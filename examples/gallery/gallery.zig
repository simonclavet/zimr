//! gallery - multi-app demo on WebGPU, now via the pushViewport primitive
//! (P1 of the multi-app refactor). One App hosts four independent sub-apps in a
//! 2x2 grid: pulse (gradient), spinner (rotating triangle), sparkles (per-app-RNG
//! particles), counter (big frame count). The host opens ONE draw frame, then for
//! each cell calls z.pushViewport(f, cell) -> sub-app -> z.popViewport(f). Inside
//! a viewport the sub-app draws in LOCAL coordinates as if it owns a small screen
//! (it reads f.window for its size, draws from 0,0); pushViewport sets the
//! modelview to translate it into the cell and clips to it. This is the manual
//! shape every example will take once migrated to the launcher model - the
//! sub-apps here are written exactly like a future embedded example body (no
//! begin/clear/end, no absolute offsets, reads f.window).
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const sinTurns = zm.sinTurns;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const pi = zm.pi;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const log = std.log.scoped(.gallery);

// ===========================================================================
// Sub-app: Pulse - animated background gradient
// ===========================================================================

const PulseState = struct {
    frame_count: usize = 0,
};

inline fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = float(a);
    const bf: f32 = float(b);
    return @trunc(af + t * (bf - af));
}

fn updatePulse(s: *PulseState, f: *z.Frame, font: z.Font) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const t: f32 = f.time.time;
    // A HALF turn across the cycle, so the phase rises and falls once.
    const phase: f32 = 0.5 + 0.5 * sinTurns(t * 0.5);
    const a: Color = z.colors.violet_500;
    const b: Color = z.colors.pink_500;
    const bg: Color = .{
        .r = lerpU8(a.r, b.r, phase),
        .g = lerpU8(a.g, b.g, phase),
        .b = lerpU8(a.b, b.b, phase),
        .a = 255,
    };
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = bg });
    f.gl.text(.{ 12, 12 }, "pulse", .{ .size = 20, .color = z.colors.slate_50, .font = &font });
    if (s.frame_count == 1) {
        log.info("[pulse] started", .{});
    }
}

// ===========================================================================
// Sub-app: Spinner - rotating triangle
// ===========================================================================

const SpinnerState = struct {
    frame_count: usize = 0,
};

fn updateSpinner(s: *SpinnerState, f: *z.Frame, font: z.Font) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = z.colors.slate_900 });

    const cx: f32 = w / 2;
    const cy: f32 = h / 2;
    const r: f32 = @min(w, h) * 0.28;
    const angle: f32 = f.time.time * 1.2; // radians/sec
    const two_pi: f32 = pi * 2;

    var verts: [3]Vec2 = undefined;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const ang: f32 = angle + float(i) * (two_pi / 3);
        verts[i] = .{ cx + r * @cos(ang), cy + r * @sin(ang) };
    }

    f.gl.triangle(verts[0], verts[1], verts[2], .{ .color = z.colors.amber_400 });
    f.gl.triangleLines(verts[0], verts[1], verts[2], .{ .color = z.colors.amber_200 });
    f.gl.text(.{ 12, 12 }, "spinner", .{ .size = 20, .color = z.colors.slate_50, .font = &font });
    if (s.frame_count == 1) {
        log.info("[spinner] started", .{});
    }
}

// ===========================================================================
// Sub-app: Sparkles - particle spawn with this sub-app's own RNG
// ===========================================================================

const max_sparkles: usize = 64;

const Sparkle = struct {
    x: f32,
    y: f32,
    age: f32,
    life: f32,
};

const SparklesState = struct {
    frame_count: usize = 0,
    sparkles: [max_sparkles]Sparkle = @splat(Sparkle{ .x = 0, .y = 0, .age = 999, .life = 0 }),
    next_slot: usize = 0,
};

fn updateSparkles(s: *SparklesState, f: *z.Frame, font: z.Font, rand: std.Random) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = z.colors.slate_950 });

    const dt: f32 = f.time.delta_time;

    // Spawn 2 new sparkles per frame from THIS sub-app's own RNG stream.
    var spawn_i: usize = 0;
    while (spawn_i < 2) : (spawn_i += 1) {
        const slot: usize = s.next_slot;
        s.next_slot = (s.next_slot + 1) % max_sparkles;
        s.sparkles[slot] = .{
            .x = rand.float(f32) * w,
            .y = rand.float(f32) * h,
            .age = 0,
            .life = 0.6 + rand.float(f32) * 0.8,
        };
    }

    for (&s.sparkles) |*sp| {
        sp.age += dt;
        if (sp.age >= sp.life) {
            continue;
        }
        const tnorm: f32 = sp.age / sp.life;
        const alpha: u8 = @round(255.0 * (1.0 - tnorm));
        const base: Color = z.colors.sky_300;
        const col: Color = .{ .r = base.r, .g = base.g, .b = base.b, .a = alpha };
        f.gl.circle(.{ sp.x, sp.y }, 2.0 + (1.0 - tnorm) * 1.5, .{ .color = col, .segments = 12 });
    }

    f.gl.text(.{ 12, 12 }, "sparkles", .{ .size = 20, .color = z.colors.slate_50, .font = &font });
    if (s.frame_count == 1) {
        log.info("[sparkles] started", .{});
    }
}

// ===========================================================================
// Sub-app: Counter - large frame counter
// ===========================================================================

const CounterState = struct {
    frame_count: usize = 0,
};

fn measureWidth(font: z.Font, text: []const u8, size: f32) f32 {
    const m: Vec2 = z.measureText(font, text, size);
    return m[0];
}

fn updateCounter(s: *CounterState, f: *z.Frame, font: z.Font) void {
    s.frame_count += 1;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    f.gl.rect(.{ .x = 0, .y = 0, .width = w, .height = h }, .{ .color = z.colors.emerald_500 });

    var buf: [32]u8 = undefined;
    const text: []const u8 = bufPrint(&buf, "{d}", .{s.frame_count}) catch return;
    const font_size: f32 = @min(w, h) * 0.32;
    const tw: f32 = measureWidth(font, text, font_size);
    const tx: f32 = (w - tw) / 2;
    const ty: f32 = (h - font_size) / 2;
    f.gl.text(.{ tx, ty }, text, .{ .size = font_size, .color = z.colors.emerald_200, .font = &font });
    f.gl.text(.{ 12, 12 }, "counter", .{ .size = 20, .color = z.colors.slate_50, .font = &font });

    if (s.frame_count == 1 or s.frame_count % 60 == 0) {
        log.info("[counter] tick #{d}", .{s.frame_count});
    }
}

// ===========================================================================
// Gallery host
// ===========================================================================

const State = struct {
    font: z.Font,
    pulse: PulseState = .{},
    spinner: SpinnerState = .{},
    sparkles: SparklesState = .{},
    counter: CounterState = .{},
    // Distinct seed -> an independent RNG stream for the sparkles cell.
    sparkles_rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xC3C3_C3C3),
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, z.colors.slate_950);

    // Cells from the LIVE canvas each frame (responsive). f.window here is the
    // full canvas - pushViewport overrides it to the cell for each sub-app.
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const cw: f32 = w * 0.5;
    const ch: f32 = h * 0.5;
    const cell_pulse: z.Rectangle = .{ .x = 0, .y = 0, .width = cw, .height = ch };
    const cell_spinner: z.Rectangle = .{ .x = cw, .y = 0, .width = cw, .height = ch };
    const cell_sparkles: z.Rectangle = .{ .x = 0, .y = ch, .width = cw, .height = ch };
    const cell_counter: z.Rectangle = .{ .x = cw, .y = ch, .width = cw, .height = ch };

    // Each sub-app draws in LOCAL coords inside its cell; pushViewport places +
    // clips it (1:1 reflow here - logical size == cell size).
    z.pushViewport(f, .{ .rect = cell_pulse, .logical_w = cw, .logical_h = ch });
    updatePulse(&s.pulse, f, s.font);
    z.popViewport(f);

    z.pushViewport(f, .{ .rect = cell_spinner, .logical_w = cw, .logical_h = ch });
    updateSpinner(&s.spinner, f, s.font);
    z.popViewport(f);

    z.pushViewport(f, .{ .rect = cell_sparkles, .logical_w = cw, .logical_h = ch });
    updateSparkles(&s.sparkles, f, s.font, s.sparkles_rng.random());
    z.popViewport(f);

    z.pushViewport(f, .{ .rect = cell_counter, .logical_w = cw, .logical_h = ch });
    updateCounter(&s.counter, f, s.font);
    z.popViewport(f);

    // Cell borders (full-canvas coords; viewports popped, f.window restored).
    const cc: Color = z.colors.slate_700;
    f.gl.line(.{ cw, 0 }, .{ cw, h }, .{ .color = cc, .thickness = 1.0 });
    f.gl.line(.{ 0, ch }, .{ w, ch }, .{ .color = cc, .thickness = 1.0 });
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - gallery (4 sub-apps)",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
