# spv2wgsl audit & improvement plan (working doc)

Goal: make zimr's `src/spv2wgsl.zig` (10.5k LOC hand-written SPIR-V→WGSL translator)
produce WGSL that ALWAYS passes naga/Tint validation, taking inspiration from
SPIRV-Tools / naga / Tint(Dawn). Deliverable: a tutorial comparing what we do vs
what they do, plus concrete transpiler fixes.

## Tooling set up (turn 1) — WORKS
- Rust 1.96.1 installed at `/home/claude/study/rust` (PATH + LD_LIBRARY_PATH=.../rust/lib).
- **naga-cli built**: `/home/claude/study/wgpu-trunk/target/debug/naga` (v30.0.0).
  - `naga foo.wgsl` → validates WGSL (our primary automated validator). "Validation successful" / detailed diagnostics on failure.
  - `naga in.spv out.wgsl` → naga's OWN spv→wgsl (ground truth) — BUT naga's spv frontend
    rejects our `.rewritten.spv`: "Unknown capability Linkage", "invalid operand count 6 for Load".
    So naga-as-converter isn't drop-in on our post-zspv_rewrite spv. TODO: try the PRE-rewrite
    `shader.opt.spv` — naga may accept it and give a reference WGSL to diff against ours.
- Reference sources extracted for reading (NOT compiled, per user): `SPIRV-Tools-main/`,
  `wgpu-trunk/naga/` (the naga library — our best-readable reference), `dawn-main/` (Tint) — extract next turn.
- Corpus WGSL harness: `/home/claude/study/corpus_wgsl/*.wgsl` (dedup by md5 from zig-cache
  `shader.wgsl`). Validate-all loop tallies pass/fail + collects diagnostics.

## Turn-1 finding: naga validation of our corpus — 38/40 PASS, 2 FAIL
Both failures are the SAME class, a real WGSL rule Tint/Dawn also enforce:

    error: Global variable 'u' is invalid
    = Alignment requirements for address space Uniform are not met
    = The array stride 4 is not a multiple of the required alignment 16

Offending WGSL (a `var<uniform>` struct):

    struct S31 {
      field_0: array<f32, 2>,   // stride 4 — ILLEGAL in uniform
      field_1: array<f32, 2>,
      field_2: array<f32, 4>,
      field_3: array<f32, 4>,
    };
    @group(0) @binding(0) var<uniform> u: S31;

WGSL rule: in the `uniform` address space, array element stride must be a multiple of 16.
`array<f32,N>` has stride 4 → rejected. (naga RequiredAlignment; Tint has the same rule.)

Root-cause hypothesis (to confirm): our transpiler lowers SPIR-V vectors/matrices/small
arrays inside a uniform block to bare `array<f32,N>`, losing the type that would satisfy
alignment. If the original fields were `vec2`/`vec4`, they must stay `vec2<f32>`/`vec4<f32>`
(align 8/16, uniform-legal). If they're genuinely arrays, uniform layout needs `@stride`-
padded element types (e.g. wrap each element in a 16-byte struct, or use `array<vec4<f32>>`).
This is very likely the exact "we had to change our code to pass browser validation" pain.

## What we already know we do WRONG or fragile (from prior device bugs)
1. OpCopyLogical → emitted zeroed defaults (fixed at 4 sites, but points to weak struct-copy modeling).
2. Unreachable-code after diverging loop bodies — naga ACCEPTS, Dawn REJECTS (we suppress now).
   => naga-pass is necessary but NOT sufficient for Dawn. Need Tint-awareness too (read Tint source).
3. Sampler binding collision / texture-vs-sampler type — fixed via shared solver + build-time linter.
4. Uniform array stride (this turn).

## Multi-turn plan
- **T2**: Confirm the uniform-stride root cause. Read our type-emit path in spv2wgsl.zig
  (struct/array/vector/matrix emission) + the shader-codegen that builds the uniform structs.
  Compare with how naga's `back::wgsl` writer emits uniform-block member types and how it
  decides vec vs array. Fix so uniform members are vec/mat or 16-stride-padded. Re-validate.
- **T3**: Build the FULL corpus (all 272 shaders) and run naga over every one; catalog EVERY
  distinct naga error class we still produce. Prioritize by frequency.
- **T4**: Read naga `front::spv` (SPIR-V → naga IR) and `back::wgsl` (IR → WGSL). Map their
  IR + passes (typifier, validator, WGSL writer) to our monolithic emit. Identify the
  structural passes we lack (a real validator pass; a type/layout resolver; a proper CFG
  structurizer). Write the "what they do vs what we do" tutorial sections.
- **T5**: Read SPIRV-Tools (spirv-val rules; the structured-CFG + relaxed-logical-pointers
  passes) and Tint (Dawn) reader/writer + its stricter-than-naga rules (the unreachable-code
  case). Enumerate the Dawn-only rules we must satisfy that naga won't catch.
- **T6+**: Decide refactor vs rewrite. Draft the design: introduce a small typed IR + a
  validation pass modeled on naga's validator so we can REJECT-or-FIX at transpile time
  instead of shipping bad WGSL. Land incremental fixes, each gated by naga validation in
  `check` (extend the spv2wgsl_check tool to shell out to naga when present).
- **Deliverable**: `src/notes/spv2wgsl_vs_reference.md` tutorial + the transpiler improvements.

## Immediate next action (T2)
grep the two failing shaders back to their source schema (which uniform block has the
array<f32,N> fields), then read spv2wgsl.zig's type emission for uniform members.

---

## T2 DONE — uniform-stride bug FIXED + naga architecture studied

### The fix (verified)
Root cause: `points_vs_io.zig` and `fluid_discs_vs_io.zig` declared UBO fields as
`[2]f32` / `[4]f32` (a 1245-migration artifact — arrays dodged the `@Vector`-in-extern
ban). On the GPU side these lower to `array<f32,N>` in a `var<uniform>` struct, which
WGSL forbids (uniform array element stride must be a multiple of 16; f32 stride is 4).

Fix: since `Ubo` is now a PLAIN struct (not extern), `@Vector` fields are legal again,
and the wire serializer already supports `@Vector(2|4, f32)` (see `wireAlignOf`/`wireFieldSize`
in shader_interface.zig — vec3 is explicitly disallowed as a std140 trap). Changed the
fields to `Vec2`/`Vec` (=`@Vector(4,f32)`). The byte OFFSETS are unchanged (fields were
already naturally aligned: 0,8,16,32...), so the CPU wire layout is byte-identical — but
the WGSL now emits `vec2<f32>`/`vec4<f32>` which are uniform-legal.
VERIFIED: rebuilt shaders emit `field: vec2<f32>/vec4<f32>`; `naga` says "Validation
successful"; point-rendering / fluid-gpu / sph-fluid-2d all build clean. The two stale
naga failures in the corpus scan are pre-fix cache dirs (mtime 22:05 vs the 23:17 rebuild).

LESSON: this is precisely a case a LAYOUT-VALIDATION PASS would have caught at build time.

### How naga is built (the reference architecture)
Pipeline: `SPIR-V → front::spv (parse + CFG-structurize) → typed IR → valid (validate)
→ proc (layout/typifier/namer) → back::wgsl (write)`. LOC: front 37k, back 51k,
valid 10k, proc 11k, IR (ir/mod.rs) 2.8k.

Four things naga HAS that our monolithic 10.5k-line spv2wgsl does NOT:
1. **A typed IR** (`ir/mod.rs`): arena-allocated Handles for Types/Expressions/Statements.
   Everything is typed and referenced by Handle, so passes can reason about it. We translate
   SPIR-V→WGSL text much more directly, carrying less structure.
2. **A CFG structurizer** (`front/spv/next_block.rs`, 3129 LOC): converts SPIR-V's arbitrary
   goto-CFG into structured WGSL control flow (if/loop/switch/break/continue/merge). This is
   the single hardest part of SPIR-V→WGSL and the source of our unreachable-code (Dawn-only)
   bug. Ours is more ad-hoc.
3. **A VALIDATOR** (`valid/`, 9 passes, 10k LOC) — the biggest gap. It validates the IR
   BEFORE emitting, so it never ships invalid output:
   - `type.rs`: type + LAYOUT validation. Has `Disalignment { ArrayStride{stride,alignment},
     StructSpan, MemberOffset }` and `check_member_layout` → per-address-space alignment
     (`uniform_layout` vs storage). `ArrayStride` is the EXACT error text naga gave for our bug.
   - `handles.rs`: every arena Handle points to something valid (no dangling refs / the class
     of bug behind our OpCopyLogical zeroing).
   - `expression.rs` / `function.rs`: every expression well-typed; every statement legal.
   - `interface.rs`: entry points, resource bindings, IO location rules.
   - `analyzer.rs`: uniformity analysis (which is what governs where texture sampling is legal
     — related to our `[sampler-in-helper]` lint but done properly at the IR level).
4. **proc passes** (`proc/`): `Layouter` (computes offsets/sizes/alignments — the source of
   truth a layout validator needs), `Typifier` (infers expression types), `Namer` (WGSL-legal
   unique identifiers), `ResolveContext`. We hand-roll fragments of these inline.

### Plan to REACH them (correctness parity: always pass naga+Tint)
- **P1 — Validation harness (do first, cheap, huge leverage):** wire `naga` into `check` as a
  hard gate. Build the FULL corpus, validate every WGSL with naga, fail the build on any
  rejection. This turns "discover on device" into "fail at build". (Tint-only rules — the
  unreachable-code case — naga won't catch; keep our spv2wgsl_check duplicate-binding linter and
  ADD targeted Tint-rule linters as we find them.)
- **P2 — A layout pass, modeled on naga `proc::Layouter` + `valid/type.rs`:** compute
  offset/size/alignment for every struct per address space, and REJECT (or auto-fix: promote
  small scalar arrays in uniform blocks to vecN, insert std140 padding) at transpile time. This
  fixes the whole CLASS of the bug above, not just two shaders.
- **P3 — Harden the CFG path against Dawn:** study `front/spv/next_block.rs` (T5) and make our
  structurizer's divergence/merge handling match what Dawn accepts (we already special-case the
  unreachable-return; generalize it from naga's model).
- **P4 — Introduce a minimal typed IR at the SPIR-V→WGSL seam** so we can run validation/layout
  passes over structured data instead of pattern-matching text. (Refactor, not full rewrite.)

### Plan to BEAT them (where we can be better than naga/Tint for OUR use case)
naga/Tint are general SPIR-V→WGSL. We control the WHOLE pipeline (Zig shader → our SPIR-V →
our WGSL), so we can:
- **Emit already-valid WGSL by construction** (single-source layout solver shared by SPIR-V gen
  AND WGSL emit — we started this with the sampler-slot solver). If both sides derive from one
  typed schema, whole error classes become unrepresentable.
- **Keep byte-identical CPU/GPU/comptime layouts** (our north star: same fragment shader on CPU
  and GPU). naga doesn't care about a CPU mirror; we do, and our wire serializer already encodes
  it — so our layout pass can be STRICTER and also guarantee CPU parity, which neither tool does.
- **Produce smaller/cleaner WGSL** than naga's (its output has S31/field_0 numbering + many
  private globals + `const undef_*` splats we saw). We can carry names/semantics through.
- **Faster, dependency-free, in the same Zig build** (no Rust/C++ toolchain).

### Deliverable tracking
- Tutorial file (final): `src/notes/spv2wgsl_vs_reference.md`. Sections drafted here (architecture,
  validator, CFG, layout). Expand with concrete side-by-side WGSL (ours vs naga) in T3-T5.
- Next (T3): P1 — build full corpus, naga-validate all 272, catalog EVERY remaining error class.
  Then read `front/spv/next_block.rs` + `proc/layouter.rs` for P2/P3 design.

---

## ★ THE PLAN (precise, dependency-free) ★
Constraint from Simon: **naga is a temporary dev oracle ONLY** (at
`/home/claude/study/wgpu-trunk/target/debug/naga`). We must NOT depend on it long-term.
The permanent gate is OUR OWN validator, ported from naga's rules into Zig. Main focus =
the transpiler emitting valid WGSL; porting the full validator is the stretch goal.
Ship order is value-first and each phase is independently useful.

### Reference: naga's layout algorithm (captured, ready to port to Zig)
Base layout — `proc/layouter.rs`, `TypeLayout { size, alignment }`, ~284 LOC total:
- scalar/atomic: `align = width` (f32/i32/u32 → 4). `size = width`.
- vector: `align = vecSizeAlign * width`, where vecSizeAlign = {vec2→2, vec3→4, vec4→4}.
  ⇒ vec2 align 8, vec3/vec4 align 16. `size = width * count`.
- matrix (column-major): `align = rowsAlign * width` (each column is a vector).
- array: `align = element.align`; `size` includes stride*count.
- struct: `align = max(member aligns)`; `size = span` (declared/rounded).
- `Alignment.round_up(n)`, `Alignment.is_aligned(n)`, `Alignment.new(pow2)`.

Per-address-space rules — `valid/type.rs`, `TypeInfo { uniform_layout, storage_layout }`,
`check_member_layout` + `Disalignment { ArrayStride{stride,alignment},
StructSpan{span,alignment}, MemberOffset{index,offset,alignment} }`:
- STORAGE: member.offset must be aligned to member.align; array stride aligned to elem.align.
- UNIFORM (std140, stricter): array element stride AND struct member alignment are rounded
  UP to 16, i.e. `RequiredAlign(array|struct, uniform) = roundUp(16, baseAlign)`. THIS is why
  `array<f32,N>` (stride 4) fails in uniform, and `vec4` (align 16) passes. (Our fixed bug.)

### Phase 1 — `src/wgsl_layout.zig` : the layout+validation module (HIGHEST VALUE)
A pure, comptime-and-runtime Zig port of Layouter + the per-address-space checker. No naga,
no deps. Two entry points:
- comptime `fn layoutOf(comptime T: type, space) TypeLayout` + `fn validateLayout(comptime T,
  space) ?LayoutError` — operate on a Zig SCHEMA struct. Used by shader_interface/gen_shader_
  externs to (a) REJECT a bad uniform/storage block at COMPTIME with a naga-quality message,
  and (b) drive valid-by-construction SPIR-V emission (emit 16-aligned uniform member offsets/
  strides; auto-promote `[2..4]f32`→`vecN`; auto-pad otherwise). This is where we BEAT naga:
  the CPU wire serializer (already in shader_interface) + this share ONE layout truth, so
  CPU/GPU/WGSL can't disagree.
- runtime `fn checkWgslStructLayout(parsed_struct, space) ?LayoutError` — operate on a struct
  parsed from EMITTED WGSL text. Wired into `tools/spv2wgsl_check.zig` (already in `check`),
  so EVERY emitted WGSL is layout-validated at build time — the permanent, naga-free gate.
Deliverable: kills the uniform-stride class for good; unit tests mirror naga's Disalignment
cases; add a regression fixture (a schema that used to fail).

### Phase 2 — Full-corpus defect catalog (uses naga oracle NOW, temporarily)
Build all 272 shaders; run naga over every WGSL; bucket every distinct error class by
frequency; for each, decide fix-at-schema vs fix-at-transpiler vs port-a-validator-rule.
Output: a ranked defect table appended here. (This is the only phase that leans on naga, and
only to DISCOVER classes — the fixes and permanent gates are ours.)

### Phase 3 — Transpiler correctness fixes (the main focus)
Fix each cataloged class in `src/spv2wgsl.zig` (or the schema/codegen when that's the true
source). Known targets so far: (a) layout → Phase 1; (b) CFG unreachable/divergence (the
Dawn-only class) → generalize our current special-case using naga `front/spv/next_block.rs`'s
structured-block model (study T5); (c) OpCopyLogical struct-copy fidelity (revisit — points to
weak struct modeling). Each fix gets a spv2wgsl unit test + stays green under naga during dev.

### Phase 4 — Minimal typed IR at the seam (enabler; refactor not rewrite)
Introduce a small typed IR (`src/spv2wgsl_ir.zig`: Types/Exprs/Stmts as tagged unions with
indices, à la naga arenas) between SPIR-V parse and WGSL write, so layout/validation/CFG passes
run over structured data instead of text. Keep the existing emitter working; migrate incrementally.

### Phase 5 (STRETCH) — Port the validator (`src/wgsl_valid.zig`)
Port naga `valid/` passes in value order: type/layout (mostly Phase 1) → handles (no dangling
refs) → interface (bindings/IO/entry points) → expression/function (well-typed). This is the
permanent replacement for naga: after this, `check` validates every WGSL with OUR validator and
naga can be deleted from the workflow entirely.

### Immediate next action (T4): write `src/wgsl_layout.zig` (Phase 1), unit-test against
naga's Disalignment cases, wire the runtime check into spv2wgsl_check, and re-run `check`.

### ✅ Phase 1 LANDED (T6)
`src/wgsl_layout.zig` written — pure-comptime port of naga's Layouter (`alignOf`/`sizeOf`/
`offsetOfField`) + the address-space validator (`validateForSpace`/`assertValidUniform`).
6 unit tests pass, mirroring naga's Disalignment cases: the exact `[N]f32`-in-uniform bug is
rejected with a "stride … not a multiple of 16" message, the vec-field fix validates, `[N]vec4`
is uniform-legal while `[N]vec2` is not, and vec3 is flagged as a std140 trap. WIRED as a
build-time gate: `shader_interface.zig` re-exports `assertValidUniform`, and
`tools/gen_shader_externs.zig` calls it at the per-schema UBO chokepoint — so any UBO whose
WGSL uniform layout Tint/Dawn would reject is now a COMPILE ERROR with a precise message,
naga-free. Verified: point-rendering (and all UBO shaders) build clean; no false positives.
### ✅ Phase 1b LANDED (T7) — Tint behavior analysis, merged INTO spv2wgsl.zig (no new file)
Replaced the informal boolean divergence helpers (`itemsAlwaysDiverge`/`blockAlwaysDiverges`/
`termDiverges`/`constructAlwaysDiverges`) with a faithful port of Tint's behavior model, right
in `src/spv2wgsl.zig` next to the emitter. Added a `Behaviors` packed-set {next,ret,brk,cont}
and `termBehaviors`/`blockBehaviors`/`constructBehaviors` implementing the WGSL spec rules
(#behaviors-rules): block = fold `(b−next)+stmt`; if = union of arms; switch = union of
cases; loop = body(+continuing), `next` IFF body can `break`, break/continue consumed. The old
helpers are now one-line wrappers (`diverges == !behaviors.next`) so all call sites (the
unreachable-return suppression in `emitBlock`) are unchanged — but now also correct for the
case the boolean version missed: an INFINITE loop (body can't break) has no `next`, so code
after it is unreachable (Dawn rejects; the old `.loop_ => false` did not catch this).
VERIFIED: spv2wgsl compiles; point-rendering, pbr-demo, hybrid-render (loop-heavy) build clean;
naga-validates every freshly-regenerated shader (the 2 corpus fails are stale pre-fix cache
dirs, mtime 22:05). FOLLOW-UP: add IR-level unit tests for the behavior rules (needs a small
IR-builder helper; the loop-heavy corpus is the current evidence) and port a few of Tint's
`control_block_validation_test.cc` cases.

### ✅ File consolidation + simplification DONE (T8)
`src/wgsl_layout.zig` DELETED. Its validator folded into `src/shader_interface.zig` next to the
wire serializer — and SIMPLIFIED in the process: instead of duplicating a layout engine
(`alignOf`/`sizeOf`/`offsetOfField`, ~250 LOC), the new `uniformFieldError`/`assertValidUniform`
(~35 LOC incl. test) REUSE the existing `wireAlignOf`/`wireFieldSize`. The wire (CPU) layout and
the base WGSL layout agree byte-for-byte on the allowed UBO field set, so there is now ONE layout
source of truth shared by CPU-wire serialization AND WGSL uniform validation — exactly the
"valid by construction from one schema" goal. `gen_shader_externs` still calls
`shader_iface.assertValidUniform(IfaceMod.Ubo)` (unchanged). VERIFIED: `zig build check` → 185 ok,
0 failed (this runs gen_shader_externs on every schema and spv2wgsl on the whole corpus, so it
confirms the UBO gate has no false positives AND the behavior analysis has no regression).
File count net −1. Note: the standalone base-layout API (`layoutOf`/`offsetOfField`) was dropped
as unused — if a future WGSL-text validator (for hand-authored WGSL) needs it, it can call the
wire functions too.

### ✅ shader_builtins.zig extraction DONE (T11) — decouples shader DSL from host
The SPIR-V shader DSL (stage-IO decorators `location`/`binding`, the `@SpirvType` texture/
sampler/storage types, `texture2D`/`sampler`, `zsample2d`, `sampleLod`/`sampleLevel`,
`StorageImage2D`/`imageStore`, `storageBuffer`/`ssboLoad`/`ssboStore` — 18 pub decls) was
carved out of `zimrmath.zig` (now 9337 LOC, was 9730) into `src/shader_builtins.zig`. Rationale:
`zm` is imported by the ENTIRE host, so editing a shader intrinsic invalidated every module's
cache and forced the ~280s full rebuild (the recurring `check` timeouts). Now touching an
intrinsic only rebuilds shaders. Boundary rule: value-math (dot/length/normalize/vec builders)
stays in `zm` (shared CPU+GPU); the GPU-interface layer moves out. Verified no host code calls
the intrinsics (only shaders + the codegen, which references names as strings). Wiring:
`build.zig` adds a `shader_builtins` module (imports `zm`) and hands it to the 3 externs modules;
`src/shader_codegen.zig` adds `-Mshader_builtins=` (dep `zm`) to the SPIR-V compile for both the
shader root and the externs; `tools/gen_shader_externs.zig` templates now `@import("shader_
builtins")` for the intrinsics; `tests/fixture_fs.zig` + `src/shaders/probes/sampler_test_fs.zig`
import it directly. VERIFIED: standalone SPIR-V compile of a shader importing both modules (800 B);
`cube3d` textured example rc=0; `zig build check` → 260 ok, 0 failed.

### ✅ sampleLevel escape hatch (T10-T11) — sample in helpers/branches, verified
`shader_builtins.sampleLevel(tex, samp, uv, lod)` — explicit-LOD 2D sample via
`OpImageSampleExplicitLod` (no derivatives → valid in ANY control flow → lowers to WGSL
`textureSampleLevel`). Verified end-to-end: a shader sampling in a HELPER via `sampleLevel`
compiles and its WGSL passes naga ("Validation successful"). The `isBareSamplerCall` lint now
matches implicit-LOD samplers (`zsample2d` + `sampleLod` → `textureSample`, must be uniform) and
intentionally exempts the explicit `sampleLevel` (the escape hatch). NOTE: this helps shaders on
the MODERN `texture2D`/`sampleLod` inline path; all current shaders use the OLD `zsample2d`
(noinline wrapper) path, so the definitive fix for THEM is still uniformity analysis (or
migrating them to the modern inline path). See the "Texture-sample-at-root-of-main" section.


### Transpiler fix (T13): OpSMod (opcode 139) was UNHANDLED
Found while porting `eratosthenes_sieve` (`@mod` in a prime test): the transpiler silently
emitted `i32()` (0) for `OpSMod`, so `value % i == 0` was always true → the sieve rendered a
smooth gradient (color = largest i tried ≈ sqrt) instead of scattered primes. FIX: added `SMod`
to the opcode enum + dispatch (emit `%`, matching the already-handled `SRem`; correct for
non-negative operands — the common shader case; true signed-modulo sign handling for mixed-sign
operands is a future refinement). This is exactly the naga-oracle value proposition applied to a
SEMANTIC bug our binding-only checker misses — worth a spv2wgsl_check rule that flags any
`UNHANDLED spv opcode` in emitted WGSL.

### Texture-sample-at-root-of-main (the most common historical error) — INVESTIGATED (T10)
Simon asked if this work fixes the "must sample textures at the root of shaderMain" pain. It
does NOT yet, and a naive attempt this turn FAILED and was reverted — but the failure taught us
exactly why and what the real fix must be.

The constraint: WGSL `textureSample` computes screen-space derivatives, so Dawn permits it only
in UNIFORM control flow. Two lints enforce this at the source: `sampler-in-helper` (sample in a
user helper fn) and `sampler-in-branch` (sample inside an if/loop of main) — both force samples
to shaderMain's unconditional top.

Attempted fix: in `emitImageSample`, emit `textureSampleLevel(..., 0.0)` (derivative-free, valid
in ANY control flow) for samples not in the entry function, and relax `sampler-in-helper`.
RESULT: broke ALL sampling — every shader flipped to `textureSampleLevel`, losing auto-LOD/
mipmapping. ROOT CAUSE: texture sampling always routes through a `noinline __sample2d` wrapper
(`zm.sample2d`, see zimrmath.zig / shader_codegen.zig), so the actual `OpImageSampleImplicitLod`
is ALWAYS inside a helper (the wrapper), never in the entry fn — `s.is_current_entry` is always
false at the sample site. So a per-site "am I in the entry fn" test cannot distinguish "the
wrapper called from uniform flow" (wants `textureSample`) from "a user helper called from non-
uniform flow" (wants `textureSampleLevel`). Reverted both changes; `zig build check` → 185 ok.
(The empty-type-var fix from T9 is retained.)

What the REAL fix requires — options, in order of correctness/effort:
- **A. Uniformity analysis (Tint `uniformity.cc`)**: build the call graph + CFG, propagate
  uniformity, and decide per `textureSample` whether it is ALWAYS reached via uniform flow.
  Non-uniform-reachable samples become an error OR are lowered to `textureSampleLevel`. This is
  the correct, complete fix — and is a substantial pass (the hardest of the reference-parity
  items). It would let us DROP both sampler lints and auto-handle helper/branch samples.
- **B. Inline `__sample2d` (and user helpers that sample) into the entry fn**, then apply a
  per-site `construct_depth` check (uniform iff depth==0 in main). The wrapper is thin so
  inlining it is cheap; inlining user helpers is more involved. After inlining, the samples are
  in main's control flow where `is_current_entry` + construct depth IS a valid signal.
- **C. Two wrapper variants** — `__sample2d` (textureSample) and `__sample2dLod` (textureSample-
  Level); the transpiler picks per call site from uniformity (still needs analysis A).
- **D. Library escape hatch (pragmatic, low-risk, partial)**: expose `zm.sample2dLod` that
  emits `textureSampleLevel`, and EXEMPT it from the sampler lints. Authors opt into it when
  sampling in a helper/branch (no auto-LOD there). Doesn't auto-fix, but removes the hard build
  error with a one-line author change. Achievable without uniformity analysis. GOOD next step.

RECOMMENDATION: land D as a quick win (escape hatch + lint exemption + a helper-sample test that
naga-validates), then pursue A (uniformity analysis) as the definitive fix — it is the last big
reference-parity item alongside the CFG structurizer. Add both to the phase list.

### ✅ Phase 2 STARTED (T9) — full naga sweep found + fixed a real transpiler bug
Ran the naga oracle over the whole cache corpus. Beyond the known layout class (2 stale
pre-fix cache dirs), it caught a genuine transpiler defect OUR checker missed: `var _8: ;` —
an EMPTY-TYPE local declaration (invalid WGSL: "expected identifier, found ;"). Root cause: a
zero-bit / void value (opaque type or void) that is HOISTED (used across blocks) or a phi/
OpVariable gets a function-entry `var NAME: <empty>;` — its type has no WGSL name. Such values
fold to `undef` at their use sites, so the declaration is dead. FIX (spv2wgsl.zig): guard all
three function-entry var-decl sites (hoisted values, phis, OpVariables) to skip when the type's
`wgsl_name` is empty. VERIFIED: the fixture (tests/fixture_fs.zig) now emits 0 empty-type vars
and naga says "Validation successful"; refreshed the locked corpus fixture
(tests/fixtures/wgsl_corpus.json, 46 live + 92 carried); `zig build check` → 185 ok, 0 failed.
This is exactly why the naga oracle is worth using during dev: it flags classes
`spv2wgsl_check` (bindings only) doesn't. FOLLOW-UP (cheap, defense-in-depth): add an
"empty-type var / `: ;`" lint to `spv2wgsl_check` so OUR gate catches this class too, and note
`s.hoisted` is indexed by id so a hoisted id is declared in every function — worth revisiting
for dead-decl pruning. NEXT: build more of the 272-shader corpus (only ~46 unique are in cache)
for broader coverage, and seed Tint behavior cases naga won't flag.

### Simplifications banked so far (theme: fewer files, one source of truth)
- Behavior analysis: replaced 4 informal boolean divergence helpers with one principled
  `Behaviors` model (more correct — fixes the infinite-loop case — and no larger). In spv2wgsl.zig.
- Layout: one layout engine (the wire serializer) now serves CPU-wire + WGSL validation, instead
  of two. In shader_interface.zig. wgsl_layout.zig removed.
- Remaining external file for this work: none — both landed pieces live in existing files.

---

## ★ Tint & SPIRV-Tools deep-dive (T5) — the biggest new insight ★

### Tint's BEHAVIOR ANALYSIS — the thing naga does NOT have and Dawn enforces
Tint (Dawn's WGSL compiler = the ACTUAL browser validator) is IR-based like naga:
`SPIR-V → reader/parser.cc (→ Tint core IR) → resolver (types+behavior+uniformity) → WGSL`.
Its resolver runs a formal **behavior analysis** straight from the WGSL spec
(https://www.w3.org/TR/WGSL/#behaviors-rules). This is the exact model behind our worst
Dawn-only bug (unreachable code), and crucially **naga does not enforce it** — so this is
what lets us catch Dawn-only control-flow bugs WITHOUT Dawn.

Model (`lang/wgsl/sem/behavior.h`): every statement has `Behaviors` = a subset of
`{ kReturn, kBreak, kContinue, kNext }`. `kNext` = "control can fall through to the next
statement". The per-statement rules (from `resolver.cc`):
- **compound block**: `b = {kNext}`; for each stmt s in order: `b = (b − kNext) + s.behaviors`.
  If a NON-LAST stmt lacks `kNext`, everything after it is UNREACHABLE ⇒ Dawn error
  "code is unreachable" (validator.cc:1767). ← THIS is our bug: a `return` after a loop-body
  `if(c){continue}else{break}` (both arms diverge, so the if has no kNext) is unreachable.
- **if**: no-else ⇒ always add `kNext` (the then can be skipped). both-branches ⇒
  `then.behaviors ∪ else.behaviors` (if both diverge, no kNext).
- **loop**: `b = body (+ continuing)`; then `if body Contains(kBreak): add kNext else: remove
  kNext`; finally `remove {kBreak, kContinue}`. ⇒ a loop that never `break`s has NO kNext, so
  code after it is unreachable.
- **for**: same, but `if (has condition || body Contains(kBreak)) add kNext` — a conditional
  for can always fall through.
- **switch**: union of case behaviors; `break` in a case ⇒ contributes kNext; then remove kBreak.
- **function**: `func.behaviors = body.behaviors`; if it Contains(kReturn), swap kReturn→kNext.

Why this matters more than the layout pass: layout errors naga ALSO catches, but behavior/
unreachable errors are Dawn-ONLY (naga silently accepts). Our current `itemsAlwaysDiverge`/
`blockAlwaysDiverges`/`termDiverges` in spv2wgsl.zig is an informal, partial reimplementation of
exactly this. Porting the real thing (4-value enum-set + these ~7 rules, a couple hundred LOC)
gives us a PRINCIPLED, complete way to (a) never emit unreachable statements, and (b) validate
control flow to Dawn's standard at build time, naga-free.

Tint also has UNIFORMITY analysis (`resolver/uniformity.cc`) — governs where non-uniform
control flow may call `textureSample` etc. (Dawn rejects non-uniform sampling.) This is the
proper version of our `[sampler-in-helper]` lint. Lower priority but note for later.

### SPIRV-Tools — mostly an INPUT contract + CFG cleanup techniques
- `source/val/validate_cfg.cpp` (1315 LOC): the SPIR-V structured-CFG validator — dominance,
  OpSelectionMerge/OpLoopMerge merge-block rules, back-edges. This defines what VALID structured
  SPIR-V looks like = our transpiler's INPUT contract. If we validated our zspv_rewrite output
  against these rules we'd catch malformed-CFG inputs before transpiling.
- opt passes worth knowing: `merge_return` (collapse multiple OpReturn into one structured
  return — makes function-end control flow trivially structured), `block_merge`,
  `dead_branch_elim`, `aggressive_dead_code_elim`. Our inputs are already structured (Zig→SPIR-V
  via our own path), so these are techniques to borrow if we ever need to normalize CFG, not
  must-haves. `merge_return`'s idea is the useful one for the unreachable-return class.
- `cfa.h` (control-flow analysis: dominators, structured-CFG traversal) is a compact reference
  if we build a real CFG pass.

### REVISED PRIORITY (after Tint study)
The plan's Phase 3 (CFG) is SPLIT and PROMOTED, because behavior analysis is the only way to
catch the Dawn-only class without Dawn:
- **Phase 1 — `src/wgsl_layout.zig`** (layout; catches the class naga also catches). Unchanged.
- **Phase 1b — `src/wgsl_behavior.zig`** (NEW, co-equal priority): port Tint's Behavior enum +
  the ~7 statement rules. Use it in spv2wgsl's emitter to (a) drop provably-unreachable trailing
  statements (generalizing the current special-case), and (b) as a build-time control-flow
  validator in spv2wgsl_check. This is our ONLY defense against Dawn-only CFG rejects without
  shipping to a device. HIGH value.
- **Phase 2** — full-corpus naga catalog (layout/type classes) — but ALSO manually seed
  behavior test cases (naga won't flag them), derived from Tint's `resolver_behavior_test.cc`
  and `control_block_validation_test.cc` (great ready-made test corpora to port).
- **Phases 3-5** unchanged (transpiler fixes, typed IR, full validator port). The typed-IR phase
  is where behavior+layout+uniformity passes all naturally live, mirroring Tint/naga's resolver.

### Best test assets to port (free, high-value)
- Tint `lang/wgsl/resolver/control_block_validation_test.cc` + `resolver_behavior_test.cc` —
  authoritative unreachable-code / behavior cases (Dawn-exact).
- naga `Disalignment` variants — layout cases.
Porting these two test files' cases into our spv2wgsl/wgsl_layout/wgsl_behavior tests gives us a
Dawn+naga-aligned regression suite with zero runtime dependency on either tool.
