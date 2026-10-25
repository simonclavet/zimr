//! goban - a Go board for two players on one screen.
//!
//! THE GAME
//!   Two players take turns placing stones, black first, on the intersections ("points") of a square grid. Stones of
//!   one colour that touch along the lines form a GROUP. The empty points next to a group are its LIBERTIES. A group
//!   left with no liberty is captured: its stones leave the board and become the capturer's PRISONERS. A move that
//!   would leave its own group with no liberty (SUICIDE) is refused, unless it captures first. A move may not retake a
//!   single stone at once in the back-and-forth called KO, which would otherwise repeat forever.
//!   In ATARI GO, a game for learning, the first player to capture a set number of stones wins.
//!
//! THE FOREST
//!   The program keeps every group as a tree whose nodes are the group's stones, the whole board being a forest of such
//!   trees (a disjoint-set forest, or union-find). Every stone points to a PARENT; following parents ends at the ROOT,
//!   the stone that stands for its group and holds the group's liberties and stone list. Two stones are in one group
//!   exactly when they reach the same root.
//!
//!       stones on the board           parent pointers               what the root holds
//!
//!         . X X .                       . > v .                       root (2,2):
//!         . . X .                       . . v .                         stones    (0,1) (0,2) (1,2) (2,2)
//!         . . X .                       . . R .                         liberties (0,0) (0,3) (1,1) (1,3) ...
//!
//!   (> and v point right and down to a stone's parent; R is the root, (2,2), its own parent)
//!
//!   Placing a stone joins it to the groups it touches: their roots get the new stone as their parent, so the newest
//!   stone becomes the root of the whole joined group, and the joined groups' liberties and stones move into its sets.
//!   Finding a root later shortens the path it walks ("path compression"), so the trees stay flat. A move therefore
//!   costs a few set operations, where a search of the whole group (a "flood fill") would visit every stone.
//!
//! THE SECTIONS (each opens with a `// ===== N. Name =====` banner and a lesson of its own)
//!    1. Stones and points     a point's index, its row and column, its neighbours
//!    2. The forest            Position: the stones, the parents, each root's liberties and stones
//!    3. The rules             which moves are legal, and what a move does: joins, captures, ko, the turn
//!    4. The record            the setup and the moves; starting a game; undo and redo by replay
//!    5. Checking the forest   a flood fill from the stones alone, compared with every root's sets
//!    6. Diagrams              a position as text, written and read, for tests and the clipboard
//!    7. The opponent          Monte Carlo tree search for Atari Go: the tree, its iterations, the move chosen
//!    8. Layout                the board's place in the window, and from a pointer to a point
//!    9. Drawing               the wood, the lines, the star points, the stones, the last move, the ghost
//!   10. Input                 press, drag, release: picking a stone up and putting it down
//!   11. The app               the state, the buttons and the pause window, and one frame
//!    Tests                    each rule as a diagram, random games checked move by move, undo and redo, diagrams
const std = @import("std");
const ArrayList = std.ArrayList;
const Io = std.Io;
const indexOf = std.mem.indexOf;
const eql = std.mem.eql;
const indexOfScalar = std.mem.indexOfScalar;
const parseInt = std.fmt.parseInt;
const printInt = std.fmt.printInt;
const bufPrint = std.fmt.bufPrint;
const splitScalar = std.mem.splitScalar;
const startsWith = std.mem.startsWith;
const trim = std.mem.trim;
const StaticBitSet = std.bit_set.StaticBitSet;
const Random = std.Random;
const DefaultPrng = Random.DefaultPrng;
const Xoshiro256 = Random.Xoshiro256;
const Wyhash = std.hash.Wyhash;
const asBytes = std.mem.asBytes;
const sliceAsBytes = std.mem.sliceAsBytes;
const bytesAsSlice = std.mem.bytesAsSlice;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const zm = @import("zm");
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const panicf = zm.panicf;
const float = zm.float;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const DoubleSpring = zm.DoubleSpring;
const clamp = zm.clamp;
const clamp01 = zm.clamp01;
const sinRad = zm.sinRad;
const lerp = zm.lerp;
const smootherStep01 = zm.smootherStep01;
const lengthSq2 = zm.lengthSq2;
const maxInt = zm.maxInt;
const minInt = zm.minInt;
const inf = zm.inf;
const sqrt = zm.sqrt;
const ln = zm.ln;
const float64 = zm.float64;
const splat2 = zm.splat2;
const pi = zm.pi;
const z = @import("zimr");
const common = @import("example_common");
const ui = z.ui_real;
const jobs = z.jobs;
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const sortSlice = std.mem.sort;
const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;

// ===== 1. Stones and points =====
//
// The board is a square of `board_size` x `board_size` points, from 3 x 3 up to 19 x 19. A point is named by one
// number, its index in reading order: row 0 holds points 0 .. board_size - 1, row 1 the next board_size, and so on.
//
//       col:  0   1   2           on a 3 x 3 board:   pointAt(1, 2) = 1 * 3 + 2 = 5
//   row 0     0 - 1 - 2                               rowOf(5) = 5 / 3 = 1
//   row 1     3 - 4 - 5                               colOf(5) = 5 % 3 = 2
//   row 2     6 - 7 - 8
//
// One number per point lets every per-point table be a plain array indexed by point, and a set of points be a bit
// set. Every table is sized for the largest board, so changing the board size allocates nothing; a smaller board uses
// the first board_size * board_size entries.
//
// These functions take the board size as an argument rather than reading it from somewhere: the size is part of the
// position (section 2), and nothing in this file is global.

/// The sizes a board may have. They are compile-time constants, because the largest board sizes every per-point
/// table, and they live in this namespace so that every use names what it is a limit of: `board_limits.max_size`.
pub const board_limits = struct {
    /// The smallest board: a 3 x 3 board still has a centre point and four corners.
    pub const min_size: u8 = 3;

    /// The largest board, the standard one.
    pub const max_size: u8 = 19;

    /// Points on the largest board, 19 x 19 = 361: the length of every per-point table.
    pub const max_points: usize = @as(usize, max_size) * max_size;

    /// The most neighbours a point can have: up, down, left and right. The length of the buffer neighborsOf fills.
    pub const max_neighbors: usize = 4;

    /// The most star points a board has: four corners, four sides and the centre (section 9).
    pub const max_star_points: usize = 9;
};

/// A point of the board, as its index in reading order: `row * board_size + col`.
/// An absent point - no ko point, no last move - is `null` in a `?Point`.
pub const Point = u16;

/// A set of points: one bit per point of the largest board. Adding, removing and testing a point are one bit
/// operation each, the union of two sets is one OR per machine word, and nothing is ever allocated.
pub const PointSet = StaticBitSet(board_limits.max_points);

/// What stands on a point: nothing, a black stone or a white stone. The same type names a player - the player whose
/// stones are that colour - so `player_to_move` and `winner` are Stones too.
pub const Stone = enum(u8) {
    none,
    black,
    white,

    /// The other player. Asking for the opponent of `.none` is a bug in the caller, so it asserts.
    pub fn opponent(stone: Stone) Stone {
        assertf(stone != .none, @src(), "opponent() asked for the opponent of an empty point", .{});
        switch (stone) {
            .black => {
                return .white;
            },
            .white => {
                return .black;
            },
            .none => {
                unreachable;
            },
        }
    }
};

/// How many points a board of this size has: board_size * board_size.
pub fn pointCount(board_size: u8) usize {
    assertf(
        board_size >= board_limits.min_size and board_size <= board_limits.max_size,
        @src(),
        "board size {d} is outside {d}..{d}",
        .{ board_size, board_limits.min_size, board_limits.max_size },
    );
    const side: usize = board_size;
    const point_count: usize = side * side;
    return point_count;
}

/// Is (row, col) a point of the board? Rows and columns are signed here, because the questions this answers come from
/// arithmetic that can step off the board on either side: a neighbour's row - 1, or a pointer left of the board.
pub fn isOnBoard(board_size: u8, row: i32, col: i32) bool {
    const row_is_on_board: bool = row >= 0 and row < board_size;
    const col_is_on_board: bool = col >= 0 and col < board_size;
    const point_is_on_board: bool = row_is_on_board and col_is_on_board;
    return point_is_on_board;
}

/// The point at (row, col): its index in reading order, `row * board_size + col`.
pub fn pointAt(board_size: u8, row: u8, col: u8) Point {
    assertf(
        isOnBoard(board_size, row, col),
        @src(),
        "pointAt({d}, {d}) is off a {d} x {d} board",
        .{ row, col, board_size, board_size },
    );
    const side: Point = board_size;
    const rows_above: Point = row;
    const point: Point = rows_above * side + col;
    return point;
}

/// The row of a point: how many whole rows come before it in reading order.
pub fn rowOf(board_size: u8, point: Point) u8 {
    assertf(point < pointCount(board_size), @src(), "point {d} is off a {d} x {d} board", .{
        point,
        board_size,
        board_size,
    });
    const side: Point = board_size;
    const row: u8 = @intCast(point / side);
    return row;
}

/// The column of a point: how far along its row it is.
pub fn colOf(board_size: u8, point: Point) u8 {
    assertf(point < pointCount(board_size), @src(), "point {d} is off a {d} x {d} board", .{
        point,
        board_size,
        board_size,
    });
    const side: Point = board_size;
    const col: u8 = @intCast(point % side);
    return col;
}

/// The neighbours of `point`: the points one line away, up, down, left and right, in that order, leaving out the
/// ones that would be off the board. A point in the middle has four, a point on an edge three, a corner two.
/// They are written into the caller's buffer, and the returned slice is the part of it that holds them; it is valid
/// for as long as the buffer is. Every append fits, since no point has more than `board_limits.max_neighbors`.
pub fn neighborsOf(
    board_size: u8,
    point: Point,
    out_buffer: *[board_limits.max_neighbors]Point,
) []const Point {
    const row: u8 = rowOf(board_size, point);
    const col: u8 = colOf(board_size, point);
    const last_line: u8 = board_size - 1;
    var neighbors: ArrayList(Point) = .initBuffer(out_buffer);

    const has_point_above: bool = row > 0;
    if (has_point_above) {
        neighbors.appendAssumeCapacity(pointAt(board_size, row - 1, col));
    }
    const has_point_below: bool = row < last_line;
    if (has_point_below) {
        neighbors.appendAssumeCapacity(pointAt(board_size, row + 1, col));
    }
    const has_point_left: bool = col > 0;
    if (has_point_left) {
        neighbors.appendAssumeCapacity(pointAt(board_size, row, col - 1));
    }
    const has_point_right: bool = col < last_line;
    if (has_point_right) {
        neighbors.appendAssumeCapacity(pointAt(board_size, row, col + 1));
    }
    return neighbors.items;
}

/// A rectangle of the board's points, its first and last row and column included: the region a problem is
/// played in (section 3's lesson). Moves outside it are not moves of the problem.
pub const ProblemRegion = struct {
    first_row: u8,
    first_col: u8,
    last_row: u8,
    last_col: u8,

    /// Whether `point` of a board this size is in the region.
    pub fn contains(region: ProblemRegion, board_size: u8, point: Point) bool {
        const row: u8 = rowOf(board_size, point);
        const col: u8 = colOf(board_size, point);
        const row_is_inside: bool = row >= region.first_row and row <= region.last_row;
        const col_is_inside: bool = col >= region.first_col and col <= region.last_col;
        return row_is_inside and col_is_inside;
    }

    /// The smallest rectangle around `points` widened by `margin` lines on every side, within a board this size.
    /// `points` must not be empty.
    pub fn around(board_size: u8, points: []const Point, margin: u8) ProblemRegion {
        assertf(points.len > 0, @src(), "ProblemRegion.around: no points", .{});
        var region: ProblemRegion = .{ .first_row = maxInt(u8), .first_col = maxInt(u8), .last_row = 0, .last_col = 0 };
        for (points) |point| {
            region.first_row = @min(region.first_row, rowOf(board_size, point));
            region.first_col = @min(region.first_col, colOf(board_size, point));
            region.last_row = @max(region.last_row, rowOf(board_size, point));
            region.last_col = @max(region.last_col, colOf(board_size, point));
        }
        const last_line: u8 = board_size - 1;
        region.first_row -|= margin;
        region.first_col -|= margin;
        region.last_row = @min(region.last_row + margin, last_line);
        region.last_col = @min(region.last_col + margin, last_line);
        return region;
    }
};

// ===== 2. The forest =====
//
// A Position is what is on the board now: the stones, and the forest that groups them (the header draws it). Every
// table has one entry per point; the group tables are read only at a group's root.
//
//   group_parent[p]       the stone p points to. A root points to itself; an empty point has no parent (null).
//   group_liberties[r]    for a root r: the empty points next to any stone of r's group.
//   group_stones[r]       for a root r: every stone of r's group, r included.
//
// Away from the roots, group_liberties and group_stones are empty: a stone is a root when it is placed, and its sets
// are emptied when its group joins another or is captured. The functions below keep that true, and read the sets
// only at a root.
//
// Three operations change the forest, and all three are used only while a stone is being placed (section 3):
//
//   findRootCompressingPath   find a stone's root, and make every stone passed on the way a child of the root
//   joinGroups                hang one group's tree under another's root, and move its sets there
//   removeCapturedGroup       take a captured group off the board, and give its points back as liberties
//
// Everything that only looks at the board - the suicide test, the overlays, the inspector - uses findRoot, which
// follows the same parents and changes nothing. So the shape of the forest follows from the moves played alone, and
// replaying a game rebuilds the same forest. If every search compressed paths, the forest's shape would depend on
// every question ever asked of it - drawing the board included - and a drawing of the forest would show where the
// mouse had been as much as what the moves made.

/// What is on the board now, and everything the rules need to know about it. How the game got here - the moves -
/// is not part of it.
pub const Position = struct {
    /// Points per side, board_limits.min_size .. board_limits.max_size.
    board_size: u8,
    /// What stands on each point.
    stones: [board_limits.max_points]Stone,
    /// The forest: each stone's parent in its group's tree, itself at a root, null on an empty point.
    group_parent: [board_limits.max_points]?Point,
    /// Meaningful at a root only: the group's liberties.
    group_liberties: [board_limits.max_points]PointSet,
    /// Meaningful at a root only: the group's stones.
    group_stones: [board_limits.max_points]PointSet,
    /// The point the player to move may not play this turn because of ko, if any.
    ko_point: ?Point,
    /// Whose turn it is.
    player_to_move: Stone,
    /// The stone placed by the last move, for its marker; null before the first move.
    last_move: ?Point,
    /// White stones captured by black so far: black's prisoners.
    stones_captured_by_black: u32,
    /// Black stones captured by white so far: white's prisoners.
    stones_captured_by_white: u32,
    /// Atari Go: the first player to capture this many stones wins. Null in plain Go.
    capture_goal: ?u8,
    /// A problem's target (section 3's lesson): the stone whose capture wins the game for its opponent - in a kill
    /// problem a white stone black must capture, in a life problem a black stone white must not. Null in a game.
    target: ?Point,
    /// A problem: the region its moves are played in. Null in a game, whose moves may go anywhere.
    region: ?ProblemRegion,
    /// The player who reached the capture goal, or captured the target, once one has.
    winner: ?Stone,

    /// An empty board of `board_size`, black to play, no captures, plain Go.
    pub fn init(board_size: u8) Position {
        assertf(
            board_size >= board_limits.min_size and board_size <= board_limits.max_size,
            @src(),
            "board size {d} is outside {d}..{d}",
            .{ board_size, board_limits.min_size, board_limits.max_size },
        );
        const empty_board: Position = .{
            .board_size = board_size,
            .stones = @splat(.none),
            .group_parent = @splat(null),
            .group_liberties = @splat(.empty),
            .group_stones = @splat(.empty),
            .ko_point = null,
            .player_to_move = .black,
            .last_move = null,
            .stones_captured_by_black = 0,
            .stones_captured_by_white = 0,
            .capture_goal = null,
            .target = null,
            .region = null,
            .winner = null,
        };
        return empty_board;
    }
};

/// Does `point` hold a stone that is its own parent - the root of its group?
pub fn isRoot(position: *const Position, point: Point) bool {
    const maybe_parent: ?Point = position.group_parent[point];
    const has_parent: bool = maybe_parent != null;
    if (!has_parent) {
        return false;
    }
    const parent: Point = maybe_parent.?;
    const is_own_parent: bool = parent == point;
    return is_own_parent;
}

/// The parent of the stone on `point`. Every stone has one - a root is its own - so a stone without a parent means the
/// forest is broken, and this asserts.
fn parentOf(position: *const Position, point: Point) Point {
    const maybe_parent: ?Point = position.group_parent[point];
    assertf(maybe_parent != null, @src(), "the stone on point {d} has no parent", .{point});
    const parent: Point = maybe_parent.?;
    return parent;
}

/// The root of the group that the stone on `point` belongs to: follow parents until a stone is its own parent.
///
///     a -> b -> c -> root        findRoot(a) = root, after three steps; the forest is left as it was
///
/// Read-only, so everything that only looks at the board uses this one (the section's lesson says why that matters).
/// Each step goes one stone closer to the root, so a walk longer than the board has points has found a loop of
/// parents, and asserts.
pub fn findRoot(position: *const Position, point: Point) Point {
    assertf(position.stones[point] != .none, @src(), "findRoot asked about empty point {d}", .{point});
    var current: Point = point;
    var steps_taken: usize = 0;
    while (true) {
        const parent: Point = parentOf(position, current);
        const current_is_root: bool = parent == current;
        if (current_is_root) {
            return current;
        }
        steps_taken += 1;
        assertf(
            steps_taken < board_limits.max_points,
            @src(),
            "the parents from point {d} loop without reaching a root",
            .{point},
        );
        current = parent;
    }
}

/// The root of `point`'s group, as findRoot finds it, and on the way every stone of the path is made a child of the
/// root ("path compression"), so the next search from any of them takes one step.
///
///     before:  a -> b -> c -> root          after:  a -> root
///                                                   b -> root
///                                                   c -> root   (c's parent was already the root)
///
/// Two passes: findRoot walks to the root, then the same path is walked again, each stone repointed at the root as it
/// is left. It changes the forest, so it is used only while a stone is being placed.
pub fn findRootCompressingPath(position: *Position, point: Point) Point {
    const root: Point = findRoot(position, point);
    var current: Point = point;
    while (current != root) {
        const next_on_path: Point = parentOf(position, current);
        position.group_parent[current] = root;
        current = next_on_path;
    }
    return root;
}

/// Joins two groups of one colour into one, rooted at `new_root`: the joining group's root takes `new_root` as its
/// parent, so its whole tree hangs under `new_root`, and its liberties and stones move into `new_root`'s sets.
///
///     new_root's group:  N           joining group:  J <- s           after:  N <- J <- s
///
/// The rules call it with the stone just placed as `new_root`, so the newest stone becomes the root of every group
/// it touches. Returns whether two groups were joined: false when both roots are already the same group's - a placed
/// stone can touch one group on two sides, and the second side finds the group already joined.
pub fn joinGroups(position: *Position, new_root: Point, joining_root: Point) bool {
    const already_one_group: bool = new_root == joining_root;
    if (already_one_group) {
        return false;
    }
    assertf(isRoot(position, new_root), @src(), "joinGroups: new_root {d} is not a root", .{new_root});
    assertf(isRoot(position, joining_root), @src(), "joinGroups: joining_root {d} is not a root", .{joining_root});
    const new_root_stone: Stone = position.stones[new_root];
    const joining_root_stone: Stone = position.stones[joining_root];
    assertf(new_root_stone == joining_root_stone, @src(), "joinGroups: {d} is {t} and {d} is {t}", .{
        new_root,
        new_root_stone,
        joining_root,
        joining_root_stone,
    });

    position.group_parent[joining_root] = new_root;

    const joining_liberties: PointSet = position.group_liberties[joining_root];
    const joining_stones: PointSet = position.group_stones[joining_root];
    position.group_liberties[new_root].setUnion(joining_liberties);
    position.group_stones[new_root].setUnion(joining_stones);
    position.group_liberties[joining_root] = .empty;
    position.group_stones[joining_root] = .empty;
    return true;
}

/// Takes a captured group off the board and returns the points it emptied.
/// The group must have no liberty left: that is what captured means.
///
///     before:   . O .        O's root has no liberty        after:   . O .
///               O X O        X is captured                           O . O     the emptied point is now a
///               . O .                                                . O .     liberty of all four O groups
///
/// First every stone of the group leaves the board. Then each emptied point is given, as a liberty, to every group of
/// the capturing colour beside it: the stones that did the capturing get that breathing space back. Points beside an
/// emptied point that were also in the captured group are empty by then, and get nothing.
pub fn removeCapturedGroup(position: *Position, captured_root: Point) PointSet {
    assertf(isRoot(position, captured_root), @src(), "removeCapturedGroup: {d} is not a root", .{captured_root});
    const liberty_count: usize = position.group_liberties[captured_root].count();
    assertf(liberty_count == 0, @src(), "removeCapturedGroup: group {d} still has {d} liberties", .{
        captured_root,
        liberty_count,
    });
    const captured_stone: Stone = position.stones[captured_root];
    const capturing_stone: Stone = captured_stone.opponent();
    const captured_points: PointSet = position.group_stones[captured_root];

    // Empty every point of the group. The root's sets go with it; the others were emptied when their groups joined.
    var points_to_empty: PointSet.Iterator(.{}) = captured_points.iterator(.{});
    while (points_to_empty.next()) |point_index| {
        const emptied_point: Point = @intCast(point_index);
        position.stones[emptied_point] = .none;
        position.group_parent[emptied_point] = null;
    }
    position.group_stones[captured_root] = .empty;

    // Give each emptied point to the capturing groups beside it.
    var points_to_give: PointSet.Iterator(.{}) = captured_points.iterator(.{});
    while (points_to_give.next()) |point_index| {
        const emptied_point: Point = @intCast(point_index);
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        const neighbors: []const Point = neighborsOf(position.board_size, emptied_point, &neighbor_buffer);
        for (neighbors) |neighbor| {
            const neighbor_is_capturer: bool = position.stones[neighbor] == capturing_stone;
            if (neighbor_is_capturer) {
                const capturer_root: Point = findRootCompressingPath(position, neighbor);
                position.group_liberties[capturer_root].set(emptied_point);
            }
        }
    }
    return captured_points;
}

// ===== 3. The rules =====
//
// A move is one stone placed by the player to move. Whether it may be played is decided by checkMove, from four
// conditions; what it does to the board is placeStone, which follows the rules in the order they apply:
//
//   1. the stone stands on the point, a group of one;
//   2. its empty neighbours are its liberties, and every group beside it loses this point as a liberty;
//   3. it joins the groups of its own colour beside it, into one group with the new stone as root;
//   4. every enemy group beside it that has no liberty left is captured;
//   5. the ko point is set if the move took exactly one stone back and forth (below);
//   6. the prisoners are counted, an Atari Go win is noted, and the turn passes.
//
// Captures come before the suicide question. A stone that fills an enemy group's last liberty captures it, and the
// emptied points become its own liberties, so a move that looks like suicide is legal when it captures. That is why
// wouldBeSuicide counts an enemy neighbour with one liberty as a way out.
//
// KO. Black captures one white stone by playing into the point it was attacking from; if White could at once play
// back on the emptied point, capturing Black's stone, the two could repeat forever:
//
//       . X O .                . X O .                . X O .
//       X O . O     Black      X . X O     White      X O . O     the same position again
//       . X O .     plays      . X O .     retakes    . X O .
//
// So the point of a single captured stone is forbidden for one turn - but only when the capture has that shape: the
// capturing stone stands alone, and its one liberty is the point it just emptied, so a retake there would capture it
// in turn. Any other capture of one stone leaves the point open. In a SNAPBACK, the stone that captures one joins a
// group of its own colour that is left with that point as its one liberty; the opponent may play there at once and
// capture the whole group, which is legal Go. A ko rule that forbade the point after every capture of one stone
// would refuse snapbacks.
//
// PROBLEMS. A go problem is played as a capture: one stone is its TARGET, and capturing it wins for its opponent - in
// a kill problem black captures a white target, in a life problem white must not capture a black one. Its moves are
// played in its REGION, the box around its stones and one line beyond; a move outside it is refused like an illegal
// one, so a player's input and the computer's search both stay inside.
//
// UNCONDITIONAL LIFE (Benson's algorithm, 1976). A group is alive unconditionally when the opponent cannot capture it
// however he plays, even if its owner never moves again. Take the board's chains of one colour, and its regions - the
// connected sets of points with no stone of that colour. A region is VITAL to a chain beside it when every empty point
// of it is that chain's liberty: the opponent could only fill it by playing on the chain's liberties, and a chain
// with two such regions keeps one empty to the end. So, until nothing changes, every chain with fewer than two vital
// regions is set aside, and every region beside a chain set aside goes with it - a region bounded partly by a chain
// that may die is no safe eye for the rest. What is left is alive:
//
//       . X . X O        two eyes, (0, 0) and (0, 2): each a region of one empty point that is black's
//       X X X X O        liberty, so both vital - alive. With one eye only, or in a seki, whose shared
//       O O O O O        liberties are no chain's alone, the group is not proven alive, though a seki lives.

/// Why a move may not be played - or that it may.
pub const Legality = enum {
    /// The move may be played.
    legal,
    /// A stone already stands on the point.
    occupied,
    /// The point is the ko point: playing there would retake a single stone at once.
    ko,
    /// The stone would be left with no liberty, and it captures nothing.
    suicide,
    /// An Atari Go game is won, or a problem solved, and no more moves are played in it.
    game_over,
    /// A problem's move outside the problem's region.
    outside_problem,
};

/// What a move did: for the move log, the prisoners' flights and the tests.
pub const MoveReport = struct {
    /// Where the stone was placed.
    placed: Point,
    /// Who placed it.
    mover: Stone,
    /// How many groups of the mover's colour the new stone joined into one with itself: 0 for a stone standing alone.
    groups_joined: u8,
    /// The points emptied by captures.
    captured: PointSet,
    /// How many stones were captured: `captured.count()`.
    captured_count: u32,
    /// The ko point the move left for the opponent, if any.
    ko_point: ?Point,
};

/// Would a stone of the player to move, placed on the empty `point`, be left with no liberty? It survives if any
/// neighbour gives it a way out:
///   - an empty neighbour is a liberty of its own;
///   - a friendly group with 2 or more liberties still has one after this stone fills one, and the stone joins it;
///   - an enemy group with exactly 1 liberty - this point - is captured, and its stones' points become liberties.
/// If no neighbour does any of those, the move is suicide.
/// Read-only: roots are looked up with findRoot, which never reshapes the forest.
pub fn wouldBeSuicide(position: *const Position, point: Point) bool {
    assertf(position.stones[point] == .none, @src(), "wouldBeSuicide asked about occupied point {d}", .{point});
    const mover: Stone = position.player_to_move;
    const enemy: Stone = mover.opponent();

    var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
    const neighbors: []const Point = neighborsOf(position.board_size, point, &neighbor_buffer);
    for (neighbors) |neighbor| {
        const neighbor_stone: Stone = position.stones[neighbor];

        const neighbor_is_empty: bool = neighbor_stone == .none;
        if (neighbor_is_empty) {
            return false;
        }

        const neighbor_root: Point = findRoot(position, neighbor);
        const neighbor_liberty_count: usize = position.group_liberties[neighbor_root].count();

        const friend_keeps_a_liberty: bool = neighbor_stone == mover and neighbor_liberty_count >= 2;
        if (friend_keeps_a_liberty) {
            return false;
        }

        const enemy_gets_captured: bool = neighbor_stone == enemy and neighbor_liberty_count == 1;
        if (enemy_gets_captured) {
            return false;
        }
    }
    return true;
}

/// May the player to move place a stone on `point`, and if not, why not? The one definition of a legal move, asked by
/// everything that needs to know, so the answer cannot differ from one place to another. Read-only.
pub fn checkMove(position: *const Position, point: Point) Legality {
    assertf(point < pointCount(position.board_size), @src(), "checkMove: point {d} is off a {d} x {d} board", .{
        point,
        position.board_size,
        position.board_size,
    });
    const game_is_won: bool = position.winner != null;
    if (game_is_won) {
        return .game_over;
    }
    if (position.region) |region| {
        if (!region.contains(position.board_size, point)) {
            return .outside_problem;
        }
    }
    const point_is_occupied: bool = position.stones[point] != .none;
    if (point_is_occupied) {
        return .occupied;
    }
    const point_is_ko: bool = position.ko_point == point;
    if (point_is_ko) {
        return .ko;
    }
    const move_is_suicide: bool = wouldBeSuicide(position, point);
    if (move_is_suicide) {
        return .suicide;
    }
    return .legal;
}

/// Plays a legal move: a stone of the player to move on `point`, then everything the rules make follow from it, in
/// the six steps of the section's lesson. Returns what the move did.
pub fn placeStone(position: *Position, point: Point) MoveReport {
    const legality: Legality = checkMove(position, point);
    assertf(legality == .legal, @src(), "placeStone: point {d} is not a legal move ({t})", .{ point, legality });
    const mover: Stone = position.player_to_move;
    const enemy: Stone = mover.opponent();
    var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
    const neighbors: []const Point = neighborsOf(position.board_size, point, &neighbor_buffer);

    // 1. The stone stands on the point, a group of one: its own parent, its own stone set.
    position.stones[point] = mover;
    position.group_parent[point] = point;
    position.group_stones[point] = .empty;
    position.group_stones[point].set(point);
    position.group_liberties[point] = .empty;

    // 2. Each empty neighbour is a liberty of the new stone. Each group beside it, of either colour, has just lost
    //    this point as a liberty.
    for (neighbors) |neighbor| {
        const neighbor_is_empty: bool = position.stones[neighbor] == .none;
        if (neighbor_is_empty) {
            position.group_liberties[point].set(neighbor);
        } else {
            const neighbor_root: Point = findRootCompressingPath(position, neighbor);
            position.group_liberties[neighbor_root].unset(point);
        }
    }

    // 3. Join the friendly groups beside it. The new stone stays the root, so each joined group hangs under it.
    var groups_joined: u8 = 0;
    for (neighbors) |neighbor| {
        const neighbor_is_friend: bool = position.stones[neighbor] == mover;
        if (neighbor_is_friend) {
            const neighbor_root: Point = findRootCompressingPath(position, neighbor);
            const joined_a_group: bool = joinGroups(position, point, neighbor_root);
            if (joined_a_group) {
                groups_joined += 1;
            }
        }
    }

    // 4. Capture every enemy group beside it that has no liberty left. A group touching the stone on two sides is
    //    found again from the second side after it is gone; by then that side is an empty point, so it is skipped.
    var captured: PointSet = .empty;
    for (neighbors) |neighbor| {
        const neighbor_is_enemy: bool = position.stones[neighbor] == enemy;
        if (neighbor_is_enemy) {
            const neighbor_root: Point = findRootCompressingPath(position, neighbor);
            const enemy_liberty_count: usize = position.group_liberties[neighbor_root].count();
            const enemy_is_captured: bool = enemy_liberty_count == 0;
            if (enemy_is_captured) {
                const emptied_points: PointSet = removeCapturedGroup(position, neighbor_root);
                captured.setUnion(emptied_points);
            }
        }
    }
    const captured_count: u32 = @intCast(captured.count());

    // 5. Ko: the point of a single captured stone is forbidden to the opponent for one turn, when the capturing stone
    //    stands alone with that point as its one liberty - the shape in which retaking there would capture it back.
    const captured_one_stone: bool = captured_count == 1;
    const mover_root: Point = findRoot(position, point);
    const mover_stands_alone: bool = position.group_stones[mover_root].count() == 1;
    const mover_has_one_liberty: bool = position.group_liberties[mover_root].count() == 1;
    const is_ko_shape: bool = captured_one_stone and mover_stands_alone and mover_has_one_liberty;
    var ko_point: ?Point = null;
    if (is_ko_shape) {
        const emptied_point: Point = @intCast(captured.findFirstSet().?);
        ko_point = emptied_point;
    }
    position.ko_point = ko_point;

    // 6. Count the prisoners, note an Atari Go win, and pass the turn.
    var mover_prisoners: u32 = 0;
    if (mover == .black) {
        position.stones_captured_by_black += captured_count;
        mover_prisoners = position.stones_captured_by_black;
    } else {
        position.stones_captured_by_white += captured_count;
        mover_prisoners = position.stones_captured_by_white;
    }
    if (position.capture_goal) |capture_goal| {
        const goal_reached: bool = mover_prisoners >= capture_goal;
        if (goal_reached) {
            position.winner = mover;
        }
    }
    // A problem is won when its target's point is emptied: only the target's opponent can capture it, the mover.
    if (position.target) |target| {
        const target_is_captured: bool = position.stones[target] == .none;
        if (target_is_captured) {
            position.winner = mover;
        }
    }
    position.last_move = point;
    position.player_to_move = enemy;

    const report: MoveReport = .{
        .placed = point,
        .mover = mover,
        .groups_joined = groups_joined,
        .captured = captured,
        .captured_count = captured_count,
        .ko_point = ko_point,
    };
    return report;
}

/// How many stones `capturer` has captured: its prisoners.
pub fn prisonersOf(position: *const Position, capturer: Stone) u32 {
    if (capturer == .black) {
        return position.stones_captured_by_black;
    }
    return position.stones_captured_by_white;
}

/// The groups a move on `point` would capture, as their roots, written into the caller's buffer: the enemy groups
/// beside the point whose one liberty is the point. A group touching the point on two sides is listed once - it is
/// found again from the second side with the same root - and a move that is not legal captures nothing, so nothing is
/// listed for it (the ko point, an occupied point). Read-only: the roots are found with findRoot.
///
///       . X X .        black to play on (2,2): the white group of three has (2,2) as its one liberty.
///       X O O X        It touches (2,2) twice - from above and from the left - and is listed once.
///       X O . X
///       . X X .
pub fn groupsCapturedBy(
    position: *const Position,
    point: Point,
    out_buffer: *[board_limits.max_neighbors]Point,
) []const Point {
    var captured_roots: ArrayList(Point) = .initBuffer(out_buffer);
    const move_is_legal: bool = checkMove(position, point) == .legal;
    if (!move_is_legal) {
        return captured_roots.items;
    }
    const enemy: Stone = position.player_to_move.opponent();
    var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
    const neighbors: []const Point = neighborsOf(position.board_size, point, &neighbor_buffer);
    for (neighbors) |neighbor| {
        const neighbor_is_enemy: bool = position.stones[neighbor] == enemy;
        if (!neighbor_is_enemy) {
            continue;
        }
        const neighbor_root: Point = findRoot(position, neighbor);
        const in_atari: bool = position.group_liberties[neighbor_root].count() == 1;
        const already_listed: bool = indexOfScalar(Point, captured_roots.items, neighbor_root) != null;
        if (in_atari and !already_listed) {
            captured_roots.appendAssumeCapacity(neighbor_root);
        }
    }
    return captured_roots.items;
}

/// The groups touching `point` - of either colour - as their roots, written into the caller's buffer, each listed once
/// however many sides of the point it touches. Read-only: the roots are found with findRoot.
pub fn groupsTouching(
    position: *const Position,
    point: Point,
    out_buffer: *[board_limits.max_neighbors]Point,
) []const Point {
    var touching_roots: ArrayList(Point) = .initBuffer(out_buffer);
    var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
    const neighbors: []const Point = neighborsOf(position.board_size, point, &neighbor_buffer);
    for (neighbors) |neighbor| {
        const neighbor_is_empty: bool = position.stones[neighbor] == .none;
        if (neighbor_is_empty) {
            continue;
        }
        const neighbor_root: Point = findRoot(position, neighbor);
        const already_listed: bool = indexOfScalar(Point, touching_roots.items, neighbor_root) != null;
        if (!already_listed) {
            touching_roots.appendAssumeCapacity(neighbor_root);
        }
    }
    return touching_roots.items;
}

/// The position a legal move on `point` would make, written into `after`; `position` is left as it is. What the
/// overlays read to show a move's consequences before it is played: the group the stone would join, the liberties each
/// group around it would have, the groups it would take. `after` is caller storage - a whole position is too large for
/// a frame's stack on every platform.
pub fn positionAfterMove(
    position: *const Position,
    point: Point,
    after: *Position,
) MoveReport {
    after.* = position.*;
    const report: MoveReport = placeStone(after, point);
    return report;
}

/// One region of Benson's algorithm (`aliveStones`): a connected set of points with no stone of the colour asked about,
/// its empty points, and the roots of that colour's chains beside it.
const BensonRegion = struct {
    empty_points: PointSet,
    bordering_roots: PointSet,
    is_left: bool,
};

/// The stones of `colour` that are alive unconditionally (the section's lesson: Benson's algorithm) - alive whatever
/// the opponent plays, though their owner never move again. Each region - a connected set of points with no stone of
/// that colour - is VITAL to a chain beside it when every empty point of it is the chain's liberty: an eye the
/// opponent can fill only by playing on the chain's liberties. Then, until nothing changes, every chain with fewer
/// than two vital regions is set aside, and every region beside a chain set aside with it; what is left is alive.
/// The stones of every chain left, as one set.
pub fn aliveStones(position: *const Position, colour: Stone) PointSet {
    const board_size: u8 = position.board_size;
    var regions_buffer: [board_limits.max_points]BensonRegion = undefined;
    var region_count: usize = 0;
    var visited: PointSet = .empty;
    var stack_buffer: [board_limits.max_points]Point = undefined;
    for (0..pointCount(board_size)) |point_index| {
        const start: Point = @intCast(point_index);
        if (position.stones[start] == colour or visited.isSet(start)) {
            continue;
        }
        // One region, flood-filled across every point that is not the colour's.
        var region: BensonRegion = .{ .empty_points = .empty, .bordering_roots = .empty, .is_left = true };
        var stack: ArrayList(Point) = .initBuffer(&stack_buffer);
        stack.appendAssumeCapacity(start);
        visited.set(start);
        while (stack.pop()) |point| {
            if (position.stones[point] == .none) {
                region.empty_points.set(point);
            }
            var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
            for (neighborsOf(board_size, point, &neighbor_buffer)) |neighbor| {
                if (position.stones[neighbor] == colour) {
                    region.bordering_roots.set(findRoot(position, neighbor));
                } else if (!visited.isSet(neighbor)) {
                    visited.set(neighbor);
                    stack.appendAssumeCapacity(neighbor);
                }
            }
        }
        regions_buffer[region_count] = region;
        region_count += 1;
    }
    const regions: []BensonRegion = regions_buffer[0..region_count];

    var chains_left: PointSet = .empty;
    for (0..pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        if (position.stones[point] == colour and isRoot(position, point)) {
            chains_left.set(point);
        }
    }
    var something_changed: bool = true;
    while (something_changed) {
        something_changed = false;
        // Every chain with fewer than two vital regions among those left is set aside.
        var roots: PointSet.Iterator(.{}) = chains_left.iterator(.{});
        while (roots.next()) |root_index| {
            const root: Point = @intCast(root_index);
            const liberties: PointSet = position.group_liberties[root];
            var vital_count: u32 = 0;
            for (regions) |region| {
                const is_vital: bool = region.is_left and region.bordering_roots.isSet(root) and
                    region.empty_points.count() > 0 and region.empty_points.subsetOf(liberties);
                vital_count += @intFromBool(is_vital);
            }
            if (vital_count < 2) {
                chains_left.unset(root);
                something_changed = true;
            }
        }
        // Every region beside a chain set aside goes with it.
        for (regions) |*region| {
            if (region.is_left and !region.bordering_roots.subsetOf(chains_left)) {
                region.is_left = false;
                something_changed = true;
            }
        }
    }

    var alive: PointSet = .empty;
    var roots: PointSet.Iterator(.{}) = chains_left.iterator(.{});
    while (roots.next()) |root_index| {
        alive.setUnion(position.group_stones[root_index]);
    }
    return alive;
}

/// Whether the chain at `point` is alive unconditionally (`aliveStones`).
pub fn isUnconditionallyAlive(position: *const Position, point: Point) bool {
    const colour: Stone = position.stones[point];
    if (colour == .none) {
        return false;
    }
    return aliveStones(position, colour).isSet(point);
}

// ===== 4. The record =====
//
// A Position says what is on the board; it does not say how the game got there. The Record does: the board size, the
// Atari Go capture goal, the stones that stood on the board before the first move (the SETUP), and the moves, one
// point each. Replaying the record on an empty board rebuilds the position - stones, forest, prisoners, ko point and
// winner - because placeStone decides all of them from the moves alone.
//
// Undo and redo are replays. The record keeps every move played so far, and `moves_played` says how many of them the
// position shows; undo replays one move fewer, redo one more. A new move played after an undo replaces the moves
// that were undone:
//
//       moves:  m0 m1 m2 m3 m4              moves_recorded = 5
//                        ^ moves_played = 3   (the position shows m0 m1 m2; redo would play m3 again)
//
//       play m5 here:   m0 m1 m2 m5          moves_recorded = moves_played = 4   (m3 and m4 are gone)
//
// Replaying a game of a few hundred moves is a few thousand set operations, which is far below a frame's time, and it
// leaves nothing to undo by hand: there is no "un-capture" and no "un-join", only the moves.
//
// SETUP STONES. Atari Go starts from four stones in a square at the centre of the board, black on one diagonal and
// white on the other, so that the first moves already touch:
//
//       . . . .            the square's top-left corner is at row board_size / 2 - 1 and the same column
//       . X O .
//       . O X .
//       . . . .
//
// Those stones are part of the record but are not moves: undo stops at them, and the last-move marker never points
// at one. Each is put on the board by placeStone - so the forest grows exactly as it would for moves - and then the
// move-only facts (the last move, the ko point) are cleared. A setup must leave every group a liberty; then no setup
// stone captures, which putSetupStone asserts. On a 3 x 3 board the square would take both liberties of its corner
// stone, so Atari Go needs a board of 4 x 4 or more.
//
// SCATTERED STONES. A game can start with a few more stones around the square - drawn at random for each game - so
// that no two games open alike. They stand on the second line from the edge, never the edge itself, at least 2 from
// the square (counting the larger of the row and column steps to its nearest stone), so none touches it:
//
//       . . . . . . . .
//       . X . . . . O .         8 x 8 with three scattered stones on the second line, which is
//       . . . . . . . .         20 points around the square here: none on the edge, none touching
//       . . . X O . . .         the square or another
//       . . . O X . . .
//       . . . . . . . .
//       . X . . . . . .
//       . . . . . . . .
//
// How many are black and how many white is the settings' to say: goban's menu offers 2 or 4, half of each colour, and
// a game made another way can set any split - goban outposts climbs a ladder of them (`OutpostLadder`). The colours
// are shuffled and each stone drawn on its own; its neighbours then leave the candidates, so no two scattered stones
// touch and none starts in atari. A stone takes its point and at most four neighbours, so k stones always fit a board
// with at least 1 + 5 (k - 1) candidates: two from 7 x 7, four from 8 x 8 - on 6 x 6 the second line is next to the
// square.

/// The record's capacity. A move past it is refused (`recordIsFull`).
pub const record_limits = struct {
    /// Moves kept per game: more than a 19 x 19 game takes.
    pub const max_moves: usize = 1024;
};

/// The rules of Atari Go that the board size depends on.
pub const atari_go = struct {
    /// The smallest board Atari Go is played on: on 3 x 3, the starting square takes both liberties of its corner
    /// stone, which the setup would capture.
    pub const min_board_size: u8 = 4;
};

/// A stone that stands on the board before the first move: part of the record, not a move.
pub const SetupStone = struct {
    point: Point,
    stone: Stone,
};

/// Stones scattered on the board before the first move, around Atari Go's starting square (the section's lesson):
/// so many black and so many white, each drawn at random from the lines `nearest_line` to `farthest_line` from the
/// edge - the second by default, never the edge itself - at least `min_distance_from_square` from the square.
pub const ScatteredStones = struct {
    black_count: u8 = 0,
    white_count: u8 = 0,
    /// How near the square a stone may stand: the larger of the row and column steps to the square's nearest stone.
    /// 2, which leaves a line between a stone and the square.
    min_distance_from_square: u8 = 2,
    /// The lines a stone may stand on, counted from the edge: 0 the edge, 1 the second line, 2 the third.
    nearest_line: u8 = 1,
    farthest_line: u8 = 1,
    /// Whether a stone keeps out from in front of the square: level with its rows or its columns, at the nearest
    /// distance allowed - one empty line between - where a stone of either colour starts a ladder against the
    /// square's stones at once (`isInFrontOfSquare`).
    keeps_square_front_clear: bool = false,
    /// The seed of the random draw: the same seed, the same stones.
    seed: u64 = 0,

    /// The most stones there can be.
    pub const max_count: u8 = 8;
    /// The counts the main menu offers, half of each colour.
    pub const counts = [_]u8{ 0, 2, 4 };

    /// `count` stones, half black and half white.
    pub fn evenly(count: u8) ScatteredStones {
        const half: u8 = count / 2;
        const stones: ScatteredStones = .{ .black_count = count - half, .white_count = half };
        return stones;
    }

    /// How many stones, both colours.
    pub fn total(scattered: ScatteredStones) u8 {
        return scattered.black_count + scattered.white_count;
    }
};

/// What a new game is played with.
pub const NewGameSettings = struct {
    /// Points per side, board_limits.min_size .. board_limits.max_size (atari_go.min_board_size for Atari Go).
    board_size: u8,
    /// Atari Go: the first player to capture this many stones wins. Null for plain Go.
    capture_goal: ?u8,
    /// Atari Go: stones scattered around the starting square. None by default.
    scattered: ScatteredStones = .{},
    /// Who moves first: black, as in Go - or white, for a game whose ladder (`OutpostLadder`) gives the person the
    /// second move. Atari Go's square is its own mirror with its colours swapped, so white moving first is as fair.
    first_player: Stone = .black,
};

/// How the game got to its position: replaying it from an empty board rebuilds the position.
pub const Record = struct {
    /// Points per side.
    board_size: u8,
    /// Atari Go's capture goal, or null for plain Go.
    capture_goal: ?u8,
    /// A problem's target and region (section 3's lesson); null in a game.
    target: ?Point = null,
    region: ?ProblemRegion = null,
    /// The stones on the board before the first move; only `setup[0..setup_count]` are meaningful.
    setup: [board_limits.max_points]SetupStone,
    setup_count: u16,
    /// Whose turn it is once the setup stands.
    setup_to_play: Stone,
    /// The moves, one point each; only `moves[0..moves_recorded]` are meaningful.
    moves: [record_limits.max_moves]Point,
    /// How many moves the record holds: the end that redo can reach.
    moves_recorded: u16,
    /// How many of them the position shows: `moves_played <= moves_recorded`.
    moves_played: u16,
};

/// A game: the position on the board, and the record it was replayed from. They are kept together so that every
/// change goes through the functions below, which keep the two in agreement.
pub const Game = struct {
    position: Position,
    record: Record,
};

/// Puts a setup stone on the board: placed by placeStone, so the forest grows as it would for a move, then stripped of
/// what only a move leaves - the last-move marker and the ko point. The turn is left to the caller.
pub fn putSetupStone(position: *Position, setup_stone: SetupStone) void {
    assertf(setup_stone.stone != .none, @src(), "putSetupStone: setup stone on {d} has no colour", .{
        setup_stone.point,
    });
    position.player_to_move = setup_stone.stone;
    const report: MoveReport = placeStone(position, setup_stone.point);
    assertf(report.captured_count == 0, @src(), "putSetupStone: setup stone on {d} captured {d} stones", .{
        setup_stone.point,
        report.captured_count,
    });
    position.last_move = null;
    position.ko_point = null;
}

/// Rebuilds the position from the record: an empty board, the setup, then the first `moves_played` moves.
pub fn replayTo(game: *Game, moves_played: u16) void {
    const record: *Record = &game.record;
    assertf(moves_played <= record.moves_recorded, @src(), "replayTo({d}) past the {d} moves recorded", .{
        moves_played,
        record.moves_recorded,
    });
    game.position = Position.init(record.board_size);
    const position: *Position = &game.position;
    position.capture_goal = record.capture_goal;

    for (record.setup[0..record.setup_count]) |setup_stone| {
        putSetupStone(position, setup_stone);
    }
    position.player_to_move = record.setup_to_play;
    // A problem's target and region once its stones stand: the target's point is empty until its stone is put.
    position.target = record.target;
    position.region = record.region;

    for (record.moves[0..moves_played]) |move_point| {
        _ = placeStone(position, move_point);
    }
    record.moves_played = moves_played;
}

/// May a game with this capture goal (null for plain Go) be played on a board of this size? Plain Go needs
/// board_limits.min_size points per side and Atari Go atari_go.min_board_size; neither may exceed
/// board_limits.max_size. startGame asserts it; whatever offers board sizes can ask it first.
pub fn allowsBoardSize(capture_goal: ?u8, board_size: u8) bool {
    const is_atari_go: bool = capture_goal != null;
    var min_size: u8 = board_limits.min_size;
    if (is_atari_go) {
        min_size = atari_go.min_board_size;
    }
    const size_is_allowed: bool = board_size >= min_size and board_size <= board_limits.max_size;
    return size_is_allowed;
}

/// The top-left stone's row and column of Atari Go's starting square on a board this size: the square is that point,
/// the one right of it, and the two below.
pub fn startingSquareCorner(board_size: u8) u8 {
    return board_size / 2 - 1;
}

/// How many steps `index` is outside `first` .. `last`: 0 within it.
fn stepsOutside(index: u8, first: u8, last: u8) u8 {
    if (index < first) {
        return first - index;
    }
    if (index > last) {
        return index - last;
    }
    return 0;
}

/// How far `point` is from Atari Go's starting square: the larger of its row and column steps to the square's
/// nearest stone - so the points at one distance make a square ring around it.
pub fn distanceFromStartingSquare(board_size: u8, point: Point) u8 {
    const square_first: u8 = startingSquareCorner(board_size);
    const square_last: u8 = square_first + 1;
    const row_steps: u8 = stepsOutside(rowOf(board_size, point), square_first, square_last);
    const col_steps: u8 = stepsOutside(colOf(board_size, point), square_first, square_last);
    return @max(row_steps, col_steps);
}

/// How many lines `point` is in from the board's nearest edge: 0 on the edge, 1 on the second line.
pub fn linesFromEdge(board_size: u8, point: Point) u8 {
    const row: u8 = rowOf(board_size, point);
    const col: u8 = colOf(board_size, point);
    const last: u8 = board_size - 1;
    return @min(@min(row, last - row), @min(col, last - col));
}

/// Whether `point` stands in front of the starting square, `distance` steps from it (`ScatteredStones`): in one of the
/// square's two rows, that many columns out from it, or in one of its two columns, that many rows out.
fn isInFrontOfSquare(board_size: u8, point: Point, distance: u8) bool {
    const square_first: u8 = board_size / 2 - 1;
    const square_last: u8 = square_first + 1;
    const row_steps: u8 = stepsOutside(rowOf(board_size, point), square_first, square_last);
    const col_steps: u8 = stepsOutside(colOf(board_size, point), square_first, square_last);
    const level_with_rows: bool = row_steps == 0 and col_steps == distance;
    const level_with_cols: bool = col_steps == 0 and row_steps == distance;
    return level_with_rows or level_with_cols;
}

/// The points a scattered stone may stand on (the section's lesson): those of the lines from
/// `scattered.nearest_line` to `scattered.farthest_line` from the edge at least `scattered.min_distance_from_square`
/// from the square - and, with `scattered.keeps_square_front_clear`, not in front of it at that distance.
fn scatterCandidates(
    board_size: u8,
    scattered: ScatteredStones,
    out_buffer: *[board_limits.max_points]Point,
) ArrayList(Point) {
    var candidates: ArrayList(Point) = .initBuffer(out_buffer);
    for (0..pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const line: u8 = linesFromEdge(board_size, point);
        const on_allowed_line: bool = line >= scattered.nearest_line and line <= scattered.farthest_line;
        const steps_from_square: u8 = distanceFromStartingSquare(board_size, point);
        const clear_of_square: bool = steps_from_square >= scattered.min_distance_from_square;
        const in_front: bool = scattered.keeps_square_front_clear and
            isInFrontOfSquare(board_size, point, scattered.min_distance_from_square);
        if (on_allowed_line and clear_of_square and !in_front) {
            candidates.appendAssumeCapacity(point);
        }
    }
    return candidates;
}

/// Whether `scattered`'s stones always fit a board this size: the first stone needs one candidate point, and each
/// stone after it takes its own and those of its neighbours that are candidates, which no later stone may take - on
/// the second line, at most two, the points beside it along the line. So k stones always fit at 1 + (1 + m) (k - 1)
/// candidates, m the most candidate neighbours any candidate has.
pub fn scatteredStonesFit(board_size: u8, scattered: ScatteredStones) bool {
    const stone_count: usize = scattered.total();
    if (stone_count == 0) {
        return true;
    }
    if (board_size < atari_go.min_board_size or stone_count > ScatteredStones.max_count) {
        return false;
    }
    var candidate_buffer: [board_limits.max_points]Point = undefined;
    const candidates: ArrayList(Point) = scatterCandidates(board_size, scattered, &candidate_buffer);
    var most_candidate_neighbors: usize = 0;
    for (candidates.items) |candidate| {
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        var candidate_neighbors: usize = 0;
        for (neighborsOf(board_size, candidate, &neighbor_buffer)) |neighbor| {
            const neighbor_is_candidate: bool = indexOfScalar(Point, candidates.items, neighbor) != null;
            candidate_neighbors += @intFromBool(neighbor_is_candidate);
        }
        most_candidate_neighbors = @max(most_candidate_neighbors, candidate_neighbors);
    }
    const points_needed: usize = 1 + (1 + most_candidate_neighbors) * (stone_count - 1);
    return candidates.items.len >= points_needed;
}

/// The smallest board on which `scattered`'s stones always fit, or null when none does.
pub fn smallestBoardForScatteredStones(scattered: ScatteredStones) ?u8 {
    for (atari_go.min_board_size..board_limits.max_size + 1) |size| {
        const board_size: u8 = @intCast(size);
        if (scatteredStonesFit(board_size, scattered)) {
            return board_size;
        }
    }
    return null;
}

/// Adds `scattered`'s stones to `record`'s setup, after Atari Go's square (the section's lesson): the colours shuffled;
/// each stone on a candidate drawn at random, and its point's neighbours struck from the candidates, so that no two
/// scattered stones touch and none starts in atari. Returns false, adding nothing, when the stones do not fit
/// (`scatteredStonesFit`).
fn scatterStones(record: *Record, scattered: ScatteredStones) bool {
    const board_size: u8 = record.board_size;
    if (!scatteredStonesFit(board_size, scattered)) {
        return false;
    }
    var generator: Xoshiro256 = .init(scattered.seed);
    const random: Random = generator.random();
    assertf(scattered.total() <= ScatteredStones.max_count, @src(), "scatterStones: {d} stones, {d} at the most", .{
        scattered.total(),
        ScatteredStones.max_count,
    });
    var colours: [ScatteredStones.max_count]Stone = undefined;
    const stone_count: usize = scattered.total();
    for (colours[0..stone_count], 0..) |*colour, stone_index| {
        colour.* = if (stone_index < scattered.black_count) .black else .white;
    }
    random.shuffle(Stone, colours[0..stone_count]);
    var candidate_buffer: [board_limits.max_points]Point = undefined;
    var candidates: ArrayList(Point) = scatterCandidates(board_size, scattered, &candidate_buffer);
    for (colours[0..stone_count]) |colour| {
        const drawn_index: usize = random.uintLessThan(usize, candidates.items.len);
        const point: Point = candidates.swapRemove(drawn_index);
        record.setup[record.setup_count] = .{ .point = point, .stone = colour };
        record.setup_count += 1;
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        for (neighborsOf(board_size, point, &neighbor_buffer)) |neighbor| {
            if (indexOfScalar(Point, candidates.items, neighbor)) |neighbor_index| {
                _ = candidates.swapRemove(neighbor_index);
            }
        }
    }
    return true;
}

/// Starts a new game: an empty record with the settings' size and goal, the Atari Go square as its setup when there
/// is a capture goal - and the settings' scattered stones around it - and the position replayed from it.
pub fn startGame(game: *Game, settings: NewGameSettings) void {
    const board_size: u8 = settings.board_size;
    const is_atari_go: bool = settings.capture_goal != null;
    assertf(allowsBoardSize(settings.capture_goal, board_size), @src(), "startGame: no game on a {d} x {d} board", .{
        board_size,
        board_size,
    });

    game.record = .{
        .board_size = board_size,
        .capture_goal = settings.capture_goal,
        .setup = @splat(.{ .point = 0, .stone = .none }),
        .setup_count = 0,
        .setup_to_play = settings.first_player,
        .moves = @splat(0),
        .moves_recorded = 0,
        .moves_played = 0,
    };

    if (is_atari_go) {
        const square_row: u8 = startingSquareCorner(board_size);
        const square_col: u8 = startingSquareCorner(board_size);
        const square: [4]SetupStone = .{
            .{ .point = pointAt(board_size, square_row, square_col), .stone = .black },
            .{ .point = pointAt(board_size, square_row, square_col + 1), .stone = .white },
            .{ .point = pointAt(board_size, square_row + 1, square_col + 1), .stone = .black },
            .{ .point = pointAt(board_size, square_row + 1, square_col), .stone = .white },
        };
        @memcpy(game.record.setup[0..square.len], &square);
        game.record.setup_count = square.len;
        const scattered_fit: bool = scatterStones(&game.record, settings.scattered);
        assertf(scattered_fit, @src(), "startGame: {d} scattered stones do not fit a {d} x {d} board", .{
            settings.scattered.total(),
            board_size,
            board_size,
        });
    }
    replayTo(game, 0);
}

/// Has the record no room for one more move after the ones the position shows? Moves undone do not count: a new move
/// replaces them.
pub fn recordIsFull(record: *const Record) bool {
    const moves_played: usize = record.moves_played;
    const is_full: bool = moves_played >= record_limits.max_moves;
    return is_full;
}

/// Plays a legal move and records it. A move played after an undo replaces the moves that were undone, so the record
/// ends with it. Returns what the move did.
pub fn playMove(game: *Game, point: Point) MoveReport {
    const record: *Record = &game.record;
    assertf(!recordIsFull(record), @src(), "playMove: the record is full at {d} moves", .{record.moves_played});

    const report: MoveReport = placeStone(&game.position, point);
    record.moves[record.moves_played] = point;
    record.moves_played += 1;
    record.moves_recorded = record.moves_played;
    return report;
}

/// Takes back the last move shown, by replaying one move fewer. Returns false when there is no move to take back -
/// the setup stays.
pub fn undo(game: *Game) bool {
    const has_move_to_undo: bool = game.record.moves_played > 0;
    if (!has_move_to_undo) {
        return false;
    }
    replayTo(game, game.record.moves_played - 1);
    return true;
}

/// Who made the record's move at `move_index`: the setup's player made the first, and the players took turns after
/// it - goban has no passes, so a move's number says whose it was.
pub fn moverOfMove(record: *const Record, move_index: u16) Stone {
    const made_by_setup_player: bool = move_index % 2 == 0;
    if (made_by_setup_player) {
        return record.setup_to_play;
    }
    return record.setup_to_play.opponent();
}

/// Plays again the next move that was undone. Returns false when no move is waiting.
pub fn redo(game: *Game) bool {
    const has_move_to_redo: bool = game.record.moves_played < game.record.moves_recorded;
    if (!has_move_to_redo) {
        return false;
    }
    replayTo(game, game.record.moves_played + 1);
    return true;
}

/// Goes on with a won Atari Go game as plain Go: the record's capture goal is dropped and the position replayed, so the
/// win - which replaying decides from the moves - is gone, and undo and redo do not bring it back. Only this game
/// changes: whatever starts the next game keeps its own settings.
pub fn continueAsPlainGo(game: *Game) void {
    game.record.capture_goal = null;
    replayTo(game, game.record.moves_played);
}

// ===== 5. Checking the forest =====
//
// The forest is fast because it remembers: each root keeps its group's stones and liberties, and every move updates
// them. A mistake in an update would not show at once - it would sit in a set until a capture came out wrong many
// moves later. So the forest gets an independent check: recompute every group from the stones alone, and compare.
//
// The recomputation is a FLOOD FILL, the simplest way to find a group. Start at a stone; its neighbours of the same
// colour are in its group, and so are theirs, until no new stone is found; every empty neighbour met on the way is a
// liberty. It reads nothing but the stones, so it shares nothing with the forest it checks:
//
//       X X .        start at (0,0): visit (0,0) -> its neighbour (0,1) -> its neighbour (1,1)
//       O X .        group:     (0,0) (0,1) (1,1)
//       . . .        liberties: (0,2) (1,2) (2,1)        (1,0) is white: a neighbour, not a liberty
//
// findDisagreement walks the whole board in three passes and returns the first thing that is wrong, named:
//
//   1. each point's own entries: an empty point has no parent; a stone has a parent, which holds a stone of the same
//      colour; a point that is not a root has empty sets;
//   2. each group, once: every stone of the flood-filled group reaches the same root by its parents, without a loop;
//   3. that root's sets: its stones equal the flood fill's stones, and its liberties the flood fill's liberties.
//
// It costs a few operations per point, so the tests run it after every move, and the program can too.

/// A group found by flood fill: everything the forest keeps at a root, computed from the stones alone.
pub const FloodFilledGroup = struct {
    stones: PointSet,
    liberties: PointSet,
};

/// The group of the stone on `start` and its liberties, found by flood fill (the section's lesson draws it). It takes
/// the stones alone - not a Position - so nothing it computes can come from the forest, and it works as well on stones
/// that have no forest yet, such as a diagram being read. Points still to visit wait on a stack; a stone is marked as
/// in the group when it is pushed, so each is pushed once and the stack never holds more than the board's points.
pub fn floodFillGroup(
    board_size: u8,
    stones: *const [board_limits.max_points]Stone,
    start: Point,
) FloodFilledGroup {
    const group_stone: Stone = stones[start];
    assertf(group_stone != .none, @src(), "floodFillGroup started on empty point {d}", .{start});

    var group: FloodFilledGroup = .{ .stones = .empty, .liberties = .empty };
    var to_visit_buffer: [board_limits.max_points]Point = undefined;
    var to_visit: ArrayList(Point) = .initBuffer(&to_visit_buffer);
    group.stones.set(start);
    to_visit.appendAssumeCapacity(start);

    while (to_visit.pop()) |visiting| {
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        const neighbors: []const Point = neighborsOf(board_size, visiting, &neighbor_buffer);
        for (neighbors) |neighbor| {
            const neighbor_stone: Stone = stones[neighbor];
            const neighbor_is_empty: bool = neighbor_stone == .none;
            const neighbor_is_same_colour: bool = neighbor_stone == group_stone;
            const neighbor_is_new: bool = !group.stones.isSet(neighbor);
            if (neighbor_is_empty) {
                group.liberties.set(neighbor);
            } else if (neighbor_is_same_colour and neighbor_is_new) {
                group.stones.set(neighbor);
                to_visit.appendAssumeCapacity(neighbor);
            }
        }
    }
    return group;
}

/// What can be wrong with the forest, one kind per check of findDisagreement.
pub const DisagreementKind = enum {
    /// An empty point has a parent.
    empty_point_with_parent,
    /// A stone has no parent.
    stone_without_parent,
    /// A stone's parent is an empty point, or a stone of the other colour.
    parent_of_another_colour,
    /// A point that is not a root holds stones or liberties in its sets.
    sets_away_from_root,
    /// Following parents from a stone never reaches a root.
    parents_loop,
    /// Two stones of one flood-filled group reach different roots.
    group_split_between_roots,
    /// A root's stone set differs from the flood fill's stones.
    stones_differ,
    /// A root's liberty set differs from the flood fill's liberties.
    liberties_differ,
};

/// The first thing findDisagreement found wrong, and where.
pub const Disagreement = struct {
    kind: DisagreementKind,
    /// The point the check failed at: for the two set comparisons, the group's root.
    point: Point,
    row: u8,
    col: u8,
    /// For stones_differ and liberties_differ: how many the forest has, and how many the flood fill found.
    forest_count: usize,
    flood_fill_count: usize,

    /// One line for a person: "point (3,4): forest has 3 liberties, flood fill finds 2". Used with `{f}`.
    pub fn format(disagreement: Disagreement, writer: *Io.Writer) Io.Writer.Error!void {
        try writer.print("point ({d},{d}): ", .{ disagreement.row, disagreement.col });
        switch (disagreement.kind) {
            .empty_point_with_parent => {
                try writer.writeAll("empty, but has a parent");
            },
            .stone_without_parent => {
                try writer.writeAll("a stone without a parent");
            },
            .parent_of_another_colour => {
                try writer.writeAll("its parent is empty or of the other colour");
            },
            .sets_away_from_root => {
                try writer.writeAll("not a root, but its sets are not empty");
            },
            .parents_loop => {
                try writer.writeAll("its parents loop without reaching a root");
            },
            .group_split_between_roots => {
                try writer.writeAll("reaches another root than the rest of its group");
            },
            .stones_differ => {
                try writer.print("forest has {d} stones, flood fill finds {d}", .{
                    disagreement.forest_count,
                    disagreement.flood_fill_count,
                });
            },
            .liberties_differ => {
                try writer.print("forest has {d} liberties, flood fill finds {d}", .{
                    disagreement.forest_count,
                    disagreement.flood_fill_count,
                });
            },
        }
    }
};

/// A Disagreement of `kind` at `point`, with the point's row and column filled in.
fn disagreementAt(
    position: *const Position,
    kind: DisagreementKind,
    point: Point,
    forest_count: usize,
    flood_fill_count: usize,
) Disagreement {
    const disagreement: Disagreement = .{
        .kind = kind,
        .point = point,
        .row = rowOf(position.board_size, point),
        .col = colOf(position.board_size, point),
        .forest_count = forest_count,
        .flood_fill_count = flood_fill_count,
    };
    return disagreement;
}

/// The root the stone on `point` reaches by its parents, or null when the parents loop. Unlike findRoot it reports a
/// loop instead of asserting, because finding one is its caller's job. Every stone must have a parent (pass 1 of
/// findDisagreement checks that first).
fn rootOrLoop(position: *const Position, point: Point) ?Point {
    var current: Point = point;
    var steps_taken: usize = 0;
    while (steps_taken < board_limits.max_points) {
        const parent: Point = parentOf(position, current);
        const current_is_root: bool = parent == current;
        if (current_is_root) {
            return current;
        }
        current = parent;
        steps_taken += 1;
    }
    return null;
}

/// Compares the forest with a flood fill of every group, and returns the first disagreement, or null when the two
/// agree everywhere (the section's lesson lists the three passes). Read-only.
pub fn findDisagreement(position: *const Position) ?Disagreement {
    const point_count: usize = pointCount(position.board_size);

    // 1. Each point's own entries.
    for (0..point_count) |point_index| {
        const point: Point = @intCast(point_index);
        const stone: Stone = position.stones[point];
        const maybe_parent: ?Point = position.group_parent[point];
        const point_is_empty: bool = stone == .none;
        const has_parent: bool = maybe_parent != null;
        if (point_is_empty and has_parent) {
            return disagreementAt(position, .empty_point_with_parent, point, 0, 0);
        }
        if (!point_is_empty and !has_parent) {
            return disagreementAt(position, .stone_without_parent, point, 0, 0);
        }
        if (!point_is_empty) {
            const parent_stone: Stone = position.stones[maybe_parent.?];
            const parent_is_same_colour: bool = parent_stone == stone;
            if (!parent_is_same_colour) {
                return disagreementAt(position, .parent_of_another_colour, point, 0, 0);
            }
        }
        const sets_are_empty: bool = position.group_liberties[point].count() == 0 and
            position.group_stones[point].count() == 0;
        if (!isRoot(position, point) and !sets_are_empty) {
            return disagreementAt(position, .sets_away_from_root, point, 0, 0);
        }
    }

    // 2 and 3. Each group once: one root for all its stones, and that root's sets equal to the flood fill's.
    var stones_checked: PointSet = .empty;
    for (0..point_count) |point_index| {
        const point: Point = @intCast(point_index);
        const point_is_empty: bool = position.stones[point] == .none;
        const already_checked: bool = stones_checked.isSet(point);
        if (point_is_empty or already_checked) {
            continue;
        }
        const flood_fill: FloodFilledGroup = floodFillGroup(position.board_size, &position.stones, point);
        stones_checked.setUnion(flood_fill.stones);

        const maybe_group_root: ?Point = rootOrLoop(position, point);
        if (maybe_group_root == null) {
            return disagreementAt(position, .parents_loop, point, 0, 0);
        }
        const group_root: Point = maybe_group_root.?;
        var members: PointSet.Iterator(.{}) = flood_fill.stones.iterator(.{});
        while (members.next()) |member_index| {
            const member: Point = @intCast(member_index);
            const member_root: ?Point = rootOrLoop(position, member);
            if (member_root == null) {
                return disagreementAt(position, .parents_loop, member, 0, 0);
            }
            if (member_root.? != group_root) {
                return disagreementAt(position, .group_split_between_roots, member, 0, 0);
            }
        }

        const forest_stones: PointSet = position.group_stones[group_root];
        if (!forest_stones.eql(flood_fill.stones)) {
            const forest_count: usize = forest_stones.count();
            const flood_fill_count: usize = flood_fill.stones.count();
            return disagreementAt(position, .stones_differ, group_root, forest_count, flood_fill_count);
        }
        const forest_liberties: PointSet = position.group_liberties[group_root];
        if (!forest_liberties.eql(flood_fill.liberties)) {
            const forest_count: usize = forest_liberties.count();
            const flood_fill_count: usize = flood_fill.liberties.count();
            return disagreementAt(position, .liberties_differ, group_root, forest_count, flood_fill_count);
        }
    }
    return null;
}

/// Everything the forest says about one point: what the debug panel's inspector shows.
pub const PointInspection = struct {
    row: u8,
    col: u8,
    /// The point's index in the board's arrays.
    index: Point,
    stone: Stone,
    /// For a stone: its parent and its root in the forest, how many steps up its root is, and its group's stones and
    /// liberties. Null and zero on an empty point.
    parent: ?Point,
    root: ?Point,
    depth: u32,
    group_size: usize,
    liberty_count: usize,
};

/// Inspects `point` (read-only: the forest is walked with parentOf, as findRoot walks it).
///
///       a -> b -> root        for a: parent b, root `root`, depth 2
pub fn inspectPoint(position: *const Position, point: Point) PointInspection {
    var inspection: PointInspection = .{
        .row = rowOf(position.board_size, point),
        .col = colOf(position.board_size, point),
        .index = point,
        .stone = position.stones[point],
        .parent = null,
        .root = null,
        .depth = 0,
        .group_size = 0,
        .liberty_count = 0,
    };
    const point_is_empty: bool = position.stones[point] == .none;
    if (point_is_empty) {
        return inspection;
    }
    inspection.parent = parentOf(position, point);
    var current: Point = point;
    while (!isRoot(position, current)) {
        current = parentOf(position, current);
        inspection.depth += 1;
    }
    inspection.root = current;
    inspection.group_size = position.group_stones[current].count();
    inspection.liberty_count = position.group_liberties[current].count();
    return inspection;
}

/// One parent pointer of the forest: a stone, and the stone it points to.
pub const ForestArrow = struct {
    from: Point,
    to: Point,
};

/// Every parent pointer of the forest - one per stone that is not a root, so a group of n stones has n - 1 - written
/// into the caller's buffer in reading order: what the forest view draws.
pub fn forestArrows(
    position: *const Position,
    out_buffer: *[board_limits.max_points]ForestArrow,
) []const ForestArrow {
    var arrows: ArrayList(ForestArrow) = .initBuffer(out_buffer);
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const point_is_empty: bool = position.stones[point] == .none;
        if (point_is_empty or isRoot(position, point)) {
            continue;
        }
        arrows.appendAssumeCapacity(.{ .from = point, .to = parentOf(position, point) });
    }
    return arrows.items;
}

/// The stones from `point` up to its root, parent after parent, `point` first and the root last, written into the
/// caller's buffer: the walk findRoot makes, which the forest view highlights for the stone under the pointer.
pub fn pathToRoot(
    position: *const Position,
    point: Point,
    out_buffer: *[board_limits.max_points]Point,
) []const Point {
    var path: ArrayList(Point) = .initBuffer(out_buffer);
    var current: Point = point;
    path.appendAssumeCapacity(current);
    while (!isRoot(position, current)) {
        current = parentOf(position, current);
        path.appendAssumeCapacity(current);
    }
    return path.items;
}

// ===== 6. Diagrams =====
//
// A position can be written as text, one line per row of the board, the way Go books print a position:
//
//       // goban 5x5, white to play
//       . . X O .
//       X O O . .
//       . . . . .
//       . . . . .
//       . . . . .
//
// `X` is a black stone, `O` a white stone, `.` an empty point; spaces between them are optional. The first line, if
// it starts with `//`, says whose turn it is; without it, black is to play. The number of rows is the board size,
// from board_limits.min_size to board_limits.max_size, and every row is that long.
//
// Reading a diagram is the way a position gets into the program without its moves: from a test, or pasted from the
// clipboard. A diagram carries the stones and the turn and nothing else - no moves, no ko point, no prisoners - so
// it starts a game whose record holds the stones as its setup (section 4), and undo stops there. A diagram that does
// not describe a position is refused, with what is wrong and where: a row of the wrong length, a character that is
// not a stone, or a group with no liberty, which no game can reach because it would have been captured.
//
// SGF, the Smart Game Format, is how go programs and problem collections write games. A file is a tree of nodes in
// parentheses, each node a `;` and its properties, each property an identifier and one or more values in brackets:
//
//       (;SZ[19]AB[op][pp]AW[pq][qq]TR[qq]C[Black to play.]
//        (;B[rs];W[rr];B[ns]C[Correct])
//        (;B[rq];W[rr]))
//
// A point is two letters, its column and then its row, `a` the first from the left and from the top: `pq` is column
// 15, row 16. The root node - the first - sets the problem up: `SZ` the board size, `AB` and `AW` the black and white
// stones (a value `aa:cc` is the whole rectangle between two points), and the branches after it are the solution's
// variations. A KILL PROBLEM is black to play and kill a white group, a LIFE PROBLEM black to play and make a black
// group live; goban's problems carry one mark the published ones do not, on the problem's target - a triangle (`TR`)
// on the white stone black must capture, or a square (`SQ`) on the black stone black must save. Reading one takes its
// root node (the solution tree is read apart, `readSolutionTree`, the book the computer may follow) and refuses what
// no position could be: a point off the board or given two stones, a group with no liberty, a root marking no stone
// of the right colour, or more than one.

/// The character that shows a stone in a diagram.
pub fn diagramSymbol(stone: Stone) u8 {
    switch (stone) {
        .none => {
            return '.';
        },
        .black => {
            return 'X';
        },
        .white => {
            return 'O';
        },
    }
}

/// The stone a diagram's character shows, or null when the character is not one of `.`, `X` and `O`.
pub fn stoneOfSymbol(character: u8) ?Stone {
    switch (character) {
        '.' => {
            return .none;
        },
        'X' => {
            return .black;
        },
        'O' => {
            return .white;
        },
        else => {
            return null;
        },
    }
}

/// Writes one move as a line of the debug panel's move log: who played where, then what it did - the groups it joined,
/// the stones it captured, the ko point it left - each part only when there is something to say:
///
///       B (3,4)                                 a stone on its own
///       W (2,2): joined 2 groups, captured 3, ko at (2,3)
pub fn writeMoveLine(
    report: MoveReport,
    board_size: u8,
    writer: *Io.Writer,
) Io.Writer.Error!void {
    var player_letter: u8 = 'B';
    if (report.mover == .white) {
        player_letter = 'W';
    }
    const row: u8 = rowOf(board_size, report.placed);
    const col: u8 = colOf(board_size, report.placed);
    try writer.print("{c} ({d},{d})", .{ player_letter, row, col });
    var separator: []const u8 = ": ";
    if (report.groups_joined == 1) {
        try writer.print("{s}joined a group", .{separator});
        separator = ", ";
    } else if (report.groups_joined > 1) {
        try writer.print("{s}joined {d} groups", .{ separator, report.groups_joined });
        separator = ", ";
    }
    if (report.captured_count > 0) {
        try writer.print("{s}captured {d}", .{ separator, report.captured_count });
        separator = ", ";
    }
    if (report.ko_point) |ko_point| {
        const ko_row: u8 = rowOf(board_size, ko_point);
        const ko_col: u8 = colOf(board_size, ko_point);
        try writer.print("{s}ko at ({d},{d})", .{ separator, ko_row, ko_col });
    }
}

/// Writes the position as a diagram: the turn line, then one line per row, stones separated by spaces.
pub fn writeDiagram(position: *const Position, writer: *Io.Writer) Io.Writer.Error!void {
    const board_size: u8 = position.board_size;
    const player_name: []const u8 = @tagName(position.player_to_move);
    try writer.print("// goban {d}x{d}, {s} to play\n", .{ board_size, board_size, player_name });
    for (0..board_size) |row_index| {
        const row: u8 = @intCast(row_index);
        for (0..board_size) |col_index| {
            const col: u8 = @intCast(col_index);
            const is_first_in_row: bool = col == 0;
            if (!is_first_in_row) {
                try writer.writeByte(' ');
            }
            const stone: Stone = position.stones[pointAt(board_size, row, col)];
            try writer.writeByte(diagramSymbol(stone));
        }
        try writer.writeByte('\n');
    }
}

/// What a diagram describes: everything a game is started from.
pub const DiagramSetup = struct {
    board_size: u8,
    /// What stands on each point; only the first board_size * board_size entries are meaningful.
    stones: [board_limits.max_points]Stone,
    player_to_move: Stone,
};

/// Why a diagram was refused, and where. Line and column numbers count from 1, as an editor shows them.
pub const DiagramProblem = union(enum) {
    /// The text holds no row of stones.
    no_rows,
    /// More rows than the largest board has; the line is the first one too many.
    too_many_rows: struct { line_number: usize },
    /// Fewer rows than the smallest board has.
    too_few_rows: struct { row_count: usize },
    /// A row longer than the largest board is wide.
    row_too_long: struct { line_number: usize },
    /// A character that is not a stone, an empty point or a space.
    unknown_character: struct { line_number: usize, column_number: usize, character: u8 },
    /// A `//` line that says neither "black to play" nor "white to play".
    unclear_turn: struct { line_number: usize },
    /// A row whose length is not the number of rows: the board would not be square.
    row_length_differs: struct { line_number: usize, row_length: usize, row_count: usize },
    /// A group with no liberty, at its first stone in reading order.
    group_without_liberty: struct { row: u8, col: u8 },

    /// One line for a person, for the panel that shows why a paste was refused. Used with `{f}`.
    pub fn format(problem: DiagramProblem, writer: *Io.Writer) Io.Writer.Error!void {
        switch (problem) {
            .no_rows => {
                try writer.writeAll("no rows of stones");
            },
            .too_many_rows => |where| {
                try writer.print("line {d}: more than {d} rows", .{ where.line_number, board_limits.max_size });
            },
            .too_few_rows => |found| {
                try writer.print("{d} rows: a board has at least {d}", .{ found.row_count, board_limits.min_size });
            },
            .row_too_long => |where| {
                try writer.print("line {d}: more than {d} points", .{ where.line_number, board_limits.max_size });
            },
            .unknown_character => |where| {
                try writer.print("line {d}, column {d}: '{c}' is not X, O or .", .{
                    where.line_number,
                    where.column_number,
                    where.character,
                });
            },
            .unclear_turn => |where| {
                try writer.print("line {d}: say \"black to play\" or \"white to play\"", .{where.line_number});
            },
            .row_length_differs => |where| {
                try writer.print("line {d}: {d} points in a diagram of {d} rows", .{
                    where.line_number,
                    where.row_length,
                    where.row_count,
                });
            },
            .group_without_liberty => |where| {
                try writer.print("the group at ({d},{d}) has no liberty", .{ where.row, where.col });
            },
        }
    }
};

/// What reading a diagram gives: the setup it describes, or why it was refused.
pub const DiagramReading = union(enum) {
    setup: DiagramSetup,
    problem: DiagramProblem,
};

/// Reads a diagram (the section's lesson gives the format). Lines are read one by one: blank lines are skipped, a `//`
/// line before the first row says whose turn it is, and every other line is a row of stones. Then the shape is checked
/// - enough rows, and every row as long as there are rows - and last every group is flood-filled to make sure it has
/// a liberty.
pub fn readDiagram(text: []const u8) DiagramReading {
    var setup: DiagramSetup = .{ .board_size = 0, .stones = @splat(.none), .player_to_move = .black };
    var row_lengths: [board_limits.max_size]usize = @splat(0);
    var row_line_numbers: [board_limits.max_size]usize = @splat(0);
    var row_count: usize = 0;
    const widest: usize = board_limits.max_size;

    // Rows of stones are kept at the largest board's width until the board size is known: row r, column c is
    // stones[r * widest + c]. They are moved to the real board's layout once every row has been read.
    var stones_by_widest_row: [board_limits.max_points]Stone = @splat(.none);

    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const line: []const u8 = trim(u8, raw_line, " \t\r");
        const line_is_blank: bool = line.len == 0;
        if (line_is_blank) {
            continue;
        }

        const is_turn_line: bool = startsWith(u8, line, "//") and row_count == 0;
        if (is_turn_line) {
            const says_white: bool = indexOf(u8, line, "white to play") != null;
            const says_black: bool = indexOf(u8, line, "black to play") != null;
            if (says_white) {
                setup.player_to_move = .white;
            } else if (says_black) {
                setup.player_to_move = .black;
            } else {
                return .{ .problem = .{ .unclear_turn = .{ .line_number = line_number } } };
            }
            continue;
        }

        const rows_are_full: bool = row_count == board_limits.max_size;
        if (rows_are_full) {
            return .{ .problem = .{ .too_many_rows = .{ .line_number = line_number } } };
        }
        var row_length: usize = 0;
        for (line, 0..) |character, character_index| {
            const is_space: bool = character == ' ' or character == '\t';
            if (is_space) {
                continue;
            }
            const maybe_stone: ?Stone = stoneOfSymbol(character);
            if (maybe_stone == null) {
                return .{ .problem = .{ .unknown_character = .{
                    .line_number = line_number,
                    .column_number = character_index + 1,
                    .character = character,
                } } };
            }
            const row_is_full: bool = row_length == widest;
            if (row_is_full) {
                return .{ .problem = .{ .row_too_long = .{ .line_number = line_number } } };
            }
            stones_by_widest_row[row_count * widest + row_length] = maybe_stone.?;
            row_length += 1;
        }
        row_lengths[row_count] = row_length;
        row_line_numbers[row_count] = line_number;
        row_count += 1;
    }

    // The shape: enough rows, and every row as long as there are rows.
    if (row_count == 0) {
        return .{ .problem = .no_rows };
    }
    if (row_count < board_limits.min_size) {
        return .{ .problem = .{ .too_few_rows = .{ .row_count = row_count } } };
    }
    for (row_lengths[0..row_count], row_line_numbers[0..row_count]) |row_length, row_line_number| {
        const row_is_square: bool = row_length == row_count;
        if (!row_is_square) {
            return .{ .problem = .{ .row_length_differs = .{
                .line_number = row_line_number,
                .row_length = row_length,
                .row_count = row_count,
            } } };
        }
    }

    // The stones, moved to the real board's layout: row r, column c is point r * board_size + c.
    const board_size: u8 = @intCast(row_count);
    setup.board_size = board_size;
    for (0..board_size) |row_index| {
        for (0..board_size) |col_index| {
            const row: u8 = @intCast(row_index);
            const col: u8 = @intCast(col_index);
            const stone: Stone = stones_by_widest_row[row_index * widest + col_index];
            setup.stones[pointAt(board_size, row, col)] = stone;
        }
    }

    // Every group must have a liberty: a group without one would have been captured.
    var stones_checked: PointSet = .empty;
    for (0..pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const point_is_empty: bool = setup.stones[point] == .none;
        const already_checked: bool = stones_checked.isSet(point);
        if (point_is_empty or already_checked) {
            continue;
        }
        const group: FloodFilledGroup = floodFillGroup(board_size, &setup.stones, point);
        stones_checked.setUnion(group.stones);
        const group_has_no_liberty: bool = group.liberties.count() == 0;
        if (group_has_no_liberty) {
            return .{ .problem = .{ .group_without_liberty = .{
                .row = rowOf(board_size, point),
                .col = colOf(board_size, point),
            } } };
        }
    }
    return .{ .setup = setup };
}

/// Starts a game from a diagram's setup: a plain-Go record whose setup is the diagram's stones in reading order, with
/// the diagram's player to move, and no moves yet.
pub fn startGameFromDiagram(game: *Game, setup: *const DiagramSetup) void {
    game.record = .{
        .board_size = setup.board_size,
        .capture_goal = null,
        .setup = @splat(.{ .point = 0, .stone = .none }),
        .setup_count = 0,
        .setup_to_play = setup.player_to_move,
        .moves = @splat(0),
        .moves_recorded = 0,
        .moves_played = 0,
    };
    for (0..pointCount(setup.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const stone: Stone = setup.stones[point];
        const point_has_stone: bool = stone != .none;
        if (point_has_stone) {
            game.record.setup[game.record.setup_count] = .{ .point = point, .stone = stone };
            game.record.setup_count += 1;
        }
    }
    replayTo(game, 0);
}

/// Which task a problem sets black (the section's lesson).
pub const ProblemKind = enum {
    /// Capture the target, a white stone: the root node's triangle.
    kill,
    /// Keep the target, a black stone, from capture: the root node's square.
    live,
};

/// A go problem read from SGF (the section's lesson): a position, black to play, its target, which task it sets, and
/// the points its book plays - which its region must take in, with its stones (`startProblem`), so that every move of
/// the book can be played.
pub const Problem = struct {
    setup: DiagramSetup,
    target: Point,
    kind: ProblemKind = .kill,
    book_points: PointSet = .empty,
};

/// Why an SGF text was refused as a problem.
pub const SgfError = error{
    /// The text has no game tree: it does not begin with `(;`.
    NotSgf,
    /// A property value whose `]` never comes.
    UnterminatedValue,
    /// A board size (`SZ`) goban cannot play on, or a board that is not square.
    UnsupportedBoardSize,
    /// A point that is not two letters of the board.
    BadPoint,
    /// A point given a stone twice.
    StoneTwice,
    /// A group with no liberty, which no game could reach.
    GroupWithoutLiberty,
    /// A root node marking no point with a triangle (`TR`) or a square (`SQ`), or more than one.
    NoSingleTarget,
    /// A triangle on a point with no white stone, or a square on one with no black stone.
    TargetWrongColour,
    /// A solution tree of more nodes than `SolutionTree.max_nodes`.
    TreeTooLarge,
};

/// The coordinate an SGF letter names: `a` .. `z` 0 .. 25, then `A` .. `Z` 26 .. 51.
fn sgfCoordinate(letter: u8) ?u8 {
    if (letter >= 'a' and letter <= 'z') {
        return letter - 'a';
    }
    if (letter >= 'A' and letter <= 'Z') {
        return letter - 'A' + 26;
    }
    return null;
}

/// The column and row an SGF point names - two letters, the column first - or null when it is not two letters.
/// Whether a move's value is a pass: empty, as SGF writes one now, or `tt` on a board of 19 lines or fewer, as older
/// files do. A book's pass explains what would follow if a player played elsewhere; a problem's game has no pass, so
/// the readers leave out the rest of such a variation.
fn isSgfPass(value: []const u8, board_size: u8) bool {
    const is_empty: bool = value.len == 0;
    const is_old_pass: bool = board_size <= 19 and eql(u8, value, "tt");
    return is_empty or is_old_pass;
}

fn sgfColumnAndRow(value: []const u8) ?[2]u8 {
    if (value.len != 2) {
        return null;
    }
    const col: u8 = sgfCoordinate(value[0]) orelse {
        return null;
    };
    const row: u8 = sgfCoordinate(value[1]) orelse {
        return null;
    };
    return .{ col, row };
}

/// A property of an SGF node: its identifier, and its values with their brackets taken off.
const SgfProperty = struct {
    identifier: []const u8,
    values: [board_limits.max_points][]const u8,
    value_count: usize,
};

/// Where in an SGF text a reading is, and what it reads: properties and their values, one at a time.
const SgfCursor = struct {
    text: []const u8,
    index: usize,

    fn skipWhitespace(cursor: *SgfCursor) void {
        while (cursor.index < cursor.text.len and std.ascii.isWhitespace(cursor.text[cursor.index])) {
            cursor.index += 1;
        }
    }

    /// The next property of the node the cursor is in, or null at the node's end - the next `;`, `(` or `)`, or the
    /// text's. Its values are slices of the text, escapes (`\]`) left in, which goban's properties never need.
    fn nextProperty(cursor: *SgfCursor, property: *SgfProperty) SgfError!bool {
        cursor.skipWhitespace();
        const at_node_end: bool = cursor.index >= cursor.text.len or !std.ascii.isAlphabetic(cursor.text[cursor.index]);
        if (at_node_end) {
            return false;
        }
        const identifier_start: usize = cursor.index;
        while (cursor.index < cursor.text.len and std.ascii.isAlphabetic(cursor.text[cursor.index])) {
            cursor.index += 1;
        }
        property.identifier = cursor.text[identifier_start..cursor.index];
        property.value_count = 0;
        while (true) {
            cursor.skipWhitespace();
            const another_value: bool = cursor.index < cursor.text.len and cursor.text[cursor.index] == '[';
            if (!another_value) {
                break;
            }
            const value_start: usize = cursor.index + 1;
            var value_end: usize = value_start;
            while (value_end < cursor.text.len and cursor.text[value_end] != ']') {
                // A backslash keeps the character after it, a `]` included, in the value.
                value_end += if (cursor.text[value_end] == '\\') 2 else 1;
            }
            if (value_end >= cursor.text.len) {
                return SgfError.UnterminatedValue;
            }
            if (property.value_count < property.values.len) {
                property.values[property.value_count] = cursor.text[value_start..value_end];
                property.value_count += 1;
            }
            cursor.index = value_end + 1;
        }
        return true;
    }
};

/// The points an SGF stone list's values name, each a point or a rectangle `aa:cc`, as columns and rows, written into
/// `out` from `count` on. Returns the new count.
fn appendSgfPoints(
    values: []const []const u8,
    out: *[board_limits.max_points][2]u8,
    count: usize,
) SgfError!usize {
    var point_count: usize = count;
    for (values) |value| {
        const colon_index: ?usize = indexOfScalar(u8, value, ':');
        const first: [2]u8 = sgfColumnAndRow(if (colon_index) |colon| value[0..colon] else value) orelse {
            return SgfError.BadPoint;
        };
        const last: [2]u8 = if (colon_index) |colon| sgfColumnAndRow(value[colon + 1 ..]) orelse {
            return SgfError.BadPoint;
        } else first;
        for (@min(first[0], last[0])..@max(first[0], last[0]) + 1) |col| {
            for (@min(first[1], last[1])..@max(first[1], last[1]) + 1) |row| {
                if (point_count >= out.len) {
                    return SgfError.StoneTwice;
                }
                out[point_count] = .{ @intCast(col), @intCast(row) };
                point_count += 1;
            }
        }
    }
    return point_count;
}

/// What an SGF text's root node sets up (the section's lesson): the position, black to play, its triangle marks, and
/// where in the text the root node ends - where a property added to it goes.
pub const SgfRoot = struct {
    setup: DiagramSetup,
    triangles: [board_limits.max_points]Point,
    triangle_count: usize,
    squares: [board_limits.max_points]Point,
    square_count: usize,
    /// The index just past the root node's last property.
    end_index: usize,
};

/// Reads an SGF text's root node (the section's lesson): its board size, its stones and its triangles, the variations
/// after it left unread. The stones are checked as a diagram's are.
pub fn readSgfRoot(text: []const u8) SgfError!SgfRoot {
    var cursor: SgfCursor = .{ .text = text, .index = 0 };
    cursor.skipWhitespace();
    const opens_a_tree: bool = cursor.index + 1 < text.len and text[cursor.index] == '(';
    if (!opens_a_tree) {
        return SgfError.NotSgf;
    }
    cursor.index += 1;
    cursor.skipWhitespace();
    const opens_a_node: bool = cursor.index < text.len and text[cursor.index] == ';';
    if (!opens_a_node) {
        return SgfError.NotSgf;
    }
    cursor.index += 1;

    // The root node's properties: the stones and the triangles kept until the board size is known.
    var board_size_value: u32 = 19;
    var black_points: [board_limits.max_points][2]u8 = undefined;
    var black_count: usize = 0;
    var white_points: [board_limits.max_points][2]u8 = undefined;
    var white_count: usize = 0;
    var triangle_points: [board_limits.max_points][2]u8 = undefined;
    var triangle_count: usize = 0;
    var square_points: [board_limits.max_points][2]u8 = undefined;
    var square_count: usize = 0;
    var property: SgfProperty = undefined;
    while (try cursor.nextProperty(&property)) {
        const values: []const []const u8 = property.values[0..property.value_count];
        if (eql(u8, property.identifier, "SZ")) {
            const size_text: []const u8 = if (values.len > 0) values[0] else "";
            const colon_index: ?usize = indexOfScalar(u8, size_text, ':');
            if (colon_index) |colon| {
                const is_square: bool = eql(u8, size_text[0..colon], size_text[colon + 1 ..]);
                if (!is_square) {
                    return SgfError.UnsupportedBoardSize;
                }
            }
            const side_text: []const u8 = if (colon_index) |colon| size_text[0..colon] else size_text;
            board_size_value = parseInt(u32, side_text, 10) catch {
                return SgfError.UnsupportedBoardSize;
            };
        } else if (eql(u8, property.identifier, "AB")) {
            black_count = try appendSgfPoints(values, &black_points, black_count);
        } else if (eql(u8, property.identifier, "AW")) {
            white_count = try appendSgfPoints(values, &white_points, white_count);
        } else if (eql(u8, property.identifier, "TR")) {
            triangle_count = try appendSgfPoints(values, &triangle_points, triangle_count);
        } else if (eql(u8, property.identifier, "SQ")) {
            square_count = try appendSgfPoints(values, &square_points, square_count);
        }
    }
    const size_is_supported: bool = board_size_value >= board_limits.min_size and
        board_size_value <= board_limits.max_size;
    if (!size_is_supported) {
        return SgfError.UnsupportedBoardSize;
    }
    const board_size: u8 = @intCast(board_size_value);

    // The stones, each on the board and on a point of its own.
    var root: SgfRoot = .{
        .setup = .{ .board_size = board_size, .stones = @splat(.none), .player_to_move = .black },
        .triangles = undefined,
        .triangle_count = 0,
        .squares = undefined,
        .square_count = 0,
        .end_index = cursor.index,
    };
    const stone_lists = [_]struct { points: []const [2]u8, stone: Stone }{
        .{ .points = black_points[0..black_count], .stone = .black },
        .{ .points = white_points[0..white_count], .stone = .white },
    };
    for (stone_lists) |stone_list| {
        for (stone_list.points) |col_row| {
            const on_board: bool = col_row[0] < board_size and col_row[1] < board_size;
            if (!on_board) {
                return SgfError.BadPoint;
            }
            const point: Point = pointAt(board_size, col_row[1], col_row[0]);
            if (root.setup.stones[point] != .none) {
                return SgfError.StoneTwice;
            }
            root.setup.stones[point] = stone_list.stone;
        }
    }

    // Every group must have a liberty, as in a diagram.
    var stones_checked: PointSet = .empty;
    for (0..pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const point_is_empty: bool = root.setup.stones[point] == .none;
        if (point_is_empty or stones_checked.isSet(point)) {
            continue;
        }
        const group: FloodFilledGroup = floodFillGroup(board_size, &root.setup.stones, point);
        stones_checked.setUnion(group.stones);
        if (group.liberties.count() == 0) {
            return SgfError.GroupWithoutLiberty;
        }
    }

    // The triangles and the squares, each a point of the board.
    for (triangle_points[0..triangle_count]) |col_row| {
        const on_board: bool = col_row[0] < board_size and col_row[1] < board_size;
        if (!on_board) {
            return SgfError.BadPoint;
        }
        root.triangles[root.triangle_count] = pointAt(board_size, col_row[1], col_row[0]);
        root.triangle_count += 1;
    }
    for (square_points[0..square_count]) |col_row| {
        const on_board: bool = col_row[0] < board_size and col_row[1] < board_size;
        if (!on_board) {
            return SgfError.BadPoint;
        }
        root.squares[root.square_count] = pointAt(board_size, col_row[1], col_row[0]);
        root.square_count += 1;
    }
    return root;
}

/// The index just past the bracketed value that opens at `index` (a `[`), escapes skipped; the text's end when the
/// value never closes.
fn indexPastSgfValue(text: []const u8, index: usize) usize {
    var value_index: usize = index + 1;
    while (value_index < text.len and text[value_index] != ']') {
        value_index += if (text[value_index] == '\\') 2 else 1;
    }
    return @min(value_index + 1, text.len);
}

/// The index of the `)` that closes the variation opening at `index` (a `(`), the values in it skipped; the text's
/// length when it never closes.
fn indexOfSgfVariationEnd(text: []const u8, index: usize) usize {
    var depth: usize = 0;
    var scan_index: usize = index;
    while (scan_index < text.len) {
        switch (text[scan_index]) {
            '[' => {
                scan_index = indexPastSgfValue(text, scan_index);
                continue;
            },
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return scan_index;
                }
            },
            else => {},
        }
        scan_index += 1;
    }
    return text.len;
}

/// A first move of an SGF problem's solution (the section's lesson): the black move that opens one of the variations
/// after the root node, and whether a line under it ends in a comment that begins "Correct".
pub const SgfFirstMove = struct {
    point: Point,
    leads_to_correct: bool,
};

/// The first moves of the variations after `root`'s node in `text`, each point once - a move opening two variations
/// is correct if either leads to "Correct". A solution written as one line, with no variation, is one variation.
pub fn readSgfFirstMoves(
    text: []const u8,
    root: *const SgfRoot,
    out_buffer: *[board_limits.max_points]SgfFirstMove,
) SgfError![]const SgfFirstMove {
    var first_moves: ArrayList(SgfFirstMove) = .initBuffer(out_buffer);
    const board_size: u8 = root.setup.board_size;
    var index: usize = root.end_index;
    while (index < text.len) {
        const character: u8 = text[index];
        if (std.ascii.isWhitespace(character)) {
            index += 1;
            continue;
        }
        // Each variation: `(`, its first node `;B[..]`, and everything to its `)`; a single line: the rest of the text.
        const is_variation: bool = character == '(';
        const is_single_line: bool = character == ';';
        if (!is_variation and !is_single_line) {
            break;
        }
        const variation_end: usize = if (is_variation) indexOfSgfVariationEnd(text, index) else text.len;
        var node_index: usize = index;
        while (node_index < variation_end and text[node_index] != ';') {
            node_index += 1;
        }
        var cursor: SgfCursor = .{ .text = text[0..variation_end], .index = node_index + 1 };
        var property: SgfProperty = undefined;
        var first_move: ?[2]u8 = null;
        while (try cursor.nextProperty(&property)) {
            const is_black_move: bool = eql(u8, property.identifier, "B") and property.value_count == 1;
            // A pass is no first move: the variation has none.
            if (is_black_move and !isSgfPass(property.values[0], board_size)) {
                first_move = sgfColumnAndRow(property.values[0]) orelse {
                    return SgfError.BadPoint;
                };
            }
        }
        const variation_text: []const u8 = text[index..variation_end];
        const leads_to_correct: bool = indexOf(u8, variation_text, "C[Correct") != null or
            indexOf(u8, variation_text, "C[Also correct") != null;
        if (first_move) |col_row| {
            const on_board: bool = col_row[0] < board_size and col_row[1] < board_size;
            if (!on_board) {
                return SgfError.BadPoint;
            }
            const point: Point = pointAt(board_size, col_row[1], col_row[0]);
            var already_listed: bool = false;
            for (first_moves.items) |*listed| {
                if (listed.point == point) {
                    listed.leads_to_correct = listed.leads_to_correct or leads_to_correct;
                    already_listed = true;
                }
            }
            if (!already_listed) {
                first_moves.appendAssumeCapacity(.{ .point = point, .leads_to_correct = leads_to_correct });
            }
        }
        if (is_single_line) {
            break;
        }
        index = variation_end + 1;
    }
    return first_moves.items;
}

/// One of the square board's eight symmetries (the section's lesson): four turns and four reflections. A problem drawn
/// in any of them is the same problem, so each start can show it differently.
pub const Symmetry = enum(u3) {
    identity,
    quarter_turn,
    half_turn,
    three_quarter_turn,
    left_for_right,
    top_for_bottom,
    across_main_diagonal,
    across_other_diagonal,

    /// The point `point` of a board this size becomes under the symmetry.
    pub fn transformPoint(symmetry: Symmetry, board_size: u8, point: Point) Point {
        const row: u8 = rowOf(board_size, point);
        const col: u8 = colOf(board_size, point);
        const last: u8 = board_size - 1;
        const row_col: [2]u8 = switch (symmetry) {
            .identity => .{ row, col },
            .quarter_turn => .{ col, last - row },
            .half_turn => .{ last - row, last - col },
            .three_quarter_turn => .{ last - col, row },
            .left_for_right => .{ row, last - col },
            .top_for_bottom => .{ last - row, col },
            .across_main_diagonal => .{ col, row },
            .across_other_diagonal => .{ last - col, last - row },
        };
        return pointAt(board_size, row_col[0], row_col[1]);
    }
};

/// Whether an SGF comment says its node solves the problem: it begins "Correct", or "Also correct" for a second
/// solution.
pub fn commentSaysCorrect(comment: []const u8) bool {
    return startsWith(u8, comment, "Correct") or startsWith(u8, comment, "Also correct");
}

/// A node of a problem's solution tree (the section's lesson): a move, whether its comment says the moves to it solve
/// the problem, and where its first child and next sibling are in the tree's nodes.
pub const SolutionNode = struct {
    move: Point,
    is_correct: bool,
    first_child: u16 = none,
    next_sibling: u16 = none,

    pub const none: u16 = maxInt(u16);
};

/// A problem's solution tree as its SGF writes it: the root's children, the first moves, and every node under them.
pub const SolutionTree = struct {
    nodes: [max_nodes]SolutionNode,
    node_count: u16,
    first_move: u16,

    /// The most nodes a tree holds: more than any published problem's.
    pub const max_nodes: usize = 1024;
    pub const empty: SolutionTree = .{ .nodes = undefined, .node_count = 0, .first_move = SolutionNode.none };

    /// The node the moves `moves` reach from the root, each the child of the one before, or null when they leave the
    /// tree - the book does not have them.
    pub fn nodeAfter(tree: *const SolutionTree, moves: []const Point) ?u16 {
        var node_index: u16 = SolutionNode.none;
        var child_index: u16 = tree.first_move;
        for (moves) |move| {
            while (child_index != SolutionNode.none and tree.nodes[child_index].move != move) {
                child_index = tree.nodes[child_index].next_sibling;
            }
            if (child_index == SolutionNode.none) {
                return null;
            }
            node_index = child_index;
            child_index = tree.nodes[child_index].first_child;
        }
        return node_index;
    }

    /// Whether the moves `moves` solve the problem as the book says: a node on their way through the tree is correct.
    pub fn isSolvedBy(tree: *const SolutionTree, moves: []const Point) bool {
        for (1..moves.len + 1) |move_count| {
            const node_index: u16 = tree.nodeAfter(moves[0..move_count]) orelse {
                return false;
            };
            if (tree.nodes[node_index].is_correct) {
                return true;
            }
        }
        return false;
    }

    /// The book's answers to the moves `moves`: the moves of the children of the node they reach - none when they
    /// leave the tree or reach a node with no child. Written into `out_buffer`.
    pub fn repliesAfter(
        tree: *const SolutionTree,
        moves: []const Point,
        out_buffer: []Point,
    ) []const Point {
        var child_index: u16 = tree.first_move;
        if (moves.len > 0) {
            const node_index: u16 = tree.nodeAfter(moves) orelse {
                return out_buffer[0..0];
            };
            child_index = tree.nodes[node_index].first_child;
        }
        var reply_count: usize = 0;
        while (child_index != SolutionNode.none and reply_count < out_buffer.len) {
            out_buffer[reply_count] = tree.nodes[child_index].move;
            reply_count += 1;
            child_index = tree.nodes[child_index].next_sibling;
        }
        return out_buffer[0..reply_count];
    }

    /// The tree from the node `moves` reach on: its children the new tree's first moves, everything under them kept -
    /// the book of a problem started after those moves. Empty when the moves leave the tree; the whole tree when
    /// there are none.
    pub fn subtreeAfter(tree: *const SolutionTree, moves: []const Point) SolutionTree {
        var subtree: SolutionTree = .empty;
        var first_child: u16 = tree.first_move;
        if (moves.len > 0) {
            const node_index: u16 = tree.nodeAfter(moves) orelse {
                return subtree;
            };
            first_child = tree.nodes[node_index].first_child;
        }
        subtree.copyChildrenFrom(tree, first_child, SolutionNode.none);
        return subtree;
    }

    /// Adds a node for `move` as the last child of `parent_index` - of the root when it is `none`. Returns its index.
    fn appendChild(
        tree: *SolutionTree,
        parent_index: u16,
        move: Point,
        is_correct: bool,
    ) SgfError!u16 {
        if (tree.node_count >= SolutionTree.max_nodes) {
            return SgfError.TreeTooLarge;
        }
        const node_index: u16 = tree.node_count;
        tree.nodes[node_index] = .{ .move = move, .is_correct = is_correct };
        tree.node_count += 1;
        const parent_is_root: bool = parent_index == SolutionNode.none;
        const first_child: *u16 = if (parent_is_root) &tree.first_move else &tree.nodes[parent_index].first_child;
        if (first_child.* == SolutionNode.none) {
            first_child.* = node_index;
            return node_index;
        }
        var sibling_index: u16 = first_child.*;
        while (tree.nodes[sibling_index].next_sibling != SolutionNode.none) {
            sibling_index = tree.nodes[sibling_index].next_sibling;
        }
        tree.nodes[sibling_index].next_sibling = node_index;
        return node_index;
    }

    /// Copies the children from `first_child` on in `from`, and everything under them, into the tree as children of
    /// `new_parent` - of its root when that is `none` - in their order.
    fn copyChildrenFrom(
        tree: *SolutionTree,
        from: *const SolutionTree,
        first_child: u16,
        new_parent: u16,
    ) void {
        var child_index: u16 = first_child;
        while (child_index != SolutionNode.none) : (child_index = from.nodes[child_index].next_sibling) {
            const child: SolutionNode = from.nodes[child_index];
            const copied_index: u16 = tree.appendChild(new_parent, child.move, child.is_correct) catch {
                panicf(@src(), "copyChildrenFrom: a copy larger than the tree it comes from", .{});
            };
            tree.copyChildrenFrom(from, child.first_child, copied_index);
        }
    }

    /// The tree drawn under `symmetry`, as its problem is (`transformedProblem`): every move moved to its point.
    pub fn transformed(
        tree: *const SolutionTree,
        board_size: u8,
        symmetry: Symmetry,
    ) SolutionTree {
        var moved: SolutionTree = tree.*;
        for (moved.nodes[0..moved.node_count]) |*node| {
            node.move = symmetry.transformPoint(board_size, node.move);
        }
        return moved;
    }
};

/// Reads the nodes from `start` to `end` - a run of nodes, then variations - each node with a move a child of the one
/// before, the first a child of `parent_index`, and the variations children of the last.
fn readSolutionNodes(
    text: []const u8,
    start: usize,
    end: usize,
    board_size: u8,
    parent_index: u16,
    tree: *SolutionTree,
) SgfError!void {
    var cursor: SgfCursor = .{ .text = text[0..end], .index = start };
    var last_index: u16 = parent_index;
    while (true) {
        cursor.skipWhitespace();
        if (cursor.index >= end) {
            return;
        }
        const character: u8 = text[cursor.index];
        if (character == ';') {
            cursor.index += 1;
            var property: SgfProperty = undefined;
            var move: ?Point = null;
            var is_correct: bool = false;
            while (try cursor.nextProperty(&property)) {
                const is_move: bool = eql(u8, property.identifier, "B") or eql(u8, property.identifier, "W");
                if (is_move and property.value_count == 1) {
                    // A pass: the rest of this variation - its nodes and its variations - is left out.
                    if (isSgfPass(property.values[0], board_size)) {
                        return;
                    }
                    const col_row: [2]u8 = sgfColumnAndRow(property.values[0]) orelse {
                        return SgfError.BadPoint;
                    };
                    if (col_row[0] >= board_size or col_row[1] >= board_size) {
                        return SgfError.BadPoint;
                    }
                    move = pointAt(board_size, col_row[1], col_row[0]);
                }
                const is_comment: bool = eql(u8, property.identifier, "C") and property.value_count > 0;
                if (is_comment and commentSaysCorrect(property.values[0])) {
                    is_correct = true;
                }
            }
            const node_move: Point = move orelse {
                continue;
            };
            last_index = try tree.appendChild(last_index, node_move, is_correct);
        } else if (character == '(') {
            // A variation: its nodes, the first of them a child of this run's last node.
            const variation_end: usize = indexOfSgfVariationEnd(text, cursor.index);
            try readSolutionNodes(text, cursor.index + 1, variation_end, board_size, last_index, tree);
            cursor.index = variation_end + 1;
        } else {
            return;
        }
    }
}

/// Reads a problem's solution tree from its SGF text (the section's lesson): every node after the root with a move,
/// each the child of the node before it in its variation, and the first nodes of a variation's variations its last
/// node's children.
pub fn readSolutionTree(
    text: []const u8,
    root: *const SgfRoot,
    tree: *SolutionTree,
) SgfError!void {
    tree.* = .empty;
    const board_size: u8 = root.setup.board_size;
    var index: usize = root.end_index;
    while (index < text.len) {
        const character: u8 = text[index];
        if (std.ascii.isWhitespace(character)) {
            index += 1;
            continue;
        }
        if (character == '(') {
            const variation_end: usize = indexOfSgfVariationEnd(text, index);
            try readSolutionNodes(text, index + 1, variation_end, board_size, SolutionNode.none, tree);
            index = variation_end + 1;
        } else if (character == ';') {
            // A solution as one line after the root, with no variation.
            try readSolutionNodes(text, index, text.len, board_size, SolutionNode.none, tree);
            break;
        } else {
            break;
        }
    }
}

/// Reads a go problem from an SGF text (the section's lesson): its root node (`readSgfRoot`), whose one mark is the
/// target - a triangle on a white stone for a kill problem, a square on a black stone for a life problem - and the
/// points its book's moves are played on (`readSolutionTree`).
pub fn readProblem(text: []const u8) SgfError!Problem {
    const root: SgfRoot = try readSgfRoot(text);
    const mark_count: usize = root.triangle_count + root.square_count;
    if (mark_count != 1) {
        return SgfError.NoSingleTarget;
    }
    const is_kill: bool = root.triangle_count == 1;
    var problem: Problem = .{
        .setup = root.setup,
        .target = if (is_kill) root.triangles[0] else root.squares[0],
        .kind = if (is_kill) .kill else .live,
    };
    // Every point a move of the book is played on, in any variation.
    var book: SolutionTree = undefined;
    try readSolutionTree(text, &root, &book);
    for (book.nodes[0..book.node_count]) |node| {
        problem.book_points.set(node.move);
    }
    const target_colour_expected: Stone = if (is_kill) .white else .black;
    if (problem.setup.stones[problem.target] != target_colour_expected) {
        return SgfError.TargetWrongColour;
    }
    return problem;
}

/// Walks the variation opening at `index` (a `(`), its nodes and then its variations in turn, adding each node's move
/// to `line` and taking back a variation's moves when no line in it reaches "Correct". Whether one did.
fn findCorrectLine(
    text: []const u8,
    index: usize,
    board_size: u8,
    line: *ArrayList(Point),
) SgfError!bool {
    const variation_end: usize = indexOfSgfVariationEnd(text, index);
    var cursor: SgfCursor = .{ .text = text[0..variation_end], .index = index + 1 };
    while (true) {
        cursor.skipWhitespace();
        if (cursor.index >= variation_end) {
            return false;
        }
        const character: u8 = text[cursor.index];
        if (character == ';') {
            cursor.index += 1;
            var property: SgfProperty = undefined;
            var reaches_correct: bool = false;
            while (try cursor.nextProperty(&property)) {
                const is_move: bool = eql(u8, property.identifier, "B") or eql(u8, property.identifier, "W");
                if (is_move and property.value_count == 1) {
                    // No line goes through a pass: the variation gives none.
                    if (isSgfPass(property.values[0], board_size)) {
                        return false;
                    }
                    const col_row: [2]u8 = sgfColumnAndRow(property.values[0]) orelse {
                        return SgfError.BadPoint;
                    };
                    const on_board: bool = col_row[0] < board_size and col_row[1] < board_size;
                    if (!on_board or line.items.len >= line.capacity) {
                        return SgfError.BadPoint;
                    }
                    line.appendAssumeCapacity(pointAt(board_size, col_row[1], col_row[0]));
                }
                const is_comment: bool = eql(u8, property.identifier, "C") and property.value_count > 0;
                if (is_comment and commentSaysCorrect(property.values[0])) {
                    reaches_correct = true;
                }
            }
            if (reaches_correct) {
                return true;
            }
        } else if (character == '(') {
            const length_before: usize = line.items.len;
            if (try findCorrectLine(text, cursor.index, board_size, line)) {
                return true;
            }
            line.shrinkRetainingCapacity(length_before);
            cursor.index = indexOfSgfVariationEnd(text, cursor.index) + 1;
        } else {
            return false;
        }
    }
}

/// The moves of the first line of `text`'s solution that reaches a comment beginning "Correct" (the section's lesson):
/// black's and white's in turn, from the root up to and including the node with the comment. Empty when no line does.
pub fn readSgfCorrectLine(
    text: []const u8,
    root: *const SgfRoot,
    out_buffer: *[record_limits.max_moves]Point,
) SgfError![]const Point {
    var line: ArrayList(Point) = .initBuffer(out_buffer);
    var index: usize = 0;
    while (index < text.len and text[index] != '(') {
        index += 1;
    }
    const found: bool = try findCorrectLine(text, index, root.setup.board_size, &line);
    if (!found) {
        line.clearRetainingCapacity();
    }
    return line.items;
}

/// `setup` with its colours swapped, black for white and white for black, the player to move kept: a problem's twin
/// with the other side's task - a group that had to live now to be killed, or the other way round.
pub fn swapColours(setup: *const DiagramSetup) DiagramSetup {
    var swapped: DiagramSetup = setup.*;
    for (swapped.stones[0..pointCount(setup.board_size)]) |*stone| {
        stone.* = switch (stone.*) {
            .black => .white,
            .white => .black,
            .none => .none,
        };
    }
    return swapped;
}

/// How a problem is played: the margin, in lines, its region keeps around its stones.
pub const ProblemSettings = struct {
    region_margin: u8 = 1,
};

/// `problem` drawn under `symmetry`: each stone, and the target, moved to its point under it.
pub fn transformedProblem(problem: *const Problem, symmetry: Symmetry) Problem {
    const board_size: u8 = problem.setup.board_size;
    var transformed: Problem = .{
        .setup = .{ .board_size = board_size, .stones = @splat(.none), .player_to_move = problem.setup.player_to_move },
        .target = symmetry.transformPoint(board_size, problem.target),
        .kind = problem.kind,
    };
    for (0..pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const moved_point: Point = symmetry.transformPoint(board_size, point);
        transformed.setup.stones[moved_point] = problem.setup.stones[point];
        if (problem.book_points.isSet(point)) {
            transformed.book_points.set(moved_point);
        }
    }
    return transformed;
}

/// Whose the board beyond a problem's frame is (the section's lesson): the colour whose stones face the frame's open
/// sides. Along every line in from each side of the stones' box that the board's edge does not close, the first stone
/// met is counted; the colour with more is the outside's - `tie_colour` when the counts are equal. A life problem's
/// black group sits inside white's wall, a kill problem's white group inside black's: the wall faces outward, and the
/// outside is the wall's.
pub fn outsideOwner(setup: *const DiagramSetup, tie_colour: Stone) Stone {
    const board_size: u8 = setup.board_size;
    var first_row: u8 = board_size;
    var last_row: u8 = 0;
    var first_col: u8 = board_size;
    var last_col: u8 = 0;
    for (0..pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        if (setup.stones[point] == .none) {
            continue;
        }
        first_row = @min(first_row, rowOf(board_size, point));
        last_row = @max(last_row, rowOf(board_size, point));
        first_col = @min(first_col, colOf(board_size, point));
        last_col = @max(last_col, colOf(board_size, point));
    }
    if (first_row > last_row) {
        return tie_colour;
    }
    var facing = [_]u32{ 0, 0 };
    const last_line: u8 = board_size - 1;
    // From the top, the bottom, the left and the right: each open side, each line across the box, walked inward.
    const sides = [_]struct { open: bool, along_rows: bool, from_start: bool }{
        .{ .open = first_row > 0, .along_rows = false, .from_start = true },
        .{ .open = last_row < last_line, .along_rows = false, .from_start = false },
        .{ .open = first_col > 0, .along_rows = true, .from_start = true },
        .{ .open = last_col < last_line, .along_rows = true, .from_start = false },
    };
    for (sides) |side| {
        if (!side.open) {
            continue;
        }
        const line_first: u8 = if (side.along_rows) first_row else first_col;
        const line_last: u8 = if (side.along_rows) last_row else last_col;
        const step_first: u8 = if (side.along_rows) first_col else first_row;
        const step_last: u8 = if (side.along_rows) last_col else last_row;
        for (line_first..@as(usize, line_last) + 1) |line| {
            const step_count: usize = @as(usize, step_last) - step_first + 1;
            for (0..step_count) |step_index| {
                const step: usize = if (side.from_start) step_first + step_index else step_last - step_index;
                const row: u8 = @intCast(if (side.along_rows) line else step);
                const col: u8 = @intCast(if (side.along_rows) step else line);
                const stone: Stone = setup.stones[pointAt(board_size, row, col)];
                if (stone != .none) {
                    facing[@intFromBool(stone == .white)] += 1;
                    break;
                }
            }
        }
    }
    const black_faces: u32 = facing[0];
    const white_faces: u32 = facing[1];
    if (black_faces == white_faces) {
        return tie_colour;
    }
    return if (black_faces > white_faces) .black else .white;
}

/// Starts a game from a problem (the section's lesson): its stones as the setup, black to play, its target, and its
/// region - the box around its stones and its book's points, and `settings.region_margin` lines more - with a ring
/// of stones just outside the region on every side the board's edge does not close, of the colour whose wall faces
/// those sides (`outsideOwner`). The board beyond a problem's frame is that wall's: a group pushed to the frame's edge
/// has nowhere to go. Without the ring, an
/// empty point beyond the frame - where no move may be played - would be a liberty no one could ever fill, and a group
/// reaching the frame's edge could never be captured. The ring's stones have their own liberties further out, so
/// they are never captured; they are not drawn (`drawStones`).
pub fn startProblem(
    game: *Game,
    problem: *const Problem,
    settings: ProblemSettings,
) void {
    startGameFromDiagram(game, &problem.setup);
    // The region frames the stones and the book's points.
    var framed: PointSet = problem.book_points;
    for (game.record.setup[0..game.record.setup_count]) |setup_stone| {
        framed.set(setup_stone.point);
    }
    var framed_buffer: [board_limits.max_points]Point = undefined;
    var framed_points: ArrayList(Point) = .initBuffer(&framed_buffer);
    var framed_iterator: PointSet.Iterator(.{}) = framed.iterator(.{});
    while (framed_iterator.next()) |point_index| {
        framed_points.appendAssumeCapacity(@intCast(point_index));
    }
    const board_size: u8 = problem.setup.board_size;
    const region: ProblemRegion = .around(board_size, framed_points.items, settings.region_margin);
    game.record.target = problem.target;
    game.record.region = region;
    // The ring: every empty point outside the region beside one inside it, the outside's colour (`outsideOwner`) -
    // the stones facing the frame's open sides, or on a tie the task's attacker.
    const task_attacker: Stone = if (problem.kind == .kill) .black else .white;
    const attacker: Stone = outsideOwner(&problem.setup, task_attacker);
    for (0..pointCount(board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const is_free_outside: bool = !region.contains(board_size, point) and problem.setup.stones[point] == .none;
        if (!is_free_outside) {
            continue;
        }
        var touches_region: bool = false;
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        for (neighborsOf(board_size, point, &neighbor_buffer)) |neighbor| {
            touches_region = touches_region or region.contains(board_size, neighbor);
        }
        if (touches_region) {
            game.record.setup[game.record.setup_count] = .{ .point = point, .stone = attacker };
            game.record.setup_count += 1;
        }
    }
    replayTo(game, 0);
}

/// `position`'s stones inside its problem's region, every point outside it empty: the stones a problem started from
/// a played position has (`puzzleAt`), without the ring its first start put around the region (`startProblem`).
pub fn stonesInRegion(position: *const Position) [board_limits.max_points]Stone {
    var stones: [board_limits.max_points]Stone = position.stones;
    const region: ProblemRegion = position.region orelse {
        return stones;
    };
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        if (!region.contains(position.board_size, point)) {
            stones[point] = .none;
        }
    }
    return stones;
}

/// How hard a problem is, as its collection grades it: Go Game Guru's easy, intermediate and hard; other for a problem
/// of no grade.
pub const ProblemLevel = enum {
    easy,
    intermediate,
    hard,
    other,
};

/// A start of a family's ladder (the section's lesson): the moves of the correct line before it, and which of its two
/// puzzles goban_problems_tool's test of interest kept - `own`, black to play the problem as published from there,
/// and `twin`, the move given to the other side and the colours swapped. A puzzle that asks nothing - an obvious move
/// wins it, or many moves do - is dropped wherever it would stand, in a ladder as at its opening.
pub const FamilyStart = struct {
    moves: u8,
    own: bool = true,
    twin: bool = true,

    /// Whether the start sets a puzzle oriented `is_twin` - the twin when true, the book's own kind when false.
    fn allows(start: FamilyStart, is_twin: bool) bool {
        return if (is_twin) start.twin else start.own;
    }
};

/// A published problem and the starts along its correct line that set puzzles worth asking (the section's lesson:
/// puzzle ladders, `FamilyStart`). A ladder's every step is a puzzle of its own, so a family may also open at one of
/// its problem's later starts, its ladder the rest of the line: an easier problem than the published one, a level
/// below it (the index's derived families).
pub const ProblemFamily = struct {
    /// Its file's name, `ggg-easy-01.sgf`.
    name: []const u8 = "",
    sgf: []const u8,
    /// The published problem's kind; its twins' is the other.
    kind: ProblemKind = .kill,
    /// The ladder's starts in order along the correct line, the first its opening: the full problem for a published
    /// family, a later start for a derived one.
    starts: []const FamilyStart,
    level: ProblemLevel = .other,
    /// How hard its answer is to find: the iterations the converter's search took to settle on one of the book's
    /// correct first moves for good (`goban_problems_tool`'s `measureDifficulty`); the families come in the order of
    /// their levels, then of this.
    difficulty: u32 = 0,

    /// The moves of the correct line before the family's first step: 0 for the problem as published.
    pub fn firstStart(family: ProblemFamily) u8 {
        return family.starts[0].moves;
    }

    /// Whether the family can open with a puzzle of `kind`: the published kind's own puzzle, or the other kind's
    /// twin, kept at its first start.
    pub fn opensWith(family: ProblemFamily, kind: ProblemKind) bool {
        const is_twin: bool = kind != family.kind;
        return family.starts[0].allows(is_twin);
    }
};

/// goban's problems as goban_problems_tool.zig made them (`problems/index.zig`, generated from its report): the
/// families and the lists of kill and life problems' files below come from there, none written by hand.
const problem_index = @import("problems/index.zig");

/// The index's entries as `ProblemFamily`s, at compile time.
/// A kind named in the index (`kill`, `live`), read when goban is compiled.
fn kindOfIndex(comptime name: []const u8) ProblemKind {
    return std.meta.stringToEnum(ProblemKind, name) orelse {
        @compileError("goban: problems/index.zig names a kind goban does not have: " ++ name);
    };
}

/// An entry of the index (`problems/index.zig`).
const IndexEntry = @TypeOf(problem_index.families[0]);

/// An index entry's ladder starts (`FamilyStart`), made when goban is compiled.
fn startsOfIndex(comptime entry: IndexEntry) [entry.starts.len]FamilyStart {
    var starts: [entry.starts.len]FamilyStart = undefined;
    for (entry.starts, &starts) |index_start, *start| {
        start.* = .{ .moves = index_start.moves, .own = index_start.own, .twin = index_start.twin };
    }
    return starts;
}

fn familiesOfIndex() [problem_index.families.len]ProblemFamily {
    // Reading a level from its name walks a comptime string map: a few hundred steps an entry.
    @setEvalBranchQuota(1000 * (problem_index.families.len + 1));
    var families: [problem_index.families.len]ProblemFamily = undefined;
    for (problem_index.families, &families) |entry, *family| {
        const level: ProblemLevel = std.meta.stringToEnum(ProblemLevel, entry.level) orelse {
            @compileError("goban: problems/index.zig names a level goban does not have: " ++ entry.level);
        };
        // Each entry's starts a constant of their own, made when goban is compiled, which the family points into.
        const entry_starts: [entry.starts.len]FamilyStart = startsOfIndex(entry);
        family.* = .{
            .name = entry.name,
            .sgf = entry.sgf,
            .kind = kindOfIndex(entry.kind),
            .starts = &entry_starts,
            .level = level,
            .difficulty = entry.difficulty,
        };
    }
    return families;
}

/// goban's published problems, by level, with their later starts, the converter's `from-move` files: the index's
/// entries, their levels read from their names.
pub const problem_families: [problem_index.families.len]ProblemFamily = familiesOfIndex();

/// The published problem named `name` - the family starting from its first move, not one of those derived from its
/// later starts - looked up when the program runs; a name that is not one is a broken promise.
fn familyOf(name: []const u8) ProblemFamily {
    for (problem_families) |family| {
        if (eql(u8, family.name, name) and family.firstStart() == 0) {
            return family;
        }
    }
    panicf(@src(), "familyOf: no published problem is named {s}", .{name});
}

/// The published problem named `name` - `ggg-easy-01.sgf` - found at compile time: a name that is not one fails the
/// build.
pub fn familyNamed(comptime name: []const u8) ProblemFamily {
    const found: ProblemFamily = comptime found: {
        @setEvalBranchQuota(100 * (problem_families.len + 1));
        for (problem_families) |family| {
            if (eql(u8, family.name, name) and family.firstStart() == 0) {
                break :found family;
            }
        }
        @compileError("goban: no published problem is named " ++ name);
    };
    return found;
}

/// One step of a problem's ladder (the section's lesson): the position after `start_moves` of its correct line, black
/// to play the problem as published - or, a twin, the position with the move given to the other side and the colours
/// swapped, so that black plays the other task: a kill problem's twin is a life problem, and the other way round.
pub const PuzzleStep = struct {
    start_moves: u8,
    is_twin: bool,
};

/// The steps of `family`'s ladder (`FamilyStart`), from its first start - the full problem for a published one - to
/// the last: the first oriented `first_is_twin`, each after it the other way from the one before - the kinds
/// alternating - when that puzzle was kept, the same way when only that one was. Written into `out_buffer`.
pub fn familySteps(
    family: ProblemFamily,
    first_is_twin: bool,
    out_buffer: []PuzzleStep,
) []const PuzzleStep {
    var step_count: usize = 0;
    var previous_is_twin: bool = first_is_twin;
    for (family.starts, 0..) |start, start_index| {
        if (step_count >= out_buffer.len) {
            break;
        }
        const alternated_is_twin: bool = !previous_is_twin;
        const is_twin: bool = if (start_index == 0)
            first_is_twin
        else if (start.allows(alternated_is_twin))
            alternated_is_twin
        else if (start.allows(previous_is_twin))
            previous_is_twin
        else
            continue;
        out_buffer[step_count] = .{ .start_moves = start.moves, .is_twin = is_twin };
        step_count += 1;
        previous_is_twin = is_twin;
    }
    return out_buffer[0..step_count];
}

/// A puzzle: the problem a ladder's step sets, and its book - the published tree from the step's start on, or none
/// for a twin, whose side the book does not play.
pub const Puzzle = struct {
    problem: Problem,
    tree: SolutionTree,
};

/// The puzzle of `step` in the ladder of `base` (the section's lesson): the base problem's position after the step's
/// moves of `correct_line`, played in `scratch`; for a twin, the colours swapped, the target's with them, and the kind
/// turned. Black is to play either way.
pub fn puzzleAt(
    base: *const Problem,
    base_tree: *const SolutionTree,
    correct_line: []const Point,
    step: PuzzleStep,
    scratch: *Game,
) Puzzle {
    const moves: []const Point = correct_line[0..step.start_moves];
    startProblem(scratch, base, .{});
    for (moves) |move| {
        _ = playMove(scratch, move);
    }
    const target_stands: bool = scratch.position.stones[base.target] != .none;
    assertf(target_stands, @src(), "puzzleAt: the correct line captures the target in its first {d} moves", .{
        step.start_moves,
    });
    const reached: DiagramSetup = .{
        .board_size = base.setup.board_size,
        .stones = stonesInRegion(&scratch.position),
        .player_to_move = .black,
    };
    // The base's frame kept: its book's points and its stones, whatever the moves have captured since.
    var framed: PointSet = base.book_points;
    for (0..pointCount(base.setup.board_size)) |point_index| {
        if (base.setup.stones[point_index] != .none) {
            framed.set(point_index);
        }
    }
    if (step.is_twin) {
        const other_kind: ProblemKind = if (base.kind == .kill) .live else .kill;
        const twin_problem: Problem = .{
            .setup = swapColours(&reached),
            .target = base.target,
            .kind = other_kind,
            .book_points = framed,
        };
        return .{ .problem = twin_problem, .tree = .empty };
    }
    const same_kind_problem: Problem = .{
        .setup = reached,
        .target = base.target,
        .kind = base.kind,
        .book_points = framed,
    };
    return .{ .problem = same_kind_problem, .tree = base_tree.subtreeAfter(moves) };
}

/// goban's kill problems (`problems/`, whose SOURCE.md says where they come from, made by goban_problems_tool.zig):
/// SGF texts, each with its target marked, embedded only in a program that uses them - the ones as published first,
/// then those made from them: later starts along their correct lines, and the colour-swapped twins of life problems.
pub const kill_problem_sgfs = problem_index.kill_sgfs;

/// goban's life problems: black to play and save one black stone, the target, which a square marks.
pub const life_problem_sgfs = problem_index.life_sgfs;

/// Every one of goban's problems: the kill problems, then the life problems.
pub const problem_sgfs = kill_problem_sgfs ++ life_problem_sgfs;

/// `first` and `second` taken one of each in turn, `first` leading, while both last; then the rest of the longer.
fn alternated(
    comptime first: []const []const u8,
    comptime second: []const []const u8,
) [first.len + second.len][]const u8 {
    // Evaluated when goban is compiled: a few steps an entry, for lists of thousands.
    @setEvalBranchQuota(10 * (first.len + second.len) + 1000);
    var result: [first.len + second.len][]const u8 = undefined;
    var first_index: usize = 0;
    var second_index: usize = 0;
    for (&result, 0..) |*entry, result_index| {
        const first_turn: bool = result_index % 2 == 0;
        const takes_first: bool = (first_turn and first_index < first.len) or second_index >= second.len;
        if (takes_first) {
            entry.* = first[first_index];
            first_index += 1;
        } else {
            entry.* = second[second_index];
            second_index += 1;
        }
    }
    return result;
}

/// goban's problems with kill and life in turn while both last, the rest of the longer list after.
pub const alternating_problem_sgfs = alternated(&kill_problem_sgfs, &life_problem_sgfs);

// ===== 7. The opponent =====
//
// The computer plays Atari Go by MONTE CARLO TREE SEARCH (MCTS). A program that plays a board game must know how good
// a position is, and plain Go makes that hard: who is ahead depends on territory settled only at the end of a long
// game. Atari Go removes the difficulty - the game ends the moment a player reaches the capture goal, often within a
// few dozen moves on a 9 x 9 board - so a game played out at random from any position reaches a real result, a win or
// a loss, with no judgement of the board at all. MCTS is built on exactly that: it plays many such games, PLAYOUTS,
// and keeps the statistics of their first moves in a tree that grows toward the moves that win.
//
// Each node of the tree is a position, reached from its parent's by one move; it counts the playouts that went
// through it (its VISITS) and how many of them the player who made its move went on to win. One ITERATION of the
// search adds one node and one playout, in four steps (the UCT form of Kocsis and Szepesvari, 2006):
//
//     1. selection       from the root, go down the tree: at each node whose moves all have children, to the child
//                        with the highest upper confidence bound (UCB1, below)
//     2. expansion       at the first node with a legal move that has no child yet, add that move's child
//     3. simulation      from the new child's position, play random legal moves until a player reaches the goal
//     4. backpropagation from the new child back to the root, every node counts one visit more, and a win more when
//                        the player who made its move is the playout's winner
//
// UCB1 weighs what a move has won against how little it has been tried:
//
//     bound(child) = wins / visits  +  c * sqrt( ln(parent's visits) / visits )
//
//                  = wins / visits  +  c * sqrt(ln(parent's visits))  /  sqrt(visits)
//                                      '-------- the same for every child of one parent: worked out once
//
// The first term favours the moves that have won; the second grows for a move left untried while its siblings are
// played, so every move is tried again from time to time and none is written off on a few unlucky playouts. The
// constant c sets the balance. sqrt(2) is the value for which UCB1's guarantee is proven when results are 0 or 1; but
// that guarantee is about trying every move enough in the long run, and a search of a few thousand iterations does
// better to deepen its best moves sooner - this one uses 0.6, which plays Atari Go stronger.
// A node's wins are counted for the player who made its move - the player choosing among it and its siblings at
// the parent - so at every level the bound measures the move from the point of view of the player who would make it.
//
// After the iterations, the move played is the root's most visited child - or, when the root has one candidate only (a
// capture that wins, the only legal move), that move at once, with no time spent on a choice there is not. Visits are
// the steadier measure: a win rate can be inflated by a few lucky playouts, but the search sends its visits to the
// move whose wins hold up.
//
//     2000 iterations, black to play, a goal of one capture:
//
//         . . a . .        the root's children, most visited first:
//         . X O X .            a  (0, 2)   148 visits, 296 of 296 half-wins - it captures, and wins at once
//         . . X . .               (0, 3)   136 visits, 268 of 272 half-wins
//         . . . . .               (0, 1)   136 visits, 268 of 272 half-wins
//         . . . . .               ... 18 more
//
// Every playout through a is a win, so its win rate is 1 and it gets the most visits. The other moves are nearly as
// good, and the search says so: the white stone cannot escape - extending to a leaves it one liberty, and black takes
// it there - so after almost any move black still wins. The exploration term keeps giving them a share, and the
// more iterations, the larger a's lead.
//
// THE TREE IS ONE ARRAY. Its nodes are `extern struct`s in one array, joined by indices rather than pointers: a node
// names its parent, its first child and its next sibling. So the tree is one contiguous block of bytes, which can be
// handed to a job and taken back whole, with nothing to fix up, and an `extern struct`'s layout is the same in every
// compile. A node does not store its untried moves: a node's children are made in the order of its position's
// candidate moves (`candidateMoves`, below; the legal moves among them are the rules' to say - ko, suicide and a game
// already won are never the search's business), so a count of the children made says which candidate is next. A
// node's candidates are counted the first time an iteration expands it, not when it is made: most nodes are made by
// one iteration and never reached again, and counting them takes a pass over the board. Wins are counted in
// HALF-WINS - 2 for a win, 1 for a playout that ended undecided - so every count is an integer.
//
// Each iteration starts from a copy of the root position - a Position is fixed arrays, so the copy is one memory
// copy, and nothing is allocated - and plays the selected moves on it; the root position itself is only read. The
// random generator the playouts draw from keeps its state in the tree, so a search continued later draws the same
// numbers as one run without a pause: the same seed and the same count of iterations give the same tree.
//
// THE TREE IS KEPT BETWEEN MOVES. After the computer's move and the reply, the node of that pair of moves is the root
// of a subtree the last search already explored, and its visits are a head start for the next one:
//
//         root  (the computer to play)                       the next search's root, copied out with
//          |- a   the computer's move ............                everything under it:
//          |   |- b   the person's reply  ........  ---->     b'
//          |   |   |- ...                                       |- ...
//          |   '- ...
//          '- ...
//
// So a tree records which game it belongs to: how many of the record's moves had been played at its root, and a
// fingerprint of the root's position. A later search replays the record to that point and compares fingerprints;
// if they agree, it follows the moves played since through the tree's children, and the node it reaches becomes
// the root of a fresh array holding its subtree (`takeUpSubtree`). A tree that does not lead there - a new game, an
// undo, a pasted position, a reply the search never tried - is not taken up, and the search starts afresh.
// `continueSearch` does all of it, given the record and the last tree. When no move has been played since the last
// tree's root - a search cut into slices, one after another - the tree is the search's own, and goes on in place;
// since its generator's state goes on with it, the slices make the very tree one search of all their iterations
// would have made.
//
// A tree goes to a job and comes back as bytes: its header, then its nodes (`writeTree`, `readTree`). Both are
// `extern struct`s, so their bytes mean the same to the program and to the job's separate compile.
//
// THE SEARCH AS A JOB. A search of a second would hold up the program's frames for a second, so it runs as a job of
// zimr's job system (`z.jobs`): a pure function, run on a worker of its own - a Web Worker in a page, a thread in a
// native program - while the board keeps drawing. A job is given a small header and a payload of bytes, and writes
// its result as bytes; it keeps nothing from one job to the next. So everything the search needs travels with it:
//
//     header    SearchJobHeader: the settings, the count of iterations, the seed of a fresh tree
//     payload   the record - the board, the goal, the setup stones, the moves played - then the last tree's bytes,
//               or nothing when there is none
//     result    the tree after the iterations, as bytes
//
// The job runs in a separate compile, whose plain structs need not be laid out as the program's are, so every byte
// that crosses is an `extern struct`'s or a plain number's, and the record is written field by field rather than
// copied whole (`writeSearchPayload`, `readSearchPayload`). The job itself is `searchJob`, listed in `kernels.zig`.
//
// DECISIVE MOVES. A node's candidate moves are its legal moves - unless its player can win at once, by a capture that
// brings their prisoners to the goal: then the winning moves are its only candidates (Teytaud and Teytaud, 2010). The
// search must otherwise make every child of a node before it chooses among them, and a reply that wins is only as
// early among them as its point is on the board. Here white must escape at a, and every other move loses:
//
//         . . . . . . . . .
//         . . . . . . . . .      black's last move left white's stone at (3, 4) one liberty, a. Under each of white's
//         . . . . X . . . .      76 moves but a, black's winning capture at a is a reply among 75, about the 33rd
//         . . . X O a . . .      made; until it is, black's replies are moves at random, and the losing move looks
//         . . . O X . . . .      sound - on 5,000 iterations, white chose (4, 5), and lost. With decisive moves,
//         . . . . . . . . .      black's one candidate under each such move is the capture: it wins every playout,
//         . . . . . . . . .      and a few visits bring the move's win rate to nothing. Then the visits go to a.
//
// A PLAYOUT plays moves until a player reaches the goal. A LIGHT playout draws every move uniformly at random from the
// legal moves. A HEAVY one first plays the URGENT MOVE, the two that matter most in Atari Go:
//
//     capture: a group of the opponent's is in atari    rescue: a group of one's own is in atari
//
//         . . . . .                                         . . . . .
//         . . X . .     white's stone has one liberty,      . . O . .     black's stone has one liberty, at a:
//         . X O X .     at a: black captures it there       . O X a .     black extends there
//         . . a . .     (with a goal of one, that wins)     . . O . .
//         . . . . .                                         . . . . .
//
// A capture comes before a rescue, and among several of a kind one is drawn at random. When neither applies, the move
// is a random legal move. Random play misses both: it leaves a capturable group standing, or lets its own be taken,
// about as often as not, so a light playout's result says little about the position it started from. Playing the
// urgent moves makes the playouts play the way the game is decided, and each playout tells the search more.
//
// The urgent moves are looked for over the whole board, not only around the last move. A group can stay in atari
// across several moves - its owner played elsewhere - and a playout that looked only at the last move would leave it
// standing; the search would then judge leaving a group in atari to be nearly safe, which in Atari Go is the one
// thing it is not. The look costs one pass over the board's roots, the same order as the listing of empty points a
// random move makes.
//
// A playout that finds no legal move, or is still undecided after `playout_move_cap` moves, counts as half a win for
// each side.

/// How a playout chooses its moves (the section's lesson). A byte, as it travels in a job's header.
pub const PlayoutKind = enum(u8) {
    /// Every move drawn uniformly at random from the legal moves.
    light,
    /// The urgent move first - capture an opponent's group in atari, else rescue one of one's own - and a random
    /// legal move when there is none.
    heavy,
};

/// How a search's move is chosen from the root's children (the section's lesson). A byte, as it travels in a job's
/// header.
pub const MoveChoice = enum(u8) {
    /// The most visited child: the visits go to the move whose wins hold up.
    most_visited,
    /// The child whose win rate is most surely high (KataGo's lower confidence bound): its win rate less
    /// `confidence_stdevs` standard errors, among the children with at least `confidence_min_share` of the most
    /// visited child's visits. When two moves are close, the one whose lead is surer.
    confidence_bound,
};

/// The most weakest groups a cut-short playout's score compares (`SearchSettings.cut_groups_compared`).
const max_groups_compared: usize = 4;

/// The liberties of `colour`'s weakest groups in `position`, fewest first, written into `out` - as many as it holds;
/// a place with no group left counts as `maxInt(u32)`, a group with no danger at all.
fn weakestLibertyCounts(position: *const Position, colour: Stone, out: []u32) void {
    @memset(out, maxInt(u32));
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const is_root: bool = position.stones[point] == colour and isRoot(position, point);
        if (!is_root) {
            continue;
        }
        var liberty_count: u32 = @intCast(position.group_liberties[point].count());
        // Into its place among the fewest so far, the larger ones moving up.
        for (out) |*slot| {
            if (liberty_count < slot.*) {
                const displaced: u32 = slot.*;
                slot.* = liberty_count;
                liberty_count = displaced;
            }
        }
    }
}

/// Who a cut-short playout goes to when both players' weakest groups have as many liberties
/// (`SearchSettings.cut_tie`).
pub const CutTie = enum(u8) {
    /// Half a win to each - undecided. A playout always stops after the same number of moves, so the player to move
    /// at its end is the player to move where it began, which alternates with the depth of the node it began from:
    /// a tie given to either player would tilt a move's rating with how deep the tree under it happens to reach.
    half,
    /// The player to move, who presses first - right for two groups in a capturing race, a tilt by depth elsewhere.
    player_to_move,
};

/// What the search is told: how far it explores, and how its playouts are played. An `extern struct`, since it travels
/// in a job's header (the section's lesson).
pub const SearchSettings = extern struct {
    /// UCB1's exploration constant c (the section's lesson): larger tries more moves, smaller deepens the best ones.
    /// 0.3, far below UCB1's sqrt(2). On go puzzles hero's board (10 x 10, the search's own choice every move, 400
    /// games at 500 iterations a move), with playouts cut after 10 moves: 0.3 won 60.3% against 0.6, 1.0 47.5%, and
    /// at 2,000 iterations 0.2 won 69.5% of 200 against 0.6. With playouts cut after 2 and their score comparing three
    /// groups - ratings nearer even, which need a larger term to tell the moves apart: 0.3 won 53.8% against 0.2,
    /// 0.1 42.8%, 0.4 47.5% against 0.3, and at 2,000 iterations 0.3 won 53.5% of 200 against 0.2.
    exploration: f32 = 0.3,
    /// A playout still undecided after this many moves stops, and counts as half a win for each side.
    playout_move_cap: u32 = 1000,
    /// Cut-short playouts (the section's lesson): a game's playout that has played this many moves stops there, and
    /// is scored by its liberties (`cutShortWinner`) rather than played on at random - in Atari Go the first capture
    /// wins, so the player whose weakest groups have fewer liberties is the one in danger. 0, never: each playout
    /// plays to its end. A problem's playouts always do, its question a group's life, not a race to a capture; so do
    /// a game's whose goal is more than one capture, which the score - knowing no prisoners - cannot judge. 2: the
    /// tree does the reading, a playout's random moves only blur what the score sees. On go puzzles hero's board
    /// (10 x 10, exploration 0.2, the search's own choice, 400 games at 500 iterations a move): 6 won 61.0% against
    /// 10 and 15 39.8%; 3 won 57.8% against 6, 4 54.8%; 2 won 58.8% against 3, 1 56.0%; and at 2,000 iterations 2 won
    /// 78.0% of 200 against 10 - at equal iterations, and a shorter playout costs less besides.
    playout_cutoff: u32 = 2,
    /// Who a cut-short playout goes to when both players' weakest groups have as many liberties (`CutTie`).
    cut_tie: CutTie = .half,
    /// How many of each player's weakest groups a cut-short playout's score compares (`cutShortWinner`), the weakest
    /// first: a tie between the weakest is broken by the second weakest, and so on - so that a quiet position, its
    /// weakest groups level, is still judged rather than called even. 1, the weakest alone. 3 won 57.8% against 1
    /// (400 games at 500 iterations), and 4 51.2% against 3.
    cut_groups_compared: u32 = 3,
    /// How each playout chooses its moves.
    playout_kind: PlayoutKind = .heavy,
    /// Progressive widening (the section's lesson; Chaslot, Winands, van den Herik, Uiterwijk and Bouzy, 2008): a node
    /// may have `widening_base + widening_growth * sqrt(visits)` children, its candidates made in their order - the
    /// near moves first (`nearMoves`) - and its visits go to the children it has until it earns another. The search
    /// then reads the likely moves deeply before it tries the rest. A growth of 0 is no widening: every candidate
    /// gets its child before any is visited twice. 4 and 1.0: in the arena (8 x 8, two outposts each, 1,000
    /// iterations a move) it won 59 of 80 games against no widening; on goban's problems it settled on the book's
    /// first move in about half the iterations (3,466 against 6,687, on 17 of them).
    widening_base: u32 = 4,
    widening_growth: f32 = 1.0,
    /// Whether a heavy playout reads ladders in a game (the section's lesson; KataGo's ladder search): an escape from
    /// atari that a ladder would capture is no urgent move. The reading copies a position for each level it goes down,
    /// up to `ladder_depth` levels - deeper, the ladder counts as working - and visits at most `ladder_budget`
    /// positions - more, and it counts as failing, the escape left to stand. In the arena (8 x 8, two outposts each,
    /// 80 games each) it won 56.3% at equal iterations and 58.8% at equal time. Not in a problem, whose target's
    /// escapes are the problem's own fight, read by the search: there the hard problems fared worse with it.
    ladder_reading: bool = true,
    ladder_depth: u32 = 24,
    ladder_budget: u32 = 64,
    /// How the move is chosen from the root's children (`MoveChoice`), and the confidence bound's measures. The bound:
    /// in the arena (8 x 8, two outposts each, 1,000 iterations a move) it won 77 of 140 games against the most
    /// visited move, 55.0% +- 4.2 - a small gain, at no cost, since it only reads the tree.
    choice: MoveChoice = .confidence_bound,
    confidence_stdevs: f32 = 3,
    confidence_min_share: f32 = 0.15,
    /// When the computer plays the fighting move instead of the search's choice (`playedMove`) - only where the
    /// result cannot change. A lost position: the chosen move wins less often than `lost_below_rate`, so every move
    /// loses, and the fighting move is the honest one rather than a random-looking resignation. A tenuki between
    /// equals: the chosen move is more than `tenuki_lines` from the fight (`isTenuki`), and a move near the fight is
    /// as good - its win rate within `equal_rate_margin` of the chosen's, with at least `equal_min_share` of its
    /// visits (`equalMovesNearFight`). Never in a winning position, and never for a move the search rates worse; with
    /// `fights_tenuki` off, only the lost case. A looser rule - every decided position, winning ones too, and any
    /// rival within two standard errors - played moves 12 to 16 points worse on average, and won 14.0% against the
    /// search's own choice (10 x 10, 500 iterations a move, 400 games).
    lost_below_rate: f32 = 0.05,
    /// A won position (`playedMove`): the chosen move wins more often than this. The fighting move is then played
    /// among the moves still rated above it (`movesStillWinning`), so that the computer closes in on its win - the
    /// attack - rather than playing whichever winning move the visits went to.
    won_above_rate: f32 = 0.95,
    /// A tenuki with no move near the fight as good (`equalMovesNearFight`): with this on, the fighting move - the
    /// attack on the opponent's weakest group, or the defence of its own - among all the moves, rather than the
    /// tenuki.
    attacks_after_tenuki: bool = true,
    fights_tenuki: bool = true,
    tenuki_lines: u32 = 2,
    /// The groups a tenuki is measured from (`isTenuki`): those with at most this many liberties - under pressure.
    fight_liberties: u32 = 3,
    /// The margin of an equal move: 4 points, about two standard errors of the difference between two moves at the
    /// thousand or so visits each has in a second's search - where the search cannot tell them apart. In a standoff,
    /// where both players' groups are about as weak, random playouts rate a move that touches nothing a few points
    /// above one in contact - almost a pass, it leaves the reply no new contact to strike at - so the search's own
    /// choice there is a stone alone in a corner or on an edge, and the margin lets the fight's move be played.
    equal_rate_margin: f32 = 0.04,
    equal_min_share: f32 = 0.25,
};

/// The points a move may be played on as a rectangle: a problem's region, or the whole board. Every stone stands in
/// it too - a problem's region is the box around its stones - so a scan for groups need look nowhere else; and its
/// rows, then its columns, in order visit the points in the order of the points.
pub fn playableRegion(position: *const Position) ProblemRegion {
    const last_line: u8 = position.board_size - 1;
    const whole_board: ProblemRegion = .{
        .first_row = 0,
        .first_col = 0,
        .last_row = last_line,
        .last_col = last_line,
    };
    return position.region orelse whole_board;
}

/// The legal moves of the player to move, in the order of the points, written into `out_buffer`.
pub fn legalMoves(position: *const Position, out_buffer: *[board_limits.max_points]Point) []const Point {
    var legal_moves: ArrayList(Point) = .initBuffer(out_buffer);
    const region: ProblemRegion = playableRegion(position);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const point: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const move_is_legal: bool = checkMove(position, point) == .legal;
            if (move_is_legal) {
                legal_moves.appendAssumeCapacity(point);
            }
        }
    }
    return legal_moves.items;
}

/// The only liberty of the group standing on `point` - a group in atari - or null when it has more than one.
fn soleLiberty(position: *const Position, point: Point) ?Point {
    const root: Point = findRoot(position, point);
    const liberties: *const PointSet = &position.group_liberties[root];
    const group_is_in_atari: bool = liberties.count() == 1;
    if (!group_is_in_atari) {
        return null;
    }
    const liberty: Point = @intCast(liberties.findFirstSet().?);
    return liberty;
}

/// The moves that win at once for the player to move (the section's lesson): legal captures that bring their prisoners
/// to the goal - each on the one liberty of a group of the opponent's in atari - written into `out_buffer`, each point
/// once. None in a game with no goal.
pub fn winningMoves(position: *const Position, out_buffer: *[board_limits.max_points]Point) []const Point {
    var winning: ArrayList(Point) = .initBuffer(out_buffer);
    // A problem's one winning move: the capture of the target's group, by its opponent, when it is in atari.
    if (position.target) |target| {
        // A target already captured leaves no move to win with.
        const target_stands: bool = position.stones[target] != .none;
        const attacker_to_play: bool = target_stands and position.player_to_move == position.stones[target].opponent();
        if (attacker_to_play) {
            if (soleLiberty(position, target)) |capturing_point| {
                if (checkMove(position, capturing_point) == .legal) {
                    winning.appendAssumeCapacity(capturing_point);
                }
            }
        }
        return winning.items;
    }
    const capture_goal: u8 = position.capture_goal orelse {
        return winning.items;
    };
    const mover: Stone = position.player_to_move;
    const prisoners_before: u32 = prisonersOf(position, mover);
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const is_opponent_root: bool = position.stones[point] == mover.opponent() and isRoot(position, point);
        if (!is_opponent_root) {
            continue;
        }
        const capturing_point: Point = soleLiberty(position, point) orelse {
            continue;
        };
        const already_listed: bool = indexOfScalar(Point, winning.items, capturing_point) != null;
        if (already_listed) {
            continue;
        }
        // Every group the move takes counts, not only this one: one stone can capture several.
        var captured_buffer: [board_limits.max_neighbors]Point = undefined;
        const captured_roots: []const Point = groupsCapturedBy(position, capturing_point, &captured_buffer);
        var stones_captured: u32 = 0;
        for (captured_roots) |captured_root| {
            stones_captured += @intCast(position.group_stones[captured_root].count());
        }
        const reaches_goal: bool = prisoners_before + stones_captured >= capture_goal;
        if (reaches_goal) {
            winning.appendAssumeCapacity(capturing_point);
        }
    }
    // In the order of the points, as every kind of candidate list is.
    sortSlice(Point, winning.items, {}, std.sort.asc(Point));
    return winning.items;
}

/// Whether `move` is a capture that wins at once for the player to move: the stones of every group it takes bring the
/// player's prisoners to the goal.
fn isWinningCapture(position: *const Position, move: Point) bool {
    if (position.target) |target| {
        const target_stands: bool = position.stones[target] != .none;
        const attacker_to_play: bool = target_stands and position.player_to_move == position.stones[target].opponent();
        return attacker_to_play and soleLiberty(position, target) == move;
    }
    const capture_goal: u8 = position.capture_goal orelse {
        return false;
    };
    var captured_buffer: [board_limits.max_neighbors]Point = undefined;
    const captured_roots: []const Point = groupsCapturedBy(position, move, &captured_buffer);
    var stones_captured: u32 = 0;
    for (captured_roots) |captured_root| {
        stones_captured += @intCast(position.group_stones[captured_root].count());
    }
    const prisoners_before: u32 = prisonersOf(position, position.player_to_move);
    return captured_roots.len > 0 and prisoners_before + stones_captured >= capture_goal;
}

/// Which kind of list a node's candidates are (`candidateMoves`): each the points, in order, that are legal moves and
/// meet one test - so the next candidate after one is found by testing the points past it.
/// A problem's target's neighbourhood (the section's lesson): its group's liberties, and the empty points beside
/// each - where the fight for the group is. Null when there is no target, or it has been captured.
fn targetNeighbourhood(position: *const Position) ?PointSet {
    const target: Point = position.target orelse {
        return null;
    };
    if (position.stones[target] == .none) {
        return null;
    }
    const root: Point = findRoot(position, target);
    const liberties: PointSet = position.group_liberties[root];
    var near: PointSet = liberties;
    var liberty_points: PointSet.Iterator(.{}) = liberties.iterator(.{});
    while (liberty_points.next()) |liberty_index| {
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        for (neighborsOf(position.board_size, @intCast(liberty_index), &neighbor_buffer)) |neighbor| {
            if (position.stones[neighbor] == .none) {
                near.set(neighbor);
            }
        }
    }
    return near;
}

/// The moves a search tries first (the section's lesson): where the fight is. The liberties of every group of one or
/// two liberties, either colour's - its capture, its escape, the atari that threatens it - the empty points around
/// the last move, diagonals included, which answer it; and in a problem the target's neighbourhood
/// (`targetNeighbourhood`). Empty points only; legality is the candidates' test.
pub fn nearMoves(position: *const Position) PointSet {
    var near: PointSet = .empty;
    const region: ProblemRegion = playableRegion(position);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const point: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const is_root: bool = position.stones[point] != .none and isRoot(position, point);
            if (!is_root) {
                continue;
            }
            const liberties: PointSet = position.group_liberties[point];
            if (liberties.count() <= 2) {
                near.setUnion(liberties);
            }
        }
    }
    if (position.last_move) |last_move| {
        const board_size: u8 = position.board_size;
        const last_row: i32 = rowOf(board_size, last_move);
        const last_col: i32 = colOf(board_size, last_move);
        for ([_]i32{ -1, 0, 1 }) |row_step| {
            for ([_]i32{ -1, 0, 1 }) |col_step| {
                const row: i32 = last_row + row_step;
                const col: i32 = last_col + col_step;
                const on_board: bool = row >= 0 and col >= 0 and row < board_size and col < board_size;
                if (!on_board) {
                    continue;
                }
                const point: Point = pointAt(board_size, @intCast(row), @intCast(col));
                if (position.stones[point] == .none) {
                    near.set(point);
                }
            }
        }
    }
    if (targetNeighbourhood(position)) |neighbourhood| {
        near.setUnion(neighbourhood);
    }
    return near;
}

pub const CandidateKind = enum(u8) {
    /// Every legal move.
    legal,
    /// The captures that win at once.
    winning,
};

/// A node's candidates, and which kind of list they are.
pub const Candidates = struct {
    moves: []const Point,
    kind: CandidateKind,
};

/// A node's candidate moves, in the order its children are made (the section's lesson): the moves that win at once if
/// there are any, in the order of the points; else every legal move, the near ones first (`nearMoves`) and then the
/// rest, each in the order of the points - so that the next candidate after one can be found from it alone
/// (`nextCandidate`).
pub fn candidateMoves(position: *const Position, out_buffer: *[board_limits.max_points]Point) Candidates {
    const winning: []const Point = winningMoves(position, out_buffer);
    if (winning.len > 0) {
        return .{ .moves = winning, .kind = .winning };
    }
    const legal: []const Point = legalMoves(position, out_buffer);
    // The near moves to the front, the rest after them, each part keeping the order of the points.
    const near: PointSet = nearMoves(position);
    var far_buffer: [board_limits.max_points]Point = undefined;
    var far: ArrayList(Point) = .initBuffer(&far_buffer);
    var near_count: usize = 0;
    for (legal) |move| {
        if (near.isSet(move)) {
            out_buffer[near_count] = move;
            near_count += 1;
        } else {
            far.appendAssumeCapacity(move);
        }
    }
    @memcpy(out_buffer[near_count..][0..far.items.len], far.items);
    return .{ .moves = out_buffer[0 .. near_count + far.items.len], .kind = .legal };
}

/// Which side of a set a candidate must be on (`nextCandidate`): inside it, or outside.
const CandidateSide = struct {
    set: PointSet,
    inside: bool,
};

/// The first legal move at or past the point `first_index`, on `side` of its set.
fn firstMoveFrom(
    position: *const Position,
    first_index: usize,
    side: CandidateSide,
) ?Point {
    var point_index: usize = first_index;
    while (point_index < pointCount(position.board_size)) : (point_index += 1) {
        const point: Point = @intCast(point_index);
        const on_side: bool = side.set.isSet(point) == side.inside;
        if (on_side and checkMove(position, point) == .legal) {
            return point;
        }
    }
    return null;
}

/// The first point past `after` that is a candidate of `kind`, on `side` of its set when there is one.
fn firstMovePast(
    position: *const Position,
    after: Point,
    kind: CandidateKind,
    side: ?CandidateSide,
) ?Point {
    const first_index: usize = @as(usize, after) + 1;
    if (kind == .winning) {
        var point_index: usize = first_index;
        while (point_index < pointCount(position.board_size)) : (point_index += 1) {
            const point: Point = @intCast(point_index);
            const is_legal: bool = checkMove(position, point) == .legal;
            if (is_legal and isWinningCapture(position, point)) {
                return point;
            }
        }
        return null;
    }
    return firstMoveFrom(position, first_index, side.?);
}

/// The first candidate of a list of `kind` past `after` - the point of the candidate before it - or null when there is
/// none (the section's lesson): the points past it tried in order, each a legal move meeting the kind's test. What a
/// node's later expansions use, instead of making its whole list again.
pub fn nextCandidate(
    position: *const Position,
    kind: CandidateKind,
    after: Point,
) ?Point {
    switch (kind) {
        .winning => return firstMovePast(position, after, .winning, null),
        .legal => {
            // The near moves come first, the rest after them: past a near move, the next near one, or the first of
            // the rest; past one of the rest, the next of the rest.
            const near: PointSet = nearMoves(position);
            if (near.isSet(after)) {
                if (firstMovePast(position, after, .legal, .{ .set = near, .inside = true })) |next_near| {
                    return next_near;
                }
                return firstMoveFrom(position, 0, .{ .set = near, .inside = false });
            }
            return firstMovePast(position, after, .legal, .{ .set = near, .inside = false });
        },
    }
}

/// One node of the search tree: a position reached from its parent's by one move, with the statistics of the
/// playouts that went through it. Nodes live in one array (`SearchTree`) and name each other by index.
pub const SearchNode = extern struct {
    /// The move from the parent's position to this one. The root's is unused.
    move: Point,
    /// How many candidate moves this node's position has (`candidateMoves`) - the children it will have once fully
    /// expanded - or `not_counted` before the node is first expanded (the section's lesson). Zero where the game is
    /// won or no move is legal: a leaf for good.
    candidate_count: u16,
    /// How many children have been made. Children are made in the order of `candidateMoves`, so the next is the
    /// candidate at this index.
    children_made: u16,
    /// The player who made `move`: the player whose wins `half_wins` counts. The root's is the player to move's
    /// opponent, and unused.
    mover: Stone,
    /// Which kind of list the node's candidates are, once counted (`CandidateKind`): what a later expansion asks of a
    /// point to find the next one. In the byte the fields above leave before `parent`, so every byte of a node is a
    /// field's.
    candidate_kind: CandidateKind = .legal,
    /// The parent's index; `none` for the root.
    parent: u32,
    /// The newest child's index; `none` before the first child is made.
    first_child: u32,
    /// The next older sibling's index; `none` for the oldest.
    next_sibling: u32,
    /// The playouts that went through this node.
    visits: u32,
    /// Of those, 2 for each the mover won and 1 for each that ended undecided.
    half_wins: u32,

    /// The index that names no node.
    pub const none: u32 = maxInt(u32);
    /// The `candidate_count` of a node not yet expanded.
    pub const not_counted: u16 = maxInt(u16);

    /// Whether the node has every child its visits allow it so far (`SearchSettings.widening_base`): with widening, the
    /// count grows with the square root of its visits; without, every candidate's - the node fully expanded.
    fn hasEveryChildAllowed(node: *const SearchNode, settings: SearchSettings) bool {
        if (node.isFullyExpanded()) {
            return true;
        }
        if (settings.widening_growth <= 0 or node.candidate_count == not_counted) {
            return false;
        }
        const allowed: f32 = float(settings.widening_base) + settings.widening_growth * @sqrt(float(node.visits));
        return float(node.children_made) >= allowed;
    }

    /// Whether every candidate move of the node has its child - false before its candidates are counted.
    fn isFullyExpanded(node: *const SearchNode) bool {
        const moves_are_counted: bool = node.candidate_count != not_counted;
        const fully_expanded: bool = moves_are_counted and node.children_made == node.candidate_count;
        return fully_expanded;
    }

    /// How often the node's mover won its playouts: half its half-wins over its visits - a draw counting half - and
    /// zero before its first visit.
    pub fn winRate(node: *const SearchNode) f32 {
        const half_wins: f32 = float(node.half_wins);
        const visits: f32 = float(@max(node.visits, 1));
        return half_wins / (2 * visits);
    }
};

/// Copies `from` into `to` the way `to.* = from.*` would, but of the arrays with an entry for each point only the
/// board's points (the section's lesson): a position's arrays are as long as the largest board's, and an 8 x 8 board
/// uses 64 of their 361 entries. No code reads an entry past the board's points, so the stale ones `to` keeps there do
/// no harm. A search copies its root's position at every iteration (`runIteration`), on a small board a sixth as much.
pub fn copyPosition(to: *Position, from: *const Position) void {
    const point_count: usize = pointCount(from.board_size);
    // A full-size board uses every entry: one whole copy is quicker than one a field.
    if (point_count == board_limits.max_points) {
        to.* = from.*;
        return;
    }
    const struct_info: std.lang.Type.Struct = @typeInfo(Position).@"struct";
    inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
        const field_info: std.lang.Type = @typeInfo(field_type);
        const is_point_array: bool = field_info == .array and field_info.array.len == board_limits.max_points;
        if (is_point_array) {
            @memcpy(@field(to, field_name)[0..point_count], @field(from, field_name)[0..point_count]);
        } else {
            @field(to, field_name) = @field(from, field_name);
        }
    }
}

/// A 64-bit hash of what decides a position's future: the board's size and stones, the player to move, the ko point,
/// the prisoners, the capture goal, a problem's target and region, and the winner. Two positions with the same
/// fingerprint are, but for a one in 2^64 chance, the same position.
pub fn positionFingerprint(position: *const Position) u64 {
    // An optional is hashed as a plain number, one no value can be standing for null: the bytes of a null optional
    // include its value's, which the language leaves undefined.
    const ko_code: u32 = if (position.ko_point) |ko_point| ko_point else maxInt(u32);
    const goal_code: u32 = if (position.capture_goal) |capture_goal| capture_goal else maxInt(u32);
    const winner_code: u32 = if (position.winner) |winner| @backingInt(winner) else maxInt(u32);
    const target_code: u32 = if (position.target) |target| target else maxInt(u32);
    const region: ProblemRegion = position.region orelse .{
        .first_row = maxInt(u8),
        .first_col = maxInt(u8),
        .last_row = maxInt(u8),
        .last_col = maxInt(u8),
    };
    const region_bytes = [4]u8{ region.first_row, region.first_col, region.last_row, region.last_col };
    const stones_in_use: []const Stone = position.stones[0..pointCount(position.board_size)];
    var hasher: Wyhash = .init(0);
    hasher.update(asBytes(&position.board_size));
    hasher.update(sliceAsBytes(stones_in_use));
    hasher.update(asBytes(&position.player_to_move));
    hasher.update(asBytes(&ko_code));
    hasher.update(asBytes(&position.stones_captured_by_black));
    hasher.update(asBytes(&position.stones_captured_by_white));
    hasher.update(asBytes(&goal_code));
    hasher.update(asBytes(&target_code));
    hasher.update(&region_bytes);
    hasher.update(asBytes(&winner_code));
    const fingerprint: u64 = hasher.final();
    return fingerprint;
}

/// What a tree is besides its nodes: how many are in use, which game it belongs to, and its generator's state. An
/// `extern struct`, so that it travels in bytes with the nodes (the section's lesson).
pub const SearchTreeHeader = extern struct {
    /// How many nodes are in use, from node 0, the root.
    node_count: u32,
    /// How many of the game record's moves had been played at the root's position.
    root_moves_played: u32,
    /// The root position's `positionFingerprint`: with `root_moves_played`, what says the tree belongs to the game a
    /// later search continues.
    root_fingerprint: u64,
    /// The state of the random generator the playouts draw from, so that a search continued draws the numbers it
    /// would have drawn without a pause.
    random_state: [4]u64,
};

/// The search's tree: its header, and its nodes, the first `header.node_count` of `nodes` in use.
pub const SearchTree = struct {
    header: SearchTreeHeader,
    nodes: []SearchNode,

    /// A tree of one node, the root, for a search from `root_position`, reached after `root_moves_played` moves of
    /// its game's record; its nodes kept in `node_buffer` (at least one node long; each iteration adds at most one)
    /// and its generator seeded with `seed`.
    pub fn init(
        node_buffer: []SearchNode,
        root_position: *const Position,
        root_moves_played: u32,
        seed: u64,
    ) SearchTree {
        assertf(node_buffer.len >= 1, @src(), "SearchTree.init: a tree needs room for its root", .{});
        // Only a game with a goal ends on its own; a playout of plain Go would only ever stop at the move cap.
        const has_a_goal: bool = root_position.capture_goal != null or root_position.target != null;
        assertf(has_a_goal, @src(), "SearchTree.init: the search plays Atari Go and problems only", .{});
        node_buffer[0] = .{
            .move = 0,
            .mover = root_position.player_to_move.opponent(),
            .candidate_count = SearchNode.not_counted,
            .children_made = 0,
            .parent = SearchNode.none,
            .first_child = SearchNode.none,
            .next_sibling = SearchNode.none,
            .visits = 0,
            .half_wins = 0,
        };
        const seeded_generator: Xoshiro256 = .init(seed);
        const tree: SearchTree = .{
            .header = .{
                .node_count = 1,
                .root_moves_played = root_moves_played,
                .root_fingerprint = positionFingerprint(root_position),
                .random_state = seeded_generator.s,
            },
            .nodes = node_buffer,
        };
        return tree;
    }
};

/// The factor of UCB1's exploration term that every child of one parent shares (the section's lesson):
/// c * sqrt(ln(parent's visits)).
pub fn explorationFactor(parent_visits: u32, exploration: f32) f32 {
    const log_parent_visits: f32 = ln(float(parent_visits));
    const factor: f32 = exploration * sqrt(log_parent_visits);
    return factor;
}

/// UCB1 (the section's lesson) for a child visited at least once: its win rate plus `exploration_factor` - the
/// parent's `explorationFactor` - over the square root of its visits.
pub fn upperConfidenceBound(
    child_half_wins: u32,
    child_visits: u32,
    exploration_factor: f32,
) f32 {
    const visits: f32 = float(child_visits);
    const win_rate: f32 = float(child_half_wins) / (2 * visits);
    const exploration_term: f32 = exploration_factor / sqrt(visits);
    return win_rate + exploration_term;
}

/// The child of `parent_index` with the highest upper confidence bound; the newest of equals. The parent has at
/// least one child, and each child has been visited, since the iteration that made it visited it.
fn childWithHighestBound(
    tree: *const SearchTree,
    parent_index: u32,
    exploration: f32,
) u32 {
    const parent: *const SearchNode = &tree.nodes[parent_index];
    const exploration_factor: f32 = explorationFactor(parent.visits, exploration);
    var best_index: u32 = SearchNode.none;
    var best_bound: f32 = -inf(f32);
    var child_index: u32 = parent.first_child;
    while (child_index != SearchNode.none) {
        const child: *const SearchNode = &tree.nodes[child_index];
        const bound: f32 = upperConfidenceBound(child.half_wins, child.visits, exploration_factor);
        if (bound > best_bound) {
            best_bound = bound;
            best_index = child_index;
        }
        child_index = child.next_sibling;
    }
    assertf(best_index != SearchNode.none, @src(), "childWithHighestBound: node {d} has no child", .{parent_index});
    return best_index;
}

/// Adds a child under `parent_index`: the position after `move`, made by `mover`, its moves not yet counted. Returns
/// its index.
fn addChild(
    tree: *SearchTree,
    parent_index: u32,
    move: Point,
    mover: Stone,
) u32 {
    const child_index: u32 = tree.header.node_count;
    const parent: *SearchNode = &tree.nodes[parent_index];
    tree.nodes[child_index] = .{
        .move = move,
        .mover = mover,
        .candidate_count = SearchNode.not_counted,
        .children_made = 0,
        .parent = parent_index,
        .first_child = SearchNode.none,
        .next_sibling = parent.first_child,
        .visits = 0,
        .half_wins = 0,
    };
    parent.first_child = child_index;
    parent.children_made += 1;
    tree.header.node_count += 1;
    return child_index;
}

/// A legal move of the player to move, drawn uniformly at random, or null when none is legal. The empty points are
/// listed and one drawn; an illegal one is struck from the list and another drawn, so every legal move is equally
/// likely and the cost stays close to one listing of the board.
/// Whether `point`, empty, is an eye of the player to move's (the section's lesson): every neighbour the player's
/// stone, and the diagonal points not the opponent's enough to make it false - two of them in the middle of the board,
/// one at its edge or in its corner, would let the opponent cut the stones around it apart.
pub fn isOwnEye(position: *const Position, point: Point) bool {
    const mover: Stone = position.player_to_move;
    var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
    for (neighborsOf(position.board_size, point, &neighbor_buffer)) |neighbor| {
        if (position.stones[neighbor] != mover) {
            return false;
        }
    }
    const row: i32 = rowOf(position.board_size, point);
    const col: i32 = colOf(position.board_size, point);
    const last_line: i32 = position.board_size - 1;
    var diagonals_on_board: u32 = 0;
    var opponent_diagonals: u32 = 0;
    for ([_][2]i32{ .{ -1, -1 }, .{ -1, 1 }, .{ 1, -1 }, .{ 1, 1 } }) |step| {
        const diagonal_row: i32 = row + step[0];
        const diagonal_col: i32 = col + step[1];
        const on_board: bool = diagonal_row >= 0 and diagonal_row <= last_line and diagonal_col >= 0 and
            diagonal_col <= last_line;
        if (!on_board) {
            continue;
        }
        diagonals_on_board += 1;
        const diagonal: Point = pointAt(position.board_size, @intCast(diagonal_row), @intCast(diagonal_col));
        opponent_diagonals += @intFromBool(position.stones[diagonal] == mover.opponent());
    }
    const at_edge: bool = diagonals_on_board < 4;
    const opponent_diagonals_allowed: u32 = if (at_edge) 0 else 1;
    return opponent_diagonals <= opponent_diagonals_allowed;
}

/// A playout's pass (the section's lesson): the turn goes to the opponent with no stone placed, and the ko point with
/// it. Only a problem's playouts pass - a player with no move left but filling its own eyes - and never a game.
fn passTurn(position: *Position) void {
    position.player_to_move = position.player_to_move.opponent();
    position.ko_point = null;
}

/// A playout's random move (the section's lesson): drawn uniformly from the empty points, each drawn struck from the
/// list, until one is legal - and, in a problem, fills no eye of the mover's own. Null when none is.
fn randomLegalMove(position: *const Position, random: Random) ?Point {
    // The empty points a move may be drawn from: the whole board's, or in a problem only its region's - the points
    // outside it would all be refused.
    const region: ProblemRegion = playableRegion(position);
    var candidate_buffer: [board_limits.max_points]Point = undefined;
    var candidates: ArrayList(Point) = .initBuffer(&candidate_buffer);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const point: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const point_is_empty: bool = position.stones[point] == .none;
            if (point_is_empty) {
                candidates.appendAssumeCapacity(point);
            }
        }
    }
    while (candidates.items.len > 0) {
        const drawn_index: usize = random.uintLessThan(usize, candidates.items.len);
        // Struck from the list either way: the last candidate takes its place.
        const candidate: Point = candidates.swapRemove(drawn_index);
        const candidate_is_legal: bool = checkMove(position, candidate) == .legal;
        if (!candidate_is_legal) {
            continue;
        }
        // In a problem a player never fills its own eye: that is how a group that lives kills itself.
        const fills_own_eye: bool = position.target != null and isOwnEye(position, candidate);
        if (fills_own_eye) {
            continue;
        }
        return candidate;
    }
    return null;
}

/// The moves a group in atari has against a ladder (the section's lesson): the capture of each group of the
/// attacker's beside it that is itself in atari - the stones taken become liberties - and the extension on its own
/// last liberty. Written into `out_buffer`.
fn ladderDefences(
    position: *const Position,
    root: Point,
    out_buffer: []Point,
) []const Point {
    var defences: ArrayList(Point) = .initBuffer(out_buffer);
    const board_size: u8 = position.board_size;
    const defender: Stone = position.stones[root];
    var members: PointSet.Iterator(.{}) = position.group_stones[root].iterator(.{});
    while (members.next()) |member_index| {
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        for (neighborsOf(board_size, @intCast(member_index), &neighbor_buffer)) |neighbor| {
            const is_attacker: bool = position.stones[neighbor] == defender.opponent();
            if (!is_attacker) {
                continue;
            }
            const capture: Point = soleLiberty(position, neighbor) orelse {
                continue;
            };
            const already_listed: bool = indexOfScalar(Point, defences.items, capture) != null;
            if (!already_listed and defences.items.len < out_buffer.len) {
                defences.appendAssumeCapacity(capture);
            }
        }
    }
    if (soleLiberty(position, root)) |extension| {
        const already_listed: bool = indexOfScalar(Point, defences.items, extension) != null;
        if (!already_listed and defences.items.len < out_buffer.len) {
            defences.appendAssumeCapacity(extension);
        }
    }
    return defences.items;
}

/// Whether the group on `defender_point` is captured in a ladder (the section's lesson; after KataGo's
/// `searchIsLadderCaptured`): a depth-first search of the fight over a group of one or two liberties, each side's
/// moves only the ones that matter. With the attacker to play: the group at one liberty is taken, at three or more it
/// is free, and at two the attacker tries the atari on each - the group is captured if either works. With the
/// defender to play: at two liberties or more the group is free, as it is when the attacker's last move left a ko the
/// defender may take; at one, the defender tries each capture of an attacker's group in atari beside it and the
/// extension on its last liberty - the group is captured only if every one fails. Each level plays on a copy of the
/// position, `pool`'s first: a pool run out counts the ladder as working, as a long ladder usually does; `budget`
/// counts the positions visited, and run out counts the group as free.
pub fn ladderCaptures(
    position: *const Position,
    defender_point: Point,
    attacker_to_move: bool,
    pool: []Position,
    budget: *u32,
) bool {
    if (position.stones[defender_point] == .none) {
        return true;
    }
    if (budget.* == 0) {
        return false;
    }
    budget.* -= 1;
    const root: Point = findRoot(position, defender_point);
    const liberty_count: usize = position.group_liberties[root].count();
    if (attacker_to_move) {
        if (liberty_count <= 1) {
            return true;
        }
        if (liberty_count >= 3) {
            return false;
        }
        if (pool.len == 0) {
            return true;
        }
        var liberties: PointSet.Iterator(.{}) = position.group_liberties[root].iterator(.{});
        while (liberties.next()) |liberty_index| {
            const atari: Point = @intCast(liberty_index);
            if (checkMove(position, atari) != .legal) {
                continue;
            }
            const after: *Position = &pool[0];
            copyPosition(after, position);
            _ = placeStone(after, atari);
            if (ladderCaptures(after, defender_point, false, pool[1..], budget)) {
                return true;
            }
        }
        return false;
    }
    const takes_ko: bool = position.ko_point != null;
    if (liberty_count >= 2 or takes_ko) {
        return false;
    }
    if (pool.len == 0) {
        return true;
    }
    var defence_buffer: [board_limits.max_points]Point = undefined;
    for (ladderDefences(position, root, &defence_buffer)) |defence| {
        if (checkMove(position, defence) != .legal) {
            continue;
        }
        const after: *Position = &pool[0];
        copyPosition(after, position);
        _ = placeStone(after, defence);
        const defender_won: bool = after.winner != null and after.winner.? == position.player_to_move;
        if (defender_won or !ladderCaptures(after, defender_point, true, pool[1..], budget)) {
            return false;
        }
    }
    return true;
}

/// Whether the escape of the group on `group_point` to its last liberty, `escape`, only runs into a ladder that
/// captures it (`ladderCaptures`, the attacker to play after the escape). False when `pool` is empty: no reading.
fn escapeRunsIntoLadder(
    position: *const Position,
    group_point: Point,
    escape: Point,
    settings: SearchSettings,
    pool: []Position,
) bool {
    if (pool.len == 0) {
        return false;
    }
    const after: *Position = &pool[0];
    copyPosition(after, position);
    _ = placeStone(after, escape);
    if (after.winner != null) {
        return false;
    }
    var budget: u32 = settings.ladder_budget;
    return ladderCaptures(after, group_point, true, pool[1..], &budget);
}

/// The heavy playout's urgent move (the section's lesson), or null when there is none: the capture of a group of the
/// opponent's in atari, else the escape of a group of the player to move's in atari - each a legal move on the
/// group's one liberty, drawn at random when there are several of a kind. Read-only, like the rules' checks.
pub fn urgentMove(
    position: *const Position,
    random: Random,
    settings: SearchSettings,
    ladder_pool: []Position,
) ?Point {
    var capture_buffer: [board_limits.max_points]Point = undefined;
    var captures: ArrayList(Point) = .initBuffer(&capture_buffer);
    var escape_buffer: [board_limits.max_points]Point = undefined;
    var escapes: ArrayList(Point) = .initBuffer(&escape_buffer);
    // The region's groups are all the board's: every stone stands in it.
    const region: ProblemRegion = playableRegion(position);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const point: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const stone: Stone = position.stones[point];
            const is_group_root: bool = stone != .none and isRoot(position, point);
            if (!is_group_root) {
                continue;
            }
            const liberty: Point = soleLiberty(position, point) orelse {
                continue;
            };
            const liberty_is_legal: bool = checkMove(position, liberty) == .legal;
            if (!liberty_is_legal) {
                continue;
            }
            const is_own_group: bool = stone == position.player_to_move;
            if (is_own_group) {
                // An escape into a ladder that captures only delays the capture. A game's playouts read it; a
                // problem's leave its target's fight to the search.
                const reads: bool = settings.ladder_reading and position.target == null;
                const futile: bool = reads and escapeRunsIntoLadder(position, point, liberty, settings, ladder_pool);
                if (!futile) {
                    escapes.appendAssumeCapacity(liberty);
                }
            } else {
                captures.appendAssumeCapacity(liberty);
            }
        }
    }
    if (captures.items.len > 0) {
        const drawn_index: usize = random.uintLessThan(usize, captures.items.len);
        return captures.items[drawn_index];
    }
    if (escapes.items.len > 0) {
        const drawn_index: usize = random.uintLessThan(usize, escapes.items.len);
        return escapes.items[drawn_index];
    }
    return null;
}

/// A stone of `colour`'s group with the fewest liberties in `position` - its root, the first such group in point
/// order - or null when `colour` has no stone there.
fn weakestGroupStone(position: *const Position, colour: Stone) ?Point {
    var weakest_root: ?Point = null;
    var weakest: usize = maxInt(usize);
    const region: ProblemRegion = playableRegion(position);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const point: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const is_root: bool = position.stones[point] == colour and isRoot(position, point);
            if (!is_root) {
                continue;
            }
            const liberty_count: usize = position.group_liberties[point].count();
            if (liberty_count < weakest) {
                weakest = liberty_count;
                weakest_root = point;
            }
        }
    }
    return weakest_root;
}

/// How far apart two points are along the lines: the rows between them and the columns between them, added.
fn lineDistance(board_size: u8, from: Point, to: Point) u32 {
    const row_gap: u32 = @abs(@as(i32, rowOf(board_size, from)) - @as(i32, rowOf(board_size, to)));
    const col_gap: u32 = @abs(@as(i32, colOf(board_size, from)) - @as(i32, colOf(board_size, to)));
    return row_gap + col_gap;
}

/// The next move of a playout of `kind`, or null when no move is legal.
/// The move that keeps fighting for a problem's target (the section's lesson), for a player whose position is
/// decided - every move winning about as often, so that the search's choice among them is no choice: among the
/// target's neighbourhood's moves (`targetNeighbourhood`), legal and filling no eye of the mover's own, the one that
/// leaves the target's group the most liberties when the mover owns it, and the fewest when the mover attacks it - a
/// capture fewest of all. The defender goes on extending, capturing beside its group and making eye shape; the
/// attacker goes on filling liberties. Ties go to the first point. Only moves in `allowed`, when it is given. Null when
/// there is no such move.
pub fn fightingMove(position: *const Position, allowed: ?*const PointSet) ?Point {
    var near: PointSet = targetNeighbourhood(position) orelse {
        return null;
    };
    if (allowed) |allowed_moves| {
        near.setIntersection(allowed_moves.*);
    }
    const target: Point = position.target.?;
    const mover_defends: bool = position.stones[target] == position.player_to_move;
    var best_move: ?Point = null;
    var best_score: i32 = minInt(i32);
    var near_points: PointSet.Iterator(.{}) = near.iterator(.{});
    while (near_points.next()) |point_index| {
        const candidate: Point = @intCast(point_index);
        const is_legal: bool = checkMove(position, candidate) == .legal;
        if (!is_legal or isOwnEye(position, candidate)) {
            continue;
        }
        var after: Position = position.*;
        _ = placeStone(&after, candidate);
        const target_stands: bool = after.stones[target] != .none;
        const target_root: Point = if (target_stands) findRoot(&after, target) else target;
        const liberties_after: i32 = if (target_stands) @intCast(after.group_liberties[target_root].count()) else -1;
        const liberty_score: i32 = if (mover_defends) liberties_after else -liberties_after;
        // Ties to the move nearest the target, not the first point.
        const distance_to_target: i32 = @intCast(lineDistance(position.board_size, candidate, target));
        const distance_range: i32 = 4 * @as(i32, position.board_size);
        const score: i32 = liberty_score * distance_range - distance_to_target;
        if (score > best_score) {
            best_score = score;
            best_move = candidate;
        }
    }
    return best_move;
}

/// The fewest liberties among `colour`'s groups in `position`; `maxInt(u32)` when it has none.
fn weakestLiberties(position: *const Position, colour: Stone) u32 {
    var weakest: u32 = maxInt(u32);
    const region: ProblemRegion = playableRegion(position);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const point: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const is_root: bool = position.stones[point] == colour and isRoot(position, point);
            if (is_root) {
                const liberty_count: u32 = @intCast(position.group_liberties[point].count());
                weakest = @min(weakest, liberty_count);
            }
        }
    }
    return weakest;
}

/// How far `move` is from the group whose root is `root` in `position`: the fewest lines, along the rows and the
/// columns, to any stone of it.
fn groupDistance(
    position: *const Position,
    move: Point,
    root: Point,
) i64 {
    var nearest: u32 = maxInt(u32);
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const in_the_group: bool = position.stones[point] != .none and findRoot(position, point) == root;
        if (in_the_group) {
            nearest = @min(nearest, lineDistance(position.board_size, move, point));
        }
    }
    return nearest;
}

/// The move that keeps fighting in a game of Atari Go (the section's lesson), played where the search's own choice
/// would fight nothing (`playedMove`): it attacks the opponent's weakest group, or defends its own. A capture, when
/// there is one, wins. Otherwise the two weakest groups are compared. When the mover's own has fewer liberties than
/// the opponent's, the mover defends it: the move that leaves its own weakest group the most liberties. Else it
/// attacks: the move that leaves the opponent's weakest group the fewest - an atari before a quieter approach -
/// never at the cost of putting its own stones in atari, though two liberties are safe enough, since a move that
/// puts the opponent in atari forces the answer. Ties go to the move nearest the group fought over, attacked or
/// defended, measured to its nearest stone - where the fight is, never a quiet move in a corner. Only moves in
/// `allowed`, when it is given; a move filling an eye of the mover's own is never played. Null when there is no such
/// move.
pub fn atariFightingMove(position: *const Position, allowed: ?*const PointSet) ?Point {
    const mover: Stone = position.player_to_move;
    const opponent: Stone = mover.opponent();
    // Liberties beyond these keep the mover's groups no safer, for an attack's choice.
    const safe_liberties: u32 = 2;
    // Liberties beyond these leave a group as free, for either choice.
    const free_liberties: u32 = 16;
    // Attack or defence, and the group fought over.
    const own_before: u32 = weakestLiberties(position, mover);
    const opponent_before: u32 = weakestLiberties(position, opponent);
    const defends: bool = own_before < opponent_before;
    const fought_colour: Stone = if (defends) mover else opponent;
    const fought_group: ?Point = weakestGroupStone(position, fought_colour);
    // The score's parts, each worth more than every later part can add.
    const distance_range: i64 = 4 * @as(i64, position.board_size);
    const pressure_range: i64 = (free_liberties + 1) * distance_range;
    const own_cap: u32 = if (defends) free_liberties else safe_liberties;
    var best_move: ?Point = null;
    var best_score: i64 = minInt(i64);
    const region: ProblemRegion = playableRegion(position);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const candidate: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const is_allowed: bool = allowed == null or allowed.?.isSet(candidate);
            const is_legal: bool = is_allowed and checkMove(position, candidate) == .legal;
            if (!is_legal or isOwnEye(position, candidate)) {
                continue;
            }
            var after: Position = position.*;
            _ = placeStone(&after, candidate);
            if (after.winner == mover) {
                return candidate;
            }
            const own_weakest: i64 = @min(weakestLiberties(&after, mover), own_cap);
            const opponent_weakest: i64 = @min(weakestLiberties(&after, opponent), free_liberties);
            const distance_to_fight: i64 = if (fought_group) |root| groupDistance(position, candidate, root) else 0;
            const safety_score: i64 = own_weakest * pressure_range;
            const pressure_score: i64 = -opponent_weakest * distance_range;
            const score: i64 = safety_score + pressure_score - distance_to_fight;
            if (score > best_score) {
                best_score = score;
                best_move = candidate;
            }
        }
    }
    return best_move;
}

fn playoutMove(
    position: *const Position,
    random: Random,
    settings: SearchSettings,
    ladder_pool: []Position,
) ?Point {
    switch (settings.playout_kind) {
        .light => {
            return randomLegalMove(position, random);
        },
        .heavy => {
            const urgent: ?Point = urgentMove(position, random, settings, ladder_pool);
            if (urgent != null) {
                return urgent;
            }
            return randomLegalMove(position, random);
        },
    }
}

/// The winner of a game's playout cut short (`SearchSettings.playout_cutoff`), by its liberties: a group of the
/// opponent's in atari whose liberty the player to move may take is the capture, and the game, theirs; otherwise the
/// player whose weakest group has more liberties - the other's nearer capture - and on a tie as `tie` says
/// (`CutTie`): `.none`, undecided, for half a win each. A player without a stone counts as having no weak group at
/// all.
fn cutShortWinner(position: *const Position, tie: CutTie, groups_compared: u32) Stone {
    const to_move: Stone = position.player_to_move;
    const opponent: Stone = to_move.opponent();
    const opponent_weakest: ?Point = weakestGroupStone(position, opponent);
    if (opponent_weakest) |root| {
        const liberty: ?Point = soleLiberty(position, root);
        const can_capture: bool = liberty != null and checkMove(position, liberty.?) == .legal;
        if (can_capture) {
            return to_move;
        }
    }
    var own_liberties: [max_groups_compared]u32 = undefined;
    var opponent_liberties: [max_groups_compared]u32 = undefined;
    const compared: usize = @min(groups_compared, max_groups_compared);
    weakestLibertyCounts(position, to_move, own_liberties[0..compared]);
    weakestLibertyCounts(position, opponent, opponent_liberties[0..compared]);
    for (own_liberties[0..compared], opponent_liberties[0..compared]) |own, other| {
        if (own < other) {
            return opponent;
        }
        if (own > other) {
            return to_move;
        }
    }
    const tie_winner: Stone = switch (tie) {
        .half => .none,
        .player_to_move => to_move,
    };
    return tie_winner;
}

/// A playout (the section's lesson): moves chosen as `settings.playout_kind` says, played on `position` until a player
/// reaches the goal, no move is legal, or `settings.playout_move_cap` moves have been played. Returns the winner, or
/// `.none` for a playout that ended undecided.
pub fn playOut(
    position: *Position,
    random: Random,
    settings: SearchSettings,
    ladder_pool: []Position,
) Stone {
    // A problem undecided at the end - both players passing, or the cap - is the target's owner's: it stands.
    const is_problem: bool = position.target != null;
    const undecided_result: Stone = if (position.target) |target| position.stones[target] else .none;
    var moves_played: u32 = 0;
    var passes_in_a_row: u32 = 0;
    while (position.winner == null) {
        const cap_reached: bool = moves_played >= settings.playout_move_cap;
        if (cap_reached) {
            return undecided_result;
        }
        // Only where the first capture wins: the cut's score knows no prisoners taken, nor a goal of several.
        const first_capture_wins: bool = position.capture_goal == 1;
        const cuts_short: bool = settings.playout_cutoff > 0 and !is_problem and first_capture_wins;
        if (cuts_short and moves_played >= settings.playout_cutoff) {
            return cutShortWinner(position, settings.cut_tie, settings.cut_groups_compared);
        }
        const maybe_move: ?Point = playoutMove(position, random, settings, ladder_pool);
        if (maybe_move) |move| {
            _ = placeStone(position, move);
            passes_in_a_row = 0;
        } else {
            // With no move: a game's playout ends there; a problem's player passes, and two passes end it.
            if (!is_problem) {
                return undecided_result;
            }
            passTurn(position);
            passes_in_a_row += 1;
            if (passes_in_a_row >= 2) {
                return undecided_result;
            }
        }
        moves_played += 1;
    }
    return position.winner.?;
}

/// What a playout's result counts for a node whose move `mover` made: 2 for a win, 1 for an undecided playout, 0 for
/// a loss.
fn halfWinsFor(mover: Stone, winner: Stone) u32 {
    if (winner == mover) {
        return 2;
    }
    if (winner == .none) {
        return 1;
    }
    return 0;
}

/// One iteration of the search (the section's lesson): selection, expansion, a playout and backpropagation.
/// `scratch` is overwritten with a copy of `root_position` and played on; `root_position` is only read. When the tree
/// is full, the iteration plays out from the node selection reached without adding one.
pub fn runIteration(
    tree: *SearchTree,
    root_position: *const Position,
    settings: SearchSettings,
    scratch: *Position,
    ladder_pool: []Position,
) void {
    copyPosition(scratch, root_position);
    var generator: Xoshiro256 = .{ .s = tree.header.random_state };
    const random: Random = generator.random();

    // 1. Selection: down through the nodes whose candidates all have children - a final node, with none, stops it,
    var node_index: u32 = 0;
    while (true) {
        const node: *const SearchNode = &tree.nodes[node_index];
        const has_children: bool = node.candidate_count != SearchNode.not_counted and node.children_made > 0;
        const goes_deeper: bool = has_children and node.hasEveryChildAllowed(settings);
        if (!goes_deeper) {
            break;
        }
        node_index = childWithHighestBound(tree, node_index, settings.exploration);
        _ = placeStone(scratch, tree.nodes[node_index].move);
    }

    // 2. Expansion: the next untried candidate becomes a child, if the tree has room for it. The leaf's candidates
    //    are listed for it, and counted the first time.
    const leaf: *SearchNode = &tree.nodes[node_index];
    const tree_has_room: bool = tree.header.node_count < tree.nodes.len;
    if (!leaf.hasEveryChildAllowed(settings) and tree_has_room) {
        // The first expansion makes the whole list, to count it; a later one finds the next candidate past the last
        // child's, its newest, from that move alone (`nextCandidate`: the candidates' order is fixed by the position).
        var next_move: ?Point = null;
        if (leaf.candidate_count == SearchNode.not_counted) {
            var candidate_buffer: [board_limits.max_points]Point = undefined;
            const candidates: Candidates = candidateMoves(scratch, &candidate_buffer);
            leaf.candidate_count = @intCast(candidates.moves.len);
            leaf.candidate_kind = candidates.kind;
            if (candidates.moves.len > 0) {
                next_move = candidates.moves[0];
            }
        } else {
            const newest_child_move: Point = tree.nodes[leaf.first_child].move;
            next_move = nextCandidate(scratch, leaf.candidate_kind, newest_child_move);
        }
        if (next_move) |move| {
            const mover: Stone = scratch.player_to_move;
            _ = placeStone(scratch, move);
            node_index = addChild(tree, node_index, move, mover);
        }
    }

    // 3. Simulation: a playout from the node's position.
    const winner: Stone = playOut(scratch, random, settings, ladder_pool);

    // 4. Backpropagation: every node from there up to the root counts the playout.
    var climbing_index: u32 = node_index;
    while (climbing_index != SearchNode.none) {
        const node: *SearchNode = &tree.nodes[climbing_index];
        node.visits += 1;
        node.half_wins += halfWinsFor(node.mover, winner);
        climbing_index = node.parent;
    }
    tree.header.random_state = generator.s;
}

/// `iteration_count` iterations of the search from `root_position` (see `runIteration`).
pub fn runIterations(
    tree: *SearchTree,
    root_position: *const Position,
    settings: SearchSettings,
    iteration_count: u32,
    scratch: *Position,
    ladder_pool: []Position,
) void {
    for (0..iteration_count) |_| {
        runIteration(tree, root_position, settings, scratch, ladder_pool);
    }
}

/// The most visited child of `parent_index` - the newest of equals, as with `childWithHighestBound` - or null when it
/// has no child.
pub fn mostVisitedChild(tree: *const SearchTree, parent_index: u32) ?u32 {
    var best_index: ?u32 = null;
    var best_visits: u32 = 0;
    var child_index: u32 = tree.nodes[parent_index].first_child;
    while (child_index != SearchNode.none) {
        const child: *const SearchNode = &tree.nodes[child_index];
        const is_better: bool = best_index == null or child.visits > best_visits;
        if (is_better) {
            best_visits = child.visits;
            best_index = child_index;
        }
        child_index = child.next_sibling;
    }
    return best_index;
}

/// Whether the root's move is forced: one candidate - a capture that wins, or the only legal move - leaves the search
/// nothing to choose, so it plays the move at once instead of spending the move's time on it. False before the root's
/// candidates are counted, which its first iteration does.
pub fn rootMoveIsForced(tree: *const SearchTree) bool {
    const root: *const SearchNode = &tree.nodes[0];
    return root.candidate_count == 1;
}

/// The root's most visited child's move (`mostVisitedChild`): the move a search makes by the visits alone, which
/// go to the move whose wins hold up. Null when the root has no child.
pub fn mostVisitedMove(tree: *const SearchTree) ?Point {
    const child_index: u32 = mostVisitedChild(tree, 0) orelse {
        return null;
    };
    return tree.nodes[child_index].move;
}

/// The root's child for `move`, or null when the root has none.
pub fn rootChild(tree: *const SearchTree, move: Point) ?*const SearchNode {
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const child: *const SearchNode = &tree.nodes[child_index];
        if (child.move == move) {
            return child;
        }
    }
    return null;
}

/// How often the player who makes `move` won, in the root's child for it (`SearchNode.winRate`); zero when the root
/// has no such child.
pub fn rootChildWinRate(tree: *const SearchTree, move: Point) f32 {
    const child: *const SearchNode = rootChild(tree, move) orelse {
        return 0;
    };
    return child.winRate();
}

/// A win rate's standard error: that of a share of the node's playouts, its rate smoothed by a playout won and one
/// lost, so that one never seen to lose is not sure of winning (`chosenMove`).
fn winRateError(node: *const SearchNode) f32 {
    const visits: f32 = float(@max(node.visits, 1));
    const smoothed_rate: f32 = (float(node.half_wins) / 2 + 1) / (visits + 2);
    return @sqrt(smoothed_rate * (1 - smoothed_rate) / visits);
}

/// The move a search chooses (`MoveChoice`): the most visited child's, or the one whose win rate less
/// `settings.confidence_stdevs` standard errors is highest, among the children with at least
/// `settings.confidence_min_share` of the most visited child's visits. A win rate's standard error is that of a share
/// of `visits` playouts, its rate smoothed by a playout won and one lost, so that one never seen to lose is not sure
/// of winning: sqrt(r (1 - r) / visits). Null when the root has no child.
pub fn chosenMove(tree: *const SearchTree, settings: SearchSettings) ?Point {
    const most_visited: Point = mostVisitedMove(tree) orelse {
        return null;
    };
    if (settings.choice == .most_visited) {
        return most_visited;
    }
    const leader: *const SearchNode = rootChild(tree, most_visited).?;
    const least_visits: f32 = settings.confidence_min_share * float(leader.visits);
    var best_move: Point = most_visited;
    var best_bound: f32 = -1;
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const child: *const SearchNode = &tree.nodes[child_index];
        const visits: f32 = float(child.visits);
        if (visits < least_visits or child.visits == 0) {
            continue;
        }
        const bound: f32 = child.winRate() - settings.confidence_stdevs * winRateError(child);
        if (bound > best_bound) {
            best_bound = bound;
            best_move = child.move;
        }
    }
    return best_move;
}

/// Whether `move` is a tenuki in `position` (`SearchSettings.tenuki_lines`): farther than `tenuki_lines` along the
/// lines from every stone of the fight's groups - in a problem, its target's; in a game, every group of either player
/// with at most `fight_liberties` liberties, the groups under pressure, or when there is none, the weakest group of
/// each player - so far that it fights nothing. Each stone of a group counts, not one of them: a long group reaches
/// across the board. False when there is no fight to be far from.
fn isTenuki(
    position: *const Position,
    move: Point,
    tenuki_lines: u32,
    fight_liberties: u32,
) bool {
    var fight_roots_buffer: [board_limits.max_points]Point = undefined;
    var fight_roots: ArrayList(Point) = .initBuffer(&fight_roots_buffer);
    if (position.target) |target| {
        if (position.stones[target] != .none) {
            fight_roots.appendAssumeCapacity(findRoot(position, target));
        }
    } else {
        for (0..pointCount(position.board_size)) |point_index| {
            const point: Point = @intCast(point_index);
            const is_root: bool = position.stones[point] != .none and isRoot(position, point);
            const under_pressure: bool = is_root and position.group_liberties[point].count() <= fight_liberties;
            if (under_pressure) {
                fight_roots.appendAssumeCapacity(point);
            }
        }
        if (fight_roots.items.len == 0) {
            for ([_]Stone{ .black, .white }) |colour| {
                const weakest: ?Point = weakestGroupStone(position, colour);
                if (weakest) |root| {
                    fight_roots.appendAssumeCapacity(root);
                }
            }
        }
    }
    if (fight_roots.items.len == 0) {
        return false;
    }
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        if (position.stones[point] == .none) {
            continue;
        }
        const root: Point = findRoot(position, point);
        const in_the_fight: bool = indexOfScalar(Point, fight_roots.items, root) != null;
        const near_it: bool = in_the_fight and lineDistance(position.board_size, move, point) <= tenuki_lines;
        if (near_it) {
            return false;
        }
    }
    return true;
}

/// The root's moves as good as the tenuki `chosen` and near the fight (`SearchSettings.equal_rate_margin`,
/// `.equal_min_share`, `isTenuki`): each other child whose win rate is within the margin of the chosen's, with at
/// least the share of its visits, and which is no tenuki itself. Empty when there is none.
fn equalMovesNearFight(
    tree: *const SearchTree,
    position: *const Position,
    chosen: Point,
    settings: SearchSettings,
) PointSet {
    var equal_moves: PointSet = .empty;
    const chosen_child: *const SearchNode = rootChild(tree, chosen) orelse {
        return equal_moves;
    };
    const chosen_rate: f32 = chosen_child.winRate();
    const least_visits: f32 = settings.equal_min_share * float(chosen_child.visits);
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const child: *const SearchNode = &tree.nodes[child_index];
        const is_chosen: bool = child.move == chosen;
        const well_visited: bool = float(child.visits) >= least_visits and child.visits > 0;
        const as_good: bool = child.winRate() >= chosen_rate - settings.equal_rate_margin;
        if (is_chosen or !well_visited or !as_good) {
            continue;
        }
        if (!isTenuki(position, child.move, settings.tenuki_lines, settings.fight_liberties)) {
            equal_moves.set(child.move);
        }
    }
    return equal_moves;
}

/// Every move of the root's children.
fn everyRootMove(tree: *const SearchTree) PointSet {
    var moves: PointSet = .empty;
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        moves.set(tree.nodes[child_index].move);
    }
    return moves;
}

/// The root's moves that win as surely as the chosen one in a won position (`SearchSettings.won_above_rate`): each
/// child rated above that rate, with at least `equal_min_share` of the chosen's visits - among them the attack or
/// the defence keeps the win.
fn movesStillWinning(
    tree: *const SearchTree,
    chosen: Point,
    settings: SearchSettings,
) PointSet {
    var moves: PointSet = .empty;
    const chosen_child: *const SearchNode = rootChild(tree, chosen) orelse {
        return moves;
    };
    const least_visits: f32 = settings.equal_min_share * float(chosen_child.visits);
    var child_index: u32 = tree.nodes[0].first_child;
    while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
        const child: *const SearchNode = &tree.nodes[child_index];
        const well_visited: bool = float(child.visits) >= least_visits and child.visits > 0;
        if (well_visited and child.winRate() > settings.won_above_rate) {
            moves.set(child.move);
        }
    }
    return moves;
}

/// The move the computer plays from a search of `position` (the section's lesson): the chosen move (`chosenMove`),
/// except in the two cases where the fighting move cannot change the result (`SearchSettings.lost_below_rate`):
/// a lost position, every move losing - the fighting move among them all; and a tenuki between equals - the
/// fighting move among the moves near the fight as good as it (`equalMovesNearFight`). The fighting move is, for a
/// problem's target, `fightingMove`; in Atari Go, for every group, `atariFightingMove`. Null when the root has no
/// child.
pub fn playedMove(
    tree: *const SearchTree,
    position: *const Position,
    settings: SearchSettings,
) ?Point {
    const chosen: Point = chosenMove(tree, settings) orelse {
        return null;
    };
    const chosen_rate: f32 = rootChildWinRate(tree, chosen);
    var candidates: PointSet = .empty;
    const lost: bool = chosen_rate < settings.lost_below_rate;
    const won: bool = chosen_rate > settings.won_above_rate;
    if (lost) {
        candidates = everyRootMove(tree);
    } else if (won) {
        candidates = movesStillWinning(tree, chosen, settings);
    } else if (settings.fights_tenuki and isTenuki(position, chosen, settings.tenuki_lines, settings.fight_liberties)) {
        candidates = equalMovesNearFight(tree, position, chosen, settings);
        if (candidates.count() == 0 and settings.attacks_after_tenuki) {
            candidates = everyRootMove(tree);
        }
    }
    if (candidates.count() == 0) {
        return chosen;
    }
    if (position.target != null) {
        return fightingMove(position, &candidates) orelse chosen;
    }
    if (position.capture_goal != null) {
        return atariFightingMove(position, &candidates) orelse chosen;
    }
    return chosen;
}

/// Whether the search has nothing left to find: the root's move is forced.
pub fn searchIsSettled(tree: *const SearchTree) bool {
    return rootMoveIsForced(tree);
}

/// The child of `parent_index` reached by `move`, or null when the search never made it.
fn childByMove(tree: *const SearchTree, parent_index: u32, move: Point) ?u32 {
    var child_index: u32 = tree.nodes[parent_index].first_child;
    while (child_index != SearchNode.none) {
        const child: *const SearchNode = &tree.nodes[child_index];
        if (child.move == move) {
            return child_index;
        }
        child_index = child.next_sibling;
    }
    return null;
}

/// The subtree of `old_tree` reached from its root by `moves_since_root`, copied into `node_buffer` as a tree of its
/// own (the section's lesson): the node reached is its root, node 0, and everything under it follows, with its visits
/// and half-wins, its children in their order, and the old tree's generator state. `new_root_moves_played` and
/// `new_root_fingerprint` say which game position the new root is. Null when a move leads to no child, or when the
/// subtree is larger than `node_buffer`, a buffer apart from the old tree's; `gpa` lends the copy a table of old
/// indices for the time it takes.
pub fn takeUpSubtree(
    gpa: Allocator,
    old_tree: *const SearchTree,
    moves_since_root: []const Point,
    new_root_moves_played: u32,
    new_root_fingerprint: u64,
    node_buffer: []SearchNode,
) Allocator.Error!?SearchTree {
    var reached_index: u32 = 0;
    for (moves_since_root) |move| {
        reached_index = childByMove(old_tree, reached_index, move) orelse {
            return null;
        };
    }
    if (node_buffer.len == 0) {
        return null;
    }
    const old_nodes_start: usize = @intFromPtr(old_tree.nodes.ptr);
    const old_nodes_end: usize = old_nodes_start + old_tree.nodes.len * @sizeOf(SearchNode);
    const new_nodes_start: usize = @intFromPtr(node_buffer.ptr);
    const new_nodes_end: usize = new_nodes_start + node_buffer.len * @sizeOf(SearchNode);
    const buffers_overlap: bool = new_nodes_start < old_nodes_end and old_nodes_start < new_nodes_end;
    assertf(!buffers_overlap, @src(), "takeUpSubtree: the new nodes' buffer overlaps the old tree's", .{});
    // The nodes are copied breadth first: each new node's children are appended when it is reached, so a node's index
    // in the new array is always known before its children are copied. `old_index_of[i]` is where new node i came from.
    const old_index_of: []u32 = try gpa.alloc(u32, node_buffer.len);
    defer gpa.free(old_index_of);
    node_buffer[0] = old_tree.nodes[reached_index];
    node_buffer[0].parent = SearchNode.none;
    node_buffer[0].next_sibling = SearchNode.none;
    old_index_of[0] = reached_index;
    var copied_count: u32 = 1;
    var reached_new_index: u32 = 0;
    while (reached_new_index < copied_count) : (reached_new_index += 1) {
        const old_parent_index: u32 = old_index_of[reached_new_index];
        node_buffer[reached_new_index].first_child = SearchNode.none;
        var previous_new_child: u32 = SearchNode.none;
        var old_child_index: u32 = old_tree.nodes[old_parent_index].first_child;
        while (old_child_index != SearchNode.none) {
            const buffer_is_full: bool = copied_count == node_buffer.len;
            if (buffer_is_full) {
                return null;
            }
            const new_child_index: u32 = copied_count;
            node_buffer[new_child_index] = old_tree.nodes[old_child_index];
            node_buffer[new_child_index].parent = reached_new_index;
            node_buffer[new_child_index].next_sibling = SearchNode.none;
            old_index_of[new_child_index] = old_child_index;
            const is_first_child: bool = previous_new_child == SearchNode.none;
            if (is_first_child) {
                node_buffer[reached_new_index].first_child = new_child_index;
            } else {
                node_buffer[previous_new_child].next_sibling = new_child_index;
            }
            previous_new_child = new_child_index;
            copied_count += 1;
            old_child_index = old_tree.nodes[old_child_index].next_sibling;
        }
    }
    const subtree: SearchTree = .{
        .header = .{
            .node_count = copied_count,
            .root_moves_played = new_root_moves_played,
            .root_fingerprint = new_root_fingerprint,
            .random_state = old_tree.header.random_state,
        },
        .nodes = node_buffer,
    };
    return subtree;
}

/// `last_tree` where it fits the game in `game.record` (the section's lesson), or null: its root's position must be
/// the record's after `root_moves_played` moves, as their fingerprints say, and the moves played since must lead
/// through its children. With no move since, the last tree itself is returned, to go on in place; otherwise its
/// subtree, copied into `node_buffer`. Replays the record into `game`, leaving it at the root's position or the
/// record's, whichever it looked at last.
fn takeUpLastTree(
    gpa: Allocator,
    game: *Game,
    last_tree: ?SearchTree,
    node_buffer: []SearchNode,
) Allocator.Error!?SearchTree {
    const tree: SearchTree = last_tree orelse {
        return null;
    };
    // `replayTo` moves the record's own count, so the record's moves are read with the count it came with.
    const moves_played: u16 = game.record.moves_played;
    const root_moves_played: u32 = tree.header.root_moves_played;
    const root_is_in_the_record: bool = root_moves_played <= moves_played;
    if (!root_is_in_the_record) {
        return null;
    }
    replayTo(game, @intCast(root_moves_played));
    const root_is_the_record_s: bool = positionFingerprint(&game.position) == tree.header.root_fingerprint;
    if (!root_is_the_record_s) {
        return null;
    }
    const moves_since_root: []const Point = game.record.moves[root_moves_played..moves_played];
    const no_move_since: bool = moves_since_root.len == 0;
    if (no_move_since) {
        return tree;
    }
    replayTo(game, moves_played);
    const new_root_fingerprint: u64 = positionFingerprint(&game.position);
    const subtree: ?SearchTree = try takeUpSubtree(
        gpa,
        &tree,
        moves_since_root,
        moves_played,
        new_root_fingerprint,
        node_buffer,
    );
    return subtree;
}

/// The search for the game in `record` continued (the section's lesson): `last_tree` - the tree the last search
/// returned, if any - taken up where it fits, a fresh tree seeded with `seed` where it does not, and `iteration_count`
/// iterations run on it. The tree returned keeps its nodes in `last_tree`'s buffer when it goes on in place - no move
/// since its root - and in `node_buffer` otherwise; whichever it is should have room for the nodes it holds and
/// `iteration_count` more, or the iterations past its end play out without adding nodes. `gpa` lends the search a
/// game to replay the record into, a scratch position, and the take-up its table.
pub fn continueSearch(
    gpa: Allocator,
    record: *const Record,
    last_tree: ?SearchTree,
    node_buffer: []SearchNode,
    iteration_count: u32,
    seed: u64,
    settings: SearchSettings,
) Allocator.Error!SearchTree {
    const game: *Game = try gpa.create(Game);
    defer gpa.destroy(game);
    const scratch: *Position = try gpa.create(Position);
    defer gpa.destroy(scratch);
    // The ladder reading's positions, one a level, when the playouts read ladders: a game's, never a problem's.
    const reads_ladders: bool = settings.ladder_reading and record.target == null;
    const ladder_depth: usize = if (reads_ladders) settings.ladder_depth else 0;
    const ladder_pool: []Position = try gpa.alloc(Position, ladder_depth);
    defer gpa.free(ladder_pool);

    // The position is made by the replays below.
    game.* = .{ .position = undefined, .record = record.* };
    const taken_up: ?SearchTree = try takeUpLastTree(gpa, game, last_tree, node_buffer);
    replayTo(game, record.moves_played);
    const root_position: *const Position = &game.position;
    var tree: SearchTree = taken_up orelse .init(node_buffer, root_position, record.moves_played, seed);
    runIterations(&tree, root_position, settings, iteration_count, scratch, ladder_pool);
    return tree;
}

/// Writes `tree` as bytes (the section's lesson): its header, then its nodes in use.
pub fn writeTree(tree: *const SearchTree, out: *Io.Writer) Io.Writer.Error!void {
    const nodes_in_use: []const SearchNode = tree.nodes[0..tree.header.node_count];
    try out.writeAll(asBytes(&tree.header));
    try out.writeAll(sliceAsBytes(nodes_in_use));
}

/// The header of the tree `writeTree` wrote into `bytes`, or null when the bytes are too short to hold one.
pub fn readTreeHeader(bytes: []const u8) ?SearchTreeHeader {
    const header_size: usize = @sizeOf(SearchTreeHeader);
    if (bytes.len < header_size) {
        return null;
    }
    // Copied, not cast: the bytes come from a job, with no promise of alignment.
    var header: SearchTreeHeader = undefined;
    @memcpy(asBytes(&header), bytes[0..header_size]);
    return header;
}

/// The tree `writeTree` wrote into `bytes`, its nodes copied into `node_buffer`; null when the bytes are not a tree's -
/// too short, or not as long as their node count says - or the tree has more nodes than `node_buffer`.
pub fn readTree(bytes: []const u8, node_buffer: []SearchNode) ?SearchTree {
    const header: SearchTreeHeader = readTreeHeader(bytes) orelse {
        return null;
    };
    const node_bytes: []const u8 = bytes[@sizeOf(SearchTreeHeader)..];
    const node_count: usize = header.node_count;
    // Divided, not multiplied: a count read from bad bytes times a node's size could overflow a 32-bit usize.
    const whole_nodes: bool = node_bytes.len % @sizeOf(SearchNode) == 0;
    const length_agrees: bool = whole_nodes and node_bytes.len / @sizeOf(SearchNode) == node_count;
    const tree_fits: bool = node_count >= 1 and node_count <= node_buffer.len;
    if (!length_agrees or !tree_fits) {
        return null;
    }
    @memcpy(sliceAsBytes(node_buffer[0..node_count]), node_bytes);
    const tree: SearchTree = .{ .header = header, .nodes = node_buffer };
    return tree;
}

/// The tree `writeTree` wrote into `bytes`, its nodes read where they are, with no copy: the bytes are aligned for
/// nodes, and the header's size is a whole number of node alignments. Null when the bytes are not a tree's, as with
/// `readTree`.
pub fn viewTree(bytes: []align(@alignOf(SearchNode)) u8) ?SearchTree {
    comptime {
        const header_keeps_node_alignment: bool = @sizeOf(SearchTreeHeader) % @alignOf(SearchNode) == 0;
        if (!header_keeps_node_alignment) {
            @compileError("viewTree: a tree's header must be a whole number of node alignments long");
        }
    }
    const header: SearchTreeHeader = readTreeHeader(bytes) orelse {
        return null;
    };
    const node_bytes: []align(@alignOf(SearchNode)) u8 = @alignCast(bytes[@sizeOf(SearchTreeHeader)..]);
    const whole_nodes: bool = node_bytes.len % @sizeOf(SearchNode) == 0;
    const length_agrees: bool = whole_nodes and node_bytes.len / @sizeOf(SearchNode) == header.node_count;
    if (!length_agrees or header.node_count == 0) {
        return null;
    }
    const nodes: []SearchNode = bytesAsSlice(SearchNode, node_bytes);
    const tree: SearchTree = .{ .header = header, .nodes = nodes };
    return tree;
}

/// What a search job is told besides its payload (the section's lesson): an `extern struct`, as a job's header must be.
pub const SearchJobHeader = extern struct {
    settings: SearchSettings,
    /// How many iterations the job runs.
    iteration_count: u32,
    /// The most nodes the job's tree may have: it stops growing there, and its iterations past that play out without
    /// adding nodes, so that the tree fits whatever the program keeps it in.
    max_node_count: u32,
    /// The seed of the tree the job starts when the last one does not fit.
    seed: u64,
};

/// The fixed part of a record as a search job's payload carries it, ahead of its setup stones and its moves.
const RecordBytes = extern struct {
    board_size: u8,
    /// Atari Go's capture goal; 0 for plain Go - a goal is at least 1.
    capture_goal: u8,
    setup_to_play: Stone,
    /// Named so that every byte is defined.
    unused_byte: u8 = 0,
    setup_count: u16,
    moves_played: u16,
    /// A problem's target; `no_target` in a game.
    target: Point,
    /// A problem's region, its first row `no_region` in a game.
    region_first_row: u8,
    region_first_col: u8,
    region_last_row: u8,
    region_last_col: u8,

    const no_target: Point = maxInt(Point);
    const no_region: u8 = maxInt(u8);
};

/// One setup stone as a search job's payload carries it.
const SetupStoneBytes = extern struct {
    point: Point,
    stone: Stone,
    /// Named so that every byte is defined.
    unused_byte: u8 = 0,
};

/// Writes a search job's payload (the section's lesson): `record` - its board, goal, setup stones and the moves
/// played, field by field - then `last_tree_bytes`, the last tree as `writeTree` wrote it (empty for none).
pub fn writeSearchPayload(
    record: *const Record,
    last_tree_bytes: []const u8,
    out: *Io.Writer,
) Io.Writer.Error!void {
    const region: ProblemRegion = record.region orelse .{
        .first_row = RecordBytes.no_region,
        .first_col = 0,
        .last_row = 0,
        .last_col = 0,
    };
    const fixed_part: RecordBytes = .{
        .board_size = record.board_size,
        .capture_goal = record.capture_goal orelse 0,
        .setup_to_play = record.setup_to_play,
        .setup_count = record.setup_count,
        .moves_played = record.moves_played,
        .target = record.target orelse RecordBytes.no_target,
        .region_first_row = region.first_row,
        .region_first_col = region.first_col,
        .region_last_row = region.last_row,
        .region_last_col = region.last_col,
    };
    try out.writeAll(asBytes(&fixed_part));
    for (record.setup[0..record.setup_count]) |setup_stone| {
        const stone_bytes: SetupStoneBytes = .{ .point = setup_stone.point, .stone = setup_stone.stone };
        try out.writeAll(asBytes(&stone_bytes));
    }
    try out.writeAll(sliceAsBytes(record.moves[0..record.moves_played]));
    try out.writeAll(last_tree_bytes);
}

/// Reads a search job's payload into `record` - its moves recorded up to the moves played, none beyond - and returns
/// the bytes after it, the last tree's (empty when there is none); null when the payload is not one: too short for
/// what it says it holds, or with a board size, a turn or a count no record can have.
pub fn readSearchPayload(payload: []const u8, record: *Record) ?[]const u8 {
    var cursor: usize = 0;
    // Each part is copied out, not cast: the payload has no promise of alignment.
    if (payload.len < @sizeOf(RecordBytes)) {
        return null;
    }
    var fixed_part: RecordBytes = undefined;
    @memcpy(asBytes(&fixed_part), payload[0..@sizeOf(RecordBytes)]);
    cursor += @sizeOf(RecordBytes);
    const size_is_possible: bool = fixed_part.board_size >= board_limits.min_size and
        fixed_part.board_size <= board_limits.max_size;
    const turn_is_possible: bool = fixed_part.setup_to_play == .black or fixed_part.setup_to_play == .white;
    const counts_are_possible: bool = fixed_part.setup_count <= board_limits.max_points and
        fixed_part.moves_played <= record_limits.max_moves;
    if (!size_is_possible or !turn_is_possible or !counts_are_possible) {
        return null;
    }
    const setup_size: usize = @as(usize, fixed_part.setup_count) * @sizeOf(SetupStoneBytes);
    const moves_size: usize = @as(usize, fixed_part.moves_played) * @sizeOf(Point);
    if (payload.len - cursor < setup_size + moves_size) {
        return null;
    }
    const has_region: bool = fixed_part.region_first_row != RecordBytes.no_region;
    const region: ?ProblemRegion = if (has_region) .{
        .first_row = fixed_part.region_first_row,
        .first_col = fixed_part.region_first_col,
        .last_row = fixed_part.region_last_row,
        .last_col = fixed_part.region_last_col,
    } else null;
    record.* = .{
        .board_size = fixed_part.board_size,
        .capture_goal = if (fixed_part.capture_goal == 0) null else fixed_part.capture_goal,
        .target = if (fixed_part.target == RecordBytes.no_target) null else fixed_part.target,
        .region = region,
        .setup = @splat(.{ .point = 0, .stone = .none }),
        .setup_count = fixed_part.setup_count,
        .setup_to_play = fixed_part.setup_to_play,
        .moves = @splat(0),
        .moves_recorded = fixed_part.moves_played,
        .moves_played = fixed_part.moves_played,
    };
    for (record.setup[0..record.setup_count]) |*setup_stone| {
        var stone_bytes: SetupStoneBytes = undefined;
        @memcpy(asBytes(&stone_bytes), payload[cursor..][0..@sizeOf(SetupStoneBytes)]);
        cursor += @sizeOf(SetupStoneBytes);
        setup_stone.* = .{ .point = stone_bytes.point, .stone = stone_bytes.stone };
    }
    @memcpy(sliceAsBytes(record.moves[0..record.moves_played]), payload[cursor..][0..moves_size]);
    cursor += moves_size;
    return payload[cursor..];
}

/// The search job (the section's lesson; listed in `kernels.zig`): the record and the last tree read from `payload`,
/// `continueSearch` run with `header`'s settings, count and seed, and the tree it returns written to `out`. `gpa` is
/// the job's arena, freed whole when the job ends.
pub fn searchJob(
    gpa: Allocator,
    header: SearchJobHeader,
    payload: []const u8,
    out: *Io.Writer,
) !void {
    const record: *Record = try gpa.create(Record);
    const last_tree_bytes: []const u8 = readSearchPayload(payload, record) orelse {
        return error.SearchPayloadMalformed;
    };
    // Room for every node the job can hold: the last tree's, which the take-up never exceeds, and one per iteration.
    var last_tree: ?SearchTree = null;
    var node_capacity: usize = @min(@as(usize, header.iteration_count) + 1, header.max_node_count);
    const has_last_tree: bool = last_tree_bytes.len > 0;
    if (has_last_tree) {
        const last_header: SearchTreeHeader = readTreeHeader(last_tree_bytes) orelse {
            return error.SearchPayloadMalformed;
        };
        // Never fewer than the last tree's own nodes, whatever the header allows.
        const grown_capacity: usize = @as(usize, last_header.node_count) + header.iteration_count;
        const most_nodes: usize = @max(last_header.node_count, header.max_node_count);
        node_capacity = clamp(grown_capacity, last_header.node_count, most_nodes);
        const last_nodes: []SearchNode = try gpa.alloc(SearchNode, node_capacity);
        last_tree = readTree(last_tree_bytes, last_nodes) orelse {
            return error.SearchPayloadMalformed;
        };
    }
    const node_buffer: []SearchNode = try gpa.alloc(SearchNode, node_capacity);
    const tree: SearchTree = try continueSearch(
        gpa,
        record,
        last_tree,
        node_buffer,
        header.iteration_count,
        header.seed,
        header.settings,
    );
    // On a worker the line goes home with the job's reply, and the page prints it (`jobs.Registry.workerLogFn`).
    const taken_up_visits: u32 = tree.nodes[0].visits - header.iteration_count;
    std.log.info("search: {d} iterations after move {d}, the tree {d} nodes, {d} visits taken up from the last", .{
        header.iteration_count,
        record.moves_played,
        tree.header.node_count,
        taken_up_visits,
    });
    try writeTree(&tree, out);
}

/// The search's job kernels, by name (the section's lesson): the wasm export of each is `zimr_job_<name>`.
/// `kernels.zig`, which the build requires of an app with jobs, lists them from here.
pub const search_job_kernels = .{
    .{ "searchGoban", searchJob },
};

/// The registry the search's jobs are submitted through. A job's output is its tree, 28 bytes a node: 3 MB holds the
/// 100,000 nodes the program keeps at most (`ComputerSettings.max_tree_nodes`); its input is that tree and the record.
/// The bounds are kept close to what is needed because a job that runs inside the frame - no worker, no thread - is
/// given an output buffer of the whole bound each time, and the computer then submits one every frame.
pub const search_job_registry = jobs.Registry(search_job_kernels, .{
    .max_input = 4 << 20,
    .max_output = 3 << 20,
});

// ===== 8. Layout =====
//
// The board is placed on the screen afresh every frame, from the window's size, so it follows every resize and fits
// a phone held either way. Everything is measured in SPACINGS - the distance between two neighbouring lines - so the
// board looks the same at every size:
//
//       |<-- margin -->|<------------- grid: (board_size - 1) spacings ------------->|<-- margin -->|
//       |  2 spacings  |  +----+----+----+---- ... ----+                              |  2 spacings  |
//                         origin = point (0,0)
//
// The shorter side of the window holds the grid and a margin on each side, so the spacing is that side divided by
// (board_size - 1 + 2 * margin), rounded down to a whole number of pixels: every line then lands on a whole pixel and
// looks equally sharp. The grid is centred in the window. A point is drawn at origin + (col, row) * spacing, and a
// pointer is turned into a point by snapping it to the nearest intersection.

/// How the board looks. Every size is a fraction of the spacing between lines; the defaults are the ones the
/// program uses, kept in the app's state and passed to whatever draws.
pub const BoardStyle = struct {
    /// Empty space around the grid on each side, in spacings: room for the stones on the edge lines and beyond.
    margin_spacings: f32 = 2,
    /// The grid's lines, in pixels.
    line_px: f32 = 2,
    line_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    /// A star point's radius, in spacings, and at least this many pixels so it shows on a small board.
    star_point_radius_spacings: f32 = 0.125,
    star_point_min_radius_px: f32 = 2,
    /// A stone's drawn width, in spacings: a little more than one, so neighbouring stones touch, as on a real board.
    stone_size_spacings: f32 = 1.1,
    /// The ring that marks the last move, in spacings, and its colour on each stone.
    last_move_ring_radius_spacings: f32 = 1.0 / 3.0,
    last_move_ring_px: f32 = 1.5,
    last_move_ring_on_black: Color = .{ .r = 150, .g = 150, .b = 150, .a = 255 },
    last_move_ring_on_white: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    /// The ghost - the stone the player to move would place - reaches the pointer's point in about this long.
    ghost_blend_seconds: f32 = 0.08,
    /// The ghost's opacity: nearly opaque while a stone is held, lighter while it only follows the pointer. A white
    /// stone's picture is pale, so its ghost needs less opacity to show than a black one's.
    ghost_alpha_held: u8 = 220,
    ghost_alpha_black: u8 = 180,
    ghost_alpha_white: u8 = 80,
    /// A group in atari - one liberty left - gets a thin red ring around each of its stones, this many pixels outside
    /// the stone's edge, so it shows at every board size.
    atari_ring_color: Color = .{ .r = 255, .g = 0, .b = 0, .a = 140 },
    atari_ring_gap_px: f32 = 1.5,
    atari_ring_px: f32 = 1.5,
    /// The groups the hovered move would capture get a wider dark red ring around each stone, outside the atari ring
    /// (they are always in atari), pulsing between the two opacities.
    doomed_ring_color: Color = .{ .r = 150, .g = 0, .b = 0, .a = 255 },
    doomed_ring_gap_px: f32 = 4,
    doomed_ring_px: f32 = 3,
    doomed_alpha_low: f32 = 80,
    doomed_alpha_high: f32 = 180,
    /// The liberties of the groups the pointer bears on (section 9): a ring on each, this fraction of a spacing across,
    /// pulsing likewise - gold for the groups of the player to move, pale blue for the opponent's.
    liberty_mark_color: Color = .{ .r = 180, .g = 140, .b = 30, .a = 255 },
    liberty_mark_color_opponent: Color = .{ .r = 110, .g = 170, .b = 230, .a = 255 },
    /// Each of those groups' liberty count, written on its stone beside the ghost: this fraction of a spacing tall,
    /// light on a black stone and dark on a white one. It shows the count now for `liberty_count_hold_seconds`, then
    /// changes to the count after the move over `liberty_count_switch_seconds`, so the move's effect is seen.
    liberty_count_size_spacings: f32 = 0.5,
    liberty_count_hold_seconds: f32 = 0.1,
    liberty_count_switch_seconds: f32 = 0.2,
    liberty_count_on_black: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    liberty_count_on_white: Color = .{ .r = 20, .g = 20, .b = 20, .a = 255 },
    /// The forest view (section 9): each parent pointer an arrow, leaving its stone this far from the centre and
    /// stopping this far short of its parent's, with a head this long - in spacings; each root a square of this half
    /// width; the path from the stone under the pointer to its root drawn over the rest in its own colour, wider; and,
    /// when asked, each stone's depth written small beside it.
    forest_arrow_color: Color = .{ .r = 230, .g = 60, .b = 60, .a = 220 },
    forest_arrow_px: f32 = 2,
    forest_arrow_start_spacings: f32 = 0.15,
    forest_arrow_stop_spacings: f32 = 0.3,
    forest_arrow_head_spacings: f32 = 0.16,
    forest_root_color: Color = .{ .r = 230, .g = 60, .b = 60, .a = 255 },
    forest_root_half_spacings: f32 = 0.22,
    forest_path_color: Color = .{ .r = 255, .g = 210, .b = 60, .a = 255 },
    forest_path_px: f32 = 3,
    forest_depth_size_spacings: f32 = 0.32,
    liberty_mark_radius_spacings: f32 = 0.15,
    liberty_mark_px: f32 = 1.5,
    liberty_alpha_low: f32 = 100,
    liberty_alpha_high: f32 = 220,
    /// The pulse of the two hover overlays, in radians of its sine per second, and how fast they fade in when the
    /// pointer reaches a new point: fully shown after 1 / overlay_fade_in_per_second seconds.
    overlay_pulse_radians_per_second: f32 = 4,
    overlay_fade_in_per_second: f32 = 3,
    /// The capture columns (section 8): a captured stone's radius, as a fraction of a board stone's (half a
    /// spacing); its drawn width, in its radii; the gap between the board's edge stones and a column, in board-stone
    /// radii.
    captured_stone_radius_fraction: f32 = 0.6,
    captured_stone_size_radii: f32 = 2.2,
    column_gap_radii: f32 = 0.5,
    /// Two slots of a column are at most one captured stone apart (touching) and at least this many radii apart
    /// (overlapping like a stack of coins); past that, a column wraps into a second one further out.
    slot_spacing_min_radii: f32 = 0.6,
    /// The slots close up on a spring, over about this long, when a column grows.
    slot_spacing_blend_seconds: f32 = 0.3,
    /// An Atari Go game shows its goal as empty circles in the columns, in this colour.
    goal_circle_color: Color = .{ .r = 130, .g = 130, .b = 130, .a = 255 },
    goal_circle_px: f32 = 1,
    /// A captured stone's flight to its column: how long it takes, and how much later each next stone of the same
    /// capture leaves.
    flight_seconds: f32 = 0.4,
    flight_stagger_seconds: f32 = 0.05,
    /// A problem's target is marked as an SGF viewer marks it - a triangle (`TR`) on a white stone to capture, a square
    /// (`SQ`) on a black one to save: the triangle's colour, the distance from the stone's centre to a corner, in
    /// spacings, and the lines' width.
    target_mark_color: Color = .{ .r = 40, .g = 40, .b = 40, .a = 255 },
    /// A life problem's black stone to save is marked with a square, in this colour.
    save_mark_color: Color = .{ .r = 225, .g = 225, .b = 225, .a = 255 },
    target_mark_spacings: f32 = 0.25,
    target_mark_px: f32 = 2.5,
    /// A hint's dot (`HintSettings`): its colour, and its radius in the board's spacings.
    hint_color: Color = .{ .r = 40, .g = 120, .b = 255, .a = 255 },
    hint_dot_spacings: f32 = 0.22,
};

/// Where the board is on the screen this frame. All values are logical pixels.
pub const BoardLayout = struct {
    board_size: u8,
    /// The distance between two neighbouring lines: a whole number of pixels.
    spacing_px: f32,
    /// The screen position of point (0,0), the top-left intersection.
    origin_px: Vec2,
    /// The length of one side of the grid: (board_size - 1) spacings.
    grid_px: f32,

    /// The layout for a window of this size (the section's lesson draws it).
    pub fn fromWindow(
        window_width_px: f32,
        window_height_px: f32,
        board_size: u8,
        style: BoardStyle,
    ) BoardLayout {
        const shorter_side_px: f32 = @min(window_width_px, window_height_px);
        const grid_spacings: f32 = float(board_size - 1);
        const spacings_across: f32 = grid_spacings + 2 * style.margin_spacings;
        const whole_pixel_spacing: f32 = @floor(shorter_side_px / spacings_across);
        const spacing_px: f32 = @max(whole_pixel_spacing, 1);
        const grid_px: f32 = spacing_px * grid_spacings;
        const origin_x_px: f32 = @floor((window_width_px - grid_px) / 2);
        const origin_y_px: f32 = @floor((window_height_px - grid_px) / 2);
        const layout: BoardLayout = .{
            .board_size = board_size,
            .spacing_px = spacing_px,
            .origin_px = .{ origin_x_px, origin_y_px },
            .grid_px = grid_px,
        };
        return layout;
    }

    /// The layout for a window of this size that shows `region` of the board (the section's lesson): the spacing that
    /// fits the region and the margin around it, and the origin that centres it - the board's other points off the
    /// window's sides, and its lines running off with them where the region does not reach the edge.
    pub fn forRegion(
        window_width_px: f32,
        window_height_px: f32,
        board_size: u8,
        region: ProblemRegion,
        style: BoardStyle,
    ) BoardLayout {
        const region_cols: f32 = float(region.last_col - region.first_col);
        const region_rows: f32 = float(region.last_row - region.first_row);
        const spacings_across: f32 = region_cols + 2 * style.margin_spacings;
        const spacings_down: f32 = region_rows + 2 * style.margin_spacings;
        const fitting_spacing_px: f32 = @min(window_width_px / spacings_across, window_height_px / spacings_down);
        const spacing_px: f32 = @max(@floor(fitting_spacing_px), 1);
        const region_middle_col: f32 = float(region.first_col) + region_cols / 2;
        const region_middle_row: f32 = float(region.first_row) + region_rows / 2;
        const origin_x_px: f32 = @floor(window_width_px / 2 - region_middle_col * spacing_px);
        const origin_y_px: f32 = @floor(window_height_px / 2 - region_middle_row * spacing_px);
        const layout: BoardLayout = .{
            .board_size = board_size,
            .spacing_px = spacing_px,
            .origin_px = .{ origin_x_px, origin_y_px },
            .grid_px = spacing_px * float(board_size - 1),
        };
        return layout;
    }

    /// The layout of `position` for a window of this size: its region's when it has one, a problem's, else the
    /// whole board's.
    pub fn forPosition(
        window_width_px: f32,
        window_height_px: f32,
        position: *const Position,
        style: BoardStyle,
    ) BoardLayout {
        if (position.region) |region| {
            return .forRegion(window_width_px, window_height_px, position.board_size, region, style);
        }
        return .fromWindow(window_width_px, window_height_px, position.board_size, style);
    }

    /// The screen position of a point: the origin plus its column and row in spacings.
    pub fn pointPosition(layout: BoardLayout, point: Point) Vec2 {
        const col: f32 = float(colOf(layout.board_size, point));
        const row: f32 = float(rowOf(layout.board_size, point));
        const position_px: Vec2 = .{
            layout.origin_px[0] + col * layout.spacing_px,
            layout.origin_px[1] + row * layout.spacing_px,
        };
        return position_px;
    }

    /// The point nearest the pointer, or null when the pointer is more than half a spacing outside the grid. The
    /// pointer's offset from the origin, in spacings, is rounded to the nearest whole column and row; rounding is
    /// done with a floor of the value plus one half, which rounds the same way on both sides of zero, so a pointer
    /// just left of the grid gives column -1 (off the board) rather than column 0.
    pub fn pointUnderPointer(layout: BoardLayout, pointer_px: Vec2) ?Point {
        const offset_cols: f32 = (pointer_px[0] - layout.origin_px[0]) / layout.spacing_px;
        const offset_rows: f32 = (pointer_px[1] - layout.origin_px[1]) / layout.spacing_px;
        const nearest_col: i32 = @floor(offset_cols + 0.5);
        const nearest_row: i32 = @floor(offset_rows + 0.5);
        if (!isOnBoard(layout.board_size, nearest_row, nearest_col)) {
            return null;
        }
        const row: u8 = @intCast(nearest_row);
        const col: u8 = @intCast(nearest_col);
        const point: Point = pointAt(layout.board_size, row, col);
        return point;
    }

    /// `pointer_px` brought onto the board: itself when it is over the grid, the nearest place on the grid's outline
    /// when it is outside but no farther than `reach_px` from it, and null when it is farther - off the board.
    ///
    ///       pointer just outside, left     ->  the grid's left edge, at the pointer's height
    ///       pointer just outside a corner  ->  the corner
    pub fn clampedOntoBoard(layout: BoardLayout, pointer_px: Vec2, reach_px: f32) ?Vec2 {
        const grid_min_px: Vec2 = layout.origin_px;
        const grid_max_px: Vec2 = layout.origin_px + Vec2{ layout.grid_px, layout.grid_px };
        const clamped_px: Vec2 = clamp(pointer_px, grid_min_px, grid_max_px);
        const outside_by_px: Vec2 = pointer_px - clamped_px;
        const distance_outside_squared_px: f32 = lengthSq2(outside_by_px);
        const within_reach: bool = distance_outside_squared_px <= reach_px * reach_px;
        if (!within_reach) {
            return null;
        }
        return clamped_px;
    }
};

// ---- The capture columns ----
//
// The stones a player has captured are kept beside the board, as on a real one: black's prisoners - white stones -
// in a column on the left, white's on the right. A captured stone is a little smaller than a board stone, and the
// column starts level with the board's top line:
//
//       left column       board                                    right column
//          (O)    gap  X--+--+--+--+--+--+--X  gap    (X)
//          (O)            |  |  |  |  |  |  |            (X)
//          (O)                                            ...
//
// While the column fits in the board's height the stones touch, one captured stone apart. When it does not, they
// close up like a stack of coins, down to `slot_spacing_min_radii` apart; past that, the column wraps into a second
// column further out. Both sides use the same spacing - the one the fuller side needs - so the two columns stay level.

/// Where the captured stones are drawn this frame. All values are logical pixels.
pub const CaptureColumns = struct {
    /// The centre of the first slot of each side's first column: level with the board's top line.
    left_top_px: Vec2,
    right_top_px: Vec2,
    /// A captured stone's radius, and the width its picture is drawn at.
    stone_radius_px: f32,
    stone_size_px: f32,
    /// The distance between two slots of a column, centre to centre.
    slot_spacing_px: f32,
    /// How many slots one column holds before the next one starts, and how far out the next one is.
    slots_per_column: u32,
    column_step_px: f32,

    /// The columns for this frame's board, with the slots `slot_spacing_px` apart.
    pub fn fromLayout(
        layout: BoardLayout,
        style: BoardStyle,
        slot_spacing_px: f32,
    ) CaptureColumns {
        const board_stone_radius_px: f32 = layout.spacing_px / 2;
        const stone_radius_px: f32 = board_stone_radius_px * style.captured_stone_radius_fraction;
        const gap_px: f32 = board_stone_radius_px * style.column_gap_radii;
        const distance_from_grid_px: f32 = board_stone_radius_px + gap_px + stone_radius_px;
        const top_y_px: f32 = layout.origin_px[1];
        const left_x_px: f32 = layout.origin_px[0] - distance_from_grid_px;
        const right_x_px: f32 = layout.origin_px[0] + layout.grid_px + distance_from_grid_px;
        // The spacing is often the board's height divided by a whole number of gaps, exactly (`fittedSlotSpacing`),
        // and the division back can land a hair below that number; the small tolerance keeps such a column whole
        // instead of starting a second column for its last stone.
        const slot_gaps_in_height: f32 = layout.grid_px / @max(slot_spacing_px, 1);
        const whole_slot_gaps: u32 = @floor(slot_gaps_in_height + 1.0e-3);
        const slots_per_column: u32 = whole_slot_gaps + 1;
        const stone_size_px: f32 = stone_radius_px * style.captured_stone_size_radii;
        const columns: CaptureColumns = .{
            .left_top_px = .{ left_x_px, top_y_px },
            .right_top_px = .{ right_x_px, top_y_px },
            .stone_radius_px = stone_radius_px,
            .stone_size_px = stone_size_px,
            .slot_spacing_px = slot_spacing_px,
            .slots_per_column = slots_per_column,
            .column_step_px = stone_size_px,
        };
        return columns;
    }

    /// The centre of slot `slot` of the column of the stones `capturer` has taken: black's on the left, white's on
    /// the right; down the first column, then down the next one, further out.
    pub fn slotPosition(columns: CaptureColumns, capturer: Stone, slot: u32) Vec2 {
        const column_index: u32 = slot / columns.slots_per_column;
        const row_index: u32 = slot % columns.slots_per_column;
        const outward_px: f32 = float(column_index) * columns.column_step_px;
        const down_px: f32 = float(row_index) * columns.slot_spacing_px;
        if (capturer == .black) {
            const left_position_px: Vec2 = .{ columns.left_top_px[0] - outward_px, columns.left_top_px[1] + down_px };
            return left_position_px;
        }
        const right_position_px: Vec2 = .{ columns.right_top_px[0] + outward_px, columns.right_top_px[1] + down_px };
        return right_position_px;
    }
};

/// The slot spacing a column of `slot_count` stones wants (the lesson above): one captured stone apart while they
/// fit in the board's height, closer when they do not, but never closer than `slot_spacing_min_radii`.
pub fn fittedSlotSpacing(layout: BoardLayout, style: BoardStyle, slot_count: u32) f32 {
    const board_stone_radius_px: f32 = layout.spacing_px / 2;
    const stone_radius_px: f32 = board_stone_radius_px * style.captured_stone_radius_fraction;
    const touching_px: f32 = 2 * stone_radius_px;
    const closest_px: f32 = style.slot_spacing_min_radii * stone_radius_px;
    if (slot_count <= 1) {
        return touching_px;
    }
    const gaps: f32 = float(slot_count - 1);
    const fitting_px: f32 = layout.grid_px / gaps;
    const spacing_px: f32 = clamp(fitting_px, closest_px, touching_px);
    return spacing_px;
}

// ===== 9. Drawing =====
//
// A frame draws back to front: the wood, covering the whole window; the grid's lines; the star points; the rings of
// the groups in atari and of the groups the hovered move would capture; the stones; the marker of the last move; the
// hovered group's liberties; the ghost. Nothing here changes the game - every function takes the position
// read-only.
//
// STAR POINTS (hoshi) are the dots that help a player find their way on a large board. They stand on the third line
// from each edge (the second on boards up to 9 x 9): the four corner points, the centre on a board with a centre,
// and from 13 x 13 up the four points halfway along each side.
//
//       9 x 9:  . . . . . . . . .         13 x 13 and 19 x 19: the same on the third line,
//               . . . . . . . . .         plus the side points
//               . . * . . . * . .
//               . . . . . . . . .
//               . . . . * . . . .
//               . . . . . . . . .
//               . . * . . . * . .

/// The star points of a board of this size, written into the caller's buffer (the section's lesson draws them).
pub fn starPoints(board_size: u8, out_buffer: *[board_limits.max_star_points]Point) []const Point {
    var star_points: ArrayList(Point) = .initBuffer(out_buffer);
    const board_has_star_points: bool = board_size >= 5;
    if (!board_has_star_points) {
        return star_points.items;
    }
    var line_from_edge: u8 = 3;
    if (board_size <= 9) {
        line_from_edge = 2;
    }
    const near: u8 = line_from_edge;
    const far: u8 = board_size - 1 - line_from_edge;
    const centre: u8 = board_size / 2;
    const has_centre: bool = board_size % 2 == 1;

    // On a 5 x 5 board the second line from each edge is the middle line, so the four corner points and the centre
    // are one point; it is listed once.
    const corners_coincide: bool = near == far;
    if (corners_coincide) {
        star_points.appendAssumeCapacity(pointAt(board_size, near, near));
        return star_points.items;
    }
    star_points.appendAssumeCapacity(pointAt(board_size, near, near));
    star_points.appendAssumeCapacity(pointAt(board_size, near, far));
    star_points.appendAssumeCapacity(pointAt(board_size, far, near));
    star_points.appendAssumeCapacity(pointAt(board_size, far, far));
    if (has_centre) {
        star_points.appendAssumeCapacity(pointAt(board_size, centre, centre));
        const has_side_points: bool = board_size >= 13;
        if (has_side_points) {
            star_points.appendAssumeCapacity(pointAt(board_size, near, centre));
            star_points.appendAssumeCapacity(pointAt(board_size, far, centre));
            star_points.appendAssumeCapacity(pointAt(board_size, centre, near));
            star_points.appendAssumeCapacity(pointAt(board_size, centre, far));
        }
    }
    return star_points.items;
}

/// The wood: scaled to cover the whole window with its proportions kept, and centred, so whatever is cut off is cut
/// equally from both sides.
fn drawWood(
    gl: *z.WgpuGl,
    wood: z.WgpuTexture,
    window_width_px: f32,
    window_height_px: f32,
) void {
    const wood_width_px: f32 = float(wood.width);
    const wood_height_px: f32 = float(wood.height);
    const scale_to_fill_width: f32 = window_width_px / wood_width_px;
    const scale_to_fill_height: f32 = window_height_px / wood_height_px;
    const cover_scale: f32 = @max(scale_to_fill_width, scale_to_fill_height);
    const drawn_width_px: f32 = wood_width_px * cover_scale;
    const drawn_height_px: f32 = wood_height_px * cover_scale;
    const destination: z.Rectangle = .{
        .x = (window_width_px - drawn_width_px) / 2,
        .y = (window_height_px - drawn_height_px) / 2,
        .width = drawn_width_px,
        .height = drawn_height_px,
    };
    gl.texture(destination, wood, .{});
}

/// One stone's picture, centred on `centre_px`, `size_px` wide, multiplied by `tint` (white for a stone on the board;
/// a lower alpha for the ghost).
fn drawStone(
    gl: *z.WgpuGl,
    stone_texture: z.WgpuTexture,
    centre_px: Vec2,
    size_px: f32,
    tint: Color,
) void {
    const half_px: f32 = size_px / 2;
    const destination: z.Rectangle = .{
        .x = centre_px[0] - half_px,
        .y = centre_px[1] - half_px,
        .width = size_px,
        .height = size_px,
    };
    gl.texture(destination, stone_texture, .{ .tint = tint });
}

/// The pictures the board is drawn with.
pub const Textures = struct {
    wood: z.WgpuTexture,
    black_stone: z.WgpuTexture,
    white_stone: z.WgpuTexture,
};

/// The grid's lines and the star points: the board before any stone.
fn drawGrid(gl: *z.WgpuGl, layout: BoardLayout, style: BoardStyle) void {
    const spacing_px: f32 = layout.spacing_px;
    const origin_px: Vec2 = layout.origin_px;

    // The lines: one vertical and one horizontal per line of the board.
    for (0..layout.board_size) |line_index| {
        const line_offset_px: f32 = float(line_index) * spacing_px;
        const vertical_top: Vec2 = .{ origin_px[0] + line_offset_px, origin_px[1] };
        const vertical_bottom: Vec2 = .{ origin_px[0] + line_offset_px, origin_px[1] + layout.grid_px };
        const horizontal_left: Vec2 = .{ origin_px[0], origin_px[1] + line_offset_px };
        const horizontal_right: Vec2 = .{ origin_px[0] + layout.grid_px, origin_px[1] + line_offset_px };
        gl.line(vertical_top, vertical_bottom, .{ .color = style.line_color, .thickness = style.line_px });
        gl.line(horizontal_left, horizontal_right, .{ .color = style.line_color, .thickness = style.line_px });
    }

    // The star points.
    var star_buffer: [board_limits.max_star_points]Point = undefined;
    const star_radius_px: f32 = @max(spacing_px * style.star_point_radius_spacings, style.star_point_min_radius_px);
    for (starPoints(layout.board_size, &star_buffer)) |star_point| {
        gl.circle(layout.pointPosition(star_point), star_radius_px, .{ .color = style.line_color });
    }
}

/// The stones and the last move's marker.
fn drawStones(
    gl: *z.WgpuGl,
    position: *const Position,
    layout: BoardLayout,
    textures: *const Textures,
    style: BoardStyle,
) void {
    // The stones, drawn untinted.
    const stone_size_px: f32 = layout.spacing_px * style.stone_size_spacings;
    const opaque_white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    for (0..pointCount(layout.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const stone: Stone = position.stones[point];
        const point_is_empty: bool = stone == .none;
        // A problem's ring of the attacker's stones, outside its region, is part of its rules, not of its picture.
        const region: ?ProblemRegion = position.region;
        const outside_problem: bool = region != null and !region.?.contains(layout.board_size, point);
        if (point_is_empty or outside_problem) {
            continue;
        }
        var stone_texture: z.WgpuTexture = textures.black_stone;
        if (stone == .white) {
            stone_texture = textures.white_stone;
        }
        drawStone(gl, stone_texture, layout.pointPosition(point), stone_size_px, opaque_white);
    }

    // The last move's marker: a thin ring on the stone, dark on white and light on black.
    if (position.last_move) |last_move| {
        var ring_color: Color = style.last_move_ring_on_black;
        if (position.stones[last_move] == .white) {
            ring_color = style.last_move_ring_on_white;
        }
        const ring_radius_px: f32 = layout.spacing_px * style.last_move_ring_radius_spacings;
        gl.circle(layout.pointPosition(last_move), ring_radius_px, .{
            .color = ring_color,
            .outline = style.last_move_ring_px,
        });
    }
}

// ---- The overlays ----
//
// Three overlays read the forest to show the player what the rules see. They are drawn in this order:
//
//   groups in atari        a thin red ring around every stone of a group with one liberty left     under the stones
//   the doomed groups      a dark red ring, pulsing, around the stones the hovered move would take   under the stones
//   liberties              a ring, pulsing, on each liberty of the groups the pointer bears on,     over the stones
//                          and each group's liberty count on its stone beside the ghost - gold
//                          rings for the mover's groups, pale blue for the opponent's
//
// The liberties are those the groups WOULD have if the ghost's stone were played: the overlay reads the position the
// move would make (`positionAfterMove`), not the one on the board. So the groups shown are the ones touching the
// stone in that position - the mover's group it joins, with every liberty the joined group would have, and the
// opponent's groups beside it, less the liberty the stone takes - and a stone alone, which joins nothing, shows no
// liberties of its own. A group the move would capture is gone from that position: the doomed ring marks it instead.
// Without a ghost, a stone under the pointer shows its group's liberties as they are.
//
//       on the board          the ghost at x           what is shown
//       . . . . .             . . . . .                . o o b .        o: the joined black group's 5 liberties;
//       . X . O .             . X x O .                o X x O b           on X, "4" changing to "5"
//       . . . . .             . . . . .                . o o b .        b: white's 3 left of 4; on O, "4" to "3"
//
// The COUNTS show the move's effect as it happens: each group touching the ghost has its count written on its stone
// beside the ghost, showing the group's liberties as they are for a moment, then changing smoothly to what they would
// be after the move - so a player sees "4" become "5" as a stone joins a group, or "1" become "0" as a group is about
// to be taken. A stone alone, touching no group, has no count.
//
// The two hover overlays pulse - their opacity follows a sine between two values - and fade in when the pointer
// reaches a new point, so a glance across the board does not flicker with them. Their clock starts again on every
// new point (`HoverClock`).

/// Which overlays are drawn: the player's choice, in the pause window.
pub const OverlayOptions = struct {
    atari_groups: bool = true,
    doomed_groups: bool = true,
    liberties: bool = true,
};

/// How long the pointer has been on the point it is on: the clock of the hover overlays' fade and pulse.
pub const HoverClock = struct {
    point: ?Point = null,
    seconds: f32 = 0,

    /// Counts `dt` more on the same point, or starts again from zero on a new one.
    pub fn advance(clock: *HoverClock, hovered_point: ?Point, dt: f32) void {
        const on_a_new_point: bool = clock.point != hovered_point;
        if (on_a_new_point) {
            clock.point = hovered_point;
            clock.seconds = 0;
            return;
        }
        clock.seconds += dt;
    }

    /// An overlay's opacity now: between `low` and `high` with the pulse, times the fade-in.
    pub fn alpha(clock: HoverClock, low: f32, high: f32, style: BoardStyle) u8 {
        const fade_in: f32 = clamp01(clock.seconds * style.overlay_fade_in_per_second);
        const wave: f32 = sinRad(clock.seconds * style.overlay_pulse_radians_per_second);
        const pulse: f32 = 0.5 + 0.5 * wave;
        const pulsing_alpha: f32 = low + (high - low) * pulse;
        const shown_alpha: f32 = fade_in * pulsing_alpha;
        const as_byte: u8 = @round(clamp(shown_alpha, 0, 255));
        return as_byte;
    }
};

/// `color` with its alpha replaced.
fn withAlpha(color: Color, alpha: u8) Color {
    const recoloured: Color = .{ .r = color.r, .g = color.g, .b = color.b, .a = alpha };
    return recoloured;
}

/// A problem's target, while it stands, marked as an SGF viewer marks it: a dark triangle, a corner up, on a white
/// stone to capture; a light square on a black stone to save.
fn drawTargetMark(
    gl: *z.WgpuGl,
    position: *const Position,
    layout: BoardLayout,
    style: BoardStyle,
) void {
    const target: Point = position.target orelse {
        return;
    };
    if (position.stones[target] == .none) {
        return;
    }
    const center_px: Vec2 = layout.pointPosition(target);
    const corner_distance_px: f32 = style.target_mark_spacings * layout.spacing_px;
    if (position.stones[target] == .black) {
        const half_side_px: f32 = corner_distance_px * 0.75;
        const corner_steps = [_]Vec2{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        for (corner_steps, 0..) |corner_step, corner_index| {
            const next_step: Vec2 = corner_steps[(corner_index + 1) % corner_steps.len];
            const corner_px: Vec2 = center_px + corner_step * splat2(half_side_px);
            const next_corner_px: Vec2 = center_px + next_step * splat2(half_side_px);
            gl.line(corner_px, next_corner_px, .{ .color = style.save_mark_color, .thickness = style.target_mark_px });
        }
        return;
    }
    // The three corners, a third of a turn apart, the first straight up.
    var corners_px: [3]Vec2 = undefined;
    for (&corners_px, 0..) |*corner_px, corner_index| {
        const angle: f32 = -pi / 2.0 + float(corner_index) * 2 * pi / 3.0;
        const direction: Vec2 = .{ @cos(angle), @sin(angle) };
        corner_px.* = center_px + direction * splat2(corner_distance_px);
    }
    for (0..3) |corner_index| {
        const next_corner_index: usize = (corner_index + 1) % 3;
        gl.line(corners_px[corner_index], corners_px[next_corner_index], .{
            .color = style.target_mark_color,
            .thickness = style.target_mark_px,
        });
    }
}

/// A thin red ring just outside every stone of every group in atari: groups whose root has one liberty.
fn drawAtariRings(
    gl: *z.WgpuGl,
    position: *const Position,
    layout: BoardLayout,
    style: BoardStyle,
) void {
    const stone_radius_px: f32 = layout.spacing_px * style.stone_size_spacings / 2;
    const ring_radius_px: f32 = stone_radius_px + style.atari_ring_gap_px + style.atari_ring_px;
    for (0..pointCount(layout.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const is_group_root: bool = isRoot(position, point);
        if (!is_group_root) {
            continue;
        }
        const in_atari: bool = position.group_liberties[point].count() == 1;
        if (!in_atari) {
            continue;
        }
        var stones: PointSet.Iterator(.{}) = position.group_stones[point].iterator(.{});
        while (stones.next()) |stone_index| {
            const stone_point: Point = @intCast(stone_index);
            gl.circle(layout.pointPosition(stone_point), ring_radius_px, .{
                .color = style.atari_ring_color,
                .outline = style.atari_ring_px,
            });
        }
    }
}

/// A dark red ring around every stone of the groups a move on `hovered_point` would capture (`groupsCapturedBy`),
/// pulsing.
fn drawDoomedRings(
    gl: *z.WgpuGl,
    position: *const Position,
    hovered_point: Point,
    clock: HoverClock,
    layout: BoardLayout,
    style: BoardStyle,
) void {
    var root_buffer: [board_limits.max_neighbors]Point = undefined;
    const doomed_roots: []const Point = groupsCapturedBy(position, hovered_point, &root_buffer);
    const alpha: u8 = clock.alpha(style.doomed_alpha_low, style.doomed_alpha_high, style);
    const ring_color: Color = withAlpha(style.doomed_ring_color, alpha);
    const stone_radius_px: f32 = layout.spacing_px * style.stone_size_spacings / 2;
    const ring_radius_px: f32 = stone_radius_px + style.doomed_ring_gap_px + style.doomed_ring_px;
    for (doomed_roots) |doomed_root| {
        var stones: PointSet.Iterator(.{}) = position.group_stones[doomed_root].iterator(.{});
        while (stones.next()) |stone_index| {
            const stone_point: Point = @intCast(stone_index);
            gl.circle(layout.pointPosition(stone_point), ring_radius_px, .{
                .color = ring_color,
                .outline = style.doomed_ring_px,
            });
        }
    }
}

/// The groups whose liberties are shown (the overlays' lesson), as their roots in `shown_position`, written into the
/// caller's buffer: the groups touching the ghost's point, of both players, and the group of a stone under the
/// pointer - each once. Given the position the ghost's move would make, the mover's group touching the ghost's point
/// is the one the stone joins (a stone alone touches none of its own), and a group the move captures is not there.
pub fn libertyOverlayGroups(
    position: *const Position,
    ghost_point: ?Point,
    pointed_point: ?Point,
    out_buffer: *[board_limits.max_neighbors + 1]Point,
) []const Point {
    var groups: ArrayList(Point) = .initBuffer(out_buffer);
    if (ghost_point) |point| {
        var touching_buffer: [board_limits.max_neighbors]Point = undefined;
        const touching: []const Point = groupsTouching(position, point, &touching_buffer);
        groups.appendSliceAssumeCapacity(touching);
    }
    if (pointed_point) |point| {
        // A stone under the pointer that is the ghost's own - in the position its move would make, the pointer's point
        // holds it - is no stone of the board: a stone alone shows nothing.
        const pointer_on_the_ghost: bool = ghost_point != null and ghost_point.? == point;
        const pointer_on_a_stone: bool = position.stones[point] != .none and !pointer_on_the_ghost;
        if (pointer_on_a_stone) {
            const pointed_root: Point = findRoot(position, point);
            const already_listed: bool = indexOfScalar(Point, groups.items, pointed_root) != null;
            if (!already_listed) {
                groups.appendAssumeCapacity(pointed_root);
            }
        }
    }
    return groups.items;
}

/// A liberty count shown on the board (the overlays' lesson): the stone it is written on - the group's stone beside
/// the ghost, or the stone under the pointer - and the group's liberties before the ghost's move and after it.
pub const LibertyLabel = struct {
    stone: Point,
    before: usize,
    after: usize,
};

/// The liberty counts to show (the overlays' lesson), written into the caller's buffer: one for each group touching
/// the ghost's point - on its first stone beside the point, found in `position`, the board as it is - and one for a
/// stone under the pointer whose group has none yet. `after` is the position the ghost's move would make (or
/// `position` itself when there is no ghost): a group the move would capture is gone from it, and its count after is
/// zero.
/// How many of the group on `root`'s liberties lie inside the position's playable region (`playableRegion`): in a
/// problem, the ones a player can see and fill - a group joined to the ring outside the region has the ring's too, and
/// those are not shown.
fn regionLibertyCount(position: *const Position, root: Point) usize {
    const region: ProblemRegion = playableRegion(position);
    var count: usize = 0;
    var liberties: PointSet.Iterator(.{}) = position.group_liberties[root].iterator(.{});
    while (liberties.next()) |liberty_index| {
        count += @intFromBool(region.contains(position.board_size, @intCast(liberty_index)));
    }
    return count;
}

pub fn libertyLabels(
    position: *const Position,
    after: *const Position,
    ghost_point: ?Point,
    pointed_point: ?Point,
    out_buffer: *[board_limits.max_neighbors + 1]LibertyLabel,
) []const LibertyLabel {
    var labels: ArrayList(LibertyLabel) = .initBuffer(out_buffer);
    var labelled_roots_buffer: [board_limits.max_neighbors + 1]Point = undefined;
    var labelled_roots: ArrayList(Point) = .initBuffer(&labelled_roots_buffer);
    var candidate_buffer: [board_limits.max_neighbors + 1]Point = undefined;
    var candidates: ArrayList(Point) = .initBuffer(&candidate_buffer);
    if (ghost_point) |point| {
        var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
        candidates.appendSliceAssumeCapacity(neighborsOf(position.board_size, point, &neighbor_buffer));
    }
    if (pointed_point) |point| {
        const pointer_on_the_ghost: bool = ghost_point != null and ghost_point.? == point;
        if (!pointer_on_the_ghost) {
            candidates.appendAssumeCapacity(point);
        }
    }
    const region: ProblemRegion = playableRegion(position);
    for (candidates.items) |stone| {
        // A stone outside the region - the ring's - is not shown, and its count is not either.
        const has_a_stone: bool = position.stones[stone] != .none;
        if (!has_a_stone or !region.contains(position.board_size, stone)) {
            continue;
        }
        const root_now: Point = findRoot(position, stone);
        const already_labelled: bool = indexOfScalar(Point, labelled_roots.items, root_now) != null;
        if (already_labelled) {
            continue;
        }
        labelled_roots.appendAssumeCapacity(root_now);
        const before: usize = regionLibertyCount(position, root_now);
        var after_count: usize = 0;
        const survives: bool = after.stones[stone] != .none;
        if (survives) {
            after_count = regionLibertyCount(after, findRoot(after, stone));
        }
        labels.appendAssumeCapacity(.{ .stone = stone, .before = before, .after = after_count });
    }
    return labels.items;
}

/// A ring, pulsing, on each liberty of each group in `group_roots`, as `position` has them: gold for the groups of
/// `mover`, the player whose ghost it is, pale blue for the opponent's. A point that is a liberty of groups of both
/// players gets both rings, the later one drawn over the earlier.
fn drawLibertyMarks(
    gl: *z.WgpuGl,
    position: *const Position,
    group_roots: []const Point,
    mover: Stone,
    clock: HoverClock,
    layout: BoardLayout,
    style: BoardStyle,
) void {
    const alpha: u8 = clock.alpha(style.liberty_alpha_low, style.liberty_alpha_high, style);
    const mark_radius_px: f32 = layout.spacing_px * style.liberty_mark_radius_spacings;
    for (group_roots) |group_root| {
        const is_movers_group: bool = position.stones[group_root] == mover;
        var base_color: Color = style.liberty_mark_color_opponent;
        if (is_movers_group) {
            base_color = style.liberty_mark_color;
        }
        const mark_color: Color = withAlpha(base_color, alpha);
        const region: ProblemRegion = playableRegion(position);
        var liberties: PointSet.Iterator(.{}) = position.group_liberties[group_root].iterator(.{});
        while (liberties.next()) |liberty_index| {
            const liberty_point: Point = @intCast(liberty_index);
            // Outside a problem's region, a liberty is the ring's: not shown.
            if (!region.contains(position.board_size, liberty_point)) {
                continue;
            }
            gl.circle(layout.pointPosition(liberty_point), mark_radius_px, .{
                .color = mark_color,
                .outline = style.liberty_mark_px,
            });
        }
    }
}

/// Writes a count, centred on `centre_px`, at the given opacity.
fn drawCount(
    gl: *z.WgpuGl,
    count: usize,
    centre_px: Vec2,
    color: Color,
    font: *const z.Font,
    text_size_px: f32,
) void {
    // A board has at most 361 points, so a count has at most three digits.
    var digits_buffer: [3]u8 = undefined;
    const digit_count: usize = printInt(&digits_buffer, count, 10, .lower, .{});
    const digits: []const u8 = digits_buffer[0..digit_count];
    const text_extent_px: Vec2 = z.measureText(font.*, digits, text_size_px);
    const half_extent_px: Vec2 = text_extent_px / Vec2{ 2, 2 };
    gl.text(centre_px - half_extent_px, digits, .{ .size = text_size_px, .color = color, .font = font });
}

/// The liberty counts (`libertyLabels`), each on its stone: light on a black stone, dark on a white one. A count that
/// the move changes shows its value before for `liberty_count_hold_seconds` after the ghost reaches its point, then
/// fades into its value after over `liberty_count_switch_seconds`, eased by smootherStep01 - the old number fading
/// out as the new one fades in, in the same place.
fn drawLibertyCounts(
    gl: *z.WgpuGl,
    position: *const Position,
    labels: []const LibertyLabel,
    font: *const z.Font,
    clock: HoverClock,
    layout: BoardLayout,
    style: BoardStyle,
) void {
    const text_size_px: f32 = layout.spacing_px * style.liberty_count_size_spacings;
    const seconds_switching: f32 = clock.seconds - style.liberty_count_hold_seconds;
    const switch_fraction: f32 = seconds_switching / style.liberty_count_switch_seconds;
    const after_share: f32 = smootherStep01(switch_fraction);
    for (labels) |label| {
        var text_color: Color = style.liberty_count_on_black;
        if (position.stones[label.stone] == .white) {
            text_color = style.liberty_count_on_white;
        }
        const centre_px: Vec2 = layout.pointPosition(label.stone);
        const count_changes: bool = label.before != label.after;
        if (!count_changes) {
            drawCount(gl, label.after, centre_px, text_color, font, text_size_px);
            continue;
        }
        const before_alpha: u8 = @round(255 * (1 - after_share));
        const after_alpha: u8 = @round(255 * after_share);
        drawCount(gl, label.before, centre_px, withAlpha(text_color, before_alpha), font, text_size_px);
        drawCount(gl, label.after, centre_px, withAlpha(text_color, after_alpha), font, text_size_px);
    }
}

// ---- The forest view ----
//
// The forest itself, drawn on the board - what the rules work on, made visible: every stone that is not a root has an
// arrow to its parent, and every root is a square. Placing a stone makes it the root of the group it joins, and the
// walk up from a stone to its root shortens each time a stone is placed beside it (path compression, section 2), so
// the arrows change move by move. The path from the stone under the pointer to its root - the walk findRoot makes -
// is drawn over the rest, and each stone's depth, the steps up to its root, can be written beside it.
//
//         X <-- X <-- X          a group of three: two arrows, and the root - the square - at the left
//        [ ]

/// One arrow from `from_px` toward `to_px`: it leaves `from_px` a little off its centre and stops short of `to_px`,
/// so its head lands at the edge of the parent's stone rather than under it.
fn drawArrow(
    gl: *z.WgpuGl,
    from_px: Vec2,
    to_px: Vec2,
    color: Color,
    thickness_px: f32,
    layout: BoardLayout,
    style: BoardStyle,
) void {
    const offset_px: Vec2 = to_px - from_px;
    const length_px: f32 = @sqrt(lengthSq2(offset_px));
    const stop_px: f32 = style.forest_arrow_stop_spacings * layout.spacing_px;
    const start_px: f32 = style.forest_arrow_start_spacings * layout.spacing_px;
    const too_short: bool = length_px <= start_px + stop_px;
    if (too_short) {
        return;
    }
    const direction: Vec2 = offset_px / Vec2{ length_px, length_px };
    const across: Vec2 = .{ -direction[1], direction[0] };
    const tail_px: Vec2 = from_px + direction * Vec2{ start_px, start_px };
    const tip_px: Vec2 = to_px - direction * Vec2{ stop_px, stop_px };
    const head_px: f32 = style.forest_arrow_head_spacings * layout.spacing_px;
    const head_back_px: Vec2 = tip_px - direction * Vec2{ head_px, head_px };
    const head_side_px: Vec2 = across * Vec2{ head_px * 0.6, head_px * 0.6 };
    gl.line(tail_px, tip_px, .{ .color = color, .thickness = thickness_px });
    gl.line(tip_px, head_back_px + head_side_px, .{ .color = color, .thickness = thickness_px });
    gl.line(tip_px, head_back_px - head_side_px, .{ .color = color, .thickness = thickness_px });
}

/// The forest view (the lesson above): the arrows, the roots' squares, the pointed stone's path to its root over the
/// rest, and - when `show_depths` - each stone's depth.
fn drawForestView(
    gl: *z.WgpuGl,
    position: *const Position,
    pointed_point: ?Point,
    show_depths: bool,
    font: *const z.Font,
    layout: BoardLayout,
    style: BoardStyle,
) void {
    var arrow_buffer: [board_limits.max_points]ForestArrow = undefined;
    for (forestArrows(position, &arrow_buffer)) |arrow| {
        const from_px: Vec2 = layout.pointPosition(arrow.from);
        const to_px: Vec2 = layout.pointPosition(arrow.to);
        drawArrow(gl, from_px, to_px, style.forest_arrow_color, style.forest_arrow_px, layout, style);
    }

    // The roots: a square on each.
    const half_px: f32 = style.forest_root_half_spacings * layout.spacing_px;
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const is_a_root: bool = position.stones[point] != .none and isRoot(position, point);
        if (!is_a_root) {
            continue;
        }
        const centre_px: Vec2 = layout.pointPosition(point);
        const square: z.Rectangle = .{
            .x = centre_px[0] - half_px,
            .y = centre_px[1] - half_px,
            .width = 2 * half_px,
            .height = 2 * half_px,
        };
        gl.rect(square, .{ .color = style.forest_root_color, .outline = style.forest_arrow_px });
    }

    // The pointed stone's walk up to its root.
    if (pointed_point) |point| {
        const pointer_on_a_stone: bool = position.stones[point] != .none;
        if (pointer_on_a_stone) {
            var path_buffer: [board_limits.max_points]Point = undefined;
            const path: []const Point = pathToRoot(position, point, &path_buffer);
            for (path[0 .. path.len - 1], path[1..]) |step_from, step_to| {
                const from_px: Vec2 = layout.pointPosition(step_from);
                const to_px: Vec2 = layout.pointPosition(step_to);
                drawArrow(gl, from_px, to_px, style.forest_path_color, style.forest_path_px, layout, style);
            }
        }
    }

    // The depths: written small at each stone's lower right.
    if (!show_depths) {
        return;
    }
    const text_size_px: f32 = style.forest_depth_size_spacings * layout.spacing_px;
    const corner_offset_px: Vec2 = .{ 0.12 * layout.spacing_px, 0.05 * layout.spacing_px };
    for (0..pointCount(position.board_size)) |point_index| {
        const point: Point = @intCast(point_index);
        const point_is_empty: bool = position.stones[point] == .none;
        if (point_is_empty) {
            continue;
        }
        const depth: u32 = inspectPoint(position, point).depth;
        var digits_buffer: [3]u8 = undefined;
        const digit_count: usize = printInt(&digits_buffer, depth, 10, .lower, .{});
        var text_color: Color = style.liberty_count_on_black;
        if (position.stones[point] == .white) {
            text_color = style.liberty_count_on_white;
        }
        const top_left_px: Vec2 = layout.pointPosition(point) + corner_offset_px;
        const digits: []const u8 = digits_buffer[0..digit_count];
        gl.text(top_left_px, digits, .{ .size = text_size_px, .color = text_color, .font = font });
    }
}

/// The ghost: the stone the player to move would place, drawn where the pointer would place it. It moves on a spring
/// (`zm.DoubleSpring`), so it glides from point to point as the pointer crosses the board instead of jumping, and it
/// eases in and out of each move rather than starting and stopping at once.
pub const Ghost = struct {
    /// Where the ghost is drawn, chasing the pointer's point.
    spring: DoubleSpring(Vec2),
    /// Whether the ghost has a point to show this frame: the pointer is over a point where a move is legal.
    has_target: bool,
    /// The point it shows, or last showed: what the next frame's drop point holds steady against (section 10).
    point: ?Point,

    /// A ghost with nowhere to be: hidden until the pointer finds a legal point.
    pub const hidden: Ghost = .{ .spring = .atRest(.{ 0, 0 }), .has_target = false, .point = null };
};

/// Moves the ghost toward `target_point`, the point under the pointer when a move is legal there, or hides it when
/// there is none. A ghost that had no target appears on its first one at once, rather than gliding in from wherever
/// it was last seen.
pub fn updateGhost(
    ghost: *Ghost,
    target_point: ?Point,
    layout: BoardLayout,
    style: BoardStyle,
    dt: f32,
) void {
    ghost.point = target_point;
    const point: Point = target_point orelse {
        ghost.has_target = false;
        return;
    };
    const target_px: Vec2 = layout.pointPosition(point);
    if (!ghost.has_target) {
        const resting_at_target: DoubleSpring(Vec2) = .atRest(target_px);
        ghost.spring = resting_at_target;
        ghost.has_target = true;
    }
    ghost.spring.step(target_px, style.ghost_blend_seconds, dt);
}

/// Draws the ghost, if it has a target: a stone of the player to move, nearly opaque while a stone is held, lighter
/// while it only follows the pointer.
fn drawGhost(
    gl: *z.WgpuGl,
    ghost: *const Ghost,
    player_to_move: Stone,
    stone_held: bool,
    layout: BoardLayout,
    textures: *const Textures,
    style: BoardStyle,
) void {
    if (!ghost.has_target) {
        return;
    }
    var stone_texture: z.WgpuTexture = textures.black_stone;
    var alpha: u8 = style.ghost_alpha_black;
    if (player_to_move == .white) {
        stone_texture = textures.white_stone;
        alpha = style.ghost_alpha_white;
    }
    if (stone_held) {
        alpha = style.ghost_alpha_held;
    }
    const tint: Color = .{ .r = 255, .g = 255, .b = 255, .a = alpha };
    const stone_size_px: f32 = layout.spacing_px * style.stone_size_spacings;
    drawStone(gl, stone_texture, ghost.spring.value, stone_size_px, tint);
}

// ---- The captured stones ----
//
// A captured stone does not vanish: it flies from its point to its slot in the capturer's column, shrinking to a
// captured stone's size on the way, eased in and out by `smootherStep01`. The stones of one capture leave one after
// another, a little apart, so a large capture pours into the column rather than jumping there.
//
// A flight remembers where it started (the point) and where it goes (the slot), not the pixels of either: both are
// placed again every frame, from the board and the columns as they are that frame. So a flight follows a window
// being resized, and lands on its slot even when the column closes up while it is in the air.
//
// The column shows the stones that have landed: a side's prisoners less its stones still in flight. In Atari Go the
// slots up to the capture goal that are still empty show as circles, the distance left to win.

/// Where a flying stone is drawn: its centre and its width.
pub const FlightPlacement = struct {
    centre_px: Vec2,
    size_px: f32,
};

/// One captured stone on its way to its column.
pub const Flight = struct {
    /// The point it was captured on, and the slot it goes to in the column of the stones `capturer` has taken.
    from_point: Point,
    capturer: Stone,
    slot: u32,
    /// How long after the capture it leaves, and how long ago the capture was.
    delay_seconds: f32,
    seconds: f32,

    /// How far along its flight is, from 0 (still on its point) to 1 (in its slot).
    pub fn progress(flight: Flight, style: BoardStyle) f32 {
        const seconds_flying: f32 = flight.seconds - flight.delay_seconds;
        const fraction: f32 = clamp01(seconds_flying / style.flight_seconds);
        return fraction;
    }

    /// Where the stone is drawn now, and how wide: from its point to its slot - both placed from this frame's board
    /// and columns - eased by smootherStep01.
    pub fn placement(
        flight: Flight,
        layout: BoardLayout,
        columns: CaptureColumns,
        style: BoardStyle,
    ) FlightPlacement {
        const eased: f32 = smootherStep01(flight.progress(style));
        const from_px: Vec2 = layout.pointPosition(flight.from_point);
        const to_px: Vec2 = columns.slotPosition(flight.capturer, flight.slot);
        const board_stone_size_px: f32 = layout.spacing_px * style.stone_size_spacings;
        const placed: FlightPlacement = .{
            .centre_px = lerp(from_px, to_px, eased),
            .size_px = lerp(board_stone_size_px, columns.stone_size_px, eased),
        };
        return placed;
    }
};

/// The stones in flight. One capture takes at most every point of the board but the capturing stone, so the board's
/// points are room enough for one; when a new capture does not fit beside the flights still in the air, those land at
/// once.
pub const Flights = struct {
    flights: [board_limits.max_points]Flight,
    count: usize,

    /// No stone in flight.
    pub const none: Flights = .{ .flights = undefined, .count = 0 };

    /// The flights now in the air.
    pub fn inAir(flights: *const Flights) []const Flight {
        const flying: []const Flight = flights.flights[0..flights.count];
        return flying;
    }

    /// Sends the stones a move captured to their capturer's column: the n-th stone of the capture (in reading order)
    /// to the slot after the n-th prisoner the capturer held before, leaving n stagger-steps after the capture.
    pub fn launch(
        flights: *Flights,
        report: MoveReport,
        prisoners_before: u32,
        style: BoardStyle,
    ) void {
        const capture_size: usize = report.captured_count;
        const room_left: usize = flights.flights.len - flights.count;
        if (capture_size > room_left) {
            flights.count = 0;
        }
        var captured: PointSet.Iterator(.{}) = report.captured.iterator(.{});
        var stone_number: u32 = 0;
        while (captured.next()) |point_index| {
            const flight: Flight = .{
                .from_point = @intCast(point_index),
                .capturer = report.mover,
                .slot = prisoners_before + stone_number,
                .delay_seconds = float(stone_number) * style.flight_stagger_seconds,
                .seconds = 0,
            };
            flights.flights[flights.count] = flight;
            flights.count += 1;
            stone_number += 1;
        }
    }

    /// Moves every flight on by `dt`, and takes out those that have landed.
    pub fn advance(flights: *Flights, dt: f32, style: BoardStyle) void {
        var kept: usize = 0;
        for (flights.flights[0..flights.count]) |flight| {
            var moved: Flight = flight;
            moved.seconds += dt;
            const has_landed: bool = moved.progress(style) >= 1;
            if (!has_landed) {
                flights.flights[kept] = moved;
                kept += 1;
            }
        }
        flights.count = kept;
    }

    /// How many of `capturer`'s prisoners are still in the air.
    pub fn countFor(flights: *const Flights, capturer: Stone) u32 {
        var in_air: u32 = 0;
        for (flights.inAir()) |flight| {
            if (flight.capturer == capturer) {
                in_air += 1;
            }
        }
        return in_air;
    }
};

/// How many of `capturer`'s prisoners have landed in its column: those captured, less those still in flight.
pub fn landedPrisoners(
    position: *const Position,
    flights: *const Flights,
    capturer: Stone,
) u32 {
    const prisoners: u32 = prisonersOf(position, capturer);
    const landed: u32 = prisoners - flights.countFor(capturer);
    return landed;
}

/// How many slots a side's column shows: its landed prisoners, or the Atari Go goal if that is more.
pub fn shownSlots(
    position: *const Position,
    flights: *const Flights,
    capturer: Stone,
) u32 {
    const landed: u32 = landedPrisoners(position, flights, capturer);
    const goal: u32 = position.capture_goal orelse 0;
    const shown: u32 = @max(landed, goal);
    return shown;
}

/// One side's column: a stone in each slot that has its prisoner, and a circle in each slot the Atari Go goal still
/// wants.
fn drawColumn(
    gl: *z.WgpuGl,
    position: *const Position,
    flights: *const Flights,
    capturer: Stone,
    columns: CaptureColumns,
    textures: *const Textures,
    style: BoardStyle,
) void {
    const landed: u32 = landedPrisoners(position, flights, capturer);
    const shown: u32 = shownSlots(position, flights, capturer);
    var stone_texture: z.WgpuTexture = textures.white_stone;
    if (capturer == .white) {
        stone_texture = textures.black_stone;
    }
    const opaque_white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    for (0..shown) |slot_index| {
        const slot: u32 = @intCast(slot_index);
        const centre_px: Vec2 = columns.slotPosition(capturer, slot);
        const slot_has_prisoner: bool = slot < landed;
        if (slot_has_prisoner) {
            drawStone(gl, stone_texture, centre_px, columns.stone_size_px, opaque_white);
        } else {
            gl.circle(centre_px, columns.stone_radius_px, .{
                .color = style.goal_circle_color,
                .outline = style.goal_circle_px,
            });
        }
    }
}

/// Every stone in flight, where it is now.
fn drawFlights(
    gl: *z.WgpuGl,
    flights: *const Flights,
    layout: BoardLayout,
    columns: CaptureColumns,
    textures: *const Textures,
    style: BoardStyle,
) void {
    const opaque_white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    for (flights.inAir()) |flight| {
        var stone_texture: z.WgpuTexture = textures.white_stone;
        if (flight.capturer == .white) {
            stone_texture = textures.black_stone;
        }
        const placed: FlightPlacement = flight.placement(layout, columns, style);
        drawStone(gl, stone_texture, placed.centre_px, placed.size_px, opaque_white);
    }
}

// ===== 10. Input =====
//
// A stone is placed in two motions, as a stone is set on a real board: the press picks it up, the release puts it
// down. Between them the pointer may move, and the ghost (section 9) follows it, so a player can see where the stone
// will go and correct it before letting go:
//
//       press on a legal point       the stone is held; the ghost turns nearly opaque
//       move                         the ghost follows, from legal point to legal point
//       release on a legal point     the stone is played there
//       release anywhere else        the stone is put back; nothing is played
//
// A press where no move is legal picks nothing up, so a stray tap on a stone does nothing. A finger works the same
// way: the engine reports a touch as the left button, and lifting it is the release.
//
// The interface's windows - the buttons, the menus - take the pointer first. A pointer over one of them is over no
// point of the board, so a press on a button never picks up a stone, and a stone carried onto a button and let go
// there is put back. This file's frame (section 11) submits the windows before it reads the board's input, so it
// knows where they are.
//
// A FINGER HIDES WHAT IT TOUCHES. On a touch screen the point under the fingertip is the one the player cannot see,
// so for a finger the board reads the point a fixed distance above it, and the ghost is drawn there, clear of the
// finger:
//
//         ( ghost )      <- the point the stone goes to: finger_lift_px above the finger
//             |
//          finger
//
// Near the bottom of the window the lift shrinks to the distance left to the edge, so the bottom rows stay within
// reach of a finger that cannot go lower: with the window H tall, a finger at height y aims at y - min(lift, H - y).
// Down to H - lift the aim follows the finger at the full lift; below it the aim moves down twice as fast as the
// finger, and both reach the bottom edge together - one continuous mapping, with no jump where the lift starts to
// shrink.
//
// The engine says what each pointer event came from (`z.pointerKind`): a mouse, a finger on a touch screen, or a pen,
// as the platform reports it. A finger is the one that hides its point; a pen's tip is thin and its point stays in
// sight, so a pen is treated as a mouse.
//
// A finger is on the screen only while it touches: when it lifts it leaves no pointer behind, although the engine
// keeps its last position. So for a finger the board reads nothing between two touches - no ghost waits where the
// last finger lifted, after a button press for instance.
//
// TWO FINGERS ARE NOT A STONE. A second finger on the screen means the person is doing something else - beginning a
// pinch, or resting a hand on the glass - so it cancels the gesture: a stone held is put back, the ghost goes, and the
// board takes no press and no release until every finger is lifted (`FingerGesture`). Lifting the fingers one at a
// time plays nothing, since every lift belongs to the cancelled gesture:
//
//         fingers down    1     2     2     1     0     1
//         the board       aims  -     -     -     -     aims       (- : the pointer ignored)
//
// The fingers are counted where the platform reports each of them (`z.getTouchPointCount`): the browser does, for
// every pointer. Where none is reported the count stays zero and nothing is ever cancelled.
//
// A STONE DROPPED ON A TAKEN POINT goes beside it. The point a stone would drop on - the DROP POINT - is the
// intersection under the pointer if a stone may be played there; if not (a stone stands there, or the move is not
// legal), it is the playable point nearest the pointer, no farther than `drop_reach_spacings` away, measured from the
// pointer itself:
//
//         .   .   .          the pointer (*) is on a stone, a little right of its centre: of the playable
//         .   X * .          points within one spacing of it, the one on the right is the nearest, and the
//         .   .   .          stone goes there
//
// A pointer just off the board - no farther than the same reach from it - is first brought onto the board's edge,
// and the drop point found from there, so a stone let go a little outside the board lands on its edge. Farther off,
// nothing is dropped: carrying a stone well off the board and letting it go puts it back.
//
// The ghost, the press and the release all use the drop point, so the ghost shows where the stone would go before it
// is let go. The overlay of what a stone stands on - its group's liberties - keeps the point under the pointer.
//
// THE GHOST HOLDS STILL, AND THE STONE GOES WHERE IT WAS SEEN. Two things would make a stone land elsewhere than the
// ghost showed. A pointer near the line between two points trembles across it, and the ghost would flicker between
// them; so the ghost keeps its point until another is nearer the pointer by `ghost_hysteresis_spacings` - a little
// better, not merely as good (`steadyDropPoint`). And a fingertip rolls as it lifts, moving the touch in its last
// moment; so a finger's stone is played where the ghost was `finger_release_delay_seconds` before the lift, not where
// the lift itself would put it (`StoneHold`). A mouse's release does not move it, and plays where the ghost is.
//
// Everything here is a function of the game and of one frame's pointer, with nothing of the engine in it, so the
// tests at the end of the file play stones exactly as a person would.

/// Is there a pointer over the screen at all this frame? A mouse always is; a finger only while it touches - the
/// frame of its lifting included, so that a release is read where it happened.
pub fn pointerIsPresent(
    pointer_is_finger: bool,
    button_down: bool,
    button_released: bool,
) bool {
    if (!pointer_is_finger) {
        return true;
    }
    const finger_touches: bool = button_down or button_released;
    return finger_touches;
}

/// The position on the screen a pointer aims at (the section's lesson): the pointer itself for a mouse; for a finger,
/// `finger_lift_px` above it, the lift shrinking to the distance left to the window's bottom edge.
pub fn aimedPosition(
    pointer_px: Vec2,
    pointer_is_finger: bool,
    finger_lift_px: f32,
    window_height_px: f32,
) Vec2 {
    if (!pointer_is_finger) {
        return pointer_px;
    }
    const distance_to_bottom_px: f32 = @max(window_height_px - pointer_px[1], 0);
    const lift_px: f32 = @min(finger_lift_px, distance_to_bottom_px);
    const aimed_px: Vec2 = .{ pointer_px[0], pointer_px[1] - lift_px };
    return aimed_px;
}

/// What the pointer did over the board this frame.
pub const BoardPointer = struct {
    /// The point a stone would drop on - the ghost's point (`steadyDropPoint`): null off the board, over a window of
    /// the interface, between two touches of a finger, and where no point within reach is playable.
    hovered: ?Point,
    /// The button went down (or a finger touched) this frame.
    pressed: bool,
    /// The button came up (or the finger lifted) this frame.
    released: bool,
    /// How long before the release the stone's point is taken from: `finger_release_delay_seconds` for a finger, zero
    /// for a mouse (the section's lesson).
    release_delay_seconds: f32,
    /// How long this frame lasted.
    frame_seconds: f32,
};

/// May the player to move play on `point` now: is the move legal, and has the record room for it?
pub fn isPlayable(game: *const Game, point: Point) bool {
    const move_is_legal: bool = checkMove(&game.position, point) == .legal;
    const record_has_room: bool = !recordIsFull(&game.record);
    const playable: bool = move_is_legal and record_has_room;
    return playable;
}

/// The point a stone would drop on for a pointer at `aimed_px` (the section's lesson). A pointer just off the board -
/// within `reach_spacings` of it - is first brought onto the board's edge (`clampedOntoBoard`); a pointer farther off
/// drops nothing. Then: the intersection under it if a stone may be played there; otherwise the playable point nearest
/// it within `reach_spacings`; null when there is none. The points looked at are those of a square around the
/// intersection under it, wide enough to hold every point within reach; of two at the same distance, the first in
/// reading order is taken.
pub fn dropPoint(
    game: *const Game,
    layout: BoardLayout,
    aimed_px: Vec2,
    reach_spacings: f32,
) ?Point {
    const reach_px: f32 = reach_spacings * layout.spacing_px;
    const reach_squared_px: f32 = reach_px * reach_px;
    const on_board_px: Vec2 = layout.clampedOntoBoard(aimed_px, reach_px) orelse {
        return null;
    };
    const pointed: Point = layout.pointUnderPointer(on_board_px) orelse {
        return null;
    };
    if (isPlayable(game, pointed)) {
        return pointed;
    }
    // The pointer is within half a spacing of `pointed`, so every point within reach of it is within reach + 1/2
    // spacings of `pointed`, in rows and in columns.
    const lines_around: i32 = @ceil(reach_spacings + 0.5);
    const pointed_row: i32 = rowOf(layout.board_size, pointed);
    const pointed_col: i32 = colOf(layout.board_size, pointed);
    var nearest_point: ?Point = null;
    var nearest_distance_squared_px: f32 = reach_squared_px;
    var row: i32 = pointed_row - lines_around;
    while (row <= pointed_row + lines_around) : (row += 1) {
        var col: i32 = pointed_col - lines_around;
        while (col <= pointed_col + lines_around) : (col += 1) {
            if (!isOnBoard(layout.board_size, row, col)) {
                continue;
            }
            const candidate: Point = pointAt(layout.board_size, @intCast(row), @intCast(col));
            if (!isPlayable(game, candidate)) {
                continue;
            }
            const offset_px: Vec2 = layout.pointPosition(candidate) - on_board_px;
            const distance_squared_px: f32 = lengthSq2(offset_px);
            const within_reach: bool = distance_squared_px <= reach_squared_px;
            const nearer: bool = nearest_point == null or distance_squared_px < nearest_distance_squared_px;
            if (within_reach and nearer) {
                nearest_point = candidate;
                nearest_distance_squared_px = distance_squared_px;
            }
        }
    }
    return nearest_point;
}

/// The drop point, held steady (the section's lesson): `previous`, the ghost's point last frame, is kept while it is
/// still playable and within reach and no other point is nearer the pointer by `hysteresis_spacings`; otherwise the
/// drop point now (`dropPoint`).
pub fn steadyDropPoint(
    game: *const Game,
    layout: BoardLayout,
    aimed_px: Vec2,
    reach_spacings: f32,
    previous: ?Point,
    hysteresis_spacings: f32,
) ?Point {
    const best: Point = dropPoint(game, layout, aimed_px, reach_spacings) orelse {
        return null;
    };
    const kept: Point = previous orelse {
        return best;
    };
    if (kept == best or !isPlayable(game, kept)) {
        return best;
    }
    const reach_px: f32 = reach_spacings * layout.spacing_px;
    const on_board_px: Vec2 = layout.clampedOntoBoard(aimed_px, reach_px) orelse {
        return best;
    };
    const kept_distance_px: f32 = @sqrt(lengthSq2(layout.pointPosition(kept) - on_board_px));
    const best_distance_px: f32 = @sqrt(lengthSq2(layout.pointPosition(best) - on_board_px));
    const margin_px: f32 = hysteresis_spacings * layout.spacing_px;
    const kept_is_within_reach: bool = kept_distance_px <= reach_px;
    const best_is_clearly_nearer: bool = best_distance_px + margin_px < kept_distance_px;
    if (kept_is_within_reach and !best_is_clearly_nearer) {
        return kept;
    }
    return best;
}

/// A point the ghost showed, and when: how long after the press.
pub const ShownPoint = struct {
    seconds_held: f32,
    point: ?Point,
};

/// A stone picked up by a press, and where the ghost has shown it since: the last frames' points, each with how long
/// after the press it was shown, so that a release can play where the ghost was a moment before (the section's
/// lesson). The frames are kept in a ring, the oldest written over: 32 of them are more than 0.1 s at any frame rate
/// up to 240 per second.
pub const StoneHold = struct {
    is_held: bool,
    seconds_held: f32,
    shown: [shown_capacity]ShownPoint,
    shown_count: usize,
    next_slot: usize,

    const shown_capacity: usize = 32;

    /// No stone held.
    pub const empty: StoneHold = .{
        .is_held = false,
        .seconds_held = 0,
        .shown = undefined,
        .shown_count = 0,
        .next_slot = 0,
    };

    /// A stone picked up, shown on `point`.
    pub fn pickUp(hold: *StoneHold, point: Point) void {
        hold.* = .empty;
        hold.is_held = true;
        hold.remember(point);
    }

    /// One more frame of holding it, `frame_seconds` long, the ghost now on `point` - or nowhere.
    pub fn follow(hold: *StoneHold, frame_seconds: f32, point: ?Point) void {
        hold.seconds_held += frame_seconds;
        hold.remember(point);
    }

    /// Where the ghost showed the stone `seconds_ago` before now: the newest point shown at least that long ago, or -
    /// when the stone has been held a shorter time - the point it was picked up on.
    pub fn pointShownAgo(hold: *const StoneHold, seconds_ago: f32) ?Point {
        const wanted_seconds: f32 = hold.seconds_held - seconds_ago;
        var oldest: ?Point = null;
        for (0..hold.shown_count) |age| {
            const slot: usize = (hold.next_slot + shown_capacity - 1 - age) % shown_capacity;
            const sample: ShownPoint = hold.shown[slot];
            if (sample.seconds_held <= wanted_seconds) {
                return sample.point;
            }
            oldest = sample.point;
        }
        return oldest;
    }

    /// The stone put down, or put back.
    pub fn putDown(hold: *StoneHold) void {
        hold.* = .empty;
    }

    fn remember(hold: *StoneHold, point: ?Point) void {
        hold.shown[hold.next_slot] = .{ .seconds_held = hold.seconds_held, .point = point };
        hold.next_slot = (hold.next_slot + 1) % shown_capacity;
        hold.shown_count = @min(hold.shown_count + 1, shown_capacity);
    }
};

/// Whether a second finger has cancelled the gesture under way (the section's lesson): set the frame two fingers are
/// down, cleared once none is.
pub const FingerGesture = struct {
    cancelled: bool,

    /// No gesture cancelled: the board reads the pointer.
    pub const uncancelled: FingerGesture = .{ .cancelled = false };

    /// Whether the board ignores the pointer this frame, with `fingers_down` fingers on the screen. The frame the last
    /// finger lifts still belongs to the cancelled gesture - its release is ignored - and the next frame starts afresh.
    pub fn ignoresPointer(gesture: *FingerGesture, fingers_down: u32) bool {
        const second_finger_down: bool = fingers_down >= 2;
        if (second_finger_down) {
            gesture.cancelled = true;
        }
        const pointer_ignored: bool = gesture.cancelled;
        const every_finger_up: bool = fingers_down == 0;
        if (every_finger_up) {
            gesture.cancelled = false;
        }
        return pointer_ignored;
    }
};

/// One frame of the pointer on the board (the section's lesson): a press over a playable point picks the stone up;
/// while it is held, the ghost's points are remembered; a release plays it on the point the ghost showed
/// `release_delay_seconds` before, if that point is playable. A press and a release in the same frame - a quick tap -
/// do both. Returns the move's report when a stone was played.
pub fn applyPointer(game: *Game, hold: *StoneHold, pointer: BoardPointer) ?MoveReport {
    const picks_up: bool = pointer.pressed and pointer.hovered != null and isPlayable(game, pointer.hovered.?);
    if (picks_up) {
        hold.pickUp(pointer.hovered.?);
    } else if (hold.is_held) {
        hold.follow(pointer.frame_seconds, pointer.hovered);
    }
    const stone_is_let_go: bool = pointer.released and hold.is_held;
    if (!stone_is_let_go) {
        return null;
    }
    const release_point: ?Point = hold.pointShownAgo(pointer.release_delay_seconds);
    hold.putDown();
    const point: Point = release_point orelse {
        return null;
    };
    if (!isPlayable(game, point)) {
        return null;
    }
    const report: MoveReport = playMove(game, point);
    return report;
}

// ===== 11. The app =====
//
// The app's state is the game, the settings its next game starts with, how the board looks, the stone held and the
// ghost, the interface, and the pictures and font everything is drawn with.
//
// The app has two screens. The MAIN MENU chooses the next game - its board size, from 3 x 3 to 19 x 19 with three
// usual sizes a press away, and whether it is Atari Go and to how many captures - and starts it. The GAME screen is
// the board, with two buttons - Menu in the top-right corner, Undo in the bottom-left - and two windows: the pause
// window, which the Menu button and the Escape key open, and the victory window, which an Atari Go win opens. While
// either window is open the board below is dimmed and its two buttons are disabled, so nothing behind a window
// can be pressed by mistake. The mouse's side button takes back a move, as Undo does. The interface is zimr's port of
// Dear ImGui; its sizes are measured in its font size, which follows the window's width and height
// (`interfaceFontSize`), so the buttons stay finger-sized on a phone, do not grow past a comfortable size on a desktop,
// and the tallest window, measured as it is shown, still fits a phone held sideways. The pause, victory and main menu
// windows sit high: the room each leaves goes a third above it and two thirds below (`centredWindowTop`). A screen too
// short for a window even at the smallest font size holds it to its height, and the window scrolls
// (`openCentredWindow`).
//
// A won Atari Go game can go on as plain Go ("Continue Playing"): that changes the game being played, not the main
// menu's choice, so the next game started is Atari Go again.
//
// A stone placed makes a sound: a stone's click, or - when the move captures - the sound of stones taken. Each comes
// in five takes, and the one played is picked at random but never the take just played, so a run of moves does not
// click like a clock. The sounds are Ogg Vorbis files (`sounds/`, with where they come from), decoded whole when the
// app starts. Undo, redo and the timeline are silent: only a stone placed makes a sound. The pause window's "Sound"
// switch turns them off. A page may sound only after the person's first press, which it waits for anywhere on the
// page: in goban that press is always the main menu's, so by the first stone the sound is running, and goban needs
// no start screen of its own.
//
// A game frame runs in this order:
//
//       begin the frame and the interface; submit the windows     the interface now knows where its windows are
//       carry out what the buttons asked                          Undo, Menu, the pause window's choices
//       read the board's input, unless the interface has it       press, drag, release (section 10)
//       move the ghost; draw the wood, the board and the ghost
//       draw the interface on top; end the frame
//
// The windows are submitted before the board's input is read, because only then can the interface say whether the
// pointer is over one of them; the interface is drawn last, so it is never hidden under the board.
//
// THE COMPUTER'S TURN. The main menu offers three kinds of game - two players, a person against the computer, the
// computer against itself - and the computer plays Atari Go only, so a game with it is always Atari Go. On the
// computer's turn the board takes no stone and the caption says it is thinking, while its search (section 7) runs as
// a job, frame after frame, until the move's iterations are done:
//
//         its turn, no job running   ->  a job: the record and the last tree go to it
//         a job running              ->  polled; nothing yet
//         the job's tree landed      ->  kept, to go with the next job; if the move's iterations are all run, its
//                                        most visited move is played as a person's would be
//
// A move's search runs for a second of the monotonic clock, as many iterations as the machine runs in that time.
// Where there is a worker or a thread, the second is a run of jobs (`JobSearch`), each sized from the rate the last
// one ran at to take about a tenth of it, each taking up the tree the last returned; a job, in a kernel that imports
// nothing, has no clock of its own, so the program keeps the time. The frames go on while each job runs, and every
// move's tree goes with the next move's first job, so after the person's reply the search starts from the part of it
// the reply leads to. Where there is neither - a page shown inside another app, or one whose workers were made but
// never started, which the job system gives up after a few seconds - the search runs in the frames themselves
// (`FrameSearch`): each frame gives it 30 ms of iterations until the second is up, and its tree stays in
// the program as nodes, with nothing written to bytes; a move's take-up copies the subtree into a second buffer. A
// record that changes under a search - an undo, a pasted diagram, the debug panel's timeline - ends it, and the next
// frame starts again, with a second of its own, from what is there.
//
// UNDO takes back the last move between two players. Against the computer it goes back to just before the person's
// last move, so that the person is always the one to play after it: two moves when the computer has replied, one
// while it is still thinking, and none before the person's first move - the computer, playing black, has made the
// only one. Between two computers it is off; the pause window stops their game.

/// The sizes of the buttons and the pause window, in units of the interface's font size, and how the font size
/// follows the window. Kept in the state and passed to whatever lays the controls out.
pub const ControlsStyle = struct {
    /// About this many characters of text fit across the window, and this many lines down it: the font size is the
    /// smaller of the window's width and height divided by them, kept between 12 and 26 pixels (`interfaceFontSize`).
    /// The lines down grow past these to the tallest centred window as it is measured, with its margins - the main
    /// menu, against the computer with Atari Go's goal shown, is taller than 24 font sizes - so it fits a short
    /// window, a phone held sideways, too.
    characters_across: f32 = 20,
    characters_down: f32 = 24,
    /// The Menu button, the Undo button, and their distance from the window's edge.
    menu_button_size_fonts: Vec2 = .{ 4.0, 2.0 },
    undo_button_size_fonts: Vec2 = .{ 4.8, 2.0 },
    edge_gap_fonts: f32 = 0.4,
    /// One character's width in the interface's monospace font, in font sizes: what centring a line of it takes.
    label_glyph_fonts: f32 = 0.62,
    /// go puzzles hero's row of progress along the bottom (`heroProgressRow`): its places - a stone for each win
    /// since the level began, a ring for each still to come - their spacing at the most, in font sizes, and a ring's
    /// line.
    progress_places: u8 = 10,
    /// go puzzles hero's headlines - its level, and the line across the top: their size, in the interface's font
    /// sizes, and their boldness - the text drawn a second time this far to the right, in font sizes, which
    /// thickens its strokes (`fixedHeadline`).
    headline_scale: f32 = 1.25,
    headline_stroke_fonts: f32 = 0.06,
    progress_spacing_fonts: f32 = 1.6,
    progress_ring_px: f32 = 2,
    /// The pause and victory windows' width, the main menu's, and the height of each of their buttons.
    pause_window_width_fonts: f32 = 12.0,
    main_menu_width_fonts: f32 = 15.0,
    pause_button_height_fonts: f32 = 1.8,
    /// The board under an open window is drawn over with this, to show it is out of reach.
    window_dim_color: Color = .{ .r = 0, .g = 0, .b = 0, .a = 120 },
    /// How loud a stone's sounds play, 0 to 1.
    sound_volume: f32 = 0.8,
    /// How far above a finger the board reads its point (section 10), in logical pixels: on a phone, where a logical
    /// pixel is a CSS pixel of about 1/160 inch, 64 of them are about 10 mm - enough to clear a fingertip.
    finger_lift_px: f32 = 64,
    /// How far from the pointer a stone may go when the point under it is taken (section 10): one spacing, the size of
    /// a cell of the grid.
    drop_reach_spacings: f32 = 1.0,
    /// The ghost keeps its point until another is nearer the pointer by this much, in spacings (section 10).
    ghost_hysteresis_spacings: f32 = 0.15,
    /// A finger's stone is played where the ghost was this long before the finger lifted (section 10).
    finger_release_delay_seconds: f32 = 0.1,
};

/// What the pause window asks for this frame.
const PauseChoice = enum {
    /// Nothing was pressed.
    none,
    /// Close the window and go on playing.
    return_to_game,
    /// Start the game again with the same settings.
    restart,
    /// Leave the game for the main menu.
    return_to_main_menu,
    /// End the program: on the platforms whose program runs its own frames (`z.host.drives_own_frames`) - a page has
    /// nothing to quit to.
    quit_to_desktop,
};

/// What the victory window asks for this frame.
const VictoryChoice = enum {
    none,
    /// Go on with this game as plain Go (`continueAsPlainGo`).
    continue_playing,
    /// Start the game again with the same settings.
    restart,
    /// Leave the game for the main menu.
    main_menu,
};

/// What the main menu asks for this frame.
const MainMenuChoice = enum {
    none,
    /// Start a game with the menu's choices.
    start,
    /// End the program, where it runs its own frames.
    quit,
};

/// Which screen the app shows.
const Screen = enum {
    main_menu,
    game,
};

/// What the judge found after a move: the move's number, and the first place the forest and the flood fill disagree -
/// none when they agree.
const ForestCheck = struct {
    after_move: u16,
    disagreement: ?Disagreement,
};

/// The debug panel's state: whether it is open, whether the forest is checked by the judge (section 5) after every
/// move, and what the last check found.
const DebugPanel = struct {
    open: bool = false,
    verify_every_move: bool = false,
    /// The forest view's switches (section 9): the view itself, and the depths in it. The view stays on when the panel
    /// closes, so the board can be watched without the panel over it.
    forest_view: bool = false,
    forest_depths: bool = false,
    last_check: ?ForestCheck = null,
    /// The point the inspector shows: the one under the pointer in the frame before. The panel is submitted before
    /// the board reads the pointer - it must be, to keep the pointer from reaching the board through it - so this
    /// frame's point is not known yet.
    inspected_point: ?Point = null,
    /// What the last paste did, as the panel says it: the position it loaded, or why it was not a diagram.
    paste_note: [paste_note_capacity]u8 = undefined,
    paste_note_length: usize = 0,

    const paste_note_capacity: usize = 160;
    /// How many of the log's moves the panel shows: the last ones.
    const log_lines: usize = 8;

    /// The last paste's note, or nothing before the first.
    fn pasteNote(debug: *const DebugPanel) []const u8 {
        return debug.paste_note[0..debug.paste_note_length];
    }
};

/// What the debug panel asks for this frame: a move taken back or played again, the game restarted, the position moved
/// along the record to a move of the timeline, or copied and pasted as a diagram.
const DebugRequests = struct {
    undo: bool = false,
    redo: bool = false,
    restart: bool = false,
    jump_to_move: ?u16 = null,
    /// The position copied to the clipboard as a diagram, or the clipboard's text asked for, to load as one.
    copy_diagram: bool = false,
    paste_diagram: bool = false,
};

/// The main menu's choices, kept from one game to the next: the board's size, and whether the game is Atari Go and to
/// how many captures.
/// Who plays a game (the section's lesson): the main menu's first choice.
pub const GameKind = enum {
    two_players,
    against_computer,
    computer_against_computer,

    /// What the main menu calls each kind, in the kinds' order.
    const labels = [_][]const u8{ "Two players", "Against the computer", "Computer against computer" };

    /// Whether the computer plays a side - and so whether the game is Atari Go, the one game it plays.
    fn hasComputer(kind: GameKind) bool {
        return kind != .two_players;
    }
};

/// Who plays the game being played: its kind, and the person's colour when the computer plays the other.
pub const Players = struct {
    kind: GameKind,
    person_stone: Stone,

    /// Whether the computer is to play in `position`: never when the game is won, never between two players.
    fn computerToPlay(players: Players, position: *const Position) bool {
        if (position.winner != null) {
            return false;
        }
        switch (players.kind) {
            .two_players => return false,
            .against_computer => return position.player_to_move != players.person_stone,
            .computer_against_computer => return true,
        }
    }
};

const MenuChoices = struct {
    game_kind: GameKind = .two_players,
    /// Against the computer, the colour the person plays.
    person_stone: Stone = .black,
    board_size: u8 = 13,
    /// Whether Atari Go is chosen; with the computer playing, it is whatever this says.
    atari_go: bool = false,
    /// The capture goal, one of `capture_goals`; an `i32` because the radio buttons choosing it set one.
    capture_goal: i32 = 1,
    /// Atari Go: how many stones to scatter around the starting square, one of `ScatteredStones.counts`; an `i32`
    /// because the radio buttons choosing it set one.
    scattered_count: i32 = 0,

    /// The mode's name, as the main menu shows it.
    const scattered_mode_name = "Outposts";

    /// The board sizes a press away, and the capture goals offered.
    const usual_sizes = [_]u8{ 9, 13, 19 };
    const capture_goals = [_]i32{ 1, 3, 5 };

    /// Whether the game these choices start is Atari Go: chosen so, or played with the computer.
    fn isAtariGo(choices: MenuChoices) bool {
        return choices.atari_go or choices.game_kind.hasComputer();
    }

    /// The settings these choices start a game with.
    /// The settings these choices start a game with; the scattered stones' seed is the game's to set.
    fn settings(choices: MenuChoices) NewGameSettings {
        var capture_goal: ?u8 = null;
        var scattered: ScatteredStones = .{};
        if (choices.isAtariGo()) {
            capture_goal = @intCast(choices.capture_goal);
            scattered = .evenly(@intCast(choices.scattered_count));
        }
        const chosen: NewGameSettings = .{
            .board_size = choices.board_size,
            .capture_goal = capture_goal,
            .scattered = scattered,
        };
        return chosen;
    }

    /// Who plays the game these choices start.
    fn players(choices: MenuChoices) Players {
        const chosen: Players = .{ .kind = choices.game_kind, .person_stone = choices.person_stone };
        return chosen;
    }
};

/// How the computer plays (the section's lesson), kept in the state.
const ComputerSettings = struct {
    /// How long one move's search runs, in milliseconds of the monotonic clock: as many iterations as the machine runs
    /// in that time, so a faster machine plays stronger.
    move_milliseconds: f64 = 1000,
    /// The least time a move takes, in milliseconds of the monotonic clock: a move found sooner - a forced one, after
    /// a single iteration - is held until then (`ComputerPlayer.held_move`), so that the computer never answers the
    /// instant a stone is put down, which a player reads as not thinking at all.
    min_move_milliseconds: f64 = 500,
    /// On a worker, a move's search is a run of jobs (the section's lesson), each sized to take about this long from
    /// the rate the last one ran at, so that the move ends within about this much of its time; the first job,
    /// before any rate is known, runs `first_job_iterations`.
    job_milliseconds: f64 = 100,
    first_job_iterations: u32 = 500,
    /// Where the search runs in the frames (no worker, no thread), the time each frame gives it, and the most
    /// iterations a frame runs whatever the time - the bound that ends a frame whose clock stands still, as a headless
    /// run's does.
    frame_budget_milliseconds: f64 = 30,
    max_iterations_per_frame: u32 = 2_000,
    /// The most nodes a tree may have: a tree that reaches it stops growing (`SearchJobHeader.max_node_count` on a
    /// worker, the size of each of `FrameSearch`'s buffers in the frames), so that it fits `JobSearch.tree_bytes` and
    /// the registry's output bound.
    max_tree_nodes: u32 = 100_000,
    search: SearchSettings = .{},

    /// The bytes of the largest tree a job may return.
    fn maxTreeBytes(settings: ComputerSettings) usize {
        const max_bytes: usize = @sizeOf(SearchTreeHeader) + @as(usize, settings.max_tree_nodes) * @sizeOf(SearchNode);
        return max_bytes;
    }
};

/// The computer's search as jobs, on a worker or a thread (the section's lesson): the job in flight, the iterations
/// run for the move being searched, the rate the last job ran at, and the last tree, as bytes, which goes with the
/// next job.
const JobSearch = struct {
    job: jobs.Job,
    /// Whether `job` is in flight; its iterations, and when it was submitted, in milliseconds of the monotonic clock.
    searching: bool,
    iterations_in_flight: u32,
    submitted_ms: f64,
    /// The iterations of this move's search run so far, and of the last move's whole search.
    iterations_done: u32,
    last_move_iterations: u32,
    /// How often the last move's player won in its search, for whoever asks how the search judged it.
    last_move_win_rate: f32 = 0,
    /// Iterations a millisecond, as the last job that landed ran them, the time it took to send and return included;
    /// 0 before any has.
    iterations_per_millisecond: f64,
    /// The last tree the search returned, as `writeTree` wrote it: `tree_bytes[0..tree_length]`, empty before the
    /// first. Aligned for nodes, so its nodes are read where they are (`viewTree`).
    tree_bytes: []align(@alignOf(SearchNode)) u8,
    tree_length: usize,
    /// Where each job's payload is written: the record, then the last tree.
    payload_bytes: []u8,

    /// Where the jobs run, for the debug lines: a page's Web Worker, or natively a thread of the program's own.
    const place: []const u8 = if (z.host.is_browser) "a worker" else "a thread";

    /// A search with its buffers made for `settings`' largest tree, no job in flight and no tree yet.
    fn init(gpa: Allocator, settings: ComputerSettings) Allocator.Error!JobSearch {
        const tree_capacity: usize = settings.maxTreeBytes();
        // The record's part of a payload: its fixed part, its setup stones and its moves, at their most.
        const record_capacity: usize = @sizeOf(RecordBytes) + board_limits.max_points * @sizeOf(SetupStoneBytes) +
            record_limits.max_moves * @sizeOf(Point);
        assertf(tree_capacity <= search_job_registry.max_output, @src(), "JobSearch: a tree of {d} bytes would " ++
            "not fit the job's output bound of {d}", .{ tree_capacity, search_job_registry.max_output });
        const tree_bytes: []align(@alignOf(SearchNode)) u8 = try gpa.alignedAlloc(u8, .of(SearchNode), tree_capacity);
        errdefer gpa.free(tree_bytes);
        const payload_bytes: []u8 = try gpa.alloc(u8, record_capacity + tree_capacity);
        const search: JobSearch = .{
            .job = .{},
            .searching = false,
            .iterations_in_flight = 0,
            .submitted_ms = 0,
            .iterations_done = 0,
            .last_move_iterations = 0,
            .iterations_per_millisecond = 0,
            .tree_bytes = tree_bytes,
            .tree_length = 0,
            .payload_bytes = payload_bytes,
        };
        return search;
    }

    fn deinit(search: *JobSearch, gpa: Allocator) void {
        search.job.deinit();
        gpa.free(search.tree_bytes);
        gpa.free(search.payload_bytes);
    }

    /// Ends the search under way - the job in flight given up, the move's iterations forgotten - keeping the last
    /// tree, which the next job takes up where it still fits.
    fn stop(search: *JobSearch) void {
        search.job.deinit();
        search.searching = false;
        search.iterations_in_flight = 0;
        search.iterations_done = 0;
    }

    /// For a new game: the search stopped and the last tree forgotten.
    fn forget(search: *JobSearch) void {
        search.stop();
        search.tree_length = 0;
    }

    /// The iterations of the next job: as many as the last job's rate runs in `settings.job_milliseconds`, or in what
    /// is left of the move's time if that is less; `settings.first_job_iterations` before any rate is known.
    fn nextJobIterations(
        search: *const JobSearch,
        settings: ComputerSettings,
        milliseconds_left: f64,
    ) u32 {
        const rate_is_known: bool = search.iterations_per_millisecond > 0;
        if (!rate_is_known) {
            return settings.first_job_iterations;
        }
        const job_milliseconds: f64 = clamp(milliseconds_left, 1, settings.job_milliseconds);
        const fitting_iterations: f64 = search.iterations_per_millisecond * job_milliseconds;
        const iteration_count: u32 = @trunc(clamp(fitting_iterations, 1, float(settings.max_tree_nodes)));
        return iteration_count;
    }

    /// Submits the next job, from `record`'s position with the last tree. A submission that fails is logged and tried
    /// again next frame.
    fn submit(
        search: *JobSearch,
        gpa: Allocator,
        record: *const Record,
        settings: ComputerSettings,
        seed: u64,
        iteration_count: u32,
        now_ms: f64,
    ) void {
        const last_tree_bytes: []const u8 = search.tree_bytes[0..search.tree_length];
        var payload: Io.Writer = .fixed(search.payload_bytes);
        writeSearchPayload(record, last_tree_bytes, &payload) catch {
            panicf(@src(), "a search payload fits `payload_bytes`, sized for the largest record and tree", .{});
        };
        const header: SearchJobHeader = .{
            .settings = settings.search,
            .iteration_count = iteration_count,
            .max_node_count = settings.max_tree_nodes,
            .seed = seed,
        };
        search.job = search_job_registry.submit(gpa, searchJob, header, payload.buffered()) catch |err| {
            std.log.err("goban: the computer's search could not be submitted: {t}", .{err});
            return;
        };
        search.searching = true;
        search.iterations_in_flight = iteration_count;
        search.submitted_ms = now_ms;
    }

    /// One frame of the search for the computer's move in `record`'s position, its time up at `deadline_ms` (the
    /// section's lesson): the job in flight polled; when its tree lands, the next job submitted with it while there
    /// is time left, and the move, the root's most visited, once there is none. Null on every other frame.
    fn step(
        search: *JobSearch,
        gpa: Allocator,
        record: *const Record,
        position: *const Position,
        settings: ComputerSettings,
        seed: u64,
        deadline_ms: f64,
        now_ms: f64,
    ) ?Point {
        var move_is_forced: bool = false;
        if (search.searching) {
            const landed: ?[]const u8 = search.job.pollInto(search.tree_bytes) catch |err| {
                std.log.err("goban: the computer's search failed: {t} {s}", .{ err, search.job.errorName() });
                search.stop();
                search.tree_length = 0;
                return null;
            };
            const tree_landed: []const u8 = landed orelse {
                return null;
            };
            search.tree_length = tree_landed.len;
            search.job.deinit();
            search.searching = false;
            const job_milliseconds: f64 = now_ms - search.submitted_ms;
            if (job_milliseconds > 0) {
                search.iterations_per_millisecond = float(search.iterations_in_flight) / job_milliseconds;
            }
            search.iterations_done += search.iterations_in_flight;
            search.iterations_in_flight = 0;
            const landed_tree: SearchTree = viewTree(search.tree_bytes[0..search.tree_length]) orelse {
                panicf(@src(), "a search job returns a tree", .{});
            };
            move_is_forced = searchIsSettled(&landed_tree);
        }
        const milliseconds_left: f64 = deadline_ms - now_ms;
        const time_is_up: bool = (milliseconds_left <= 0 or move_is_forced) and search.iterations_done > 0;
        if (time_is_up) {
            search.last_move_iterations = search.iterations_done;
            search.iterations_done = 0;
            const tree: SearchTree = viewTree(search.tree_bytes[0..search.tree_length]) orelse {
                panicf(@src(), "a search job returns a tree", .{});
            };
            const chosen: ?Point = chosenMove(&tree, settings.search);
            search.last_move_win_rate = if (chosen) |move| rootChildWinRate(&tree, move) else 0;
            return playedMove(&tree, position, settings.search);
        }
        const iteration_count: u32 = search.nextJobIterations(settings, milliseconds_left);
        search.submit(gpa, record, settings, seed, iteration_count, now_ms);
        return null;
    }
};

/// The computer's search where no job can run on a worker or a thread - a page shown inside another app (the
/// section's lesson): it runs in the frames themselves, and its tree stays here as nodes, with nothing written to
/// bytes and read back. The nodes are in one of two buffers; the other is free for the subtree a move's take-up
/// copies out. With them, the root's position, a scratch position for the iterations, and a game to replay the record
/// into when the tree is brought to a new position.
const FrameSearch = struct {
    node_buffers: [2][]SearchNode,
    tree: ?SearchTree,
    /// The iterations of this move's search run so far, and of the last move's whole search.
    iterations_done: u32,
    last_move_iterations: u32,
    /// How often the last move's player won in its search, for whoever asks how the search judged it.
    last_move_win_rate: f32 = 0,
    root_position: *Position,
    scratch: *Position,
    /// The ladder reading's positions (`SearchSettings.ladder_reading`): none when the search reads no ladders.
    ladder_pool: []Position,
    replay_game: *Game,

    /// A search with two buffers of `settings.max_tree_nodes` nodes, and no tree yet.
    fn init(gpa: Allocator, settings: ComputerSettings) Allocator.Error!FrameSearch {
        const first_buffer: []SearchNode = try gpa.alloc(SearchNode, settings.max_tree_nodes);
        errdefer gpa.free(first_buffer);
        const second_buffer: []SearchNode = try gpa.alloc(SearchNode, settings.max_tree_nodes);
        errdefer gpa.free(second_buffer);
        const root_position: *Position = try gpa.create(Position);
        errdefer gpa.destroy(root_position);
        const scratch: *Position = try gpa.create(Position);
        errdefer gpa.destroy(scratch);
        const ladder_depth: usize = if (settings.search.ladder_reading) settings.search.ladder_depth else 0;
        const ladder_pool: []Position = try gpa.alloc(Position, ladder_depth);
        errdefer gpa.free(ladder_pool);
        const replay_game: *Game = try gpa.create(Game);
        const search: FrameSearch = .{
            .node_buffers = .{ first_buffer, second_buffer },
            .tree = null,
            .iterations_done = 0,
            .last_move_iterations = 0,
            .root_position = root_position,
            .scratch = scratch,
            .ladder_pool = ladder_pool,
            .replay_game = replay_game,
        };
        return search;
    }

    fn deinit(search: *FrameSearch, gpa: Allocator) void {
        gpa.free(search.node_buffers[0]);
        gpa.free(search.node_buffers[1]);
        gpa.destroy(search.root_position);
        gpa.destroy(search.scratch);
        gpa.free(search.ladder_pool);
        gpa.destroy(search.replay_game);
    }

    /// Ends the search under way: the move's iterations forgotten. The tree stays, with the visits it was given.
    fn stop(search: *FrameSearch) void {
        search.iterations_done = 0;
    }

    /// For a new game: the search stopped and the tree forgotten.
    fn forget(search: *FrameSearch) void {
        search.stop();
        search.tree = null;
    }

    /// The buffer not holding the tree's nodes: where a take-up copies its subtree, or a fresh tree goes.
    fn freeBuffer(search: *const FrameSearch) []SearchNode {
        const tree: SearchTree = search.tree orelse {
            return search.node_buffers[0];
        };
        const tree_is_in_first: bool = tree.nodes.ptr == search.node_buffers[0].ptr;
        if (tree_is_in_first) {
            return search.node_buffers[1];
        }
        return search.node_buffers[0];
    }

    /// Brings the tree to `position`, the record's position now, unless it is there: the last tree's subtree taken up
    /// where it fits (`takeUpLastTree`), a fresh tree seeded with `seed` where it does not.
    fn bringTreeTo(
        search: *FrameSearch,
        gpa: Allocator,
        record: *const Record,
        position: *const Position,
        seed: u64,
    ) Allocator.Error!void {
        const fingerprint: u64 = positionFingerprint(position);
        if (search.tree) |tree| {
            const tree_is_here: bool = tree.header.root_moves_played == record.moves_played and
                tree.header.root_fingerprint == fingerprint;
            if (tree_is_here) {
                return;
            }
        }
        search.replay_game.* = .{ .position = undefined, .record = record.* };
        const free_buffer: []SearchNode = search.freeBuffer();
        const taken_up: ?SearchTree = try takeUpLastTree(gpa, search.replay_game, search.tree, free_buffer);
        search.root_position.* = position.*;
        search.tree = taken_up orelse SearchTree.init(free_buffer, search.root_position, record.moves_played, seed);
    }

    /// One frame of the search for the computer's move in `position`, `record`'s position now, its time up at
    /// `deadline_ms` on `clock` (the section's lesson): the tree brought to it, then iterations until the move's time
    /// is up, `settings.frame_budget_milliseconds` have passed, or `settings.max_iterations_per_frame` have run this
    /// frame - and once the move's time is up, the move it chooses, the root's most visited. Null on every other
    /// frame.
    fn step(
        search: *FrameSearch,
        gpa: Allocator,
        record: *const Record,
        position: *const Position,
        settings: ComputerSettings,
        seed: u64,
        deadline_ms: f64,
        clock: *const fn () f64,
    ) Allocator.Error!?Point {
        try search.bringTreeTo(gpa, record, position, seed);
        const tree: *SearchTree = &search.tree.?;
        const started_ms: f64 = clock();
        var iterations_this_frame: u32 = 0;
        while (true) {
            const now_ms: f64 = clock();
            const search_is_over: bool = now_ms >= deadline_ms or searchIsSettled(tree);
            const time_is_up: bool = search_is_over and search.iterations_done > 0;
            if (time_is_up) {
                search.last_move_iterations = search.iterations_done;
                search.iterations_done = 0;
                const chosen: ?Point = chosenMove(tree, settings.search);
                search.last_move_win_rate = if (chosen) |move| rootChildWinRate(tree, move) else 0;
                return playedMove(tree, position, settings.search);
            }
            const frame_has_run_its_most: bool = iterations_this_frame >= settings.max_iterations_per_frame;
            const budget_spent: bool = now_ms - started_ms >= settings.frame_budget_milliseconds;
            if (frame_has_run_its_most or budget_spent) {
                return null;
            }
            runIteration(tree, search.root_position, settings.search, search.scratch, search.ladder_pool);
            search.iterations_done += 1;
            iterations_this_frame += 1;
        }
    }
};

/// The computer (the section's lesson): its search - as jobs where they run on a worker or a thread, in the frames
/// where they cannot - the game's seed, the move's time, and what the last move took.
const ComputerPlayer = struct {
    /// The allocator its search needs as it goes - a job's submission, a take-up's table: the frame function is given
    /// none, so the player keeps the one the program's start was given.
    gpa: Allocator,
    search: union(enum) {
        jobs: JobSearch,
        frames: FrameSearch,
    },
    /// The game's seed: a fresh tree is seeded with it plus the moves played.
    game_seed: u64,
    /// When this move's search began, in milliseconds of the monotonic clock, if it has; and the record's moves
    /// played and its position's fingerprint then - a record that changes under the search, an undo, a pasted
    /// diagram, the timeline, starts it again.
    move_started_ms: ?f64,
    searched_moves_played: u16,
    searched_fingerprint: u64,
    /// The move found before the least time a move takes (`ComputerSettings.min_move_milliseconds`), held until
    /// then; null when there is none.
    held_move: ?Point,
    /// The last move's time, for the debug panel.
    last_move_seconds: f32,

    /// How often its last searched move's player - the computer - won in the search.
    fn lastMoveWinRate(player: *const ComputerPlayer) f32 {
        switch (player.search) {
            .jobs => |*job_search| return job_search.last_move_win_rate,
            .frames => |*frame_search| return frame_search.last_move_win_rate,
        }
    }

    /// A player searching as jobs when they run in parallel, in the frames when they do not.
    fn init(gpa: Allocator, settings: ComputerSettings) Allocator.Error!ComputerPlayer {
        var player: ComputerPlayer = .{
            .gpa = gpa,
            .search = undefined,
            .game_seed = 0,
            .move_started_ms = null,
            .held_move = null,
            .searched_moves_played = 0,
            .searched_fingerprint = 0,
            .last_move_seconds = 0,
        };
        if (jobs.parallel()) {
            player.search = .{ .jobs = try JobSearch.init(gpa, settings) };
        } else {
            player.search = .{ .frames = try FrameSearch.init(gpa, settings) };
        }
        return player;
    }

    fn deinit(player: *ComputerPlayer) void {
        switch (player.search) {
            .jobs => |*search| search.deinit(player.gpa),
            .frames => |*search| search.deinit(player.gpa),
        }
    }

    /// Ends the search under way, if there is one, keeping the last tree, which the next search takes up where it
    /// still fits.
    fn stopSearch(player: *ComputerPlayer) void {
        player.move_started_ms = null;
        player.held_move = null;
        switch (player.search) {
            .jobs => |*search| search.stop(),
            .frames => |*search| search.stop(),
        }
    }

    /// For a new game: the search stopped, the last tree forgotten, and the game's seed set.
    fn startGame(player: *ComputerPlayer, game_seed: u64) void {
        player.stopSearch();
        player.game_seed = game_seed;
        switch (player.search) {
            .jobs => |*search| search.forget(),
            .frames => |*search| search.forget(),
        }
    }

    /// The iterations the search under way has run for its move, and those of the last move's whole search.
    fn iterationsDone(player: *const ComputerPlayer) u32 {
        switch (player.search) {
            .jobs => |search| return search.iterations_done,
            .frames => |search| return search.iterations_done,
        }
    }

    fn lastMoveIterations(player: *const ComputerPlayer) u32 {
        switch (player.search) {
            .jobs => |search| return search.last_move_iterations,
            .frames => |search| return search.last_move_iterations,
        }
    }

    /// Turns from jobs to the frames: for a page whose workers were made but never started - the job system then
    /// gives them up, and says so through `jobs.parallel()`. The move under way goes on in the frames, from a fresh
    /// tree.
    fn searchInTheFrames(player: *ComputerPlayer, settings: ComputerSettings) Allocator.Error!void {
        const frame_search: FrameSearch = try .init(player.gpa, settings);
        switch (player.search) {
            .jobs => |*search| search.deinit(player.gpa),
            .frames => |*search| search.deinit(player.gpa),
        }
        player.search = .{ .frames = frame_search };
        // Debug, which a release page does not log: the frames are the designed path where a host lets no worker
        // start, and an info line shows on the page's log overlay, over the board.
        std.log.debug("goban: no worker runs jobs here; the computer searches in the frames", .{});
    }

    /// One frame of the computer's turn in `game`, whichever way it searches, its time read on `clock`: the move, once
    /// its time is up; null on every other frame.
    fn step(
        player: *ComputerPlayer,
        game: *const Game,
        settings: ComputerSettings,
        clock: *const fn () f64,
    ) ?Point {
        const workers_lost: bool = player.search == .jobs and !jobs.parallel();
        if (workers_lost) {
            player.searchInTheFrames(settings) catch {
                std.log.err("goban: no memory for the computer's search", .{});
                return null;
            };
        }
        const record: *const Record = &game.record;
        const position: *const Position = &game.position;
        const fingerprint: u64 = positionFingerprint(position);
        if (player.move_started_ms != null) {
            const record_changed: bool = record.moves_played != player.searched_moves_played or
                fingerprint != player.searched_fingerprint;
            if (record_changed) {
                player.stopSearch();
            }
        }
        const now_ms: f64 = clock();
        if (player.move_started_ms == null) {
            player.move_started_ms = now_ms;
            player.searched_moves_played = record.moves_played;
            player.searched_fingerprint = fingerprint;
        }
        const started_ms: f64 = player.move_started_ms.?;
        const earliest_ms: f64 = started_ms + settings.min_move_milliseconds;
        // A move already found waits out the least time a move takes.
        if (player.held_move) |held| {
            if (now_ms < earliest_ms) {
                return null;
            }
            player.finishMove(started_ms, now_ms);
            return held;
        }
        const deadline_ms: f64 = started_ms + settings.move_milliseconds;
        const seed: u64 = player.game_seed +% record.moves_played;
        var move: ?Point = null;
        switch (player.search) {
            .jobs => |*search| {
                move = search.step(player.gpa, record, position, settings, seed, deadline_ms, now_ms);
            },
            .frames => |*search| {
                move = search.step(player.gpa, record, position, settings, seed, deadline_ms, clock) catch {
                    std.log.err("goban: no memory for the computer's search", .{});
                    return null;
                };
            },
        }
        const found: Point = move orelse {
            return null;
        };
        const found_ms: f64 = clock();
        if (found_ms < earliest_ms) {
            player.held_move = found;
            return null;
        }
        player.finishMove(started_ms, found_ms);
        return found;
    }

    /// The end of a move's turn, begun at `started_ms` and over at `finished_ms`: how long it took kept, the search's
    /// start and any held move let go.
    fn finishMove(
        player: *ComputerPlayer,
        started_ms: f64,
        finished_ms: f64,
    ) void {
        player.last_move_seconds = @floatCast((finished_ms - started_ms) / 1000);
        player.move_started_ms = null;
        player.held_move = null;
    }
};

/// A stone's click, and stones taken - five takes of each (`sounds/SOURCE.md` says where they come from).
const move_oggs = [_][]const u8{
    @embedFile("sounds/move-0.ogg"),
    @embedFile("sounds/move-1.ogg"),
    @embedFile("sounds/move-2.ogg"),
    @embedFile("sounds/move-3.ogg"),
    @embedFile("sounds/move-4.ogg"),
};
const capture_oggs = [_][]const u8{
    @embedFile("sounds/capture0.ogg"),
    @embedFile("sounds/capture1.ogg"),
    @embedFile("sounds/capture2.ogg"),
    @embedFile("sounds/capture3.ogg"),
    @embedFile("sounds/capture4.ogg"),
};

/// Which of `take_count` takes to play next, from a random `roll`: any of them the first time, and after that any but
/// the `previous` one - each of the others equally likely.
pub fn nextTake(previous: ?u8, roll: u64, take_count: u8) u8 {
    assertf(take_count >= 2, @src(), "nextTake: {d} takes leave no other to pick", .{take_count});
    const first: u8 = previous orelse {
        return @intCast(roll % take_count);
    };
    const others: u8 = take_count - 1;
    const among_others: u8 = @intCast(roll % others);
    if (among_others >= first) {
        return among_others + 1;
    }
    return among_others;
}

/// The sounds a stone makes (the section's lesson): the takes of a click and of a capture, the audio tables they are
/// loaded in, and which take each played last.
const StoneSounds = struct {
    audio: z.AudioState,
    clicks: [move_oggs.len]z.Sound,
    captures: [capture_oggs.len]z.Sound,
    last_click: ?u8,
    last_capture: ?u8,
    random: Random.DefaultPrng,
    /// The variant's reward sound (`AppVariant.reward_sound`), when it has one: the app's other sound, on the same
    /// audio state as the stones'.
    reward: ?z.Sound,

    /// Every take decoded (Ogg Vorbis, `z.sounds.loadFromMemory`) onto the audio device, at `volume`; and the reward's
    /// sound, `reward_ogg`, when there is one.
    fn load(
        gpa: Allocator,
        f: *z.Frame,
        volume: f32,
        reward_ogg: ?[]const u8,
    ) !StoneSounds {
        var stone_sounds: StoneSounds = .{
            .audio = .{},
            .clicks = undefined,
            .captures = undefined,
            .last_click = null,
            .last_capture = null,
            .random = Random.DefaultPrng.init(@trunc(z.epochMillis())),
            .reward = null,
        };
        const audio: *z.AudioState = &stone_sounds.audio;
        for (move_oggs, &stone_sounds.clicks) |ogg, *click| {
            click.* = try z.sounds.loadFromMemory(&audio.sounds, f.audio_device, &audio.waves, gpa, ".ogg", ogg);
            z.sounds.setVolume(&audio.sounds, click.*, volume);
        }
        for (capture_oggs, &stone_sounds.captures) |ogg, *capture| {
            capture.* = try z.sounds.loadFromMemory(&audio.sounds, f.audio_device, &audio.waves, gpa, ".ogg", ogg);
            z.sounds.setVolume(&audio.sounds, capture.*, volume);
        }
        if (reward_ogg) |ogg| {
            const reward: z.Sound = try z.sounds.loadFromMemory(
                &audio.sounds,
                f.audio_device,
                &audio.waves,
                gpa,
                ".ogg",
                ogg,
            );
            z.sounds.setVolume(&audio.sounds, reward, volume);
            stone_sounds.reward = reward;
        }
        return stone_sounds;
    }

    /// The reward's sound, when there is one.
    fn playReward(stone_sounds: *StoneSounds) void {
        const reward: z.Sound = stone_sounds.reward orelse return;
        z.sounds.play(&stone_sounds.audio.sounds, reward);
    }

    fn unload(stone_sounds: *StoneSounds) void {
        for (stone_sounds.clicks) |click| {
            z.sounds.unload(&stone_sounds.audio.sounds, click);
        }
        for (stone_sounds.captures) |capture| {
            z.sounds.unload(&stone_sounds.audio.sounds, capture);
        }
        if (stone_sounds.reward) |reward| {
            z.sounds.unload(&stone_sounds.audio.sounds, reward);
        }
    }

    /// The sound of the move just played: a take of the capture's when it took stones, of the click's otherwise.
    fn playFor(stone_sounds: *StoneSounds, report: MoveReport) void {
        const roll: u64 = stone_sounds.random.next();
        const took_stones: bool = report.captured_count > 0;
        if (took_stones) {
            const take: u8 = nextTake(stone_sounds.last_capture, roll, capture_oggs.len);
            stone_sounds.last_capture = take;
            z.sounds.play(&stone_sounds.audio.sounds, stone_sounds.captures[take]);
            return;
        }
        const take: u8 = nextTake(stone_sounds.last_click, roll, move_oggs.len);
        stone_sounds.last_click = take;
        z.sounds.play(&stone_sounds.audio.sounds, stone_sounds.clicks[take]);
    }
};

/// The centred windows' heights, in the interface's font sizes: each window's as its content needed it the last frame
/// it was shown - zero before its first - which places it the next (`openCentredWindow`), and the tallest any of them
/// has needed, which the font size is fitted to (`interfaceFontSize`). The interface's sizes are multiples of the font
/// size - the style's (`scaleToViewport`), the windows' widths, the buttons - but for a few pixels, a separator's line
/// and a checkbox's or a radio button's 4 past the font size, so a window's height in font sizes stays nearly the same
/// when the font size follows the window's size: a few pixels' worth more at a smaller font size.
const CentredWindowHeights = struct {
    main_menu: f32 = 0,
    pause: f32 = 0,
    victory: f32 = 0,
    paywall: f32 = 0,
    tallest: f32 = 0,
};

/// A window go puzzles hero opens once a session's first games are played (`AppVariant.paywall`): a message, a link
/// opened in a new tab, and a password box. Until the password is typed the game waits behind it; typed, the window
/// closes, and the game goes on - for good: the password typed is kept with the player's progress (`HeroProgress`).
/// The session's count of games starts again with every start.
pub const Paywall = struct {
    /// The games a session plays before the window opens: every fight and every puzzle that ends, whatever its end -
    /// won or lost, solved or failed.
    free_games: u32 = 10,
    message: []const u8 = "Buy me a coffee to continue",
    link_label: []const u8 = "Buy me a coffee",
    url: []const u8 = "https://example.com",
    password: []const u8 = "1234",
};

/// go puzzles hero's reward for a new level (`AppVariant.reward_images`): when a win fills the row of progress's last
/// place, the game waits `delay_seconds` - the full row seen - then shows one of the pictures, drawn at random, with
/// the reward's sound: it comes down from above the window to its centre in `enter_seconds`, stays `hold_seconds`,
/// and goes on down and out in `exit_seconds`, a backdrop darkening and clearing with it. The row empties and the
/// level rises when it is gone.
pub const RewardSettings = struct {
    delay_seconds: f32 = 0.5,
    enter_seconds: f32 = 0.5,
    hold_seconds: f32 = 2,
    exit_seconds: f32 = 0.5,

    /// How long the picture shows, from its coming in to its going out.
    fn showSeconds(settings: RewardSettings) f32 {
        return settings.enter_seconds + settings.hold_seconds + settings.exit_seconds;
    }
};

/// Where a reward stands, by the seconds since the row's last place was filled (`rewardPhase`).
pub const RewardPhase = enum {
    /// The full row seen, the picture not yet shown.
    waiting,
    showing,
    /// Over: the picture gone, the level risen.
    over,
};

/// The phase of a reward `elapsed_seconds` after the row's last place was filled (`RewardSettings`).
pub fn rewardPhase(elapsed_seconds: f32, settings: RewardSettings) RewardPhase {
    if (elapsed_seconds < settings.delay_seconds) {
        return .waiting;
    }
    const show_end_seconds: f32 = settings.delay_seconds + settings.showSeconds();
    return if (elapsed_seconds < show_end_seconds) .showing else .over;
}

/// Where the reward's picture is `show_seconds` after it began to show (`RewardSettings`), as a share of the
/// window's height below the centre: from -1, just above the window, to 0 while it comes in - fast at first, slowing
/// into place (ease out, the cube of what is left) - 0 while it stays, and from 0 to 1, out at the bottom, while it
/// goes - slow at first, gathering speed (ease in, the cube of the share gone).
pub fn rewardOffset(show_seconds: f32, settings: RewardSettings) f32 {
    if (show_seconds < settings.enter_seconds) {
        const left: f32 = 1 - show_seconds / settings.enter_seconds;
        return -(left * left * left);
    }
    const exit_start_seconds: f32 = settings.enter_seconds + settings.hold_seconds;
    if (show_seconds < exit_start_seconds) {
        return 0;
    }
    const gone: f32 = clamp01((show_seconds - exit_start_seconds) / settings.exit_seconds);
    return gone * gone * gone;
}

/// How dark the reward's backdrop is `show_seconds` after the picture began to show (`RewardSettings`): darkening
/// from clear to black as it comes in, black while it stays, clearing as it goes.
pub fn rewardBackdropAlpha(show_seconds: f32, settings: RewardSettings) f32 {
    if (show_seconds < settings.enter_seconds) {
        return clamp01(show_seconds / settings.enter_seconds);
    }
    const exit_start_seconds: f32 = settings.enter_seconds + settings.hold_seconds;
    if (show_seconds < exit_start_seconds) {
        return 1;
    }
    return 1 - clamp01((show_seconds - exit_start_seconds) / settings.exit_seconds);
}

/// A ladder of games that follows the results (`AppVariant.outpost_ladder`; the section's lesson): each rung a split of
/// scattered stones between the person and the computer, and each rung played twice - the person moving first, then
/// moving second. Its positions, from the easiest:
///
///     rung   person's  computer's   moving first, then second
///     0      2         0            positions 0, 1
///     1      2         1            2, 3
///     2      2         2            4, 5
///     3      1         2            6, 7
///     4      1         3            8, 9
///     5      1         4            10, 11
///     6      0         4            12, 13
///     7      0         5            14, 15
///     ...    0         one more each rung, as long as they fit the board
///
/// A win moves the person one position up, a loss one down, within the ladder: so a rung is climbed only by winning
/// it moving second, without the first move's advantage, and a loss moving second first gives the move back. The
/// rungs go up in threes: the computer given a stone, then another, then one of the person's taken - until the person
/// has none; from there each rung gives the computer one more, up to the most the board holds. The level the person
/// is at is the position counted from 1: level 1 at the bottom, which a loss does not go under.
pub const OutpostLadder = struct {
    /// The person's stones on the first rung.
    person_start: u8,

    /// The rung of `position`, two positions to a rung.
    fn rungOf(position: u8) u8 {
        return position / 2;
    }

    /// The person's and the computer's stones on `rung`, the rungs in threes: in the third `cycle`, the person has
    /// `person_start - cycle` and the computer `2 * cycle`, and the cycle's three rungs give the computer none, one and
    /// two more. Past the person's last stone, each rung gives the computer one more.
    fn rungSplit(ladder: OutpostLadder, rung: u8) [2]u8 {
        const rungs_per_cycle: u8 = 3;
        const cycle_rungs: u8 = rungs_per_cycle * ladder.person_start;
        if (rung <= cycle_rungs) {
            const cycle: u8 = rung / rungs_per_cycle;
            const step_in_cycle: u8 = rung % rungs_per_cycle;
            const person_count: u8 = ladder.person_start - cycle;
            const computer_count: u8 = 2 * cycle + step_in_cycle;
            return .{ person_count, computer_count };
        }
        const computer_count: u8 = 2 * ladder.person_start + (rung - cycle_rungs);
        return .{ 0, computer_count };
    }

    /// How many positions the ladder has on a board this size: two for each rung whose stones fit it.
    pub fn positionCount(ladder: OutpostLadder, board_size: u8) u8 {
        var top_rung: u8 = 0;
        while (true) {
            const split: [2]u8 = ladder.rungSplit(top_rung + 1);
            const next_rung_stones: ScatteredStones = .{ .black_count = split[0], .white_count = split[1] };
            if (!scatteredStonesFit(board_size, next_rung_stones)) {
                break;
            }
            top_rung += 1;
        }
        return 2 * (top_rung + 1);
    }

    /// The scattered stones of the game at `position`, the person playing `person_stone`: the rung's split.
    pub fn stonesAt(
        ladder: OutpostLadder,
        position: u8,
        person_stone: Stone,
    ) ScatteredStones {
        const split: [2]u8 = ladder.rungSplit(rungOf(position));
        const person_count: u8 = split[0];
        const computer_count: u8 = split[1];
        var stones: ScatteredStones = .{};
        if (person_stone == .black) {
            stones.black_count = person_count;
            stones.white_count = computer_count;
        } else {
            stones.black_count = computer_count;
            stones.white_count = person_count;
        }
        return stones;
    }

    /// Who moves first in the game at `position`: the person on a rung's first game, the computer on its second.
    pub fn firstPlayerAt(
        ladder: OutpostLadder,
        position: u8,
        person_stone: Stone,
    ) Stone {
        _ = ladder;
        const person_moves_first: bool = position % 2 == 0;
        return if (person_moves_first) person_stone else person_stone.opponent();
    }

    /// The position after a game at `position` on a board this size that `winner` won: one up after the person's win,
    /// one down after the computer's, within the ladder; the same after a game that ended undecided.
    pub fn nextPosition(
        ladder: OutpostLadder,
        board_size: u8,
        position: u8,
        winner: Stone,
        person_stone: Stone,
    ) u8 {
        if (winner == .none) {
            return position;
        }
        const person_won: bool = winner == person_stone;
        if (person_won) {
            return @min(position + 1, ladder.positionCount(board_size) - 1);
        }
        return position -| 1;
    }

    /// The settings of the game at `position`: `base` with the rung's stones and its first player.
    pub fn settingsAt(
        ladder: OutpostLadder,
        base: NewGameSettings,
        position: u8,
        person_stone: Stone,
    ) NewGameSettings {
        var settings: NewGameSettings = base;
        settings.scattered = ladder.stonesAt(position, person_stone);
        settings.first_player = ladder.firstPlayerAt(position, person_stone);
        return settings;
    }
};

/// The rounds of go puzzles hero (the section's lesson), each one's successor drawn at random (`RoundChances`).
pub const HeroRound = enum {
    /// The fixed game: Atari Go with outposts, on its ladder.
    fight,
    /// A puzzle ladder opening with a life problem.
    live,
    /// A puzzle ladder opening with a kill problem.
    kill,
};

/// The chances of go puzzles hero's next round after each kind (the section's lesson): a row for each kind - its
/// chances of a fight, a life puzzle and a kill puzzle next, in the order of `HeroRound`, adding up to 1. After a
/// fight, a kill puzzle twice as often as a life puzzle; after a life puzzle, a kill puzzle twice as often as a
/// fight; after a kill puzzle, any of the three alike. Only a kill puzzle may follow one of its own kind. In the long
/// run - where each kind comes as often as the rows send the play to it - a quarter of the rounds are fights, a
/// quarter life puzzles and half kill puzzles.
pub const RoundChances = struct {
    after_fight: [3]f32 = .{ 0, 1.0 / 3.0, 2.0 / 3.0 },
    after_live: [3]f32 = .{ 1.0 / 3.0, 0, 2.0 / 3.0 },
    after_kill: [3]f32 = .{ 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0 },
};

/// The round after `round` (`RoundChances`): `draw`, a number from 0 up to 1, falls in one kind's share of the
/// row - the shares laid end to end in the order of `HeroRound`. A draw past the last share, which rounding can
/// leave, is the last kind with any chance.
pub fn nextRound(round: HeroRound, chances: RoundChances, draw: f32) HeroRound {
    const row: [3]f32 = switch (round) {
        .fight => chances.after_fight,
        .live => chances.after_live,
        .kill => chances.after_kill,
    };
    var share_end: f32 = 0;
    var last_with_a_chance: HeroRound = .kill;
    for (row, 0..) |chance, kind_index| {
        if (chance <= 0) {
            continue;
        }
        last_with_a_chance = @fromBackingInt(@intCast(kind_index));
        share_end += chance;
        if (draw < share_end) {
            return last_with_a_chance;
        }
    }
    return last_with_a_chance;
}

/// How go puzzles hero's rating moves, and what a round draws from (the section's lesson). The rating is a place in
/// the problems' order of difficulty, from 0, the easiest, to 1, the hardest. A round's full problem solved at its
/// first try moves it up by `step_up`, failed at its first try down by `step_down` times the failures in a row, up
/// to `max_streak_steps` of them: a player who keeps failing falls fast to easier problems. The steps of a ladder
/// after a failure count for nothing. Alone, the two steps would bring the rating to rest where its moves even out,
/// where the player solves `step_down / (step_up + step_down)` of their first tries - 70% with 0.03 and 0.07; the
/// failures in a row raise that a little, to about three in four. A round draws its problem at random from a window
/// around the rating holding `window_share` of the problems, and at least `min_window`: a fifth of them, wide for
/// variety - every round a different problem - and still moving with the rating.
pub const RatingSettings = struct {
    step_up: f32 = 0.03,
    step_down: f32 = 0.07,
    /// The failures in a row a step down counts up to (`ratedPlace`).
    max_streak_steps: u8 = 3,
    window_share: f32 = 0.2,
    /// The fewest families a window holds, however small the collection.
    min_window: usize = 20,
};

/// The hint in go puzzles hero's puzzles (the section's lesson): a button offered once the round's problem has been
/// failed `after_failures` times - on any of its ladder's steps - which shows the move to play as a blue dot for
/// `show_seconds`: the book's next correct move while the moves so far follow the book, else the search's choice
/// for the player from a search of `search_iterations` (`heroHintMove`).
pub const HintSettings = struct {
    after_failures: u8 = 3,
    show_seconds: f32 = 0.5,
    search_iterations: u32 = 3000,
};

/// How go puzzles hero moves on from a puzzle it cannot get past (the section's lesson): a step failed
/// `max_step_failures` times in a row - the bottom step of a ladder, repeated after each failure, most often - ends
/// the round, and the next is drawn, so that no puzzle holds the player for good.
pub const HeroFlowSettings = struct {
    max_step_failures: u8 = 5,
};

/// go puzzles hero's level and its progress (the section's lesson): every `places` wins - a round's full problem
/// solved at its first try, or a fight won - raise the level by one, from 1; the wins since the level began fill the
/// row of progress, which empties as the level rises.
pub const HeroLevel = struct {
    level: u32,
    filled: u32,
};

/// The level and progress `wins` make (`HeroLevel`), with `places` wins a level.
pub fn heroLevel(wins: u32, places: u8) HeroLevel {
    const places_per_level: u32 = @max(places, 1);
    return .{ .level = wins / places_per_level + 1, .filled = wins % places_per_level };
}

/// Where go puzzles hero's row of progress is drawn (`heroProgressRow`): the first place's centre, the step to the
/// next, a stone's size, and how many places.
pub const ProgressRow = struct {
    first_centre_px: Vec2,
    spacing_px: f32,
    stone_px: f32,
    places: u8,
};

/// go puzzles hero's row of progress (the section's lesson): `controls.progress_places` places in a line along the
/// bottom, at the buttons' height, centred between the hint's place on the left and Next on the right - their sizes as
/// `submitHeroButtons` makes them - each place at most `controls.progress_spacing_fonts` from the next and no wider
/// than the room between the buttons allows, a stone filling nine tenths of its place.
pub fn heroProgressRow(
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
) ProgressRow {
    const font_size_lanes: Vec2 = @splat(font_size_px);
    const gap_px: f32 = controls.edge_gap_fonts * font_size_px;
    const button_size_px: Vec2 = controls.undo_button_size_fonts * font_size_lanes;
    const hint_width_px: f32 = button_size_px[0] * 1.4;
    const row_left_px: f32 = gap_px + hint_width_px + gap_px;
    const row_right_px: f32 = window_width_px - gap_px - button_size_px[0] - gap_px;
    const room_px: f32 = @max(row_right_px - row_left_px, 0);
    const places: u8 = @max(controls.progress_places, 1);
    const widest_spacing_px: f32 = controls.progress_spacing_fonts * font_size_px;
    const spacing_px: f32 = @min(room_px / float(places), widest_spacing_px);
    const row_width_px: f32 = spacing_px * float(places - 1);
    const middle_px: f32 = (row_left_px + row_right_px) / 2;
    const centre_y_px: f32 = window_height_px - gap_px - button_size_px[1] / 2;
    return .{
        .first_centre_px = .{ middle_px - row_width_px / 2, centre_y_px },
        .spacing_px = spacing_px,
        .stone_px = 0.9 * spacing_px,
        .places = places,
    };
}

/// go puzzles hero's row of progress (`heroProgressRow`, `HeroLevel`): a black stone in each of the first `filled`
/// places, a ring in the line's colour in each of the rest.
fn drawHeroProgress(
    gl: *z.WgpuGl,
    row: ProgressRow,
    filled: u32,
    textures: *const Textures,
    style: BoardStyle,
    controls: ControlsStyle,
) void {
    const no_tint: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const ring_radius_px: f32 = (row.stone_px - controls.progress_ring_px) / 2;
    for (0..row.places) |place_index| {
        const centre_px: Vec2 = row.first_centre_px + Vec2{ row.spacing_px * float(place_index), 0 };
        if (place_index < filled) {
            drawStone(gl, textures.black_stone, centre_px, row.stone_px, no_tint);
        } else {
            gl.circle(centre_px, ring_radius_px, .{ .color = style.line_color, .outline = controls.progress_ring_px });
        }
    }
}

/// Where go puzzles hero is (the section's lesson): its round, and in a puzzle round the family - drawn at random, not
/// the last one again - its ladder of steps and the step being played: one later after each loss, down to
/// the last; one earlier after each success, up to the full problem, whose success ends the round. And what it keeps
/// between runs (`HeroProgress`): its count of wins and the puzzle rating, which chooses the round's problems.
const HeroState = struct {
    round: HeroRound = .fight,
    family_index: usize = 0,
    steps: [max_steps]PuzzleStep = undefined,
    step_count: usize = 0,
    step_index: usize = 0,
    /// The family the last puzzle round played, which the next does not draw again.
    last_family: ?usize = null,
    /// Puzzle steps solved and fights won, over every run: the number in the corner.
    wins: u32 = 0,
    /// The puzzle rating (`RatingSettings`), and whether the round's full problem is still at its first try - the
    /// try that moves the rating.
    rating: f32 = 0,
    rating_settings: RatingSettings = .{},
    first_try: bool = false,
    /// The full problems failed at their first try in a row, the last ones (`ratedPlace`); not kept between runs.
    failure_streak: u8 = 0,
    /// Where the row of progress is drawn this frame (`heroProgressRow`), made with the buttons.
    progress_row: ?ProgressRow = null,
    /// The reward for a new level (`RewardSettings`): due when a win filled the row's last place, under way from
    /// then - the time it began - and its picture's texture while it shows.
    reward_due: bool = false,
    reward_since_seconds: ?f32 = null,
    reward_texture: ?z.WgpuTexture = null,
    /// The chances of each kind of round after each (`RoundChances`).
    round_chances: RoundChances = .{},
    /// The hint (`HintSettings`): when it is offered, how long its dot shows, and how hard its search looks; the
    /// round's puzzles failed so far - every step of its problem counts, reset with the round; and the hint shown,
    /// its point and when it began - due, the next frame's time stamps it.
    hint: HintSettings = .{},
    round_failures: u8 = 0,
    hint_point: ?Point = null,
    hint_due: bool = false,
    hint_since_seconds: ?f32 = null,
    /// How many times in a row a step may be failed before the round moves on (`HeroFlowSettings`), and
    /// the current step's count of them - reset when the step changes or is solved.
    flow: HeroFlowSettings = .{},
    step_failures: u8 = 0,
    /// This session's games ended, and whether the paywall's password has been typed - in this session or an earlier
    /// one (`Paywall`, `HeroProgress`); the password box's text.
    session_games: u32 = 0,
    unlocked: bool = false,
    /// Whether the debug lines are shown (`heroDebugLines`), and the target marked: a tap on the count of wins.
    debug_shown: bool = false,
    password_buffer: [32]u8 = undefined,
    password_length: usize = 0,

    /// More steps than any ladder has.
    const max_steps: usize = 16;
};

/// How a puzzle of go puzzles hero's ended, for its ladder.
pub const HeroOutcome = enum {
    solved,
    /// Lost beyond doubt (`heroPuzzleIsLost`), and left with Next.
    given_up,
};

/// The step a ladder of `step_count` steps goes to after its step `step_index` ended `outcome` (the section's
/// lesson): one earlier after a solution, towards the full problem - or null, the round over, when that was the full
/// problem; one later after giving up, the last at the most.
pub fn nextHeroStep(step_index: usize, step_count: usize, outcome: HeroOutcome) ?usize {
    switch (outcome) {
        .solved => {
            if (step_index == 0) {
                return null;
            }
            return step_index - 1;
        },
        .given_up => return @min(step_index + 1, step_count - 1),
    }
}

/// Where go puzzles hero goes after a step (`heroStepAfter`): the ladder's next step, or null for the next round,
/// and the failures in a row the step then has.
pub const HeroStepMove = struct {
    next_step: ?usize,
    step_failures: u8,
};

/// The move after step `step_index` of `step_count` ended with `outcome` (the section's lesson, `nextHeroStep`), the
/// step failed `step_failures` times in a row before: a failure more, and at `flow.max_step_failures`
/// the round moves on; otherwise the ladder's next step, its count of failures kept only if it is the same step
/// again - the bottom step, after a failure - and reset for another.
pub fn heroStepAfter(
    step_index: usize,
    step_count: usize,
    outcome: HeroOutcome,
    step_failures: u8,
    flow: HeroFlowSettings,
) HeroStepMove {
    const failures_now: u8 = if (outcome == .solved) 0 else step_failures +| 1;
    const next_round: HeroStepMove = .{ .next_step = null, .step_failures = 0 };
    if (failures_now >= flow.max_step_failures) {
        return next_round;
    }
    const next_step: usize = nextHeroStep(step_index, step_count, outcome) orelse return next_round;
    const kept_failures: u8 = if (next_step == step_index) failures_now else 0;
    return .{ .next_step = next_step, .step_failures = kept_failures };
}

/// The families a round may draw from: `first` up to `end`, in the order of difficulty.
pub const RatingWindow = struct {
    first: usize,
    end: usize,
};

/// The window of `family_count` families, in order of difficulty, that a round at `rating` draws from
/// (`RatingSettings`): `window_share` of them, centred on the rating's place, and shifted, not cut, at either end -
/// so that a window always holds as many.
pub fn ratingWindow(
    rating: f32,
    family_count: usize,
    settings: RatingSettings,
) RatingWindow {
    const count: f32 = float(family_count);
    const share_width: usize = @round(settings.window_share * count);
    const wide_enough: usize = @max(share_width, settings.min_window);
    const width: usize = clamp(wide_enough, 1, @max(family_count, 1));
    const centre: f32 = clamp01(rating) * (count - 1);
    const first_unclamped: f32 = @round(centre - float(width - 1) / 2);
    const highest_first: f32 = float(family_count -| width);
    const first: usize = @round(clamp(first_unclamped, 0, highest_first));
    return .{ .first = first, .end = first + width };
}

/// The rating after a round's full problem ended at its first try: up a step when it was solved, down when not - a
/// step for each of the `failures_in_a_row`, this one included, up to `settings.max_streak_steps` - within 0 and 1
/// (`RatingSettings`).
pub fn ratedPlace(
    rating: f32,
    solved_first_try: bool,
    failures_in_a_row: u8,
    settings: RatingSettings,
) f32 {
    const streak_steps: f32 = float(clamp(failures_in_a_row, 1, settings.max_streak_steps));
    const step: f32 = if (solved_first_try) settings.step_up else -settings.step_down * streak_steps;
    return clamp01(rating + step);
}

/// What go puzzles hero keeps between runs (the section's lesson): the count of wins - the one number it shows - the
/// puzzle rating, the outpost ladder's position and whether the paywall's password has been typed, saved together as
/// one value (`z.saveValue`) of nine bytes: a version, the ladder's position, the rating in ten-thousandths, the count,
/// little-endian, then a byte of flags - its lowest bit the password's. Version 1 had no flags byte; it is read as
/// the same with the password not typed.
pub const HeroProgress = struct {
    wins: u32 = 0,
    rating: f32 = 0,
    ladder_position: u8 = 0,
    unlocked: bool = false,

    /// The layout's version, its first byte: a later layout reads an earlier one by it.
    const version: u8 = 2;
    pub const byte_count: usize = 9;
    /// Version 1's length: the same, without the flags byte.
    const version_1_byte_count: usize = 8;

    /// The progress as its eight bytes.
    pub fn toBytes(progress: HeroProgress) [byte_count]u8 {
        var bytes: [byte_count]u8 = undefined;
        bytes[0] = version;
        bytes[1] = progress.ladder_position;
        const rating_in_ten_thousandths: u16 = @round(clamp01(progress.rating) * 10_000);
        writeInt(u16, bytes[2..4], rating_in_ten_thousandths, .little);
        writeInt(u32, bytes[4..8], progress.wins, .little);
        bytes[8] = @intFromBool(progress.unlocked);
        return bytes;
    }

    /// The progress `bytes` hold - this layout's, or version 1's - or null when they are neither.
    pub fn fromBytes(bytes: []const u8) ?HeroProgress {
        const is_current: bool = bytes.len == byte_count and bytes[0] == version;
        const is_version_1: bool = bytes.len == version_1_byte_count and bytes[0] == 1;
        if (!is_current and !is_version_1) {
            return null;
        }
        const rating_in_ten_thousandths: u16 = readInt(u16, bytes[2..4], .little);
        const progress: HeroProgress = .{
            .wins = readInt(u32, bytes[4..8], .little),
            .rating = float(rating_in_ten_thousandths) / 10_000,
            .ladder_position = bytes[1],
            .unlocked = is_current and bytes[8] & 1 != 0,
        };
        return progress;
    }
};

/// A game an app plays from its start, with no main menu (`AppVariant.fixed_game`): its settings, and who plays it.
pub const FixedGame = struct {
    settings: NewGameSettings,
    players: Players,
};

/// How a problem's game judges its player's moves after the problem is solved.
pub const ProblemPlaySettings = struct {
    /// A move the computer searched and won at least this often in its search has, it says, let the target's group
    /// live: the player's move before it undid the solution, and "Solved" goes. High, since the playouts that must
    /// capture a dead group often fail: after the book's solution the computer's rate is about 0.3 to 0.5.
    refuting_win_rate: f32 = 0.8,
    /// A computer whose searched moves won less than this often `giving_up_moves` times in a row cannot do what it
    /// plays for: in a life problem the target lives - in seki, escaped, or with eyes not yet proven - and in a kill
    /// problem it is dead. Low, since once a group truly lives no playout captures it.
    giving_up_win_rate: f32 = 0.05,
    giving_up_moves: u8 = 2,
};

/// What interface one of goban's apps has.
pub const Interface = enum {
    /// The buttons, the windows, the debug panel and the caption.
    full,
    /// None: the screen is the board alone.
    none,
    /// A problem's: Undo, and Next once the problem is solved.
    problem_buttons,
    /// Go puzzles hero's: the hint once a puzzle has been failed often enough, Next once a puzzle is solved or lost,
    /// the count of wins in a corner, and a line across the top - the puzzle's kind before the first move, "Solved"
    /// once it is.
    hero_buttons,
};

/// What makes one of goban's apps (the section's lesson): goban is the default, and another example makes its own
/// from the same code with `appFor` - the rules, the search, the board, the input and the sounds all goban's.
pub const AppVariant = struct {
    /// The window's title.
    title: []const u8 = "zimr - goban",
    /// A game played from the start, with no main menu; null: the main menu chooses one.
    fixed_game: ?FixedGame = null,
    /// What interface the screen has.
    interface: Interface = .full,
    /// Problems played one after another, each an SGF text with its target marked (`problem_sgfs`); empty,
    /// the fixed game or the main menu's.
    problems: []const []const u8 = &.{},
    /// Go puzzles hero (`HeroState`): rounds of the fixed game (the fight, on its outpost ladder) and of puzzles from
    /// `problem_families`, in turn - fight, live, kill - each puzzle a ladder of starts, failed down and solved up.
    hero: bool = false,
    problem_families: []const ProblemFamily = &.{},
    /// Where go puzzles hero keeps its progress between runs (`HeroProgress`, `z.saveValue`: the page's local storage,
    /// a file natively).
    hero_progress_key: []const u8 = "go_puzzles_hero.progress",
    /// Where an earlier version kept the count of wins alone, read when there is no progress yet.
    hero_earlier_wins_key: []const u8 = "go_puzzles_hero.wins",
    /// The pictures go puzzles hero shows, one at random, at each new level (`RewardSettings`), the sound that goes
    /// with them (Ogg Vorbis), and the reward's timing; no pictures, no reward.
    reward_images: []const []const u8 = &.{},
    reward_sound: ?[]const u8 = null,
    reward: RewardSettings = .{},
    /// The window that asks a player for support after a session's first puzzles (`Paywall`), or none.
    paywall: ?Paywall = null,
    /// Whether a problem's target is marked on the board - a triangle on a stone to capture, a square on one to save.
    /// Where the problem makes its group plain enough, the board goes without.
    marks_target: bool = true,
    /// With kill problems, whether the computer answers with the book's reply when the moves so far are a line of the
    /// problem's solution tree - so that a player who finds the book's solution reaches its "Correct" - and searches
    /// only off the book.
    computer_follows_book: bool = true,
    /// A won game starts again by itself this long after the win, in seconds; null: the victory window offers what
    /// comes next.
    restart_after_win_seconds: ?f32 = null,
    /// Scattered stones that move with the results, against the computer: null, the fixed game's own.
    outpost_ladder: ?OutpostLadder = null,
};

/// The program's whole state: everything it remembers from one frame to the next.
const State = struct {
    /// Which of goban's apps this is (`appFor`): the full one, or one made for another example.
    variant: AppVariant,
    /// When the game being played was won, in the app's seconds - the clock of a restart that the variant makes after a
    /// win - or null while it is not won.
    won_at_seconds: ?f32,
    /// With an outpost ladder, the position of the game being played.
    ladder_position: u8,
    /// With problems, the one being played, by its index in `variant.problems`, and its solution tree drawn
    /// in the problem's symmetry.
    problem_index: usize,
    problem_tree: SolutionTree,
    /// Whether the problem has been solved in this start of it - Next is shown from then on - and whether the
    /// computer's last searched move says the player's has since let the target live.
    problem_solved_once: bool,
    problem_refuted: bool,
    /// Which task the problem sets, and how many of the computer's searched moves in a row won less often than
    /// `problem_play.giving_up_win_rate`.
    problem_kind: ProblemKind,
    computer_hopeless_moves: u8,
    /// Go puzzles hero's round and step (`AppVariant.hero`).
    hero: HeroState,
    /// The session's random numbers, seeded once from the wall clock (`z.epochMillis`) when the app starts: every
    /// draw - a game's scattered stones, a problem's symmetry, a round, a family, a book's reply - takes the next of
    /// them, so that two draws in one frame are not the same draw, and every session differs, a cleared save
    /// included.
    random: Xoshiro256,
    /// The allocator the app was started with, kept for what a frame must allocate and a frame does not carry
    /// one for: a reward's picture, decoded when it is shown (`updateHeroReward`) rather than all at the start.
    gpa: Allocator,
    problem_play: ProblemPlaySettings,
    /// The screen shown, and the main menu's choices.
    screen: Screen,
    menu: MenuChoices,
    game: Game,
    /// The settings the game being played was started with, and who plays it: what Restart starts again.
    new_game_settings: NewGameSettings,
    players: Players,
    /// The computer: how it plays, and its search between frames.
    computer_settings: ComputerSettings,
    computer: ComputerPlayer,
    style: BoardStyle,
    controls: ControlsStyle,
    /// A stone picked up by a press, waiting for the release, and where the ghost has shown it (section 10).
    hold: StoneHold,
    ghost: Ghost,
    /// Which overlays are drawn, and how long the pointer has been on its point (section 9).
    overlays: OverlayOptions,
    hover_clock: HoverClock,
    /// The captured stones in flight, and the capture columns' slot spacing on its spring, which has its first value
    /// once `slot_spacing_ready` (sections 8 and 9).
    flights: Flights,
    slot_spacing_spring: DoubleSpring(f32),
    slot_spacing_ready: bool,
    /// The position the ghost's move would make, which the liberty overlay reads (section 9): scratch, written every
    /// frame there is a ghost, before it is read.
    ghost_position: Position,
    pause_open: bool,
    window_heights: CentredWindowHeights,
    finger_gesture: FingerGesture,
    /// The sounds a stone makes, and whether they are on (the pause window's "Sound").
    stone_sounds: StoneSounds,
    sound_on: bool,
    debug: DebugPanel,
    /// What each move of the record did, for the debug panel's move log: written when the move is played, at its
    /// index. Undo, redo and the timeline replay the same moves, so the reports stay true; a move played after an undo
    /// writes over the one it replaces.
    move_log: [record_limits.max_moves]MoveReport,
    ui_host: z.UiHost,
    textures: Textures,
    font: z.Font,
};

/// The three pictures, in the program: decoded at start, uploaded to the GPU, and their decoded pixels freed.
const wood_png: []const u8 = @embedFile("wood.png");
const black_stone_png: []const u8 = @embedFile("black_stone.png");
const white_stone_png: []const u8 = @embedFile("white_stone.png");
const atkinson_mono_ttf: []const u8 = @embedFile("atkinson_mono_ttf");

/// Decodes a PNG, uploads it as a texture, and frees the decoded pixels, which the GPU now holds.
fn uploadPng(gpa: Allocator, gl: *z.WgpuGl, png_bytes: []const u8) !z.WgpuTexture {
    const image: z.Image = try z.loadImageFromMemory(gpa, png_bytes);
    const texture: z.WgpuTexture = z.loadTextureFromImage(gl, image);
    z.unloadImage(gpa, image);
    return texture;
}

/// Releases what init made and loaded.
fn deinit(gpa: Allocator, s: *State) void {
    s.computer.deinit();
    s.stone_sounds.unload();
    s.ui_host.deinit();
    s.textures.wood.deinit();
    s.textures.black_stone.deinit();
    s.textures.white_stone.deinit();
    if (s.hero.reward_texture) |*texture| {
        texture.deinit();
    }
    z.unloadFont(gpa, s.font);
}

/// One button alone in a window of its own, with no title bar, no background and no outline, so only the button
/// shows. The button is placed at `top_left_px` and `size_px` large every frame, so it follows the window when it is
/// resized; its window is the button plus the window's padding on every side. Returns whether it was pressed.
fn fixedButton(
    u: ui.Ui,
    window_id: []const u8,
    label: []const u8,
    top_left_px: Vec2,
    size_px: Vec2,
) bool {
    const padding_px: Vec2 = u.style().window_padding;
    const window_top_left_px: Vec2 = top_left_px - padding_px;
    const window_size_px: Vec2 = size_px + padding_px + padding_px;
    u.setNextWindowPos(window_top_left_px, .{});
    u.setNextWindowSize(window_size_px, .{});
    const flags: ui.WindowFlags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_scrollbar = true,
    };
    // A window's outline is drawn when it opens, in the style's border colour: made transparent for this one.
    const no_outline: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    u.pushStyle("border", no_outline);
    const maybe_window: ?ui.WindowHandle = u.window(window_id, .{ .flags = flags });
    u.popStyle();
    const window: ui.WindowHandle = maybe_window orelse {
        return false;
    };
    defer window.close();
    const pressed: bool = u.button(label, .{ .size = size_px });
    return pressed;
}

/// What the two buttons on the board's screen asked for this frame.
const ButtonPresses = struct {
    menu: bool,
    undo: bool,
};

/// The Menu button in the top-right corner and the Undo button in the bottom-left, opposite it. A corner keeps Undo
/// clear of what a host draws at the bottom centre - the launcher's switch pill, which stands 56 to 90 px above the
/// bottom edge, would cover the top of a centred Undo in any window wider than about 470 px.
fn submitGameButtons(
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
    undo_takes_something_back: bool,
) ButtonPresses {
    const font_size_lanes: Vec2 = @splat(font_size_px);
    const gap_px: f32 = controls.edge_gap_fonts * font_size_px;

    const menu_size_px: Vec2 = controls.menu_button_size_fonts * font_size_lanes;
    const menu_top_left_px: Vec2 = .{ window_width_px - menu_size_px[0] - gap_px, gap_px };
    const menu_pressed: bool = fixedButton(u, "menu button", "Menu", menu_top_left_px, menu_size_px);

    const undo_size_px: Vec2 = controls.undo_button_size_fonts * font_size_lanes;
    const undo_top_left_px: Vec2 = .{
        gap_px,
        window_height_px - undo_size_px[1] - gap_px,
    };
    u.beginDisabled(!undo_takes_something_back);
    const undo_pressed: bool = fixedButton(u, "undo button", "Undo", undo_top_left_px, undo_size_px);
    u.endDisabled();

    const presses: ButtonPresses = .{ .menu = menu_pressed, .undo = undo_pressed };
    return presses;
}

/// A line of text alone in a window of its own, with no title bar, no background and no outline, so only the text
/// shows, placed at `top_left_px` every frame.
fn fixedLabel(u: ui.Ui, window_id: []const u8, text: []const u8, top_left_px: Vec2) void {
    u.setNextWindowPos(top_left_px, .{});
    const flags: ui.WindowFlags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_scrollbar = true,
        .always_auto_resize = true,
        .no_inputs = true,
    };
    const no_outline: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    u.pushStyle("border", no_outline);
    const maybe_window: ?ui.WindowHandle = u.window(window_id, .{ .flags = flags });
    u.popStyle();
    const window: ui.WindowHandle = maybe_window orelse {
        return;
    };
    defer window.close();
    u.text("{s}", .{text});
}

/// A label drawn larger and bolder (`ControlsStyle.headline_scale`, `.headline_stroke_fonts`): `text` at
/// `headline_px`, in two windows of their own (`window_ids`) - the second `stroke_px` to the right of the first, so
/// that each stroke is drawn twice, thicker. The interface has one face of its font; this is its bold.
fn fixedHeadline(
    u: ui.Ui,
    window_ids: [2][]const u8,
    text: []const u8,
    top_left_px: Vec2,
    headline_px: f32,
    stroke_px: f32,
) void {
    u.pushStyle("font_size", headline_px);
    defer u.popStyle();
    fixedLabel(u, window_ids[0], text, top_left_px);
    fixedLabel(u, window_ids[1], text, top_left_px + Vec2{ stroke_px, 0 });
}

/// A button with nothing drawn, in a window of its own placed at `top_left_px` every frame, `size_px` large: a tap on
/// whatever is drawn there - a label, say (`fixedLabel`), whose window takes no input - is caught by it.
fn fixedTapArea(u: ui.Ui, window_id: []const u8, top_left_px: Vec2, size_px: Vec2) bool {
    const padding_px: Vec2 = u.style().window_padding;
    u.setNextWindowPos(top_left_px - padding_px, .{});
    u.setNextWindowSize(size_px + padding_px + padding_px, .{});
    const flags: ui.WindowFlags = .{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
        .no_background = true,
        .no_scrollbar = true,
    };
    const no_outline: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    u.pushStyle("border", no_outline);
    const maybe_window: ?ui.WindowHandle = u.window(window_id, .{ .flags = flags });
    u.popStyle();
    const window: ui.WindowHandle = maybe_window orelse {
        return false;
    };
    defer window.close();
    return u.invisibleButton("##tap", size_px);
}

/// What go puzzles hero's buttons asked for this frame.
const HeroPresses = struct {
    hint: bool = false,
    next: bool = false,
    /// A tap on the count of wins: the debug lines shown or hidden.
    debug_toggle: bool = false,
};

/// Go puzzles hero's buttons: the hint in the bottom-left corner when `shows_hint`, Next in the bottom-right when
/// `shows_next`, the count
/// of wins in the top-left, and - when there is one - a line across the top, `top_line`: the round's kind before the
/// player's first move, "Solved" or "Failed" once the puzzle is.
fn submitHeroButtons(
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
    shows_hint: bool,
    shows_next: bool,
    label: []const u8,
    top_line: ?[]const u8,
    debug_lines: []const []const u8,
) HeroPresses {
    const font_size_lanes: Vec2 = @splat(font_size_px);
    const gap_px: f32 = controls.edge_gap_fonts * font_size_px;
    const button_size_px: Vec2 = controls.undo_button_size_fonts * font_size_lanes;
    const hint_size_px: Vec2 = .{ button_size_px[0] * 1.4, button_size_px[1] };
    const bottom_px: f32 = window_height_px - button_size_px[1] - gap_px;
    // The hint, in a puzzle failed often enough (`HintSettings`).
    var hint_pressed: bool = false;
    if (shows_hint) {
        hint_pressed = fixedButton(u, "hint button", "Hint", .{ gap_px, bottom_px }, hint_size_px);
    }
    var next_pressed: bool = false;
    if (shows_next) {
        const next_top_left_px: Vec2 = .{ window_width_px - button_size_px[0] - gap_px, bottom_px };
        next_pressed = fixedButton(u, "next button", "Next", next_top_left_px, button_size_px);
    }
    // The level and the line across the top as headlines (`fixedHeadline`).
    const headline_px: f32 = controls.headline_scale * font_size_px;
    const stroke_px: f32 = controls.headline_stroke_fonts * headline_px;
    fixedHeadline(u, .{ "hero wins", "hero wins bold" }, label, .{ gap_px, gap_px }, headline_px, stroke_px);
    // The level, tapped, shows or hides the debug lines, drawn under it.
    const count_size_px: Vec2 = .{ controls.label_glyph_fonts * headline_px * 4, headline_px };
    const debug_toggled: bool = fixedTapArea(u, "hero wins tap", .{ gap_px, gap_px }, count_size_px);
    const debug_ids = [_][]const u8{
        "hero debug 0", "hero debug 1", "hero debug 2", "hero debug 3",
        "hero debug 4", "hero debug 5", "hero debug 6", "hero debug 7",
    };
    const line_height_px: f32 = 1.2 * font_size_px;
    const first_line_top_px: f32 = gap_px + 1.2 * headline_px;
    const shown_count: usize = @min(debug_lines.len, debug_ids.len);
    for (debug_lines[0..shown_count], debug_ids[0..shown_count], 0..) |debug_line, debug_id, line_index| {
        const line_top_px: f32 = first_line_top_px + line_height_px * float(line_index);
        fixedLabel(u, debug_id, debug_line, .{ gap_px, line_top_px });
    }
    if (top_line) |line| {
        const line_width_px: f32 = controls.label_glyph_fonts * headline_px * float(line.len) + stroke_px;
        const line_left_px: f32 = (window_width_px - line_width_px) / 2;
        const line_ids: [2][]const u8 = .{ "hero top line", "hero top line bold" };
        fixedHeadline(u, line_ids, line, .{ line_left_px, gap_px }, headline_px, stroke_px);
    }
    const presses: HeroPresses = .{ .hint = hint_pressed, .next = next_pressed, .debug_toggle = debug_toggled };
    return presses;
}

/// What a problem's buttons asked for this frame.
const ProblemPresses = struct {
    undo: bool = false,
    next: bool = false,
};

/// A problem's buttons: Undo in the bottom-left corner, where the game's own is, and - from the problem's first
/// solving on - Next in the bottom-right, opposite it; and at the top, "Solved" while it is, or `task_label` - the
/// task, before the first move.
fn submitProblemButtons(
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
    undo_takes_something_back: bool,
    problem_is_solved: bool,
    shows_next: bool,
    task_label: ?[]const u8,
) ProblemPresses {
    const font_size_lanes: Vec2 = @splat(font_size_px);
    const gap_px: f32 = controls.edge_gap_fonts * font_size_px;
    const button_size_px: Vec2 = controls.undo_button_size_fonts * font_size_lanes;
    const bottom_px: f32 = window_height_px - button_size_px[1] - gap_px;

    const undo_top_left_px: Vec2 = .{ gap_px, bottom_px };
    u.beginDisabled(!undo_takes_something_back);
    const undo_pressed: bool = fixedButton(u, "undo button", "Undo", undo_top_left_px, button_size_px);
    u.endDisabled();

    var next_pressed: bool = false;
    if (shows_next) {
        const next_top_left_px: Vec2 = .{ window_width_px - button_size_px[0] - gap_px, bottom_px };
        next_pressed = fixedButton(u, "next button", "Next", next_top_left_px, button_size_px);
    }
    // Across the top, in the middle: "Solved" while it is; before the first move, the task - "Kill" or "Live".
    const top_label: ?[]const u8 = if (problem_is_solved) "Solved" else task_label;
    if (top_label) |label| {
        const label_width_px: f32 = float(label.len) * 0.6 * font_size_px;
        const label_top_left_px: Vec2 = .{ (window_width_px - label_width_px) / 2, gap_px };
        fixedLabel(u, "problem label", label, label_top_left_px);
    }
    const presses: ProblemPresses = .{ .undo = undo_pressed, .next = next_pressed };
    return presses;
}

/// Where a centred window's top goes, for a window `window_height_px` tall in a screen `screen_height_px` tall, kept
/// `margin_px` from the screen's top and bottom: the room the window leaves between the margins goes a third above it
/// and two thirds below, so it sits high, where a menu is looked for. A window with no room to spare - as tall as the
/// screen leaves it, or taller - starts at the margin.
pub fn centredWindowTop(
    screen_height_px: f32,
    window_height_px: f32,
    margin_px: f32,
) f32 {
    const room_left_px: f32 = @max(0, screen_height_px - 2 * margin_px - window_height_px);
    const top_px: f32 = margin_px + room_left_px / 3;
    return top_px;
}

/// A centred window open this frame (`openCentredWindow`): closing it keeps the height its content needed, for the
/// next frame to place it by and the font size to fit.
const CentredWindow = struct {
    handle: ui.WindowHandle,
    /// The window's own height in `CentredWindowHeights`, and the tallest of them all.
    height_fonts: *f32,
    tallest_fonts: *f32,
    font_size_px: f32,

    /// Keeps the height the window's content needed this frame, in font sizes, and closes it. The layout's cursor
    /// waits one item spacing below the last row, moved up by the window's scroll: the content's bottom, with the
    /// padding below it, is the window's height fitted to it - read this frame, at this frame's font size, whether
    /// the window was held shorter or not.
    fn close(window: CentredWindow) void {
        const u: ui.Ui = window.handle.ui;
        const style: *ui.Style = u.style();
        const content_bottom_px: f32 = u.getCursorPos()[1] + u.getScrollY() - style.item_spacing[1];
        const height_px: f32 = content_bottom_px + style.window_padding[1] - u.getWindowPos()[1];
        const height_fonts: f32 = height_px / window.font_size_px;
        // A window's first frame lays it out at the size it is made with, not one fitted to it, and a wrapped line
        // can need more lines in it: the tallest takes the window's height from its second frame on.
        const is_first_frame: bool = window.height_fonts.* == 0;
        window.height_fonts.* = height_fonts;
        if (!is_first_frame) {
            window.tallest_fonts.* = @max(window.tallest_fonts.*, height_fonts);
        }
        window.handle.close();
    }
};

/// A window centred across, `width_px` wide and as tall as its content - the pause, victory, main menu and paywall
/// windows - its top placed by `centredWindowTop` from the height its content needed the last frame it was shown,
/// `height_fonts` (zero before its first frame, which opens it at the margin). It is never taller than the screen
/// less its margins: the font size, fitted to the tallest window (`interfaceFontSize`), keeps every window shorter than
/// that unless the screen is too short for it at the smallest font size, and then the window is held to that height
/// and scrolls the rest. Returns the window, or null when it is not shown this frame.
fn openCentredWindow(
    u: ui.Ui,
    title: []const u8,
    window_width_px: f32,
    window_height_px: f32,
    width_px: f32,
    font_size_px: f32,
    margin_px: f32,
    height_fonts: *f32,
    tallest_fonts: *f32,
) ?CentredWindow {
    const room_px: f32 = @max(0, window_height_px - 2 * margin_px);
    const content_height_px: f32 = height_fonts.* * font_size_px;
    // Before its first frame the window's height is not known, so it opens at the margin, where whatever its height
    // it runs off the screen no further than it must; from the next frame it is placed by the height it then needed.
    var top_px: f32 = margin_px;
    if (height_fonts.* > 0) {
        top_px = centredWindowTop(window_height_px, content_height_px, margin_px);
    }
    const top_left_px: Vec2 = .{ (window_width_px - width_px) / 2, top_px };
    u.setNextWindowPos(top_left_px, .{});
    // Fitted to its content, the window keeps within the room. Its scroll bar - and the wheel, and a finger's drag -
    // is only for a window whose content the room is too short for, as measured: when the font size has just shrunk,
    // the few pixels that do not shrink with it (`CentredWindowHeights`) can make the window a little taller than its
    // height in font sizes says, and the room cuts them off the padding below for the frame it takes to measure it.
    u.setNextWindowSizeConstraints(null, .{ window_width_px, room_px });
    const scrolls: bool = content_height_px > room_px;
    const flags: ui.WindowFlags = .{
        .no_resize = true,
        .no_move = true,
        .no_scrollbar = !scrolls,
        .always_auto_resize = true,
    };
    const handle: ui.WindowHandle = u.window(title, .{ .flags = flags }) orelse {
        return null;
    };
    const window: CentredWindow = .{
        .handle = handle,
        .height_fonts = height_fonts,
        .tallest_fonts = tallest_fonts,
        .font_size_px = font_size_px,
    };
    return window;
}

/// The pause window, centred: Return to Game, Restart, Return to Main Menu and - where the program runs its own
/// frames - Quit to Desktop, and a checkbox for each overlay, for the stones' sounds, and for the debug panel (the way
/// to it on a phone, which has no H key). Returns what was chosen this frame; the checkboxes change what they point at
/// directly.
fn submitPauseWindow(
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
    window_heights: *CentredWindowHeights,
    overlays: *OverlayOptions,
    sound_on: *bool,
    debug_panel_open: *bool,
) PauseChoice {
    const width_px: f32 = controls.pause_window_width_fonts * font_size_px;
    const button_height_px: f32 = controls.pause_button_height_fonts * font_size_px;
    const maybe_window: ?CentredWindow = openCentredWindow(
        u,
        "Paused",
        window_width_px,
        window_height_px,
        width_px,
        font_size_px,
        controls.edge_gap_fonts * font_size_px,
        &window_heights.pause,
        &window_heights.tallest,
    );
    const window: CentredWindow = maybe_window orelse {
        return .none;
    };
    defer window.close();
    const padding_px: Vec2 = u.style().window_padding;
    const button_size_px: Vec2 = .{ width_px - 2 * padding_px[0], button_height_px };
    if (u.button("Return to Game", .{ .size = button_size_px })) {
        return .return_to_game;
    }
    if (u.button("Restart", .{ .size = button_size_px })) {
        return .restart;
    }
    if (u.button("Return to Main Menu", .{ .size = button_size_px })) {
        return .return_to_main_menu;
    }
    if (comptime z.host.drives_own_frames) {
        if (u.button("Quit to Desktop", .{ .size = button_size_px })) {
            return .quit_to_desktop;
        }
    }
    u.separator();
    _ = u.checkbox("Show atari", &overlays.atari_groups);
    _ = u.checkbox("Show captures", &overlays.doomed_groups);
    _ = u.checkbox("Show liberties", &overlays.liberties);
    _ = u.checkbox("Sound", sound_on);
    _ = u.checkbox("Debug panel", debug_panel_open);
    return .none;
}

/// The victory window: who won, and Continue Playing, Restart and Main Menu. Returns what was chosen this frame.
fn submitVictoryWindow(
    u: ui.Ui,
    winner: Stone,
    continue_is_offered: bool,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
    window_heights: *CentredWindowHeights,
) VictoryChoice {
    const width_px: f32 = controls.pause_window_width_fonts * font_size_px;
    const maybe_window: ?CentredWindow = openCentredWindow(
        u,
        "Atari Go",
        window_width_px,
        window_height_px,
        width_px,
        font_size_px,
        controls.edge_gap_fonts * font_size_px,
        &window_heights.victory,
        &window_heights.tallest,
    );
    const window: CentredWindow = maybe_window orelse {
        return .none;
    };
    defer window.close();
    var winner_name: []const u8 = "Black";
    if (winner == .white) {
        winner_name = "White";
    }
    u.text("{s} wins!", .{winner_name});
    const padding_px: Vec2 = u.style().window_padding;
    const button_height_px: f32 = controls.pause_button_height_fonts * font_size_px;
    const button_size_px: Vec2 = .{ width_px - 2 * padding_px[0], button_height_px };
    // Continue Playing turns the game into plain Go, which the computer does not play.
    if (continue_is_offered and u.button("Continue Playing", .{ .size = button_size_px })) {
        return .continue_playing;
    }
    if (u.button("Restart", .{ .size = button_size_px })) {
        return .restart;
    }
    if (u.button("Main Menu", .{ .size = button_size_px })) {
        return .main_menu;
    }
    return .none;
}

/// A usual size's button label, "9 x 9" and the like, written into `buffer`.
fn sizeLabel(buffer: *[8]u8, board_size: u8) []const u8 {
    var label_length: usize = printInt(buffer[0..], board_size, 10, .lower, .{});
    const between: []const u8 = " x ";
    @memcpy(buffer[label_length .. label_length + between.len], between);
    label_length += between.len;
    label_length += printInt(buffer[label_length..], board_size, 10, .lower, .{});
    return buffer[0..label_length];
}

/// The main menu: the board's size - three usual sizes as buttons, the one chosen highlighted, and a slider for any
/// size - then Atari Go and its capture goal, then Start Game and, where the program runs its own frames, Quit. Start
/// Game is disabled, with the reason said, when Atari Go is chosen on a board too small for it (G3: on 3 x 3 the
/// starting square's corner stone would begin the game captured). Returns what was chosen this frame; the choices are
/// changed in place.
fn submitMainMenu(
    u: ui.Ui,
    choices: *MenuChoices,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
    window_heights: *CentredWindowHeights,
) MainMenuChoice {
    const width_px: f32 = controls.main_menu_width_fonts * font_size_px;
    const maybe_window: ?CentredWindow = openCentredWindow(
        u,
        "goban",
        window_width_px,
        window_height_px,
        width_px,
        font_size_px,
        controls.edge_gap_fonts * font_size_px,
        &window_heights.main_menu,
        &window_heights.tallest,
    );
    const window: CentredWindow = maybe_window orelse {
        return .none;
    };
    defer window.close();
    const padding_px: Vec2 = u.style().window_padding;
    const spacing_px: f32 = u.style().item_spacing[0];
    const inner_width_px: f32 = width_px - 2 * padding_px[0];
    const button_height_px: f32 = controls.pause_button_height_fonts * font_size_px;

    // Who plays; against the computer, the person's colour.
    var kind_index: i32 = @backingInt(choices.game_kind);
    for (GameKind.labels, 0..) |label, index| {
        _ = u.radioButton(label, &kind_index, @intCast(index));
    }
    choices.game_kind = @fromBackingInt(@intCast(kind_index));
    if (choices.game_kind == .against_computer) {
        u.text("You play", .{});
        var stone_index: i32 = @backingInt(choices.person_stone);
        u.sameLine(.{});
        _ = u.radioButton("Black", &stone_index, @backingInt(Stone.black));
        u.sameLine(.{});
        _ = u.radioButton("White", &stone_index, @backingInt(Stone.white));
        choices.person_stone = @fromBackingInt(@intCast(stone_index));
    }
    u.separator();

    // The board's size.
    u.text("Board size", .{});
    const usual_count: f32 = float(MenuChoices.usual_sizes.len);
    const usual_width_px: f32 = (inner_width_px - (usual_count - 1) * spacing_px) / usual_count;
    for (MenuChoices.usual_sizes, 0..) |usual_size, index| {
        if (index > 0) {
            u.sameLine(.{});
        }
        var label_buffer: [8]u8 = undefined;
        const label: []const u8 = sizeLabel(&label_buffer, usual_size);
        const is_chosen: bool = choices.board_size == usual_size;
        if (is_chosen) {
            u.pushStyle("button", u.style().button_active);
        }
        if (u.button(label, .{ .size = .{ usual_width_px, button_height_px } })) {
            choices.board_size = usual_size;
        }
        if (is_chosen) {
            u.popStyle();
        }
    }
    _ = u.slider("size", &choices.board_size, .{
        .min = board_limits.min_size,
        .max = board_limits.max_size,
        .fmt = "{d}",
    });
    u.separator();

    // Atari Go, and its goal. With the computer playing, Atari Go is on and stays on: it is the one game it plays.
    const computer_plays: bool = choices.game_kind.hasComputer();
    if (computer_plays) {
        var locked_on: bool = true;
        u.beginDisabled(true);
        _ = u.checkbox("Atari Go", &locked_on);
        u.endDisabled();
        u.text("The computer plays Atari Go.", .{});
    } else {
        _ = u.checkbox("Atari Go", &choices.atari_go);
    }
    if (choices.isAtariGo()) {
        u.text("Captures to win", .{});
        for (MenuChoices.capture_goals, 0..) |goal, index| {
            if (index > 0) {
                u.sameLine(.{});
            }
            var label_buffer: [4]u8 = undefined;
            const digit_count: usize = printInt(&label_buffer, goal, 10, .lower, .{});
            _ = u.radioButton(label_buffer[0..digit_count], &choices.capture_goal, goal);
        }
        // The scattered stones: none, or a few pairs around the square, drawn anew for each game.
        u.text(MenuChoices.scattered_mode_name, .{});
        for (ScatteredStones.counts) |count| {
            u.sameLine(.{});
            var label_buffer: [8]u8 = undefined;
            var label: []const u8 = "none";
            if (count > 0) {
                const digit_count: usize = printInt(&label_buffer, count, 10, .lower, .{});
                label = label_buffer[0..digit_count];
            }
            _ = u.radioButton(label, &choices.scattered_count, count);
        }
    }
    const settings: NewGameSettings = choices.settings();
    const size_is_allowed: bool = allowsBoardSize(settings.capture_goal, settings.board_size);
    if (!size_is_allowed) {
        u.text("Atari Go needs a board of {d} x {d} or more.", .{ atari_go.min_board_size, atari_go.min_board_size });
    }
    const scattered_stones_fit: bool = scatteredStonesFit(settings.board_size, settings.scattered);
    if (size_is_allowed and !scattered_stones_fit) {
        const smallest_size: u8 = smallestBoardForScatteredStones(settings.scattered) orelse board_limits.max_size;
        u.text("{s} of {d} need a board of {d} x {d} or more.", .{
            MenuChoices.scattered_mode_name,
            settings.scattered.total(),
            smallest_size,
            smallest_size,
        });
    }
    const can_start: bool = size_is_allowed and scattered_stones_fit;
    u.separator();

    // Start, and Quit.
    const button_size_px: Vec2 = .{ inner_width_px, button_height_px };
    u.beginDisabled(!can_start);
    const start_pressed: bool = u.button("Start Game", .{ .size = button_size_px });
    u.endDisabled();
    if (start_pressed and can_start) {
        return .start;
    }
    if (comptime z.host.drives_own_frames) {
        if (u.button("Quit", .{ .size = button_size_px })) {
            return .quit;
        }
    }
    return .none;
}

/// A point as a person reads it: "(row,col)", written into `buffer`.
fn pointLabel(buffer: *[12]u8, board_size: u8, point: Point) []const u8 {
    const row: u8 = rowOf(board_size, point);
    const col: u8 = colOf(board_size, point);
    const label: []const u8 = bufPrint(buffer, "({d},{d})", .{ row, col }) catch {
        panicf(@src(), "a point's label fits in 12 bytes", .{});
    };
    return label;
}

/// The debug panel: the game's state in one line; Undo, Redo and Restart; a timeline slider over the record's moves;
/// the position copied and pasted as a diagram; the judge's switch and its last finding; the last moves of the log
/// (`move_log`, one report per move shown); and the inspector - everything the forest says about the point under the
/// pointer. Returns what it asks for this frame; the switch is changed in place.
fn submitDebugPanel(
    u: ui.Ui,
    game: *const Game,
    computer: *const ComputerPlayer,
    computer_settings: ComputerSettings,
    move_log: []const MoveReport,
    pointed_point: ?Point,
    debug: *DebugPanel,
    font_size_px: f32,
) DebugRequests {
    var requests: DebugRequests = .{};
    u.setNextWindowPos(.{ font_size_px * 0.4, font_size_px * 3 }, .{ .once = true });
    const flags: ui.WindowFlags = .{ .always_auto_resize = true, .no_scrollbar = true };
    const window: ui.WindowHandle = u.window("Debug", .{ .flags = flags }) orelse {
        return requests;
    };
    defer window.close();
    const position: *const Position = &game.position;
    const record: *const Record = &game.record;

    // The game's state, and its controls.
    u.text("{t} to play - move {d} of {d}", .{ position.player_to_move, record.moves_played, record.moves_recorded });
    var where_jobs_run: []const u8 = "in the frames";
    if (computer.search == .jobs) {
        where_jobs_run = "on " ++ JobSearch.place;
    }
    u.text("computer: {d:.1} s a move, {s}", .{ computer_settings.move_milliseconds / 1000, where_jobs_run });
    u.text("  last move {d} iterations in {d:.2} s; now {d}", .{
        computer.lastMoveIterations(),
        computer.last_move_seconds,
        computer.iterationsDone(),
    });
    const black_prisoners: u32 = position.stones_captured_by_black;
    const white_prisoners: u32 = position.stones_captured_by_white;
    u.text("prisoners: black {d}, white {d}", .{ black_prisoners, white_prisoners });
    requests.undo = u.button("Undo", .{});
    u.sameLine(.{});
    requests.redo = u.button("Redo", .{});
    u.sameLine(.{});
    requests.restart = u.button("Restart", .{});
    var timeline_move: u16 = record.moves_played;
    const timeline_moved: bool = u.slider("move", &timeline_move, .{
        .min = 0,
        .max = float(record.moves_recorded),
        .fmt = "{d}",
    });
    if (timeline_moved and timeline_move != record.moves_played) {
        requests.jump_to_move = timeline_move;
    }

    // The position as text: copied to the clipboard as a diagram - one paste away from a test - and pasted back. A
    // paste through the system's own command (Ctrl+V) loads too, while the panel is open.
    requests.copy_diagram = u.button("Copy diagram", .{});
    u.sameLine(.{});
    requests.paste_diagram = u.button("Paste diagram", .{});
    const paste_note: []const u8 = debug.pasteNote();
    if (paste_note.len > 0) {
        u.text("{s}", .{paste_note});
    }

    // The forest view, and the judge.
    u.separator();
    _ = u.checkbox("Forest view", &debug.forest_view);
    if (debug.forest_view) {
        u.sameLine(.{});
        _ = u.checkbox("depths", &debug.forest_depths);
    }
    _ = u.checkbox("Verify every move", &debug.verify_every_move);
    if (debug.last_check) |check| {
        if (check.disagreement) |disagreement| {
            u.text("after move {d}: {f}", .{ check.after_move, disagreement });
        } else {
            u.text("after move {d}: the forest agrees", .{check.after_move});
        }
    }

    // The move log: the last moves the board shows, oldest first.
    u.separator();
    const shown_moves: usize = @min(move_log.len, DebugPanel.log_lines);
    const first_shown: usize = move_log.len - shown_moves;
    for (move_log[first_shown..], first_shown..) |report, move_index| {
        var line_buffer: [80]u8 = undefined;
        var line: Io.Writer = .fixed(&line_buffer);
        writeMoveLine(report, position.board_size, &line) catch {
            panicf(@src(), "a move's line fits in 80 bytes", .{});
        };
        u.text("{d}. {s}", .{ move_index + 1, line.buffered() });
    }
    if (move_log.len == 0) {
        u.text("no moves yet", .{});
    }

    // The inspector.
    u.separator();
    const point: Point = pointed_point orelse {
        u.text("point at the board to inspect it", .{});
        return requests;
    };
    const inspection: PointInspection = inspectPoint(position, point);
    var stone_word: []const u8 = @tagName(inspection.stone);
    if (inspection.stone == .none) {
        stone_word = "empty";
    }
    u.text("({d},{d}) - index {d} - {s}", .{ inspection.row, inspection.col, inspection.index, stone_word });
    const root: Point = inspection.root orelse {
        return requests;
    };
    var parent_buffer: [12]u8 = undefined;
    var root_buffer: [12]u8 = undefined;
    const parent_label: []const u8 = pointLabel(&parent_buffer, position.board_size, inspection.parent.?);
    const root_label: []const u8 = pointLabel(&root_buffer, position.board_size, root);
    u.text("parent {s} - root {s} - depth {d}", .{ parent_label, root_label, inspection.depth });
    var stones_word: []const u8 = "stones";
    if (inspection.group_size == 1) {
        stones_word = "stone";
    }
    var liberties_word: []const u8 = "liberties";
    if (inspection.liberty_count == 1) {
        liberties_word = "liberty";
    }
    u.text("group: {d} {s}, {d} {s}", .{
        inspection.group_size,
        stones_word,
        inspection.liberty_count,
        liberties_word,
    });
    return requests;
}

/// Starts a new game with `settings` on the game screen: the game itself, and everything that belonged to the one
/// before - a stone held, the stones in flight, the ghost, the columns' spacing, an open window, the judge's last
/// finding - cleared.
fn beginGame(s: *State, settings: NewGameSettings) void {
    // Each game its own seed, so that two games between the same players need not be the same game - and a game
    // with scattered stones, Restart included, scatters them anew.
    const game_seed: u64 = s.random.next();
    var game_settings: NewGameSettings = settings;
    game_settings.scattered.seed = game_seed;
    startGame(&s.game, game_settings);
    s.new_game_settings = settings;
    s.won_at_seconds = null;
    s.computer.startGame(game_seed);
    s.hold.putDown();
    s.flights = .none;
    s.ghost = .hidden;
    s.slot_spacing_ready = false;
    s.pause_open = false;
    s.debug.last_check = null;
    s.screen = .game;
}

/// The state a puzzle starts from, its game already started: its kind and book, nothing solved, refuted or given up
/// yet, the computer's search and the screen's stone, flights and ghost fresh.
fn resetForPuzzle(s: *State, kind: ProblemKind, tree: SolutionTree, seed: u64) void {
    s.problem_tree = tree;
    s.problem_solved_once = false;
    s.problem_refuted = false;
    s.problem_kind = kind;
    s.computer_hopeless_moves = 0;
    s.won_at_seconds = null;
    s.computer.startGame(seed);
    s.hold.putDown();
    s.flights = .none;
    s.ghost = .hidden;
    s.slot_spacing_ready = false;
    s.pause_open = false;
    s.debug.last_check = null;
    s.screen = .game;
}

/// Starts the problem `s.problem_index` names (the section's lesson): read from its SGF, drawn in a symmetry of
/// the board chosen at random, and played from its start - the person black, to move, against the computer.
fn beginProblem(s: *State) void {
    const problem_seed: u64 = s.random.next();
    const sgf: []const u8 = s.variant.problems[s.problem_index];
    const problem: Problem = readProblem(sgf) catch |err| {
        panicf(@src(), "beginProblem: problem {d} does not read ({t})", .{ s.problem_index, err });
    };
    var generator: Xoshiro256 = .init(problem_seed);
    const symmetry: Symmetry = generator.random().enumValue(Symmetry);
    const shown: Problem = transformedProblem(&problem, symmetry);
    startProblem(&s.game, &shown, .{});
    const root: SgfRoot = readSgfRoot(sgf) catch |err| {
        panicf(@src(), "beginProblem: problem {d} does not read ({t})", .{ s.problem_index, err });
    };
    var tree: SolutionTree = undefined;
    readSolutionTree(sgf, &root, &tree) catch |err| {
        panicf(@src(), "beginProblem: problem {d}'s solution does not read ({t})", .{ s.problem_index, err });
    };
    resetForPuzzle(s, problem.kind, tree.transformed(problem.setup.board_size, symmetry), problem_seed);
}

/// Starts the step `s.hero.step_index` of the round's ladder: its puzzle (`puzzleAt`), drawn in a symmetry of the
/// board chosen at random.
fn beginHeroStep(s: *State) void {
    const family: ProblemFamily = s.variant.problem_families[s.hero.family_index];
    const base: Problem = readProblem(family.sgf) catch |err| {
        panicf(@src(), "beginHeroStep: family {d} does not read ({t})", .{ s.hero.family_index, err });
    };
    const root: SgfRoot = readSgfRoot(family.sgf) catch |err| {
        panicf(@src(), "beginHeroStep: family {d} does not read ({t})", .{ s.hero.family_index, err });
    };
    var base_tree: SolutionTree = undefined;
    readSolutionTree(family.sgf, &root, &base_tree) catch |err| {
        panicf(@src(), "beginHeroStep: family {d}'s solution does not read ({t})", .{ s.hero.family_index, err });
    };
    var line_buffer: [record_limits.max_moves]Point = undefined;
    const line: []const Point = readSgfCorrectLine(family.sgf, &root, &line_buffer) catch |err| {
        panicf(@src(), "beginHeroStep: family {d}'s correct line does not read ({t})", .{ s.hero.family_index, err });
    };
    const step: PuzzleStep = s.hero.steps[s.hero.step_index];
    const puzzle: Puzzle = puzzleAt(&base, &base_tree, line, step, &s.game);
    const symmetry: Symmetry = s.random.random().enumValue(Symmetry);
    const shown: Problem = transformedProblem(&puzzle.problem, symmetry);
    startProblem(&s.game, &shown, .{});
    const board_size: u8 = base.setup.board_size;
    const search_seed: u64 = s.random.next();
    resetForPuzzle(s, puzzle.problem.kind, puzzle.tree.transformed(board_size, symmetry), search_seed);
}

/// Starts go puzzles hero's round `s.hero.round` (the section's lesson): a fight, the fixed game at the outpost
/// ladder's position; or a puzzle round, the next family's ladder opening with the round's kind - the published
/// problem when it is that kind, its twin when not.
fn beginHeroRound(s: *State) void {
    s.players = .{ .kind = .against_computer, .person_stone = .black };
    s.hero.round_failures = 0;
    s.hero.hint_point = null;
    s.hero.hint_since_seconds = null;
    if (s.hero.round == .fight) {
        const fixed_game: FixedGame = s.variant.fixed_game orelse {
            panicf(@src(), "beginHeroRound: go puzzles hero needs its fight, a fixed game", .{});
        };
        var settings: NewGameSettings = fixed_game.settings;
        if (s.variant.outpost_ladder) |ladder| {
            settings = ladder.settingsAt(settings, s.ladder_position, s.players.person_stone);
        }
        beginGame(s, settings);
        s.screen = .game;
        return;
    }
    // A family at random from the rating's window - among those that open with the round's kind (`opensWith`) -
    // not the last one again: drawn as the n-th of the window's openers, n at random.
    const families: []const ProblemFamily = s.variant.problem_families;
    const window: RatingWindow = ratingWindow(s.hero.rating, families.len, s.hero.rating_settings);
    const round_kind: ProblemKind = if (s.hero.round == .kill) .kill else .live;
    var opener_count: usize = 0;
    for (families[window.first..window.end], window.first..) |candidate, candidate_index| {
        const is_the_last: bool = candidate_index == s.hero.last_family;
        opener_count += @intFromBool(candidate.opensWith(round_kind) and !is_the_last);
    }
    const random: Random = s.random.random();
    // With no opener of the round's kind in the window, any family of it, opened as its first start allows.
    var drawn_index: usize = window.first + random.uintLessThan(usize, window.end - window.first);
    if (opener_count > 0) {
        var openers_to_pass: usize = random.uintLessThan(usize, opener_count);
        for (families[window.first..window.end], window.first..) |candidate, candidate_index| {
            const is_the_last: bool = candidate_index == s.hero.last_family;
            if (!candidate.opensWith(round_kind) or is_the_last) {
                continue;
            }
            if (openers_to_pass == 0) {
                drawn_index = candidate_index;
                break;
            }
            openers_to_pass -= 1;
        }
    }
    s.hero.family_index = drawn_index;
    s.hero.last_family = s.hero.family_index;
    s.hero.first_try = true;
    const family: ProblemFamily = families[s.hero.family_index];
    const opens_as_twin: bool = family.kind != round_kind;
    const first_is_twin: bool = if (family.starts[0].allows(opens_as_twin)) opens_as_twin else !opens_as_twin;
    const steps: []const PuzzleStep = familySteps(family, first_is_twin, &s.hero.steps);
    s.hero.step_count = steps.len;
    s.hero.step_index = 0;
    beginHeroStep(s);
}

/// Whether go puzzles hero's puzzle is lost, beyond doubt: a life puzzle's target captured, or a kill puzzle's alive
/// unconditionally (Benson's algorithm).
fn heroPuzzleIsLost(s: *const State) bool {
    const target: Point = s.game.position.target orelse {
        return false;
    };
    if (s.game.position.winner) |winner| {
        return winner == .white;
    }
    const kill_target_lives: bool = s.problem_kind == .kill and isUnconditionallyAlive(&s.game.position, target);
    return kill_target_lives;
}

/// Go puzzles hero's progress as saved (`HeroProgress`): under the variant's progress key, or - from an earlier
/// version, which kept the count of wins alone, as four little-endian bytes - that count; nothing at all when neither
/// is there.
fn loadHeroProgress(variant: AppVariant) HeroProgress {
    var bytes: [HeroProgress.byte_count]u8 = undefined;
    if (z.loadValue(variant.hero_progress_key, &bytes)) |saved| {
        if (HeroProgress.fromBytes(saved)) |progress| {
            return progress;
        }
    }
    var wins_bytes: [4]u8 = undefined;
    const earlier: []u8 = z.loadValue(variant.hero_earlier_wins_key, &wins_bytes) orelse {
        return .{};
    };
    if (earlier.len != wins_bytes.len) {
        return .{};
    }
    return .{ .wins = readInt(u32, &wins_bytes, .little) };
}

/// Saves go puzzles hero's progress (`HeroProgress`, `z.saveValue`): after every change to it.
fn saveHeroProgress(s: *const State) void {
    const progress: HeroProgress = .{
        .wins = s.hero.wins,
        .rating = s.hero.rating,
        .ladder_position = s.ladder_position,
        .unlocked = s.hero.unlocked,
    };
    const bytes: [HeroProgress.byte_count]u8 = progress.toBytes();
    z.saveValue(s.variant.hero_progress_key, &bytes);
}

/// One more win for go puzzles hero, saved at once - and, filling the row of progress's last place, its reward due
/// (`RewardSettings`).
fn countHeroWin(s: *State) void {
    s.hero.wins +|= 1;
    saveHeroProgress(s);
    const places: u32 = @max(s.controls.progress_places, 1);
    const fills_the_row: bool = s.hero.wins % places == 0;
    if (fills_the_row and s.variant.reward_images.len > 0) {
        s.hero.reward_due = true;
    }
}

/// The hint's move in go puzzles hero's puzzle (`HintSettings`): the book's first correct move after the moves so far,
/// while they follow the book; else - off the book, or a problem without one - the search's choice for the player
/// to move, from a search of `hint.search_iterations`. Null when neither has a move.
fn heroHintMove(s: *State) ?Point {
    const record: *const Record = &s.game.record;
    const moves: []const Point = record.moves[0..record.moves_played];
    const has_book: bool = s.problem_tree.node_count > 0;
    if (has_book) {
        var reply_buffer: [board_limits.max_points]Point = undefined;
        const book_moves: []const Point = s.problem_tree.repliesAfter(moves, &reply_buffer);
        if (book_moves.len > 0) {
            return book_moves[0];
        }
    }
    const iterations: u32 = s.hero.hint.search_iterations;
    const node_buffer: []SearchNode = s.gpa.alloc(SearchNode, iterations + 1) catch {
        return null;
    };
    defer s.gpa.free(node_buffer);
    const search_settings: SearchSettings = s.computer_settings.search;
    const seed: u64 = s.random.next();
    const tree: SearchTree = continueSearch(s.gpa, record, null, node_buffer, iterations, seed, search_settings) catch {
        return null;
    };
    return chosenMove(&tree, search_settings);
}

/// Whether go puzzles hero's reward is under way (`RewardSettings`): the game waits for it.
fn heroRewardIsUp(s: *const State) bool {
    return s.hero.reward_since_seconds != null;
}

/// The level and progress go puzzles hero shows (`heroLevel`): while a reward is under way, the level before it and
/// the row full - the last stone seen - and after it the level risen and the row empty.
fn heroShownLevel(s: *const State) HeroLevel {
    const places: u8 = s.controls.progress_places;
    const level: HeroLevel = heroLevel(s.hero.wins, places);
    const completing: bool = heroRewardIsUp(s) and level.filled == 0 and s.hero.wins > 0;
    if (completing) {
        return .{ .level = level.level - 1, .filled = places };
    }
    return level;
}

/// Moves go puzzles hero's reward on (`rewardPhase`), at `now_seconds`: started when due; its picture drawn at
/// random and decoded once it is to show - and a picture that will not decode ends the reward; freed and the reward
/// over when its time is up.
fn updateHeroReward(s: *State, gl: *z.WgpuGl, now_seconds: f32) void {
    if (s.hero.reward_due) {
        s.hero.reward_due = false;
        s.hero.reward_since_seconds = now_seconds;
    }
    const since_seconds: f32 = s.hero.reward_since_seconds orelse return;
    const phase: RewardPhase = rewardPhase(now_seconds - since_seconds, s.variant.reward);
    switch (phase) {
        .waiting => {},
        .showing => if (s.hero.reward_texture == null) {
            const images: []const []const u8 = s.variant.reward_images;
            const image_index: usize = s.random.random().uintLessThan(usize, images.len);
            const image: z.Image = z.loadImageFromMemory(s.gpa, images[image_index]) catch |err| {
                std.log.err("go puzzles hero: reward picture {d} does not decode ({t})", .{ image_index, err });
                s.hero.reward_since_seconds = null;
                return;
            };
            s.hero.reward_texture = z.loadTextureFromImage(gl, image);
            z.unloadImage(s.gpa, image);
            s.stone_sounds.playReward();
        },
        .over => {
            if (s.hero.reward_texture) |*texture| {
                texture.deinit();
            }
            s.hero.reward_texture = null;
            s.hero.reward_since_seconds = null;
        },
    }
}

/// go puzzles hero's reward picture, `show_seconds` into its show (`rewardOffset`, `rewardBackdropAlpha`): a black
/// backdrop over the window, as dark as the moment says, and the picture as large as fits whole, centred across and
/// moved down by its offset - above the window coming in, below it going out.
fn drawHeroReward(
    gl: *z.WgpuGl,
    texture: z.WgpuTexture,
    show_seconds: f32,
    settings: RewardSettings,
    window_width_px: f32,
    window_height_px: f32,
) void {
    const backdrop: z.Rectangle = .{ .x = 0, .y = 0, .width = window_width_px, .height = window_height_px };
    const backdrop_alpha: u8 = @round(255 * rewardBackdropAlpha(show_seconds, settings));
    gl.rect(backdrop, .{ .color = .{ .r = 0, .g = 0, .b = 0, .a = backdrop_alpha } });
    const offset_px: f32 = rewardOffset(show_seconds, settings) * window_height_px;
    const picture_width_px: f32 = float(texture.width);
    const picture_height_px: f32 = float(texture.height);
    const scale: f32 = @min(window_width_px / picture_width_px, window_height_px / picture_height_px);
    const drawn_width_px: f32 = picture_width_px * scale;
    const drawn_height_px: f32 = picture_height_px * scale;
    const destination: z.Rectangle = .{
        .x = (window_width_px - drawn_width_px) / 2,
        .y = (window_height_px - drawn_height_px) / 2 + offset_px,
        .width = drawn_width_px,
        .height = drawn_height_px,
    };
    gl.texture(destination, texture, .{});
}

/// Whether go puzzles hero's paywall is up (`Paywall`): this session has played its free games and the password has
/// never been typed. The game waits behind it.
fn heroPaywallIsUp(s: *const State) bool {
    const paywall: Paywall = s.variant.paywall orelse {
        return false;
    };
    return !s.hero.unlocked and s.hero.session_games >= paywall.free_games;
}

/// The paywall's window, centred (`Paywall`): its message, its link - opened in a new tab - and the password box, its
/// characters hidden. Returns the box's text.
fn submitPaywallWindow(
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    controls: ControlsStyle,
    window_heights: *CentredWindowHeights,
    paywall: Paywall,
    password_buffer: []u8,
    password_length: *usize,
) []const u8 {
    const width_px: f32 = controls.pause_window_width_fonts * font_size_px;
    const maybe_window: ?CentredWindow = openCentredWindow(
        u,
        "Support",
        window_width_px,
        window_height_px,
        width_px,
        font_size_px,
        controls.edge_gap_fonts * font_size_px,
        &window_heights.paywall,
        &window_heights.tallest,
    );
    const window: CentredWindow = maybe_window orelse {
        return password_buffer[0..password_length.*];
    };
    defer window.close();
    u.textWrapped("{s}", .{paywall.message});
    _ = u.textLinkOpenURL(paywall.link_label, paywall.url);
    u.separator();
    u.text("Password", .{});
    _ = u.inputText("##paywall password", password_buffer, password_length, .{ .password_mask = true });
    return password_buffer[0..password_length.*];
}

/// Draws go puzzles hero's next round (`nextRound`), the draw the session's next number (`State.random`).
fn drawNextRound(s: *State) void {
    const draw: f32 = s.random.random().float(f32);
    s.hero.round = nextRound(s.hero.round, s.hero.round_chances, draw);
}

/// Moves the outpost ladder by a fight that `winner` won (`OutpostLadder.nextPosition`).
fn moveHeroLadder(s: *State, winner: Stone) void {
    const ladder: OutpostLadder = s.variant.outpost_ladder orelse {
        return;
    };
    const board_size: u8 = s.game.position.board_size;
    s.ladder_position = ladder.nextPosition(board_size, s.ladder_position, winner, s.players.person_stone);
    saveHeroProgress(s);
}

/// What a problem's game has shown so far, for `isProblemSolved` to judge.
pub const ProblemEvidence = struct {
    kind: ProblemKind,
    /// The computer's last searched move says the player's has undone the solution.
    refuted: bool,
    /// How many of the computer's searched moves in a row won less often than its giving-up rate.
    hopeless_moves: u8,
};

/// Whether a problem is solved (the section's lesson). A captured target decides it: solved when it was white's, the
/// kill done; not, when it was black's, the group lost. Otherwise it is solved when the moves pass through a node of
/// the solution tree the book calls correct and the computer has not refuted them since; in a life problem, when the
/// target is alive unconditionally (Benson's algorithm); and in either, when the computer has given up - its searched
/// moves winning too seldom, `settings.giving_up_moves` times in a row. Moves after a solution keep it so: the player
/// may play on to see why it works.
pub fn isProblemSolved(
    position: *const Position,
    tree: *const SolutionTree,
    moves: []const Point,
    evidence: ProblemEvidence,
    settings: ProblemPlaySettings,
) bool {
    if (position.winner) |winner| {
        return winner == .black;
    }
    if (tree.isSolvedBy(moves) and !evidence.refuted) {
        return true;
    }
    if (evidence.kind == .live) {
        if (position.target) |target| {
            if (isUnconditionallyAlive(position, target)) {
                return true;
            }
        }
    }
    return evidence.hopeless_moves >= settings.giving_up_moves;
}

/// Whether the game being played is a problem - it has a target - in whichever app: goban problems' or go puzzles
/// hero's, whose puzzles are problems though its variant lists none.
fn gameIsProblem(s: *const State) bool {
    return s.game.record.target != null;
}

/// Whether the problem being played is solved (`isProblemSolved`).
fn problemIsSolved(s: *const State) bool {
    if (!gameIsProblem(s)) {
        return false;
    }
    const moves: []const Point = s.game.record.moves[0..s.game.record.moves_played];
    const evidence: ProblemEvidence = .{
        .kind = s.problem_kind,
        .refuted = s.problem_refuted,
        .hopeless_moves = s.computer_hopeless_moves,
    };
    return isProblemSolved(&s.game.position, &s.problem_tree, moves, evidence, s.problem_play);
}

/// The book's reply to the moves of the problem being played, when its solution tree has one there and it is
/// legal - one of several drawn at random - or null.
fn bookReply(s: *State) ?Point {
    const moves: []const Point = s.game.record.moves[0..s.game.record.moves_played];
    var reply_buffer: [board_limits.max_points]Point = undefined;
    const replies: []const Point = s.problem_tree.repliesAfter(moves, &reply_buffer);
    if (replies.len == 0) {
        return null;
    }
    const reply: Point = replies[s.random.random().uintLessThan(usize, replies.len)];
    if (checkMove(&s.game.position, reply) != .legal) {
        return null;
    }
    return reply;
}

/// How many moves the board's Undo takes back (the section's lesson): the last move between two players; against the
/// computer, the moves back to just before the person's last - two when the computer has replied, one while it is
/// still thinking, none before the person's first move, the computer having played black; none between two
/// computers, whose game the pause window stops instead.
fn movesUndoTakesBack(players: Players, record: *const Record) u16 {
    switch (players.kind) {
        .two_players => {
            const has_a_move: bool = record.moves_played > 0;
            return @intFromBool(has_a_move);
        },
        .computer_against_computer => return 0,
        .against_computer => {
            var move_index: u16 = record.moves_played;
            while (move_index > 0) {
                move_index -= 1;
                const is_person_move: bool = moverOfMove(record, move_index) == players.person_stone;
                if (is_person_move) {
                    return record.moves_played - move_index;
                }
            }
            return 0;
        },
    }
}

/// Takes back what the board's Undo takes back (`movesUndoTakesBack`) - the Undo button's and the side button's one
/// way of doing it (G10): a stone held is put back, and the stones in flight land at once, since they belong to the
/// position that was. A search under way for the computer sees the record change, and ends.
fn takeBackMove(s: *State) void {
    const moves_to_take_back: u16 = movesUndoTakesBack(s.players, &s.game.record);
    for (0..moves_to_take_back) |_| {
        _ = undo(&s.game);
    }
    s.hold.putDown();
    s.flights = .none;
}

/// The judge's check after a move (section 5), when the debug panel asks for it: the forest the moves built is compared
/// with a flood fill of the stones alone. What it finds is kept for the panel, and a disagreement asserts - it is a
/// fault in the forest's code, never in the player's moves.
fn verifyForest(s: *State) void {
    const disagreement: ?Disagreement = findDisagreement(&s.game.position);
    s.debug.last_check = .{ .after_move = s.game.record.moves_played, .disagreement = disagreement };
    if (disagreement) |found| {
        assertUnreachable(@src(), "the forest disagrees with the stones after move {d}: {f}", .{
            s.game.record.moves_played,
            found,
        });
    }
}

/// What follows a move, whoever played it: its report logged for the debug panel, its sound, the judge's check when the
/// debug panel asks for it, and the stones it captured sent flying to the capturer's column.
fn afterMovePlayed(s: *State, report: MoveReport) void {
    s.move_log[s.game.record.moves_played - 1] = report;
    if (s.sound_on) {
        s.stone_sounds.playFor(report);
    }
    if (s.debug.verify_every_move) {
        verifyForest(s);
    }
    const stones_captured: bool = report.captured_count > 0;
    if (stones_captured) {
        const prisoners_now: u32 = prisonersOf(&s.game.position, report.mover);
        const prisoners_before: u32 = prisoners_now - report.captured_count;
        s.flights.launch(report, prisoners_before, s.style);
    }
}

/// Copies `position` to the clipboard as a diagram (section 6): what a test's diagram is written as, so a position seen
/// in the app becomes a test with one paste.
fn copyDiagram(position: *const Position) void {
    // A 19 x 19 diagram is 19 lines of 38 bytes and a turn line: 1 KB holds it.
    var diagram_buffer: [1024]u8 = undefined;
    var diagram: Io.Writer = .fixed(&diagram_buffer);
    writeDiagram(position, &diagram) catch {
        panicf(@src(), "a diagram fits in 1024 bytes", .{});
    };
    z.setClipboardText(diagram.buffered());
}

/// Loads pasted text as a position, if it is a diagram (section 6), and says in the debug panel's note what it did: a
/// new game from that position - the hold, flights, ghost, columns and judge's finding of the old one cleared - or why
/// the text was not a diagram, the game left as it was.
fn loadPastedDiagram(s: *State, pasted: []const u8) void {
    var note: Io.Writer = .fixed(&s.debug.paste_note);
    switch (readDiagram(pasted)) {
        .setup => |setup| {
            startGameFromDiagram(&s.game, &setup);
            s.hold.putDown();
            s.flights = .none;
            s.ghost = .hidden;
            s.slot_spacing_ready = false;
            s.debug.last_check = null;
            // lint:off catch-suppression: a note longer than its buffer keeps the part that fits - enough to read
            note.print("pasted: a {d} x {d} position", .{ setup.board_size, setup.board_size }) catch {};
        },
        .problem => |problem| {
            // lint:off catch-suppression: a note longer than its buffer keeps the part that fits - enough to read
            note.print("not a diagram: {f}", .{problem}) catch {};
        },
    }
    s.debug.paste_note_length = note.buffered().len;
}

/// Plays again the next move undone: as with takeBackMove, a stone held is put back and the flights land.
fn stepForward(s: *State) void {
    _ = redo(&s.game);
    s.hold.putDown();
    s.flights = .none;
}

/// Moves the position along the record to `moves_played` moves (the debug panel's timeline), as many undos or redos
/// would.
fn jumpToMove(s: *State, moves_played: u16) void {
    replayTo(&s.game, moves_played);
    s.hold.putDown();
    s.flights = .none;
}

/// One frame of the main menu: the menu over the wood, and what it asks for.
fn updateMainMenu(
    f: *z.Frame,
    s: *State,
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
) void {
    const choice: MainMenuChoice = submitMainMenu(
        u,
        &s.menu,
        window_width_px,
        window_height_px,
        font_size_px,
        s.controls,
        &s.window_heights,
    );
    switch (choice) {
        .none => {},
        .start => {
            s.players = s.menu.players();
            beginGame(s, s.menu.settings());
        },
        .quit => {
            if (comptime z.host.drives_own_frames) {
                z.requestQuit();
            }
        },
    }
    drawWood(f.gl, s.textures.wood, window_width_px, window_height_px);
}

/// One frame of the game screen, in the order the section's lesson gives; the interface is begun and rendered by
/// `update`.
/// Submits the game screen's interface (the section's lesson): the board's two buttons, disabled while a window is
/// open (G11), the open window, and the debug panel - writing what they ask for into `presses`, `pause_choice`,
/// `victory_choice` and `debug_requests`, for the game screen to carry out.
fn submitInterface(
    f: *z.Frame,
    s: *State,
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
    window_is_open: bool,
    presses: *ButtonPresses,
    pause_choice: *PauseChoice,
    victory_choice: *VictoryChoice,
    debug_requests: *DebugRequests,
) void {
    u.beginDisabled(window_is_open);
    const undo_takes_something_back: bool = movesUndoTakesBack(s.players, &s.game.record) > 0;
    presses.* = submitGameButtons(
        u,
        window_width_px,
        window_height_px,
        font_size_px,
        s.controls,
        undo_takes_something_back,
    );
    u.endDisabled();
    if (s.pause_open) {
        pause_choice.* = submitPauseWindow(
            u,
            window_width_px,
            window_height_px,
            font_size_px,
            s.controls,
            &s.window_heights,
            &s.overlays,
            &s.sound_on,
            &s.debug.open,
        );
    }
    if (s.game.position.winner) |winner| {
        victory_choice.* = submitVictoryWindow(
            u,
            winner,
            s.players.kind == .two_players,
            window_width_px,
            window_height_px,
            font_size_px,
            s.controls,
            &s.window_heights,
        );
    }
    // H opens and closes the debug panel; the pause window has a switch for it too.
    if (z.isKeyPressed(f.input, .h)) {
        s.debug.open = !s.debug.open;
    }
    if (s.debug.open) {
        const log_shown: []const MoveReport = s.move_log[0..s.game.record.moves_played];
        debug_requests.* = submitDebugPanel(
            u,
            &s.game,
            &s.computer,
            s.computer_settings,
            log_shown,
            s.debug.inspected_point,
            &s.debug,
            font_size_px,
        );
    }
}

/// A problem's buttons, for one frame (the section's lesson): Undo and Next, which work after the win too - Undo takes
/// the win back, Next goes on to the next problem - and "Solved". Whether the pointer is over them.
fn updateProblemButtons(
    s: *State,
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
) bool {
    const undo_takes_something_back: bool = movesUndoTakesBack(s.players, &s.game.record) > 0;
    const problem_is_solved: bool = problemIsSolved(s);
    if (problem_is_solved) {
        s.problem_solved_once = true;
    }
    // The task, until the first move: what the player is to do with the marked stone.
    const before_first_move: bool = s.game.record.moves_played == 0;
    const task_name: []const u8 = if (s.problem_kind == .kill) "Kill" else "Live";
    const task_label: ?[]const u8 = if (before_first_move) task_name else null;
    const problem_presses: ProblemPresses = submitProblemButtons(
        u,
        window_width_px,
        window_height_px,
        font_size_px,
        s.controls,
        undo_takes_something_back,
        problem_is_solved,
        s.problem_solved_once,
        task_label,
    );
    const pointer_is_over: bool = u.wantCaptureMouse();
    if (problem_presses.undo) {
        takeBackMove(s);
        // The computer's judgement was of a later position: the book's path decides again.
        s.problem_refuted = false;
        s.computer_hopeless_moves = 0;
    }
    if (problem_presses.next) {
        s.problem_index = (s.problem_index + 1) % s.variant.problems.len;
        beginProblem(s);
    }
    return pointer_is_over;
}

/// Whether a problem's target shares the problem's region with other stones of its colour, not of its group
/// (the section's lesson): then which group the problem is about is not plain from the position, and go puzzles hero
/// marks it. False when there is no target.
fn targetHasCompany(position: *const Position) bool {
    const target: Point = position.target orelse return false;
    const colour: Stone = position.stones[target];
    if (colour == .none) {
        return false;
    }
    const target_root: Point = findRoot(position, target);
    const region: ProblemRegion = playableRegion(position);
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const point: Point = pointAt(position.board_size, @intCast(row), @intCast(col));
            const is_company: bool = position.stones[point] == colour and findRoot(position, point) != target_root;
            if (is_company) {
                return true;
            }
        }
    }
    return false;
}

/// Whether go puzzles hero's game waits for the player's first move: the record's first move when the player
/// starts, its second when the computer does. Until then the round's kind shows across the top, and in a puzzle its
/// target is marked - which group the puzzle is about, plain before the play begins.
fn heroAwaitsFirstMove(s: *const State) bool {
    const player_starts: bool = s.game.record.setup_to_play == s.players.person_stone;
    const moves_before_players: u32 = if (player_starts) 0 else 1;
    return s.game.record.moves_played <= moves_before_players;
}

/// The lines of go puzzles hero's debug text (`HeroState.debug_shown`), written into `out_buffer` and listed in
/// `lines_buffer`: what a screenshot needs to tell what the game is doing - the round and the session; in a puzzle
/// the problem's file, level, difficulty, ladder step and kind, the target's group and whether Benson's proof finds
/// it alive, whether play is still on the book's line, the computer's last win rate and its judgements, and the
/// rating's window; in a fight the ladder and the computer's last win rate.
fn heroDebugLines(
    s: *const State,
    out_buffer: []u8,
    lines_buffer: [][]const u8,
) []const []const u8 {
    var written: usize = 0;
    var line_count: usize = 0;
    const Line = struct {
        fn add(
            buffer: []u8,
            used: *usize,
            lines: [][]const u8,
            count: *usize,
            comptime fmt: []const u8,
            args: anytype,
        ) void {
            const text: []const u8 = bufPrint(buffer[used.*..], fmt, args) catch return;
            if (count.* < lines.len) {
                lines[count.*] = text;
                count.* += 1;
            }
            used.* += text.len;
        }
    };
    const record: *const Record = &s.game.record;
    const position: *const Position = &s.game.position;
    const families: []const ProblemFamily = s.variant.problem_families;
    const window: RatingWindow = ratingWindow(s.hero.rating, families.len, s.hero.rating_settings);
    Line.add(out_buffer, &written, lines_buffer, &line_count, "round {t}; session games {d}; moves {d}", .{
        s.hero.round,
        s.hero.session_games,
        record.moves_played,
    });
    Line.add(out_buffer, &written, lines_buffer, &line_count, "rating {d:.3}; window {d}-{d} of {d}", .{
        s.hero.rating,
        window.first,
        window.end,
        families.len,
    });
    const win_rate: f32 = s.computer.lastMoveWinRate();
    if (s.hero.round == .fight) {
        Line.add(out_buffer, &written, lines_buffer, &line_count, "ladder position {d}; computer {d:.0}%", .{
            s.ladder_position,
            100 * win_rate,
        });
        return lines_buffer[0..line_count];
    }
    const family: ProblemFamily = families[s.hero.family_index];
    const step: PuzzleStep = s.hero.steps[s.hero.step_index];
    Line.add(out_buffer, &written, lines_buffer, &line_count, "{s} {t}, difficulty {d}", .{
        family.name,
        family.level,
        family.difficulty,
    });
    Line.add(out_buffer, &written, lines_buffer, &line_count, "step {d} of {d}, after {d} moves{s}; {t}", .{
        s.hero.step_index + 1,
        s.hero.step_count,
        step.start_moves,
        if (step.is_twin) ", twin" else "",
        s.problem_kind,
    });
    if (position.target) |target| {
        const board_size: u8 = position.board_size;
        const stands: bool = position.stones[target] != .none;
        if (stands) {
            const root: Point = findRoot(position, target);
            const stone_count: usize = position.group_stones[root].count();
            const liberty_count: usize = regionLibertyCount(position, root);
            const alive: bool = isUnconditionallyAlive(position, target);
            const target_format: []const u8 = "target row {d} col {d}: {d} stones, {d} lib, alive {}";
            Line.add(out_buffer, &written, lines_buffer, &line_count, target_format, .{
                rowOf(board_size, target),
                colOf(board_size, target),
                stone_count,
                liberty_count,
                alive,
            });
        } else {
            Line.add(out_buffer, &written, lines_buffer, &line_count, "target row {d} col {d}: captured", .{
                rowOf(board_size, target),
                colOf(board_size, target),
            });
        }
    }
    const moves: []const Point = record.moves[0..record.moves_played];
    const has_book: bool = s.problem_tree.node_count > 0;
    const on_book: bool = has_book and (moves.len == 0 or s.problem_tree.nodeAfter(moves) != null);
    Line.add(out_buffer, &written, lines_buffer, &line_count, "book {s}; solved {}, lost {}", .{
        if (!has_book) "none" else if (on_book) "followed" else "left",
        problemIsSolved(s),
        heroPuzzleIsLost(s),
    });
    Line.add(out_buffer, &written, lines_buffer, &line_count, "computer {d:.0}%; gives up {d} of {d}; refuted {}", .{
        100 * win_rate,
        s.computer_hopeless_moves,
        s.problem_play.giving_up_moves,
        s.problem_refuted,
    });
    // Where the computer's search runs and how many iterations its last move had in its time: on a phone, the
    // measure of how strongly it can play there.
    const search_place: []const u8 = switch (s.computer.search) {
        .jobs => JobSearch.place,
        .frames => "the frames",
    };
    Line.add(out_buffer, &written, lines_buffer, &line_count, "search on {s}: {d} iterations in {d:.0} ms", .{
        search_place,
        s.computer.lastMoveIterations(),
        s.computer_settings.move_milliseconds,
    });
    return lines_buffer[0..line_count];
}

/// Go puzzles hero's buttons, for one frame (the section's lesson): the hint, once the round's problem has been failed
/// often enough (`HintSettings`), and Next, once a puzzle is solved (up the ladder) or lost (down it); the count of
/// wins, and a puzzle's kind until the first move. Whether the pointer is over them.
fn updateHeroButtons(
    s: *State,
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
) bool {
    // A reward's picture fills the window: no button, no label over it, and the pointer the picture's.
    if (s.hero.reward_texture != null) {
        return true;
    }
    const in_puzzle: bool = s.hero.round != .fight;
    const solved: bool = in_puzzle and problemIsSolved(s);
    const lost: bool = in_puzzle and !solved and heroPuzzleIsLost(s);
    // A win counts once: the round's full problem solved at its first try - not a step of the ladder after a
    // failure.
    if (solved and !s.problem_solved_once) {
        s.problem_solved_once = true;
        if (s.hero.step_index == 0 and s.hero.first_try) {
            countHeroWin(s);
        }
    }
    // The level in the top-left corner; the wins since it began in the row of progress along the bottom.
    const level: HeroLevel = heroShownLevel(s);
    var label_buffer: [16]u8 = undefined;
    const label: []const u8 = bufPrint(&label_buffer, "{d}", .{level.level}) catch "";
    s.hero.progress_row = heroProgressRow(window_width_px, window_height_px, font_size_px, s.controls);
    // The line across the top: "Solved" or "Failed" once the puzzle is - with Next beside it - and before that, until
    // the player's first move, the round's kind: "Live" or "Kill" in a puzzle, "Fight" in a fight.
    const awaits_first_move: bool = heroAwaitsFirstMove(s);
    const puzzle_kind_name: []const u8 = if (s.problem_kind == .kill) "Kill" else "Live";
    const round_name: []const u8 = if (in_puzzle) puzzle_kind_name else "Fight";
    const kind_line: ?[]const u8 = if (awaits_first_move) round_name else null;
    // Lost beyond doubt - a kill puzzle's group alive with two eyes, a life puzzle's captured: "Failed".
    const outcome_line: ?[]const u8 = if (solved) "Solved" else if (lost) "Failed" else null;
    const top_line: ?[]const u8 = outcome_line orelse kind_line;
    const failed_enough: bool = s.hero.round_failures >= s.hero.hint.after_failures;
    const shows_hint: bool = in_puzzle and !solved and !lost and failed_enough;
    var debug_text_buffer: [1024]u8 = undefined;
    var debug_line_buffer: [8][]const u8 = undefined;
    const no_lines: []const []const u8 = &.{};
    const debug_lines: []const []const u8 = if (s.hero.debug_shown)
        heroDebugLines(s, &debug_text_buffer, &debug_line_buffer)
    else
        no_lines;
    const hero_presses: HeroPresses = submitHeroButtons(
        u,
        window_width_px,
        window_height_px,
        font_size_px,
        s.controls,
        shows_hint,
        solved or lost,
        label,
        top_line,
        debug_lines,
    );
    if (hero_presses.debug_toggle) {
        s.hero.debug_shown = !s.hero.debug_shown;
    }
    if (hero_presses.hint) {
        s.hero.hint_point = heroHintMove(s);
        s.hero.hint_due = s.hero.hint_point != null;
    }
    if (heroPaywallIsUp(s)) {
        const paywall: Paywall = s.variant.paywall.?;
        const typed: []const u8 = submitPaywallWindow(
            u,
            window_width_px,
            window_height_px,
            font_size_px,
            s.controls,
            &s.window_heights,
            paywall,
            &s.hero.password_buffer,
            &s.hero.password_length,
        );
        // The password typed: the paywall gone for good, kept with the player's progress.
        if (eql(u8, typed, paywall.password)) {
            s.hero.unlocked = true;
            saveHeroProgress(s);
        }
    }
    const pointer_is_over: bool = u.wantCaptureMouse();
    // A puzzle left, solved or failed: one more of the session's games.
    if (hero_presses.next) {
        s.hero.session_games +|= 1;
    }
    if (hero_presses.next) {
        // A puzzle over: its ladder's next step, or - the full problem solved - the next round. The full problem's
        // first try moves the rating, saved.
        const outcome: HeroOutcome = if (solved) .solved else .given_up;
        if (outcome == .given_up) {
            s.hero.round_failures +|= 1;
        }
        if (s.hero.step_index == 0 and s.hero.first_try) {
            const solved_first_try: bool = outcome == .solved;
            s.hero.failure_streak = if (solved_first_try) 0 else s.hero.failure_streak +| 1;
            const streak: u8 = s.hero.failure_streak;
            s.hero.rating = ratedPlace(s.hero.rating, solved_first_try, streak, s.hero.rating_settings);
            s.hero.first_try = false;
            saveHeroProgress(s);
        }
        // The ladder's next step - or, the full problem solved or a step failed too often in a row, the next round
        // (`heroStepAfter`).
        const step_move: HeroStepMove = heroStepAfter(
            s.hero.step_index,
            s.hero.step_count,
            outcome,
            s.hero.step_failures,
            s.hero.flow,
        );
        s.hero.step_failures = step_move.step_failures;
        if (step_move.next_step) |step_index| {
            s.hero.step_index = step_index;
            beginHeroStep(s);
        } else {
            drawNextRound(s);
            beginHeroRound(s);
        }
    }
    return pointer_is_over;
}

/// The restart a variant makes of a won game (the section's lesson), a while after the win: the game's own settings
/// again - its scattered stones drawn anew, and with an outpost ladder the next game the result leads to - or, in go
/// puzzles hero, the fight's win counted and its next round.
fn restartAfterWin(s: *State, now_seconds: f32, restart_delay_seconds: f32) void {
    if (s.game.position.winner != null) {
        const won_at_seconds: f32 = s.won_at_seconds orelse now_seconds;
        s.won_at_seconds = won_at_seconds;
        const waited_seconds: f32 = now_seconds - won_at_seconds;
        const is_hero_fight: bool = s.variant.hero and s.hero.round == .fight;
        if (waited_seconds >= restart_delay_seconds and is_hero_fight) {
            // Go puzzles hero's fight over: a win counted, one more of the session's games, the ladder moved by its
            // result, and the next round.
            s.hero.session_games +|= 1;
            const fight_winner: Stone = s.game.position.winner.?;
            if (fight_winner == s.players.person_stone) {
                countHeroWin(s);
            }
            moveHeroLadder(s, fight_winner);
            drawNextRound(s);
            beginHeroRound(s);
        } else if (waited_seconds >= restart_delay_seconds and !s.variant.hero) {
            // With a ladder, the result moves the person up or down it before the next game.
            var next_settings: NewGameSettings = s.new_game_settings;
            if (s.variant.outpost_ladder) |ladder| {
                const winner: Stone = s.game.position.winner.?;
                const person_stone: Stone = s.players.person_stone;
                const board_size: u8 = next_settings.board_size;
                s.ladder_position = ladder.nextPosition(board_size, s.ladder_position, winner, person_stone);
                next_settings = ladder.settingsAt(next_settings, s.ladder_position, person_stone);
            }
            beginGame(s, next_settings);
        }
    }
}

/// The computer's turn, for one frame (the section's lesson): its search goes on frame after frame while no window is
/// open, and its move, when it comes, is played as a person's would be - in a problem on the book's line the book's
/// reply, with no search. When it is not the computer's turn - after an undo, say - a search under way is ended.
fn playComputerTurn(s: *State, window_is_open: bool) void {
    const computer_to_play: bool = s.players.computerToPlay(&s.game.position);
    if (!computer_to_play) {
        s.computer.stopSearch();
    }
    if (computer_to_play and !window_is_open) {
        // In a problem on the book's line, the book's reply, with no search; off it, the search's.
        const follows_book: bool = gameIsProblem(s) and s.variant.computer_follows_book;
        const book_move: ?Point = if (follows_book) bookReply(s) else null;
        const clock: *const fn () f64 = z.monotonicMilliseconds;
        const computer_move: ?Point = book_move orelse s.computer.step(&s.game, s.computer_settings, clock);
        // A searched move's win rate says whether the player's last move undid the solution, and whether the computer
        // has given up; a book reply says neither.
        const searched: bool = book_move == null;
        const win_rate: f32 = s.computer.lastMoveWinRate();
        if (computer_move != null and gameIsProblem(s)) {
            s.problem_refuted = searched and win_rate >= s.problem_play.refuting_win_rate;
            const hopeless: bool = searched and win_rate < s.problem_play.giving_up_win_rate;
            s.computer_hopeless_moves = if (hopeless) s.computer_hopeless_moves +| 1 else 0;
        }
        if (computer_move) |move| {
            const report: MoveReport = playMove(&s.game, move);
            afterMovePlayed(s, report);
        }
    }
}

fn updateGame(
    f: *z.Frame,
    s: *State,
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    font_size_px: f32,
) void {
    // The interface the variant has (`AppVariant.interface`): the whole of it; none, the board alone, whose buttons,
    // windows and panel ask for nothing; or a problem's two buttons.
    const has_interface: bool = s.variant.interface == .full;
    const game_was_won: bool = s.game.position.winner != null;
    var presses: ButtonPresses = .{ .menu = false, .undo = false };
    var pause_choice: PauseChoice = .none;
    var victory_choice: VictoryChoice = .none;
    var debug_requests: DebugRequests = .{};
    var interface_has_pointer: bool = false;
    if (has_interface) {
        // Escape opens and closes the pause window - not over a won game, whose victory window is open instead.
        const escape_pressed: bool = z.isKeyPressed(f.input, .escape);
        if (escape_pressed and !game_was_won) {
            s.pause_open = !s.pause_open;
        }
        submitInterface(
            f,
            s,
            u,
            window_width_px,
            window_height_px,
            font_size_px,
            s.pause_open or game_was_won,
            &presses,
            &pause_choice,
            &victory_choice,
            &debug_requests,
        );
        interface_has_pointer = u.wantCaptureMouse();
    }
    if (s.variant.interface == .problem_buttons) {
        interface_has_pointer = updateProblemButtons(s, u, window_width_px, window_height_px, font_size_px);
    }
    if (s.variant.interface == .hero_buttons) {
        interface_has_pointer = updateHeroButtons(s, u, window_width_px, window_height_px, font_size_px);
    }
    if (s.variant.hero) {
        updateHeroReward(s, f.gl, f.time.time);
        if (s.hero.hint_due) {
            s.hero.hint_due = false;
            s.hero.hint_since_seconds = f.time.time;
        }
    }
    const window_was_open: bool = s.pause_open or s.game.position.winner != null or heroPaywallIsUp(s) or
        heroRewardIsUp(s);

    if (s.variant.restart_after_win_seconds) |restart_delay_seconds| {
        restartAfterWin(s, f.time.time, restart_delay_seconds);
    }

    // Carry out what the buttons, the side button and the windows asked.
    const side_button_pressed: bool = has_interface and z.isMouseButtonPressed(f.input, .side);
    if (!window_was_open) {
        if (presses.menu) {
            s.pause_open = true;
        }
        if (presses.undo or side_button_pressed) {
            takeBackMove(s);
        }
    }
    switch (pause_choice) {
        .none => {},
        .return_to_game => {
            s.pause_open = false;
        },
        .restart => {
            beginGame(s, s.new_game_settings);
        },
        .return_to_main_menu => {
            s.pause_open = false;
            s.screen = .main_menu;
        },
        .quit_to_desktop => {
            if (comptime z.host.drives_own_frames) {
                z.requestQuit();
            }
        },
    }
    // The debug panel's controls work while a window is open: undoing the winning capture is how a win is looked at
    // again.
    if (debug_requests.undo) {
        takeBackMove(s);
    }
    if (debug_requests.redo) {
        stepForward(s);
    }
    if (debug_requests.restart) {
        beginGame(s, s.new_game_settings);
    }
    if (debug_requests.jump_to_move) |moves_played| {
        jumpToMove(s, moves_played);
    }
    if (debug_requests.copy_diagram) {
        copyDiagram(&s.game.position);
    }
    if (debug_requests.paste_diagram) {
        z.requestPaste();
    }
    if (s.debug.open) {
        if (z.getPastedText(f.input)) |pasted| {
            loadPastedDiagram(s, pasted);
        }
    }
    switch (victory_choice) {
        .none => {},
        .continue_playing => {
            continueAsPlainGo(&s.game);
        },
        .restart => {
            beginGame(s, s.new_game_settings);
        },
        .main_menu => {
            s.screen = .main_menu;
        },
    }
    const window_is_open: bool = s.pause_open or s.game.position.winner != null or heroPaywallIsUp(s) or
        heroRewardIsUp(s);

    playComputerTurn(s, window_is_open);
    const computer_still_to_play: bool = s.players.computerToPlay(&s.game.position);

    // Whether the pointer is a finger, as the engine says, and where it aims (section 10).
    const pointer_px: Vec2 = z.getMousePosition(f.input);
    const button_down: bool = z.isMouseButtonDown(f.input, .left);
    const button_released: bool = z.isMouseButtonReleased(f.input, .left);
    const pointer_is_finger: bool = z.pointerKind(f.input) == .touch;
    const aimed_px: Vec2 = aimedPosition(pointer_px, pointer_is_finger, s.controls.finger_lift_px, window_height_px);

    // A second finger cancels the gesture: the stone held goes back, and the board reads nothing until every finger
    // is up (section 10).
    const fingers_down: u32 = @intCast(z.getTouchPointCount(f.input));
    const gesture_cancelled: bool = s.finger_gesture.ignoresPointer(fingers_down);
    if (gesture_cancelled) {
        s.hold.putDown();
    }

    // Read the board's input, unless the pause window is open, the pointer is over the interface, the gesture is
    // cancelled, or the computer is to play.
    const position: *const Position = &s.game.position;
    const layout: BoardLayout = .forPosition(window_width_px, window_height_px, position, s.style);
    const pointer_is_present: bool = pointerIsPresent(pointer_is_finger, button_down, button_released);
    const board_is_free: bool = !window_is_open and !interface_has_pointer and !gesture_cancelled and
        !computer_still_to_play;
    const board_has_pointer: bool = board_is_free and pointer_is_present;
    var pointed_point: ?Point = null;
    var drop_point: ?Point = null;
    if (board_has_pointer) {
        pointed_point = layout.pointUnderPointer(aimed_px);
        drop_point = steadyDropPoint(
            &s.game,
            layout,
            aimed_px,
            s.controls.drop_reach_spacings,
            s.ghost.point,
            s.controls.ghost_hysteresis_spacings,
        );
    }
    var release_delay_seconds: f32 = 0;
    if (pointer_is_finger) {
        release_delay_seconds = s.controls.finger_release_delay_seconds;
    }
    s.debug.inspected_point = pointed_point;
    const pointer: BoardPointer = .{
        .hovered = drop_point,
        .pressed = board_has_pointer and z.isMouseButtonPressed(f.input, .left),
        .released = button_released and !gesture_cancelled,
        .release_delay_seconds = release_delay_seconds,
        .frame_seconds = f.time.delta_time,
    };
    const move_played: ?MoveReport = applyPointer(&s.game, &s.hold, pointer);
    if (move_played) |report| {
        afterMovePlayed(s, report);
    }
    s.flights.advance(f.time.delta_time, s.style);

    // The columns' slot spacing, on its spring toward what the fuller side needs (section 8). The slots the flights
    // are heading for count, so the column has made room by the time they land.
    const black_prisoners: u32 = @max(prisonersOf(position, .black), position.capture_goal orelse 0);
    const white_prisoners: u32 = @max(prisonersOf(position, .white), position.capture_goal orelse 0);
    const fuller_side_slots: u32 = @max(black_prisoners, white_prisoners);
    const wanted_slot_spacing_px: f32 = fittedSlotSpacing(layout, s.style, fuller_side_slots);
    if (!s.slot_spacing_ready) {
        const resting: DoubleSpring(f32) = .atRest(wanted_slot_spacing_px);
        s.slot_spacing_spring = resting;
        s.slot_spacing_ready = true;
    }
    s.slot_spacing_spring.step(wanted_slot_spacing_px, s.style.slot_spacing_blend_seconds, f.time.delta_time);
    const columns: CaptureColumns = .fromLayout(layout, s.style, s.slot_spacing_spring.value);

    // Move the ghost toward the drop point - after the move just played, if any, so it is the next player's, and
    // held steady against the ghost's last point.
    var ghost_target: ?Point = null;
    if (board_has_pointer) {
        ghost_target = steadyDropPoint(
            &s.game,
            layout,
            aimed_px,
            s.controls.drop_reach_spacings,
            s.ghost.point,
            s.controls.ghost_hysteresis_spacings,
        );
    }
    updateGhost(&s.ghost, ghost_target, layout, s.style, f.time.delta_time);

    // The hover overlays, while a game is being played: what the stone would capture is read at the ghost's point;
    // the liberties shown are those of the groups touching the ghost's point and of a stone under the pointer. Their
    // clock starts again when the ghost moves to a new point, or the pointer to a new stone.
    const game_is_won: bool = position.winner != null;
    var doomed_point: ?Point = ghost_target;
    var liberties_ghost_point: ?Point = ghost_target;
    var liberties_pointed_point: ?Point = pointed_point;
    if (game_is_won) {
        doomed_point = null;
        liberties_ghost_point = null;
        liberties_pointed_point = null;
    }
    const clock_point: ?Point = liberties_ghost_point orelse liberties_pointed_point;
    s.hover_clock.advance(clock_point, f.time.delta_time);
    // With a ghost, the liberties shown are those of the position its move would make.
    const mover: Stone = position.player_to_move;
    var liberties_position: *const Position = position;
    if (liberties_ghost_point) |point| {
        _ = positionAfterMove(position, point, &s.ghost_position);
        liberties_position = &s.ghost_position;
    }
    var liberty_group_buffer: [board_limits.max_neighbors + 1]Point = undefined;
    const liberty_groups: []const Point = libertyOverlayGroups(
        liberties_position,
        liberties_ghost_point,
        liberties_pointed_point,
        &liberty_group_buffer,
    );
    var liberty_label_buffer: [board_limits.max_neighbors + 1]LibertyLabel = undefined;
    const liberty_labels: []const LibertyLabel = libertyLabels(
        position,
        liberties_position,
        liberties_ghost_point,
        liberties_pointed_point,
        &liberty_label_buffer,
    );

    // Draw back to front (section 9): the wood, the grid, the rings under the stones, the stones, the liberties, the
    // ghost; then the interface on top.
    drawWood(f.gl, s.textures.wood, window_width_px, window_height_px);
    drawGrid(f.gl, layout, s.style);
    if (s.overlays.atari_groups) {
        drawAtariRings(f.gl, position, layout, s.style);
    }
    if (doomed_point) |point| {
        if (s.overlays.doomed_groups) {
            drawDoomedRings(f.gl, position, point, s.hover_clock, layout, s.style);
        }
    }
    drawStones(f.gl, position, layout, &s.textures, s.style);
    // The target marked where the variant marks it; in go puzzles hero, which marks none, until the player's first
    // move when another group of its colour could be meant (`targetHasCompany`), and in its debug mode.
    const hero_shows_target: bool = heroAwaitsFirstMove(s) and targetHasCompany(position);
    const hero_marks: bool = s.variant.problem_families.len > 0 and (hero_shows_target or s.hero.debug_shown);
    if (s.variant.marks_target or hero_marks) {
        drawTargetMark(f.gl, position, layout, s.style);
    }
    // go puzzles hero's hint, a blue dot while its time lasts.
    if (s.hero.hint_point) |hint_point| {
        const since_seconds: f32 = s.hero.hint_since_seconds orelse f.time.time;
        const still_shown: bool = f.time.time - since_seconds < s.hero.hint.show_seconds;
        if (still_shown) {
            const dot_radius_px: f32 = s.style.hint_dot_spacings * layout.spacing_px;
            f.gl.circle(layout.pointPosition(hint_point), dot_radius_px, .{ .color = s.style.hint_color });
        } else {
            s.hero.hint_point = null;
            s.hero.hint_since_seconds = null;
        }
    }
    if (s.overlays.liberties) {
        drawLibertyMarks(f.gl, liberties_position, liberty_groups, mover, s.hover_clock, layout, s.style);
    }
    if (s.debug.forest_view) {
        drawForestView(f.gl, position, pointed_point, s.debug.forest_depths, &s.font, layout, s.style);
    }
    drawColumn(f.gl, position, &s.flights, .black, columns, &s.textures, s.style);
    drawColumn(f.gl, position, &s.flights, .white, columns, &s.textures, s.style);
    // go puzzles hero's row of progress, where its buttons put it; over everything, a reward's picture.
    if (s.hero.progress_row) |progress_row| {
        const level: HeroLevel = heroShownLevel(s);
        drawHeroProgress(f.gl, progress_row, level.filled, &s.textures, s.style, s.controls);
    }
    if (s.hero.reward_texture) |reward_texture| {
        const reward_settings: RewardSettings = s.variant.reward;
        const since_seconds: f32 = s.hero.reward_since_seconds orelse f.time.time;
        const show_seconds: f32 = f.time.time - since_seconds - reward_settings.delay_seconds;
        drawHeroReward(f.gl, reward_texture, show_seconds, reward_settings, window_width_px, window_height_px);
    }
    drawGhost(f.gl, &s.ghost, position.player_to_move, s.hold.is_held, layout, &s.textures, s.style);
    // The counts go over the ghost and the stones: each is written on a stone beside the ghost.
    if (s.overlays.liberties) {
        drawLibertyCounts(f.gl, position, liberty_labels, &s.font, s.hover_clock, layout, s.style);
    }
    drawFlights(f.gl, &s.flights, layout, columns, &s.textures, s.style);
    // With a ladder, its level in the corner, where goban's caption would be.
    if (s.variant.outpost_ladder != null and s.variant.interface == .none) {
        common.captionf(f.gl, s.font, "Level {d}", .{s.ladder_position + 1});
    }
    if (has_interface) {
        const player_name: []const u8 = @tagName(position.player_to_move);
        var thinking: []const u8 = "";
        if (computer_still_to_play) {
            thinking = " - the computer is thinking";
        }
        common.captionf(f.gl, s.font, "goban {d} x {d} - move {d} - {s} to play{s}", .{
            position.board_size,
            position.board_size,
            s.game.record.moves_played,
            player_name,
            thinking,
        });
    }

    // Under an open window, the board is dimmed: out of reach until the window closes.
    if (has_interface and window_is_open) {
        const whole_window: z.Rectangle = .{ .x = 0, .y = 0, .width = window_width_px, .height = window_height_px };
        f.gl.rect(whole_window, .{ .color = s.controls.window_dim_color });
    }
}

/// The interface's font size for a window of this size, the interface scaled to it (`scaleToViewport`): the smaller
/// of a `characters_across`-th of the width and a `characters_down`-th of the height, kept between 12 and 26 pixels -
/// so the text fits across a narrow window and the tallest window fits down a short one. The lines down are more than
/// `characters_down` when the tallest centred window measured so far, `tallest_window_fonts`, needs more with a
/// margin above and below it.
fn interfaceFontSize(
    u: ui.Ui,
    window_width_px: f32,
    window_height_px: f32,
    controls: ControlsStyle,
    tallest_window_fonts: f32,
) f32 {
    const tallest_window_with_margins_fonts: f32 = tallest_window_fonts + 2 * controls.edge_gap_fonts;
    const lines_down: f32 = @max(controls.characters_down, tallest_window_with_margins_fonts);
    const width_by_height_px: f32 = window_height_px * controls.characters_across / lines_down;
    const fitting_width_px: f32 = @min(window_width_px, width_by_height_px);
    const font_size_px: f32 = u.scaleToViewport(fitting_width_px, controls.characters_across);
    return font_size_px;
}

/// Writes the whole state: the pictures and font loaded, the interface made, the main menu shown - and a game started
/// with its choices behind it, so the state always holds a game.
fn init(gpa: Allocator, f: *z.Frame, s: *State, variant: AppVariant) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);
    // The audio device opens with the app: on a page, that is what makes the page ask for a press before it sounds.
    z.audio_device.init(f.audio_device);
    const controls: ControlsStyle = .{};
    const menu: MenuChoices = .{};
    const computer_settings: ComputerSettings = .{};
    s.* = .{
        .variant = variant,
        .won_at_seconds = null,
        .ladder_position = 0,
        .problem_index = 0,
        .problem_tree = .empty,
        .problem_solved_once = false,
        .problem_refuted = false,
        .problem_kind = .kill,
        .computer_hopeless_moves = 0,
        .hero = .{},
        .random = Xoshiro256.init(@trunc(z.epochMillis())),
        .gpa = gpa,
        .problem_play = .{},
        .screen = .main_menu,
        .menu = menu,
        .game = undefined,
        .new_game_settings = menu.settings(),
        .players = menu.players(),
        .computer_settings = computer_settings,
        .computer = try ComputerPlayer.init(gpa, computer_settings),
        .style = .{},
        .controls = controls,
        .hold = .empty,
        .ghost = .hidden,
        .overlays = .{},
        .hover_clock = .{},
        .flights = .none,
        .slot_spacing_spring = .atRest(0),
        .slot_spacing_ready = false,
        .ghost_position = undefined,
        .pause_open = false,
        .window_heights = .{},
        .finger_gesture = .uncancelled,
        .stone_sounds = try StoneSounds.load(gpa, f, controls.sound_volume, variant.reward_sound),
        .sound_on = true,
        .debug = .{},
        .move_log = undefined,
        .ui_host = z.UiHost.init(gpa, font),
        .textures = .{
            .wood = try uploadPng(gpa, f.gl, wood_png),
            .black_stone = try uploadPng(gpa, f.gl, black_stone_png),
            .white_stone = try uploadPng(gpa, f.gl, white_stone_png),
        },
        .font = font,
    };
    startGame(&s.game, s.new_game_settings);
    // Go puzzles hero starts its first round, a fight; its fixed game is that fight's, not one to start here.
    if (variant.hero) {
        const progress: HeroProgress = loadHeroProgress(variant);
        s.hero.wins = progress.wins;
        s.hero.rating = progress.rating;
        s.ladder_position = progress.ladder_position;
        s.hero.unlocked = progress.unlocked;
        beginHeroRound(s);
        return;
    }
    // A variant with problems starts the first: the person black against the computer.
    if (variant.problems.len > 0) {
        s.players = .{ .kind = .against_computer, .person_stone = .black };
        beginProblem(s);
    }
    // A variant with a game of its own starts it at once: there is no main menu to choose one in.
    if (variant.fixed_game) |fixed_game| {
        s.players = fixed_game.players;
        s.screen = .game;
        var first_settings: NewGameSettings = fixed_game.settings;
        if (variant.outpost_ladder) |ladder| {
            first_settings = ladder.settingsAt(first_settings, s.ladder_position, s.players.person_stone);
        }
        beginGame(s, first_settings);
    }
}

/// One frame: the interface begun, the screen's own frame, the interface drawn on top.
fn update(f: *z.Frame, s: *State) void {
    const window_width_px: f32 = f.window.widthf();
    const window_height_px: f32 = f.window.heightf();
    z.beginDrawing(f.gl);
    const u: ui.Ui = s.ui_host.begin(f);
    const font_size_px: f32 = interfaceFontSize(
        u,
        window_width_px,
        window_height_px,
        s.controls,
        s.window_heights.tallest,
    );
    switch (s.screen) {
        .main_menu => updateMainMenu(f, s, u, window_width_px, window_height_px, font_size_px),
        .game => updateGame(f, s, u, window_width_px, window_height_px, font_size_px),
    }
    s.ui_host.render(f);
    z.endDrawing(f.gl);
}

/// The panic handler: the examples' own, which reports through the engine, when this file is the program; std's
/// default when this file is built as its own test, which has no engine to report through.
pub const panic = if (builtin.is_test) std.debug.FullPanic(std.debug.defaultPanic) else std.debug.FullPanic(
    common.reportPanic,
);

/// One of goban's apps, as `variant` makes it.
pub fn appFor(comptime variant: AppVariant) z.AppSpec(State) {
    const VariantInit = struct {
        fn initVariant(gpa: Allocator, f: *z.Frame, s: *State) !void {
            try init(gpa, f, s, variant);
        }
    };
    const spec: z.AppSpec(State) = .{
        .config = .{
            .window = .{
                .title = variant.title,
                .width = 900,
                .height = 900,
                .scale_mode = .responsive,
            },
        },
        .init = VariantInit.initVariant,
        .memory = .managed,
        .deinit = deinit,
        .update = update,
    };
    return spec;
}

/// The program, as the runner (a page, a window, a headless run) or the launcher starts it: goban, with its interface.
pub const app: z.AppSpec(State) = appFor(.{});

// ===== Tests =====
//
// The tests are written as diagrams: each starts a game from the position it is about, plays the moves, and checks
// what the rules say should follow. After every move the forest is compared with the flood fill (section 5), so a
// test that only meant to check a capture also checks the bookkeeping behind it. `zig build test-goban` runs them.

/// A game, allocated: a Game is too large to keep comfortably on a test's stack.
fn createTestGame() !*Game {
    const game: *Game = try testing_allocator.create(Game);
    return game;
}

/// Fails when the forest disagrees with the flood fill.
fn expectForestAgrees(position: *const Position) !void {
    const disagreement: ?Disagreement = findDisagreement(position);
    try expectEqual(@as(?Disagreement, null), disagreement);
}

/// Starts `game` from a diagram the test knows to be valid.
fn startTestGameFromDiagram(game: *Game, text: []const u8) !void {
    const reading: DiagramReading = readDiagram(text);
    switch (reading) {
        .setup => |setup| {
            startGameFromDiagram(game, &setup);
        },
        .problem => {
            return error.TestDiagramRefused;
        },
    }
    try expectForestAgrees(&game.position);
}

/// Plays a move the test expects to be legal, and checks the forest after it.
fn playTestMove(game: *Game, row: u8, col: u8) !MoveReport {
    const point: Point = pointAt(game.position.board_size, row, col);
    try expectEqual(Legality.legal, checkMove(&game.position, point));
    const report: MoveReport = playMove(game, point);
    try expectForestAgrees(&game.position);
    return report;
}

/// The legality of a move at (row, col) for the player to move.
fn testLegality(game: *const Game, row: u8, col: u8) Legality {
    const point: Point = pointAt(game.position.board_size, row, col);
    const legality: Legality = checkMove(&game.position, point);
    return legality;
}

/// Fails unless the two positions are equal by value: every point's stone, parent and sets, and the position's own
/// facts. (Equal positions need not be equal byte for byte: the payload of a null `?Point` is undefined.)
fn expectSamePosition(expected: *const Position, actual: *const Position) !void {
    try expectEqual(expected.board_size, actual.board_size);
    for (0..pointCount(expected.board_size)) |point_index| {
        try expectEqual(expected.stones[point_index], actual.stones[point_index]);
        try expectEqual(expected.group_parent[point_index], actual.group_parent[point_index]);
        try expect(expected.group_liberties[point_index].eql(actual.group_liberties[point_index]));
        try expect(expected.group_stones[point_index].eql(actual.group_stones[point_index]));
    }
    try expectEqual(expected.ko_point, actual.ko_point);
    try expectEqual(expected.player_to_move, actual.player_to_move);
    try expectEqual(expected.last_move, actual.last_move);
    try expectEqual(expected.stones_captured_by_black, actual.stones_captured_by_black);
    try expectEqual(expected.stones_captured_by_white, actual.stones_captured_by_white);
    try expectEqual(expected.capture_goal, actual.capture_goal);
    try expectEqual(expected.winner, actual.winner);
}

test "neighbours of a middle point, an edge point and two corners, up down left right" {
    var buffer: [board_limits.max_neighbors]Point = undefined;
    const middle_expected: [4]Point = .{ 7, 17, 11, 13 };
    const edge_expected: [3]Point = .{ 7, 1, 3 };
    const top_left_expected: [2]Point = .{ 5, 1 };
    const bottom_right_expected: [2]Point = .{ 19, 23 };
    try expectEqualSlices(Point, &middle_expected, neighborsOf(5, 12, &buffer));
    try expectEqualSlices(Point, &edge_expected, neighborsOf(5, 2, &buffer));
    try expectEqualSlices(Point, &top_left_expected, neighborsOf(5, 0, &buffer));
    try expectEqualSlices(Point, &bottom_right_expected, neighborsOf(5, 24, &buffer));
}

test "star points: one on 5 x 5, corners and centre up to 11 x 11, sides too from 13 x 13, none below 5 x 5" {
    var buffer: [board_limits.max_star_points]Point = undefined;
    try expectEqual(@as(usize, 0), starPoints(4, &buffer).len);
    try expectEqual(@as(usize, 1), starPoints(5, &buffer).len);
    try expectEqual(@as(usize, 4), starPoints(6, &buffer).len);
    try expectEqual(@as(usize, 5), starPoints(9, &buffer).len);
    try expectEqual(@as(usize, 4), starPoints(10, &buffer).len);
    try expectEqual(@as(usize, 9), starPoints(13, &buffer).len);
    try expectEqual(@as(usize, 9), starPoints(19, &buffer).len);
    const standard_board: []const Point = starPoints(19, &buffer);
    try expectEqual(pointAt(19, 3, 3), standard_board[0]);
    try expectEqual(pointAt(19, 9, 9), standard_board[4]);
}

/// One frame of the pointer, for the tests, a sixtieth of a second long: a mouse over (row, col) of a 9 x 9 board, or
/// off it.
fn testPointer(row_col: ?[2]u8, pressed: bool, released: bool) BoardPointer {
    var hovered: ?Point = null;
    if (row_col) |point_row_col| {
        hovered = pointAt(9, point_row_col[0], point_row_col[1]);
    }
    const pointer: BoardPointer = .{
        .hovered = hovered,
        .pressed = pressed,
        .released = released,
        .release_delay_seconds = 0,
        .frame_seconds = 1.0 / 60.0,
    };
    return pointer;
}

/// The same frame, of a finger: its release plays where the ghost was 0.1 s before.
fn testFinger(row_col: ?[2]u8, pressed: bool, released: bool) BoardPointer {
    var pointer: BoardPointer = testPointer(row_col, pressed, released);
    pointer.release_delay_seconds = 0.1;
    return pointer;
}

test "press, drag, release: the stone is played where it is let go" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = null });
    var hold: StoneHold = .empty;

    // Press on (2,2), drag across (2,3), release on (3,3): one move, at (3,3).
    try expectEqual(@as(?MoveReport, null), applyPointer(game, &hold, testPointer(.{ 2, 2 }, true, false)));
    try expectEqual(true, hold.is_held);
    try expectEqual(@as(?MoveReport, null), applyPointer(game, &hold, testPointer(.{ 2, 3 }, false, false)));
    const report: MoveReport = applyPointer(game, &hold, testPointer(.{ 3, 3 }, false, true)).?;
    try expectEqual(pointAt(9, 3, 3), report.placed);
    try expectEqual(false, hold.is_held);
    try expectEqual(Stone.none, game.position.stones[pointAt(9, 2, 2)]);

    // A tap - press and release in one frame - plays where it lands.
    const tap: MoveReport = applyPointer(game, &hold, testPointer(.{ 0, 0 }, true, true)).?;
    try expectEqual(pointAt(9, 0, 0), tap.placed);
    try expectEqual(@as(u16, 2), game.record.moves_played);
}

test "press, drag, release: nothing is played from an occupied point, or onto one, or off the board" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = null });
    var hold: StoneHold = .empty;
    _ = applyPointer(game, &hold, testPointer(.{ 4, 4 }, true, true));

    // A press on a stone picks nothing up, so its release plays nothing.
    _ = applyPointer(game, &hold, testPointer(.{ 4, 4 }, true, false));
    try expectEqual(false, hold.is_held);
    try expectEqual(@as(?MoveReport, null), applyPointer(game, &hold, testPointer(.{ 5, 5 }, false, true)));

    // A held stone let go on a stone, or off the board (or over a window), is put back.
    _ = applyPointer(game, &hold, testPointer(.{ 1, 1 }, true, false));
    try expectEqual(@as(?MoveReport, null), applyPointer(game, &hold, testPointer(.{ 4, 4 }, false, true)));
    try expectEqual(false, hold.is_held);
    _ = applyPointer(game, &hold, testPointer(.{ 1, 1 }, true, false));
    try expectEqual(@as(?MoveReport, null), applyPointer(game, &hold, testPointer(null, false, true)));
    try expectEqual(false, hold.is_held);
    try expectEqual(@as(u16, 1), game.record.moves_played);
}

test "a finger's stone is played where the ghost was a tenth of a second before it lifted" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = null });
    var hold: StoneHold = .empty;

    // Held on (4,4) for half a second, then in the last two frames the fingertip rolls onto (4,5) as it lifts: the
    // stone goes on (4,4), where the ghost had been.
    _ = applyPointer(game, &hold, testFinger(.{ 4, 4 }, true, false));
    for (0..30) |_| {
        _ = applyPointer(game, &hold, testFinger(.{ 4, 4 }, false, false));
    }
    _ = applyPointer(game, &hold, testFinger(.{ 4, 5 }, false, false));
    const report: MoveReport = applyPointer(game, &hold, testFinger(.{ 4, 5 }, false, true)).?;
    try expectEqual(pointAt(9, 4, 4), report.placed);

    // A mouse is played where the ghost is.
    _ = applyPointer(game, &hold, testPointer(.{ 2, 2 }, true, false));
    for (0..30) |_| {
        _ = applyPointer(game, &hold, testPointer(.{ 2, 2 }, false, false));
    }
    const mouse_report: MoveReport = applyPointer(game, &hold, testPointer(.{ 2, 3 }, false, true)).?;
    try expectEqual(pointAt(9, 2, 3), mouse_report.placed);

    // A finger's tap shorter than the delay plays where it pressed.
    const tap: MoveReport = applyPointer(game, &hold, testFinger(.{ 6, 6 }, true, true)).?;
    try expectEqual(pointAt(9, 6, 6), tap.placed);
}

test "the ghost holds its point until another is nearer the pointer by the hysteresis" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const style: BoardStyle = .{};
    const layout: BoardLayout = .fromWindow(900, 900, 13, style);
    const spacing_px: f32 = layout.spacing_px;
    startGame(game, .{ .board_size = 13, .capture_goal = null });
    const left: Point = pointAt(13, 6, 6);
    const right: Point = pointAt(13, 6, 7);
    const left_px: Vec2 = layout.pointPosition(left);

    // Just past the middle between the two points, toward the right: without hysteresis the right point, but a ghost
    // on the left keeps it - the right is nearer by 0.1 spacings, less than 0.15.
    const just_past_middle_px: Vec2 = left_px + Vec2{ 0.55 * spacing_px, 0 };
    try expectEqual(@as(?Point, right), dropPoint(game, layout, just_past_middle_px, 1.0));
    try expectEqual(@as(?Point, left), steadyDropPoint(game, layout, just_past_middle_px, 1.0, left, 0.15));
    // Farther right, nearer by 0.2 spacings: the ghost moves.
    const farther_px: Vec2 = left_px + Vec2{ 0.6 * spacing_px, 0 };
    try expectEqual(@as(?Point, right), steadyDropPoint(game, layout, farther_px, 1.0, left, 0.15));
    // A ghost with no point yet takes the best one.
    try expectEqual(@as(?Point, right), steadyDropPoint(game, layout, just_past_middle_px, 1.0, null, 0.15));
}

test "a finger aims above itself, the lift shrinking near the bottom so the aim reaches the edge" {
    const lift_px: f32 = 64;
    const window_height_px: f32 = 800;
    const middle: Vec2 = .{ 300, 400 };
    try expectEqual(middle, aimedPosition(middle, false, lift_px, window_height_px));
    try expectEqual(@as(Vec2, .{ 300, 336 }), aimedPosition(middle, true, lift_px, window_height_px));
    // Where the lift starts to shrink, both formulas agree: no jump.
    const lift_starts_to_shrink: Vec2 = .{ 300, window_height_px - lift_px };
    try expectEqual(@as(Vec2, .{ 300, 672 }), aimedPosition(lift_starts_to_shrink, true, lift_px, window_height_px));
    // Below it the aim moves twice as fast as the finger, and at the edge both are there.
    try expectEqual(@as(Vec2, .{ 300, 768 }), aimedPosition(.{ 300, 784 }, true, lift_px, window_height_px));
    try expectEqual(@as(Vec2, .{ 300, 800 }), aimedPosition(.{ 300, 800 }, true, lift_px, window_height_px));
}

test "groupsCapturedBy: a group touching the point twice is listed once, and an illegal move captures nothing" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    var root_buffer: [board_limits.max_neighbors]Point = undefined;
    try startTestGameFromDiagram(game,
        \\. X X . .
        \\X O O X .
        \\X O . X .
        \\. X X . .
        \\. . . . .
    );
    const doomed: []const Point = groupsCapturedBy(&game.position, pointAt(5, 2, 2), &root_buffer);
    try expectEqual(@as(usize, 1), doomed.len);
    try expectEqual(findRoot(&game.position, pointAt(5, 1, 1)), doomed[0]);
    try expectEqual(@as(usize, 0), groupsCapturedBy(&game.position, pointAt(5, 4, 4), &root_buffer).len);

    // The ko point: the retake would capture, but it is not legal, so nothing is shown as doomed.
    try startTestGameFromDiagram(game,
        \\. X O . .
        \\X O . O .
        \\. X O . .
        \\. . . . .
        \\. . . . .
    );
    _ = try playTestMove(game, 1, 2);
    try expectEqual(Legality.ko, testLegality(game, 1, 1));
    try expectEqual(@as(usize, 0), groupsCapturedBy(&game.position, pointAt(5, 1, 1), &root_buffer).len);
}

test "the hover clock starts again on a new point; the overlay fades in, then pulses between its two opacities" {
    const style: BoardStyle = .{};
    var clock: HoverClock = .{};
    clock.advance(7, 0.5);
    try expectEqual(@as(f32, 0), clock.seconds);
    try expectEqual(@as(u8, 0), clock.alpha(100, 220, style));
    clock.advance(7, 0.5);
    try expectEqual(@as(f32, 0.5), clock.seconds);
    // Fully faded in after 1/3 s; then the pulse: 0.5 + 0.5 sin(4 t), between 100 and 220.
    for (0..40) |_| {
        clock.advance(7, 0.05);
        const alpha: u8 = clock.alpha(100, 220, style);
        try expect(alpha >= 100 and alpha <= 220);
    }
    clock.advance(8, 0.05);
    try expectEqual(@as(f32, 0), clock.seconds);
}

test "capture columns: touching while they fit, closer when not, never closer than the minimum, then a new column" {
    const style: BoardStyle = .{};
    const layout: BoardLayout = .fromWindow(900, 900, 13, style);
    const stone_radius_px: f32 = layout.spacing_px / 2 * style.captured_stone_radius_fraction;
    try expectEqual(2 * stone_radius_px, fittedSlotSpacing(layout, style, 1));
    try expectEqual(2 * stone_radius_px, fittedSlotSpacing(layout, style, 5));
    const crowded_px: f32 = fittedSlotSpacing(layout, style, 40);
    try expectEqual(layout.grid_px / 39, crowded_px);
    // Fitted exactly, the 40 stones make one whole column: none of them starts a second one.
    const crowded_columns: CaptureColumns = .fromLayout(layout, style, crowded_px);
    try expectEqual(@as(u32, 40), crowded_columns.slots_per_column);
    try expectEqual(style.slot_spacing_min_radii * stone_radius_px, fittedSlotSpacing(layout, style, 400));

    // At the minimum spacing a column holds what fits in the board's height; the next slot starts a second column,
    // further out on each side.
    const closest_px: f32 = fittedSlotSpacing(layout, style, 400);
    const columns: CaptureColumns = .fromLayout(layout, style, closest_px);
    const per_column: u32 = columns.slots_per_column;
    const last_of_first: Vec2 = columns.slotPosition(.black, per_column - 1);
    const first_of_second: Vec2 = columns.slotPosition(.black, per_column);
    try expect(last_of_first[1] <= layout.origin_px[1] + layout.grid_px);
    try expectEqual(columns.left_top_px[1], first_of_second[1]);
    try expect(first_of_second[0] < columns.left_top_px[0]);
    try expect(columns.slotPosition(.white, per_column)[0] > columns.right_top_px[0]);
}

test "flights: a capture leaves in turn, lands in its slots, and lands where the slot is when it arrives" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// white to play
        \\. O O O .
        \\O X X X .
        \\. O O O .
        \\. . . . .
        \\. . . . .
    );
    const style: BoardStyle = .{};
    const report: MoveReport = try playTestMove(game, 1, 4);
    var flights: Flights = .none;
    flights.launch(report, 0, style);
    try expectEqual(@as(usize, 3), flights.inAir().len);
    try expectEqual(@as(u32, 3), flights.countFor(.white));
    try expectEqual(@as(u32, 0), landedPrisoners(&game.position, &flights, .white));
    try expectEqual(@as(f32, 0.1), flights.inAir()[2].delay_seconds);

    // Half way, the first stone is in the air and the column still shows nothing.
    flights.advance(0.2, style);
    try expectEqual(@as(u32, 0), landedPrisoners(&game.position, &flights, .white));

    // The column closes up while the stones fly: each still lands on its slot as the slot now is.
    const layout: BoardLayout = .fromWindow(900, 900, 5, style);
    const closer_columns: CaptureColumns = .fromLayout(layout, style, fittedSlotSpacing(layout, style, 300));
    var arriving: Flight = flights.inAir()[1];
    arriving.seconds = arriving.delay_seconds + style.flight_seconds;
    const landing: FlightPlacement = arriving.placement(layout, closer_columns, style);
    try expectEqual(closer_columns.slotPosition(.white, 1), landing.centre_px);
    try expectEqual(closer_columns.stone_size_px, landing.size_px);

    // Once all have landed, the column shows all three.
    flights.advance(1.0, style);
    try expectEqual(@as(usize, 0), flights.inAir().len);
    try expectEqual(@as(u32, 3), landedPrisoners(&game.position, &flights, .white));
}

test "an Atari Go column shows the slots up to the goal" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = 5 });
    const flights: Flights = .none;
    try expectEqual(@as(u32, 5), shownSlots(&game.position, &flights, .black));
    try expectEqual(@as(u32, 0), landedPrisoners(&game.position, &flights, .black));
}

test "a stone aimed at a taken point drops on the nearest playable point within one spacing, or nowhere" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const style: BoardStyle = .{};
    const layout: BoardLayout = .fromWindow(900, 900, 13, style);
    const spacing_px: f32 = layout.spacing_px;
    startGame(game, .{ .board_size = 13, .capture_goal = null });

    // A playable point under the pointer is the drop point itself.
    const centre: Point = pointAt(13, 6, 6);
    const centre_px: Vec2 = layout.pointPosition(centre);
    try expectEqual(@as(?Point, centre), dropPoint(game, layout, centre_px, 1.0));

    // Taken: a little right of its centre, the right neighbour is the nearest.
    _ = try playTestMove(game, 6, 6);
    const right_of_centre_px: Vec2 = centre_px + Vec2{ 0.2 * spacing_px, 0 };
    try expectEqual(@as(?Point, pointAt(13, 6, 7)), dropPoint(game, layout, right_of_centre_px, 1.0));
    // A little above it, the one above.
    const above_centre_px: Vec2 = centre_px - Vec2{ 0, 0.3 * spacing_px };
    try expectEqual(@as(?Point, pointAt(13, 5, 6)), dropPoint(game, layout, above_centre_px, 1.0));

    // With its four neighbours taken too, the diagonal points are 1.41 spacings away: out of reach.
    _ = try playTestMove(game, 5, 6);
    _ = try playTestMove(game, 7, 6);
    _ = try playTestMove(game, 6, 5);
    _ = try playTestMove(game, 6, 7);
    try expectEqual(@as(?Point, null), dropPoint(game, layout, centre_px, 1.0));
    try expect(dropPoint(game, layout, centre_px, 1.5) != null);

    // Off the board there is no drop point.
    try expectEqual(@as(?Point, null), dropPoint(game, layout, .{ 5, 5 }, 1.0));
}

test "a finger is present only while it touches; a mouse always" {
    try expectEqual(true, pointerIsPresent(false, false, false));
    try expectEqual(false, pointerIsPresent(true, false, false));
    try expectEqual(true, pointerIsPresent(true, true, false));
    try expectEqual(true, pointerIsPresent(true, false, true));
}

test "a pointer just off the board drops on the board's edge; farther off, nothing" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const style: BoardStyle = .{};
    const layout: BoardLayout = .fromWindow(900, 900, 13, style);
    const spacing_px: f32 = layout.spacing_px;
    startGame(game, .{ .board_size = 13, .capture_goal = null });
    const left_edge_row_3: Vec2 = layout.pointPosition(pointAt(13, 3, 0));

    // 0.8 spacings left of the board, level with row 3: brought onto the edge, at (3, 0).
    const just_outside_px: Vec2 = left_edge_row_3 - Vec2{ 0.8 * spacing_px, 0 };
    try expectEqual(@as(?Point, pointAt(13, 3, 0)), dropPoint(game, layout, just_outside_px, 1.0));
    // 1.5 spacings off: out of reach, nothing - a held stone carried there is put back.
    const far_outside_px: Vec2 = left_edge_row_3 - Vec2{ 1.5 * spacing_px, 0 };
    try expectEqual(@as(?Point, null), dropPoint(game, layout, far_outside_px, 1.0));
    // Off a corner, the reach is measured to the corner itself: 0.6 spacings out on each axis is 0.85 away.
    const corner_px: Vec2 = layout.pointPosition(pointAt(13, 0, 0));
    const off_corner_px: Vec2 = corner_px - Vec2{ 0.6 * spacing_px, 0.6 * spacing_px };
    try expectEqual(@as(?Point, pointAt(13, 0, 0)), dropPoint(game, layout, off_corner_px, 1.0));
    // A taken edge point sends the stone along the edge, as on the board.
    _ = try playTestMove(game, 3, 0);
    const beside: ?Point = dropPoint(game, layout, just_outside_px - Vec2{ 0, 0.2 * spacing_px }, 1.0);
    try expectEqual(@as(?Point, pointAt(13, 2, 0)), beside);
}

test "liberties shown while ghosting are those after the move: a lone stone shows none, a joined group its new ones" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    var after: Position = undefined;
    var group_buffer: [board_limits.max_neighbors + 1]Point = undefined;
    try startTestGameFromDiagram(game,
        \\. . . . .
        \\. X . O .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );

    // A ghost alone, far from every stone: it joins nothing and touches nothing - no group is shown, with the pointer
    // on the ghost's own point too (in the position after the move, a stone stands there: the ghost's).
    const lone_point: Point = pointAt(5, 4, 4);
    _ = positionAfterMove(&game.position, lone_point, &after);
    try expectEqual(@as(usize, 0), libertyOverlayGroups(&after, lone_point, null, &group_buffer).len);
    try expectEqual(@as(usize, 0), libertyOverlayGroups(&after, lone_point, lone_point, &group_buffer).len);

    // A ghost between black and white: black's group would be the two stones, with 5 liberties; white's stone would
    // keep 3 of its 4 - the board is unchanged meanwhile.
    _ = positionAfterMove(&game.position, pointAt(5, 1, 2), &after);
    const groups: []const Point = libertyOverlayGroups(&after, pointAt(5, 1, 2), null, &group_buffer);
    try expectEqual(@as(usize, 2), groups.len);
    const joined_root: Point = findRoot(&after, pointAt(5, 1, 1));
    const white_root: Point = findRoot(&after, pointAt(5, 1, 3));
    try expect(indexOfScalar(Point, groups, joined_root) != null);
    try expect(indexOfScalar(Point, groups, white_root) != null);
    try expectEqual(@as(usize, 5), after.group_liberties[joined_root].count());
    try expectEqual(@as(usize, 3), after.group_liberties[white_root].count());
    try expectEqual(Stone.none, game.position.stones[pointAt(5, 1, 2)]);

    // A group the move would capture is gone from that position, so it is not shown.
    try startTestGameFromDiagram(game,
        \\. X . . .
        \\X O X . .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    _ = positionAfterMove(&game.position, pointAt(5, 2, 1), &after);
    const after_capture: []const Point = libertyOverlayGroups(&after, pointAt(5, 2, 1), null, &group_buffer);
    for (after_capture) |root| {
        try expect(after.stones[root] == .black);
    }
}

test "an Atari Go game continued as plain Go loses its win for good, undo and redo included" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = 1 });
    // The square's white stone at (4,3) has two liberties, (4,2) and (5,3): black takes one, white plays away, black
    // takes the other and captures it - black reaches the goal of one.
    _ = try playTestMove(game, 4, 2);
    _ = try playTestMove(game, 0, 0);
    _ = try playTestMove(game, 5, 3);
    try expectEqual(@as(?Stone, .black), game.position.winner);

    continueAsPlainGo(game);
    try expectEqual(@as(?Stone, null), game.position.winner);
    try expectEqual(@as(?u8, null), game.record.capture_goal);
    try expectEqual(@as(u16, 3), game.record.moves_played);
    try expect(undo(game));
    try expect(redo(game));
    try expectEqual(@as(?Stone, null), game.position.winner);
    try expectEqual(Legality.legal, testLegality(game, 8, 8));
}

test "inspectPoint: an empty point, and a stone's parent, root, depth, group and liberties" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\. . . . .
        \\. X X X .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    const empty: PointInspection = inspectPoint(&game.position, pointAt(5, 4, 4));
    try expectEqual(Stone.none, empty.stone);
    try expectEqual(@as(?Point, null), empty.root);

    const end_stone: PointInspection = inspectPoint(&game.position, pointAt(5, 1, 1));
    try expectEqual(@as(u8, 1), end_stone.row);
    try expectEqual(@as(u8, 1), end_stone.col);
    try expectEqual(pointAt(5, 1, 1), end_stone.index);
    try expectEqual(Stone.black, end_stone.stone);
    try expectEqual(@as(?Point, findRoot(&game.position, pointAt(5, 1, 1))), end_stone.root);
    try expectEqual(@as(usize, 3), end_stone.group_size);
    try expectEqual(@as(usize, 8), end_stone.liberty_count);
    // The depth counts the steps to the root: zero at the root, one more for each parent between.
    const root_inspection: PointInspection = inspectPoint(&game.position, end_stone.root.?);
    try expectEqual(@as(u32, 0), root_inspection.depth);
    try expectEqual(end_stone.root, root_inspection.parent);
}

test "the move log says who played where, and what the move joined, captured and left as ko" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    var line_buffer: [80]u8 = undefined;
    try startTestGameFromDiagram(game,
        \\. X O . .
        \\X O . O .
        \\. X O . .
        \\. . . . .
        \\. . . . .
    );
    // Black takes the white stone at (1,1) from (1,2): one stone captured, and the ko point left at (1,1).
    const capture: MoveReport = try playTestMove(game, 1, 2);
    var capture_line: Io.Writer = .fixed(&line_buffer);
    try writeMoveLine(capture, 5, &capture_line);
    try expectEqualStrings("B (1,2): captured 1, ko at (1,1)", capture_line.buffered());

    // White plays alone, which ends the ko; then black fills (1,1) and joins the four single black stones around it.
    const alone: MoveReport = try playTestMove(game, 4, 4);
    var alone_line: Io.Writer = .fixed(&line_buffer);
    try writeMoveLine(alone, 5, &alone_line);
    try expectEqualStrings("W (4,4)", alone_line.buffered());
    const joining: MoveReport = try playTestMove(game, 1, 1);
    var joining_line: Io.Writer = .fixed(&line_buffer);
    try writeMoveLine(joining, 5, &joining_line);
    try expectEqualStrings("B (1,1): joined 4 groups", joining_line.buffered());
}

test "the forest's arrows: one per stone that is not a root, each to its parent; a path climbs to the root" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\. . . . .
        \\. X X X .
        \\. . X . .
        \\. . . . O
        \\. . . O O
    );
    var arrow_buffer: [board_limits.max_points]ForestArrow = undefined;
    const arrows: []const ForestArrow = forestArrows(&game.position, &arrow_buffer);
    // Black's group of four and white's group of three: 3 + 2 arrows.
    try expectEqual(@as(usize, 5), arrows.len);
    for (arrows) |arrow| {
        try expectEqual(parentOf(&game.position, arrow.from), arrow.to);
        try expect(!isRoot(&game.position, arrow.from));
    }

    var path_buffer: [board_limits.max_points]Point = undefined;
    const path: []const Point = pathToRoot(&game.position, pointAt(5, 2, 2), &path_buffer);
    try expectEqual(pointAt(5, 2, 2), path[0]);
    try expectEqual(findRoot(&game.position, pointAt(5, 2, 2)), path[path.len - 1]);
    try expectEqual(@as(usize, inspectPoint(&game.position, pointAt(5, 2, 2)).depth + 1), path.len);
}

test "liberty counts: on each touching group's stone beside the ghost, before and after; a captured group goes to 0" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    var after: Position = undefined;
    var label_buffer: [board_limits.max_neighbors + 1]LibertyLabel = undefined;
    try startTestGameFromDiagram(game,
        \\. . . . .
        \\. X . O .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    // The ghost between black and white: black's stone goes from 4 to 5 (it joins the ghost), white's from 4 to 3;
    // each count is written on the stone beside the ghost.
    const between: Point = pointAt(5, 1, 2);
    _ = positionAfterMove(&game.position, between, &after);
    const labels: []const LibertyLabel = libertyLabels(&game.position, &after, between, null, &label_buffer);
    try expectEqual(@as(usize, 2), labels.len);
    // The ghost's neighbours are visited up, down, left, right: black's stone on the left comes first.
    try expectEqual(LibertyLabel{ .stone = pointAt(5, 1, 1), .before = 4, .after = 5 }, labels[0]);
    try expectEqual(LibertyLabel{ .stone = pointAt(5, 1, 3), .before = 4, .after = 3 }, labels[1]);
    // A ghost alone: no count. Without a ghost, a stone under the pointer: its count, unchanged.
    const lone: Point = pointAt(5, 4, 4);
    _ = positionAfterMove(&game.position, lone, &after);
    try expectEqual(@as(usize, 0), libertyLabels(&game.position, &after, lone, lone, &label_buffer).len);
    const pointed: []const LibertyLabel = libertyLabels(
        &game.position,
        &game.position,
        null,
        pointAt(5, 1, 1),
        &label_buffer,
    );
    try expectEqual(LibertyLabel{ .stone = pointAt(5, 1, 1), .before = 4, .after = 4 }, pointed[0]);

    // A group the move would capture: from its one liberty to none.
    try startTestGameFromDiagram(game,
        \\. X . . .
        \\X O X . .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    const capture: Point = pointAt(5, 2, 1);
    _ = positionAfterMove(&game.position, capture, &after);
    const capture_labels: []const LibertyLabel = libertyLabels(&game.position, &after, capture, null, &label_buffer);
    try expectEqual(LibertyLabel{ .stone = pointAt(5, 1, 1), .before = 1, .after = 0 }, capture_labels[0]);
}

test "a second finger cancels the gesture: nothing is played until every finger is up, even lifted one by one" {
    var game: Game = undefined;
    startGame(&game, .{ .board_size = 9, .capture_goal = null });
    var hold: StoneHold = .empty;
    var gesture: FingerGesture = .uncancelled;
    const centre: [2]u8 = .{ 4, 4 };

    // One finger presses and holds a stone over the centre.
    try expect(!gesture.ignoresPointer(1));
    _ = applyPointer(&game, &hold, testPointer(centre, true, false));
    try expect(hold.is_held);

    // A second finger comes down: the gesture is cancelled, and the stone goes back as the board's frame does.
    try expect(gesture.ignoresPointer(2));
    hold.putDown();
    // One finger lifts (its release ignored), then the other: still the cancelled gesture, the board unchanged.
    try expect(gesture.ignoresPointer(1));
    try expect(gesture.ignoresPointer(0));
    try expectEqual(@as(u32, 0), game.record.moves_played);

    // The next touch starts afresh: a tap plays.
    try expect(!gesture.ignoresPointer(1));
    const report: ?MoveReport = applyPointer(&game, &hold, testPointer(centre, true, true));
    try expect(report != null);
    try expectEqual(@as(u32, 1), game.record.moves_played);
}

test "a centred window has a third of the room it leaves above it and two thirds below, and starts at the margin" {
    // 900 px tall with 10 px margins: a 400 px window leaves 480 px, 160 of them above it.
    try expectEqual(@as(f32, 170), centredWindowTop(900, 400, 10));
    // 330 px tall: a 250 px window leaves 60 px, 20 above it.
    try expectEqual(@as(f32, 30), centredWindowTop(330, 250, 10));
    // As tall as the room between the margins, or taller than the screen: from the margin.
    try expectEqual(@as(f32, 10), centredWindowTop(320, 300, 10));
    try expectEqual(@as(f32, 10), centredWindowTop(320, 500, 10));
}

test "a sound's take is picked at random, but never the one just played" {
    // The first time any take; after that each of the others, never the previous one.
    for (0..5) |roll| {
        try expectEqual(@as(u8, @intCast(roll)), nextTake(null, roll, 5));
    }
    for (0..5) |previous_index| {
        const previous: u8 = @intCast(previous_index);
        var seen: [5]bool = @splat(false);
        for (0..4) |roll| {
            const take: u8 = nextTake(previous, roll, 5);
            try expect(take != previous);
            seen[take] = true;
        }
        for (seen, 0..) |was_seen, take| {
            try expectEqual(take != previous, was_seen);
        }
    }
}

test "a lone stone is captured in the middle, on the edge and in the corner" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\. X . . .
        \\X O X . .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    const middle_capture: MoveReport = try playTestMove(game, 2, 1);
    try expectEqual(@as(u32, 1), middle_capture.captured_count);
    try expectEqual(Stone.none, game.position.stones[pointAt(5, 1, 1)]);

    try startTestGameFromDiagram(game,
        \\// white to play
        \\. O X . .
        \\. . O . .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    const edge_capture: MoveReport = try playTestMove(game, 0, 3);
    try expectEqual(@as(u32, 1), edge_capture.captured_count);
    try expectEqual(Stone.none, game.position.stones[pointAt(5, 0, 2)]);

    try startTestGameFromDiagram(game,
        \\// white to play
        \\. . . . .
        \\. . . . .
        \\. . . . .
        \\. . . . O
        \\. . . . X
    );
    const corner_capture: MoveReport = try playTestMove(game, 4, 3);
    try expectEqual(@as(u32, 1), corner_capture.captured_count);
    try expectEqual(@as(u32, 1), game.position.stones_captured_by_white);
}

test "a group of three is captured at once, and its points become the capturer's liberties" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// white to play
        \\. O O O .
        \\O X X X .
        \\. O O O .
        \\. . . . .
        \\. . . . .
    );
    const capture: MoveReport = try playTestMove(game, 1, 4);
    try expectEqual(@as(u32, 3), capture.captured_count);
    try expectEqual(@as(u32, 3), game.position.stones_captured_by_white);
    const capturing_root: Point = findRoot(&game.position, pointAt(5, 1, 4));
    const emptied_neighbour: Point = pointAt(5, 1, 3);
    try expect(game.position.group_liberties[capturing_root].isSet(emptied_neighbour));
    const upper_root: Point = findRoot(&game.position, pointAt(5, 0, 2));
    try expect(game.position.group_liberties[upper_root].isSet(pointAt(5, 1, 2)));
}

test "suicide is refused, and a move that only looks like suicide but captures is legal" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// white to play
        \\. X . . .
        \\X . . . .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    try expectEqual(Legality.suicide, testLegality(game, 0, 0));

    try startTestGameFromDiagram(game,
        \\// white to play
        \\. X O . .
        \\X O . . .
        \\O . . . .
        \\. . . . .
        \\. . . . .
    );
    try expectEqual(Legality.legal, testLegality(game, 0, 0));
    const capture: MoveReport = try playTestMove(game, 0, 0);
    try expectEqual(@as(u32, 2), capture.captured_count);
}

test "ko: the immediate retake is refused, and allowed after a move elsewhere and an answer" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\. X O . .
        \\X O . O .
        \\. X O . .
        \\. . . . .
        \\. . . . .
    );
    const take: MoveReport = try playTestMove(game, 1, 2);
    try expectEqual(@as(u32, 1), take.captured_count);
    try expectEqual(@as(?Point, pointAt(5, 1, 1)), take.ko_point);
    try expectEqual(Legality.ko, testLegality(game, 1, 1));

    _ = try playTestMove(game, 4, 4);
    _ = try playTestMove(game, 4, 0);
    const retake: MoveReport = try playTestMove(game, 1, 1);
    try expectEqual(@as(u32, 1), retake.captured_count);
}

test "snapback: a capture of one by a group of two leaves no ko point, and the recapture of two is legal" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// white to play
        \\. . X O .
        \\X O O . .
        \\. . . . .
        \\. . . . .
        \\. . . . .
    );
    _ = try playTestMove(game, 0, 0);
    const take_one: MoveReport = try playTestMove(game, 0, 1);
    try expectEqual(@as(u32, 1), take_one.captured_count);
    try expectEqual(@as(?Point, null), take_one.ko_point);
    const take_two: MoveReport = try playTestMove(game, 0, 0);
    try expectEqual(@as(u32, 2), take_two.captured_count);
}

test "the Atari Go square: placed by startGame, kept by undo, redo and a restart, never the last move" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const settings: NewGameSettings = .{ .board_size = 9, .capture_goal = 3 };
    startGame(game, settings);
    const square_text: []const u8 =
        \\// goban 9x9, black to play
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . X O . . . .
        \\. . . O X . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\
    ;
    var text_buffer: [512]u8 = undefined;
    var writer: Io.Writer = .fixed(&text_buffer);
    try writeDiagram(&game.position, &writer);
    try expectEqualStrings(square_text, writer.buffered());
    try expectEqual(@as(?Point, null), game.position.last_move);
    try expectEqual(false, undo(game));

    const position_after_start: Position = game.position;
    _ = try playTestMove(game, 0, 0);
    try expectEqual(true, undo(game));
    try expectSamePosition(&position_after_start, &game.position);
    try expectEqual(true, redo(game));
    try expectEqual(@as(?Point, pointAt(9, 0, 0)), game.position.last_move);

    startGame(game, settings);
    try expectSamePosition(&position_after_start, &game.position);
}

test "Atari Go needs a 4 x 4 board: on 3 x 3 the square would capture its own corner" {
    try expectEqual(false, allowsBoardSize(3, 3));
    try expectEqual(true, allowsBoardSize(3, 4));
    try expectEqual(true, allowsBoardSize(null, 3));

    var position: Position = .init(3);
    const square_order: [4][2]u8 = .{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 } };
    var captured_by_the_square: u32 = 0;
    for (square_order) |row_col| {
        const report: MoveReport = placeStone(&position, pointAt(3, row_col[0], row_col[1]));
        captured_by_the_square += report.captured_count;
    }
    try expectEqual(@as(u32, 1), captured_by_the_square);
    try expectEqual(Stone.none, position.stones[pointAt(3, 0, 0)]);
}

test "an Atari Go win is cleared by undo and set again by redo" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = 1 });
    _ = try playTestMove(game, 2, 4);
    _ = try playTestMove(game, 8, 8);
    const winning_move: MoveReport = try playTestMove(game, 3, 5);
    try expectEqual(@as(u32, 1), winning_move.captured_count);
    try expectEqual(@as(?Stone, .black), game.position.winner);
    try expectEqual(Legality.game_over, testLegality(game, 0, 0));
    try expectEqual(true, undo(game));
    try expectEqual(@as(?Stone, null), game.position.winner);
    try expectEqual(true, redo(game));
    try expectEqual(@as(?Stone, .black), game.position.winner);
}

test "a new move after undo replaces the moves that were undone" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = null });
    for (0..5) |move_index| {
        const col: u8 = @intCast(move_index);
        _ = try playTestMove(game, 0, col);
    }
    try expectEqual(true, undo(game));
    try expectEqual(true, undo(game));
    try expectEqual(@as(u16, 3), game.record.moves_played);
    try expectEqual(@as(u16, 5), game.record.moves_recorded);
    _ = try playTestMove(game, 8, 8);
    try expectEqual(@as(u16, 4), game.record.moves_recorded);
    try expectEqual(false, redo(game));
}

/// Plays one random game: at each turn a legal move is drawn from all the legal moves, the forest is checked, and
/// read-only queries are asked of every point to show they leave the position as it was. Returns the stones captured.
fn playCheckedRandomGame(game: *Game, board_size: u8, seed: u64, move_limit: usize) !u32 {
    var prng: DefaultPrng = .init(seed);
    const random: Random = prng.random();
    startGame(game, .{ .board_size = board_size, .capture_goal = null });

    var stones_captured: u32 = 0;
    var legal_buffer: [board_limits.max_points]Point = undefined;
    for (0..move_limit) |_| {
        var legal_moves: ArrayList(Point) = .initBuffer(&legal_buffer);
        for (0..pointCount(board_size)) |point_index| {
            const point: Point = @intCast(point_index);
            const is_legal: bool = checkMove(&game.position, point) == .legal;
            if (is_legal) {
                legal_moves.appendAssumeCapacity(point);
            }
        }
        const no_legal_move: bool = legal_moves.items.len == 0;
        if (no_legal_move) {
            break;
        }
        const chosen_index: usize = random.uintLessThan(usize, legal_moves.items.len);
        const report: MoveReport = playMove(game, legal_moves.items[chosen_index]);
        stones_captured += report.captured_count;
        try expectForestAgrees(&game.position);

        const position_before_queries: Position = game.position;
        for (0..pointCount(board_size)) |point_index| {
            const point: Point = @intCast(point_index);
            _ = checkMove(&game.position, point);
            const point_has_stone: bool = game.position.stones[point] != .none;
            if (point_has_stone) {
                _ = findRoot(&game.position, point);
            }
        }
        try expectSamePosition(&position_before_queries, &game.position);
    }
    return stones_captured;
}

test "random games on four board sizes: the forest agrees with the flood fill after every move" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const board_sizes: [4]u8 = .{ 5, 9, 13, 19 };
    var total_captured: u32 = 0;
    for (board_sizes) |board_size| {
        for (0..3) |seed_index| {
            const seed: u64 = 1000 * @as(u64, board_size) + seed_index;
            total_captured += try playCheckedRandomGame(game, board_size, seed, 200);
        }
    }
    try expect(total_captured > 100);
}

test "undo to every move and redo to the end rebuild the positions the game went through" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const move_count: usize = 60;
    _ = try playCheckedRandomGame(game, 9, 77, move_count);
    const played: usize = game.record.moves_played;
    try expect(played == move_count);

    const positions: []Position = try testing_allocator.alloc(Position, played + 1);
    defer testing_allocator.free(positions);
    positions[played] = game.position;
    var moves_left: usize = played;
    while (moves_left > 0) {
        moves_left -= 1;
        try expectEqual(true, undo(game));
        positions[moves_left] = game.position;
    }
    try expectEqual(false, undo(game));
    for (1..played + 1) |moves_shown| {
        try expectEqual(true, redo(game));
        try expectSamePosition(&positions[moves_shown], &game.position);
    }
    try expectEqual(false, redo(game));
}

test "the forest check names a fault planted in a liberty set and in a parent" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\. . . . .
        \\. X X . .
        \\. . X . .
        \\. . . . .
        \\. . . . .
    );
    const root: Point = findRoot(&game.position, pointAt(5, 1, 1));

    var missing_liberty: Position = game.position;
    missing_liberty.group_liberties[root].unset(pointAt(5, 3, 2));
    const liberty_fault: Disagreement = findDisagreement(&missing_liberty).?;
    try expectEqual(DisagreementKind.liberties_differ, liberty_fault.kind);
    try expectEqual(root, liberty_fault.point);
    try expectEqual(@as(usize, 6), liberty_fault.forest_count);
    try expectEqual(@as(usize, 7), liberty_fault.flood_fill_count);
    var text_buffer: [128]u8 = undefined;
    var writer: Io.Writer = .fixed(&text_buffer);
    try writer.print("{f}", .{liberty_fault});
    try expectEqualStrings("point (2,2): forest has 6 liberties, flood fill finds 7", writer.buffered());

    var looping_parents: Position = game.position;
    const stone_a: Point = pointAt(5, 1, 1);
    const stone_b: Point = pointAt(5, 1, 2);
    looping_parents.group_parent[stone_a] = stone_b;
    looping_parents.group_parent[stone_b] = stone_a;
    const loop_fault: Disagreement = findDisagreement(&looping_parents).?;
    try expectEqual(DisagreementKind.parents_loop, loop_fault.kind);
    try expectEqual(stone_a, loop_fault.point);
}

test "a diagram is written back exactly as it was read" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const diagram_text: []const u8 =
        \\// goban 5x5, white to play
        \\. . X O .
        \\X O O . .
        \\. . . . .
        \\. . . O .
        \\. X . . .
        \\
    ;
    try startTestGameFromDiagram(game, diagram_text);
    var text_buffer: [256]u8 = undefined;
    var writer: Io.Writer = .fixed(&text_buffer);
    try writeDiagram(&game.position, &writer);
    try expectEqualStrings(diagram_text, writer.buffered());
    try expectEqual(false, undo(game));
}

test "a diagram that describes no position is refused, with the reason" {
    const RefusalCase = struct { text: []const u8, expected: std.meta.Tag(DiagramProblem) };
    const cases: [8]RefusalCase = .{
        .{ .text = "\n  \n", .expected = .no_rows },
        .{ .text = ". .\n. .", .expected = .too_few_rows },
        .{ .text = "...\n.Z.\n...", .expected = .unknown_character },
        .{ .text = "// whose turn?\n...\n...\n...", .expected = .unclear_turn },
        .{ .text = "...\n....\n...", .expected = .row_length_differs },
        .{ .text = "XO.\nO..\n...", .expected = .group_without_liberty },
        .{ .text = "....................", .expected = .row_too_long },
        .{ .text = ".\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n.\n", .expected = .too_many_rows },
    };
    for (cases) |case| {
        const reading: DiagramReading = readDiagram(case.text);
        try expect(reading == .problem);
        try expectEqual(case.expected, std.meta.activeTag(reading.problem));
    }
}

/// The position of a diagram as an Atari Go game with `capture_goal`, for the search's tests.
fn atariGoTestPosition(text: []const u8, capture_goal: u8) !Position {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game, text);
    var position: Position = game.position;
    position.capture_goal = capture_goal;
    return position;
}

/// A search of `iteration_count` iterations from `root_position`, seeded with `seed`, with the default settings. Its
/// nodes come from the testing allocator: the caller frees `tree.nodes`.
fn testSearch(
    root_position: *const Position,
    iteration_count: u32,
    seed: u64,
) !SearchTree {
    const node_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, iteration_count + 1);
    var tree: SearchTree = .init(node_buffer, root_position, 0, seed);
    var scratch: Position = undefined;
    runIterations(&tree, root_position, .{}, iteration_count, &scratch, &.{});
    return tree;
}

test "the search finds a capture that wins at once" {
    // White's stone has one liberty, at (0, 2); with a goal of one capture, black wins by taking it.
    const position: Position = try atariGoTestPosition(
        \\// goban 5x5, black to play
        \\. . . . .
        \\. X O X .
        \\. . X . .
        \\. . . . .
        \\. . . . .
    , 1);
    const tree: SearchTree = try testSearch(&position, 2000, 1);
    defer testing_allocator.free(tree.nodes);
    try expectEqual(@as(?Point, pointAt(5, 0, 2)), mostVisitedMove(&tree));
}

test "the search finds the only rescue of its own stone in atari" {
    // Black's stone has one liberty, at (1, 2), and black can capture nothing: any other move lets white take the
    // stone and win. Extending to (1, 2) gives the group three liberties.
    const position: Position = try atariGoTestPosition(
        \\// goban 5x5, black to play
        \\. . . . .
        \\. . . . .
        \\. O X O .
        \\. . O . .
        \\. . . . .
    , 1);
    const tree: SearchTree = try testSearch(&position, 3000, 2);
    defer testing_allocator.free(tree.nodes);
    try expectEqual(@as(?Point, pointAt(5, 1, 2)), mostVisitedMove(&tree));
}

test "the search's visits and half-wins add up through the tree" {
    var position: Position = .init(9);
    position.capture_goal = 1;
    const iteration_count: u32 = 500;
    const tree: SearchTree = try testSearch(&position, iteration_count, 7);
    defer testing_allocator.free(tree.nodes);
    try expectEqual(iteration_count, tree.nodes[0].visits);
    try expect(tree.header.node_count <= iteration_count + 1);

    for (tree.nodes[0..tree.header.node_count], 0..) |node, node_index| {
        // A child's playouts are its parent's too, and a child's mover is its parent's opponent, so each half-win the
        // child's mover did not get is one the parent's mover got.
        var children_visits: u32 = 0;
        var children_half_wins_for_parent: u32 = 0;
        var child_index: u32 = node.first_child;
        while (child_index != SearchNode.none) {
            const child: SearchNode = tree.nodes[child_index];
            children_visits += child.visits;
            children_half_wins_for_parent += 2 * child.visits - child.half_wins;
            child_index = child.next_sibling;
        }
        try expect(node.half_wins <= 2 * node.visits);
        const is_root: bool = node_index == 0;
        const is_final: bool = node.candidate_count == 0;
        if (is_root) {
            // The root is made without a playout: all its visits are its children's.
            try expectEqual(children_visits, node.visits);
            try expectEqual(children_half_wins_for_parent, node.half_wins);
        } else if (is_final) {
            // A final node's playouts end where they start: won by its mover (2 each) or undecided (1 each).
            try expectEqual(SearchNode.none, node.first_child);
            try expect(node.half_wins == 2 * node.visits or node.half_wins == node.visits);
        } else {
            // One playout from the iteration that made the node, and the rest through its children.
            try expectEqual(children_visits + 1, node.visits);
            const own_half_wins: u32 = node.half_wins - children_half_wins_for_parent;
            try expect(own_half_wins <= 2);
        }
    }
}

test "the same seed and the same iterations give the same tree, and the same move" {
    var position: Position = .init(7);
    position.capture_goal = 1;
    const first: SearchTree = try testSearch(&position, 400, 11);
    defer testing_allocator.free(first.nodes);
    const second: SearchTree = try testSearch(&position, 400, 11);
    defer testing_allocator.free(second.nodes);
    try expectEqual(first.header, second.header);
    const first_nodes: []const SearchNode = first.nodes[0..first.header.node_count];
    const second_nodes: []const SearchNode = second.nodes[0..second.header.node_count];
    for (first_nodes, second_nodes) |first_node, second_node| {
        try expectEqual(first_node, second_node);
    }
    try expectEqual(mostVisitedMove(&first), mostVisitedMove(&second));
}

test "the search reads the root position and leaves it as it was" {
    const position: Position = try atariGoTestPosition(
        \\// goban 5x5, white to play
        \\. . . . .
        \\. X O . .
        \\. O X . .
        \\. . . . .
        \\. . . . .
    , 3);
    const position_before: Position = position;
    const tree: SearchTree = try testSearch(&position, 300, 3);
    defer testing_allocator.free(tree.nodes);
    try expectSamePosition(&position_before, &position);
}

test "the urgent move captures a group in atari before it rescues one, wherever the group stands" {
    var generator: DefaultPrng = .init(5);
    const random: Random = generator.random();
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// goban 5x5, white to play
        \\. . . . .
        \\. . X . .
        \\. X . X .
        \\. . . . .
        \\. . . . .
    );
    // Nothing is in atari: no urgent move.
    try expectEqual(@as(?Point, null), urgentMove(&game.position, random, .{}, &.{}));
    // White plays into black's triangle: its stone's one liberty is (3, 2), and black captures there.
    _ = try playTestMove(game, 2, 2);
    try expectEqual(@as(?Point, pointAt(5, 3, 2)), urgentMove(&game.position, random, .{}, &.{}));

    // A stone left in atari since before the last move is captured too: here no move has been played at all.
    try startTestGameFromDiagram(game,
        \\// goban 5x5, white to play
        \\. . . . .
        \\. . . . .
        \\. O X O .
        \\. . O . .
        \\. . . . .
    );
    try expectEqual(@as(?Point, pointAt(5, 1, 2)), urgentMove(&game.position, random, .{}, &.{}));
}

test "the urgent move rescues a group of one's own in atari when there is nothing to capture" {
    var generator: DefaultPrng = .init(6);
    const random: Random = generator.random();
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// goban 5x5, white to play
        \\. . . . .
        \\. . O . .
        \\. O X . .
        \\. . . . .
        \\. . . . .
    );
    // White's stone below black's leaves it one liberty, at (2, 3); no white group is in atari, so black extends.
    _ = try playTestMove(game, 3, 2);
    try expectEqual(@as(?Point, pointAt(5, 2, 3)), urgentMove(&game.position, random, .{}, &.{}));
    // Once black has extended, and white has played away, nothing is in atari.
    _ = try playTestMove(game, 2, 3);
    _ = try playTestMove(game, 0, 0);
    try expectEqual(@as(?Point, null), urgentMove(&game.position, random, .{}, &.{}));
}

/// How many nodes the subtree under `node_index` holds, itself included.
fn subtreeSize(tree: *const SearchTree, node_index: u32) u32 {
    var size: u32 = 1;
    var child_index: u32 = tree.nodes[node_index].first_child;
    while (child_index != SearchNode.none) {
        size += subtreeSize(tree, child_index);
        child_index = tree.nodes[child_index].next_sibling;
    }
    return size;
}

test "a tree written as bytes is read back as it was" {
    var position: Position = .init(7);
    position.capture_goal = 1;
    const tree: SearchTree = try testSearch(&position, 300, 21);
    defer testing_allocator.free(tree.nodes);

    var byte_buffer: [400 * @sizeOf(SearchNode)]u8 = undefined;
    var out: Io.Writer = .fixed(&byte_buffer);
    try writeTree(&tree, &out);
    const bytes: []const u8 = out.buffered();
    try expectEqual(@sizeOf(SearchTreeHeader) + tree.header.node_count * @sizeOf(SearchNode), bytes.len);

    const read_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, 301);
    defer testing_allocator.free(read_buffer);
    const read_tree: SearchTree = readTree(bytes, read_buffer) orelse {
        return error.TestTreeNotRead;
    };
    try expectEqual(tree.header, read_tree.header);
    for (tree.nodes[0..tree.header.node_count], read_tree.nodes[0..read_tree.header.node_count]) |node, read_node| {
        try expectEqual(node, read_node);
    }
    // Bytes cut short, and a buffer too small, are refused.
    try expectEqual(@as(?SearchTree, null), readTree(bytes[0 .. bytes.len - 1], read_buffer));
    try expectEqual(@as(?SearchTree, null), readTree(bytes, read_buffer[0..10]));
}

test "the subtree after two moves is taken up whole: its visits, its half-wins and its shape" {
    var position: Position = .init(7);
    position.capture_goal = 1;
    const tree: SearchTree = try testSearch(&position, 2000, 23);
    defer testing_allocator.free(tree.nodes);
    // The computer's most visited move, and the most visited reply to it.
    const move_index: u32 = mostVisitedChild(&tree, 0).?;
    const reply_index: u32 = mostVisitedChild(&tree, move_index).?;
    const moves: [2]Point = .{ tree.nodes[move_index].move, tree.nodes[reply_index].move };

    const new_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, tree.header.node_count);
    defer testing_allocator.free(new_buffer);
    const subtree: SearchTree = (try takeUpSubtree(testing_allocator, &tree, &moves, 2, 99, new_buffer)) orelse {
        return error.TestSubtreeNotTakenUp;
    };
    try expectEqual(subtreeSize(&tree, reply_index), subtree.header.node_count);
    try expectEqual(@as(u32, 2), subtree.header.root_moves_played);
    try expectEqual(tree.header.random_state, subtree.header.random_state);
    const old_root: SearchNode = tree.nodes[reply_index];
    const new_root: SearchNode = subtree.nodes[0];
    try expectEqual(old_root.visits, new_root.visits);
    try expectEqual(old_root.half_wins, new_root.half_wins);
    try expectEqual(SearchNode.none, new_root.parent);
    // The children, in their order, with their statistics and their own subtrees' sizes.
    var old_child: u32 = old_root.first_child;
    var new_child: u32 = new_root.first_child;
    while (old_child != SearchNode.none) {
        try expect(new_child != SearchNode.none);
        try expectEqual(tree.nodes[old_child].move, subtree.nodes[new_child].move);
        try expectEqual(tree.nodes[old_child].visits, subtree.nodes[new_child].visits);
        try expectEqual(@as(u32, 0), subtree.nodes[new_child].parent);
        try expectEqual(subtreeSize(&tree, old_child), subtreeSize(&subtree, new_child));
        old_child = tree.nodes[old_child].next_sibling;
        new_child = subtree.nodes[new_child].next_sibling;
    }
    try expectEqual(SearchNode.none, new_child);
}

test "a tree is not taken up when a move leads to no child, or the subtree does not fit" {
    var position: Position = .init(7);
    position.capture_goal = 1;
    const tree: SearchTree = try testSearch(&position, 200, 25);
    defer testing_allocator.free(tree.nodes);
    const new_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, tree.header.node_count);
    defer testing_allocator.free(new_buffer);

    // After 200 iterations from an empty 7 x 7 board, some reply to the first move is still untried.
    const move_index: u32 = mostVisitedChild(&tree, 0).?;
    const move: Point = tree.nodes[move_index].move;
    var untried_reply: ?Point = null;
    for (0..pointCount(7)) |point_index| {
        const reply: Point = @intCast(point_index);
        const reply_is_tried: bool = childByMove(&tree, move_index, reply) != null;
        if (reply != move and !reply_is_tried) {
            untried_reply = reply;
            break;
        }
    }
    const moves_off_the_tree: [2]Point = .{ move, untried_reply.? };
    const off_the_tree: ?SearchTree = try takeUpSubtree(
        testing_allocator,
        &tree,
        &moves_off_the_tree,
        2,
        0,
        new_buffer,
    );
    try expectEqual(@as(?SearchTree, null), off_the_tree);

    // The whole tree, into a buffer one node too small.
    const too_small: []SearchNode = new_buffer[0 .. tree.header.node_count - 1];
    const not_fitting: ?SearchTree = try takeUpSubtree(testing_allocator, &tree, &.{}, 0, 0, too_small);
    try expectEqual(@as(?SearchTree, null), not_fitting);
}

test "a search node and a tree's header have no padding: every byte that travels is a field's" {
    inline for (.{ SearchNode, SearchTreeHeader }) |Layout| {
        comptime var fields_size: usize = 0;
        inline for (@typeInfo(Layout).@"struct".field_types) |FieldType| {
            fields_size += @sizeOf(FieldType);
        }
        try expectEqual(fields_size, @sizeOf(Layout));
    }
    try expectEqual(@as(usize, 28), @sizeOf(SearchNode));
}

test "the fingerprint is the same for the same position reached twice, and differs where a position differs" {
    const first_game: *Game = try createTestGame();
    defer testing_allocator.destroy(first_game);
    const second_game: *Game = try createTestGame();
    defer testing_allocator.destroy(second_game);
    // The second game played something else first, so its memory held another position before the replay.
    startGame(second_game, .{ .board_size = 9, .capture_goal = 1 });
    _ = playMove(second_game, pointAt(9, 0, 0));
    _ = playMove(second_game, pointAt(9, 8, 8));
    for ([_]*Game{ first_game, second_game }) |game| {
        startGame(game, .{ .board_size = 9, .capture_goal = 1 });
        _ = playMove(game, pointAt(9, 2, 2));
        _ = playMove(game, pointAt(9, 6, 6));
    }
    try expectEqual(positionFingerprint(&first_game.position), positionFingerprint(&second_game.position));
    // One move more on one side: another position, another fingerprint.
    _ = playMove(second_game, pointAt(9, 2, 6));
    try expect(positionFingerprint(&first_game.position) != positionFingerprint(&second_game.position));
}

/// Fails unless the subtree of `actual_tree` under `actual_index` is the subtree of `expected_tree` under
/// `expected_index`: the same moves, counts and statistics, node for node, children in the same order - whatever the
/// nodes' indices.
fn expectSameSubtree(
    expected_tree: *const SearchTree,
    expected_index: u32,
    actual_tree: *const SearchTree,
    actual_index: u32,
) !void {
    const expected: SearchNode = expected_tree.nodes[expected_index];
    const actual: SearchNode = actual_tree.nodes[actual_index];
    try expectEqual(expected.move, actual.move);
    try expectEqual(expected.mover, actual.mover);
    try expectEqual(expected.candidate_count, actual.candidate_count);
    try expectEqual(expected.children_made, actual.children_made);
    try expectEqual(expected.visits, actual.visits);
    try expectEqual(expected.half_wins, actual.half_wins);
    var expected_child: u32 = expected.first_child;
    var actual_child: u32 = actual.first_child;
    while (expected_child != SearchNode.none) {
        try expect(actual_child != SearchNode.none);
        try expectSameSubtree(expected_tree, expected_child, actual_tree, actual_child);
        expected_child = expected_tree.nodes[expected_child].next_sibling;
        actual_child = actual_tree.nodes[actual_child].next_sibling;
    }
    try expectEqual(SearchNode.none, actual_child);
}

/// An Atari Go game on 7 x 7 with a goal of one capture, `first_moves` played (as (row, col)), for the tests of
/// `continueSearch`. The caller destroys it.
fn searchTestGame(first_moves: []const [2]u8) !*Game {
    const game: *Game = try createTestGame();
    startGame(game, .{ .board_size = 7, .capture_goal = 1 });
    for (first_moves) |row_col| {
        _ = try playTestMove(game, row_col[0], row_col[1]);
    }
    return game;
}

test "a search cut into slices makes the very tree one search of all their iterations makes" {
    const game: *Game = try searchTestGame(&.{ .{ 1, 1 }, .{ 5, 5 } });
    defer testing_allocator.destroy(game);
    const iteration_count: u32 = 800;

    const whole_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, iteration_count + 1);
    defer testing_allocator.free(whole_buffer);
    const whole: SearchTree = try continueSearch(testing_allocator, &game.record, null, whole_buffer, 800, 9, .{});

    // The same 800 iterations as three jobs, each taking up the tree the last returned.
    const sliced_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, iteration_count + 1);
    defer testing_allocator.free(sliced_buffer);
    var sliced: SearchTree = try continueSearch(testing_allocator, &game.record, null, sliced_buffer, 300, 9, .{});
    for ([_]u32{ 200, 300 }) |slice_iterations| {
        sliced = try continueSearch(testing_allocator, &game.record, sliced, &.{}, slice_iterations, 9, .{});
    }
    try expectEqual(whole.header, sliced.header);
    for (whole.nodes[0..whole.header.node_count], sliced.nodes[0..sliced.header.node_count]) |node, sliced_node| {
        try expectEqual(node, sliced_node);
    }
}

test "after the computer's move and a reply it tried, the next search starts from that reply's subtree" {
    const game: *Game = try searchTestGame(&.{ .{ 1, 1 }, .{ 5, 5 } });
    defer testing_allocator.destroy(game);
    const first_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, 1001);
    defer testing_allocator.free(first_buffer);
    const first: SearchTree = try continueSearch(testing_allocator, &game.record, null, first_buffer, 1000, 3, .{});

    // The computer plays its choice; the person replies with the reply the search tried most.
    const move_index: u32 = mostVisitedChild(&first, 0).?;
    const reply_index: u32 = mostVisitedChild(&first, move_index).?;
    _ = playMove(game, first.nodes[move_index].move);
    _ = playMove(game, first.nodes[reply_index].move);

    // With no iteration, the next search's tree is that subtree exactly.
    const second_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, first.header.node_count + 200);
    defer testing_allocator.free(second_buffer);
    const taken_up: SearchTree = try continueSearch(testing_allocator, &game.record, first, second_buffer, 0, 3, .{});
    try expectEqual(@as(u32, 4), taken_up.header.root_moves_played);
    try expectEqual(positionFingerprint(&game.position), taken_up.header.root_fingerprint);
    try expectSameSubtree(&first, reply_index, &taken_up, 0);

    // And its iterations add to the visits it starts with.
    const continued: SearchTree = try continueSearch(testing_allocator, &game.record, taken_up, &.{}, 200, 3, .{});
    try expectEqual(first.nodes[reply_index].visits + 200, continued.nodes[0].visits);
}

test "a tree is not taken up after a reply it never tried, an undo, or in another game" {
    const game: *Game = try searchTestGame(&.{ .{ 1, 1 }, .{ 5, 5 } });
    defer testing_allocator.destroy(game);
    const first_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, 301);
    defer testing_allocator.free(first_buffer);
    const first: SearchTree = try continueSearch(testing_allocator, &game.record, null, first_buffer, 300, 5, .{});
    const fresh_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, first.header.node_count + 100);
    defer testing_allocator.free(fresh_buffer);

    // A reply the search never tried: after 300 iterations on 7 x 7, the most visited move still has untried replies.
    const move_index: u32 = mostVisitedChild(&first, 0).?;
    const move: Point = first.nodes[move_index].move;
    _ = playMove(game, move);
    var untried_reply: ?Point = null;
    for (0..pointCount(7)) |point_index| {
        const reply: Point = @intCast(point_index);
        const reply_is_legal: bool = checkMove(&game.position, reply) == .legal;
        const reply_is_tried: bool = childByMove(&first, move_index, reply) != null;
        if (reply_is_legal and !reply_is_tried) {
            untried_reply = reply;
            break;
        }
    }
    _ = playMove(game, untried_reply.?);
    const after_untried: SearchTree = try continueSearch(
        testing_allocator,
        &game.record,
        first,
        fresh_buffer,
        100,
        5,
        .{},
    );
    try expectEqual(@as(u32, 100), after_untried.nodes[0].visits);

    // An undo past the tree's root: the root's position is no longer in the record.
    _ = undo(game);
    _ = undo(game);
    _ = undo(game);
    const after_undo: SearchTree = try continueSearch(
        testing_allocator,
        &game.record,
        first,
        fresh_buffer,
        100,
        5,
        .{},
    );
    try expectEqual(@as(u32, 100), after_undo.nodes[0].visits);

    // Another game, with as many moves: the fingerprints differ.
    const other_game: *Game = try searchTestGame(&.{ .{ 1, 5 }, .{ 5, 1 } });
    defer testing_allocator.destroy(other_game);
    const elsewhere: SearchTree = try continueSearch(
        testing_allocator,
        &other_game.record,
        first,
        fresh_buffer,
        100,
        5,
        .{},
    );
    try expectEqual(@as(u32, 100), elsewhere.nodes[0].visits);
}

test "a search job's payload carries the record: read back, it replays to the same position" {
    const game: *Game = try searchTestGame(&.{ .{ 1, 1 }, .{ 5, 5 }, .{ 2, 4 } });
    defer testing_allocator.destroy(game);
    var payload_buffer: [4096]u8 = undefined;
    var out: Io.Writer = .fixed(&payload_buffer);
    try writeSearchPayload(&game.record, &.{}, &out);

    const read_game: *Game = try createTestGame();
    defer testing_allocator.destroy(read_game);
    const rest: []const u8 = readSearchPayload(out.buffered(), &read_game.record) orelse {
        return error.TestPayloadRefused;
    };
    try expectEqual(@as(usize, 0), rest.len);
    replayTo(read_game, read_game.record.moves_played);
    try expectSamePosition(&game.position, &read_game.position);
    // A payload cut short is refused.
    try expectEqual(@as(?[]const u8, null), readSearchPayload(out.buffered()[0..10], &read_game.record));
}

test "a search job makes the tree continueSearch makes, with and without a last tree" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const game: *Game = try searchTestGame(&.{ .{ 1, 1 }, .{ 5, 5 } });
    defer testing_allocator.destroy(game);
    const header: SearchJobHeader = .{ .settings = .{}, .iteration_count = 300, .max_node_count = 601, .seed = 17 };

    // Without a last tree.
    var payload_buffer: [64 * 1024]u8 = undefined;
    var payload: Io.Writer = .fixed(&payload_buffer);
    try writeSearchPayload(&game.record, &.{}, &payload);
    var result_buffer: [64 * 1024]u8 = undefined;
    var result: Io.Writer = .fixed(&result_buffer);
    try searchJob(arena, header, payload.buffered(), &result);

    const direct_buffer: []SearchNode = try arena.alloc(SearchNode, 601);
    const direct: SearchTree = try continueSearch(arena, &game.record, null, direct_buffer, 300, 17, .{});
    var direct_bytes_buffer: [64 * 1024]u8 = undefined;
    var direct_bytes: Io.Writer = .fixed(&direct_bytes_buffer);
    try writeTree(&direct, &direct_bytes);
    try expectEqualSlices(u8, direct_bytes.buffered(), result.buffered());

    // With the tree it returned: a second job of 300 equals one search of 600.
    payload = .fixed(&payload_buffer);
    const first_tree_bytes: []const u8 = try arena.dupe(u8, result.buffered());
    try writeSearchPayload(&game.record, first_tree_bytes, &payload);
    result = .fixed(&result_buffer);
    try searchJob(arena, header, payload.buffered(), &result);
    const whole: SearchTree = try continueSearch(arena, &game.record, null, direct_buffer, 600, 17, .{});
    direct_bytes = .fixed(&direct_bytes_buffer);
    try writeTree(&whole, &direct_bytes);
    try expectEqualSlices(u8, direct_bytes.buffered(), result.buffered());
}

/// A clock that moves a tenth of a millisecond each time it is read, for the tests of the search in the frames: the
/// iterations a search runs on it, and so its tree, are the same every run.
const SteppingClock = struct {
    var now_ms: f64 = 0; // lint:off module-var: a test's clock, read through a function pointer as the real one is

    fn read() f64 {
        now_ms += 0.1;
        return now_ms;
    }
};

test "a search in the frames makes the tree one job of as many iterations makes, and takes up the same subtree" {
    const game: *Game = try searchTestGame(&.{ .{ 1, 1 }, .{ 5, 5 } });
    defer testing_allocator.destroy(game);
    const settings: ComputerSettings = .{
        .move_milliseconds = 100,
        .frame_budget_milliseconds = 30,
        .max_tree_nodes = 4000,
    };
    const record: *const Record = &game.record;
    const position: *const Position = &game.position;
    var frame_search: FrameSearch = try .init(testing_allocator, settings);
    defer frame_search.deinit(testing_allocator);
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    // A move of 100 ms in frames of 30: three frames without a move, then the move.
    SteppingClock.now_ms = 0;
    const deadline_ms: f64 = SteppingClock.now_ms + settings.move_milliseconds;
    var chosen: ?Point = null;
    var frame_count: u32 = 0;
    while (chosen == null) : (frame_count += 1) {
        const clock: *const fn () f64 = SteppingClock.read;
        chosen = try frame_search.step(testing_allocator, record, position, settings, 7, deadline_ms, clock);
    }
    try expectEqual(@as(u32, 4), frame_count);
    const iteration_count: u32 = frame_search.last_move_iterations;
    try expect(iteration_count > 0);

    // One job of as many iterations makes the same tree, and plays the same move from it (`playedMove`).
    const job_buffer: []SearchNode = try arena.alloc(SearchNode, 4000);
    const job_tree: SearchTree = try continueSearch(arena, record, null, job_buffer, iteration_count, 7, .{});
    try expectEqual(playedMove(&job_tree, position, settings.search), chosen);
    const frame_tree: SearchTree = frame_search.tree.?;
    try expectEqual(job_tree.header, frame_tree.header);
    try expectSameSubtree(&job_tree, 0, &frame_tree, 0);

    // The move and a reply; the next move's tree, as a job would take it up.
    _ = playMove(game, chosen.?);
    const reply_index: u32 = mostVisitedChild(&job_tree, childByMove(&job_tree, 0, chosen.?).?).?;
    _ = playMove(game, job_tree.nodes[reply_index].move);
    const next_buffer: []SearchNode = try arena.alloc(SearchNode, 4000);
    const job_next: SearchTree = try continueSearch(arena, record, job_tree, next_buffer, 0, 7 +% 4, .{});
    try frame_search.bringTreeTo(testing_allocator, &game.record, &game.position, 7 +% 4);
    try expectSameSubtree(&job_next, 0, &frame_search.tree.?, 0);
}

test "a job's tree stops growing at the node count its header allows" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const game: *Game = try searchTestGame(&.{});
    defer testing_allocator.destroy(game);
    const header: SearchJobHeader = .{ .settings = .{}, .iteration_count = 500, .max_node_count = 100, .seed = 3 };
    var payload_buffer: [8 * 1024]u8 = undefined;
    var payload: Io.Writer = .fixed(&payload_buffer);
    try writeSearchPayload(&game.record, &.{}, &payload);
    var result_buffer: [64 * 1024]u8 = undefined;
    var result: Io.Writer = .fixed(&result_buffer);
    try searchJob(arena, header, payload.buffered(), &result);
    const result_header: SearchTreeHeader = readTreeHeader(result.buffered()).?;
    try expectEqual(@as(u32, 100), result_header.node_count);
}

test "the moves that win at once are the captures that reach the goal, and then the only candidates" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// goban 5x5, black to play
        \\. . . . .
        \\. X O X .
        \\. . X . .
        \\. . . . .
        \\. . . . .
    );
    var buffer: [board_limits.max_points]Point = undefined;
    // A goal of one: the capture at (0, 2) wins, and is the only candidate.
    game.position.capture_goal = 1;
    try expectEqualSlices(Point, &.{pointAt(5, 0, 2)}, winningMoves(&game.position, &buffer));
    try expectEqualSlices(Point, &.{pointAt(5, 0, 2)}, candidateMoves(&game.position, &buffer).moves);
    // A goal of three: the capture takes one stone, which does not reach it, so every legal move is a candidate.
    game.position.capture_goal = 3;
    try expectEqual(@as(usize, 0), winningMoves(&game.position, &buffer).len);
    const legal_count: usize = legalMoves(&game.position, &buffer).len;
    try expectEqual(legal_count, candidateMoves(&game.position, &buffer).moves.len);
    // With two prisoners already, the same capture reaches three.
    game.position.stones_captured_by_black = 2;
    try expectEqualSlices(Point, &.{pointAt(5, 0, 2)}, winningMoves(&game.position, &buffer));
}

test "with decisive moves, the search finds the escape a plain search of as many iterations missed" {
    // Atari Go on 9 x 9 from its starting square; black's (2, 4) leaves white's (3, 4) one liberty, at (3, 5). Without
    // decisive moves, 5,000 iterations chose (4, 5), after which black captures and wins.
    const game: *Game = try searchTestGame(&.{});
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = 1 });
    _ = try playTestMove(game, 2, 4);
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const node_buffer: []SearchNode = try arena.alloc(SearchNode, 5001);
    const tree: SearchTree = try continueSearch(arena, &game.record, null, node_buffer, 5000, 1234, .{});
    try expectEqual(@as(?Point, pointAt(9, 3, 5)), mostVisitedMove(&tree));
}

test "Undo goes back one move between two players, to just before the person's last move against the computer" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 9, .capture_goal = 1 });
    const two_players: Players = .{ .kind = .two_players, .person_stone = .black };
    const person_black: Players = .{ .kind = .against_computer, .person_stone = .black };
    const person_white: Players = .{ .kind = .against_computer, .person_stone = .white };
    const two_computers: Players = .{ .kind = .computer_against_computer, .person_stone = .black };

    // Nothing played: nothing to take back.
    try expectEqual(@as(u16, 0), movesUndoTakesBack(two_players, &game.record));
    try expectEqual(@as(u16, 0), movesUndoTakesBack(person_black, &game.record));

    // Black's first move: the person as black, the computer still thinking - one; the person as white has not moved.
    _ = try playTestMove(game, 2, 2);
    try expectEqual(@as(u16, 1), movesUndoTakesBack(two_players, &game.record));
    try expectEqual(@as(u16, 1), movesUndoTakesBack(person_black, &game.record));
    try expectEqual(@as(u16, 0), movesUndoTakesBack(person_white, &game.record));

    // White replies: the person as black takes back both; the person as white, their one.
    _ = try playTestMove(game, 6, 6);
    try expectEqual(@as(u16, 2), movesUndoTakesBack(person_black, &game.record));
    try expectEqual(@as(u16, 1), movesUndoTakesBack(person_white, &game.record));

    // Black again: the person as white takes back black's move and their own.
    _ = try playTestMove(game, 2, 6);
    try expectEqual(@as(u16, 2), movesUndoTakesBack(person_white, &game.record));
    try expectEqual(@as(u16, 1), movesUndoTakesBack(person_black, &game.record));

    // Between two computers, never.
    try expectEqual(@as(u16, 0), movesUndoTakesBack(two_computers, &game.record));
}

test "scattered stones: so many of each colour, on the second line, clear of the square and each other, none in atari" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const splits = [_][2]u8{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 0 }, .{ 2, 1 }, .{ 1, 2 }, .{ 0, 3 }, .{ 0, 5 }, .{ 0, 7 } };
    for (8..board_limits.max_size + 1) |size| {
        const board_size: u8 = @intCast(size);
        for (splits) |split| {
            for (0..200) |seed| {
                const scattered: ScatteredStones = .{ .black_count = split[0], .white_count = split[1], .seed = seed };
                startGame(game, .{ .board_size = board_size, .capture_goal = 1, .scattered = scattered });
                const position: *const Position = &game.position;
                const record: *const Record = &game.record;
                try expectEqual(@as(u16, 4 + split[0] + split[1]), record.setup_count);

                var black_count: u32 = 0;
                var white_count: u32 = 0;
                for (record.setup[4..record.setup_count]) |setup_stone| {
                    // On the second line, at least 2 from the square, touching no other stone.
                    try expectEqual(@as(u8, 1), linesFromEdge(board_size, setup_stone.point));
                    try expect(distanceFromStartingSquare(board_size, setup_stone.point) >= 2);
                    var neighbor_buffer: [board_limits.max_neighbors]Point = undefined;
                    for (neighborsOf(board_size, setup_stone.point, &neighbor_buffer)) |neighbor| {
                        try expectEqual(Stone.none, position.stones[neighbor]);
                    }
                    if (setup_stone.stone == .black) {
                        black_count += 1;
                    } else {
                        white_count += 1;
                    }
                }
                try expectEqual(@as(u32, split[0]), black_count);
                try expectEqual(@as(u32, split[1]), white_count);

                // No group starts in atari.
                for (0..pointCount(board_size)) |point_index| {
                    const point: Point = @intCast(point_index);
                    if (position.stones[point] != .none) {
                        try expect(soleLiberty(position, point) == null);
                    }
                }
            }
        }
    }
}

test "scattered stones: the same seed scatters the same stones, another seed others" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const first_settings: NewGameSettings = .{
        .board_size = 13,
        .capture_goal = 1,
        .scattered = .{ .black_count = 2, .white_count = 2, .seed = 42 },
    };
    startGame(game, first_settings);
    const first_setup: [8]SetupStone = game.record.setup[0..8].*;
    startGame(game, first_settings);
    try expectEqualSlices(SetupStone, &first_setup, game.record.setup[0..8]);
    var other_settings: NewGameSettings = first_settings;
    other_settings.scattered.seed = 43;
    startGame(game, other_settings);
    try expect(!std.meta.eql(first_setup, game.record.setup[0..8].*));
}

test "scattered stones fit from 7 x 7 for two and 8 x 8 for four; on 6 x 6 the second line is next to the square" {
    const two: ScatteredStones = .evenly(2);
    const four: ScatteredStones = .evenly(4);
    try expect(!scatteredStonesFit(6, two));
    try expect(scatteredStonesFit(7, two));
    try expect(!scatteredStonesFit(7, four));
    try expect(scatteredStonesFit(8, four));
    try expectEqual(@as(?u8, 7), smallestBoardForScatteredStones(two));
    try expectEqual(@as(?u8, 8), smallestBoardForScatteredStones(four));
    // No stones fit every board, and a game without them is the plain Atari Go start.
    try expect(scatteredStonesFit(4, .{}));
}

/// A match of the arena (`zig build goban-arena`): two settings of the search play games of Atari Go from openings
/// with scattered stones - each opening twice, each side black once - and the wins are counted.
const ArenaSettings = struct {
    board_size: u8 = 8,
    capture_goal: u8 = 1,
    scattered: ScatteredStones = .evenly(4),
    /// The same count for both sides, so that the match measures the settings, not the speed - unless
    /// `candidate_iterations_per_move` gives the candidate its own, for a match at equal time between settings whose
    /// iterations cost differently.
    iterations_per_move: u32 = 1000,
    candidate_iterations_per_move: ?u32 = null,
    /// Openings, each played twice.
    opening_count: u32 = 50,
    /// A game still going after this many moves is a draw.
    move_cap: u32 = 200,
};

/// The settings of the arena's game from the opening `opening_seed` scatters: the arena's board and goal, and its
/// scattered stones - their counts and their placement - drawn with that seed.
fn arenaGameSettings(arena: ArenaSettings, opening_seed: u64) NewGameSettings {
    var scattered: ScatteredStones = arena.scattered;
    scattered.seed = opening_seed;
    const settings: NewGameSettings = .{
        .board_size = arena.board_size,
        .capture_goal = arena.capture_goal,
        .scattered = scattered,
    };
    return settings;
}

/// One game of the arena from the opening `opening_seed` scatters: black and white each search with their own
/// settings, a fresh tree each move. Returns the winner, `.none` for a game that reached the move cap.
fn playArenaGame(
    gpa: Allocator,
    black: SearchSettings,
    white: SearchSettings,
    black_iterations: u32,
    white_iterations: u32,
    arena: ArenaSettings,
    opening_seed: u64,
) !Stone {
    const game: *Game = try gpa.create(Game);
    defer gpa.destroy(game);
    startGame(game, arenaGameSettings(arena, opening_seed));
    const node_buffer: []SearchNode = try gpa.alloc(SearchNode, @max(black_iterations, white_iterations) + 1);
    defer gpa.free(node_buffer);
    var move_count: u32 = 0;
    while (game.position.winner == null and move_count < arena.move_cap) : (move_count += 1) {
        const black_to_play: bool = game.position.player_to_move == .black;
        const settings: SearchSettings = if (black_to_play) black else white;
        const seed: u64 = opening_seed *% 1_000_003 +% move_count;
        const iterations: u32 = if (black_to_play) black_iterations else white_iterations;
        const tree: SearchTree = try continueSearch(gpa, &game.record, null, node_buffer, iterations, seed, settings);
        const move: Point = playedMove(&tree, &game.position, settings) orelse {
            break;
        };
        _ = playMove(game, move);
    }
    return game.position.winner orelse .none;
}

/// Plays the arena's match of `candidate` against `baseline` and prints its score under `name`.
fn playArenaMatch(
    name: []const u8,
    candidate: SearchSettings,
    baseline: SearchSettings,
    arena: ArenaSettings,
) !void {
    var candidate_wins: u32 = 0;
    var baseline_wins: u32 = 0;
    var draws: u32 = 0;
    // The openings by how their two games went: both to the candidate, both to the baseline, or one each - split
    // by colour, when the opening favours one so much that either setting wins with it, and the pair measures
    // nothing.
    var candidate_pairs: u32 = 0;
    var baseline_pairs: u32 = 0;
    var split_pairs: u32 = 0;
    // How often black won: far from a half, the first move - or the colour's outposts - decides the games.
    var black_wins: u32 = 0;
    for (0..arena.opening_count) |opening_index| {
        const opening_seed: u64 = 7919 *% (opening_index + 1);
        var candidate_wins_here: u32 = 0;
        for ([_]Stone{ .black, .white }) |candidate_stone| {
            const candidate_is_black: bool = candidate_stone == .black;
            const black: SearchSettings = if (candidate_is_black) candidate else baseline;
            const white: SearchSettings = if (candidate_is_black) baseline else candidate;
            const candidate_iterations: u32 = arena.candidate_iterations_per_move orelse arena.iterations_per_move;
            const baseline_iterations: u32 = arena.iterations_per_move;
            const black_iterations: u32 = if (candidate_is_black) candidate_iterations else baseline_iterations;
            const white_iterations: u32 = if (candidate_is_black) baseline_iterations else candidate_iterations;
            const winner: Stone = try playArenaGame(
                testing_allocator,
                black,
                white,
                black_iterations,
                white_iterations,
                arena,
                opening_seed,
            );
            if (winner == .black) {
                black_wins += 1;
            }
            if (winner == .none) {
                draws += 1;
            } else if (winner == candidate_stone) {
                candidate_wins += 1;
                candidate_wins_here += 1;
            } else {
                baseline_wins += 1;
            }
        }
        switch (candidate_wins_here) {
            2 => candidate_pairs += 1,
            0 => baseline_pairs += 1,
            else => split_pairs += 1,
        }
    }
    const opening_count: usize = arena.opening_count;
    const games: f64 = @floatFromInt(2 * opening_count);
    const score: f64 = (float64(candidate_wins) + 0.5 * float64(draws)) / games;
    const standard_error: f64 = @sqrt(score * (1 - score) / games);
    const format: []const u8 = "arena: {s}: the candidate {d}, the baseline {d}, draws {d} of {d} games - " ++
        "score {d:.1}% +- {d:.1}\n";
    std.debug.print(format, .{
        name,
        candidate_wins,
        baseline_wins,
        draws,
        2 * opening_count,
        100 * score,
        100 * standard_error,
    });
    const pairs_format: []const u8 = "arena: {s}: openings won twice by the candidate {d}, by the baseline {d}, " ++
        "split {d}; black won {d} of {d} games\n";
    const game_count: usize = 2 * opening_count;
    std.debug.print(pairs_format, .{
        name,
        candidate_pairs,
        baseline_pairs,
        split_pairs,
        black_wins,
        game_count,
    });
}

/// The arena on go puzzles hero's board (the section's lesson): 10 x 10, two outposts each, on the second and third
/// lines and never in front of the square - an even split, so that either side may play black.
const hero_arena: ArenaSettings = .{
    .board_size = 10,
    .scattered = .{
        .black_count = 2,
        .white_count = 2,
        .nearest_line = 1,
        .farthest_line = 2,
        .keeps_square_front_clear = true,
    },
    .opening_count = 30,
};

test "a playout cut short is scored by its liberties: a capture open, the weaker group, a tie half each" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    // White's stone is in atari, its liberty black's to take: black's game.
    try startTestGameFromDiagram(game,
        \\// goban 5x5, black to play
        \\. . . . .
        \\. X O X .
        \\. . X . .
        \\. . . . .
        \\. . . . .
    );
    try expectEqual(Stone.black, cutShortWinner(&game.position, .half, 1));
    // Black's weakest group has two liberties, white's three: white's.
    try startTestGameFromDiagram(game,
        \\// goban 5x5, black to play
        \\. . . . .
        \\. . O . .
        \\. O X . .
        \\. . . . .
        \\. . . . .
    );
    try expectEqual(Stone.white, cutShortWinner(&game.position, .half, 1));
    // Both weakest groups have three liberties: undecided - or, by the old rule, the player to move's.
    try startTestGameFromDiagram(game,
        \\// goban 5x5, white to play
        \\. . . . .
        \\. . . . .
        \\. X . O .
        \\. . . . .
        \\. . . . .
    );
    try expectEqual(Stone.none, cutShortWinner(&game.position, .half, 1));
    try expectEqual(Stone.white, cutShortWinner(&game.position, .player_to_move, 1));
}

/// The search's own choice every move (`playedMove`): no fighting rule, neither for close choices nor for decided
/// positions - the arena's settings when what is measured is the search.
const own_choice: SearchSettings = .{ .lost_below_rate = 0, .won_above_rate = 1, .fights_tenuki = false };

test "arena: the fighting rule, now only where it cannot change the result, against the search's own choice" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    var arena: ArenaSettings = hero_arena;
    arena.opening_count = 100;
    arena.iterations_per_move = 500;
    try playArenaMatch("the strict fighting rule against own choice", .{}, own_choice, arena);
}

/// This morning's search, as it was before the day's measures (`own_choice`, no fighting rule): exploration 0.6,
/// playouts to their end, and - when cut - the weakest group alone in the score.
const morning_search: SearchSettings = .{
    .exploration = 0.6,
    .playout_cutoff = 0,
    .cut_groups_compared = 1,
    .lost_below_rate = 0,
    .won_above_rate = 1,
    .fights_tenuki = false,
};

test "arena: today's search against this morning's, at equal time" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    // This morning's iteration, playouts to their end, about 9.5 us; today's, cut after two moves, about 3.5: in
    // the same time, 2.7 times as many.
    var arena: ArenaSettings = hero_arena;
    arena.opening_count = 25;
    arena.iterations_per_move = 2000;
    arena.candidate_iterations_per_move = 5400;
    try playArenaMatch("today's search against this morning's, at equal time", own_choice, morning_search, arena);
}

test "arena: the arena's controls with the search's own choice every move - no fighting rule - on 10 x 10" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    var light: SearchSettings = own_choice;
    light.playout_kind = .light;
    var tenth: ArenaSettings = hero_arena;
    tenth.opening_count = 100;
    tenth.iterations_per_move = 50;
    tenth.candidate_iterations_per_move = 500;
    try playArenaMatch("own choice, 500 against 50 iterations", own_choice, own_choice, tenth);
    var random_playouts: ArenaSettings = hero_arena;
    random_playouts.opening_count = 100;
    random_playouts.iterations_per_move = 500;
    try playArenaMatch("own choice, heavy playouts against light", own_choice, light, random_playouts);
}

test "arena: the speed of cut-short playouts, on go puzzles hero's board" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    const game: *Game = try testing_allocator.create(Game);
    defer testing_allocator.destroy(game);
    const io = std.testing.io;
    const iteration_count: u32 = 40_000;
    const node_buffer: []SearchNode = try testing_allocator.alloc(SearchNode, iteration_count + 1);
    defer testing_allocator.free(node_buffer);
    var nanoseconds: [2]f64 = .{ 0, 0 };
    const settings_pair = [2]SearchSettings{ .{ .playout_cutoff = 0 }, .{} };
    for (0..5) |opening_index| {
        const opening_seed: u64 = 7919 *% (opening_index + 1);
        startGame(game, arenaGameSettings(hero_arena, opening_seed));
        for (settings_pair, 0..) |settings, settings_index| {
            const started: Io.Timestamp = .now(io, .awake);
            _ = try continueSearch(testing_allocator, &game.record, null, node_buffer, iteration_count, 1, settings);
            nanoseconds[settings_index] += float64(started.durationTo(.now(io, .awake)).nanoseconds);
        }
    }
    const iterations_run: f64 = 5 * float64(iteration_count);
    const full_us: f64 = nanoseconds[0] / iterations_run / 1000;
    const cut_us: f64 = nanoseconds[1] / iterations_run / 1000;
    const speed_format: []const u8 = "arena: an iteration, playouts to the end {d:.2} us, cut short as by default " ++
        "{d:.2} us - {d:.2} times as many\n";
    std.debug.print(speed_format, .{ full_us, cut_us, full_us / cut_us });
}

test "a node's candidates found one after another are its whole list, in its order - from many positions" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    var candidate_buffer: [board_limits.max_points]Point = undefined;
    for (0..20) |opening_index| {
        startGame(game, arenaGameSettings(hero_arena, 7919 *% (opening_index + 1)));
        var generator: Xoshiro256 = .init(opening_index);
        for (0..30) |_| {
            if (game.position.winner != null) {
                break;
            }
            const candidates: Candidates = candidateMoves(&game.position, &candidate_buffer);
            if (candidates.moves.len > 0) {
                var previous: Point = candidates.moves[0];
                for (candidates.moves[1..]) |expected| {
                    const next: ?Point = nextCandidate(&game.position, candidates.kind, previous);
                    try expectEqual(@as(?Point, expected), next);
                    previous = expected;
                }
                try expectEqual(@as(?Point, null), nextCandidate(&game.position, candidates.kind, previous));
            }
            const move: Point = randomLegalMove(&game.position, generator.random()) orelse {
                break;
            };
            _ = playMove(game, move);
        }
    }
}

test "a forced move - one candidate, a winning capture - is played after one iteration, not after the move's time" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// goban 5x5, black to play
        \\. . . . .
        \\. X O X .
        \\. . X . .
        \\. . . . .
        \\. . . . .
    );
    game.position.capture_goal = 1;
    game.record.capture_goal = 1;
    const settings: ComputerSettings = .{ .move_milliseconds = 1_000_000, .max_tree_nodes = 100 };
    var frame_search: FrameSearch = try .init(testing_allocator, settings);
    defer frame_search.deinit(testing_allocator);
    SteppingClock.now_ms = 0;
    const clock: *const fn () f64 = SteppingClock.read;
    const record: *const Record = &game.record;
    const position: *const Position = &game.position;
    const move: ?Point = try frame_search.step(testing_allocator, record, position, settings, 1, 1_000_000, clock);
    try expectEqual(@as(?Point, pointAt(5, 0, 2)), move);
    try expectEqual(@as(u32, 1), frame_search.last_move_iterations);
}

test "a node's candidates, found one by one past the last, are the whole list made at once - for every kind" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    var generator: DefaultPrng = .init(77);
    const random: Random = generator.random();
    var kinds_seen: [@typeInfo(CandidateKind).@"enum".field_names.len]bool = @splat(false);
    for (0..300) |game_index| {
        const scattered: ScatteredStones = .{ .black_count = 2, .white_count = 2, .seed = game_index };
        startGame(game, .{ .board_size = 8, .capture_goal = 1, .scattered = scattered });
        // Random moves until the game is won or a move cap, every position on the way checked.
        for (0..40) |_| {
            if (game.position.winner != null) {
                break;
            }
            var buffer: [board_limits.max_points]Point = undefined;
            const candidates: Candidates = candidateMoves(&game.position, &buffer);
            kinds_seen[@backingInt(candidates.kind)] = true;
            // The first, then each next past the one before; then none.
            for (candidates.moves[1..], 0..) |expected, before_index| {
                const before: Point = candidates.moves[before_index];
                const found: ?Point = nextCandidate(&game.position, candidates.kind, before);
                try expectEqual(@as(?Point, expected), found);
            }
            if (candidates.moves.len > 0) {
                const last: Point = candidates.moves[candidates.moves.len - 1];
                try expectEqual(@as(?Point, null), nextCandidate(&game.position, candidates.kind, last));
            }
            const move: Point = randomLegalMove(&game.position, random) orelse {
                break;
            };
            _ = playMove(game, move);
        }
    }
    // Every kind of list came up, so every test was tried.
    for (kinds_seen) |seen| {
        try expect(seen);
    }
}

test "the outpost ladder: each rung played moving first, then second; a win one position up, a loss one down" {
    const ladder: OutpostLadder = .{ .person_start = 2 };
    // On 8 x 8 the second line holds seven: from 2 - 0, the rungs go to 0 - 7, ten rungs, 20 positions.
    try expectEqual(@as(u8, 20), ladder.positionCount(8));
    // Every rung's split - the computer given a stone, another, then one of the person's taken - and each rung's
    // first player, the person black.
    const expected = [_][2]u8{
        .{ 2, 0 }, .{ 2, 1 }, .{ 2, 2 }, .{ 1, 2 }, .{ 1, 3 },
        .{ 1, 4 }, .{ 0, 4 }, .{ 0, 5 }, .{ 0, 6 }, .{ 0, 7 },
    };
    var total_before: u8 = 0;
    for (expected, 0..) |split, rung_index| {
        for (0..2) |game_in_rung| {
            const position: u8 = @intCast(2 * rung_index + game_in_rung);
            const stones: ScatteredStones = ladder.stonesAt(position, .black);
            try expectEqual(split[0], stones.black_count);
            try expectEqual(split[1], stones.white_count);
            const first: Stone = if (game_in_rung == 0) .black else .white;
            try expectEqual(first, ladder.firstPlayerAt(position, .black));
            try expect(scatteredStonesFit(8, stones));
        }
        // Each rung's stones one more than the last's at most.
        const total: u8 = split[0] + split[1];
        try expect(rung_index == 0 or total <= total_before + 1);
        total_before = total;
    }
    // A win up, a loss down, the ends holding.
    try expectEqual(@as(u8, 1), ladder.nextPosition(8, 0, .black, .black));
    try expectEqual(@as(u8, 0), ladder.nextPosition(8, 1, .white, .black));
    try expectEqual(@as(u8, 0), ladder.nextPosition(8, 0, .white, .black));
    try expectEqual(@as(u8, 19), ladder.nextPosition(8, 19, .black, .black));
    try expectEqual(@as(u8, 5), ladder.nextPosition(8, 5, .none, .black));
    // The person white: their stones white, and on a rung's first game, white moves first.
    const as_white: ScatteredStones = ladder.stonesAt(2, .white);
    try expectEqual(@as(u8, 1), as_white.black_count);
    try expectEqual(@as(u8, 2), as_white.white_count);
    try expectEqual(Stone.white, ladder.firstPlayerAt(2, .white));
}

test "a game whose first player is white starts with white to play, and its moves are counted from white" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGame(game, .{ .board_size = 8, .capture_goal = 1, .first_player = .white });
    try expectEqual(Stone.white, game.position.player_to_move);
    _ = try playTestMove(game, 1, 1);
    try expectEqual(Stone.white, moverOfMove(&game.record, 0));
    try expectEqual(Stone.black, game.position.player_to_move);
}

/// goban's first three easy problems, by name: the families the problem tests read, whatever order the index has.
const easy_problem_families = [_]ProblemFamily{
    familyNamed("ggg-easy-01.sgf"),
    familyNamed("ggg-easy-02.sgf"),
    familyNamed("ggg-easy-03.sgf"),
};

test "goban's kill problems read: 19 x 19, black to play, the target a white stone" {
    // The easy problems' targets as goban_problems_tool found them: pq, qq and rq, column then row.
    const expected = [_]struct { black: u32, white: u32, target: [2]u8 }{
        .{ .black = 9, .white = 7, .target = .{ 15, 16 } },
        .{ .black = 10, .white = 8, .target = .{ 16, 16 } },
        .{ .black = 9, .white = 7, .target = .{ 17, 16 } },
    };
    for (easy_problem_families[0..expected.len], expected) |family, problem_expected| {
        const sgf: []const u8 = family.sgf;
        const problem: Problem = try readProblem(sgf);
        try expectEqual(@as(u8, 19), problem.setup.board_size);
        try expectEqual(Stone.black, problem.setup.player_to_move);
        var black_count: u32 = 0;
        var white_count: u32 = 0;
        for (problem.setup.stones[0..pointCount(19)]) |stone| {
            black_count += @intFromBool(stone == .black);
            white_count += @intFromBool(stone == .white);
        }
        try expectEqual(problem_expected.black, black_count);
        try expectEqual(problem_expected.white, white_count);
        const target_expected: Point = pointAt(19, problem_expected.target[1], problem_expected.target[0]);
        try expectEqual(target_expected, problem.target);
        try expectEqual(Stone.white, problem.setup.stones[problem.target]);
    }
}

test "an SGF kill problem with a rectangle of stones, and the refusals" {
    // `aa:bb` is the four points of the rectangle; the white stone at `dd` is marked.
    const rectangle: Problem = try readProblem("(;SZ[9]AB[aa:bb]AW[dd]TR[dd])");
    try expectEqual(@as(u8, 9), rectangle.setup.board_size);
    try expectEqual(Stone.black, rectangle.setup.stones[pointAt(9, 1, 1)]);
    try expectEqual(Stone.none, rectangle.setup.stones[pointAt(9, 2, 2)]);
    try expectEqual(pointAt(9, 3, 3), rectangle.target);
    // A property's values may have spaces between them, and an escaped bracket stays inside a comment.
    _ = try readProblem("( ; SZ[9] AW [dd] [de] C[a \\] in a comment] TR[dd] ;B[aa])");

    try expectError(SgfError.NotSgf, readProblem("SZ[9]"));
    try expectError(SgfError.UnterminatedValue, readProblem("(;SZ[9]AW[dd"));
    try expectError(SgfError.UnsupportedBoardSize, readProblem("(;SZ[13:9]AW[dd]TR[dd])"));
    try expectError(SgfError.UnsupportedBoardSize, readProblem("(;SZ[2]AW[aa]TR[aa])"));
    try expectError(SgfError.BadPoint, readProblem("(;SZ[9]AW[zz]TR[zz])"));
    try expectError(SgfError.StoneTwice, readProblem("(;SZ[9]AB[dd]AW[dd]TR[dd])"));
    try expectError(SgfError.GroupWithoutLiberty, readProblem("(;SZ[9]AW[aa]AB[ba][ab]TR[aa])"));
    try expectError(SgfError.NoSingleTarget, readProblem("(;SZ[9]AW[dd])"));
    try expectError(SgfError.NoSingleTarget, readProblem("(;SZ[9]AW[dd][ee]TR[dd][ee])"));
    try expectError(SgfError.TargetWrongColour, readProblem("(;SZ[9]AB[dd]TR[dd])"));
    try expectError(SgfError.TargetWrongColour, readProblem("(;SZ[9]AW[dd]SQ[dd])"));
    try expectError(SgfError.NoSingleTarget, readProblem("(;SZ[9]AW[dd]AB[ff]TR[dd]SQ[ff])"));
    // A square on a black stone: a life problem.
    const life: Problem = try readProblem("(;SZ[9]AB[dd]AW[ee]SQ[dd])");
    try expectEqual(ProblemKind.live, life.kind);
    try expectEqual(pointAt(9, 3, 3), life.target);
}

test "a kill problem: its region refuses the moves outside it, and capturing the target wins" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    // The white stone at (2, 2) is the target; black's stones around it leave it one liberty, (3, 2).
    const problem: Problem = try readProblem("(;SZ[9]AB[cb][bc][dc]AW[cc]TR[cc])");
    startProblem(game, &problem, .{});
    const region: ProblemRegion = game.record.region.?;
    try expectEqual(ProblemRegion{ .first_row = 0, .first_col = 0, .last_row = 3, .last_col = 4 }, region);
    try expectEqual(Legality.outside_problem, checkMove(&game.position, pointAt(9, 8, 8)));
    try expectEqual(Legality.legal, checkMove(&game.position, pointAt(9, 3, 2)));
    _ = try playTestMove(game, 3, 2);
    try expectEqual(@as(?Stone, .black), game.position.winner);
    try expectEqual(Legality.game_over, checkMove(&game.position, pointAt(9, 0, 0)));
}

test "an eye of the player to move's: every neighbour its stone, and too few of the opponent's on the diagonals" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    try startTestGameFromDiagram(game,
        \\// goban 7x7, black to play
        \\. X . . . . .
        \\X . X . . . .
        \\. X . . . . .
        \\. . . . X . .
        \\. . . X . X O
        \\. . O . X . .
        \\. . . O . . .
    );
    const position: *const Position = &game.position;
    // (1, 1): black all round, no white diagonal - an eye. (0, 0): two black neighbours in the corner - an eye.
    try expect(isOwnEye(position, pointAt(7, 1, 1)));
    try expect(isOwnEye(position, pointAt(7, 0, 0)));
    // (4, 4): black all round, one white diagonal at (5, 5)? none - and (3, 5) empty: still an eye in the middle.
    try expect(isOwnEye(position, pointAt(7, 4, 4)));
    // (1, 3) has an empty neighbour: no eye.
    try expect(!isOwnEye(position, pointAt(7, 1, 3)));
}

/// The book's correct first move of each of goban's easy kill problems, and the iterations the search needs to find
/// it: rs, rs and ss - column then row, as SGF writes them. The third needs the most: after its correct move white's
/// group is dead, but the random playouts that must capture it often let white take a vital point first, so its death
/// shows only over many of them.
const easy_problem_answers = [_]struct { col_row: [2]u8, iterations: u32 }{
    .{ .col_row = .{ 17, 18 }, .iterations = 30_000 },
    .{ .col_row = .{ 17, 18 }, .iterations = 30_000 },
    .{ .col_row = .{ 18, 18 }, .iterations = 300_000 },
};

/// Checks that the search's move in each of goban's kill problems `first .. end` is the book's.
fn expectSearchSolvesEasyProblems(first: usize, end: usize) !void {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const game: *Game = try arena.create(Game);
    const node_buffer: []SearchNode = try arena.alloc(SearchNode, 300_001);
    for (easy_problem_families[first..end], easy_problem_answers[first..end]) |family, problem_expected| {
        const sgf: []const u8 = family.sgf;
        const expected_col_row: [2]u8 = problem_expected.col_row;
        const iteration_count: u32 = problem_expected.iterations;
        const problem: Problem = try readProblem(sgf);
        startProblem(game, &problem, .{});
        const tree: SearchTree = try continueSearch(arena, &game.record, null, node_buffer, iteration_count, 1, .{});
        const expected_move: Point = pointAt(19, expected_col_row[1], expected_col_row[0]);
        try expectEqual(@as(?Point, expected_move), mostVisitedMove(&tree));
    }
}

test "the search solves goban's first two easy kill problems: it plays the book's first move" {
    try expectSearchSolvesEasyProblems(0, 2);
}

test "arena: the search solves goban's third easy kill problem, at 300,000 iterations" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    try expectSearchSolvesEasyProblems(2, 3);
}

test "an SGF problem's first moves: one per variation, correct when a line under it ends Correct" {
    var buffer: [board_limits.max_points]SgfFirstMove = undefined;
    // Easy problem 1: rs is the correct first move; rq, ns and ps are refuted.
    const root: SgfRoot = try readSgfRoot(easy_problem_families[0].sgf);
    const first_moves: []const SgfFirstMove = try readSgfFirstMoves(easy_problem_families[0].sgf, &root, &buffer);
    const expected = [_]struct { col_row: [2]u8, correct: bool }{
        .{ .col_row = .{ 17, 18 }, .correct = true },
        .{ .col_row = .{ 17, 16 }, .correct = false },
        .{ .col_row = .{ 13, 18 }, .correct = false },
        .{ .col_row = .{ 15, 18 }, .correct = false },
    };
    try expectEqual(expected.len, first_moves.len);
    for (first_moves, expected) |first_move, move_expected| {
        const point_expected: Point = pointAt(19, move_expected.col_row[1], move_expected.col_row[0]);
        try expectEqual(point_expected, first_move.point);
        try expectEqual(move_expected.correct, first_move.leads_to_correct);
    }
    // A solution as one line, with no variation; and a move opening two variations, correct when either is.
    const single_text: []const u8 = "(;SZ[9]AW[dd];B[de];W[ee];B[ed]C[Correct])";
    const single_root: SgfRoot = try readSgfRoot(single_text);
    const single: []const SgfFirstMove = try readSgfFirstMoves(single_text, &single_root, &buffer);
    try expectEqual(@as(usize, 1), single.len);
    try expect(single[0].leads_to_correct);
    const twice_text: []const u8 = "(;SZ[9]AW[dd](;B[de];W[ee])(;B[de];W[cd];B[ce]C[Correct. A \\] bracket])(;B[cc]))";
    const twice_root: SgfRoot = try readSgfRoot(twice_text);
    const twice: []const SgfFirstMove = try readSgfFirstMoves(twice_text, &twice_root, &buffer);
    try expectEqual(@as(usize, 2), twice.len);
    try expect(twice[0].leads_to_correct);
    try expect(!twice[1].leads_to_correct);
}

test "every one of goban's problems reads: a kill problem's target white, a life problem's black" {
    for (kill_problem_sgfs) |sgf| {
        const problem: Problem = try readProblem(sgf);
        try expectEqual(ProblemKind.kill, problem.kind);
        try expectEqual(Stone.white, problem.setup.stones[problem.target]);
    }
    for (life_problem_sgfs) |sgf| {
        const problem: Problem = try readProblem(sgf);
        try expectEqual(ProblemKind.live, problem.kind);
        try expectEqual(Stone.black, problem.setup.stones[problem.target]);
    }
    // In turn: kill, life, kill, life, kill, life, then the kill problems left.
    try expectEqual(kill_problem_sgfs[0].ptr, alternating_problem_sgfs[0].ptr);
    try expectEqual(life_problem_sgfs[0].ptr, alternating_problem_sgfs[1].ptr);
    try expectEqual(kill_problem_sgfs[1].ptr, alternating_problem_sgfs[2].ptr);
    const last_kill: []const u8 = kill_problem_sgfs[kill_problem_sgfs.len - 1];
    try expectEqual(last_kill.ptr, alternating_problem_sgfs[problem_sgfs.len - 1].ptr);
}

test "an SGF problem's correct line, and a setup with its colours swapped" {
    var line_buffer: [record_limits.max_moves]Point = undefined;
    // Easy problem 1: B rs, W rr, B ns - the first line that reaches "Correct".
    const root: SgfRoot = try readSgfRoot(easy_problem_families[0].sgf);
    const line: []const Point = try readSgfCorrectLine(easy_problem_families[0].sgf, &root, &line_buffer);
    const expected = [_]Point{ pointAt(19, 18, 17), pointAt(19, 17, 17), pointAt(19, 18, 13) };
    try expectEqualSlices(Point, &expected, line);
    // A line with no "Correct" in it gives none; a "Correct" in the middle of a line ends it there.
    const none_text: []const u8 = "(;SZ[9]AW[dd](;B[de];W[ee]))";
    const none_root: SgfRoot = try readSgfRoot(none_text);
    try expectEqual(@as(usize, 0), (try readSgfCorrectLine(none_text, &none_root, &line_buffer)).len);
    const middle_text: []const u8 = "(;SZ[9]AW[dd](;B[cc];W[ee])(;B[de]C[Correct];W[ed]))";
    const middle_root: SgfRoot = try readSgfRoot(middle_text);
    const middle: []const Point = try readSgfCorrectLine(middle_text, &middle_root, &line_buffer);
    try expectEqualSlices(Point, &.{pointAt(9, 4, 3)}, middle);

    const swapped: DiagramSetup = swapColours(&root.setup);
    for (root.setup.stones[0..pointCount(19)], swapped.stones[0..pointCount(19)]) |stone, swapped_stone| {
        const expected_stone: Stone = if (stone == .none) .none else stone.opponent();
        try expectEqual(expected_stone, swapped_stone);
    }
    try expectEqual(Stone.black, swapped.player_to_move);
}

test "the board's eight symmetries: each moves every point to a point of its own; four quarter turns are none" {
    for ([_]u8{ 5, 8, 19 }) |board_size| {
        for (std.enums.values(Symmetry)) |symmetry| {
            var reached: PointSet = .empty;
            for (0..pointCount(board_size)) |point_index| {
                reached.set(symmetry.transformPoint(board_size, @intCast(point_index)));
            }
            try expectEqual(pointCount(board_size), reached.count());
        }
        for (0..pointCount(board_size)) |point_index| {
            var point: Point = @intCast(point_index);
            for (0..4) |_| {
                point = Symmetry.quarter_turn.transformPoint(board_size, point);
            }
            try expectEqual(@as(Point, @intCast(point_index)), point);
        }
    }
    // A problem drawn in a symmetry keeps its stones and its target, a white stone.
    const problem: Problem = try readProblem(easy_problem_families[0].sgf);
    for (std.enums.values(Symmetry)) |symmetry| {
        const shown: Problem = transformedProblem(&problem, symmetry);
        try expectEqual(Stone.white, shown.setup.stones[shown.target]);
        var stone_count: usize = 0;
        for (shown.setup.stones[0..pointCount(19)]) |stone| {
            stone_count += @intFromBool(stone != .none);
        }
        try expectEqual(@as(usize, 16), stone_count);
    }
}

test "a kill problem's layout shows its region in the middle of the window, and the rest of the board off it" {
    const style: BoardStyle = .{};
    const region: ProblemRegion = .{ .first_row = 12, .first_col = 11, .last_row = 18, .last_col = 18 };
    const layout: BoardLayout = .forRegion(900, 600, 19, region, style);
    // The region's middle - row 15, column 14.5 - at the window's middle, to the pixel.
    const middle_px: Vec2 = layout.pointPosition(pointAt(19, 15, 14)) + Vec2{ layout.spacing_px / 2, 0 };
    try expect(@abs(middle_px[0] - 450) <= 1 and @abs(middle_px[1] - 300) <= 1);
    // Every point of the region inside the window; the board's far corner outside it.
    for (region.first_row..@as(usize, region.last_row) + 1) |row| {
        for (region.first_col..@as(usize, region.last_col) + 1) |col| {
            const position_px: Vec2 = layout.pointPosition(pointAt(19, @intCast(row), @intCast(col)));
            try expect(position_px[0] > 0 and position_px[0] < 900 and position_px[1] > 0 and position_px[1] < 600);
        }
    }
    const far_corner_px: Vec2 = layout.pointPosition(pointAt(19, 0, 0));
    try expect(far_corner_px[0] < 0 and far_corner_px[1] < 0);
}

test "a problem's solution tree: the book's answers, its correct lines, and moves it does not have" {
    var tree: SolutionTree = undefined;
    const root: SgfRoot = try readSgfRoot(easy_problem_families[0].sgf);
    try readSolutionTree(easy_problem_families[0].sgf, &root, &tree);
    const rs: Point = pointAt(19, 18, 17);
    const rr: Point = pointAt(19, 17, 17);
    const ns: Point = pointAt(19, 18, 13);
    const ps: Point = pointAt(19, 18, 15);
    const rq: Point = pointAt(19, 16, 17);
    // Four first moves; after rs the book answers rr.
    var reply_buffer: [8]Point = undefined;
    try expectEqual(@as(usize, 4), tree.repliesAfter(&.{}, &reply_buffer).len);
    try expectEqualSlices(Point, &.{rr}, tree.repliesAfter(&.{rs}, &reply_buffer));
    // rs rr ns is "Correct", rs rr ps "Also correct"; rs rr alone is not yet, rq rr not at all.
    try expect(tree.isSolvedBy(&.{ rs, rr, ns }));
    try expect(tree.isSolvedBy(&.{ rs, rr, ps }));
    try expect(!tree.isSolvedBy(&.{ rs, rr }));
    try expect(!tree.isSolvedBy(&.{ rq, rr, ns }));
    // A move the book does not have leaves the tree.
    try expectEqual(@as(?u16, null), tree.nodeAfter(&.{ rs, ns }));
    // Drawn in a symmetry, the tree's moves move with the problem's.
    const turned: SolutionTree = tree.transformed(19, .half_turn);
    const turned_rs: Point = Symmetry.half_turn.transformPoint(19, rs);
    const turned_rr: Point = Symmetry.half_turn.transformPoint(19, rr);
    try expectEqualSlices(Point, &.{turned_rr}, turned.repliesAfter(&.{turned_rs}, &reply_buffer));
}

test "Benson's algorithm: two eyes alive, one eye not, a seki not, an eye with a dead stone in it still an eye" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    // Black's corner group with two separate eyes, (0, 0) and (0, 2): alive.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, black to play
        \\. X . X O . .
        \\X X X X O . .
        \\O O O O O . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    try expect(isUnconditionallyAlive(&game.position, pointAt(7, 1, 1)));
    // One eye only, (0, 0): not alive.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, black to play
        \\. X X X O . .
        \\X X X X O . .
        \\O O O O O . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    try expect(!isUnconditionallyAlive(&game.position, pointAt(7, 1, 1)));
    // A seki: black and white share the two liberties (0, 2) and (0, 3), and neither can play there. Alive in fact,
    // but not unconditionally: Benson's algorithm does not say so.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, black to play
        \\X X . . O O X
        \\O X X O O X X
        \\O O X O X X .
        \\. O X X X . .
        \\. O O O . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    try expect(!isUnconditionallyAlive(&game.position, pointAt(7, 0, 1)));
    // Two eyes, one of them with a white stone inside that black has in atari: the region of that stone and the empty
    // point is vital - its one empty point is black's liberty - so black is alive.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, black to play
        \\. X O . X O .
        \\X X X X X O .
        \\O O O O O O .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    try expect(isUnconditionallyAlive(&game.position, pointAt(7, 1, 1)));
    try expect(!isUnconditionallyAlive(&game.position, pointAt(7, 0, 2)));
}

test "a target of either colour: its capture wins for its opponent, and an undecided playout goes to its owner" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    // A black target in atari, white to play: white's capture at (0, 2) is the one winning move, and wins for white.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, white to play
        \\. . X O . . .
        \\. . O . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    game.record.target = pointAt(7, 0, 2);
    replayTo(game, 0);
    var buffer: [board_limits.max_points]Point = undefined;
    try expectEqualSlices(Point, &.{pointAt(7, 0, 1)}, winningMoves(&game.position, &buffer));
    // Black's turn instead: the defender has no winning move.
    game.record.setup_to_play = .black;
    replayTo(game, 0);
    try expectEqual(@as(usize, 0), winningMoves(&game.position, &buffer).len);
    // A black target alive with two eyes, white to play in a small region: no playout captures it, so every one
    // ends undecided - and goes to black, its owner.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, white to play
        \\. X . X O . .
        \\X X X X O . .
        \\O O O O O . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    game.record.target = pointAt(7, 1, 1);
    game.record.region = .{ .first_row = 0, .first_col = 0, .last_row = 3, .last_col = 6 };
    replayTo(game, 0);
    var generator: DefaultPrng = .init(5);
    for (0..50) |_| {
        var scratch: Position = game.position;
        try expectEqual(Stone.black, playOut(&scratch, generator.random(), .{}, &.{}));
    }
}

test "a problem is solved by its target's capture, the book, unconditional life, or the computer giving up" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const settings: ProblemPlaySettings = .{};
    const no_tree: SolutionTree = .empty;
    // A life problem, its black target alive with two eyes: solved by Benson's algorithm, with no book.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, white to play
        \\. X . X O . .
        \\X X X X O . .
        \\O O O O O . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    game.record.target = pointAt(7, 1, 1);
    replayTo(game, 0);
    const living: ProblemEvidence = .{ .kind = .live, .refuted = false, .hopeless_moves = 0 };
    try expect(isProblemSolved(&game.position, &no_tree, &.{}, living, settings));
    // The same as a kill problem's position: unconditional life solves nothing for the attacker.
    const killing: ProblemEvidence = .{ .kind = .kill, .refuted = false, .hopeless_moves = 0 };
    try expect(!isProblemSolved(&game.position, &no_tree, &.{}, killing, settings));
    // The computer giving up twice solves either kind; once is not enough.
    const given_up: ProblemEvidence = .{ .kind = .kill, .refuted = false, .hopeless_moves = 2 };
    try expect(isProblemSolved(&game.position, &no_tree, &.{}, given_up, settings));
    const once: ProblemEvidence = .{ .kind = .kill, .refuted = false, .hopeless_moves = 1 };
    try expect(!isProblemSolved(&game.position, &no_tree, &.{}, once, settings));
    // A black target captured: the life problem lost, whatever else.
    try startTestGameFromDiagram(game,
        \\// goban 7x7, white to play
        \\. . X O . . .
        \\. . O . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
        \\. . . . . . .
    );
    game.record.target = pointAt(7, 0, 2);
    replayTo(game, 0);
    _ = try playTestMove(game, 0, 1);
    try expectEqual(@as(?Stone, .white), game.position.winner);
    const lost: ProblemEvidence = .{ .kind = .live, .refuted = false, .hopeless_moves = 2 };
    try expect(!isProblemSolved(&game.position, &no_tree, &.{}, lost, settings));
}

test "a family from a later start: its ladder starts there, and its first step is a puzzle of its own" {
    // The first of the index's families derived from a later start.
    const derived: ProblemFamily = comptime found: {
        @setEvalBranchQuota(100 * (problem_families.len + 1));
        for (problem_families) |family| {
            if (family.firstStart() > 0) {
                break :found family;
            }
        }
        @compileError("goban: the index has no family from a later start");
    };
    var step_buffer: [8]PuzzleStep = undefined;
    const opens_as_twin: bool = !derived.starts[0].own;
    const steps: []const PuzzleStep = familySteps(derived, opens_as_twin, &step_buffer);
    try expectEqual(derived.firstStart(), steps[0].start_moves);
    try expect(steps.len >= 1 and steps.len <= derived.starts.len);
    // Its first step: the position after the start's moves of the correct line, the target standing.
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const base: Problem = try readProblem(derived.sgf);
    const root: SgfRoot = try readSgfRoot(derived.sgf);
    var tree: SolutionTree = undefined;
    try readSolutionTree(derived.sgf, &root, &tree);
    var line_buffer: [record_limits.max_moves]Point = undefined;
    const line: []const Point = try readSgfCorrectLine(derived.sgf, &root, &line_buffer);
    const first: Puzzle = puzzleAt(&base, &tree, line, steps[0], game);
    try expect(first.problem.setup.stones[first.problem.target] != .none);
    // The family of the same name found by name is the published one, from the first move.
    try expectEqual(@as(u8, 0), familyOf(derived.name).firstStart());
}

test "a problem's ladder: its steps alternate in kind, a twin's puzzle has its colours swapped and no book" {
    // Easy problem 1: its correct line rs rr ns, a start after rs rr - every puzzle kept.
    const family: ProblemFamily = .{
        .name = "ggg-easy-01.sgf",
        .sgf = easy_problem_families[0].sgf,
        .kind = .kill,
        .starts = &.{ .{ .moves = 0 }, .{ .moves = 2 } },
    };
    var step_buffer: [8]PuzzleStep = undefined;
    const steps: []const PuzzleStep = familySteps(family, false, &step_buffer);
    var twin_first_buffer: [8]PuzzleStep = undefined;
    try expectEqual(@as(usize, 2), steps.len);
    try expectEqual(PuzzleStep{ .start_moves = 0, .is_twin = false }, steps[0]);
    try expectEqual(PuzzleStep{ .start_moves = 2, .is_twin = true }, steps[1]);
    const twin_first: []const PuzzleStep = familySteps(family, true, &twin_first_buffer);
    try expect(twin_first[0].is_twin and !twin_first[1].is_twin);

    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const base: Problem = try readProblem(family.sgf);
    const root: SgfRoot = try readSgfRoot(family.sgf);
    var tree: SolutionTree = undefined;
    try readSolutionTree(family.sgf, &root, &tree);
    var line_buffer: [record_limits.max_moves]Point = undefined;
    const line: []const Point = try readSgfCorrectLine(family.sgf, &root, &line_buffer);
    // The full problem: as published, its whole book.
    const full: Puzzle = puzzleAt(&base, &tree, line, steps[0], game);
    try expectEqual(ProblemKind.kill, full.problem.kind);
    try expectEqual(tree.node_count, full.tree.node_count);
    // The second step: after rs and rr, the colours swapped - a life problem, the target now black, no book.
    const second: Puzzle = puzzleAt(&base, &tree, line, steps[1], game);
    try expectEqual(ProblemKind.live, second.problem.kind);
    try expectEqual(Stone.black, second.problem.setup.stones[second.problem.target]);
    try expectEqual(Stone.white, second.problem.setup.stones[line[0]]);
    try expectEqual(@as(u16, 0), second.tree.node_count);
    // The same step as the published kind: the book from rs rr on, ns its correct answer.
    const same_kind: Puzzle = puzzleAt(&base, &tree, line, .{ .start_moves = 2, .is_twin = false }, game);
    try expect(same_kind.tree.isSolvedBy(&.{line[2]}));
}

test "a problem's ladder: a start whose twin was dropped keeps its own puzzle; one with neither kept is passed" {
    // Starts after 0, 2, 4 and 6 moves: the twin after 2 dropped, nothing kept after 4.
    const family: ProblemFamily = .{
        .sgf = "",
        .starts = &.{
            .{ .moves = 0 },
            .{ .moves = 2, .twin = false },
            .{ .moves = 4, .own = false, .twin = false },
            .{ .moves = 6 },
        },
    };
    var step_buffer: [8]PuzzleStep = undefined;
    const steps: []const PuzzleStep = familySteps(family, false, &step_buffer);
    // The book's kind first; after 2 the twin would alternate but was dropped, so the book's kind again; after 4
    // nothing; after 6 the alternation goes on - the twin.
    try expectEqual(@as(usize, 3), steps.len);
    try expectEqual(PuzzleStep{ .start_moves = 0, .is_twin = false }, steps[0]);
    try expectEqual(PuzzleStep{ .start_moves = 2, .is_twin = false }, steps[1]);
    try expectEqual(PuzzleStep{ .start_moves = 6, .is_twin = true }, steps[2]);
}

test "go puzzles hero's ladder: up a step after a solution, down after giving up, the round over at the top" {
    // A ladder of three steps: solved at the last, back to the middle; at the full problem, the round over.
    try expectEqual(@as(?usize, 1), nextHeroStep(2, 3, .solved));
    try expectEqual(@as(?usize, null), nextHeroStep(0, 3, .solved));
    // Given up: one later, the last at the most - a ladder of one step gives its only step again.
    try expectEqual(@as(?usize, 1), nextHeroStep(0, 3, .given_up));
    try expectEqual(@as(?usize, 2), nextHeroStep(2, 3, .given_up));
    try expectEqual(@as(?usize, 0), nextHeroStep(0, 1, .given_up));
}

test "go puzzles hero's next round: each row's shares, and in the long run a quarter, a quarter and a half" {
    const chances: RoundChances = .{};
    // After a fight: a life puzzle in the first third, a kill puzzle in the rest - never a fight.
    try expectEqual(HeroRound.live, nextRound(.fight, chances, 0.1));
    try expectEqual(HeroRound.kill, nextRound(.fight, chances, 0.5));
    try expectEqual(HeroRound.kill, nextRound(.fight, chances, 0.9999));
    // After a life puzzle: a fight in the first third, a kill puzzle in the rest.
    try expectEqual(HeroRound.fight, nextRound(.live, chances, 0.2));
    try expectEqual(HeroRound.kill, nextRound(.live, chances, 0.4));
    // After a kill puzzle: each a third.
    try expectEqual(HeroRound.fight, nextRound(.kill, chances, 0.2));
    try expectEqual(HeroRound.live, nextRound(.kill, chances, 0.5));
    try expectEqual(HeroRound.kill, nextRound(.kill, chances, 0.9));
    // Many rounds: their shares near the chain's lasting ones.
    var generator: DefaultPrng = .init(5);
    var counts = [_]u32{ 0, 0, 0 };
    var current_round: HeroRound = .fight;
    const round_count: u32 = 30_000;
    for (0..round_count) |_| {
        current_round = nextRound(current_round, chances, generator.random().float(f32));
        counts[@backingInt(current_round)] += 1;
    }
    const lasting_shares = [_]f32{ 0.25, 0.25, 0.5 };
    for (counts, lasting_shares) |count, lasting_share| {
        const share: f32 = float(count) / float(round_count);
        try expectApproxEqAbs(lasting_share, share, 0.02);
    }
}

test "arena: the search against the book on goban's problems - is the book's first move chosen, and how highly rated" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const game: *Game = try arena.create(Game);
    const iteration_count: u32 = 50_000;
    const node_buffer: []SearchNode = try arena.alloc(SearchNode, iteration_count + 1);
    const variants = [_]struct { name: []const u8, settings: SearchSettings }{
        .{ .name = "widening", .settings = .{} },
        .{ .name = "widening and ladders", .settings = .{ .ladder_reading = true } },
    };
    for (variants) |variant| {
        const settings: SearchSettings = variant.settings;
        const level_count: usize = std.enums.values(ProblemLevel).len;
        var agreeing: [level_count]u32 = @splat(0);
        var sampled: [level_count]u32 = @splat(0);
        var book_rate_sum: [level_count]f32 = @splat(0);
        // A sample of the families, every 64th - about thirty of the index's two thousand, from every level - so
        // that the test runs in well under five minutes.
        const family_stride: usize = 64;
        for (problem_families, 0..) |family, family_index| {
            if (family_index % family_stride != 0) {
                continue;
            }
            const problem: Problem = try readProblem(family.sgf);
            const root: SgfRoot = try readSgfRoot(family.sgf);
            var first_move_buffer: [board_limits.max_points]SgfFirstMove = undefined;
            const first_moves: []const SgfFirstMove = try readSgfFirstMoves(family.sgf, &root, &first_move_buffer);
            startProblem(game, &problem, .{});
            const record: *const Record = &game.record;
            const tree: SearchTree = try continueSearch(arena, record, null, node_buffer, iteration_count, 1, settings);
            const chosen: ?Point = mostVisitedMove(&tree);
            var agrees: bool = false;
            var best_book_rate: f32 = 0;
            for (first_moves) |first_move| {
                if (!first_move.leads_to_correct) {
                    continue;
                }
                agrees = agrees or chosen == first_move.point;
                best_book_rate = @max(best_book_rate, rootChildWinRate(&tree, first_move.point));
            }
            const level_index: usize = @backingInt(family.level);
            sampled[level_index] += 1;
            agreeing[level_index] += @intFromBool(agrees);
            book_rate_sum[level_index] += best_book_rate;
        }
        for (std.enums.values(ProblemLevel)) |level| {
            const level_index: usize = @backingInt(level);
            if (sampled[level_index] == 0) {
                continue;
            }
            const mean_rate: f32 = book_rate_sum[level_index] / float(sampled[level_index]);
            const format: []const u8 = "arena: {s}, {t}: the book's move chosen in {d} of {d}; " ++
                "its win rate for black {d:.0}%\n";
            std.debug.print(format, .{
                variant.name,
                level,
                agreeing[level_index],
                sampled[level_index],
                100 * mean_rate,
            });
        }
    }
}

test "arena: playouts from dead and living positions - the book's line's end, black's to win; white first, white's" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    const game: *Game = try testing_allocator.create(Game);
    defer testing_allocator.destroy(game);
    const variants = [_]struct { name: []const u8, settings: SearchSettings }{
        .{ .name = "as now", .settings = .{} },
    };
    const level_count: usize = std.enums.values(ProblemLevel).len;
    for (variants) |variant| {
        var black_wins: [level_count]u32 = @splat(0);
        var playouts: [level_count]u32 = @splat(0);
        var white_wins_alive: [level_count]u32 = @splat(0);
        var playouts_alive: [level_count]u32 = @splat(0);
        for (problem_families) |family| {
            const problem: Problem = try readProblem(family.sgf);
            if (problem.kind != .kill) {
                continue;
            }
            const root: SgfRoot = try readSgfRoot(family.sgf);
            var line_buffer: [record_limits.max_moves]Point = undefined;
            const line: []const Point = try readSgfCorrectLine(family.sgf, &root, &line_buffer);
            var generator: DefaultPrng = .init(7);
            const level_index: usize = @backingInt(family.level);
            // The problem with white to move first: white saves the target, so white's to win.
            startProblem(game, &problem, .{});
            game.record.setup_to_play = .white;
            replayTo(game, 0);
            for (0..200) |_| {
                var scratch: Position = game.position;
                const winner: Stone = playOut(&scratch, generator.random(), variant.settings, &.{});
                white_wins_alive[level_index] += @intFromBool(winner == .white);
                playouts_alive[level_index] += 1;
            }
            startProblem(game, &problem, .{});
            for (line) |move| {
                if (game.position.winner != null) {
                    break;
                }
                _ = playMove(game, move);
            }
            if (game.position.winner != null) {
                continue;
            }
            // White to answer the line's last move: every playout from here, its result.
            for (0..200) |_| {
                var scratch: Position = game.position;
                const winner: Stone = playOut(&scratch, generator.random(), variant.settings, &.{});
                black_wins[level_index] += @intFromBool(winner == .black);
                playouts[level_index] += 1;
            }
        }
        for (std.enums.values(ProblemLevel)) |level| {
            const level_index: usize = @backingInt(level);
            if (playouts[level_index] == 0) {
                continue;
            }
            const share: f32 = float(black_wins[level_index]) / float(playouts[level_index]);
            const alive_share: f32 = float(white_wins_alive[level_index]) / float(@max(playouts_alive[level_index], 1));
            std.debug.print("arena: {s}, {t}: dead - black wins {d:.0}%; alive - white wins {d:.0}%\n", .{
                variant.name,
                level,
                100 * share,
                100 * alive_share,
            });
        }
    }
}

test "a problem's frame: its region takes in its book's moves, and a turned problem keeps its kind" {
    // Every move of every published problem's book can be played: its point is in the problem's region.
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    for (problem_families) |family| {
        const problem: Problem = try readProblem(family.sgf);
        startProblem(game, &problem, .{});
        const region: ProblemRegion = game.position.region.?;
        var book_points: PointSet.Iterator(.{}) = problem.book_points.iterator(.{});
        while (book_points.next()) |point_index| {
            try expect(region.contains(problem.setup.board_size, @intCast(point_index)));
        }
    }
    // A life problem turned: still a life problem, whose ring is the attacker's - white.
    const life: Problem = try readProblem(life_problem_sgfs[0]);
    const turned: Problem = transformedProblem(&life, .quarter_turn);
    try expectEqual(ProblemKind.live, turned.kind);
    try expectEqual(life.book_points.count(), turned.book_points.count());
}

test "the fighting move: a defender extends its group, an attacker takes its liberties - near it, not elsewhere" {
    // A white group of two by the corner with two liberties under it, black stones above and beside it: white can
    // extend along the edge, black can take a liberty.
    const text: []const u8 =
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\. . . . . . . . .
        \\X X X . . . . . .
        \\O O X . . . . . .
        \\. . . . . . . . .
    ;
    const reading: DiagramReading = readDiagram(text);
    const setup: DiagramSetup = reading.setup;
    const target: Point = pointAt(9, 7, 0);
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    const problem: Problem = .{ .setup = setup, .target = target, .kind = .kill };
    startProblem(game, &problem, .{});
    const liberties_before: usize = game.position.group_liberties[findRoot(&game.position, target)].count();
    // White to play, defending: a move beside the group that leaves it no fewer liberties.
    game.position.player_to_move = .white;
    const defence: Point = fightingMove(&game.position, null).?;
    try expect(targetNeighbourhood(&game.position).?.isSet(defence));
    var after_defence: Position = game.position;
    _ = placeStone(&after_defence, defence);
    try expect(after_defence.group_liberties[findRoot(&after_defence, target)].count() >= liberties_before);
    // Black to play, attacking: a move that takes one of its liberties.
    game.position.player_to_move = .black;
    const attack: Point = fightingMove(&game.position, null).?;
    var after_attack: Position = game.position;
    _ = placeStone(&after_attack, attack);
    try expect(after_attack.group_liberties[findRoot(&after_attack, target)].count() < liberties_before);
}

test "the fighting move in Atari Go: a capture first; otherwise out of atari, rather than a move elsewhere" {
    // White's stone in atari - black to its left, above and below - and black's own stone free: white to play.
    const text: []const u8 =
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . X . . . .
        \\. . X O . . . .
        \\. . . X . . . .
        \\. . . . . . . .
        \\. . . . . . X .
        \\. . . . . . . .
    ;
    const reading: DiagramReading = readDiagram(text);
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGameFromDiagram(game, &reading.setup);
    game.record.capture_goal = 1;
    replayTo(game, 0);
    game.position.player_to_move = .white;
    // White runs: the move out of atari, to the right of its stone, its group two liberties or more.
    const escape: Point = atariFightingMove(&game.position, null).?;
    try expectEqual(pointAt(8, 3, 4), escape);
    // Black to play: the capture, which wins.
    game.position.player_to_move = .black;
    try expectEqual(pointAt(8, 3, 4), atariFightingMove(&game.position, null).?);
}

test "go puzzles hero's rating with a simulated player: first tries solved 60% to 80% of the time, a fall in rounds" {
    const settings: RatingSettings = .{};
    var generator: DefaultPrng = .init(11);
    const random: Random = generator.random();
    const family_count: usize = 1000;
    // A player solves a problem at a place in the order with a chance falling as the place passes the player's skill:
    // a half at the skill, nine in ten a fifth of the order below it.
    const steepness: f32 = 12;
    for ([_]f32{ 0.3, 0.6, 0.9 }) |skill| {
        var rating: f32 = 0;
        var failure_streak: u8 = 0;
        var solved_count: u32 = 0;
        var counted_rounds: u32 = 0;
        for (0..600) |round_index| {
            const window: RatingWindow = ratingWindow(rating, family_count, settings);
            const family_index: usize = window.first + random.uintLessThan(usize, window.end - window.first);
            const place: f32 = float(family_index) / float(family_count - 1);
            const chance: f32 = 1 / (1 + @exp(steepness * (place - skill)));
            const solved_first_try: bool = random.float(f32) < chance;
            failure_streak = if (solved_first_try) 0 else failure_streak +| 1;
            rating = ratedPlace(rating, solved_first_try, failure_streak, settings);
            // The first 200 rounds the climb from the easiest; the rest at rest.
            if (round_index >= 200) {
                counted_rounds += 1;
                solved_count += @intFromBool(solved_first_try);
            }
        }
        const solved_share: f32 = float(solved_count) / float(counted_rounds);
        try expect(solved_share >= 0.6 and solved_share <= 0.8);
    }
    // A strong player gone weak, failing every first try from a rating of 0.9: under a half within three rounds.
    var rating: f32 = 0.9;
    var failure_streak: u8 = 0;
    var rounds: u32 = 0;
    while (rating >= 0.5) : (rounds += 1) {
        failure_streak +|= 1;
        rating = ratedPlace(rating, false, failure_streak, settings);
    }
    try expect(rounds <= 3);
}

test "go puzzles hero's rating: its window a fifth of the problems, 20 at least, shifted at the ends; its steps" {
    const settings: RatingSettings = .{};
    // 60 families: a window of 20, the least - the easiest at 0, the hardest at 1, the middle ones at a half.
    try expectEqual(RatingWindow{ .first = 0, .end = 20 }, ratingWindow(0, 60, settings));
    try expectEqual(RatingWindow{ .first = 40, .end = 60 }, ratingWindow(1, 60, settings));
    const middle: RatingWindow = ratingWindow(0.5, 60, settings);
    try expectEqual(@as(usize, 20), middle.end - middle.first);
    try expect(middle.first >= 19 and middle.first <= 21);
    // 1,316 families: a fifth, 263.
    const large: RatingWindow = ratingWindow(0, 1316, settings);
    try expectEqual(@as(usize, 263), large.end - large.first);
    // Up a step after a first try solved; down one after a first try failed, two after the second failure in a row,
    // three after the third and no more; within 0 and 1.
    try expectApproxEqAbs(@as(f32, 0.53), ratedPlace(0.5, true, 0, settings), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.43), ratedPlace(0.5, false, 1, settings), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.36), ratedPlace(0.5, false, 2, settings), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.29), ratedPlace(0.5, false, 3, settings), 1e-6);
    try expectApproxEqAbs(@as(f32, 0.29), ratedPlace(0.5, false, 7, settings), 1e-6);
    try expectEqual(@as(f32, 0), ratedPlace(0.02, false, 1, settings));
    try expectEqual(@as(f32, 1), ratedPlace(0.99, true, 0, settings));
    // At 70% first tries solved, the rating's moves even out.
    const drift: f32 = 0.7 * settings.step_up - 0.3 * settings.step_down;
    try expectApproxEqAbs(@as(f32, 0), drift, 1e-6);
    // The progress, saved and read back.
    const progress: HeroProgress = .{ .wins = 123, .rating = 0.4567, .ladder_position = 9 };
    const read_back: HeroProgress = HeroProgress.fromBytes(&progress.toBytes()).?;
    try expectEqual(@as(u32, 123), read_back.wins);
    try expectEqual(@as(u8, 9), read_back.ladder_position);
    try expectApproxEqAbs(@as(f32, 0.4567), read_back.rating, 1e-4);
    try expectEqual(@as(?HeroProgress, null), HeroProgress.fromBytes(&[_]u8{ 0, 0, 0, 0 }));
    // The password's flag kept; a version 1 value read, the password not typed.
    const unlocked: HeroProgress = .{ .wins = 7, .unlocked = true };
    try expect(HeroProgress.fromBytes(&unlocked.toBytes()).?.unlocked);
    const version_1 = [_]u8{ 1, 3, 0, 0, 5, 0, 0, 0 };
    const read_version_1: HeroProgress = HeroProgress.fromBytes(&version_1).?;
    try expectEqual(@as(u32, 5), read_version_1.wins);
    try expectEqual(@as(u8, 3), read_version_1.ladder_position);
    try expect(!read_version_1.unlocked);
}

test "arena: the search's speed - an iteration, a position's copy and a playout's move, on 8 x 8 and on a problem" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const game: *Game = try arena.create(Game);
    const io = std.testing.io;
    const iteration_count: u32 = 40_000;
    const playout_count: u32 = 10_000;
    const node_buffer: []SearchNode = try arena.alloc(SearchNode, iteration_count + 1);
    for ([_][]const u8{ "8 x 8 Atari Go", "a 19 x 19 problem" }, 0..) |case_name, case_index| {
        if (case_index == 0) {
            const outposts: ScatteredStones = .{ .black_count = 2, .white_count = 2 };
            startGame(game, .{ .board_size = 8, .capture_goal = 1, .scattered = outposts });
        } else {
            const problem: Problem = try readProblem(easy_problem_families[0].sgf);
            startProblem(game, &problem, .{});
        }
        // A search's iteration.
        var started: Io.Timestamp = .now(io, .awake);
        _ = try continueSearch(arena, &game.record, null, node_buffer, iteration_count, 1, .{});
        const search_ns: f64 = float64(started.durationTo(.now(io, .awake)).nanoseconds);
        // The position's copy each iteration makes.
        var scratch: Position = undefined;
        started = .now(io, .awake);
        for (0..iteration_count) |_| {
            copyPosition(&scratch, &game.position);
            std.mem.doNotOptimizeAway(&scratch);
        }
        const copy_ns: f64 = float64(started.durationTo(.now(io, .awake)).nanoseconds);
        // Playouts from the start, their moves counted.
        var generator: DefaultPrng = .init(1);
        var playout_moves: u64 = 0;
        started = .now(io, .awake);
        for (0..playout_count) |_| {
            copyPosition(&scratch, &game.position);
            var moves: u32 = 0;
            while (scratch.winner == null and moves < 200) : (moves += 1) {
                const move: Point = playoutMove(&scratch, generator.random(), .{}, &.{}) orelse break;
                _ = placeStone(&scratch, move);
            }
            playout_moves += moves;
        }
        const playout_ns: f64 = float64(started.durationTo(.now(io, .awake)).nanoseconds);
        const iteration_us: f64 = search_ns / 1000 / float64(iteration_count);
        const copy_us: f64 = copy_ns / 1000 / float64(iteration_count);
        const move_us: f64 = playout_ns / 1000 / float64(playout_moves);
        const moves_per_playout: f64 = float64(playout_moves) / float64(playout_count);
        std.debug.print("arena: {s}: an iteration {d:.1} us, a copy {d:.2} us, a playout's move {d:.2} us ({d:.0} " ++
            "moves a playout)\n", .{ case_name, iteration_us, copy_us, move_us, moves_per_playout });
    }
}

test "arena: how many of a search's nodes are transpositions - a position the tree reaches by another path too" {
    const test_options = @import("goban_test_options");
    if (!test_options.run_arena) {
        return error.SkipZigTest;
    }
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const game: *Game = try arena.create(Game);
    const iteration_count: u32 = 50_000;
    const node_buffer: []SearchNode = try arena.alloc(SearchNode, iteration_count + 1);
    const cases = [_][]const u8{ "8 x 8 Atari Go", "easy problem 1", "intermediate problem 1", "hard problem 1" };
    for (cases, 0..) |case_name, case_index| {
        const problem_names = [_][]const u8{ "", "ggg-easy-01.sgf", "ggg-intermediate-01.sgf", "ggg-hard-01.sgf" };
        if (case_index == 0) {
            const outposts: ScatteredStones = .{ .black_count = 2, .white_count = 2 };
            startGame(game, .{ .board_size = 8, .capture_goal = 1, .scattered = outposts });
        } else {
            const sgf: []const u8 = familyOf(problem_names[case_index]).sgf;
            const problem: Problem = try readProblem(sgf);
            startProblem(game, &problem, .{});
        }
        const record: *const Record = &game.record;
        const tree: SearchTree = try continueSearch(arena, record, null, node_buffer, iteration_count, 1, .{});
        // Every node's position, by a depth-first walk from the root: its fingerprint counted.
        var seen: std.AutoHashMap(u64, u32) = .init(arena);
        const Frame = struct { node: u32, position: Position };
        var stack: ArrayList(Frame) = .empty;
        try stack.append(arena, .{ .node = 0, .position = game.position });
        var node_count: u32 = 0;
        var visits_total: u64 = 0;
        var visits_in_repeats: u64 = 0;
        var repeated_nodes: u32 = 0;
        while (stack.pop()) |frame| {
            const node: SearchNode = tree.nodes[frame.node];
            node_count += 1;
            visits_total += node.visits;
            const fingerprint: u64 = positionFingerprint(&frame.position);
            const entry: std.AutoHashMap(u64, u32).GetOrPutResult = try seen.getOrPut(fingerprint);
            if (entry.found_existing) {
                repeated_nodes += 1;
                visits_in_repeats += node.visits;
                entry.value_ptr.* += 1;
            } else {
                entry.value_ptr.* = 1;
            }
            var child_index: u32 = node.first_child;
            while (child_index != SearchNode.none) : (child_index = tree.nodes[child_index].next_sibling) {
                var child_position: Position = frame.position;
                _ = placeStone(&child_position, tree.nodes[child_index].move);
                try stack.append(arena, .{ .node = child_index, .position = child_position });
            }
        }
        const repeated_share: f64 = float64(repeated_nodes) / float64(node_count);
        const repeated_visit_share: f64 = float64(visits_in_repeats) / float64(@max(visits_total, 1));
        std.debug.print("arena: {s}: {d} nodes, {d} positions; {d:.0}% of the nodes repeat a position, with " ++
            "{d:.0}% of the visits\n", .{
            case_name,
            node_count,
            seen.count(),
            100 * repeated_share,
            100 * repeated_visit_share,
        });
    }
}

test "a ladder: an escape along the edge the ladder catches, and one with room to run" {
    var pool: [24]Position = undefined;
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    // White's stone at (1, 3) in atari, its escape to (0, 3) leaving two liberties on the edge: black's atari on
    // either side leaves it one.
    const caught_text: []const u8 =
        \\. . . . . . . .
        \\. . X O X . . .
        \\. . . X . . . .
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . . . . . .
    ;
    startGameFromDiagram(game, &readDiagram(caught_text).setup);
    game.position.player_to_move = .white;
    const white_stone: Point = pointAt(8, 1, 3);
    const edge_escape: Point = pointAt(8, 0, 3);
    try expect(escapeRunsIntoLadder(&game.position, white_stone, edge_escape, .{}, &pool));
    // One line further from the edge: the escape to (1, 3) leaves three liberties, and no ladder follows.
    const free_text: []const u8 =
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . X O X . . .
        \\. . . X . . . .
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . . . . . .
    ;
    startGameFromDiagram(game, &readDiagram(free_text).setup);
    game.position.player_to_move = .white;
    const free_stone: Point = pointAt(8, 2, 3);
    const open_escape: Point = pointAt(8, 1, 3);
    try expect(!escapeRunsIntoLadder(&game.position, free_stone, open_escape, .{}, &pool));
    // With no pool, nothing is read.
    try expect(!escapeRunsIntoLadder(&game.position, free_stone, open_escape, .{}, &.{}));
}

test "a problem's outside: the colour whose stones face the frame's open sides - white in a life problem" {
    // Easy problem 1, a kill problem: black's wall faces the open sides.
    const kill: Problem = try readProblem(familyNamed("ggg-easy-01.sgf").sgf);
    try expectEqual(Stone.black, outsideOwner(&kill.setup, .white));
    // Easy problem 4, a life problem: white's wall faces them.
    const life: Problem = try readProblem(familyNamed("ggg-easy-04.sgf").sgf);
    try expectEqual(Stone.white, outsideOwner(&life.setup, .black));
}

test "atariFightingMove presses where the fight is: an atari on a pair of two liberties; in quiet, next to the stone" {
    // The position before a fight's white move that went to the top edge: black's pair in the middle has two
    // liberties, at (3,1) and (4,2) - white puts it in atari.
    const fight_text: []const u8 =
        \\. . . . . . . .
        \\. . . . O . . .
        \\. . O O . . . .
        \\. . X X O O . .
        \\. X . O X X X .
        \\. . . O X . . .
        \\. . . . . O . .
        \\. . . . . . . .
    ;
    const fight_reading: DiagramReading = readDiagram(fight_text);
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    startGameFromDiagram(game, &fight_reading.setup);
    game.record.capture_goal = 1;
    game.record.setup_to_play = .white;
    replayTo(game, 0);
    const pressing: Point = atariFightingMove(&game.position, null).?;
    const ataris_from_the_left: bool = pressing == pointAt(8, 3, 1);
    const ataris_from_below: bool = pressing == pointAt(8, 4, 2);
    try expect(ataris_from_the_left or ataris_from_below);
    // A quiet position: no group short of liberties. White plays next to black's stone - the fight - not at the
    // board's first point.
    const quiet_text: []const u8 =
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . O . . . .
        \\. . . . X . . .
        \\. . . . . . . .
        \\. . . . . . . .
        \\. . . . . . . .
    ;
    const quiet_reading: DiagramReading = readDiagram(quiet_text);
    startGameFromDiagram(game, &quiet_reading.setup);
    game.record.capture_goal = 1;
    game.record.setup_to_play = .white;
    replayTo(game, 0);
    const approach: Point = atariFightingMove(&game.position, null).?;
    try expectEqual(@as(u32, 1), lineDistance(8, approach, pointAt(8, 4, 4)));
}

test "targetHasCompany: a target alone in its colour needs no mark; one beside another group of its colour does" {
    const game: *Game = try createTestGame();
    defer testing_allocator.destroy(game);
    // A black chain of two along the top edge, a liberty to its right, the only black stones: the target is plain.
    const alone: Problem = try readProblem("(;SZ[9]AB[aa][ba]AW[ab][bb]SQ[aa])");
    startProblem(game, &alone, .{});
    try expect(!targetHasCompany(&game.position));
    // Another black stone apart from it: which group is meant is not plain.
    const with_company: Problem = try readProblem("(;SZ[9]AB[aa][ba][dd]AW[ab][bb]SQ[aa])");
    startProblem(game, &with_company, .{});
    try expect(targetHasCompany(&game.position));
}

test "go puzzles hero's level: a level every ten wins from 1, the wins since it began filling the row" {
    try expectEqual(HeroLevel{ .level = 1, .filled = 0 }, heroLevel(0, 10));
    try expectEqual(HeroLevel{ .level = 1, .filled = 9 }, heroLevel(9, 10));
    try expectEqual(HeroLevel{ .level = 2, .filled = 0 }, heroLevel(10, 10));
    try expectEqual(HeroLevel{ .level = 3, .filled = 3 }, heroLevel(23, 10));
    // The row: ten places between the buttons, at their height, on a narrow phone and a wide window alike.
    const controls: ControlsStyle = .{ .progress_places = 10 };
    for ([_]Vec2{ .{ 400, 800 }, .{ 1600, 900 } }) |window_px| {
        const font_size_px: f32 = 20;
        const row: ProgressRow = heroProgressRow(window_px[0], window_px[1], font_size_px, controls);
        try expectEqual(@as(u8, 10), row.places);
        const gap_px: f32 = controls.edge_gap_fonts * font_size_px;
        const button_width_px: f32 = controls.undo_button_size_fonts[0] * font_size_px;
        const last_centre_px: f32 = row.first_centre_px[0] + 9 * row.spacing_px;
        const left_edge_px: f32 = row.first_centre_px[0] - row.stone_px / 2;
        const right_edge_px: f32 = last_centre_px + row.stone_px / 2;
        try expect(left_edge_px >= gap_px + 1.4 * button_width_px + gap_px - 0.01);
        try expect(right_edge_px <= window_px[0] - gap_px - button_width_px - gap_px + 0.01);
        try expect(row.spacing_px <= controls.progress_spacing_fonts * font_size_px + 0.01);
    }
}

test "go puzzles hero's reward: half a second's wait, the picture in, held two seconds, out, then over" {
    const settings: RewardSettings = .{};
    try expectEqual(RewardPhase.waiting, rewardPhase(0, settings));
    try expectEqual(RewardPhase.waiting, rewardPhase(0.49, settings));
    try expectEqual(RewardPhase.showing, rewardPhase(0.5, settings));
    try expectEqual(RewardPhase.showing, rewardPhase(3.49, settings));
    try expectEqual(RewardPhase.over, rewardPhase(3.5, settings));
    // Above the window at the start, sliding into the centre - more than half way after a third of the way in -
    // held there two seconds, then gathering speed down and out.
    try expectApproxEqAbs(@as(f32, -1), rewardOffset(0, settings), 1e-6);
    try expect(rewardOffset(0.5 / 3.0, settings) > -0.5);
    try expectEqual(@as(f32, 0), rewardOffset(0.5, settings));
    try expectEqual(@as(f32, 0), rewardOffset(2.49, settings));
    try expect(rewardOffset(2.5 + 0.5 / 3.0, settings) < 0.5);
    try expectApproxEqAbs(@as(f32, 1), rewardOffset(3, settings), 1e-6);
    // The backdrop darkens as the picture comes, and clears as it goes.
    try expectApproxEqAbs(@as(f32, 0.5), rewardBackdropAlpha(0.25, settings), 1e-6);
    try expectEqual(@as(f32, 1), rewardBackdropAlpha(2, settings));
    try expectApproxEqAbs(@as(f32, 0), rewardBackdropAlpha(3, settings), 1e-6);
}

test "scattered stones on the second and third lines, clear of the square's front: go puzzles hero's 10 x 10" {
    const scattered: ScatteredStones = .{
        .black_count = 2,
        .nearest_line = 1,
        .farthest_line = 2,
        .keeps_square_front_clear = true,
    };
    var candidate_buffer: [board_limits.max_points]Point = undefined;
    const candidates: ArrayList(Point) = scatterCandidates(10, scattered, &candidate_buffer);
    var is_candidate: PointSet = .empty;
    for (candidates.items) |point| {
        is_candidate.set(point);
    }
    // The second line and the third, away from the square.
    try expect(is_candidate.isSet(pointAt(10, 1, 1)));
    try expect(is_candidate.isSet(pointAt(10, 1, 4)));
    try expect(is_candidate.isSet(pointAt(10, 2, 3)));
    try expect(is_candidate.isSet(pointAt(10, 7, 6)));
    // Never the edge, nor the fourth line.
    try expect(!is_candidate.isSet(pointAt(10, 0, 4)));
    try expect(!is_candidate.isSet(pointAt(10, 3, 3)));
    // Not on the third line level with the square: its front, on all four sides.
    const fronts = [_][2]u8{ .{ 2, 4 }, .{ 2, 5 }, .{ 7, 4 }, .{ 7, 5 }, .{ 4, 2 }, .{ 5, 2 }, .{ 4, 7 }, .{ 5, 7 } };
    for (fronts) |front| {
        try expect(!is_candidate.isSet(pointAt(10, front[0], front[1])));
    }
    try expect(scatteredStonesFit(10, scattered));
}

test "go puzzles hero moves on from a step failed five times in a row" {
    const flow: HeroFlowSettings = .{};
    // A ladder of one step: failed, it comes back - four times; the fifth failure moves on to the next round.
    var failures: u8 = 0;
    for (0..4) |_| {
        const again: HeroStepMove = heroStepAfter(0, 1, .given_up, failures, flow);
        try expectEqual(@as(?usize, 0), again.next_step);
        failures = again.step_failures;
    }
    try expectEqual(@as(u8, 4), failures);
    const moved_on: HeroStepMove = heroStepAfter(0, 1, .given_up, failures, flow);
    try expectEqual(@as(?usize, null), moved_on.next_step);
    try expectEqual(@as(u8, 0), moved_on.step_failures);
    // A failure that moves down the ladder starts the next step's count afresh.
    const down: HeroStepMove = heroStepAfter(0, 3, .given_up, 3, flow);
    try expectEqual(@as(?usize, 1), down.next_step);
    try expectEqual(@as(u8, 0), down.step_failures);
}
