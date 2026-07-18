//! textures_magnifying_glass — port of raylib [textures] example.
//! A 2x magnifier follows the pointer. The magnified world is rendered into a
//! 256x256 render texture through a zoomed Camera2D, where hidden bunnies are
//! drawn with MULTIPLY blend so they blend into the parrots below (invisible in
//! the normal view). The square RTT is masked to a circle by drawing a white
//! circle over it with MULTIPLY blend — whose alpha function (src.a * dst.a)
//! zeroes the RTT alpha outside the circle. Drag/move the pointer to hunt.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = Color;
const Vec2 = zm.Vec2;

const parrots_png = @embedFile("parrots.png");
const bunny_png = @embedFile("raybunny.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const glass: f32 = 256; // magnifier size

const State = struct {
    parrots: z.WgpuTexture,
    bunny: z.WgpuTexture,
    mask: z.WgpuTexture,
    rt: z.RenderTexture,
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.parrots.deinit();
    s.bunny.deinit();
    s.mask.deinit();
    s.rt.deinit();
}

fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    z.unloadImage(gpa, img);
    return tex;
}

/// A 256x256 white disc on transparent — the circular alpha mask.
fn buildCircleMask(gpa: Allocator, gl: *z.WgpuGl) !z.WgpuTexture {
    const sz: usize = 256;
    const r: f32 = 128;
    const pixels: []u8 = try gpa.alloc(u8, sz * sz * 4);
    defer gpa.free(pixels);
    for (0..sz) |y| {
        for (0..sz) |x| {
            const dx: f32 = float(x) - r;
            const dy: f32 = float(y) - r;
            const inside: bool = (dx * dx + dy * dy) <= r * r;
            const idx: usize = (y * sz + x) * 4;
            pixels[idx + 0] = 255;
            pixels[idx + 1] = 255;
            pixels[idx + 2] = 255;
            pixels[idx + 3] = if (inside) 255 else 0;
        }
    }
    const img: z.Image = .{
        .data = @ptrCast(pixels.ptr),
        .width = @intCast(sz),
        .height = @intCast(sz),
        .mipmaps = 1,
        .format = @intFromEnum(z.PixelFormat.uncompressed_r8g8b8a8),
    };
    return z.loadTextureFromImage(gl, img);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .parrots = try uploadPng(gpa, f.gl, parrots_png),
        .bunny = try uploadPng(gpa, f.gl, bunny_png),
        .mask = try buildCircleMask(gpa, f.gl),
        .rt = z.loadRenderTexture(f.gl, @intFromFloat(glass), @intFromFloat(glass)),
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
    };
}

fn drawScene(f: *z.Frame, s: *State) void {
    const pw: f32 = float(s.parrots.width);
    const ph: f32 = float(s.parrots.height);
    f.gl.texture(.{ .x = 144, .y = 33, .width = pw, .height = ph }, s.parrots, .{ .tint = c.white });
    f.gl.text(.{ 154, 6 }, "Find the hidden bunnies!", .{ .size = 20, .color = c.black, .font = &s.font });
}

const zoom: f32 = 2; // magnifier zoom
const half: f32 = glass / 2;

/// Draw a texture into the RTT at world (wx,wy), transformed by the magnifier
/// camera manually: (world - mouse) * zoom + 128. (beginMode2D can't run inside
/// beginTextureMode, so we apply the Camera2D math by hand.)
fn drawMag(
    f: *z.Frame,
    tex: z.WgpuTexture,
    m: Vec2,
    wx: f32,
    wy: f32,
) void {
    const x: f32 = (wx - m[0]) * zoom + half;
    const y: f32 = (wy - m[1]) * zoom + half;
    f.gl.texture(
        .{ .x = x, .y = y, .width = float(tex.width) * zoom, .height = float(tex.height) * zoom },
        tex,
        .{ .tint = c.white },
    );
}

fn update(f: *z.Frame, s: *State) void {
    const m: Vec2 = z.getMousePosition(f.input);

    // OFFSCREEN FIRST: render the magnified world + circular mask into the RTT.
    z.beginTextureMode(f.gl, s.rt, c.raywhite);
    // Magnified parrots + label (manual camera transform).
    drawMag(f, s.parrots, m, 144, 33);
    f.gl.text(
        .{ (154 - m[0]) * zoom + half, (6 - m[1]) * zoom + half },
        "Find the hidden bunnies!",
        .{ .size = 20 * zoom, .color = c.black, .font = &s.font },
    );
    // Hidden bunnies: MULTIPLY makes them take the colour of the parrots below.
    z.beginBlendMode(f.gl, .multiply);
    drawMag(f, s.bunny, m, 250, 350);
    drawMag(f, s.bunny, m, 500, 100);
    drawMag(f, s.bunny, m, 420, 300);
    drawMag(f, s.bunny, m, 650, 10);
    z.endBlendMode(f.gl);
    // Mask to a circle: MULTIPLY's alpha = src.a * dst.a, so the disc's zero
    // alpha outside the circle zeroes the RTT's alpha there.
    z.beginBlendMode(f.gl, .multiply);
    f.gl.texture(.{ .x = 0, .y = 0, .width = glass, .height = glass }, s.mask, .{ .tint = c.white });
    z.endBlendMode(f.gl);
    z.endTextureMode(f.gl);

    // MAIN PASS: normal scene + the magnifier centered on the pointer.
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.raywhite);
    drawScene(f, s);
    f.gl.texture(
        .{ .x = m[0] - glass / 2, .y = m[1] - glass / 2, .width = glass, .height = glass },
        s.rt.asTexture(),
        .{ .tint = c.white },
    );
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures magnifying glass",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
    } },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
    .memory = .managed,
};
