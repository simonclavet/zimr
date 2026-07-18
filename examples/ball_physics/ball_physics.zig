// examples/ball_physics.zig - toss bouncy balls around in a box.
// Up to 5000 balls.  Each ball has position, velocity, radius,
// friction, elasticity.  Walls reflect with the elasticity factor;
// every frame the velocity is scaled by friction and gravity adds
// to the Y component.
// You can grab a ball with LMB on bare canvas (top-most-first hit
// test) and drag it; releasing imparts the apparent drag velocity
// to the ball.  RMB on bare canvas spawns a new ball at the cursor
// with random size, colour, and starting speed.
// The "Physics" panel exposes gravity, friction, elasticity,
// spawn-burst count, and a "Shake" button.  Spawning the random
// burst is more useful than the old hold-CTRL-RMB stream - one
// click plops down N balls at the mouse.
// We skip raylib's window-shake behaviour (`GetWindowPosition()`
// is a desktop-only API).  Shake-via-button works the same way.
// Ball-ball collisions are intentionally not handled - the
// raylib original doesn't have them either, and the soft pile-up
// at the bottom of the box is visually correct without them.
// Ported from raylib's `shapes_ball_physics.c`.

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const c = Color;

const screen_w: i32 = 800;
const screen_h: i32 = 450;
const max_balls: usize = 5000;

const Ball = struct {
    position: Vec2,
    speed: Vec2,
    prev_position: Vec2,
    radius: f32,
    color: Color,
    grabbed: bool,
};

const State = struct {
    scratch: std.heap.ArenaAllocator,
    rng: std.Random.DefaultPrng,
    gpa: Allocator,
    ui_host: z.UiHost,
    font: z.Font,

    balls: ArrayList(Ball) = .empty,
    /// Index of the grabbed ball (or null).  Stored as an index
    /// not a pointer so that pushing new balls into the list
    /// (which might reallocate in principle) doesn't invalidate
    /// the reference.  In practice the list's capacity is reserved
    /// to `max_balls` at init so growth never happens — but indexing
    /// stays index-based to keep the spawn path obviously correct.
    grabbed: ?usize = null,
    press_offset: Vec2 = .{ 0, 0 },

    // ---- UI-bound parameters -----------------------------------------------
    gravity: f32 = 100,
    /// Per-step velocity damping.  1.0 = lossless; default 0.99
    /// matches raylib.  Applied to every ball every frame, so this
    /// is global rather than per-ball.
    friction: f32 = 0.99,
    /// Wall-bounce coefficient.  1.0 = perfect rebound.
    elasticity: f32 = 0.9,
    /// Number of balls to spawn when the "Burst" button fires.
    burst_count: i32 = 20,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.balls.deinit(gpa);
    s.scratch.deinit();
    s.ui_host.deinit();
}

fn initState(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 28);
    s.* = .{
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .rng = std.Random.DefaultPrng.init(0xBA11_C0DE),
        .gpa = gpa,
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
    };
    // Reserve full capacity up front so the per-frame spawn path
    // never reallocates — a 5000-element realloc in the middle of a
    // burst would chunk the framerate.
    try s.balls.ensureTotalCapacity(gpa, max_balls);
    // Seed with one big blue ball at center, matches the raylib
    // original - gives the user something to grab at startup.
    try s.balls.append(gpa, .{
        .position = .{ @as(f32, screen_w) / 2.0, @as(f32, screen_h) / 2.0 },
        .speed = .{ 200, 200 },
        .prev_position = .{ 0, 0 },
        .radius = 40,
        .color = c.blue,
        .grabbed = false,
    });
}

fn randomSpeed(rand: std.Random) f32 {
    return @floatFromInt(rand.intRangeAtMost(i32, -300, 300));
}

fn randomU8(rand: std.Random) u8 {
    return rand.intRangeAtMost(u8, 0, 255);
}

fn spawnBallAt(state: *State, at: Vec2) void {
    if (state.balls.items.len >= max_balls) {
        return;
    }
    const rand: std.Random = state.rng.random();
    // `ensureTotalCapacity(max_balls)` already ran in initState, so
    // appendAssumeCapacity is correct here — we just checked the cap
    // above, and the reserved capacity never shrinks.
    state.balls.appendAssumeCapacity(.{
        .position = at,
        .speed = .{ randomSpeed(rand), randomSpeed(rand) },
        .prev_position = .{ 0, 0 },
        .radius = 20.0 + float(rand.intRangeAtMost(i32, 0, 30)),
        .color = .{ .r = randomU8(rand), .g = randomU8(rand), .b = randomU8(rand), .a = 255 },
        .grabbed = false,
    });
}

fn shakeAll(state: *State) void {
    const rand: std.Random = state.rng.random();
    for (state.balls.items) |*b| {
        if (b.grabbed) {
            continue;
        }
        b.speed = .{
            float(rand.intRangeAtMost(i32, -2000, 2000)),
            float(rand.intRangeAtMost(i32, -2000, 2000)),
        };
    }
}

fn drawUiPanel(f: *z.Frame, s: *State) bool {
    const u: z.ui_real.Ui = s.ui_host.begin(f);

    if (u.window("Physics", .{})) |w| {
        defer w.close();

        u.text("LMB grab / throw, RMB spawn", .{});
        u.separator();

        _ = u.slider("Gravity", &s.gravity, .{ .min = -500, .max = 1500, .fmt = "{d:.0}" });
        _ = u.slider("Friction", &s.friction, .{ .min = 0.80, .max = 1.0, .fmt = "{d:.3}" });
        _ = u.slider("Elasticity", &s.elasticity, .{ .min = 0.0, .max = 1.0, .fmt = "{d:.2}" });

        u.separator();

        _ = u.slider("Burst count", &s.burst_count, .{ .min = 1, .max = 200, .fmt = "{d}" });
        if (u.button("Burst at cursor", .{})) {
            const mp: Vec2 = z.getMousePosition(f.input);
            var i: i32 = 0;
            while (i < s.burst_count) : (i += 1) {
                spawnBallAt(s, .{ mp[0], mp[1] });
            }
        }
        u.sameLine(.{});
        if (u.button("Shake", .{})) {
            shakeAll(s);
        }

        u.separator();

        u.text("Balls: {d} / {d}", .{ s.balls.items.len, max_balls });
        if (u.button("Clear", .{})) {
            s.balls.clearRetainingCapacity();
            s.grabbed = null;
        }
    }

    return u.wantCaptureMouse();
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);

    const ui_capture_mouse: bool = drawUiPanel(f, state);

    const dt: f32 = f.time.delta_time;
    const mp: Vec2 = z.getMousePosition(f.input);
    const mouse: Vec2 = .{ mp[0], mp[1] };
    // Live canvas dims for the physics box.  Under `.responsive`
    // mode (set in `main`) these track CSS-pixel resizes every
    // frame — the simulation box is exactly the window, no aspect-
    // ratio enforcement.  UI is absolute-pixel under `.responsive`
    // so the Physics panel keeps its physical size.  The
    // `screen_w` / `screen_h` consts at the top of this file are
    // only the initial-size hint passed to the window config.
    const box_w: f32 = f.window.widthf();
    const box_h: f32 = f.window.heightf();

    // ---- Grab ---------------------------------------------------------------
    // Iterate top-most-spawned to bottom so the youngest ball
    // wins overlapping hits - same visual layering as the
    // rendering order.  Skip canvas mouse input when the UI is
    // hovered so panel clicks don't grab balls.
    if (!ui_capture_mouse and z.isMouseButtonPressed(f.input, .left)) {
        const items: []Ball = state.balls.items;
        var i: usize = items.len;
        while (i > 0) {
            i -= 1;
            const b: *Ball = &items[i];
            const dx: f32 = mouse[0] - b.position[0];
            const dy: f32 = mouse[1] - b.position[1];
            if (@sqrt(dx * dx + dy * dy) <= b.radius) {
                state.press_offset = .{ dx, dy };
                state.grabbed = i;
                b.grabbed = true;
                break;
            }
        }
    }

    if (z.isMouseButtonReleased(f.input, .left)) {
        if (state.grabbed) |idx| {
            state.balls.items[idx].grabbed = false;
            state.grabbed = null;
        }
    }

    // ---- Spawn (RMB single shot) -------------------------------------------
    if (!ui_capture_mouse and z.isMouseButtonPressed(f.input, .right)) {
        spawnBallAt(state, mouse);
    }

    // ---- Step balls --------------------------------------------------------
    for (state.balls.items) |*b| {
        if (!b.grabbed) {
            b.position[0] += b.speed[0] * dt;
            b.position[1] += b.speed[1] * dt;

            // Walls: reposition to the edge and reflect velocity
            // with the elasticity factor.  Without the
            // reposition, fast-moving balls would tunnel through.
            if (b.position[0] + b.radius >= box_w) {
                b.position[0] = box_w - b.radius;
                b.speed[0] = -b.speed[0] * state.elasticity;
            } else if (b.position[0] - b.radius <= 0) {
                b.position[0] = b.radius;
                b.speed[0] = -b.speed[0] * state.elasticity;
            }
            if (b.position[1] + b.radius >= box_h) {
                b.position[1] = box_h - b.radius;
                b.speed[1] = -b.speed[1] * state.elasticity;
            } else if (b.position[1] - b.radius <= 0) {
                b.position[1] = b.radius;
                b.speed[1] = -b.speed[1] * state.elasticity;
            }

            b.speed[0] *= state.friction;
            b.speed[1] = b.speed[1] * state.friction + state.gravity;
        } else {
            // Grabbed ball tracks the cursor with the offset
            // captured at grab time.  Derive a "throw" velocity
            // from the per-frame position delta so releasing the
            // ball mid-swing imparts realistic momentum.
            b.position[0] = mouse[0] - state.press_offset[0];
            b.position[1] = mouse[1] - state.press_offset[1];
            if (dt > 0) {
                b.speed[0] = (b.position[0] - b.prev_position[0]) / dt;
                b.speed[1] = (b.position[1] - b.prev_position[1]) / dt;
            }
            b.prev_position = b.position;
        }
    }

    // ---- Render ------------------------------------------------------------

    z.clearViewport(f, c.raywhite);

    for (state.balls.items) |b| {
        f.gl.circle(b.position, b.radius, .{ .color = b.color, .segments = 16 });
        f.gl.circle(b.position, b.radius, .{ .color = c.black, .outline = 1 });
    }

    state.ui_host.render(f);
    z.endDrawing(f.gl);
}

/// User-owned framework integration point.  See `examples/basic.zig`
/// for the canonical comment block; this declaration is the
/// AppBridge pattern's required convention.
/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - ball physics",
            .width = screen_w,
            .height = screen_h,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
