//! textures_polygon_drawing — port of raylib [textures] example.
//! Maps cat.png onto an irregular 10-sided polygon and spins it. zimr's textured
//! triangle path (drawTexturedTriangles) lives in the 3D pipeline, so we view a
//! flat z=0 triangle-fan through an ORTHOGRAPHIC camera looking straight down
//! -Z, which reproduces the original's 2D look with no perspective distortion.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const c = Color;
const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;
const vec = zm.vec;

const cat_png = @embedFile("cat.png");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// UV coords of the polygon rim (last == first to close it).
const texcoords = [_][2]f32{
    .{ 0.75, 0.0 },    .{ 0.25, 0.0 }, .{ 0.0, 0.5 },
    .{ 0.0, 0.75 },    .{ 0.25, 1.0 }, .{ 0.375, 0.875 },
    .{ 0.625, 0.875 }, .{ 0.75, 1.0 }, .{ 1.0, 0.75 },
    .{ 1.0, 0.5 },     .{ 0.75, 0.0 },
};
const rim = texcoords.len - 1; // 10 rim points -> 10 triangles
const tri_verts = rim * 3;
const poly_scale: f32 = 2.6; // world size of the 256px polygon

const State = struct {
    tex: z.WgpuTexture,
    font: z.Font,
    angle: f32 = 0.0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.tex.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try z.loadImageFromMemory(gpa, cat_png);
    defer z.unloadImage(gpa, img);
    s.* = .{
        .tex = z.loadTextureFromImage(f.gl, img),
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
    };
}

/// UV (y-down, 0..1) -> world position (y-up), centered on the origin, rotated.
fn rimPos(uv: [2]f32, angle: f32) [3]f32 {
    const px: f32 = (uv[0] - 0.5) * poly_scale;
    const py: f32 = (0.5 - uv[1]) * poly_scale; // flip V for y-up world
    return .{ px * @cos(angle) - py * @sin(angle), px * @sin(angle) + py * @cos(angle), 0 };
}

fn update(f: *z.Frame, s: *State) void {
    s.angle += f.time.delta_time; // ~1 rad/s spin

    var positions: [tri_verts][3]f32 = undefined;
    var uvs: [tri_verts][2]f32 = undefined;
    var i: usize = 0;
    while (i < rim) : (i += 1) {
        const base: usize = i * 3;
        positions[base + 0] = .{ 0, 0, 0 }; // fan center
        positions[base + 1] = rimPos(texcoords[i], s.angle);
        positions[base + 2] = rimPos(texcoords[i + 1], s.angle);
        uvs[base + 0] = .{ 0.5, 0.5 };
        uvs[base + 1] = texcoords[i];
        uvs[base + 2] = texcoords[i + 1];
    }

    z.beginDrawing(f.gl);
    z.clearViewport(f, c.raywhite);

    const aspect: f32 = f.window.widthf() / f.window.heightf();
    // beginMode3D is always perspective; pull back so the polygon fits the
    // smaller viewport dimension (portrait phones are width-constrained).
    const dist: f32 = 5.7 / @min(1.0, aspect);
    const cam: Camera3D = .{
        .position = pointVec(0, 0, dist),
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 45,
        .projection = 0, // perspective (the only mode beginMode3D honors)
    };
    z.beginMode3D(f.gl, cam);
    z.drawTexturedTriangles(f.gl, s.tex, &positions, &uvs, .{ .tint = c.white, .depth_write = false });
    z.endMode3D(f.gl);

    f.gl.text(.{ 20, 20 }, "textured polygon", .{ .size = 20, .color = c.darkgray, .font = &s.font });
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures polygon drawing",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
        .depth_format = .depth24_plus,
    } },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
};
