//! input_gamepad - the gamepads the platform reads, one panel per slot: each button lit while held, both sticks as a
//! dot inside their circle, and the triggers as bars filling with their travel. Pressing the south button - A on an
//! Xbox pad, cross on a PlayStation one - rumbles that gamepad for a quarter of a second. A browser shows a page its
//! gamepads only once a button is pressed while the page has the focus.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const float = zm.float;

const State = struct {
    font: z.Font,
};

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const background: Color = .{ .r = 24, .g = 26, .b = 34, .a = 255 };
const panel: Color = .{ .r = 36, .g = 40, .b = 52, .a = 255 };
const resting: Color = .{ .r = 70, .g = 76, .b = 92, .a = 255 };
const held: Color = .{ .r = 96, .g = 165, .b = 250, .a = 255 };
const text_color: Color = .{ .r = 230, .g = 230, .b = 235, .a = 255 };

/// The buttons a panel shows, by raylib's names, with the labels an Xbox pad prints.
const shown_buttons = [_]struct { button: z.GamepadButton, label: []const u8 }{
    .{ .button = .right_face_down, .label = "A" },
    .{ .button = .right_face_right, .label = "B" },
    .{ .button = .right_face_left, .label = "X" },
    .{ .button = .right_face_up, .label = "Y" },
    .{ .button = .left_trigger_1, .label = "LB" },
    .{ .button = .right_trigger_1, .label = "RB" },
    .{ .button = .middle_left, .label = "Back" },
    .{ .button = .middle_right, .label = "Start" },
    .{ .button = .left_thumb, .label = "LS" },
    .{ .button = .right_thumb, .label = "RS" },
    .{ .button = .left_face_up, .label = "Up" },
    .{ .button = .left_face_down, .label = "Down" },
    .{ .button = .left_face_left, .label = "Left" },
    .{ .button = .left_face_right, .label = "Right" },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 16);
    s.* = .{ .font = font };
}

/// A stick: its circle, and a dot where the stick points.
fn drawStick(f: *z.Frame, center: Vec2, x: f32, y: f32) void {
    const radius: f32 = 34;
    f.gl.circle(center, radius, .{ .color = resting, .segments = 32 });
    const tip: Vec2 = .{ center[0] + x * radius, center[1] + y * radius };
    f.gl.circle(tip, 8, .{ .color = held, .segments = 16 });
}

/// A trigger: a bar filling upward with its travel, 0 to 1.
fn drawTrigger(
    f: *z.Frame,
    s: *State,
    corner: Vec2,
    travel: f32,
    label: []const u8,
) void {
    const height: f32 = 70;
    f.gl.rect(.{ .x = corner[0], .y = corner[1], .width = 22, .height = height }, .{ .color = resting });
    const filled: f32 = height * travel;
    f.gl.rect(.{ .x = corner[0], .y = corner[1] + height - filled, .width = 22, .height = filled }, .{ .color = held });
    f.gl.text(.{ corner[0], corner[1] + height + 4 }, label, .{ .size = 14, .color = text_color, .font = &s.font });
}

/// One slot's panel at `corner`: its buttons, sticks and triggers. Its south button rumbles it.
fn drawGamepad(f: *z.Frame, s: *State, slot: i32, corner: Vec2) void {
    f.gl.rect(.{ .x = corner[0], .y = corner[1], .width = 440, .height = 230 }, .{ .color = panel });
    var title_bytes: [32]u8 = undefined;
    const title: []const u8 = bufPrint(&title_bytes, "gamepad {d}", .{slot}) catch "gamepad";
    f.gl.text(.{ corner[0] + 12, corner[1] + 8 }, title, .{ .size = 16, .color = text_color, .font = &s.font });
    for (shown_buttons, 0..) |shown, index| {
        const column: f32 = float(index % 7);
        const row: f32 = float(index / 7);
        const box_x: f32 = corner[0] + 12 + column * 60;
        const box_y: f32 = corner[1] + 36 + row * 34;
        const is_held: bool = z.isGamepadButtonDown(f.input, slot, shown.button);
        const box_color: Color = if (is_held) held else resting;
        f.gl.rect(.{ .x = box_x, .y = box_y, .width = 54, .height = 28 }, .{ .color = box_color });
        f.gl.text(.{ box_x + 6, box_y + 6 }, shown.label, .{ .size = 14, .color = text_color, .font = &s.font });
    }
    const left_x: f32 = z.getGamepadAxisMovement(f.input, slot, .left_x);
    const left_y: f32 = z.getGamepadAxisMovement(f.input, slot, .left_y);
    const right_x: f32 = z.getGamepadAxisMovement(f.input, slot, .right_x);
    const right_y: f32 = z.getGamepadAxisMovement(f.input, slot, .right_y);
    drawStick(f, .{ corner[0] + 60, corner[1] + 160 }, left_x, left_y);
    drawStick(f, .{ corner[0] + 160, corner[1] + 160 }, right_x, right_y);
    const left_trigger: f32 = z.getGamepadAxisMovement(f.input, slot, .left_trigger);
    const right_trigger: f32 = z.getGamepadAxisMovement(f.input, slot, .right_trigger);
    drawTrigger(f, s, .{ corner[0] + 240, corner[1] + 112 }, left_trigger, "LT");
    drawTrigger(f, s, .{ corner[0] + 280, corner[1] + 112 }, right_trigger, "RT");
    if (z.isGamepadButtonPressed(f.input, slot, .right_face_down)) {
        z.setGamepadVibration(f.input, slot, 0.6, 0.4, 0.25);
    }
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, background);
    var shown_count: u32 = 0;
    var slot: i32 = 0;
    while (slot < 4) : (slot += 1) {
        if (!z.isGamepadAvailable(f.input, slot)) {
            continue;
        }
        const column: f32 = float(shown_count % 2);
        const row: f32 = float(shown_count / 2);
        drawGamepad(f, s, slot, .{ 16 + column * 456, 16 + row * 246 });
        shown_count += 1;
    }
    if (shown_count == 0) {
        const prompt: []const u8 = "connect a gamepad, then press one of its buttons";
        f.gl.text(.{ 24, 24 }, prompt, .{ .size = 18, .color = text_color, .font = &s.font });
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - gamepads",
            .width = 928,
            .height = 508,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
