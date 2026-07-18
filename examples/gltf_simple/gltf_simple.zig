// examples/gltf_simple/gltf_simple.zig
//
// The wgpu port of the GL `gltf_simple`: parse an embedded binary glTF cube
// (a freshly-generated 24-vert CCW cube_glb.zig) with the reusable `z.pbr3d` renderer and
// draw it lit + auto-rotating. The cube glb carries POSITION + indices only
// (no normals/UVs/material), so this exercises loadGltf's flat-normal synthesis
// + the default material — a good minimal check of the glTF→GPU path.
//
// Build:      zig build wgpu-gltf-simple
// Standalone: zig build wgpu-gltf-simple-standalone
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Mat = zm.Mat;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationX = zm.rotationX;
const rotationY = zm.rotationY;
const vec = zm.vec;

const cube_data = @import("cube_glb.zig");
const pbr_vs_wgsl = @embedFile("pbr_vs.wgsl");
const pbr_fs_wgsl = @embedFile("pbr_fs.wgsl");

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
        .vs_wgsl = pbr_vs_wgsl,
        .fs_wgsl = pbr_fs_wgsl,
        .cull_mode = .none, // let depth sort the solid cube (avoids winding/front-face mismatch)
    });
    const model: z.pbr3d.Model = try renderer.loadGltf(&cube_data.CUBE_GLB);
    s.* = .{ .renderer = renderer, .model = model };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();

    // Tumble on two axes so the flat-shaded faces catch the light differently.
    const model_m: Mat = mulMat(rotationY(t * 0.6), rotationX(t * 0.25));
    const view: Mat = lookAtRh(vec(0, 0, 5), vec(0, 0, 0), vec(0, 1, 0));
    const proj: Mat = perspectiveFovRh(0.9, aspect, 0.1, 100.0);

    s.renderer.beginFrame(f.gpu, .{
        .camera = .{ .view = view, .proj = proj, .eye = .{ 0, 0, 5 } },
        .light = .{ .dir = .{ -0.4, -0.6, -0.7 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.25, 0.27, 0.32 } },
        .clear = .{ .r = 0.03, .g = 0.04, .b = 0.06, .a = 1.0 },
    });
    s.renderer.draw(s.model, model_m);
    s.renderer.endFrame();
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{
            .title = "zimr - WebGPU - glTF simple",
            .width = 800,
            .height = 600,
            // The pbr3d pipeline is depth-tested; the pass's depth attachment
            // comes from the GpuFrame, which only allocates it when the window
            // opts in here. Must match the renderer's depth_format below.
            .depth_format = .depth24_plus,
        },
    }, State, initState, update);
}
