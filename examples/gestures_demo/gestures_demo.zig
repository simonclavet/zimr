//! gestures_demo — port of the GL `gestures_demo`: shows the most recent
//! gesture name + its data (drag vector, pinch vector/angle, hold duration), a
//! scrolling history, and a touch-point debug strip. Touch-driven — a graceful
//! no-op on desktop. The recognizers are backend-agnostic input math
//! (`updateGestures` ticks them on the wgpu input snapshot each frame); no GL.
//! Mirrors raylib's core_input_gestures.
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

const history_len: usize = 12;

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    gestures: z.GesturesState = .{},
    frame_count: usize = 0,
    /// Newest at the head; oldest scrolls off the bottom.
    history: [history_len]z.Gesture = @splat(.none),
    history_count: usize = 0,
    last_seen: z.Gesture = .none,
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
        .none => "none",
        .tap => "tap",
        .doubletap => "doubletap",
        .hold => "hold",
        .drag => "drag",
        .swipe_right => "swipe right",
        .swipe_left => "swipe left",
        .swipe_up => "swipe up",
        .swipe_down => "swipe down",
        .pinch_in => "pinch in",
        .pinch_out => "pinch out",
    };
}

fn pushHistory(state: *State, g: z.Gesture) void {
    // Record only meaningful transitions (skip none + repeats).
    if (g == .none) {
        return;
    }
    if (g == state.last_seen) {
        return;
    }
    state.last_seen = g;
    var i: usize = state.history.len - 1;
    while (i > 0) : (i -= 1) {
        state.history[i] = state.history[i - 1];
    }
    state.history[0] = g;
    if (state.history_count < state.history.len) {
        state.history_count += 1;
    }
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    const arena: Allocator = state.scratch.allocator();
    z.updateGestures(&state.gestures, f.input, f.time);
    state.frame_count += 1;

    const cur: z.Gesture = z.getGestureDetected(&state.gestures);
    pushHistory(state, cur);

    z.clearViewport(f, common.palette.bg);

    f.gl.text(.{ 20, 20 }, "Current gesture", .{ .size = 16, .color = c.slate_400, .font = &state.font });
    f.gl.text(.{ 20, 50 }, gestureName(cur), .{ .size = 56, .color = c.amber_300, .font = &state.font });

    var y: f32 = 130;
    if (cur == .hold) {
        const dur: f32 = z.getGestureHoldDuration(&state.gestures, f.time);
        const txt: []const u8 = allocPrint(arena, "hold duration: {d:.2} s", .{dur}) catch "";
        f.gl.text(.{ 20, y }, txt, .{ .size = 18, .color = c.slate_300, .font = &state.font });
        y += 24;
    }
    if (cur == .drag) {
        const v: Vec2 = z.getGestureDragVector(&state.gestures);
        const txt: []const u8 = allocPrint(arena, "drag: ({d:.0}, {d:.0})", .{ v[0], v[1] }) catch "";
        f.gl.text(.{ 20, y }, txt, .{ .size = 18, .color = c.slate_300, .font = &state.font });
        y += 24;
    }
    if (cur == .pinch_in or cur == .pinch_out) {
        const v: Vec2 = z.getGesturePinchVector(&state.gestures);
        const a: f32 = z.getGesturePinchAngle(&state.gestures);
        const txt: []const u8 = allocPrint(
            arena,
            "pinch: vec=({d:.0}, {d:.0}) angle={d:.1}",
            .{ v[0], v[1], a },
        ) catch "";
        f.gl.text(.{ 20, y }, txt, .{ .size = 18, .color = c.slate_300, .font = &state.font });
        y += 24;
    }

    f.gl.text(.{ 20, 220 }, "Recent gestures", .{ .size = 16, .color = c.slate_400, .font = &state.font });
    var i: usize = 0;
    while (i < state.history_count) : (i += 1) {
        const name: []const u8 = gestureName(state.history[i]);
        const txt: []const u8 = allocPrint(arena, "{d}. {s}", .{ i + 1, name }) catch "";
        const fade: u8 = @trunc(255.0 * (1.0 - float(i) / float(state.history.len)));
        const col: Color = .{ .r = fade, .g = fade, .b = fade, .a = 255 };
        f.gl.text(.{ 20, 250 + float(i) * 16 }, txt, .{ .size = 14, .color = col, .font = &state.font });
    }

    // Touch-point debug strip: a circle per active finger.
    const tcount: i32 = z.getTouchPointCount(f.input);
    var k: i32 = 0;
    while (k < tcount) : (k += 1) {
        const p: Vec2 = z.getTouchPosition(f.input, k);
        f.gl.circle(p, 24, .{ .color = c.sky_400, .segments = 24 });
    }

    const hud: []const u8 = allocPrint(
        arena,
        "frame {d}, fingers {d}",
        .{ state.frame_count, tcount },
    ) catch "";
    common.caption(f.gl, state.font, hud);
    z.endDrawing(f.gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - gestures",
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
