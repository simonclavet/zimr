//! yaw_pitch_roll - raylib's `models_yaw_pitch_roll`.
//!
//! The classic aircraft-orientation demo: three independent rotations -
//! PITCH (nose up/down, X axis), YAW (nose left/right, Y axis), and ROLL
//! (bank, Z axis) - composed as one XYZ rotation matrix and applied to a
//! plane. raylib loads a WWI biplane .obj; a standalone can't fetch that,
//! so the plane here is built from immediate-3D-batch primitives (fuselage,
//! wings, tail, nose) - enough of a recognizable body that all three axes
//! read clearly. Each part's offset from the origin AND its own orientation
//! are rotated by the same matrix, so the whole craft turns rigidly.
//!
//! Controls: UP/DOWN pitch, A/S yaw, LEFT/RIGHT roll (raylib's mapping),
//! plus on-screen buttons for phones. Inputs ease back toward level when
//! released, like the original.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Vec = zm.Vec;
const mulMat = zm.mulMat;
const mulMatVec = zm.mulMatVec;
const pointVec = zm.pointVec;
const rotationX = zm.rotationX;
const rotationY = zm.rotationY;
const rotationZ = zm.rotationZ;
const rad_per_deg = zm.rad_per_deg;
const vec = zm.vec;
const bufPrint = std.fmt.bufPrint;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub var zimr_app: z.App = .{};

// Plane palette.
const body_col: Color = .{ .r = 180, .g = 60, .b = 55, .a = 255 };
const wing_col: Color = .{ .r = 210, .g = 200, .b = 180, .a = 255 };
const tail_col: Color = .{ .r = 90, .g = 120, .b = 190, .a = 255 };
const nose_col: Color = .{ .r = 240, .g = 200, .b = 70, .a = 255 };

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    pitch: f32 = 0, // degrees
    yaw: f32 = 0,
    roll: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
    };
}

/// One plane part: a box at `offset` from the craft origin, with `size`.
const Part = struct {
    offset: [3]f32,
    size: [3]f32,
    color: Color,
};

const parts = [_]Part{
    .{ .offset = .{ 0, 0, 0 }, .size = .{ 1.4, 1.0, 6.0 }, .color = body_col }, // fuselage
    .{ .offset = .{ 0, 0, 2.6 }, .size = .{ 1.0, 0.8, 1.2 }, .color = nose_col }, // nose
    .{ .offset = .{ 0, 0.1, -0.3 }, .size = .{ 9.0, 0.25, 1.8 }, .color = wing_col }, // main wing
    .{ .offset = .{ 0, 1.1, -0.3 }, .size = .{ 7.5, 0.25, 1.5 }, .color = wing_col }, // upper wing (biplane)
    .{ .offset = .{ 0, 0.6, -3.2 }, .size = .{ 3.2, 0.22, 1.1 }, .color = tail_col }, // horizontal stabilizer
    .{ .offset = .{ 0, 1.1, -3.1 }, .size = .{ 0.22, 1.4, 1.0 }, .color = tail_col }, // vertical fin
};

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    z.clearViewport(f, common.palette.bg);

    const u: z.ui_real.Ui = s.ui_host.begin(f);

    // ---- controls: keyboard (raylib mapping) + easing back to level ----
    const in = f.input;
    // Pitch: UP nose-down, DOWN nose-up (raylib's sign).
    if (z.isKeyDown(in, .down)) {
        s.pitch += 0.6;
    } else if (z.isKeyDown(in, .up)) {
        s.pitch -= 0.6;
    } else {
        s.pitch = easeToZero(s.pitch, 0.3);
    }
    // Yaw: A left, S right.
    if (z.isKeyDown(in, .s)) {
        s.yaw -= 1.0;
    } else if (z.isKeyDown(in, .a)) {
        s.yaw += 1.0;
    } else {
        s.yaw = easeToZero(s.yaw, 0.5);
    }
    // Roll: LEFT/RIGHT bank.
    if (z.isKeyDown(in, .left)) {
        s.roll -= 1.0;
    } else if (z.isKeyDown(in, .right)) {
        s.roll += 1.0;
    } else {
        s.roll = easeToZero(s.roll, 0.5);
    }

    // ---- on-screen buttons (phone): three held pairs ----
    controlPanel(u, s, vw, vh);

    // ---- compose the XYZ rotation (raylib's MatrixRotateXYZ) ----
    const rp: f32 = s.pitch * rad_per_deg;
    const ry: f32 = s.yaw * rad_per_deg;
    const rr: f32 = s.roll * rad_per_deg;
    const rot: Mat = mulMat(rotationX(rp), mulMat(rotationY(ry), rotationZ(rr)));

    const cam: Camera3D = .{
        .position = pointVec(0, 6, -16),
        .target = pointVec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 45.0,
        .projection = 0,
    };

    // ---- draw the plane: rotate each part's offset AND orientation ----
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 20, 1.0);
    for (parts) |p| {
        const local: Vec = pointVec(p.offset[0], p.offset[1], p.offset[2]);
        const world: Vec = mulMatVec(rot, local);
        z.drawCube(f.gl, world, .{
            .size = vec(p.size[0], p.size[1], p.size[2]),
            .rotation = rot,
            .color = p.color,
        });
    }
    z.endMode3D(f.gl);

    // ---- HUD ----
    var buf: [96]u8 = undefined;
    const hud: []const u8 = bufPrint(
        &buf,
        "pitch {d: >6.1}   yaw {d: >6.1}   roll {d: >6.1}",
        .{ s.pitch, s.yaw, s.roll },
    ) catch "";
    f.gl.text(.{ 14, 42 }, hud, .{ .size = 18, .color = common.palette.ink_dim, .font = &s.font });
    common.caption(f.gl, s.font, "WebGPU 3D - yaw / pitch / roll (arrows + A/S, or buttons)");
    s.ui_host.render(f);
}

/// Ease a value toward 0 by `step` (raylib's release behavior).
fn easeToZero(v: f32, step: f32) f32 {
    if (v > step) {
        return v - step;
    }
    if (v < -step) {
        return v + step;
    }
    return 0;
}

/// On-screen held buttons: pitch (+/-), yaw (+/-), roll (+/-). Phone-first: 2 rows.
fn controlPanel(u: z.ui_real.Ui, s: *State, vw: f32, vh: f32) void {
    u.setNextWindowPos(.{ 8, vh - 108 }, .{});
    u.setNextWindowSize(.{ @min(340, vw - 16), 100 }, .{});
    if (u.window("attitude", .{})) |w| {
        defer w.close();
        heldPair(u, "nose up", "nose dn", &s.pitch, 0.6, false);
        heldPair(u, "yaw L", "yaw R", &s.yaw, 1.0, true);
        heldPair(u, "roll L", "roll R", &s.roll, 1.0, false);
    }
}

/// A pair of held buttons that increment/decrement `v` while pressed. `plus_left`
/// flips which button adds (yaw's A/S is inverted vs the others in raylib).
fn heldPair(
    u: z.ui_real.Ui,
    neg_label: []const u8,
    pos_label: []const u8,
    v: *f32,
    step: f32,
    plus_left: bool,
) void {
    _ = u.button(neg_label, .{});
    if (u.isItemActive()) {
        v.* += if (plus_left) step else -step;
    }
    u.sameLine(.{});
    _ = u.button(pos_label, .{});
    if (u.isItemActive()) {
        v.* += if (plus_left) -step else step;
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - yaw pitch roll",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
