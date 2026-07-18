//! orthographic_projection — raylib's `models_orthographic_projection`.
//!
//! One scene of solid + wireframe primitives, drawn twice ways: press
//! SPACE (or tap the toggle) to swap the camera between a normal
//! PERSPECTIVE projection and an ORTHOGRAPHIC one. Perspective makes
//! far things smaller (vanishing point); orthographic keeps every depth
//! the same size (parallel lines stay parallel) — the difference is
//! obvious the instant you flip it, which is the whole point of the
//! example.
//!
//! raylib expresses the ortho "zoom" by reusing the camera's `fovy`
//! field as a world-space WIDTH (10 units here). zimr's immediate 3D
//! batch always builds a perspective matrix internally, so this example
//! builds BOTH matrices itself (`perspectiveFovRh` / `orthographicRh`)
//! and feeds the chosen one to `beginMode3DMatrix`.
//!
//! Phone-first: the camera is fixed (like raylib), a big on-screen
//! button flips the projection, and the current mode is labelled.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Mat = zm.Mat;
const Vec = zm.Vec;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const orthographicRh = zm.orthographicRh;
const perspectiveFovRh = zm.perspectiveFovRh;
const pointVec = zm.pointVec;
const rad_per_deg = zm.rad_per_deg;
const vec = zm.vec;
const co = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub var zimr_app: z.App = .{};

const fovy_perspective: f32 = 45.0; // degrees
const width_orthographic: f32 = 10.0; // world units (raylib reuses fovy as width)

// raylib's exact palette for the scene.
const red: Color = .{ .r = 230, .g = 41, .b = 55, .a = 255 };
const gold: Color = .{ .r = 255, .g = 203, .b = 0, .a = 255 };
const maroon: Color = .{ .r = 190, .g = 33, .b = 55, .a = 255 };
const green: Color = .{ .r = 0, .g = 228, .b = 48, .a = 255 };
const lime: Color = .{ .r = 0, .g = 158, .b = 47, .a = 255 };
const sky_blue: Color = .{ .r = 102, .g = 191, .b = 255, .a = 255 };
const dark_blue: Color = .{ .r = 0, .g = 82, .b = 172, .a = 255 };
const brown: Color = .{ .r = 127, .g = 106, .b = 79, .a = 255 };
const pink: Color = .{ .r = 255, .g = 109, .b = 194, .a = 255 };

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    ortho: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
    };
}

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    z.clearViewport(f, co.palette.bg);

    // ---- toggle: SPACE or the on-screen button ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    u.setNextWindowPos(.{ 8, vh - 70 }, .{});
    u.setNextWindowSize(.{ @min(280, vw - 16), 62 }, .{});
    if (u.window("projection", .{})) |w| {
        defer w.close();
        if (u.button(if (s.ortho) "switch to PERSPECTIVE" else "switch to ORTHOGRAPHIC", .{})) {
            s.ortho = !s.ortho;
        }
    }
    if (z.isKeyPressed(f.input, .space)) {
        s.ortho = !s.ortho;
    }

    // ---- build the chosen projection (raylib's fixed camera) ----
    const eye: Vec = pointVec(0, 10, 10);
    const view: Mat = lookAtRh(eye, pointVec(0, 0, 0), vec(0, 1, 0));
    const aspect: f32 = vw / vh;
    const proj: Mat = if (s.ortho)
        orthographicRh(width_orthographic, width_orthographic / aspect, 0.01, 1000.0)
    else
        perspectiveFovRh(fovy_perspective * rad_per_deg, aspect, 0.01, 1000.0);
    const view_proj: Mat = mulMat(proj, view);

    // ---- the scene (raylib's exact primitives + positions) ----
    z.beginMode3DMatrix(f.gl, view_proj);

    z.drawCube(f.gl, pointVec(-4, 0, 2), .{ .size = vec(2, 5, 2), .color = red });
    z.drawCubeWires(f.gl, pointVec(-4, 0, 2), .{ .size = vec(2, 5, 2), .color = gold });
    z.drawCubeWires(f.gl, pointVec(-4, 0, -2), .{ .size = vec(3, 6, 2), .color = maroon });

    z.drawSphere(f.gl, pointVec(-1, 0, -2), .{ .radius = 1.0, .color = green });
    z.drawSphereWires(f.gl, pointVec(1, 0, 2), .{ .radius = 2.0, .color = lime });

    z.drawCylinder(f.gl, pointVec(4, 0, -2), .{ .radius = 1.5, .height = 3.0, .color = sky_blue });
    z.drawCylinderWires(f.gl, pointVec(4, 0, -2), .{ .radius = 1.5, .height = 3.0, .color = dark_blue });
    z.drawCylinderWires(f.gl, pointVec(4.5, -1, 2), .{ .radius = 1.0, .height = 2.0, .color = brown });

    // A cone (top radius 0) via the variable-radius cylinder, raylib's last two.
    z.drawCylinderBetween(f.gl, pointVec(1, -1.5, -4), pointVec(1, 1.5, -4), 0.0, 1.5, 8, gold);
    z.drawCylinderBetween(f.gl, pointVec(1, -1.5, -4), pointVec(1, 1.5, -4), 0.0, 1.55, 8, pink);

    z.drawGrid(f.gl, 10, 1.0);
    z.endMode3D(f.gl);

    // ---- HUD ----
    const label: []const u8 = if (s.ortho) "ORTHOGRAPHIC" else "PERSPECTIVE";
    f.gl.text(
        .{ 14, 44 },
        label,
        .{ .size = 22, .color = if (s.ortho) co.palette.accent else co.palette.accent2, .font = &s.font },
    );
    co.caption(f.gl, s.font, "WebGPU 3D - orthographic vs perspective (SPACE / tap to switch)");
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - orthographic projection",
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
