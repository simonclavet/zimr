//! tic_tac_toe — two players share the screen and tap a cell to claim it. X is drawn
//! as two crossing bars, O as a ring (a filled disc with a background-coloured disc
//! punched out of it), the board as four bars. Nothing here but 2D shapes: no
//! textures, no font work beyond the caption, no AI. Tap anywhere once somebody has
//! won (or the board fills) to start a new game.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const common = @import("example_common");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// What one square holds. An enum makes the three states the only three states --
/// you cannot store a 4 by accident -- and each carries its own draw colour.
const Cell = enum {
    empty,
    x,
    o,

    fn color(self: Cell) Color {
        return switch (self) {
            .empty => bg_col,
            .x => x_col,
            .o => o_col,
        };
    }

    /// The other player. `.empty` has no opponent, so this is only called on x/o.
    fn other(self: Cell) Cell {
        return switch (self) {
            .x => .o,
            .o => .x,
            .empty => .empty,
        };
    }
};

/// Board geometry for the CURRENT window: a square centred in whatever space we
/// get, sized off the shorter side so it fits portrait phones and wide desktops
/// alike. Recomputed every frame -- nothing about the layout is baked in.
const Layout = struct {
    x: f32,
    y: f32,
    cell: f32,

    fn of(f: *z.Frame) Layout {
        const w: f32 = f.window.widthf();
        const h: f32 = f.window.heightf();
        const side: f32 = @min(w, h) * 0.78;
        return .{
            .x = (w - side) / 2.0,
            .y = (h - side) / 2.0,
            .cell = side / 3.0,
        };
    }
};

const bg_col: Color = .{ .r = 20, .g = 24, .b = 34, .a = 255 };
const grid_col: Color = .{ .r = 90, .g = 100, .b = 120, .a = 255 };
const x_col: Color = .{ .r = 236, .g = 72, .b = 60, .a = 255 };
const o_col: Color = .{ .r = 90, .g = 190, .b = 235, .a = 255 };
const win_col: Color = .{ .r = 250, .g = 204, .b = 60, .a = 255 };

/// The eight ways to make three in a row, as board indices.
const win_lines = [8][3]usize{
    .{ 0, 1, 2 }, .{ 3, 4, 5 }, .{ 6, 7, 8 }, // rows
    .{ 0, 3, 6 }, .{ 1, 4, 7 }, .{ 2, 5, 8 }, // columns
    .{ 0, 4, 8 }, .{ 2, 4, 6 }, // diagonals
};

const State = struct {
    font: z.Font,
    board: [9]Cell = @splat(.empty),
    turn: Cell = .x,
    /// The winning triple's index into win_lines, set once someone wins.
    win_line: ?usize = null,
    full: bool = false,

    fn winner(self: State) ?Cell {
        if (self.win_line) |li| {
            return self.board[win_lines[li][0]];
        }
        return null;
    }

    /// The one line of text shown along the bottom, for whatever the game is doing.
    fn status(self: State) []const u8 {
        if (self.winner()) |w| {
            return switch (w) {
                .x => "X wins - tap to play again",
                .o => "O wins - tap to play again",
                .empty => unreachable,
            };
        }
        if (self.full) {
            return "draw - tap to play again";
        }
        return switch (self.turn) {
            .x => "tic tac toe - X to play",
            .o => "tic tac toe - O to play",
            .empty => unreachable,
        };
    }
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{ .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 24) };
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
}

fn reset(s: *State) void {
    s.board = @splat(.empty);
    s.turn = .x;
    s.win_line = null;
    s.full = false;
}

/// Which cell the point falls in, or null when it is outside the board.
fn cellAt(lay: Layout, p: Vec2) ?usize {
    const side: f32 = lay.cell * 3.0;
    if (p[0] < lay.x or p[0] >= lay.x + side) {
        return null;
    }
    if (p[1] < lay.y or p[1] >= lay.y + side) {
        return null;
    }
    // Plain comparisons rather than a float->int cast: only three bands each way.
    const fx: f32 = (p[0] - lay.x) / lay.cell;
    const fy: f32 = (p[1] - lay.y) / lay.cell;
    const col: usize = if (fx < 1.0) 0 else if (fx < 2.0) 1 else 2;
    const row: usize = if (fy < 1.0) 0 else if (fy < 2.0) 1 else 2;
    return row * 3 + col;
}

/// Marks the winning line, or the full board, if either just happened.
fn scoreBoard(s: *State) void {
    for (win_lines, 0..) |line, i| {
        const a: Cell = s.board[line[0]];
        if (a == .empty) {
            continue;
        }
        if (a == s.board[line[1]] and a == s.board[line[2]]) {
            s.win_line = i;
            return;
        }
    }
    for (s.board) |cell| {
        if (cell == .empty) {
            return;
        }
    }
    s.full = true;
}

fn cellCenter(lay: Layout, i: usize) Vec2 {
    const col: f32 = @floatFromInt(i % 3);
    const row: f32 = @floatFromInt(i / 3);
    return .{
        lay.x + (col + 0.5) * lay.cell,
        lay.y + (row + 0.5) * lay.cell,
    };
}

/// A bar between two points, drawn as a rotated rectangle via the line helper.
fn drawX(
    gl: *z.WgpuGl,
    c: Vec2,
    r: f32,
    t: f32,
) void {
    gl.line(.{ c[0] - r, c[1] - r }, .{ c[0] + r, c[1] + r }, .{ .color = x_col, .thickness = t });
    gl.line(.{ c[0] - r, c[1] + r }, .{ c[0] + r, c[1] - r }, .{ .color = x_col, .thickness = t });
}

/// A ring: a filled disc with a background-coloured disc punched out of it.
fn drawO(
    gl: *z.WgpuGl,
    c: Vec2,
    r: f32,
    t: f32,
) void {
    gl.circle(c, r, .{ .color = o_col, .segments = 48 });
    gl.circle(c, r - t, .{ .color = bg_col, .segments = 48 });
}

fn update(f: *z.Frame, s: *State) void {
    const lay: Layout = Layout.of(f);
    const thick: f32 = @max(3.0, lay.cell * 0.09);
    const over: bool = s.winner() != null or s.full;
    if (z.isMouseButtonPressed(f.input, .left)) {
        const mp: Vec2 = z.getMousePosition(f.input);
        if (over) {
            reset(s);
        } else if (cellAt(lay, mp)) |i| {
            if (s.board[i] == .empty) {
                s.board[i] = s.turn;
                s.turn = s.turn.other();
                scoreBoard(s);
            }
        }
    }

    z.beginDrawing(f.gl);
    f.gl.rect(
        .{ .x = 0, .y = 0, .width = f.window.widthf(), .height = f.window.heightf() },
        .{ .color = bg_col },
    );

    // Board: two vertical bars and two horizontal bars.
    var k: usize = 1;
    while (k < 3) : (k += 1) {
        const off: f32 = float(k) * lay.cell;
        const side: f32 = lay.cell * 3.0;
        f.gl.line(
            .{ lay.x + off, lay.y },
            .{ lay.x + off, lay.y + side },
            .{ .color = grid_col, .thickness = thick * 0.5 },
        );
        f.gl.line(
            .{ lay.x, lay.y + off },
            .{ lay.x + side, lay.y + off },
            .{ .color = grid_col, .thickness = thick * 0.5 },
        );
    }

    for (s.board, 0..) |cell, i| {
        const c: Vec2 = cellCenter(lay, i);
        switch (cell) {
            .empty => {},
            .x => drawX(f.gl, c, lay.cell * 0.28, thick),
            .o => drawO(f.gl, c, lay.cell * 0.30, thick),
        }
    }

    // Strike through the winning triple.
    if (s.win_line) |li| {
        const line: [3]usize = win_lines[li];
        f.gl.line(
            cellCenter(lay, line[0]),
            cellCenter(lay, line[2]),
            .{ .color = win_col, .thickness = thick },
        );
    }

    common.caption(f.gl, s.font, s.status());
    z.endDrawing(f.gl);
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - tic tac toe",
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
