//! textures_tiled_drawing — port of raylib [textures] example.
//! Tiles a chosen sub-rectangle of patterns.png across a destination area with
//! adjustable scale, rotation, and tint. drawTextureTiled is a faithful port of
//! raylib's helper (single-tile / one-column / one-row / full-grid cases, with
//! the edge tiles clipped by shrinking the source rect). Pattern, colour,
//! scale, and rotation are driven by UI sliders.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const radFromDeg = zm.radFromDeg;
const int = zm.int;
const Color = zm.Color;
const c = Color;
const Rect = z.Rectangle;

const patterns_png = @embedFile("patterns.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const patterns = [_]Rect{
    .{ .x = 3, .y = 3, .width = 66, .height = 66 },
    .{ .x = 75, .y = 3, .width = 100, .height = 100 },
    .{ .x = 3, .y = 75, .width = 66, .height = 66 },
    .{ .x = 7, .y = 156, .width = 50, .height = 50 },
    .{ .x = 85, .y = 106, .width = 90, .height = 45 },
    .{ .x = 75, .y = 154, .width = 100, .height = 60 },
};
const palette = [_]Color{
    c.black, c.maroon, c.orange, c.blue,     c.purple,
    c.beige, c.lime,   c.red,    c.darkgray, c.skyblue,
};

const State = struct {
    tex: z.WgpuTexture,
    ui_host: z.UiHost,
    font: z.Font,
    active_pattern: f32 = 0,
    active_color: f32 = 2, // orange, like the raylib default feel
    scale: f32 = 1.0,
    rotation_deg: f32 = 0.0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.tex.deinit();
}

fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    z.unloadImage(gpa, img);
    return tex;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const ui_font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18);
    s.* = .{
        .tex = try uploadPng(gpa, f.gl, patterns_png),
        .font = ui_font,
        .ui_host = z.UiHost.init(gpa, ui_font),
    };
}

fn rect(x: f32, y: f32, w: f32, h: f32) Rect {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

/// Faithful port of raylib's DrawTextureTiled: fill `dest` by repeating
/// `source` at `source_size*scale`, clipping the edge tiles.
fn drawTextureTiled(
    gl: *z.WgpuGl,
    tex: z.WgpuTexture,
    source: Rect,
    dest: Rect,
    origin: zm.Vec2,
    rotation_rad: f32,
    scale: f32,
    tint: Color,
) void {
    if (scale <= 0.0 or source.width == 0 or source.height == 0) {
        return;
    }
    const tw: f32 = source.width * scale;
    const th: f32 = source.height * scale;
    const sx: f32 = source.x;
    const sy: f32 = source.y;
    const sw: f32 = source.width;
    const sh: f32 = source.height;

    const tile = struct {
        fn draw(g: *z.WgpuGl, t: z.WgpuTexture, sr: Rect, dr: Rect, o: zm.Vec2, r: f32, ti: Color) void {
            g.texture(dr, t, .{
                .source = sr,
                .origin = o,
                .rotation_rad = r,
                .tint = ti,
            });
        }
    }.draw;

    if (dest.width < tw and dest.height < th) {
        const src: Rect = rect(sx, sy, (dest.width / tw) * sw, (dest.height / th) * sh);
        tile(gl, tex, src, dest, origin, rotation_rad, tint);
        return;
    }
    if (dest.width <= tw) {
        var dy: f32 = 0;
        while (dy + th < dest.height) : (dy += th) {
            const src: Rect = rect(sx, sy, (dest.width / tw) * sw, sh);
            tile(gl, tex, src, rect(dest.x, dest.y + dy, dest.width, th), origin, rotation_rad, tint);
        }
        if (dy < dest.height) {
            const src: Rect = rect(sx, sy, (dest.width / tw) * sw, ((dest.height - dy) / th) * sh);
            tile(gl, tex, src, rect(dest.x, dest.y + dy, dest.width, dest.height - dy), origin, rotation_rad, tint);
        }
        return;
    }
    if (dest.height <= th) {
        var dx: f32 = 0;
        while (dx + tw < dest.width) : (dx += tw) {
            const src: Rect = rect(sx, sy, sw, (dest.height / th) * sh);
            tile(gl, tex, src, rect(dest.x + dx, dest.y, tw, dest.height), origin, rotation_rad, tint);
        }
        if (dx < dest.width) {
            const src: Rect = rect(sx, sy, ((dest.width - dx) / tw) * sw, (dest.height / th) * sh);
            tile(gl, tex, src, rect(dest.x + dx, dest.y, dest.width - dx, dest.height), origin, rotation_rad, tint);
        }
        return;
    }
    // Full grid: columns of full tiles, each column clipped at the bottom, then
    // a final clipped right-hand column.
    var dx: f32 = 0;
    while (dx + tw < dest.width) : (dx += tw) {
        var dy: f32 = 0;
        while (dy + th < dest.height) : (dy += th) {
            tile(gl, tex, source, rect(dest.x + dx, dest.y + dy, tw, th), origin, rotation_rad, tint);
        }
        if (dy < dest.height) {
            const src: Rect = rect(sx, sy, sw, ((dest.height - dy) / th) * sh);
            tile(gl, tex, src, rect(dest.x + dx, dest.y + dy, tw, dest.height - dy), origin, rotation_rad, tint);
        }
    }
    if (dx < dest.width) {
        var dy: f32 = 0;
        while (dy + th < dest.height) : (dy += th) {
            const src: Rect = rect(sx, sy, ((dest.width - dx) / tw) * sw, sh);
            tile(gl, tex, src, rect(dest.x + dx, dest.y + dy, dest.width - dx, th), origin, rotation_rad, tint);
        }
        if (dy < dest.height) {
            const src: Rect = rect(sx, sy, ((dest.width - dx) / tw) * sw, ((dest.height - dy) / th) * sh);
            const dr: Rect = rect(dest.x + dx, dest.y + dy, dest.width - dx, dest.height - dy);
            tile(gl, tex, src, dr, origin, rotation_rad, tint);
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.raywhite);

    const pat_i: usize = @min(patterns.len - 1, int(usize, @max(0, s.active_pattern)));
    const col_i: usize = @min(palette.len - 1, int(usize, @max(0, s.active_color)));

    // Tile the whole viewport; the opaque UI panel overlays the top-left.
    const dest: Rect = rect(0, 0, f.window.widthf(), f.window.heightf());
    drawTextureTiled(
        f.gl,
        s.tex,
        patterns[pat_i],
        dest,
        .{ 0, 0 },
        radFromDeg(s.rotation_deg),
        s.scale,
        palette[col_i],
    );

    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    ui.ctx.style.window_bg = .{ .r = 15, .g = 15, .b = 15, .a = 255 };
    if (ui.window("Tiled drawing", .{ .initial_pos = .{ 10, 10 }, .initial_size = .{ 200, 200 } })) |w| {
        defer w.close();
        _ = ui.slider("Pattern", &s.active_pattern, .{ .min = 0, .max = float(patterns.len - 1), .fmt = "{d:.0}" });
        _ = ui.slider("Color", &s.active_color, .{ .min = 0, .max = float(palette.len - 1), .fmt = "{d:.0}" });
        _ = ui.slider("Scale", &s.scale, .{ .min = 0.25, .max = 3.0, .fmt = "{d:.2}" });
        _ = ui.slider("Rotation", &s.rotation_deg, .{ .min = 0, .max = 360, .fmt = "{d:.0}" });
    }
    s.ui_host.render(f);

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures tiled drawing",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
    } },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
};
