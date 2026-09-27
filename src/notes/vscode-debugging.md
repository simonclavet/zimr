# Debugging zimr examples in VS Code

`.vscode/launch.json` has one debug configuration per app in
`build.zig`'s `example_steps` list (`Debug: hello-world`, …), generated
by `zig build gen-vscode`.  Pick one from the Run/Debug panel and hit
F5.  VS Code will:

1. Start `zig build serve-only` as a background task (if not already running).
2. Wait for the server to log `zimr serve: http://127.0.0.1:8080/` (i.e. port 8080 bound).
3. Run the app's build task, `zig build hello-world`, which rebuilds that one app.
4. Launch a fresh Chrome instance at the app's page, `http://localhost:8080/hello_world/`.

Zed runs the same flow with a few differences (the server is started by
hand, and the DWARF decoder is an npm package):
see `tutorials/debug-reload-tutorial.md`.

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

Zig emits DWARF v4 in `.debug_*` custom sections of the wasm whenever
you build in **Debug** mode.

`-Dmode` picks one of three modes and defaults to `debug`:

- `-Dmode=debug` — Debug optimize, all asserts on, DWARF emitted.
  **Use this for VS Code debugging.**  It is the default, so the
  generated `zig: build <step>` tasks don't pass `-Dmode` at all.
- `-Dmode=release` — ReleaseSmall optimize; zimr's own asserts
  (`assertf`) still report, Zig stdlib safety is stripped, and the
  wasm carries no DWARF.  Used by `zig build publish` and the
  `zig: standalone <step>` tasks so prebuilt Pages artifacts still
  trip our own assertion macros.
- `-Dmode=ship` — ReleaseSmall with zimr's asserts and the profiler
  stripped too.

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
parser packaged as a Node module (`@vscode/dwarf-debugging`) that
`vscode-js-debug` can call into.  Chrome's own DWARF extension doesn't
stand in for it: breakpoints set in the editor go through js-debug.
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

- **`zig: serve-only (background)`** — runs `zig build serve-only`.
  Marked `isBackground: true` with a `problemMatcher` whose
  `endsPattern` (`zimr serve: http`) matches the server's first
  line, so VS Code knows when the task is "ready" (= port bound)
  and can move on.  Reused across launches via `instanceLimit: 1`.
- **`zig: build <step>`** — one per app, `zig build <step>`.  Depends
  on the serve task so the first F5 brings up both; later F5s reuse
  the running server and just rebuild.  It is each launch config's
  `preLaunchTask`.
- **`zig: standalone <step>`** — `zig build <step>-standalone
  -Dmode=release`: the app as one self-contained HTML page.
- **`zig: build (release)`** — `zig build
  -Dmode=release`.  Useful for size/perf
  comparisons; not used by any launch config.
- **`zig: test`** (`zig build test --summary all`) and
  **`zig: smoke-test`** (`zig build -Dmode=debug smoke-test`) —
  wired into VS Code's test runner so Ctrl/Cmd-Shift-P → "Run Test
  Task" works.

## Workflow

**First launch (cold):** F5 takes a few seconds.  The serve task
runs `zig build serve-only`: the default install (`zimr.js`, the
gallery, the HTML docs; no example wasms), then the static server.
Once its `zimr serve:` line prints, the app's build task compiles
that one app in Debug mode, and Chrome launches.

**Subsequent launches:** F5 is fast.  Server is already running;
the build task is a cached no-op unless you edited something;
Chrome window opens within ~1 second.

**After editing a `.zig` file:** nothing happens on save.  The
server is static, with no file watcher, rebuild or reload.  Re-run
the launch config (F5 or restart), which rebuilds through its
`preLaunchTask`, or run the app's build task and press Ctrl+R in the
debugged Chrome: the server sends `Cache-Control: no-store`, so the
reload fetches the new wasm, and vscode-js-debug binds your
breakpoints in it.

**Stopping:** clicking the red square in VS Code closes the Chrome
window but leaves the background server running.  Use
"Tasks: Terminate Task" → "zig: serve-only (background)" to kill it,
or just close VS Code.

## Adding a new example

1. Add the app's build step to `example_steps` in `build.zig`.
2. Regenerate the editor configs:

   ```sh
   zig build gen-vscode
   ```

3. Commit the four generated files (`.vscode/launch.json`,
   `.vscode/tasks.json`, `.zed/debug.json`, `.zed/tasks.json`) along
   with your `build.zig` change.

The generator parses `example_steps` and writes one `Debug: <step>`
Chrome config per entry, pointed at the app's underscored directory
(`Debug: hello-world` opens `http://localhost:8080/hello_world/`).
Source of truth is build.zig (not the gallery manifest) so that
in-progress examples — ones you don't want listed in the public
gallery yet — still get an IDE launch entry.

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
  ran the app's build task separately).
