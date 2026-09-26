//! pipeline_bloom - a full multi-pass BLOOM effect, now entirely on the typed
//! shader interface (no inline WGSL, no override constants). Five effect passes
//! across three render textures:
//!
//!   scene  -> rt_scene         (a field of orbiting, pulsing glowing orbs)
//!   bright -> rt_a             (keep only pixels above a luminance threshold)
//!   blurH  -> rt_b, blurV -> rt_a   (separable Gaussian, x4 for a wider glow)
//!   composite: rt_scene + rt_a -> backbuffer (add the blurred highlights back)
//!
//! Every effect pass is a fullscreen shader authored in pure Zig
//! (`examples/bloom_*.zig`) and compiled to WGSL by the build. Each pass's
//! per-pass configuration - the bright threshold, the blur direction, the
//! composite intensity - is a PER-PASS UBO rather than a WGSL `override`
//! constant. That's the clean fit here (each value is set once at load) and it
//! needs no spec-constant authoring. The two blur directions are two separate
//! LoadedShaders with their `dir` baked in at load, which also sidesteps the
//! "can't update a UBO between draws in one command buffer" hazard.
//!
//! The scene itself is drawn with the immediate 2D path (radial-gradient
//! circles straight into rt_scene) - bright glowing cores on near-black, which
//! is what bloom actually wants: small very-bright regions against darkness.
//!
//! Build:  zig build pipeline-bloom
//! Device: zig build pipeline-bloom-standalone -Dmode=release

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const common = @import("example_common");
const zm = @import("zm");
const Vec = zm.Vec;
const float = zm.float;
const clamp = zm.clamp;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// The scene is a field of glowing orbs drawn straight into rt_scene with the
// immediate 2D path (drawCircleGradient - a bright core fading to black, which
// is exactly the shape of a light source). No scene shader / vertex buffer: the
// engine's built-in 2D shape shader draws it, and the bloom chain does the rest.
//
// WHY ORBS, NOT THE OLD GRADIENT TRIANGLE: bloom keeps only pixels whose
// LUMINANCE clears `bright_thresh`, so it pops only where the scene has small,
// very bright regions against darkness. A flat mid-bright triangle sits just
// over the threshold everywhere and blooms as a dull uniform smear. Bright
// cores on black give crisp, glowing halos - the whole point of the effect.

// Effect passes - the bloom shaders (examples/bloom_*.zig), wired into this
// example via the `.shaders` build list. The typed `_io` schemas are imported
// directly; the `.wgsl` bodies are build artifacts embedded by basename.
const fullscreen_vs_io = @import("bloom_fullscreen_vs_io.zig");
const bright_fs_io = @import("bloom_bright_fs_io.zig");
const blur_fs_io = @import("bloom_blur_fs_io.zig");
const composite_fs_io = @import("bloom_composite_fs_io.zig");
const fullscreen_vs_wgsl = @embedFile("bloom_fullscreen_vs.wgsl");
const bright_fs_wgsl = @embedFile("bloom_bright_fs.wgsl");
const blur_fs_wgsl = @embedFile("bloom_blur_fs.wgsl");
const composite_fs_wgsl = @embedFile("bloom_composite_fs.wgsl");

const rt_size: i32 = 512;
const rt_sizef: f32 = 512.0;
const blur_iters: usize = 2;
const bright_thresh: f32 = 0.20;
const blur_texel: f32 = 2.0 / 512.0;
const composite_intensity: f32 = 4.0;

const BrightSchema = z.shader.MaterialSchema(fullscreen_vs_io, bright_fs_io);
const BlurSchema = z.shader.MaterialSchema(fullscreen_vs_io, blur_fs_io);
const CompositeSchema = z.shader.MaterialSchema(fullscreen_vs_io, composite_fs_io);

/// One glowing orb: an orbit (radius + angular speed + phase), a core colour
/// with a WHITE-HOT centre, and a base radius that pulses. Colours are chosen
/// BRIGHT and high-luminance (not pure saturated hues, which have low luminance
/// and would barely clear the bright-pass threshold) so each orb blooms hard.
const Orb = struct {
    orbit: f32, // orbit radius as a fraction of the RT half-size
    speed: f32, // radians/sec around the centre
    phase: f32, // starting angle
    pulse: f32, // radians/sec of the size/brightness pulse
    radius: f32, // base radius in RT pixels
    color: Vec, // {r,g,b,_} in 0..1 - the halo tint
};

const orbs = [_]Orb{
    .{ .orbit = 0.00, .speed = 0.0, .phase = 0.0, .pulse = 1.3, .radius = 56, .color = .{ 1.0, 0.95, 0.85, 1 } },
    .{ .orbit = 0.42, .speed = 0.55, .phase = 0.0, .pulse = 2.1, .radius = 11, .color = .{ 1.0, 0.4, 0.7, 1 } },
    .{ .orbit = 0.42, .speed = 0.55, .phase = 2.09, .pulse = 1.7, .radius = 44, .color = .{ 0.4, 1.0, 0.9, 1 } },
    .{ .orbit = 0.42, .speed = 0.55, .phase = 4.19, .pulse = 2.4, .radius = 14, .color = .{ 1.0, 0.85, 0.35, 1 } },
    .{ .orbit = 0.66, .speed = -0.35, .phase = 1.0, .pulse = 1.9, .radius = 50, .color = .{ 0.55, 0.75, 1.0, 1 } },
    .{ .orbit = 0.66, .speed = -0.35, .phase = 3.1, .pulse = 2.6, .radius = 20, .color = .{ 0.7, 1.0, 0.5, 1 } },
    .{ .orbit = 0.66, .speed = -0.35, .phase = 5.2, .pulse = 1.5, .radius = 34, .color = .{ 1.0, 0.6, 0.4, 1 } },
    .{ .orbit = 0.84, .speed = 0.8, .phase = 0.5, .pulse = 3.0, .radius = 9, .color = .{ 0.95, 0.7, 1.0, 1 } },
    .{ .orbit = 0.84, .speed = 0.8, .phase = 3.6, .pulse = 2.2, .radius = 40, .color = .{ 0.6, 1.0, 1.0, 1 } },
};

const State = struct {
    font: z.Font,
    rt_scene: z.RenderTexture,
    rt_a: z.RenderTexture,
    rt_b: z.RenderTexture,
    bright: z.shader.LoadedShader(BrightSchema),
    blur_h: z.shader.LoadedShader(BlurSchema),
    blur_v: z.shader.LoadedShader(BlurSchema),
    composite: z.shader.LoadedShader(CompositeSchema),
};

fn deinit(gpa: Allocator, s: *State) void {
    s.bright.deinit();
    s.blur_h.deinit();
    s.blur_v.deinit();
    s.composite.deinit();
    s.rt_scene.deinit();
    s.rt_a.deinit();
    s.rt_b.deinit();
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Three render textures (rgba8_unorm, no depth) - the scene, and the two
    // ping-pong blur buffers.
    const rt_scene: z.RenderTexture = z.loadRenderTexture(f.gl, rt_size, rt_size);
    const rt_a: z.RenderTexture = z.loadRenderTexture(f.gl, rt_size, rt_size);
    const rt_b: z.RenderTexture = z.loadRenderTexture(f.gl, rt_size, rt_size);

    // Bright pass: rt_scene -> rt_a. Keeps luminance above `thresh`.
    const bright: z.shader.LoadedShader(BrightSchema) = try z.shader.loadShaderVF(fullscreen_vs_io, bright_fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = fullscreen_vs_wgsl,
        .fs_wgsl_source = bright_fs_wgsl,
        .textures = .{ .src = rt_scene.asTexture() },
        .initial_ubo = .{ .params = .{ bright_thresh, 0, 0, 0 } },
        .color_format = .rgba8_unorm,
        .depth_state = .none,
        .label = "bloom_bright",
    });

    // Separable blur: TWO shaders sharing one FS, direction baked into each
    // one's UBO (so no mid-frame UBO update is needed). blur_h reads rt_a and
    // writes rt_b; blur_v reads rt_b and writes rt_a. Both source textures are
    // fixed, so the ping-pong is just the alternating render targets.
    const blur_h: z.shader.LoadedShader(BlurSchema) = try z.shader.loadShaderVF(fullscreen_vs_io, blur_fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = fullscreen_vs_wgsl,
        .fs_wgsl_source = blur_fs_wgsl,
        .textures = .{ .src = rt_a.asTexture() },
        .initial_ubo = .{ .dir = .{ blur_texel, 0, 0, 0 } },
        .color_format = .rgba8_unorm,
        .depth_state = .none,
        .label = "bloom_blur_h",
    });
    const blur_v: z.shader.LoadedShader(BlurSchema) = try z.shader.loadShaderVF(fullscreen_vs_io, blur_fs_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = fullscreen_vs_wgsl,
        .fs_wgsl_source = blur_fs_wgsl,
        .textures = .{ .src = rt_b.asTexture() },
        .initial_ubo = .{ .dir = .{ 0, blur_texel, 0, 0 } },
        .color_format = .rgba8_unorm,
        .depth_state = .none,
        .label = "bloom_blur_v",
    });

    // Composite: rt_scene + rt_a -> backbuffer. Two textures, bound by schema
    // field name. Targets the backbuffer, so no explicit color_format.
    const composite: z.shader.LoadedShader(CompositeSchema) =
        try z.shader.loadShaderVF(fullscreen_vs_io, composite_fs_io, .{
            .f = f.gpu,
            .gpa = gpa,
            .vs_wgsl_source = fullscreen_vs_wgsl,
            .fs_wgsl_source = composite_fs_wgsl,
            .textures = .{ .scene = rt_scene.asTexture(), .bloom = rt_a.asTexture() },
            .initial_ubo = .{ .params = .{ composite_intensity, 0, 0, 0 } },
            .depth_state = .none,
            .label = "bloom_composite",
        });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .rt_scene = rt_scene,
        .rt_a = rt_a,
        .rt_b = rt_b,
        .bright = bright,
        .blur_h = blur_h,
        .blur_v = blur_v,
        .composite = composite,
    };
}

/// Draw the glowing-orb scene into rt_scene. Each orb is a radial gradient
/// (bright core -> transparent edge) so it reads as a soft light source, with a
/// small white-hot centre that clears the bright-pass threshold cleanly. The
/// orbs orbit the centre and pulse in size/brightness.
fn drawScene(f: *z.Frame, s: *State) void {
    const bg: zm.Color = .{ .r = 4, .g = 5, .b = 10, .a = 255 };
    z.beginTextureMode(f.gl, s.rt_scene, bg);
    const cx: f32 = rt_sizef * 0.5;
    const cy: f32 = rt_sizef * 0.5;
    const half: f32 = rt_sizef * 0.5;
    const t: f32 = f.time.time;
    for (orbs) |orb| {
        const ang: f32 = orb.phase + t * orb.speed;
        const ox: f32 = cx + @cos(ang) * orb.orbit * half * 0.82;
        const oy: f32 = cy + @sin(ang) * orb.orbit * half * 0.82;
        // Pulse: 0.72..1.0 on size, 0.75..1.0 on brightness.
        const p: f32 = 0.5 + 0.5 * @sin(t * orb.pulse + orb.phase);
        const rad: f32 = orb.radius * (0.72 + 0.28 * p);
        const bright: f32 = 1.15 + 0.35 * p;
        const inner: zm.Color = colorScaled(orb.color, bright);
        const edge: zm.Color = .{ .r = inner.r, .g = inner.g, .b = inner.b, .a = 0 };
        // Soft coloured halo (large, faded) then the bright core, then a
        // white-hot centre that guarantees a clean threshold hit.
        f.gl.circleGradient(.{ ox, oy }, rad * 3.2, dim(inner, 0.9), edge);
        f.gl.circleGradient(.{ ox, oy }, rad, inner, edge);
        f.gl.circleGradient(.{ ox, oy }, rad * 0.75, whiteHot(bright), edge);
    }
    z.endTextureMode(f.gl);
}

/// A 0..1 float colour scaled by `k`, as an 8-bit Color (clamped).
fn colorScaled(c: Vec, k: f32) zm.Color {
    return .{
        .r = chan(c[0] * k),
        .g = chan(c[1] * k),
        .b = chan(c[2] * k),
        .a = 255,
    };
}

fn dim(c: zm.Color, k: f32) zm.Color {
    return .{
        .r = chan(cf(c.r) * k),
        .g = chan(cf(c.g) * k),
        .b = chan(cf(c.b) * k),
        .a = c.a,
    };
}

fn whiteHot(k: f32) zm.Color {
    const v: u8 = chan(k);
    return .{ .r = v, .g = v, .b = v, .a = 255 };
}

fn cf(v: u8) f32 {
    return float(v) / 255.0;
}

fn chan(v: f32) u8 {
    const clamped: f32 = clamp(v, 0.0, 1.0);
    return @trunc(clamped * 255.0);
}

fn update(f: *z.Frame, s: *State) void {
    const black: zm.Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };

    // Re-push the per-pass UBOs EVERY frame. Setting them only via `initial_ubo`
    // left them correct for exactly one frame, then they read as zero (intensity
    // 0 -> no bloom -> "bright for 1 frame then dark"). Pushing each frame keeps
    // threshold / intensity / blur direction live.
    s.bright.pushUbo(f.gpu.queue, .{ .params = .{ bright_thresh, 0, 0, 0 } });
    s.blur_h.pushUbo(f.gpu.queue, .{ .dir = .{ blur_texel, 0, 0, 0 } });
    s.blur_v.pushUbo(f.gpu.queue, .{ .dir = .{ 0, blur_texel, 0, 0 } });
    s.composite.pushUbo(f.gpu.queue, .{ .params = .{ composite_intensity, 0, 0, 0 } });

    // 1) Scene: the glowing orbs -> rt_scene.
    drawScene(f, s);

    // 2) Bright-pass: rt_scene -> rt_a.
    z.beginTextureMode(f.gl, s.rt_a, black);
    z.drawFullscreenShader(f.gl, BrightSchema, &s.bright);
    z.endTextureMode(f.gl);

    // 3) Separable blur, ping-ponging rt_a <-> rt_b.
    var iter: usize = 0;
    while (iter < blur_iters) : (iter += 1) {
        z.beginTextureMode(f.gl, s.rt_b, black);
        z.drawFullscreenShader(f.gl, BlurSchema, &s.blur_h);
        z.endTextureMode(f.gl);
        z.beginTextureMode(f.gl, s.rt_a, black);
        z.drawFullscreenShader(f.gl, BlurSchema, &s.blur_v);
        z.endTextureMode(f.gl);
    }

    // ---- SCREEN PASS: open once, composite to the backbuffer + caption. ----
    z.beginDrawing(f.gl);

    // 4) Composite scene + blurred highlights -> backbuffer.
    z.drawFullscreenShader(f.gl, CompositeSchema, &s.composite);

    common.caption(f.gl, s.font, "pipeline_bloom: glowing orbs -> bright -> separable blur -> composite (typed)");
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    // Transient GPU-technique demo: pipeline setup creates layouts and shader
    // modules that aren't retained in State, so a leak-tight deinit isn't
    // practical. Opt out of the managed leak gate rather than fake teardown.
    .memory = .managed,
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - pipeline bloom",
            .width = 800,
            .height = 600,
            .scale_mode = .responsive,
            .clear = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
        },
    },
    .init = initState,
    // .memory left default (arena): init builds a compute pipeline / multi-pass
    // chain (mipmap or bloom) whose intermediate handles aren't kept in State,
    // so a full managed teardown needs added State fields - deferred.
    .deinit = deinit,
    .update = update,
    // Scene + bright + blur passes render offscreen before the screen opens
    // (tile-based-GPU safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
