# zimr_template

A starter project for building browser apps on
[zimr](https://github.com/simonclavet/zimr), a pure-Zig port of raylib and
Dear ImGui that runs in the browser on WebGPU. It ships inside zimr, as
`zimr/template/`: try it there, then copy it to wherever your project should
live.

Three demo apps ship out of the box. **They're called `myproject1` to
`myproject3` on purpose: rename them to whatever your project actually is.**
The whole template is meant to be edited.

- **`src/myproject1.zig`**: 2D bouncing balls with an ImGui control panel.
- **`src/myproject2.zig`**: a rotating 3D cube with a wireframe overlay,
  color picker and camera distance.
- **`src/myproject3.zig`**: hello world, as a program that owns its `main`
  (see [Owning your main](#owning-your-main)).

---

## Requirements

- **Zig 0.17 (dev).** zimr tracks a specific Zig dev build; this template was
  verified with `0.17.0-dev.2122+3e15e99e6`. A different Zig will probably not
  build zimr.
- **A browser with WebGPU.**

Nothing else: no Bun, Node or emscripten. zimr's dev server and its browser
runtime are both built from Zig source by `zig build`.

---

## Where zimr lives

As shipped, this folder builds right after a clone:

```sh
git clone https://github.com/simonclavet/zimr
cd zimr/template
zig build serve -Dplatform=web     # then open http://127.0.0.1:8081/
```

Edits there are changes to your zimr checkout, though, so before real work copy
this folder to wherever your project should live and fix one line in
`build.zig.zon`: `.path`, the way to zimr relative to this project.

| Layout | Folders | `.path` |
|---|---|---|
| As shipped | `zimr/template/` | `".."` |
| Next to a checkout | `code/zimr/` and `code/mygame/` | `"../zimr"` |
| zimr inside your project | `mygame/thirdparty/zimr/` (a copy or a git submodule) | `"thirdparty/zimr"` |

Zig rejects an absolute path. On Windows, a project on another drive than zimr
can't reach it with a relative one: link zimr in with a junction (in `cmd`,
`mklink /J thirdparty\zimr D:\code\zimr`), or pin a published zimr instead.

To pin a published zimr, delete the `.path` line and run:

```sh
zig fetch --save=zimr https://github.com/simonclavet/zimr/archive/<commit>.tar.gz
```

That writes `.url` and `.hash` into `build.zig.zon`. Zig keeps the fetched copy
in `zig-pkg/`, which `.gitignore` leaves out; commit it instead if builds must
work offline. Pin a commit whose `build.zig.zon` lists
`assets/RobotoMono-Regular.ttf` and `assets/sample.ogg` in `.paths`: a fetched
copy of an older zimr is missing files every app build needs.

A pinned project can still build against a local zimr checkout, without editing
anything:

```sh
zig build --fork=../zimr serve
```

If you rename `.name` in `build.zig.zon`, Zig reports a new `.fingerprint` value
to use.

---

## Workflow

```sh
zig build                          # debug build of every app for this machine's platform (Windows: .exe files)
zig build -Dplatform=web           # every app for the browser: zig-out/web/ and zig-out/standalone/
zig build -Dplatform=windows       # every app as a Windows program: zig-out/windows/<name>.exe
zig build -Dmode=release           # zimr's asserts kept; web ReleaseSmall, native ReleaseSafe (share this one)
zig build -Dmode=ship              # asserts and profiler stripped; web ReleaseSmall, native ReleaseFast
zig build serve -Dplatform=web     # build for the web, then serve zig-out/web/ on http://127.0.0.1:8081/
zig build myproject1               # build just one app, for the platform
zig build run-myproject1           # build it, then run it: the program, or with -Dplatform=web its page in a browser
zig build run                      # run-<name> of the first app in build.zig
zig build test                     # host unit tests (see "Tests" below)
zig build lint                     # zimr's linter over src/ (rules: `.lint` in build.zig)
zig build check                    # lint + host tests + every app, and the editor configs current
zig build editor-configs           # write .vscode/ and .zed/: a debug configuration per app (see "Debugging")
zig build zbuild                   # install zig-out/bin/zbuild (below)
```

All of these steps come from `zimr.Project`, which `build.zig` sets up in
a few lines.

When a build fails, the error that matters is often buried under a tree of
"transitive failure" lines. `zig-out/bin/zbuild` takes the same arguments as
`zig build` (`zig-out/bin/zbuild check`), passes its output through, and when
it fails ends with only what failed. Install it once with `zig build zbuild`.

`zig build` produces a complete site at `zig-out/web/`:

```
zig-out/web/
├── index.html          ← gallery (from public/index.html)
├── manifest.json
├── zimr.js             ← zimr's browser runtime, transpiled from its Zig source
├── myproject1/
│   ├── index.html      ← page that streams the wasm beside it
│   └── myproject1.wasm
├── myproject2/
│   ├── index.html
│   └── myproject2.wasm
└── myproject3/
    ├── index.html
    └── myproject3.wasm
```

After `zig build serve -Dplatform=web`, open `http://127.0.0.1:8081/` for the gallery, or
`http://127.0.0.1:8081/myproject1/` directly. The port is 8081 rather than 8080
so it can run beside zimr's own gallery; `.port` in `build.zig` changes it.

The dev server reads files from disk on every request, so it never needs
restarting. A plain rebuild does not reload an open page: refresh it, or
rebuild with `run-<name>` (below), which asks the server to reload it.

### Build and run in one step

```sh
zig build run-myproject1                    # build it, then run zig-out/windows/myproject1.exe
zig build run-myproject1 -Dplatform=web     # build it, then open its page in the default browser
zig build run                               # run-<name> of the first app in build.zig
```

On the web, `run-<name>` starts the dev server and opens the page in a new
tab. The server keeps running until Ctrl+C. If a server is already running on
the port, `run-<name>` reloads the tabs showing that page instead, opens a
tab only if none does, and then ends. So with a server running in one
terminal, this in another reloads the page every time you save:

```sh
zig build serve -Dplatform=web                     # terminal 1: the server, left running
zig build --watch run-myproject1 -Dplatform=web    # terminal 2: rebuild and reload on every save
```

If something other than this project's dev server holds the port, the step
fails and says what holds it.

The pages under `zig-out/web/` need the server. Every web build also writes
`zig-out/standalone/<name>.html`, which inlines the wasm and the runtime, so it
opens straight from disk and is the one to send to someone.

Anything an app logs with `std.log` appears in the browser console and in a
panel along the bottom of the page.

---

## Tests

`zig build test` runs every file passed to `project.addTest` in `build.zig`.
**By default there are none**: the template doesn't ship any tests.

To add one:

1. Create a pure-Zig file (e.g. `src/util.zig`) with `pub fn` declarations
   and `test "..."` blocks at the bottom. It can import `zm` and `zn`.
2. Register it in `build.zig`:
   ```zig
   project.addTest(b.path("src/util.zig"));
   ```
3. Run `zig build test`.

**Tests cannot live in a file that imports zimr**: zimr only builds for the
browser. Put pure-CPU logic (math, state transitions, parsing) in its own
module and test that. Rendering, input and runtime behavior you check by
running the app.

---

## Debugging

`.vscode/` and `.zed/` hold a debug configuration for every app, written by
`zig build editor-configs` the way zimr writes its own. Run it again after
adding or renaming an app; `zig build check` fails while they are out of date.

**In the browser** (VS Code and Zed): **Debug: myproject1** (and **2**, **3**)
builds that app for the web and opens it in Chrome through the dev server. Set
breakpoints in `.zig` source: the debug-mode wasm carries the DWARF that maps
them to Zig lines. VS Code starts the server as a background task on the first
F5. In Zed, start it once yourself with the task **zig: serve**, which builds
every app for the web and then serves them.

**As a Windows program** (VS Code and Zed): **Debug: myproject1 (windows)**
builds `zig-out/windows/myproject1.exe` and launches it under CodeLLDB: the
CodeLLDB extension in VS Code, and in Zed the copy Zed downloads by itself
(F4 picks a configuration there). F9 sets a breakpoint in both.

VS Code's required extensions are listed in `.vscode/extensions.json`; VS Code
offers to install them the first time the folder is opened. That file and
`.vscode/settings.json`, which has CodeLLDB read the program's debug info with
LLDB's own reader, are the two there written by hand.

---

## Adding a new app

1. Copy one of the apps to `src/myname.zig`. An app is a
   `pub const app: z.AppSpec(State) = .{ ... }` descriptor plus the `init`,
   `deinit` and `update` functions it names; zimr's runner does the rest.
   Or copy `myproject3.zig` for an app with its own `main` (below).
2. Add `_ = project.addApp(.{ .name = "myname", .title = "..." });` to
   `build.zig` (with `.own_frame = true` for an app with its own `main`).
3. Add a card to `public/index.html` linking to `myname/`.
4. `zig build editor-configs` gives it its debug configurations (Debugging, above).
5. `zig build run-myname -Dplatform=web` opens `http://127.0.0.1:8081/myname/`
   (or `zig build run-myname` runs it as a program).

---

## Owning your main

`myproject1` and `myproject2` are *descriptors*: the file declares
`pub const app: z.AppSpec(State)` and nothing else. The program is zimr's
runner: it holds `main`, the root module, and the frame, opening and closing
it around the app's `update`.

`myproject3` is the program itself. Its row in `build.zig` sets
`.own_frame = true`, which makes its file the root of the wasm (and of the
Windows program) instead of the runner. Then:

- **`main` is yours.** Code before `zimr_app.run(...)` runs before the first
  frame. Natively, `zimr_app.runNative()` returns when the window closes, so
  code after it runs on the way out.
- **The root module's declarations are yours**: `std_options` (re-export
  `z.std_options` so `std.log` reaches the page), a `panic` handler, exports.
- **Each frame is yours**: `update` calls `z.beginDrawing` / `z.endDrawing`
  itself, so it can render offscreen before it opens the screen.

Owning `main` is not owning the loop. The browser calls a page once per frame,
so `zimr_app.run` returns as soon as the app is initialized; natively,
`runNative` calls the frames. Write a frame as a function, never as a
`while` loop in `main`.

What it costs: a descriptor is something another program can host. zimr's
launcher runs many descriptors on one page, each in its own viewport, and
resets them; a program can't be hosted that way. This template's gallery is
just links to each app's own page, so it lists `myproject3` like the others.
Start with a descriptor unless you need one of the three things above.

---

## Layout

```
.
├── .vscode/                ← VS Code debug + task configs (zig build editor-configs)
├── .zed/                   ← Zed debug + task configs (zig build editor-configs)
├── build.zig               ← the apps and tests (zimr.Project does the rest)
├── build.zig.zon           ← the zimr dependency
├── public/
│   ├── index.html          ← gallery (your app cards)
│   └── manifest.json
└── src/
    ├── myproject1.zig      ← rename me
    ├── myproject2.zig      ← rename me too
    └── myproject3.zig      ← this one owns its main
```

The app runner, the browser runtime and the dev server all come from the
zimr dependency at build time. Nothing is copied into this project.
