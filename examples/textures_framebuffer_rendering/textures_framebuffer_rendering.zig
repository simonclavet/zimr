//! textures_framebuffer_rendering - port of raylib's
//! `examples/textures/textures_framebuffer_rendering.c` (Jack Boakes, 2/4).
//!
//! The sample's subject is the RENDER TEXTURE itself: one world drawn twice, into
//! two framebuffers, composited side by side - plus a cropped ZOOM of one of them
//! sampled straight back out of its own framebuffer.
//!   * OBSERVER pane - the world, plus a wire prism showing exactly where the
//!     other camera is and what it can see (its frustum, unprojected).
//!   * SUBJECT pane - the same world through that camera.
//!   * The viewfinder - a `capture_px` square of the SUBJECT framebuffer, drawn
//!     magnified over the corner. That is one `gl.texture(dst, rt, .{ .source })`
//!     call: a sub-rectangle of a texture we rendered ourselves this same frame.
//!
//! WHERE THIS DEPARTS FROM RAYLIB (and why):
//!   * raylib drives the observer with WASD+mouse and the subject with
//!     CAMERA_ORBITAL. A phone has neither. Here BOTH cameras are `z.OrbitCamera`s
//!     and the pane you touch is the one you steer - drag the top pane to fly the
//!     observer, drag the bottom pane to AIM the subject and watch its green
//!     frustum swing round in the pane above. The pane is latched on press, so a
//!     drag that crosses the divider keeps steering the camera it started on.
//!   * The split follows the device: stacked on a portrait phone, side-by-side on
//!     a landscape screen. Each framebuffer is exactly its pane's size in BACKING
//!     pixels, so the 3D is never stretched and the zoom is never resampled twice.
//!   * raylib passes a NEGATIVE source height (`-texture.height`) everywhere here,
//!     because a GL render texture arrives upside down. zimr's do not, so the
//!     source rects are plain positive pixels - except the `mirror` toggle, which
//!     flips the viewfinder on purpose to show that the negative-extent rule works.
//!
//! Leak-clean (`.memory = .managed`): both render textures and the UI host are
//! freed in `deinit`, and the twice-lifecycle smoke census must come back FLAT.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Camera3D = zm.Camera3D;
const Color = zm.Color;
const Mat = zm.Mat;
const Vec = zm.Vec;
const float = zm.float;
const inverse = zm.inverse;
const length3 = zm.length3;
const mulMat = zm.mulMat;
const mulMatVec = zm.mulMatVec;
const perspectiveFovRh = zm.perspectiveFovRh;
const pi = zm.pi;
const pointVec = zm.pointVec;
const vec = zm.vec;
const vec4 = zm.vec4;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub var zimr_app: z.App = .{};

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    /// The camera we LOOK THROUGH in the bottom pane (and see drawn in the top).
    subject: z.OrbitCamera,
    /// The camera that watches the subject.
    observer: z.OrbitCamera,
    rt_observer: z.RenderTexture = .{},
    rt_subject: z.RenderTexture = .{},
    auto_orbit: bool = true,
    mirror: bool = false,
    capture_px: f32 = 128,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .subject = z.OrbitCamera.init(pointVec(0, 0, 0), 8.0),
        .observer = z.OrbitCamera.init(pointVec(0, 0, 0), 18.0),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.rt_observer.deinit();
    s.rt_subject.deinit();
    s.ui_host.deinit();
}

/// Both framebuffers are one pane in BACKING pixels - half the surface on the
/// split axis, full on the other. Recreated only when that size actually
/// changes (rotation, resize), never per frame.
fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const portrait: bool = backing.height >= backing.width;
    const w: u32 = if (portrait) @max(backing.width, 1) else @max(backing.width / 2, 1);
    const h: u32 = if (portrait) @max(backing.height / 2, 1) else @max(backing.height, 1);
    if (s.rt_observer.color != .invalid and s.rt_observer.width == w and s.rt_observer.height == h) {
        return;
    }
    if (s.rt_observer.color != .invalid) {
        z.unloadRenderTexture(f.gl, &s.rt_observer);
        z.unloadRenderTexture(f.gl, &s.rt_subject);
    }
    s.rt_observer = z.loadRenderTexture(f.gl, @intCast(w), @intCast(h));
    s.rt_subject = z.loadRenderTexture(f.gl, @intCast(w), @intCast(h));
}

/// The shared world: raylib's gold cube on a grid, plus a few satellites so the
/// subject camera (and the magnified crop) always has something to frame.
fn drawWorld(f: *z.Frame) void {
    z.drawGrid(f.gl, 10, 1.0);
    z.drawCube(f.gl, pointVec(0, 0, 0), .{ .size = vec(2, 2, 2), .color = c.gold });
    z.drawCubeWires(f.gl, pointVec(0, 0, 0), .{ .size = vec(2, 2, 2), .color = c.pink_400 });
    z.drawSphere(f.gl, pointVec(-3, 0.6, 2), .{ .radius = 0.6, .rings = 10, .slices = 14, .color = c.emerald_400 });
    z.drawSphere(f.gl, pointVec(3, 0.6, -2), .{ .radius = 0.6, .rings = 10, .slices = 14, .color = c.sky_300 });
    z.drawCube(f.gl, pointVec(2.5, 0.4, 2.5), .{ .size = vec(0.8, 0.8, 0.8), .color = c.violet_400 });
    z.drawCube(f.gl, pointVec(-2.5, 0.4, -2.5), .{ .size = vec(0.8, 0.8, 0.8), .color = c.amber_500 });
}

/// raylib's `DrawCameraPrism`: the subject camera's frustum, unprojected into
/// world space and drawn as wires in the OBSERVER's pane.
///
/// The trick is that the far plane is deliberately built at the camera's TARGET
/// distance (`far = |position - target|`), so the prism is sliced exactly where
/// the subject is looking instead of running off to z_far. Take the four far-plane
/// NDC corners `(+/-1, +/-1, 1)`, push them through the INVERSE view-projection, and
/// the perspective divide hands back the four world-space corners of what that
/// camera can see. z = 1 is the far plane in WebGPU's 0..1 clip space just as it
/// is in GL's -1..1, so raylib's corner list ports across unchanged.
fn drawCameraPrism(f: *z.Frame, cam: Camera3D, aspect: f32, color: Color) void {
    const far: f32 = @max(length3(cam.position - cam.target), 0.1);
    const proj: Mat = perspectiveFovRh(cam.fovy_deg * pi / 180.0, aspect, 0.05, far);
    const view_proj: Mat = mulMat(proj, cam.viewMatrix());
    const inv: Mat = inverse(view_proj);

    const ndc: [4]Vec = .{
        vec4(-1, -1, 1, 1), // bottom-left
        vec4(1, -1, 1, 1), // bottom-right
        vec4(1, 1, 1, 1), // top-right
        vec4(-1, 1, 1, 1), // top-left
    };
    var corner: [4]Vec = undefined;
    for (ndc, 0..) |p, i| {
        const h: Vec = mulMatVec(inv, p);
        const w: f32 = if (@abs(h[3]) < 1e-6) 1e-6 else h[3];
        corner[i] = pointVec(h[0] / w, h[1] / w, h[2] / w);
    }

    for (0..4) |i| {
        z.drawLine3D(f.gl, corner[i], corner[(i + 1) % 4], color); // the far plane
        z.drawLine3D(f.gl, cam.position, corner[i], color); // and the four eye rays
    }
}

/// The two viewports, in logical coords: stacked on a portrait phone, side by
/// side on a landscape screen. These rects are BOTH the compositor's layout and
/// each camera's `region` - one source of truth, so what you see is what you
/// steer.
const Layout = struct {
    observer: z.Rectangle,
    subject: z.Rectangle,
    portrait: bool,
};

fn layoutFor(vw: f32, vh: f32) Layout {
    const portrait: bool = vh >= vw;
    const pane_w: f32 = if (portrait) vw else vw * 0.5;
    const pane_h: f32 = if (portrait) vh * 0.5 else vh;
    const second_x: f32 = if (portrait) 0 else pane_w;
    const second_y: f32 = if (portrait) pane_h else 0;
    return .{
        .observer = .{ .x = 0, .y = 0, .width = pane_w, .height = pane_h },
        .subject = .{ .x = second_x, .y = second_y, .width = pane_w, .height = pane_h },
        .portrait = portrait,
    };
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    const lay: Layout = layoutFor(vw, vh);
    const rt_w: f32 = float(s.rt_subject.width);
    const rt_h: f32 = float(s.rt_subject.height);
    const aspect: f32 = rt_w / @max(rt_h, 1);

    // Each camera is handed ITS pane as `region`: the engine then routes a drag
    // (pointer) or a pinch (the midpoint of the two fingers) to whichever camera
    // owns the viewport the gesture began in, and latches it for the gesture's
    // life. No pane bookkeeping in the app.
    const observer_opts: z.OrbitOptions = .{
        .min_distance = 6.0,
        .max_distance = 60.0,
        .region = lay.observer,
    };
    const subject_opts: z.OrbitOptions = .{
        .min_distance = 3.0,
        .max_distance = 24.0,
        .fovy_deg = 45,
        .region = lay.subject,
    };

    // ORDER (forced, and worth understanding): `manages_own_frame` means the
    // offscreen passes run BEFORE the screen pass opens - that is the whole
    // tile-based-GPU point. But `UiHost.begin` asserts an OPEN draw frame (the UI
    // is built into it), and the camera must not steal a drag that belongs to the
    // UI panel. So input can only be read AFTER `beginDrawing`, i.e. after the
    // framebuffers are already drawn. The cameras therefore render from the state
    // last frame's input left them in, and this frame's drag lands next frame -
    // one frame of lag, invisible at 60fps, and exactly what cel_shading does.
    const cam_observer: Camera3D = s.observer.camera(observer_opts);
    const cam_subject: Camera3D = s.subject.camera(subject_opts);

    // ---- framebuffer 1: what the observer sees (including the subject) ----
    z.beginTextureMode(f.gl, s.rt_observer, .{ .r = 18, .g = 20, .b = 28, .a = 255 });
    z.beginMode3D(f.gl, cam_observer);
    drawWorld(f);
    drawCameraPrism(f, cam_subject, aspect, c.emerald_400);
    z.endMode3D(f.gl);
    f.gl.text(.{ 12, 10 }, "OBSERVER", .{ .size = 20, .color = c.white, .font = &s.font });
    z.endTextureMode(f.gl);

    // ---- framebuffer 2: what the subject sees, with the capture box marked ----
    const cap: f32 = @min(s.capture_px, @min(rt_w, rt_h));
    const cap_x: f32 = (rt_w - cap) * 0.5;
    const cap_y: f32 = (rt_h - cap) * 0.5;
    z.beginTextureMode(f.gl, s.rt_subject, .{ .r = 18, .g = 20, .b = 28, .a = 255 });
    z.beginMode3D(f.gl, cam_subject);
    drawWorld(f);
    z.endMode3D(f.gl);
    f.gl.rect(
        .{ .x = cap_x, .y = cap_y, .width = cap, .height = cap },
        .{ .color = c.emerald_400, .outline = 2.0 },
    );
    f.gl.text(.{ 12, 10 }, "SUBJECT", .{ .size = 20, .color = c.white, .font = &s.font });
    z.endTextureMode(f.gl);

    // ---- composite ----
    z.beginDrawing(f.gl);
    z.clearViewport(f, common.palette.bg);

    const obs: z.Rectangle = lay.observer;
    const sub: z.Rectangle = lay.subject;
    f.gl.texture(obs, s.rt_observer.asTexture(), .{ .tint = c.white });
    f.gl.texture(sub, s.rt_subject.asTexture(), .{ .tint = c.white });

    // THE POINT OF THE SAMPLE: a sub-rectangle of a texture we rendered this
    // frame, magnified. `.source` is in the framebuffer's own PIXELS; a negative
    // width mirrors it (raylib's rule, and how a GL render texture gets flipped).
    const view_px: f32 = @min(160, sub.width * 0.42);
    const vx: f32 = sub.x + sub.width - view_px - 14;
    const vy: f32 = sub.y + 14;
    const src_w: f32 = if (s.mirror) -cap else cap;
    const src_x: f32 = if (s.mirror) cap_x + cap else cap_x;
    f.gl.texture(
        .{ .x = vx, .y = vy, .width = view_px, .height = view_px },
        s.rt_subject.asTexture(),
        .{ .source = .{ .x = src_x, .y = cap_y, .width = src_w, .height = cap }, .tint = c.white },
    );
    f.gl.rect(
        .{ .x = vx, .y = vy, .width = view_px, .height = view_px },
        .{ .color = c.black, .outline = 2.0 },
    );

    // the split divider
    if (lay.portrait) {
        f.gl.rect(.{ .x = 0, .y = sub.y - 1.5, .width = vw, .height = 3 }, .{ .color = c.white });
    } else {
        f.gl.rect(.{ .x = sub.x - 1.5, .y = 0, .width = 3, .height = vh }, .{ .color = c.white });
    }

    const hint: []const u8 = "drag or pinch a pane to steer THAT camera";
    f.gl.text(.{ 14, 40 }, hint, .{ .size = 18, .color = common.palette.ink_dim, .font = &s.font });
    common.caption(f.gl, s.font, "two render textures - one world, two cameras, a cropped viewfinder");

    // ---- UI (inside the open frame), then input ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(300, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 150 }, .{});
    u.setNextWindowSize(.{ panel_w, 142 }, .{});
    if (u.window("framebuffers", .{})) |w| {
        defer w.close();
        if (u.button("reset both", .{})) {
            s.subject = z.OrbitCamera.init(pointVec(0, 0, 0), 8.0);
            s.observer = z.OrbitCamera.init(pointVec(0, 0, 0), 18.0);
        }
        u.sameLine(.{});
        _ = u.checkbox("auto-orbit", &s.auto_orbit);
        _ = u.checkbox("mirror viewfinder", &s.mirror);
        _ = u.slider("capture px", &s.capture_px, .{ .min = 48, .max = 320 });
    }

    // Both controllers see every gesture; each takes only the ones that BEGAN in
    // its own `region` - pointer for a drag, MIDPOINT OF THE TWO FINGERS for a
    // pinch. No pane bookkeeping here: that is the controller's job now.
    // Auto-orbit yields while a gesture owns the subject pane.
    const ui_owns: bool = u.wantCaptureMouse();
    _ = s.observer.update(f, ui_owns, observer_opts);
    if (s.auto_orbit and !s.subject.owns_gesture) {
        s.subject.yaw += f.time.delta_time * 0.45;
    }
    _ = s.subject.update(f, ui_owns, subject_opts);

    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - textures framebuffer rendering",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    // Offscreen render textures are drawn BEFORE the screen pass opens
    // (tile-based-GPU safe), so the app owns its own begin/endDrawing.
    .manages_own_frame = true,
    .memory = .managed,
};
