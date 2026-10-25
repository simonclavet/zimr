//! goban problems - go problems against the computer, kill and life in turn: black to play and capture one marked
//! white stone, the computer defending, or save one marked black stone, the computer attacking. Each problem is shown
//! in the part of the board it is played in, drawn in a symmetry of the board chosen at random. Undo takes back a
//! move; once the problem is solved - by the book's line, the target's capture, or its group's life - "Solved" shows,
//! and Next goes on to the next problem. There is no losing: a player who sees it will not come undoes and tries again.
//!
//! It is goban, made another way (`goban.appFor`): the rules, the problems (`goban.problem_sgfs`, made from
//! published ones by goban_problems_tool.zig), the computer, the board and its sounds are all goban's. Only the choice
//! of problems and of the two buttons are this file's.
const goban = @import("goban");

/// goban's panic handler, which reports through the engine.
pub const panic = goban.panic;

/// What makes this app of goban's: its problems, one after another, and their two buttons.
const variant: goban.AppVariant = .{
    .title = "zimr - goban problems",
    .interface = .problem_buttons,
    .problems = &goban.alternating_problem_sgfs,
};

/// The program.
pub const app = goban.appFor(variant);
