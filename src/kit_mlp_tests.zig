//! kit_mlp's checks: an ordinary network trained on the GPU learning kit's CPU twin against zimrnum's autodiff, and
//! what its output scale does to a first action. Kept apart from `kit_mlp.zig` so that the file reaches the kernel
//! module only as the type parameter its callers pass: a build that names `gpu/zn_mlp.zig` as a module of its own (the
//! headless trainer) can then use `kit_mlp` without the same file arriving a second time by its path.

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const zn = @import("zn");
const gapInUnits = zm.gapInUnits;
const compute_host = @import("compute_host.zig");
const kit_mlp = @import("kit_mlp.zig");

const KitMlp = kit_mlp.KitMlp;
const KitLayer = kit_mlp.KitLayer;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const eql = std.mem.eql;
const nan = zm.nan;
const testing_allocator = std.testing.allocator;
const Random = std.Random;
const Spec = kit_mlp.Spec;
const float = zm.float;
const expect = std.testing.expect;

// -- The checks. A trainer is only worth building on if it computes what it claims. --

const zn_mlp = @import("gpu/zn_mlp.zig");
const Host = compute_host.Compute(zn_mlp);
const Mlp = KitMlp(zn_mlp);

/// The same network in plain Zig, so the kit's answer has something to be wrong against.
const Reference = struct {
    spec: Spec,
    params: []f32,

    fn forward(
        self: Reference,
        layers: []const KitLayer,
        input: []const f32,
        out: []f32,
    ) void {
        var buffer_a: [4096]f32 = undefined;
        var buffer_b: [4096]f32 = undefined;
        var from: []f32 = buffer_a[0..input.len];
        @memcpy(from, input);
        for (layers, 0..) |layer, i| {
            const to: []f32 = if (i % 2 == 0) buffer_b[0..layer.output_width] else buffer_a[0..layer.output_width];
            for (0..layer.output_width) |o| {
                var acc: f32 = self.params[layer.weights_offset + layer.input_width * layer.output_width + o];
                for (0..layer.input_width) |k| {
                    acc += from[k] * self.params[layer.weights_offset + k * layer.output_width + o];
                }
                to[o] = switch (layer.kind) {
                    .dense_tanh => zm.tanh(acc),
                    .dense_relu => @max(acc, 0.0),
                    .plain, .normed_mish, .normed_silu, .normed_simnorm => acc,
                };
            }
            from = to;
        }
        @memcpy(out, from);
    }
};

test "kit_mlp: the kit's forward pass is the one on paper" {
    const gpa: Allocator = testing_allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 5, .hidden = &.{ 7, 6 }, .outputs = 3, .rows = 4, .seed = 12 };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();

    var rng: Random.DefaultPrng = .init(5);
    const random: Random = rng.random();
    const inputs: []f32 = try gpa.alloc(f32, spec.rows * spec.inputs);
    defer gpa.free(inputs);
    for (inputs) |*x| {
        x.* = random.floatNorm(f32);
    }
    const got: []f32 = try gpa.alloc(f32, spec.rows * spec.outputs);
    defer gpa.free(got);
    try net.forward(inputs, got);

    const reference: Reference = .{ .spec = spec, .params = @constCast(net.parameters()) };
    var want: [3]f32 = undefined;
    var worst: f32 = 0.0;
    for (0..spec.rows) |r| {
        reference.forward(net.network.layers, inputs[r * spec.inputs ..][0..spec.inputs], &want);
        for (0..spec.outputs) |o| {
            worst = @max(worst, gapInUnits(got[r * spec.outputs + o], want[o], 1.0));
        }
    }
    try expect(worst < 1.0e-6);
}

fn referenceLoss(
    reference: Reference,
    layers: []const KitLayer,
    spec: Spec,
    inputs: []const f32,
    targets: []const f32,
) f32 {
    var out: [64]f32 = undefined;
    var total: f32 = 0.0;
    for (0..spec.rows) |r| {
        reference.forward(layers, inputs[r * spec.inputs ..][0..spec.inputs], out[0..spec.outputs]);
        for (0..spec.outputs) |o| {
            const diff: f32 = out[o] - targets[r * spec.outputs + o];
            total += diff * diff;
        }
    }
    return total / float(spec.rows * spec.outputs);
}

test "kit_mlp: one training step moves every weight the way Adam says" {
    const gpa: Allocator = testing_allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 4, .hidden = &.{5}, .outputs = 2, .rows = 3, .rate = 0.01, .seed = 3 };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();
    const before: []f32 = try gpa.dupe(f32, net.parameters());
    defer gpa.free(before);
    net.requestParameters(); // this test compares them afterwards, so it pays for them

    var rng: Random.DefaultPrng = .init(8);
    const random: Random = rng.random();
    const inputs: []f32 = try gpa.alloc(f32, spec.rows * spec.inputs);
    defer gpa.free(inputs);
    const targets: []f32 = try gpa.alloc(f32, spec.rows * spec.outputs);
    defer gpa.free(targets);
    for (inputs) |*x| {
        x.* = random.floatNorm(f32);
    }
    for (targets) |*t| {
        t.* = random.floatNorm(f32);
    }
    const loss: f32 = try net.trainStep(inputs, targets);

    // The gradient by finite differences, on the reference network: nudge a weight, see how the
    // loss moves. Then Adam's first step, which for t = 1 is the learning rate times the sign of
    // the gradient (the corrections cancel the moments' bias exactly), so every weight must have
    // moved by one rate in the right direction.
    var reference: Reference = .{ .spec = spec, .params = try gpa.dupe(f32, before) };
    defer gpa.free(reference.params);
    const after: []const f32 = net.parameters();
    var worst_direction: usize = 0;
    var checked: usize = 0;
    for (0..net.param_count) |j| {
        const h: f32 = 1.0e-3;
        const original: f32 = reference.params[j];
        reference.params[j] = original + h;
        const up: f32 = referenceLoss(reference, net.network.layers, spec, inputs, targets);
        reference.params[j] = original - h;
        const down: f32 = referenceLoss(reference, net.network.layers, spec, inputs, targets);
        reference.params[j] = original;
        const slope: f32 = (up - down) / (2.0 * h);
        const moved: f32 = after[j] - before[j];
        if (@abs(slope) < 1.0e-4) {
            continue; // a weight the batch says nothing about; Adam's epsilon dominates
        }
        checked += 1;
        if (moved * slope > 0.0) {
            worst_direction += 1; // moved UPHILL: wrong
        }
        // Adam's first step is the rate, whichever way the gradient points.
        if (@abs(@abs(moved) - spec.rate) > 0.2 * spec.rate) {
            worst_direction += 1;
        }
    }
    report.print("\n  kit_mlp: loss {d:.4}, {d} of {d} parameters checked against finite " ++
        "differences, {d} wrong\n", .{
        loss,
        checked,
        net.param_count,
        worst_direction,
    });
    try expect(checked > net.param_count / 2);
    try expect(worst_direction == 0);
}

test "kit_mlp: a residual network starts by doing nothing" {
    // The point of a small output scale: whatever the observation says, the first actions are
    // near zero, so the open-loop controller underneath is what drives the character while the
    // policy learns. Without it a fresh network shouts over a controller that was already nearly
    // right - which is what DReCon's Fig 9 measures the cost of.
    const gpa: Allocator = testing_allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 108, .hidden = &.{ 48, 48 }, .outputs = 27, .rows = 8, .seed = 6 };
    var rng: Random.DefaultPrng = .init(11);
    const random: Random = rng.random();
    const inputs: []f32 = try gpa.alloc(f32, spec.rows * spec.inputs);
    defer gpa.free(inputs);
    for (inputs) |*x| {
        x.* = random.floatNorm(f32);
    }
    const out: []f32 = try gpa.alloc(f32, spec.rows * spec.outputs);
    defer gpa.free(out);

    var quiet_spec: Spec = spec;
    quiet_spec.output_scale = 0.01;
    const quiet: *Mlp = try Mlp.init(gpa, &host, quiet_spec);
    defer quiet.deinit();
    try quiet.forward(inputs, out);
    var quiet_worst: f32 = 0.0;
    for (out) |y| {
        quiet_worst = @max(quiet_worst, gapInUnits(y, 0, 1.0));
    }

    const loud: *Mlp = try Mlp.init(gpa, &host, spec);
    defer loud.deinit();
    try loud.forward(inputs, out);
    var loud_worst: f32 = 0.0;
    for (out) |y| {
        loud_worst = @max(loud_worst, gapInUnits(y, 0, 1.0));
    }
    report.print("  kit_mlp: largest first action {d:.4} at output scale 0.01, {d:.4} left alone\n", .{
        quiet_worst,
        loud_worst,
    });
    // A tenth of the action range, before the controller's filter takes a fifth of it - so the
    // character feels about two hundredths of a radian on the first step, against a servo that is
    // already tracking the reference. That is the "nothing" being asked for; the untouched network
    // asks for thirty times more, which on a residual controller is noise over a working signal.
    try expect(quiet_worst < 0.2);
    try expect(loud_worst > 10.0 * quiet_worst);
}

test "kit_mlp: it learns something a network should find easy" {
    const gpa: Allocator = testing_allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 2, .hidden = &.{ 32, 32 }, .outputs = 1, .rows = 64, .rate = 0.01, .seed = 7 };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();
    const inputs: []f32 = try gpa.alloc(f32, spec.rows * spec.inputs);
    defer gpa.free(inputs);
    const targets: []f32 = try gpa.alloc(f32, spec.rows * spec.outputs);
    defer gpa.free(targets);
    var rng: Random.DefaultPrng = .init(21);
    const random: Random = rng.random();

    // f(x, y) = sin(3x) * y: smooth, nonlinear, and impossible for a linear model - so a falling
    // loss here means the hidden layers and their gradients are both doing something.
    var first: f32 = 0.0;
    var last: f32 = 0.0;
    for (0..400) |step| {
        for (0..spec.rows) |r| {
            const x: f32 = 2.0 * random.float(f32) - 1.0;
            const y: f32 = 2.0 * random.float(f32) - 1.0;
            inputs[r * 2] = x;
            inputs[r * 2 + 1] = y;
            targets[r] = @sin(3.0 * x) * y;
        }
        const loss: f32 = try net.trainStep(inputs, targets);
        if (step == 0) {
            first = loss;
        }
        last = loss;
    }
    report.print("  kit_mlp: sin(3x)*y over 400 steps, loss {d:.4} -> {d:.4}\n", .{ first, last });
    try expect(last < 0.1 * first);
}

test "kit_mlp: an SGD network steps every weight as zimrnum's sgdMomentum does, step after step" {
    // A network with `.optimizer = .sgd` trained three steps on the kit's CPU twin. Around each step, the weights
    // before it, the gradients its backward left (held to zimrnum elsewhere: "a whole Mlp on the kit is zimrnum's")
    // and a velocity kept here go through zimrnum's `sgdMomentum`: the weights after the step, and the velocity the kit
    // keeps in Adam's first moment, must be zimrnum's to the bit. So the step is the optimiser asked for, with its rate
    // and momentum, from a velocity that starts at zero and then does not.
    const gpa: Allocator = testing_allocator;
    var host: Host = .initCpu();
    const momentum: f32 = 0.9;
    const spec: Spec = .{
        .inputs = 3,
        .hidden = &.{ 5, 4 },
        .outputs = 2,
        .rows = 4,
        .rate = 0.02,
        .seed = 9,
        .optimizer = .{ .sgd = .{ .momentum = momentum } },
    };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const inputs: []f32 = try arena.alloc(f32, spec.rows * spec.inputs);
    const targets: []f32 = try arena.alloc(f32, spec.rows * spec.outputs);
    var rng: Random.DefaultPrng = .init(13);
    const random: Random = rng.random();
    for (inputs) |*input| {
        input.* = random.floatNorm(f32);
    }
    for (targets) |*target| {
        target.* = random.floatNorm(f32);
    }
    const shape: [1]usize = .{net.param_count};
    const weights: zn.Tensor(f32) = try .alloc(arena, &shape);
    const gradients: zn.Tensor(f32) = try .alloc(arena, &shape);
    const velocity: zn.Tensor(f32) = try .alloc(arena, &shape);
    velocity.fill(0);
    // The twin's buffers read back whole: every weight, gradient and velocity.
    host.element_count = net.param_count;
    for (0..3) |_| {
        const weights_before: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        @memcpy(weights.data, weights_before);
        _ = try net.trainStep(inputs, targets);
        const kit_gradients: []const f32 = host.readLatest(.grads) orelse return error.NoReadback;
        @memcpy(gradients.data, kit_gradients);
        try zn.sgdMomentum(f32, weights, weights, gradients, velocity, spec.rate, momentum);
        const kit_weights: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        const kit_velocity: []const f32 = host.readLatest(.adam_m) orelse return error.NoReadback;
        try expectEqualSlices(f32, weights.data, kit_weights);
        try expectEqualSlices(f32, velocity.data, kit_velocity);
    }
}

/// A network's training state COPIED off the kit's CPU twin - whose buffers the next run on any CPU pipe of the module
/// overwrites (claude.md:854) - the way a page takes it (`requestState`). Freed with `freeState`.
fn copiedState(gpa: Allocator, net: *Mlp) !kit_mlp.TrainingState {
    const weights: []f32 = try gpa.alloc(f32, net.param_count);
    errdefer gpa.free(weights);
    const first_moments: []f32 = try gpa.alloc(f32, net.param_count);
    errdefer gpa.free(first_moments);
    const second_moments: []f32 = try gpa.alloc(f32, net.param_count);
    errdefer gpa.free(second_moments);
    var state: kit_mlp.TrainingState = .{
        .weights = weights,
        .first_moments = first_moments,
        .second_moments = second_moments,
        .step_count = 0,
    };
    var request: Mlp.StateRequest = try net.requestState(gpa);
    // On the twin every buffer lands at once.
    const has_landed: bool = request.collect(&state);
    if (!has_landed) {
        request.discard();
        return error.NoReadback;
    }
    return state;
}

fn freeState(gpa: Allocator, state: kit_mlp.TrainingState) void {
    gpa.free(state.weights);
    gpa.free(state.first_moments);
    gpa.free(state.second_moments);
}

/// NaN over everything a step reads that it writes itself first - the activations, their gradients and the weights'
/// gradients, as an earlier run left them - so that a step reading any of it before writing it shows the poison.
fn poisonWorkingBuffers(gpa: Allocator, host: *Host, net: *const Mlp) !void {
    const acts_used: u32 = net.layout.acts_floats;
    const dacts_used: u32 = net.layout.dacts_floats;
    const poison_length: u32 = @max(acts_used, @max(dacts_used, net.param_count));
    const poison: []f32 = try gpa.alloc(f32, poison_length);
    defer gpa.free(poison);
    @memset(poison, nan(f32));
    host.upload(.acts, poison[0..acts_used]);
    host.upload(.dacts, poison[0..dacts_used]);
    host.upload(.grads, poison[0..net.param_count]);
}

test "kit_mlp: a training state taken out and put back goes on as if never interrupted, bit for bit" {
    // Two runs of six steps from one seed on the kit's CPU twin, one after the other (claude.md:854). One runs straight
    // through. The other stops after three: its state is taken out (`requestState`), a network from ANOTHER seed takes
    // it (`putState`), its working buffers are poisoned with NaN, and it steps three more. Had anything a step needs
    // lived outside the state - a moment, or the step count Adam's bias corrections read - the two runs would part, or
    // the poison would show. Adam, and SGD with momentum.
    const gpa: Allocator = testing_allocator;
    var host: Host = .initCpu();
    const optimizers = [_]kit_mlp.MlpOptimizer{ .adam, .{ .sgd = .{ .momentum = 0.9 } } };
    for (optimizers) |optimizer| {
        const spec: Spec = .{
            .inputs = 3,
            .hidden = &.{ 6, 5 },
            .outputs = 2,
            .rows = 4,
            .rate = 0.01,
            .seed = 5,
            .optimizer = optimizer,
        };
        var arena_state: ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();
        const inputs: []f32 = try arena.alloc(f32, spec.rows * spec.inputs);
        const targets: []f32 = try arena.alloc(f32, spec.rows * spec.outputs);
        var rng: Random.DefaultPrng = .init(23);
        const random: Random = rng.random();
        for (inputs) |*input| {
            input.* = random.floatNorm(f32);
        }
        for (targets) |*target| {
            target.* = random.floatNorm(f32);
        }

        const straight: *Mlp = try Mlp.init(gpa, &host, spec);
        defer straight.deinit();
        straight.setBatch(inputs, targets);
        straight.trainSteps(6);
        const straight_state: kit_mlp.TrainingState = try copiedState(gpa, straight);
        defer freeState(gpa, straight_state);

        const first_half: *Mlp = try Mlp.init(gpa, &host, spec);
        defer first_half.deinit();
        first_half.setBatch(inputs, targets);
        first_half.trainSteps(3);
        const halfway_state: kit_mlp.TrainingState = try copiedState(gpa, first_half);
        defer freeState(gpa, halfway_state);

        var another_seed: Spec = spec;
        another_seed.seed = 99;
        const second_half: *Mlp = try Mlp.init(gpa, &host, another_seed);
        defer second_half.deinit();
        second_half.putState(halfway_state);
        try poisonWorkingBuffers(gpa, &host, second_half);
        second_half.setBatch(inputs, targets);
        second_half.trainSteps(3);
        const resumed_state: kit_mlp.TrainingState = try copiedState(gpa, second_half);
        defer freeState(gpa, resumed_state);

        try expectEqual(straight_state.step_count, resumed_state.step_count);
        try expectEqualSlices(f32, straight_state.weights, resumed_state.weights);
        try expectEqualSlices(f32, straight_state.first_moments, resumed_state.first_moments);
        try expectEqualSlices(f32, straight_state.second_moments, resumed_state.second_moments);
    }
}

test "kit_mlp: the outputs a step leaves are the network's on the weights before it" {
    // One step, then the curve as a page asks for it (`requestOutputs`): every row's outputs must be the plain-Zig
    // reference's on the weights BEFORE the step - a step's forward is its first work and its update its last - and the
    // step must have moved the weights, or before and after could not be told apart.
    const gpa: Allocator = testing_allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{
        .inputs = 2,
        .hidden = &.{ 7, 5 },
        .outputs = 3,
        .act = .tanh,
        .rows = 6,
        .rate = 0.05,
        .seed = 17,
    };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const inputs: []f32 = try arena.alloc(f32, spec.rows * spec.inputs);
    const targets: []f32 = try arena.alloc(f32, spec.rows * spec.outputs);
    var rng: Random.DefaultPrng = .init(29);
    const random: Random = rng.random();
    for (inputs) |*input| {
        input.* = random.floatNorm(f32);
    }
    for (targets) |*target| {
        target.* = random.floatNorm(f32);
    }
    const weights_before: []f32 = try arena.dupe(f32, net.parameters());
    net.setBatch(inputs, targets);
    net.trainSteps(1);
    var outputs_request: Host.RangeRequest(.acts) = try net.requestOutputs(gpa);
    const outputs: []f32 = try arena.alloc(f32, spec.rows * spec.outputs);
    try expect(outputs_request.collect(outputs));
    const reference: Reference = .{ .spec = spec, .params = weights_before };
    var want: [3]f32 = undefined;
    var worst: f32 = 0.0;
    for (0..spec.rows) |row| {
        reference.forward(net.network.layers, inputs[row * spec.inputs ..][0..spec.inputs], &want);
        for (0..spec.outputs) |output_index| {
            const gap: f32 = gapInUnits(outputs[row * spec.outputs + output_index], want[output_index], 1.0);
            worst = @max(worst, gap);
        }
    }
    try expect(worst < 1.0e-6);
    const after_step: kit_mlp.TrainingState = try copiedState(gpa, net);
    defer freeState(gpa, after_step);
    try expect(!eql(f32, weights_before, after_step.weights));
}

test "kit_mlp: fits names the buffer a network would overflow, where init would assert" {
    // At the pages' sizes (`gpu/zn_mlp_sizes.zig`). Two layers of 512 hold 264,193 weights against 262,144: the
    // parameters. Four layers of 256 over 512 rows - the largest network zimrnum_fit offers - need 1,050,112 floats of
    // activation gradients against 1,048,576: each dense layer reserves a gradient for its outputs and one for its
    // inputs. Three layers of 64 over the same rows fit.
    const gpa: Allocator = testing_allocator;
    try Mlp.fits(gpa, .{ .inputs = 1, .hidden = &.{ 64, 64, 64 }, .outputs = 1, .rows = 512 });
    const too_many_weights: Spec = .{ .inputs = 1, .hidden = &.{ 512, 512 }, .outputs = 1, .rows = 4 };
    try expectError(error.KitParametersTooSmall, Mlp.fits(gpa, too_many_weights));
    const too_many_gradients: Spec = .{ .inputs = 1, .hidden = &.{ 256, 256, 256, 256 }, .outputs = 1, .rows = 512 };
    try expectError(error.KitGradientsTooSmall, Mlp.fits(gpa, too_many_gradients));
}

test "kit: the latent model's two joins match plain Zig, and touch nothing else" {
    // lat_advance and lat_take are single additions, so the bar is BITWISE: the CPU twin runs the
    // very functions the GPU runs, and anything short of equal would be a wrong index. Also that
    // neither writes outside its block - the columns beside z in a wide row hold the reference and
    // the action, and a join that spilt into them would corrupt the next step silently.
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    // The readback copies this many leading elements of every buffer; nothing asks by default.
    host.element_count = 128;
    const rows: u32 = 3;
    const count: u32 = 4;
    const stride: u32 = 7;
    var acts: [128]f32 = undefined;
    for (&acts, 0..) |*a, i| {
        a.* = float((i * 37) % 101) * 0.173 - 5.0;
    }
    host.upload(.acts, &acts);
    host.params = .{
        .rows = rows,
        .count = count,
        .stride = stride,
        .x_off = 0,
        .t_off = 32,
        .y_off = 64,
        .z_off = 96,
    };
    host.run("lat_advance", rows * count);
    const after: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    for (0..rows) |r| {
        for (0..stride) |c| {
            const at: usize = 64 + r * stride + c;
            if (c < count) {
                const expected: f32 = acts[r * stride + c] + acts[32 + r * count + c];
                try expectEqual(expected, after[at]);
                try expectEqual(expected, after[96 + r * count + c]);
            } else {
                // The next block's reference and action columns: untouched.
                try expectEqual(acts[at], after[at]);
            }
        }
    }

    var dacts: [64]f32 = undefined;
    for (&dacts, 0..) |*d, i| {
        d.* = float((i * 53) % 89) * 0.091 - 3.0;
    }
    host.upload(.dacts, &dacts);
    host.params = .{ .rows = rows, .count = count, .stride = stride, .dy_off = 0, .dx_off = 16 };
    host.run("lat_take", rows * count);
    const grads: []const f32 = host.readLatest(.dacts) orelse return error.NoReadback;
    for (0..rows * count) |i| {
        const r: usize = i / count;
        const c: usize = i % count;
        try expectEqual(dacts[i] + dacts[16 + r * stride + c], grads[i]);
    }
    // The source block is read, never written.
    for (16..16 + rows * stride) |i| {
        try expectEqual(dacts[i], grads[i]);
    }
}
