//! examples/zimrnum_fit/kernels_tests.zig - the job's checks (`src/notes/zimrnum_fit_plan.md`, 3.9, S2), run by
//! `zig build test-zimrnum-fit` on the build's machine, compiled from the modules the kernel wasm is compiled from
//! (build.zig's `JobKernelModules`): the job as a worker runs it - the kit's CPU twin, with no host.
//!
//! Each check compares runs made one after the other on the twin, whose buffers are ONE set, shared by every CPU pipe
//! of the module (claude.md, "TWO CPU PIPES OF ONE MODULE ARE ONE SET OF BUFFERS"). So every buffer is poisoned with
//! NaN before each run - a run reading anything it neither wrote nor was given shows it - and what is compared are
//! the bytes each run sent back, copies, never the buffers.

const std = @import("std");
const Io = std.Io;
const z = @import("zimr");
const zm = @import("zm");
const zn_mlp = @import("zn_mlp");
const kernels = @import("kernels.zig");
const sketch = @import("sketch.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Writer = Io.Writer;
const asBytes = std.mem.asBytes;
const sliceAsBytes = std.mem.sliceAsBytes;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const testing_allocator = std.testing.allocator;
const nan = zm.nan;
const kit_mlp = z.kit_mlp;

const Pipe = z.Compute(zn_mlp);
const Network = kit_mlp.KitMlp(zn_mlp);

/// The checks' network: two hidden layers of 16, small enough that a Debug build steps it quickly.
const hidden_widths = [_]u32{ 16, 16 };
const rate: f32 = 0.01;
const momentum: f32 = 0.9;
const seed: u32 = 7;
/// The steps each check takes: enough for Adam's bias corrections and SGD's velocity to matter.
const step_count: u32 = 4;
/// The room a result is written into: far more than the checks' network sends back.
const result_room: usize = 1 << 20;
/// The longest of the twin's buffers, for one poison that covers them all.
const poison_length: usize = @max(zn_mlp.acts_len, zn_mlp.dacts_len, zn_mlp.config.max);

/// One network a check runs, said twice: as the page's header says it, and as the kit's own `Spec` says it - the
/// second written out here by hand, not built by the job's `networkSpec`, so that the job's reading of its header is
/// checked too.
const Case = struct {
    activation: kernels.Activation,
    optimizer: kernels.Optimizer,
    kit_activation: kit_mlp.DenseActivation,
    kit_optimizer: kit_mlp.MlpOptimizer,
};

/// Adam over tanh, SGD with momentum over relu: each of the header's two choices both ways.
const cases = [_]Case{
    .{ .activation = .tanh, .optimizer = .adam, .kit_activation = .tanh, .kit_optimizer = .adam },
    .{
        .activation = .relu,
        .optimizer = .sgd,
        .kit_activation = .relu,
        .kit_optimizer = .{ .sgd = .{ .momentum = momentum } },
    },
};

/// A job header for `steps` steps of a case's network.
fn caseHeader(
    check_case: Case,
    steps: u32,
    starts_fresh: bool,
    steps_taken: u32,
) kernels.TrainHeader {
    const train_header: kernels.TrainHeader = .{
        .step_count = steps,
        .hidden_layer_count = hidden_widths.len,
        .hidden_width = hidden_widths[0],
        .activation = check_case.activation,
        .optimizer = check_case.optimizer,
        .rate = rate,
        .momentum = momentum,
        .starts_fresh = starts_fresh,
        .seed = seed,
        .steps_taken = steps_taken,
    };
    return train_header;
}

/// NaN over every buffer of the kit's CPU twin that a job reads or writes.
fn poisonTheTwin(pipe: *Pipe, poison: []const f32) void {
    pipe.upload(.acts, poison[0..zn_mlp.acts_len]);
    pipe.upload(.dacts, poison[0..zn_mlp.dacts_len]);
    pipe.upload(.params, poison[0..zn_mlp.config.max]);
    pipe.upload(.grads, poison[0..zn_mlp.config.max]);
    pipe.upload(.adam_m, poison[0..zn_mlp.config.max]);
    pipe.upload(.adam_v, poison[0..zn_mlp.config.max]);
    pipe.upload(.loss, poison[0..zn_mlp.config.max]);
}

/// The job run as the page runs it on its own thread (`runJobHere`): an arena, a fixed writer. Returns a copy of
/// what it wrote, owned by the caller.
fn runJob(gpa: Allocator, train_header: kernels.TrainHeader, payload: []const u8) ![]u8 {
    var job_arena: ArenaAllocator = .init(gpa);
    defer job_arena.deinit();
    const room: []u8 = try job_arena.allocator().alloc(u8, result_room);
    var result_writer: Writer = .fixed(room);
    try kernels.trainSteps(job_arena.allocator(), train_header, payload, &result_writer);
    return gpa.dupe(u8, result_writer.buffered());
}

/// A result's head.
fn resultHead(result: []const u8) kernels.TrainResultHead {
    var head: kernels.TrainResultHead = undefined;
    @memcpy(asBytes(&head), result[0..@sizeOf(kernels.TrainResultHead)]);
    return head;
}

/// A result's training state - the weights and both moments - as bytes.
fn stateBytes(result: []const u8) []const u8 {
    const head: kernels.TrainResultHead = resultHead(result);
    const state_byte_count: usize = 3 * @as(usize, head.parameter_count) * @sizeOf(f32);
    return result[@sizeOf(kernels.TrainResultHead)..][0..state_byte_count];
}

/// A job's payload as the page builds it (`submitJob`): the state the last job sent back, unless there is none and
/// the job starts fresh, then the targets.
fn payloadFrom(gpa: Allocator, last_result: ?[]const u8, targets: []const f32) ![]u8 {
    const state_bytes: []const u8 = if (last_result) |result| stateBytes(result) else &.{};
    const target_bytes: []const u8 = sliceAsBytes(targets);
    const payload: []u8 = try gpa.alloc(u8, state_bytes.len + target_bytes.len);
    @memcpy(payload[0..state_bytes.len], state_bytes);
    @memcpy(payload[state_bytes.len..], target_bytes);
    return payload;
}

test "zimrnum_fit's job: its steps are KitMlp's own on the twin, bit for bit" {
    // The job, fresh, takes `step_count` steps; then KitMlp, from a `Spec` written out by hand, takes as many on the
    // same grid and targets. What the job sends back must be the network's own, to the bit: the steps taken, the
    // parameter count, the loss, the weights, both moments and the curve.
    const gpa: Allocator = testing_allocator;
    var pipe: Pipe = .initCpu();
    const poison: []f32 = try gpa.alloc(f32, poison_length);
    defer gpa.free(poison);
    @memset(poison, nan(f32));
    const targets: [sketch.sample_count]f32 = sketch.Sketch.sine().targets;
    var inputs: [sketch.sample_count]f32 = undefined;
    for (&inputs, 0..) |*input, sample_index| {
        input.* = sketch.sampleX(sample_index);
    }
    for (cases) |check_case| {
        poisonTheTwin(&pipe, poison);
        const payload: []u8 = try payloadFrom(gpa, null, &targets);
        defer gpa.free(payload);
        const job_result: []u8 = try runJob(gpa, caseHeader(check_case, step_count, true, 0), payload);
        defer gpa.free(job_result);

        poisonTheTwin(&pipe, poison);
        var direct_arena: ArenaAllocator = .init(gpa);
        defer direct_arena.deinit();
        const arena: Allocator = direct_arena.allocator();
        const spec: kit_mlp.Spec = .{
            .inputs = 1,
            .hidden = &hidden_widths,
            .outputs = 1,
            .act = check_case.kit_activation,
            .rows = sketch.sample_count,
            .optimizer = check_case.kit_optimizer,
            .rate = rate,
            .seed = seed,
        };
        const network: *Network = try Network.init(arena, &pipe, spec);
        network.setBatch(&inputs, &targets);
        network.trainSteps(step_count);
        const parameter_count: usize = network.param_count;
        const direct_floats: []f32 = try arena.alloc(f32, kernels.resultFloatCount(parameter_count));
        var state: kit_mlp.TrainingState = .{
            .weights = direct_floats[0..parameter_count],
            .first_moments = direct_floats[parameter_count..][0..parameter_count],
            .second_moments = direct_floats[2 * parameter_count ..][0..parameter_count],
            .step_count = 0,
        };
        var state_request: Network.StateRequest = try network.requestState(arena);
        try expect(state_request.collect(&state));
        var curve_request: Pipe.RangeRequest(.acts) = try network.requestOutputs(arena);
        try expect(curve_request.collect(direct_floats[3 * parameter_count ..][0..sketch.sample_count]));
        const loss: []const f32 = pipe.readLatest(.loss) orelse return error.NoLoss;

        const job_head: kernels.TrainResultHead = resultHead(job_result);
        try expectEqual(state.step_count, job_head.steps_taken);
        try expectEqual(parameter_count, job_head.parameter_count);
        try expectEqual(@as(u32, @bitCast(loss[0])), @as(u32, @bitCast(job_head.loss)));
        const job_floats: []const u8 = job_result[@sizeOf(kernels.TrainResultHead)..];
        try expectEqualSlices(u8, sliceAsBytes(direct_floats), job_floats);
    }
}

test "zimrnum_fit's job: one job of K steps is K jobs of one, the state carried in the bytes" {
    // As the page chains them: each job of one step is given the state the last one sent back and the steps it has
    // taken (Adam's bias corrections read them). Had any of the training lived outside those bytes - a moment, the
    // step count - or had a job read anything it was not given, the chain would part from the one long job.
    const gpa: Allocator = testing_allocator;
    var pipe: Pipe = .initCpu();
    const poison: []f32 = try gpa.alloc(f32, poison_length);
    defer gpa.free(poison);
    @memset(poison, nan(f32));
    const targets: [sketch.sample_count]f32 = sketch.Sketch.sine().targets;
    const fresh_payload: []u8 = try payloadFrom(gpa, null, &targets);
    defer gpa.free(fresh_payload);
    for (cases) |check_case| {
        poisonTheTwin(&pipe, poison);
        const long_job: []u8 = try runJob(gpa, caseHeader(check_case, step_count, true, 0), fresh_payload);
        defer gpa.free(long_job);

        poisonTheTwin(&pipe, poison);
        var chained: []u8 = try runJob(gpa, caseHeader(check_case, 1, true, 0), fresh_payload);
        defer gpa.free(chained);
        for (1..step_count) |_| {
            poisonTheTwin(&pipe, poison);
            const payload: []u8 = try payloadFrom(gpa, chained, &targets);
            defer gpa.free(payload);
            const steps_taken: u32 = resultHead(chained).steps_taken;
            const next: []u8 = try runJob(gpa, caseHeader(check_case, 1, false, steps_taken), payload);
            gpa.free(chained);
            chained = next;
        }
        try expectEqual(step_count, resultHead(chained).steps_taken);
        try expectEqualSlices(u8, long_job, chained);
    }
}
