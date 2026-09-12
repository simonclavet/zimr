// examples/input_virtual_controls.zig - on-screen D-pad that
// drives a player ball.  Works with touch on mobile, with mouse
// hold-and-drag on desktop.
// Port of raylib's `examples/core/core_input_virtual_controls.c`
// (★2, ~171 LOC).  Four buttons (UP/LEFT/RIGHT/DOWN) laid out in
// a cross.  Each frame:
//   - Sample the input position: prefer touch[0], fall back to
//     mouse position.
//   - If touching OR (mouse + left-button-held), find the
//     nearest button to the input position using a Manhattan-
//     distance threshold against the button radius.
//   - If a button is pressed, advance the player in that direction
//     by `player_speed * dt`.
// What this exercises:
//   - Touch-OR-mouse dual input: a real on-screen-controls pattern
//     for mobile games that gracefully degrades to mouse on desktop.
//   - Manhattan-distance hit test (|dx| + |dy| < r) - cheaper
//     than Euclidean for a "near enough" check, and matches what
//     raylib's source does literally.
//   - `z.drawTriangle` for the four D-pad arrows.
// Controls:
//   Touch screen / left-click-hold + drag the D-pad buttons to
//   move the player.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const button_radius: f32 = 30;
const player_radius: f32 = 50;
const player_speed: f32 = 75; // pixels/second
const pad_center: Vec2 = .{ 100, 350 };

const c = Color;

// D-pad button layout: 4 buttons arranged in a plus around the
// pad centre.  Distance from centre to each button = 1.5×
// button_radius, so adjacent buttons just barely don't touch.
const PadButton = enum(u8) {
    up = 0,
    left = 1,
    right = 2,
    down = 3,
};
const button_count: usize = 4;

const State = struct {
    font: z.Font,
    frame_count: usize = 0,
    /// Player ball position; starts at screen centre.
    player: Vec2 = .{ screen_w / 2, screen_h / 2 },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 32);
    s.* = .{ .font = font };
}

/// The four D-pad button centres, evaluated at comptime so we
/// don't recompute the layout each frame.
fn buttonPositions() [button_count]Vec2 {
    const off: f32 = button_radius * 1.5;
    return .{
        .{ pad_center[0], pad_center[1] - off }, // up
        .{ pad_center[0] - off, pad_center[1] }, // left
        .{ pad_center[0] + off, pad_center[1] }, // right
        .{ pad_center[0], pad_center[1] + off }, // down
    };
}

/// Build the three vertices of the arrow triangle for `btn`,
/// centred on its button position `bp`.  Triangle points in the
/// direction the button represents.
fn arrowTriangle(
    bp: Vec2,
    btn: PadButton,
) [3]Vec2 {
    // 12px in the pointing direction; 9px in the two side
    // directions.  Matches raylib's source numbers.
    return switch (btn) {
        .up => .{
            .{ bp[0], bp[1] - 12 },
            .{ bp[0] - 9, bp[1] + 9 },
            .{ bp[0] + 9, bp[1] + 9 },
        },
        .left => .{
            .{ bp[0] + 9, bp[1] - 9 },
            .{ bp[0] - 12, bp[1] },
            .{ bp[0] + 9, bp[1] + 9 },
        },
        .right => .{
            .{ bp[0] + 12, bp[1] },
            .{ bp[0] - 9, bp[1] - 9 },
            .{ bp[0] - 9, bp[1] + 9 },
        },
        .down => .{
            .{ bp[0] - 9, bp[1] - 9 },
            .{ bp[0], bp[1] + 12 },
            .{ bp[0] + 9, bp[1] - 9 },
        },
    };
}

/// Arrow label colour per direction.  Matches raylib's source:
/// yellow up, blue left, red right, green down.
fn arrowColor(btn: PadButton) Color {
    return switch (btn) {
        .up => c.yellow,
        .left => c.blue,
        .right => c.red,
        .down => c.green,
    };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;

    const button_positions: [4]Vec2 = buttonPositions();

    // ---- Sample input ----------------------------------------------------
    // Prefer touch (mobile); fall back to mouse (desktop).
    const touch_count: i32 = z.getTouchPointCount(f.input);
    const has_touch: bool = touch_count > 0;

    const input_pos: Vec2 = blk: {
        if (has_touch) {
            const tp: Vec2 = z.getTouchPosition(f.input, 0);
            break :blk .{ tp[0], tp[1] };
        }
        const mp: Vec2 = z.getMousePosition(f.input);
        break :blk .{ mp[0], mp[1] };
    };

    // Desktop users need to hold left mouse button; touch users
    // are already "pressing" by definition of having a touch.
    const input_active: bool = has_touch or z.isMouseButtonDown(f.input, .left);

    // ---- Resolve which button (if any) is being pressed ------------------
    var pressed: ?PadButton = null;
    if (input_active) {
        for (button_positions, 0..) |bp, i| {
            const dist_x: f32 = @abs(bp[0] - input_pos[0]);
            const dist_y: f32 = @abs(bp[1] - input_pos[1]);
            if ((dist_x + dist_y) < button_radius) {
                pressed = @fromBackingInt(@intCast(@as(u8, @intCast(i))));
                break;
            }
        }
    }

    // ---- Apply movement --------------------------------------------------
    const dt: f32 = @floatCast(f.time.delta_time);
    const step: f32 = player_speed * dt;
    if (pressed) |btn| {
        switch (btn) {
            .up => state.player[1] -= step,
            .down => state.player[1] += step,
            .left => state.player[0] -= step,
            .right => state.player[0] += step,
        }
    }

    // ---- Render ----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    // World: just the player ball.
    f.gl.circle(state.player, player_radius, .{ .color = c.maroon, .segments = 16 });

    // GUI: 4 D-pad buttons.  Active button gets a slightly lighter
    // fill so the user can see which one they're pressing.
    for (button_positions, 0..) |bp, i| {
        const i_btn: u8 = @intCast(i);
        const is_pressed: bool = (pressed != null) and (@backingInt(pressed.?) == i_btn);
        const fill: Color = if (is_pressed) c.darkgray else c.black;
        f.gl.circle(bp, button_radius, .{ .color = fill, .segments = 16 });

        const btn: PadButton = @fromBackingInt(@intCast(i_btn));
        const tris: [3]Vec2 = arrowTriangle(bp, btn);
        f.gl.triangle(tris[0], tris[1], tris[2], .{ .color = arrowColor(btn) });
    }

    f.gl.text(
        .{ 10, 10 },
        "move the player with D-Pad buttons",
        .{ .size = 20, .color = c.darkgray, .font = &state.font },
    );
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - input virtual controls",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
