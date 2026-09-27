# zimr_template

A starter project for building browser apps on
[zimr](https://github.com/simonclavet/zimr), a pure-Zig port of raylib and
Dear ImGui that runs in the browser on WebGPU. It ships inside zimr, as
`zimr/template/`: try it there, then copy it to wherever your project should
live.

Two demo apps ship out of the box. **They're called `myproject1` and
`myproject2` on purpose: rename them to whatever your project actually is.**
The whole template is meant to be edited.

- **`src/myproject1.zig`**: 2D bouncing balls with an ImGui control panel.
- **`src/myproject2.zig`**: a rotating 3D cube with a wireframe overlay,
  color picker and camera distance.

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
zig build serve                    # then open http://127.0.0.1:8081/
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
zig build                          # debug build of every app → zig-out/web/
zig build -Dmode=release           # ReleaseSmall with zimr's asserts kept (share this one)
zig build -Dmode=ship              # ReleaseSmall, asserts and profiler stripped
zig build serve                    # build, then serve zig-out/web/ on http://127.0.0.1:8081/
zig build myproject1               # build just one app into zig-out/web/myproject1/
zig build myproject1-standalone    # one self-contained HTML file in zig-out/standalone/
zig build test                     # host unit tests (see "Tests" below)
zig build lint                     # zimr's linter over src/ (rules: `.lint` in build.zig)
zig build check                    # lint + host tests + every app
```

All of these steps come from `zimr.Project`, which `build.zig` sets up in
a few lines.

`zig build` produces a complete site at `zig-out/web/`:

```
zig-out/web/
├── index.html          ← gallery (from public/index.html)
├── manifest.json
├── zimr.js             ← zimr's browser runtime, transpiled from its Zig source
├── myproject1/
│   ├── index.html      ← page that streams the wasm beside it
│   └── myproject1.wasm
└── myproject2/
    ├── index.html
    └── myproject2.wasm
```

After `zig build serve`, open `http://127.0.0.1:8081/` for the gallery, or
`http://127.0.0.1:8081/myproject1/` directly. The port is 8081 rather than 8080
so it can run beside zimr's own gallery; `.port` in `build.zig` changes it.

The dev server does not reload pages for you: rebuild, then refresh. It reads
files from disk on every request, so it never needs restarting.

The pages under `zig-out/web/` need the server. A `<name>-standalone` file
inlines the wasm and the runtime, so it opens straight from disk and is the
one to send to someone.

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

## VS Code

`.vscode/{launch,tasks,extensions}.json` ship a complete F5-to-debug flow.
Three launch configurations:

- **Debug: gallery** opens the picker
- **Debug: myproject1** opens myproject1 directly
- **Debug: myproject2** opens myproject2 directly

Each one starts the dev server once (as a background task) and rebuilds in
debug mode before launching Chrome. Set breakpoints in `.zig` source. The
required extensions are listed in `.vscode/extensions.json`; VS Code offers
to install them the first time the folder is opened.

---

## Adding a new app

1. Copy one of the apps to `src/myname.zig`. An app is a
   `pub const app: z.AppSpec(State) = .{ ... }` descriptor plus the `init`,
   `deinit` and `update` functions it names; zimr's runner does the rest.
2. Add `_ = project.addApp(.{ .name = "myname", .title = "..." });` to
   `build.zig`.
3. Add a card to `public/index.html` linking to `myname/`.
4. (Optional) Add a launch configuration to `.vscode/launch.json`.
5. `zig build serve`, then open `http://127.0.0.1:8081/myname/`.

---

## Layout

```
.
├── .vscode/                ← debug + task configs
├── build.zig               ← the apps and tests (zimr.Project does the rest)
├── build.zig.zon           ← the zimr dependency
├── public/
│   ├── index.html          ← gallery (your app cards)
│   └── manifest.json
└── src/
    ├── myproject1.zig      ← rename me
    └── myproject2.zig      ← rename me too
```

The app runner, the browser runtime and the dev server all come from the
zimr dependency at build time. Nothing is copied into this project.
