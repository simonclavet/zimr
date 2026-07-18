// examples/bouncing_ball.zig - gravity-driven ball with wall-bounce,
// pause, and gravity toggle.
// Direct port of raylib's `examples/shapes/shapes_bouncing_ball.c`
// (★1, ~93 LOC).  The mechanics are the simplest a "physics" demo
// can get without actually using `physics.zig`: a single ball with
// (vx, vy), a constant downward acceleration, and walls that flip
// the relevant velocity component on contact.
// What this exercises in zimr:
//   - `f.gl.circle` for the filled ball (takes
//     `&state.shapes_texture` so the GPU rasterizer can sample the
//     1×1 white texture - same convention as raylib's `DrawCircleV`).
//   - `f.gl.text` for the HUD strings.
//   - `z.isKeyPressed` for the two rising-edge toggles (G for
//     gravity, SPACE for pause).
//   - `f.time.delta_time` for the dt that drives velocity
//     integration - raylib's source uses a fixed-step "5 pixels per
//     frame" pattern, but we scale by `dt * 60` so frame-rate
//     variations don't change the apparent speed.
// Controls:
//   G      - toggle gravity (default on)
//   SPACE  - pause/resume ball movement
// Subtle thing worth noticing: the y-bounce has a 0.95 restitution
// coefficient (vy *= -0.95 on the floor), so the ball loses a
// little energy on each bounce and eventually rests against the
// floor.  The x-bounce is perfectly elastic (-1.0), so horizontal
// energy is conserved indefinitely.  Matches raylib's source
// exactly.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const ball_radius: f32 = 20.0;
const initial_speed_x: f32 = 5.0;
const initial_speed_y: f32 = 4.0;
const gravity: f32 = 0.2;
const floor_restitution: f32 = 0.95;

// raylib's named colour palette is namespaced inside `Color` (see
// `src/types.zig`).  Aliasing the struct gives us `c.maroon` etc.
// without polluting the module-level color namespace.
const c = Color;

const State = struct {
    /// Owned shapes-texture state.  Default-init points at rlgl's
    /// internal 1x1 white pixel (texture id=1) - no upload needed.
    font: z.Font,
    frame_count: usize = 0,
    /// Pixel position of the ball centre.
    pos: Vec2 = .{ screen_w / 2, screen_h / 2 },
    /// Velocity in pixels per (1/60)-second, so the integrator is
    /// `pos += vel * dt * 60`.  Keeps raylib's tuning numbers usable
    /// without re-deriving them for true-pixels-per-second.
    vel: Vec2 = .{ initial_speed_x, initial_speed_y },
    /// Whether gravity is currently applied.  Toggled by G.
    use_gravity: bool = true,
    /// Whether the simulation is paused.  Toggled by SPACE.
    paused: bool = false,
    /// Frame counter used to blink the "PAUSED" overlay.
    paused_frames: u32 = 0,
};

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, roboto_mono_ttf, 32);
    s.* = .{ .font = font };
}

fn update(f: *z.Frame, state: *State) void {
    state.frame_count += 1;

    // ---- Input toggles ----------------------------------------------------
    // Rising-edge: only fires on the transition from up→down, not
    // every frame the key is held.
    if (z.isKeyPressed(f.input, .g)) {
        state.use_gravity = !state.use_gravity;
    }
    if (z.isKeyPressed(f.input, .space)) {
        state.paused = !state.paused;
    }

    // ---- Physics ----------------------------------------------------------
    // Scale by 60·dt so the per-frame deltas match raylib's
    // intended tuning (raylib runs at SetTargetFPS(60) without any
    // scaling).  zimr's `f.time.delta_time` returns real-seconds,
    // so `60 * dt ≈ 1` at 60fps.
    const dt: f32 = @floatCast(f.time.delta_time);
    const k: f32 = dt * 60.0;

    if (state.paused) {
        state.paused_frames += 1;
    } else {
        state.pos[0] += state.vel[0] * k;
        state.pos[1] += state.vel[1] * k;

        if (state.use_gravity) {
            state.vel[1] += gravity * k;
        }

        // Wall collisions.  Flip the perpendicular velocity
        // component when the ball would cross the wall, applying
        // the restitution coefficient on the floor only.
        const sw: f32 = f.window.widthf();
        const sh: f32 = f.window.heightf();
        if (state.pos[0] >= sw - ball_radius or state.pos[0] <= ball_radius) {
            state.vel[0] *= -1.0;
        }
        if (state.pos[1] >= sh - ball_radius or state.pos[1] <= ball_radius) {
            state.vel[1] *= -floor_restitution;
        }
    }

    // ---- Render -----------------------------------------------------------
    z.clearViewport(f, c.raywhite);

    f.gl.circle(state.pos, ball_radius, .{ .color = c.maroon, .segments = 16 });

    // Bottom HUD: pause hint (raylib's source put this just above
    // the bottom edge with a 25px margin).
    f.gl.text(.{ 10, screen_h - 25 }, "PRESS SPACE to PAUSE BALL MOVEMENT", .{
        .size = 20,
        .color = c.lightgray,
        .font = &state.font,
    });

    // Gravity state line just above the pause hint.
    const grav_msg: []const u8 = if (state.use_gravity)
        "GRAVITY: ON (Press G to disable)"
    else
        "GRAVITY: OFF (Press G to enable)";
    const grav_color: Color = if (state.use_gravity) c.darkgreen else c.red;
    f.gl.text(.{ 10, screen_h - 50 }, grav_msg, .{ .size = 20, .color = grav_color, .font = &state.font });

    // Blinking "PAUSED" overlay - on for 30 frames, off for 30.
    if (state.paused and ((state.paused_frames / 30) % 2 == 0)) {
        f.gl.text(.{ 350, 200 }, "PAUSED", .{ .size = 30, .color = c.gray, .font = &state.font });
    }
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - bouncing ball",
            .width = screen_w,
            .height = screen_h,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
