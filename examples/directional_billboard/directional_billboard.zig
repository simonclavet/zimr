//! directional_billboard - raylib's `models_directional_billboard`.
//!
//! A character sprite that (a) always faces the camera as a flat billboard
//! and (b) picks its frame from a sprite ATLAS by the camera's angle around
//! it - an 8-direction sprite, like the enemies in Doom: orbit the scene
//! and you see the robot's front, side, back, etc. A second axis of the
//! atlas is a 4-frame walk cycle advancing over time.
//!
//! raylib loads `skillbot.png`; standalones can't fetch external files, so
//! the atlas here is generated procedurally (8 rows x 4 columns of a little
//! directional robot). The engine addition this drove is a source-rect +
//! anchor billboard (`z.drawBillboardRec`, raylib's `DrawBillboardPro`), so
//! a billboard can frame one atlas cell and plant its feet on the ground.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const sinTurns = zm.sinTurns;

const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const pointVec = zm.pointVec;
const pi = zm.pi;
const atan2Rad = zm.atan2Rad;
const bufPrint = std.fmt.bufPrint;
const float = zm.float;
const clamp = zm.clamp;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub var zimr_app: z.App = .{};

const dirs: u32 = 8; // atlas rows: 8 view directions
const anims: u32 = 4; // atlas columns: 4 walk-cycle frames
const cell: u32 = 32; // pixels per atlas cell

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    atlas: z.WgpuTexture,
    anim: u32 = 0,
    anim_timer: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.atlas.deinit();
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    const img: z.Image = try makeAtlas(gpa);
    const atlas: z.WgpuTexture = z.loadTextureFromImage(f.gl, img);
    defer z.unloadImage(gpa, img);
    var cam: z.OrbitCamera = z.OrbitCamera.init(pointVec(0, 0.5, 0), 4.0);
    cam.yaw = 0.8;
    cam.pitch = 0.35;
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .cam = cam,
        .atlas = atlas,
    };
}

/// Build the 4x8 procedural sprite atlas: for each (direction, frame) cell,
/// draw a simple robot whose body orientation and a walk-bob depend on the cell.
fn makeAtlas(gpa: Allocator) !z.Image {
    const w: u32 = anims * cell;
    const h: u32 = dirs * cell;
    const img: z.Image = try z.genImageColor(gpa, @intCast(w), @intCast(h), .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const px: [*]u8 = @ptrCast(img.data.?);

    var d: u32 = 0;
    while (d < dirs) : (d += 1) {
        // Facing angle for this row (0 = toward viewer, sweeping around).
        const facing: f32 = 2.0 * pi * float(d) / float(dirs);
        // How much we see the "front" of the robot (1 = front, -1 = back).
        const frontness: f32 = @cos(facing);
        var a: u32 = 0;
        while (a < anims) : (a += 1) {
            // Walk bob: legs swing, body lifts a touch, per frame.
            const swing: f32 = sinTurns(float(a) / float(anims));
            paintRobot(px, w, a * cell, d * cell, frontness, swing);
        }
    }
    return img;
}

/// Paint one robot cell at pixel offset (ox, oy). `frontness` in [-1,1] shades
/// the "face" (front) brighter than the "back"; `swing` in [-1,1] offsets legs.
fn paintRobot(
    px: [*]u8,
    atlas_w: u32,
    ox: u32,
    oy: u32,
    frontness: f32,
    swing: f32,
) void {
    const cf: f32 = float(cell);
    var y: u32 = 0;
    while (y < cell) : (y += 1) {
        var x: u32 = 0;
        while (x < cell) : (x += 1) {
            const u: f32 = (float(x) + 0.5) / cf; // 0..1 across
            const v: f32 = (float(y) + 0.5) / cf; // 0..1 down
            var col: ?[3]u8 = null;

            // Head: circle near the top-center.
            if (inDisc(u, v, 0.5, 0.28, 0.16)) {
                const shade: u8 = @round(150.0 + 60.0 * clamp(frontness, -1, 1));
                col = .{ shade, shade, @min(@as(u8, 255), shade + 40) };
                // A darker visor band only on front-ish views.
                if (frontness > 0.2 and v > 0.24 and v < 0.30) {
                    col = .{ 30, 40, 60 };
                }
            }
            // Body: rounded rectangle in the middle.
            else if (u > 0.34 and u < 0.66 and v > 0.42 and v < 0.72) {
                const shade: u8 = @round(90.0 + 70.0 * clamp(0.5 + 0.5 * frontness, 0, 1));
                col = .{ shade, @min(@as(u8, 255), shade + 30), 200 };
            }
            // Legs: two bars at the bottom, offset by the walk swing.
            else if (v > 0.72 and v < 0.95) {
                const off: f32 = 0.05 * swing;
                const left: bool = u > 0.38 + off and u < 0.48 + off;
                const right: bool = u > 0.52 - off and u < 0.62 - off;
                if (left or right) {
                    col = .{ 70, 80, 110 };
                }
            }

            if (col) |c| {
                const gx: u32 = ox + x;
                const gy: u32 = oy + y;
                const i: usize = (@as(usize, gy) * atlas_w + gx) * 4;
                px[i + 0] = c[0];
                px[i + 1] = c[1];
                px[i + 2] = c[2];
                px[i + 3] = 255;
            }
        }
    }
}

fn inDisc(u: f32, v: f32, cx: f32, cy: f32, r: f32) bool {
    const dx: f32 = u - cx;
    const dy: f32 = v - cy;
    return dx * dx + dy * dy <= r * r;
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, common.palette.bg);

    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 2.0,
        .max_distance = 14.0,
        .fovy_deg = 45.0,
    });

    // ---- advance the walk-cycle frame ----
    s.anim_timer += @floatCast(f.time.delta_time);
    if (s.anim_timer > 0.16) {
        s.anim_timer = 0;
        s.anim = (s.anim + 1) % anims;
    }

    // ---- pick the DIRECTION row from the camera's angle around the sprite ----
    const cp: Vec = cam.position;
    // Angle of the camera in the ground plane, relative to +X.
    const view_ang: f32 = atan2Rad(cp[2], cp[0]);
    // Map to [0, dirs) and round to the nearest row.
    var dir_f: f32 = view_ang / (2.0 * pi) * float(dirs);
    dir_f = @mod(dir_f + float(dirs), float(dirs));
    // Round to the nearest row, then wrap: @round of a value near dirs-0.5 can
    // land on `dirs` itself, which is one past the last row.
    const dir_rounded: u32 = @round(@mod(dir_f, float(dirs)));
    const dir: u32 = dir_rounded % dirs;

    // ---- camera basis for the billboard quad ----
    const ct: Vec = cam.target;
    const fwd: [3]f32 = norm3(.{ ct[0] - cp[0], ct[1] - cp[1], ct[2] - cp[2] });
    const right: [3]f32 = norm3(cross3(fwd, .{ 0, 1, 0 }));
    const bup: [3]f32 = cross3(right, fwd);

    // ---- UV sub-rect of the chosen atlas cell ----
    const uv_min: [2]f32 = .{ float(s.anim) / float(anims), float(dir) / float(dirs) };
    const uv_max: [2]f32 = .{ float(s.anim + 1) / float(anims), float(dir + 1) / float(dirs) };

    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 10, 1.0);
    // Feet on the ground: anchor {0.5, 0} plants the bottom edge on y=0.
    z.drawBillboardRec(
        f.gl,
        s.atlas,
        right,
        bup,
        pointVec(0, 0, 0),
        1.5,
        1.5,
        uv_min,
        uv_max,
        .{ 0.5, 0.0 },
        .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    );
    z.endMode3D(f.gl);

    // ---- HUD ----
    var buf: [64]u8 = undefined;
    const hud: []const u8 = bufPrint(&buf, "direction row: {d}   walk frame: {d}", .{ dir, s.anim }) catch "";
    f.gl.text(.{ 14, 42 }, hud, .{ .size = 18, .color = common.palette.ink_dim, .font = &s.font });
    common.caption(f.gl, s.font, "WebGPU 3D - directional billboard (orbit to see other sides)");
    s.ui_host.render(f);
}

fn norm3(v: [3]f32) [3]f32 {
    const l: f32 = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l < 1.0e-6) {
        return .{ 0, 0, 1 };
    }
    return .{ v[0] / l, v[1] / l, v[2] / l };
}

fn cross3(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - directional billboard",
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
};
