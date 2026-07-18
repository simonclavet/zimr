// examples/easings_testbed.zig - interactive testbed for trying
// every easing curve on a 2D ball trajectory.
// Port of raylib's `examples/shapes/shapes_easings_testbed.c` (★3,
// ~247 LOC).  Pick an easing for X, pick another for Y, hit ENTER,
// watch a ball traverse the screen with the chosen curves.
// raylib's original used a typedef'd function table with the
// 4-arg `Ease(t, b, c, d)` signature.  We do the same idea with
// Zig's first-class function pointers + the [0,1]-form curves
// from `src/easings.zig`, which means the lerp lives at the
// call site instead of inside every easing fn.
// raylib also exposes four `Linear*` aliases (None, In, Out, InOut)
// that are all the identity function.  We collapse them to one
// `Linear`; the testbed simply has one fewer entry.
// Controls:
//   ←  →    cycle the X-axis easing (wraps; "None" is the last entry)
//   ↑  ↓    cycle the Y-axis easing (wraps)
//   ENTER   play/pause the ball's motion
//   SPACE   restart from frame 0 (also fires automatically when
//           you change a setting)
//   T       toggle bounded-time mode (default ON; OFF lets t keep
//           growing past the duration so you can watch what the
//           curve does extrapolating into the future)
//   Q  W    decrease / increase the duration by 20 frames
//   A  S    decrease / increase the duration by 2 frames (fine)
// The ball traverses from (100, 100) to (700, 400) over `d` frames.
// HUD shows the current easing names + (t, d) values.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const Color = zm.Color;
const clamp = zm.clamp;
const float = zm.float;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const font_size: i32 = 20;
const d_step: f32 = 20;
const d_step_fine: f32 = 2;
const d_min: f32 = 1;
const d_max: f32 = 10000;
const ball_radius: f32 = 16;
const ball_start: Vec2 = .{ 100, 100 };
const ball_end: Vec2 = .{ 700, 400 };

const c = Color;

const EaseFn = *const fn (f32) f32;

const EaseEntry = struct {
    name: []const u8,
    func: EaseFn,
};

/// No-easing identity used for the "None" entry - the ball stays
/// at the start position on this axis.  Implemented as a static
/// fn so we can put a pointer to it in the table.
fn noEase(_: f32) f32 {
    return 0;
}

// Function table.  Order matches raylib's source (modulo the
// collapsed Linear aliases).  Last entry is the "None" sentinel
// that pins the axis to its start value.
const easings_table = [_]EaseEntry{
    .{ .name = "Linear", .func = z.easeLinear },
    .{ .name = "SineIn", .func = z.easeSineIn },
    .{ .name = "SineOut", .func = z.easeSineOut },
    .{ .name = "SineInOut", .func = z.easeSineInOut },
    .{ .name = "CircIn", .func = z.easeCircIn },
    .{ .name = "CircOut", .func = z.easeCircOut },
    .{ .name = "CircInOut", .func = z.easeCircInOut },
    .{ .name = "CubicIn", .func = z.easeCubicIn },
    .{ .name = "CubicOut", .func = z.easeCubicOut },
    .{ .name = "CubicInOut", .func = z.easeCubicInOut },
    .{ .name = "QuadIn", .func = z.easeQuadIn },
    .{ .name = "QuadOut", .func = z.easeQuadOut },
    .{ .name = "QuadInOut", .func = z.easeQuadInOut },
    .{ .name = "ExpoIn", .func = z.easeExpoIn },
    .{ .name = "ExpoOut", .func = z.easeExpoOut },
    .{ .name = "ExpoInOut", .func = z.easeExpoInOut },
    .{ .name = "BackIn", .func = z.easeBackIn },
    .{ .name = "BackOut", .func = z.easeBackOut },
    .{ .name = "BackInOut", .func = z.easeBackInOut },
    .{ .name = "BounceOut", .func = z.easeBounceOut },
    .{ .name = "BounceIn", .func = z.easeBounceIn },
    .{ .name = "BounceInOut", .func = z.easeBounceInOut },
    .{ .name = "ElasticIn", .func = z.easeElasticIn },
    .{ .name = "ElasticOut", .func = z.easeElasticOut },
    .{ .name = "ElasticInOut", .func = z.easeElasticInOut },
    .{ .name = "None", .func = noEase },
};

const easing_none_idx: usize = easings_table.len - 1;

/// Names of every easing in `easings_table`, for the combo box. Built at
/// comptime so the panel and the table can never drift.
const easing_names: [easings_table.len][]const u8 = blk: {
    var names: [easings_table.len][]const u8 = undefined;
    for (easings_table, 0..) |e, i| {
        names[i] = e.name;
    }
    break :blk names;
};

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    /// Owned shapes-texture state. id=1 → rlgl's internal 1x1 white pixel.
    /// Owned default-font cache. Populated by `loadFontFromTtfBytes` below.
    frame_count: usize = 0,
    /// Current animation time in frames (matches raylib's `t`).
    t: f32 = 0,
    /// Total animation duration in frames.
    duration: f32 = 300,
    /// True = animation halts at t == duration; False = t keeps
    /// growing forever.
    bounded_t: bool = true,
    /// True = paused (waiting for ENTER).  Default true so the
    /// user sees the start state before motion begins.
    paused: bool = false,
    /// Indices into `easings_table` for the X-axis and Y-axis curves.
    ease_x: usize = 0, // Linear (was None — gives an immediately visible demo)
    ease_y: usize = 23, // ElasticOut
    /// Current ball position (lerped per frame).
    ball: Vec2 = ball_start,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

/// Draw one line of bottom-of-screen help text in the testbed's
/// shared style (left-aligned at x=20, light grey, font_size).
fn drawHelpLine(
    f: *z.Frame,
    font: z.Font,
    msg: []const u8,
    y: f32,
) void {
    f.gl.text(.{ 20, y }, msg, .{ .size = font_size, .color = c.darkgray, .font = &font });
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;
    const dt: f32 = @floatCast(f.time.delta_time);
    const tick: f32 = dt * 60.0;

    // ---- Input - settings that trigger a restart
    var triggered_restart: bool = false;

    if (z.isKeyPressed(f.input, .t)) {
        state.bounded_t = !state.bounded_t;
        triggered_restart = true;
    }

    if (z.isKeyPressed(f.input, .right)) {
        state.ease_x = (state.ease_x + 1) % easings_table.len;
        triggered_restart = true;
    } else if (z.isKeyPressed(f.input, .left)) {
        state.ease_x = if (state.ease_x == 0) easing_none_idx else state.ease_x - 1;
        triggered_restart = true;
    }

    if (z.isKeyPressed(f.input, .down)) {
        state.ease_y = (state.ease_y + 1) % easings_table.len;
        triggered_restart = true;
    } else if (z.isKeyPressed(f.input, .up)) {
        state.ease_y = if (state.ease_y == 0) easing_none_idx else state.ease_y - 1;
        triggered_restart = true;
    }

    // Duration controls: Q/W coarse (20 frames), A/S fine (2 frames).
    if (z.isKeyPressed(f.input, .w) and state.duration < d_max - d_step) {
        state.duration += d_step;
        triggered_restart = true;
    } else if (z.isKeyPressed(f.input, .q) and state.duration > d_min + d_step) {
        state.duration -= d_step;
        triggered_restart = true;
    }
    if (z.isKeyDown(f.input, .s) and state.duration < d_max - d_step_fine) {
        state.duration += d_step_fine;
        triggered_restart = true;
    } else if (z.isKeyDown(f.input, .a) and state.duration > d_min + d_step_fine) {
        state.duration -= d_step_fine;
        triggered_restart = true;
    }

    // SPACE = restart; ENTER on already-finished bounded-mode also restarts.
    const space_restart: bool = z.isKeyPressed(f.input, .space);
    const enter_at_end: bool =
        z.isKeyPressed(f.input, .enter) and state.bounded_t and state.t >= state.duration;

    if (triggered_restart or space_restart or enter_at_end) {
        state.t = 0;
        state.ball = ball_start;
        state.paused = true;
    }

    // ENTER toggles play/pause.
    if (z.isKeyPressed(f.input, .enter) and !enter_at_end) {
        state.paused = !state.paused;
    }

    // ---- Update - advance the animation if running
    const should_advance: bool = blk: {
        if (state.paused) {
            break :blk false;
        }
        // Bounded mode halts at t == duration; unbounded keeps growing.
        if (state.bounded_t and state.t >= state.duration) {
            break :blk false;
        }
        break :blk true;
    };

    if (should_advance) {
        const t01: f32 = clamp(state.t / state.duration, 0, 1);
        const ease_x: EaseFn = easings_table[state.ease_x].func;
        const ease_y: EaseFn = easings_table[state.ease_y].func;
        state.ball[0] = ball_start[0] + ease_x(t01) * (ball_end[0] - ball_start[0]);
        state.ball[1] = ball_start[1] + ease_y(t01) * (ball_end[1] - ball_start[1]);
        state.t += tick;
    }

    // ---- Render ----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    // Top-left info block.
    var buf: [128]u8 = undefined;
    f.gl.text(
        .{ 20, font_size },
        bufPrint(&buf, "Easing x: {s}", .{easings_table[state.ease_x].name}) catch "x",
        .{ .size = font_size, .color = c.darkgray, .font = &state.font },
    );
    f.gl.text(
        .{ 20, font_size * 2 },
        bufPrint(&buf, "Easing y: {s}", .{easings_table[state.ease_y].name}) catch "y",
        .{ .size = font_size, .color = c.darkgray, .font = &state.font },
    );
    const bound_marker: u8 = if (state.bounded_t) 'b' else 'u';
    f.gl.text(
        .{ 20, font_size * 3 },
        bufPrint(&buf, "t ({c}) = {d:.2}   d = {d:.2}", .{ bound_marker, state.t, state.duration }) catch "t",
        .{ .size = font_size, .color = c.darkgray, .font = &state.font },
    );

    // Bottom help text.  Stacked from the bottom so the most
    // useful line (LEFT/RIGHT) is closest to the action area.
    const bottom_line_y: i32 = screen_h - font_size * 2;
    drawHelpLine(
        f,
        state.font,
        "Use ENTER to play or pause movement, use SPACE to restart",
        float(bottom_line_y),
    );
    drawHelpLine(
        f,
        state.font,
        "Use Q and W or A and S keys to change duration",
        float(bottom_line_y - font_size),
    );
    drawHelpLine(
        f,
        state.font,
        "Use LEFT or RIGHT keys to choose easing for the x axis",
        float(bottom_line_y - font_size * 2),
    );
    drawHelpLine(
        f,
        state.font,
        "Use UP or DOWN keys to choose easing for the y axis",
        float(bottom_line_y - font_size * 3),
    );

    f.gl.circle(state.ball, ball_radius, .{ .color = c.maroon, .segments = 16 });

    // Touch controls: the keyboard shortcuts (arrows/Q/W/A/S/ENTER/SPACE) still
    // work on desktop; this panel gives phones a way to drive the testbed.
    const u: z.ui_real.Ui = state.ui_host.begin(f);
    if (u.window("Easings", .{ .initial_pos = .{ 14, 14 }, .initial_size = .{ 250, 230 } })) |w| {
        defer w.close();
        var ix: i32 = @intCast(state.ease_x);
        if (u.combo("X axis", &ix, &easing_names, .{})) {
            state.ease_x = @intCast(ix);
        }
        var iy: i32 = @intCast(state.ease_y);
        if (u.combo("Y axis", &iy, &easing_names, .{})) {
            state.ease_y = @intCast(iy);
        }
        _ = u.slider("duration", &state.duration, .{ .min = 30, .max = 600, .fmt = "{d:.0}" });
        if (u.button(if (state.paused) "play" else "pause", .{})) {
            state.paused = !state.paused;
        }
        u.sameLine(.{});
        if (u.button("restart", .{})) {
            state.t = 0;
            state.ball = ball_start;
        }
    }
    state.ui_host.render(f);

    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - easings testbed",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
