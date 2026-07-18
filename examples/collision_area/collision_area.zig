// examples/collision_area.zig - visualise the intersection of an
// axis-aligned bouncing box (A) and a mouse-controlled box (B).
// Port of raylib's `examples/shapes/shapes_collision_area.c` (★2,
// ~117 LOC).  Box A slides left-right and bounces off the screen
// edges; box B tracks the mouse cursor.  When they overlap, the
// intersection rectangle is drawn in lime green and a HUD strip
// at the top flashes red.
// What this exercises:
//   - Axis-aligned bounding box (AABB) overlap test.  raylib's
//     `CheckCollisionRecs` and `GetCollisionRec` - equivalent
//     to the two small helpers at the bottom of this file.
//   - Rectangle clamping for keeping box B in-bounds.
//   - Live geometry HUD: as box A scrubs back-and-forth, the
//     mouse position cleanly defines a moving Boolean test.
// Controls:
//   Mouse    moves box B
//   SPACE    pause/resume box A's motion

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const zm = @import("zm");
const Color = zm.Color;
const clamp = zm.clamp;
const float = zm.float;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const screen_w_f: f32 = float(screen_w);
const screen_h_f: f32 = float(screen_h);
const upper_strip: f32 = 40.0;
const box_a_speed: f32 = 4.0;

const c = Color;

const State = struct {
    /// Owned shapes-texture state.  Default-init points at rlgl's
    /// internal 1x1 white pixel (texture id=1) - no upload needed.
    /// Owned default-font cache.  Populated by `z.loadFontFromTtfBytes`
    /// in `initState` below.
    font: z.Font,
    frame_count: usize = 0,
    /// Box A - moving, bounces between screen edges.
    box_a: z.Rectangle = .{
        .x = 10,
        .y = screen_h_f / 2 - 50,
        .width = 200,
        .height = 100,
    },
    /// Per-frame velocity of box A in the X axis.  Flipped on
    /// edge contact.
    box_a_speed_x: f32 = box_a_speed,
    /// Box B - follows mouse, clamped to screen + below the upper strip.
    box_b: z.Rectangle = .{
        .x = screen_w_f / 2 - 30,
        .y = screen_h_f / 2 - 30,
        .width = 60,
        .height = 60,
    },
    /// Whether box A's motion is currently paused.
    paused: bool = false,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .font = font };
}

/// AABB overlap test - closed intervals on both axes.
fn rectsOverlap(a: z.Rectangle, b: z.Rectangle) bool {
    return (a.x <= b.x + b.width) and (a.x + a.width >= b.x) and
        (a.y <= b.y + b.height) and (a.y + a.height >= b.y);
}

/// AABB intersection rectangle.  Caller should only invoke when
/// `rectsOverlap` is true - width/height would otherwise be
/// negative for non-overlapping rects.
fn rectIntersection(a: z.Rectangle, b: z.Rectangle) z.Rectangle {
    const x: f32 = @max(a.x, b.x);
    const y: f32 = @max(a.y, b.y);
    const x2: f32 = @min(a.x + a.width, b.x + b.width);
    const y2: f32 = @min(a.y + a.height, b.y + b.height);
    return .{ .x = x, .y = y, .width = x2 - x, .height = y2 - y };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;

    // ---- Update box A (moving) -------------------------------------------
    if (z.isKeyPressed(f.input, .space)) {
        state.paused = !state.paused;
    }

    // dt-scaled so motion is independent of frame rate.  raylib's
    // source uses fixed integer pixels per frame; we match the
    // visual feel with `60 * dt * speed_per_frame`.
    const dt: f32 = @floatCast(f.time.delta_time);
    const k: f32 = dt * 60.0;

    if (!state.paused) {
        state.box_a.x += state.box_a_speed_x * k;
    }
    // Edge-bounce by flipping the speed sign.
    if ((state.box_a.x + state.box_a.width) >= screen_w_f or state.box_a.x <= 0) {
        state.box_a_speed_x *= -1;
    }

    // ---- Update box B (mouse-tracked) ------------------------------------
    state.box_b.x = float(z.getMouseX(f.input)) - state.box_b.width / 2;
    state.box_b.y = float(z.getMouseY(f.input)) - state.box_b.height / 2;

    // Clamp inside the play area (below the upper strip).
    state.box_b.x = clamp(state.box_b.x, 0, screen_w_f - state.box_b.width);
    state.box_b.y = clamp(state.box_b.y, upper_strip, screen_h_f - state.box_b.height);

    // ---- Collision -------------------------------------------------------
    const collision: bool = rectsOverlap(state.box_a, state.box_b);
    const overlap: z.Rectangle = if (collision)
        rectIntersection(state.box_a, state.box_b)
    else
        .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    // ---- Render ----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    // Top strip flips red when colliding, black otherwise.
    f.gl.rect(
        .{ .x = 0, .y = 0, .width = float(screen_w), .height = upper_strip },
        .{ .color = if (collision) c.red else c.black },
    );

    f.gl.rect(state.box_a, .{ .color = c.gold });
    f.gl.rect(state.box_b, .{ .color = c.blue });

    if (collision) {
        // Intersection in lime.  This is the visual payoff.
        f.gl.rect(overlap, .{ .color = c.lime });

        // Centred "COLLISION!" inside the upper strip.
        const msg: []const u8 = "COLLISION!";
        const w: f32 = z.measureText(state.font, msg, 20)[0];
        const msg_x: f32 = screen_w_f / 2 - w / 2;
        const msg_y: f32 = upper_strip / 2 - 10;
        f.gl.text(.{ msg_x, msg_y }, msg, .{ .size = 20, .color = c.black, .font = &state.font });

        // Area readout just below the upper strip.
        var buf: [64]u8 = undefined;
        const aw: i32 = @trunc(overlap.width);
        const ah: i32 = @trunc(overlap.height);
        const area: i32 = aw * ah;
        const area_msg: []const u8 = bufPrint(&buf, "Collision Area: {d}", .{area}) catch "Collision Area: ?";
        const area_y = @as(i32, upper_strip) + 10;
        f.gl.text(
            .{ @divFloor(screen_w, 2) - 100, area_y },
            area_msg,
            .{ .size = 20, .color = c.black, .font = &state.font },
        );
    }

    f.gl.text(
        .{ 20, screen_h - 35 },
        "Press SPACE to PAUSE/RESUME",
        .{ .size = 20, .color = c.lightgray, .font = &state.font },
    );
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - collision area",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
