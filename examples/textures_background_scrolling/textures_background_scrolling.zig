//! textures_background_scrolling — port of raylib [textures] example.
//! Three parallax cyberpunk layers scroll at different speeds, each drawn twice
//! for a seamless loop and scaled 2x (raylib's DrawTextureEx). PNGs are decoded
//! at runtime -> GPU textures; the CPU pixels are freed right after upload.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const c = z.colors;

const bg_png = @embedFile("cyberpunk_street_background.png");
const mid_png = @embedFile("cyberpunk_street_midground.png");
const fore_png = @embedFile("cyberpunk_street_foreground.png");

const State = struct {
    bg: z.WgpuTexture,
    mid: z.WgpuTexture,
    fore: z.WgpuTexture,
    scroll_back: f32 = 0,
    scroll_mid: f32 = 0,
    scroll_fore: f32 = 0,
};

fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    if (img.data) |d| {
        const n: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4;
        gpa.free(@as([*]u8, @ptrCast(d))[0..n]);
    }
    return tex;
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.bg.deinit();
    s.mid.deinit();
    s.fore.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .bg = try uploadPng(gpa, f.gl, bg_png),
        .mid = try uploadPng(gpa, f.gl, mid_png),
        .fore = try uploadPng(gpa, f.gl, fore_png),
    };
}

fn update(f: *z.Frame, s: *State) void {
    // Parallax: farther layers scroll slower (raylib's speeds).
    s.scroll_back -= 0.1;
    s.scroll_mid -= 0.5;
    s.scroll_fore -= 1.0;
    const bw2: f32 = float(s.bg.width) * 2.0;
    const mw2: f32 = float(s.mid.width) * 2.0;
    const fw2: f32 = float(s.fore.width) * 2.0;
    if (s.scroll_back <= -bw2) {
        s.scroll_back = 0;
    }
    if (s.scroll_mid <= -mw2) {
        s.scroll_mid = 0;
    }
    if (s.scroll_fore <= -fw2) {
        s.scroll_fore = 0;
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 5, .g = 44, .b = 70, .a = 255 });

    // Each layer drawn twice (at offset and +width*2), scaled 2x, seamless.
    const bh2: f32 = float(s.bg.height) * 2.0;
    f.gl.texture(.{ .x = s.scroll_back, .y = 20, .width = bw2, .height = bh2 }, s.bg, .{ .tint = c.white });
    f.gl.texture(.{ .x = bw2 + s.scroll_back, .y = 20, .width = bw2, .height = bh2 }, s.bg, .{ .tint = c.white });

    const mh2: f32 = float(s.mid.height) * 2.0;
    f.gl.texture(.{ .x = s.scroll_mid, .y = 20, .width = mw2, .height = mh2 }, s.mid, .{ .tint = c.white });
    f.gl.texture(.{ .x = mw2 + s.scroll_mid, .y = 20, .width = mw2, .height = mh2 }, s.mid, .{ .tint = c.white });

    const fh2: f32 = float(s.fore.height) * 2.0;
    f.gl.texture(.{ .x = s.scroll_fore, .y = 70, .width = fw2, .height = fh2 }, s.fore, .{ .tint = c.white });
    f.gl.texture(.{ .x = fw2 + s.scroll_fore, .y = 70, .width = fw2, .height = fh2 }, s.fore, .{ .tint = c.white });

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - textures background scrolling",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    // Simple 2D; owns its own begin/endDrawing (uniform style).
    .manages_own_frame = true,
    .memory = .managed,
};
