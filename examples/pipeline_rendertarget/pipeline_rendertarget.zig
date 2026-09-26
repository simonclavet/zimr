//! pipeline_rendertarget - render a CUSTOM PIPELINE into an offscreen
//! RenderTexture, then composite that texture to the screen many times -
//! "render once, reuse many". The foundation for post-processing and MSAA.
//!
//! No hand-written WGSL. The custom shader is the same pos+colour+transform
//! shader as pipeline_uniforms (REUSED - this example's lesson is the offscreen
//! render + composite, not the shader). The triangle is drawn once into the RT,
//! then `drawTextureRec` stamps `rt.asTexture()` across a grid. The texture
//! sampling is the ENGINE's 2D path, not a custom sampler.
//!
//! The RT is colour-only rgba8 and depthless, so the loadShaderVF call pins
//! `.color_format` + `.depth_state = .none` (the window's depth default would
//! otherwise expect a depth attachment the RT pass doesn't have).
//!
//! Build:  zig build wgpu-pipeline-rendertarget
//! Device: zig build wgpu-pipeline-rendertarget-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const float = zm.float;
const rotationZ = zm.rotationZ;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const rt_size: i32 = 480;
const grid_cols: usize = 3;
const grid_rows: usize = 2;
const rt_format: z.wgpu.TextureFormat = .rgba8_unorm;

// Reused, build-generated from the pipeline_uniforms Zig shaders.
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
    .{ .x = 0.0, .y = 0.7, .r = 1.0, .g = 0.2, .b = 0.2 },
    .{ .x = -0.7, .y = -0.6, .r = 0.2, .g = 1.0, .b = 0.3 },
    .{ .x = 0.7, .y = -0.6, .r = 0.3, .g = 0.4, .b = 1.0 },
};

const tints = [grid_cols * grid_rows]zm.Color{
    .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    .{ .r = 255, .g = 220, .b = 180, .a = 255 },
    .{ .r = 180, .g = 230, .b = 255, .a = 255 },
    .{ .r = 210, .g = 255, .b = 210, .a = 255 },
    .{ .r = 255, .g = 200, .b = 230, .a = 255 },
    .{ .r = 230, .g = 230, .b = 255, .a = 255 },
};

const State = struct {
    font: z.Font,
    rt: z.RenderTexture,
    shader: z.shader.LoadedShader(vs_io),
    vbo: z.wgpu.BufferHandle,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.shader.deinit();
    z.wgpu.destroyBuffer(s.vbo);
    s.rt.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "rt_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&vertices));

    const shader: z.shader.LoadedShader(vs_io) = try z.shader.loadShaderVF(vs_io, fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(vs_io)},
        .color_format = rt_format,
        .depth_state = .none,
        .label = "rendertarget",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .rt = z.loadRenderTexture(f.gl, rt_size, rt_size),
        .shader = shader,
        .vbo = vbo,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // 1) Render the custom pipeline ONCE into the offscreen render texture.
    const m: zm.Mat = rotationZ(f.time.time * 0.7);
    s.shader.pushUbo(f.gpu.queue, .{ .transform = m });

    const tile_bg: zm.Color = .{ .r = 16, .g = 20, .b = 30, .a = 255 };
    z.beginTextureMode(f.gl, s.rt, tile_bg);
    const rps: *z.PassState = f.gl.pass;
    s.shader.bindForDraw(rps);
    s.shader.setVertex(rps, 0, s.vbo, @sizeOf(@TypeOf(vertices)));
    s.shader.draw(rps, vertices.len, 1);
    z.endTextureMode(f.gl);

    // SCREEN PASS: open once (app owns begin/endDrawing), then composite.
    z.beginDrawing(f.gl);

    // 2) Composite: stamp the rendered texture across a grid on the backbuffer.
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const pad: f32 = 12.0;
    const cell_w: f32 = (w - pad * float(grid_cols + 1)) / float(grid_cols);
    const cell_h: f32 = cell_w; // square stamps (the RT is square)
    const total_h: f32 = cell_h * float(grid_rows) + pad * float(grid_rows - 1);
    const y0: f32 = (h - total_h) * 0.5;
    const tex: z.WgpuTexture = s.rt.asTexture();
    for (0..grid_rows) |gy| {
        for (0..grid_cols) |gx| {
            const dx: f32 = pad + float(gx) * (cell_w + pad);
            const dy: f32 = y0 + float(gy) * (cell_h + pad);
            const tint: zm.Color = tints[gy * grid_cols + gx];
            f.gl.texture(.{ .x = dx, .y = dy, .width = cell_w, .height = cell_h }, tex, .{ .tint = tint });
        }
    }

    common.caption(f.gl, s.font, "pipeline_rendertarget: custom pipeline -> offscreen texture -> stamped 6x");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline render target",
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
    // Offscreen render-texture drawn before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
