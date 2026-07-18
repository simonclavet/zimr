# Debugging zimr examples in VS Code

`.vscode/launch.json` ships 26 debug configurations — one per example
plus a "gallery" entry that opens the picker.  Pick any of them from
the Run/Debug panel and hit F5.  VS Code will:

1. Start `zig build serve` as a background task (if not already running).
2. Wait for the server to log `Ctrl+C to stop` (i.e. port 8000 bound).
3. Run `zig build` to rebuild any `.zig` files you've edited.
4. Launch a fresh Chrome instance pointed at the example's host page.

Set breakpoints in `.zig` source, edit values in the `Variables` panel,
walk the call stack, and use the debug console — all of it works
because the wasm has DWARF symbols embedded.

## Required extensions

Listed in `.vscode/extensions.json`; VS Code will prompt you to install
them when you open the workspace.

| Extension | Purpose |
|---|---|
| `ms-vscode.js-debug` | Built-in JavaScript debugger.  Drives Chrome via the Chrome DevTools Protocol. |
| `ms-vscode.wasm-dwarf-debugging` | Decodes the DWARF custom sections embedded in our debug-mode wasm, so wasm offsets map to `.zig` source lines.  Without this, breakpoints in `.zig` files don't catch — VS Code would only see the wasm as a flat blob. |
| `ziglang.vscode-zig` | Syntax, formatter, ZLS integration. |

## How DWARF debugging works in this setup

The official Zig toolchain (0.16) emits DWARF v4 in `.debug_*` custom
sections of the wasm whenever you build in **Debug** mode.

`zig build` requires `-Dmode=...` (no default).  Three modes are
valid:

- `-Dmode=debug` — Debug optimize, all asserts on, DWARF emitted.
  **Use this for VS Code debugging.**  All `.vscode/tasks.json`
  entries pass it.
- `-Dmode=release` — ReleaseSmall optimize, only
  the asserts declared in `src/assert.zig` survive (Zig stdlib
  safety stripped).  Used by `release.bat` and
  `scripts/build_standalone.py` so prebuilt Pages artifacts still
  trip our own assertion macros.
- `-Dmode=release-no-zimr-asserts` — ReleaseSmall with everything
  stripped.  Reserved; no caller uses it today.

A typical Debug `basic.wasm` is ~1.5 MB with these sections:

```
.debug_loc        244 KB
.debug_abbrev       2 KB
.debug_info       325 KB
.debug_ranges      37 KB
.debug_str        140 KB
.debug_pubnames    41 KB
.debug_pubtypes    85 KB
.debug_line       268 KB
```

`ms-vscode.wasm-dwarf-debugging` is a port of Chrome DevTools' DWARF
parser packaged as a Node module that `vscode-js-debug` can call into.
When you set a breakpoint in a `.zig` file:

1. VS Code asks the DWARF extension: "where in this wasm is line X
   of this file?"
2. The extension scans `.debug_line` and returns one or more wasm
   offsets.
3. VS Code sets a breakpoint at those wasm offsets via CDP.
4. When the wasm reaches that offset, Chrome pauses and reports the
   stop event.
5. The DWARF extension translates wasm locals back to Zig variable
   names using `.debug_info`.

DWARF source paths are absolute paths from the build host, so debugging
works "out of the box" only when the wasm was built on the same machine
where you're debugging.  For build-on-A-debug-on-B you'd need to add
`pathMapping` entries to `launch.json` — not relevant for typical local
development.

## Tasks

`.vscode/tasks.json` defines the supporting tasks:

- **`zig: serve (background)`** — runs `zig build -Dmode=debug
  serve`.  Marked `isBackground: true` with a `problemMatcher`
  whose `endsPattern` matches the server's "Ctrl+C to stop" line,
  so VS Code knows when the task is "ready" (= port bound) and
  can move on.  Reused across launches via `instanceLimit: 1`.
- **`zig: build (debug)`** — `zig build -Dmode=debug`.  Depends on
  the serve task so the first F5 brings up both, subsequent F5s
  reuse the running server and just rebuild.  Default build task
  (Ctrl/Cmd-Shift-B).
- **`zig: build (release)`** — `zig build
  -Dmode=release`.  Useful for size/perf
  comparisons; not used by any launch config.
- **`zig: test`** / **`zig: smoke-test`** — both pass
  `-Dmode=debug`.  Wired into VS Code's test runner so
  Ctrl/Cmd-Shift-P → "Run Test Task" works.

## Workflow

**First launch (cold):** F5 takes a few seconds.  The serve task
starts `zig build serve`, which compiles every example wasm in
Debug mode and bundles `zimr.js`, then starts the Bun dev server.
Once the "Ctrl+C to stop" line prints, the build task runs (cached
no-op), and Chrome launches.

**Subsequent launches:** F5 is fast.  Server is already running;
build task is a cached no-op; Chrome window opens within ~1 second.

**After editing a `.zig` file:** *Hot reload* takes care of it.
The dev server watches `examples/`, `src/`, etc., and on save it
spawns `zig build`; on success it sends a WebSocket message that
calls `location.reload()` in your already-open page.  vscode-js-debug
reattaches breakpoints across the reload — same flow as a manual
Ctrl+R during a debug session — so you can keep your debugger window
focused, edit Zig, save, and watch the new wasm step into your
breakpoints.  Typical turnaround: ~5 s for zimr_template (2 apps),
~11 s for zimr (25 apps).  Build errors are shown in the browser
console without a reload, so you stay paused on the last working
state until the new build is good.

**Stopping:** clicking the red square in VS Code closes the Chrome
window but leaves the background server running.  Use
"Tasks: Terminate Task" → "zig: serve (background)" to kill it,
or just close VS Code.

## Adding a new example

1. Add the name to `examples` in `build.zig`.
2. Regenerate `.vscode/launch.json`:

   ```sh
   zig build gen-vscode
   ```

3. Commit the updated `launch.json` along with your `build.zig`
   change.

The script parses build.zig's examples array and writes one
`Debug: <name>` Chrome config per example, plus a
`Debug: gallery (pick from list)` picker entry at the top.
Source of truth is build.zig (not the gallery manifest) so that
in-progress examples — ones you don't want listed in the public
gallery yet — still get an IDE launch entry.  The set mirrors
`zig build run-<name>` 1:1.

`.vscode/` is tracked in git: launch.json, tasks.json, and
extensions.json are workspace-level configuration that's worth
sharing, and committing the generated launch.json keeps every
clone in sync without each developer having to remember to run
the script.

If you need per-example customization (special preLaunchTask,
viewport size, custom URL parameters), edit the generated file
and stop running the script for that workspace.

## Caveats

- **Early breakpoints can be missed.**  DWARF resolution is async;
  breakpoints set very early in the lifecycle (e.g. inside `init`)
  may not catch on the first run.  Workaround: hit the green
  "restart" button after the page loads — second run catches them.
  This is a known VS Code-side issue
  ([js-debug#1789](https://github.com/microsoft/vscode-js-debug/issues/1789)).
- **Optimized-out variables.**  Even in Debug mode, Zig may inline or
  fold some values; the Variables panel will show `<optimized out>`.
  Try a different line, or look at the wider scope.
- **Debug builds are big.**  A `basic.wasm` jumps from ~30 KB
  (ReleaseSmall) to ~1.5 MB (Debug, with DWARF).  Dev-server load is
  fast over localhost; only matters if you're profiling page weight.
- **Browser console output** is piped to VS Code's debug console,
  including any panics from the Zig runtime.  Stack traces include
  Zig source positions courtesy of DWARF.
- **Hot reload** isn't a thing.  Edit → save → F5 (or just hit
  Chrome's reload button if the server is still running and you
  ran `zig build` separately).
