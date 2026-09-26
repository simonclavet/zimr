//! kit_mlp - an ordinary multilayer perceptron, trained on the GPU kit.
//!
//! The kit (`src/gpu/zn_mlp.zig`) has everything an MLP needs - a dense layer forward, the three
//! pieces of its backward pass, a mean-squared error and Adam - but nothing that says "here is a
//! network, here are some examples, train it". So every learner so far has laid out its own buffer
//! offsets by hand, and the cartpole's does it for two networks and an unrolled window across
//! about forty fields. That is fine once and a liability three times: the world model, the policy
//! and the critic all want the same thing.
//!
//! So this is that thing. You give it layer sizes and a batch size; it gives you:
//!
//!     forward(inputs, outputs)          run the network
//!     trainStep(inputs, targets)        one Adam step on mean-squared error, returns the loss
//!     parameters() / setParameters()    the weights, for saving, loading and parity checks
//!
//! It is generic over the kernel module the same way the other learners are, so the same code runs
//! on the GPU and on the kit's CPU twin - which is where its tests run, and where anything built on
//! it can be checked against a plain-Zig reference without a GPU in sight.
//!
//! **One caveat, stated here because it will bite otherwise.** Reading anything back out of the kit
//! goes through `readLatest`, which on the CPU twin hands over the current buffer and on a GPU
//! hands over the most recent readback - typically a frame old. So `forward` and the loss returned
//! by `trainStep` are exact on the twin (where the tests run) and RECENT on a device. Training does
//! not care; anything that needs this frame's numbers on a GPU keeps them on the device.
//!
//! **The layout.** One contiguous block of parameters per layer, weights then biases, exactly as
//! `dense_fwd` reads them: W is `in_dim * out_dim` in input-major order, the bias follows. The
//! activations buffer holds the batch's input, then each layer's output, then the targets; the
//! gradient buffer mirrors it. Nothing is interleaved and nothing is padded, so an offset is always
//! a sum of sizes you can work out on paper - which matters when a kernel index is wrong and you
//! are trying to find out why.

const std = @import("std");
const zm = @import("zm");
const compute_host = @import("compute_host.zig");
const expectEqual = std.testing.expectEqual;

const Allocator = std.mem.Allocator;
const assertf = zm.assertf;
const float = zm.float;
const expect = std.testing.expect;

/// What a network is: its shape, how it is trained, and how many examples at a time.
pub const Spec = struct {
    inputs: u32,
    /// Hidden layer widths, in order. Empty makes a single linear layer.
    hidden: []const u32,
    outputs: u32,
    /// The activation on every hidden layer; the output layer is always linear, because a bounded
    /// output would quietly bound whatever the network is predicting.
    act: enum { relu, tanh } = .relu,
    /// Examples per step. Every buffer is sized for this, so it is fixed for the network's life.
    rows: u32 = 256,
    /// How large the OUTPUT layer starts, as a uniform range around zero. One leaves it alone.
    ///
    /// A residual policy wants this tiny. Its job is to correct an open-loop controller that is
    /// already nearly right, and a network whose first outputs are large drowns that controller in
    /// noise before it has learned anything - DReCon measured the difference (their Fig 9: 0.4
    /// against 0.2 mean reward at the start of training, and the gap never closes). It matters
    /// more here than for them, because our open-loop servo is stronger than theirs.
    output_scale: f32 = 1.0,
    rate: f32 = 1.0e-3,
    beta1: f32 = 0.9,
    beta2: f32 = 0.999,
    epsilon: f32 = 1.0e-8,
    seed: u64 = 1,
};

/// Where one layer's numbers live in the kit's buffers.
const Layer = struct {
    in_dim: u32,
    out_dim: u32,
    /// Into `params` / `grads` / `adam_m` / `adam_v`: the weights, with the bias right after.
    weights: u32,
    /// Into `acts`: this layer's input and its output.
    x: u32,
    y: u32,
    /// Into `dacts`: the gradient at this layer's output and at its input.
    dy: u32,
    dx: u32,
    act: u32,
};

pub fn KitMlp(comptime M: type) type {
    return struct {
        const Self = @This();

        gpa: Allocator,
        arena: std.heap.ArenaAllocator,
        pipe: *compute_host.Compute(M),
        spec: Spec,
        layers: []Layer,
        /// Total parameters, and where the targets and the loss sit.
        param_count: u32,
        targets_at: u32,
        /// A host-side mirror of the weights, as of the last `syncParameters`.
        cpu_params: []f32,
        adam_step: u32 = 0,

        pub fn init(gpa: Allocator, pipe: *compute_host.Compute(M), spec: Spec) !*Self {
            assertf(spec.inputs > 0 and spec.outputs > 0 and spec.rows > 0, @src(), "empty network", .{});
            const self: *Self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .arena = .init(gpa),
                .pipe = pipe,
                .spec = spec,
                .layers = undefined,
                .param_count = 0,
                .targets_at = 0,
                .cpu_params = undefined,
            };
            errdefer self.arena.deinit();
            const owned: Allocator = self.arena.allocator();

            // Lay the layers out: parameters end to end, activations the batch's input then every
            // layer's output, gradients mirroring the activations.
            // The hidden sizes are copied: a `Spec` is kept for the network's life, and a caller
            // that built its layer sizes in a scratch buffer would otherwise leave a dangling
            // slice behind.
            self.spec.hidden = try owned.dupe(u32, spec.hidden);
            const count: usize = spec.hidden.len + 1;
            self.layers = try owned.alloc(Layer, count);
            var params_at: u32 = 0;
            var acts_at: u32 = 0;
            var in_dim: u32 = spec.inputs;
            const input_at: u32 = acts_at;
            acts_at += spec.rows * spec.inputs;
            for (self.layers, 0..) |*layer, i| {
                const out_dim: u32 = if (i < spec.hidden.len) spec.hidden[i] else spec.outputs;
                layer.* = .{
                    .in_dim = in_dim,
                    .out_dim = out_dim,
                    .weights = params_at,
                    .x = if (i == 0) input_at else self.layers[i - 1].y,
                    .y = acts_at,
                    .dy = acts_at,
                    .dx = if (i == 0) input_at else self.layers[i - 1].y,
                    // The kernel module's own codes, not numbers that happen to match today.
                    .act = if (i < spec.hidden.len) switch (spec.act) {
                        .relu => @backingInt(M.Act.relu),
                        .tanh => @backingInt(M.Act.tanh),
                    } else @backingInt(M.Act.linear),
                };
                params_at += in_dim * out_dim + out_dim;
                acts_at += spec.rows * out_dim;
                in_dim = out_dim;
            }
            self.param_count = params_at;
            self.targets_at = acts_at;
            acts_at += spec.rows * spec.outputs;
            // Both halves have to fit the kit's buffers, and the parameters are the half that
            // surprises you: a 361 -> 512 -> 512 -> 108 network is half a million weights, twice
            // what the kit holds. Better a message naming the number than a kernel writing past
            // the end of a buffer.
            assertf(
                acts_at <= M.config.max and self.param_count <= M.config.max,
                @src(),
                "the network needs {d} activation slots and {d} parameters; the kit's buffers hold {d}",
                .{ acts_at, self.param_count, M.config.max },
            );

            self.cpu_params = try owned.alloc(f32, self.param_count);

            // He initialisation for relu, Xavier for tanh: the scale that keeps a signal's variance
            // from shrinking or exploding as it passes through the layers.
            var rng: std.Random.DefaultPrng = .init(spec.seed);
            const random: std.Random = rng.random();
            for (self.layers, 0..) |layer, i| {
                const last: bool = i + 1 == self.layers.len;
                const fan_in: f32 = float(layer.in_dim);
                const gain: f32 = if (spec.act == .relu) 2.0 else 1.0;
                const deviation: f32 = @sqrt(gain / fan_in);
                const weights: u32 = layer.in_dim * layer.out_dim;
                for (0..weights) |w| {
                    self.cpu_params[layer.weights + w] = if (last and spec.output_scale != 1.0)
                        spec.output_scale * (2.0 * random.float(f32) - 1.0)
                    else
                        deviation * random.floatNorm(f32);
                }
                @memset(self.cpu_params[layer.weights + weights ..][0..layer.out_dim], 0.0);
            }
            self.pipe.element_count = @max(self.param_count, 1);
            try self.uploadParameters();
            const zeros: []f32 = try gpa.alloc(f32, self.param_count);
            defer gpa.free(zeros);
            @memset(zeros, 0.0);
            pipe.upload(.adam_m, zeros);
            pipe.upload(.adam_v, zeros);
            // From here on, one number comes back per step - the loss. Anything wider is asked for
            // explicitly, because the readback copies its prefix out of EVERY buffer.
            pipe.element_count = 1;
            return self;
        }

        pub fn deinit(self: *Self) void {
            const gpa: Allocator = self.gpa;
            self.arena.deinit();
            gpa.destroy(self);
        }

        /// The weights as of the last successful `syncParameters`: every layer's W then its bias,
        /// end to end.
        pub fn parameters(self: *Self) []const f32 {
            return self.cpu_params;
        }

        /// Ask for the weights to come back with the next submitted work. They are not free - on a
        /// device this widens the readback of every buffer - so nothing asks by default.
        pub fn requestParameters(self: *Self) void {
            self.pipe.element_count = @max(self.pipe.element_count, self.param_count);
        }

        /// Copy the weights out of the latest readback into the host mirror; false if none has
        /// arrived yet, or if it was too short because nobody asked (`requestParameters`).
        pub fn syncParameters(self: *Self) bool {
            const params: []const f32 = self.pipe.readLatest(.params) orelse return false;
            if (params.len < self.param_count) {
                return false;
            }
            @memcpy(self.cpu_params, params[0..self.param_count]);
            return true;
        }

        pub fn setParameters(self: *Self, values: []const f32) !void {
            assertf(values.len == self.param_count, @src(), "{d} parameters, wanted {d}", .{
                values.len,
                self.param_count,
            });
            @memcpy(self.cpu_params, values);
            try self.uploadParameters();
        }

        fn uploadParameters(self: *Self) !void {
            self.pipe.upload(.params, self.cpu_params);
        }

        fn dispatch(self: *Self, comptime kernel: []const u8, params: M.Params, threads: u32) void {
            self.pipe.params = params;
            self.pipe.run(kernel, threads);
        }

        /// The forward pass, layer by layer, from `inputs` into `out`.
        ///
        /// Any number of rows up to the network's batch size: a rollout asks one state at a time,
        /// and padding it out to a full batch would be a hundred times the work for the same
        /// answer. The buffers are already the full size, so a short batch just leaves the tail
        /// untouched.
        pub fn forward(self: *Self, inputs: []const f32, out: []f32) !void {
            const rows: u32 = @intCast(inputs.len / self.spec.inputs);
            assertf(
                rows > 0 and rows <= self.spec.rows and inputs.len == rows * self.spec.inputs and
                    out.len == rows * self.spec.outputs,
                @src(),
                "forward got {d} inputs and {d} outputs, which is not {d} rows of {d} and {d}",
                .{ inputs.len, out.len, rows, self.spec.inputs, self.spec.outputs },
            );
            // What comes back: the kit copies the first `element_count` elements of each buffer,
            // and it has to be set before the work is submitted, not before the read.
            // Widen the readback just for this pass, then put it back: a caller training in a loop
            // should not silently start paying for a forward pass it did once.
            const last_end: u32 = self.layers[self.layers.len - 1].y + rows * self.spec.outputs;
            const previous: u32 = self.pipe.element_count;
            defer self.pipe.element_count = previous;
            self.pipe.element_count = last_end;
            self.pipe.uploadAt(.acts, 0, inputs);
            self.pipe.beginRecording();
            self.runForward(rows);
            self.pipe.submitRecording();
            const last: Layer = self.layers[self.layers.len - 1];
            const acts: []const f32 = self.pipe.readLatest(.acts) orelse return error.NoReadback;
            if (acts.len < last_end) {
                return error.NoReadback;
            }
            @memcpy(out, acts[last.y..][0..out.len]);
        }

        fn runForward(self: *Self, rows: u32) void {
            for (self.layers) |layer| {
                self.dispatch("dense_fwd", .{
                    .rows = rows,
                    .in_dim = layer.in_dim,
                    .out_dim = layer.out_dim,
                    .act = layer.act,
                    .x_off = layer.x,
                    .y_off = layer.y,
                    .w_off = layer.weights,
                }, rows * layer.out_dim);
            }
        }

        /// One step: forward, mean-squared error against `targets`, backward, Adam. Returns the
        /// loss BEFORE the step, which is what a training curve wants.
        pub fn trainStep(self: *Self, inputs: []const f32, targets: []const f32) !f32 {
            const rows: u32 = self.spec.rows;
            assertf(
                inputs.len == rows * self.spec.inputs and targets.len == rows * self.spec.outputs,
                @src(),
                "a step wants {d} in and {d} targets, got {d} and {d}",
                .{
                    rows * self.spec.inputs,
                    rows * self.spec.outputs,
                    inputs.len,
                    targets.len,
                },
            );
            self.adam_step += 1;
            // Only the loss comes back - ONE number. The readback copies the first `element_count`
            // elements of every buffer, so asking for the weights here would copy a prefix of all
            // seven of them on every step, to learn a single float. Ask for the weights with
            // `requestParameters` when you actually want them.
            self.pipe.element_count = @max(self.pipe.element_count, 1);
            self.pipe.uploadAt(.acts, 0, inputs);
            self.pipe.uploadAt(.acts, self.targets_at, targets);

            const last: Layer = self.layers[self.layers.len - 1];
            self.pipe.beginRecording();
            self.runForward(rows);
            // The loss, and the gradient it starts.
            self.dispatch("mse_value", .{
                .rows = rows,
                .out_dim = self.spec.outputs,
                .y_off = last.y,
                .t_off = self.targets_at,
            }, 1);
            self.dispatch("mse_bwd", .{
                .rows = rows,
                .out_dim = self.spec.outputs,
                .y_off = last.y,
                .t_off = self.targets_at,
                .dy_off = last.dy,
            }, rows * self.spec.outputs);
            // Backward, last layer first. The output layer is linear, so its activation derivative
            // is skipped - `act_bwd` with a linear act would be a no-op dispatch.
            var i: usize = self.layers.len;
            while (i > 0) {
                i -= 1;
                const layer: Layer = self.layers[i];
                if (layer.act != 0) {
                    self.dispatch("act_bwd", .{
                        .rows = rows,
                        .out_dim = layer.out_dim,
                        .act = layer.act,
                        .y_off = layer.y,
                        .dy_off = layer.dy,
                    }, rows * layer.out_dim);
                }
                self.dispatch("dense_bwd_w", .{
                    .rows = rows,
                    .in_dim = layer.in_dim,
                    .out_dim = layer.out_dim,
                    .x_off = layer.x,
                    .dy_off = layer.dy,
                    .w_off = layer.weights,
                }, layer.in_dim * layer.out_dim + layer.out_dim);
                if (i > 0) {
                    self.dispatch("dense_bwd_x", .{
                        .rows = rows,
                        .in_dim = layer.in_dim,
                        .out_dim = layer.out_dim,
                        .dy_off = layer.dy,
                        .dx_off = layer.dx,
                        .w_off = layer.weights,
                    }, rows * layer.in_dim);
                }
            }
            // Adam over every parameter at once: they are one contiguous block.
            // 1 / (1 - beta^t), worked out here because a kernel has no `pow`.
            const step: f32 = float(self.adam_step);
            self.dispatch("adam", .{
                .count = self.param_count,
                .w_off = 0,
                .rate = self.spec.rate,
                .beta1 = self.spec.beta1,
                .beta2 = self.spec.beta2,
                .epsilon = self.spec.epsilon,
                .correction1 = 1.0 / (1.0 - zm.pow(self.spec.beta1, step)),
                .correction2 = 1.0 / (1.0 - zm.pow(self.spec.beta2, step)),
            }, self.param_count);
            self.pipe.submitRecording();

            const loss: []const f32 = self.pipe.readLatest(.loss) orelse return error.NoReadback;
            if (loss.len < 1) {
                return error.NoReadback;
            }
            // If someone asked for the weights, they are in this readback too.
            _ = self.syncParameters();
            return loss[0];
        }
    };
}

// ── The checks. A trainer is only worth building on if it computes what it claims. ──

const zn_mlp = @import("gpu/zn_mlp.zig");
const Host = compute_host.Compute(zn_mlp);
const Mlp = KitMlp(zn_mlp);

/// The same network in plain Zig, so the kit's answer has something to be wrong against.
const Reference = struct {
    spec: Spec,
    params: []f32,

    fn forward(
        self: Reference,
        layers: []const Layer,
        input: []const f32,
        out: []f32,
    ) void {
        var buffer_a: [4096]f32 = undefined;
        var buffer_b: [4096]f32 = undefined;
        var from: []f32 = buffer_a[0..input.len];
        @memcpy(from, input);
        for (layers, 0..) |layer, i| {
            const to: []f32 = if (i % 2 == 0) buffer_b[0..layer.out_dim] else buffer_a[0..layer.out_dim];
            for (0..layer.out_dim) |o| {
                var acc: f32 = self.params[layer.weights + layer.in_dim * layer.out_dim + o];
                for (0..layer.in_dim) |k| {
                    acc += from[k] * self.params[layer.weights + k * layer.out_dim + o];
                }
                to[o] = switch (layer.act) {
                    1 => zm.tanh(acc),
                    2 => @max(acc, 0.0),
                    else => acc,
                };
            }
            from = to;
        }
        @memcpy(out, from);
    }
};

test "kit_mlp: the kit's forward pass is the one on paper" {
    const gpa: Allocator = std.testing.allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 5, .hidden = &.{ 7, 6 }, .outputs = 3, .rows = 4, .seed = 12 };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();

    var rng: std.Random.DefaultPrng = .init(5);
    const random: std.Random = rng.random();
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
        reference.forward(net.layers, inputs[r * spec.inputs ..][0..spec.inputs], &want);
        for (0..spec.outputs) |o| {
            worst = @max(worst, @abs(got[r * spec.outputs + o] - want[o]));
        }
    }
    try expect(worst < 1.0e-6);
}

test "kit_mlp: one training step moves every weight the way Adam says" {
    const gpa: Allocator = std.testing.allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 4, .hidden = &.{5}, .outputs = 2, .rows = 3, .rate = 0.01, .seed = 3 };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();
    const before: []f32 = try gpa.dupe(f32, net.parameters());
    defer gpa.free(before);
    net.requestParameters(); // this test compares them afterwards, so it pays for them

    var rng: std.Random.DefaultPrng = .init(8);
    const random: std.Random = rng.random();
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
        const up: f32 = referenceLoss(reference, net.layers, spec, inputs, targets);
        reference.params[j] = original - h;
        const down: f32 = referenceLoss(reference, net.layers, spec, inputs, targets);
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  kit_mlp: loss {d:.4}, {d} of {d} parameters checked against finite " ++
        "differences, {d} wrong\n", .{
        loss,
        checked,
        net.param_count,
        worst_direction,
    });
    try expect(checked > net.param_count / 2);
    try expect(worst_direction == 0);
}

fn referenceLoss(
    reference: Reference,
    layers: []const Layer,
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

test "kit_mlp: a residual network starts by doing nothing" {
    // The point of a small output scale: whatever the observation says, the first actions are
    // near zero, so the open-loop controller underneath is what drives the character while the
    // policy learns. Without it a fresh network shouts over a controller that was already nearly
    // right - which is what DReCon's Fig 9 measures the cost of.
    const gpa: Allocator = std.testing.allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 108, .hidden = &.{ 48, 48 }, .outputs = 27, .rows = 8, .seed = 6 };
    var rng: std.Random.DefaultPrng = .init(11);
    const random: std.Random = rng.random();
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  kit_mlp: largest first action {d:.4} at output scale 0.01, {d:.4} left alone\n", .{
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
    const gpa: Allocator = std.testing.allocator;
    var host: Host = .initCpu();
    const spec: Spec = .{ .inputs = 2, .hidden = &.{ 32, 32 }, .outputs = 1, .rows = 64, .rate = 0.01, .seed = 7 };
    const net: *Mlp = try Mlp.init(gpa, &host, spec);
    defer net.deinit();
    const inputs: []f32 = try gpa.alloc(f32, spec.rows * spec.inputs);
    defer gpa.free(inputs);
    const targets: []f32 = try gpa.alloc(f32, spec.rows * spec.outputs);
    defer gpa.free(targets);
    var rng: std.Random.DefaultPrng = .init(21);
    const random: std.Random = rng.random();

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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("  kit_mlp: sin(3x)*y over 400 steps, loss {d:.4} -> {d:.4}\n", .{ first, last });
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
