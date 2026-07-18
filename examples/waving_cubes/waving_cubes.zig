//! waving_cubes — raylib's `models_waving_cubes`, the zimr way.
//!
//! A 15×15×15 field of cubes breathes: a global `scale` pulses on a
//! slow sine, and each cube gets a per-cube `scatter` offset from
//! `sin(blockScale*20 + time*4)`, so the grid ripples like a wave
//! travelling through it. Color is an HSV rainbow keyed to (x+y+z), and
//! each cube's size shrinks with the same diagonal index — the far
//! corner cubes are the biggest and most saturated. raylib's numbers
//! (the 3375-cube grid, the 0.7 pulse, the ×20/×4 wave frequencies) are
//! kept verbatim; this is a pure immediate-mode 3D batch, so it also
//! stress-tests that path at a few thousand cubes per frame.
//!
//! raylib auto-orbits the camera on a fixed circle. Phone-first here:
//! the same slow auto-orbit, but one finger drags to take the wheel
//! (orbit yaw/pitch by hand), and a pinch zooms the radius. Lifting off
//! hands control back to the auto-orbit from wherever you left it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Camera3D = zm.Camera3D;
const Color = zm.Color;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const float = zm.float;
const pointVec = zm.pointVec;
const rad_per_deg = zm.rad_per_deg;
const vec = zm.vec;
const co = @import("example_common");

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

pub var zimr_app: z.App = .{};

const num_blocks: i32 = 15;
const min_radius: f32 = 18;
const max_radius: f32 = 70;

const State = struct {
    font: z.Font,
    // Orbit camera: auto-advances unless the user is dragging.
    orbit_angle: f32 = 0,
    pitch: f32 = 22, // degrees above the ground plane
    radius: f32 = 40,
    dragging: bool = false,
    prev_pinch: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 22) };
}

/// One finger drags to orbit (gated on the UI not wanting the pointer);
/// a two-finger pinch zooms the radius. Matches every other 3D demo.
fn handleCamera(f: *z.Frame, s: *State, dt: f32) void {
    if (z.getTouchPointCount(f.input) >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.radius = clamp(s.radius - (dist - s.prev_pinch) * 0.05, min_radius, max_radius);
        }
        s.prev_pinch = dist;
    } else {
        s.prev_pinch = 0;
    }

    if (z.isMouseButtonDown(f.input, .left)) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.orbit_angle -= d[0] * 0.005;
            s.pitch = clamp(s.pitch - d[1] * 0.25, -80, 80);
        }
        s.dragging = true;
    } else {
        s.dragging = false;
        // Auto-orbit only while hands-off (raylib's cameraTime = time*0.3).
        s.orbit_angle += dt * 0.3;
    }
}

fn update(f: *z.Frame, s: *State) void {
    const t: f32 = f.time.time;
    const dt: f32 = @floatCast(f.time.delta_time);

    z.clearViewport(f, co.palette.bg);
    handleCamera(f, s, dt);

    // Global breathing pulse (raylib: (2 + sin(time)) * 0.7).
    const scale: f32 = (2.0 + @sin(t)) * 0.7;

    // Orbit camera position from angle + pitch + radius.
    const cp: f32 = @cos(s.pitch * rad_per_deg);
    const eye: Vec = pointVec(
        @cos(s.orbit_angle) * s.radius * cp,
        @sin(s.pitch * rad_per_deg) * s.radius + 2.0,
        @sin(s.orbit_angle) * s.radius * cp,
    );
    const cam: Camera3D = .{
        .position = eye,
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 70,
        .projection = 0,
    };

    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 10, 5.0);

    const half: f32 = float(num_blocks) / 2.0;
    var x: i32 = 0;
    while (x < num_blocks) : (x += 1) {
        var y: i32 = 0;
        while (y < num_blocks) : (y += 1) {
            var zc: i32 = 0;
            while (zc < num_blocks) : (zc += 1) {
                const diag: f32 = float(x + y + zc);
                const block_scale: f32 = diag / 30.0;
                const scatter: f32 = @sin(block_scale * 20.0 + t * 4.0);
                const fx: f32 = float(x);
                const fy: f32 = float(y);
                const fz: f32 = float(zc);
                const pos: Vec = pointVec(
                    (fx - half) * (scale * 3.0) + scatter,
                    (fy - half) * (scale * 2.0) + scatter,
                    (fz - half) * (scale * 3.0) + scatter,
                );
                const hue: f32 = @mod(diag * 18.0, 360.0);
                const col: Color = z.colorFromHSV(hue, 0.75, 0.9);
                const cube_size: f32 = (2.4 - scale) * block_scale;
                z.drawCube(f.gl, pos, .{ .size = vec(cube_size, cube_size, cube_size), .color = col });
            }
        }
    }
    z.endMode3D(f.gl);

    co.caption(f.gl, s.font, "WebGPU 3D - waving cubes (drag orbit, pinch zoom)");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - waving cubes",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
