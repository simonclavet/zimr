//! rectangle_scaling — drag the bottom-right handle to live-resize a rectangle. Three
//! states: idle, ready (pointer over the handle → outline + corner marker appear), and
//! dragging (the corner tracks the pointer until release). Ported from raylib
//! shapes_rectangle_scaling; touch-draggable on mobile. Themed with the shared scaffold.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const co = @import("example_common");

const Vec2 = zm.Vec2;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const handle_size: f32 = 16;

const State = struct {
    font: z.Font,
    rec: z.Rectangle = .{ .x = 120, .y = 120, .width = 240, .height = 120 },
    ready: bool = false,
    dragging: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, roboto_mono_ttf, 24) };
}

fn update(f: *z.Frame, s: *State) void {
    const w: f32 = f.window.widthf();
    const h: f32 = f.window.heightf();
    const mouse: Vec2 = z.getMousePosition(f.input);

    const handle: z.Rectangle = .{
        .x = s.rec.x + s.rec.width - handle_size,
        .y = s.rec.y + s.rec.height - handle_size,
        .width = handle_size,
        .height = handle_size,
    };
    if (z.checkCollisionPointRec(mouse, handle)) {
        s.ready = true;
        if (z.isMouseButtonPressed(f.input, .left)) {
            s.dragging = true;
        }
    } else {
        s.ready = false;
    }
    if (s.dragging) {
        s.ready = true;
        s.rec.width = @max(handle_size, @min(mouse[0] - s.rec.x, w - s.rec.x));
        s.rec.height = @max(handle_size, @min(mouse[1] - s.rec.y, h - s.rec.y));
        if (z.isMouseButtonReleased(f.input, .left)) {
            s.dragging = false;
        }
    }

    z.clearViewport(f, co.palette.bg);
    co.backdrop(f.gl, w, h);

    f.gl.rect(s.rec, .{ .color = co.palette.accent.fade(0.45) });
    if (s.ready) {
        f.gl.rect(
            .{ .x = s.rec.x, .y = s.rec.y, .width = s.rec.width, .height = s.rec.height },
            .{ .color = co.palette.accent2, .outline = 1.0 },
        );
        const bx: f32 = s.rec.x + s.rec.width;
        const by: f32 = s.rec.y + s.rec.height;
        f.gl.triangle(
            .{ bx - handle_size, by },
            .{ bx, by },
            .{ bx, by - handle_size },
            .{ .color = co.palette.accent2 },
        );
    }

    co.caption(f.gl, s.font, "rectangle scaling: drag the bottom-right corner");
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - rectangle scaling",
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
