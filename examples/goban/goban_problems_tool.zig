//! goban_problems_tool - turns published SGF go problems into goban's kill problems
//! (`zbuild goban-problems-convert -- [--out <dir>] [--iterations <n>] <sgf files>`).
//!
//! A published problem says "Black to play" and gives its solution as a tree of variations, the correct lines ending
//! in a comment that begins "Correct" - but not which stone black must capture. goban plays a problem as a capture:
//! black wins by capturing one marked white stone, its target. This tool finds that stone with goban's own search, the
//! one the app's computer plays with:
//!
//!   1. every white chain of the problem is tried as the target: the search, from the problem's start with black to
//!      play, chooses black's move; the chain is a candidate when that move is one of the book's correct first moves,
//!      the search agreeing with the book that this is the stone the problem is about;
//!   2. the largest candidate is the target - the group the problem kills, not a stone it captures on the way;
//!   3. the target is checked with white to play first: white should save it, so that the problem is not decided
//!      before black's first move.
//!
//! Each problem's result is reported - every chain tried, the search's moves and win rates - and a problem with a
//! target is written to the output directory with a triangle (`TR`) on it, the rest of the file as it was. A problem
//! the search and the book do not agree on is not written. The search runs a fixed count of iterations, so the same
//! files give the same report.
const std = @import("std");
const zm = @import("zm");
const goban = @import("goban.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const File = Io.File;
const Dir = Io.Dir;
const eql = std.mem.eql;
const parseInt = std.fmt.parseInt;
const maxInt = zm.maxInt;
const float = zm.float;
const clamp = zm.clamp;
const sortSlice = std.mem.sort;
const basename = std.fs.path.basename;
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const indexOfScalar = std.mem.indexOfScalar;
const splitScalar = std.mem.splitScalar;
const startsWith = std.mem.startsWith;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const parseFloat = std.fmt.parseFloat;
const indexOf = std.mem.indexOf;

const Point = goban.Point;
const Stone = goban.Stone;
const Game = goban.Game;
const SearchNode = goban.SearchNode;
const SearchTree = goban.SearchTree;
const SgfRoot = goban.SgfRoot;
const SgfFirstMove = goban.SgfFirstMove;
const board_limits = goban.board_limits;

/// What a run is told: where to write, how long each search runs, and the files.
const ConvertOptions = struct {
    out_dir: []const u8 = "examples/goban/problems",
    iterations: u32 = 200_000,
    /// A search runs in slices of this many iterations; after `min_iterations` it stops once its most visited move
    /// holds `settled_share` of the root's visits - a choice made - and at any time once its choice can no longer
    /// change.
    slice_iterations: u32 = 10_000,
    min_iterations: u32 = 50_000,
    settled_share: f32 = 0.7,
    /// ... and stops as well once even its most visited move wins less than this: a reading needs 50%
    /// (`solvable_rate`, `unsettled_rate`), and a search whose best is this far below will not reach it - the
    /// full count would only confirm a failure.
    hopeless_rate: f32 = 0.35,
    /// ... and only when the leader also wins at least as often as every child holding this share of the visits.
    counted_share: f32 = 0.01,
    /// How many problems are converted at once, each on a thread of its own: one for each of the machine's cores.
    thread_count: ?usize = null,
    /// The longest a problem's conversion may take, in seconds: a problem past it stops where it is, keeping what it
    /// had accepted (`OutcomeNote.too_slow`). Most take under two minutes; the few that take many more are wide
    /// positions with many candidate chains, whose time is better spent on the next problems.
    time_cap_seconds: f32 = 180,
    /// Whether the run converts the problems a person has annotated (`annotations.tsv` beside the problems: each one's
    /// kind and target, read from its diagram) instead of searching for their targets: one search checks each, of
    /// `check_iterations` - one of the book's correct first moves must win at least `solvable_rate` for black over at
    /// least `check_min_visits` visits - its later starts checked by one search each, and no twin.
    annotated: bool = false,
    /// Whether the run converts problems that have no book - positions only, as a scanned collection gives them
    /// (`convertBookless`).
    bookless: bool = false,
    /// A collection to split into source files (`splitCollection`): its path, the book's name for the comments,
    /// and the files' stem - `cho-easy` makes `cho-easy-0001.sgf`.
    split_path: ?[]const u8 = null,
    split_book: []const u8 = "",
    split_stem: []const u8 = "",
    /// Whether the run sets each kill problem's target to the chain its book kills (`bookTarget`), the problem files
    /// given - and their later starts' - marked anew where it differs; nothing converted.
    retargets: bool = false,
    check_iterations: u32 = 30_000,
    check_min_visits: u32 = 300,
    /// A move wins a puzzle clearly at this share of its playouts or more (`PuzzleInterest`); a puzzle is trivial when
    /// its obvious move does, or when `max_clear_moves` moves or more do.
    clear_rate: f32 = 0.8,
    max_clear_moves: u32 = 3,
    /// A bookless problem's own puzzle is solved when its best move wins at least this often (`convertBookless`):
    /// the search has found the answer, though playouts that do not finish off a dead group keep a kill's rate
    /// low. Its twin, made from it, still needs a clear win (`clear_rate`).
    bookless_rate: f32 = 0.65,
    /// A bookless puzzle whose best move wins at least `recheck_rate` but not enough is searched once more, longer,
    /// with `recheck_iterations`: a near miss in a short search is often a win in a longer.
    recheck_rate: f32 = 0.5,
    recheck_iterations: u32 = 120_000,
    /// A bookless puzzle's best move is refuted when the opponent's best reply to it, searched, still wins more often
    /// than this (`opponentReplyRate`): the first search can rate a move highly that a plain reply undoes - a
    /// throw-in the defender simply captures.
    refute_rate: f32 = 0.35,
    /// The clock a problem's conversion reads, and when it began: set for each problem (`convertProblem`), so that
    /// its searches stop at the cap (`search`).
    clock: ?Io = null,
    started: ?Io.Timestamp = null,
    /// The most later starts checked along a correct line - a hard problem's runs to dozens of moves.
    max_later_starts: u8 = 6,
    /// Whether the run adopts the problems already written to the output directory into the report, from their
    /// files, instead of converting them: an index for work done before the report was kept.
    adopts: bool = false,
    /// Whether the run only prints each problem's hint (`kindHint`), converting none.
    prints_hints: bool = false,
    /// Whether the run only prints, for each problem file given, how interesting each puzzle of its ladder is
    /// (`PuzzleInterest`): every start along its correct line, the book's own kind and the twin. Nothing is written.
    prints_interest: bool = false,
    /// Where `prints_interest` writes each puzzle it keeps as an SGF file of its own, or nowhere.
    interest_out_dir: ?[]const u8 = null,
    /// Whether the run measures the difficulty of the problems it is given - converted ones, marked - instead of
    /// converting (`measureDifficulty`): their search in slices of `measure_slice_iterations`, up to
    /// `measure_iterations`, each problem's result a line of `difficulty.tsv`.
    measures: bool = false,
    measure_iterations: u32 = 100_000,
    measure_slice_iterations: u32 = 1_000,
    /// A chain is tried as a target only when one of its stones is this near a move of the book's correct line -
    /// the larger of the row and column steps.
    candidate_reach: u8 = 2,
    seed: u64 = 1,
    problem_settings: goban.ProblemSettings = .{},
    /// A position is unsettled - a problem - when white, moving first, saves the target at least this often.
    unsettled_rate: f32 = 0.5,
    /// How often black's search must win, black moving first, for a reading to be a problem at all: black must be
    /// able to solve it. A reading whose best try loses - a kill reading of a group that lives whatever black does -
    /// is no problem, though its least bad move may be the book's.
    solvable_rate: f32 = 0.5,
    /// A reading holds when one of the book's correct first moves wins at least `solvable_rate` for black over at least
    /// this many visits - enough for its rate to mean something: the search need not prefer the book's move, only find
    /// it good. On a hard problem the search often prefers another, and spends most of its visits there; the book
    /// still decides the problem in play, the computer following it and "Solved" coming from its line.
    book_min_visits: u32 = 1_000,
    /// The largest file read.
    read_limit: Io.Limit = .limited(1 << 20),
    paths: []const []const u8 = &.{},
};

/// The options and paths in `args` (the program's name first).
fn parseOptions(args: []const [:0]const u8, paths_buffer: [][]const u8) !ConvertOptions {
    var options: ConvertOptions = .{};
    var path_count: usize = 0;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg: []const u8 = args[index];
        if (eql(u8, arg, "--adopt")) {
            options.adopts = true;
            continue;
        }
        if (eql(u8, arg, "--annotated")) {
            options.annotated = true;
            continue;
        }
        if (eql(u8, arg, "--bookless")) {
            options.bookless = true;
            continue;
        }
        if (eql(u8, arg, "--retarget")) {
            options.retargets = true;
            continue;
        }
        if (eql(u8, arg, "--split")) {
            if (index + 3 >= args.len) {
                return error.MissingValue;
            }
            options.split_path = args[index + 1];
            options.split_book = args[index + 2];
            options.split_stem = args[index + 3];
            index += 3;
            continue;
        }
        if (eql(u8, arg, "--measure")) {
            options.measures = true;
            continue;
        }
        if (eql(u8, arg, "--hints")) {
            options.prints_hints = true;
            continue;
        }
        if (eql(u8, arg, "--interest")) {
            options.prints_interest = true;
            continue;
        }
        if (eql(u8, arg, "--interest-out")) {
            index += 1;
            if (index >= args.len) {
                return error.MissingValue;
            }
            options.interest_out_dir = args[index];
            continue;
        }
        const takes_value: bool = eql(u8, arg, "--out") or eql(u8, arg, "--iterations") or eql(u8, arg, "--threads") or
            eql(u8, arg, "--max-later-starts") or eql(u8, arg, "--time-cap");
        if (takes_value) {
            index += 1;
            if (index >= args.len) {
                return error.OptionWithoutValue;
            }
            if (eql(u8, arg, "--out")) {
                options.out_dir = args[index];
            } else if (eql(u8, arg, "--iterations")) {
                options.iterations = try parseInt(u32, args[index], 10);
            } else if (eql(u8, arg, "--time-cap")) {
                options.time_cap_seconds = try parseFloat(f32, args[index]);
            } else if (eql(u8, arg, "--max-later-starts")) {
                options.max_later_starts = try parseInt(u8, args[index], 10);
            } else {
                options.thread_count = try parseInt(usize, args[index], 10);
            }
            continue;
        }
        paths_buffer[path_count] = arg;
        path_count += 1;
    }
    options.paths = paths_buffer[0..path_count];
    return options;
}

/// Writes `point` in SGF's letters: its column, then its row.
fn writeSgfPoint(out: *Io.Writer, board_size: u8, point: Point) !void {
    try out.print("{c}{c}", .{ 'a' + goban.colOf(board_size, point), 'a' + goban.rowOf(board_size, point) });
}

/// What one search found: its move, and how often the player who made it won.
const SearchResult = struct {
    move: ?Point,
    win_rate: f32,
};

/// A root child's visits and win rate for its player, or zeros when the root has no child of that move.
const ChildStatistics = struct {
    visits: u32 = 0,
    win_rate: f32 = 0,
};

/// The statistics of the root's child for `move` (`goban.rootChild`).
fn childStatistics(tree: *const SearchTree, move: Point) ChildStatistics {
    const child: *const SearchNode = goban.rootChild(tree, move) orelse {
        return .{};
    };
    return .{ .visits = child.visits, .win_rate = child.winRate() };
}

/// Whether the root's most visited child is ahead of every other by more visits than `iterations_left`: then even
/// all of them given to another could not overtake it.
fn choiceCannotChange(tree: *const SearchTree, iterations_left: u32) bool {
    var most_visits: u32 = 0;
    var next_visits: u32 = 0;
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const visits: u32 = tree.nodes[child_index].visits;
        if (visits > most_visits) {
            next_visits = most_visits;
            most_visits = visits;
        } else if (visits > next_visits) {
            next_visits = visits;
        }
    }
    return most_visits - next_visits > iterations_left;
}

/// Whether the root's most visited child also wins at least as often as every other child with a share of the visits
/// worth counting - `least_share` of them: while a less visited move wins more often, the search is still moving its
/// visits there, and the leader may yet change.
fn leaderWinsMost(tree: *const SearchTree, least_share: f32) bool {
    const root_visits: f32 = float(@max(tree.nodes[0].visits, 1));
    var leader_visits: u32 = 0;
    var leader_rate: f32 = 0;
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const child: SearchNode = tree.nodes[child_index];
        if (child.visits > leader_visits) {
            leader_visits = child.visits;
            leader_rate = child.winRate();
        }
    }
    child_index = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const child: SearchNode = tree.nodes[child_index];
        const counts: bool = float(child.visits) >= least_share * root_visits;
        const rate: f32 = child.winRate();
        if (counts and rate > leader_rate) {
            return false;
        }
    }
    return true;
}

/// The share of the root's visits its most visited child has.
fn leaderShare(tree: *const SearchTree) f32 {
    var most_visits: u32 = 0;
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        most_visits = @max(most_visits, tree.nodes[child_index].visits);
    }
    const root_visits: f32 = float(@max(tree.nodes[0].visits, 1));
    return float(most_visits) / root_visits;
}

/// The search from `game`'s position, its tree in `node_buffer` (the file's lesson): in slices, each taking up the
/// tree the last made, up to `options.iterations` - stopping early once its choice is made (past the minimum, the
/// most visited move holding the settled share of the visits), once it can no longer change (ahead of the next by more
/// visits than are left to give), or once the search is settled.
fn search(
    gpa: Allocator,
    game: *const Game,
    options: ConvertOptions,
    node_buffer: []SearchNode,
) !SearchTree {
    var tree: ?SearchTree = null;
    var iterations_done: u32 = 0;
    while (iterations_done < options.iterations) {
        const slice: u32 = @min(options.slice_iterations, options.iterations - iterations_done);
        tree = try goban.continueSearch(gpa, &game.record, tree, node_buffer, slice, options.seed, .{});
        iterations_done += slice;
        // The problem's time cap, checked between slices.
        if (options.clock) |clock| {
            const elapsed_ns: i96 = options.started.?.durationTo(.now(clock, .awake)).nanoseconds;
            const cap_ns: f32 = options.time_cap_seconds * 1e9;
            if (float(elapsed_ns) > cap_ns) {
                return error.TimeUp;
            }
        }
        const iterations_left: u32 = options.iterations - iterations_done;
        const past_minimum: bool = iterations_done >= options.min_iterations;
        const choice_is_made: bool = past_minimum and leaderShare(&tree.?) >= options.settled_share and
            leaderWinsMost(&tree.?, options.counted_share);
        const leader: ?Point = goban.mostVisitedMove(&tree.?);
        const leader_rate: f32 = if (leader) |move| childStatistics(&tree.?, move).win_rate else 0;
        const is_hopeless: bool = past_minimum and leader_rate < options.hopeless_rate;
        const stops: bool = choice_is_made or is_hopeless or choiceCannotChange(&tree.?, iterations_left);
        if (goban.searchIsSettled(&tree.?) or stops) {
            break;
        }
    }
    return tree.?;
}

/// The move a search chose, and its win rate for its player.
fn chosenMove(tree: *const SearchTree) SearchResult {
    const move: Point = goban.mostVisitedMove(tree) orelse {
        return .{ .move = null, .win_rate = 0 };
    };
    return .{ .move = move, .win_rate = childStatistics(tree, move).win_rate };
}

/// How hard a problem's answer is to find (the file's lesson): its search played in slices of
/// `options.measure_slice_iterations`, up to `options.measure_iterations`, without stopping early, and the iterations
/// after which its choice was one of the book's correct first moves, `correct_moves`, and stayed so to the end. A
/// problem whose search ends on another move gets the whole count: as hard as the measure goes.
fn measureDifficulty(
    gpa: Allocator,
    game: *Game,
    problem: *const goban.Problem,
    correct_moves: []const Point,
    options: ConvertOptions,
    node_buffer: []SearchNode,
) !u32 {
    goban.startProblem(game, problem, options.problem_settings);
    var tree: ?SearchTree = null;
    var iterations_done: u32 = 0;
    var settled_at: u32 = 0;
    var last_choice: ?Point = null;
    while (iterations_done < options.measure_iterations) {
        const slice: u32 = @min(options.measure_slice_iterations, options.measure_iterations - iterations_done);
        tree = try goban.continueSearch(gpa, &game.record, tree, node_buffer, slice, options.seed, .{});
        iterations_done += slice;
        const choice: ?Point = goban.mostVisitedMove(&tree.?);
        if (choice != last_choice) {
            settled_at = iterations_done;
            last_choice = choice;
        }
    }
    var ends_on_book: bool = false;
    for (correct_moves) |correct_move| {
        ends_on_book = ends_on_book or last_choice == correct_move;
    }
    return if (ends_on_book) settled_at else options.measure_iterations;
}

/// The difficulties measured so far (`measureDifficulty`), kept in `difficulty.tsv` beside the problems: one line a
/// problem, its name and its iterations, rewritten after each - so a measuring run stopped part way keeps what it
/// measured, and the next skips it.
const Difficulties = struct {
    text: ArrayList(u8),
    path: []const u8,

    /// The difficulties at `path`, or none when there is no such file.
    fn load(
        gpa: Allocator,
        io: Io,
        path: []const u8,
        read_limit: Io.Limit,
    ) !Difficulties {
        var difficulties: Difficulties = .{ .text = .empty, .path = path };
        const existing: ?[]u8 = Dir.cwd().readFileAlloc(io, path, gpa, read_limit) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |text| {
            try difficulties.text.appendSlice(gpa, text);
        }
        return difficulties;
    }

    /// The problem `name`'s difficulty, or null when it has not been measured.
    fn of(difficulties: *const Difficulties, name: []const u8) ?u32 {
        var lines = splitScalar(u8, difficulties.text.items, '\n');
        while (lines.next()) |line| {
            var columns = splitScalar(u8, line, '\t');
            const line_name: []const u8 = columns.next() orelse continue;
            const value_text: []const u8 = columns.next() orelse continue;
            if (eql(u8, line_name, name)) {
                return parseInt(u32, value_text, 10) catch null;
            }
        }
        return null;
    }

    /// Adds the problem `name`'s difficulty and writes the file out.
    fn add(
        difficulties: *Difficulties,
        gpa: Allocator,
        io: Io,
        name: []const u8,
        difficulty: u32,
    ) !void {
        var line_buffer: [512]u8 = undefined;
        const line: []const u8 = try bufPrint(&line_buffer, "{s}\t{d}\n", .{ name, difficulty });
        try difficulties.text.appendSlice(gpa, line);
        try Dir.cwd().writeFile(io, .{ .sub_path = difficulties.path, .data = difficulties.text.items });
    }
};

/// The verdicts of interest kept beside the problems (`interest.tsv`), added to by bookless conversions as they go.
const Verdicts = struct {
    text: ArrayList(u8),
    path: []const u8,
    lock: Io.Mutex = .init,

    /// The verdicts at `path`, or none when there is no such file.
    fn load(gpa: Allocator, io: Io, path: []const u8, read_limit: Io.Limit) !Verdicts {
        var verdicts: Verdicts = .{ .text = .empty, .path = path };
        const existing: ?[]u8 = Dir.cwd().readFileAlloc(io, path, gpa, read_limit) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |text| {
            defer gpa.free(text);
            try verdicts.text.appendSlice(gpa, text);
        }
        return verdicts;
    }

    /// Adds `lines` and writes the file out.
    fn add(verdicts: *Verdicts, gpa: Allocator, io: Io, lines: []const u8) !void {
        verdicts.lock.lockUncancelable(io);
        defer verdicts.lock.unlock(io);
        try verdicts.text.appendSlice(gpa, lines);
        try Dir.cwd().writeFile(io, .{ .sub_path = verdicts.path, .data = verdicts.text.items });
    }
};

/// Measures every problem in `options.paths` not yet in `difficulties` (`measureDifficulty`), one after another: each
/// a converted problem's file, its mark its target, its book its correct first moves.
fn measureAll(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    options: ConvertOptions,
    difficulties: *Difficulties,
) !void {
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const game: *Game = try arena.create(Game);
    const node_buffer: []SearchNode = try arena.alloc(SearchNode, options.measure_iterations + 1);
    for (options.paths) |path| {
        const name: []const u8 = basename(path);
        if (difficulties.of(name) != null) {
            continue;
        }
        const text: []const u8 = try Dir.cwd().readFileAlloc(io, path, arena, options.read_limit);
        const problem: goban.Problem = try goban.readProblem(text);
        const root: SgfRoot = try goban.readSgfRoot(text);
        var first_move_buffer: [board_limits.max_points]goban.SgfFirstMove = undefined;
        const first_moves: []const goban.SgfFirstMove = try goban.readSgfFirstMoves(text, &root, &first_move_buffer);
        var correct_buffer: [board_limits.max_points]Point = undefined;
        var correct_count: usize = 0;
        for (first_moves) |first_move| {
            if (first_move.leads_to_correct) {
                correct_buffer[correct_count] = first_move.point;
                correct_count += 1;
            }
        }
        const correct_moves: []const Point = correct_buffer[0..correct_count];
        const difficulty: u32 = try measureDifficulty(arena, game, &problem, correct_moves, options, node_buffer);
        try difficulties.add(gpa, io, name, difficulty);
        try out.print("{s}: {d}\n", .{ name, difficulty });
        try out.flush();
    }
}

/// How a problem's conversion ended, besides what it found.
const OutcomeNote = enum {
    converted,
    unreadable,
    already_marked,
    /// Taken into the report from its files (`ConvertOptions.adopts`), not converted in this run.
    adopted,
    /// Stopped at the time cap (`ConvertOptions.time_cap_seconds`), keeping what it had accepted.
    too_slow,
    /// Converted from its annotation (`ConvertOptions.annotated`), its check passed.
    annotated,
    /// Converted from its annotation though its check did not confirm it - the book's moves not winning for black
    /// often enough in a short search, a hard problem's usual lot: kept, the annotation trusted, and listed by this
    /// note for a second look.
    annotated_unconfirmed,
    /// Its annotation names no stone of the target's colour.
    bad_annotation,
    /// Converted with no book (`convertBookless`): its kind and target those its search solves clearly.
    bookless,
    /// No book, and its search solved it clearly neither as a kill problem nor as a life problem.
    unsolved,
    /// Annotated as no life-and-death problem - an attack, an invasion, a question of shape - which a puzzle of
    /// goban's cannot be.
    not_life_and_death,
};

/// Where a hint of a problem's kind comes from (`kindHint`).
const HintSource = enum {
    /// Its comments say whose group lives or dies.
    comments,
    /// Its stones' geometry: the wall facing the frame's open sides, and the more grouped colour, agree.
    geometry,
};

/// A guess of a problem's kind before any search, and where it comes from.
const KindHint = struct {
    kind: goban.ProblemKind,
    source: HintSource,
};

/// What converting one problem found (the file's lesson): a line of the report.
const ProblemOutcome = struct {
    note: OutcomeNote = .converted,
    board_size: u8 = 19,
    /// The problem as published, a kill or a life problem, or null when it is neither.
    published: ?goban.ProblemKind = null,
    target: ?Point = null,
    /// A life problem's colour-swapped twin's target, when the twin is a kill problem.
    twin_target: ?Point = null,
    black_rate: ?f32 = null,
    white_first_rate: ?f32 = null,
    /// The later starts accepted - the correct line's moves played before each - and how many were checked.
    later_starts: [max_later_starts]u8 = undefined,
    later_count: usize = 0,
    later_checked: u8 = 0,
    seconds: f32 = 0,
    /// The kind the problem was guessed to be before any search (`kindHint`).
    hint: ?KindHint = null,
    /// The verdicts of interest a bookless conversion measured (`interest.tsv`'s lines), added with the report's.
    verdict_buffer: [512]u8 = undefined,
    verdict_length: usize = 0,

    const max_later_starts: usize = 64;
};

/// A problem's level, as its file's name says - its second word: `ggg-easy-01.sgf`, `cho-intermediate-0001.sgf`;
/// any other is other.
fn levelOf(name: []const u8) goban.ProblemLevel {
    var words = splitScalar(u8, name, '-');
    _ = words.next();
    const level_word: []const u8 = words.next() orelse return .other;
    return std.meta.stringToEnum(goban.ProblemLevel, level_word) orelse .other;
}

/// Writes a rate for the report: its percentage, or `-` when there is none.
fn writeRate(out: *Io.Writer, rate: ?f32) !void {
    if (rate) |known| {
        try out.print("{d:.0}", .{100 * known});
    } else {
        try out.writeAll("-");
    }
}

/// Writes a point for the report: its SGF letters, or `-`.
fn writeReportPoint(out: *Io.Writer, board_size: u8, point: ?Point) !void {
    if (point) |known| {
        try writeSgfPoint(out, board_size, known);
    } else {
        try out.writeAll("-");
    }
}

/// The report's columns, its first line.
const report_header: []const u8 = "# name\tlevel\tnote\tpublished\ttarget\tblack %\twhite first %" ++
    "\tlater starts\tlater checked\ttwin target\tseconds\thint\n";

/// Writes `outcome` as one line of the report: tab-separated, the later starts a comma-separated list of the moves
/// played before each.
fn writeReportLine(
    out: *Io.Writer,
    name: []const u8,
    outcome: *const ProblemOutcome,
) !void {
    const published_name: []const u8 = if (outcome.published) |kind| @tagName(kind) else "-";
    try out.print("{s}\t{t}\t{t}\t{s}\t", .{ name, levelOf(name), outcome.note, published_name });
    try writeReportPoint(out, outcome.board_size, outcome.target);
    try out.writeAll("\t");
    try writeRate(out, outcome.black_rate);
    try out.writeAll("\t");
    try writeRate(out, outcome.white_first_rate);
    try out.writeAll("\t");
    for (outcome.later_starts[0..outcome.later_count], 0..) |moves_before, later_index| {
        if (later_index > 0) {
            try out.writeAll(",");
        }
        try out.print("{d}", .{moves_before});
    }
    if (outcome.later_count == 0) {
        try out.writeAll("-");
    }
    try out.print("\t{d}\t", .{outcome.later_checked});
    try writeReportPoint(out, outcome.board_size, outcome.twin_target);
    try out.print("\t{d:.0}\t", .{outcome.seconds});
    if (outcome.hint) |hint| {
        try out.print("{t} from the {t}\n", .{ hint.kind, hint.source });
    } else {
        try out.writeAll("-\n");
    }
}

/// The report of a run and of the runs before it (the file's lesson): one line a problem, kept in `report.tsv` in the
/// output directory and rewritten after each problem, so a run stopped part way loses at most the problem it was on,
/// and the next run skips every problem the report has.
const Report = struct {
    text: ArrayList(u8),
    path: []const u8,
    lock: Io.Mutex = .init,

    /// The report at `path`, or a new one with its header when there is none.
    fn load(gpa: Allocator, io: Io, path: []const u8, read_limit: Io.Limit) !Report {
        var report: Report = .{ .text = .empty, .path = path };
        const existing: ?[]u8 = Dir.cwd().readFileAlloc(io, path, gpa, read_limit) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |text| {
            try report.text.appendSlice(gpa, text);
        } else {
            try report.text.appendSlice(gpa, report_header);
        }
        return report;
    }

    /// Whether the report has a line for the problem named `name`.
    fn has(report: *const Report, name: []const u8) bool {
        var lines = splitScalar(u8, report.text.items, '\n');
        while (lines.next()) |line| {
            const first_column: []const u8 = line[0 .. indexOfScalar(u8, line, '\t') orelse line.len];
            if (eql(u8, first_column, name)) {
                return true;
            }
        }
        return false;
    }

    /// Adds `outcome`'s line and writes the report out.
    fn add(
        report: *Report,
        gpa: Allocator,
        io: Io,
        name: []const u8,
        outcome: *const ProblemOutcome,
    ) !void {
        report.lock.lockUncancelable(io);
        defer report.lock.unlock(io);
        var line: Io.Writer.Allocating = .init(gpa);
        defer line.deinit();
        try writeReportLine(&line.writer, name, outcome);
        try report.text.appendSlice(gpa, line.written());
        try Dir.cwd().writeFile(io, .{ .sub_path = report.path, .data = report.text.items });
    }
};

/// The book a problem's name says it is from: its name up to its number - `cho-easy` for `cho-easy-0007.sgf`.
fn bookOf(name: []const u8) []const u8 {
    const dash: usize = std.mem.lastIndexOfScalar(u8, name, '-') orelse return name;
    return name[0..dash];
}

/// The number at the end of a problem's name - `ggg-easy-07.sgf` is 7 - or zero when there is none.
fn numberIn(name: []const u8) u32 {
    const stem: []const u8 = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
    const dash: usize = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return 0;
    return parseInt(u32, stem[dash + 1 ..], 10) catch 0;
}

/// One problem of the report, as the index needs it.
/// A start of a family's ladder as the index lists it (`goban.FamilyStart`): the moves of the correct line before
/// it, and which of its two puzzles the test of interest kept (`interest.tsv`).
const IndexStart = struct {
    moves: u8,
    own: bool = true,
    twin: bool = true,
};

const IndexEntry = struct {
    name: []const u8,
    level: goban.ProblemLevel,
    published: ?goban.ProblemKind,
    /// The later starts the converter accepted - its `from-move` files.
    later_starts: []const u8,
    /// The family's ladder starts (`ladderStarts`), the first its opening: a published problem's from its first move,
    /// a derived family's from one of its later starts (`derivedLevel`).
    starts: []const IndexStart = &.{},
    has_twin: bool,
    /// Its measured difficulty (`measureDifficulty`), or null when it has none yet.
    difficulty: ?u32,

    /// Before `other` in the index: by level, then by difficulty - the unmeasured last - then by the number in the
    /// name, then by the name, then by the first start - for the families derived from one problem, which share its
    /// name. An entry whose starts are not yet made counts as starting from the first move: a sort may compare an
    /// entry with itself, its starts empty while the published entries are sorted.
    fn before(_: void, entry: IndexEntry, other: IndexEntry) bool {
        if (entry.level != other.level) {
            return @backingInt(entry.level) < @backingInt(other.level);
        }
        const entry_difficulty: u32 = entry.difficulty orelse maxInt(u32);
        const other_difficulty: u32 = other.difficulty orelse maxInt(u32);
        if (entry_difficulty != other_difficulty) {
            return entry_difficulty < other_difficulty;
        }
        const entry_number: u32 = numberIn(entry.name);
        const other_number: u32 = numberIn(other.name);
        if (entry_number != other_number) {
            return entry_number < other_number;
        }
        if (!eql(u8, entry.name, other.name)) {
            return std.mem.lessThan(u8, entry.name, other.name);
        }
        const entry_first_start: u8 = if (entry.starts.len > 0) entry.starts[0].moves else 0;
        const other_first_start: u8 = if (other.starts.len > 0) other.starts[0].moves else 0;
        return entry_first_start < other_first_start;
    }
};

/// The ladder starts of the published problem `entry` (`IndexStart`): from its verdicts in `interest_text` when it
/// was measured - each start where a puzzle was kept, the first start's own puzzle always (its authors set it) - or,
/// not measured yet, its first start and later starts with every puzzle kept.
fn ladderStarts(
    gpa: Allocator,
    interest_text: []const u8,
    entry: *const IndexEntry,
) ![]const IndexStart {
    var starts: ArrayList(IndexStart) = .empty;
    var lines = splitScalar(u8, interest_text, '\n');
    while (lines.next()) |line| {
        var columns = splitScalar(u8, line, '\t');
        const name: []const u8 = columns.next() orelse continue;
        if (!eql(u8, name, entry.name)) {
            continue;
        }
        const moves_text: []const u8 = columns.next() orelse continue;
        const orientation: []const u8 = columns.next() orelse continue;
        _ = columns.next(); // the puzzle's kind
        const verdict: []const u8 = columns.next() orelse continue;
        const moves: u8 = parseInt(u8, moves_text, 10) catch continue;
        const kept: bool = eql(u8, verdict, "kept");
        // The start's entry, made by its first verdict, both puzzles dropped until a verdict keeps one.
        const is_new_start: bool = starts.items.len == 0 or starts.items[starts.items.len - 1].moves != moves;
        if (is_new_start) {
            try starts.append(gpa, .{ .moves = moves, .own = moves == 0, .twin = false });
        }
        const start: *IndexStart = &starts.items[starts.items.len - 1];
        if (eql(u8, orientation, "twin")) {
            start.twin = start.twin or kept;
        } else {
            start.own = start.own or kept;
        }
    }
    if (starts.items.len == 0) {
        try starts.append(gpa, .{ .moves = 0 });
        for (entry.later_starts) |later_start| {
            try starts.append(gpa, .{ .moves = later_start });
        }
        return starts.items;
    }
    // A start with neither puzzle kept is no step of any ladder.
    var kept_count: usize = 0;
    for (starts.items) |start| {
        if (start.own or start.twin) {
            starts.items[kept_count] = start;
            kept_count += 1;
        }
    }
    return starts.items[0..kept_count];
}

/// The level of a family derived from a later start of a problem of `level` (the file's lesson): a ladder's later
/// steps are easier than its first - a hard problem's are intermediate, an intermediate problem's easy, and an easy
/// problem's easy still. Their difficulty is not measured; they take their level's average.
fn derivedLevel(level: goban.ProblemLevel) goban.ProblemLevel {
    return switch (level) {
        .easy, .intermediate => .easy,
        .hard => .intermediate,
        .other => .other,
    };
}

/// Writes `index.zig` beside the problems from the report (the file's lesson): the families - each published problem
/// with its level and later starts - and the lists of kill and of life problems' files, each problem's later starts
/// and twin after it. goban.zig imports it, so every list of problems comes from the report, none written by hand.
fn writeIndex(
    gpa: Allocator,
    io: Io,
    report: *const Report,
    difficulties: *const Difficulties,
    index_path: []const u8,
) !void {
    var entries: ArrayList(IndexEntry) = .empty;
    var lines = splitScalar(u8, report.text.items, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') {
            continue;
        }
        var columns = splitScalar(u8, line, '\t');
        const name: []const u8 = columns.next() orelse continue;
        _ = columns.next(); // the level, from the name again
        _ = columns.next(); // the note
        const published_text: []const u8 = columns.next() orelse continue;
        _ = columns.next(); // the target
        _ = columns.next(); // black's rate
        _ = columns.next(); // white's rate
        const later_text: []const u8 = columns.next() orelse continue;
        _ = columns.next(); // later starts checked
        const twin_text: []const u8 = columns.next() orelse continue;
        var later_starts: ArrayList(u8) = .empty;
        if (!eql(u8, later_text, "-")) {
            var starts = splitScalar(u8, later_text, ',');
            while (starts.next()) |start| {
                try later_starts.append(gpa, try parseInt(u8, start, 10));
            }
        }
        const published: ?goban.ProblemKind = std.meta.stringToEnum(goban.ProblemKind, published_text);
        const has_twin: bool = !eql(u8, twin_text, "-");
        if (published == null and !has_twin) {
            continue;
        }
        try entries.append(gpa, .{
            .name = name,
            .level = levelOf(name),
            .published = published,
            .later_starts = later_starts.items,
            .has_twin = has_twin,
            .difficulty = difficulties.of(name),
        });
    }
    // A family with no measured difficulty gets one from its level's median - the middle of its measured
    // problems, which the few that never settle (counted at the measure's cap) do not pull up as they would an
    // average: it sorts among its level's, not after them.
    const level_count: usize = std.enums.values(goban.ProblemLevel).len;
    var measured_by_level: [level_count]ArrayList(u32) = @splat(.empty);
    defer for (&measured_by_level) |*measured| measured.deinit(gpa);
    for (entries.items) |entry| {
        if (entry.difficulty) |difficulty| {
            try measured_by_level[@backingInt(entry.level)].append(gpa, difficulty);
        }
    }
    var level_medians: [level_count]?u32 = @splat(null);
    for (&measured_by_level, &level_medians) |*measured, *median| {
        if (measured.items.len == 0) {
            continue;
        }
        sortSlice(u32, measured.items, {}, std.sort.asc(u32));
        median.* = measured.items[measured.items.len / 2];
    }
    // A book's problems grow harder with their numbers: one other than Go Game Guru's, unmeasured, is guessed from
    // its place in its book (`bookOf`) - from half its level's median for the first to one and a half for the last.
    var book_names: ArrayList([]const u8) = .empty;
    defer book_names.deinit(gpa);
    var book_last_numbers: ArrayList(u32) = .empty;
    defer book_last_numbers.deinit(gpa);
    for (entries.items) |entry| {
        const book: []const u8 = bookOf(entry.name);
        const number: u32 = numberIn(entry.name);
        const known_index: ?usize = for (book_names.items, 0..) |known, known_index| {
            if (eql(u8, known, book)) {
                break known_index;
            }
        } else null;
        if (known_index) |found| {
            book_last_numbers.items[found] = @max(book_last_numbers.items[found], number);
        } else {
            try book_names.append(gpa, book);
            try book_last_numbers.append(gpa, number);
        }
    }
    for (entries.items) |*entry| {
        const level_index: usize = @backingInt(entry.level);
        const level_median: u32 = level_medians[level_index] orelse continue;
        if (entry.difficulty != null) {
            continue;
        }
        const book: []const u8 = bookOf(entry.name);
        const is_go_game_guru: bool = startsWith(u8, book, "ggg-");
        const last_number: u32 = for (book_names.items, book_last_numbers.items) |known, last| {
            if (eql(u8, known, book)) {
                break last;
            }
        } else 0;
        const place: f32 = if (last_number > 0) float(numberIn(entry.name)) / float(last_number) else 0.5;
        const scale: f32 = if (is_go_game_guru) 1 else 0.5 + place;
        const guessed_difficulty: u32 = @trunc(float(level_median) * scale);
        entry.difficulty = guessed_difficulty;
    }
    sortSlice(IndexEntry, entries.items, {}, IndexEntry.before);
    // The families: the published problems, and one more from each of their later starts - its ladder the rest of
    // the line, a level below (`derivedLevel`), at that level's average difficulty.
    var family_entries: ArrayList(IndexEntry) = .empty;
    defer family_entries.deinit(gpa);
    var interest_path_buffer: [4096]u8 = undefined;
    const interest_path: []const u8 = try bufPrint(&interest_path_buffer, "{s}/interest.tsv", .{
        std.fs.path.dirname(index_path) orelse ".",
    });
    const interest_text: []const u8 = Dir.cwd().readFileAlloc(io, interest_path, gpa, .unlimited) catch "";
    for (entries.items) |entry| {
        if (entry.published == null) {
            continue;
        }
        var published: IndexEntry = entry;
        published.starts = try ladderStarts(gpa, interest_text, &entry);
        try family_entries.append(gpa, published);
        const level: goban.ProblemLevel = derivedLevel(entry.level);
        const level_index: usize = @backingInt(level);
        const level_median: ?u32 = level_medians[level_index] orelse entry.difficulty;
        for (1..published.starts.len) |start_index| {
            var derived: IndexEntry = published;
            derived.starts = published.starts[start_index..];
            derived.level = level;
            derived.difficulty = level_median;
            try family_entries.append(gpa, derived);
        }
    }
    sortSlice(IndexEntry, family_entries.items, {}, IndexEntry.before);

    var index: Io.Writer.Allocating = .init(gpa);
    defer index.deinit();
    const out: *Io.Writer = &index.writer;
    try out.writeAll("//! goban's problems, generated by goban_problems_tool.zig from report.tsv beside this\n" ++
        "//! file: run the converter to change it, not an editor. The families are the published problems with\n" ++
        "//! their levels and the later starts the converter accepted; the lists are every kill and every life\n" ++
        "//! problem's file.\n" ++
        "/// A start of a family's ladder: the moves of the correct line before it, and which of its two\n" ++
        "/// puzzles the test of interest kept - the book's own kind, and the twin.\n" ++
        "pub const Start = struct {\n" ++
        "    moves: u8,\n" ++
        "    own: bool = true,\n" ++
        "    twin: bool = true,\n" ++
        "};\n\n" ++
        "/// One published problem: its file, its level's name, and the later starts the converter\n" ++
        "/// accepted - plain data, so that this file imports nothing (goban.zig turns each into a\n" ++
        "/// `ProblemFamily`).\n" ++
        "pub const Family = struct {\n" ++
        "    name: []const u8 = \"\",\n" ++
        "    sgf: []const u8,\n" ++
        "    level: []const u8,\n" ++
        "    kind: []const u8,\n" ++
        "    starts: []const Start,\n" ++
        "    difficulty: u32 = 0,\n" ++
        "};\n\n" ++
        "/// Every published problem, by level, with the later starts the converter accepted; and one\n" ++
        "/// family more from each later start, a level below.\n" ++
        "pub const families = [_]Family{\n");
    for (family_entries.items) |entry| {
        // Each family over several lines, as zig fmt keeps a literal with a trailing comma: the long names fit.
        try out.print("    .{{\n        .name = \"{s}\",\n", .{entry.name});
        try out.print("        .sgf = @embedFile(\"{s}\"),\n", .{entry.name});
        try out.print("        .level = \"{t}\",\n", .{entry.level});
        try out.print("        .kind = \"{t}\",\n", .{entry.published.?});
        // A start a line, as zig fmt lays such a list out; a puzzle dropped is the one flag written.
        try out.writeAll("        .starts = &.{\n");
        for (entry.starts) |start| {
            try out.print("            .{{ .moves = {d}", .{start.moves});
            if (!start.own) {
                try out.writeAll(", .own = false");
            }
            if (!start.twin) {
                try out.writeAll(", .twin = false");
            }
            try out.writeAll(" },\n");
        }
        try out.writeAll("        },\n");
        try out.print("        .difficulty = {d},\n    }},\n", .{entry.difficulty orelse 0});
    }
    try out.writeAll("};\n\n/// Every kill problem's file: the published, each with its later starts, and the " ++
        "colour-swapped twins\n/// of life problems.\npub const kill_sgfs = [_][]const u8{\n");
    for (entries.items) |entry| {
        const stem: []const u8 = entry.name[0 .. entry.name.len - ".sgf".len];
        if (entry.published == .kill) {
            try out.print("    @embedFile(\"{s}\"),\n", .{entry.name});
            for (entry.later_starts) |start| {
                try out.print("    @embedFile(\"{s}-from-move-{d}.sgf\"),\n", .{ stem, start + 1 });
            }
        }
        if (entry.has_twin) {
            try out.print("    @embedFile(\"{s}-swapped.sgf\"),\n", .{stem});
        }
    }
    try out.writeAll("};\n\n/// Every life problem's file.\npub const life_sgfs = [_][]const u8{\n");
    for (entries.items) |entry| {
        if (entry.published == .live) {
            try out.print("    @embedFile(\"{s}\"),\n", .{entry.name});
        }
    }
    try out.writeAll("};\n");
    try Dir.cwd().writeFile(io, .{ .sub_path = index_path, .data = index.written() });
}

/// A chain of the problem: the stone that stands for it, its first in the board's order, and its size.
const Chain = struct {
    first_stone: Point,
    size: usize,
};

/// The chains of `colour` in `game`'s position, written into `out_buffer`.
fn chainsOf(game: *const Game, colour: Stone, out_buffer: []Chain) []const Chain {
    const position: *const goban.Position = &game.position;
    var chain_count: usize = 0;
    for (0..goban.pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const is_root: bool = position.stones[point] == colour and goban.isRoot(position, point);
        if (!is_root) {
            continue;
        }
        const stones: goban.PointSet = position.group_stones[point];
        out_buffer[chain_count] = .{ .first_stone = @intCast(stones.findFirstSet().?), .size = stones.count() };
        chain_count += 1;
    }
    return out_buffer[0..chain_count];
}

/// What black's search found for a target: its move and rate, and whether the move was one of the book's.
const BlackFirstCheck = struct {
    black_first: SearchResult,
    /// Whether one of the book's moves wins for black often enough, over visits enough
    /// (`ConvertOptions.book_min_visits`).
    book_holds_up: bool,
};

/// The search with black to play for `target` as the target of `setup`, its move compared with `book_moves`. Writes
/// the report line's first part, led by `label`.
fn checkBlackFirst(
    gpa: Allocator,
    out: *Io.Writer,
    label: []const u8,
    setup: *const goban.DiagramSetup,
    target: Point,
    kind: goban.ProblemKind,
    book_points: *const goban.PointSet,
    book_moves: []const Point,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
) !BlackFirstCheck {
    const board_size: u8 = setup.board_size;
    const problem: goban.Problem = .{
        .setup = setup.*,
        .target = target,
        .kind = kind,
        .book_points = book_points.*,
    };
    goban.startProblem(game, &problem, options.problem_settings);
    const black_tree: SearchTree = try search(gpa, game, options, node_buffer);
    const black_first: SearchResult = chosenMove(&black_tree);
    var agrees_with_book: bool = false;
    for (book_moves) |book_move| {
        agrees_with_book = agrees_with_book or black_first.move == book_move;
    }
    // The book holds up when one of its moves wins often enough, over visits enough for its rate to mean something.
    var book_holds_up: bool = false;
    for (book_moves) |book_move| {
        const book_statistics: ChildStatistics = childStatistics(&black_tree, book_move);
        const visited_enough: bool = book_statistics.visits >= options.book_min_visits;
        const wins_enough: bool = book_statistics.win_rate >= options.solvable_rate;
        book_holds_up = book_holds_up or (visited_enough and wins_enough);
    }
    try out.print("    {s} ", .{label});
    try writeSgfPoint(out, board_size, target);
    try out.writeAll(": black plays ");
    if (black_first.move) |move| {
        try writeSgfPoint(out, board_size, move);
    } else {
        try out.writeAll("nothing");
    }
    const holds_note: []const u8 = if (book_holds_up) " - the book's holds up" else "";
    const agreement: []const u8 = if (agrees_with_book) " - the book's" else holds_note;
    try out.print(", wins {d:.0}%{s}", .{ 100 * black_first.win_rate, agreement });
    for (book_moves) |book_move| {
        if (book_move == black_first.move) {
            continue;
        }
        const book_statistics: ChildStatistics = childStatistics(&black_tree, book_move);
        try out.writeAll("; the book's ");
        try writeSgfPoint(out, board_size, book_move);
        try out.print(" {d} visits, wins {d:.0}%", .{ book_statistics.visits, 100 * book_statistics.win_rate });
    }
    try out.writeAll("\n");
    return .{ .black_first = black_first, .book_holds_up = book_holds_up };
}

/// The search with white to play first for `target` as the target of `setup`: how often white, the computer, wins -
/// saving a kill problem's target, capturing a life problem's. Writes one report line.
fn checkWhiteFirst(
    gpa: Allocator,
    out: *Io.Writer,
    setup: *const goban.DiagramSetup,
    target: Point,
    kind: goban.ProblemKind,
    book_points: *const goban.PointSet,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
) !SearchResult {
    const problem: goban.Problem = .{
        .setup = setup.*,
        .target = target,
        .kind = kind,
        .book_points = book_points.*,
    };
    goban.startProblem(game, &problem, options.problem_settings);
    game.record.setup_to_play = .white;
    goban.replayTo(game, 0);
    const white_tree: SearchTree = try search(gpa, game, options, node_buffer);
    const white_first: SearchResult = chosenMove(&white_tree);
    try out.print("      white first wins {d:.0}%\n", .{100 * white_first.win_rate});
    return white_first;
}

/// What trying a target found: black's search, and white's moving first.
const TargetCheck = struct {
    black_first: SearchResult,
    white_first: SearchResult,
    book_holds_up: bool,
};

/// Both checks of `target` as the target of `setup` (the file's lesson).
fn checkTarget(
    gpa: Allocator,
    out: *Io.Writer,
    label: []const u8,
    setup: *const goban.DiagramSetup,
    target: Point,
    kind: goban.ProblemKind,
    book_points: *const goban.PointSet,
    book_moves: []const Point,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
) !TargetCheck {
    const black: BlackFirstCheck = try checkBlackFirst(
        gpa,
        out,
        label,
        setup,
        target,
        kind,
        book_points,
        book_moves,
        options,
        game,
        node_buffer,
    );
    const white_first: SearchResult = try checkWhiteFirst(
        gpa,
        out,
        setup,
        target,
        kind,
        book_points,
        options,
        game,
        node_buffer,
    );
    const check: TargetCheck = .{
        .black_first = black.black_first,
        .white_first = white_first,
        .book_holds_up = black.book_holds_up,
    };
    return check;
}

/// Whether a stone of `chain`'s is within `reach` of one of `moves` - the larger of the row and column steps.
fn chainIsNear(game: *const Game, chain: Chain, moves: []const Point, reach: u8) bool {
    const position: *const goban.Position = &game.position;
    const board_size: u8 = position.board_size;
    const root: Point = goban.findRoot(position, chain.first_stone);
    var members: goban.PointSet.Iterator(.{}) = position.group_stones[root].iterator(.{});
    while (members.next()) |member_index| {
        const member: Point = @intCast(member_index);
        for (moves) |move| {
            const row_difference: i32 = @as(i32, goban.rowOf(board_size, member)) - goban.rowOf(board_size, move);
            const col_difference: i32 = @as(i32, goban.colOf(board_size, member)) - goban.colOf(board_size, move);
            const row_steps: u32 = @abs(row_difference);
            const col_steps: u32 = @abs(col_difference);
            if (@max(row_steps, col_steps) <= reach) {
                return true;
            }
        }
    }
    return false;
}

/// A target found for a setup: its chain, and what checking it found.
const TargetChoice = struct {
    chain: Chain,
    check: TargetCheck,
};

/// Tries the chains of `setup` of the target's colour for `kind` - white to kill, black to save - near `near_moves`,
/// the book's correct line and first moves (the file's lesson): black's search for each; then, from the largest down
/// among those whose book holds up in the search (`ConvertOptions.book_min_visits`), white's moving first, until one is
/// unsettled - white winning, which saves a kill problem's target or captures a life problem's. That one is the
/// target; null when none is.
fn findTarget(
    gpa: Allocator,
    out: *Io.Writer,
    setup: *const goban.DiagramSetup,
    kind: goban.ProblemKind,
    book_points: *const goban.PointSet,
    book_moves: []const Point,
    near_moves: []const Point,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
) !?TargetChoice {
    goban.startGameFromDiagram(game, setup);
    const target_colour: Stone = if (kind == .kill) .white else .black;
    var chain_buffer: [board_limits.max_points]Chain = undefined;
    const chains: []const Chain = chainsOf(game, target_colour, &chain_buffer);
    var agreeing_buffer: [board_limits.max_points]TargetChoice = undefined;
    var agreeing_count: usize = 0;
    for (chains) |chain| {
        goban.startGameFromDiagram(game, setup);
        if (!chainIsNear(game, chain, near_moves, options.candidate_reach)) {
            continue;
        }
        var label_buffer: [64]u8 = undefined;
        const label: []const u8 = try bufPrint(&label_buffer, "the chain of {d} at", .{chain.size});
        const black: BlackFirstCheck = try checkBlackFirst(
            gpa,
            out,
            label,
            setup,
            chain.first_stone,
            kind,
            book_points,
            book_moves,
            options,
            game,
            node_buffer,
        );
        if (black.book_holds_up) {
            agreeing_buffer[agreeing_count] = .{
                .chain = chain,
                .check = .{ .black_first = black.black_first, .white_first = undefined, .book_holds_up = true },
            };
            agreeing_count += 1;
        }
    }
    const agreeing: []TargetChoice = agreeing_buffer[0..agreeing_count];
    const BySize = struct {
        fn larger(_: void, left: TargetChoice, right: TargetChoice) bool {
            return left.chain.size > right.chain.size;
        }
    };
    sortSlice(TargetChoice, agreeing, {}, BySize.larger);
    for (agreeing) |*choice| {
        try out.writeAll("    the chain at ");
        try writeSgfPoint(out, setup.board_size, choice.chain.first_stone);
        try out.writeAll(", the largest agreeing left:\n");
        choice.check.white_first = try checkWhiteFirst(
            gpa,
            out,
            setup,
            choice.chain.first_stone,
            kind,
            book_points,
            options,
            game,
            node_buffer,
        );
        if (choice.check.white_first.win_rate >= options.unsettled_rate) {
            return choice.*;
        }
    }
    return null;
}

/// Writes a problem made from another - a later start, a twin - as a fresh SGF file: its stones, its target and a
/// comment saying where it comes from, with no solution tree. The mark follows the target's colour: a triangle on a
/// white target, black to kill it; a square on a black one, black to save it (`goban.readProblem`).
fn writeFreshProblem(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    out_path: []const u8,
    setup: *const goban.DiagramSetup,
    target: Point,
    comment: []const u8,
) !void {
    const board_size: u8 = setup.board_size;
    var text: Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    const writer: *Io.Writer = &text.writer;
    try writer.print("(;GM[1]FF[4]CA[UTF-8]SZ[{d}]", .{board_size});
    const stone_lists = [_]struct { identifier: []const u8, stone: Stone }{
        .{ .identifier = "AB", .stone = .black },
        .{ .identifier = "AW", .stone = .white },
    };
    for (stone_lists) |list| {
        try writer.writeAll(list.identifier);
        for (setup.stones[0..goban.pointCount(board_size)], 0..) |stone, point_index| {
            if (stone == list.stone) {
                try writer.writeAll("[");
                try writeSgfPoint(writer, board_size, @intCast(point_index));
                try writer.writeAll("]");
            }
        }
    }
    const mark: []const u8 = if (setup.stones[target] == .white) "TR" else "SQ";
    try writer.print("{s}[", .{mark});
    try writeSgfPoint(writer, board_size, target);
    try writer.print("]C[{s}])\n", .{comment});
    try Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = text.written() });
    try out.print("    written to {s}\n", .{out_path});
}

/// Writes the problem as published with its target marked - `TR`, a triangle, for a kill problem's, `SQ`, a square,
/// for a life problem's - after the root node's last property, the rest of the file as it was.
fn writeMarkedProblem(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    text: []const u8,
    root: *const SgfRoot,
    mark: []const u8,
    target: Point,
    options: ConvertOptions,
    name: []const u8,
) !void {
    const board_size: u8 = root.setup.board_size;
    var marked: ArrayList(u8) = .empty;
    defer marked.deinit(gpa);
    try marked.appendSlice(gpa, text[0..root.end_index]);
    try marked.appendSlice(gpa, mark);
    try marked.appendSlice(gpa, "[");
    try marked.append(gpa, 'a' + goban.colOf(board_size, target));
    try marked.append(gpa, 'a' + goban.rowOf(board_size, target));
    try marked.appendSlice(gpa, "]");
    try marked.appendSlice(gpa, text[root.end_index..]);
    var path_buffer: [4096]u8 = undefined;
    const out_path: []const u8 = try bufPrint(&path_buffer, "{s}/{s}", .{ options.out_dir, name });
    try Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = marked.items });
    try out.print("    written to {s}\n", .{out_path});
}

/// `text` with its root node's triangles and squares (`TR`, `SQ`, every value of each) taken out: a published
/// diagram's illustration, not a problem's mark. `root_end` is where the root node ends (`SgfRoot.end_index`).
fn withoutRootMarks(gpa: Allocator, text: []const u8, root_end: usize) ![]const u8 {
    var unmarked: ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        const rest: []const u8 = text[index..];
        const starts_mark: bool = startsWith(u8, rest, "TR[") or startsWith(u8, rest, "SQ[");
        const is_property_start: bool = index == 0 or !std.ascii.isUpper(text[index - 1]);
        if (index < root_end and starts_mark and is_property_start) {
            // The identifier, then each value - whitespace may part them.
            index += 2;
            while (index < text.len and text[index] == '[') {
                const value_end: usize = indexOfScalarPos(u8, text, index, ']') orelse text.len;
                index = value_end + 1;
                while (index < text.len and std.ascii.isWhitespace(text[index]) and index + 1 < text.len and
                    indexOfScalar(u8, " \t\r\n[", text[index + 1]) != null)
                {
                    index += 1;
                }
            }
            continue;
        }
        try unmarked.append(gpa, text[index]);
        index += 1;
    }
    return unmarked.items;
}

/// What converting a problem reads of it once, for each reading tried (`tryKillReading`, `tryLifeReading`): its text,
/// root and names, the points its book plays, its correct first moves, the moves a target must be near, and its
/// correct line.
const ProblemInputs = struct {
    text: []const u8,
    root: SgfRoot,
    name: []const u8,
    stem: []const u8,
    book_points: goban.PointSet,
    correct_moves: []const Point,
    near_moves: []const Point,
    line: []const Point,
};

/// The kind a problem's comments say (the file's lesson): whose fate they talk about - each colour's name ("white",
/// "white's") followed within five words by a word of life or death (dead, dies, die, lives, live, alive, living,
/// captured, killed) counts for that colour; white's fate more often is a kill problem, black's a life problem. Null
/// when the counts are equal - most comments say only "Correct".
fn commentsKind(text: []const u8) ?goban.ProblemKind {
    const fate_words = [_][]const u8{ "dead", "dies", "die", "lives", "live", "alive", "living", "captured", "killed" };
    var white_fates: u32 = 0;
    var black_fates: u32 = 0;
    var search_from: usize = 0;
    while (indexOfPos(u8, text, search_from, "C[")) |property_start| {
        search_from = property_start + 2;
        const is_comment: bool = property_start == 0 or !std.ascii.isUpper(text[property_start - 1]);
        if (!is_comment) {
            continue;
        }
        // The comment's words, lower case, up to its closing bracket - an escaped one is the comment's own.
        var words_buffer: [256][]const u8 = undefined;
        var word_count: usize = 0;
        var lower_buffer: [4096]u8 = undefined;
        var lower_length: usize = 0;
        var index: usize = property_start + 2;
        var escaped: bool = false;
        while (index < text.len and lower_length < lower_buffer.len) : (index += 1) {
            const character: u8 = text[index];
            if (!escaped and character == ']') {
                break;
            }
            escaped = !escaped and character == '\\';
            lower_buffer[lower_length] = std.ascii.toLower(character);
            lower_length += 1;
        }
        search_from = index;
        var words = std.mem.tokenizeAny(u8, lower_buffer[0..lower_length], " \t\r\n.,;:!?()\"");
        while (words.next()) |word| {
            if (word_count < words_buffer.len) {
                words_buffer[word_count] = word;
                word_count += 1;
            }
        }
        const comment_words: []const []const u8 = words_buffer[0..word_count];
        for (comment_words, 0..) |word, word_index| {
            const is_white: bool = eql(u8, word, "white") or eql(u8, word, "white's");
            const is_black: bool = eql(u8, word, "black") or eql(u8, word, "black's");
            if (!is_white and !is_black) {
                continue;
            }
            const window_end: usize = @min(word_index + 6, comment_words.len);
            const has_fate: bool = for (comment_words[word_index + 1 .. window_end]) |following| {
                const is_fate: bool = for (fate_words) |fate_word| {
                    if (eql(u8, following, fate_word)) {
                        break true;
                    }
                } else false;
                if (is_fate) {
                    break true;
                }
            } else false;
            if (has_fate) {
                white_fates += @intFromBool(is_white);
                black_fates += @intFromBool(is_black);
            }
        }
    }
    if (white_fates == black_fates) {
        return null;
    }
    return if (white_fates > black_fates) .kill else .live;
}

/// How far `colour`'s stones in `setup` lie from their centre: the root of the mean squared distance.
fn stoneSpread(setup: *const goban.DiagramSetup, colour: goban.Stone) f32 {
    var count: f32 = 0;
    var row_sum: f32 = 0;
    var col_sum: f32 = 0;
    const board_size: u8 = setup.board_size;
    for (0..goban.pointCount(board_size)) |point_index| {
        if (setup.stones[point_index] != colour) {
            continue;
        }
        count += 1;
        row_sum += float(goban.rowOf(board_size, @intCast(point_index)));
        col_sum += float(goban.colOf(board_size, @intCast(point_index)));
    }
    if (count == 0) {
        return 0;
    }
    const row_mean: f32 = row_sum / count;
    const col_mean: f32 = col_sum / count;
    var squared_sum: f32 = 0;
    for (0..goban.pointCount(board_size)) |point_index| {
        if (setup.stones[point_index] != colour) {
            continue;
        }
        const row_offset: f32 = float(goban.rowOf(board_size, @intCast(point_index))) - row_mean;
        const col_offset: f32 = float(goban.colOf(board_size, @intCast(point_index))) - col_mean;
        squared_sum += row_offset * row_offset + col_offset * col_offset;
    }
    return @sqrt(squared_sum / count);
}

/// The kind a problem's stones suggest (the file's lesson): the defender is the colour whose stones do not face the
/// frame's open sides (`goban.outsideOwner`) and the more grouped one (`stoneSpread`) - the group inside the wall.
/// Null unless the two agree: on the published problems whose comments decide, they agree on four in five and are
/// right on nine in ten of those; where they disagree they are a coin's toss.
fn geometryKind(setup: *const goban.DiagramSetup) ?goban.ProblemKind {
    const outside: goban.Stone = goban.outsideOwner(setup, .none);
    if (outside == .none) {
        return null;
    }
    const black_spread: f32 = stoneSpread(setup, .black);
    const white_spread: f32 = stoneSpread(setup, .white);
    if (black_spread == white_spread) {
        return null;
    }
    const grouped_colour: goban.Stone = if (black_spread < white_spread) .black else .white;
    const defender: goban.Stone = outside.opponent();
    if (grouped_colour != defender) {
        return null;
    }
    return if (defender == .black) .live else .kill;
}

/// A problem's kind before any search (the file's lesson): its comments', when they say; else its stones', when the
/// geometry's two signs agree; else none.
fn kindHint(text: []const u8, setup: *const goban.DiagramSetup) ?KindHint {
    if (commentsKind(text)) |kind| {
        return .{ .kind = kind, .source = .comments };
    }
    if (geometryKind(setup)) |kind| {
        return .{ .kind = kind, .source = .geometry };
    }
    return null;
}

/// The problem read as published as a kill problem (the file's lesson): a white chain near the book's moves whose
/// book holds up in the search, black able to kill it and white, moving first, to save it; marked with a triangle,
/// with its later starts along the correct line. Whether it was.
fn tryKillReading(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    inputs: *const ProblemInputs,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
    outcome: *ProblemOutcome,
) !bool {
    const text: []const u8 = inputs.text;
    const root: SgfRoot = inputs.root;
    const name: []const u8 = inputs.name;
    const stem: []const u8 = inputs.stem;
    const board_size: u8 = root.setup.board_size;
    const book_points: goban.PointSet = inputs.book_points;
    const correct_moves: []const Point = inputs.correct_moves;
    const near_moves: []const Point = inputs.near_moves;
    const line: []const Point = inputs.line;
    var path_buffer: [4096]u8 = undefined;
    const setup: *const goban.DiagramSetup = &root.setup;
    const maybe_choice: ?TargetChoice = try findTarget(
        gpa,
        out,
        setup,
        .kill,
        &book_points,
        correct_moves,
        near_moves,
        options,
        game,
        node_buffer,
    );
    if (maybe_choice) |choice| {
        const target: Point = choice.chain.first_stone;
        outcome.published = .kill;
        outcome.target = target;
        outcome.black_rate = choice.check.black_first.win_rate;
        outcome.white_first_rate = choice.check.white_first.win_rate;
        try out.writeAll("  a kill problem, target ");
        try writeSgfPoint(out, board_size, target);
        // Its life twin: the same position, colours swapped - valid since white first saves it; its vital point is
        // the kill's own when white's saving move is one of the book's.
        var twin_shares_vital_point: bool = false;
        for (correct_moves) |correct_move| {
            twin_shares_vital_point = twin_shares_vital_point or choice.check.white_first.move == correct_move;
        }
        const vital_note: []const u8 = if (twin_shares_vital_point) "the kill's own" else "another point";
        try out.print("; its life twin's first move is {s}\n", .{vital_note});
        try writeMarkedProblem(gpa, io, out, text, &root, "TR", target, options, name);

        // Later starts: after each black move and white's answer along the correct line, black to play again.
        const problem: goban.Problem = .{ .setup = root.setup, .target = target, .book_points = book_points };
        var moves_before: usize = 2;
        while (moves_before < line.len and outcome.later_checked < options.max_later_starts) : (moves_before += 2) {
            goban.startProblem(game, &problem, options.problem_settings);
            for (line[0..moves_before]) |move| {
                _ = goban.playMove(game, move);
            }
            if (game.position.winner != null or game.position.stones[target] != .white) {
                break;
            }
            const later_setup: goban.DiagramSetup = .{
                .board_size = board_size,
                .stones = goban.stonesInRegion(&game.position),
                .player_to_move = .black,
            };
            var label_buffer: [64]u8 = undefined;
            const label: []const u8 = try bufPrint(&label_buffer, "from move {d}, target", .{moves_before + 1});
            const book_move = [_]Point{line[moves_before]};
            const check: TargetCheck = try checkTarget(
                gpa,
                out,
                label,
                &later_setup,
                target,
                .kill,
                &book_points,
                &book_move,
                options,
                game,
                node_buffer,
            );
            const unsettled: bool = check.white_first.win_rate >= options.unsettled_rate;
            outcome.later_checked += 1;
            if (check.book_holds_up and unsettled) {
                outcome.later_starts[outcome.later_count] = @intCast(moves_before);
                outcome.later_count += 1;
                const later_path: []const u8 = try bufPrint(&path_buffer, "{s}/{s}-from-move-{d}.sgf", .{
                    options.out_dir,
                    stem,
                    moves_before + 1,
                });
                var comment_buffer: [128]u8 = undefined;
                const comment: []const u8 = try bufPrint(&comment_buffer, "{s} from move {d}", .{
                    stem,
                    moves_before + 1,
                });
                try writeFreshProblem(gpa, io, out, later_path, &later_setup, target, comment);
            } else {
                // The first start rejected ends the ladder: its steps stay one after another, none skipped.
                const rejection: []const u8 = "the book's move not the search's, or already decided";
                try out.print("    not a problem from there: {s}; the ladder ends\n", .{rejection});
                break;
            }
        }
        return true;
    }
    return false;
}

/// The problem read as published as a life problem (the file's lesson): a black chain to save, marked with a square;
/// and its colour-swapped twin read as a kill problem. Whether the life reading was accepted.
fn tryLifeReading(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    inputs: *const ProblemInputs,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
    outcome: *ProblemOutcome,
) !bool {
    const text: []const u8 = inputs.text;
    const root: SgfRoot = inputs.root;
    const name: []const u8 = inputs.name;
    const stem: []const u8 = inputs.stem;
    const board_size: u8 = root.setup.board_size;
    const book_points: goban.PointSet = inputs.book_points;
    const correct_moves: []const Point = inputs.correct_moves;
    const near_moves: []const Point = inputs.near_moves;
    var path_buffer: [4096]u8 = undefined;
    const setup: *const goban.DiagramSetup = &root.setup;
    try out.writeAll("  as a life problem:\n");
    const life_choice: ?TargetChoice = try findTarget(
        gpa,
        out,
        setup,
        .live,
        &book_points,
        correct_moves,
        near_moves,
        options,
        game,
        node_buffer,
    );
    if (life_choice) |choice| {
        const target: Point = choice.chain.first_stone;
        outcome.published = .live;
        outcome.target = target;
        outcome.black_rate = choice.check.black_first.win_rate;
        outcome.white_first_rate = choice.check.white_first.win_rate;
        try out.writeAll("  a life problem, target ");
        try writeSgfPoint(out, board_size, target);
        try out.writeAll("\n");
        try writeMarkedProblem(gpa, io, out, text, &root, "SQ", target, options, name);
    } else {
        try out.writeAll("  no life problem either\n");
    }

    // Its colour-swapped twin as a kill problem, its vital point the book's first move.
    try out.writeAll("  the colour-swapped twin:\n");
    const swapped: goban.DiagramSetup = goban.swapColours(&root.setup);
    const twin_choice: ?TargetChoice = try findTarget(
        gpa,
        out,
        &swapped,
        .kill,
        &book_points,
        correct_moves,
        near_moves,
        options,
        game,
        node_buffer,
    );
    if (twin_choice) |choice| {
        const twin_path: []const u8 = try bufPrint(&path_buffer, "{s}/{s}-swapped.sgf", .{ options.out_dir, stem });
        var comment_buffer: [128]u8 = undefined;
        const comment: []const u8 = try bufPrint(&comment_buffer, "{s}, its colours swapped", .{stem});
        try out.writeAll("  a kill problem in its twin, target ");
        try writeSgfPoint(out, board_size, choice.chain.first_stone);
        try out.writeAll("\n");
        try writeFreshProblem(gpa, io, out, twin_path, &swapped, choice.chain.first_stone, comment);
        outcome.twin_target = choice.chain.first_stone;
    } else {
        try out.writeAll("  nor in its twin: not written\n");
    }
    return life_choice != null;
}

/// Converts one problem (the file's lesson): a kill problem found in it as published, and the later starts along its
/// correct line; or, when it is a life problem, the kill problem of its colour-swapped twin. Writes each one found and
/// reports all that was tried.
fn convertProblem(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
    outcome: *ProblemOutcome,
) !void {
    const name: []const u8 = basename(path);
    const stem: []const u8 = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
    var text: []const u8 = try Dir.cwd().readFileAlloc(io, path, gpa, options.read_limit);
    var root: SgfRoot = goban.readSgfRoot(text) catch |err| {
        try out.print("{s}: not read - {t}\n", .{ name, err });
        outcome.note = .unreadable;
        return;
    };
    if (root.triangle_count > 0 or root.square_count > 0) {
        // A published diagram's own marks illustrate it; the problem's mark is the converter's to make.
        try out.print("{s}: its own marks set aside\n", .{name});
        text = try withoutRootMarks(gpa, text, root.end_index);
        root = try goban.readSgfRoot(text);
    }
    const board_size: u8 = root.setup.board_size;
    outcome.board_size = board_size;
    // The points the book plays, which every search's region takes in, so that the book's moves can be played.
    var book: goban.SolutionTree = undefined;
    try goban.readSolutionTree(text, &root, &book);
    var book_points: goban.PointSet = .empty;
    for (book.nodes[0..book.node_count]) |node| {
        book_points.set(node.move);
    }
    var first_move_buffer: [board_limits.max_points]SgfFirstMove = undefined;
    const first_moves: []const SgfFirstMove = try goban.readSgfFirstMoves(text, &root, &first_move_buffer);
    var correct_buffer: [board_limits.max_points]Point = undefined;
    var correct_count: usize = 0;
    try out.print("{s}: the book's correct first moves:", .{name});
    for (first_moves) |first_move| {
        if (first_move.leads_to_correct) {
            correct_buffer[correct_count] = first_move.point;
            correct_count += 1;
            try out.writeAll(" ");
            try writeSgfPoint(out, board_size, first_move.point);
        }
    }
    try out.writeAll("\n");
    const correct_moves: []const Point = correct_buffer[0..correct_count];
    // The moves a target must be near: the correct first moves, and every move of the correct line.
    var line_buffer: [goban.record_limits.max_moves]Point = undefined;
    const line: []const Point = try goban.readSgfCorrectLine(text, &root, &line_buffer);
    var near_buffer: [board_limits.max_points + goban.record_limits.max_moves]Point = undefined;
    @memcpy(near_buffer[0..correct_moves.len], correct_moves);
    @memcpy(near_buffer[correct_moves.len..][0..line.len], line);
    const near_moves: []const Point = near_buffer[0 .. correct_moves.len + line.len];

    const inputs: ProblemInputs = .{
        .text = text,
        .root = root,
        .name = name,
        .stem = stem,
        .book_points = book_points,
        .correct_moves = correct_moves,
        .near_moves = near_moves,
        .line = line,
    };
    // The readings in the order the hint gives (`kindHint`): a hint from the comments is the only reading tried, one
    // from the stones' geometry the first; with none, kill first, then life.
    const hint: ?KindHint = kindHint(text, &root.setup);
    outcome.hint = hint;
    if (hint) |known| {
        try out.print("  the hint: {t}, from the {t}\n", .{ known.kind, known.source });
    }
    const life_first: bool = hint != null and hint.?.kind == .live;
    const hinted_only: bool = hint != null and hint.?.source == .comments;
    if (life_first) {
        if (try tryLifeReading(gpa, io, out, &inputs, options, game, node_buffer, outcome) or hinted_only) {
            return;
        }
        _ = try tryKillReading(gpa, io, out, &inputs, options, game, node_buffer, outcome);
        return;
    }
    if (try tryKillReading(gpa, io, out, &inputs, options, game, node_buffer, outcome) or hinted_only) {
        return;
    }
    _ = try tryLifeReading(gpa, io, out, &inputs, options, game, node_buffer, outcome);
}

/// The problem's file in the output directory, read, or null when there is none.
fn readOutput(
    gpa: Allocator,
    io: Io,
    options: ConvertOptions,
    name: []const u8,
) !?[]const u8 {
    var path_buffer: [4096]u8 = undefined;
    const path: []const u8 = try bufPrint(&path_buffer, "{s}/{s}", .{ options.out_dir, name });
    return Dir.cwd().readFileAlloc(io, path, gpa, options.read_limit) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// The outcome of the problem at `path` as the files written for it before say (`ConvertOptions.adopts`): its
/// published file's mark, its later starts' files, its twin's - or null when none was written, the problem not yet
/// converted or rejected.
fn adoptProblem(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    options: ConvertOptions,
) !?ProblemOutcome {
    const name: []const u8 = basename(path);
    const stem: []const u8 = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.') orelse name.len];
    var outcome: ProblemOutcome = .{ .note = .adopted };
    if (try readOutput(gpa, io, options, name)) |text| {
        const root: SgfRoot = try goban.readSgfRoot(text);
        outcome.board_size = root.setup.board_size;
        if (root.triangle_count == 1) {
            outcome.published = .kill;
            outcome.target = root.triangles[0];
        } else if (root.square_count == 1) {
            outcome.published = .live;
            outcome.target = root.squares[0];
        }
    }
    var moves_before: u8 = 2;
    while (moves_before < 2 * ProblemOutcome.max_later_starts) : (moves_before += 2) {
        var later_name_buffer: [256]u8 = undefined;
        const later_name: []const u8 = try bufPrint(&later_name_buffer, "{s}-from-move-{d}.sgf", .{
            stem,
            moves_before + 1,
        });
        if (try readOutput(gpa, io, options, later_name) != null) {
            outcome.later_starts[outcome.later_count] = moves_before;
            outcome.later_count += 1;
            outcome.later_checked += 1;
        }
    }
    var twin_name_buffer: [256]u8 = undefined;
    const twin_name: []const u8 = try bufPrint(&twin_name_buffer, "{s}-swapped.sgf", .{stem});
    if (try readOutput(gpa, io, options, twin_name)) |twin_text| {
        const twin_root: SgfRoot = try goban.readSgfRoot(twin_text);
        if (twin_root.triangle_count == 1) {
            outcome.twin_target = twin_root.triangles[0];
        }
    }
    if (outcome.published == null and outcome.twin_target == null) {
        return null;
    }
    return outcome;
}

/// The obvious moves of a puzzle's position (the file's lesson): what a player tries before reading anything - the
/// fighting move (`goban.fightingMove`, the target's liberties), every move that captures stones, and every move
/// that saves the player's own stones from atari by extending them, the group joined having more than one liberty
/// after it.
fn obviousMoves(position: *const goban.Position) goban.PointSet {
    var obvious: goban.PointSet = .empty;
    if (goban.fightingMove(position, null)) |fighting_move| {
        obvious.set(fighting_move);
    }
    const board_size: u8 = position.board_size;
    const mover: Stone = position.player_to_move;
    for (0..goban.pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        if (goban.checkMove(position, point) != .legal) {
            continue;
        }
        var after: goban.Position = position.*;
        const report: goban.MoveReport = goban.placeStone(&after, point);
        const captures: bool = report.captured_count > 0;
        // An escape: a neighbouring group of the mover's in atari before, joined into one with more liberties.
        var escapes: bool = false;
        var neighbour_buffer: [goban.board_limits.max_neighbors]Point = undefined;
        for (goban.neighborsOf(board_size, point, &neighbour_buffer)) |neighbour| {
            if (position.stones[neighbour] != mover) {
                continue;
            }
            const root_before: Point = goban.findRoot(position, neighbour);
            const was_in_atari: bool = position.group_liberties[root_before].count() == 1;
            const root_after: Point = goban.findRoot(&after, point);
            const has_liberties_now: bool = after.group_liberties[root_after].count() > 1;
            escapes = escapes or (was_in_atari and has_liberties_now);
        }
        if (captures or escapes) {
            obvious.set(point);
        }
    }
    return obvious;
}

/// How interesting a puzzle is (the file's lesson): a puzzle is a choice, and a choice an obvious move makes
/// (`obviousMoves`), or one that many moves make, asks nothing. One search of the puzzle's position, the player to
/// move, measures it.
const PuzzleInterest = struct {
    /// The best of the obvious moves (`obviousMoves`) and its win rate (0 when none was visited often enough to tell).
    obvious_move: ?Point,
    obvious_rate: f32,
    /// The first moves that win clearly - each over at least `ConvertOptions.check_min_visits` visits, at least
    /// `ConvertOptions.clear_rate` of its playouts. A rate near a half means the search is unsure, not that the move
    /// wins.
    clear_count: u32,
    /// The best first move - of those visited often enough to tell - and its win rate.
    best_move: ?Point = null,
    best_rate: f32,

    /// Whether the puzzle asks nothing: the obvious move wins it clearly, or `options.max_clear_moves` moves or more
    /// do.
    fn isTrivial(interest: PuzzleInterest, options: ConvertOptions) bool {
        const obvious_wins: bool = interest.obvious_rate >= options.clear_rate;
        const many_win: bool = interest.clear_count >= options.max_clear_moves;
        return obvious_wins or many_win;
    }
};

/// The interest of the puzzle `game` holds (`PuzzleInterest`): one search of `options.check_iterations`.
fn measureInterest(
    gpa: Allocator,
    game: *Game,
    options: ConvertOptions,
    node_buffer: []SearchNode,
) !PuzzleInterest {
    var check_options: ConvertOptions = options;
    check_options.iterations = options.check_iterations;
    const tree: SearchTree = try search(gpa, game, check_options, node_buffer);
    const obvious: goban.PointSet = obviousMoves(&game.position);
    var interest: PuzzleInterest = .{
        .obvious_move = null,
        .obvious_rate = 0,
        .clear_count = 0,
        .best_rate = 0,
    };
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const child: *const SearchNode = &tree.nodes[child_index];
        const visited_enough: bool = child.visits >= options.check_min_visits;
        const rate: f32 = if (visited_enough) child.winRate() else 0;
        interest.clear_count += @intFromBool(rate >= options.clear_rate);
        if (rate > interest.best_rate) {
            interest.best_rate = rate;
            interest.best_move = child.move;
        }
        if (obvious.isSet(child.move) and rate >= interest.obvious_rate) {
            interest.obvious_move = child.move;
            interest.obvious_rate = rate;
        }
    }
    return interest;
}

/// Measures how interesting each puzzle of the problem at `path` is (`measureInterest`): every start along its
/// correct line - the problem itself, then each second move while black has a move left - in the book's own kind and
/// as the twin. Each verdict is printed and written to `verdicts`, a line a puzzle: the problem's name, the start,
/// `own` or `twin`, the puzzle's kind, `kept`, `trivial` or `unclear`, the best move's win rate, the best obvious
/// move's, and the count of moves winning clearly (`interest.tsv`, read by the index). With
/// `options.interest_out_dir`, each puzzle kept is written there as an SGF file of its own.
fn printInterest(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    verdicts: *Io.Writer,
    path: []const u8,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
) !void {
    const text: []const u8 = try Dir.cwd().readFileAlloc(io, path, gpa, options.read_limit);
    const base: goban.Problem = try goban.readProblem(text);
    const root: SgfRoot = try goban.readSgfRoot(text);
    var tree: goban.SolutionTree = undefined;
    try goban.readSolutionTree(text, &root, &tree);
    var line_buffer: [goban.record_limits.max_moves]Point = undefined;
    const line: []const Point = try goban.readSgfCorrectLine(text, &root, &line_buffer);
    const board_size: u8 = base.setup.board_size;
    const scratch: *Game = try gpa.create(Game);
    const name: []const u8 = basename(path);
    const stem: []const u8 = name[0 .. name.len - ".sgf".len];
    var start_count: usize = 0;
    while (start_count < line.len) : (start_count += 2) {
        const start_moves: u8 = @intCast(start_count);
        for ([_]bool{ false, true }) |is_twin| {
            const step: goban.PuzzleStep = .{ .start_moves = start_moves, .is_twin = is_twin };
            const puzzle: goban.Puzzle = goban.puzzleAt(&base, &tree, line, step, scratch);
            goban.startProblem(game, &puzzle.problem, options.problem_settings);
            const interest: PuzzleInterest = try measureInterest(gpa, game, options, node_buffer);
            const obvious: Point = interest.obvious_move orelse 0;
            // A twin has no book: the search's judgement is all there is, so it needs a clear winner too.
            const is_trivial: bool = interest.isTrivial(options);
            const is_unclear: bool = is_twin and interest.best_rate < options.clear_rate;
            const verdict: []const u8 = if (is_trivial) "trivial" else if (is_unclear) "unclear" else "kept";
            try verdicts.print("{s}\t{d}\t{s}\t{t}\t{s}\t{d:.2}\t{d:.2}\t{d}\n", .{
                name,
                start_moves,
                if (is_twin) "twin" else "own",
                puzzle.problem.kind,
                verdict,
                interest.best_rate,
                interest.obvious_rate,
                interest.clear_count,
            });
            if (options.interest_out_dir) |out_dir| {
                if (!is_trivial and !is_unclear) {
                    var path_buffer: [4096]u8 = undefined;
                    const orientation: []const u8 = if (is_twin) "twin" else "own";
                    const puzzle_path: []const u8 = try bufPrint(&path_buffer, "{s}/{s}-after-{d}-{s}.sgf", .{
                        out_dir,
                        stem,
                        start_moves,
                        orientation,
                    });
                    var comment_buffer: [128]u8 = undefined;
                    const comment: []const u8 = try bufPrint(&comment_buffer, "{s} after {d} moves, {s}: {t}", .{
                        stem,
                        start_moves,
                        orientation,
                        puzzle.problem.kind,
                    });
                    const puzzle_setup: *const goban.DiagramSetup = &puzzle.problem.setup;
                    try writeFreshProblem(gpa, io, out, puzzle_path, puzzle_setup, puzzle.problem.target, comment);
                }
            }
            try out.print("{s}\tafter {d}\t{s}\t{t}\tobvious {d},{d} {d:.0}%\tclear {d}\tbest {d:.0}%\t{s}\n", .{
                basename(path),
                start_moves,
                if (is_twin) "twin" else "own",
                puzzle.problem.kind,
                goban.rowOf(board_size, obvious),
                goban.colOf(board_size, obvious),
                100 * interest.obvious_rate,
                interest.clear_count,
                100 * interest.best_rate,
                verdict,
            });
        }
    }
}

/// Writes one variation of a collection as a source file (`splitCollection`): its `AB` and `AW` properties as they
/// are, its number the first number in its comment - `ordinal` when it has none. Whether it had stones to write.
fn writeSplitProblem(
    gpa: Allocator,
    io: Io,
    variation: []const u8,
    ordinal: u32,
    book: []const u8,
    stem: []const u8,
    out_dir: []const u8,
) !bool {
    var stones: Io.Writer.Allocating = .init(gpa);
    var number: ?u32 = null;
    var index: usize = 0;
    while (index < variation.len) {
        // A property: an identifier in capitals, then its values.
        if (!std.ascii.isUpper(variation[index])) {
            index += 1;
            continue;
        }
        const identifier_start: usize = index;
        while (index < variation.len and std.ascii.isUpper(variation[index])) {
            index += 1;
        }
        const identifier: []const u8 = variation[identifier_start..index];
        const values_start: usize = index;
        while (index < variation.len and variation[index] == '[') {
            const value_end: usize = indexOfScalarPos(u8, variation, index, ']') orelse variation.len;
            if (eql(u8, identifier, "C") and number == null) {
                const value: []const u8 = variation[index + 1 .. value_end];
                const digits_start: ?usize = std.mem.indexOfAny(u8, value, "0123456789");
                if (digits_start) |first_digit| {
                    var digits_end: usize = first_digit;
                    while (digits_end < value.len and std.ascii.isDigit(value[digits_end])) {
                        digits_end += 1;
                    }
                    number = parseInt(u32, value[first_digit..digits_end], 10) catch null;
                }
            }
            index = value_end + 1;
        }
        const is_stones: bool = eql(u8, identifier, "AB") or eql(u8, identifier, "AW");
        if (is_stones) {
            try stones.writer.print("{s}{s}", .{ identifier, variation[values_start..index] });
        }
    }
    if (stones.written().len == 0) {
        return false;
    }
    const problem_number: u32 = number orelse ordinal;
    var path_buffer: [4096]u8 = undefined;
    const path: []const u8 = try bufPrint(&path_buffer, "{s}/{s}-{d:0>4}.sgf", .{ out_dir, stem, problem_number });
    var file_text: Io.Writer.Allocating = .init(gpa);
    try file_text.writer.print("(;GM[1]FF[4]CA[UTF-8]SZ[19]PL[B]{s}C[{s}, problem {d}])\n", .{
        stones.written(),
        book,
        problem_number,
    });
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file_text.written() });
    return true;
}

/// Whether `point` is beside one of `stones`: a step along a line or diagonally from it.
fn isBeside(board_size: u8, point: Point, stones: *const goban.PointSet) bool {
    const row: i32 = goban.rowOf(board_size, point);
    const col: i32 = goban.colOf(board_size, point);
    const last: i32 = @as(i32, board_size) - 1;
    for ([_]i32{ -1, 0, 1 }) |row_step| {
        for ([_]i32{ -1, 0, 1 }) |col_step| {
            const near_row: i32 = row + row_step;
            const near_col: i32 = col + col_step;
            const on_board: bool = near_row >= 0 and near_row <= last and near_col >= 0 and near_col <= last;
            if (!on_board) {
                continue;
            }
            const near: Point = goban.pointAt(board_size, @intCast(near_row), @intCast(near_col));
            if (stones.isSet(near)) {
                return true;
            }
        }
    }
    return false;
}

/// The chain a kill problem's book kills, when that is plainly another than the problem marks (the file's lesson:
/// a target set right). The book's correct line is played out from the problem, and for each of white's chains
/// standing at the start the line's captures and its black moves beside the chain - next to one of its stones, along
/// a line or diagonally - are counted. The marked chain stays whenever the line touches it, capturing it or playing
/// beside it: a line often captures a small chain on the way, a throw-in taken back, while the group it kills stands
/// dead, and a vital point inside an eye space is diagonal to the group, taking none of its liberties. Only a line
/// that leaves the marked chain alone names another: the largest chain it captures, or none captured, the chain its
/// moves came beside most - then the one left fewest liberties, then the larger. A stone of it as it stood at the
/// start; null to keep the mark.
fn bookTarget(
    game: *Game,
    problem: *const goban.Problem,
    line: []const Point,
    options: ConvertOptions,
) ?Point {
    goban.startProblem(game, problem, options.problem_settings);
    const board_size: u8 = problem.setup.board_size;
    // White's chains at the start: a stone of each, and its size.
    var chain_points_buffer: [goban.board_limits.max_points]Point = undefined;
    var chain_sizes_buffer: [goban.board_limits.max_points]usize = undefined;
    var chain_count: usize = 0;
    var seen: goban.PointSet = .empty;
    for (0..goban.pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        if (game.position.stones[point] != .white or seen.isSet(point)) {
            continue;
        }
        const root: Point = goban.findRoot(&game.position, point);
        const chain_stones: goban.PointSet = game.position.group_stones[root];
        seen.setUnion(chain_stones);
        chain_points_buffer[chain_count] = point;
        chain_sizes_buffer[chain_count] = chain_stones.count();
        chain_count += 1;
    }
    if (chain_count == 0 or line.len == 0) {
        return null;
    }
    const chain_points: []const Point = chain_points_buffer[0..chain_count];
    const chain_sizes: []const usize = chain_sizes_buffer[0..chain_count];
    // The marked chain, and the line played: captures, and black's moves on each chain's liberties.
    const marked_root_start: Point = goban.findRoot(&game.position, problem.target);
    var marked_index: usize = 0;
    for (chain_points, 0..) |point, chain_index| {
        if (goban.findRoot(&game.position, point) == marked_root_start) {
            marked_index = chain_index;
        }
    }
    var captured: [goban.board_limits.max_points]bool = @splat(false);
    var moves_beside: [goban.board_limits.max_points]u32 = @splat(0);
    for (line) |move| {
        if (game.position.winner != null or goban.checkMove(&game.position, move) != .legal) {
            break;
        }
        const black_moves: bool = game.position.player_to_move == .black;
        for (chain_points, 0..) |point, chain_index| {
            const stands: bool = game.position.stones[point] != .none;
            if (black_moves and stands) {
                const root: Point = goban.findRoot(&game.position, point);
                const chain_stones: goban.PointSet = game.position.group_stones[root];
                moves_beside[chain_index] += @intFromBool(isBeside(board_size, move, &chain_stones));
            }
        }
        _ = goban.playMove(game, move);
        for (chain_points, 0..) |point, chain_index| {
            if (game.position.stones[point] == .none) {
                captured[chain_index] = true;
            }
        }
    }
    // The marked chain touched by the line: it stays.
    if (captured[marked_index] or moves_beside[marked_index] > 0) {
        return null;
    }
    // Left alone: the largest chain the line captures.
    var largest_captured: ?usize = null;
    for (chain_points, 0..) |_, chain_index| {
        if (!captured[chain_index]) {
            continue;
        }
        const larger: bool = largest_captured == null or chain_sizes[chain_index] > chain_sizes[largest_captured.?];
        if (larger) {
            largest_captured = chain_index;
        }
    }
    if (largest_captured) |captured_index| {
        return chain_points[captured_index];
    }
    // None captured: the chain the line pressed most.
    var most_pressed: ?usize = null;
    var most_pressed_liberties: usize = maxInt(usize);
    for (chain_points, 0..) |point, chain_index| {
        if (moves_beside[chain_index] == 0) {
            continue;
        }
        const root: Point = goban.findRoot(&game.position, point);
        const liberty_count: usize = game.position.group_liberties[root].count();
        const better: bool = if (most_pressed) |best| better: {
            if (moves_beside[chain_index] != moves_beside[best]) {
                break :better moves_beside[chain_index] > moves_beside[best];
            }
            if (liberty_count != most_pressed_liberties) {
                break :better liberty_count < most_pressed_liberties;
            }
            break :better chain_sizes[chain_index] > chain_sizes[best];
        } else true;
        if (better) {
            most_pressed = chain_index;
            most_pressed_liberties = liberty_count;
        }
    }
    const pressed_index: usize = most_pressed orelse return null;
    return chain_points[pressed_index];
}

/// A target's mark as SGF writes it: `TR[` and the point's letters, column then row, and `]`.
fn sgfMark(buffer: []u8, board_size: u8, point: Point) ![]const u8 {
    const col: u8 = goban.colOf(board_size, point);
    const row: u8 = goban.rowOf(board_size, point);
    return bufPrint(buffer, "TR[{c}{c}]", .{ 'a' + col, 'a' + row });
}

/// `path`'s text with its one `old` written as `new`; a file without it is left alone.
fn replaceInFile(
    gpa: Allocator,
    io: Io,
    path: []const u8,
    old: []const u8,
    new: []const u8,
    options: ConvertOptions,
) !void {
    const text: []const u8 = try Dir.cwd().readFileAlloc(io, path, gpa, options.read_limit);
    const at: usize = indexOf(u8, text, old) orelse return;
    var replaced: Io.Writer.Allocating = .init(gpa);
    try replaced.writer.print("{s}{s}{s}", .{ text[0..at], new, text[at + old.len ..] });
    try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = replaced.written() });
}

/// Sets the kill problem at `path` to the target its book kills (`bookTarget`): where that is another chain than
/// the marked one, the problem's triangle moves to it - in its file, and in its later starts' files beside it, which
/// mark the same point. Whether it moved.
fn retargetProblem(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    options: ConvertOptions,
    game: *Game,
) !bool {
    const text: []const u8 = try Dir.cwd().readFileAlloc(io, path, gpa, options.read_limit);
    const problem: goban.Problem = try goban.readProblem(text);
    if (problem.kind != .kill) {
        return false;
    }
    const root: SgfRoot = try goban.readSgfRoot(text);
    var line_buffer: [goban.record_limits.max_moves]Point = undefined;
    const line: []const Point = try goban.readSgfCorrectLine(text, &root, &line_buffer);
    const new_target: Point = bookTarget(game, &problem, line, options) orelse return false;
    // The same chain: nothing to move.
    goban.startProblem(game, &problem, options.problem_settings);
    const new_root: Point = goban.findRoot(&game.position, new_target);
    const same_chain: bool = new_root == goban.findRoot(&game.position, problem.target);
    if (same_chain) {
        return false;
    }
    const board_size: u8 = problem.setup.board_size;
    var old_mark_buffer: [8]u8 = undefined;
    var new_mark_buffer: [8]u8 = undefined;
    const old_mark: []const u8 = try sgfMark(&old_mark_buffer, board_size, problem.target);
    const new_mark: []const u8 = try sgfMark(&new_mark_buffer, board_size, new_target);
    const name: []const u8 = basename(path);
    try out.print("{s}: the target {s} -> {s}\n", .{ name, old_mark, new_mark });
    try replaceInFile(gpa, io, path, old_mark, new_mark, options);
    // Its later starts' files.
    const stem: []const u8 = name[0 .. name.len - ".sgf".len];
    const dir_path: []const u8 = std.fs.path.dirname(path) orelse ".";
    for (1..goban.record_limits.max_moves) |move_number| {
        var later_path_buffer: [4096]u8 = undefined;
        const later_path: []const u8 = try bufPrint(&later_path_buffer, "{s}/{s}-from-move-{d}.sgf", .{
            dir_path,
            stem,
            move_number,
        });
        replaceInFile(gpa, io, later_path, old_mark, new_mark, options) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
    return true;
}

/// Splits the problem collection `text` - a root node, then a variation a problem, each holding its stones and a
/// comment `problem N` - into a source file a problem (the file's lesson): `{stem}-{NNNN}.sgf` in `out_dir`, on a
/// board of 19 lines, black to play, the problem's stones, and a comment naming `book` and the problem's number. A
/// variation with no stones is passed. Returns how many files were written.
fn splitCollection(
    gpa: Allocator,
    io: Io,
    text: []const u8,
    book: []const u8,
    stem: []const u8,
    out_dir: []const u8,
) !usize {
    var written: usize = 0;
    var variation_count: u32 = 0;
    var depth: u32 = 0;
    var in_value: bool = false;
    var variation_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const character: u8 = text[index];
        if (in_value) {
            if (character == '\\') {
                index += 1;
            } else if (character == ']') {
                in_value = false;
            }
            continue;
        }
        switch (character) {
            '[' => in_value = true,
            '(' => {
                depth += 1;
                if (depth == 2) {
                    variation_start = index;
                }
            },
            ')' => {
                if (depth == 2) {
                    variation_count += 1;
                    const variation: []const u8 = text[variation_start .. index + 1];
                    const wrote: bool = try writeSplitProblem(gpa, io, variation, variation_count, book, stem, out_dir);
                    written += @intFromBool(wrote);
                }
                depth -|= 1;
            },
            else => {},
        }
    }
    return written;
}

/// A stone of the largest chain of `colour` in `setup` (the file's lesson: a bookless problem's target), or null when
/// `colour` has no stone. Chains are found by spreading from each stone over its neighbours of the same colour.
fn largestChain(setup: *const goban.DiagramSetup, colour: Stone) ?Point {
    const board_size: u8 = setup.board_size;
    var seen: goban.PointSet = .empty;
    var best_point: ?Point = null;
    var best_count: usize = 0;
    for (0..goban.pointCount(board_size)) |point_index| {
        const start: Point = @intCast(point_index);
        if (setup.stones[start] != colour or seen.isSet(start)) {
            continue;
        }
        // The chain's stones, by a stack of points still to spread from.
        var stack_buffer: [goban.board_limits.max_points]Point = undefined;
        var stack_length: usize = 1;
        stack_buffer[0] = start;
        seen.set(start);
        var chain_count: usize = 0;
        while (stack_length > 0) {
            stack_length -= 1;
            const point: Point = stack_buffer[stack_length];
            chain_count += 1;
            var neighbour_buffer: [goban.board_limits.max_neighbors]Point = undefined;
            for (goban.neighborsOf(board_size, point, &neighbour_buffer)) |neighbour| {
                if (setup.stones[neighbour] == colour and !seen.isSet(neighbour)) {
                    seen.set(neighbour);
                    stack_buffer[stack_length] = neighbour;
                    stack_length += 1;
                }
            }
        }
        if (chain_count > best_count) {
            best_count = chain_count;
            best_point = start;
        }
    }
    return best_point;
}

/// The verdict of a measured puzzle (`PuzzleInterest`): `trivial` when it asks nothing, `unclear` when no move wins
/// it at least `solved_rate` - a puzzle with no book needs one, its search all that will judge it - and `kept`
/// otherwise.
fn booklessVerdict(
    interest: PuzzleInterest,
    solved_rate: f32,
    options: ConvertOptions,
) []const u8 {
    if (interest.isTrivial(options)) {
        return "trivial";
    }
    if (interest.best_rate < solved_rate) {
        return "unclear";
    }
    return "kept";
}

/// How often the opponent's best reply to `move` wins (the file's lesson: a check two plies deep): `move` played in the
/// puzzle `game` holds, then one search of the opponent's replies. The game is left after `move`.
fn opponentReplyRate(
    gpa: Allocator,
    game: *Game,
    move: Point,
    options: ConvertOptions,
    node_buffer: []SearchNode,
) !f32 {
    _ = goban.playMove(game, move);
    var reply_options: ConvertOptions = options;
    reply_options.iterations = options.check_iterations;
    const tree: SearchTree = try search(gpa, game, reply_options, node_buffer);
    const reply: SearchResult = chosenMove(&tree);
    return reply.win_rate;
}

/// The value of the first comment in `text`, or null when it has none.
fn sgfComment(text: []const u8) ?[]const u8 {
    const property_start: usize = indexOf(u8, text, "C[") orelse return null;
    const value_start: usize = property_start + 2;
    const value_end: usize = indexOfScalarPos(u8, text, value_start, ']') orelse return null;
    return text[value_start..value_end];
}

/// Converts the problem at `path`, which has no book (the file's lesson): its kind the geometry's hint
/// (`kindHint`), then the other; its target the largest chain of the target's colour (`largestChain`); kept as the
/// first kind whose puzzle one search finds a winner of that is no obvious move (`measureInterest`) and that holds
/// against the opponent's best reply (`opponentReplyRate`), and written marked. Its twin - the move given to the
/// other side, the colours swapped - is measured too, and both verdicts go with the outcome to `interest.tsv`, so
/// that the index opens the problem as either kind it keeps. Neither kind solved, the problem is noted unsolved.
fn convertBookless(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
    outcome: *ProblemOutcome,
) !void {
    const name: []const u8 = basename(path);
    var text: []const u8 = try Dir.cwd().readFileAlloc(io, path, gpa, options.read_limit);
    var root: SgfRoot = try goban.readSgfRoot(text);
    if (root.triangle_count > 0 or root.square_count > 0) {
        text = try withoutRootMarks(gpa, text, root.end_index);
        root = try goban.readSgfRoot(text);
    }
    const setup: *const goban.DiagramSetup = &root.setup;
    outcome.board_size = setup.board_size;
    const hint: ?KindHint = kindHint(text, setup);
    outcome.hint = hint;
    const first_kind: goban.ProblemKind = if (hint) |known| known.kind else .kill;
    const second_kind: goban.ProblemKind = if (first_kind == .kill) .live else .kill;
    var tree: goban.SolutionTree = undefined;
    try goban.readSolutionTree(text, &root, &tree);
    for ([_]goban.ProblemKind{ first_kind, second_kind }) |kind| {
        const target_colour: Stone = if (kind == .kill) .white else .black;
        const target: Point = largestChain(setup, target_colour) orelse continue;
        const problem: goban.Problem = .{ .setup = setup.*, .target = target, .kind = kind, .book_points = .empty };
        goban.startProblem(game, &problem, options.problem_settings);
        var interest: PuzzleInterest = try measureInterest(gpa, game, options, node_buffer);
        // A near miss searched once more, longer.
        const best_rate: f32 = interest.best_rate;
        const near_miss: bool = best_rate >= options.recheck_rate and best_rate < options.bookless_rate;
        if (near_miss and !interest.isTrivial(options)) {
            var longer_options: ConvertOptions = options;
            longer_options.check_iterations = options.recheck_iterations;
            goban.startProblem(game, &problem, options.problem_settings);
            interest = try measureInterest(gpa, game, longer_options, node_buffer);
        }
        var own_verdict: []const u8 = booklessVerdict(interest, options.bookless_rate, options);
        // Kept, its best move must hold against the opponent's best reply.
        var reply_rate: f32 = 0;
        if (eql(u8, own_verdict, "kept")) {
            goban.startProblem(game, &problem, options.problem_settings);
            reply_rate = try opponentReplyRate(gpa, game, interest.best_move.?, options, node_buffer);
            if (reply_rate > options.refute_rate) {
                own_verdict = "refuted";
            }
        }
        try out.print("{s}: as a {t} problem, {s} - the best move {d:.0}%, the reply {d:.0}%\n", .{
            name,
            kind,
            own_verdict,
            100 * interest.best_rate,
            100 * reply_rate,
        });
        if (!eql(u8, own_verdict, "kept")) {
            continue;
        }
        // Accepted: written marked, its comment the source's.
        var out_path_buffer: [4096]u8 = undefined;
        const out_path: []const u8 = try bufPrint(&out_path_buffer, "{s}/{s}", .{ options.out_dir, name });
        const comment: []const u8 = sgfComment(text) orelse name;
        try writeFreshProblem(gpa, io, out, out_path, setup, target, comment);
        outcome.published = kind;
        outcome.target = target;
        outcome.note = .bookless;
        outcome.black_rate = interest.best_rate;
        // The twin, from the same position.
        const scratch: *Game = try gpa.create(Game);
        const twin_step: goban.PuzzleStep = .{ .start_moves = 0, .is_twin = true };
        const twin: goban.Puzzle = goban.puzzleAt(&problem, &tree, &.{}, twin_step, scratch);
        goban.startProblem(game, &twin.problem, options.problem_settings);
        const twin_interest: PuzzleInterest = try measureInterest(gpa, game, options, node_buffer);
        var twin_verdict: []const u8 = booklessVerdict(twin_interest, options.clear_rate, options);
        if (eql(u8, twin_verdict, "kept")) {
            goban.startProblem(game, &twin.problem, options.problem_settings);
            const twin_move: Point = twin_interest.best_move.?;
            const twin_reply_rate: f32 = try opponentReplyRate(gpa, game, twin_move, options, node_buffer);
            if (twin_reply_rate > options.refute_rate) {
                twin_verdict = "refuted";
            }
        }
        const verdict_text: []const u8 = try bufPrint(&outcome.verdict_buffer, "{s}\t0\town\t{t}\tkept\t{d:.2}\t" ++
            "{d:.2}\t{d}\n{s}\t0\ttwin\t{t}\t{s}\t{d:.2}\t{d:.2}\t{d}\n", .{
            name,                       kind,                      interest.best_rate,
            interest.obvious_rate,      interest.clear_count,      name,
            twin.problem.kind,          twin_verdict,              twin_interest.best_rate,
            twin_interest.obvious_rate, twin_interest.clear_count,
        });
        outcome.verdict_length = verdict_text.len;
        return;
    }
    outcome.note = .unsolved;
}

/// A person's reading of a problem (`annotations.tsv`): its kind, and a stone of its target - for a capturing race,
/// where living and killing are the same moves, a kill problem whose target is the white group in the race.
const Annotation = struct {
    /// Null for a problem annotated `skip`: not one of life and death.
    kind: ?goban.ProblemKind,
    target: Point,
};

/// The annotations kept beside the problems: one line a problem, its name, its kind (`kill` or `live`, or `skip` for
/// no life-and-death problem) and its target's point in SGF letters (`-` for a skip), tab-separated, a note after them
/// if any; lines starting `#` are comments.
const Annotations = struct {
    text: []const u8,

    /// The annotations at `path`, or none when there is no such file.
    fn load(gpa: Allocator, io: Io, path: []const u8, read_limit: Io.Limit) !Annotations {
        const existing: ?[]u8 = Dir.cwd().readFileAlloc(io, path, gpa, read_limit) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        return .{ .text = existing orelse "" };
    }

    /// The annotation of the problem `name`, on a board of `board_size` lines, or null when it has none.
    fn of(annotations: *const Annotations, name: []const u8, board_size: u8) ?Annotation {
        var lines = splitScalar(u8, annotations.text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') {
                continue;
            }
            var columns = splitScalar(u8, line, '\t');
            const line_name: []const u8 = columns.next() orelse continue;
            if (!eql(u8, line_name, name)) {
                continue;
            }
            const kind_text: []const u8 = columns.next() orelse return null;
            const point_text: []const u8 = columns.next() orelse return null;
            if (eql(u8, kind_text, "skip")) {
                return .{ .kind = null, .target = 0 };
            }
            const kind: goban.ProblemKind = std.meta.stringToEnum(goban.ProblemKind, kind_text) orelse return null;
            if (point_text.len != 2) {
                return null;
            }
            const col: u8 = point_text[0] -% 'a';
            const row: u8 = point_text[1] -% 'a';
            if (col >= board_size or row >= board_size) {
                return null;
            }
            return .{ .kind = kind, .target = goban.pointAt(board_size, row, col) };
        }
        return null;
    }
};

/// Converts the problem at `path` from its annotation (the file's lesson): the kind and target a person read from
/// its diagram, marked, with its later starts along the correct line; no twin file - the hero makes its twins in
/// play. One search checks it - one of the book's correct first moves winning for black, often enough over visits
/// enough - and a check that does not confirm it is noted, the problem kept: the annotation is trusted, and in play
/// the book decides the problem. An annotation naming no stone of the target's colour is refused.
fn convertAnnotated(
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    annotation: Annotation,
    options: ConvertOptions,
    game: *Game,
    node_buffer: []SearchNode,
    outcome: *ProblemOutcome,
) !void {
    const name: []const u8 = basename(path);
    var text: []const u8 = try Dir.cwd().readFileAlloc(io, path, gpa, options.read_limit);
    var root: SgfRoot = try goban.readSgfRoot(text);
    if (root.triangle_count > 0 or root.square_count > 0) {
        text = try withoutRootMarks(gpa, text, root.end_index);
        root = try goban.readSgfRoot(text);
    }
    const board_size: u8 = root.setup.board_size;
    outcome.board_size = board_size;
    const kind: goban.ProblemKind = annotation.kind orelse {
        try out.print("{s}: annotated as no life-and-death problem\n", .{name});
        outcome.note = .not_life_and_death;
        return;
    };
    const target_colour: Stone = if (kind == .kill) .white else .black;
    if (root.setup.stones[annotation.target] != target_colour) {
        try out.print("{s}: the annotation's target is no {t} stone\n", .{ name, target_colour });
        outcome.note = .bad_annotation;
        return;
    }
    // The problem as annotated, its region framing the book's points.
    var book: goban.SolutionTree = undefined;
    try goban.readSolutionTree(text, &root, &book);
    var book_points: goban.PointSet = .empty;
    for (book.nodes[0..book.node_count]) |node| {
        book_points.set(node.move);
    }
    var first_move_buffer: [board_limits.max_points]goban.SgfFirstMove = undefined;
    const first_moves: []const goban.SgfFirstMove = try goban.readSgfFirstMoves(text, &root, &first_move_buffer);
    const problem: goban.Problem = .{
        .setup = root.setup,
        .target = annotation.target,
        .kind = kind,
        .book_points = book_points,
    };
    goban.startProblem(game, &problem, options.problem_settings);
    var check_options: ConvertOptions = options;
    check_options.iterations = options.check_iterations;
    const tree: SearchTree = try search(gpa, game, check_options, node_buffer);
    // The check: one of the book's correct first moves wins often enough, over visits enough.
    var best_book_rate: f32 = 0;
    var book_holds_up: bool = false;
    for (first_moves) |first_move| {
        if (!first_move.leads_to_correct) {
            continue;
        }
        const statistics: ChildStatistics = childStatistics(&tree, first_move.point);
        const visited_enough: bool = statistics.visits >= options.check_min_visits;
        const wins_enough: bool = statistics.win_rate >= options.solvable_rate;
        book_holds_up = book_holds_up or (visited_enough and wins_enough);
        best_book_rate = @max(best_book_rate, statistics.win_rate);
    }
    outcome.black_rate = best_book_rate;
    if (!book_holds_up) {
        const best_percent: f32 = 100 * best_book_rate;
        try out.print("{s}: unconfirmed - the book's best {d:.0}%; kept as annotated\n", .{ name, best_percent });
    }
    const mark: []const u8 = if (kind == .kill) "TR" else "SQ";
    try writeMarkedProblem(gpa, io, out, text, &root, mark, annotation.target, options, name);
    outcome.note = if (book_holds_up) .annotated else .annotated_unconfirmed;
    outcome.published = kind;
    outcome.target = annotation.target;
    // The later starts along the correct line - the hero's ladder, its twins made in play (`goban.puzzleAt`): every
    // second move, as long as the other side, moving first there, still wins - its twin a real puzzle. The first
    // that does not ends the ladder, so that its steps follow one another. A kill problem's are written as files
    // too, for goban problems' lists.
    var line_buffer: [goban.record_limits.max_moves]Point = undefined;
    const line: []const Point = try goban.readSgfCorrectLine(text, &root, &line_buffer);
    const stem: []const u8 = name[0 .. name.len - ".sgf".len];
    var path_buffer: [4096]u8 = undefined;
    var moves_before: usize = 2;
    while (moves_before < line.len and outcome.later_count < options.max_later_starts) : (moves_before += 2) {
        goban.startProblem(game, &problem, options.problem_settings);
        // The line's moves up to this start - unless the game ends on the way, the line capturing the target, which
        // ends the ladder.
        for (line[0..moves_before]) |move| {
            if (game.position.winner != null) {
                break;
            }
            _ = goban.playMove(game, move);
        }
        const target_stands: bool = game.position.stones[annotation.target] != .none;
        if (!target_stands or game.position.winner != null) {
            break;
        }
        const later_setup: goban.DiagramSetup = .{
            .board_size = board_size,
            .stones = goban.stonesInRegion(&game.position),
            .player_to_move = .black,
        };
        // The target as the start would be written: a stone of its colour in the region, or the ladder ends there.
        if (later_setup.stones[annotation.target] != target_colour) {
            break;
        }
        const later_problem: goban.Problem = .{
            .setup = later_setup,
            .target = annotation.target,
            .kind = kind,
            .book_points = book_points,
        };
        goban.startProblem(game, &later_problem, options.problem_settings);
        game.record.setup_to_play = .white;
        goban.replayTo(game, 0);
        const other_first: SearchResult = chosenMove(&(try search(gpa, game, check_options, node_buffer)));
        outcome.later_checked += 1;
        if (other_first.win_rate < options.unsettled_rate) {
            break;
        }
        outcome.later_starts[outcome.later_count] = @intCast(moves_before);
        outcome.later_count += 1;
        if (kind == .kill) {
            const later_path: []const u8 = try bufPrint(&path_buffer, "{s}/{s}-from-move-{d}.sgf", .{
                options.out_dir,
                stem,
                moves_before + 1,
            });
            var comment_buffer: [128]u8 = undefined;
            const comment: []const u8 = try bufPrint(&comment_buffer, "{s} from move {d}", .{
                stem,
                moves_before + 1,
            });
            try writeFreshProblem(gpa, io, out, later_path, &later_setup, annotation.target, comment);
        }
    }
}

/// One thread's share of a run: every `stride`-th path from `first`, each converted with the thread's own game and
/// tree, its report written into its own buffer.
const ConversionShare = struct {
    first: usize,
    stride: usize,
    options: ConvertOptions,
    io: Io,
    gpa: Allocator,
    /// One report per path of the run, the share's own filled in.
    reports: []Io.Writer.Allocating,
    /// The run's report, every thread's.
    report: *Report,
    /// The annotations, for an annotated run (`ConvertOptions.annotated`).
    annotations: *const Annotations,
    /// The verdicts of interest, for a bookless run (`ConvertOptions.bookless`).
    verdicts: *Verdicts,
    /// The first error the share met, if any.
    failure: ?anyerror = null,

    fn run(share: *ConversionShare) void {
        share.convertAll() catch |err| {
            share.failure = err;
        };
    }

    fn convertAll(share: *ConversionShare) !void {
        var arena_state: ArenaAllocator = .init(share.gpa);
        defer arena_state.deinit();
        const arena: Allocator = arena_state.allocator();
        const game: *Game = try arena.create(Game);
        const node_buffer: []SearchNode = try arena.alloc(SearchNode, share.options.iterations + 1);
        var path_index: usize = share.first;
        while (path_index < share.options.paths.len) : (path_index += share.stride) {
            const report: *Io.Writer = &share.reports[path_index].writer;
            const path: []const u8 = share.options.paths[path_index];
            const name: []const u8 = basename(path);
            if (share.report.has(name)) {
                try report.print("{s}: in the report already\n", .{name});
                continue;
            }
            const started: Io.Timestamp = .now(share.io, .awake);
            var outcome: ProblemOutcome = .{};
            if (share.options.bookless) {
                try convertBookless(arena, share.io, report, path, share.options, game, node_buffer, &outcome);
            } else if (share.options.annotated) {
                // Only the annotated problems: the rest are left for their annotations.
                const text: []const u8 = try Dir.cwd().readFileAlloc(share.io, path, arena, share.options.read_limit);
                const board_size: u8 = (try goban.readSgfRoot(text)).setup.board_size;
                const annotation: Annotation = share.annotations.of(name, board_size) orelse continue;
                const options: ConvertOptions = share.options;
                try convertAnnotated(arena, share.io, report, path, annotation, options, game, node_buffer, &outcome);
            } else if (share.options.adopts) {
                outcome = try adoptProblem(arena, share.io, path, share.options) orelse continue;
                try report.print("{s}: adopted\n", .{name});
            } else {
                // A problem that cannot be read, or that runs past the time cap, is reported so - the latter keeping
                // what it had accepted - and the run goes on to the next. Each problem's searches read the clock
                // from the moment it began.
                var problem_options: ConvertOptions = share.options;
                problem_options.clock = share.io;
                problem_options.started = started;
                convertProblem(
                    arena,
                    share.io,
                    report,
                    path,
                    problem_options,
                    game,
                    node_buffer,
                    &outcome,
                ) catch |err| {
                    const timed_out: bool = err == error.TimeUp;
                    const what: []const u8 = if (timed_out) "stopped at the time cap" else "not converted";
                    try report.print("{s}: {s} - {t}\n", .{ name, what, err });
                    outcome.note = if (timed_out) .too_slow else .unreadable;
                };
            }
            const elapsed_ns: i96 = started.durationTo(.now(share.io, .awake)).nanoseconds;
            outcome.seconds = float(elapsed_ns) / 1e9;
            try share.report.add(share.gpa, share.io, name, &outcome);
            if (outcome.verdict_length > 0) {
                try share.verdicts.add(share.gpa, share.io, outcome.verdict_buffer[0..outcome.verdict_length]);
            }
        }
    }
};

/// One run (the file's lesson): the options read, the problems converted on as many threads as asked for - one for
/// each core by default - and their reports written in the order of the files.
fn run(init: std.process.Init, out: *Io.Writer) !void {
    const gpa: Allocator = init.gpa;
    const args: []const [:0]const u8 = try init.minimal.args.toSlice(init.arena.allocator());
    const paths_buffer: [][]const u8 = try init.arena.allocator().alloc([]const u8, args.len);
    const options: ConvertOptions = parseOptions(args, paths_buffer) catch |err| {
        try out.print("goban-problems-convert: {t}. Use: [--out <dir>] [--iterations <n>] [--threads <n>] " ++
            "<sgf files>\n", .{err});
        return;
    };
    const core_count: usize = std.Thread.getCpuCount() catch 1;
    const threads_asked: usize = options.thread_count orelse core_count;
    const thread_count: usize = clamp(threads_asked, 1, @max(options.paths.len, 1));
    const reports: []Io.Writer.Allocating = try init.arena.allocator().alloc(Io.Writer.Allocating, options.paths.len);
    for (reports) |*problem_report| {
        problem_report.* = Io.Writer.Allocating.init(gpa);
    }
    defer for (reports) |*problem_report| {
        problem_report.deinit();
    };
    var report_path_buffer: [4096]u8 = undefined;
    const report_path: []const u8 = try bufPrint(&report_path_buffer, "{s}/report.tsv", .{options.out_dir});
    var report: Report = try .load(gpa, init.io, report_path, options.read_limit);
    defer report.text.deinit(gpa);
    var annotations_path_buffer: [4096]u8 = undefined;
    const annotations_path: []const u8 = try bufPrint(&annotations_path_buffer, "{s}/annotations.tsv", .{
        options.out_dir,
    });
    const annotations: Annotations = try .load(init.arena.allocator(), init.io, annotations_path, options.read_limit);
    var verdicts_path_buffer: [4096]u8 = undefined;
    const verdicts_path: []const u8 = try bufPrint(&verdicts_path_buffer, "{s}/interest.tsv", .{options.out_dir});
    var verdicts: Verdicts = try .load(init.arena.allocator(), init.io, verdicts_path, options.read_limit);
    var difficulty_path_buffer: [4096]u8 = undefined;
    const difficulty_path: []const u8 = try bufPrint(&difficulty_path_buffer, "{s}/difficulty.tsv", .{options.out_dir});
    var difficulties: Difficulties = try .load(gpa, init.io, difficulty_path, options.read_limit);
    defer difficulties.text.deinit(gpa);
    if (options.retargets) {
        const game: *Game = try gpa.create(Game);
        defer gpa.destroy(game);
        var changed_count: usize = 0;
        for (options.paths) |path| {
            const arena: Allocator = init.arena.allocator();
            const changed: bool = try retargetProblem(arena, init.io, out, path, options, game);
            changed_count += @intFromBool(changed);
            try out.flush();
        }
        try out.print("{d} of {d} problems retargeted\n", .{ changed_count, options.paths.len });
        return;
    }
    if (options.split_path) |split_path| {
        const text: []const u8 = try Dir.cwd().readFileAlloc(init.io, split_path, gpa, options.read_limit);
        defer gpa.free(text);
        var source_dir_buffer: [4096]u8 = undefined;
        const source_dir: []const u8 = try bufPrint(&source_dir_buffer, "{s}/source", .{options.out_dir});
        const book: []const u8 = options.split_book;
        const stem: []const u8 = options.split_stem;
        const written: usize = try splitCollection(init.arena.allocator(), init.io, text, book, stem, source_dir);
        try out.print("{d} problems written to {s}\n", .{ written, source_dir });
        return;
    }
    if (options.prints_interest) {
        const game: *Game = try gpa.create(Game);
        defer gpa.destroy(game);
        const node_buffer: []SearchNode = try gpa.alloc(SearchNode, options.check_iterations + 1);
        defer gpa.free(node_buffer);
        // The verdicts kept beside the problems: each problem's added once, the run going on from where an earlier
        // one stopped; the whole file written again after each problem.
        var interest_path_buffer: [4096]u8 = undefined;
        const interest_path: []const u8 = try bufPrint(&interest_path_buffer, "{s}/interest.tsv", .{options.out_dir});
        const arena: Allocator = init.arena.allocator();
        const read_limit: Io.Limit = options.read_limit;
        const existing: []const u8 = Dir.cwd().readFileAlloc(init.io, interest_path, arena, read_limit) catch "";
        var all_verdicts: Io.Writer.Allocating = .init(arena);
        try all_verdicts.writer.writeAll(existing);
        for (options.paths) |path| {
            const name: []const u8 = basename(path);
            var line_start_buffer: [256]u8 = undefined;
            const line_start: []const u8 = try bufPrint(&line_start_buffer, "\n{s}\t", .{name});
            const is_first_line: bool = startsWith(u8, existing, line_start[1..]);
            const measured_before: bool = is_first_line or indexOf(u8, existing, line_start) != null;
            if (measured_before) {
                continue;
            }
            try printInterest(arena, init.io, out, &all_verdicts.writer, path, options, game, node_buffer);
            try Dir.cwd().writeFile(init.io, .{ .sub_path = interest_path, .data = all_verdicts.written() });
            try out.flush();
        }
        return;
    }
    if (options.prints_hints) {
        for (options.paths) |path| {
            const text: []const u8 = try Dir.cwd().readFileAlloc(init.io, path, gpa, options.read_limit);
            defer gpa.free(text);
            const root: SgfRoot = try goban.readSgfRoot(text);
            const hint: ?KindHint = kindHint(text, &root.setup);
            if (hint) |known| {
                try out.print("{s}\t{t}\t{t}\n", .{ basename(path), known.kind, known.source });
            } else {
                try out.print("{s}\t-\t-\n", .{basename(path)});
            }
        }
        return;
    }
    if (options.measures) {
        try measureAll(gpa, init.io, out, options, &difficulties);
        var measure_index_path_buffer: [4096]u8 = undefined;
        const measure_index_path: []const u8 = try bufPrint(&measure_index_path_buffer, "{s}/index.zig", .{
            options.out_dir,
        });
        var measure_arena_state: ArenaAllocator = .init(gpa);
        defer measure_arena_state.deinit();
        try writeIndex(measure_arena_state.allocator(), init.io, &report, &difficulties, measure_index_path);
        return;
    }
    const shares: []ConversionShare = try init.arena.allocator().alloc(ConversionShare, thread_count);
    for (shares, 0..) |*share, share_index| {
        share.* = .{
            .first = share_index,
            .stride = thread_count,
            .options = options,
            .io = init.io,
            .gpa = gpa,
            .reports = reports,
            .report = &report,
            .annotations = &annotations,
            .verdicts = &verdicts,
        };
    }
    // The first share on this thread, the others each on one of their own.
    const threads: []std.Thread = try init.arena.allocator().alloc(std.Thread, thread_count - 1);
    for (threads, shares[1..]) |*thread, *share| {
        thread.* = try std.Thread.spawn(.{}, ConversionShare.run, .{share});
    }
    shares[0].run();
    for (threads) |thread| {
        thread.join();
    }
    for (reports) |*problem_report| {
        try out.writeAll(problem_report.written());
    }
    for (shares) |share| {
        if (share.failure) |err| {
            return err;
        }
    }
    // The index, from the whole report - this run's problems and every run's before.
    var index_path_buffer: [4096]u8 = undefined;
    const index_path: []const u8 = try bufPrint(&index_path_buffer, "{s}/index.zig", .{options.out_dir});
    var index_arena_state: ArenaAllocator = .init(gpa);
    defer index_arena_state.deinit();
    try writeIndex(index_arena_state.allocator(), init.io, &report, &difficulties, index_path);
    try out.print("report: {s}; index: {s}\n", .{ report_path, index_path });
}

pub fn main(init: std.process.Init) !void {
    var out_buffer: [8192]u8 = undefined;
    var out_writer: File.Writer = File.stdout().writer(init.io, &out_buffer);
    const out: *Io.Writer = &out_writer.interface;
    try run(init, out);
    try out.flush();
}
