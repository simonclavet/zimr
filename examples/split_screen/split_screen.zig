//! split_screen - port of the GL `split_screen`: two players, one
//! world, two perspectives.
//!
//! The original was the architecture test for the (GL-era) Scene renderer's
//! per-camera fog: two cameras orbiting inside two different fog spheres,
//! each rendered into its half of the canvas, picking up "its" fog with no
//! split-screen awareness in the renderer.  That Scene system dies with the
//! GL path; this port keeps the demo's ESSENCE on the wgpu idioms:
//!   - ONE world (immediate-3D primitives + the two zone spheres), drawn
//!     TWICE per frame with two cameras - each into its own RenderTexture
//!     (the helmet's RTT pattern), composited side by side.
//!   - Per-camera ATMOSPHERE computed in app code: whichever zone sphere a
//!     camera is inside tints that camera's half (a translucent overlay in
//!     the RTT's own 2D space).  Same story - one world, two views, two
//!     atmospheres - without renderer special-casing.
//!   - The engine learned `App.target_size` for this port: `beginMode3D`
//!     inside `beginTextureMode` now uses the RTT's aspect, so a half-width
//!     viewport renders undistorted.
//! The halves track the live canvas (backing size / 2 each), so rotation
//! and resize stay correct - the t1168 fullscreen rules.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const float = zm.float;
const length3 = zm.length3;
const pi = zm.pi;
const pointVec = zm.pointVec;
const tau = zm.tau;
const vec = zm.vec;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

// The two atmosphere zones: a blue one on the left of the world, an amber
// one on the right.  Each camera orbits INSIDE its zone, so by construction
// each half always shows that zone's tint (cross over and it would switch -
// same "exercise for the reader" as the original).
const zone_blue_center: Vec = pointVec(-4, 1, 0);
const zone_amber_center: Vec = pointVec(4, 1, 0);
const zone_radius: f32 = 3.4;

const State = struct {
    font: z.Font,
    rt_left: z.RenderTexture = .{},
    rt_right: z.RenderTexture = .{},
    angle: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.rt_left.deinit();
    s.rt_right.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

/// Keep each half's render texture at half the surface BACKING width x
/// full backing height (pixel-perfect at any orientation; recreated only
/// when the size actually changes).
fn ensureTargets(f: *z.Frame, s: *State) void {
    const backing: z.wgpu.SurfaceSize = z.wgpu.getSurfaceSize(f.gpu.surface);
    const half_w: u32 = @max(backing.width / 2, 1);
    const full_h: u32 = @max(backing.height, 1);
    if (s.rt_left.color == .invalid or s.rt_left.width != half_w or s.rt_left.height != full_h) {
        if (s.rt_left.color != .invalid) {
            z.unloadRenderTexture(f.gl, &s.rt_left);
            z.unloadRenderTexture(f.gl, &s.rt_right);
        }
        s.rt_left = z.loadRenderTexture(f.gl, @intCast(half_w), @intCast(full_h));
        s.rt_right = z.loadRenderTexture(f.gl, @intCast(half_w), @intCast(full_h));
    }
}

/// Three orthogonal great circles approximating a wire sphere.
fn drawZoneRings(f: *z.Frame, center: Vec, radius: f32, color: Color) void {
    const segs: usize = 28;
    var i: usize = 0;
    while (i < segs) : (i += 1) {
        const a0: f32 = float(i) / segs * tau;
        const a1: f32 = float(i + 1) / segs * tau;
        const c0: f32 = @cos(a0) * radius;
        const s0: f32 = @sin(a0) * radius;
        const c1: f32 = @cos(a1) * radius;
        const s1: f32 = @sin(a1) * radius;
        // XZ ring (horizon), XY ring, YZ ring.
        z.drawLine3D(f.gl, center + vec(c0, 0, s0), center + vec(c1, 0, s1), color);
        z.drawLine3D(f.gl, center + vec(c0, s0, 0), center + vec(c1, s1, 0), color);
        z.drawLine3D(f.gl, center + vec(0, c0, s0), center + vec(0, c1, s1), color);
    }
}

/// The shared world - drawn identically for both cameras.  A ground grid,
/// a small scatter of primitives, and the two zone spheres as wireframes so
/// each player can SEE the atmosphere volumes.
fn drawWorld(f: *z.Frame) void {
    z.drawGrid(f.gl, 20, 1.0);

    z.drawCube(f.gl, pointVec(0, 0.6, 0), .{ .size = vec(1.2, 1.2, 1.2), .color = c.slate_400 });
    z.drawCubeWires(f.gl, pointVec(0, 0.6, 0), .{ .size = vec(1.2, 1.2, 1.2), .color = c.slate_200 });
    z.drawSphere(f.gl, pointVec(-2, 0.7, 2), .{ .radius = 0.7, .rings = 12, .slices = 16, .color = c.rose_400 });
    z.drawSphere(f.gl, pointVec(2, 0.7, -2), .{ .radius = 0.7, .rings = 12, .slices = 16, .color = c.emerald_400 });
    z.drawCylinderBetween(f.gl, pointVec(-1.5, 0, -2.5), pointVec(-1.5, 1.6, -2.5), 0.4, 0.4, 14, c.violet_400);
    z.drawCylinderBetween(f.gl, pointVec(1.5, 0, 2.5), pointVec(1.5, 2.0, 2.5), 0.5, 0.0, 14, c.amber_500);

    // The atmosphere volumes, visible from inside and out (three orthogonal
    // rings each - the wgpu immediate set has no drawSphereWires yet).
    drawZoneRings(f, zone_blue_center, zone_radius, c.sky_300);
    drawZoneRings(f, zone_amber_center, zone_radius, c.amber_300);
}

/// Whichever zone sphere `pos` is inside picks the half's atmosphere tint
/// (alpha-blended overlay); outside both = no tint.  The original's
/// per-camera fog picker, reborn as twelve lines of app code.
fn atmosphereTint(pos: Vec) ?Color {
    if (length3(pos - zone_blue_center) < zone_radius) {
        return .{ .r = 70, .g = 120, .b = 220, .a = 64 };
    }
    if (length3(pos - zone_amber_center) < zone_radius) {
        return .{ .r = 230, .g = 160, .b = 40, .a = 64 };
    }
    return null;
}

/// Render the shared world from `cam` into `rt`, then overlay that
/// camera's atmosphere tint in the RTT's own 2D space.
fn renderView(f: *z.Frame, rt: z.RenderTexture, cam: Camera3D) void {
    z.beginTextureMode(f.gl, rt, .{ .r = 10, .g = 12, .b = 20, .a = 255 });
    z.beginMode3D(f.gl, cam);
    drawWorld(f);
    z.endMode3D(f.gl);
    if (atmosphereTint(cam.position)) |tint| {
        const rtw: f32 = float(rt.width);
        const rth: f32 = float(rt.height);
        f.gl.rect(.{ .x = 0, .y = 0, .width = rtw, .height = rth }, .{ .color = tint });
    }
    z.endTextureMode(f.gl);
}

fn update(f: *z.Frame, s: *State) void {
    ensureTargets(f, s);
    s.angle += f.time.delta_time * 24.0;
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);

    // OFFSCREEN FIRST (tile-based-GPU safe; app owns begin/endDrawing).
    // Each camera orbits INSIDE its own zone at radius 2, looking across
    // the world at the other zone's center - so each half frames the whole
    // scene from its side.
    const rad: f32 = s.angle * pi / 180.0;
    const cam_left: Camera3D = .{
        .position = pointVec(
            zone_blue_center[0] + @cos(rad) * 2.0,
            1.6,
            zone_blue_center[2] + @sin(rad) * 2.0,
        ),
        .target = zone_amber_center,
        .up = vec(0, 1, 0),
        .fovy_deg = 55,
        .projection = 0,
    };
    const cam_right: Camera3D = .{
        .position = pointVec(
            zone_amber_center[0] + @cos(-rad) * 2.0,
            1.6,
            zone_amber_center[2] + @sin(-rad) * 2.0,
        ),
        .target = zone_blue_center,
        .up = vec(0, 1, 0),
        .fovy_deg = 55,
        .projection = 0,
    };

    renderView(f, s.rt_left, cam_left);
    renderView(f, s.rt_right, cam_right);

    // SCREEN PASS: open once, clear, then composite.
    z.beginDrawing(f.gl);
    z.clearViewport(f, common.palette.bg);

    // Composite the two halves + divider + labels.
    const half: f32 = vw * 0.5;
    const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    f.gl.texture(.{ .x = 0, .y = 0, .width = half, .height = vh }, s.rt_left.asTexture(), .{ .tint = white });
    f.gl.texture(.{ .x = half, .y = 0, .width = half, .height = vh }, s.rt_right.asTexture(), .{ .tint = white });
    f.gl.rect(.{ .x = half - 1.5, .y = 0, .width = 3, .height = vh }, .{ .color = white });

    f.gl.text(
        .{ 16, 14 },
        "P1 - blue zone",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    f.gl.text(
        .{ vw - 188, 14 },
        "P2 - amber zone",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    common.caption(f.gl, s.font, "one world, two cameras, two render textures - per-camera atmosphere");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - split screen: two cameras, one world",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    // Offscreen render-textures drawn before the screen opens (tile-based-GPU
    // safe); owns its own begin/endDrawing.
    .manages_own_frame = true,
};
