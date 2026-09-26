//! fps_playground - a first-person character walking a world of physics cubes.
//! The player is a `CharacterVirtual` (the engine's ported Jolt capsule character
//! controller): a capsule that sweeps through the world, slides along walls, walks
//! up small steps, sticks to the floor on slopes, and reports whether it is on the
//! ground. Scattered around are random-sized dynamic cubes that fall into a pile
//! you can walk into, shove, and jump on top of. Everything the character touches
//! is real physics.
//!
//! Controls are built for both a keyboard and a phone:
//!   WASD / left stick     move
//!   mouse (click to lock) / right-drag   look
//!   space / jump button   jump (only when standing on something)
//!   esc                   release the mouse
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const clamp = zm.clamp;
const common = @import("example_common");

/// A wasm safety trap is a bare `RuntimeError: unreachable` without this - no message, no line.
/// See `common.reportPanic`: six turns of debugging went to a panic that named itself in one
/// build once a handler existed.
pub const panic = std.debug.FullPanic(common.reportPanic);
const render = @import("render.zig");

const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const float = zm.float;
const vec = zm.vec;
const splat = zm.splat;
const pi = zm.pi;
const c = z.colors;
const zp = z.zimrphysics;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const num_cubes = 18;
const eye_height = 1.5; // camera height above the capsule origin
const cap_half_height = 0.6; // capsule cylinder half-height
const cap_radius = 0.35;
const move_speed = 5.0; // m/s on the ground
const jump_speed = 6.0; // m/s launched upward
const jump_buffer_time = 0.15; // s a jump request survives waiting for the ground
const mouse_sens = 0.0026; // radians per pixel of mouse motion
const drag_sens = 0.005; // radians per pixel of touch drag

const sky_col: Color = .{ .r = 30, .g = 38, .b = 52, .a = 255 };
const btn_col: Color = .{ .r = 34, .g = 40, .b = 54, .a = 220 };
const btn_hot_col: Color = .{ .r = 64, .g = 78, .b = 104, .a = 245 };
const stick_col: Color = .{ .r = 70, .g = 84, .b = 110, .a = 180 };
const stick_knob_col: Color = .{ .r = 150, .g = 168, .b = 200, .a = 230 };
const cross_col: Color = .{ .r = 220, .g = 228, .b = 240, .a = 220 };

const cube_palette = [_]Color{
    c.amber_400,
    c.emerald_400,
    c.sky_400,
    c.rose_400,
    c.violet_400,
    c.green_400,
};

/// A screen-space rectangle for the on-screen buttons.
const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    fn contains(self: Rect, p: Vec2) bool {
        return p[0] >= self.x and p[0] <= self.x + self.w and
            p[1] >= self.y and p[1] <= self.y + self.h;
    }
};

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    gestures: z.GesturesState = .{},
    rng: std.Random.DefaultPrng,

    world: zp.World,
    player: zp.CharacterVirtual,
    vel_y: f32 = 0, // vertical velocity we own (character owns horizontal slide)
    yaw: f32 = 0, // radians, 0 looks down -Z
    pitch: f32 = 0, // radians, clamped
    mouse_locked: bool = false,
    phys_accum: f32 = 0,

    /// The finger id currently driving the move stick, and where it started.
    stick_touch: ?i32 = null,
    stick_origin: Vec2 = .{ 0, 0 },
    stick_cur: Vec2 = .{ 0, 0 },
    /// The finger id currently driving look (right half of the screen).
    look_touch: ?i32 = null,
    look_prev: Vec2 = .{ 0, 0 },
    /// The finger currently resting on the jump button. Held so the button is
    /// EDGE-triggered: a resting finger must not re-jump the moment we land.
    jump_touch: ?i32 = null,
    /// Seconds left on a buffered jump request. A tap lasts ONE frame; if that
    /// frame happens not to be a grounded one the jump would be silently lost,
    /// which is what made the button feel like it worked only once. Standard
    /// jump-buffering: remember the request briefly and spend it on landing.
    jump_buffer: f32 = 0,
    /// True once a mouse drag has produced at least one frame of motion. The
    /// first frame is skipped because getMouseDelta is current - previous, and
    /// `previous` is stale across the not-dragging -> dragging boundary.
    mouse_dragging: bool = false,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var world: zp.World = try zp.World.init(gpa, 256);

    // Floor: a big flat static box centred at the origin, top at y = 0.
    const floor_shape: zp.ShapeId = try world.shapes.add(gpa, .{
        .box = .{ .half_extent = vec(30.0, 0.5, 30.0), .convex_radius = 0.05 },
    });
    _ = try world.createBody(.{
        .shape = floor_shape,
        .position = vec(0.0, -0.5, 0.0),
        .motion_type = .static,
        .material = 0,
    });

    var rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0xF00D_CA75);
    const rand: std.Random = rng.random();

    // A scatter of random-sized dynamic cubes that fall into a loose pile.
    var i: usize = 0;
    while (i < num_cubes) : (i += 1) {
        const he: f32 = 0.3 + rand.float(f32) * 0.7; // half-extent 0.3 .. 1.0
        const shape: zp.ShapeId = try world.shapes.add(gpa, .{
            .box = .{ .half_extent = vec(he, he, he), .convex_radius = 0.03 },
        });
        const px: f32 = (rand.float(f32) - 0.5) * 12.0;
        const pz: f32 = (rand.float(f32) - 0.5) * 12.0;
        const py: f32 = 2.0 + rand.float(f32) * 6.0;
        _ = try world.createBody(.{
            .shape = shape,
            .position = vec(px, py, pz),
            .material = @intCast(1 + (i % cube_palette.len)),
        });
    }

    // The player: a capsule character controller, dropped in a clear spot.
    const cap_shape: zp.ShapeId = try world.shapes.add(gpa, .{
        .capsule = .{ .half_height = cap_half_height, .radius = cap_radius },
    });

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .rng = rng,
        .world = world,
        .player = .{
            .shape = cap_shape,
            .position = vec(0.0, 1.2, 9.0),
        },
        .yaw = pi, // look toward -Z, into the pile
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.player.deinit(gpa);
    s.world.deinit(gpa);
    s.scratch.deinit();
}

/// Horizontal forward/right basis vectors derived from the yaw angle.
const Basis = struct { fwd: Vec, right: Vec };

/// Forward and right unit vectors on the horizontal plane, from the current yaw.
fn yawBasis(s: *const State) Basis {
    const sy: f32 = @sin(s.yaw);
    const cy: f32 = @cos(s.yaw);
    // yaw 0 -> -Z; positive yaw turns toward +X.
    const fwd: Vec = vec(sy, 0.0, -cy);
    const right: Vec = vec(cy, 0.0, sy);
    return .{ .fwd = fwd, .right = right };
}

fn button(
    f: *z.Frame,
    s: *State,
    r: Rect,
    label: []const u8,
    hot: bool,
) void {
    f.gl.rect(.{ .x = r.x, .y = r.y, .width = r.w, .height = r.h }, .{ .color = if (hot) btn_hot_col else btn_col });
    const approx_w: f32 = float(@as(i32, @intCast(label.len))) * 10.0;
    f.gl.text(
        .{ r.x + (r.w - approx_w) / 2.0, r.y + r.h / 2.0 - 9.0 },
        label,
        .{ .size = 18, .color = cross_col, .font = &s.font },
    );
}

fn jumpButtonRect(f: *z.Frame) Rect {
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    const d: f32 = @max(64.0, sh * 0.16);
    return .{ .x = sw - d - 24.0, .y = sh - d - 24.0, .w = d, .h = d };
}

/// Read all input and produce a horizontal wish-direction (world units, unit-ish)
/// The per-frame control output.
const Controls = struct { wish: Vec, jump: bool };

/// plus whether a jump was requested this frame.
fn gatherControls(f: *z.Frame, s: *State) Controls {
    var wish: Vec = vec(0.0, 0.0, 0.0);
    var jump: bool = false;
    const b: Basis = yawBasis(s);

    // --- Keyboard movement ---
    var kx: f32 = 0;
    var kz: f32 = 0;
    if (z.isKeyDown(f.input, .w)) {
        kz += 1;
    }
    if (z.isKeyDown(f.input, .s)) {
        kz -= 1;
    }
    if (z.isKeyDown(f.input, .d)) {
        kx += 1;
    }
    if (z.isKeyDown(f.input, .a)) {
        kx -= 1;
    }
    wish += b.fwd * splat(kz) + b.right * splat(kx);

    if (z.isKeyPressed(f.input, .space)) {
        jump = true;
    }

    // --- Mouse look (desktop only) ---
    // Drag-to-look is the primary mechanism and works everywhere (including
    // sandboxed iframes, where pointer lock is blocked): hold the left button and
    // move to look. We also *try* pointer lock as an optional upgrade for a nicer
    // desktop feel -- if the browser grants it, look becomes free-move instead of
    // drag; if it doesn't, the request is swallowed and drag-look keeps working.
    //
    // THIS BLOCK MUST NOT RUN ON TOUCH. A phone reports every finger as a
    // synthesized left button AND a mouse position, so running it beside
    // gatherTouch made EVERY touch rotate the camera: the stick finger steered
    // the view instead of walking, and the jump finger did too (getMousePosition
    // reports only the primary pointer, so `over_ui` sees the OTHER finger and
    // lets the jump through as a drag). Touch owns the pointer whenever a finger
    // is down; two look drivers must never be live at once.
    if (z.isKeyPressed(f.input, .escape)) {
        z.enableCursor(f.input);
        s.mouse_locked = false;
    }
    const touch_count: i32 = z.getTouchPointCount(f.input);
    if (touch_count == 0) {
        const over_ui: bool = overUi(f, z.getMousePosition(f.input));
        if (z.isMouseButtonPressed(f.input, .left) and !over_ui) {
            // Optional: ask for pointer lock. Harmless if refused.
            z.disableCursor(f.input);
            s.mouse_locked = true; // provisional; corrected below by the real state
        }
        // Look from mouse motion when the pointer is actually captured, OR while
        // the left button is held (drag-look). getMouseDelta is relative motion in
        // both cases, so the same maths serves both.
        const captured: bool = z.isCursorHidden(f.input);
        const dragging: bool = z.isMouseButtonDown(f.input, .left) and !over_ui;
        if (captured or dragging) {
            // Skip the FIRST frame of a drag: `previous` is wherever the pointer
            // last was, so frame 1 is a jump across the screen, not a motion.
            if (s.mouse_dragging) {
                const d: Vec2 = z.getMouseDelta(f.input);
                s.yaw += d[0] * mouse_sens;
                s.pitch -= d[1] * mouse_sens;
            }
            s.mouse_dragging = true;
        } else {
            s.mouse_dragging = false;
        }
        if (!captured) {
            s.mouse_locked = false;
        }
    } else {
        // A finger is down. Drop any half-finished mouse drag so that when the
        // fingers lift, the next real mouse drag starts from a fresh baseline.
        s.mouse_dragging = false;
    }

    // --- Touch: left half = move stick, right half = look, plus jump button ---
    z.updateGestures(&s.gestures, f.input, f.time);
    gatherTouch(f, s, &wish, &jump, b);

    // Clamp pitch so you can't flip over.
    const lim: f32 = pi * 0.49;
    if (s.pitch > lim) {
        s.pitch = lim;
    }
    if (s.pitch < -lim) {
        s.pitch = -lim;
    }

    // Normalise horizontal wish so diagonals aren't faster.
    const wlen: f32 = @sqrt(wish[0] * wish[0] + wish[2] * wish[2]);
    if (wlen > 1.0) {
        wish[0] /= wlen;
        wish[2] /= wlen;
    }
    return .{ .wish = wish, .jump = jump };
}

fn overUi(f: *z.Frame, p: Vec2) bool {
    return jumpButtonRect(f).contains(p);
}

/// Multi-touch handling: assign one finger to the move stick (left half), one to
/// look (right half), and detect a tap on the jump button.
fn gatherTouch(
    f: *z.Frame,
    s: *State,
    wish: *Vec,
    jump: *bool,
    b: Basis,
) void {
    const count: i32 = z.getTouchPointCount(f.input);
    const sw: f32 = f.window.widthf();

    // Drop fingers that lifted.
    if (s.stick_touch) |id| {
        if (!touchAlive(f, id)) {
            s.stick_touch = null;
        }
    }
    if (s.look_touch) |id| {
        if (!touchAlive(f, id)) {
            s.look_touch = null;
        }
    }
    if (s.jump_touch) |id| {
        if (!touchAlive(f, id)) {
            s.jump_touch = null;
        }
    }

    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const id: i32 = z.getTouchPointId(f.input, i);
        const p: Vec2 = z.getTouchPosition(f.input, i);

        // ROUTE BY OWNER FIRST. A finger's role is decided once, on the frame it
        // arrives, and is never re-tested afterwards. The half-screen split used
        // to be re-evaluated from the finger's CURRENT position every frame, so
        // dragging a stick finger across the midline handed it to look (the
        // camera span) while the stick froze at its last left-half sample, and
        // dragging a look finger the other way grabbed the move stick. Where a
        // finger STARTED is what decides; where it travels is just motion.
        if (s.jump_touch != null and s.jump_touch.? == id) {
            continue;
        }
        if (s.stick_touch != null and s.stick_touch.? == id) {
            s.stick_cur = p;
            continue;
        }
        if (s.look_touch != null and s.look_touch.? == id) {
            const dx: f32 = p[0] - s.look_prev[0];
            const dy: f32 = p[1] - s.look_prev[1];
            s.yaw += dx * drag_sens;
            s.pitch -= dy * drag_sens;
            s.look_prev = p;
            continue;
        }

        // An unclaimed finger: assign its role from where it landed.
        // Jump is EDGE-triggered -- firing every frame a finger rested on the
        // button would re-jump the instant we touched down again.
        if (jumpButtonRect(f).contains(p)) {
            if (s.jump_touch == null) {
                s.jump_touch = id;
                jump.* = true;
            }
            continue;
        }
        if (p[0] < sw * 0.5) {
            if (s.stick_touch == null) {
                s.stick_touch = id;
                s.stick_origin = p;
                s.stick_cur = p;
            }
        } else {
            if (s.look_touch == null) {
                s.look_touch = id;
                s.look_prev = p;
            }
        }
    }

    // Apply the move stick as a wish-direction.
    if (s.stick_touch != null) {
        const dx: f32 = s.stick_cur[0] - s.stick_origin[0];
        const dy: f32 = s.stick_cur[1] - s.stick_origin[1];
        const dead: f32 = 8.0;
        const maxr: f32 = 70.0;
        const mag: f32 = @sqrt(dx * dx + dy * dy);
        if (mag > dead) {
            const scale: f32 = @min(mag, maxr) / maxr;
            const nx: f32 = dx / mag;
            const ny: f32 = dy / mag;
            // Up on screen (negative y) = forward.
            wish.* += b.fwd * splat(-ny * scale) + b.right * splat(nx * scale);
        }
    }
}

fn touchAlive(f: *z.Frame, id: i32) bool {
    const count: i32 = z.getTouchPointCount(f.input);
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        if (z.getTouchPointId(f.input, i) == id) {
            return true;
        }
    }
    return false;
}

fn update(f: *z.Frame, s: *State) void {
    _ = s.scratch.reset(.retain_capacity);
    const arena: Allocator = s.scratch.allocator();

    const ctl: Controls = gatherControls(f, s);

    // Vertical velocity: we integrate gravity ourselves and set it on the
    // character; the character owns the horizontal slide against the world.
    const grounded: bool = s.player.isSupported();
    if (grounded and s.vel_y < 0) {
        s.vel_y = 0; // rest on the ground
    }
    // Buffer the request rather than requiring the tap to land on a grounded
    // frame: isSupported() flickers while the capsule settles, so a one-frame
    // request loses the race often enough to feel broken.
    if (ctl.jump) {
        s.jump_buffer = jump_buffer_time;
    }
    if (s.jump_buffer > 0 and grounded) {
        s.vel_y = jump_speed;
        s.jump_buffer = 0;
    }
    s.jump_buffer = @max(0.0, s.jump_buffer - f.time.delta_time);
    s.vel_y += -9.81 * f.time.delta_time;

    // Compose the character velocity: horizontal from input, vertical from us.
    const horiz: Vec = ctl.wish * splat(move_speed);
    s.player.linear_velocity = vec(horiz[0], s.vel_y, horiz[2]);

    // Fixed-timestep stepping for both the character and the cubes.
    const fixed_dt: f32 = 1.0 / 60.0;
    s.phys_accum += clamp(f.time.delta_time, 0.0, 0.1);
    var sub: u32 = 0;
    while (s.phys_accum >= fixed_dt and sub < 4) : (sub += 1) {
        zp.characterExtendedUpdate(
            &s.world,
            &s.player,
            fixed_dt,
            vec(0.0, -9.81, 0.0),
            .{},
            arena,
            // These two can only fail by running out of memory: the frame callback that contains them
            // returns `void` by the engine's design, so there is nothing to propagate to. Swallowing
            // leaves the world un-stepped for one frame, which is the least-bad outcome available here -
            // and is why the rule wants it said out loud rather than written silently.
            // lint:off catch-suppression: OOM only, void callback - see above
        ) catch {};
        // lint:off catch-suppression: OOM only, void callback - see above
        zp.step(&s.world, fixed_dt) catch {};
        s.phys_accum -= fixed_dt;
    }
    if (s.phys_accum > fixed_dt) {
        s.phys_accum = 0;
    }

    // Camera at eye height, looking along yaw/pitch.
    const eye: Vec = s.player.position + vec(0.0, eye_height, 0.0);
    const cp: f32 = @cos(s.pitch);
    const dir: Vec = vec(@sin(s.yaw) * cp, @sin(s.pitch), -@cos(s.yaw) * cp);
    const cam: Camera3D = .{
        .position = eye,
        .target = eye + dir,
        .up = vec(0.0, 1.0, 0.0),
        .fovy_deg = 70,
        .projection = 0,
    };

    z.beginDrawing(f.gl);
    z.clearBackground(f.gl, sky_col);

    z.beginMode3D(f.gl, cam);
    const style: render.Style = .{ .palette = &cube_palette, .static_color = c.slate_600 };
    render.drawWorld(f.gl, &s.world, style);
    z.endMode3D(f.gl);

    drawHud(f, s, grounded);
    z.endDrawing(f.gl);
}

fn drawHud(f: *z.Frame, s: *State, grounded: bool) void {
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();

    // Crosshair.
    const cx: f32 = sw / 2.0;
    const cy: f32 = sh / 2.0;
    f.gl.line(.{ cx - 10, cy }, .{ cx + 10, cy }, .{ .color = cross_col, .thickness = 2.0 });
    f.gl.line(.{ cx, cy - 10 }, .{ cx, cy + 10 }, .{ .color = cross_col, .thickness = 2.0 });

    // Move stick, drawn where the finger grabbed.
    if (s.stick_touch != null) {
        f.gl.circle(s.stick_origin, 70.0, .{ .color = stick_col, .segments = 28 });
        f.gl.circle(s.stick_cur, 30.0, .{ .color = stick_knob_col, .segments = 20 });
    }

    // Jump button.
    const jb: Rect = jumpButtonRect(f);
    button(f, s, jb, "JUMP", false);

    const status: []const u8 = allocPrint(
        s.scratch.allocator(),
        "fps playground - {s} - {s}",
        .{
            if (grounded) "on ground" else "in air",
            if (s.mouse_locked) "mouse captured (esc to release)" else "drag to look - WASD to move",
        },
    ) catch "fps playground";
    common.caption(f.gl, s.font, status);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - fps playground",
            .width = 900,
            .height = 520,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
