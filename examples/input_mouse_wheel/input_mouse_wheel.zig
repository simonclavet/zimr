// examples/input_mouse_wheel.zig - mouse-wheel-controlled box,
// the entire demo.
// Port of raylib's `examples/core/core_input_mouse_wheel.c`
// (*1, ~64 LOC).  Smallest possible demo of `getMouseWheelMove`:
// each notch moves a box four pixels.  Tests that the wheel
// delta is sampled per-frame correctly (not accumulated across
// frames, not lost when the user spins fast).
// What this exercises:
//   - `z.getMouseWheelMove` - returns a float wheel delta
//     for the most recent frame.  On most setups one notch ~ +/-1.
//     Touchpads on macOS can return fractional values for
//     "smooth scrolling".
// Controls:
//   Mouse wheel    move the box vertically (positive = up; the
//                  raylib convention has Y growing downward on
//                  screen but wheel-up moves the box up, so the
//                  delta is *subtracted* from box_y)

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const box_size: i32 = 80;
/// Pixels moved per wheel notch.  raylib's source uses 4.
const scroll_speed: i32 = 4;

const c = Color;

const State = struct {
    /// Owned shapes-texture state.  Default-init points at rlgl's
    /// internal 1x1 white pixel (texture id=1) - no upload needed.
    /// Owned default-font cache.  Populated by `z.loadFontFromTtfBytes`
    /// in `initState` below.
    font: z.Font,
    frame_count: usize = 0,
    /// Y position of the box (top edge).  Initial position
    /// vertically-centred minus half the box height - matches
    /// raylib's source.
    box_y: i32 = @divFloor(screen_h, 2) - @divFloor(box_size, 2),
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

    // Wheel delta this frame.  Subtract so wheel-up makes the box
    // visually move up.  Use the float->int truncation that raylib's
    // source does - wheel delta is float, box position is int.
    const wheel: f32 = z.getMouseWheelMove(f.input);
    const delta_pixels: i32 = @trunc(wheel * float(scroll_speed));
    state.box_y -= delta_pixels;

    // ---- Render ----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    const box_x: i32 = @divFloor(screen_w, 2) - @divFloor(box_size, 2);
    f.gl.rect(
        .{ .x = float(box_x), .y = float(state.box_y), .width = float(box_size), .height = float(box_size) },
        .{ .color = c.maroon },
    );

    f.gl.text(
        .{ 10, 10 },
        "Use mouse wheel to move the cube up and down!",
        .{ .size = 20, .color = c.gray, .font = &state.font },
    );

    var buf: [64]u8 = undefined;
    const msg: []const u8 = bufPrint(&buf, "Box position Y: {d:0>3}", .{state.box_y}) catch "Box position Y: ?";
    f.gl.text(.{ 10, 40 }, msg, .{ .size = 20, .color = c.lightgray, .font = &state.font });
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - input mouse wheel",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
