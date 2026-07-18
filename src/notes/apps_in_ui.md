# App launcher — switching between full examples (reframed)

> **Reframe (this is the current direction).** The earlier idea — "any app
> embeddable in any draggable UI panel, with its own UI inside" — is dropped as
> over-complex and undesirable: examples already own their UI, so nesting a full
> app (with its own panels) inside a draggable host panel is incoherent, and it
> drags in the whole render-to-texture / scissor / occlusion problem. Instead the
> launcher is **special and fullscreen**: it shows exactly ONE example at a time,
> fullscreen, and that example does whatever it wants with the full screen,
> its own UI, and all input — identical to running it standalone. The launcher's
> only job is to SWITCH which example is live. No compositing, no RTs, no panels.
> Physics scene-switching is deferred until example-switching works; it is
> probably a *different* (intra-app) mechanism (see §7).

## 1. Goal

A fullscreen host that holds ~10 hand-picked examples (mandelbrot side-by-side,
PBR helmet, raytracer, the physics demo, …). One is active and renders
fullscreen with its own UI/input. A lightweight, dismissable switcher lets you
pick another. Adding example #11 is a one-line registration. Fullscreen-standalone
examples stay first-class and unchanged.

## 2. Why fullscreen-swap, not panel-embedding

- Examples already draw their own UI; a host panel UI around an app's own UI is
  redundant and confusing.
- Only one app is visible at a time, so there is nothing to composite — the
  active app renders straight to the swapchain exactly as standalone. This sheds
  the entire RTT/scissor/occlusion problem that sank the plot3d attempt.
- Input is trivial: the live app owns all of it; when the switcher is open the
  app is paused and the switcher owns input. No per-panel routing.

## 3. How examples are wired in the build (the deep dive)

Every servable wgpu example is a declarative row in the `wgpu_apps` table
(`build.zig:1531`):

```
App = struct {
    name: []const u8,                 // e.g. "mandel_sidebyside"
    title: []const u8,
    root_source_file: ?LazyPath = null, // null => derived from name
    shaders: []const []const u8 = &.{}, // e.g. {"mandelbrot_fs","wgpu_trivial_vs"}
    configure: ?*const fn (AppContext, *Module) void = null, // asset-bake escape hatch
};
```

`ctx.addApp(row)` (`build.zig:3518`) runs a fixed pipeline:

1. **`buildUserMod(name)`** (`build.zig:3240`) — creates the example's *module*:
   - root = `examples/wgpu_<name>/wgpu_<name>.zig`,
   - imports `zimr`, `zm`, `shader_interface`, a fresh `wgpu_common`,
   - anonymous imports `roboto_mono_ttf`, `atkinson_mono_ttf`, `sample_ogg`.
2. **`addShaderDep(mod, basename)`** per declared shader (`build.zig:3286`) — wires,
   *into that module's import table*:
   - `<basename>.wgsl` (compiled WGSL, anonymous import),
   - `<basename>_io.zig` (the typed IO interface, a module),
   - `<basename>.zig` + `<basename>_externs` (the shader source, anonymous import).
   This is why `@import("mandelbrot_fs.zig")` resolves even though the file lives
   at top-level `examples/`, not next to the example — it is a *build-injected
   named import*, not a filesystem-relative one.
3. **`configure`** hook (e.g. `configureHelmetSw` bakes the GLB mesh).
4. **`finishWgpuApp(user_mod, …)`** (`build.zig:3341`) — creates the runner exe:
   root = `src/wgpu_runner.zig`, imports `zimr`/`zm`/`shader_interface` +
   **`user_app` = the example module**, then served page + standalone HTML.

The runner (`src/wgpu_runner.zig`) owns the frame: `beginDrawing` (clear) →
`spec.update(f, s)` → `endDrawing`. The example exposes only `pub const app =
z.AppSpec(State){…}` (plus a `std_options` that is ignored unless it is the exe
root). Many examples also call `clearViewport`/`endDrawing` inside `update`; this
is redundant with the runner and currently tolerated.

**The crucial consequence:** an example is *already a self-contained module* — its
shaders, fonts, and IO are wired into its own import table, encapsulated. Anything
importing that module by name gets its `app` AppSpec without needing to know or
re-wire any of its shaders. That is the whole basis for the launcher.

## 4. Future-proof launcher architecture

**Examples as reusable modules; the launcher aggregates their AppSpecs.**

- `AppSpec(State)` is already type-erasable via `eraseApp` → `AppVtable`
  (`wgpu_app.zig:265`), and `z.Launcher` (`wgpu_app.zig:2565`) already holds N
  type-erased children with per-child leak-checked allocators and
  `tick`/`reset`/`deinit`. The launcher reuses this; it does not invent new
  machinery.
- **Build side:** today `addApp` builds an example module and immediately buries
  it inside its own runner exe. Refactor so each example module is also
  *retained* (return it from `addApp`, or register it in a name→module map). Then
  a new launcher exe (root `examples/wgpu_launcher/wgpu_launcher.zig`) imports the
  chosen example modules **by name** (`mod.addImport("ex_mandel_sidebyside",
  mandel_mod)`, …) plus `zimr`/`zm`/`wgpu_common`/fonts. A module may be a
  dependency of several compilations, so each example module is shared between
  its own standalone exe and the launcher — no duplication, no shader re-wiring.
- **Launcher source:** `const mandel = @import("ex_mandel_sidebyside"); …` then
  `const entries = .{ .{ "Mandelbrot", eraseApp(mandel.app) }, … };`. Adding an
  example is one import + one table row. Future-proof.

**Modal switcher (keeps examples' UI/input intact, needs ~zero example changes):**

- The switcher is a *modal overlay*, not persistent chrome. Closed: the active
  example is ticked and renders fullscreen, owning the frame and all input
  (it may even call its own `endDrawing` — the tolerated double-end still works,
  so examples need no edits for the swap itself). Open: the example is **not**
  ticked (paused); the launcher draws only a fullscreen picker (grid/list of the
  10 names, maybe a thumbnail later) and owns input. A single hotkey / on-screen
  button / edge gesture toggles it. Because the example and the overlay are never
  drawn in the same frame, there is no overlay-vs-app-UI conflict.
- Optional later polish: a thin always-visible "≡" button in a corner to open the
  switcher on touch devices.

## 5. Lifecycle + the leak problem

- We never implemented per-app `deinit`-on-switch, so naive switching leaks.
  Avoid the problem for v1: **lazy-init on first activation, then keep alive**;
  `deinit` every child once at launcher exit (via `z.Launcher.deinit`). No
  per-switch free → no leak, at the cost of keeping activated examples' GPU
  resources resident (fine for ~10).
- Later, when we want per-switch teardown, add **leak detection around a switch**:
  each child already has its own allocator under `z.Launcher`; wrap a child's
  allocator in a counting/My-leak-checking allocator and assert net-zero after
  `deinit`. That is the right time to make every hosted example's `deinit`
  actually free everything (today several are no-ops). Tracked, not v1.

## 6. Example changes we may accept

- None required for the swap (the tolerated double-`endDrawing` makes ticking a
  child fullscreen work as-is).
- Nice-to-have conformance (separate cleanup pass): make examples obey the
  runner contract — `update` draws, never calls `beginDrawing`/`endDrawing` —
  so the frame lifecycle lives in exactly one place. Low risk, do opportunistically.
- A hosted example must tolerate being *paused* (not ticked) while the switcher is
  open and *resumed* later. Stateless-per-frame examples are fine; time-based ones
  should read `f.time.delta_time` (already standard) so a pause is just a long gap.

## 7. Physics scene-switching — deferred, and probably different

Switching the *physics scene* is **intra-app** (one app rebuilding its World via
`switchScene`), whereas switching *examples* is **inter-app** (the launcher
swapping which `AppVtable` is live). They are not the same mechanism and should
not be forced together: the physics demo keeps its own in-app scene tabs; the
launcher treats the whole physics demo as one entry. Revisit once example
switching is solid — at most they share the "modal picker" UI widget, not the
switching machinery.

## 8. First slice (small, provable)

1. Build refactor: make `addApp` retain each example module (name→module map).
2. New `examples/wgpu_launcher/` exe importing 2–3 example modules by name
   (start with `sidebyside` (CPU|GPU 2D — no shader-dep surprises) + `physics`).
   Confirm it builds green and the standalone is produced.
3. Launcher source: lazy-init + keep, tick active fullscreen, a hotkey-toggled
   fullscreen picker listing the entries. Screenshot: each entry shows its example
   fullscreen; the picker switches them.
4. Grow to the 10 best examples one import-row at a time. Each addition is a
   build dep + a table row; if a green build survives each, the architecture holds.

**Open question to settle in step 2:** can two example modules (each with its own
`wgpu_common` instance and font anon-imports) coexist as deps of one launcher exe
without symbol/import collisions? Almost certainly yes (separate modules =
separate namespaces), but the 2-example slice proves it before we wire 10.

## 9. BUILT (zimr169) — launcher with 7 flagships

The fullscreen launcher is implemented and builds green.

- **Source:** `examples/wgpu_launcher/wgpu_launcher.zig` — a `z.Launcher` holding 7
  flagship example modules (rt / helmet / mandelbrot side-by-sides, UI full
  showcase, plot 2D demo, plot 3D gallery, physics demo). One is live at a time
  via `Launcher.tickFullscreen` (new — direct `update`, no `pushViewport`, so the
  child owns the whole frame and its own input exactly as standalone). A modal
  picker (shown at start, reopened with backtick `` ` ``) chooses the example;
  while open the live example is not ticked. Lazy-init on first activation +
  keep-alive; `Launcher.deinit` tears everything down once (no per-switch leak).
- **Build (the careful part):** `addApp` was split into `buildAppModule` (returns
  the example `*Module`) + `finishWgpuApp`. The wgpu_apps loop now captures every
  example module into a `name -> *Module` map; the launcher exe imports the 7 by
  name (`ex_<name>`). Two new `AppContext` helpers keep the file graph single-owner
  so many example modules can share one binary: `buildUserModShared` uses ONE
  shared `wgpu_common`/font/ogg module instance (created once) instead of fresh
  per-example, and `addShaderDepShared` MEMOIZES each shader's modules by basename
  (a `StringHashMap(ShaderDep)` on the ctx) so a shader used by several examples
  (e.g. `wgpu_trivial_vs`, shared by rt + mandel) is wired exactly once. Lazy
  memoization also means a standalone exe still compiles only its own shaders.
- **Bonus fix:** `src/plot3d.zig` used `Color.w` (stale Vec4 access after the
  Color consolidation; `Color` is `{r,g,b,a}`) on four lines — `.w` -> `.a`. This
  was a latent break: `wgpu-plot3d-gallery-standalone` did not compile until now.
- **Unverified by me:** the on-device behaviour (Simon screenshots) — does each
  flagship render fullscreen from the picker, and does backtick return cleanly?
  The launcher window opts into depth (`depth24_plus`) so the 3D flagships
  (helmet/physics/plot3d/rt) have a frame depth target.

## 10. STATUS (zimr170) — launcher blocked on a device black screen; logging unreliable

### Where we are
The launcher BUILDS green at every size (7 / 3 / 1 children), but on Simon's device
it renders a BLACK screen and never shows its UI — even reduced to RUNG 1 (hosting
ONLY the known-good `wgpu_ui_smoke_button` as a single child, no menu). The same
smoke button as its OWN standalone renders perfectly, and `wgpu_mandel_sidebyside`
renders all THREE targets (CPU + GPU + comptime inset) through the refactored build.

### The build refactor is EXONERATED
`mandel_sidebyside` (and `ui_smoke_button`) build via the new `buildUserModShared`
+ memoized-shader path and render correctly, including the comptime-baked corner
(pure `@import("mandelbrot_fs.zig")` at compile time). So `addApp`-split,
`buildUserModShared`, `addShaderDepShared` memoization, and the shared
common/font modules are all SOUND. The launcher's failure is specific to it.

### What we tried (launcher bring-up)
- 7 flagships, Debug → 18 MB wasm, black. Switched to `-Dmode=release` (ReleaseSmall)
  → 7.9 MB, still black.
- Cut to 3 light 2D children (mandel/rt/ui) → 2.1 MB, black.
- Cut to RUNG 1: one child (smoke button), no menu, just `tickFullscreen` → 1.6 MB,
  still black. So it is NOT the menu, NOT scope/size, NOT raw-2D drawing.
- Added `std.log` diagnostics in the launcher init/update. Saw NOTHING — but see
  the logging problems below; the "no logs" was never a trustworthy signal.

### THE LOGGING PROBLEM (must fix before trusting any launcher diagnosis)
We cannot yet reliably see logs on device, which has blocked every diagnosis:
1. `std.log.info`/`.warn` are DROPPED in ReleaseSmall — Zig's `default_level` is
   `.err` for ReleaseFast/Small. Only `std.log.err` survives. (zimr's std_options
   sets only `.logFn`, not `.log_level`.)
2. `dom.js_log` (bridge `ZimrWgpu.jsLog`) writes ONLY to `console.log`, invisible
   on a phone in-app browser with no devtools.
3. Attempt A: a c2js page-template overlay mirroring `console.{log,warn,error}` to
   a `<div>`. Never confirmed to work (no logging example was tested with it).
4. Attempt B: made `jsLog` append to a real DOM `<pre>` panel. This BRICKED the
   phone — every log allocates JS handles and grows `textContent`; with any
   per-frame logging it explodes (memory + handle-table). REVERTED.
5. All Attempt-A/B/runner-log/canvas-shrink instrumentation has been REVERTED to
   the known-good baseline.

### What to try NEXT (in order)
1. SAFE logging first, proven on a KNOWN-GOOD example before touching the launcher:
   - Use `std.log.err` (or set `std_options.log_level = .debug` in the assert
     build) so messages survive ReleaseSmall.
   - A bounded on-page sink: keep a small Zig-side ring buffer / cap the DOM panel
     to the last N lines and RELEASE JS handles each call (the brick came from
     unbounded growth + leaked handles). Throttle to first K frames only.
   - VERIFY it shows on a working example (e.g. add one `std.log.err` to
     `ui_smoke_button`) BEFORE relying on it.
2. With trustworthy logs, answer the one open question: does the launcher's
   `app.init` run at all? Put a log as the very first statement of the runner's
   init path AND the launcher init.
   - If the runner runs but the launcher init never fires → the multi-module exe
     wiring (runner root + `user_app` = launcher importing `ex_*`) is the suspect.
   - If neither fires → the launcher wasm never starts (instantiation/entry).
3. If wiring is suspect, diff the launcher exe's module graph against a normal
   example's (the launcher is the only exe whose `user_app` imports OTHER example
   modules). Suspect: duplicate/!-conflicting top-level decls pulled in via the
   child modules, or the wgpu async-init path differing.

### Kept in tree (safe, green)
- `plot3d.zig` `Color.w` → `.a` bugfix (also unbroke `wgpu-plot3d-gallery-standalone`).
- The whole build refactor + `Launcher.tickFullscreen` + the rung-1 launcher source.
