//! zimrnum_fit - draw a function and watch an MLP learn it, on the CPU or the GPU (`src/notes/zimrnum_fit_plan.md`).
//!
//! Drag across the plot to reshape the curve; the network's curve follows. ONE NETWORK, TWO MACHINES, the same kernels
//! on both - the GPU learning kit's (`src/gpu/zn_mlp.zig`):
//!
//!   * THE CPU trains IN A JOB - a Web Worker in a browser, a thread of the program's own natively - as a chain: one
//!     job in flight, each a few steps of the kernels on their CPU twin, the training's state shipped back to the page
//!     and out again with the next job, with the drawing as it is then (`kernels.trainSteps`). One box runs the very
//!     same job on the frame's own thread instead, to see what the worker saves.
//!   * THE GPU trains IN BATCHES: many steps recorded as one submission, then the curve and the loss asked back, the
//!     frame never waiting for them (`submitBatch`, `collectBatch`).
//!
//! The toggle hands the training from one machine to the other - the weights, both moments, the step count - once the
//! work in flight has landed (`switchMachines`). The panel chooses the network and how it learns. What to look for:
//!
//!   * the network's curve bending toward each new stroke while the stroke is still being drawn;
//!   * the dot orbiting smoothly, the frames near 16.7 ms: the training is ELSEWHERE - and, with the box ticked, the
//!     dot stuttering, the same work now ON the frame;
//!   * the steps a second at a flip: the CPU is slow, the GPU is not, and the loss carries on across it.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const z = @import("zimr");
const zm = @import("zm");
const zn_mlp = @import("zn_mlp");
const common = @import("example_common");
const kernels = @import("kernels.zig");
const sketch = @import("sketch.zig");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line (claude.md).
pub const panic = std.debug.FullPanic(common.reportPanic);

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const Writer = Io.Writer;
const asBytes = std.mem.asBytes;
const sliceAsBytes = std.mem.sliceAsBytes;
const cosRad = zm.cosRad;
const sinRad = zm.sinRad;
const exp10 = zm.exp10;
const log10 = zm.log10;
const lerp = zm.lerp;
const nan = zm.nan;
const float = zm.float;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const jobs = z.jobs;
const kit_mlp = z.kit_mlp;
const native_os = z.native_os;
const ui = z.ui;
const plot_ui = z.plot_ui;

/// The GPU's machine: the kit's kernels as a pipe of the device's, and the network on it.
const Pipe = z.Compute(zn_mlp);
const Network = kit_mlp.KitMlp(zn_mlp);

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The machines a network trains on, numbered for the panel's radio buttons.
const Machine = enum(i32) { cpu = 0, gpu = 1 };

/// THE GPU's KERNELS: the plain dense network's, its loss and both optimisers - this page's entries in build.zig, each
/// translated for the device: WGSL in a browser, the kernel file's SPIR-V natively.
const gpu_kernel_names = [_][:0]const u8{
    "dense_fwd_tiled",
    "act_bwd",
    "dense_bwd_w_tiled",
    "dense_bwd_x_tiled",
    "mse_bwd",
    "mse_value",
    "adam",
    "sgd",
};
const gpu_kernels: [gpu_kernel_names.len]Pipe.KernelWgsl = kernel_table: {
    var table: [gpu_kernel_names.len]Pipe.KernelWgsl = undefined;
    for (gpu_kernel_names, 0..) |name, index| {
        table[index] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    break :kernel_table table;
};

/// The network and how it learns, as the panel sets them: the plan's defaults to start.
const Settings = struct {
    hidden_layer_count: u32 = 3,
    hidden_width: u32 = 64,
    activation: kernels.Activation = .tanh,
    optimizer: kernels.Optimizer = .adam,
    rate: f32 = 5.0e-3,
    momentum: f32 = 0.9,
    seed: u32 = 1,
};

/// A job lasts about this long: long enough that the round trip to the worker is a small part of it, short enough
/// that the curve follows the pen (`steerStepsPerJob`).
const job_target_seconds: f32 = 2.0 / 60.0;
const most_steps_per_job: u32 = 4096;
/// A frame gap past this is a dropped frame at 60 Hz: two frames' time.
const dropped_frame_gap_ms: f32 = 34.0;
/// How often the steps-a-second figure is renewed.
const speed_window_seconds: f32 = 1.0;
/// The learning rate's slider runs over its logarithm, from 1e-5 to about 0.3.
const smallest_rate_exponent: f32 = -5.0;
const largest_rate_exponent: f32 = -0.5;
/// The narrowest hidden layer the panel offers.
const narrowest_layer: u32 = 4;
/// The two curves' colours: the drawing's blue, the network's orange.
const drawing_color: Color = .{ .r = 96, .g = 165, .b = 250, .a = 255 };
const network_color: Color = .{ .r = 251, .g = 146, .b = 60, .a = 255 };
const optimizer_names = [_][]const u8{ "Adam", "SGD" };
const activation_names = [_][]const u8{ "relu", "tanh" };
/// THE LOSS CHART: room for this many points (`recordLoss`), its share of the plot window's height and its least
/// height, and the least loss its log axis shows.
const loss_room: usize = 1024;
/// The loss chart's line by machine: the CPU's in the network's orange, the GPU's in violet.
const cpu_color: Color = network_color;
const gpu_color: Color = z.colors.violet_400;
const loss_chart_share: f32 = 0.28;
const smallest_loss_chart_height: f32 = 90.0;
const smallest_loss_shown: f64 = 1.0e-12;
/// How quickly the frames' average follows each frame: a twentieth of the way.
const frame_average_rate: f32 = 0.05;
/// THE GPU's BATCH, STEERED ON THE FRAMES (`steerStepsPerBatch`). A frame past this is late - a 60 Hz frame is
/// 16.7 ms - and a batch during which one was is halved; natively a batch is doubled only while every frame during it
/// stayed under `quick_frame_ms`. The gap between the two keeps the steering from rocking between two sizes.
const late_frame_ms: f32 = 21.0;
const quick_frame_ms: f32 = 12.5;
/// A batch on the GPU that takes longer than this to come back has its steps halved: four frames.
const longest_batch_seconds: f32 = 4.0 / 60.0;
/// THE SPEED LOG's file: beside the program natively (`writeSpeedLog`), the browser's download otherwise.
const speed_log_name: []const u8 = "zimrnum_fit_log.csv";

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    /// The drawing: the targets the network learns.
    drawing: sketch.Sketch,
    settings: Settings,
    /// The learning rate's slider, over its logarithm: `settings.rate` is ten to its power.
    rate_exponent: f32,
    /// Changes the panel asked for, made at the next submit - a job may be in flight: a new shape or a Reset starts
    /// the network afresh; a new optimiser keeps the weights and starts its moments from zero.
    fresh_start_due: bool,
    moments_reset_due: bool,
    /// Whether the job runs on the frame's own thread instead of a worker: the contrast (`runJobHere`).
    runs_inline: bool,
    /// Paused: no job is submitted; the one in flight still lands.
    paused: bool,
    /// THE TRAINING's STATE, held here between jobs - a job keeps nothing: the weights and both moment buffers back
    /// to back, as a job sends them, their length and the steps the optimiser has taken. No parameters yet: the next
    /// job starts fresh.
    training_state: []f32,
    parameter_count: u32,
    steps_taken: u32,
    /// Steps since the network last started afresh, for the readout.
    steps_since_reset: u64,
    /// The network's output at every sample, and the loss before the last step, as the last job left them.
    curve: [sketch.sample_count]f32,
    loss: f32,
    /// The job in flight, and the buffers it is staged from and collected into - owned once, never allocated in a
    /// frame (`Job.pollInto`).
    job: jobs.Job,
    payload_buffer: []u8,
    result_buffer: []u8,
    /// Steps per job (`steerStepsPerJob`), the job in flight's steps, when it was submitted (`wgpu.nowMs`, so that a
    /// job run inline can be timed within its frame), and the last job's steps and time.
    steps_per_job: u32,
    steps_in_flight: u32,
    submitted_at_ms: f64,
    last_job_steps: u32,
    last_job_seconds: f32,
    /// The steps a second, renewed every `speed_window_seconds`.
    speed_window_start: f32,
    speed_window_steps: u32,
    steps_per_second: f32,
    /// The worst gap between two frames since the first job landed, or since the box last changed, and the frames'
    /// time averaged: a slow build's frames told from a hitch. The worst while the GPU's batch was in flight - what
    /// steers it (`steerStepsPerBatch`) - and the worst of the speed window, for the log.
    worst_frame_gap_ms: f32,
    average_frame_ms: f32,
    batch_worst_frame_ms: f32,
    window_worst_frame_ms: f32,
    /// A failed job's error name, kept to be drawn: the name lives in the job, which is released.
    failure_name: [48]u8,
    failure_length: usize,
    /// Why the last shape asked for was refused: the buffer it would overflow (`kernels.fitsTheKit`).
    shape_notice: [48]u8,
    shape_notice_length: usize,
    /// The plot: its view, held still - the plot is drawn on, not panned - and its series in the plot's f64.
    plot_state: plot_ui.PlotState,
    sample_xs: [sketch.sample_count]f64,
    drawing_ys: [sketch.sample_count]f64,
    network_ys: [sketch.sample_count]f64,
    /// Where the pointer was on the frame before, while a stroke lasts, in the plot's units.
    stroke_last: Vec2,
    /// THE LOSS CHART: when the page started (`wgpu.nowMs`), and a point per landing - its seconds since then, its
    /// loss and the machine that trained it - of every `loss_stride`-th landing (`recordLoss`); and each machine's
    /// line, drawn from them (`drawLossChart`).
    started_at_ms: f64,
    loss_seconds: [loss_room]f64,
    loss_values: [loss_room]f64,
    loss_machines: [loss_room]Machine,
    cpu_loss_ys: [loss_room]f64,
    gpu_loss_ys: [loss_room]f64,
    loss_count: usize,
    loss_stride: u32,
    landings_since_loss_point: u32,
    loss_plot_state: plot_ui.PlotState,
    /// THE MACHINES: the one training now, and the toggle's choice - taken once the work in flight has landed
    /// (`switchMachines`).
    machine: Machine,
    wanted_machine: Machine,
    /// THE GPU: the kit's kernels on the device - their pipelines made in the background - and the network on it,
    /// made when the GPU first trains and again at each fresh start. No pipe where the device would not make one.
    gpu_pipe: ?Pipe,
    gpu_network: ?*Network,
    /// The batch on the GPU: whether one is in flight, its two readbacks - the curve and the loss - and the steps a
    /// batch takes (`steerStepsPerBatch`).
    batch_in_flight: bool,
    curve_request: ?Pipe.RangeRequest(.acts),
    loss_request: ?Pipe.RangeRequest(.loss),
    steps_per_batch: u32,
    /// The GPU's training state on its way back to the CPU (`takeTheCpu`).
    state_request: ?Network.StateRequest,
    /// A batch's inputs: the grid's x values, as the job makes them (`sketch.sampleX`).
    sample_inputs: [sketch.sample_count]f32,
    /// THE SPEED LOG: a line a second - what trained, its shape, how fast, the frames (`logSpeed`) - to be read after a
    /// run: written beside the program as it closes, natively (`writeSpeedLog`), and saved from the panel's button in
    /// a browser. How long it was when last offered to that button.
    speed_log: ArrayList(u8),
    speed_log_offered_length: usize,
};

/// The speed log's head: where it was made - a browser or native, the build's mode, whether jobs had workers at the
/// start - then the names of its columns (`logSpeed`).
fn startSpeedLog(gpa: Allocator, speed_log: *ArrayList(u8)) !void {
    const made_where: []const u8 = if (z.host.is_browser) "a browser" else "native";
    const workers: []const u8 = if (jobs.parallel()) "workers" else "no workers";
    try speed_log.print(gpa, "# zimrnum_fit's speed log: {s}, a {s} build, {s} at the start\n", .{
        made_where,
        @tagName(builtin.mode),
        workers,
    });
    const columns: []const u8 = "seconds,machine,inline,layers,width,activation,optimizer,rate,steps_per_second," ++
        "steps_per_work,work_ms,frame_ms,worst_frame_ms,loss,step\n";
    try speed_log.appendSlice(gpa, columns);
}

/// A LINE OF THE SPEED LOG, at each renewal of the steps a second (`renewSpeed`): the machine training and whether its
/// job runs inline, the network and how it learns, the steps a second, the last job's or batch's steps and time, the
/// frames' average and the window's worst, the loss and the steps since a fresh start.
fn logSpeed(f: *z.Frame, s: *State) void {
    const line_format: []const u8 = "{d:.1},{s},{d},{d},{d},{s},{s},{e:.2}," ++
        "{d:.1},{d},{d:.1},{d:.2},{d:.1},{e:.4},{d}\n";
    s.speed_log.print(s.gpa, line_format, .{
        f.time.time,
        @tagName(s.machine),
        @intFromBool(s.runs_inline),
        s.settings.hidden_layer_count,
        s.settings.hidden_width,
        @tagName(s.settings.activation),
        @tagName(s.settings.optimizer),
        s.settings.rate,
        s.steps_per_second,
        s.last_job_steps,
        s.last_job_seconds * 1000.0,
        s.average_frame_ms,
        s.window_worst_frame_ms,
        s.loss,
        s.steps_since_reset,
    }) catch |err| {
        std.log.warn("zimrnum_fit: the speed log stops growing: {s}", .{@errorName(err)});
    };
}

/// THE SPEED LOG BESIDE THE PROGRAM, natively, as the page closes: `zimrnum_fit_log.csv` in the executable's folder,
/// to be read after a run - written once, so that no frame of the run waits on a file. A page has no files by path:
/// in a browser the panel's "save the log" downloads it.
fn writeSpeedLog(s: *State) void {
    if (comptime !z.host.is_browser) {
        const io: Io = native_os.servicesIo();
        var folder_buffer: [1024]u8 = undefined;
        const folder: []const u8 = native_os.executableFolder(io, &folder_buffer) orelse {
            std.log.warn("zimrnum_fit: no folder for the speed log: the system did not say where the program is", .{});
            return;
        };
        var path_buffer: [1200]u8 = undefined;
        const path: []const u8 = bufPrint(&path_buffer, "{s}/{s}", .{ folder, speed_log_name }) catch |err| {
            std.log.warn("zimrnum_fit: no path for the speed log: {s}", .{@errorName(err)});
            return;
        };
        native_os.writeWhole(s.gpa, io, path, s.speed_log.items) catch |err| {
            std.log.warn("zimrnum_fit: the speed log was not written to {s}: {s}", .{ path, @errorName(err) });
            return;
        };
        std.log.info("zimrnum_fit: the speed log is at {s}", .{path});
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    const training_state: []f32 = try gpa.alloc(f32, kernels.most_state_floats);
    const payload_buffer: []u8 = try gpa.alloc(u8, kernels.registry.max_input);
    const result_buffer: []u8 = try gpa.alloc(u8, kernels.registry.max_output);
    var sample_inputs: [sketch.sample_count]f32 = undefined;
    var sample_xs: [sketch.sample_count]f64 = undefined;
    for (&sample_inputs, &sample_xs, 0..) |*sample_input, *sample_x, sample_index| {
        sample_input.* = sketch.sampleX(sample_index);
        sample_x.* = sample_input.*;
    }
    // The GPU's pipe, its pipelines made in the background: the CPU trains at once, and the GPU is offered once they
    // are all made (`drawMachine`).
    const gpu_pipe: ?Pipe = Pipe.initGpuInBackground(gpa, f.gpu.device, f.gpu.queue, &gpu_kernels) catch |err| none: {
        std.log.warn("zimrnum_fit: no pipe on the GPU ({s}): the CPU trains alone", .{@errorName(err)});
        break :none null;
    };
    var speed_log: ArrayList(u8) = .empty;
    try startSpeedLog(gpa, &speed_log);
    const largest_target: f64 = sketch.largest_target;
    const settings: Settings = .{};
    s.* = .{
        .gpa = gpa,
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .drawing = .sine(),
        .settings = settings,
        .rate_exponent = log10(settings.rate),
        .fresh_start_due = false,
        .moments_reset_due = false,
        .runs_inline = false,
        .paused = false,
        .training_state = training_state,
        .parameter_count = 0,
        .steps_taken = 0,
        .steps_since_reset = 0,
        .curve = @splat(0),
        .loss = 0,
        .job = .{},
        .payload_buffer = payload_buffer,
        .result_buffer = result_buffer,
        .steps_per_job = 1,
        .steps_in_flight = 0,
        .submitted_at_ms = 0,
        .last_job_steps = 0,
        .last_job_seconds = 0,
        .speed_window_start = 0,
        .speed_window_steps = 0,
        .steps_per_second = 0,
        .worst_frame_gap_ms = 0,
        .average_frame_ms = 0,
        .batch_worst_frame_ms = 0,
        .window_worst_frame_ms = 0,
        .failure_name = @splat(0),
        .failure_length = 0,
        .shape_notice = @splat(0),
        .shape_notice_length = 0,
        .plot_state = .{
            .x = .{ .min = -1.0, .max = 1.0 },
            .y = .{ .min = -largest_target, .max = largest_target },
            .fitted = true,
        },
        .sample_xs = sample_xs,
        .drawing_ys = @splat(0),
        .network_ys = @splat(0),
        .stroke_last = .{ 0, 0 },
        .started_at_ms = z.wgpu.nowMs(),
        .loss_seconds = @splat(0),
        .loss_values = @splat(0),
        .loss_machines = @splat(.cpu),
        .cpu_loss_ys = @splat(0),
        .gpu_loss_ys = @splat(0),
        .loss_count = 0,
        .loss_stride = 1,
        .landings_since_loss_point = 0,
        .loss_plot_state = .{},
        .machine = .cpu,
        .wanted_machine = .cpu,
        .gpu_pipe = gpu_pipe,
        .gpu_network = null,
        .batch_in_flight = false,
        .curve_request = null,
        .loss_request = null,
        .steps_per_batch = 1,
        .state_request = null,
        .sample_inputs = sample_inputs,
        .speed_log = speed_log,
        .speed_log_offered_length = 0,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    // Cancels the job if it is still in flight: a thread's is reclaimed once it lands.
    s.job.deinit();
    // The GPU's readbacks given up - their buffers wait for the device - then its network and its pipe.
    if (s.curve_request) |*request| {
        request.discard();
    }
    if (s.loss_request) |*request| {
        request.discard();
    }
    if (s.state_request) |*request| {
        request.discard();
    }
    if (s.gpu_network) |network| {
        network.deinit();
    }
    if (s.gpu_pipe) |*pipe| {
        pipe.deinit();
    }
    writeSpeedLog(s);
    s.speed_log.deinit(gpa);
    gpa.free(s.training_state);
    gpa.free(s.payload_buffer);
    gpa.free(s.result_buffer);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// A name kept in a fixed buffer, cut to its room: returns its length.
fn keepName(destination: []u8, name: []const u8) usize {
    const kept_length: usize = @min(name.len, destination.len);
    @memcpy(destination[0..kept_length], name[0..kept_length]);
    return kept_length;
}

fn recordFailure(s: *State, failure_name: []const u8) void {
    s.failure_length = keepName(&s.failure_name, failure_name);
    std.log.err("zimrnum_fit: the training job failed: {s}", .{failure_name});
}

/// The header of a job of `step_count` steps of the network `settings` describes.
fn trainHeader(
    settings: Settings,
    step_count: u32,
    starts_fresh: bool,
    steps_taken: u32,
) kernels.TrainHeader {
    const header: kernels.TrainHeader = .{
        .step_count = step_count,
        .hidden_layer_count = settings.hidden_layer_count,
        .hidden_width = settings.hidden_width,
        .activation = settings.activation,
        .optimizer = settings.optimizer,
        .rate = settings.rate,
        .momentum = settings.momentum,
        .starts_fresh = starts_fresh,
        .seed = settings.seed,
        .steps_taken = steps_taken,
    };
    return header;
}

/// STEPS PER JOB, steered so that a job lasts about two frames. The kernel has no clock, so a job is timed from its
/// submit to its landing: doubled when one lands within a frame, halved past four.
fn steerStepsPerJob(s: *State) void {
    const landed_soon: bool = s.last_job_seconds < 0.5 * job_target_seconds;
    const landed_late: bool = s.last_job_seconds > 2.0 * job_target_seconds;
    if (landed_soon) {
        s.steps_per_job = @min(s.steps_per_job * 2, most_steps_per_job);
    } else if (landed_late) {
        s.steps_per_job = @max(s.steps_per_job / 2, 1);
    }
}

/// The seconds since the job in flight was submitted.
fn secondsSinceSubmit(s: *const State) f32 {
    const elapsed_ms: f64 = z.wgpu.nowMs() - s.submitted_at_ms;
    return @floatCast(elapsed_ms / 1000.0);
}

/// One point of the loss chart, for the job just landed: every `loss_stride`-th landing is kept. When the room is
/// full, every other point goes and the stride doubles - the whole run stays in view, in a room that never grows.
fn recordLoss(s: *State) void {
    s.landings_since_loss_point += 1;
    if (s.landings_since_loss_point < s.loss_stride) {
        return;
    }
    s.landings_since_loss_point = 0;
    const room_is_full: bool = s.loss_count == loss_room;
    if (room_is_full) {
        for (0..loss_room / 2) |kept_index| {
            s.loss_seconds[kept_index] = s.loss_seconds[2 * kept_index + 1];
            s.loss_values[kept_index] = s.loss_values[2 * kept_index + 1];
            s.loss_machines[kept_index] = s.loss_machines[2 * kept_index + 1];
        }
        s.loss_count = loss_room / 2;
        s.loss_stride *= 2;
    }
    const elapsed_ms: f64 = z.wgpu.nowMs() - s.started_at_ms;
    const loss: f64 = s.loss;
    s.loss_seconds[s.loss_count] = elapsed_ms / 1000.0;
    s.loss_values[s.loss_count] = @max(loss, smallest_loss_shown);
    // The machine that trained it: a switch waits for the work in flight, so the landed work is the current machine's.
    s.loss_machines[s.loss_count] = s.machine;
    s.loss_count += 1;
}

/// A landed result into the page's state: its head, the training's state, the curve.
fn takeResult(s: *State, bytes: []const u8, job_seconds: f32) void {
    const head_bytes: usize = @sizeOf(kernels.TrainResultHead);
    if (bytes.len < head_bytes) {
        recordFailure(s, "ResultTooShort");
        return;
    }
    var head: kernels.TrainResultHead = undefined;
    @memcpy(asBytes(&head), bytes[0..head_bytes]);
    const state_floats: usize = 3 * @as(usize, head.parameter_count);
    const result_is_whole: bool = state_floats <= s.training_state.len and
        bytes.len == head_bytes + kernels.resultFloatCount(head.parameter_count) * @sizeOf(f32);
    if (!result_is_whole) {
        recordFailure(s, "ResultDoesNotFit");
        return;
    }
    const numbers: []const u8 = bytes[head_bytes..];
    const state_bytes: usize = state_floats * @sizeOf(f32);
    @memcpy(sliceAsBytes(s.training_state[0..state_floats]), numbers[0..state_bytes]);
    @memcpy(sliceAsBytes(&s.curve), numbers[state_bytes..]);
    s.parameter_count = head.parameter_count;
    s.steps_taken = head.steps_taken;
    s.steps_since_reset += s.steps_in_flight;
    s.loss = head.loss;
    s.last_job_steps = s.steps_in_flight;
    s.last_job_seconds = job_seconds;
    s.speed_window_steps += s.steps_in_flight;
    steerStepsPerJob(s);
    recordLoss(s);
}

/// Takes the job's result once it has landed - a non-blocking poll, every frame, the same whether a worker, a thread
/// or the inline fallback ran it - and releases the job, landed or failed, so that the next can be submitted.
fn collectJob(s: *State) void {
    const landed_bytes: ?[]const u8 = s.job.pollInto(s.result_buffer) catch |err| {
        const job_name: []const u8 = s.job.errorName();
        recordFailure(s, if (job_name.len > 0) job_name else @errorName(err));
        s.job.deinit();
        return;
    };
    const bytes: []const u8 = landed_bytes orelse return;
    takeResult(s, bytes, secondsSinceSubmit(s));
    s.job.deinit();
}

/// THE SAME JOB ON THE FRAME's THREAD: the kernel called as a plain function, as `jobs` itself does where no worker
/// can be had, into the page's own result buffer. The frame waits for every step of it.
fn runJobHere(s: *State, header: kernels.TrainHeader, payload: []const u8) void {
    var job_arena: ArenaAllocator = .init(s.gpa);
    defer job_arena.deinit();
    var result_writer: Writer = .fixed(s.result_buffer);
    kernels.trainSteps(job_arena.allocator(), header, payload, &result_writer) catch |err| {
        recordFailure(s, @errorName(err));
        return;
    };
    takeResult(s, result_writer.buffered(), secondsSinceSubmit(s));
}

/// Submits the next job - unless one is in flight, one has failed, the training is paused or the machines are being
/// switched - with the training's state, unless it starts fresh, and the drawing AS IT IS NOW: a change to the drawing
/// reaches the training within a job. The panel's changes are made here, to the state the last job sent back.
fn submitJob(s: *State) void {
    const has_failed: bool = s.failure_length > 0;
    const switch_is_pending: bool = s.wanted_machine != s.machine;
    if (s.job.inFlight() or has_failed or s.paused or switch_is_pending) {
        return;
    }
    const starts_fresh: bool = s.parameter_count == 0 or s.fresh_start_due;
    const parameter_count: usize = s.parameter_count;
    const resets_moments: bool = !starts_fresh and s.moments_reset_due;
    if (resets_moments) {
        @memset(s.training_state[parameter_count .. 3 * parameter_count], 0.0);
        s.steps_taken = 0;
    }
    if (starts_fresh) {
        s.steps_since_reset = 0;
    }
    s.fresh_start_due = false;
    s.moments_reset_due = false;
    const state_floats: usize = if (starts_fresh) 0 else 3 * parameter_count;
    const state_bytes: usize = state_floats * @sizeOf(f32);
    const target_bytes: usize = sketch.sample_count * @sizeOf(f32);
    @memcpy(s.payload_buffer[0..state_bytes], sliceAsBytes(s.training_state[0..state_floats]));
    @memcpy(s.payload_buffer[state_bytes..][0..target_bytes], sliceAsBytes(&s.drawing.targets));
    const steps_taken: u32 = if (starts_fresh) 0 else s.steps_taken;
    const header: kernels.TrainHeader = trainHeader(s.settings, s.steps_per_job, starts_fresh, steps_taken);
    const payload: []const u8 = s.payload_buffer[0 .. state_bytes + target_bytes];
    s.steps_in_flight = s.steps_per_job;
    s.submitted_at_ms = z.wgpu.nowMs();
    if (s.runs_inline) {
        runJobHere(s, header, payload);
        return;
    }
    s.job = kernels.registry.submit(s.gpa, kernels.trainSteps, header, payload) catch |err| submit_failed: {
        recordFailure(s, @errorName(err));
        break :submit_failed .{};
    };
}

/// How far the GPU's pipelines have come - null where there is no pipe on the GPU. Asked every frame: a pipe whose
/// pipelines are made in the background may dispatch only once they all are (`pipelineProgress`).
fn gpuProgress(s: *State) ?Pipe.PipelineProgress {
    if (s.gpu_pipe) |*pipe| {
        return pipe.pipelineProgress();
    }
    return null;
}

/// THE GPU's NETWORK, made afresh from the seed for the panel's settings - the one before, if any, released. The very
/// network a job builds (`kernels.networkSpec`), on the device's buffers instead of the twin's.
fn makeGpuNetwork(s: *State) !*Network {
    if (s.gpu_network) |old_network| {
        old_network.deinit();
        s.gpu_network = null;
    }
    var hidden_widths: [kernels.most_hidden_layers]u32 = undefined;
    const spec: kit_mlp.Spec = kernels.networkSpec(trainHeader(s.settings, 1, true, 0), &hidden_widths);
    const network: *Network = try Network.init(s.gpa, &s.gpu_pipe.?, spec);
    s.gpu_network = network;
    return network;
}

/// THE PANEL's CHANGES ON THE GPU, made before a batch as the CPU's are before a job (`submitJob`): a fresh start makes
/// a new network; a new optimiser zeroes both moments and the step count; the rate and SGD's momentum are the
/// network's spec, which each step reads as it is recorded (`KitMlp.recordOptimizerStep`).
fn applySettingsOnTheGpu(s: *State) !*Network {
    const starts_fresh: bool = s.gpu_network == null or s.fresh_start_due;
    s.fresh_start_due = false;
    if (starts_fresh) {
        s.moments_reset_due = false;
        s.steps_since_reset = 0;
        return makeGpuNetwork(s);
    }
    const network: *Network = s.gpu_network.?;
    if (s.moments_reset_due) {
        s.moments_reset_due = false;
        const zeros: []f32 = try s.gpa.alloc(f32, network.param_count);
        defer s.gpa.free(zeros);
        @memset(zeros, 0.0);
        network.pipe.upload(.adam_m, zeros);
        network.pipe.upload(.adam_v, zeros);
        network.adam_step = 0;
    }
    var hidden_widths: [kernels.most_hidden_layers]u32 = undefined;
    const wanted: kit_mlp.Spec = kernels.networkSpec(trainHeader(s.settings, 1, false, 0), &hidden_widths);
    network.spec.rate = wanted.rate;
    network.spec.optimizer = wanted.optimizer;
    return network;
}

/// The most steps one recording holds for the panel's network, so that a batch stays one submission: a step
/// dispatches every layer forward, the loss and its gradient, up to three kernels a layer backward, and the optimiser
/// (`KitMlp.recordStep`).
fn mostStepsPerBatch(settings: Settings) u32 {
    const layer_count: u32 = settings.hidden_layer_count + 1;
    const dispatches_per_step: u32 = 4 * layer_count + 3;
    return @max(Pipe.recording_slots / dispatches_per_step, 1);
}

/// STEPS PER BATCH, steered on the frames that passed while it was in flight: halved when one of them was late, or
/// when the batch took past four frames to come back. NATIVELY the frame waits for the device, so a batch of too many
/// steps shows as a late frame (the first speed log: batches of 25-55 ms, frames up to 66 ms), and a batch grows only
/// while every frame during it stayed quick. IN A BROWSER the page is called at the browser's own rate whatever the
/// device is doing, so its frames cannot say; there a batch grows while it comes back within two frames. Never past
/// what one recording holds (`mostStepsPerBatch`).
fn steerStepsPerBatch(s: *State) void {
    const a_frame_was_late: bool = s.batch_worst_frame_ms > late_frame_ms;
    const came_back_late: bool = s.last_job_seconds > longest_batch_seconds;
    const has_room_to_grow: bool = if (z.host.is_browser)
        s.last_job_seconds <= job_target_seconds
    else
        s.batch_worst_frame_ms < quick_frame_ms;
    if (a_frame_was_late or came_back_late) {
        s.steps_per_batch = @max(s.steps_per_batch / 2, 1);
    } else if (has_room_to_grow) {
        s.steps_per_batch = @min(s.steps_per_batch * 2, mostStepsPerBatch(s.settings));
    }
}

/// THE NEXT BATCH ON THE GPU - unless one is in flight, one has failed, the training is paused or the machines are
/// being switched: the drawing as it is now, `steps_per_batch` steps recorded as one submission, then the curve and the
/// loss asked back. The frame never waits for them (`collectBatch`).
fn submitBatch(s: *State) void {
    const has_failed: bool = s.failure_length > 0;
    const switch_is_pending: bool = s.wanted_machine != s.machine;
    if (s.batch_in_flight or has_failed or s.paused or switch_is_pending) {
        return;
    }
    const network: *Network = applySettingsOnTheGpu(s) catch |err| {
        recordFailure(s, @errorName(err));
        return;
    };
    network.setBatch(&s.sample_inputs, &s.drawing.targets);
    network.trainSteps(s.steps_per_batch);
    s.curve_request = network.requestOutputs(s.gpa) catch |err| {
        recordFailure(s, @errorName(err));
        return;
    };
    s.loss_request = network.pipe.requestRange(s.gpa, .loss, 0, 1) catch |err| {
        recordFailure(s, @errorName(err));
        return;
    };
    s.batch_in_flight = true;
    s.steps_in_flight = s.steps_per_batch;
    s.submitted_at_ms = z.wgpu.nowMs();
    s.batch_worst_frame_ms = 0;
}

/// Takes the GPU's batch once both its readbacks have landed - polled every frame, each landing as it arrives.
fn collectBatch(s: *State) void {
    if (!s.batch_in_flight) {
        return;
    }
    if (s.curve_request) |*request| {
        if (request.collect(&s.curve)) {
            s.curve_request = null;
        }
    }
    if (s.loss_request) |*request| {
        var loss: [1]f32 = undefined;
        if (request.collect(&loss)) {
            s.loss = loss[0];
            s.loss_request = null;
        }
    }
    const batch_has_landed: bool = s.curve_request == null and s.loss_request == null;
    if (!batch_has_landed) {
        return;
    }
    s.batch_in_flight = false;
    const network: *Network = s.gpu_network.?;
    s.parameter_count = network.param_count;
    s.steps_taken = network.adam_step;
    s.steps_since_reset += s.steps_in_flight;
    s.last_job_steps = s.steps_in_flight;
    s.last_job_seconds = secondsSinceSubmit(s);
    s.speed_window_steps += s.steps_in_flight;
    steerStepsPerBatch(s);
    recordLoss(s);
}

/// CPU TO GPU, once the job in flight has landed and the GPU's pipelines are made: the GPU's network, made for the
/// panel's settings, takes the state the last job sent back (`putState`) - unless the training starts afresh anyway.
fn takeTheGpu(s: *State) void {
    const gpu_is_ready: bool = if (gpuProgress(s)) |progress| progress.isComplete() else false;
    if (s.job.inFlight() or !gpu_is_ready) {
        return;
    }
    const carries_the_state: bool = s.parameter_count > 0 and !s.fresh_start_due;
    const network: *Network = makeGpuNetwork(s) catch |err| {
        recordFailure(s, @errorName(err));
        return;
    };
    const shapes_agree: bool = network.param_count == s.parameter_count;
    if (carries_the_state and shapes_agree) {
        const parameter_count: usize = s.parameter_count;
        network.putState(.{
            .weights = s.training_state[0..parameter_count],
            .first_moments = s.training_state[parameter_count..][0..parameter_count],
            .second_moments = s.training_state[2 * parameter_count ..][0..parameter_count],
            .step_count = s.steps_taken,
        });
    } else {
        s.steps_since_reset = 0;
    }
    s.fresh_start_due = false;
    s.machine = .gpu;
}

/// GPU TO CPU, once the batch in flight has landed: the GPU's state is asked back (`requestState`) into the page's,
/// and once it has landed the next job goes on from it.
fn takeTheCpu(s: *State) void {
    if (s.batch_in_flight) {
        return;
    }
    const network: *Network = s.gpu_network orelse {
        s.machine = .cpu;
        return;
    };
    if (s.state_request == null) {
        s.state_request = network.requestState(s.gpa) catch |err| {
            recordFailure(s, @errorName(err));
            return;
        };
    }
    const parameter_count: usize = network.param_count;
    var state: kit_mlp.TrainingState = .{
        .weights = s.training_state[0..parameter_count],
        .first_moments = s.training_state[parameter_count..][0..parameter_count],
        .second_moments = s.training_state[2 * parameter_count ..][0..parameter_count],
        .step_count = 0,
    };
    const request: *Network.StateRequest = &s.state_request.?;
    if (!request.collect(&state)) {
        return;
    }
    s.state_request = null;
    s.parameter_count = network.param_count;
    s.steps_taken = state.step_count;
    s.machine = .cpu;
}

/// THE TOGGLE: the machine the panel asks for takes the training over, once the work in flight has landed. Nothing is
/// submitted while a switch is under way (`submitJob`, `submitBatch`), so no step is lost on either side.
fn switchMachines(s: *State) void {
    const switch_is_pending: bool = s.wanted_machine != s.machine;
    if (!switch_is_pending) {
        // A toggle turned back before the GPU's state landed gives the request up: the GPU trains on, and a later
        // switch asks again - never for a state some batches old.
        if (s.state_request) |*request| {
            request.discard();
            s.state_request = null;
        }
        return;
    }
    switch (s.wanted_machine) {
        .gpu => takeTheGpu(s),
        .cpu => takeTheCpu(s),
    }
}

/// The steps a second over the last window.
fn renewSpeed(f: *z.Frame, s: *State) void {
    const window_seconds: f32 = f.time.time - s.speed_window_start;
    if (window_seconds < speed_window_seconds) {
        return;
    }
    s.steps_per_second = float(s.speed_window_steps) / window_seconds;
    s.speed_window_steps = 0;
    s.speed_window_start = f.time.time;
    logSpeed(f, s);
    s.window_worst_frame_ms = 0;
}

/// A NEW SHAPE, if it fits the kit: the network starts afresh with it at the next submit. One that does not fit is
/// refused with the buffer it would overflow, and the shape stays as it was.
fn takeShape(s: *State, wanted: Settings) void {
    const header: kernels.TrainHeader = trainHeader(wanted, 1, true, 0);
    kernels.fitsTheKit(s.gpa, header) catch |err| {
        s.shape_notice_length = keepName(&s.shape_notice, @errorName(err));
        return;
    };
    s.settings = wanted;
    s.shape_notice_length = 0;
    s.fresh_start_due = true;
}

/// Where the plot and the panel go: side by side on a desktop, the plot over the panel on a narrow screen.
const Layout = struct {
    plot_position: Vec2,
    plot_size: Vec2,
    panel_position: Vec2,
    panel_size: Vec2,
    panel_characters: f32,
};

fn pageLayout(viewport_width: f32, viewport_height: f32) Layout {
    const margin: f32 = 8.0;
    const is_narrow: bool = ui.Ui.isNarrow(viewport_width);
    if (is_narrow) {
        const plot_height: f32 = viewport_height * 0.45;
        const narrow_layout: Layout = .{
            .plot_position = .{ margin, margin },
            .plot_size = .{ viewport_width - 2.0 * margin, plot_height },
            .panel_position = .{ margin, plot_height + 2.0 * margin },
            .panel_size = .{ viewport_width - 2.0 * margin, viewport_height - plot_height - 3.0 * margin },
            .panel_characters = 30.0,
        };
        return narrow_layout;
    }
    const panel_width: f32 = @min(460.0, viewport_width * 0.36);
    const wide_layout: Layout = .{
        .plot_position = .{ margin, margin },
        .plot_size = .{ viewport_width - panel_width - 3.0 * margin, viewport_height - 2.0 * margin },
        .panel_position = .{ viewport_width - panel_width - margin, margin },
        .panel_size = .{ panel_width, viewport_height - 2.0 * margin },
        .panel_characters = 28.0,
    };
    return wide_layout;
}

/// THE STROKE: while the plot is held, the drawing takes the line from where the pointer was to where it is. A
/// stroke starts where the pointer IS on the press frame, never from where it last was - a finger arrives as a jump
/// from wherever the last touch ended (claude.md: a drag anchors on the press frame). Called right after the plot,
/// whose hit target is then the last item.
fn drawWithThePointer(u: ui.Ui, s: *State) void {
    const plot_is_held: bool = u.isItemActive();
    const stroke_starts: bool = u.isItemActivated();
    const pointer: [2]f64 = s.plot_state.getPlotMousePos();
    const pointer_point: Vec2 = .{ @floatCast(pointer[0]), @floatCast(pointer[1]) };
    if (stroke_starts) {
        s.drawing.paintSegment(pointer_point, pointer_point);
    } else if (plot_is_held) {
        s.drawing.paintSegment(s.stroke_last, pointer_point);
    }
    s.stroke_last = pointer_point;
}

/// THE LOSS OVER THE SECONDS, on a log scale - a point per landing (`recordLoss`) - one line for each machine: its
/// slope is how fast the network learns, and at a flip the slope changes colour and steepness, never level.
fn drawLossChart(u: ui.Ui, s: *State, size: Vec2) void {
    const has_a_line: bool = s.loss_count >= 2;
    if (!has_a_line) {
        u.dummy(size);
        return;
    }
    // Each machine's line holds its own points, and a missing number - which breaks a plot's line - where the other
    // machine trained. The point before a flip belongs to both lines, so the line runs on unbroken in the new colour.
    for (0..s.loss_count) |point_index| {
        const machine: Machine = s.loss_machines[point_index];
        const has_next: bool = point_index + 1 < s.loss_count;
        const next_machine: Machine = if (has_next) s.loss_machines[point_index + 1] else machine;
        const on_cpu_line: bool = machine == .cpu or next_machine == .cpu;
        const on_gpu_line: bool = machine == .gpu or next_machine == .gpu;
        const loss: f64 = s.loss_values[point_index];
        s.cpu_loss_ys[point_index] = if (on_cpu_line) loss else nan(f64);
        s.gpu_loss_ys[point_index] = if (on_gpu_line) loss else nan(f64);
    }
    const loss_series = [_]plot_ui.Series{
        .{
            .xs = s.loss_seconds[0..s.loss_count],
            .ys = s.cpu_loss_ys[0..s.loss_count],
            .spec = .{ .color = cpu_color, .thickness = 2.0 },
            .label = "CPU",
        },
        .{
            .xs = s.loss_seconds[0..s.loss_count],
            .ys = s.gpu_loss_ys[0..s.loss_count],
            .spec = .{ .color = gpu_color, .thickness = 2.0 },
            .label = "GPU",
        },
    };
    // An untitled plot's hit target has one id; the drawing's plot has it, so this one is pushed apart.
    u.pushId("loss chart");
    defer u.popId();
    plot_ui.show(u, &s.loss_plot_state, size, &loss_series, .{
        .interactive = false,
        .auto_fit = true,
        .y_log = true,
        .x_label = "seconds",
        .y_label = "loss",
    });
}

fn drawPlot(u: ui.Ui, s: *State, layout: Layout) void {
    for (&s.drawing_ys, &s.network_ys, s.drawing.targets, s.curve) |*drawing_y, *network_y, target, output| {
        drawing_y.* = target;
        network_y.* = output;
    }
    const all_series = [_]plot_ui.Series{
        .{
            .xs = &s.sample_xs,
            .ys = &s.drawing_ys,
            .spec = .{ .color = drawing_color, .thickness = 3.0 },
            .label = "your drawing",
        },
        .{
            .xs = &s.sample_xs,
            .ys = &s.network_ys,
            .spec = .{ .color = network_color, .thickness = 2.0 },
            .label = "the network",
        },
    };
    // The network's curve only once a job has drawn one.
    const has_trained: bool = s.parameter_count > 0;
    const shown_series: []const plot_ui.Series = if (has_trained) &all_series else all_series[0..1];
    u.setNextWindowPos(layout.plot_position, .{});
    u.setNextWindowSize(layout.plot_size, .{});
    const plot_flags: ui.WindowFlags = .{ .no_title_bar = true, .no_move = true, .no_resize = true };
    if (u.window("the drawing", .{ .flags = plot_flags })) |window| {
        defer window.close();
        // The drawing above, the loss chart under it.
        const available: Vec2 = u.getContentRegionAvail();
        const loss_height: f32 = @max(smallest_loss_chart_height, available[1] * loss_chart_share);
        const spacing: f32 = u.style().item_spacing[1];
        const drawing_size: Vec2 = .{ available[0], available[1] - loss_height - spacing };
        plot_ui.show(u, &s.plot_state, drawing_size, shown_series, .{
            .interactive = false,
            .x_label = "x - drag across to draw",
            .y_label = "y",
        });
        drawWithThePointer(u, s);
        drawLossChart(u, s, .{ available[0], loss_height });
    }
}

/// The dot that orbits once a couple of seconds: a frame that does not happen stops it dead (worker_png's).
fn drawOrbitingDot(u: ui.Ui, time: f32) void {
    const draw_list: *ui.DrawList = u.getDrawList() orelse return;
    const ring_radius: f32 = 26.0;
    const corner: Vec2 = u.getCursorScreenPos();
    u.dummy(.{ 2.0 * ring_radius + 8.0, 2.0 * ring_radius + 8.0 });
    const center: Vec2 = .{ corner[0] + ring_radius + 4.0, corner[1] + ring_radius + 4.0 };
    const orbit_radius: f32 = ring_radius - 6.0;
    const angle: f32 = time * 3.0;
    const dot_position: Vec2 = .{ center[0] + orbit_radius * cosRad(angle), center[1] + orbit_radius * sinRad(angle) };
    const ring_color: Color = .{ .r = 22, .g = 30, .b = 48, .a = 255 };
    draw_list.addCircleFilled(u.drawListAllocator(), center, ring_radius, ring_color.toWire(), 32);
    draw_list.addCircleFilled(u.drawListAllocator(), dot_position, 6.0, z.colors.emerald_400.toWire(), 16);
}

/// The machine - the GPU offered once its pipelines are all made - where the training runs, the box that brings the
/// CPU's job onto the frame's thread, and Pause and Reset.
fn drawMachine(u: ui.Ui, s: *State) void {
    u.separatorText("Machine");
    var machine_choice: i32 = @backingInt(s.wanted_machine);
    _ = u.radioButton("CPU", &machine_choice, @backingInt(Machine.cpu));
    u.sameLine(.{});
    const progress: ?Pipe.PipelineProgress = gpuProgress(s);
    const gpu_is_ready: bool = if (progress) |made| made.isComplete() else false;
    u.beginDisabled(!gpu_is_ready);
    _ = u.radioButton("GPU", &machine_choice, @backingInt(Machine.gpu));
    u.endDisabled();
    s.wanted_machine = @fromBackingInt(machine_choice);
    if (progress) |made| {
        if (!made.isComplete()) {
            u.sameLine(.{});
            u.textColored(z.colors.slate_400, "preparing kernels {d}/{d}", .{ made.ready, made.total });
        }
    } else {
        u.sameLine(.{});
        u.textColored(z.colors.slate_400, "no GPU here", .{});
    }
    const runs_where: []const u8 = if (s.machine == .gpu)
        "the GPU, in batches of steps"
    else if (s.runs_inline)
        "THIS THREAD - the frame waits for every step"
    else if (!jobs.parallel())
        "this thread too - no workers here, so the frame hitches"
    else if (z.host.is_browser)
        "a Web Worker"
    else
        "a thread of the program's own";
    u.textWrapped("the training runs on {s}", .{runs_where});
    const switch_is_pending: bool = s.wanted_machine != s.machine;
    if (switch_is_pending) {
        u.textColored(z.colors.slate_400, "handing the training over", .{});
    }
    // The box is the CPU's: a batch on the GPU never runs on this thread.
    u.beginDisabled(s.machine == .gpu);
    if (u.checkbox("run on this thread", &s.runs_inline)) {
        s.worst_frame_gap_ms = 0;
    }
    u.endDisabled();
    const pause_label: []const u8 = if (s.paused) "Run" else "Pause";
    if (u.button(pause_label, .{})) {
        s.paused = !s.paused;
    }
    u.sameLine(.{});
    if (u.button("Reset", .{})) {
        s.fresh_start_due = true;
    }
}

/// What the training has done, the worst frame gap, and the dot that shows it.
fn drawReadout(u: ui.Ui, s: *State, time: f32) void {
    u.separatorText("Readout");
    const has_trained: bool = s.parameter_count > 0;
    if (has_trained) {
        u.text("step {d}   loss {d:.5}", .{ s.steps_since_reset, s.loss });
        u.text("{d:.0} steps a second", .{s.steps_per_second});
        const work_name: []const u8 = if (s.machine == .gpu) "a batch" else "a job";
        u.text("{s}: {d} steps, {d:.0} ms", .{ work_name, s.last_job_steps, s.last_job_seconds * 1000.0 });
        const frames_are_smooth: bool = s.worst_frame_gap_ms < dropped_frame_gap_ms;
        const gap_tint: Color = if (frames_are_smooth) z.colors.emerald_400 else z.colors.red_400;
        u.textColored(gap_tint, "frames {d:.1} ms, worst {d:.0} ms", .{ s.average_frame_ms, s.worst_frame_gap_ms });
        // Why the speeds differ (the plan's D10): what each machine pays for.
        const why_the_gpu_wins: []const u8 = "a GPU pays per dispatch, a CPU per multiplication: " ++
            "the wider the layers, the further ahead the GPU";
        u.textWrapped("{s}", .{why_the_gpu_wins});
    } else {
        u.textColored(z.colors.slate_400, "waiting for the first job", .{});
    }
    const has_failed: bool = s.failure_length > 0;
    if (has_failed) {
        u.textColored(z.colors.red_400, "the job FAILED:", .{});
        u.textColored(z.colors.red_400, "{s}", .{s.failure_name[0..s.failure_length]});
    }
    // THE SPEED LOG TO KEEP (`logSpeed`): a press saves it - a download in a browser, the system's dialog natively. The
    // button's file is offered again each time the log grows, and its area given each frame it shows (`z.userfile`).
    const log_has_grown: bool = s.speed_log.items.len != s.speed_log_offered_length;
    if (log_has_grown) {
        z.userfile.offerDownload(s.speed_log.items, speed_log_name);
        s.speed_log_offered_length = s.speed_log.items.len;
    }
    _ = u.button("save the log", .{});
    const save_min: Vec2 = u.getItemRectMin();
    const save_max: Vec2 = u.getItemRectMax();
    z.userfile.setSaveRect(save_min[0], save_min[1], save_max[0] - save_min[0], save_max[1] - save_min[1]);
    drawOrbitingDot(u, time);
}

/// How the network learns: the optimiser, its rate on a logarithmic slider, SGD's momentum.
fn drawAlgorithm(u: ui.Ui, s: *State) void {
    u.separatorText("Algorithm");
    var optimizer_index: i32 = @intCast(@backingInt(s.settings.optimizer));
    if (u.combo("optimiser", &optimizer_index, &optimizer_names, .{})) {
        s.settings.optimizer = @fromBackingInt(@intCast(optimizer_index));
        s.moments_reset_due = true;
    }
    const rate_range: ui.SliderOpts = .{ .min = smallest_rate_exponent, .max = largest_rate_exponent };
    if (u.slider("log10 of the rate", &s.rate_exponent, rate_range)) {
        s.settings.rate = exp10(s.rate_exponent);
    }
    u.textColored(z.colors.slate_400, "rate {d:.5}", .{s.settings.rate});
    const is_sgd: bool = s.settings.optimizer == .sgd;
    u.beginDisabled(!is_sgd);
    _ = u.slider("momentum", &s.settings.momentum, .{ .min = 0.0, .max = 0.99 });
    u.endDisabled();
}

/// The network's shape: a change starts it afresh, if the kit can hold it.
fn drawNetwork(u: ui.Ui, s: *State) void {
    u.separatorText("Network");
    var layer_count: u32 = s.settings.hidden_layer_count;
    if (u.slider("hidden layers", &layer_count, .{ .min = 1, .max = float(kernels.most_hidden_layers) })) {
        var wanted: Settings = s.settings;
        wanted.hidden_layer_count = layer_count;
        takeShape(s, wanted);
    }
    var layer_width: u32 = s.settings.hidden_width;
    const width_range: ui.SliderOpts = .{ .min = float(narrowest_layer), .max = float(kernels.widest_layer) };
    if (u.slider("width", &layer_width, width_range)) {
        var wanted: Settings = s.settings;
        wanted.hidden_width = layer_width;
        takeShape(s, wanted);
    }
    var activation_index: i32 = @intCast(@backingInt(s.settings.activation));
    if (u.combo("activation", &activation_index, &activation_names, .{})) {
        var wanted: Settings = s.settings;
        wanted.activation = @fromBackingInt(@intCast(activation_index));
        takeShape(s, wanted);
    }
    const has_shape_notice: bool = s.shape_notice_length > 0;
    if (has_shape_notice) {
        u.textColored(z.colors.red_400, "the kit refused that shape:", .{});
        u.textColored(z.colors.red_400, "{s}", .{s.shape_notice[0..s.shape_notice_length]});
    }
}

fn drawPanel(u: ui.Ui, s: *State, layout: Layout, time: f32) void {
    u.setNextWindowPos(layout.panel_position, .{});
    u.setNextWindowSize(layout.panel_size, .{});
    const panel_flags: ui.WindowFlags = .{ .no_move = true, .no_resize = true };
    const panel_title: []const u8 = "zimrnum fit - training in a job";
    const window: ui.WindowHandle = u.window(panel_title, .{ .flags = panel_flags }) orelse return;
    defer window.close();
    drawMachine(u, s);
    drawAlgorithm(u, s);
    drawNetwork(u, s);
    u.separatorText("Drawing");
    if (u.button("Clear", .{})) {
        s.drawing.clear();
    }
    u.sameLine(.{});
    if (u.button("Sine", .{})) {
        s.drawing.drawSine();
    }
    drawReadout(u, s, time);
}

fn update(f: *z.Frame, s: *State) void {
    // The frame that just ended, measured first: a batch landing now is steered by the frames it was in flight for,
    // this one's too. The worst since the first landing is measured past the start-up frames.
    const frame_gap_ms: f32 = f.time.delta_time * 1000.0;
    if (s.parameter_count > 0) {
        s.worst_frame_gap_ms = @max(s.worst_frame_gap_ms, frame_gap_ms);
    }
    s.average_frame_ms = lerp(s.average_frame_ms, frame_gap_ms, frame_average_rate);
    s.batch_worst_frame_ms = @max(s.batch_worst_frame_ms, frame_gap_ms);
    s.window_worst_frame_ms = @max(s.window_worst_frame_ms, frame_gap_ms);
    // Land what has come back, hand the training over if the toggle asks, then give the machine its next work.
    collectJob(s);
    collectBatch(s);
    switchMachines(s);
    switch (s.machine) {
        .cpu => submitJob(s),
        .gpu => submitBatch(s),
    }
    renewSpeed(f, s);
    z.clearViewport(f, z.colors.slate_900);
    const u: ui.Ui = s.ui_host.begin(f);
    const layout: Layout = pageLayout(f.window.widthf(), f.window.heightf());
    _ = u.scaleToViewport(layout.panel_size[0], layout.panel_characters);
    drawPlot(u, s, layout);
    drawPanel(u, s, layout, f.time.time);
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - zimrnum fit",
            .width = 1200,
            .height = 720,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
