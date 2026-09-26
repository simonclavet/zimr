// examples/obj_bunny/obj_bunny.zig
//
// Loads the Stanford bunny (`bun_zipper`) through `codecs.obj` and draws it lit
// + slowly turning. The bunny is the real stress test for the loader: 35,947
// positions, 69,451 triangles, and - like most scan-derived OBJs - NO normals
// and NO tex-coords. So this whole frame leans on the loader's smooth-normal
// synthesis (per-vertex accumulation of face normals) and on de-indexing
// dropping the bunny's ~1,100 unreferenced "hole" vertices. ~34,834 vertices /
// 208,353 indices reach the GPU through the standard u16 PBR path.
//
// Build:      zig build wgpu-obj-bunny
// Standalone: zig build wgpu-obj-bunny-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Mat = zm.Mat;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationY = zm.rotationY;
const scaling = zm.scaling;
const translation = zm.translation;
const vec = zm.vec;

const bunny_obj = @embedFile("bunny.obj");

// Model AABB center + a scale that lifts the ~0.15-unit-tall bunny to a few
// units so it fills the view. Measured from the file.
const center_x: f32 = -0.0168;
const center_y: f32 = 0.1102;
const center_z: f32 = -0.0015;
const fit_scale: f32 = 16.0;

pub var zimr_app: z.App = .{};

const State = struct {
    renderer: z.pbr3d.Renderer,
    model: z.pbr3d.Model,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const gf: *z.GpuFrame = f.gpu;
    var renderer: z.pbr3d.Renderer = try z.pbr3d.Renderer.init(.{
        .device = gf.device,
        .queue = gf.queue,
        .gpa = gpa,
        .surface_format = gf.backbuffer_format,
        .depth_format = .depth24_plus,
        .vs_wgsl = @embedFile("pbr_vs.wgsl"),
        .fs_wgsl = @embedFile("pbr_fs.wgsl"),
        .cull_mode = .none,
    });
    const model: z.pbr3d.Model = try renderer.loadObj(bunny_obj);
    s.* = .{ .renderer = renderer, .model = model };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();

    // recenter to the origin, scale up, then spin about Y.
    const recenter: Mat = translation(-center_x, -center_y, -center_z);
    const scale_m: Mat = scaling(fit_scale, fit_scale, fit_scale);
    const spin: Mat = rotationY(t * 0.5);
    const model_m: Mat = mulMat(spin, mulMat(scale_m, recenter));

    const view: Mat = lookAtRh(vec(0, 0.2, 5), vec(0, 0, 0), vec(0, 1, 0));
    const proj: Mat = perspectiveFovRh(0.8, aspect, 0.1, 100.0);

    s.renderer.beginFrame(f.gpu, .{
        .camera = .{ .view = view, .proj = proj, .eye = .{ 0, 0.2, 5 } },
        .light = .{ .dir = .{ -0.5, -0.5, -0.7 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.22, 0.24, 0.30 } },
        .clear = .{ .r = 0.05, .g = 0.06, .b = 0.08, .a = 1.0 },
    });
    s.renderer.draw(s.model, model_m);
    s.renderer.endFrame();
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{
            .title = "zimr - WebGPU - OBJ bunny",
            .width = 800,
            .height = 600,
            .depth_format = .depth24_plus,
        },
    }, State, initState, update);
}
