//! pipeline_basic — the first example on zimr's public custom-pipeline API.
//! Ported from raygpu's `pipeline_basic.c`: a custom render pipeline + a vertex
//! buffer + a single draw, drawing one gradient triangle.
//!
//! The headline is COMPOSITION + COMPLETE CONTROL, the zimr way: the shaders are
//! authored in ZIG (`pipeline_basic_vs.zig` / `_fs.zig`, schemas in the matching
//! `_io.zig` files) and transpiled at build time — the app never writes or sees
//! WGSL. `z.shader.loadShaderVF` builds the pipeline + bind-group layout from the
//! typed schema; the triangle still composites into the same pass as the 2D
//! caption below it.
//!
//! Build:  zig build wgpu-pipeline-basic
//! Device: zig build wgpu-pipeline-basic-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Build-time-transpiled WGSL of the Zig shaders (wired via the example's
// `.shaders` list in build.zig). The app embeds the artifact but never authors
// WGSL — these are the only mention of it and they're machine-generated.
const vs_wgsl = @embedFile("pipeline_basic_vs.wgsl");
const fs_wgsl = @embedFile("pipeline_basic_fs.wgsl");
const vs_io = @import("pipeline_basic_vs_io.zig");
const fs_io = @import("pipeline_basic_fs_io.zig");

/// Interleaved vertex: clip-space position (vec2) + colour (vec3), stride 20.
/// Mirrors `pipeline_basic_vs_io.Attributes`.
const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
};

/// One triangle in NDC, primary colours at the corners (the GPU interpolates).
const vertices = [_]Vertex{
    .{ .x = 0.0, .y = 0.65, .r = 1.0, .g = 0.2, .b = 0.2 },
    .{ .x = -0.65, .y = -0.55, .r = 0.2, .g = 1.0, .b = 0.3 },
    .{ .x = 0.65, .y = -0.55, .r = 0.3, .g = 0.4, .b = 1.0 },
};

const State = struct {
    font: z.Font,
    shader: z.shader.LoadedShader(fs_io),
    vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.shader.deinit();
    z.wgpu.destroyBuffer(s.vbo);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "tri_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&vertices));

    // The vertex layout is DERIVED from the typed schema — single source of
    // truth, so the buffer and the shader can't drift apart.
    const shader: z.shader.LoadedShader(fs_io) = try z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .label = "pipeline_basic",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .shader = shader,
        .vbo = vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // Aspect-correct the triangle so it stays equilateral on any viewport.
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const sx: f32 = if (aspect < 1.0) 1.0 else 1.0 / aspect;
    const sy: f32 = if (aspect < 1.0) aspect else 1.0;
    var corrected: [vertices.len]Vertex = vertices;
    for (&corrected) |*v| {
        v.x *= sx;
        v.y *= sy;
    }
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.vbo, 0, std.mem.sliceAsBytes(&corrected));

    const ps: *z.PassState = f.gl.pass;
    s.shader.bindForDraw(ps);
    s.shader.setVertex(ps, 0, s.vbo, @sizeOf(@TypeOf(vertices)));
    s.shader.draw(ps, vertices.len, 1);

    common.caption(f.gl, s.font, "pipeline_basic: a Zig-authored custom pipeline, composed with 2D");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline basic",
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
