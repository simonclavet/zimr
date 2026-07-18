//! textures_sprite_stacking — port of raylib [textures] example, zimr-ified.
//! booth.png is a vertical sheet of 122 horizontal cross-sections of a 3D
//! model. We render each slice as a fixed horizontal textured quad stacked in
//! world Y (via drawBillboardRec with explicit right/up so the quads DON'T face
//! the camera), then view the whole stack with the shared orbit camera — drag
//! to orbit, wheel/pinch to zoom, exactly like the raytracer example. A UI
//! slider controls the vertical separation between slices.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const c = Color;
const Vec = zm.Vec;
const vec = zm.vec;
const Camera3D = zm.Camera3D;

const booth_png = @embedFile("booth.png");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const stack_count: u32 = 122;
const slice_width: f32 = 2.0; // world-space width of a slice quad

// Shared orbit-camera tuning (mirrors rt_sidebyside's feel).
const orbit_opts: z.OrbitOptions = .{
    .orbit_sensitivity = 0.006,
    .min_distance = 3.0,
    .max_distance = 30.0,
    .fovy_deg = 45.0,
};

const State = struct {
    tex: z.WgpuTexture,
    cam: z.OrbitCamera,
    ui_host: z.UiHost,
    font: z.Font,
    ui_wanted_mouse: bool = false,
    separation: f32 = 2.0, // slider units; scaled to world Y below
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    s.tex.deinit();
}

/// booth.png is 112x11468 - taller than the 8192-per-side GPU texture limit.
/// Scale the sheet down to the largest height that both fits and still divides
/// evenly into `stack_count` slices (so each slice stays pixel-aligned),
/// preserving aspect, before uploading.
fn loadStackSheet(gpa: Allocator, gl: *z.WgpuGl, png: []const u8) !z.WgpuTexture {
    var img: z.Image = try z.loadImageFromMemory(gpa, png);
    defer z.unloadImage(gpa, img);
    const max_side: i32 = 8192;
    if (img.height > max_side) {
        const count: i32 = @intCast(stack_count);
        const fit_h: i32 = count * @divFloor(max_side, count); // largest multiple of 122 <= 8192
        const fit_w: i32 = @max(1, @divFloor(img.width * fit_h, img.height));
        try z.imageResize(gpa, &img, fit_w, fit_h);
    }
    return z.loadTextureFromImage(gl, img);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 18);
    s.* = .{
        .tex = try loadStackSheet(gpa, f.gl, booth_png),
        .cam = .{ .target = vec(0, 0, 0), .distance = 9.0, .pitch = 1.0, .yaw = -0.6 + std.math.pi },
        .font = font,
        .ui_host = z.UiHost.init(gpa, font),
    };
}

fn update(f: *z.Frame, s: *State) void {
    // Orbit camera reads the drag/wheel itself; gated on last frame's UI capture.
    const cam3d: Camera3D = s.cam.update(f, s.ui_wanted_mouse, orbit_opts);

    z.beginDrawing(f.gl);
    z.clearViewport(f, c.black);

    z.beginMode3D(f.gl, cam3d);
    const count_f: f32 = float(stack_count);
    const aspect: f32 = (float(s.tex.height) / count_f) / float(s.tex.width); // sliceH/sliceW
    const slice_depth: f32 = slice_width * aspect; // extent along the up axis (world Z)
    const sep: f32 = s.separation * 0.01; // slider units -> world Y per slice
    const right = [3]f32{ 1, 0, 0 }; // quad lies flat in the XZ plane...
    const up = [3]f32{ 0, 0, 1 }; // ...so slices stack cleanly along world Y

    // Draw back-to-front (top slice first): drawBillboardRec uses the depth-
    // tested-but-not-depth-writing billboard pipeline, so nearer slices must be
    // painted last to composite correctly from this top-down view.
    var idx: u32 = stack_count;
    while (idx > 0) {
        idx -= 1;
        const fi: f32 = float(idx);
        const y: f32 = (count_f * 0.5 - fi) * sep; // slice 0 at top -> model upright
        const pos: Vec = vec(0, y, 0);
        const v0: f32 = fi / count_f;
        const v1: f32 = (fi + 1.0) / count_f;
        z.drawBillboardRec(
            f.gl,
            s.tex,
            right,
            up,
            pos,
            slice_width,
            slice_depth,
            .{ 1, v0 }, // U swapped -> mirror each slice horizontally (un-mirror model)
            .{ 0, v1 },
            .{ 0.5, 0.5 },
            c.white,
        );
    }
    z.endMode3D(f.gl);

    // ---- UI: separation slider + hint --------------------------------------
    const ui: z.ui_real.Ui = s.ui_host.begin(f);
    ui.ctx.style.window_bg = .{ .r = 15, .g = 15, .b = 15, .a = 255 }; // opaque panel
    if (ui.window("Sprite stacking", .{ .initial_pos = .{ 10, 10 }, .initial_size = .{ 250, 110 } })) |w| {
        defer w.close();
        ui.text("drag: orbit, wheel: zoom", .{});
        _ = ui.slider("Separation", &s.separation, .{ .min = 0.0, .max = 5.0, .fmt = "{d:.2}" });
    }
    s.ui_wanted_mouse = ui.wantCaptureMouse();
    s.ui_host.render(f);

    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{ .window = .{
        .title = "zimr - WebGPU - textures sprite stacking",
        .width = 800,
        .height = 450,
        .scale_mode = .responsive,
        .depth_format = .depth24_plus,
    } },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
    .manages_own_frame = true,
};
