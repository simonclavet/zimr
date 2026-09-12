# finishing_webgpu.md

The near-term plan for finishing the WebGPU subsystem. Sits *below*
`finishing_new_gpu_foundations.md` (the long-horizon plan): that one
thinks in whole feature areas; this one thinks in the next several
sessions and is meant to be **concrete and precise** — every item names
files, the verification gate, and the done-condition.

Prior versions of this file are archived (`archive/finishing_webgpu_pre-cardioid.md`
= the blank-fractal hunt; `archive/finishing_webgpu_pre-t815.md` = the
pre-this-rewrite plan). The durable system map is preserved in §6.

---

## §0. STATUS (read this FIRST)

**LATEST (turn ~868) -- PBR Ubo migration DONE, and the DamagedHelmet is ported
to wgpu with full PBR textures (both Chrome-confirmed by Simon). The PBR/GLTF
path is now proven end to end; the remaining work is breadth: port ALL examples
to wgpu, then delete the entire WebGL/GL path. That is the new north star (see
section 8). The SCCP / transpiler / uniformity items below are historical
context -- that pipeline work is done.**
- PBR FS uniforms went from 18 loose `@group(2)` uniform-buffer bindings (which
  exceeded the device `maxUniformBuffersPerShaderStage`=12 and silently
  invalidated the pipeline -> blank canvas) to a SINGLE `Ubo` block at
  `@group(2) @binding(0)`. `pbr_fs_io.Uniforms` became an `extern struct Ubo`
  (vec3s widened to vec4, light arrays vec4-strided, scalar tail = two 16-byte
  rows; @sizeOf 368, %16==0, no interior pad). The codegen
  (`gen_shader_externs.zig`) `Ubo` path is now stage-segregated (VS Ubo -> set 0,
  FS Ubo -> set 2) in BOTH emission sites; the operative one was
  `installSpirvEntry` (the path that actually reaches SPIR-V) -- fixing only
  `setup()` left the block at group 0. Chrome: lit textured cube at 120fps
  (per-face shading proves the FS reads the Ubo correctly).
- DamagedHelmet on wgpu (repurposed `wgpu_pbr_demo`): parse the glb at init
  (`codecs.gltf.parse` + `meshesFromGltf`, pure / GL-free), interleave 14556
  verts into the PbrVertex buffer, 46356 u16 indices; decode the 5 embedded
  JPEGs (`codecs.jpeg.decode`) into 5 wgpu textures (baseColor + emissive
  `rgba8_unorm_srgb`, MR / normal / AO linear, `.repeat` wrap because the helmet
  V texcoords run [1,2]); inline tangent generation (Lengyel) since the glb
  ships no TANGENT and the GL-side `prepareMeshFor` lives in the heavy
  drawing.zig. Material: metallic / roughness = 1 (MR map drives them),
  emissiveFactor = [1,1,1].
- THREE structural enablers, each a reusable pattern for the broader port:
  (1) `codecs` is re-exported FROM `zimr_wgpu` (`pub const codecs =
  @import("codecs.zig")`) instead of being its own module -- `rlsw` already
  pulls `types.zig` into the zimr_wgpu module and a file may belong to only one
  module, so a separate codecs module collided on types.zig. (2) `zimr_wgpu`
  now wires the `zm` named import (codecs needs it; rlsw was lazy so it had been
  unneeded). (3) the wgpu JS bridge (`zimr_wgpu.ts`) now provides `dom.js_log`
  -- codecs' glTF error path imports it, and without it the wasm fails to
  instantiate in Chrome (the smoke harness got the same stub).
- Verified without a GPU at each step: `wgpu-smoke` runs `_initialize` (full glb
  parse + tangents + 5 JPEG decodes + 5 texture creates, no trap) plus 60
  frames; naga + nagac validate the PBR WGSL; lint / fmt / ast clean.
- Deferred (Simon's standing ask): make host<->shader std140 Ubo mismatches a
  compile / lint error with a good message (the 368-byte `FsUbo` host mirror in
  the demo must match the shader `Ubo` byte-for-byte; today only a `@sizeOf%16`
  assert guards it).

**LATEST (turn ~867) — PBR uniformity: shader restructured + build-time lint
added. The earlier one-line shadow reorder was NOT enough — `computeShadow`
is still *called* conditionally (`if (i == 0)`) inside the directional loop,
so Tint still saw its shadow_map sample as non-uniform (`pbr_fs:1516`). The
robust fix (Simon's call): "we can't call a sampler from a branch — avoid it
in our shader, and add a lint." So ALL six texture samples (base color, MR,
normal, occlusion, emissive, shadow_map) are now taken UNCONDITIONALLY at the
top of `pbr_fs_shaderMain`, before any if/loop, and their values threaded
down; `computeShadow` is sample-free (takes a pre-sampled `closest_depth` +
`proj_coords`). Structural proof in the generated WGSL: all 6 sampler-helper
calls land at lines 355-506, the first if/loop is at 547 → every sample is in
the function's uniform entry region. naga validates (no regression).
**Confirmed this turn: NEITHER naga NOR nagac enforces the WGSL uniformity
rule** (both validate a `textureSample` inside an `if`), so Tint (Simon's
Chrome) is the only authority → pending Simon's reload of the freshly-built
2.1 MB `prebuilt/standalone/wgpu_pbr_demo.html` (the `pbr_fs:1516` screenshot
is the OLD build; the rebuilt shadow_map call is at line 506).
NEW build-time guard: `tools/zimrlint.zig` gained a `sampler-at-top`
discipline (tags `sampler-in-branch` / `sampler-in-helper`). Schema-free
detection — samplers are the only *callable* members of an Io struct, so any
`io.<m>(...)` call is a sample; flagged unless it's a non-nested statement of
`shaderMain`. Catches the whole bug class at build instead of in Chrome.
Self-lint clean; all 15 shaders pass; negative test (sample in if + in
while-loop + in a helper) correctly flags 3. SCCP is RETAINED as a general
dead-code/unreachable cleanup but is no longer load-bearing for uniformity —
the sample-at-top discipline is.**
Symptom (real Chrome/Tint, screenshot): `wgpu_pbr_demo` fails with
`[wgsl:pbr_fs:1054] 'textureSample' must only be called from uniform control
flow` (+ two `code is unreachable` warnings at 627/758). The other demos
(2D, cube, lambert) render.
ROOT CAUSE (traced through the generated WGSL + pbr_fs.zig): all texture
samples are UNCONDITIONAL in the source, but the fragment body has two light
loops; the point-light loop's `continue` is gated on `dist > range` where
`dist` depends on `frag_world_pos` (per-fragment → NON-uniform). spv2wgsl
reconstructs the loop with a numeric phi-state machine and emits the entire
post-loop body (the `occlusion()`/`emissive()` sampling helpers, tone-map,
fog, output) under a guard `if (phi867 == 482u)`. That guard is **always
true** (the loop's only non-`continue` exit assigns 482u), i.e. SPURIOUS —
but `phi867` is data-derived from the non-uniform loop, so Tint's
inter-procedural uniformity analysis marks the guard non-uniform and rejects
the sampling helpers called under it. spirv-opt used to fold this guard
(mem2reg/SSA + const-prop + dead-branch-elim); the pure-Zig path (§2.2, no
spirv-opt) does not yet, so the guard survives. The unreachable warnings are
the same dead-CFG smell (the `return S317();` after break/continue).
INTERIM FIX — LANDED (`src/spv2wgsl.zig` `emitImageSample`): emit
`textureSampleLevel(t, s, uv, 0.0)` instead of `textureSample(...)` for
implicit-LOD samples. Explicit LOD has NO uniformity requirement, so the
error is gone. VERIFIED: pbr WGSL now has 0 bare `textureSample` (6 →
`textureSampleLevel`), all 3 wgpu standalones rebuild green with 0 C++ tools.
TRADE-OFF: forces mip 0 globally (identical for single-mip textures; loses
minification LOD otherwise) — a stopgap, clearly commented for removal.
Confirm pixels by reloading `wgpu_pbr_demo.html` in Chrome.
PRINCIPLED FIX (next, removes the interim) — **sparse conditional constant
propagation (SCCP) over the IR's merge-state phis**, then fold guards whose
condition is constant. Reference-grounded (SPIRV-Tools
`source/opt/dead_branch_elim_pass.cpp`: `GetConstCondition` → `MarkLiveBlocks`
→ `FixPhiNodesInLiveBlocks` → `EraseDeadBlocks` — but DBE only fires once the
condition is constant, which mem2reg+const-prop establish; SCCP fuses
const-prop + reachability in one ~few-hundred-LOC pass). After SCCP folds the
spurious guard, post-loop samples sit at uniform scope and faithful
implicit-LOD `textureSample` is valid again → revert the interim. This is the
right pure-Zig step and the next focused chunk; verify with naga
(`/home/claude/refs/naga-main`, build is slow on this 1-core box) + a Chrome
reload. Reference sources now under `/home/claude/refs/` (SPIRV-Tools, naga).


### Current reality (turn ~863)

The pure-Zig WGSL pipeline is live: `zig build-obj -target spirv* → zspv →
spv2wgsl → .wgsl`, with **no spirv-opt / spirv-val / spirv-cross on the WGSL
path** (§2.2 done). In a real browser (Chrome/Tint): the **2D, cube, and
lambert** demos render correctly; **PBR renders via the `textureSampleLevel`
interim** (the SCCP fix in the forward plan removes it and restores faithful
implicit-LOD sampling). The transpiler is **IR-walker-only** (the legacy walker
was deleted, §3.C). The C++ SPIR-V tools are still **vendored** but build-time
only and confined to the dying GL/`.glsl` path — never shipped, never on the
WGSL path.

**Current numbers (reconciled; update at end of each session):**
- Live shaders: **naga 39/39 valid** — every real zimr shader (vertex +
  fragment) translates from RAW (pre-opt) Zig SPIR-V to naga-valid WGSL.
- Tint corpus: **164 valid / 0 known-invalid / 13 unstructured-fallback** of
  181. The naga-invalid baseline is **EMPTY**.
- spv2wgsl host tests pass; lint 0.
- The 13 fallbacks are CFG-torture fixtures (Tint's own SPIR-V-reader unit
  tests), not shapes a real shader produces; they hard-error and are
  count-gated (legacy fallback is gone, §3.C).

### Forward plan (priority order — the best long-term path)

North star: a robust, FAITHFUL, pure-Zig SPIR-V→WGSL pipeline, with naga as the
standing oracle, then delete the vendored C++ tools. No silent semantic
shortcuts survive to the end state.

1. **[IN PROGRESS — the keystone] SCCP: sparse conditional constant
   propagation + dead-guard / dead-block elimination.** Highest leverage on the
   board. It simultaneously:
   - **removes the PBR interim** — folds the spurious always-true post-loop
     guard (`if (phi867 == 482u)`) whose condition is a constant phi, so the
     post-loop texture samples sit at uniform scope and faithful implicit-LOD
     `textureSample` is valid again (revert the `textureSampleLevel` stopgap);
   - **clears the `code is unreachable` warnings** (the dead blocks raw Zig
     SPIR-V leaves, e.g. the `return S317();` after a break/continue);
   - is the **general cleanup that makes the no-spirv-opt path robust** — the
     minimal slice of what spirv-opt's mem2reg + const-prop + dead-branch-elim
     used to do for us;
   - likely **clears several of the 13 fallback fixtures** (const-prop +
     reachability simplifies CFG-torture).

   **It must run on SPIR-V, not the IR** — `ir.zig` models only control flow
   (values are raw ids; data flow lives in the SPIR-V), so the constant
   relationships are invisible at the IR level. So SCCP is a SPIR-V analysis
   that runs before `ir_build`.

   **STATUS — analysis core DONE + unit-tested (`src/spv2wgsl/sccp.zig`,
   turn ~865).** Wegman–Zadeck iterative fixpoint over one function:
   value lattice {⊤, konst, ⊥} seeded from module constants; OpPhi meets over
   LIVE incoming edges only; folds IEqual/INotEqual/LogicalEqual/
   LogicalNotEqual/LogicalNot/Select; every other result is ⊥ (so a guard
   folds ONLY when provably constant). Outputs: reachable-block set, value
   lattice, and `foldedTarget(block)` for any constant BranchConditional/Switch.
   4 unit tests pass, incl. the minimized PBR shape (a single-exit-loop state
   phi resolving to its one exit constant → the post-loop guard folds, dead arm
   unreachable) and a soundness test (a varying guard does NOT fold). Reuses
   `block_table.registerBlocks` + the `inst_off` decode convention.

   **FOLD CONSUMER — SPIR-V rewrite (architecture A): DONE + unit-tested
   (turn ~865).** Reviewed `ir_build`: it is a recursive-descent structurizer
   (`StopStack`) with `by_id` / `cond_to_if` maps and multi-pass merge-phi
   attachment that ASSUMES every `OpBranchConditional` has a reconstructed
   `If`. Folding inside the builder (architecture B) would have to thread "this
   conditional is now a plain branch / these blocks are gone" through all that
   delicate phi logic — fragile. So `sccp.rewrite()` is a self-contained
   **SPIR-V→SPIR-V rewrite** that keeps the structurizer UNCHANGED (its
   invariants hold; it just sees cleaner input, exactly how spirv-opt layers
   before a translator) and is independently unit-testable. The analysis output
   (`reachable` + `folded`) is sufficient — edge-liveness for phi pruning is
   `reachable(pred) and (folded[pred] orelse block) == block` (no extra state).
   - skip unreachable blocks entirely (OpLabel … terminator);
   - for a folded block: drop its preceding `OpSelectionMerge` and replace the
     `OpBranchConditional`/`OpSwitch` with `OpBranch <foldedTarget>`;
   - rewrite each `OpPhi`: drop `(value, pred)` pairs on dead edges; recompute wc;
   - **loop headers are NEVER folded** (conservative — preserves loop structure
     for a later pass), so only selection guards fold.
   A 5th unit test proves it end-to-end on the PBR shape (SelectionMerge
   dropped, conditional → `OpBranch`, dead block removed, and a re-analysis of
   the rewritten module comes back clean). **16/16 sccp tests pass.**
   Reference for the fold mechanics: SPIRV-Tools
   `source/opt/dead_branch_elim_pass.cpp` (`MarkLiveBlocks →
   FixPhiNodesInLiveBlocks → EraseDeadBlocks`).
   **WIRED + PBR FAITHFUL FIX LANDED (turn ~865).** `sccp.rewrite` runs at the
   top of `convertSpirvToWgsl` (before the structurizer), guarded `catch spirv`
   so a rewrite error can never regress availability, plus a `spirv.len < 5`
   short-module guard. On the real PBR shader it folds the spurious guards:
   the regenerated WGSL has **0** `if (phiN == …)` guards and **0** dead
   `return S…()` tails (was the `if (phi867 == 482u)` + the 627/758 unreachable
   warnings), shrank 2176→2077 lines, and the occlusion/emissive sampling
   helpers are now called at uniform scope. One residual genuine non-uniform
   sample — the shadow map, called after a per-fragment frustum test in
   `computeShadow` (NOT a constant guard, so SCCP rightly leaves it) — was fixed
   in the SOURCE by sampling the shadow map BEFORE the frustum test (harmless;
   the value is discarded when the test fails), making it uniform too. With all
   sample call sites uniform, the **`textureSampleLevel` interim was REVERTED**
   → 6 faithful implicit-LOD `textureSample`, 0 SampleLevel in the PBR WGSL.
   VALIDATION: spv2wgsl 50/50 + sccp 16/16 unit tests pass; **all live shaders
   naga 34/34 valid (0 regressions vs the 20/0 baseline; count rose as more
   demos were rebuilt)**; 0 spurious guards pipeline-wide.
   REMAINING (confirmation, not implementation): (1) **Simon reloads
   `wgpu_pbr_demo.html` in Chrome** — the authoritative uniformity check, since
   naga is lenient on the rule (it validated the bug too); the structural
   evidence (all samples at uniform scope, guards folded) is strong but Tint is
   the final word. (2) Re-baseline the Tint corpus (`tests/fixtures/
   wgsl_corpus.json`) — SCCP may change a few fixtures' output; re-record after
   confirming the new output is naga-valid, and re-measure the 13-unstructured
   count (§3.B). (3) `wgpu-check` byte-diff.

2. **WGSL oracles — BUILT (turn ~865).** TWO are now on PATH (persisted via
   `/home/claude/zenv`):
   - **`naga`** (authoritative) — the Rust `naga-cli` (binary `naga`, v29.0.0)
     built from `/home/claude/refs/wgpu-trunk/naga-cli` (the gfx-rs/wgpu
     monorepo Simon uploaded) with the provided rust 1.96 toolchain. Debug
     build, compiled in ~62s. `naga shader.wgsl` → "Validation successful" / a
     diagnostic. This is the standing regression gate (§1.2, invariant #7).
   - **`nagac`** (fast secondary) — the pure-**Go** port `gogpu/naga`
     (`/home/claude/refs/naga-main`, NOT the Rust naga — Simon's first upload).
     Built with apt's Go 1.23 after relaxing its `go 1.25` go.mod directive (it
     has zero deps, so only the directive blocked it). Faster to invoke; "some
     features simplified" per its README.
   ⚠️ **KEY FINDING — naga and Tint DISAGREE on uniformity.** The Rust `naga`
   VALIDATES a `textureSample` inside non-uniform control flow (lenient by
   default — uniformity is a configurable diagnostic), whereas Tint (Chrome)
   REJECTS it — that is exactly the PBR bug. So: use `naga` as the authoritative
   gate for PARSE/TYPE/STRUCTURE regressions, but the PBR uniformity fix is
   proven STRUCTURALLY (guard folded → sample at uniform scope) + by Chrome/Tint
   (Simon), not by naga. Dawn/Tint (`/home/claude/refs/dawn-main`, large C++)
   stays in reserve as the only local tool that would enforce uniformity.
   **BASELINE (pre-SCCP, Rust naga): 20 live-shader WGSL valid / 0 invalid** —
   the regression reference. After wiring SCCP, re-run → must stay 20/0.

3. **§3.B — drive the 13 fallbacks to 0 (or formally declared-irreducible).**
   After SCCP, re-measure (several should fall out). For the rest: reconstruct
   the reducible ones (study Tint `parser.cc` for the shape), and put any
   genuinely-unstructured ones (Tint rejects those too) on a documented
   irreducible list with the reason. Endgame: the IR walker is the sole,
   complete path; the count gate becomes "0 trans-fail, N declared-irreducible".

4. **Latent CORRECTNESS fix: faithful pointer-out-param lowering.** The flagged
   trap (turn 856): a *called* pointer-out-param helper silently miscompiles
   (lowered to a by-value `_param` + local `var`; the caller's variable is
   never written back). Today's shaders are safe ONLY because dead-fn-elim
   drops the uncalled ones and spirv-opt used to inline the rest — but with
   spirv-opt gone, a real shader with a called out-param helper would SHIP
   WRONG, and naga cannot catch it (the WGSL is well-formed). FIX: lower a
   pointer param to `ptr<function, T>`, body load/store to `*p` / `*p = v`, and
   the call site (`emitFunctionCall`) to pass `&arg` for pointer-typed args.
   Gate it with a numeric-diff fixture (promote `/tmp/shtest/ptrshader.zig`).

5. **§2.3 — delete the vendored spirv-opt / spirv-cross.** The final payoff of
   the pure-Zig mandate. Blocked on the GL/`.glsl` path retiring (§7 /
   `finishing_new_gpu_foundations.md`) — spirv-cross only exists for that path,
   and spirv-opt only for it once SCCP lands. Remove `tools/spirv/` + prebuilts
   only when nothing on any built target invokes them. Not before.

6. **§4 finish PBR for real:** shadows ON (single-cascade depth pass +
   `light_space_matrix` + real `shadow_map`); then migrate
   `examples/damaged_helmet.zig` GL→wgpu (real GLTF base/MR/normal/AO/emissive
   textures — exercises the combined-sampler limit + real binding). After SCCP
   (#1) the PBR shader is faithful, so this is honest end-to-end PBR.

7. **§5 (`z.draw` ergonomics) and §7 (subsystem polish)** — after the pipeline
   is faithful and the C++ tools are gone.

DISCIPLINE: each of #1–#4 is a transpiler change verified the same way — naga +
a browser reload + host tests + the `wgpu-check` byte-diff. **SCCP (#1) is the
gate that converts today's interim into the real fix; do it first, carefully,
before anything that depends on a clean CFG.**

---

## §0.6 Completed work log (condensed; durable findings preserved)

**§2 — raw-SPIR-V support + spirv-opt removal (turns 848–863).** Zig's SPIR-V
backend emits multi-function, `OpUnreachable`-heavy, un-canonicalized SPIR-V
(4–73 `OpFunction`, up to 72 `OpFunctionCall`, 2–50 `OpUnreachable` per shader).
Porting spirv-opt was costed and REJECTED (~25k LOC of intertwined C++; the
general restructurizer isn't needed because Zig's CF is already structured +
reducible). Instead the IR reader was hardened directly:
- `OpUnreachable` handled as a real no-successor terminator (was the first bail).
- `attachExitArg` skips phi-predecessors that are structurally-unreachable
  blocks (dead blocks Zig names as phi preds; an opt pass would delete them).
- Pointer-typed params emitted by-value + a local `var` shadow — naga-valid for
  UNCALLED helpers. ⚠️ A CALLED out-param helper still miscompiles → forward
  plan #4 (the real fix).
- `computeReachableFunctions` (BFS the `OpFunctionCall` graph from the entry) →
  skip emitting unreachable functions. This is Tint-reader step-1 DCE; it
  removed all the struct-`OpBitcast` dead helpers (Zig 8-bit-pointer comptime
  machinery WGSL can't express) in one stroke.
- SPIR-V Input/Output globals emitted as module-scope `var<private>`; the entry
  wrapper copies `inputs.X → X` at entry and `X → outputs.X` at the return, so
  a bare-name I/O load/store resolves from ANY function. This also closed the
  last naga-debt fixture (§3.A).
- A `.unreach` tail in a value-returning function emits `return T();` (the
  zero-value) instead of falling off the end.
RESULT: **all 37 raw live shaders naga-valid**. **§2.2 landed** — `spv2wgsl` now
consumes the `zspv` output directly (`shader_codegen.zig` Stage 6: input switched
`opt_spv → rewritten_spv`, the `spirv-val` dep dropped), so the WGSL path is
pure-Zig; all wgpu standalones build with zero C++ tools. The one remaining gap
is the PBR uniformity bug — see the LATEST entry at the very top of §0
(spurious-guard diagnosis + interim + SCCP plan).

**§3.A — naga-debt → 0 (DONE, turn 855).** The last fixture
(`function_VertexShader_PositionUsed_Transitive`, an `Output` written in a
transitively-called helper) validates via the module-scope-`var<private>` I/O
emission above; `naga-invalid-baseline.txt` has zero non-comment lines.

**§3.C — legacy walker DELETED (turn 848).** `src/spv2wgsl/walker.zig` (1434
lines) removed; spv2wgsl is IR-walker-only; an unstructurable shape is a hard
`IrBuildUnsupported`, no fallback. `--walker=` / `-Dwalker=` are
accepted-but-ignored deprecation no-ops. The corpus test gates the (now 13)
unstructured fixtures as an expected, count-gated category. `tools/zglsl.zig`
was kept (it's the GLSL textual rewriter for the GL path; retires with §2.3/§7).

**§4 — 3D-on-wgpu ladder (turns 857–862).** Depth-tested cube → lambert → PBR
demos built (`wgpu_{cube,lambert,pbr}_demo`, each with a `-standalone`
single-file HTML step). Binding layouts read straight from the emitted
naga-valid WGSL (source of truth, not the IO schema). PBR wires 35 bindings
(group 0 = 5 VS mat4 uniforms; group 1 = 6 textures + 6 samplers; group 2 = 18
loose FS uniforms), built programmatically; first milestone = lighting on a
primitive (one checker texture for all maps, one directional light, point
lights + fog + shadows gated off). Remaining rungs are forward plan #6.

**Ubo migration + DamagedHelmet on wgpu (turn ~868).** PBR FS uniforms: 18 loose
group-2 bindings -> one Ubo block (the >12-per-stage limit was the blank-canvas
cause); the codegen Ubo binding was stage-segregated in `installSpirvEntry` (the
operative SPIR-V path), not just `setup()`. Helmet ported: runtime glb parse
(codecs, GL-free) + interleave + inline Lengyel tangents + 5 JPEG-decoded
textures (sRGB color / linear data, repeat wrap). Enablers: codecs re-exported
from zimr_wgpu (avoids a types.zig one-file-per-module clash), `zm` wired into
zimr_wgpu, `dom.js_log` added to the wgpu bridge. Chrome-confirmed; smoke +
naga + nagac green.

---

## §1. Two architectural mandates (these reframe the whole plan)

### §1.1 The pipeline is **Zig-only** — no spirv-opt, no spirv-cross in the shipping path

The whole thesis of `spv2wgsl` (and zimr) is *one Zig source → four
runtimes*, with a **pure-Zig** build path. The diagram:

```
zig shader source
    │  zig build-obj -target spirv*  (Zig's own SPIR-V backend)
    ▼
  SPIR-V
    │  spv2wgsl.zig   (pure Zig — the ONLY transform)
    ▼
  WGSL  ── embed──▶ ship this
```

**We cannot use `spirv-opt`** (SPIRV-Tools, C++) **as a build step**,
because it breaks the pure-Zig invariant — it would make the toolchain
depend on a prebuilt third-party binary that isn't Zig and isn't
portable to the comptime/wasm "universal Zig" story (§6.2: the same Zig
runs at comptime, in the browser VM, and on the GPU). The same applies
to `spirv-cross` (also C++): it may stay **only** as a build-time
convenience for the *dying* GLSL-output path that is scheduled for
deletion, never on the WGSL shipping path.

**Consequence — this is the important part.** Today `spirv-opt -O`
runs between the Zig SPIR-V output and `spv2wgsl` (see
`src/shader_codegen.zig` `spirv_opt_path`). spirv-opt was doing real work:
it *collapses degenerate control flow* (the empty/infinite loops, the
dead branches) that Zig's SPIR-V backend emits verbatim. Several Tint
fixtures only validated because spirv-opt cleaned them first. **Removing
spirv-opt means `spv2wgsl` must handle those raw shapes itself.** This
is exactly the fallback burn-down already underway (turns 813–815 added
degenerate-both-break headers, break-if-in-continuing, infinite-loop
headers, both-back-edge loops — all shapes spirv-opt used to erase).

So §1.1 and §3 are the same project viewed from two angles:
- §3 ("finish the transpiler") is the *work*.
- §1.1 ("drop spirv-opt") is the *acceptance test*: the pipeline is
  done when `spv2wgsl` consumes **raw, unoptimized** Zig SPIR-V and the
  live shaders + corpus stay naga-valid with no spirv-opt in the loop.

### §1.2 Finish naga compliance — even though it may not be strictly required

naga (Firefox's WGSL validator) is our oracle. **Decision: drive the
whole corpus to naga-clean, and keep it there as a standing gate** —
even though it is *not proven* that every naga rule is enforced by Dawn
(Chrome), which is the primary runtime. Rationale:

- naga and Dawn agree on the bug classes that actually bite us (types,
  binding arity/collisions, undefined identifiers, control-flow
  validity, varying/location rules). Every real-shader bug this arc
  found was a class both validators reject.
- naga is *stricter* in places. Passing the stricter validator is cheap
  insurance: a naga-clean shader is overwhelmingly likely to be
  Dawn-clean, and the converse failures are the ones worth catching
  early (they'd otherwise surface as a blank canvas on someone's phone).
- A green naga gate is a precise, automatable signal; "does it render in
  Chrome" is not. We treat **naga PASS = strong evidence to ship**,
  **naga FAIL = investigate**, and confirm genuinely surprising
  naga/Dawn disagreements with a browser screenshot.

This means: naga-debt baseline → 0 (not "0 except things we think Dawn
tolerates"), and the per-turn audit keeps it there. If a specific naga
rule is later proven irrelevant to Dawn *and* expensive to satisfy, that
is a deliberate, documented exception — not the default.

---

## §2. Drop the C++ SPIR-V tools from the shipping pipeline

Goal: the WGSL shipping path is `zig build-obj -target spirv* → spv2wgsl
→ .wgsl`, with **zero** invocation of spirv-opt / spirv-val / spirv-cross
on that path.

Current state (`src/shader_codegen.zig`): the per-shader pipeline is
`zspv (combined-sampler rewrite, pure Zig) → spirv-opt -O
--skip-validation → spv2wgsl → .wgsl` (plus a parallel `spirv-cross`
branch that emits `.glsl` for the GL renderer).

Steps:

- **§2.1 — Make spv2wgsl handle raw (un-opted) Zig SPIR-V.  [DONE — §0.6]**
  The corpus harness now scans pre-opt SPIR-V; the shapes spirv-opt was
  hiding were burned down by hardening the IR reader (OpUnreachable
  terminator, unreachable-phi-pred skip, by-value pointer params,
  reachable-function DCE, module-scope `var<private>` I/O). All 37 live
  shaders naga-valid from raw SPIR-V.
- **§2.2 — Remove `spirv-opt` from the WGSL path.  [DONE — §0.6]**
  `shader_codegen.zig` Stage 6 feeds `zspv` output straight to `spv2wgsl`
  (input switched `opt_spv → rewritten_spv`, the spirv-val dep dropped).
  Outcome: live shaders **naga 39/39** with no spirv-opt step; all wgpu
  standalones build with zero C++ tools. (`zspv` stays — it's pure Zig.)
  The one fallout was the PBR uniformity bug → interim landed, SCCP is the
  real fix (forward-plan #1).
- **§2.3 — Decide spirv-cross's fate.** It only exists for the `.glsl`
  output consumed by the GL renderer (`render.zig`). When the GL path is
  retired (§7 / `finishing_new_gpu_foundations`), spirv-cross leaves with
  it. Until then it is build-time-only and off the WGSL path — acceptable
  but flagged. Do NOT let any WGSL-path code grow a spirv-cross dependency.
- **§2.4 — Update invariant #6** (§6.9): "one SPIR-V → WGSL (spv2wgsl)"
  is the durable invariant; the "→ GLSL (spirv-cross)" half is transitional.
- **Note on spirv-val:** validation is a *debugging* aid, not a shipping
  step. It can stay in `scripts/` for hand-debugging but must not gate
  the build. naga is the shipping validator.

Why this matters beyond purity: it removes a ~tens-of-MB prebuilt
toolchain dependency, makes the pipeline reproducible from a Zig
toolchain alone, and is a prerequisite for the "universal Zig" story
(the transpiler itself already runs as wasm — `spv2wgsl.wasm`).

---

## §3. Finish the transpiler (the work behind §1 + §2)

### §3.A naga-debt → 0  [DONE — turn 855]
**DONE.** The last fixture (`function_VertexShader_PositionUsed_Transitive` —
the position `Output` written inside a transitively-called helper) now
validates via the module-scope-`var<private>` I/O emission (§0.6 / §2): the
entry wrapper copies inputs→private at entry and private→outputs at the return,
so a bare-name I/O store resolves from any function — no per-call threading
needed. `naga-invalid-baseline.txt` has zero non-comment lines; `zig build
naga-tint` enforces it stays empty.

### §3.B Fallbacks → 0 (or declared irreducible)
**13 fixtures** now hard-error as `unstructured` (the legacy walker is GONE,
§3.C — there is no fallback; they are an EXPECTED, count-gated category in the
corpus test). These are Tint's own SPIR-V-reader torture tests, NOT shapes a
real zimr shader produces. **Re-measure after SCCP (forward-plan #1)** — const-
prop + reachability should simplify several of these CFG-torture graphs and
drop the count on its own. The remaining clusters (by instrumented bail site;
re-measure each session since lines shift):
- **StopStack overflow (~7):** `branch_BranchConditional_Back_MultiBlock_*`,
  `phi_Phi_Propagated`, `MergeIsAlsoMultiBlockLoopHeader`,
  `phi_Phi_MultiBlockLoopIndex`. Runaway recursion on genuinely-tricky
  multi-block back-edge graphs. **Some of these may be irreducible** —
  even Tint rejects truly-unstructured CF. For each: either reconstruct
  it (study Tint's `parser.cc` for the shape) **or** formally classify it
  "legitimately unstructured — stays on legacy / can't happen in a real
  zimr shader" and record why.
- **Zero-operand / exotic branch guard (~5):** `HoistingMultiExit`,
  `phi_Phi_FromHeaderAndThen`, `phi_Phi_InLoopBody`,
  `phi_Phi_UnreachableLoopMerge`. Symptoms of exotic shapes; study individually.
- **Continuing/phi variants (~4):** `ValueFromLoopBodyAndContinuing`,
  `SimultaneousAssignment`, `phi_Phi_Loop_ContinueIsHeader`,
  `phi_Phi_Propagated_BreakIf`. The next-cleanest cluster; likely
  phi-ordering at the continuing block. **Best next target.**
- Method (proven this arc): instrument bail sites → dump SPIR-V +
  spirv-cross reference → study Tint → implement → `zig build naga-tint`
  green → `wgpu-check` no-drift → unit test → snapshot.
- Done: every fixture either IR-translates to naga-valid WGSL or is on a
  documented "irreducible" list. F5 (walker deletion) already happened
  (§3.C), so an irreducible shape is simply a hard error today; the goal is
  to shrink the count to a small, explained, intentional set.

### §3.C F5 — delete the legacy walker  [DONE — turn 848]
**DONE.** `src/spv2wgsl/walker.zig` (1434 lines) deleted; the spv2wgsl
module is now 9 files / 7880 lines (was 11 / 9419). What was removed:
- `walker.zig` entirely + its import in `spv2wgsl.zig` and `tests.zig`.
- `WalkerChoice` enum, the `walker_choice` `State` field, and the
  `.ir`/`.ir_or_legacy`/`.legacy` dispatch in `emitFunctionBody` — that
  function now calls `tryEmitViaIr` unconditionally (an unstructurable
  shape is a hard `IrBuildUnsupported`, no fallback).
- `convertSpirvToWgslWithWalker` collapsed into `convertSpirvToWgsl`
  (single public entry; `State.init` no longer takes a walker choice).
- The CLI `--walker=` flag is now an accepted-but-IGNORED deprecation
  no-op (so `scripts/naga-validate-tint.sh` and `shader_codegen.zig`'s
  `-Dwalker=` keep working unchanged); `TranslateOpts.walker` /
  `cmdCheck`'s walker param dropped.
- Corpus test (`spv2wgsl_corpus_test.zig`) switched from `.ir_or_legacy`
  to strict `convertSpirvToWgsl`; added `Status.unstructured` + the
  `unstructured_fixtures` allow-list (the 18 Tint torture shapes) +
  `baseline.tint_corpus_unstructured = 18`, so those hard-errors are an
  EXPECTED, COUNT-GATED category (a NEW trans-fail on a real shape still
  trips the test). Also restricted `scanZigCache` to `shader.opt.spv`
  only — the raw pre-opt `shader.spv` (multi-function, OpUnreachable-
  heavy Zig output) used to be swept up and translated ONLY via legacy;
  handling it is §2, not a regression.
- LEFT FOR A FOLLOW-UP (harmless dead code, not legacy-CFG): the
  `PhiAssignMap` precompute + the phi-assign block inside the shared
  `emitBlockBodyOnly` (still passed as the IR emitter's body callback,
  but `phi_assigns_ref` is always null on the IR path). Also `tools/
  zglsl.zig` was NOT deleted — it's the GLSL textual rewriter for the GL
  renderer path (`render.zig`), so it retires with the GL path (§2.3/§7),
  not with the WGSL walker.
- Gates (turn 848): wgpu-diff PASS (tint 0 trans-fail / 18 unstructured;
  internal 0 trans-fail) · naga-tint green (162 valid / 1 known / 18
  fallback) · live shaders naga 34/34 · host test 1808/1809 (the 1 =
  the known pre-existing `rlsw_shader.rasterizeTriangles` negative test)
  · 4 tier-a smoke PASS (identical gl-call counts) · wgpu_smoke PASS ·
  lint 0/272 (was /273; walker.zig gone) · cube3d + wgpu_cube_demo +
  wgpu_lambert_demo wasm BUILD OK.

ORIGINAL PLAN (for reference):
Precondition: §3.A done **and** §3.B done (every fallback handled or
declared irreducible) **and** §2.1 done (raw SPIR-V handled).
- Delete `src/spv2wgsl/walker.zig` (~1434 lines) + its sole-user support
  (`phi_assigns_ref`, `StopSet`, `route_phi_inline`,
  `isTrivialPassthroughBlock`).
- Remove `WalkerChoice`, the `-Dwalker` option, the legacy branch in the
  IR-or-legacy glue (71 references in `spv2wgsl.zig`). The IR path stands
  alone; an unsupported shape becomes a hard error surfaced by the naga
  gate.
- Delete the dying GLSL emitter `tools/zglsl.zig`.
- **If an irreducible list survives §3.B:** F5 still deletes most of the
  walker, but the build must reject (not silently miscompile) those
  shapes — a clean `@compileError`/diagnostic, not a fallback. Decide
  whether any real zimr shader can produce them; if not, the rejection is
  theoretical and F5 is unconditional.
- This is the single biggest simplification on the board (~1400+ lines).
- Gate: full corpus + 10 live shaders naga-clean; lint 0; snapshot.

### §3.D Optional Tier-2 simplifications (post-F5)
From `spv2wgsl_simplifications.md`: collapse `ir_emit.zig`'s `Enclosing`
3-field threading; make the hoist analysis a named struct; split
`spv2wgsl.zig` (3025 lines) along its seams once F5's churn settles. The
operand-shape table (Tier-1.2) is already done (turn 813). None are
urgent; do when touching the area.

---

## §4. 3D on wgpu — the ladder to the PBR standalone

**Investigation result (turn 815): the 3D path is a wiring job, not a
build-from-scratch.** Every primitive exists:
- Depth is fully plumbed: `pipeline_cache.StateCombo.fromParts` takes
  `depth: DepthMode`, `cull: CullMode`, `depth_format`; the descriptor
  encoder serializes them; the JS bridge (`src/web/zimr_wgpu.ts`)
  handles `depth24plus`/`depth32float` and emits a `depthStencilAttachment`
  with clear/store.
- Buffers + pipelines + vertex-buffer layouts are in use by `Renderer2D`.
- `unlit_vs_io` declares exactly a 3D vertex (`vertex_position: vec3 @0`,
  `vertex_tex_coord: vec2 @1`); `unlit_vs/fs` translate to valid WGSL.

The one structural fact: **`render.zig` (the existing 3D renderer) is
GL-only** (`@embedFile(".glsl")` + `rlgl`). There is no 3D-on-wgpu
renderer yet. So §4 builds a minimal 3D-on-wgpu draw path using the
existing primitives, paralleling how `Renderer2D` was built — it does
NOT port `render.zig`.

### §4.A The unlit depth-tested cube (the linchpin)
A new `wgpu_cube_demo` (fresh, self-contained — isolates the new 3D path
from the working 2D demo). Steps:
1. **Depth texture**: create a `depth24plus` texture at canvas size;
   thread its view into `beginRenderPass` via the existing `depth_view`.
2. **3D pipeline**: `StateCombo.fromParts(.triangle_list, .opaque,
   .back, .less, color_fmt, .depth24plus, 1)` + a `VertexBufferLayout`
   for `(vec3 position, vec2 uv)`, using the `unlit` VS+FS WGSL.
3. **Cube mesh**: 24 verts / 36 indices → vertex + index buffers (reuse
   `Renderer2D`'s `GenBuffer` pattern).
4. **MVP**: push a model-view-projection mat4 as the VS UBO each frame
   (the `unlit_vs_io.Ubo` typed path via `loadShader`).
5. **Draw**: depth-tested `drawIndexed` in the pass.
6. **Verify**: WGSL naga-valid; spinning textured cube renders in the
   browser (screenshot).
- Done: a depth-tested 3D mesh visibly renders in Chrome. This resolves
  the only remaining unknown ("does 3D-on-wgpu work end-to-end?").

### §4.B Lambert (one directional light) — incremental
Swap the `unlit` material for `lambert` (`lambert_vs/fs`, already valid
WGSL). Adds a normal attribute + a light-direction uniform. Same draw
path, depth, pipeline shape.

### §4.C PBR + the standalone (the answer to "when?")
Wire the `pbr_vs/fs` material (already naga-valid) as the Lit material on
the §4.A/B draw path: material UBO (col_diffuse, metallic, roughness,
emissive, ambient), the texture samplers (base/MR/normal/AO/emissive),
the light arrays, and single-cascade shadow sampling. Then a
`pbr_standalone` via the single-file bundler (§7.3).
- **Honest dependency chain for "when can I have the PBR example
  standalone":** §4.A (cube renders) → §4.B (lit mesh) → §4.C (PBR
  material + shadow + standalone). PBR is **step 3 of 3** on the runtime
  side. The *shader translation* for PBR is already done (naga-valid
  today); the gate is the runtime ladder above. Each rung is verifiable
  in a browser, so progress is unambiguous.

**§4.C STATUS — PBR-lit cube DEMO BUILT (turn 857).**  `examples/
wgpu_pbr_demo/` (+ `wgpu-pbr-demo` / `wgpu-pbr-standalone` build steps)
wires the engine `pbr_vs`/`pbr_fs` material on the cube/lambert
depth-tested draw path, by hand, paralleling wgpu_lambert_demo.  Binding
layout was read STRAIGHT FROM the emitted naga-valid WGSL (source of
truth, not the IO schema): group 0 = 5 mat4 VS uniforms (mat_model,
mat_view, mat_projection, mat_normal, light_space_matrix @0..4, each
array<vec4,4> 64B); group 1 = 6 textures @0..5 + 6 samplers @6..11;
group 2 = 18 LOOSE FS uniform bindings @0..17 (col_diffuse, view_pos,
ambient, metallic/roughness factors, emissive, dir/point light arrays
padded to vec4, fog, shadow gate).  35 bindings total, built
programmatically (loops in buildGroup0/1/2).  First milestone =
PBR LIGHTING works on a primitive: one white checker texture stands in
for all 6 maps, ONE directional light, point lights + fog + SHADOWS
GATED OFF (shadow_enabled=0).  VERIFIED (build-side contract — no GPU in
sandbox): compiles clean, embedded pbr_vs+pbr_fs WGSL both naga-VALID,
lint 0/273, wgpu-smoke PASS (73 init bridge calls, 60 frames no trap),
tier-a-check exit 0, no regressions.  Simon verifies the lit spinning
cube in the browser (`zig build wgpu-pbr-demo`).
NEXT §4.C rungs: (1) turn shadows ON (single-cascade: render depth pass
to a shadow map, fill light_space_matrix, bind real shadow_map texture,
shadow_enabled=1); (2) migrate `examples/damaged_helmet.zig` GL→wgpu
(the GLTF+PBR showcase — real base/MR/normal/AO/emissive textures via
drawMesh's sampler-binding loop, the Phase-4b work the pbr_fs_io schema
references); (3) `pbr_standalone` single-file HTML (already wired:
`wgpu-pbr-standalone`).  ⚠️ The damaged_helmet migration is where the
combined-sampler limitation + real texture binding will get exercised —
budget a debug pass.

**4.C UPDATE (turn ~868) -- DONE through the helmet.** The 18-loose-uniform
binding above was the bug (>12 uniform buffers per stage invalidated the
pipeline). It is now a single Ubo block at group 2 binding 0 (see the LATEST
entry in section 0). Rung (2) -- the damaged_helmet GL->wgpu migration -- is
COMPLETE: the real model + all 5 PBR maps render on wgpu (geometry, normal
mapping with generated tangents, emissive, AO). Rung (1) shadows remain OFF
(gated). This closes section 4; the work now moves to section 8 (port
everything, delete GL).

---

## §5. The optional raygpu-like ergonomics layer (`z.draw`)

**Motivation.** Studied raygpu (C99, raylib-style, WebGPU via Dawn/
emscripten). Its appeal is the *one-liner* surface:

```c
InitWindow(800, 600, "Title");
while (!WindowShouldClose()) {
    BeginDrawing();
      ClearBackground(GREEN);
      DrawRectangle(100, 100, 100, 100, WHITE);
      DrawText("hi", 200, 200, 30, BLACK);
    EndDrawing();
}
// pipelines:  DescribedPipeline* pl = LoadPipeline(src);
//             SetPipelineUniformBufferData(pl, &m, sizeof m);
// meshes:     DrawMesh(mesh, material, transform);
```

zimr **already has** the drawing verbs — `drawing.zig` exposes
`drawRectangle`, `drawCircle`, `drawTriangle`, … (raylib-parity). What
zimr does NOT yet have is raygpu's *frame ergonomics*: today a frame is
the explicit dance (see `wgpu_demo.zig`):

```zig
const fctx = Backend.beginFrame(f);
var ps = Backend.beginRenderPass(fctx.encoder, .{ .color_view = …, .clear = … });
ps.queue = f.queue; ps.batch = &renderer.shapes_batch;
renderer.bindForPass(&ps);
Backend.drawQuadBatched(&ps, …);
Backend.flushBatch(&ps);
Backend.endRenderPass(&ps);
Backend.endFrame(f);
```

That explicitness is **correct and stays** (invariant §6.9 #4: PassState
is plumbed, never global). The optional layer wraps it for the common
case — **almost as easy as raygpu, just without globals and slightly
more explicit**:

### §5.1 Design
- **A `Frame`/`Draw` context object, never a global.** raygpu hides the
  device/pass/batch in file-scope statics; we put them in a context the
  user threads. The ergonomic win is the *grouping*, not hidden state.

  ```zig
  // The optional layer — one object, explicit, no globals:
  var d = try z.draw.begin(&gpu, .{ .clear = z.color.rgb(20, 50, 50) });
  defer d.end();              // flush + endRenderPass + endFrame, ordered
  d.rectangle(100, 100, 100, 100, z.color.white);
  d.circle(d.mouseX(), d.mouseY(), 40, z.color.white);
  d.text("hi", 200, 200, 30, z.color.black);
  ```
  `begin` does beginFrame + beginRenderPass + bindForPass + sets
  queue/batch; `end` does flushBatch + endRenderPass + endFrame in the
  correct order (the ordering footgun the explicit path documents). The
  `d.*` verbs forward to the existing `drawing.zig` functions against
  `d`'s PassState. **No global PassState** — `d` IS the PassState holder,
  passed explicitly.
- **Pipelines, raygpu-style but typed.** raygpu's `LoadPipeline(src)` +
  `SetPipelineUniformBufferData(pl, &x, n)` becomes our existing typed
  `loadShader(Schema, …)` + `shader.pushUbo(queue, value)` — already this
  ergonomic, already type-checked. The layer just re-exports them under
  `z.draw` with raygpu-ish names (`z.draw.pipeline(...)`,
  `pl.setUniform(value)`), so a raygpu user feels at home but the schema
  still catches binding mismatches at compile time.
- **3D, raygpu-style.** Once §4 lands: `d.mesh(mesh, material, transform)`
  mirrors raygpu's `DrawMesh` — wrapping the §4 draw path. `z.draw.camera3D`
  / `beginMode3D` set the view-projection UBO. A `z.shapes.cube()` /
  `.sphere()` mesh factory mirrors raygpu's mesh gens.

### §5.2 Rules (what keeps it "zimr", not raygpu)
1. **No globals, ever.** The context is an explicit value. This is the
   one hard line vs raygpu. (Multiple windows / headless fall out for
   free, like raygpu — because state is per-context.)
2. **The explicit API stays first-class.** `z.draw` is a *thin optional*
   wrapper over `gpu_iface.zig` + `drawing.zig` + `loadShader`. Anyone
   can drop to the explicit path mid-frame (the layer exposes `d.pass`).
   No capability is *only* reachable through the sugar.
3. **Typed shaders only.** No raw-WGSL `LoadPipeline(string)` escape
   (invariant: no hand-written WGSL). `z.draw.pipeline` takes a Schema +
   the build-emitted `.wgsl`, same contract as `loadShader`.
4. **Minimal + explicit prose/code** (Simon's house style): the layer is
   a small file (`src/draw.zig`?), verbs forward to existing code, no new
   subsystem. If it grows a renderer of its own, it's gone too far.

### §5.3 Sequencing
Build `z.draw` **after** §4.A (so the 2D *and* 3D verbs both exist to
wrap) but the 2D-only slice can land earlier if useful. Done-condition: a
`hello_draw` example that opens a window and draws shapes + text in
< ~15 lines, no globals, and a one-screen 3D variant after §4.

---

## §6. System map (durable; updated for the mandates above)

### §6.1 Shader compilation pipeline (build time) — TARGET (post-§2)

```
.zig source (e.g. examples/mandelbrot_fs.zig)
    │  zig build-obj -target spirv*  (Zig's SPIR-V backend; .spirv_fragment/.spirv_vertex)
    ▼
.spv  (raw SPIR-V; SPIR-V 1.5+, Logical addressing)
    │  tools/zspv  (pure Zig — combined-sampler → separate texture+sampler per WGSL ABI)
    ▼
.rewritten.spv
    │  spv2wgsl  (src/spv2wgsl.zig + src/spv2wgsl/*; pure Zig; structured-IR walker:
    │             ir_build.zig reconstructs the CFG, ir_emit.zig lowers it)
    ▼
.wgsl  ← @embedFile'd into wasm at build time   ←── SHIP THIS
```

**Differences from the pre-§2 pipeline:** no `spirv-opt` step (§1.1,
§2.2); no `spirv-cross` on this path (it remains only for the dying
`.glsl`/GL path, §2.3). `spirv-val` is a hand-debug aid in `scripts/`,
not a build gate (§2).

**Critical invariant:** the wasm contains zero transpilation code. Every
WGSL byte is baked in at build time; runtime "shader compilation" is just
`device.createShaderModule({code: <embedded string>})`.

### §6.2 The "universal Zig" frame (from the diagram)
One Zig source serves four execution contexts: **comptime** (in the
compiler), **JS** (bridge, browser VM — `c2js.zig` path), **wasm**
(browser VM — the app), **WGSL** (GPU — `spirv2wgsl.zig` path). The
pure-Zig mandate (§1.1) exists so the *toolchain* matches this story: no
context should require a non-Zig binary. `spv2wgsl` already compiles to
`spv2wgsl.wasm`, so the transpiler itself runs in the universal-Zig set.

### §6.3–§6.8 (runtime arch, standalone, diagnostics, tests, examples, smoke)
Unchanged from the prior plan; see `archive/finishing_webgpu_pre-t815.md`
§5.2–§5.8 for the verbatim detail. Key live facts: JS bridge
(`src/web/zimr_wgpu.ts`) implements all 37 `js_*` WebGPU functions;
`Renderer2D` ships the typed `default_shapes` shader; standalone via the
in-build step `zig build wgpu-standalone` / `wgpu-cube-standalone` (inlines
JS, base64s wasm; the `WgpuStandalone` step + `WGPU_STANDALONE_TEMPLATE`
constant in build.zig — turn 816, replaced the Python script).

### §6.9 System invariants (must hold across all changes)
1. **Pure Zig destination AND pure-Zig build path.** No npm/Bun/
   emscripten in the artifact; **and no spirv-opt/spirv-cross on the WGSL
   shipping path** (§1.1). Bun is fine for build-time bundling of
   `zimr_wgpu.ts`→`.js`; it never ships.
2. **Static everything.** No dynamic shader compilation in the shipped
   wasm; all WGSL `@embedFile`'d at build time.
3. **One trait, both backends.** `Backend` in `gpu_iface.zig`:
   `WgpuBackend` (browser/native) and `SwBackend` (CPU smoke). No
   per-example traits.
4. **`PassState` is plumbed explicitly — no globals.** Even the optional
   `z.draw` layer (§5) holds PassState in an explicit context, never
   file-scope. This is the hard line vs raygpu.
5. **Bind groups are typed.** `loadShader(Schema, …)` turns marker
   decorations into a comptime bind-group layout; shader/binding
   mismatches are Zig compile errors, not runtime WebGPU validation
   errors. No raw-WGSL escape hatch.
6. **One SPIR-V → one WGSL, via spv2wgsl (pure Zig).** Same SPIR-V →
   byte-identical WGSL between builds (the `wgpu-check` snapshot enforces
   this). The transitional `→ GLSL (spirv-cross)` half leaves with the GL
   path (§2.3).
7. **naga-clean is the standing bar** (§1.2). naga-debt baseline → 0 and
   kept there; naga PASS = ship, FAIL = investigate.

---

## §7. Broader subsystem polish (after the above)
1. More examples on wgpu (in difficulty order): cube3d → imgui_demo →
   damaged_helmet (GLTF+PBR) → a compute demo (bridge has compute imports;
   nothing uses them).
2. The "missing blue quad" first-draw bug (engine vertex-buffer-offset /
   first-draw-state; not spv2wgsl).
3. Standalone refinements: generic `--example NAME` bundler; ReleaseSmall
   to get bundles <1MB; debug toggles via URL fragment.
4. Bridge optimization: ~26 calls/frame (setBindGroup + setVertexBuffer);
   collapse via a bound-state cache.
5. WASI shim audit: drop unused `wasi_snapshot_preview1` imports.
6. Per-group auto-binding counter (currently global across `@group`s —
   valid but non-minimal; turn 815 deferred this).
7. Retire the GL path (`render.zig`, `.glsl` embeds, spirv-cross) — see
   `finishing_new_gpu_foundations.md`; this is what lets §2.3 finish.
8. Docs: CHEATSHEET wgpu recipe + "new wgpu example" guide; mark progress
   in `finishing_new_gpu_foundations.md`.
9. Native (Dawn) port — future; sketch preserved in the archived plan §5.8.


## §8. The all-examples wgpu port + GL deletion  [SUPERSEDED — turn 1094]

> **SUPERSEDED by `PORT_PLAN.md` §1.5** — the authoritative full-parity + GL-kill plan
> (per-subsystem designs S-A…S-F, the live build order, the NEXT step). This §8 is the
> earlier (turn ~868) sketch of the same north star; kept for its inventory + guardrails
> only. Do NOT plan from here — read `PORT_PLAN.md` §1.5 (`claude.md` points there too).

The shader pipeline and the 3D/PBR runtime are proven -- the DamagedHelmet
renders on wgpu with full PBR (section 4 closed). What remains is breadth, not
depth: move every example onto the wgpu backend, then delete the WebGL/GL path
wholesale. This section is the road.

### §8.0 End state
- ONE rendering backend: wgpu (browser via Tint; native via Dawn later). The
  `SwBackend` CPU path stays (smoke + rlsw). No GL.
- Deleted: `rlgl.zig` (~5.1k), `gpu.zig` (~2.7k, the GL gpu fwd), the GL shader
  runtime (`shader_runtime.zig`, ~380), the GL halves of `drawing.zig` (~18.6k;
  the bulk is GL draw / model / material / texture upload) and `web.zig` (~2.2k;
  the `webgl` externs + GL dom glue), the `.glsl` embeds + spirv-cross + the
  vendored C++ SPIR-V tools under `tools/spirv/`, and `tools/zglsl.zig`.
- The `zimr` module collapses into `zimr_wgpu` (or `zimr_wgpu` is renamed to
  `zimr` once it is the only one). codecs / types / zm / math survive as the
  shared, backend-agnostic core -- the helmet already proves codecs works under
  wgpu.

### §8.1 Inventory (turn ~868)
- ~150 example `.zig` files import `zimr` (the GL path); only 4 import
  `zimr_wgpu`: wgpu_demo (2D), wgpu_cube_demo, wgpu_lambert_demo, wgpu_pbr_demo
  (now the helmet). The remaining `examples/*_fs.zig` / `*_io.zig` / `*_vs.zig`
  / `*_bundle.zig` / `comptime_*` / `sw_*` files are shader-pipeline scaffolds
  or the software path, not GL examples.
- GL core to retire: ~29k lines across the 5 files above.

### §8.2 Capability gaps to close BEFORE bulk porting
Porting is gated on the wgpu path reaching feature parity for what the examples
use. Rough dependency order:
1. **2D parity (the biggest unlock).** Most examples are 2D/UI. `Renderer2D`
   already ships the typed `default_shapes` shader; audit + fill: filled/lined
   shapes, circles / ellipses / polylines / bezier, textured quads + sub-rects,
   text (font-atlas upload + glyph quads), blend modes, scissor/clip, camera2D.
   This is the section 5 `z.draw` ergonomics layer doing real work.
2. **imgui on wgpu.** The `ui_*` + `imgui_*` examples (~60 files -- the single
   largest bucket) need Dear ImGui draw lists rendered through wgpu (a vertex/
   index buffer per frame, the font-atlas texture, scissor rects). One focused
   subsystem that unlocks ~40% of the examples at once.
3. **3D ergonomics.** The raw path works (helmet). Wrap it: a Model/Mesh upload
   helper (the interleave + tangent-gen from the helmet demo, generalized), a
   Material with the 5 maps, a camera, a draw call. Then cube3d, models3d,
   gltf_*, instancing, skybox, wireframe, first_person_camera, billboards port
   quickly.
4. **Fullscreen-shader helper.** mandelbrot / julia / mandel_julia /
   kaleidoscope / raytracer / shader_* are a fullscreen triangle + an FS with a
   small uniform block -- one tiny helper covers them all.
5. **RTT / MRT.** rtt, mrt_demo, texture_readback, text_on_texture need render-
   to-texture (`WgpuRenderTexture` exists -- wire it through the 2D/3D paths).
6. **Skinned mesh + instancing.** skinned_mesh (bone-palette uniform/SSBO + the
   skinning VS), instancing (per-instance buffer) -- after 3D ergonomics.
7. **Already backend-agnostic (no gap):** input / gestures, audio, codecs /
   image decode, math, ECS, easings -- logic, not GL. They ride along once their
   *rendering* (2D) is ported.

### §8.3 Porting order (highest value / lowest risk first)
1. 3D showcase: cube3d, models3d, gltf_simple, gltf_textured, skybox,
   instancing, wireframe (pipeline proven; exercises 8.2.3).
2. Fullscreen shaders: mandelbrot, julia, mandel_julia, kaleidoscope (8.2.4).
3. 2D primitives + image: shapes_showcase, lines_*, easings_*, colors_palette,
   load_image_demo, png_demo (drives 8.2.1 to completion).
4. The UI/imgui bucket: ui_* + imgui_* (gated on 8.2.2 -- build that subsystem
   first, then these fall in batches).
5. Physics / sim / ECS: ball_physics, double_pendulum, particles, life, ecs_*,
   sph_fluid_2d (2D + logic).
6. Audio + misc: audio_*, music_*, composer_drum (audio is GL-independent).
Each port: switch imports zimr -> zimr_wgpu, swap the draw calls, add a build
target (or fold into a generic `--example NAME` wgpu bundler, see 8.5), and
verify with `wgpu-smoke` + a Chrome reload before moving on.

### §8.4 Deletion sequence (only once nothing imports GL)
1. Port (or explicitly retire) every GL example; remove their GL build wiring.
2. Extract any remaining backend-agnostic helpers still trapped in drawing.zig
   into their own modules (codecs is already out; do the same for any model /
   mesh math the wgpu path reuses) so the GL monolith has no live dependents.
3. Delete `rlgl.zig`, `gpu.zig` (GL fwd), `shader_runtime.zig`, the GL halves of
   `drawing.zig` and `web.zig`.
4. Drop the `.glsl` embeds, the spirv-cross path, `tools/zglsl.zig`, and the
   vendored C++ SPIR-V tools under `tools/spirv/` -- they were build-time-only,
   confined to the GL/.glsl path (this is the long-promised 2.3 / section 7.7).
5. Collapse the module graph: `zimr_wgpu` becomes the one public module.
6. Update CHEATSHEET + the "new example" guide to the wgpu-only world.

### §8.5 Guardrails (do not regress)
- Keep codecs / types / zm / math PURE and shared -- the helmet relies on codecs
  under wgpu; do not let GL deletion drag them down. The one-file-per-module trap
  that forced the codecs re-export is the warning shot: a file belongs to ONE
  module.
- Never break the 4 working wgpu demos. The single-Ubo PBR pipeline + the
  368-byte `FsUbo` host-mirror layout are load-bearing (a host<->shader std140
  mismatch is silent -- Simon's deferred ask is a compile/lint check for it).
- Every ported example verified by `wgpu-smoke` (no-GPU trap check) AND a real
  Chrome reload (Tint is the only uniformity authority; naga / nagac do NOT
  enforce it).
- Land it in reviewable batches (a category at a time), snapshotting between.

### §8.6 Recommended next step
Pick ONE: either (a) the 3D ergonomics wrapper (8.2.3) + port cube3d / models3d /
gltf_* -- fast wins on the proven path, keeps momentum; or (b) the imgui-on-wgpu
subsystem (8.2.2), the single highest-leverage unlock (~60 examples). (a) is
lower risk; (b) is the bigger prize. Independently, fold the helmet off the
`wgpu-pbr` target into its own `wgpu-helmet` target and drop the now-unused cube
arrays from the demo file.

**Progress (8.3 item 1 underway).** The 3D-ergonomics wrapper from option (a)
shipped as `src/pbr3d.zig` (re-exported `z.pbr3d`): pipeline + 3 bind-group
layouts + glTF Model loader (material-resolved 5 maps, tangent-gen) + camera +
draw loop. The helmet demo was rebuilt on it (686 -> ~100 lines) as the
regression proof. First *new* port: **wgpu_gltf_textured** (the wgpu port of GL
`gltf_textured`) -- a PNG-textured, normal-less quad glb, proving pbr3d
generalizes past the helmet. Build `wgpu-gltf-textured`(+`-standalone`); smoke
PASS; Chrome pending.

Two robustness fixes the helmet never forced, found by this port:
1. `loadGltf` now handles **absent vertex attributes** -- a glb with no NORMAL
   (this quad) made the old interleave null-deref `mesh.normals`. Now: absent
   UVs -> (0,0); absent normals -> flat per-face normals synthesized from the
   triangle winding (`synthesizeFlatNormals`).
2. `resolveTexture` -> `resolveMap`: the sRGB-vs-linear format and the
   white/flat-normal fallback are now derived from the `MaterialSlot` enum, not
   passed per call -- five 130-col call sites collapsed to one-liners.
3. **Cull mode is per-model, not renderer-wide.** The quad rendered blank at
   120fps (loop fine, nothing drawn): a single-sided flat plane in z=0, and the
   JS bridge never set `frontFace` (WebGPU defaults ccw), so the camera saw its
   back face and `.back` culling dropped it. The helmet (a closed solid) hid
   this. Fix: `cull_mode` is now an `InitOptions` field (default `.back`; the
   quad passes `.none`). A flat/card/billboard model must opt out of culling.
4. **Metallic-roughness fallback must be matte dielectric, not white.** The
   quad still rendered (near-)black after the cull fix. Traced through pbr_fs:
   the MR slot's *white* fallback reads B=1 -> metallic=1.0, and the BRDF's
   `kD = (1 - kS) * (1 - metallic)` zeroes the entire diffuse term, leaving only
   a faint specular highlight on an untextured surface. glTF packs metallic in
   B, roughness in G, so the correct neutral is (R=255,G=255,B=0): metallic 0,
   roughness 1. Added `default_mr_texture`; the helmet (real MR map) is
   unaffected. CPU-side load/transform/tangent/texture were ALL verified correct
   via host probes -- this was purely the lighting fallback. Chrome reverify
   pending.
5. **The depth attachment size MUST equal the surface size, or WebGPU drops
   the whole render pass.** The textured quad rendered blank for several turns:
   pipeline valid, draw issued, data correct, no init error -- but the quad
   demo's depth texture was 800x450 while the standalone surface is 800x600.
   WebGPU rejected every BeginRenderPass for the mismatch. Found via NEW on-page
   logging (below). Hand-fixed by matching the demo canvas to the surface;
   STRUCTURAL fix is N1 in wgpu_new_beginnings.md (GpuFrame owns + auto-resizes
   the depth texture, like raygpu backend_wgpu.c:830). Chrome-confirmed: the
   red/cyan checker quad renders.

**On-page logging infra (turn ~875, keep + reuse).** The wgpu standalone
(buildaux) now mirrors console.log/warn/error into an always-visible on-page
debug pane AND wraps _initialize + the first frame in WebGPU validation error
scopes whose results print on-page (`[GPU] init scope: ...` / `frame scope:
...`). `pbr3d` reports its decisions via `dom.js_log` (verts/indices/maps/draw).
This is the WebGL-bridge-style "wasm talks to the page" channel; it turned a
multi-turn blind guessing loop into a one-screenshot diagnosis (the depth-size
error printed verbatim). The device global the scopes use is `__zimrDevice`
(the bridge sets it); an older buildaux patch looked for `__zimr_wgpu_device`
via a marker that no longer matched -- now we read `__zimrDevice` directly.

**STOP: do not port more wgpu examples here.** This whole section (the all-
examples port + GL deletion) is now GATED behind `wgpu_new_beginnings.md`, which
restores zimr's ergonomic surface (AppBridge / Frame / coordinate+resize rules /
the rlsw||wgpu side-by-side architecture) on WebGPU first. Resume this section
only when that plan closes (its N7d flips this back to ACTIVE). Simon, turn ~875.

System idea parked (do NOT build yet, needs 2-3 ports of evidence): the GL
examples use the `z.AppBridge` run-loop (initState/update callbacks, a `Frame`
carrying time+input), while every wgpu demo hand-rolls `main()`+`update()` with
manual frame_count timing and ~40 lines of device/surface/cache boilerplate. If
that boilerplate recurs across the next ports, a `z.wgpu` App/Frame harness
(mirroring AppBridge) is the highest-value ergonomics win -- it would make each
subsequent port a ~30-line file. Watch for it; don't over-fit to one example.

