// examples/text_codepoints_loading.zig - baking a chosen set of Unicode
// codepoints into a font atlas.
// Ports raylib's `text_codepoints_loading`: `loadFont` bakes only ASCII 32..126,
// so anything outside it (accented Latin, Greek, Cyrillic, ...) has no glyph.
// `loadFontEx` takes an EXPLICIT codepoint list, so you bake exactly the scripts
// your app renders — and no more, since every codepoint costs atlas space.
//
// The example loads the SAME TTF twice — once ASCII-only, once extended — and
// draws the same multilingual lines with both, so the difference is visible
// rather than asserted.
//
// What this exercises (the engine work this drove):
//   - `z.loadFontEx(f, gpa, ttf, size, codepoints)` — newly exported; the atlas
//     baker always accepted a codepoint slice, but only ASCII was reachable.
//
// The ranges below are the ones the bundled RobotoMono actually covers (its cmap
// has Latin-1, Latin Extended-A, most Greek and nearly all Cyrillic — but NO
// arrows, box-drawing or CJK, which would bake as empty .notdef boxes).
//
// Leak-clean (`.memory = .managed`): both atlases are engine-owned.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;
const bufPrint = std.fmt.bufPrint;

const screen_w: i32 = 800;
const screen_h: i32 = 450;

const n_ascii: usize = 95; // 32..126
const n_latin1: usize = 64; // C0..FF   accented Latin
const n_greek_u: usize = 25; // 391..3A9 Alpha..Omega
const n_greek_l: usize = 25; // 3B1..3C9 alpha..omega
const n_cyril: usize = 64; // 410..44F  Cyrillic

/// The exact codepoint set to bake, built at comptime — so the atlas contents
/// are a compile-time fact and the count is exact (no "bake all of Unicode").
const cp_set: [n_ascii + n_latin1 + n_greek_u + n_greek_l + n_cyril]u21 = blk: {
    var out: [n_ascii + n_latin1 + n_greek_u + n_greek_l + n_cyril]u21 = undefined;
    var n: usize = 0;
    for (32..127) |v| {
        out[n] = @intCast(v);
        n += 1;
    }
    for (0xC0..0x100) |v| {
        out[n] = @intCast(v);
        n += 1;
    }
    for (0x391..0x3AA) |v| {
        out[n] = @intCast(v);
        n += 1;
    }
    for (0x3B1..0x3CA) |v| {
        out[n] = @intCast(v);
        n += 1;
    }
    for (0x410..0x450) |v| {
        out[n] = @intCast(v);
        n += 1;
    }
    break :blk out;
};

// Every character below lives inside the baked ranges above.
const line_latin = "Grüße! Ñoño, Åland, Çà et là";
const line_greek = "ΑΒΓΔΕΖΗΘΙΚΛΜ αβγδεζηθικλμ";
const line_cyril = "Привет, мир! Здравствуй";

const State = struct {
    ascii_font: z.Font, // loadFont   — ASCII 32..126 only
    uni_font: z.Font, // loadFontEx — the set above
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .ascii_font = try z.loadFont(f, gpa, roboto_mono_ttf, 22),
        .uni_font = try z.loadFontEx(f, gpa, roboto_mono_ttf, 22, &cp_set),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.ascii_font);
    z.unloadFont(gpa, s.uni_font);
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, c.raywhite);

    f.gl.text(
        .{ 20, 14 },
        "loadFontEx bakes a chosen codepoint set - loadFont bakes ASCII only",
        .{ .size = 18, .color = c.darkgray, .font = &s.uni_font },
    );

    // --- LEFT/TOP: the ASCII-only atlas. Non-ASCII has no glyph. ---
    f.gl.text(.{ 20, 58 }, "ASCII-only atlas (z.loadFont):", .{ .size = 17, .color = c.maroon, .font = &s.uni_font });
    f.gl.text(.{ 34, 84 }, line_latin, .{ .size = 22, .color = c.gray, .font = &s.ascii_font });
    f.gl.text(.{ 34, 112 }, line_greek, .{ .size = 22, .color = c.gray, .font = &s.ascii_font });
    f.gl.text(.{ 34, 140 }, line_cyril, .{ .size = 22, .color = c.gray, .font = &s.ascii_font });

    // --- BELOW: the extended atlas. Same strings, real glyphs. ---
    f.gl.text(.{ 20, 190 }, "Extended atlas (z.loadFontEx):", .{
        .size = 17,
        .color = c.darkgreen,
        .font = &s.uni_font,
    });
    f.gl.text(.{ 34, 216 }, line_latin, .{ .size = 22, .color = c.black, .font = &s.uni_font });
    f.gl.text(.{ 34, 244 }, line_greek, .{ .size = 22, .color = c.black, .font = &s.uni_font });
    f.gl.text(.{ 34, 272 }, line_cyril, .{ .size = 22, .color = c.black, .font = &s.uni_font });

    // The cost of each atlas, so "bake only what you need" is concrete.
    var buf: [128]u8 = undefined;
    const info: []const u8 = bufPrint(
        &buf,
        "glyphs baked - ascii: {d}   extended: {d}   (atlas {d}x{d} px)",
        .{
            s.ascii_font.glyphCount,
            s.uni_font.glyphCount,
            s.uni_font.texture.width,
            s.uni_font.texture.height,
        },
    ) catch "?";
    f.gl.text(.{ 20, 330 }, info, .{ .size = 17, .color = c.darkgray, .font = &s.uni_font });

    f.gl.text(
        .{ 20, 360 },
        "ASCII + Latin-1 accented + Greek + Cyrillic - the ranges this TTF covers.",
        .{ .size = 16, .color = c.gray, .font = &s.uni_font },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - text - codepoints loading",
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
