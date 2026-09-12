//! tesseract_view — raylib's `models_tesseract_view`.
//!
//! A tesseract (4-dimensional hypercube) spinning through the XW plane,
//! projected from 4D down to 3D and drawn as 16 vertices + their edges.
//! The projection is a perspective divide by the 4th coordinate: points
//! with larger w are "closer in 4D" and swell/spread as they rotate
//! through, so the cube appears to turn itself inside-out. Two vertices
//! share an edge when they differ in exactly one of the four coordinates.
//!
//! raylib uses a fixed camera; here you can orbit / pan / zoom it with
//! `z.OrbitCamera` (drag / two-finger / pinch / wheel) — much nicer for
//! studying a 4D object from different angles.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");

const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const pointVec = zm.pointVec;
const rad_per_deg = zm.rad_per_deg;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub var zimr_app: z.App = .{};

const red: Color = .{ .r = 230, .g = 41, .b = 55, .a = 255 };
const maroon: Color = .{ .r = 190, .g = 33, .b = 55, .a = 255 };

/// The 16 corners of a unit tesseract: every (±1, ±1, ±1, ±1).
const corners: [16][4]f32 = .{
    .{ 1, 1, 1, 1 },    .{ 1, 1, 1, -1 },
    .{ 1, 1, -1, 1 },   .{ 1, 1, -1, -1 },
    .{ 1, -1, 1, 1 },   .{ 1, -1, 1, -1 },
    .{ 1, -1, -1, 1 },  .{ 1, -1, -1, -1 },
    .{ -1, 1, 1, 1 },   .{ -1, 1, 1, -1 },
    .{ -1, 1, -1, 1 },  .{ -1, 1, -1, -1 },
    .{ -1, -1, 1, 1 },  .{ -1, -1, 1, -1 },
    .{ -1, -1, -1, 1 }, .{ -1, -1, -1, -1 },
};

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22);
    var cam: z.OrbitCamera = z.OrbitCamera.init(pointVec(0, 0, 0), 7.0);
    cam.yaw = 0.9;
    cam.pitch = 0.6;
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        .cam = cam,
    };
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, common.palette.bg);

    const u: z.ui_real.Ui = s.ui_host.begin(f);
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 3.0,
        .max_distance = 24.0,
        .fovy_deg = 50.0,
    });

    // ---- rotate the 4D points through the XW plane, then project to 3D ----
    const rot: f32 = rad_per_deg * 45.0 * f.time.time;
    const cr: f32 = @cos(rot);
    const sr: f32 = @sin(rot);
    var proj: [16]Vec = undefined;
    var w_vals: [16]f32 = undefined;
    for (corners, 0..) |c, i| {
        // Rotate the (x, w) pair; leave y, z.
        const x: f32 = c[0] * cr - c[3] * sr;
        const w: f32 = c[0] * sr + c[3] * cr;
        // 4D→3D perspective divide: points with larger w spread out.
        const k: f32 = 3.0 / (3.0 - w);
        proj[i] = pointVec(k * x, k * c[1], k * c[2]);
        w_vals[i] = w;
    }

    // ---- draw: a vertex sphere per corner, an edge per single-axis pair ----
    z.beginMode3D(f.gl, cam);
    for (proj, 0..) |p, i| {
        z.drawSphere(f.gl, p, .{ .radius = @abs(w_vals[i]) * 0.1, .color = red });
        // Edge iff exactly one of the four ORIGINAL coordinates differs.
        var j: usize = i + 1;
        while (j < 16) : (j += 1) {
            var same: u32 = 0;
            inline for (0..4) |k| {
                if (corners[i][k] == corners[j][k]) same += 1;
            }
            if (same == 3) {
                z.drawLine3D(f.gl, p, proj[j], maroon);
            }
        }
    }
    z.endMode3D(f.gl);

    // ---- HUD ----
    const hint: []const u8 = "a tesseract (4D hypercube) rotating through the XW plane";
    f.gl.text(.{ 14, 42 }, hint, .{ .size = 18, .color = common.palette.ink_dim, .font = &s.font });
    common.caption(f.gl, s.font, "WebGPU 3D - tesseract view (drag / pinch to orbit)");
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - tesseract view",
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
