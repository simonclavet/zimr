// examples/text_font_loading.zig - loading a TTF font and rendering with it.
// Ports raylib's core `text_font_loading` idea: a custom font is loaded (raylib
// from a file, here from embedded TTF bytes), then a sample string is drawn at
// several sizes to show one baked atlas scaling cleanly, plus the font's baked
// metrics (atlas base size + glyph count).
//
// zimr bakes ONE atlas per `loadFont` at a chosen pixel size; drawing at a
// different `size` scales that atlas, so a single load covers every size below.
//
// What this exercises:
//   - `z.loadFont(f, gpa, ttf_bytes, base_px)` and the baked `Font` metrics.
//   - `f.gl.text` at varying `size` off one atlas.
//
// Leak-clean (`.memory = .managed`): the atlas is engine-owned (freed by
// resetRegistry), so `deinit` is a no-op.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

// Atkinson Hyperlegible Mono — the Braille Institute's legibility font.
// Distinct letterforms (slashed zero, unambiguous I/l/1), and a deliberate
// break from raylib's look. Latin-only content, so its cmap is plenty:
// ASCII + Latin-1 accented in full. (It has NO Cyrillic and almost no Greek,
// which is why the Unicode examples stay on RobotoMono.)
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Color = zm.Color;
const c = Color;
const bufPrint = std.fmt.bufPrint;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const sample = "The quick brown fox jumps over the lazy dog 0123456789";

const State = struct {
    font: z.Font,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Bake at a high pixel size so the downscaled draws below stay sharp.
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 42);
    s.* = .{ .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    const sh: f32 = f.window.heightf();

    z.clearViewport(f, c.raywhite);

    f.gl.text(
        .{ 20, 16 },
        "Font loaded from embedded TTF - one atlas, drawn at several sizes:",
        .{ .size = 18, .color = c.darkgray, .font = &s.font },
    );

    const sizes: [4]f32 = .{ 12, 18, 26, 36 };
    var y: f32 = 58;
    for (sizes) |sz| {
        f.gl.text(.{ 30, y }, sample, .{ .size = sz, .color = c.maroon, .font = &s.font });
        y += sz + 16.0;
    }

    var buf: [96]u8 = undefined;
    const meta: []const u8 = bufPrint(
        &buf,
        "atlas base size: {d} px    glyphs baked: {d}",
        .{ s.font.baseSize, s.font.glyphCount },
    ) catch "?";
    f.gl.text(.{ 20, sh - 36.0 }, meta, .{ .size = 18, .color = c.gray, .font = &s.font });

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - text - font loading",
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
