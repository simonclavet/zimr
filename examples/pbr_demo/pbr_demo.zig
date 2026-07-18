// examples/pbr_demo/pbr_demo.zig
//
// The DamagedHelmet (full PBR) on the WebGPU backend, driven by the reusable
// `z.pbr3d` renderer (src/pbr3d.zig) and written in the standard zimr AppBridge
// form (z.App.run + initState + update) -- the same shape as every other demo.
// This is both the PBR/glTF showcase AND the regression test for pbr3d.zig: it
// must render the worn metal, scorch mark, gold visor, normal-mapped detail,
// and emissive.
//
// The renderer resolves the five PBR maps through the glTF *material* (not a
// hardcoded image order), so the same code loads other glbs.
//
// Build:    zig build wgpu-pbr-demo
// Standalone (single-file HTML): zig build wgpu-pbr-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Mat = zm.Mat;
const lookAtRh = zm.lookAtRh;
const mulMat = zm.mulMat;
const perspectiveFovRh = zm.perspectiveFovRh;
const pi = zm.pi;
const rotationX = zm.rotationX;
const rotationY = zm.rotationY;
const vec = zm.vec;

const helmet_glb = @embedFile("DamagedHelmet.glb");
const pbr_vs_wgsl = @embedFile("pbr_vs.wgsl");
const pbr_fs_wgsl = @embedFile("pbr_fs.wgsl");

pub var zimr_app: z.App = .{};

const State = struct {
    renderer: z.pbr3d.Renderer,
    model: z.pbr3d.Model,
};

fn initState(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
) !void {
    // The frame carries the live device/queue/surface/format via its GpuFrame;
    // the renderer owns the PBR pipeline, bind-group layouts, shared uniform
    // buffers, and neutral fallback textures. The depth target is the frame's.
    const gf: *z.GpuFrame = f.gpu;
    var renderer: z.pbr3d.Renderer = try z.pbr3d.Renderer.init(.{
        .device = gf.device,
        .queue = gf.queue,
        .gpa = gpa,
        .surface_format = gf.backbuffer_format,
        .depth_format = .depth24_plus,
        .vs_wgsl = pbr_vs_wgsl,
        .fs_wgsl = pbr_fs_wgsl,
    });
    // Parse + interleave + tangent-gen + decode the 5 embedded JPEG maps.
    const model: z.pbr3d.Model = try renderer.loadGltf(helmet_glb);
    s.* = .{ .renderer = renderer, .model = model };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();

    // Orient the helmet upright (the glb authors it Z-up; its node carries a
    // +90 deg rotation about X) and spin slowly about Y.
    const half_pi: f32 = pi * 0.5;
    const model_m: Mat = mulMat(rotationY(t * 0.5), rotationX(half_pi));
    const view: Mat = lookAtRh(vec(0, 0, 3.2), vec(0, 0, 0), vec(0, 1, 0));
    const proj: Mat = perspectiveFovRh(0.9, aspect, 0.1, 100.0);

    s.renderer.beginFrame(f.gpu, .{
        .camera = .{ .view = view, .proj = proj, .eye = .{ 0, 0, 3.2 } },
        .light = .{ .dir = .{ -0.4, -0.8, -0.5 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.12, 0.12, 0.14 } },
        .clear = .{ .r = 0.05, .g = 0.06, .b = 0.10, .a = 1.0 },
    });
    s.renderer.draw(s.model, model_m);
    s.renderer.endFrame();
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{ .title = "zimr - WebGPU - PBR (DamagedHelmet)", .width = 800, .height = 600 },
    }, State, initState, update);
}
