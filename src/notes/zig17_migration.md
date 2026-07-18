# zig17_migration.md — Zig 0.16 → 0.17 (master) migration

Target toolchain for this arc: **`zig 0.17.0-dev.639+284ab0ad8`** (Simon-supplied).
0.17.0 tag is "a couple weeks" out (devlog 2026-05-26). Do the work now; keep the
readme/build pin at **0.16.0 until 0.17.0 actually tags**, then flip it.

## The one fact that explains everything (READ FIRST)

The Zig build system was split into a **configurer** + a **maker** (devlog
2026-05-26, "Build System Reworked", PR 35428). `build.zig` now compiles into a
small *configurer* that builds the graph in memory and **serializes it** to a
binary config file; a **separate, release-mode "maker" process** then executes
that graph (compiled once per `zig version`, cached globally).

Consequence that bites us: **there is no longer any place to run a user `makeFn`
closure** — a closure from the configurer's address space can't cross into the
separate maker process. `Step.makeFn`, `Step.MakeOptions`, and the `.custom`
`Step.Tag` are all **deleted** (verified: none exist anywhere in this toolchain's
`std/Build`). That is why `build.zig` won't even *configure* on master.

The fix pattern for every custom step: **express the logic as either a built-in
step kind (CheckFile / InstallDir / WriteFile / UpdateSourceFiles) or as a small
Zig CLI invoked via `addRunArtifact`.** The make-fn *bodies* move almost verbatim
into a tool `main()` — relocation, not rewrite. zimr already has a `tools/` dir
full of build-time CLIs, so this is idiomatic here.

Andrew's framing: the rework is *mostly* non-breaking at the API level (high-level
`addExecutable`/`addRunArtifact`/`installArtifact`/`addModule`/`addAnonymousImport`
all survive — verified). The one change "most people" hit is `b.args` →
`addPassthruArgs()`. zimr is in the minority that *also* defined custom `makeFn`
steps, so we hit a second class of breakage on top.

## Why it's worth it (the payoff, not just the tax)

Once green: `--watch -fincremental` + the new ELF linker (x86_64-linux) give
ms-scale rebuilds (devlog: Tetris ~30 ms; compiler ~250 ms), and `zig build -h`
drops ~150 ms → ~14 ms because the serialized config is reused instead of
re-running `build.zig`. For a project whose whole gate is "keep the warm loop
under a few seconds," this is the prize. There's also `--fork=<path>` for working
through any dependency breakage against a local checkout.

## Breakage buckets (evidence-backed)

**B — Build system (the real work). All in `build.zig` + `tools/build.zig`.**
- 5 custom `makeFn` steps (dead `Step.init(.{ .id = .custom, .makeFn = … })`):
  test-printer, `dist_copy`, `WgpuStandalone` (×4 uses), `FixtureGlslCheck` (×2),
  `FixtureWgslCheck`.
- `b.args` ×2 (build.zig 2811 dist/serve, 2917 lint) → `addPassthruArgs()`.
- `b.build_root.handle` ×2 (tools/build.zig ~210, ~422) → field removed.

**S — Source / stdlib: looks essentially clean (happy surprise).**
- `src/zimrmath.zig` (288 KB, biggest std-only leaf) compiles clean to wasm32.
- Already on current idioms: unmanaged `std.ArrayList` (`= .empty`,
  `.initCapacity(alloc, …)`), zero `std.io.` writergate calls, zero
  `usingnamespace`, zero `std.mem.split(`; already on `std.Io.Dir` / `b.graph.io`;
  tools already use `pub fn main(init: std.process.Init)`.
- `ArrayListUnmanaged` (61 uses) survives as a **deprecated alias** → still
  compiles. Cleanup later, not a blocker.
- CAVEAT: only one module proven end-to-end. The full lib + ~150 examples can't
  compile until build.zig configures, so a tail of small source breaks may still
  surface. Confidence high, not certain.

**T — Toolchain / process notes.**
- Maker compiles once per `zig version` (global cache): fresh sandbox pays a
  one-time maker compile, then faster.
- `tools/spirv-prebuilt-linux-x86_64/` is **excluded from the zip** → the
  shader-pipeline gates (`tier-a-check`, `wgpu-check`) need the ~10-min
  from-source SPIRV-Tools/Cross build here (`-Dprebuilt-spirv=false`), or get
  skipped for a pure source survey.
- **T4 — Zig master bug found (dev.639): the configurer SEGFAULTS serializing a
  `Fmt` step's LazyPath `paths`.** GP-fault in `Configuration.addString` via
  `addOptionalLazyPathEnum` → `initLazyPathList` → `serialize`. Isolated with a
  6-line minimal `build.zig` (`b.addFmt(.{ .paths = &.{b.path("build.zig")} })`
  crashes; a minimal exe + addRunArtifact + addFileArg + installArtifact build
  configures fine — so the bug is **Fmt-specific, not general LazyPath**).
  WORKAROUND (applied, B8): both `b.addFmt(...)` replaced with
  `b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", [--check], "src", "examples",
  "build.zig", "tools/lint_zimr.zig", "tools/build.zig" })`. TODO: file upstream
  for 0.17.1; revert to `b.addFmt` once fixed.

## Steps (tagged)

### B — build-system migration (gets `zig build --help` to configure)
- **B1 — DONE.** `tools/build.zig`: `b.build_root.handle` → `b.root.root_dir.handle`
  ×2 (210, 422). `Build.build_root` field removed; `Build.root` is a `Cache.Path`
  whose `root_dir.handle` is the `Io.Dir`. tools/build.zig now configures green.
- **B1b — DONE (bonus, same shape).** `build.zig` 751: removed `b.pathFromRoot(rel)`
  (gone in 0.17) → `b.root.root_dir.handle.access(io, rel, .{})` (root-relative,
  no absolute path needed).
- **B2 — DONE.** `build.zig`: deleted the `test_step.makeFn` printer (528–532).
- **B3 — DONE.** `build.zig`: the lint step *read* `b.args` to detect file-path
  args — and `b.args` is gone entirely (capability removed). Reworked: file
  targeting now via `-Dlint-files=a.zig,b.zig` (observable build option); flags
  (`--quiet`/`--only=`/`--skip=`) flow through `addPassthruArgs()`.
  USER-FACING CHANGE: `zig build lint -- src/foo.zig` → `zig build lint
  -Dlint-files=src/foo.zig`. TODO: update claude.md + readme.html lint docs.
- **B4 — DONE.** `tools/buildaux.zig` written (zspv.zig template; built as a
  MAIN-build `addExecutable` host exe). Subcommands all ported + smoke-tested
  (correct exit codes, errors to stderr): `check-glsl-header`, `check-wgsl-clean`,
  `wgpu-standalone <wasm> <js> <title> <out>`, `dist-copy`. The
  `WGPU_STANDALONE_TEMPLATE` const moved from build.zig into buildaux.zig.
- **B5 — DONE.** Rewired the 3 fixture checks → `addRunArtifact(buildaux …)` +
  `addFileArg(lp)` + `expectExitCode(0)`; deleted both Fixture* structs.
- **B6 — DONE.** Rewired `dist_copy` → `addRunArtifact(buildaux dist-copy)`;
  deleted `distCopyMake`.
- **B7 — DONE.** Rewired `WgpuStandalone.add` ×4 → new free fn
  `addWgpuStandalone(b, buildaux_exe, …)` (addRunArtifact + addFileArg(wasm) +
  string args for js/title/out, writes directly to prebuilt/standalone/); deleted
  the `WgpuStandalone` struct. (Possible later hardening: use `addOutputFileArg`
  + an install step for the HTML instead of a literal prebuilt/ path.)
- **B8 — DONE. `zig build --help` CONFIGURES GREEN** under master; all steps
  present (test, lint, lint-check, dist, fmt, wgpu-check, wgpu-*-standalone, …).
  Hit a real **Zig master bug** on the way — see T4.

### S — source verification (after B8)
- **S1 — DONE (src + examples).** The substantive source breakage was the
  removed `**` operator; both `src/` (session 3, 25 sites) and `examples/`
  (session 4, 25 sites) are now `**`→`@splat` clean and fmt-green. Sampled
  modules typecheck as wasm32. Remaining whole-program typecheck = S3.
- **S2** (non-blocking cleanup) `ArrayListUnmanaged` → `ArrayList`.
- **S3** Full unfocused `zig build test` once SPIRV prebuilts exist or are built.

## Open questions for Simon (parked)
- Flip the readme/build pin off `0.16.0` only when `0.17.0` tags? (rec: yes)
- FixtureGlslCheck: accept "contains" via built-in CheckFile, or keep exact
  startsWith via buildaux? (current plan: buildaux, exact semantics preserved)

---

## Progress log / STATUS  ← update at END of every session, read at START

**STATUS (session 6 — `tools/lint_zimr.zig` made 0.17-clean; standalone is
C++-SPIR-V-gated):** Chasing a `zig build wgpu-lambert-standalone` request, the
`tools_subbuild` step (builds `lint_zimr` + the C++ SPIR-V tools) surfaced **two
real 0.17 regressions in `lint_zimr.zig`**, now fixed: (1) `Allocator.dupeZ` was
removed → replaced with `allocSentinel` + `@memcpy` (line ~1954, the
`Ast.parse` source buffer); (2) the linter's own `checkArrayMult` rule + the
`.array_mult` case in its binary-op tag list referenced the **`array_mult` AST
node, which 0.17 deleted alongside the `**` operator** — removed both (the rule
is self-obsolete now that the compiler rejects `**`). `lint_zimr.zig` compiles
to a native object under 0.17 and is fmt-clean. The other tools (`spv2wgsl`,
`zspv`, `zglsl`) already build; only the **C++ SPIR-V tools remain**.

**The standalone can't be produced on THIS sandbox.** `zig build
wgpu-lambert-standalone` → lambert wasm → `@embedFile lambert_vs/fs.wgsl` →
shader pipeline (`spirv-opt`/`spirv-val` → `spv2wgsl`) → `tools_subbuild`, which
must compile SPIRV-Tools+Cross from source. Single-core box, ~300 s/call cap,
no surviving background procs (see session 5) → est. ~40+ min of C++ (gauged
~22 s/object, ~120 objects left). Cache persists, so it's grind-able across
turns, but the right path is to run the command on Simon's machine with
`tools/spirv-prebuilt-linux-x86_64/` present (instant, no C++ build).

**STATUS (session 5 — S3 attempted; blocked by sandbox, partial signal clean):**
The full `zig build test` requires the from-source SPIR-V toolchain
(spirv-opt/val/cross), and **this sandbox cannot build it in-budget**: `nproc=1`
(serial C++ build of SPIRV-Tools + SPIRV-Cross), the per-call wall-clock cap is
~300 s, and **background (`nohup &`) processes do NOT survive between tool calls**
(a `pgrep -f "build-file tools/build.zig"` false-matches the poll shell itself —
the real build dies when its launching shell exits). Partial C++ objects are
cached in `tools/.zig-cache` (no lock files; cache is clean), so a resume is
warm, but completion isn't reachable here. This is an environment limit, not a
migration problem.

**S3 partial signal (SPIR-V-free, achievable per-call): clean.** Typechecked 6
more `src/` modules as wasm32 objects — `physics`, `scene`, `shader_introspect`,
`gpu_iface`, `rlsw_shader`, `rlsw_pixel` — all compile. Combined with session-3
(`drawing`, `ui`, `runtime`, `shader_runtime_wgpu`, `zimrmath`), a broad
cross-section of the library is now proven clean under 0.17. **No new source
breakage beyond `**` (already fixed).** Confirmed the known-red baseline cause:
`src/render.zig` `@embedFile`s generated GLSL (`pbr_/shadow_/unlit_/lambert_/
skybox_ vs|fs.glsl`) that only exist after the shader pipeline (SPIR-V) runs —
the dying WebGL/GLSL 3D path, red on 0.16 too.

**NEXT (resume S3):** run the full `zig build test` where the SPIR-V tools are
available — either (a) on Simon's machine with `tools/spirv-prebuilt-linux-
x86_64/` restored (instant, no C++ build) or a multi-core box, or (b) if forced
onto this single-core sandbox, drive the C++ build to completion in foreground
chunks (each <300 s; the cache makes each call resume) until
`tools/zig-out/bin/{spirv-opt,spirv-val,spirv-cross}` exist, then `zig build
test` and classify any failures as known-red-4 (render/rlgl/renderer_2d/
typed_unlit_demo embeds) vs genuine 0.17 regressions. Expectation given the
signal so far: only the known-red embeds fail.

**STATUS (session 4 — examples `**` sweep DONE; `zig build fmt` GREEN):**
The deferred `examples/` `**`→`@splat` sweep is complete: all 25 operator sites
across 10 files converted (`life`, `keys`, `particles` [multi-line, by hand],
`gestures_testbed` [nested → `@splat(@splat(0))`], `ui_dock_persistence`,
`ui_input_flags_zoo_phone` [13], `ui_log_viewer` [`@splat(.info)`], `ui_notes_phone`,
`ui_shortcuts`, `ui_window_menubar`). `zig fmt --check examples` 10→0 errors; the
nested/struct/enum `@splat` forms verified to type-check; and **`zig build fmt`
now passes end-to-end** (src + examples + build.zig + tools + lint_zimr.zig).
Re-verified this session that the **whole maker pipeline executes** (the `fmt`
step ran configurer→serialize→maker→`zig fmt` for real) and `tools/buildaux.zig`
compiles native — i.e. the B-track migration is functionally sound, not just
configure-green.

Prior milestone (session 3): **all of B1–B8 done + verified**, configure green,
full step graph intact, one Zig master bug found+worked-around (**T4**, Fmt-step
LazyPath serialize segfault → `zig fmt` via addSystemCommand).

**NEXT — superseded; see session-5 STATUS above. (Session-4 view:)** S3 — the
full `zig build test`. With both `src/` and
`examples/` now `**`-clean and fmt-green, the remaining unknown is whatever the
full typecheck/test surfaces. It needs the SPIR-V pipeline (spirv-opt/val/cross),
whose prebuilts are absent here → build from source (~10 min,
`-Dprebuilt-spirv=false`). The four GLSL `@embedFile` consumers (rlgl.zig,
render.zig, renderer_2d.zig, typed_unlit_demo.zig) are KNOWN-RED (the dying
WebGL/GLSL 3D path) and will fail their embeds without the generated shaders —
those are not 0.17 regressions; classify any *new* errors separately. **S2**
(ArrayListUnmanaged→ArrayList) stays non-blocking cleanup.

**S1 progress (this session) — the substantive source breakage was `**`:**
Zig 0.17 **removed the `**` array/tuple-repeat operator** (0.17 std uses it zero
times outside a comment; `x ** n` now mis-parses as `x * (*n)` →
"binary operator '*' has whitespace on one side…" or "expected type, found
comptime_int"). `zig fmt` does NOT fix it. The replacement is **`@splat`** (works
for scalar- AND array-element fixed arrays; nested repeats →
`@splat(@splat(x))`). Fixed all 25 `**` sites in `src/` → `@splat`; `zig fmt
--check src` went 15 errors → 0; the previously-failing `drawing`/`ui`/`runtime`/
`shader_runtime_wgpu` now build clean as wasm32 objects. Configure still green.

**Tidy-ups (non-blocking):** 3 stale code comments still name deleted symbols
(build.zig ~1630 "WgpuStandalone.add", ~2011 "FixtureWgslCheck", ~2770
"distCopyMake") — cosmetic, fix on next pass. Update lint-CLI docs in claude.md +
readme.html for the `-Dlint-files` change (B3). File the T4 Fmt bug upstream.

**Already done — don't redo:**
- `Step.makeFn`/`MakeOptions`/`.custom` gone; removed-API fixes applied:
  `build_root`→`b.root.root_dir.handle`, `pathFromRoot` removed, `b.args` removed
  (→ `-Dlint-files`), `Fmt.Options.paths` now `[]const LazyPath` (but Fmt itself
  segfaults — T4).
- buildaux subcommands smoke-tested (exit codes correct).
- Minimal repros saved: `/tmp/fmtrepro` (Fmt crash), `/tmp/lprepro` (exe+run+
  install configures fine — proves LazyPath generally OK).
- `zimrmath.zig` compiles to wasm32; `tools/zspv.zig` + `tools/buildaux.zig`
  compile native.
- Env: `. /home/claude/zenv` → zig 0.17.0-dev.639 + bun 1.3.14 on PATH; `zig
  build` uses PATH; tools subbuild via `--build-file tools/build.zig
  -Dprebuilt-spirv=false`.
