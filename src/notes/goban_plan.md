# goban - porting `goforest` (C++/raylib/imgui) to a zimr example

**Status: IMPLEMENTING (Oct 18) - S1-S12, E1 and E2 done, S13 (the manifest, gallery, launcher and gates) next; the opponent (8.8, S14-S17) planned, D9-D13 decided.** Decisions D1-D8 are decided and Simon agreed with the whole
final list (10.1). `examples/goban/goban.zig` holds the header and sections 1-4 (points, the forest, the rules, the record); not yet in
build.zig (S7 adds the row), so nothing builds it but the probes in the journal.

**The goal, in Simon's words:** optimise for understanding - perfect pedagogical code, lots of intermediate locals,
good variable names, and debugging capabilities.

Source: `C:/dev/tests202601/goforest/` - `src/main.cpp` (1578 lines), `src/utils.h` (548), `src/math_utils.h` (837),
`data/` (three textures), `CLAUDE.md` (the project's own notes and style), `CMakeLists.txt` (raylib 5.5, imgui master,
rlImGui main, C++20, MSVC `/W4 /WX`). Target: a new example, `examples/goban/`. **In the tree since Oct 18**, byte for
byte: `examples/goban/goforest/` (the sources, `CMakeLists.txt`, the notes as `goforest_notes.md`, a README) and the
textures beside it - every `main.cpp:NNN` in this plan is a line of `examples/goban/goforest/main.cpp`.

(An earlier draft of this file planned a port of `gogus`, the first French version of the same program. It is
superseded; appendix A keeps what that study found, because goforest is the story of fixing it.)

---

## 1. The source, studied

### 1.1 What it is

A Go board for two players on one screen, written step by step as a recreational project with Simon's kid (goforest's
`CLAUDE.md`: "Originally written in French by the user's kid as a programming exercise, then rewritten in English with
proper Go rules", collaboration mode "Tutorial"). The engine tracks groups with a **disjoint-set forest** (DSU) - hence
"goforest" - so a move costs a few set operations instead of a flood fill.

Features: board sizes 3-19 (presets 9 / 13 / 19); capture, suicide prevention and simple ko; **Atari Go** (first to
capture 1, 3 or 5 stones wins, starting from a 2 x 2 cross); undo / redo by replaying the move list (also on the
mouse's side button); a main menu, a pause menu (Escape) and a victory window, in Dear ImGui at 2x scale; a ghost stone
that follows the mouse on a spring, and a press - drag - release way of placing; stones that fly into two capture
columns beside the board, the columns compressing like stacked coins as captures grow; star points; textured wood and
stones; debug overlays toggled with H (group roots, liberties, atari groups, doomed stones) and a debug panel.

### 1.2 Files

| file | lines | what main.cpp uses from it |
|---|---|---|
| `main.cpp` | 1578 | everything below |
| `math_utils.h` | 837 | `Max`, `MinInt`, `MaxInt`, `Saturate`, `SmootherStep`, the double spring damper (scalar and `Vector2`). The rest (quaternions, frustum, Rot6d, cubic interpolation) is shared Flomo boilerplate, unused here. |
| `utils.h` | 548 | `assert` (through `<cassert>`). The rest (command-line and JSON parsing, `Array2D`, random numbers, sides) is shared boilerplate, unused here. |
| `data/b.png` | 300 x 300 RGBA, 33 KB | the black stone: a shaded sphere with a highlight |
| `data/w_1.png` | 250 x 250 RGBA, 40 KB | the white stone: a clam-shell stone with grain |
| `data/wood.png` | 901 x 796 RGBA, 1.25 MB | teak, drawn to cover the whole window |

### 1.3 The engine (main.cpp 16-575, 897-934)

| lines | piece | what it does |
|---|---|---|
| 16-31 | types, globals | `Stone` = `char` (0 none, 1 black, 2 white); `BoardIndex` = `int`, `-1` invalid. **Mutable globals**: `boardSize`, `totalCells`, and the layout (`boardOffsetX/Y`, `boardPixelSize`, `spacing`). |
| 33-102 | index helpers | `OtherStoneColor`; `Index1D(row, col) = row * boardSize + col`, `RowFrom1D`, `ColFrom1D`, `IsValidRowCol`; `GetBoardIndexFromScreenPos` (snaps to the nearest intersection, and - unlike gogus - refuses negative offsets before the integer division); `GetScreenPosFromBoardIndex`; `GetNeighbors(id, result[4])` returns 0-4 neighbours in the order up, down, left, right. |
| 105-191 | **dead code** | `FindGroupAndLiberties` (recursive flood fill) and `CaptureStones`, the engine before the DSU. Nothing calls `CaptureStones`, and `FindGroupAndLiberties` is called only by itself and by `CaptureStones`. |
| 194-231 | `FindGroupRootAndCompressPath` | recursive find with path compression; returns -1 for an empty point. |
| 233-259 | `MergeGroups(A, B)` | `groupRoot[B] = A`, then moves B's liberties and stones into A's sets. Always called with A = the stone just placed, so **the newest stone becomes the root** of every group it joins. |
| 261-306 | `KillGroup` | removes every stone of a dead group, gives each emptied point back as a liberty to the killer's groups next to it, accumulates the count. |
| 309-345 | `GameState` | `board`; the forest `groupRoot` (a stone's **parent**, which is its root only once compressed - the name says more than the array holds); `groupLiberties` (`unordered_set`) and `groupStones` (`vector`), meaningful at roots; `koForbidden`; `currentPlayer`; `lastPlaced`; capture counts; `winner`; `lastCapturedPositions` (for the animations); `moveHistory` + `historyPosition`. |
| 389-427 | `InitGameState`, `ResetGameState` | allocate (and set the global `boardSize`), or clear. |
| 432-527 | `PlayMove` | assumes a legal move. In order: place the stone as its own group; its empty neighbours become its liberties and every neighbouring group loses this point; merge with friendly neighbours; capture enemy neighbours left with no liberty; set the ko point; add to the mover's capture count; swap the turn. |
| 531-574 | `ReplayMoves`, `UndoMove`, `RedoMove` | undo = reset and replay the first n moves; the history survives the reset by being copied out and back. |
| 897-934 | `IsMoveSuicide` | not suicide if any neighbour is empty, or a friendly group with 2+ liberties, or an enemy group with exactly 1 liberty (it gets captured); suicide otherwise. Correct, and explained in its comment. |

### 1.4 The application (main.cpp 576-1570)

| lines | piece | what it does |
|---|---|---|
| 576-593 | `DrawBackgroundTexture` | wood scaled to cover the window, aspect kept, centred. |
| 595-649 | `UpdateBoardLayout` | every frame: `spacing = max(minDim / (boardSize + 3), 1)` (integers, so lines land on whole pixels), the board centred; the capture columns one stone radius + a gap + a small-stone radius outside the board; the columns' vertical spacing from the larger capture count, from "touching" down to 0.6 radius when they would overflow the board's height. |
| 651-861 | `DrawBoardAndStones` | grid (1 px black); star points (offset 2 on boards up to 9, else 3; centre on odd sizes; side points from 13 up); **doomed stones** (hovering an empty point: rings on every enemy group it would capture, pulsing); **atari groups** (a red ring on every stone of a 1-liberty group); stones (textures at 1.1 x spacing); last-move ring; the two capture columns (in Atari Go, empty rings show the goal). |
| 863-895 | GLFW hook | a window-size callback that redraws during Windows' modal resize loop, chained after raylib's own. |
| 936-1007 | `GoGameDSU` setup | window 1000 x 1000 resizable; imgui at 2x; Escape no longer quits; finds `data/` from the build directory; loads the three textures; the ghost spring, the hover-pulse clock, the capture-spacing spring, `placingStone`. |
| 1015-1132 | main menu | sizes 9 / 13 / 19 as buttons + a 3-19 slider; Atari Go checkbox + goal combo (1 / 3 / 5); Start (initialise, and in Atari Go play the cross: B, W, B, W around the centre); Quit. |
| 1137-1244 | game input | Escape: pause; H: debug panel; side button: undo; left press on a legal point starts placing; release places at the point under the pointer if legal, records it, plays it, launches one flight per captured stone (staggered 0.05 s, 0.4 s each), and checks the Atari Go goal. |
| 1246-1339 | per frame | hovered point; pulse clock restarts when it changes; the board; a Menu button (top right) and an Undo button (bottom centre); the debug panel (player, move k / n, four toggles, undo / redo / restart). |
| 1341-1425 | hover overlays | the ghost (spring-smoothed, alpha 220 while placing, else 180 black / 80 white); liberties of the hovered group (gold rings, fading in, pulsing); debug: a red line from the hovered stone to its root, a square on the root, rings on the group. |
| 1427-1517 | overlays | pause window (return, three toggles, main menu, quit) and victory window (continue, restart, main menu), each over a dimmed board. |
| 1520-1560 | flights | after imgui renders: each captured stone eases (smootherstep) from the board to its column slot, shrinking. |

### 1.5 The helpers it needs from `math_utils.h`

- `SmootherStep(t) = t^3 (t (6 t - 15) + 10)` (Perlin's quintic).
- The **double spring damper** (Daniel Holden's critically damped spring, run twice in series for a smoother start):
  `halflife -> damping = 4 ln2 / (halflife + eps)`, `y = damping / 2`, `eydt = fastNegExp(y dt)`, then
  `j0 = x - goal; j1 = v + j0 y; x = eydt (j0 + j1 dt) + goal; v = eydt (v - j1 y dt)` - first for the intermediate
  point chasing the goal, then for the visible point chasing the intermediate. `fastNegExp(x) = 1 / (1 + x + 0.48 x^2
  + 0.235 x^3)`. Blend time 0.08 s for the ghost, 0.3 s for the capture-column spacing.

---

## 2. Behaviour the port must decide about (G1-G20)

Each was found by reading the code and checked by hand on the input given. **D1 (decided): every bug is fixed in the
port**, and each fix that touches the rules or the record is pinned by a test the C++ logic would fail.

### 2.1 Rules and history

| # | finding | input that shows it | recommendation |
|---|---|---|---|
| G1 | **Snapback is illegal for a turn.** After *any* move that captures exactly one stone, that point is forbidden. Ko only applies when the capturing stone stands alone with one liberty. | 5 x 5, rows `. . X O .` / `X O O . .`: White throws in at (0,0); Black captures it at (0,1) - now Black's two stones (0,1)-(0,2) have one liberty, (0,0); White's recapture of two stones there is legal Go and refused. | Fix: a ko capture = exactly one stone captured, by a stone now alone in its group, with exactly one liberty. |
| G2 | **Undo, redo and the debug panel's Restart lose the Atari Go cross.** The four starting stones are played but not recorded, and replay starts from an empty board. | Atari Go, play one move, undo: the cross is gone. | Fix: the cross is part of the game record (setup stones), replayed before the moves. |
| G3 | **On 3 x 3, Atari Go's cross captures its own first stone.** The corner black stone's two liberties are both taken by the cross; White starts with one capture and, at goal 1, wins after Black's first move. A 2 x 2 cross on 3 x 3 always holds a corner. | Size slider at 3, Atari Go, Start. | Fix: Atari Go needs a board of 4 or more (the menu says so). |
| G4 | The Atari Go win is checked in the input handler, not in `PlayMove`, so a replay clears it (the reset) and never sets it again. | Undo the winning capture, then redo it: the game goes on, no winner. | Fix: the engine decides the winner after every move, so replay recomputes it. |
| G5 | **Read-only questions reshape the forest.** `IsMoveSuicide` and the hover overlays call `FindGroupRootAndCompressPath` (the drawing code needs a `const_cast`, with the comment "annoying: path compression mutates groupRoot"). The forest's shape then depends on where the mouse went, and a replay builds a different one. Harmless to the rules; fatal to a forest view meant for learning and debugging. | Hover a long chain, then undo / redo: the arrows differ. | Fix: two finds - `findRoot` reads, `findRootCompressingPath` is used only while a stone is being placed. |

### 2.2 Input, drawing and UI

| # | finding | recommendation |
|---|---|---|
| G6 | **Clicks go through ImGui windows**: nothing checks `WantCaptureMouse`, so a click on the debug panel over the board also places a stone. | Fix: board input only when `u.wantCaptureMouse()` is false. |
| G7 | **Capture flights are drawn after ImGui renders**: over the pause and victory windows, and not dimmed. In Atari Go at goal 1 the winning stone flies across the victory dialog. | Fix: flights before the UI. |
| G8 | **Doomed-stone rings are drawn once per adjacent stone of the group** (no dedup), so a group touching the hovered point twice glows twice as bright; and doom is shown on points where the move is illegal (the ko point). | Fix: dedupe by root; show doom only for a legal move. |
| G9 | "Continue Playing" turns Atari Go off **in the main menu's setting** too. | Fix: switch only the current game to plain Go. |
| G10 | The debug panel's Undo does not clear the flights; every other undo, redo and restart path does. | Fix: one undo function used by every button. |
| G11 | The Undo and Menu buttons stay clickable while the pause or victory window is open. Undoing the winning capture silently removes the victory. | Keep undo-the-win (it is useful), but disable the board buttons while a window is open. |
| G12 | The last-move ring starts on the fourth cross stone in Atari Go. | Fix: setup stones are not moves. |
| G13 | Past ~60 captures on one side, the column (at its 0.6-radius minimum spacing) runs off the board and then the window. | Keep the minimum; let the column wrap into a second column. |
| G14 | A flight's landing point is computed once, at capture; when the columns compress mid-flight, the stone lands where its slot was and then jumps. | Fix: compute the landing point every frame. |

### 2.3 Platform leftovers and structure

| # | finding | recommendation |
|---|---|---|
| G15 | The GLFW resize hook exists because Windows blocks the main loop during a resize. | Not ported. In zimr this is the engine's job, already scheduled in `platforms_plan.md` ("The window freezes while dragged or resized on Windows", the sokol timer approach). The web never had the problem. |
| G16 | Quit and Quit-to-Desktop buttons. | **Kept on native only (Simon, D1).** A page has nothing to quit to, but a Windows program does. zimr has no app-to-platform quit yet - only the close button's `quit_requested` the other way - so this adds one (8.6), and the buttons show under `comptime z.host.drives_own_frames`. |
| G17 | ImGui at a fixed 2x scale. | `u.scaleToViewport`, so it reads on a phone. |
| G18 | Mutable globals (`boardSize`, layout, capture-column layout, two resize-hook pointers). | The board size lives in the position; the layout is a struct recomputed every frame (zimr allows no mutable module globals). |
| G19 | Dead code: the flood-fill engine (105-191). | **Revived with a job**: the slow, obviously-correct judge that checks the forest (section 4). |
| G20 | Star points: 9 on 13 x 13 (corners, sides, centre), where most 13 x 13 boards mark 5. | Keep the source's rule; it is a style. |

---

## 3. The pedagogical standard for this port

The source already reads well; the port goes further, and the zimr linter enforces part of it.

1. **One idea per line, named.** A condition gets a named boolean; a looked-up value gets a named local with its type.
   No expression that has to be unpacked in the reader's head, and none a debugger cannot show: every intermediate
   is in the locals pane when stepping in LLDB (Windows build) or Chrome (web build).
2. **Names carry their space and unit.** `point` (a 1D index), `row` / `col`, `*_px` for screen pixels, `*_seconds`;
   board space never mixes silently with screen space.
3. **Names chosen fresh, for a reader** (D6): they say what the data is (`group_parent`, where goforest's
   `groupRoot` holds parents until compressed), they use Go's own words where Go has one (point, prisoners, ko
   point, atari), and `GameState` splits into `Position` (what is on the board now) and `Record` (how we got here),
   which removes the save-and-restore dance around `ResetGameState`. Section 3.1 maps every goforest name; the file's
   header keeps a short version, so the C++ can still be followed beside it.
4. **Long functions for the important logic** (goforest's own rule, and zimr's "helpers only when the name does real
   work"): `placeStone` reads top to bottom as the rules do, in numbered steps.
5. **Statements, not cleverness, where a breakpoint may go**: `if` / `else` with braces on every branch (zimr lint),
   no load-bearing one-liners (goforest's "no ternaries for load-bearing logic").
6. **Queries cannot change state**: anything that only looks takes `*const Position`.
7. **Every precondition asserted**, with a message that names the values (`zm.assertf(..., @src(), ...)`); the
   expensive invariant checks run behind `zm.allow_assert` or a debug toggle.
8. **Tests read like Go diagrams** (`X` black, `O` white, `.` empty), so a test is a picture of the position.
9. **One file, read top to bottom** (D5): it opens with a `//!` lesson - what the program is, the forest drawn as
   ASCII, where each part came from in goforest - and a table of contents; each section opens with a
   `// ===== N. Name =====` banner and a short lesson of its own. The order is the dependency order the linter wants
   (`decl-order`), which is also the order to learn it in: stones, the forest, the rules, the record, the judge,
   then drawing and the app, tests last.

**The exemplar** - goforest's `IsMoveSuicide`, as it will be written (D6: this style, approved, with fresh names):

```zig
/// Would a stone of the player to move, placed on `point`, be left with no liberty?
/// It survives if any neighbour gives it a way out:
///   - an empty neighbour is a liberty of its own;
///   - a friendly group with 2+ liberties still has one after this stone fills one;
///   - an enemy group with exactly 1 liberty (this point) is captured, and its stones' places become liberties.
/// If no neighbour does any of those, the move is suicide.
/// Read-only: roots are looked up with `findRoot`, which never reshapes the forest.
pub fn wouldBeSuicide(position: *const Position, point: Point) bool {
    assertf(position.stones[point] == .none, @src(), "wouldBeSuicide asked about occupied point {d}", .{point});
    const mover: Stone = position.player_to_move;
    const enemy: Stone = mover.opponent();

    const neighbors: Neighbors = position.neighborsOf(point);
    for (neighbors.points[0..neighbors.count]) |neighbor| {
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
```

### 3.1 Names: goforest -> goban (D6, proposed - confirmed with the final list)

The rules engine:

| goforest | goban | why |
|---|---|---|
| `Stone` (`char`), `STONE_NONE / BLACK / WHITE` | `Stone = enum { none, black, white }` | "stone: none" reads as English |
| `OtherStoneColor(s)` | `stone.opponent()` | |
| `BoardIndex`, `INVALID_INDEX` | `Point` (`u16`), `?Point` / `null` | Go's word for an intersection; Zig's optional for "none" |
| `boardSize`, `totalCells` (globals) | `position.board_size`, `position.pointCount()` | no globals |
| `Index1D`, `RowFrom1D`, `ColFrom1D`, `IsValidRowCol` | `pointAt(row, col)`, `rowOf`, `colOf`, `isOnBoard(row, col)` | |
| `GetNeighbors(id, result[4])` | `neighborsOf(point) -> Neighbors` | returned by value, no out-array |
| `GameState` | `Position` + `Record`, held together by `Game` | the board now, and how we got here |
| `board` | `stones` | |
| `groupRoot` | `group_parent` | it holds parents |
| `groupLiberties`, `groupStones` | `group_liberties`, `group_stones` | meaningful at roots |
| `koForbidden` | `ko_point` | |
| `currentPlayer` | `player_to_move` | |
| `lastPlaced` | `last_move` | |
| `capturedByBlack / White` | `stones_captured_by_black / white` | says whose stones and whose capture |
| `winner` (`STONE_NONE` = none) | `winner: ?Stone` | |
| `lastCapturedPositions` | `MoveReport.captured` | what a move did, returned |
| `moveHistory`, `historyPosition` (-1 = none) | `Record.moves`, `moves_recorded`, `moves_played` | counts, no -1 |
| `FindGroupRootAndCompressPath` | `findRootCompressingPath`, plus the read-only `findRoot` | "path compression" is the textbook term to look up |
| `MergeGroups(A, B)` | `joinGroups(new_root, joining_root)` | |
| `KillGroup` | `removeCapturedGroup` | |
| `PlayMove` | `placeStone -> MoveReport` | |
| (the Atari Go cross, via `PlayMove`) | `putSetupStone(game, stone, point)` | on the board, not a move |
| `IsMoveSuicide` | `wouldBeSuicide` | |
| (the legality test, written three times) | `checkMove(position, point) -> Legality` | one definition, which says why not |
| `InitGameState`, `ResetGameState` | `startGame(game, settings)` | |
| `ReplayMoves`, `UndoMove`, `RedoMove` | `replayTo(game, moves_played)`, `undo`, `redo` | |
| `FindGroupAndLiberties`, `CaptureStones` (dead) | `floodFillGroup`, `findDisagreement` (the judge) | |

The application:

| goforest | goban | why |
|---|---|---|
| `AppState` | `State` | zimr's `AppSpec(State)` |
| `Screen` (`SCREEN_MAIN_MENU`, `SCREEN_GAME`) | `Screen = enum { main_menu, playing }` | |
| `pauseMenuOpen`, `showDebugPanel`, `quitRequested` | `pause_window_open`, `debug_panel_open`, `z.requestQuit()` | |
| `selectedBoardSize`, `atariGoMode`, `atariCaptureGoal` | `NewGameSettings { board_size, atari_go, capture_goal }` | what Start uses |
| `AppOptions` (`showDebug`, `showDoomedStones`, `showLiberties`, `showAtariGroups`) | `Overlays` (`show_forest`, `preview_captures`, `show_liberties`, `mark_atari_groups`) + `verify_every_move` | each says what it shows |
| the three textures | `textures.wood`, `.black_stone`, `.white_stone` | |
| capture columns (six globals) | `PrisonerColumns`, part of `BoardLayout` | "prisoners": Go's word for captured stones |
| `CaptureAnimation`, `captureAnimations` | `PrisonerFlight`, `prisoner_flights` | |
| `UpdateBoardLayout` | `BoardLayout.fromWindow` | |
| `DrawBackgroundTexture`, `DrawStoneTexture`, `DrawBoardAndStones` | `drawWood`, `drawStone`, `drawBoard` (+ `drawOverlays`, `drawForest`, `drawPrisoners`) | |
| `DoubleSpringDamperState`, `DoubleSpringDamper` (+ `Vector2`) | `zm.DoubleSpring(T)` with `.step(goal, blend_seconds, dt)` | in zm (D7, 8.7) |
| `SmootherStep` | `zm.smootherStep`, bound bare as `smootherstep` | in zm (D7, 8.7) |
| `ghostDamper`, `ghostHasTarget`, `placingStone` | `ghost_spring: DoubleSpring(Vec2)`, `ghost_has_target`, `stone_held` | |
| `lastHoveredForPulse`, `hoverPulseStartTime` | `pulse_point`, `pulse_start_seconds` | |
| `captureSpacingDamper`, `captureSpacingInitialized` | `prisoner_spacing_spring: DoubleSpring(f32)`, `prisoner_spacing_started` | |
| `GoGameDSU` (the loop) | `update` | |

---

## 4. Debugging capabilities

The source has four overlays and a small panel. The port keeps them and adds tools that let a learner (or a bug
hunter) *see* the forest and *check* it. **D2 (decided): all four.**

| tool | what it shows or does | why |
|---|---|---|
| **The judge** (reference check) | goforest's dead flood fill, revived as section 5 of `goban.zig`: recompute every group and its liberties from the stones alone, and compare with the forest. Returns the first disagreement, named ("point (3,4): forest says 3 liberties, flood fill says 2"). Run after every move in the tests; in the app, after every move while "verify every move" is on, the result in the debug panel and an assert. | A check must use a value the code under test did not produce (claude.md: "a self-referential check is not a check"). The flood fill is an independent second implementation, and the simplest possible one. Proven able to fail: a test corrupts one liberty and expects the judge to name it. |
| **Forest view** | every stone's parent pointer drawn as an arrow, roots as squares, depth as a number on demand - not only the hovered stone's line to its root. | Path compression and "the newest stone becomes the root" become visible move by move. With G5 fixed, what is drawn is exactly what the engine built. |
| **Inspector + move log** | in the debug panel: the hovered point's row / col, index, stone, parent, root, depth, group size, liberty count; and one line per move ("B (3,4): merged 2 groups, captured 3, ko at (3,5)"). | The numbers behind the picture, without a debugger attached. |
| **Position as text + timeline** | copy the board to the clipboard as a diagram (`z.setClipboardText`) - paste it straight into a test; paste a diagram back to load a position (`z.getPastedText`); a slider over the move list replays to any move. | Turns "I saw something odd" into a test in one step, on a phone too. |

And from zimr itself: the Windows build runs under LLDB with the regenerated launch configs; a headless script
plays a scripted game and saves frames as PNGs; the smoke test watches leaks and GPU validation.

**The diagram format** (copy, paste and the tests share one parser):

    // goban 5x5, white to play
    . . X O .
    X O O . .
    . . . . .
    . . . . .
    . . . . .

`X` black, `O` white, `.` empty, spaces optional; the `//` line is optional and says whose turn it is (black when
absent). The size is the number of rows, which must be 3-19, every row as long. A pasted position is refused, with
the reason in the panel, when a row's length differs, a character is unknown, or a group has no liberty. It loads as
the record's setup: no moves, no ko point, no captures yet - the panel says so, because a diagram cannot carry them.

---

## 5. What zimr already has

### 5.1 Call by call

| goforest | zimr |
|---|---|
| `InitWindow`, `SetConfigFlags(RESIZABLE)`, `SetTargetFPS`, the main loop | `app.config.window` with `.scale_mode = .responsive`; the runner calls `update(f, s)` every frame |
| `GetScreenWidth/Height` | `f.window.widthf()` / `heightf()` (logical pixels) |
| `GetTime()` (double), `GetFrameTime()` | `f.time.time` (f32 seconds since start), `f.time.delta_time` |
| `IsMouseButtonPressed/Released(LEFT)`, `GetMouseX/Y` | `z.isMouseButtonPressed/Released(f.input, .left)`, `z.getMousePosition(f.input)` |
| `MOUSE_BUTTON_SIDE` | `.side` (same value, 3) |
| `IsKeyPressed(KEY_ESCAPE)`, `KEY_H`, `SetExitKey(KEY_NULL)` | `z.isKeyPressed(f.input, .escape)`, `.h`; nothing to disable |
| `LoadTexture("data/...")`, `UnloadTexture` | `@embedFile` + `z.loadImageFromMemory` (PNG) + `z.loadTextureFromImage`, the CPU pixels freed after upload; `tex.deinit()` (as `textures_background_scrolling`). No search for `data/`: the files are in the binary. |
| `DrawTexturePro` | `f.gl.texture(dst, tex, .{ .source, .tint })` |
| `DrawLine`, `DrawLineEx` | `f.gl.line(a, b, .{ .color, .thickness })` |
| `DrawCircle`, `DrawCircleLines` | `f.gl.circle(c, r, .{ .color })`, `.outline = width` |
| `DrawRing` | `f.gl.ring(c, inner, outer, start_rad, end_rad, segments, .{ .color })` |
| `DrawRectangle`, `DrawRectangleLines` | `f.gl.rect(r, .{ .color })`, `.outline = width` |
| `Clamp`, `Lerp`, `Saturate` | `zm.clamp`, `zm.lerp`, `zm.clamp01` |
| `SmootherStep`, the spring dampers | `zm.smootherStep`, `zm.DoubleSpring(T)` - **new in zm** (D7, 8.7); today zm has only `smoothstep`, and `u.spring` is a UI animation keyed by label |
| ImGui (rlImGui) | `z.UiHost` (zimr's Dear ImGui port): `u.window`, `u.button`, `u.checkbox`, `u.slider`, `u.beginCombo` / `u.selectable`, `u.text`, `u.separator`, `u.sameLine`, `u.setNextWindowPos/Size`, `u.wantCaptureMouse`, `u.scaleToViewport` |
| `unordered_set<BoardIndex>`, `vector<BoardIndex>` per point | `std.bit_set.StaticBitSet(361)` (`.empty`, `set`, `unset`, `isSet`, `count`, `setUnion`, `iterator`), already used in `native_input.zig`: no allocation, union is one OR |
| `vector`s sized by board | fixed arrays sized 19 x 19 = 361 |
| `assert` | `zm.assertf(ok, @src(), fmt, args)` |
| Quit, Quit to Desktop | `z.requestQuit()` - **new** (8.6), called only under `comptime z.host.drives_own_frames` |
| GLFW resize hook | see G15 |

### 5.2 Registering an example

1. `build.zig`, the `wgpu_apps` table: `.{ .name = "goban", .title = "zimr - goban" }` - gives `zig build goban`
   (`-Dplatform=web|windows`), `run-goban`, `goban-headless`, the smoke test and a gallery shot.
2. `src/web/manifest.json`: the gallery card.
3. `zig build editor-configs` (`generate_editor_configs.bat`) regenerates the VS Code and Zed launch files, including
   the LLDB entry for `zig-out/windows/goban.exe`; `zig build check` fails until it is run.
4. `src/notes/examples_catalog.md`: a row under "2D simulation and games", and the counts.
5. `zig build files-md`: the per-file atlas.
6. A `test-goban` step: a test artifact from the example's own module, for the host (8.1).
7. The launcher (D8: now, at S13): `examples/launcher/launcher.zig` **and** build.zig's `flagships` list - one
   alone gives "no module named ex_goban". The launcher is what `platforms-check` compiles for Linux, macOS and
   Android, so goban must compile there too (8.6).

### 5.3 House rules that shape the code

`.memory = .managed` hands `init` zeroed memory, so `init` writes the whole `State` (`s.* = .{ ... }`); no mutable
module globals; explicit types on locals; braces on every branch; declarations dependency-first; `@round` / `@trunc`
for float to int, `zm.float` for int to float; layout from the live window, never the configured size; a panic
handler (`std.debug.FullPanic(common.reportPanic)`); UI sized with `u.scaleToViewport`.

---

## 6. Brainstorm - every option, including the ones I expect to reject

- **Approach (D1).** (A) port every feature with the bugs of section 2 fixed, each fix pinned by a test; (B) port
  faithfully, bugs included, then fix each as its own lesson (failing test, then fix) - goforest's tutorial mode;
  (C) the engine and its tests only, the app later; (D) A plus new Go: pass, scoring, an MCTS player (goforest's own
  "possible next steps").
- **Debugging tools (D2).** Any subset of section 4.
- **UI (D3).** (A) zimr's ImGui port, the same windows as the source; (B) hand-drawn buttons (langton_ant's idiom),
  no `ui.zig` - a faster compile, but the slider, combo and checkboxes must be hand-made; (C) hand-drawn in-game
  buttons, ImGui menus.
- **Assets (D4).** (A) the stones as PNG, the wood re-encoded as a baseline JPEG (~1.3 MB -> ~0.2 MB of page); (B)
  all three PNGs as they are; (C) procedural - wood from noise, stones as gradients, no files; (D) the PNGs scaled
  down. Whatever the encoding, the images' origin decides whether they may ship in zimr at all.
- **Files (D5).** (A) by concept: rules, reference judge, tests, drawing, app; (B) one file, like goforest; (C)
  engine + app.
- **Names and style (D6).** (A) source names Zig-cased, misleading ones renamed, the exemplar's style; (B) new names
  throughout.
- **Spring and smootherstep (D7).** (A) local to the example, a short commented section; (B) added to `zm`
  (claude.md: "every gap in zimrmath is a workaround somewhere else") - then vector-generic, branch-free, tested.
- **Launcher (D8).** Now, or later.
- Smaller choices: a recursive find (as goforest) or an iterative two-pass one (each step a local in the debugger);
  union by newest stone (as goforest) or by size (shallower trees, but a different forest from the source's);
  Atari Go's win in the engine or the app; one generic `DoubleSpring(T)` or a scalar spring used twice for 2D.

---

## 7. Preferred choices, and why

| | pick | why |
|---|---|---|
| D1 | **A - decided** | The port is meant to be read, and a known bug teaches less than its test and its fix. The fixes are small and local, and each test documents the rule it protects (G1's snapback test is a Go lesson in itself). |
| D2 | **All four** | The judge is what makes the rest trustworthy; the forest view is the reason the program is called goforest; the inspector and text positions turn sightings into tests. |
| D3 | **A, ImGui - decided** | Same widgets as the source, so the port maps line for line; zimr has the port; `scaleToViewport` makes it phone-sized. Cost: ui.zig roughly triples the compile (claude.md: 3 s -> 10 s). |
| D4 | **B - decided** (all three PNGs as they are) | Recommended was A (JPEG wood, ~1 MB lighter); Simon chose the files unchanged - identical pixels, one decoder, nothing to re-encode. |
| D5 | **B - decided** (one file, like goforest) | Recommended was A (a file per concept); Simon chose one file, read top to bottom as goforest is. Sections with banners and a table of contents carry the structure instead. |
| D6 | **C - decided** (the exemplar's style, fresh names) | Recommended was A (source names kept); Simon chose names picked anew. Section 3.1 proposes them. (Superseded Oct 18: goforest is not mentioned in the code or the tutorial - no name table, no citations.) |
| D7 | **B - decided** (into zm now) | Recommended was A (local); Simon chose zm, so the gap is closed where claude.md says gaps belong. Stage E2, designed in 8.7. |
| D8 | **Now, at S13 - decided** | Recommended was later; Simon chose now. It brings `platforms-check` into goban's gates (8.6's run-time refusal in `unwritten.zig` is what keeps that compiling) and the switch pill onto goban's screen (8.5). |
| small | iterative find, union by newest, win in the engine | debugger-visible steps; faithful forest; replay-consistent wins. (The spring is generic in zm now, D7.) |

---

## 8. The design

### 8.1 Files (`examples/goban/`) - one source file (D5)

    goban.zig, ~2300 lines, in this order (the table of contents at its top):
       1. Stones and points     Stone, Point, PointSet, Neighbors, index helpers                                ~120
       2. The forest            Position; findRoot / findRootCompressingPath, joinGroups, removeCapturedGroup   ~200
       3. The rules             wouldBeSuicide, checkMove -> Legality, placeStone -> MoveReport                  ~230
       4. The record            Record (setup + moves), startGame (Atari Go cross), undo / redo / replayTo       ~150
       5. The judge             flood fill from the stones alone, findDisagreement                              ~180
       6. Diagrams              text <-> position (the tests, copy and paste share it)                          ~120
       7. Layout                BoardLayout and the prisoner columns, from the window every frame                ~110
       8. Drawing               background, grid, star points, stones, markers, overlays, forest view, columns,
                                flights (springs and easing from zm, D7)                                         ~450
       9. The app               State, init / deinit (textures, UI), update: screens, input, menus, debug panel,
                                Quit on native; AppSpec, panic handler                                           ~520
      10. Tests                 the tests of 8.4, run by `zig build test-goban`                                  ~400
    check.script                the headless walk-through                                                         ~80
    black_stone.png, white_stone.png, wood.png    goforest's b.png, w_1.png and wood.png, unchanged (D4), renamed
                                                  for what they show; @embedFile'd, decoded by z.loadImageFromMemory
                                                  (in place since Oct 18)
    goforest/                   the C++ original, frozen (in place since Oct 18): main.cpp, utils.h, math_utils.h,
                                CMakeLists.txt, goforest_notes.md (its CLAUDE.md, renamed so Claude Code does not load
                                it as instructions here), README.md. Never built: the build and lint walks take .zig
                                files only. Not `reference/`: .gitignore ignores every folder of that name.

**Neither `goban.zig` nor the tutorial mentions goforest (Simon, Oct 18: it is just a previous version).** The
`goforest/` folder stays as this plan's reference; the plan's `main.cpp:NNN` citations are for the plan only.

**`test-goban`**: a test artifact built from the example's own module for the host (as the `bmpc-cartpole` step
builds one), running the tests at the end of `goban.zig`. Zig analyses only what the tests reference, so the rules'
tests compile the rules, not the renderer; the first run at S6 confirms that and measures the time.

### 8.2 Types

```zig
// Compile-time parameters live in namespaces, never bare at the file's root (Simon, Oct 18).
pub const board_limits = struct {
    pub const min_size: u8 = 3;
    pub const max_size: u8 = 19;
    pub const max_points: usize = @as(usize, max_size) * max_size; // 361
};
pub const record_limits = struct {
    pub const max_moves: usize = 1024;
};
pub const Point = u16; // a 1D index: row * board_size + col (goforest's BoardIndex)
pub const PointSet = std.bit_set.StaticBitSet(board_limits.max_points);
pub const SetupStone = struct { point: Point, stone: Stone }; // the Atari Go cross: on the board, not a move

pub const Stone = enum(u8) {
    none,
    black,
    white,

    pub fn opponent(self: Stone) Stone { ... } // asserts self != .none
};

// neighborsOf(board_size, point, out_buffer: *[board_limits.max_neighbors]Point) []const Point - up, down, left, right
// (Oct 18: the Neighbors struct gave way to the caller's buffer and an ArrayList made with initBuffer)

/// What is on the board now. Rebuilt by replay; everything here follows from the record.
pub const Position = struct {
    board_size: u8,
    stones: [board_limits.max_points]Stone,
    /// The forest. A stone's parent in its group's tree; a root is its own parent; null on an empty point.
    group_parent: [board_limits.max_points]?Point,
    /// Meaningful at a root only: the group's liberties, and its stones.
    group_liberties: [board_limits.max_points]PointSet,
    group_stones: [board_limits.max_points]PointSet,
    ko_point: ?Point,
    player_to_move: Stone,
    last_move: ?Point,
    stones_captured_by_black: u32,
    stones_captured_by_white: u32,
    capture_goal: ?u8, // Atari Go: the first to capture this many wins; null in plain Go
    winner: ?Stone,
};

/// How we got here: replaying it from an empty board rebuilds the position.
pub const Record = struct {
    setup: [board_limits.max_points]SetupStone, // the Atari Go cross, a pasted position, or nothing
    setup_count: u16,
    setup_to_play: Stone,          // whose turn after the setup: black, unless a pasted diagram says white
    moves: [record_limits.max_moves]Point,
    moves_recorded: u16, // the redo end
    moves_played: u16,   // where we are (goforest: historyPosition + 1)
};

/// What a move did - for the move log, the flights and the tests.
pub const MoveReport = struct {
    placed: Point,
    mover: Stone,
    groups_merged: u8,
    captured: PointSet,
    captured_count: u32,
    ko_point: ?Point,
};

pub const Legality = enum { legal, occupied, ko, suicide, game_over }; // no off_board: checkMove takes a Point
```

`checkMove(position, point) Legality` replaces the four-condition test goforest repeats in three places (press,
release, ghost): one function defines a legal move, and its answer names why not.

### 8.3 `placeStone`, step by step

1. The stone becomes a group of one: its own parent, its own stone set.
2. Liberties: each empty neighbour is one of its liberties; each neighbouring group, friend or enemy, loses this point.
3. Join friendly neighbours (`joinGroups(placed, neighbour_root)`, the newest stone stays the root).
4. Capture each enemy neighbour group left with no liberty (`removeCapturedGroup`: every emptied point becomes a liberty of the
   mover's groups beside it).
5. Ko (G1): forbidden point only if exactly one stone was captured, by a stone alone in its group, with one liberty.
6. Capture counts; Atari Go goal -> `winner` (G4); the turn passes; the report is returned.

### 8.4 Tests (`zig build test-goban`)

Each source bug gets a test that the C++ logic fails and the port passes; each rule gets one written as a diagram.

| test | proves |
|---|---|
| lone stone captured in the middle / on the edge / in the corner | capture |
| a group of three captured at once, all its points become liberties of the capturer | groups, `removeCapturedGroup` |
| suicide refused; a "suicide" that captures is legal | `wouldBeSuicide` |
| ko: the immediate retake refused, allowed after a threat and an answer | ko |
| **snapback**: the 5 x 5 position of G1; White's recapture of two is legal | G1 |
| Atari Go cross survives undo and redo; restart re-places it; no last-move ring on it | G2, G12 |
| Atari Go refuses a 3 x 3 board | G3 |
| an Atari Go win is set by replay and cleared by undo | G4 |
| a position built with read-only queries in between has the same forest as its replay | G5 |
| **random games**: ~2000 random legal moves over several sizes and seeds, the judge after every move | the whole engine |
| undo to every move, then redo to the end: identical to the live game | replay |
| **the judge can fail**: one liberty corrupted on purpose, the judge names that point | the judge itself |
| a diagram round-trips: text -> position -> text | the test tool |
| a pasted diagram with a dead group, a ragged row or an unknown character is refused, each with its reason | paste |

### 8.5 The application

- **Frame order** (fixes G6, G7): begin UI and submit every window (they render later) -> board input, only when
  `!u.wantCaptureMouse()` -> background, board, overlays, forest view, ghost, flights -> dim and UI render last.
- **State**: screen (`main_menu`, `game`), `pause_open`, `debug_panel_open`; menu settings (size, Atari Go, goal);
  display options (goforest's four + forest view + verify every move); the textures; the ghost spring, pulse clock,
  column spring, `placing_stone`; the flights (fixed array, asserted capacity); the move log; the UI host and font.
- **Phones**: Escape, H and the side button do not exist there, so the Menu button opens the pause window, which also
  holds the debug panel's toggle; press - drag - release already suits a finger.
- **Quit** (G16): the main menu's Quit and the pause window's Quit to Desktop, both inside
  `if (comptime z.host.drives_own_frames) { ... }` - true for native and headless, the hosts whose program runs its
  own loop and so can end it; false in the browser, which calls a page's frames. Inside the Windows launcher, Quit
  ends the launcher itself - the program the person is in, as "Quit to Desktop" says.
- **The launcher's switch pill** (D8) is centred 56-90 px above the bottom edge; goforest's Undo button sits
  bottom-centre, 10-60 px up. They touch: S13 checks them together on device, and Undo moves to a bottom corner if
  they collide.

### 8.6 The engine addition: `z.requestQuit`

An app cannot end a native run today. The platform contract carries the close button's `quit_requested` from the
platform to the engine, and nothing the other way. The addition follows the contract's own pattern for a request one
platform cannot carry out (the window requests the web refuses):

| place | change |
|---|---|
| `src/platform/contract.zig` | `requests` gains `.{ .name = "requestQuit", .signature = fn () void }`: the app asks to end; the loop finishes the frame, tears down and the program exits, as after the close button. |
| `src/platform/windows.zig` | sets the flag the `WM_CLOSE` handler sets (`close_requested`), so the next `serviceWindow` returns `.closed` and the existing teardown runs - one way out of the program, not two. |
| `src/platform/headless.zig` | ends the run, as a script's `.quit` does. |
| `src/platform/web.zig` | `@compileError("web platform: a page cannot close its browser's tab")`, beside the window requests' refusals: code that calls it for the web does not compile. |
| `src/platform/unwritten.zig` | `refuse("requestQuit")` at run time, as it refuses every other request, so the launcher still compiles for Linux, macOS and Android in `platforms-check` (D8: goban is in the launcher, and `drives_own_frames` is true there). |
| `src/platform/template.zig` | refused at compile time, as that file refuses every request for a platform being written. |
| `src/wgpu_app.zig`, `src/zimr.zig` | `pub fn requestQuit() void` with its doc comment, and the `z.` re-export. |
| `src/web/readme.html` | the new request, the same turn (claude.md: keep the readme current). |

Rejected: `std.process.exit` from the example - it skips the GPU teardown and the allocator's leak check
(claude.md: "`std.process.exit(1)` skips the leak check").

### 8.7 The engine addition: `zm.smootherStep` and `zm.DoubleSpring` (D7)

goforest's motion comes from two helpers in its `math_utils.h` that zimrmath lacks. They go into zimrmath, written
its way - claude.md: "every gap in zimrmath is a workaround somewhere else", and "a zimrmath function that only takes
scalars is half a function".

```zig
/// Perlin's smootherstep: 0 below `e0`, 1 above `e1`, and between them the quintic t^3 (t (6t - 15) + 10), whose
/// first and second derivatives are both zero at the ends (smoothstep's second derivative jumps there). `x` is a
/// scalar or a float vector, lane by lane, with scalar edges - GLSL's smoothstep(float, float, genType) shape.
/// Branch-free, so shaders may call it.
pub fn smootherstep(e0: f32, e1: f32, x: anytype) @TypeOf(x) { ... }

/// Daniel Holden's critically damped spring ("Spring-It-On", theorangeduck.com), run twice in series: a hidden
/// point chases the goal and the shown point chases the hidden one, so motion starts with zero acceleration as well
/// as zero velocity. `blend_seconds` is about how long the trip takes; each spring takes a quarter of it as its
/// half-life (goforest's math_utils.h:395). `T` is f32 or a float vector (Vec2, Vec3, Vec).
pub fn DoubleSpring(comptime T: type) type {
    return struct {
        value: T,
        velocity: T,
        hidden_value: T,
        hidden_velocity: T,

        pub fn atRest(start: T) @This() { ... }
        pub fn step(spring: *@This(), goal: T, blend_seconds: f32, dt: f32) void { ... }
    };
}
```

- **Generic the zimrmath way**: `smootherstep` follows `sinh` (`@typeInfo(T) == .vector` -> `perLane`, constants
  through `splatLike`); `DoubleSpring` follows `Range(comptime T)`. The ghost uses `DoubleSpring(Vec2)`, the prisoner
  columns `DoubleSpring(f32)`.
- **`smoothstep` stays as it is** (scalar, three `f32`): changing its signature would break callers passing literals.
  The pair is then asymmetric until `smoothstep` gets the same vector `x` - noted as a follow-up, not done here.
- **`@exp(-x)` instead of goforest's `FastNegExp`**: the rational approximation is 0.5 % high at the ghost's settings
  (blend 0.08 s at 60 fps, x = 1.155: 0.3168 against 0.3151) and 0.02 % at the columns' (0.3 s), nothing a person
  sees, and an exact exponential needs no explaining in a library. On the final list.
- **Tests** in zimrmath (`zig build test-zimrmath`), each against a value the code does not produce: smootherstep's
  ends, its midpoint 0.5 and `smootherstep(0, 1, 0.25) = 0.103515625` (exact in binary, worked by hand); its symmetry
  `s(1 - t) = 1 - s(t)`; zero first and second derivatives at the ends (finite differences); vector lanes equal to
  scalar calls. The spring: a step toward a goal from rest never overshoots and arrives (the arrival bound measured,
  then pinned); its first step against numbers worked by hand from goforest's formulas; `DoubleSpring(Vec2)` equal to
  two `DoubleSpring(f32)`; `dt = 0` changes nothing.
- **Around it**: `smootherstep` joins the vocabulary index in zimrmath's header and the `@hasDecl` list in
  `src/tests/features_test.zig` (beside `smoothstep`); it becomes a zimrlint math keyword like `smoothstep`, bound
  once and used bare (`no-qualified-zm`; nothing in the tree bears the name today, so reserving it is free); and
  `src/shaders/zm_gpu_probe.zig` calls it on a `Vec`, so `zig build zm-gpu` proves it lowers to SPIR-V.

### 8.8 The opponent: Monte Carlo tree search for Atari Go (S14-S17, D9-D13 open)

**Why this algorithm suits Atari Go.** A program that plays a board game needs to know how good a position is.
Plain Go makes that hard: who is ahead depends on territory that is only settled at the end of a long game, so a
search must guess. Atari Go removes the guess - the game ends the moment a player reaches the capture goal, often
within a few dozen moves on 9 x 9 - so a game played out at random from any position reaches a real result, a win or
a loss, with no judgement of the board at all. Monte Carlo tree search (MCTS) is built on exactly that: it plays many
such games, and keeps the statistics of their first moves in a tree that grows toward the moves that win.

**One iteration, four steps** (the classic UCT form - Kocsis and Szepesvari 2006, Coulom 2006):

    1. selection       from the root, go down the tree, at each node to the child with the highest
                       UCB1 = wins / visits + c * sqrt(ln(parent visits) / visits)
                       - the first term the moves that have won, the second the moves tried least; c = sqrt(2)
                       to start, a field of the search's settings
    2. expansion       at the first node with a legal move not yet tried, add that move as a new child
    3. simulation      from there, play the game out - a playout - until a player reaches the goal
    4. backpropagation walk back to the root: every node visited counts one visit more, and one win more when the
                       player who moved into it is the playout's winner

After the budget, the move played is the root's most visited child (the "robust child": visits are steadier than
win rates, which a lucky few playouts can inflate).

**The data, one block of nodes.** The tree is one array of nodes joined by indices - no pointers - so it is one
contiguous block of bytes that a job can hand back and the next job take up again, copied in one piece with nothing
to fix up. A node is an `extern struct`, whose layout Zig fixes the same in every compile (the workers' kernels are a
separate one), and small - about 24 bytes:

    SearchNode = extern struct { move: u16, mover: u8, ..., parent: u32, first_child: u32, next_sibling: u32,
                                 visits: u32, half_wins: u32, children_made: u16 }

A tree of a second's search - tens of thousands of iterations, one node each - is a megabyte or two. Wins are counted
in half-points (2 a win, 1 a half-won playout), so every count is an integer. A node does not store its untried moves:
its children are made in the order of its legal moves (found with section 3's `checkMove` - ko, suicide and a won
game are the rules' business, never the search's), so `children_made` says which legal move is next. The tree comes
with a small header: how many nodes, the record length at its root, and the random generator's state.

Each iteration starts from a copy of the root position (a `Position` is fixed arrays, about 36 KB: one memcpy) and
plays the selected moves on it with `placeStone`; the root position itself is never touched, and a test says so. The
random generator's state is part of the tree's header and moves on with it, so a search continued in several jobs
draws the same numbers as one search run in one: the same seed and the same count of iterations give the same tree,
however the work was cut.

**Playouts.** A light playout plays uniformly random legal moves. A heavy one first plays the urgent move: capture an
opponent's group in atari (with a goal of one, that wins at once), else rescue one's own group in atari by playing
its last liberty, drawing at random among several; failing both, a random legal move. The urgent moves are looked for
over the whole board, not around the last move only as the attached program does: S15 found that a last-move rule
leaves a group standing in atari once its owner has played elsewhere, so that the search judged leaving a stone in
atari nearly safe (5 x 5, black's stone in atari: the rescue fell from first to below fifth). A playout that finds
no legal move, or runs past a cap of moves, counts as half a win for each side.

**Moves near the stones (D14, Simon - eventually).** In Atari Go the good moves are nearly always close to the
stones already on the board. So the search's candidate moves - a node's children - are to be limited to the points
within two of a stone, which leaves the root a fraction of the board's moves and lets the search go deeper; the
same may later apply to the playouts' random moves. Where no legal move is that close, every legal move is a
candidate, so the computer always has one. To settle when it is built: "within two" as two steps along the lines
(Manhattan distance <= 2 - excludes the knight's move, one across and two along, a common shape) or the 5 x 5 square
around a stone (Chebyshev distance <= 2 - includes it); recommended: the square.

**Off the main thread: the search as a job (D9).** The search runs in zimr's job system (`src/jobs.zig`): a kernel
is a pure function - an arena, a small header, a payload, a writer for its result - run on a Web Worker in a page, on
a thread of the program's own natively, so the board keeps moving at 60 frames a second while the computer thinks.
A kernel keeps nothing from one job to the next, so the tree travels with the job, in and out:

    kernel continueSearch(arena, header: { iterations, settings }, payload: the record + the last tree, out)
        replay the record into the position to search (section 4's replayTo)
        take up the last tree where it fits the position: the node reached by the moves played since its root
            becomes the new root, its subtree copied into a fresh array; anything else, a fresh tree
        run `iterations` iterations of MCTS on it
        write the tree: its header, then its nodes, in one block

**One worker, one fixed budget (D11).** A move is one job, on one worker, for a fixed count of iterations - tuned so
that a move takes about a second (on Simon's phone, the slowest place goban runs). A fixed count, not a clock: the same
position gives the same move on every device, only sooner or later. The debug panel shows the count and the time the
last move took, to tune it by.

**The tree kept between moves (D13).** After the computer's move and the reply, the node of that pair of moves is the
root of a subtree the last search already explored - its visits are a head start. The app keeps the tree the job
returned and hands it to the next job, which takes up that subtree (above). A tree that does not fit - a new game,
an undo, a pasted position - is simply not taken up.

Where no worker can be made - a page in a sandboxed frame, the Claude app's preview among them - a job runs inline,
inside `submit`, holding up that frame for as long as it takes (`jobs.parallel()` says which); a second's job would
freeze the board for a second. There the same budget is cut into jobs of about a frame's worth of iterations, one a
frame, each taking up the tree the last returned: since the generator's state travels with the tree, the move is the
same as one job's.

The payload is the record, not the position's bytes: Zig does not fix a plain struct's layout across compilations, and
the record is a few arrays of points and numbers in a defined order, from which section 4's `replayTo` rebuilds the
position - the prisoners, the ko point and the capture goal with it. The kernel is listed in
`examples/goban/kernels.zig`, the registry the build compiles into the workers' wasm: a second file beside
`goban.zig`, which the build requires (D5's one file holds everything else), and which the launcher's own registry
merges in (D8).

The search starts in the example (D9); once a second game wants one, it moves into zimr as a generic MCTS, keeping the
kernel's shape.

**What the attached C++ program does, and why goban differs.** It is a useful sketch - the four steps, UCB1, a
heavy playout - and it shows what to avoid:
- it searches for 950 ms inside one frame, so the window freezes while the computer thinks (on a page the tab
  would stall): goban searches in jobs, off the main thread;
- its budget is wall-clock time, so the same position can give different moves: goban counts iterations;
- it stops each playout after 60 moves and counts stones, which measures little in Go: Atari Go playouts reach
  the real end;
- a node's untried moves are every empty point, and an illegal one (ko, suicide) found at expansion is dropped while
  the iteration goes on from the parent, crediting its playout to the wrong node: goban lists legal moves only;
- each iteration copies the board's hash sets and vectors, allocating: goban copies fixed arrays;
- its nodes are `new`/`delete` objects joined by pointers: goban's are one array with indices;
- it uses `rand()` and `std::random_shuffle` (removed in C++17): goban takes a seeded generator;
- the computer always plays white and the human cannot take a move back: goban's menu picks who plays - two
  people, a person and the computer (either colour), or the computer on both sides - and Undo goes back to before the
  person's last move.

**Who plays (D12).** The main menu opens with the game's three kinds, a radio button each, at its top:

    Two players                 a person on each side, as goban has played so far
    Against the computer        a person and the computer; under it, the person's colour - black or white
    Computer against computer   the computer on both sides, to watch

The computer plays Atari Go only - its playouts end at a capture - so with either of the last two, the menu's Atari Go
switch is on and locked, saying why, and the victory window offers Continue Playing (which turns the game into plain
Go) only in a two-player game.

While the computer is to move, the board takes no stone and shows no ghost, and a word in the status line says it is
thinking; its stone lands with the same sound and flights as a person's. Against the computer, Undo goes back to just
before the person's last move: two moves when the computer has replied, one when it is still thinking - its job
cancelled - and nothing at all when the person has not moved yet (the computer playing black has made the only move).
So Undo always leaves the person to play. Computer against computer, Undo is off - the same position would only give
the same move again - and the pause window stops the game; each move takes at least a second, so a game can be watched
on a desktop that searches faster than the phone.

The debug panel gains the search's numbers - the iterations run, the last move's time, the nodes taken up from the
last tree, the five most visited moves with their win rates - and a switch that writes each point's visit count on
the board, so the search's attention can be seen growing.

**Placement.** A new section of `goban.zig`, "The opponent", after the diagrams and before the layout: it is
engine-free like sections 1-6 and is tested like them - the kernel is an ordinary function, so its tests call it
directly, with no worker; the sections after it are renumbered. The tutorial gains a
chapter with diagrams of the four steps, a worked UCB1 example and one playout drawn move by move.

---

## 9. Stages

Each stage leaves something runnable, and its new code fits one reply (~150 lines, claude.md's "show the code" rule).
Claude writes, runs zimrlint (the `zimr_lint_rules` set, a fresh `--cache-dir`) and `zig fmt --check`; Simon builds
and runs, and sends screenshots.

| stage | what | done when |
|---|---|---|
| S1 | `goban.zig` header, table of contents, section 1; `Position.init` | lint + fmt clean |
| S2 | the forest: `findRoot`, `findRootCompressingPath`, `joinGroups`, `removeCapturedGroup` | lint + fmt clean |
| S3 | `checkMove`, `wouldBeSuicide`, `placeStone` with the ko fix | lint + fmt clean |
| S4 | `Record`, `startGame` (Atari Go cross as setup), undo / redo / `replayTo` | lint + fmt clean |
| S5 | section 5, the judge; section 6, diagrams | lint + fmt clean |
| S6 | section 10, the tests; the `test-goban` step | `zig build test-goban` green; the judge test watched failing on a planted fault; the step's compile time measured |
| S7 | sections 7-8 in part (layout, wood, grid, star points, stones, last move) and 9's skeleton, playing on click; build.zig row | a board on screen at every window size, desktop and phone |
| E2 | zm: `smootherstep` and `DoubleSpring(T)` (8.7) - zimrmath, its tests, the vocabulary index, the linter's keyword, the GPU probe | `zig build test-zimrmath` and `zig build zm-gpu` green; the pinned values watched failing on a planted change |
| S8 | UiHost; Menu and Undo buttons; press - drag - release; the ghost on its spring | a game can be played; clicks on windows do not reach the board |
| S9 | liberties, atari and doomed overlays (G8) | overlays match goforest's screenshots |
| S10 | capture columns, their spring, the flights (G13, G14) | captures fly and stack |
| E1 | engine: `z.requestQuit` (8.6) - contract, Windows, headless, the web's refusal, readme | a test app's Quit closes the Windows build cleanly (no leak report); the web build still compiles |
| S11 | main menu, pause, victory; Escape, H, side button; Atari Go end to end; Quit on native | goforest's full flow; Quit closes the Windows build; the web build has no Quit button |
| S12 | debug panel: inspector, move log, verify toggle, timeline, copy / paste diagram; forest view | every tool of D2 works |
| S13 | manifest card, editor configs, catalog, files-md, `check.script`, gallery shot; the launcher (D8) | `goban-headless` frames read and right; `smoke-test -Dfocus=goban`, `zig build platforms-check` and `zig build check` green; goban in the launcher on desktop and phone, Undo clear of the switch pill |
| S14 | the opponent's section (8.8): the nodes in one array, UCB1, one iteration, light playouts, the most visited move; its tests (a capture in one found, a defence found, visits and wins adding up through the tree, the same seed giving the same move, the root position untouched) | `zig build test-goban` green; each test watched failing on a planted fault |
| S15 | heavy playouts (capture, then rescue, then random) with the switch to light; the tree as bytes and back; the search continued (`continueSearch`); the subtree taken up after two moves; their tests (a search of n iterations the same as n cut into slices; the subtree's visits kept; a tree that does not fit not taken up) | test-goban green |
| S16 | the app: `kernels.zig` and the build row; the main menu's three kinds of game (and the person's colour), Atari Go locked on with a computer; a move as one job on a worker, or frame-sized slices inline; the tree kept between moves; the board closed and a word while the computer thinks; Undo to before the person's last move (the job cancelled if running), off between two computers; a second's pace between two computers; Continue Playing for two players only; headless games against the computer and between two | whole games of each kind, desktop and phone (and in the Claude app's preview, inline), the frame rate held; the budget tuned to about a second on the phone |
| S17 | the debug panel's search numbers (iterations, the last move's time, nodes taken up, the five most visited moves) and visit counts on the board; the tutorial chapter with its diagrams | the tutorial regenerated; the frames read and right |

---

## 10. Open decisions (asked one at a time, in this order)

| | question | recommendation | answer |
|---|---|---|---|
| D1 | Approach: fix bugs in the port, port bugs then fix as lessons, engine only, or add new Go? | fix in the port | **Fix them** (Simon, Oct 18), and a Quit button on native only - the mechanism (8.6) goes on the final list |
| D2 | Debugging tools: judge, forest view, inspector + log, text positions + timeline? | all four | **All four** (Simon, Oct 18) |
| D3 | UI: zimr's ImGui port, hand-drawn, or hybrid? | ImGui | **zimr's ImGui port** (Simon, Oct 18) |
| D4 | Assets: PNG stones + JPEG wood, PNGs as-is, procedural, shrunk? And may the images ship in zimr? | PNG + JPEG, if they may | **All three PNGs as they are** (Simon, Oct 18) - so they may ship |
| D5 | Files: by concept, one file, or engine + app? | by concept | **One file, like goforest** (Simon, Oct 18) |
| D6 | Names and style: the exemplar in section 3 with source names kept, or new names? | the exemplar | **The exemplar's style, fresh names** (Simon, Oct 18) - the names themselves (3.1) go on the final list |
| D7 | Spring + smootherstep: local, or in `zm`? | local, `zm` as a follow-up | **Into zm now** (Simon, Oct 18) - stage E2, section 8.7 |
| D8 | Launcher now or later? | later | **Now, at S13** (Simon, Oct 18) |
| D9 | The search: in `goban.zig` (specialised to Atari Go), or a generic MCTS in zimrnum that games plug into? | in `goban.zig` - one game, plain functions on its own types; a second game that wants it is when a generic one would be designed | **In the example first, into zimr later; and the search runs as a job** (Simon, Oct 18) - 8.8: one job a move on a worker, the tree carried in and out; frame-sized slices where jobs run inline |
| D10 | Playouts: light (uniform random), heavy (capture, rescue, random), or both with a switch? | heavy, with a debug switch to light - the heavy rules are two short functions and play far better per iteration | **Heavy, with the switch** (Simon, Oct 18) |
| D11 | Strength: one fixed budget, levels in the main menu (iterations per move), or a slider? | levels - Easy, Medium, Hard as iteration counts - and the exact count in the debug panel | **One worker, a fixed count of iterations tuned to about a second** (Simon, Oct 18); the count and the time in the debug panel |
| D12 | Which side, and Undo: the computer as white only, or either side; Undo one move or two? | either side, chosen in the menu; Undo takes back the computer's reply and the move before it | **Three kinds of game at the top of the main menu - two players, against the computer, computer against computer; against the computer, Undo goes back to just before the person's move** (Simon, Oct 18) - 8.8 |
| D13 | Between moves: a fresh tree each move, or keep the subtree under the move played? | a fresh tree - simpler, and the budget is small; keeping the subtree is a later improvement | **Keep it** (Simon, Oct 18) - the tree returned by the job, taken up by the next (8.8) |
| D14 | Candidate moves: every legal move, or only those near the stones? | near: within the 5 x 5 square around a stone, every legal move where none is | **Near the stones, eventually** (Simon, Oct 19); the distance's definition open - 8.8 |

Minor defaults, confirmed with the final list rather than asked: gallery stars 3; window 900 x 900 to start; title
"zimr - goban"; 1024 recorded moves, refusing the 1025th with a message; goforest's timings, alphas and colours.
The opponent's (8.8): against the computer, the person chooses black or white, black first; Atari Go locked on with a
computer, and Continue Playing for two players only; computer against computer, Undo off, the pause window stopping
the game, and a move at least a second apart.

### 10.1 The final list - every decision, for Simon's agreement

1. **D1** - every bug of section 2 fixed in the port; the rules and record fixes (G1-G5, G12) each pinned by a test.
   Quit on native: the new `z.requestQuit` (8.6, stage E1) - Windows sets the close button's own flag, headless ends
   the run, the web refuses at compile time, `unwritten.zig` at run time, `template.zig` at compile time; the readme
   updated. Both Quit buttons under `comptime z.host.drives_own_frames`.
2. **D2** - all four tools: the judge, the forest view, the inspector + move log, text positions (the format in
   section 4; a pasted position loads as the record's setup) + the timeline.
3. **D3** - zimr's ImGui port, scaled with `u.scaleToViewport`; board input only when `!u.wantCaptureMouse()`.
4. **D4** - the three PNGs unchanged, renamed `black_stone.png`, `white_stone.png`, `wood.png`.
5. **D5** - one file, `goban.zig`, in ten sections with a table of contents; tests at its end; `zig build test-goban`
   built from the example's own module.
6. **D6** - the exemplar's style; the fresh names of 3.1 (no goforest table or citations in the file: Oct 18).
7. **D7** - `zm.smootherStep` (vector `x`, scalar edges) and `zm.DoubleSpring(T)` in zimrmath (8.7, stage E2), with
   `@exp` in place of `FastNegExp`; `smoothstep` untouched; tests, vocabulary, keyword, GPU probe.
8. **D8** - into the launcher at S13; Quit in the Windows launcher ends the launcher; Undo moves to a corner if the
   switch pill covers it.
9. **Behaviour kept or chosen** (section 2): undo can take back a winning capture (G11); a prisoner column wraps into
   a second column past the board's height (G13); goforest's star-point rule (G20); Atari Go needs a board of 4 or
   more (G3); Escape pauses, H toggles the debug panel, the side button undoes; a panic handler.
10. **The minor defaults** above.

---

## 11. Risks

- **Scope**: ~2300 lines of example and ~150 of engine (E1, E2) over fifteen stages - the largest example port since
  the robot demos. The stages keep each step small and runnable.
- **E2 touches zimrmath and the linter** (D7): a new math keyword reserves `smootherstep` tree-wide (free today), the
  linter is rebuilt with it, and zimrmath's GPU path must accept the vector form - which is what `zm-gpu` checks.
- **One 2300-line file** (D5): the table of contents, the numbered banners and Zed's outline are the navigation;
  `decl-order` keeps the sections in reading order.
- **The test step's cost** (D5): the tests compile with the example's module, so the engine module must be built
  for the host first. Lazy analysis should keep the test binary small; S6 measures it rather than assuming.
- **A judge written by the same hand as the engine** could share its mistakes. It is deliberately the dumbest
  possible algorithm (flood fill from stones alone, nothing shared with the forest), and it is proven able to fail.
- **Page weight** (D4, D8): the three PNGs add ~1.3 MB to goban's page and ~1.75 MB to single-file HTML (base64) -
  to goban's and, through D8, to the launcher's (13.6 MB today). The Android viewer's old 2 MB cap is gone
  (claude.md, Sep 27), so this is weight, not breakage.
- **The UI on a phone**: menus scaled by `scaleToViewport`, checked on device at S8 and S11.
- **Windows resize freezing** (G15) remains until the engine's platforms_plan fix; it is not this example's to solve.
- **E1 touches the platform contract**: `requirePlatform` checks that every platform module declares every request,
  so all five - web, windows, headless, unwritten, template - change together, or the build fails. Small, but it is
  engine code and gets reviewed as such.

---

## Appendix A - gogus, the first version

`C:/dev/tests202601/gogus/src/main.cpp` (265 lines, French names) - what goforest already fixed:

| gogus | goforest |
|---|---|
| only single stones captured (`kill` counts enemy neighbours per stone) | groups and liberties, in a forest |
| captures depend on scan order, so a capture into the top-left corner removes the capturer | the mover's captures first, then the suicide check |
| suicide placed then removed, a free pass | suicide refused (`IsMoveSuicide`) |
| white moved first | black first |
| no ko | simple ko (too broad: G1) |
| integer division toward zero widened the top row and left column to 99 px | negative offsets refused before dividing |
| grid lines over the stones; a stray ring at (150, 150) before the first move | lines first; no ring until a move |
| fixed pixel layout in a resizable window | layout from the window every frame |

A tutorial built on the port could start from this table: the same program, three versions.

---

- **The opponent's speed** (8.8): the iterations a frame affords on a phone's wasm are not known; each iteration
  copies a 36 KB position. If 9 x 9 is too slow at the levels chosen, a smaller position copy (the board's own size)
  or keeping the subtree between moves (D13) are the levers - measured when the opponent plays, not guessed now.
- **Inline jobs**: where no worker can be made (the Claude app's preview), each slice holds up its frame, and carries
  the tree in and out - two copies of a megabyte or two a frame by the end of a move. The slice size is a guess until
  measured on the phone.
- **The tree's size**: one node an iteration; the registry's output bound (`Options.max_output`) must hold the
  largest tree a move makes, plus the subtree taken up. The bound is set from the budget, with room.
- **19 x 19 Atari Go**: playouts there are long and the tree wide; the computer will be weak. The menu may offer the
  computer only up to 13 x 13 - decided with D11.

## 12. Journal

- Oct 18: first draft planned a port of gogus (`C:/dev/tests202601/gogus`); Simon pointed to the real program,
  goforest. Studied in full (main.cpp, both headers, the three textures, its CLAUDE.md); plan rewritten. D1 asked.
- Oct 18: **D1 decided - fix the bugs in the port.** Simon also asked for Quit on native: zimr has no app-to-platform
  quit, so section 8.6 plans one (`z.requestQuit`, the web refusing at compile time as it does the window requests),
  as stage E1; the buttons show under `comptime z.host.drives_own_frames`. D2 asked.
- Oct 18: **D2 decided - all four tools.** The diagram format is now specified (section 4), and the record's setup
  grows to a whole board so a pasted position replays like the Atari Go cross. D3 asked.
- Oct 18: **D3 decided - zimr's ImGui port** (`z.UiHost`). D4 asked.
- Oct 18: **D4 decided - the three PNGs as they are** (not the recommended JPEG wood), renamed `black_stone.png`,
  `white_stone.png`, `wood.png`. D5 asked.
- Oct 18: **D5 decided - one file, like goforest** (not the recommended file per concept). Section 8.1 is now the
  file's eleven sections; the tests sit at its end and `test-goban` builds them from the example's own module. D6
  asked.
- Oct 18: **D6 decided - the exemplar's style, with fresh names** (not the recommended source names). Section 3.1
  proposes every name, goforest -> goban, using Go's words (point, prisoners, ko point); the exemplar and the
  sketches use them. D7 asked.
- Oct 18: **D7 decided - into zm now** (not the recommended local copy). Section 8.7 designs `zm.smootherStep`
  (vector `x`, scalar edges) and `zm.DoubleSpring(T)`, with their tests, the vocabulary, the keyword and the GPU
  probe; stage E2. goban.zig loses its Motion section (ten sections now). D8 asked.
- Oct 18: **D8 decided - into the launcher now, at S13** (not the recommended later). E1 refuses `requestQuit` at
  run time in `unwritten.zig` so `platforms-check` keeps compiling; Quit in the Windows launcher ends the launcher;
  the switch pill and goban's Undo button are checked together at S13. All eight decided; the full list goes back to
  Simon for agreement.
- Oct 18: **Simon agreed with the whole final list - the plan is final.** Asked next: prepare the example folder with
  the C++ reference, and not implement yet.
- Oct 18: **folder prepared.** `examples/goban/goforest/` holds main.cpp, utils.h, math_utils.h, CMakeLists.txt and
  the notes (renamed `goforest_notes.md`), with a README; the three textures sit in `examples/goban/` under their D4
  names. All eight copies checked byte-identical (`cmp`); git sees nine untracked files, none ignored; no `.zig`
  file yet, so no build or lint change. Not committed. Next: S1, when Simon says go.
- Oct 18: **S1 done.** `goban.zig`: the `//!` lesson (the game, the forest drawn, the sections, goforest -> goban
  names), section 1 (`Stone`, `Point`, `PointSet`, `Neighbors`, `pointCount`, `isOnBoard`, `pointAt`, `rowOf`,
  `colOf`, `neighborsOf`) and `Position` with `init` at the top of section 2. One change from 3.1: the index helpers
  are free functions taking `board_size` (`neighborsOf(position.board_size, point)`), not `Position` methods - they
  need only the size, and section 1 comes before `Position`. Clean under all 60 `zimr_lint_rules` (zimrlint run
  directly, a planted braceless `if` watched failing); compiled and probed by a throwaway test outside the tree.
  **Incremental compilation measured** (toolchain 0.18.0-dev.253, host x86_64, Debug, a test of goban.zig + zimrmath):
  cold 11 s; a one-line edit rebuilt by plain `zig test` 2.4 s; the same edit under `zig build test --watch
  -fincremental` 11-18 ms per update, compile errors reported on the update that makes them, the binary re-run. The
  probe build is a 15-line build.zig outside the tree; S6 decides how `test-goban` offers it.
- Oct 18: **the file's compile-time parameters go in namespaces** (Simon): `board_limits.min_size`, `.max_size`,
  `.max_points`; the record's move cap will be `record_limits.max_moves` (8.2 updated). Types (`Point`, `PointSet`,
  `Stone`) stay at the root. Lint clean, the probe passes.
- Oct 18: **S2 done.** Section 2: `isRoot`, `parentOf` (asserts every stone has a parent), `findRoot` (read-only,
  iterative, asserts on a loop of parents), `findRootCompressingPath` (findRoot, then the path walked again and
  repointed - the forest goforest's recursion leaves), `joinGroups -> bool` (false when both roots are one group),
  `removeCapturedGroup -> PointSet` (empties the group, then gives each emptied point to the capturer's groups beside
  it). New invariant, stated in the section's lesson: away from roots, `group_liberties` and `group_stones` are empty
  (goforest cleared them too) - the judge (S5) can check it. Lint clean; a probe outside the tree (hand-built chain,
  join, a lone stone captured by four) passed, 1.2 s per edit through its build.zig.
- Oct 18: **S3 done.** Section 3: the lesson (the six steps, captures before suicide, ko drawn), `Legality` (without
  the sketch's `off_board`: `checkMove` takes a `Point`, and turning a pointer into a point is the layout's question),
  `MoveReport` (`groups_joined`, as joinGroups counts them), `wouldBeSuicide` (the exemplar), `checkMove` (game over,
  occupied, ko, suicide, in that order) and `placeStone` (the six steps; ko set only when one stone was captured by a
  stone standing alone with one liberty - G1). Lint clean. Probe outside the tree: simple ko refused, the G1 snapback
  legal and capturing two, suicide refused, an Atari Go win at goal 1. With goforest's rule planted (`captured_one_stone`
  alone) the snapback probe failed, and passed again once restored.
- Oct 18: **the goban tutorial** (Simon): `src/notes/tutorials/goban_tutorial.html`, in the sound / zimrnum
  tutorials' form - the game, points, the forest, the rules, a generated reference; all 23 declarations in folds
  filled by `zig build doc-folds` (the page is in its list and in the published pages; readme.html's tutorial index
  has a new "Games" group). 13 diagrams drawn as boards (wood, shaded stones, liberty dots, root squares, parent
  arrows), each checked as a rendered image and the page checked at phone width. The diagrams come from a scratch
  generator outside the tree (`/tmp/gb/figs.py`, `make_figs.py`); the page holds their SVG. **Kept in sync from
  here: each stage adds its section to the tutorial in the same turn.** The comments the folds quote lost their plan
  citations, and `checkMove`'s doc no longer names unbuilt callers.
- Oct 18: **goforest out of the code and the tutorial** (Simon: it is just a previous version). The header's name
  table and every `goforest's X` / `main.cpp:NNN` citation are gone from `goban.zig`; where a citation carried a
  reason, the reason stays in the code's own terms (section 2: why queries do not compress; section 3: a ko rule
  that forbade every one-stone recapture would refuse snapbacks). The tutorial's opening no longer names it.
- Oct 18: **S4 done.** Section 4: the lesson (the record, undo and redo as replays with the truncation drawn, the
  Atari Go square drawn, why 3 x 3 cannot hold it), `record_limits.max_moves`, `atari_go.min_board_size` (4, G3),
  `SetupStone`, `NewGameSettings` (`capture_goal: ?u8`, null for plain Go - one field instead of a bool and a goal),
  `Record`, `Game`, `putSetupStone` (placeStone, then last move and ko cleared; asserts no capture), `replayTo`,
  `startGame` (the square as setup: G2, G12), `recordIsFull` (counts the moves shown, since a new move replaces the
  undone ones), `playMove`, `undo`, `redo`. Lint clean. Probe outside the tree: the square after start, undo stops
  at it, one move undone and redone keeps it, an Atari Go win cleared by undo and set again by redo (G4), a move
  after two undos truncates the record, and a replay equal to the live position field by field. A byte-for-byte
  comparison of the two positions DIFFERED: a null `?Point`'s payload byte is undefined, so the judge (S5) and the
  tests must compare positions by value, never with `mem.eql` over bytes. The tutorial's section 5 (the record, with
  three new diagrams) landed the same turn.
- Oct 18: **`Neighbors` removed** (Simon: a hand-made bounded array is not Zig-idiomatic). `neighborsOf` now takes
  the caller's `out_buffer: *[board_limits.max_neighbors]Point` (new limit, 4), fills it through an `ArrayList`
  made with `initBuffer` - `appendAssumeCapacity`, not `appendBounded`, because a fifth neighbour cannot happen and
  an error for it would force `try` or `catch unreachable` on every caller - and returns the filled slice. The four
  callers (removeCapturedGroup, wouldBeSuicide, placeStone's three loops) declare the buffer beside the call. Lint
  clean; probe: neighbours of a middle point, an edge, two corners in up/down/left/right order, against indices worked
  by hand, and the S4 probe (which exercises every caller) still green. Tutorial 2.2 rewritten, with a diagram of
  the buffer and its slice.
- Oct 18: **S5, first half: section 5, "Checking the forest"** (the plan's "judge"). `FloodFilledGroup`,
  `floodFillGroup` (an explicit stack in a board-sized buffer through `ArrayList.initBuffer`, a stone marked when
  pushed so each is pushed once), `DisagreementKind` (eight kinds), `Disagreement` (point, row, col, both counts, a
  `format` method for `{f}`), `rootOrLoop` (reports a loop where findRoot asserts), `findDisagreement` (pass 1: each
  point's own entries; passes 2-3: each group once - one root for all its stones, and that root's sets equal the flood
  fill's, by value). Lint clean. Probe: 374 random legal moves over 5, 9 and 13 with 113 stones captured, checked
  after every move; one liberty removed from a root on purpose and the checker named that root
  (`point (3,4): forest has 0 liberties, flood fill finds 1`). **For S6's random games:** picking random points on a
  crowded board stalls (4000 tries gave only 374 moves); the test should draw from the legal moves, or restart a game
  after a run of illegal picks. Tutorial section 6 (two diagrams: a flood fill's visit order, a planted missing
  liberty) the same turn. Next: section 6 of the file, diagrams (text <-> position).
- Oct 18: **S5 done: section 6, "Diagrams".** `diagramSymbol` / `stoneOfSymbol`, `writeDiagram` (to an
  `Io.Writer`: the turn line, then rows with single spaces), `DiagramSetup`, `DiagramProblem` (a tagged union - each
  refusal carries exactly what locates it: line, column, character, or board point - with a `format` method),
  `DiagramReading` (`setup` or `problem`), `readDiagram` (rows collected at the widest board's width until the size is
  known, then the shape, then a flood fill of every group for a liberty), `startGameFromDiagram` (the stones as the
  record's setup, in reading order; plain Go). `floodFillGroup` now takes `(board_size, stones, start)` instead of a
  Position: its signature shows it cannot read the forest, and a diagram being read has stones but no forest. The
  std vocabulary used (`indexOf`, `splitScalar`, `startsWith`, `trim`) is bound once at the top (no-qualified-std
  caught the first draft). Lint clean. Probe: the G1 snapback diagram written back byte for byte, the checker silent
  on it, undo stopping at it, the snapback played from it (one taken, two retaken); spaces optional and black by
  default; seven refusals each with its reason (`no_rows` .. `row_too_long`, `too_many_rows` not exercised). Tutorial
  section 7 (two diagrams: text and board read/written, a refused diagram) the same turn.
- Oct 18: **S6 done.** The tests close `goban.zig` (a `// ===== Tests =====` section, no number: the app's sections
  7-9 go above it). 15 tests, written as diagrams, the forest checked after every move: neighbours; a lone stone
  captured in the middle, on the edge and in the corner; a group of three and its liberties handed back; suicide and
  a suicide-looking capture; ko refused then allowed after a move elsewhere and an answer; snapback (G1); the Atari
  Go square through undo, redo and a restart, never the last move (G2, G12); 3 x 3 refused and the square shown to
  capture its own corner there (G3); a win cleared by undo and set by redo (G4); undo truncation; random games on 5,
  9, 13 and 19 drawing from the legal moves, read-only queries of every point between moves leaving the position
  equal (G5); undo to every move and redo to the end against the positions recorded live; planted faults (a missing
  liberty, named with both counts and the exact sentence; a loop of parents); a diagram written back exactly; eight
  refusals, `too_many_rows` included. New in section 4: `allowsBoardSize(capture_goal, board_size)`, the one
  definition of which sizes a game may use - startGame asserts it, the menu will ask it.
  **`zig build test-goban`**: a Debug test of the example's own file for the host, importing only `zm`: 15 pass in
  ~0.33 s after a 1 s compile, 7 s with the build's configure. **Watched failing:** the over-broad ko rule planted -
  4 tests crash; the liberty hand-back in removeCapturedGroup removed - 8 fail, the random games among them.
  **Incremental, through the real build.zig:** `zig build test-goban --watch -fincremental` gives its first result in
  4 s, then every save recompiles in 23-31 ms and reruns the tests (~0.4 s): about half a second from save to verdict
  (claude.md's test list has the line). It stays this cheap while the tests reach only sections 1-6; S7 will import
  the engine, and the step must then still build without it - the next measurement.
- Oct 18: **S7 done: the board on screen.** Sections 7-9 above the tests. 7, Layout: `BoardStyle` (every size in
  spacings, every colour - the defaults the app keeps in its state; nothing at file scope), `BoardLayout.fromWindow`
  (shorter side / (board_size - 1 + 2 * margin), floored to whole pixels; grid centred), `pointPosition`,
  `pointUnderPointer` (floor(offset + 0.5), so just outside the grid is off the board). 8, Drawing: `starPoints`
  (into a buffer of `board_limits.max_star_points`; on 5 x 5 the corners and the centre coincide and are listed once -
  seen while checking the first frame, pinned by a new test), `drawWood` (cover, proportions kept, centred),
  `drawStone`, `Textures`, `drawBoard` (lines, star points, stones at 1.1 spacings, last-move ring). 9, The app:
  `State`, the three PNGs and the font embedded, `uploadPng` (decode, upload, free), `init` (13 x 13 plain Go to
  start), `deinit`, `update` (lay out; a press on a legal point with room in the record plays it; draw; a caption),
  `panic` (std's under `builtin.is_test`, so the test build never needs the engine), `app` (900 x 900, responsive).
  **The file's engine imports cost the test build nothing**: an unreferenced `@import("zimr")` is never resolved, and
  `test-goban` (16 tests now) still compiles in ~1 s with only `zm`. build.zig: the `wgpu_apps` row. **First web
  build** `zig build goban -Dplatform=web -Dmode=release`: 202 s cold, 17 s after an edit; single-file page 5.9 MB.
  **First headless run** (`check.script`, lavapipe installed - claude.md's sandbox quirks): 65 s to build, 12 frames,
  0 validation errors; the frames show the board at exactly the layout's numbers (origin 114 px, spacing 56 px), four
  stones played by clicking, the last-move ring on white, the caption. Tutorial section 8 (three diagrams: the layout,
  a pointer snapping, star points on three sizes) the same turn.
- Oct 18: **S7 seen on device** (Simon's phone, Claude's viewer): the board right. The viewer's sound-worklet warning
  on a page with no sound led to an engine change, journaled in `platforms_plan.md` (Oct 18): the renderer is exported
  only by apps that call `z.audio_device.init`, and the script-processor fallback is a console notice, not an on-page
  warning. goban's page is 4.8 MB now. When goban gets sound, the viewer still plays it (script processor) and stays
  quiet.
- Oct 18: **E2 done: `zm.smootherStep` and `zm.DoubleSpring(T)`** in zimrmath, after `smoothstep`. Two private
  helpers first: `requireF32Lanes` (requireFloatLike, then f32 lanes only - both mix their argument with plain f32
  parameters) and `broadcast` (a run-time scalar to every lane; `splatTo` is the compile-time one). `smootherstep(e0,
  e1, x)`: clamp01 then the quintic, branch-free. `DoubleSpring(T)`: `atRest`, `step(goal, blend_seconds, dt)` - each
  spring's half-life a quarter of the blend, damping 2 ln2 / (half-life + 1e-5 s), `@exp` for the decay (not the
  approximation, as decided), the hidden point stepped first; a step of no time returns at once (the closed form's
  `(value - goal) + goal` moved the value by one unit in the last place - the dt-0 check caught it). Tests: ends,
  middle, 0.103515625 at a quarter (and on edges 2..6), symmetry, flat ends by finite differences against
  smoothstep's, lanes equal to scalar calls; the spring's first step against its closed form worked by hand
  ((1 - e(1 + y dt))^2), monotone with no overshoot over two blends and within 2 % of the goal after them, Vec2 equal to
  two f32 springs exactly, dt 0 a no-op. **Watched failing:** 6 -> 6.01 in the quintic, and a damping 5 % stiff.
  Around it: the vocabulary index in zimrmath's header, `features_test.zig`'s @hasDecl list (checked alone against
  zm), zimrlint's math keyword (so it is bound once and used bare), the GPU probe (`zm-gpu` green: it lowers to
  SPIR-V on a Vec), `math.md`. `test-zimrmath` + `lint-test`: 308 passed.
- Oct 18: **the easing curves renamed camelCase, with [0, 1] forms** (Simon): `zm.smoothStep(e0, e1, x)`,
  `zm.smoothStep01(t)`, `zm.smootherStep(e0, e1, x)`, `zm.smootherStep01(t)` - all f32 or vectors of f32, a bare
  literal computed as f32 (`F32Lanes`), the edged forms written as the [0, 1] ones of `(x - e0) / (e1 - e0)`, the old
  scalar-only `smoothstep` now vector-generic. `smoothstep` / `smootherstep` remain as private empty stubs naming the
  new spellings (zimr's pattern for `mix`, `saturate`, `sin`), pinned by reference and by features_test's not-pub
  list. Call sites renamed (8 shader and example files, zimrnum's reference, shader_codegen's comment); prose that
  names the curve stays, and spv2wgsl's `"smoothstep"` is WGSL's builtin. The linter's math keywords carry all four
  (it then caught qualified calls in the GPU probe, now bound bare). Checked: zimrmath + lint-test 308 passed; zm-gpu
  lowers all four on a Vec, edges in both orders; the four examples whose shaders call them built for the web (112
  WGSL shaders regenerated); shaders_vertex_displacement ran headless on lavapipe, its height ramp drawn, 0
  validation errors.
- Oct 18: **S8 done.** BoardStyle gains the ghost's blend (0.08 s) and alphas (220 held, 180 black, 80 white);
  `drawStone` takes a tint. Section 8 gains `Ghost` (a `DoubleSpring(Vec2)` and `has_target`; `.hidden`),
  `updateGhost` (snaps onto its first target, then springs), `drawGhost`. New section 9, Input - engine-free:
  `BoardPointer` (hovered, pressed, released; hovered null off the board and over a window), `isPlayable` (legal and
  room in the record), `applyPointer` (press over a playable point holds; release while holding plays where the
  pointer is, if playable; a one-frame tap does both). Section 10, The app: `ControlsStyle` (font from
  `scaleToViewport(width, 20)`; Menu 4 x 2 fonts top-right, Undo 4.8 x 2 bottom-centre, 0.4-font gap; pause window 12
  fonts wide), `PauseChoice`, `State` (+ controls, stone_held, ghost, pause_open, ui_host), `fixedButton` (one button
  in a title-less, background-less window placed every frame), `submitGameButtons`, `submitPauseWindow` (Return to
  Game, Restart - S9 adds the rest), `update` in the order of 8.5: windows submitted, actions, board input only when
  `!pause_open and !wantCaptureMouse()` (G6, G7), ghost, draw, interface last. Two tests (18 now): press, drag,
  release plays where let go, a tap plays; nothing from or onto a stone, nothing off the board / over a window.
  **Headless** (`check.script` rewritten, positions worked from the layout and the font): hover ghost; held ghost
  dark after the drag; black played at the release point, not the press point; Undo removes white's stone and plays
  nothing under it; Menu opens the pause window; Restart empties the board with nothing played under the button; 22
  frames, 0 validation errors. Web page rebuilt (18 s). Tutorial: 8.4 The ghost (the spring's curve against one
  spring and smootherstep, `zm.DoubleSpring` folded from zimrmath), 9 Playing a stone, 10 The app (the frame's order,
  the buttons, the program); diagrams: press-drag-release, the spring curves, the frame's order.
- Oct 18: **a finger aims above itself** (Simon, from the phone: a finger hides the point it touches). Section 9:
  `pointerHovered` (moved with no button down, the release frame excluded) and `aimedPosition` (a finger aims
  `finger_lift_px` = 64 px - about 10 mm of CSS pixels - above itself; within that of the window's bottom the lift
  shrinks to the distance left, y - min(lift, H - y), continuous, so the bottom rows stay in reach in landscape). The
  kind of pointer is learnt in the app: the engine reports finger and mouse alike (the web bridge listens to Pointer
  Events only and does not keep `pointerType`), so a pointer never seen hovering is a finger, and its first hover makes
  it a mouse (sticky; a touch laptop used with its mouse stays a mouse). **Engine follow-up, noted for later:** a
  pointer kind (mouse / touch / pen) carried by every platform, from `pointerType` on the web, would replace the guess.
  **Buttons fixed** (seen on the phone): the label overflowed because the window had the button's size and the button
  got what the padding left (1 font for a 1.6-font label); now the window is the button plus padding, placed so the
  button lands where meant, and a transparent `border` pushed around it removes the outline every window draws.
  zimr's sized button puts its label at the top-left plus padding where Dear ImGui centres it (`ButtonTextAlign`
  0.5, 0.5) - an engine question for Simon. Tests 20: hover detection; the aim, mid-screen, at the knee, below it
  and at the edge. Headless: `check_finger.script` - a finger at row 7 holds the ghost on row 6, slides and lifts, and
  black is played a row above; `check.script` (a mouse) unchanged in behaviour; 0 validation errors. Tutorial 9.1 with
  a diagram (the ghost over a finger; the aim against height).
- Oct 18: **zimr's buttons centre their label, as Dear ImGui's do** (Simon: "match imgui, adjust everything").
  `ui.Style.button_text_align` (Dear ImGui's `ButtonTextAlign`, default 0.5, 0.5; persisted with a default, so old
  saves load centred); `alignedTextPosition` (free space times the alignment, never before the start, as
  `RenderTextClipped`); `drawButtonLabel` (clips to the frame only when the label does not fit - Dear ImGui's
  `need_clipping` - so fitting labels keep the batches whole); `buttonImpl` draws through it; `smallButton` unchanged
  (it is exactly its label's size). Adjusting: 30 sized buttons in 13 examples and plot3d - none worked around the old
  top-left label (the space-padded labels are auto-sized, unchanged); they now centre as Dear ImGui would. Three
  tests ("button label: ...") in ui.zig: placement arithmetic; a sized button centred, and (0, 0) giving the old
  placement exactly; clipped only when it does not fit (the test context has no font metrics - text measures 0 wide -
  so the overflow is made vertical). Seen: goban's Menu, Undo and pause buttons, ui_pomodoro_phone's Start and Reset,
  centred, 0 validation errors. **Found on the way:** the main test root (`src/tests.zig`) did not compile on Linux
  since the gallery shots - `isStartScreenSkipped` reads `ZIMR_SKIP_START_SCREEN` through `std.c.getenv`, and the
  host test build links no libc (Windows reads it through win32, so the suite passed there). `native_os.
  environmentVariable` now returns null in a build without libc; every native program links it. With that,
  `zig build test -Dfocus=goban "-Dtest-filter=button label"` runs: 11 of 11.
- Oct 18: **S9 done: the overlays.** Section 3 gains `groupsCapturedBy(position, point, out_buffer)` - the roots of
  the enemy groups beside the point whose one liberty is the point, each listed once (G8's dedupe), nothing for an
  illegal move (G8's ko case). Section 8: `drawBoard` split into `drawGrid` and `drawStones` (rings go between them);
  `OverlayOptions` (three toggles, in the pause window as checkboxes); `HoverClock` (restarts on a new point; `alpha`
  = fade-in clamp01(3 t) times a pulse 0.5 + 0.5 sin(4 t) between two opacities); `drawAtariRings` (every root with
  one liberty, a thin ring just outside each stone), `drawDoomedRings` (wider, darker, pulsing, outside the atari
  ring), `drawLibertyMarks` (gold, pulsing, over the stones). Hidden while paused or after a win. Departure: the atari
  ring is placed from the stone's edge, not at half a spacing + 3 px as before - the stones are 1.1 spacings wide, so
  that ring sat under the stone's rim on any board larger than a phone's (seen headless); and the doomed ring was made
  wider and moved outside the atari ring, which it otherwise matched. No screenshots of the original exist in its
  folder, so the "done" column's comparison is to its code. Tests 22: groupsCapturedBy (a group touching twice, the ko
  point), the hover clock. Headless `check_overlays.script` (a hover first, so the pointer is a mouse): doomed and
  atari rings on white's stone, the liberties of black's; 0 validation errors. Tutorial 8.5 with a diagram.
- Oct 18: **S10 done: the capture columns and the flights.** Section 7 gains `CaptureColumns` (left = black's
  prisoners, right = white's, level with the top line; `fromLayout`, `slotPosition` - down a column, then the next
  one further out: G13) and `fittedSlotSpacing` (touching while they fit, then height / (n - 1), never below 0.6
  radii). Section 8 gains `FlightPlacement`, `Flight` (point and slot remembered, not pixels; `placement` places both
  from this frame's board and columns, eased by smootherStep01 - so a flight lands where its slot IS: G14),
  `Flights` (a fixed array of `max_points`; when a new capture does not fit beside the ones in the air, those land),
  `prisonersOf`, `landedPrisoners`, `shownSlots` (Atari Go's goal as empty circles), `drawColumn`, `drawFlights`. The
  frame launches a capture's flights (slot = prisoners before + n, delay n x 0.05 s), advances them, puts the slot
  spacing on a 0.3 s spring toward what the fuller side needs (its flights' slots included), and clears the flights
  on undo and restart (G10). **A bug the tutorial's diagram showed:** with the spacing fitted exactly, `floor(height /
  spacing)` landed a hair short, and the last stone of a full column started a second one; a 1e-3 tolerance, and a
  test (40 stones in one column) watched failing without it (39). Tests 25. Headless `check_captures.script`: the
  stone halfway to black's column, then in its first slot; 0 validation errors. Tutorial 8.6 with two diagrams (a
  column at three sizes; a flight at equal time steps).
- Oct 18: **a stone aimed at a taken point drops beside it; no ghost after a button** (Simon, from the phone).
  Section 9: `dropPoint(game, layout, aimed_px, reach_spacings)` - the intersection under the pointer if playable,
  else the playable point nearest the pointer within `drop_reach_spacings` (1.0, a cell) of it, measured from the
  pointer, ties to the first in reading order; "free" read as playable (a legal move), so a ko point or a suicide is
  skipped like a stone. The ghost, press, release and the doomed overlay use the drop point; the liberties overlay
  keeps the point under the pointer. `pointerIsPresent`: a finger only while it touches (and on its release frame),
  so the stale last-touch position no longer hovers the board - after Menu, Return to Game left a ghost where the
  finger had lifted. Tests 27 (the drop point: playable itself, right of centre, above, all four neighbours taken ->
  out of reach at 1.0 and found at 1.5, off the board; presence). Headless, `check_finger.script` extended: a touch
  aimed at black's stone holds white's ghost beside it and plays there; Menu then Return to Game leave no ghost; 0
  validation errors. Tutorial 9.1 (presence) and 9.2 (the drop point, with a diagram - its first draft said all four
  neighbours were in reach; with the pointer off-centre only two are, and it says so now).
- Oct 18: **E1 done: `z.requestQuit`.** contract.zig: `requestQuit: fn () void` beside the window requests, with
  what it means (the frame finished, teardown, exit - one way out, whichever asked; nothing for a program called by
  another). Windows: `native_loop.requestQuit` sets `window.close_requested`, the flag `WM_CLOSE` sets, so the next
  `serviceWindow` answers `.closed` and the run's own teardown follows. Headless: `requestQuit` / `isQuitRequested`,
  and the headless frame driver returns false after the frame that asked, which stops the session as `.quit` does.
  Web: `@compileError("web platform: a page cannot close its browser's tab")`. unwritten: `refuse` at run time.
  template: not written. `wgpu_app.requestQuit` (its doc says to call it inside `if (comptime
  z.host.drives_own_frames)`) and `z.requestQuit`. readme's application model has a paragraph. The first caller is
  goban's pause window: **Quit to Desktop** under `comptime z.host.drives_own_frames`, PauseChoice `.quit_to_desktop`.
  Checked: headless `check_quit.script` - Menu, Quit to Desktop, and the 30 frames and the capture after it never run
  (9 frames run, 10 drawn - the quitting frame is drawn and ends the run), exit 0, validation 0 errors after
  teardown; the web page builds (no button, no call); goban.exe cross-compiles for Windows (79 s) - not run here, so
  the "no leak report on Windows" check is Simon's. `platforms-check` not run (the unwritten change is one refusal).
  **Found on the way:** the pause window had been 200 px tall - its first size - in every capture, because a capture
  two frames after Menu lands on the window's first frame; the S9 checkboxes looked missing for that reason only. Now
  `always_auto_resize`, the labels shortened to fit its 12 fonts, and the script waits the frame.
- Oct 18: **the board's edge clamps, and the ghost shows the liberties around it** (Simon). Section 7:
  `BoardLayout.clampedOntoBoard(pointer, reach)` - the pointer itself over the grid, the nearest place on the grid's
  outline when within reach of it (off a corner, the corner), null farther; `dropPoint` searches from the clamped
  position, so a stone let go just off the board lands on its edge, and one carried more than a cell off is put back
  (the cancel gesture stays). Section 3: `groupsTouching(position, point, out)` - the roots of both players' groups
  beside a point, each once. Section 8: `libertyOverlayGroups(position, ghost_point, pointed_point, out)` - the groups
  touching the ghost and the group of a stone under the pointer; `drawLibertyMarks` takes that list and colours each
  group's rings by whose it is: gold for the mover (as before), pale blue for the opponent
  (`liberty_mark_color_opponent`) - a choice of mine, offered to Simon. The hover clock restarts on the ghost's point,
  or on the pointed stone when there is no ghost. Tests 29 (clamp: just off an edge, too far, off a corner, a taken
  edge point sends the stone along the edge; the overlay's groups). Headless `check_ghost_liberties.script`: the
  ghost between a black and a white stone with gold and blue rings; a tap 40 px off the left edge plays on (2, 0); 0
  validation errors. Tutorial 8.5 (text, the diagram's third panel) and 9.2 (the edge, `clampedOntoBoard`).
- Oct 18: **the ghost's liberties are those after its move, with counts** (Simon). Section 3:
  `positionAfterMove(position, point, after)` - the position copied into caller storage (a Position is about 36 KB:
  kept in the state as `ghost_position`, not on a frame's stack) and the move placed on it. The liberty overlay reads
  that position when there is a ghost: `libertyOverlayGroups` unchanged in shape - the groups touching the ghost's
  point there are the mover's group the stone joins and the opponent's beside it, a lone stone touching none of its
  own, a captured group gone - except that the pointed point is skipped when it is the ghost's own point (in the
  position after, the ghost stands there; the first frames showed a lone ghost's 4 liberties and a "4" for that
  reason - the test now covers it, watched failing without the check). `drawLibertyMarks` colours by the mover passed
  in (the copy's player to move has flipped). New `drawLibertyCounts`: each group's count on its root stone, centred
  (`z.measureText`), light on black and dark on white, fading in with the overlays, drawn after the ghost (a joined
  group's root may be the ghost's point). Tests 29. Headless: the ghost between black and white - the pair's 5
  liberties and "5", white's 3 of 4 and "3"; a lone ghost shows nothing; 0 validation errors. Tutorial 8.5 rewritten
  for it, the diagram's third panel with the counts.
- Oct 18: **the ghost holds still, and a finger's stone goes where the ghost was** (Simon: releasing a finger
  sometimes moved the stone; ghost noise). Section 9: `steadyDropPoint(..., previous, hysteresis_spacings)` keeps
  the ghost's last point while it is playable and within reach and no point is nearer the pointer by 0.15 spacings
  (`ghost_hysteresis_spacings`); `Ghost.point` remembers it. `StoneHold` replaces `stone_held: bool`: `pickUp`,
  `follow(frame_seconds, point)` each frame held, `pointShownAgo(seconds)` (the newest point shown at least that long
  ago, or the press's point for a shorter hold), `putDown`; a ring of 32 `ShownPoint`s (more than 0.1 s up to 240
  frames per second). `BoardPointer` gains `release_delay_seconds` (0.1 for a finger, `finger_release_delay_seconds`;
  0 for a mouse, whose release does not move it) and `frame_seconds`; `applyPointer` plays the release on
  `pointShownAgo(delay)`. Tests 31 (the finger's roll at the lift played on the earlier point, a mouse where the ghost
  is, a finger's quick tap where it pressed; the hysteresis band); each new test watched failing on its planted fault.
  `check_finger.script`'s slide now rests 10 frames before lifting (a 3-frame slide-and-lift now, correctly, plays the
  point before the slide). Headless: 0 validation errors. Tutorial 9.3 with a diagram (the band; the release
  timeline). Dropped on the way and restored: a block replacement deleted `dropPoint` along with what it replaced;
  `test-goban` would not have compiled, so it was caught before any run.
- Oct 18: **S11 done: the menus.** Section 4: `continueAsPlainGo(game)` (the record's goal dropped, replayed - the
  win gone for undo and redo too; G9: only the game changes). Section 10: `Screen` (main_menu, game), `MenuChoices`
  (size 13, Atari Go off, goal 1 of 1/3/5; `settings`), `VictoryChoice`, `MainMenuChoice`, `PauseChoice` +
  `return_to_main_menu`; `openCentredWindow` (the three windows' one way of opening: centred, a third down,
  `always_auto_resize`); `submitMainMenu` (the usual sizes as buttons, the chosen one highlighted; a slider 3-19; Atari
  Go and its goal as radio buttons; G3: on a board too small for Atari Go the reason is said and Start Game disabled;
  Quit under `drives_own_frames`); `submitVictoryWindow` (who won; Continue Playing, Restart, Main Menu); the pause
  window gains Return to Main Menu. `update` is now the interface begun, `updateMainMenu` or `updateGame`, the
  interface rendered. `updateGame`: Escape toggles the pause window (not over a won game); the board's buttons inside
  `beginDisabled` while a window is open (G11); the side button and Undo through one `takeBackMove` (G10); `beginGame`
  for Start and Restart (clears the hold, flights, ghost, columns' spring, the window); the board dimmed under an open
  window (`window_dim_color`). Not in S11 after all: H, which opens the debug panel of S12. Tests 32 (+ the continue
  test). Headless `check_menus.script`, positions read off the frames: the menu; 9 x 9 Atari Go with its square and
  goal circles; black's capture and the victory window over the dimmed board, the buttons disabled; Continue Playing
  and a move after it; Escape's pause window; back to the menu with 9 x 9, Atari Go and goal 1 kept; 73 frames, 0
  validation errors. Not run headless: the side button. Tutorial 10.3.
- Oct 18: **auto-fitted windows have their padding below the last item** (Simon, the phone: no space under Start
  Game). An engine fix in `ui.zig`'s `closeWindow`: the fitted height was the title bar + the content + ONE window
  padding, the content's height being measured from below the top padding - so the bottom padding was missing and the
  last item sat on the window's edge, in every auto-sized window. Now `fitted_h` adds the padding above and below, as
  Dear ImGui's `CalcWindowAutoFitSize` does (the width already had both); and the scroll range's visible height
  (`viewport_h`, and the content-overflow check's) is the size less the title bar and both paddings, so a scrolled
  window keeps the bottom padding under its last item at the end too. Test "auto-fit: ..." (the bottom gap equals the
  padding; nothing to scroll); `-Dtest-filter=auto`: 44 of 44, the existing auto-resize tests among them. Not watched
  failing - the test root takes 9 minutes a run; the old formula's gap is 0 against the padding asserted. Seen: goban's
  main menu, pause and victory windows, the padding under Quit, Show liberties and Main Menu; 0 validation errors.
- Oct 18: **S12, first half: the debug panel.** Split in two turns: this one is the panel, its controls, the
  inspector and the judge; the move log, the diagrams' copy and paste, and the forest view follow. Section 5:
  `PointInspection` and `inspectPoint` (row, col, index, stone; for a stone its parent, root, depth - steps to the root
  - group size and liberty count; read-only). Section 10: `ForestCheck`, `DebugPanel` (open, verify_every_move,
  last_check, inspected_point - the frame before's pointed point, since the panel is submitted before the board reads
  the pointer, to keep presses on it from reaching the board), `DebugRequests`; `submitDebugPanel` (the state line,
  prisoners, Undo / Redo / Restart, a timeline slider over 0..moves_recorded, the judge's switch and its finding, the
  inspector); `pointLabel`; `verifyForest` (findDisagreement after each played move while switched on; the finding
  kept, and a disagreement panics - a fault in the forest's code); `stepForward`, `jumpToMove` (beside takeBackMove:
  the hold and the flights cleared). H toggles the panel; the pause window has a switch for it (phones). The panel's
  controls work while a window is open (undoing a win to look at it again). Tests 33 (inspectPoint). Headless
  `check_debug_panel.script`: the panel opens with H; the judge on, two moves, "after move 2: the forest agrees"; the
  inspector on black's stone (own root, depth 0, 1 stone, 3 liberties); the panel's Undo to move 1 of 2, nothing
  played under the panel. The script's first points fell under the panel once it grew a line - correctly kept from
  the board - and were moved clear. 0 validation errors. Tutorial 10.4.
- Oct 18: **the finger's lift was gone since S11** (Simon, the phone). Cause: the pointer's kind was learnt only in
  the game's frame, and S11 put the main menu before it. In the game's first frame the pointer seemed to jump, button
  up, from its last tracked place ((0,0)) to where the finger had tapped Start Game: a "hover", so a mouse for the
  rest of the run, and a mouse gets no lift. Fix: `PointerKind` (section 9: `observe` per frame, `isFinger`) replaces
  the two loose state fields, observed in `update` on every frame of every screen. `check_finger.script` now starts
  as a phone does, a finger tapping Start Game: run on the old code it put the held ghost under the finger, (7, 6);
  fixed, on (6, 6) above it. It had not caught this because it predated the menu and never started from it. Test 34:
  a finger's taps, a menu's included, never make it a mouse; a hover does. Tutorial 9.1.
- Oct 18: **the engine says what a pointer is; goban's guess is gone** (Simon: "do it"). Written in a turn that
  stopped before it finished; checked and completed in the next. contract.zig: `PointerKind` (mouse, touch, pen;
  mouse when a platform cannot tell) on `mouse_move` and the button events. runtime: the latest kind in the input
  state (`pushPointerKind`, `pointerKind`); `z.pointerKind` / `z.PointerKind`. Web: the bridge reads
  `PointerEvent.pointerType` and pushes the kind before each pointer event's pushes (`input_push_pointer_kind`).
  Windows: `GetMessageExtraInfo` read while each mouse message is handled; its signature 0xFF515700 in the upper 24
  bits marks a pen's or a touch's message, bit 7 a touch (`native_input.pointerKindOfExtraInfo`). Headless: a script's
  `.move` takes `.kind = .touch` (or `.pen`), which its presses and releases then carry. goban: `pointerHovered` and its
  `PointerKind` guess removed; a finger is `z.pointerKind(f.input) == .touch`, a pen treated as a mouse (its tip hides
  nothing). Tests: native-input-test (the signature; a touch's move and press through the queue and the conversion; a
  script's touch), platform-contract-test, test-goban (32 - the guess's two tests went with it). Checked: lint over the
  eight files; `check_finger.script` with `.kind = .touch` on its moves - the held ghost a row above the finger, as
  before; the web page and goban.exe build. Not run here: a real touch on Windows. Tutorial 9.1 now folds the engine's
  PointerKind; the readme's input section says what `z.pointerKind` reports.
- Oct 18: **S12, second part: the move log, and the position as text.** Section 6: `writeMoveLine(report,
  board_size, writer)` - "W (2,2): joined 2 groups, captured 3, ko at (2,3)", each part only when there is something
  to say ("joined a group" for one). Section 10: `State.move_log` (one MoveReport per move of the record, written when
  the frame plays it; replays repeat the same moves, so the reports stay true); the panel shows the last 8 of the moves
  shown (`DebugPanel.log_lines`). `copyDiagram` (writeDiagram into 1 KB - a 19 x 19 diagram is under 800 bytes - then
  `z.setClipboardText`); Paste diagram asks `z.requestPaste`, and any paste while the panel is open
  (`z.getPastedText`) goes to `loadPastedDiagram`: readDiagram, a new game from the setup, or the problem said in the
  panel's note (`DebugPanel.paste_note`, 160 bytes; a longer note keeps what fits - checked that Zig's fixed writer
  does, two explained lint:offs). A new game - started or pasted - clears the judge's last finding (it was showing the
  old game's "after move 2"). Tests 33 (the log's three shapes; the test's first joining move was an occupied point,
  fixed to black's (1,1) joining four). Headless `check_debug_panel.script`: the log's two lines; Copy diagram then
  Paste diagram - the same position back as a new game; a 5 x 5 diagram pasted; "hello" refused with its reason, the
  position kept; 36 frames, 0 validation errors. Not checked here: the browser's clipboard (a copy outside a
  gesture's own event may be refused there). Tutorial 10.4.
- Oct 18: **S12 done: the forest view.** Section 5: `ForestArrow`, `forestArrows(position, out)` (one per stone that
  is not a root, to its parent, reading order), `pathToRoot(position, point, out)` (point first, root last). Section 8:
  `drawArrow` (leaves its stone 0.15 spacings off the centre, stops 0.3 short of the parent's, head 0.16), and
  `drawForestView` (the arrows in red, a square on each root, the pointed stone's path in gold over them, the depths
  at each stone's lower right when asked); style fields `forest_*`. `DebugPanel.forest_view` and `forest_depths` -
  the view stays on when the panel closes. Drawn after the liberty marks, before the ghost. Tests 34 (arrows: 5 for
  groups of 4 and 3, each to its parent; a path's ends and length = depth + 1). Headless `check_forest.script`:
  white's three (depths 2, 1, 0), black's chain of four (3, 2, 1, 0 - each new stone became the root), the gold walk
  from black's first stone; `check_debug_panel.script`'s judge click moved below the new switch (38, 428); 0
  validation errors. Tutorial 8.7 with a diagram; 10.4 names the switches.
- Oct 18: **liberty counts beside the ghost, changing from before to after** (Simon, the phone: the count sat on the
  group's root, far from the ghost). Section 8: `LibertyLabel` (stone, before, after) and `libertyLabels(position,
  after, ghost, pointed, out)` - one per group touching the ghost, on its first stone beside the ghost (neighbours
  up, down, left, right), plus one on a stone under the pointer whose group has none; before from the board, after
  from the position the move would make (0 for a group it captures). `drawLibertyCounts` shows `before` for
  `liberty_count_hold_seconds` (0.2) after the ghost reaches its point (the hover clock restarts there), then
  cross-fades to `after` over `liberty_count_switch_seconds` (0.2), eased by smootherStep01; an unchanged count is
  drawn once. The counts are no longer faded in with the rings, so the "before" is readable in its 0.2 s. Tests 35
  (two groups 4 -> 5 and 4 -> 3 on their stones beside the ghost - the test first expected them in the wrong order;
  a lone ghost none; a pointed stone unchanged; a captured group 1 -> 0). Headless `check_ghost_liberties.script`
  captures at 0.1 s (4 and 4), 0.3 s (changing), 0.5 s (5 and 3); 0 validation errors. Tutorial 8.5.
- Oct 18: **sounds when a stone is placed** (Simon, with Kaya's sounds). `examples/goban/sounds/`: Kaya's
  `move-0..4.ogg` and `capture0..4.ogg`, unchanged, and `SOURCE.md` - Kaya's repository is AGPL-3.0 as a whole and
  states no license or origin for the sounds of its own; Simon holds them royalty-free; their origin to be recorded
  there once known. Engine: `sounds.loadFromMemory` accepts Ogg Vorbis (`loadFromVorbis`, decoded whole at load by
  `codecs.audio.vorbis.Decoder`, more than two channels refused) - it refused OGG before (`error.OggNeedsDecoder`),
  sending Vorbis to music; test-sound 269 of 274 (+1: the load holds every frame of `sample.ogg`, compared with a
  second decode in small chunks), 5 skipped. goban: `nextTake` (random, never the take just played), `StoneSounds`
  (load, unload, playFor: a capture's take when the move took stones, a click's otherwise; volume 0.8 -
  `ControlsStyle.sound_volume`); `z.audio_device.init` in `init`; played only for a stone placed (undo, redo and the
  timeline silent); the pause window's "Sound" switch. No start screen: a page's audio starts on its first press
  anywhere, always the main menu's in goban. Tests 36. Headless captures and menus: 0 validation errors (no speaker
  there: the sounds load and play without a fault, unheard). Page 5.2 -> 6.5 MB: the audio worklet is back with the
  device (as before the Oct 18 worklet change), the sounds about 80 KB. Not heard here: Simon to listen on the phone.
- Oct 18: **the opponent planned** (Simon: a basic computer player for Atari Go, with an understandable MCTS; he
  sent a C++/raylib Go program with MCTS as a reference). Section 8.8: UCT in four steps, the tree as a flat array of
  nodes, legal moves only (section 3's `checkMove`), positions copied per iteration, a seeded generator, an iteration
  budget spread over frames; light and heavy playouts; what the reference does and why goban differs (a 950 ms
  frame, wall-clock budget, a 60-move stone count, illegal moves in the tree, allocating copies, pointer nodes,
  `rand`). Stages S14-S17 after S13; decisions D9-D13 open, to be asked one at a time; two risks.
- Oct 18: **D9 decided - the search starts in the example and moves into zimr later; it runs as jobs** (Simon). Read
  `src/jobs.zig`: a kernel is a pure function (arena, header, payload, writer) on a Web Worker or a native thread,
  keeping nothing between jobs, and runs inline where no worker can be made - the Claude app's preview is such a
  place. So 8.8 now has each job grow its own tree from the root and return the root's statistics, summed by the app
  (root parallelization); wins in half-points, so the sum is exact in any order; jobs sized to a frame and submitted
  one a frame when inline; the record as the payload, replayed in the kernel, since the workers' wasm is a separate
  compile; `examples/goban/kernels.zig` as the registry, merged into the launcher's. S14 and S16 rewritten, two
  risks added.
- Oct 18: **D10, D11 and D13 decided** (Simon): heavy playouts with a switch to light; one worker, a fixed count of
  iterations tuned to about a second; and the tree kept between moves - "there has to be a good way to get this
  chunk of nodes efficiently". 8.8 rewritten: root parallelization dropped. The nodes are an `extern struct` in one
  array joined by indices (about 24 bytes; no untried set - children are made in the order of the legal moves), so
  the tree is one block a job writes out and the next takes up in one copy; the kernel `continueSearch` takes the
  record and the last tree, keeps the subtree under the moves played since, and runs its iterations; the random
  generator's state travels in the tree's header, so slices of a search equal the whole - which lets the inline
  fallback cut the second's budget into frame-sized jobs and still give the same move. Stages S14-S17 rewritten; the
  risks now the inline copies and the tree's size against the output bound.
- Oct 18: **D12 decided - three kinds of game** (Simon): two players, against the computer, computer against
  computer, at the top of the main menu; against the computer, Undo goes to just before the person's last move. 8.8's
  "Who plays" written from it, with the defaults it implies, to be confirmed: the person's colour (black first); Atari
  Go locked on with a computer and Continue Playing for two players only (the computer plays Atari Go only); Undo
  while the computer thinks cancels its job and takes back one move, and does nothing before the person's first;
  between two computers, Undo off (the same position gives the same move), pause to stop, a second's pace. S16
  rewritten. Every decision of the opponent is made; the order stays S13 first, then S14-S17.
- Oct 18: **S13, first part: registered.** `src/web/manifest.json`: goban's card (module core, 3 stars), beside
  tic_tac_toe - inserted as text, the file's own formatting kept (a first attempt rewrote the whole file through a JSON
  writer, reformatting every card; restored from the snapshot before anything else ran). `src/notes/examples_catalog.md`:
  goban's row under games, and rows for three other examples the catalog lacked (`audio_scale_star`,
  `audio_scale_star_hands`, `geno_lab`, none in the gallery); the counts made true (330 directories, 328 examples,
  306 in the gallery, 22 outside, 321 kept). `zig build editor-configs` (goban's entries in .vscode and .zed) and
  `zig build files-md` (goban's files, the sounds among them; 436 files across the atlas have no description and
  nothing requires one - goban's scripts and sounds left like the rest). Engine (ui.zig): `Window.user_moved`, set by a
  title-bar drag that moves the window; `closeWindow`'s warning about an auto-sized window running off the canvas is
  not given for a window the person moved - Simon's phone showed it for the debug panel he had dragged down. Test
  "user_moved: ..." (a click alone moves nothing; a drag does). Left for S13's second part: the launcher (D8), the
  gallery shot, smoke-test, platforms-check, check.
- Oct 18: **S13, second part begun: goban in the launcher.** `examples/launcher/launcher.zig` and build.zig's
  `flagships`: goban after snake; `audio_scale_star_hands` in `audio_scale_star`'s place (Simon). The switch pill:
  its dots' spacing fitted to the window (`pillDotSpacing`, at most 11 px) - with 36 flagships the pill was 465 px,
  wider than a phone held upright, its chevrons off the screen. goban's Undo moved to the bottom-left corner (8.5's
  note: in a window wider than about 470 px the pill's band, 56-90 px up, covered a centred Undo's top);
  `check.script`'s press moved with it. The launcher's headless run (480 x 320) showed goban's main menu running off
  the bottom, Start Game out of reach - so in goban: `centredWindowTop` (a third down if the window fits, higher if
  not, never above the margin; tested), `openCentredWindow` placing each window from its height the frame before
  (`CentredWindowHeights`), and `interfaceFontSize` (the smaller of a 20th of the width and an 18th of the height, so
  the 17-line menu fits a short window). The launcher's web build, its headless run to goban and goban's own menu
  flow (unchanged at 900 x 900): 0 validation errors. Tests 37. Seen and left for Simon: in a window that short the
  pill still crosses the menu - over Start Game - since the pill covers any app's bottom centre; a safe-area band the
  launcher reports to its apps would be the engine's way. Not yet run: flagships-check, platforms-check, smoke-test,
  zig build check, the gallery shot.
- Oct 19: **two fingers are no touch** (Simon: two fingers felt strange). The web bridge sends every pointer to the
  mouse channel, so two fingers made the mouse jump between them, and the first to lift released the button and
  played a stone. `FingerGesture` (section 9): a second finger down cancels the gesture - the stone held put back, the
  board reading no press or release - until every finger is up; the last lift's frame still belongs to the cancelled
  gesture. Fingers counted by `z.getTouchPointCount` (the browser reports each pointer; Windows reports none, so the
  guard never acts there). Test "a second finger cancels the gesture..." (38 tests). Lesson paragraph; tutorial 9.4.
  Not checked headless: scripts have no command for a second finger - a script `touch_down`/`touch_up` pair would let
  one, and would serve every example with touch gestures.
- Oct 19: **S14 - the search** (Simon: on to the opponent, no more S13 checks). New section 7 "The opponent" in
  goban.zig (Layout, Drawing, Input and the app now 8-11; every "section N" reference moved with them; the tutorial's
  chapters still carry the old numbers until its chapter on the opponent is written). `SearchSettings` (exploration
  c = sqrt 2, playout move cap 1000), `SearchNode` (extern struct, 28 bytes: move, mover, legal_move_count,
  children_made, parent, first_child, next_sibling, visits, half_wins), `SearchTree` (nodes, node_count, the
  generator's state as four words), `legalMoves`/`countLegalMoves`, `upperConfidenceBound`, `runIteration` (selection,
  expansion in legal-move order, a light playout, backpropagation; a full tree plays out without adding),
  `runIterations`, `mostVisitedMove`, `playOut` with `randomLegalMove` (rejection with removal: uniform over legal
  moves). Five tests: a capture in one found; the only rescue found; visits and half-wins adding up through the tree
  (root = its children's; others = one + their children's; a child's lost half-wins are its parent's won ones); the
  same seed giving the same tree and move; the root position left as it was. 43 tests, 0.6 s. Measured: from the
  capture test's position, 2000 iterations give the capture 382 visits (all won), the next move 114 - the lesson's
  diagram shows these. Next: S15 (heavy playouts, the tree as bytes, continueSearch, the subtree taken up), and the
  tutorial's chapter 7.
- Oct 19: **S15 begun - heavy playouts.** `PlayoutKind` (light, heavy; heavy the default) in `SearchSettings`;
  `urgentMove` (a capture of an opponent's group in atari, else a rescue of one's own, drawn at random among several,
  each only if legal; via `soleLiberty` on every root), `playoutMove`, `playOut` taking the settings. A first version
  looked at the last move only, as the attached program does: the rescue test then failed - the search chose (4, 3)
  over the rescue (1, 2), whose half-win rate under heavy playouts fell to 26% against 34% for leaving the stone,
  because a stone left in atari while its owner played elsewhere was never captured in the playouts. Hence the whole
  board. Tests: the urgent move captures before it rescues, wherever the group stands (an atari standing before any
  move included); it rescues when nothing can be captured; none when nothing is in atari. 45 tests. D14 recorded
  (Simon: moves within two of a stone, eventually). Next: the tree as bytes, `continueSearch`, the subtree taken up.
- Oct 19: the search's lists as bounded `ArrayList`s over stack buffers (`.initBuffer`, `appendAssumeCapacity`,
  `swapRemove`), as `neighborsOf` does (Simon): `legalMoves`, `randomLegalMove` (the strike-out is `swapRemove`),
  `urgentMove`. Same exchanges in the same order, so every search is unchanged; 45 tests.
- Oct 19: **S15 - the tree portable and continued.** `SearchTreeHeader` (extern: node_count, root_moves_played,
  root_fingerprint, random_state) beside the nodes in `SearchTree`; `positionFingerprint` (Wyhash of size, stones,
  turn, ko, prisoners, goal, winner); `childByMove`; `takeUpSubtree` (follows the moves since the root through the
  children; copies the node reached and everything under it breadth first into a fresh array - children in their
  order, visits and half-wins kept, the generator's state carried; null when a move leads off the tree or the subtree
  does not fit); `writeTree`/`readTree` (header then nodes; read by copying, since a job's bytes promise no alignment;
  refused when short, inconsistent or too large). Lesson paragraph with a diagram. Tests: bytes round trip; the
  subtree after two moves taken up whole (size, root statistics, children in order with their subtrees' sizes); not
  taken up off the tree or into a buffer too small. 48 tests. Next: `continueSearch` (replay the record, check the
  fingerprint, take up or start afresh, run) and the test that n iterations equal n cut into slices; then the
  tutorial's chapter 7.
- Oct 19: **review of section 7** (Simon: bugs, optimisations, perfect). Measured first, in ReleaseSmall (the pages'
  mode; `test-goban` builds Debug, so build.zig's line was switched for the timing runs only and restored): 20,000
  iterations from an empty 9 x 9 board, goal 1 - a playout about 23 us of the iteration, a legal-move scan 2.8 us
  (two per iteration), the root's copy 1 us. Changes: (1) `positionFingerprint` hashes each optional as a defined
  number - it hashed their bytes, whose value part the language leaves undefined when null (this compiler writes
  them whole, zeros in release, 0xAA in Debug, so no wrong fingerprint was seen; the hash no longer depends on it);
  (2) `SearchNode`'s hidden padding byte named (`unused_byte`, 0) and a test that a node and a header have no padding;
  (3) `readTree` checks the length by division - the product could overflow a 32-bit usize; (4) `SearchTree.init`
  asserts a capture goal - plain Go playouts would only stop at the cap; (5) `mostVisitedChild` in the section,
  `mostVisitedMove` through it, the tests' copy gone, ties broken as `childWithHighestBound` breaks them (the newest);
  (6) `takeUpSubtree` asserts its buffers do not overlap. Optimisations: a node's legal moves counted lazily, the
  first time it is expanded (`not_counted`, `isFullyExpanded`; `countLegalMoves` gone) - about 11%; UCB1's
  c * sqrt(ln N) worked out once per parent (`explorationFactor`) - about 4%. Old against new in the same conditions:
  712-731 ms against 541 ms, about 25% faster; same move, same node count. Not done: copying only the board's part of
  a position (under 2%, and a copy that must list every field). Tests: the fingerprint for the same position reached
  twice; the layouts. 50 tests. The lesson's visit counts re-measured: they had been taken with light playouts; under
  the heavy default the capture leads 148 to 136, the other moves winning nearly as surely.
- Oct 19: **S15 done - `continueSearch`.** `takeUpLastTree` (the root's position must be the record's after
  `root_moves_played` moves, by fingerprint; with no move since, the last tree itself goes on in place; else its
  subtree under the moves since, into a fresh buffer; null otherwise) and `continueSearch(gpa, record, last_tree,
  node_buffer, iteration_count, seed, settings)` (its own scratch game and position from `gpa`, the game written whole
  before the replays). Lesson paragraph. Tests: 800 iterations equal to 300 + 200 + 300 as three continued searches,
  node for node and header for header; after the computer's move and a tried reply, the next tree is exactly that
  reply's subtree (`expectSameSubtree`, index-free) and its iterations add to its visits; a fresh tree after an untried
  reply, an undo past the root, and another game of as many moves. 53 tests. Next: the tutorial's chapter 7 (and its
  later chapters renumbered 8-11), then S16 - the job's header as an extern struct (SearchSettings is a plain struct;
  the job is a separate compile), `kernels.zig`, the menus.
- Oct 19: **the tutorial's chapter 8, "The opponent"** (8.1 playing games out, 8.2 one iteration, 8.3 choosing among
  the children - UCB1 with a worked example, 8.4 the move played, 8.5 the tree in one array, 8.6 playouts, 8.7
  continuing a search), five diagrams (the four steps, the UCB1 bars for a parent of 100 visits, a tree and its array,
  the two urgent moves, the subtree taken up), 28 folds. Chapters 8-11 renumbered 9-12, three cross-references moved
  with them. Fixed on the way: the contents lacked 10.4 "Two fingers"; the Reference heading was there twice, as 11
  and as 9; the figure generator defined `f_forest` twice, so chapter 3.3's diagram of the forest showed the forest
  view's (now `f_forest_view`); two figures shared the SVG id prefix "flt" (the fault figure is now "fau"). The job's part of the search is left to the chapter until S16 builds it.
- Oct 19: **S16 begun - the search as a job.** `SearchSettings` an extern struct (exploration, playout_move_cap,
  playout_kind as `enum(u8)`, three named padding bytes); `SearchJobHeader` (settings, iteration_count, seed);
  `RecordBytes`/`SetupStoneBytes` and `writeSearchPayload`/`readSearchPayload` (the record field by field - board,
  goal with 0 for none, setup stones, the moves played - then the last tree's bytes; refused when short or impossible);
  `readTreeHeader` (shared with `readTree`); `searchJob(gpa, header, payload, out)` - the kernel. Lesson paragraph
  "THE SEARCH AS A JOB". `examples/goban/kernels.zig` (registry `searchGoban`, default bounds); build.zig: goban's row
  `.job_kernels = true`, the launcher's kernel deps + "goban", the launcher's merged table + `searchGoban` and its
  bounds. Engine: the generated `kernel_root.zig` declares `std_options` with a log function that drops lines - a
  kernel that reached `zm.assertf` (which logs) did not compile, std.log's default writing through the standard
  library's threaded I/O, which wasm32-freestanding lacks; goban's is the first kernel to assert. Tests: the payload
  replays to the same position (and a short one is refused); the job's tree equals `continueSearch`'s byte for byte,
  with and without a last tree (300 + 300 = 600). 55 tests. Pages: goban's kernel wasm 15 KB, 0 imports, exports
  `zimr_job_searchGoban`; the launcher's 32 KB, 0 imports, all three kernels. Next: the app - the menu's kinds of game,
  submitting the job (one on a worker or thread; frame-sized slices inline), the computer's move, Undo.
- Oct 19: **S16, the computer plays.** Section 11: `GameKind` (two players, against the computer, computer against
  computer; the menu's labels), `Players` (`computerToPlay`), `MenuChoices.game_kind`/`person_stone`/`isAtariGo`/
  `players`; the main menu opens with the three kinds as radio buttons, "You play: Black / White" against the
  computer, Atari Go shown on and disabled with "The computer plays Atari Go." when the computer plays (the menu now
  about 23 lines: `characters_down` 24). `ComputerSettings` (5,000 iterations a move, 50 a frame inline, 100,000
  nodes kept at most, the search's settings), `ComputerPlayer` (the job, the iterations done, the last tree's bytes
  aligned for nodes, the payload buffer, the game's seed - a fresh tree's seed is it plus the moves played -, the last
  move's time; keeps `gpa`, the frame function being given none), `submitSearchJob`, `advanceComputer` (submit when
  idle; poll; a landed tree kept; the most visited move once the move's iterations are run; a record changed under a
  search - undo, paste, timeline - stops it). `afterMovePlayed` (log, sound, judge, flights) shared by the person's
  moves and the computer's. The board closed and the caption "the computer is thinking" on its turn; Continue
  Playing only between two players; the debug panel's line for the computer. Section 7: `viewTree` (a tree's nodes
  read in place), `writeSearchPayload` taking the tree's bytes, and the registry now `search_job_registry` beside
  the kernel (bounds 4 MB in, 3 MB out - the inline path allocates the output bound at each submission); kernels.zig
  only lists them (it imported goban.zig, which imported it: the lint's import cycle, gone). Headless
  (`check_computer.script`): the menu, "Against the computer", 9 x 9, black's move, "thinking", white's reply - 0
  validation errors. **Found: the computer blunders.** After black's (2,4) leaves white's (3,4) one liberty, white
  played (4,5); black then captures and wins. With every child made before any is chosen, 5,000 iterations over 76
  moves of 75 replies spread almost evenly (80-120 visits each), and black's winning reply under each bad move is
  about the 33rd made, so the bad moves look sound (59%). Proposed next: **decisive moves** (Teytaud & Teytaud,
  2010) - a node whose player can win at once has only its winning moves as candidates.
- Oct 19: **the search in the frames, where there are no jobs** (Simon: the Claude viewer has no workers; 30 ms of
  iterations a frame until the count, with no tree written to bytes; logs from workers; native). Engine: a monotonic
  clock for apps, `z.monotonicMilliseconds` - contract entry `monotonicMilliseconds` (web `performance.now()`,
  Windows the performance counter, headless the run's clock, which stands still within a frame; template and
  unwritten as for every entry). goban: `JobSearch` (the job path, as before, now also ending a search on a changed
  fingerprint - a pasted diagram keeps the move count) and `FrameSearch` (two node buffers, the tree in one, a
  take-up copying into the other; the root position, a scratch position, a replay game; `bringTreeTo`, `step` with
  the clock passed in: iterations until `frame_budget_milliseconds` (30), the move's count, or
  `max_iterations_per_frame` (2,000 - the bound for a still clock)); `ComputerPlayer` over a union of the two, chosen
  at start by `jobs.parallel()`; `inline_iterations_per_frame` gone. Test: in frames of 300 with a still clock, the
  1000-iteration tree equals `continueSearch`'s node for node, and the take-up after a move and reply equals the
  job's. 56 tests. Built and run: Windows (release), headless against the computer (a native thread: the reply
  played), web, `platforms-check` - all clean. Still to do: the workers' log lines (they are dropped in the kernel
  wasm), then decisive moves.
- Oct 20: **workers' log lines reach the page** (finished after a turn that stalled before its checks; its edits were
  complete). Engine: `jobs_abi` names `zimr_job_log_ptr`/`zimr_job_log_len`; in `jobs.zig` the kernel wasm keeps a
  job's log lines in a 4 KB buffer (`Registry.workerLogFn`, the generated kernel root's `std_options.logFn` instead
  of dropping them), emptied as each job starts, a line past the end dropped and counted, the count reported in a
  last line; the worker script (`jobs_worker.zig`) reads them after the job and sends them with its reply, done or
  failed; the page (`bridge.zig`, `printWorkerLog`) prints each line through the console method its level names -
  so also on the page's overlay. Natively a kernel runs on a thread and logs as the program does. goban's kernel
  logs one line a job (iterations, nodes, visits taken up). Checked: lint, test-goban, the web build - the kernel
  26 KB (15 before; the formatting), 0 imports, the two log exports. Not run: the jobs test of the log buffer
  (engine test root, about 8 minutes) - with the next full gate. Next: decisive moves.
- Oct 20: **a move's search runs for a second** (Simon: one second regardless of machine speed, for now - D11's fixed
  count set aside, so a position's move now depends on the machine). `ComputerSettings.move_milliseconds` (1000)
  replaces `iterations_per_move`; on a worker the second is a run of jobs, each sized from the last's measured rate
  to take about `job_milliseconds` (100; `first_job_iterations` 500 before any rate), each taking up the tree the last
  returned - a kernel imports nothing, so has no clock, and the program keeps the time; in the frames, 30 ms of
  iterations a frame until the second is up. `SearchJobHeader.max_node_count`: a job's tree stops growing there
  (the kernel's buffer capped), which replaces dropping a tree that might outgrow the cap - within a move that
  would have thrown away the move's own search. `ComputerPlayer` keeps the move's timer and notices a changed
  record (moves played, fingerprint); each search keeps its last move's iterations; the debug panel shows the
  second, where the search runs, the last move's iterations and time, and the iterations so far. Tests: the search in
  the frames on a stepping clock (four frames for 100 ms in 30s; then one job of as many iterations makes the same
  tree and move, and the same take-up); a job's tree stops at `max_node_count`. 57 tests. Headless (native threads):
  11 jobs in the second, 38,000 iterations, the tree 37,846 nodes - and white now escapes at (3,5), the move the
  5,000-iteration search missed. Web built. Next: decisive moves, so that the escape does not depend on the machine.
- Oct 20: **decisive moves** (Teytaud & Teytaud 2010). `winningMoves` (the liberties of the opponent's groups in
  atari whose capture - every group it takes, counted with `groupsCapturedBy` - brings the mover's prisoners to the
  goal; each point once) and `candidateMoves` (the winning moves if any, else every legal move): a node's children are
  made in the candidates' order; `SearchNode.legal_move_count` renamed `candidate_count`. `prisonersOf` moved up from
  drawing into the rules, `soleLiberty` up beside `winningMoves`. Lesson paragraph "DECISIVE MOVES" with the blunder's
  position. Tests: winning moves with goals 1 and 3 (and 2 prisoners already); in the blunder's position, 5,000
  iterations - the count that chose the losing (4,5) - now choose the escape (3,5). 59 tests. Tutorial 8.8 "Decisive
  moves", 8.5 corrected (children in the candidates' order); two stale folds fixed - `fn init(` ambiguous since the
  searches gained their own, `SearchSettings` an extern struct since S16. Headless: still escapes, 0 errors; web built.
  Next (S16's rest): Undo against the computer to just before the person's move, computer against computer's pace
  and pause, then D14 (moves near the stones).
- Oct 20: **the computer did not play in the Claude app** (Simon's screenshot: "the computer is thinking" for ever).
  Cause, in the engine's job host (`bridge.zig`): a page there may make Workers - `new Worker` does not throw - that
  never start; the host counted the pool usable once they were made, `pump` gives jobs only to workers that have said
  "ready", and none did, so the jobs waited for ever while `available()` said there were workers; and `poll`
  answered "running" for any job once the pool was unusable. Fix: `onWorkerError` (a worker's error event: it takes
  no job, and when none is left the pool is given up); `checkPoolStarted` from `available()` and `poll()` (no worker
  ready 3 s after they were made - `startup_deadline_ms` - and the pool is given up); `abandonPool` (workers
  terminated, `available()` false from then on, every job it took failed as "WorkersUnavailable", `abandoned_pool`
  so that `poll` reports failure, not running). goban: `ComputerPlayer.searchInTheFrames` - when its search is jobs and
  `jobs.parallel()` turns false, it turns to `FrameSearch`. Also from the screenshot: the warning "auto-expanded
  'goban' extends below canvas" was the main menu's first frame, placed a third down before its height was known -
  `openCentredWindow` now opens a window at the margin until its height is known. Not tested in the Claude app here
  (no such sandbox in this one): Simon to check.
- Oct 20: **it plays in the Claude app** (Simon's screenshot: four workers failed, the pool given up, the computer
  searching in the frames, a game at move 18). Tidied from it: a worker that could not load gives a plain error
  event with no message - printed only when it has one, the pool's line saying "every worker failed to start";
  the "auto-expanded 'goban' extends below canvas" warning was the main menu's one frame of growing (choosing
  "Against the computer" adds lines; placed by the height before) - engine: `Window.overhang_height`, the warning only
  for an overhang two frames running at the same height. **Undo per D12**: `moverOfMove` (record, section 4: the
  setup's player first, then turns - no passes), `movesUndoTakesBack` (one between two players; against the
  computer back to just before the person's last move - two after a reply, one while it thinks, none before the
  person's first; none between two computers), `takeBackMove` taking back that many; the board's Undo disabled when it
  would take back nothing; lesson paragraph. Test: the counts through three moves for each kind and colour. 60 tests.
  Disk: the build refused at 97% full (.zig-cache 7.8 GB); zig-out and scratch cleared, 1.3 GB free. Next: the
  tutorial's chapter 11 on the computer's turn and the kinds of game, then D14.
- Oct 20: **the tutorial's 11.4 "Playing against the computer"**: the kinds of game, the computer's turn, the second
  spent on a worker (a run of jobs, the program keeping the time) or in the frames (30 ms a frame, the tree kept as
  nodes in two buffers), a pool of workers that never start given up, a changed record restarting the search, Undo's
  rule; a figure of the move's second both ways; nine folds. 11.4-11.6 renumbered 11.5-11.7; 11.2's font bound
  corrected (a twenty-fourth of the height), 11.3's menu choices and Continue Playing brought up to date. 171 folds,
  0 errors, no duplicate ids or broken links. No code changed. Next: D14 (moves near the stones).
- Oct 20: **a new mode, scattered stones** (Simon: Atari Go's square plus 2 or 4 stones at random, 3 or 4 from the
  centre; name to brainstorm; details mine). Decided: 0/2/4 a menu choice ("Outposts", the working name, one string -
  `MenuChoices.scattered_mode_name`); distance = the larger of the row and column steps to the square's nearest stone
  (the square is off-centre on odd boards); stones in mirror pairs across the square's middle - black at a point,
  white at its mirror, which colour left drawn too - so the start is its own mirror with the colours swapped, fair but
  for black's first move; a drawn point's neighbours struck, so no scattered stones touch and none starts in atari;
  setup stones in the record, seeded per game (Restart scatters anew). Code (section 4): `ScatteredStones` (count,
  distances 3-4, seed) in `NewGameSettings` (default none), `startingSquareCorner`, `stepsOutside`,
  `distanceFromStartingSquare`, `mirrorAcrossStartingSquare` (null off the board - an odd board's last column),
  `scatterCandidates`, `scatteredStonesFit` (k pairs fit at >= 1 + 5(k-1) candidates: a pair from 7 x 7, two from 8 x 8),
  `smallestBoardForScatteredStones`, `scatterStones`; startGame adds them. Menu: "Outposts: none / 2 / 4" under the
  goal; a board too small said so and Start disabled. Lesson paragraph. Tests: 200 seeds x 8..19 x {2, 4} - counts,
  colours, distances, the mirror with colours swapped, no touching, no atari; same seed same stones; fit sizes. 63
  tests. Headless: the menu, a 13 x 13 start with 4. Tutorial 5.5 with a figure, 5.4 and 11.3 updated.
- Oct 20: **the arena, and the first liberty idea** (Simon: improve the computer by rating positions by liberties, if
  it helps). Liberties can enter in three places - the playouts (pass over self-ataris), the tree (prune moves that
  give the opponent a winning capture: anti-decisive), an evaluation (cut a playout short and rate by liberties) -
  and each is to be measured, not assumed. `zig build goban-arena` (on demand, ReleaseFast; `goban_test_options.
  run_arena`, false in test-goban, so the `arena:` tests skip there): `ArenaSettings` (9 x 9, goal 1, four scattered
  stones - every opening different and fair - 1,000 iterations a move for both, each opening played twice, colours
  swapped, a 200-move cap), `playArenaGame`, `playArenaMatch` (the score and its standard error). The arena's own
  check: heavy against light playouts 75.0% +- 3.1 of 200. `isSelfAtari` (liberties counted, no position made; a
  capture is never one; tested) and `SearchSettings.avoid_self_atari` (random moves and escapes): 50.7% +- 2.5 of
  400 - no gain, off; the heavy playout's capture already ends a self-atari's playout as the loss it is. A match of
  400 games takes about 70 s. Next: anti-decisive moves in the tree, then a liberty evaluation at a playout cut.
- Oct 20: **goban outposts, a second example from goban's code** (Simon: outposts nearer, no fairness, more random; a
  separate example - 8 x 8, the person black against the computer, four outposts, Atari Go to one capture, restarting
  by itself on a capture, no menu, no options, no interface; the best way to share code). Outposts: 2-3 from the
  square, each stone drawn on its own, colours shuffled, as many black as white; no touching kept (none in atari); the
  mirror gone; fit at 1 + 5(k-1) candidates: two from 5 x 5, four from 6 x 6. Sharing: the new example imports
  goban.zig as a module and makes its app with `goban.appFor(variant)` - `AppVariant` (title, `fixed_game` =
  `FixedGame` {settings, players}, `has_interface`, `restart_after_win_seconds`) and `appFor` in goban.zig; goban's
  own `app` is `appFor(.{})`. The interface's submission moved into `submitInterface`, skipped without one (no
  buttons, windows, panel, caption, dimming); `init` takes the variant (a fixed game begins at once; moved beside
  `update`); `State.variant`, `State.won_at_seconds` (the restart's clock). build.zig: `App.kernel_deps` (k_<name>
  kernels a row's kernels.zig imports), `configureGobanOutposts` (the `goban` import), the row; the example's step is
  `goban-outposts` (steps take dashes). `examples/goban_outposts/`: goban_outposts.zig (27 lines: the variant, the
  app), kernels.zig (goban's, from k_goban), check.script. Found and fixed on the way: a forced move - one candidate -
  was searched for the whole second (54,000 iterations over a 2-node tree): `rootMoveIsForced` ends both searches
  after one iteration (tested). Headless: the start (no interface), a self-atari, the computer's capture after one
  job, the restart 1.5 s later - 0 errors. Both pages built. Registered: card (2 stars), catalog row and counts (331
  directories, 329 examples, 307 cards), editor configs, files-md. Tutorial 5.5 rewritten, 11.8 added. 65 tests.
- Oct 20: **ideas for the computer, measured** (Simon: it plays badly; improve it, keeping the second). The arena now
  on 8 x 8 with four scattered stones; `ArenaSettings.candidate_iterations_per_move` for matches at equal time;
  `arena: the cost` times an iteration each way. Results, 200 games each: exploration 0.6 against sqrt 2 - 63.0%
  (0.3: 58.5%, 1.0: 54.5%); **made the default**, free. Anti-decisive moves (`AntiDecisive`: off / threats /
  threats_and_self_ataris; `threatenedGroups`, `savesGroup`, `isLosingSelfAtari`, `keepsFromLosing`) - at equal
  iterations 62.5% (threats alone 55%), with 0.6 together 66.5% (73% at 4,000), but an iteration costs ~1.5x, and at
  equal time 48.0% (2,000 v 4,000) and 49.5% (2,700 v 4,000): left off - the decisive moves already punish a losing
  move one level down, in cheap visits. Speed: `isSelfAtari` answers at two empty neighbours without a set; the
  candidates in point order for every kind (`CandidateKind` kept in the node's spare byte; `winningMoves` sorted),
  a node's later expansions finding the next one past its newest child (`nextCandidate`, `isWinningCapture`) instead
  of making the whole list - the same moves (the equal-time match replayed game for game), tested over 300 games for
  every kind. Disk: .zig-cache cleared (8.7 GB, the build refusing); zimrlint rebuilt (the old one hit an illegal
  instruction - the sandbox's CPU changed). 66 tests. Next: RAVE (all moves as first).
- Oct 20: **`zbuild goban-play`** (Simon: something to let Claude play the computer). `examples/goban/goban_play.zig`,
  a native ReleaseFast program on goban.zig's rules and search (no engine): each call replays the game from the
  moves after `--` (Go coordinates: column letter, row from the bottom), refuses an illegal move with the rules'
  reason, searches the computer's reply for a second (or `--iterations` for a reproducible game) in slices of 2,000
  continuing the tree in place - a forced move at once - and prints the search's top moves, the board with
  coordinates, the prisoners, the winner and the moves so far. Options in `PlayOptions`; build step with
  `addPassthruArgs` (this Zig's `Build` has no `args`). **A game, Claude black, seed 1:** h2 g1 g2 f1 f2 e1 e2 d1 d3 c4
  c2 c1 b1 - black wins in seven moves by a ladder along the first line (h1's outpost could not be saved) and a double
  threat at d3 (d4 in atari and the ladder's group). The computer saw it: 1-2% from move one, every reply its best
  defence. 590,000-830,000 iterations a second natively, but a tree of 93-13,000 nodes - nearly every iteration a
  visit to a decided node. Next: **MCTS-Solver** (proven wins and losses carried up the tree, selection spending
  nothing on them).
- Oct 20: **MCTS-Solver, measured; a second game.** `Proof` (unknown / won / lost, from the node's mover's side) and
  `NodeStatus` (a packed byte: the candidate kind, now 2 bits, and the proof - the node still 28 bytes);
  `SearchSettings.solver`; selection stops at a proven node and counts its result with no playout, takes a child
  proven won at once, a proven-lost one only when no other is left; `propagateProof` (won child: parent lost; all
  children lost and fully expanded: parent won; up while it proves); `mostVisitedMove` proof-aware;
  `searchIsSettled` (forced, or a proven root) ends the searches and goban-play. Tests: the capture's node proven won
  and the root lost; the double threat of the first game proven within 20,000 iterations. Arena: 48% at 1,000, 52.5%
  at 4,000 - no gain - and 8.6 us an iteration against 5.1 (the visits it saves were cheap): left off. **Game 2**
  (seed 7, the computer black): f5 e6 d6 f6 f4 d3 a7 c6 c5 c4 c7 b6 b5 d7 a6 b7 b8 - the computer won: Claude's c6
  pushed with two liberties toward black's outposts, and c7, b5, a6, b8 were exact. Its one doubtful move, a7, came
  from flat ratings (its five best all 53%) in a quiet position, and helped the net later. Natively it runs 120,000-
  650,000 iterations a second; on a phone, in a worker or the frames, far fewer - the likeliest reason it plays
  worse there. 68 tests.
- Oct 20: **outposts on the second line, and a ladder** (Simon: none on the last line, all on the next to last; three
  outposts that move with the results - three black to begin with, a win of the person's turning one white, up to
  three white, the computer's wins turning them back). `ScatteredStones`: `black_count` and `white_count` (and
  `evenly`, `total`, `max_count`) for the one count; candidates the second line (`linesFromEdge` == 1) at least
  `min_distance_from_square` (2) from the square; the colours set, then shuffled; fit as before - two from 7 x 7, four
  from 8 x 8 (6 x 6: the second line is beside the square). goban's menu: `evenly(2 / 4)`. `OutpostLadder` (total;
  `stonesFor(computer_count, person_stone)`), `nextComputerOutposts` (person's win +1 up to total, computer's -1 down
  to 0), `AppVariant.outpost_ladder`, `State.computer_outposts`; the first game from the ladder, each restart moving
  it by the winner. goban outposts: `.outpost_ladder = .{ .total = 3 }`. goban-play: `--black-outposts`,
  `--white-outposts` (`--outposts` the even split). Tests: placement over 8..19 x six splits x 200 seeds (second line,
  clear of the square and each other, counts, no atari); the fit sizes; the ladder's steps both ways and for a white
  person; the solver's double threat from a diagram (it replayed an opening the old placement drew). 69 tests.
  Headless: three black outposts at b7, g6, c2. Both pages built; tutorial 5.5 and 11.8, the figure, the card and the
  catalog row updated.
- Oct 20: **the ladder, slower and fair about the first move** (Simon: 3 black, then +1 white keeping the blacks, then
  a black removed, ...; always 3 or 4 outposts; slower; to advance the person must win moving second, losing makes
  them move first). `OutpostLadder { person_start }`: rungs (person, computer) 3-0, 3-1, 2-1, 2-2, 1-2, 1-3, 0-3,
  each played twice - the person moving first, then second: 14 positions, a win one up, a loss one down, the ends
  holding (`positionCount`, `stonesAt`, `firstPlayerAt`, `nextPosition`, `settingsAt`). So a rung is climbed only by
  winning it moving second, and a loss moving second gives the first move back. The person keeps their colour;
  `NewGameSettings.first_player` (default black) sets `setup_to_play` - white first is as fair, the square being its
  own colour-swapped mirror. `State.ladder_position`. goban outposts: `.{ .person_start = 3 }`. goban-play: `--first`.
  Tests: every position's split and first player (always 3 or 4 stones), the steps and ends, the person white; a game
  with white first. 70 tests. Tutorial 5.5 (the rung table) and 11.8, card and catalog updated; both pages built.
- Oct 20: **levels** (Simon: "Level N" in the corner, from the ladder; past the last black outpost, more white ones;
  never under level 1). The level is the ladder position + 1, drawn with `common.captionf` in the top-left corner
  when the variant has a ladder and no interface. `OutpostLadder.rungSplit`: the alternating rungs, then past the
  person's last stone one more of the computer's each rung; `positionCount(board_size)` the rungs whose stones fit
  (on 8 x 8: 0-4 .. 0-7, 11 rungs, 22 positions - level 22 the top); `nextPosition` takes the board size.
  `scatteredStonesFit` exact: 1 + (1 + m)(k - 1), m the most candidate neighbours of a candidate (2 on the second
  line), not 4 - so the second line of 8 x 8 holds 7. Tests: all 22 positions (split, first player, fit), the ends;
  placement with 5 and 7 stones. 70 tests. Tutorial 5.5's table with the levels; both pages built.
- Oct 20: **go problems, step 1: the database and its reader** (Simon: a new example of SGF kill problems - the
  person black, our computer the defence instead of the SGF's moves, win by killing a marked stone, Undo, Next after a
  win, nothing else). `examples/goban/problems/`: ggg-easy-01..03 from Go Game Guru, each root node given `TR[..]` on
  the stone to capture (qq, qq, rr - a stone of the corner group the "Correct" lines kill), the rest as published;
  SOURCE.md. Section 6: the SGF lesson; `KillProblem` (a `DiagramSetup` and the target), `SgfError`, `SgfCursor`
  (properties of the root node, values with escapes), `appendSgfPoints` (points and `aa:cc` rectangles),
  `readKillProblem` (SZ, AB, AW, TR; on the board, no point twice, every group a liberty, one triangle on a white
  stone); `kill_problem_sgfs` embedded. Tests: the three read (counts, targets); rectangles, spaces, an escaped
  bracket; every refusal. 72 tests. Plan for the rest: (2) the rules - a target to capture as the goal, the loss when
  the target's group is unconditionally alive (Benson's algorithm), and a pass for white; (3) the search for life and
  death - moves within the problem's region, playouts that do not fill their own eyes and pass, ending at two passes
  (white wins if the target stands); (4) the view - the problem's region of the board, its open sides running off;
  (5) the example, goban_problems: goban made another way, an Undo button, Next after a win.
- Oct 20: **nine intermediate problems, classified** (Simon: how to convert them into precise kill problems; later
  life problems, problems started later in a solution, random rotations). `problems/source/`: all twelve as
  published. Kill: 01 (capture the cutting stones np-nq-nr), 02 (the group inside the wall), 03 (capture the white
  stones inside black's, which lives), 06 (one move, qs), 07. Life: 04, 05 (two eyes under a wall), 08, 09 (seki).
  The target comes from the game, not the comments. A PRECISE KILL PROBLEM: black first captures the target against
  any defence; white first saves it; the book's correct first moves win and its wrong ones lose. The converter tries
  the white chains beside the correct lines' black moves, keeps those that pass, takes the largest, and reports any
  disagreement with the book. Life problems mirrored: a black stone to save (SGF `SQ`, the triangle `TR` for kill),
  the defender winning when both pass with it on the board - seki included. Later starts: the positions along a
  correct line, kept if black still wins and some black move loses. Rotations: the square's 8 symmetries at load.
  Ko: a winnable ko counts as a capture under these rules, against the book's "a ko, but Black can do better" -
  flagged by the agreement check for now. Order: (1) the rules and search for life and death, (2) the converter,
  (3) later starts and rotations, (4) the app.
- Oct 20: **go problems, step 2: the rules and the search for a kill problem** (Simon: only problems where capturing
  one stone wins; no losing - the person undoes; life problems later, perhaps with the search judging safety; Kill and
  Live eventually alternating on the same problems). Rules: `ProblemRegion` (section 1: a rectangle, `contains`,
  `around` - the stones' box and a margin); `Position.target`, `Position.region`, and the record's (defaulted null);
  `Legality.outside_problem`; `placeStone` declares black the winner when the target's point empties; replay sets the
  target and region after the setup (set before, the first setup stone saw the empty target and "won"). The payload
  (`RecordBytes`: target, the region's four bytes; no padding) and the fingerprint carry both. Search:
  `SearchTree.init` takes a kill problem; `winningMoves` / `isWinningCapture`: black's capture of the target's group;
  `isOwnEye` (all neighbours the mover's; opponent diagonals at most 1 in the middle, 0 at an edge); `passTurn` (the
  playouts' only pass - the record has none, so nothing that turns moves into points changed); playouts in a problem
  skip their own eyes, pass with no move left, end at two passes or the cap - white's then; `randomLegalMove` draws
  from the region only (test-goban 18 s to 8 s). `KillProblemSettings { region_margin = 1 }`, `startKillProblem`.
  Tests: the region and the target's capture; eyes; the search plays the book's first move in easy-01 and -02 at
  30,000 iterations; easy-03 needs 300,000 (its correct move leaves a dead group whose death random playouts show
  slowly - 30,000 left it 43% to qo's 39% by rate but behind in visits) - an arena test, 7 s ReleaseFast. 75 tests.
  Next: the converter (targets and the precision checks), then the app.
- Oct 20: **go problems, step 3: the converter.** goban.zig: `SgfRoot` and `readSgfRoot` (the root node's setup,
  triangles and end index; `readKillProblem` on it), `SgfFirstMove` and `readSgfFirstMoves` (each variation's first
  black move, correct when "C[Correct" lies under it; one line without variations counts as one; a move opening two
  variations correct if either is), `indexPastSgfValue`, `indexOfSgfVariationEnd`. `examples/goban/goban_problems_
  tool.zig` and `zbuild goban-problems-convert` (native ReleaseFast): every white chain tried as the target, the
  search (200,000 iterations, the app's settings) choosing black's first move; a chain agreeing with the book's
  correct first moves is a candidate, the largest the target; checked with white first; written with `TR` after the
  root's last property; a report line for every chain. On the twelve (275 s): written easy 01 (pq), 02 (qq), 03 (rq)
  - the hand-marked chains - and intermediate 01 (np, the cutting stones), 02 (on), 03 (oq, a stone inside black's),
  06 (pq); white first saves the target 84-97% in each. Rejected: 04, 05, 08, 09 (life problems; 09's trivial 100%
  captures not the book's move - the agreement check filters those too) and 07 (the search plays qr, a ko black wins
  under these rules; the book's pr 192 visits, 40% - the kill after it is deep, a dead group the playouts show slowly).
  The seven installed in problems/ and embedded; SOURCE.md. Tests: the first-moves reader; every problem reads. 77
  tests. Next: the app (goban_problems: the region's view, Undo, Next after a win).
- Oct 20: **go problems, step 4: twins and later starts** (Simon's theory: life and kill problems convert into each
  other; more problems by starting later in the solution - right, under one condition each: the position must be
  unsettled, white first saving the target, which the converter's check already tests). goban.zig:
  `readSgfCorrectLine` / `findCorrectLine` (the first line reaching "Correct", moves of both colours, a variation's
  moves taken back when no line in it reaches it), `swapColours`. The tool: `checkTarget` (a known target: black
  first against the book's moves, white first - black's part of the report printed before white's search reuses the
  node buffer: the first run's "the book's .. visits" figures read white's tree), `findTarget` (every chain; the
  largest agreeing and unsettled), `writeFreshProblem` (stones, TR, a comment; no tree), `unsettled_rate` 0.5;
  `convertProblem`: as published, then later starts after each black-white pair of the correct line (the book's next
  black move the agreement); or, for a life problem, the swapped twin, the book's first move its vital point. Run in
  two halves (277 s, 317 s; one core, ~5 s a search): 16 kill problems - the 7 as published; from move 3 of easy-01,
  -02, intermediate-02; from moves 3 and 5 of easy-03; from moves 3, 5 and 7 of intermediate-01; intermediate-04's
  swapped twin (target mq, the group that had to live; black's ns the book's vital point, 83%; white first 92%).
  Rejected: intermediate-03 from move 3 (already decided: white first 0%), 05 / 07 / 08 either way, 09's twin (white
  first 36%). Every published kill problem's life twin has the kill's vital point - the proverb held. The 16 embedded;
  SOURCE.md. 78 tests.
- Oct 20: **go problems, step 5: the app, goban problems.** goban.zig: `Symmetry` (the square's 8; `transformPoint`),
  `transformedProblem`; `BoardLayout.forRegion` (the spacing that fits the region and its margin, the origin that
  centres it - the board's other points off the window, its lines running off the open sides; the real edges end
  them) and `forPosition` (the game screen's layout); `AppVariant.interface` (`Interface`: full / none /
  problem_buttons - goban outposts' `has_interface = false` now `.none`) and `kill_problems`; `State.problem_index`;
  `beginProblem` (read, a random symmetry from the start's seed, `startKillProblem`, the computer and the screen's
  state reset); `submitProblemButtons` (Undo bottom-left, Next bottom-right once solved; both work after the win -
  their own path, not the game buttons', which a won game holds); init starts the first problem;
  `BoardStyle.target_mark_*` and `drawTargetMark` (a triangle on the target's stone, as SGF viewers draw `TR`). Tests:
  the symmetries (one-to-one; four quarter turns none; a problem keeps its stones and target); the region's layout
  (its middle at the window's, every region point in, the far corner out). `examples/goban_problems/`
  (goban_problems.zig 22 lines: the variant; kernels.zig goban's; check.script); build row with
  `configureGobanProblems` and `kernel_deps`. Headless: easy-01 in a half turn, its corner top-left, the target's
  triangle, black's rs and the computer's reply rr - the book's - then Undo back to the start. Pages: goban problems,
  outposts, goban. Registered: card, catalog (332 directories, 330 examples, 308 cards), editor configs, files-md.
  Tutorial 5.6 "Kill problems"; 11.8. 80 tests.
- Oct 20: **"Solved" by the book** (Simon: show solved when the file says so, and Next; no playing out). goban.zig:
  `commentSaysCorrect` ("Correct" or "Also correct" - easy-01's second solution; the first-move reader and the
  correct-line walker take it too); `SolutionNode`, `SolutionTree` (1,024 nodes; `nodeAfter`, `isSolvedBy` - a correct
  node on the moves' way, `repliesAfter`, `transformed`), `readSolutionTree` / `readSolutionNodes` (one recursive
  reader: a run of nodes, then variations whose first nodes are the run's last node's children) /
  `appendSolutionChild`; `SgfError.TreeTooLarge`. App: `State.problem_tree` (read and drawn in the problem's
  symmetry by `beginProblem`), `problemIsSolved` (the book's correct node or the target's capture), the board held
  while solved; `AppVariant.computer_follows_book` (true): on the book's line the computer plays the book's reply
  (`bookReply`, one of several at random, legal) with no search, off it the search's - so a player who finds the
  book's solution reaches its "Correct"; `fixedLabel`; "Solved" at the top centre with Next. Test: the tree's
  replies, its correct lines (Correct and Also correct), a move off it, a symmetry. Headless: easy-01 by rs, the
  book's rr at once, ns - Solved and Next, the target still standing; Next opens easy-02 in its own symmetry. Tutorial
  5.6. 81 tests. Next: later-start problems given the rest of their book's tree (they have none, so only the
  capture solves them now).
- Oct 20: **playing on after Solved** (Simon: the player may continue after solving, to understand why; Next stays
  once shown, even after an undo, which takes the label away; the label stays while playing on, but not after a
  mistake that unsolves). The board is held only by the target's capture now. `problemIsSolved`: the capture, or the
  moves passing through a correct node and `!problem_refuted`. `State.problem_solved_once` (Next from the first
  solving on, reset by `beginProblem`), `problem_refuted` (the computer's last searched move won at least
  `ProblemPlaySettings.refuting_win_rate` (0.8) - after a real solution the rate is about 0.3 to 0.5 - cleared by a
  book reply and by an undo), `problem_play`. `rootChildWinRate`; `JobSearch` / `FrameSearch.last_move_win_rate`;
  `ComputerPlayer.lastMoveWinRate`. `submitProblemButtons` takes the label and Next apart. Headless: solved by the
  book, played on - the computer answers, Solved stays; Undo - Solved goes, Next stays; Next - the second problem.
  Tutorial 5.6. 81 tests.
- Oct 21: **life problems, steps 1-2: a target of either colour; Benson's algorithm.** The target's capture wins for
  its opponent - the mover - as before; `winningMoves` / `isWinningCapture` ask whether the target's opponent is to
  play (and find no move once it is captured: the search expands such nodes); an undecided playout goes to the
  target's owner (it was white's). `BensonRegion`, `aliveStones(position, colour)` (regions of non-colour points
  flood-filled, vital when their empty points are all a bordering chain's liberties; chains with fewer than two vital
  regions set aside, and the regions beside them, until nothing changes), `isUnconditionallyAlive`. Section 3's
  lesson: PROBLEMS and UNCONDITIONAL LIFE. Tests: two eyes alive; one eye not; a seki not; an eye holding a dead stone
  still vital; a black target white captures to win (white's one winning move; black, to play, none); a living black
  target's playouts all go to black. 83 tests. Next: the give-up test from the computer's search; life problems in
  SGF (`SQ`, the stone to save) and one problem type; the converter; the app alternating.
- Oct 21: **life problems, steps 3-4 and the app's side; the converter's first life problems.** Renamed for both
  kinds: `Problem` (+ `kind: ProblemKind` kill / live), `readProblem` (one mark: `TR` on a white stone, a kill; `SQ`
  on a black one, a life - `SgfError.TargetWrongColour`), `startProblem`, `ProblemSettings`, `problem_sgfs`,
  `AppVariant.problems`; `SgfRoot.squares`. `isProblemSolved` (pure, tested) with `ProblemEvidence`: a captured target
  decides (white's: solved; black's: lost); else the book's correct node unless refuted; for a life problem
  Benson's proof; for either, the computer giving up - `ProblemPlaySettings.giving_up_win_rate` 0.05,
  `giving_up_moves` 2 (`State.computer_hopeless_moves`, reset by undo, a book reply resets it). The target's mark by
  its colour: a dark triangle on white, a light square on black (`BoardStyle.save_mark_color`). The tool:
  `chainsOf(colour)`, `findTarget(kind)` / `checkTarget(kind)` (unsettled one test for both: white first wins),
  `writeMarkedProblem` (TR or SQ); a problem with no kill tried as a life problem, then its swapped twin. Run on 04,
  05, 08, 09 (388 s): life problems 04 (mq), 08 (qp, seki), 09 (lp, seki); 05 neither. `kill_problem_sgfs` (16),
  `life_problem_sgfs` (3), `problem_sgfs` both, `alternating_problem_sgfs` (`alternated`, comptime: kill, life, ...),
  played by goban problems. Headless: Next after easy-01 opens 04, its square on the stone to save. Tutorial 5.6.
  84 tests. Next: the refutations as life problems (30 + 10 candidates) and the life books' as kill problems (18),
  their trees written with success nodes; the kill twins' life twins.
- Oct 21: **a faster converter, and Simon's 14 new problems.** Measured (ReleaseFast, easy-01): an iteration 27 us -
  the playout 32 us of it; the position's copy 2 us; a random move 0.15 us. `playableRegion` (a problem's region, or
  the board: every stone stands in it), and `legalMoves` and `urgentMove` scan it only - a playout 32 to 25 us. The
  tool: candidates only chains within `candidate_reach` (2) of the book's correct line and first moves; black first
  for each, white first only down the agreeing from the largest (`checkBlackFirst`, `checkWhiteFirst`); a search in
  slices of 10,000, stopping when its choice cannot change (`choiceCannotChange`), or after `min_iterations` (50,000)
  when the leader holds `settled_share` (0.7) of the visits AND wins at least as often as every child with
  `counted_share` (0.01) of them (`leaderWinsMost`) - without that last test intermediate-02's chain at on stopped at
  50,000 with po leading at 55% while the book's qn, at 61%, was still gaining, and the target came out sp; threads
  (`ConversionShare`, one per core or `--threads`, reports in the files' order). The 26 sources (Simon's 14 new:
  intermediate 11, 12, 109-120): about 16 minutes here in six chunks (the sandbox suspends between turns, killing a
  background run), against well over 20 before (the slow run timed out after 25); the result equal to the slow run's
  on its 25. New: 11 (+ from 3, 5), 111, 116 (+ from 5), 117 (+ from 5, 7, 9), 118 (+ from 3, 5, 7, 9), 119, 12 (+ from
  3); rejected 109, 110, 112-115, 120. Installed: 34 kill problems, 3 life (lists made from the files' marks). 84 tests.
- Oct 21: **go puzzles hero** (Simon: outposts and puzzles combined; no undo; Abandon gives the problem again from a
  later start, a kill problem now a life problem, down to the last start; success backs up a start at a time, the
  full problem's success a fresh round; Fight, Live, Kill in turn, the fight remembering its level). One move later
  would set an impossible life problem - after the attacker's correct move the defender is lost - so (agreed) each
  step is two moves on, the kinds alternating by giving the move to the other side at every other step. goban.zig:
  `ProblemFamily` and `problem_families` (17: each published problem and its accepted later starts, from the
  converter's from-move files), `PuzzleStep`, `familySteps`, `Puzzle`, `puzzleAt` (the correct line's first moves
  played; a twin's colours swapped, its kind turned, no book), `SolutionTree.subtreeAfter` - and `appendChild` /
  `copyChildrenFrom` now its methods (they were free functions in a decl-order cycle). App: `AppVariant.hero`,
  `problem_families`, `Interface.hero_buttons`; `HeroRound` (fight, live, kill, `next`), `HeroState`;
  `beginHeroRound` (a fight at the ladder's position; a puzzle round the next family, its ladder opening with the
  round's kind), `beginHeroStep`, `resetForPuzzle` (shared with `beginProblem`), `heroPuzzleIsLost` (a life target
  captured, a kill target alive by Benson), `moveHeroLadder`, `heroLabel` ("Fight - Level 1", "Live 1 of 2 - Solved"),
  `submitHeroButtons` (Abandon - resigning a fight - and Next when solved or lost). `problemIsSolved` asks for a target,
  not for a problems variant. `examples/go_puzzles_hero/` (the variant; kernels; check.script); build row. Headless:
  the fight at level 1; Abandon - the live round, easy-01's twin ("Live 1 of 2"); Abandon - its kill step after rs rr
  ("Kill 2 of 2"). Registered (card, catalog 333 / 331 / 309, editor configs, files-md). Tutorial 5.7 Puzzle ladders,
  11.8. 85 tests. Not yet tried headless: solving a step back up, a fight's end moving the ladder.
- Oct 21: **go puzzles hero, quieter** (Simon, from his phone: no fight level, no "1 of 2" - nothing but one number in
  the corner, the puzzles and fights won, kept in local storage, natively in a file; problems at random, every play
  different; and the two warnings over Abandon). The label gone (`heroLabel` removed); `HeroState.wins`, shown alone
  in the top-left corner, `loadHeroWins` / `countHeroWin` through `z.loadValue` / `z.saveValue` (local storage on
  the web, a file natively - the engine's own) under `AppVariant.hero_score_key` ("go_puzzles_hero.wins"), four bytes
  little-endian; a step counts once, when first solved, a fight when the person wins it. A puzzle round's family drawn
  at random from the clock, never the last one again (`HeroState.last_family`; the cursor gone). The page's overlay
  mirrors console log / warn / error: `abandonPool` now says it on console.info (bridge.zig), goban's frames fallback
  is std.log.info (release pages emit no info) - both the designed path in a host with no workers, not faults to show
  over the board. 85 tests.
- Oct 21: **go puzzles hero: the kind named, no marks** (Simon: "Live" or "Kill" at the top while waiting for the
  first move; no square or triangle - the group is always plain). `submitHeroButtons` takes `kind_name`, shown across
  the top while `record.moves_played == 0` (the player always plays first); `ControlsStyle.label_glyph_fonts` (0.62)
  centres it. `AppVariant.marks_target` (true; go puzzles hero false), the board's `drawTargetMark` only with it -
  goban problems keeps its marks. Tutorial 11.8. 85 tests.
- Oct 21: **a review of the go code** (13,040 lines, 94 tests; lint clean). Bugs: the computer's turn asked
  `variant.problems.len > 0` for "a problem is played" - false in go puzzles hero, whose variant lists no problems -
  so in the hero the computer never followed the book (a step's "Solved" by the book was out of reach) and never
  judged the player's moves (no refuting, no giving up: a life twin with no book only solvable by Benson's proof).
  Now `gameIsProblem` (the record has a target), used there and in `problemIsSolved`. Stale words: 27 comments said
  "kill problem" of what serves both kinds - now "problem"; the SGF lesson names life problems and the square;
  `playOut`'s `is_kill_problem` is `is_problem`. Duplication: the win rate a node's own (`SearchNode.winRate`), the
  root's child for a move `rootChild` - the converter's statistics and the referee's top moves use them (and one
  float type, f32, in the converter). Logic tested: the hero's ladder moves a pure `nextHeroStep` (`HeroOutcome`),
  with a test of every case and of the rounds' turn. `updateGame` 424 lines to 294: `updateProblemButtons`,
  `updateHeroButtons`, `restartAfterWin`, `playComputerTurn`, each a frame's part, called where it stood. Headless:
  goban, outposts, problems, hero all as before, 0 validation errors. 86 tests. Left for Simon: the three search
  settings measured to no gain (avoid_self_atari, anti_decisive, solver) - remove them, or keep them for the arena?
- Oct 21: **the batch: 422 problems** (Simon's problems.zip: 140 easy, 140 intermediate, 140 hard, 2 other - the
  26 known among them, the same bytes; the EPS files diagrams). Survey: all parse; all 19 x 19 but one 13 x 13;
  region areas median 63 / 80 / 90 (hard up to 420); trees up to 445 nodes; correct lines median 5 / 7 / 9, hard up
  to 65 moves. Two hard problems timed: 117 s each, later starts all rejected - the search rates the book's line 0-9%
  for black from move 3 on (dead groups the playouts rarely capture). Plan agreed: convert here, the levels in turn;
  no licence question (Simon contracts for Go Game Guru). **Step 1, the batch tooling**: `ProblemOutcome` (a problem's
  line of the report), `report.tsv` in the output directory - one tab-separated line a problem (name, level, note,
  published kind, target, black %, white-first %, later starts accepted, checked, twin target, seconds), rewritten
  after each problem under an `Io.Mutex`, the problems in it skipped by the next run (`Report`); `index.zig`
  generated after each run from the whole report (`writeIndex`: the families with their levels and later starts, the
  kill and life files - laid out as zig fmt lays them), goban.zig's `problem_families`, `kill_problem_sgfs` and
  `life_problem_sgfs` from it; `ProblemLevel` (easy / intermediate / hard / other) and `ProblemFamily.level`;
  `--adopt` (the files written before taken into the report: the 26's 37 problems, 17 lines, 35 s);
  `--max-later-starts` (6). All 422 sources in problems/source/. /tmp/gb/next.sh picks the next unconverted problem
  of each level. First run: easy-04 a life problem, intermediate-05 rejected, hard-01 a kill (black 13%, its three
  later starts rejected) - 120 s. 86 tests.
- Oct 21: **the search on problems; the frame's edge** (Simon: bias the playouts by liberties, and detect a win or a
  loss earlier). The batch stopped at 82 sources (26 easy, 36 intermediate, 20 hard) - enough. Measured with two
  arena tests: the search against the book (every fourth family, 50,000 iterations: is the book's first move
  chosen, its win rate for black) and playouts from dead and living positions (200 each: the end of the book's
  correct line, black's to win; the problem with white first, white's). `SearchSettings.target_focus`
  (`focusedMove`: a share of a problem's playout moves among the target's liberties and the empty points beside
  them) changed nothing in the search, a few points in the playouts. `local_reply` (`localReplyMove`: a share among
  the eight points around the opponent's last move) a few points on dead positions, nothing in the search - both
  off, for now. The cause, found by counting how playouts end: never the cap; in intermediate half of them both
  players passing with the target standing - its liberties all OUTSIDE the region, where no move may be played: a
  group reaching the frame's edge could never be captured. **The ring**: `startProblem` puts the attacker's stones
  on every free point just outside the region on a side the board's edge does not close (the board beyond a
  problem's frame is the attacker's); never captured (their liberties further out), not drawn (`drawStones`);
  `stonesInRegion` for the starts made from played positions (`puzzleAt`, the converter's later starts). Dead
  positions: black's playouts 84 / 43 / 29% to 95 / 65 / 49% (easy / intermediate / hard); living: white's 73 / 73
  / 75% to 73 / 53 / 62% (the old life partly the frame's edge's). Search against the book: easy 7 of 7 (87%),
  intermediate 3 of 7 (55%; 5 of 7 before), hard 1 of 2 (47%; 33% before). Found too: 3 of 64 families' correct
  lines play outside their region (6 of 327 moves). Next: re-check the problems under the ring; the region to take
  in the book's moves; the early win and loss from the computer's confidence. 86 tests.
- Oct 21: **the book's frame; the kind kept in a turn; the re-conversion begun.** `Problem.book_points` - every
  point the book plays, read with the problem (`readProblem` now after `readSolutionTree`, which it uses) - and
  `startProblem` frames its region around the stones and those points: 3 of 64 families' books had moves outside
  their region, unplayable. `transformedProblem` dropped the kind - every turned problem a kill problem - harmless
  before the ring, but the ring's colour is the kind's attacker's: every life problem an app showed would have had a
  black ring. It keeps the kind and turns the book's points. `puzzleAt` keeps the base's frame (its book's points and
  stones). The converter's checks frame with the book's points too (`book_points` beside `kind` in the four
  signatures, read once in `convertProblem`). Test: every published book's moves inside its region; a turned life
  problem still a life problem. The 82 sources converted again under the new rules (the old report kept as
  report_before_ring.tsv; /tmp/gb/next.sh draws only from the 82): after 9, easy 01-03 unchanged (black 65-75%,
  white first 91-95%); hard 01 black 30% (13%), hard 03 now a kill problem with a later start (a twin only before);
  intermediate 01 now a life problem (a capturing race: the book's move kills and saves), intermediate 02 and 03 a
  different target chain. 87 tests.
- Oct 21: **the computer keeps fighting** (Simon: the opponent abandons and tenukis; it should keep trying). In a
  decided position every move wins about as often, and the search's choice among them - where its visits went - is
  often far from the fight. `ProblemPlaySettings.fighting_below_rate` (0.1) / `fighting_above_rate` (0.9): a
  searched move outside them is replaced by `fightingMove` - among the target's neighbourhood's moves
  (`targetNeighbourhood`, taken out of `focusedMove`), legal and filling no eye of the mover's own, the defender's
  leaving the target the most liberties, the attacker's the fewest (a capture fewest of all). The problem's
  judgements (refuted, gives up) still read the searched move's rate. Each move's search starts from the record, so a
  move other than the searched one is safe. Test: a defender extends beside its group, an attacker takes a liberty.
  Pages rebuilt with the 51 sources re-converted so far. 88 tests.
- Oct 21: **the index imports nothing.** The web build's lint found an import cycle (goban.zig -> problems/index.zig
  -> goban.zig, the index naming `goban.ProblemFamily`) that the native builds do not check. The index now holds
  plain data under its own small type (`Family`: the file, its level's NAME, its later starts) and goban.zig makes
  its `problem_families` from it at compile time (`familiesOfIndex`, the level read with `stringToEnum`, a compile
  error for a level it does not have; the eval budget raised for it). Converted once by hand, then written by the
  converter (`writeIndex`) and regenerated: the same entries. Pages rebuilt (hero, problems) with the ring, the
  book's frame and the fighting move, on the 51 sources re-converted so far. 88 tests.
- Oct 21: **go puzzles hero says "Solved"** (Simon: at the top, when Next appears). The line across the top
  (`submitHeroButtons`' `top_line`): "Solved" once the puzzle is, the puzzle's kind before the player's first move,
  nothing otherwise (a lost puzzle shows Next only). Not seen headless yet - it needs a script playing a rotated
  puzzle's correct line. 88 tests.
- Oct 21: **the outpost ladder from two outposts, in threes** (Simon: three outposts to begin with is too many; start
  with two, then add one white, then a second, before taking a black away; who moves first as before). `rungSplit`:
  in the third `cycle` of rungs, the person `person_start - cycle`, the computer `2 * cycle` plus the rung's step
  (0, 1, 2); past the person's last, one more for the computer each rung. goban outposts and go puzzles hero start at
  2 (their fixed games' outposts 2). On 8 x 8: 2-0, 2-1, 2-2, 1-2, 1-3, 1-4, 0-4, 0-5, 0-6, 0-7 - ten rungs, 20
  positions (22 before). The test checks every rung's split and first player, each rung one stone more at most, and
  the ladder's ends. Tutorial 5.5's table and text, 11.8, goban outposts' header. Headless: level 1 with two black
  outposts. 88 tests.
- Oct 21: **the fight keeps fighting too** (Simon: in the outposts fights the computer still looks like giving up -
  a white stone on the edge, far from the fight). The decided-position substitution reached only problems (a
  target). `atariFightingMove`: in Atari Go every group is in the fight - a capture when there is one (a win);
  otherwise the legal move filling no own eye that leaves the mover's weakest group the most liberties
  (`weakestLiberties`, capped at 16), ties to the one leaving the opponent's weakest the fewest. `playComputerTurn`
  substitutes `fightingMove` in a problem and `atariFightingMove` in any Atari Go game, for a searched move under 10%
  or over 90%. Test: white's stone in atari runs; black captures. And the page's overlay over Abandon: the web
  platform's failed save is said once per page (`save_failure_logged`, an explained lint:off - the contract's
  `saveValue` carries no state) - in the Claude app's viewer the page has no storage, so the count does not persist
  there; goban's no-worker line is debug (a release page logs info, which the overlay shows). 89 tests.
- Oct 21: **the problems in order of difficulty.** The re-conversion done: 82 sources - easy 18 kill + 8 life, 
  intermediate 22 + 8 (6 rejected), hard 11 + 1 (1 twin only, 7 rejected); 68 families, 54 later starts, 4 twins, 126
  files (17 old files the index no longer listed deleted). `--measure` (`measureDifficulty`): a published problem's
  search in slices of 1,000 to 100,000 iterations, no early stop; its difficulty the iterations after which the
  choice was one of the book's correct first moves and stayed so (100,000 when it ends elsewhere); kept in
  difficulty.tsv beside the problems (`Difficulties`, rewritten after each, skipped when there), about 5 s a problem.
  Medians: easy 3,000, intermediate 6,000, hard 20,000; 6 never settle on the book (1 / 3 / 2). The index's families
  in order of level, then difficulty (the unmeasured last), each with its `name` and `difficulty`, written over
  several lines (zig fmt keeps a trailing-comma literal; the long names fit). `ProblemFamily.name` and
  `.difficulty`; `familyNamed` (at compile time; a missing name fails the build); the tests take easy 01-03 by name
  (`easy_problem_families`), not by place. Next: the hero's rating - a place in this order, a window of a third,
  steps up 3 and down 7 hundredths for 70% first-try success, saved with the outpost level and the count. 89 tests.
- Oct 21: **go puzzles hero's rating** (Simon: 70% of first tries solved; saved with the outpost level and the count,
  the one number shown). `RatingSettings` (step up 0.03, down 0.07 - at rest where 0.7 x 0.03 = 0.3 x 0.07 - and a
  window of a third), `ratingWindow` (a third of the families, in order of difficulty, centred on the rating's place,
  shifted not cut at the ends), `ratedPlace` (a step, within 0 and 1). `HeroState.rating` and `.first_try`: a puzzle
  round draws at random within the window (never the last family again) and the full problem's first end - solved,
  or abandoned or lost - moves the rating; the ladder's later steps, and the full problem again after them, do not.
  `HeroProgress`: the count, the rating (ten-thousandths) and the outpost ladder's position in eight bytes, a version
  first (`toBytes`, `fromBytes`), saved after every change (`saveHeroProgress`: a win, a rating step, a ladder step)
  under `hero_progress_key`; `loadHeroProgress` falls back to the earlier wins-only key. Test: the windows at both
  ends and the middle, the steps and their bounds, the 70% balance, the progress read back. 90 tests.
- Oct 21: **a review; a plan for speed.** Removed: `SearchSettings.target_focus` and `local_reply`, with
  `focusedMove` and `localReplyMove` - measured to give the search nothing; the two arena measures (the search
  against the book; playouts from dead and living positions) kept as benchmarks at the search's own settings.
  `FightingSettings` (below 0.1, above 0.9) out of `ProblemPlaySettings`, held in the state as `s.fighting`: they
  serve Atari Go games as well as problems. The hero's interface doc; SOURCE.md (the batch, the permission, the
  report, the difficulties, the index). Tutorial: 5.6 the frame and the ring (a diagram), 5.8 Rating the player (the
  order, the window, the steps, the 70% rest; a diagram), 8.4 the fighting move. Measured (ReleaseFast): an iteration
  11.3 us on 8 x 8 Atari Go, 18.6 us on a 19 x 19 problem; a position's copy 0.79 us; a playout 15.1 us (21 moves,
  0.73 us a move) and 21.3 us (25, 0.86); per move the urgent scan 0.1 and the random draw 0.14 us, the rest placing
  the stone; one search job at a time. **Speed plan**, by gain over cost: (1) root-parallel search - a job per worker,
  each its own tree, the roots' children merged by move - about the cores' count more iterations where workers run;
  (2) point sets as wide as the board needs - a 361-bit set is six words, an 8 x 8 board's one - for placing stones;
  (3) incremental playout bookkeeping: the empty points and the groups in atari kept by `placeStone`, not scanned
  each move (about a third of a move's cost); (4) copying only the board's points of a position (0.8 to about 0.15
  us); (5) the timing test made a standing arena benchmark first, each step measured against it. 90 tests.
- Oct 21: **speed, step 1 and 2** (Simon: proceed; web workers are weak - so the plan for one core first, the
  parallel search last). The standing benchmark: "arena: the search's speed" - an iteration, a position's copy and a
  playout's move, on 8 x 8 Atari Go (two outposts each) and on easy problem 1. `copyPosition`: every field, but of
  the arrays with an entry a point only the board's points (no code reads past them; the fingerprint hashes the
  board's stones only); a full-size board copied whole, which is quicker than field by field (0.98 against 0.79 us).
  This Zig's struct info: `@typeInfo(T).@"struct".field_names` and `.field_types`, the type `std.lang.Type` -
  `std.meta.fields` is a compile error now. `runIteration` copies with it. 8 x 8: a copy 0.79 to 0.08 us, an
  iteration 11.2 to 10.0 us (runs vary by about a microsecond); a 19 x 19 problem unchanged at 18.5. Next: the three
  settings measured to no gain removed (avoid_self_atari, anti_decisive, solver), then incremental playout
  bookkeeping (the empty points, the groups in atari). 90 tests.
- Oct 21: **anti-decisive moves and self-atari avoidance removed** (both off, measured to no gain - their results are
  in the entries above: anti-decisive 62.5% at equal iterations, 49.5% at equal time; self-atari avoidance 50.7%).
  Gone: `AntiDecisive`, `SearchSettings.avoid_self_atari` and `.anti_decisive`, `isSelfAtari`, `isLosingSelfAtari`,
  `savesGroup`, `savesEveryGroup`, `keepsFromLosing`, `threatenedGroups`; `CandidateKind` keeps `legal` and
  `winning`; `candidateMoves` takes no settings; `randomLegalMove` and `urgentMove` no self-atari flag
  (`randomLegalMove` given its doc). Tests: the self-atari test and five anti-decisive arena tests gone; the
  candidates-one-by-one test now checks the two kinds. The section's lesson loses its anti-decisive paragraph. The
  benchmark unchanged (8 x 8 about 10.3 us an iteration, the problem about 19). Next: the solver. 89 tests.
- Oct 21: **KataGo read for ideas** (Simon: graph search, or anything else - no neural nets; simple and clean, for
  puzzles). Its MCGS (docs/GraphSearch.md): a node's visits and each edge's visits kept apart, a node's Q recomputed
  from its children's Q weighted by its edge visits, nodes shared by position hash; cycles left to game-specific
  handling. Its ladder reader (`Board::searchIsLadderCaptured`): a small depth-first search over a group of at most
  two liberties, the attacker on its liberties, the defender extending or capturing beside it, decided by liberty
  counts, a node budget, kos given to the defender. Measured, at 50,000 iterations: the share of a tree's nodes that
  repeat a position it reaches by another path - 8 x 8 Atari Go 11% (9% of the visits), easy 1 21% (16%),
  intermediate 1 2% (2%), hard 1 6% (5%): graph search would save little while the trees are this shallow - a node
  makes every child before revisiting one. Kept as a standing arena measure ("how many of a search's nodes are
  transpositions"); `familyOf`, a family by name at run time. 89 tests.
- Oct 22: **likely moves first: progressive widening** (step 1 of the KataGo-inspired plan). `nearMoves`: the
  liberties of every group with one or two, either colour's; the empty points around the last move; in a problem the
  target's neighbourhood. `candidateMoves` puts the near legal moves first, then the rest, each in the order of the
  points; `nextCandidate` follows that order from the newest child alone (`firstMovePast`, `firstMoveFrom`,
  `CandidateSide`). `SearchSettings.widening_base` / `widening_growth`: a node may have base + growth x sqrt(visits)
  children (`SearchNode.hasEveryChildAllowed`), its visits going to those it has until it earns another; selection
  goes deeper at a node with every child it is allowed. Measured: the search against the book (17 problems, 50,000
  iterations) - no widening 7/7, 6/7, 3/3 (81 / 60 / 47%), 4 + 1.0 7/7, 6/7, 2/3 (82 / 61 / 45%), 2 + 0.5 7/7, 5/7,
  1/3; iterations until settled on the book's first move - 6,687 without (16 of 17), 3,466 with 4 + 1.0 (15 of 17);
  8 x 8 Atari Go, 1,000 iterations a move, 80 games: widening 59 - 21, 73.8% +- 4.9. Default 4 + 1.0. Iterations
  faster too (deeper trees, shorter playouts): 8 x 8 7.8 us (about 10), the problem 15.4 (about 19). Tutorial 8.9
  Likely moves first. Pages rebuilt. 89 tests.
- Oct 22: **ladder reading** (step 2, after KataGo's `searchIsLadderCaptured`). `ladderCaptures`: a depth-first
  search over a group of one or two liberties - the attacker taking it at one, losing at three, trying the atari on
  each liberty at two; the defender free at two or when a ko was left, at one trying each capture of an attacker's
  group in atari beside it (`ladderDefences`) and the extension - a copy of the position a level from a pool (no
  undo in goban's rules), the pool run out counting the ladder as working, a node budget run out counting the group
  free. `escapeRunsIntoLadder`; `urgentMove` leaves out an escape a ladder captures. `SearchSettings.ladder_reading`
  (on), `ladder_depth` (24), `ladder_budget` (64); the pool allocated by `continueSearch` (none for a problem's
  search) and by `FrameSearch.init`, passed down `runIterations` - `runIteration` - `playOut` - `playoutMove` -
  `urgentMove`. Measured, 8 x 8 Atari Go, 80 games each: 45 - 35 (56.3% +- 5.5) at 1,000 iterations, 47 - 33 (58.8%)
  at equal time (the baseline given 1,480); an iteration 5.6-5.8 to 6.4-8.6 us. In problems: hard 2/3 to 1/3 (45 to
  39%), so a problem's playouts read no ladders. Test: an edge escape the ladder catches, one with room to run.
  Tutorial 8.6. Pages rebuilt. 90 tests.
- Oct 22: **the move chosen by a confidence bound** (step 3, KataGo's LCB). `MoveChoice` (most_visited,
  confidence_bound) and `SearchSettings.choice`, `confidence_stdevs` (3), `confidence_min_share` (0.15);
  `chosenMove`: among the root's children with at least 15% of the most visited one's visits, the highest win rate
  less three standard errors (of a share of the playouts, its rate smoothed by one won and one lost). The computer's
  two searches, the arena's games and the referee choose with it; the tests of the most visited move keep
  `mostVisitedMove`, and so does the converter (its problems were made with it). Arena, 8 x 8, 1,000 iterations:
  46 - 34 on 80 games, 77 - 63 on 140 (55.0% +- 4.2) - small, at no cost: the default. Tutorial 8.4. Pages rebuilt.
  90 tests.
- Oct 22: **the MCTS-Solver removed** (off; measured: 48% at 1,000 iterations, 52.5% at 4,000, an iteration 8.6 us
  against 5.1). Gone: the setting, its lesson paragraph, `Proof`, `provenWinner`, `propagateProof`; selection,
  expansion and the playout's step without proofs; `childWithHighestBound` without its solver flag;
  `searchIsSettled` the forced move alone; `mostVisitedMove` the most visited child's move (`mostVisitedChild`).
  `NodeStatus` gone: `SearchNode.candidate_kind`, `CandidateKind` a byte. The expansion's comment no longer says the
  candidates come in the order of the points. Tests: the solver's two and its arena match gone. Speed: 8 x 8 9.2 us an
  iteration (ladders read), the problem 16.0. Pages rebuilt. 88 tests.
- Oct 22: **the ring's colour from the stones; problems black cannot solve rejected; the ring's liberties hidden;
  Fight.** Simon: a puzzle labelled Live was a kill problem to look at. Cause: the ring was the reading's attacker's,
  so a kill reading of a life problem - black inside white's wall - got a black ring, which enclosed white's wall and
  made it look killable; the kill reading, tried first, was accepted, and a Live round showed its twin. 27 of the 68
  recorded problems had the ring of the colour not facing the open sides (all kill readings, mostly white 9-27 against
  black 0-5: life problems read as kills - hard 01 to 04 among them). `outsideOwner`: along every line in from each
  open side of the stones' box, the first stone met counted; the colour with more owns the outside (a tie: the task's
  attacker); `startProblem`'s ring is its colour. The converter: `solvable_rate` (0.5) - black's search, black first,
  must win at least that for a reading, a later start or a twin to be accepted (hard 01's kill reading had black 15%,
  white first 100%: accepted before for its least bad move being the book's). The liberty display: counts only the
  liberties inside the region (`regionLibertyCount`), labels no stone outside it, draws no ring outside it - a stone
  joined to the ring showed the ring's 23. Go puzzles hero: "Fight" across the top until the player's first move in a
  fight (the record's first or second move, as who starts). Test: easy 1's outside black, easy 4's white. Re-conversion
  of the 82 begun (old report and difficulties kept in /tmp/gb): easy 1 kill pq again; intermediate 1 kill np again;
  hard 1 rejected - as a life problem black's search wins 60-63% but prefers gr to the book's cr (53%). 89 tests.
- Oct 22: **a problem's kind guessed before the search** (Simon: can geometry tell kill from life?). Scored against
  the 98 sources whose comments say whose group lives or dies (49 / 49): the defender's stones closer to the edge
  70%, more grouped 80%, the attacker's facing the frame's open sides 85%; facing and grouping agreeing (80 of 98) 89%,
  disagreeing a coin's toss. In the converter: `kindHint` - `commentsKind` (each colour's name followed within five
  words by a word of life or death counts for that colour; white's fate more often, kill) or else `geometryKind`
  (`goban.outsideOwner`'s defender and the more grouped colour, `stoneSpread`, agreeing), or none. A hint from the
  comments is the only reading tried, one from the geometry the first; with none, kill then life. The two readings
  are functions now (`tryKillReading`, `tryLifeReading`, the inputs read once in `ProblemInputs`); the report has a
  hint column; `--hints` prints each problem's. Over the 422: 101 comment hints (95 of the analysis's 98 alike), 248
  geometry, 73 none. Re-conversion restarted with them: easy 1 kill pq (hint kill); intermediate 1 kill np (hint
  life, the life reading failed); hard 1 rejected (comments: life; the search prefers gr to the book's cr). 89 tests.
- Oct 22: **fewer problems rejected** (Simon: yes - try to avoid rejecting problems). The converter's test, the search
  agreeing with the book, is now `book_holds_up`: one of the book's correct first moves wins at least `solvable_rate`
  (0.5) for black over at least `book_min_visits` (1,000) visits, whatever the search prefers - for the readings, the
  later starts and the twins. A share of the leader's visits (tried first, a quarter) asked too much: the search
  spends most of its visits on its favourite - hard 01's book move cr had 11,966 at 53%. The re-conversion of the 82
  done: easy 7 kill + 19 life; intermediate 15 + 15 + 1 twin only, 5 rejected; hard 8 + 7, 5 rejected (13 of 20
  rejected before the rule) - 71 families, 34 later starts, 23 twins, 128 files (38 left by the earlier rules
  deleted). Difficulties measured again (measure.sh reads each family's `.name` - the multi-line index names each
  twice): medians easy 1,000, intermediate 6,000, hard 100,000 (10 of 15 never settle on the book's move; 6
  intermediate, 1 easy). Pages rebuilt (problems, hero); headless: "Fight" on the fight, the first Live puzzle a black
  group inside white's. 89 tests.
- Oct 22: **go puzzles hero's rounds at random** (Simon: after a fight, kill 2/3 and live 1/3; after live, fight 1/3
  and kill 2/3; after kill, each 1/3). `RoundChances` (a row a kind, in `HeroRound`'s order, held in `HeroState`),
  `nextRound` (a draw from 0 to 1 falling in a kind's share of the row; past the last share, which rounding can
  leave, the last kind with a chance), `drawNextRound` (the clock's seed) where the three ends of a round chose
  `HeroRound.next` (gone). The chain's lasting shares: a quarter fights, a quarter life, half kill. Test: each row at
  chosen draws; 30,000 rounds within 0.02 of the lasting shares. Tutorial 11.8 (and Fight in its top line). Also,
  in the conversion of more easy problems: passes in a book (`isSgfPass`: empty, or `tt` up to 19 lines) end their
  variation in the readers - one source of 422 (easy 44) has one; a problem that cannot be read is reported and the
  run goes on; a published root's own marks are set aside (`withoutRootMarks`) - 3 sources had some. 97 of 140
  easy converted. 90 tests.
- Oct 22: **the corner move** (Simon: in a fight the computer played the corner - why?). Reproduced on the
  screenshot's position, white to play: the search sees it as even (55-65%) and every move alike - the five most
  visited within a percent or two, spread over the board, a different choice every seed (the corner at 20,000
  iterations). A quiet position: no group under three liberties; random playouts cannot tell quiet moves apart.
  `playedMove`, the one place the computer's move is decided (the job and frame searches, the arena, the referee):
  the chosen move (`chosenMove`), unless the search cannot tell it from others - every move of a decided position,
  or the moves whose win rate's range (`close_stdevs` standard errors, `winRateError`) reaches into its
  (`closeMoves`); then the fighting move among those (`fightingMove` and `atariFightingMove` take an allowed set).
  The fighting thresholds are `SearchSettings`' now (`FightingSettings` gone; `playComputerTurn`'s substitution
  gone). On the screenshot: (6,3) in 9 of 12 searches - white extending its weakest group - (2,2) or (2,3) in the
  others. Arena, 80 games each: 41.3% +- 5.5 at two standard errors, 43.8% at one - weaker than the search's own pick
  among equals. Left on (`fights_close_choices`) for the natural play, the ladder absorbing the cost; Simon to decide.
  Pages rebuilt. 90 tests.
- Oct 22: **"Failed"** (Simon: in a kill problem, Failed at the top when the opponent makes two eyes). The hero's top
  line: "Solved" or "Failed" once a puzzle is - Failed when it is lost beyond doubt (`heroPuzzleIsLost`: a kill
  puzzle's group alive by Benson's proof, a life puzzle's captured), with Next beside it. The tutorial's 8.4 folds
  `playedMove` and `closeMoves` (FightingSettings is gone) and tells of the quiet positions; 11.8 tells of Failed.
  90 tests.
- Oct 22: **a paywall to test** (Simon: after two puzzles solved in a session, a window - buy me a coffee to continue,
  a link opening a page in a new tab, a password box; 1234 continues the game). `Paywall` (`AppVariant.paywall`, go
  puzzles hero's `.{}`: two free solves, the message, the link's label and address - https://example.com for now -
  the password); `HeroState.session_solves` (counted where a step is first solved), `.unlocked`, the box's buffer;
  `heroPaywallIsUp`, `submitPaywallWindow` (centred: the message wrapped, `Ui.textLinkOpenURL` - `window.open` in
  a new tab on the web, a tap being a user gesture - and `Ui.inputText` with `password_mask`); the typed text equal
  to the password unlocks the session. While it is up the game waits behind it (both window tests in `updateGame`).
  Found on the way, in ui.zig: `textWrapped` dropped the last word when it did not fit its line ("Buy me a coffee
  to" without "continue") - the word that overflowed waited for the next word's turn to be measured again, and the
  last has none; it now starts the new line. ui.zig's tests have no font (every width 0), so the fix is checked
  headless: the window reads "Buy me a coffee to / continue". 90 tests.
- Oct 22: **the paywall after ten games, its password kept** (Simon: after 10 rounds, failed ones too, to test faster;
  the password once typed, never asked again). `Paywall.free_games` (10): a session's games - every fight and every
  puzzle that ends, won, lost, resigned, solved, failed or abandoned - counted where they end (`HeroState.
  session_games`: a press of Abandon or Next, a fight's end in `restartAfterWin`). The password typed is kept:
  `HeroProgress` version 2, nine bytes, its last a byte of flags whose lowest bit is the password's; version 1's
  eight bytes still read, the password not typed. `saveHeroProgress` on the unlock; `loadHeroProgress` sets it.
  Test: the flag round-trips; a version 1 value reads. 90 tests.
- Oct 22: **every easy problem converted.** All 140 easy sources: 51 kill, 70 life, 2 twins only, 17 rejected (none
  unreadable; the slowest, easy 82, 459 s for a rejection - a 16 x 9 box). With the intermediate 36 and hard 20, 196
  of the 422 sources: 157 families, 343 problem files, every one in the index. Difficulties measured for the 86 new
  families (measure.sh, about 5 s each): easy median 1,000 iterations, 14 easy never settle on the book's move. The
  hero's rating now draws from 157 families, its lowest third almost all easy. Pages rebuilt (hero 6.9 MB). SOURCE.md's
  count. 90 tests.
- Oct 22: **go puzzles hero's debug mode** (Simon: a life puzzle he lived with eyes never said Solved; wants debug text
  for screenshots). A tap on the count of wins (`fixedTapArea`, an invisible button in a window of its own over the
  label, whose window takes no input) shows or hides `heroDebugLines`, drawn under the count: the round, the
  session's games and the moves; the rating and its window; in a puzzle the family's file, level and difficulty, the
  ladder step (start, twin) and kind, the target's point, its group's stones and liberties and whether Benson's proof
  finds it alive, the book followed or left, solved and lost, the computer's last win rate, its gives-up count and
  refuted; in a fight the ladder position. In debug mode the target is marked though the variant hides marks. The
  likeliest cause of Simon's case: the target was another black group than the one he made alive. Headless: the
  lines and the mark on easy 31. 90 tests.
- Oct 22: **problems annotated by eye** (Simon: the conversion is too long; can I read the problems myself?). Found
  first: another session had added to the converter a time cap (`time_cap_seconds`, 180; `OutcomeNote.too_slow`)
  and an early stop for hopeless searches (`hopeless_rate`) - both sound, both used by the intermediate runs since.
  The test of reading by eye: six converted intermediate problems drawn as text diagrams (the stones' box and a line
  more, the board's edges, the book's correct first moves) - four read as the converter had, two capturing races read
  the other way (Simon: a race, living and killing the same moves, is a kill problem). `annotations.tsv` beside the
  problems (a problem's name, kind - kill, live or skip - target in SGF letters, note); `--annotated`
  (`Annotations`, `convertAnnotated`): the annotation's problem marked, no later starts, no twin, one check search
  of 30,000 iterations noted - `annotated` when a book move wins 50% over 300 visits, else `annotated_unconfirmed`,
  kept (in play the book decides; the target matters only off its line); `skip` gives `not_life_and_death` (some
  intermediate sources are opening, attack or shape questions); a target of the wrong colour, `bad_annotation`. The
  index gives a family with no measured difficulty its level's average. The first batch, intermediate 62-76: 3
  confirmed, 8 unconfirmed, 4 skipped, 54 s of searching. 90 tests.
- Oct 23: **an annotated problem's ladder** (Simon: the live and kill chain is the starts along the main line - can
  they be made the same way?). Yes: a ladder needs only its later starts, the twins made in play (`goban.puzzleAt`).
  `convertAnnotated` adds them: every second move of the correct line, kept while the other side, moving first
  there, still wins in one short search (`check_iterations`) - so its twin is a real puzzle; the first that does not
  ends the ladder; a kill problem's written as files too, for goban problems' lists. The first batch redone: 10 of
  the 11 problems with 1 to 6 later starts (intermediate 70 none), 126 s in all. 90 tests.
- Oct 23: annotated batch 2, intermediate 77-91: 14 kill (several capturing races), 1 life (85); 186 s; 5 confirmed
  by the check (78, 79, 80, 83, 88), 10 unconfirmed (the book's move 23-49% in the short search), every one with 1 to
  6 later starts. Two uncertain readings noted in annotations.tsv (77, 80).
- Oct 23: annotated batch 3, intermediate 92-106: all 15 kill (cutting stones, capturing races); 192 s; 2 confirmed
  (93, 101), 13 unconfirmed, every one with 2 to 5 later starts. Five uncertain readings noted. Fixed in
  `convertAnnotated`'s later starts: the correct line's moves stop when the game ends on the way (one problem's line
  captures its target before a later start; placeStone's assert caught the move after the end).
- Oct 23: **every ladder step a problem of its own** (Simon: the chains' problems can all be primary problems; twins
  of hard problems are intermediate, of intermediate easy; we want many problems). `ProblemFamily.first_start`: the
  correct line's moves before the family's first step (0 for a published problem), `familySteps` starting there;
  `familyOf` and `familyNamed` find the published one (`first_start` 0). The converter's index writes, besides each
  published family, one from each of its later starts - its ladder the rest of the line, a level below
  (`derivedLevel`: hard to intermediate, intermediate and easy to easy), at that level's average difficulty - in a
  list of its own, sorted with the published (by level, difficulty, number, name, first start); the kill and life
  lists of files stay the published problems'. The index: 464 families - 222 published, 242 derived; 355 easy, 94
  intermediate, 15 hard. Test: a derived family's ladder starts at its first start, one step for each start on, its
  first step a puzzle; the family found by name is the published one. Tutorial 5.7. 91 tests.
- Oct 23: annotated batch 4, intermediate 107-126 (111, 116-119 left for later in order): 10 kill, 5 life; 185 s;
  3 confirmed (122, 123, 125), 12 unconfirmed; 12 with 1 to 6 later starts, three life problems none. Eight
  uncertain readings noted.
- Oct 23: **the target marked until the player's first move** (Simon: a life puzzle said Failed though he lived). The
  screenshot: his corner group alive, and beside it an empty point inside four white stones - white's last move had
  captured a black stone there, likely the target: a twin of a kill problem about white's cutting stones becomes
  "save black's cutting stones", and with the mark hidden the player saves the plain group instead. go puzzles hero
  now marks the target while the round's kind shows (`heroAwaitsFirstMove`, shared with the top line), and always in
  its debug mode. Headless: the first life puzzle's target square before the first move. 91 tests.
- Oct 23: **trivial puzzles** (Simon: a derived family's twin - four white stones in atari, taken at once - is no
  puzzle; and a trivial step should not stay in the ladders either). Measured first: the converter's `--interest`
  (`PuzzleInterest`, `measureInterest`, `printInterest`) prints, for each problem file, every start's puzzle in the
  book's kind and as the twin: the obvious move (`goban.fightingMove`) and its win rate, the moves that win clearly
  (`clear_rate` 0.8 over `check_min_visits`), the best rate. A rate near a half is the search unsure, not a win: at
  0.5 several published problems read trivial. The rule: trivial when the obvious move wins clearly or
  `max_clear_moves` (3) moves do; a twin, which has no book, also needs a clear winner. On seven problems' 38
  puzzles: the 7 published kept; of the other 31, 10 kept, 18 trivial (most twins: the defender's extra move settles
  the position), 3 unclear. Next: the measure over every problem, the index's steps with what passed, the ladders
  and the derived families from those only.
- Oct 23: **one hard problem's ladder, its puzzles kept and shown** (Simon: the hard problems' chains will hold
  interesting puzzles - take one, do the process, eyeball them, show them in a debug build of goban problems).
  `--interest` now measures every start along a problem's correct line (each second move while black has one left),
  not only the later starts accepted before; `--interest-out DIR` writes each puzzle kept as an SGF file of its own
  (`writeFreshProblem`'s mark now follows the target's colour: a triangle on a white target, a square on a black
  one). Hard 03: 8 puzzles, 6 kept - the published problem, its continuations after 2, 4 and 6 moves, and the twins
  after 4 and 6 (each one clear winner, not the obvious move); the twins after 0 and 2 trivial. Eyeballed: all six
  real choices. The debug page: goban problems built with a temporary list of the six (examples/goban/problems/debug;
  the list and the app's pointer put back after the build), goban_problems_debug_hard03.html. 91 tests.
- Oct 23: **obvious moves, wider** (Simon: a kept twin was too easy - capturing two stones in atari, the obvious
  move, wins). The fighting move weighs only the target's liberties, and those stones bordered another of the
  player's groups. `obviousMoves`: the fighting move, every move that captures stones, every move that saves the
  player's stones from atari by extending them; a puzzle is trivial when the best of them wins clearly. Hard 03
  again: the puzzles after 6 moves, own and twin, now trivial (the capture at 18,6 wins, 82% and 96%); 4 kept - the
  published problem, the continuations after 2 and 4, the twin after 4. The debug page rebuilt with the four.
- Oct 23: **the collection from kept puzzles only** (Simon: the largest possible collection for the hero). The
  measure: `--interest` appends each puzzle's verdict to problems/interest.tsv (a problem's name, start, own or
  twin, kind, verdict, best rate, best obvious rate, clear count), a problem already there skipped; one background
  job over the 237 published problems (one core here: easy problems take seconds, the job ~30 minutes). The
  ladders: `FamilyStart` (the moves before a start, and whether its own puzzle and its twin were kept);
  `ProblemFamily.starts` (the first its opening) and `.kind` replace `first_start` and `later_starts`;
  `firstStart`, `opensWith`; `familySteps` alternates where the flags allow, keeps the same orientation where only
  it was kept, and passes a start with neither. The hero's draw takes the n-th family of the window that opens with
  the round's kind (none: any, opened as it allows). The index: the converter's `ladderStarts` (a measured problem's
  kept starts, the first start's own puzzle always; an unmeasured one's old ladder), derived families from each
  start after the first; the index prints `.kind` and `.starts` (a dropped puzzle's flag the one written; `Start`
  before `Family`). goban read both formats for the one run that rewrote the index. Tests: the alternation from a
  literal family; a dropped twin keeps its own puzzle, a start with neither is passed. 541 families with 97 of 237
  measured. 92 tests.
- Oct 23: the measure done - all 237 published problems, 1,564 puzzles: own 651 kept, 131 trivial; twins 170 kept,
  325 trivial, 287 unclear. The index from every verdict: 676 families (510 easy, 151 intermediate, 15 hard).
  Headless: the hero's rounds draw and play. Tutorial 5.7: the puzzles worth asking (the obvious moves, a clear
  win, a twin's need of one) and the ladders' kept starts, with an example table; `FamilyStart` folded. Pages
  rebuilt (hero, problems). 92 tests.
- Oct 23: annotated batch 5, the last intermediate problems (127-140): 11 kill, 3 life; 219 s; 4 confirmed, 10
  unconfirmed; their puzzles measured (two runs, the second going on from the first), the index again: 733
  families (553 easy, 165 intermediate, 15 hard). Every intermediate problem converted - 280 of the 422 sources.
  SOURCE.md's count. 92 tests.
- Oct 23: annotated hard batch 1 (21-35): 10 kill, 5 life; 181 s; 8 confirmed, 7 unconfirmed; their 152 puzzles
  measured (two runs): 89 kept, 27 trivial, 36 unclear. The index: 806 families (553 easy, 223 intermediate, 30
  hard) - the 15 hard problems gave 73, 58 of them intermediate from their kept steps. 295 of 422 sources
  converted. 92 tests.
- Oct 23: the disk full (the container's writable space ~18 GB, 0.6 GB free; the build's guard refused to
  configure): freed zig-out, .zig-cache/tmp, old file backups in /tmp/gb and ~/.cache/uv (1.5 GB of Python package
  downloads) - 2.6 GB free; .zig-cache itself (7.9 GB) kept. Hero page rebuilt.
- Oct 23: **the scanned collections** (Simon: ingest scrapeGo - Cho Chikun's Encyclopedia of Life and Death, three
  volumes, Gokyo Shumyo, Hatsuyoron; quickly, guessing difficulty). Each book one SGF collection, a variation a
  problem: its stones and "problem N" only - no book, no task, no player (Cho's: black to play). 3,256 problems.
  The converter: `levelOf` reads a name's second word (`cho-easy-0001.sgf`); `--split PATH BOOK STEM`
  (`splitCollection`, `writeSplitProblem`: a source file a problem, SZ 19, PL B, the stones, the book and number in
  its comment) - all five books split into problems/source (cho-easy 900, cho-intermediate 861, cho-hard 792,
  gokyo-hard 520, hatsuyoron-hard 183); `--bookless` (`convertBookless`): the kind the geometry's hint, then the
  other, the target the largest chain of its colour (`largestChain`), kept when its search's best move wins at least
  `bookless_rate` (0.65) and no obvious move wins - a near miss (from `recheck_rate`, 0.5) searched again with
  120,000 iterations; its twin measured too (`clear_rate`, 0.8), both verdicts going with the outcome to
  interest.tsv (`Verdicts`, added under a lock). `unsolved` when neither kind keeps. The index: an unmeasured
  problem not Go Game Guru's guessed from its place in its book (`bookOf`), half to one and a half its level's
  average. On the first 40 elementary problems: 25 kept (14 kill, 11 life; 9 twins kept), 2.5 s each. The volumes run
  in the background: elementary, then a chain - Cho intermediate, Cho advanced, Gokyo Shumyo (Hatsuyoron held
  back).
- Oct 23: **bookless problems, checked two plies deep.** Played out (a temporary arena test, black by a strong
  search, white as the hero's computer), three converted kills ended only after 9 to 25 moves: black's search had
  rated a wrong first move at 100% - in elementary 5 the throw-in at the corner, which white answers by capturing
  three stones and living. The conversion now asks the reply too: `opponentReplyRate` plays the best move
  (`PuzzleInterest.best_move`) and searches the opponent's best reply; above `refute_rate` (0.35) the puzzle is
  `refuted` - for the own puzzle and the twin alike. The converter's best move for elementary 5 was the right one
  (the reply 1%); the check refuted 8's life reading (38%). On the first 20: 13 kept, 4.4 s each. The runs restarted
  from nothing with it - elementary, then the chain (Cho intermediate, Cho advanced, Gokyo Shumyo).
- Oct 23: the machine restarted (up 0 min) and the background runs died with it; the work on disk is whole, every
  run resuming from the report. One script now does every book in turn (/tmp/gb/books.sh: elementary, Cho
  intermediate, Cho advanced, Gokyo Shumyo), started again; to be checked, and started again if gone, each turn.
  Tutorial 5.9, problems without a book: the collection's format, the split, the kind from geometry, the target, the
  search's bar, the reply check, the ladder of one and the end from the position, the difficulty from the book.
- Oct 23: **the collection in the app, balanced** (Simon: failing should bring easy problems quickly, success harder
  ones, first tries 60-80%; the ladder's steps after a failure do not count; the outposts their own level; draws
  from real time, different every play even with the save cleared). Only the full problem's first try moves the
  rating (already so); fights move only the outpost ladder (already so). `RatingSettings`: `window_share` 0.05 and
  `min_window` 20 (the third was 439 of 1,316 families: a rating's moves changed nothing), `max_streak_steps` 3 -
  `ratedPlace` steps down `step_down` times the failures in a row (`HeroState.failure_streak`, reset by a success),
  so a struggling player falls fast. `State.random`: the session's generator, seeded once from the wall clock
  (`Date.now()` on the web), every draw taking its next number - a game's seed, a problem's symmetry, a puzzle's
  search seed, the round, the family, the book's reply (before, each seeded from the millisecond, two draws in one
  frame were the same draw). Tests: the window (66 of 1,316), the steps with streaks; a simulated player (its
  chance falling past its skill, steepness 12) at skills 0.3, 0.6 and 0.9 solves 60-80% of its first tries after
  200 rounds; failing from 0.9, under a half in three rounds. In the converter: difficulty guesses from the level's
  median (the average was pulled up by the problems that never settle - Cho elementary 143 had 11,320, now 659);
  `alternated`'s compile-time allowance grown with its lists. Cho elementary done: 510 of 900 kept (193 kill, 317
  life; 235 twins kept). The hero rebuilt: 1,363 families. The machine restarts even within a turn; the books'
  run is started again whenever it is gone. 93 tests.
- Oct 23: **the window a fifth** (Simon: variability): `RatingSettings.window_share` 0.2 (263 of 1,316 families);
  the simulated players still settle at 60-80%. Tutorial 5.8: the fifth, the failures in a row, the outposts apart.
- Oct 23: **the target's mark only when another group could be meant** (Simon: one group needs no square):
  `targetHasCompany` - another stone of the target's colour in the region, not of its group. Test.
- Oct 23: **the fighting move's order** (Simon: in an outpost fight the computer played on the edge, and earlier in a
  corner): the old rule gave the mover's weakest group the most liberties first - an atari places a stone of two,
  so it never attacked - and broke ties by point order, the first point the top-left corner. `atariFightingMove`
  now: a capture; else the mover's groups kept out of atari (two liberties safe enough); among those the least
  liberties for the opponent's weakest group; ties to the move nearest it (`weakestGroupStone`, `lineDistance`).
  `fightingMove`'s ties go to the move nearest the target. Tests: the screenshot's position - the atari on black's
  two-liberty pair; a quiet position - next to the stone. Arena: still weaker than the search's own pick among close
  moves (38.8% +- 5.4, 80 games), kept for its natural play. Tutorial 8.4. Cho intermediate at about 600 of 861; the
  index 1,511 families; the hero rebuilt. 95 tests.
- Oct 23: Cho intermediate done: 274 of 861 kept (103 kill, 171 life; 70 twins). Cho advanced under way (51 of the
  first 336 kept, about one in six). **The index's crash**: once Cho advanced problems were in the report every
  run's index writing died (SEGV in the fast build; the same data crashed the copy that had written the last index;
  not the stack, no malformed line). Built ReleaseSafe for the diagnosis: index out of bounds inside std's block
  sort, from `writeIndex` - `IndexEntry.before`'s last tie-break read `starts[0]`, meant for the derived families,
  which share a name; the published entries are sorted before their starts are made, and a sort may compare an
  entry with itself, which reaches that tie-break with empty starts. Which comparisons a sort makes depends on the
  data: the new entries changed its path. An entry without starts now counts as starting from the first move.
  build.zig back to ReleaseFast; the background run's copy replaced. The index: 1,641 families (1,063 easy, 497
  intermediate, 81 hard); the hero rebuilt. 95 tests.
- Oct 23: **go puzzles hero's level and row of progress** (Simon: the corner shows wins / 10 + 1; ten black circles
  along the bottom fill with stones, the wins modulo ten, emptying as the level rises - a feeling of progression).
  The count of wins now counts what Simon named: a round's full problem solved at its first try (no longer every
  step first solved, the ladder's easier ones included) and a fight won. `heroLevel` (`HeroLevel`: level, filled),
  `heroProgressRow` (`ProgressRow`: ten places centred between Abandon and Next at the buttons' height, spaced at most
  `progress_spacing_fonts`, a stone nine tenths of a place - `ControlsStyle.progress_places`, `progress_spacing_fonts`,
  `progress_ring_px`), made in the UI pass and kept in `HeroState.progress_row`; `drawHeroProgress` in the board's
  pass: the board's black stone for each filled place, a ring in the line's colour for the rest. Test: the levels
  (0, 9, 10, 23 wins); the row between the buttons on a narrow and a wide window. Headless: level 1 and ten rings.
  Tutorial 11.8. 96 tests.
- Oct 23: **a picture at each new level** (Simon: when the row's last stone is placed, wait 0.5 s, then a random
  picture from a set - Wikimedia Commons' "Humorous cats" - in full screen for 2 s). The 85 pictures scaled to 600
  pixels on the longer side, baseline JPEG at quality 70 (3.2 MB; examples/go_puzzles_hero/cats, SOURCE.md naming each
  file's original; their licences - mostly Creative Commons, many requiring credit - to be seen to before shipping).
  `RewardSettings` (0.5 s, 2 s), `RewardPhase`, `rewardPhase`; `AppVariant.reward_images`, `.reward`;
  `countHeroWin` marks a reward due when a win fills the row; `heroShownLevel` keeps the full row and the old level
  while it is under way; `updateHeroReward` (the picture drawn at random from `State.random`, decoded when it is
  to show, freed after; a picture that will not decode logged as an error); `drawHeroReward` (a black backdrop,
  the picture fitted whole, centred); the buttons and labels not submitted while it shows; the game held
  (`heroRewardIsUp`). `State.gpa` kept for the decoding a frame must do. Found on the way: zimr's
  `loadImageFromMemory` read PNG only (a JPEG gave InvalidSignature) - it now tells a JPEG by its start (FF D8 FF)
  and decodes it with codecs.jpeg, both through `rgba8Image`. The headless check took long: the test trigger had
  been put after `init`'s early return for the hero; an app's log is compiled out below errors in release builds.
  Test: the reward's phases. Headless: the picture at 0.75 s, the game back at 3 s. The hero 11.6 MB. Tutorial
  11.8. 97 tests.
- Oct 23: **the reward's motion and sound** (Simon: the picture comes down from the top in 0.5 s, stays at the
  centre 1 s, goes down and out in 0.5 s, with a clapping sound; for testing, 2 points a level instead of 10).
  `RewardSettings`: `enter_seconds`, `hold_seconds`, `exit_seconds` (`showSeconds` their sum); `rewardOffset` (a share
  of the window's height: -1 to 0 easing out, the cube of what is left; 0; 0 to 1 easing in, the cube of what is
  gone) and `rewardBackdropAlpha` (darkening in, black held, clearing out); `drawHeroReward` moves the picture by the
  offset and fades the backdrop. The sound: the uploaded WAV (3.26 s, 16-bit stereo, 576 KB) cut to 2.5 s with a
  half-second fade and encoded Ogg Vorbis (42 KB, examples/go_puzzles_hero/cheering_and_clapping.ogg);
  `AppVariant.reward_sound`; `StoneSounds` loads and unloads it with the stones' takes (`reward`, `playReward`),
  played as the picture is first shown. `ControlsStyle.progress_places` 2 - TEMPORARY, for testing; 10 to restore.
  Tests: the phases, the offset's ends, eases and hold, the backdrop's alpha. Headless: the picture coming in, held,
  going out; the audio captured a second into the show, -22.7 dB mean (silence would be near -90). Tutorial 11.8. 97
  tests.
- Oct 23: the reward's picture held 2 s (Simon), the show 3 s; the sound cut again to 3 s with its half-second fade
  (51 KB); a level ten wins again (`progress_places` 10). Cho advanced done: 88 of 792 kept (26 kill, 62 life; 12
  twins) - one in nine, the search unsure of most. The index 1,678 families (1,063 easy, 497 intermediate, 118 hard);
  Gokyo Shumyo under way. 97 tests.
- Oct 23: **go puzzles hero's fights on 10 x 10, the outposts placed with care** (Simon: 10 by 10; outposts on the
  second or third line, never on the third line in front of the centre four - a ladder from the start).
  `ScatteredStones` gains `nearest_line` and `farthest_line` (lines from the edge, 1 and 1 by default: the second, as
  before) and `keeps_square_front_clear` (off by default): `isInFrontOfSquare` - level with the square's rows or
  columns at the nearest distance allowed, one empty line between (`stepsOutside`, which goban had). The hero's
  fight: 10 x 10, lines 1 to 2, the front kept clear. Test: the candidates on 10 x 10 - second and third lines, not
  the edge nor the fourth, none of the eight points level with the square; the stones fit. Headless: the fight on
  10 x 10, two outposts on the second line. Tutorial 11.8. Gokyo Shumyo at 87 of 520. 98 tests.
- Oct 24: **moving on, and thicker lines** (Simon: after 5 failures or abandons of the same step, move on; the grid
  lines twice as thick; two kill puzzles he could not solve). `HeroFlowSettings.max_step_failures` (5),
  `HeroState.step_failures`; `heroStepAfter` (`HeroStepMove`): a failure more, at the most the next round; the
  count kept for the same step again - the ladder's bottom, repeated - reset for another, and by a solve. Test: a
  one-step ladder failed five times moves on; a failure down the ladder starts afresh. `BoardStyle.line_px` 2. The
  two puzzles: both have a book move (intermediate 73 after 8 moves: (14,5), which joins black's stones and wins the
  capturing race; easy 49 after 2: (17,12), a placement in the corner). Easy 49's target is wrong: the full
  converter took the largest chain that passed its checks, not the group the book kills - the mark, shown since
  other white groups stand by, points at a group with six liberties. To propose: the target of a problem with a book
  as the chain its correct line captures or leaves with the fewest liberties. Left at easy and intermediate: Go Game
  Guru 17 easy and 19 intermediate rejected or too slow (books - by eye, as before), Cho 390 elementary and 587
  intermediate unsolved by the search. 99 tests.
- Oct 24: **headlines, and no abandoning a fight** (Simon: the level and Live, Fight, Kill a little bigger and bolder;
  an outpost game not abandoned). `fixedHeadline`: the text at `ControlsStyle.headline_scale` (1.25) of the
  interface's size, drawn twice, the second `headline_stroke_fonts` (0.06 of the headline) to the right - the bold of
  a font that has one face; the level, its tap area and the top line use it, the debug lines below it. Abandon is
  shown in a puzzle only (`shows_abandon`); the fight's resignation branch is gone. The check script: the fight, and
  a tap where Abandon stood - the fight goes on. Found while testing: `ggg-hard-24-from-move-7.sgf` had its triangle
  on an empty point (an older run's), failing the test that every problem reads; `convertAnnotated` now checks the
  later start's target as it would be written, and ends the ladder otherwise; hard 24 converted and measured again.
  Also learned: the background run keeps the report and the verdicts in memory and writes them whole - it must be
  stopped before either is edited by hand. Tutorial 11.8. 99 tests.
- Oct 24: **easy and intermediate only** (Simon). Gokyo Shumyo left where it stopped (514 of 520 in the report; the
  index takes in what it converted). The 17 Go Game Guru easy problems the full converter had rejected, read by eye
  and converted the annotated way (their old report lines removed with no background run going): 15 kill, 2 life;
  2 confirmed by the check, 15 unconfirmed; every one with a ladder (1 to 4 later starts); their puzzles measured.
  The index: 1,881 families (1,109 easy, 497 intermediate, 275 hard). The disk full again (97%): zig-out, the cache's
  scratch and old snapshots freed little; .zig-cache (10 GB) cleared - 11 GB free, the converter built cold in 39 s.
  Next: the 19 Go Game Guru intermediate problems rejected or too slow. 99 tests.
- Oct 24: the 19 Go Game Guru intermediate problems the full converter had rejected or run out of time on, read by
  eye: 16 converted the annotated way (15 kill, 1 life; 3 confirmed, 13 unconfirmed; every one with a ladder, up to
  six later starts), 3 skipped as not life and death (58, 60, 61 - whole-board or middle-game positions without a
  plain target). Their puzzles measured - the long ladders in a background process, as a run over 285 s is cut off.
  The index: 1,944 families (1,156 easy, 513 intermediate, 275 hard). Go Game Guru's easy and intermediate problems
  are done: of 280, all but the 7 not life and death are in. Left at those levels: Cho's 977 unsolved by the search.
  Learned again: `pgrep -f` or `pkill -f` with a pattern in the command's own line matches the shell running it - use
  `ps aux | grep '[x]...'`. The lint binary went with the cleared cache (/tmp/gb/lint_path.txt stale); the hero's
  build lints what it compiles. The hero built cold in 200 s. 99 tests.
- Oct 24: **improving the computer: the measure first** (Simon: all the ideas brainstormed but thinking on the
  player's time - measure, keep the tree, spend time where it matters, faster positions, RAVE, priors, ladders in the
  tree, a liberty score for cut-short playouts, patterns, a network, human-like mistakes). The budget is time: 1 s a
  move (`ComputerSettings.move_milliseconds`), so a phone plays with what it runs in a second; the hero's debug lines
  now say where the search runs and the last move's iterations (`lastMoveIterations`), for reading off a phone.
  The curve on go puzzles hero's board (`hero_arena`: 10 x 10, two outposts each on the second and third lines, the
  square's front clear; 30 openings, each twice; `playDoublingMatch`, the same search at twice the iterations):
  1,000 v 500 51.7% +- 6.5, 2,000 v 1,000 51.7% +- 6.5, 4,000 v 2,000 55.0% +- 6.4, 8,000 v 4,000 61.7% +- 6.3. Below
  a few thousand iterations more of the same search buys almost nothing; past them it starts to pay - so at a phone's
  budget, knowledge (RAVE, priors) should count for more than speed. 99 tests.
- Oct 24: **the phone's budget, and the arena's openings.** Simon's phone, in a puzzle: 43,238 iterations in its
  second, on a worker. Keeping the tree between moves was already built (`takeUpSubtree`, `takeUpLastTree`,
  `continueSearch`: the subtree under the moves since, the tree forgotten only for a new game or on an error) - the
  brainstorm was wrong there; only the arena starts each move afresh. One more doubling match: 16,000 v 8,000 50.0%
  +- 6.5; the five together 162 of 300, 54.0% +- 2.9. `playArenaMatch` now counts each opening's pair - won twice by
  the candidate, twice by the baseline, or split - and black's wins: 4,000 v 2,000 split 21 of 30, 1,000 v 500 15 of
  30, black winning 29 of 60. The openings decide most games, not the first move: their random outposts favour one
  colour so much that either setting wins with it, and the pair measures nothing. Next: balanced openings for the
  arena - screened by a long search from the start, kept when it rates them near even - and the curve again; the
  same balance could make the hero's fights fairer. 99 tests.
- Oct 24: **balanced openings tried, and a precise baseline.** A bug found first: `playArenaGame` passed the scattered
  stones' counts and seed but not their placement - the 10 x 10 curve so far had its outposts on the second line
  only; `arenaGameSettings` now passes the whole placement with the opening's seed. A screen by a long search
  (20,000 iterations from the start, kept within 10 points of even) kept 30 of 36 openings and 20 of the 30 still
  split: the search rates nearly every opening near even, and cannot see the imbalance - removed. The splits were read
  too strongly: between equal settings a pair splits half the time by chance, so 65-70% split means about a third of
  the placements decided from the start, not most. The arena measures with more games instead
  (`playDoublingMatch(iterations, opening_count)`): 1,000 v 500 over 400 games, 52.8% +- 2.5 - 131 of 200 split,
  black 217 of 400. The baseline for the ideas to come: an idea worth more than doubling the iterations scores above
  that, at the same budget. 99 tests.
- Oct 24: **RAVE, measured and removed.** Built: `SearchNode.amaf_visits`, `.amaf_half_wins` (the node 28 to 36 bytes);
  `FirstPlays` (who first played each point after a node: the playout writes its moves as they come, the climb back
  writes each node's move over them); `creditFirstPlays` on the way up; `raveBound`, a child's win rate blended with
  its RAVE rate by beta = sqrt(k / (3 n + k)) (Gelly and Silver), plus UCB1's term; `SearchSettings.rave`,
  `.rave_equivalence`. A test: each root child's RAVE count at least its visits, some more; the capture still found.
  Arena, 10 x 10, 500 iterations, 400 games each, against no RAVE: k 1,000 48.5% +- 2.5; k 100 48.3%; k 10,000 45.5%;
  k 1,000 with exploration 0.3 50.0%. No gain, and worse the more weight RAVE gets: in a capture fight a move's worth
  hangs on its order (an atari first, the capture after), which RAVE's "as good later as now" ignores. Removed - the
  bytes it adds to every node travel with each job - its version kept at /tmp/gb/goban_with_rave.zig for now. Next:
  priors. 99 tests.
- Oct 24: **prior knowledge, measured and removed.** Built: `MovePrior` (quiet, atari, double atari, escape,
  self-atari, laddered escape), worked out once when a node is made (`movePrior`: the move played on a copy; the
  escape read for ladders as the playouts read them); `NodeStatus`, the node's packed status byte (the candidate
  kind, 1 bit, and the prior, 3) - the node still 28 bytes; `PriorValues` in `SearchSettings`; progressive bias
  (Chaslot and others, 2008), `priorBias`: the kind's value over the child's visits and one, added to its bound, the
  visits untouched. A test: five diagrams classified. The priors act: of 2,961 nodes from one opening, 548 ataris,
  47 escapes, 41 self-ataris. Arena, 10 x 10, 500 iterations, 400 games: 50.0% +- 2.5, and 50.0% with the values
  doubled. With RAVE at 48.5% and doubling the iterations at 52.8%, tactics are not what holds the computer back -
  the heavy playouts and the near-first widening find them already - but judging quiet positions, where its best
  moves rate alike. Removed; its version kept at /tmp/gb/goban_with_priors.zig for now. Next: the liberty score for
  cut-short playouts (an evaluation idea); ladder reading in the tree set aside, as more tactics. 99 tests.
- Oct 24: **cut-short playouts, and what masked every measure.** `SearchSettings.playout_cutoff` (0, never) and
  `cutShortWinner`: a game's playout that has played that many moves is scored by its liberties - a capture open to
  the player to move is theirs, else the player whose weakest group has more liberties, a tie the player to move's.
  A test: three diagrams scored. Arena (500 iterations, 400 games): after 3 moves 49.5%, 5 49.3%, 10 53.3%, 20
  50.2%, 40 49.5%. Every idea so far within three points of even, so **the arena's controls**: 500 v 50 iterations
  51.7%, heavy v light playouts 49.5% - impossible for a working arena. The cause: `playedMove`'s fighting rule
  (`fights_close_choices`, `fighting_below_rate`, `fighting_above_rate`), on by default, plays the pressing rule's
  move instead of the search's whenever the top moves are within their confidence of each other or the position is
  decided - with this search's flat ratings, most moves - so both sides play the same rule whatever their search.
  With the search's own choice every move (the rule off on both sides): 500 v 50 78.3% +- 2.1, heavy v light 83.3%
  +- 1.9. So today's doubling, RAVE, priors and cut-offs measured the rule against itself, and must be measured
  again with the rule off; RAVE's and the priors' versions are kept at /tmp/gb/goban_with_rave.zig and
  /tmp/gb/goban_with_priors.zig. And in the apps the computer plays mostly the pressing rule: its search barely
  shows - the largest lever for a stronger opponent. 100 tests.
- Oct 24: **what the fighting rule costs.** Counted in 50 games (10 x 10, 500 iterations, the defaults): of 1,112
  moves, 417 (37.5%) the pressing rule's instead of the search's - 214 of the 380 in decided positions, 203 among
  close choices; never, in a won position, a move rated under a half. Arena, 400 games each, against the search's
  own choice (`own_choice`: no fighting rule): the rule as shipped 14.0% +- 1.7 (it was 38.8% on 8 x 8); fighting
  the decided positions only 25.8% +- 2.2; the close choices only 32.0% +- 2.3. And doubling on the search's own
  choice, 1,000 v 500: 59.5% +- 2.5 (52.8% with the rule) - more search pays once the search decides. The rule was
  kept for natural play at a cost the outpost ladder absorbs; on 10 x 10 that cost is most of the computer's
  strength. To decide with Simon: drop it in Atari Go, keep it, or a milder version. 100 tests.
- Oct 24: **the fighting rule, reviewed and made strict** (Simon: only when it is certain the game is lost - an
  abandon - or to prevent a weird tenuki far from the fight; it must not change the score). The review, over 50
  games: of 203 overrides among close choices, the played move was on average 12.4 points worse, 116 more than 10
  worse - the two-standard-error ranges at a few hundred visits admit clearly worse moves, and the pressing rule reads
  the position, not the ratings; of 214 in decided positions, 164 were in won ones (chosen over 90%), the played move
  16.2 points worse on average, 91 more than 10; the 50 in lost ones (under 10%) cost nothing - none of those sides
  won. Now (`playedMove`): a lost position, the chosen move under `lost_below_rate` (5%), the fighting move among all;
  a tenuki between equals - the chosen move more than `tenuki_lines` (4) from the fight (`isTenuki`: a problem's
  target, or each player's weakest group) and a move near the fight within `equal_rate_margin` (2 points) with at
  least `equal_min_share` (half) of its visits (`equalMovesNearFight`) - the fighting move among those; else the
  search's choice. Won positions never; `closeMoves`, `fighting_above_rate`, `close_stdevs`, `fights_close_choices`
  gone; `own_choice` is `{ lost_below_rate 0, fights_tenuki false }`. Arena: the strict rule against the search's own
  choice 52.0% +- 2.5 - no score change; it acts in 74 of 1,015 moves (50 lost, 24 tenukis replaced; 69 more tenukis
  kept, no move near the fight as good). The computer in the apps is now the search's strength: it beat the old rule
  86% of the time, so the outpost ladder will move toward the person. Lint caught last turn's cut-short code
  (`cutShortWinner` before `playOut`, now using goban's own `weakestLiberties`). Tutorial 8.4. 100 tests.
- Oct 24: **the ideas measured again, with the strict rule** (Simon: keep improving the computer, and make it look
  human where that costs nothing). Cut-short playouts at equal iterations: after 10 moves 52.0% +- 2.5, after 20
  48.3%. Their speed (5 hero openings, 40,000 iterations each): 9.30 us an iteration to the end, 4.93 cut short
  after 10 - 1.89 times as many; at equal time (945 against 500 iterations) **61.5% +- 2.4**. So
  `SearchSettings.playout_cutoff` is 10 by default, for games only. The priors built again (as before) and measured
  against the new defaults: 50.2% +- 2.5 at equal iterations, with a cost at every expansion - removed again. RAVE
  not built again: its trend was down with more weight, and the reason - a capture fight's moves hang on their
  order - holds whatever the arena. Next: spending time where it matters - quick on obvious moves, longer on
  close ones - the most human of the ideas, and measured for strength. Tutorial 8.6: the cut-short playouts. 100
  tests.
- Oct 24: **why the computer played on the edge** (Simon's screenshot: white's stone alone on the last line, the
  fight on the left). The position from the screenshot, searched as on his phone (40,000 iterations): nearly every
  move rated 65-67% - the edge move (6,9) the most visited - and the tenuki rule's "near" too loose: 4 lines from a
  weakest group's root stone, so it swapped (6,9) for (4,9), another edge move; and its half-the-visits rule shut out
  (4,2), beside black's weak group, a point lower on 3,950 visits. The strong move, white (3,2) - a net on black's two
  stones with two liberties, 75% - one search in three; with playouts to the end, six in six. The 10-move cut misses
  it: a net takes more moves to end in a capture than the cut leaves, and the position then looks quiet. Tried, a
  quiet moment for the cut: at every move past it (11.62 us an iteration, slower than to the end), then once, at
  move 10, with at most 10 more (7.33 us, 1.31 times as many as to the end, against 1.81 for the plain cut) - the
  bounded one lost 41.8% +- 2.5 to the plain cut at equal time; removed: on average the plain cut's speed is worth
  more than its sight of nets. The tenuki rule tightened instead: near is within 2 lines of any stone of the fight's
  groups (`isTenuki` walks the board, each stone's root), and an equal move needs a quarter of the chosen's visits:
  52.8% +- 2.5 against the search's own choice - no change in score; in the screenshot's position four of six
  searches now play beside the fight, against one. A 3-point margin: 52.3%, and no change there - kept at 2.
  Tutorial 8.4. 100 tests.
- Oct 24: **why the search missed the net, and a flaw in the cut** (Simon: why not the moves that ensure victory -
  sure of winning whatever it played? a bug?). The net (3,2) in the screenshot's position, per search (40,000
  iterations): made 35th of 79 candidates every time - early enough; with the cut, 87-152 visits at 47-53% against
  the quiet moves' 66%, so the search stopped spending on it before the tree could read it; with playouts to the
  end, 6,700-9,800 visits at 75%, chosen every time. And with the cut and no widening, (4,2) rated 85% against 65%
  with it: ratings swinging with the tree's shape. The flaw: a cut-short tie went to the player to move, and a
  playout always stops after the same number of moves, so that player alternates with the depth of the node it
  began from - ties tilted a move's rating by how deep the tree under it reached. Now `CutTie` (`cut_tie`): `.half`,
  undecided, half a win each, by default; `.player_to_move` the old rule. Half against the old rule: 52.3% +- 2.5.
  In the position, all six searches now choose (6,6) at 69-71% - pressing black's central group of three
  liberties - where before each chose differently, edge moves among them; the net gets thousands of visits in three,
  at 69% (still under the 75% of playouts to the end: the cut cannot see its capture). And the fight for the tenuki
  rule is now every group of either player with at most `fight_liberties` (3) liberties - the groups under
  pressure - or, with none, the weakest of each: (6,6) is no tenuki then, and played in all six; the rule against
  the search's own choice 51.2% +- 2.5. Tutorial 8.4 and 8.6. 100 tests.
- Oct 24: **a deep review of the search** (Simon: review the critical parts again - maybe other bugs; then a new
  screenshot, the computer in the corner again). Read line by line: the exploration term (c sqrt(ln N), over sqrt n:
  UCB1), the bound, the smoothed standard error, the confidence-bound choice (best lower bound among children with
  15% of the leader's visits), the widening (base + growth sqrt(visits); growth 0 every candidate first), the
  candidate order (`candidateMoves`: near then far, each in point order) against `nextCandidate`, the random move
  (uniform: drawn from the empty points, struck, drawn again) - sound. A test now walks the candidates one after
  another from 600 positions (20 hero openings, 30 random moves each) and finds the whole list in its order. **A bug
  found:** goban's menu offers capture goals 1, 3 and 5, and the cut-short playouts - whose score assumes the first
  capture wins and knows no prisoners - ran in all of them; now only where the goal is one capture. The corner move
  (the screenshot rebuilt, white to play): the top moves corners and edges - (8,9), (0,0), (8,0), (9,8), (1,8) at
  about 62% cut, 69% with playouts to the end - so not the cut, nor a bug: in a standoff random playouts rate a move
  that touches nothing a few points above one in contact, which gives the reply the first chance at the new
  contact. Local answers (MoGo: half the random moves from the 3 x 3 around the last move, `localRandomMove`) moved
  the choice to the second line, still away, and lost 45.5% +- 2.5 - removed. The tenuki margin raised to 4 points,
  about two standard errors of a difference at a second's visits: in the corner position all six searches play in
  the fight ((3,4), (5,3), (6,3), 2-3 points under the edge move); against the search's own choice 52.5% +- 2.5.
  Left to look at again: the measurements made with the old fighting rule on - the exploration constant, widening,
  the confidence bound, ladder reading - each may have been masked. Tutorial 8.4. 101 tests.
- Oct 24: **attack or defend** (Simon: whenever the computer thinks it has won or lost, or no move near the fight is
  good, attack the opponent's weakest group or defend its own). `atariFightingMove` rewritten: a capture wins; else
  the two weakest groups compared - the mover's own weaker, it defends (the move leaving its weakest group the most
  liberties), else it attacks (the opponent's weakest the fewest, its own kept at two liberties or more); ties to
  the move nearest the group fought over, to its nearest stone (`groupDistance`). `playedMove`: lost (under 5%) -
  among all moves (`everyRootMove`); won (over `won_above_rate`, 95%) - among the moves still rated above it, with a
  quarter of the chosen's visits (`movesStillWinning`); a tenuki - an equal move near the fight, or with
  `attacks_after_tenuki` the fighting move among all moves. Against the search's own choice (400 games): 52.3% +- 2.5
  with the tenuki's fallback, 52.0% without. In 50 games it changes 172 of 1,074 moves: lost 49, won 33, a tenuki for
  an equal move 45, for the attack or defence 45. The two screenshots' positions: (6,6) pressing black's central
  group, and (5,3) or (6,3), white's weakest group out of danger - never the corner. Tutorial 8.4. 101 tests.
- Oct 24: **a least time for a move, and the exploration constant measured again** (Simon: wait at least 0.5 s
  before playing, even when the winning move is found sooner; keep improving the computer). `ComputerSettings.
  min_move_milliseconds` (500): a move found sooner - a forced one after one iteration - is held
  (`ComputerPlayer.held_move`) until then; `finishMove` ends a turn; `stopSearch` lets a held move go with the
  search. The settings measured while the old fighting rule masked the arena, again with the search's own choice
  (`playSettingMatch`, 10 x 10, 400 games at 500 iterations): exploration 0.3 v 0.6 **60.3% +- 2.4**, 1.0 v 0.6
  47.5%; 0.2 v 0.3 54.3%, 0.1 v 0.3 52.5%; and at 2,000 iterations (200 games) 0.2 v 0.6 **69.5% +- 3.3** - so
  `exploration` is 0.2. Widening, the confidence-bound choice and ladder reading (an earlier test, the strict rule
  on): no widening 17.0% (28.7% with the search's own choice), the most visited move 50.2%, no ladder reading
  40.8% - widening and ladders kept, the confidence bound kept as the safer choice. The fighting rule against the
  search's own choice at 0.2: 50.5% +- 2.5. Tutorial 8.2. 101 tests.
- Oct 24: **shorter playouts, and a finer score** (Simon: continue trying things). Measured with the search's own
  choice at exploration 0.2, 400 games at 500 iterations: the widening's growth 0.5 51.7% against 1.0, 2.0 35.5% -
  kept at 1.0. The cut-off: 6 v 10 61.0%, 15 v 10 39.8%; 3 v 6 57.8%, 4 v 6 54.8%; 2 v 3 58.8%, 1 v 3 56.0%; at
  2,000 iterations 2 v 10 **78.0% +- 2.9** - `playout_cutoff` is 2: the tree does the reading, a playout's random
  moves only blur what the score sees; an iteration about 3.5 us against 9.3 to the end. With playouts that short
  the score decides nearly everything, and comparing only the weakest groups called most quiet positions even:
  `cut_groups_compared` (3) - each player's weakest groups compared in order, the weakest first, a tie broken by the
  next (`weakestLibertyCounts`; a missing group counts as unbounded): 3 v 1 **57.8% +- 2.5**, 4 v 3 51.2%. The
  first screenshot's position under them: the net (3,2) now rated 30-34% even at 120,000 iterations, the choice
  (7,2) - and rightly, read again: black's two stones escape by (4,2), joining (5,1)-(5,2), while white's own
  (5,3)-(6,3) has three liberties, (7,2) one of them; full playouts had liked the net only because their random
  black never found (4,2). Tutorial 8.6. 101 tests.
- Oct 24: **exploration again, and two playout ideas that lost.** With playouts cut after 2 and three groups
  compared (the search's own choice, 400 games at 500 iterations): exploration 0.1 v 0.2 42.8%, 0.3 v 0.2 53.8%,
  0.4 v 0.3 47.5%, and at 2,000 iterations 0.3 v 0.2 53.5% of 200 - `exploration` 0.3: ratings nearer even need a
  larger term to tell the moves apart. Urgent-only playouts (`PlayoutKind.urgent`: captures and rescues to the first
  quiet moment, then the score - a quiescence search): 46.5% at a cap of 4 moves and of 10 - removed; the two random
  moves add something, averaged over many playouts a few plausible continuations judged rather than one frozen
  position. The confidence bound's width: 1.5 standard errors 47.0%, 5 50.5% - kept at 3. A test failed on the new
  exploration: "a search in the frames makes the tree one job of as many iterations makes" compared the frame
  search's move with the job tree's most visited move - but the move played is `playedMove`'s, the confidence bound
  and the fighting rule, not always the most visited; it now compares with `playedMove` from the job's tree, the
  trees themselves still equal node for node - no bug in the search. Tutorial 8.2. 101 tests.
- Oct 24: a turn got stuck while condensing the arena (it removed the experiments whose results live in the
  settings' docs and the journal, leaving 9 tests, among them "today's search against this morning's, at equal
  time"); what it left compiled and passed, and is kept. **The hint, and no Abandon** (Simon: remove the abandon; a
  hint button after a problem is failed 3 times, showing the book move or the best computer move as a blue dot for
  0.5 s). `HintSettings` (after 3 failures, 0.5 s, a search of 3,000 iterations) in the hero's state;
  `HeroState.round_failures` - every step of the round's problem counts, reset with the round, since a failed step
  moves down the ladder and the same step seldom fails three times in a row; `heroHintMove`: the book's first
  correct move after the moves so far (`repliesAfter`), else the search's choice for the player (`chosenMove`); the
  Hint button in Abandon's place, its press marking the hint due and the next frame stamping its time;
  `BoardStyle.hint_color` and `.hint_dot_spacings`, the dot drawn with the board's marks. Abandon gone, in puzzles
  too - a puzzle is played to its result, and five failures in a row move the round on. Headless (a temporary start
  in a life puzzle failed three times): the button, the dot after a tap, gone 0.7 s later. Tutorial 11.8. 101
  tests.
