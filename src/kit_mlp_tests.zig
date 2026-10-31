//! kit_mlp's checks: an ordinary network trained on the GPU learning kit's CPU twin against zimrnum's autodiff, and
//! what its output scale does to a first action. Kept apart from `kit_mlp.zig` so that the file reaches the kernel
//! module only as the type parameter its callers pass: a build that names `gpu/zn_mlp.zig` as a module of its own (the
//! headless trainer) can then use `kit_mlp` without the same file arriving a second time by its path.

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const compute_host = @import("compute_host.zig");
const kit_mlp = @import("kit_mlp.zig");

const KitMlp = kit_mlp.KitMlp;
const KitLayer = kit_mlp.KitLayer;
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
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
                    .plain, .normed_mish, .normed_simnorm => acc,
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
            worst = @max(worst, @abs(got[r * spec.outputs + o] - want[o]));
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
        quiet_worst = @max(quiet_worst, @abs(y));
    }

    const loud: *Mlp = try Mlp.init(gpa, &host, spec);
    defer loud.deinit();
    try loud.forward(inputs, out);
    var loud_worst: f32 = 0.0;
    for (out) |y| {
        loud_worst = @max(loud_worst, @abs(y));
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
