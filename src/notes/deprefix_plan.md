# Plan: drop the `wgpu_` prefix from example folders/files/steps

## Why it's tractable
The prefix is NOT stored per-folder in build.zig — it's SYNTHESIZED centrally from the
clean registry `.name` (e.g. "rectangle_advanced") in exactly three `b.fmt` spots:
- build.zig ~3226 (buildUserModShared): `const under = b.fmt("wgpu_{s}", .{name});`
  then `root_source_file = examples/{under}/{under}.zig`
- build.zig ~3334 (standalone/step helper): same `under = b.fmt("wgpu_{s}", .{name})`
- build.zig ~3344: `const dash = b.fmt("wgpu-{s}", .{dash_name});`  (step names)
`under` drives: folder path, entry-file name, exe `.name`, `{under}.html`, smoke focus.
`dash` drives: `zig build <step>` and `<step>-standalone`.
The served gallery dir is ALREADY clean (`web/{name}`), not `web/wgpu_{name}`.

## Scope (measured)
- 187 `examples/wgpu_*/` folders; ~164 registry-driven. Each has ONE prefixed thing:
  the folder + entry `wgpu_<name>.zig`. NO sub-file (shader/io/index) carries the prefix
  (verified) — so rename = folder + entry file only, leave sub-files alone.
- Special, explicitly-pathed (NOT registry-driven):
  - examples/wgpu_common/common.zig  (refs: build.zig 1128, 3236, 3789; module name
    "wgpu_common" imported by 64 example files + 3 addImport)
  - examples/wgpu_demo/wgpu_demo.zig  (build.zig 872, 976; exe/step "wgpu_demo")
  - examples/wgpu_launcher/wgpu_launcher.zig  (built via registry helper name "launcher")
  - examples/wgpu_trivial_{vs,fs}{,_io}.zig  (build.zig 950-956; shader scaffolds)
- Legacy `wgpu_examples` dashed list (build.zig 78..~242) -> drives gen-vscode; hand-kept,
  likely out of sync with the 164-entry registry.
- Cross-refs: src/web/readme.html (3 hits), src/notes/raylib_port.md, claude.md,
  generated .vscode/.zed configs, prebuilt/standalone/*.html names, the snapshot recipe's
  `cp .../wgpu_<name>.html`.

## SCOPING DECISION (important): keep "wgpu" where it means the BACKEND
"wgpu" legitimately names the WebGPU backend. Only EXAMPLE identity should lose it. KEEP:
`wgpu-check` (the gate), `wgpu_smoke`, `wgpu-standalone` (generic 2D), `zimr_wgpu.ts`,
backend module names. REMOVE: per-example folders/files/steps/html.

## Decisions needed from Simon
1. Step names: rename `wgpu-<name>` -> `<name>` too (so `zig build rectangle-advanced`)?
   (Recommended yes, for consistency; it changes muscle-memory + the vscode list.)
2. examples/wgpu_common -> examples/common: rename the FOLDER only (cheap: 3 build.zig
   paths) and KEEP import name "wgpu_common"? OR also rename the import to "common"
   (touches 64 example files + 3 addImport). (Recommended: rename both for a clean break,
   it's a mechanical sed.)
3. wgpu_demo / wgpu_trivial_* / wgpu_launcher: de-prefix these too? (Recommended yes.)

## Phased execution (each phase ends GREEN before the next)
Phase 0 — guard: snapshot first (rollback point). No git in env, so the snapshot zip IS
  the rollback.
Phase 1 — central build.zig flip (no disk renames yet, will fail to build — do WITH Phase 2):
  - `under`: `b.fmt("wgpu_{s}",.{name})` -> `name` (both ~3226 and ~3334).
  - `dash`: `b.fmt("wgpu-{s}",.{dash_name})` -> `dash_name`.
Phase 2 — rename registry-driven folders+entry files (script):
  for each registry name N: `mv examples/wgpu_<N> examples/<N>` then
  `mv examples/<N>/wgpu_<N>.zig examples/<N>/<N>.zig`. Drive the loop from the actual
  registry list (extract the `.name=` entries from build.zig), NOT a glob, so non-registry
  infra folders are skipped. Run Phases 1+2 together, then `wgpu-check`.
Phase 3 — special infra:
  - common: `mv examples/wgpu_common examples/common`; update build.zig 1128/3236/3789;
    if renaming import: sed `@import("wgpu_common")`->`@import("common")` across examples +
    `addImport("wgpu_common"`->`addImport("common"`.
  - demo/trivial/launcher: rename folders+files + their explicit build.zig paths + the
    `.name="wgpu_demo"` and launcher entry.
Phase 4 — legacy vscode list: either regenerate `wgpu_examples` from the registry (kills the
  duplicate source of truth) or strip `wgpu-` from each entry; re-run gen-vscode.
Phase 5 — cross-refs + outputs: readme.html, raylib_port.md, claude.md, regenerate
  prebuilt/standalone/*.html under new names, update the snapshot recipe (cp `<name>.html`).
Phase 6 — full verify: lint whole tree, `wgpu-check` GREEN, node-instantiate a couple of
  standalones, build the launcher, build a few standalones and confirm `<name>.html`.

## Risks / gotchas
- Half-rename breaks the build -> do central flip + folder rename in ONE commit, gate once.
- Drive the rename from the registry list, not `ls wgpu_*`, to avoid clobbering infra.
- The `wgpu-check`/smoke focus uses `under`; verify smoke still resolves after rename.
- Keep backend "wgpu" names; don't over-strip.
- 187 renames: script + verify count before/after.

## Recommended call
Do Phases 1+2 first as a self-contained green change (the bulk win: clean folders/files +
clean steps + clean html), snapshot, THEN Phase 3-5 as a follow-up. This de-risks the big
rename from the infra rename.

## STATUS (zimr472)
DONE this pass (all GREEN via wgpu-check):
- Central flip: 4x `under = name`, 1x `dash = dash_name`, 1x dep `app.name` (all wgpu_/wgpu- prefixes gone from derivation).
- Renamed 185 example folders + entry files -> examples/<name>/<name>.zig; steps <name>/<name>-standalone; html <name>.html. Verified (rectangle-advanced-standalone -> rectangle_advanced.html).
- Resolved 2 step-name collisions: native PNG steps julia-gallery->julia-gallery-png, comptime-julia->comptime-julia-png (the clean names go to the wgpu examples).
- example_common: examples/wgpu_common/common.zig -> examples/example_common/example_common.zig; import "wgpu_common"->"example_common" across 64 example files + 3 build addImport + 3 build paths + headers.
- vscode/zed: regenerated for ALL 187 example steps with clean names; renamed const wgpu_examples->example_steps + gen_vscode anchor; 0 wgpu refs in .vscode/.zed.

DEFERRED (next passes, each its own gated commit):
- Gallery manifest src/web/manifest.json: NOT broken by rename (already clean names, served dir web/<name>). Simon wants it to list ALL examples (currently 135 curated of ~187). Additive: merge registry/folder set into the manifest, preserving stars/descriptions/module for existing, sensible defaults for new. Needs care re: the "module" grouping field.
- demo/trivial de-prefix: wgpu_demo (30+ build refs, own shader/smoke/page/standalone wgpu_demo.html wiring, in smoke_focus CSV) and wgpu_trivial_{vs,fs}{,_io}.zig (shared shader name used by 8 registry entries via .shaders). Higher-touch; do as a focused commit.
- zimr_wgpu.ts -> zimr.ts: 65 refs across core (zimr.zig, wgpu.zig, bridge.zig, draw3d.zig, build.zig, tests) + a few examples + tutorials. WATCH: the symbol/import token "zimr_wgpu" renaming to "zimr" may collide with the existing zimr module/alias — rename the .ts FILE to zimr.ts but pick a non-colliding symbol (or verify no clash) for any zig-side alias.
- Infra step names: wgpu-check->check, wgpu_smoke->smoke, wgpu-standalone->standalone (decouple the gate command rename so verification stays stable mid-change).

## STATUS (zimr473)
- wgpu_demo -> wgpu_bringup (Simon: the name was weird; this app IS the wgpu-stack bringup/validation app
  -- "first complete zimr-wgpu app", raylib-parity 2D on engine-default hand-written WGSL, typed UBO/texture
  paths, and the subject the wgpu_smoke harness drives -- so it KEEPS wgpu, with a name that says what it is).
  Renamed folder+file + all build.zig refs (module/exe/page/standalone html wgpu_bringup.html/step wgpu-bringup/
  smoke wasm path/.name) + webtests/wgpu_smoke.zig default path + comment refs in trivial/lambert/cube. GREEN.
- ALSO fixed latent stale tier-a smoke_focus CSV from zimr472: wgpu_cube3d/compute_smoke/shapes_showcase/
  ui_color_picker/mandel_sidebyside/ui_dock_simple/ecs_solar_system -> de-prefixed (wgpu_bringup kept). Verified
  all folders exist. Standalone step for the bringup app is `wgpu-standalone` (generic 2D), builds wgpu_bringup.html.

## STILL DEFERRED
- wgpu_trivial_{vs,fs}{,_io}.zig (shared shader files; referenced by 8 registry entries via .shaders=&{"wgpu_trivial_vs"}).
- gallery manifest all-examples.
- zimr_wgpu.ts -> zimr.ts (65 refs; watch `zimr` symbol clash).
- infra step names: wgpu-check->check, wgpu_smoke->smoke, wgpu-standalone->standalone.

## STATUS (zimr474)
DONE (GREEN via `zig build check`):
- Infra step names de-wgpu'd: wgpu-check->check, wgpu-smoke->smoke, wgpu-smoke-install->smoke-install,
  wgpu-standalone->standalone, wgpu-corpus->corpus, wgpu-corpus-refresh->corpus-refresh, wgpu-diff->corpus-diff.
  KEPT wgpu-bringup (the backend bringup app). THE GATE IS NOW `zig build check`.
- Collision: renamed wgpu-smoke-install->smoke-install clashed with a pre-existing legacy ReleaseSafe
  `smoke-install` (still wired via 2 dependOn) -> renamed THAT legacy one to `smoke-install-safe`; live wgpu
  successor keeps `smoke-install`. (Lesson: the line-based collision pre-check misses multiline b.step(\n "x");
  use the regex `b\.step\(\s*"name"` over the whole text.)
- Updated external refs to the renamed steps: src/web/readme.html, webtests/transpiler_corpus.zig,
  tools/file_descriptions.zig, tools/spv2wgsl_check.zig.
- zimr_wgpu cleanup: the file src/web/zimr_wgpu.ts NO LONGER EXISTS (the browser runtime is src/bridge.zig ->
  c2js). Removed every live-ish zimr_wgpu mention: comments in src/{zimr,wgpu,bridge,draw3d}.zig + build.zig
  (incl. rewording the stale "converging zimr_wgpu INTO zimr" narrative), file_descriptions.zig (repointed the
  dead .ts atlas entry to src/bridge.zig), tutorial HTML @import("zimr_wgpu")->@import("zimr"), ui_panes mock
  code strings, and neutralised tools/gl2wgpu_ui.py's obsolete import-rewrite. Regenerated src/notes/files.md
  (0 zimr_wgpu). Left purely-historical mentions in journal.txt + blog_zimr_architecture.md.

## STILL DEFERRED (last de-wgpu items)
- wgpu_trivial_{vs,fs}{,_io}.zig shared shader files (referenced by 8 registry entries via .shaders=&{"wgpu_trivial_vs"} + sh_name/source_path/io_path wiring ~build.zig L949-956,1221-1342).
- gallery manifest src/web/manifest.json all-examples expansion (manifest is STATIC, already clean names, ~135 of ~187; additive, preserve stars/descriptions/module grouping).

## STATUS (zimr475) — DE-WGPU COMPLETE
- wgpu_trivial_{vs,fs}{,_io}.zig -> trivial_{vs,fs}{,_io}.zig: renamed 4 files + global wgpu_trivial->trivial
  across build.zig (sh_name/source_path/io_path + 8 .shaders refs) and ~12 consuming examples (@import io,
  @embedFile .wgsl, _externs). GREEN.
- Gallery manifest src/web/manifest.json: added the 25 missing examples (Wave-A shapes ports + pipeline_*) with
  descriptions pulled from each source //! header, heuristic module, neutral stars; now 160 examples, valid JSON.
- Stale self-references swept: 203 `wgpu_<example>` refs across 140 files (mostly the //! header self-name +
  ui_panes mock strings + a few src/ canonical-example refs) de-prefixed precisely (name-set match, never the
  backend tokens wgpu_texture/wgpu_app/WgpuGl/etc). readme.html wgpu_shapes_showcase fixed.
- REMAINING wgpu is ALL intentional backend: src/wgpu.zig, wgpu_texture.zig/WgpuTexture, shader_runtime_wgpu.zig,
  wgpu_app, WgpuGl, wgpu_ns (bridge), the wgpu_smoke harness, and the deliberately-kept wgpu_bringup app.
  The de-wgpu refactor is DONE.
