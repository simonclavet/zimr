//! keys - input demo (ported). WASD/arrows move a square, shift = faster,
//! space toggles bg, mouse crosshair + click splats. Exercises the input state
//! machine + core 2D draws on the wgpu backend.
// Validates the input state machine end-to-end:
//   - WASD or arrow keys move a small square.
//   - Holding shift makes it move faster (isKeyDown for the shift).
//   - Space changes the background tone (isKeyPressed - fires once
//     per press, not every frame held).
//   - Mouse position is reported by a crosshair that follows the
//     cursor.
//   - Mouse left-button clicks leave a "splat" mark at the cursor
//     isMouseButtonPressed exercises rising-edge detection.
// Open `host.html?app=keys` in a browser, focus the canvas (click
// once), and try the controls.  Smoke test won't exercise input
// (the fake doesn't simulate events), but verifies the wasm loads
// and runs through frames without trapping.

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const tau = zm.tau;
const clamp = zm.clamp;
const sqrt = zm.sqrt;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const square_size: f32 = 32;
const max_splats: usize = 64;

const Splat = struct { x: f32, y: f32, age: f32 };

const State = struct {
    /// Loaded default font (wgpu drawText takes a Font, not a cache).
    font: z.Font,
    /// Per-frame scratch arena, reset at top of update by user code.
    scratch: std.heap.ArenaAllocator,
    frame_count: usize = 0,

    /// Player square position (centre).
    px: f32 = screen_w / 2,
    py: f32 = screen_h / 2,

    /// Background phase: 0 = slate, 1 = sky.  Toggled by space.
    bg_mode: u8 = 0,
    /// Smoothly-interpolating bg phase for visual feedback.
    bg_phase: f32 = 0,

    /// Click splat ring buffer.
    splats: [max_splats]Splat = @splat(Splat{ .x = 0, .y = 0, .age = 999 }),
    splat_head: usize = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, @embedFile("atkinson_mono_ttf"), 32);
    s.* = .{ .font = font, .scratch = std.heap.ArenaAllocator.init(gpa) };
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    state.frame_count += 1;
    // Real frame delta from the core timing module.  On the very
    // first frame this can be 0 (no previous frame to subtract from);
    // callers should treat that as a no-op rather than dividing by it.
    const dt: f32 = f.time.delta_time;

    // ---- Movement (isKeyDown - held-state polling)
    const KbK: type = z.KeyboardKey;
    const KEY_W: KbK = .w;
    const KEY_A: KbK = .a;
    const KEY_S: KbK = .s;
    const KEY_D: KbK = .d;
    const KEY_LEFT: KbK = .left;
    const KEY_RIGHT: KbK = .right;
    const KEY_UP: KbK = .up;
    const KEY_DOWN: KbK = .down;
    const KEY_LEFT_SHIFT: KbK = .left_shift;
    const KEY_SPACE: KbK = .space;

    const speed: f32 = if (z.isKeyDown(f.input, KEY_LEFT_SHIFT)) 600 else 240;
    var dx: f32 = 0;
    var dy: f32 = 0;
    if (z.isKeyDown(f.input, KEY_A) or z.isKeyDown(f.input, KEY_LEFT)) {
        dx -= 1;
    }
    if (z.isKeyDown(f.input, KEY_D) or z.isKeyDown(f.input, KEY_RIGHT)) {
        dx += 1;
    }
    if (z.isKeyDown(f.input, KEY_W) or z.isKeyDown(f.input, KEY_UP)) {
        dy -= 1;
    }
    if (z.isKeyDown(f.input, KEY_S) or z.isKeyDown(f.input, KEY_DOWN)) {
        dy += 1;
    }
    // Normalise diagonal so it doesn't move √2x faster.
    if (dx != 0 and dy != 0) {
        const inv: f32 = 1.0 / sqrt(2.0);
        dx *= inv;
        dy *= inv;
    }
    state.px += dx * speed * dt;
    state.py += dy * speed * dt;
    // Clamp inside the canvas.
    state.px = clamp(state.px, square_size / 2, @as(f32, screen_w) - square_size / 2);
    state.py = clamp(state.py, square_size / 2, @as(f32, screen_h) - square_size / 2);

    // ---- Background toggle (isKeyPressed - rising edge)
    if (z.isKeyPressed(f.input, KEY_SPACE)) {
        state.bg_mode = if (state.bg_mode == 0) 1 else 0;
    }
    // Smoothly interpolate towards the target.
    const target: f32 = if (state.bg_mode == 1) 1 else 0;
    state.bg_phase += (target - state.bg_phase) * 0.08;

    // ---- Mouse click splats (isMouseButtonPressed - rising edge)
    if (z.isMouseButtonPressed(f.input, .left)) {
        const mp: Vec2 = z.getMousePosition(f.input);
        state.splats[state.splat_head] = .{ .x = mp[0], .y = mp[1], .age = 0 };
        state.splat_head = (state.splat_head + 1) % max_splats;
    }
    // Age all splats.
    for (&state.splats) |*s| {
        s.age += dt;
    }

    // ---- Render ----------------------------------------------------------
    // Use textures.colorLerp instead of an inline lerpU8 helper.
    // Mirrors raylib's standard idiom for two-state cross-fades.
    const slate: Color = z.colors.slate_900;
    const sky: Color = z.colors.sky_700;
    const bg: Color = Color.lerp(slate, sky, clamp(state.bg_phase, 0, 1));
    z.clearViewport(f, bg);

    // Splats - drawn first so the player + crosshair are on top.
    for (state.splats) |s| {
        if (s.age > 1.5) {
            continue;
        }
        const alpha: u8 = @round(255.0 * (1.0 - s.age / 1.5));
        const r: f32 = 4 + s.age * 50;
        f.gl.circleSector(.{ s.x, s.y }, r, 0, tau, 16, .{ .color = .{ .r = 255, .g = 220, .b = 120, .a = alpha } });
    }

    // Crosshair at the mouse position.
    const mp: Vec2 = z.getMousePosition(f.input);
    f.gl.line(.{ mp[0] - 8, mp[1] }, .{ mp[0] + 8, mp[1] }, .{ .color = z.colors.white, .thickness = 1.0 });
    f.gl.line(.{ mp[0], mp[1] - 8 }, .{ mp[0], mp[1] + 8 }, .{ .color = z.colors.white, .thickness = 1.0 });

    // Player square.
    const sq_pos: Vec2 = .{ state.px - square_size / 2, state.py - square_size / 2 };
    f.gl.rect(
        .{ .x = sq_pos[0], .y = sq_pos[1], .width = square_size, .height = square_size },
        .{ .color = z.colors.amber_400 },
    );

    // ---- HUD text
    // Demos the default font: lazily loaded on first call to
    // `text.draw` via `getFontDefault`.  Glyphs are drawn from a
    // 128×128 atlas - see `font_default.zig`.  We format into the
    // per-frame arena so no allocator churn between frames.
    const arena: Allocator = state.scratch.allocator();
    const fps_int: i32 = if (f.time.delta_time > 0.0) @trunc(1.0 / f.time.delta_time) else 0;
    const fps_str: []u8 = allocPrint(arena, "FPS: {d}", .{fps_int}) catch return;
    f.gl.text(.{ 12, 12 }, fps_str, .{ .size = 20, .color = z.colors.white, .font = &state.font });

    const frame_str: []u8 = allocPrint(arena, "frame {d}", .{state.frame_count}) catch return;
    f.gl.text(.{ 12, 38 }, frame_str, .{ .size = 20, .color = z.colors.slate_400, .font = &state.font });
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - keys",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
            .depth_format = null,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
