// examples/shapes_demo/shapes_demo.zig
//
// The first 2D drawing demo on WebGPU, in the standard zimr AppBridge form.
// This is N5a's gate (wgpu_new_beginnings.md): it drives the `WgpuGl` adapter
// (f.gl) through z.beginDrawing / z.drawRectangle / z.drawCircle — the SAME
// free-function shape as a GL example — proving WgpuGl renders real 2D geometry
// on-screen (which retires N4's "visual pending"). No 3D, no pbr3d.
//
// Build:      zig build wgpu-shapes
// Standalone: zig build wgpu-shapes-standalone

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const float = zm.float;
const int = zm.int;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

// lint:off module-var: the app-bridge instance, the one sanctioned wasm entry-point handle

const State = struct {
    t: f32,
    // A checkerboard texture, drawn via the textured-2D path (N5e).
    checker: z.WgpuTexture,
    // A baked font, rendered via the text path (N5f).
    font: z.Font,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.checker.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    // Upload a checkerboard texture to exercise the textured-2D path (N5e).
    const checker: z.WgpuTexture = try z.WgpuTexture.createCheckerboard(
        f.gpu.device,
        f.gpu.queue,
        gpa,
        .{ 0xff, 0xff, 0xff, 0xff },
        .{ 0xff, 0x66, 0x00, 0xff },
        64,
        8,
    );
    // Bake + upload a font (N5f).
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 32);
    s.* = .{ .t = 0, .checker = checker, .font = font };
}

/// Clamp a float color expression to a valid u8 (avoids the @intFromFloat trap
/// on a possibly-negative or >255 expression — the wart the blog flagged).
fn clampColor(v: f32) u8 {
    return int(u8, clamp(v, 0.0, 255.0));
}

fn update(f: *z.Frame, s: *State) void {
    s.t = f.time.time;

    // Input (N5d): cursor position + whether the left button is down.
    const mouse: Vec2 = z.getMousePosition(f.input);
    const pressed: bool = z.isMouseButtonDown(f.input, .left);

    z.clearViewport(f, .{ .r = 18, .g = 18, .b = 26, .a = 255 });

    // A row of rectangles; they brighten while the mouse button is held.
    const lift: u8 = if (pressed) 60 else 0;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const fi: f32 = float(i);
        const x: f32 = 60 + fi * 140;
        const y: f32 = 80 + 30 * @sin(s.t * 2 + fi);
        f.gl.rect(.{ .x = x, .y = y, .width = 100, .height = 100 }, .{ .color = .{
            .r = clampColor(120 + 120 * @sin(s.t + fi) + float(lift)),
            .g = 80,
            .b = clampColor(120 + 120 * @cos(s.t + fi)),
            .a = 255,
        } });
    }

    // Circles bobbing along the bottom.
    var j: u32 = 0;
    while (j < 6) : (j += 1) {
        const fj: f32 = float(j);
        const cx: f32 = 80 + fj * 130;
        const cy: f32 = 400 + 50 * @cos(s.t * 1.5 + fj);
        f.gl.circle(.{ cx, cy }, 45, .{ .color = .{ .r = 80, .g = 200, .b = 220, .a = 255 }, .segments = 32 });
    }

    // A checkerboard texture (the N5e textured-2D proof), gently scaling,
    // CLIPPED by a scissor rect (N5g) so its bottom-right is cut off.
    const ts: f32 = 180 + 20 * @sin(s.t);
    z.beginScissorMode(f.gl, 540, 220, 130, 130);
    f.gl.texture(
        .{ .x = 540, .y = 220, .width = ts, .height = ts },
        s.checker,
        .{ .tint = .{ .r = 255, .g = 255, .b = 255, .a = 255 } },
    );
    z.endScissorMode(f.gl);

    // A cursor-following circle (the input proof): red while pressed.
    f.gl.circle(mouse, 24, .{ .color = if (pressed)
        .{ .r = 240, .g = 80, .b = 80, .a = 255 }
    else
        .{ .r = 240, .g = 220, .b = 120, .a = 255 }, .segments = 24 });

    // Text (N5f): a title + a live frame counter, drawn through the reusable
    // glyph-quad path. Dark text on the white canvas.
    f.gl.text(
        .{ 40, 20 },
        "zimr WebGPU - text works",
        .{ .size = 32, .color = .{ .r = 20, .g = 20, .b = 30, .a = 255 }, .font = &s.font },
    );
    var buf: [64]u8 = undefined;
    const fps_label: []const u8 = bufPrint(&buf, "frame {d}", .{f.time.frame_count}) catch "frame ?";
    f.gl.text(
        .{ 40, 540 },
        fps_label,
        .{ .size = 24, .color = .{ .r = 60, .g = 90, .b = 160, .a = 255 }, .font = &s.font },
    );

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - 2D shapes (WgpuGl)",
            .width = 800,
            .height = 600,
            // .fit: a fixed 800x600 design space scaled+letterboxed to the
            // canvas, so the demo looks identical across browsers/devices
            // regardless of how the host sizes the canvas.
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
