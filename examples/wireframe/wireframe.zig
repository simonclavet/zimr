//! wireframe — port of the GL `wireframe`: a generated sphere + two cubes,
//! drawn solid or as wireframe (TAB toggles), proving the retained Mesh/Model
//! tier — `genMeshSphere`/`genMeshCube` → `loadModelFromMesh` → `drawModel` /
//! `drawModelWires`. The wgpu retained path CPU-transforms each mesh into the
//! immediate 3D batch (Step 3a); true GPU instancing lands in Step 4. The
//! camera auto-orbits; the caption is 2D, drawn after endMode3D.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const pi = zm.pi;
const pointVec = zm.pointVec;
const vec = zm.vec;
const co = @import("example_common");
const c = z.colors;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const State = struct {
    font: z.Font,
    sphere_model: z.Model,
    cube_model: z.Model,
    angle: f32 = 0, // camera orbit angle (degrees)
    show_wires: bool = true,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadModel(gpa, s.sphere_model);
    z.unloadModel(gpa, s.cube_model);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Sphere: 16 rings × 24 slices = 768 triangles, indexed.
    var sphere_mesh: z.Mesh = try z.genMeshSphere(gpa, 1.2, 16, 24);
    try z.uploadMesh(gpa, &sphere_mesh, false);
    const sphere_model: z.Model = try z.loadModelFromMesh(f.gl, gpa, sphere_mesh);

    // Cube: 12 triangles.
    var cube_mesh: z.Mesh = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    try z.uploadMesh(gpa, &cube_mesh, false);
    const cube_model: z.Model = try z.loadModelFromMesh(f.gl, gpa, cube_mesh);

    s.* = .{
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24),
        .sphere_model = sphere_model,
        .cube_model = cube_model,
    };
}

fn update(f: *z.Frame, s: *State) void {
    s.angle += f.time.delta_time * 20.0; // 20°/sec orbit
    if (z.isKeyPressed(f.input, .tab)) {
        s.show_wires = !s.show_wires;
    }

    z.clearViewport(f, co.palette.bg);

    const rad: f32 = s.angle * pi / 180.0;
    const cam: Camera3D = .{
        .position = pointVec(@cos(rad) * 8, 4, @sin(rad) * 8),
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 50,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 20, 1.0);

    if (s.show_wires) {
        z.drawModelWires(f.gl, s.sphere_model, pointVec(0, 1.5, 0), 1.0, c.sky_300);
        z.drawModelWires(f.gl, s.cube_model, pointVec(-3, 0.5, 0), 1.0, c.amber_300);
        z.drawModelWires(f.gl, s.cube_model, pointVec(3, 0.5, 0), 1.0, c.emerald_400);
    } else {
        z.drawModel(f.gl, s.sphere_model, pointVec(0, 1.5, 0), 1.0, c.sky_500);
        z.drawModel(f.gl, s.cube_model, pointVec(-3, 0.5, 0), 1.0, c.amber_500);
        z.drawModel(f.gl, s.cube_model, pointVec(3, 0.5, 0), 1.0, c.emerald_500);
    }

    z.endMode3D(f.gl);

    const cap: []const u8 = if (s.show_wires)
        "WebGPU wireframe - TAB toggles - MODE: wires (sphere + 2 cubes)"
    else
        "WebGPU wireframe - TAB toggles - MODE: solid (sphere + 2 cubes)";
    co.caption(f.gl, s.font, cap);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - wireframe",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
