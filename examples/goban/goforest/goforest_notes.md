# Goforest (Gogus) - Go Board Game

## Project Overview
A Go board game built with raylib, imgui, and C++20. Originally written in French by the user's kid as a programming exercise, then rewritten in English with proper Go rules. The goal is to build a real Go program step by step, as a recreational coding project.

## Build System
- **CMake** (minimum 3.21), **C++20**, **Visual Studio 2022** on Windows
- Dependencies fetched automatically via FetchContent (no manual downloads)
- raylib uses `FetchContent_MakeAvailable`, imgui/rlImGui use `FetchContent_Populate` (they have no CMakeLists.txt)
- imgui and rlImGui both track latest master/main (they're tightly coupled)

### Build Commands
```bash
# Configure (run configure.bat, or):
cd build && cmake -G "Visual Studio 17 2022" -A x64 ..

# Build Debug
cmake --build build --config Debug

# Output: build/Debug/Gogus.exe
```

### Reconfiguring
If FetchContent gets confused (stale caches after path changes), delete `build/CMakeCache.txt` and `build/_deps/*/CMakeCache.txt`, then reconfigure. Don't delete the whole build dir if VS has the solution open.

## Code Style (same as Flomo)

- Prefer `int` as the main integer type (don't warn about size_t to int conversions)
- Use `float` for all floating-point values (add `f` suffix to literals: `1.0f`)
- Be const-correct for pointer/reference parameters, function results, and local variables
- When possible initialize variables directly in struct definitions
- Don't use default values for function parameters
- Function names are CamelCase, variable and member names are camelCase. constexpr for CONSTANTS
- Don't use auto unless it replaces a gigantic mess (more than 80 characters)
- Don't use lambdas unless for extremely small simple things
- When an argument is modified as the result, prefix with `/*out*/` or `/*inout*/`
- Never modify non-const value arguments of functions
- Don't use pairs and tuples, make small structs instead
- Don't use smart pointers
- Keep lines under 120 characters
- Place arguments on separate lines when there are more than 4 or they don't fit in 120 chars
- Don't use complicated OOP (inheritance, polymorphism) unless absolutely necessary
- Don't use exceptions. Use assertions defensively. No noexcept, catch, try unless necessary
- Use linebreaks before opening braces for functions and control blocks
- Always use braces for if/for/while
- When writing comments, be casual
- Use structs only, no private/public unless we really want to
- Use `if (ptr != nullptr)` instead of `if (ptr)`
- Prefer long functions for important logic over hiding it behind single-use helpers
- Keep things simple. Flag opportunities to remove abstractions and dead code
- Don't create unused variables
- Don't use goto. Prefer a `bool skipX` flag pattern for early-outs: set the flag in separate `if` blocks, then check `if (!skipX)` for the main logic. This avoids deep nesting, goto, and do-once loops.
- Don't use ternary operators for load-bearing logic where you might want breakpoints. Use explicit if/else instead. Ternary is fine for simple value picks like colors or display strings.
- Ask questions if unsure about anything

## Compiler Warnings Policy
- Warnings as errors (`/WX`)
- Warning level 4 (`/W4`)
- Suppressed: 4100 (unused params), 4267 (size_t to int), 4018 (signed/unsigned), 4505 (unreferenced static)
- Third-party imgui sources compiled with `/W0`

## Collaboration Mode: Tutorial

The user wants to code this himself as a recreational project. When working on game logic:

- **Don't write code** unless specifically asked to. Instead, describe what to change step by step.
- Keep steps very small.
- Don't go to the next step until the user says they're done and you've verified the change.
- Give enough hints that the user doesn't have to think hard, but don't give actual code lines.
- Make it very easy and fun.
- Be casual.

Exception: boilerplate, build system changes, and non-game-logic tasks can be done directly.

## Current State

### Implemented
- Configurable board size (3-19), with presets for 9, 13, 19
- DSU (Disjoint Set Union) engine for efficient group/liberty tracking
- Full Go rules: capture, suicide prevention, simple ko
- Atari Go mode: first to capture N stones wins (1, 3, or 5), with starting cross pattern
- Undo/redo via move history replay (side mouse button for undo)
- Main menu, pause menu (ESC), victory screen
- imgui UI with 2x font scale
- Debug overlays (toggle H): group roots, liberties, atari highlights, doomed stone preview
- Ghost stone hover preview, capture count display on board sides
- Star points (hoshi) with sensible placement for all board sizes
- Smooth resize via GLFW window size callback (chains raylib's callback)
- Board centered in window with 10% margin

### Key Types
- `Stone` (alias for `char`) - stone color: STONE_NONE, STONE_BLACK, STONE_WHITE
- `BoardIndex` (alias for `int`) - 1D board index (row * boardSize + col), INVALID_INDEX for none
- `GameState` - board + DSU arrays + ko + captures + move history
- `AppOptions` - display toggles (debug, doomed stones, liberties, atari groups)
- `AppState` - wraps GameState + AppOptions + screen state + atari go settings

### Architecture
- Board uses 1D indexing via `Index1D(row, col)`, `RowFrom1D(id)`, `ColFrom1D(id)`
- DSU: `groupRoot`, `groupLiberties` (unordered_set), `groupStones` (vector) per intersection
- `PlayMove` handles placement + liberty update + merge + capture + ko in one call
- Undo works by replaying all moves from scratch (cheap for human games)
- Screen flow: SCREEN_MAIN_MENU -> SCREEN_GAME (with optional pause overlay)

### Possible Next Steps
- Pass move
- Scoring
- MCTS AI engine
- Better board rendering (wood texture, stone shadows)
