// examples/obj_simple/obj_simple.zig
//
// Loads a Wavefront OBJ model through the new `codecs.obj` path and draws it
// lit + auto-rotating, exactly like `gltf_simple` does for glTF. The
// embedded cube uses QUAD faces with `v/vt/vn` corners, so one small file
// exercises the whole loader: polygon triangulation (quads -> tris), tex-coord
// indices, explicit per-face normals, and the de-index/dedup that turns OBJ's
// separate v/vt/vn streams into a single GPU vertex + u16 index buffer.
//
// Build:      zig build wgpu-obj-simple
// Standalone: zig build wgpu-obj-simple-standalone

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

const pbr_vs_wgsl = @embedFile("pbr_vs.wgsl");
const pbr_fs_wgsl = @embedFile("pbr_fs.wgsl");

// A unit cube, written by hand. Quad faces (4 corners each) prove the fan
// triangulation; `v/vt/vn` corners prove tex-coord + normal index parsing.
const cube_obj =
    \\# unit cube
    \\v -1 -1 -1
    \\v  1 -1 -1
    \\v  1  1 -1
    \\v -1  1 -1
    \\v -1 -1  1
    \\v  1 -1  1
    \\v  1  1  1
    \\v -1  1  1
    \\vt 0 0
    \\vt 1 0
    \\vt 1 1
    \\vt 0 1
    \\vn  0  0 -1
    \\vn  0  0  1
    \\vn -1  0  0
    \\vn  1  0  0
    \\vn  0 -1  0
    \\vn  0  1  0
    \\f 1/1/1 2/2/1 3/3/1 4/4/1
    \\f 5/1/2 8/2/2 7/3/2 6/4/2
    \\f 1/1/3 4/2/3 8/3/3 5/4/3
    \\f 2/1/4 6/2/4 7/3/4 3/4/4
    \\f 1/1/5 5/2/5 6/3/5 2/4/5
    \\f 4/1/6 3/2/6 7/3/6 8/4/6
;

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
        .cull_mode = .none, // depth-sort the solid cube; winding-agnostic
    });
    const model: z.pbr3d.Model = try renderer.loadObj(cube_obj);
    s.* = .{ .renderer = renderer, .model = model };
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const aspect: f32 = f.window.aspect();

    const model_m: Mat = mulMat(rotationY(t * 0.6), rotationX(t * 0.25));
    const view: Mat = lookAtRh(vec(0, 0, 5), vec(0, 0, 0), vec(0, 1, 0));
    const proj: Mat = perspectiveFovRh(0.9, aspect, 0.1, 100.0);

    s.renderer.beginFrame(f.gpu, .{
        .camera = .{ .view = view, .proj = proj, .eye = .{ 0, 0, 5 } },
        .light = .{ .dir = .{ -0.4, -0.6, -0.7 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.25, 0.27, 0.32 } },
        .clear = .{ .r = 0.04, .g = 0.05, .b = 0.07, .a = 1.0 },
    });
    s.renderer.draw(s.model, model_m);
    s.renderer.endFrame();
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{
            .title = "zimr - WebGPU - OBJ simple",
            .width = 800,
            .height = 600,
            // pbr3d is depth-tested; the pass's depth attachment is only
            // allocated when the window opts in, and must match depth_format
            // passed to Renderer.init above.
            .depth_format = .depth24_plus,
        },
    }, State, initState, update);
}
