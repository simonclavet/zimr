//! goban outposts - Atari Go on an 8 x 8 board against the computer, from a start new every game: the four stones of
//! Atari Go's square, and outposts on the second line, scattered at random. The person plays black and the computer
//! white; the first capture wins, and a won game starts again by itself. The games climb a ladder
//! (`goban.OutpostLadder`): two outposts the person's to begin with; each rung played twice, the person moving first
//! and then second; a win one game up, a loss one down - so a rung is climbed by winning it moving second - and the
//! rungs going up in threes, the computer given an outpost, then another, then one of the person's taken, until the
//! person has none. There is no menu, no button and no window: the screen is the board.
//!
//! It is goban, made another way (`goban.appFor`): the rules, the computer, the board, the stones and their sounds are
//! all goban's, imported from `examples/goban/goban.zig`, so the two examples share every line of the game. Only the
//! choice of game and the want of an interface are this file's.
const goban = @import("goban");

/// goban's panic handler, which reports through the engine.
pub const panic = goban.panic;

/// What makes this app of goban's: one game, played again and again, and nothing on the screen but the board.
const variant: goban.AppVariant = .{
    .title = "zimr - goban outposts",
    .fixed_game = .{
        .settings = .{ .board_size = 8, .capture_goal = 1, .scattered = .{ .black_count = 2 } },
        .players = .{ .kind = .against_computer, .person_stone = .black },
    },
    .interface = .none,
    // Long enough to see the capture: the captured stone's flight to its column, and its sound.
    .restart_after_win_seconds = 1.5,
    .outpost_ladder = .{ .person_start = 2 },
};

/// The program.
pub const app = goban.appFor(variant);
