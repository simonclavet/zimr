# STRUCTURE PLAN — flatten, merge, DAG-ify, rename (post-GL-retirement)

Status: **EXECUTED** (t1177, all stages green: 1684/1684 host tests,
tier-a 11×PASS incl. the new dag-check gate, lint 0/258, standalones
rebuilt).  Two documented deviations from the proposal:
(1) kompute.zig + compute_host.zig DEFERRED from S2 — kompute is a
    named-module root (kernel files `@import("kompute")`), the same
    exemption class as shader_interface; folding it means re-rooting a
    module.  Queued as its own compute-consolidation item.
(2) S4's facade allowance is STRUCTURAL (a dup is permitted iff exactly
    one side is wgpu_app.zig, the z-API facade) rather than a 30-name
    allowlist — the wgpu_app↔shapes2d/draw3d raylib surface is one
    pattern, so it gets one rule. Data below is measured
from the live tree (comment-stripped import graph, fn-name audit, line counts).

Goal (Simon): flattest, simplest structure. Giant files. A real DAG. No deep
namespacing. No reuse of file-level function names except where the contract
demands it. Shader/comptime-safe code legible at a glance.

---

## S0 — DAG repair (we are NOT a DAG today: 3 cycles)

Measured cycles (comment-stripped):

1. **image.zig ↔ text2d.zig** — image's text-drawing fns import text2d
   (FontCache/glyphs); text2d imports image (atlas ops). FIX: move the
   image→text2d users (`imageDrawText` family, ~4 fns) INTO text2d.zig —
   text-on-image belongs with the font machinery. image becomes text-free;
   text2d→image remains (a forward edge). 
2. **renderer_trait.zig ↔ wgpu_draw.zig** — created in P5 when the trait test
   instantiated WgpuGl. FIX: move that one test into wgpu_draw.zig (the impl
   asserts its own conformance — better locality anyway).
3. **gpu_iface ↔ renderer_2d ↔ shader_runtime_wgpu (3-cycle)** — gpu_iface
   (supposedly the LOW backend handle) contains two `flushBatch` bodies that
   reach into renderer internals (`Vertex2D` sizing) and holds a
   `SwPipelineDispatch` pointer typed from shader_runtime_wgpu. FIX:
   (a) move the flushBatch bodies into renderer_2d (free fns taking
   *PassState); (b) move the `SwPipelineDispatch` TYPE into gpu_iface
   (shader_runtime_wgpu already imports gpu_iface — it re-exports the alias).
   gpu_iface then imports nothing upward → a true leaf.

Hygiene: runtime.zig has 14 intra-file `@import("runtime.zig")` self-refs
(cross-namespace idiom) → replace with direct sibling references.

**Enforcement:** wire `scripts/check_dag.py` as `zig build dag-check`, make it
a tier-a member. A cycle becomes a build failure forever.

## S1 — spv2wgsl becomes ONE file (Simon's explicit ask)

Today: src/spv2wgsl.zig (3,280l) + src/spv2wgsl/{ir_build 2393, sccp 1280,
wgsl_check 609, block_table 612, ir_emit 585, ir 486, types 332, selection 30,
loop 25, switch 22} = **10,336 lines across 10 files** — every subdir file is
spv2wgsl-parented (or test-listed). FOLD ALL into src/spv2wgsl.zig with
section banners; delete src/spv2wgsl/. tests.zig collapses six lines to one
refAllDecls. Expected friction: internal name collisions across the folded
files (each had its own `types`/aliases) — resolved by section-local renames.
The known recursive-emitter stack issue is untouched (separate P6 item).

## S2 — merges (the giant-file pass)

Single-REAL-parent (excluding the refAllDecls aggregator) and where each goes:

| file | lines | real parent | → destination |
|---|---|---|---|
| pbr3d.zig | 1,046 | zimr_wgpu | **draw3d.zig** (3D consolidates) |
| draw_points.zig | 166 | zimr_wgpu | **draw3d.zig** |
| compute_pass.zig | ~300 | wgpu users | **wgpu.zig** (bridge encoding lives with the bridge) |
| render_pass.zig | ~300 | wgpu users | **wgpu.zig** (kills the begin/end/setPipeline fn-name dups) |
| storage_buffer.zig | 166 | zimr_wgpu | **wgpu.zig** (buffer helpers with the handle layer) |
| uniform_buffer.zig | 178 | zimr_wgpu | **wgpu.zig** |
| compute_host.zig | 295 | zimr_wgpu | **wgpu.zig** (one compute story: pass + host wrapper) |
| kompute.zig | 93 | NOBODY (orphan) | fold useful bits into wgpu.zig compute section, else delete |
| shader_compile.zig | 270 | zimr_wgpu | **shader_runtime_wgpu.zig** |
| shaders/default_shapes_bundle.zig | 10 | sw_runtime_bundle | inline into sw_runtime_bundle |

wgpu.zig becomes the GPU mega-file (~3.5–4k: handles + bridge + passes +
buffers + compute). draw3d ~5.3k. zimr_wgpu stays a pure re-export umbrella.

**Deliberately KEPT standalone despite single-parenting** (domain libraries —
cohesion over the rule; veto any of these and they merge too): physics
(4,076l), entities, easings, codecs, sound, rlsw/rlsw_shader/rlsw_pixel/
rlsw_adapter, ui, image, text2d, shapes2d, draw3d, runtime, types, errors.

**Cannot merge, with reason:** all `*_fs.zig`/`*_vs.zig` (separately-compiled
SPIR-V pipeline ROOTS) and all `*_io.zig` (the shader↔host contract — imported
by BOTH the shader root via `--dep io` AND host code; merging either direction
breaks one side). shader_codegen.zig's real parent is the BUILD (it's the codegen
exe) — rename in S3, not merge.

## S3 — renames

| from | to | why |
|---|---|---|
| src/renderer_trait.zig | **renderer_trait.zig** | "gl" is a GL-era ghost; it's the `gl: anytype` renderer contract |
| src/shader_codegen.zig | **shader_codegen.zig** | it's the per-shader externs/bootstrap codegen exe, name says nothing |
| src/sw_runtime.zig | **sw_runtime.zig** | match the module name it's wired as |
| src/wgpu_draw.zig | *(option)* **wgpu_draw.zig** | the WgpuGl TYPE name stays (churn); file name only — say yes/no |
| examples/quad_glb_data.zig | **quad_glb_data.zig** | it's embedded data, not an example |

Not renaming: zimrmath (established), wgpu_app (it IS the app layer),
shader_interface (S5 makes it the tier anchor).

## S4 — function-name uniqueness

Audit found **51 file-level `pub fn` names defined in 2+ files**. Policy:
unique across src EXCEPT contract names. Allowlist: `shaderMain` (every
shader's pipeline entry, ×9), `main` (wasm roots), `init/deinit` on file-level
*(judgment — currently fine as type methods; file-level free `init` would be
banned)*.

Fixes:
- render/compute pass dups (begin/end/setPipeline/setBindGroup) → die in S2.
- wgpu_app's forwarder redefinitions (`getSphereBoundingBox` etc. vs draw3d;
  `drawRectangle/drawCircle` vs shapes2d) → become `pub const x = draw3d.x;`
  ALIASES (re-export ≠ redefinition).
- image.zig vs wgpu_app (`drawTexture`, `drawTextureRec`, `colorFromHSV`):
  image's are CPU draw-INTO-image ops → rename to the raylib `imageDraw*` /
  `imageColorFromHSV` convention. GPU names stay on wgpu_app.
- `floatToHalf`/`halfToFloat`: rlsw_pixel deletes its copies, uses zimrmath's.
- `Handle` (entities vs rlsw): different domains, both type-constructors —
  proposed allowlist entry (veto → rename rlsw's to `SwHandle`).

**Enforcement:** new lint rule `dup-pub-fn` — duplicate file-level pub fn
names across src = error, allowlist in the linter.

## S5 — the SHADER-SAFE tier (Simon's "which files can shaders include")

Measured: shader sources today import exactly `zm` (zimrmath), their
`*_io.zig` (+ `*_common_io.zig` → shader_interface), and the generated
externs. So the tier already exists implicitly: **zimrmath, shader_interface,
the io files**. Make it explicit:

1. Marker contract: first line `//! SHADER-SAFE` on zimrmath.zig and
   shader_interface.zig; `*_io.zig` are implied by suffix.
2. Lint: extend the shader-DSL scan (today only `_fs/_vs`) to every marked
   file — no allocators, no std runtime calls, no extern beyond the DSL set,
   comptime-evaluable bodies. The marker becomes a checked promise.
3. files.md generator prints the tier (`[shader-safe]` tag in each entry).
4. Rule of thumb going forward: new shader-includable helpers go INTO
   zimrmath, or into a new file that carries the marker.

## S6 — execution order + gates

S0 (DAG, ~1 turn) → S1 (transpiler fold, ~1 turn) → S2+S3 together (merges +
renames share the import-rewrite churn, 1–2 turns) → S4 (dedupe + lint rule)
→ S5 (tier + lint). Every stage: full test (direct binary), tier-a, lint,
helmet+ui_demo standalones, atlas regen, per-turn zip.

## Open questions for Simon

1. Physics & friends staying standalone — agree, or fold physics into
   zimr_wgpu/draw3d too?
2. wgpu_draw.zig file rename (type keeps `WgpuGl`) — yes/no?
3. `Handle` name shared by entities + rlsw — allowlist or rename rlsw's?
4. wgsl-primary engine_shaders collapse (kills the .glsl gravestone) — fold
   into S2 or keep as its own later item?
