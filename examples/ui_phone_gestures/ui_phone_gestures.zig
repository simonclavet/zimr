//! ui_phone_gestures — port of the GL `ui_phone_gestures`: a touch
//! playground exercising the three core phone gestures against the wgpu input
//! state. TAP (four targets, rising-edge press tested against the landing
//! point so a finger that drifts after touchstart still counts), DRAG (a handle
//! that pins to the finger while held), and SWIPE (a scissor-clipped list that
//! scrolls with the drag delta). Pure manual drawing + raw mouse/touch input
//! (`f.input.mouse.press_position`/`current_button`, `getMousePosition`) — no
//! UI widgets, so hover is computed directly rather than via a UiHost.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;

const clamp = zm.clamp;
const float = zm.float;
const Color = zm.Color;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const bg: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };
const panel: Color = .{ .r = 30, .g = 41, .b = 59, .a = 255 };
const panel_hi: Color = .{ .r = 51, .g = 65, .b = 85, .a = 255 };
const panel_lo: Color = .{ .r = 15, .g = 23, .b = 42, .a = 255 };
const accent: Color = .{ .r = 14, .g = 165, .b = 233, .a = 255 };
const accent_hi: Color = .{ .r = 56, .g = 189, .b = 248, .a = 255 };
const white: Color = .{ .r = 241, .g = 245, .b = 249, .a = 255 };
const dim: Color = .{ .r = 148, .g = 163, .b = 184, .a = 255 };

const tap_size: f32 = 64;
const gap: f32 = 12;
const handle_size: f32 = 96;

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    tap_counts: [4]u32 = .{ 0, 0, 0, 0 },
    drag_pos: Vec2 = .{ 60, 360 },
    drag_offset: Vec2 = .{ 0, 0 },
    drag_active: bool = false,
    swipe_scroll: f32 = 0,
    last_swipe_y: f32 = 0,
    swipe_active: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24),
        .scratch = std.heap.ArenaAllocator.init(gpa),
    };
}

fn inRect(px: f32, py: f32, r: z.Rectangle) bool {
    return px >= r.x and px < r.x + r.width and py >= r.y and py < r.y + r.height;
}

fn update(f: *z.Frame, s: *State) void {
    _ = s.scratch.reset(.retain_capacity);
    const a: Allocator = s.scratch.allocator();
    z.clearViewport(f, bg);

    const w: f32 = f.window.widthf();
    const mouse: Vec2 = z.getMousePosition(f.input);
    const left_pressed: bool = z.isMouseButtonPressed(f.input, .left);
    const left_down: bool = f.input.mouse.current_button[0] != 0;
    const press_x: f32 = f.input.mouse.press_position[0][0];
    const press_y: f32 = f.input.mouse.press_position[0][1];

    f.gl.text(.{ 16, 16 }, "phone gestures", .{ .size = 24, .color = white, .font = &s.font });
    f.gl.text(.{ 16, 46 }, "tap, drag, swipe", .{ .size = 14, .color = dim, .font = &s.font });

    // ---- TAP: four targets, count rising-edge presses that LANDED here ----
    f.gl.text(.{ 16, 84 }, "1. TAP - touch each square", .{ .size = 16, .color = accent_hi, .font = &s.font });
    const tap_y: f32 = 110;
    const tap_pad: f32 = 16;
    const tap_w: f32 = (w - tap_pad * 2 - gap * 3) / 4;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const x: f32 = tap_pad + (tap_w + gap) * float(i);
        const rect: z.Rectangle = .{ .x = x, .y = tap_y, .width = tap_w, .height = tap_size };
        const hovered: bool = inRect(mouse[0], mouse[1], rect);
        if (left_pressed and inRect(press_x, press_y, rect)) {
            s.tap_counts[i] += 1;
        }
        f.gl.rect(rect, .{ .color = if (hovered) accent_hi else accent });
        const num: []const u8 = allocPrint(a, "{d}", .{s.tap_counts[i]}) catch "?";
        f.gl.text(
            .{ x + tap_w / 2 - float(num.len) * 6, tap_y + 22 },
            num,
            .{ .size = 20, .color = white, .font = &s.font },
        );
    }

    // ---- DRAG: a handle that pins to the finger while held ----
    f.gl.text(.{ 16, 200 }, "2. DRAG - slide the orange handle", .{ .size = 16, .color = accent_hi, .font = &s.font });
    const drag_area: z.Rectangle = .{ .x = 16, .y = 226, .width = w - 32, .height = 120 };
    f.gl.rect(drag_area, .{ .color = panel });
    s.drag_pos[0] = clamp(s.drag_pos[0], drag_area.x, drag_area.x + drag_area.width - handle_size);
    s.drag_pos[1] = clamp(s.drag_pos[1], drag_area.y, drag_area.y + drag_area.height - handle_size);
    const handle: z.Rectangle = .{
        .x = s.drag_pos[0],
        .y = s.drag_pos[1],
        .width = handle_size,
        .height = handle_size,
    };
    if (left_pressed and inRect(press_x, press_y, handle)) {
        s.drag_active = true;
        s.drag_offset[0] = press_x - handle.x;
        s.drag_offset[1] = press_y - handle.y;
    }
    if (!left_down) {
        s.drag_active = false;
    }
    if (s.drag_active) {
        s.drag_pos[0] = mouse[0] - s.drag_offset[0];
        s.drag_pos[1] = mouse[1] - s.drag_offset[1];
    }
    const handle_fill: Color = if (s.drag_active)
        .{ .r = 251, .g = 191, .b = 36, .a = 255 }
    else
        .{ .r = 245, .g = 158, .b = 11, .a = 255 };
    f.gl.rect(handle, .{ .color = handle_fill });
    f.gl.text(.{ s.drag_pos[0] + 20, s.drag_pos[1] + 38 }, "drag", .{ .size = 16, .color = bg, .font = &s.font });

    // ---- SWIPE: a scissor-clipped list that fills the rest of the screen ----
    f.gl.text(
        .{ 16, 366 },
        "3. SWIPE - drag inside the list to scroll",
        .{ .size = 16, .color = accent_hi, .font = &s.font },
    );
    const swipe_y: f32 = 392;
    // Fill down to just above the status line (the design height is fixed via
    // .fit, so this is deterministic — the list uses all remaining space).
    const swipe_h: f32 = f.window.heightf() - swipe_y - 34;
    if (swipe_h >= 40) {
        const swipe_rect: z.Rectangle = .{ .x = 16, .y = swipe_y, .width = w - 32, .height = swipe_h };
        f.gl.rect(swipe_rect, .{ .color = panel });
        if (left_pressed and inRect(press_x, press_y, swipe_rect)) {
            s.swipe_active = true;
            s.last_swipe_y = mouse[1];
        }
        if (!left_down) {
            s.swipe_active = false;
        }
        if (s.swipe_active) {
            s.swipe_scroll += mouse[1] - s.last_swipe_y;
            s.last_swipe_y = mouse[1];
        }
        const total_content: f32 = 20 * 56;
        s.swipe_scroll = clamp(s.swipe_scroll, -(total_content - swipe_h), 0);

        z.beginScissorMode(f.gl, swipe_rect.x, swipe_rect.y, swipe_rect.width, swipe_rect.height);
        var row: usize = 0;
        while (row < 20) : (row += 1) {
            const ry: f32 = swipe_y + s.swipe_scroll + float(row) * 56;
            if (ry > swipe_y + swipe_h or ry + 56 < swipe_y) {
                continue;
            }
            const row_rect: z.Rectangle = .{
                .x = swipe_rect.x + 6,
                .y = ry + 4,
                .width = swipe_rect.width - 12,
                .height = 48,
            };
            f.gl.rect(row_rect, .{ .color = if (row % 2 == 0) panel_hi else panel_lo });
            const text: []const u8 = allocPrint(a, "row {d:>2} - item label", .{row}) catch "?";
            f.gl.text(.{ row_rect.x + 16, row_rect.y + 16 }, text, .{ .size = 16, .color = white, .font = &s.font });
        }
        z.endScissorMode(f.gl);

        const status: []const u8 = allocPrint(
            a,
            "canvas {d:.0}x{d:.0}  pos:({d:.0},{d:.0})  drag:{s} swipe:{s}",
            .{
                w,
                f.window.heightf(),
                mouse[0],
                mouse[1],
                if (s.drag_active) "Y" else "n",
                if (s.swipe_active) "Y" else "n",
            },
        ) catch "status";
        f.gl.text(.{ 16, swipe_y + swipe_h + 8 }, status, .{ .size = 12, .color = dim, .font = &s.font });
    }
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - phone gestures",
            // .fit: a FIXED design space (9:16 portrait) uniformly scaled +
            // centered into the canvas. The standalone canvas uses the SAME
            // 9:16 aspect-ratio (CSS), so .fit fills it exactly — no letterbox,
            // no centering-shrink — and it looks identical in every viewer
            // regardless of how each sizes/zooms the page.
            .width = 450,
            .height = 800,
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
