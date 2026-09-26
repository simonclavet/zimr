//! textures_blend_modes - port of raylib [textures] example.
//! Draws a cyberpunk-street background, then composites the foreground over it
//! with a cycling blend mode (alpha / additive / multiply / premultiplied).
//! SPACE or tap cycles the mode - exercises the engine's beginBlendMode.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = Color;

const bg_png = @embedFile("bg.png");
const fg_png = @embedFile("fg.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const modes = [_]z.BlendMode{ .alpha, .additive, .multiply, .premultiplied };
const mode_names = [_][]const u8{ "ALPHA", "ADDITIVE", "MULTIPLY", "PREMULTIPLIED" };

const State = struct {
    bg: z.WgpuTexture,
    fg: z.WgpuTexture,
    font: z.Font,
    mode: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.bg.deinit();
    s.fg.deinit();
}

fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    const img: z.Image = try z.loadImageFromMemory(gpa, png);
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    z.unloadImage(gpa, img);
    return tex;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .bg = try uploadPng(gpa, f.gl, bg_png),
        .fg = try uploadPng(gpa, f.gl, fg_png),
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
    };
}

fn update(f: *z.Frame, s: *State) void {
    if (z.isKeyPressed(f.input, .space) or z.isMouseButtonPressed(f.input, .left)) {
        s.mode = (s.mode + 1) % modes.len;
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, c.raywhite);

    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();

    const bw: f32 = float(s.bg.width);
    const bh: f32 = float(s.bg.height);
    f.gl.texture(
        .{ .x = (sw - bw) * 0.5, .y = (sh - bh) * 0.5, .width = bw, .height = bh },
        s.bg,
        .{ .tint = c.white },
    );

    const fw: f32 = float(s.fg.width);
    const fh: f32 = float(s.fg.height);
    z.beginBlendMode(f.gl, modes[s.mode]);
    f.gl.texture(
        .{ .x = (sw - fw) * 0.5, .y = (sh - fh) * 0.5, .width = fw, .height = fh },
        s.fg,
        .{ .tint = c.white },
    );
    z.endBlendMode(f.gl);

    f.gl.text(.{ 20, 20 }, "SPACE / TAP: cycle blend mode", .{ .size = 18, .color = c.black, .font = &s.font });
    f.gl.text(.{ 20, sh - 40 }, mode_names[s.mode], .{ .size = 24, .color = c.darkblue, .font = &s.font });
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures blend modes",
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
