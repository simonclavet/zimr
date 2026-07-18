// examples/sidebyside/sidebyside.zig
//
// THE FLAGSHIP: the same scene rendered two ways at once.
//   - LEFT of the divider:  a LOW-RES software rasterizer (raster) running
//     entirely on the CPU (wasm), its pixel buffer uploaded to the GPU and
//     blitted to screen.
//   - RIGHT of the divider: the SAME scene drawn at FULL resolution by the
//     WebGPU backend (WgpuGl).
//   - A vertical splitter follows the mouse X.
//
// The whole point: the scene-drawing code is written ONCE as `fn(gl: anytype)`
// and runs unchanged on both backends — raster (software) and WgpuGl (GPU) both
// satisfy the same renderer trait (gl_iface). Move the splitter and you're
// looking at the exact same geometry, software on one side and hardware on the
// other, pixel-for-pixel.
//
// Build:      zig build wgpu-sidebyside
// Standalone: zig build wgpu-sidebyside-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;

// Fixed-function shader pair used by the CPU side's `ff_triangle` bridge
// (`ffBridge` below): the immediate-mode triangles render through this
// exact pair on `raster_shader.rasterizeTriangles` — the same shader the GPU
// side runs — so the two halves match through one rasteriser, no drift.
const ff_vs = z.default_shapes.vs;
const ff_fs = z.default_shapes.fs;
const clamp = zm.clamp;
const float = zm.float;
const int = zm.int;

// Full-canvas logical size (the GPU side renders at this; the design space).
const width: u32 = 960;
const height: u32 = 600;

// The software side renders at a LOWER resolution (this is the visible point of
// the comparison — software is cheaper at low res, hardware is crisp at full
// res). Upscaled with nearest filtering so the chunky pixels read clearly.
const sw_w: u32 = width / 3;
const sw_h: u32 = height / 3;

const State = struct {
    // The software rasterizer + its CPU→GPU framebuffer bridge.
    sw: z.raster.Context,
    sw_fb: z.CpuFramebuffer,

    // Divider X in design pixels; follows the mouse.
    divider_x: f32,

    t: f32,
};

fn deinit(gpa: Allocator, s: *State) void {
    s.sw.deinit(gpa);
    s.sw_fb.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var sw: z.raster.Context = try z.raster.Context.init(gpa, @intCast(sw_w), @intCast(sw_h));
    const sw_fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        sw_w,
        sw_h,
        sw.colorBufferBytes(),
        "sidebyside_sw",
    );
    s.* = .{
        .sw = sw,
        .sw_fb = sw_fb,
        .divider_x = float(width) * 0.5,
        .t = 0,
    };
}

/// Fixed-function `ff_triangle` hook (Phase 2 — one rasteriser): route
/// each immediate-mode triangle of the CPU side through the SAME
/// `default_shapes` pair + `raster_shader.rasterizeTriangles` the GPU side
/// runs.  raster has already transformed the positions to clip space, so
/// the VS is bypassed and `Out` is built directly (preserving the full
/// vec4).  This 2D scene is untextured (a white 1×1 → `frag_color` flows
/// straight through) with no depth and no cull; only blend varies, and it
/// follows the context so the alpha discs composite exactly as the
/// fixed-function `triangleKernel` path did.
fn ffBridge(
    ctx_opaque: *anyopaque,
    v0: *const z.raster.Vertex,
    v1: *const z.raster.Vertex,
    v2: *const z.raster.Vertex,
) void {
    const ctx: *z.raster.Context = @ptrCast(@alignCast(ctx_opaque));
    const vs_outs: [3]ff_vs.Out = .{
        .{ .position = v0.position, .frag_tex_coord = v0.texcoord, .frag_color = v0.color },
        .{ .position = v1.position, .frag_tex_coord = v1.texcoord, .frag_color = v1.color },
        .{ .position = v2.position, .frag_tex_coord = v2.texcoord, .frag_color = v2.color },
    };
    const idx: [3]u32 = .{ 0, 1, 2 };
    const white_px: [4]u8 = .{ 255, 255, 255, 255 };
    const base_io: ff_fs.Io = .{
        .frag_tex_coord = .{ 0, 0 },
        .frag_color = .{ 1, 1, 1, 1 },
        ._texture0 = .{ .pixels = &white_px, .width = 1, .height = 1 },
    };
    const connect: fn (ff_vs.Out, *ff_fs.Io) void = z.autoConnect(ff_vs.Out, ff_fs.Io);
    // This 2D scene has no depth and no cull; only blend varies (the
    // alpha discs).  Route through the shared runtime-opts core so the
    // composite matches the fixed-function path exactly — no opts logic
    // duplicated here.
    z.raster_shader.rasterizeWithRuntimeOpts(
        ff_vs,
        ff_fs,
        ctx,
        &vs_outs,
        &idx,
        base_io,
        connect,
        false,
        ctx.blendEnabled(),
        false,
    );
}

/// Tiny HSV→RGB (h,s,v in 0..1) for cheerful palette cycling.
fn hsv(h: f32, s: f32, v: f32) [3]u8 {
    const i: f32 = @floor(h * 6.0);
    const f: f32 = h * 6.0 - i;
    const p: f32 = v * (1.0 - s);
    const q: f32 = v * (1.0 - f * s);
    const tt: f32 = v * (1.0 - (1.0 - f) * s);
    const seg: i32 = @mod(int(i32, i), 6);
    const rgb: [3]f32 = switch (seg) {
        0 => .{ v, tt, p },
        1 => .{ q, v, p },
        2 => .{ p, v, tt },
        3 => .{ p, q, v },
        4 => .{ tt, p, v },
        else => .{ v, p, q },
    };
    return .{
        int(u8, rgb[0] * 255.0),
        int(u8, rgb[1] * 255.0),
        int(u8, rgb[2] * 255.0),
    };
}

/// Filled circle via a triangle fan — works on any `gl: anytype`.
fn fillCircle(
    gl: anytype,
    cx: f32,
    cy: f32,
    r: f32,
    cr: u8,
    cg: u8,
    cb: u8,
    ca: u8,
) void {
    const segs: u32 = 24;
    gl.color4ub(cr, cg, cb, ca);
    gl.begin(.triangles);
    var i: u32 = 0;
    while (i < segs) : (i += 1) {
        const a0: f32 = float(i) * (std.math.tau / float(segs));
        const a1: f32 = float(i + 1) * (std.math.tau / float(segs));
        gl.vertex2f(cx, cy);
        gl.vertex2f(cx + r * @cos(a0), cy + r * @sin(a0));
        gl.vertex2f(cx + r * @cos(a1), cy + r * @sin(a1));
    }
    gl.end();
}

fn drawScene(gl: anytype, t: f32) void {
    gl.clearColor(.{ .r = 12, .g = 14, .b = 22, .a = 255 });
    gl.clear(.{ .color = true });

    // Top-left 2D ortho over the full design space; both sides share it.
    gl.matrixMode(.projection);
    gl.loadIdentity();
    gl.ortho(0, float(width), float(height), 0, -1, 1);
    gl.matrixMode(.modelview);
    gl.loadIdentity();
    gl.enable(.blend);

    const cx: f32 = float(width) * 0.5;
    const cy: f32 = float(height) * 0.5;

    // A ring of orbiting discs, each pulsing — drawn as filled triangle fans.
    const n_orbit: u32 = 10;
    var i: u32 = 0;
    while (i < n_orbit) : (i += 1) {
        const fi: f32 = float(i);
        const ang: f32 = t * 0.5 + fi * (std.math.tau / float(n_orbit));
        const orbit_r: f32 = 180.0 + 40.0 * @sin(t + fi);
        const px: f32 = cx + orbit_r * @cos(ang);
        const py: f32 = cy + orbit_r * @sin(ang);
        const rad: f32 = 18.0 + 10.0 * @sin(t * 2.0 + fi * 1.3);
        const hue: f32 = fi / float(n_orbit);
        const col: [3]u8 = hsv(hue, 0.7, 1.0);
        fillCircle(gl, px, py, rad, col[0], col[1], col[2], 255);
    }

    // A rotating filled polygon in the center.
    const sides: u32 = 6;
    const poly_r: f32 = 90.0 + 20.0 * @sin(t * 1.3);
    gl.color4ub(90, 130, 240, 230);
    gl.begin(.triangles);
    var k: u32 = 0;
    while (k < sides) : (k += 1) {
        const a0: f32 = t * 0.8 + float(k) * (std.math.tau / float(sides));
        const a1: f32 = t * 0.8 + float(k + 1) * (std.math.tau / float(sides));
        gl.vertex2f(cx, cy);
        gl.vertex2f(cx + poly_r * @cos(a0), cy + poly_r * @sin(a0));
        gl.vertex2f(cx + poly_r * @cos(a1), cy + poly_r * @sin(a1));
    }
    gl.end();

    gl.disable(.blend);
}

fn update(f: *z.Frame, s: *State) void {
    s.t = f.time.time;

    // Splitter follows the mouse X (design pixels), clamped to the canvas.
    const mouse: Vec2 = z.getMousePosition(f.input);
    s.divider_x = clamp(mouse[0], 0, float(width));

    // ---- SOFTWARE SIDE: run the scene on the raster rasterizer (CPU) ----------
    // Same drawScene, but `gl` is the raster adapter. Renders into the CPU
    // framebuffer at low res, which we upload + blit on the left.
    {
        s.sw.ff_triangle = ffBridge;
        var sw_gl: z.SwGl = z.SwGl.init(&s.sw);
        drawScene(&sw_gl, s.t);
        s.sw_fb.update(f.gpu.queue, s.sw.colorBufferBytes());
    }

    // ---- GPU SIDE: run the SAME scene on WgpuGl, full resolution ------------
    drawScene(f.gl, s.t);
    // Commit the GPU scene NOW — before the blit binds the framebuffer texture.
    // (The shapes batch defers draws; if we let the scene stay staged until the
    // blit's bindTexture swaps the material bind group, the scene's draw would
    // sample the framebuffer instead of its vertex colors → a black right half.)
    f.gl.flushBeforeMaterialSwap();

    // Composite the software image over the LEFT of the divider.
    const w_f: f32 = float(width);
    const h_f: f32 = float(height);
    if (s.divider_x > 0) {
        z.beginScissorMode(f.gl, 0, 0, s.divider_x, h_f);
        s.sw_fb.present(f.gl, 0, 0, w_f, h_f);
        z.endScissorMode(f.gl);
    }

    // The divider bar.
    f.gl.rect(
        .{ .x = s.divider_x - 1.5, .y = 0, .width = 3, .height = h_f },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );

    z.endDrawing(f.gl);
}

// ---- The shared scene: written ONCE, runs on raster AND WgpuGl ---------------
// `gl: anytype` — the only requirement is that gl satisfies the renderer trait.
// A 2D scene (no depth buffer needed): a field of orbiting, pulsing rings +
// a rotating polygon. Identical geometry on both backends; across the splitter
// you see the SAME shapes, software-rasterized (chunky) on the left and
// GPU-rasterized (crisp) on the right.

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - CPU | GPU side-by-side",
            .width = width,
            .height = height,
            .scale_mode = .fit,
            // No window depth attachment: the WgpuGl path draws everything
            // through the 2D "shapes" pipeline, which has no depth-stencil state
            // — a depth attachment on the pass would mismatch it (GPU
            // validation error). The cube's gl.enable(.depth_test) is a no-op on
            // the GPU side; faces are drawn in array order. (A future depth-aware
            // WgpuGl 3D path can re-enable this.)
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
