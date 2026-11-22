//! examples/zimrnum_fit/kernels.zig - the page's JOB: training on the GPU learning kit's own kernels, run by their CPU
//! twin, off the frame's thread (`src/notes/zimrnum_fit_plan.md`, 3.4).
//!
//! This file is compiled TWICE, as every example's `kernels.zig` is (see examples/worker_png/kernels.zig): into the
//! app, which takes its registry and its types, and into the kernel wasm a Web Worker instantiates - a wasm that
//! imports NOTHING, which the build asserts. For a kernel module's CPU twin that took the plan's S0: the kernel wasm is
//! built with no host, so every GPU call the twin's code can reach returns at once (`host.zig`'s `none`).
//!
//! ONE JOB, `trainSteps`: some steps of a network on the drawing, then its state and its curve back. A job is
//! STATELESS - a worker keeps nothing from one job to the next - so the page holds the training's state between jobs
//! and ships it in and out with each. A breakpoint in any of the kit's kernels it runs - `dense_fwd_tiled`, `adam`,
//! `sgd`, in src/gpu/zn_mlp.zig - stops inside this job: on the job's thread, natively.

const std = @import("std");
const z = @import("zimr");
const zn_mlp = @import("zn_mlp");
const sketch = @import("sketch.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const asBytes = std.mem.asBytes;
const sliceAsBytes = std.mem.sliceAsBytes;
const jobs = z.jobs;
const kit_mlp = z.kit_mlp;

/// The kit's CPU twin: the kernels' own code, run as plain loops over the kernel module's buffers.
const Pipe = z.Compute(zn_mlp);
const Network = kit_mlp.KitMlp(zn_mlp);

/// The most hidden layers a network may have, and the widest one (the plan's D8).
pub const most_hidden_layers: u32 = 4;
pub const widest_layer: u32 = 256;
/// The most weights the kit holds - each of its parameter buffers is this long - so the most a state carries.
const most_parameters: usize = zn_mlp.config.max;
/// The most floats a training state holds: three buffers of `most_parameters`. What the page keeps room for.
pub const most_state_floats: usize = 3 * most_parameters;

pub const Activation = enum(u32) { relu = 0, tanh = 1 };
pub const Optimizer = enum(u32) { adam = 0, sgd = 1 };

/// What a training job is asked to do - numbers alone, as a header must be (`jobs`): no pointer crosses into a worker.
pub const TrainHeader = extern struct {
    /// Steps to take, at least one.
    step_count: u32,
    /// The network: hidden layers of one width, each through relu or tanh.
    hidden_layer_count: u32,
    hidden_width: u32,
    activation: Activation,
    /// How the steps move the weights, and how far.
    optimizer: Optimizer,
    rate: f32,
    /// SGD's momentum; Adam keeps its own `kit_mlp.Spec` betas.
    momentum: f32,
    /// Whether the job starts the network afresh from `seed` - the first job, a Reset, a new shape - or goes on from
    /// the state at the head of the payload.
    starts_fresh: bool,
    seed: u32,
    /// The steps the state has taken: Adam's bias corrections read them.
    steps_taken: u32,
};

/// What a training job sends back before its numbers: the steps its state has taken now, how many parameters each of
/// the state's three buffers holds, and the loss before its last step.
pub const TrainResultHead = extern struct {
    steps_taken: u32,
    parameter_count: u32,
    loss: f32,
};

/// The floats after a result's head: the weights, the first and the second moments, then the curve - the last
/// forward's output at every sample.
pub fn resultFloatCount(parameter_count: usize) usize {
    return 3 * parameter_count + sketch.sample_count;
}

/// Whether a header's network is one this page offers: 1 to `most_hidden_layers` layers, 1 to `widest_layer` wide.
fn shapeIsOffered(header: TrainHeader) bool {
    const layers_in_range: bool = header.hidden_layer_count >= 1 and header.hidden_layer_count <= most_hidden_layers;
    const width_in_range: bool = header.hidden_width >= 1 and header.hidden_width <= widest_layer;
    return layers_in_range and width_in_range;
}

/// The network a header describes, as the kit's `Spec` - built here alone, so that the job, the page's question
/// "does it fit" (`fitsTheKit`) and the page's network on the GPU are the same network. `hidden_widths` holds the
/// layers' widths and must outlive the spec; the header's shape must be one the page offers (`shapeIsOffered`).
pub fn networkSpec(header: TrainHeader, hidden_widths: *[most_hidden_layers]u32) kit_mlp.Spec {
    hidden_widths.* = @splat(header.hidden_width);
    const activation: kit_mlp.DenseActivation = switch (header.activation) {
        .relu => .relu,
        .tanh => .tanh,
    };
    const optimizer: kit_mlp.MlpOptimizer = switch (header.optimizer) {
        .adam => .adam,
        .sgd => .{ .sgd = .{ .momentum = header.momentum } },
    };
    const spec: kit_mlp.Spec = .{
        .inputs = 1,
        .hidden = hidden_widths[0..header.hidden_layer_count],
        .outputs = 1,
        .act = activation,
        .rows = sketch.sample_count,
        .optimizer = optimizer,
        .rate = header.rate,
        .seed = header.seed,
    };
    return spec;
}

/// WHETHER A HEADER's NETWORK FITS THE KIT's BUFFERS - the job's own check, asked by the page before it takes a new
/// shape, and answered with the buffer too small (`KitMlp.fits`). A shape the page does not offer is refused too.
pub fn fitsTheKit(gpa: Allocator, header: TrainHeader) !void {
    if (!shapeIsOffered(header)) {
        return error.ShapeOutOfRange;
    }
    var hidden_widths: [most_hidden_layers]u32 = undefined;
    try Network.fits(gpa, networkSpec(header, &hidden_widths));
}

/// THE JOB: `step_count` steps of a network on the drawing's targets, on the kit's CPU twin.
///
///     payload   the state - weights | first moments | second moments - unless the job starts fresh; then the targets
///     out       a `TrainResultHead`, the state after the steps, and the curve
///
/// In a browser the twin's buffers are the worker's own; natively they are the program's, lent to this one job
/// (`registry`).
pub fn trainSteps(
    gpa: Allocator,
    header: TrainHeader,
    payload: []const u8,
    out: *Io.Writer,
) !void {
    const job_is_in_range: bool = shapeIsOffered(header) and header.step_count >= 1;
    if (!job_is_in_range) {
        return error.ShapeOutOfRange;
    }
    var hidden_widths: [most_hidden_layers]u32 = undefined;
    const spec: kit_mlp.Spec = networkSpec(header, &hidden_widths);
    // A shape too big for the kit is refused by the buffer's name: inside a worker an assert is a bare trap.
    try Network.fits(gpa, spec);
    var pipe: Pipe = .initCpu();
    const network: *Network = try Network.init(gpa, &pipe, spec);
    defer network.deinit();
    const parameter_count: usize = network.param_count;
    const state_floats: usize = if (header.starts_fresh) 0 else 3 * parameter_count;
    const payload_fits: bool = payload.len == (state_floats + sketch.sample_count) * @sizeOf(f32);
    if (!payload_fits) {
        return error.PayloadDoesNotFitTheNetwork;
    }
    // The payload's numbers, copied out: its bytes carry no alignment.
    const payload_floats: []f32 = try gpa.alloc(f32, state_floats + sketch.sample_count);
    @memcpy(sliceAsBytes(payload_floats), payload);
    if (!header.starts_fresh) {
        network.putState(.{
            .weights = payload_floats[0..parameter_count],
            .first_moments = payload_floats[parameter_count..][0..parameter_count],
            .second_moments = payload_floats[2 * parameter_count ..][0..parameter_count],
            .step_count = header.steps_taken,
        });
    }
    var inputs: [sketch.sample_count]f32 = undefined;
    for (&inputs, 0..) |*input, sample_index| {
        input.* = sketch.sampleX(sample_index);
    }
    network.setBatch(&inputs, payload_floats[state_floats..][0..sketch.sample_count]);
    network.trainSteps(header.step_count);

    // Back: the state after the steps and the curve - on the twin every request lands at once - and the loss.
    const result_floats: []f32 = try gpa.alloc(f32, resultFloatCount(parameter_count));
    var state: kit_mlp.TrainingState = .{
        .weights = result_floats[0..parameter_count],
        .first_moments = result_floats[parameter_count..][0..parameter_count],
        .second_moments = result_floats[2 * parameter_count ..][0..parameter_count],
        .step_count = 0,
    };
    var state_request: Network.StateRequest = try network.requestState(gpa);
    const state_has_landed: bool = state_request.collect(&state);
    var curve_request: Pipe.RangeRequest(.acts) = try network.requestOutputs(gpa);
    const curve_has_landed: bool = curve_request.collect(result_floats[3 * parameter_count ..][0..sketch.sample_count]);
    const loss: []const f32 = pipe.readLatest(.loss) orelse return error.NoLoss;
    const readbacks_have_landed: bool = state_has_landed and curve_has_landed;
    if (!readbacks_have_landed) {
        return error.ReadbackDidNotLand;
    }
    const head: TrainResultHead = .{
        .steps_taken = state.step_count,
        .parameter_count = @intCast(parameter_count),
        .loss = loss[0],
    };
    try out.writeAll(asBytes(&head));
    try out.writeAll(sliceAsBytes(result_floats));
}

/// The kernel table, exposed as every example's is, so that a page bundling several (the launcher) can merge them.
pub const job_kernels = .{
    .{ "trainSteps", trainSteps },
};

/// THE PAGE's REGISTRY. Its jobs work in the kit's CPU-twin buffers - the kernel module's globals - and the page LENDS
/// them: its frame never dispatches on a CPU pipe of the kit while a job runs, and its GPU pipe writes only the
/// device's buffers. So natively its jobs run on a thread, one at a time (`jobs.Globals.lent_to_one_job`); in a
/// browser each worker has buffers of its own. Its bounds: the largest state the kit holds, and the targets.
pub const registry = jobs.Registry(job_kernels, .{
    .max_input = @sizeOf(TrainHeader) + (3 * most_parameters + sketch.sample_count) * @sizeOf(f32),
    .max_output = @sizeOf(TrainResultHead) + resultFloatCount(most_parameters) * @sizeOf(f32),
    .globals = .lent_to_one_job,
});
