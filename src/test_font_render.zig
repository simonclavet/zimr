//! HOST-ONLY debug harness (not shipped): exercises the pure-CPU text-into-image
//! path — bakeFontAtlas → imageDrawTextWithFont → exportImageToMemory(PNG) — so the
//! result can be viewed directly in the sandbox without a device round-trip.
const std = @import("std");
const text2d = @import("text2d.zig");
const image = @import("image.zig");
const codecs = @import("codecs.zig");
const types = @import("types.zig");

const roboto = @embedFile("roboto");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    const tt: codecs.truetype.Font = try codecs.truetype.loadFontFromTtf(gpa, roboto);

    var codepoints: [95]u21 = undefined;
    for (&codepoints, 0..) |*cp, k| {
        cp.* = @intCast(32 + k);
    }

    const bake_size: i32 = 90; // simulate DPR-3 device bake
    const atlas: text2d.FontAtlas = try text2d.bakeFontAtlas(gpa, &tt, bake_size, &codepoints, 1);
    // lint:off debug-print: host-only harness output
    std.debug.print("atlas: base_size={d} glyphs={d} glyph_padding={d} atlas_img={d}x{d}\n", .{
        atlas.base_size,
        atlas.glyphs.len,
        atlas.glyph_padding,
        atlas.image.width,
        atlas.image.height,
    });

    const font = types.Font{
        .baseSize = atlas.base_size,
        .glyphCount = @intCast(atlas.glyphs.len),
        .glyphPadding = atlas.glyph_padding,
        .texture = .{},
        .recs = atlas.recs.ptr,
        .glyphs = atlas.glyphs.ptr,
    };

    // Inspect a couple glyphs' per-glyph CPU images (what imageDrawTextWithFont samples).
    for ([_]u8{ 'H', 'e', '[' }) |ch| {
        const idx: usize = @intCast(ch - 32);
        const g: text2d.GlyphInfo = atlas.glyphs[idx];
        // lint:off debug-print: host-only harness output
        std.debug.print("  glyph '{c}': image={d}x{d} data_null={} advanceX={d} offX={d} offY={d}\n", .{
            ch,
            g.image.width,
            g.image.height,
            g.image.data == null,
            g.advanceX,
            g.offsetX,
            g.offsetY,
        });
    }

    var img: image.Image = try image.genImageChecked(
        gpa,
        360,
        240,
        30,
        30,
        .{ .r = 28, .g = 36, .b = 66, .a = 255 },
        .{ .r = 40, .g = 52, .b = 92, .a = 255 },
    );

    // Draw at bake_size (scale 1, no downsample) as the control.
    text2d.imageDrawTextWithFont(
        &img,
        font,
        "Hello [World] 30px",
        .{ 20, 40 },
        30,
        1,
        .{ .r = 255, .g = 203, .b = 0, .a = 255 },
    );
    // Draw at a smaller size (downsample path).
    text2d.imageDrawTextWithFont(
        &img,
        font,
        "small 24px [abc]",
        .{ 20, 140 },
        24,
        1,
        .{ .r = 245, .g = 245, .b = 245, .a = 255 },
    );

    // Count non-background pixels as a quick sanity metric.
    const px: [*]const u8 = @ptrCast(img.data.?);
    const n: usize = @intCast(img.width * img.height);
    var text_pixels: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = px[i * 4 + 0];
        const g = px[i * 4 + 1];
        // gold or white text is much brighter than the blue checker
        if (r > 150 and g > 150) {
            text_pixels += 1;
        }
    }
    // lint:off debug-print: host-only harness output
    std.debug.print("text-colored pixels in image: {d}\n", .{text_pixels});

    const png: []u8 = try image.exportImageToMemory(gpa, img, ".png");
    const out: std.Io.File = std.Io.File.stdout();
    try out.writeStreamingAll(io, png);
    // lint:off debug-print: host-only harness output
    std.debug.print("wrote PNG to stdout ({d} bytes)\n", .{png.len});
}
