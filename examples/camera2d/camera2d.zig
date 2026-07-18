//! camera2d — the Camera2D pan / zoom / rotate transform, ported to WebGPU. A world
//! scene (grid + landmark shapes + origin marker) is viewed through a Camera2D whose
//! target pans on a Lissajous path, zoom breathes, and rotation slowly turns — exercising
//! the full 2D camera (offset / target / zoom / rotation) via `beginMode2D`. The GL
//! original was mouse-driven; this animates itself. Viewport-relative under `.responsive`.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;
const Camera2D = zm.Camera2D;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;

const State = struct {
    font: z.Font,
    frame_count: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

/// Draw the fixed world scene (world coordinates; the camera transforms it).
fn drawWorld(gl: anytype) void {
    const grid: Color = c.init(40, 44, 54, 255);
    var g: i32 = -400;
    while (g <= 400) : (g += 50) {
        const v: f32 = float(g);
        gl.line(.{ v, -400.0 }, .{ v, 400.0 }, .{ .color = grid, .thickness = 1.0 });
        gl.line(.{ -400.0, v }, .{ 400.0, v }, .{ .color = grid, .thickness = 1.0 });
    }
    const axis: Color = c.init(80, 86, 100, 255);
    gl.line(.{ -400.0, 0.0 }, .{ 400.0, 0.0 }, .{ .color = axis, .thickness = 1.0 });
    gl.line(.{ 0.0, -400.0 }, .{ 0.0, 400.0 }, .{ .color = axis, .thickness = 1.0 });

    gl.rect(.{ .x = -170, .y = -130, .width = 80, .height = 80 }, .{ .color = c.init(235, 90, 90, 255) });
    gl.rect(.{ .x = 100, .y = -150, .width = 64, .height = 64 }, .{ .color = c.init(90, 200, 130, 255) });
    gl.circle(.{ 165, 120 }, 42.0, .{ .color = c.init(90, 150, 235, 255), .segments = 16 });
    gl.circle(.{ -150, 140 }, 32.0, .{ .color = c.init(235, 200, 90, 255), .segments = 16 });
    gl.circle(.{ 0, 0 }, 8.0, .{ .color = c.init(245, 248, 252, 255), .segments = 16 });
}

fn update(f: *z.Frame, s: *State) void {
    s.frame_count += 1;
    const t: f32 = f.time.time;
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();

    const cam: Camera2D = .{
        .target = .{ @cos(t * 0.3) * 120.0, @sin(t * 0.4) * 120.0 },
        .offset = .{ w * 0.5, h * 0.5 },
        .rotation = t * 10.0,
        .zoom = 1.0 + @sin(t * 0.5) * 0.35,
    };

    z.clearViewport(f, c.init(12, 14, 20, 255));
    z.beginMode2D(f.gl, cam);
    drawWorld(f.gl);
    z.endMode2D(f.gl);

    var buf: [56]u8 = undefined;
    const lbl: []const u8 = bufPrint(
        &buf,
        "Camera2D  zoom {d:.2}  rot {d:.0}",
        .{ cam.zoom, @mod(cam.rotation, 360.0) },
    ) catch "?";
    f.gl.text(.{ 12, 12 }, lbl, .{ .size = 16, .color = c.init(210, 214, 224, 230), .font = &s.font });
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - camera2d",
            .width = 800,
            .height = 450,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
