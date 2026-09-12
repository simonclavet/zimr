//! text_sprite_fonts — port of raylib [text] examples "font spritefont" and
//! "sprite fonts" (merged). raylib sources: examples/text/text_font_spritefont.c
//! and examples/text/text_sprite_fonts.c.
//!
//! Both raylib samples do the same thing: `LoadFont("something.png")`, which for
//! a PNG routes into `LoadFontFromImage` — an XNA-style BITMAP font where the
//! glyphs sit on a MAGENTA key background and are separated by key-coloured
//! gutters. raylib then draws a fixed sentence per font and exits; nothing is
//! interactive. This is the honest phone translation and adds what a touch UI
//! makes worth having: pick the sample text, scale every font live, and tighten
//! or loosen the inter-glyph spacing (raylib's `DrawTextEx` spacing) — so you
//! can actually see how each face behaves, not just a frozen screenshot.
//!
//! The engine work this drove is `z.loadFontFromImage` (raylib's
//! `LoadFontFromImage`): segment the image into glyph rectangles (a pure,
//! unit-tested `image.segmentSpriteFont` — first non-key pixel gives the shared
//! char/line spacing border, the first glyph column gives the char height, then
//! each line band is walked splitting glyphs on key columns), replace the key
//! colour with transparent, and upload the cleaned image as a NEAREST atlas.
//! The glyphs carry `advanceX = 0`, so the existing text path advances by the
//! rec width — exactly like raylib. The segmentation was validated headless:
//! pixel-for-pixel identical glyph counts/rects to a reference scan on all three
//! real fonts (mecha 96, alagard 95, jupiter_crash 96 glyphs).
//!
//! `.memory = .managed`: all four fonts (three sprite + the TTF UI font) and the
//! UI host are freed in `deinit`; the sprite-font atlases are engine-owned
//! (registered) and reclaimed with the renderer at teardown, so the twice-
//! lifecycle smoke census must come back FLAT.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = z.colors;
const common = @import("example_common");

const mecha_png = @embedFile("mecha.png");
const alagard_png = @embedFile("alagard.png");
const jupiter_png = @embedFile("jupiter_crash.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// The MAGENTA key colour these XNA-style fonts use for their background.
const key_magenta: Color = .{ .r = 255, .g = 0, .b = 255, .a = 255 };

const FontInfo = struct {
    label: []const u8,
    tint: Color,
};

const font_info = [_]FontInfo{
    .{ .label = "MECHA  -  by Captain Falcon", .tint = .{ .r = 120, .g = 220, .b = 160, .a = 255 } },
    .{ .label = "ALAGARD  -  by Hewett Tsoi", .tint = .{ .r = 235, .g = 150, .b = 120, .a = 255 } },
    .{ .label = "JUPITER CRASH  -  by Brian Kent", .tint = .{ .r = 240, .g = 205, .b = 110, .a = 255 } },
};

const samples = [_][]const u8{
    "THE QUICK BROWN FOX",
    "Sphinx of black quartz",
    "ABCDEFG abcdefg",
    "0123456789 !?.,:;",
    "zimr sprite fonts",
};

const State = struct {
    ui_font: z.Font,
    ui_host: z.UiHost,
    /// mecha, alagard, jupiter_crash — parsed from magenta-keyed PNGs.
    fonts: [3]z.Font,

    sample_idx: u32 = 0,
    /// Multiplier applied to each font's own baseSize.
    size_scale: f32 = 2.0,
    /// raylib `DrawTextEx` inter-glyph spacing (logical px; may be negative).
    spacing: f32 = 1.0,
};

fn loadSpriteFont(f: *z.Frame, gpa: Allocator, bytes: []const u8) !z.Font {
    // loadFontFromImage copies what it needs, so the decoded image is freed here.
    const img: z.Image = try z.loadImageFromMemory(gpa, bytes);
    defer z.unloadImage(gpa, img);
    return z.loadFontFromImage(f.gl, gpa, img, key_magenta, 32);
}

fn deinit(gpa: Allocator, s: *State) void {
    for (&s.fonts) |font| {
        z.unloadFont(gpa, font);
    }
    z.unloadFont(gpa, s.ui_font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    s.* = .{
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .fonts = .{
            try loadSpriteFont(f, gpa, mecha_png),
            try loadSpriteFont(f, gpa, alagard_png),
            try loadSpriteFont(f, gpa, jupiter_png),
        },
    };
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    const msg: []const u8 = samples[s.sample_idx];

    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // ---- three font rows, each centred on its own sample line -------------
    const panel_h: f32 = 232;
    const top: f32 = 40;
    const avail: f32 = fh - panel_h - top - 16;
    const row_h: f32 = avail / 3.0;
    for (s.fonts, 0..) |font, i| {
        const info: FontInfo = font_info[i];
        const size: f32 = float(font.baseSize) * s.size_scale;
        const dim: zm.Vec2 = z.measureTextEx(font, msg, size, s.spacing);
        const row_y: f32 = top + row_h * float(@as(u32, @intCast(i)));

        // small TTF caption naming the face
        f.gl.text(.{ 16, row_y + 4 }, info.label, .{ .size = 16, .color = c.slate_400, .font = &s.ui_font });

        // the sprite-font sample, horizontally centred in its row
        const tx: f32 = @max(16.0, (fw - dim[0]) * 0.5);
        const ty: f32 = row_y + (row_h - dim[1]) * 0.5 + 10;
        f.gl.text(.{ tx, ty }, msg, .{ .size = size, .color = info.tint, .font = &font, .spacing = s.spacing });

        // a thin divider under each row (except the last)
        if (i < 2) {
            const ly: f32 = top + row_h * float(@as(u32, @intCast(i)) + 1);
            f.gl.rect(
                .{ .x = 16, .y = ly, .width = fw - 32, .height = 1 },
                .{ .color = .{ .r = 40, .g = 44, .b = 54, .a = 255 } },
            );
        }
    }

    // ---- control panel ----------------------------------------------------
    u.setNextWindowPos(.{ 8, fh - panel_h - 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, panel_h }, .{});
    if (u.window("Sprite fonts (LoadFontFromImage)", .{})) |w| {
        defer w.close();

        u.text("XNA-style bitmap fonts: glyphs on a magenta key, split by key gutters.", .{});
        u.text("glyphs  mecha {d}  alagard {d}  jupiter {d}", .{
            s.fonts[0].glyphCount,
            s.fonts[1].glyphCount,
            s.fonts[2].glyphCount,
        });
        u.separator();

        u.text("sample: {s}", .{msg});
        if (u.button("< prev text", .{})) {
            s.sample_idx = if (s.sample_idx == 0) samples.len - 1 else s.sample_idx - 1;
        }
        u.sameLine(.{});
        if (u.button("next text >", .{})) {
            s.sample_idx = if (s.sample_idx + 1 >= samples.len) 0 else s.sample_idx + 1;
        }

        u.separator();
        _ = u.slider("size", &s.size_scale, .{ .min = 1.0, .max = 4.0 });
        _ = u.slider("spacing", &s.spacing, .{ .min = -4.0, .max = 12.0 });
    }

    s.ui_host.render(f);

    common.caption(f.gl, s.ui_font, "Bitmap fonts parsed by z.loadFontFromImage - fonts (c) their designers");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner/launcher drives begin/end (no offscreen pass, so
/// no `manages_own_frame`), exactly like the other 2D UI examples.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - text sprite fonts",
            .width = 800,
            .height = 640,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
