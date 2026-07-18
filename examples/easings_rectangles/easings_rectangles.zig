// examples/easings_rectangles.zig - 16×9 grid of rectangles that
// simultaneously shrink to zero and rotate one full turn.
// Port of raylib's `examples/shapes/shapes_easings_rectangles.c`
// (★3, ~124 LOC).  Both the shrink and the spin share the same
// `framesCounter` time anchor - `circOut` drives the size, `linear`
// drives the rotation.  240 frames = ~4s total.
// What this exercises:
//   - 144 rectangles × 240 frames = ~35k draw-rect-pro calls per
//     animation.  Light stress test for `drawRectangleRotated`'s
//     batching.
//   - `circOut`'s shape: starts fast, finishes flat.  Half of the
//     rectangles vanish in the first ~30% of the animation; the
//     remaining 70% is the slow tail.
//   - Both `linear` and `circOut` from the same `z.easings`
//     module - confirms the API works for the entire grid of
//     calls without per-call overhead.
// Controls:
//   SPACE  - once the animation finishes, replay from the start

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const tau = zm.tau;
const Vec2 = zm.Vec2;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");
const Color = zm.Color;
const clamp = zm.clamp;
const int = zm.int;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const rec_width: f32 = 50;
const rec_height: f32 = 50;

// Grid dimensions derived from screen / rec-size.
const cols: usize = @as(usize, @intCast(screen_w)) / int(usize, rec_width);
const rows: usize = @as(usize, @intCast(screen_h)) / int(usize, rec_height);
const total_recs: usize = cols * rows;

const play_duration: f32 = 240; // 4s at 60fps

const c = Color;

const State = struct {
    /// Owned shapes-texture state. id=1 → rlgl's internal 1x1 white pixel.
    /// Owned default-font cache. Populated by `loadFontFromTtfBytes` below.
    font: z.Font,
    frame_count: usize = 0,
    /// Per-rectangle width and height - they shrink together over
    /// the duration.  Stored per-rect so each one can independently
    /// be clamped at zero without recalculating from the curve.
    recs_w: [total_recs]f32 = @splat(rec_width),
    recs_h: [total_recs]f32 = @splat(rec_height),
    /// Frame progress.  Wrapped into [0, play_duration].
    progress: f32 = 0,
    /// Current rotation (degrees, common to all rects).
    rotation: f32 = 0,
    /// 0 = playing, 1 = finished (waiting for SPACE).
    stage: u8 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;
    const dt: f32 = @floatCast(f.time.delta_time);
    const tick: f32 = dt * 60.0;

    // ---- Update ----------------------------------------------------------
    if (state.stage == 0) {
        state.progress += tick;
        const t01: f32 = clamp(state.progress / play_duration, 0, 1);
        const eased: f32 = z.easeCircOut(t01);

        // Both dimensions shrink with the same curve and amount
        // (`rec_width` and `rec_height` are subtracted as the
        // "change" parameter; raylib's signature has it as
        // delta, not target).
        const w: f32 = rec_width - eased * rec_width;
        const h: f32 = rec_height - eased * rec_height;

        // Apply the same value to every rect.  Splat-and-clamp.
        for (&state.recs_w) |*rw| {
            rw.* = @max(0, w);
        }
        for (&state.recs_h) |*rh| {
            rh.* = @max(0, h);
        }

        state.rotation = z.easeLinear(t01) * tau;

        if (state.progress >= play_duration) {
            state.stage = 1;
        }
    } else if (state.stage == 1 and z.isKeyPressed(f.input, .space)) {
        // Restart: zero the progress + restore the rectangles.
        state.progress = 0;
        state.stage = 0;
        for (&state.recs_w) |*rw| {
            rw.* = rec_width;
        }
        for (&state.recs_h) |*rh| {
            rh.* = rec_height;
        }
    }

    // ---- Render ---------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    if (state.stage == 0) {
        for (0..total_recs) |i| {
            const col_i: f32 = float(i % cols);
            const row_i: f32 = float(i / cols);
            // Position is the cell *centre*; raylib's source uses
            // `RECS_WIDTH/2.0f + RECS_WIDTH*x` which is the same.
            const rect: z.Rectangle = .{
                .x = rec_width / 2.0 + rec_width * col_i,
                .y = rec_height / 2.0 + rec_height * row_i,
                .width = state.recs_w[i],
                .height = state.recs_h[i],
            };
            // Pivot at centre so the rotation matches all neighbours.
            const origin: Vec2 = .{ state.recs_w[i] / 2.0, state.recs_h[i] / 2.0 };
            f.gl.rectRotated(rect, origin, state.rotation, .{ .color = c.red });
        }
    } else {
        f.gl.text(.{ 240, 200 }, "PRESS [SPACE] TO PLAY AGAIN!", .{ .size = 20, .color = c.gray, .font = &state.font });
    }
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - easings rectangles",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
