//! tile_gather.zig - workgroup shared-memory NEIGHBOUR-TILING de-risk (Stage 2a).
//!
//! Proves the mechanism the fluid's density/force passes will use: ONE WORKGROUP
//! PER CELL cooperatively loads its 3x3 cell neighbourhood into a workgroup-
//! shared tile, barriers ONCE, then each thread processes one center-cell
//! particle reading neighbours from the fast tile instead of from global memory.
//!
//! The verifiable quantity is an INTEGER neighbour count (particles within h,
//! excluding self) per particle - exact pass/fail, no float epsilon. Because the
//! cell size equals h, every neighbour within h lies in the 3x3 block, so the
//! grid count equals a brute-force O(N^2) count (the host's ground truth).
//!
//! GPU path: workgroupId()=cell, localId()=slot; cooperative load -> barrier ->
//! gather from tile. The barrier is UNIFORM: the dispatch is exactly grid_cells
//! workgroups (no out-of-range workgroup), the load loop guards per-lane WORK
//! (`while (s < cnt)`) not the barrier, so every lane reaches it (spv2wgsl's
//! checkBarrierUniformity enforces this at build time). CPU path: the identical
//! gather straight from global memory - the oracle (no tile, no barrier).
const k = @import("kompute");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

pub const num_particles: u32 = 1024;
pub const domain: f32 = 512.0;
pub const h_radius: f32 = 64.0;
pub const max_per_cell: u32 = 64;
// +2 boundary pad (same convention as the fluid grid).
pub const n_cols: u32 = @trunc(@ceil(domain / h_radius) + 2);
pub const n_rows: u32 = n_cols;
pub const grid_cells: u32 = n_cols * n_rows;

// `.max` = the LARGEST dispatch across all kernels (gatherTiled runs
// grid_cells*wg_size threads), NOT num_particles - the run() cap assert uses it
// as a single bound for every kernel, so it must cover the biggest one.
pub const config = k.Config{ .max = grid_cells * 64, .workgroup = 64 };
pub const wg_size: u32 = config.workgroup;
/// Worst-case tile capacity: 9 cells, each up to max_per_cell.
pub const tile_cap: u32 = 9 * max_per_cell;

pub const Buffers = extern struct {
    pos: [num_particles][2]f32 align(8), // [2]f32 + align(8): extern-safe, bind() reinterprets as @Vector(2,f32)
    grid_counts: [grid_cells]u32,
    grid_data: [grid_cells * max_per_cell]u32,
    out_count: [num_particles]u32,
    /// Diagnostic: dbg[wgid*wg_size + lid] = wgid, written UNCONDITIONALLY by
    /// every thread (before any guard). The host checks dbg[t] == t/wg_size to
    /// verify workgroupId() is delivered correctly - the one primitive Stage 1
    /// never tested.
    dbg: [grid_cells * wg_size]u32,
};

pub const Params = extern struct {
    count: u32,
    h: f32,
    cols: u32,
    rows: u32,
};

pub const g = k.Globals(@This());
const b_pos = g.bind(.pos);
const b_grid_counts = g.bind(.grid_counts);
const b_grid_data = g.bind(.grid_data);
const b_out_count = g.bind(.out_count);
const b_dbg = g.bind(.dbg);

// Workgroup-shared tile (module level, like g.bind). Positions split into two
// scalar f32 arrays + a u32 index array (for self-skip).
const tile_px = k.shared(f32, tile_cap, "tg_px");
const tile_py = k.shared(f32, tile_cap, "tg_py");
const tile_idx = k.shared(u32, tile_cap, "tg_idx");

/// The 9 cell offsets of the 3x3 neighbourhood, unrolled at comptime so the
/// cooperative load is straight-line (NO runtime loop before the barrier).
const neighbour_offsets = [9][2]i32{
    .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
    .{ -1, 0 },  .{ 0, 0 },  .{ 1, 0 },
    .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
};

/// Per CELL: zero this cell's count (tileClearGrid before tileBuildGrid).
pub fn tileClearGrid(c: k.Ctx(@This())) void {
    const cell: u32 = c.id;
    if (cell >= c.params.cols * c.params.rows) {
        return;
    }
    k.atomicStore(b_grid_counts, cell, 0);
}

/// Per PARTICLE: atomic slot-claim into its cell (the O(N) parallel build).
pub fn tileBuildGrid(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const pos: Vec2 = b_pos[i];
    const max_cx: f32 = float(c.params.cols - 1);
    const max_cy: f32 = float(c.params.rows - 1);
    const cx: u32 = @trunc(clamp(@floor(pos[0] / c.params.h), 0.0, max_cx));
    const cy: u32 = @trunc(clamp(@floor(pos[1] / c.params.h), 0.0, max_cy));
    const cell: u32 = cx + cy * c.params.cols;
    const slot: u32 = k.atomicAdd(b_grid_counts, cell, 1);
    if (slot < max_per_cell) {
        b_grid_data[cell * max_per_cell + slot] = i;
    }
}

/// Count this cell's neighbour pairs via the shared tile (GPU) or straight from
/// global memory (CPU oracle). Dispatch is PER-CELL: count = grid_cells*wg_size.
/// Cooperatively load the 3x3 neighbourhood of `cell` into the shared tile and
/// return tile_len. `noinline` so spv2wgsl keeps it a SEPARATE WGSL function -
/// its `if (in_bounds)` branches then stay inside this function and do NOT
/// enclose the barrier that `gatherTiled` issues after the call (a barrier must
/// not sit inside cell-dependent control flow, which Tint treats as non-uniform
/// because `cell` derives from global_invocation_id). Straight-line load: the
/// 9-cell walk is unrolled and each lane loads exactly slot `lid` of each cell.
noinline fn loadNeighbourTile(cell: u32, lid: u32, cols: u32, rows: u32) u32 {
    const cx: i32 = @intCast(cell % cols);
    const cy: i32 = @intCast(cell / cols);
    var off: u32 = 0;
    inline for (neighbour_offsets) |d| {
        const nx: i32 = cx + d[0];
        const ny: i32 = cy + d[1];
        const in_bounds: bool = nx >= 0 and ny >= 0 and
            nx < @as(i32, @intCast(cols)) and ny < @as(i32, @intCast(rows));
        if (in_bounds) {
            const ncell: u32 = @as(u32, @intCast(nx)) + @as(u32, @intCast(ny)) * cols;
            const raw: u32 = k.atomicLoad(b_grid_counts, ncell);
            const cnt: u32 = if (raw < max_per_cell) raw else max_per_cell;
            if (lid < cnt) {
                const dst: u32 = off + lid;
                if (dst < tile_cap) {
                    const idx: u32 = b_grid_data[ncell * max_per_cell + lid];
                    tile_idx[dst] = idx;
                    tile_px[dst] = b_pos[idx][0];
                    tile_py[dst] = b_pos[idx][1];
                }
            }
            off += cnt;
        }
    }
    return if (off < tile_cap) off else tile_cap;
}

pub fn gatherTiled(c: k.Ctx(@This())) void {
    const gid: u32 = c.id;
    if (k.is_gpu) {
        const cell: u32 = gid / wg_size;
        const lid: u32 = gid % wg_size;
        b_dbg[gid] = gid + 1;
        // Load (in a separate fn) -> barrier at TOP LEVEL -> process.
        const tile_len: u32 = loadNeighbourTile(cell, lid, c.params.cols, c.params.rows);
        k.workgroupBarrier();
        const center_raw: u32 = k.atomicLoad(b_grid_counts, cell);
        const center_cnt: u32 = if (center_raw < max_per_cell) center_raw else max_per_cell;
        if (lid < center_cnt) {
            const i: u32 = b_grid_data[cell * max_per_cell + lid];
            const mx: f32 = b_pos[i][0];
            const my: f32 = b_pos[i][1];
            var nbrs: u32 = 0;
            var t: u32 = 0;
            while (t < tile_len) : (t += 1) {
                const j: u32 = tile_idx[t];
                if (j != i) {
                    const sx: f32 = tile_px[t] - mx;
                    const sy: f32 = tile_py[t] - my;
                    if (sx * sx + sy * sy < c.params.h * c.params.h) {
                        nbrs += 1;
                    }
                }
            }
            b_out_count[i] = nbrs;
        }
    } else {
        // CPU oracle: per-cell mapping, direct global gather (no tile/barrier).
        const cell: u32 = c.id / wg_size;
        const lid: u32 = c.id % wg_size;
        if (c.id < grid_cells * wg_size) {
            b_dbg[c.id] = c.id + 1;
        }
        if (cell >= c.params.cols * c.params.rows) {
            return;
        }
        const center_raw: u32 = k.atomicLoad(b_grid_counts, cell);
        const center_cnt: u32 = if (center_raw < max_per_cell) center_raw else max_per_cell;
        if (lid >= center_cnt) {
            return;
        }
        const i: u32 = b_grid_data[cell * max_per_cell + lid];
        const mx: f32 = b_pos[i][0];
        const my: f32 = b_pos[i][1];
        const cx: i32 = @intCast(cell % c.params.cols);
        const cy: i32 = @intCast(cell / c.params.cols);
        var nbrs: u32 = 0;
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx: i32 = cx + dx;
                const ny: i32 = cy + dy;
                const in_bounds: bool = nx >= 0 and ny >= 0 and
                    nx < @as(i32, @intCast(c.params.cols)) and ny < @as(i32, @intCast(c.params.rows));
                if (in_bounds) {
                    const ncell: u32 = @as(u32, @intCast(nx)) + @as(u32, @intCast(ny)) * c.params.cols;
                    const raw: u32 = k.atomicLoad(b_grid_counts, ncell);
                    const cnt: u32 = if (raw < max_per_cell) raw else max_per_cell;
                    var s: u32 = 0;
                    while (s < cnt) : (s += 1) {
                        const j: u32 = b_grid_data[ncell * max_per_cell + s];
                        if (j != i) {
                            const sx: f32 = b_pos[j][0] - mx;
                            const sy: f32 = b_pos[j][1] - my;
                            if (sx * sx + sy * sy < c.params.h * c.params.h) {
                                nbrs += 1;
                            }
                        }
                    }
                }
            }
        }
        b_out_count[i] = nbrs;
    }
}

comptime {
    k.installKernel(@This(), "tileClearGrid");
    k.installKernel(@This(), "tileBuildGrid");
    k.installKernel(@This(), "gatherTiled");
}

// ---- CPU oracle test: grid gather == brute-force O(N^2) count -------------

fn bruteCount(pos: []const [2]f32, i: usize, h: f32) u32 {
    var n: u32 = 0;
    for (pos, 0..) |p, j| {
        if (j == i) {
            continue;
        }
        const sx: f32 = p[0] - pos[i][0];
        const sy: f32 = p[1] - pos[i][1];
        if (sx * sx + sy * sy < h * h) {
            n += 1;
        }
    }
    return n;
}

test "tile_gather: per-cell gather matches brute-force O(N^2)" {
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x7f1e);
    const rnd: std.Random = prng.random();
    const N: u32 = num_particles;
    for (0..N) |i| {
        g.B.pos[i] = .{ rnd.float(f32) * domain, rnd.float(f32) * domain };
    }
    g.P = .{ .count = N, .h = h_radius, .cols = n_cols, .rows = n_rows };
    // Build the grid.
    var cell: u32 = 0;
    while (cell < grid_cells) : (cell += 1) {
        tileClearGrid(.{ .id = cell, .params = g.P });
    }
    var p: u32 = 0;
    while (p < N) : (p += 1) {
        tileBuildGrid(.{ .id = p, .params = g.P });
    }
    // No cell may overflow (else GPU/CPU drop different particles).
    for (0..grid_cells) |ci| {
        try expect(g.B.grid_counts[ci] <= max_per_cell);
    }
    // Run the (CPU) gather over the per-cell dispatch.
    var id: u32 = 0;
    while (id < grid_cells * wg_size) : (id += 1) {
        gatherTiled(.{ .id = id, .params = g.P });
    }
    // Every particle's grid count must equal its brute-force count.
    for (0..N) |i| {
        try expectEqual(bruteCount(g.B.pos[0..N], i, h_radius), g.B.out_count[i]);
    }
}
