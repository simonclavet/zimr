// examples/julia/julia.zig
//
// The Julia set on WebGPU: a fullscreen fragment-shader demo, the sibling of
// mandel_sidebyside's GPU half. Same escape-iteration shader family
// (cmandelbrot_step), but z starts at the pixel coordinate and the constant is
// the animated `julia_c` - so the fractal morphs continuously as julia_c orbits
// a small circle.
//
// This is the WebGPU port of examples/julia.zig. It exercises:
//   - the pure-Zig SPIR-V->WGSL pipeline on a non-trivial escape loop, and
//   - loadShaderVF: the comptime VS<->FS varying check (the trivial fullscreen
//     VS outputs only frag_tex_coord; julia_fs_io.Inputs must match exactly).
//
// Build:      zig build wgpu-julia
// Standalone: zig build wgpu-julia-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const float = zm.float;

const shader_io = @import("julia_fs_io.zig");
const trivial_vs_io = @import("trivial_vs_io.zig");

const mandel_fs_wgsl = @embedFile("julia_fs.wgsl");
const trivial_vs_wgsl = @embedFile("trivial_vs.wgsl");

const screen_w: u32 = 800;
const screen_h: u32 = 600;

const State = struct {
    gpu_shader: z.shader.LoadedShader(shader_io),
};

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    s.gpu_shader.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // loadShaderVF comptime-asserts trivial_vs_io.Outputs == julia_fs_io.Inputs
    // (both just `frag_tex_coord`), so a mismatched varying is a build error.
    const gpu_shader: z.shader.LoadedShader(shader_io) = try z.shader.loadShaderVF(trivial_vs_io, shader_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = trivial_vs_wgsl,
        .fs_wgsl_source = mandel_fs_wgsl,
        .label = "julia_gpu",
    });
    s.* = .{ .gpu_shader = gpu_shader };
}

fn update(f: *z.Frame, s: *State) void {
    // Animate julia_c around a small circle near the boundary - the classic
    // morphing-Julia look. The pixel/view params stay fixed.
    const t: f32 = f.time.time;
    const julia_c: Vec2 = .{
        -0.8 + 0.12 * @cos(t * 0.4),
        0.156 + 0.12 * @sin(t * 0.4),
    };

    z.clearViewport(f, .{ .r = 8, .g = 8, .b = 14, .a = 255 });

    s.gpu_shader.pushUbo(f.gpu.queue, .{
        .center = .{ 0.0, 0.0 },
        .zoom = 1.0,
        .resolution = .{ float(screen_w), float(screen_h) },
        .max_iter = 256,
        .julia_c = julia_c,
    });
    z.bindFullscreenShader(f.gl, shader_io, &s.gpu_shader);
    z.drawFullscreenTriangle(f.gl);

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - Julia set",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
