//! pipeline_constants — increment 5 of the custom-pipeline API
//! (`src/notes/webgpu_control.md`). Ported from raygpu's `pipeline_constants.cpp`:
//! WGSL pipeline-overridable constants (`override`). ONE shader source becomes
//! THREE specialised pipelines, each baked with different constant values at
//! creation — different tint, position and scale — with no separate shaders and
//! no per-draw uniforms.
//!
//! This increment added the plumbing the rest of the stack lacked: a `constants`
//! list on `gpu.RenderPipelineDescriptor` (encoded into the pipeline blob), the
//! bridge decoding it onto both stage descriptors' `constants` map, and a
//! `constants` field on `z.PipelineOptions` (each entry is a `z.material.Constant
//! = .{ .name, .value }`).
//!
//! Override constants are fixed at pipeline creation — so the three triangles
//! are static (an aspect-correct UBO would belong with per-frame data instead).
//!
//! Build:  zig build wgpu-pipeline-constants
//! Device: zig build wgpu-pipeline-constants-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// `override`s with defaults; each pipeline supplies its own values. `scl` and
/// `ox` move/size the shape; `tint_*` recolour it.
const tri_wgsl =
    \\override tint_r: f32 = 1.0;
    \\override tint_g: f32 = 1.0;
    \\override tint_b: f32 = 1.0;
    \\override ox: f32 = 0.0;
    \\override scl: f32 = 1.0;
    \\
    \\struct VsOut {
    \\    @builtin(position) pos: vec4f,
    \\    @location(0) color: vec3f,
    \\};
    \\
    \\@vertex
    \\fn vs_main(@location(0) p: vec2f, @location(1) c: vec3f) -> VsOut {
    \\    var out: VsOut;
    \\    out.pos = vec4f(p * scl + vec2f(ox, 0.0), 0.0, 1.0);
    \\    out.color = c * vec3f(tint_r, tint_g, tint_b);
    \\    return out;
    \\}
    \\
    \\@fragment
    \\fn fs_main(in: VsOut) -> @location(0) vec4f {
    \\    return vec4f(in.color, 1.0);
    \\}
;

const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// A white triangle — the tint comes entirely from each pipeline's constants.
const vertices = [_]Vertex{
    .{ .x = 0.0, .y = 0.9, .r = 1.0, .g = 1.0, .b = 1.0 },
    .{ .x = -0.9, .y = -0.8, .r = 1.0, .g = 1.0, .b = 1.0 },
    .{ .x = 0.9, .y = -0.8, .r = 1.0, .g = 1.0, .b = 1.0 },
};

const State = struct {
    font: z.Font,
    vbo: z.wgpu.BufferHandle,
    pipes: [3]z.Pipeline,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    for (s.pipes) |p| {
        z.wgpu.destroyRenderPipeline(p.handle);
        z.wgpu.destroyPipelineLayout(p.layout);
        z.wgpu.destroyShaderModule(p.module);
    }
    z.wgpu.destroyBuffer(s.vbo);
}

/// Build one pipeline from the shared WGSL, specialised by override constants.
fn makePipe(
    gpa: Allocator,
    f: *z.Frame,
    layout: z.VertexLayout,
    consts: []const z.material.Constant,
) !z.Pipeline {
    return z.Pipeline.init(gpa, f, .{
        .wgsl = tri_wgsl,
        .layouts = &.{layout},
        .constants = consts,
        .label = "pipeline_constants",
    });
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "const_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&vertices));

    const layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 8, .shader_location = 1 },
        },
    };

    // Same WGSL, three constant sets -> three specialised pipelines.
    const pipe_red: z.Pipeline = try makePipe(gpa, f, layout, &.{
        .{ .name = "ox", .value = -0.62 },
        .{ .name = "scl", .value = 0.3 },
        .{ .name = "tint_r", .value = 1.0 },
        .{ .name = "tint_g", .value = 0.25 },
        .{ .name = "tint_b", .value = 0.25 },
    });
    const pipe_green: z.Pipeline = try makePipe(gpa, f, layout, &.{
        .{ .name = "ox", .value = 0.0 },
        .{ .name = "scl", .value = 0.3 },
        .{ .name = "tint_r", .value = 0.25 },
        .{ .name = "tint_g", .value = 1.0 },
        .{ .name = "tint_b", .value = 0.35 },
    });
    const pipe_blue: z.Pipeline = try makePipe(gpa, f, layout, &.{
        .{ .name = "ox", .value = 0.62 },
        .{ .name = "scl", .value = 0.3 },
        .{ .name = "tint_r", .value = 0.35 },
        .{ .name = "tint_g", .value = 0.45 },
        .{ .name = "tint_b", .value = 1.0 },
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .vbo = vbo,
        .pipes = .{ pipe_red, pipe_green, pipe_blue },
    };
}

fn update(f: *z.Frame, s: *State) void {
    const ps: *z.PassState = f.gl.pass;
    for (&s.pipes) |*pipe| {
        pipe.bind(ps);
        pipe.setVertex(ps, 0, s.vbo, @sizeOf(@TypeOf(vertices)));
        pipe.drawArrays(ps, vertices.len, 1);
    }
    common.caption(f.gl, s.font, "pipeline_constants: one WGSL -> three pipelines via override constants");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline constants",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.039, .g = 0.047, .b = 0.071, .a = 1.0 },
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
