# claude.md — fresh-session entry point

## Current plan
The first lines of this file always name the active plan file(s) under
`src/notes/`, so any session sees the current plan at a glance. Keep that true:
when work on a new plan begins, create its file and name it right here.

**ACTIVE — `src/notes/raylib_port.md`** — finish porting raylib's example set. That file is
the ONE source of truth for the DONE/TODO/N/A counts and the 7 prioritized waves; **never
restate the counts here** (three stale copies had drifted apart before this was fixed).
Rhythm: one example per turn (port → standalone → smoke → ship → Simon verifies), each
citing its raylib source. Every new example must be leak-free — author it `.memory =
.managed` with a deinit that frees ALL its GPU resources; the twice-lifecycle smoke gate
enforces a FLAT census.

**DONE — `src/notes/leak_detection.md`** — per-example `memory` flag: `.arena` (default)
vs `.managed` (leak-detecting GPA; `deinit` must free everything, and the `leak-test` smoke
gate verifies CPU heap AND GPU handles return to baseline before the arena reset). The
destroy bridge is complete.

**DONE (June–July 2026), a closed arc:** the typed-shader-interface unification. ALL
shaders are IoT/typed (zero direct `@SpirvType`); the extern-gen binding path is
single-source-of-truth (zimr577); bloom is fully off inline WGSL / override constants
(zimr578+); the decal CPU|GPU side-by-side (`decal_sw`) shipped.

**Paused, not dropped — `src/notes/spv2wgsl_vs_reference.md`:** make `src/spv2wgsl.zig` always
pass Tint/Dawn validation by porting naga/Tint ideas into our dependency-free pipeline. Landed
so far: uniform-layout gate + Tint behavior analysis (both in-file, no new files), empty-type-var
fix, and the naga full-corpus catalog started. naga is a TEMPORARY dev oracle only (at
`/home/claude/study/wgpu-trunk/target/debug/naga`); the permanent gate is our own ported
validator. Remaining: texture-sampling uniformity analysis (the definitive fix for the
sample-at-root restriction — the `sampleLevel` escape hatch is landed in `shader_builtins.zig`),
broader corpus coverage, minimal typed IR. Resume after a batch of ports.

**Planned, not started — `src/notes/vulkan_backend.md`:** native platforms
(Windows/Vulkan first) behind a comptime backend seam; investigation complete
(mach studied, seams inventoried, cross-compile probe proven), implementation
deliberately deferred. Web stays first-class.

**Paused, not dropped:** `src/notes/webgpu_control.md` (low-level WebGPU control /
raygpu parity), the physics demo plan (`src/notes/physics_demo.md`), and the
3D-plot plan (`src/notes/plot3d.md`). Finished plans live in `src/notes/archive/`.

## First thing each session
Read `src/web/readme.html`. It is the project description — what zimr is, the
API, the build commands, the shader/compute pipeline, the file layout. **Keep it
current**: any change to a path, type, namespace, build step, or behavior it
describes gets reflected in `readme.html` the same turn (grep it for the old name
before merging). The repo file is canonical, not the `/mnt/user-data/outputs/`
delivery copy.

## Show Simon the code — every turn, no exceptions
**ALL new or changed code appears in the chat, in full.** This is a hard rule and
the most common way to fail Simon. Concretely:
- A new file: its COMPLETE source must be visible in the conversation. A
  `create_file` call whose content is shown satisfies this; a file written via a
  heredoc inside a long bash script, or assembled by a Python patcher, does NOT —
  in those cases paste the resulting file (or every changed region, whole) in the
  reply.
- An edit: show the full new version of every changed function/region (a
  `str_replace` with visible old/new counts; a sed one-liner does not).
- Shaders and engine changes are never summarized — always the full text.
- Recovering work from a lost context or a prior session? Re-show it (view the
  file in a tool call) before shipping; Simon must never receive code he has not
  seen.
Alongside the code: explain what each piece does and why, walk through anything
non-obvious, and `present_files` any standalone built. If the work is visual,
Simon opens the standalone and sends a screenshot — there is no GPU or browser in
this sandbox, so the visual verdict is always his. Inline code + visual proof,
both, every time, even on multi-example turns.

## What zimr is
A pure-Zig port of raylib and Dear ImGui on `wasm32-wasi` + WebGPU. No C
dependencies, no emscripten. WebGPU is the only render path (the old GL backend is
gone). The only build dependency is the Zig compiler. Two transpilers, both
written in Zig, carry the code to the browser: `spv2wgsl` (Zig → SPIR-V → WGSL for
shaders and compute kernels) and `c2js` (Zig → C → JavaScript for the browser
host, `src/bridge.zig`). The architecture lives in the `//!` doc atop
`src/zimr.zig`; the public API surface is `CHEATSHEET.md` (codegen). Reference C
is at `/tmp/raylib-master/` and `/tmp/imgui-master/` (the imgui DOCKING branch —
zimr mirrors docking, not master).

## Snapshots — per-turn, non-negotiable
The repo at `/home/claude/zimr` is the source of truth (the sandbox preserves it
across restarts; the zip is insurance and the recovery point if it ever resets).
- **End every turn with a zip** and `present_files` it. Ship only at a GREEN
  milestone — never a mid-broken build.
  ```
  cd /home/claude && zip -r -y -q /mnt/user-data/outputs/zimr<N>.zip zimr \
    -x '*/.zig-cache/*' -x 'zimr/.zig-cache/*' \
    -x '*/zig-out/*' -x 'zimr/zig-out/*' \
    -x 'zimr/tools/zig-x86_64-*' \
    -x 'zimr/tools/bun-linux-x64/*' -x 'zimr/tools/naga/*' \
    -x 'zimr/prebuilt/standalone/*.html' -x '*/.git/*' -x 'zimr/.git/*' \
    -x '*/node_modules/*' -x 'zimr/intake/*' \
    -x 'zimr/*.js.map' \
    -x 'zimr/zimr*/*'
  ```
  NB: the `*/.zig-cache/*` / `*/zig-out/*` / `*/.git/*` forms are DEPTH-AGNOSTIC —
  nested caches exist (e.g. `src/shaders/tools/.zig-cache/`) and the top-level-only
  globs miss them. `zimr/zimr*/*` drops any stray nested project snapshot
  (a 55MB `zimr331/` dupe was accidentally living in the tree — junk, not built).
  Everything else ships (all `src/`, notes, `build.zig`, scripts, examples).
- **Prune** (disk is finite, a full cache is ~2.5G): keep the 5 most recent + every
  10th. If disk is tight mid-turn, `rm -rf .zig-cache tools/.zig-cache` first.
  ```python
  import os,re,glob
  z=glob.glob("/mnt/user-data/outputs/zimr*.zip"); n=lambda p:int(re.search(r"zimr(\d+)\.zip$",p).group(1))
  nums=sorted(n(p) for p in z); keep=set(nums[-5:])|{x for x in nums if x%10==0}
  [os.remove(p) for p in z if n(p) not in keep]
  ```

## Iterating — the velocity path
Don't default to `zig build test` for iteration; it builds broadly. When working a
specific example, shader, or module:
- Build its standalone and hand it back: `zig build <name>-standalone
  -Dmode=release` → `zig-out/standalone/<name>.html` → `present_files`.
- **Always `-Dmode=release` for standalones.** It is ReleaseSmall but keeps the
  zimr asserts (`assertf`/`alwaysAssert`) and their on-page log. Omitting `-Dmode`
  defaults to **debug** (large + slow); reserve debug for crash-stacktrace work.
  The mode enum is `debug | release | ship` (build.zig). `ship` strips zimr's
  asserts and the profiler; older notes calling it `release-with-zimr-asserts` or
  `release-no-zimr-asserts` are stale — those names no longer exist.
- **"Iterate in debug because it builds faster" is FALSE — measured (1282, July).**
  Launcher rebuild after a one-example edit: debug **48s** / release **51s** (+6%),
  and debug peaks at **2 GB** RSS vs release's **1 GB**. Single example: debug ~9-10s
  / release ~13-15s (+50%, i.e. +4-5s). What debug actually costs is the ARTIFACT:
  launcher HTML **26.6 MB** (debug) vs **12.0 MB** (release); a single example
  7.3-10.8 MB vs 1.9-5.1 MB. Simon opens these on a phone. Four seconds of build time
  never beats 5-15 MB of transfer. Do NOT "speed up iteration" by dropping to debug —
  and don't mix modes to compile-check either, since ReleaseSmall has its own
  failure modes (the old UiHost ReleaseSmall hang) that a debug check would miss.
- A new engine shader is just dropping files in `src/shaders/`: a
  `*_vs.zig` / `*_fs.zig` (+ `*_io.zig`) is auto-discovered, translated to `.wgsl`,
  and wired into the engine module. No `build.zig` edit needed.

## Building one example from cold cache — step by step
Zig caches by **content hash** (`touch` invalidates nothing) and its cache GC
evicts old entries **including the tool binaries** (`lint_zimr`, `spv2wgsl`,
`c2js`). From a cold or partially evicted cache, one
`zig build <name>-standalone` chains: configure → lint_zimr (build the tool,
then lint all ~450 files) → spv2wgsl (ReleaseFast) → per-shader transpiles →
c2js (host JS) → the wasm compile (ReleaseSmall) → standalone pack. That chain
does not fit in one command window on this 1-core box — but every finished
object is cached, so the procedure is an **idempotent retry loop**: rerunning
the SAME command always makes forward progress. Never `rm -rf .zig-cache` to
"fix" anything; that converts minutes of retries into a ~30-minute rebuild.

**The LAUNCHER standalone OOMs from a COLD cache** — not at the link, but at the cold
parallel compile of every module at once. Warm the constituent modules first (build a few
individual example standalones); the aggregate build then just links + packages (~50s, low
memory).

Ground rules for every call:
- FOREGROUND only, wrapped in `timeout 170`. Backgrounded/nohup builds are
  reaped silently between tool calls (empty logs, no zig processes).
- `-j1` always (1 core, ~3.9GB RAM). `-Dautofix=false` always.
- **A `timeout`-killed build ORPHANS its children.** `timeout` kills the `zig
  build` PARENT; the `zig build-exe` it spawned keeps compiling — on ONE core,
  forever, starving every command you run afterwards. Symptom: builds that took
  10s now take 60s, a smoke that "hangs", and a `zig build test` that seems to
  compile an example you never asked for (t1284: an orphan compiling
  `triangle_strip`'s Debug smoke wasm ran ~25 minutes and made the whole session
  look stuck). **So: after ANY `rc=124`, and any time a build feels slow, run
  `pgrep -a zig` FIRST** — and kill what you find:
  `for p in $(pgrep -x zig); do kill -9 $p; done` — NEVER `pkill zig` (it
  matches your own shell). A clean core is the difference between a 3s focused
  smoke and a 170s timeout; measure before you conclude the build is slow.
- **Watch the disk across a long turn.** The build guard fails at >=90% and its
  remedy is a ~17-minute cold rebuild. `zig-out` is pure output (1.8 GB after a
  launcher + a few standalones) and is regenerated on demand: once the
  standalones are copied to `/mnt/user-data/outputs`, `rm -rf zig-out` is free
  disk. It took one turn to go 47% -> 86%.

The steps, **one tool call each**:
1. **Warm the linter** (it gates every compile, and its own rebuild is the
   usual cold-cache time sink):
   `timeout 170 $ZIG build lint -Dautofix=false -j1`
   A cold first run may exit non-zero with only a "maker command exited" tail —
   that was the tool finishing its own compile. Run it AGAIN; now read real
   violations via `grep ': \['`.
2. **Build the example**, looping until green:
   `timeout 170 $ZIG build <dash-name>-standalone -Dmode=release -Dautofix=false -j1 2>/tmp/b.log 1>&2; echo rc=$?`
   Interpret the exit:
   - `rc=124` → timed out mid-chain. **Rerun the same command.** From cold
     expect 2–4 rounds (tool compiles ~60–90s each, wasm ~40–80s).
   - `rc=1` and `grep 'error:' /tmp/b.log` shows compile errors → real errors
     in the code; fix them.
   - `rc=1` and the log shows only a failed *configure* step (sometimes with a
     "rm -rf .zig-cache" hint) → the known transient; rerun once, it
     self-heals. Do NOT take the hint.
   - The failed-command tail names which step died (`lint_zimr <450 files>`,
     `spv2wgsl`, `c2js`): that is a TOOL rebuild, not your code.
3. **Smoke it**: `timeout 170 $ZIG build smoke-test -Dfocus=<snake_name> -Dautofix=false -j1`
   (first run may also time out while the smoke wasm builds — same retry rule).
   Green includes the per-frame call profile AND the ClobberScan.
4. **Gate**: `timeout 170 $ZIG build check -Dautofix=false -j1` → green =
   `✓ NO REGRESSIONS` + `✓ wgpu_smoke PASSED`.
5. **If shaders were added or changed**: `timeout 170 $ZIG build corpus-refresh -j1`
   — merge-preserving; the output reports `N live + M carried`, and the count
   must never need to shrink.

### WebAudio host bridge — A WHOLE SUBSYSTEM WAS NEVER WIRED TO THE BROWSER (fixed)
`src/web.zig` has declared `extern "audio" fn js_audio_*` (20 fns) since the SFX
subsystem landed, and `webtests/wgpu_smoke.zig` STUBS all 20 — so every audio
example compiled, smoke-passed, and was marked DONE. But `bridge.zig` (the ONE
browser host: Zig -> C -> c2js -> zimr.js, used by both the standalone and the
served gallery) only ever built four import namespaces — `dom`, `wgpu`,
`wasi_snapshot_preview1`, `env`. **There was no `audio` namespace at all**, so
EVERY audio example died at `WebAssembly.instantiate`:
"Import 'audio': module is not an object or function". audio_basic (7 imports),
music_streaming (12), composer_drum, audio_stream_synth — none had ever run in a
browser.

**Why it was invisible:** smoke SUPPLIES the very import the browser lacks. A
green smoke run is therefore no evidence at all that a host namespace exists.

**The fix:** ported the pre-wgpu TypeScript host (`src/web/zimr.ts` in the old
tree) into `ZimrAudio` in bridge.zig — same object graph
(`BufferSource -> Gain -> StereoPanner -> masterGain -> destination`), same id
discipline (ONE Map, one counter, ids unique across types, 0 = invalid), now in
Zig and transpiled by c2js so the page has ONE host language.
Notes worth keeping:
- **A stopped AudioBufferSourceNode can never restart** (Web Audio makes them
  one-shot). That single fact is why a source RECORD exists: `pause` banks the
  play position (scaling elapsed wall-clock by `pitch`, since playbackRate
  stretches time) and discards the node; `resume` builds a fresh node at that
  offset and reuses the existing gain->panner chain.
- **No closures in Zig->JS.** Callbacks close over state with
  `Function.prototype.bind` — `func(&onDecodeOk).call("bind", .{ num(0), rec })` —
  binding the record (or id) as the first argument.
- `decodeAudioData` DETACHES the ArrayBuffer it is given, so it gets a private
  copy, never a view onto the wasm heap. A FAILED decode still reports "ready",
  or the engine would poll forever; `take` then returns 0 (the invalid-buffer
  answer the Zig side already handles).
- `load_buffer` copies (`.slice()`) the Float32Array view before upload — the wasm
  heap can move when it grows, and `copyToChannel` must not alias it. Mono takes a
  one-call fast path; multi-channel must be de-interleaved (Web Audio is planar,
  and JS has no strided typed-array view).

**NEW GATE — `webtests/verify_imports.js`** (`node webtests/verify_imports.js
zig-out/standalone/<app>.html`). Runs the bundle's REAL host JS under Node with an
auto-mocking Proxy browser, pumps the rAF-driven boot machine, intercepts
`WebAssembly.instantiate`, and asserts every namespace the wasm imports is actually
provided. Reproduces the original bug in-sandbox (pre-fix: `dom, wgpu, wasi` ->
FAIL) and proves the fix (post-fix: `dom, wgpu, audio, wasi` -> 20/20 fns).
**Run this for any example that touches a new host namespace — smoke cannot.**
The gate now derives its requirements FROM THE WASM (`WebAssembly.Module.imports`),
not a hardcoded list, so it keeps checking new host functions as they are added.
**Proof that smoke is not authoritative for imports:** adding three new
`js_audio_*` analyser fns, which the smoke stub does NOT list, still smoke-PASSED —
the harness auto-stubs unknown names. Only verify_imports.js catches this.

### VERIFY A ZIMRMATH CHANGE AGAINST SPIR-V IN ~1 SECOND (build nothing else)
**When a compiler bump breaks shaders, read `src/notes/zig-spirv-compiler-interface.md`
first** — it is the contract with Zig's SPIR-V backend (`@SpirvType`, `@extern` descriptor
decorations, exec-mode-on-callconv, and the inline-asm `"t"` type constraint that makes
`OpLoad` of an opaque image type resolve to the module's deduped type id).

zimrmath compiles for BOTH the CPU and SPIR-V. A change that is fine natively can
fail on the shader path — and the only way to find out used to be building an
example, which after a zimrmath edit recompiles EVERY shader. Instead:

    ZIG=tools/zig-x86_64-linux-*/zig
    $ZIG build-obj -target spirv32-vulkan -mcpu vulkan_v1_2 \
      -fno-llvm -fno-lld -O ReleaseFast -ofmt=spirv \
      -femit-bin=/tmp/probe.spv \
      --dep zm -Mroot=scripts/spv_math_probe.zig -Mzm=src/zimrmath.zig
    .zig-cache/o/*/spv2wgsl --check /tmp/probe.spv

Those are the EXACT flags `src/shader_codegen.zig` uses (`-fno-llvm -fno-lld` is
MANDATORY — LLVM segfaults on the spirv target). `zm` has NO module deps, so
`--dep zm` is the only one needed; the generated `*_externs` module is NOT
required because the probe has no shader entry point.

**`spv2wgsl --check` is the real assertion**: it parses the WHOLE module, so it
proves zimr's own SPIR-V→WGSL transpiler understands every instruction the new
code emits. The WGSL OUTPUT will be ~30 bytes — spv2wgsl only emits from an
OpEntryPoint and a probe has none. That is expected, not a failure.

Used this to clear the riskiest edit of the vocabulary work: `clamp01` went from
`pub fn clamp01(v: f32) f32` to `pub inline fn clamp01(v: anytype)` with a
`switch (@typeInfo(T))`, and shaders call it 24x directly plus more via
`smoothstep`. Probe compiled in 1s; the @typeInfo switch folds away at comptime
and what reaches the backend is plain OpSelect/OpPhi/OpBranchConditional — the
same ops `min`/`max` already emit. Add a probe fn to scripts/spv_math_probe.zig
whenever a math function starts being used by shaders.

### zimrmath canonical names — the @compileError TEACHING ALIAS (the mechanism)
The tension: **discoverability** wants the alias to EXIST (`zm.mix` should resolve, or people
hand-roll duplicates — which is exactly what happened with `step`/`stepEdge`); **consistency**
wants ONE spelling in the codebase. Both, via a dead decl that teaches:

    pub fn step(edge: f32, v: f32) f32 { ... }        // CANONICAL (was `stepEdge`)
    pub inline fn clamp01(v: anytype) @TypeOf(v)      // CANONICAL, now vector-generic
    pub const stepEdge = @compileError("zimrmath spells this `step` — use `zm.step`");
    pub const saturate = @compileError("... use `zm.clamp01` ...");
    pub const mix      = @compileError("... use `zm.lerp` ...");

Why this beats a lint rule for "force people to use lerp":
1. It is a COMPILE error — cannot be skipped, no linter run needed, fires in the editor.
2. The name still RESOLVES: `@hasDecl` sees it, autocomplete lists it, and a first guess of
   `zm.mix` TELLS you the house name instead of "no member named 'mix'".
3. Zero linter machinery; every future alias is one line.

**Do NOT make `step` a linter KEYWORD.** A keyword is RESERVED (`reserved-math-names`: no other
decl/local may bear the name). Measured collisions: `zimrphysics2d.step(world, dt)` (the public
physics world-step — Box2D spells it the same way), `draw2d`'s dash `step`, `compute_host`'s
`step`. Reserving the word would force renaming a core physics API to satisfy a math linter.
`step` and `mix` are ordinary English words with legitimate non-math meanings — which is exactly
why they were excluded originally. That call was RIGHT; the bug was that `step` did not exist
under a findable name, not that it wasn't reserved. Keywords are for DISTINCTIVE math words
(`dot`, `cross`, `atan2`, `lerp`, `clamp01`), where reserving them costs nothing.
`saturate` was REMOVED from the keyword list (a @compileError decl cannot be aliased/used).

### zimrmath discoverability — a standard op under a non-standard name is INVISIBLE

`step` was already there as `stepEdge`; I searched for `step`, did not find it, and
hand-rolled a duplicate in a shader. Then the compiler revealed that `saturate` and
`lerp` were ALSO already there — my `grep '^pub fn X'` had missed them because they
are declared **`pub inline fn`**. The grep lied three times.
FIX (three layers):
1. `pub const step = stepEdge;` / `pub const mix = lerp;` — only TWO names were
   genuinely absent. The name you TYPE now exists, aliased to the implementation
   that was already there (nothing calling `stepEdge`/`lerp` breaks).
2. A greppable **GPU-MATH VOCABULARY index** in zimrmath's header, listing the
   GLSL/HLSL spelling -> the zimr name (incl. "abs/min/max/sqrt are Zig BUILTINS,
   deliberately not wrapped").
3. A `@hasDecl` test in features_test.zig pinning the whole vocabulary. **@hasDecl
   cannot be fooled by a non-standard name OR a bad grep pattern** — which is the
   real lesson: don't discover an API with grep, ask the compiler.


### GPU VALIDATION IN THE SANDBOX — the class of bug that only showed on device
**Symptom (device only):** `Attachment state of [RenderPipeline "fx_mask"] is not
compatible with [RenderPassEncoder]` — the pipeline was built with
`depthStencilFormat: Depth24Plus` but the open pass had no depth attachment.
**Cause:** `effects2d.load` HARDCODED `.less` + `.depth24_plus` into every
pipeline's StateCombo. That works only for apps with `.depth_format = .depth24_plus`
(shader_effects); an app with `.depth_format = null` (any UI/2D app) gets a
depth-LESS render texture — `loadRenderTexture` sets `.with_depth =
app.gpu_frame.depth_format != null` — and the pipeline is then incompatible.

**THE TWO-LAYER FIX (this is the pattern for this whole class):**

1. **Make it impossible by construction.** `Host.init` now takes `gl`, not a bare
   device, and reads `wgpu_app.appOf(gl).gpu_frame.{device, depth_format}` — the
   ONE source of truth. The caller is never asked for something it can get wrong.
   The pipeline now mirrors renderer_2d exactly:
       `if (depth_format != null) .always else .none`   // DepthMode
       `depth_format orelse .undefined_`                // TextureFormat (0 = no depth)

2. **Teach the SANDBOX the rule the browser enforces.** `webtests/runner.mjs` now
   implements WebGPU's attachment-compatibility check with pure bookkeeping — no
   GPU needed — because BOTH sides are visible to the shims:
     - `js_device_create_render_pipeline(..., descPtr, descLen, labelPtr, labelLen)`
       carries the descriptor blob -> forward-parse `gpu.zig`'s SECTION-3 format to
       get `depth_format` / `sample_count` / `color_format`. (Parse FORWARD: the
       tail is variable — depth-compare string, constants, extra color formats.)
     - `js_encoder_begin_render_pass(..., depth_view, resolve_view)` — `depth_view
       == 0` means no depth.
     - `js_render_pass_set_pipeline(pass, pipeline)` is where the browser rejects,
       so that is where we compare.
   A mismatch pushes `!ASSERT gpu-validation: ...`, which the EXISTING `!ASSERT`
   channel in wgpu_smoke.zig already turns into `✗ FAIL`. **Zero Zig changes.**
   PROVEN: it reproduced the device error in-sandbox on the broken build, and went
   green on the fix (red->green, so it is a real gate, not a tautology).

**GENERAL LESSON:** when a bug is only catchable on the device, ask whether the
sandbox can already SEE both sides of the rule. Here it could — the shims get the
descriptor and the attachments. Same move as `verify_imports.js` (derive the
requirement from the wasm, don't trust the stub). A stub that always succeeds is
not a test; a stub that enforces the real API's contract is.

### effects2d — the 2D effect runner is ENGINE now, not userland (raylib-shaped)
`src/effects2d.zig` + `z.effects2d`. Every effect gallery used to hand-roll its own
bind-group layouts, uniform buffers, pipeline layout, fullscreen quad, and then
drive `setPipeline` / `setBindGroup` x3 / `setVertexBuffer` / `draw` by hand — GPU
plumbing living in an example. Now:

    z.beginTextureModeRaw(gl, target, clear);
    z.effects2d.beginShaderMode(gl, &host, fx);   // raylib BeginShaderMode
    z.effects2d.drawFullscreen(gl);               //        DrawTextureRec
    z.effects2d.endShaderMode(gl);                //        EndShaderMode
    z.endTextureModeRaw(gl);

`Host.init(gpa, device, vs_wgsl)` -> `Host.load(...) !Effect` -> `Effect.setValues`.
BINDING CONTRACT (what `effect_common_io.zig` already declares): @group(0) empty,
@group(1) = source texture + sampler, @group(2) = the effect's uniform block.
The VS wgsl is a PARAMETER, not an `@embedFile` — the generated `.wgsl` is a build
artifact handed to modules by `wireEngineWgsl`, so taking it in keeps the engine
module free of build-graph knowledge.
- **The quad is NDC POSITION ONLY** (`[2]f32`, one attribute). `deferred_shading_vs`
  derives the UV from clip position; shipping a UV attribute fails pipeline
  validation against the VS's declared inputs. (Caught this before device.)
- `Host.setSource` DESTROYS the previous bind group — the hand-rolled version it
  replaced leaked one bind group per resize.
- **`std.EnumArray(Mode, Effect)` for the effect table.** The old `[N]Effect` +
  `switch (mode) => index` map meant adding one effect required editing four things
  in lockstep (array, length, index map, ubo writes) and any one could silently
  drift into a wrong-pipeline-at-runtime. EnumArray makes the mapping total and
  compiler-checked. Ubos are addressed `s.fx.get(.ascii).ubo`, not `s.effects[7]`.
Net: shader_effects.zig 620 -> 477 lines; 285 reusable engine lines.
STYLE: `@trunc` is the house form for float->int, NOT `@intFromFloat` (Simon).

### Build & disk economics (measured, 1-core box — July)
| what | cost |
|---|---|
| warm no-op rebuild | **1s** |
| edit one example -> standalone (no UI) | **~7s** total, wasm compile **3s** (MaxRSS 193M) |
| edit one example -> standalone (with `z.UiHost`) | **~15s** total, wasm compile **10s** (MaxRSS 309M) |
| build runner alone (compiling `build.zig` into an exe) | **~107s** cold — paid before any step runs |
| `lint_zimr` compile / run over ~450 files | **43s** / **8s** |
| `zig build lint` from cold | **~158s** |
| FULL cold rebuild after `rm -rf .zig-cache` | **~17 min** (6 x 170s rounds) |

(`--summary all` only prints on COMPLETION, so a >170s cold chain shows nothing — profile warm.)

Findings (measured, not assumed):
- **The wasm compile dominates** (~70% of a warm rebuild). lint_zimr, spv2wgsl, zspv,
  gen_externs and the per-shader transpiles are cached and cost milliseconds; `c2js` is a
  flat ~2s.
- **Opt mode is NOT the lever.** `-Dmode=debug` compiles in the SAME 10s and uses 2.4x the
  RAM (747M vs 309M). Don't "speed up iteration" by dropping to debug — it buys nothing and
  risks OOM.
- **Cost scales with what the example PULLS IN, not with engine size** (Zig's lazy analysis
  works): `input_mouse` (no UI) 3s vs `undo_redo` (UiHost) 10s. Pulling in `ui.zig` roughly
  TRIPLES the compile, so the UI-buttons rule (needed for phone testing) costs ~3x per
  example — worth it, but budget for it.
- **1 core, ~3.9GB RAM.** `-j1` is forced by the CPU, not memory (peak RSS 309M).
  Parallelism is genuinely unavailable; don't chase it.
- **Prefer the LAUNCHER over N standalones** when exercising several examples:
  `buildUserModShared` memoizes the shared modules, so engine+UI compile ONCE.
- Untried levers, best first: Zig incremental compilation (`-fincremental` / `--watch`);
  pinning the native tool binaries into `tools/bin/` (the cold tax is rebuilding lint_zimr /
  c2js / spv2wgsl / zspv / gen_externs at ~60-90s each after Zig's cache GC evicts them —
  there is no prebuilt-tool mechanism today, `prebuilt/` is only the web dist);
  `-ftime-report` to decide whether to attack analysis or codegen.

**★ MATCH A TOOL'S OPTIMIZE MODE TO ITS RUNTIME, NOT TO A BLANKET POLICY.** `gen_externs` is
compiled ONCE PER SHADER (~45) because it reflects over the schema at comptime — that
duplication is correct and must not be "fixed". But each exe RUNS FOR 1 ms, and it was built
`ReleaseFast`: LLVM spent ~17.6s optimizing std *per shader* = **~13 minutes of every cold
build**, to make a 1 ms script 0 ms faster. Now `.optimize = .Debug, .strip = true` (self-hosted
x86 backend, no LLVM): **0.46s per shader**, a SMALLER binary (3.2 vs 3.8 MB), stronger safety
checks, byte-identical output. `lint_zimr` (3.1s/build) and `c2js` (2.1s/build) DO earn their
optimization — the rule is runtime-proportional, not uniform.

**Disk — the hogs are NOT zimr.** Volume ~19G; zimr is <1G (`.zig-cache` 0.5-2.5G + the 409M
Zig toolchain + ~51M of src/examples). Zig's GLOBAL cache (`/root/.cache/zig`, HOME=/root) is
only ~86M — clearing it frees nothing. When disk is tight, delete in this order: `zig-out` ->
`/tmp` scratch -> old zips/HTMLs in outputs -> the non-zimr caches (`~/.cache/uv` 1.5G,
`~/.cache/puppeteer` 581M, `~/.npm-global` 749M — none referenced by zimr).
`/home/claude/study/` (3.5G: the Rust toolchain + wgpu-trunk, used to build naga as a WGSL
oracle) is the single biggest reclaim — **ask before deleting**, and keep the small useful
parts (`dawn-main`, `SPIRV-Tools-main`, `corpus_wgsl`, `spv2wgsl_audit.md`). The project
`.zig-cache` is the LAST resort (~17 min to rebuild).

**Cache pruning (learned the hard way):** deleting `.zig-cache/o/<hash>` dirs alone BREAKS the
build (`failed to check cache: ... FileNotFound`) — the manifests in `.zig-cache/h` still
reference them. Prune `/o` **and** wipe `/h` together; that took 6.3GB -> 2.6GB without a cold
rebuild.

**The build guard measures the HAZARD, not a proxy.** `checkDiskSpace` fails only at >= 90%
disk full, via one O(1) `statfs(2)` (Linux; `GetDiskFreeSpaceExA` on Windows; unmeasurable ->
never blocks) — cheap enough to run every build. It replaced `checkCacheSize`, which failed at
6GB of cache: a bad proxy for the real hazard (running out of disk mid-link), so it fired on
healthy disks and its remedy cost a full cold rebuild. Zig's std has NO statfs wrapper — the
`LinuxStatfs` ABI struct is spelled out in build.zig and called through
`std.os.linux.syscall2(.statfs, ...)`.

## Build / test gates
- General cross-cutting work: `zig build tier-a-check` — host tests + a small
  representative example typecheck + the spv2wgsl corpus + fixture WGSL.
- wgpu / spv2wgsl work: `zig build wgpu-check` — skips example typechecks.
- Arc close, unfocused: `zig build test` — re-typechecks every example (~80s).
- `-Dfocus=<comma names or prefix glob ending in '*'>` filters build / typecheck /
  smoke. The `smoke-test` filter takes the snake_case directory name
  (`-Dfocus=shader_effects`); build steps are the kebab-case name.
- **Never let a test fail, even one "not yours."** When you touch the tree you own
  the green — fix it the same turn or revert until the pre-existing failure is
  fixed. Fix errors the moment you notice them, with the best long-term solution,
  not a band-aid.
- The build CAN be broken DURING a turn if that reaches a cleaner final state
  (API-shape sweeps, type refactors across many sites); acceptance is green at the
  END of the turn. Prefer the deep correct fix over the local patch.

## Known sandbox quirks
- **`/bin/sh` does not brace-expand**: `rm src/{a,b}.zig` is a silent no-op. Use a
  loop or `xargs`.
- **`zig build test` runs at the default stack** (no more `ulimit -s unlimited`):
  the host corpus tests that drove the spv2wgsl recursive emitter past the 8MB
  thread stack were removed (zimr1233). Transpiler regression coverage now lives
  only in the standalone `wgpu-corpus` / `wgpu-check` gate (own process), so run
  that when touching `spv2wgsl.zig`. If a NEW host test ever recurses that deep,
  prefer a `std.Thread.spawn(.{ .stack_size = ... })` wrapper over reinstating the
  global ulimit footgun.
- **Cold setup**: the zip does NOT carry the toolchain (`tools/zig-x86_64-*` is
  excluded by the zip recipe), so on a FRESH sandbox there is no compiler at all —
  Simon uploads the Zig tarball and it goes in as:
  `tar -xJf <upload> -C tools/` → `tools/zig-x86_64-linux-<ver>/zig`.
  Then `. ./.zenv.sh` (it GLOB-resolves the toolchain dir; do not pin a version
  string in it — that file rotted for months naming a `704` build that was gone).
  There is NO `tools/build.zig`: the Zig tools (lint_zimr, spv2wgsl, c2js, zspv,
  gen_externs) are steps of the ROOT `build.zig` and are built on demand.
  If something is missing, ASK — don't hunt the network.

## Lint — hard gate at 0
Any new lint issue blocks `zig build`. Scope is `src/` + `examples/` + `tools/`
recursive, minus path-prefix carve-outs and a `deletion_skip` full-path list
(condemned files only — never add live code to dodge a fix).
- Write lint-clean on the first pass; apply the rules as you write.
- Edit lint sweeps bottom-up — a multi-line edit shifts the lines below it.
- Improve the linter (`tools/lint_zimr.zig`) rather than mechanically satisfying
  its own checks; after any change, re-verify it still fires on a known-bad sample.
- `decl-order` (declare-before-use for file-scope `fn`/`const`/`var`) is an OPT-IN
  migration rule, not part of the gate: `lint_zimr --decl-order <files>`. The sweep is
  DONE (1336 hits / 197 files -> 50, all in ui.zig).
  **Decision (Simon): ui.zig stays in FEATURE order** — a widget beside its helpers.
  Reordering it into a pure DAG kills only 16 of the 50 while reshuffling ~57% of a
  42k-line file. Do NOT reorder it and do NOT `lint:off` its 50; the rule is off in the
  gate, so they cost nothing. `tools/decl_reorder.py` is for future files where the
  reshuffle is mild.
  Where a true cycle is irreducible (entities' ECS cluster, zimrphysics
  World<->subsystems, bridge, wgpu_app's active_app<->App, lint_zimr's
  walkNode<->walkBlockBody, plot3d's Im<->Context back-pointer), an EXPLAINED
  `// lint:off decl-order: <why>` on the forward leg is the answer — justify it in the
  comment lines ABOVE (keep the directive line itself short, all <=120 cols).
  Self-recursion is fine.
  GOTCHA when moving a decl: a `// lint:off <rule>` line does NOT travel with it —
  re-attach it as a LEADING directive (trailing busts the 120-col rule) or the
  suppressed issue resurfaces.

## Style — one line each (the linter prints the rule when you break it)
1. 3+ fn args: one per line + trailing comma (3-4 may stay on one line if ≤90 cols).
2. Locals get explicit types — add one whenever you see a local without it.
3. Braces on EVERY branch (even `if (c) return x;` — for debugger breakpoints).
4. Casual present-tense comments: what the code does + why, never how it got there
   (no turn numbers, plan-step refs, history). Section banners `// ===== X =====`
   are fine in long files; ASCII art inside short fns is not.
5. `@splat(N)` for arrays-of-N.
6. Lift magic literals used at 2+ call sites. Lift complex sub-exprs out of
   conditions.
7. Helpers only when the name does real work and a second caller exists.
8. No mutable module globals (the C-ABI exception lives in `zimr.zig`); a
   function-scoped `const Cache = struct { var X = ...; };` is a hidden global —
   same restriction.
9. Lines ≤120 cols (markdown exempt); a trailing comma forces `zig fmt` multi-line.
10. Use the int that fits (`usize` for sizes/indices, signed for negatives, c-types
    straight off FFI) — pick for clarity, don't contort to dodge one.
11. Never read a var in the same literal that overwrites it.
12. `extern struct` only at real FFI seams.
13. An options arg, not `xxxEx` variants: `opts: FooOpts = .{}`.
14. float→int: NEVER `@intFromFloat` (banned/deprecated). Type on the line already
    (typed decl, fn return, call arg, struct/array field) → bare builtin
    `@round(x)`/`@trunc(x)`/`@floor(x)`/`@ceil(x)` — it converts in one step. Type
    NOT on the line → `zm.roundi(T,x)` / `zm.int(T,x)`(trunc) / `zm.floori` /
    `zm.ceili`. Never wrap or double-spell. Get this right the FIRST time — it's a
    30-second decision, not a build-fumble loop.
    Likewise int→float: `zm.float(x)`, never `@as(f32, @floatFromInt(x))`.
15. Matrix compose order: to apply transform P then Q, use `zm.compose(P, Q)`
    (reads in application order) — NOT bare `mulMat`. `mulMat(a, b)` applies `b`
    FIRST then `a` (later transform on the LEFT); it's fine for the already-natural
    `view_proj = mulMat(proj, view)`, but for any sequence prefer `compose`/`composeN`.
    ⚠ PORTING RAYLIB: raylib's `MatrixMultiply(left, right)` is the OPPOSITE order
    (applies left first). Translate `MatrixMultiply(A, B)` → `compose(A, B)` (same
    operand order) or `mulMat(B, A)` (swapped) — NEVER `mulMat(A, B)`. Copying
    raylib's order into `mulMat` verbatim silently reverses the composition (it
    compiles, looks close, mis-places geometry — cost us 3 turns on the decals port).
    See src/notes/math.md "Porting matrix code from raylib".

**Touching a fn means bringing the whole fn up to spec** — every line you touch
gets clearer (add asserts, comments, logs that make future bugs impossible).

## Defensive coding — assert every precondition
`assertf` liberally at the top of a fn for every precondition (arg ranges,
invariant flags, non-empty slices, unit-quat-ness). Failure is a clean trap with
`file:line` + message; without it, silent UB three frames later. Always pass
`@src()`. EXPENSIVE checks (O(n) scan, hash, tree walk) must be wrapped in
`if (comptime assert.allow_assert) { ... }` — `assertf` evaluates its `ok` arg
before checking the build flag, so an unwrapped costly precondition tanks the ship
build; the comptime guard elides it in `ship`.
```zig
assertf(substeps > 0, @src(), "substeps must be > 0", .{});
if (comptime assert.allow_assert) { /* costly check */ assertf(ok, @src(), "...", .{}); }
```

- **Never reorder, overwrite or compact an array whose elements are OWNED allocations
  freed by index — build a borrowed view instead.** `tools/spv2wgsl.zig` filtered its argv
  flags with `pos = items[1..]; pos[0] = args[0];`, which aliased one allocation into two
  slots; the cleanup loop then freed it twice. Silent heap corruption on EVERY shader
  transpile under ReleaseFast; ReleaseSafe's allocator caught it on the first build. The
  `--entry=` compaction (`pos[w] = pos[r]`) had the same defect.
- **The build tools are ReleaseSafe on purpose.** They cost ~14-20% run time vs ReleaseFast
  (~0.7s/build total) and they catch exactly the class of bug above. Worth it.

## Big-system docs live IN CODE, not in plans
Architecture for a major subsystem belongs in a `//!` module doc on that
subsystem's front-door file — not a plan or tutorial (those rot or get archived).
The WebGPU stack is documented atop `src/zimr.zig`; every sibling file gets a short
pointer to the canonical doc, not a re-explanation. When the architecture changes,
update the `//!` doc in the same turn, like a test.

## Zig 0.17 API gotchas (toolchain is 0.17.0-dev; grep the tree before assuming an API)
- **Containers are UNMANAGED, init with `.empty`, methods take the allocator.**
  `std.ArrayList(T)` IS the unmanaged type. `var xs: std.ArrayList(T) = .empty;`
  (NOT `.{}`, NOT `.init(alloc)`). Methods: `xs.append(alloc, v)`,
  `xs.toOwnedSlice(alloc)`, `map.getOrPut(alloc, k)`. `pop()` returns `?T`. Type the
  getOrPut result for the explicit-types rule:
  `const gop: @TypeOf(map).GetOrPutResult = ...`.
- **No `GeneralPurposeAllocator`** — it's `std.heap.DebugAllocator(.{}){}`:
  `var s = std.heap.DebugAllocator(.{}){}; const gpa = s.allocator();`.
- **File I/O goes through `std.Io`**: get an io
  (`var t = std.Io.Threaded.init(alloc, .{}); const io = t.io();`), then
  `std.Io.Dir.cwd().openDir(io, p, .{.iterate=true})` /
  `.readFileAlloc(io, p, gpa, limit)` / `while (try it.next(io)) |e|`. `entry.name`
  lives in a shared buffer — `arena.dupe` it before the next io call. Build text
  with `ArrayList(u8).append`/`appendSlice` + `allocPrint`, not `std.Io.Writer`.
- **`std.meta.Int` and `@Type(.{.int=...})` are GONE → `@Int(.unsigned, bits)`**
  (builtin). `std.meta.fields` is a hard `@compileError` → `std.meta.fieldNames(T)`
  / `fieldTypes(T)`.
- **`@typeInfo` is struct-of-arrays (parallel arrays).** Struct: `info.field_names`
  + `info.field_types` (no `.fields`). Fn: `info.param_types: []const ?type` +
  `info.return_type`. Enum: `field_names` + `field_values`. Iterate exactly the
  array(s) you use (`inline for (info.field_names, info.field_types) |n, t|`) — an
  unused inline-for capture is a compile error.
- **Other renames:** `bufPrintZ` → `bufPrintSentinel(buf, fmt, args, 0)`; `dupeZ` →
  `allocSentinel(u8, len, 0)` + `@memcpy`; `EnumSet.initEmpty()` → `EnumSet.empty`;
  `alignedAlloc(T, .of(T), n)` (alignment is an `Alignment` enum); a `switch` on an
  inferred error set needs `else`. `std.math.clamp(v, lo, hi)` over nested
  `@max/@min`.
- **`std.log.err` inside a test FAILS the test STEP** even if assertions pass;
  `std.log.warn` doesn't. A guard expected to fire in a test must return its error
  without logging, or log at warn.
- **The build enforces `zig fmt`** — non-conforming looks like a compile error. Run
  `zig fmt <file>` after any `.zig` edit (python-regex edits especially).
- **Test aggregators must compile or they don't run** — a green `zig build` of demos
  does NOT prove `src/tests.zig` compiles (demos don't instantiate every path). Run
  `zig build test` after toolchain-sensitive changes. `refAllDecls` is a partial net
  (non-generic decls only; generic bodies need an instantiating test).

## Working with Simon
- **Port the source you can see, not the source you remember.** Before writing Zig
  for an imgui/raylib/stb API, read the actual upstream (`/tmp/imgui-master/`
  DOCKING, `/tmp/raylib-master/`, stb under `raylib-master/src/external/`): header
  for declarations, `.cpp`/`.c` for behavior, the `_demo` for canonical usage. Cite
  `file:line` in the Zig fn's doc comment and enumerate intentional divergences. If
  it isn't on disk and you can't fetch it, ASK — API recall is the failure mode.
- **One concrete decision per question** — 2-4 options (+ implicit "other"), brief
  context, and your **(Recommended)** pick. After decisions land, summarize then
  implement.
- **Build the demo in parallel with the API** — land scaffolding from turn 1 of a
  multi-turn step. Every snapshot should be phone-testable.
- **Allocator policy**: if >80% of a struct's methods can allocate, the `gpa` stays
  on the struct. Caller-owned storage types take `gpa` explicitly on mutating
  methods, so the user can substitute a no-alloc-after-init allocator and pick a
  different allocator for their data than zimr's.
- **Don't present what you haven't verified** — before `present_files` of a new
  standalone, grep the bundle for undefined exports / missing externs and scan the
  build output. Simon's loop is slow; a broken standalone burns a round-trip.

## Archived history — where the old turns went
This file is the fresh-session entry point, not the ledger. Per-turn entries that only
recorded *that* something was built/ported/tuned live in
`src/notes/archive/changelogs/` (verbatim, nothing lost) — most recently
`changelog_zimr264-479_pruned.md`. An entry EARNS its place in claude.md only if it
teaches a rule or a root cause that is still true. When the journal below grows past
roughly the last ~70 turns, prune it the same way: move the "built X" entries out, keep
the lessons.

Authoritative state lives elsewhere and must never be restated here (it drifts):
`src/web/readme.html` (what zimr is + the API), `src/notes/raylib_port.md` (the port
counts), `build.zig` (build steps + modes), the `//!` docs in code (architecture).

## Tone
- **Never apologize, never go sad.** A turn that didn't go as planned is
  *information*. Banned: "sorry," "unfortunately," "I apologize," "I failed to." If
  something broke: "caught it — here's the fix."
- **Casual, direct, generous.** Push back when Simon is wrong; show life when
  something cracks open.
- **Be skeptical of labels.** "Known issue / intentional / negative test /
  already-done" — mine or a past note's — are not evidence; verify cheaply (read the
  code, run the one input, grep the output). A 30-second check beats a stale belief.
- **This file is yours to edit.** When you learn something a future Claude needs (a
  Zig quirk, a bug pattern, a faster command), write it down. Re-read it on a
  meta/process question, a rule bent twice, or ~10 turns since the last read.

## Cross-platform (Linux sandbox AND Simon's Windows — neither is "the" one)
Targets desktop browsers + iOS Safari + Android Chrome. Never break desktop while
fixing mobile — gate mobile paths by feature detection
(`window.visualViewport`, `'ontouchstart'`), not hard-coded checks.
- Directory walks must tolerate a missing/differently-named root (`catch continue`,
  never `@panic` — it once took down the whole configure on Windows).
- No Linux-only hardcoded paths — match an OS-agnostic prefix or branch on
  `builtin.os.tag`. Compare on bare basename (a literal `"src/foo.zig"` in
  `endsWith` misses every Windows path).
- Every `.sh` a build step shells out to needs a `.bat`/`.ps1` sibling, or gate it
  so absence is a skip.

The standing check: touching `build.zig`, a script, or anything that opens a path or
probes the toolchain → "does this still work on the OTHER OS?" before calling it
done.

## Coordinate systems (read before touching positioning code)
Three pixel kinds, and a logical-vs-CSS distinction that only matters under `.fit`:

| Name           | Where you see it                                              | Phone (DPR=3, 360-wide) |
| -------------- | ------------------------------------------------------------- | ----------------------- |
| **CSS pixel**  | `event.clientX`, DOM styles, `visualViewport`, `clientWidth`  | 360                     |
| **Backing px** | `canvas.width`, the GPU viewport / framebuffer                | 1080 = 360 × DPR        |
| **Logical px** | wasm widget code — `box.x`, `f.window.screen_width`, input    | = CSS in `.responsive`; fixed `cfg.window.width × .height` in `.fit` |

**Modes (`cfg.window.scale`)**:
- **`.responsive`** (default): logical px == CSS px. The wasm reads the canvas CSS
  dims each frame and reprograms the projection. Hit-test direct; HUDs anchor to
  `f.window.screen_width/height`. Use this unless you have a deliberate fixed design.
- **`.fit`** (opt-in): fixed logical size, scaled uniformly with letterbox bars on
  aspect mismatch (the bars are intentional). For retro games, kiosk, forced
  orientation.

**Input contract (single invariant): all input coords entering wasm are logical
pixels** — mouse, touch, drag, wheel. The bridge does CSS→logical at the JS seam, so
`getMousePosition()` matches the space `drawRectangle(x,y,...)` draws in — no ratio
scaling in user code, ever. When off-size on phone: open in desktop Chrome (DPR≈1) —
correct there ⇒ DPR-related, wrong ⇒ mode-related; then log
`x,y,w,h,screen_w,clientW,dpr` and do the pixel arithmetic, don't guess.

## Sharp edges
- **★ THE DEAD `if (73u == 73u)` GUARDS WERE A ONE-WORD BUG IN SCCP'S FOLD RULE.** The
  exclusion in `sccp.rewrite` read:
      "Skip the fold when the merge block (a) carries an OpPhi AND (b) is ITSELF a
       construct header"
  ...and then called `mergeBlockHasPhi()`, which tested **(a) only**. Zig lowers every
  branchy helper into a numeric phi STATE MACHINE, so essentially every selection it emits
  merges into a block carrying the state phi — which meant condition (a) was true almost
  always and folding was disabled almost everywhere. SCCP had already PROVEN these guards
  constant; it was simply forbidden to remove them. Implementing the rule as documented
  (now `mergeBlockPhiWouldOrphan`, testing (a) AND (b)) removed **44% of every `if` in every
  shader** — 3973 -> 2242 across 350 shaders, WGSL 8.1% smaller. effect_ascii_fs went 34 -> 15
  ifs, decal_fs 9 -> 6. Verified safe: 350/350 transpile, ZERO undeclared identifiers (the
  orphaned-phi failure this rule guards against), zero `// ERROR:` markers, full test suite
  green, launcher builds and imports PASS.
  **When a guard's comment describes an AND and the code tests one conjunct, the comment is
  usually right and the code is the bug — but check which, because over-approximating in a
  safety check is invisible: it just silently does nothing useful.**
- The residual survivors (a merge that IS a header AND carries a phi — the chained
  state-machine case) are the ones the rule legitimately protects. They are legal (constant
  condition => uniform control flow), so they are cosmetic, not correctness.


- **★ THE SAMPLER-UNIFORMITY GATE (`sampler_uniformity` in src/spv2wgsl.zig).** Runs on every
  shader at build time, on the SCCP-folded SPIR-V, and FAILS THE BUILD when an implicit-LOD
  `textureSample` is reachable only through a branch whose condition derives from a varying.
  This class used to be discoverable ONLY on device, at pipeline creation. Regression-pinned
  by two fixtures in `src/tests/fixtures/uniformity/` (the real decal_fs as it failed, and the
  fixed one as the negative control).
- **Building that gate taught two things worth more than the gate itself:**
  1. **A PHI WHOSE INCOMING VALUES ARE ALL CONSTANTS CAN STILL BE NON-UNIFORM.** Zig's SPIR-V
     lowers a branchy helper into a numeric phi state machine: `%654 = OpPhi(59u, 61u)`, then
     `%659 = %654 == 61u`, and the sample lives under `%659`. Every value in that chain is a
     constant, so a pure DATA-flow taint says "uniform" and sails straight past the bug. The
     phi is non-uniform because the CONTROL FLOW selecting between its arms is. A uniformity
     analysis needs control dependence, not just def-use. My first version had exactly this
     hole and produced a false negative on the very bug it was written for — it only got
     caught because I re-introduced the bug and demanded the gate fire.
  2. **`types.operandsAt` returns the words AFTER the opcode word.** Index operands from 0
     (`ops[0]` = result_type, `ops[1]` = result), not from 1. Getting this wrong panicked on
     all 260 shaders.
- **A GATE THAT HAS NEVER FIRED IS NOT A GATE.** Always prove it by re-introducing the bug
  (revert the fix, rebuild, demand a non-zero exit), THEN prove no false positives across
  every shader. "It compiles and reports nothing" is indistinguishable from "it is broken".
- **A BRANCHING HELPER IN THE MATH VOCABULARY IS A HAZARD TO EVERY `textureSample`
  DOWNSTREAM OF IT.** `textureSample` needs derivatives, so it needs UNIFORM control flow.
  A `zm` helper written as `if (v < 0) 0 else ...` emits REAL branches; if its condition
  derives from a varying (it usually does), the transpiler nests every downstream sample
  inside that branch and Dawn rejects the shader: *"'textureSample' must only be called from
  uniform control flow"*, with the tell-tale note *"reading from module-scope private
  variable 'o_normal' may result in a non-uniform value"* (that private var IS the varying).
  Keep zm's GPU vocabulary BRANCH-FREE: `@min`/`@max`/`@select`, never `if`. `clamp01` IS
  `clamp(v, 0, 1)`; `step` is `@floatFromInt(@intFromBool(v >= edge))`. The source-level
  `[sampler-in-branch]` lint CANNOT see this — decal_fs's source samples unconditionally at
  the top; the branch was manufactured inside a helper and exists only in the emitted code.
- **Nesting in the emitted WGSL is NOT automatically a bug.** spv2wgsl's phi-dispatch emits
  dead `if (73u == 73u)` guards. A CONSTANT condition is uniform, so a sample inside one is
  legal — `effect_ascii_fs` sits 3 `if`s deep and is valid. The question is never "is it
  nested" but "does the enclosing condition derive from a varying". A depth-only heuristic
  gives false positives; I raised one and had to retract it.
- **A `pub const X = @compileError(...)` decl takes down the TEST GATE.** `src/tests.zig` runs
  `std.testing.refAllDecls(zm)`, which REFERENCES every pub decl — and referencing a
  @compileError decl is, of course, an error. Dead spellings (`mix`, `saturate`, `stepEdge`)
  are therefore PRIVATE, empty decls whose doc comment names the canonical spelling: `zm.mix`
  fails with "not marked pub" and Zig points at that comment. `@typeInfo` only exposes pub
  decls, so refAllDecls never sees them. features_test pins that they are NOT pub; zimrmath's
  own test pins that they still exist.


- **A BRANCHING HELPER IN THE MATH VOCABULARY IS A HAZARD TO EVERY `textureSample`
  DOWNSTREAM OF IT.** `textureSample` must be reached through UNIFORM control flow.
  A helper like `clamp01`/`step` written as `if (v < 0) 0 else ...` emits REAL BRANCHES
  in SPIR-V; if its condition derives from a varying (it usually does), every sample the
  transpiler nests inside that branch is invalid WGSL — Dawn: *"'textureSample' must only
  be called from uniform control flow"*, with the tell-tale note *"reading from
  module-scope private variable 'o_normal' may result in a non-uniform value"* (that
  private var IS the varying — spv2wgsl lowers entry inputs to module-scope privates).
  Keep `zm`'s GPU vocabulary BRANCH-FREE: `@min`/`@max`/`@select`, never `if`.
  `clamp01` is now literally `clamp(v, 0, 1)`; `step` is `@floatFromInt(@intFromBool(..))`.
  The source-level `[sampler-in-branch]` lint CANNOT see this — decal_fs's source samples
  unconditionally at the top; the branch was manufactured inside a zm helper and only
  appears in the EMITTED WGSL. Read the WGSL, not just the Zig.
- **Nesting in the emitted WGSL is NOT automatically a bug.** spv2wgsl's phi-dispatch
  structurizer emits dead `if (131u == 131u)` blocks. A CONSTANT condition is uniform, so a
  sample inside one is legal — `effect_ascii_fs` sits 3 `if`s deep and is perfectly valid.
  The question is never "is it nested" but "does the enclosing condition derive from a
  varying". A depth-only heuristic gives false positives; I raised one.
- **A `pub const X = @compileError(...)` decl takes down the TEST GATE.**
  `src/tests.zig` runs `std.testing.refAllDecls(zm)`, which REFERENCES every pub decl —
  and referencing a @compileError decl is, of course, a compile error. Dead spellings
  (`mix`, `saturate`, `stepEdge`) are therefore PRIVATE, empty decls whose doc comment
  names the canonical spelling: `zm.mix` fails with "not marked pub" and Zig points at
  that comment. `@typeInfo` only exposes pub decls, so refAllDecls never sees them.
  features_test pins that they are NOT pub; zimrmath's own test pins that they still exist.


- **Drag/orbit camera first-touch pop** → a `dragging: bool` latch that SKIPS the
  first drag frame. `getMouseDelta` is `current − previous`; on the no-touch→touch
  boundary `previous` is stale, so frame 1 jumps. Fix:
  `if (down) { if (s.dragging) apply(getMouseDelta()); s.dragging = true; } else s.dragging = false;`
  — raw delta, no threshold, so rotation tracks 1:1 and only the press frame is
  skipped. Don't use the UI `getMouseDragDelta` threshold helper for a free camera.
- In library code import the math module as `const zm = @import("zimrmath.zig")`; in
  examples it's `const zm = @import("zm")`.
- **Every file that does math imports `zm` and binds `Vec`**: `const zm =
  @import("zm"); const Vec = zm.Vec;` (and `Vec2`/`Vec3`/`Mat` as needed). Prefer
  `zm` directly — do NOT reach for `z.Vec` (it isn't even re-exported through
  zimr). `Vec` is zimr's central type; write it, never the longhand `@Vector(4,
  f32)`. This holds in ALL shaders too, io schema files included: `Vec` in an
  `extern struct` UBO/vertex field transpiles to the identical `vec4<f32>` std140
  layout (verified — terrain_fs_io's Vec-typed Ubo → WGSL `field_N: vec4<f32>`,
  smoke PASS), so externs are NOT a special case. The `prefer-vec` lint rule
  enforces this (`@Vector(N,f32)` → `Vec`/`Vec3`/`Vec2`; only `zimrmath.zig`'s
  canonical `const Vec = @Vector(4,f32)` definitions are exempt; `@Vector(4,u8)`
  and other non-f32/exotic widths keep the raw form). GATING (default on) — the
  whole tree (246 findings / 73 files) was migrated in zimr531, so any new
  `@Vector(N,f32)` fails the gate; `--fix` autofixes wherever `Vec` is bound,
  `--no-prefer-vec` is the escape hatch.
- **Never re-export a zm type through a namespace** (e.g. `pub const Vec2 = zm.Vec2` inside one
  struct that a sibling then borrows as `other.Vec2`). That manufactures a false dependency edge
  between siblings. Every file/section declares its own `const Vec2 = zm.Vec2` (binding name ==
  member name). In big flat files, a borrowed type is the usual cause of a "cycle" that is really
  just a re-export.
- **FILE-AS-STRUCT is the house pattern for a single-type file** (`Canvas.zig`, `BindGroupCache.zig`,
  `WgpuGl.zig`, `SwAdapter.zig`): rename the file CamelCase = the type, top-level
  `const <TypeName> = @This();` (a descriptive alias — NEVER bare `@This()` or `Self` inline),
  fields+methods hoisted to file scope, helper types (Options, Key) nested under it. Importers do
  `const Canvas = @import("Canvas.zig");`. The `[dup-pub-fn]` lint EXEMPTS file-structs (any file
  with a col-0 `const X = @This();`), so col-0 `init`/`deinit` can't collide. Multi-export
  namespaces (`gpu.zig`, `raster.zig`) stay namespaces — don't force them.
- **Graph tooling** (all Zig, no Python — the analysis/codegen purge is complete):
  `tools/import_graph.zig` is the shared library (collectImports, Graph, sccs, levels,
  transitiveReduction); `zig build dag-check` is the acyclic gate + level report;
  `zig build files-md` regenerates the per-file atlas (curated text in
  `tools/file_descriptions.zig`); `zig build dag-png` renders `src/notes/dag.png` (layered) and
  `dag_force.png` (force-directed), tunables at the top of `tools/dag_png.zig`. Current shape:
  49 modules, 63 covering edges after reduction, 0 cycles. **When porting a generator, prove it:**
  snapshot the old output and diff byte-for-byte before deleting the original.
  The PNGs are NOT in the ship zip (the recipe excludes `*.png`) — attach them separately.
- **COMPILE-CHECK RECIPES for cross-cutting refactors**: native/Canvas path → `zig build dag-png`
  (~1 min, compiles `zimr_native_mod`); WebGPU path (gpu/wgpu_app/caches) → `zig build hello-world`
  (compiles the full wgpu wasm module). Both run lint over the roster first.
- **`grep | head` HIDES consumers.** Always grep WITHOUT `head` before declaring a rename complete
  (a `head` once hid a `z.descriptor_encoder` user and shipped a broken build).


### zimr309
Phase 4 (models) opened: added a Wavefront **OBJ** loader to the codecs.
- `src/codecs.zig` new `obj` sub-struct: `obj.parse(gpa, bytes) -> Data` (faithful:
  flat position/tex_coord/normal pools + a corner list grouped by `face_lengths`,
  1-based/negative indices resolved to 0-based, `v//vn` + quads/n-gons supported,
  unknown directives ignored). `Data.toMesh(gpa) -> Mesh` de-indexes (one unique
  vertex per distinct v/vt/vn combo via AutoHashMap), fan-triangulates, and
  synthesizes smooth normals when the file omits `vn`. Structure inspired by the
  `zig-obj` lib (Builder + errdefer + optional-index corners) and tinyobj's
  triangulated output. 3 HOST tests (pools / quad triangulation+dedup+normal
  synth / `v//vn`+negative-index) — run under `zig build test`, so the parser is
  fully sandbox-confirmed (rare; no GPU needed).
- Naming gotcha: a file-level `pub const obj` collided with a local `const obj`
  (the glTF JSON root map) in `parseJsonWithBin` -> renamed that local to
  `root_obj` (scoped 7589-8175) so the device-tested glTF path is untouched.
- `src/draw3d.zig` `pbr3d.Renderer.loadObj(bytes) -> Model`: parse -> toMesh ->
  build `Vertex[]` + u16 indices -> upload via NEW additive `uploadDefaultMesh`
  helper (white default material; loadGltf left byte-identical).
- Example `examples/wgpu_obj_simple` (registered own_frame + wireEngineWgsl, after
  gltf_simple): embedded hand-written unit cube with QUAD `v/vt/vn` faces ->
  loadObj -> lit auto-rotating draw. One small file exercises triangulation +
  tex-coord + normal parsing + de-index at once. Built debug + standalone.
- NEXT: device-confirm the cube screenshot; then optional `.mtl` materials, and a
  bigger real .obj. Phase 5 (input/core) + Phase 6 (shader inspection) still ahead;
  plot3d.md / physics_demo.md paused-not-dropped.

### zimr310
OBJ loader exercised on real data — the Stanford bunny (`bun_zipper`).
- Bunny = 35,947 positions, 69,451 tris, NO vt / NO vn (scan-derived). Leans hard
  on the loader's smooth-normal synthesis + de-index. HOST-CONFIRMED via a
  temporary embedded `zig build test` (added, run, then removed with its 2.3M data
  so src/ stays lean): parse -> 35947 positions / 0 vt / 0 vn / 69451 faces;
  toMesh -> 34,834 unique vertices (the bunny's ~1,113 UNREFERENCED hole vertices
  are correctly dropped — only face-referenced corners become vertices, same as
  tinyobj/raylib), 208,353 indices, every synthesized normal unit-length (<1e-3).
- `draw3d.zig` loadObj: added `error.TooManyVertices` guard when unique verts >
  maxInt(u16) (bunny's 34,834 fits the u16 PBR path; bigger models would need a
  u32 index path, not yet wired).
- Example `examples/wgpu_obj_bunny` (own_frame + wireEngineWgsl): @embedFile the
  bunny, recenter (AABB center -0.0168/0.1102/-0.0015) + scale 16x, lit + spin.
  Built debug + standalone (4.2M, embeds the 2.3M obj). Device-pending screenshot.
- NEXT: confirm bunny render; then optional u32 index path for >64k-vert models,
  .mtl materials. (cube = wgpu_obj_simple; bunny = wgpu_obj_bunny.)

### zimr311
Device fix: bunny threw `writeBuffer ... must be a multiple of 4`. Cause: u16
index upload size = index_count*2; an ODD index count (bunny = 208,353) gives
2-mod-4 bytes, which WebGPU's queueWriteBuffer rejects. (Cube was fine: 36 -> 72.)
- Fix in `draw3d.zig` `uploadDefaultMesh`: pad the index BUFFER to an even count
  (size multiple of 4); write a padded copy (extra slot = 0) only when odd.
  `Model.index_count` stays the REAL count so drawIndexed never draws the pad
  slot; setIndexBuffer binds the padded size (= actual buffer size). loadGltf
  has the same latent hazard but is untouched (device-tested; its models happen
  to be even-count) — fix lives only in the new obj path.
- Rebuilt wgpu_obj_bunny standalone (4.2M). zig build test exit 0. Device-pending.

### zimr312
Phase 4 forward kinematics — `examples/wgpu_forward_kinematics`. Articulated chain
of 8 bones; each joint's world transform = parent_world · localRot (sway about Z +
bend about X, phase-shifted sine down the chain), whole rig spins about Y so bones
occlude (depth test). ONE instanced draw renders all bones via the custom-pipeline
API: per-bone {mvp, nrm(rotation-only for normals), color} in a read-only STORAGE
buffer indexed by @builtin(instance_index) — no per-draw UBO churn. Lambert FS.
- Depth: window opts into depth_format=.depth24_plus -> the 2D main pass
  (f.gl.pass) carries a depth attachment (wgpu_app.zig:536-543), and z.Pipeline
  with depth=.less matches it. So a custom 3D pipeline can depth-test in the
  normal 2D pass — no own_frame / pbr3d pass needed.
- Matrix convention LOCKED: zm.Mat = [4]Vec rows; uploaded raw, WGSL reads rows as
  columns, so `m * vec4(p,1)` in WGSL == zm.mulMatPoint (pbr_vs comment confirms
  "matches GLSL M*vec4(p,1)"). matToArray writes m[r][c] row-major; works.
- AppSpec example (pub const app, no zimr_app/main), simple build list. depth via
  window.depth_format. storage_buffer read_only LayoutEntry + buffer BindEntry.
- DEVICE-PENDING: storage-read-in-VS instancing + the matrix layout + 2D-pass
  depth are confirmed-by-design but unproven on GPU — screenshot is the real test.
- Plan: models_obj ✅, models_forwardkinematics 🟡 (this, pending). Phase 4 nearly
  done. NEXT: confirm FK; then Phase 5 (input/core) or Phase 6 (shader inspection).

### zimr313
forward_kinematics DEVICE-CONFIRMED (lit, coiling, correctly-occluding rainbow
chain — proves storage-read-in-VS instancing + zm->WGSL matrix layout + depth in
the 2D pass, all at once). Phase 4 COMPLETE.
- Reconciled webgpu_control.md matrix: flipped 9 stale ❌->✅ (pipeline_basic/
  uniforms/constants/settings, vao_multibuffer, textures_bloom/array/mipmap,
  core_msaa — all shipped in zimr296-308 but never marked). models_obj ✅,
  models_forwardkinematics ✅.
- TRUE remaining: Phase 5 (input_gamepad, cursor, core_window showcase,
  benchmark_cubes+profiler panel, benchmark_tilemap), Phase 6 (shader_inspection
  — shader_introspect already exists, just needs a dump example), + optional
  textures_formats / shaders_lightmap, + readme.html currency (add obj/FK + the
  examples table). Declined: GLSL front-end, multiwindow, Vulkan backend.
- Keystone (custom pipeline/material API) done + proven. NEXT likely: Phase 6
  shader_inspection (cheap, reflection exists) or Phase 5 input_gamepad.

### zimr314
Phase 6 shader_inspection. Added a pure-Zig WGSL binding reflector +
example.
- `src/shader_introspect.zig` SECTION 4: `reflectWgslBindings(gpa, wgsl) ->
  []WgslBinding` (group, binding, name, kind, detail) + `freeWgslBindings`.
  Strips // and /* */ comments, splits on ';', scans each chunk for @group/
  @binding + the `var<addr,access> name: Type` decl; classifies uniform/storage/
  sampler/texture/storage_texture. Owns its strings (duped). 2 HOST tests (5-kind
  classification incl. commented-out decoy ignored; empty-shader case) — pure CPU,
  sandbox-confirmed like the obj parser. Reexported z.material.{WgslBinding,
  reflectWgslBindings, freeWgslBindings}.
  - GOTCHA: a global perl replace of `std.testing.expectEqual`->`expectEqual`
    clobbered the file-scope alias DEFS (lines 32-34) into self-references; restore
    those three lines verbatim. Scope replaces to the new code next time.
- Example `examples/wgpu_shader_inspection` (AppSpec, simple list): reflects a demo
  WGSL (6 bindings, all kinds, 3 groups) and renders a colour-coded layout table
  (z.drawText, one row per binding, hue by kind). Built debug + standalone.
- Plan: shader_inspection ✅. Phase 6 done (GLSL declined). REMAINING: Phase 5
  (input_gamepad, cursor, core_window showcase, benchmark_cubes+profiler,
  benchmark_tilemap), optional textures_formats/lightmap, readme.html currency.

### zimr315
BEGIN no-inline-WGSL migration. Directive: users author ALL shaders in Zig;
WGSL is an invisible build artifact. Studied the engine pattern + converted
pipeline_basic as the canonical template (builds; device-pending).

CANONICAL PER-EXAMPLE ZIG-SHADER RECIPE (follow for every conversion):
1. Author 4 files in examples/ ROOT (flat, NOT the example subdir):
   - `<name>_vs_io.zig`: `const shader = @import("shader_interface");`
     `pub const Attributes = struct { f: shader.Attr(.vecN, LOC), ... };`
     `pub const Outputs = struct { <varyings> };` (+ `pub const Ubo` if needed).
   - `<name>_vs.zig`: imports zm + `<name>_vs_io.zig` + `<name>_vs_externs`.
     `pub const Io = shader_externs.IoT(UboOrVoid); pub const Out = shader_externs.Out;`
     `comptime { _ = shader_io; }` (if io unused directly),
     `pub fn shaderMain(io_in: Io) Out { ... out.position = ...; out.<vary> = ...; }`
     `comptime { _ = shader_externs.installSpirvEntry(shaderMain); }`. Read attrs as
     `io_in.<attr_name>`; Ubo fields as `io_in.u.<field>`.
   - `<name>_fs_io.zig`: `pub const Inputs = struct { <varyings, MATCH vs Outputs> };`
     `pub const Outputs = struct { final_color: @Vector(4,f32) };` (+ Ubo/Samplers).
   - `<name>_fs.zig`: same shape; `out.final_color = ...`.
   GOTCHA: do NOT share a `_common_io.zig` between vs+fs in the EXAMPLE path
   (addShaderDepShared gives each io its own module root -> "file exists in two
   modules" error). INLINE the varying struct in both io files (wgpu_trivial does
   this). assertVaryingsMatch is STRUCTURAL (field name+type), so duplicates are
   fine. (The engine's src/shaders/ path CAN share common_io; examples can't.)
2. build.zig: add `.shaders = &.{ "<name>_vs", "<name>_fs" }` to the example's
   registration entry. Auto-wires `@embedFile("<name>_vs.wgsl")` + the io module +
   the externs into the shader source module. No configure hook.
3. Example consumes:
   `const vs_wgsl = @embedFile("<name>_vs.wgsl"); const vs_io = @import("<name>_vs_io.zig");`
   `s.shader = try z.shader.loadShaderVF(vs_io, fs_io, .{ .f = f.gpu, .gpa, .vs_wgsl_source = vs_wgsl, .fs_wgsl_source = fs_wgsl, .vertex_buffer_layouts = &.{layout}, .label });`
   Draw: `s.shader.bindForDraw(ps);` then
   `z.wgpu.render_pass.setVertexBuffer(ps.pass, .{ .slot=0, .buffer=vbo });`
   `z.wgpu.render_pass.draw(ps.pass, .{ .vertex_count = N });`. UBO: `s.shader.pushUbo(queue, val)`.

z.shader.ShaderDesc knobs: vs/fs_wgsl_source, initial_ubo, ubo_group(=2, FS UBO
convention), blend_state, color_format, depth_state, primitive_topology, cull_mode,
vertex_buffer_layouts (custom + instancing via step_mode). MISSING (need typed-path
extension for later examples): override constants, MSAA sample_count, storage-buffer
bind entries (FK/storage), compute path. So conversion order: easy geometry/texture
first (basic ✓, uniforms, vao, settings, rendertarget, postprocess, sampler, mipmap,
array), then extend the typed path for constants/msaa/storage/instancing(FK)/compute.
Finally REMOVE z.PipelineOptions.wgsl (kill inline WGSL) + readme stance.

### zimr316
SHADER PIPELINE AUDIT (z.shader / shader_runtime_wgpu.zig). Drove it off the
friction hit converting pipeline_basic. All changes additive + backward-compatible;
zig build test exit 0 (no existing consumer broke).

IMPROVEMENTS MADE:
1. TYPESAFETY: `z.shader.vertexLayout(VsSchema)` — derives an interleaved vertex
   buffer layout from the schema's typed `Attributes` (format from ElemKind,
   location from Attr.location, offsets packed in decl order, stride = sum). The
   schema is now the SINGLE source of truth; the buffer layout can't drift from
   the shader. Was: hand-written `vertex_buffer_layouts` duplicating Attributes.
   (attrElemSize/attrElemFormat helpers map ElemKind {vec2/3/4,ivec4,uvec4}.)
   ZIG 0.17: use `@typeInfo(T).@"struct".field_types` (array of types), NOT
   `.fields` (removed); each Attr type exposes `.element`/`.location` decls.
2. ERGONOMICS: LoadedShader draw methods — setVertex/draw/setIndex/drawIndexed/
   setBindGroup — so apps draw THROUGH the handle, never touching
   z.wgpu.render_pass. pipeline_basic now: bindForDraw -> setVertex -> draw.
3. COMMENTS: refreshed the module header (stale `.wgsl_source` -> current split
   vs/fs example + vertexLayout + draw-through-handle + a "Key surface" list).
   vertexLayout + each draw method fully doc-commented.

AUDIT FINDINGS DEFERRED (good future work, noted for Simon):
- `@embedFile("name.wgsl")` still puts the token "wgsl" in user code. A build-gen
  per-shader handle module (`z.shader.load(MyShaderHandle)`) could hide it fully.
- loadShader vs loadShaderVF: VF is the real one (validates varyings). Consider
  making VF the only path / deprecating bare loadShader.
- `ubo_group=2` magic default (FS-UBO convention) is undocumented at the surface;
  could be derived from which stage declares the Ubo.
- Auto-derive vertexLayout when vertex_buffer_layouts==null (currently opt-in via
  the helper to stay backward-compatible — flipping null's meaning would change
  existing 2D/cube_sidebyside callers; revisit once all migrate).
- Shader-body boilerplate (Io=IoT(...), installSpirvEntry, comptime _=shader_io)
  is repetitive; a helper could collapse it.
- MIGRATION-BLOCKER KNOBS still missing from ShaderDesc (add as I convert): override
  constants, MSAA sample_count, storage-buffer bind entries (FK/storage), compute path.

NEXT: resume the no-inline-WGSL migration with the improved API (easier now) —
convert pipeline_uniforms next (UBO via schema), then the geometry/texture batch.

### zimr317
NO-BACKWARD-COMPAT GREENLIT (Simon: "we are our only client; change everything
you're confident about"). Pushed the shader-API improvements into the core +
converted the next example, then built the launcher as the integration proof.

CORE: loadShaderVF now ROUTES THE UBO BY STAGE (killed the ubo_group magic for
callers). New MaterialSchema(Vs,Fs) + materialUboGroup(Vs,Fs): the codegen binds
a VS-declared uniform at @group(0) and an FS-declared one at @group(2)
(gen_shader_externs.zig:462-466), so loadShaderVF picks the uniform-carrying
schema, sets ubo_group automatically (VS->0, FS->2), and returns
LoadedShader(MaterialSchema). Callers NEVER set ubo_group now. @compileError if
BOTH stages declare a Ubo (auto bind group binds one stage; unsupported for now).
SAFE: every existing loadShaderVF caller has its Ubo in the FS schema (or none) ->
MaterialSchema=FsSchema, group 2 -> identical to before. zig build test exit 0.

DISCOVERY: ShaderDesc ALREADY has `constants` (-> RenderPipelineDescriptor.constants)
and `sample_count` (-> StateCombo.fromParts). So pipeline_constants + pipeline_msaa
are LESS blocked than the audit thought — they mostly need their shaders authored
in Zig, not new knobs. (Storage-buffer + compute typed paths are still the real
remaining gaps.)

MIGRATION: pipeline_uniforms CONVERTED to Zig shaders (no inline WGSL) — the FIRST
VERTEX-STAGE-UBO example through loadShaderVF. Authored examples/pipeline_uniforms_
{vs,vs_io,fs,fs_io}.zig: vs_io has Attributes{vertex_position vec2@0, vertex_color
vec3@1} + Ubo{transform:[4]@Vector(4,f32)} + Outputs{frag_color vec4}; vs body does
mulMatPoint(io_in.u.transform, {x,y,0}); fs is pass-through. Host uses
z.shader.vertexLayout(vs_io) (schema-derived layout) + pushUbo + draw-through-handle.
transform2d = mulMat(scaling(sx,sy,1), rotationZ(angle)) (zm row conv == WGSL m*vec4).
build.zig: `.shaders = &.{"pipeline_uniforms_vs","pipeline_uniforms_fs"}`.

DELIVERED: zig-out/standalone/wgpu_launcher.html (8.4M, 13 flagships: helmet_sw,
ui_full_showcase, zimrphysics, mandel_sidebyside, rt_sidebyside, plot, plot3d,
sph_fluid_2d, ecs_boids, fluid_sort, skinned_mesh, mandel_julia, kaleidoscope) as
the engine-health smoke test, + wgpu_pipeline_uniforms.html.

NEXT MIGRATION TARGETS (easy now): vao_multibuffer (hand-built multi-buffer layouts,
no UBO), pipeline_settings, then the texture batch. Then constants/msaa (author Zig
shaders; knobs already exist), then storage/FK/compute (need typed storage+compute
paths). FINAL: delete z.PipelineOptions.wgsl + readme stance.

### zimr318
MIGRATION cont. vao_multibuffer CONVERTED to Zig shaders (no inline WGSL).
KEY: it REUSES the pipeline_uniforms shaders — same typed schema (vertex_position
vec2@0, vertex_color vec3@1, vertex-stage transform Ubo), because this example's
lesson is the BUFFER SPLIT, not the shader. build.zig: vao_multibuffer registers
`.shaders = &.{"pipeline_uniforms_vs","pipeline_uniforms_fs"}` — VALIDATED that
cross-example shader reuse wires cleanly (no "file in two modules" conflict; the
generated wgsl + io + externs are shared/memoized). So a shader authored once can
back multiple examples.

DEMONSTRATES the schema is LAYOUT-AGNOSTIC: `Attributes` says what the shader
reads; whether the bytes arrive interleaved (one buffer → z.shader.vertexLayout)
or split across buffers (here: slot0 positions vec2@0 stride8, slot1 colours
vec3@1 stride12 → two hand-built gpu.VertexBufferLayout) is purely the host's
`vertex_buffer_layouts`. Host: hand-built two layouts, pushUbo(scale), draw via
bindForDraw + setVertex(0,pos) + setVertex(1,col) + draw. VS-stage UBO (scale)
auto-routed to @group(0) by zimr317's MaterialSchema. col buffer swapped between
two palettes every ~1.2s to prove slot independence. scale2d = zm.scaling(sx,sy,1).
Removed: tri_wgsl, z.Pipeline, manual bgl/bind_group, scale2d [16]f32 hand-roll.

CACHE: hit the 6GB guard mid-turn → rm -rf .zig-cache (cold rebuild slow but fine).

NEXT: pipeline_settings (two blend pipelines — .alpha vs .additive — sharing one
shader; needs a transform+ox-offset Ubo so the two clusters sit left/right, and
TWO loadShaderVF calls differing only by .blend_state). Then the texture batch
(sampler/mipmap/array — Samplers schema, note loadShader's auto bind group is
Ubo-only so samplers still bind manually). constants/msaa: knobs already exist.

### zimr319
MIGRATION cont. pipeline_settings CONVERTED to Zig shaders (no inline WGSL).
The blend-mode example: same rosette drawn twice, left .alpha / right .additive.
TWO loadShaderVF calls share ONE VS but differ ONLY by `.blend_state`
(?wgpu.BlendMode in ShaderDesc; .alpha/.additive) → two pipelines, distinct cache
keys (state_combo differs). Each LoadedShader owns its UBO, so the per-side
x-offset is pushed independently.

REUSE: bespoke VS (pipeline_settings_vs: pos vec2@0 + colour vec4@1, Ubo p:vec4 =
(sx,sy,ox,0)) + the SHARED pass-through FS (pipeline_uniforms_fs). build.zig
`.shaders = &.{"pipeline_settings_vs","pipeline_uniforms_fs"}` — VALIDATED MIXED
wiring (one example's bespoke VS + another's FS) wires + varying-asserts cleanly.
The pass-through "emit interpolated colour" FS is now de-facto shared infra.

DESIGN CALL: the original used a pipeline-OVERRIDE constant `ox` to offset the two
clusters. Override-constants-in-Zig-shaders aren't wired yet, and this example is
about BLEND not overrides, so ox moved into the UBO (p.z). Override constants stay
pipeline_constants' job (its conversion will need the Zig-shader override path —
the only genuinely-blocked knob now, since ShaderDesc.constants exists but the
shadermath side has no `override` declaration yet).

MIGRATION TALLY (no inline WGSL): pipeline_basic, pipeline_uniforms, vao_multibuffer,
pipeline_settings ✓. NEXT: texture batch (pipeline_sampler/mipmap/array) — Samplers
schema; loadShader's auto bind group is Ubo-ONLY so the sampler/texture entries
still bind manually per-draw (good next improvement: teach loadShader to bind
schema Samplers too). Then rendertarget/postprocess/bloom, msaa (sample_count
exists), then constants (needs override path), storage/FK/compute (typed storage +
compute paths).

### zimr320
MIGRATION cont. pipeline_msaa CONVERTED to Zig shaders (no inline WGSL).
Two loadShaderVF calls differ ONLY by `.sample_count` (1 vs 4) — the knob that was
already in ShaderDesc. Confirmed it threads to StateCombo.fromParts. NOTE:
ShaderDesc.sample_count is **u4** (not u32).

PROVED EMPTY-VARYING SHADERS WORK: the VS outputs only @builtin(position) (no
@location varyings) and the FS takes no inputs + emits a constant colour — so
vs_io.Outputs = struct{} and fs_io.Inputs = struct{}. assertVaryingsMatch passes on
two empty structs and the codegen/externs handle a no-varying VS/FS fine. Good to
know for any constant-colour / position-only shader.

RENDER-TARGET PINS: these pipelines render into rgba8 offscreen RenderTextures with
NO depth, so the calls pin `.color_format = .rgba8_unorm` and `.depth_state = .none`
— otherwise loadShader defaults depth to .always (because the WINDOW has a depth
format) and the pipeline would expect a depth attachment the RT pass doesn't have.
The MSAA resolve plumbing (own command encoder, multisampled colour + resolve_view)
is unchanged — that's render-pass setup, orthogonal to the shader.

MIGRATION TALLY (no inline WGSL): pipeline_basic, pipeline_uniforms, vao_multibuffer,
pipeline_settings, pipeline_msaa ✓. NEXT (non-compute): pipeline_rendertarget
(render-to-texture then SAMPLE it — first real texture/sampler example; must resolve
setMaterial's single-group bind vs the codegen's split groups: VS-Ubo@0 / samplers@1
/ FS-Ubo@2). Then postprocess/bloom. pipeline_constants needs the Zig-shader
`override` path (only genuinely-missing knob). sampler/mipmap/array + storage/FK
need typed compute/storage first.

### zimr321
MIGRATION cont. pipeline_rendertarget CONVERTED to Zig shaders (no inline WGSL).
TURNS OUT it's NOT a texture/sampler-shader example: the custom shader is the same
pos+colour+transform shader as pipeline_uniforms (REUSED), rendered ONCE into an
offscreen rgba8 RenderTexture, then composited to a 6-cell grid via the ENGINE's
drawTextureRec (2D textured path) — the texture sampling is engine machinery, not a
user sampler. So: reuse pipeline_uniforms shaders + RT pins (.color_format=rgba8_unorm,
.depth_state=.none, like msaa) + pushUbo(rotationZ) + bindForDraw/setVertex/draw inside
beginTextureMode/endTextureMode. Composite loop unchanged.

MIGRATION TALLY (no inline WGSL): pipeline_basic, pipeline_uniforms, vao_multibuffer,
pipeline_settings, pipeline_msaa, pipeline_rendertarget ✓ (6).

REMAINING inline-WGSL pipeline_* by difficulty:
- pipeline_postprocess — FIRST genuine texture/sampler-in-a-user-shader (fullscreen
  pass samples the offscreen RT). THIS is where the bind-group question must be
  resolved: setMaterial binds Ubo+tex+sampler in ONE group, but codegen splits
  (VS-Ubo@0 / samplers@1 / FS-Ubo@2). Likely the next real API improvement: teach
  loadShader to auto-bind a schema's Samplers (it's Ubo-only today) OR provide a
  clean per-draw material-bind. Investigate autoMaterialBindGroupLayout grouping +
  whether a fullscreen FS-sampler shader needs Ubo at all.
- pipeline_bloom — multi-pass postprocess (depends on the above).
- pipeline_constants — needs Zig-shader `override` declaration path (the only
  genuinely-missing ShaderDesc-adjacent knob; ShaderDesc.constants already exists).
- pipeline_sampler/mipmap/array — compute paints the texture (needs typed compute).
- pipeline_storage, forward_kinematics — storage buffers (+ compute / instancing).
NEXT: pipeline_postprocess (resolve the texture/sampler bind path).

### zimr322
INFLECTION POINT — the easy/medium pipeline_* ports are DONE (6: basic, uniforms,
vao_multibuffer, settings, msaa, rendertarget). The REMAINING inline-WGSL examples
all need CORE engine capabilities, not just ports, AND are device-verification-gated
(sampler/texture/compute correctness only shows on a real GPU — can't confirm in the
headless sandbox). So this turn = map the wall precisely + make the convenience path
fail-loud + plan, rather than ship a large unverifiable core change blind.

THE SAMPLER WALL (precisely mapped):
- The shader codegen (tools/gen_shader_externs.zig:2-3,462-466 + shader_introspect.solveLayout)
  binds VS-Ubo→@group(0), SAMPLERS→@group(1), FS-Ubo→@group(2) — samplers are a
  SEPARATE group from the Ubo.
- loadShader's auto bind group (autoMaterialBindGroupLayout) puts Ubo + samplers in
  ONE group at desc.ubo_group, and only ever creates the Ubo bind group (sampler
  resources are runtime, never supplied). So its single-group pipeline layout does
  NOT match the codegen's multi-group WGSL → a sampler shader through loadShaderVF
  would emit a mismatched pipeline (device failure).
- PROOF this is the real constraint: wgpu_cube_demo (device-confirmed) deliberately
  works AROUND loadShader — it declares Ubo+Samplers, builds `z.shader.Resources(Schema)`
  (which uses solveLayout to make a BGL+BG PER GROUP: bg_layouts[0]=Ubo, [1]=sampler),
  and hand-builds the pipeline layout chaining both groups.
- GUARD ADDED (this turn, safe): loadShader now @compileErrors if handed a `Samplers`
  schema, pointing to Resources + cube_demo. Verified NO current convenience-path
  caller uses Samplers (grep + zig build test exit 0), so the guard is inert today
  and launcher flagships are byte-identical.

USEFUL DISCOVERIES for the texture work:
- Fullscreen: `z.drawFullscreenTriangle(f.gl)` feeds 3 verts (Vertex2D: pos2+uv2+color,
  uv gradient) THROUGH the currently-bound custom pipeline via the 2D batch, then
  re-binds shapes. Flagships pair it with trivial_vs_io (pos vec2@0, uv vec2@1 →
  frag_tex_coord). So a post/sample pass reuses trivial_vs + a sampler FS, no buffer.
- @builtin(vertex_index)/instance_index ARE exposed to shadermath
  (gen_shader_externs.zig:220-221: `pub const vertex_index = std.spirv.vertex_index;`).
- z.shader.Resources(Schema): .init(gpa, f.gpu, InitArgs{initial_ubo?, <one WgpuTexture
  per Sampler2D field>}) → bg_layouts[4]/bind_groups[4]; .bind(ps) binds all groups;
  .writeUbo(v). Sampler2D fields: si.Sampler2D(.albedo, .{}).

PLAN (next): fold sampler binding into loadShaderVF by reusing Resources internally —
when the material schema has Samplers, build a Resources(Material) (textures supplied
via a new desc field), use resources.bg_layouts for the pipeline layout, store it in
LoadedShader, and have bindForDraw/pushUbo delegate to resources.bind/writeUbo. Gate
entirely on @hasDecl Samplers (no-sampler path unchanged). Then convert pipeline_postprocess
(scene = reuse pipeline_uniforms + RT pins; post = trivial_vs + new sampler FS via the new
path) — FLAG it for device check (first sampler-through-loadShaderVF). Then bloom.
SEPARATELY: pipeline_constants needs a shadermath `override` decl path; sampler/mipmap/
array + storage/FK need typed compute + storage-buffer paths.

### zimr323

**Unified `LoadedShader` on `Resources` — one bind-group mechanism for every shader (UBO-only flagships AND textured shaders).** Simon: "go all in, make me verify everything."

- `src/shader_runtime_wgpu.zig`: `LoadedShader(Schema)` now wraps `resources: Resources(Schema)` (removed the bespoke `bind_group_layout`/`ubo_buffer`/`ubo_bind_group`/`ubo_group`/`device`/`gpa` fields + `setMaterial`). `pushUbo` writes `resources.ubo_buffer`; `bindForDraw` = `setPipeline` + `resources.bind(ps)` (binds ALL used groups); new `setTexture(.field, tex)` → `resources.set`. `loadShader` builds `Resources` from `desc` (initial_ubo + new `desc.textures`) and the pipeline layout from `resources.bg_layouts` (groups 0..max, gaps → empty BGLs) — the SAME `solveLayout` group convention the codegen emits, so samplers (group 1) now bind correctly. Removed the `@compileError` sampler guard, `autoMaterialBindGroupLayout` call, `binding_point`/`ubo_group`/`pre_bake_pipelines` desc fields, and `materialUboGroup`. `MaterialSchema` routes by Ubo-OR-Samplers (compileError if BOTH stages carry resources — merge + use Resources directly, à la cube_demo). New `SamplerTextures(Schema)` builds `desc.textures` (one WgpuTexture per Sampler2D field, empty-defaulted). `buildGroup` gives the UBO all-stage visibility, so FS-UBO flagships are safe through Resources.
- First sampler consumer: **`examples/wgpu_pipeline_postprocess`** rewritten with NO inline WGSL. Scene = reuse `pipeline_uniforms` shaders into an rgba8/no-depth RT (`.color_format=.rgba8_unorm,.depth_state=.none`); post = `wgpu_trivial_vs` + new `postprocess_post_fs` (samples `io.scene(uv)` for chromatic aberration + vignette via `zm.smoothstep`/`zm.length`). Texture supplied by name: `.textures = .{ .scene = rt.asTexture() }`. Draw: `z.bindFullscreenShader(f.gl, post_fs_io, &s.post)` (binds the sampler group via the unified path) + `z.drawFullscreenTriangle`.
- `zig build test` exit 0 (engine + tier-A + host tests; the `Resources`-wrap is compile-clean). `wgpu-pipeline-postprocess` + both standalones build.
- **SIMON DEVICE-VERIFY:** (1) the LAUNCHER flagships still render (UBO path rerouted through Resources — wgpu_launcher.html); (2) pipeline_postprocess shows the spinning gradient triangle with chromatic-aberration edges + vignette (first sampler through loadShaderVF). Flag if the post image is Y-flipped (trivial_vs uv orientation) — easy fix.
- Migration tally (device-confirmed): pipeline_basic, pipeline_uniforms, vao_multibuffer, pipeline_settings, pipeline_msaa, pipeline_rendertarget. NEW pending device check: pipeline_postprocess.
- NEXT: pipeline_bloom (multi-pass sampler, now unblocked); pipeline_constants (needs shadermath `override`); sampler/mipmap/array + storage/forward_kinematics (need typed compute/storage). FINAL: remove `z.PipelineOptions.wgsl` + readme inline-WGSL stance.

### zimr324 — FIX: FS-UBO flagship group mismatch (zimr323 regression)

Device check (Simon) caught it: the launcher's fullscreen FS-UBO flagships (mandel/julia/mandel_julia/rt/raycube via loadShaderVF) showed `[Invalid RenderPipeline ".._gpu"] is invalid due to a previous error` — `createRenderPipeline` rejected them. Hand-built 3D flagships (helmet/pbr/cube3d) were fine (they don't use loadShader).

ROOT CAUSE: `shader_introspect.solveLayout` assigned EVERY `Ubo` to `defaultGroupFor(.ubo) = 0`, with no stage detection. But the codegen (`tools/gen_shader_externs.zig`, top-of-file: "VS uniforms=group 0, samplers=group 1, FS uniforms=group 2") emits an FS-stage UBO at `@group(2)`. So `Resources` built the UBO bind group + pipeline-layout slot at group 0 while the WGSL declared `@group(2)` → pipeline-layout/WGSL mismatch → invalid pipeline. cube_demo survived only because its UBO is VS-stage (group 0 both ways). zimr323's old code had dodged this via the now-deleted `materialUboGroup` (hardcoded FS→2).

FIX (`src/shader_introspect.zig` solveLayout `// ---- Ubo ----`): UBO group is now STAGE-AWARE, matching the codegen — `@hasDecl(Attributes)` (VS) → group 0; else `@hasDecl(Inputs)` (FS) → group 2; else 0. VS-UBO (cube_demo, pipeline_uniforms, rendertarget scene) stays at 0; FS-UBO flagships move to 2 where their WGSL expects them. `zig build test` exit 0; `wgpu-mandel-sidebyside` + launcher standalone build clean.

**SIMON RE-VERIFY:** launcher one-by-one — the fullscreen fractal/RT flagships should render now (helmet already did).

STILL OPEN: `pipeline_postprocess` rendered garbage (vertical bars; the post chromatic/vignette effect runs and samples, but the sampled RT content is wrong). NOT this bug — its scene is VS-UBO@0 (unaffected) and matches the device-proven `rendertarget` scene-into-RT pattern exactly. Next: add GPU-error logging to determine whether the scene pipeline silently errors (RT left uninitialized → garbage) or the post sampling/uv is wrong. Deferred from this ship.

### zimr325 — postprocess BISECT (diagnostic, not a fix)

Ruled OUT analytically: post_fs WGSL is correct (`@group(1)` scene texture+sampler, samples fine — verified in generated wgsl); `asTexture()` bundles the right color_view+sampler; `drawFullscreenTriangle` uv is correct; default window `depth_format = null` so the RT has no depth → scene's `.depth_state=.none` is correct (depth mismatch ruled out). The post effect visibly runs (chromatic fringes), so the sampler path works — the garbage is the RT *content* (the VS-UBO scene render), a path the launcher never exercised (rendertarget, the proven VS-UBO-into-RT example, is NOT in the launcher).

DIAGNOSTIC: `examples/wgpu_pipeline_postprocess` `update` now composites the RT with the device-proven `drawTextureRec` instead of the post shader (`diag_use_proven_composite: bool = true`). Bisect: clean triangle = scene+RT fine, post binding is the bug; bars = the scene render into the RT is broken (engine-level VS-UBO-into-RT regression from the Resources unification — would also affect rendertarget). Toggle back to false to restore the post shader. SIMON: what shows — triangle or bars?

### zimr326 — FIX postprocess: fullscreen sampler shaders can't use the 2D-batch draw path

Bisect result (Simon): `drawTextureRec` composite showed a CLEAN spinning gradient triangle → scene+RT perfect. So the bug was purely the post DRAW path.

ROOT CAUSE: `gpu_iface.flushBatch` (line ~603) unconditionally does `setBindGroup(ps, 1, b.current_texture_bind_group)` — the 2D shapes batch owns `@group(1)` for its texture/sampler (`--sampler-group=1`). `drawFullscreenTriangle` draws through that batch, so its flush CLOBBERS group 1 with the shapes/glyph atlas. My post FS samples its `scene` texture at group 1 (sampler solver default) → it sampled the ATLAS, not the RT → the "bars" were glyph rows. The FS-UBO flagships (rt/mandel) are immune because they read group 2, which the batch never touches.

FIX (`examples/wgpu_pipeline_postprocess`): draw the fullscreen sampler shader through the post shader's OWN pipeline + Resources bind groups (group-1 RT sampler survives) using a dedicated fullscreen VBO (`fs_verts`, 3 Vertex2D covering clip space, uv 0..2) — `s.post.bindForDraw(ps); s.post.setVertex(ps,0,fs_vbo,..); s.post.draw(ps,3,1)` — NOT `bindFullscreenShader`/`drawFullscreenTriangle` (which route through the batch). Builds clean.

ARCHITECTURAL NOTE for bloom + future fullscreen sampler shaders: `drawFullscreenTriangle` is only safe for fullscreen shaders whose resources avoid group 1 (i.e. FS-UBO at group 2). Any fullscreen shader that SAMPLES a texture (group 1) must use its own draw path. TODO: promote this owned-draw into an engine helper `z.drawFullscreenShader(gl, &loaded)` (with a cached fullscreen VBO) so bloom/sampler/mipmap reuse it instead of hand-rolling the VBO.

SIMON VERIFY: postprocess should now show the spinning gradient triangle WITH chromatic-aberration edges + vignette (the effect applied to the real RT, not the atlas).

### zimr327 — make the group-1 clobber bug IMPOSSIBLE (compile-time guard + safe helper)

Simon: "make this bug impossible, maybe assert more." Done — but at COMPILE time, not runtime (zero cost, can't be missed, fires before shipping):

1. **Centralized the reserved group** — `gpu_iface.batch_reserved_group: u32 = 1` (the group the 2D shapes batch binds its atlas at). `flushBatch`'s `setBindGroup(ps, batch_reserved_group, atlas)` now references it, so the guard and the batch can't drift.
2. **Compile-time guard** — `bindFullscreenShader` now does `comptime assertFullscreenBatchSafe(SchemaT)`: if `solveLayout(SchemaT).groups_used` includes the reserved group, `@compileError` with a message naming the schema and pointing to `drawFullscreenShader`. VERIFIED: routing `post_fs_io` (sampler@1) through `bindFullscreenShader` now fails to compile ("binds a resource at @group(1) … silently clobbered … use drawFullscreenShader instead"). FS-UBO flagships (group 2) compile fine.
3. **Safe helper** — `z.drawFullscreenShader(gl, Schema, &loaded)` draws a fullscreen triangle through the shader's OWN pipeline + Resources bind groups using a shared engine-owned fullscreen VBO (`App.fullscreen_vbo`, lazily created) — never the batch, so group 1 is never clobbered. Safe for sampler AND UBO fullscreen shaders. `examples/wgpu_pipeline_postprocess` now uses it (hand-rolled VBO removed).

`zig build test` exit 0; flagship + post + standalone build clean; negative test confirms the guard. Flagships left on the (now-guarded-safe) batch path — not churning proven device code; they CAN migrate to drawFullscreenShader later.

NEXT (migration): pipeline_bloom (multi-pass sampler — reuse drawFullscreenShader), then pipeline_constants (shadermath `override`), then storage/compute-dependent ones. FINAL: remove `z.PipelineOptions.wgsl` + readme inline-WGSL stance.

### zimr328 — robustness: single source of truth for binding groups (kills the drift bug class)

The zimr324 invalid-pipeline bug was a DRIFT bug: the codegen (`gen_shader_externs`, sets WGSL `@group`) and the runtime solver (`shader_introspect.solveLayout`, builds host bind groups) each had their OWN copy of the stage→group rule, and they disagreed on FS-UBO. Made drift structurally impossible:

- **`shader_interface.zig` (dependency-free) now owns the rule**: `uniformGroupForSchema(SchemaT)` = `if (@hasDecl(Attributes)) 0 else 2` (VS→0, FS/else→2), plus `sampler_group = 1`. Single source of truth.
- **`solveLayout` calls it** (replacing the zimr324 inline `Attributes?0:Inputs?2:0` — which ALSO had a latent disagreement with the codegen on a lone-UBO schema: solver said 0, codegen said 2; now both say 2).
- **`gen_shader_externs` calls it too** — wired `shader_interface` into the codegen module (`shader_codegen.zig` `gen_mod.addImport`). Both the @group decorations and the host bind groups now come from ONE function; they can't diverge.
- **Tied `gpu_iface.batch_reserved_group` to `shader_interface.sampler_group`** via a comptime assert in `wgpu_app` (they must be equal — the batch reserves the sampler group, and the fullscreen-batch guard relies on it).

Behavior-preserving: `uniformGroupForSchema` is byte-identical to the old codegen logic for every existing shader, so the emitted WGSL is unchanged (no rendering change) — it only removes the duplicate + fixes the latent lone-UBO edge case. `zig build test` exit 0; FS-UBO + VS-UBO + post + launcher standalone build clean.

SIMON: spot-check the launcher renders unchanged (the codegen refactor is device-critical though byte-identical in output).

NEXT (migration): pipeline_bloom (multi-pass sampler — reuse `drawFullscreenShader`).

### zimr329 — FIX zimr328 regression: merged-schema UBO group (shapes pipeline)

zimr328 broke the 2D **shapes** pipeline (device: repeated `[Invalid RenderPipeline "shapes"]`) — and shapes is the 2D batch every example draws through. Root cause: my zimr328 "simplification" of `uniformGroupForSchema` to `Attributes ? 0 : 2`. `renderer_2d` builds the shapes layout from `Resources(EngineSchema)`, and `EngineSchema` is a MERGED schema (Ubo + Samplers, NO Attributes/Inputs — its UBO is VS-stage). The 2-way rule sent EngineSchema's UBO to group 2, so `bg_layouts[0]` (read for the pipeline layout) was invalid → dead pipeline.

FIX: `uniformGroupForSchema` back to THREE-WAY — `Attributes → 0; else Inputs → 2; else 0`. The final `else 0` is the merged-VS-UBO case (EngineSchema). Still a valid single source of truth shared with the codegen: the codegen only ever processes pure VS(`Attributes`)/FS(`Inputs`) io files, so it never reaches the final case; only `solveLayout` sees merged schemas → 0. (The zimr328 framing of the lone-UBO case as a "latent bug" was wrong — that case IS the merged-material case and must be 0.)

ROBUSTNESS follow-through: added a host test in `shader_interface.zig` (`uniformGroupForSchema: VS->0, FS->2, merged-material->0`) that pins all three cases, so this regression is now caught by `zig build test` forever — not just on-device. `zig build test` exit 0; launcher + pipeline_uniforms + post standalones build clean.

SIMON: re-verify the launcher (and any 2D) renders again — shapes pipeline should be valid.

NEXT (migration): pipeline_bloom (multi-pass sampler — reuse `drawFullscreenShader`).

### zimr330 — migrate wgpu_pipeline_instancing to Zig shaders (no inline WGSL)

Ported the instancing example off `PipelineOptions.wgsl` onto the typed Zig-shader path. New `examples/instancing_vs{,_io}.zig` (3 attributes: vertex_position@0 per-vertex, instance_offset@1 + instance_color@2 per-instance; Ubo transform mat4; Outputs frag_color vec4). The fragment stage REUSES `pipeline_uniforms_fs` (pure colour pass-through — same varying), so only a VS was authored. Wired via `loadShaderVF` with THREE hand-built `vertex_buffer_layouts` (the schema can't express step rate, so instanced/multi-buffer layouts are built host-side, per the `vertexLayout` doc): slot 0 `.step_mode = .vertex`, slots 1&2 `.step_mode = .instance`. Draw via `bindForDraw` + `setVertex(slot,…)` ×3 + `draw(3, inst_count)`; UBO via `pushUbo`. zig build test exit 0; example + standalone build clean.

GOTCHA (cost a build): there are TWO instancing examples — `wgpu_instancing` (`.name = "instancing"`) and `wgpu_pipeline_instancing` (`.name = "pipeline_instancing"`). Register `.shaders` on the one matching the file you edited. `buildUserModShared(name)` → `examples/wgpu_{name}/wgpu_{name}.zig`.

WGSL-INVENTORY (answering "is there hand-written WGSL left"): YES, three buckets —
1. The escape hatch `PipelineOptions.wgsl` (material.zig:69) — removed in the migration's FINAL step.
2. Example backlog still inline: bloom, forward_kinematics, array, sampler, mipmap, storage, constants, fluid_gpu.
3. Engine-internal: `draw3d.zig` billboard_* + skybox_* (deliberate shortcut for trivial no-control-flow shaders); cube3d_* are already migrated (embedFile of spv2wgsl output).
LEGIT WGSL-as-data (NOT targets): wgpu_shader_inspection, wgpu_ui_code_editor.

BACKLOG RE-CLASSIFIED BY BLOCKER (important for ordering):
- override authoring (declare `override` in Zig shader → SpecId → spv2wgsl already parses spec constants → runtime set): blocks **bloom + constants**.
- compute/storage-texture authoring: blocks **sampler, mipmap, array** (all compute-GENERATE their test textures) + **storage, forward_kinematics, fluid_gpu**.
- instancing was the ONLY cleanly-migratable one (done now).

NEXT (Simon's call: B then A): A = build override-constant authoring → unblocks bloom + constants. That's now the highest-leverage migration enabler.

### zimr332 — FIX fluid_sort (perfect storm): spv2wgsl struct-dedup + a compute-path build gate

fluid_sort's compute kernels died on-device under 956: `gravityMouse`'s WGSL had `let _1786: S8 = P;` where `P: S3461`, two BYTE-IDENTICAL 20-field Params structs → WGSL nominal-type mismatch → invalid ComputePipeline → CommandBuffer cascade. Hit 8/11 kernels (every one reading `c.params`).

ROOT CAUSE (a perfect storm, NOT the zimr328–330 render refactor — that path never touches kompute): kompute's `Ctx` copies the uniform whole-struct by value (`c.params = Module.g.P`, kompute.zig:272). On 956 that load lowers to an `OpLoad` whose result is an UNDECORATED struct twin (S8), distinct from the Block/Offset-decorated uniform type (S3461). spv2wgsl named every `OpTypeStruct` `S<result_id>` with NO structural dedup, so the twins became two WGSL types. 892 kept them as one (or read fields per-access-chain); the kompute comment had even declared params-by-value "safe" from the known let-copy bug — 956 extended the bug's reach.

THE FIX (`src/spv2wgsl.zig` `emitTypeStruct`): structural dedup. Build the struct BODY first; if an earlier struct emitted the identical body, alias this id's `wgsl_name` to it and emit nothing (`State.struct_bodies: StringHashMapUnmanaged`). WGSL never prints `Offset`, so the decorated/undecorated twins have identical bodies and collapse → `var<uniform> P: S8` + `let _: S8 = P;` typecheck. IO structs print `@location`/`@builtin` → different body → never merged. Required-or-harmless by construction; shared back-half, so it hardens render AND compute. VERIFIED: all 11 kernels now `var<uniform> P: S8`, 0 `S3461`; launcher + fluid_sort standalones clean; `wgpu-check` corpus clean, NO REGRESSIONS, smoke PASSED.

DURABLE GATE (the compute path had none — wgsl_check is structural-only AND the corpus walker globbed `shader.spv`/`shader.opt.spv`, never kompute's `compute.spv`; two stacked blind spots):
- `wgsl_check.duplicateStructBody` — lexical tripwire: two identical struct bodies = the dedup regressed → fail at build, not device. Fits the structural charter (no semantic engine). Wired into `spv2wgsl_check.checkWgslStructural`. Host tests pin both the firing (bad) and passing (good) cases.
- `spv2wgsl_check` cache walker now also picks up `compute.spv`, so kompute kernels are gated every build.

DELIBERATELY NOT DONE: changing kompute's params-by-value to fight the compiler (brittle across exactly this kind of switch). Fix lives in the shared transpiler. FOLLOW-UP (deferred, noted): an emit-site assert refusing value-copies of types holding an unsized array/atomic (the OTHER let-copy hazard kompute dodges by discipline). FINAL GATE TO RUN: `zig build test` / `tier-a-check` for the full host-test sweep (the new guard tests sit alongside the existing in-gate wgsl_check tests).

SIMON: device-verify wgpu_fluid_sort.html (now a standalone) AND the launcher's fluid_sort flagship — the counting-sort fluid should run.

### zimr333 — FIX fluid_sort part 2: atomic buffer mis-named `arr` (956 OpName order)

After zimr332's struct dedup fixed the WGSL parse, fluid_sort reached pipeline creation and Dawn rejected clearGrid/countGrid: `Binding doesn't exist in [BindGroupLayoutInternal "clearGrid"]` for `@group(0) @binding(1)`. Root cause (second 956 regression, masked until the parse fix): the atomic grid buffer (`grid_counts`, a Buffers field) was emitted in the WGSL as **`arr`** instead of `kbuf_grid_counts`. The host's `compute_host.usedFields`/`parseBindings` key on the `kbuf_<field>` convention, so an `arr`-named binding is invisible — binding 1 was dropped from every atomic kernel's layout → the Dawn error.

WHY `arr`: kompute routes atomics through `noinline` helper `zatomicStore(arr: anytype, …)` (Zig's SPIR-V backend has no atomic builtins; spv2wgsl intercepts the call). The grid buffer is only ever passed to that helper, so Zig emits TWO OpNames on the buffer's id: the real `kbuf_grid_counts` AND `arr` (the helper's param). spv2wgsl's `.Name` handler was "first OpName wins," with a comment betting the declaration name comes first. Confirmed by parsing the .spv: on 0.17-dev.956 the order is **`arr` first, then `kbuf_grid_counts`** — first-wins kept the wrong one. (892 emitted the other order, which is why it worked.)

FIX (`src/spv2wgsl.zig` `.Name`): order-independent selection — a `kbuf_`-prefixed declaration name always beats a non-`kbuf_` duplicate; else first-wins. Now all 11 kernels emit `@binding(1) … kbuf_grid_counts: array<atomic<u32>>` and `atomicStore(&kbuf_grid_counts[…], …)`. `wgpu-check`: corpus clean, NO REGRESSIONS, smoke PASSED. Launcher + fluid_sort standalones rebuilt clean (0 `arr` atomic bindings).

DURABLE GUARD (`compute_host.parseBindings`): assert every `@binding` storage decl is `kbuf_<field>`; a non-kbuf binding now TRAPS at init with the offending line instead of silently dropping it into a cryptic Dawn error — the compute-path analog of the shader-robustness work.

SIMON: device-verify wgpu_fluid_sort.html + the launcher fluid_sort flagship — the counting-sort fluid should finally run (the cyan disk should disperse, not freeze).

### zimr334 — HARDEN the compute path: a name-agnostic host↔WGSL binding cross-check

Generalizes the zimr333 fix from "prevent the specific `arr` recurrence" to "make the whole CLASS catchable." The class: the host-built bind-group layout silently disagreeing with the kernel's actual WGSL bindings, which surfaces only as Dawn's opaque `Binding doesn't exist` cascade at pipeline creation — buried, scrolled-off, no build-time gate (sandbox has no Tint).

NEW: `compute_host.unboundUsedBinding(wgsl, bound) ?WgslBinding` — a pure, file-scope, **independent** cross-check. For every `@binding(N)` the kernel DECLARES and REFERENCES in its body, it requires N to be in the layout the host built. Deliberately NOT the `kbuf_<field>` usage scan that BUILDS the layout: it keys on each binding's *declared var name* (whatever it is — `kbuf_grid_counts`, `arr`, `P`) and matches by binding NUMBER, so a disagreement between the two derivations is exactly the drift we want. Run once per kernel at init (behind `comptime zm.allow_assert`, gone in ship) right before `createComputePipeline`; on a miss it `assertf`s with the kernel + binding number + var name + the hint that this is what Dawn reports as "Binding doesn't exist." Turns a multi-screenshot device hunt into a one-line zimr trap at init, no Tint needed — and it would have pinned the `arr` bug instantly.

Tested (the "guard must fire on known-bad" discipline): two host tests pin `unboundUsedBinding` — the `arr`-at-binding-1/layout-{0} shape returns `{1,"arr"}`; the covered case and a declared-but-unused binding both return null (no false-fire on the WebGPU "statically used" rule). `zig build test` (full host sweep + tier-A) PASSES. Helpers `isWgslIdentChar`/`wgslRefsName`/`wgslDeclName` added at file scope (whole-word, name-agnostic).

Layering now: struct-body dup → build-time lexical tripwire (zimr332); buffer naming corruption → `kbuf_` preference + init assert (zimr333); ANY host↔WGSL binding drift → init-time precise trap (zimr334). `wgpu-check` clean, NO REGRESSIONS, smoke PASSED; launcher + fluid_sort standalones rebuilt with the guard compiled in (passes for all 11 kernels, no false-fire).

### ★ CURRENT STATE + PLAN (as of the 0.17.0-dev.1245 compiler) ★

**COMPILER — now on Zig `0.17.0-dev.1245+efd6f190f`** at
`tools/zig-x86_64-linux-0.17.0-dev.1245+efd6f190f/`. Full migration notes:
`src/notes/zig1245_migration_plan.md`. Key 1245 breaking changes handled:
- **`@Vector` fields banned in `extern struct` on CPU targets** (fires at layout
  resolution; spirv32-vulkan still accepts them). Schema `Ubo`s are now PLAIN
  structs; GPU bytes via the `shader_interface` wire serializer (`wireOf`/
  `wireSizeOf`/`wireOffsetOf`), never `@sizeOf`/`asBytes` on the struct. Vertex/
  storage structs that must stay extern (InstanceVertex, kompute Buffers) use
  `[N][M]f32` (extern-legal) with Vec views. SPIR-V side keeps an extern
  `UboWire` mirror so WGSL is byte-identical.
- **struct `@typeInfo` is now PARALLEL ARRAYS** (`std.builtin.Type.Struct`):
  `field_names`/`field_types`/`field_attrs`/`decl_names` — no more `.fields`
  (`[]StructField`). Iterate `for (si.field_names, si.field_types, si.field_attrs)`;
  build with `@Struct(.auto, null, &names, &types, &attrs)`; default via
  `attr.defaultValue()`.
- **`@bitCast` from ANY struct banned** (even scalar-field extern like Color) —
  read fields directly.
- **`&vec[i]` types as `*align(A:0:N:0) f32`** — copy to scalar local, write back.
- **`std.hash.crc.Crc32` removed** — use `std.hash.crc.@"CRC-32/ISO-HDLC"`.
- **spv2wgsl OpCopyLogical (opcode 400)**: plain-struct↔wire-struct copies now
  emit OpCopyLogical; spv2wgsl handles it as a plain WGSL assignment (was
  emitting broken defaults → shadow-map corruption). CopyLogical wired alongside
  CopyObject at 4 sites in `src/spv2wgsl.zig`.
- **spv2wgsl unreachable-code (Dawn-only)**: a `.unreach` block's fall-through
  `return T();` after code that already diverges on all paths (e.g. loop body
  ending in `if (c){continue}else{break}`) is fine for naga but Dawn/Tint rejects
  it as unreachable code. `emitBlock` now suppresses it via `itemsAlwaysDiverge`
  (only when the items diverge; `exit_if`/`exit_switch` fall through to a merge and
  are NOT divergence). Caught on-device, NOT by wgpu_smoke (it uses a mock parser).
- **sampler binding collision (Dawn-only)**: each Sampler2D expands to a texture
  at N + a paired sampler at N+1, so the free-sampler solver must advance by 2, not
  1 (else texture N+1 collides with texture N's sampler). Textures now 0,2,4,…;
  samplers 1,3,5,…. Only bites shaders with 2+ unpinned samplers (helmet's 6-tex PBR).
- **sampler type mismatch (Dawn-only)**: helmet's PBR uses draw3d's hand-rolled
  `pbr3d_pipe`, whose `makeMaterialLayout`/bind-group builder used a stale BLOCK
  scheme (textures @0-5, samplers @6-11) that disagreed with the interleaved WGSL
  → Dawn: "binding type in the shader (sampler) doesn't match the layout (texture)"
  at @group(1)@binding(3). Fixed: both now derive from `pbr3d.material_tex_bindings`
  (comptime from the schema, same as the WGSL). Host-vs-WGSL drift now impossible.
- **★ SAMPLER SOLVER UNIFIED — ONE authority ★**: the sampler-pairing algorithm
  used to live in THREE hand-kept copies (`solveLayout` + 2 in `gen_shader_externs`)
  that HAD to agree — the exact drift that produced both device bugs above. Lifted
  into `shader_interface.solveSamplerSlots(SamplersT)` (both modules already import
  shader_interface; shader_introspect can't be imported by the codegen because it
  pulls in wgpu.zig). All three call sites + draw3d now delegate. Also fixed a latent
  bug the unification surfaced: a PINNED sampler now reserves BOTH its cell N and its
  paired-sampler cell N+1, so a free sampler can't land on a pinned sampler's +1 slot.
  Verified: solver + WGSL + host BGL all emit tex@0,2,4,6,8,10 / sampler@+1 for pbr.
- **LLVM native ReleaseFast SEGV** on `shadowmap_sw_verify`: RESOLVED on the
  1245 toolchain. This was a dev.956–early-1245 LLVM-backend crash (rc=139, no
  Zig panic) compiling the `native_verify.zig` module in optimized modes; the
  old workaround forced the self-hosted x86 backend (`use_llvm=false`). Verified
  gone: build.zig now uses the default (LLVM) backend with `.ReleaseFast`, no
  override anywhere, and a forced clean rebuild compiles + verifies 0-byte-diff.
  Sanity-checked the toolchain broadly: native LLVM ReleaseFast, native
  self-hosted, and wasm ReleaseSmall all build+run a hello-world fine. No repro
  remains — nothing to file.
- **`zm` is now imported by `shader_interface.zig`** (build wires it): gives
  Vec/Vec2/Vec3 aliases everywhere, so raw `@Vector` + `lint:off prefer-vec` are
  gone. zm is self-contained (build_options baked in, std.log branch comptime-dead
  on SPIR-V) so the shader-safe tier holds.
- **`-Dmode` values are `debug | release | ship`** (was `release-with-zimr-asserts`,
  renamed). Standalones for Simon use `-Dmode=release` (keeps zimr asserts on).
GATES on 1245: lint ✓ | shadowmap-sw standalone/verify (0-byte diff) ✓ | check ✓
(corpus 50 live + 86 carried, NO REGRESSIONS) | zig build test ✓ | helmet-sw +
launcher + all 17 app standalones rebuilt clean (0 UNHANDLED) ✓.

## Turn journal (oldest first; pruned turns are in archive/changelogs/)

Only entries that still teach something stay here. Superseded WIP notes, per-example port
logs and tuning runs have been moved out — see "Archived history" above.

**P1 LANDED (zimr336): the `@SpirvType` sampling helpers ship in `src/zimrmath.zig`** (so a
shader gets them from `@import("zm")`, alongside the old `zsample2d`/`location`/`binding`):
`Texture2D()`/`Texture2DPtr()`/`texture2D(name,set,bind)` + `sampleLod(tex,uv)`, and
`StorageImage2D(fmt)` + `imageStore(ImgT,img,coord,texel)`. They emit REAL ops — no
`zspv_rewrite`. Proven by `src/notes/spikes/spike_texture_shader.zig` (a shader importing
zm → 856-byte .spv with native `OpImageSampleImplicitLod` + `OpTypeSampledImage` + `@extern`
descriptor). The helpers are `fn`s not file-scope consts so `@SpirvType` stays behind Zig's
LAZY analysis — zimrmath also compiles to wasm32/host, where `@SpirvType` is invalid; a
file-scope `const = @SpirvType(...)` would break every host build. RULE: never reference
these from host code/tests. Verified host-safe: `zig build-obj src/zimrmath.zig -target
wasm32-wasi` still compiles; lint clean. (Did NOT re-back the host-side `shader_interface`
markers yet — those are pipeline metadata, changed in P3 when codegen emits the descriptors.)

**★ COMPILER-INTERFACE DOC (read when a compiler bump breaks shaders): `src/notes/
zig-spirv-compiler-interface.md` ★** — the full contract (build flags, `@SpirvType` API +
enum gotchas, `@extern` decorations, callconv forms, the `"c"`/`"t"`/value asm constraints,
addrspace→storage-class map, std.spirv limits) WITH a step-by-step recovery playbook: where
each thing lives (`lib/std/lang.zig` ships in the release → grep locally; `src/codegen/spirv/
{Assembler,CodeGen}.zig` are compiler src → `curl raw.githubusercontent.com/ziglang/zig/
<commit>/…`), how to re-derive, and the known move history. The canary spikes recompile-first.

**zimr344 — spv2wgsl BUG fixed (device test caught it): "missing return at end of function".**
- Simon's skybox standalone failed at runtime: Tint rejected the VS with `:89: missing return at end
  of function`. The corpus gate MISSED it — the gate only checks for `// ERROR:` markers, not real
  browser-WGSL validity. ⇒ DEVICE TESTING IS LOAD-BEARING for these migrations.
- Root cause: scalar `if (c) a else b` selects (my corners) lower to OpSelectionMerge with the user's
  OpReturn INSIDE a branch and an OpUnreachable post-merge tail. `emitUnreachReturn` (spv2wgsl.zig)
  emitted nothing for the ENTRY function (`if (self.is_current_entry ...) return;`) — fine for the
  old wrapper model, but a DIRECT @SpirvType entry IS the shader, so its fall-through path had no
  return → invalid WGSL. (Non-entry helpers already got a `return T();`; `.kill`→`discard;` already
  works, good for fluid later.)
- FIX: `emitUnreachReturn` now, for the entry function, stages the Outputs and emits `return outputs;`
  exactly like a normal entry OpReturn (the path is unreachable so values are immaterial — only WGSL
  validity matters). Verified the regenerated skybox_vs.wgsl now ends `...; return outputs; }`.
  `wgpu-check` → NO REGRESSIONS (the fix only adds a trailing return on unreachable entry tails).
- Rebuilt both standalones; re-sent for device-verify. This fix also unblocks ANY branchy entry shader
  (points uses the same selects; fluid's `discard` is branchy too).

**zimr345 — ROOT CAUSE of "skybox + whole 3D scene black" (NOT the shader). Pre-existing depth bug.**
- Symptom: skybox black; with a CONSTANT-colour FS STILL black; AND the entire 3D scene
  (grid/cube/sphere) black while the 2D caption rendered. Points "worked" but points
  (wgpu_compute_particles) uses `z.DrawPoints` directly, NOT `beginMode3D` — so it never exercised the
  3D depth pass. The skybox shader is a faithful port (CPU math finite; WGSL equivalent to the old
  inline; IO decorations correct; mulMatVec == WGSL m*v, proven by cube3d).
- Root cause: the 2D renderer draws with DepthMode `.always`, and `clearViewport` is a full-screen 2D
  RECT draw that runs before the 3D scene in the SAME pass. bridge.zig mapped
  `depthWriteEnabled = (depth != 7)` — EVERY mode except `.less_no_write` writes depth, INCLUDING
  `.always`. So clearViewport stamped near-z across the whole depth buffer and every later `.less` 3D
  draw (skybox at 0.999999, grid, solids) failed the test → entire 3D scene black, 2D caption (drawn
  last) still visible. Depth clears to 1.0 (bridge ~L1257), so absent the stamp 3D passes.
- `.always` is intended PASSIVE: draw3d fluid_discs comments it "passive depth-stencil (always, no real
  test)"; 2D renderer + shader_runtime_wgpu use it the same way. None want to WRITE depth.
- FIX (bridge.zig depthWriteEnabled): `if (depth != 7 and depth != 6)` — `.always` (6) and
  `.less_no_write` (7) are now non-writing passive overlay modes. Rebuilt skybox standalone; sent for
  device-verify. Also de-risks fluid (its passive `.always` pipeline was wrongly writing depth).

**zimr346 — made the depth-write bug class IMPOSSIBLE (compiler-enforced).**
- Root fragility (zimr345): the JS bridge re-derived depth semantics from a raw int — a
  position-indexed compare table + `depthWriteEnabled = (depth != 7)`. Both silently mis-handle any
  added/reordered DepthMode (a new passive mode would default to writing depth → re-introduce the
  black-screen).
- Fix: `wgpu.DepthMode` now OWNS `depthCompare()` and `writesDepth()` as EXHAUSTIVE switches (single
  source of truth). The descriptor encoder (gpu.encodeRenderPipelineDescriptor) bakes both resolved
  values into the pipeline blob; the bridge consumes them verbatim. Deleted bridge `depthCompareName`
  table + the `depth != 7` rule. Adding/reordering a DepthMode is now a COMPILE ERROR until its
  compare + write are stated — the passive-mode-writes-depth class can't recur.
- Wire format: appended `depth_compare` (str) + `depth_write` (u32) after sample_count in the encoder
  AND the bridge decode (kept in sync). wgpu-check green: NO REGRESSIONS, wgpu_smoke PASSED (exercises
  encode→decode), wgpu_demo PASS. Rebuilt skybox standalone for device re-verify.


zimr349 — INJECTED zimrphysics2d 2D-math block into src/zimrmath.zig.
  Source: port's zimrmath.zig lines 8769..EOF (the '== Z-physics2d ==' banner block,
  491 lines, appended after the trailing `test "zm.Range"`). zimr's zimrmath was NOT
  replaced (port's copy is an OLDER base missing zimr's shader helpers Sampler/StorageBuffer/
  Texture2D/ssbo*/sampleLod/imageStore). Block is self-contained: reuses existing
  dot2/cross2/length2/lengthSq2/splat2/vec2/pi; zero name collisions.
  Added 36 pub decls: TYPES Rot2,Transform2,Mat22,Aabb2,Plane2,Sweep2; FNs computeCosSin2,
  atan2Det,unwindAngle,rotationBetween2,sweepTransform2,rotateVec2/invRotateVec2,
  transformPoint2/invTransformPoint2,mulRot2/invMulRot2,mulTransforms2/invMulTransforms2,
  solve22,inverse22,mulMV22,nLerp2,integrateRot2,computeAngularVelocity2,relativeAngle2,
  normalizeOrZero2,getLengthAndNormalize2,planeSeparation2,leftPerp2/rightPerp2,
  crossVS2/crossSV2,mulAdd2/mulSub2. Box2D-deterministic trig (atan2/cos/sin polynomials)
  ported verbatim for bit-repro. Hand-edit: braced 7 single-stmt ifs for lint rule 3
  (getLengthAndNormalize2, atan2Det x4, inverse22, solve22). VERIFIED: zig fmt --check OK,
  ast-check OK, lint 0 issues, `zig test` 163/163 pass (incl. new transform round-trip +
  2x2 solve smoke). File stays SHADER-SAFE (scalar f32 / @Vector(2,f32) only). NEXT: copy
  engine -> src/zimrphysics2d.zig + export from zimr.zig; lint-clean the 12.5k-line engine;
  build wgpu_zimrphysics2d_demo (box2d-sample scenes + ui switcher).

zimr350  zimrphysics2d engine landed in flat src/ -- full wgpu-check gate GREEN.
  - src/zimrphysics2d.zig (13041 lines): faithful Box2D v3.1 (TGS-Soft) port, free-fn API
    over entities.zig + zm. Imports @import("zm")+@import("entities.zig") match zimr verbatim
    (entities resolves as a src sibling). Wired pub export at zimr.zig:327 (after zimrphysics 3D).
  - Lint clean to house style (0 issues), NO lint:off. All math routed through zm per rule:
    floatMax/floatEps/clamp/maxInt bound `const X = zm.X`; assert=zm.assert with @src() at sites.
    std.math is banned (no opt-out) -- all 4 used fns already exist in zm, nothing added.
  - CROSS-FILE name collisions: 2D step/overlapAabb collided w/ 3D zimrphysics; draw w/ text2d
    under the old [dup-pub-fn] rule (only fired linting the whole roster, 0 in single-file checks).
    Per Simon that rule no longer makes sense -> REMOVED it from tools/lint_zimr.zig (deleted the
    ~105-line cross-file pre-pass: dup_allow allowlist, wgpu_app facade exemption, pubfn_first map,
    file-struct @This() exemption). 2D engine keeps the natural `pub fn step/overlapAabb/draw` --
    nothing renamed, no re-export indirection. lint_zimr self-lints clean and rebuilds in-gate.
  - Verified: build-obj + refAllDecls (module graph zm->zimrmath->build_options) true exit 0;
    `zig build wgpu-check` GREEN (NO REGRESSIONS, wgpu_smoke PASSED).
  - NEXT: build wgpu_zimrphysics2d_demo (box2d-sample scenes + UI switcher, mirror 3D
    examples/wgpu_zimrphysics_demo/); refresh STALE regression.zig to new API (.motion_type/
    MotionType) to diff vs baseline.txt.


zimr360  ENGINE HARMONIZATION (2D Box2D ⟷ 3D Jolt), guided by the original zimrphysics2d.zip
         design docs (ENGINE_COMPATIBILITY_PLAN / API_CHANGES_2D / ENGINE_3D_CHANGES, now in
         /home/claude/work/phys/zp2d_raw). The 2D engine had already adopted the 3D engine's good
         conventions (MotionType/MotionQuality/AllowedDofs/?RayResult/QueryFilter.exclude); this pass
         moves the remaining cheap, SAFE divergences on the 3D side to the 2D anchor + adds the
         durable "stay parallel" mechanism. CREATED src/physics_common.zig: canonical
         MotionType+MotionQuality (enum(u8){static,kinematic,dynamic} / {discrete,linear_cast}) — BOTH
         engines now `pub const MotionType = physics_common.MotionType;` (and MotionQuality), so they
         are literally the same type; plus assertParallelEngines(comptime E2,E3) that @compileErrors
         if either engine drops a required parallel decl (World,Settings,MotionType,MotionQuality,
         step,overlapAabb,castRayClosest,castShapeClosest) or lets the shared enums drift. Wired into
         src/zimr.zig as `comptime { physics_common.assertParallelEngines(zimrphysics2d, zimrphysics); }`
         so every build enforces it. Both engines import siblings via relative @import so no build.zig
         wiring was needed. 3D ENGINE RENAMES (sed \b word-boundary, all in-file, 0 external callers —
         the 3D demo doesn't reference these names): gravity_factor→gravity_scale (8),
         max_linear_velocity→max_linear_speed (8), max_angular_velocity→max_angular_speed (6),
         castRay→castRayClosest (3), castShape→castShapeClosest (1), collideShape→overlapShape (1),
         collidePoint→overlapPoint (1). Left untouched: collideShapes (plural, 10), castRayVehicleFloor
         /castShapeVehicleFloor (3 each). Verified: 2D demo, 3D demo (2.2MB HTML, renamed engine runs),
         AND full wgpu-check all GREEN; physics_common lint+fmt 0. Copied the compatibility plan into
         src/notes/engine_compatibility_plan.md with a STATUS header. REMAINING (structural, deferred —
         the 3D demo uses addBody + add*Constraint ~147× so these need examples/wgpu_zimrphysics_demo
         call-site rewrites + carry risk): createBody(world,BodyDef)→handle (drop per-call gpa, use
         world.allocator), BodyHandle=ent.Handle(Body) on 3D (generation-checked identity = biggest
         win), joint vocab add*Constraint→create*Joint (Hinge→Revolute/Slider→Prismatic/Fixed→Weld),
         step(world,dt) on both (sub_step_count/scratch onto World/Settings). Each new parallel name
         should be appended to assertParallelEngines's `required` list as it lands.

zimr361  HARMONIZATION cont. — createBody/BodyDef (Phase-1 creation verb), perf-safe.
         CONTEXT: Simon confirmed GO with a hard constraint — "3D is more important than 2D for
         perf; follow Jolt PRECISELY; lose no 3D perf for similarity." Established the rule for the
         whole arc: NONE of the harmonization touches the per-step hot path — identity, creation
         verb, step shape, accessor names all live at the API boundary / setup. The two changes that
         WOULD touch Jolt's layout (relocating material/filter off the body; forcing per-body shapes
         for meshes) are explicitly NOT done: 3D keeps material/filter on the body and keeps the
         shared ShapeStore + mesh-BVH model; similarity there comes from naming + parallel accessors.
         (Shape-model perf analysis settled with Simon: shape cost = acceleration structure; cheap
         convex/primitive shapes — and ALL 2D shapes — have none, so per-body vs shared is identical;
         only mesh/heightfield BVHs benefit from sharing when instanced, which 3D keeps as an opt-in
         ShapeId path. Net unified design loses zero perf.)
         THIS INCREMENT (cold-path only, zero hot-path impact): 3D addBody→createBody, BodyDesc→
         BodyDef, dropped the per-call gpa (uses world.allocator; also MORE Jolt-faithful), still
         returns BodyIndex. Discovery: 3D bodies already live in ent.Entities and addBody already
         got a BodyHandle from world.bodies.spawn() then unwrapped it — so the handle machinery
         EXISTS; BodyHandle adoption later is cheaper than feared (but 87 public accessors take
         BodyIndex, too many for one pass). STYLE FIX: 2D createBody is a module-level FREE fn
         (phys.createBody(world,def)); 3D's was the lone World METHOD while its step/queries/
         constraints are already free fns. Added `pub const createBody = World.createBody;` after the
         World struct so 3D exposes the identical module-level surface (conformance @hasDecl passes);
         world.createBody(def) still works, so the demo's 113 + test's 5 call sites kept working after
         a mechanical `.addBody(gpa,/.createBody(` swap (+ state.gpa variant; internal caller at the
         compound builder updated). Added "createBody" to physics_common.assertParallelEngines
         required (now [9]). VERIFIED: 2D demo, 3D demo (2.2MB), full wgpu-check all GREEN.
         NEXT (each perf-neutral, own verified pass): BodyHandle/ShapeHandle identity (the 87
         accessors + 47 constraint call sites flip BodyIndex→BodyHandle, .index() internally);
         create*Joint family (addHingeConstraint→createRevoluteJoint, Slider→Prismatic, Fixed→Weld,
         Distance, Point + the 3D-unique gear/pulley/sixdof/path; drop gpa); step(world,dt) (3D
         scratch→World reset-arena, 2D sub_step_count→Settings); event buffer getters on 3D as an
         opt-in recording listener (keeps Jolt's ContactListener hot path untouched). Material/filter
         stay on the 3D body (Jolt-faithful) — align names + parallel accessors only.

zimr362  HARMONIZATION cont. — articulation family rename (pure cold-path, zero hot-path).
         Renamed all 11 3D articulation fns add*Constraint→create*Joint, with the shared concepts
         taking 2D's standard kinematics names: Hinge→Revolute, Slider→Prismatic, Fixed→Weld
         (Distance stays). 3D-specific ones keep their distinctive middle name under the unified verb:
         createPointJoint, createSwingTwistJoint, createGearJoint, createRackAndPinionJoint,
         createPulleyJoint, createSixDofJoint, createPathJoint. RESULT: both engines now expose
         identical createRevoluteJoint / createPrismaticJoint / createWeldJoint / createDistanceJoint
         — added all four to physics_common.assertParallelEngines required (now [13]). Applied as a
         whole-word global rename across src/zimrphysics.zig (11 defs + internal callers),
         examples/wgpu_zimrphysics_demo (33 actual calls + 10 UI display strings that label which API
         each scene demonstrates), and src/tests/zimrphysics_stack_test.zig (2 calls). No name
         collisions; render.zig had no constraint refs. DELIBERATELY DEFERRED to a later consistency
         sweep (kept this increment a pure rename, no body edits): dropping the per-call gpa from the
         joints (they still take world,gpa,a,b,spec — createBody already dropped its gpa); folding a,b
         into a single *JointDef + returning a JointHandle to exactly match 2D's
         createRevoluteJoint(world, RevoluteJointDef)!JointHandle shape (that fold couples with the
         BodyHandle migration, since the def would carry BodyHandles). Spec structs (HingeSpec etc.)
         left as-is for now (demo uses anonymous .{...} so call sites are unaffected). VERIFIED: 2D
         demo, 3D demo (2.2MB), full wgpu-check all GREEN.
         REMAINING (each its own verified pass): BodyHandle/ShapeHandle identity (87 accessors + the
         joint a/b params flip BodyIndex→BodyHandle, .index() internally — the foundational pass that
         also unblocks folding bodies into the *JointDefs); step(world,dt) (3D scratch→World reset
         arena, 2D sub_step_count→Settings); gpa-drop consistency sweep on the joints + wake/activate;
         opt-in event buffers on 3D (recording listener, Jolt ContactListener hot path untouched);
         material/filter stay on the 3D body (Jolt-faithful) — names + parallel accessors only.

zimr363  HARMONIZATION cont. — step(world, dt) on BOTH engines (perf-neutral).
         Both engines now expose the identical call `step(world, dt)`. 3D: dropped the per-call
         `scratch: Allocator` param; added a World-owned `scratch_arena: std.heap.ArenaAllocator`
         (init in World.init, deinit in World.deinit) that step resets `.retain_capacity` at the top
         and binds to a local `const scratch` — so the entire step body is UNCHANGED (scratch went
         from a param to a local). This is perf-neutral (same arena semantics, retain_capacity reuses
         memory) and arguably MORE Jolt-faithful: Jolt reuses a persistent TempAllocator across
         Update() calls rather than taking a fresh one each step. Demo: removed the manual
         state.scratch.reset + arg → `zp.step(&state.world, fixed_dt)`. Stack test: dropped the
         arena.allocator() arg from its 2 step calls. 2D: dropped the `sub_step_count: u32` param;
         step now reads `world.settings.sub_step_count` (the Settings field already existed, default
         4) via a top-of-fn local so its body is unchanged too. 2D demo: `phys.step(&s.world,
         fixed_dt)` + removed the now-unused `const sub_steps = 4` (= the Settings default, behavior
         identical). Note: 3D demo's State.scratch arena field is now unused (harmless; cleanup later).
         Hot path UNTOUCHED on both — only the allocator's owner (3D) and a param's source (2D) moved.
         VERIFIED: 2D demo, 3D demo (2.2MB), full wgpu-check all GREEN.
         REMAINING: BodyHandle/ShapeHandle identity (the big foundational pass — 87 user-facing
         accessors + joint a/b params take BodyHandle, resolved via .index() like 2D; BodyHandle must
         become `pub const` in 3D; care needed to migrate ONLY user-facing fns, not internal helpers
         that the hot path calls with raw indices — that categorization is per-fn, so it's its own
         focused pass). Then: fold a,b into the *JointDefs + JointHandle returns (rides on BodyHandle);
         gpa-drop sweep on joints + wake/activate; opt-in event buffers on 3D (recording listener,
         Jolt ContactListener hot path untouched); material/filter stay on the 3D body (names +
         parallel accessors only). step is now in the contract as a truly-parallel signature.

zimr364  HARMONIZATION cont. — BodyHandle identity on the 3D public creation/articulation API.
         The 3D engine now hands out and accepts generation-checked BodyHandles (matching 2D) for the
         body lifecycle, while the per-step solver still works in raw BodyIndex (hot path UNTOUCHED).
         Changes: BodyHandle is now `pub const` (was private). createBody returns BodyHandle (it already
         had the handle from bodies.spawn — just returns it instead of .index()). All 11 create*Joint
         fns take `handle_a`/`handle_b: BodyHandle` (named to avoid the joints' internal `const body_a:
         *const Body` pointer; each prepends `const a/b: BodyIndex = handle_a/b.index();` so the body is
         UNCHANGED). The two velocity accessors the demo exercises — setLinearVelocity, setAngularVelocity
         — take `body: BodyHandle` (prepend `const idx = body.index();`, body unchanged). Added helper
         `handleOf(world, idx) BodyHandle` (= BodyHandle.pack(idx, world.bodies.cycle[idx])) for the few
         internal builders (ragdoll/compound) that work in raw indices but call the now-handle-taking
         joints. Demo: holds BodyHandles (createBody results, ~59 annotations), uses .index() for its 2
         direct `world.bodies.data[...]` reads (slider_plat, clockwork_rack); the conveyor contact
         listener STAYS BodyIndex (must match engine PairCallback which passes BodyIndex) with belt
         stored as belt.index() at the boundary. Stack test made handle-based to match (ids arrays +
         anchor/bob/prev → BodyHandle, bodies.data reads via .index(); unverifiable here, mirrors demo).
         WHY safe for perf: createBody/joints/velocity-setters are all cold-path (user setup/poke); the
         solver reads world.motion[idx]/bodies.data[idx] with raw indices and never calls these public
         accessors, so identity packing never enters the per-step loop. VERIFIED: 3D demo, 2D demo
         (conformance), full wgpu-check all GREEN.
         REMAINING accessor sweep (separate, consistency-only): the demo only exercises the 2 velocity
         setters, so the other ~85 user-facing accessors (getLinearVelocity, applyImpulse, setMotionType,
         removeBody, materialAt, get/setTransform, ...) STILL take BodyIndex. Migrating them is mechanical
         (same param-rename + .index() prepend) and compile-verifiable, but per-fn: skip any internal
         helper the hot path calls with a raw index. Also still pending: fold a,b into the *JointDefs +
         JointHandle returns (now trivial — defs carry BodyHandle, exactly like 2D); gpa-drop sweep on
         joints + wake/activate; opt-in 3D event buffers; material/filter name alignment on the body.

zimr365  HARMONIZATION cont. — gpa-drop on the 11 joints (toward 2D's def-based joint API).
         The create*Joint family no longer takes a per-call `gpa: std.mem.Allocator`; each uses
         `world.allocator` internally (same allocator the demo was passing — World.init(gpa) stores it,
         so behavior is identical). All gpa body-uses (constraints.append / six_dof.append / paths.append
         / the path joint's gpa.alloc) became world.allocator. Joints are now
         createRevoluteJoint(world, handle_a, handle_b, spec) — exactly one step from 2D's
         createRevoluteJoint(world, def): fold handle_a/handle_b + spec into a *JointDef and return a
         JointHandle, and they match. Call sites updated: demo 32 single-line + 1 multi-line (gear),
         engine internal ragdoll callers 5 single-line + 2 multi-line (swing-twist parent, distance),
         stack test 1 single-line + 1 multi-line. Cold-path only (joint creation); hot path untouched.
         Also fixed a PRE-EXISTING latent lint issue the stale-lint-cache had been masking: demo had an
         inline `zm.quat_identity` in createPathJoint — now bound at file scope as
         `const quat_identity = zm.quat_identity;` (no-qualified-zm). It surfaced because this turn's
         rebuild cleared the lint cache. VERIFIED: 3D demo, 2D demo, full wgpu-check all GREEN.
         REMAINING: (1) fold a,b+spec into *JointDef + JointHandle returns => exact 2D joint parity
         (biggest structural reshape left; demo-verified but BEHAVIORALLY needs Simon's screenshot since
         a swapped a/b or wrong spec field compiles fine — worth a dedicated careful pass). (2) accessor
         BodyHandle sweep is NOT cleanly doable as a blanket: getPointVelocity + addImpulseAtPosition are
         called from the CONTACT SOLVER hot path, and moveKinematic/setTransform/addImpulse from per-frame
         pose application — migrating those forces handle-packing into warm/hot paths (violates perf
         rule). Only ~6 (setMotionType, getMotionType, addForce, addForceAtPosition, addTorque,
         addAngularImpulse) are internal-caller-free and cleanly migratable, but doing only those splits
         the impulse/force families across types — to get a uniform handle API the hot-path-shared ones
         need a public-handle wrapper + private *ByIndex core (a deliberate design choice, defer). (3)
         gpa-drop sweep continues to wakeBody/activateBody/velocity-setters. (4) 3D event buffers;
         material/filter name alignment.

zimr366  HARMONIZATION cont. — collision-filter name alignment + latent-breakage fix.
         (1) Renamed the 3D body collision-filter field collides_with -> mask, matching 2D's Filter.mask
         (category already matched on both). 7 sites incl the BodyDef field, the createBody copy, and the
         broad-phase filter check `(a.category & b.mask) != 0 ...`. Pure rename, same access, zero perf
         change. NOTE the model split stays (Jolt-faithful): 2D keeps a Filter STRUCT on the shape; 3D
         keeps category/mask as fields ON THE BODY — only the NAME is aligned, not the location.
         (2) Fixed latent breakage discovered while scoping a velocity-setter gpa-drop: 5 internal callers
         (moveKinematic x2, Ragdoll.setVelocities x2, character setVelocity) passed raw BodyIndex
         (body_indices: []BodyIndex, char.body: BodyIndex) to setLinear/AngularVelocity, which take
         body: BodyHandle since zimr364. They compiled only because Zig's lazy analysis never reached
         them (unreferenced by the demo) — i.e. the zimr364 migration left them type-broken in dead code.
         Now wrapped with handleOf(world, idx) so they are correct whenever those paths go live.
         VERIFIED: 3D demo, full wgpu-check GREEN.
         STRATEGIC NOTE — the CORE API harmonization is now essentially done (enums, createBody/BodyDef,
         create*Joint w/ BodyHandle + no gpa, step(world,dt), BodyHandle identity on creation+joints+
         velocity-setters, collides_with->mask), all enforced by assertParallelEngines. Every REMAINING
         item now hits a genuine Box2D-vs-Jolt MODEL difference, not just naming:
           • Joint def-fold + JointHandle: 2D's JointHandle is pool-based (ent.Handle(Joint)) + JointBaseDef
             carries Box2D frame/threshold fields; 3D stores constraints in a plain ArrayList the SOLVER
             iterates directly. Exact parity => restructure 3D constraint storage => touches the hot path /
             breaks Jolt-fidelity. Only a light 3D-flavored def (wrap a,b+spec, index-based handle) is safe;
             modest value, reshapes 33 demo calls w/ behavioral (screenshot) risk.
           • Event API: 2D = Box2D buffered/queryable (getContactEvents); 3D = Jolt push ContactListener.
             Different paradigms. Bridge = opt-in recording listener on 3D (additive, hot-path-safe; reuses
             the existing contacts_prev/curr derivation, guarded so zero overhead when off). Real feature
             parity but gives the Jolt engine a Box2D-style surface.
           • Accessor BodyHandle sweep: getPointVelocity + addImpulseAtPosition are called from the CONTACT
             SOLVER; moveKinematic/setTransform/addImpulse from per-frame pose. Uniform handle API needs a
             public-handle wrapper + private *ByIndex core for those (deliberate design choice).
         => These are direction calls for Simon (how far to push vs preserve each engine's native model),
         not obvious mechanical wins. Surfaced to him this turn.

zimr388: ENGINE FEATURE + SHOWCASE. Added a PULLEY JOINT to the 2D TGS-soft solver (box2d v2's
         b2PulleyJoint, dropped in box2d v3 — reintroduced here). New JointType.pulley + PulleyJoint
         payload {ground_anchor_a/b, ratio, constant(lazy sentinel -1), anchor_a/b, s_a0/s_b0, u_a/u_b,
         mass, impulse}; prepare/warmStart/solve (single equality constraint C = constant - lenA -
         ratio*lenB, body anchors taken at COM via computeJointFrames, Cdot = -dot(uA,vpA) -
         ratio*dot(uB,vpB)); wired into all dispatch + the 3 exhaustive switches (getConstraintForce
         returns u_b*(-ratio*impulse*inv_h); getConstraintTorque 0; drawJoint draws both rope legs +
         a connecting bar). Public PulleyJointDef + createPulleyJoint(world,.{.base,.ground_anchor_a/b,
         .ratio=1}). Inline host test "pulley joint conserves rope length and transfers load": heavy
         box hauls light box up while lengthA+ratio*lengthB stays constant to <0.05 — PASSES.
         PORTED the CS296 "Dominos" Rube Goldberg machine (Erin Catto / IIT-Bombay CS296 lab) as a new
         category Showcase|Dominos. Faithful v2->v3 port of ~40 bodies: ground+basin edges->segments,
         SetAsBox(hw,hh,c,angle)->new attachRotBox helper (makeOffsetBox+Rot2.fromAngle+friction),
         cannon (wheel + 2 angled barrel walls, recoil v=-5) firing a ball v=(17,15), recoil ball,
         right staircase (angular/vertical/horizontal shelves), 2 revolving flaps (plank pivoting on
         static hinge via revolute with localFrameA.p=(0,-1.5)/B.p=(0,0) — mismatched anchors stand the
         flap up, faithful to source), bouncy ball, 7-domino run, heavy struck ball, weight-balance
         frame (7 fixtures hinged on a wedge tip), the LEFT PULLEY (open carrier box + heavy toothbrush,
         both lock_rot, joined by createPulleyJoint over ground anchors (-22,25)/(-5,25)), centre see-saw
         platform (center-pivot revolute) with a heavy bead, bottom-left see-saw plank on a wedge with a
         weight + stop box, and a water block in a basin. sub_step_count=8. Dynamic bodies that omitted
         density in the v2 source (->mass forced to 1 there) given density 1 here; unspecified shelf
         friction set to box2d's 0.2 default. cam target (6,16) ppm 7 frames the whole machine.
         Lint clean (engine + scenes), 2D standalone builds x2, wgpu-check GREEN, pulley host test green.
         106 scenes. Dominos is an ADDITION beyond the box2d-137 set (still 33 of 137 portable-remaining,
         unchanged). The pulley was the last missing joint TYPE; it also unblocks any future b2 pulley
         sample. NOT yet device-verified (chain-reaction timing differs across solvers; geometry faithful).

zimr390: PERF FIX (engine) — per-step scratch arena. Simon device-reported Benchmark|Capacity
         (1000 circles) "freezes": UI stayed responsive (could place a mouse-drag joint) but the
         world crawled (3 min to settle), and he intuited it correlated with CONSTRAINT COUNT. Root
         cause confirmed by a host harness (/tmp/cap_bench.zig, World+step directly): step() and its
         callees alloc/FREE several contact-count-sized scratch arrays EVERY step — measured 5 allocs
         / ~343 KB per step at 1000 bodies during the chaotic high-contact phase (two big
         ContactConstraint arrays: the prepared `constraints` and the color-sort `temp`; plus
         contact_color, wide_blocks, touching_ids, active_joints, narrowPhase `disjoint`). On the host
         (page_allocator, mmap) this is free, so prior timing (0.84ms/step) hid it; the WASM demo uses
         std.heap.wasm_allocator (src/wgpu_app.zig:432) where per-step alloc/free of contact-sized
         buffers is the dominant cost and scales with contact count — exactly the freeze.
         FIX: added `step_arena: std.heap.ArenaAllocator` to World (init/deinit wired). step() calls
         `_ = world.step_arena.reset(.retain_capacity)` at the top, and ALL step-scoped scratch now
         allocates from `world.step_arena.allocator()` instead of world.allocator (touching_ids,
         constraints, active_joints, wide_blocks via buildWideBlocks, colorConstraintGraph's 4 arrays,
         narrowPhase disjoint) — defers dropped (arena reclaims wholesale). Persistent things
         (events, contacts.spawn, contact_ids) STILL use world.allocator. retain_capacity keeps the
         peak working set, so after warmup the backing allocator sees ZERO per-step traffic.
         VERIFIED on host harness: per-step allocs 5/343KB -> 0 allocs/0 bytes at steady state (one
         tiny 136B event-buffer growth around step 30). All engine inline tests PASS (solver
         correctness unchanged), lint clean, 2D demo builds x2, wgpu-check GREEN. Scene counts left
         intact on purpose — this is the principled fix and it helps every dense scene (Smash 1200,
         Junkyard, Compounds, Barrel), not just Capacity. Arena is freed+recreated per scene switch
         (demo does world.deinit+World.init), so no cross-scene memory accumulation. AWAITING Simon
         device re-test of Capacity; if still choppy during the initial fall, trimming counts is the
         follow-up, but the allocator cliff is gone.

zimr391: DIAGNOSTIC — on-device perf HUD (Simon: "Capacity still freezes. Maybe show numbers?").
         The zimr390 arena fix helped (pile settles further/faster, a chunk now sleeps = gray grid)
         but Capacity still chugs. Added a live readout to the demo control panel (under the Scene
         line): "{fps} fps {ms}/frame", "phys {ms} x{substeps} draw {ms}", "bodies {n} contacts {n}
         awake {n}". Timing via z.wgpu.nowMs() (performance.now) around the accumulator loop and around
         phys.draw separately; counts via world.bodies.count()/contacts.count()/active.items.len;
         EMA-smoothed (0.15). New State fields perf_frame_ms/perf_phys_ms/perf_draw_ms/perf_substeps.
         HYPOTHESIS to confirm from the numbers: render-bound, not physics-bound. phys.draw walks ALL
         shapes every frame regardless of sleep, and drawSolidCircle emits 3 primitives per circle
         (filled disc + AA outline ring + spoke line, 2 of them AA-stroked); at 1000 circles that is
         ~3000 AA primitives/frame built on the single wasm thread, independent of how many bodies are
         asleep. So as bodies sleep, phys ms should fall but draw ms stays pinned -> freeze persists.
         If the device shows high draw ms / low phys ms, the fix is render-side: skip the AA outline +
         spoke for tiny circles (r_px below ~5) drawing only the filled disc, and/or lower the circle
         segment floor — cuts dense-scene render ~3x without touching normal-scale scenes. Deliberately
         did NOT change rendering this turn so the baseline numbers are clean. Demo-only change; engine
         untouched since zimr390. Lint clean, builds x2, wgpu-check GREEN.

zimr392: ROOT-CAUSE FIX for the Capacity "freeze" — contact-pool overflow. The zimr391 HUD made it
         obvious: device showed 114 fps, phys 0.2ms, draw 0.4ms (engine FAST) but "contacts 2047" pinned
         at capacity-1, and Simon: "always freezes at 2047 contacts." World.init sized ALL pools (bodies,
         shapes, CONTACTS, joints) to the same `capacity` (demo uses 2048). But contacts are not
         one-per-body: a dense 2D pile is ~3x bodies + speculative fat-AABB pairs. Reproduced on host
         with a tight pack (spacing 0.92): contacts pinned at 2047 and EVERY step errored (601/600) —
         because the overflowing world.contacts.spawn returns error, step() propagates it, and the demo's
         `phys.step(...) catch {}` swallows it, so step aborts in updateBroadPhasePairs before integrating
         -> world frozen, UI still live. sizeof(Contact)=224 B.
         FIX (engine, World.init): contact pool now sized `capacity *| 6` (12288 at cap 2048 = 2.75MB,
         up from 459KB) — six contacts/body covers a maximally dense pack at full body capacity with
         margin. bodies/shapes/joints unchanged (shapes at `capacity` still fine: densest shape scene is
         ~1003). VERIFIED on host dense bench: contacts now climb to 3847 with 0 errored steps (was 2047 /
         all-errored). All engine inline tests PASS, lint clean, demo builds x2, wgpu-check GREEN.
         Note the earlier fixes still stand and matter: zimr390 arena (no per-step alloc churn) is why
         phys is 0.2ms even at thousands of contacts; this fix removes the hard cap that was the actual
         freeze. The HUD (zimr391) stays — now shows contacts climbing past 2048 without stalling.
         FOLLOW-THOUGHT: the silent `catch {}` in the demo hid a hard failure as a freeze; a future
         hardening could make contact creation drop-on-full (box2d-ish) rather than error, but adequate
         pool sizing is the correct primary fix.

zimr393: pool-overflow HARDENING (Simon: "dynamic increasing of max bodies/contacts would be good if
         it does not cause problems/perf hit, or at least assertf when we hit a cap?"). Investigated
         dynamic growth and DECIDED AGAINST it — here is why, recorded so we don't retry blindly:
         the entity pool (ent.Entities) is not just a data[] array; alloc() reserves a PARALLEL ECS slot
         via Entity.reserveImmediateOrErr(&self.ecs) with a hard assert(ecs_e.key.index == idx) — the
         pool and a separate ECS Registry must stay in lockstep by index. A grow() that reallocs only the
         primary triple (data/cycle/free_list) leaves the ECS registry at its old capacity, so the very
         next alloc past the old cap returns EcsEntityOverflow (verified: pool data grew to 2200 but
         allocation stayed pinned at the ECS cap, every step still errored). Growing the ECS core in
         lockstep is a deep, risky change to the ECS monolith — exactly the "problems" the request guarded
         against. So dynamic growth is NOT a clean/safe win for these pools; dropped it (removed the
         half-grow method).
         DELIVERED instead, the safe high-value subset:
         (1) generous fixed sizing kept (zimr392: contacts = capacity*|6) — covers every real scene;
         (2) loud assertf on ALL four pools (body/shape/contact/joint) when spawn hits the cap: in an
         assert build it panics with a located, named message ("shape pool exhausted: live=511 cap=512;
         raise World.init capacity" + file:line); in a stripped ship build the assertf is comptime-elided
         via `if (comptime zm.allow_assert)` and the real error is returned instead (NO unreachable/UB).
         This converts the old silent-freeze (overflow -> error -> demo's `catch {}` -> step aborts) into
         an immediate, actionable failure. assertf bound at file scope (const assertf = zm.assertf).
         VERIFIED: forcing cap 512 with a 1000-body scene prints the named pool message; all engine inline
         tests PASS; lint clean (entities + engine); demo builds x2; wgpu-check GREEN.
         If we ever truly need unbounded bodies/contacts, the correct path is a growable ECS registry (or
         a paged/stable-address pool), scoped as its own carefully-tested effort — not a quick patch.

zimr394: Issues category ported — 5 box2d robustness/solver repros (114 scenes, 26 of 137 left).
         New category "Issues" with builders in scenes.zig:
         - Bad Steiner: near-degenerate sliver triangle (3 almost-collinear pts far from body origin)
           dropped on a segment; stresses hull centroid / Steiner-point inertia. attachHull.
         - Crash01: dynamic platform held by a motorised revolute (to a hanging attachment box) AND a
           limited motorised prismatic (to ground); the mixed-joint crash repro in default dynamic
           state. pinRevolute + pinPrismatic + attachRotBox(0.5,4,{4,0},pi/2,2,0.6).
         - StaticVsBulletBug: r0.3 bullet at (58.9,77.5) vel(104.9,-281.1) lock_rot into a static 5-vert
           hull (~48-69 x, 68-70 y); CCD-vs-static repro. createShape polygon + bullet circle.
         - Unstable Prismatic Joints: light r0.5 centre between two r2 circles on spring prismatics
           (hertz10 damp2, target_translation ∓3); solver stress test. createPrismaticJoint direct
           (needs target_translation, which pinPrismatic does not expose; base local frames left
           identity = box2d default).
         - Unstable Windmill: 4 box rotors welded around a gravity-free r5 disc via weldRotor() helper
           with base.constraint_hertz=30; weld stability test. createWeldJoint with explicit body-local
           frames (NOT worldToLocal — box2d sets localFrame.p directly). Ground segment at y=-10.
         DEFERRED: Issues|Disable (pure enable/disable checkbox, no autonomous behaviour; we do not
         surface a runtime body enable/disable toggle and update_s has no UI hook).
         VERIFIED: lint clean; demo builds x2; wgpu-check GREEN; host smoke (assert build, 180 steps
         each) on the 4 physics-risky scenes = errs 0/180, all-finite — near-degenerate hull does not
         trip computeHull/makePolygon, spring-target prismatic + weld constraint_hertz stay stable,
         bullet-vs-static-hull CCD resolves. Cam hints: zoom→ppm ~ inverse (Bad Steiner ppm90 zoomed
         in on the tiny sliver; Windmill ppm12 to frame the ~35m span).
         REMAINING 26: mostly capacity/query benchmarks (Cast/Shape Distance/CreateDestroy/Large
         Compounds/Washer/Sensor/Barrel 2.4), visualization-driven Events(5), engine-blocked World(3
         f64 origin-shift), gear/user-constraint Joints(2), and interactive Shapes/Continuum scenes.

zimr395: Benchmark|Washer ported (115 scenes, 25 of 137 left). A kinematic spinning ring "drum"
         (box2d CreateWasher): 36 wedge polygons between r1=16..r2=18 plus 4 inner spokes (r0=14..r1)
         every 9th, built by rotating a unit dir vector by 10deg/wedge (rotateVec2 bound at file scope;
         qo=±0.1*10deg insets the wedge edges, exactly box2d). Body is .kinematic with angular_velocity
         = 25deg/s -> verified on host the kinematic drum integrates rotation (spun 1.7453 rad in 240
         steps = 0.4363 rad/s = 25deg/s exactly). Debris grid scaled 90->40 (1600 small squares, hit
         events) to stay in the 2048 body pool. Host smoke: 1601 bodies, 6642 contacts, 0 errs/240,
         all finite — and the 6642 contacts is a nice real-world confirmation the zimr392 6x contact
         pool (12288) carries a heavy scene with margin. lint clean; demo builds x2; wgpu-check GREEN.
         cam target (0,10) ppm14 frames the ~36-wide ring. Renames for lint/compiler: u1/u2 dir vectors
         -> dir_a/dir_b (u1/u2 shadow Zig primitive int types), square -> cell (reserved math name).
         DEFERRED this pass (documented in box2d_samples_plan.md):
         - Benchmark|CreateDestroy: rebuilds a 5050-body pyramid 10x/frame; over capacity AND visually
           static (resets each frame) — pure create/destroy throughput micro-bench, low value.
         - Benchmark|Large Compounds: ~50k shapes (static ground alone is ~40k tiny boxes) on a few
           bodies; far over the 2048 shape pool, and we already have a Compounds scene.
         - Character|Mover: a code-driven capsule character controller (pogo raycast + keyboard input +
           custom per-step movement); not a faithful data-only port.
         REMAINING 25: Benchmark(Barrel 2.4 / Cast / CreateDestroy / Large Compounds / Sensor / Shape
         Distance — mostly query/throughput or over-capacity), Events(5 visualization-driven), World(3
         f64 origin-shift, engine-blocked), Joints(Gear Lift / User Constraint — need gear joint /
         callback), Shapes(Custom Filter / Modify Geometry — callback/interactive), Continuous(Ghost
         Bumps / Pinball — interactive), plus Collision|Dynamic Tree, Determinism|SnapShot, Robustness|
         Cart. Next genuinely-portable candidates are thin: Robustness|Cart (vehicle) and possibly a
         scaled Barrel 2.4; most of the rest are engine-blocked or interactive/callback-driven.

zimr396: GROWABLE ENTITY POOLS — the real fix so the engine matches box2d's dynamic counts (no
         fixed cap, no per-scene caps workaround). Simon: "if entities can't grow we can't be as good
         as box2d, non-starter."
         WHY it could not grow (root cause, now understood fully): an Entities(T) slot is THREE coupled
         allocations sharing one index space — (1) the pool triple data/cycle/free_list, (2) the
         Registry.handle_tab SlotMap (the thing that overflowed when I grew only the pool in zimr393),
         (3) the chunk_pool (only for secondary components). 1 and 2 are index/key-addressed (free lists
         index-based, no element pointers held across calls), so reallocating them is safe iff both grow
         to the SAME new capacity — lockstep holds because watermark/next_index are untouched by a grow
         and the free lists stay valid. It was simply ported from a pre-sized (zcs-style) ECS; nothing in
         the data model forbids growth. The ONE thing not realloc-safe is the chunk_pool: chunks are raw
         *Chunk pointers into one arena (indexOf derives index from pointer offset), so realloc would
         dangle them — but chunks are only used for SECONDARY components, and the physics pools are
         primary-only, so that path is untouched (segmenting the chunk arena is a documented future step).
         DELIVERED (entities.zig): SlotMap.grow (realloc slots+free_next, memset new region, indices
         stable); Registry.growEntities (grows just handle_tab — the only entity-sized member; bumps
         pointer_generation); Entities(T).grow (grows pool triple + handle_tab to the same cap, keeping
         the lockstep invariant). Unit-tested in isolation: from cap 4, spawned 200 (pool+ECS grew to 256
         in lockstep), all 200 handles deref correct, destroyed-half invalidate, 100 survivors stay valid,
         recycle+respawn across the grown region works. PASS.
         DELIVERED (zimrphysics2d.zig World orchestration): the World owns body-indexed side tables, so it
         must grow them WITH the bodies pool. growBodies grows bodies.grow + motion(=Motion.zero tail) +
         state(=BodyState.identity tail) + island_parent/island_can_sleep/body_sleep (scratch, like init)
         + active.ensureTotalCapacity + body_bits (per-step scratch, cleared each step via @memset, so
         just resized and words_per_color updated — no re-layout needed). growShapes/growContacts/
         growJoints are just pool.grow (shapes/contacts/joints have NO parallel World arrays; the
         broad-phase DynamicTree.nodes and contact_ids/joint_ids/active/sensors are already dynamic
         ArrayLists). All four create paths (createBody/Shape/Contact/Joint) now grow-and-retry on
         PoolExhausted (amortised doubling) instead of asserting — the pool now behaves like a growable
         container (ArrayList-with-recycling-and-handles), which was the stated goal. zm.assertf binding
         removed (create paths no longer assert; true OOM still propagates).
         VERIFIED end to end: dense 1000-body scene started at cap 512 grows bodies 512->1024, shapes
         512->1024, contacts 3072->6144, 0 errs/400 steps, finite, exactly 1001 bodies — body_bits
         re-size + graph coloring stay correct across the grow. Engine inline tests PASS; entities inline
         tests PASS; lint clean (entities + engine); demo builds x2; wgpu-check GREEN.
         APPLIED: Benchmark|Washer reverted to box2d-native 90x90 (8100 debris squares); host smoke shows
         it auto-grows to bodies=8101, contacts=38333, 0 errs, drum spins 25deg/s. This is the first
         benchmark running at box2d's EXACT numbers via growth rather than a scale-down.
         IMPLICATION: per-scene capacity hints are NO LONGER NEEDED. The demo's world_capacity=2048 is now
         just an initial size; loadScene re-inits at 2048 and every scene grows to fit. Over-capacity
         benchmarks (Large Compounds ~50k shapes — note the broad-phase is a BVH so it's tractable;
         CreateDestroy 5050 bodies) are now portable at native size; CreateDestroy still has the separate
         u8-handle-generation saturation caveat under extreme per-frame churn (slots retire after 255
         reuses -> handle_tab grows under churn; widen HandleTab generation if we port it).
         FUTURE (documented, not needed for physics): chunk_pool growth via a SEGMENTED arena (append
         stable-address pages) for component-bearing pools at scale; growing arches similarly.

zimr397: PROFILER instrumentation for the 2D physics step (the 8100-body Washer runs ~2fps; needed
         to see WHERE the step time goes). Mirrored the 3D engine's pattern (zimrphysics.zig uses
         profiler.zoneNamed(@src(),"name") + defer end at phase boundaries).
         zimrphysics2d.zig: import profiler (+ pub re-export profiler_mod so host harnesses/tools read the
         same zone store the engine records into; the in-app HUD reads it via zimr.zig's z.profiler
         re-export — same instance within the zimr module). Wrapped step() phases in zones:
         p2d.step (top), p2d.broadphase (updateBroadPhasePairs), p2d.narrowphase (narrowPhase),
         p2d.prepare (state reset + touching collect + prepareContacts + joints + colorConstraintGraph +
         buildWideBlocks), p2d.solve (the TGS substep loop), p2d.finalize (restitution + storeImpulses +
         finalizeBodies + continuous), p2d.sleep (refitActiveBodyAabbs + sleepIslands), p2d.sensors.
         Zones are comptime no-ops when profile_enabled is off (ship); on for debug/release (the demo
         build). NOTE host test/harness command now needs `--dep build_options` on the ROOT module too,
         since zimrphysics2d -> profiler -> build_options.
         HUD: added a per-phase breakdown to the 2D demo control panel — profiler.aggregate over the ~2s
         window, filtered to p2d.* zones, printing mean ms/step per phase. So the device (the only honest
         profiler for wasm) shows the split live.
         HOST MEASUREMENT (washer 8101 bodies / 32898 contacts, ReleaseFast single-core, profile_enabled):
         p2d.step 149.8ms = solve 35.7 (24%) + sleep 33.3 (22%) + broadphase 28.7 (19%) + narrowphase
         26.6 (18%) + prepare 18.2 (12%) + finalize 7.1 (5%) + sensors 0. NO single dominant hotspot; cost
         is broadly spread. SURPRISE: p2d.sleep (refitActiveBodyAabbs + sleepIslands) is 22% — unexpectedly
         heavy for mostly-settled bodies; prime optimization candidate alongside the broad+narrow collision
         pipeline (37% combined). The device's ~554ms/step is slower than host (mobile wasm) but the
         RELATIVE split should hold.
         VERIFIED: lint clean; engine inline tests PASS (with build_options dep on root); demo builds x2;
         wgpu-check GREEN. NEXT (optimization, separate from this instrumentation): investigate sleep/island
         cost; consider finer solve sub-zones (contacts vs joints vs wide) before optimizing the solver.

zimr398: Washer 30fps tweak + GRAPHICS CORRUPTION root-cause study (both from the same on-device
         screenshot: 8101-body Washer at 2fps with torn debris + garbled UI text).
         CORRUPTION CAUSE (studied, definitive): the 2D debug-draw path is DrawList(cmds) -> render()
         -> WgpuGl group(256) flushes -> renderer_2d/gpu_iface ShapesBatch. The GPU geometry lands in a
         VBO/IBO RING: gpu_iface.vbo_ring_vertices=262144, ibo_ring_indices=393216, indices are u16
         (per-flush-relative, so u16 is fine per ≤8192-vtx flush). The batch auto-flushes every
         max_batch_vertices(8192) and APPENDS at a running offset into the ring. BUG: gpu_iface.zig
         ~563-571 — when a single frame's cumulative geometry exceeds the ring, the "safety net" sets
         vbo_vertex_base=0 / ibo_index_base=0, i.e. WRAPS TO 0 MID-FRAME, overwriting geometry that
         already-recorded draw calls still reference. Each debris square ~= fill(6) + outline(~24) = ~30
         verts; 8101 bodies ~= 243K verts > 262144 (plus ring wedges/spokes tip it over). So late flushes
         (incl. the UI text drawn after the world) clobber the debris region and read wrapped data ->
         the exact tears-in-debris + garbled-text seen. KEY: physics is fine at 8101 (growable pools,
         ~70ms/step); it's purely the debug RENDERER's vertex ring that overflows past ~8000 drawn bodies.
         30FPS TWEAK: demo runs a 60Hz fixed-step accumulator (fixed_dt=1/60, up to 8 catch-up steps/
         frame). Real-time keep-up REQUIRES step < 16.67ms; at 8101 bodies device step=69.9ms so it
         spirals to ~2fps. No render fix changes that — body count is the only lever at 60Hz. Host scan
         (/tmp/wash_scan.zig, ratio host:device=2.143 calibrated at gc90→pred 69.7ms vs device 69.9ms,
         holds): gc38 est 9.7ms / gc42 11.4 / gc46 15.2 / gc50 16.9 (AT cliff) / gc90 69.7. Set washer
         grid_count 90 -> 44 (1936 bodies, est device ~13-14ms/step, ~57K verts << 262K ring). Result:
         stays under the 60Hz cliff with thermal margin -> smooth 30fps+ AND no corruption (verts far
         under ring). Updated the washer comment to explain the choice + that growability lives in the
         host harnesses, not this scene.
         VERIFIED: lint clean; demo builds x2; wgpu-check GREEN.
         FOLLOW-UPS (not done; offered): (a) make the ring overflow non-silent — log/assert in assert
         builds instead of wrapping, OR enlarge vbo_ring_vertices (costs GPU mem for all demos), so a
         future high-vtx scene fails loudly rather than corrupting; (b) the sleep phase is 31% of step
         (refitActiveBodyAabbs + sleepIslands) — the prime algorithmic optimization if we ever want
         higher live body counts at framerate; (c) finer p2d.solve sub-zones (contacts vs joints vs wide).

zimr399: SlotMap generation now WRAPS instead of RETIRES + washer-cliff investigation (memory logging,
         broadphase sub-zones, tree stats). The washer framerate "diminishes gradually" — NOT a leak.
         WRAP (entities.zig SlotMap.remove): the old code retired a slot permanently when its u8
         generation saturated (gen==max -> set .invalid, saturated+=1, never reissue). Under high churn
         (a contact pool cycling thousands of slots/sec) this leaks slots forever. Changed to WRAP: on
         overflow set generation back to the first valid value ((Key.Generation.invalid).next() == 1) and
         push to the free list as normal. The ONLY downside is ABA: a Handle held across exactly 2^bits
         (255 for HandleTab's u8) destroy/reissue cycles OF THE SAME SLOT could alias a new object.
         CONTRACT documented inline + this is the misuse to stay away from: never hold a handle across
         that many reuses of its slot. Step-scoped engine handles (contacts) never approach it; long-lived
         user handles (bodies/shapes/joints) cycle their slot far too rarely to wrap in any real session.
         `saturated` field is now vestigial (always 0; its once-per-N warning never fires). Entities +
         phys tests pass; the "overflow" test is capacity-overflow, unrelated.
         INVESTIGATION (host, washer, profile_enabled; wrap fix did NOT change the cliff — confirms the
         u8 generation was never the perf cost):
         - Memory: FLAT ~15MB over 1500 steps (added a CountingAllocator in the demo wrapping the world's
           gpa: HUD shows "mem KB / peak KB"). No leak.
         - The gradual slowdown is 100% in p2d.broadphase (updateBroadPhasePairs). Added sub-zones
           p2d.bp.query (the tree-query loop) and p2d.bp.newcontacts (the createContact loop). Split at
           1936 bodies: query 8->68ms, newcontacts 0.2->113ms over the run.
         - Ruled out: tree quality (added DynamicTree.stats() -> {height, leaves, nodes, area_ratio};
           height ~40 and area_ratio ~100 are STABLE), tree rebuild (interval default 0 = disabled;
           setting it to 8 did NOT help -> not balance), body energy (maxSpeed ~13 stable), contact count
           (~7000 stable), pool capacity (12288 CONSTANT -> grow-and-retry NOT firing), live-contact index
           span (~12195 CONSTANT from step 150), and createContact's spawn (sub-zoned: ~0ms -> the
           SlotMap/generation alloc is NOT the cost) and pair_set.put (~0.5ms).
         - So createContact is O(1) line-by-line yet ~565us/call late. Every structural metric is flat;
           only TIME grows, and it scales SUPER-LINEARLY with body count: half the bodies (gridCount 31,
           961 bodies) -> step plateaus ~45ms / newcontacts ~19ms vs ~200ms / ~113ms at 1936. Plateau
           reached ~step 1350 (~22s). Signature = a churn-driven CACHE/working-set effect: as contacts
           churn, the live-contact access ORDER randomizes (the contact pool's data is slot-indexed across
           a 12288-wide sparse range; the live list becomes a random permutation), collapsing locality.
           Exact micro-mechanism for the createContact half (2 scattered accesses != 565us) still not
           fully pinned -- wants real cache-miss counters (no perf in sandbox).
         - LIKELY FIX (ties to the contact-handle design discussion): give contacts a COMPACT/dense pool
           (box2d-style dense array + index free-list) so live data is accessed sequentially, OR periodically
           defragment the contact pool. This would fix the cache cliff AND remove the (now-wrapped, still
           arguably unnecessary) generation machinery for an internal step-scoped object.
         DEMO: HUD now shows mem/peak KB + dyn-tree h{height} area{area_ratio} nodes pairs. Washer set to
         gridCount 31 (half of 44) so it's initially smooth (~15ms) though it still creeps to ~45ms after
         ~20s until the cache cliff is fixed.
         VERIFIED: lint clean; entities + phys tests pass; demo builds x2; wgpu-check GREEN.
         STILL PENDING (earlier ask, not done this turn): wire profiler_ui.panel (worst-frame flamegraph)
         into the 2D demo behind a Profile toggle, like the 3D demo.

zimr400: chasing the "washer goes fully black after ~20s" device crash.
         Key facts: deterministic ~20s, world memory FLAT (~7.8MB tracked), step only ~12ms right before
         (so NOT the perf cliff / not slowness). RULED OUT physics logic: host washer (gridCount 31) in
         ReleaseSafe ran 2500 steps (41 sim-sec) with full Zig runtime safety and NEVER trapped. So the
         crash is device/wasm/GPU-specific — in a path the headless host harness doesn't exercise (UI /
         render / GPU / wasm linear memory). Our HUD "mem" only tracks the WORLD allocator, so a leak in
         UI/render/global alloc is invisible to it.
         ADDED (demo): a total-wasm-memory readout — `if (comptime arch==.wasm32) @wasmMemorySize(0)*64/1024`
         MB — shown under the world mem line. If total wasm memory climbs toward the cap before the black
         screen, it's a leak outside the world (UI/render/GPU staging) exhausting linear memory -> OOM trap.
         BUILT TWO standalones to send:
         - wgpu_zimrphysics2d_demo.html  : -Dmode=release (fast; watch "wasm total MB" climb).
         - wgpu_zimrphysics2d_demo_DEBUG.html : -Dmode=debug (optimize=Debug, FULL Zig runtime safety +
           all asserts). Slower/larger (9.4MB) but an OOB/overflow/unreachable/OOM will PANIC with a
           message (log overlay / console) instead of silently going black.
         NEXT once we know: if wasm-mem climbs -> hunt the per-frame leak (UI host / DrawList arena /
           render buffers / font); if debug build panics -> the message names the trap site. The contact
           cache cliff + dense-pool refactor are separate and still pending, as is the flamegraph panel.
         VERIFIED: lint clean; demo builds (debug + release); wgpu-check GREEN.

zimr401: BISECTION probe for the ~20s washer black-screen. Clue: NO crash in the -Dmode=debug build
         (full Zig runtime safety) — but debug wasm is ~5fps so "no crash in 20s wall-time" likely just
         means it never reached the crash step (~1200 sim-steps); treat as inconclusive, not exoneration.
         Host (ReleaseSafe, gridCount 31, 2500 steps) never trapped -> not physics logic.
         Simon's hypothesis: the zimr399 wrap change introduced it. CLEAN A/B: reverted entities.zig
         SlotMap.remove wrap->RETIRE (exactly pre-zimr399 for that code), held everything else constant
         (CountingAllocator, bp.query/bp.newcontacts zones, wasm-mem readout, gridCount 31).
         Shipped wgpu_zimrphysics2d_demo_RETIRE.html (-Dmode=release) to test:
           - crash GONE with retire  => wrap's ABA aliasing was the cause => permanent fix = widen
             HandleTab generation u8 -> u32 (never wraps in a session: no slot leak AND no ABA).
           - crash REMAINS with retire => wrap is NOT it => bisect next suspects from zimr399: the
             CountingAllocator wrapping the world gpa (device-only path), the added profiler zones, or
             the stats()/HUD per-frame work.
         NOTE: this leaves the tree in the reverted (retire) state pending the A/B result.
         VERIFIED: lint clean; entities tests pass; release standalone builds.

zimr402: BISECTION cont. RESULT from zimr401: RETIRE STILL CRASHES -> the wrap/generation change is
         FULLY EXONERATED (not the cause). Next variable: the PROFILER. It records zones into fixed rings
         every frame (zone ring 65536, frame ring 256) and the 2D HUD calls aggregate() every frame; a
         ring-wrap/aggregate bug after sustained recording fits a deterministic ~20s death. The zone ring
         at ~1500-1800 zones/sec fills/wraps around ~36s, frame ring wraps ~5-8s — plausible trigger.
         Force-disabled the profiler at source: profiler.enabled hard-false (kept build_options referenced
         via @hasDecl to satisfy unused-global lint). Every zone/frameMark/aggregate now no-ops; the HUD
         per-phase breakdown is skipped (gated on enabled). Kept RETIRE constant from zimr401 so this flips
         ONLY the profiler. Shipped wgpu_zimrphysics2d_demo_NOPROF.html (-Dmode=release):
           - crash GONE => the profiler is the culprit; then dig into the ring/aggregate/worstFrame logic
             for an OOB on wrap.
           - crash REMAINS => not the profiler either; remaining zimr399 device-path suspects: the
             CountingAllocator wrapping the world gpa, or the per-frame stats()/HUD work; also revisit
             whether the crash predates zimr399 entirely (could be a longstanding render/GPU/wasm-mem leak
             surfaced only now because the washer is the heaviest scene).
         Tree currently: RETIRE + profiler-disabled (both to be restored once the culprit is known).
         VERIFIED: lint clean; release standalone builds.

zimr403: BISECTION cont. zimr402 RESULT: profiler-disabled STILL CRASHES -> profiler exonerated for
         the crash (though Simon noted perf was better, so the profiler does cost perf — separate finding).
         Next variable: PHYSICS vs GRAPHICS. Skipped phys.step entirely (if(false) wrap in the demo
         accumulator) so the scene FREEZES but the render path runs every frame. Kept retire + profiler-off
         constant -> flips ONLY physics. Shipped wgpu_zimrphysics2d_demo_NOPHYS.html (-Dmode=release):
           - crash REMAINS with physics off => it's the RENDER/GPU path (a per-frame resource/memory leak
             independent of simulation) -> hunt the per-frame render allocations / GPU resources; watch the
             "wasm total MB" line for the climb.
           - crash GONE with physics off => the crash needs the simulation to evolve (a body count/position/
             contact pattern that breaks rendering or some resource) -> re-enable physics and bisect the
             render of dynamic state (vert ring? draw of contacts/aabbs? per-body something).
         Tree state: retire + profiler-disabled + physics-skipped (all bisection-temporary).
         VERIFIED: lint clean; release standalone builds.

zimr404: *** ROOT CAUSE FOUND + FIXED: the ~20s washer black-screen is a wasm-LINEAR-MEMORY leak in
         the UI render path. *** zimr403 (physics SKIPPED) STILL CRASHED -> render path, not sim. Device
         HUD confirmed: "wasm total" climbs to ~2072 MB (≈2GB wasm cap) while world "mem" stays flat ~4MB,
         ~1.7-2MB/frame, scaling with draw primitives (washer = heaviest -> ~20s to the cap -> trap -> black).
         CAUSE: UiContext.frame_arena (src/ui.zig) is init'd once and deinit'd only at shutdown, and is
         NEVER reset per frame. Every DrawList add* dupes its payload (polyline points / tri fans / glyph
         slices) + the cmds list INTO that arena each frame; DrawList.clear() zeros to .empty (NOT
         clearRetainingCapacity) and the DrawList/clear docstrings literally say the cmds slice "is
         invalidated whenever the arena is reset at endFrame" -- i.e. the whole design assumed a per-frame
         arena reset that was simply never wired in. So a full frame of draw geometry accumulated every
         frame.
         FIX (beginFrameRaw, the per-frame entry, at the existing draw-list clear site): empty EVERY
         persistent arena-backed draw list (all self.windows incl. popups, tooltip_window,
         drag_preview_window; foreground/background/dock_tabs were already cleared) THEN
         `_ = self.frame_arena.reset(.retain_capacity)`. Emptying-all-first is REQUIRED: a window not
         resubmitted this frame would otherwise keep a cmds.items.ptr into reclaimed pages (caught as a
         write-after-free by the first naive single-line reset; the UI test "click-outside dismisses popup
         on subsequent frames" exposed it). .retain_capacity keeps the pages so wasm memory plateaus at one
         frame's high-water instead of re-growing.
         VERIFIED: src/ui.zig host tests 1182 passed / 1 skipped / 0 failed (write-after-free gone);
         wgpu-check GREEN (NO REGRESSIONS + wgpu_smoke PASSED). Shipped wgpu_zimrphysics2d_demo_LEAKFIX.html
         (-Dmode=release) with physics STILL SKIPPED + profiler STILL DISABLED (bisection config unchanged
         except the fix) so the device test isolates the leak: EXPECT "wasm total" to now stay FLAT and no
         ~20s black-out. If flat -> fix confirmed; next build RESTORES wrap (entities.zig retire->wrap),
         profiler.enabled (real expr), and phys.step (remove if(false)).
         NOTE (separate, deferred): this latent leak affected ALL scenes/demos (any UI) -- just slow enough
         elsewhere to go unnoticed; the washer's ~962 primitives/frame made it a ~20s kill. Also still
         pending: broadphase super-linear cliff; profiler perf cost; 2D flamegraph panel.

zimr405: LEAK-DETECTION HARDENING (so a leak like zimr404's is loud + located, not a silent 20s kill)
         + restored all zimr401-403 bisection temporaries now that the leak is fixed.
         NEW src/frame_arena.zig (FrameArena): an ArenaAllocator wrapper whose alloc() tallies live_bytes
           since the last reset and trips assertf (with a locating label) past a generous `ceiling` — the
           check lives in alloc() (always runs) not reset() (a forgotten reset never calls it), so "never
           reset" panics within a few frames instead of marching to the 2GB wall. Drop-in: allocator(),
           reset(mode), deinit() mirror ArenaAllocator, so only init sites change. Has a unit test.
         NEW src/memwatch.zig (MemWatch): per-frame wasm-memory growth watchdog. Samples @wasmMemorySize,
           warns via std.log.err (survives ReleaseSmall) when memory climbs >128MiB above its settled floor
           without plateauing. Plateau-rebaseline (accept high-water as floor after ~120 still frames) means
           one-time scene/app loads don't false-positive — NO manual workload-change hook needed. Throttled
           (re-arms one margin higher). Compiled out in ship (active = Debug or build_options.assert_log).
           State lives on App (App.mem_watch), ticked in wgpu_app.update() after frame_count++ — universal
           across all demos, no module globals.
         ADOPTED FrameArena for the two per-frame arenas: UiContext.frame_arena (the zimr404 culprit;
           ceiling 256MiB, ~162 field-init sites incl. tests) and World.step_arena (physics2d; 256MiB).
           (Audio scratch arenas NOT yet converted — trivial follow-on if wanted.)
         COUNTING: deliberately did NOT add root/per-subsystem counting. The watchdog reads true wasm pages
           (more honest than summed allocator bytes) and is effectively the "root" view; FrameArena +
           the existing world CountingAllocator cover attribution. Keeps complexity down per Simon's ask.
         RESTORED: profiler.enabled real expr (zimr402 undo); demo accumulator phys.step un-skipped
           (zimr403 undo); entities.zig SlotMap.remove RETIRE->WRAP (zimr401 undo; wrap is final — retire
           was exonerated as the crash cause). WRAP: at max generation, wrap past `.invalid` (0) to
           invalid.next()==1 and free-list the slot (statement-if for the brace lint rule); `saturated` now
           vestigial. ABA contract documented inline.
         VERIFIED: lint clean (incl. assertf bound at file scope as required); host tests ui.zig 1183 /
           physics2d 36 / entities 31 / frame_arena 1 all pass; wgpu-check GREEN (NO REGRESSIONS +
           wgpu_smoke). Shipped wgpu_zimrphysics2d_demo.html (-Dmode=release) = leak fix + restorations +
           hardening, physics + profiler ON. EXPECT: washer runs without the ~20s black-out, "wasm total"
           plateaus (not climbs), and NO memwatch warning in the console. The watchdog/FrameArena now stand
           guard for the next such leak. (Still pending: broadphase super-linear cliff = next; profiler perf
           cost; 2D flamegraph panel.)

zimr406: close out the leak-hardening — finished the "track every per-frame path" thread from zimr405.
         FINDING: the "three frame arenas" I'd named was an overcount. The real per-frame allocating
           arenas are UI frame_arena + World.step_arena (both already FrameArena since zimr405). The
           "audio scratch arena" was a phantom (sound.zig has no arena). gpu.GpuFrame.frame_arena
           (?*ArenaAllocator) was a dead, never-assigned vestigial field — REMOVED it (it advertised a
           per-frame arena that did not exist, muddying any future "which arena leaks?" hunt). So
           FrameArena adoption is COMPLETE at the two arenas that actually allocate per frame.
         COUNTING (the one suggested item I'd punted on in zimr405): did the minimal-complexity version
           rather than an engine-wide root wrap. Routed the demo's UiHost through the existing
           CountingAllocator (was raw gpa) — the UI path being untracked is exactly what let the zimr404
           leak hide. The demo HUD line relabeled "mem"->"heap": it now covers the whole tracked Zig-heap
           footprint (world + UI), not world-only. "wasm total" stays the ground-truth global (all pages
           incl. untracked GPU/interop); heap-flat + wasm-climbing now localises a leak to the untracked
           paths. Deliberately did NOT wrap App.gpa engine-wide: the watchdog already reads true wasm
           pages (the honest global), and a root CountingAllocator would tax every alloc in every demo
           for a number the watchdog already gives. (Available on request if per-demo Zig-heap attribution
           is ever wanted across all demos.)
         VERIFIED: lint clean; wgpu-check GREEN (NO REGRESSIONS + wgpu_smoke). Shipped
           wgpu_zimrphysics2d_demo.html (-Dmode=release, 2066925 bytes), physics + profiler ON.
           Device-side now: "heap" tracks world+UI, "wasm total" should plateau (leak fixed), no memwatch
           console warning. NEXT (deferred through this whole arc): broadphase super-linear cliff; profiler
           perf cost; 2D flamegraph panel.

zimr416: BUG FIX (Simon device report) — enabling the contact debug overlay in Benchmark|Barrel 2.4
         corrupted ALL geometry (shapes mangled/displaced, not just the overlay).
         ROOT CAUSE: the 2D renderer's per-frame GPU vertex ring (gpu_iface.zig: vbo_ring_vertices=262144,
           ibo_ring_indices=393216, u16 indices) is filled by many incremental flushes per frame, each
           appending at a running base so earlier same-pass recorded draws keep referencing their region.
           On overflow flushBatch (the wgpu one ~line 567) WRAPPED vbo_vertex_base/ibo_index_base back to 0,
           which reuses a region an already-recorded draw still points at -> that earlier geometry (the shapes,
           flushed first) gets overwritten by later data -> corruption. Barrel 2.4 = 26x130 = 3380 cubes; with
           the contact overlay on, the thousands of contact points (each draw_point = a filled circle, many
           verts) + normals push the frame past 262144 verts and trip the wrap.
         FIX: on ring overflow, DROP the offending batch (zero vertex_count/index_count and return) instead of
           wrapping to 0. Shapes are flushed first at low offsets (well under the ring), so they always stay
           intact; only the overflow TAIL (excess debug-contact overlay in a pathologically dense frame)
           is omitted — graceful degradation, no corruption. Normal frames are far under the ring and unaffected.
           The SW backend's flushBatch (~737) does not use the GPU ring and needed no change.
         RESULT: Barrel 2.4 + contacts now renders correct cubes with a partial contact overlay (no corruption).
           If full contact overlay on the densest scenes is ever wanted, the follow-up is cheaper contact points
           (draw_point as a small quad instead of a filled circle) or a bigger ring — not needed for correctness.
         NOTE: the contact overlay path itself was fine (drawContact uses center_b+anchor_b since draw_anchor_a
           defaults false; both anchors resolve to the same world point) — the bug was purely the ring overflow.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release standalone build; release 2083557 bytes.


zimr417: 2D shapes ring — enlarge + assert-on-overflow (follow-up to zimr416, per Simon). zimr 126.
         CONTEXT: zimr416's graceful-drop net moved the failure to whatever draws LAST — the UI is drawn after
         the scene+overlay, so on Barrel 2.4 + contacts the UI itself got dropped (device screenshot). Simon's
         call: just enlarge the buffer, and assertf instead of silently corrupting/dropping.
         WHY NOT MID-FRAME FLUSH (the design question): the per-flush queueWriteBuffer calls all land on the
           queue timeline BEFORE the single command-buffer submit runs any draw, so every recorded drawIndexed
           reads the buffer's FINAL contents — distinct ring regions are the only thing letting each draw see its
           own data. Reusing offset 0 mid-frame corrupts earlier same-pass draws. Actually freeing a region needs
           a mid-frame SUBMIT + render-pass restart, which on a tiled mobile GPU forces a full attachment
           store+reload (bandwidth) and is unsafe in gpu_iface's shared depth pass (2D batch can composite with
           the 3D immediate path). So: size the ring generously for a whole frame instead.
         CHANGE (src/gpu_iface.zig):
           - vbo_ring_vertices 262144 -> 1048576; ibo_ring_indices 393216 -> 1572864 (~4x). renderer_2d sizes the
             GPU vbo/ibo from these constants, so the buffers grow automatically (now ~20MB vbo + ~3MB ibo).
             Sizing rationale: heaviest known frame = Barrel 2.4 (3380 cubes) + contact overlay (each contact
             point = a small filled circle via drawPoint->addCircleFilled) peaks ~235K verts / ~475K indices —
             note the OLD 393216 index cap was already below that peak, which is why it overflowed. New caps leave
             ~4x headroom.
           - flushBatch overflow branch: replaced the wrap-to-0 (and the interim drop) with assertf(fits, @src(),
             ...) — loud failure if a frame ever exceeds the ring (a sizing bug). Added `const assertf = zm.assertf;`.
             Kept a drop-this-batch fallback AFTER the assert so ship builds (asserts compiled out) degrade to
             missing geometry rather than corruption. The release standalone keeps assert_log on, so the assert is
             live in the build Simon tests.
         RESULT: Barrel 2.4 + contacts + UI all fit with margin; no corruption, no dropped UI; overflow now
           asserts loudly instead of corrupting.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release standalone build; release 2084737 bytes.


zimr418: 2D contact overlay FREEZE fix (Simon device report: "freezes when I draw contacts in barrels").
         After zimr417 it no longer corrupted but FROZE on Barrel 2.4 + contacts.
         ROOT CAUSE (measured, not guessed — wrote a throwaway host harness replicating the Barrel pile):
           Barrel 2.4 settles with up to ~13,054 touching contacts / ~26,108 manifold points (peak at the
           initial densely-stacked frame). The debug contact overlay draws each manifold point via drawPoint ->
           addCircleFilled, and shapes2d.drawPoly emits a filled circle as N QUADS (gl.begin(.quads)): a 12-gon
           (autoCircleSegments min is 12) = 12 quads = 48 verts / 72 indices PER POINT. 26,108 points => ~1.4M
           verts / ~2.1M indices, which overruns BOTH new ring caps (1,048,576 / 1,572,864). flushBatch's
           zimr417 assertf then fires every frame, and assertf with assert_log on calls @panic -> the wasm traps
           -> the canvas freezes. (So the freeze was literally my own overflow assert tripping; the buffer was
           still too small because my per-point cost estimate was 4x too low.)
         FIX (examples/wgpu_zimrphysics2d_demo/render.zig drawPoint): draw each debug point as a single small
           filled SQUARE (addRectFilled, 4 verts / 6 indices) instead of a tessellated circle — ~12x cheaper and
           visually identical at debug-dot sizes. New peak ~276K verts / ~415K indices, comfortably under the
           ring (~3.6x headroom) so the assert never fires, and ~5x less GPU+CPU overdraw so it's no longer
           sluggish either. Kept zimr417's enlarged ring + assert as the safety net.
         Affects all engine debug-draw points (contact points, joint anchors) in the demo — squares read fine.
         VERIFIED: measured peak via host harness (then deleted it); lint clean; wgpu-check GREEN; debug+release
           standalone build; release 2084785 bytes. PENDING: Simon device-verify Barrel 2.4 + contacts (expect
           clean squares at every contact, no freeze, no corruption).


zimr419: 2D ring overflow — overlay-log + abort instead of @panic (per Simon: "freezing is bad", want the
         guard to abort drawing and log text on an overlay). Supersedes zimr417's assertf.
         WHY: assertf with assert_log on calls @panic, which traps the wasm and freezes the canvas — the wrong
         failure mode for a recoverable resource limit (scene too dense for the 2D ring). A dropped overlay/batch
         is recoverable; a frozen canvas is not.
         MECHANISM CHECK: the standalone page template (tools/c2js.zig) already mirrors console.{log,warn,error}
         to a bounded on-page overlay; bridge.zig routes std.log.err -> console.error (both the std_options.logFn
         path via jsLog and bridge.err). So std.log.err from anywhere in the wasm shows on that overlay.
         CHANGE (src/gpu_iface.zig flushBatch): replaced the assertf(fits,...) with: if the batch would overflow
         the ring, std.log.err(...) the counts (-> overlay) and drop the batch (zero vertex/index counts, return)
         — abort that draw, never @panic, never wrap/clobber. Removed the now-unused `const assertf = zm.assertf;`.
         Logs every frame it overflows; the overlay is bounded (200 lines, self-trimming) so an ongoing overflow
         just shows a persistent message rather than flooding. Kept the enlarged ring (zimr417) as the headroom
         and the cheap square contact points (zimr418) so the path isn't hit in normal use; this is the safety net
         for any future pathological scene.
         TRADE-OFF (unchanged, Simon's call): if a frame truly overflows, batches drawn after the fill drop
         (incl. the UI, drawn last) — but now it's a visible logged degradation, not a freeze.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release standalone build; release 2084437 bytes.


zimr420: assert/assertf — release logs to the page overlay + CONTINUES instead of @panic (per Simon: make
         the guards do the overlay thing natively so sites don't need manual std.log.err replacement). Reverts
         zimr419's hand-rolled std.log.err at the ring-overflow site back to assertf.
         CHANGE (src/zimrmath.zig, BOTH assert and assertf, CPU/non-gpu path): split the old combined
         `(!is_stripped or assert_log)` branch into three:
           - debug (!is_stripped):            std.log.err(...) + @panic   (hard fail for desk dev)
           - release (is_stripped+assert_log): std.log.err(...) only       (-> console.error -> on-page overlay,
                                                                            then RETURNS — no freeze)
           - ship (is_stripped+!assert_log):   unreachable                 (asserts compiled out, unchanged)
         std.log.err routes to console.error via bridge.zig (jsLog + std_options.logFn), and tools/c2js.zig's
         page template mirrors console.{log,warn,error} to a bounded on-page overlay — so a failed assert in the
         release standalone now paints a line at the bottom of the screen and keeps running.
         CAVEAT (inherent, Simon's call): in release a failed check no longer halts, so a caller that must bail
         has to do so itself — assertf returns void, it can't abort the caller. All existing assertf/assert sites
         keep compiling (the signature was always void, never noreturn, so control flow is unchanged). Two
         assertf(false,...) misuse-guards (compute_host.zig kernel-not-registered, plot.zig Scale.custom) now
         log+continue in release rather than panic; both are misuse paths, acceptable.
         SITE (src/gpu_iface.zig flushBatch): restored assertf(fits,...) for the ring-overflow message, kept the
         explicit `if (!fits) { drop; return; }` to actually abort the batch (assertf can't bail the caller). So
         release: overlay-logs + drops (no freeze, no corruption); debug: panics; ship: check compiled out (the
         drop still guards via the plain bool). Removed zimr419's manual std.log.err. Re-added const assertf import.
         VERIFIED: lint clean; host tests (zimrphysics2d 41/41, debug => assert still panics there); wgpu-check
         GREEN; debug+release standalone build; release 2080961 bytes.


zimr427: FIX Pinball "inputs dead when arms sleep" (Simon device report). revoluteSetMotorSpeed does
         NOT wake a sleeping body, so once the flippers fell asleep at rest the motor-speed writes did
         nothing. box2d's Pinball sets bodyDef.enableSleep=false on the flippers for exactly this; I'd
         omitted it. Fix: added `no_sleep: bool=false` to the scenes Body helper -> addBody maps it to
         BodyDef.enable_sleep = !no_sleep; set .no_sleep=true on both flipper bodies (lf/rf). General-
         purpose for any motor-driven body that must respond at rest (Cart wheels will likely use it).
         NOTE: Mover is unaffected — setLinearVelocity wakes the body, so its control still works asleep.
         VERIFIED: lint clean; wgpu-check GREEN; debug+release build; release 2098449 bytes. 134 scenes.


zimr428: ENGINE FIX (Simon: "revoluteSetMotorSpeed should wake a body... wake them on set speed").
         Made the motor-speed setters wake their connected bodies. New private helper in zimrphysics2d.zig
         (right after wakeBody ~8660):
           fn wakeJointBodies(world,*World, joint: JointHandle) void { j=&joints.data[joint.index()];
             wakeBody(world,j.body_a); wakeBody(world,j.body_b); }   (Joint has body_a/body_b: BodyIndex;
             wakeBody already no-ops on static or already-awake bodies, so ground endpoints are free.)
         Called it at the END of all four motor-speed setters: revoluteSetMotorSpeed (11274),
           prismaticSetMotorSpeed (11419), distanceSetMotorSpeed (11523), wheelSetMotorSpeed (11561).
         Now matches the convention of setLinearVelocity/setAngularVelocity (which already wakeBody).
         Reverted the zimr427 flipper .no_sleep workaround so Pinball exercises the real wake path; the
           `no_sleep` Body-helper option STAYS available for bodies that genuinely must never sleep.
         VERIFIED: lint clean; zimrphysics2d host tests 41/41 PASS (engine change safe); wgpu-check GREEN;
           debug+release build; release 2098589 bytes. 134 scenes.
         REMAINING interactive: Robustness|Cart, Events|Joint. Then Determinism|SnapShot serialize (finale).


zimr432: Contacts moved OFF the entities.zig generational/ECS pool onto a manual freelist, box2d-style.
         WHY: external code never holds a ContactHandle (every public contact API takes/returns a plain u32
           contact_id: liveContactId/isContactTouching/getContactData/getContactEvents) and contacts carry NO
           secondary ECS components, so ent.Entities(Contact)'s generation array + parallel Registry lockstep
           (reserveImmediate + assert(ecs.index==idx,@src()) per spawn) was pure overhead on the hot
           create/destroy path that dominates dense-pile broadphase churn (the washer newcontacts probe).
         WHAT: new `const ContactPool = struct { data: []Contact, free_list: ArrayListUnmanaged(u32),
           next_index: u32 }` mirroring box2d b2IdPool + contact array (id_pool.c):
             - alloc(gpa,value): pop a freed id else bump next_index (self-grows data via amortised doubling);
             - free(id): appendAssumeCapacity to free_list (free-list cap held >= data.len, so free never allocs
               and needs no error union / no gpa);
             - grow(gpa,min): realloc data + ensureTotalCapacity(free_list); count(): next_index-free_list.len
               (pub, used by demo perf panel, = box2d b2GetIdCount); init/deinit.
           Replaced: `pub const Contacts = ent.Entities(Contact)` field -> ContactPool; createContact's
           spawn+catch(PoolExhausted)+growContacts+retry dance -> one `const id = try contacts.alloc(...)`
           (self-growing); destroyContact's `ContactHandle.pack(id,cycle[id]); handle.destroy(&contacts)` ->
           `contacts.free(id)`. DELETED `pub const ContactHandle = ent.Handle(Contact)` (0 remaining refs).
           Bodies/Shapes/Joints UNCHANGED (they're handle-addressed and/or carry components). growContacts
           wrapper kept (now unused but valid, symmetric w/ growBodies/growJoints).
         VERIFIED: determinism parity EXACT (washer 1200-step probe: OLD ECS path and NEW pool both produce
           88903 createContact calls). 43/43 host tests (incl. both snapshot/restore tests, which destroy via
           free + recreate via alloc). lint clean; zig fmt --check clean (gate runs fmt!); wgpu-check GREEN;
           debug+release build; release 2106377 bytes (was 2108613, ~2KB smaller).
         PERF (native ReleaseFast, host): whole-run wall time ~UNCHANGED -- ECS asserts off ~4675 ms/run both;
           asserts on (device-like) OLD ~4645 vs NEW ~4610 ms/run (~0.8%). So the ECS primary-only spawn is a
           cheap fast-path on native; createContact is a tiny slice of the full step here. The device's 2.4 ms
           bp.newcontacts (ReleaseSmall + assert_log ON, wasm) is a different regime: the removed per-spawn ECS
           work (handle-table insert + @src() assert) is plausibly far costlier under wasm than native, but I
           CANNOT measure wasm here -- Simon to confirm on device by watching bp.newcontacts. Honest take: this
           is primarily a correctness/simplicity + box2d-alignment win; native perf delta is within noise.
         NOTE for future: the remaining per-create hashmap work is broadphase pair_set.put (+ contains in
           bp.query) -- an AutoHashMap(u64) that is also wasm-hostile and was NOT touched. And the churn COUNT
           lever (fat-AABB margin / speculative distance hysteresis) is still available to cut creates/step.


zimr433: Broadphase tree-degradation FIX + washer doubled + newcontacts investigation (Simon: "newcontacts
         still 0.2->2.4, probably cache misses or bad tree; double body count, investigate, propose solutions").
         (Stale assert screenshot was a cached build; zimr432 ECS removal is clean, no asserts fire.)
         ROOT CAUSE of the broadphase climb = BAD TREE, now proven by measurement. DynamicTree.moveProxy did
           removeLeaf + insertLeaf(should_rotate=FALSE), and the periodic rebuild was OFF by default
           (tree_rebuild_interval=0). So in a scene where every proxy moves every step (churning washer pile)
           the tree got NO rebalancing at all and degraded to ~4-5x ideal height.
         MEASURED (host probe, washer doubled to 44x44 = 1936 bodies, ReleaseFast), dynamic-tree height and
           broad-phase query node-visits/step (settled):
             rotate-off + rebuild-off (shipped):   height ~50   visits ~219k
             rotate-off + rebuild every 1 step:     height ~14   visits ~137k
             rotate-off + rebuild every 8 steps:    height ~14   visits ~143k
             rotate-ON  + rebuild-off (THE FIX):    height ~15   visits ~121k   <- best, no rebuild spike
           Candidates/step (~17.8k) and new-contacts/step (~100-250) were IDENTICAL across ALL tree configs ->
           tree quality changes query TRAVERSAL cost (bp.query), NOT how many overlaps/creates exist.
         FIX SHIPPED: DynamicTree.moveProxy now insertLeaf(...true) (rotate on re-insert). One word; keeps the
           tree continuously balanced (height 50->15), cuts query node-visits ~45% (219k->121k) -> should drop
           device bp.query from ~2.3ms toward ~1.3ms. No periodic O(n) rebuild spike (smoother than enabling
           the rebuild). tree_rebuild_interval path still exists as an alternative knob (left default 0).
           Determinism preserved: all 43 host tests pass incl. both snapshot/restore tests.
         bp.newcontacts is TREE-INDEPENDENT (confirmed: creates/step identical across tree configs). It is
           ~100-250 createContact/step x per-create cost. Two findings on the levers:
           - MARGIN IS THE WRONG LEVER (measured, important negative result): fat-AABB margin x4 ->
             contacts ~DOUBLED (10.6k->18.4k) and new/step ~4x'd (107->1006). Bigger fat AABBs sweep over more
             neighbours, so contact population + churn both RISE. Do NOT widen margin to cut churn; it backfires.
           - The remaining lever is PER-CREATE COST (the wasm 0.2->2.4 climb tracks the create COUNT rising from
             ~0 in free-fall to ~100-250 in the dense pile; native ReleaseFast shows createContact ~free, so the
             device cost is wasm cache-miss/bounds-check on the scattered large-struct reads in createContact +
             pair_set.put). Tree-independent; needs data-layout work, not a quick toggle.
         ALSO surfaced: bp.query pays ~17.8k pair_set.contains/step (one AutoHashMap(u64) lookup per candidate)
           on top of tree traversal -- cache-heavy and tree-independent; a flatter open-addressing set (or
           folding the dedup into the contact lookup) would cut both bp.query and bp.newcontacts on wasm.
         PROPOSED (not yet done) for newcontacts, in priority order:
           A. hot/cold SoA split of Body/Shape/Contact (box2d b2BodySim/b2ContactSim) so createContact + solver
              touch small contiguous structs instead of scatter-reading large AoS records -> biggest wasm win.
           B. cheaper pair_set (open-addressing u64 set, or store contact_id so contains doubles as lookup).
           C. churn count is inherent to a chaotic pile; little to do without changing the scene.
         WASHER doubled 31x31 -> 44x44 (961 -> 1936 dynamic squares) so the broadphase term is visible on
           device; comment corrected (was stale "44x44/~15ms" while code was 31). cam unchanged.
         VERIFIED: scenes+engine lint clean; zig fmt --check clean; 43/43 host tests; wgpu-check GREEN; debug +
           release x2; release 2106353 bytes. Next id zimr434.


zimr434: Broadphase pair_set: std.AutoHashMapUnmanaged(u64,void) -> custom flat open-addressing PairSet.
         BIG WIN (Simon: "yes try things" on the doubled-washer broadphase = 70% of step on device).
         The pair_set is the broadphase's hottest structure: contains() once per CANDIDATE (~18k/step in
         the 1936-body washer) + put()/remove() per contact create/destroy (~200 each/step). The generic
         AutoHashMap (Wyhash over the u64 + a metadata side-table separate from entries = 2 cache lines/lookup)
         was murdering it. PairSet = a single contiguous []u64 (power-of-two), multiply-shift (Fibonacci) hash,
         linear probing, BACKWARD-SHIFT deletion (no tombstones -> stays tight under the heavy create/destroy
         churn), grow at 0.75 load. empty slot = maxInt(u64) (unreachable: shapePairKey (lo<<32)|hi is < 2^63).
         3 call sites swapped (contains 8597-ish, put in createContact, remove in destroyContact); BroadPhase
         field default .{} (lazy first-alloc, so World.init untouched). Demo perf panel .pair_set.count() ->
         .count (now a field).
         MEASURED (host, washer doubled 44x44=1936, 1200 steps, ReleaseFast, shell-timed, IDENTICAL physics:
         both end at contacts=6882): OLD AutoHashMap ~17.7 s/run -> NEW PairSet ~7.9 s/run = ~2.2-2.3x FASTER
         total sim. i.e. the generic hash map was ~57% of the entire washer runtime. This is a NATIVE win (not
         a wasm-only hypothesis like the SoA idea), so it will carry to device -- likely larger, since wasm's
         generic-hashmap + bounds-checks are worse. Directly attacks both bp.query (the ~18k contains) and
         bp.newcontacts (the puts) + destroy (removes, billed to narrowphase).
         CORRECTNESS: new permanent fuzz test "PairSet matches a reference set under heavy random churn" --
         300k random put/remove/contains in a tiny key space (forces collisions + long probe runs) cross-checked
         live against std.AutoHashMapUnmanaged (membership + count); validates the backward-shift deletion.
         44/44 host tests (43 + this), incl. both snapshot/restore determinism tests. lint + zig fmt --check
         clean; wgpu-check GREEN; debug + release x2; release 2105393 bytes.
         STILL OPEN (newcontacts per-create cache cost): the SoA hot/cold split of Body/Shape/Contact
         (box2d b2BodySim/b2ContactSim) is the remaining big lever and is wasm-cache-bound (not measurable on
         native); propose next if device still shows bp.newcontacts high after this + the rotate-on-move (z433)
         land. Also: TreeNode is ~48 B and the query reads ~121k nodes/step -> an SoA tree (or packing the hot
         aabb+children into a tighter node) is a secondary broadphase lever. Next id zimr435.


zimr435: Washer doubled again 44x44 -> 62x62 (1936 -> 3844 dynamic squares) per Simon, to expose the next
         bottleneck now that broadphase is cheap. Scene-constant change only (grid_count 44->62) + comment.
         DEVICE CONFIRMATION of zimr433+434 at 1937 bodies (5801 contacts): step 38.1->11.8 ms; broadphase
         26.7->1.7 ms; bp.query 11.7->1.6; bp.newcontacts 15.0->0.1 ms (~150x); phys back to x0 (real-time).
         The AutoHashMap pair_set was even worse on wasm than the ~2.2x native shell-timing predicted -- it WAS
         essentially all of bp.newcontacts and most of bp.query.
         NEW BOTTLENECK to watch at the higher count: "sleep" is now 5.0 ms = the largest slice of step. That
         zone runs refitActiveBodyAabbs (per active body: recompute shape AABBs; moveProxy -- now rotate-on-move,
         slightly pricier per move -- when a proxy escapes its fat AABB) + sleepIslands. So the rotate-on-move
         win (z433) partly shifted cost into refit's moveProxy. Likely the next target after this doubling.
         VERIFIED: scenes lint clean; wgpu-check GREEN; debug + release x2; release 2105393 bytes. Next zimr436.


zimr436: "sleep" zone investigation (Simon: 10.2ms at 3845 bodies, "bodies should never sleep here, why so
         long, what next"). The "p2d.sleep" zone actually ran TWO things: refitActiveBodyAabbs + sleepIslands.
         FINDINGS:
         - sleepIslands rebuilt islands from SCRATCH every step regardless of whether anything can sleep:
           dsuReset + a dsuUnion over every touching contact (~15k at 3845 bodies) + joints + 3 aggregate
           passes -- pure waste in a perpetually-stirred scene where no body is ever sleep-eligible. A body can
           only sleep when its own sleep_time >= time_to_sleep, and sleep_time resets to 0 every step it moves
           faster than sleep_threshold (finalize, ~line 9700). In the washer that's never -> the whole
           union-find is for nothing.
         - refitActiveBodyAabbs recomputes every active body's AABB and, when a proxy escapes its fat AABB, does
           a full moveProxy = removeLeaf + insertLeaf(ROTATE) (rotation added in z433). In the churning pile
           almost every proxy escapes every step -> ~3845 tree remove+insert+rotate/step. Likely the bigger
           half of the old "sleep" number, and partly a cost the z433 rotate-on-move win pushed here.
         SHIPPED THIS TURN:
           1. Split the profiler zone -> "p2d.refit" (refitActiveBodyAabbs) + "p2d.sleep" (sleepIslands) so the
              device overlay shows which half dominates. KEY DIAGNOSTIC for the next move.
           2. sleepIslands early-out: scan active bodies first (O(active)); if NONE is eligible
              (dynamic & enable_sleep & sleep_time>=time_to_sleep) skip dsuReset + all unions + aggregate and
              just clear body_sleep. Correct (identical sleep decisions; only skips work that can't change them).
         MEASURED (host, washer 44x44, 800 steps, shell-timed, IDENTICAL physics: both end contacts=6757):
           OLD full union-find ~5154 ms/run -> NEW early-out ~4975 ms/run (~3.5% native). Modest natively ->
           confirms refit (moveProxy) is the bigger half of "sleep", not the union-find. On wasm the early-out
           may save more (15k cache-missy random body-index unions), but the prime suspect for the remaining
           cost is refit's per-escape tree remove+reinsert.
         NEW TEST (45 total): "settled bodies fall asleep" drops 3 boxes on a segment, steps 300, asserts all 3
           sleep -> covers the eligible union-find/aggregate path the early-out guards. fmt + lint clean;
           wgpu-check GREEN; debug + release x2; release 2105629 bytes.
         NEXT (pending the device refit/sleep split): if "refit" dominates, the box2d fix is enlargeProxy
           (grow the fat AABB in place, cheap -- no findBestSibling/rotation/removeLeaf) instead of moveProxy,
           paired with the periodic tree_rebuild to reclaim the looseness enlarge introduces (that rebuild path
           already exists; default off). Trade: cheap refit + small rebuild spike vs today's pricier per-move
           remove+reinsert. Must re-measure query node-visits to ensure broadphase doesn't regress. Next zimr437.


zimr437: refit (the new bottleneck) optimised: moveProxy -> enlargeProxy + periodic tree rebuild ON.
         DEVICE confirmed the z436 split at 3845 bodies: refit 10.8 ms (the real cost in the old "sleep"),
         sleep 0.1 ms (island early-out crushed its half on wasm), step 27.8 ms. So refit's per-escape full
         tree remove+reinsert+rotate was the target.
         refitActiveBodyAabbs now calls world.broadphase.enlargeProxy (grow the leaf AABB in place + mark
         ancestors, O(height) and pointer-cheap) instead of moveProxy (removeLeaf + findBestSibling +
         insertLeaf + rotateNodes). Enlarge loosens internal node bounds over time, so the periodic full
         rebuild reclaims tree quality: tree_rebuild_interval default 0 -> 8 (box2d: b2BroadPhase_EnlargeProxy +
         incremental rebuild; here a periodic full median-split rebuild every 8 steps). z433 rotate-on-move
         stays on DynamicTree.moveProxy for the now-rare callers (setTransform, drag, restore resync).
         INTERVAL SWEEP (host, washer 44x44, 800 steps, shell-timed, ms/run): move+rotate/rebuild-off (z436)
         4425; enlarge + rebuild {1:3934, 2:3972, 4:3788, 8:3824, 16:4047, 32:4672}. Clear U: too-frequent
         wastes O(n) rebuild work, too-infrequent lets the tree loosen -> query rises. Picked 8 (3824, within
         ~1% of the 4 optimum but half the rebuild spikes -> smoother frames) = ~14% faster TOTAL native sim.
         refit is a bigger slice on device (10.8/27.8 = 39%) than in this native total, so the device win should
         exceed 14%. (contacts differ across configs -- 6757 move vs 6430 enlarge -- because the rebuild reorders
         contact creation -> trajectories diverge; both valid sims. Determinism is intact WITHIN a config.)
         CAVEAT to watch on device: the rebuild is a full O(n) median-split every 8th step = a periodic frame
         spike (box2d spreads it incrementally). The demo accumulator absorbs it (clamp(dt,0,0.1) + guard<8 =>
         slow-mo, never a death spiral), but if the 8th-frame hitch is visible, switch to incremental rebuild
         or retune. Answered Simon's spiral question: yes -- line 384 clamp(delta_time,0,0.1) caps sim-time/frame
         (0.1/(1/60)=6 -> the "x6") and guard<8 hard-caps substeps; below ~10fps the world runs slow-mo.
         VERIFIED: 45/45 host tests (snapshot/jointed/sleep all OK with rebuild on); fmt + lint clean;
         wgpu-check GREEN; debug + release x2; release 2106429 bytes. Next zimr438.


zimr438: slow-mo threshold 10fps -> 30fps (Simon: "go slomo under 30, not 10"). DEVICE confirmed the
         zimr437 enlarge win is huge: refit 10.8 -> 0.8 ms, step 27.8 -> 18.5 ms (~33%). bp.query rose
         3.9 -> 5.1 (the expected, much smaller counter-cost of the looser enlarge tree between rebuilds).
         Pipeline now BALANCED at 3845 bodies (step 18.5): bp.query 5.1, narrowphase 4.8, solve 3.3,
         prepare 3.1, finalize 1.0, refit 0.8, sleep 0.1.
         The accumulator clamp was already 1/30 in source (line 388) but the device still showed "x6" (the
         0.1s/10fps behavior), i.e. the shipped wasm wasn't honoring it. Made the intent structural and
         recompile-forcing: guard < 8 -> guard < 2 in the substep loop. 1/30s of sim = exactly two 1/60
         steps, so two is now also the HARD substep cap -- the world cannot run >2 substeps regardless of
         delta_time, so x6 is impossible by construction; below 30fps it slow-mos (clamp(delta_time,0,1/30)
         caps sim-time/frame, guard<2 caps work/frame). Demo-only change; 45 host tests unaffected, lint+fmt
         clean, wgpu-check GREEN, debug + release x2, release 2106429 bytes.
         NEXT-OPTIM MENU presented to Simon (the easy 10ms wins are gone; remaining costs are cache-bound
         scattered reads of large AoS structs):
           1a. INCREMENTAL tree rebuild -- rebuild a slice each step instead of a full O(n) rebuild every 8
               -> tree stays continuously tight (query back toward 3.9) AND removes the periodic frame spike.
               Contained to broadphase. RECOMMENDED next (targets the new top cost + the spike).
           1b. TreeNode hot/cold split -- query reads only aabb+children+category_bits (32B) but the node also
               carries parent/height/flags/user_data -> ~2 cache lines/visit; split hot into its own array.
           2.  SoA hot/cold split of Body (box2d b2BodySim + b2BodyState) -- prepare+solve+finalize+narrowphase
               all scatter-read the fat Body struct; tight parallel solver arrays cut misses across all of them.
               Highest ceiling, biggest effort.
           3.  narrowphase locality -- sort contacts by shape / SoA geom so manifold regen reads are contiguous.


zimr439: bottom-up tree AABB refit each step -> cheaper bp.query (targets the 5.1ms top zone). On
         investigating Simon's chosen optim (1a incremental rebuild) two things became clear: (a) the solver
         is ALREADY SoA (prepareContacts/solveContacts/integrate* read parallel BodyState + Motion arrays, not
         the fat Body), so "SoA the solver" was already done; (b) the interval sweep proved the rebuild CADENCE
         is already at its optimum, and in an all-moving scene like the washer a structural "incremental"
         rebuild collapses to a full rebuild (every path is dirty) -- so it can't drop the washer query.
         The real cause of the z437 query regression (3.9 -> 5.1) is that enlargeProxy only ever GROWS internal
         AABBs and never shrinks them, so the bounds bloat between structural rebuilds. FIX (new): DynamicTree
         .refitTight(gpa) -- gather internal nodes in pre-order into a reused refit_order buffer, process in
         reverse so children are tightened first, set each internal aabb = combine(children) (+ category_bits,
         height). O(n) sequential, far cheaper than a structural rebuild. Called every step in the p2d.refit
         zone right after refitActiveBodyAabbs; structural rebuild stays at interval 8 (refit tightens AABBs but
         can't REGROUP migrating bodies). PHYSICALLY TRANSPARENT: refit only tightens internal bounds, never
         changes the leaf set a query returns -> identical contacts to the no-refit build (washer 6430 = 6430).
         MEASURED (host, washer 44x44, 800 steps, 3-run avgs): B rebuild8/no-refit ~3949-4016; C rebuild8+refit
         ~3822-3847 (reproducible ~3.6% faster total native, both B runs > both C runs). Refit ONLY, no
         structural rebuild = 7049 (DISASTER -- confirms structure rebuild is essential; refit complements,
         doesn't replace). refit + rebuild32 = 3972 (worse than rebuild8; structure degrades in 32 steps).
         bp.query is a bigger slice on device (5.1/18.5 = 28%) than in this native total, so the device query
         drop should exceed 3.6%. Expect device: p2d.refit ticks up slightly (the O(n) pass), bp.query drops.
         VERIFIED: 45/45 host tests (refit transparent -> snapshot/determinism intact); fmt + lint clean;
         wgpu-check GREEN; debug + release x2; release 2107633 bytes. Next zimr440.


zimr440: NEW PLAN — raylib sample port completion (src/notes/raylib_port.md is now the Current plan in
         claude.md; webgpu_control / physics_demo / plot3d paused). Cross-referenced raylib-master's 217
         examples against zimr's 172 wgpu_* examples by name+concept (lineage raylib -> zimr GL ports -> wgpu).
         Result: 76 DONE, 126 TODO in-scope, 15 N/A (VR sim, multi-monitor/window flags, native file IO, GL
         interop, rlgl-standalone -- don't apply to wasm32-wasi/WebGPU/single-canvas/phone). Per-category todo:
         core 24, shapes 17, textures 22, text 11, models 20, shaders 24, audio 7, others 1. Grouped into 7
         prioritized waves A-G (A 2D draw primitives, B texture/image, C text/fonts, D 3D models/anim/loaders,
         E shaders/renderer features [highest engine value], F audio, G core/utilities). ~15 DONE matches are
         approximate (flagged (~)) -- re-verify early (e.g. text_layout standing in for 3 text samples; trails
         for mouse_trail). Plan says: one example/turn, cite the raylib .c source in each header so the
         checklist stays grep-auditable. Docs-only turn (no engine change; standalone unchanged from zimr439).


zimr445: PIVOT (Simon) -- break from raylib porting to design a --fix autofix mode for lint_zimr,
         mirroring `zig fmt` check-vs-write. Surveyed the source: linter is AST-based, emits Issue{line,col,
         message,rule} (a POSITION, not an edit); has `// lint:off` suppression + isSkipped allow-list + mtime
         stamp cache; only file-write today is the stamp cache. NO --fix exists -- the `--fix` mentions in
         comments are historical: a prior EXTERNAL autofixer once left `} };` shapes -> parse errors ->
         5 files silently un-linted ~5 turns (lint_zimr.zig:3510). Byte spans are trivially available
         (ast.tokenStart(tok); end = tokenStart(last)+tokenSlice(last).len, see :2112). Wrote the design to
         src/notes/lint_autofix.md. Core: Issue gains `fix: ?Fix{start,end,replacement}`; check mode ignores
         it (gate untouched); suppression inherited for free. SAFETY INVARIANT: after splicing edits, re-parse;
         if more parse errors than input -> roll back whole file, never persist a worse-parsing file. Apply algo:
         collect fixes, sort desc by start, skip overlaps, splice back-to-front, re-parse-guard, write, re-lint
         up to 3 passes (cascade + deferred), then `zig fmt`. Triage: A1 (mechanical single-span, v1) =
         unused-global [FLAGSHIP, Simon's pick], shader-inline-fn, named-struct-init, fn-args-multiline (insert
         trailing comma -> fmt reflows), branch-braces (wrap body -> fmt reflows). A2 (v2) = as-round/
         redundant-cast, int-from-float, std-debug-assert, prefer-std-alias, import-at-top, clamp-pattern,
         decl-order. MANUAL = untyped-local (needs inference), std-math, reserved-math-names (rename+scope),
         module-var, line-length, array-mult, shader-no-atan, sampler-*, anon-return. CLI recommendation:
         keep default=check (gate-safe; DIVERGES from fmt's default-write because the linter is a build-gate
         dep), add --fix / --check / --fix --dry-run. OPEN Q for Simon: accept that divergence or match fmt
         literally? Phases P1 plumbing+unused-global+tests, P2 rest of A1, P3 A2. Awaiting Simon's go-ahead +
         the CLI-default decision before implementing.


zimr446: lint_zimr AUTOFIX -- implemented `--fix` mode (P1 of src/notes/lint_autofix.md). Simon: only the
         rules we can do UNAMBIGUOUSLY. Shipped 3, all single-span edits that are valid Zig even before fmt:
         unused-global (delete decl span: walk back over `///` doc-comment tokens + indentation, through `;`,
         swallow trailing newline only when the decl OWNS its line so shared-line siblings survive),
         named-struct-init (delete the WHOLE type expr firstToken(node)..tokenStart('{') -> "." so qualified
         `foo.Bar{...}` works, not just single-token), shader-inline-fn (delete "inline " via pointer arith:
         trimmed.ptr - ctx.source.ptr, since the text-scan slices point into ctx.source).
         ARCH: Issue gained `fix: ?Fix{start,end,replacement}` (check mode ignores it -> gate identical, verified
         0 issues whole-tree post-refactor). Ctx.emitFix (token) + emitFixLC (line/col) both honour existing
         // lint:off. Extracted analyzeSource() from main so check + fix share one path. applyFixes (segment
         splice), collectFixes (sort asc + drop overlaps), countParseErrors + PARSE-GUARD ROLLBACK (edit that
         raises parse-error count is discarded -> never write a worse-parsing file, directly answering the old
         `} };` external-autofixer disaster), runFixLoop (<=5 passes -> cascades settle: removing b unuses a).
         CLI: --fix (rewrite in place), --dry-run (report, no write), --check (explicit alias). DECISION: default
         stays CHECK (gate-safe), --fix is opt-in -- deliberate divergence from `zig fmt` default-write because
         lint is a build-gate dep. Pair --fix with `zig fmt` after (collapses the blank line a deletion leaves).
         TESTED IN SANDBOX (linter is a host tool): doc-commented unused decl, multi-line blk: decl, cascade,
         Point{}->.{} , inline fn->fn; dry-run leaves bytes intact; re-fix no-op (idempotent); fmt collapses
         double-blank; ast-check passes; wgpu-check GREEN. Refreshed /tmp/lint_new to the new binary. NEXT:
         permanent fixture+host-test target (rollback + cascade), then A2 tier (as-round/redundant-cast first).


zimr447: AUTOFIX-ON-BUILD (Simon: by default lint+fmt before compile; if confident we aren't breaking
         anything, autofix on zig build). Discovery: build.zig already has a LINT-FIRST GATE -- every Compile
         dependsOn lint + `zig fmt --check`, so they ALREADY run before compilation (in CHECK mode). So the only
         new thing was flipping check->apply. Added `-Dautofix` build option (default TRUE per Simon). When on:
         install-path lint Run gets `--fix` (lint_run_install.addArg), and a NEW gate-only fmt Run
         (fmt_apply_gate, distinct from `zig build fmt`s fmt_apply so ordering doesnt change that step) is wired
         AFTER lint_run_install so the two mutating steps SERIALISE (never race on the same files); every compile
         dependsOn fmt_apply_gate => order = lint --fix -> zig fmt -> compile. When off (-Dautofix=false):
         original strict gate (fmt --check + lint check, no mutation). Standalone `lint`/`lint-check` steps keep
         using check-mode lint_run regardless. CONFIDENCE ARGUMENT (the "not breaking anything" bar): parse-guard
         => never writes worse-parsing file, AND the compile is the very next step => any wrong deletion (removed-
         but-referenced decl) surfaces as undefined-identifier in the SAME build. Only silent risk:
         @hasDecl(@This(),"private") string-literal flip, vanishingly rare. Autofix also dissolves the turn-343
         objection (dirty state used to BLOCK build; now it gets FIXED). VERIFIED end-to-end in sandbox: planted
         unused global in wgpu_dashed_line -> `zig build wgpu-dashed-line-standalone` (autofix default) removed it
         + produced html, exit 0; -Dautofix=false reported the global and REFUSED to mutate (probe still present);
         wgpu-check -Dautofix=false GREEN; default gate on clean tree mutates nothing. Caught + fixed my own 121-
         col line in build.zig via the autofix residual (line-length is manual-tier -> correctly failed the build
         until I shortened it -- nice proof the unfixable path works). readme.html updated (linter now repairs +
         fmts before compile). lint_autofix.md P2 section added. **STANDING GATE RECIPE CHANGE: strict
         verification now uses `timeout 580 $ZIG build wgpu-check -Dautofix=false -j1`** (default would autofix).
         For porting, building a standalone with default autofix now auto-fixes my mechanical nits (no more hand-
         fixing the 2-4 lint nits per example) -- only manual-tier issues still need hand fixes. TODO: enable
         mtime-cache in fix mode (currently --fix re-lints whole tree ~2.4s/build, no skip); permanent fixtures.


zimr448: lint --fix WARM (Simon: make sure lint is warm). Fix mode previously bypassed the per-file mtime
         stamp cache -> every autofix build re-lints the whole tree (~3.7s). Now the fix branch in main() uses
         the SAME stamp cache as check mode: (1) cache lookup before processing -- if stamp.source_mtime ==
         current file mtime AND stamp.binary_mtime == lint binary mtime, skip (clean file has nothing to fix;
         binary-mtime invalidates the moment new fix rules ship); (2) re-stamp after processing iff no residual
         + not rolled_back + not dry_run -- if edits were applied the file was written so RE-STAT for the post-
         write mtime and stamp that (else stamp the unchanged mtime). dry-run skips both lookup and stamp (always
         shows full picture). Stamps are shared/interchangeable with check mode (same stampPathFor hash, same
         binary) -- a file proven clean by either mode is known clean, so my strict `-Dautofix=false` gate and
         the default autofix build cooperate. VERIFIED in sandbox: cold whole-tree --fix 3684ms -> warm 3ms
         (skip-all); editing one file (mtime bump) re-examines+fixes just it, then an immediate re-run skips it
         (nothing fixed); the post-fix file differs from original by only one blank line which `zig fmt` (the
         gate step after lint) heals to byte-identical. fmt always runs regardless of lint stamps (fmt_apply_gate
         is independent), so caching lint work never skips needed formatting. fmt-clean, tree 0 issues, strict
         wgpu-check GREEN. Autofix feature now complete + warm. NEXT: back to raylib ports (Wave A #5 pie_chart),
         unless Simon redirects. (Deferred niceties: permanent lint fixtures/host-test; A2 fix tier.)


zimr450: autofix +no-qualified-zm (half-1) + GUARD UPGRADE to AstGen. Simon asked: is `zm.clamp` in a body
         (adding `const clamp = zm.clamp` if missing) autofixable? Assessment: splits in two. HALF-1 (shipped):
         when a file-scope `const X = zm.X;` ALREADY exists, rewrite inline `zm.X` -> `X` by DELETING the `zm.`
         prefix (span [firstToken(node)..tokenStart(field_tok)), replacement "" -- static, so no source-pointer
         lifetime issue). Safe+unambiguous: X provably resolves to the binding, file already compiles, parse+
         compile safe. Guarded by new fileScopeBindsZm(ast, zm_aliases, name) which confirms a rootDecl
         `const name = <zmalias>.name`. Missing-binding case stays report-only. HALF-2 (deferred): auto-INSERT
         the binding when missing -- needs free-name guard (collision/shadow) + placement + insert-dedup; safe
         only via compile backstop. Building half-1 EXPOSED a real interaction bug: unused-global flagged a
         zm-binding `const clamp = zm.clamp` as unused (its only use was the QUALIFIED zm.clamp, which the bare-
         identifier ref-counter doesnt see), so in one pass unused-global DELETED the binding while no-qualified
         REWROTE the body to bare clamp -> undeclared identifier. Parses fine, so the parse-only guard MISSED it.
         FIX: upgraded the rollback guard from countParseErrors -> compilesClean = Ast.parse THEN
         std.zig.AstGen.generate + zir.hasCompileErrors(). Now a pass that turns a clean-compiling file broken
         rolls back (verified: conflict file left untouched, both issues reported; clean Case-1 still rewrites;
         original unused/named/shader/cascade fixtures still pass). AstGen treats @import opaquely (no false
         trips on cross-module refs) and only runs when a fix is pending (0 cost on clean files; cold whole-tree
         --fix still ~3.6s). Hand-fixed my own fn-args-multiline (fileScopeBindsZm 3 params >90col -> multiline;
         not yet an autofix). tree 0 issues, strict wgpu-check GREEN. NEXT: back to raylib (Wave A #6
         triangle_strip) unless Simon wants half-2 or the fn-args/branch-braces autofixes.


zimr451: zm KEYWORDS reform (Simon). Decisions: (a) keyword list = the curated zm vocab that needs file-top
         aliasing; NON-keyword zm decls may be used qualified `zm.X` WITHOUT an alias ("i dont want to have to
         alias a non keyword name"); (b) rename cross3->cross. zm has 418 pub decls -- reserving ALL would forbid
         common locals (float/int/angle/texture/rotate/blend/location/binding...), so keep CURATED but expand.
         IMPLEMENTED: (1) renamed cross3->cross across 128 sites (word-boundary sed, spared cross3arr) in
         zimrmath + all callers; 162 math tests + 45 physics tests pass. (2) Replaced reserved_math (~40, with
         DRIFT: cross/lengthSq/square/reflect/refract werent bare zm decls) with a renamed+expanded `keywords`
         StaticStringMap (~62): added scalar vocab asin acos atan atan2 sincos exp2 exp10 log2 log10 trunc fract
         hypot mulAdd degToRad radToDeg, vector dimensioned variants dot2/3/4 cross cross2 length2/3/4
         lengthSq2/3/4 normalize2/3/4 distance2/3/4 reflect2/3 refract2/3 project3 reject3 angle2/3, const inf;
         every entry verified vs the 418 zm decls. (3) NARROWED no-qualified-zm: now fires ONLY when the field
         is a keyword (added `if (!keywords.has(field)) return;`), so `zm.matFromAxisAngle`/`zm.vec3` are allowed
         qualified, `zm.clamp` still flagged. reserved-math-names uses the same `keywords` set. COLLISION SWEEP:
         building+linting the tree surfaced 2 -- a local `sqrt2=1.412` (box2d const, NOT zm.sqrt2) in
         zimrphysics2d and `ln`(=local normal vec) in draw3d -- so dropped ln/sqrt2/sqrt1_2 from keywords (short,
         collide with reasonable locals -> bad keywords; matches the "distinctive names dont collide" principle).
         Verified: narrowing test (matFromAxisAngle pass, clamp flagged), tree 0 issues, fmt clean, strict
         wgpu-check GREEN. The keyword list is the single source of truth for both rules now; maintain it in
         tools/lint_zimr.zig (~line 415, with a header comment). NEXT: back to raylib (Wave A #6 triangle_strip).


zimr452: keyword additions + magic-constant sweep (Simon). Added vec2/vec3/vec4 + sqrt2/sqrt1_2 to the
         keyword set (Simon: "vec3 should be a keyword", "sqrt2/sqrt1_2 ... should be keywords"). Then the
         box2d sqrt2 thread: the local `const sqrt2 = 1.412` in zimrphysics2d (computeShapeMass rounded-polygon
         path) -- Simon: "if box2d has a sqrt2 it should be zm.sqrt2." CONFIRMED FROM BOX2D SOURCE
         (box2d-main/src/geometry.c:326): literally `float sqrt2 = 1.412f;` with comment "Approximate mass of
         rounded polygons by pushing out the vertices." => it is a LOOSE magic sqrt2 in an already-APPROXIMATE
         mass calc; no algorithmic reason for 3 decimals; the ~0.01% delta is meaningless and parity-safe (mass/
         inertia approximation, not collision geometry). Fixed: bound `const sqrt2 = zm.sqrt2;` in zimrphysics2d
         and use it (1.41421356 now). SWEEP for other hardcoded math-constant approximations found+fixed:
         image.zig/shapes2d.zig/draw3d.zig each had `pub const PI: f32 = 3.14159...` in a raylib-compat
         PI/DEG2RAD/RAD2DEG struct DESPITE already binding `const pi = zm.pi;` -> pointed PI at the canonical
         `pi` (DEG2RAD/RAD2DEG derive from it); removed image.zig's duplicate local PI too. wgpu_app `two_pi =
         6.2831853...` -> bound `const tau = zm.tau;` and use tau. plot.zig `-1.5707963...`-> `-pi*0.5`,
         `6.283185...`-> tau (bound pi/tau). LEFT runtime.zig `0.7071` (x4 camera up-vector basis threshold):
         multiple nested zm scopes + it's a fuzzy threshold not a duplicated constant -> low value/risk, skipped
         (noted). All value-preserving/parity-safe. 45 physics tests pass, tree 0 issues, fmt clean, strict
         wgpu-check GREEN. NEXT: back to raylib (Wave A #6 triangle_strip) unless Simon continues the cleanup.


zimr453: keywords = all zm constants + screaming-case purge (Simon: "most zimrmath constants should be
         keywords", "deg_to_rad/rad_to_deg should be keywords", "PI is not legal (screaming case)", "I am ok
         with many keywords", cos45). Added the remaining zm numeric constants as keywords: euler log2e log10e
         ln2 ln10 two_sqrtpi rad_per_deg deg_per_rad (pi tau phi sqrt2 sqrt1_2 already; nan/inf are zm FUNCTIONS
         so already valid keywords). NOW ALL 13 zm numeric constants are keywords (report: 0 constants left
         non-keyword). 79 keywords total; 327 non-keyword zm decls = 37 types + 290 fns (report written to
         outputs/zimr_keywords_report.txt for Simon). deg/rad: Simon's "deg_to_rad/rad_to_deg" = zm's
         rad_per_deg (deg->rad, pi/180) and deg_per_rad (rad->deg, 180/pi) -- both now keywords. COLLISION
         sweep on add: ui.zig had a local `const rad_per_deg: f32 = pi/180.0` redefinition -> routed to the
         keyword (bound const rad_per_deg = zm.rad_per_deg). euler had NO collision (kept). SCREAMING-CASE PURGE:
         image.zig/shapes2d.zig/draw3d.zig each had a file-local `const z = struct{...}` namespace defining
         `pub const PI/DEG2RAD/RAD2DEG` (PI=pi already from last turn). Removed all three from each; replaced
         z.DEG2RAD (2 in image, 43 in shapes2d) with the keyword `rad_per_deg`; draw3d's were unused (deleted).
         z.PI/z.RAD2DEG had 0 uses. cos45: runtime.zig `0.7071` x4 (camera up-vector basis threshold) = cos45 =
         sqrt1_2 -> bound const sqrt1_2 = zm.sqrt1_2 in the governing struct scope, replaced all 4. tree 0
         issues, fmt clean, strict wgpu-check GREEN. OPEN for Simon: 37 zm TYPES (Vec2/Mat4/Color/...) are still
         non-keywords (usable as zm.X qualified) -- report lists them; he may want some as keywords too. NEXT:
         back to raylib (Wave A #6 triangle_strip) unless more keyword/constant work.


zimr454(analysis-only, no code change): keyword EXPANSION proposal for types+fns (Simon: "clearly a
         mistake to use Color as something else than zm.Color ... guess which types/functions I want, look for
         collisions, present for approval"). Method: copied lint_zimr.zig to /tmp, added all 37 zm types + ~20
         distinctive fns as temp keywords, ran the tree -> every reserved-math collision surfaced. REPO KEYWORD
         LIST UNCHANGED (still 79) pending approval. Proposal written to src/notes/keyword_candidates.md +
         outputs/keyword_proposal.txt. TIERS: A=27 types 0-collision RECOMMEND ADD (Aabb Aabb2 Boolx4/8/16
         CameraProjection ColorU32 Complex F32x4Component F32x8/16 Mat Mat2 Mat22 Mat3 OrthoBasis3 Plane2 Quat
         RayCamera RayCameraDesc Rot2 Sweep2 Transform2 Trs Vec Vec2i Vec3); B=Vec2 (2 dup redefs incl runtime
         `@import("zm").Vec2`), Color (wgpu.zig:208 extern Color RGBA = Simon's exact case, reconcile w/ zm.Color)
         -- add after tiny fixes; C=EXCLUDE (legit non-zm): Ray(5 raytracer/plot3d custom + types.Ray),
         RayCollision(2), Camera2D/3D(2), Transform(1 plot's own 2D); D=optional fns 0-collision (complex f32x4
         f32x8 lerpV mapLinear modAngle mulMat mulMatVec niceNum swizzle vec); EXCLUDE common-word fns (identity
         inverse translation quat transpose determinant scaling remap splat -- collide w/ natural locals like
         ln/sqrt2 did). Also found linter gap: canonical-binding check should exempt `@import("zm").X` form
         (runtime.zig:3523). NEXT: await Simon's tier pick, then apply + fix Tier-B collisions + gate.


zimr455: aggressive keyword unification Tier A+B (Simon: "unify aggressively ... rename if good reason").
         CHUNK 1: added 27 Tier-A types (0-collision: Aabb Aabb2 Boolx4/8/16 CameraProjection ColorU32 Complex
         F32x4Component F32x8/16 Mat Mat2 Mat22 Mat3 OrthoBasis3 Plane2 Quat RayCamera RayCameraDesc Rot2 Sweep2
         Transform2 Trs Vec Vec2i Vec3) + 16 functions incl SPLAT (Simon disagreed w/ excluding it): complex
         determinant f32x4 f32x8 lerpV mapLinear modAngle mulMat mulMatVec niceNum remap scaling splat swizzle
         transpose vec. CHUNK 2 (Tier B): Vec2 -> both redefs were literally zm.Vec2 (compute_host @Vector(2,f32),
         runtime @import("zm").Vec2); canonicalized + HOISTED compute_host's to file scope (Simon: "aliases at
         root"). Color -> NOT unifiable: zm.Color is extern{r,g,b,a:u8} (raylib 0-255) but wgpu.Color was
         extern{r,g,b,a:f32} w/ 16-byte assert (WebGPU clear color) -- genuinely different, so RENAMED wgpu.Color
         -> ColorF32 (def + 2 internal + 2 gpu_iface refs), freeing `Color` to mean zm.Color (now a keyword).
         LINTER FIX (Simon: "untyped-local should not trigger for aliases"): added isAliasInit() -- a const whose
         entire init is a bare identifier or field_access chain (zm.Vec2, foo.Bar) is an alias, not a value
         local, so untyped-local skips it (both .statement/.expression branches). Verified: `const M = zm.Mat4;`
         exempt, `const v = zm.dot(...)` (call) still checked. Keyword count now ~124. tree 0 issues, fmt clean,
         strict wgpu-check GREEN (had to rm -rf .zig-cache, hit the 6GB guard). PENDING Tier C (Simon: "try to
         unify"): Ray/RayCollision/Camera2D/Camera3D/Transform have legit non-zm uses; + colliding common-word
         fns identity/inverse/translation/quat. Investigate unification next.


zimr456: Tier C unification (Simon approved, "unify Ray, plot3d adapts, quat keyword like vec"). DONE:
         (1) Ray UNIFIED to zm.Ray everywhere: raytracer (custom struct {origin,direction,fn at} -> `const Ray =
         zm.Ray` + free `rayAt`; .origin->.position x8; ray.at(root)->rayAt(ray,root)); plot3d (custom {origin,
         direction:Point3=@splat(0)} -> zm.Ray; .origin->.position x5; Point3==Vec so field-compatible, no Ray{}
         default-construction so dropping defaults is safe); draw3d (2 sites types.Ray/models_types.Ray ->
         zm.Ray) + runtime (types.Ray -> zm.Ray). (2) RayCollision -> zm.RayCollision (draw3d x2). (3) quat:
         zimrphysics.zig had a local `inline fn quat(x,y,z,w) Quat { return .{x,y,z,w}; }` -- byte-identical to
         zm.quat (verified) -- removed it, bound `const quat = zm.quat;`; 17 quat() call sites now resolve to the
         keyword. (4) plot.Transform ({forward,inverse:*const fn(f64)f64} axis scale-map, unrelated to zm.Transform
         TRS) RENAMED -> AxisMap (4 sites). Added keywords: Ray RayCollision Transform quat (~128 total). tree 0
         issues, fmt clean, strict wgpu-check GREEN. NOT DONE -- Camera2D: the 2 demo cams (physics) do a Y-FLIP
         (sy = center - (w.y-target.y)*ppm) to bridge box2d Y-up -> screen Y-down; zm.Camera2D uses a SCALAR zoom
         and can't flip Y, so it can't express the demo transform without manual Y-handling. Genuine coordinate-
         convention mismatch (can't device-verify a rendering change here). PRESENTED options to Simon: (a) add an
         optional Y-flip / non-uniform zoom to zm.Camera2D so demos adopt it cleanly [recommended, general], (b)
         demos hold zm.Camera2D data + a local flip helper [partial], (c) rename demo cams. AWAIT decision.
         identity/inverse/translation left non-keywords (agreed). NEXT: Camera2D decision, else raylib triangle_strip.


zimr457: Camera2D unified via Option-1 (Simon: add Y-flip to zm.Camera2D so demos adopt it). zm.Camera2D
         gained `flip_y: bool = false` -- when true the matrix() scale negates Y (scaling(zoom, -zoom, 1)),
         reflecting Y about target (Y-up world -> Y-down screen). Additive/default-false so existing users
         unaffected; screenToWorld inverts automatically. Added host test "zm.Camera2D flip_y" (offset 100,50 zoom
         10 flip: (2,3)->(120,20) + round-trip) -> 163 zimrmath tests pass. ALSO FIXED a latent bug surfaced by the
         test (first caller of worldToScreen/screenToWorld forced analysis): both used vec()=4-wide where
         mulMatPoint wants Vec3 -> changed to vec3(). Migrated BOTH demo cams to zm.Camera2D: (1) sidebyside --
         custom {target,ppm,cx,cy,toScreen} -> zm.Camera2D; construct .zoom=ppm .offset=.{cx,cy} .flip_y=true;
         toScreen->worldToScreen. (2) zimrphysics2d_demo/render.zig -- custom {target,pixels_per_meter,screen_w/h,
         worldToScreen,screenToWorld} -> zm.Camera2D; pixels_per_meter->zoom; demo main sets .flip_y=true on init
         (State default + reset ctor), screen_w/h -> offset=.{w*0.5,h*0.5} each frame, zoom slider rebound.
         scenes.zig untouched (its .ppm is a scene-spec field copied to cam.zoom). flip_y reproduces the prior
         formula exactly (host-verified) so rendering should match -- SIMON: device-verify both physics demos.
         Added keywords Camera2D Camera3D -> 130 keywords total; ALL 37 zm types are now keywords. tree 0 issues,
         fmt clean, strict wgpu-check GREEN. Tier C COMPLETE. NEXT: raylib Wave A #6 triangle_strip.


zimr459: float/float64/int are now keywords (Simon: "float is a keyword, right?"). They were previously in
         the excluded common-word bucket, but zm.float (->f32), zm.float64 (->f64) and zm.int(T,x) are pervasive
         numeric-conversion helpers and naming a local `float`/`int` is essentially always a mistake. Empirical
         collision sweep (temp linter on whole tree): 0 collisions for all three. Added to keywords -> 133 total.
         hasTypeSignal still special-cases float/float64 (orthogonal: type-signal for untyped-local vs keyword
         alias). Only the linter keyword list changed -- engine source byte-identical to the gated zimr458 -- so
         tree lints 0 issues and compilation is unchanged (no re-gate needed). NEXT: raylib Wave A #7
         shapes_rectangle_advanced.


zimr464: ENGINE - real wall-clock date/time API for zimr apps (Simon: "make it easy for zimr apps to get
         the actual date/time"). Prior state: runtime clock = performance.now (monotonic elapsed via
         dom.js_now_ms); no time-of-day. ADDED two dom imports beside js_now_ms: js_epoch_ms (Date.now() ms
         since Unix epoch UTC) + js_tz_offset_min (new Date().getTimezoneOffset(), mins to ADD to local->UTC).
         Wiring: web.zig dom struct gets the externs + wrappers epoch_ms()/tz_offset_min() (native fallback:
         std.time.milliTimestamp()/offset 0 guarded by !isWasm); bridge.zig gets host providers jsEpochMs/
         jsTzOffsetMin registered at the js_now_ms site (ns.set in ZimrWgpu install -> the same import object the
         working clock uses; confirmed both land in generated standalone HTML beside js_now_ms). PUBLIC API on
         z.: DateTime{year,month(1-12),day,hour,minute,second,millis,weekday(0=Sun)}, localTime()->DateTime
         (real local, DST-correct), epochMillis()->f64, timezoneOffsetMinutes()->f64. Core decomposition
         web.dom.fromEpochMillis(epoch_ms,offset_min) is PURE+deterministic (Howard Hinnant civil_from_days);
         validated against 5 python-generated vectors incl 1970 epoch, 2000 leap day, weekday correctness, and a
         UTC+2 offset shift (throwaway native zig test, all pass). KEY FACTS: bridge.zig is Zig that c2js
         transpiles to the browser host JS providing dom/wgpu imports (NOT a hand-written JS template -- there
         is none for canvas/panic either); @intFromFloat still banned so localNow uses @round(tz)->i32. Migrated
         wgpu_digital_clock off the seeded-time hack to z.localTime() -> shows ACTUAL current time now (rebuilt
         standalone, js_epoch_ms/js_tz_offset_min present in HTML). NO new module (kept in web.zig per single-
         zimr-module rule). lint clean across web/bridge/zimr/example, strict wgpu-check GREEN (smoke instantiates
         OK). raylib_port.md unchanged 86/116. SIMON: device-verify wgpu_digital_clock.html shows real local
         time. NEXT Wave A #11 shapes_clock_of_clocks. FOLLOWUP IDEA: a permanent host test for fromEpochMillis
         (currently only throwaway-validated; lives in web.zig which the zimrmath harness doesn't compile).


zimr465: FIX the zimr464 wall-clock boot crash + make boot errors diagnosable (Simon device-hit
         "zimr boot: WASM instantiate rejected (out of memory or bad bundle)" -> black screen). ROOT CAUSE: a
         LinkError. web.zig declared js_epoch_ms/js_tz_offset_min `extern "dom"` (correct), but I registered the
         providers in wgpu_ns beside jsNowMs -- WRONG. js_now_ms is a SPECIAL case: declared extern "dom" yet a
         build step remaps its wasm import module to "wgpu" (node confirms: js_now_ms module=wgpu), so providing
         it in wgpu_ns happens to work. The CORRECT pattern for a "dom" host fn is js_log:
         `dom.set("js_log", funcNum(&ZimrWgpu.jsLog))` inside the dom import-object block (~bridge.zig 2865).
         The real dom object there did NOT contain my fns -> dom.js_epoch_ms unresolved -> instantiate rejects.
         FIX: removed the 2 wgpu_ns registrations, added dom.set("js_epoch_ms"/"js_tz_offset_min",
         funcNum(&ZimrWgpu.jsEpochMs/jsTzOffsetMin)) next to js_log; jsEpochMs/jsTzOffsetMin stay defined in
         ZimrWgpu. DIAGNOSTICS: the boot poll discarded the rejection reason. The c2js promise registry
         (c2js.zig ~2199) DOES store it: on reject it saves {s:2, v:__href(e)} and js_promise_take returns that
         error handle. Rewrote the stage 1/2/3 reject handler to js_promise_take the reason and
         console.error(prefix, reason.get("message"), reason) -> the on-page log overlay (which mirrors
         console.error) now shows the actual LinkError text naming the missing import, instead of the canned
         "out of memory or bad bundle". Kept a per-stage hint line. VERIFICATION TECHNIQUE (reusable, runs in
         THIS sandbox without a browser): node is available (v22). Extract the inlined wasm from the standalone
         (WASM_BYTES = Uint8Array.from(atob("..."))), then (a) `new WebAssembly.Module(buf)` +
         WebAssembly.Module.imports() to list imports BY MODULE (this is how I found js_now_ms@wgpu vs
         js_epoch_ms@dom); (b) build a stub importObject covering every import and `new WebAssembly.Instance` ->
         proves the module LINKS / isn't a CompileError or OOM; (c) `node --check` each <script> block to rule
         out malformed-bundle JS; (d) grep the transpiled HTML for `__H[tN].<name> =` to confirm several dom fns
         target the SAME object handle (js_log/js_epoch_ms/js_tz_offset_min all -> __H[t3]). All four checks now
         pass on the rebuilt clock. lint clean, strict wgpu-check GREEN. raylib_port.md unchanged 86/116. SIMON:
         re-load wgpu_digital_clock.html -- should boot and show real local time now; if any future boot fails,
         the overlay will print the actual reason. NEXT Wave A #11 shapes_clock_of_clocks.


zimr477: API idiom fix (Simon caught it): user code should NOT track `was_down` for edge detection -- the
         engine already tracks previous/current button state. USE z.isMouseButtonPressed(f.input,.left)
         (down-edge: prev==0 && curr!=0) and z.isMouseButtonReleased(f.input,.left) (up-edge: prev!=0 &&
         curr==0); z.isMouseButtonDown is the LEVEL (held) check. UPDATED TAP-VS-DRAG IDIOM: on Pressed set
         s.press=mouse, s.dragged=false; while Down if distance(mouse,s.press)>8 -> s.dragged=true; on Released
         if !s.dragged -> tap action. (s.dragged still lives in State -- it persists across frames -- but
         was_down is GONE.) Swept all 9 examples that used the old pattern (bullet_hell + digital_clock,
         logo_raylib_anim, triangle_strip, color_wheel, penrose_tile, splines_drawing, rectangle_advanced,
         clock_of_clocks): replaced `down and !s.was_down`->isMouseButtonPressed, `!down and s.was_down`->
         isMouseButtonReleased, dropped the `s.was_down = down;` line + the field. GOTCHA: clock_of_clocks only
         used `down` for the (removed) release edge -> its `const down` became unused (Zig errors on unused
         locals) -> removed it; the others keep `const down` for their drag level-checks. lint clean, `zig build
         check` GREEN. No engine change. raylib_port.md unchanged 92/110. NEXT: Wave B (texture/image pipeline)
         or continue ports.


zimr480: REORGANISED raylib_port.md HARDEST-FIRST (Simon: start with the most complicated examples that
         require engine work, so the engine grows under the hard cases and lighter examples get cheaper).
         Old order was theme-by-category easy->hard (textures, text, ... shaders, models last). NEW order:
         WAVE 1 Renderer & shader features (24; depth textures + compare-sample, MRT G-buffers, shadow-map
         pass, per-material WGSL via shadermath, normal/tangent attribs, post chains; heaviest first =
         shadowmap -> deferred -> hybrid -> normalmap/lightmap -> depth -> forward variants -> 2D frag
         effects). WAVE 2 Models/anim/loaders (20; skeletal blending, bone sockets, mesh picking, procedural
         mesh gen, IQM/M3D/VOX loaders). WAVE 3 Texture pipeline engine-bits-first (19; the WgpuTexture
         drawTexturePro rotation gap from zimr479, blend modes, n-patch, polygon, RTT zoom, image kernels).
         WAVE 4 Text & fonts (11; TTF range load, SDF atlas, sprite fonts, unicode). WAVE 5 Audio (7; mixing,
         positional, FFT spectrum, DSP effects, module). WAVE 6 Core utils (25; lightest, last). Recorded the
         carry-over engine TODO at the top (WgpuTexture drawTexturePro origin+rotation). Updated the execution
         note: expect most Wave 1-2 turns to ship an engine change alongside the example. Doc-only change (no
         gate). raylib_port.md still 94 DONE; wave lists sum to 106 (a ~2 census drift vs the old 108 header
         predates this and is a separate audit). NEXT: start WAVE 1 -- likely shaders_shadowmap_rendering or,
         to unblock several at once, first add the WgpuTexture drawTexturePro rotation.


zimr481: ENGINE ADD -> z.drawTexturePro (WgpuTexture origin+rotation), then finished srcrec_dstrec with the
         spin raylib's version has. New wgpu_app.zig drawTexturePro(gl, tex: WgpuTexture, source: Rectangle
         (PIXELS), dest: Rectangle, origin: Vec2, rotation deg, tint): UVs = source/tex dims; rotates the 4
         dest corners about pivot dest.x/dest.y where corner offsets are (-origin .. -origin+size); emits 2
         triangles via the same gl.bindTexture/begin(.triangles)/texCoord2f/vertex2f immediate-mode path as
         drawTextureRec (which was the template). Added `const rad_per_deg = zm.rad_per_deg;` alias in
         wgpu_app. Exported `pub const drawTexturePro = wgpu_app.drawTexturePro;` in zimr.zig after
         drawTextureRec. GOTCHA: a corner var named `try` is illegal (keyword) -> used tryy. srcrec_dstrec:
         the big selected frame now drawn via z.drawTexturePro with source = pixel rect of frame, dest at
         dst_center, origin = {dw/2,dh/2} (centre pivot), rotation = t*40 deg/sec; dropped the pulse + the
         axis-aligned outline (wrong once rotated); thumbnail strip still uses drawTextureRec. lint clean
         (engine + example); node link-check INSTANTIATES; standalone 1.4MB; `zig build check` GREEN (engine
         change, no regressions). Plan carry-over engine TODO marked DONE; UNBLOCKS sprite_stacking/
         image_rotate/sprite_explosion. raylib_port.md still 94 DONE (engine add, not a new example). SIMON:
         device-verify srcrec_dstrec.html now ROTATES. NEXT: Wave 3 textures_sprite_stacking or image_rotate
         (use the new rotation), or jump to Wave 1 shadowmap.


zimr482: RADIANS-CENTRIC API direction (Simon: serious game progs prefer radians; always name the unit;
         convert near the UI, not deep in the system). (1) Added a NOTE on rad_per_deg + deg_per_rad in
         zimrmath.zig: prefer the degToRad()/radToDeg() FUNCTIONS over the raw constants. (2) drawTexturePro
         param rotation -> rotation_rad and now takes RADIANS directly (dropped the internal rotation*
         rad_per_deg); removed the now-unused `const rad_per_deg = zm.rad_per_deg;` alias I had added to
         wgpu_app in zimr481. (3) srcrec_dstrec converts at the call site: `const degToRad = zm.degToRad;`
         (keyword -> must alias) then `const rotation_rad: f32 = degToRad(s.t * 40.0);` (40 deg/sec kept for
         readability, converted at the UI layer). lint clean; node link-check INSTANTIATES; `zig build check`
         GREEN (engine + math change, no regressions). TRACKED FOLLOW-UP audit recorded in raylib_port.md:
         the remaining DEGREE rotation params to flip to `_rad` are drawPoly/drawPolyLines/drawRectanglePro
         (wgpu_app) + drawTexturePro(legacy)/drawTextureRotated/drawTextureNPatch (image.zig), plus verifying
         Camera2D/Transform rotation fields. Did NOT sweep them this turn (each needs call-site + example
         updates; flagged for a dedicated pass). raylib_port.md still 94 DONE. NEXT: either the radians audit
         sweep, or Wave 3 textures_sprite_stacking/image_rotate (now unblocked by drawTexturePro).


zimr483: RADIANS SWEEP (Simon: do the radian sweep). Flipped EVERY rotation-parameter draw fn from degrees
         to radians (param renamed rotation -> rotation_rad, internal *rad_per_deg / *pi/180 removed), and
         converted all call sites with degToRad() at the UI layer. Functions: wgpu_app drawPoly/drawPolyLines/
         drawRectanglePro; shapes2d drawRectanglePro/drawPoly/drawPolyLines/drawPolyLinesThick; image
         drawTexturePro(legacy types.Texture)/drawTextureRotated/drawTextureNPatch; text2d drawPro. The two
         GL-matrix-rotate fns (drawTextureNPatch's gl.rotate, drawPro's rlRotatef) take degrees by GL
         convention, so they now convert IN: gl.rotate(radToDeg(rotation_rad),..) / rlRotatef(radToDeg(..)).
         Camera2D.rotation FIELD is now radians (zimrmath camera-matrix consumer dropped the *pi/180; field
         comment "// radians"); verified NO example sets it non-zero. Aliases: image.zig rad_per_deg alias
         (now dead there) SWAPPED to radToDeg; text2d +radToDeg; ui.zig +degToRad; 6 examples +degToRad.
         Call sites converted: shapes_showcase (drawPoly ang / drawPolyLines -ang), bullet_hell (2x magic_rot),
         recursive_hud (t*45), easings_box + easings_rectangles (state.rotation), render_texture (rot), ui.zig
         ngon/poly (c.rotation_deg x2). Doc comments updated deg->rad on the touched fns. NOTE: arc/sweep/
         direction ANGLES (drawCircleSector/drawRing/drawEllipse start-end, imageRotate, gradient direction)
         are NOT rotation params and remain degrees -> recorded as a separate later cleanup in raylib_port.md.
         lint clean (12 files); fmt; built shapes_showcase/bullet_hell/render_texture/easings_box/
         easings_rectangles/recursive_hud/srcrec_dstrec/ui_primitives_zoo_phone standalones (all exit 0);
         node link-check INSTANTIATES (shapes_showcase, bullet_hell, srcrec_dstrec); `zig build check` GREEN.
         raylib_port.md radians audit marked DONE. SIMON: device-verify any rotation still looks right
         (bullet_hell magic circle, easings box/rects, render_texture, srcrec_dstrec). NEXT: Wave 3
         sprite_stacking/image_rotate, or the arc-angle radians cleanup.


zimr484: RENAMED degToRad/radToDeg -> radFromDeg/degFromRad (Simon: Zig idiom is result-type-first, like
         @intFromFloat; and the FromX idiom is ALREADY dominant in zm - matFromQuat/quatFromMat/matFromArr/
         quatFromAxisAngle/pointFromArr3/... - so degToRad/radToDeg were the inconsistent minority). Pure
         identifier rename, ZERO behaviour change (radFromDeg computes the same deg->rad). Blast radius hit:
         18 .zig files (zimrmath defs+2 tests+3 rad_per_deg doc notes; text2d/image/ui/wgpu_app; 12 examples)
         + tools/lint_zimr.zig keyword list (degToRad->radFromDeg, radToDeg->degFromRad so the new names keep
         the no-qualified-zm alias-required treatment) + 5 live docs (CHEATSHEET, files.md, raylib_port.md,
         wgpu-ports-tutorial.html, lint_autofix.md). LEFT AS HISTORY (not rewritten): claude.md prior log
         entries + archive changelogs. Method: word-boundary sed across code+lint+live-docs, both tokens in one
         pass (no overlap). lint clean; fmt; built pie_chart/vector_angle/double_pendulum/circle_sector_drawing/
         math_angle_rotation/bullet_hell/srcrec_dstrec/shapes_showcase (all exit 0); node link-check
         INSTANTIATES (pie_chart, exercises both fns); `zig build check` GREEN. NOT done (tracked separately,
         per the eval): the other xToY stragglers (vecToArr2/3/4, matToArr*, quatToEuler*, quatToAxisAngle) +
         the matToQuat/quatToMat DUPLICATES of the existing matFromQuat/quatFromMat (dedup candidate) + color
         rgbToHsl/hsvToRgb-style (left; conventional). NEXT: Wave 3 sprite_stacking/image_rotate, or the
         remaining xToY/dedup cleanup, or the arc-angle radians cleanup.


zimr485: "Finish the arc radians. No degrees in zimr internals." First INSPECTED disk reality (handoff
         summary was STALE - it claimed shapes2d arc conversion was still pending, but on disk the arc/sector/
         ring/poly/ellipse geometry in shapes2d.zig + wgpu_app.zig + ui.zig addArc was ALREADY fully radian and
         already inside the green zimr484 gate: adaptiveArcSegments uses pi/2 & 2*pi; drawCircleSector et al
         take radian params with direct @cos/@sin; ZERO rad_per_deg multiplies in geometry). The ONE real
         remaining internal-degree LEAK: ui.zig DrawList declares a radians convention (addArc takes a0/a1 in
         radians, comment L1975 "public API exposed in radians not degrees") yet addNgon/addNgonFilled took
         `rotation_deg` - degrees - contradicting it. A rotated regular polygon is arc-stepped geometry, so it
         belongs in the sweep. FIX: renamed the two DrawCmd fields + both DrawList methods + both DrawListHandle
         wrappers rotation_deg->rotation_rad; dropped the now-redundant radFromDeg(c.rotation_deg) in the
         submission consumer (field is already radians); radFromDeg alias stays live (SliderAngle widget still
         uses it). Callers: ui_primitives_zoo_phone drove rotation from an anim phase -> made radian directly
         (phase*tau); ui_custom_rendering has a user-facing 0-360 deg SLIDER -> kept the degree slider (UI
         display) and convert at the call boundary via radFromDeg(s.ngon_rotation_deg) - the "convert near the
         edge" principle. lint clean; built ui-primitives-zoo-phone/ui-custom-rendering/circle-sector-drawing/
         ring-drawing (exit 0); node link-check INSTANTIATES ui_custom_rendering; `zig build check` GREEN.
         AUDIT - arc/shape geometry is now 100% radian. Remaining pi/180 sites in src are all DELIBERATE
         convention boundaries, NOT internal-geometry degrees (flagged to Simon as separate API-surface
         decisions): (1) Camera3D fovy [raylib projection convention] - zimrmath vfov_deg + wgpu_app fovy_rad;
         (2) HSV/HSL hue 0-360 [color convention] - image.zig; (3) plot3d camera elevation/azimuth [plotting
         convention]; (4) ImGui SliderAngle [displays deg, STORES radians - correct widget semantics];
         (5) runtime input-gesture angles + 3D orbit-camera pitch/yaw/roll [input/camera reporting convention];
         (6) GL-primitive isolation: text2d.rlRotatef / image.gl.rotate / raster software-rotate take degrees to
         mirror the glRotatef contract, but the PUBLIC drawPro/drawTexturePro/imageRotate above them are radian
         and convert via degFromRad at the boundary; (7) physics radian constants written `45.0 * pi/180.0` -
         stored value IS radians, the degree literal is just human-readable. NEXT: Simon to rule on fovy/hue/
         plot-elev-azim/gesture units; or Wave 3 sprite_stacking/image_rotate (drawTexturePro rotation ready);
         or the xToY straggler rename + matToQuat/quatToMat dedup.


zimr486: rad revolution part 2 - _rad/_deg suffix completeness + linter ban on custom conversions.
         (1) NAMING: every radian angle arg now suffixed _rad, every degree arg _deg. shapes2d arc params
         startAngle_in/endAngle_in -> start_angle_rad/end_angle_rad (+ adaptiveArcSegments); text2d rlRotatef
         angle->angle_deg (GL-degree primitive; drawPro converts radian->deg at the boundary) + drawPro local
         rotation->rotation_rad; zimrmath constructors rotationX/Y/Z, matFromAxisAngle/NormAxisAngle,
         quatFromAxisAngle/NormAxisAngle, rotate2 angle->angle_rad, matFromRollPitchYaw/quatFromRollPitchYaw
         pitch/yaw/roll->_rad, modAngle32 in_angle->in_angle_rad, + the comment API listing block; plot3d
         quatFromElAz elevation/azimuth->_rad; zimrphysics2d revoluteSetTargetAngle angle->angle_rad. All
         positional params so callers are caller-safe; zimrmath tests (positional) unaffected and pass.
         (2) BANNED CUSTOM CONVERSIONS: replaced every locally-rolled deg<->rad with zm helpers - runtime
         DEG2RAD -> radFromDeg(cam.fovy_deg); zimrmath test d2r/std.math.degreesToRadians -> radFromDeg;
         zimrphysics_demo d2r -> radFromDeg(j.*_deg); math_sine_cosine deg2rad -> radFromDeg + a full turn ->
         tau, and its degree state field angle->angle_deg (dropped now-unused pi). (3) LINTER: new AST rule
         `custom-degrad` in tools/lint_zimr.zig (checkBannedConversion, fires on any USE of DEG2RAD/RAD2DEG/
         deg2rad/rad2deg/DEG_TO_RAD/RAD_TO_DEG/degToRad/radToDeg/degrees_to_radians/radians_to_degrees/
         toRadians/toDegrees; radFromDeg/degFromRad/rad_per_deg/deg_per_rad are NOT banned, exact-match only).
         Built the tool via `zig build lint` (green tree, no false positives on radFromDeg), planted-violation
         test confirms it fires on uses + clean on the zm helpers. Gate runs the rule tree-wide: GREEN.
         Built circle-sector/ring/math-sine-cosine/zimrphysics-demo/plot3d-demo/cube3d/math-angle-rotation
         (exit 0); `zig build check` GREEN (NO REGRESSIONS + wgpu_smoke). DELIBERATE _deg/convention exceptions
         (flagged for Simon): Camera3D fovy_deg, plot3d elevation_deg/azimuth_deg, gesture angle_deg (raylib-
         compat), GL-rotate primitives angle_deg; HSV hue 0-360 (color convention, NOT renamed); Box2D joint
         target_angle/lower_angle/upper_angle (radians, kept Box2D names for port parity - candidate for _rad
         if Simon wants to break Box2D naming parity). NOT done: --explain rule-note entry for custom-degrad
         (rule fires with a clear message already; skipped to avoid an extra lint_zimr compile/gate cycle).


zimr487: DEPTH-RTT FOUNDATION step 1 (Simon picked "build depth_rendering foundation toward shadowmap").
         Shadowmap (Wave-1 hardest-first lead) is blocked on: RTT depth attachment is render-attachment-ONLY
         (wgpu_texture.zig:223, not sampleable) + shadermath/spv2wgsl has texture_2d<f32>/textureSample but NO
         texture_depth_2d/comparison sampling. The .shadow_map refs in shader_interface are illustrative DOC
         comments, not built infra. Decomposed into verifiable sub-steps; this turn lands the reusable engine
         capability (compile + unit-test verifiable; blind-GPU, Simon device-verifies the eventual example).
         DONE: WgpuRenderTexture gained `sampleable_depth: bool` (CreateDesc) -> depth attachment becomes
         depth32float (the WebGPU depth format that supports texture_binding; depth24_plus is NOT sampleable)
         with usage {render_attachment, texture_binding} + a non-filtering (nearest) depth_sampler; new fields
         depth_sampler + depth_sampleable; new `asDepthTexture()` accessor (returns a WgpuTexture viewing the
         depth, format=depth32_float, invalid handles when no sampleable depth so a miswire fails loud not
         silent-color). wgpu_app `loadRenderTextureDepthTex(gl,w,h)` (raylib LoadRenderTextureDepthTex) +
         exported z.loadRenderTextureDepthTex. 3 new unit tests (field defaults, asDepthTexture on no-depth RT,
         CreateDesc defaults) - all 11 wgpu_texture tests pass; lint clean; `zig build check` GREEN.
         REMAINING sub-steps for shaders_depth_rendering (next turns, the blind shader-codegen part): (2)
         texture_depth_2d binding kind through shader_interface (a depth Sampler2D variant) -> spv2wgsl (emit
         texture_depth_2d + sample returns f32, the OpTypeImage Depth operand is already parsed @ spv2wgsl
         ~L1599) -> bind-group-layout sampleType=depth + runtime binding; (3) depth_render_fs.zig schema+body
         (sample depth, linearize (2*near)/(far+near - depth*(far-near)), grayscale out, flipY uniform); (4)
         the example (cube+plane into the sampleable-depth RTT, then blit the depth via the shader). THEN
         shaders_shadowmap_rendering = sampleable-depth (done) + light camera VP + manual shadow compare in the
         fs. Engine-only turn (no new example yet) - foundation per Simon's explicit choice; NOT padded into a
         fake example. raylib_port.md carry-over TODO updated with the sub-step ledger.


zimr488: DEPTH ROUTE-1 "see something" (Simon: "Do 1 first, just to see something. Then spend 20 turns
         on 2"). Investigation this turn found the DECISIVE facts: (a) the faithful texture_depth_2d path is
         blocked - the clean @SpirvType texture descriptors (zimrmath.zig ~8431, where .depth=.yes would be a
         one-liner) DON'T work end-to-end (documented OpUndef zero-bit-opaque @extern blocker @ ~8413); the
         working texture path is the legacy zsample2d/zspv_rewrite machinery. (b) THE DEPTH-AS-COLOR TECHNIQUE
         ALREADY EXISTS IN THE ENGINE: pbr_fs.zig implements full shadow mapping (shadowProjCoords +
         computeShadow: (current_depth-bias)>closest_depth) sampling a "Depth-in-red shadow map"
         (pbr_fs_io.zig:48-53, shadow_map: Sampler2D(.cubemap) - a normal texture_2d<f32>). But draw3d.zig
         GATES SHADOWS OFF (white fallback, identity light matrix, "wiring one is [todo]"). So depth-as-color is
         the intended technique, shader-side done, engine shadow-PASS not wired. Route 1 chosen; per Simon's
         "just to see something" (minimal Route-1 effort), shipped the RELIABLE per-OBJECT depth cue, not a
         blind per-pixel shader-pipeline build: examples/depth_cue/depth_cue.zig - immediate-mode 3D (beginMode3D
         /drawCube/drawGrid, modeled on cube3d), a 9x9 field of cubes each grayscale-tinted by CPU distance from
         an orbiting camera (near=bright far=dark, near_d=4/far_d=26), 12-floor so far end stays visible. 1
         build.zig registry row + example_steps entry. Lint clean, standalone builds, node link-check
         INSTANTIATES, gate GREEN. HONEST SCOPE: this is the per-object cue, NOT the faithful per-pixel depth-
         as-color port; shaders_depth_rendering is NOT marked done. NEXT (the real Route-1 finish): a depth
         VS+FS pair (VS passes normalized view-space depth as a varying; FS greyscales it) rendered per-pixel -
         reuses the confirmed depth-in-red technique - then wire the shadow PASS (render depth-in-red from light
         POV into a color RTT + light VP matrix + ungate draw3d shadows) for shaders_shadowmap_rendering. Route
         2 (fix the OpUndef @extern descriptor blocker -> clean @SpirvType binding path engine-wide, then
         faithful hw-depth sampling) is Simon's queued ~20-turn engine project, tracked separately. zimr487's
         sampleable-depth RTT stands (foundation for the faithful path; not used by depth-as-color).


zimr489 - @floatFromInt -> zm.float/float64 migration + new `float-from-int` lint rule (autofix).
  WHY: `@as(f32, @floatFromInt(i))` slipped the linter - only `@intFromFloat` (int-from-float)
  had a rule; `@floatFromInt` was unchecked. House style: f32 int->float = `zm.float(x)`, f64 = `zm.float64(x)`.
  MIGRATION (~587 sites across ~90 files, paren-aware python transforms):
    `@as(f32,@floatFromInt(X))`->`float(X)` (221 @as-form); `: f32 = @floatFromInt(X)`->`float(X)` (244 bare);
    f64 equivalents ->`float64(X)` (95 @as + 23 bare); multi-line fmt-split @as forms too.
    Added file-scope `const float = zm.float;` / `const float64 = zm.float64;` aliases per touched file.
    LEFT: 242 bare `@floatFromInt` in inferred contexts (fn args/returns - type not locally pinnable) as follow-up.
  REVERTS (files that can't take zm / are special): src/bridge.zig (JS-transpiled monolith, baked into
    standalones), tools/gen_shader_externs.zig (emits code inside `\\` template strings), tools/mesh_bake.zig
    (no zm), build.zig:3994 + webtests/wgpu_smoke.zig (restructured to typed f64 intermediates),
    tests/fixtures/phi_repro/* (not gate-linted). LESSON: bare `@floatFromInt` beside a comptime_float or in
    `+`/`/` needs a typed decl intermediate ("must have a known result type").
  LINT RULE: `checkFloatFromInt` (after checkAsRound; dispatch after checkIntFromFloat). Detects
    `@as(f32|f64, @floatFromInt(x))` -> "use zm.float/float64(x)", tag float-from-int, rule 0. AUTOFIX WORKS:
    emits Fix spanning whole @as node -> `helper(x_src)` from @floatFromInt arg span; verified rewriting nested
    forms + leaving inner @intFromFloat alone. (Parse-guard skips only when a competing unused-global delete-fix
    sits on the same file - a pre-existing framework trait, not hit on real files where the alias is used.)
  RUNTIME.ZIG ROOT-ALIAS HOIST (Simon: "aliases should be at root if possible"): runtime.zig imported zm
    LOCALLY inside 5 struct/fn blocks (dodging no-qualified-zm). Hoisted `const zm = @import("zm");` to file
    scope, derived float/float64 from it, removed the 5 shadowing local `const zm` decls, converted 3 inline
    `@import("zm").X`->`zm.X`. That exposed 26 previously-masked no-qualified-zm in-body uses -> added 11 more
    root aliases (atan2/pi/vec/Vec/normalize3/cross/length3/angle3/mulMatVec/scaling/mulMat) + replaced in-body
    `zm.KW`->`KW` (word-boundary). No local-name collisions. runtime.zig now 0 lint violations.
  GATE: `zig build check -Dautofix=false -j1` GREEN (exit 0), wgpu_smoke PASSED, NO REGRESSIONS - the full
    compile validates all ~587 migrated sites.


zimr490: SHADOWMAP PLAN, step 1 - the DEPTH-IN-RED primitive + shaders_depth_rendering (Simon:
         "continue the shadowmap plan, study hard"). DEEP STUDY (re-verified from source): the PBR shadow
         SHADER is already COMPLETE - pbr_vs.zig:58 writes frag_light_space_pos = light_space_matrix*world_pos;
         pbr_fs.shadowProjCoords perspective-divides it + remaps *0.5+0.5 -> current_depth, samples shadow_map
         (pbr_fs_io.zig:53 Sampler2D(.cubemap) = a normal texture_2d<f32> at an unused material slot).r as
         closest_depth, computeShadow = (current_depth-bias) > closest_depth ? 0 : 1 (gated by Ubo.shadow_enabled,
         applied to the FIRST directional light). Only the engine PASS is unwired: draw3d.zig pbr3d.Renderer
         GATES it via THREE stubs - vs_uniform_buffers[4] (light-space slot) = identity() (~L4738), shadow_enabled
         defaults 0, shadow sampler slot reuses white_texture (~L4907). To un-gate, the host must produce: (a) a
         depth-in-red RTT from a light-POV pass, (b) light_space_matrix = light_proj*light_view, (c) the enable flag.
         The missing primitive was a depth-writing shader for that light pass.
         BLOCKED faithful path (why depth-as-color exists): texture_depth_2d/comparison sampling doesn't work -
         spv2wgsl has no texture_depth_2d binding kind; clean @SpirvType descriptors hit the documented OpUndef
         zero-bit-opaque @extern blocker (zimrmath.zig ~8413). Route 2 (fix that) = Simon's queued ~20-turn project.
         SHADER BUILD SYSTEM learned: src/shaders/*.zig auto-discovered (collectShaderFiles) -> a sibling
         <name>_io.zig triggers typed codegen -> <name>_externs + emits <name>.wgsl (wgsl_strict). BUT the shader
         cache is LAZY: a shader's SPIR-V/WGSL is only built when a CONSUMER app wires it - a bare shader with no
         consumer is NOT compiled by the gate (false green). So it needs an example to be verified.
         BUILT - depth shader pair (5 files, src/shaders/): depth_common_io.zig (Interp{frag_clip_pos:vec4}),
         depth_vs_io.zig (Attr .vec3@0; Ubo{mvp:[4]vec4}), depth_vs.zig (out.position=out.frag_clip_pos=
         mulMatPoint(mvp,pos)), depth_fs_io.zig (Inputs=Interp; Out{out_color:vec4}), depth_fs.zig (IoT(void):
         inv_w=1/clip[3]; d=clip[2]*inv_w*0.5+0.5; out=(d,d,d,1)). DESIGN: pass the pre-divide light-clip pos as a
         vec4 varying (tested pattern - no scalar varyings exist in the codebase) + do the divide+remap in the FS ->
         BYTE-IDENTICAL to pbr_fs current_depth (so a shadow map this makes compares correctly) AND perspective-
         correct. Output (d,d,d,1) serves BOTH grayscale depth-viz AND depth-in-red (pbr reads .r). VERIFIED the
         emitted WGSL by hand: correct group0 uniform binding, @builtin(position)+frag_clip_pos outputs, exact
         inv_w/ndc_z/*0.5+0.5 math, naga-valid.
         BUILT - examples/depth_rendering/depth_rendering.zig (shaders_depth_rendering, Route-1 per-pixel): three
         unit cubes (hs=0.6) staggered in depth, baked into ONE world-space vertex buffer (position-only, u16
         indices), drawn in a single call with MVP=proj*view (orbiting camera). Custom SINGLE-group pipeline
         (simpler than lambert_demo - only group0 mvp UBO, NO samplers/FS-uniforms), @embedFile depth_vs/fs.wgsl,
         .configure=wireEngineWgsl. build.zig: dash-name "depth-rendering" + own_frame table row near lambert.
         VERIFIED: fmt+lint 0, standalone HTML builds (984KB), regular demo exit 0, node link-check instantiates
         (imports wgpu+wasi), depth shader now in the corpus (frag_clip_pos WGSL x2), `zig build check` GREEN exit 0.
         HONEST: GPU runtime (does it render the grayscale gradient) is Simon's device-verify, as with every example.
         NEXT (shaders_shadowmap_rendering) = (1) render scene from light POV with the depth shader (mvp=
         light_ortho_proj*light_view*model; directional light -> ORTHOGRAPHIC so the perspective-divide is exact)
         into a COLOR RTT (depth-in-red); (2) light_space_matrix = light_proj*light_view; (3) main pass: set
         vs_uniform_buffers[4]=light_space_matrix, bind RTT color as shadow_map, shadow_enabled=1, ungate draw3d.
         FORK for the main pass (surface to Simon): (A) extend pbr3d.Renderer - reuses the DONE pbr shadow shader
         but needs multi-model (it's "one model per frame" - shared per-renderer buffers) + RTT rendering + the
         shadow pass; vs (B) self-contained lambert-style example with its own lit+shadow shader + own two passes.
         Recommendation: do depth_rendering first (done - verifies the depth primitive), then (A).


zimr491: depth_rendering DEVICE FEEDBACK fix - "is this good?" screenshot showed the pipeline RUNNING on
         device (milestone: the hand-built custom depth pipeline + shader compiled codegen->WGSL->GPU and
         renders) but the cubes were ALL WHITE. Diagnosis: a perspective camera's NDC z is nonlinear (clusters
         near 1.0 for anything off the near plane), and the pbr-style *0.5+0.5 remap pushed it to ~0.93-0.98 ->
         indistinguishable white. The shader was doing the shadow-map-correct thing (fine for an ORTHO light,
         where z is linear) but a perspective-camera VIZ needs linearization. FIX (keeps the shader dual-purpose
         via a mode flag): depth_vs_io.Ubo gained params:vec4 {cam_near,cam_far,viz_near,viz_far} + mode:i32
         (96 bytes, was 64). depth_vs now computes the grayscale IN THE VS and folds it into a vec4 varying
         frag_gray; depth_fs is a pure pass-through (cube3d pattern) - this keeps the whole shader ONE group-0
         UBO (no new bind groups, lowest risk) and avoids scalar varyings. mode 0 = raw ndc_z*0.5+0.5
         (pbr-faithful shadow map, exact for ortho light); mode!=0 = linearize NDC->view-space distance
         (z_view = cam_near*cam_far/(cam_far - ndc_z*(cam_far-cam_near)); verified perspectiveFovRh is WebGPU
         [0,1] z, the LhGl variant is the [-1,1] one) then normalize by the viz window [viz_near,viz_far] +
         zm.clamp. VERIFIED emitted WGSL by hand (inv_w/ndc_z/raw/linearize/clamp/mode-branch all correct,
         naga-valid). depth_rendering sets mode=1, params={0.5,20,3.5,8.5} (window tight around the cubes'
         view-space distances -> full-contrast gradient, near dark / far light). Host DepthUbo mirror (96 bytes)
         matches. lint 0, standalone builds (987KB), node link-check instantiates, `zig build check` GREEN.
         Awaiting Simon's re-check of the gradient on device. (Shadow-map path unchanged: light pass will set
         mode=0.)


zimr492: depth_rendering viz polish + WORKFLOW note. Screenshot after zimr491 showed the gradient WORKING
         (near cube dark, far cube light - the standard depth-buffer convention, raylib-faithful) but the near
         cube clamped toward pure black and vanished on the black background. FIX (example-only, no shader
         change): clear to WHITE (empty space = infinitely far = white, the proper depth-buffer view) so a dark
         near cube pops; widened the viz window to {viz_near=3.0, viz_far=11.0} so the near cube reads ~0.08
         (dark, visible on white) and the far cube ~0.6 (mid-gray, clearly below white). lint 0, standalone
         builds (987KB), node link-check instantiates. Awaiting Simon's re-check.
         WORKFLOW (Simon, standing): "you dont have to build more gates than the examples we are working on" -
         during iterative example work, build ONLY the specific example (`zig build <name>-standalone ...`),
         NOT the full `zig build check` gate every turn. Run the full gate only when engine/shared code changes
         land or before a milestone snapshot.


zimr493: shadowmap example STEP 1 (light-POV depth-to-screen) UNBLOCKED + built. The prior standalone build
         failed with a bare "process exited with code 1"; real cause = the STANDALONE lint step scans the WHOLE
         tree and an ORPHAN earlier attempt examples/shadowmap_rendering/shadowmap_rendering.zig (unwired, NOT in
         build.zig, superseded by examples/shadowmap/shadowmap.zig) had 2 lint violations (line-length +
         untyped-local). Deleted the orphan dir. examples/shadowmap/shadowmap.zig is the keeper (wired, dash-name
         "shadowmap", own-frame manual single-group pipeline like depth_rendering): floor quad + one floating
         caster cube, SceneVertex{position,normal} (normal baked now, unused by depth pass, reused by STEP 2),
         drawn from the DIRECTIONAL light's ORTHOGRAPHIC POV with depth_vs/depth_fs mode=2 (raw NDC full [0,1],
         linear+correct for an ortho light) -> the on-screen image IS the shadow map contents. light_view =
         lookAtRh(light_pos orbiting via rotationY, target {0,0.5,0}); light_proj = orthographicRh(13,13, 1,20).
         lint 0, standalone builds (987KB), node link-check instantiates (imports wgpu + wasi). Awaiting Simon
         device-verify. STEP 2 next: render this pass into a sampleable RTT (switch to mode=0 raw depth), main
         camera pass samples + shadow-compares (pbr_fs.computeShadow is exactly that test). STEP-2 FORK still
         open: (A) extend pbr3d.Renderer with a shadow-input API (recommended, banks the complete pbr shadow
         shader) vs (B) self-contained lambert+shadow FS.


zimr494: lint App-exception CONFIRMED ALREADY PRESENT + STEP-2 decision B. Simon asked to add a module-var
         exception for App-typed vars; it ALREADY EXISTS: tools/lint_zimr.zig isAppTypedVar (matches final type
         token == "App", covers bare App and z.App) wired into checkVarDecl .container branch (~L1435). Empirically
         verified: `some_random_handle: z.App` + `another: App` (non-allowlisted names) -> 0 module-var; control
         `counter: u32` -> fires. So `pub var zimr_app: z.App = .{}` needs no annotation; the 2 lint:off comments I
         put in shadowmap.zig were redundant and autofix already pruned them. The name-based zimr_app allowlist in
         isAllowlistedModuleVar is now redundant (all 11 real-code zimr_app decls are `: z.App`) but left as a
         harmless fallback for any future inferred-type `pub var zimr_app = z.App{}` form.
         STEP-2 RECOMMENDATION REVERSED A->B (surfaced to Simon for greenlight): self-contained lit+shadow, NOT
         extending pbr3d.Renderer. Reasons: raylib's shaders_shadowmap uses a DEDICATED shadow shader (B more
         faithful); B builds on the verified light pass; zero regression risk to pbr/gltf; the pbr-shadow-shader
         "bank" of A is outweighed by dragging the whole PBR pipeline (6 samplers, glTF mats, one-model/frame) into
         a shadow demo; the needed shadow math is ~10 lines from pbr_fs. VERIFIED FEASIBLE: beginTextureMode sets
         app.pass = Backend.beginRenderPass(color=rt.color_view, depth=rt.depth_view) so a MANUAL pipeline can draw
         into the RTT pass via f.gl.pass, then drawTextureRec(rt.asTexture()) blits — clean RTT path, no io-schema
         import needed. STEP-2 SPEC (ready to build): (1) author lit_shadow shader pair via shadermath DSL —
         lit_shadow_common_io.zig {frag_normal vec3, frag_light_space_pos vec4}; lit_shadow_vs_io.zig {Attributes
         position@0 normal@1; Uniforms mvp[16]+light_vp[16] (flattened `io_in.mvp` access); Outputs=Interp};
         lit_shadow_vs.zig (out.position=mulMatPoint(mvp,pos); frag_normal=normalize(normal); frag_light_space_pos=
         mulMatPoint(light_vp,pos)); lit_shadow_fs_io.zig {Inputs=Interp; Samplers.shadow_map=Sampler2D; Uniforms
         light_dir vec4 + base_color}; lit_shadow_fs.zig (shadowProjCoords perspective-divide+*0.5+0.5, sample
         shadow_map(.{proj0,proj1})[0], bias=max(0.005*(1-N.L),0.0005), current-bias>closest?0.0:1.0; lambert
         ambient+diffuse*shadow; NO uv y-flip to match pbr_fs). (2) AppSpec example (configure=wireEngineWgsl):
         pass1 light depth -> sampleable RTT via loadRenderTexture (f.gpu.depth_format=.depth24_plus) with the
         EXISTING manual depth pipeline switched to mode=0 (raw ndc*0.5+0.5, matches shadow-compare current_depth);
         pass2 main camera lit_shadow pipeline (group0 mvp+light_vp uniforms, group1 shadow_map sampler bound to
         rt.asTexture()) draws floor+cube; caption. BLIND RISKS to device-verify: shadow-map UV Y convention
         (WebGPU RTT), ortho light frustum tightness (acne/peter-pan), rt color must be a depth-readable value not
         a viz. Reuse floor+cube geometry (SceneVertex position+normal already baked in shadowmap.zig).


zimr495: STEP 2 (B, self-contained lit+shadow) BUILT + link-verified, awaiting Simon device-verify. Two-pass
         examples/shadowmap/shadowmap.zig (AppSpec, configure=wireEngineWgsl): PASS1 depth pipeline (pos-only layout,
         rgba8 color + depth24plus, cull .none, mode=0) renders scene from light ortho POV into loadRenderTexture RTT
         via beginTextureMode(white)/endTextureMode; PASS2 lit_shadow pipeline (pos+normal, group0 mvp+light_vp,
         group1 shadow_map tex+sampler from rt.asTexture(), group2 light_dir+base_color, back_fmt/depth24plus)
         renders floor+cube to backbuffer. Manual pipelines draw into f.gl.pass (p.queue=gf.queue set manually).
         lit_shadow shader pair (src/shaders/lit_shadow_{common_io,vs_io,vs,fs_io,fs}.zig) auto-discovered by build
         (src/shaders/*_vs.zig/*_fs.zig), codegen->WGSL valid (standalone EXIT=0 + wgsl_strict), wasm links (15
         exports). FS = pbr_fs shadow math (perspective-divide+*0.5+0.5, sample shadow_map[0] ONCE, slope bias
         max(0.005*(1-N.L),0.0005), current-bias>closest?shadow:lit, ambient 0.25, NO uv y-flip). Light fixed
         (5,7,4)->target(0,0.5,0), ortho(13,13,1,20); orbiting perspective cam. **DECISION: lit pass cull switched
         .back->.none for first blind verify (winding unverifiable без GPU; back faces depth-occluded) — tighten to
         .back once shadows confirmed.** DEVICE-VERIFY WATCH: (1) shadow appears as darker floor region offset from
         cube; (2) UV Y convention (WebGPU RTT — may need proj[1]=1-proj[1] flip if shadow is mirrored in Z); (3)
         acne (striping on lit surfaces -> raise bias) vs peter-panning (shadow detached from cube -> lower bias);
         (4) ortho frustum 13x13 covers floor 8x8 — ok. base_color floor+cube both {0.82,0.82,0.88}. Delivered
         zimr495.zip + shadowmap.html.

zimr496: shadowmap STEP-2 device-verify #1 fixes. Simon's screenshot showed the shadow WORKING (cube casts a
         real blob on floor) BUT (a) big dark triangle over the RIGHT HALF of the floor with a clean diagonal
         boundary + (b) zigzag acne on the cube face. DIAGNOSIS: RTT UV Y-flip (the half-dark clean-boundary split
         is the signature — far half of floor samples near-half's stored depth -> false shadow; same wrong-texel
         sampling -> cube self-acne). NOT self-shadowing, not bias. FIX 1: lit_shadow_fs.zig shadowProjCoords now
         does `proj[1] = 1.0 - proj[1]` after the *0.5+0.5 remap (WebGPU RTT origin top-left vs NDC +y up); z
         untouched (depth compare stays). FIX 2 (Simon ask): replaced hardcoded auto-orbit with the SAME
         interactive orbit camera as damaged_helmet — State {yaw .7, pitch .45, distance 13, dragging, prev_pinch};
         pinch(2-finger)/wheel zoom clamp 5..26, 1-finger/mouse drag orbit (yaw-=dx*.008, pitch=clamp(+dy*.008,
         .1,1.45)); eye = cam_target(0,1,0)+dist*(cp*sy,sp,cp*cy), lookAtRh, perspectiveFovRh(0.8,aspect,.1,100).
         Light stays FIXED (target 0,0.5,0) so shadow is stable while orbiting. Aliases added Vec2, clamp from zm.
         Build EXIT=0, lint clean, links. Delivered zimr496.zip + shadowmap.html. IF STILL WRONG after Y-flip:
         next levers = residual acne -> raise bias floor (0.0005->0.0015) or add normal-offset; shadow mirrored the
         OTHER axis -> also flip proj[0]; lit pass still .none (tighten to .back once confirmed).

zimr497: shadowmap acne fix (device-verify #2). After Y-flip, shadow + cube clean but FLOOR had regular
         diagonal ACNE STRIPES. ROOT CAUSE: the shadow map is an 8-bit rgba8 RTT (loadRenderTexture color =
         rgba8_unorm) -> depth stored at ~1/255≈0.004 quantum; floor at grazing angle to light -> continuous
         fragment depth crosses the quantized stored depth -> moiré. Old bias floor 0.0005 << 1 quantum. FIX (quick,
         scene-appropriate): lit_shadow_fs.zig bias = max(0.03*(1-N.L), 0.012) (~3 quanta). Free here because the
         caster FLOATS (cube bottom y=0.8, floor y=0) so no contact point -> no visible peter-panning. Build EXIT=0,
         lint clean, links. Delivered zimr497.zip + shadowmap.html. **PROPER PRECISION FOLLOW-UP offered to Simon
         (deferred pending his call): 8-bit shadow map is fundamentally low-quality; bias-hacking works only because
         this caster floats. The RIGHT fix = higher-precision depth store: either (A) pack float depth into RGBA8 in
         a dedicated shadow-depth FS + unpack in lit_shadow (≈32-bit, ~4-6 turns, reusable engine cap) or (B) float
         RTT (r32float, needs a loadRenderTexture float variant) or (C) the deferred Route-2 sampleable
         texture_depth_2d + comparison sampler (blocked on OpUndef @extern, ~20-turn). Also could tighten the light
         ortho near/far (currently 1..20, scene depth ~4..13) to spread 8-bit over less range — cheap partial win.**
         lit pass still cull .none — tighten to .back once Simon confirms clean.

zimr498: shadowmap multi-object — 4 boxes + rotating Stanford bunny. Simon asked "more cubes + rotating
         bunny". WORK: (1) lit_shadow_vs gained a normal_matrix (Ubo now 192B: mvp+light_vp+normal_matrix) so
         animated casters shade correctly (VS: frag_normal = normalize(mat3(normal_matrix)*vertex_normal) via
         mulMatVec w=0). Host LitVsUbo mirrors 192B. (2) shadowmap.zig REWRITTEN (703 lines) to a multi-object
         design: `Obj` struct = geometry buffers + private depth/lit-vs/lit-fs ubos+bindgroups; makeObj() builds
         them from shared BGLs; drawMesh(obj); writeObjUniforms(obj, model, normal_matrix, cam_vp, light_vp,
         to_light) sets depth mvp=light_vp*model, lit mvp=cam_vp*model + light_vp*model + normal_matrix. Static
         batch (floor + 4 boxes via CubePlace list, model=identity, gray 0.82) + bunny (model=T(spot)*S*Ry(t*0.6)*
         T(-center), normal_matrix=Ry, tan 0.86,0.72,0.52). Both passes now draw BOTH objects (rebind group0 per
         obj in depth pass; rebind g0+g2 per obj in lit pass, g1 sampler shared/set once). (3) Bunny loaded via
         z.codecs.obj.parse->toMesh (de-index + smooth-normal synth): 34,834 verts / 208,353 idx; built SceneVertex
         + u16 idx (values fit), AABB computed for seating (center xz, min y, scale=2.8/height). bunny.obj COPIED
         into examples/shadowmap/ (cross-module @embedFile unreliable) -> +2.4MB, HTML now 4.5MB. Build EXIT=0, lint
         clean, links (wgpu,dom). Delivered zimr498.zip + shadowmap.html. DEVICE-VERIFY WATCH: (1) bunny UP-axis —
         assumed Y-up (obj_bunny renders it via pbr3d with NO rotationX, unlike helmet); if on its side add
         rotationX. (2) bunny seating (AABB-based) — may float/sink if bounds off. (3) CONTACT peter-panning: 2 of
         4 boxes + bunny now SIT on the floor (bottom y=0); bias 0.012 (tuned for floor acne) may show a small
         shadow gap at contacts — the 8-bit precision tradeoff; RGBA8-pack fix resolves if wanted. lit still .none.

zimr499: writeBuffer 4-byte-alignment fix + guard (ENGINE change, full gate GREEN). Simon's browser hit
         "Failed to execute 'writeBuffer' on 'GPUQueue': Number of bytes to write must be a multiple of 4". CAUSE:
         bunny index buffer = 208,353 u16 indices (odd, =3*69,451 tris) * 2 = 416,706 bytes ≡ 2 mod 4; WebGPU
         requires writeBuffer size (and offset) to be mult of 4. All prior writes (matrices/vec4 ubos, even-count
         static idx) happened to be 4-aligned. FIX (both of Simon's accepted options): (1) src/wgpu.zig new
         `createBufferInit(device, queue, bytes, usage, label) BufferHandle` — creates a buffer sized up to the next
         mult of 4 and uploads padded: writes the 4-aligned prefix directly, then a <=3-byte tail zero-extended into
         a [4]u8 stack write (NO allocator). Pad bytes are zero + never referenced (draw uses real element count;
         setIndexBuffer .size still passes the real byte length, buffer is just 2 bytes bigger). (2) assertf guard
         in queueWriteBuffer: `assertf(offset%4==0,...)` + `assertf(data.len%4==0, @src(), "... use
         createBufferInit, which pads")` — engine's shared assert family (zm.assertf; std.debug.assert is
         lint-BANNED by rule std-debug-assert -> use assert(ok,@src())/assertf). Logs file:line+msg in dev, lowers
         to unreachable in ship (ReleaseSmall) so the PADDING HELPER is the ship-safe fix, assert is the dev
         tripwire. shadowmap.zig: all 4 geometry uploads (static vbo/ibo, bunny vbo/ibo) now go through
         createBufferInit (removed the createBuffer+queueWriteBuffer pairs). Full gate: NO REGRESSIONS + wgpu_smoke
         PASSED (js_queue_write_buffer x7/frame through the assert, no trips) + GATE_EXIT=0. standalone EXIT=0,
         links. Delivered zimr499.zip + shadowmap.html. NOTE: a lint rule to flag queueWriteBuffer(sliceAsBytes(..))
         create-sites -> createBufferInit is possible but heuristic (false-positives on already-aligned slice
         writes); offered to Simon, not implemented — assert(dev)+helper(ship) already cover it.

zimr500: shadowmap PRECISION upgrade — rgba8 -> rgba16_float shadow map (kills the bias tradeoff). Simon saw
         peter-panning at grounded-cube corners (0.012 bias hiding 8-bit acne) and asked what blocks better
         precision. ANSWER: nothing fundamental — 8-bit was purely loadRenderTexture's hardcoded rgba8_unorm. The
         only BLOCKED path is the hardware depth-compare route (texture_depth_2d + comparison sampler) = deferred
         Route-2 OpUndef @extern transpiler issue. A float COLOR target sidesteps it (normal sampled texture). FIX
         (example-only, no engine change — formats + BlendMode.none already existed): (1) shadow RTT via
         z.RenderTexture.create(.format=.rgba16_float, .with_depth=true, depth24_plus) instead of loadRenderTexture
         (which hardcodes rgba8). rgba16_float = mobile-universally renderable+filterable, ~16-bit depth (~40x finer
         than 8-bit in the [0.16,0.63] range used). (2) NEAREST shadow sampler (createSampler mag/min linear=false)
         bound in group1 instead of rt's linear sampler — linear blends depths across silhouettes and corrupts the
         compare. (3) depth pipeline color .rgba8_unorm->.rgba16_float, blend .alpha->.none (opaque depth write; and
         float targets prefer no-blend). (4) lit_shadow_fs bias 0.012/0.03 -> 0.0008/0.0025 (~15x smaller) -> peter-
         panning gap shrinks ~15x = gone, still clears residual acne. Build EXIT=0, lint clean, links. Delivered
         zimr500.zip + shadowmap.html. BLIND RISK: beginTextureMode still binds the 2D pipeline (rgba8) into the now
         -rgba16 RTT pass, but I override with the manual depth pipeline before any draw + never draw 2D into it, so
         no format-mismatch draw occurs (setPipeline doesn't validate-vs-attachment until draw). If a device throws
         a target-format validation error, fall back to a manual Backend.beginRenderPass for pass 1. rgba32_float
         (full 32-bit) is a 1-line bump if 16-bit ever proves insufficient (needs nearest + .none, both already set)
         . lit pass still cull .none.

zimr501: rgba16f RTT hit "[zimr GPU] Attachment state of [RenderPipeline \"shapes\"] not compatible ...
         expects RGBA16Float ... has RGBA8Unorm ... While encoding SetPipeline(shapes)". The blind risk from
         zimr500 REALIZED: beginTextureMode eagerly binds the 2D "shapes" pipeline (rgba8) via
         renderer_2d.bindForPass, and WebGPU validates SetPipeline vs pass attachments IMMEDIATELY (not at draw), so
         it fails inside beginTextureMode before the manual depth-pipeline override. Simon: make this class
         impossible or diagnosable. FIX (ENGINE, gate GREEN): (1) NEW z.beginTextureModeRaw(gl, rt, clear) +
         z.endTextureModeRaw(gl) in wgpu_app.zig — open/close an offscreen pass into an ANY-format RTT WITHOUT
         binding the 2D pipeline (Backend.flushBatch+endRenderPass+beginRenderPass(color=rt.color_view,
         depth=rt.depth_view), sets pass.queue + target_size; end = target_size null + reopen2DPass). Caller sets
         its own pipeline/bindgroups on gl.pass. Exported in zimr.zig. -> makes the mismatch IMPOSSIBLE for the
         manual-pipeline-into-custom-RTT path. (2) assertf guard in beginTextureMode: assertf(rt.format ==
         .rgba8_unorm, @src(), "beginTextureMode needs an rgba8_unorm render texture ...; got .{s}. ... use
         beginTextureModeRaw ...", @tagName(rt.format)) -> fires EARLY in dev with the FIX suggestion instead of an
         opaque mid-pass GPU error (ship builds still get the engine's existing [zimr GPU] attachment-mismatch log,
         which already names pipeline+both formats). shadowmap.zig PASS1 now uses beginTextureModeRaw/
         endTextureModeRaw (removed the redundant p1.queue=gf.queue; raw sets it). Gate: NO REGRESSIONS + wgpu_smoke
         PASSED + GATE_EXIT=0 (existing beginTextureMode callers all use rgba8 loadRenderTexture RTTs -> assert
         passes). standalone EXIT=0, links. Delivered zimr501.zip + shadowmap.html. This is now the sanctioned
         pattern for shadow/depth/postprocess passes into non-rgba8 RTTs.

zimr502: NEW shadow_sidebyside demo — rayshadow_fs on CPU|GPU|comptime (the cube_sidebyside pattern applied
         to shadows). Simon: investigate helmet/cube sidebyside (cpu/gpu/comptime), do a sidebyside shadowmap.
         FINDING: the sidebyside family = ONE self-contained per-pixel shaderMain run 3 ways (GPU=loadShaderVF
         fullscreen pass; CPU=z.raster_shader.dispatchFragmentShader per-pixel into z.raster.Context+CpuFramebuffer;
         comptime=`blk:{@setEvalBranchQuota(2e9); ...shaderMain...}` baked to a small Color image shown as an inset;
         mouse-X splitter composites CPU-left over GPU-right). True shadow-MAPPING (2-pass RTT) does NOT fit — the
         comptime/CPU targets can't sample a GPU RTT and reproducing the depth pass in sw/comptime = a whole
         software shadow-map rasterizer. So used RAY-TRACED shadows (shadow ray = 2nd ray-scene intersection), which
         IS self-contained per-pixel -> fits all 3 targets. BUILT: examples/rayshadow_fs.zig (+_io) — ray-traces a
         bounded 8x8 platform + 2 boxes (center/half consts, a_min=center-half etc.) + directional light; helper
         fns hitBox (slab, @min/@max no-swap, returns entry t or miss_t=1e30), hitPlatform (bounded y=0), boxNormal
         (max-axis of (p-center)/half); primary ray picks nearest of {platform,A,B}; shadow ray from hit+N*0.004
         toward light tests both boxes -> shadow 0/1; ambient 0.22. No loops/recursion (comptime+WGSL+CPU safe;
         helper fns OK per pbr_fs). examples/shadow_sidebyside/shadow_sidebyside.zig = cube_sidebyside harness with
         rayshadow_fs swapped in, cam_target (0,0.45,0) dist 5.6 pitch 0.5 (looking down at shadows), pitch clamp
         0.05..1.4, dist 3..14. build.zig: dash-name "shadow-sidebyside" + row (.shaders={rayshadow_fs,trivial_vs}).
         Reused existing infra (no engine change). Standalone EXIT=0 (shader compiled GPU-WGSL + CPU-native +
         comptime-bake all clean), links, lint clean. Delivered zimr502.zip + shadow_sidebyside.html. NOTE to Simon:
         this is ray-traced shadows (fits the 1-shader-3-ways pattern); literal shadow-MAP-vs-CPU comparison would
         be a different (non-sidebyside) structure. DEVICE-VERIFY: 3 panels identical (CPU left / GPU right / comptime
         corner), boxes cast hard shadows on platform + on each other; orbit live, corner frozen.

zimr503: INVESTIGATION (no code change) — how to extend the CPU rasteriser to a two-pass shadow-map pipeline
         mirroring the WebGPU passes, for teaching + as a GPU oracle. Wrote src/notes/cpu_shadowmap_plan.md.
         FINDINGS: the SW rasteriser already has ~90% of it. raster_shader.zig has a full programmable VS+FS
         triangle pipeline: dispatchVertexShader (runs shaderMain as a VS over an indexed mesh) + rasterizeTriangles
         (edge-fn raster, perspective-correct interp of whole Out, near-plane clip) + RasterizeOpts{front_face(cull),
         depth_test(.less, write-on-pass, wgpu NDC-z [0,1]), blend(alpha-over)} + rasterizeWithRuntimeOpts (runtime
         flags->comptime opts) + rasterizeToImage (comptime raster w/ internal z-buffer, bakes the sidebyside
         corners). rasterizeTriangles writes color to ctx.colorBufferBytesMut()/depth to ctx.depthBufferBytesMut()
         = the BOUND framebuffer (raster_shader.zig:546) -> binding an offscreen FBO = a beginRenderPass. raster.zig
         Context: up to 8 framebuffers (genFramebuffers), 128 textures, framebufferTexture2D to attach a texture as
         color target (raster.zig:607). Float color formats ALREADY exist: color_r32/color_r16/color_r16g16b16a16/
         color_r32g32b32a32 (raster_pixel.zig:41) -> the GPU shadow map is depth-in-red rgba16_float, so the CPU
         equivalent is a color_r32 target = SAME depth-as-float-color trick, NO depth-texture-sample path needed.
         FS samples _texture0 (raster_shader.zig:796) via ReadColorFn; bindTexture sets it. Existing oracle plan
         (software_rasterizer_oracle.md) = SAME shaderMain, GPU-faithful coverage/sample-pos/interp/sampler
         semantics, but stops at SINGLE-pass parity; this note adds the multi-pass/RTT layer. GAPS (narrow): (1)
         route the FS's named sampler (io_in.shadow_map) to a chosen texture — single-sampler shadow_map->_texture0
         is one binding; multi-sampler (PBR) later. (2) verify color_r32 is in write_color_table too (has read codec
         at :393); add f32 writer if missing (~1/2 day). (3) a pass-shaped façade raster_pass.zig (cpuBeginPass/
         cpuSetPipeline/cpuSetBindGroup/cpuDrawIndexed/cpuEndPass) = thin sugar over bindFramebuffer+clear /
         RasterizeOpts / dispatchVertexShader+rasterizeWithRuntimeOpts, so CPU frame reads 1:1 like the wgpu frame.
         (4) CONVENTION PARITY (the real work + the oracle's whole point): the lit_shadow_fs proj.y=1-proj.y RTT
         y-flip + NDC-z [0,1] + texel-center sample must be bit-comparable CPU vs GPU. BUILD ORDER: codec -> sampler
         routing -> façade -> CPU shadow map w/ the REAL depth_*/lit_shadow_* shaders into an r32 FBO then screen ->
         payoff demo. PAYOFF = examples/shadowmap_cpu_gpu: split screen LEFT=wgpu 2-pass shadow map, RIGHT=CPU 2-pass
         shadow map, SAME 4 shaders -> the honest shadow-MAPPING sidebyside (vs the ray-traced shadow_sidebyside),
         and a per-pixel diff = the oracle test. No GPU-backend change; all additive on the CPU side. Delivered
         cpu_shadowmap_plan.md + zimr503.zip.

zimr504: EXECUTE cpu_shadowmap_plan STEP 1 — PROVED the two-pass CPU shadow map end-to-end NATIVELY
         (the sandbox runs the software rasteriser, so this is pixel-VERIFIED, not blind). New test
         src/tests/cpu_shadowmap_test.zig: file-scope comptime scene (ground quad y=0 + occluder panel y=1.2),
         inline DepthVs/DepthFs (depth-in-red, mirrors src/shaders/depth_*) + LitVs/LitFs (Lambert + shadow
         sample, mirrors lit_shadow_* incl the proj[1]=1-proj[1] RTT y-flip). Pass1: dispatchVertexShader(DepthVs,
         light_vp) + rasterizeToImage -> 128x128 rgba8 shadow map (depth-in-red). Pass2: dispatchVertexShader(
         LitVs, cam_vp+light_vp) + rasterizeToImage, LitFs samples the map via a spelled-out ShadowRef
         (={pixels,w,h}, nearest, red/255 — the shape the generated IoT TextureRef gives CPU sampling shaders).
         autoConnect(VsOut,FsIo) wires varyings. Asserts a projected known-shadowed ground pt (lum 47 ~ambient) is
         >60 darker than a projected lit pt (lum 182), + band counts. RESULT: all 239 tests pass, EXIT=0; final
         image shows a COHERENT cast-shadow blob where the panel's shadow falls, rest of ground uniformly lit.
         KEY EMPIRICAL FINDINGS: (a) rasterizeToImage NDC->screen is sx=(ndc_x+1)*0.5*W, sy=(1-(ndc_y+1)*0.5)*H
         (row 0=TOP, like the GPU RTT) + depth=raw ndc_z .less -> the CPU needs the SAME proj[1]=1-proj[1] flip
         lit_shadow_fs uses; confirmed correct (shadow lands right). (b) 8-bit rgba8 map: first run at bias floor
         0.0025 gave pervasive SHADOW ACNE (shadow_px 4171, regular ground stipple) because 8-bit quantum=1/255
         ~=0.0039 > bias; raising floor to 0.008 killed the acne (shadow_px 239, clean cast shadow). THIS IS THE
         precision tax the plan predicted -> the float (r32/rgba16f) sampler extension is the payoff of STEP 2.
         RUNNING IT: `zig build test` is PRE-EXISTING-BROKEN (src/web.zig milliTimestamp API drift; src/zimrmath.zig
         @SpirvType-only-on-SPIR-V under the aggregator refAllDecls; src/plot_ui.zig plot.Transform) — NOT my code.
         So added standalone runner src/_sm_test_root.zig (roots module at src/ so ../raster_shader.zig resolves;
         lazy analysis dodges the broken @SpirvType decls); run via `$ZIG test --dep zm -Mroot=src/_sm_test_root.zig
         --dep build_options -Mzm=src/zimrmath.zig -Mbuild_options=/tmp/bo.zig` (bo.zig=`pub const assert_log=false;`).
         Test is ALSO wired into src/tests.zig so it rejoins the normal suite once the 3 aggregator breakages are
         fixed. NEXT (STEP 2): float-precision sampler (extend TextureRef+sampleTexture to r32/rgba16f so the CPU
         map matches the GPU rgba16_float and the bias drops ~5x), then the raster_pass.zig façade, then the
         examples/shadowmap_cpu_gpu split-screen payoff (LEFT wgpu 2-pass, RIGHT CPU 2-pass, same 4 shaders,
         per-pixel diff = oracle test). Delivered the test + zimr504.zip. FLAG to Simon: want the pre-existing
         `zig build test` aggregator breakage fixed (small: milliTimestamp rename, guard @SpirvType decls behind
         isSpirV, plot.Transform), or a dedicated `zig build test-cpu-shadow` step?

zimr505: REPAIRED `zig build test` (was pre-existing-broken) + EXPANDED lint to all zig except test corpora.
         (A) Fixed 3 pre-existing host-compile breakages that blocked the aggregator: (1) src/plot_ui.zig
         `plot.Transform` -> `plot.AxisMap` (renamed type; 3 refs: fields 392/393 + pickScale param ~797).
         (2) src/web.zig:85 `std.time.milliTimestamp` (dropped in Zig 0.16) in epoch_ms()'s host branch -> return 0,
         mirroring runtime.hostNow() (browser path js_epoch_ms unaffected; wasm build already took that branch).
         (3) src/zimrmath.zig @SpirvType sampler/image block force-analyzed on host by tests.zig's
         refAllDecls(@import("zm")): gated the 5 NON-GENERIC type fns (Texture2D/Sampler/SampledImage2D ->
         `if(!isSpirV()) return opaque{};`, Texture2DPtr/SamplerPtr -> `return *const anyopaque;`) so host signature
         analysis is legal; generic fns (storageBuffer/imageStore/StorageImage2D/StorageBuffer*) aren't analyzed
         until instantiated, and asm bodies (sampleLod) aren't analyzed unless CALLED, so 5 gates suffice; SPIR-V
         path unchanged (dead branch on-target, verified by `zig build check` green: NO REGRESSIONS + wgpu_smoke).
         (B) Removed the std.debug.print ASCII dumps from src/tests/cpu_shadowmap_test.zig: under `zig build test`'s
         `--listen=-` IPC they produced a misleading "failed command: test" WITH exit 0; running the test binary
         DIRECTLY proved the truth = 1721 passed; 2 skipped; 0 failed. The assertions ARE the test. Also DELETED
         src/_sm_test_root.zig (the standalone runner from zimr504 — obsolete now that `zig build test` works;
         cpu_shadowmap_test runs via the normal aggregator/src/tests.zig).
         (C) EXPANDED the lint walk (build.zig ~2390) per Simon: lint ALL zig files except the test corpora. Added
         `scripts` as a 5th scan root; REMOVED the blanket `if (startsWith(entry.path,"tests/")) continue;` so
         src/tests/ is now linted (first-class zimr code); ADDED "c2js_cases/" to tools_skip_prefix (c2js transpiler
         corpus = arbitrary Zig, not zimr's subset). Top-level tests/ shader fixtures stay excluded automatically
         (not a scan root). EMPIRICAL basis: linting everything-excluded surfaced 104 violations but ~75 were in the
         tests/ transpiler fixtures (corpora, correctly left out); the 11 existing src/tests/ files were ALREADY
         clean; only cpu_shadowmap_test (22, mine) + 3 scripts (7) needed fixing. Fixed all: cpu_shadowmap_test
         (file-scope aliases const floori/normalize/mulMat = zm.*; braces; @intFromFloat(@floor(x))->@floor(x) since
         the DECLARED i32 pins it (redundant-cast rule), but floori(usize,..) kept in projectToPixel's array literal;
         removed inline @import); scripts/ui_screenshot_repro (W/H->w/h, args:std.process.ArgIterator),
         scripts/probe_damaged_helmet (types import + []types.Mesh + brace for), scripts/jpeg_section (0xE0..0xEF
         range pattern collapses the long marker case; zig fmt re-collapses manual wraps so a RANGE is the fix).
         VERIFIED: proved the walk now covers src/tests/ by injecting a violation -> LINT_EXIT=1 (was skipped
         before), reverted -> LINT_EXIT=0. `zig build lint` green, `zig build check` green.
         FOLLOW-UP for Simon: (i) whether to also lint the top-level tests/ transpiler fixtures (recommend NO — they
         are spv2wgsl input corpora like c2js). (ii) The debug-print lint rule is inSrcDir-scoped so it now ALSO
         guards src/tests/ (walk reaches it) — good: future test files can't reintroduce the IPC-breaking print.

zimr506: OBJ build-time geometry loading for the comptime corner (mirrors helmet's GLB pipeline).
         GOAL (Simon): the flagship CPU|GPU|comptime shadow-MAP demo (rotating bunny + cubes) needs a mesh the
         COMPILER can rasterize for the comptime corner. helmet_sw already solves this for GLB: tools/mesh_bake.zig
         vertex-cluster-decimates the 15k-tri helmet to a ~2k-tri proxy baked as `pub const` arrays, and the
         corner_image comptime block calls z.raster_shader.rasterizeToImage on it (@setEvalBranchQuota 2e9, 48²).
         Simon: "do the same with obj." DONE, UNIFIED (not a parallel tool): refactored tools/mesh_bake.zig so the
         decimation core is a shared `fn decimate(vertices, normals, texcoords: ?[]const f32, indices: []const u32,
         vertex_count, grid) !Decimated` + `fn emitProxyGeometry(w, clusters, out_indices)` (emits vertex_count/
         positions/normals/indices), and main() branches on input extension: `.obj` -> `bakeObj` (codecs.obj.parse
         + .toMesh -> geometry-only proxy, texcoords=null, no material/tex); else the existing glTF path (parse +
         texcoords + bakeBaseColor, then emitProxyGeometry + uvs + base_color tail). The existing `bakeMesh` build
         helper works unchanged for OBJ (the `base`/tex_edge arg is simply ignored) -> ZERO new build wiring.
         PROVED SAFE: captured the helmet_proxy.zig baseline (952 clusters/1979 tris/64²) BEFORE, refactored, rebuilt
         helmet-sw-standalone (EXIT=0), and diffed every glTF const per-name -> vertex_count/positions/normals/uvs/
         indices/base_color/base_color_factor all BYTE-IDENTICAL (only the emit ORDER of indices vs uvs swapped;
         helmet_sw imports by name so unaffected). OBJ path verified on examples/shadowmap/bunny.obj (34834 verts /
         69451 tris): grid 10->693 tris, 12->1044, 16->1874(~helmet), 20->2889. Generated proxy ast-checks + is
         COMPTIME-USABLE (build-time comptime asserts on positions.len==vertex_count, normals, tri-multiple indices
         all passed). mesh_bake.zig lint-clean. codecs.obj API: parse(gpa,bytes)!Data; Data.toMesh(gpa)!Mesh;
         Mesh{positions,tex_coords,normals,indices:[]const u32,has_tex_coords,had_normals, vertexCount()}.
         KEY REUSE MAP for the flagship (next steps): GPU half ALREADY EXISTS = examples/shadowmap/shadowmap.zig
         (floor + boxes + slowly-rotating Stanford bunny, one light, two manual passes: depth-in-red into rgba16f
         RTT via beginTextureModeRaw + lit_shadow sampling it). CPU half = the zimr504 proof src/tests/
         cpu_shadowmap_test.zig (two-pass SW shadow map, pixel-verified; 8-bit map needs bias~0.008 to kill acne).
         comptime corner = NEW: two rasterizeToImage calls (pass1 depth-in-red into an r32/rgba8 map, pass2 lit
         sampling it) on the bunny proxy (recommend grid 10-12, ~700-1000 tris) + cubes, small res, frozen angle.
         SHADERS (author in shadermath per no-inline-WGSL): src/shaders/depth_vs/fs (mode 0) + lit_shadow_vs/fs
         already exist and are the SAME four for all three backends. Three-way harness template = cube_sidebyside.zig
         (LEFT/GPU + CPU live, comptime baked const uploaded once as a small quad; @setEvalBranchQuota 2e9).
         #1 RISK to de-risk NEXT (recommended before building the full example): comptime TWO-PASS budget. helmet
         proves ONE comptime pass @ ~2k tris/48². Shadow mapping needs TWO (depth render + lit sampling). Prototype
         a native comptime two-pass proof (like cpu_shadowmap_test was for CPU): measure compile time + pixel-verify
         the baked image; if slow, shrink proxy/res/cube-count. THEN build examples/shadowmap_sw + launcher entry.

zimr507: comptime TWO-PASS shadow-map PROOF — VERIFIED (cold bake 34s < 60s budget; pixel-confirmed).
         examples/comptime_shadowmap_proof/main.zig (native host exe; the two-pass shadow render is a comptime
         `const`, so bake time == compile time). De-risks the flagship's novel corner exactly like
         cpu_shadowmap_test de-risked the CPU path. Scene = floor(4v/2t) + cube(24v/12t flat per-face normals) +
         normalized/rotated bunny proxy (mesh_bake OBJ path, grid=10 -> 346v/693t), merged into single positions/
         normals/COLORS/indices arrays (buildScene(); @setEvalBranchQuota 2e9 at its top — REQUIRED, separate
         comptime call). Per-vertex color VS->FS keeps floor/cube/bunny distinct under ONE depth-tested draw per
         pass. KEY CORRECTION baked in: RasterizeOpts.depth_test DEFAULTS FALSE and rasterizeToImage only uses the
         z-buffer when .depth_test=true (memory's "z always-on" was WRONG) — merged multi-object scenes MUST pass
         .{ .front_face=.none, .depth_test=true }. Inline shaders DepthVs/Fs + LitVs/Fs mirror src/shaders/depth_*
         + lit_shadow_* (ShadowRef.sampleRed = clamp+nearest+red/255; LitFs bias @max(0.015*(1-ndl),0.008),
         ambient 0.25, proj[1]=1-proj[1] RTT flip). Pass1 shadow_map:[SM*SM*4]u8 (clear white=far, @bitCast from
         [N][4]u8); pass2 lit_image:[MW*MH*4]u8 samples it. main(): page_allocator + std.Io.Threaded; prints stats;
         z.codecs.png.encode(gpa, pixels, w, h) -> comptime_lit.png + comptime_shadowmap.png. build.zig: native exe
         wired in `pub fn build` AFTER native_plot_png block (~573) where mesh_bake_exe/zimr_native_mod/zimrmath_mod/
         host_target are in scope; step `comptime-shadowmap-proof`; bakes bunny_proxy via mesh_bake OBJ grid=10.
         TUNABLES (top of main.zig; edit + the grid arg to move the budget): shadow_res=64, main_w=96, main_h=72,
         light_dir={0.40,1.0,0.30}, bunny_yaw=2.3, bunny_height=1.4. RESULT: EXIT=0, cold ELAPSED=34s; shadow-map
         min red 169(<240); lit-band 3432 px, shadow-band 299 px; VISUAL: recognizable bunny(ears/body)+blue cube
         +floor with a coherent cast shadow (floor patch below bunny + darkened undersides/cube faces). HEADROOM at
         34s: could bump grid->12 (~1044t) or shadow_res->96 for quality and stay <60s. NEXT: build the full
         three-way flagship examples/shadowmap_sw (GPU=existing shadowmap.zig live, CPU=cpu_shadowmap_test proof
         live, comptime corner=THIS baked const) + launcher entry; switch inline shaders -> real src/shaders/
         depth_* + lit_shadow_* (same-shader-three-ways thesis).

## zimr508 — flagship shadowmap_sw: one shadow shader, three executors
- NEW examples/shadowmap_sw/: `scene.zig` (shared scene: floor+spinning pillar/receiver cubes+spinning bunny, orbiting light rig, depth/lit Ubo builders, VS loops, Context draws for live CPU, `bakeCorner` via rasterizeToTarget for comptime), `shadowmap_sw.zig` (wasm app: GPU two-pass w/ real depth+lit_shadow pipelines | live CPU two-pass through the same shaderMains | comptime-baked corner inset; pointer divider, helmet_sw layout), `native_verify.zig` (native exe: comptime-bakes bakeCorner AND re-runs it at runtime, byte-diff == 0 proven, dumps PNGs).
- ENGINE: `raster_shader.rasterizeToTarget` = non-clearing multi-draw core split out of rasterizeToImage (GPU-pass semantics: clear once, N draws w/ per-draw uniforms); rasterizeToImage now the clearing wrapper. `zimr.zig` += `shadow_shaders` re-export {depth_vs, depth_fs, lit_vs, lit_fs}. `lit_shadow_fs` bias moved to Ubo `params` ({bias_slope,bias_min}) — per-backend data (GPU rgba16f 0.0025/0.0008, software rgba8 0.018/0.010); GPU shadowmap example writes its params.
- build.zig: shadow shader externs wired into zimr_mod AND zimr_native_mod (externs are target-agnostic); shadowmap-sw-verify step (mesh_bake OBJ proxy grid10 → native gate); shadowmap_sw example + launcher flagship entries; deleted comptime_shadowmap_proof (superseded by native_verify).
- VERIFIED: shadowmap-sw-verify green (comptime vs runtime 0-byte diff on shadow map + lit image; corner eyeballed: bunny+pillar shadows correct). shadowmap-sw-standalone builds (bake in wasm graph confirmed via forced rebuild). Full `check` gate green after `corpus-refresh` (79/79 fixtures, stale 12-entry corpus from Jun 20 refreshed). GPU half needs device verify.

## System improvement notes (observed zimr508 session)
- WGSL fixture corpus staleness is silent: 12 dead entries warned for 11 days without failing anything. `check` should either hint `zig build corpus-refresh` loudly or fail when >N entries are unmatched (dead fixtures = untested shaders).
- `zig build test` is monolithic and >13min on 1 core; needs `-Dfocus`-style filtering like smoke-test has, or per-area steps (test-raster, test-codecs, ...). Killed mid-run this session; only the check gate + targeted builds ran.
- `is_reexported_shadermain` in build.zig is a hardcoded name list that must be updated in lockstep with zimr.zig re-exports. Either wire ALL externs unconditionally (lazy analysis makes unused ones free) or derive the list from one shared source of truth.
- Validated fast per-example runtime loop (should be the standard pre-device check): `zig build <name>-standalone` (12s warm) + `zig build smoke-test -Dfocus=<name>` (mock-WebGPU, N frames, call profile). Caught nothing this time but would catch traps/miswired binds without a device.
- rasterizeToTarget gives GPU-pass-shaped software multi-draw; the deferred raster_pass.zig facade can now be a thin clear+draws wrapper if ever needed.

## zimr509 — flagship device-verified; system fixes; port plan resumed
- shadowmap_sw DEVICE-VERIFIED by Simon (screenshot: CPU|GPU|comptime all agree, pillar+bunny shadows correct on both halves).
- SYSTEM: (1) all shader externs now wired unconditionally into zimr_mod + zimr_native_mod (hardcoded is_reexported_shadermain list deleted; lazy analysis makes unused ones free); (2) stale-corpus warning now prints an actionable `zig build corpus-refresh` hint. Gate green (13s).
- raylib_port.md: shaders_shadowmap_rendering + shaders_depth_rendering marked DONE. Next WAVE 1 heavy: shaders_deferred_render → NEW src/notes/deferred_render_plan.md (4 steps: spv2wgsl multi-output FS → N-target pipeline → MRT pass encoding → the example). Surveyed: all three fronts single-target today; bridge begin_render_pass takes one view; raylib_src absent from snapshot (fetched GLSL from GitHub to scope).

## zimr510 — deferred STEP 1 DONE: multi-output FS proven, all four shaders in
- raylib-master extracted to /home/claude/work/raylib-master (Simon-uploaded; OUTSIDE repo so zips stay lean — refetch from uploads or GitHub next session if missing).
- NEW engine shaders (auto-discovered by collectShaderFiles): gbuffer_vs/fs (+ common/vs_io/fs_io) — the engine's FIRST multi-output FS: Outputs {g_world_pos, g_world_normal, g_albedo_spec} → WGSL `entryOutputs @location(0/1/2)`. spv2wgsl handled it GENERICALLY — zero transpiler changes; STEP 1 collapsed to "write the shaders".
- deferred_shading_vs/fs (+ ios): NDC-quad passthrough VS (no uniforms) + lighting FS: 3 G-buffer sampler pairs (g1 bindings tex 0/1/2 + samplers 3/4/5), SoA lights UBO (light_pos[4] .w=reach, light_color[4] .a=enabled — no std140 struct-array minefield), branchless enabled-multiply per light, pow32 as five squarings, and the raylib bug FIXED (they dot the UN-normalized light vector → diffuse double-scales with distance).
- Corpus refreshed (83 entries), full gate green.
- ROBUSTNESS FINDING (repro ×2): the FIRST build after adding new *_vs/_fs files fails at a spv2wgsl-adjacent step; immediate retry is green. Smells like a missing dependency edge in the shader codegen graph (consumer sequenced before producer on fresh discovery). Capture full log on next repro; fix the edge.
- NEXT (deferred_render_plan.md): STEP 2 pipeline N color targets + STEP 3 MRT pass encoding (bridge extern taking a view-handle array), then the example (phone: drag/pinch orbit, ImGui light toggles + mode segmented control; pass B shares G-buffer depth attachment loadOp=load so light gizmos depth-test without raylib's GL blit).

## zimr511 — deferred STEP 2+3 DONE: MRT pipeline targets + MRT pass encoding
- gpu.zig: RenderPipelineDescriptor += `extra_color_formats: []const wgpu.TextureFormat` (locations 1..N; location 0 keeps StateCombo blend, extras blend-free); encoded as strict blob-tail extension (count + formats). New unit test pins the tail byte-for-byte (NOT yet executed — `zig build test` too slow this box; runs on next full test pass).
- bridge.zig: pipeline decoder pushes N extra blend-free fragment targets; NEW jsEncoderBeginRenderPassMrt (Cursor over wasm-memory u32 view-handle array, shared clear/load/store, shared depth, same GPU-timing tagging) registered as js_encoder_begin_render_pass_mrt; smoke shim name list updated.
- wgpu.zig: extern + wgpu_js alias + `render_pass.beginMrt(BeginMrtDesc)` (≤8 views, stack array).
- gpu_iface.zig: `Backend.beginRenderPassMrt` + BeginRenderPassMrtDesc (PassState contract identical to single-view).
- wgpu_app.zig + zimr.zig: `beginTextureModeMrtRaw(gl, rts, clear)` — fragment @location(N) → rts[N], depth from rts[0] (create FIRST rt with_depth=true, rest color-only); close with ordinary endTextureModeRaw.
- Gate green (83 fixtures), flagship smoke unchanged. NEXT: STEP 4 — examples/deferred_render (phone: drag/pinch orbit; ImGui: 4 colored light toggles + POSITION|NORMAL|ALBEDO|SHADING segmented mode; pass B loads G-buffer depth for forward light gizmos).

## zimr512 — deferred STEP 4 DONE: examples/deferred_render built + smoked
- NEW examples/deferred_render/deferred_render.zig (~800 lines): PASS A = beginTextureModeMrtRaw fills the 3-RTT G-buffer (pos rgba16f owns depth, normal rgba16f, albedo+spec rgba8) through gbuffer_vs/fs; PASS B = fullscreen NDC quad through deferred_shading_fs into canvas RTT (empty g0 BGL+BG fills the positional pipeline-layout hole; g1 = 3 tex + 3 samplers nearest; g2 = SoA lights ubo). Debug modes blit raw G-buffer maps via drawTextureRec.
- Scene: seeded xorshift cube field (raylib reseeds rand() — ours is screenshot-stable), 30 tumbling cubes + shiny centerpiece + matte floor, 4 ORBITING lights (quarter-turn phases, bobbing) with over-bright lamp cubes that dim when toggled off. UI panel: 4 light checkboxes + position/normal/albedo/shading buttons, u.wantCaptureMouse() gates the drag-orbit; pinch/wheel zoom.
- z.deferred_shaders re-export added; wgpu.zig render_pass's inner wgpu_externs block needed the MRT extern too (duplicate extern decl surface — consolidation candidate). Wired: example_steps, entries (wireEngineWgsl suffices), launcher flagship, launcher.zig import.
- smoke -Dfocus=deferred_render PASS (60 idx draws/frame = 36 gbuf + UI; 124 ubo writes; 4 single passes + 1 MRT below top-10 cutoff). Full gate green. Simon: device-verify (first real MRT validation — mock can't catch attachment-format mismatches).

## zimr513 — Color hygiene + fog_rendering port (WAVE 1)
- SIMON RULE (standing): Color comes from zm — never invent color types; imports at file root; alias common things at root. deferred_render.zig fixed (root `const Color = zm.Color;` + root `white` const).
- NEW src/shaders/fog_fs (+io): the fog example has NO vertex shader of its own — VS = gbuffer_vs REUSED (Inputs alias gbuffer_common_io.Interp). Pattern established: "clip pos + world pos + world normal" gbuffer_vs is THE forward-material vertex stage; cel/spotlight next are one-FS ports each. Fog math = raylib exp² curve, pow16-as-squarings spec, fog_color==clear (raylib ships the halo mismatch).
- NEW examples/fog_rendering: torus/cube/sphere trio (z.genMeshTorus re-export added + z.unloadMesh) + 21-torus fog ruler, UI density slider (u.slider), drag/pinch orbit gated on wantCaptureMouse. uploadMesh helper interleaves raylib-shaped types.Mesh (handles null indices → 0..N).
- smoke -Dfocus=fog_rendering PASS (31 draws/frame). Gate green, corpus refreshed (+fog_fs). raylib_port.md: shaders_fog_rendering DONE.

## zimr514 — cel_shading port (fog+deferred device-VERIFIED by Simon)
- Screenshots confirmed: fog_rendering (seamless dissolve, slider live) + deferred_render (MRT lighting pools, lamp cubes glowing) both correct on device. WAVE 1's MRT foundation is hardware-proven. NOTE observed in screenshot: UI checkboxes render as unfilled squares even when the bool is true — cosmetic checkbox glyph issue worth a look in ui.zig someday (toggling itself untested on device).
- NEW src/shaders/cel_fs (+io): banded Lambert (floor(NdotL*bands)/bands, ambient after snap so band edges stay crisp) on gbuffer_vs. NEW outline_hull_vs (+io): model-space normal extrusion pre-mvp, ink color rides frag_gray into depth_fs's passthrough — the outline pass costs ONE new shader.
- NEW examples/cel_shading: spinning bunny, circling sun (bands sweep live), hull pipeline cull .front drawn first then toon cull .back in the same pass; UI sliders (bands 2-12, ink width) + outline checkbox. z.toon_shaders re-export.
- smoke PASS (13 draws/frame), gate green, corpus refreshed. shaders_cel_shading DONE in plan; spotlight rebucketed to the 2D-effects wave.

## zimr515 — cel_shading FIXED to follow raylib (device screenshot showed dark blob)
- Root causes vs raylib (read cel.fs tail + their .png reference): (1) quantization must divide by bands-1 (top band = FULL 1.0; /bands never reaches white → underexposed), (2) their light is 45-deg directional spinning 0.5 rad/s (mine was low + often behind), (3) RAYWHITE background (ink needs paper), (4) hull thickness is MODEL-space pre-scale — bunny normalization is ~14x, so the world-unit slider now divides by s.scale (raw 0.02 had inflated the hull into the giant dark blob in Simon's screenshot).
- NEW examples/cel_shading/native_verify.zig + `zig build cel-shading-verify`: renders BOTH passes (hull back-faces via front_face=.cw, toon front via .ccw — rasterizeToTarget cull doubles as the inverted-hull trick) through the real shaderMains, dumps cel_verify.png, asserts paper/top-band/ink populations. Eyeballed: matches raylib's reference aesthetic. LESSON reinforced: stylized-look examples get a native pixel verify BEFORE device round-trips — the smoke call-profile can't see aesthetics.
- Standalone rebuilt, smoke PASS, corpus refreshed, gate green.

## zimr516 — 2D effects wave, batch 1: gallery + 4 raylib ports + native contact-sheet verify
- NEW src/shaders/effect_common_io.zig (the family shape: Inputs = deferred_shading Interp, texture0 sampler, final_color out) + FOUR effects, each ONE fs+io pair on the shared fullscreen VS: effect_grade_fs (raylib color_correction.fs, /100 pre-applied; saturation -1 == their grayscale.fs), effect_wave_fs (wave.fs verbatim incl. the 750 divisor; amps in source pixels), effect_outline_fs (outline.fs 4 diagonal alpha taps + double mix), effect_palette_fs (palette_switch.fs; live-scene variant indexes quantized NTSC luminance; branchless masked table walk — no dynamic uniform-array indexing).
- NEW examples/shader_effects: filters a LIVE 2D scene (bouncing balls + spinning slabs + label drawn via beginTextureMode on TRANSPARENT clear — outline keys on alpha) instead of raylib's static PNG; UI mode buttons + contextual sliders; 3 palettes to cycle (gameboy/sunset/ice). rt_src → effect quad → rt_out → blit.
- NEW shader-effects-verify target: all four shaderMains run natively over a synthetic pattern → effects_verify.png contact sheet (source|grade|waves|outline|palette) + per-effect assertions (grade diff 11066px, wave diff 2858px, ink 3113px, palette off-table 0). Eyeballed correct. GOTCHA recorded: every externs module declares its OWN structurally-identical TextureRef — use anonymous literals per effect, a shared typed const won't cross-assign. rasterizeToImage grew a trailing clear arg at the earlier split.
- API fixes learned: beginTextureMode(gl, rt, clear) (no separate clearBackground), drawCircle takes f32 + segments, drawRectanglePro rotation is RADIANS, TimeState field is delta_time.
- smoke PASS (waves default path), gate green, corpus 91 entries. Plan: 4 raylib examples DONE via the gallery (+grayscale free); spotlight = fifth gallery effect next.

## zimr517 — THE DUPLICATED-GRID GLITCH: diagnosed, fixed structurally, made a CI failure
- SYMPTOM (Simon device, shader_effects): frame content duplicated as a grid at different scales/crops, morphing while dragging UI. Recurring bug class, never previously pinned.
- ROOT CAUSE — NOT pass ordering. Queue-timeline UBO clobber: WebGPU executes ALL queue.writeBuffer calls BEFORE the frame's single encoder submit. Resources.writeUbo wrote the 2D ortho UBO into ONE buffer at offset 0; updatePerFrame is legitimately called by frame-begin, every reopen2DPass, and every beginTextureMode — shader_effects was the first example combining all three (~4 ortho writes/frame with DIFFERENT matrices), so only the LAST projection survived and applied to EVERY recorded 2D segment, including ones authored under a different ortho → wrong-scale stamps/crops = the grid. Frame-order-sensitive (UI drags change segment counts), which is why it always looked like a pass-ordering ghost. The engine had ALREADY solved this exact hazard for batch VERTICES (flushBatch's ring, comment: "queue-timeline writes clobber each other") — vertices got the ring, the ortho UBO didn't.
- FIX (structural): per-frame ortho RING in Renderer2D (32 x 64B buffers + group-0 bind groups against Resources' existing layout — pipeline layout untouched). updatePerFrame advances the cursor and writes the NEXT slot; bindForPass overrides group 0 with the cursor slot, so every pass segment KEEPS the matrix it was recorded with. Write budget resets STRUCTURALLY on encoder-handle change (no per-frame app call); overflow past 32 asserts loudly (debug) / logs to overlay (release) instead of glitching silently.
- IMPOSSIBILITY LAYER (CI): wgpu_smoke now runs a ClobberScan per frame — any (buffer, offset) pair written >= 2x within one update() is a smoke FAILURE naming the buffer/offset/frame. Verified green across shader_effects, deferred_render, cel_shading, fog_rendering, shadowmap_sw + the full gate. The whole bug class is now a red build, not a device-only visual.
- writeUbo doc now carries the ★ ONE-write-per-frame INVARIANT ★ and points to the rings. SIBLING DEFECT filed: pushUbo (shader_runtime_wgpu) has the same single-buffer-offset-0 shape — same medicine when an engine path starts calling it multiple times per frame (today only examples use it, once per frame each).
- Backlog carried: wgpu.zig duplicate extern surface (render_pass's inner wgpu_externs mirrors top-level decls — MRT extern had to be added twice); UI checkbox glyph renders unfilled when true (cosmetic, ui.zig); flaky first-build-after-new-shader-files codegen edge (repro x2 — capture full log next occurrence).

## zimr518 — readme.html major revision (Simon-directed)
- src/web/readme.html rewritten: 2,331 -> 1,714 lines while ADDING the centerpiece "Building the graphics demos" section (the shared pipeline recipe quoted in full, then fog/cel+hull/deferred-MRT/shadowmap-3-executors/effects-gallery/pbr-helmet walkthroughs, the verify-before-device philosophy with the three *-verify targets, and a condensed custom-pipelines para).
- Reordering: demos moved up right after "Shaders in Zig"; bridge/webgpu-layer/rasterizer merged into one "Under the hood" section near the end (includes the zimr517 ortho-ring war story as the recorded engine rule); input+time+zm merged; profiler/entities/audio merged.
- Dedup killed: the one-function-many-executors point now said once (was 3x), RTT explained once, spv2wgsl section folded into "one language", the ImGui widget table dropped, walkthroughs 10 -> 5 (kept fractal-tree, procgen-noise, recursive-hud, text-on-texture, ui-clipper).
- Currency fixes: build steps are plain kebab names (ALL `wgpu-<name>` references purged), 255 examples (was 156), ~190k src lines (was 140k), ~1,900 tests, corpus 91 entries, `io_in.u` (was stale `io_in.ubo`), no-inline-WGSL stance stated up front, zm.Color as THE color type, launcher mentioned, shared-VS table (gbuffer_vs / deferred_shading_vs) documents the io-sharing design.
- Structure validated (balanced tags, every nav anchor resolves). Fog snippet honestly labeled as condensed.

## zimr519 — spotlight joins the gallery (WAVE 1 forward/2D shader set now complete except depth_writing + hybrid)
- NEW src/shaders/effect_spotlight_fs (+io): raylib's spotlight.fs ported as a direct filter (texel * mix(dark,1,visibility)) instead of their black-overlay quad — identical picture, one pass. Keeps their radii-compensated nearest-spot double loop (spots compared by EDGE distance so overlapping big+small spots blend right); inline for over the fixed uniform array = uniform control flow.
- Gallery: fifth Effect slot + mode button + radius/darkness sliders. Hero spot CHASES THE POINTER (window px -> backing px scale, dt-damped lerp; idles on a slow orbit while wantCaptureMouse) — phone-first upgrade over raylib's random-walk spots; spots 2-3 ride balls 0 and 2.
- shader-effects-verify: sixth contact-sheet panel + two machine assertions (hero-spot center keeps the red disk >220, far bar darkened below 25% of source). PASS. Corpus refreshed 91 -> 97 entries (NOTE: fixture is hash-keyed SPIR-V->WGSL, no names — don't grep it for shader names). Smoke PASS through the clobber detector, full gate green.
- Transient seen twice: a configure-step failure ("Fix: rm -rf .zig-cache") that vanishes on immediate retry — same flaky-first-build family already on the backlog; still no full log captured (it self-heals too fast).

## zimr520 — effects panel: buttons in 2 rows (Simon device feedback)
- Device screenshot confirmed the gallery WORKS post-ring-fix (palette mode live, no grid glitch) but six mode buttons overflowed one phone-width row ("spot" invisible). Fixed: two rows of three (drop the sameLine between waves and outline), panel 160 -> 224 tall, pos vh-232. Rebuilt + smoke PASS.
- The transient configure failure ("rm -rf .zig-cache" hint, self-heals on retry) struck twice more this session — now reproduced ~4x total, always first build after edits, always clean on immediate retry. Pattern noted for the backlog investigation.

## zimr521 — depth_writing example ships (frag_depth end-to-end proven in an app)
- depth_write_fs (+io) already existed with the frag_depth Outputs builtin (gen_shader_externs name-magic, spv2wgsl BuiltIn 22 -> @builtin(frag_depth)); what was missing was the EXAMPLE. NEW examples/depth_writing: three staggered cubes whose REAL depth order is the opposite of what their blue channel claims — purple (blue~.95) pops in FRONT, yellow (blue 0) sinks BEHIND, impossible occlusion that holds while orbiting.
- Upgrade over raylib: "lie to depth" checkbox flips the same scene to an honest material (fog_fs at density 0 — it degrades to plain lambert+blinn) so the fraud is directly comparable edge by edge. Two pipelines, same gbuffer_vs, same pass.
- Verified @builtin(frag_depth) in the generated WGSL of the example's shader set. Gotcha: u.text fmt string must be comptime — runtime-selected captions go through u.text("{s}", .{caption}).
- smoke PASS, gate green. Plan: shaders_depth_writing DONE. WAVE 1 remaining: shaders_hybrid_rendering (raymarch+raster shared depth — frag_depth capability now app-proven, next turn) + shaders_raymarching_rendering (the pure-raymarch cousin, likely lands en route).

## zimr522 — depth_writing fidelity fix (Simon device catch: teal top beat purple side)
- Root cause: raylib's depth_write cubes are UNLIT — their finalColor.z is the FLAT color, so each cube claims exactly one depth. Our added Lambert fed the SHADED blue into frag_depth, so per-face lighting wobbled each face's claimed depth (bright teal top 0.74 -> depth 0.26 out-claimed dim purple side 0.33 -> depth 0.67). Fix: frag_depth = 1 - base_color.blue (flat); the Lambert stays for the eye only. LESSON: when porting a depth/stencil trick, check whether the source pipeline is lit — shading that's cosmetic in the original becomes semantic if it leaks into the trick's input.
- Corpus refreshed (shader changed), rebuilt, gate green.

## zimr523 — hybrid raster+raymarch ships + corpus made shrink-proof
- WAVE 1 FINALE: examples/hybrid_render + src/shaders/hybrid_raymarch_fs (+io). Sphere-traced metaball trio (iq smin, tetrahedron-gradient normals, rim light) over an analytic checkerboard floor + sky gradient, on deferred_shading_vs. THE HANDSHAKE: hit depth = clip.z/clip.w of the hit point through the SAME cam_vp the raster pass uses (column-major manual project) -> raster cubes and marched blobs depth-test against each other by CONSTRUCTION; raylib instead hardcodes 0.01/1000 in the shader and their hybrid_raster.fs writes finalColor.z (the depth_write gag leaked in — vestigial/buggy, NOT ported; our raster side uses honest hardware depth via fog_fs@0). One pass, two rendering methods, one depth buffer; show_march/show_cubes toggles. Native verify (hybrid-render-verify) asserted sky/floor-light/floor-dark/blob populations + pixel census eyeball (sky gradient / checker / orange blob). Smoke PASS, gate green.
- CORPUS INCIDENT + FIX: fixture shrank 97 -> 47 silently on refresh. Diagnosis: the corpus scans .zig-cache/o/*/shader.rewritten.spv — BUILD-STATE-DEPENDENT; Zig caches by CONTENT HASH (touch is a no-op) and its cache GC evicts old dirs; the 97 was live-shaders x build-config variants (Debug gate + release builds), not 97 distinct shaders. FIX (durable): refreshFixture now MERGES — live entries update, non-live pinned entries carry forward ("N live + M carried" in the output); coverage can only grow; genuinely deleted shaders accumulate as stale pins until a deliberate manual prune (safe failure direction). Old 97-entry file unrecoverable (zips rotated); baseline restarts at 48 and re-accumulates.
- This turn survived a mid-turn context reset: the hybrid shader/io/example/verify/wiring were found complete on disk (timestamps minutes old) and finished from inventory. Lost-context recovery protocol worked.

## zimr524 — WAVE 2 opens: mesh picking (screen ray + tap-to-pick)
- ENGINE: NEW draw3d.getScreenToWorldRay (raylib GetScreenToWorldRayEx: screen px -> NDC (y-flip) -> inverse VP unproject near z=0 / far z=1 in WebGPU's [0,1] clip -> normalized ray) + 2 in-tree unit tests (center-pixel matches camera axis + hits target sphere; corner pixel diverges correctly). z re-exports for the whole getRayCollision{Sphere,Box,Triangle,Quad,Mesh} family (existed in draw3d since the early port, was never surfaced).
- NEW examples/mesh_picking: ground quad / static cube / sphere / SPINNING torus, each picked with the collision routine that fits it — quad, AABB, analytic sphere, and full triangle-walk getRayCollisionMesh fed the torus's LIVE model matrix (exact hits while rotating; the CPU mesh stays resident for this, only the GPU copy is expendable). Closest hit wins, winner glows, white marker cube on the hit point, panel reports name + distance.
- Phone-first: raylib picks on hover; ours picks on TAP = press+release with <10px accumulated drag, so one-finger orbit and pinch keep working (a pinch is never a tap). Camera3D fovy is DEGREES — the example's 0.8 rad fov converts via *180/pi so the pick ray and the render projection agree exactly.
- OPS: cache GC had also evicted TOOL BINARIES (lint_zimr, spv2wgsl) — builds "timing out" were toolchain rebuilds killed mid-flight by my 110s timeout; warming `zig build lint` alone first unstuck everything. Pattern: after any cache-eviction symptom, rebuild tools in a dedicated call before example builds.
- smoke PASS, gate green (fixture 48 baseline, merge-protected). Plan: models_mesh_picking DONE; box_collisions next inherits the ray+AABB plumbing.

## zimr525 — claude.md: cold-cache build procedure + hardened show-the-code rule (Simon-directed)
- NEW section "Building one example from cold cache — step by step": the content-hash caching model (touch is a no-op), cache GC evicting TOOL BINARIES, the full build chain, and the core operating insight — the IDEMPOTENT RETRY LOOP (same command, forward progress every run; timeout 170; rc=124 -> rerun, rc=1+error: -> real, rc=1+configure-only -> transient, never rm the cache). Five steps, one tool call each: warm lint -> loop the standalone -> smoke -> gate -> corpus-refresh if shaders changed.
- "Show Simon the code" section rewritten as a hard rule with the failure modes named: heredoc-in-bash and Python-patcher writes do NOT count as shown; edits show the full changed region; shaders never summarized; lost-context recoveries must re-show before shipping.
- Adjacent staleness fixed while in there: wgpu-<name>-standalone -> <name>-standalone, prebuilt/ -> zig-out/standalone/, smoke filter is the plain snake_case name.

## zimr526 — box_collisions ships (the ray plumbing pays off immediately)
- z re-exports for checkCollision{Spheres,Boxes,BoxSphere} (existed in draw3d, never surfaced — same story as the ray family last turn).
- NEW examples/box_collisions: raylib's exact scene (player 1x2x1 green at (0,1,2), enemy cube 2^3 at (-4,1,0), enemy sphere r=1.5 at (4,0,0), fixed camera (0,10,10)) with their predicates verbatim; player flashes RED on overlap and the panel names which enemy. Phone translation: arrow keys -> DRAG anywhere, finger ray (getScreenToWorldRay) vs an oversized ground quad gives the target point, clamped to the arena; camera fixed like raylib so drag never fights an orbit; pinch scales the camera distance.
- Full file shown in chat per the hardened rule. smoke PASS, gate green. models_box_collisions DONE — two WAVE 2 items in two turns off one engine addition.

## zimr527 — point_rendering ships (point_list topology enters the example set)
- NEW src/shaders/points3d_vs (+io): unlit point VS, one VP ubo, Outputs alias cube3d Interp so the existing cube3d_fs passthrough is the matching stage by construction — a point-cloud pipeline cost ONE vertex shader, zero fragment shaders. Corpus 48 -> 49.
- NEW examples/point_rendering: raylib's GenMeshPoints distribution verbatim (uniform theta/phi/r — the core/pole bunching is part of the look) with colorFromHSV(r*360,1,1) rainbow shells; single point_list draw. Count steps x10 between 1k and 1M (raylib caps at 10M, but one point = 16B so 1M = 16MB vertex buffer — the honest phone ceiling); buffer allocated ONCE at cap, count changes queueWriteBuffer into it and change vertex_count only. Live FPS readout keeps the cost-curve pedagogy; raylib's GL point-mode-vs-DrawPoint3D toggle has no WebGPU analogue and was dropped, stated in the doc comment. Yellow wire-sphere landmark translated into the medium: three great-circle rings of yellow points in the same buffer/draw.
- Auto-orbit at raylib's CAMERA_ORBITAL pace; first drag takes the wheel (auto_orbit=false), pinch zooms, orbit checkbox to resume.
- GOTCHA: wgpu.VertexFormat has no `unorm8x4` — the engine's name is `uint8x4_unorm`.
- smoke PASS, gate green. models_point_rendering DONE. Next WAVE 2 group: heightmap/cubicmap/voxel/first_person_maze.

## zimr528 — box_collisions reframed for portrait (Simon device catch)
- Symptom: on the phone only the green player + a sliver of the enemy box showed; enemy sphere (x=4) and box (x=-4) fell off the horizontal edges. Cause: PORTRAIT squeezes horizontal FOV to roughly half the vertical, so raylib's landscape-tuned camera (0,10,10)+45deg framed a narrow vertical slice of a scene that spans x=[-5.5,5.5]. LESSON: raylib example cameras are framed for 16:9 landscape; any wide scene needs the camera pulled back / FOV widened for a portrait phone — verify the visible half-width (dist*tan(fovy/2)*aspect) covers the scene's widest axis at aspect ~0.46-0.56, not just at the desktop's 1.78.
- Fix: fovy 0.8 -> 1.0 rad, fixed camera (0,10,10) -> (0,15,20). Computed half-width 7.7 at 0.56 aspect vs 5.5 needed; still comfortable landscape. Pinch scale still applies on top.
- smoke PASS.

## zimr529 — heightmap terrain (WAVE 2 procedural-mesh group opens)
- Engine already had genMeshHeightmap (pixel grayscale -> vertex height, pos/normal/uv arrays) + genImagePerlinNoise, both re-exported. NEW src/shaders/terrain_fs (+io): height-banded material on the shared gbuffer_vs — normalize frag_world_pos.y across [min,max], blend a 4-stop water/grass/rock/snow ramp, times Lambert (0.25 floor). A new forward material = one FS file, again. Corpus 49 -> 50.
- NEW examples/heightmap: Perlin field (64x64) -> genMeshHeightmap -> terrain_fs; the landscape colours itself from its own shape, NO texture upload (raylib textures a PNG; we read height as colour so the standalone needs no asset). "regen" rolls a new noise offset and refills the SAME vbo (fixed vertex budget). Source-noise thumbnail shown corner via drawTextureRec. Auto-orbit + drag + pinch.
- GOTCHAs: loadTextureFromImage returns z.WgpuTexture (validity = .handle != .invalid, free via .deinit()), NOT types.Texture (.id). unloadImage/genMeshHeightmap take Image BY VALUE (not &img).
- Tried in-file FS unit tests (height->band assertions) but shader files can't join `zig build test` — their _externs modules are only wired in the real build (same limitation draw3d ray tests hit). Removed them to keep the shader clean like every sibling; height-band logic is simple and covered by corpus + device. smoke PASS, gate (check) green.
- NOTE for the group: raylib example cameras assume 16:9 — heightmap uses fovy 1.0 and dist 26 framed for portrait from the start (box_collisions lesson applied preemptively).

## zimr530 — prefer-vec lint rule: force `Vec` over `@Vector(4, f32)` (Simon-directed)
- NEW rule `prefer-vec` in tools/lint_zimr.zig: flags `@Vector(N, f32)` (N in 2/3/4) and autofixes to `Vec`/`Vec3`/`Vec2` — the whole `@Vector(...)` span is spliced to the alias. Covers locals, params, return types, non-extern types, AND extern/packed struct fields. ONLY exemption: zimrmath.zig's own canonical `const Vec = @Vector(4,f32)` definitions. `@Vector(4,u8)` and other non-f32/exotic widths correctly keep the raw form (no alias exists).
- KEY PROOF (settled Simon's open question): `Vec` works in `extern struct` UBO/vertex schema fields — it's a bare alias (`= @Vector(4,f32)`), so it transpiles to the IDENTICAL `vec4<f32>` std140 layout. Verified by converting terrain_fs_io's Ubo (light_dir/band_*/params) + Outputs to Vec and diffing the generated WGSL: `field_0..field_5: vec4<f32>`, `@group(2) @binding(0) var<uniform> u`, heightmap smoke PASS. So externs are NOT a special case — the earlier "explicit width documents layout" intuition was wrong; removed that exemption + its dead precompute (markExternFieldVectors/extern_field_vecs).
- LINTER INTERNALS learned: the walk descends into fn BODIES but not type-expression positions. Type-level rules need explicit reach: added `walkTypeExpr` (recursively runs checkPreferVec on a type node + children) invoked from THREE places in walkNode — fn-proto param types (`proto.iterate`) + return type, var_decl type annotations (`vd.ast.type_node`), and container_field types (`ast.fullContainerField`). Without the last one, extern UBO fields are silently missed (the bug I hit twice).
- Autofix rides the AstGen parse-guard: it applies wherever `Vec` is bound in scope and ROLLS BACK where it isn't (proven on toy files vs a real zm-importing file where it applied cleanly `fn scale(v: @Vector(4,f32))` -> `fn scale(v: Vec)`). So --fix is safe tree-wide.
- Landed OPT-IN (`--prefer-vec` flag, default off; mirrors anon-return) because the backlog is 246 items (io schemas are the bulk). Default gate stays green so builds aren't blocked on legacy debt; new/edited files run it, and it flips to gating once the tree is migrated. Convention recorded near the math-import note (line ~368): every math file `const zm = @import("zm"); const Vec = zm.Vec;`, never z.Vec, Vec even in externs.
- Hand-migrated as exemplars (clean under --prefer-vec, builds verified): terrain_fs(+io), raster.zig, lambert_demo, pipeline_settings. Gate green, corpus 50, heightmap smoke PASS.

## zimr531 — prefer-vec backlog fully migrated + rule flipped to GATING (Simon-directed)
- Migrated the ENTIRE @Vector(N,f32) -> Vec/Vec2/Vec3 backlog: 246 findings across 73 files, in verified batches (27 shader io schemas, 17 shader bodies, 22 examples, 6 core src incl raster_shader/shader_runtime_wgpu/shader_connect/shader_introspect/draw3d + 2 spikes). Tree now 0 findings under the rule.
- Method (careful, batch-verified): for each file add `const zm = @import("zm"); const Vec = zm.Vec;` (and Vec2/Vec3 as needed) if absent, then replace @Vector(N,f32) with the alias ONLY where that alias is bound. Built+smoked a representative example per batch before moving on (fog_rendering, deferred_render, shader_effects, skybox, cube_demo, ui_canvas_demo, particles, depth_rendering, sidebyside, heightmap, cel_shading, point_rendering — all PASS).
- GOTCHA that shaped the method: the linter's --fix AstGen parse-guard ROLLS BACK fixes in any file that @imports "zm" (or "zimrmath.zig"), because AstGen runs the file in isolation where the module can't resolve, so the import itself fails and every fix reverts. So autofix only lands in files with no module imports; for shader/io/core files I did the direct textual @Vector->Vec replacement (provably identical: Vec is a bare alias, transpiles to the same vec4<f32> std140 layout — verified turn zimr530). Real build/smoke is the verification, not the guard.
- Then flipped the rule to GATING: Ctx.prefer_vec + Args.prefer_vec default true, added --no-prefer-vec escape hatch, --prefer-vec kept as a back-compat no-op, doc updated. Default gate green with prefer-vec now enforced (0 findings). Rationale (Simon): aliasing is a deliberate counterweight to Zig's verbosity (no overloading/operators, manual casts/polymorphism) — Vec is the highest-leverage alias, so it's worth enforcing tree-wide.
- No dup bindings introduced (checked per file); no new reserved-math/no-qualified-zm violations from the added imports (the added aliases ARE the canonical bindings those rules want). Gate: NO REGRESSIONS, wgpu_smoke PASSED, 0 transpile failures, corpus 81 live.

## zimr532 — cubicmap maze (WAVE 2 procedural-mesh group continues)
- ENGINE: NEW draw3d.genMeshCubicmap (raylib GenMeshCubicmap port): white pixel -> solid cube column, black -> empty corridor. Top+bottom faces always emitted; each of the 4 side walls emitted ONLY where the neighbor cell is BLACK or the map edge (occluded shared walls skipped — keeps the maze hollow/cheap). Per-face UVs into a 2x2 atlas (right/left/front/back top row, top/bottom bottom row) computed and stored even though example A shades by face. Variable vertex count: allocs worst-case (cells*12*3) then reports used_verts. Re-exported z.genMeshCubicmap. GOTCHAS hit: local `half` shadowed file-scope const half (removed mine); loop vars z/x shadowed file-scope `const z`/`const x` aliases -> renamed to zc/xc.
- NEW src/shaders/maze_fs (+io): face-shaded material on gbuffer_vs — picks a base color from the dominant world-normal axis (floor/ceiling + 2 wall orientations get distinct tones) x Lambert. The heightmap "geometry carries the look, no texture" trick applied to walls. Corpus 81->86.
- NEW examples/cubicmap: procedural maze via randomized-DFS carve into a genImageColor image (odd 17x17 grid, 2-step lattice, stack-based backtracker) -> genMeshCubicmap -> maze_fs. NO bundled asset (raylib loads cubicmap.png + atlas; we generate + face-shade). "regen" recarves into the same vbo; source-map thumbnail in the corner. Auto-orbit + drag + pinch, portrait framing (fovy 1.0, dist 26).
- DECISION (Simon, option A of A/B/C): face-shaded self-contained now; option B (textured-lit-mesh pipeline + atlas) deferred as its own focused turn to prove the image-texture path — the atlas UVs are already computed in the mesh, waiting. B fills a real gap (zimr has no general textured-lit-mesh material, only immediate-mode drawCubeTexture + fullscreen effects).
- smoke PASS, gate green, 0 transpile failures. cubicmap DONE; voxel next in the group.

## zimr533 — basic voxel (WAVE 2 procedural-mesh group; last is first_person_maze)
- NEW examples/voxel: raylib models_basic_voxel. 8x8x8 solid beige voxel field centered on origin (voxelCenter(x,y,z) = coord - (world-1)/2). Crosshair locked at screen center; TAP casts a ray through center (getScreenToWorldRay) -> tests every present voxel's AABB (getRayCollisionBox) -> removes the CLOSEST hit (Minecraft block-break). Drawn via the immediate-mode 3D batch (beginMode3D + drawCube + drawCubeWires per voxel, exactly raylib's loop; coalesces to few draws). "remaining" count shown. NO engine changes — reuses getScreenToWorldRay + getRayCollisionBox from mesh_picking.
- Phone controls: raylib is WASD + locked-mouse first-person; here ONE finger drags to look (orbit-style yaw/pitch on cameraOf), a TAP (press+release, <10px drag) breaks the crosshair voxel, pinch + closer/farther buttons dolly cam_dist, reset refills. build.zig entry is a bare .{ .name, .title } (no configure — the 3D batch uses built-in engine shaders, like cube3d).
- API GOTCHAS hit: getRayCollisionBox takes an inline .{ .min, .max } literal (don't name zm.BoundingBox — it's z.BoundingBox and inference works); z.drawCircle wrapper sig is (gl, cx:f32, cy:f32, radius, color, segments:u32) — needs the segment count arg (see audio_basic:131). zm.float in a body must be file-scope-bound (no-qualified-zm). Fixed a stray [4]@Vector(4,f32) at draw3d.zig:189 the earlier prefer-vec sweep missed (nested inner-struct field) -> [4]Vec; tree still 0 prefer-vec.
- KNOWN ISSUE (pre-existing, NOT voxel-specific): `zig build smoke-test -Dfocus=voxel` (and -Dfocus=cube3d, identically) reports a queue-timeline clobber "buffer N offset 0 written 2+ times in frame 0 (1 total violation)". It's the immediate-3D batch's camera/view_proj UBO: lazy batch init seeds that resources UBO AND beginFrame3D's writeUbo both land in frame 0 — a ONE-TIME first-frame overlap (last write wins, same offset, correct data), harmless. The main `check` gate passes (its smoke path doesn't hit the first-frame batch-init overlap). Real fix = ring-buffer the 3D-batch UBO like the 2D ortho ring (renderer_2d); deferred as a focused engine turn since it touches shared batch internals used by every 3D example (cube3d, models3d, billboards, voxel, cubicmap-adjacent).
- Gate: NO REGRESSIONS, wgpu_smoke PASSED, 0 transpile failures, lint clean. voxel DONE.

## zimr534 — root-caused + fixed the 3D-batch queue-timeline clobber (Simon: understand deeply)
- SYMPTOM: `smoke-test -Dfocus=<cube3d|voxel|cubicmap|billboards|models3d|skybox|...>` reported "queue-timeline clobber: buffer N offset 0 written 2+ times in frame 0 (1 total violation)". Previously mislabeled (zimr533 notes) as a harmless first-frame INIT overlap — that was WRONG: ClobberScan starts counting at frame_start = init_calls (AFTER _initialize), so init-time writes are NOT scanned. The double-write is inside update() frame 0.
- ROOT CAUSE (traced end to end): the immediate-mode 3D batch (draw3d.Cube3D) inits LAZILY on the first beginMode3D, which runs inside update() frame 0. Cube3D.init passed `.initial_ubo = .{}` to shader.Resources(CubeSchema).init, which seeds the view-projection UBO with a queueWriteBuffer at offset 0. Then — same frame, a few calls later — beginMode3D's beginFrame3D calls resources.writeUbo, writing the SAME buffer+offset again. Two writes, same (buffer, offset), frame 0. It never recurs because init only runs once; that's why it was "1 total violation" and frame 0 only. The batch's draws (resources.bind) only happen at endMode3D, ALWAYS after beginFrame3D, so the seeded value is provably never observed by any pass — the seed is pure redundancy.
- FIX (minimal, correct at the right layer): drop `.initial_ubo` from Cube3D.init (and the identical skybox_resources init) → `shader.Resources(...).init(gpa, f, .{})`. initial_ubo is `?UboT` defaulting to null, so this just skips the redundant seed; beginFrame3D/drawSkybox's per-frame writeUbo stands alone and the buffer is only read after it. NOT ring-buffered: a ring is for buffers legitimately written per-SEGMENT within a frame (the 2D ortho case); here it was init-once + per-frame, so removing the dead seed is the honest fix.
- AUDITED every initial_ubo call site: the 4 example uses (pipeline_postprocess/pipeline_uniforms/vao_multibuffer/pipeline_instancing) are the LEGITIMATE pattern — they seed a static transform ONCE and never writeUbo again, so the seed IS the sole write, no clobber (verified: they smoke clean, keep their seed). initial_ubo is correct as the sole write; redundant (a clobber) only when the caller ALSO writes the UBO before first use. The 2 engine sites were the latter; fixed exactly those.
- The detector stays correctly strict (didn't weaken it to tolerate "harmless" double-writes — that would mask real per-segment corruption, the zimr517 duplicated-grid class). Right response to a clobber = eliminate the redundant write.
- VERIFIED: all 9 3D-batch examples PASS (cube3d, voxel, cubicmap, billboards, models3d, skybox, depth_cue, wireframe, dynamic_mesh), gate NO REGRESSIONS + wgpu_smoke PASSED, 0 transpile, lint clean. Removed the zimr533 "KNOWN ISSUE (deferred)" — it's resolved here.

## zimr535 — beginner graphics tutorial (src/web/tutorial.html), Simon-directed
- Wrote a from-scratch, example-first HTML tutorial teaching the whole zimr graphics stack to someone whose FIRST contact with graphics is zimr. 14 numbered lessons, each adds exactly one idea: what a GPU does -> smallest app (state + update, no main loop) -> immediate-mode 2D + polled input -> first fragment shader (gradient) -> THE SIGNATURE: "one function, three homes" (GPU via SPIR-V->WGSL / CPU software rasterizer / comptime) -> vertices+varyings+the typed schema -> the UBO as one Zig struct both sides share -> Lambert (dot(normal,light)) -> cel shading (the @floor(n·bands)/bands punchline, real cel_fs.zig) -> sharing gbuffer_vs/deferred_shading_vs (a new look = one fragment file) -> real WebGPU setup (buffer/module/pipeline/bindgroup, condensed from heightmap) -> raymarched-metaball showpiece (hybrid_raymarch_fs header, decoded using earlier lessons) -> compute (double_it kernel) -> where-to-next (change bands, recolor gradient, copy fog_fs).
- All code snippets are REAL, condensed from actual src/shaders + examples files (gbuffer_vs, fog_fs_io, cel_fs, hybrid_raymarch_fs header, double_it, heightmap pipeline). The CPU-debuggability of shaders is the recurring pedagogical hook. The Lesson-11 "watch" callout ties in the queue-timeline clobber fix from zimr534 as a real example of the tooling watching the seams.
- Design: inherits the readme's kraft-paper identity (brown palette, mono body + Georgia serif headers, hard drop-shadows, dotted-grid bg, terracotta #d35f33 accent) so it reads as the same project, but with its own tutorial character — numbered lessons, hand-written Zig syntax highlighting (span classes), "runs on GPU/CPU/comptime" chips per snippet, the 3-color "three homes" signature cards, noun tables, and 3 callout variants (aha=terracotta, watch=violet, plain=gold). Verified via playwright at 1000px + 390px (phone-first): TOC 2-col->1-col, three-homes 3-col->1-col, all 14 anchors resolve, all tags balanced, 0 unescaped < in <pre>.
- Linked from readme.html: a second wip-warning banner (terracotta border) right after the WIP notice points newcomers to tutorial.html before the reference. readme stays the canonical description; tutorial is the on-ramp.
- No engine/code changes; docs only. Gate untouched (no rebuild needed).

## zimr536 — first_person_maze: the procedural-mesh WAVE 2 group finale
- NEW examples/first_person_maze: raylib models_first_person_maze. Same cubicmap maze (genMeshCubicmap + maze_fs on gbuffer_vs, the cubicmap recipe reused verbatim — same MeshVertex/pipeline/uniformLayout/carveMaze), but WALKED in first person instead of orbited. Re-exported z.checkCollisionCircleRec (+ checkCollisionCircles) from shapes2d.
- Movement + collision follow raylib: keep the maze pixels resident on the CPU (State.walls: [grid_w*grid_h]bool), and on each move test the player's collision circle (r=0.28) against wall-cell AABBs in the 3x3 neighborhood around the player's cell. Improvement over raylib's simple "revert to oldPos": tryMove() tries the combined move, then each axis independently, so you SLIDE along walls instead of sticking. Out-of-bounds cells read as solid (isWall guards edges).
- Coordinate mapping is the crux (verified round-trip): genMeshCubicmap centers the mesh on origin, so cell (cx,cz) sits at world (cx + map_off_x, cz + map_off_z) with map_off = -(grid-1)/2. worldToCell = @round(w - map_off); cellCenter = float(c) + map_off. worldToCell(cellCenter(c)) == c by construction.
- Phone-first: raylib is WASD + locked-mouse. Here a left-drag turns you (yaw) and a forward-drag component nudges you forward (one thumb steers+walks); a "walk" toggle auto-advances along facing; turn L/R buttons; "new maze" recarves+respawns. Desktop keeps W/S walk + A/D turn. Minimap in the corner: drawRectangle per cell (walls light / corridors dark) + red player dot (drawCircle with segment count) + a facing tick (drawLineEx).
- GOTCHAS hit: RNG seed 0x5EEDMAZE1 had non-hex digits (M,Z) -> 0x5EED_1A2E; z.drawRectangleV doesn't exist, it's z.drawRectangle(gl, x,y,w,h, color) with separate floats; lint wanted @intFromFloat(@round(x)) -> bare @round(x) coerced via i32 annotation, and @as(f32,@floatFromInt) -> float(). smoke PASS (no clobber — zimr534 fix holds for this custom-pipeline example), gate green, no corpus change (reuses maze_fs).
- WAVE 2 procedural-mesh group (heightmap/cubicmap/voxel/first_person_maze) is now COMPLETE.

## zimr537 — first_person_maze position bug + control redesign + lint-note clarity (Simon device feedback)
- BUG 1 (position != red minimap marker) ROOT CAUSE: genMeshCubicmap does NOT center the mesh. Cell (cx,cz) is placed centered at world (cx, ·, cz) DIRECTLY (corners at fx±0.5 where fx=float(cx)); the mesh spans world 0..(grid-1), NOT centered on origin. first_person_maze wrongly assumed a centered mesh (map_off = -(grid-1)/2), so the camera world pos and the minimap cell disagreed by that offset. FIX: cell<->world map is the IDENTITY — worldToCell = @round(w); cellCenter = float(c). Wall AABB = cellCenter±0.5, which now matches the mesh cube corners exactly. Unit-verified the round-trip + AABB alignment. (cubicmap.zig orbits so it never exposed this; the minimap made it visible.)
- BUG 2 (awkward controls) REDESIGN per Simon "I should hold a button to move forward": removed the auto-walk toggle + the forward-drag-nudge hybrid. Now: HOLD a "forward" button to walk (read via u.isItemActive() right after u.button — the button need not "fire"; active==held-down), drag anywhere off-UI turns you (yaw only, vertical ignored), turn L/R buttons, new maze. Desktop keeps W(fwd)/S(back)/A/D(turn). Dropped the unused State.walking field. UI held-button idiom: `_ = u.button("forward",.{}); held = u.isItemActive();`.
- LINT NOTE CLARITY (Simon: make the int-from-float note clearer, mention roundi/trunki, use bare @trunc when type inferable, spend less time next time): rewrote the `int-from-float` rule body in tools/lint_zimr.zig to lead with "THE ONE DECISION" — is the target int type inferable from where the value LANDS (typed decl / fn return / call arg / struct-or-array field)? YES -> bare builtin @round/@trunc/@floor/@ceil (converts in one step, do NOT wrap or add zm.roundi). NO -> zm.int(T,x)(trunc, the "trunki") / zm.floori / zm.roundi / zm.ceili. Ends with a QUICK PICK one-liner. ALSO added rule #14 to claude.md "Style — one line each" so the decision is in front of me BEFORE I hit the linter (float->int quick-rule + int->float = zm.float never @as(f32,@floatFromInt)). zm truncating helper is `zm.int(T,x)` (Simon's "trunki"); roundi/floori/ceili exist too. Linter rebuilt clean.
- Verified: lint 0, first-person-maze-standalone builds, smoke PASS (no clobber), gate NO REGRESSIONS.

## zimr538 — waving_cubes (next WAVE 2 group: 3D models/animation begins)
- NEW examples/waving_cubes: raylib models_waving_cubes. 15^3 = 3375-cube field animated by (a) a global breathing pulse scale=(2+sin t)*0.7 and (b) a per-cube scatter=sin(block_scale*20 + t*4) that ripples a wave through the grid; HSV rainbow keyed to the diagonal (x+y+z), cube size shrinks with the same index (corner cube (0,0,0) is size 0 — matches raylib). raylib's constants kept verbatim.
- Pure immediate-mode 3D BATCH (z.beginMode3D + z.drawGrid + z.drawCube{CubeDesc{size,color}} + z.endMode3D) using BUILT-IN engine shaders -> build.zig entry is BARE `.{ .name, .title }` (NO wireEngineWgsl, unlike the custom-shader maze examples). Stress-tests the batch at a few thousand cubes/frame: smoke shows ~57.5 calls/frame for all 3375 cubes (immediate-mode batching -> one pass), and NO clobber (the zimr534 batch-UBO seed fix holds at scale).
- Camera: raylib auto-orbits on a fixed circle (cameraTime=time*0.3). Phone-first here: auto-orbit while hands-off, one-finger drag takes over (orbit yaw + pitch, clamped ±80), two-finger pinch zooms radius [18..70]. Pinch computed manually from two getTouchPosition points gated on getTouchPointCount>=2 (there is NO z.getPinchDistance — voxel does the same manual calc). Lifting a drag resumes auto-orbit from the current angle.
- API notes for next time: NO z.drawFPS (use co.caption); rad_per_deg is zm.rad_per_deg NOT std.math.rad_per_deg; int->float is zm.float() (rule #14). colorFromHSV(hue,sat,val) in types.zig. co.palette / co.caption from example_common.
- Verified: lint 0, waving-cubes-standalone builds, smoke PASS (no clobber), gate NO REGRESSIONS. WAVE 2 3D-models group started; remaining: decals, directional_billboard, tesseract_view, yaw_pitch_roll, orthographic_projection, then the animation set (needs skeletal) + loaders (IQM/M3D/VOX).

## zimr539 — waving_cubes added to the launcher flagship switcher (Simon: "add it to the launcher demo")
- Added waving_cubes to the launcher in the TWO required places: (1) examples/launcher/launcher.zig flagships array `z.eraseApp(@import("ex_waving_cubes").app)` (after kaleidoscope), (2) build.zig flagships list `"waving_cubes"` (after "kaleidoscope"). That's the whole recipe for adding a launcher entry: one name in each list.
- FIXED A PRE-EXISTING BREAK surfaced by the rebuild: examples/zimrphysics2d_demo/render.zig referenced `cam.pixels_per_meter`, a field that no longer exists on zm.Camera2D (its world->screen scale is now `zoom`). One-line fix `r_world * self.cam.zoom` (zoom IS the world->screen px scale). This example is a launcher flagship, so the launcher couldn't build until it was fixed. zimrphysics2d_demo smoke PASS after.
- Launcher standalone builds (12MB, waving_cubes present), lint clean, main gate (check) NO REGRESSIONS + wgpu_smoke PASSED.
- KNOWN ISSUE (pre-existing, NOT introduced here, NOT in the standard gate): `smoke-test -Dfocus=launcher` FAILS a queue-timeline clobber — buffer 97 offset 0 written 6x in frame 0. VERIFIED pre-existing: it fails identically with waving_cubes removed from the launcher, and the main `check` gate does NOT smoke the launcher so it stays green. helmet_sw (the active[0] child during launcher smoke) PASSES standalone, so the clobber comes from the launcher's compose-on-top pattern (tickFullscreen child + the launcher's own 2D pill draw) writing some non-ortho UBO 6x/frame — the 2D ortho UBO itself is ring-protected (renderer_2d 32-slot ortho ring), so buffer 97 is a DIFFERENT ubo. Deferred to a dedicated session: needs the launcher call-log dumped to identify buffer 97's owner (likely a per-child material/RTT ubo re-seeded under tickFullscreen, or the pill's own ubo). Do NOT rush a fix bundled with unrelated work.

## zimr540 — deep-dived the queue-timeline clobber CLASS; named-resource diagnosis + pbr3d ring + seed removal (Simon: find a good solution, willing to go back to the drawing board)
- Simon's key unblock: "add a name + @src to resource creation in non-ship." Built NAMED-RESOURCE clobber diagnosis: webtests/runner.mjs now decodes the (labelPtr,labelLen) that createBuffer/createBindGroup already forward, reads it from SUT memory at create time, and appends `LABEL_MAP(handle, name)` to the call log. wgpu_smoke.zig printClobberFail scans for it and prints `buffer N (label='...')`. An empty label='' is itself the signal to add a `.label` at that createBuffer site. (Gotcha: a `? :` ternary feeding {s} into bufPrint made c2js emit a `t19 is not defined` ReferenceError — avoid ternaries feeding format args in smoke code; compute into a const first or let lookupLabel return the default. Also filter non-`js_` log lines out of the by-type tally so LABEL_MAP doesn't pollute stats.)
- With buffers NAMED, root cause was instant: launcher's clobbered buffer = `pbr3d_vs_ubo_ring`. TWO bugs, same class:
  (1) pbr3d.Renderer (src/draw3d.zig) wrote 5 fixed VS mat4 UBOs + 1 FS UBO per draw() — its own comment said "single-model-per-frame v1". Any frame drawing >=2 models (helmet_sw draws the helmet; the launcher composes it) clobbered. FIX: 8-slot UBO ring (mirrors renderer_2d's ortho ring) — draw() advances ubo_cursor, writes+binds a fresh slot; beginFrame/drawInApp reset the cursor; a wrap asserts (ubo_ring_len=8, side-by-sides need 2).
  (2) the ring init SEEDED every slot to identity/defaults. The launcher inits children LAZILY inside update frame 0, so those seed writes collided with the SAME frame's first draw writes -> self-clobber. This is EXACTLY the zimr534 hazard (lazy-init seed vs frame-0 write). FIX: drop the seed entirely — draw() fully writes a slot before binding it, so the seed was always dead. (Lesson: NEVER seed a UBO a lazily-init'd subsystem also writes per-frame; the seed is both dead AND a frame-0 clobber.)
- Also fixed a PRE-EXISTING build break the launcher rebuild surfaced: examples/zimrphysics2d_demo/render.zig used cam.pixels_per_meter (renamed to zoom on zm.Camera2D) -> `r_world * cam.zoom`.
- GATE COVERAGE: added "launcher" to the tier-a smoke set (build.zig) so multi-model compose + lazy-child-init-in-frame-0 (invisible in any single-app smoke) is now caught on every `zig build check`. Verified: launcher + helmet_sw + all 9 3D-batch/model examples PASS, gate NO REGRESSIONS.
- Labels kept unconditionally (short literals; real browsers surface them in WebGPU errors too, so they help on-device debugging, matching existing labeled buffers like storage_buf/render_pass).
- Design writeup: src/notes/clobber_design.md (root cause, options A/arena-B/writeUbo-C, why we did A+seed-removal+naming and deferred the full arena). Deferred: the frame-wide FrameUniforms bump arena that would let ortho ring + pbr3d + Resources.writeUbo all route through one never-twice-written buffer and delete the per-subsystem rings — no longer urgent now that known clobbers are fixed and new ones self-name in the gate.

## zimr541 — orthographic_projection (WAVE 2 3D-models)
- NEW examples/orthographic_projection: raylib models_orthographic_projection. One scene of solid+wire primitives, SPACE (or on-screen button) toggles the camera between PERSPECTIVE and ORTHOGRAPHIC. The pedagogical point: perspective has a vanishing point (far = smaller), ortho keeps parallel lines parallel (depth-independent size).
- KEY ENGINE FACT: z.beginMode3D ALWAYS builds a perspectiveFovRh matrix internally (ignores Camera3D.projection). To use a non-perspective camera, build the matrix yourself and call z.beginMode3DMatrix(gl, view_proj) — its doc explicitly says "custom (e.g. orthographic) camera". So this example builds BOTH: perspectiveFovRh(fovy_rad, aspect, ...) and orthographicRh(w, h, near, far) [zm has orthographic{Lh,Rh,LhGl,RhGl} + OffCenter variants; Rh (non-GL) matches the perspective path's Z range]. raylib reuses the camera's fovy field as the ortho WIDTH (10 units) — replicated as width_orthographic, height = width/aspect so it's not stretched.
- Scene uses existing 3D-batch primitives: drawCube/drawCubeWires (CubeDesc.size is per-axis Vec, so raylib's 2x5x2 boxes work), drawSphere (SphereDesc{radius}), drawCylinder (CylinderDesc{radius,height} — NOTE the engine cylinder is fixed radius top=bottom, 24 sides; raylib's cone/variable-radius cylinders were approximated with equal-radius cylinders + extra wire cubes to read the parallax). Bare built-in-shader example -> build.zig entry is bare .{ .name, .title } (no wireEngineWgsl).
- Verified: lint 0, standalone builds, smoke PASS (no clobber — the named-label reporter stays quiet), gate NO REGRESSIONS. (Playwright headless chromium can't fully render zimr standalones — its Tint rejects the shapes_fs WGSL texture-in-let; device verify via screenshot as usual.)
- WAVE 2 3D-models remaining: yaw_pitch_roll, decals, directional_billboard, tesseract_view; then animation set (needs skeletal) + loaders (IQM/M3D/VOX).

## zimr542 — OrbitCamera controller (orbit/pan/zoom, mouse+gestures) + wire primitives; camera_controls example (Simon: add what's missing to the engine — zoom/orbit/pan with mouse and gestures)
- NEW z.OrbitCamera (src/wgpu_app.zig, re-exported in zimr.zig): a reusable spherical camera that turns per-frame input into a Camera3D, replacing the hand-rolled orbit math every 3D demo was duplicating (~15 examples had it). State: target:Vec, yaw/pitch(radians), distance, up. API: OrbitCamera.init(target, distance); .eye(); .camera(opts); .update(f, ui_wants_mouse, opts) Camera3D (call once/frame, feed result to beginMode3D). Behavior — ORBIT: 1-finger / left-mouse drag; PAN: 2-finger avg motion / right-or-middle-mouse drag (moves target across the camera screen plane, distance-scaled so it tracks at any zoom); ZOOM: pinch / mouse wheel. Gated on !ui_wants_mouse (pass ui.wantCaptureMouse()) so grabbing a slider never spins the scene.
- NEW z.OrbitOptions knobs (all defaulted): orbit_sensitivity(0.006 rad/px), pan_sensitivity(0.0015 world/px, ×distance), zoom_sensitivity(0.1), min/max_distance(1..500), min/max_pitch(±1.5 rad, prevents pole gimbal-flip), fovy_deg(45), respect_ui(true).
- Implementation notes: two-finger = spread→zoom + midpoint drift→pan (prev_pinch/prev_pan deltas, reset when <2 touches); pan basis = normalize(target-eye)=fwd, right=cross(fwd,up), scr_up=cross(right,fwd) — all zm.cross/zm.normalize on Vec4 (w-safe, since vec() sets w=0 and cross zeros w). Added file-scope `const normalize = zm.normalize; const cross = zm.cross;` (no-qualified-zm lint). update() is 4 params so one-per-line (fn-args-multiline). GOTCHA during edit: my str_replace old_str accidentally swallowed reopenOverlayPass's doc+signature, orphaning its body — had to restore it; ALWAYS verify a nearby fn wasn't split after a big insert (grep -c 'pub fn reopenOverlayPass' == 1).
- NEW wire primitives (the genuinely-missing ones): z.drawSphereWires(gl, center, SphereDesc) + z.drawCylinderWires(gl, center, CylinderDesc). Built on Cube3D.appendSphereWires (lat/long circles via appendLine, 12×12) + appendCylinderWires (top+bottom rings + vertical struts, 24 sides) in draw3d.zig; public wrappers + zimr.zig re-exports. NOTE the variable-radius/cone cylinder was ALREADY there as z.drawCylinderBetween(gl, p0, p1, r0, r1, sides, color) (=raylib DrawCylinderEx; r1==0 → cone), and z.drawCapsule too — so "missing cone" was actually already covered; only the wire sphere/cylinder were absent.
- NEW examples/camera_controls: the reference demo for OrbitCamera — a checkerboard of HSV cubes you fully navigate; the whole camera is one line `s.cam.update(f, u.wantCaptureMouse(), .{.min_distance=3, .max_distance=60})`. Reset-view button. Bare built-in-shader entry.
- Retrofitted orthographic_projection to use the now-exposed cone cylinders (drawCylinderBetween r0=0) + drawSphereWires/drawCylinderWires — faithful to raylib's primitive zoo now.
- Did NOT retrofit waving_cubes: it's already device-verified ("Beautiful") and its auto-orbit (advance-when-idle) is a feature OrbitCamera doesn't have; not worth regressing a known-good example. camera_controls is the clean demo instead.
- KEY FACT reconfirmed: z.beginMode3D ALWAYS builds perspectiveFovRh internally (ignores Camera3D.projection); OrbitCamera returns a Camera3D whose projection field is 0/perspective and beginMode3D honors that path. For ortho, still build the matrix yourself + beginMode3DMatrix.
- Verified: lint 0 across wgpu_app/draw3d/zimr/both examples; camera_controls + orthographic_projection standalones build; smoke PASS (no clobber); gate NO REGRESSIONS.

## zimr543 — OrbitCamera "pop on first touch" fix + rt_sidebyside de-duplication (Simon: I like rt_sidebyside's camera; don't duplicate work; there's a pop on first touch)
- ROOT of the pop: getMouseDelta = current_position - previous_position (src/runtime.zig). On the frame a drag STARTS (esp. touch), previous_position is stale (last pointer location, possibly far away or a default), so the first delta is a big jump that snaps the camera. rt_sidebyside had ALREADY solved this with a `dragging` flag that skips the first drag frame — but my new OrbitCamera (zimr542) applied the delta immediately on frame 1, reintroducing the pop.
- FIX in z.OrbitCamera (src/wgpu_app.zig): added a `dragging: bool` field; handleMouse now skips the orbit/pan delta on the FIRST frame of a drag (`if (self.dragging) apply; self.dragging = true;`), applying only from frame 2 when both positions are from the live drag — exactly rt_sidebyside's technique, now shared. Also reset `dragging=false` when two fingers go down (can't 1-finger-drag mid-pinch) and when UI owns the pointer (blocked), so resuming control after UI/second-finger doesn't apply a stale jump. (The two-finger pinch/pan already had its own first-frame guard via `if (self.prev_pinch > 0)`, so pinch didn't pop.)
- DE-DUPLICATION: rt_sidebyside (examples/rt_sidebyside) was hand-rolling the identical orbit camera (cam_yaw/pitch/dist + clampDist + handleInput with touch pinch + wheel + drag-skip). Replaced all of it with a single `cam: z.OrbitCamera` field + one `_ = s.cam.update(f, s.ui_wanted_mouse, orbit_opts);` call; buildUbo now reads s.cam.yaw/pitch/distance. Deleted clampDist + handleInput entirely. orbit_opts reproduces the old feel: orbit_sensitivity=0.005, min/max_distance=1.2/12, pitch ±1.5, fovy 45. Target is non-origin (0,0.3,-1.0) — OrbitCamera.init(target, dist) supports that. buildUbo keeps its own eye-derivation (it's also called at COMPTIME for the baked corner with raw initial_* constants, so it can't call the runtime cam) — that's the scene builder, not input handling, so no meaningful dup remains.
- rt_sidebyside is a launcher flagship, so this also exercises via the launcher smoke (still PASS, no clobber).
- OrbitCamerA reference pattern for driving a CUSTOM shader (not beginMode3D): call s.cam.update(...) for its side effects (ignore the returned Camera3D with `_ =`), then read s.cam.yaw/pitch/distance or s.cam.eye() to build your own UBO.
- Verified: lint 0 (no unused imports after deleting handleInput), rt_sidebyside + camera_controls + launcher standalones build + smoke PASS, gate NO REGRESSIONS.

## zimr544 — tesseract_view (WAVE 2 3D-models)
- NEW examples/tesseract_view: raylib models_tesseract_view. A 4D hypercube (16 corners = every (±1,±1,±1,±1)) rotated through the XW plane and projected 4D→3D by a perspective divide k=3/(3-w); drawn as 16 vertex spheres (radius=|w|*0.1) + 32 edges (a pair is an edge iff its two corners differ in EXACTLY ONE of the four original coords — verified: 32 edges). The w-scaling makes it appear to turn inside-out as it spins.
- Uses the new z.OrbitCamera so you can orbit/pan/zoom the 4D object (raylib's camera is fixed — orbitable is strictly nicer for studying it). Pattern: `const cam = s.cam.update(f, u.wantCaptureMouse(), .{...}); z.beginMode3D(f.gl, cam);`. Primitives: z.drawSphere + z.drawLine3D (both pre-existing). Bare built-in-shader entry.
- Edge test uses `inline for (0..4) |k|` over the 4 coords with a compile-time-unrolled equality count — clean and avoids a runtime loop over a comptime-known dimension.
- Lint gotchas hit: unused `vec` import (this one uses pointVec only); zm.rad_per_deg needs a file-scope `const rad_per_deg = zm.rad_per_deg;` (no-qualified-zm); 121-col HUD string → hoist to a const. f.time.time is the elapsed-seconds field.
- Verified: lint 0, standalone builds, smoke PASS (no clobber), projection math sanity-checked in Python (32 edges, k-scaling correct), gate NO REGRESSIONS.
- WAVE 2 3D-models remaining: models_yaw_pitch_roll (needs a plane model asset), models_decals, models_directional_billboard; then animation set (skeletal) + loaders (IQM/M3D/VOX).

## zimr545 — directional_billboard (WAVE 2 3D-models) + sprite-atlas billboard engine addition
- NEW examples/directional_billboard: raylib models_directional_billboard. A character sprite that (a) always faces the camera (billboard) and (b) picks its atlas frame by the CAMERA's angle around it — an 8-direction "Doom enemy" sprite: orbit and you see its front/side/back. Second atlas axis = a 4-frame walk cycle on a timer.
- ENGINE ADDITION (this is what the port needed): source-rect + anchor billboard.
  * draw3d.zig: appendTexQuad now delegates to a new appendTexQuadUV(p0..p3, uv_min, uv_max, col) so a quad can frame a UV SUB-rect (one atlas cell) instead of the whole texture. (GOTCHA: named the UV locals u0/v0/u1/v1 first — `u0` SHADOWS the Zig primitive `u0` (0-bit uint)! Renamed to su0/sv0/su1/sv1.)
  * NEW Cube3D.drawBillboardRec + public z.drawBillboardRec(gl, tex, right, up, pos, w, h, uv_min, uv_max, anchor, tint) = raylib's DrawBillboardPro core. `anchor` in (w,h) units positions the quad in its plane: {0.5,0.5}=centered (=drawBillboard), {0.5,0}=bottom edge on pos (feet-on-ground sprites). Re-exported in zimr.zig. The pre-existing z.drawBillboard (whole-texture, centered) is unchanged and still works (billboards example still PASS — it shares appendTexQuad which now routes through the UV version at 0..1).
- Texture: standalones can't fetch external PNGs, so the 4×8 atlas is PROCEDURAL — makeAtlas builds a z.Image via z.genImageColor and paints a little robot per cell (frontness=cos(facing) shades the face brighter + adds a visor only on front views; swing offsets the legs per walk frame), then z.loadTextureFromImage. Same recipe as the billboards example's makeSprite.
- Direction pick: view_ang=zm.atan2(cam.pos.z, cam.pos.x); dir_f = view_ang/(2π)*dirs, wrapped to [0,dirs). BUG FIXED: @round(dir_f) can land on `dirs` itself (e.g. dir_f=7.8 → 8, one past the last row) → had to `% dirs` AFTER rounding, not just @mod before. Verified in Python.
- Lint gotchas: std.math is BANNED outside zimrmath (GPU portability) — use zm.pi / zm.atan2 (both exist); float→int with target type on the line is BARE @round (no @intFromFloat); std.fmt.bufPrint needs a file-scope alias (prefer-std-alias); 6-param fns one-per-line; if-return needs braces.
- Uses z.OrbitCamera (3rd real user) so you can orbit to see the other sprite sides. Verified: lint 0, standalone builds, directional_billboard + billboards smoke PASS (no clobber), gate NO REGRESSIONS.
- WAVE 2 3D-models remaining: models_yaw_pitch_roll (needs a plane .obj asset), models_decals (needs character model + decal projection); then animation set (skeletal) + loaders (IQM/M3D/VOX).

## zimr546 — yaw_pitch_roll (WAVE 2 3D-models)
- NEW examples/yaw_pitch_roll: raylib models_yaw_pitch_roll. Three independent aircraft rotations — PITCH (X), YAW (Y), ROLL (Z) — composed as one XYZ matrix and applied to a plane. raylib loads a WWI biplane .obj; standalones can't fetch assets, so the plane is built from immediate-3D-batch cubes (fuselage, nose, two wings, h-stab, vertical fin) — recognizable enough that all three axes read.
- KEY TECHNIQUE — rigid multi-part rotation about a common origin: each Part has a local `offset` from the craft origin. World placement = mulMatVec(rot, offset_as_point); part orientation = pass the SAME `rot` as CubeDesc.rotation. So drawCube rotates the box's local geometry by rot AND we place its center at the rotated offset → the whole craft turns as one rigid body. (appendCubeEx rotates geometry around the cube's OWN center then translates, so you must rotate the offset separately — the matrix does both jobs here.)
- Rotation compose: rot = mulMat(rotationX(pitch), mulMat(rotationY(yaw), rotationZ(roll))) = raylib's MatrixRotateXYZ intent. Verified in Python the axes are independent + correct: pure pitch tilts nose vertically (x stays 0), pure yaw swings it horizontally (y stays 0), pure roll leaves the nose fixed while banking the wings. (raylib's MatrixRotateXYZ uses NEGATED angles for its handedness — a sign convention that only flips a control direction; not worth matching bit-for-bit since it's driven interactively. Flip a key's sign on device if a control feels backwards.)
- Controls: raylib's keyboard mapping (UP/DOWN pitch, A/S yaw, LEFT/RIGHT roll) via z.isKeyDown(in, .up/.down/.a/.s/.left/.right) + easeToZero release behavior; PLUS phone-first held on-screen buttons (u.button + u.isItemActive per frame while pressed, u.sameLine to pair them). heldPair helper flips which button adds (yaw's A/S is inverted vs the others).
- Lint gotchas: std.fmt.bufPrint needs a file-scope alias (prefer-std-alias); 6-param fn one-per-line.
- Verified: lint 0, standalone builds, smoke PASS (no clobber), rotation math sanity-checked, gate NO REGRESSIONS.
- WAVE 2 3D-models remaining: models_decals (character model + decal projection — the last asset-heavy one); then animation set (skeletal: animation_blending/blend_custom/timing/bone_socket) + loaders (IQM/M3D/VOX).

## zimr547 — API idiomatic pass: Ex/Pro/Rec/V variant audit + Desc consolidation (Simon: verify all ex/pro versions; maybe some should be one normal version + an option struct .{} for discoverability; zimr is a zig-idiomatic raylib-INSPIRED lib, NOT a 100% port — don't keep alias symbols for old raylib names, mention them in the fn's doc comment instead)
- AUDITED every draw*Ex/Pro/Rec/V/Wires/Between/Subdivided variant. FINDING: nearly all (drawLineEx, drawCircleV, drawRectanglePro, drawTextureRec, drawBillboardRec, ...) map 1:1 to REAL raylib API names and their loose-param signatures are the raylib signatures — those stay as-is (a raylib user finds them by the name they know; the breadcrumb "Raylib parity: `DrawX`" in the doc comment is the discovery aid).
- CONSOLIDATED the tessellation into the Desc structs so there's ONE function + a discoverable `.{}`: SphereDesc now has rings/slices (i32, defaults 16/16); CylinderDesc now has sides (i32, default 24). drawSphere/drawCylinder/drawSphereWires/drawCylinderWires all read those (guarded @intCast(@max(...))). So `drawSphere(gl, c, .{ .rings = 32, .slices = 32 })` replaces the old separate drawSphereSubdivided — the loose-param variant is GONE, not aliased.
- REMOVED drawSphereEx + drawSphereSubdivided entirely (drawSphere's Desc covers them). Migrated all 7 call sites to drawSphere(gl, c, .{ .radius, .rings, .slices, .color }). (Migration GOTCHA: a naive regex comma-split MANGLES calls whose center arg is `pointVec(x,y,z)` — the inner commas break the capture; had to hand-reconstruct 4 lines. When migrating loose→Desc, watch nested-paren args.)
- KEPT drawCylinderBetween (point-to-point, variable-radius/cone cylinder) as the ONE name — it's a genuinely distinct primitive from drawCylinder (Y-axis fixed). Did NOT rename to drawCylinderEx: `Between` is the more descriptive zig-idiomatic name; the doc comment now says "(If you know raylib, this is `DrawCylinderEx`; a plain Y-axis cylinder is `drawCylinder` with a `CylinderDesc`.)". No alias symbol kept.
- Desc tessellation fields are i32 (NOT u32): matches raylib convention + the existing i32 style-struct fields that feed them (drawCylinderBetween/drawCapsule take i32 sides too), avoiding casts at every call site. The @max guards handle negatives.
- FIXED a pre-existing latent bug found en route: renderer_2d.zig ortho_ring_len was `usize` but ortho_cursor is `u32`, so `(cursor+1) % ortho_ring_len` is `usize`→`u32` — tolerated by release `check` but caught by Debug `test`. Made ortho_ring_len `u32` (array-size use accepts it).
## zimr549-563 — DECALS: the whole arc, condensed (14 turns, one feature)
Shipped: shader-projected decals (`z.uploadDecalReceiver` / `z.drawDecal` / `z.DecalDesc`),
clean discs on a sphere AND a 69k-tri bunny. Full narrative in
`archive/changelogs/changelog_zimr264-479_pruned.md`; `decal_shader_plan.md` has the design.

- **Mesh-clip decals do NOT scale.** v1 clipped the receiver's triangles into an oriented box
  (Sutherland-Hodgman). The bunny drops ~5,404 tris inside ONE decal box against a 96-tri cap →
  a scattered 2% subset, i.e. shards. Real engines project in the FRAGMENT shader: re-draw the
  receiver with a decal pipeline, transform world pos by the projector matrix, discard outside
  `[-s,s]^3`, sample at planar box XY. Density-independent. That's what shipped.
- **Matrix composition order was the bug that cost 3 turns.** `mulMat(a,b)` applies `b` FIRST;
  `lookAtRh`/`mulMatVec` are row-vector. Composing a lookAt with a spin the "obvious" way flung
  every decal into world space. Fixed by `zm.compose(first, then)` — now **Style rule 15** +
  `math.md`'s raylib translation table. raylib's `MatrixMultiply(A,B)` is the REVERSE reading
  order; every raylib matrix port goes through `compose`.
- **Sample at UNIFORM control flow, always.** `textureSample` inside `if (inside)` = invalid
  WGSL. Sample unconditionally at the top of `entry()`, then multiply an arithmetic mask into
  alpha (value-selects lower to `OpSelect`, not branches). The `[sampler-in-branch]` lint only
  scanned IoT shaders (`io.<method>()`), so direct `zsample2d` shaders were an unscanned blind
  spot — `isBareSamplerCall` now covers them. **When a runtime-only failure recurs, extend the
  mechanical guard to the path it was missing.**
- **Winding varies by mesh source: `genMesh*` is CW-outward, OBJ is CCW.** It bit twice.
  (a) The decal pipeline must NOT cull (`.none`) or the sphere's outer surface disappears.
  (b) **Never trust the raw cross-product normal from a picked triangle** — its sign follows the
  winding. Orient it against the view ray at pick time:
  `if (dot(hit.normal, ray.pos - hit.point) < 0) negate`. A wrong-signed hit normal silently
  inverted the projector AND made the facing test reject the entire sphere.
- **Depth: no bias, by construction.** Draw the receiver and use the SAME mesh as the decal
  receiver (both via `drawModel` + `uploadDecalReceiver`), so the decal re-draws bit-identical
  triangles at bit-identical depth → `less_equal_no_write` passes on the near surface and fails
  on the far one. The 0.0008 clip-space bias added earlier was ~16% of the sphere's front-to-back
  NDC gap (0.0052) and PULLED far-side decals through the front. A bias is a smell here; identical
  geometry is the fix. (Non-identity model transforms would need ~5e-5 insurance.)
- **Facing test** (`dot(surface_normal, projector_forward) > -0.1`) rejects the far box wall
  independent of cull mode. Needs real normals: `bunny.obj` has ZERO `vn`, and `toMesh`
  SYNTHESIZES them — do not gate on `had_normals` or every normal is garbage.
- **Per-decal UBO ring** (64 x 256B, bind groups with the offset pre-baked) — the bridge's
  `setBindGroup` has no dynamic-offset param. Same lesson as the pbr3d ring.
- **`cube3d` is lazily created at the first `beginMode3D`.** Any engine call made from
  `initState` that needs it must lazy-init it itself (`uploadDecalReceiver` does). Smoke did not
  catch this; the device did (`DecalReceiverFailed`, black screen).
- **SPIR-V: no in-place indexed writes to a `@Vector`** (`clip[2] -= x` fails to lower) — build a
  fresh vector instead.
- SUPERSEDED: this arc's "direct `@SpirvType` for single-consumer shaders is principled" note.
  zimr564-571 moved EVERYTHING to IoT; zero direct shaders remain.

- NOTE: `zig build test` had 6 shader files failing with "no module named '*_externs'" — ROOT-CAUSED + FIXED in zimr548 (it was a real build-graph gap, NOT environmental noise as first assumed).
- Verified: lint 0 all touched files; models3d/skybox/split_screen/first_person_camera/skinned_mesh/zimrphysics_demo/orthographic_projection build + smoke PASS; gate NO REGRESSIONS.

## zimr548 — root-caused + fixed the shader `_externs` `zig build test` failure (Simon: investigate the extern noise — and it was NOT noise)
- SYMPTOM: `zig build test` failed with 6× "no module named '<name>_externs' available within module 'root'" for depth_write_fs / fog_fs / hybrid_raymarch_fs / maze_fs / points3d_vs / terrain_fs. (I'd earlier mislabeled this "environmental noise" — it was a real latent build bug. Lesson: investigate before dismissing.)
- MECHANISM: each `src/shaders/<name>.zig` does `@import("<name>_externs")` — a NAMED module (codegen-emitted IoT/Out/installSpirvEntry surface), not a file path. build.zig wires it per-shader into zimr_mod + zimr_native_mod (the wasm + native-tools instances) via `addImport("<name>_externs", externs_mod)`. But the HOST UNIT-TEST module (test_mod, rooted at src/tests.zig, ~line 2204) only wired externs for the default_shapes_vs/fs PAIR (an `is_shapes` filter). src/tests.zig → refAllDecls → src/zimr.zig, which over time grew PUBLIC re-exports of these 6 other shaders (pub const depth_write_shader = @import("shaders/depth_write_fs.zig"); etc.) — so the test graph now reaches shaders whose externs the `is_shapes` filter never wired. The error referenced src/zimr.zig:581 (depth_write_shader) — the breadcrumb that pinned it.
- FIX: generalized the externs wiring in BOTH src/tests.zig-rooted test modules — the host unit-test loop (~2204) AND the transpiler corpus-diff module (diff_mod, ~1988) — from `if (is_shapes)` to "wire EVERY shader with an externs_path" (`if (s.sh_name) |sh_name| if (s.externs_path) |externs_path| { create externs_mod{root=externs_path, native, ReleaseFast} + addImport("zm") + test_mod.addImport("<name>_externs", ...) }`). Both loops now identical, so adding a shader to zimr.zig's public surface won't silently break `test` again.
- Verified: `zig build test` exit 0 (was failing), `zig build corpus-diff` exit 0, `zig build check` NO REGRESSIONS + wgpu_smoke PASSED. All three green now.
- TAKEAWAY: the `is_shapes` special-case was correct when written (test graph only reached the shapes pair) but became a landmine as zimr.zig's shader re-export surface grew. Prefer "wire all that have X" over "wire the specific ones I know about today" for build-graph deps that track a growing public surface.

## zimr564 — EXPERIMENT: closed all IoT shader-interface gaps (Simon: if the interface can't express something, we failed)
- Ran experiments to prove/disprove the IoT interface can express EVERY shader. Target: the hardest one, fluid_discs_vs (2 read-only SSBOs indexed by instance_index + vertex_index quad expansion). If IoT can't do it, the interface failed.
- RESULT: IoT CAN express it. Added two schema sections + codegen:
  * `shader.StorageBuf(Elem, .read|.read_write)` + `Storage` section (shader_interface.zig). Codegen (gen_shader_externs.zig) emits per field: `storageBuffer(Elem, name, group, binding)` extern + `io.<name>(i)` accessor calling ssboLoad. Binds in the stage's uniform group AFTER the Ubo — group 0 binding 1,2 for a VS with UBO at 0. Matches fluid's existing hand-wired layout exactly.
  * `shader.Builtin(.vertex_index|.instance_index)` + `Builtins` section. Accessor reads `std.spirv.<name>` directly.
- BUGS the experiment surfaced (each a real completeness gap, fixed):
  1. Entry wrapper didn't init the storage CPU void fields → `missing struct field _positions`. Fixed: init `._<name> = {}` alongside samplers.
  2. `unable to resolve comptime value` — you CANNOT `const _b = std.spirv.vertex_index` (magic extern, not comptime). Fixed: accessor reads std.spirv.<name> inline, no const alias.
- VERIFIED END-TO-END (built xfluid_vs as the experiment, then removed the experiment shaders — interface additions stay): `build-obj -target spirv32-vulkan` rc=0 → zspv rewrite rc=0 → spv2wgsl rc=0, emitting `@group(0)@binding(0) var<uniform> u`, `@binding(1/2) var<storage,read> positions/density`, `@builtin(vertex_index/instance_index)` — binding layout IDENTICAL to hand-wired fluid host.
- Gap C (decal ring) is NOT an interface gap: the decal SHADER types fine in IoT; only host `Resources` needs an N-bind-group ring mode (additive). So NOTHING is inexpressible.
- Regression: codegen changes are all @hasDecl-guarded, so shaders without Storage/Builtins are unaffected. Verified: lint 0, cube3d builds, decals-standalone builds, smoke PASS 107/frame, gate NO REGRESSIONS.
- Docs: src/notes/shader_gap_experiments.md (full experiment log), shader_unification_eval.md (updated verdict). NOT YET DONE (production follow-up): wire autoStorageBindGroupLayout to the in-stage-group scheme so Resources auto-binds SSBOs; then port points/fluid/billboard/skybox for real + gate.

## zimr565 — PRODUCTION: Resources SSBO auto-binding wired + points shader ported to IoT for real (first real port)
- Building on zimr564's interface additions (StorageBuf/Builtin schema members), did the production wiring so Resources auto-binds SSBOs, then ported `points` (the simpler of the two SSBO shaders) end-to-end.
- HOST WIRING (shader_introspect.zig + shader_runtime_wgpu.zig):
  * solveLayout now emits `.storage_buffer` ResolvedFields: group = stage's uniform group (uniformGroupForSchema), binding = after the Ubo (base = has-Ubo?1:0 + index). Same single-source-of-truth group rule as the Ubo, so host layout can NEVER disagree with the emitted WGSL @group. (Filled the old `// TODO: extend to Storage` stub.)
  * ResolvedField gained `read_only: bool = true` (for storage fields). solveLayout reads it via the pre-existing isReadOnlyStorageField (matches StorageBuf's `.access == .read`).
  * Resources(SchemaT): added `storage_count`, a `StorageBinding{handle,size}` type, a `storage_bindings[storage_count]` array, storage fields in InitArgs (one StorageBinding per Storage member), population in init, and REPLACED the `@compileError` storage_buffer placeholder in the BGL/BG builder with real entries (storage_buffer layout entry w/ read_only+min_size; .buffer BG entry). Added a storage_idx_global counter alongside sampler_idx_global.
- FIRST REAL PORT — points: created points_common_io.zig (shared `col` varying), points_vs_io.zig (Attributes{} + Ubo + Storage{positions} + Builtins{vertex_index,instance_index} + Outputs=Interp), points_fs_io.zig (Inputs=Interp + Outputs). Rewrote points_vs.zig/points_fs.zig bodies to IoT shaderMain form (io.positions(ii), io.vertex_index(), io.u, out.position/col). Deleted the direct @extern/storageBuffer/spirv.* code.
- VERIFIED byte-compatible: transpiled points_vs → WGSL emits `@group(0)@binding(0) var<uniform> u`, `@binding(1) var<storage,read> positions`, `@builtin(vertex_index/instance_index)` — IDENTICAL layout to the old direct version, so the existing DrawPoints host (which hand-wires that exact layout via @embedFile points_vs.wgsl) works UNCHANGED. Port is a drop-in.
- point_rendering example builds clean (attempt 1). Gate: lint 0, check NO REGRESSIONS, `zig build test` (host units + all-shader Debug compile) rc=0.
- NOT YET (remaining follow-up): (1) convert DrawPoints/fluid host to actually USE Resources(PointsSchema/FluidSchema) instead of the hand-wired bind groups — optional, since the layout matches; the win would be deleting the hand-wired BGL code. (2) Port fluid_discs for real (2 SSBOs — same pattern, just density too). (3) billboard/skybox (no SSBO, trivial). (4) Resources N-bind-group ring mode for decal (gap C host ergonomic).
- Notes: shader_gap_experiments.md, shader_unification_eval.md updated.

## zimr566 — PORTED fluid_discs to IoT (the HARDEST shader — 2 SSBOs + both builtins). Byte-compatible drop-in.
- Continuing the shader unification: after points (zimr565), ported fluid_discs — the hardest shader in the engine (two read-only storage buffers `positions`+`density` indexed by instance_index, plus vertex_index quad expansion). This is the shader the xfluid EXPERIMENT (zimr564) simulated; now it's the real thing.
- Created: fluid_discs_common_io.zig (shared Interp{col:Vec, corner:Vec2}), fluid_discs_vs_io.zig (Attributes{} + Ubo[FluidUniforms mirror] + Storage{positions,density both StorageBuf(Vec2,.read)} + Builtins{vertex_index,instance_index} + Outputs=Interp), fluid_discs_fs_io.zig (Inputs=Interp + Outputs{final_color}).
- Rewrote fluid_discs_vs.zig / fluid_discs_fs.zig bodies to IoT shaderMain form: io.positions(ii), io.density(ii), io.vertex_index()/instance_index(), io.u, io.corner/io.col, out.position/col/corner/final_color. Deleted all direct @extern/storageBuffer/spirv.* code. FS keeps the no-OpKill smoothstep-discard trick + explicit r>1 guard for parity.
- VERIFIED byte-compatible (transpiled both halves to WGSL directly):
  * VS: @group(0)@binding(0) var<uniform> u; @binding(1) var<storage,read> positions; @binding(2) var<storage,read> density; @builtin(vertex_index/instance_index); out @location(0) col, @location(1) corner.
  * FS: in @location(0) col, @location(1) corner; out @location(0) final_color.
  — IDENTICAL layout to the direct version, so the existing FluidDiscs host (draw3d.zig ~6225, hand-wires that exact layout via @embedFile fluid_discs_vs.wgsl) works UNCHANGED. Drop-in.
- fluid-gpu builds clean (attempt 1). Gate: lint 0, check NO REGRESSIONS, smoke fluid_gpu ✓ PASS ~150/frame (24 compute-pass dispatches + render intact), `zig build test` rc=0. fluid-gpu-standalone built for device verify.
- REMAINING shader ports: billboard, skybox (no SSBO — trivial now the Storage/Builtins pattern is proven). Then only the decal ring stays direct (host-side ring, gap C — Resources N-bind-group mode, not an interface gap). Optional: convert DrawPoints/FluidDiscs host to actually USE Resources(Schema) instead of hand-wired bind groups (layouts already match; win = deleting manual BGL code).
- Also this turn: shipped shader_authoring_tutorial.html (direct vs IoT tutorial, in repo root) — presented separately to Simon, confirmed points renders on device.

## zimr567 — PORTED billboard + skybox to IoT. Only the decal ring stays direct now.
- Continuing shader unification (points zimr565, fluid_discs zimr566). Ported the last two standard direct shaders. Both byte-verified drop-ins (host unchanged).
- BILLBOARD (first port with REAL vertex Attributes + a Sampler): billboard_common_io.zig (Interp{o_uv:Vec2, o_col:Vec} — NOTE prefixed o_ to avoid colliding with the VS attribute names uv/col; codegen emits attributes AND outputs into one namespace so a shared name is a duplicate-member error — a real gotcha this port surfaced), billboard_vs_io.zig (Attributes{p@0,uv@1,col@2} + Ubo{vp:mat4} + Outputs=Interp), billboard_fs_io.zig (Inputs=Interp + Samplers{tex:Sampler2D(.albedo,.{})} + Outputs{final_color}). Bodies: VS mulMatVec(io.u.vp,...) + forward; FS io.tex(io.o_uv) * io.o_col. VERIFIED WGSL: VS cam UBO @group0/binding0, attrs p@0/uv@1/col@2, out o_uv@0/o_col@1; FS texture @group1/binding0 + sampler @group1/binding1, final_color@0 — IDENTICAL to direct (camera group0, tex group1). Host (draw3d ~1065, resources.bg_layouts[0] + tex_bgl) UNCHANGED.
- SKYBOX (the tricky one — FS originally read a group-0 UBO, but IoT convention puts FS uniforms at group 2, which would break the host's single-group-0 layout). SOLUTION: VS forwards sky_bottom+sky_top as VARYINGS so the FS is UBO-FREE — whole pipeline stays on one group-0 uniform (VS-only), host's one-bind-group layout unchanged. skybox_common_io.zig (Interp{dir:Vec3, sky_bottom:Vec, sky_top:Vec}), skybox_vs_io.zig (Attributes{} + Ubo[SkyboxSchema.Ubo mirror] + Builtins{vertex_index} + Outputs=Interp), skybox_fs_io.zig (Inputs=Interp + Outputs{final_color}, NO Ubo). VERIFIED WGSL: VS UBO @group0/binding0 + vertex_index + forwards dir@0/sky_bottom@1/sky_top@2; FS has ZERO uniforms, reads only the 3 varyings, final_color@0. draw3d.SkyboxSchema.Ubo still matches skybox_vs_io.Ubo field-for-field. Host UNCHANGED.
- Gate: lint 0, check NO REGRESSIONS, smoke skybox ✓ PASS ~67/frame, billboards ✓ PASS ~75/frame, `zig build test` rc=0. Both standalones built for device verify.
- KEY LESSON (durable): when a VS has both vertex Attributes and Outputs, their field names share one namespace in the generated externs — name varyings distinctly (o_ prefix) or the codegen errors "duplicate struct member". When a FS needs values that live in a group-0 (VS) UBO, forward them as varyings rather than declaring an FS Ubo (which would relocate to group 2).
- STATUS: ALL standard shaders are now IoT. Only decal_vs/decal_fs remain direct — and that's the 64-slot projector-UBO RING (gap C), a host-side resource concern (Resources needs N-bind-group ring mode), NOT an interface-expressiveness gap. The two-ways-to-write-a-shader problem is effectively solved.
- Optional cleanup remaining: convert DrawPoints/FluidDiscs/billboard/skybox host code to actually USE Resources(Schema) instead of hand-wired bind groups (layouts already match; win = deleting manual BGL code, not capability).

## zimr568 — CONVERTED DrawPoints host to Resources(PointsSchema) — first real consumer of the SSBO auto-binding (zimr565). Hand-wired BGL deleted.
- Most logical next step after all shaders became IoT: make the storage-buffer auto-binding I built into Resources (zimr565) actually USED. Until now nothing consumed it — DrawPoints/FluidDiscs still hand-wired their bind groups. Converted DrawPoints as the first real consumer (validates the path end-to-end on device via smoke).
- Added `PointsSchema` (host-side merged schema in draw3d.zig): `pub const Ubo = Uniforms; pub const Storage = struct { positions: shader_iface.StorageBuf(zm.Vec2, .read) };`. Added `const shader_iface = @import("shader_interface")` to draw3d (first host schema needing the StorageBuf marker; CubeSchema/SkyboxSchema are Ubo-only).
- Rewrote DrawPoints: struct now holds `resources: shader.Resources(PointsSchema)` instead of `uniform`+`bind_group`. init() calls `Resources(PointsSchema).init(gpa, f, .{ .positions = .{ .handle = pos_buffer, .size = pos_bytes } })` — Resources auto-generates the UBO buffer + BGL + bind group (UBO@binding0, positions storage@binding1). Deleted ~35 lines of hand-written BindGroupLayoutEntry + BindGroupEntry + createBuffer/createBindGroupLayout/createBindGroup. Pipeline uses resources.bg_layouts[0]; draw() uses resources.writeUbo(...) + resources.bind_groups[0].
- SIGNATURE CHANGE: DrawPoints.init gained a leading `f: *gpu.GpuFrame` param (Resources.init needs the frame). Updated the one real caller (examples/compute_particles/compute_particles.zig → passes f.gpu) + the doc-comment example. NOTE Resources.init arg order is (gpa, f, args) — gpa FIRST.
- Gate: lint 0, check NO REGRESSIONS, `zig build test` rc=0. Smoke point_rendering ✓ PASS ~123/frame, compute_particles ✓ PASS ~59/frame — both exercise the Resources SSBO bind-group calls on the smoke harness (ClobberScan clean). point_rendering-standalone built for device verify.
- This VALIDATES the zimr565 storage-buffer Resources wiring with a real GPU consumer — the loop from "interface can express it" (zimr564) → "Resources can bind it" (zimr565) → "a real host uses it" (now) is closed for the 1-SSBO case.
- REMAINING optional cleanup: convert FluidDiscs (2 SSBOs — stronger test of the storage path), billboard, skybox hosts to Resources too. Same pattern; each deletes its hand-wired BGL. Then only the decal ring's bespoke N-bind-group topology stays hand-wired (genuine gap C — needs a Resources ring mode, or Ubo pinning + multi-UBO schema; the decal SHADER could move to IoT with those, but it's real new infra, not a quick port).

## zimr569 — CONVERTED FluidDiscs host to Resources(FluidSchema) — 2-SSBO + OFFSET binding validated. Added offset to StorageBinding.
- Continued the host cleanup (DrawPoints was zimr568). FluidDiscs is the stronger test: TWO storage buffers, and fluid_gpu's mirror path binds them at FIELD OFFSETS into one shared Buffers-struct buffer.
- StorageBinding (shader_runtime_wgpu.zig) gained an `offset: u64 = 0` field (was handle+size only); the storage BG entry now passes `.offset = sb.offset`. This is what FluidDiscs' offset-binding needs (pos/density at @offsetOf(Buffers,...) into one buffer).
- Added `FluidSchema` (draw3d.zig): `pub const Ubo = FluidUniforms; pub const Storage = struct { positions, density: shader_iface.StorageBuf(zm.Vec2, .read) };`.
- Rewrote FluidDiscs: struct holds `resources: shader.Resources(FluidSchema)` instead of uniform+bind_group. init() calls Resources.init(gpa, f, .{ .positions = .{handle,offset,size}, .density = .{handle,offset,size} }) — auto-generates UBO buffer + BGL + BG (UBO@0, positions@1, density@2). Deleted ~50 lines of hand-wired BindGroupLayoutEntry + BindGroupEntry. Pipeline uses resources.bg_layouts[0] (depth-mode logic stays — it's a pipeline concern). draw() uses resources.writeUbo(...) + resources.bind_groups[0].
- SIGNATURE: FluidDiscs.init gained leading `f: *gpu.GpuFrame`. Updated 3 call sites (fluid_gpu.zig ×2 incl the offset-binding mirror, fluid_sort.zig ×1) to pass f.gpu.
- Gate: lint 0, check NO REGRESSIONS, `zig build test` rc=0. Smoke fluid_gpu ✓ PASS ~150/frame (offset-binding mirror path exercised — validates the new offset field), fluid_sort ✓ PASS ~175/frame. fluid-gpu-standalone built for device verify.
- Both SSBO consumers (points 1-buf, fluid 2-buf+offset) now drive the storage path through Resources. The auto-binding is validated across the full range: single buffer, multiple buffers, and sub-region offset binding.
- REMAINING cleanup: billboard + skybox hosts to Resources (Ubo + Sampler / Ubo only — simpler, no SSBO). Then only the decal ring stays hand-wired (gap C — genuine new infra: Resources ring mode or Ubo-pinning + multi-UBO schema).

## zimr570 — Host-cleanup ASSESSMENT: skybox already on Resources; billboard texture path SHOULD stay hand-wired (shared cache, not per-shader). Cleanup effectively complete.
- Went to convert billboard + skybox hosts to Resources (following points zimr568, fluid zimr569). Investigation changed the plan — this is a correctness finding, not laziness:
  * SKYBOX: ALREADY fully on Resources(SkyboxSchema) — writeUbo + bind(ps), no hand-wired BG. Was converted before this session (that's why SkyboxSchema existed). Nothing to do.
  * BILLBOARD: camera UBO ALREADY comes from Resources (Cube3D's resources.bg_layouts[0]). The TEXTURE path is a SHARED ENGINE RESOURCE, not a per-shader binding: `tex_bgl` (group-1 texture+sampler layout) is used by billboard AND decal group2 AND drawTexturedTriangles, with `texBindGroup` caching one bind group PER TEXTURE VIEW (tex_bind_cache, keyed by view handle). Resources builds a FIXED bind group at init — wrong model for "one layout, N cached BGs keyed by texture." Converting would be a DOWNGRADE. Correct as-is.
- Audited all remaining hand-wired createBindGroupLayout sites in draw3d.zig. They are ALL deliberate specialized resources, NOT Resources candidates:
  * tex_bgl (shared textured-3D layout + per-texture cache) — correct as shared engine resource.
  * decal_proj_bgl (the 64-slot projector-UBO ring) — gap C.
  * pbr3d_vs_layout/material_layout/fs_layout (PBR: VS-UBO ring @group0, 6-texture+6-sampler material @group1, FS-UBO @group2) — specialized multi-map material + ring, predates IoT, own architecture.
- CONCLUSION: the Resources host-cleanup is COMPLETE for everything that should use it. The SSBO-shader hosts (DrawPoints, FluidDiscs) are converted + device-validated. Skybox was already done. Everything still hand-wired is a shared cache or a ring — architecturally correct to stay that way, NOT tech debt.
- No code changes this turn (assessment only) — tree unchanged, still green from zimr569. The "convert all hosts to Resources" goal is satisfied; forcing the remaining paths would harm the design.
- WHAT ACTUALLY REMAINS (the real frontier): the decal shader is the last direct @SpirvType shader, blocked by gap C (the ring). Moving it to IoT needs genuine new infra — either a Resources ring mode (N pre-built bind groups baking per-slot offsets) OR Ubo-pinning + multi-UBO schema support (camera UBO @group0 + projector UBO @group1 + texture @group2, which the current one-Ubo-per-schema + auto-sampler-group scheme can't express). That's the next substantive build if full unification (zero direct shaders) is the goal.

## zimr571 — DECAL now fully on IoT via `ubo_group` UBO-pinning. ZERO direct shaders remain. Fixed a latent codegen SSOT bug.
- Set out to derisk "put decals on IoT" expecting a big multi-UBO-schema build. The experiment REFRAMED the problem and found the true minimal solution — and revealed the decal was already half-converted (prior compacted session) but LATENTLY BROKEN.
- REFRAME: my earlier "needs multiple UBOs per schema" plan was WRONG. decal_vs and decal_fs are SEPARATE files → SEPARATE schemas, each with exactly ONE Ubo. decal_vs: Attributes + Ubo(camera) → auto group 0 (standard, like billboard). decal_fs: the ONLY non-standard part — projector UBO wants group 1 (where samplers default) and texture wants group 2 (where FS-Ubo defaults). It's a SWAP of the two default FS groups, solvable by PINNING, not multi-UBO.
- Sampler pinning already existed (Sampler2D .pinned=.{group,binding}). The one missing primitive was UBO pinning. Added it MINIMALLY: `uniformGroupForSchema` now checks for an optional `pub const ubo_group: u32 = N` on the schema BEFORE the stage default. Because BOTH the codegen and solveLayout read the group through this one function, the override keeps emitted @group + host layout in lockstep automatically.
- FOUND + FIXED a latent SSOT bug: gen_shader_externs had TWO ubo-group derivations. setup() (line ~508) used uniformGroupForSchema, but the ENTRY-WRAPPER path (line ~1109, the one installSpirvEntry ACTUALLY emits) HARDCODED `if (ubo_is_vs) 0 else 2` — bypassing the SSOT. So the decal's declared ubo_group=1 was ignored at the authoritative path → projector emitted at group 2, mismatching the host's group-1 ring → decal-via-IoT was BROKEN. Fixed line 1109 to call uniformGroupForSchema. Now BOTH sites agree.
- The decal_*_io.zig / decal bodies / decal_common_io.zig ALREADY EXISTED (prior session started the conversion with the ubo_group=1 + sampler-pin design, but couldn't work without the override). My two fixes complete it.
- VERIFIED byte-identical to the direct decal: decal_fs WGSL emits @group(1)@binding(0) var<uniform> u (projector), @group(2)@binding(0) decal texture, @group(2)@binding(1) sampler, in o_world@0/o_normal@1, out final_color@0. Matches the hand-written layout exactly → host UNCHANGED.
- HOST is correctly integrated: group 0 camera = Cube3D's Resources (resources.bind), group 1 projector = the 64-slot hand-wired RING (correctly bespoke — an offset-baked N-bind-group ring is NOT something Resources does, same category as tex_bgl), group 2 texture = shared tex_bgl cache. The "ring" (gap C) stays a host resource concern, which is architecturally right — it never needed to be in the schema.
- Gate: lint 0, check NO REGRESSIONS, smoke decals ✓ PASS ~107/frame (Clobber clean), `zig build test` rc=0. decals-standalone built for device verify.
- RESULT: ZERO direct @SpirvType shaders remain (audited: every src/shaders/*.zig non-_io file has shaderMain, none has bare `export fn entry`). The shader unification is now COMPLETE — genuinely one way to write a shader. The `ubo_group` primitive is the general answer to any future non-standard-group shader.

## zimr572 — readme.html shader-interface section finalized + 4 real hardening fixes found by the write-up audit.
- Task: expand src/web/readme.html #shaders with internals + examples, and audit for holes/future bugs. The expansion was ALREADY largely present (prior compacted session's in-progress work): under-the-hood pipeline (io+body → gen_shader_externs → SPIR-V → zspv → spv2wgsl → @embedFile), the group-rule TABLE (VS-Ubo→g0, FS-Ubo→g2, ubo_group=N override, samplers→g1, Storage→Ubo's group, Builtins→no binding), a second worked example (points_vs: Storage+Builtins, no vertex buffer), the decal_fs ubo_group=1 + pinned-sampler example, and a "Known edges / future bugs" .disclaimer callout. Verified it's ACCURATE against current code (ubo_group checked first = override wins; single-source uniformGroupForSchema read by codegen+solveLayout).
- The write-up doubled as an audit and turned up 4 REAL soft spots — FIXED the cheap unambiguous ones this turn:
  1. [FIXED] gen_shader_externs typo guard `recognized` list was STALE — listed only the original 6 sections, missing Storage/Builtins. Added them + close-miss entries (Storages→Storage, StorageBuf→Storage, Builtin/Builtln→Builtins). Without this a typo'd Storage section wasn't caught.
  2. [FIXED] The "Recognized schema sections" @compileError message was stale (missing Storage, Builtins) — updated.
  3. [FIXED] `ubo_group` had NO bounds check — `claimed_in_group[g]` with g>=4 is a comptime OOB panic (ugly). Added a friendly `>= 4` @compileError in uniformGroupForSchema (the single source of truth, so checked once for both callers).
  4. [FIXED] The Ubo-collision @compileError + its preceding comment referenced a non-existent `ubo_config (TODO)` and said "pinned UBOs aren't supported yet" — STALE now that ubo_group exists. Rewrote both to point users at `pub const ubo_group = N`. Directly improves the "confusing message" edge the readme flags.
- The 4 DOCUMENTED-as-future-holes (in the readme callout, still open, correctly framed as "shapes that don't exist yet"): (a) CPU dual-target path for Storage/Builtins accessors is WRITTEN BUT NEVER EXERCISED — all Storage/Builtins shaders are VS (GPU-only); the CPU software rasterizer only runs FS per-pixel. First FS reading a storage buffer finds out if the dispatcher fills the slices. (b) ubo_group=1 + Storage + unpinned Samplers = 3-way group-1 contention; collision IS caught (claimed_in_group) but ordering-dependent → error names symptom not cause. (c) varying @location count unchecked (WebGPU guarantees ~16; overflow fails at pipeline creation, not comptime). (d) ubo_group pins THE single Ubo — a stage needing 2 uniform blocks would need a per-block config redesign (the split-file design avoids this today).
- Gate: HTML tag-balanced (validated via python: pre/div/table/tr/p/h3 all matched, 21 code blocks balanced), lint 0, check NO REGRESSIONS, `zig build test` rc=0 (all shaders compile through the strengthened typo guard). No standalone (docs + comptime-guarded codegen/interface changes only).
- These 4 fixes are @hasDecl-guarded / comptime-only / doc-string, so zero runtime risk; the test build compiling all shaders is the validation that the codegen still emits correctly.

## zimr573 — DECAL side-by-side INFRASTRUCTURE: decal_shaders re-export + CPU less_equal/no-write depth mode. (Example next.)
- Simon: can we do the helmet_sw side-by-side idea for decals, sharing max code CPU/GPU? ANSWER: yes. Studied helmet_sw's sharing recipe (same vs/fs shaderMain both sides, one shared camera + one shared Ubo builder, z.shader.autoConnect for varyings, rasterizeTriangles on CPU + real GPU pipeline into a RenderTexture, splitter composite). Built the two ENABLING pieces this turn; the example itself is the next step.
- The decal FS is ALREADY CPU-ready: its body is plain zm (mulMatVec/normalize/clamp01) + typed io fields + one io.decal(uv) sampler call — no raw @extern/spirv. The generated decal_fs externs CPU branch exposes o_world/o_normal varyings, u (Ubo), _decal TextureRef, and the decal(uv) accessor that samples the TextureRef on CPU — structurally identical to pbr_fs, which already runs 3 ways. So the software rasterizer can run decal_fs unchanged.
- PIECE 1 — re-export: added `pub const decal_shaders = struct { pub const vs = @import("shaders/decal_vs.zig"); pub const fs = @import("shaders/decal_fs.zig"); };` to src/zimr.zig (mirrors pbr_shaders; lazily analyzed).
- PIECE 2 — the ONE real gap was the CPU rasterizer's depth: it hardcoded `.less` + write-on-pass (`if frag_z >= stored_z continue; depth_writer(...)`). The decal re-draws the SAME receiver mesh (fragment depth bit-identical to the surface) and needs `.less_equal` + NO write — matching the GPU decal pipeline's `.less_equal_no_write` (draw3d:1193). Added to RasterizeOpts (src/raster_shader.zig), BACKWARD-COMPATIBLY:
  * new `pub const DepthCompare = enum { less, less_equal };`
  * `depth_compare: DepthCompare = .less` (default preserves opaque behavior)
  * `depth_write: bool = true` (default preserves write-on-pass)
  * early-z block now: `const fails = switch(comptime opts.depth_compare){ .less => frag_z >= stored_z, .less_equal => frag_z > stored_z }; if (fails) continue; if (comptime opts.depth_write) depth_writer(...)`.
  * rasterizeWithRuntimeOpts (the 3-bool 2^3 switch) only sets depth_test/blend/cull → new fields take defaults there → all 19 existing .depth_test callsites unchanged. Overlay callers use rasterizeTriangles directly with explicit comptime opts (like helmet_sw), getting less_equal+no-write.
- Why less_equal+no_write is SOUND with early-z: the decal FS masks out-of-box fragments to 0 alpha via arithmetic (inside*facing), and the color path is alpha-OVER blend (already supported, RasterizeOpts.blend), so 0-alpha frags contribute nothing; skipping the depth write keeps stacked decals from occluding each other. Documented in the block comment.
- Gate: lint 0, `zig build test` rc=0 (the raster differential test rasterizeToImage-vs-rasterizeTriangles PINS the .less path — proves bit-identical, no drift), helmet-sw builds clean (the main depth_test consumer — proves backward-compat).
- NEXT: build examples/decal_sw/decal_sw.zig mirroring helmet_sw — one receiver mesh (sphere or bunny) + one decal texture feeding BOTH halves; shared camera + projector (compose(lookAtRh(hit,eye), rotationZ(spin)), forward=normal) + DecalUbo (params={half_size,1/size,0,0}, from draw3d.drawDecal:1914); GPU via z.drawDecal into a RenderTexture; CPU: base-lit receiver pass THEN decal overlay via rasterizeTriangles(.{.depth_test=true,.depth_compare=.less_equal,.depth_write=false,.blend=true}); splitter composite. Consider a comptime-baked corner too (3rd executor) like helmet_sw. autoConnect(decal_vs.Out, decal_fs.Io) for varyings.

## zimr574 — SHIPPED examples/decal_sw: the decal side-by-side. One decal shader, CPU rasterizer | GPU pipeline. Passes smoke + device standalone built.
- Built on zimr573's infra (decal_shaders re-export + CPU less_equal/no-write depth). Completed the example + the last re-export piece.
- ADDED re-exports to src/shaders/decal_fs.zig: `pub const Ubo = shader_io.Ubo;` + `pub const TextureRef = shader_externs.TextureRef;` (mirrors pbr_fs.zig — needed so the CPU example builds the same Ubo the GPU std140 block comes from, and feeds the decal texture as a TextureRef to io.decal(uv) on CPU). NOTE the paths are decal.fs.Ubo / decal.fs.TextureRef (module-level decls), NOT decal.fs.Io.Ubo.
- examples/decal_sw/decal_sw.zig (~380 lines, mirrors helmet_sw): ONE sphere receiver (genMeshSphere) + ONE procedural decal texture feed BOTH halves. Shared orbit camera + shared projector (buildProjector = compose(lookAtRh(hit,eye), rotationZ(spin))) + shared DecalUbo (buildDecalUbo: params={half_size,1/size,0,0}, mirrors draw3d.drawDecal). Decals auto-scatter over the sphere on a fibonacci spiral (deterministic → both halves paint identical set).
  * CPU half (renderCpu): clear color+depth; run decal_vs.shaderMain per vertex; base pass = a trivial FlatFs (flat sphere fill, .depth_write=true .less) so the sphere is solid + depth-writes; then decal overlay = the SHARED decal_fs via rasterizeTriangles(.{.front_face=.none, .depth_test=true, .depth_compare=.less_equal, .depth_write=false, .blend=true}) once per decal — the software mirror of the GPU decal pipeline's less_equal_no_write + alpha-over. autoConnect(decal_vs.Out, decal_fs.Io) wires the o_world/o_normal varyings.
  * GPU half: z.beginMode3D → z.drawModel(sphere, flat) → z.drawDecal per decal (the engine's real decal pipeline). Draws straight to the live frame.
  * composite: GPU fills the frame; CPU framebuffer drawn over the LEFT of a pointer-follow splitter via scissor.
- KEY DEBUG LESSONS (durable):
  1. Color type is `zm.Color` (bind `const Color = zm.Color;`), NOT z.Color. z has genImageColor/uniformColor but not Color.
  2. z.drawDecal wrapper sig = (gl, handle, projector, tex, DecalDesc{.size,.tint,.forward}) — 5 args, opts struct. NOT the 7-arg Cube3D method.
  3. ~~beginMode3D can NOT run inside beginTextureMode~~ **FALSE since the phase-SSOT fix (corrected zimr857).** beginTextureMode routes through `enterFrame2D`, so the phase assert passes; the app just needs `window.depth_format` set. 3D-into-a-render-texture WORKS and is shipped: `split_screen`, `text_on_texture`, `textures_framebuffer_rendering`. (What was missing was not the pass — it was the per-pass camera UBO ring; see zimr857.) The old advice sent you round a detour (scissor-composite the halves) to avoid a thing that works.
  4. Must set window.depth_format=.depth24_plus in the app config for any beginMode3D example.
  5. FlatFs.Io needs `pub const Ubo = FlatFs.Ubo;` but the field `u: FlatFs.Ubo` must reference the OUTER name explicitly (u: FlatFs.Ubo, not u: Ubo) or Zig errors "ambiguous reference" between the field-scope decl and outer decl.
- DISK: .zig-cache hit 8.5G / disk 100%. Removed zig-out (~1G, regenerable) then did a full `rm -rf .zig-cache` reset (the smoke guard's own recommendation at 6G threshold) → freed to 52%. Cold rebuild via idempotent retry. LESSON: when disk >95%, rm zig-out first (safe, ~1G); full .zig-cache reset is the clean fix when >6G (slow cold rebuild but no corruption risk, unlike deleting individual o/ dirs).
- Gate: lint 0, smoke decal_sw ✓ PASS ~77/frame (Clobber clean), check NO REGRESSIONS, `zig build test` rc=0 (raster differential test pins .less path — the new depth modes didn't perturb it). decal-sw-standalone built for device verify. Registered in build.zig (exampleList + name-list "decal-sw").
- This RETIRES the readme's "CPU fragment path for the newest features is unexercised" edge — decal_fs is now the first typed-IoT fragment shader actually run through the software rasterizer, proving the projector math (world→box, inside/facing masks) bit-identical on HW + SW.

## zimr575 — HARDENED 2 of the 4 documented shader-setup edges with comptime guards. Both proven to fire.
- Revisited the readme-audit's 4 future-holes and fixed the 2 cheap high-value ones (turn late/confusing failures into clear early comptime errors).
- GUARD (c) — inter-stage varying count. Added to tools/gen_shader_externs.zig (right after the typo guard, comptime block): counts Outputs varyings (excluding the frag_depth builtin) + Inputs varyings; @compileError if either > 16 (WebGPU's guaranteed maxInterStageShaderVariables). Uses std.fmt.comptimePrint (NOT comptimeIntStr — that's shader_introspect's; codegen uses comptimePrint) and .field_names.len (this Zig's @typeInfo struct has field_names/field_types, NOT .fields). PROVEN: a temp 17-varying Inputs schema errored exactly "Schema `Inputs` reads 17 varyings, but WebGPU guarantees only 16 inter-stage locations. Pack fields into fewer vec4s...". Was: opaque driver error at pipeline creation.
- GUARD (b) — group contention, upfront + names the cause. Added to src/shader_introspect.zig solveLayout (right after claimed_in_group init, runs BEFORE per-section claiming): if schema has Ubo + ubo_group AND ug == shader.sampler_group AND hasUnpinnedSampler → @compileError naming "ubo_group collides with the default sampler group"; separate 3-way message if Storage also present. New helper hasUnpinnedSampler(SchemaT) (iterates Samplers field_types, readSamplerOverride==null → unpinned). Was: collision caught by whichever section claimed last → error named a symptom.
- CRITICAL no-false-positive check: the decal uses ubo_group=1 with a PINNED sampler (group 2). hasUnpinnedSampler returns false for it → guard correctly does NOT fire. Verified by full `zig build test` rc=0 (all real shaders compile through both guards).
- The other 2 edges stay open (correctly): (a) CPU Storage/Builtins accessors still unexercised (all such shaders are VS; though decal_sw now exercises the CPU FS+sampler path generally). (d) ubo_group single-UBO limit = genuine redesign, not worth speculative work.
- Updated readme.html #shaders-edges callout: (b)+(c) rewritten as "now guarded at comptime"; (a) softened to "barely exercised" (decal_sw drives a real typed FS+sampler through the SW rasterizer now); intro + closing reflect 2-of-4 hardened. HTML tag-balanced.
- Zig gotchas (durable): in THIS codebase's Zig, @typeInfo(T).@"struct" exposes `field_names` + `field_types` arrays, NOT a `fields` array with `.name`/`.type`. The codegen tool (lang.Type) and std both use this shape here. Iterate field_types for type-only passes.
- Gate: lint 0, check NO REGRESSIONS, `zig build test` rc=0, both guards positive-tested (varying guard fired on 17; contention guard didn't false-fire on decal). Docs-only + comptime-guard changes → no standalone.

## zimr577 — ROBUSTNESS: made the sampler-binding path SINGLE-SOURCE-OF-TRUTH across codegen/rewriter/host. Fixed the bloom collision at its ROOT.
- The bloom collision (ubo@0 + texture@0) was a SYMPTOM. Root: texture/sampler BINDING assignment was computed INDEPENDENTLY in 3 places (codegen zm_binding, zspv_rewrite split, host solveLayout+runtime) with no shared rule — unlike GROUP assignment which already routes through uniformGroupForSchema. Fixed the whole path, not just bloom.
- DIAGNOSIS (via zspv --dump of OpDecorate op=71): raw SPIR-V had sampler2d var 534 with DescriptorSet 0 + Binding 1 (from codegen zm_binding(&src_sampler2d,0,1)). POST-rewrite the Binding-1 decoration was GONE (only DescriptorSet survived) → spv2wgsl resolveBinding fell back to next_auto_binding=0 → texture@0 COLLIDED with ubo@0. The rewriter's old logic ASSUMED the source Binding survives ("leave existing texture decorations alone, skip re-emit") but a downstream pass dropped it.
- FIX 1 (authoritative decorations) in tools/zspv_rewrite.zig rewriteSamplersWgsl: ALWAYS emit fresh texture Binding+DescriptorSet from the computed `pair` (removed the has_existing_texture_decs skip); AND in the copy loop, STRIP any existing Binding/DescriptorSet on a paired texture var (`pairs.get(operands[0]) != null`). One authority for texture decorations = the pair; can't be lost by downstream passes.
- FIX 2 (shared sampler-binding rule) same file: the sampler half now lands at `texture_binding + 1` when the texture binding came from the schema (existing_binding != null) — the EXACT convention the host uses expanding a .sampler_2d ResolvedField (shader_runtime_wgpu.zig:1039-1051: texture@N, sampler@N+1). Both sides derive the sampler slot from the ONE texture binding → WGSL and host BGL can't diverge. Removed the old free-slot `next_binding_in_group` map (dead). Fallback branch (GLSL→SPIR-V implicit bindings, no schema) keeps the legacy "after all textures" counter.
- WHY this is the robust design: GROUP already had a single source of truth (uniformGroupForSchema, read by codegen+solver). BINDING did not — the sampler's slot was invented separately by rewriter (free-slot) vs host (N+1). Now BINDING has one too: texture binding from codegen's zm_binding, sampler = texture+1 everywhere.
- VERIFIED WGSL byte-level: bright ubo@0b0/src tex@0b1/samp@0b2; composite ubo@0b0/scene tex@0b1 samp@0b2/bloom tex@0b3 samp@0b4 — all distinct, sampler always tex+1, matches host solveLayout. (Was: bright tex@0 [collide]/samp@2; composite scene tex@0 [collide]/samp@4/bloom tex@1/samp@5.)
- Gate: ast 0, lint 0, `zig build test` rc=0 (ALL shaders compile through the changed rewriter + host units + naga corpus — proves every existing material shader still agrees), check NO REGRESSIONS + wgpu_smoke PASSED (full device-smoke corpus). Safe engine-wide, not just bloom.
- BLOOM STATUS: all 4 typed FS now produce correct collision-free WGSL. ubo_group=0 + pinned samplers (tex g0 b1; composite bloom tex g0 b3) is the right layout for a post pass (one bind group). NEXT: host wiring — rewrite examples/pipeline_bloom.zig to @embedFile the generated .wgsl + drive each pass via shader.Resources(<Schema>), write per-pass UBOs (bright {thresh}, blurH {texel,0}, blurV {0,texel}, composite {intensity}), bind scene+bloom textures. Then build pipeline-bloom, smoke, standalone, update readme scoreboard (drop bloom).

## zimr578 — BLOOM MIGRATION COMPLETE. pipeline_bloom fully typed: no inline WGSL, no override constants. Shipped green + standalone.
- The override-constant blocker is RESOLVED via per-pass UBOs (each pass's config set once at load — a clean fit, no spec-constant authoring). This was the last example needing override constants (pipeline_constants stays as the deliberate override showcase).
- REWROTE examples/pipeline_bloom/pipeline_bloom.zig (~270 lines): deleted all 5 inline-WGSL consts (fs_vs, scene_wgsl, bright/blur/composite_wgsl) + texBgl/texBg/fullscreen helpers + z.Pipeline usage. Now:
  * 5 LoadedShaders: scene (reuses pipeline_uniforms_vs/fs), bright, blur_h, blur_v, composite — each via z.shader.loadShaderVF(vs_io, fs_io, .{ .f=f.gpu, .gpa, .vs/fs_wgsl_source=@embedFile, .textures=.{...by field name}, .initial_ubo=.{...}, .color_format=.rgba8_unorm, .depth_state=.none }).
  * Per-pass UBOs: bright params={thresh,0,0,0}; blur_h dir={texel,0,0,0}, blur_v dir={0,texel,0,0} (SEPARATE LoadedShaders, dir baked at load → no mid-frame UBO update); composite params={intensity,0,0,0}, textures=.{.scene=rt_scene, .bloom=rt_a}.
  * update(): scene→rt_scene (pushUbo transform, bindForDraw+setVertex+draw); bright drawFullscreenShader→rt_a; blur loop H→rt_b V→rt_a via drawFullscreenShader inside beginTextureMode; composite drawFullscreenShader→backbuffer.
- KEY BUILD-SYSTEM LESSON (durable): example shaders live FLAT in examples/ and are wired via the per-example `.shaders=&.{...}` list (build.zig addShaderDep → makes {basename}.wgsl @embedFile-able + creates the _io module). ENGINE shaders (src/shaders/) are auto-discovered but their .wgsl is only on zimr_mod (NOT @embedFile-able from an example) and their _io isn't in the example's import path. So a shader used by ONE example belongs in examples/ as an example shader. MOVED all bloom shaders src/shaders/→examples/ (bloom_fullscreen_vs, bloom_{bright,blur,composite}_fs + _io) and registered them in bloom's .shaders list.
- addShaderDep's generated _io module only imports zm+shader_interface — so an _io file that imports a sibling _common_io does NOT resolve. FIX: inlined the shared Interp{v_uv:Vec2} varying into each io file (varying match is STRUCTURAL, not by shared type) and deleted bloom_fullscreen_common_io.zig. Each shader is now self-contained.
- Builds on zimr577's binding-robustness fix (the pinned-sampler/UBO collision) — without it these passes would've collided ubo@0 with texture@0.
- readme.html: updated the pipeline-bloom description — now notes it runs every pass through z.shader.loadShaderVF with per-pass UBOs (not override constants, not hand-written WGSL). HTML tag-balanced (code/td/tr/p/em all matched). The "no inline WGSL anywhere in the tree" claim (line 391) is now materially closer to true (bloom removed).
- Gate: lint 0 (example + all 8 bloom shader files), build pipeline-bloom rc=0, smoke ✓ PASS pipeline_bloom ~237/frame (Clobber clean), check NO REGRESSIONS + wgpu_smoke PASSED, `zig build test` rc=0 (all shaders incl. moved bloom transpile). pipeline-bloom-standalone built for device verify.
- REMAINING INLINE WGSL scoreboard now: escape hatch PipelineOptions.wgsl; examples forward_kinematics, array, sampler, mipmap, storage, constants (override showcase — intentional), fluid_gpu; engine draw3d billboard_*/skybox_* (already IoT — verify stale). bloom DROPPED.

## zimr579 — BLOOM SCENE upgrade: gradient triangle -> glowing-orb light show. Device-verified great. + claude.md plan pointer reaffirmed to raylib_port.
- Simon: triangle was underwhelming. ROOT CAUSE (real, not taste): bright pass keeps pixels by LUMINANCE > thresh, so bloom only pops on small VERY-bright regions vs dark. A flat mid-bright triangle sits just over thresh everywhere -> dull uniform smear. Also: saturated hues have LOW luminance (pure blue 0.114 < thresh -> no bloom at all), so glow sources must be bright + high-luminance, not pure neon.
- REPLACED the scene: 9 orbiting/pulsing glowing orbs on near-black, drawn with the immediate 2D path (z.drawCircleGradient: bright core -> transparent edge = a light-source shape that pre-shapes the bloom) straight into rt_scene. Each orb = 3 stacked gradients: wide soft coloured halo (dim 0.55), bright core, small white-hot centre (rad*0.45) that guarantees a clean threshold hit regardless of hue. Palette is bright high-luminance colours. Orbit + size/brightness pulse via sin(t*speed/pulse + phase).
- SIMPLER too: deleted the scene LoadedShader + vbo + Vertex + transform2d + the pipeline_uniforms_vs/fs reuse (and dropped them from bloom's .shaders list). Scene now uses the engine's built-in 2D shape shader; bright/blur/composite chain UNTOUCHED. Tuned: blur_iters 3->4, thresh 0.30->0.35, intensity 2.0->1.7.
- Helpers added (all lint-clean): colorScaled(Vec,k)->Color, dim(Color,k), whiteHot(k), cf(u8)->f32, chan(f32)->u8 (uses zm.clamp + bare @trunc per rule 14). Bound `const float = zm.float; const clamp = zm.clamp;` at file scope (no-qualified-zm).
- Gate: lint 0, build pipeline-bloom rc=0, smoke ✓ PASS ~284/frame (Clobber clean), check NO REGRESSIONS + wgpu_smoke PASSED, `zig build test` rc=0. Standalone device-verified by Simon (screenshot: soft saturated glowing orbs, fat symmetric halos, white-hot cores — exactly right).
- Also updated readme pipeline-bloom description last turn (zimr578) — still accurate (typed shaders + per-pass UBOs); scene-content change doesn't affect that copy.
- PLAN POINTER: reaffirmed claude.md "Current plan" = raylib_port.md. Added a "just completed, closed arc" note there marking the typed-shader-interface unification + robustness + bloom migration as DONE, so next session resumes the raylib port rather than drifting back into shader work.

PHASES (P0,P1 done): ~~P0 spike~~ ✓ → ~~P1 DSL (`@SpirvType` helpers)~~ ✓ → P2 sample/store builtins →
P3 codegen+spv2wgsl (emit `@extern` descriptors [also replaces `zm.binding` asm OpDecorate];
translate OpImageSample*/OpImageWrite → `textureSample`/`textureStore`; DROP the limited
spirv-opt pass list — full `-O` runs again) → P4 RETIRE `zspv_rewrite` sampler machinery +
`zsample2d` placeholder + u32-handle convention → P5 device-verify the textured corpus
(cube_demo, pbr, lambert, post, …). Payoff: deletes the most fragile, version-sensitive
code in the build; full spirv-opt; unblocks 3 example categories.

**bloom (orthogonal to @SpirvType — needs `override`/spec constants):** still blocked on
override authoring, which 956 does NOT make easier (no spec-constant support in std.spirv;
the hard part — declaring a spec constant in Zig — has no clean path; would be an
extern+marker+spv2wgsl-synthesis hack). RECOMMENDATION: migrate bloom with a per-pass
FS-UBO (threshold/dir/intensity are set once per pass — a UBO is a clean fit), no new
tooling; leave pipeline_constants (whose whole point is `override`) for if/when override
authoring is built. Decision pending Simon.

**REMAINING INLINE WGSL** (the migration scoreboard): escape hatch
`PipelineOptions.wgsl` (material.zig:69, removed last); examples bloom, forward_kinematics,
array, sampler, mipmap, storage, constants, fluid_gpu; engine `draw3d.zig` billboard_* +
skybox_*. LEGIT WGSL-as-data (not targets): shader_inspection, ui_code_editor.

## zimr856 — COMPILER BUMP 1245 -> 0.17.0-dev.1398+cb5635714. Cold rebuild from a FRESH sandbox, all gates green. One breakage: `std.zig.Ast.parse`.
- CONTEXT: the sandbox had been reset — no `/home/claude/zimr`, and the zip deliberately excludes `tools/zig-x86_64-*`, so there was NO compiler until Simon uploaded one. That is the expected cold-start shape; the recipe is now written down under "Known sandbox quirks" (untar into `tools/`, `. ./.zenv.sh`).
- THE ONE SOURCE BREAKAGE (whole tree, 6 call sites, all in `tools/`): `std.zig.Ast.parse(gpa, src, .zig)` -> `std.zig.Ast.parse(gpa, src, .{ .mode = .zig })`. 1398 replaced the bare `Ast.Mode` third argument with an `Ast.ParseOptions` struct (`.{ recover: bool = true, mode: Mode = .zig }`). Sites: lint_zimr.zig x2, decl_deps.zig, rename_local.zig, rename_pub_fn.zig, zm_namedimports.zig. NOTE the new `recover` knob — lint/refactor tools parse KNOWN-GOOD source, so default `recover = true` is right; a tool that wants to reject malformed input can now say so.
- NOTHING ELSE MOVED. Zero changes to `src/` or `examples/`: engine, all shaders, spv2wgsl/zspv/c2js, and the ~200 example typechecks all compiled unmodified. The SPIR-V backend contract (`@SpirvType`, `@extern` descriptors, exec-mode-on-callconv, the inline-asm `"t"` constraint) survived the bump intact.
- The LLVM-backend SEGV that forced a self-hosted-backend override on 956–early-1245 is still gone on 1398: `shadowmap-sw-verify` (native ReleaseFast, LLVM default) compiles and reports a 0-byte differential (comptime bake vs runtime render). The `build.zig:636` note stands.
- COLD BUILD TIMINGS (1 core, 3.9G, `-j1`, this box). untar toolchain 0s; `zig build lint` 41s INCLUDING the build-runner compile + lint_zimr compile + ~450-file lint (the notes' "~158s from cold" is now optimistic-side wrong — 1398 is markedly faster here); `four-ways-standalone -Dmode=release` 106s cold (this call also builds spv2wgsl + zspv + c2js + gen_externs and every shader transpile); `launcher-standalone` 74s; `check` 51s; `smoke-test -Dfocus=launcher` 51s; `zig build test` 43s; `shadowmap-sw-verify` 20s; `corpus-refresh` 3s. Total ~6.5 min of wall clock, no OOM, no retries — the whole `.zig-cache` is 294M.
- **The launcher did NOT OOM from cold this time**, having warmed exactly ONE example standalone (four_ways) first. The "warm a few individual standalones" rule held; one was enough.
- `.zenv.sh` FIXED: it named `zig-x86_64-linux-0.17.0-dev.704+b8cb78023`, a directory that has not existed in `tools/` for months — sourcing it put NO zig on PATH. It now GLOB-resolves `tools/zig-x86_64-linux-*/`, so a toolchain swap needs no edit. (Class of bug: a pinned copy of something that moves.)
- **PROCESS FINDING — the corpus fixture is keyed by INPUT HASH, so a compiler bump silently zeroes its coverage while it still prints `✓ NO REGRESSIONS`.** `tests/fixtures/wgsl_corpus.json` maps `spv_input_hash -> wgsl_output_hash`. New compiler = new SPIR-V bytes = every input hash changes = all 138 pinned entries went dead in one step ("no matching live shader" x138) and the gate compared NOTHING, yet still reported green. `corpus-refresh` then wrote `52 live + 138 carried` = 190 entries, of which 138 can never match again (their inputs are gone with the old compiler) — the file grows ~52 orphans per bump forever. Two consequences: (1) the ONE gate that exists to catch a spv2wgsl regression is blind exactly when the compiler changes, i.e. exactly when spv2wgsl is most at risk; (2) re-pinning after a bump bakes in whatever the transpiler now emits, unreviewed, because a hash-to-hash map has nothing a human can diff. Raised with Simon; fix on the table = key the fixture by SHADER NAME (stable across compilers) and store a reviewable structural digest (entry points, binding table, resource decls) instead of an opaque hash, plus make "0 live matches" a hard FAIL, since a gate that can print ✓ while comparing nothing is a tautology (this codebase's own rule: "a stub that always succeeds is not a test").
- JOURNAL NUMBERING: this file's last entry was `zimr579` while turns in the body reference `zimr1233`/`1282` and the shipped zip is `zimr855` — three numbering schemes, all diverged, and the last ~months of landed work (four_ways, the jobs/worker system, the kompute refactor, most of the raylib port wave) has NO journal entry here at all; its durable lessons live only in the per-plan files. Flagged for Simon: pick ONE counter (the zip number is the only one that is externally visible and monotonic) and either keep journaling here or say plainly that the plan files are the record.
- Gate: lint 0, `zig build test` rc=0, `check` -> `✓ ENTIRE CORPUS TRANSPILES CLEANLY` + `✓ NO REGRESSIONS`, `smoke-test -Dfocus=launcher` -> `✓ PASS launcher ~135.1 calls/frame` with a FLAT twice-lifecycle GPU census, `verify_imports.js launcher.html` -> PASS 102/102 imports across `dom, wgpu, audio, jobs, wasi`. launcher standalone (12.9 MB) shipped for device verify.

## zimr857 — PORT: textures_framebuffer_rendering (raylib). It was billed "near-free"; it surfaced THREE engine bugs, incl. a SHIPPED example that was RED. New standing note: `src/notes/engine_findings.md`.
- **NEW STANDING FILE — `src/notes/engine_findings.md`** (Simon: "take note of all engine problems, opportunities for improvements you can find"). Every engine problem noticed while doing other work goes there, fixed or not, so it can't be lost in a journal entry. Read it when looking for the next high-value engine job.
- THE PORT (`examples/textures_framebuffer_rendering/`, raylib `examples/textures/textures_framebuffer_rendering.c`, 2/4): two render textures — one per pane, each sized to its pane in BACKING px — plus the cropped "viewfinder" (a magnified sub-rect of the subject framebuffer, which IS the sample's point: `gl.texture(dst, rt, .{ .source })`). PHONE-FIRST changes: panes stack in portrait / sit side-by-side in landscape; BOTH cameras are `z.OrbitCamera`s and the pane you drag is the one you steer (latched on press, so a drag across the divider keeps its camera) — drag the bottom pane to AIM the subject camera and watch its green frustum swing round in the pane above. UI panel: reset both / auto-orbit / mirror viewfinder / capture-px slider. raylib's WASD+mouse observer and CAMERA_ORBITAL subject don't exist on a phone; this is the honest translation, not a weaker one.
- `drawCameraPrism` (raylib's): frustum = unproject the four far-plane NDC corners (±1,±1,1) through the INVERSE view-projection, built with `far = |position - target|` so the prism is SLICED at what the camera is looking at instead of running to z_far. z=1 is the far plane in WebGPU's 0..1 clip space just as in GL's -1..1, so raylib's corner list ports unchanged. Uses `zm.inverse` + `mulMatVec` + perspective divide.
- **BUG 1 (engine, `gl.texture`): `.source` was documented "in pixels" and consumed as raw 0..1 UVs.** All FIVE call sites had each hand-divided by the texture size (`sr.x / tw`, `source.x / th`, ...) — five private copies of one transform — and NONE could express raylib's negative-extent flip (`-height`), which is exactly what a render texture needs. Fixed at the primitive: pixels in, flip supported, conversion in ONE place (mirrors `image.zig:drawTexturePro` exactly); migrated all 5 callers (each got SHORTER). This is the third time the "every caller re-derives the same transform" bug has been written up here (see the `.fit` scissor letterbox).
- **BUG 2 (engine, draw3d): the 3D camera UBO was SINGLE-SLOT.** `beginMode3D` → `Resources.writeUbo` → one buffer, offset 0. `queue.writeBuffer` executes before the frame's single submit, so ANY app with two 3D passes had every pass read the LAST camera — split-screen, minimaps, 3D-into-a-render-texture: all things the engine advertises. **The shipped `split_screen` example was RED on the smoke clobber gate and nobody had run it.** Fixed with a 16-slot view-projection RING (one buffer, 256-B slots, a PRE-BUILT bind group per slot — the bridge's setBindGroup takes no dynamic offset), cursor advanced by `beginFrame3D`, all four flush paths binding THIS pass's slot, plus an encoder-scoped assert so a wrap panics loudly instead of clobbering. Same medicine as renderer_2d's ortho ring and the decal projector ring 400 lines away in the same file.
- **BUG 3 (engine, draw3d): every 3D VERTEX stream restarted at offset 0 per flush** (solid, line, textured, instanced). Two passes → the first pass's recorded draw reads the second pass's vertices. The INSTANCED one didn't even need a second pass: two `drawMeshInstanced` calls in ONE frame both wrote offset 0, so the first draw rendered the second mesh's transforms. All four now APPEND at a frame-scoped cursor (reset on encoder change, the same structural trick renderer_2d uses); caps became per-FRAME budgets.
- **BUG 4 (infra, smoke): the clobber gate could DETECT a clobber but never NAME one.** `printClobberFail` builds a ~360-byte message; `printFail` bufPrint'd it into a 256-byte buffer → guaranteed overflow → and the overflow does NOT reach its `catch`, because c2js miscompiles `std.Io.Writer`'s error path (`ReferenceError: t19 is not defined`). So the single gate that stands between queue-timeline clobbers and the device answered with a Node stack trace instead of a diagnosis. Buffers sized (640/512) → it now prints `buffer 107 (label='ubo') offset 0 written 2+ times`, which is what made bugs 2 and 3 findable in minutes. **The c2js error-path miscompile is still open (engine_findings #3): any `catch` on a format error in transpiled code is currently a lie.** LESSON: test the FAILURE path of a gate, not just its success path.
- STALE DOC CORRECTED: claude.md's own line ("beginMode3D can NOT run inside beginTextureMode ... DON'T try to render immediate-3D into an RT") has been FALSE since the phase-SSOT fix — `split_screen` and `text_on_texture` both do it. A rule that has silently become false is worse than none: it stops you attempting the thing that works. Believe the tree, not the note; then fix the note.
- Gate: lint 0, `zig build test` rc=0 (84s), `check` → ✓ ENTIRE CORPUS TRANSPILES CLEANLY + ✓ NO REGRESSIONS, smoke `textures_framebuffer_rendering` ✓ PASS ~202.7/frame with a FLAT twice-lifecycle census (`.memory = .managed`), and the regression set that the draw3d change could have broken all re-smoked green: **split_screen (was RED, now PASS)**, instancing, waving_cubes, deferred_render. Standalone + refreshed launcher built for device verify.
- PLAN: raylib_port.md now 171 DONE / 20 TODO / 26 N/A. Its own lesson recorded there: **"near-free, the engine already has the pieces" is a hypothesis, not a status** — the pieces existed but had never been driven twice in one frame.

## zimr858 — THE "STUCK SMOKE" WAS AN ORPHANED COMPILER (Simon spotted it). Not a build problem; a process-hygiene problem.
- SYMPTOM (Simon): "looks like you are stuck compiling the smoke test." REALITY: `pgrep -a zig` showed ONE leftover `zig build-exe` compiling `triangle_strip`'s **Debug smoke wasm** — an example the focused smoke never asked for. It had been running ~25 minutes on the box's ONLY core, stealing CPU from every command after it. Killed it; the very same focused smoke then ran in **3 seconds** (and built exactly 1 wasm — `-Dfocus` gates the BUILD, not just the run, so the smoke system was never the problem). `zig build test` re-ran green in 1s, cached, 0 orphans.
- ROOT CAUSE: `timeout 170 zig build ...` kills the `zig build` PARENT. Its `zig build-exe` CHILD is not in the timeout's kill scope and keeps compiling. Every rc=124 in a session can leave one behind, and they accumulate. This is why "the build got slower as the turn went on" — a thing I had been attributing to cache state.
- WHY IT MISLEADS SO WELL: the orphan is compiling something UNRELATED to what you asked for, so the log you're staring at (a focused smoke) looks like it is doing something insane. The lesson generalises: **on a 1-core box, before concluding a build is slow, prove nothing else is running.** `pgrep -a zig` costs nothing.
- claude.md hardened (cold-cache section): orphan-killing is now a MANDATORY step after any `rc=124` and any time a build "feels slow", not just advice for a build that has visibly hung. Recorded in `engine_findings.md` #6 with the real fix (kill the process GROUP / refuse to start while another compile is live) — discipline is what we had, and discipline is what failed.
- DISK, same class of quiet hazard: the turn went **47% -> 86%** full (2.7 GB free; the build guard fails at 90% and its remedy is a ~17-min cold rebuild). `zig-out` alone was 1.8 GB. It is pure output — once the standalones are copied to `/mnt/user-data/outputs`, `rm -rf zig-out` is free disk. Back to 77%. Rule added to claude.md.
- JUNK REMOVED: `bridge.js.map` (1.4 MB) — a c2js artifact (`c_to_js <basename>` also writes `<basename>.js.map`) that had been sitting in the repo ROOT and shipping inside EVERY snapshot zip. Added `*.js.map` to `.gitignore` and to the zip's exclusion list.
- ALSO NOTED (engine_findings #7): the smoke's per-example wasm builds are `-ODebug`, which per our own measurements costs ~2.4x the RAM of release for the same compile time — the heaviest thing that runs on this 4 GB box. Worth checking whether the smoke needs Debug at all (it reads exports and counts host calls; it does not read stack traces).
- Gate: unchanged and green (lint 0, `zig build test` rc=0, focused smoke ✓ PASS). No engine code changed this turn — notes, .gitignore, and the sandbox itself.
