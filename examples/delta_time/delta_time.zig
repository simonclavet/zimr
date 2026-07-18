// examples/delta_time.zig - frame-rate-independent motion via delta time.
// Ports raylib's core delta-time idea: a ball crosses the screen at a CONSTANT
// real-world speed (pixels per second) by scaling its step by the frame time
// (raylib's GetFrameTime; here `f.time.delta_time`). It therefore covers the
// same distance every second whether the frame runs at 30 or 144 fps. A HUD
// shows the live frame time, a smoothed FPS, and total elapsed time.
//
// What this exercises:
//   - `f.time.delta_time` / `f.time.time` from the frame's TimeState.
//   - Frame-independent integration: `pos += vel * dt` (never `pos += vel`).
//
// Leak-clean (`.memory = .managed`): only the font is allocated and it is
// engine-owned (freed by resetRegistry), so `deinit` is a no-op.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;
const bufPrint = std.fmt.bufPrint;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const ball_r: f32 = 30.0;
const ball_speed: f32 = 260.0; // pixels per SECOND (not per frame)

const State = struct {
    font: z.Font,
    x: f32 = ball_r,
    dir: f32 = 1.0,
    fps_smooth: f32 = 60.0, // exponentially smoothed so the readout doesn't flicker
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 20);
    s.* = .{ .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = f.time.delta_time;
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();

    // Frame-independent motion: distance = speed * time, so the ball covers
    // `ball_speed` px every real second regardless of frame rate. Bounce at the
    // edges.
    s.x += s.dir * ball_speed * dt;
    if (s.x > sw - ball_r) {
        s.x = sw - ball_r;
        s.dir = -1.0;
    }
    if (s.x < ball_r) {
        s.x = ball_r;
        s.dir = 1.0;
    }

    if (dt > 0.0) {
        const inst_fps: f32 = 1.0 / dt;
        s.fps_smooth += (inst_fps - s.fps_smooth) * 0.1;
    }

    z.clearViewport(f, c.raywhite);

    f.gl.circle(.{ s.x, sh * 0.5 }, ball_r, .{ .color = c.maroon });

    var buf: [64]u8 = undefined;
    const fps_txt: []const u8 = bufPrint(&buf, "{d:.0} FPS", .{s.fps_smooth}) catch "?";
    f.gl.text(.{ 20, 20 }, fps_txt, .{ .size = 20, .color = c.darkgray, .font = &s.font });

    var buf2: [64]u8 = undefined;
    const ft_txt: []const u8 = bufPrint(&buf2, "frame time: {d:.2} ms", .{dt * 1000.0}) catch "?";
    f.gl.text(.{ 20, 46 }, ft_txt, .{ .size = 20, .color = c.darkgray, .font = &s.font });

    var buf3: [64]u8 = undefined;
    const t_txt: []const u8 = bufPrint(&buf3, "elapsed: {d:.1} s", .{f.time.time}) catch "?";
    f.gl.text(.{ 20, 72 }, t_txt, .{ .size = 20, .color = c.darkgray, .font = &s.font });

    f.gl.text(
        .{ 20, sh - 40.0 },
        "Ball crosses at a constant speed (px/sec) - frame-rate independent.",
        .{ .size = 18, .color = c.gray, .font = &s.font },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - delta time",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .fit,
            .clear = .{ .r = 245.0 / 255.0, .g = 245.0 / 255.0, .b = 245.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
