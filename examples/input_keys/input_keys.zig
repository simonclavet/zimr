// examples/input_keys.zig - the simplest possible keyboard input
// demo: arrow keys move a ball.
// Port of raylib's `examples/core/core_input_keys.c` (*1, ~65 LOC).
// Smallest example in the entire raylib catalogue - really just
// validates that `isKeyDown` returns true continuously while a
// key is held, and that we have a way to wire that to a position
// integrator.
// **See also:** `examples/keys.zig` is the more comprehensive
// "general input" showcase in zimr's gallery - WASD + shift
// modifier + space-toggle + mouse crosshair + click splats.
// Use `input_keys` when you want the minimum-viable arrow-key
// demo; use `keys` when you want to see several input types
// integrated.
// What this exercises:
//   - `z.isKeyDown` (held detection - fires every frame).
//   - dt-scaled motion: raylib's source uses a fixed `+= 2.0f`
//     per frame, we multiply by `60 * dt` so the speed feels the
//     same whether the framerate is 60 or 144 fps.
//   - `z.keyName`: keys are named by their position - W, A, S, D are
//     where they sit on a US keyboard - and the prompt shows what the
//     person's own layout prints on those keys: on a French keyboard,
//     the same four keys read Z, Q, S, D.
// Controls:
//   ^ v <- ->  move the ball, or the four keys at W A S D

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const Vec2 = zm.Vec2;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const ball_radius: f32 = 50;
/// Per-frame movement at 60fps.  Matches raylib's source `2.0f`
/// constant exactly; the dt-scaling below makes this rate-
/// independent without changing the visible speed at 60fps.
const speed_per_frame: f32 = 2;

const c = Color;

const State = struct {
    /// Owned shapes-texture state.  Default-init points at rlgl's
    /// internal 1x1 white pixel (texture id=1) - no upload needed.
    /// Owned default-font cache.  Populated by `z.loadFontFromTtfBytes`
    /// in `initState` below.
    font: z.Font,
    frame_count: usize = 0,
    /// Pixel position of the ball centre.
    pos: Vec2 = .{ screen_w / 2, screen_h / 2 },
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;

    // Frame-rate-independent step.  At 60fps, k = 1 and the ball
    // moves at raylib's original speed.
    const dt: f32 = @floatCast(f.time.delta_time);
    const k: f32 = dt * 60.0;
    const step: f32 = speed_per_frame * k;

    if (z.isKeyDown(f.input, .right) or z.isKeyDown(f.input, .d)) {
        state.pos[0] += step;
    }
    if (z.isKeyDown(f.input, .left) or z.isKeyDown(f.input, .a)) {
        state.pos[0] -= step;
    }
    if (z.isKeyDown(f.input, .up) or z.isKeyDown(f.input, .w)) {
        state.pos[1] -= step;
    }
    if (z.isKeyDown(f.input, .down) or z.isKeyDown(f.input, .s)) {
        state.pos[1] += step;
    }

    // ---- Render -----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    // The four keys at W A S D, by what the person's layout prints on them.
    var label_bytes: [4][16]u8 = undefined;
    const movement_keys = [4]z.KeyboardKey{ .w, .a, .s, .d };
    var labels: [4][]const u8 = undefined;
    for (movement_keys, 0..) |key, index| {
        labels[index] = z.keyName(key, &label_bytes[index]) orelse "?";
    }
    f.gl.textf(
        .{ 10, 10 },
        "move the ball with the arrows, or {s} {s} {s} {s}",
        .{ labels[0], labels[1], labels[2], labels[3] },
        .{ .size = 20, .color = c.darkgray, .font = &state.font },
    );

    f.gl.circle(state.pos, ball_radius, .{ .color = c.maroon, .segments = 16 });
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - input keys",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
