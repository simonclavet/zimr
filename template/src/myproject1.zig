//! myproject1 - 2D bouncing balls with an ImGui control panel.
//!
//! Demonstrates:
//!   - the `pub const app: z.AppSpec(State)` descriptor (zimr's runner owns the frame)
//!   - 2D drawing through `f.gl` (`circle`, `line`, `text`)
//!   - mouse input (`z.isMouseButtonPressed` + `z.getMousePosition`)
//!   - an ImGui panel: sliders, checkboxes, a color editor, buttons
//!   - `wantCaptureMouse`, so a click on the panel does not spawn a ball
//!
//! Click anywhere outside the panel to spawn a ball.
//!
//! Rename this file (and its row in build.zig + its card in public/index.html)
//! to whatever your project actually is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Random = std.Random;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;
const splat2 = zm.splat2;
const colors = z.colors;

/// Wired by zimr's `Project`. zimr ships no default font: text needs one.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The longest step the integrator takes. A tab that was in the background
/// resumes with a huge delta; clamping it keeps balls from tunnelling out.
const max_step_seconds: f32 = 1.0 / 20.0;

const palette = [_]Color{
    colors.sky_400,   colors.amber_400,  colors.pink_400,
    colors.green_400, colors.violet_400, colors.rose_400,
};

const Ball = struct {
    pos: Vec2,
    vel: Vec2,
    radius: f32,
    color: Color,
};

const State = struct {
    /// `update` is not handed an allocator, so spawning a ball uses this one.
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    balls: ArrayList(Ball) = .empty,

    // Tunables, driven by the panel.
    gravity: f32 = 980.0, // pixels / second^2
    damping: f32 = 0.85, // wall-bounce coefficient: 1 = elastic, 0 = stop dead
    spawn_radius: f32 = 18,
    background: Color = .{ .r = 0x18, .g = 0x1a, .b = 0x1f, .a = 0xff },
    paused: bool = false,
    show_velocity: bool = false,
};

fn spawnBall(s: *State, random: Random, pos: Vec2) void {
    const horizontal_speed: f32 = (random.float(f32) - 0.5) * 360.0;
    // Out of memory is the only failure: then there is just no new ball.
    s.balls.append(s.gpa, .{
        .pos = pos,
        .vel = .{ horizontal_speed, -50 },
        .radius = s.spawn_radius,
        .color = palette[s.balls.items.len % palette.len],
    }) catch return;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .gpa = gpa, .font = font, .ui_host = z.UiHost.init(gpa, font) };
    // A few balls so the first frame is not empty.
    for (0..5) |i| {
        spawnBall(s, f.random, .{ 200 + float(i) * 100, 100 });
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
    s.balls.deinit(gpa);
}

fn stepBalls(s: *State, dt: f32, width: f32, height: f32) void {
    for (s.balls.items) |*ball| {
        ball.vel[1] += s.gravity * dt;
        ball.pos += ball.vel * splat2(dt);

        // Wall bounces: clamp the position back inside, then reflect the velocity.
        const hits_left: bool = ball.pos[0] - ball.radius < 0;
        const hits_right: bool = ball.pos[0] + ball.radius > width;
        if (hits_left) {
            ball.pos[0] = ball.radius;
            ball.vel[0] = -ball.vel[0] * s.damping;
        } else if (hits_right) {
            ball.pos[0] = width - ball.radius;
            ball.vel[0] = -ball.vel[0] * s.damping;
        }
        const hits_top: bool = ball.pos[1] - ball.radius < 0;
        const hits_floor: bool = ball.pos[1] + ball.radius > height;
        if (hits_top) {
            ball.pos[1] = ball.radius;
            ball.vel[1] = -ball.vel[1] * s.damping;
        } else if (hits_floor) {
            ball.pos[1] = height - ball.radius;
            ball.vel[1] = -ball.vel[1] * s.damping;
        }
    }
}

fn drawPanel(u: z.ui.Ui, f: *z.Frame, s: *State) void {
    // Phone-sized viewports get a wider, larger-text panel; the height follows the content.
    const viewport_width: f32 = f.window.widthf();
    const narrow: bool = z.ui.Ui.isNarrow(viewport_width);
    const panel_width: f32 = if (narrow) @min(340.0, viewport_width - 16.0) else 300.0;
    _ = u.scaleToViewport(panel_width, if (narrow) 30.0 else 22.0);
    u.setNextWindowPos(.{ 8, 8 }, .{ .once = true });
    u.setNextWindowSize(.{ panel_width, 0 }, .{});

    if (u.window("Controls", .{ .flags = .{ .always_auto_resize = true } })) |w| {
        defer w.close();

        u.text("click anywhere to spawn a ball", .{});
        u.separator();

        _ = u.slider("gravity (px/s^2)", &s.gravity, .{ .min = 0, .max = 2500 });
        _ = u.slider("damping", &s.damping, .{ .min = 0, .max = 1 });
        _ = u.slider("spawn radius", &s.spawn_radius, .{ .min = 4, .max = 48 });

        u.spacing();
        _ = u.checkbox("paused", &s.paused);
        u.sameLine(.{});
        _ = u.checkbox("show velocity", &s.show_velocity);

        u.spacing();
        u.separator();
        _ = u.colorEdit("background", &s.background, .{});

        u.spacing();
        if (u.button("clear", .{})) {
            s.balls.clearRetainingCapacity();
        }
        u.sameLine(.{});
        if (u.button("add 10", .{})) {
            for (0..10) |_| {
                const x: f32 = f.random.float(f32) * viewport_width;
                spawnBall(s, f.random, .{ x, 40 });
            }
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    // The canvas follows the browser window (`.responsive`), so read its size every frame.
    const width: f32 = f.window.widthf();
    const height: f32 = f.window.heightf();

    z.clearViewport(f, s.background);
    const u: z.ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Scene input comes before the panel is submitted. `wantCaptureMouse` also
    // checks last frame's windows, so a click on the panel still does not land here.
    const clicked_scene: bool = z.isMouseButtonPressed(f.input, .left) and !u.wantCaptureMouse();
    if (clicked_scene) {
        spawnBall(s, f.random, z.getMousePosition(f.input));
    }

    if (!s.paused) {
        stepBalls(s, @min(f.time.delta_time, max_step_seconds), width, height);
    }

    for (s.balls.items) |ball| {
        f.gl.circle(ball.pos, ball.radius, .{ .color = ball.color });
        if (s.show_velocity) {
            const tip: Vec2 = ball.pos + ball.vel * splat2(0.05);
            f.gl.line(ball.pos, tip, .{ .color = colors.white, .thickness = 2 });
        }
    }

    f.gl.textf(
        .{ 12, height - 28 },
        "balls: {d}    {s}",
        .{ s.balls.items.len, if (s.paused) "PAUSED" else "running" },
        .{ .size = 18, .color = colors.slate_400, .font = &s.font },
    );

    drawPanel(u, f, s);
}

/// Descriptor only: zimr's runner opens and closes the frame around `update`.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "myproject1 - bouncing balls",
            .width = 900,
            .height = 600,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
