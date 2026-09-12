//! 3d_probe — the immediate-mode 3D pipeline, end to end. A drag-orbit
//! camera (z.updateCamera, .orbital) around a lit scene: a ground plane + grid,
//! two cubes tumbling via drawCubeEx / drawCubeWiresEx, a smooth sphere, and a
//! capped cylinder — all depth-tested in the dedicated 3D pass, batched into one
//! draw per topology. The caption is drawn in 2D before entering 3D so it stays
//! screen-anchored. Drag to orbit; wheel to zoom.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Vec = zm.Vec;
const matFromAxisAngle = zm.matFromAxisAngle;
const pointVec = zm.pointVec;
const vec = zm.vec;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const Color = zm.Color;

const State = struct {
    font: z.Font,
    cam: Camera3D,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .cam = .{
            .position = .{ 7.0, 5.5, 7.0, 0 },
            .target = .{ 0, 0.7, 0, 0 },
            .up = .{ 0, 1, 0, 0 },
            .fovy_deg = 50,
            .projection = 0,
        },
    };
}

fn update(f: *z.Frame, s: *State) void {
    z.updateCamera(f.gl, &s.cam, .orbital);
    const t: f32 = f.time.time;

    z.clearViewport(f, common.palette.bg);

    z.beginMode3D(f.gl, s.cam);
    const floor_color: Color = .{ .r = 30, .g = 32, .b = 42, .a = 255 };
    z.drawPlane(f.gl, pointVec(0, 0, 0), .{ .size = .{ 18, 18 }, .color = floor_color });
    z.drawGrid(f.gl, 18, 1.0);

    const teal: Color = .{ .r = 90, .g = 200, .b = 190, .a = 255 };
    const blue: Color = .{ .r = 110, .g = 150, .b = 230, .a = 255 };
    const mag: Color = .{ .r = 210, .g = 110, .b = 200, .a = 255 };
    const accent: Color = .{ .r = 224, .g = 122, .b = 95, .a = 255 };
    const wire: Color = .{ .r = 250, .g = 245, .b = 240, .a = 255 };
    const axis: Vec = .{ 0.408, 0.816, 0.408, 0 }; // unit, tilted
    const spin: Mat = matFromAxisAngle(axis, t);

    z.drawCube(f.gl, pointVec(-3.0, 0.9, 0), .{ .size = vec(1.3, 1.3, 1.3), .rotation = spin, .color = teal });
    z.drawSphere(f.gl, pointVec(-0.6, 0.9, 0), .{ .radius = 0.8, .color = blue });
    z.drawCylinder(f.gl, pointVec(1.8, 0.9, 0), .{ .radius = 0.7, .height = 1.7, .color = mag });
    z.drawCube(f.gl, pointVec(3.8, 0.75, 0), .{ .size = vec(1.3, 1.3, 1.3), .rotation = spin, .color = accent });
    z.drawCubeWires(f.gl, pointVec(3.8, 0.75, 0), .{
        .size = vec(1.32, 1.32, 1.32),
        .rotation = spin,
        .color = wire,
    });

    z.endMode3D(f.gl);

    // 2D HUD on top, AFTER the 3D flush. Single shared pass: the 2D pipeline is
    // depth compare=always, so it composites over the depth-tested 3D.
    common.caption(f.gl, s.font, "3D probe: drag to orbit - plane, spinning cubes, sphere, cylinder");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - 3D probe",
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
