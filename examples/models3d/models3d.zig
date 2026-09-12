//! models3d — port of the GL `models3d`: every immediate-3D primitive in
//! one slowly-orbiting scene — sphere, cube, tapered cylinder, capsule, cone —
//! above a ground grid, each wrapped in its wireframe AABB so the
//! `getXxxBoundingBox` helpers are visually verified. The GL version drew these
//! through the rlgl matrix stack; the wgpu immediate API batches them (one draw
//! per topology) and the camera orbits via a hand-set `Camera3D`. The caption is
//! 2D, drawn after endMode3D, so it stays screen-anchored (single shared pass).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const pi = zm.pi;
const pointVec = zm.pointVec;
const vec = zm.vec;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const State = struct {
    font: z.Font,
    angle: f32 = 0, // camera orbit angle (degrees)
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    s.angle += f.time.delta_time * 20.0; // 20°/sec orbit

    z.clearViewport(f, common.palette.bg);

    // Camera orbits at radius 10, height 5, looking at the scene centre.
    const rad: f32 = s.angle * pi / 180.0;
    const cam: Camera3D = .{
        .position = pointVec(@cos(rad) * 10, 5, @sin(rad) * 10),
        .target = pointVec(0, 1, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 50,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 20, 1.0);

    // Sphere (x = -4)
    const sph: Vec = pointVec(-4, 1, 0);
    z.drawSphere(f.gl, sph, .{ .radius = 0.8, .rings = 12, .slices = 16, .color = c.rose_400 });
    z.drawBoundingBox(f.gl, z.getSphereBoundingBox(sph, 0.8), c.rose_200);

    // Cube (x = -2)
    const cube: Vec = pointVec(-2, 1, 0);
    z.drawCube(f.gl, cube, .{ .size = vec(1.2, 1.2, 1.2), .color = c.amber_500 });
    z.drawCubeWires(f.gl, cube, .{ .size = vec(1.2, 1.2, 1.2), .color = c.amber_200 });

    // Tapered cylinder (x = 0): base r=0.7 at y=0.2, top r=0.5 at y=1.8.
    z.drawCylinderBetween(f.gl, pointVec(0, 0.2, 0), pointVec(0, 1.8, 0), 0.7, 0.5, 16, c.emerald_500);
    z.drawBoundingBox(f.gl, z.getCylinderBoundingBox(pointVec(0, 0.2, 0), 0.5, 0.7, 1.6), c.emerald_200);

    // Capsule (x = 2), axis tilted slightly off vertical.
    const cap0: Vec = pointVec(2, 0.4, 0);
    const cap1: Vec = pointVec(2, 1.8, 0.3);
    z.drawCapsule(f.gl, cap0, cap1, 0.4, 12, 6, c.sky_500);
    z.drawBoundingBox(f.gl, z.getCapsuleBoundingBox(cap0, cap1, 0.4), c.sky_200);

    // Cone (x = 4): a tapered cylinder with a zero-radius top.
    z.drawCylinderBetween(f.gl, pointVec(4, 0.2, 0), pointVec(4, 1.8, 0), 0.7, 0.0, 16, c.violet_500);

    z.endMode3D(f.gl);

    common.caption(f.gl, s.font, "WebGPU 3D primitives - sphere, cube, cylinder, capsule, cone (+ AABBs)");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - 3D primitives",
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
