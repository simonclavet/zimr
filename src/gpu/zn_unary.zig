//! zn_unary.zig — the floating-point unary activations, ported from znum's `k_unary.zig`.
//!
//! ── ★★★ PORTED, NOT RE-DERIVED ──
//!
//! The shape is znum's and so is the reasoning: lean entries taking a raw `id`, one alias per
//! binding declared at module scope, a `kernels` list with a comptime loop that installs them,
//! and guards written as an early return because a unary kernel has no barrier to strand.
//!
//! ★★ THE BODIES ARE CALLS INTO `zm`, WHICH IS THE POINT. `zm.sigmoid` and friends compile for
//! the host and for SPIR-V from ONE source, so the CPU reference and this shader are the same
//! arithmetic rather than two implementations that agree until they do not. The sweep measures
//! whether that holds on a real device; the tutorial claims it, and a claim nobody measured is
//! just a sentence.
//!
//! ★ `T` is `f32` here. znum injects it per dtype through a module substitution
//! (`-Mdtype=kernels/dtype_f32.zig`), which is the next piece of that machinery to bring across.
const k = @import("kompute");
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const cosTurns = zm.cosTurns;
const exp = zm.exp;
const exp2 = zm.exp2;
const nan = zm.nan;
const abs = zm.abs;
const floor = zm.floor;
const ceil = zm.ceil;
const trunc = zm.trunc;
const round = zm.round;
const sinRad = zm.sinRad;
const cosRad = zm.cosRad;
const clamp = zm.clamp;
const float = zm.float;

// A KERNEL MAY ONLY CALL A `zm` FUNCTION THAT COMPUTES THE SAME EXPRESSION ON BOTH BACKENDS
//
// `zm.cosh` used to be `math.cosh` on the host and an identity on SPIR-V. Both are cosh, both are
// correct, and on the device they disagreed by **29.6** - because the sweep compares the host's
// answer against the GPU's, and a function with two routes has two answers.
//
// The headless twin test cannot see this: it compiles the kernel for the HOST, where `is_gpu` is
// false and every branch takes the CPU path. It measured 0.0 for cosh and was right about the
// only thing it can measure.
//
// So the rule is checked here, at comptime: every `zm` name these kernels call must appear in the
// list below, which is the set audited as branch-free. Adding a call to something else is a
// compile error, and the fix is either to audit that function or to write the expression out.
comptime {
    @setEvalBranchQuota(400_000);
    // Audited: each computes one expression, with no `is_gpu` branch that could diverge.
    const branch_free = [_][]const u8{
        "relu", "exp",   "abs",   "floor", "ceil",  "square", "expm1", "log1p",
        "sinh", "cosh",  "asinh", "atanh", "rsqrt", "sign",   "trunc", "round",
        "log2", "log10",
        // `exp2` is `@exp2(x)` and nothing else - checked before adding it here, which is what
        // this list is for: an entry added without reading the function is the audit failing
        // silently rather than the compile failing loudly.
        "exp2",
        // `nan(T)` is a comptime `@bitCast` of a constant per float width - no branch, no call,
        // nothing that could differ between backends. Read before adding, same as `exp2`.
         "nan",
        // `clamp(v, lo, hi)` is `min(hi, max(lo, v))`, and BOTH of those were read in zimrmath:
        // neither contains an `is_gpu` branch at all. Their vector path is a pair of `@select`s
        // for NaN handling - branch-free by construction - and their scalar path is the bare
        // `@min`/`@max` builtin. Read before adding, same as the two above.
        //
        // Two things this scan does that are worth knowing: it catches the ALIAS line
        // (`const clamp = ...;`) as well as call sites, and it is TEXTUAL - so naming the
        // qualified form of a function in a comment trips it too, which is why the sentence
        // above says 'in zimrmath' instead.
          "clamp",
        // `float(x)` is a comptime type-check that the argument is an integer, then a bare
        // `@floatFromInt(x)`. No branch, no call, nothing backend-dependent. It exists so the
        // conversion has a known result type, which `@floatFromInt` alone does not get through
        // a `*` or `/` peer - the compiler rejects that outright.
        "float",
    };
    // Known to branch on `is_gpu`, and deliberately allowed: their two routes are measured on the
    // device and agree inside their rows' bars - `sin` 1.8e-7, `cos` 1.9e-7, `tanh` and `sigmoid`
    // one ULP each.
    const measured_branching = [_][]const u8{
        "sinRad",   "cosRad",   "tanh", "sigmoid", "gelu", "silu",
        // These call `sin` and `cos` after an EXACT reduction, so they inherit exactly those
        // two entries' behaviour and nothing more.
        "sinTurns", "cosTurns",
    };
    const source: []const u8 = @embedFile("zn_unary.zig");
    // Written without `std`, because this file is compiled for SPIR-V and imports only what a
    // kernel needs. A three-character scan is small enough to spell out.
    var i: usize = 0;
    while (i + 3 < source.len) : (i += 1) {
        if (source[i] != 'z' or source[i + 1] != 'm' or source[i + 2] != '.') {
            continue;
        }
        var stop: usize = i + 3;
        while (stop < source.len) : (stop += 1) {
            const c: u8 = source[stop];
            const wordy: bool = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_';
            if (!wordy) {
                break;
            }
        }
        const name: []const u8 = source[i + 3 .. stop];
        if (name.len == 0) {
            continue;
        }
        var allowed: bool = false;
        for (branch_free) |ok| {
            if (ok.len == name.len) {
                var same: bool = true;
                for (ok, name) |a, b| {
                    if (a != b) {
                        same = false;
                    }
                }
                if (same) {
                    allowed = true;
                }
            }
        }
        for (measured_branching) |ok| {
            if (ok.len == name.len) {
                var same: bool = true;
                for (ok, name) |a, b| {
                    if (a != b) {
                        same = false;
                    }
                }
                if (same) {
                    allowed = true;
                }
            }
        }
        if (!allowed) {
            @compileError("kernel calls `zm." ++ name ++
                "`, which is not in the audited list - see the note above this check");
        }
    }
}

// THE THIRD EDGE OF THE TRIANGLE
//
// `zn` delegates to `zm` on the CPU. These kernels call `zm` on the GPU. So one sweep row now
// checks all three at once: zm's host path, zm's SPIR-V path, and the two against each other -
// where before, a kernel that hand-rolled the same arithmetic checked only that two people had
// written the same formula twice.
//
// Eighteen kernels here wrote out something `zm` already spelled. That is the duplication the
// `zm` vocabulary pin exists to prevent, and it had accumulated on the GPU side where the pin
// does not reach.

// The element type. znum injects this per dtype via a module substitution; until that machinery
// is ported, this file is the f32 instance.
const Elem = f32;

pub const config = k.Config{ .max = 1 << 14, .workgroup = 64 };

/// Convention: the last field is the output, the rest are inputs.
pub const Buffers = extern struct {
    x: [config.max]Elem,
    out: [config.max]Elem,
};

/// 16-byte sized, padded with scalars rather than an array: `[3]u32` emits `array<u32,3>` with
/// stride 4, which WGSL rejects in the uniform address space.
pub const Params = extern struct {
    count: u32,
    /// The multiplier for `scale`. A pad word carrying a value: the uniform must be 16-byte
    /// sized either way, so the scalar is free.
    scalar: f32 = 0,
    /// Row length, for the entries that treat the buffer as a 2-D field.
    cols: u32 = 0,
    /// The stabiliser inside layer normalisation's square root. Not a constant: frameworks pick
    /// different values and the choice is visible in f32, so the host passes it.
    epsilon: f32 = 0,
    /// Bounds for `clamp`. Named fields rather than reusing `scalar`: a uniform word doing two
    /// jobs is how a kernel ends up clamping to the learning rate.
    lo: f32 = 0,
    hi: f32 = 0,
    /// ★ Padding to 32 bytes. `compute_host` refuses a `Params` that is not a multiple of 16 —
    /// WGSL uniform blocks are std140-aligned, so a 24-byte struct silently mismatches the GPU
    /// and the kernel reads garbage. The guard caught this the moment `lo`/`hi` were added, with
    /// the size and the fix in the message. Exactly the kind of check worth having.
    /// Slope for `leaky_relu` and alpha for `elu`. One word, two kernels that never run in the
    /// same dispatch — but named for what it IS, not for one of its users.
    alpha: f32 = 0,
    /// Window size for the two poolings.
    pool: u32 = 0,
};

pub const g = k.Globals(@This());
const bx = g.bind(.x);
const bout = g.bind(.out);
const params = g.uniform();

pub fn relu(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.relu(bx[id]);
}

pub fn sigmoid(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.sigmoid(bx[id]);
}

pub fn tanhf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.tanh(bx[id]);
}

pub fn gelu(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.gelu(bx[id]);
}

/// One list, one loop. Adding an entry is a line here and a line in `build.zig`'s
/// `.entries` — which is the shape the kernel manifest will formalise.
pub fn expf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = exp(bx[id]);
}

/// `2^x`, which is not the same code path as `exp(x * ln 2)`.
///
/// A driver may lower this to a dedicated instruction with its own rounding. That is exactly
/// what a sweep row is for: pure addressing cannot drift between backends, a transcendental can.
pub fn exp2f(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = exp2(bx[id]);
}

/// `a * gain + offset`, the one affine that replaced znum's four scalar variants.
///
/// Worth a row because a backend may contract it into a fused multiply-add, which rounds ONCE
/// where the separate operations round twice. That is a real difference and a small one, which
/// is the kind a sweep exists to measure rather than argue about.
pub fn affine_f(id: u32) void {
    if (id >= params.count) {
        return;
    }
    // `epsilon` as the offset: this module's params have `scalar` and `epsilon` and no third
    // float. Reusing a field whose NAME says something else is what `slice_columns` did with
    // `cols` and it cost a red row on device - so the row's CPU side passes the same two
    // constants by name, and the doc says which is which rather than leaving them to match up.
    bout[id] = bx[id] * params.scalar + params.epsilon;
}

/// One thread counts the nonzero elements of the whole field.
///
/// A COUNTING REDUCTION HAS A ZERO BAR, WHICH IS UNUSUAL AND WORTH SAYING
///
/// Most reduction rows carry a ULP allowance because a sum accumulates differently depending on
/// the order. **A count does not accumulate** - it increments, and integer addition is exact in
/// any order. So the bar is zero, and a nonzero difference here is a real bug rather than
/// rounding.
/// `all`: one thread, early exit on the first zero.
///
/// ONE THREAD, LIKE `count_nonzero` BESIDE IT - AND THAT IS THE POINT OF THE ROW
///
/// A parallel reduction would need a tree and shared memory, and the tree is what makes a GPU
/// sum differ from a serial one. `all` and `any` are immune to that: they combine with `and` and
/// `or`, which are **associative AND idempotent**, so every order gives the same answer.
///
/// The row still earns its place. It proves the early exit does not skip an element the host
/// would have read - a kernel that returned on the first NONZERO instead would pass any test
/// that only checked an all-zero input.
pub fn all_nonzero(id: u32) void {
    if (id != 0) {
        return;
    }
    var i: u32 = 0;
    while (i < params.count) : (i += 1) {
        if (bx[i] == 0) {
            bout[0] = 0;
            return;
        }
    }
    bout[0] = 1;
}

/// `any`: the mirror, exiting on the first nonzero.
pub fn any_nonzero(id: u32) void {
    if (id != 0) {
        return;
    }
    var i: u32 = 0;
    while (i < params.count) : (i += 1) {
        if (bx[i] != 0) {
            bout[0] = 1;
            return;
        }
    }
    bout[0] = 0;
}

/// The product of every element.
///
/// A PRODUCT IS WHERE ORDER REALLY DOES MATTER
///
/// Multiplication is associative in real arithmetic and **not** in floating point: `(a*b)*c` and
/// `a*(b*c)` can differ in the last bits, and a product accumulates that over the whole buffer
/// where a sum only accumulates absolute error. It also overflows to infinity far sooner.
///
/// So this row has a real tolerance where `all` and `any` have zero, and the difference between
/// those two facts is what the sweep is for.
pub fn prod_all(id: u32) void {
    if (id != 0) {
        return;
    }
    var total: f32 = 1;
    var i: u32 = 0;
    while (i < params.count) : (i += 1) {
        total *= bx[i];
    }
    bout[0] = total;
}

pub fn count_nonzero(id: u32) void {
    if (id != 0) {
        return;
    }
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < params.count) : (i += 1) {
        if (bx[i] != 0) {
            total += 1;
        }
    }
    bout[0] = total;
}

/// Successive differences: `out[i] = x[i] - x[i-1]`, with the first slot zero.
///
/// Worth a row because a subtraction of two nearby values is where cancellation lives: the host
/// and the device must agree on it exactly, and they do - a subtraction is a single rounding on
/// both. The row exists to prove that rather than assume it.
pub fn diff_forward(id: u32) void {
    if (id >= params.count) {
        return;
    }
    // THE HOLE IS NaN AT FLOAT, NOT ZERO - AND THE HOST DECIDED THAT ON PURPOSE
    //
    // `diff` of n values has n-1 differences and one slot with no answer. The host writes NaN
    // there for a float type and 0 for an integer, because **an integer has no NaN and a zero
    // difference is a value someone might believe** - that asymmetry is documented on
    // `stepOverLastAxis` and it is the reason the integer widening treated `diff` carefully.
    //
    // This kernel wrote 0.0, so the sweep compared 0 against NaN and reported `inf` against a
    // bar of zero. It was the one red row in an otherwise green 105.
    //
    // The field is f32, so NaN is the value that matches.
    // Element 0 has no predecessor, so the first difference is undefined rather than zero -
    // NaN says that, where 0 would silently read as 'no change'.
    // ---- THE HOLE IS PER ROW, NOT ONE PER BUFFER ----
    //
    // `zn.diff` steps over the LAST AXIS, so on a rank-2 tensor every row's column 0 has no
    // predecessor and every row gets a NaN. This kernel used to test `id == 0` - one hole in the
    // whole buffer - which on the sweep's 64x64 field meant 63 rows disagreed with the CPU in
    // two ways at once: a finite value where NaN belonged, AND a difference taken across the row
    // boundary against the previous row's last element.
    //
    // It survived because the kernel could not compile for a device until today, so the row had
    // never actually run. The first device run reported `inf` - a finiteness mismatch - and the
    // driver was blamed before the arithmetic was.
    const col: u32 = if (params.cols == 0) id else id % params.cols;
    bout[id] = if (col == 0) nan(f32) else bx[id] - bx[id - 1];
}

pub fn absf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = abs(bx[id]);
}

pub fn neg(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = -bx[id];
}

/// `out = a * s`. Matches `zn.scale`. The first unary entry to read a runtime scalar.
pub fn scale(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = bx[id] * params.scalar;
}

/// Softmax along each row: `out[r][c] = e^(x[r][c] - max_r) / sum_r`.
///
/// ── ★★★ ONE THREAD PER ROW, AND THAT IS A KNOWN LIMITATION ──
///
/// Each thread walks its whole row three times — max, exponentiate-and-sum, divide. With 64 rows
/// that is 64 threads, which leaves a modern GPU almost entirely idle. The tiled alternative is
/// one WORKGROUP per row with a shared-memory tree reduction, and it is the obvious next step.
///
/// This ships first for the reason `matmul` shipped before `matmul_tiled`: it is the simple,
/// checkable reference, and once a faster one exists the two can be compared ON THE SAME DEVICE
/// rather than only against the CPU.
///
/// ★★ THE ROW MAXIMUM IS SUBTRACTED HERE TOO, and it has to be: `exp` overflows f32 above ~88 and
/// the CPU implementation subtracts. Skipping it would not merely be less accurate — the two
/// sides would disagree by an infinity the moment a logit got large.
/// `logSumExp` of each row, one value per row.
///
/// THE SAME MAX-SUBTRACTION AS `softmax_rows`, AND FOR THE SAME REASON
///
/// A shader has no more headroom than a host: `exp(800)` is infinity in f32 long before f64 gives
/// up, so the largest element comes out first here exactly as it does above. `softmax_rows` needs
/// it to keep the ratio finite; this needs it to keep the SUM finite. One trick, two functions,
/// and if either drops it the failure is `inf` rather than a wrong digit.
///
/// One thread per row, and the output is one value per row - so `bout` beyond `rows` is left
/// alone and the host reads only the prefix.
pub fn log_sum_exp_rows(id: u32) void {
    const rows: u32 = params.count / params.cols;
    if (id >= rows) {
        return;
    }
    const base: u32 = id * params.cols;

    var largest: f32 = bx[base];
    var i: u32 = 1;
    while (i < params.cols) : (i += 1) {
        largest = @max(largest, bx[base + i]);
    }

    var total: f32 = 0;
    i = 0;
    while (i < params.cols) : (i += 1) {
        total += @exp(bx[base + i] - largest);
    }
    bout[id] = largest + @log(total);
}

pub fn softmax_rows(id: u32) void {
    const rows: u32 = params.count / params.cols;
    if (id >= rows) {
        return;
    }
    const base: u32 = id * params.cols;

    var largest: f32 = bx[base];
    var i: u32 = 1;
    while (i < params.cols) : (i += 1) {
        largest = @max(largest, bx[base + i]);
    }

    var total: f32 = 0;
    i = 0;
    while (i < params.cols) : (i += 1) {
        const e: f32 = @exp(bx[base + i] - largest);
        bout[base + i] = e;
        total += e;
    }

    i = 0;
    while (i < params.cols) : (i += 1) {
        bout[base + i] = bout[base + i] / total;
    }
}

/// Normalise each row to zero mean and unit variance. Matches `zn.layerNormRows`.
///
/// ★ Three passes over the row — mean, variance, write — exactly as the CPU does. A single-pass
/// form using E[x²] − E[x]² exists and is NOT used: it subtracts two large nearly-equal numbers
/// and loses most of its significant digits when the mean is large relative to the spread, which
/// is the normal case for an unnormalised activation. The two sides must also agree, and the CPU
/// version is the two-pass one.
pub fn layernorm_rows(id: u32) void {
    const rows: u32 = params.count / params.cols;
    if (id >= rows) {
        return;
    }
    const base: u32 = id * params.cols;
    const width: f32 = @floatFromInt(params.cols);

    var total: f32 = 0;
    var i: u32 = 0;
    while (i < params.cols) : (i += 1) {
        total += bx[base + i];
    }
    const mean: f32 = total / width;

    var sq: f32 = 0;
    i = 0;
    while (i < params.cols) : (i += 1) {
        const d: f32 = bx[base + i] - mean;
        sq += d * d;
    }
    const inv: f32 = 1.0 / @sqrt(sq / width + params.epsilon);

    i = 0;
    while (i < params.cols) : (i += 1) {
        bout[base + i] = (bx[base + i] - mean) * inv;
    }
}

/// `out[c] = sum over rows of x[r][c]` — one output per COLUMN. The bias gradient of a dense
/// layer, which sums the incoming gradient down the batch.
///
/// ★ One thread per column, each walking its column with a stride of `cols`. That stride is a
/// cache miss per step, which is the price of the column-major access an axis-0 reduction needs;
/// the tiled form transposes into shared memory first and is the follow-up.
pub fn sum_axis0(id: u32) void {
    if (id >= params.cols) {
        return;
    }
    const rows: u32 = params.count / params.cols;
    var total: f32 = 0;
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        total += bx[r * params.cols + id];
    }
    bout[id] = total;
}

/// `out[0] = sum of every element` — a scalar.
///
/// ★★ ONE THREAD FOR THE WHOLE BUFFER, and that is as slow as it sounds. It exists as the
/// CHECKABLE REFERENCE for the tree reduction that replaces it: a workgroup-shared log-depth sum
/// has a barrier at every level and no CPU oracle can see a barrier mistake, so it needs a
/// same-device comparison — and this is what it will be compared against.
pub fn sum_all(id: u32) void {
    if (id >= 1) {
        return;
    }
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < params.count) : (i += 1) {
        total += bx[i];
    }
    bout[0] = total;
}

/// One workgroup's worth of lanes, and the width of the reduction tree below.
const lanes: u32 = config.workgroup;

const partial = k.shared(f32, lanes, "red_partial");

/// `out[0] = sum of every element`, by a workgroup-shared tree — the FAST scalar reduction.
///
/// ⚠ **THIS KERNEL HAS NO VALID CPU TWIN, AND THAT IS STRUCTURAL.** `compute_host`'s CPU path
/// runs `for id in 0..n: kernel(id)` — each lane executes the WHOLE kernel before the next lane
/// starts. A barrier is a no-op there, so lane 0 completes all six tree levels before lane 1 has
/// written its partial. The result is wrong, and no amount of care in the kernel fixes it.
///
/// The sweep row is still valid, because it compares the GPU against `zn.sumAll` rather than
/// against this kernel's host execution. But nothing on a host can verify the BARRIERS, which is
/// the sharpest form of the limitation recorded in §10.3: a CPU oracle checks arithmetic, never
/// synchronisation.
///
/// ── ★★★ SIX BARRIER LEVELS, AND NOT ONE MAY SIT IN A BRANCH ──
///
/// Each lane strides the buffer accumulating its own partial, then the 64 partials collapse in
/// log2(64) = 6 levels. The textbook level is `if (lid < stride) p[lid] += p[lid + stride];`
/// followed by a barrier — and that `if` is derived from the thread id, which is exactly what put
/// the tiled matmul's barrier five blocks deep and got the module rejected with
/// "'workgroupBarrier' must only be called from uniform control flow".
///
/// ★★ SO THE LEVEL IS ARITHMETIC. Every lane reads, every lane writes, and inactive lanes add a
/// term multiplied by ZERO. `(lid + stride) % lanes` keeps the index in range without a guard.
/// The result is identical and there is no branch for the structurizer to wrap a barrier in.
///
/// ★ TWO barriers per level, not one: all lanes must finish READING a level's values before any
/// lane WRITES them, or a fast lane overwrites a slow lane's source. One barrier would be a race
/// that gives a wrong total on some devices and not others — the worst kind.
pub fn sum_all_tiled(id: u32) void {
    const lid: u32 = id % lanes;

    // ★★★ THE TRIP COUNT IS COMPUTED FROM UNIFORM VALUES, NOT FROM THE LANE.
    //
    // `while (i < count) : (i += lanes)` starting at `i = lid` runs the same number of times in
    // every lane HERE — but Tint cannot know that, because the start is per-lane. The barrier
    // that follows the loop then sits after control flow the analysis calls non-uniform, and the
    // module is rejected. Deriving the bound from `count` and `lanes` makes it provably uniform,
    // and the range guard becomes a multiply by 0-or-1 instead of a branch.
    const per_lane: u32 = (params.count + lanes - 1) / lanes;
    var acc: f32 = 0;
    var step: u32 = 0;
    while (step < per_lane) : (step += 1) {
        const idx: u32 = step * lanes + lid;
        const in_range: u32 = @intFromBool(idx < params.count);
        // Clamped rather than guarded: an out-of-range lane reads element 0 and multiplies it
        // by zero. Strided so consecutive lanes touch consecutive addresses — a coalesced walk.
        acc += bx[idx * in_range] * float(in_range);
    }
    partial[lid] = acc;
    k.workgroupBarrier();

    var stride: u32 = lanes / 2;
    while (stride > 0) : (stride /= 2) {
        const src: u32 = (lid + stride) % lanes;
        const active: f32 = @floatFromInt(@intFromBool(lid < stride));
        const merged: f32 = partial[lid] + partial[src] * active;
        k.workgroupBarrier();
        partial[lid] = merged;
        k.workgroupBarrier();
    }

    // Lane 0 holds the total. The write is the only guarded step, and it strands nobody.
    if (lid == 0) {
        bout[0] = partial[0];
    }
}

/// `out[0] = mean of every element`. Matches `zn.meanAll`.
///
/// ★ The division is by a value from the uniform, not a constant: `count` is what the host
/// dispatched with, so a shorter buffer divides by its own length rather than by whatever the
/// kernel happened to be written against.
pub fn mean_all(id: u32) void {
    if (id >= 1) {
        return;
    }
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < params.count) : (i += 1) {
        total += bx[i];
    }
    bout[0] = total / float(params.count);
}

/// `out[0] = largest element`. Matches `zn.maxAll`.
///
/// ★★ SEEDED FROM ELEMENT 0, NOT FROM NEGATIVE INFINITY. Seeding with `-inf` would return `-inf`
/// for an empty buffer, which READS AS AN ANSWER. Seeding from the first element means the empty
/// case cannot be answered wrongly here — and `zn.maxAll` returns `DomainError` for it, which a
/// kernel has no way to express at all. The asymmetry is worth knowing: a kernel cannot report a
/// domain error, so the host must not dispatch one.
pub fn max_all(id: u32) void {
    if (id >= 1) {
        return;
    }
    var best: f32 = bx[0];
    var i: u32 = 1;
    while (i < params.count) : (i += 1) {
        best = @max(best, bx[i]);
    }
    bout[0] = best;
}

/// NaN below zero — the same undefined result the CPU gives, which the sweep's `compare` now
/// treats as agreement rather than as a mismatch.
pub fn sqrtf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = @sqrt(bx[id]);
}

pub fn logf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = @log(bx[id]);
}

pub fn floorf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = floor(bx[id]);
}

pub fn ceilf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = ceil(bx[id]);
}

/// Zero maps to zero. Written as two comparisons rather than `sign(x)` so the convention is
/// visible and matches `zn.signf` exactly.
pub fn signf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const x: f32 = bx[id];
    var r: f32 = 0;
    if (x > 0) {
        r = 1;
    }
    if (x < 0) {
        r = -1;
    }
    bout[id] = r;
}

pub fn square(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.square(bx[id]);
}

pub fn reciprocal(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = 1.0 / bx[id];
}

pub fn truncf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = trunc(bx[id]);
}

pub fn roundf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = round(bx[id]);
}

pub fn sinf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = sinRad(bx[id]);
}

pub fn cosf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = cosRad(bx[id]);
}

pub fn clampf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    // `@min(@max(v, lo), hi)` IS `clamp`'s definition exactly - lower bound first, then
    // upper - so unlike the scroll and impulse clamps elsewhere this substitution needs no
    // argument about lo <= hi.
    bout[id] = clamp(bx[id], params.lo, params.hi);
}

/// Guarded above 20 at the SAME threshold as `zn.softplus`: `@exp(30)` is finite in f32 but
/// `@exp(90)` is not, and a guard on one side only means the two disagree by an infinity.
pub fn softplus(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const x: f32 = bx[id];
    bout[id] = if (x > 20.0) x else @log(1.0 + @exp(x));
}

pub fn silu(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = bx[id] * zm.sigmoid(bx[id]);
}

pub fn leaky_relu(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const x: f32 = bx[id];
    bout[id] = if (x > 0) x else params.alpha * x;
}

pub fn elu(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const x: f32 = bx[id];
    bout[id] = if (x > 0) x else params.alpha * (@exp(x) - 1.0);
}

/// `out[0] = smallest element`. Seeded from element 0, like `max_all`.
pub fn min_all(id: u32) void {
    if (id >= 1) {
        return;
    }
    var best: f32 = bx[0];
    var i: u32 = 1;
    while (i < params.count) : (i += 1) {
        best = @min(best, bx[i]);
    }
    bout[0] = best;
}

/// `out[c] = max over rows of x[r][c]`. One thread per column, seeded from row 0.
pub fn max_axis0(id: u32) void {
    if (id >= params.cols) {
        return;
    }
    const rows: u32 = params.count / params.cols;
    var best: f32 = bx[id];
    var r: u32 = 1;
    while (r < rows) : (r += 1) {
        best = @max(best, bx[r * params.cols + id]);
    }
    bout[id] = best;
}

pub fn min_axis0(id: u32) void {
    if (id >= params.cols) {
        return;
    }
    const rows: u32 = params.count / params.cols;
    var best: f32 = bx[id];
    var r: u32 = 1;
    while (r < rows) : (r += 1) {
        best = @min(best, bx[r * params.cols + id]);
    }
    bout[id] = best;
}

pub fn mean_axis0(id: u32) void {
    if (id >= params.cols) {
        return;
    }
    const rows: u32 = params.count / params.cols;
    var total: f32 = 0;
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        total += bx[r * params.cols + id];
    }
    bout[id] = total / float(rows);
}

/// `out[c] = row index of the largest x[r][c]`, written as a float. Ties to the first, NaN
/// never wins — the comparison is `>`, matching `zn.argmaxRows`.
pub fn argmax_axis0(id: u32) void {
    if (id >= params.cols) {
        return;
    }
    const rows: u32 = params.count / params.cols;
    var best: f32 = bx[id];
    var best_at: u32 = 0;
    var r: u32 = 1;
    while (r < rows) : (r += 1) {
        const x: f32 = bx[r * params.cols + id];
        if (x > best) {
            best = x;
            best_at = r;
        }
    }
    bout[id] = @floatFromInt(best_at);
}

/// Running sum along each row. One thread per row, sequential — a scan has a parallel form
/// with log-depth barriers, and this is the reference it will be compared against.
pub fn cumsum_rows(id: u32) void {
    const rows: u32 = params.count / params.cols;
    if (id >= rows) {
        return;
    }
    const base: u32 = id * params.cols;
    var running: f32 = 0;
    var i: u32 = 0;
    while (i < params.cols) : (i += 1) {
        running += bx[base + i];
        bout[base + i] = running;
    }
}

/// `out[c] = population variance down column c`. Two passes, as `zn.varianceAxis` does. One
/// thread per column.
pub fn variance_axis0(id: u32) void {
    if (id >= params.cols) {
        return;
    }
    const rows: u32 = params.count / params.cols;
    const width: f32 = @floatFromInt(rows);
    var total: f32 = 0;
    var r: u32 = 0;
    while (r < rows) : (r += 1) {
        total += bx[r * params.cols + id];
    }
    const mean: f32 = total / width;
    var sq: f32 = 0;
    r = 0;
    while (r < rows) : (r += 1) {
        const d: f32 = bx[r * params.cols + id] - mean;
        sq += d * d;
    }
    bout[id] = sq / width;
}

/// Max pooling of a `cols × cols` image over non-overlapping `pool × pool` windows. One thread
/// per output pixel; the output is `(cols / pool)²` wide.
pub fn max_pool2d(id: u32) void {
    const ow: u32 = params.cols / params.pool;
    if (id >= ow * ow) {
        return;
    }
    const oy: u32 = id / ow;
    const ox: u32 = id % ow;
    var best: f32 = bx[(oy * params.pool) * params.cols + ox * params.pool];
    var i: u32 = 0;
    while (i < params.pool) : (i += 1) {
        var j: u32 = 0;
        while (j < params.pool) : (j += 1) {
            best = @max(best, bx[(oy * params.pool + i) * params.cols + ox * params.pool + j]);
        }
    }
    bout[id] = best;
}

pub fn avg_pool2d(id: u32) void {
    const ow: u32 = params.cols / params.pool;
    if (id >= ow * ow) {
        return;
    }
    const oy: u32 = id / ow;
    const ox: u32 = id % ow;
    var total: f32 = 0;
    var i: u32 = 0;
    while (i < params.pool) : (i += 1) {
        var j: u32 = 0;
        while (j < params.pool) : (j += 1) {
            total += bx[(oy * params.pool + i) * params.cols + ox * params.pool + j];
        }
    }
    bout[id] = total / float(params.pool * params.pool);
}

/// `log(x) / log(2)`: the SPIR-V backend has no `log2` or `log10` intrinsic, so both are the
/// natural log times a constant. `zn.log2f` uses `zm.log2` on the host, which is a separate
/// implementation; the row's 2-ULP bar is for that difference.
pub fn log2f(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = @log(bx[id]) * (1.0 / @log(2.0));
}

pub fn log10f(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = @log(bx[id]) * (1.0 / @log(10.0));
}

pub fn expm1(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.expm1(bx[id]);
}

pub fn log1p(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.log1p(bx[id]);
}

/// The same `sign(x)·exp(log|x|/3)` as `zn.cbrtf`, so the two agree on negatives.
pub fn cbrtf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    const x: f32 = bx[id];
    const root: f32 = @exp(@log(@abs(x)) / 3.0);
    bout[id] = if (x == 0) 0 else if (x < 0) -root else root;
}

pub fn sinhf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.sinh(bx[id]);
}

pub fn coshf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.cosh(bx[id]);
}

pub fn asinhf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.asinh(bx[id]);
}

pub fn atanhf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.atanh(bx[id]);
}

pub fn rsqrtf(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.rsqrt(bx[id]);
}

/// ── ★★ THESE CALL `zm` DIRECTLY, WHICH IS THE POINT ──
///
/// Every other kernel here writes its arithmetic out. These four go through `zm.sign`,
/// `zm.expm1`, `zm.log1p` and `zm.relu` — the functions zimrmath gained this pass — so the sweep
/// proves the new zimrmath code **lowers to SPIR-V and agrees with its own CPU path**, which is
/// the whole claim the library makes.
pub fn signz(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.sign(bx[id]);
}

pub fn expm1z(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.expm1(bx[id]);
}

pub fn log1pz(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.log1p(bx[id]);
}

pub fn reluz(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = zm.relu(bx[id]);
}

pub fn sin_turns(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = sinTurns(bx[id]);
}

pub fn cos_turns(id: u32) void {
    if (id >= params.count) {
        return;
    }
    bout[id] = cosTurns(bx[id]);
}

// ★ ONE ENTRY PER LINE, deliberately. `zig fmt` column-aligns a list whose items share
// a line, and that realignment silently broke an append anchor three times during the
// port. A vertical list is stable under formatting, so adding a kernel is a one-line
// diff that no tooling will reflow.
/// A NaN written straight to the output, with no branch and no arithmetic after it.
///
/// ---- WHY THIS KERNEL EXISTS: TO SPLIT ONE QUESTION INTO TWO ----
///
/// The `diff` row returns a FINITE value on device where the CPU returns NaN. The transpiled
/// WGSL was read end to end and is correct at every step: the branch selects the NaN path, and
/// the helper routes the bit pattern through a runtime `var` so the constant evaluator cannot
/// fold it. So the value is lost somewhere at or below the driver - but "somewhere" spans a
/// function call chain, a phi, a branch and a buffer store.
///
/// This kernel removes all of them. If it ALSO returns finite, the bitcast itself does not
/// survive on this hardware and the answer is a driver assumption about NaN. If it returns NaN,
/// then the bitcast is fine and something between it and `diff`'s store destroys the value -
/// and the next bisection step is the function chain.
///
/// One bit of information, and it is the bit that decides which half to look in.
pub fn nan_direct(id: u32) void {
    if (id >= params.count) {
        return;
    }
    // NO BRANCH. The first attempt wrote `if (x == x) nan else nan` to keep the input live,
    // and the transpiler faithfully emitted the branch and the phi - which are two of the three
    // things this kernel exists to eliminate. One call, one store, nothing else.
    //
    // The value being a constant is not a problem here: `nan(f32)` still reaches the device
    // through `nonfinite_<bits>()`, which holds the pattern in a runtime `var` precisely so it
    // cannot be folded. If the driver folds it anyway, that IS the finding.
    bout[id] = nan(f32);
}

pub const kernels = [_][:0]const u8{
    "nan_direct",
    "relu",
    "sigmoid",
    "tanhf",
    "gelu",
    "expf",
    "absf",
    "neg",
    "scale",
    "softmax_rows",
    "layernorm_rows",
    "sum_axis0",
    "sum_all",
    "sum_all_tiled",
    "mean_all",
    "max_all",
    "sqrtf",
    "logf",
    "floorf",
    "ceilf",
    "signf",
    "square",
    "reciprocal",
    "truncf",
    "roundf",
    "sinf",
    "cosf",
    "clampf",
    "softplus",
    "silu",
    "leaky_relu",
    "elu",
    "min_all",
    "max_axis0",
    "min_axis0",
    "mean_axis0",
    "argmax_axis0",
    "cumsum_rows",
    "variance_axis0",
    "max_pool2d",
    "avg_pool2d",
    "log2f",
    "log10f",
    "expm1",
    "log1p",
    "cbrtf",
    "sinhf",
    "coshf",
    "asinhf",
    "atanhf",
    "rsqrtf",
    "signz",
    "expm1z",
    "log1pz",
    "reluz",
    "sin_turns",
    "cos_turns",
    "log_sum_exp_rows",
    "exp2f",
    "affine_f",
    "count_nonzero",
    "diff_forward",
    "all_nonzero",
    "any_nonzero",
    "prod_all",
};

comptime {
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}
