//! textured_cube — validates the new textured-3D pipeline (`drawCubeTexture`):
//! an axis-aligned cube with a generated checker texture mapped 0..1 on each of
//! its six faces, depth-tested in the immediate 3D pass alongside a ground grid
//! (so the cube occludes the grid lines behind it). The camera auto-orbits to
//! show every face. This is the first immediate-mode TEXTURED 3D draw — the 3D
//! batch was solid-colour-only before; `drawCubeTexture`/`drawBillboard` add a
//! texture-sampling pipeline that shares the depth pass + camera with the solids.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Camera3D = zm.Camera3D;
const pi = zm.pi;
const pointVec = zm.pointVec;
const vec = zm.vec;

const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    tex: z.WgpuTexture,
    font: z.Font,
    angle: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.tex.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const img: z.Image = try z.genImageChecked(gpa, 64, 64, 8, 8, c.sky_400, c.slate_800);
    const tex: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    z.unloadImage(gpa, img);
    s.* = .{ .tex = tex, .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    s.angle += f.time.delta_time * 25.0; // 25°/sec orbit

    z.clearViewport(f, .{ .r = 12, .g = 14, .b = 20, .a = 255 });

    const rad: f32 = s.angle * pi / 180.0;
    const cam: Camera3D = .{
        .position = pointVec(@cos(rad) * 6.0, 3.5, @sin(rad) * 6.0),
        .target = pointVec(0, 1, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 50,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 16, 1.0);
    z.drawCubeTexture(f.gl, s.tex, pointVec(0, 1, 0), 2.0, c.white);
    z.endMode3D(f.gl);

    common.caption(f.gl, s.font, "drawCubeTexture - checker mapped on each face, depth-tested with the grid");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - textured cube",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
