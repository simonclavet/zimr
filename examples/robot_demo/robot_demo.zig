//! robot_demo — a scene table for `src/robot.zig`, in the shape of the 2D physics demo.
//!
//! The host knows nothing about any individual scene: it steps whatever `scenes.zig` hands
//! it, draws the links from the engine's own body poses, and renders a HUD. Adding a scene
//! is adding a row to that table.
//!
//! Every scene is planar (hinges about Z), so this draws in 2D with no camera. The engine
//! is fully 3D; the demo is 2D because that is what reads on a phone.
//!
//! Standard wgpu example contract: a `pub const app: z.AppSpec(State)`.

const std = @import("std");
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;

const z = @import("zimr");
const zm = @import("zm");
const rbt = z.robot;
const scenes = @import("scenes.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const vec2 = zm.vec2;
const rotate = zm.rotate;
const float = zm.float;
const assertUnreachable = zm.assertUnreachable;

/// Scale text and chrome with the viewport.
///
/// A standalone build renders at DEVICE resolution — a phone reporting a CSS width of 400
/// gives a canvas near 1080 wide — so a fixed 13-pixel font arrives about four CSS pixels
/// tall. Readable in the in-app viewer, invisible in a browser full-screen. Scaling against
/// the smaller dimension makes a glyph a fixed fraction of the screen instead.
fn uiScale(w: f32, h: f32) f32 {
    return @max(1.0, @min(w, h) / 450.0);
}

/// The scene picker's strip along the bottom, before scaling.
const picker_h: f32 = 108;
/// Where the pivot sits within the world area, as a fraction of its height. Leaves room
/// above for the HUD and below for a full downward swing.
const origin_y_frac: f32 = 0.30;
/// Fraction of the world area a scene's full reach should occupy. Under 1 so a mechanism
/// swinging sideways still has margin.
const fill: f32 = 0.62;

const bg: Color = .{ .r = 31, .g = 20, .b = 14, .a = 255 };
const panel: Color = .{ .r = 51, .g = 34, .b = 24, .a = 255 };
const panel_on: Color = .{ .r = 88, .g = 52, .b = 32, .a = 255 };
const accent: Color = .{ .r = 211, .g = 95, .b = 51, .a = 255 };
const accent2: Color = .{ .r = 79, .g = 179, .b = 165, .a = 255 };
const trail_col: Color = .{ .r = 79, .g = 179, .b = 165, .a = 80 };
const text_col: Color = .{ .r = 240, .g = 230, .b = 210, .a = 255 };
const dim_col: Color = .{ .r = 168, .g = 150, .b = 132, .a = 255 };
const target_col: Color = .{ .r = 232, .g = 196, .b = 92, .a = 255 };

const trail_len: usize = 200;

const State = struct {
    gpa: Allocator,
    font: z.Font,
    index: usize,
    live: scenes.Live,
    trail: [trail_len]Vec2,
    trail_n: usize,
    accumulator: f32,
    /// Live drag target, in world metres.
    target: Vec2,
    pointing: bool,

    fn load(self: *State, index: usize) !void {
        self.live.deinit(self.gpa);
        self.index = index;
        self.live = try scenes.all[index].build(self.gpa);
        self.trail_n = 0;
        self.accumulator = 0;
        self.pointing = false;
    }
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .index = 0,
        .live = try scenes.all[0].build(gpa),
        .trail = @splat(vec2(0, 0)),
        .trail_n = 0,
        .accumulator = 0,
        .target = vec2(0, -0.5),
        .pointing = false,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    s.live.deinit(gpa);
    z.unloadFont(gpa, s.font);
}

/// How the world maps onto the screen, recomputed each frame so the view survives a
/// resize, a rotation, and a viewport squashed by an on-screen keyboard.
const View = struct {
    origin: Vec2,
    scale: f32,

    /// Fit `reach` metres into the space above the picker, in both axes.
    fn fit(w: f32, h: f32, reach: f32) View {
        const world_h: f32 = @max(h - picker_h * uiScale(w, h), 80);
        const oy: f32 = world_h * origin_y_frac;
        // Vertically the mechanism hangs DOWN from the pivot, so the space that matters is
        // what is below it. Horizontally it can swing either way, so it is the half-width.
        const room: f32 = @min(world_h - oy, w * 0.5);
        return .{ .origin = vec2(w * 0.5, oy), .scale = room * fill / @max(reach, 0.01) };
    }

    fn toScreen(self: View, p: Vec2) Vec2 {
        return vec2(self.origin[0] + p[0] * self.scale, self.origin[1] - p[1] * self.scale);
    }

    fn toWorld(self: View, p: Vec2) Vec2 {
        return vec2((p[0] - self.origin[0]) / self.scale, (self.origin[1] - p[1]) / self.scale);
    }
};

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    const w: f32 = float(f.window.screen_width);
    const h: f32 = float(f.window.screen_height);
    const scene: scenes.Scene = scenes.all[s.index];
    const m: *rbt.Model = &s.live.model;
    const d: *rbt.Data = &s.live.data;

    // ---- input ----
    const mouse: Vec2 = z.getMousePosition(f.input);
    const held: bool = z.isMouseButtonDown(f.input, .left);
    const view: View = .fit(w, h, scene.reach);
    // The bottom strip is the scene picker; everything above it is the world.
    const ui: f32 = uiScale(w, h);
    const picker_top: f32 = h - picker_h * ui;
    const in_world: bool = mouse[1] < picker_top;
    s.pointing = held and in_world;
    if (s.pointing) {
        s.target = view.toWorld(mouse);
    }

    // ---- step, at a fixed rate independent of frame rate ----
    const dt: f32 = m.opt.timestep;
    s.accumulator += @min(f.time.delta_time, 0.1);
    while (s.accumulator >= dt) : (s.accumulator -= dt) {
        // A controller belongs between "state is known" and "forces are committed", so the
        // hook runs against a forward pass and then the step re-runs it. That costs one
        // extra evaluation and keeps the control law honest about what it can see.
        rbt.forward(m, d);
        @memset(d.applied_force, 0);
        if (scene.control) |hook| {
            hook(&s.live, .{ .target = s.target, .pointing = s.pointing, .elapsed = s.live.elapsed });
        }
        rbt.step(m, d);
        s.live.elapsed += dt;
    }
    rbt.forward(m, d);

    // ---- draw ----
    z.clearViewport(f, bg);

    // Trail of the scene's nominated tip.
    if (scene.tip) |tip| {
        const p: Vec = d.body_xpos[tip.body] + rotate(d.body_xrot[tip.body], tip.local);
        s.trail[s.trail_n % trail_len] = vec2(p[0], p[1]);
        s.trail_n += 1;
        const shown: usize = @min(s.trail_n, trail_len);
        const oldest: usize = if (s.trail_n > trail_len) s.trail_n - trail_len else 0;
        var k: usize = 1;
        while (k < shown) : (k += 1) {
            const a: Vec2 = s.trail[(oldest + k - 1) % trail_len];
            const b: Vec2 = s.trail[(oldest + k) % trail_len];
            gl.line(view.toScreen(a), view.toScreen(b), .{ .color = trail_col, .thickness = 2 * ui });
        }
    }

    // The mechanism itself, drawn from the engine's body poses. Body 0 is the world, so
    // each real body's link runs from its parent's origin to its own.
    var bi: u32 = 1;
    while (bi < m.nbody) : (bi += 1) {
        const parent: u32 = m.body_parent[bi];
        const a: Vec = d.body_xpos[parent];
        const b: Vec = d.body_xpos[bi];
        const col: Color = if (bi % 2 == 1) accent else accent2;
        gl.line(
            view.toScreen(vec2(a[0], a[1])),
            view.toScreen(vec2(b[0], b[1])),
            .{ .color = col, .thickness = 9 * ui },
        );
        gl.circle(view.toScreen(vec2(b[0], b[1])), 6, .{ .color = col });
    }
    // The far end of the last link, which no body origin marks.
    if (scene.tip) |tip| {
        const p: Vec = d.body_xpos[tip.body] + rotate(d.body_xrot[tip.body], tip.local);
        const last: Vec = d.body_xpos[tip.body];
        const col: Color = if (tip.body % 2 == 1) accent else accent2;
        gl.line(
            view.toScreen(vec2(last[0], last[1])),
            view.toScreen(vec2(p[0], p[1])),
            .{ .color = col, .thickness = 9 * ui },
        );
        gl.circle(view.toScreen(vec2(p[0], p[1])), 7, .{ .color = col });
    }
    gl.circle(view.toScreen(vec2(0, 0)), 7, .{ .color = dim_col });

    if (s.pointing) {
        gl.circle(view.toScreen(s.target), 9 * ui, .{ .color = target_col, .outline = 2 });
    }

    // ---- HUD ----
    var buf: [160]u8 = undefined;
    const title: []const u8 = bufPrint(&buf, "{s} / {s}", .{ scene.category, scene.name }) catch scene.name;
    gl.text(vec2(16 * ui, 26 * ui), title, .{ .size = 18 * ui, .color = text_col, .font = &s.font });
    gl.text(vec2(16 * ui, 48 * ui), scene.blurb, .{ .size = 13 * ui, .color = dim_col, .font = &s.font });

    var buf2: [160]u8 = undefined;
    const stats: []const u8 = bufPrint(
        &buf2,
        "nv {d}  nu {d}  constraints {d}  solver {d} it  energy {d:.2} J",
        .{ m.nv, m.nu, d.constraint_count, d.solver_iterations, rbt.energy(m, d) },
    ) catch "";
    gl.text(vec2(16 * ui, 70 * ui), stats, .{ .size = 13 * ui, .color = dim_col, .font = &s.font });

    // A scene's own readout, if it has one: the numbers that scene is actually about.
    if (scene.readout) |readout| {
        var buf3: [160]u8 = undefined;
        gl.text(
            vec2(16 * ui, 92 * ui),
            readout(&s.live, &buf3),
            .{ .size = 13 * ui, .color = accent2, .font = &s.font },
        );
    }

    // ---- scene picker: one cell per scene, wrapped ----
    const cols: usize = 4;
    const cell_w: f32 = (w - 24 * ui) / float(cols);
    const cell_h: f32 = 30 * ui;
    const clicked: bool = z.isMouseButtonPressed(f.input, .left);
    for (scenes.all, 0..) |sc, i| {
        const col_i: f32 = float(i % cols);
        const row_i: f32 = float(i / cols);
        const r: z.Rectangle = .{
            .x = 12 * ui + col_i * cell_w,
            .y = picker_top + 6 * ui + row_i * (cell_h + 6 * ui),
            .width = cell_w - 6 * ui,
            .height = cell_h,
        };
        gl.rect(r, .{ .color = if (i == s.index) panel_on else panel });
        gl.text(
            vec2(r.x + 7 * ui, r.y + cell_h * 0.68),
            sc.name,
            .{ .size = 11 * ui, .color = if (i == s.index) text_col else dim_col, .font = &s.font },
        );
        const hit: bool = mouse[0] >= r.x and mouse[0] <= r.x + r.width and
            mouse[1] >= r.y and mouse[1] <= r.y + r.height;
        if (clicked and hit and i != s.index) {
            s.load(i) catch assertUnreachable(@src(), "scene build failed", .{});
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - robot demo",
            .width = 560,
            .height = 940,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
