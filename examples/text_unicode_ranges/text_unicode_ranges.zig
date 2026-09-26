// examples/text_unicode_ranges.zig - adding Unicode ranges to a font at RUNTIME.
// Ports raylib's `text_unicode_ranges`: the font starts with plain ASCII, and
// each range you enable is BAKED INTO A NEW ATLAS - so glyphs that rendered as
// fallback boxes suddenly appear. Toggle the ranges and watch the glyph count
// grow.
//
// raylib's original pulls ranges (Devanagari / Arabic / Hebrew / CJK) out of a
// large NotoSans font. The bundled RobotoMono has no such coverage - shipping a
// multi-megabyte CJK font just for a demo isn't worth it - so this port keeps the
// MECHANISM identical and uses the scripts this TTF actually has (checked against
// its cmap: Latin-1, Latin Extended-A, most Greek, nearly all Cyrillic).
//
// What this exercises (the engine work this drove):
//   - `z.releaseFont(gl, gpa, font)` - NEW. Re-baking a font means registering a
//     new GPU atlas; the old one has to go back. `z.unloadFont` only frees the
//     CPU glyph arrays, so without this each re-bake abandons a GPU texture, and
//     after 64 the registry runs out of slots and hands back the WHITE texture -
//     text would silently turn into solid blocks. `releaseFont` destroys the
//     atlas + its bind group and recycles the registry slot.
//   - `z.loadFontEx(f, gpa, ttf, size, codepoints)` - bakes the chosen set.
//
// Leak-clean (`.memory = .managed`): every re-bake releases its predecessor, so
// toggling ranges all day keeps exactly ONE atlas alive.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

// Stays on RobotoMono ON PURPOSE: this example needs Greek + Cyrillic, and the
// other bundled font (Atkinson Mono) has ZERO Cyrillic and only 4/57 Greek -
// every sample line below would render as fallback boxes. Probe the cmap before
// swapping a font under a Unicode example.
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;

const font_px: i32 = 22;
const max_cp: usize = 400;

/// One toggleable script. `sample` only contains codepoints from its own range,
/// so before the range is enabled the line renders as fallback marks - and after,
/// as real glyphs. That contrast IS the example.
const Range = struct {
    name: []const u8,
    lo: u21,
    hi: u21,
    sample: []const u8,
};

const ranges = [_]Range{
    .{ .name = "Latin-1", .lo = 0xC0, .hi = 0xFF, .sample = "Grüße Ñoño Åland Çà" },
    .{ .name = "Latin Ext-A", .lo = 0x100, .hi = 0x17F, .sample = "Āā Ćć Ďď Łł Šš Žž" },
    .{ .name = "Greek", .lo = 0x391, .hi = 0x3C9, .sample = "ΑΒΓΔΕ αβγδε ΞΠΣΦ" },
    .{ .name = "Cyrillic", .lo = 0x410, .hi = 0x44F, .sample = "Привет мир Здравствуй" },
};

const State = struct {
    /// `Frame` carries no allocator (gpu/gl/input/time/window only), so stash the
    /// one `init` was handed - re-baking a font in `update` needs it.
    gpa: Allocator,
    ui_host: z.UiHost,
    font: z.Font, // re-baked whenever the enabled set changes
    ui_font: z.Font,
    enabled: [ranges.len]bool = @splat(false),
    glyph_count: i32 = 0,
    bakes: u32 = 0, // how many atlases we've built - proves slots are recycled
};

/// Build the codepoint set for the currently-enabled ranges (ASCII is always in)
/// and bake a fresh atlas. Returns the new font; the CALLER releases the old one.
fn bakeFont(f: *z.Frame, gpa: Allocator, enabled: [ranges.len]bool) !z.Font {
    var cps: [max_cp]u21 = undefined;
    var n: usize = 0;

    var v: u21 = 32;
    while (v < 127) : (v += 1) { // ASCII always
        cps[n] = v;
        n += 1;
    }
    for (ranges, 0..) |rg, i| {
        if (!enabled[i]) {
            continue;
        }
        var cp: u21 = rg.lo;
        while (cp <= rg.hi and n < max_cp) : (cp += 1) {
            cps[n] = cp;
            n += 1;
        }
    }
    return z.loadFontEx(f, gpa, roboto_mono_ttf, font_px, cps[0..n]);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 24);
    const enabled: [ranges.len]bool = @splat(false);
    const font: z.Font = try bakeFont(f, gpa, enabled);
    s.* = .{
        .gpa = gpa,
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .font = font,
        .glyph_count = font.glyphCount,
        .bakes = 1,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadFont(gpa, s.ui_font);
    s.ui_host.deinit();
}

/// Toggle a range and re-bake. The OLD atlas is released first - this is the
/// whole point of `releaseFont`.
fn toggleRange(f: *z.Frame, s: *State, gpa: Allocator, idx: usize) void {
    var next: [ranges.len]bool = s.enabled;
    next[idx] = !next[idx];
    const new_font: z.Font = bakeFont(f, gpa, next) catch return; // keep the old font on failure
    z.releaseFont(f.gl, gpa, s.font);
    s.font = new_font;
    s.enabled = next;
    s.glyph_count = new_font.glyphCount;
    s.bakes += 1;
}

fn update(f: *z.Frame, s: *State) void {
    const gpa: Allocator = s.gpa;
    const fw: f32 = f.window.widthf();

    z.clearViewport(f, c.raywhite);

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 250 }, .{});
    if (u.window("Unicode ranges", .{})) |w| {
        defer w.close();
        u.text("Tap a range to bake it in.", .{});
        u.separator();
        for (ranges, 0..) |rg, i| {
            if (u.button(rg.name, .{})) {
                toggleRange(f, s, gpa, i);
            }
            if (i % 2 == 0) {
                u.sameLine(.{});
            }
        }
        u.separator();
        u.text("glyphs baked: {d}   atlases built: {d}", .{ s.glyph_count, s.bakes });
    }

    // Each script's sample. Disabled ranges have no glyphs baked, so the line
    // renders as fallback marks until you enable it.
    var y: f32 = 280;
    for (ranges, 0..) |rg, i| {
        const on: bool = s.enabled[i];
        f.gl.text(
            .{ 16, y },
            rg.name,
            .{ .size = 15, .color = if (on) c.darkgreen else c.gray, .font = &s.font },
        );
        f.gl.text(
            .{ 130, y },
            rg.sample,
            .{ .size = 22, .color = if (on) c.black else c.gray, .font = &s.font },
        );
        y += 40;
    }

    f.gl.text(
        .{ 16, y + 8.0 },
        "Old atlas is released on every re-bake (releaseFont).",
        .{ .size = 15, .color = c.gray, .font = &s.font },
    );

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - text - unicode ranges",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = null,
            .clear = .{ .r = 245.0 / 255.0, .g = 245.0 / 255.0, .b = 245.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
