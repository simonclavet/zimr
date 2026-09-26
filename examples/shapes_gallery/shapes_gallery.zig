//! shapes_gallery - visual check + showcase for the new parametric shape spine
//! and the mesh-ops toolkit. Renders the eight parametric primitives (sphere,
//! hemisphere, cylinder, cone, torus, trefoil knot, plane, klein bottle) plus a
//! COMPOSED shape - a dumbbell built from a cylinder + two spheres with
//! `meshMerge` and `meshTranslate` - in a grid under an orbit camera. Lit by the
//! immediate renderer's directional shade, so orientation, winding, and the
//! welded seam normals are all visible.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Vec = zm.Vec;
const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;

const num: usize = 9;

const State = struct {
    models: [num]z.Model,
    cam: z.OrbitCamera,
};

const positions = [num]Vec{
    pointVec(-3.9, 0, -1.6), pointVec(-1.3, 0, -1.6), pointVec(1.3, 0, -1.6), pointVec(3.9, 0, -1.6),
    pointVec(-3.9, 0, 1.6),  pointVec(-1.3, 0, 1.6),  pointVec(1.3, 0, 1.6),  pointVec(3.9, 0, 1.6),
    pointVec(0, 0.75, 4.0), // dumbbell, front centre
};

const tints = [num][3]u8{
    .{ 235, 110, 90 }, // sphere
    .{ 240, 175, 70 }, // hemisphere
    .{ 120, 200, 110 }, // cylinder
    .{ 90, 190, 200 }, // cone
    .{ 110, 150, 240 }, // torus
    .{ 190, 130, 235 }, // knot
    .{ 210, 210, 220 }, // plane
    .{ 240, 130, 180 }, // klein
    .{ 230, 205, 120 }, // dumbbell (composed)
};

/// Build a dumbbell = a cylinder bar + two end spheres, via mesh-ops.
fn buildDumbbell(gpa: Allocator) !z.types.Mesh {
    var bar: z.types.Mesh = try z.genMeshCylinder(gpa, 0.16, 1.5, 20, 2);
    z.meshTranslate(&bar, 0, -0.75, 0); // cylinder spans 0..height -> centre it
    var ball_a: z.types.Mesh = try z.genMeshSphere(gpa, 0.42, 20, 16);
    z.meshTranslate(&ball_a, 0, 0.75, 0);
    var ball_b: z.types.Mesh = try z.genMeshSphere(gpa, 0.42, 20, 16);
    z.meshTranslate(&ball_b, 0, -0.75, 0);
    const step1: z.types.Mesh = try z.meshMerge(gpa, bar, ball_a);
    const dumbbell: z.types.Mesh = try z.meshMerge(gpa, step1, ball_b);
    z.unloadMesh(gpa, bar);
    z.unloadMesh(gpa, ball_a);
    z.unloadMesh(gpa, ball_b);
    z.unloadMesh(gpa, step1);
    return dumbbell;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var models: [num]z.Model = undefined;
    const simple = [8]z.types.Mesh{
        try z.genMeshSphere(gpa, 0.75, 32, 24),
        try z.genMeshHemiSphere(gpa, 0.8, 32, 16),
        try z.genMeshCylinder(gpa, 0.5, 1.3, 28, 4),
        try z.genMeshCone(gpa, 0.6, 1.3, 28, 4),
        try z.genMeshTorus(gpa, 0.55, 0.24, 36, 18),
        try z.genMeshKnot(gpa, 1.0, 0.7, 128, 20),
        try z.genMeshPlane(gpa, 1.4, 1.4, 6, 6),
        try z.genMeshKlein(gpa, 0.11, 48, 26),
    };
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        models[i] = try z.loadModelFromMesh(f.gl, gpa, simple[i]);
    }
    const dumbbell: z.types.Mesh = try buildDumbbell(gpa);
    models[8] = try z.loadModelFromMesh(f.gl, gpa, dumbbell);
    s.* = .{
        .models = models,
        .cam = .{ .target = pointVec(0, 0.1, 0.6), .distance = 13.0, .pitch = 0.5, .yaw = 0.7 },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    var i: usize = 0;
    while (i < num) : (i += 1) {
        z.unloadModel(gpa, s.models[i]);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const cam: Camera3D = s.cam.update(f, false, .{ .fovy_deg = 45 });
    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 22, .a = 255 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    var i: usize = 0;
    while (i < num) : (i += 1) {
        z.drawModel(f.gl, s.models[i], positions[i], 1.0, .{
            .r = tints[i][0],
            .g = tints[i][1],
            .b = tints[i][2],
            .a = 255,
        });
    }
    z.endMode3D(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - shapes gallery",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .update = update,
    .deinit = deinit,
};
