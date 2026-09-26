//! text_font_sdf - port of raylib [text] example - font SDF loading.
//! raylib source: examples/text/text_font_sdf.c.
//!
//! The point of SDF text: a normal glyph atlas stores COVERAGE, so magnifying a
//! glyph past the resolution it was baked at just bilinear-blurs that coverage -
//! the edge goes soft. A signed-distance-field atlas stores, per texel, the
//! distance to the nearest glyph edge; a `smoothstep` around the 0.5 iso-line
//! reconstructs a crisp ~1px edge at ANY magnification. raylib proves it by
//! baking one 16px font both ways and drawing both big; this does the same and
//! makes the size a live slider so you can watch the bitmap dissolve while the
//! SDF stays razor-sharp.
//!
//! Engine work this drove:
//!   * `z.loadFontSdf` - bake a coverage atlas, then `image.coverageToSdf`
//!     (a pure, unit-tested signed 8SSEDT) turns coverage into distance in the
//!     alpha channel; uploaded LINEAR-filtered.
//!   * `src/shaders/text_sdf_fs.zig` - raylib's `sdf.fs`, the `smoothstep(0.5)`
//!     fragment stage, run over the 2D batch via `beginShaderMode`. The SDF
//!     glyphs are just `gl.text` drawn between begin/endShaderMode.
//!
//! `.memory = .managed`: both fonts + the UI font + the shader are freed in
//! `deinit`; the atlases are engine-owned (registered) and reclaimed with the
//! renderer, so the twice-lifecycle census stays FLAT.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const c = z.colors;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
/// The WGSL the build generated from `src/shaders/text_sdf_fs.zig`.
const sdf_wgsl = @embedFile("text_sdf_fs.wgsl");

const samples = [_][]const u8{ "Sphinx", "SHARP", "Ag&Q@", "zimr" };

const State = struct {
    ui_font: z.Font,
    /// Small coverage atlas - blurs when magnified far past its bake size.
    bitmap_font: z.Font,
    /// Same face, baked as a signed distance field - crisp at any size.
    sdf_font: z.Font,
    sdf_shader: z.Shader2D,
    ui_host: z.UiHost,

    /// On-screen pixel size both rows are drawn at.
    size: f32 = 200.0,
    /// SDF edge smoothing half-width (shader params[0]).
    smoothing: f32 = 0.05,
    sample_idx: u32 = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    const sdf_shader: z.Shader2D = try z.Shader2D.init(
        gpa,
        f.gpu.device,
        f.gpu.queue,
        f.gl.renderer(),
        sdf_wgsl,
        "text_sdf",
    );
    s.* = .{
        .ui_font = ui_font,
        // A deliberately small coverage atlas so the blur is honest at big sizes.
        .bitmap_font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32),
        .sdf_font = try z.loadFontSdf(f, gpa, atkinson_mono_ttf, 128),
        .sdf_shader = sdf_shader,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.bitmap_font);
    z.unloadFont(gpa, s.sdf_font);
    z.unloadFont(gpa, s.ui_font);
    s.sdf_shader.deinit();
    s.ui_host.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    const word: []const u8 = samples[s.sample_idx];

    z.clearViewport(f, .{ .r = 16, .g = 18, .b = 26, .a = 255 });
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    const panel_h: f32 = 210;
    const top: f32 = 44;
    const avail: f32 = fh - panel_h - top - 16;
    const row_h: f32 = avail / 2.0;

    // ---- row 1: the plain coverage (bitmap) font --------------------------
    const bm_row_y: f32 = top;
    f.gl.text(.{ 16, bm_row_y }, "BITMAP (coverage atlas) - blurs when magnified", .{
        .size = 15,
        .color = c.slate_400,
        .font = &s.ui_font,
    });
    drawCentered(f, s.bitmap_font, word, s.size, fw, bm_row_y + 28, row_h - 40, c.sky_300, null);

    // divider
    f.gl.rect(.{ .x = 16, .y = top + row_h, .width = fw - 32, .height = 1 }, .{
        .color = .{ .r = 40, .g = 44, .b = 54, .a = 255 },
    });

    // ---- row 2: the SDF font, drawn through the SDF shader -----------------
    const sdf_row_y: f32 = top + row_h;
    f.gl.text(.{ 16, sdf_row_y }, "SDF (distance field) - crisp at any size", .{
        .size = 15,
        .color = c.slate_400,
        .font = &s.ui_font,
    });
    s.sdf_shader.setParams(.{ .params = .{ s.smoothing, 0, 0, 0 } });
    drawCentered(f, s.sdf_font, word, s.size, fw, sdf_row_y + 28, row_h - 40, c.amber_300, &s.sdf_shader);

    // ---- control panel ----------------------------------------------------
    u.setNextWindowPos(.{ 8, fh - panel_h - 8 }, .{});
    u.setNextWindowSize(.{ fw - 16.0, panel_h }, .{});
    if (u.window("SDF text (loadFontSdf + smoothstep shader)", .{})) |w| {
        defer w.close();

        u.text("Both rows draw the same word at the SAME px size.", .{});
        u.text("Crank size up: the bitmap softens, the SDF holds its edge.", .{});
        u.separator();

        u.text("sample: {s}", .{word});
        if (u.button("< prev", .{})) {
            s.sample_idx = if (s.sample_idx == 0) samples.len - 1 else s.sample_idx - 1;
        }
        u.sameLine(.{});
        if (u.button("next >", .{})) {
            s.sample_idx = if (s.sample_idx + 1 >= samples.len) 0 else s.sample_idx + 1;
        }

        u.separator();
        _ = u.slider("size px", &s.size, .{ .min = 40.0, .max = 360.0 });
        _ = u.slider("SDF edge", &s.smoothing, .{ .min = 0.02, .max = 0.14 });
    }

    s.ui_host.render(f);
    common.caption(
        f.gl,
        s.ui_font,
        "SDF: one distance-field atlas stays sharp at any zoom - z.loadFontSdf + src/shaders/text_sdf_fs.zig",
    );
    z.endDrawing(f.gl);
}

/// Draw `word` horizontally centred in a row band. If `shader` is non-null,
/// wrap the text in begin/endShaderMode so it renders through that shader.
fn drawCentered(
    f: *z.Frame,
    font: z.Font,
    word: []const u8,
    size: f32,
    fw: f32,
    band_top: f32,
    band_h: f32,
    tint: Color,
    shader: ?*const z.Shader2D,
) void {
    const dim: Vec2 = z.measureText(font, word, size);
    const tx: f32 = @max(12.0, (fw - dim[0]) * 0.5);
    const ty: f32 = band_top + @max(0.0, (band_h - dim[1]) * 0.5);
    if (shader) |sh| {
        z.beginShaderMode(f.gl, sh.*);
        f.gl.text(.{ tx, ty }, word, .{ .size = size, .color = tint, .font = &font });
        z.endShaderMode(f.gl);
    } else {
        f.gl.text(.{ tx, ty }, word, .{ .size = size, .color = tint, .font = &font });
    }
}

/// Descriptor-only: the runner/launcher drives begin/end (no offscreen pass).
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - text font SDF",
            .width = 800,
            .height = 680,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
