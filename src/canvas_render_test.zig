//! HOST harness (not shipped): exercises the new Canvas primitive surface →
//! PNG so each slice of the drawing-API migration can be viewed in-sandbox with
//! no device. Excluded from the style gate via build.zig `deletion_skip`.
const std = @import("std");
const Canvas = @import("Canvas.zig");
const image = @import("image.zig");
const Sprite = @import("Sprite.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    var canvas = try Canvas.init(gpa, 360, 240, .{});
    defer canvas.deinit();

    // A procedural checker -> Sprite (owns a copy; free the source right after to
    // prove the Sprite is self-contained).
    const checker: image.Image = try image.genImageChecked(
        gpa,
        64,
        64,
        8,
        8,
        .{ .r = 40, .g = 52, .b = 120, .a = 255 },
        .{ .r = 230, .g = 205, .b = 90, .a = 255 },
    );
    var sprite = try Sprite.fromImage(gpa, checker);
    image.unloadImage(gpa, checker);
    defer sprite.deinit(gpa);

    canvas.rect(
        .{ .x = 10, .y = 10, .width = 340, .height = 220 },
        .{ .color = .{ .r = 60, .g = 60, .b = 70, .a = 255 }, .outline = 2 },
    );
    canvas.image(.{ .x = 24, .y = 24, .width = 130, .height = 130 }, sprite, .{});
    canvas.imageXYWH(180, 24, 150, 150, sprite, .{ .source = .{ .x = 0, .y = 0, .width = 32, .height = 32 } });
    canvas.image(
        .{ .x = 24, .y = 168, .width = 306, .height = 48 },
        sprite,
        .{ .tint = .{ .r = 255, .g = 170, .b = 170, .a = 255 } },
    );
    canvas.circle(.{ 300, 70 }, 34, .{ .color = .{ .r = 80, .g = 200, .b = 140, .a = 255 } }); // unified circle

    const png: []u8 = try canvas.writePngToMemory();
    const out: std.Io.File = std.Io.File.stdout();
    try out.writeStreamingAll(io, png);
    // lint:off debug-print: host-only harness, writes status to stdout on native
    std.debug.print("wrote canvas PNG to stdout ({d} bytes)\n", .{png.len});
}
