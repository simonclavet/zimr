//! vao_multibuffer — a vertex layout split across SEPARATE buffers (one per
//! attribute) instead of one interleaved buffer. Positions live in slot 0,
//! colours in slot 1, and the colour buffer is rebound between two palettes
//! every ~1.2s — proving the slots are independent (swap one without touching
//! the other). This is the groundwork for instancing.
//!
//! No hand-written WGSL. The SHADER is identical to pipeline_uniforms (same
//! typed schema: vertex_position vec2@0, vertex_color vec3@1, a vertex-stage
//! transform UBO), so we REUSE those Zig shaders — the lesson here is the buffer
//! split, not the shader. The schema is layout-agnostic: `Attributes` says what
//! the shader reads; whether those bytes arrive interleaved or in two buffers is
//! purely the host's `vertex_buffer_layouts`. Interleaved gets the derived
//! `z.shader.vertexLayout`; here we hand-build two single-attribute layouts.
//!
//! Build:  zig build wgpu-vao-multibuffer
//! Device: zig build wgpu-vao-multibuffer-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const scaling = zm.scaling;
const co = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Reused, build-generated from the pipeline_uniforms Zig shaders.
const vs_wgsl = @embedFile("pipeline_uniforms_vs.wgsl");
const fs_wgsl = @embedFile("pipeline_uniforms_fs.wgsl");
const vs_io = @import("pipeline_uniforms_vs_io.zig");
const fs_io = @import("pipeline_uniforms_fs_io.zig");

/// Slot 0: positions only (vec2, stride 8).
const Pos = extern struct { x: f32, y: f32 };
/// Slot 1: colours only (vec3, stride 12).
const Col = extern struct { r: f32, g: f32, b: f32 };

const positions = [_]Pos{
    .{ .x = 0.0, .y = 0.65 },
    .{ .x = -0.65, .y = -0.55 },
    .{ .x = 0.65, .y = -0.55 },
};

/// Two palettes in two separate colour buffers, swapped at runtime.
const colors_a = [_]Col{
    .{ .r = 1.0, .g = 0.2, .b = 0.2 },
    .{ .r = 0.2, .g = 1.0, .b = 0.3 },
    .{ .r = 0.3, .g = 0.4, .b = 1.0 },
};
const colors_b = [_]Col{
    .{ .r = 0.1, .g = 0.9, .b = 0.9 },
    .{ .r = 0.95, .g = 0.85, .b = 0.2 },
    .{ .r = 0.9, .g = 0.25, .b = 0.9 },
};

const State = struct {
    font: z.Font,
    shader: z.shader.LoadedShader(vs_io),
    pos_vbo: z.wgpu.BufferHandle,
    col_a_vbo: z.wgpu.BufferHandle,
    col_b_vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.wgpu.destroyBuffer(s.pos_vbo);
    z.wgpu.destroyBuffer(s.col_a_vbo);
    z.wgpu.destroyBuffer(s.col_b_vbo);
    s.shader.deinit();
}

/// Aspect-scale (no rotation): keep the triangle upright so the colour swap
/// reads clearly. zm row convention so `mulMatPoint` matches WGSL `m * vec4`.
fn scale2d(sx: f32, sy: f32) zm.Mat {
    return scaling(sx, sy, 1.0);
}

fn makeVertexBuffer(
    f: *z.Frame,
    bytes: []const u8,
    label: []const u8,
) z.wgpu.BufferHandle {
    const buf: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = bytes.len,
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = label,
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, buf, 0, bytes);
    return buf;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const pos_vbo: z.wgpu.BufferHandle = makeVertexBuffer(f, std.mem.sliceAsBytes(&positions), "pos_vbo");
    const col_a_vbo: z.wgpu.BufferHandle = makeVertexBuffer(f, std.mem.sliceAsBytes(&colors_a), "col_a_vbo");
    const col_b_vbo: z.wgpu.BufferHandle = makeVertexBuffer(f, std.mem.sliceAsBytes(&colors_b), "col_b_vbo");

    // TWO vertex-buffer layouts: slot 0 = positions (loc 0), slot 1 = colours
    // (loc 1). Each is its own buffer, so the shader_location numbering spans
    // both. (Single-attribute layouts → hand-built, not the interleaved helper.)
    const pos_layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Pos),
        .step_mode = .vertex,
        .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }},
    };
    const col_layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Col),
        .step_mode = .vertex,
        .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 1 }},
    };

    const shader: z.shader.LoadedShader(vs_io) = try z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{ pos_layout, col_layout },
        .initial_ubo = .{ .transform = scale2d(1, 1) },
        .label = "vao_multibuffer",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .shader = shader,
        .pos_vbo = pos_vbo,
        .col_a_vbo = col_a_vbo,
        .col_b_vbo = col_b_vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const sx: f32 = if (aspect < 1.0) 1.0 else 1.0 / aspect;
    const sy: f32 = if (aspect < 1.0) aspect else 1.0;
    s.shader.pushUbo(f.gpu.queue, .{ .transform = scale2d(sx, sy) });

    // Swap the COLOUR buffer (slot 1) every ~1.2s; positions (slot 0) unchanged.
    const phase: f32 = @mod(f.time.time, 2.4);
    const use_b: bool = phase >= 1.2;
    const active_col: z.wgpu.BufferHandle = if (use_b) s.col_b_vbo else s.col_a_vbo;

    const ps: *z.PassState = f.gl.pass;
    s.shader.bindForDraw(ps);
    s.shader.setVertex(ps, 0, s.pos_vbo, @sizeOf(@TypeOf(positions)));
    s.shader.setVertex(ps, 1, active_col, @sizeOf(@TypeOf(colors_a)));
    s.shader.draw(ps, positions.len, 1);

    const label: []const u8 = if (use_b)
        "vao_multibuffer: colour buffer swapped to palette B (slot 1)"
    else
        "vao_multibuffer: positions slot 0, colours slot 1 (palette A)";
    co.caption(f.gl, s.font, label);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - vao multibuffer",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.039, .g = 0.047, .b = 0.071, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
