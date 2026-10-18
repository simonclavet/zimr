# goforest - the C++ original of `goban`

`goban` (`../goban.zig`, not written yet) is a port of this program. These files are a frozen copy, kept beside the
port so its comments can cite `goforest/main.cpp:432` and the two can be read side by side. zimr never builds them:
every build and lint walk over `examples/` takes `.zig` files only.

- **Source**: `C:/dev/tests202601/goforest/` on Simon's machine, files dated Apr 12-14 2026, copied Oct 18 2026.
- **`main.cpp`** - the whole program, 1578 lines: the disjoint-set engine, layout, drawing, the ImGui menus.
- **`math_utils.h`, `utils.h`** - shared helper headers. `main.cpp` uses only `Max`, `MinInt`, `MaxInt`, `Saturate`,
  `SmootherStep` and the double spring damper from `math_utils.h`, and `assert` through `utils.h`.
- **`CMakeLists.txt`** - how it was built: raylib 5.5, imgui master, rlImGui main, C++20, MSVC `/W4 /WX`. It expects
  `src/` and `data/`; here the sources are flat and the textures sit one level up, renamed:

      data/b.png    -> ../black_stone.png
      data/w_1.png  -> ../white_stone.png
      data/wood.png -> ../wood.png

- **`goforest_notes.md`** - the project's own `CLAUDE.md`, renamed. Claude Code loads any file named `CLAUDE.md` as
  instructions for the folder it sits in, and these ("don't write code unless specifically asked to", the C++ style)
  belong to the C++ project, not to the port.

The plan for the port: `src/notes/goban_plan.md`.
