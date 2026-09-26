//! pipeline_settings - pipeline STATE: the same translucent geometry drawn
//! twice, left with `.blend = .alpha`, right with `.blend = .additive`, so the
//! difference is unmistakable (alpha occludes back-to-front; additive sums to
//! white where the three triangles overlap).
//!
//! No hand-written WGSL. The shaders are authored in Zig: a bespoke VS
//! (`pipeline_settings_vs.zig`) plus the SHARED pass-through fragment shader
//! (`pipeline_uniforms_fs.zig`) - a reminder that "emit the interpolated colour"
//! is one shader, reused. The two pipelines come from two `loadShaderVF` calls
//! that differ ONLY by `.blend_state`; everything else (schema, layout, UBO) is
//! identical. The per-pipeline x-offset rides in the UBO (`p.z`) rather than a
//! pipeline-override constant - overrides are pipeline_constants' story.
//!
//! Build:  zig build wgpu-pipeline-settings
//! Device: zig build wgpu-pipeline-settings-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Bespoke VS + the shared pass-through FS, build-generated from Zig.
const vs_wgsl = @embedFile("pipeline_settings_vs.wgsl");
const fs_wgsl = @embedFile("pipeline_uniforms_fs.wgsl");
const vs_io = @import("pipeline_settings_vs_io.zig");
const fs_io = @import("pipeline_uniforms_fs_io.zig");

const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

/// One translucent triangle centred at (cx,cy).
fn tri(cx: f32, cy: f32, r: f32, g: f32, b: f32) [3]Vertex {
    const h: f32 = 0.42;
    const al: f32 = 0.6;
    return .{
        .{ .x = cx, .y = cy + h, .r = r, .g = g, .b = b, .a = al },
        .{ .x = cx - 0.36, .y = cy - 0.3, .r = r, .g = g, .b = b, .a = al },
        .{ .x = cx + 0.36, .y = cy - 0.3, .r = r, .g = g, .b = b, .a = al },
    };
}

/// Three overlapping triangles (R/G/B) forming a rosette.
const cluster = tri(0.0, 0.12, 1.0, 0.2, 0.2) ++
    tri(-0.12, -0.08, 0.2, 1.0, 0.3) ++
    tri(0.12, -0.08, 0.3, 0.4, 1.0);

const State = struct {
    font: z.Font,
    vbo: z.wgpu.BufferHandle,
    alpha_shader: z.shader.LoadedShader(vs_io),
    add_shader: z.shader.LoadedShader(vs_io),
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.alpha_shader.deinit();
    s.add_shader.deinit();
    z.wgpu.destroyBuffer(s.vbo);
}

/// Build a pipeline for one blend mode. Identical except for `.blend_state`.
fn blendShader(
    gpa: Allocator,
    f: *z.Frame,
    blend: z.wgpu.BlendMode,
    label: []const u8,
) !z.shader.LoadedShader(vs_io) {
    return z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .blend_state = blend,
        .label = label,
    });
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(cluster)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "blend_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&cluster));

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .vbo = vbo,
        .alpha_shader = try blendShader(gpa, f, .alpha, "blend_alpha"),
        .add_shader = try blendShader(gpa, f, .additive, "blend_additive"),
    };
}

/// Aspect-correct scale packed with an x-offset: p = (sx, sy, ox, 0).
fn scaleOffset(f: *z.Frame, ox: f32) Vec {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const size: f32 = 0.5;
    const sx: f32 = if (aspect < 1.0) size else size / aspect;
    const sy: f32 = if (aspect < 1.0) size * aspect else size;
    return .{ sx, sy, ox, 0.0 };
}

fn update(f: *z.Frame, s: *State) void {
    const ps: *z.PassState = f.gl.pass;
    const verts: u32 = cluster.len;
    const vbo_bytes: u64 = @sizeOf(@TypeOf(cluster));

    // Left half: alpha blend (offset -0.5).
    s.alpha_shader.pushUbo(f.gpu.queue, .{ .p = scaleOffset(f, -0.5) });
    s.alpha_shader.bindForDraw(ps);
    s.alpha_shader.setVertex(ps, 0, s.vbo, vbo_bytes);
    s.alpha_shader.draw(ps, verts, 1);

    // Right half: additive blend (offset +0.5).
    s.add_shader.pushUbo(f.gpu.queue, .{ .p = scaleOffset(f, 0.5) });
    s.add_shader.bindForDraw(ps);
    s.add_shader.setVertex(ps, 0, s.vbo, vbo_bytes);
    s.add_shader.draw(ps, verts, 1);

    common.caption(f.gl, s.font, "pipeline_settings: blend modes - left alpha, right additive (same geometry)");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline settings",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.02, .g = 0.02, .b = 0.03, .a = 1.0 },
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
