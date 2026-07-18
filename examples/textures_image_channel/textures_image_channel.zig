//! textures_image_channel — port of raylib [textures] example.
//! Split a PNG into its R, G, B, and A channels on the CPU (imageFromChannel
//! returns a grayscale image per channel), promote each colour channel to RGBA
//! and punch it through the alpha silhouette (imageAlphaMask needs an RGBA
//! target + grayscale mask), then lay them out over a checkerboard: the full
//! image on the left, the four channels tinted in a 2x2 grid.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = Color; // raylib's named palette (raywhite, orange, red, ...)

const fudesumi_png = @embedFile("fudesumi.png");

const State = struct {
    background: z.WgpuTexture,
    full: z.WgpuTexture,
    red: z.WgpuTexture,
    green: z.WgpuTexture,
    blue: z.WgpuTexture,
    alpha: z.WgpuTexture,
    src_w: f32,
    src_h: f32,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.background.deinit();
    s.full.deinit();
    s.red.deinit();
    s.green.deinit();
    s.blue.deinit();
    s.alpha.deinit();
}

/// One colour channel as an RGBA image, masked to the alpha silhouette so only
/// the character's pixels survive.
fn channelRgba(
    gpa: Allocator,
    src: z.Image,
    ch: i32,
    alpha_mask: z.Image,
) !z.Image {
    var img: z.Image = try z.imageFromChannel(gpa, src, ch); // grayscale
    try z.imageFormat(gpa, &img, .uncompressed_r8g8b8a8); // promote to RGBA
    z.imageAlphaMask(&img, alpha_mask); // keep silhouette only
    return img;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const src: z.Image = try z.loadImageFromMemory(gpa, fudesumi_png);
    defer z.unloadImage(gpa, src);

    const alpha_gray: z.Image = try z.imageFromChannel(gpa, src, 3);
    defer z.unloadImage(gpa, alpha_gray);
    var alpha_rgba: z.Image = try z.imageFromChannel(gpa, src, 3);
    defer z.unloadImage(gpa, alpha_rgba);
    try z.imageFormat(gpa, &alpha_rgba, .uncompressed_r8g8b8a8);

    const red_img: z.Image = try channelRgba(gpa, src, 0, alpha_gray);
    defer z.unloadImage(gpa, red_img);
    const green_img: z.Image = try channelRgba(gpa, src, 1, alpha_gray);
    defer z.unloadImage(gpa, green_img);
    const blue_img: z.Image = try channelRgba(gpa, src, 2, alpha_gray);
    defer z.unloadImage(gpa, blue_img);

    const bg: z.Image = try z.genImageChecked(gpa, 800, 450, 40, 22, c.orange, c.gold);
    defer z.unloadImage(gpa, bg);

    s.* = .{
        .background = z.loadTextureFromImage(f.gl, bg),
        .full = z.loadTextureFromImage(f.gl, src),
        .red = z.loadTextureFromImage(f.gl, red_img),
        .green = z.loadTextureFromImage(f.gl, green_img),
        .blue = z.loadTextureFromImage(f.gl, blue_img),
        .alpha = z.loadTextureFromImage(f.gl, alpha_rgba),
        .src_w = float(src.width),
        .src_h = float(src.height),
    };
}

fn update(f: *z.Frame, s: *State) void {
    z.beginDrawing(f.gl);
    z.clearViewport(f, c.raywhite);

    f.gl.texture(.{ .x = 0, .y = 0, .width = 800, .height = 450 }, s.background, .{ .tint = c.white });

    const fw: f32 = s.src_w * 0.8;
    const fh: f32 = s.src_h * 0.8;
    f.gl.texture(.{ .x = 50, .y = 10, .width = fw, .height = fh }, s.full, .{ .tint = c.white });

    const hw: f32 = fw * 0.5;
    const hh: f32 = fh * 0.5;
    f.gl.texture(.{ .x = 410, .y = 10, .width = hw, .height = hh }, s.red, .{ .tint = c.red });
    f.gl.texture(.{ .x = 600, .y = 10, .width = hw, .height = hh }, s.green, .{ .tint = c.green });
    f.gl.texture(.{ .x = 410, .y = 230, .width = hw, .height = hh }, s.blue, .{ .tint = c.blue });
    f.gl.texture(.{ .x = 600, .y = 230, .width = hw, .height = hh }, s.alpha, .{ .tint = c.white });

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures image channel",
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
