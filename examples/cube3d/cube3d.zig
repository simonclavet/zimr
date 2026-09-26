//! cube3d - port of the GL `cube3d`: a fixed-camera 3D scene with a
//! spinning green cube (solid + wireframe) above a ground grid, plus a static
//! reference sphere. The GL version spun the cube through the rlgl matrix stack
//! (rlPushMatrix / rlRotatef); the wgpu immediate API expresses the same thing
//! as a `.rotation` matrix on the cube descriptor - no matrix stack. The HUD is
//! drawn in 2D after endMode3D so it stays screen-anchored (single shared pass).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const matFromAxisAngle = zm.matFromAxisAngle;
const pointVec = zm.pointVec;
const vec = zm.vec;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const Color = zm.Color;

const State = struct {
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const angle: f32 = t * 0.8; // ~45 deg/sec about Y

    z.clearViewport(f, common.palette.bg);

    const cam: Camera3D = .{
        .position = pointVec(4, 4, 4),
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 60,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 20, 1.0);

    const green: Color = .{ .r = 74, .g = 222, .b = 128, .a = 255 };
    const wire: Color = .{ .r = 220, .g = 252, .b = 231, .a = 255 };
    const spin: Mat = matFromAxisAngle(vec(0, 1, 0), angle);
    z.drawCube(f.gl, pointVec(0, 1, 0), .{ .size = vec(1.5, 1.5, 1.5), .rotation = spin, .color = green });
    z.drawCubeWires(f.gl, pointVec(0, 1, 0), .{ .size = vec(1.52, 1.52, 1.52), .rotation = spin, .color = wire });
    z.drawSphere(f.gl, pointVec(-2, 0.5, 0), .{ .radius = 0.5, .color = green });

    z.endMode3D(f.gl);

    common.caption(f.gl, s.font, "WebGPU 3D cube - spinning solid + wires, grid, sphere");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - 3D cube",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
