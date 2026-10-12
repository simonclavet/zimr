//! input_pointer_lock - turning a view with the mouse, as a first-person camera does, and what the engine reports
//! about the pointer while it does.
//!
//! A click asks for the pointer lock (`z.disableCursor`). Once the platform grants it, the cursor is hidden and held
//! still, and the mouse's own motion keeps coming: `z.getMouseDelta` is how far the hand moved this frame, while the
//! position stands still. Summed frame after frame, the motion turns the view - a heading (yaw) and a tilt (pitch),
//! in degrees - shown here as a compass strip and a horizon around a crosshair. Escape releases the lock
//! (`z.enableCursor`); so does the window losing focus, and in a browser so does the user's own Escape.
//!
//! The panel shows what the engine knows: whether the lock holds (`z.isPointerLocked`, as the platform last reported
//! it), whether the pointer is over the window (`z.isCursorOnScreen`), whether the window has the keyboard's focus
//! (`f.window.focused`), the frame's mouse delta, and the position.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// How far the view turns per logical pixel of mouse motion, in degrees.
const degrees_per_pixel: f32 = 0.15;
/// How many logical pixels on screen one degree of heading or tilt spans.
const pixels_per_degree: f32 = 6;
/// The tilt stops short of straight up and straight down.
const pitch_limit: f32 = 80;

const sky: Color = .{ .r = 30, .g = 41, .b = 59, .a = 255 };
const ground: Color = .{ .r = 41, .g = 37, .b = 36, .a = 255 };
const horizon_color: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };
const tick_color: Color = .{ .r = 203, .g = 213, .b = 225, .a = 255 };
const crosshair_color: Color = .{ .r = 250, .g = 204, .b = 21, .a = 255 };
const text_color: Color = .{ .r = 226, .g = 232, .b = 240, .a = 255 };
const dim_color: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };

const State = struct {
    font: z.Font,
    /// The view's heading, in degrees from north, kept in 0..360; and its tilt, positive looking up.
    yaw: f32 = 0,
    pitch: f32 = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18) };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

/// The name of a heading that is a multiple of 45 degrees, or null.
fn compassName(heading: i32) ?[]const u8 {
    return switch (@mod(heading, 360)) {
        0 => "N",
        45 => "NE",
        90 => "E",
        135 => "SE",
        180 => "S",
        225 => "SW",
        270 => "W",
        315 => "NW",
        else => null,
    };
}

/// The view: ground below the horizon, which rises as the view tilts down; heading ticks every 15 degrees along it,
/// sliding as the view turns; and the crosshair at the centre.
fn drawView(f: *z.Frame, s: *State, width: f32, height: f32) void {
    const center_x: f32 = width / 2;
    const center_y: f32 = height / 2;
    const horizon_y: f32 = center_y + s.pitch * pixels_per_degree;
    f.gl.rect(.{ .x = 0, .y = 0, .width = width, .height = height }, .{ .color = sky });
    if (horizon_y < height) {
        const ground_top: f32 = @max(horizon_y, 0);
        f.gl.rect(.{ .x = 0, .y = ground_top, .width = width, .height = height - ground_top }, .{ .color = ground });
    }
    f.gl.rect(.{ .x = 0, .y = horizon_y - 1, .width = width, .height = 2 }, .{ .color = horizon_color });
    // The headings in view, every 15 degrees: a heading `h` sits (h - yaw) degrees right of the centre.
    const half_span: f32 = width / 2 / pixels_per_degree;
    const first_step: i32 = @floor((s.yaw - half_span) / 15);
    const last_step: i32 = @ceil((s.yaw + half_span) / 15);
    var step: i32 = first_step;
    while (step <= last_step) : (step += 1) {
        const heading: i32 = step * 15;
        const x: f32 = center_x + (float(heading) - s.yaw) * pixels_per_degree;
        const name: ?[]const u8 = compassName(heading);
        const tick_height: f32 = if (name != null) 24 else 12;
        const tick: z.Rectangle = .{ .x = x - 1, .y = horizon_y - tick_height, .width = 2, .height = tick_height };
        f.gl.rect(tick, .{ .color = tick_color });
        if (name) |label| {
            const label_position: [2]f32 = .{ x - 6, horizon_y - tick_height - 24 };
            f.gl.text(label_position, label, .{ .size = 18, .color = tick_color, .font = &s.font });
        }
    }
    f.gl.rect(.{ .x = center_x - 12, .y = center_y - 1, .width = 24, .height = 2 }, .{ .color = crosshair_color });
    f.gl.rect(.{ .x = center_x - 1, .y = center_y - 12, .width = 2, .height = 24 }, .{ .color = crosshair_color });
}

/// One line of the panel: a label and its value.
fn panelLine(
    f: *z.Frame,
    s: *State,
    row: usize,
    label: []const u8,
    value: []const u8,
) void {
    const y: f32 = 44 + float(row) * 24;
    f.gl.text(.{ 16, y }, label, .{ .size = 16, .color = dim_color, .font = &s.font });
    f.gl.text(.{ 250, y }, value, .{ .size = 16, .color = text_color, .font = &s.font });
}

fn update(f: *z.Frame, s: *State) void {
    const is_locked: bool = z.isPointerLocked(f.input);
    if (!is_locked and z.isMouseButtonPressed(f.input, .left)) {
        z.disableCursor(f.input);
    }
    if (is_locked and z.isKeyPressed(f.input, .escape)) {
        z.enableCursor(f.input);
    }
    const delta: Vec2 = z.getMouseDelta(f.input);
    if (is_locked) {
        // Moving the mouse right turns the view right; moving it forward, away from the hand, tilts the view up.
        s.yaw = @mod(s.yaw + delta[0] * degrees_per_pixel, 360);
        s.pitch = clamp(s.pitch - delta[1] * degrees_per_pixel, -pitch_limit, pitch_limit);
    }
    const width: f32 = f.window.widthf();
    const height: f32 = f.window.heightf();
    drawView(f, s, width, height);

    const lock_text: []const u8 = if (is_locked) "held - Escape releases it" else "not held - click to lock";
    panelLine(f, s, 0, "pointer lock", lock_text);
    panelLine(f, s, 1, "pointer over the window", if (z.isCursorOnScreen(f.input)) "yes" else "no");
    panelLine(f, s, 2, "window has focus", if (f.window.focused) "yes" else "no");
    const delta_text: z.Str(48) = .print("{d:.1}, {d:.1}", .{ delta[0], delta[1] });
    panelLine(f, s, 3, "mouse delta this frame", delta_text.slice());
    const position: Vec2 = z.getMousePosition(f.input);
    const position_text: z.Str(48) = .print("{d:.0}, {d:.0}", .{ position[0], position[1] });
    panelLine(f, s, 4, "mouse position", position_text.slice());
    const view_text: z.Str(48) = .print("heading {d:.0}, tilt {d:.0}", .{ s.yaw, s.pitch });
    panelLine(f, s, 5, "view", view_text.slice());
    common.caption(f.gl, s.font, "input_pointer_lock: click to lock the pointer, move to turn, Escape to release");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - core - input pointer lock",
            .width = 900,
            .height = 600,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
