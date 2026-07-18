# ============================================================================
# FINAL STATE — multi-app / descriptor migration (read this first)
# ============================================================================
# WHAT THIS IS: every wgpu example is a DESCRIPTOR — `pub const app =
# z.AppSpec(State){ .config, .init, .deinit, .update }` — with no main/zimr_app/
# std_options. One generic runner (src/wgpu_runner.zig) is the wasm entry; it
# owns the frame (beginDrawing/clearBackground/endDrawing) and ticks the app.
#
# HOW TO ADD A WGPU EXAMPLE (one build call, deps declared in the call):
#   addWgpuApp(..., "name", "title")                       -- 2D / UI / engine-3D
#   addWgpuShaderApp(..., &shader_pipeline, "name","title",
#                    &.{ "my_fs", "wgpu_trivial_vs" })     -- custom VS/FS shaders
#   addWgpuComputeApp(..., &shader_pipeline, "name","title",
#                    &.{ .{ .basename = "my_kernel" } })   -- kompute kernels
# All three share buildUserMod (the example module + standard imports) +
# finishWgpuApp (runner exe + smoke + bundle + standalone). ALL names derive
# from `name` (dir examples/wgpu_<name>/, steps wgpu-<dash>, etc.).
#   - addShaderDep wires <basename>.wgsl + <basename>_io.zig (+ externs +
#     CPU-side <basename>.zig when present). Shader sources live in examples/.
#   - In update: paint your viewport with z.clearViewport(f, color) (NOT
#     clearBackground — the runner owns the pass). Works full-screen or in a cell.
#
# STATUS: 58/63 examples are descriptor. addWgpuExample (legacy) is DELETED.
#
# DELIBERATE EXCEPTIONS (5, marked `[MANUAL EXCEPTION]` in build.zig): examples
# that own their OWN GPU frame don't fit the runner-owns-frame contract and stay
# as bespoke manual blocks BY DESIGN (migrating them would mean rewriting their
# renderer):
#   - cube_demo      (Backend.beginFrame, low-level custom-pipeline 3D)
#   - lambert_demo   (renderer.beginFrame, 3D)
#   - pbr_demo       (renderer.beginFrame, 3D + DamagedHelmet.glb)
#   - gltf_textured  (renderer.beginFrame, 3D)
#   - demo           (legacy scaffold, installs to zig-out/wgpu/; own-frame +
#                     irregular multi-shader kitchen-sink)
# The descriptor contract fits 2D + UI + engine-3D (beginMode3D) + fullscreen-
# shader + compute (one-shot AND per-frame). Own-frame custom-pipeline 3D is out.
#
# GATES: lint 0/353, zig fmt --check clean, FULL `zig build smoke-test` 59/59.
# The migration gate is the FULL smoke (no -Dfocus) — focused subsets hid 3
# registration/file mismatches during the migration.
#
# OPEN POLISH (optional, not blocking): (a) WgpuCtx opts struct to fold the
# 11-13 shared positional args into one ctx (scriptable churn over ~58 calls);
# (b) unloadFont + LoadedShader.deinit so launcher resets free GPU/atlas memory
# (debug leak check is CPU-heap only today).
# ============================================================================

# Multi-app refactor — design study (turn ~1033)

GOAL (northstar): gather ALL examples into one wasm "launcher" that can start,
reset, and lay out other apps, each taking only PART of the screen. Add an
`uninitState` paired with `initState`, and verify no leaks across a start→reset
cycle. Keep it SIMPLE; avoid globals and magic. Open question: does an example
still own its own `main`, or is there always a launcher?

This is a design doc for evaluation — NO code shipped this turn.

---

## 1. The problem, grounded in the current code

A wgpu example today IS its own whole-frame harness:

```zig
pub var zimr_app: z.App = .{};                 // module-scope global
pub fn main() !void { try zimr_app.run(cfg, State, initState, update); }
fn initState(gpa, f) !State { ... }            // returns State (run gpa.create's it)
fn update(f, s) { z.beginDrawing(f.gl); z.clearBackground(..); ...; z.endDrawing(f.gl); }
```

How it actually runs (src/wgpu_app.zig):
- ONE module-global `active_app: ?*App`. `main` → `App.run` sets it + stores the
  typed state ptr + a comptime `update_fn` thunk.
- ONE wasm export `update(dt)` (+ `_initialize`, input_push_*). The JS RAF loop
  calls `update` each tick; it reads `active_app`, builds a `Frame` (makeFrame),
  dispatches the thunk. There is exactly ONE root, ONE update export per wasm.
- `beginDrawing` ACQUIRES the surface texture, opens the render pass (loadOp =
  clear → clears the WHOLE surface), programs a top-left ortho at the live CSS
  size. `endDrawing` flushes + ends the pass + presents. `.fit` mode already
  bakes a uniform scale+offset into the ortho (a "viewport" precedent).
- Draw fns reach the App via `appOf(gl)` (gl.owner back-pointer). `f.window`
  reports the full canvas. `beginScissorMode(gl,x,y,w,h)` clips (top-left origin;
  the Y-flip bug is fixed).
- RTT EXISTS: `loadRenderTexture` + `beginTextureMode(gl, rt, clear)` (flush →
  open a fresh pass into rt.color_view with its own clear + ortho at rt size) +
  `endTextureMode` (reopen backbuffer preserving) + `drawTexture` (composite).

The five concrete blockers to embedding an example unchanged:

- B1 FRAME OWNERSHIP. The child calls `beginDrawing`/`clearBackground`/
  `endDrawing` — once-per-frame, whole-surface ops. N children can't each
  acquire/clear/present; `clearBackground` would wipe siblings.
- B2 FULL-CANVAS SIZING. The child reads `f.window.widthf()/heightf()` and draws
  from origin 0,0. A scissor clips it to a cell but you'd see the top-left of a
  full-canvas layout, not a cell-fitted one. No cell origin / scale.
- B3 SINGLE ROOT EXPORT. `zimr_app`/`update`/`_initialize` are one-per-wasm; you
  cannot link N examples' `main`/`zimr_app`. (Their `init/update/State` ARE just
  functions/types the launcher can reference; the unused `main` is DCE'd.)
- B4 FIXED UPDATE SIGNATURE `fn update(*Frame, *State)` — no viewport param, so a
  child can't even be TOLD its rect.
- B5 PER-CHILD UiHost / INPUT. UI examples each own a UiHost; N of them fight
  over the global mouse/focus/popup state and read full-canvas mouse coords.

ROOT CAUSE: "the example owns the frame + the whole screen." Every solution is a
different way to (a) take frame-ownership away from the child (or redirect it),
(b) scope the child to a sub-rect (coords + window dims), and (c) type-erase the
child so a launcher can hold a heterogeneous list.

---

## 2. Cross-cutting requirements (apply to ALL five solutions)

These are independent of the embedding strategy; design once, reuse.

### 2a. initState / uninitState + leak verification
- New child contract: `init(gpa, *Frame) !State`, `deinit(gpa, *State) void`,
  `update(*Frame, *State) void`. `deinit` frees everything `init` allocated
  (Font atlas, UiHost.ctx arena, any heap).
- Per-child LEAK CHECK: give each child its OWN allocator =
  `std.heap.DebugAllocator(.{})` wrapping `std.heap.wasm_allocator`. It tracks
  every alloc on wasm and reports leaks/double-frees on `deinit()`. The launcher,
  on reset/kill: call the child's `deinit(gpa, &state)`, then
  `dbg.deinit()` → if it reports leaks, log/assert with the child's name. Start→
  reset→start in a loop = a leak regression test we can't get any other way.
- GPU-RESOURCE CAVEAT (must flag): `init` also creates GPU buffers/textures/
  pipelines via the DEVICE, not via `gpa`. The CPU DebugAllocator won't see those.
  Options: (i) accept CPU-only leak checking v1 (catches the Font/UiHost/heap
  class, which is most user code); (ii) add a per-child GPU-handle counter on the
  device wrapper (alloc++/free--) and assert zero on reset; (iii) give each child
  a child-scoped pipeline/bind-group cache that's dropped wholesale on reset.
  Recommend (i)+(ii-lite): CPU leak check now, a coarse GPU handle count later.

### 2b. Input routing + coordinate translation
- The launcher owns ONE input stream. It must pick the FOCUSED/hovered child and
  translate global mouse/touch coords into child-local coords (subtract cell
  origin / invert the child's transform), and gate keyboard to the focused child.
- Minimum v1: route by hover (mouse inside cell rect) + a click-to-focus for
  keyboard; children outside focus get "no input" (their UiHost sees no mouse).
  This is the same translation the scoping needs (2c), reused for input.

### 2c. The scoping transform (the shared primitive)
Whatever the strategy, a child needs: coords offset+scaled into its rect, and
`f.window` reporting the rect (not the canvas). Define ONE `Viewport { x, y, w,
h }` and ONE transform; solutions differ only in WHERE it's applied (ortho bake,
GPU viewport, or an offscreen texture's natural space).

### 2d. The single-root-export fact → "main ownership"
There is exactly one `update`/`_initialize` export per wasm. So:
- A MULTI-APP binary's root is ALWAYS a launcher (it owns `zimr_app`/`main`).
- An example MAY still keep its own `pub fn main` for STANDALONE builds: when the
  standalone is the root, its `main` runs; when the example is embedded, the
  LAUNCHER is the root and the example's `main`/`zimr_app` are simply never
  referenced → dead-code-eliminated. So "an example contains its own main" and
  "an example is embeddable" are NOT in conflict — they're different roots.
- The cleanest expression: the example exposes a DESCRIPTOR (State + init/deinit/
  update/config) that BOTH a one-line standalone `main` AND the launcher consume.
  Then "there's always a launcher" is true, but a standalone's launcher is a
  trivial shim that can live in the example file (opt-in) or be generated.

---

## 3. The five solutions

Notation: "scope" = how a child is confined to its rect; "frame ops" = what
happens to the child's begin/clear/end; "mod" = how much an existing example
changes.

### S1 — Tickable App; the launcher is just another App
- Split `App.run` into `App.init(cfg, State, init, deinit, update) → *App`
  (builds runtime-less app object: allocates state via its own DebugAllocator,
  runs init) and `App.tick(f)` (today's update-export body, MINUS surface
  acquire). The wasm `update` export calls `root.tick(realFrame)` where `root` is
  the one root App (the launcher).
- A child is an `App`. The launcher (itself an App) holds `[]*App` and in its
  tick: `beginDrawing` ONCE, then per child `child.tickViewport(f, cell)` which
  pushes a Viewport scope on WgpuGl (offset+clip + window-dims override), calls
  the child's update_fn, pops. `endDrawing` ONCE.
- Frame ops: the child's `update` must NOT begin/clear/end (the launcher owns the
  frame). To tolerate unmodified examples that DO call them: in "child mode"
  `beginDrawing` = no re-acquire (just set viewport + scissored clear of the
  cell), `endDrawing` = flush only (no present).
- mod: examples mostly unmodified IF they don't begin/clear/end; otherwise the
  child-mode interception handles them. scope: ortho-bake or GPU viewport.
- + App is a clean reusable unit (state+init/deinit+update+leak alloc); recurses
  (an App's tick can host child Apps). − "child-mode begin/clear/end" is subtle;
  `active_app` global still exists (now "root app").

### S2 — `pub const app: AppDef` descriptor; uniform launcher; no example main/globals
- Each example REPLACES `main`+`zimr_app` with a comptime descriptor:
  `pub const app = z.defineApp(State, .{ .init = initState, .deinit = uninitState,
  .update = update, .config = .{...} });`. `defineApp` type-erases into
  `AppDef { state_size, init: *const fn(gpa,*Frame)anyerror!*anyopaque, deinit,
  update: *const fn(*Frame,*anyopaque)void, config }` (the launcher holds a slice
  of these). No globals in the example, no `main`.
- Standalone: a tiny generated `main` (or `z.runOne(@import("ex").app)`).
  Multi-app: `z.MultiApp.init(allocator, &.{ ex1.app, ex2.app, ... })`.
- Frame ops + scope: same Viewport mechanism as S1 (launcher owns the frame,
  pushes a scope per child). Children authored to the "render into current frame
  at current viewport" contract (no begin/clear/end of their own).
- mod: EVERY example's harness changes (main → `pub const app`), but the body
  (update) only changes by dropping begin/clear/end. scope: viewport.
- + Least magic, ZERO example globals, one uniform launcher, trivially does
  single AND multi, descriptor is plain data. − Touches every example; an example
  can no longer "just run" without a launcher (but the standalone shim is one line).

### S3 — Minimal: per-example tick split + a `pushViewport` stack
- Smallest engine change. Add to WgpuGl: `pushViewport(rect)` / `popViewport()`
  (a stack that offsets+clips all subsequent draws and overrides the `f.window`
  dims the child reads). Keep `App`/`run`/exports as-is.
- The example splits `update` into a body that draws into the CURRENT frame at the
  CURRENT viewport (no begin/clear/end). The example's OWN `main` (kept) wraps
  that body in begin/clear/end for standalone. The launcher wraps each child's
  body in `pushViewport(cell)` + scissor + call + `popViewport()`.
- mod: a real per-example refactor (extract the no-frame body), but mechanical and
  matches what the gallery sub-apps already look like. scope: viewport stack.
- + Tiny, explicit, no new type system, example keeps its main. − Every example
  refactored by hand; standalone main duplicates begin/clear/end boilerplate;
  doesn't by itself solve type-erasure (launcher still needs a vtable per child —
  fold in S1/S2's AppDef).

### S4 — Scoped sub-Frame (`Frame.sub(rect)`); children 100% unmodified
- Revive the capability thin-frame dropped (minus vtable substitution). Engine
  adds `parent.childFrame(rect) Frame` (a.k.a. `Frame.sub`): a Frame whose `gl`
  offsets+clips to rect, whose `window` reports rect size, and whose
  `beginDrawing` = set viewport (NO surface acquire — host already opened the
  frame), `clearBackground` = scissored clear of rect only, `endDrawing` = flush
  (no present). Input coords pre-translated into rect-local.
- The launcher opens the real frame, then per child:
  `child.update(parent.childFrame(cell), &child_state)` — the child's update is
  the UNMODIFIED example (begin/clear/draw/end against `f.window`) and it Just
  Works because the sub-Frame makes `f.window` = cell and frame ops cell-scoped.
- mod: ZERO (the northstar, fully met). scope: baked into the sub-Frame.
- + True drop-in of any example unchanged; recurses (sub of a sub). − Most
  "magic": the Frame silently remaps begin/clear/end + window + coords; the
  "begin doesn't acquire / clear is scissored / end doesn't present" rules are
  the subtle part and must be airtight (a child that assumes a real clear of the
  whole target, or queries backing size, can surprise).

### S5 — Render-to-texture per child + composite (uses existing RTT)
- Each child renders into its OWN offscreen `WgpuRenderTexture` sized to its cell.
  The child genuinely owns a full frame — just an offscreen one at texture size:
  its `clearBackground` clears ITS texture, full-canvas sizing == texture size, no
  coordinate offset needed. The launcher composites the N textures to the screen
  with `drawTexture(rt, cellRect)`.
- Mechanism is mostly built: `loadRenderTexture` + `beginTextureMode(gl, rt,
  clear)` + `endTextureMode` + `drawTexture` exist. The remaining work: in "child
  mode" the child's `beginDrawing`/`clearBackground` must map to
  `beginTextureMode(child_rt, clear)` and `endDrawing` to `endTextureMode` (i.e.,
  redirect the child's frame ops to its texture instead of the surface), and the
  launcher resizes each rt on canvas/cell resize then composites.
- mod: ZERO for the child body (full clear + full coord space in its texture).
  scope: the texture's natural space + a composite draw.
- + STRONGEST isolation (each child truly owns its frame; clears/scissors/passes
  naturally per-child; per-child leak + GPU-handle accounting is cleanest;
  recurses via nested RTT; great for "freeze/snapshot a child"). − N offscreen
  textures = VRAM + N extra render passes + a composite pass; resize handling per
  texture; still needs the begin/clear/end → texture redirect (same interception
  shape as S4, but the target is a texture, not a viewport).

---

## 4. Evaluation axes

| Axis                         | S1 tickable | S2 descriptor | S3 viewport-min | S4 sub-Frame | S5 RTT |
| ---------------------------- | ----------- | ------------- | --------------- | ------------ | ------ |
| Example body modification    | low         | low           | medium          | none         | none   |
| Example harness modification | low         | HIGH (all)    | low (keep main) | none         | none   |
| Engine complexity            | medium      | medium        | LOW             | med-high     | high   |
| "Magic" (hidden remap)       | some        | least         | least           | most         | medium |
| Globals removed              | partial     | YES (best)    | no              | partial      | partial|
| Child isolation strength     | medium      | medium        | medium          | medium       | HIGH   |
| Recurses (multi-in-multi)    | yes         | yes           | yes             | yes          | yes    |
| Input routing fit            | good        | good          | good            | good         | good   |
| Leak-check fit (CPU)         | good        | good          | good            | good         | best   |
| Keep example's own main?     | optional    | shim only     | YES             | YES          | YES    |
| Memory / perf cost           | low         | low           | low             | low          | higher |

---

## 5. The "main ownership" answer (my read)

You CAN have both. The single-root-export constraint only means the MULTI-APP
build's root is a launcher; an example's own `main` is harmless there (DCE'd when
not the root). So the question isn't "main XOR embeddable" — it's "what does the
example EXPOSE that both a standalone main and the launcher consume?"

- If we want zero example globals (your stated preference), S2's `pub const app`
  descriptor is the cleanest: the example exposes data, a one-line standalone shim
  (or generated main) runs it, the launcher lists it. "Always a launcher" — but a
  trivial one for standalone.
- If we want examples to keep a real `main` for run-it-directly ergonomics, S3/S4/
  S5 allow it: the example keeps `main` for standalone; the launcher references
  only its init/deinit/update/State.

Recommendation: make the DESCRIPTOR the source of truth (S2-style `defineApp`),
and let `main` be OPTIONAL sugar — a 1-line `pub fn main() { z.runOne(app); }` an
example may include or omit. That removes globals/magic, keeps single-file run
possible, and gives the launcher a clean uniform list.

---

## 6. My recommendation for evaluation

Two finalists, depending on appetite for engine work vs example churn:

- BEST "simple + no magic + no globals": S2 (descriptor) for the harness +
  S3 (viewport stack) for the scoping. Children are authored "frame-less" (no
  begin/clear/end; draw into the current frame/viewport). Cost: touch every
  example's harness + drop begin/clear/end from its update. Payoff: the cleanest
  mental model, explicit data, easy leak/uninit, easy recursion. This is the one
  I'd pick if we're willing to reshape examples (you said you are).

- BEST "zero example modification (true drop-in)": S5 (RTT-per-child), because the
  mechanism mostly exists and isolation is strongest; or S4 (sub-Frame) if we want
  to avoid the VRAM/extra-pass cost and accept more frame-op-interception magic.
  Pick S5 if "freeze/snapshot/reset a child cleanly" and per-child GPU accounting
  matter; pick S4 if memory/perf is tight and most examples are light 2D.

DECISIONS TO MAKE TOGETHER:
1. Are we willing to reshape every example's HARNESS (→ S2) and BODY (drop
   begin/clear/end → S3)? If yes, S2+S3 is the clean target.
2. Or is "any example, byte-for-byte" non-negotiable (→ S4 or S5)?
3. Leak scope v1: CPU-only (DebugAllocator) acceptable, or do we want GPU-handle
   accounting from day one?
4. Standalone ergonomics: keep an optional 1-line `main` per example, or go
   launcher-only with a generated standalone?
5. Input v1: hover-routing + click-to-focus enough, or do we need richer focus?

## STATUS
Design only this turn (no code). Five solutions above; awaiting evaluation. Next
action after we pick: spike the chosen scoping primitive (viewport stack OR
sub-Frame OR child-RTT redirect) on `wgpu_gallery` (it's already the manual
version of all three), then convert one real example as the proof.


# ============================================================================
# LOCKED DESIGN (rubberducked turn ~1034) — "Launcher + scoped Frame"
# ============================================================================

Decided with Simon, one question at a time. Values that drove every call: NO
globals (in example code), NO hidden/ambient state, functions take what they
need as ARGUMENTS, simplest-that-works; willing to rewrite ALL examples.

## The six decisions
- D1 (frame contract): the LAUNCHER owns beginDrawing/clearBackground/endDrawing.
  A child's per-frame fn just DRAWS into the scoped Frame it is handed, in LOCAL
  coords, as if it owns a small screen. The scope rides in the Frame argument —
  no global, no ambient mode. Every example's update STOPS calling begin/clear/
  end and STOPS reading the full canvas (reads f.window = its cell).
- D2 (alloc + leaks): each child gets its OWN std.heap.DebugAllocator wrapping
  the wasm allocator, passed EXPLICITLY to init(gpa,...) / deinit(gpa,...). reset
  = deinit then assert that allocator came back EMPTY (leak reported w/ child
  name). CPU-heap detection only for v1; GPU resources are a known blind spot
  (revisit with a GPU-heavy example; coarse device-handle counter later).
- D3 (registration): examples are DESCRIPTOR-ONLY (no per-example main, no
  zimr_app global). One generic RUNNER owns the entry point + the single
  unavoidable global (the root-app pointer behind the wasm `update` export —
  irreducible because the export has nowhere to receive a handle). Standalone =
  runner with one root app full-screen; multi = runner with a launcher root.
- D4 (placement dims): a placement is an OFFSET + UNIFORM SCALE; scale=1 is the
  1:1/reflow case (f.window = cell), scale<1 is the fit/thumbnail case (f.window =
  design size, mapped into the cell). REUSES the existing .responsive/.fit ortho
  math (orthoTopLeft / fitOrtho / fitScaleOffset), just targeting a sub-rect.
  Launcher picks per placement.
- D5 (input): CURSOR-ROUTED. Mouse+keyboard go to the child under the cursor,
  coords run through the same offset+inverse-scale map. NO stored focus. Only
  state = event-scoped DRAG-CAPTURE (a held button stays with the child it
  started on until release; cleared on mouse-up) so cross-edge drags don't jump.
  Keyboard follows the cursor for v1 (fine until text input lands; click-to-focus
  layers on later).
- D6 (launcher): a THIN PRIMITIVE the user drives — `add`/`reset`/`remove`/`tick`.
  No imposed UI, no hidden layout. The all-examples gallery is itself an EXAMPLE
  app built on the primitive (dogfoods it; stays inspectable). Recursion is free.

## The crystallized model
- RUNNER: owns the wasm `update` export, the one global, and the SINGLE
  beginDrawing/clearBackground/endDrawing per frame. Ticks ONE root app into the
  full canvas (placement = whole canvas, scale 1).
- APP (example OR launcher): just `{ config, init, deinit, update }`. update draws
  into the scoped Frame it's given; NEVER begins/clears/ends.
- LAUNCHER: an app whose update ticks sub-children into sub-rects via the
  primitive. Because begin/clear/end live ONLY at the runner, children at ANY
  depth just draw into the already-open frame at their viewport → multi-in-multi
  is free and uniform.
- A child draws its OWN background (fill its rect), because clearBackground is the
  launcher's (consequence of D1) — so a child looks identical standalone vs
  embedded. The runner's one clearBackground just wipes the canvas before any app.

## Sketch types (names provisional)
```zig
// Example file — pure data, no globals, no main:
pub const app: z.AppSpec(State) = .{
    .config = .{ .title = "...", .width = 800, .height = 450 },
    .init   = init,    // fn(gpa: Allocator, f: *Frame) anyerror!State
    .deinit = deinit,  // fn(gpa: Allocator, s: *State) void  (frees ALL init alloc'd)
    .update = update,  // fn(f: *Frame, s: *State) void        (draws into f's viewport)
};

// z.AppSpec(State) is comptime-typed at the example; z.eraseApp(app) → AppVtable
// (the type-erased form the launcher/runner hold, like run()'s current Thunk):
const AppVtable = struct {
    config: Config,
    state_size: usize, state_align: usize,
    init:   *const fn (Allocator, *Frame, *anyopaque) anyerror!void, // into ptr
    deinit: *const fn (Allocator, *anyopaque) void,
    update: *const fn (*Frame, *anyopaque) void,
};

// Placement = where + how big the child's screen maps onto the canvas.
const Placement = struct { rect: Rectangle, mode: enum { reflow, fit } };

// The thin launcher primitive (user-driven):
//   add(spec)            -> ChildId   (alloc child + own DebugAllocator; run init)
//   reset(id)            -> void      (deinit; assert allocator empty; re-init)
//   remove(id)           -> void
//   tick(f, id, place)   -> void      (set scoped frame + translate input; child.update)
// A ChildRec = { vtable, dbg: DebugAllocator, state_ptr, drag_capture: bool }.

// The runner (engine): owns the `update` export + the lone global + the single
// begin/clear/end; ticks the root app full-screen. Standalone build picks the
// root via -Dexample=NAME wiring; multi root is a launcher example.
```

## Authoring rules (the per-example contract)
- update(f, s) draws into f's viewport in LOCAL coords; reads f.window for its
  size; does NOT call beginDrawing/clearBackground/endDrawing.
- Draw your own background (fill the viewport); don't rely on clearBackground.
- deinit(gpa, s) must free EVERYTHING init allocated through gpa (Font, UiHost,
  buffers) — the reset leak-check enforces it.
- No module-scope mutable state (no globals); per-run state lives in State.

## Implementation plan (phased; each shippable)
- P1 SPIKE — the scoped-frame primitive on WgpuGl: `pushViewport(placement)` /
  `popViewport()` = build the offset(+scale) ortho (reuse fitOrtho), INTERSECT the
  cell scissor with any existing clip, and override the f.window dims the child
  reads; restore on pop. Prove it by converting wgpu_gallery's 4 cells to use it
  (it's already the MANUAL version — explicit vp rects + scissor). No API churn
  yet; just the primitive + gallery using it.
- P2 — AppSpec(State) + eraseApp + the runner. Convert ONE example (e.g.
  wgpu_starfield_effect) to descriptor-only; run it via the runner standalone
  (root app full-screen). Verify pixel-identical to today. This is where main/
  zimr_app leave the example.
- P3 — the Launcher primitive (add/reset/remove/tick) + per-child DebugAllocator
  + reset leak-check (loop start->reset->start, assert empty). Build
  examples/wgpu_gallery_all/ = a launcher example hosting several real example
  apps in a grid (the northstar gallery), with start/reset on tap.
- P4 — cursor-routed input + drag-capture + inverse-scale, inside tick().
- P5 — migrate ALL examples to descriptor-only (the bulk rewrite). Delete the old
  App.run/main/zimr_app path once empty.
- LATER — GPU-resource leak accounting; host a child inside a ui.zig window
  (the child-ui unification: a window's content rect becomes the placement rect —
  the primitive is already forward-compatible).

## Open mechanism notes (not forks — resolve in implementation)
- Nested scissor must INTERSECT (a child's own beginScissorMode ∩ its cell clip),
  not replace. pushViewport saves/restores the clip stack.
- init() runs mid-loop on add/reset and needs a Frame with a live GPU device (for
  loadFont/buffers). The launcher synthesizes one (device is always available);
  viewport is irrelevant during init (no drawing).
- Standalone build wiring: the runner is the root; `-Dfocus`/`-Dexample` selects
  which example's `app` the runner ticks full-screen.
- The ONE global (root-app pointer behind `update`) lives only in the runner.

## STATUS
Design LOCKED (D1-D6 above). No code yet. NEXT: P1 spike — add pushViewport/
popViewport to WgpuGl and convert wgpu_gallery to it (the manual version already
exists, so it's a faithful, low-risk first proof). Awaiting go-ahead.

# ----------------------------------------------------------------------------
# P1 LANDED (turn ~1035) — pushViewport/popViewport + gallery converted
# ----------------------------------------------------------------------------
- KEY MECHANISM FOUND: WgpuGl already applies a CPU-side MODELVIEW matrix to every
  vertex (vertex3f = zm.mulMatVec(self.modelview, v)); the projection ortho lives
  in the per-frame UBO. So a child's cell placement goes in the MODELVIEW (a
  translate+scale), NOT the UBO. This sidesteps the blocker that writeUbo writes
  the view-projection IN PLACE at offset 0 (so per-cell VPs in one frame would
  collapse to the last write). With the modelview approach the ortho stays
  constant all frame and every cell's verts are baked correctly at emit time —
  N viewports, one open pass, no UBO conflict. Verified all gallery primitives
  (drawRectangleRec/drawText/drawTriangle/drawCircle/drawLineEx) route through
  gl.vertex2f, so the modelview places shapes AND text.
- ENGINE (src/wgpu_app.zig): added `Placement {rect, logical_w, logical_h,
  scale_to_fit}`, an 8-deep viewport save stack on App, and free fns
  `pushViewport(f, placement)` / `popViewport(f)`. push: flush; save modelview +
  f.window; set modelview = translate(ox,oy)*scale(s) (s=1 reflow, s=min fit,
  centered); set cell scissor (logicalToBacking); set f.window = logical size.
  pop: flush; restore modelview + f.window; reset scissor to full surface.
  Re-exported as z.pushViewport / z.popViewport / z.Placement.
- GALLERY (examples/wgpu_gallery): rewritten so each sub-app draws in LOCAL coords
  reading f.window for its size (exactly the future embedded-example contract — no
  begin/clear/end, no absolute offsets), and the host drives pushViewport(cell) ->
  sub-app -> popViewport per cell (1:1 reflow). Sub-apps draw their own bg rect.
- GATES: lint 0/351, wgpu-gallery-standalone rc 0 (760 KB), smoke PASS (init 28,
  ~226/frame). Build was ~30s (Zig 0.17 incremental — only the new decls).
- KNOWN/DEFERRED (noted in code): nested-scissor INTERSECTION (a deeper child's
  clip widens back to full until it reclips — fine for a flat grid); a child that
  loadIdentity's the modelview would reset to true identity, not the cell base
  (no 2D example does this; revisit when migrating one that does); f.window
  override + scale exercised by reflow now, fit path written but proven in P3.
- AWAITING: Simon's screenshot that the 2x2 grid still renders correctly (cells
  placed + clipped, text inside cells) — the modelview routing is verified by
  analysis + smoke, the VISUAL verdict is the screenshot.
- NEXT: P2 — AppSpec(State) + eraseApp + the runner; convert wgpu_starfield_effect
  to descriptor-only and run it standalone via the runner, verify pixel-identical.

# ----------------------------------------------------------------------------
# P2 LANDED (turn ~1036) — AppSpec + runner; starfield_effect is descriptor-only
# ----------------------------------------------------------------------------
- ENGINE (src/wgpu_app.zig): `AppSpec(StateT)` = a comptime struct { config, init,
  deinit, update } with `pub const State = StateT`. Fns are plain `fn` types (not
  ptrs) so a comptime `pub const app` lets the runner pass init/update to App.run
  comptime — no type-erasure needed yet (eraseApp is P3, for the heterogeneous
  launcher list). Re-exported as z.AppSpec.
- RUNNER (src/wgpu_runner.zig, NEW): the generic exe root for a descriptor-only
  app. Imports the example as the `user_app` module, declares `std_options`
  (must be on the ROOT, not the example), owns `zimr_app` + `main`, and ticks the
  app full-screen via a wrapper that does beginDrawing -> spec.update -> endDrawing
  (reusing App.run — fully ADDITIVE; App.run is untouched, old-shape examples keep
  working). `_initialize` calls the runner's main, same as any example.
- BUILD (build.zig): `addWgpuApp(name,title)` mirrors addWgpuExample but roots the
  exe at src/wgpu_runner.zig and wires the example as the `user_app` module (with
  the example's imports: zimr_wgpu/zm/shader_interface/wgpu_common/fonts). Output
  paths / smoke / standalone identical. starfield_effect re-registered via it.
- EXAMPLE (wgpu_starfield_effect): now `pub const app = z.AppSpec(State){...}` and
  NOTHING else — no main, no zimr_app, no std_options. update drops begin/clear/
  end and paints its own background (drawRectangleRec over its viewport) so it
  works full-screen now and in a cell later. init/deinit/update are the contract.
  deinit frees the UiHost; Font has no unloadFont yet (P3's leak check will force
  one — standalone never calls deinit so it doesn't bite now).
- GATES: lint 0/352 (wgpu_runner.zig is a new linted src file), standalone rc 0
  (1.117 MB), smoke PASS (init 28, ~598/frame -> runner main ran + app updates).
- This is where main/zimr_app/std_options LEFT the example. Old-shape examples are
  untouched (still on addWgpuExample/App.run); the two paths coexist (additive).
- AWAITING: Simon's screenshot that the descriptor-only starfield is pixel-identical
  to before (stars stream, panel works, Atkinson font, console quiet).
- NEXT: P3 — eraseApp -> AppVtable (type-erase for a heterogeneous list); the
  Launcher primitive (add/reset/remove/tick) with a per-child DebugAllocator +
  reset leak-check; build examples/wgpu_gallery_all/ hosting several real
  descriptor apps in a grid via pushViewport + tap-to-reset. (Will surface the
  need for unloadFont via the leak check.)

# ----------------------------------------------------------------------------
# P3 LANDED (turn ~1037) — eraseApp + Launcher + wgpu_gallery_all
# ----------------------------------------------------------------------------
- ENGINE (src/wgpu_app.zig):
  * AppVtable = type-erased AppSpec { config, state_size, state_align,
    init/deinit/update over *anyopaque }. eraseApp(comptime spec) wraps the typed
    fns in thunks that cast the slot to *State (init constructs straight into the
    slot — no move, so self-referential State stays valid). Same comptime-thunk
    trick App.run already uses. Re-exported z.AppVtable / z.eraseApp.
  * Launcher (z.Launcher) + ChildId. Holds heap-allocated Recs (so each child's
    allocator never moves under an ArrayList realloc). Each Rec = { vt, dbg:
    DebugAllocator(.{ .safety = true }), state slot (aligned via alignedAlloc +
    Alignment.fromByteUnits(16), asserts state_align<=16), alive }. API:
      add(f, vt) -> ChildId   (alloc slot + own dbg; run vt.init)
      tick(f, id, placement)  (pushViewport -> vt.update -> popViewport)
      reset(f, id)            (vt.deinit -> dbg.deinit()==.leak? LOG -> fresh dbg
                               -> vt.init)   leak is logged, not fatal
      remove via deinit-all; deinit() tears everything down.
    CRITICAL: .safety=true is forced because DebugAllocator's default `safety` =
    runtime_safety, which is OFF in ReleaseSmall (our standalone) — without it the
    leak check would be a no-op in release.
- EXAMPLE (examples/wgpu_gallery_all): a LAUNCHER app (descriptor-only, addWgpuApp)
  hosting FOUR inline toy descriptor apps with DIFFERENT State types (bouncer /
  pulse / spinner / orbit) — proves type-erasure. 3 use reflow placement, orbit
  uses scale_to_fit (300x300 design letterboxed into its cell) — proves both
  placement modes. Tap a cell -> launcher.reset(that child): the toys allocate
  NOTHING, so the reset leak-check passes silently (a clean reset). The four are
  inline (no cross-example import) to keep P3 self-contained.
- GATES: lint 0/353, wgpu-gallery-all-standalone rc 0 (680 KB), smoke PASS
  (init 7, ~66/frame -> runner main ran, launcher added 4, all update).
- VERIFY (Simon): open wgpu_gallery_all.html -> four animating cells (ball /
  pulsing disc / rotating triangle / orbiting dot letterboxed); tap any cell to
  reset it (ball back to start, etc.). The leak check is runtime/browser-only
  (a tap triggers reset); it's clean for these no-alloc toys.
- DEFERRED / NEXT (in order):
  * tick() does NOT yet translate INPUT into the child's local/scaled space — the
    toys don't read input so it didn't bite, but interactive children (the UI
    examples) need it. That's P4: cursor-routed input + inverse-scale +
    drag-capture, applied inside tick().
  * unloadFont (+ free loadFontFromTtf's temp) so FONT-using real examples have a
    clean teardown; THEN host real examples (starfield, UI ones) in cells — which
    also needs the build to wire cross-example imports into a launcher (the
    "gather ALL examples" step). The leak check is exactly what will flag a
    missing unloadFont.
  * MENU-CHOOSER (Simon's idea): a launcher VARIANT — an app whose update shows a
    menu (UiHost) listing apps; on select it ticks the chosen child full-screen;
    a back button returns to the menu. No new machinery: it's a launcher app that
    picks WHICH child to tick and WHERE. Natural once real examples are hosted.
  * P5: migrate all examples to descriptor-only; delete App.run/main/zimr_app.
- PER-TURN zip (zimr1037).

# ----------------------------------------------------------------------------
# P5 STARTED + scope narrowed (turn ~1038)
# ----------------------------------------------------------------------------
SCOPE (per Simon): goal = any example hostable in the multi-app gallery + the
door open for start/end (Launcher.add/reset already provide it). LEAK CHECK IS
DEBUG-ONLY — so DebugAllocator's `safety` default (runtime_safety: on debug / off
release) is exactly right; the forced `.safety = true` was REMOVED. Don't gold-
plate the gallery (input scoping for hosting INTERACTIVE examples in a cell is
deferred — not a blocker for standalone or for non-interactive thumbnails). Get
back to porting new wgpu examples (now directly in the descriptor shape) soon.

MIGRATED to descriptor-only this turn (now run standalone via the runner):
wgpu_ui_pomodoro_phone, wgpu_ui_window_menubar (+ starfield_effect from P2).
gates: lint 0/353, both standalone rc 0, smoke PASS (pomodoro ~283/frame,
menubar ~2050/frame). ~44 wgpu examples remain on App.run/addWgpuExample.

## MIGRATION RECIPE (App.run example -> descriptor-only) — mechanical
1. Delete `pub const std_options = z.std_options;`  (it lives on the runner now).
2. Delete `pub var zimr_app: z.App = .{};` and the whole `pub fn main()` (which
   was just `zimr_app.run(cfg, State, initState, update)`); KEEP the cfg.
3. Add:  pub const app: z.AppSpec(State) = .{ .config = <the cfg from main>,
          .init = init, .deinit = deinit, .update = update };
4. Rename `initState` -> `init`.
5. In `update`: delete `z.beginDrawing(f.gl);` + `defer z.endDrawing(f.gl);`, and
   turn `z.clearBackground(f.gl, COL)` into the app drawing its OWN background:
   `z.drawRectangleRec(f.gl, .{ .x=0,.y=0,.width=f.window.widthf(),.height=f.window.heightf() }, COL)`
   (hoist w/h + a color const to stay <=120 cols). EXCEPTION: if a fullscreen UI
   panel already covers the surface (e.g. pomodoro), just drop begin/clear/end —
   no fill needed.
6. Add `fn deinit(gpa: std.mem.Allocator, s: *State) void { ...free init's allocs... }`
   — UiHost: `s.ui_host.deinit();`  (Font has no unloadFont yet; the debug-only
   leak check will flag it if/when a launcher resets the app — fine for now).
7. build.zig: change the example's `addWgpuExample(...)` call to `addWgpuApp(...)`
   (identical args).
8. Verify: zig build wgpu-<name>-standalone -Dmode=release ; smoke -Dfocus=wgpu_<name>.
GOTCHAS: the bg-fill line trips line-length (use a color const); the widget/draw
body is otherwise UNCHANGED; std_options MUST leave the example (root-only).

## NEXT
- Migrate the remaining ~44 wgpu examples with the recipe (batchable). NEW wgpu
  ports go straight to the descriptor shape — so "resume porting" == this.
- When we WANT a real example IN the gallery interactively: add input scoping to
  pushViewport (translate+gate the mouse into the child rect) + a `hosted` cross-
  example-import to addWgpuApp. Until then the gallery hosts the toy apps; real
  examples run standalone via the runner.
- unloadFont eventually (debug leak check will nag); the menu-chooser launcher
  variant whenever desired.
- PER-TURN zip (zimr1038).

## BUGFIX (turn ~1039): per-window menu bar labels drew at canvas y=0
- Simon's screenshot of wgpu_ui_window_menubar: the menu-bar STRIP rendered under
  each window's title bar, but File/Edit/View were missing. Root cause in SHARED
  ui.zig `openMenu`: the menu-button rect hardcoded `.y = 0` — correct for the
  MAIN menu bar (top-of-screen, y=0) but wrong for a PER-WINDOW bar (this example's
  windows are at y=32+), so labels drew (and hit-tested) at the canvas top instead
  of in the window's strip. NOT a migration regression (the per-window bar was
  never visually verified in either backend).
- FIX: `.y = ctx.menu_bar_bottom_y - button_h`. menu_bar_bottom_y = bar_top + bar_h
  for BOTH paths (main: bottom=height -> 0, unchanged; per-window: win.pos.y +
  title_h), so labels land in the strip and the hover hit-test follows. Fixes GL
  too (shared ui.zig). gates: lint 0/353, menubar standalone rc 0, smoke PASS.

## BUGFIX (turn ~1040): menu bar had no single-open / no hover-tracking
- Symptom (Simon, touch): swiping View->Edit left BOTH highlighted blue and View
  stayed open. Root cause in SHARED ui.zig `openMenu`: each menu was an INDEPENDENT
  toggle in `popup_open` — no "only one open per bar", no hover-tracking. Plus a
  click on a menu's own button counted as "outside" to dismissPopupsOnClickOutside.
- FIX (imgui menu-bar behaviour; helps GL too):
  * New ctx.bar_open_menu (?Id) = the ONE menu the bar treats as open (intent),
    + ctx.bar_open_menu_btn (its button rect for the dismiss exclusion).
  * openMenu now: (0) clear intent if its popup was dismissed externally; (1)
    HOVER-TRACKING — once a menu is open, hovering a different label switches to
    it (this is the swipe behaviour); (2) click TOGGLES (open<->close); (3)
    SINGLE-OPEN — any menu open but not the designated one closes.
  * dismissPopupsOnClickOutside skips the open menu's own button (that click is the
    toggle, handled in openMenu — not an outside click), so click-to-close works
    instead of dismiss-then-reopen.
- Result: one menu open at a time; swipe across the bar switches the open menu;
  click opens/switches/closes; click-outside closes. (Minor: a 1-frame transient
  when hover-switching to a menu submitted LATER in the bar; self-corrects next
  frame — invisible at 60-120fps.)
- gates: lint 0/353, menubar standalone rc 0, smoke PASS.

# ----------------------------------------------------------------------------
# P5 BATCH 1 (turn ~1041): the addWgpuExample cluster -> descriptor (20 examples)
# ----------------------------------------------------------------------------
- Added z.clearViewport(f, color) — fills the CURRENT viewport (f.window) with a
  color. The descriptor-app replacement for clearBackground (a child can't clear
  the pass): same call works full-screen or in a launcher cell.
- Wrote tools/migrate (scratch, /tmp): conservative descriptor migration — removes
  std_options + zimr_app, brace-parses `zimr_app.run(cfg,State,init,update)` into
  `pub const app = z.AppSpec(State){...}`, generates a deinit (ui_host.deinit() if
  the State has a UiHost, else no-op), and rewrites the update frame ops
  (drop beginDrawing/endDrawing; clearBackground(f.gl,..) -> clearViewport(f,..)).
  Skips + reports anything off the standard shape.
- Migrated the 20 addWgpuExample examples (incl. the P1 wgpu_gallery): ecs_boids,
  fractal_tree, gallery, lines_bezier, lines_drawing, math_angle_rotation,
  math_sine_cosine, rectangle_scaling, recursive_hud, render_texture,
  shapes_showcase, simple_particles, trails, triangle_gradient, ui_color_picker,
  ui_combo_custom, ui_custom_widget, ui_plotting_basic, vector_angle, writing_anim.
  Then swapped all `_ = addWgpuExample(` -> `_ = addWgpuApp(` (the fn def stays).
- GOTCHA: the script output isn't auto-formatted -> the `zig fmt --check` build gate
  failed; `zig fmt examples` fixed it. (camera2d + colors_palette were over-migrated
  — they're MANUAL blocks, not addWgpuExample — reverted from the original zip.)
- GATES: lint 0/353, zig fmt --check clean, smoke PASS x10 (ui_color_picker, render_
  texture/RTT, ecs_boids, gallery/multi-app, shapes_showcase, fractal_tree, trails,
  simple_particles, recursive_hud, writing_anim), 4 standalones rc 0.
- Descriptor-only examples now: 24 (4 prior + these 20). RTT (render_texture) and a
  multi-app (gallery via pushViewport) both migrated cleanly through the runner.
- REMAINING (batch 2): the ~33 addWgpuStandalone bespoke demos (fractals/3D/compute)
  — their FILES are mostly standard-shape too, but their BUILD blocks wire custom
  shaders/3D/compute, so they need addWgpuApp to grow optional custom-shader wiring
  (or per-example care). Plus camera2d/colors_palette (manual blocks). NEW wgpu
  ports go straight to the descriptor shape.
- PER-TURN zip (zimr1041).

# ----------------------------------------------------------------------------
# P5 BATCH 2 (turn ~1042): simple-2D manual blocks -> descriptor (21 examples)
# ----------------------------------------------------------------------------
- The simple-2D examples were wired via verbose ~55-line MANUAL build blocks (the
  expanded form of addWgpuApp). Migrated their files (migrate.py) AND replaced
  each manual block with a 14-line addWgpuApp call via a block-replacement script
  (tools scratch /tmp/blocks.py): finds each block by its `.custom = "wgpu-<dash>"`
  InstallDir line, spans to its addWgpuStandalone(...) close, guards against
  CUSTOM wiring (extra addImport / addShader / addCompute -> skip), extracts the
  title, replaces. Dry-ran on a build.zig COPY + ast-checked before applying.
- Converted (21): ball_physics, bouncing_ball, collision_area, colors_palette,
  double_pendulum, easings_ball, easings_box, easings_rectangles, easings_testbed,
  ellipse_collision, hello_world, hilbert_curve, input_keys, input_mouse,
  input_mouse_wheel, kaleidoscope, life, particles, sidebyside, starfield, ui_demo.
  This also DELETED ~21 redundant manual blocks (build.zig much shorter).
- GOTCHAS: script output needs `zig fmt examples build.zig` (fmt --check gate).
  camera2d's registration isn't a standard `.custom` block -> not matched ->
  reverted its file (handle in batch 3). wgpu_particles (simple) vs
  wgpu_compute_particles share a `wgpu_particles_mod`-style abbr but DIFFERENT
  blocks (dash names differ) -> only the simple one converted; compute one intact.
- GATES: build.zig CONFIGURES clean (zig build lint ran it), lint 0/353,
  zig fmt --check clean, smoke PASS x18, 4 standalones rc 0.
- DESCRIPTOR EXAMPLES NOW: 45 of 62. 
- REMAINING (~17, batch 3): SHADER/3D/COMPUTE demos (cube_demo, cube3d, julia,
  mandel_julia, mandelbrot_split, mandel_sidebyside, demo, lambert_demo, pbr_demo,
  gltf_textured, raytracer, rt_shader, shapes_demo, compute_smoke,
  compute_particles, sph_fluid_2d) + camera2d. These keep their manual blocks for
  now because they wire custom shaders/3D/compute modules; addWgpuApp needs an
  optional custom-module/shader hook (a real feature) before they flip. They still
  BUILD + RUN standalone on the old App.run path (additive coexistence).
- PER-TURN zip (zimr1042).

# ----------------------------------------------------------------------------
# P5 BATCH 3a (turn ~1043): latent-break fixes + shader helper + FS fractals
# ----------------------------------------------------------------------------
FIXES (latent breaks from batch-1's broad `addWgpuExample->addWgpuApp` sed, which
swapped ALL registrations but only 20 files were migrated -> 3 examples had an
addWgpuApp registration but no `pub const app`; focused smokes never built them):
  - camera2d, cube3d, 3d_probe: migrated their files. cube3d proves engine-3D
    migrates cleanly through the runner (depth flows via the example config).
  - LESSON (process): the migration gate is the FULL `zig build smoke-test` (no
    -Dfocus), not focused subsets. Full smoke now 50/50 PASS.

BUILD REFACTOR (uniformization): split addWgpuApp into reusable pieces so the
runner/standalone plumbing lives in exactly one place:
  - buildUserMod(...)   -> the example module + standard imports.
  - finishWgpuApp(...)  -> runner-root exe + install/smoke/bundle/standalone.
  - addShaderDep(...)   -> wire ONE shader (VS/FS) by basename: <b>.wgsl + <b>_io.zig
    (+ externs + CPU-side <b>.zig when the shader produced externs). Uniform; over-
    provisions imports (unused module import is lazy/harmless).
  - addWgpuApp = buildUserMod + finishWgpuApp (unchanged signature; 48 calls intact).
  - addWgpuShaderApp = buildUserMod + (addShaderDep per shader) + finishWgpuApp.
    `shaders` is a list of basenames, e.g. &.{ "julia_fs", "wgpu_trivial_vs" }.

MIGRATED via addWgpuShaderApp (each ~120-line bespoke shader block -> ~16-line call):
  julia, mandel_julia, mandelbrot_split. GATES: lint 0/353, fmt clean, smoke PASS.
DESCRIPTOR EXAMPLES NOW: 51.

# --- SIMPLIFICATION / UNIFORMIZATION IDEAS (surfaced; act on incrementally) ---
1. TWO build entry points, not three. addWgpuApp (no shaders) + addWgpuShaderApp
   (shaders by basename) should REPLACE all of: addWgpuExample (legacy), and every
   bespoke manual block. Retire addWgpuExample + the manual blocks once all migrate.
2. NAMING CONSISTENCY. Derive dir/step/standalone/install names from ONE `name`.
   Bespoke blocks used ad-hoc short names (wgpu-shapes for wgpu_shapes_demo, wgpu-cube
   for cube_demo) that mismatch the dir -> migration friction. The helpers already
   derive everything from `name`; rename the few mismatched dirs/standalones to match.
3. DESCRIPTOR-CONTRACT GUARD. A missing `pub const app` on an addWgpuApp example only
   shows as a runtime "no member app" when that exe is built. Add a comptime guard
   and/or always gate on full smoke. (Process fix already adopted.)
4. OPTS/CTX STRUCT. The helpers take 11-13 positional args. Bundle the shared deps
   (smoke_install, focus, target, optimize, zimr_wgpu_mod, zimrmath_mod,
   shader_interface_mod, buildaux_exe, shader_pipeline) into a `WgpuCtx` built once;
   calls become addWgpuApp(ctx, .{ .name, .title, .shaders }). Mechanical 51-call
   churn (scriptable) -> deferred but recommended; lets depth/compute be opt fields.
5. DEINIT GAP. migrate.py emits no-op deinit for non-UiHost examples; shader
   LoadedShader + font atlases aren't freed (debug leak check is CPU-heap only).
   Add unloadFont + LoadedShader.deinit and wire them for clean launcher resets.

REMAINING (~12, batch 3b): demo + mandel_sidebyside (irregular/multi-shader),
3D-custom-VS (cube_demo, lambert_demo, pbr_demo, gltf_textured, rt_shader), compute
(compute_smoke, compute_particles, sph_fluid_2d) [need a compute analog of
addShaderDep -> addWgpuComputeApp], raytracer, shapes_demo (name-mismatched block).
PER-TURN zip (zimr1043).

# ----------------------------------------------------------------------------
# P5 BATCH 3b (turn ~1044): rt_shader + compute helper + compute examples
# ----------------------------------------------------------------------------
- rt_shader: a fullscreen FS (rt_fs + wgpu_trivial_vs) -> addWgpuShaderApp. Fits the
  descriptor frame contract (beginDrawing present).
- NEW: addWgpuComputeApp + ComputeKernel{ basename, workgroup=.{64,1,1} }. Wires the
  `kompute` module + addComputeImport per kernel (compiled -> "<basename>_wgsl").
  Kernels live in the example's own dir, @imported relatively (inherit `kompute`).
  Compute analog of addWgpuShaderApp; finishWgpuApp shared.
- MIGRATED: compute_smoke (kernel double_it), compute_particles (kernel particle_step).
  compute_particles dispatches PER-FRAME and still PASSES inside the runner's frame
  -> z.Compute submits its compute work independently of the render pass. Good: the
  descriptor contract holds for per-frame compute, not just one-shot (compute_smoke).
- GATES: lint 0/353, fmt clean, FULL smoke 55/55 PASS. DESCRIPTOR EXAMPLES NOW: 54/63.

- ARCHITECTURAL BOUNDARY (own-frame 3D): cube_demo/lambert_demo/pbr_demo/gltf_textured
  call Backend.beginFrame(f.gpu)/endFrame — they own their OWN GPU frame (low-level
  custom-pipeline 3D), which collides with the runner owning the frame. They do NOT
  fit the descriptor contract without a rewrite to the engine-3D path (beginMode3D),
  which would change what they demonstrate. DECISION: leave them as manual blocks
  (standalone-functional, additive). The descriptor contract fits 2D + UI + engine-3D
  + fullscreen-shader + compute; own-frame custom-pipeline 3D is out of scope by design.

REMAINING (~9): demo + mandel_sidebyside (irregular multi-shader: embeds/imports don't
pair by basename); cube_demo/lambert_demo/pbr_demo/gltf_textured (own-frame 3D — keep
manual); raytracer; shapes_demo (name-mismatched block); sph_fluid_2d (multi-kernel
compute — the northstar; bespoke). The "two entry points" goal is essentially reached
for everything that fits the contract; the rest are deliberate exceptions or need
per-example care. PER-TURN zip (zimr1044).
