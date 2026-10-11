//! input_cursor_shapes - the cursor's shape over the window, and the window's title, changed while the app runs.
//!
//! Each tile names one of the engine's cursor shapes (raylib's set). Hovering a tile asks for its shape
//! (`z.setMouseCursor`), and the window's title names it (`z.setWindowTitle`); the last tile hides the cursor while
//! it is hovered (`z.hideCursor`). The app only says, each frame, which cursor it wants. The engine shows it through
//! the platform once the frame's update is done - a CSS cursor in the browser, a system cursor in a native window -
//! and only when it differs from the one shown, so asking every frame costs nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const Vec2 = zm.Vec2;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// One tile: its label, and the cursor it asks for - none for the tile that hides the cursor.
const Tile = struct {
    label: []const u8,
    cursor: ?z.MouseCursor,
};

const tiles = [_]Tile{
    .{ .label = "default", .cursor = .default },
    .{ .label = "ibeam", .cursor = .ibeam },
    .{ .label = "pointing_hand", .cursor = .pointing_hand },
    .{ .label = "crosshair", .cursor = .crosshair },
    .{ .label = "resize_ew", .cursor = .resize_ew },
    .{ .label = "resize_ns", .cursor = .resize_ns },
    .{ .label = "resize_nwse", .cursor = .resize_nwse },
    .{ .label = "resize_nesw", .cursor = .resize_nesw },
    .{ .label = "resize_all", .cursor = .resize_all },
    .{ .label = "not_allowed", .cursor = .not_allowed },
    .{ .label = "hidden", .cursor = null },
};

const columns: usize = 4;
const margin: f32 = 16;
const gap: f32 = 10;

const background: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };
const tile_color: Color = .{ .r = 30, .g = 41, .b = 59, .a = 255 };
const hovered_color: Color = .{ .r = 51, .g = 65, .b = 85, .a = 255 };
const text_color: Color = .{ .r = 226, .g = 232, .b = 240, .a = 255 };

const State = struct {
    font: z.Font,
    /// The tile hovered in the previous frame, so the title changes only when the hovered tile does.
    hovered: ?usize = null,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18) };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

/// Tile `index`'s rectangle, in a grid of `columns` filling the window's width below the caption.
fn tileRect(index: usize, width: f32) z.Rectangle {
    const tile_width: f32 = (width - 2 * margin - gap * float(columns - 1)) / float(columns);
    const tile_height: f32 = 64;
    const column: usize = index % columns;
    const row: usize = index / columns;
    return .{
        .x = margin + float(column) * (tile_width + gap),
        .y = 48 + float(row) * (tile_height + gap),
        .width = tile_width,
        .height = tile_height,
    };
}

fn isInside(rect: z.Rectangle, point: Vec2) bool {
    const is_within_columns: bool = point[0] >= rect.x and point[0] < rect.x + rect.width;
    const is_within_rows: bool = point[1] >= rect.y and point[1] < rect.y + rect.height;
    return is_within_columns and is_within_rows;
}

fn update(f: *z.Frame, s: *State) void {
    const width: f32 = f.window.widthf();
    const pointer: Vec2 = z.getMousePosition(f.input);
    var hovered: ?usize = null;
    for (tiles, 0..) |_, index| {
        if (isInside(tileRect(index, width), pointer)) {
            hovered = index;
        }
    }
    // The wish for this frame: the hovered tile's cursor, hidden for the last tile, the default elsewhere.
    const wanted: ?z.MouseCursor = if (hovered) |index| tiles[index].cursor else .default;
    if (wanted) |cursor| {
        z.showCursor(f.input);
        z.setMouseCursor(f.input, cursor);
    } else {
        z.hideCursor(f.input);
    }
    if (hovered != s.hovered) {
        s.hovered = hovered;
        var title_buffer: [64]u8 = undefined;
        const label: []const u8 = if (hovered) |index| tiles[index].label else "none";
        const title: []const u8 = bufPrint(&title_buffer, "zimr - cursor: {s}", .{label}) catch "zimr - cursor";
        z.setWindowTitle(title);
    }

    z.clearViewport(f, background);
    for (tiles, 0..) |tile, index| {
        const rect: z.Rectangle = tileRect(index, width);
        const color: Color = if (hovered == index) hovered_color else tile_color;
        f.gl.rect(rect, .{ .color = color });
        f.gl.text(.{ rect.x + 12, rect.y + 22 }, tile.label, .{ .size = 18, .color = text_color, .font = &s.font });
    }
    common.caption(f.gl, s.font, "input_cursor_shapes: hover a tile to show its cursor; the title names it");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - cursor: none",
            .width = 820,
            .height = 360,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
