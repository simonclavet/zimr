// examples/input_mouse.zig - ball-follows-cursor with all seven
// mouse buttons mapped to different ball colours, plus cursor
// visibility toggle.
// Port of raylib's `examples/core/core_input_mouse.c` (*1,
// ~81 LOC).  Validates that every distinct mouse button raylib
// exposes (left/middle/right/side/extra/forward/back) is
// distinguishable as a separate event, and that the OS cursor
// can be hidden + restored at runtime.
// Notes on browser support:
//   In a desktop browser, buttons 0/1/2 (left/middle/right) are
//   universally supported.  Buttons 3+ (the "side" thumb buttons
//   on a 5-button mouse) come through as `mousedown` events with
//   `event.button === 3, 4, ...` on Chrome/Firefox/Safari but
//   their mapping to raylib's `side / extra / forward / back`
//   isn't standardised - different browsers and OSes label them
//   differently.  This demo just lets you see *which* index
//   fires for *which* physical button on your setup.
//   On a trackpad or two-button mouse, the side buttons simply
//   never fire.  That's fine - left/middle/right still work and
//   demonstrate the rising-edge detection.
// What this exercises:
//   - `z.isMouseButtonPressed` for all 7 button variants.
//   - `z.showCursor` / `hideCursor` / `isCursorHidden`.
//   - Mouse position bridge: `Vec2 -> Vec2` via the inline
//     `.{ mp.x, mp.y }` pattern.
// Controls:
//   Mouse position      moves the ball
//   Left click          ball -> maroon
//   Middle click        ball -> lime
//   Right click         ball -> dark blue (default)
//   Side / back / etc.  see notes above; varies by hardware
//   H                   toggle cursor visibility

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const ball_radius: f32 = 40;

const c = Color;

const State = struct {
    /// Owned shapes-texture state.  Default-init points at rlgl's
    /// internal 1x1 white pixel (texture id=1) - no upload needed.
    /// Owned default-font cache.  Populated by `z.loadFontFromTtfBytes`
    /// in `initState` below.
    font: z.Font,
    frame_count: usize = 0,
    /// Cursor-tracking ball position.  Off-screen at start so the
    /// first frame doesn't flash the ball at (0, 0) before the
    /// mouse has been positioned.
    pos: Vec2 = .{ -100, -100 },
    /// Current ball colour; defaults to dark blue per raylib's
    /// source.  Changed by mouse-button rising-edges below.
    color: Color = c.darkblue,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;

    // ---- Cursor visibility toggle ----------------------------------------
    if (z.isKeyPressed(f.input, .h)) {
        if (z.isCursorHidden(f.input)) {
            z.showCursor(f.input);
        } else {
            z.hideCursor(f.input);
        }
    }

    // ---- Mouse position -> ball position ---------------------------------
    const mp: Vec2 = z.getMousePosition(f.input);
    state.pos = .{ mp[0], mp[1] };

    // ---- Button -> colour mapping.  Each is a rising-edge so the
    // colour sticks until the next click.
    if (z.isMouseButtonPressed(f.input, .left)) {
        state.color = c.maroon;
    } else if (z.isMouseButtonPressed(f.input, .middle)) {
        state.color = c.lime;
    } else if (z.isMouseButtonPressed(f.input, .right)) {
        state.color = c.darkblue;
    } else if (z.isMouseButtonPressed(f.input, .side)) {
        state.color = c.purple;
    } else if (z.isMouseButtonPressed(f.input, .extra)) {
        state.color = c.yellow;
    } else if (z.isMouseButtonPressed(f.input, .forward)) {
        state.color = c.orange;
    } else if (z.isMouseButtonPressed(f.input, .back)) {
        state.color = c.beige;
    }

    // ---- Render ----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    f.gl.circle(state.pos, ball_radius, .{ .color = state.color, .segments = 16 });

    f.gl.text(
        .{ 10, 10 },
        "move ball with mouse and click mouse button to change color",
        .{ .size = 20, .color = c.darkgray, .font = &state.font },
    );
    f.gl.text(
        .{ 10, 30 },
        "Press 'H' to toggle cursor visibility",
        .{ .size = 20, .color = c.darkgray, .font = &state.font },
    );

    if (z.isCursorHidden(f.input)) {
        f.gl.text(.{ 20, 60 }, "CURSOR HIDDEN", .{ .size = 20, .color = c.red, .font = &state.font });
    } else {
        f.gl.text(.{ 20, 60 }, "CURSOR VISIBLE", .{ .size = 20, .color = c.lime, .font = &state.font });
    }
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - input mouse",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
