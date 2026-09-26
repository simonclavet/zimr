//! input_actions - port of raylib [core] example - input actions.
//! raylib source: examples/core/core_input_actions.c.
//!
//! raylib's sample is about ONE idea: an ACTION MAP. Game logic never reads a
//! key directly - it asks "is ACTION_UP down?", and a small indirection layer
//! decides which physical input satisfies that action. raylib proves the point
//! by letting you swap between two keysets (WASD vs the cursor keys) while the
//! box-moving logic stays byte-for-byte identical.
//!
//! On a phone there is no keyboard, so the honest translation keeps the LESSON
//! (game logic depends only on logical actions) and swaps the two *keysets* for
//! two *input schemes* that a touch screen actually has:
//!
//!   * PAD   - a discrete D-pad (four buttons) + a Fire button. Multi-touch, so
//!             two thumbs give real diagonals and simultaneous fire.
//!   * STICK - a virtual analog stick: drag inside the ring, the knob's offset
//!             past a dead-zone becomes the same four direction actions.
//!
//! Both schemes fill the SAME `Actions` struct; the box update and the on-screen
//! read-out consume only that struct and cannot tell which scheme produced it -
//! which is the entire raylib lesson, made tactile. Toggle the scheme live and
//! watch the identical logic keep working.
//!
//! No new engine primitive: the action map is a tiny in-example construct (raw
//! touch/mouse in, logical `Actions` out). `.memory = .managed`: only the UI
//! font is owned, freed in `deinit`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const clamp = zm.clamp;
const Vec2 = zm.Vec2;
const Color = zm.Color;
const c = z.colors;
const common = @import("example_common");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const Scheme = enum { pad, stick };

/// The logical action set - the ONLY thing the game logic reads.
const Actions = struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    /// Edge-triggered: true only on the frame Fire goes down.
    fire_pressed: bool = false,
};

const State = struct {
    ui_font: z.Font,
    scheme: Scheme = .pad,
    box: Vec2 = .{ 0, 0 },
    /// Fire button held last frame, so a press is an edge not a level.
    fire_was_down: bool = false,
    /// Fire feedback: expanding ring, seconds remaining.
    flash: f32 = 0,
    /// Latest actions, kept for the on-screen read-out.
    acts: Actions = .{},
    /// Live knob offset for the stick scheme (for drawing), in px.
    knob: Vec2 = .{ 0, 0 },
    initialised: bool = false,
};

/// Control geometry, recomputed each frame from the window size so it adapts to
/// portrait/landscape and any screen. All positions are in logical px.
const Layout = struct {
    play: z.Rectangle,
    /// D-pad / stick base centre + button/base radius.
    left_center: Vec2,
    dir_radius: f32,
    base_radius: f32,
    fire_center: Vec2,
    fire_radius: f32,
    toggle: z.Rectangle,
};

fn computeLayout(fw: f32, fh: f32) Layout {
    const band: f32 = @min(280.0, fh * 0.42);
    const play: z.Rectangle = .{ .x = 12, .y = 56, .width = fw - 24, .height = fh - band - 68 };
    const cy: f32 = fh - band * 0.5;
    const dir_r: f32 = @min(44.0, band * 0.16);
    return .{
        .play = play,
        .left_center = .{ fw * 0.24, cy },
        .dir_radius = dir_r,
        .base_radius = dir_r * 2.1,
        .fire_center = .{ fw * 0.78, cy },
        .fire_radius = @min(58.0, band * 0.2),
        .toggle = .{ .x = fw - 150, .y = 12, .width = 138, .height = 34 },
    };
}

fn dpadButtonCenter(lay: Layout, dir: u2) Vec2 {
    // 0=up 1=down 2=left 3=right, arranged as a cross around left_center.
    const g: f32 = lay.dir_radius * 1.15;
    const p: Vec2 = lay.left_center;
    return switch (dir) {
        0 => .{ p[0], p[1] - g },
        1 => .{ p[0], p[1] + g },
        2 => .{ p[0] - g, p[1] },
        3 => .{ p[0] + g, p[1] },
    };
}

fn within(point: Vec2, center: Vec2, radius: f32) bool {
    const dx: f32 = point[0] - center[0];
    const dy: f32 = point[1] - center[1];
    return dx * dx + dy * dy <= radius * radius;
}

fn pointInRect(point: Vec2, r: z.Rectangle) bool {
    return point[0] >= r.x and point[0] <= r.x + r.width and
        point[1] >= r.y and point[1] <= r.y + r.height;
}

/// Gather every active pointer this frame (all touch points; else mouse if the
/// left button is held) into `buf`, returning the count.
fn gatherPoints(f: *z.Frame, buf: []Vec2) usize {
    var n: usize = 0;
    const tc: i32 = z.getTouchPointCount(f.input);
    var i: i32 = 0;
    while (i < tc and n < buf.len) : (i += 1) {
        buf[n] = z.getTouchPosition(f.input, i);
        n += 1;
    }
    if (n == 0 and z.isMouseButtonDown(f.input, .left)) {
        buf[0] = z.getMousePosition(f.input);
        n = 1;
    }
    return n;
}

/// PAD scheme: OR every pointer against each button. `fire_down` is the raw
/// (level) fire state; the caller turns it into an edge.
fn readPad(
    points: []const Vec2,
    lay: Layout,
    fire_down: *bool,
) Actions {
    var a: Actions = .{};
    for (points) |p| {
        if (within(p, dpadButtonCenter(lay, 0), lay.dir_radius)) {
            a.up = true;
        }
        if (within(p, dpadButtonCenter(lay, 1), lay.dir_radius)) {
            a.down = true;
        }
        if (within(p, dpadButtonCenter(lay, 2), lay.dir_radius)) {
            a.left = true;
        }
        if (within(p, dpadButtonCenter(lay, 3), lay.dir_radius)) {
            a.right = true;
        }
        if (within(p, lay.fire_center, lay.fire_radius)) {
            fire_down.* = true;
        }
    }
    return a;
}

/// STICK scheme: the first pointer inside the base becomes the stick; its offset
/// past a dead-zone maps to the four direction actions. `out_knob` receives the
/// clamped knob offset for drawing. Fire stays a button.
fn readStick(
    points: []const Vec2,
    lay: Layout,
    fire_down: *bool,
    out_knob: *Vec2,
) Actions {
    var a: Actions = .{};
    out_knob.* = .{ 0, 0 };
    const dead: f32 = lay.base_radius * 0.28;
    for (points) |p| {
        if (within(p, lay.fire_center, lay.fire_radius)) {
            fire_down.* = true;
        }
    }
    for (points) |p| {
        if (!within(p, lay.left_center, lay.base_radius)) {
            continue;
        }
        var off: Vec2 = .{ p[0] - lay.left_center[0], p[1] - lay.left_center[1] };
        const len: f32 = @sqrt(off[0] * off[0] + off[1] * off[1]);
        if (len > lay.base_radius) {
            const s: f32 = lay.base_radius / len;
            off = .{ off[0] * s, off[1] * s };
        }
        out_knob.* = off;
        if (off[1] < -dead) {
            a.up = true;
        }
        if (off[1] > dead) {
            a.down = true;
        }
        if (off[0] < -dead) {
            a.left = true;
        }
        if (off[0] > dead) {
            a.right = true;
        }
        break;
    }
    return a;
}

/// Top-left position that centres a `size`-square box in `play`.
fn playCenter(play: z.Rectangle, size: f32) Vec2 {
    return .{ play.x + play.width * 0.5 - size * 0.5, play.y + play.height * 0.5 - size * 0.5 };
}

/// PURE game logic: move the box by the actions. Reads ONLY `Actions` - it has
/// no idea which scheme produced them. Returns the new position, clamped to the
/// play rect. This is the whole point of the action map.
fn applyActions(
    box: Vec2,
    size: f32,
    acts: Actions,
    dt: f32,
    play: z.Rectangle,
) Vec2 {
    const speed: f32 = 320.0;
    var p: Vec2 = box;
    if (acts.up) {
        p[1] -= speed * dt;
    }
    if (acts.down) {
        p[1] += speed * dt;
    }
    if (acts.left) {
        p[0] -= speed * dt;
    }
    if (acts.right) {
        p[0] += speed * dt;
    }
    const min_x: f32 = play.x;
    const min_y: f32 = play.y;
    const max_x: f32 = play.x + play.width - size;
    const max_y: f32 = play.y + play.height - size;
    p[0] = clamp(p[0], min_x, max_x);
    p[1] = clamp(p[1], min_y, max_y);
    return p;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .ui_font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20) };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.ui_font);
}

fn update(f: *z.Frame, s: *State) void {
    const fw: f32 = f.window.widthf();
    const fh: f32 = f.window.heightf();
    const dt: f32 = f.time.delta_time;
    const lay: Layout = computeLayout(fw, fh);
    const box_size: f32 = 44;

    // Centre the box on first frame (needs a valid layout).
    if (!s.initialised) {
        s.box = playCenter(lay.play, box_size);
        s.initialised = true;
    }

    // ---- input -> actions (the swappable layer) ---------------------------
    var pbuf: [8]Vec2 = undefined;
    const np: usize = gatherPoints(f, &pbuf);
    const points: []const Vec2 = pbuf[0..np];

    var fire_down: bool = false;
    var knob: Vec2 = .{ 0, 0 };
    const acts: Actions = switch (s.scheme) {
        .pad => readPad(points, lay, &fire_down),
        .stick => readStick(points, lay, &fire_down, &knob),
    };

    // Scheme toggle (its own hit region, so it never feeds the game).
    var toggled: bool = false;
    for (points) |p| {
        if (pointInRect(p, lay.toggle)) {
            toggled = true;
        }
    }
    // toggle is edge-triggered off the same fire_was_down guard? No - give it
    // its own edge via a static-ish check: only flip when a fresh press lands.
    // Reuse fire edge machinery would double-fire, so gate on !fire_was_down and
    // require the toggle not to have been held: track via the flash-free path.
    if (toggled and !s.fire_was_down and np == 1) {
        // a single fresh pointer on the toggle flips the scheme
        s.scheme = if (s.scheme == .pad) .stick else .pad;
    }

    var out_acts: Actions = acts;
    out_acts.fire_pressed = fire_down and !s.fire_was_down;
    s.fire_was_down = fire_down or toggled;

    // ---- game logic (reads ONLY actions) ----------------------------------
    s.box = applyActions(s.box, box_size, out_acts, dt, lay.play);
    if (out_acts.fire_pressed) {
        s.box = playCenter(lay.play, box_size);
        s.flash = 0.45;
    }
    if (s.flash > 0) {
        s.flash -= dt;
    }
    s.acts = out_acts;
    s.knob = knob;

    // ---- draw -------------------------------------------------------------
    z.clearViewport(f, .{ .r = 15, .g = 17, .b = 24, .a = 255 });
    common.backdrop(f.gl, fw, fh);

    // play area frame
    f.gl.rect(lay.play, .{ .color = .{ .r = 30, .g = 34, .b = 44, .a = 255 }, .outline = 1.0 });

    // fire flash ring
    if (s.flash > 0) {
        const t: f32 = 1.0 - s.flash / 0.45;
        const cx: f32 = lay.play.x + lay.play.width * 0.5;
        const cy2: f32 = lay.play.y + lay.play.height * 0.5;
        const a8: u8 = @trunc(@max(0.0, 200.0 * (1.0 - t)));
        f.gl.circle(.{ cx, cy2 }, 20.0 + 90.0 * t, .{
            .color = .{ .r = 240, .g = 190, .b = 90, .a = a8 },
            .outline = 3.0,
            .segments = 40,
        });
    }

    // the box
    f.gl.rectRoundedXYWH(s.box[0], s.box[1], box_size, box_size, 0.3, 8, .{ .color = c.sky_400 });
    f.gl.rectRoundedXYWH(s.box[0], s.box[1], box_size, box_size, 0.3, 8, .{ .color = c.sky_200, .outline = 2.0 });

    drawControls(f, s, lay);
    drawReadout(f, s, lay);

    common.caption(
        f.gl,
        s.ui_font,
        "Action map: the box logic reads only logical actions - swap the input scheme, it never notices",
    );
    z.endDrawing(f.gl);
}

fn dirActive(a: Actions, dir: u2) bool {
    return switch (dir) {
        0 => a.up,
        1 => a.down,
        2 => a.left,
        3 => a.right,
    };
}

fn drawControls(f: *z.Frame, s: *State, lay: Layout) void {
    const idle: Color = .{ .r = 44, .g = 50, .b = 62, .a = 255 };
    const hot: Color = c.sky_500;

    // scheme toggle button
    f.gl.rectRoundedXYWH(lay.toggle.x, lay.toggle.y, lay.toggle.width, lay.toggle.height, 0.4, 8, .{
        .color = .{ .r = 50, .g = 56, .b = 70, .a = 255 },
    });
    const label: []const u8 = if (s.scheme == .pad) "scheme: PAD" else "scheme: STICK";
    f.gl.text(.{ lay.toggle.x + 12, lay.toggle.y + 9 }, label, .{
        .size = 15,
        .color = c.slate_100,
        .font = &s.ui_font,
    });

    switch (s.scheme) {
        .pad => {
            var d: u2 = 0;
            while (true) : (d += 1) {
                const ctr: Vec2 = dpadButtonCenter(lay, d);
                const on: bool = dirActive(s.acts, d);
                f.gl.circle(ctr, lay.dir_radius, .{ .color = if (on) hot else idle, .segments = 24 });
                f.gl.circle(ctr, lay.dir_radius, .{ .color = c.slate_500, .outline = 1.5, .segments = 24 });
                drawArrow(f, ctr, d, lay.dir_radius * 0.5);
                if (d == 3) {
                    break;
                }
            }
        },
        .stick => {
            f.gl.circle(lay.left_center, lay.base_radius, .{
                .color = .{ .r = 34, .g = 39, .b = 50, .a = 255 },
                .segments = 40,
            });
            f.gl.circle(lay.left_center, lay.base_radius, .{ .color = c.slate_600, .outline = 1.5, .segments = 40 });
            const knob_c: Vec2 = .{ lay.left_center[0] + s.knob[0], lay.left_center[1] + s.knob[1] };
            const moving: bool = s.acts.up or s.acts.down or s.acts.left or s.acts.right;
            f.gl.circle(knob_c, lay.base_radius * 0.42, .{ .color = if (moving) hot else idle, .segments = 28 });
            f.gl.circle(knob_c, lay.base_radius * 0.42, .{ .color = c.slate_400, .outline = 1.5, .segments = 28 });
        },
    }

    // fire button (both schemes)
    const fire_hot: bool = s.acts.fire_pressed;
    const fire_fill: Color = if (fire_hot) c.amber_400 else .{ .r = 90, .g = 44, .b = 44, .a = 255 };
    f.gl.circle(lay.fire_center, lay.fire_radius, .{ .color = fire_fill, .segments = 32 });
    f.gl.circle(lay.fire_center, lay.fire_radius, .{
        .color = .{ .r = 190, .g = 33, .b = 55, .a = 255 },
        .outline = 2.0,
        .segments = 32,
    });
    const fx: f32 = lay.fire_center[0] - z.measureText(s.ui_font, "FIRE", 16)[0] * 0.5;
    f.gl.text(.{ fx, lay.fire_center[1] - 8 }, "FIRE", .{ .size = 16, .color = c.slate_100, .font = &s.ui_font });
}

fn drawArrow(f: *z.Frame, ctr: Vec2, dir: u2, r: f32) void {
    const col: Color = c.slate_200;
    const a: Vec2 = switch (dir) {
        0 => .{ ctr[0], ctr[1] - r },
        1 => .{ ctr[0], ctr[1] + r },
        2 => .{ ctr[0] - r, ctr[1] },
        3 => .{ ctr[0] + r, ctr[1] },
    };
    const b: Vec2 = switch (dir) {
        0 => .{ ctr[0] - r * 0.7, ctr[1] + r * 0.4 },
        1 => .{ ctr[0] - r * 0.7, ctr[1] - r * 0.4 },
        2 => .{ ctr[0] + r * 0.4, ctr[1] - r * 0.7 },
        3 => .{ ctr[0] - r * 0.4, ctr[1] - r * 0.7 },
    };
    const e: Vec2 = switch (dir) {
        0 => .{ ctr[0] + r * 0.7, ctr[1] + r * 0.4 },
        1 => .{ ctr[0] + r * 0.7, ctr[1] - r * 0.4 },
        2 => .{ ctr[0] + r * 0.4, ctr[1] + r * 0.7 },
        3 => .{ ctr[0] - r * 0.4, ctr[1] + r * 0.7 },
    };
    f.gl.triangle(a, b, e, .{ .color = col });
}

fn drawReadout(f: *z.Frame, s: *State, lay: Layout) void {
    const x: f32 = lay.play.x + 12;
    var y: f32 = lay.play.y + 10;
    f.gl.text(.{ x, y }, "logical actions (what the game sees):", .{
        .size = 14,
        .color = c.slate_400,
        .font = &s.ui_font,
    });
    y += 24;
    const names = [_][]const u8{ "UP", "DOWN", "LEFT", "RIGHT", "FIRE" };
    const on = [_]bool{ s.acts.up, s.acts.down, s.acts.left, s.acts.right, s.acts.fire_pressed };
    var cx: f32 = x;
    for (names, on) |nm, active| {
        const col: Color = if (active) c.emerald_400 else .{ .r = 60, .g = 66, .b = 78, .a = 255 };
        const w: f32 = z.measureText(s.ui_font, nm, 16)[0] + 18;
        f.gl.rectRoundedXYWH(cx, y, w, 26, 0.4, 6, .{ .color = col });
        const tcol: Color = if (active) .{ .r = 10, .g = 20, .b = 15, .a = 255 } else c.slate_300;
        f.gl.text(.{ cx + 9, y + 5 }, nm, .{ .size = 16, .color = tcol, .font = &s.ui_font });
        cx += w + 8;
    }
}

/// Descriptor-only: the runner/launcher drives begin/end (no offscreen pass).
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - input actions",
            .width = 720,
            .height = 720,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
