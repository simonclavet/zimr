//! zn-conformance - the CPU reference the GPU sweep is judged against.
//!
//! ---- WHY THIS IS ENGINE CODE AND NOT PART OF A DEMO ----
//!
//! This table is **the only thing that proves zimrnum's CPU and GPU answers agree**. It carries,
//! per operation: the kernel entry point, the CPU function that defines the right answer, the
//! tolerance that answer is allowed to differ by, and the input distribution the comparison is
//! meaningful over.
//!
//! It lived inside `examples/zimrnum_field/zimrnum_field.zig`, wrapped in 900 lines of field
//! rendering, reachable only by building a visualisation. The kernels moved to `src/gpu/` first;
//! the thing that JUDGES them had at least as much claim to be here.
//!
//! ---- WHAT A TOLERANCE OF ZERO MEANS ----
//!
//! Many rows carry `.tol = 0`, which is not optimism. A mask returns a literal 0 or 1; `leaky
//! relu` is a compare and a select; `max axis0` and `argmax axis0` are SELECTIONS - they return
//! an input value unchanged rather than computing a new one. There is no arithmetic to round, so
//! any difference at all is a bug rather than drift, and a non-zero tolerance there would hide
//! exactly the failure worth catching.
//!
//! Rows that do accumulate - `sum`, `mean`, matmul - carry a real tolerance, because summation
//! order differs between a serial CPU loop and a parallel reduction and the difference is
//! arithmetic rather than error.

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const inf = zm.inf;
const isFinite = zm.isFinite;
const expect = std.testing.expect;
const eql = std.mem.eql;

/// A tensor of the sweep's fixed element type, spelled once.
// ---- THE SWEEP'S PROBLEM SIZE AND ITS FIXED PARAMETERS ----
//
// These moved here with the table because they are part of the SPEC, not the rendering: the
// field is `side` x `side` because the comparison needs that many elements, and every
// parameter below is pinned so both backends use the same value. The sweep is a comparison,
// not a training run - a learning rate that differed between them would make every row
// disagree for a reason that is not a bug.
pub const side: usize = 64;
pub const count: u32 = side * side;

/// Fixed so both backends use the same value; the sweep is a comparison, not a training run.
pub const learning_rate: f32 = 0.1;

/// Layer normalisation's stabiliser. PyTorch's default, so the numbers are comparable with
/// what a reader is likely to have seen elsewhere.
pub const layernorm_epsilon: f32 = 1.0e-5;

/// Bounds for the `clamp` row, chosen to sit INSIDE the noise field's range so the row exercises
/// both branches - a clamp whose bounds enclose the data clamps nothing and tests nothing.
/// Slope for `leaky relu` and alpha for `elu`. 0.25 rather than PyTorch's 0.01 so the negative
/// branch is clearly visible in the heatmap instead of being a rounding-sized sliver.
pub const elu_alpha: f32 = 0.25;

/// Huber's threshold for the sweep, chosen so both branches are exercised on the noise field.
/// Momentum for the `sgd momentum` row, matching the kernel's `delta`.
pub const momentum: f32 = 0.9;

pub const huber_delta: f32 = 1.0;

/// Elements in a 2x2-pooled field.
pub const pooled: u32 = (side / 2) * (side / 2);

pub const clamp_lo: f32 = -0.5;
pub const clamp_hi: f32 = 0.5;

/// The re-run button's size. Its POSITION follows the layout and is stored on the `State` when
/// the frame draws it, so the hit test and the drawing cannot drift apart - a button drawn in one
/// place and pressed in another is the classic version of this bug, and a hardcoded `y = 4` had
/// it sitting on top of the summary line before this was measured.
pub const Tn = zn.Tensor(f32);

/// Which pipeline an entry belongs to, which is also which buffers it reads.
pub const Kind = enum { binary, unary, matmul };

/// One row of the sweep: everything that differs between kernels, in one place.
///
/// -- *** ONE TABLE INSTEAD OF FOUR PARALLEL SWITCHES --
///
/// Adding a kernel used to mean eight edits: an enum variant, an arm in `next`, one in `label`,
/// one in `tolerance`, one in `isUnary`, one in `buildFields`, one in the dispatch, and a slot in
/// two hand-written array literals. Eight chances to add a row that reports the wrong reference,
/// which is exactly the bug that produced `FAIL add worst 23.9` earlier.
///
/// Now it is ONE `Case` here plus the kernel itself plus `build.zig`'s entry - and the drift gate
/// catches the last of those. The `cpu` field carries the reference implementation inline, so a
/// row's GPU entry and its oracle are written on the same line and cannot drift apart.
pub const Case = struct {
    label: []const u8,
    /// Absolute allowance. Zero where both sides do the same flops in the same order.
    tol: f32,
    /// -- *** AN ALLOWANCE THAT SCALES WITH THE ROW'S MAGNITUDE --
    ///
    /// An absolute bar of zero is only ever right when the output is O(1) or the operation is
    /// exact. `div` is neither: measured, its outputs peak at 102.5, where **one ULP of f32 is
    /// 1.22e-5** - and the device's worst deviation was **1.9e-6, six times SMALLER than a single
    /// ULP at that magnitude**. The kernel was correct; the bar was wrong.
    ///
    /// So a row may also allow `ulps` units in the last place OF ITS OWN PEAK VALUE. That is a
    /// statement about precision rather than about a number someone picked, and it moves with the
    /// data instead of needing a new constant when the inputs change.
    ulps: f32 = 0,
    kind: Kind,
    /// The kernel entry name. Comptime, because `Compute.run` needs it so.
    entry: [:0]const u8,
    /// The zimrnum implementation this row is checked against. Unary rows ignore `b`.
    cpu: *const fn (out: Tn, a: Tn, b: Tn) anyerror!void,
    /// How many threads to dispatch. Defaults to one per element, which is right for everything
    /// elementwise - but a ROW-WISE kernel wants one per row, and dispatching 4096 threads for
    /// 64 rows would have 4032 of them return immediately from the guard. Making it explicit
    /// keeps the launch geometry next to the kernel it belongs to.
    threads: u32 = count,
    /// -- *** HOW MANY OUTPUTS THIS ROW ACTUALLY PRODUCES --
    ///
    /// A REDUCTION does not fill the output buffer. `sum_axis0` writes 64 values and `sum_all`
    /// writes one; comparing all 4096 would be comparing whatever the previous dispatch left
    /// behind, and the row would fail for a reason having nothing to do with the kernel.
    ///
    /// * Defaulting to one per element leaves every elementwise row untouched and makes the
    /// reduction rows state their own shape rather than the harness guessing it.
    out_len: u32 = count,
    /// -- *** WHICH INPUT THIS ROW IS ENTITLED TO --
    ///
    /// `sqrt` and `log` are **undefined** below zero in WGSL - not NaN, undefined - so an
    /// implementation may return NaN, an infinity, zero or anything else. Measured on device:
    /// both rows reported `inf`, because the CPU produced NaN and the GPU did not agree. That is
    /// not a defect in either; it is a comparison of two undefined results, and it says nothing.
    ///
    /// * So a row may ask for the POSITIVE field instead - `|noise| + 0.5`, strictly above zero
    /// so `log` is defined too. That is what a caller does: check the domain before calling. The
    /// row then tests the OPERATION rather than two implementations' undefined behaviour.
    /// Which field this row's input comes from.
    ///
    /// * `unit` was added when `atanh` failed on the device with a worst of **inf**: `atanh` is
    /// +/-infinity at +/-1 and NaN beyond, so on the noise field BOTH sides return inf and their
    /// difference is NaN - which is not <= any bar. The row was asking a question with no finite
    /// answer, and the fix is a field the function is defined on rather than a wider tolerance.
    /// `tiny` was added when `zm.tanh` turned out to be 1.0 relative error at f32 NEAR ZERO and
    /// the sweep had never noticed: a normal(0,1) field has no values small enough for
    /// cancellation to bite. **A test's input distribution decides which bugs it can see**, and
    /// every row here had been asked about one distribution.
    input: enum { noise, positive, unit, tiny } = .noise,
};

pub const cases = [_]Case{
    // ---- THE FIRST REINFORCEMENT-LEARNING ROWS ----
    //
    // The sweep covered 92 kernels of elementwise, reduction and matmul arithmetic and NOT ONE
    // RL operation. `ppoClipSample` and `cartpoleContinuousStep` were both written scalar-first - no
    // allocation, no error union, no slice - precisely so a kernel could call the SAME function
    // the CPU loop calls, rather than a transcription of it. Two transcriptions is how a
    // CPU/GPU comparison becomes circular: it compares a formula against itself.
    //
    // The SPIR-V probe already proved these COMPILE for a device. Only a row proves the device
    // agrees on the numbers.
    // ---- ADAM AT A STEP THAT IS NOT THE FIRST ----
    //
    // The `adam step` row below fills both moments with zero, which tests the one update per
    // training run where the moments are empty. This row tests the other few thousand: moments
    // carrying history, and bias correction at step 5 rather than step 1.
    //
    // The gap is worth naming because it has the shape of a real and expensive bug. A
    // predecessor project's GPU-resident SAC learned correctly for one update and then diverged
    // - eleven hypotheses, none confirmed - and "nearly right for one step, systematically wrong
    // thereafter" is precisely what a first-step-only optimiser produces.
    // ---- SAC's SQUASH CORRECTION, AT SATURATION ----
    //
    // The input is scaled by 12 inside both sides so the field reaches pre-squash values where
    // `tanh` rounds to exactly 1 in f32. That is where the textbook spelling
    // `-log(1 - tanh(u)^2)` becomes `log(0)` - and it is where a converged SAC policy spends
    // most of its time, so the correction is needed most precisely where the naive form fails.
    //
    // A row fed ordinary small values would agree perfectly and check nothing that matters.
    .{
        .label = "squash correction",
        // `exp` and `log1p`, both transcendental.
        .tol = 0,
        .ulps = 8,
        .kind = .binary,
        .entry = "squash_correction",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                for (o.data, a.data) |*out, u| {
                    out.* = zn.squashCorrection(f32, u * 12.0);
                }
            }
        }.f,
    },
    .{
        .label = "polyak follow",
        // A multiply and two adds - no accumulation and no transcendental, so a real zero.
        .tol = 0,
        .kind = .binary,
        .entry = "polyak_follow",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                // `a` is the target, `b` the online network. Copied into the output first because
                // `polyakUpdate` moves its target IN PLACE - which is how the caller uses it, and
                // so is the behaviour worth checking rather than a pure variant that nothing runs.
                @memcpy(o.data, a.data);
                return zn.polyakUpdate(f32, o, b, 0.005);
            }
        }.f,
    },
    .{
        .label = "adam step (warm)",
        // `sqrt` and a divide, so the same ULPS allowance the transcendental rows carry.
        .tol = 0,
        .ulps = 8,
        .kind = .binary,
        .entry = "adam_step_warm",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                const step: usize = 5;
                const hyper: zn.Adam = .{ .rate = 0.01, .beta1 = 0.9, .beta2 = 0.999, .epsilon = 1e-8 };
                for (o.data, a.data, b.data) |*out, weight, gradient| {
                    // The same history the kernel derives, built the same way.
                    var moment: [1]f32 = .{0.3 * gradient};
                    var velocity: [1]f32 = .{0.2 * gradient * gradient};
                    var one_weight: [1]f32 = .{weight};
                    var one_grad: [1]f32 = .{gradient};
                    var one_out: [1]f32 = .{0};
                    const shape = [_]usize{ 1, 1 };
                    try zn.adamStep(
                        f32,
                        try Tn.fromSlice(&one_out, &shape),
                        try Tn.fromSlice(&one_weight, &shape),
                        try Tn.fromSlice(&one_grad, &shape),
                        try Tn.fromSlice(&moment, &shape),
                        try Tn.fromSlice(&velocity, &shape),
                        hyper,
                        step,
                    );
                    out.* = one_out[0];
                }
            }
        }.f,
    },
    .{
        .label = "disc reward",
        // ULPS, learned from `ppo clip`: the reward is a `sigmoid` and a `log`, both
        // transcendental, so a CPU libm and a GPU's hardware approximation are not required to
        // agree in the last bit. Claiming zero here would repeat this morning's mistake.
        .tol = 0,
        .ulps = 8,
        .kind = .binary,
        .entry = "disc_reward",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                for (o.data, a.data, b.data) |*out, logit, reward_scale| {
                    out.* = zn.discriminatorReward(f32, logit * 20.0, reward_scale, 1.0e-4);
                }
            }
        }.f,
    },
    .{
        .label = "ppo clip",
        // ---- NOT ZERO, AND WHY IT WAS, BRIEFLY ----
        //
        // This row shipped at `.tol = 0` reasoning "no accumulation, so summation order cannot
        // differ and there is nothing to round differently". The device disagreed by 3.8e-6 and
        // the reasoning was wrong: **the surrogate opens with `@exp`**, and a transcendental is
        // not required to be bit-identical between a CPU libm and a GPU's hardware
        // approximation. `sin`, `cos`, `log` and `exp` all carry allowances here for exactly
        // that, and the clamp and `@min` that follow propagate the difference rather than
        // absorbing it.
        //
        // ULPS rather than an absolute bar, because the surrogate's magnitude follows the
        // advantage: a fixed `1e-5` would be loose at small advantages and tight at large ones.
        .tol = 0,
        .ulps = 8,
        .kind = .binary,
        .entry = "ppo_clip",
        .cpu = struct {
            // Both sides call `ppoClipSample`. That is the point - a row whose CPU side re-derived
            // the formula would pass while both were wrong, which is exactly what this row is for.
            //
            // TOLERANCE ZERO. The surrogate is an `exp`, a clamp, two multiplies and a `@min` - no
            // accumulation, so summation order cannot differ and there is nothing to round
            // differently. A nonzero bar here would be accepting a real disagreement.
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                for (o.data, a.data, b.data) |*out, log_ratio, advantage| {
                    out.* = zn.ppoClipSample(f32, log_ratio, 0.0, advantage, 0.2);
                }
            }
        }.f,
    },
    .{
        .label = "cartpole pole",
        // Same correction as `ppo clip`, same cause named plainly: the dynamics call `sin` and
        // `cos`. The device disagreed by 1.2e-7 - one ULP at this magnitude - which is a
        // transcendental doing what transcendentals do, not a bug.
        //
        // I claimed zero because "both sides take the same path through the same `zm`
        // functions". They take the same path through the same SOURCE; on a device that source
        // becomes the hardware's `sin`, not the CPU's. **Calling one function from both sides
        // guarantees the same formula, never the same last bit.**
        .tol = 0,
        .ulps = 8,
        .kind = .binary,
        .entry = "cartpole_pole",
        .cpu = struct {
            // Also tolerance zero, and for the same reason: the dynamics are a fixed sequence of
            // multiplies, divides, a `sin` and a `cos`. Both sides take the same path through the
            // same `zm` functions, so a difference is a bug rather than drift.
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                for (o.data, a.data, b.data) |*out, angle, force| {
                    const start: zn.CartpoleState(f32) = .{
                        .cart = 0,
                        .cart_rate = 0,
                        .pole_rad = angle,
                        .pole_rate_rad = 0,
                    };
                    out.* = zn.cartpoleContinuousStep(f32, start, force).state.pole_rad;
                }
            }
        }.f,
    },
    .{ .label = "add", .tol = 0, .kind = .binary, .entry = "add", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.add(f32, o, a, b);
        }
    }.f },
    .{ .label = "mul", .tol = 0, .kind = .binary, .entry = "mul", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.mul(f32, o, a, b);
        }
    }.f },
    .{ .label = "sub", .tol = 0, .kind = .binary, .entry = "sub", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.sub(f32, o, a, b);
        }
    }.f },
    .{ .label = "div", .tol = 0, .ulps = 2, .kind = .binary, .entry = "div", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.div(f32, o, a, b);
        }
    }.f },
    // ** The bias add. `a` is the field; `b` is read with a row stride of ZERO on the GPU, so
    // its first row is stretched down - and the CPU oracle stretches the same row with
    // `broadcastTo`. The two representations of broadcasting, checked against each other.
    .{ .label = "bcast add (bias)", .tol = 0, .kind = .binary, .entry = "bcast_add", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            const row: Tn = try Tn.fromSlice(b.data[0..side], &.{ 1, side });
            return zn.add(f32, o, a, try row.broadcastTo(&.{ side, side }));
        }
    }.f },
    .{ .label = "sigmoid grad", .tol = 0, .kind = .binary, .entry = "sigmoid_grad", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.sigmoidGrad(f32, o, a, b);
        }
    }.f },
    .{ .label = "tanh grad", .tol = 0, .kind = .binary, .entry = "tanh_grad", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.tanhGrad(f32, o, a, b);
        }
    }.f },
    .{ .label = "relu grad", .tol = 0, .kind = .binary, .entry = "relu_grad", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.reluGrad(f32, o, a, b);
        }
    }.f },
    .{ .label = "sgd step", .tol = 0, .kind = .binary, .entry = "sgd_step", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.sgdStep(f32, o, a, b, learning_rate);
        }
    }.f },
    .{ .label = "matmul (global)", .tol = 1.0e-4, .kind = .matmul, .entry = "matmul", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.matmul(f32, o, a, b);
        }
    }.f },
    .{ .label = "matmul (16x16 tiled)", .tol = 1.0e-4, .kind = .matmul, .entry = "matmul_tiled", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.matmul(f32, o, a, b);
        }
    }.f },
    .{ .label = "matmul a@bT", .tol = 1.0e-4, .kind = .matmul, .entry = "matmul_bt", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            return zn.matmul(f32, o, a, try b.transpose(0, 1));
        }
    }.f },
    // A materialising transpose. On the CPU it is a stride swap copied through `map`; on the GPU
    // it is a real gather, which is why the kernel exists at all.
    .{ .label = "transpose", .tol = 0, .kind = .matmul, .entry = "transpose", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.map(f32, o, try a.transpose(0, 1), struct {
                fn id(x: f32) f32 {
                    return x;
                }
            }.id);
        }
    }.f },
    .{ .label = "scale", .tol = 0, .kind = .unary, .entry = "scale", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.scale(f32, o, a, learning_rate);
        }
    }.f },
    .{
        .label = "logsumexp rows",
        .tol = 0,
        .ulps = 16,
        .kind = .unary,
        .entry = "log_sum_exp_rows",
        // One thread per row, and one value out per row - so only the first `side` elements are
        // judged. Everything past that is whatever the buffer held, and comparing it would be
        // comparing noise.
        .threads = side,
        .out_len = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const per_row: Tn = try Tn.fromSlice(o.data[0..side], &.{side});
                return zn.logSumExpAxis(f32, per_row, a, 1);
            }
        }.f,
    },
    .{
        .label = "softmax rows",
        .tol = 0,
        .ulps = 16,
        .kind = .unary,
        .entry = "softmax_rows",
        .threads = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.softmaxRows(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "layernorm rows",
        .tol = 0,
        .ulps = 64,
        .kind = .unary,
        .entry = "layernorm_rows",
        .threads = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.layerNormRows(f32, o, a, layernorm_epsilon);
            }
        }.f,
    },
    .{
        .label = "sum axis0 (bias grad)",
        .tol = 0,
        .ulps = 16,
        .kind = .unary,
        .entry = "sum_axis0",
        .threads = side,
        .out_len = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const vec: Tn = try Tn.fromSlice(o.data[0..side], &.{side});
                return zn.sumAxis(f32, vec, a, 0);
            }
        }.f,
    },
    .{
        .label = "sum all (scalar)",
        .tol = 0,
        .ulps = 64,
        .kind = .unary,
        .entry = "sum_all",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                // * Against the COMPENSATED sum, deliberately. The kernel accumulates plainly, so
                // this row measures how far a plain 4096-term accumulation drifts from the exact
                // answer - the number that justifies `sumAll`'s default.
                o.data[0] = zn.sumAll(f32, a);
            }
        }.f,
    },
    .{
        // ** The same answer as `sum all (scalar)` by a different route: 64 lanes and a 6-level
        // shared-memory tree instead of one thread. Both are compared against `zn.sumAll`, so a
        // barrier mistake or a race shows up as this row disagreeing with the one above it -
        // which is the check a CPU oracle structurally cannot make.
        .label = "sum all (tree)",
        .tol = 0,
        .ulps = 64,
        .kind = .unary,
        .entry = "sum_all_tiled",
        .threads = 64,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = zn.sumAll(f32, a);
            }
        }.f,
    },
    .{
        .label = "mean all",
        .tol = 0,
        .ulps = 64,
        .kind = .unary,
        .entry = "mean_all",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = try zn.meanAll(f32, a);
            }
        }.f,
    },
    .{
        // * Tolerance 0, and that is not optimism: a maximum is a SELECTION, not an
        // accumulation. Every candidate is a value that already exists in the input, so both
        // sides must return the same bits or one of them is comparing wrongly. A nonzero bar
        // here would hide a real defect rather than absorb rounding - there is no rounding.
        .label = "max all",
        .tol = 0,
        .kind = .unary,
        .entry = "max_all",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = try zn.maxAll(f32, a);
            }
        }.f,
    },
    // -- *** TOLERANCES CHOSEN PER OPERATION, NOT PER BATCH --
    //
    // `floor`, `ceil`, `sign`, `minimum` and `maximum` are all SELECTIONS or exact roundings:
    // every result already exists, or is an integer both sides reach identically. Zero is the
    // only defensible bar and a looser one would hide a defect.
    //
    // `sqrt` and `square` are single operations, so 2 ULP covers the rounding step. `log` gets 4:
    // its output magnitude swings with the input and the host and device take different
    // implementations, the same asymmetry already measured at 1-2 ULP for the other
    // transcendentals.
    .{
        .label = "minimum",
        .tol = 0,
        .kind = .binary,
        .entry = "minimum",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.minimum(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "maximum",
        .tol = 0,
        .kind = .binary,
        .entry = "maximum",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.maximum(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "sqrt",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "sqrtf",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.sqrt(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "log",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "logf",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.log(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "floor",
        .tol = 0,
        .kind = .unary,
        .entry = "floorf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.floor(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "ceil",
        .tol = 0,
        .kind = .unary,
        .entry = "ceilf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.ceil(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "sign",
        .tol = 0,
        .kind = .unary,
        .entry = "signf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.sign(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "square",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "square",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.square(f32, o, a);
            }
        }.f,
    },
    // ** `reciprocal` takes the POSITIVE input, not the noise. 1/x is defined at every non-zero
    // real, but the noise field can come arbitrarily close to zero, and a quotient near 1e30 has
    // a ULP of 1e23 - a bar that would accept anything. The positive field bounds the output at
    // 2, so the row measures the division rather than the luck of the draw.
    //
    // * `trunc` and `round` are exact on both sides: they return integers both backends reach
    // identically, so zero is the only defensible bar.
    .{
        .label = "reciprocal",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "reciprocal",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.reciprocal(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "trunc",
        .tol = 0,
        .kind = .unary,
        .entry = "truncf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.trunc(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "round",
        .tol = 0,
        .kind = .unary,
        .entry = "roundf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.round(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "sin",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "sinf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.sinRad(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "cos",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "cosf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.cosRad(f32, o, a);
            }
        }.f,
    },
    .{
        // -- *** 16 ULP, AND zm's OWN COMMENT IS THE JUSTIFICATION --
        //
        // `zm.atan2Rad` is `std.math.atan2` on the host - exact, a hundred lines - and a
        // **DirectXMath-derived polynomial** on the GPU. The two backends run deliberately
        // different algorithms, so the agreement is bounded by the polynomial's accuracy, not by
        // rounding. Measured on device: **9.6 ULP**, against 1.5 for `sin` and 1.6 for `cos`,
        // whose GPU path is a much closer approximation.
        //
        // ** My first bar was 4 ULP, guessed by analogy with the other transcendentals, and the
        // device rejected it. **The number came from the implementation, not from the pattern** -
        // 16 covers the measured value with margin without hiding a real regression.
        .label = "atan2",
        .tol = 0,
        .ulps = 16,
        .kind = .binary,
        .entry = "atan2f",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.atan2Rad(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "hypot",
        .tol = 0,
        .ulps = 2,
        .kind = .binary,
        .entry = "hypotf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.hypot(f32, o, a, b);
            }
        }.f,
    },
    // * All five have a tolerance of ZERO. The masks return literal 0 or 1; `clamp` is two
    // selections; and `lerp` is exact at both endpoints and a single fused expression between
    // them, evaluated identically on both sides. Nothing here rounds, so nothing needs a bar.
    .{
        .label = "greater",
        .tol = 0,
        .kind = .binary,
        .entry = "greater",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.greater(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "less",
        .tol = 0,
        .kind = .binary,
        .entry = "less",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.less(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "equal",
        .tol = 0,
        .kind = .binary,
        .entry = "equal",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.equal(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "lerp",
        .tol = 0,
        .kind = .binary,
        .entry = "lerpf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.lerp(f32, o, a, b, learning_rate);
            }
        }.f,
    },
    .{
        .label = "clamp",
        .tol = 0,
        .kind = .unary,
        .entry = "clampf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.clamp(f32, o, a, clamp_lo, clamp_hi);
            }
        }.f,
    },
    // ** `leaky relu` has a tolerance of ZERO: both branches are a compare and a single multiply,
    // exact on both sides. `elu` and `softplus` get 2 ULP for their `exp`, and `mse loss` gets 64
    // because the kernel accumulates 4096 terms plainly against a compensated reference - the
    // same drift `sum all (scalar)` reports.
    .{
        .label = "softplus",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "softplus",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.softplus(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "silu",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "silu",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.silu(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "leaky relu",
        .tol = 0,
        .kind = .unary,
        .entry = "leaky_relu",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.leakyRelu(f32, o, a, elu_alpha);
            }
        }.f,
    },
    .{
        .label = "elu",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "elu",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.elu(f32, o, a, elu_alpha);
            }
        }.f,
    },
    .{
        .label = "min all",
        .tol = 0,
        .kind = .unary,
        .entry = "min_all",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = try zn.minAll(f32, a);
            }
        }.f,
    },
    .{
        .label = "mse loss",
        .tol = 0,
        .ulps = 64,
        .kind = .binary,
        .entry = "mse_loss",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                o.data[0] = try zn.mseLoss(f32, a, b);
            }
        }.f,
    },
    // * `max axis0`, `min axis0` and `argmax axis0` are SELECTIONS: tolerance zero. `mean axis0`
    // is a 64-term plain accumulation against a compensated reference, so it gets the same bar
    // as `sum axis0`. `cumsum` accumulates up to 64 terms per row, where the last element has
    // seen every rounding before it.
    .{
        .label = "max axis0",
        .tol = 0,
        .kind = .unary,
        .entry = "max_axis0",
        .threads = side,
        .out_len = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const vec: Tn = try Tn.fromSlice(o.data[0..side], &.{side});
                return zn.maxAxis(f32, vec, a, 0);
            }
        }.f,
    },
    .{
        .label = "min axis0",
        .tol = 0,
        .kind = .unary,
        .entry = "min_axis0",
        .threads = side,
        .out_len = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const vec: Tn = try Tn.fromSlice(o.data[0..side], &.{side});
                return zn.minAxis(f32, vec, a, 0);
            }
        }.f,
    },
    .{
        .label = "mean axis0",
        .tol = 0,
        .ulps = 16,
        .kind = .unary,
        .entry = "mean_axis0",
        .threads = side,
        .out_len = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const vec: Tn = try Tn.fromSlice(o.data[0..side], &.{side});
                return zn.meanAxis(f32, vec, a, 0);
            }
        }.f,
    },
    .{
        .label = "argmax axis0",
        .tol = 0,
        .kind = .unary,
        .entry = "argmax_axis0",
        .threads = side,
        .out_len = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                // argmaxRows works on rows; the column form is the transpose's rows. The index
                // comes back as a float so it can sit in the same buffer as everything else.
                var idx: [side]usize = @splat(0);
                try zn.argmaxRows(f32, &idx, try a.transpose(0, 1));
                for (idx, 0..) |k, c| {
                    o.data[c] = @floatFromInt(k);
                }
            }
        }.f,
    },
    .{
        .label = "cumsum rows",
        .tol = 0,
        .ulps = 16,
        .kind = .unary,
        .entry = "cumsum_rows",
        .threads = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.cumsum(f32, o, a);
            }
        }.f,
    },
    // ** THE THREE LOSSES NOW COMPARE PLAIN AGAINST COMPENSATED, like `mse loss`: the kernel
    // accumulates 4096 terms plainly and `zn` uses `CompensatedSum`. The drift is the measured cost of
    // the plain form, and 64 ULP covers it. `max pool` is a selection: zero. `avg pool` is four
    // terms and `conv2d` nine, so both get a small bar; `variance axis0` is two 64-term passes.
    .{
        .label = "mae loss",
        .tol = 0,
        .ulps = 64,
        .kind = .binary,
        .entry = "mae_loss",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                o.data[0] = try zn.maeLoss(f32, a, b);
            }
        }.f,
    },
    .{
        .label = "huber loss",
        .tol = 0,
        .ulps = 64,
        .kind = .binary,
        .entry = "huber_loss",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                o.data[0] = try zn.huberLoss(f32, a, b, huber_delta);
            }
        }.f,
    },
    .{
        .label = "bce loss",
        .tol = 0,
        .ulps = 64,
        .kind = .binary,
        .entry = "bce_loss",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                o.data[0] = try zn.binaryCrossEntropyFromLogits(f32, a, b);
            }
        }.f,
    },
    .{
        // The kernel is the first nine elements of `b`, read as 3x3; padding 1 keeps the output
        // the image's size, which is what lets it fill the same buffer as an elementwise row.
        .label = "conv2d 3x3 same",
        .tol = 0,
        .ulps = 8,
        .kind = .binary,
        .entry = "conv2d_same",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                const kernel: Tn = try Tn.fromSlice(b.data[0..9], &.{ 3, 3 });
                return zn.conv2d(f32, o, a, kernel, .{ 1, 1 }, .{ 1, 1 });
            }
        }.f,
    },
    .{
        .label = "variance axis0",
        .tol = 0,
        .ulps = 16,
        .kind = .unary,
        .entry = "variance_axis0",
        .threads = side,
        .out_len = side,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const vec: Tn = try Tn.fromSlice(o.data[0..side], &.{side});
                return zn.varianceAxis(f32, vec, a, 0, .population);
            }
        }.f,
    },
    .{
        .label = "max pool 2x2",
        .tol = 0,
        .kind = .unary,
        .entry = "max_pool2d",
        .threads = pooled,
        .out_len = pooled,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const img: Tn = try Tn.fromSlice(o.data[0..pooled], &.{ side / 2, side / 2 });
                return zn.maxPool2d(f32, img, a, 2);
            }
        }.f,
    },
    .{
        .label = "avg pool 2x2",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "avg_pool2d",
        .threads = pooled,
        .out_len = pooled,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const img: Tn = try Tn.fromSlice(o.data[0..pooled], &.{ side / 2, side / 2 });
                return zn.avgPool2d(f32, img, a, 2);
            }
        }.f,
    },
    .{
        .label = "log2",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "log2f",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.log2(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "log10",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "log10f",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.log10(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "expm1",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "expm1",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.expm1(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "log1p",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "log1p",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.log1p(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "cbrt",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "cbrtf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.cbrt(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "not equal",
        .tol = 0,
        .kind = .binary,
        .entry = "not_equal",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.notEqual(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "greater equal",
        .tol = 0,
        .kind = .binary,
        .entry = "greater_equal",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.greaterEqual(f32, o, a, b);
            }
        }.f,
    },
    .{
        .label = "less equal",
        .tol = 0,
        .kind = .binary,
        .entry = "less_equal",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                return zn.lessEqual(f32, o, a, b);
            }
        }.f,
    },
    // ** THE THREE ROWS THE THIRD BUFFER UNBLOCKED. Each was host-only for want of a binding,
    // not for any reason of algorithm.
    .{
        .label = "where",
        .tol = 0,
        .kind = .binary,
        .entry = "where_pick",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                // The mask the kernel reads from `c` is `greater(a, b)`, built the same way here.
                // * The scratch lives INSIDE the closure, as a static local. A module-level
                // mutable would be shared between rows that run in sequence and read fine, right
                // up until two of them ran concurrently.
                const Scratch = struct {
                    var mask: [count]f32 = @splat(0);
                };
                const mask: Tn = try Tn.fromSlice(&Scratch.mask, &.{ side, side });
                try zn.greater(f32, mask, a, b);
                return zn.where(f32, o, mask, a, b);
            }
        }.f,
    },
    .{
        .label = "sgd momentum",
        .tol = 0,
        .ulps = 4,
        .kind = .binary,
        .entry = "sgd_momentum",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                const Scratch = struct {
                    var velocity: [count]f32 = @splat(0);
                };
                const velocity: Tn = try Tn.fromSlice(&Scratch.velocity, &.{ side, side });
                velocity.fill(0);
                return zn.sgdMomentum(f32, o, a, b, velocity, learning_rate, momentum);
            }
        }.f,
    },
    .{
        .label = "adam step",
        .tol = 0,
        .ulps = 8,
        .kind = .binary,
        .entry = "adam_step",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                const Scratch = struct {
                    var first: [count]f32 = @splat(0);
                    var second: [count]f32 = @splat(0);
                };
                const first: Tn = try Tn.fromSlice(&Scratch.first, &.{ side, side });
                const second: Tn = try Tn.fromSlice(&Scratch.second, &.{ side, side });
                first.fill(0);
                second.fill(0);
                return zn.adamStep(f32, o, a, b, first, second, .{ .rate = learning_rate }, 1);
            }
        }.f,
    },
    .{
        .label = "sinh",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "sinhf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.sinh(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "cosh",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "coshf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.cosh(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "asinh",
        .tol = 0,
        // * 8 rather than 4: the device measured 1.43e-6 against a 9.4e-7 bar, which is 4.8 ULP.
        // `asinh` is three roundings deep - a square root, an add and a log - so the bar was set
        // from a guess and is now set from the measurement.
        .ulps = 8,
        .kind = .unary,
        .entry = "asinhf",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.asinh(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "atanh",
        .tol = 0,
        .ulps = 8,
        .kind = .unary,
        .entry = "atanhf",
        .input = .unit,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.atanh(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "rsqrt",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "rsqrtf",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.rsqrt(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "zm sign",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "signz",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.sign(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "zm expm1",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "expm1z",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.expm1(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "zm log1p",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "log1pz",
        .input = .positive,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.log1p(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "zm relu",
        .tol = 0,
        .ulps = 2,
        .kind = .unary,
        .entry = "reluz",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.relu(f32, o, a);
            }
        }.f,
    },
    // THE ROWS THAT ASK ABOUT CANCELLATION
    //
    // Three, not five. `sigmoid` and `softplus` were here too and were dropped: near zero their
    // values are 0.5 and 0.693, not small, so nothing cancels and the band tests nothing the
    // noise field does not already cover. A row that cannot fail differently is a row that costs
    // three frames to tell you what you knew.
    //
    // The same five functions as elsewhere in this table, on the `tiny` field instead of the
    // noise. They are here because `zm.tanh` was 1.0 relative error at f32 near zero for as long
    // as this sweep has existed, and the sweep never said so - a normal(0,1) field has no values
    // small enough for the subtraction to cancel. One more distribution, five more rows, and the
    // whole class becomes visible.
    .{
        .label = "expm1 (tiny)",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "expm1",
        .input = .tiny,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.expm1(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "log1p (tiny)",
        .tol = 0,
        // BACK TO 4, BECAUSE THE FUNCTION CHANGED RATHER THAN THE TOLERANCE
        //
        // This row failed twice. At 8 ULP it still came back **27 000 times over** on the narrow
        // band, and that was the band doing its job: `log1p` went through `@log(1 + x)`, and a
        // shader's `@log` is off by about 1.19e-7 ABSOLUTE near 1 - which at x = 1e-6 is twelve
        // percent. `zm.log1p` now uses a series below an eighth, on both backends, so the two
        // sides run the same arithmetic again and 4 is the right bar.
        .ulps = 4,
        .kind = .unary,
        .entry = "log1p",
        .input = .tiny,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.log1p(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "tanh (tiny)",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "tanhf",
        .input = .tiny,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.tanh(f32, o, a);
            }
        }.f,
    },
    // Turns, on the noise field: the values run to about +/-4, so several whole turns are
    // covered and the reduction is exercised rather than skipped.
    .{
        .label = "sin turns",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "sin_turns",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.sinTurns(f32, o, a);
            }
        }.f,
    },
    .{
        .label = "cos turns",
        .tol = 0,
        .ulps = 4,
        .kind = .unary,
        .entry = "cos_turns",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                return zn.cosTurns(f32, o, a);
            }
        }.f,
    },
    // Pure addressing, no arithmetic: both must be EXACT, so the bars are zero.
    .{
        .label = "cartpole step",
        // NOT ZERO - THE ARITHMETIC HAS A SINE, A COSINE AND TWO DIVISIONS IN IT
        //
        // The headless twin measured EXACTLY zero, which was true and misleading: it compiles
        // the kernel for the host, where `@sin` is the host's. On device it is the driver's, and
        // the device reported 2.4e-7 - one ULP at this scale, and correct. **A twin that runs
        // both sides on the same machine cannot see a library difference**, only an algebraic
        // one. Sixteen ULPs, like the other rows whose kernels transcend a builtin.
        .tol = 0,
        .ulps = 16,
        .kind = .binary,
        .entry = "cartpole_step",
        // Four floats of state per environment, so the field is read as `side*side/4` rows.
        // Only the state block is judged; the reward and flag sit past it.
        .threads = count / 4,
        .out_len = count,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                const rows: usize = count / 4;
                const states: Tn = try Tn.fromSlice(a.data[0..count], &.{ rows, 4 });
                const next: Tn = try Tn.fromSlice(o.data[0..count], &.{ rows, 4 });
                // The outcome goes in scratch, not past the end of `o` - see the kernel's note.
                var scratch: [count / 4 * 2]f32 = undefined;
                const outcome: Tn = try Tn.fromSlice(&scratch, &.{ rows, 2 });
                var pushes: [count / 4]zn.Push = undefined;
                for (&pushes, 0..) |*p, i| {
                    p.* = if (b.data[i] < 0) .left else .right;
                }
                return zn.cartpoleStepBatch(f32, next, outcome, states, &pushes);
            }
        }.f,
    },
    .{
        .label = "slice columns",
        .tol = 0,
        .kind = .binary,
        .entry = "slice_columns",
        // Half the width out, read from an offset - so a kernel that assumed the input and
        // output widths matched would pass on the first column and fail on the rest.
        .out_len = count / 2,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                const narrow: Tn = try Tn.fromSlice(o.data[0 .. side * side / 2], &.{ side, side / 2 });
                return zn.materialise(f32, narrow, try a.slice(1, side / 2, side / 2));
            }
        }.f,
    },
    .{
        .label = "concat columns",
        .tol = 0,
        .kind = .binary,
        .entry = "concat_columns",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                // First half from `a`, second from `b`, both packed at half width.
                const left: Tn = try Tn.fromSlice(a.data[0 .. side * side / 2], &.{ side, side / 2 });
                const right: Tn = try Tn.fromSlice(b.data[0 .. side * side / 2], &.{ side, side / 2 });
                return zn.concat(f32, o, left, right, 1);
            }
        }.f,
    },
    .{
        .label = "mesh grid x",
        .tol = 0,
        .kind = .binary,
        .entry = "mesh_grid_x",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                // Only the column grid; `mesh grid y` is the row one, next.
                // BOTH GRIDS NEED SOMEWHERE TO GO
                //
                // This passed `o` for out_x AND out_y, so the row grid overwrote the column grid
                // and the reference computed the wrong one - while the kernel computed the right
                // one. The headless twin used two separate buffers and passed; **the twin
                // verified a call the sweep never makes.**
                const xs: Tn = try Tn.fromSlice(a.data[0..side], &.{side});
                const ys: Tn = try Tn.fromSlice(a.data[0..side], &.{side});
                var other: [count]f32 = undefined;
                const grid_y: Tn = try Tn.fromSlice(&other, &.{ side, side });
                return zn.meshGrid(f32, o, grid_y, xs, ys);
            }
        }.f,
    },
    .{
        .label = "mesh grid y",
        .tol = 0,
        .kind = .binary,
        .entry = "mesh_grid_y",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = a;
                const ys: Tn = try Tn.fromSlice(b.data[0..side], &.{side});
                var walk: zn.Walk = .over(o.shape[0..o.rank]);
                while (walk.next()) |at| {
                    try o.setAt(at, try ys.at(&.{at[0]}));
                }
            }
        }.f,
    },
    .{
        .label = "repeat each",
        .tol = 0,
        .kind = .binary,
        .entry = "repeat_each",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                // Half as many columns in, twice each on the way out. The slice is a strided
                // VIEW and `repeatEach` reads through `.at()`, so nothing needs materialising -
                // a reference that allocated every frame would leak on a loop this sweep runs
                // ninety-three times a pass.
                const narrow: Tn = try a.slice(1, 0, side / 2);
                return zn.repeatEach(f32, o, narrow, 1, 2);
            }
        }.f,
    },
    .{ .label = "relu", .tol = 1.0e-5, .kind = .unary, .entry = "relu", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.relu(f32, o, a);
        }
    }.f },
    .{ .label = "sigmoid", .tol = 1.0e-5, .kind = .unary, .entry = "sigmoid", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.sigmoid(f32, o, a);
        }
    }.f },
    .{ .label = "tanh", .tol = 1.0e-5, .kind = .unary, .entry = "tanhf", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.tanh(f32, o, a);
        }
    }.f },
    .{ .label = "gelu", .tol = 1.0e-5, .kind = .unary, .entry = "gelu", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.gelu(f32, o, a);
        }
    }.f },
    .{ .label = "exp", .tol = 1.0e-5, .kind = .unary, .entry = "expf", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.exp(f32, o, a);
        }
    }.f },
    // `exp2` is not `exp(x * ln 2)` on every backend - a driver may lower it to a dedicated
    // instruction with its own rounding. A transcendental can drift where addressing cannot,
    // which is what makes it worth a row.
    .{ .label = "exp2", .tol = 1.0e-5, .kind = .unary, .entry = "exp2f", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.exp2(f32, o, a);
        }
    }.f },
    // `affine` may be CONTRACTED into a fused multiply-add, which rounds once where the separate
    // multiply and add round twice. A real difference and a small one - the kind a sweep exists
    // to measure rather than argue about.
    .{ .label = "affine", .tol = 1.0e-6, .kind = .unary, .entry = "affine_f", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.affine(f32, o, a, learning_rate, layernorm_epsilon);
        }
    }.f },
    // A COUNT DOES NOT ACCUMULATE, so its bar is zero where every other reduction row carries a
    // ULP allowance. Integer addition is exact in any order, so a difference here is a real bug.
    // `all` and `any` combine with `and`/`or`, which are associative AND idempotent - so the
    // order of a reduction cannot change the answer and the bar is ZERO. A nonzero difference
    // here is a real bug, not accumulated rounding, which is exactly what a zero bar asserts.
    .{
        .label = "all nonzero",
        .tol = 0,
        .kind = .unary,
        .entry = "all_nonzero",
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = if (zn.all(f32, a)) 1 else 0;
            }
        }.f,
    },
    .{
        .label = "any nonzero",
        .tol = 0,
        .kind = .unary,
        .entry = "any_nonzero",
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = if (zn.any(f32, a)) 1 else 0;
            }
        }.f,
    },
    // A PRODUCT IS THE OPPOSITE CASE. Multiplication is associative in real arithmetic and not
    // in floating point, and a product accumulates that over the whole buffer where a sum
    // accumulates only absolute error. Hence a real tolerance beside two zeros - and the
    // contrast is what makes both bars informative.
    .{
        .label = "prod all",
        .tol = 1.0e-3,
        .kind = .unary,
        .entry = "prod_all",
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = zn.prodAll(f32, a);
            }
        }.f,
    },
    .{
        .label = "count nonzero",
        .tol = 0,
        .kind = .unary,
        .entry = "count_nonzero",
        .threads = 1,
        .out_len = 1,
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                _ = b;
                o.data[0] = @floatFromInt(zn.countNonzero(f32, a));
            }
        }.f,
    },
    // A subtraction of two nearby values is where cancellation lives. One rounding on each side,
    // so the bar is zero - and this row exists to prove that rather than assume it.
    .{ .label = "diff", .tol = 0, .kind = .unary, .entry = "diff_forward", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.diff(f32, o, a);
        }
    }.f },
    // ---- THE DIAGNOSTIC ROW FOR `diff`'s FINITENESS MISMATCH ----
    //
    // `diff` returns finite on device where NaN is correct, and the transpiled WGSL is correct
    // at every step - branch, phi, and a bit pattern routed through a runtime `var`. This row
    // strips away the branch, the call chain and the arithmetic, leaving only: can a NaN reach
    // the output buffer at all?
    //
    // If this row is ALSO red, the answer is below the driver and no amount of transpiler work
    // will fix it. If it is green, the bitcast survives and the fault is between it and `diff`'s
    // store - which is a much smaller place to look.
    .{ .label = "nan direct", .tol = 0, .kind = .unary, .entry = "nan_direct", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = a;
            _ = b;
            for (o.data) |*out| {
                out.* = zm.nan(f32);
            }
        }
    }.f },
    .{ .label = "abs", .tol = 0, .kind = .unary, .entry = "absf", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.abs(f32, o, a);
        }
    }.f },
    .{ .label = "neg", .tol = 0, .kind = .unary, .entry = "neg", .cpu = struct {
        fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
            _ = b;
            return zn.neg(f32, o, a);
        }
    }.f },
};

/// The worst absolute disagreement, and the largest reference magnitude, over the pair.
///
/// *** A NON-FINITE DISAGREEMENT CANNOT BE SKIPPED. `@abs(inf - inf)` is NaN, and `NaN > worst`
/// is FALSE - so the obvious loop silently ignores exactly the elements most likely to be wrong.
/// The `div` row proves this is not hypothetical: the ramp crosses zero, so a whole column
/// divides by zero and every one of those comparisons was being dropped. A GPU returning NaN
/// where the CPU returned infinity would have passed. Now a mismatch in FINITENESS is reported
/// as infinity, which no tolerance can accept.
pub const Comparison = struct { worst: f32, peak: f32 };

pub fn compare(gpu: []const f32, cpu: []const f32) Comparison {
    var worst: f32 = 0;
    var peak: f32 = 0;
    var mismatched: bool = false;
    var i: usize = 0;
    while (i < gpu.len and i < cpu.len) : (i += 1) {
        const g: f32 = gpu[i];
        const c: f32 = cpu[i];
        if (isFinite(c) and @abs(c) > peak) {
            peak = @abs(c);
        }
        if (isFinite(g) != isFinite(c)) {
            // ** RECORDED, NOT RETURNED. Returning here left `peak` holding whatever had
            // accumulated before the first disagreement, so a failing row displayed a bar of 0
            // and no reader could tell what it had been judged against. The scan always
            // completes now.
            mismatched = true;
            continue;
        }
        if (!isFinite(g)) {
            // *** TWO NaNs ARE AGREEMENT. `NaN != NaN` is true, so the obvious `g != c` reports
            // a mismatch whenever BOTH sides correctly produce NaN - which is every partial
            // function on an out-of-domain input. Matching infinities agree; anything else does
            // not.
            const both_nan: bool = (g != g) and (c != c);
            if (!both_nan and g != c) {
                mismatched = true;
            }
            continue;
        }
        const delta: f32 = @abs(g - c);
        if (delta > worst) {
            worst = delta;
        }
    }
    return .{ .worst = if (mismatched) inf(f32) else worst, .peak = peak };
}

// ---- THE TABLE'S OWN INVARIANTS, CHECKED WITHOUT A DEVICE ----
//
// These do not compare CPU against GPU - that needs a queue, and it is what the field sweep
// does. They check the things that can silently rot in a table of 52 rows and would make the
// device comparison meaningless BEFORE it ever runs.

test "zn conformance: no row repeats another's kernel AND input distribution" {
    // The invariant is (kind, entry, input) - NOT (kind, entry). Three kernels are deliberately
    // rowed twice: `expm1`, `log1p` and `tanhf` each appear once on `.noise` and once on
    // `.tiny`, because the first two exist PRECISELY for small arguments and a sweep that only
    // ever fed them noise would never exercise the path they were written for.
    //
    // What would be a bug is the same kernel on the same distribution twice: one of the two CPU
    // references is then never compared against anything, and nothing says so - the row still
    // renders, still passes, and means nothing.
    for (cases, 0..) |a, i| {
        for (cases[i + 1 ..]) |b| {
            if (a.kind != b.kind or a.input != b.input) {
                continue;
            }
            try expect(!eql(u8, a.entry, b.entry));
        }
    }
}

test "zn conformance: a tolerance is either zero or a real allowance, never negative" {
    // A negative tolerance accepts EVERYTHING - `worst <= bar` holds for any finite worst - so
    // the row would pass no matter what the GPU returned. That is the one failure a sweep
    // cannot report, because it looks exactly like success.
    for (cases) |c| {
        try expect(c.tol >= 0);
        try expect(c.ulps >= 0);
        try expect(isFinite(c.tol) and isFinite(c.ulps));
    }
}

test "zn conformance: every row's output fits the buffer the sweep allocates" {
    // `out_len` drives the comparison's slice. A row claiming more elements than the field
    // holds would read past the reference, and one claiming fewer would silently compare a
    // prefix and call the rest verified.
    for (cases) |c| {
        try expect(c.out_len > 0);
        try expect(c.out_len <= count);
        try expect(c.threads > 0);
    }
}

test "zn conformance: compare reports infinity when finiteness disagrees" {
    // The `div` row proved this is not hypothetical: the ramp crosses zero, so a backend that
    // returned a finite number where the reference returned infinity used to pass on tolerance.
    // A mismatch in FINITENESS is now unconditional, which no tolerance can accept.
    const gpu = [_]f32{ 1.0, 2.0 };
    const cpu_same = [_]f32{ 1.0, 2.0 };
    const cpu_inf = [_]f32{ 1.0, inf(f32) };
    try expect(isFinite(compare(&gpu, &cpu_same).worst));
    try expect(!isFinite(compare(&gpu, &cpu_inf).worst));
}
