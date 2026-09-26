// examples/mandel_sidebyside/mandel_sidebyside.zig
//
// THE HEADLINE: the SAME mandelbrot fragment shader running on the CPU and the
// GPU at the same time, on one zoomable view.
//   - LEFT of the (fixed, centered) divider: the mandelbrot_fs `shaderMain`
//     dispatched PER PIXEL on the CPU (raster_shader.dispatchFragmentShader) into
//     a LOW-RES software framebuffer (1/5 canvas res - chunky but fast), then
//     uploaded + blitted.
//   - RIGHT of the divider: the EXACT SAME `shaderMain`, compiled to WGSL, run
//     as a full-resolution GPU fullscreen pass.
//
// One shader. One iteration loop. Two execution targets, side by side. Pan by
// dragging, zoom with the mouse wheel or a two-finger pinch - both halves track
// the same (center, zoom) because they share one UBO.
//
// Build:      zig build wgpu-mandel-sidebyside
// Standalone: zig build wgpu-mandel-sidebyside-standalone

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const float = zm.float;
const Vec2i = zm.Vec2i;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;

const shader = @import("mandelbrot_fs.zig");
const shader_io = @import("mandelbrot_fs_io.zig");
const trivial_vs_io = @import("trivial_vs_io.zig");

// Route std.log to the on-page console (see zimr.std_options).

const fs_wgsl = @embedFile("mandelbrot_fs.wgsl");
const trivial_vs_wgsl = @embedFile("trivial_vs.wgsl");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const width: u32 = 960;
const height: u32 = 600;

// Software side: 1/5 resolution. The CPU mandelbrot is expensive (width*height*max_iter
// per frame, single wasm thread), so we render it small and upscale - the
// chunky result is the whole point of the comparison.
// sw_w/sw_h are the INITIAL dims; `ensureCpuTarget` reshapes the buffer to
// the live canvas aspect each frame at this constant pixel budget.
const sw_w: u32 = width / 5;
const sw_h: u32 = height / 5;

const max_iter: f32 = 100;
const zoom_step: f32 = 1.15;
const initial_center: Vec2 = .{ -0.5, 0.0 };
const initial_zoom: f32 = 1.0;

// ---- Comptime corner: the SAME shaderMain, run by the Zig COMPILER ----------
// A third execution target alongside CPU (raster) and GPU (WGSL). The fractal here
// is evaluated PER PIXEL at COMPILE TIME and baked into the binary as a const;
// runtime just blits it. It uses the INITIAL view + resolution, so on load all
// three renders are identical. It cannot pan - it is literally a const in the
// read-only data section. One shader source. Three execution targets.
const corner_cols: usize = 64;
const corner_rows: usize = 40;
const corner_iter: f32 = 48; // lower cap keeps the comptime budget sane

const corner_image: [corner_rows * corner_cols]Color = blk: {
    @setEvalBranchQuota(2_000_000_000);
    const ubo: shader_io.Ubo = .{
        .center = initial_center,
        .zoom = initial_zoom,
        .resolution = .{ @floatFromInt(width), @floatFromInt(height) },
        .max_iter = corner_iter,
    };
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
            const out: shader.Out = shader.shaderMain(io);
            img[py * corner_cols + px] = Color.fromFloats(out.out_color[0], out.out_color[1], out.out_color[2], 1.0);
        }
    }
    break :blk img;
};

/// Raw RGBA8 view of the corner - uploaded ONCE to a small texture and
/// drawn as a single quad instead of a 2560-rect grid (the helmet's
/// rect-grid version of this was the difference between 60 and 16 fps).
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

// No field defaults: initState constructs and returns a fully-specified State
// (zimr_app.run takes initState by value-return, so a missing field is a
// compile error - the "uninitialized/default-ignored" class can't happen).
const State = struct {
    gpu_shader: z.shader.LoadedShader(shader_io),
    sw: z.raster.Context,
    sw_fb: z.CpuFramebuffer,

    // View (shared by both halves via the UBO).
    center: Vec2,
    zoom: f32,

    // Drag-pan bookkeeping; pinch-zoom now rides the shared gesture detector.
    dragging: bool,
    drag_anchor_world: Vec2,
    gestures: z.GesturesState,
    ui_host: z.UiHost,
    gpa: Allocator,
    font: z.Font,
    max_iter: f32,
    /// Splitter as a width FRACTION (rotation-stable); follows the pointer.
    divider_frac: f32,
    last_mouse: Vec2,
    /// The comptime-baked corner, uploaded once at init.
    corner_fb: z.CpuFramebuffer,
    ui_capturing: bool,
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
        .label = "mandel_sbs_gpu",
    });
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    var sw: z.raster.Context = try z.raster.Context.init(gpa, @intCast(sw_w), @intCast(sw_h));
    const sw_fb: z.CpuFramebuffer = z.CpuFramebuffer.init(
        f.gpu.device,
        f.gpu.queue,
        sw_w,
        sw_h,
        sw.colorBufferBytes(),
        "mandel_sbs_sw",
    );
    // Every field set explicitly - no defaults to silently drop.
    s.* = .{
        .gpu_shader = gpu_shader,
        .sw = sw,
        .sw_fb = sw_fb,
        .center = initial_center,
        .zoom = initial_zoom,
        .dragging = false,
        .drag_anchor_world = .{ 0, 0 },
        .gestures = .{},
        .ui_host = z.UiHost.init(gpa, font),
        .gpa = gpa,
        .font = font,
        .max_iter = max_iter,
        .ui_capturing = false,
        .divider_frac = 0.5,
        .last_mouse = .{ -1, -1 },
        .corner_fb = z.CpuFramebuffer.init(
            f.gpu.device,
            f.gpu.queue,
            corner_cols,
            corner_rows,
            &corner_bytes,
            "mandel_sbs_corner",
        ),
    };
}

/// Map a screen pixel (logical px) to a complex-plane point for the CURRENT
/// view - the inverse of the shader's pixel->complex mapping. Used to keep the
/// world point under the cursor/pinch-midpoint fixed across zoom.
fn screenToComplex(
    p: Vec2,
    sw_f: f32,
    sh_f: f32,
    center: Vec2,
    zoom: f32,
) Vec2 {
    const scale: f32 = 4.0 / (zoom * sh_f);
    // Match the SHADER's pixel->complex mapping. The shader uses
    // frag_tex_coord.y, which is now v=1 at screen-TOP, 0 at screen-BOTTOM
    // (the unified CPU/GPU convention). So a screen pixel p.y (Y-down: 0=top)
    // corresponds to frag.y = (1 - p.y/sh_f), and the shader computes
    //   c.y = center.y - (frag.y*resH - halfH) * scale.
    // Substituting frag.y = 1 - p.y/sh_f gives c.y = center.y + (p.y - half)*scale
    // - i.e. the Y term is PLUS here (the shader's own flip already accounts for
    // screen-down). Getting this wrong inverts pan; it must mirror the shader.
    return .{
        center[0] + (p[0] - 0.5 * sw_f) * scale,
        center[1] + (p[1] - 0.5 * sh_f) * scale,
    };
}

fn handleInput(f: *z.Frame, s: *State) void {
    const sw_f: f32 = f.window.widthf();
    const sh_f: f32 = f.window.heightf();
    const mouse: Vec2 = z.getMousePosition(f.input);

    // Tick the shared gesture detector once per frame.
    z.updateGestures(&s.gestures, f.input, f.time);

    // ---- Two-finger pinch via the shared detector: `scale` = distance ratio
    // (zoom), `mid` = focal point to hold fixed, `mid_delta` = pan-while-pinch.
    const touch_count: i32 = z.getTouchPointCount(f.input);
    if (touch_count >= 2) {
        const scale: f32 = z.getGesturePinchScale(&s.gestures);
        const mid: Vec2 = z.getGesturePinchMid(&s.gestures);
        s.dragging = false; // pinch wins over drag
        // scale is 1.0 on the first two-finger frame (no baseline yet) - skip.
        if (scale > 0 and scale != 1.0) {
            // Zoom about the midpoint: keep the world point under `mid` fixed.
            const world_before: Vec2 = screenToComplex(mid, sw_f, sh_f, s.center, s.zoom);
            s.zoom *= scale;
            if (s.zoom < initial_zoom * 0.5) {
                s.zoom = initial_zoom * 0.5;
            }
            const world_after: Vec2 = screenToComplex(mid, sw_f, sh_f, s.center, s.zoom);
            s.center += world_before - world_after;
            // Pan by the midpoint's screen motion (in world units).
            const md: Vec2 = z.getGesturePinchMidDelta(&s.gestures);
            const sc: f32 = 4.0 / (s.zoom * sh_f);
            s.center[0] -= md[0] * sc;
            s.center[1] -= md[1] * sc;
        }
        return;
    }

    // ---- Drag to pan --------------------------------------------------------
    const pressed: bool = z.isMouseButtonDown(f.input, .left);
    if (pressed and !s.dragging) {
        s.dragging = true;
        s.drag_anchor_world = screenToComplex(mouse, sw_f, sh_f, s.center, s.zoom);
    }
    if (!pressed) {
        s.dragging = false;
    }
    if (s.dragging and pressed) {
        const scale: f32 = 4.0 / (s.zoom * sh_f);
        const off: Vec2 = .{ mouse[0] - 0.5 * sw_f, mouse[1] - 0.5 * sh_f };
        // Keep the world point grabbed at press (drag_anchor_world) under the
        // cursor: center = anchor - offset*scale on BOTH axes. (Both axes use
        // the same sign now that screenToComplex's Y term is +, matching the
        // shader. X and Y symmetric - if they differ, one axis pans backwards.)
        s.center = .{
            s.drag_anchor_world[0] - off[0] * scale,
            s.drag_anchor_world[1] - off[1] * scale,
        };
    }

    // ---- Wheel to zoom (about the cursor) -----------------------------------
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        const world_before: Vec2 = screenToComplex(mouse, sw_f, sh_f, s.center, s.zoom);
        s.zoom *= if (wheel > 0) zoom_step else 1.0 / zoom_step;
        if (s.zoom < initial_zoom * 0.5) {
            s.zoom = initial_zoom * 0.5;
        }
        const world_after: Vec2 = screenToComplex(mouse, sw_f, sh_f, s.center, s.zoom);
        s.center += world_before - world_after;
        if (s.dragging) {
            s.drag_anchor_world = screenToComplex(mouse, sw_f, sh_f, s.center, s.zoom);
        }
    }
}

// The control-panel rectangle (logical px). Shared by the input gate and the
// UI draw so they agree on the touch area.
const panel_x: f32 = 14;
const panel_y: f32 = 14;
const panel_w: f32 = 300;
const panel_h: f32 = 188;

fn mouseOverPanel(f: *z.Frame) bool {
    const m: Vec2 = z.getMousePosition(f.input);
    return m[0] >= panel_x and m[0] <= panel_x + panel_w and
        m[1] >= panel_y and m[1] <= panel_y + panel_h;
}

fn update(f: *z.Frame, s: *State) void {
    // Gate scene pan/zoom: if the pointer is over the UI panel (or a drag
    // started there), the UI owns the input. (Fixes "moving the slider pans the
    // fractal".)
    if (mouseOverPanel(f) or s.ui_capturing) {
        s.ui_capturing = z.isMouseButtonDown(f.input, .left);
        s.dragging = false;
    } else {
        handleInput(f, s);
    }

    // The app's coordinate space is f.window.screen_width/height (the contract;
    // see wgpu_app cssToLogical). In .responsive that's the LIVE size, which may
    // differ from width/height - so read it live, never hardcode. Both halves + the
    // shader resolution use this same size.
    const vw: f32 = f.window.widthf();
    const vh: f32 = f.window.heightf();

    // The shared UBO: both the CPU dispatch and the GPU pass read this, so the
    // two halves render the SAME view. resolution = the live logical size.
    const ubo: shader_io.Ubo = .{
        .center = s.center,
        .zoom = s.zoom,
        .resolution = .{ vw, vh },
        .max_iter = s.max_iter,
    };

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
    // Commit the GPU pass before touching textured 2D.
    f.gl.flushBeforeMaterialSwap();

    // ---- Composite: software (CPU) over the LEFT of the splitter.  The
    //      divider is a width FRACTION (rotation-stable) that follows the
    //      pointer - helmet mechanics (t1168) - except while the UI owns
    //      the mouse (panel drags must not sweep the split).
    const m_div: Vec2 = z.getMousePosition(f.input);
    const is_first_zero: bool = s.last_mouse[0] < 0 and m_div[0] == 0 and m_div[1] == 0;
    const ui_owns: bool = s.ui_capturing or mouseOverPanel(f);
    if (!ui_owns and !is_first_zero and (m_div[0] != s.last_mouse[0] or m_div[1] != s.last_mouse[1])) {
        s.last_mouse = m_div;
        s.divider_frac = clamp(m_div[0] / vw, 0.0, 1.0);
    }
    const divider_x: f32 = s.divider_frac * vw;
    z.beginScissorMode(f.gl, 0, 0, divider_x, vh);
    s.sw_fb.present(f.gl, 0, 0, vw, vh);
    z.endScissorMode(f.gl);

    // Divider bar.
    f.gl.rect(
        .{ .x = divider_x - 1.5, .y = 0, .width = 3, .height = vh },
        .{ .color = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );

    // ---- UI control panel (immediate-mode, drawn via the same gl) -----------
    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    if (ui.window("Mandelbrot", .{ .initial_pos = .{ panel_x, panel_y }, .initial_size = .{ panel_w, panel_h } })) |w| {
        defer w.close();
        ui.text("ONE shader, 3 targets:", .{});
        ui.text("CPU (left) | GPU (right) | comptime (corner)", .{});
        _ = ui.slider("max iterations", &s.max_iter, .{ .min = 20, .max = 300 });
        if (ui.button("reset view", .{})) {
            s.center = initial_center;
            s.zoom = initial_zoom;
        }
    }
    s.ui_host.render(f);

    // ---- Labels + comptime corner inset (bottom-right): the third target ----
    f.gl.text(
        .{ 16, 14 },
        "CPU mandel_fs",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ vw - 156, 14 },
        "GPU mandel_fs",
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
        "comptime mandel_fs",
        .{ .size = 16, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Mandelbrot: CPU shader | GPU shader",
            .width = width,
            .height = height,
            // responsive: CSS px == design px, so mouse AND touch coords are in
            // the same space the pan/zoom math expects (no .fit inverse gap).
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
