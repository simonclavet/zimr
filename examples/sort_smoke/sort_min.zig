//! The counting sort, stripped to nothing but the sort - no physics.
//!
//! Same five kernels as `fluid_sort`, same shapes, same control flow. Small enough that the
//! correct answer can be written down by hand, so `sort_smoke` can check every stage against
//! ground truth on BOTH backends. kompute runs this exact source as plain Zig on `.cpu` and
//! as SPIR-V->WGSL on `.gpu`, so a disagreement between them convicts the toolchain and an
//! agreement convicts the algorithm. Nothing else in the tree can make that distinction.
const k = @import("kompute");
const zm = @import("zm");

const Vec2 = zm.Vec2;
const float = zm.float;
const clamp = zm.clamp;

pub const config = k.Config{ .max = 4096, .workgroup = 64 };

/// A grid you can hold in your head: 8 x 4 cells of 100 units, over 800 x 400.
pub const n_particles: u32 = 64;
pub const cell_size: f32 = 100.0;
pub const n_cols: u32 = 8;
pub const n_rows: u32 = 4;
pub const n_cells: u32 = n_cols * n_rows; // 32

// A PLAIN struct with Vec2 fields, exactly as `sort_kernels` declares its buffers. (An
// `extern struct` would need `[N][2]f32`, and kompute's reshape to `[N]Vec2` is a pointer
// cast SPIR-V will not perform in the storage address space.)
pub const Buffers = struct {
    pos: [n_particles]Vec2,
    pos2: [n_particles]Vec2,
    /// Per-cell population. countGrid accumulates it; prefixSum zeroes it so scatter can
    /// reuse it as a per-cell cursor; scatter fills it back up to the counts.
    counts: [n_cells]u32,
    /// The exclusive prefix sum of `counts`, plus a total in the last slot.
    starts: [n_cells + 1]u32,
    /// The velocity change `sort_kernels.viscosity` applies. UNTESTED KERNEL #1: it is one of
    /// only two the fluid still runs that nothing has verified, and its inner loop carries a
    /// `continue` gated on a COMPUTED FLOAT (`if (u <= 0) continue`) - data-dependent control
    /// flow nested three loops deep, which nothing else in the module does.
    visc: [n_particles]Vec2,
    /// The position `sort_kernels.applyAndFinalize` produces. UNTESTED KERNEL #2 - and the
    /// last one standing. Branch-heavy: a soft wall band, a hard clamp with per-particle
    /// jitter (`i % 7`), directional wall damping, and a speed cap.
    applied: [n_particles]Vec2,
    /// (rho, rho_near) per particle - Clavet's double density, computed EXACTLY as
    /// `sort_kernels.density` does. The neighbour SET is already proven correct; this tests
    /// the ARITHMETIC over it, which nothing so far has.
    dens: [n_particles]Vec2,
    /// The pressure correction `corr` from `sort_kernels.force`. Density is proven exact on
    /// the GPU; this is the NEXT computation over the same (proven) neighbour set, and the
    /// CPU-vs-GPU fluid split says the fault lives in here, `viscosity`, or the integrator.
    corr: [n_particles]Vec2,
};

pub const Params = extern struct {
    count: u32,
    n_cols: u32,
    n_rows: u32,
    _pad: u32 = 0,
    h: f32,
    _pad1: f32 = 0,
    _pad2: f32 = 0,
    _pad3: f32 = 0,
};

pub const g = k.Globals(@This());

pub const kernels = [_][:0]const u8{
    "clearGrid",
    "countGrid",
    "prefixSum",
    "scatter",
    "copyback",
    "computeDensity",
    "computeForce",
    "computeVisc",
    "applyMini",
};

const b_pos = g.bind(.pos);
const b_pos2 = g.bind(.pos2);
const b_counts = g.bind(.counts);
const b_starts = g.bind(.starts);
const b_dens = g.bind(.dens);
const b_corr = g.bind(.corr);
const b_visc = g.bind(.visc);
const b_applied = g.bind(.applied);

/// floor(pos / h), clamped into the grid. The ONE definition of a particle's cell -
/// countGrid, scatter and any neighbour walk must all agree with it exactly.
fn cellOf(p: Vec2, cols: u32, rows: u32, h: f32) u32 {
    const max_cx: f32 = float(cols - 1);
    const max_cy: f32 = float(rows - 1);
    const cx: u32 = @trunc(clamp(@floor(p[0] / h), 0.0, max_cx));
    const cy: u32 = @trunc(clamp(@floor(p[1] / h), 0.0, max_cy));
    return cx + cy * cols;
}

pub fn clearGrid(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.n_cols * c.params.n_rows) {
        return;
    }
    k.atomicStore(b_counts, i, 0);
}

pub fn countGrid(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const cell: u32 = cellOf(b_pos[i], c.params.n_cols, c.params.n_rows, c.params.h);
    _ = k.atomicAdd(b_counts, cell, 1);
}

/// ONE invocation walks every cell. The only serial loop in the whole engine, and the one
/// the spv2wgsl phi bug used to break.
pub fn prefixSum(c: k.Ctx(@This())) void {
    if (c.id != 0) {
        return;
    }
    const cells: u32 = c.params.n_cols * c.params.n_rows;
    var acc: u32 = 0;
    var cell: u32 = 0;
    while (cell < cells) : (cell += 1) {
        const cnt: u32 = k.atomicLoad(b_counts, cell);
        b_starts[cell] = acc;
        acc += cnt;
        k.atomicStore(b_counts, cell, 0);
    }
    b_starts[cells] = acc;
}

pub fn scatter(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const cell: u32 = cellOf(b_pos[i], c.params.n_cols, c.params.n_rows, c.params.h);
    const slot: u32 = k.atomicAdd(b_counts, cell, 1);
    const dst: u32 = b_starts[cell] + slot;
    b_pos2[dst] = b_pos[i];
}

pub fn copyback(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    b_pos[i] = b_pos2[i];
}

/// Clavet's double density, byte for byte as `sort_kernels.density` computes it:
///
///     rho      += (1 - d/h)^2
///     rho_near += (1 - d/h)^3
///
/// The host computes the same sums by brute force in f64 and compares. If the neighbour set
/// is right (proven) but these numbers are wrong, the fault is in the FLOAT MATH of the
/// kernel - the one layer nothing has tested yet.
pub fn computeDensity(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const my_pos: Vec2 = b_pos[i];
    const h: f32 = c.params.h;
    var rho: f32 = 0.0;
    var rho_near: f32 = 0.0;

    const ccx: i32 = @floor(my_pos[0] / h);
    const ccy: i32 = @floor(my_pos[1] / h);
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
            const start: u32 = b_starts[cell];
            const end: u32 = b_starts[cell + 1];
            var kk: u32 = start;
            while (kk < end) : (kk += 1) {
                if (kk == i) {
                    continue;
                }
                const sep: Vec2 = b_pos[kk] - my_pos;
                const d2: f32 = sep[0] * sep[0] + sep[1] * sep[1];
                if (d2 < h * h) {
                    const dist: f32 = @sqrt(d2);
                    const omq: f32 = 1.0 - dist / h;
                    rho += omq * omq;
                    rho_near += omq * omq * omq;
                }
            }
        }
    }
    b_dens[i] = .{ rho, rho_near };
}

/// The pressure correction, byte for byte as `sort_kernels.force` computes it - including
/// the co-location fallback with its pseudo-random direction (`@cos`/`@sin` of a hashed
/// seed), which is the single most exotic thing any of these kernels does and therefore a
/// prime suspect for a transpiler bug.
pub fn computeForce(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const my_pos: Vec2 = b_pos[i];
    const h: f32 = c.params.h;
    const k_far: f32 = 0.009;
    const k_near: f32 = 0.028;
    const r0: f32 = 15.39;
    const my_d: Vec2 = b_dens[i];
    const my_press: f32 = k_far * (my_d[0] - r0);
    const my_near: f32 = k_near * my_d[1];
    var corr: Vec2 = .{ 0.0, 0.0 };

    const ccx: i32 = @floor(my_pos[0] / h);
    const ccy: i32 = @floor(my_pos[1] / h);
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
            const start: u32 = b_starts[cell];
            const end: u32 = b_starts[cell + 1];
            var kk: u32 = start;
            while (kk < end) : (kk += 1) {
                if (kk == i) {
                    continue;
                }
                const rel: Vec2 = b_pos[kk] - my_pos;
                const d2: f32 = rel[0] * rel[0] + rel[1] * rel[1];
                if (d2 >= h * h) {
                    continue;
                }
                const dist: f32 = @sqrt(d2);
                var dir: Vec2 = undefined;
                if (dist > 0.5) {
                    dir = rel * Vec2{ 1.0 / dist, 1.0 / dist };
                } else {
                    const seed: u32 = (i +% kk) *% 2654435761;
                    const ang: f32 = float(seed % 6283) * 0.001;
                    const sgn: f32 = if (i < kk) 1.0 else -1.0;
                    dir = .{ @cos(ang) * sgn, @sin(ang) * sgn };
                }
                const omq: f32 = 1.0 - dist / h;
                const jd: Vec2 = b_dens[kk];
                const j_press: f32 = k_far * (jd[0] - r0);
                const j_near: f32 = k_near * jd[1];
                const disp: f32 = 0.5 * ((my_press + j_press) * omq + (my_near + j_near) * omq * omq);
                corr = corr - dir * Vec2{ disp, disp };
            }
        }
    }
    b_corr[i] = corr;
}

/// A velocity that is a pure function of position, so the host reproduces it exactly.
fn fakeVel(p: Vec2) Vec2 {
    return .{ p[1] * 0.01 - 2.0, 1.0 - p[0] * 0.008 };
}

/// UNTESTED KERNEL #1 - `sort_kernels.viscosity`, byte for byte, over a synthetic velocity
/// field. Its inner loop hides a `continue` gated on a computed float, three loops deep.
pub fn computeVisc(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    const my_pos: Vec2 = b_pos[i];
    const h: f32 = c.params.h;
    const beta: f32 = 0.017;
    var my_vel: Vec2 = fakeVel(my_pos);

    const ccx: i32 = @floor(my_pos[0] / h);
    const ccy: i32 = @floor(my_pos[1] / h);
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
            const start: u32 = b_starts[cell];
            const end: u32 = b_starts[cell + 1];
            var kk: u32 = start;
            while (kk < end) : (kk += 1) {
                if (kk == i) {
                    continue;
                }
                const sep: Vec2 = b_pos[kk] - my_pos;
                const d2: f32 = sep[0] * sep[0] + sep[1] * sep[1];
                const dist: f32 = @sqrt(d2);
                if (dist >= h or dist <= 0.0001) {
                    continue;
                }
                const n: Vec2 = sep * Vec2{ 1.0 / dist, 1.0 / dist };
                const other: Vec2 = fakeVel(b_pos[kk]);
                const u: f32 = (my_vel[0] - other[0]) * n[0] + (my_vel[1] - other[1]) * n[1];
                if (u <= 0.0) {
                    continue;
                }
                const w: f32 = 1.0 - dist / h;
                const imp_raw: f32 = beta * w * u * u;
                const imp: f32 = if (imp_raw < u) imp_raw else u;
                my_vel = my_vel - n * Vec2{ imp * 0.5, imp * 0.5 };
            }
        }
    }
    b_visc[i] = my_vel;
}

/// UNTESTED KERNEL #2 - `sort_kernels.applyAndFinalize`'s POSITION path, byte for byte:
/// `pos + delta`, the soft wall band, the jittered hard clamp. `corr` stands in for delta
/// (computeForce already produced it) and `pos2` for prev (copyback made it equal to pos).
pub fn applyMini(c: k.Ctx(@This())) void {
    const i: u32 = c.id;
    if (i >= c.params.count) {
        return;
    }
    var p: Vec2 = b_pos[i] + b_corr[i];
    const dom_w: f32 = float(n_cols) * cell_size;
    const dom_h: f32 = float(n_rows) * cell_size;
    const band: f32 = c.params.h;
    const push: f32 = 0.25;
    if (p[0] < band) {
        p[0] += (band - p[0]) * push;
    } else if (p[0] > dom_w - band) {
        p[0] -= (p[0] - (dom_w - band)) * push;
    }
    if (p[1] < band) {
        p[1] += (band - p[1]) * push;
    } else if (p[1] > dom_h - band) {
        p[1] -= (p[1] - (dom_h - band)) * push;
    }
    const margin: f32 = 1.5;
    const jx: f32 = float(i % 7) * 0.4;
    const jy: f32 = float((i / 7) % 7) * 0.4;
    const lo_x: f32 = margin + jx;
    const hi_x: f32 = dom_w - margin - jx;
    const lo_y: f32 = margin + jy;
    const hi_y: f32 = dom_h - margin - jy;
    if (p[0] < lo_x) {
        p[0] = lo_x;
    } else if (p[0] > hi_x) {
        p[0] = hi_x;
    }
    if (p[1] < lo_y) {
        p[1] = lo_y;
    } else if (p[1] > hi_y) {
        p[1] = hi_y;
    }
    b_applied[i] = p;
}

comptime {
    k.installKernels(@This());
}
