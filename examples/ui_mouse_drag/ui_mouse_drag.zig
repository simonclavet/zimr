// examples/ui_mouse_drag.zig - B1 capstone.
// Demonstrates the new mouse cursor + drag helpers added in
// `imgui-parity` Phase B1:
//   - `u.setMouseCursor(cursor)` - change the CSS cursor when
//     hovering specific widgets.
//   - `u.isMouseDragging(.left, -1)` - distinguish click from
//     drag with imgui's default 6 px threshold.
//   - `u.getMouseDragDelta(.left, -1)` + `resetMouseDragDelta`
//     consume per-frame delta to move a widget around.
//   - `u.isMouseHoveringRect(x0, y0, x1, y1)` - hit-test
//     arbitrary rectangles outside the standard widget pipeline.
// Layout:
//   - Top row: six colored zones labeled with cursor names.  Hover
//     each to see the canvas cursor change.
//   - Middle: a square that follows your mouse while you drag it.
//     Drag from elsewhere does nothing - the threshold + hover
//     check gate engagement.
//   - Bottom: live readout of mouse pos, button state, drag state.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const ui = z.ui_real;

const Color = zm.Color;

const CursorZone = struct {
    label: []const u8,
    cursor: ui.MouseCursor,
    color: Color,
};

const cursor_zones = [_]CursorZone{
    .{ .label = "default", .cursor = .default, .color = .{ .r = 71, .g = 85, .b = 105, .a = 255 } },
    .{ .label = "pointing_hand", .cursor = .pointing_hand, .color = .{ .r = 14, .g = 165, .b = 233, .a = 255 } },
    .{ .label = "ibeam", .cursor = .ibeam, .color = .{ .r = 168, .g = 85, .b = 247, .a = 255 } },
    .{ .label = "crosshair", .cursor = .crosshair, .color = .{ .r = 244, .g = 114, .b = 182, .a = 255 } },
    .{ .label = "resize_ew", .cursor = .resize_ew, .color = .{ .r = 251, .g = 146, .b = 60, .a = 255 } },
    .{ .label = "resize_ns", .cursor = .resize_ns, .color = .{ .r = 132, .g = 204, .b = 22, .a = 255 } },
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    // Position of the draggable square.  Stays put except while the
    // user is dragging it; the runtime never touches it.
    draggable_pos: Vec2 = .{ 80, 220 },
    // While true, this frame's mouse-drag delta is being consumed by
    // the draggable.  Latched on mouse-down inside the rect, cleared
    // on mouse-up.  Without this gate, releasing-and-reclicking
    // anywhere on the canvas would teleport the square.
    dragging_square: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
    };
}

/// Brighten a color by `amount` (0-255), clamping each channel at 255.
/// Used for hover-highlight feedback.
fn brightenColor(c: Color, amount: u8) Color {
    return .{
        .r = if (@as(u16, c.r) + amount > 255) 255 else c.r + amount,
        .g = if (@as(u16, c.g) + amount > 255) 255 else c.g + amount,
        .b = if (@as(u16, c.b) + amount > 255) 255 else c.b + amount,
        .a = c.a,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const u: ui.Ui = s.ui_host.begin(f);

    z.clearViewport(f, .{ .r = 15, .g = 23, .b = 42, .a = 255 });

    const sw: i32 = @intCast(f.window.screen_width);
    const sh: f32 = float(f.window.screen_height);

    const white: Color = .{ .r = 241, .g = 245, .b = 249, .a = 255 };
    const dim: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };
    const accent: Color = .{ .r = 245, .g = 158, .b = 11, .a = 255 };

    // Header.
    f.gl.text(.{ 24, 22 }, "mouse cursor + drag helpers", .{ .size = 20, .color = white, .font = &s.font });
    f.gl.text(
        .{ 24, 54 },
        "hover the zones to change cursor; drag the orange square to move it.",
        .{ .size = 12, .color = dim, .font = &s.font },
    );

    // Top row: cursor zones.  Hover-test each rect; the FIRST hit
    // wins (in case zones overlap - they don't here but the pattern
    // is correct).  Set cursor to .default when nothing claims it.
    const zone_y: f32 = 90;
    const zone_h: f32 = 80;
    const zone_count: i32 = @intCast(cursor_zones.len);
    const total_pad: i32 = 48 + 8 * (zone_count - 1);
    const zone_w: i32 = @divFloor(sw - total_pad, zone_count);
    var cursor_for_this_frame: z.MouseCursor = .default;

    var i: usize = 0;
    while (i < cursor_zones.len) : (i += 1) {
        const zone: CursorZone = cursor_zones[i];
        const x: f32 = float(24 + @as(i32, @intCast(i)) * (zone_w + 8));
        const w: f32 = float(zone_w);
        const rect: z.Rectangle = .{ .x = x, .y = zone_y, .width = w, .height = zone_h };

        const hovered: bool = u.isMouseHoveringRect(rect.x, rect.y, rect.x + rect.width, rect.y + rect.height);
        const fill: Color = if (hovered) brightenColor(zone.color, 30) else zone.color;
        f.gl.rect(rect, .{ .color = fill });

        if (hovered) {
            cursor_for_this_frame = zone.cursor;
        }

        // Centred label.  Atkinson at 12 px ~ 7 px advance per char;
        // crude but adequate for this demo.
        const label_w: i32 = @intCast(zone.label.len * 7);
        const lx: f32 = x + float(@divFloor(zone_w - label_w, 2));
        const ly: f32 = zone_y + 32;
        f.gl.text(.{ lx, ly }, zone.label, .{ .size = 12, .color = white, .font = &s.font });
    }

    // Middle: draggable square.  Hit-test with isMouseHoveringRect;
    // latch the dragging state on left-press inside the rect, clear
    // it on left-release.  Consume the per-frame delta and reset
    // the anchor so subsequent deltas are incremental.
    const square_size: f32 = 64;
    const sx: f32 = s.draggable_pos[0];
    const sy: f32 = s.draggable_pos[1];
    const square_rect: z.Rectangle = .{ .x = sx, .y = sy, .width = square_size, .height = square_size };
    const square_hovered: bool = u.isMouseHoveringRect(sx, sy, sx + square_size, sy + square_size);

    if (square_hovered and !s.dragging_square) {
        cursor_for_this_frame = .resize_all;
    }

    if (f.input.mouse.current_button[0] != 0 and square_hovered and !s.dragging_square) {
        // Rising edge of a left-press inside the square - capture it.
        s.dragging_square = true;
    } else if (f.input.mouse.current_button[0] == 0) {
        // Released - drop the latch.
        s.dragging_square = false;
    }

    if (s.dragging_square) {
        cursor_for_this_frame = .resize_all;
        const d: Vec2 = u.getMouseDragDelta(.left, -1);
        if (d[0] != 0 or d[1] != 0) {
            s.draggable_pos[0] += d[0];
            s.draggable_pos[1] += d[1];
            u.resetMouseDragDelta(.left);
        }
    }

    f.gl.rect(square_rect, .{ .color = accent });
    f.gl.text(.{ sx + 8, sy + 26 }, "drag me", .{ .size = 12, .color = white, .font = &s.font });

    // Apply the chosen cursor exactly once at the end of the frame.
    // Doing it here (rather than inside each hover branch) means
    // the LAST claimant wins, which works because we walk zones
    // -> square in source-order top-to-bottom - the visual stacking
    // order users expect.
    u.setMouseCursor(cursor_for_this_frame);

    // Bottom: live readout.
    var buf: [128]u8 = undefined;
    const mp: Vec2 = z.getMousePosition(f.input);
    const lmb: bool = f.input.mouse.current_button[0] != 0;
    const dragging: bool = u.isMouseDragging(.left, -1);
    const d: Vec2 = u.getMouseDragDelta(.left, -1);

    const line1: []const u8 = bufPrint(&buf, "mouse: ({d:.0}, {d:.0})  left: {s}  dragging: {s}", .{
        mp[0],
        mp[1],
        if (lmb) "DOWN" else "up",
        if (dragging) "YES" else "no",
    }) catch "?";
    f.gl.text(.{ 24, sh - 56 }, line1, .{ .size = 12, .color = dim, .font = &s.font });

    var buf2: [128]u8 = undefined;
    const line2: []const u8 = bufPrint(&buf2, "drag delta: ({d:.1}, {d:.1})  square: ({d:.0}, {d:.0})", .{
        d[0],
        d[1],
        s.draggable_pos[0],
        s.draggable_pos[1],
    }) catch "?";
    f.gl.text(.{ 24, sh - 36 }, line2, .{ .size = 12, .color = dim, .font = &s.font });
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - ui mouse drag (B1 capstone)",
            .width = 720,
            .height = 480,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
