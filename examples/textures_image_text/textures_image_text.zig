//! textures_image_text — draw text INTO a CPU image, then upload the result as a
//! texture and display it. Ports raylib's `textures_image_text` (a generated
//! checker image instead of the resources/parrots.png asset): text is rasterized
//! onto the image pixels with `imageDrawTextWithFont` BEFORE the image becomes a
//! GPU texture, so the caption is baked into the texels themselves.
//!
//! Leak-clean (`.memory = .managed`): the baked WgpuTexture is freed in `deinit`;
//! the font atlas is engine-owned (freed by resetRegistry). Flat census.

const std = @import("std");
const Allocator = std.mem.Allocator;

const z = @import("zimr");
const zm = @import("zm");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const Color = zm.Color;
const c = Color;

const screen_w = 800;
const screen_h = 450;
const img_w = 360;
const img_h = 240;

const State = struct {
    tex: z.WgpuTexture,
    font: z.Font,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Base image: a checker so the baked text reads clearly over it.
    var img: z.Image = try z.genImageChecked(
        gpa,
        img_w,
        img_h,
        30,
        30,
        .{ .r = 28, .g = 36, .b = 66, .a = 255 },
        .{ .r = 40, .g = 52, .b = 92, .a = 255 },
    );

    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 30);
    // Rasterize the caption onto the CPU image (before it becomes a texture).
    z.imageDrawTextWithFont(&img, font, "[ text baked into", .{ 22, 40 }, 30, 1, c.gold);
    z.imageDrawTextWithFont(&img, font, "  the image ]", .{ 22, 78 }, 30, 1, c.gold);
    z.imageDrawTextWithFont(&img, font, "these pixels are", .{ 22, 140 }, 24, 1, c.raywhite);
    z.imageDrawTextWithFont(&img, font, "part of the texture", .{ 22, 172 }, 24, 1, c.raywhite);

    const tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    z.unloadImage(gpa, img);
    s.* = .{ .tex = tex, .font = font };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.tex.deinit();
}

fn update(f: *z.Frame, s: *State) void {
    // Draw the baked texture scaled up + centered.
    const scale: f32 = 1.6;
    const dw: f32 = @as(f32, img_w) * scale;
    const dh: f32 = @as(f32, img_h) * scale;
    const dx: f32 = (@as(f32, screen_w) - dw) / 2.0;
    const dy: f32 = (@as(f32, screen_h) - dh) / 2.0 + 14.0;
    f.gl.texture(.{ .x = dx, .y = dy, .width = dw, .height = dh }, s.tex, .{ .tint = c.white });

    f.gl.text(
        .{ 24, 22 },
        "imageDrawText: caption baked into the texels",
        .{ .size = 22, .color = c.raywhite, .font = &s.font },
    );
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - textures image text",
            .width = screen_w,
            .height = screen_h,
            .clear = .{ .r = 16.0 / 255.0, .g = 18.0 / 255.0, .b = 26.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
