//! instancing — port of the GL `instancing`: 1000 cubes (a 10×10×10 grid)
//! drawn in ONE instanced GPU draw. The GL version split a per-instance mat4
//! into four vec4 vertex attributes through a custom GLSL shader; on wgpu the
//! engine owns that — `drawMeshInstanced` keeps the cube mesh GPU-resident and
//! streams a per-instance buffer (model matrix + colour, instance step-mode),
//! and the instanced cube3d shader reconstructs the matrix on the GPU. Each cube
//! spins on its own Y axis at a phase from its grid position, so the motion is
//! spatially varied rather than synchronised. The camera slowly orbits.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Vec = zm.Vec;
const float = zm.float;
const mulMat = zm.mulMat;
const pi = zm.pi;
const pointVec = zm.pointVec;
const rotationY = zm.rotationY;
const translationV = zm.translationV;
const vec = zm.vec;
const co = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const grid: usize = 10;
const instance_count: usize = grid * grid * grid;
const spacing: f32 = 1.2;

const State = struct {
    font: z.Font,
    gpa: Allocator,
    cube: z.Mesh,
    /// Grid base positions (fixed); per-frame transforms derive from these.
    base_positions: []Vec,
    /// Per-instance model matrices, rebuilt each frame, passed to drawMeshInstanced.
    transforms: []Mat,
    angle: f32 = 0, // camera orbit (degrees)
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadMesh(gpa, s.cube);
    gpa.free(s.base_positions);
    gpa.free(s.transforms);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const positions: []Vec = try gpa.alloc(Vec, instance_count);
    errdefer gpa.free(positions);
    const transforms: []Mat = try gpa.alloc(Mat, instance_count);
    errdefer gpa.free(transforms);

    // Grid×grid×grid centred on the origin, `spacing` units apart.
    const half: f32 = float(grid - 1) * 0.5;
    var idx: usize = 0;
    var zi: usize = 0;
    while (zi < grid) : (zi += 1) {
        var yi: usize = 0;
        while (yi < grid) : (yi += 1) {
            var xi: usize = 0;
            while (xi < grid) : (xi += 1) {
                positions[idx] = pointVec(
                    (float(xi) - half) * spacing,
                    (float(yi) - half) * spacing,
                    (float(zi) - half) * spacing,
                );
                idx += 1;
            }
        }
    }

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .gpa = gpa,
        .cube = try z.genMeshCube(gpa, 0.4, 0.4, 0.4),
        .base_positions = positions,
        .transforms = transforms,
    };
}

fn update(f: *z.Frame, s: *State) void {
    s.angle += f.time.delta_time * 12.0; // 12°/sec orbit
    const t: f32 = f.time.time;

    // Rebuild per-instance transforms: each cube rotates around its own Y axis
    // at a phase derived from its grid position, then translates to that cell.
    var i: usize = 0;
    while (i < instance_count) : (i += 1) {
        const p: Vec = s.base_positions[i];
        const phase: f32 = p[0] * 0.5 + p[2] * 0.7 + t;
        s.transforms[i] = mulMat(translationV(p), rotationY(phase));
    }

    z.clearViewport(f, co.palette.bg);

    const orbit: f32 = s.angle * pi / 180.0;
    const dist: f32 = float(grid) * spacing * 1.6;
    const cam: Camera3D = .{
        .position = pointVec(@cos(orbit) * dist, dist * 0.45, @sin(orbit) * dist),
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 50,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawMeshInstanced(f.gl, &s.cube, s.transforms, c.sky_400);
    z.endMode3D(f.gl);

    const hud: []const u8 = allocPrint(
        s.gpa,
        "instancing - {d} cubes ({d}x{d}x{d}) in one instanced draw",
        .{ instance_count, grid, grid, grid },
    ) catch "instancing";
    defer s.gpa.free(hud);
    co.caption(f.gl, s.font, hud);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - instancing",
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
