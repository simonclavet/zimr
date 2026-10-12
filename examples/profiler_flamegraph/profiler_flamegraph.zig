//! profiler_flamegraph - the integrated profiler's flamegraph on the simplest workload there is.
//!
//! Every frame pretends to be a game frame: it simulates (broadphase, narrowphase, solve), thinks
//! (pathfind) and culls, and each step "works" by spinning on the clock for a fixed number of
//! milliseconds inside a profiler zone. Once a second one frame also loads a level - a long hitch - and
//! the panel, which always shows the WORST frame of the last two seconds, lands on that frame.
//!
//! The whole integration is three things: a zone at the top of each function (`z.profiler.zone(@src())`,
//! named after the function it sits in), a ui window, and `z.profiler_ui.panel(u)` inside it. The engine
//! marks the frames itself. The profiler records in `debug` and `release` builds and is compiled out of
//! `ship`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const Ui = z.ui_real.Ui;
const Zone = z.profiler.Zone;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// The pretend workload: how long each step spins, in milliseconds. `solve` and the level load are
// sliders instead, so the flamegraph can be watched changing shape.
const broadphase_ms: f64 = 0.6;
const narrowphase_ms: f64 = 0.9;
const pathfind_ms: f64 = 0.8;
/// `think`'s own work besides `pathfind`: the flamegraph shows it as the part of `think` with nothing under it.
const think_own_ms: f64 = 0.3;
const cull_ms: f64 = 0.4;

/// One level load a second keeps a hitch inside the profiler's two-second window at all times.
const seconds_between_level_loads: f32 = 1.0;

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    solve_ms: f32 = 1.5,
    level_load_ms: f32 = 20.0,
    seconds_since_level_load: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .ui_host = z.UiHost.init(gpa, font), .font = font };
}

/// Burns `ms` milliseconds on the profiler's own clock: the stand-in for real work. The browser's main
/// thread cannot block, so a sleep is a spin, and it shows in the flamegraph exactly as work would. A host
/// without a clock (host tests) reads 0 forever, so there the spin returns at once rather than never.
fn spinMs(ms: f64) void {
    const start_ms: f64 = z.wgpu.nowMs();
    const clock_is_running: bool = start_ms > 0;
    if (!clock_is_running) {
        return;
    }
    while (z.wgpu.nowMs() - start_ms < ms) {}
}

fn broadphase() void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    spinMs(broadphase_ms);
}

fn narrowphase() void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    spinMs(narrowphase_ms);
}

fn solve(solve_ms: f32) void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    spinMs(solve_ms);
}

fn simulate(solve_ms: f32) void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    broadphase();
    narrowphase();
    solve(solve_ms);
}

fn pathfind() void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    spinMs(pathfind_ms);
}

fn think() void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    pathfind();
    spinMs(think_own_ms);
}

fn cull() void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    spinMs(cull_ms);
}

fn loadLevel(level_load_ms: f32) void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    spinMs(level_load_ms);
}

/// The window holding the controls and the profiler's panel. Zoned like the work, so the cost of drawing
/// the profiler shows in the profiler.
fn drawPanel(f: *z.Frame, s: *State) void {
    const zone: Zone = z.profiler.zone(@src());
    defer zone.end();
    const u: Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    const viewport_w: f32 = f.window.widthf();
    const viewport_h: f32 = f.window.heightf();
    const narrow: bool = Ui.isNarrow(viewport_w);
    const panel_w: f32 = @min(900.0, viewport_w - 16);
    const panel_h: f32 = @min(480.0, viewport_h - 16);
    _ = u.scaleToViewport(panel_w, if (narrow) 30.0 else 48.0);

    if (u.window("profiler", .{
        .initial_pos = .{ 8, 8 },
        .initial_size = .{ panel_w, panel_h },
    })) |w| {
        defer w.close();
        u.text("once a second a frame loads a level; the panel shows the worst frame of the last 2 s", .{});
        _ = u.slider("solve ms", &s.solve_ms, .{ .min = 0, .max = 8 });
        _ = u.slider("level load ms", &s.level_load_ms, .{ .min = 0, .max = 40 });
        const frozen: bool = z.profiler.isFrozen();
        if (u.button(if (frozen) "Live" else "Freeze", .{})) {
            if (frozen) {
                z.profiler.unfreeze();
            } else {
                z.profiler.freeze();
            }
        }
        u.separator();
        if (!z.profiler.enabled) {
            u.text("the profiler is compiled out of ship builds: build with -Dmode=release", .{});
        }
        z.profiler_ui.panel(u);
    }
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });

    simulate(s.solve_ms);
    think();
    cull();
    s.seconds_since_level_load += f.time.delta_time;
    const level_load_is_due: bool = s.seconds_since_level_load >= seconds_between_level_loads;
    if (level_load_is_due) {
        loadLevel(s.level_load_ms);
        s.seconds_since_level_load = 0;
    }

    drawPanel(f, s);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - profiler flamegraph",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
