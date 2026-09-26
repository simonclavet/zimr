//! pipeline_msaa - MSAA (multisample anti-aliasing). The same rotating
//! high-contrast triangle is rendered twice into small targets, magnified side
//! by side so the edge quality is obvious:
//!   - LEFT  : 1 sample  -> jagged, stair-stepped diagonal edges
//!   - RIGHT : 4 samples -> resolved to a 1-sample texture -> smooth edges
//!
//! No hand-written WGSL: the shader is authored in Zig (position-only triangle,
//! a vertex-stage transform UBO, a constant-colour FS with no varyings). The
//! two pipelines come from two `loadShaderVF` calls differing only by
//! `.sample_count` (1 vs 4). Because these render into rgba8 offscreen targets
//! with no depth, the calls also pin `.color_format` and `.depth_state = .none`.
//!
//! The MSAA pass is self-managed on its OWN command encoder (a multisampled
//! attachment + resolve target can't go through beginTextureMode). The aliased
//! side uses the normal offscreen path. Both display via drawTextureRec.
//!
//! Build:  zig build wgpu-pipeline-msaa
//! Device: zig build wgpu-pipeline-msaa-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const rotationZ = zm.rotationZ;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const rt_size: i32 = 220; // small targets so magnified jaggies are visible
const samples: u4 = 4;
const rt_format: z.wgpu.TextureFormat = .rgba8_unorm;

const vs_wgsl = @embedFile("pipeline_msaa_vs.wgsl");
const fs_wgsl = @embedFile("pipeline_msaa_fs.wgsl");
const vs_io = @import("pipeline_msaa_vs_io.zig");
const fs_io = @import("pipeline_msaa_fs_io.zig");

const Vertex = extern struct { x: f32, y: f32 };

const vertices = [_]Vertex{
    .{ .x = 0.0, .y = 0.62 },
    .{ .x = -0.55, .y = -0.45 },
    .{ .x = 0.55, .y = -0.45 },
};

const State = struct {
    font: z.Font,
    aliased_rt: z.RenderTexture,
    resolve_rt: z.RenderTexture,
    msaa_view: z.wgpu.TextureViewHandle,
    msaa_tex: z.wgpu.TextureHandle,
    aliased_shader: z.shader.LoadedShader(vs_io),
    msaa_shader: z.shader.LoadedShader(vs_io),
    vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.aliased_shader.deinit();
    s.msaa_shader.deinit();
    s.aliased_rt.deinit();
    s.resolve_rt.deinit();
    z.wgpu.destroyTextureView(s.msaa_view);
    z.wgpu.destroyTexture(s.msaa_tex);
    z.wgpu.destroyBuffer(s.vbo);
}

/// Build a pipeline for one sample count. Targets are rgba8 with no depth.
fn msaaShader(
    gpa: Allocator,
    f: *z.Frame,
    sample_count: u4,
    label: []const u8,
) !z.shader.LoadedShader(vs_io) {
    return z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .color_format = rt_format,
        .depth_state = .none,
        .sample_count = sample_count,
        .label = label,
    });
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "msaa_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&vertices));

    // 1-sample sampleable targets: one rendered directly (aliased), one used as
    // the MSAA resolve target. Plus a 4-sample colour texture for the MSAA pass.
    const aliased_rt: z.RenderTexture = z.loadRenderTexture(f.gl, rt_size, rt_size);
    const resolve_rt: z.RenderTexture = z.loadRenderTexture(f.gl, rt_size, rt_size);
    const msaa_tex: z.wgpu.TextureHandle = z.wgpu.createTexture(f.gpu.device, .{
        .width = @intCast(rt_size),
        .height = @intCast(rt_size),
        .format = rt_format,
        .usage = .{ .render_attachment = true },
        .sample_count = samples,
        .label = "msaa_color",
    });
    const msaa_view: z.wgpu.TextureViewHandle = z.wgpu.createTextureView(msaa_tex);

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .aliased_rt = aliased_rt,
        .resolve_rt = resolve_rt,
        .msaa_view = msaa_view,
        .msaa_tex = msaa_tex,
        .aliased_shader = try msaaShader(gpa, f, 1, "msaa_aliased"),
        .msaa_shader = try msaaShader(gpa, f, samples, "msaa_4x"),
        .vbo = vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    const m: zm.Mat = rotationZ(f.time.time * 0.5);
    const vsize: u64 = @sizeOf(@TypeOf(vertices));
    const clear: zm.Color = .{ .r = 12, .g = 14, .b = 20, .a = 255 };

    // LEFT: aliased (1 sample) via the normal offscreen path.
    s.aliased_shader.pushUbo(f.gpu.queue, .{ .transform = m });
    z.beginTextureMode(f.gl, s.aliased_rt, clear);
    const ap: *z.PassState = f.gl.pass;
    s.aliased_shader.bindForDraw(ap);
    s.aliased_shader.setVertex(ap, 0, s.vbo, vsize);
    s.aliased_shader.draw(ap, vertices.len, 1);
    z.endTextureMode(f.gl);

    // RIGHT: MSAA (4 samples) on its own encoder, resolving into resolve_rt.
    s.msaa_shader.pushUbo(f.gpu.queue, .{ .transform = m });
    const enc: z.wgpu.CommandEncoderHandle = z.wgpu.createCommandEncoder(f.gpu.device);
    const raw: z.wgpu.RenderPassEncoderHandle = z.wgpu.render_pass.begin(.{
        .encoder = enc,
        .color_view = s.msaa_view,
        .clear = .{ .r = 12.0 / 255.0, .g = 14.0 / 255.0, .b = 20.0 / 255.0, .a = 1.0 },
        .resolve_view = s.resolve_rt.color_view,
    });
    var mp: z.PassState = .{ .pass = raw };
    s.msaa_shader.bindForDraw(&mp);
    s.msaa_shader.setVertex(&mp, 0, s.vbo, vsize);
    s.msaa_shader.draw(&mp, vertices.len, 1);
    z.wgpu.render_pass.end(raw);
    const cmd: z.wgpu.CommandBufferHandle = z.wgpu.finishCommandEncoder(enc);
    z.wgpu.queueSubmit(f.gpu.queue, cmd);

    // ---- SCREEN PASS: open once, composite the two RTs side by side. ----
    z.beginDrawing(f.gl);

    // Composite both, magnified side by side, on the backbuffer.
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const cell: f32 = @min(w * 0.44, h * 0.6);
    const gap: f32 = w * 0.04;
    const total: f32 = cell * 2 + gap;
    const x0: f32 = (w - total) * 0.5;
    const y0: f32 = (h - cell) * 0.5;
    const white: zm.Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    f.gl.texture(.{ .x = x0, .y = y0, .width = cell, .height = cell }, s.aliased_rt.asTexture(), .{ .tint = white });
    f.gl.texture(
        .{ .x = x0 + cell + gap, .y = y0, .width = cell, .height = cell },
        s.resolve_rt.asTexture(),
        .{ .tint = white },
    );

    f.gl.text(.{ x0, y0 + cell + 10 }, "1x (aliased)", .{
        .size = 22,
        .color = common.palette.ink_dim,
        .font = &s.font,
    });
    f.gl.text(
        .{ x0 + cell + gap, y0 + cell + 10 },
        "4x MSAA",
        .{ .size = 22, .color = common.palette.ink_dim, .font = &s.font },
    );
    common.caption(f.gl, s.font, "pipeline_msaa: 1x vs 4x multisampling - compare the diagonal edges");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline MSAA",
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
    // Aliased + MSAA-resolve targets render offscreen before the screen opens
    // (tile-based-GPU safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
