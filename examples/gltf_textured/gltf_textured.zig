// examples/gltf_textured/gltf_textured.zig
//
// A textured glTF quad on WebGPU, written in the standard zimr AppBridge form
// (z.App.run + initState + update) -- the same shape as a GL example, but on
// the WebGPU backend. This is the N3 proof in wgpu_new_beginnings.md: the
// device/surface/cache boilerplate every hand-rolled wgpu demo repeated now
// lives in z.App.run, and the frame loop calls update(f, s) for us.
//
// The renderer (z.pbr3d) resolves the 5 PBR maps through the glTF material; the
// quad embeds a red/cyan checker PNG and has no normals, exercising the PNG +
// flat-normal-synthesis paths. In Chrome: a checker quad rotating in 3D.
//
// Build:      zig build wgpu-gltf-textured
// Standalone: zig build wgpu-gltf-textured-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Mat = zm.Mat;
const lookAtRh = zm.lookAtRh;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationY = zm.rotationY;
const vec = zm.vec;

const quad_data = @import("quad_glb_data.zig");
const pbr_vs_wgsl = @embedFile("pbr_vs.wgsl");
const pbr_fs_wgsl = @embedFile("pbr_fs.wgsl");

// The AppBridge instance. Default-initialized; z.App.run populates it and the
// library's `update` export drives the frame loop. (`pub` so it survives DCE.)
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
    // The frame already carries the live device/queue/surface/format via its
    // GpuFrame -- no device boilerplate here. Build the renderer from it.
    const gf: *z.GpuFrame = f.gpu;
    var renderer: z.pbr3d.Renderer = try z.pbr3d.Renderer.init(.{
        .device = gf.device,
        .queue = gf.queue,
        .gpa = gpa,
        .surface_format = gf.backbuffer_format,
        .depth_format = .depth24_plus,
        .vs_wgsl = pbr_vs_wgsl,
        .fs_wgsl = pbr_fs_wgsl,
        .cull_mode = .none, // the quad is a single-sided flat plane
    });
    const model: z.pbr3d.Model = try renderer.loadGltf(&quad_data.QUAD_GLB);
    s.* = .{ .renderer = renderer, .model = model };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();

    const model_m: Mat = rotationY(t * 0.6);
    const view: Mat = lookAtRh(vec(0, 0, 4), vec(0, 0, 0), vec(0, 1, 0));
    const proj: Mat = perspectiveFovRh(0.9, aspect, 0.1, 100.0);

    s.renderer.beginFrame(f.gpu, .{
        .camera = .{ .view = view, .proj = proj, .eye = .{ 0, 0, 4 } },
        .light = .{ .dir = .{ -0.3, -0.5, -0.8 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.3, 0.3, 0.3 } },
        .clear = .{ .r = 0.02, .g = 0.03, .b = 0.05, .a = 1.0 },
    });
    s.renderer.draw(s.model, model_m);
    s.renderer.endFrame();
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{
            .title = "zimr - WebGPU - textured glTF quad",
            .width = 800,
            .height = 600,
            .depth_format = .depth24_plus,
        },
    }, State, initState, update);
}
