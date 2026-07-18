// examples/text_font_filters.zig - point vs bilinear filtering on a font atlas.
// Ports raylib's `text_font_filters`: a font is baked ONCE at a small pixel size,
// then drawn much larger. How the atlas is SAMPLED decides what that looks like:
//
//   .point    - nearest-neighbour. Crisp and exact at the baked size; chunky and
//               aliased when magnified far past it.
//   .bilinear - smooths between texels. Softer, but degrades gracefully when the
//               drawn size is well away from the baked size.
//
// The atlas is never re-baked — only the sampler changes — which is the point:
// the filter is a property of how you READ the texture, not of the glyphs.
//
// Controls are UI BUTTONS + a SLIDER (not keys), so the whole example is
// testable by tapping on a phone.
//
// What this exercises (the engine work this drove):
//   - `z.setTextureFilter(gl, texture_id, .point | .bilinear)` — newly added
//     (raylib SetTextureFilter). Swaps the sampler and rebuilds that texture's
//     material bind group; previously a texture's filter was fixed at creation.
//
// Leak-clean (`.memory = .managed`): the UiHost is deinit'd; atlases are
// engine-owned.

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
const float = zm.float;

const bake_size: i32 = 20; // deliberately SMALL, so magnifying it exposes the filter
const sample = "Aa1 Bb2";

const State = struct {
    ui_host: z.UiHost,
    demo_font: z.Font, // the atlas whose filter we toggle
    ui_font: z.Font,
    bilinear: bool = false, // atlases start point-sampled (engine default)
    draw_size: f32 = 60.0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Two atlases: one drives the UI (must stay legible), one is the specimen we
    // re-filter. Sharing a single atlas would re-filter the UI text too and
    // muddle what the example is showing.
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    const demo_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, bake_size);
    s.* = .{
        .ui_font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
        .demo_font = demo_font,
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.demo_font);
    z.unloadFont(gpa, s.ui_font);
    s.ui_host.deinit();
}

/// Apply `bilinear` to the specimen atlas' live sampler.
fn applyFilter(f: *z.Frame, s: *State) void {
    z.setTextureFilter(
        f.gl,
        s.demo_font.texture.id,
        if (s.bilinear) .bilinear else .point,
    );
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();

    z.clearViewport(f, c.raywhite);

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, 210 }, .{});
    if (u.window("Font atlas filter", .{})) |w| {
        defer w.close();
        u.text("Atlas baked once at {d} px.", .{bake_size});
        u.text("Filter changes the SAMPLER, not the glyphs.", .{});
        u.separator();

        if (u.button("POINT (nearest)", .{})) {
            s.bilinear = false;
            applyFilter(f, s);
        }
        u.sameLine(.{});
        if (u.button("BILINEAR", .{})) {
            s.bilinear = true;
            applyFilter(f, s);
        }

        _ = u.slider("drawn size", &s.draw_size, .{ .min = 8, .max = 90 });
        u.text("filter: {s}   magnification: {d:.1}x", .{
            if (s.bilinear) "BILINEAR" else "POINT",
            s.draw_size / float(bake_size),
        });
    }

    // The magnified specimen — this is where the filter shows. Drawn BEFORE
    // ui_host.render so the UI panel composites on top.
    f.gl.text(
        .{ 20, 250 },
        sample,
        .{ .size = s.draw_size, .color = c.black, .font = &s.demo_font },
    );

    // The same string AT the baked size — the reference. Both filters look
    // near-identical here, which is why the magnified line above is the one to
    // judge.
    f.gl.text(
        .{ 20, 370 },
        sample,
        .{ .size = float(bake_size), .color = c.darkgray, .font = &s.demo_font },
    );
    f.gl.text(
        .{ 20, 396 },
        "(baked size - the reference)",
        .{ .size = 15, .color = c.gray, .font = &s.demo_font },
    );

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - text - font filters",
            .width = 800,
            .height = 450,
            // .responsive (not .fit): every UiHost example uses it, and the
            // layout below is derived from f.window rather than hardcoded.
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
