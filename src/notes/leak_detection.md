# leak_detection.md — CURRENT PLAN

Goal: give zimr users confidence they can build **long-running apps that create and
destroy resources constantly** without leaking — while keeping the arena default that
makes simple examples effortless. Approach: a **per-example opt-in flag** that switches
an example from arena-mode to managed-mode, where its `deinit` must free everything and
a smoke gate verifies it did (CPU heap AND GPU handles) before the arena reset (a no-op
in that mode).

Simon's framing (accepted): two independent leak domains.
- **CPU heap** — arena handles examples; Zig's GPA/`testing.allocator` already reports
  un-freed allocations with allocation-site stack traces. Nothing to build; just USE it
  in managed mode.
- **GPU resources** (textures, buffers, bind groups, pipelines, layouts, samplers, shader
  modules, render textures, views) — wgpu handles the arena knows NOTHING about. Clearing
  the arena frees CPU bookkeeping but leaks the GPU objects. THIS is the real risk and the
  focus of the plan.

Per-example flag is the chosen shape (not a separate certified list). Scope/RAII middle-tier
and an always-on handle canary are noted as FUTURE (Phase 5), not part of this pass.

---

## Current GPU create/destroy asymmetry (the blocking gap)

`src/wgpu.zig` has these `createX` with NO matching `destroyX`:
- createBindGroup            → **no destroyBindGroup** (updateRegisteredTexture already drops handles — known)
- createBindGroupLayout      → no destroyBindGroupLayout
- createPipelineLayout       → no destroyPipelineLayout
- createRenderPipeline       → no destroyRenderPipeline
- createComputePipeline      → no destroyComputePipeline
- createSampler              → no destroySampler
- createShaderModuleWgsl     → no destroyShaderModule
- createTextureView(/Array/Mip) → no destroyTextureView

Present: destroyBuffer, destroyTexture. (createCommandEncoder / createBufferInit / createWithData
are transient or wrappers — audit but likely no standalone destroy needed.)

Leak detection is meaningless until every create has a working destroy — **Phase 0 is blocking.**

---

## Phase 0 — Complete the destroy bridge  [BLOCKING]
- [ ] Add JS-side destroy hooks in the wgpu bridge (`src/web/*` bridge + `webtests/runner.mjs`
      mock) for: bind group, bind group layout, pipeline layout, render pipeline, compute
      pipeline, sampler, shader module, texture view. Each drops the handle-table entry.
- [ ] Add the Zig `pub fn destroyX(handle)` wrappers in `src/wgpu.zig` mirroring
      destroyBuffer/destroyTexture.
- [ ] Wire the obvious owners' `deinit` to call them: `Renderer2D.deinit` (bg layouts,
      pipeline layout, blend_pipes[5], shader modules, ortho ring bufs+bgs, white tex,
      batch vbo/ibo), `WgpuRenderTexture` (color/depth textures+views), `WgpuTexture.deinit`
      (already frees the texture — add sampler+view), the registered-texture bind groups.
- Acceptance: `grep` shows every `createX` in wgpu.zig has a sibling `destroyX`; existing
  examples still build + smoke green (destroys are additive, unused by arena mode).

## Phase 0 STATUS (verified via cold rebuild): the destroy BRIDGE already exists.
Re-checked wgpu.zig: all 8 `destroyX` wrappers ARE present (lines ~1062-1104: destroyBindGroup,
destroyBindGroupLayout, destroyPipelineLayout, destroyRenderPipeline, destroyComputePipeline,
destroySampler, destroyShaderModule, destroyTextureView) + destroyBuffer/destroyTexture, and
bridge.zig implements every `js_*_destroy` (device side). The planning-turn inventory was stale.
So Phase 0's create/destroy PARITY is DONE. The mock (webtests/runner.mjs) auto-stubs unlisted
imports via a Proxy, so calling destroys won't break smoke instantiation.
REMAINING for Phase 0 (the real work): WIRE the destroys into owners' `deinit` (Renderer2D:
bg layouts, pipeline layout, blend_pipes[5], shader modules, ortho ring bufs+bgs, white tex,
batch vbo/ibo; WgpuRenderTexture: color/depth tex+views; WgpuTexture: sampler+view; registered
bind groups) and confirm the launcher calls example `deinit` on switch. Do this GUIDED by Phase 1
(mock counting + leak-test) so freeing an in-use resource is caught immediately.

## Phase 1 — Mock create/destroy accounting + baseline + `leak-test` step
- [ ] Mock GPU (`webtests/runner.mjs`) already records `createX`; also record `destroyX`.
      Maintain per-type live counts keyed by the label already passed to create ("material",
      "fog", "shapes", "renderer2d_ortho_ring", ...). A leak = live count ≠ baseline per type.
- [ ] BASELINE SNAPSHOT: capture per-type live counts AFTER engine init (Renderer2D pipelines,
      ortho ring, white tex are app-lifetime and MUST NOT be flagged) and BEFORE example init.
      The check compares post-`deinit` counts to this baseline, not to zero.
- [ ] New build step `leak-test` (sibling of `smoke-test`), `-Dfocus=<name>`: init example →
      tick N frames → call `deinit` → assert live GPU counts == baseline. Report leaks BY LABEL
      ("2 'fog' textures leaked, 1 'material' bind group leaked").
- [ ] The step is a NO-OP pass for arena-mode examples (they don't opt in) — see Phase 2.
- Acceptance: `leak-test -Dfocus=<a converted example>` passes; deliberately commenting out a
  `deinit` free makes it fail naming the leaked label.

## Phase 1b — Always-on GPU handle canary  [COMMITTED]
- [ ] Lightweight live-handle counters IN THE ENGINE (`src/wgpu.zig`), not just the mock: a small
      per-type tally incremented in each `createX`, decremented in each `destroyX`. Always compiled
      in (all build modes) — it's a handful of integer ops, negligible cost.
- [ ] At app exit (App.deinit / the runner's teardown) log any non-zero per-type live count via
      `std.log.err` (surfaces on the page overlay). This is the DEVICE-SIDE backstop the mock can't
      provide (the mock only runs headless in smoke). Off-by-baseline is fine here — the canary
      reports the raw non-zero tally at exit, which for a clean shutdown (engine deinit included)
      should be zero.
- Acceptance: a clean app logs nothing at exit; a deliberately-leaked handle logs its type+count.

## Phase 2 — Per-example `memory` flag  [the headline]
- [ ] Add to `AppSpec(StateT)` (src/wgpu_app.zig ~248): `memory: MemoryMode = .arena` where
      `MemoryMode = enum { arena, managed }`.
- [ ] **arena** (default, unchanged): `gpa` handed to init IS the frame/example arena; `deinit`
      may be a stub; the launcher resets the arena on switch; `leak-test` skips it.
- [ ] **managed**: the runner/launcher hands init a **leak-detecting GPA** (std GPA in debug /
      a tracking wrapper), NOT the arena. On switch (or at `leak-test` end): call `deinit`,
      then assert (a) the GPA reports zero un-freed CPU allocations, (b) GPU live counts ==
      baseline. THEN the arena reset runs and is a genuine no-op.
- [ ] **CRUCIAL invariant (document + assert):** a managed example must allocate the things it
      frees from the *handed gpa*, never from a stashed arena — arena `free` is a no-op, so a
      missing `deinit` free would be invisible. Swapping the allocator in managed mode is what
      makes "verify clean before arena clear" mean anything. Consider a debug guard that the
      handed gpa in managed mode is not the arena.
- [ ] Convert ONE existing example to `.managed` first (candidate: `textures_bunnymark` or
      `textures_mouse_painting` — both churn GPU resources) and let `leak-test` tell us what
      currently leaks. EXPECT it to surface real GPU leaks immediately; fixing them validates
      Phase 0's destroys end-to-end.
- Acceptance: the converted example's `deinit` frees everything; `leak-test` green; arena reset
  confirmed no-op (nothing to reclaim).

## Phase 3 — User-facing `expectNoLeaks` + docs
- [ ] `zimr.testing.expectNoLeaks(App, .{ .frames = 60 })` — the SAME harness exposed as a test
      helper so USERS get leak detection on THEIR code (a scene/entity pool that leaks fails in
      their CI), not just our examples. This is what actually delivers the confidence goal.
- [ ] Doc page: the two domains; arena vs managed; the "allocate-from-the-handed-gpa" invariant;
      how to write a correct `deinit`; how to run `expectNoLeaks`. Keep `src/web/readme.html`'s
      memory section in sync.
- Acceptance: a tiny sample app + its `expectNoLeaks` test in the docs builds + passes.

## Phase 4 — Convert a meaningful subset + make it a standing gate
- [ ] Convert a handful more examples that exercise dynamic create/destroy to `.managed`.
- [ ] Run `leak-test -Dfocus=<managed prefix>` each turn alongside smoke as a regression gate
      (catches an engine change that starts leaking).

## Phase 1 — increment 1 DONE: handle-balance line in every smoke.
`webtests/wgpu_smoke.zig` now prints, after the by-type profile:
`    GPU handles (created-destroyed): texture=N buffer=M bind_group=K ...` — the net
created-minus-destroyed count per leak-tracked resource type (the 10 with a destroy;
transient encoders excluded), computed by scanning the SUT call log (no shim change).
With no deinit called it's the working set (mostly engine-lifetime: ortho ring = 32
buffers+bgs, blend_pipes = 5 render_pipelines, etc.); a PER-FRAME leaker shows counts
scaling with frames; once deinit is wired+called (leak mode) a non-zero after teardown
is a leak. `res_types` table maps create-verb<->destroy-verb (note the irregular
`js_texture_create_view` and `js_device_create_shader_module_wgsl`).
NEXT increments: (a) a `leak-test` build step that runs init->deinit(->twice) and FAILS on
a growing/non-zero resource balance; (b) wire owners' deinit (guided by this); (c) the
Zig-side canary (Phase 1b).

## Phase 0/1/2 — leak-test WORKING END-TO-END (this turn).
Discovered the probe INFRASTRUCTURE already exists: `runnerDeinit` (wgpu_runner.zig) calls the
example's `spec.deinit`, and the smoke calls it after the frames + prints a second line
`    GPU handles after deinit:  ...` via `printLiveHandles(prefix)`. Fixes/wiring landed:
- Phase 0 owner deinits COMPLETED: `WgpuTexture.deinit` now frees view + sampler (was texture
  only); `WgpuRenderTexture.deinit` now frees color_view + depth_view (was color/depth only).
  Both guard `.invalid` so the canary isn't wrongly decremented.
- The mock (`wgpu_void` list in wgpu_smoke.zig) now records all 10 destroys (was only
  buffer/texture) so `printLiveHandles` COUNTS them — otherwise the Proxy stubbed them as
  UNHANDLED and the after-deinit line couldn't show sampler/view drops.
- Guarded the leak probe with `hasExport(exports, "runnerDeinit")` — wgpu_bringup and other
  non-runner wasms don't export it (was throwing "export not callable" in the check gate).
- Phase 2: converted `textures_magnifying_glass` deinit to free parrots/bunny/mask/rt.
RESULT (magnifying_glass smoke): before `texture=6 sampler=6 texture_view=6`; AFTER DEINIT
`texture=2 sampler=3 texture_view=2` — the example's own resources are freed; the remainder is
the engine baseline (white tex) + the font atlas (a real, now-visible leak: loadFont's texture
isn't freed) + engine-lifetime pipelines/ortho-ring. check gate: 91 ok, 0 failed, NO REGRESSIONS.
NEXT: (a) engine-baseline snapshot (canary `snapshotEngineBaseline` after Renderer2D.init) so the
after-deinit line can be compared to the engine baseline and a PASS/FAIL asserted; (b) free the
font (a Font.deinit / freeFont); (c) the `memory` flag (Phase 2) to make the check opt-in + failing.

## TWICE-LIFECYCLE leak detector WORKING (this turn) — reveals a systemic leak.
Added `runnerReinit` (wgpu_runner.zig): re-runs the example's `init` on the SAME instance after
`runnerDeinit` (engine persists — lazy init guarded). `runnerDeinit` now also frees the State slot
(`gpa.destroy`). Made `App.makeFrame` pub. The smoke now runs init->frames->deinit->REINIT->frames
->deinit and prints a 3rd line `GPU handles after 2nd deinit:`. GROWTH over the 1st teardown =
per-lifecycle leak, ISOLATED from the fixed engine baseline (which the single-deinit line can't
separate). Guarded by `hasExport(exports,"runnerReinit")`.
FINDING (magnifying_glass): after 1st deinit texture=2/bind_group=39/sampler=3/view=2; after 2nd
deinit texture=3/bind_group=44/sampler=5/view=3 → **+1 texture, +5 bind_group, +2 sampler, +1 view
PER lifecycle**. Root: the Renderer2D TEXTURE REGISTRY (`registered_textures`/`registered_bind_groups`)
never frees entries — every texture load / example switch accumulates a registration + material
bind group, and `loadFont`'s atlas is registry-owned ("renderer owns residency"; `unloadTexture`
is a no-op). This is THE long-running-app leak. Also confirmed magnifying_glass frees its OWN
direct textures/rt correctly (the non-growing part of the census).
NEXT: (a) PASS/FAIL — compare the two after-deinit lines, FAIL if 2nd > 1st; (b) FIX the systemic
registry leak: a way to release a registered texture + its bind group on teardown (and free the
font atlas), so the census doesn't grow per lifecycle.

## Registry-retention leak FIXED (this turn) — engine no longer keeps per-example data.
Simon's principle applied at the right GRANULARITY: the engine has FIXED resources (pipelines,
ortho ring, white texture — needed by the launcher + every example, created once) vs PER-EXAMPLE
registrations (texture-registry material bind groups) that must not persist past an example's life.
- Added `Renderer2D.resetRegistry()`: destroys every material bind group (id >= 1) + resets the
  count to 1 (keeps id 0 = engine white), re-arms the batch to white. Does NOT destroy the
  registered TEXTURES (the example owns + frees those via WgpuTexture.deinit) — only the engine-side
  bind groups that referenced them.
- `runnerDeinit` now calls it after the example's deinit (+ frees the State slot). Fixed engine
  resources persist; per-example registrations clear.
RESULT: magnifying_glass twice-lifecycle bind_group growth +5 -> **+0** (34->34). Gate: 91 ok, 0
failed, NO REGRESSIONS. The launcher switch path should call resetRegistry analogously (TODO).
REMAINING per-lifecycle leak: the FONT ATLAS (+1 texture, +2 sampler, +1 texture_view). `loadFont`
(wgpu_app.zig ~3337) bakes an atlas + `WgpuTexture.createFromPixels(...)` then registers it — but
NOTHING destroys that atlas texture (`unloadTexture` is a deliberate no-op; the example doesn't hold
the atlas WgpuTexture, only a `Font` with `texture.id`). NEXT: give the atlas an OWNER — have the
Font hold the atlas WgpuTexture (or handle) and `unloadFont`/example-deinit destroy it, so it's freed
per-lifecycle like any example resource. Then the twice-lifecycle census should be flat = PASS.

## magnifying_glass now LEAK-CLEAN (this turn) — flat twice-lifecycle census.
Two more owner-deinit gaps fixed after resetRegistry:
- Font atlas: `loadFont` now registers via `Renderer2D.registerOwnedTexture` (marks the slot
  engine-owned in `registered_owned[]`); `resetRegistry` destroys owned textures' WgpuTexture
  (handle+view+sampler), not just their bind group. → texture/view growth +1/+1 -> +0/+0.
- `WgpuRenderTexture.deinit` now also destroys `.sampler` + `.depth_sampler` (was color/depth
  textures + views only). → sampler growth +1 -> +0.
RESULT: magnifying_glass twice-lifecycle census is now IDENTICAL across both teardowns
(texture=1 buffer=35 bind_group=34 sampler=1 texture_view=1 render_pipeline=5 ...) = the FIXED
engine baseline, no per-lifecycle growth. Gate: check green. The detector + the fixes together
prove an example can be fully leak-clean.
NEXT: (a) PASS/FAIL — refactor printLiveHandles to RETURN the census, compare the two teardown
snapshots, FAIL on any positive delta (a real leak); make it opt-in via the `memory` flag so
not-yet-clean examples don't break the gate. (b) Call resetRegistry on the launcher switch path.
(c) The `memory = .arena | .managed` flag (Phase 2) + convert magnifying_glass to .managed.

## ENFORCED leak GATE working (this turn) — the `memory` flag + PASS/FAIL.
- Added `AppSpec.memory: MemoryMode = .arena` (+ `pub const MemoryMode = enum { arena, managed }`)
  and `runnerMemoryMode()` export (0=arena, 1=managed).
- `printLiveHandles` now RETURNS the per-type census `[res_types.len]i32`. The smoke captures the
  census after the 1st and 2nd teardown; for `.managed` examples (via runnerMemoryMode) it FAILS
  with `LEAK (managed, per lifecycle): <type>+N ...` on ANY positive growth (c2 > c1). `.arena`
  examples (default) just print the lines — no gate — so unconverted examples don't break the build.
- `textures_magnifying_glass` is now `.memory = .managed` and PASSES (flat census). PROVEN the gate
  bites: temporarily removing `s.rt.deinit()` made it FAIL `texture+1 sampler+1 texture_view+1`.
Gate: check green (managed example clean; all others arena).
This is Phase 2 + Phase 3(partial): a per-example opt-in leak gate. NEXT: (a) call resetRegistry on
the LAUNCHER switch path (analogous to runnerDeinit); (b) convert a few more churny examples to
.managed (bunnymark, mouse_painting) — each will reveal + force-fix its deinit; (c) user-facing
`zimr.testing.expectNoLeaks` + docs (Phase 3) reusing this same twice-lifecycle census.

## LAUNCHER leak analysis (this turn) — a fork for Simon.
Refactored `resetRegistry` -> `resetRegistryFrom(base)` (runner still uses base=1; magnifying_glass
stays leak-clean, gate green). Then studied the launcher (`Launcher` in wgpu_app.zig; used by
`examples/gallery_all`). Key facts:
- gallery_all runs FOUR apps SIMULTANEOUSLY in a 2x2 grid (`tick` into 4 cells) — all live, all
  registering textures into the ONE shared Renderer2D registry, interleaved. The fullscreen browser
  shows one at a time but still keeps switched-away children ALIVE (ensureInit is once-only).
- So normal CYCLING does NOT leak per cycle: each child is inited exactly once (ensureInit guards
  re-init); re-showing reuses it. The registry holds all shown children's registrations = a bounded
  WORKING SET, not unbounded growth.
- The real leak is `Launcher.reset(id)` (deinit -> re-init the SAME child, triggered by tapping a
  cell in gallery_all): the child's own textures free (WgpuTexture.deinit) but its material bind
  groups + engine-owned font atlas in the registry do NOT -> they accumulate per reset.
- A simple base-cutoff clear is WRONG here (would clear siblings' registrations); the correct fix
  needs PER-CHILD registry attribution: tag each registration with the owning child (a gen the
  launcher sets before ticking each child), and a FREE-LIST so releasing a child's ids reclaims the
  slots (else holes grow to the 64 cap). That's a registry data-structure rework.
DECISION FOR SIMON: (A) do the per-child attribution + free-list rework now (makes reset()/the grid
fully leak-tight), or (B) accept that per-app churn is solved + gated (the core goal) and the launcher
is bounded-on-cycling, deferring the multi-child registry rework. Testing (A) headlessly is also hard
(reset fires on input, which the smoke has none of) — would need a scripted-input launcher smoke.

## Launcher-in-launcher ADDED (this turn, for fun) — and it works.
Added `gallery_all` (the 2x2 grid of 4 inline mini-apps) to the flagship `launcher` roster
(build.zig flagships name list + a `z.eraseApp(@import("ex_gallery_all").app)` in
examples/launcher/launcher.zig). Nesting works at BOTH compile and runtime: temporarily starting
the launcher on the gallery_all entry smoked clean (nested child_tick_active + pushViewport per
grid cell compose fine). On device, switch to the LAST roster entry to see 4 apps in a grid inside
the fullscreen switcher.
INCIDENTAL FIX: `examples/plot_demo` used the old `f.gl.renderer` FIELD (removed by the
optional-accessor refactor) — my earlier sweep only covered src/, not examples/. Fixed to
`f.gl.renderer()`. (Lesson: the accessor sweep should have included examples/; only plot_demo was
affected, surfaced by compiling it via the launcher.)
NOTE: the launcher's OWN twice-lifecycle census still grows (it's `.arena`, so no gate) — that's the
known multi-child registry leak on runnerReinit/reset, not the nested grid's doing.

## Launcher registry attribution DONE (this turn) — necessary piece, not sufficient alone.
Renderer2D now tags each registration with a per-child owner gen (`registered_owner[]`,
`current_reg_owner`) + a FREE-LIST (`reg_free`) so ids recycle. `setRegOwner(gen)` /
`releaseOwner(gen)` clear exactly one child's registrations (bind groups + engine-owned font
atlas), leaving siblings in a SHARED registry (the 2x2 grid) untouched. `registerTexture` uses
the free-list; `resetRegistryFrom` clears owner tags + the free-list. Launcher wired: `add`/
`ensureInit`/`tick`/`tickFullscreen` wrap the child's init+update in `setChildRegOwner(f, gen)`;
`reset` calls `releaseOwner(gen)` before re-init. Verified: magnifying_glass stays flat, gallery_all
flat (its toy apps use only shapes — no textures), check gate green, no regression.
BUT the dominant launcher leak is NOT the registry — it's each CHILD's OWN GPU resources not freed
by its deinit. Example: `helmet_sw` (the flagship active=0) holds rt / two CpuFramebuffers / font /
PBR textures / mesh buffers / a custom pipeline; its deinit frees only CPU (mesh, pixels), so the
launcher twice-lifecycle grows buffer +50, texture +12, bind_group_layout +20, etc. The font atlas
IS now freed (engine-owned, via releaseOwner/resetRegistry), but the rest needs helmet_sw's GPU
deinit wired.
REALITY: in NORMAL launcher use (cycle apps, each inited once = working set; page reload = fresh) there
is NO per-cycle leak. The growth shows on runnerReinit (whole-app re-init on one instance) and would
show on repeated `reset()` (tap-to-reset) — both need each shown child's GPU deinit completed. That's
a per-example effort (convert flagships to leak-clean, like magnifying_glass). NEXT: convert flagship
children to free their GPU resources one at a time (helmet_sw is a hard first; a simpler flagship like
waving_cubes / kaleidoscope would be a better starting demo), then flip them to `.managed`.

## First leak-clean launcher CHILDREN (this turn): kaleidoscope, waving_cubes, ecs_boids.
All three hold only a `font` as their GPU resource; the registry work (engine-owned atlas + release
on teardown) already reclaims it, so they were ALREADY GPU-leak-clean — they just needed
`.memory = .managed` to opt into the twice-lifecycle gate. Each now smokes with a FLAT census
(after 1st deinit == after 2nd deinit) and PASSES. waving_cubes' larger counts (bind_group=100,
render_pipeline=12, shader_module=11) are engine-lifetime 3D pipelines — created once, not growing.
So the pattern: a font-only example is leak-clean for free now; flip the flag. NEXT simple ones to
try: examples whose only GPU resource is a font/shapes. HARDER ones (mandel_julia = a LoadedShader
pipeline; helmet_sw = rt + framebuffers + PBR textures + mesh buffers) need their GPU deinit wired
(free the shader/pipeline/buffers) before they'll go flat. Gate: check green with 3 managed examples.

## 7 leak-clean `.managed` flagship children now (this turn +4).
Added: ui_full_showcase, zimrphysics_demo, zimrphysics2d_demo, sph_fluid_2d — all FLAT (0 leak),
gate passes. (Total managed-clean: kaleidoscope, waving_cubes, ecs_boids, ui_full_showcase,
zimrphysics_demo, zimrphysics2d_demo, sph_fluid_2d — plus textures_magnifying_glass.) The registry
+ engine-owned-atlas work makes font/shapes-only (and even sph_fluid_2d) clean for free.
GATE PROVEN AGAIN in the wild: `fluid_sort` (GPU SPH with sorting) FAILED the managed gate with
`buffer+13 bind_group+12 compute_pipeline+11 shader_module+13` per lifecycle — it recreates compute
pipelines/shaders/buffers each lifecycle without freeing. REVERTED it to `.arena` (needs its compute
GPU deinit wired first). Note sph_fluid_2d is clean but fluid_sort isn't — the gate distinguishes.
CAVEAT for future batch flips: `printPass` prints "✓ PASS" BEFORE the gate's post-2nd-deinit check,
so grep the log for "✗ FAIL"/"LEAK" (not just the first PASS) to judge a managed example.
HARDER TIER remaining (need GPU deinit wired): fluid_sort, mandel_julia (+ its sidebyside cousins),
the RTT/framebuffer 3D ones (shadowmap_sw, decals, deferred_render, cel_shading, fog_rendering,
hybrid_render, helmet_sw), textures_background_scrolling, plot3d_demo, skinned_mesh.

## LoadedShader teardown FIXED at the engine level (this turn) — mandel_julia clean (9th).
Resolved two long-standing "no destroy API yet" TODOs now that the destroy bridge exists:
- `LoadedShader.deinit` (shader_runtime_wgpu.zig ~224) now destroys `vs_module`+`fs_module` (created
  fresh per loadShaderVF). It deliberately does NOT destroy `pipeline` — that's owned by
  pipeline_cache.zig (deduped by source+state, reused across LoadedShaders/lifecycles); destroying it
  would hand a dead handle to a later cache hit. Modules/layouts are only needed to BUILD the
  pipeline, so releasing them after is safe.
- `Resources.deinit` (~1115) now destroys the per-instance `bind_groups` + `bg_layouts` (was ubo only).
Wired `mandel_julia` deinit (`s.gpu_shader.deinit()`) + `.managed` → FLAT census, passes. render_pipeline
stays 6 across both lifecycles (the cached pipeline created once, reused). Gate green, no regression to
other shader examples. Managed-clean count: 9.
SIDEBYSIDES NOT YET: mandel_sidebyside + rt_sidebyside FAIL — their deinits call `ui_host.deinit()` but
NOT `gpu_shader.deinit()` (shader_module+2), and their TWO CpuFramebuffers leak GPU textures (texture+2,
sampler+2, texture_view+2). Reverted to `.arena`. NEXT: add `s.gpu_shader.deinit()` + free each
CpuFramebuffer's GPU upload texture (check CpuFramebuffer.deinit) — then they should go flat.

## CpuFramebuffer teardown FIXED at engine level (this turn) — helps the whole framebuffer tier.
- Added `CpuFramebuffer.deinit` (wgpu_app.zig ~3186): frees its GPU upload texture (handle+view+
  sampler) via `self.tex.deinit()`. Its registry bind group is cleared on teardown by
  resetRegistry/releaseOwner (the tex is CpuFramebuffer-owned, non-engine-owned).
- Fixed the `CpuFramebuffer` RESIZE path (~3144): was `destroyTexture(self.tex.handle)` (HANDLE ONLY,
  orphaning the old view+sampler every resize) → now `self.tex.deinit()` (full free before the new
  createFromPixels). Fixes a per-resize view/sampler leak for every CpuFramebuffer user.
- Wired both sidebysides' deinits: `gpu_shader.deinit()` (was missing → shader_module/buffer/bg/layout
  leaked) + `sw_fb.deinit()` + `sw.deinit(gpa)`. This took mandel_sidebyside from
  `texture+2 sampler+2 view+2 shader_module+2 buffer+1 bg+1 layout+1` down to `texture+1 sampler+1
  view+1`, and rt_sidebyside similarly. Kept the deinit wiring (a real improvement) but REVERTED
  `.managed` — they still leak ONE texture/sampler/view per lifecycle.
REMAINING (sidebysides): one unidentified WgpuTexture per lifecycle. NOT the shader (its schema has 0
samplers → Resources.textures empty) and NOT UiHost (ui_full_showcase uses UiHost + is clean). Prime
suspect: `raster.Context` (the software rasterizer `sw`) holding an internal GPU framebuffer/texture
that `sw.deinit(gpa)` doesn't free. NEXT: inspect raster.Context for a GPU texture + free it. Gate green.
Managed-clean count still 9 (sidebysides pending that last texture).

## Both SIDEBYSIDES now leak-clean (this turn) — the missing texture was a 2nd framebuffer.
The unidentified `texture+1 sampler+1 view+1` was `corner_fb` — mandel_sidebyside and rt_sidebyside
each have TWO CpuFramebuffers (`sw_fb` + `corner_fb`) and I'd only freed `sw_fb`. Added
`s.corner_fb.deinit()` to both → FLAT, PASS. Combined with the CpuFramebuffer.deinit + resize fixes
and the LoadedShader teardown, both are now `.managed`. Managed-clean count: 11 (magnifying_glass,
kaleidoscope, waving_cubes, ecs_boids, ui_full_showcase, zimrphysics_demo, zimrphysics2d_demo,
sph_fluid_2d, mandel_julia, mandel_sidebyside, rt_sidebyside). Gate green.
LESSON: grep the State for ALL `_fb: CpuFramebuffer` fields, not just the first — multi-framebuffer
examples (the CPU-vs-GPU side-by-sides, and likely the RTT 3D ones) hide extra GPU textures.
HARDER TIER remaining: fluid_sort (compute pipelines/shaders), the RTT/framebuffer 3D ones
(shadowmap_sw, decals, deferred_render, cel_shading, fog_rendering, hybrid_render, helmet_sw),
textures_background_scrolling (WgpuTexture), plot3d_demo (Mesh), skinned_mesh (Model).

## First RTT 3D example clean (this turn): fog_rendering — establishes the RTT pattern.
fog_rendering is now `.managed` + FLAT. The RTT/raw-handle pattern (for the whole 3D cluster):
1. BUILD-ONLY intermediates (shader modules, bind group layouts, pipeline layout) are consumed by
   createRenderPipeline/createBindGroup — destroy them INLINE right after construction (createRenderPipeline
   is DIRECT, not cached, so unlike LoadedShader the pipeline IS example-owned and destroyed in deinit).
2. RUNTIME handles kept in State (pipeline, bind groups, per-object UBO buffers, RenderTexture) → destroyed
   in deinit; `rt.deinit()` covers the lazily-created RTT.
3. SHARED resources (the 3 GpuMeshes torus/cube/sphere, referenced by multiple objs) → store the unique set
   in State and free ONCE, never per-obj (would double-free the shared handle).
Bisection went: everything flat except buffer+6 → the 3 meshes × (vbo+ibo). Count: 12 clean.
REMAINING RTT cluster (same pattern, each needs its own handle enumeration + wiring): cel_shading,
deferred_render, hybrid_render, shadowmap_sw (also 2 raster.Contexts + sw_fb), decals (Mesh/Model/WgpuTexture),
helmet_sw (rt + 2 CpuFramebuffers + PBR textures + mesh). Plus textures_background_scrolling (WgpuTexture),
plot3d_demo (Mesh), skinned_mesh (Model), fluid_sort (compute pipelines/shaders/buffers).

## cel_shading clean (this turn) — 13th; RTT pattern is now mechanical.
cel_shading (2 pipelines toon/hull, 1 mesh vbo/ibo, 3 UBO buffers, 4 bind groups, an RTT) wired the
same way as fog_rendering + `.managed` → FLAT. One structural note: its bind groups were built INSIDE
the `return .{...}` literal (so the bgls were live there) — refactored to build them in locals first,
THEN destroy the build-only bgls/pls/modules, THEN return. Count: 13 clean.
Recipe (repeatable for the rest of the cluster): (1) grep State for all raw Handle fields → those get
destroyed in deinit; (2) grep initState for createShaderModule/createPipelineLayout/createBindGroupLayout
→ those are build-only, destroy inline after the pipeline+bind groups are built (move bind-group creation
out of the return literal if needed); (3) createRenderPipeline is DIRECT → pipelines are owned, destroy in
deinit; (4) meshes/textures shared across N objects → free the unique set once.
REMAINING: deferred_render, hybrid_render (raw handles, same as cel_shading), shadowmap_sw (+2 raster
Contexts + sw_fb), decals (Mesh/Model/WgpuTexture), helmet_sw (rt + 2 CpuFramebuffers + PBR textures +
mesh), textures_background_scrolling, plot3d_demo, skinned_mesh, fluid_sort.

## Batch toward "all launcher apps clean" (this turn): +gallery_all, plot_demo, hybrid_render → 16.
- gallery_all: CLEAN by just flipping `.managed` (its 4 toy apps are shape-only; launcher.deinit handles them).
- plot_demo: leaked its checker texture — it registered a WgpuTexture but discarded the handle. Fix:
  `registerTexture` → `registerOwnedTexture` so resetRegistry frees it (same as the font-atlas pattern).
  A useful pattern for any example that registers-and-forgets a texture.
- hybrid_render: full raw-handle wiring (2 pipelines, per-cube array, shared cube mesh, march bind group),
  same recipe as fog/cel. CLEAN.
Managed-clean examples (16): magnifying_glass, kaleidoscope, waving_cubes, ecs_boids, ui_full_showcase,
zimrphysics_demo, zimrphysics2d_demo, sph_fluid_2d, mandel_julia, mandel_sidebyside, rt_sidebyside,
fog_rendering, cel_shading, gallery_all, plot_demo, hybrid_render.
REMAINING flagship roster to clean: deferred_render, shadowmap_sw, decals, helmet_sw, skinned_mesh,
plot3d_demo, textures_background_scrolling, fluid_sort (~8). Each = the raw-handle recipe (deferred_render
is next, same shape). helmet_sw + shadowmap_sw are the big ones (multi-framebuffer + raster + PBR).

## deferred_render clean (this turn) — 17. Recipe scales to the complex ones.
deferred_render (2 pipelines, 3 lazily-built G-buffer RTTs, 2 shared meshes plane/cube, a resize-rebuilt
g1_bg, per-obj array, lights UBO/bg) → FLAT first try. Two extra wrinkles handled: (a) stored the shared
plane/cube vbo+ibo in State to free ONCE (the per-obj Obj.vbo/ibo are copies of those — freeing per-obj
would double-free); (b) fixed ensureTargets to destroy the OLD g1_bg before rebuilding on resize (a
per-resize leak; harmless in the 1-resize smoke but now correct). g_rts freed via `g.deinit()` per RTT.
Managed-clean count: 17. Remaining flagship roster: shadowmap_sw, decals, helmet_sw, skinned_mesh,
plot3d_demo, textures_background_scrolling, fluid_sort (7). helmet_sw + shadowmap_sw are the big multi-
framebuffer + raster ones; decals/skinned_mesh/plot3d_demo have Mesh/Model (check Mesh/Model.deinit);
textures_background_scrolling is a WgpuTexture (likely registerOwnedTexture like plot_demo); fluid_sort is
compute pipelines/shaders/buffers.

## Batch: +textures_background_scrolling, skinned_mesh, plot3d_demo, decals → 21 clean.
- textures_background_scrolling: 3 WgpuTextures in State — `s.bg/mid/fore.deinit()`. CLEAN.
- skinned_mesh, plot3d_demo: CLEAN by just flipping `.managed` (their Model/Mesh buffers already freed
  by existing deinit / the drawing path).
- decals: freed decal_tex (WgpuTexture) + used `unloadModel` on sphere_model/bunny_model. Subtlety:
  loadModelFromMesh UPLOADS A COPY, so the model owns GPU buffers while s.mesh/s.bunny stay CPU-only
  (for ray-pick) — unloadModel frees the GPU copy, unloadMesh frees the CPU original, NO double-free.
  `unloadMesh(gpa, m)` / `unloadModel(gpa, m)` need only gpa (no frame) — callable from deinit.
Managed-clean count: 21. REMAINING: shadowmap_sw, helmet_sw, fluid_sort (3 — the heavy ones:
shadowmap_sw = 2 raster.Contexts + framebuffers + RTT; helmet_sw = rt + 2 CpuFramebuffers + PBR
textures + mesh + custom pipeline; fluid_sort = compute pipelines/shaders/buffers).

## shadowmap_sw clean (this turn) — 22. Hardest RTT so far, flat first try.
shadowmap_sw: 2 pipelines (depth/lit), 2 RTTs (shadow_rt + rt), 2 raster.Contexts (sm_ctx/sw), 2
CpuFramebuffers (sw_fb/corner_fb), a shadow sampler, 4 objects sharing 3 meshes (cube shared by
pillar+receiver), per-object UBOs+bind groups. Wired: stored the 3 unique meshes (6 buffers) +
shadow_sampler in State (freed once — cube would double-free if per-obj); per-obj loop frees
depth/lit UBOs + 3 bind groups; build-only bgls/pls/modules destroyed inline; both RTTs + both
CpuFramebuffers via .deinit(); kept the existing raster.Context + CPU frees. FLAT first try. Count: 22.
REMAINING: helmet_sw (the launcher's default landing app — rt + 2 CpuFramebuffers + PBR textures +
mesh + custom pipeline; its deinit currently frees only CPU), fluid_sort (compute pipelines/shaders/
buffers — needs the compute-resource teardown).

## Near-complete: 22 launcher apps leak-clean; helmet_sw + decals have remaining issues.
This turn added ENGINE fixes: pbr3d.Model.deinit + pbr3d.Renderer.deinit (were missing — freed
buffers/textures/pipelines/bind groups), Compute.deinit completed (was freeing only CPU slices —
now destroys the per-kernel compute pipelines + bind groups + field/uniform/staging buffers) +
initGpu per-kernel build-only layout/module destroys, and exported `z.unloadModel`.
CLEAN (fresh-compile verified): fluid_sort (compute — the Compute engine fix), + the earlier 21.
CAUTION LESSON: two "CLEAN" results were STALE — decals used `z.unloadModel` which WASN'T exported,
so its smoke silently ran a CACHED wasm. Always confirm a managed example recompiled (watch for a
build error before trusting PASS). Fixed by exporting unloadModel, but then:
- decals: `unloadModel` + `unloadMesh` DOUBLE-FREES on reinit (crash) — sphere_model/bunny_model DO
  share the CPU meshes' GPU buffers (loadModelFromMesh does NOT copy, contrary to my assumption).
  Reverted to safe `.arena`: unloadMesh + decal_tex.deinit (frees the texture; the shared model
  buffers need a single-owner teardown — unloadModel only, dropping unloadMesh, OR track ownership).
- helmet_sw: reverted to `.arena` — after the pbr3d deinits it's down to `bind_group_layout+20`
  (loadGltf creates per-material/primitive layouts not tracked). Needs loadGltf layout teardown.
NEXT: (a) decals single-owner mesh teardown; (b) helmet_sw loadGltf bind-group-layout freeing.

## helmet_sw CLEAN (this turn) — 23 clean; the launcher default is now leak-tight.
The pbr3d bind_group_layout+20 leak was makeVs/Fs/MaterialLayout creating a FRESH layout on every
call and discarding it. Fixed by destroying the build-only layout after each createBindGroup:
- buildMaterialBindGroup (per material): -1
- buildVsBindGroup + buildFsBindGroup (per ring slot × 8 slots × 2): -16
- the pipeline's vs/material/fs layouts after createPipelineLayout: -3
→ +20 to +0. helmet_sw (rt + 2 CpuFramebuffers + PBR model + renderer + custom pipeline) is now
`.managed` + FLAT, combined with the pbr3d.Model.deinit + Renderer.deinit + Compute engine fixes.
This is the launcher's ACTIVE=0 landing app, so the launcher's main visible leak is gone.
ONLY decals REMAINS (buffer+2): the decal system uploads the receiver Model's mesh to a GPU vertex
buffer (in mesh.vboId), and unloadMesh/unloadModel free only the CPU handle-ARRAY (`freeMany(vboId)`),
never `destroyBuffer` on the handles. The engine `unloadMesh` never destroys GPU buffers — fixing it
risks double-free for any mesh user that frees them elsewhere, so it needs care. decals is safe on
`.arena` (frees CPU + decal_tex via unloadModel; the 2 receiver-upload buffers leak). NEXT: audit the
mesh GPU-buffer ownership (who uploads receiver meshes, who should destroy vboId handles) and fix
`unloadMesh` to destroy them — then decals goes clean and all 24 are done.

## COMPLETE: all 24 launcher apps leak-clean (this turn closed out decals).
decals was the last. Root of its buffer+2: `uploadDecalReceiver` uploads each receiver mesh to a GPU
vertex buffer stored in the ENGINE-owned `Cube3D.decal_receivers` list, which Cube3D never freed (no
deinit) — so the 2 receiver VBOs accumulated per lifecycle. Fixed like the texture registry: added
`Cube3D.resetDecalReceivers()` (destroys each receiver VBO + clears the list, keeping the shared
engine decal_proj_buffer) and call it in `runnerDeinit` alongside `resetRegistry`. decals `.managed`
+ FLAT (unloadModel frees the CPU meshes+material; decal_tex.deinit frees the texture; receiver VBOs
via resetDecalReceivers). No double-free — the models have NO GPU buffers (uploadMesh is a no-op;
`loadModelFromMesh` ignores gl; the wgpu draw path owns GPU buffers), so unloadMesh's CPU-only free
was correct all along.
ALL 24 CLEAN: magnifying_glass, kaleidoscope, waving_cubes, ecs_boids, ui_full_showcase,
zimrphysics_demo, zimrphysics2d_demo, sph_fluid_2d, mandel_julia, mandel_sidebyside, rt_sidebyside,
fog_rendering, cel_shading, gallery_all, plot_demo, hybrid_render, textures_background_scrolling,
skinned_mesh, plot3d_demo, deferred_render, shadowmap_sw, fluid_sort, helmet_sw, decals.
Systemic engine fixes that made it scale: registry per-child attribution + free-list, LoadedShader
teardown (modules not the cached pipeline), Resources bind-group/layout frees, CpuFramebuffer.deinit
+ resize fix, RTT sampler frees, pbr3d Model/Renderer deinit + build-only layout frees, Compute GPU
teardown + per-kernel layout frees, Cube3D.resetDecalReceivers, exported unloadModel. Gate green.
REFINEMENT (not blocking; the single-example gate is clean): the LAUNCHER's reset()/releaseOwner path
should also call resetDecalReceivers so an in-launcher decals reset is tight (only decals uploads them).

## Phase 1b — Always-on handle canary  [KEEP — Simon]
- [ ] Maintain live GPU-handle counts (per type) on the ZIG side too (increment in createX, decrement
      in destroyX wrappers in wgpu.zig), independent of the mock. At process exit / on request, if any
      count != baseline, `std.log.err` the non-zero types in EVERY build mode (not just debug) — a
      backstop for device-only leaks the mock can't see. Nearly free (a counter per create/destroy).

## Phase 1b — increment DONE: Zig-side canary infrastructure in wgpu.zig.
Added `HandleKind` (10 kinds) + `HandleCensus = std.enums.EnumArray(HandleKind, i64)` (sizes
itself from the enum — no hand-count), `var live_handles: HandleCensus`, and `bumpHandle(kind, delta)`
called from the 12 create wrappers (+1) and 10 destroy wrappers (-1) — createBufferInit/
createWithData skipped (delegate to createBuffer, would double-count); view-array/mip bump as
texture_view (distinct externs, produce views). Exposed `pub fn handleBaseline() HandleCensus` (snapshot) + `pub fn liveHandleReport(baseline,
buf)` (non-zero delta, named via `@tagName` — no parallel names array).
NOT auto-logged (engine resources are legitimately live until exit → false positive). Works in
EVERY build (device/launcher/standalone) — the mock-independent backstop. Verified: lint clean,
smoke PASS, check gate 46 ok / NO REGRESSIONS.
NOTE: `std.enums.EnumArray` + `std.enums.values` + `@tagName` avoid the hand-count AND the
`@typeInfo(T).@"enum".fields` access that errors on Zig 0.17.0-dev.1245.
CONSUMER NEXT (the observable value): a `leak-test` that snapshots handleBaseline() AFTER engine
init + BEFORE example init, runs init->frames->deinit, then asserts liveHandleReport==empty. The
baseline timing matters (engine inits lazily on first frame), which is why the launcher wiring is
deferred to the leak-test where the ordering is controlled.

## Phase 5 — FUTURE (undecided)
- **`Scope`** (UNDECIDED — Simon unsure; revisit after managed mode is felt) (scoped arena + GPU-resource group that free together; `level.loadTexture(...)`
  then `level.deinit()`): the ergonomic middle tier for per-scene/per-pool dynamic lifetime.
  Build once we've felt real free-ordering pain in managed mode.
- **Typed `WgpuGl.owner: *App` accessor**: currently blocked by a WgpuGl↔wgpu_app import cycle;
  unrelated to leaks but same "single source of truth" spirit.

---

## Open decisions (Simon)
- RESOLVED: per-example flag (not a separate certified list).
- RESOLVED: KEEP the always-on canary (now Phase 1b, committed) — cheap device-side backstop.
- UNDECIDED (Simon): keep `Scope` as the headline dynamic-memory abstraction, or lean on
  explicit `deinit` + `defer` + RAII only? Left in Phase 5 until decided.

## Notes / invariants to preserve
- Engine-lifetime resources (Renderer2D pipelines incl. blend_pipes[5], ortho ring, white tex,
  batch buffers) are intentionally app-lifetime → baseline, never flagged.
- Mock-balanced ⇒ device-balanced, so the mock count check is a valid proxy; the canary
  (Phase 5) covers the residual device-only cases.
- `WgpuTexture` already has a `deinit`; completing Phase 0 makes `defer x.deinit()` uniform
  across all resource types.
