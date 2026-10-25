//! goban_play - a game against goban's computer from the command line (`zbuild goban-play -- <options> <moves>`): the
//! game replayed from the moves given, the computer's reply when it is its turn, and the board written as text.
//!
//! Each call is the whole game: it keeps nothing between calls, so a game is played by calling it again with one move
//! more. The options set the game - `--size` (8), `--outposts` (4, half of each colour) or `--black-outposts` and
//! `--white-outposts`, `--seed` (1, the outposts' draw), `--goal` (1), `--first` (black, or white),
//! `--computer` (white, or black) - and the search: `--milliseconds` (1000, as the app's) or `--iterations` (a count
//! instead, for a game that comes out the same every time). The moves follow, each a column letter from the left and
//! a row number from the bottom, as Go writes them: `d5 c4 e3`. The rules and the search are goban's own
//! (`goban.zig`), the ones the app plays with; none of the engine is needed for them, so this is a plain native
//! program.
const std = @import("std");
const goban = @import("goban.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const File = Io.File;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const sortSlice = std.mem.sort;

const Point = goban.Point;
const Stone = goban.Stone;
const Game = goban.Game;
const Position = goban.Position;
const SearchNode = goban.SearchNode;
const SearchTree = goban.SearchTree;

/// What a call is told: the game, the search, and the moves so far.
const PlayOptions = struct {
    board_size: u8 = 8,
    black_outposts: u8 = 2,
    white_outposts: u8 = 2,
    seed: u64 = 1,
    capture_goal: u8 = 1,
    computer: Stone = .white,
    /// Who moves first.
    first_player: Stone = .black,
    /// The search's time, in milliseconds; ignored when `iterations` is given.
    milliseconds: u32 = 1000,
    iterations: ?u32 = null,
    /// The iterations of one slice of the search: the time is read between slices.
    slice_iterations: u32 = 2000,
    /// The most nodes the tree may have; past it, it stops growing and its iterations still run.
    max_tree_nodes: u32 = 400_000,
    moves: []const []const u8 = &.{},
};

/// The options and moves in `args` (the program's name first), or an error naming what is wrong.
fn parseOptions(args: []const [:0]const u8, moves_buffer: [][]const u8) !PlayOptions {
    var options: PlayOptions = .{};
    var move_count: usize = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        const is_option: bool = arg.len > 2 and arg[0] == '-' and arg[1] == '-';
        if (!is_option) {
            moves_buffer[move_count] = arg;
            move_count += 1;
            continue;
        }
        index += 1;
        if (index >= args.len) {
            return error.OptionWithoutValue;
        }
        const value: []const u8 = args[index];
        if (eql(u8, arg, "--size")) {
            options.board_size = try parseInt(u8, value, 10);
        } else if (eql(u8, arg, "--outposts")) {
            const count: u8 = try parseInt(u8, value, 10);
            options.white_outposts = count / 2;
            options.black_outposts = count - count / 2;
        } else if (eql(u8, arg, "--black-outposts")) {
            options.black_outposts = try parseInt(u8, value, 10);
        } else if (eql(u8, arg, "--white-outposts")) {
            options.white_outposts = try parseInt(u8, value, 10);
        } else if (eql(u8, arg, "--seed")) {
            options.seed = try parseInt(u64, value, 10);
        } else if (eql(u8, arg, "--goal")) {
            options.capture_goal = try parseInt(u8, value, 10);
        } else if (eql(u8, arg, "--milliseconds")) {
            options.milliseconds = try parseInt(u32, value, 10);
        } else if (eql(u8, arg, "--iterations")) {
            options.iterations = try parseInt(u32, value, 10);
        } else if (eql(u8, arg, "--first")) {
            options.first_player = if (eql(u8, value, "white")) .white else .black;
        } else if (eql(u8, arg, "--computer")) {
            options.computer = if (eql(u8, value, "black")) .black else .white;
        } else {
            return error.UnknownOption;
        }
    }
    options.moves = moves_buffer[0..move_count];
    return options;
}

/// The point a move's text names - a column letter from the left, a row number from the bottom - or null.
fn parsePoint(board_size: u8, text: []const u8) ?Point {
    if (text.len < 2) {
        return null;
    }
    const letter: u8 = std.ascii.toLower(text[0]);
    if (letter < 'a' or letter >= 'a' + board_size) {
        return null;
    }
    const col: u8 = letter - 'a';
    const row_from_bottom: u8 = parseInt(u8, text[1..], 10) catch {
        return null;
    };
    if (row_from_bottom < 1 or row_from_bottom > board_size) {
        return null;
    }
    const row: u8 = board_size - row_from_bottom;
    return goban.pointAt(board_size, row, col);
}

/// Writes `point` as a move's text: `d5`.
fn writePoint(out: *Io.Writer, board_size: u8, point: Point) !void {
    const col: u8 = goban.colOf(board_size, point);
    const row: u8 = goban.rowOf(board_size, point);
    try out.print("{c}{d}", .{ 'a' + col, board_size - row });
}

/// Writes the board, its columns lettered and its rows numbered from the bottom, the last move in brackets.
fn writeBoard(out: *Io.Writer, position: *const Position) !void {
    const board_size: u8 = position.board_size;
    try out.writeAll("\n    ");
    for (0..board_size) |col| {
        try out.print(" {c} ", .{'a' + @as(u8, @intCast(col))});
    }
    try out.writeAll("\n");
    for (0..board_size) |row_index| {
        const row: u8 = @intCast(row_index);
        try out.print(" {d:>2} ", .{board_size - row});
        for (0..board_size) |col_index| {
            const point: Point = goban.pointAt(board_size, row, @intCast(col_index));
            const symbol: u8 = switch (position.stones[point]) {
                .black => 'X',
                .white => 'O',
                .none => '.',
            };
            const is_last_move: bool = position.last_move == point;
            if (is_last_move) {
                try out.print("[{c}]", .{symbol});
            } else {
                try out.print(" {c} ", .{symbol});
            }
        }
        try out.print(" {d}\n", .{board_size - row});
    }
    try out.writeAll("    ");
    for (0..board_size) |col| {
        try out.print(" {c} ", .{'a' + @as(u8, @intCast(col))});
    }
    try out.writeAll("\n\n");
}

/// Writes the root's most visited moves, up to `count` of them, with their visits and win rates.
fn writeTopMoves(
    out: *Io.Writer,
    tree: *const SearchTree,
    board_size: u8,
    count: usize,
) !void {
    var children: [goban.board_limits.max_points]SearchNode = undefined;
    var child_count: usize = 0;
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        children[child_count] = tree.nodes[child_index];
        child_count += 1;
    }
    const ByVisits = struct {
        fn greater(_: void, left: SearchNode, right: SearchNode) bool {
            return left.visits > right.visits;
        }
    };
    sortSlice(SearchNode, children[0..child_count], {}, ByVisits.greater);
    for (children[0..@min(count, child_count)]) |child| {
        const win_rate: f32 = child.winRate();
        try out.writeAll("    ");
        try writePoint(out, board_size, child.move);
        try out.print("  {d} visits, wins {d:.0}%\n", .{ child.visits, 100 * win_rate });
    }
}

/// The computer's move in `game`: the search run in slices, each taking up the tree the last made, until its time or
/// its count is reached - or at once when the move is forced. Writes what the search found.
fn computerMove(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    game: *const Game,
    options: PlayOptions,
    node_buffer: []SearchNode,
) !?Point {
    const started: Io.Timestamp = .now(io, .awake);
    const search_seed: u64 = options.seed *% 1_000_003 +% game.record.moves_played;
    var tree: ?SearchTree = null;
    var iterations_done: u64 = 0;
    while (true) {
        const slice: u32 = options.slice_iterations;
        tree = try goban.continueSearch(gpa, &game.record, tree, node_buffer, slice, search_seed, .{});
        iterations_done += slice;
        const elapsed_ns: i96 = started.durationTo(.now(io, .awake)).nanoseconds;
        const elapsed_ms: u64 = @intCast(@divTrunc(elapsed_ns, 1_000_000));
        const count_reached: bool = if (options.iterations) |limit| iterations_done >= limit else false;
        const time_is_up: bool = options.iterations == null and elapsed_ms >= options.milliseconds;
        if (count_reached or time_is_up or goban.searchIsSettled(&tree.?)) {
            try out.print("the computer searched {d} iterations in {d} ms; its tree has {d} nodes\n", .{
                iterations_done,
                elapsed_ms,
                tree.?.header.node_count,
            });
            break;
        }
    }
    try writeTopMoves(out, &tree.?, game.position.board_size, 5);
    // The move the computer would play: chosen as its default settings choose.
    const settings: goban.SearchSettings = .{};
    return goban.playedMove(&tree.?, &game.position, settings);
}

/// One call: the options and moves read, the game replayed, the computer's reply, and the board written to `out`.
fn play(init: std.process.Init, out: *Io.Writer) !void {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());
    var moves_buffer: [goban.record_limits.max_moves][]const u8 = undefined;
    const options: PlayOptions = parseOptions(args, &moves_buffer) catch |err| {
        try out.print("goban-play: {t}. Options: --size --outposts --black-outposts --white-outposts --seed --goal " ++
            "--first --milliseconds --iterations --computer; then the moves, as d5 c4 ...\n", .{err});
        return;
    };

    const game: *Game = try gpa.create(Game);
    defer gpa.destroy(game);
    goban.startGame(game, .{
        .board_size = options.board_size,
        .capture_goal = options.capture_goal,
        .scattered = .{
            .black_count = options.black_outposts,
            .white_count = options.white_outposts,
            .seed = options.seed,
        },
        .first_player = options.first_player,
    });

    // The moves given, each checked by the rules.
    for (options.moves, 0..) |move_text, move_index| {
        if (game.position.winner != null) {
            try out.print("move {d} ({s}): the game is already won\n", .{ move_index + 1, move_text });
            return;
        }
        const point: Point = parsePoint(options.board_size, move_text) orelse {
            try out.print("move {d} ({s}): not a point of the board\n", .{ move_index + 1, move_text });
            return;
        };
        const legality: goban.Legality = goban.checkMove(&game.position, point);
        if (legality != .legal) {
            try out.print("move {d} ({s}): {t}\n", .{ move_index + 1, move_text, legality });
            return;
        }
        _ = goban.playMove(game, point);
    }

    // The computer's reply, when it is its turn.
    const computer_to_play: bool = game.position.winner == null and game.position.player_to_move == options.computer;
    if (computer_to_play) {
        const node_buffer: []SearchNode = try gpa.alloc(SearchNode, options.max_tree_nodes);
        defer gpa.free(node_buffer);
        if (try computerMove(gpa, io, out, game, options, node_buffer)) |move| {
            _ = goban.playMove(game, move);
            try out.writeAll("the computer plays ");
            try writePoint(out, options.board_size, move);
            try out.writeAll("\n");
        }
    }

    try writeBoard(out, &game.position);
    try out.print("prisoners: black {d}, white {d}\n", .{
        game.position.stones_captured_by_black,
        game.position.stones_captured_by_white,
    });
    if (game.position.winner) |winner| {
        try out.print("{t} wins\n", .{winner});
    } else {
        try out.print("{t} to play\n", .{game.position.player_to_move});
    }
    try out.writeAll("moves:");
    for (game.record.moves[0..game.record.moves_played]) |move| {
        try out.writeAll(" ");
        try writePoint(out, options.board_size, move);
    }
    try out.writeAll("\n");
}

pub fn main(init: std.process.Init) !void {
    var out_buffer: [8192]u8 = undefined;
    var out_writer: File.Writer = File.stdout().writer(init.io, &out_buffer);
    const out: *Io.Writer = &out_writer.interface;
    try play(init, out);
    try out.flush();
}
