//! snake — the classic. Steer the snake around a grid, eat the dots to grow, and
//! don't run into a wall or your own tail. Every dot eaten adds a segment and a
//! little speed, so the game tightens as your score climbs.
//!
//! Built to play equally well two ways: arrow keys or WASD on a keyboard, and
//! SWIPES on a phone (swipe the way you want to turn). A pause and a restart
//! button sit on screen so no keyboard is ever needed. The board is recomputed
//! from the window every frame, so it fills a tall phone and a wide monitor alike.
//!
//! Controls:
//!   arrows / WASD    turn
//!   swipe            turn (phone)
//!   space            pause / resume  (also restarts after a game over)
const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const float = zm.float;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const grid_w = 20;
const grid_h = 20;
const max_len = grid_w * grid_h;
const base_tps = 6.0; // ticks per second at the start
const tps_per_food = 0.35; // speed added per dot eaten

const bg_col: Color = .{ .r = 16, .g = 19, .b = 27, .a = 255 };
const board_col: Color = .{ .r = 24, .g = 29, .b = 40, .a = 255 };
const grid_col: Color = .{ .r = 34, .g = 40, .b = 54, .a = 255 };
const snake_col: Color = .{ .r = 96, .g = 206, .b = 120, .a = 255 };
const head_col: Color = .{ .r = 150, .g = 240, .b = 168, .a = 255 };
const food_col: Color = .{ .r = 236, .g = 92, .b = 84, .a = 255 };
const over_col: Color = .{ .r = 250, .g = 204, .b = 60, .a = 255 };
const btn_col: Color = .{ .r = 34, .g = 40, .b = 54, .a = 235 };
const btn_hot_col: Color = .{ .r = 54, .g = 64, .b = 86, .a = 245 };
const btn_txt_col: Color = .{ .r = 210, .g = 216, .b = 228, .a = 255 };

/// A heading. Turning can't reverse straight back on itself, which `opposite`
/// makes easy to check.
const Dir = enum {
    up,
    down,
    left,
    right,

    fn delta(self: Dir) [2]i32 {
        return switch (self) {
            .up => .{ 0, -1 },
            .down => .{ 0, 1 },
            .left => .{ -1, 0 },
            .right => .{ 1, 0 },
        };
    }

    fn opposite(self: Dir, other: Dir) bool {
        return switch (self) {
            .up => other == .down,
            .down => other == .up,
            .left => other == .right,
            .right => other == .left,
        };
    }
};

/// A cell on the board.
const Cell = struct {
    x: i32,
    y: i32,

    fn eql(self: Cell, o: Cell) bool {
        return self.x == o.x and self.y == o.y;
    }
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

/// Board geometry for the current window: a square grid centred in the space
/// above the control bar, sized off the shorter side. Recomputed every frame.
const Layout = struct {
    x: f32,
    y: f32,
    cell: f32,

    fn of(f: *z.Frame) Layout {
        const w: f32 = f.window.widthf();
        const bar: f32 = barHeight(f);
        const h: f32 = f.window.heightf() - bar;
        const side: f32 = @min(w, h) * 0.92;
        return .{
            .x = (w - side) / 2.0,
            .y = (h - side) / 2.0,
            .cell = side / float(grid_w),
        };
    }

    fn cellRect(self: Layout, cx: i32, cy: i32) z.Rectangle {
        return .{
            .x = self.x + float(cx) * self.cell,
            .y = self.y + float(cy) * self.cell,
            .width = self.cell,
            .height = self.cell,
        };
    }
};

const State = struct {
    font: z.Font,
    scratch: std.heap.ArenaAllocator,
    gestures: z.GesturesState = .{},
    rng: std.Random.DefaultPrng,

    /// The snake body, head first. `len` cells are live.
    body: [max_len]Cell = undefined,
    len: usize = 3,
    dir: Dir = .right,
    /// The turn to apply on the next tick. Buffering it means a fast double-tap
    /// can't reverse the snake into itself within one tick.
    next_dir: Dir = .right,
    food: Cell = .{ .x = 10, .y = 10 },
    score: u32 = 0,
    best: u32 = 0,

    paused: bool = false,
    dead: bool = false,
    step_accum: f64 = 0,

    fn head(self: *const State) Cell {
        return self.body[0];
    }

    fn tps(self: *const State) f64 {
        return base_tps + tps_per_food * float(self.score);
    }
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .scratch = std.heap.ArenaAllocator.init(gpa),
        .rng = std.Random.DefaultPrng.init(0x5EED_1234),
    };
    restart(s);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
}

fn restart(s: *State) void {
    const cx: i32 = grid_w / 2;
    const cy: i32 = grid_h / 2;
    s.len = 3;
    s.body[0] = .{ .x = cx, .y = cy };
    s.body[1] = .{ .x = cx - 1, .y = cy };
    s.body[2] = .{ .x = cx - 2, .y = cy };
    s.dir = .right;
    s.next_dir = .right;
    s.score = 0;
    s.paused = false;
    s.dead = false;
    s.step_accum = 0;
    placeFood(s);
}

/// Drop food on a random cell that isn't currently under the snake.
fn placeFood(s: *State) void {
    const rand: std.Random = s.rng.random();
    while (true) {
        const c: Cell = .{
            .x = rand.intRangeLessThan(i32, 0, grid_w),
            .y = rand.intRangeLessThan(i32, 0, grid_h),
        };
        var on_snake: bool = false;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s.body[i].eql(c)) {
                on_snake = true;
                break;
            }
        }
        if (!on_snake) {
            s.food = c;
            return;
        }
    }
}

/// One tick: turn, move the head, eat or shuffle the tail, check for death.
fn tick(s: *State) void {
    // Apply the buffered turn unless it would reverse straight back.
    if (!s.dir.opposite(s.next_dir)) {
        s.dir = s.next_dir;
    }
    const d: [2]i32 = s.dir.delta();
    const nx: i32 = s.head().x + d[0];
    const ny: i32 = s.head().y + d[1];

    // Wall collision.
    if (nx < 0 or nx >= grid_w or ny < 0 or ny >= grid_h) {
        die(s);
        return;
    }
    const new_head: Cell = .{ .x = nx, .y = ny };

    // Self collision: check against every segment except the tail tip, which will
    // move out of the way this tick (unless we're growing).
    const growing: bool = new_head.eql(s.food);
    const check_to: usize = if (growing) s.len else s.len - 1;
    var i: usize = 0;
    while (i < check_to) : (i += 1) {
        if (s.body[i].eql(new_head)) {
            die(s);
            return;
        }
    }

    // Shift the body down by one and place the new head.
    var j: usize = s.len;
    while (j > 0) : (j -= 1) {
        if (j < max_len) {
            s.body[j] = s.body[j - 1];
        }
    }
    s.body[0] = new_head;

    if (growing) {
        if (s.len < max_len) {
            s.len += 1;
        }
        s.score += 1;
        if (s.score > s.best) {
            s.best = s.score;
        }
        placeFood(s);
    }
}

fn die(s: *State) void {
    s.dead = true;
}

fn turn(s: *State, d: Dir) void {
    // Buffer the turn; tick() applies it and rejects a straight reversal.
    if (!s.dir.opposite(d)) {
        s.next_dir = d;
    }
}

fn barHeight(f: *z.Frame) f32 {
    return @max(44.0, f.window.heightf() * 0.10);
}

fn barButton(f: *z.Frame, i: usize, count: usize) Rect {
    const sw: f32 = f.window.widthf();
    const pad: f32 = 8.0;
    const h: f32 = barHeight(f) - pad;
    const total_w: f32 = sw - pad * 2.0;
    const w: f32 = (total_w - pad * (float(@as(i32, @intCast(count))) - 1.0)) / float(@as(i32, @intCast(count)));
    return .{
        .x = pad + float(@as(i32, @intCast(i))) * (w + pad),
        .y = f.window.heightf() - h - pad / 2.0,
        .w = w,
        .h = h,
    };
}

fn button(
    f: *z.Frame,
    s: *State,
    r: Rect,
    label: []const u8,
    tap: ?Vec2,
) bool {
    const hot: bool = if (tap) |p| r.contains(p) else false;
    f.gl.rect(.{ .x = r.x, .y = r.y, .width = r.w, .height = r.h }, .{ .color = if (hot) btn_hot_col else btn_col });
    const approx_w: f32 = float(@as(i32, @intCast(label.len))) * 10.0;
    const tx: f32 = r.x + (r.w - approx_w) / 2.0;
    const ty: f32 = r.y + r.h / 2.0 - 9.0;
    f.gl.text(.{ tx, ty }, label, .{ .size = 18, .color = btn_txt_col, .font = &s.font });
    return hot;
}

fn handleInput(f: *z.Frame, s: *State) void {
    // Keyboard: arrows and WASD.
    if (z.isKeyPressed(f.input, .up) or z.isKeyPressed(f.input, .w)) {
        turn(s, .up);
    }
    if (z.isKeyPressed(f.input, .down) or z.isKeyPressed(f.input, .s)) {
        turn(s, .down);
    }
    if (z.isKeyPressed(f.input, .left) or z.isKeyPressed(f.input, .a)) {
        turn(s, .left);
    }
    if (z.isKeyPressed(f.input, .right) or z.isKeyPressed(f.input, .d)) {
        turn(s, .right);
    }
    if (z.isKeyPressed(f.input, .space)) {
        if (s.dead) {
            restart(s);
        } else {
            s.paused = !s.paused;
        }
    }

    // Phone: swipe to turn.
    z.updateGestures(&s.gestures, f.input, f.time);
    switch (z.getGestureDetected(&s.gestures)) {
        .swipe_up => turn(s, .up),
        .swipe_down => turn(s, .down),
        .swipe_left => turn(s, .left),
        .swipe_right => turn(s, .right),
        else => {},
    }
}

fn update(f: *z.Frame, s: *State) void {
    _ = s.scratch.reset(.retain_capacity);
    const arena: Allocator = s.scratch.allocator();

    handleInput(f, s);

    // Advance by real time, so speed is frame-rate independent.
    if (!s.paused and !s.dead) {
        s.step_accum += f.time.delta_time * s.tps();
        var budget: u32 = 0;
        while (s.step_accum >= 1.0 and budget < 16) : (budget += 1) {
            tick(s);
            s.step_accum -= 1.0;
            if (s.dead) {
                break;
            }
        }
    } else {
        s.step_accum = 0;
    }

    const lay: Layout = Layout.of(f);

    z.beginDrawing(f.gl);
    f.gl.rect(.{ .x = 0, .y = 0, .width = f.window.widthf(), .height = f.window.heightf() }, .{ .color = bg_col });

    // Board backdrop.
    f.gl.rect(.{
        .x = lay.x,
        .y = lay.y,
        .width = lay.cell * float(grid_w),
        .height = lay.cell * float(grid_h),
    }, .{ .color = board_col });

    // Grid lines.
    var g: i32 = 0;
    while (g <= grid_w) : (g += 1) {
        const gx: f32 = lay.x + float(g) * lay.cell;
        f.gl.line(.{ gx, lay.y }, .{ gx, lay.y + lay.cell * float(grid_h) }, .{ .color = grid_col, .thickness = 1.0 });
    }
    var gy: i32 = 0;
    while (gy <= grid_h) : (gy += 1) {
        const yy: f32 = lay.y + float(gy) * lay.cell;
        f.gl.line(.{ lay.x, yy }, .{ lay.x + lay.cell * float(grid_w), yy }, .{ .color = grid_col, .thickness = 1.0 });
    }

    // Food, as a circle.
    const fc: f32 = lay.cell * 0.5;
    f.gl.circle(
        .{ lay.x + (float(s.food.x) + 0.5) * lay.cell, lay.y + (float(s.food.y) + 0.5) * lay.cell },
        fc * 0.7,
        .{ .color = food_col, .segments = 20 },
    );

    // Snake body, head highlighted. Slight inset so segments read as separate.
    const inset: f32 = @max(1.0, lay.cell * 0.08);
    var k: usize = s.len;
    while (k > 0) : (k -= 1) {
        const c: Cell = s.body[k - 1];
        const r: z.Rectangle = lay.cellRect(c.x, c.y);
        f.gl.rect(.{
            .x = r.x + inset,
            .y = r.y + inset,
            .width = r.width - inset * 2.0,
            .height = r.height - inset * 2.0,
        }, .{ .color = if (k == 1) head_col else snake_col });
    }

    // Status line.
    const status: []const u8 = if (s.dead)
        allocPrint(arena, "game over - score {d} - space or restart", .{s.score}) catch "game over"
    else if (s.paused)
        allocPrint(arena, "paused - score {d}", .{s.score}) catch "paused"
    else
        allocPrint(arena, "snake - score {d} - best {d}", .{ s.score, s.best }) catch "snake";
    common.caption(f.gl, s.font, status);

    // A big centred hint on game over.
    if (s.dead) {
        const cx: f32 = f.window.widthf() / 2.0 - 90.0;
        const cy: f32 = lay.y + lay.cell * float(grid_h) / 2.0 - 16.0;
        f.gl.text(.{ cx, cy }, "GAME OVER", .{ .size = 32, .color = over_col, .font = &s.font });
    }

    // On-screen control bar: pause/play and restart. Tap read once.
    const tap: ?Vec2 = if (z.isMouseButtonPressed(f.input, .left)) z.getMousePosition(f.input) else null;
    if (button(f, s, barButton(f, 0, 2), if (s.dead) "play again" else if (s.paused) "resume" else "pause", tap)) {
        if (s.dead) {
            restart(s);
        } else {
            s.paused = !s.paused;
        }
    }
    if (button(f, s, barButton(f, 1, 2), "restart", tap)) {
        restart(s);
    }

    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - snake",
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
