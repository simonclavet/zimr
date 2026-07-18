// examples/rt_shader/rt_shader.zig
//
// A GPU ray tracer: the rt_fs fragment shader path-traces a sphere scene,
// rendered as a fullscreen pass. Same shaderMain that (later) drives the CPU
// side of a side-by-side. Accumulates over frames while the camera is still
// (a frame_seed varies the sampling), so the image refines from noisy to clean.
//
// Build:      zig build wgpu-rt-shader
// Standalone: zig build wgpu-rt-shader-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Camera3D = zm.Camera3D;
const RayCamera = zm.RayCamera;
const Vec = zm.Vec;
const float = zm.float;
const vec = zm.vec;
const vec4 = zm.vec4;

const shader_io = @import("rt_fs_io.zig");
const trivial_vs_io = @import("trivial_vs_io.zig");

const fs_wgsl = @embedFile("rt_fs.wgsl");
const trivial_vs_wgsl = @embedFile("trivial_vs.wgsl");

const width: u32 = 800;
const height: u32 = 450;

const State = struct {
    gpu_shader: z.shader.LoadedShader(shader_io),
    frame: u32,
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.gpu_shader.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const gpu_shader: z.shader.LoadedShader(shader_io) = try z.shader.loadShaderVF(trivial_vs_io, shader_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = trivial_vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .label = "rt_gpu",
    });
    s.* = .{ .gpu_shader = gpu_shader, .frame = 0 };
}

/// Build the scene UBO: camera basis (looking at the spheres) + the sphere
/// array. Identical to the data the CPU side would push.
fn buildUbo(frame: u32) shader_io.Ubo {
    const w_f: f32 = float(width);
    const h_f: f32 = float(height);

    // The ONE camera API: a Camera3D + .rayBasis (frag_tex_coord-correct).
    const cam3d: Camera3D = .{
        .position = vec(0, 0.6, 2.2),
        .target = vec(0, 0.3, -1.0),
        .fovy_deg = 45.0,
    };
    const cam: RayCamera = cam3d.rayBasis(w_f, h_f);

    var ubo: shader_io.Ubo = .{
        .cam_origin = cam.origin,
        .px00 = cam.px00,
        .pdu = cam.pdu,
        .pdv = cam.pdv,
        .resolution = .{ w_f, h_f },
        .frame_seed = float(frame),
        .sphere_count = 6,
        .sphere_geom = undefined,
        .sphere_albedo = undefined,
        .sphere_extra = undefined,
    };

    // Scene (RTIOW-ish): ground + glass + lambertian + metal + two small.
    // geom = (cx,cy,cz,radius); albedo = (r,g,b,material); extra = (param,..).
    const geom = [shader_io.max_spheres]Vec{
        vec4(0, -100.5, -1, 100), // ground
        vec4(-0.9, 0.0, -1.0, 0.5), // glass
        vec4(0.0, 0.0, -1.0, 0.5), // teal lambertian
        vec4(0.9, 0.0, -1.0, 0.5), // gold metal
        vec4(-0.25, -0.32, -0.55, 0.18), // chrome mirror
        vec4(0.35, -0.38, -0.5, 0.12), // small pink
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
    };
    const albedo = [shader_io.max_spheres]Vec{
        vec4(0.5, 0.55, 0.5, 0),
        vec4(1, 1, 1, 2),
        vec4(0.2, 0.55, 0.6, 0),
        vec4(0.8, 0.6, 0.2, 1),
        vec4(0.8, 0.8, 0.85, 1),
        vec4(0.85, 0.4, 0.45, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
    };
    const extra = [shader_io.max_spheres]Vec{
        vec4(0, 0, 0, 0),
        vec4(1.5, 0, 0, 0), // glass IOR
        vec4(0, 0, 0, 0),
        vec4(0.18, 0, 0, 0), // gold fuzz
        vec4(0.0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
    };
    ubo.sphere_geom = geom;
    ubo.sphere_albedo = albedo;
    ubo.sphere_extra = extra;
    return ubo;
}

fn update(f: *z.Frame, s: *State) void {
    s.frame +%= 1;
    const ubo: shader_io.Ubo = buildUbo(s.frame);

    s.gpu_shader.pushUbo(f.gpu.queue, ubo);
    z.bindFullscreenShader(f.gl, shader_io, &s.gpu_shader);
    z.drawFullscreenTriangle(f.gl);
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - GPU ray tracer (fragment shader)",
            .width = width,
            .height = height,
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
