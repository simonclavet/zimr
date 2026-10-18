# goban - porting `goforest` (C++/raylib/imgui) to a zimr example

**Status: FINAL (Oct 18).** Decisions D1-D8 are decided and Simon agreed with the whole final list (10.1). The
example folder is prepared with the C++ reference (`examples/goban/reference/`) and the textures; nothing is
implemented, and nothing will be until Simon says go.

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
| `SmootherStep` | `zm.smootherstep`, bound bare as `smootherstep` | in zm (D7, 8.7) |
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
| `SmootherStep`, the spring dampers | `zm.smootherstep`, `zm.DoubleSpring(T)` - **new in zm** (D7, 8.7); today zm has only `smoothstep`, and `u.spring` is a UI animation keyed by label |
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
| D6 | **C - decided** (the exemplar's style, fresh names) | Recommended was A (source names kept); Simon chose names picked anew. Section 3.1 proposes them, and a short goforest -> goban table in the file's header keeps side-by-side reading possible. |
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

Comments in `goban.zig` cite the original as `goforest/main.cpp:NNN`.

**`test-goban`**: a test artifact built from the example's own module for the host (as the `bmpc-cartpole` step
builds one), running the tests at the end of `goban.zig`. Zig analyses only what the tests reference, so the rules'
tests compile the rules, not the renderer; the first run at S6 confirms that and measures the time.

### 8.2 Types

```zig
pub const max_board_size: usize = 19;
pub const max_points: usize = max_board_size * max_board_size; // 361
pub const max_recorded_moves: usize = 1024;
pub const Point = u16; // a 1D index: row * board_size + col (goforest's BoardIndex)
pub const PointSet = std.bit_set.StaticBitSet(max_points);
pub const SetupStone = struct { point: Point, stone: Stone }; // the Atari Go cross: on the board, not a move

pub const Stone = enum(u8) {
    none,
    black,
    white,

    pub fn opponent(self: Stone) Stone { ... } // asserts self != .none
};

pub const Neighbors = struct { points: [4]Point, count: u8 }; // up, down, left, right, as goforest

/// What is on the board now. Rebuilt by replay; everything here follows from the record.
pub const Position = struct {
    board_size: u8,
    stones: [max_points]Stone,
    /// The forest. A stone's parent in its group's tree; a root is its own parent; null on an empty point.
    group_parent: [max_points]?Point,
    /// Meaningful at a root only: the group's liberties, and its stones.
    group_liberties: [max_points]PointSet,
    group_stones: [max_points]PointSet,
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
    setup: [max_points]SetupStone, // the Atari Go cross, a pasted position, or nothing
    setup_count: u16,
    setup_to_play: Stone,          // whose turn after the setup: black, unless a pasted diagram says white
    moves: [max_recorded_moves]Point,
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

pub const Legality = enum { legal, off_board, occupied, ko, suicide, game_over };
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

### 8.7 The engine addition: `zm.smootherstep` and `zm.DoubleSpring` (D7)

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

Minor defaults, confirmed with the final list rather than asked: gallery stars 3; window 900 x 900 to start; title
"zimr - goban"; 1024 recorded moves, refusing the 1025th with a message; goforest's timings, alphas and colours.

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
6. **D6** - the exemplar's style; the fresh names of 3.1; a short goforest -> goban table in the file's header.
7. **D7** - `zm.smootherstep` (vector `x`, scalar edges) and `zm.DoubleSpring(T)` in zimrmath (8.7, stage E2), with
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
- Oct 18: **D7 decided - into zm now** (not the recommended local copy). Section 8.7 designs `zm.smootherstep`
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
