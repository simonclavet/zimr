//! examples/sph_fluid_2d.zig — Particle-based viscoelastic fluid (2D port).
//!
//! Implementation of:
//!   Clavet, Beaudoin, Poulin (2005).  Particle-based Viscoelastic
//!   Fluid Simulation.  ACM SIGGRAPH/Eurographics Symposium on
//!   Computer Animation, pp. 219-228.
//!
//! 2D adaptation targeting WebGL2/wasm.  zimr has no compute
//! shaders (WebGL2 lacks them), so the entire simulation runs on
//! the CPU; the GPU only renders.  ~2000 particles at 60fps on
//! phones; desktop handles considerably more.  A WebGPU compute
//! version of the same algorithm at 20000 particles is what this
//! is a (slower, simpler) port of.
//!
//! The simulation step is one big paper-faithful function: each
//! algorithm block from the paper appears as a labelled section
//! with comments mapping back to the original equations.  Helper
//! functions exist only where they are genuinely reused (the
//! cell-sort grid rebuild, which runs twice per step).  The 3×3-
//! cell neighbour loop is inlined into all three places it appears
//! (viscosity, density, pressure) because each has a different
//! body and zero-callback overhead matters for the hot path.
//!
//! Paper map:
//!   §3   Simulation step (Algorithm 1)    — `step` outer flow
//!   §4   Double density relax (Alg. 2)    — `step`, Pass A/B/C
//!   §5.3 Viscosity (Algorithm 5)          — `step`, viscosity
//!   §6   Object interaction               — NOT IMPLEMENTED
//!   §5.1 Elasticity (springs)             — NOT IMPLEMENTED
//!   §5.2 Plasticity                       — NOT IMPLEMENTED
//!
//! Controls:
//!   Left-drag          : repel particles from the cursor
//!   Shift + left-drag  : attract particles to the cursor
//!   Sliders            : k (far stiffness), k_near, gravity,
//!                        viscosity
//!   Reset button       : dam-break initial configuration

const std = @import("std");
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const clamp = zm.clamp;
const float = zm.float;
const vec3 = zm.vec3;
const assert = zm.assert;
const z = @import("zimr");
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// --- Constants -----------------------------------------------------
//
// Tunables.  The values come from the paper's "typical" set (§7.3)
// adapted to a smaller canvas:
//   h = 22 px        (interaction radius)
//   rho_0 = 10       (rest density, dimensionless)
//   k = 0.004        (far-pressure stiffness)
//   k_near = 0.010   (near-pressure stiffness)
//   sigma = 0        (linear viscosity — disabled)
//   beta = 0.10      (quadratic viscosity coefficient)
// Time unit is 1 step = 1/60 second (one rendered frame).  We run
// `substeps` iterations of the algorithm per rendered frame to
// improve temporal resolution; visual frame rate is unchanged.

const screen_w: f32 = 800;
const screen_h: f32 = 450;
const num_particles: u32 = 2000;
const interact_radius: f32 = 22.0;
const render_radius: f32 = 4.5;
const substeps: u32 = 2;
const rest_rho: f32 = 10.0;
/// Maximum particle speed in pixels per substep.  A hard cap that
/// prevents instability if `k` is set high enough to overshoot
/// boundaries.  Sliding the speed back down preserves direction
/// but silently breaks momentum conservation — band-aid, not a
/// feature.
const max_speed: f32 = 40.0;
const mouse_radius: f32 = 90.0;
const mouse_force_mag: f32 = 0.8;

// Spatial grid: cell size = interaction radius.  +2 border pads
// the edges so a particle right on the boundary still has a valid
// cell (the algorithm's 3×3 neighbour walk would otherwise OOB).
const grid_cols: u32 = @trunc(@ceil(screen_w / interact_radius) + 2);
const grid_rows: u32 = @trunc(@ceil(screen_h / interact_radius) + 2);
const grid_cells: u32 = grid_cols * grid_rows;

// --- State --------------------------------------------------------

const State = struct {
    // Particle data, struct-of-arrays.  Each array is
    // num_particles long, allocated once at init, never resized.
    // SoA chosen because every algorithm pass touches either
    // positions+velocities OR densities+positions — the access
    // pattern is component-major.
    positions: []Vec2,
    prev_positions: []Vec2,
    velocities: []Vec2,
    /// `.x` = rho (linear-spike density), `.y` = rho_near (cubic-
    /// spike near-density).  Stored together because the pressure
    /// pass reads both fields per neighbour — paired access wins
    /// cache lines.
    densities: []Vec2,
    /// Pressure-pass output, applied as a separate sweep so all
    /// reads in the force computation see the same predicted
    /// positions (no order-dependent drift between particles
    /// updated early and late).
    pos_deltas: []Vec2,
    /// Viscosity-pass output.  Same rationale as `pos_deltas`:
    /// the gather is over PAIRS, and serial mutation of velocities
    /// during the gather would let particle i+1 read an already-
    /// damped v[i].  The dam-break spawn correlates index with
    /// position (low = upper-left, high = lower-right), so the
    /// order dependency manifested as a visible asymmetric damping
    /// — rightward-sloshing particles damped less than leftward
    /// ones, producing a persistent rightward bias.  Two-pass
    /// gather + apply fixes that.
    visc_deltas: []Vec2,

    // Spatial hash grid in CSR (compressed sparse row) layout.
    //
    //   grid_starts[c]   = first slot in grid_indices for cell c
    //   grid_starts[c+1] = one past last slot for cell c
    //   grid_indices[k]  = particle index, for k in
    //                      [starts[c], starts[c+1])
    //
    // Constructed each substep by bucket-count → exclusive prefix
    // sum → scatter.  No MAX_PER_CELL cap (cells can hold any
    // number of particles).  Faster than the WebGPU version's
    // atomic-append for hot cells because no contention.
    grid_starts: []u32,
    grid_indices: []u32,
    /// Scratch cursor used during scatter.  Initialized from
    /// `grid_starts` then bumped per write.  Lives in State to
    /// avoid per-frame alloc.
    grid_cursor: []u32,
    /// Cached cell index per particle.  Computed during
    /// `rebuildGrid` and reused by all three neighbour passes —
    /// saves recomputing `x/h, y/h` ~25× per particle per substep.
    grid_cell_of_particle: []u32,

    // Simulation parameters — exposed via ImGui sliders.
    k_far: f32 = 0.004,
    k_near: f32 = 0.010,
    gravity_y: f32 = 0.05,
    visc_beta: f32 = 0.10,

    // Mouse interaction state.
    mouse_pos: Vec2 = .{ 0, 0 },
    mouse_force_active: bool = false,
    mouse_attract: bool = false,

    // Render scratch.
    ui_host: z.UiHost,
    font: z.Font,
};

// --- App bridge ---------------------------------------------------

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.ui_host.deinit();
}

// --- Init ---------------------------------------------------------

/// Dam-break initial configuration.  Fills a rectangular block in
/// the left ~52% of the canvas with deterministic sub-pixel jitter
/// to break exact co-location.
///
/// num_particles must factor as cols*rows exactly — using cols
/// computed from a sqrt + ceil produces a partial bottom row, and
/// the missing slots on one side give the dam a slight mass
/// imbalance that biases the post-release flow.  We choose
/// 50 × 40 = 2000 so the block is perfectly rectangular.
fn resetParticles(s: *State) void {
    const cols: u32 = 50;
    const rows: u32 = num_particles / cols; // = 40, exact
    comptime {
        assert(cols * rows == num_particles, @src());
    }
    const fill_w: f32 = screen_w * 0.52;
    const fill_h: f32 = screen_h * 0.92;
    const cols_f: f32 = float(cols);
    const rows_f: f32 = float(rows);
    const spacing_x: f32 = fill_w / cols_f;
    const spacing_y: f32 = fill_h / rows_f;

    var prng: std.Random.DefaultPrng = .init(0x5EED);
    const rng: std.Random = prng.random();

    for (s.positions, 0..) |*p, i| {
        const col: u32 = @as(u32, @intCast(i)) % cols;
        const row: u32 = @as(u32, @intCast(i)) / cols;
        const jx: f32 = (rng.float(f32) - 0.5) * 0.6;
        const jy: f32 = (rng.float(f32) - 0.5) * 0.6;
        p.* = .{
            6.0 + (float(col) + 0.5) * spacing_x + jx,
            6.0 + (float(row) + 0.5) * spacing_y + jy,
        };
    }
    @memset(s.velocities, .{ 0, 0 });
}

fn initState(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const n: u32 = num_particles;
    s.* = .{
        .positions = try gpa.alloc(Vec2, n),
        .prev_positions = try gpa.alloc(Vec2, n),
        .velocities = try gpa.alloc(Vec2, n),
        .densities = try gpa.alloc(Vec2, n),
        .pos_deltas = try gpa.alloc(Vec2, n),
        .visc_deltas = try gpa.alloc(Vec2, n),
        .grid_starts = try gpa.alloc(u32, grid_cells + 1),
        .grid_indices = try gpa.alloc(u32, n),
        .grid_cursor = try gpa.alloc(u32, grid_cells),
        .grid_cell_of_particle = try gpa.alloc(u32, n),
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
    };
    // Zero everything that the simulation step doesn't initialize
    // before reading.  `resetParticles` handles positions /
    // prev_positions / velocities; the rest gets touched by
    // `step()`'s first invocation in a write-then-read order — BUT
    // in ReleaseSafe (which smoke uses) Zig fills `gpa.alloc`
    // memory with the 0xAAAAAAAA undefined-sentinel, and any
    // read-before-write inside step() would trap on
    // `index 2863311530, len 2000`.  In ReleaseSmall (production)
    // the same memory is uninitialized garbage but doesn't trap,
    // making the bug invisible.  Belt-and-suspenders here means
    // the example works under both modes without depending on
    // step()'s internal ordering being airtight.
    @memset(s.densities, .{ 0, 0 });
    @memset(s.pos_deltas, .{ 0, 0 });
    @memset(s.visc_deltas, .{ 0, 0 });
    @memset(s.grid_starts, 0);
    @memset(s.grid_indices, 0);
    @memset(s.grid_cursor, 0);
    @memset(s.grid_cell_of_particle, 0);
    resetParticles(s);
}

// --- Per-frame update ---------------------------------------------

/// Bucket-sort all particles into the spatial hash grid.
///
/// Three passes:
///   1. Count: bucket per cell + cache cell-of-particle.
///   2. Exclusive prefix sum: turn counts into CSR start offsets.
///   3. Scatter: walk particles, write into grid_indices using a
///      per-cell cursor.
///
/// After this returns, the algorithm-side invariants are:
///   - `grid_cell_of_particle[i]` = cell index containing particle i
///   - `grid_starts[c] ≤ grid_starts[c+1]`, and particles in cell c
///     occupy slots `[grid_starts[c], grid_starts[c+1])` in
///     `grid_indices`
fn rebuildGrid(s: *State) void {
    const inv_h: f32 = 1.0 / interact_radius;
    const cols_i32: i32 = @intCast(grid_cols);
    const rows_i32: i32 = @intCast(grid_rows);

    // 1. Count.  We zero `grid_starts[0 .. grid_cells+1]` then
    //    write counts into `grid_starts[c + 1]` — leaves slot 0
    //    at zero, which is exactly what we want for the prefix
    //    sum below.
    @memset(s.grid_starts, 0);
    for (s.positions, 0..) |p, i| {
        var cx: i32 = @floor(p[0] * inv_h);
        var cy: i32 = @floor(p[1] * inv_h);
        if (cx < 0) {
            cx = 0;
        }
        if (cy < 0) {
            cy = 0;
        }
        if (cx >= cols_i32) {
            cx = cols_i32 - 1;
        }
        if (cy >= rows_i32) {
            cy = rows_i32 - 1;
        }
        const cell: u32 = @intCast(cx + cy * cols_i32);
        s.grid_cell_of_particle[i] = cell;
        s.grid_starts[cell + 1] += 1;
    }

    // 2. Exclusive prefix sum.  After this loop `grid_starts[c]`
    //    is the start slot for cell c, and `grid_starts[c+1]` is
    //    its end (= next cell's start).  The
    //    `grid_starts[grid_cells]` sentinel equals num_particles.
    var sum: u32 = 0;
    for (s.grid_starts) |*x| {
        const v: u32 = x.*;
        x.* = sum;
        sum += v;
    }

    // 3. Scatter.  Copy starts into a cursor; for each particle
    //    write its index at cursor[cell] and advance the cursor.
    @memcpy(s.grid_cursor, s.grid_starts[0..grid_cells]);
    for (s.grid_cell_of_particle, 0..) |cell, i| {
        const slot: u32 = s.grid_cursor[cell];
        s.grid_cursor[cell] += 1;
        s.grid_indices[slot] = @intCast(i);
    }
}

/// One substep of the Clavet 2005 algorithm.  Algorithm 1 in the
/// paper.  Reads top-to-bottom; each labelled block corresponds to
/// a paper section.  No helper functions for the neighbour loop
/// because each pass has a different body and inlining matters at
/// 2000 particles × 2 substeps × 60 fps × ~9 neighbours = ~2M
/// inner-body iterations per second.
fn step(s: *State) void {
    const dt: f32 = 1.0;
    const h: f32 = interact_radius;
    const inv_h: f32 = 1.0 / h;
    const h_sq: f32 = h * h;
    const k: f32 = s.k_far;
    const k_near: f32 = s.k_near;
    const beta: f32 = s.visc_beta;
    const cols_i32: i32 = @intCast(grid_cols);
    const rows_i32: i32 = @intCast(grid_rows);

    // ================================================================
    // Algorithm 1, lines 1-5 — apply gravity + mouse force.
    //
    // Gravity adds a constant impulse to vy each step.  The mouse
    // adds a radial impulse with linear falloff: maximum strength
    // at the cursor, fading to zero at mouse_radius.  Attract mode
    // just negates the sign.
    // ================================================================
    {
        const grav_imp: Vec2 = .{ 0, s.gravity_y * dt };
        const mouse_force: f32 = blk: {
            if (!s.mouse_force_active) {
                break :blk 0.0;
            }
            break :blk if (s.mouse_attract)
                -mouse_force_mag
            else
                mouse_force_mag;
        };
        const mouse_radius_sq: f32 = mouse_radius * mouse_radius;
        const m_pos: Vec2 = s.mouse_pos;

        for (s.velocities, s.positions) |*v, p| {
            v.* += grav_imp;
            if (mouse_force == 0) {
                continue;
            }
            const to_part: Vec2 = p - m_pos;
            const dist_sq: f32 = to_part[0] * to_part[0] +
                to_part[1] * to_part[1];
            if (dist_sq < 0.25 or dist_sq >= mouse_radius_sq) {
                continue;
            }
            const dist: f32 = @sqrt(dist_sq);
            const falloff: f32 = 1.0 - dist / mouse_radius;
            const scale: f32 = mouse_force * falloff / dist;
            v.* += to_part * @as(Vec2, @splat(scale));
        }
    }

    // ================================================================
    // Grid rebuild #1 — on CURRENT positions.  Viscosity needs to
    // find neighbours at the particles' actual positions (not yet
    // predicted).
    // ================================================================
    rebuildGrid(s);

    // ================================================================
    // Algorithm 5 — viscosity damping.
    //
    // For each pair (i, j) closer than h with positive inward
    // radial velocity, apply an impulse along the connecting line
    // that damps the relative motion:
    //
    //   u = (v_i - v_j) · r̂        (positive if approaching)
    //   I = dt · (1 - q) · β · u²   (paper β term; σ omitted)
    //   v_i -= I·r̂ / 2,   v_j += I·r̂ / 2
    //
    // Paper applies impulses in an ordered-pair scatter (each pair
    // touched once).  We use a symmetric gather: each particle
    // reads all its neighbours' velocities and accumulates its
    // half-impulse.
    //
    // The gather MUST be over a velocity snapshot — if we mutated
    // s.velocities[i] in place during the loop, later particles
    // would read already-damped neighbour velocities and damp less.
    // Since dam-break index correlates with position, that
    // asymmetry biases the fluid rightward.  Hence two passes:
    // gather into visc_deltas (read-only on velocities), then
    // apply.  Same pattern as the pressure pass below.
    // ================================================================
    for (s.positions, s.velocities, s.visc_deltas, 0..) |
        p_i,
        v_i,
        *visc_out,
        i_usize,
    | {
        const i: u32 = @intCast(i_usize);
        var accum: Vec2 = .{ 0, 0 };

        const cell_i: u32 = s.grid_cell_of_particle[i];
        const cx: i32 = @intCast(cell_i % grid_cols);
        const cy: i32 = @intCast(cell_i / grid_cols);

        // 3×3-cell neighbourhood walk.  Same pattern in density
        // and pressure passes below.
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx: i32 = cx + dx;
                const ny: i32 = cy + dy;
                if (nx < 0 or ny < 0 or nx >= cols_i32 or ny >= rows_i32) {
                    continue;
                }
                const ncell: u32 = @intCast(nx + ny * cols_i32);
                const start: u32 = s.grid_starts[ncell];
                const end: u32 = s.grid_starts[ncell + 1];

                var slot: u32 = start;
                while (slot < end) : (slot += 1) {
                    const j: u32 = s.grid_indices[slot];
                    if (j == i) {
                        continue;
                    }

                    const r: Vec2 = s.positions[j] - p_i;
                    const r_sq: f32 = r[0] * r[0] + r[1] * r[1];
                    // Only skip exact co-location (numerical NaN
                    // guard).  Threshold lowered from 0.01 → 0.0001
                    // — anything past r ≈ 0.01 px gives a sane r̂.
                    if (r_sq >= h_sq or r_sq < 0.0001) {
                        continue;
                    }

                    const r_dist: f32 = @sqrt(r_sq);
                    const inv_r: f32 = 1.0 / r_dist;
                    const r_hat: Vec2 = r * @as(Vec2, @splat(inv_r));
                    const q: f32 = r_dist * inv_h;
                    const dv: Vec2 = v_i - s.velocities[j];
                    const u_radial: f32 = dv[0] * r_hat[0] + dv[1] * r_hat[1];

                    // Linear drag, applied to ALL pairs — approaching
                    // AND separating, not just u > 0 as the paper does.
                    //
                    // Why linear instead of paper's β·u²:
                    //   Quadratic scaling kills slow-motion damping.
                    //   For bulk creep at u ≈ 1 with β = 0.10, the
                    //   impulse is 0.05 — essentially zero.  That's
                    //   why the rightward drift would never settle:
                    //   no part of our viscosity model opposed it.
                    //   Linear (σ·u) gives uniform drag regardless of
                    //   speed, which is what damps bulk flow.
                    //
                    // Why both directions (no u > 0 gate):
                    //   Real viscous drag opposes relative motion in
                    //   either direction.  Paper gates by u > 0
                    //   ("only when running into each other") to
                    //   preserve explosion energy in collisions — but
                    //   our problem is the opposite, fluid that
                    //   refuses to settle.  Damping separation too
                    //   makes the simulation actually equilibriate.
                    //
                    // Momentum still conserves exactly: u is symmetric
                    // in i↔j (dv flips sign, r̂ flips sign, sign-of-
                    // product is invariant), so mag is identical for
                    // both processings, and the equal-and-opposite r̂
                    // gives equal-and-opposite half-impulses.
                    const i_mag: f32 =
                        dt * (1.0 - q) * beta * u_radial * 0.5;
                    accum -= r_hat * @as(Vec2, @splat(i_mag));
                }
            }
        }
        visc_out.* = accum;
    }
    // Apply viscosity deltas (sweep over velocities only).
    for (s.velocities, s.visc_deltas) |*v, dv| {
        v.* += dv;
    }

    // ================================================================
    // Algorithm 1, lines 6-10 — predict + boundary contact.
    //
    // Save current pos, then move particles forward by v·dt.  The
    // double-density relaxation below operates on PREDICTED
    // positions; velocity is recovered at the end of the substep
    // as (new_pos - prev_pos) / dt, so any positional edits in
    // between (pressure, boundary) automatically become velocity
    // changes.  This is the paper's prediction-relaxation trick.
    //
    // Boundary contact is resolved HERE, not after pressure
    // relaxation.  Two reasons:
    //
    //   1. If we only clamped after relaxation, a particle whose
    //      predicted pos lies outside the domain would still
    //      contribute to pressure as if it were 5 px through the
    //      wall — neighbour density on the wall side is wrong.
    //      Catching it at predict keeps the predicted layout
    //      physically valid.
    //
    //   2. The wall must absorb momentum, not amplify it, AND it
    //      must not pile particles into a single-row-thick stack.
    //      An earlier version teleported penetrating particles
    //      TO the wall margin — but that compressed every wall
    //      contact into the same y-line (or x-line), spiking
    //      neighbour density there and launching adjacent
    //      particles as a fountain on the next pressure pass.
    //
    //      Fix: when an axis penetrates, the particle simply
    //      doesn't move on that axis this substep.  Position
    //      stays at the start-of-substep value, velocity
    //      component on that axis is zeroed.  Wall absorbs the
    //      motion cleanly without concentrating density.  This
    //      is the user-pointed approach: "if pred pos penetrates,
    //      zero penetrating vel and put it back at prev pos".
    //
    // Local v_local copy avoids depending on whether Zig emits
    // correct code for `ptr_to_vector.*[component] = value`; the
    // boring read-modify-write through a stack copy is
    // unambiguous.
    // ================================================================
    {
        const margin_lo: Vec2 = .{ 1.5, 1.5 };
        const margin_hi: Vec2 = .{ screen_w - 1.5, screen_h - 1.5 };
        for (s.positions, s.prev_positions, s.velocities) |*p, *pp, *v| {
            const p_start: Vec2 = p.*;
            var v_local: Vec2 = v.*;
            var predicted: Vec2 = p_start + v_local * @as(Vec2, @splat(dt));
            if (predicted[0] < margin_lo[0] or predicted[0] > margin_hi[0]) {
                predicted[0] = p_start[0];
                v_local[0] = 0;
            }
            if (predicted[1] < margin_lo[1] or predicted[1] > margin_hi[1]) {
                predicted[1] = p_start[1];
                v_local[1] = 0;
            }
            pp.* = p_start;
            p.* = predicted;
            v.* = v_local;
        }
    }

    // ================================================================
    // Grid rebuild #2 — on PREDICTED positions.  Density and
    // pressure both use the same predicted layout, so one rebuild
    // covers both.
    // ================================================================
    rebuildGrid(s);

    // ================================================================
    // Algorithm 2 — double density relaxation.
    //
    // PASS A: density.  For each particle i, sum two kernels over
    // neighbours:
    //   rho_i      = Σⱼ (1 - r_ij/h)²    (linear-spike, eq. 1)
    //   rho_near_i = Σⱼ (1 - r_ij/h)³    (sharp cubic, eq. 4)
    // The sharper near-density kernel reacts only to very-close
    // pairs, which gives the algorithm its anti-clustering
    // property (paper §4.3).
    // ================================================================
    for (s.densities, s.positions, 0..) |*d, p_i, i_usize| {
        const i: u32 = @intCast(i_usize);
        var rho: f32 = 0;
        var rho_near: f32 = 0;

        const cell_i: u32 = s.grid_cell_of_particle[i];
        const cx: i32 = @intCast(cell_i % grid_cols);
        const cy: i32 = @intCast(cell_i / grid_cols);

        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx: i32 = cx + dx;
                const ny: i32 = cy + dy;
                if (nx < 0 or ny < 0 or nx >= cols_i32 or ny >= rows_i32) {
                    continue;
                }
                const ncell: u32 = @intCast(nx + ny * cols_i32);
                const start: u32 = s.grid_starts[ncell];
                const end: u32 = s.grid_starts[ncell + 1];

                var slot: u32 = start;
                while (slot < end) : (slot += 1) {
                    const j: u32 = s.grid_indices[slot];
                    if (j == i) {
                        continue;
                    }

                    const r: Vec2 = s.positions[j] - p_i;
                    const r_sq: f32 = r[0] * r[0] + r[1] * r[1];
                    if (r_sq >= h_sq) {
                        continue;
                    }

                    const one_minus_q: f32 = 1.0 - @sqrt(r_sq) * inv_h;
                    const omq_sq: f32 = one_minus_q * one_minus_q;
                    rho += omq_sq;
                    rho_near += omq_sq * one_minus_q;
                }
            }
        }
        d.* = .{ rho, rho_near };
    }

    // ================================================================
    // Algorithm 2 — PASS B: compute pressure displacements.
    //
    //   P_i      = k * (rho_i - rho_0)     (signed, paper eq. 2)
    //   P_near_i = k_near * rho_near_i     (always positive, eq. 5)
    //   Δr_ij    = dt² · (P · (1-q) + P_near · (1-q)²) · r̂
    //
    // Surface tension emerges from P being NEGATIVE at the fluid
    // surface (rho < rho_0): the linear-kernel term pulls
    // neighbours closer, but the sharp-spike near-pressure term
    // still repels at very short range — net effect is a smooth
    // surface with stable drops and filaments (paper §4.4).
    //
    // Paper uses asymmetric scatter (each pair touched once).
    // We use symmetric gather: each particle reads its OWN and its
    // NEIGHBOUR's pressures, applying half the pair force.  The
    // 0.5 factor below compensates for the double-count.
    //
    // Co-location: when r ≈ 0 the normalised direction is
    // undefined.  We pick a deterministic antisymmetric cardinal
    // so the pair separates (smaller index goes -x, larger goes
    // +x).  Init jitter makes this rare in practice but it's free
    // insurance.
    // ================================================================
    const dt_sq: f32 = dt * dt;
    for (
        s.pos_deltas,
        s.positions,
        s.densities,
        0..,
    ) |*delta_i, p_i, dens_i, i_usize| {
        const i: u32 = @intCast(i_usize);
        const big_p_i: f32 = k * (dens_i[0] - rest_rho);
        const big_pn_i: f32 = k_near * dens_i[1];

        var accum: Vec2 = .{ 0, 0 };

        const cell_i: u32 = s.grid_cell_of_particle[i];
        const cx: i32 = @intCast(cell_i % grid_cols);
        const cy: i32 = @intCast(cell_i / grid_cols);

        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const nx: i32 = cx + dx;
                const ny: i32 = cy + dy;
                if (nx < 0 or ny < 0 or nx >= cols_i32 or ny >= rows_i32) {
                    continue;
                }
                const ncell: u32 = @intCast(nx + ny * cols_i32);
                const start: u32 = s.grid_starts[ncell];
                const end: u32 = s.grid_starts[ncell + 1];

                var slot: u32 = start;
                while (slot < end) : (slot += 1) {
                    const j: u32 = s.grid_indices[slot];
                    if (j == i) {
                        continue;
                    }

                    const r: Vec2 = s.positions[j] - p_i;
                    const r_sq: f32 = r[0] * r[0] + r[1] * r[1];
                    if (r_sq >= h_sq) {
                        continue;
                    }

                    var r_hat: Vec2 = undefined;
                    var r_dist: f32 = undefined;
                    if (r_sq > 0.25) {
                        r_dist = @sqrt(r_sq);
                        r_hat = r * @as(Vec2, @splat(1.0 / r_dist));
                    } else {
                        // Co-location fallback: r ≈ 0 → r̂ undefined.
                        // 1D x-only would force all of a corner-clamped
                        // stack's pressure into ±x and rocket the
                        // extreme-indexed particles out.  Fan across 4
                        // cardinals using a deterministic hash of the
                        // pair: (i+j)&3 picks the axis, i<j flips the
                        // sign so the pair separates antisymmetrically
                        // (action-reaction is preserved when particle j
                        // processes this same pair).
                        const axis: u32 = (i +% j) & 3;
                        const sign: f32 = if (i < j) -1.0 else 1.0;
                        r_hat = switch (axis) {
                            0 => .{ sign, 0 },
                            1 => .{ 0, sign },
                            2 => .{ -sign, 0 },
                            else => .{ 0, -sign },
                        };
                        r_dist = 0.5;
                    }

                    const q: f32 = r_dist * inv_h;
                    const one_minus_q: f32 = 1.0 - q;
                    const dens_j: Vec2 = s.densities[j];
                    const big_p_j: f32 = k * (dens_j[0] - rest_rho);
                    const big_pn_j: f32 = k_near * dens_j[1];

                    // Symmetric gather × 0.5 matches paper scatter total.
                    const mag: f32 = 0.5 * dt_sq *
                        ((big_p_i + big_p_j) * one_minus_q +
                            (big_pn_i + big_pn_j) * one_minus_q * one_minus_q);

                    // r_hat points FROM i TO j; pressure pushes i
                    // away → subtract.
                    accum -= r_hat * @as(Vec2, @splat(mag));
                }
            }
        }
        // Note: no per-particle displacement cap.  An earlier
        // version had one, but it breaks pair-momentum
        // conservation — when accum exceeds the cap, the per-
        // particle scaling shrinks one side of every pair this
        // particle participates in, while its pair partners
        // (typically less dense, not capped) keep their full
        // contribution.  Repeated over a pile's many pairs, the
        // asymmetry pumps net momentum into surface particles
        // and launches them as a fountain.  Co-location NaNs
        // (the original reason for the cap) are handled cleanly
        // by spawn jitter + the 4-cardinal r̂ fallback above.
        delta_i.* = accum;
    }

    // PASS C: apply deltas.  Separated from B so all reads in B
    // saw consistent predicted positions; if we'd folded apply
    // into B, particles processed later would have read partially-
    // updated positions from particles processed earlier, biasing
    // the result by processing order.
    for (s.positions, s.pos_deltas) |*p, dp| {
        p.* += dp;
    }

    // ================================================================
    // Algorithm 1, lines 18-20 — boundary clamp + velocity recompute.
    //
    // Clamp positions inside the domain (small margin so render
    // circles don't intersect the edge), then recover velocity as
    // (new_pos - prev_pos) / dt.  This is the prediction-
    // relaxation payoff: every positional edit from pressure,
    // boundary, etc. automatically becomes a velocity change
    // without explicit force integration.
    //
    // ================================================================
    // Final boundary clamp + velocity recompute.
    //
    // Defensive backstop for the rare case where pressure on its
    // own pushed a particle outside the domain (predict-clamp
    // already handles the velocity-driven case).  When firing,
    // clamp to the wall and zero the velocity component on that
    // axis — same inelastic-wall response as the predict clamp.
    //
    // Speed cap is a remaining band-aid for high-stiffness
    // setups; breaks momentum conservation when triggered but is
    // strictly better than letting particles tunnel out of the
    // domain at max_speed-exceeding velocity.
    // ================================================================
    const margin_lo: Vec2 = .{ 1.5, 1.5 };
    const margin_hi: Vec2 = .{ screen_w - 1.5, screen_h - 1.5 };
    const max_speed_sq: f32 = max_speed * max_speed;
    const inv_dt: f32 = 1.0 / dt;
    for (s.positions, s.prev_positions, s.velocities) |*p, pp, *v| {
        var p_local: Vec2 = p.*;
        var new_v: Vec2 = (p_local - pp) * @as(Vec2, @splat(inv_dt));
        if (p_local[0] < margin_lo[0]) {
            p_local[0] = margin_lo[0];
            new_v[0] = 0;
        } else if (p_local[0] > margin_hi[0]) {
            p_local[0] = margin_hi[0];
            new_v[0] = 0;
        }
        if (p_local[1] < margin_lo[1]) {
            p_local[1] = margin_lo[1];
            new_v[1] = 0;
        } else if (p_local[1] > margin_hi[1]) {
            p_local[1] = margin_hi[1];
            new_v[1] = 0;
        }
        const speed_sq: f32 = new_v[0] * new_v[0] + new_v[1] * new_v[1];
        if (speed_sq > max_speed_sq) {
            const scale: f32 = max_speed / @sqrt(speed_sq);
            new_v *= @as(Vec2, @splat(scale));
        }
        p.* = p_local;
        v.* = new_v;
    }
}

/// Map normalized density `t ∈ [0,1]` to a 3-stop blue→cyan→white
/// gradient that highlights surface (low density) and interior
/// (high) regions.  Matches the WGSL fragment shader from the
/// WebGPU version of this demo.
fn densityToColor(t: f32) Color {
    const lo: Vec3 = vec3(0.02, 0.15, 0.70);
    const mid: Vec3 = vec3(0.05, 0.65, 1.00);
    const hi: Vec3 = vec3(0.80, 0.95, 1.00);
    const c: Vec3 = if (t < 0.5) blk: {
        const u: f32 = t * 2.0;
        break :blk vec3(
            lo[0] + (mid[0] - lo[0]) * u,
            lo[1] + (mid[1] - lo[1]) * u,
            lo[2] + (mid[2] - lo[2]) * u,
        );
    } else blk: {
        const u: f32 = (t - 0.5) * 2.0;
        break :blk vec3(
            mid[0] + (hi[0] - mid[0]) * u,
            mid[1] + (hi[1] - mid[1]) * u,
            mid[2] + (hi[2] - mid[2]) * u,
        );
    };
    return .{
        .r = @trunc(c[0] * 255.0),
        .g = @trunc(c[1] * 255.0),
        .b = @trunc(c[2] * 255.0),
        .a = 255,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // Mouse state for this frame.  Capture before the substep loop
    // so all substeps see the same input (no intra-frame drift).
    s.mouse_pos = z.getMousePosition(f.input);
    s.mouse_force_active = z.isMouseButtonDown(f.input, .left);
    s.mouse_attract = z.isKeyDown(f.input, .left_shift) or
        z.isKeyDown(f.input, .right_shift);

    // Run the simulation.  Multiple substeps per rendered frame
    // improves temporal resolution under high stiffness without
    // increasing visible frame rate.
    var i: u32 = 0;
    while (i < substeps) : (i += 1) {
        step(s);
    }

    // --- Render -----------------------------------------------------

    z.clearViewport(f, .{ .r = 1, .g = 3, .b = 8, .a = 255 });

    // Density-coloured particles.  Color stops match the WGSL
    // fragment shader from the WebGPU version:
    //   low density  (surface)  → deep blue
    //   rest density            → cyan
    //   high density (interior) → near-white
    const inv_max_density: f32 = 1.0 / 15.0; // rest_rho * 1.5
    for (s.positions, s.densities) |p, d| {
        const t: f32 = clamp(d[0] * inv_max_density, 0.0, 1.0);
        const col: Color = densityToColor(t);
        f.gl.circle(p, render_radius, .{ .color = col, .segments = 16 });
    }

    // --- ImGui control panel ----------------------------------------
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    if (u.window("controls", .{ .initial_pos = .{ 12, 12 } })) |w| {
        defer w.close();
        u.text("{d} particles, {d} substep(s)/frame", .{
            num_particles,
            substeps,
        });
        u.text("fps {d:.0}", .{1.0 / f.time.delta_time});
        _ = u.slider("k (far)", &s.k_far, .{
            .min = 0,
            .max = 0.02,
            .fmt = "{d:.4}",
        });
        _ = u.slider("k_near", &s.k_near, .{
            .min = 0,
            .max = 0.05,
            .fmt = "{d:.4}",
        });
        _ = u.slider("gravity", &s.gravity_y, .{
            .min = 0,
            .max = 0.3,
        });
        _ = u.slider("viscosity β", &s.visc_beta, .{
            .min = 0,
            .max = 0.5,
        });
        if (u.button("reset", .{})) {
            resetParticles(s);
        }
        u.text("left-drag: push    shift+drag: pull", .{});
    }
    s.ui_host.render(f);
}

// --- Simulation step (the heart) -----------------------------------

// --- Spatial grid rebuild ------------------------------------------

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "SPH viscoelastic fluid — Clavet 2005",
            .width = @trunc(screen_w),
            .height = @trunc(screen_h),
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
