//! skybox — a gradient skybox via the new `drawSkybox`, with a few solid 3D
//! objects in front. The skybox is a fullscreen far-plane pass: it unprojects
//! each pixel to a world ray and lerps a vertical gradient (warm horizon → deep
//! blue zenith), parked just inside the far plane so the 3D objects + grid draw
//! over it. The camera orbits, so the gradient stays anchored to the world (you
//! see the horizon line stay level as you turn). (The GL `skybox` used a
//! procedural CUBEMAP; the wgpu skybox shaders are the gradient variant —
//! cubemap support is future work.)
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
    font: z.Font,
    angle: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    s.angle += f.time.delta_time * 12.0;

    z.clearViewport(f, .{ .r = 10, .g = 12, .b = 18, .a = 255 });

    const rad: f32 = s.angle * pi / 180.0;
    const cam: Camera3D = .{
        .position = pointVec(@cos(rad) * 7.0, 2.5, @sin(rad) * 7.0),
        .target = pointVec(0, 1, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 55,
        .projection = 0,
    };

    z.beginMode3D(f.gl, cam);
    // Background first (parks at the far plane; everything else draws over it).
    z.drawSkybox(f.gl, cam, .{ 0.85, 0.52, 0.32 }, .{ 0.12, 0.20, 0.48 });
    z.drawGrid(f.gl, 20, 1.0);
    z.drawCube(f.gl, pointVec(-2.2, 1, 0), .{ .size = vec(1.4, 1.4, 1.4), .color = c.amber_400 });
    z.drawSphere(f.gl, pointVec(2.2, 1, 0), .{ .radius = 0.9, .rings = 16, .slices = 16, .color = c.sky_400 });
    z.drawCylinderBetween(f.gl, pointVec(0, 0.2, -2.2), pointVec(0, 2, -2.2), 0.5, 0.5, 16, c.emerald_400);
    z.endMode3D(f.gl);

    common.caption(
        f.gl,
        s.font,
        "drawSkybox - per-pixel gradient sky (warm horizon -> blue zenith) behind the 3D scene",
    );
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - skybox",
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
