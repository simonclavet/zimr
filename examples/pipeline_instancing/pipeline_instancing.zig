//! pipeline_instancing - increment 4 of the custom-pipeline API
//! (`src/notes/webgpu_control.md`). Ported from raygpu's `pipeline_instancing.cpp`:
//! ONE draw call paints a whole grid of triangles, each fed its own offset and
//! colour from INSTANCE-rate vertex buffers.
//!
//! The new material is `step_mode = .instance` on a vertex-buffer layout: slot 0
//! advances per VERTEX (the shared triangle shape), slots 1 and 2 advance per
//! INSTANCE (a position offset and a colour). `drawArrays(vertex_count,
//! instance_count)` then replays the 3-vertex triangle `instance_count` times,
//! and the GPU pulls a fresh offset+colour for each. The offset buffer is
//! re-uploaded every frame so the grid ripples on a sine wave - dynamic
//! per-instance data, the raygpu demo's trick.
//!
//! Builds straight on vao_multibuffer: same multi-buffer layout, one slot just
//! switched to instance rate. A UBO carries the aspect-correct scale.
//!
//! Build:  zig build wgpu-pipeline-instancing
//! Device: zig build wgpu-pipeline-instancing-standalone -Dmode=release

const std = @import("std");
const zm = @import("zm");
const float = zm.float;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const vs_io = @import("instancing_vs_io.zig");
const fs_io = @import("pipeline_uniforms_fs_io.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Build-generated WGSL (Zig shader -> SPIR-V -> spv2wgsl). The fragment stage
// is shared with pipeline_uniforms (pure colour pass-through), so we reuse its
// generated WGSL rather than authoring a duplicate.
const vs_wgsl = @embedFile("instancing_vs.wgsl");
const fs_wgsl = @embedFile("pipeline_uniforms_fs.wgsl");

const cols: usize = 14;
const rows: usize = 9;
const inst_count: usize = cols * rows;

const Pos = extern struct { x: f32, y: f32 };
const Off = extern struct { x: f32, y: f32 };
const Col = extern struct { r: f32, g: f32, b: f32 };

/// The shared per-vertex shape: one small upward triangle around the origin.
const tri_h: f32 = 0.05;
const tri = [_]Pos{
    .{ .x = 0.0, .y = tri_h },
    .{ .x = -tri_h * 0.87, .y = -tri_h * 0.5 },
    .{ .x = tri_h * 0.87, .y = -tri_h * 0.5 },
};

const State = struct {
    font: z.Font,
    shader: z.shader.LoadedShader(vs_io),
    vbo: z.wgpu.BufferHandle,
    offset_vbo: z.wgpu.BufferHandle,
    color_vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.shader.deinit();
    z.wgpu.destroyBuffer(s.vbo);
    z.wgpu.destroyBuffer(s.offset_vbo);
    z.wgpu.destroyBuffer(s.color_vbo);
}

fn aspectMat(sx: f32, sy: f32) [4]@Vector(4, f32) {
    return .{
        .{ sx, 0, 0, 0 },
        .{ 0, sy, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
}

/// Grid cell -> base NDC position (before the per-frame wave).
fn cellPos(cx: usize, ry: usize) Off {
    const fx: f32 = float(cx) / float(cols - 1);
    const fy: f32 = float(ry) / float(rows - 1);
    return .{ .x = (fx - 0.5) * 1.7, .y = (fy - 0.5) * 1.5 };
}

fn makeBuffer(f: *z.Frame, bytes: []const u8, label: []const u8) z.wgpu.BufferHandle {
    const buf: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = bytes.len,
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = label,
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, buf, 0, bytes);
    return buf;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = makeBuffer(f, std.mem.sliceAsBytes(&tri), "inst_tri_vbo");

    // Per-instance colours: a 2D gradient across the grid. Uploaded once.
    var colors: [inst_count]Col = undefined;
    for (0..rows) |ry| {
        for (0..cols) |cx| {
            const fx: f32 = float(cx) / float(cols - 1);
            const fy: f32 = float(ry) / float(rows - 1);
            colors[ry * cols + cx] = .{ .r = 0.25 + 0.75 * fx, .g = 0.3 + 0.7 * fy, .b = 0.3 + 0.7 * (1.0 - fx) };
        }
    }
    const color_vbo: z.wgpu.BufferHandle = makeBuffer(f, std.mem.sliceAsBytes(&colors), "inst_color_vbo");

    // Per-instance offsets: seeded with the base grid; re-uploaded each frame.
    var offsets: [inst_count]Off = undefined;
    for (0..rows) |ry| {
        for (0..cols) |cx| {
            offsets[ry * cols + cx] = cellPos(cx, ry);
        }
    }
    const offset_vbo: z.wgpu.BufferHandle = makeBuffer(f, std.mem.sliceAsBytes(&offsets), "inst_offset_vbo");

    // Three buffer layouts: slot 0 per-VERTEX, slots 1 & 2 per-INSTANCE. The
    // schema can't express step rate, so instanced layouts are hand-built and
    // passed to loadShaderVF (rather than the derived `z.shader.vertexLayout`).
    const vert_layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Pos),
        .step_mode = .vertex,
        .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 0 }},
    };
    const offset_layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Off),
        .step_mode = .instance,
        .attributes = &.{.{ .format = .float32x2, .offset = 0, .shader_location = 1 }},
    };
    const color_layout: z.VertexLayout = .{
        .array_stride = @sizeOf(Col),
        .step_mode = .instance,
        .attributes = &.{.{ .format = .float32x3, .offset = 0, .shader_location = 2 }},
    };

    // The UBO (group 0) is owned by the shader's Resources; pushUbo rewrites it
    // each frame. No hand-wired bind group / layout - loadShaderVF builds them.
    const shader: z.shader.LoadedShader(vs_io) = try z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .label = "pipeline_instancing",
        .vertex_buffer_layouts = &.{ vert_layout, offset_layout, color_layout },
        .initial_ubo = .{ .transform = aspectMat(1, 1) },
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .shader = shader,
        .vbo = vbo,
        .offset_vbo = offset_vbo,
        .color_vbo = color_vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const sx: f32 = if (aspect < 1.0) 1.0 else 1.0 / aspect;
    const sy: f32 = if (aspect < 1.0) aspect else 1.0;
    s.shader.pushUbo(f.gpu.queue, .{ .transform = aspectMat(sx, sy) });

    // Animate the per-instance offsets: a travelling sine wave in Y. Dynamic
    // per-instance data, re-uploaded each frame.
    const t: f32 = f.time.time;
    var offsets: [inst_count]Off = undefined;
    for (0..rows) |ry| {
        for (0..cols) |cx| {
            const base: Off = cellPos(cx, ry);
            const wave: f32 = @sin(t * 1.8 + base.x * 4.0) * 0.045;
            offsets[ry * cols + cx] = .{ .x = base.x, .y = base.y + wave };
        }
    }
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.offset_vbo, 0, std.mem.sliceAsBytes(&offsets));

    const ps: *z.PassState = f.gl.pass;
    s.shader.bindForDraw(ps);
    s.shader.setVertex(ps, 0, s.vbo, @sizeOf(@TypeOf(tri)));
    s.shader.setVertex(ps, 1, s.offset_vbo, @sizeOf([inst_count]Off));
    s.shader.setVertex(ps, 2, s.color_vbo, @sizeOf([inst_count]Col));
    s.shader.draw(ps, tri.len, inst_count);

    common.caption(f.gl, s.font, "pipeline_instancing: one draw call, 126 triangles (per-instance offset + colour)");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline instancing",
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
