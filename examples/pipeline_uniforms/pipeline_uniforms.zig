//! pipeline_uniforms — a custom render pipeline driven by a VERTEX-STAGE
//! uniform buffer. The UBO holds a 4x4 transform the app rewrites every frame,
//! so the triangle spins and stays aspect-correct (the matrix replaces the
//! hand vertex-rewrite the basic example used).
//!
//! No hand-written WGSL: the shaders are authored in Zig
//! (`pipeline_uniforms_vs.zig` / `_fs.zig` + typed `_io.zig` schemas) and the
//! build transpiles them. What's new vs pipeline_basic:
//!   - a `Ubo` in the VERTEX schema. Because it's vertex-stage, the codegen
//!     binds it at @group(0) and `z.shader.loadShaderVF` routes it there for
//!     us — the app just calls `s.shader.pushUbo(...)` each frame.
//!   - the vertex layout is DERIVED from the schema (`z.shader.vertexLayout`).
//!   - drawing goes THROUGH the shader handle (`bindForDraw`/`setVertex`/`draw`).
//!
//! Still composes with the immediate-mode caption, and still depthless.
//!
//! Build:  zig build wgpu-pipeline-uniforms
//! Device: zig build wgpu-pipeline-uniforms-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const mulMat = zm.mulMat;
const scaling = zm.scaling;
const rotationZ = zm.rotationZ;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Build-generated WGSL artifacts + their typed schemas. The app never writes
// WGSL — these are machine output of the Zig shader pipeline.
const vs_wgsl = @embedFile("pipeline_uniforms_vs.wgsl");
const fs_wgsl = @embedFile("pipeline_uniforms_fs.wgsl");
const vs_io = @import("pipeline_uniforms_vs_io.zig");
const fs_io = @import("pipeline_uniforms_fs_io.zig");

const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};

const vertices = [_]Vertex{
    .{ .x = 0.0, .y = 0.65, .r = 1.0, .g = 0.2, .b = 0.2 },
    .{ .x = -0.65, .y = -0.55, .r = 0.2, .g = 1.0, .b = 0.3 },
    .{ .x = 0.65, .y = -0.55, .r = 0.3, .g = 0.4, .b = 1.0 },
};

const State = struct {
    font: z.Font,
    shader: z.shader.LoadedShader(vs_io),
    vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.shader.deinit();
    z.wgpu.destroyBuffer(s.vbo);
}

/// transform = scale(sx, sy) · rotateZ(angle), in zm row convention so
/// `mulMatPoint` in the shader matches WGSL `m * vec4(p, 1)`. Rotating first
/// then aspect-scaling keeps the triangle equilateral on any window shape.
fn transform2d(angle: f32, sx: f32, sy: f32) zm.Mat {
    return mulMat(scaling(sx, sy, 1.0), rotationZ(angle));
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "tri_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&vertices));

    // The pipeline, UBO buffer + bind group, and the @group(0) routing are all
    // derived from the typed schemas — no bind-group boilerplate in the app.
    const shader: z.shader.LoadedShader(vs_io) = try z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .initial_ubo = .{ .transform = transform2d(0, 1, 1) },
        .label = "pipeline_uniforms",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .shader = shader,
        .vbo = vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // Spin over time, aspect-correct so the triangle stays equilateral.
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const sx: f32 = if (aspect < 1.0) 1.0 else 1.0 / aspect;
    const sy: f32 = if (aspect < 1.0) aspect else 1.0;
    s.shader.pushUbo(f.gpu.queue, .{ .transform = transform2d(f.time.time * 0.6, sx, sy) });

    const ps: *z.PassState = f.gl.pass;
    s.shader.bindForDraw(ps);
    s.shader.setVertex(ps, 0, s.vbo, @sizeOf(@TypeOf(vertices)));
    s.shader.draw(ps, vertices.len, 1);

    common.caption(f.gl, s.font, "pipeline_uniforms: a vertex-stage UBO transform drives a custom pipeline");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline uniforms",
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
