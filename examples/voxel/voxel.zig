//! voxel - raylib's `models_basic_voxel`, the zimr way.
//!
//! An 8x8x8 solid block of unit cubes.  A crosshair sits locked at
//! screen center; a tap casts a ray through it (`getScreenToWorldRay`,
//! this port) and tests every remaining voxel's AABB
//! (`getRayCollisionBox`) - the CLOSEST hit is removed, Minecraft-style
//! block-breaking.  Cubes are drawn through the immediate-mode 3D batch
//! (`drawCube` + `drawCubeWires`), exactly raylib's per-voxel loop, so
//! the whole field coalesces into a couple of draws.
//!
//! Phone-first: raylib uses WASD + locked-mouse first-person look.
//! Here ONE finger drags to look (yaw/pitch), a TAP (press+release
//! under ~10px) breaks the voxel under the crosshair, and two on-screen
//! buttons dolly the camera in/out along its facing so you can reach
//! the far cubes.  "reset" refills the block.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const float = zm.float;
const vec = zm.vec;

pub var zimr_app: z.App = .{};

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const world: usize = 8; // 8x8x8 voxel field
const beige: Color = .{ .r = 211, .g = 176, .b = 131, .a = 255 };
const wire: Color = .{ .r = 30, .g = 30, .b = 36, .a = 255 };
const bg_clear: Color = .{ .r = 232, .g = 232, .b = 236, .a = 255 };
const crosshair_red: Color = .{ .r = 230, .g = 40, .b = 40, .a = 255 };

const State = struct {
    gpa: Allocator,
    voxels: [world][world][world]bool = undefined,
    remaining: u32 = 0,

    ui_host: z.UiHost,
    font: z.Font,

    // Orbit-style first-person: look angles + a distance so tap-look and
    // the dolly buttons both feel natural on a phone.
    cam_yaw: f32 = 0.9,
    cam_pitch: f32 = 0.35,
    cam_dist: f32 = 14.0,

    press_pos: Vec2 = .{ 0, 0 },
    pressed: bool = false,
    dragging: bool = false,
    drag_total: f32 = 0,
    prev_pinch: f32 = 0,
};

fn fill(s: *State) void {
    var count: u32 = 0;
    for (0..world) |x| {
        for (0..world) |y| {
            for (0..world) |zc| {
                s.voxels[x][y][zc] = true;
                count += 1;
            }
        }
    }
    s.remaining = count;
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    s.* = .{
        .gpa = gpa,
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
    };
    fill(s);
}

/// The field is centered on the origin: voxel (x,y,z) sits at world
/// (x - c, y - c, z - c) with c = (world-1)/2.
fn voxelCenter(x: usize, y: usize, zc: usize) Vec {
    const c: f32 = float(@as(i32, @intCast(world - 1))) * 0.5;
    return vec(
        float(@as(i32, @intCast(x))) - c,
        float(@as(i32, @intCast(y))) - c,
        float(@as(i32, @intCast(zc))) - c,
    );
}

fn cameraOf(s: *const State) Camera3D {
    const cp: f32 = @cos(s.cam_pitch);
    const sp: f32 = @sin(s.cam_pitch);
    const cy: f32 = @cos(s.cam_yaw);
    const sy: f32 = @sin(s.cam_yaw);
    const eye: Vec = vec(s.cam_dist * cp * sy, s.cam_dist * sp, s.cam_dist * cp * cy);
    return .{
        .position = eye,
        .target = vec(0, 0, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 55,
    };
}

/// Cast a ray through the crosshair (screen center) and remove the
/// closest still-present voxel it hits.
fn breakVoxel(s: *State, cam: Camera3D, vw: f32, vh: f32) void {
    const center: Vec2 = .{ vw * 0.5, vh * 0.5 };
    const ray: zm.Ray = z.getScreenToWorldRay(center, cam, vw, vh);

    var best_dist: f32 = 1.0e30;
    var hit_x: usize = 0;
    var hit_y: usize = 0;
    var hit_z: usize = 0;
    var found: bool = false;
    for (0..world) |x| {
        for (0..world) |y| {
            for (0..world) |zc| {
                if (!s.voxels[x][y][zc]) {
                    continue;
                }
                const ctr: Vec = voxelCenter(x, y, zc);
                const col: zm.RayCollision = z.getRayCollisionBox(ray, .{
                    .min = vec(ctr[0] - 0.5, ctr[1] - 0.5, ctr[2] - 0.5),
                    .max = vec(ctr[0] + 0.5, ctr[1] + 0.5, ctr[2] + 0.5),
                });
                if (col.hit and col.distance < best_dist) {
                    best_dist = col.distance;
                    hit_x = x;
                    hit_y = y;
                    hit_z = zc;
                    found = true;
                }
            }
        }
    }
    if (found) {
        s.voxels[hit_x][hit_y][hit_z] = false;
        s.remaining -= 1;
    }
}

fn handleInput(
    f: *z.Frame,
    s: *State,
    ui_wants_mouse: bool,
    cam: Camera3D,
    vw: f32,
    vh: f32,
) void {
    const touches: i32 = z.getTouchPointCount(f.input);
    if (touches >= 2) {
        const a: Vec2 = z.getTouchPosition(f.input, 0);
        const b: Vec2 = z.getTouchPosition(f.input, 1);
        const dx: f32 = a[0] - b[0];
        const dy: f32 = a[1] - b[1];
        const dist: f32 = @sqrt(dx * dx + dy * dy);
        if (s.prev_pinch > 0) {
            s.cam_dist = clamp(s.cam_dist - (dist - s.prev_pinch) * 0.03, 3.0, 24.0);
        }
        s.prev_pinch = dist;
        s.pressed = false;
        return;
    }
    s.prev_pinch = 0;

    const mp: Vec2 = z.getMousePosition(f.input);
    if (z.isMouseButtonDown(f.input, .left) and !ui_wants_mouse) {
        if (s.dragging) {
            const d: Vec2 = z.getMouseDelta(f.input);
            s.cam_yaw -= d[0] * 0.008;
            s.cam_pitch = clamp(s.cam_pitch + d[1] * 0.008, -1.4, 1.4);
            s.drag_total += @abs(d[0]) + @abs(d[1]);
        } else {
            s.press_pos = mp;
            s.drag_total = 0;
            s.pressed = true;
        }
        s.dragging = true;
    } else {
        // Release: a press that stayed put is a tap -> break a voxel.
        if (s.dragging and s.pressed and s.drag_total < 10.0) {
            breakVoxel(s, cam, vw, vh);
        }
        s.dragging = false;
        s.pressed = false;
    }
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.cam_dist = clamp(s.cam_dist - wheel * 0.6, 3.0, 24.0);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    z.clearViewport(f, bg_clear);

    const cam: Camera3D = cameraOf(s);

    // ---- UI (dolly + reset); its capture flag gates look/tap ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const panel_w: f32 = @min(320, vw - 16);
    u.setNextWindowPos(.{ 8, vh - 128 }, .{});
    u.setNextWindowSize(.{ panel_w, 120 }, .{});
    if (u.window("basic voxel", .{})) |w| {
        defer w.close();
        u.text("tap the crosshair to break a voxel", .{});
        u.text("voxels left: {d}", .{s.remaining});
        if (u.button("closer", .{})) {
            s.cam_dist = clamp(s.cam_dist - 1.5, 3.0, 24.0);
        }
        u.sameLine(.{});
        if (u.button("farther", .{})) {
            s.cam_dist = clamp(s.cam_dist + 1.5, 3.0, 24.0);
        }
        u.sameLine(.{});
        if (u.button("reset", .{})) {
            fill(s);
        }
    }
    handleInput(f, s, u.wantCaptureMouse(), cam, vw, vh);

    // ---- the 3D scene: grid + every present voxel (solid + wire) ----
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    for (0..world) |x| {
        for (0..world) |y| {
            for (0..world) |zc| {
                if (!s.voxels[x][y][zc]) {
                    continue;
                }
                const ctr: Vec = voxelCenter(x, y, zc);
                z.drawCube(f.gl, ctr, .{ .size = vec(1, 1, 1), .color = beige });
                z.drawCubeWires(f.gl, ctr, .{ .size = vec(1.001, 1.001, 1.001), .color = wire });
            }
        }
    }
    z.endMode3D(f.gl);

    // ---- 2D crosshair, screen-anchored (drawn after endMode3D) ----
    const cx: f32 = vw * 0.5;
    const cy: f32 = vh * 0.5;
    f.gl.circle(.{ cx, cy }, 5.0, .{ .color = crosshair_red, .segments = 20 });

    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - basic voxel (tap to break)",
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
