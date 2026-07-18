// examples/damaged_helmet/damaged_helmet.zig
//
// The wgpu port of the GL `damaged_helmet`: the canonical Khronos "Damaged
// Helmet" PBR glTF, rendered through `z.pbr3d` with its real materials — base
// color, metallic-roughness, normal, occlusion and emissive maps (JPEG, decoded
// by codecs.jpeg). It ships normals, so it skips the flat-normal synthesis. A
// directional key light + ambient; the helmet auto-rotates so you can see the
// whole surface. The GL version drove a catalog of toy shaders; here we use the
// PBR renderer directly for the full materially-correct look.
//
// Build:      zig build wgpu-damaged-helmet
// Standalone: zig build wgpu-damaged-helmet-standalone
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Mat = zm.Mat;
const Vec = zm.Vec;
const clamp = zm.clamp;
const lookAtRh = zm.lookAtRh;
const perspectiveFovRh = zm.perspectiveFovRh;
const rotationX = zm.rotationX;
const vec = zm.vec;

const helmet_glb = @embedFile("DamagedHelmet.glb");
const pbr_vs_wgsl = @embedFile("pbr_vs.wgsl");
const pbr_fs_wgsl = @embedFile("pbr_fs.wgsl");

pub var zimr_app: z.App = .{};

const State = struct {
    renderer: z.pbr3d.Renderer,
    model: z.pbr3d.Model,
    yaw: f32 = 0.6,
    pitch: f32 = 0.15,
    distance: f32 = 3.2,
    dragging: bool = false,
    prev_pinch: f32 = 0.0, // previous two-finger spacing; 0 = not pinching
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
        .cull_mode = .back, // closed mesh, correct winding + normals
    });
    const model: z.pbr3d.Model = try renderer.loadGltf(helmet_glb);
    s.* = .{ .renderer = renderer, .model = model };
}

fn update(f: *z.Frame, s: *State) void {
    const touches: i32 = z.getTouchPointCount(f.input);

    // ---- Pinch zoom (two fingers): compare finger spacing frame-over-frame.
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            // fingers spreading (dist grows) -> move closer (distance shrinks)
            s.distance = clamp(s.distance - (dist - s.prev_pinch) * 0.01, 1.4, 9.0);
        }
        s.prev_pinch = dist;
    } else {
        s.prev_pinch = 0;
    }

    // ---- Orbit: one-finger / mouse drag. The `dragging` latch skips the bogus
    // first-frame delta (the cursor "teleports" to the touch point on press).
    // Gated to a single touch so a two-finger pinch doesn't also spin it.
    if (touches < 2 and z.isMouseButtonDown(f.input, .left)) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.yaw -= d[0] * 0.008;
            s.pitch = clamp(s.pitch + d[1] * 0.008, -1.45, 1.45);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }

    // ---- Zoom: mouse wheel (desktop).
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.distance = clamp(s.distance - wheel * 0.3, 1.4, 9.0);
    }

    const aspect: f32 = f.window.aspect();
    const cp: f32 = @cos(s.pitch);
    const sp: f32 = @sin(s.pitch);
    const cy: f32 = @cos(s.yaw);
    const sy: f32 = @sin(s.yaw);
    const eye: Vec = vec(s.distance * cp * sy, s.distance * sp, s.distance * cp * cy);
    const view: Mat = lookAtRh(eye, vec(0, 0, 0), vec(0, 1, 0));
    const proj: Mat = perspectiveFovRh(0.8, aspect, 0.1, 100.0);

    // pbr3d.loadGltf ignores the glTF node transform; the helmet mesh is Z-up
    // with the visor toward +Y. +90° about X stands it upright, visor forward.
    const model_m: Mat = rotationX(1.5707963);

    s.renderer.beginFrame(f.gpu, .{
        .camera = .{ .view = view, .proj = proj, .eye = .{ eye[0], eye[1], eye[2] } },
        .light = .{ .dir = .{ -0.5, -0.6, -0.6 }, .color = .{ 1, 1, 1 }, .ambient = .{ 0.2, 0.22, 0.26 } },
        .clear = .{ .r = 0.02, .g = 0.025, .b = 0.04, .a = 1.0 },
    });
    s.renderer.draw(s.model, model_m);
    s.renderer.endFrame();
}

pub fn main() !void {
    try zimr_app.run(.{
        .window = .{
            .title = "zimr - WebGPU - damaged helmet",
            .width = 800,
            .height = 600,
            .depth_format = .depth24_plus, // pbr3d is depth-tested; the pass needs a depth target
        },
    }, State, initState, update);
}
