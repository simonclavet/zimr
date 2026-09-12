//! icosphere_demo — shows the icosphere refining from its icosahedron seed into
//! a smooth ball. Four copies sit in a row at subdivision levels 0, 1, 2, 3:
//! the leftmost is just the 20-face icosahedron; each step to the right splits
//! every triangle into four and pushes the new points onto the sphere, so the
//! silhouette rounds out and the surface smooths. This is the geodesic sphere —
//! uniform triangles, no pinched poles — the better base for displacement work.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;

const step_count: usize = 4;

const State = struct {
    spheres: [step_count]z.Model,
    cam: z.OrbitCamera,
};

const positions = [step_count]zm.Vec{
    pointVec(-4.2, 0, 0),
    pointVec(-1.4, 0, 0),
    pointVec(1.4, 0, 0),
    pointVec(4.2, 0, 0),
};

// one warm tint, brightening a touch as the sphere gets denser
const tints = [step_count][3]u8{
    .{ 200, 120, 110 },
    .{ 215, 150, 110 },
    .{ 230, 180, 110 },
    .{ 245, 210, 120 },
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var spheres: [step_count]z.Model = undefined;
    var subdivisions: i32 = 0;
    while (subdivisions < step_count) : (subdivisions += 1) {
        // radius 1, increasing subdivision each step
        const mesh: z.types.Mesh = try z.genMeshIcosphere(gpa, 1.0, subdivisions);
        spheres[@intCast(subdivisions)] = try z.loadModelFromMesh(f.gl, gpa, mesh);
    }
    s.* = .{
        .spheres = spheres,
        .cam = .{ .target = pointVec(0, 0, 0), .distance = 12.0, .pitch = 0.35, .yaw = 0.5 },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    var i: usize = 0;
    while (i < step_count) : (i += 1) {
        z.unloadModel(gpa, s.spheres[i]);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const cam: Camera3D = s.cam.update(f, false, .{ .fovy_deg = 42 });
    z.clearViewport(f, .{ .r = 14, .g = 16, .b = 22, .a = 255 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    var i: usize = 0;
    while (i < step_count) : (i += 1) {
        z.drawModel(f.gl, s.spheres[i], positions[i], 1.1, .{
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
            .title = "zimr - icosphere subdivision",
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
