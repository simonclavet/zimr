//! zn_matmul.zig — the matrix product on the GPU, naive and tiled, over the same ABI.
//!
//! ── ★★★ TWO ENTRIES ON PURPOSE ──
//!
//! `matmul` is one thread per output element reading straight from global memory. `matmul_tiled`
//! is the same arithmetic with a workgroup-shared tile, which is the first zimrnum kernel to use
//! shared memory and barriers at all. Keeping both means the tiled version has a same-device
//! reference and not only a CPU one: if they disagree, the barrier logic is wrong rather than the
//! maths.
//!
//! ★★ THE CONSTRAINTS THAT MAKE A BARRIER LEGAL, all of which shape the code below:
//!   * **Uniform control flow.** An `if` derived from a thread id around a barrier is rejected by
//!     Tint. So there is NO early return — every lane reaches every barrier, and only the final
//!     WRITE is guarded.
//!   * **Flat lanes viewed as a square.** The tile coordinates come from `id`, not from a 2-D
//!     builtin, so the CPU twin computes identical indices. `workgroupId` is unreliable on
//!     Adreno 7xx (kompute says so), so the decomposition is derived from the global id.
//!   * **Bitwise `&`, never `and`, AND no `if` in the masked load.** Short-circuit evaluation is
//!     a branch, and so is a select whose condition derives from the thread id. The mask is
//!     applied by MULTIPLICATION — index times 0-or-1, value times 0-or-1 — because the device
//!     rejected the `if` form outright: Tint reported "'workgroupBarrier' must only be called
//!     from uniform control flow", the barrier having landed five blocks deep inside the merge.
const k = @import("kompute");

/// 16x16 tiles: 256 threads, the workgroup size znum measured as portable.
pub const tile: u32 = 16;
pub const config = k.Config{ .max = 1 << 16, .workgroup = tile * tile };

pub const Buffers = extern struct {
    a: [config.max]f32,
    b: [config.max]f32,
    out: [config.max]f32,
};

/// `(m, kdim) @ (kdim, n) -> (m, n)`, padded to 16 bytes with scalars.
pub const Params = extern struct {
    m: u32,
    n: u32,
    kdim: u32,
    _p0: u32 = 0,
};
comptime {
    // A uniform must be 16-byte sized; a compile error here beats a validation failure at
    // pipeline creation, which reports a byte count and not a cause.
    if (@sizeOf(Params) % 16 != 0) {
        @compileError("zn_matmul.Params must be a multiple of 16 bytes");
    }
}

pub const g = k.Globals(@This());
const ba = g.bind(.a);
const bb = g.bind(.b);
const bout = g.bind(.out);

// ★★★ THE LEAN PATH, AND IT IS NOT ABOUT SIZE HERE. `installKernel` copies `Params` field by
// field out of the uniform buffer through a ladder of comptime-dead guards. Tint's uniformity
// analysis loses the provenance across that copy, so the loop condition below — `step < steps`,
// derived from `params.kdim` and identical in every lane — is no longer PROVABLY uniform, and the
// barrier inside the loop is rejected. Reading the uniform directly keeps the fact that these
// values came from a uniform buffer, which is what the analysis needs.
const params = g.uniform();

/// One thread per output element, straight from global memory. The reference the tiled version
/// is checked against on the same device.
pub fn matmul(id: u32) void {
    const total: u32 = params.m * params.n;
    if (id >= total) {
        return;
    }
    const row: u32 = id / params.n;
    const col: u32 = id % params.n;
    var sum: f32 = 0;
    var i: u32 = 0;
    while (i < params.kdim) : (i += 1) {
        sum += ba[row * params.kdim + i] * bb[i * params.n + col];
    }
    bout[row * params.n + col] = sum;
}

const shared_a = k.shared(f32, tile * tile, "tile_a");
const shared_b = k.shared(f32, tile * tile, "tile_b");

/// The same product, staging a 16x16 tile of each operand in workgroup memory.
///
/// ★ NO EARLY RETURN. A thread whose output cell is outside the matrix still walks every tile and
/// hits every barrier; it simply does not write at the end. Returning early would leave the
/// remaining lanes waiting at a barrier the departed ones never reach.
pub fn matmul_tiled(id: u32) void {
    const lanes: u32 = tile * tile;
    // Derived from the GLOBAL id, so the CPU twin computes the same indices and no unreliable
    // builtin is involved.
    const cell: u32 = id / lanes;
    const lid: u32 = id % lanes;
    const local_row: u32 = lid / tile;
    const local_col: u32 = lid % tile;
    const tiles_per_row: u32 = (params.n + tile - 1) / tile;
    const row: u32 = (cell / tiles_per_row) * tile + local_row;
    const col: u32 = (cell % tiles_per_row) * tile + local_col;

    var sum: f32 = 0;
    const steps: u32 = (params.kdim + tile - 1) / tile;
    var step: u32 = 0;
    while (step < steps) : (step += 1) {
        const a_col: u32 = step * tile + local_col;
        const b_row: u32 = step * tile + local_row;

        if (k.is_gpu) {
            // Branch-free masked loads: `&` not `and`, and the index is clamped rather than
            // guarded, so every lane executes the same instructions.
            const a_ok: u32 = @intFromBool(row < params.m) & @intFromBool(a_col < params.kdim);
            const b_ok: u32 = @intFromBool(b_row < params.kdim) & @intFromBool(col < params.n);
            // ★★★ ARITHMETIC, NOT SELECTION. `if (a_ok == 1) idx else 0` reads as branch-free and
            // is not: the condition derives from the thread id, so the barrier below lands in its
            // merge block and Tint rejects the module with "'workgroupBarrier' must only be
            // called from uniform control flow". Multiplying collapses an out-of-range index to
            // 0 — always a valid element — and zeroes its contribution, with no branch at all.
            const a_at: u32 = (row * params.kdim + a_col) * a_ok;
            const b_at: u32 = (b_row * params.n + col) * b_ok;
            // The two casts below decline `zm.float`: taking the rule's advice would mean giving this
            // kernel a `zm` dependency it does not otherwise have - it imports `kompute` and nothing
            // else. Two casts in a branch-free inner loop are not worth a module edge.
            // lint:off float-from-int: see above
            shared_a[lid] = ba[a_at] * @as(f32, @floatFromInt(a_ok));
            // lint:off float-from-int: see above
            shared_b[lid] = bb[b_at] * @as(f32, @floatFromInt(b_ok));
            k.workgroupBarrier();

            // `inline` so the second barrier is emitted where race detection can see it.
            comptime var i: u32 = 0;
            inline while (i < tile) : (i += 1) {
                sum += shared_a[local_row * tile + i] * shared_b[i * tile + local_col];
            }
            k.workgroupBarrier();
        } else {
            // CPU twin: the same arithmetic read straight from global memory. Shared memory is a
            // GPU-only cache of identical data and is never read here.
            var i: u32 = 0;
            while (i < tile) : (i += 1) {
                const ac: u32 = step * tile + i;
                const br: u32 = step * tile + i;
                const av: f32 = if ((row < params.m) and (ac < params.kdim))
                    ba[row * params.kdim + ac]
                else
                    0;
                const bv: f32 = if ((br < params.kdim) and (col < params.n))
                    bb[br * params.n + col]
                else
                    0;
                sum += av * bv;
            }
        }
    }

    // The ONLY guarded step: lanes outside the matrix computed a sum and discard it.
    if ((row < params.m) and (col < params.n)) {
        bout[row * params.n + col] = sum;
    }
}

/// The entries this file exports. See `zn_binary.kernels` for why there is one list.
/// `out = a @ bT` — the product with the SECOND operand transposed, `(m,k) @ (n,k)ᵀ -> (m,n)`.
///
/// ── ★★★ WHY THIS IS A KERNEL AND NOT A VIEW ──
///
/// On the CPU, `zn.matmul` handles a transposed operand for free: it reads through `at`, so
/// `b.transpose(0, 1)` is a stride swap and costs nothing. A kernel cannot do that — it takes a
/// dense buffer and indexes from its start — so the transpose has to live in the INDEX
/// ARITHMETIC instead. `bT[i][col]` is `b[col][i]`, which is the only line that differs.
///
/// ★★ Backpropagation needs exactly this shape twice: `dW = xᵀ @ dy` and `dx = dy @ Wᵀ`. Without
/// it, a training step would have to materialise a transposed copy of every operand each
/// iteration, which is a buffer and a pass over memory for something that is one index swap.
pub fn matmul_bt(id: u32) void {
    const total: u32 = params.m * params.n;
    if (id >= total) {
        return;
    }
    const row: u32 = id / params.n;
    const col: u32 = id % params.n;
    var sum: f32 = 0;
    var i: u32 = 0;
    while (i < params.kdim) : (i += 1) {
        sum += ba[row * params.kdim + i] * bb[col * params.kdim + i];
    }
    bout[row * params.n + col] = sum;
}

/// `out = aT` — `(m, n)` read as `(n, m)`. Uses this file's shapes: `m` rows in, `n` columns in.
///
/// ★ A materialising transpose, unlike the CPU's, where `Tensor.transpose` is a stride swap and
/// copies nothing. The GPU needs the dense result whenever the transposed operand feeds a kernel
/// that is not one of the `_bt` variants.
pub fn transpose(id: u32) void {
    const total: u32 = params.m * params.n;
    if (id >= total) {
        return;
    }
    const row: u32 = id / params.n;
    const col: u32 = id % params.n;
    bout[col * params.m + row] = ba[row * params.n + col];
}

// ★ One entry per line: see `zn_binary.kernels`.
pub const kernels = [_][:0]const u8{
    "matmul",
    "matmul_tiled",
    "matmul_bt",
    "transpose",
};

comptime {
    // The tiled entry MUST be lean — the param copy costs it uniformity provenance and the
    // barrier is then rejected. `matmul_bt` has no barrier, so either form works; it is lean too,
    // for one convention per file.
    for (kernels) |name| {
        k.installKernelLean(@This(), name);
    }
}
