//! textures_raw_data — port of raylib [textures] example.
//! Demonstrates building a GPU texture from a raw, hand-filled RGBA pixel
//! buffer: we allocate width*height*4 bytes, write an orange/gold checkerboard
//! into it, wrap it in an Image (pointer + dims + format), and upload. A second
//! texture is decoded from fudesumi.png for comparison. (raylib loads a head-
//! less .raw file here; we load the PNG since the pixels are identical.)
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = Color;

const fudesumi_png = @embedFile("fudesumi.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const im_w: i32 = 960;
const im_h: i32 = 480;

const State = struct {
    checked: z.WgpuTexture,
    fudesumi: z.WgpuTexture,
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.checked.deinit();
    s.fudesumi.deinit();
}

/// Build a checkerboard purely from raw pixel bytes, then upload it.
fn buildChecked(gpa: Allocator, gl: *z.WgpuGl) !z.WgpuTexture {
    const w: usize = @intCast(im_w);
    const h: usize = @intCast(im_h);
    const pixels: []u8 = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(pixels);
    for (0..h) |y| {
        for (0..w) |x| {
            const is_orange: bool = (x / 32 + y / 32) % 2 == 0;
            const col: Color = if (is_orange) c.orange else c.gold;
            const idx: usize = (y * w + x) * 4;
            pixels[idx + 0] = col.r;
            pixels[idx + 1] = col.g;
            pixels[idx + 2] = col.b;
            pixels[idx + 3] = col.a;
        }
    }
    const img: z.Image = .{
        .data = @ptrCast(pixels.ptr),
        .width = im_w,
        .height = im_h,
        .mipmaps = 1,
        .format = @backingInt(z.PixelFormat.uncompressed_r8g8b8a8),
    };
    return z.loadTextureFromImage(gl, img);
}

fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    z.unloadImage(gpa, img);
    return tex;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .checked = try buildChecked(gpa, f.gl),
        .fudesumi = try uploadPng(gpa, f.gl, fudesumi_png),
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 18),
    };
}

fn update(f: *z.Frame, s: *State) void {
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.raywhite);

    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();

    // Raw-built checkerboard, centered at half opacity.
    const cw: f32 = float(s.checked.width);
    const ch: f32 = float(s.checked.height);
    const faded: Color = .{ .r = 255, .g = 255, .b = 255, .a = 128 };
    f.gl.texture(
        .{ .x = (sw - cw) * 0.5, .y = (sh - ch) * 0.5, .width = cw, .height = ch },
        s.checked,
        .{ .tint = faded },
    );

    // Decoded PNG, centered.
    const fw: f32 = float(s.fudesumi.width);
    const fh: f32 = float(s.fudesumi.height);
    f.gl.texture(
        .{ .x = (sw - fw) * 0.5, .y = (sh - fh) * 0.5, .width = fw, .height = fh },
        s.fudesumi,
        .{ .tint = c.white },
    );

    f.gl.text(
        .{ 40, 20 },
        "CHECKED IMAGE BUILT FROM RAW PIXEL DATA",
        .{ .size = 18, .color = c.raywhite, .font = &s.font },
    );
    f.gl.text(
        .{ 40, sh - 34 },
        "fudesumi.png decoded on the CPU",
        .{ .size = 16, .color = c.darkgray, .font = &s.font },
    );
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures raw data",
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
