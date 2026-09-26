//! rt_sidebyside - the rt_fs path tracer on THREE execution targets, side
//! by side from ONE Zig shader:
//!   - LEFT  : `rt_fs.shaderMain` dispatched per pixel on the CPU (raster), 1/5 res.
//!   - RIGHT : the EXACT SAME shaderMain compiled to WGSL, run as a fullscreen
//!             GPU pass.
//!   - CORNER: the SAME shaderMain evaluated by the Zig COMPILER (comptime),
//!             accumulated over a few samples and baked into the binary as a
//!             const. It cannot move - it is literally read-only data.
//!
//! One path tracer. One scatter/PRNG. Three targets. The CPU + GPU halves render
//! live (1 sample/frame - watch the path-trace grain); the comptime corner is a
//! clean multi-sample average computed at build time.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2i = zm.Vec2i;
const Camera3D = zm.Camera3D;
const RayCamera = zm.RayCamera;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const float = zm.float;
const vec = zm.vec;
const vec4 = zm.vec4;

const shader = @import("rt_fs.zig");
const shader_io = @import("rt_fs_io.zig");
const trivial_vs_io = @import("trivial_vs_io.zig");

const fs_wgsl = @embedFile("rt_fs.wgsl");
const trivial_vs_wgsl = @embedFile("trivial_vs.wgsl");

const width: u32 = 800;
const height: u32 = 450;

// CPU side at 1/5 res - a per-pixel path trace on the CPU is expensive.
// sw_w/sw_h are the INITIAL dims; `ensureCpuTarget` reshapes the buffer to
// the live canvas aspect each frame at this constant pixel budget.
const sw_w: u32 = width / 5;
const sw_h: u32 = height / 5;
const cpu_pixel_budget: f32 = float(sw_w * sw_h);

// Comptime corner: small + few samples to keep the build budget sane.
const corner_cols: usize = 40;
const corner_rows: usize = 24;
const corner_samples: u32 = 4;

const panel_x: f32 = 14;
const panel_y: f32 = 14;
const panel_w: f32 = 340;
const panel_h: f32 = 140;

// Orbit camera: position derived from yaw/pitch/dist around a fixed target.
const cam_target: Vec = vec(0, 0.3, -1.0);
const initial_yaw: f32 = 0.0;
const initial_pitch: f32 = 0.0935; // matches the old eye (0, 0.6, 2.2)
const initial_dist: f32 = 3.214;

// Tuning for the shared `z.OrbitCamera`. Sensitivity + clamps reproduce the
// hand-rolled feel this example used to have (orbit 0.005 rad/px, dist 1.2..12).
const orbit_opts: z.OrbitOptions = .{
    .orbit_sensitivity = 0.005,
    .min_distance = 1.2,
    .max_distance = 12.0,
    .min_pitch = -1.5,
    .max_pitch = 1.5,
    .fovy_deg = 45.0,
};

/// Build the scene UBO: a Camera3D ray basis (orbit yaw/pitch/dist) + the
/// RTIOW-ish sphere scene. `frame_seed` varies the per-pixel sampling. The CPU
/// dispatch, the GPU pass, and the comptime bake all read this same data.
fn buildUbo(
    yaw: f32,
    pitch: f32,
    dist: f32,
    frame_seed: f32,
    res_w: f32,
    res_h: f32,
) shader_io.Ubo {
    const w_f: f32 = res_w;
    const h_f: f32 = res_h;

    const cp: f32 = @cos(pitch);
    const eye: Vec = vec(
        cam_target[0] + dist * cp * @sin(yaw),
        cam_target[1] + dist * @sin(pitch),
        cam_target[2] + dist * cp * @cos(yaw),
    );
    const cam3d: Camera3D = .{ .position = eye, .target = cam_target, .fovy_deg = 45.0 };
    const cam: RayCamera = cam3d.rayBasis(w_f, h_f);

    var ubo: shader_io.Ubo = .{
        .cam_origin = cam.origin,
        .px00 = cam.px00,
        .pdu = cam.pdu,
        .pdv = cam.pdv,
        .resolution = .{ w_f, h_f },
        .frame_seed = frame_seed,
        .sphere_count = 6,
        .sphere_geom = undefined,
        .sphere_albedo = undefined,
        .sphere_extra = undefined,
    };

    // geom = (cx,cy,cz,radius); albedo = (r,g,b,material 0=lambert/1=metal/2=glass);
    // extra = (param,..) - glass IOR / metal fuzz.
    ubo.sphere_geom = .{
        vec4(0, -100.5, -1, 100), // ground
        vec4(-0.9, 0.0, -1.0, 0.5), // glass
        vec4(0.0, 0.0, -1.0, 0.5), // teal lambertian
        vec4(0.9, 0.0, -1.0, 0.5), // gold metal
        vec4(-0.25, -0.32, -0.55, 0.18), // chrome mirror
        vec4(0.35, -0.38, -0.5, 0.12), // small pink
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
    };
    ubo.sphere_albedo = .{
        vec4(0.5, 0.55, 0.5, 0),
        vec4(1, 1, 1, 2),
        vec4(0.2, 0.55, 0.6, 0),
        vec4(0.8, 0.6, 0.2, 1),
        vec4(0.8, 0.8, 0.85, 1),
        vec4(0.85, 0.4, 0.45, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
    };
    ubo.sphere_extra = .{
        vec4(0, 0, 0, 0),
        vec4(1.5, 0, 0, 0), // glass IOR
        vec4(0, 0, 0, 0),
        vec4(0.18, 0, 0, 0), // gold fuzz
        vec4(0.0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
        vec4(0, 0, 0, 0),
    };
    return ubo;
}

// ---- Comptime corner: the SAME shaderMain, run by the Zig COMPILER ----------
// `corner_samples` rays per pixel are path-traced AT COMPILE TIME and averaged;
// the result is baked into the binary. Same scene/camera as the live halves.
const corner_image: [corner_rows * corner_cols]Color = blk: {
    @setEvalBranchQuota(2_000_000_000);
    const base: shader_io.Ubo = buildUbo(
        initial_yaw,
        initial_pitch,
        initial_dist,
        0,
        @floatFromInt(width),
        @floatFromInt(height),
    );
    var img: [corner_rows * corner_cols]Color = undefined;
    var py: usize = 0;
    while (py < corner_rows) : (py += 1) {
        var px: usize = 0;
        while (px < corner_cols) : (px += 1) {
            var acc: Vec = @splat(0.0);
            var sidx: u32 = 0;
            while (sidx < corner_samples) : (sidx += 1) {
                var ubo: shader_io.Ubo = base;
                ubo.frame_seed = @floatFromInt(sidx + 1);
                const io: shader.Io = .{
                    .frag_tex_coord = .{
                        (float(px) + 0.5) / float(corner_cols),
                        // frag.y=1 is screen-TOP (unified CPU/GPU convention).
                        1.0 - (float(py) + 0.5) / float(corner_rows),
                    },
                    .u = ubo,
                };
                acc += shader.shaderMain(io).out_color;
            }
            const inv: f32 = 1.0 / float(corner_samples);
            img[py * corner_cols + px] = Color.fromFloats(acc[0] * inv, acc[1] * inv, acc[2] * inv, 1.0);
        }
    }
    break :blk img;
};

/// Raw RGBA8 view of the corner - uploaded ONCE to a small texture and
/// drawn as a single quad (the 960-rect grid this replaces was measurable
/// per-frame cost; on the helmet's 2304-rect version it was 60->16 fps).
const corner_bytes: [corner_rows * corner_cols * 4]u8 = blk: {
    // Zig 1245 forbids @bitCast from a struct; read Color fields directly.
    @setEvalBranchQuota(corner_rows * corner_cols * 8 + 1000);
    var bytes: [corner_rows * corner_cols * 4]u8 = undefined;
    for (corner_image, 0..) |c, i| {
        bytes[i * 4 + 0] = c.r;
        bytes[i * 4 + 1] = c.g;
        bytes[i * 4 + 2] = c.b;
        bytes[i * 4 + 3] = c.a;
    }
    break :blk bytes;
};

const State = struct {
    gpu_shader: z.shader.LoadedShader(shader_io),
    sw: z.raster.Context,
    sw_fb: z.CpuFramebuffer,
    ui_host: z.UiHost,
    gpa: Allocator,
    font: z.Font,
    frame: u32,
    cam: z.OrbitCamera,
    ui_wanted_mouse: bool,
    /// Splitter as a width FRACTION (rotation-stable); follows the pointer.
    divider_frac: f32,
    last_mouse: Vec2,
    /// The comptime-baked corner, uploaded once at init.
    corner_fb: z.CpuFramebuffer,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.gpu_shader.deinit();
    s.sw.deinit(gpa);
    s.sw_fb.deinit();
    s.corner_fb.deinit();
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const gpu_shader: z.shader.LoadedShader(shader_io) = try z.shader.loadShaderVF(trivial_vs_io, shader_io, .{
        .f = f.gpu,
        .gpa = gpa,
        .vs_wgsl_source = trivial_vs_wgsl,
        .fs_wgsl_source = fs_wgsl,
        .label = "rt_sbs_gpu",
    });
    var sw: z.raster.Context = try z.raster.Context.init(gpa, @intCast(sw_w), @intCast(sw_h));
    const sw_fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        sw_w,
        sw_h,
        sw.colorBufferBytes(),
        "rt_sbs_sw",
    );
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 22);
    s.* = .{
        .gpu_shader = gpu_shader,
        .sw = sw,
        .sw_fb = sw_fb,
        .ui_host = z.UiHost.init(gpa, font),
        .gpa = gpa,
        .font = font,
        .frame = 0,
        .cam = blk: {
            var c: z.OrbitCamera = z.OrbitCamera.init(cam_target, initial_dist);
            c.yaw = initial_yaw;
            c.pitch = initial_pitch;
            break :blk c;
        },
        .ui_wanted_mouse = false,
        .divider_frac = 0.5,
        .last_mouse = .{ -1, -1 },
        .corner_fb = z.CpuFramebuffer.init(
            f.gpu.device,
            f.gpu.queue,
            corner_cols,
            corner_rows,
            &corner_bytes,
            "rt_sbs_corner",
        ),
    };
}

/// Keep the CPU half at a CONSTANT pixel budget shaped to the live canvas
/// aspect (the helmet recipe, t1168): rotation never stretches the pixels
/// and never changes the per-frame CPU cost.
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

fn update(f: *z.Frame, s: *State) void {
    s.frame +%= 1;
    ensureCpuTarget(f, s);
    const vw: f32 = f.window.widthf();
    const vh: f32 = f.window.heightf();

    // The one call that replaces this example's hand-rolled orbit/pinch/wheel
    // handler. It reads touch + mouse, skips the first drag frame (no pop), and
    // clamps distance/pitch. Gated on last frame's wantCaptureMouse (the windows
    // must be submitted first, which happens below) - one frame of latency is
    // fine, and OrbitCamera's own first-frame skip covers the resume.
    _ = s.cam.update(f, s.ui_wanted_mouse, orbit_opts);

    // The shared scene UBO - both halves read it, so they render the same view.
    // frame_seed varies per frame: the noise "dances" as it path-traces live.
    const ubo: shader_io.Ubo = buildUbo(s.cam.yaw, s.cam.pitch, s.cam.distance, float(s.frame), vw, vh);

    // ---- CPU side: dispatch the SAME shaderMain per pixel into raster ---------
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

    // ---- GPU side: the SAME shaderMain as a full-res fullscreen pass --------
    s.gpu_shader.pushUbo(f.gpu.queue, ubo);
    z.bindFullscreenShader(f.gl, shader_io, &s.gpu_shader);
    z.drawFullscreenTriangle(f.gl);
    f.gl.flushBeforeMaterialSwap();

    // ---- Composite: software (CPU) over the LEFT of the splitter.  The
    //      divider is a width FRACTION (rotation-stable) that follows the
    //      pointer - helmet mechanics (t1168) - except while the UI owns
    //      the mouse (dragging the panel must not sweep the split).
    const m: Vec2 = z.getMousePosition(f.input);
    const is_first_zero: bool = s.last_mouse[0] < 0 and m[0] == 0 and m[1] == 0;
    if (!s.ui_wanted_mouse and !is_first_zero and (m[0] != s.last_mouse[0] or m[1] != s.last_mouse[1])) {
        s.last_mouse = m;
        s.divider_frac = clamp(m[0] / vw, 0.0, 1.0);
    }
    const divider_x: f32 = s.divider_frac * vw;
    z.beginScissorMode(f.gl, 0, 0, divider_x, vh);
    s.sw_fb.present(f.gl, 0, 0, vw, vh);
    z.endScissorMode(f.gl);
    f.gl.rect(
        .{ .x = divider_x - 1.5, .y = 0, .width = 3, .height = vh },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );

    // ---- UI panel -----------------------------------------------------------
    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    if (ui.window("Ray tracer", .{ .initial_pos = .{ panel_x, panel_y }, .initial_size = .{ panel_w, panel_h } })) |w| {
        defer w.close();
        ui.text("3 targets, ONE shader:", .{});
        ui.text("CPU | GPU | comptime", .{});
        ui.text("drag: orbit, wheel: zoom", .{});
    }
    // Windows are submitted now, so wantCaptureMouse is valid - stash it for
    // next frame's scene-input gate (hovering a window OR an active drag).
    s.ui_wanted_mouse = ui.wantCaptureMouse();
    s.ui_host.render(f);

    // ---- Labels + comptime corner inset (bottom-right): the third target ----
    f.gl.text(
        .{ 16, 14 },
        "CPU rt_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ vw - 112, 14 },
        "GPU rt_fs",
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
        "comptime rt_fs",
        .{ .size = 16, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - ray tracer CPU|GPU",
            .width = width,
            .height = height,
            // responsive: CSS px == design px, so the GPU fullscreen pass, the
            // CPU present, and the UI scissor all share one coordinate space
            // (no .fit inverse gap - that broke the left-half height + UI clip).
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
