//! fluid_kernels.zig - the GPU fluid: Clavet/Beaudoin/Poulin (2005)
//! double-density relaxation as a SEVEN-kernel kompute module. The same
//! algorithm as examples/sph_fluid_2d (the CPU port), now running where
//! it was born: 20k particles in compute shaders. Every kernel is the pure
//! kompute DSL - the SAME Zig compiles to a CPU loop and to SPIR-V->WGSL.
//!
//! THE GRID, WITHOUT ATOMICS. The original WebGPU sim builds its uniform
//! grid with `atomicAdd` slot-claiming; zimr's SPIR-V->WGSL path has no
//! atomics yet (queued as a transpiler arc). Instead `buildGrid` runs one
//! invocation PER CELL: each cell scans all N particles and sequentially
//! fills its own row - no two invocations ever touch the same memory, so no
//! races, and the kernel is bit-identical on CPU. cellsxN ~ 1.5kx20k = 30M
//! reads/build; two builds per substep, two substeps - well within budget.
//!
//! Per-substep order (mirrors the reference sim):
//!   gravityMouse -> buildGrid -> viscosity -> predict
//!   -> buildGrid -> density -> force -> applyAndFinalize
//!
//! Units are PIXELS of the fixed sim domain (domain_w x domain_h), exactly
//! the reference parameterisation. The renderer maps pixels -> NDC.
const k = @import("kompute");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const dot = zm.dot;
const length = zm.length;
const splat2 = zm.splat2;
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

pub const num_particles: u32 = 20000;
pub const domain_w: f32 = 900.0;
pub const domain_h: f32 = 600.0;
pub const interact_radius: f32 = 22.0;
pub const max_per_cell: u32 = 64;
// ceil(domain/h) + 2 boundary pad, matching the reference grid.
pub const grid_cols: u32 = @trunc(@ceil(domain_w / interact_radius) + 2);
pub const grid_rows: u32 = @trunc(@ceil(domain_h / interact_radius) + 2);
pub const grid_cells: u32 = grid_cols * grid_rows;

pub const config = k.Config{ .max = num_particles, .workgroup = 256 };

/// One storage buffer, the whole sim state. `pos` is FIRST: the renderer
/// reads positions at offset 0 by instance_index (the DrawPoints contract).
// Plain struct (not extern): Zig 1245 bans @Vector fields in extern structs on
// CPU targets. The GPU binds each field by name via @extern on the SPIR-V target
// (vectors legal there); the CPU twin (`g.B`) just needs the arrays for the
// reference kernels. Per-field binding means struct layout is never used for the
// GPU storage buffers, so dropping `extern` changes nothing on either side.
pub const Buffers = struct {
    pos: [num_particles]Vec2,
    prev: [num_particles]Vec2,
    vel: [num_particles]Vec2,
    delta: [num_particles]Vec2,
    /// (rho, rho_near) per particle - also read by the renderer for colour.
    density: [num_particles]Vec2,
    grid_counts: [grid_cells]u32,
    grid_data: [grid_cells * max_per_cell]u32,
    /// Pos-in-grid (Stage 2c optim): the particle position for each grid slot,
    /// written by buildGrid alongside grid_data. The neighbour search reads this
    /// (contiguous per cell) instead of b_pos[grid_data[..]] (a RANDOM indirection
    /// that kills warp coalescing). Same layout/stride as grid_data.
    grid_data_pos: [grid_cells * max_per_cell]Vec2,
};

/// Scalar-field uniform (array pads break uniform layout - see the
/// gpu-compute tutorial). 16 x 4B = 64B, a 16-multiple.
pub const Params = extern struct {
    count: u32,
    dt: f32,
    h: f32,
    r0: f32,
    k_far: f32,
    k_near: f32,
    gravity_y: f32,
    visc_beta: f32,
    mouse_x: f32,
    mouse_y: f32,
    /// Signed: >0 repels, <0 attracts, 0 idle.
    mouse_force: f32,
    mouse_radius: f32,
    dom_w: f32,
    dom_h: f32,
    n_cols: u32,
    n_rows: u32,
};

pub const g = k.Globals(@This());
// Per-field storage bindings (t1178): one binding per array - the
// megastruct single-binding corrupted on Adreno. `bind` returns a
// pointer-to-array; indexing reads/writes through it directly.
const b_pos = g.bind(.pos);
const b_prev = g.bind(.prev);
const b_vel = g.bind(.vel);
const b_delta = g.bind(.delta);
const b_density = g.bind(.density);
const b_grid_counts = g.bind(.grid_counts);
const b_grid_data = g.bind(.grid_data);
const b_grid_data_pos = g.bind(.grid_data_pos);

// ---- Tiled-density (Stage 2b) shared-memory scaffolding --------------------
// One workgroup per grid cell; the workgroup cooperatively loads its 3x3
// neighbourhood into a workgroup-shared tile ONCE, then every center particle
// reads neighbours from the tile instead of re-reading global memory ~N_cell
// times. `densityTiled` is an A/B alternative to `density` (toggle on host);
// the per-particle `density` stays the default and the oracle.
const fluid_wg_size: u32 = 256; // MUST equal config.workgroup
const tile_cap: u32 = 9 * max_per_cell; // 3x3 cells, each up to max_per_cell
const neighbour_offsets = [9][2]i32{
    .{ -1, -1 }, .{ 0, -1 }, .{ 1, -1 },
    .{ -1, 0 },  .{ 0, 0 },  .{ 1, 0 },
    .{ -1, 1 },  .{ 0, 1 },  .{ 1, 1 },
};
const dtile_idx = k.shared(u32, tile_cap, "dtile_idx");
const dtile_px = k.shared(f32, tile_cap, "dtile_px");
const dtile_py = k.shared(f32, tile_cap, "dtile_py");

/// Per CELL (dispatch count = grid_cells): zero this cell's particle count.
/// Must run BEFORE the per-particle buildGrid each substep (the atomic
/// slot-claim accumulates into grid_counts, so it needs a clean start).
pub fn clearGrid(c: k.Ctx(@This())) void {
    const cell: u32 = c.id;
    if (cell >= c.params.n_cols * c.params.n_rows) {
        return;
    }
    k.atomicStore(b_grid_counts, cell, 0);
}

/// Per PARTICLE (dispatch count = particle count): each particle claims a slot
/// in its cell via `atomicAdd` and writes its index there. O(N) - the parallel
/// grid build that replaces the O(cellsxN) single-writer scan. The cell is
/// computed the SAME way the neighbour passes look it up (floor(pos/h) clamped
/// to the grid), so a particle lands in the cell its neighbours will search.
/// Requires `clearGrid` to have zeroed grid_counts this substep.
pub fn buildGrid(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const pos: Vec2 = b_pos[i];
    const max_cx: f32 = float(c.params.n_cols - 1);
    const max_cy: f32 = float(c.params.n_rows - 1);
    const cx: u32 = @trunc(clamp(@floor(pos[0] / c.params.h), 0.0, max_cx));
    const cy: u32 = @trunc(clamp(@floor(pos[1] / c.params.h), 0.0, max_cy));
    const cell: u32 = cx + cy * c.params.n_cols;
    // Claim a slot: atomicAdd returns the count BEFORE the increment, which is
    // this particle's unique index in the cell. Overflow past max_per_cell is
    // dropped (the neighbour passes also clamp the read count to max_per_cell).
    const slot: u32 = k.atomicAdd(b_grid_counts, cell, 1);
    if (slot < max_per_cell) {
        b_grid_data[cell * max_per_cell + slot] = i;
        // Pos-in-grid: stash the binning position in the slot so the neighbour
        // passes can read it contiguously (no b_pos[j] random indirection).
        b_grid_data_pos[cell * max_per_cell + slot] = pos;
    }
}

/// Per particle: gravity + the (signed) mouse impulse with linear falloff.
pub fn gravityMouse(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    var v: Vec2 = b_vel[i];
    v[1] = v[1] + c.params.gravity_y * c.params.dt;
    const to_p: Vec2 = b_pos[i] - Vec2{ c.params.mouse_x, c.params.mouse_y };
    const d: f32 = length(to_p);
    if (d >= 0.5 and d < c.params.mouse_radius and c.params.mouse_force != 0.0) {
        const falloff: f32 = 1.0 - d / c.params.mouse_radius;
        v = v + to_p * splat2(c.params.mouse_force * falloff / d);
    }
    b_vel[i] = v;
}

/// Per particle: collision-style viscosity (t1178 redesign), gather form. Acts
/// ONLY on approaching pairs (closing speed u > 0); separating pairs get nothing.
/// The impulse is QUADRATIC in u, then CLAMPED so it can at most bring the pair's
/// radial relative motion to rest (u' = u - J >= 0) - never a bounce, strictly
/// dissipative, momentum-conserving (1/2 each). Distance weight is 1 inside h/2,
/// ramping linearly to 0 at h. Runs pre-predict on the STALE grid (last frame's
/// bins); the soft rim weight (->0 at h) absorbs the slight stale-grid drift.
pub fn viscosity(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const my_pos: Vec2 = b_pos[i];
    var my_vel: Vec2 = b_vel[i];
    const ccx: i32 = @floor(my_pos[0] / c.params.h);
    const ccy: i32 = @floor(my_pos[1] / c.params.h);
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const nx: i32 = ccx + dx;
            const ny: i32 = ccy + dy;
            if (nx < 0 or ny < 0) {
                continue;
            }
            const unx: u32 = @intCast(nx);
            const uny: u32 = @intCast(ny);
            if (unx >= c.params.n_cols or uny >= c.params.n_rows) {
                continue;
            }
            const cell: u32 = unx + uny * c.params.n_cols;
            const raw_count: u32 = k.atomicLoad(b_grid_counts, cell);
            const in_cell: u32 = if (raw_count < max_per_cell) raw_count else max_per_cell;
            var s: u32 = 0;
            while (s < in_cell) : (s += 1) {
                const j: u32 = b_grid_data[cell * max_per_cell + s];
                if (j == i) {
                    continue;
                }
                const sep: Vec2 = b_pos[j] - my_pos; // points i -> j
                const dist: f32 = length(sep);
                if (dist < 0.1 or dist >= c.params.h) {
                    continue;
                }
                const n: Vec2 = sep * splat2(1.0 / dist);
                // closing (penetrating) speed: > 0 <=> the pair is approaching
                const u: f32 = dot(my_vel - b_vel[j], n);
                if (u <= 0.0) {
                    continue; // separating -> no viscosity
                }
                // distance weight: 1 inside h/2, linear -> 0 at h
                const w_lin: f32 = 2.0 * (1.0 - dist / c.params.h);
                const w: f32 = if (w_lin < 1.0) w_lin else 1.0;
                // quadratic in u, then clamp to u so the pair AT MOST stops
                // (u' = u - imp >= 0): never bounce, strictly dissipative; 1/2 each.
                const imp_raw: f32 = c.params.visc_beta * w * u * u;
                const imp: f32 = if (imp_raw < u) imp_raw else u;
                my_vel = my_vel - n * splat2(0.5 * imp);
            }
        }
    }
    b_vel[i] = my_vel;
}

/// Per particle: save prev, advance by vel*dt (the prediction half of
/// Clavet's prediction-relaxation).
pub fn predict(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const p: Vec2 = b_pos[i];
    b_prev[i] = p;
    b_pos[i] = p + b_vel[i] * splat2(c.params.dt);
}

inline fn densityCore(c: k.Ctx(@This()), comptime pig: bool) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const my_pos: Vec2 = b_pos[i];
    var rho: f32 = 0.0;
    var rho_near: f32 = 0.0;
    const ccx: i32 = @floor(my_pos[0] / c.params.h);
    const ccy: i32 = @floor(my_pos[1] / c.params.h);
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const nx: i32 = ccx + dx;
            const ny: i32 = ccy + dy;
            if (nx < 0 or ny < 0) {
                continue;
            }
            const unx: u32 = @intCast(nx);
            const uny: u32 = @intCast(ny);
            if (unx >= c.params.n_cols or uny >= c.params.n_rows) {
                continue;
            }
            const cell: u32 = unx + uny * c.params.n_cols;
            const raw_count: u32 = k.atomicLoad(b_grid_counts, cell);
            const in_cell: u32 = if (raw_count < max_per_cell) raw_count else max_per_cell;
            var s: u32 = 0;
            while (s < in_cell) : (s += 1) {
                const j: u32 = b_grid_data[cell * max_per_cell + s];
                if (j == i) {
                    continue;
                }
                const npos: Vec2 = if (pig) b_grid_data_pos[cell * max_per_cell + s] else b_pos[j];
                const sep: Vec2 = npos - my_pos;
                const d2: f32 = dot(sep, sep);
                if (d2 < c.params.h * c.params.h) {
                    const dist: f32 = @sqrt(d2);
                    const omq: f32 = 1.0 - dist / c.params.h;
                    rho += omq * omq;
                    rho_near += omq * omq * omq;
                }
            }
        }
    }
    b_density[i] = .{ rho, rho_near };
}

/// Per particle: rho = sum(1-q)^2, rho_near = sum(1-q)^3 over the 3x3 neighbourhood.
pub fn density(c: k.Ctx(@This())) void {
    densityCore(c, false);
}

/// Pos-in-grid variant of `density`: reads neighbour positions from
/// grid_data_pos (contiguous per cell) instead of b_pos[j] (random). Same math.
pub fn densityPig(c: k.Ctx(@This())) void {
    densityCore(c, true);
}

/// Cooperatively load `cell`'s 3x3 neighbourhood (index + position) into the
/// shared tile; return tile_len. `noinline` so spv2wgsl keeps it a SEPARATE
/// WGSL function - its cell-dependent `if (in_bounds)` branches then stay
/// inside it and do NOT enclose the workgroupBarrier that `densityTiled`
/// issues after the call (Tint rejects a barrier inside control flow that
/// depends on a c.id-derived cell index; the helper keeps the barrier at the
/// kernel's top level). fluid_wg_size >= max_per_cell, so each lane loads
/// exactly slot `lid` of each cell - straight-line, no inner loop.
noinline fn loadDensityTile(cell: u32, lid: u32, cols: u32, rows: u32) u32 {
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
                    dtile_idx[dst] = idx;
                    dtile_px[dst] = b_pos[idx][0];
                    dtile_py[dst] = b_pos[idx][1];
                }
            }
            off += cnt;
        }
    }
    return if (off < tile_cap) off else tile_cap;
}

/// A/B alternative to `density`: one workgroup per cell, shared-memory tile.
/// Same double-density math, same neighbour set, ~N_cell-fold fewer global
/// reads of b_pos (load the 3x3 region once, gather from the tile). Dispatch
/// per-cell: host sets count = grid_cells * fluid_wg_size. The CPU branch is
/// the per-particle global gather (identical to `density`) so the oracle test
/// can compare them; only the GPU branch is the tiled path.
pub fn densityTiled(c: k.Ctx(@This())) void {
    if (k.is_gpu) {
        const cell: u32 = c.id / fluid_wg_size;
        const lid: u32 = c.id % fluid_wg_size;
        const tile_len: u32 = loadDensityTile(cell, lid, c.params.n_cols, c.params.n_rows);
        k.workgroupBarrier();
        const raw: u32 = k.atomicLoad(b_grid_counts, cell);
        const cnt: u32 = if (raw < max_per_cell) raw else max_per_cell;
        if (lid < cnt) {
            const i: u32 = b_grid_data[cell * max_per_cell + lid];
            const mx: f32 = b_pos[i][0];
            const my: f32 = b_pos[i][1];
            var rho: f32 = 0.0;
            var rho_near: f32 = 0.0;
            var t: u32 = 0;
            while (t < tile_len) : (t += 1) {
                const j: u32 = dtile_idx[t];
                if (j != i) {
                    const sx: f32 = dtile_px[t] - mx;
                    const sy: f32 = dtile_py[t] - my;
                    const d2: f32 = sx * sx + sy * sy;
                    if (d2 < c.params.h * c.params.h) {
                        const dist: f32 = @sqrt(d2);
                        const omq: f32 = 1.0 - dist / c.params.h;
                        rho += omq * omq;
                        rho_near += omq * omq * omq;
                    }
                }
            }
            b_density[i] = .{ rho, rho_near };
        }
    } else {
        const i: u32 = c.id;
        if (i >= c.params.count) {
            return;
        }
        const my_pos: Vec2 = b_pos[i];
        var rho: f32 = 0.0;
        var rho_near: f32 = 0.0;
        const ccx: i32 = @floor(my_pos[0] / c.params.h);
        const ccy: i32 = @floor(my_pos[1] / c.params.h);
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx: i32 = ccx + dx;
                const ny: i32 = ccy + dy;
                if (nx < 0 or ny < 0) {
                    continue;
                }
                const unx: u32 = @intCast(nx);
                const uny: u32 = @intCast(ny);
                if (unx >= c.params.n_cols or uny >= c.params.n_rows) {
                    continue;
                }
                const cell: u32 = unx + uny * c.params.n_cols;
                const raw_count: u32 = k.atomicLoad(b_grid_counts, cell);
                const in_cell: u32 = if (raw_count < max_per_cell) raw_count else max_per_cell;
                var s: u32 = 0;
                while (s < in_cell) : (s += 1) {
                    const j: u32 = b_grid_data[cell * max_per_cell + s];
                    if (j == i) {
                        continue;
                    }
                    const sep: Vec2 = b_pos[j] - my_pos;
                    const d2: f32 = dot(sep, sep);
                    if (d2 < c.params.h * c.params.h) {
                        const dist: f32 = @sqrt(d2);
                        const omq: f32 = 1.0 - dist / c.params.h;
                        rho += omq * omq;
                        rho_near += omq * omq * omq;
                    }
                }
            }
        }
        b_density[i] = .{ rho, rho_near };
    }
}

inline fn forceCore(c: k.Ctx(@This()), comptime pig: bool) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const my_pos: Vec2 = b_pos[i];
    const my_d: Vec2 = b_density[i];
    const my_press: f32 = c.params.k_far * (my_d[0] - c.params.r0);
    const my_near: f32 = c.params.k_near * my_d[1];
    var corr: Vec2 = .{ 0.0, 0.0 };
    // Pressure-only (Clavet double-density relaxation). Viscosity is now a
    // SEPARATE pre-predict pass (`viscosity`) on the stale grid - moving it out
    // of here restores the paper's apply-viscosity-then-predict ordering, which
    // is more stable (and lets the sim take a larger dt).
    const ccx: i32 = @floor(my_pos[0] / c.params.h);
    const ccy: i32 = @floor(my_pos[1] / c.params.h);
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const nx: i32 = ccx + dx;
            const ny: i32 = ccy + dy;
            if (nx < 0 or ny < 0) {
                continue;
            }
            const unx: u32 = @intCast(nx);
            const uny: u32 = @intCast(ny);
            if (unx >= c.params.n_cols or uny >= c.params.n_rows) {
                continue;
            }
            const cell: u32 = unx + uny * c.params.n_cols;
            const raw_count: u32 = k.atomicLoad(b_grid_counts, cell);
            const in_cell: u32 = if (raw_count < max_per_cell) raw_count else max_per_cell;
            var s: u32 = 0;
            while (s < in_cell) : (s += 1) {
                const j: u32 = b_grid_data[cell * max_per_cell + s];
                if (j == i) {
                    continue;
                }
                const npos: Vec2 = if (pig) b_grid_data_pos[cell * max_per_cell + s] else b_pos[j];
                const rel: Vec2 = npos - my_pos;
                const d2: f32 = dot(rel, rel);
                if (d2 >= c.params.h * c.params.h) {
                    continue;
                }
                const dist: f32 = @sqrt(d2);
                // Co-location fallback: antisymmetric cardinal direction so
                // the pair always separates instead of NaN-ing.
                var dir: Vec2 = undefined;
                if (dist > 0.5) {
                    dir = rel * splat2(1.0 / dist);
                } else {
                    dir = .{ if (i < j) 1.0 else -1.0, 0.0 };
                }
                const omq: f32 = 1.0 - dist / c.params.h;
                const jd: Vec2 = b_density[j];
                const j_press: f32 = c.params.k_far * (jd[0] - c.params.r0);
                const j_near: f32 = c.params.k_near * jd[1];
                const disp: f32 = 0.5 * c.params.dt * c.params.dt *
                    ((my_press + j_press) * omq + (my_near + j_near) * omq * omq);
                corr = corr - dir * splat2(disp);
            }
        }
    }
    b_delta[i] = corr;
}

/// Per particle: the double-density displacement (Clavet Alg. 2, symmetric
/// gather - sum both pressures, write only your own delta; no atomics).
pub fn force(c: k.Ctx(@This())) void {
    forceCore(c, false);
}

/// Pos-in-grid variant of `force`: reads neighbour positions from grid_data_pos
/// (contiguous) instead of b_pos[j] (random). Neighbour density/velocity reads
/// stay scattered (not in the grid), so this coalesces 1 of force's 3 reads.
pub fn forcePig(c: k.Ctx(@This())) void {
    forceCore(c, true);
}

/// Per particle: apply the correction, clamp to the domain, recompute
/// velocity from displacement (absorbing every position edit), speed-cap.
pub fn applyAndFinalize(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    var p: Vec2 = b_pos[i] + b_delta[i];
    // ---- Boundary handling (corner-explosion fix) ----
    // A naive independent-axis clamp drives every corner particle onto the
    // EXACT corner point (both axes pinned), so several particles overlap at
    // dist~0 -> the near-density term (1-r/h)^3 spikes -> explosive repulsion.
    // Instead: a SOFT inward push that ramps up over a margin band (so density
    // stays smooth near walls), plus a hard safety clamp with a tiny
    // index-derived jitter ALONG each wall to break exact coincidence in the
    // worst case. The jitter is sub-particle-radius so it doesn't perturb the
    // bulk fluid.
    const band: f32 = c.params.h; // push starts one interaction radius from a wall
    const push: f32 = 0.25; // fraction of the overshoot corrected per substep
    // Left / right walls.
    if (p[0] < band) {
        p[0] += (band - p[0]) * push;
    } else if (p[0] > c.params.dom_w - band) {
        p[0] -= (p[0] - (c.params.dom_w - band)) * push;
    }
    // Top / bottom walls.
    if (p[1] < band) {
        p[1] += (band - p[1]) * push;
    } else if (p[1] > c.params.dom_h - band) {
        p[1] -= (p[1] - (c.params.dom_h - band)) * push;
    }
    // Hard safety clamp with a small jitter parallel to each wall, so two
    // particles forced to the same wall/corner do not land on one point.
    const margin: f32 = 1.5;
    const jitter: f32 = float(i % 7) * 0.3; // 0..1.8 px, sub-radius
    const lo_x: f32 = margin + jitter;
    const hi_x: f32 = c.params.dom_w - margin - jitter;
    const lo_y: f32 = margin + jitter;
    const hi_y: f32 = c.params.dom_h - margin - jitter;
    p[0] = clamp(p[0], lo_x, hi_x);
    p[1] = clamp(p[1], lo_y, hi_y);
    b_pos[i] = p;
    var v: Vec2 = (p - b_prev[i]) * splat2(1.0 / c.params.dt);
    const speed: f32 = length(v);
    const max_speed: f32 = 40.0;
    if (speed > max_speed) {
        v = v * splat2(max_speed / speed);
    }
    b_vel[i] = v;
}

/// Simple-mode kernel (the "simple" UI toggle): gravity + integrate + wall
/// bounce on a single particle's own four floats - no grid, no neighbours, no
/// cross-particle reads. A non-SPH sanity mode; if even this misbehaves the
/// fault is in the primitive dispatch/storage path, not the fluid math.
pub fn fallBounceLean(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    var p: Vec2 = b_pos[i];
    var v: Vec2 = b_vel[i];
    v[1] = v[1] + c.params.gravity_y * c.params.dt;
    p = p + v * splat2(c.params.dt);
    const r: f32 = 5.5;
    if (p[0] < r) {
        p[0] = r;
        v[0] = -v[0] * 0.85;
    }
    if (p[0] > c.params.dom_w - r) {
        p[0] = c.params.dom_w - r;
        v[0] = -v[0] * 0.85;
    }
    if (p[1] < r) {
        p[1] = r;
        v[1] = -v[1] * 0.85;
    }
    if (p[1] > c.params.dom_h - r) {
        p[1] = c.params.dom_h - r;
        v[1] = -v[1] * 0.85;
    }
    b_pos[i] = p;
    b_vel[i] = v;
}

comptime {
    k.installKernel(@This(), "fallBounceLean");
    k.installKernel(@This(), "clearGrid");
    k.installKernel(@This(), "buildGrid");
    k.installKernel(@This(), "gravityMouse");
    k.installKernel(@This(), "viscosity");
    k.installKernel(@This(), "predict");
    k.installKernel(@This(), "density");
    k.installKernel(@This(), "densityTiled");
    k.installKernel(@This(), "densityPig");
    k.installKernel(@This(), "force");
    k.installKernel(@This(), "forcePig");
    k.installKernel(@This(), "applyAndFinalize");
}

// CPU oracle for the per-particle atomic grid build. The CPU twin runs the
// REAL @atomicRmw (kompute's atomicAdd on the native target), so this verifies
// the parallel buildGrid algorithm independent of the GPU: clearGrid zeroes the
// counts, buildGrid claims a slot per particle, and the resulting grid must be
// well-formed (counts sum to N, no overflow, every particle in its own cell).
// Run on demand:
//   zig test --dep fluid_kernels --dep zm -Mroot=<this file via a shim> ...
// (also typechecked as part of the example compile.)
test "buildGrid per-particle CPU oracle: grid well-formed" {
    const N: u32 = 2000;
    const h: f32 = interact_radius;
    const params: Params = .{
        .count = N,
        .dt = 1.0,
        .h = h,
        .r0 = 10.0,
        .k_far = 0.004,
        .k_near = 0.01,
        .gravity_y = 0.05,
        .visc_beta = 0.1,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_force = 0,
        .mouse_radius = 100,
        .dom_w = domain_w,
        .dom_h = domain_h,
        .n_cols = grid_cols,
        .n_rows = grid_rows,
    };
    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r: std.Random = rng.random();
    var p: u32 = 0;
    while (p < N) : (p += 1) {
        g.B.pos[p] = .{ r.float(f32) * domain_w, r.float(f32) * domain_h };
    }
    var cell: u32 = 0;
    while (cell < grid_cols * grid_rows) : (cell += 1) {
        clearGrid(.{ .id = cell, .params = params });
    }
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        buildGrid(.{ .id = i, .params = params });
    }
    var total: u32 = 0;
    cell = 0;
    while (cell < grid_cols * grid_rows) : (cell += 1) {
        const cnt: u32 = g.B.grid_counts[cell];
        try expect(cnt <= max_per_cell);
        total += cnt;
    }
    try expectEqual(N, total);
    i = 0;
    while (i < N) : (i += 1) {
        const pos: Vec2 = g.B.pos[i];
        const mcx: f32 = float(grid_cols - 1);
        const mcy: f32 = float(grid_rows - 1);
        const cx: u32 = @trunc(clamp(@floor(pos[0] / h), 0.0, mcx));
        const cy: u32 = @trunc(clamp(@floor(pos[1] / h), 0.0, mcy));
        const c: u32 = cx + cy * grid_cols;
        const cnt: u32 = g.B.grid_counts[c];
        var found: bool = false;
        var s: u32 = 0;
        while (s < cnt) : (s += 1) {
            if (g.B.grid_data[c * max_per_cell + s] == i) {
                found = true;
                break;
            }
        }
        try expect(found);
    }
}

// densityTiled's CPU branch is the per-particle global gather (the same
// neighbour set as `density`), so on the CPU the two MUST produce identical
// b_density. This guards the CPU oracle path (the GPU tiled path is proven
// separately by the tile_smoke device test + naga). Build a grid, run
// `density` for every particle, snapshot, then run `densityTiled` and compare.
test "densityTiled CPU oracle matches density" {
    const N: u32 = 3000;
    const h: f32 = interact_radius;
    const params: Params = .{
        .count = N,
        .dt = 1.0,
        .h = h,
        .r0 = 10.0,
        .k_far = 0.004,
        .k_near = 0.01,
        .gravity_y = 0.05,
        .visc_beta = 0.1,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_force = 0,
        .mouse_radius = 100,
        .dom_w = domain_w,
        .dom_h = domain_h,
        .n_cols = grid_cols,
        .n_rows = grid_rows,
    };
    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xBADF00D);
    const r: std.Random = rng.random();
    var p: u32 = 0;
    while (p < N) : (p += 1) {
        g.B.pos[p] = .{ r.float(f32) * domain_w, r.float(f32) * domain_h };
    }
    var cell: u32 = 0;
    while (cell < grid_cols * grid_rows) : (cell += 1) {
        clearGrid(.{ .id = cell, .params = params });
    }
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        buildGrid(.{ .id = i, .params = params });
    }
    // Reference: per-particle density.
    i = 0;
    while (i < N) : (i += 1) {
        density(.{ .id = i, .params = params });
    }
    var ref: [num_particles]Vec2 = undefined;
    i = 0;
    while (i < N) : (i += 1) {
        ref[i] = g.B.density[i];
    }
    // Candidate: densityTiled (CPU branch).
    i = 0;
    while (i < N) : (i += 1) {
        densityTiled(.{ .id = i, .params = params });
    }
    i = 0;
    while (i < N) : (i += 1) {
        try expectEqual(ref[i][0], g.B.density[i][0]);
        try expectEqual(ref[i][1], g.B.density[i][1]);
    }
}

// pos-in-grid variants must be bit-identical to the originals on CPU: buildGrid
// writes grid_data_pos[slot] = b_pos[the slot's particle], so reading the slot
// pos == reading b_pos[j]. Guards densityPig + forcePig.
test "pos-in-grid variants match originals" {
    const N: u32 = 3000;
    const h: f32 = interact_radius;
    const params: Params = .{
        .count = N,
        .dt = 1.0,
        .h = h,
        .r0 = 10.0,
        .k_far = 0.004,
        .k_near = 0.01,
        .gravity_y = 0.05,
        .visc_beta = 0.1,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_force = 0,
        .mouse_radius = 100,
        .dom_w = domain_w,
        .dom_h = domain_h,
        .n_cols = grid_cols,
        .n_rows = grid_rows,
    };
    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x5EED);
    const r: std.Random = rng.random();
    var p: u32 = 0;
    while (p < N) : (p += 1) {
        g.B.pos[p] = .{ r.float(f32) * domain_w, r.float(f32) * domain_h };
        g.B.vel[p] = .{ r.float(f32) * 2 - 1, r.float(f32) * 2 - 1 };
    }
    var cell: u32 = 0;
    while (cell < grid_cols * grid_rows) : (cell += 1) {
        clearGrid(.{ .id = cell, .params = params });
    }
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        buildGrid(.{ .id = i, .params = params });
    }
    // density vs densityPig.
    i = 0;
    while (i < N) : (i += 1) {
        density(.{ .id = i, .params = params });
    }
    var rho_ref: [num_particles]Vec2 = undefined;
    i = 0;
    while (i < N) : (i += 1) {
        rho_ref[i] = g.B.density[i];
    }
    i = 0;
    while (i < N) : (i += 1) {
        densityPig(.{ .id = i, .params = params });
    }
    i = 0;
    while (i < N) : (i += 1) {
        try expectEqual(rho_ref[i][0], g.B.density[i][0]);
        try expectEqual(rho_ref[i][1], g.B.density[i][1]);
    }
    // force vs forcePig (needs valid densities, just computed above).
    i = 0;
    while (i < N) : (i += 1) {
        force(.{ .id = i, .params = params });
    }
    var d_ref: [num_particles]Vec2 = undefined;
    i = 0;
    while (i < N) : (i += 1) {
        d_ref[i] = g.B.delta[i];
    }
    i = 0;
    while (i < N) : (i += 1) {
        forcePig(.{ .id = i, .params = params });
    }
    i = 0;
    while (i < N) : (i += 1) {
        try expectEqual(d_ref[i][0], g.B.delta[i][0]);
        try expectEqual(d_ref[i][1], g.B.delta[i][1]);
    }
}
