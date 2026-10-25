//! go puzzles hero - rounds against the computer, in turn: a fight, Atari Go on 10 x 10 with outposts on a ladder that
//! keeps it balanced; a life puzzle; a kill puzzle. A puzzle is a ladder of starts along its book's correct line,
//! the kinds alternating - each later start two moves on, the move given to the other side at every other step, so a
//! kill problem's next step is a life problem and the other way round. Losing a puzzle gives its next, later start;
//! solving one goes back a start, towards the full problem, whose solving ends the round. There is no undo, and no
//! giving up: a fight is played to its end, and a problem failed three times offers a hint - the move to play, shown
//! for half a second.
//!
//! It is goban, made another way (`goban.appFor`): the rules, the problems and their ladders, the computer, the board
//! and its sounds are all goban's. Only the choice of rounds and of the buttons are this file's.
const goban = @import("goban");

/// goban's panic handler, which reports through the engine.
pub const panic = goban.panic;

/// What makes this app of goban's: its fight, its problems, and the hero's buttons.
/// The pictures shown as a reward at each new level (`goban.RewardSettings`): photographs of cats from Wikimedia
/// Commons' category "Humorous cats", each scaled to 600 pixels on its longer side (cats/SOURCE.md names them).
const reward_images = [_][]const u8{
    @embedFile("cats/cat-01.jpg"),
    @embedFile("cats/cat-02.jpg"),
    @embedFile("cats/cat-03.jpg"),
    @embedFile("cats/cat-04.jpg"),
    @embedFile("cats/cat-05.jpg"),
    @embedFile("cats/cat-06.jpg"),
    @embedFile("cats/cat-07.jpg"),
    @embedFile("cats/cat-08.jpg"),
    @embedFile("cats/cat-09.jpg"),
    @embedFile("cats/cat-10.jpg"),
    @embedFile("cats/cat-11.jpg"),
    @embedFile("cats/cat-12.jpg"),
    @embedFile("cats/cat-13.jpg"),
    @embedFile("cats/cat-14.jpg"),
    @embedFile("cats/cat-15.jpg"),
    @embedFile("cats/cat-16.jpg"),
    @embedFile("cats/cat-17.jpg"),
    @embedFile("cats/cat-18.jpg"),
    @embedFile("cats/cat-19.jpg"),
    @embedFile("cats/cat-20.jpg"),
    @embedFile("cats/cat-21.jpg"),
    @embedFile("cats/cat-22.jpg"),
    @embedFile("cats/cat-23.jpg"),
    @embedFile("cats/cat-24.jpg"),
    @embedFile("cats/cat-25.jpg"),
    @embedFile("cats/cat-26.jpg"),
    @embedFile("cats/cat-27.jpg"),
    @embedFile("cats/cat-28.jpg"),
    @embedFile("cats/cat-29.jpg"),
    @embedFile("cats/cat-30.jpg"),
    @embedFile("cats/cat-31.jpg"),
    @embedFile("cats/cat-32.jpg"),
    @embedFile("cats/cat-33.jpg"),
    @embedFile("cats/cat-34.jpg"),
    @embedFile("cats/cat-35.jpg"),
    @embedFile("cats/cat-36.jpg"),
    @embedFile("cats/cat-37.jpg"),
    @embedFile("cats/cat-38.jpg"),
    @embedFile("cats/cat-39.jpg"),
    @embedFile("cats/cat-40.jpg"),
    @embedFile("cats/cat-41.jpg"),
    @embedFile("cats/cat-42.jpg"),
    @embedFile("cats/cat-43.jpg"),
    @embedFile("cats/cat-44.jpg"),
    @embedFile("cats/cat-45.jpg"),
    @embedFile("cats/cat-46.jpg"),
    @embedFile("cats/cat-47.jpg"),
    @embedFile("cats/cat-48.jpg"),
    @embedFile("cats/cat-49.jpg"),
    @embedFile("cats/cat-50.jpg"),
    @embedFile("cats/cat-51.jpg"),
    @embedFile("cats/cat-52.jpg"),
    @embedFile("cats/cat-53.jpg"),
    @embedFile("cats/cat-54.jpg"),
    @embedFile("cats/cat-55.jpg"),
    @embedFile("cats/cat-56.jpg"),
    @embedFile("cats/cat-57.jpg"),
    @embedFile("cats/cat-58.jpg"),
    @embedFile("cats/cat-59.jpg"),
    @embedFile("cats/cat-60.jpg"),
    @embedFile("cats/cat-61.jpg"),
    @embedFile("cats/cat-62.jpg"),
    @embedFile("cats/cat-63.jpg"),
    @embedFile("cats/cat-64.jpg"),
    @embedFile("cats/cat-65.jpg"),
    @embedFile("cats/cat-66.jpg"),
    @embedFile("cats/cat-67.jpg"),
    @embedFile("cats/cat-68.jpg"),
    @embedFile("cats/cat-69.jpg"),
    @embedFile("cats/cat-70.jpg"),
    @embedFile("cats/cat-71.jpg"),
    @embedFile("cats/cat-72.jpg"),
    @embedFile("cats/cat-73.jpg"),
    @embedFile("cats/cat-74.jpg"),
    @embedFile("cats/cat-75.jpg"),
    @embedFile("cats/cat-76.jpg"),
    @embedFile("cats/cat-77.jpg"),
    @embedFile("cats/cat-78.jpg"),
    @embedFile("cats/cat-79.jpg"),
    @embedFile("cats/cat-80.jpg"),
    @embedFile("cats/cat-81.jpg"),
    @embedFile("cats/cat-82.jpg"),
    @embedFile("cats/cat-83.jpg"),
    @embedFile("cats/cat-84.jpg"),
    @embedFile("cats/cat-85.jpg"),
};

const variant: goban.AppVariant = .{
    .title = "zimr - go puzzles hero",
    .interface = .hero_buttons,
    .hero = true,
    .problem_families = &goban.problem_families,
    // The group to save or to kill is plain from the position: no mark on it.
    .marks_target = false,
    // A test of asking for support: after two puzzles solved, a window with a link and a password box.
    // .paywall = .{},
    // A picture at each new level, with cheering and clapping.
    .reward_images = &reward_images,
    .reward_sound = @embedFile("cheering_and_clapping.ogg"),
    .fixed_game = .{
        // 10 x 10, the outposts on the second and third lines, never in front of the starting square.
        .settings = .{
            .board_size = 10,
            .capture_goal = 1,
            .scattered = .{ .black_count = 2, .nearest_line = 1, .farthest_line = 2, .keeps_square_front_clear = true },
        },
        .players = .{ .kind = .against_computer, .person_stone = .black },
    },
    .outpost_ladder = .{ .person_start = 2 },
    // Long enough to see the fight's last capture.
    .restart_after_win_seconds = 1.5,
};

/// The program.
pub const app = goban.appFor(variant);
