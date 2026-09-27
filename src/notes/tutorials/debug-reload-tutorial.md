# Debug + reload system

How a `.zig` edit becomes a breakpoint hit in VS Code or Zed. Three
pieces: a build step that compiles one app in debug mode, a static
server for `zig-out/web/`, and an editor debug config that launches a
Chrome it is attached to. Nothing rebuilds or reloads on its own.

## The pieces

```
┌─ Editor: debug config "Debug: hello-world" ───────────────────────┐
│  1. build   zig build hello-world   (debug mode: DWARF in wasm)   │
│  2. launch  Chrome at http://localhost:8080/hello_world/          │
│  adapter    vscode-js-debug + a DWARF decoder (one-time setup)    │
└────────────────┬──────────────────────────────────────────────────┘
                 │ Chrome DevTools Protocol
                 ▼
┌─ Chrome, fresh profile, launched by the debug config ─────────────┐
│  hello_world/index.html                                           │
│    ../zimr.js         the shared runtime, one copy for every app  │
│    hello_world.wasm   streamed, DWARF sections embedded           │
└────────────────┬──────────────────────────────────────────────────┘
                 │ plain HTTP
                 ▼
┌─ zig build serve-only: tools/serve.zig ───────────────────────────┐
│  static files from zig-out/web/ on 127.0.0.1:8080                 │
│  no file watcher, no rebuild, no reload: reload the page yourself │
└───────────────────────────────────────────────────────────────────┘
```

## One app, two names

An app's build step is its name with dashes; the directory it installs
to, and is served from, is its name with underscores. `finishWgpuApp`
in `build.zig` derives both from one name:

| | `hello_world` |
| --- | --- |
| build step | `zig build hello-world` |
| standalone page | `zig build hello-world-standalone` |
| installed to | `zig-out/web/hello_world/` (`index.html` + `hello_world.wasm`) |
| served at | `http://localhost:8080/hello_world/` |

The server maps a URL straight onto a path under `zig-out/web/`, so
`http://localhost:8080/hello-world/` is a 404.

## One-time setup

The editor, not Chrome, turns a breakpoint on a `.zig` line into a
wasm offset. Both editors drive Chrome through vscode-js-debug, and
js-debug needs a DWARF decoder to read the wasm's debug sections.
Without one it quietly falls back to wasm disassembly, and `.zig`
breakpoints never bind.

**VS Code** — install the extensions `.vscode/extensions.json`
recommends. `ms-vscode.wasm-dwarf-debugging` is the DWARF decoder.

**Zed** — install the community **Zig** extension (`zed: extensions`,
search `Zig`; ZLS comes with it). Zed bundles js-debug but not the
decoder. js-debug loads the npm package `@vscode/dwarf-debugging` with
`import('@vscode/dwarf-debugging')`, so install the package next to the
adapter:

```
npm install --prefix "%LOCALAPPDATA%\Zed\debug_adapters\JavaScript\JavaScript_v1.140.0\js-debug" @vscode/dwarf-debugging
```

Use the `JavaScript_v<version>` folder you actually have. On macOS and
Linux the same `debug_adapters/JavaScript/...` path sits under Zed's
data directory (`~/Library/Application Support/Zed`,
`~/.local/share/zed`). The adapter lives in a versioned folder, so an
adapter update needs the install again. The package is about 59 MB
unpacked. While it is missing, Zed's debug console prints this as soon
as the wasm loads:

> You may install the `@vscode/dwarf-debugging` module via npm for enhanced WebAssembly debugging

Chrome's **C/C++ DevTools Support (DWARF)** extension is no
substitute: it only teaches Chrome's own DevTools to read DWARF, and
the Chrome a debug config launches runs on a fresh profile without
your extensions anyway.

## Per session: start the server

`zig build serve-only` runs the default install first (the shared
`zimr.js` runtime, the gallery and its `manifest.json`, the HTML docs;
no example wasms), then starts `tools/serve.zig` on `zig-out/web/`.
Once the port is bound it prints

```
zimr serve: http://127.0.0.1:8080/  (root=zig-out/web, hmr=true)
```

It serves files as they are on disk, `.wasm` as `application/wasm`,
with `Cache-Control: no-store` so a reload always gets the current
build. It also injects a one-line script into every HTML page, and that
script only logs "refresh manually after rebuild": despite `hmr=true`,
there is no file watcher, no rebuild and no reload.

- **VS Code** starts it for you. Every `zig: build <step>` task
  `dependsOn` the `zig: serve-only (background)` task, whose
  `endsPattern` (`zimr serve: http`) tells VS Code the port is bound.
- **Zed** can't tell when a background task is ready, so start it
  yourself once per session: `task: spawn`, then **`zig: serve-only`**.

## Per example: start the debug config

- **VS Code** — pick `Debug: hello-world` in Run and Debug and press
  F5. Its `preLaunchTask` is `zig: build hello-world`.
- **Zed** — open the debugger (`debugger: start`) and pick
  `Debug: hello-world`. Its `"build"` field runs the same
  `zig: build hello-world` task.

That task runs `zig build hello-world`. `-Dmode` defaults to `debug`,
so the wasm keeps its DWARF sections (a debug `hello_world.wasm` is
about 3 MB; a `-Dmode=release` one has none). Then js-debug launches
Chrome at `http://localhost:8080/hello_world/` and attaches, and
breakpoints in `examples/hello_world/hello_world.zig`, or anywhere in
`src/` the app runs, bind once the wasm loads.

**Breakpoints only work in that Chrome.** If you only run the
`zig: build hello-world` task and open the URL in your own browser,
the page runs with no debugger attached.

## After editing `.zig` code

Nothing rebuilds or reloads when you save. Either:

- **Re-run the debug config** (F5 or restart). Its build step rebuilds
  the app, then Chrome relaunches.
- **Run `zig: build hello-world`, then reload the page** in the
  debugged Chrome (Ctrl+R). `no-store` means the reload fetches the
  new wasm, and js-debug binds your breakpoints in it.

## Build steps you care about

| Step                          | What it builds                                                         |
| ----------------------------- | ---------------------------------------------------------------------- |
| `zig build`                   | `zimr.js`, the gallery + manifest, the HTML docs. No examples.         |
| `zig build <step>`            | One app into `zig-out/web/<name>/`, e.g. `zig build hello-world`.      |
| `zig build <step>-standalone` | One self-contained `zig-out/standalone/<name>.html` (-Dmode=release).  |
| `zig build all-examples`      | Every example.                                                         |
| `zig build serve-only`        | The default install, then the static server on :8080.                  |
| `zig build serve`             | `all-examples`, then the static server on :8080.                       |
| `zig build gen-vscode`        | The VS Code and Zed configs, from `example_steps` in `build.zig`.      |
| `zig build test`              | Every quick test: engine, shader-free suites, tier-A examples.         |
| `zig build dist`              | Builds all-examples + mirrors to prebuilt/.                            |
| `zig build publish`           | `dist` (release mode) + push to GitHub Pages.                          |

## Troubleshooting

### Chrome says the site can't be reached

Nothing is listening on 8080. In Zed, spawn `zig: serve-only`. In VS
Code, check the `zig: serve-only (background)` terminal to see why the
server stopped. If the configs point at `localhost:8000`, they are
older than the move to 8080: run `zig build gen-vscode`.

### 404

The URL has to use the underscored directory (`/hello_world/`), and
the app has to be built: `serve-only` builds no examples, and the
server has only what is in `zig-out/web/`. Run the app's build task.

### The page never finishes loading

`tools/serve.zig` handles one connection at a time and keeps each one
open between requests, so a request on a second browser connection
waits until the first connection closes. A page load can stall for
minutes behind an idle connection. That's a server limitation, not a
config problem.

### Breakpoints stay hollow, or you step into wasm disassembly

- No DWARF decoder: see [One-time setup](#one-time-setup). In Zed, the
  console line quoted there is the tell.
- The page wasn't launched by the debug config.
- A release build is in `zig-out/web/`. `-Dmode=release` and
  `-Dmode=ship` wasms have no DWARF; rebuild with the plain build task.
- A breakpoint in `init` can miss the first run, because the DWARF
  loads asynchronously. Restart the session once the page is up.

### A `Debug:` entry is missing, or Zed ignores `.zed/debug.json`

`zig build gen-vscode` rewrites `.vscode/launch.json`,
`.vscode/tasks.json`, `.zed/debug.json` and `.zed/tasks.json` from the
`example_steps` list in `build.zig`. Add the app's step there, run it,
and commit all four files. Zed reads `.zed/debug.json` as a bare JSON
array and silently ignores the whole file if the JSON is broken, so
regenerate instead of hand-editing.

## Where the wiring lives

- `build.zig` — the `serve` and `serve-only` steps; `example_steps`,
  the list the editor configs come from; `finishWgpuApp`, which
  installs each app to `web/<name>/` and registers its dashed step.
- `tools/serve.zig` — the static dev server.
- `tools/gen_vscode.zig` (`zig build gen-vscode`) — writes the four
  editor configs.
- `.vscode/launch.json`, `.vscode/tasks.json`, `.zed/debug.json`,
  `.zed/tasks.json` — generated; regenerating overwrites hand edits.

## VS Code and Zed side by side

| | VS Code | Zed |
| --- | --- | --- |
| Start the server | Automatic on the first F5 (background task) | `task: spawn` → `zig: serve-only`, once per session |
| Know the server is ready | `endsPattern: "zimr serve: http"` | No equivalent |
| Build before launching | `preLaunchTask: "zig: build <step>"` | `"build": "zig: build <step>"` |
| Workspace root variable | `${workspaceFolder}` | `$ZED_WORKTREE_ROOT` |
| Chrome adapter spelling | `"type": "chrome"` | `"adapter": "JavaScript"` + `"type": "chrome"` |
| DWARF decoder | `ms-vscode.wasm-dwarf-debugging` extension | `@vscode/dwarf-debugging` npm package next to js-debug |
| After a rebuild | Reload the page, or re-run the config | Same |
