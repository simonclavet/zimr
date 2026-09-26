//! zimrnum_train - the XOR network trained on the GPU and on the CPU in the same page, one step
//! per frame, side by side.
//!
//! -- *** WHAT THIS DEMONSTRATES THAT THE SWEEP CANNOT --
//!
//! The sweep compares operations one at a time against zimrnum. This trains a network end to end
//! with the data never leaving the device: eight dispatches per step over one buffer set, and
//! only the loss comes back. The CPU side is zimrnum's own `Graph` and `Optimizer`, from the same
//! seed, stepped in lockstep. If the two loss curves agree, the whole GPU chain - forward,
//! backward, update - composes correctly; nothing about that is knowable from the operations
//! passing individually.
//!
//! ** THE CURVES AGREE TO ABOUT 1e-7 FOR THE FIRST FORTY STEPS AND THEN PART. The kernels'
//! gradients match zimrnum's to one ULP at step 0; XOR with a rate of 0.5 is a chaotic optimiser
//! and amplifies that ULP. Both converge. The page shows the early agreement and the final
//! losses, and the early agreement is the check - the final losses are two minima.
//!
//! * One step per frame, because `readLatest` returns the PREVIOUS dispatch's data. Running a
//! step and reading the loss in the same frame would pair step N's loss with step N-1's
//! weights, which is the stale-readback bug the sweep hit and fixed. A step per frame keeps the
//! pairing honest and makes the curve visible as it forms.

const std = @import("std");
const z = @import("zimr");
const zn = @import("zn");
const zn_train = @import("zn_train");

const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const zm = @import("zm");
const Color = zm.Color;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const samples: u32 = 4;
const inputs: u32 = 2;
const hidden: u32 = 4;
const outputs: u32 = 1;
const rate: f32 = 0.5;
const total_steps: usize = 600;
const seed: u64 = 20260904;

/// -- *** TEN STEPS PER FRAME, SO THE PAGE FINISHES IN ABOUT A SECOND --
///
/// One step per frame took five seconds on the phone - 600 frames at 60 Hz - which is too long
/// for a test someone runs by hand. The readback captures one `(loss, step)` per frame, so with
/// ten steps a frame only every tenth step is sampled; the milestones are chosen to land on
/// those. Frame 0 runs a single step so that step 0 itself is sampled.
const steps_per_frame: usize = 10;

/// Losses are recorded at these steps for the table. Every one is the LAST step of some frame:
/// 0 alone in frame 0, then multiples of ten.
const milestones = [_]usize{ 0, 10, 40, 100, 300, 590 };

fn pipelineEntries(comptime M: type) [M.kernels.len]z.Compute(M).KernelWgsl {
    var table: [M.kernels.len]z.Compute(M).KernelWgsl = undefined;
    inline for (M.kernels, 0..) |name, i| {
        table[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

const State = struct {
    font: z.Font,
    pipe: z.Compute(zn_train),

    // The CPU twin, zimrnum's own model.
    graph: zn.Graph(f32),
    loss_var: zn.Var,
    opt: zn.Optimizer(f32),
    /// THE ARENA ITSELF, BY VALUE - the caller owns it, as Zig expects.
    ///
    /// `initState` takes `s: *State`, so the arena is initialised at its FINAL address and the
    /// `Allocator` interface is minted from there. Nothing moves after the interface exists,
    /// which is the whole hazard a heap-allocated wrapper was guarding against.
    arena: std.heap.ArenaAllocator,

    /// Loss per step, both sides. A GPU entry is filed under the step the kernel wrote beside it,
    /// so the queue may be any number of frames behind.
    gpu_loss: [total_steps]f32,
    cpu_loss: [total_steps]f32,
    /// Which GPU steps have been read back at least once.
    gpu_seen: [total_steps]bool,
    /// How many steps have been dispatched, and how many GPU steps have a loss on record.
    dispatched: usize,
    read: usize,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);
    const ctx: zn.Ctx = zn.Ctx.init(gpa, seed);
    // The arena goes into its final home before anything is allocated from it, so the
    // interface below points where the arena will still be when this function returns.
    s.arena = std.heap.ArenaAllocator.init(gpa);
    const a: Allocator = s.arena.allocator();

    // Weights, once, shared by both sides: the GPU gets a copy uploaded, the CPU keeps these.
    const w1: zn.Tensor(f32) = try zn.Tensor(f32).alloc(a, &.{ inputs, hidden });
    const b1: zn.Tensor(f32) = try zn.Tensor(f32).alloc(a, &.{ 1, hidden });
    const w2: zn.Tensor(f32) = try zn.Tensor(f32).alloc(a, &.{ hidden, outputs });
    const b2: zn.Tensor(f32) = try zn.Tensor(f32).alloc(a, &.{ 1, outputs });
    ctx.rng.split(0).fillNormal(f32, w1.data);
    ctx.rng.split(1).fillNormal(f32, w2.data);
    b1.fill(0);
    b2.fill(0);
    const x: zn.Tensor(f32) = try zn.Tensor(f32).alloc(a, &.{ samples, inputs });
    @memcpy(x.data, &[_]f32{ 0, 0, 0, 1, 1, 0, 1, 1 });
    const t: zn.Tensor(f32) = try zn.Tensor(f32).alloc(a, &.{ samples, outputs });
    @memcpy(t.data, &[_]f32{ 0, 1, 1, 0 });

    var pipe: z.Compute(zn_train) = try z.Compute(zn_train).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &pipelineEntries(zn_train),
    );
    pipe.element_count = samples * hidden;
    pipe.params = .{
        .samples = samples,
        .inputs = inputs,
        .hidden = hidden,
        .outputs = outputs,
        .rate = rate,
    };
    // The packed layouts, matching the offsets `zn_train` derives from the same geometry.
    var in_buf: [samples * inputs + samples * outputs]f32 = undefined;
    @memcpy(in_buf[0 .. samples * inputs], x.data);
    @memcpy(in_buf[samples * inputs ..], t.data);
    var par_buf: [inputs * hidden + hidden + hidden * outputs + outputs]f32 = undefined;
    @memcpy(par_buf[0 .. inputs * hidden], w1.data);
    @memcpy(par_buf[inputs * hidden ..][0..hidden], b1.data);
    @memcpy(par_buf[inputs * hidden + hidden ..][0 .. hidden * outputs], w2.data);
    @memcpy(par_buf[inputs * hidden + hidden + hidden * outputs ..], b2.data);
    pipe.upload(.inputs, &in_buf);
    pipe.upload(.params, &par_buf);

    var graph: zn.Graph(f32) = .init(a);
    const gx: zn.Var = try graph.constant(x);
    const gt: zn.Var = try graph.constant(t);
    const gw1: zn.Var = try graph.parameter(w1);
    const gb1: zn.Var = try graph.parameter(b1);
    const gw2: zn.Var = try graph.parameter(w2);
    const gb2: zn.Var = try graph.parameter(b2);
    const h: zn.Var = try graph.tanh(try graph.add(try graph.matmul(gx, gw1), gb1));
    const y: zn.Var = try graph.add(try graph.matmul(h, gw2), gb2);
    const loss_var: zn.Var = try graph.mseLoss(y, gt);
    const opt: zn.Optimizer(f32) = try .init(
        a,
        &graph,
        &.{ gw1, gb1, gw2, gb2 },
        .{ .sgd = .{ .rate = rate } },
    );

    s.* = .{
        .font = font,
        .pipe = pipe,
        .graph = graph,
        .loss_var = loss_var,
        .opt = opt,
        .arena = s.arena,
        .gpu_loss = @splat(0),
        .cpu_loss = @splat(0),
        .gpu_seen = @splat(false),
        .dispatched = 0,
        .read = 0,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.pipe.deinit();
    // Everything else - weights, the graph, the optimiser's state - came from the scope.
    s.arena.deinit();
}

/// One training step on each side.
fn stepBoth(s: *State) void {
    if (s.dispatched >= total_steps) {
        return;
    }
    // GPU: eight dispatches, in dependency order. `loss_value` reads `y` before `step` changes
    // the weights it came from, so the loss read back belongs to these weights.
    s.pipe.run("fwd_hidden", samples * hidden);
    s.pipe.run("fwd_out", samples * outputs);
    s.pipe.run("loss_value", 1);
    s.pipe.run("loss_grad", samples * outputs);
    s.pipe.run("bwd_w2", hidden * outputs);
    s.pipe.run("bwd_h", samples * hidden);
    s.pipe.run("bwd_w1", inputs * hidden);
    s.pipe.run("step", inputs * hidden + hidden + hidden * outputs + outputs);

    // CPU: the same three lines every zimrnum training loop is.
    s.graph.recompute() catch return;
    s.graph.backward(s.loss_var) catch return;
    s.cpu_loss[s.dispatched] = s.graph.valueOf(s.loss_var).data[0];
    s.opt.step(&s.graph) catch return;
    s.dispatched += 1;
}

fn update(f: *z.Frame, s: *State) void {
    // File whatever loss has arrived under the step the kernel labelled it with. The queue may
    // be several frames behind, and the same readback may be seen more than once.
    if (s.pipe.readLatest(.loss)) |loss| {
        // The kernel writes `step + 1`; zero means the buffer has not been written yet.
        const label: usize = @trunc(@max(loss[1], 0));
        if (label > 0 and label - 1 < total_steps and !s.gpu_seen[label - 1]) {
            s.gpu_loss[label - 1] = loss[0];
            s.gpu_seen[label - 1] = true;
            s.read += 1;
        }
    }
    // Frame 0 runs one step so step 0 is sampled; every later frame runs ten, and the loss
    // read back is the last of them.
    const burst: usize = @min(if (s.dispatched == 0) 1 else steps_per_frame, total_steps - s.dispatched);
    // -- ** THE STEP LABEL IS SET ONCE PER FRAME, TO THE BURST'S LAST STEP --
    //
    // Only the last step's loss survives in the buffer at frame end, so only its label matters.
    // Setting it per step changed the uniform ten times a frame, and the smoke's queue-timeline
    // check flagged the clobber: `syncParamsUniform` skips identical rewrites, but ten distinct
    // values are ten writes. One value, one write, and the label is exactly right.
    if (burst > 0) {
        s.pipe.params.step = @intCast(s.dispatched + burst - 1);
    }
    var i: usize = 0;
    while (i < burst) : (i += 1) {
        stepBoth(s);
    }

    z.clearViewport(f, z.colors.slate_900);
    var y: f32 = 10;
    textRow(f, s, &y, z.colors.amber_400, 16, "zimrnum train - XOR on the GPU and the CPU, {d}/{d} steps", .{
        s.dispatched,
        total_steps,
    });
    textRow(f, s, &y, z.colors.slate_400, 12, "    step        gpu loss        cpu loss     |gpu - cpu|", .{});
    var worst_early: f32 = 0;
    for (milestones) |m| {
        if (!s.gpu_seen[m]) {
            continue;
        }
        const gap: f32 = @abs(s.gpu_loss[m] - s.cpu_loss[m]);
        if (m <= 40) {
            worst_early = @max(worst_early, gap);
        }
        textRow(f, s, &y, z.colors.slate_200, 12, "    {d: <7} {d: <15.7} {d: <12.7} {e}", .{
            m,
            s.gpu_loss[m],
            s.cpu_loss[m],
            gap,
        });
    }
    // The verdict waits for the last milestone's loss to arrive, not for every step: with ten
    // steps a frame most steps are never sampled, and that is by design.
    if (s.dispatched >= total_steps and s.gpu_seen[milestones[milestones.len - 1]]) {
        y += 6;
        const last: usize = milestones[milestones.len - 1];
        const gpu_ok: bool = s.gpu_loss[last] < 1.0e-3;
        const cpu_ok: bool = s.cpu_loss[last] < 1.0e-3;
        const early_ok: bool = worst_early < 1.0e-5;
        const tint: Color = if (gpu_ok and cpu_ok and early_ok) z.colors.emerald_400 else z.colors.red_400;
        textRow(f, s, &y, tint, 14, "{s}: both converged ({s}), early agreement {e} ({s})", .{
            if (gpu_ok and cpu_ok and early_ok) "PASS" else "FAIL",
            if (gpu_ok and cpu_ok) "yes" else "NO",
            worst_early,
            if (early_ok) "within 1e-5" else "TOO FAR",
        });
        textRow(f, s, &y, z.colors.slate_400, 12, "    early agreement is the check; final losses are two minima", .{});
    }
    z.endDrawing(f.gl);
}

fn textRow(
    f: *z.Frame,
    s: *State,
    y: *f32,
    color: Color,
    size: f32,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var buf: [160]u8 = undefined;
    const text: []const u8 = bufPrint(&buf, fmt, args) catch return;
    f.gl.text(.{ 12, y.* }, text, .{ .size = size, .color = color, .font = &s.font });
    y.* += size + 4;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - zimrnum train",
            .width = 900,
            .height = 360,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
