//! camera_controls — a demo of the shared `z.OrbitCamera` controller.
//!
//! A small scene of colored cubes on a grid that you can fully navigate
//! with one controller doing all three moves, on mouse AND touch:
//!   * ORBIT — drag with one finger / the left mouse button.
//!   * PAN   — drag with two fingers / the right (or middle) mouse button.
//!   * ZOOM  — pinch / the mouse wheel.
//! The camera is gated on the UI, so dragging the reset button never
//! spins the scene. This is the reference for how any 3D example should
//! take input now — no more hand-rolled orbit math per demo.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;

const Camera3D = zm.Camera3D;
const Color = zm.Color;
const pointVec = zm.pointVec;
const vec = zm.vec;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

pub var zimr_app: z.App = .{};

const grid_n: i32 = 5;

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
    s.* = .{
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
        // Look at the origin from ~14 units away at a 3/4 angle.
        .cam = z.OrbitCamera.init(pointVec(0, 0, 0), 14.0),
    };
}

fn update(f: *z.Frame, s: *State) void {
    const vw: f32 = @max(f.window.widthf(), 1);
    const vh: f32 = @max(f.window.heightf(), 1);
    z.clearViewport(f, common.palette.bg);

    // ---- UI first (so wantCaptureMouse reflects this frame) ----
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    u.setNextWindowPos(.{ 8, vh - 66 }, .{});
    u.setNextWindowSize(.{ @min(220, vw - 16), 58 }, .{});
    if (u.window("camera", .{})) |w| {
        defer w.close();
        if (u.button("reset view", .{})) {
            s.cam = z.OrbitCamera.init(pointVec(0, 0, 0), 14.0);
        }
    }

    // ---- the one line that replaces every demo's orbit boilerplate ----
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 3.0,
        .max_distance = 60.0,
    });

    // ---- scene: a checkerboard of colored cubes ----
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 1.0);
    var gx: i32 = -grid_n;
    while (gx <= grid_n) : (gx += 2) {
        var gz: i32 = -grid_n;
        while (gz <= grid_n) : (gz += 2) {
            const h: f32 = @mod(float(gx * 7 + gz * 13 + 200), 360.0);
            const col: Color = z.colorFromHSV(h, 0.65, 0.95);
            const fy: f32 = 0.5 + 0.25 * @sin(f.time.time + float(gx + gz));
            z.drawCube(f.gl, pointVec(float(gx), fy, float(gz)), .{
                .size = vec(1, 1 + fy, 1),
                .color = col,
            });
        }
    }
    z.endMode3D(f.gl);

    // ---- HUD ----
    const hint: []const u8 = "drag = orbit   2-finger/right = pan   pinch/wheel = zoom";
    f.gl.text(.{ 14, 42 }, hint, .{ .size = 18, .color = common.palette.ink_dim, .font = &s.font });
    common.caption(f.gl, s.font, "WebGPU 3D - orbit / pan / zoom camera controller");
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - camera controls",
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
