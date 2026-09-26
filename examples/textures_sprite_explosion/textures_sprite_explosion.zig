//! textures_sprite_explosion - port of raylib [textures] example.
//! A 5x5 explosion sprite sheet, auto-looping. drawTextureRec over
//! normalized-UV sub-rects.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const c = z.colors;

const explosion_png = @embedFile("explosion.png");
const frames_per_line: u32 = 5;
const num_lines: u32 = 5;

const State = struct {
    explosion: z.WgpuTexture,
    current_frame: u32 = 0,
    current_line: u32 = 0,
    frames_counter: u32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.explosion.deinit();
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
    s.* = .{ .explosion = try uploadPng(gpa, f.gl, explosion_png) };
}

fn update(f: *z.Frame, s: *State) void {
    s.frames_counter += 1;
    if (s.frames_counter >= 60 / 15) {
        s.frames_counter = 0;
        s.current_frame += 1;
        if (s.current_frame >= frames_per_line) {
            s.current_frame = 0;
            s.current_line += 1;
            if (s.current_line >= num_lines) {
                s.current_line = 0;
            }
        }
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 8, .g = 8, .b = 14, .a = 255 });

    const fw: f32 = float(s.explosion.width) / float(frames_per_line);
    const fh: f32 = float(s.explosion.height) / float(num_lines);
    const x: f32 = (f.window.widthf() - fw) * 0.5;
    const y: f32 = (f.window.heightf() - fh) * 0.5;
    f.gl.texture(
        .{ .x = x, .y = y, .width = fw, .height = fh },
        s.explosion,
        .{
            .source = .{
                .x = float(s.current_frame) * fw,
                .y = float(s.current_line) * fh,
                .width = fw,
                .height = fh,
            },
            .tint = c.white,
        },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures sprite explosion",
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
