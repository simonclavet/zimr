//! textures_sprite_animation - port of raylib [textures] example.
//! Cycle a 6-frame sprite sheet (scarfy) at a fixed speed via drawTextureRec
//! over normalized-UV sub-rects. PNG decoded at runtime -> GPU texture.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const c = z.colors;

const scarfy_png = @embedFile("scarfy.png");
const num_frames: u32 = 6;
const frames_speed: u32 = 8;

const State = struct {
    scarfy: z.WgpuTexture,
    current_frame: u32 = 0,
    frames_counter: u32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.scarfy.deinit();
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
    s.* = .{ .scarfy = try uploadPng(gpa, f.gl, scarfy_png) };
}

fn update(f: *z.Frame, s: *State) void {
    s.frames_counter += 1;
    if (s.frames_counter >= 60 / frames_speed) {
        s.frames_counter = 0;
        s.current_frame += 1;
        if (s.current_frame >= num_frames) {
            s.current_frame = 0;
        }
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 20, .g = 22, .b = 30, .a = 255 });

    const fw: f32 = float(s.scarfy.width) / float(num_frames);
    const fh: f32 = float(s.scarfy.height);
    const scale: f32 = 3.0;
    const x: f32 = (f.window.widthf() - fw * scale) * 0.5;
    const y: f32 = (f.window.heightf() - fh * scale) * 0.5;
    f.gl.texture(
        .{ .x = x, .y = y, .width = fw * scale, .height = fh * scale },
        s.scarfy,
        .{
            .source = .{ .x = float(s.current_frame) * fw, .y = 0, .width = fw, .height = fh },
            .tint = c.white,
        },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures sprite animation",
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
