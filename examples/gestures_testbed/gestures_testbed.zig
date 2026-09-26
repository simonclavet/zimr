//! gestures_testbed - port of the GL `gestures_testbed`: a comprehensive
//! gesture-state visualizer. Three columns - per-finger touch state, gesture-
//! detector state, and a state-transition log - plus numbered touch circles
//! tracking each finger. Touch-driven (no-op on desktop). Same backend-agnostic
//! recognizers as gestures_demo, ticked on the wgpu input snapshot.
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;

const float = zm.float;
const common = @import("example_common");
const c = z.colors;

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const log_lines: usize = 16;

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    gestures: z.GesturesState = .{},
    frame_count: usize = 0,
    /// Ring of recent state transitions, newest at log[0].
    log: [log_lines][32]u8 = @splat(@splat(0)),
    log_count: usize = 0,
    last_gesture: z.Gesture = .none,
    /// Stash drag/pinch values across frames so the panel doesn't flicker
    /// between the active frame and the post-frame zero state.
    last_drag_v: Vec2 = .{ 0, 0 },
    last_pinch_v: Vec2 = .{ 0, 0 },
    last_pinch_a: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32),
        .scratch = std.heap.ArenaAllocator.init(gpa),
    };
}

fn gestureName(g: z.Gesture) []const u8 {
    return switch (g) {
        .none => "NONE",
        .tap => "TAP",
        .doubletap => "DOUBLETAP",
        .hold => "HOLD",
        .drag => "DRAG",
        .swipe_right => "SWIPE_RIGHT",
        .swipe_left => "SWIPE_LEFT",
        .swipe_up => "SWIPE_UP",
        .swipe_down => "SWIPE_DOWN",
        .pinch_in => "PINCH_IN",
        .pinch_out => "PINCH_OUT",
    };
}

fn pushLog(state: *State, line: []const u8) void {
    var i: usize = state.log.len - 1;
    while (i > 0) : (i -= 1) {
        state.log[i] = state.log[i - 1];
    }
    @memset(&state.log[0], 0);
    const n: usize = @min(line.len, state.log[0].len - 1);
    @memcpy(state.log[0][0..n], line[0..n]);
    if (state.log_count < state.log.len) {
        state.log_count += 1;
    }
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    const arena: Allocator = state.scratch.allocator();
    z.updateGestures(&state.gestures, f.input, f.time);
    state.frame_count += 1;

    // Detect gesture transitions and log them.
    const cur: z.Gesture = z.getGestureDetected(&state.gestures);
    if (cur != state.last_gesture and cur != .none) {
        const from: []const u8 = gestureName(state.last_gesture);
        const to: []const u8 = gestureName(cur);
        const line: []const u8 = allocPrint(
            arena,
            "F{d}: {s} -> {s}",
            .{ state.frame_count, from, to },
        ) catch "";
        pushLog(state, line);
    }
    state.last_gesture = cur;

    if (cur == .drag) {
        state.last_drag_v = z.getGestureDragVector(&state.gestures);
    }
    if (cur == .pinch_in or cur == .pinch_out) {
        state.last_pinch_v = z.getGesturePinchVector(&state.gestures);
        state.last_pinch_a = z.getGesturePinchAngle(&state.gestures);
    }

    z.clearViewport(f, common.palette.bg);

    f.gl.text(.{ 20, 16 }, "zimr gestures - testbed", .{ .size = 22, .color = c.amber_300, .font = &state.font });
    const sub: []const u8 = allocPrint(arena, "frame {d}", .{state.frame_count}) catch "";
    f.gl.text(.{ 20, 44 }, sub, .{ .size = 14, .color = c.slate_500, .font = &state.font });

    const col1_x: f32 = 20;
    const col2_x: f32 = 320;
    const col3_x: f32 = 600;
    const col_y: f32 = 80;

    // Column 1 - touch state.
    f.gl.text(.{ col1_x, col_y }, "TOUCH STATE", .{ .size = 16, .color = c.sky_400, .font = &state.font });
    const tcount: i32 = z.getTouchPointCount(f.input);
    const count_txt: []const u8 = allocPrint(arena, "count: {d}", .{tcount}) catch "";
    f.gl.text(.{ col1_x, col_y + 24 }, count_txt, .{ .size = 14, .color = c.slate_300, .font = &state.font });
    var i: i32 = 0;
    while (i < tcount) : (i += 1) {
        const id: i32 = z.getTouchPointId(f.input, i);
        const p: Vec2 = z.getTouchPosition(f.input, i);
        const txt: []const u8 = allocPrint(
            arena,
            "[{d}] id={d}  x={d:.0}  y={d:.0}",
            .{ i, id, p[0], p[1] },
        ) catch "";
        f.gl.text(
            .{ col1_x, col_y + 48 + float(i) * 18 },
            txt,
            .{ .size = 14, .color = c.slate_200, .font = &state.font },
        );
    }

    // Column 2 - gesture state.
    f.gl.text(.{ col2_x, col_y }, "GESTURE STATE", .{ .size = 16, .color = c.pink_400, .font = &state.font });
    const cur_txt: []const u8 = allocPrint(arena, "current: {s}", .{gestureName(cur)}) catch "";
    f.gl.text(.{ col2_x, col_y + 24 }, cur_txt, .{ .size = 14, .color = c.slate_300, .font = &state.font });
    const dur: f32 = z.getGestureHoldDuration(&state.gestures, f.time);
    const hold_txt: []const u8 = allocPrint(arena, "hold: {d:.2} s", .{dur}) catch "";
    f.gl.text(.{ col2_x, col_y + 48 }, hold_txt, .{ .size = 14, .color = c.slate_300, .font = &state.font });
    const drag_txt: []const u8 = allocPrint(
        arena,
        "drag: ({d:.0}, {d:.0})",
        .{ state.last_drag_v[0], state.last_drag_v[1] },
    ) catch "";
    f.gl.text(.{ col2_x, col_y + 72 }, drag_txt, .{ .size = 14, .color = c.slate_300, .font = &state.font });
    const pinch_txt: []const u8 = allocPrint(
        arena,
        "pinch: ({d:.0}, {d:.0})  {d:.1}",
        .{ state.last_pinch_v[0], state.last_pinch_v[1], state.last_pinch_a },
    ) catch "";
    f.gl.text(.{ col2_x, col_y + 96 }, pinch_txt, .{ .size = 14, .color = c.slate_300, .font = &state.font });

    // Column 3 - transition log.
    f.gl.text(.{ col3_x, col_y }, "TRANSITION LOG", .{ .size = 16, .color = c.amber_400, .font = &state.font });
    var j: usize = 0;
    while (j < state.log_count) : (j += 1) {
        var n: usize = 0;
        while (n < state.log[j].len and state.log[j][n] != 0) : (n += 1) {}
        const line: []const u8 = state.log[j][0..n];
        const fade: u8 = @trunc(255.0 * (1.0 - float(j) / float(state.log.len)));
        const col: Color = .{ .r = fade, .g = fade, .b = fade, .a = 255 };
        f.gl.text(.{ col3_x, col_y + 24 + float(j) * 14 }, line, .{ .size = 12, .color = col, .font = &state.font });
    }

    // Numbered touch circles following each finger.
    var k: i32 = 0;
    while (k < tcount) : (k += 1) {
        const p: Vec2 = z.getTouchPosition(f.input, k);
        f.gl.circle(p, 28, .{ .color = c.sky_400, .segments = 28 });
        const lbl: []const u8 = allocPrint(arena, "{d}", .{k}) catch "";
        f.gl.text(.{ p[0] - 4, p[1] - 8 }, lbl, .{ .size = 18, .color = c.slate_950, .font = &state.font });
    }

    const help: []const u8 = "Touch the canvas: tap, double-tap, hold, drag, swipe, pinch.";
    f.gl.text(.{ 20, 510 }, help, .{ .size = 12, .color = c.slate_500, .font = &state.font });
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - gestures testbed",
            .width = 900,
            .height = 540,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
