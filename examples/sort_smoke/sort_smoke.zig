//! sort_smoke — does the counting sort actually sort?
//!
//! `fluid_sort` renders a fluid that will not settle and whose particles lock into rows. Every
//! kernel READS correctly, so the argument has been going in circles. This example stops
//! arguing: it runs the same five kernels over 64 particles whose right answer can be worked
//! out by hand, and it CHECKS each stage.
//!
//! It does it twice. kompute compiles one kernel source for two targets — plain Zig on `.cpu`,
//! SPIR-V→WGSL on `.gpu` — so:
//!
//!   * CPU passes, GPU fails  ->  the toolchain (transpiler or driver) is wrong.
//!   * both fail the same way ->  the ALGORITHM is wrong, and no transpiler fix will save it.
//!   * both pass              ->  the sort is sound and the fluid bug is somewhere else.
//!
//! No other test in the tree can separate those three.
const std = @import("std");
const z = @import("zimr");
const sm = @import("sort_min.zig");
const zm = @import("zm");

const Pipe = z.Compute(sm);
/// Each kernel's transpiled WGSL, embedded by the build. Mirrors `fluid_sort`.
const kernel_wgsls: [sm.kernels.len]Pipe.KernelWgsl = blk: {
    var arr: [sm.kernels.len]Pipe.KernelWgsl = undefined;
    for (sm.kernels, 0..) |name, i| {
        arr[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    break :blk arr;
};
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Allocator = std.mem.Allocator;
const Vec2 = zm.Vec2;
const float = zm.float;
const clamp = zm.clamp;
const bufPrint = std.fmt.bufPrint;

const Line = struct {
    text: [96]u8 = @splat(0),
    len: usize = 0,
    ok: bool = true,
};

const State = struct {
    font: z.Font,
    lines: [24]Line = @splat(.{}),
    n_lines: usize = 0,
    all_ok: bool = true,

    // The GPU half cannot be checked inside `init`: `readLatest` on the `.gpu` backend is
    // ASYNCHRONOUS — it starts a staging copy and returns null until the map completes, a
    // few frames later. (The first cut of this test called it immediately and got four
    // "NO READBACK" lines that said nothing about the kernels.) So keep the pipe, dispatch
    // once, and poll each frame until the data actually arrives.
    gpu: Pipe = undefined,
    input: [sm.n_particles]Vec2 = @splat(.{ 0, 0 }),
    truth: Truth = .{},
    gpu_checked: bool = false,
    frames: u32 = 0,
};

fn say(s: *State, ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (s.n_lines >= s.lines.len) {
        return;
    }
    var l: Line = .{};
    const w: []u8 = bufPrint(&l.text, fmt, args) catch l.text[0..0];
    l.len = w.len;
    l.ok = ok;
    s.lines[s.n_lines] = l;
    s.n_lines += 1;
    if (!ok) {
        s.all_ok = false;
    }
}

/// A deterministic spread over the grid: a few particles land in every column, several rows
/// get very different populations, and one particle sits outside the domain so the clamp in
/// `cellOf` is exercised too.
fn makeInput(out: *[sm.n_particles]Vec2) void {
    var prng: std.Random.DefaultPrng = .init(0x50127);
    const rng: std.Random = prng.random();
    for (out, 0..) |*p, i| {
        if (i == 0) {
            p.* = .{ -50.0, -50.0 }; // deliberately out of bounds -> must clamp into cell 0
            continue;
        }
        p.* = .{
            rng.float(f32) * 800.0,
            rng.float(f32) * 400.0,
        };
    }
}

/// The answer, worked out on the host with no kernels involved.
const Truth = struct {
    counts: [sm.n_cells]u32 = @splat(0),
    starts: [sm.n_cells + 1]u32 = @splat(0),

    fn compute(input: *const [sm.n_particles]Vec2) Truth {
        var t: Truth = .{};
        for (input) |p| {
            t.counts[cellOfHost(p)] += 1;
        }
        var acc: u32 = 0;
        for (0..sm.n_cells) |c| {
            t.starts[c] = acc;
            acc += t.counts[c];
        }
        t.starts[sm.n_cells] = acc;
        return t;
    }
};

fn cellOfHost(p: Vec2) u32 {
    const max_cx: f32 = float(sm.n_cols - 1);
    const max_cy: f32 = float(sm.n_rows - 1);
    const cx: u32 = @trunc(clamp(@floor(p[0] / sm.cell_size), 0.0, max_cx));
    const cy: u32 = @trunc(clamp(@floor(p[1] / sm.cell_size), 0.0, max_cy));
    return cx + cy * sm.n_cols;
}

/// Check every stage of an ALREADY-DISPATCHED pipe against ground truth. Returns false if
/// the backend has no data yet (the `.gpu` readback is async), so the caller can poll.
fn checkStages(
    s: *State,
    pipe: *Pipe,
    label: []const u8,
    truth: *const Truth,
) bool {
    if (pipe.readLatest(.counts) == null) {
        return false; // readback not ready yet — try again next frame
    }

    // ---- stage 1: countGrid must reproduce the histogram exactly.
    if (pipe.readLatest(.counts)) |gc| {
        var bad: u32 = 0;
        var total: u32 = 0;
        for (gc, 0..) |v, c| {
            total += v;
            if (c < sm.n_cells and v != truth.counts[c]) {
                bad += 1;
            }
        }
        say(s, bad == 0 and total == sm.n_particles, "{s} countGrid: {d}/{d} cells wrong, total {d} (want {d})", .{
            label, bad, sm.n_cells, total, sm.n_particles,
        });
    } else {
        say(s, false, "{s} countGrid: NO READBACK", .{label});
    }

    // ---- stage 2: prefixSum must produce the exclusive scan, and ZERO the counts.
    if (pipe.readLatest(.starts)) |cs| {
        var bad: u32 = 0;
        for (0..sm.n_cells + 1) |c| {
            if (c < cs.len and cs[c] != truth.starts[c]) {
                bad += 1;
            }
        }
        const total_ok: bool = cs.len > sm.n_cells and cs[sm.n_cells] == sm.n_particles;
        say(s, bad == 0 and total_ok, "{s} prefixSum: {d}/{d} starts wrong, total {d} (want {d})", .{
            label,                                          bad,            sm.n_cells + 1,
            if (cs.len > sm.n_cells) cs[sm.n_cells] else 0, sm.n_particles,
        });
    } else {
        say(s, false, "{s} prefixSum: NO READBACK", .{label});
    }

    // ---- stage 4: after copyback, pos MUST be ordered by cell, and each cell's particles
    // must lie exactly within [starts[c], starts[c+1]) — the invariant every neighbour walk
    // in the fluid depends on.
    if (pipe.readLatest(.pos)) |pos| {
        var last: u32 = 0;
        var unsorted: u32 = 0;
        var out_of_range: u32 = 0;
        for (pos[0..@min(pos.len, sm.n_particles)], 0..) |p, slot| {
            const cell: u32 = cellOfHost(p);
            if (cell < last) {
                unsorted += 1;
            }
            last = cell;
            // slot must fall inside its own cell's range
            if (!(slot >= truth.starts[cell] and slot < truth.starts[cell + 1])) {
                out_of_range += 1;
            }
        }
        say(s, unsorted == 0 and out_of_range == 0, "{s} copyback: {d} out of order, {d} outside their cell range", .{
            label, unsorted, out_of_range,
        });
    } else {
        say(s, false, "{s} copyback: NO READBACK", .{label});
    }

    if (pipe.readLatest(.pos)) |pos_all| {
        const pos: []const Vec2 = pos_all[0..@min(pos_all.len, sm.n_particles)];
        // ---- stage 6: THE DENSITY ARITHMETIC. The neighbour SET is proven; this is the
        // float math done over it. Nothing has tested this layer, and it is where rho —
        // the number the whole pressure solve turns on — is actually produced.
        if (pipe.readLatest(.dens)) |dens| {
            var worst_rho: f32 = 0;
            var worst_near: f32 = 0;
            var bad: u32 = 0;
            for (pos, 0..) |p, i| {
                var want_rho: f64 = 0;
                var want_near: f64 = 0;
                for (pos, 0..) |q, j| {
                    if (i == j) {
                        continue;
                    }
                    const dx: f32 = q[0] - p[0];
                    const dy: f32 = q[1] - p[1];
                    const d2: f32 = dx * dx + dy * dy;
                    if (d2 < sm.cell_size * sm.cell_size) {
                        const omq: f64 = 1.0 - @as(f64, @sqrt(d2)) / @as(f64, sm.cell_size);
                        want_rho += omq * omq;
                        want_near += omq * omq * omq;
                    }
                }
                const got: Vec2 = if (i < dens.len) dens[i] else Vec2{ 0, 0 };
                const e_rho: f32 = @abs(got[0] - @as(f32, @floatCast(want_rho)));
                const e_near: f32 = @abs(got[1] - @as(f32, @floatCast(want_near)));
                if (e_rho > worst_rho) {
                    worst_rho = e_rho;
                }
                if (e_near > worst_near) {
                    worst_near = e_near;
                }
                if (e_rho > 0.01 or e_near > 0.01) {
                    bad += 1;
                }
            }
            say(s, bad == 0, "{s} DENSITY: {d}/{d} wrong (worst rho err {d:.4}, near err {d:.4})", .{
                label, bad, sm.n_particles, worst_rho, worst_near,
            });

            // ---- stage 7: THE PRESSURE CORRECTION. The CPU-vs-GPU fluid split proves the
            // fault is in force / viscosity / the integrator. Density is exact, so `corr` is
            // the very next thing computed over the same proven neighbour set.
            if (pipe.readLatest(.corr)) |corr| {
                var bad_c: u32 = 0;
                var worst_c: f32 = 0;
                for (pos, 0..) |p, i| {
                    const my_d: Vec2 = if (i < dens.len) dens[i] else Vec2{ 0, 0 };
                    const my_press: f64 = 0.009 * (@as(f64, my_d[0]) - 15.39);
                    const my_near: f64 = 0.028 * @as(f64, my_d[1]);
                    var wx: f64 = 0;
                    var wy: f64 = 0;
                    for (pos, 0..) |q, j| {
                        if (i == j) {
                            continue;
                        }
                        const rx: f32 = q[0] - p[0];
                        const ry: f32 = q[1] - p[1];
                        const d2: f32 = rx * rx + ry * ry;
                        if (d2 >= sm.cell_size * sm.cell_size) {
                            continue;
                        }
                        const dist: f64 = @sqrt(@as(f64, d2));
                        var dirx: f64 = 0;
                        var diry: f64 = 0;
                        if (dist > 0.5) {
                            dirx = @as(f64, rx) / dist;
                            diry = @as(f64, ry) / dist;
                        } else {
                            const seed: u32 = (@as(u32, @intCast(i)) +% @as(u32, @intCast(j))) *% 2654435761;
                            const ang: f64 = @as(f64, float(seed % 6283)) * 0.001;
                            const sgn: f64 = if (i < j) 1.0 else -1.0;
                            dirx = @cos(ang) * sgn;
                            diry = @sin(ang) * sgn;
                        }
                        const jd: Vec2 = if (j < dens.len) dens[j] else Vec2{ 0, 0 };
                        const j_press: f64 = 0.009 * (@as(f64, jd[0]) - 15.39);
                        const j_near: f64 = 0.028 * @as(f64, jd[1]);
                        const omq: f64 = 1.0 - dist / @as(f64, sm.cell_size);
                        const disp: f64 = 0.5 * ((my_press + j_press) * omq + (my_near + j_near) * omq * omq);
                        wx -= dirx * disp;
                        wy -= diry * disp;
                    }
                    const got: Vec2 = if (i < corr.len) corr[i] else Vec2{ 0, 0 };
                    const e: f32 = @abs(got[0] - @as(f32, @floatCast(wx))) + @abs(got[1] - @as(f32, @floatCast(wy)));
                    if (e > worst_c) {
                        worst_c = e;
                    }
                    if (e > 0.01) {
                        bad_c += 1;
                    }
                }
                say(s, bad_c == 0, "{s} FORCE: {d}/{d} wrong (worst |corr| err {d:.4})", .{
                    label, bad_c, sm.n_particles, worst_c,
                });

                // ---- stage 8: VISCOSITY. Untested until now. Its inner loop carries a
                // `continue` gated on a COMPUTED FLOAT, three loops deep — data-dependent
                // control flow nothing else in the module has.
                if (pipe.readLatest(.visc)) |visc| {
                    var bad_v: u32 = 0;
                    var worst_v: f32 = 0;
                    for (pos, 0..) |p, i| {
                        var vx: f64 = @as(f64, p[1]) * 0.01 - 2.0;
                        var vy: f64 = 1.0 - @as(f64, p[0]) * 0.008;
                        for (pos, 0..) |q, j| {
                            if (i == j) {
                                continue;
                            }
                            const sx: f64 = @as(f64, q[0]) - @as(f64, p[0]);
                            const sy: f64 = @as(f64, q[1]) - @as(f64, p[1]);
                            const dist: f64 = @sqrt(sx * sx + sy * sy);
                            if (dist >= @as(f64, sm.cell_size) or dist <= 0.0001) {
                                continue;
                            }
                            const nx2: f64 = sx / dist;
                            const ny2: f64 = sy / dist;
                            const ox: f64 = @as(f64, q[1]) * 0.01 - 2.0;
                            const oy: f64 = 1.0 - @as(f64, q[0]) * 0.008;
                            const u: f64 = (vx - ox) * nx2 + (vy - oy) * ny2;
                            if (u <= 0.0) {
                                continue;
                            }
                            const w: f64 = 1.0 - dist / @as(f64, sm.cell_size);
                            const imp_raw: f64 = 0.017 * w * u * u;
                            const imp: f64 = if (imp_raw < u) imp_raw else u;
                            vx -= nx2 * imp * 0.5;
                            vy -= ny2 * imp * 0.5;
                        }
                        const got: Vec2 = if (i < visc.len) visc[i] else Vec2{ 0, 0 };
                        const wx: f32 = @floatCast(vx);
                        const wy: f32 = @floatCast(vy);
                        const e: f32 = @abs(got[0] - wx) + @abs(got[1] - wy);
                        if (e > worst_v) {
                            worst_v = e;
                        }
                        if (e > 0.01) {
                            bad_v += 1;
                        }
                    }
                    say(s, bad_v == 0, "{s} VISCOSITY: {d}/{d} wrong (worst err {d:.4})", .{
                        label, bad_v, sm.n_particles, worst_v,
                    });
                }

                // ---- stage 9: APPLY. The last kernel the fluid runs that nothing has ever
                // verified. Branch-heavy: soft wall band, jittered hard clamp.
                if (pipe.readLatest(.applied)) |ap| {
                    var bad_a: u32 = 0;
                    var worst_a: f32 = 0;
                    const dom_w: f32 = float(sm.n_cols) * sm.cell_size;
                    const dom_h: f32 = float(sm.n_rows) * sm.cell_size;
                    for (pos, 0..) |p0, i| {
                        const cr: Vec2 = if (i < corr.len) corr[i] else Vec2{ 0, 0 };
                        var q: Vec2 = p0 + cr;
                        const band: f32 = sm.cell_size;
                        if (q[0] < band) {
                            q[0] += (band - q[0]) * 0.25;
                        } else if (q[0] > dom_w - band) {
                            q[0] -= (q[0] - (dom_w - band)) * 0.25;
                        }
                        if (q[1] < band) {
                            q[1] += (band - q[1]) * 0.25;
                        } else if (q[1] > dom_h - band) {
                            q[1] -= (q[1] - (dom_h - band)) * 0.25;
                        }
                        const jx: f32 = float(@as(u32, @intCast(i)) % 7) * 0.4;
                        const jy: f32 = float((@as(u32, @intCast(i)) / 7) % 7) * 0.4;
                        const lo_x: f32 = 1.5 + jx;
                        const hi_x: f32 = dom_w - 1.5 - jx;
                        const lo_y: f32 = 1.5 + jy;
                        const hi_y: f32 = dom_h - 1.5 - jy;
                        if (q[0] < lo_x) {
                            q[0] = lo_x;
                        } else if (q[0] > hi_x) {
                            q[0] = hi_x;
                        }
                        if (q[1] < lo_y) {
                            q[1] = lo_y;
                        } else if (q[1] > hi_y) {
                            q[1] = hi_y;
                        }
                        const got: Vec2 = if (i < ap.len) ap[i] else Vec2{ 0, 0 };
                        const e: f32 = @abs(got[0] - q[0]) + @abs(got[1] - q[1]);
                        if (e > worst_a) {
                            worst_a = e;
                        }
                        if (e > 0.01) {
                            bad_a += 1;
                        }
                    }
                    say(s, bad_a == 0, "{s} APPLY: {d}/{d} wrong (worst err {d:.4})", .{
                        label, bad_a, sm.n_particles, worst_a,
                    });
                }
            } else {
                say(s, false, "{s} force: NO READBACK", .{label});
            }
        } else {
            say(s, false, "{s} density: NO READBACK", .{label});
        }
    }
    return true;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };

    var input: [sm.n_particles]Vec2 = undefined;
    makeInput(&input);
    const truth: Truth = Truth.compute(&input);

    say(s, true, "counting sort: {d} particles, {d}x{d} grid", .{ sm.n_particles, sm.n_cols, sm.n_rows });

    // ---- the SAME kernel source, on the CPU (plain Zig). Synchronous: check immediately.
    var cpu: Pipe = Pipe.initCpu();
    dispatch(&cpu, &input);
    _ = checkStages(s, &cpu, "CPU", &truth);

    // ---- and on the GPU (SPIR-V -> WGSL). Dispatch now; check when the readback lands.
    s.gpu = try Pipe.initGpu(gpa, f.gpu.device, f.gpu.queue, &kernel_wgsls);
    s.input = input;
    s.truth = truth;
    dispatch(&s.gpu, &input);
}

/// Upload + run the five kernels once. Separated from the checking so the GPU can be
/// dispatched in `init` and inspected later, once its async readback completes.
fn dispatch(pipe: *Pipe, input: *const [sm.n_particles]Vec2) void {
    pipe.element_count = sm.n_particles;
    pipe.params = .{
        .count = sm.n_particles,
        .n_cols = sm.n_cols,
        .n_rows = sm.n_rows,
        .h = sm.cell_size,
    };
    pipe.upload(.pos, input);
    pipe.run("clearGrid", sm.n_cells);
    pipe.run("countGrid", sm.n_particles);
    pipe.run("prefixSum", 1);
    pipe.run("scatter", sm.n_particles);
    pipe.run("copyback", sm.n_particles);
    pipe.run("computeDensity", sm.n_particles);
    pipe.run("computeForce", sm.n_particles);
    pipe.run("computeVisc", sm.n_particles);
    pipe.run("applyMini", sm.n_particles);
}

fn update(f: *z.Frame, s: *State) void {
    // Poll the GPU's async readback. Once it lands, replace the "awaiting" line with the
    // real per-stage verdicts.
    if (!s.gpu_checked) {
        s.frames += 1;
        if (checkStages(s, &s.gpu, "GPU", &s.truth)) {
            s.gpu_checked = true;
            if (s.all_ok) {
                say(s, true, "ALL STAGES PASS on BOTH backends", .{});
            } else {
                say(s, false, "FAILURES ABOVE -- CPU vs GPU is the answer", .{});
            }
        } else if (s.frames > 600) {
            s.gpu_checked = true;
            say(s, false, "GPU: readback never completed ({d} frames)", .{s.frames});
        }
    }

    z.clearViewport(f, z.colors.slate_900);
    const fsz: f32 = clamp(f.window.widthf() / 46.0, 10.0, 20.0);
    var y: f32 = fsz;
    for (s.lines[0..s.n_lines]) |l| {
        const col: zm.Color = if (l.ok) z.colors.green_400 else z.colors.red_400;
        f.gl.text(.{ fsz * 0.5, y }, l.text[0..l.len], .{ .size = fsz, .color = col, .font = &s.font });
        y += fsz * 1.6;
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.gpu.deinit();
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - counting sort smoke",
            .width = 900,
            .height = 520,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
