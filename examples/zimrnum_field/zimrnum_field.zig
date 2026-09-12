//! zimrnum_field — a scalar field built with zimrnum, computed twice, drawn three times.
//!
//! ── ★★★ WHAT THIS EXAMPLE IS FOR ──
//!
//! To use zimrnum the way an application would, not the way a test does. It builds a 64×64 field
//! out of tensors — noise plus a broadcast row ramp — evaluates it through `zn.add` and `zn.mul`
//! on the CPU and through the same operations on the GPU, and draws BOTH heatmaps plus their
//! difference. A wrong GPU result is not a number in a log; it is a visibly different picture.
//!
//! ★★ THE DENSIFY STEP IS SHOWN, NOT HIDDEN. The GPU kernel takes flat buffers with a count —
//! no shape, no strides. `zn.broadcastTo` produces a stride-0 VIEW, which cannot be bound. So the
//! host materialises the ramp into a dense tensor first, with `zn.add` against a zero field, and
//! that line is the whole difference between what the two backends can accept.
//!
//! ★ Inputs come from `zn.Rng`, which is counter-based: both backends see identical values
//! without either sending them to the other, and the field is reproducible from one seed.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
// House form: bind the zm name once at file scope rather than qualifying it in a body.
const zm = @import("zm");
const bufPrint = std.fmt.bufPrint;
const isFinite = zm.isFinite;
const inf = zm.inf;
const floatEps = zm.floatEps;
const zn = @import("zn");
const zn_binary = @import("zn_binary.zig");
const zn_matmul = @import("zn_matmul.zig");
const zn_unary = @import("zn_unary.zig");
const float = zm.float;
const Color = zm.Color;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
// One WGSL per ENTRY, not per kernel file — the build names each embed after its entry.
/// ── ★★★ THE PIPELINE TABLE IS DERIVED, NOT WRITTEN ──
///
/// A kernel used to be named in four places: the file's install call, `build.zig`'s `.entries`,
/// an `@embedFile` here, and a pipeline entry here. Four lists to keep in agreement by hand, and
/// eleven kernels in, that was the thing slowing the port down.
///
/// Now each kernel file carries `pub const kernels`, and this builds the host table from it. The
/// entry name and its WGSL cannot disagree, because the same string produces both.
///
/// ★★ IT IS ALSO THE DRIFT GATE, AND IT COSTS NOTHING. `@embedFile(name ++ "_wgsl")` only
/// resolves if `build.zig` generated that WGSL. Add an entry to a kernel file and forget the
/// build, and the failure is a compile error naming the missing file — not a shader that is
/// absent at runtime on a device you are not holding.
fn pipelineEntries(comptime M: type) [M.kernels.len]z.Compute(M).KernelWgsl {
    var table: [M.kernels.len]z.Compute(M).KernelWgsl = undefined;
    inline for (M.kernels, 0..) |name, i| {
        table[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

const side: usize = 64;
const count: u32 = side * side;

/// Fixed so both backends use the same value; the sweep is a comparison, not a training run.
const learning_rate: f32 = 0.1;

/// Layer normalisation's stabiliser. PyTorch's default, so the numbers are comparable with
/// what a reader is likely to have seen elsewhere.
const layernorm_epsilon: f32 = 1.0e-5;

/// Bounds for the `clamp` row, chosen to sit INSIDE the noise field's range so the row exercises
/// both branches — a clamp whose bounds enclose the data clamps nothing and tests nothing.
/// Slope for `leaky relu` and alpha for `elu`. 0.25 rather than PyTorch's 0.01 so the negative
/// branch is clearly visible in the heatmap instead of being a rounding-sized sliver.
const elu_alpha: f32 = 0.25;

/// Huber's threshold for the sweep, chosen so both branches are exercised on the noise field.
/// Momentum for the `sgd momentum` row, matching the kernel's `delta`.
const momentum: f32 = 0.9;

const huber_delta: f32 = 1.0;

/// Elements in a 2x2-pooled field.
const pooled: u32 = (side / 2) * (side / 2);

const clamp_lo: f32 = -0.5;
const clamp_hi: f32 = 0.5;

/// The re-run button's size. Its POSITION follows the layout and is stored on the `State` when
/// the frame draws it, so the hit test and the drawing cannot drift apart — a button drawn in one
/// place and pressed in another is the classic version of this bug, and a hardcoded `y = 4` had
/// it sitting on top of the summary line before this was measured.
const rerun_size: struct { w: f32, h: f32 } = .{ .w = 124, .h = 26 };

// ── ★★★ THE COVERAGE GATE ──
//
// Every kernel entry must be exercised by exactly one row, and every row must name a kernel that
// exists. Without this the sweep's green says something about the rows someone REMEMBERED to add,
// not about the kernel set — and `sub` and `div` sat on the CPU for six turns with no kernel
// precisely because nothing was watching.
//
// ★★ IT IS A COMPILE ERROR, NOT A TEST. A kernel added without a row cannot build, so the gap
// cannot survive to a device. `build.zig`'s drift gate already covers the other edge (a kernel
// with no WGSL fails to embed), so the three lists — kernel file, build entries, sweep rows —
// are now pinned to each other in both directions.
//
// ★ WHAT THIS DOES NOT COVER, stated so it is not mistaken for more than it is: it pins
// KERNEL ↔ ROW. It cannot pin OP ↔ KERNEL — a `zimrnum` function with no GPU kernel at all is
// still invisible here, because zimrnum has no device dispatch of its own yet. That gate belongs
// with the dispatch seam, and §10.3 debt 11 stays open until then.
comptime {
    // ── ★★★ EVERY BUFFER A KERNEL READS MUST BE ONE THE HOST UPLOADS ──
    //
    // `where_pick` read its selector from `c` and nothing uploaded it. The headless twin test
    // filled `c` by hand and passed; the sweep never did, and the device failed the row with the
    // input data instead of a 0/1 mask. **A buffer the host never writes is invisible to every
    // check that runs on the host**, because the host's own test fills it as part of being a
    // test.
    //
    // ★ So: this file must contain an `upload` call for every field of every pipeline's `Buffers`
    // that is not the output. Checked by searching this file's own source, which is crude and is
    // exactly as strong as it needs to be — the failure it prevents is a missing line.
    // ★ The quota is generous because the search walks this whole file; a comptime string scan
    // over 60 KB is thousands of branches and the default stops well short.
    @setEvalBranchQuota(2_000_000);
    const source: []const u8 = @embedFile("zimrnum_field.zig");
    for (.{ "a", "b", "c" }) |field| {
        const needle: []const u8 = ".upload(." ++ field ++ ",";
        if (std.mem.indexOf(u8, source, needle) == null) {
            @compileError("zn_binary buffer `" ++ field ++ "` is never uploaded by the host");
        }
    }
    for (.{"x"}) |field| {
        const needle: []const u8 = "pipe_un.upload(." ++ field ++ ",";
        if (std.mem.indexOf(u8, source, needle) == null) {
            @compileError("zn_unary buffer `" ++ field ++ "` is never uploaded by the host");
        }
    }
}

comptime {
    // 23 rows x 22 entries of string comparison overruns the default quota; the check is O(n*m)
    // and n and m both grow with the port, so raise it once here rather than per addition.
    @setEvalBranchQuota(200_000);
    for (cases) |c| {
        const names: []const [:0]const u8 = switch (c.kind) {
            .binary => &zn_binary.kernels,
            .unary => &zn_unary.kernels,
            .matmul => &zn_matmul.kernels,
        };
        var found: usize = 0;
        for (names) |name| {
            if (std.mem.eql(u8, name, c.entry)) {
                found += 1;
            }
        }
        if (found != 1) {
            @compileError("sweep row '" ++ c.label ++ "' names entry '" ++ c.entry ++
                "', which its kernel file does not export");
        }
    }
    coverEvery(zn_binary.kernels, .binary);
    coverEvery(zn_unary.kernels, .unary);
    coverEvery(zn_matmul.kernels, .matmul);
}

/// Assert every entry of one kernel file is exercised by exactly one row.
fn coverEvery(comptime names: anytype, comptime kind: Kind) void {
    for (names) |name| {
        var rows: usize = 0;
        for (cases) |c| {
            if (c.kind == kind and std.mem.eql(u8, name, c.entry)) {
                rows += 1;
            }
        }
        if (rows == 0) {
            @compileError("kernel entry '" ++ name ++ "' has no row in the sweep: it is built, " ++
                "shipped, and never compared against zimrnum");
        }
        // ONE KERNEL MAY HAVE SEVERAL ROWS, AND THAT IS NOW THE POINT
        //
        // This used to require exactly one, on the reasoning that two rows for one kernel is a
        // copy-paste slip. It is not: the same kernel on a DIFFERENT INPUT FIELD is a different
        // question, and asking it is how the `tanh` cancellation bug would have been caught years
        // earlier. A duplicate row costs three frames; a missing row costs a kernel nobody checks.
        // The bar is "at least one", and the asymmetry is deliberate.
    }
}

/// A tensor of the sweep's fixed element type, spelled once.
const Tn = zn.Tensor(f32);

/// Which pipeline an entry belongs to, which is also which buffers it reads.
const Kind = enum { binary, unary, matmul };

/// One row of the sweep: everything that differs between kernels, in one place.
///
/// ── ★★★ ONE TABLE INSTEAD OF FOUR PARALLEL SWITCHES ──
///
/// Adding a kernel used to mean eight edits: an enum variant, an arm in `next`, one in `label`,
/// one in `tolerance`, one in `isUnary`, one in `buildFields`, one in the dispatch, and a slot in
/// two hand-written array literals. Eight chances to add a row that reports the wrong reference,
/// which is exactly the bug that produced `FAIL add worst 23.9` earlier.
///
/// Now it is ONE `Case` here plus the kernel itself plus `build.zig`'s entry — and the drift gate
/// catches the last of those. The `cpu` field carries the reference implementation inline, so a
/// row's GPU entry and its oracle are written on the same line and cannot drift apart.
const Case = struct {
    label: []const u8,
    /// Absolute allowance. Zero where both sides do the same flops in the same order.
    tol: f32,
    /// ── ★★★ AN ALLOWANCE THAT SCALES WITH THE ROW'S MAGNITUDE ──
    ///
    /// An absolute bar of zero is only ever right when the output is O(1) or the operation is
    /// exact. `div` is neither: measured, its outputs peak at 102.5, where **one ULP of f32 is
    /// 1.22e-5** — and the device's worst deviation was **1.9e-6, six times SMALLER than a single
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
    /// elementwise — but a ROW-WISE kernel wants one per row, and dispatching 4096 threads for
    /// 64 rows would have 4032 of them return immediately from the guard. Making it explicit
    /// keeps the launch geometry next to the kernel it belongs to.
    threads: u32 = count,
    /// ── ★★★ HOW MANY OUTPUTS THIS ROW ACTUALLY PRODUCES ──
    ///
    /// A REDUCTION does not fill the output buffer. `sum_axis0` writes 64 values and `sum_all`
    /// writes one; comparing all 4096 would be comparing whatever the previous dispatch left
    /// behind, and the row would fail for a reason having nothing to do with the kernel.
    ///
    /// ★ Defaulting to one per element leaves every elementwise row untouched and makes the
    /// reduction rows state their own shape rather than the harness guessing it.
    out_len: u32 = count,
    /// ── ★★★ WHICH INPUT THIS ROW IS ENTITLED TO ──
    ///
    /// `sqrt` and `log` are **undefined** below zero in WGSL — not NaN, undefined — so an
    /// implementation may return NaN, an infinity, zero or anything else. Measured on device:
    /// both rows reported `inf`, because the CPU produced NaN and the GPU did not agree. That is
    /// not a defect in either; it is a comparison of two undefined results, and it says nothing.
    ///
    /// ★ So a row may ask for the POSITIVE field instead — `|noise| + 0.5`, strictly above zero
    /// so `log` is defined too. That is what a caller does: check the domain before calling. The
    /// row then tests the OPERATION rather than two implementations' undefined behaviour.
    /// Which field this row's input comes from.
    ///
    /// ★ `unit` was added when `atanh` failed on the device with a worst of **inf**: `atanh` is
    /// ±infinity at ±1 and NaN beyond, so on the noise field BOTH sides return inf and their
    /// difference is NaN — which is not ≤ any bar. The row was asking a question with no finite
    /// answer, and the fix is a field the function is defined on rather than a wider tolerance.
    /// `tiny` was added when `zm.tanh` turned out to be 1.0 relative error at f32 NEAR ZERO and
    /// the sweep had never noticed: a normal(0,1) field has no values small enough for
    /// cancellation to bite. **A test's input distribution decides which bugs it can see**, and
    /// every row here had been asked about one distribution.
    input: enum { noise, positive, unit, tiny } = .noise,
};

const cases = [_]Case{
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
    // ★★ The bias add. `a` is the field; `b` is read with a row stride of ZERO on the GPU, so
    // its first row is stretched down — and the CPU oracle stretches the same row with
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
                // ★ Against the COMPENSATED sum, deliberately. The kernel accumulates plainly, so
                // this row measures how far a plain 4096-term accumulation drifts from the exact
                // answer — the number that justifies `sumAll`'s default.
                o.data[0] = zn.sumAll(f32, a);
            }
        }.f,
    },
    .{
        // ★★ The same answer as `sum all (scalar)` by a different route: 64 lanes and a 6-level
        // shared-memory tree instead of one thread. Both are compared against `zn.sumAll`, so a
        // barrier mistake or a race shows up as this row disagreeing with the one above it —
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
        // ★ Tolerance 0, and that is not optimism: a maximum is a SELECTION, not an
        // accumulation. Every candidate is a value that already exists in the input, so both
        // sides must return the same bits or one of them is comparing wrongly. A nonzero bar
        // here would hide a real defect rather than absorb rounding — there is no rounding.
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
    // ── ★★★ TOLERANCES CHOSEN PER OPERATION, NOT PER BATCH ──
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
    // ★★ `reciprocal` takes the POSITIVE input, not the noise. 1/x is defined at every non-zero
    // real, but the noise field can come arbitrarily close to zero, and a quotient near 1e30 has
    // a ULP of 1e23 — a bar that would accept anything. The positive field bounds the output at
    // 2, so the row measures the division rather than the luck of the draw.
    //
    // ★ `trunc` and `round` are exact on both sides: they return integers both backends reach
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
        // ── ★★★ 16 ULP, AND zm's OWN COMMENT IS THE JUSTIFICATION ──
        //
        // `zm.atan2Rad` is `std.math.atan2` on the host — exact, a hundred lines — and a
        // **DirectXMath-derived polynomial** on the GPU. The two backends run deliberately
        // different algorithms, so the agreement is bounded by the polynomial's accuracy, not by
        // rounding. Measured on device: **9.6 ULP**, against 1.5 for `sin` and 1.6 for `cos`,
        // whose GPU path is a much closer approximation.
        //
        // ★★ My first bar was 4 ULP, guessed by analogy with the other transcendentals, and the
        // device rejected it. **The number came from the implementation, not from the pattern** —
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
    // ★ All five have a tolerance of ZERO. The masks return literal 0 or 1; `clamp` is two
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
    // ★★ `leaky relu` has a tolerance of ZERO: both branches are a compare and a single multiply,
    // exact on both sides. `elu` and `softplus` get 2 ULP for their `exp`, and `mse loss` gets 64
    // because the kernel accumulates 4096 terms plainly against a compensated reference — the
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
    // ★ `max axis0`, `min axis0` and `argmax axis0` are SELECTIONS: tolerance zero. `mean axis0`
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
    // ★★ THE THREE LOSSES NOW COMPARE PLAIN AGAINST COMPENSATED, like `mse loss`: the kernel
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
    // ★★ THE THREE ROWS THE THIRD BUFFER UNBLOCKED. Each was host-only for want of a binding,
    // not for any reason of algorithm.
    .{
        .label = "where",
        .tol = 0,
        .kind = .binary,
        .entry = "where_pick",
        .cpu = struct {
            fn f(o: Tn, a: Tn, b: Tn) anyerror!void {
                // The mask the kernel reads from `c` is `greater(a, b)`, built the same way here.
                // ★ The scratch lives INSIDE the closure, as a static local. A module-level
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
        // ★ 8 rather than 4: the device measured 1.43e-6 against a 9.4e-7 bar, which is 4.8 ULP.
        // `asinh` is three roundings deep — a square root, an add and a log — so the bar was set
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

/// One operation's verdict, filled in as the page walks the list.
const Result = struct {
    done: bool = false,
    worst: f32 = 0,
    /// The largest reference magnitude in the row, which is what `ulps` scales against.
    peak: f32 = 0,
    checked: u32 = 0,
};

const State = struct {
    font: z.Font,
    pipe: z.Compute(zn_binary),
    pipe_mm: z.Compute(zn_matmul),
    pipe_un: z.Compute(zn_unary),

    /// The two dense operands both backends see.
    field_a: []f32,
    field_b: []f32,
    /// `|field_a| + 0.5`: strictly positive, for the rows whose operation needs it.
    field_p: []f32,
    /// `tanh(noise)`, so every value lies strictly inside (-1, 1) — the domain of `atanh`.
    field_u: []f32,
    /// The `where` row's selector, `greater(a, b)`, which the kernel reads from buffer `c`.
    field_c: []f32,
    /// A narrow band of magnitudes near 1e-6, both signs. Narrow because the sweep's bar is
    /// `ulps * peak`: a field spanning decades takes its bar from its largest element and stops
    /// testing the small ones at all.
    field_t: []f32,
    /// ── ★★★ ALL FOUR CPU REFERENCES, COMPUTED ONCE ──
    ///
    /// The inputs never change, so each operation's answer is fixed. Computing them up front
    /// removes the bug that produced `FAIL add worst 23.9`: the sweep used to rebuild `cpu_out`
    /// the instant it advanced, while `readLatest` still held the PREVIOUS dispatch's data — so
    /// operation N's GPU result was compared against operation N+1's reference. Nothing was wrong
    /// with either kernel.
    cpu_ref: [cases.len][]f32,
    cpu_out: []f32,
    gpu_out: []f32,

    /// The operation being measured. It ADVANCES ON ITS OWN — no tapping. A round trip to a
    /// phone costs minutes, so one screenshot has to answer every question.
    /// Index into `cases`. It advances on its own — no tapping.
    op: usize = 0,
    dispatched: bool = false,
    /// Frames to let the queue settle before a readback is believed. `readLatest` returns the
    /// most recent COMPLETED transfer, which is the previous operation's until this one lands;
    /// consuming it early is what mismatched the rows.
    settle: u32 = 0,
    /// The dispatch this row is waiting on, or null before it has been dispatched.
    ///
    /// Set from `readGeneration().submitted` AFTER the dispatch, so it names this row's work.
    /// The row retires when `mirrored` reaches it.
    await_generation: ?u64 = null,
    results: [cases.len]Result = @splat(.{}),
    /// Whether a failure has already claimed the heatmaps.
    holding: bool = false,
    /// Where the re-run button was drawn last frame. The hit test reads this rather than a
    /// constant, so the two can never disagree.
    rerun: z.Rectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// ── ★★★ THE PAGE HAS TO SCROLL, AND SORTING ALONE IS NOT ENOUGH ──
    ///
    /// Forty-eight rows plus three heatmaps already exceed a phone screen, and the port is headed
    /// past a hundred. Two changes, because they solve different halves:
    ///
    /// ★★ **Failures sort to the top**, so the rows that matter are visible without touching
    /// anything — which is what a screenshot needs.
    /// ★ **Drag or wheel scrolls**, for reading the rest.
    scroll: f32 = 0,
    /// True between a press that began outside the button and the release that ends it. A drag
    /// with no beginning cannot tell a finger arriving from a finger moving.
    dragging: bool = false,
    /// Where the finger went down, and what `scroll` was at that moment. The pair is what lets
    /// the drag be absolute instead of a sum of per-frame deltas.
    drag_from: f32 = 0,
    scroll_from: f32 = 0,
    /// Total drawn height, so the scroll can be clamped to content that actually exists rather
    /// than to a guess.
    content_height: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.field_a);
    gpa.free(s.field_b);
    gpa.free(s.field_p);
    gpa.free(s.field_u);
    gpa.free(s.field_c);
    gpa.free(s.field_t);
    for (s.cpu_ref) |r| {
        gpa.free(r);
    }
    gpa.free(s.cpu_out);
    gpa.free(s.gpu_out);
    z.unloadFont(gpa, s.font);
    s.pipe.deinit();
    s.pipe_mm.deinit();
    s.pipe_un.deinit();
}

/// Build the two operands with zimrnum, then every operation's reference answer.
///
/// ★ Called ONCE. The inputs are fixed, so the four answers are fixed, and recomputing one of
/// them mid-sweep is what let a stale readback be judged against the wrong reference.
fn buildFields(s: *State) !void {
    const shape = [_]usize{ side, side };
    const a: zn.Tensor(f32) = try zn.Tensor(f32).fromSlice(s.field_a, &shape);
    const b: zn.Tensor(f32) = try zn.Tensor(f32).fromSlice(s.field_b, &shape);

    // Operand A: noise. Two labels off one seed, so nothing has to be coordinated.
    const rng: zn.Rng = zn.Rng.init(20260904);
    rng.split(0).fillNormal(f32, s.field_a);

    // Operand B: a single row ramp, stretched down the field. `broadcastTo` makes that a view
    // with a stride of 0 on the row axis — no storage, no copy.
    var ramp_row: [side]f32 = undefined;
    for (0..side) |i| {
        ramp_row[i] = float(@as(u32, @intCast(i))) / float(side) * 2.0 - 1.0;
    }
    const row: zn.Tensor(f32) = try zn.Tensor(f32).fromSlice(&ramp_row, &.{ 1, side });
    const stretched: zn.Tensor(f32) = try row.broadcastTo(&shape);

    // ★★ MATERIALISE IT. The stretched view is fine for the CPU walk and cannot be bound to a
    // kernel, which takes a dense buffer. Adding it to a zeroed field is the densify step.
    b.fill(0.0);
    try zn.add(f32, b, b, stretched);

    // ★ `|a| + 0.5`, so `log` is defined too — a plain `|a|` would still hit zero and give -inf.
    for (s.field_p, s.field_a) |*slot, x| {
        slot.* = @abs(x) + 0.5;
    }
    // ★ `tanh` maps the whole real line into (-1, 1) exactly, so this field is inside the domain
    // of `atanh` by construction rather than by clamping — and it still spans most of the range.
    for (s.field_u, s.field_a) |*slot, x| {
        slot.* = zm.tanh(x);
    }
    // Eight decades of magnitude below 1, alternating sign. Spread by index rather than drawn,
    // so the smallest values are guaranteed present rather than merely likely.
    // A NARROW BAND. THE FIRST VERSION SPANNED EIGHT DECADES AND WAS USELESS.
    //
    // The sweep compares the worst ABSOLUTE difference against a bar of `ulps * peak`, where peak
    // is the largest reference value in the row. Spread a field over eight decades and the peak
    // comes from the largest element, so the bar sits far above anything the smallest elements
    // could fail. Measured on the exact bug these rows were added for - the old `tanh`, which
    // returns 0 where the answer is x:
    //
    //     eight decades:  peak 9.97e-2  worst 1.92e-8  bar 4.75e-8   MISSED
    //     band near 1e-6: peak 1.79e-6  worst 2.67e-8  bar 8.52e-13  CAUGHT
    //
    // **The rows would not have caught the bug they exist for.** A band keeps every value inside
    // one decade, so the peak IS the scale of the field and the bar means something at that
    // scale. One band tests one scale; 1e-6 is where a cancelling f32 formula has lost most of
    // its digits without yet collapsing to zero.
    for (s.field_t, 0..) |*slot, i| {
        const step: f32 = @floatFromInt(i % 8);
        const jitter: f32 = 1.0 + 0.9 * step / 8.0;
        const magnitude: f32 = 1.0e-6 * jitter;
        slot.* = if (i % 2 == 0) magnitude else -magnitude;
    }

    const positive: Tn = try Tn.fromSlice(s.field_p, &shape);
    const unit: Tn = try Tn.fromSlice(s.field_u, &shape);
    const tiny: Tn = try Tn.fromSlice(s.field_t, &shape);
    for (s.cpu_ref, cases) |slot, c| {
        const src: Tn = switch (c.input) {
            .noise => a,
            .positive => positive,
            .unit => unit,
            .tiny => tiny,
        };
        const out: Tn = try Tn.fromSlice(slot, &shape);
        // Zeroed first: a reduction writes only `out_len` values, and the rest of the reference
        // would otherwise be whatever the allocator handed over — visible in the heatmap even
        // though the verdict ignores it.
        out.fill(0);
        try c.cpu(out, src, b);
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);

    var pipe: z.Compute(zn_binary) = try z.Compute(zn_binary).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &pipelineEntries(zn_binary),
    );
    pipe.element_count = count;
    // Row-major strides for `bcast_add`: `a` is a full field, `b` is its first row stretched
    // down — `b_row = 0` is the broadcast, exactly as `broadcastTo` does it on the CPU.
    pipe.params = .{
        .count = count,
        .scalar = learning_rate,
        .cols = side,
        .delta = huber_delta,
        .momentum = momentum,
        .a_row = side,
        //  is the only row that uses it; every other leaves each element alone.
        .repeat_count = 2,
        .a_col = 1,
        .b_row = 0,
        .b_col = 1,
        // Their own fields, not the strides above: see the note in zn_binary.
        .slice_start = side / 2,
        .left_columns = side / 2,
    };

    var pipe_mm: z.Compute(zn_matmul) = try z.Compute(zn_matmul).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &pipelineEntries(zn_matmul),
    );
    pipe_mm.element_count = count;
    // (64, 64) @ (64, 64). The tiled entry needs the same thread count: 4x4 tiles of 256 lanes.
    pipe_mm.params = .{ .m = side, .n = side, .kdim = side };

    var pipe_un: z.Compute(zn_unary) = try z.Compute(zn_unary).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &pipelineEntries(zn_unary),
    );
    pipe_un.element_count = count;
    pipe_un.params = .{
        .count = count,
        .scalar = learning_rate,
        .cols = side,
        .epsilon = layernorm_epsilon,
        .lo = clamp_lo,
        .hi = clamp_hi,
        .alpha = elu_alpha,
        .pool = 2,
    };

    s.* = .{
        .font = font,
        .pipe = pipe,
        .pipe_mm = pipe_mm,
        .pipe_un = pipe_un,
        .field_a = try gpa.alloc(f32, count),
        .field_b = try gpa.alloc(f32, count),
        .field_p = try gpa.alloc(f32, count),
        .field_u = try gpa.alloc(f32, count),
        .field_c = try gpa.alloc(f32, count),
        .field_t = try gpa.alloc(f32, count),
        // Filled by the loop below: one reference per `cases` entry, so the count follows
        // the table and cannot drift from it.
        .cpu_ref = undefined,
        .cpu_out = try gpa.alloc(f32, count),
        .gpu_out = try gpa.alloc(f32, count),
    };
    for (&s.cpu_ref) |*slot| {
        slot.* = try gpa.alloc(f32, count);
    }
    try buildFields(s);
    s.pipe.upload(.a, s.field_a);
    s.pipe.upload(.b, s.field_b);
    // ── ★★★ THE MASK THE `where` KERNEL READS ──
    //
    // `where_pick` reads its selector from the `c` buffer, and **nothing was uploading it**. The
    // headless twin test filled `c` by hand and passed; the sweep never did, so on the device the
    // kernel selected from an empty buffer and the row failed with a worst of 4.2 — the input
    // data itself, not a 0/1 mask.
    //
    // ★ A buffer a kernel READS but the host never WRITES is invisible to every check that runs
    // on the host, because the host's own twin test fills it as part of the test. The device is
    // the only thing that can see it, and it did.
    for (s.field_c, s.field_a, s.field_b) |*slot, x, y| {
        slot.* = if (x > y) 1 else 0;
    }
    s.pipe.upload(.c, s.field_c);
    s.pipe_mm.upload(.a, s.field_a);
    s.pipe_mm.upload(.b, s.field_b);
    s.pipe_un.upload(.x, s.field_a);
}

/// The worst absolute disagreement, and the largest reference magnitude, over the pair.
///
/// ★★★ A NON-FINITE DISAGREEMENT CANNOT BE SKIPPED. `@abs(inf - inf)` is NaN, and `NaN > worst`
/// is FALSE — so the obvious loop silently ignores exactly the elements most likely to be wrong.
/// The `div` row proves this is not hypothetical: the ramp crosses zero, so a whole column
/// divides by zero and every one of those comparisons was being dropped. A GPU returning NaN
/// where the CPU returned infinity would have passed. Now a mismatch in FINITENESS is reported
/// as infinity, which no tolerance can accept.
const Comparison = struct { worst: f32, peak: f32 };

fn compare(gpu: []const f32, cpu: []const f32) Comparison {
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
            // ★★ RECORDED, NOT RETURNED. Returning here left `peak` holding whatever had
            // accumulated before the first disagreement, so a failing row displayed a bar of 0
            // and no reader could tell what it had been judged against. The scan always
            // completes now.
            mismatched = true;
            continue;
        }
        if (!isFinite(g)) {
            // ★★★ TWO NaNs ARE AGREEMENT. `NaN != NaN` is true, so the obvious `g != c` reports
            // a mismatch whenever BOTH sides correctly produce NaN — which is every partial
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

/// The bar this row is judged against: its absolute allowance plus `ulps` units in the last place
/// of its own peak magnitude.
fn barFor(c: Case, peak: f32) f32 {
    return c.tol + c.ulps * peak * floatEps(f32);
}

/// One cell of a heatmap: blue below zero, red above, brightness with magnitude.
fn heat(v: f32) Color {
    // ★★ ZERO MUST BE NEUTRAL. The first version returned dark red at v == 0, so a difference
    // panel that was exactly zero everywhere rendered as a solid red block — the same picture a
    // uniformly small POSITIVE error would give. The whole point of the third panel is to tell
    // those apart, so the saturation now falls to nothing as the magnitude does.
    const m: f32 = @min(@abs(v) / 3.0, 1.0);
    const hue: f32 = if (v < 0) 220.0 else 12.0;
    return z.colorFromHSV(hue, 0.85 * m, 0.10 + 0.75 * m);
}

/// Draw `data` as a heatmap, one rect per BLOCK of `block`x`block` elements.
///
/// ── ★★★ WHY IT DOWNSAMPLES, AND WHY BY MAGNITUDE ──
///
/// Three 64x64 panels is 12 288 rects a frame, and with the UI's glyphs on top that overflowed
/// the vertex ring: `flushBatch` asserts rather than corrupt, so the page panicked in the smoke
/// runner. Sampling every other element would fix the count and lose the point — a single wrong
/// element could fall in a skipped position, and the difference panel exists precisely to show
/// one wrong element.
///
/// So each block is represented by its LARGEST-MAGNITUDE member, sign kept. An outlier anywhere
/// in a block survives to the screen; only the fine texture of agreeing values is lost, and that
/// texture was never the information.
fn drawField(
    f: *z.Frame,
    data: []const f32,
    x0: f32,
    y0: f32,
    cell: f32,
    gain: f32,
) void {
    const block: usize = 2;
    const cells: usize = side / block;
    var row: usize = 0;
    while (row < cells) : (row += 1) {
        var col: usize = 0;
        while (col < cells) : (col += 1) {
            var peak: f32 = 0;
            for (0..block) |dr| {
                for (0..block) |dc| {
                    const v: f32 = data[(row * block + dr) * side + (col * block + dc)];
                    if (@abs(v) > @abs(peak)) {
                        peak = v;
                    }
                }
            }
            f.gl.rect(.{
                .x = x0 + float(@as(u32, @intCast(col))) * cell,
                .y = y0 + float(@as(u32, @intCast(row))) * cell,
                .width = cell,
                .height = cell,
            }, .{ .color = heat(peak * gain) });
        }
    }
}

/// One pipeline's dispatch counters, in a type all three can be read into.
///
/// The three pipelines are different `Compute(M)` instantiations, so each has its own
/// `Generation` type even though the fields match. A local struct is what lets one variable
/// hold the answer from whichever pipeline this row uses.
const Gen = struct { submitted: u64, mirrored: u64 };

fn update(f: *z.Frame, s: *State) void {
    // Tapping anywhere switches the operation; both backends recompute from the same inputs.
    // ── ★★★ A BUTTON, NOT THE WHOLE SCREEN ──
    //
    // Tapping anywhere used to re-run the sweep, which meant every scroll, every stray touch and
    // every attempt to read a number restarted the measurement. A verifier that discards its
    // result when you look at it is a verifier you cannot read.
    const mouse: zm.Vec2 = z.getMousePosition(f.input);
    const over: bool = mouse[0] >= s.rerun.x and mouse[0] <= s.rerun.x + s.rerun.width and
        mouse[1] >= s.rerun.y and mouse[1] <= s.rerun.y + s.rerun.height;
    // Wheel, and vertical drag anywhere outside the button. Clamped to real content: scrolling
    // past the end leaves a reader staring at nothing and wondering if the page broke.
    s.scroll -= z.getMouseWheelMove(f.input) * 40.0;

    // ── ★★★ A DRAG ANCHORS ON THE PRESS FRAME, AND THAT FRAME'S DELTA IS DISCARDED ──
    //
    // This used to apply `getMouseDelta` on every frame the button was down, including the frame
    // it went down on. With a mouse that is harmless — the pointer was already where you clicked,
    // so the delta is nearly zero. **With a finger it is the bug**: the pointer TELEPORTS from
    // wherever it last was to wherever you touched, and that entire jump arrives as one frame's
    // delta. Touching the bottom of the page to start scrolling flung it by the distance from the
    // last touch point, which reads as the page popping out from under you.
    //
    // ★ So a drag has a beginning: the press frame sets `dragging` and contributes NOTHING, and
    // only later frames move the page. The page now stays exactly where it was until the finger
    // actually moves, which is what every other scrolling surface does.
    if (z.isMouseButtonPressed(f.input, .left)) {
        s.dragging = !over;
        s.drag_from = mouse[1];
        s.scroll_from = s.scroll;
    } else if (s.dragging and z.isMouseButtonDown(f.input, .left)) {
        // ★★ ABSOLUTE, NOT ACCUMULATED. `scroll = scroll_at_press - (moved since press)` makes
        // the content track the finger exactly: the pixel under it at the press stays under it,
        // and no per-frame delta is ever added, so a dropped or doubled frame cannot make the
        // page drift away from the finger over a long drag.
        s.scroll = s.scroll_from - (mouse[1] - s.drag_from);
    }
    if (!z.isMouseButtonDown(f.input, .left)) {
        s.dragging = false;
    }
    const limit: f32 = @max(0.0, s.content_height - f.window.heightf() + 20.0);
    s.scroll = @min(@max(s.scroll, 0.0), limit);

    if (over and z.isMouseButtonPressed(f.input, .left)) {
        s.results = @splat(.{});
        s.op = 0;
        s.holding = false;
        s.dispatched = false;
    }
    if (false) {
        s.op += 1;
        // Rebuilding cannot fail — the shapes are fixed and no allocation happens — but a
        // swallowed error would leave the panels showing a stale field with nothing to say so.
        s.dispatched = false;
    }

    if (!s.dispatched) {
        s.dispatched = true;
        // ── ★★★ THREE FRAMES, BECAUSE THE DEVICE MEASURED THE QUEUE AT THREE ──
        //
        // The previous version waited ONE frame and detected staleness by comparing the readback
        // against the PREVIOUS row's output. **That was wrong, and the device proved it**: with a
        // three-deep queue the readback is row N−3's data, which does not match row N−1's
        // reference either — so it was accepted as fresh and compared against row N. Two rows
        // failed with worst errors of 9.8 and 4.2, which for 0/1 masks can only be another row's
        // data.
        //
        // ★★ A staleness test that compares against ONE previous row can only catch a lag of
        // exactly one. Catching a lag of three needs either a comparison against the last three —
        // which is three chances to collide with a legitimately identical output — or a label
        // travelling with the data, which the sweep has no spare buffer element for.
        //
        // ★ So: three frames, matched to the depth `zimrnum_train` measured. 86 rows × 3 is about
        // **2.2 s at 120 Hz**, a little over the two-second budget. Correctness first; the budget
        // is bought back by splitting the sweep when it next grows, not by reading early.
        // ★★★ SIX, NOT THREE - AND THE DEVICE RAISED IT TWICE NOW.
        //
        // Three was matched to the queue depth `zimrnum_train` measured. It held for 86 rows and
        // then failed again at 91: `bcast add (bias)` came back **inf** and `tanh grad` **3.84**,
        // against bars of zero. Both twins are EXACT on the host, so the kernels and the
        // reference agree and neither number is a perturbation of the right answer - they are
        // another row's data, the same signature as the 9.8 and 4.2 recorded above.
        //
        // The depth is not a constant of the hardware; it moves with row count, with what else
        // the browser is doing, and with the build. **A number that has been wrong twice should
        // be set from the budget, not from the last measurement.** Six frames is 91 x 6 = 546
        // frames, 4.6 s at 120 Hz, inside the six-second budget - so the whole margin available
        // is spent on being sure, which is what the budget was raised for.
        // WAIT FOR THIS DISPATCH, NOT FOR SIX FRAMES
        //
        // The six above was set from the time budget rather than measured, and its own comment
        // said so - because there was no way to ask which dispatch a readback belonged to.
        // `readGeneration` answers that now, so the wait is exact: record the submission count
        // after dispatching and retire the row when the mirror reaches it.
        //
        // Never early, never longer than necessary, and it does not move with row count or with
        // what else the browser is doing - which is what made the old number wrong twice.
        s.settle = 0;
        s.await_generation = null;
        // `run` takes the entry name at comptime, so the branch selects the CALL, not a string.
        // ★ `run` takes the entry name at COMPTIME, so the selection is an `inline for` over
        // the table rather than a runtime lookup — the loop is unrolled and each arm passes a
        // literal.
        // ★★ THE DEVICE MUST SEE THE SAME INPUT THE REFERENCE DID. Uploading per dispatch is
        // 16 KB of traffic on a row that already reads 4096 elements — nothing — and it removes
        // the possibility of the two sides being compared on different data, which is the bug
        // that produced `FAIL add worst 23.9` earlier in this port.
        switch (cases[s.op].input) {
            .noise => s.pipe_un.upload(.x, s.field_a),
            .positive => s.pipe_un.upload(.x, s.field_p),
            .unit => s.pipe_un.upload(.x, s.field_u),
            .tiny => s.pipe_un.upload(.x, s.field_t),
        }
        inline for (cases, 0..) |c, i| {
            if (i == s.op) {
                switch (c.kind) {
                    .binary => {
                        s.pipe.run(c.entry, c.threads);
                        s.await_generation = s.pipe.readGeneration().submitted;
                    },
                    .unary => {
                        s.pipe_un.run(c.entry, c.threads);
                        s.await_generation = s.pipe_un.readGeneration().submitted;
                    },
                    .matmul => {
                        s.pipe_mm.run(c.entry, c.threads);
                        s.await_generation = s.pipe_mm.readGeneration().submitted;
                    },
                }
            }
        }
    }
    // Frame-delayed readback: last frame's mapped data, so the queue is never stalled. Whichever
    // pipeline is live for this mode is the one asked.
    const readback: ?[]const f32 = switch (cases[s.op].kind) {
        .binary => s.pipe.readLatest(.out),
        .unary => s.pipe_un.readLatest(.out),
        .matmul => s.pipe_mm.readLatest(.out),
    };
    // THE ROW RETIRES WHEN THE MIRROR REACHES ITS OWN DISPATCH
    //
    // `readback` being non-null means SOME copy landed; the generation says whose. Comparing
    // them is what removes the guess - a row that has not been dispatched yet
    // (`await_generation == null`) and one whose data has not arrived both wait, and neither
    // waits a frame longer than it has to.
    // The three pipelines are different `Compute(M)` instantiations, so their `Generation`
    // types are distinct even though the fields match. Reading the fields out separately is
    // what lets one variable hold the answer from any of them.
    const generation: Gen = switch (cases[s.op].kind) {
        .binary => blk: {
            const g: @TypeOf(s.pipe).Generation = s.pipe.readGeneration();
            break :blk Gen{ .submitted = g.submitted, .mirrored = g.mirrored };
        },
        .unary => blk: {
            const g: @TypeOf(s.pipe_un).Generation = s.pipe_un.readGeneration();
            break :blk Gen{ .submitted = g.submitted, .mirrored = g.mirrored };
        },
        .matmul => blk: {
            const g: @TypeOf(s.pipe_mm).Generation = s.pipe_mm.readGeneration();
            break :blk Gen{ .submitted = g.submitted, .mirrored = g.mirrored };
        },
    };
    const arrived: bool = if (s.await_generation) |wanted|
        generation.mirrored >= wanted
    else
        false;
    if (s.settle > 0) {
        s.settle -= 1;
    } else if (!arrived) {
        // Still in flight. Nothing to do but let the next frame poll again.
    } else if (readback) |out| {
        const n: usize = @min(out.len, s.gpu_out.len);
        @memcpy(s.gpu_out[0..n], out[0..n]);
        const reference: []const f32 = s.cpu_ref[s.op];
        @memcpy(s.cpu_out[0..n], reference[0..n]);
        // Only the values this row actually produces.
        const judged: usize = @min(n, cases[s.op].out_len);
        const cmp: Comparison = compare(s.gpu_out[0..judged], reference[0..judged]);
        const worst: f32 = cmp.worst;
        s.results[s.op] = .{ .done = true, .worst = worst, .peak = cmp.peak, .checked = @intCast(judged) };

        // The FIRST failure keeps the heatmaps, so the picture explains the number.
        if (worst > barFor(cases[s.op], cmp.peak) or judged != cases[s.op].out_len) {
            s.holding = true;
        }
        if (!s.results[s.results.len - 1].done) {
            s.op += 1;
            s.dispatched = false;
            if (s.holding) {
                // Keep the failing picture on screen: re-dispatch but do not overwrite it.
                s.holding = true;
            }
        }
    }

    z.clearViewport(f, z.colors.slate_900);

    var passing: u32 = 0;
    var finished: u32 = 0;
    for (s.results, 0..) |r, i| {
        if (!r.done) {
            continue;
        }
        finished += 1;
        if (r.worst <= barFor(cases[i], r.peak) and r.checked == cases[i].out_len) {
            passing += 1;
        }
    }
    const all_done: bool = finished == s.results.len;

    // ── ★★★ PLAIN TEXT ROWS, NOT A UI TABLE ──
    //
    // The `ui.zig` version worked and Simon prefers this one. It is also the honest fit: this
    // page is read as a SCREENSHOT, so scrolling, column sizing and a frozen header buy nothing,
    // while the UI library cost ~400 KB of standalone and an extra frame-ordering contract to get
    // wrong — which it duly was, twice. Text rows have no such contract.
    var y: f32 = 10 - s.scroll;
    if (!all_done) {
        textRow(f, s, &y, z.colors.amber_400, 16, "zimrnum GPU sweep - {d}/{d} measured", .{
            finished,
            s.results.len,
        });
    } else if (passing == s.results.len) {
        textRow(f, s, &y, z.colors.emerald_400, 16, "ALL PASS - {d}/{d} agree with zimrnum", .{
            passing,
            s.results.len,
        });
    } else {
        textRow(f, s, &y, z.colors.red_400, 16, "{d}/{d} PASS - failures marked XX", .{
            passing,
            s.results.len,
        });
    }
    textRow(f, s, &y, z.colors.slate_500, 12, "     operation           worst |cpu-gpu|  bar", .{});

    // ★★ Two passes: everything that FAILED, then everything else. A reader opening this page
    // wants the exception, and at forty-eight rows the exception was below the fold.
    var pass_index: u8 = 0;
    while (pass_index < 2) : (pass_index += 1) {
        for (s.results, cases) |r, c| {
            const failed: bool = r.done and
                (r.worst > barFor(c, r.peak) or r.checked != c.out_len);
            if ((pass_index == 0) != failed) {
                continue;
            }
            if (!r.done) {
                textRow(f, s, &y, z.colors.slate_600, 12, " ..  {s}", .{c.label});
                continue;
            }
            const bar: f32 = barFor(c, r.peak);
            const ok: bool = !failed;
            const tint: Color = if (ok) z.colors.emerald_400 else z.colors.red_400;
            // ★ The bar is printed WITH the deviation, because a verdict a reader cannot check is a
            // verdict they learn to ignore — and for the rows that scale by ULP it is not a constant.
            textRow(f, s, &y, tint, 12, " {s}  {s: <18} {d: <15} {d}", .{
                if (ok) "OK" else "XX",
                c.label,
                r.worst,
                bar,
            });
        }
    }

    const sw: f32 = f.window.widthf();
    const cell: f32 = @min((sw - 80.0) / float((side / 2) * 3), 5.0);
    const panel: f32 = float(side / 2) * cell;
    const top: f32 = y + 8;
    drawField(f, s.cpu_out, 20, top, cell, 1.0);
    drawField(f, s.gpu_out, 40 + panel, top, cell, 1.0);
    var diff: [count]f32 = undefined;
    for (s.cpu_out, s.gpu_out, 0..) |cv, gv, i| {
        diff[i] = cv - gv;
    }
    drawField(f, &diff, 60 + panel * 2, top, cell, 1000.0);

    // The button, drawn last so nothing overlaps it. Deliberately away from the table: the rows
    // are what a reader reaches for, and a control under a finger is a control pressed by
    // accident.
    var cap: f32 = top + panel + 4;
    caption(f, s, 20, &cap, "CPU");
    caption(f, s, 40 + panel, &cap, "GPU");
    caption(f, s, 60 + panel * 2, &cap, "diff x1000");

    // Placed BELOW the heatmaps, from the layout rather than a guess, and recorded for next
    // frame's hit test. Away from the rows, because a control under a finger is a control
    // pressed by accident — which is why tapping anywhere used to restart the measurement every
    // time someone tried to read it.
    s.rerun = .{ .x = 20, .y = cap + 6, .width = rerun_size.w, .height = rerun_size.h };
    // Recorded from the layout, so the scroll limit follows the content instead of a constant
    // that goes stale the next time a row is added.
    s.content_height = s.rerun.y + s.rerun.height + s.scroll;
    f.gl.rect(s.rerun, .{ .color = if (over) z.colors.slate_600 else z.colors.slate_700 });
    f.gl.rect(s.rerun, .{ .color = z.colors.slate_400, .outline = 1 });
    f.gl.text(
        .{ s.rerun.x + 16, s.rerun.y + 7 },
        "re-run sweep",
        .{ .size = 13, .color = z.colors.slate_100, .font = &s.font },
    );
    z.endDrawing(f.gl);
}

/// The only hand-drawn text left: three labels under the heatmaps, which sit outside the UI
/// window on purpose.
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

fn caption(
    f: *z.Frame,
    s: *State,
    x: f32,
    y: *f32,
    text: []const u8,
) void {
    f.gl.text(.{ x, y.* }, text, .{ .size = 13, .color = z.colors.slate_400, .font = &s.font });
}

/// Descriptor-only: the standalone runner or the launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - zimrnum field",
            .width = 900,
            .height = 460,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
