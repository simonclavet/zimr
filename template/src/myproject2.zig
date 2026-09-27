//! myproject2 - 3D rotating cube with an ImGui control panel.
//!
//! Demonstrates:
//!   - 3D mode (`z.beginMode3D` / `z.endMode3D`) with a `zm.Camera3D`
//!   - 3D primitives (`z.drawCube`, `z.drawCubeWires`, `z.drawGrid`, `z.drawLine3D`)
//!   - orienting a primitive with a rotation matrix (`CubeDesc.rotation`)
//!   - a 2D HUD drawn after `endMode3D`, back in screen space
//!   - the depth attachment a 3D app opts into (`.depth_format`)
//!
//! Rename this file (and its row in build.zig + its card in public/index.html)
//! to whatever your project actually is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Mat = zm.Mat;
const Vec = zm.Vec;
const radFromDeg = zm.radFromDeg;
const vec = zm.vec;
const colors = z.colors;

/// Wired by zimr's `Project`. zimr ships no default font: text needs one.
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const cube_center_y: f32 = 1.0;
const initial_pitch_deg: f32 = 18;

/// Everything the panel edits. "reset" assigns `.{}`, so the reset values are
/// the defaults by construction and cannot drift apart.
const Tunables = struct {
    spin_yaw_deg_per_s: f32 = 60,
    spin_pitch_deg_per_s: f32 = 0,
    cube_size: f32 = 1.5,
    cube_color: Color = colors.amber_400,
    camera_distance: f32 = 5,
    show_wires: bool = true,
    show_grid: bool = true,
    show_axes: bool = true,
    paused: bool = false,
};

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    yaw_deg: f32 = 0,
    pitch_deg: f32 = initial_pitch_deg,
    tune: Tunables = .{},
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{ .font = font, .ui_host = z.UiHost.init(gpa, font) };
}

fn deinit(gpa: Allocator, s: *State) void {
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

fn drawScene(f: *z.Frame, s: *State) void {
    const cube_center: Vec = zm.pointVec(0, cube_center_y, 0);
    const camera_distance: f32 = s.tune.camera_distance;
    // Aim at the cube itself rather than the origin, so a close camera keeps it framed.
    const camera: zm.Camera3D = .{
        .position = zm.pointVec(camera_distance, camera_distance * 0.8 + cube_center_y, camera_distance),
        .target = cube_center,
        .up = vec(0, 1, 0),
        .fovy_deg = 60,
    };
    z.beginMode3D(f.gl, camera);
    defer z.endMode3D(f.gl);

    if (s.tune.show_grid) {
        z.drawGrid(f.gl, 20, 1.0);
    }
    if (s.tune.show_axes) {
        // Reference axes: red X, green Y, blue Z. Lifted a hair so the grid does not hide them.
        const origin: Vec = zm.pointVec(0, 0.001, 0);
        z.drawLine3D(f.gl, origin, zm.pointVec(2, 0.001, 0), colors.red_500);
        z.drawLine3D(f.gl, origin, zm.pointVec(0, 2, 0), colors.green_500);
        z.drawLine3D(f.gl, origin, zm.pointVec(0, 0.001, 2), colors.sky_500);
    }

    // Pitch is applied first, then yaw.
    const pitch: Mat = zm.matFromAxisAngle(vec(1, 0, 0), radFromDeg(s.pitch_deg));
    const yaw: Mat = zm.matFromAxisAngle(vec(0, 1, 0), radFromDeg(s.yaw_deg));
    const rotation: Mat = zm.compose(pitch, yaw);
    const edge: f32 = s.tune.cube_size;
    z.drawCube(f.gl, cube_center, .{
        .size = vec(edge, edge, edge),
        .rotation = rotation,
        .color = s.tune.cube_color,
    });
    if (s.tune.show_wires) {
        // Slightly larger than the solid so the edges do not z-fight with its faces.
        const wire_edge: f32 = edge * 1.01;
        z.drawCubeWires(f.gl, cube_center, .{
            .size = vec(wire_edge, wire_edge, wire_edge),
            .rotation = rotation,
            .color = colors.white,
        });
    }
}

fn drawPanel(u: z.ui.Ui, f: *z.Frame, s: *State) void {
    // Phone-sized viewports get a wider, larger-text panel; the height follows the content.
    const viewport_width: f32 = f.window.widthf();
    const narrow: bool = z.ui.Ui.isNarrow(viewport_width);
    const panel_width: f32 = if (narrow) @min(340.0, viewport_width - 16.0) else 300.0;
    _ = u.scaleToViewport(panel_width, if (narrow) 30.0 else 22.0);
    u.setNextWindowPos(.{ 8, 8 }, .{ .once = true });
    u.setNextWindowSize(.{ panel_width, 0 }, .{});

    if (u.window("Controls", .{ .flags = .{ .always_auto_resize = true } })) |w| {
        defer w.close();

        u.text("rotation:", .{});
        _ = u.slider("spin yaw (deg/s)", &s.tune.spin_yaw_deg_per_s, .{ .min = -360, .max = 360 });
        _ = u.slider("spin pitch (deg/s)", &s.tune.spin_pitch_deg_per_s, .{ .min = -360, .max = 360 });
        _ = u.checkbox("paused", &s.tune.paused);

        u.spacing();
        u.separator();
        u.text("cube:", .{});
        _ = u.slider("size", &s.tune.cube_size, .{ .min = 0.2, .max = 4.0 });
        _ = u.colorEdit("color", &s.tune.cube_color, .{});
        _ = u.checkbox("wireframe overlay", &s.tune.show_wires);

        u.spacing();
        u.separator();
        u.text("scene:", .{});
        _ = u.slider("camera distance", &s.tune.camera_distance, .{ .min = 2.0, .max = 15.0 });
        _ = u.checkbox("ground grid", &s.tune.show_grid);
        u.sameLine(.{});
        _ = u.checkbox("axes", &s.tune.show_axes);

        u.spacing();
        if (u.button("reset", .{})) {
            s.tune = .{};
            s.yaw_deg = 0;
            s.pitch_deg = initial_pitch_deg;
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    if (!s.tune.paused) {
        const dt: f32 = f.time.delta_time;
        // `@mod` with a positive divisor is never negative, so this also wraps negative spins.
        s.yaw_deg = @mod(s.yaw_deg + s.tune.spin_yaw_deg_per_s * dt, 360.0);
        s.pitch_deg = @mod(s.pitch_deg + s.tune.spin_pitch_deg_per_s * dt, 360.0);
    }

    z.clearViewport(f, colors.slate_950);
    const u: z.ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    drawScene(f, s);

    // ---- 2D HUD, after endMode3D, in screen space ----
    var status_buf: [64]u8 = undefined;
    const status: []const u8 = bufPrint(
        &status_buf,
        "yaw {d:.0} deg   pitch {d:.0} deg   {s}",
        .{ s.yaw_deg, s.pitch_deg, if (s.tune.paused) "PAUSED" else "spinning" },
    ) catch "yaw ?";
    f.gl.text(.{ 12, f.window.heightf() - 28 }, status, .{ .size = 18, .color = colors.slate_400, .font = &s.font });

    drawPanel(u, f, s);
}

/// Descriptor only: zimr's runner opens and closes the frame around `update`.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "myproject2 - 3D cube",
            .width = 900,
            .height = 600,
            .scale_mode = .responsive,
            // 3D draws need a depth attachment; 2D-only apps leave this null.
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
