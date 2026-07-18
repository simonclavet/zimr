// examples/mandel_julia/mandel_julia.zig
//
// Mandelbrot↔Julia morph on WebGPU. The fragment shader interpolates between
// the mandelbrot iteration (z=pixel, c=pixel; param t=0) and the Julia
// iteration (z=pixel, c=julia_const; t=1) by a single uniform `t`. Animating t
// 0→1→0 sweeps continuously through every intermediate fractal — a striking
// visual that's also a good stress of the escape-loop shader on the pure-Zig
// SPIR-V→WGSL pipeline.
//
// WebGPU port of examples/mandel_julia.zig. Uses loadShaderVF (the comptime
// VS↔FS varying check) with the trivial fullscreen VS.
//
// Build:      zig build wgpu-mandel-julia
// Standalone: zig build wgpu-mandel-julia-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const float = zm.float;

const shader_io = @import("mandel_julia_fs_io.zig");
const trivial_vs_io = @import("trivial_vs_io.zig");

const fs_wgsl = @embedFile("mandel_julia_fs.wgsl");
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
    const gpu_shader: z.shader.LoadedShader(shader_io) = try z.shader.loadShaderVF(trivial_vs_io, shader_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = trivial_vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .label = "mandel_julia_gpu",
    });
    s.* = .{ .gpu_shader = gpu_shader };
}

fn update(f: *z.Frame, s: *State) void {
    // Morph param t oscillates 0↔1 (smooth ease via cosine): 0 = mandelbrot,
    // 1 = Julia, everything between is a continuous blend.
    const t: f32 = 0.5 - 0.5 * @cos(f.time.time * 0.4);

    // A julia_c on the boundary that gives an interesting Julia endpoint.
    const julia_c: Vec2 = .{ -0.7269, 0.1889 };

    z.clearViewport(f, .{ .r = 8, .g = 8, .b = 14, .a = 255 });

    s.gpu_shader.pushUbo(f.gpu.queue, .{
        .center = .{ -0.4, 0.0 },
        .zoom = 1.1,
        .resolution = .{ float(screen_w), float(screen_h) },
        .max_iter = 256,
        .t = t,
        .julia_c = julia_c,
    });
    z.bindFullscreenShader(f.gl, shader_io, &s.gpu_shader);
    z.drawFullscreenTriangle(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - Mandelbrot↔Julia morph",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
