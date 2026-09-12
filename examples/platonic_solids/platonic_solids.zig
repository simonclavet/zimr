//! platonic_solids — the four platonic solids the shape library gained, shown
//! in a row: tetrahedron, octahedron, dodecahedron, icosahedron. They're built
//! FLAT-shaded (each face carries its own normal), so you should see crisp,
//! faceted faces with sharp edges — not the rounded look you'd get from smooth
//! normals. They slowly spin so you can appreciate the geometry.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;

const solid_count: usize = 4;

const State = struct {
    solids: [solid_count]z.Model,
    cam: z.OrbitCamera,
};

// spread the four solids out along X
const positions = [solid_count]zm.Vec{
    pointVec(-4.2, 0, 0),
    pointVec(-1.4, 0, 0),
    pointVec(1.4, 0, 0),
    pointVec(4.2, 0, 0),
};

const tints = [solid_count][3]u8{
    .{ 235, 120, 100 }, // tetrahedron
    .{ 120, 200, 120 }, // octahedron
    .{ 130, 160, 240 }, // dodecahedron
    .{ 240, 190, 90 }, // icosahedron
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // each generator hands back a flat-shaded mesh; loadModelFromMesh takes it
    const meshes = [solid_count]z.types.Mesh{
        try z.genMeshTetrahedron(gpa),
        try z.genMeshOctahedron(gpa),
        try z.genMeshDodecahedron(gpa),
        try z.genMeshIcosahedron(gpa),
    };
    var solids: [solid_count]z.Model = undefined;
    var i: usize = 0;
    while (i < solid_count) : (i += 1) {
        solids[i] = try z.loadModelFromMesh(f.gl, gpa, meshes[i]);
    }
    s.* = .{
        .solids = solids,
        .cam = .{ .target = pointVec(0, 0, 0), .distance = 12.0, .pitch = 0.35, .yaw = 0.6 },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    var i: usize = 0;
    while (i < solid_count) : (i += 1) {
        z.unloadModel(gpa, s.solids[i]);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const cam: Camera3D = s.cam.update(f, false, .{ .fovy_deg = 42 });
    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 22, .a = 255 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    var i: usize = 0;
    while (i < solid_count) : (i += 1) {
        z.drawModel(f.gl, s.solids[i], positions[i], 1.3, .{
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
            .title = "zimr - platonic solids",
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
