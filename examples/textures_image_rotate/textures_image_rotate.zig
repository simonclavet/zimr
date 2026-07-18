//! textures_image_rotate — port of raylib [textures] example.
//! Load the raylib logo three times, rotate each on the CPU (imageRotate,
//! arbitrary angle) by 45°, 90°, and -90°, upload to GPU textures, and cycle
//! between them on left-click / RIGHT. Rotation happens once at init in RAM;
//! the frame loop only draws the currently selected texture.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const radFromDeg = zm.radFromDeg;
const c = z.colors;

const logo_png = @embedFile("raylib_logo.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const num_textures: u32 = 3;
const angles_deg = [num_textures]f32{ 45.0, 90.0, -90.0 };

const State = struct {
    textures: [num_textures]z.WgpuTexture,
    current: u32 = 0,
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    for (&s.textures) |*tx| {
        tx.deinit();
    }
}

/// Load the embedded PNG, rotate it by `angle_deg` on the CPU, upload the
/// rotated pixels to a GPU texture, then free the CPU copy.
fn makeRotated(gpa: Allocator, gl: *z.WgpuGl, angle_deg: f32) !z.WgpuTexture {
    var img: z.Image = try z.loadImageFromMemory(gpa, logo_png);
    try z.imageRotate(gpa, &img, radFromDeg(angle_deg));
    const tex: z.WgpuTexture = z.loadTextureFromImage(gl, img);
    if (img.data) |d| {
        const n: usize = @as(usize, @intCast(img.width)) * @as(usize, @intCast(img.height)) * 4;
        gpa.free(@as([*]u8, @ptrCast(d))[0..n]);
    }
    return tex;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var textures: [num_textures]z.WgpuTexture = undefined;
    var i: u32 = 0;
    while (i < num_textures) : (i += 1) {
        textures[i] = try makeRotated(gpa, f.gl, angles_deg[i]);
    }
    s.* = .{
        .textures = textures,
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
    };
}

fn update(f: *z.Frame, s: *State) void {
    if (z.isMouseButtonPressed(f.input, .left) or z.isKeyPressed(f.input, .right)) {
        s.current = (s.current + 1) % num_textures;
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, .{ .r = 22, .g = 24, .b = 32, .a = 255 });

    const tex: z.WgpuTexture = s.textures[s.current];
    const x: f32 = (f.window.widthf() - float(tex.width)) * 0.5;
    const y: f32 = (f.window.heightf() - float(tex.height)) * 0.5;
    f.gl.texture(
        .{ .x = x, .y = y, .width = float(tex.width), .height = float(tex.height) },
        tex,
        .{ .tint = c.white },
    );

    f.gl.text(
        .{ 40, 400 },
        "LEFT CLICK / RIGHT: rotate the image clockwise",
        .{ .size = 20, .color = c.slate_300, .font = &s.font },
    );
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures image rotate",
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
