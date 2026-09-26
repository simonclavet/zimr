//! shadow_sidebyside - the rayshadow_fs hard-shadow scene on THREE execution
//! targets, side by side from ONE Zig shader:
//!   - LEFT  : `rayshadow_fs.shaderMain` dispatched per pixel on the CPU (raster).
//!   - RIGHT : the EXACT SAME shaderMain compiled to WGSL, run as a fullscreen
//!             GPU pass.
//!   - CORNER: the SAME shaderMain evaluated by the Zig COMPILER (comptime) and
//!             baked into the binary as a const image - read-only, can't move.
//! A vertical splitter follows the mouse X. Two boxes cast HARD SHADOWS on a
//! platform via a shadow ray (not a shadow map - a shadow map needs a depth
//! texture the comptime/CPU targets can't produce; a shadow ray is a plain
//! second ray-scene intersection, so it runs identically on all three). The
//! camera orbits (live CPU + GPU); the comptime corner is frozen at build time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;
const Vec2i = zm.Vec2i;
const Camera3D = zm.Camera3D;
const RayCamera = zm.RayCamera;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const vec = zm.vec;

const shader = @import("rayshadow_fs.zig");
const shader_io = @import("rayshadow_fs_io.zig");
const trivial_vs_io = @import("trivial_vs_io.zig");

const fs_wgsl = @embedFile("rayshadow_fs.wgsl");
const trivial_vs_wgsl = @embedFile("trivial_vs.wgsl");

const width: u32 = 800;
const height: u32 = 450;

// CPU side res - a handful of ray-primitive tests per pixel, so 1/3 is fine.
const sw_w: u32 = width / 3;
const sw_h: u32 = height / 3;
const cpu_pixel_budget: f32 = float(sw_w * sw_h);

// Comptime corner: the scene is deterministic (no sampling), so one pass.
const corner_cols: usize = 56;
const corner_rows: usize = 32;
const corner_yaw: f32 = 0.7;
const corner_pitch: f32 = 0.5; // a 3/4 view looking down onto the shadows

const cam_target: Vec = vec(0, 0.45, 0);
const cam_dist: f32 = 5.6; // fixed orbit radius

/// Build the scene UBO. Orbit the camera around the (fixed) scene in spherical
/// coords - eye = target + (yaw, pitch, dist). The CPU dispatch, the GPU pass,
/// and the comptime bake all read this same camera basis.
fn buildUbo(
    yaw: f32,
    pitch: f32,
    dist: f32,
    res_w: f32,
    res_h: f32,
) shader_io.Ubo {
    const cp: f32 = @cos(pitch);
    const eye: Vec = vec(
        cam_target[0] + dist * cp * @sin(yaw),
        cam_target[1] + dist * @sin(pitch),
        cam_target[2] + dist * cp * @cos(yaw),
    );
    const cam3d: Camera3D = .{ .position = eye, .target = cam_target, .fovy_deg = 45.0 };
    const cam: RayCamera = cam3d.rayBasis(res_w, res_h);
    return .{
        .cam_origin = cam.origin,
        .px00 = cam.px00,
        .pdu = cam.pdu,
        .pdv = cam.pdv,
        .resolution = .{ res_w, res_h },
    };
}

// ---- Comptime corner: the SAME shaderMain, run by the Zig COMPILER ----------
const corner_image: [corner_rows * corner_cols]Color = blk: {
    @setEvalBranchQuota(2_000_000_000);
    const ubo: shader_io.Ubo = buildUbo(
        corner_yaw,
        corner_pitch,
        cam_dist,
        @floatFromInt(width),
        @floatFromInt(height),
    );
    var img: [corner_rows * corner_cols]Color = undefined;
    var py: usize = 0;
    while (py < corner_rows) : (py += 1) {
        var px: usize = 0;
        while (px < corner_cols) : (px += 1) {
            const io: shader.Io = .{
                .frag_tex_coord = .{
                    (float(px) + 0.5) / float(corner_cols),
                    // frag.y=1 is screen-TOP (unified CPU/GPU convention).
                    1.0 - (float(py) + 0.5) / float(corner_rows),
                },
                .u = ubo,
            };
            const c: Vec = shader.shaderMain(io).out_color;
            img[py * corner_cols + px] = Color.fromFloats(c[0], c[1], c[2], 1.0);
        }
    }
    break :blk img;
};

const State = struct {
    gpu_shader: z.shader.LoadedShader(shader_io),
    sw: z.raster.Context,
    sw_fb: z.CpuFramebuffer,
    font: z.Font,
    gpa: Allocator,
    cam_yaw: f32,
    cam_pitch: f32,
    cam_dist: f32,
    dragging: bool,
    prev_pinch_dist: f32,
    /// Splitter as a width FRACTION (rotation-stable); follows the pointer.
    divider_frac: f32,
    last_mouse: Vec2,
    /// The comptime-baked corner, uploaded once at init.
    corner_fb: z.CpuFramebuffer,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.sw.deinit(gpa);
    s.gpu_shader.deinit();
    s.sw_fb.deinit();
    s.corner_fb.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const gpu_shader: z.shader.LoadedShader(shader_io) = try z.shader.loadShaderVF(trivial_vs_io, shader_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = trivial_vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .label = "rayshadow_sbs_gpu",
    });
    var sw: z.raster.Context = try z.raster.Context.init(gpa, @intCast(sw_w), @intCast(sw_h));
    const sw_fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        sw_w,
        sw_h,
        sw.colorBufferBytes(),
        "rayshadow_sbs_sw",
    );
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{
        .gpu_shader = gpu_shader,
        .sw = sw,
        .sw_fb = sw_fb,
        .font = font,
        .gpa = gpa,
        .cam_yaw = corner_yaw,
        .cam_pitch = corner_pitch,
        .cam_dist = cam_dist,
        .dragging = false,
        .prev_pinch_dist = 0,
        .divider_frac = 0.5,
        .last_mouse = .{ -1, -1 },
        .corner_fb = z.CpuFramebuffer.init(
            f.gpu.device,
            f.gpu.queue,
            corner_cols,
            corner_rows,
            std.mem.sliceAsBytes(&corner_image),
            "rayshadow_sbs_corner",
        ),
    };
}

/// Keep the CPU half at a CONSTANT pixel budget shaped to the live canvas
/// aspect: rotation never stretches the pixels and never changes the CPU cost.
fn ensureCpuTarget(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    const aspect: f32 = vw / vh;
    const want_w: i32 = @trunc(@max(@round(@sqrt(cpu_pixel_budget * aspect)), 16));
    const want_h: i32 = @trunc(@max(@round(float(want_w) / aspect), 16));
    const dims: Vec2i = s.sw.colorBufferDims();
    if (dims[0] != want_w or dims[1] != want_h) {
        s.sw.resize(s.gpa, want_w, want_h) catch return;
        s.sw_fb.resize(f.gl, @intCast(want_w), @intCast(want_h), s.sw.colorBufferBytes(), "sbs_sw");
    }
}

fn clampDist(s: *State) void {
    if (s.cam_dist < 3.0) {
        s.cam_dist = 3.0;
    }
    if (s.cam_dist > 14.0) {
        s.cam_dist = 14.0;
    }
}

/// Drag orbits the camera; wheel/pinch dolly. The `dragging` latch skips the
/// FIRST drag frame, so a touch doesn't pop the camera from a stale delta.
fn handleInput(f: *z.Frame, s: *State) void {
    const touch_count: i32 = z.getTouchPointCount(f.input);
    if (touch_count >= 2) {
        const t0: Vec2 = z.getTouchPosition(f.input, 0);
        const t1: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = t1[0] - t0[0];
        const dy: f32 = t1[1] - t0[1];
        const d: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch_dist < 1.0 or d < 1.0) {
            s.prev_pinch_dist = d;
        } else {
            s.cam_dist *= s.prev_pinch_dist / d;
            s.prev_pinch_dist = d;
            clampDist(s);
        }
        s.dragging = false;
        return;
    }
    s.prev_pinch_dist = 0;

    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist *= (1.0 - wheel * 0.1);
        clampDist(s);
    }

    if (z.isMouseButtonDown(f.input, .left)) {
        const d: Vec2 = z.getMouseDelta(f.input);
        if (s.dragging) {
            s.cam_yaw -= d[0] * 0.005;
            s.cam_pitch += d[1] * 0.005;
            if (s.cam_pitch > 1.4) {
                s.cam_pitch = 1.4;
            }
            if (s.cam_pitch < 0.05) {
                s.cam_pitch = 0.05;
            }
        }
        s.dragging = true;
    } else {
        s.dragging = false;
    }
}

fn update(f: *z.Frame, s: *State) void {
    ensureCpuTarget(f, s);
    const vw: f32 = f.window.widthf();
    const vh: f32 = f.window.heightf();

    handleInput(f, s);

    // Splitter: a width FRACTION (rotation-stable) that follows the pointer,
    // with a guard ignoring the pre-input (0,0) report.
    const m: Vec2 = z.getMousePosition(f.input);
    const is_first_zero: bool = s.last_mouse[0] < 0 and m[0] == 0 and m[1] == 0;
    if (!is_first_zero and (m[0] != s.last_mouse[0] or m[1] != s.last_mouse[1])) {
        s.last_mouse = m;
        s.divider_frac = clamp(m[0] / vw, 0.0, 1.0);
    }
    const divider_x: f32 = s.divider_frac * vw;

    // Shared UBO - both live halves read it, so they render the same view.
    const ubo: shader_io.Ubo = buildUbo(s.cam_yaw, s.cam_pitch, s.cam_dist, vw, vh);

    // ---- CPU side: dispatch the SAME shaderMain per pixel into raster ----
    s.sw.clearColor(.{ .r = 8, .g = 8, .b = 14, .a = 255 });
    s.sw.clear(.{ .color = true });
    const sw_dims: Vec2i = s.sw.colorBufferDims();
    const base_io: shader.Io = .{ .frag_tex_coord = undefined, .u = ubo };
    z.raster_shader.dispatchFragmentShader(&s.sw, shader, base_io, .{
        .x = 0,
        .y = 0,
        .w = @intCast(sw_dims[0]),
        .h = @intCast(sw_dims[1]),
    });
    s.sw_fb.update(f.gpu.queue, s.sw.colorBufferBytes());

    // ---- GPU side: the SAME shaderMain as a full-res fullscreen pass ----
    s.gpu_shader.pushUbo(f.gpu.queue, ubo);
    z.bindFullscreenShader(f.gl, shader_io, &s.gpu_shader);
    z.drawFullscreenTriangle(f.gl);
    f.gl.flushBeforeMaterialSwap();

    // ---- Composite: software (CPU) over the LEFT of the split ----
    z.beginScissorMode(f.gl, 0, 0, divider_x, vh);
    s.sw_fb.present(f.gl, 0, 0, vw, vh);
    z.endScissorMode(f.gl);
    f.gl.rect(
        .{ .x = divider_x - 1.5, .y = 0, .width = 3, .height = vh },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );

    // ---- Labels + the comptime corner inset (the third target) ----
    f.gl.text(
        .{ 16, 14 },
        "CPU rayshadow_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ vw - 188, 14 },
        "GPU rayshadow_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );

    const inset_w: f32 = clamp(@min(vw, vh) * 0.30, 84, 200);
    const inset_h: f32 = inset_w * float(corner_rows) / float(corner_cols);
    const ix: f32 = vw - inset_w - 12;
    const iy: f32 = vh - inset_h - 12;
    s.corner_fb.present(f.gl, ix, iy, inset_w, inset_h);
    f.gl.rect(
        .{ .x = ix - 1, .y = iy - 1, .width = inset_w + 2, .height = inset_h + 2 },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 }, .outline = 1.0 },
    );
    f.gl.text(
        .{ ix, iy - 22 },
        "comptime rayshadow_fs",
        .{ .size = 16, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - ray shadows CPU|GPU|comptime",
            .width = width,
            .height = height,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
