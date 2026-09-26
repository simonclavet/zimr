// examples/life.zig - Conway's Game of Life on an 80×45 grid.
// A small but substantial demo that exercises shapes + input + text +
// frame timing in one place.  The generation step is throttled to
// ~10 Hz so cells are visible; rendering runs at full 60 Hz so the
// mouse-paint feels responsive between generations.
// Controls:
//   left click / drag  toggle cells (paint mode)
//   space              pause / resume the simulation
//   c                  clear the grid
//   r                  randomize (~25% alive density)
//   1-9                speed control (1 = slow, 9 = fast)

const std = @import("std");
const allocPrint = std.fmt.allocPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const float = zm.float;
const pow = zm.pow;

const grid_w = 80;
const grid_h = 45;
const cell_px = 10; // 10×10 pixels per cell → 800×450 canvas

const State = struct {
    /// Owned shapes-texture state. id=1 → rlgl's internal 1x1 white pixel.
    /// Owned default-font cache. Populated by `loadFontFromTtfBytes` below.
    font: z.Font,
    ui_host: z.UiHost,
    ui_capturing: bool = false,
    /// Per-frame scratch arena, reset at top of update by user code.
    scratch: std.heap.ArenaAllocator,
    cur: [grid_w * grid_h]u8 = @splat(0),
    next: [grid_w * grid_h]u8 = @splat(0),
    generation: usize = 0,
    paused: bool = true,
    /// Throttle the simulation step.  step_interval seconds between
    /// generations; user-tunable via the 1-9 keys.
    step_interval: f32 = 0.10,
    last_step_time: f64 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.scratch.deinit();
    s.ui_host.deinit();
}

fn idx(x: usize, y: usize) usize {
    return y * grid_w + x;
}

/// Place the classic 3-cell glider.
fn seedGlider(
    grid: *[grid_w * grid_h]u8,
    x: usize,
    y: usize,
) void {
    grid[idx(x + 1, y)] = 1;
    grid[idx(x + 2, y + 1)] = 1;
    grid[idx(x, y + 2)] = 1;
    grid[idx(x + 1, y + 2)] = 1;
    grid[idx(x + 2, y + 2)] = 1;
}

/// Seed with a glider in the top-left so first frame shows movement.
fn initState(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 32);
    s.* = .{ .scratch = std.heap.ArenaAllocator.init(gpa), .font = font, .ui_host = z.UiHost.init(gpa, font) };
    seedGlider(&s.cur, 5, 5);
}

/// Advance the grid by one Conway generation.
fn step(s: *State) void {
    var y: usize = 0;
    while (y < grid_h) : (y += 1) {
        var x: usize = 0;
        while (x < grid_w) : (x += 1) {
            // Count live neighbours.  Treat off-grid as dead.
            var n: u32 = 0;
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    if (dx == 0 and dy == 0) {
                        continue;
                    }
                    const nx = @as(i32, @intCast(x)) + dx;
                    const ny = @as(i32, @intCast(y)) + dy;
                    if (nx < 0 or nx >= grid_w or ny < 0 or ny >= grid_h) {
                        continue;
                    }
                    if (s.cur[idx(@intCast(nx), @intCast(ny))] != 0) {
                        n += 1;
                    }
                }
            }
            const alive: bool = s.cur[idx(x, y)] != 0;
            const survives: bool = (alive and (n == 2 or n == 3)) or (!alive and n == 3);
            s.next[idx(x, y)] = if (survives) 1 else 0;
        }
    }
    s.cur = s.next;
    s.generation += 1;
}

fn update(f: *z.Frame, state: *State) void {
    _ = state.scratch.reset(.retain_capacity);
    // ---- Input handling ---------------------------------------------------
    if (z.isKeyPressed(f.input, .space)) {
        state.paused = !state.paused;
    }
    if (z.isKeyPressed(f.input, .c)) {
        state.cur = @splat(0);
        state.generation = 0;
    }
    if (z.isKeyPressed(f.input, .r)) {
        var i: usize = 0;
        while (i < state.cur.len) : (i += 1) {
            state.cur[i] = if (f.random.uintLessThan(u32, 4) == 0) 1 else 0;
        }
        state.generation = 0;
    }
    // 1-9 = speed control (1 = slow @ 1Hz, 9 = fast @ 60Hz capped).
    const digit_keys = [_]z.KeyboardKey{
        .one, .two,   .three, .four, .five,
        .six, .seven, .eight, .nine,
    };
    for (digit_keys, 1..) |k, slot_idx| {
        if (z.isKeyPressed(f.input, k)) {
            const slot: f32 = float(slot_idx);
            // Slot 1 → 1.0s, Slot 9 → 0.016s (60 Hz).  Geometric.
            state.step_interval = pow(0.5, slot - 1) * 0.5;
        }
    }
    // Mouse paint: hold left button to toggle cells under the cursor.
    // Skip when the UI had the mouse last frame (dragging the panel must not
    // paint through it). One-frame lag on the hit-test is imperceptible.
    if (!state.ui_capturing and z.isMouseButtonDown(f.input, .left)) {
        const mx: i32 = @divFloor(z.getMouseX(f.input), cell_px);
        const my: i32 = @divFloor(z.getMouseY(f.input), cell_px);
        if (mx >= 0 and mx < grid_w and my >= 0 and my < grid_h) {
            state.cur[idx(@intCast(mx), @intCast(my))] = 1;
        }
    }

    // ---- Simulation step ---------------------------------------------------
    if (!state.paused) {
        const t: f32 = @floatCast(f.time.time);
        if (t - state.last_step_time >= state.step_interval) {
            step(state);
            state.last_step_time = t;
        }
    }

    // ---- Render ------------------------------------------------------------
    z.clearViewport(f, z.colors.slate_900);

    // Live cells as filled rectangles.  Background grid omitted - at
    // 10px cells a flat dark background reads cleaner than gridlines.
    var alive_count: u32 = 0;
    var y: usize = 0;
    while (y < grid_h) : (y += 1) {
        var x: usize = 0;
        while (x < grid_w) : (x += 1) {
            if (state.cur[idx(x, y)] != 0) {
                f.gl.rect(.{
                    .x = float(x * cell_px),
                    .y = float(y * cell_px),
                    .width = float(cell_px - 1),
                    .height = // 1-pixel gutter for readability
                    float(cell_px - 1),
                }, .{ .color = z.colors.amber_400 });
                alive_count += 1;
            }
        }
    }

    // ---- HUD ---------------------------------------------------------------
    const hud_color: Color = if (state.paused) z.colors.sky_300 else z.colors.white;
    const hud: []u8 = allocPrint(state.scratch.allocator(), "gen {d}   alive {d}   step {d:.3}s   {s}", .{
        state.generation,
        alive_count,
        state.step_interval,
        if (state.paused) "[PAUSED]" else "[running]",
    }) catch return;
    f.gl.text(.{ 8, 8 }, hud, .{ .size = 18, .color = hud_color, .font = &state.font });

    const help: []const u8 = "tap a cell to paint  -  buttons below";
    f.gl.text(.{ 8, grid_h * cell_px - 24 }, help, .{ .size = 14, .color = z.colors.slate_400, .font = &state.font });

    // ---- Touch-friendly control panel (the keyboard shortcuts still work on
    // desktop; these give phones a way to pause/clear/seed/speed). ----
    const ui: z.ui_real.Ui = state.ui_host.begin(f);
    if (ui.window("Life", .{ .initial_pos = .{ 14, 40 }, .initial_size = .{ 200, 210 } })) |w| {
        defer w.close();
        if (ui.button(if (state.paused) "resume" else "pause", .{})) {
            state.paused = !state.paused;
        }
        if (ui.button("clear", .{})) {
            state.cur = @splat(0);
            state.generation = 0;
        }
        if (ui.button("random", .{})) {
            var i: usize = 0;
            while (i < state.cur.len) : (i += 1) {
                state.cur[i] = if (f.random.uintLessThan(u32, 4) == 0) 1 else 0;
            }
            state.generation = 0;
        }
        // Speed slider: maps step interval 1.0s (slow) .. 0.016s (fast).
        var hz: f32 = 1.0 / state.step_interval;
        if (ui.slider("speed (hz)", &hz, .{ .min = 1, .max = 60 })) {
            state.step_interval = 1.0 / hz;
        }
    }
    state.ui_capturing = ui.wantCaptureMouse();
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
            .title = "zimr - Conway's Game of Life",
            .width = grid_w * cell_px,
            .height = grid_h * cell_px,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
