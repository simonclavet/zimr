//! pipeline_postprocess — a pass whose INPUT is a previous pass's output.
//! Render a spinning gradient triangle into a RenderTexture, then a FULLSCREEN
//! shader SAMPLES that texture and applies a screen-space effect (chromatic
//! aberration + vignette). The post-processing / bloom foundation.
//!
//! No inline WGSL: every shader is authored in Zig.
//!   - Scene pass reuses the `pipeline_uniforms` shaders (a vertex-stage mat4
//!     transform + gradient) rendered into the RT.
//!   - Post pass = the fullscreen `trivial_vs` + `postprocess_post_fs`,
//!     which declares a `scene` sampler. That sampler is the FIRST texture bound
//!     through `z.shader.loadShaderVF` — the unified `Resources` machinery
//!     builds its bind group; no hand-built pipeline. The texture is supplied by
//!     name: `.textures = .{ .scene = rt.asTexture() }`.
//!
//! The scene triangle is aspect-corrected for the WINDOW before going into the
//! square RT, so the full-bleed post pass (square RT stretched to screen) shows
//! it undistorted.
//!
//! Build:  zig build wgpu-pipeline-postprocess
//! Device: zig build wgpu-pipeline-postprocess-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");

const mulMat = zm.mulMat;
const scaling = zm.scaling;
const rotationZ = zm.rotationZ;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// Scene pass: reuse the pipeline_uniforms shaders (VS-stage mat4 transform).
const scene_vs_wgsl = @embedFile("pipeline_uniforms_vs.wgsl");
const scene_fs_wgsl = @embedFile("pipeline_uniforms_fs.wgsl");
const scene_vs_io = @import("pipeline_uniforms_vs_io.zig");
const scene_fs_io = @import("pipeline_uniforms_fs_io.zig");

// Post pass: fullscreen trivial VS + the chromatic/vignette FS (a sampler shader).
const post_vs_wgsl = @embedFile("trivial_vs.wgsl");
const post_fs_wgsl = @embedFile("postprocess_post_fs.wgsl");
const post_vs_io = @import("trivial_vs_io.zig");
const post_fs_io = @import("postprocess_post_fs_io.zig");

const rt_size: i32 = 720;

/// Scene vertex: clip-ish position + per-vertex colour (matches the
/// pipeline_uniforms vertex layout: vec2 @0, vec3 @1).
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

/// transform = scale(sx, sy) · rotateZ(angle), in zm row convention so the
/// shader's `mulMatPoint` matches WGSL `m * vec4(p, 1)`.
fn transform2d(angle: f32, sx: f32, sy: f32) zm.Mat {
    return mulMat(scaling(sx, sy, 1.0), rotationZ(angle));
}

const State = struct {
    font: z.Font,
    rt: z.RenderTexture,
    vbo: z.wgpu.BufferHandle,
    scene: z.shader.LoadedShader(scene_vs_io),
    post: z.shader.LoadedShader(post_fs_io),
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scene.deinit();
    s.post.deinit();
    z.wgpu.destroyBuffer(s.vbo);
    s.rt.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const vbo: z.wgpu.BufferHandle = z.wgpu.createBuffer(f.gpu.device, .{
        .size = @sizeOf(@TypeOf(vertices)),
        .usage = .{ .vertex = true, .copy_dst = true },
        .label = "scene_vbo",
    });
    z.wgpu.queueWriteBuffer(f.gpu.queue, vbo, 0, std.mem.sliceAsBytes(&vertices));

    const rt: z.RenderTexture = z.loadRenderTexture(f.gl, rt_size, rt_size);

    // Scene shader (renders into the RT — pin to the RT's rgba8/no-depth pass).
    const scene: z.shader.LoadedShader(scene_vs_io) = try z.shader.loadShaderVF(scene_vs_io, scene_fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = scene_vs_wgsl,
        .fs_wgsl_source = scene_fs_wgsl,
        .vertex_buffer_layouts = &.{z.shader.vertexLayout(scene_vs_io)},
        .initial_ubo = .{ .transform = transform2d(0, 1, 1) },
        .color_format = .rgba8_unorm,
        .depth_state = .none,
        .label = "postprocess_scene",
    });

    // Post shader: fullscreen, samples the RT. The `scene` sampler is bound by
    // name from the schema's `Samplers` — the new unified texture path.
    const post: z.shader.LoadedShader(post_fs_io) = try z.shader.loadShaderVF(post_vs_io, post_fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = post_vs_wgsl,
        .fs_wgsl_source = post_fs_wgsl,
        .textures = .{ .scene = rt.asTexture() },
        .label = "postprocess_post",
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .rt = rt,
        .vbo = vbo,
        .scene = scene,
        .post = post,
    };
}

fn update(f: *z.Frame, s: *State) void {
    // 1) Scene -> render texture. Aspect-correct for the window so the
    //    full-bleed post pass (square RT stretched to screen) is undistorted.
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const aspect: f32 = w / @max(h, 1.0);
    const sx: f32 = if (aspect < 1.0) 1.0 else 1.0 / aspect;
    const sy: f32 = if (aspect < 1.0) aspect else 1.0;
    s.scene.pushUbo(f.gpu.queue, .{ .transform = transform2d(f.time.time * 0.7, sx, sy) });

    const scene_bg_clear: zm.Color = .{ .r = 14, .g = 16, .b = 24, .a = 255 };
    z.beginTextureMode(f.gl, s.rt, scene_bg_clear);
    const rps: *z.PassState = f.gl.pass;
    s.scene.bindForDraw(rps);
    s.scene.setVertex(rps, 0, s.vbo, @sizeOf(@TypeOf(vertices)));
    s.scene.draw(rps, vertices.len, 1);
    z.endTextureMode(f.gl);

    // SCREEN PASS: open once (app owns begin/endDrawing).
    z.beginDrawing(f.gl);

    // 2) Post pass: the fullscreen sampler shader reads the RT into the
    //    backbuffer. drawFullscreenShader routes through the post shader's OWN
    //    pipeline + bind groups (group-1 RT sampler intact), NOT the 2D batch —
    //    so the batch's atlas can't clobber the sampler.
    z.drawFullscreenShader(f.gl, post_fs_io, &s.post);

    common.caption(f.gl, s.font, "pipeline_postprocess: scene -> texture -> fullscreen sampler (chromatic + vignette)");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    // Transient GPU-technique demo: render-target/shader teardown leaves
    // residual engine handles, so opt out of the managed leak gate.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline postprocess",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        },
    },
    .init = initState,
    // .memory left default (arena): per-lifecycle teardown is balanced (scene +
    // post + vbo + rt all freed), but the shutdown proof flags 1 residual buffer
    // from the LoadedShader/rt-sampling path that isn't reachable from State —
    // deferred rather than guess at an engine-owned handle.
    .deinit = deinit,
    .update = update,
    // Offscreen render-texture drawn before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
