//! langton_ant — Langton's Ant, the two-rule cellular automaton whose ant paints
//! chaos for ~10,000 steps and then, astonishingly, builds a repeating diagonal
//! "highway" forever. The whole rule is four lines: on a white cell turn right, on
//! a black cell turn left; flip the cell you leave; step forward one square.
//!
//! To make the rule legible we draw the last ten TURNS as a red polyline with a
//! little L/R glyph at each turn, so you can read "white here, so it turned right"
//! straight off the screen. Pan and zoom (mouse wheel + drag, or pinch + drag on a
//! phone) to follow the ant in close, and slow the speed right down to watch one
//! move at a time.
//!
//! Controls:
//!   space            pause / resume
//!   . or right       single step (while paused)
//!   1-9              speed: steps taken per frame
//!   f                toggle follow-the-ant camera
//!   r                reset
//!   wheel / +  -     zoom     |   left-drag or pinch   zoom & pan
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const atan2Rad = zm.atan2Rad;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const grid_w = 200;
const grid_h = 200;
const path_len = 28; // footsteps kept for the trail polyline

const bg_col: Color = .{ .r = 18, .g = 21, .b = 29, .a = 255 };
const white_col: Color = .{ .r = 226, .g = 231, .b = 240, .a = 255 };
const grid_col: Color = .{ .r = 40, .g = 46, .b = 60, .a = 255 };
const ant_col: Color = .{ .r = 250, .g = 204, .b = 60, .a = 255 };
const turn_r_col: Color = .{ .r = 236, .g = 72, .b = 60, .a = 255 }; // right turn = red
const turn_l_col: Color = .{ .r = 90, .g = 160, .b = 240, .a = 255 }; // left turn = blue
const btn_col: Color = .{ .r = 34, .g = 40, .b = 54, .a = 235 };
const btn_hot_col: Color = .{ .r = 54, .g = 64, .b = 86, .a = 245 };
const btn_txt_col: Color = .{ .r = 210, .g = 216, .b = 228, .a = 255 };

/// A screen-space rectangle, for the on-screen control buttons (this runs on
/// phones with no keyboard, so every action needs a tappable target).
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

/// A heading. Turning is just stepping around this ring, so the two rules become
/// `dir.right()` and `dir.left()`; moving is a switch that nudges x/y by one.
const Dir = enum(u2) {
    up,
    right,
    down,
    left,

    fn turnRight(self: Dir) Dir {
        return @fromBackingInt(@intCast((@backingInt(self) +% 1) & 3));
    }

    fn turnLeft(self: Dir) Dir {
        return @fromBackingInt(@intCast((@backingInt(self) +% 3) & 3));
    }
};

/// One recorded turn: the cell it happened on, and which way the ant swung.
const Turn = struct {
    x: i32,
    y: i32,
    /// true = turned right (was on white), false = turned left (was on black).
    right: bool,
};

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    gestures: z.GesturesState = .{},

    /// The board: false = black, true = white. Everything starts white.
    cells: [grid_w * grid_h]bool = @splat(true),
    ant_x: i32 = grid_w / 2,
    ant_y: i32 = grid_h / 2,
    dir: Dir = .up,
    steps: u64 = 0,

    /// The ant's last `path_len` footsteps, as an adjacent chain -> a clean red
    /// polyline (consecutive cells always touch, so it never jumps across the
    /// board the way connecting scattered turn-cells did). Ring buffer.
    path: [path_len]Turn = @splat(.{ .x = 0, .y = 0, .right = false }),
    path_head: usize = 0,
    path_n: usize = 0,

    paused: bool = true,
    /// Simulation rate in steps per second. Below ~60 this is driven by a time
    /// accumulator so a slow rate is genuinely slow (1 = one step every second);
    /// above 60 we run several steps per frame. Ranges 1 .. 4096.
    steps_per_sec: f32 = 1,
    /// Seconds owed toward the next step, for the slow (sub-60/s) regime.
    step_accum: f64 = 0,

    /// Camera: which cell sits at the screen centre, and pixels per cell.
    cam_x: f32 = grid_w / 2,
    cam_y: f32 = grid_h / 2,
    zoom: f32 = 6.0,
    follow: bool = true,

    /// Drag-pan bookkeeping. We anchor the world (cell) point grabbed at press and
    /// hold it under the cursor every frame -- absolute, so it can't drift, the way
    /// mandel_sidebyside does it. Incremental `cam -= delta/zoom` was the broken
    /// version.
    dragging: bool = false,
    drag_anchor: Vec2 = .{ 0, 0 },

    fn cell(self: *const State, x: i32, y: i32) bool {
        return self.cells[@intCast(y * grid_w + x)];
    }

    fn setCell(self: *State, x: i32, y: i32, v: bool) void {
        self.cells[@intCast(y * grid_w + x)] = v;
    }
};

/// Push into a fixed ring buffer: writes at head, advances, grows n up to cap.
fn ringPush(
    comptime cap: usize,
    buf: *[cap]Turn,
    head: *usize,
    n: *usize,
    t: Turn,
) void {
    buf[head.*] = t;
    head.* = (head.* + 1) % cap;
    if (n.* < cap) {
        n.* += 1;
    }
}

/// One move of the ant, i.e. the entire simulation.
fn step(s: *State) void {
    const on_white: bool = s.cell(s.ant_x, s.ant_y);
    s.dir = if (on_white) s.dir.turnRight() else s.dir.turnLeft();
    s.setCell(s.ant_x, s.ant_y, !on_white);

    // Record the cell the ant is standing on as a footstep (for the connected
    // trail line) and as a turn (for the L/R glyph). Footsteps are consecutive
    // cells, so the line through them is always a clean adjacent path.
    const here: Turn = .{ .x = s.ant_x, .y = s.ant_y, .right = on_white };
    ringPush(path_len, &s.path, &s.path_head, &s.path_n, here);

    switch (s.dir) {
        .up => s.ant_y -= 1,
        .right => s.ant_x += 1,
        .down => s.ant_y += 1,
        .left => s.ant_x -= 1,
    }
    // Wrap at the edges so it runs forever.
    s.ant_x = @mod(s.ant_x, grid_w);
    s.ant_y = @mod(s.ant_y, grid_h);
    s.steps += 1;
}

fn reset(s: *State) void {
    s.cells = @splat(true);
    s.ant_x = grid_w / 2;
    s.ant_y = grid_h / 2;
    s.dir = .up;
    s.steps = 0;
    s.path_n = 0;
    s.path_head = 0;
    s.cam_x = grid_w / 2;
    s.cam_y = grid_h / 2;
    s.follow = true;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .scratch = std.heap.ArenaAllocator.init(gpa),
    };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

/// Floor a coordinate to an i32 cell index (the visible-window maths needs ints).
/// @trunc would round toward zero, which differs from floor for the negative
/// coordinates the camera can reach, so we floor first then convert.
fn floorToInt(v: f32) i32 {
    // lint:off int-from-float: floor semantics are intentional here, not @trunc
    return @intFromFloat(@floor(v));
}

/// The on-screen control bar: a row of buttons across the bottom. Returns the rect
/// for button `i` of `count`, sized to the window so it works at any size.
fn barButton(f: *z.Frame, i: usize, count: usize) Rect {
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    const pad: f32 = 8.0;
    const h: f32 = @max(40.0, sh * 0.09);
    const total_w: f32 = sw - pad * 2.0;
    const w: f32 = (total_w - pad * (float(count) - 1.0)) / float(count);
    return .{
        .x = pad + float(i) * (w + pad),
        .y = sh - h - pad,
        .w = w,
        .h = h,
    };
}

/// Draw one button and report whether it was tapped this frame.
fn button(
    f: *z.Frame,
    s: *State,
    r: Rect,
    label: []const u8,
    tap: ?Vec2,
) bool {
    const hot: bool = if (tap) |p| r.contains(p) else false;
    f.gl.rect(.{ .x = r.x, .y = r.y, .width = r.w, .height = r.h }, .{ .color = if (hot) btn_hot_col else btn_col });
    // Centre the label by eye: ~9 px per glyph at size 16.
    const approx_w: f32 = float(label.len) * 9.0;
    const tx: f32 = r.x + (r.w - approx_w) / 2.0;
    const ty: f32 = r.y + r.h / 2.0 - 8.0;
    f.gl.text(.{ tx, ty }, label, .{ .size = 16, .color = btn_txt_col, .font = &s.font });
    return hot;
}

/// -1, 0, or +1 as a float, for the sign of an integer delta.
fn signf(v: i32) f32 {
    if (v > 0) {
        return 1.0;
    }
    if (v < 0) {
        return -1.0;
    }
    return 0.0;
}

/// Unit step from cell `a` to cell `b` as a direction (-1,0,1 each axis).
fn dirBetween(ax: i32, ay: i32, bx: i32, by: i32) Vec2 {
    return .{ signf(bx - ax), signf(by - ay) };
}

/// Straight half-cell stroke from cell centre `cx,cy` outward (toward=true) or back
/// (toward=false) along direction `d`. Used for straight-through cells and for the
/// two half-cells that lead into and out of a rounded corner.
fn drawHalfStep(
    f: *z.Frame,
    s: *State,
    cx: i32,
    cy: i32,
    d: Vec2,
    toward: bool,
    col: Color,
) void {
    const cxf: f32 = float(cx) + 0.5;
    const cyf: f32 = float(cy) + 0.5;
    const sign: f32 = if (toward) 0.5 else -0.5;
    const a: Vec2 = worldToScreen(s, f, cxf, cyf);
    const b: Vec2 = worldToScreen(s, f, cxf + sign * d[0], cyf + sign * d[1]);
    f.gl.line(a, b, .{ .color = col, .thickness = 3.0 });
}

/// Draw a rounded corner as a quarter-arc through cell centre `cx,cy`, tangent to
/// the incoming (`ind`) and outgoing (`outd`) directions. Centred on the inside
/// corner `C + 0.5*(outd - ind)`, radius half a cell, swept the short way. Drawn as
/// our own short polyline (circleSectorLines would add radial cap spokes).
fn drawCornerArc(
    f: *z.Frame,
    s: *State,
    cx: i32,
    cy: i32,
    ind: Vec2,
    outd: Vec2,
    col: Color,
) void {
    const cxf: f32 = float(cx) + 0.5;
    const cyf: f32 = float(cy) + 0.5;
    const ox: f32 = cxf + 0.5 * (outd[0] - ind[0]);
    const oy: f32 = cyf + 0.5 * (outd[1] - ind[1]);
    const entry_ang: f32 = atan2Rad(cyf - 0.5 * ind[1] - oy, cxf - 0.5 * ind[0] - ox);
    const exit_ang: f32 = atan2Rad(cyf + 0.5 * outd[1] - oy, cxf + 0.5 * outd[0] - ox);
    var sweep: f32 = exit_ang - entry_ang;
    while (sweep > zm.pi) {
        sweep -= zm.tau;
    }
    while (sweep < -zm.pi) {
        sweep += zm.tau;
    }

    const segs: usize = 8;
    var prev_pt: Vec2 = worldToScreen(s, f, ox + 0.5 * @cos(entry_ang), oy + 0.5 * @sin(entry_ang));
    var i: usize = 1;
    while (i <= segs) : (i += 1) {
        const frac: f32 = float(@as(i32, @intCast(i))) / float(@as(i32, @intCast(segs)));
        const a: f32 = entry_ang + sweep * frac;
        const pt: Vec2 = worldToScreen(s, f, ox + 0.5 * @cos(a), oy + 0.5 * @sin(a));
        f.gl.line(prev_pt, pt, .{ .color = col, .thickness = 3.0 });
        prev_pt = pt;
    }
}

/// Cell coordinates -> screen pixels, through the camera.
fn worldToScreen(s: *const State, f: *z.Frame, cx: f32, cy: f32) Vec2 {
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    return .{
        sw / 2.0 + (cx - s.cam_x) * s.zoom,
        sh / 2.0 + (cy - s.cam_y) * s.zoom,
    };
}

/// Screen pixels -> cell coordinates: the exact inverse of worldToScreen. Pan and
/// zoom both work by holding a screen point's world position fixed, so they need
/// this. Getting it wrong (or out of sync with worldToScreen) is what makes pan
/// drift or run backwards.
fn screenToWorld(s: *const State, f: *z.Frame, p: Vec2) Vec2 {
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    return .{
        s.cam_x + (p[0] - sw / 2.0) / s.zoom,
        s.cam_y + (p[1] - sh / 2.0) / s.zoom,
    };
}

/// Apply a zoom factor while holding the world point under `focus` fixed on
/// screen. Same shape as mandel_sidebyside: read the world point before, scale,
/// read it after, shift the camera by the difference.
fn zoomAbout(s: *State, f: *z.Frame, factor: f32, focus: Vec2) void {
    const before: Vec2 = screenToWorld(s, f, focus);
    s.zoom = std.math.clamp(s.zoom * factor, 1.0, 40.0);
    const after: Vec2 = screenToWorld(s, f, focus);
    s.cam_x += before[0] - after[0];
    s.cam_y += before[1] - after[1];
}

fn handleInput(f: *z.Frame, s: *State) void {
    // Keyboard (desktop). Harmless on a phone, which has none -- the on-screen
    // buttons in update() cover the same actions.
    if (z.isKeyPressed(f.input, .space)) {
        s.paused = !s.paused;
    }
    if (z.isKeyPressed(f.input, .r)) {
        reset(s);
    }
    if (z.isKeyPressed(f.input, .f)) {
        s.follow = !s.follow;
    }
    if (s.paused and (z.isKeyPressed(f.input, .period) or z.isKeyPressed(f.input, .right))) {
        step(s);
    }
    const digits = [_]z.KeyboardKey{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine };
    const rate_ladder = [_]f32{ 1, 2, 5, 10, 30, 60, 240, 1000, 4000 };
    for (digits, 0..) |k, n| {
        if (z.isKeyPressed(f.input, k)) {
            s.steps_per_sec = rate_ladder[n];
        }
    }
    if (z.isKeyPressed(f.input, .equal)) {
        zoomAbout(s, f, 1.15, .{ f.window.widthf() / 2.0, f.window.heightf() / 2.0 });
    }
    if (z.isKeyPressed(f.input, .minus)) {
        zoomAbout(s, f, 1.0 / 1.15, .{ f.window.widthf() / 2.0, f.window.heightf() / 2.0 });
    }

    // Mouse wheel zoom about the cursor (desktop).
    const wheel: f32 = z.getMouseWheelMove(f.input);
    if (wheel != 0) {
        s.follow = false;
        zoomAbout(s, f, if (wheel > 0) 1.15 else 1.0 / 1.15, z.getMousePosition(f.input));
    }

    // ---- Touch camera, mirroring mandel_sidebyside ----------------------------
    z.updateGestures(&s.gestures, f.input, f.time);
    const mouse: Vec2 = z.getMousePosition(f.input);
    const touch_count: i32 = z.getTouchPointCount(f.input);

    // Two-finger pinch: scale about the midpoint, and pan by the midpoint's motion.
    if (touch_count >= 2) {
        s.dragging = false; // pinch wins over drag
        s.follow = false;
        const scale: f32 = z.getGesturePinchScale(&s.gestures);
        if (scale > 0 and scale != 1.0) {
            zoomAbout(s, f, scale, z.getGesturePinchMid(&s.gestures));
            // Pan by the midpoint's screen motion, converted to cell units.
            const md: Vec2 = z.getGesturePinchMidDelta(&s.gestures);
            s.cam_x -= md[0] / s.zoom;
            s.cam_y -= md[1] / s.zoom;
        }
        return;
    }

    // One-finger / mouse drag to pan: anchor the world point grabbed at press and
    // keep it under the cursor. Absolute, so it never drifts. Taps on the control
    // bar are not drags.
    const on_bar: bool = mouse[1] > f.window.heightf() - @max(40.0, f.window.heightf() * 0.09) - 16.0;
    const pressed: bool = z.isMouseButtonDown(f.input, .left) and !on_bar;
    if (pressed and !s.dragging) {
        s.dragging = true;
        s.follow = false;
        s.drag_anchor = screenToWorld(s, f, mouse);
    }
    if (!pressed) {
        s.dragging = false;
    }
    if (s.dragging and pressed) {
        // center = anchor - offset/zoom, on both axes (symmetric, so neither pans
        // backwards). This holds drag_anchor exactly under the cursor.
        const sw: f32 = f.window.widthf();
        const sh: f32 = f.window.heightf();
        s.cam_x = s.drag_anchor[0] - (mouse[0] - sw / 2.0) / s.zoom;
        s.cam_y = s.drag_anchor[1] - (mouse[1] - sh / 2.0) / s.zoom;
    }
}

fn update(f: *z.Frame, s: *State) void {
    _ = s.scratch.reset(.retain_capacity);
    const arena: Allocator = s.scratch.allocator();

    handleInput(f, s);

    // Advance the simulation by real elapsed time, so the rate means the same
    // thing regardless of frame rate. At 1 step/s this fires once a second; at a
    // high rate it runs many steps per frame. Capped so a big rate or a long gap
    // (e.g. tab was backgrounded) can't stall the frame.
    const dt: f64 = f.time.delta_time;
    if (!s.paused) {
        s.step_accum += dt * @as(f64, s.steps_per_sec);
        var budget: u32 = 0;
        while (s.step_accum >= 1.0 and budget < 4096) : (budget += 1) {
            step(s);
            s.step_accum -= 1.0;
        }
    } else {
        s.step_accum = 0;
    }

    if (s.follow) {
        // Ease the camera toward the ant.
        s.cam_x += (float(s.ant_x) - s.cam_x) * 0.1;
        s.cam_y += (float(s.ant_y) - s.cam_y) * 0.1;
    }

    z.beginDrawing(f.gl);
    f.gl.rect(.{ .x = 0, .y = 0, .width = f.window.widthf(), .height = f.window.heightf() }, .{ .color = bg_col });

    // Only the black cells need drawing (white is the background board colour). We
    // walk the visible window of the grid, not all 40k cells.
    const sw: f32 = f.window.widthf();
    const sh: f32 = f.window.heightf();
    const half_cols: f32 = (sw / 2.0) / s.zoom + 1.0;
    const half_rows: f32 = (sh / 2.0) / s.zoom + 1.0;
    const x0: i32 = @max(0, floorToInt(s.cam_x - half_cols));
    const x1: i32 = @min(grid_w, floorToInt(s.cam_x + half_cols) + 1);
    const y0: i32 = @max(0, floorToInt(s.cam_y - half_rows));
    const y1: i32 = @min(grid_h, floorToInt(s.cam_y + half_rows) + 1);

    var yy: i32 = y0;
    while (yy < y1) : (yy += 1) {
        var xx: i32 = x0;
        while (xx < x1) : (xx += 1) {
            if (s.cell(xx, yy)) {
                continue; // white == background
            }
            const p: Vec2 = worldToScreen(s, f, @floatFromInt(xx), @floatFromInt(yy));
            f.gl.rect(
                .{ .x = p[0], .y = p[1], .width = s.zoom + 1.0, .height = s.zoom + 1.0 },
                .{ .color = white_col },
            );
        }
    }

    // Faint cell grid, only when zoomed in enough to be useful.
    if (s.zoom >= 8.0) {
        var gx: i32 = x0;
        while (gx <= x1) : (gx += 1) {
            const a: Vec2 = worldToScreen(s, f, @floatFromInt(gx), @floatFromInt(y0));
            const b: Vec2 = worldToScreen(s, f, @floatFromInt(gx), @floatFromInt(y1));
            f.gl.line(a, b, .{ .color = grid_col, .thickness = 1.0 });
        }
        var gy: i32 = y0;
        while (gy <= y1) : (gy += 1) {
            const a: Vec2 = worldToScreen(s, f, @floatFromInt(x0), @floatFromInt(gy));
            const b: Vec2 = worldToScreen(s, f, @floatFromInt(x1), @floatFromInt(gy));
            f.gl.line(a, b, .{ .color = grid_col, .thickness = 1.0 });
        }
    }

    // The trail follows the ant's last footsteps. At each cell the ant turned, the
    // corner is drawn as a quarter-circle ARC rounding it (rather than a sharp
    // elbow); straight-through cells stay straight. Each piece is coloured by the
    // turn taken leaving that cell: red = right (was white), blue = left (was
    // black). Consecutive footsteps are adjacent; at a wrap the ant teleports
    // edge-to-edge, so we skip any non-adjacent pair.
    if (s.path_n >= 2) {
        const start: usize = (s.path_head + path_len - s.path_n) % path_len;
        // Walk interior cells with a prev and next neighbour so we know in/out dir.
        var k: usize = 0;
        while (k < s.path_n) : (k += 1) {
            const cur: Turn = s.path[(start + k) % path_len];
            const col: Color = if (cur.right) turn_r_col else turn_l_col;

            // Previous cell (or none at the tail); next cell is the following
            // footstep, or the ant's live position for the last one.
            const has_prev: bool = k > 0;
            const prev: Turn = if (has_prev) s.path[(start + k - 1) % path_len] else cur;
            const next: Turn = if (k + 1 < s.path_n)
                s.path[(start + k + 1) % path_len]
            else
                .{ .x = s.ant_x, .y = s.ant_y, .right = cur.right };

            const prev_adj: bool = has_prev and (@abs(cur.x - prev.x) + @abs(cur.y - prev.y) <= 1);
            const next_adj: bool = @abs(next.x - cur.x) + @abs(next.y - cur.y) <= 1;

            if (prev_adj and next_adj) {
                const ind: Vec2 = dirBetween(prev.x, prev.y, cur.x, cur.y);
                const outd: Vec2 = dirBetween(cur.x, cur.y, next.x, next.y);
                if (ind[0] == outd[0] and ind[1] == outd[1]) {
                    // Straight through: one full segment across the cell.
                    drawHalfStep(f, s, cur.x, cur.y, ind, false, col);
                    drawHalfStep(f, s, cur.x, cur.y, outd, true, col);
                } else {
                    // Turned here: round the corner with an arc.
                    drawCornerArc(f, s, cur.x, cur.y, ind, outd, col);
                }
            } else if (next_adj) {
                // Tail cell with no known incoming dir: just the outgoing half.
                const outd: Vec2 = dirBetween(cur.x, cur.y, next.x, next.y);
                drawHalfStep(f, s, cur.x, cur.y, outd, true, col);
            } else if (prev_adj) {
                const ind: Vec2 = dirBetween(prev.x, prev.y, cur.x, cur.y);
                drawHalfStep(f, s, cur.x, cur.y, ind, false, col);
            }
        }
    }

    // The ant.
    const ap: Vec2 = worldToScreen(s, f, float(s.ant_x) + 0.5, float(s.ant_y) + 0.5);
    f.gl.circle(ap, @max(3.0, s.zoom * 0.45), .{ .color = ant_col, .segments = 24 });

    // On-screen control bar (works with no keyboard). A tap is read once here; if
    // it hits a button we act on it. Buttons sit on top of everything else.
    const tap: ?Vec2 = if (z.isMouseButtonPressed(f.input, .left)) z.getMousePosition(f.input) else null;
    const n_btns: usize = 6;
    if (button(f, s, barButton(f, 0, n_btns), if (s.paused) "play" else "pause", tap)) {
        s.paused = !s.paused;
    }
    if (button(f, s, barButton(f, 1, n_btns), "step", tap)) {
        step(s);
        s.paused = true;
    }
    if (button(f, s, barButton(f, 2, n_btns), "slower", tap)) {
        s.steps_per_sec = @max(1.0, s.steps_per_sec / 2.0);
    }
    if (button(f, s, barButton(f, 3, n_btns), "faster", tap)) {
        s.steps_per_sec = @min(4096.0, s.steps_per_sec * 2.0);
    }
    if (button(f, s, barButton(f, 4, n_btns), if (s.follow) "unfollow" else "follow", tap)) {
        s.follow = !s.follow;
    }
    if (button(f, s, barButton(f, 5, n_btns), "reset", tap)) {
        reset(s);
    }

    const caption: []const u8 = allocPrint(arena, "langton's ant - {d} steps - {d:.0}/s{s}{s}", .{
        s.steps,
        s.steps_per_sec,
        if (s.paused) " - paused" else "",
        if (s.follow) " - following" else "",
    }) catch "langton's ant";
    common.caption(f.gl, s.font, caption);
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - langton's ant",
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
