//! rock_demo - a little scatter of procedural rocks, each a noise-displaced
//! icosphere. They all share the same generator; only the seed (and size)
//! differ, so every rock is unique but they're all made the same way. This is
//! the payoff for the icosphere's even triangles - displacing a UV sphere here
//! would tear at the poles. Rocks are recomputed-smooth, so they read as
//! rounded boulders rather than faceted crystals.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Camera3D = zm.Camera3D;
const pointVec = zm.pointVec;

const rock_count: usize = 7;

const State = struct {
    rocks: [rock_count]z.Model,
    cam: z.OrbitCamera,
};

// where each rock sits, how big it is, and its earthy tint
const RockPlacement = struct {
    position: zm.Vec,
    scale: f32,
    seed: i32,
    tint: [3]u8,
};

const placements = [rock_count]RockPlacement{
    .{ .position = pointVec(0, 0, 0), .scale = 1.6, .seed = 1, .tint = .{ 150, 140, 130 } },
    .{ .position = pointVec(-2.6, 0, -0.6), .scale = 1.0, .seed = 7, .tint = .{ 130, 120, 112 } },
    .{ .position = pointVec(2.4, 0, 0.5), .scale = 1.2, .seed = 13, .tint = .{ 165, 150, 135 } },
    .{ .position = pointVec(-1.4, 0, 2.2), .scale = 0.8, .seed = 21, .tint = .{ 120, 128, 120 } },
    .{ .position = pointVec(1.8, 0, 2.6), .scale = 0.7, .seed = 34, .tint = .{ 158, 142, 120 } },
    .{ .position = pointVec(-3.0, 0, 1.8), .scale = 0.6, .seed = 42, .tint = .{ 140, 132, 128 } },
    .{ .position = pointVec(0.3, 0, -2.4), .scale = 0.9, .seed = 55, .tint = .{ 148, 138, 118 } },
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var rocks: [rock_count]z.Model = undefined;
    var i: usize = 0;
    while (i < rock_count) : (i += 1) {
        // radius 1 mesh (scaled at draw time), subdivision 4 for decent detail
        const mesh: z.types.Mesh = try z.genMeshRock(gpa, 1.0, 4, placements[i].seed);
        rocks[i] = try z.loadModelFromMesh(f.gl, gpa, mesh);
    }
    s.* = .{
        .rocks = rocks,
        .cam = .{ .target = pointVec(0, 0.2, 0), .distance = 11.0, .pitch = 0.4, .yaw = 0.6 },
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    var i: usize = 0;
    while (i < rock_count) : (i += 1) {
        z.unloadModel(gpa, s.rocks[i]);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const cam: Camera3D = s.cam.update(f, false, .{ .fovy_deg = 45 });
    z.clearViewport(f, .{ .r = 18, .g = 18, .b = 20, .a = 255 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    var i: usize = 0;
    while (i < rock_count) : (i += 1) {
        const p: RockPlacement = placements[i];
        z.drawModel(f.gl, s.rocks[i], p.position, p.scale, .{
            .r = p.tint[0],
            .g = p.tint[1],
            .b = p.tint[2],
            .a = 255,
        });
    }
    z.endMode3D(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - procedural rocks",
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
