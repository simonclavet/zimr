//! textures_screen_buffer - port of raylib [textures] example.
//! A classic palette-cycling fire effect rendered entirely on the CPU: an
//! 8-bit index buffer is seeded along the bottom row and propagated upward with
//! random horizontal drift and decay each frame, mapped through a 256-entry HSV
//! palette into an RGBA buffer, then uploaded to a texture and drawn 2x scaled.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = Color;

const scale_factor: i32 = 2;
const img_w: usize = 800 / scale_factor;
const img_h: usize = 450 / scale_factor;
const max_colors: usize = 256;

const State = struct {
    tex: z.WgpuTexture,
    index_buffer: []u8,
    flame_root: []u8,
    pixels: []u8,
    palette: [max_colors]Color,
    prng: std.Random.DefaultPrng,
};

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.index_buffer);
    gpa.free(s.flame_root);
    gpa.free(s.pixels);
    s.tex.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const index_buffer: []u8 = try gpa.alloc(u8, img_w * img_h);
    @memset(index_buffer, 0);
    const flame_root: []u8 = try gpa.alloc(u8, img_w);
    @memset(flame_root, 0);
    const pixels: []u8 = try gpa.alloc(u8, img_w * img_h * 4);
    @memset(pixels, 0);

    var palette: [max_colors]Color = undefined;
    for (0..max_colors) |i| {
        const t: f32 = float(i) / float(max_colors - 1);
        palette[i] = z.colorFromHSV(250.0 + 150.0 * (t * t), t, t);
    }

    const img: z.Image = .{
        .data = @ptrCast(pixels.ptr),
        .width = @intCast(img_w),
        .height = @intCast(img_h),
        .mipmaps = 1,
        .format = @backingInt(z.PixelFormat.uncompressed_r8g8b8a8),
    };
    s.* = .{
        .tex = z.loadTextureFromImage(f.gl, img),
        .index_buffer = index_buffer,
        .flame_root = flame_root,
        .pixels = pixels,
        .palette = palette,
        .prng = std.Random.DefaultPrng.init(0x5EED),
    };
}

fn update(f: *z.Frame, s: *State) void {
    const rng: std.Random = s.prng.random();
    const w: usize = img_w;
    const h: usize = img_h;

    // Grow the flame roots (the hot bottom seed row).
    var x: usize = 2;
    while (x < w) : (x += 1) {
        const grown: i32 = @as(i32, s.flame_root[x]) + rng.intRangeAtMost(i32, 0, 2);
        s.flame_root[x] = if (grown > 255) 255 else @intCast(grown);
    }
    // Copy roots into the bottom row; clear the top row.
    for (0..w) |i| {
        s.index_buffer[i + (h - 1) * w] = s.flame_root[i];
    }
    for (0..w) |i| {
        s.index_buffer[i] = 0;
    }

    // Propagate upward with random drift + decay.
    var y: usize = 1;
    while (y < h) : (y += 1) {
        var xx: usize = 0;
        while (xx < w) : (xx += 1) {
            const i: usize = xx + y * w;
            var ci: u8 = s.index_buffer[i];
            if (ci == 0) {
                continue;
            }
            s.index_buffer[i] = 0;
            const move: i32 = rng.intRangeAtMost(i32, 0, 2) - 1;
            const new_x: i32 = @as(i32, @intCast(xx)) + move;
            if (new_x > 0 and new_x < @as(i32, @intCast(w))) {
                const iabove: usize = @intCast(@as(i32, @intCast(i)) - @as(i32, @intCast(w)) + move);
                const decay: u8 = @intCast(rng.intRangeAtMost(i32, 0, 3));
                ci -= if (decay < ci) decay else ci;
                s.index_buffer[iabove] = ci;
            }
        }
    }

    // Map palette indices to RGBA.
    for (0..w * h) |i| {
        const col: Color = s.palette[s.index_buffer[i]];
        s.pixels[i * 4 + 0] = col.r;
        s.pixels[i * 4 + 1] = col.g;
        s.pixels[i * 4 + 2] = col.b;
        s.pixels[i * 4 + 3] = 255;
    }
    const img: z.Image = .{
        .data = @ptrCast(s.pixels.ptr),
        .width = @intCast(w),
        .height = @intCast(h),
        .mipmaps = 1,
        .format = @backingInt(z.PixelFormat.uncompressed_r8g8b8a8),
    };
    z.updateTexture(f.gl, s.tex, img);

    z.beginDrawing(f.gl);
    z.clearViewport(f, c.black);
    f.gl.texture(
        .{ .x = 0, .y = 0, .width = f.window.widthf(), .height = f.window.heightf() },
        s.tex,
        .{ .tint = c.white },
    );
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures screen buffer",
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
