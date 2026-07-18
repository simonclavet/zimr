//! textures_sprite_button — port of raylib [textures] example.
//! A 3-frame button sheet (normal / hover / pressed) selected by mouse state.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Vec2 = zm.Vec2;
const c = z.colors;

const button_png = @embedFile("button.png");
const num_frames: u32 = 3;

const State = struct { tex: z.WgpuTexture };

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.tex.deinit();
}

fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    if (img.data) |d| {
        const n: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4;
        gpa.free(@as([*]u8, @ptrCast(d))[0..n]);
    }
    return tex;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .tex = try uploadPng(gpa, f.gl, button_png) };
}

fn update(f: *z.Frame, s: *State) void {
    const mp: Vec2 = z.getMousePosition(f.input);
    const bw: f32 = float(s.tex.width);
    const bh: f32 = float(s.tex.height) / float(num_frames);
    const bx: f32 = (f.window.widthf() - bw) * 0.5;
    const by: f32 = (f.window.heightf() - bh) * 0.5;

    var state: u32 = 0;
    if (mp[0] >= bx and mp[0] <= bx + bw and mp[1] >= by and mp[1] <= by + bh) {
        state = if (z.isMouseButtonDown(f.input, .left)) 2 else 1;
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 20, .g = 24, .b = 32, .a = 255 });
    const frame_h: f32 = float(s.tex.height) / float(num_frames);
    f.gl.texture(
        .{ .x = bx, .y = by, .width = bw, .height = bh },
        s.tex,
        .{
            .source = .{
                .x = 0,
                .y = float(state) * frame_h,
                .width = float(s.tex.width),
                .height = frame_h,
            },
            .tint = c.white,
        },
    );
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures sprite button",
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
