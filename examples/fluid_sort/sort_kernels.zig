//! sort_kernels.zig - the GPU fluid with a SPATIAL COUNTING SORT (t1178).
//! Same Clavet double-density-relaxation SPH as fluid_gpu, but the
//! neighbour grid is a counting sort instead of per-cell slot arrays:
//!   clearGrid -> countGrid -> prefixSum -> scatter -> copyback
//! reorders pos/vel/prev into CELL ORDER each frame, so the density / force /
//! viscosity neighbour loops read CONTIGUOUS memory (b_pos[cell_start[c]..[c+1]])
//! and coalesce across the warp - the win the random b_pos[grid_data[..]] gather
//! could never give. There is no max_per_cell cap either (ranges are exact), so
//! dense regions never drop neighbours. Particles are indistinguishable, so the
//! sorted order simply BECOMES the canonical order for the next frame (no
//! unsort). grid_counts is reused as the per-cell scatter cursor (prefixSum
//! zeroes it after reading the counts into cell_start).
//!
//! Per-substep order:
//!   gravityMouse -> viscosity (STALE sort) -> predict
//!   -> clearGrid -> countGrid -> prefixSum -> scatter -> copyback (FRESH sort)
//!   -> density -> force -> applyAndFinalize
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
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;

/// MATCHED TO `fluid_gpu` so the two are directly comparable: same particle count, same
/// interaction radius, same domain, same spawn, same physics constants. The ONLY thing
/// that differs between the demos is the neighbour-finding strategy - a counting sort that
/// reorders particles into cell order (here) versus per-cell bucket lists (fluid_gpu).
pub const num_particles: u32 = 20000;
pub const domain_w: f32 = 900.0;
pub const domain_h: f32 = 600.0;
pub const interact_radius: f32 = 22.0;
// Retained for host diagnostics only; the counting sort itself is uncapped.
pub const max_per_cell: u32 = 64;
pub const grid_cols: u32 = @trunc(@ceil(domain_w / interact_radius) + 2);
pub const grid_rows: u32 = @trunc(@ceil(domain_h / interact_radius) + 2);
pub const grid_cells: u32 = grid_cols * grid_rows;

pub const config = k.Config{ .max = num_particles, .workgroup = 256 };

/// One storage buffer, the whole sim state. `pos` is FIRST: the renderer reads
/// positions at offset 0 by instance_index (the DrawPoints contract).
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
    /// Per-cell particle count (atomic). countGrid accumulates it; prefixSum
    /// consumes it into cell_start and ZEROES it so scatter can reuse it as the
    /// per-cell write cursor.
    grid_counts: [grid_cells]u32,
    /// Exclusive prefix sum of grid_counts, +1 sentinel: cell c's particles
    /// occupy sorted slots [cell_start[c], cell_start[c+1]); cell_start[cells]=N.
    cell_start: [grid_cells + 1]u32,
    /// Scatter scratch - scatter writes the cell-sorted pos/vel/prev here, then
    /// copyback copies them back so pos/vel/prev are canonical (= sorted).
    /// ONE scratch buffer for the counting sort's reorder, holding pos, vel and prev
    /// back-to-back: `[0..N)` = pos2, `[N..2N)` = vel2, `[2N..3N)` = prev2.
    ///
    /// This used to be THREE separate buffers, which put the module at TEN - and WebGPU
    /// guarantees only EIGHT storage buffers per shader stage. Bindings past the eighth
    /// silently do not bind: the writes vanish with no error and the kernel runs on happily,
    /// which is exactly how this fluid came to fill its box while its twin `fluid_gpu`
    /// (which sits at exactly eight) worked perfectly. Packing them costs one multiply-add
    /// and buys the module back under the ceiling. `Compute.initGpu` now refuses to compile
    /// a module over the limit, so this can never be silently re-introduced.
    /// ...plus 16 spare Vec2 at the tail, which `paramEcho` uses to write back every field
    /// of `Params` AS THE SHADER ACTUALLY SEES IT. No new buffer: the module is at WebGPU's
    /// hard ceiling of 8.
    scratch: [3 * num_particles + 16]Vec2,
};

/// Scalar-field uniform (array pads break uniform layout). 16 x 4B = 64B.
pub const Params = extern struct {
    count: u32,
    dt: f32,
    h: f32,
    r0: f32,
    k_far: f32,
    k_near: f32,
    gravity_x: f32,
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
    /// Wall-contact damping (proportion of velocity REMOVED at the boundary).
    /// normal = the into-wall component; tangential = the along-wall component.
    /// 0 = frictionless/elastic-ish, 1 = fully killed. Live-tunable for tuning.
    wall_normal_damp: f32 = 0,
    wall_tangent_damp: f32 = 0,
    // std140 padding: 19 scalar fields = 76 B; a WGSL uniform block rounds its
    // size up to a 16-B multiple -> 80 B. One trailing pad gets us there. (The
    // Compute(M) `@sizeOf(Params) % 16` comptime check enforces this.)
    _pad0: f32 = 0,
};

pub const g = k.Globals(@This());
const b_pos = g.bind(.pos);
const b_prev = g.bind(.prev);
const b_vel = g.bind(.vel);
const b_delta = g.bind(.delta);
const b_density = g.bind(.density);
const b_grid_counts = g.bind(.grid_counts);
const b_cell_start = g.bind(.cell_start);
const b_scratch = g.bind(.scratch);

/// Bin a position to its grid cell, clamped to the grid (matching the centre
/// cell the neighbour search derives). countGrid and scatter MUST agree, so
/// both go through here.
fn cellOf(pos: Vec2, n_cols: u32, n_rows: u32, h: f32) u32 {
    const max_cx: f32 = float(n_cols - 1);
    const max_cy: f32 = float(n_rows - 1);
    const cx: u32 = @trunc(clamp(@floor(pos[0] / h), 0.0, max_cx));
    const cy: u32 = @trunc(clamp(@floor(pos[1] / h), 0.0, max_cy));
    return cx + cy * n_cols;
}

/// Per CELL (dispatch count = grid_cells): zero this cell's count before
/// countGrid accumulates into it.
pub fn clearGrid(c: k.Ctx(@This())) void {
    const cell: u32 = c.id;
    if (cell >= c.params.n_cols * c.params.n_rows) {
        return;
    }
    k.atomicStore(b_grid_counts, cell, 0);
}

/// Per PARTICLE: count this particle into its cell (the counting pass). The
/// atomicAdd result is unused - we only want the final per-cell totals.
pub fn countGrid(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const cell: u32 = cellOf(b_pos[i], c.params.n_cols, c.params.n_rows, c.params.h);
    _ = k.atomicAdd(b_grid_counts, cell, 1);
}

/// SINGLE invocation (dispatch count = 1): serial exclusive prefix sum of
/// grid_counts into cell_start, zeroing grid_counts as we go so scatter can
/// reuse it as the per-cell write cursor. cell count (~1.3k) is tiny next to N.
/// !! BROKEN ON GPU - spv2wgsl mis-structurizes this loop. See `src/notes/claude.md`.
///
/// This is the ONLY kernel in the tree with a real runtime loop (every other neighbour
/// walk is an `inline for` and unrolls), and it is the only one that trips the bug.
/// spv2wgsl emits two OpPhi variables DECLARED, READ, and NEVER ASSIGNED:
///
///     var phi26853: u32;              // never written
///     let _26845: bool = 72u == 72u;  // computed, then discarded
///     phi26855 = phi26853;            // reads the zero-init
///     let _26859: bool = phi26855 == 41u;   // -> false -> loop breaks immediately
///
/// WGSL zero-initialises them, so the loop exits on its first iteration, `cell_start`
/// stays all zeroes, `scatter` piles every particle into slot 0, and `copyback` writes
/// those zeros back into `pos`. That is the whole "fluid stuck in the corner" bug.
///
/// Neither `@setRuntimeSafety(false)` nor changing the loop form (while-with-continue-
/// expression vs manual increment) changes it - both still emit 2 unassigned phis. The
/// fix belongs in spv2wgsl's phi/default-exit handling (`applyDefaultToShortestExit`).
pub fn prefixSum(c: k.Ctx(@This())) void {
    if (c.id != 0) {
        return;
    }
    const cells: u32 = c.params.n_cols * c.params.n_rows;
    var acc: u32 = 0;
    var cell: u32 = 0;
    while (cell < cells) : (cell += 1) {
        const cnt: u32 = k.atomicLoad(b_grid_counts, cell);
        b_cell_start[cell] = acc;
        acc += cnt;
        k.atomicStore(b_grid_counts, cell, 0);
    }
    b_cell_start[cells] = acc;
}

/// Per PARTICLE: claim a slot in this particle's cell (atomicAdd on the reused
/// grid_counts cursor) and write its pos/vel/prev into the cell-sorted scratch
/// at cell_start[cell] + slot.
pub fn scatter(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const cell: u32 = cellOf(b_pos[i], c.params.n_cols, c.params.n_rows, c.params.h);
    const slot: u32 = k.atomicAdd(b_grid_counts, cell, 1);
    const dest: u32 = b_cell_start[cell] + slot;
    b_scratch[dest] = b_pos[i];
    b_scratch[num_particles + dest] = b_vel[i];
    b_scratch[2 * num_particles + dest] = b_prev[i];
}

/// Per PARTICLE: copy the cell-sorted scratch back so pos/vel/prev ARE the
/// sorted order - the canonical arrays for the rest of this frame and the next.
pub fn copyback(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    b_pos[i] = b_scratch[i];
    b_vel[i] = b_scratch[num_particles + i];
    b_prev[i] = b_scratch[2 * num_particles + i];
}

/// Per particle: gravity + the (signed) mouse impulse with linear falloff.
pub fn gravityMouse(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    var v: Vec2 = b_vel[i];
    // Gravity is a VECTOR now (was y-only): the host points it via the phone's
    // accelerometer (tilt) while the slider sets its magnitude. With tilt off
    // the host sends (0, mag), so this stays identical to the old y-only pull.
    v[0] = v[0] + c.params.gravity_x * c.params.dt;
    v[1] = v[1] + c.params.gravity_y * c.params.dt;
    const to_p: Vec2 = b_pos[i] - Vec2{ c.params.mouse_x, c.params.mouse_y };
    const d: f32 = length(to_p);
    if (d >= 0.5 and d < c.params.mouse_radius and c.params.mouse_force != 0.0) {
        const falloff: f32 = 1.0 - d / c.params.mouse_radius;
        v = v + to_p * splat2(c.params.mouse_force * falloff / d);
    }
    b_vel[i] = v;
}

/// Per particle: collision-style viscosity (t1178). Acts ONLY on approaching
/// pairs (closing speed u > 0); the impulse is QUADRATIC in u, then CLAMPED so
/// it can at most bring the pair's radial motion to rest (u' = u - imp >= 0):
/// never a bounce, strictly dissipative, 1/2 each. Weight 1 inside h/2, linear to
/// 0 at h. Reads the STALE sort (last frame's cell_start + the still-sorted
/// pos) - it runs before predict and the reorder.
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
            const start: u32 = b_cell_start[cell];
            // Capped to match `fluid_gpu` - see the note in `density`.
            const end_raw: u32 = b_cell_start[cell + 1];
            const end: u32 = if (end_raw - start > max_per_cell) start + max_per_cell else end_raw;
            var kk: u32 = start;
            while (kk < end) : (kk += 1) {
                if (kk == i) {
                    continue;
                }
                const sep: Vec2 = b_pos[kk] - my_pos;
                const dist: f32 = length(sep);
                if (dist < 0.1 or dist >= c.params.h) {
                    continue;
                }
                const n: Vec2 = sep * splat2(1.0 / dist);
                const u: f32 = dot(my_vel - b_vel[kk], n);
                if (u <= 0.0) {
                    continue;
                }
                const w_lin: f32 = 2.0 * (1.0 - dist / c.params.h);
                const w: f32 = if (w_lin < 1.0) w_lin else 1.0;
                const imp_raw: f32 = c.params.visc_beta * w * u * u;
                const imp: f32 = if (imp_raw < u) imp_raw else u;
                my_vel = my_vel - n * splat2(0.5 * imp);
            }
        }
    }
    b_vel[i] = my_vel;
}

/// Per particle: save prev, advance by vel*dt (the prediction half of Clavet's
/// prediction-relaxation).
pub fn predict(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const p: Vec2 = b_pos[i];
    b_prev[i] = p;
    b_pos[i] = p + b_vel[i] * splat2(c.params.dt);
}

/// Per particle: rho = sum(1-q)^2, rho_near = sum(1-q)^3 over the 3x3 neighbourhood,
/// iterating each cell's CONTIGUOUS sorted range [cell_start[c], cell_start[c+1]).
pub fn density(c: k.Ctx(@This())) void {
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
            const start: u32 = b_cell_start[cell];
            // CAP THE CELL, exactly as `fluid_gpu` does. Its bucket lists hold at most
            // `max_per_cell` indices and silently drop the overflow, so it never sees more
            // than 64 neighbours from one cell. This walk used to read the WHOLE range -
            // and with cellmax running 74..97 that is ~30 extra neighbours per dense cell
            // that the twin never counts. rho comes out systematically higher from the SAME
            // configuration, and `rest_density = 15.39` was tuned against the capped number.
            // Two demos cannot be a controlled comparison while one of them silently counts
            // a different neighbourhood.
            const end_raw: u32 = b_cell_start[cell + 1];
            const end: u32 = if (end_raw - start > max_per_cell) start + max_per_cell else end_raw;
            var kk: u32 = start;
            while (kk < end) : (kk += 1) {
                if (kk == i) {
                    continue;
                }
                const sep: Vec2 = b_pos[kk] - my_pos;
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

/// Per particle: pressure-only double-density displacement (viscosity is the
/// separate pre-predict pass). Reads neighbour pos + density from the CONTIGUOUS
/// sorted ranges.
pub fn force(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const my_pos: Vec2 = b_pos[i];
    const my_d: Vec2 = b_density[i];
    const my_press: f32 = c.params.k_far * (my_d[0] - c.params.r0);
    const my_near: f32 = c.params.k_near * my_d[1];
    var corr: Vec2 = .{ 0.0, 0.0 };
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
            const start: u32 = b_cell_start[cell];
            // Capped to match `fluid_gpu` - see the note in `density`.
            const end_raw: u32 = b_cell_start[cell + 1];
            const end: u32 = if (end_raw - start > max_per_cell) start + max_per_cell else end_raw;
            var kk: u32 = start;
            while (kk < end) : (kk += 1) {
                if (kk == i) {
                    continue;
                }
                const rel: Vec2 = b_pos[kk] - my_pos;
                const d2: f32 = dot(rel, rel);
                if (d2 >= c.params.h * c.params.h) {
                    continue;
                }
                const dist: f32 = @sqrt(d2);
                var dir: Vec2 = undefined;
                if (dist > 0.5) {
                    dir = rel * splat2(1.0 / dist);
                } else {
                    // Co-location fallback (particles at ~the same point). THE BUG
                    // this replaces: a FIXED +/-x axis whose sign was `i < kk`. But i,
                    // kk are sorted SLOTS, and the sort key is cell = cx + cy*n_cols,
                    // so slot grows with ROW (cy). For a vertically-stacked
                    // coincident pair the lower row always has the lower slot ->
                    // always pushed -x, upper row +x. That is a systematic shear
                    // (v_x grows with y) which funnels particles into the (0,0) and
                    // (W,H) corners - the bottom-left / top-right ejections. Fix:
                    // pick a pair-CONSISTENT pseudo-random direction (seed is
                    // symmetric in i,kk), signed by `i < kk` so it stays
                    // antisymmetric (momentum-conserving) but has NO axis bias.
                    const seed: u32 = (i +% kk) *% 2654435761;
                    const ang: f32 = float(seed % 6283) * 0.001;
                    const sgn: f32 = if (i < kk) 1.0 else -1.0;
                    dir = .{ @cos(ang) * sgn, @sin(ang) * sgn };
                }
                const omq: f32 = 1.0 - dist / c.params.h;
                const jd: Vec2 = b_density[kk];
                const j_press: f32 = c.params.k_far * (jd[0] - c.params.r0);
                const j_near: f32 = c.params.k_near * jd[1];
                const disp: f32 = 0.5 * c.params.dt * c.params.dt *
                    ((my_press + j_press) * omq + (my_near + j_near) * omq * omq);
                corr = corr - dir * splat2(disp);
            }
        }
    }
    // NO CORRECTION CLAMP - `fluid_gpu` has none, and this is meant to be its twin.
    //
    // There WAS one here (|corr| bounded to h/2), added to stop a rho_near spike in a
    // corner flinging a particle across the domain. But it also silently changes the
    // pressure solve wherever the correction is large, which is exactly where the fluid
    // is deciding how to compress - and with `h` raised from 10 to 22 the clamp bites in
    // places it never used to. Two demos cannot be compared while one of them quietly
    // truncates its own pressure. The wall clamp and the 40 px/s speed cap in
    // `applyAndFinalize` already bound the runaway this was guarding against.
    b_delta[i] = corr;
}

/// Per particle: derive velocity from the PHYSICS step, then resolve the domain
/// boundary. Velocity is taken BEFORE any boundary position edit (so clamps/pushes
/// can't pump energy in - the corner-jet fix), then a wall contact removes a
/// tunable proportion of the normal and tangential velocity (diagnostic knobs).
pub fn applyAndFinalize(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    // Physics result for this substep: predicted position + the pressure
    // correction. Velocity is read from THIS, before any boundary edit, so a
    // position correction can never leak into velocity.
    // POSITION FIRST, VELOCITY FROM THE FINAL POSITION.
    //
    // This is position-based dynamics: the walls are CONSTRAINTS, so the velocity has to be
    // derived from the position that survives them - `v = (p_final - p_prev) / dt`. It used
    // to be taken from `p_phys`, BEFORE the wall band and the clamp. That made the wall band
    // a free teleport: it shoved a particle inward every substep and left its velocity
    // untouched, so the particle paid nothing for the displacement. An energy pump running
    // along all four walls. The fluid inflated until it filled the box (rho 11.5 against a
    // rest density of 15.39) and flung particles clean through the boundary - `cellmax 97`
    // against an average of 16.7, because `cellOf` clamps every out-of-bounds particle into
    // cell 0. `fluid_gpu`, which computes v after its clamp, showed none of it (cap 0).
    var p: Vec2 = b_pos[i] + b_delta[i];
    // (Re-added) soft inward repulsion over a margin band. POSITION-ONLY: it
    // edits p, never v - and since predict makes next frame's b_pos = b_prev +
    // vel*dt, the b_prev cancels in the velocity formula, so this can never pump.
    const band: f32 = c.params.h;
    const push: f32 = 0.25;
    if (p[0] < band) {
        p[0] += (band - p[0]) * push;
    } else if (p[0] > c.params.dom_w - band) {
        p[0] -= (p[0] - (c.params.dom_w - band)) * push;
    }
    if (p[1] < band) {
        p[1] += (band - p[1]) * push;
    } else if (p[1] > c.params.dom_h - band) {
        p[1] -= (p[1] - (c.params.dom_h - band)) * push;
    }
    // Hard clamp + per-axis jitter (different x/y bases -> 2D scatter, not a
    // diagonal line). Position-only.
    const margin: f32 = 1.5;
    const jx: f32 = float(i % 7) * 0.4;
    const jy: f32 = float((i / 7) % 7) * 0.4;
    const lo_x: f32 = margin + jx;
    const hi_x: f32 = c.params.dom_w - margin - jx;
    const lo_y: f32 = margin + jy;
    const hi_y: f32 = c.params.dom_h - margin - jy;
    const hit_x_lo: bool = p[0] < lo_x;
    const hit_x_hi: bool = p[0] > hi_x;
    const hit_y_lo: bool = p[1] < lo_y;
    const hit_y_hi: bool = p[1] > hi_y;
    if (hit_x_lo) {
        p[0] = lo_x;
    } else if (hit_x_hi) {
        p[0] = hi_x;
    }
    if (hit_y_lo) {
        p[1] = lo_y;
    } else if (hit_y_hi) {
        p[1] = hi_y;
    }
    // Wall-contact damping (the experiment): remove a proportion of the into-wall
    // NORMAL velocity and the along-wall TANGENTIAL velocity. keep = 1 - damp.
    // The constraint has been applied; NOW the velocity follows from the motion the particle
    // actually made. A particle stopped by a wall gets a small v here by construction, so
    // the explicit damping below only shapes what the constraint already resolved.
    var v: Vec2 = (p - b_prev[i]) * splat2(1.0 / c.params.dt);
    const kn: f32 = 1.0 - c.params.wall_normal_damp;
    const kt: f32 = 1.0 - c.params.wall_tangent_damp;
    const hit_x: bool = hit_x_lo or hit_x_hi;
    const hit_y: bool = hit_y_lo or hit_y_hi;
    // Normal = the axis that hit; damp only the INTO-wall direction.
    if (hit_x_lo and v[0] < 0.0) {
        v[0] = v[0] * kn;
    }
    if (hit_x_hi and v[0] > 0.0) {
        v[0] = v[0] * kn;
    }
    if (hit_y_lo and v[1] < 0.0) {
        v[1] = v[1] * kn;
    }
    if (hit_y_hi and v[1] > 0.0) {
        v[1] = v[1] * kn;
    }
    // Tangential = the perpendicular axis; damp it on any wall touch (friction).
    // At a corner both components get hit, which is fine (strong corner bleed).
    if (hit_x) {
        v[1] = v[1] * kt;
    }
    if (hit_y) {
        v[0] = v[0] * kt;
    }
    b_pos[i] = p;
    const speed: f32 = length(v);
    const max_speed: f32 = 40.0;
    if (speed > max_speed) {
        v = v * splat2(max_speed / speed);
    }
    b_vel[i] = v;
}

/// The kernel manifest: every `@compute` entry this module exports, in pipeline
/// order. This single list drives BOTH sides of the dual-shape build:
///   - GPU: `installKernels(@This())` (below) exports one SPIR-V entry per name.
///   - host: `fluid_sort.zig` loops this list to `@embedFile` each kernel's
///     generated WGSL and hand it to `Compute(fk).initGpu` - no hand-kept array.
/// So a typo or a missing kernel surfaces as a compile error (a `@embedFile` of
/// a `<name>_wgsl` module the build never generated), never a silent runtime
/// "kernel not registered". Add a kernel = add its fn above + its name here.
/// Where `paramEcho` writes. Past everything the sort touches.
pub const echo_base: u32 = 3 * num_particles;

pub const kernels = [_][:0]const u8{
    "paramEcho",
    "clearGrid",
    "countGrid",
    "prefixSum",
    "scatter",
    "copyback",
    "gravityMouse",
    "viscosity",
    "predict",
    "density",
    "force",
    "applyAndFinalize",
};

/// ECHO THE UNIFORM BACK OUT, exactly as the shader reads it.
///
/// Only THREE of the 20 Params fields have ever been verified to arrive (`count`, `n_cols`,
/// `n_rows`) - and one of those was silently arriving as ZERO for who knows how long, from a
/// whole-struct copy out of the uniform address space that dropped a member. Nothing has
/// ever checked the other seventeen. A single wrong `h`, `r0` or `dt` would produce exactly
/// what we are looking at: a fluid whose kernels are all provably correct and which still
/// will not settle.
pub fn paramEcho(c: k.Ctx(@This())) void {
    if (c.id != 0) {
        return;
    }
    const b: u32 = echo_base;
    b_scratch[b + 0] = .{ float(c.params.count), c.params.dt };
    b_scratch[b + 1] = .{ c.params.h, c.params.r0 };
    b_scratch[b + 2] = .{ c.params.k_far, c.params.k_near };
    b_scratch[b + 3] = .{ c.params.gravity_x, c.params.gravity_y };
    b_scratch[b + 4] = .{ c.params.visc_beta, c.params.mouse_x };
    b_scratch[b + 5] = .{ c.params.mouse_y, c.params.mouse_force };
    b_scratch[b + 6] = .{ c.params.mouse_radius, c.params.dom_w };
    b_scratch[b + 7] = .{ c.params.dom_h, float(c.params.n_cols) };
    b_scratch[b + 8] = .{ float(c.params.n_rows), c.params.wall_normal_damp };
    b_scratch[b + 9] = .{ c.params.wall_tangent_damp, 0.0 };
}

comptime {
    k.installKernels(@This());
}

// CPU oracle for the counting sort. The CPU twin runs the REAL @atomicRmw, so
// this verifies the whole sort pipeline (count -> prefix -> scatter -> copyback)
// independent of the GPU: every particle must land in its own cell's contiguous
// range, the ranges must tile [0, N), and density computed over the sorted grid
// must match a brute-force O(N^2) density (the 3x3 of h-sized cells contains
// every neighbour within h).
test "counting sort: every particle in its cell range; density matches brute force" {
    const N: u32 = 2000;
    const h: f32 = interact_radius;
    const params: Params = .{
        .count = N,
        .dt = 1.0,
        .h = h,
        .r0 = 15.39,
        .k_far = 0.009,
        .k_near = 0.028,
        .gravity_y = 0.097,
        .visc_beta = 0.017,
        .mouse_x = 0,
        .mouse_y = 0,
        .mouse_force = 0,
        .mouse_radius = 90,
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
        // Distinctive per-particle encodings of pos so the post-sort check can
        // catch a scatter/copyback that desyncs the arrays (a zero-velocity
        // spawn would hide exactly that bug).
        g.B.vel[p] = .{ g.B.pos[p][0] * 0.5, g.B.pos[p][1] * 0.25 };
        g.B.prev[p] = .{ g.B.pos[p][0] + 7.0, g.B.pos[p][1] - 3.0 };
    }
    const cells: u32 = grid_cols * grid_rows;
    var cell: u32 = 0;
    while (cell < cells) : (cell += 1) {
        clearGrid(.{ .id = cell, .params = params });
    }
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        countGrid(.{ .id = i, .params = params });
    }
    prefixSum(.{ .id = 0, .params = params });
    i = 0;
    while (i < N) : (i += 1) {
        scatter(.{ .id = i, .params = params });
    }
    i = 0;
    while (i < N) : (i += 1) {
        copyback(.{ .id = i, .params = params });
    }
    // Sentinel == N, ranges tile [0, N) and each particle sits in its cell.
    try expectEqual(N, g.B.cell_start[cells]);
    var seen: u32 = 0;
    cell = 0;
    while (cell < cells) : (cell += 1) {
        const start: u32 = g.B.cell_start[cell];
        const end: u32 = g.B.cell_start[cell + 1];
        try expect(end >= start);
        var kk: u32 = start;
        while (kk < end) : (kk += 1) {
            try expectEqual(cell, cellOf(g.B.pos[kk], grid_cols, grid_rows, h));
            // pos/vel/prev must stay synced through the sort (same particle).
            try expectEqual(g.B.pos[kk][0] * 0.5, g.B.vel[kk][0]);
            try expectEqual(g.B.pos[kk][1] * 0.25, g.B.vel[kk][1]);
            try expectEqual(g.B.pos[kk][0] + 7.0, g.B.prev[kk][0]);
            try expectEqual(g.B.pos[kk][1] - 3.0, g.B.prev[kk][1]);
            seen += 1;
        }
    }
    try expectEqual(N, seen);
    // density over the sorted grid must equal brute force.
    i = 0;
    while (i < N) : (i += 1) {
        density(.{ .id = i, .params = params });
    }
    i = 0;
    while (i < N) : (i += 1) {
        var rho: f32 = 0;
        var rho_near: f32 = 0;
        var jj: u32 = 0;
        while (jj < N) : (jj += 1) {
            if (jj == i) {
                continue;
            }
            const sep: Vec2 = g.B.pos[jj] - g.B.pos[i];
            const d2: f32 = dot(sep, sep);
            if (d2 < h * h) {
                const dist: f32 = @sqrt(d2);
                const omq: f32 = 1.0 - dist / h;
                rho += omq * omq;
                rho_near += omq * omq * omq;
            }
        }
        try expectApproxEqAbs(rho, g.B.density[i][0], 1e-2);
        try expectApproxEqAbs(rho_near, g.B.density[i][1], 1e-2);
    }
}
