//! models_geometric_shapes — raylib's [models] geometric-shapes sample, as a 3D
//! gallery you spin with your finger.
//!
//! raylib lines up cube / sphere / cylinder / cone / torus / knot / plane, each
//! built by a `GenMeshX` procedural generator, and draws them with a fixed
//! camera.  zimr already ships every one of those generators, so the port is
//! really about SHOWING them off: a 2x4 grid of primitives on a grid floor, the
//! shared `OrbitCamera` for orbit / pan / pinch-zoom (works with one finger on a
//! phone), and a solid / wireframe / both toggle so you can see the actual
//! triangles each generator emits — the whole point of a mesh-generator demo.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Camera3D = zm.Camera3D;
const Color = zm.Color;
const Vec = zm.Vec;
const pointVec = zm.pointVec;
const float = zm.float;
const co = @import("example_common");

const roboto = @embedFile("roboto_mono_ttf");

/// Each primitive: a label for the HUD and a hue so it stays visually distinct.
const Shape = struct { name: []const u8, hue: f32 };
const shapes = [_]Shape{
    .{ .name = "cube", .hue = 12 },
    .{ .name = "sphere", .hue = 205 },
    .{ .name = "cylinder", .hue = 150 },
    .{ .name = "cone", .hue = 45 },
    .{ .name = "torus", .hue = 325 },
    .{ .name = "knot", .hue = 265 },
    .{ .name = "plane", .hue = 95 },
    .{ .name = "hemisphere", .hue = 185 },
};
const n_shapes: usize = shapes.len;
const cols: usize = 4;
const spacing: f32 = 3.2;

const Mode = enum(u8) { solid, wireframe, both };

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    models: [n_shapes]z.Model = undefined,
    mode: Mode = .both,
};

/// Build the mesh for shape `i`. These are exactly raylib's GenMeshX generators;
/// the numbers are just sizes / segment counts tuned to sit nicely in the grid.
fn genShape(gpa: Allocator, i: usize) !z.Mesh {
    return switch (i) {
        0 => z.genMeshCube(gpa, 1.4, 1.4, 1.4),
        1 => z.genMeshSphere(gpa, 0.85, 16, 24),
        2 => z.genMeshCylinder(gpa, 0.72, 1.5, 24),
        3 => z.genMeshCone(gpa, 0.85, 1.5, 24),
        4 => z.genMeshTorus(gpa, 0.3, 0.9, 24, 16),
        5 => z.genMeshKnot(gpa, 0.35, 0.8, 128, 12),
        6 => z.genMeshPlane(gpa, 1.6, 1.6, 2, 2),
        else => z.genMeshHemiSphere(gpa, 0.9, 16, 24),
    };
}

/// Grid slot for shape `i`, floating just above the floor so nothing z-fights.
fn shapePos(i: usize) Vec {
    const col: f32 = float(@as(i32, @intCast(i % cols)));
    const row: f32 = float(@as(i32, @intCast(i / cols)));
    return pointVec((col - 1.5) * spacing, 1.1, (row - 0.5) * spacing);
}

fn deinit(gpa: Allocator, s: *State) void {
    for (&s.models) |*m| {
        z.unloadModel(gpa, m.*);
    }
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto, 22);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        // Look down at the grid from a comfortable three-quarter angle.
        .cam = z.OrbitCamera.init(pointVec(0, 0.5, 0), 16.0),
    };
    // uploadMesh hands the CPU mesh to the GPU; loadModelFromMesh wraps it in a
    // Model the retained-draw path can render (and unloadModel later frees).
    for (0..n_shapes) |i| {
        var mesh: z.Mesh = try genShape(gpa, i);
        try z.uploadMesh(gpa, &mesh, false);
        s.models[i] = try z.loadModelFromMesh(f.gl, gpa, mesh);
    }
}

fn modeLabel(mode: Mode) []const u8 {
    return switch (mode) {
        .solid => "view: solid",
        .wireframe => "view: wireframe",
        .both => "view: both",
    };
}

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    z.clearViewport(f, co.palette.bg);

    // UI first so wantCaptureMouse reflects this frame before the camera reads it.
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    u.setNextWindowPos(.{ 8, vh - 62 }, .{});
    u.setNextWindowSize(.{ @min(320, vw - 16), 54 }, .{});
    if (u.window("controls", .{})) |w| {
        defer w.close();
        if (u.button(modeLabel(s.mode), .{})) {
            s.mode = switch (s.mode) {
                .solid => .wireframe,
                .wireframe => .both,
                .both => .solid,
            };
        }
        u.sameLine(.{});
        if (u.button("reset view", .{})) {
            s.cam = z.OrbitCamera.init(pointVec(0, 0.5, 0), 16.0);
        }
    }

    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 6.0,
        .max_distance = 40.0,
    });

    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 20, 1.0);
    for (0..n_shapes) |i| {
        const pos: Vec = shapePos(i);
        const hue: f32 = shapes[i].hue;
        if (s.mode != .wireframe) {
            const fill: Color = if (s.mode == .both)
                z.colorFromHSV(hue, 0.45, 0.5)
            else
                z.colorFromHSV(hue, 0.55, 0.88);
            z.drawModel(f.gl, s.models[i], pos, 1.0, fill);
        }
        if (s.mode != .solid) {
            z.drawModelWires(f.gl, s.models[i], pos, 1.0, z.colorFromHSV(hue, 0.8, 1.0));
        }
    }
    z.endMode3D(f.gl);

    // HUD: title, the recognisable primitive names, and the gesture hint.
    const ink_dim = co.palette.ink_dim;
    f.gl.text(.{ 16, 16 }, "Mesh Gallery", .{ .size = 24, .color = co.palette.ink, .font = &s.font });
    f.gl.text(
        .{ 16, 46 },
        "cube . sphere . cylinder . cone . torus . knot . plane . hemisphere",
        .{ .size = 14, .color = ink_dim, .font = &s.font },
    );
    co.caption(f.gl, s.font, "GenMesh* primitives - drag to orbit, pinch to zoom, toggle wireframe for the triangles");
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - models - geometric shapes (mesh gallery)",
            .width = 960,
            .height = 600,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
