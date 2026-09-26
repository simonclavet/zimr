//! tile_smoke - shared-memory NEIGHBOUR-TILING de-risk on device (Stage 2a).
//! Places particles, builds the uniform grid, then runs the per-cell tiled
//! gather and checks every particle's neighbour count against a brute-force
//! O(n_part^2) ground truth. Exact integer pass/fail. The CPU backend runs the same
//! at startup as an independent oracle. Once green, the fluid's density/force
//! passes can adopt the identical cooperative-load-barrier-tile-read shape.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const tg = @import("tile_gather.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const clear_wgsl = @embedFile("tileClearGrid_wgsl");
const build_wgsl = @embedFile("tileBuildGrid_wgsl");
const gather_wgsl = @embedFile("gatherTiled_wgsl");

const n_part: u32 = tg.num_particles;

/// dbg[c.id] == c.id+1 if thread c.id ran and its write landed (0 = never
/// written). Returns counts + sample values to read what c.id actually does.
const Probe = struct { correct: u32, nonzero: u32, s1000: u32, s5000: u32, maxidx: u32 };

const State = struct {
    font: z.Font,
    pipe: z.Compute(tg),
    truth: [n_part]u32,
    cpu_ok: bool = false,
    dispatched: bool = false,
    have_result: bool = false,
    miss: u32 = n_part,
    probe: Probe = .{ .correct = 0, .nonzero = 0, .s1000 = 0, .s5000 = 0, .maxidx = 0 },
    max_cell: u32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.pipe.deinit();
}

fn genPositions(pos: *[n_part][2]f32) void {
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x7f1e);
    const rnd: std.Random = prng.random();
    for (0..n_part) |i| {
        pos[i] = .{ rnd.float(f32) * tg.domain, rnd.float(f32) * tg.domain };
    }
}

fn bruteTruth(pos: *const [n_part][2]f32, truth: *[n_part]u32) void {
    const h2: f32 = tg.h_radius * tg.h_radius;
    for (0..n_part) |i| {
        var n: u32 = 0;
        for (0..n_part) |j| {
            if (j == i) {
                continue;
            }
            const sx: f32 = pos[j][0] - pos[i][0];
            const sy: f32 = pos[j][1] - pos[i][1];
            if (sx * sx + sy * sy < h2) {
                n += 1;
            }
        }
        truth[i] = n;
    }
}

/// Build the grid + run the tiled gather on whichever backend `pipe` is.
fn runGather(pipe: *z.Compute(tg)) void {
    pipe.run("tileClearGrid", tg.grid_cells);
    pipe.run("tileBuildGrid", n_part);
    pipe.run("gatherTiled", tg.grid_cells * tg.wg_size);
    // readLatest(.dbg) slices to element_count, so set it to the full gather
    // width - all grid_cells*wg_size entries come back (out_count is shorter and
    // slices to its own len).
    pipe.element_count = tg.grid_cells * tg.wg_size;
}

fn countMiss(out: []const u32, truth: *const [n_part]u32) u32 {
    var m: u32 = 0;
    var i: u32 = 0;
    while (i < n_part and i < out.len) : (i += 1) {
        if (out[i] != truth[i]) {
            m += 1;
        }
    }
    return m;
}

fn probeDbg(dbg: []const u32) Probe {
    var p: Probe = .{ .correct = 0, .nonzero = 0, .s1000 = 0, .s5000 = 0, .maxidx = 0 };
    var t: u32 = 0;
    while (t < dbg.len) : (t += 1) {
        if (dbg[t] == t + 1) {
            p.correct += 1;
        }
        if (dbg[t] != 0) {
            p.nonzero += 1;
            p.maxidx = t;
        }
    }
    if (dbg.len > 1000) {
        p.s1000 = dbg[1000];
    }
    if (dbg.len > 5000) {
        p.s5000 = dbg[5000];
    }
    return p;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);

    var pos: [n_part][2]f32 = undefined;
    genPositions(&pos);
    var truth: [n_part]u32 = undefined;
    bruteTruth(&pos, &truth);

    const params: tg.Params = .{ .count = n_part, .h = tg.h_radius, .cols = tg.n_cols, .rows = tg.n_rows };

    // CPU-backend oracle.
    var cpu: z.Compute(tg) = z.Compute(tg).initCpu();
    cpu.params = params;
    cpu.upload(.pos, pos[0..]);
    runGather(&cpu);
    const co: []const u32 = cpu.readLatest(.out_count).?;
    var max_cell: u32 = 0;
    for (cpu.readLatest(.grid_counts).?) |gc| {
        max_cell = @max(max_cell, gc);
    }
    const cpu_ok: bool = countMiss(co, &truth) == 0;

    // GPU round-trip.
    var pipe: z.Compute(tg) = try z.Compute(tg).initGpu(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        &.{
            .{ .name = "tileClearGrid", .wgsl = clear_wgsl },
            .{ .name = "tileBuildGrid", .wgsl = build_wgsl },
            .{ .name = "gatherTiled", .wgsl = gather_wgsl },
        },
    );
    pipe.params = params;
    pipe.upload(.pos, pos[0..]);

    s.* = .{ .font = font, .pipe = pipe, .truth = truth, .cpu_ok = cpu_ok, .max_cell = max_cell };
}

fn update(f: *z.Frame, s: *State) void {
    if (!s.dispatched) {
        s.dispatched = true;
        runGather(&s.pipe);
    }
    if (s.pipe.readLatest(.out_count)) |out| {
        s.miss = countMiss(out, &s.truth);
        if (s.pipe.readLatest(.dbg)) |dbg| {
            s.probe = probeDbg(dbg);
        }
        s.have_result = true;
    }

    z.clearViewport(f, z.colors.slate_900);

    var bufw: [160]u8 = undefined;
    const total: u32 = tg.grid_cells * tg.wg_size;
    const probe_ok: bool = s.probe.correct == total;
    const wgid_msg: []const u8 = if (!s.have_result)
        "c.id probe: ..."
    else
        bufPrint(
            &bufw,
            "c.id probe: {d}/{d} ok, nz={d}, max_t={d}, [1000]={d} [5000]={d}",
            .{ s.probe.correct, total, s.probe.nonzero, s.probe.maxidx, s.probe.s1000, s.probe.s5000 },
        ) catch "probe";
    f.gl.text(.{ 14, 20 }, wgid_msg, .{ .size = 15, .color = if (!s.have_result)
        z.colors.slate_300
    else if (probe_ok)
        z.colors.green_400
    else
        z.colors.red_500, .font = &s.font });

    var buf: [160]u8 = undefined;
    const head: []const u8 = if (!s.have_result)
        "GPU tiled neighbour gather: ..."
    else if (s.miss == 0)
        bufPrint(&buf, "GPU tiled neighbour gather: PASS ({d} particles)", .{n_part}) catch "PASS"
    else
        bufPrint(&buf, "GPU tiled neighbour gather: FAIL ({d}/{d} wrong)", .{ s.miss, n_part }) catch "FAIL";
    const col: Color = if (!s.have_result)
        z.colors.slate_300
    else if (s.miss == 0)
        z.colors.green_400
    else
        z.colors.red_500;
    f.gl.text(.{ 14, 50 }, head, .{ .size = 18, .color = col, .font = &s.font });

    const cpu_msg: []const u8 = if (s.cpu_ok) "CPU oracle: PASS" else "CPU oracle: FAIL";
    f.gl.text(
        .{ 14, 80 },
        cpu_msg,
        .{ .size = 14, .color = if (s.cpu_ok) z.colors.green_400 else z.colors.red_500, .font = &s.font },
    );

    var buf2: [120]u8 = undefined;
    const info: []const u8 = bufPrint(
        &buf2,
        "grid {d}x{d}, max/cell {d} (cap {d}), one workgroup per cell, dispatch {d} threads",
        .{ tg.n_cols, tg.n_rows, s.max_cell, tg.max_per_cell, total },
    ) catch "";
    f.gl.text(.{ 14, 108 }, info, .{ .size = 13, .color = z.colors.slate_300, .font = &s.font });

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - tiling smoke",
            .width = 760,
            .height = 420,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
