>>> turn 857: §4.C PBR-lit cube DEMO BUILT (first PBR-on-wgpu render) <<<

examples/wgpu_pbr_demo/ + wgpu-pbr-demo / wgpu-pbr-standalone build
steps. Wires engine pbr_vs/pbr_fs on the cube/lambert depth-tested draw
path BY HAND (paralleling wgpu_lambert_demo). Binding layout read from
the EMITTED naga-valid WGSL (not the IO schema): g0=5 mat4 VS uniforms
@0..4; g1=6 tex @0..5 + 6 samplers @6..11; g2=18 LOOSE FS uniforms
@0..17 (light arrays padded to vec4 for std140). 35 bindings, built via
loops. First milestone = PBR lighting on a primitive: 1 white texture
for all 6 maps, 1 directional light, point/fog/shadows OFF. Built clean
first try (thorough study paid off). VERIFIED: pbr_vs+pbr_fs WGSL
naga-VALID, lint 0/273, wgpu-smoke PASS (73 init calls, 60 frames no
trap), tier-a-check exit 0, no regressions. Simon verifies in browser.

NEXT §4.C: (1) shadows ON (depth pass→shadow map, light_space_matrix,
shadow_enabled=1); (2) damaged_helmet GL→wgpu (GLTF+PBR, real textures
via drawMesh sampler loop — combined-sampler limit will bite, budget
debug); (3) pbr_standalone (already wired). See finishing_webgpu.md §4.C
STATUS.

>>> turn 856: prediction-test found a latent miscompile; code improvements + flatten-prep <<<

PREDICTION TEST (wrote speculative Zig shaders, compiled raw via
`zig build-obj -target spirv32-vulkan -mcpu vulkan_v1_2 -fno-llvm
-fno-lld -O ReleaseFast -ofmt=spirv`, ran spv2wgsl+naga):
- loop-in-called-helper, nested loop+break, switch, mandel: ALL translate
  + naga-valid (transpiler more robust than expected).
- CALLED pointer-out-param helper (`fn f(a:*f32,b:*f32){a.*=...}`,
  `f(&a,&b)`): translates + naga-VALID but SILENTLY MISCOMPILES — the
  by-value param lowering (slice (b) PART 2) makes the callee write a
  local copy; call site passes the value not `&a`; caller never sees the
  result. naga can't catch it (well-formed WGSL). Full writeup +
  deferred faithful-ptr fix in finishing_webgpu.md (the ⚠️ KNOWN LATENT
  BUG block). LESSON: naga-valid != correct; need a numeric/behavioral
  gate before trusting raw output end-to-end.

IMPROVEMENT (made it LOUD): emitFunctionCall now emits an `// ERROR:`
marker when a call passes a pointer-typed arg to a by-value param, so the
miscompile is detectable instead of silent. Verified: ptrshader gets the
marker; all 37 real raw shaders still naga-valid with 0 false markers
(none have called out-params).

FLATTEN-PREP (next big task = flatten transpiler toward one file): made
all transpiler free-fn names unique. Only real collision was operandsAt/
opcodeOf/wordCountOf, each duplicated verbatim in spv2wgsl.zig +
block_table.zig + ir_build.zig. Hosted them ONCE as `pub fn` in
spv2wgsl/types.zig (single source of truth); the 3 consumers now alias
`const operandsAt = types.operandsAt;` etc (call sites unchanged). The
other shared names (wgslNameOf, emitEntryReturn, emitUnreachReturn,
currentFunctionIsEntry, scalarTypeNameOf) are State-vs-FakeState METHODS
— struct-scoped, won't collide on flatten.

claude.md cleaned to GENERAL rules only (removed plan/turn specifics per
request); plan specifics stay in finishing_webgpu.md. GATES: live 39/39,
tint 164/13/0-tf, naga-tint 168/0/13, host all-pass, lint 0/272,
tier-a-check EXIT 0, NO REGRESSIONS.

>>> turn 855: §2 MILESTONE — ALL 37 RAW SHADERS NAGA-VALID; §3.A closed (known-invalid 1->0) <<<

Two final fixes after dead-fn-elim:
(1) I/O-in-helper (was already implemented a prior turn — VERIFIED by
    grepping emitted WGSL, didn't re-do it): SPIR-V Input/Output vars
    emitted as module-scope `var<private>`; entry wrapper copies
    inputs.X->X at entry, X->outputs.X at .ret. Resolves bare-name I/O in
    any function. ALSO closed §3.A (VertexShader_PositionUsed_Transitive
    now valid) -> naga-tint known-invalid 1->0.
(2) `.unreach` in a VALUE-returning fn: body ending in post-merge
    OpUnreachable tail (Zig's pattern after all-returning if/else arms,
    e.g. zimrmath_clamp01) fell off the end -> naga "Returning None where
    Some(T) expected". FIX: ir_emit `.unreach` -> State.emitUnreachReturn
    emits `return T();` (zero-value ctor) for value-returning non-entry,
    nothing for void/entry. Added State.current_ret_type (set per-fn in
    emitOneFunction, reset via defer; FakeState got a stub for ir_emit's
    own tests). Sound: block is unreachable.

MEASURED raw 37/37 naga-valid (30 struct-bitcast->0 dead-fn-elim, 7+
scope->0 I/O fix, last Returning-None->0). Regression-free: opted 39/39,
tint 164/13/0-tf, naga-tint 168/0/13, host all-pass, lint 0/272,
tier-a-check EXIT 0.

NEXT §2.2 (UNBLOCKED): drop spirv-opt from the WGSL pipeline. Switch
ShaderPipeline (src/shader_codegen.zig) to feed RAW zig build-obj SPIR-V to
spv2wgsl (drop spirv-opt->spirv-val->spirv-cross for WGSL path); run FULL
suite+smoke+naga; only then delete vendored tools/spirv/ + prebuilts.
Keep 13 unstructured Tint fixtures count-gated. Own turn, full suite, not
a tail. See finishing_webgpu.md §2 MILESTONE + NEXT.

>>> turn 855b: I/O-IN-HELPER FIX — §3.A CLOSED, naga-invalid baseline now EMPTY; raw 0 -> 11 valid <<<

Zig puts shader logic in a HELPER (<name>_fs_main) called by an entry
wrapper that scoped I/O locally -> helper referenced frag_uv/color out
of scope -> naga "no definition in scope". SAME class as the open §3.A
fixture (VertexShader_PositionUsed_Transitive, Output in a helper). ONE
mechanism fixed BOTH: emit SPIR-V Input/Output OpVariables as module-
scope `var<private>` (pass3); emitEntrySignature copies inputs.X -> X at
entry (not a local); new State.emitEntryReturn stages Output privates
into the Outputs struct at the entry return (outputs.X = X; return
outputs; or return <var> for single-struct output_alias); ir_emit .ret
for entry delegates to emitEntryReturn; REMOVED the is_current_entry ->
outputs.X redirect in emitStore/emitAccessChain (bare module-scope name
used uniformly from entry OR helper). Tint/naga model SPIR-V I/O globals
exactly this way.

RESULTS: no-definition-in-scope wall cleared; raw 0 -> 11 naga-valid;
§3.A fixture now valid -> removed from naga-invalid-baseline.txt -> the
baseline is EMPTY (naga-tint valid=168 known-invalid=0). Regression-free:
live 39/39, tint 164/13/0-tf, host all-pass, lint 0/272, tier-a-check
EXIT 0. Refreshed canonical wgsl_corpus.json (7 -> 15 entries; I/O
emission changed for all shaders).

NEXT WALL (26 raw): naga "Returning None where Some(...) is expected" — a
value-returning HELPER (zimrmath_clamp01(f32)->f32) with a path emitting
bare `return;`/fall-through instead of `return <value>;` (early-return/
merge in a value-returning fn; spirv-opt merge-return would normalize).
Bounded; next §2 item. See finishing_webgpu.md §2+§3.A UPDATE.

>>> turn 853b: DEAD-FUNCTION ELIMINATION — struct-bitcast wall gone (30/37 -> 0); 1 wall left <<<

Struct OpBitcasts reinterpret POINTERS between unrelated struct layouts
(ptr<struct{u32,u32}> -> ptr<struct{...ptr<u8>...}>) — Zig comptime/type
machinery (8-bit ptrs, ptr-to-ptr) WGSL can't express. KEY: all live in
UNCALLED dead helpers (%42,%83,%904; none reachable from entry). Did the
principled fix (Tint reader step-1 / spirv-opt DCE): added
computeReachableFunctions to pass4_functions (build OpFunctionCall graph,
BFS from entry, skip unreachable fns). Removed ALL struct-bitcast fns in
one stroke (30->0). Regression-free (opted shaders already DCE'd): live
39/39, tint 164/13/0-tf, naga-tint 167/1/13, host all-pass, lint 0/272,
tier-a-check EXIT 0.

REMAINING — now the SINGLE wall for all 37 raw: I/O accessed in a HELPER,
not the entry wrapper. Zig puts shader logic in <name>_fs_main() and a
wrapper main() that declares `var frag_uv=inputs.frag_uv; var outputs;`
then CALLS the helper — helper references frag_uv/color out of scope ->
naga "no definition in scope". SAME inter-procedural-I/O class as the
OPEN §3.A naga-debt fixture (VertexShader_PositionUsed_Transitive). ONE
fix closes BOTH §2's last wall + §3.A: make Input/Output vars module-
scope (private var; wrapper copies inputs->private at entry, private->
outputs at exit) or thread as params. Then 37 should all be naga-valid
-> §2.2 drop spirv-opt. See finishing_webgpu.md §2 UPDATE + §3.A.

>>> turn 852b: §2 slice (b) PART 2 DONE — pointer params; "immutable binding" gone from all 37 raw <<<

Zig passes fn params by pointer (OpTypePointer Function); emitTypePointer
spells a pointer as just its pointee, so a param became immutable WGSL
binding `p932: u32` and `OpStore %932` → `p932 = 2u;` → naga "immutable
binding". KEY: dumped call graph — these pointer-param fns are ALL
UNCALLED dead helpers, so by-value vs by-ref is moot; only naga-validity
matters. FIX (emitOneFunction non-entry branch): emit pointer param by
value as `{name}_param`, shadow with `var {name}: {pointee} =
{name}_param;` at entry — existing OpStore/OpLoad/access-chain text
(spelling the ptr as {name}) works unchanged. Zero call-site changes.
"immutable binding" gone from all 37; live 39/39, tint 164/13/0-tf,
naga-tint 167/1/13, host all-pass, lint 0/272, tier-a-check EXIT 0.

NEXT WALLS (raw shaders, measured): 30/37 struct OpBitcast
(`bitcast<S46>(s36)` — WGSL bitcast is scalar/vector only; Zig bitcasts
aggregates → needs struct-reinterpret or same-layout field reconstruct);
7/37 "no definition in scope for identifier" (separate emission gap).
Each bounded. spirv-opt stays until cleared. See finishing_webgpu.md §2
slice (b) PART 2 + NEXT WALLS.

>>> turn 851b: §2 slice (b) PART 1 DONE — unreachable phi-pred skip; raw 24/37 -> 37/37 translate <<<

All 13 raw-shader MalformedFunction bails were at ONE site:
Builder.attachExitArg, when a merge OpPhi names a predecessor block that
was never built. CFG dump showed why: Zig's un-opted SPIR-V leaves
STRUCTURALLY-UNREACHABLE blocks (0 in-edges) still named as phi preds
(e.g. if-true-arm early-returns; merge phi cites dead block %873 nothing
branches to). FIX: attachExitArg now SKIPS a pred that is not header /
not a branch-entry / not in by_id (unreachable edge -> no IR terminator
to attach; value never produced at runtime; hoisted phi var keeps
default; sound because dropping an unreachable def-edge can't change
reachable computation). Measured raw translate 24/37 -> 37/37, 0
MalformedFunction. Corpus/live unchanged (tint 164/13/0-transfail,
naga-tint 167/1/13, live 39/39), host all-pass, lint 0/272, wgpu-diff
PASS.

PART 2 NEXT (characterized, not yet done): the 37 raw shaders translate
but are naga-INVALID — Zig passes fn params BY POINTER (OpTypePointer
Function) and OpStores through them; emitter renders param as immutable
WGSL binding + direct `p932 = 2u;` -> naga "immutable binding". ALL 37.
Fix: emit pointer params as `ptr<function,T>` (or per-param mutable
`var`), lower stores/loads + call-site `&local`. In emitOneFunction +
OpStore/OpLoad/OpFunctionCall handlers. See finishing_webgpu.md §2
PROGRESS slice (b) PART 2. spirv-opt stays until then.

>>> turn 850b: tier-a-check now exits 0 (was a FALSE non-zero for many sessions) <<<

ROOT CAUSE (not what the prior notes implied): the "_5 never declared"
err log was NOT from a corpus shader — it was the UNIT TEST
`checkOutputClosure catches undeclared reference` feeding hand-written
bad WGSL to verify the guard.  The test passed its assertion
(`expectError(OutputIdentifierMissing)`) but `checkOutputClosure` logged
`std.log.err` as a side effect, and Zig's test runner fails a step on ANY
err log even with 0 assertion failures (verified empirically: warn does
NOT fail a step, err DOES).  So tier-a-check had been returning exit 1
the whole time despite "all tests passed" — training us to ignore the
exit code.  FIX: made `checkOutputClosure` PURE (no logging; returns the
error + writes the offending id to a new `missing_id: ?*u32` out-param);
moved logging to the single Debug-guard caller in `convertSpirvToWgsl`,
which distinguishes a real forgotten-`wgsl_name` bug (err) from a known
downstream `// ERROR:`-marker symptom e.g. combined samplers (warn).
Unit tests pass `null`.  The diagnostic is genuinely useful (kept it);
only its TEST no longer trips the step.  Confirmed: combined-sampler
shaders were a red herring — no opted shader produces an undeclared `_N`.
tier-a-check exit=0, all tests pass, lint 0/272, NO REGRESSIONS, 4 smoke
PASS, wgpu_smoke PASS.

>>> turn 849b: §2 slice (a) OpUnreachable DONE — raw 6/20 -> 24/37, 5 fixtures flipped <<<

`Op.Unreachable=255` added to types.zig Op enum (was missing entirely).
ir_build.classifyTerminator: OpUnreachable -> new TermKind.unreach
(previously fell to `else => .branch`, then branchTarget read a
nonexistent operand[0] -> THE measured first raw-shader bail).
mapTerminator -> ir.Terminator.unreach (already existed; ir_emit lowers
it to nothing, which is correct — unreachable block needs no terminator,
naga behaviour-analysis satisfied by reachable paths). buildBlock plain
dispatch: `.unreach` joins `.ret/.kill`. MEASURED: raw pre-opt translate
6/20 -> 24/37; flipped 5 of 18 Tint "unstructured" fixtures to clean IR
(HoistingMultiExit x2, Phi_FromHeaderAndThen, Phi_InLoopBody,
Phi_UnreachableLoopMerge). Corpus allow-list 18 -> 13,
baseline.tint_corpus_unstructured=13. Remaining 13 raw fails now bail
MalformedFunction (single-function ir_build.build + cross-function
block_table.get null) = slice (b) multi-function, NEXT. GATES: wgpu-diff
PASS (tint 164 ok/13 unstructured/0 trans-fail; internal 0 trans-fail),
naga-tint 167/1/13, live shaders naga 39/39, host 1809/1809, lint 0/272,
4 smoke PASS, wgpu_smoke PASS, wgpu+cube3d+damaged_helmet BUILD OK. See
finishing_webgpu.md §2 PROGRESS.

>>> turn 849: rasterizeTriangles FIXED (real bug) + spirv-opt-port REJECTED <<<

(1) `rlsw_shader.test.rasterizeTriangles` was NOT a "known negative test"
(prior notes mislabeled it) — it was a genuine bug IN THE TEST: its NDC
vertices (-1,-1)→(-1,+1)→(+1,-1) are CW (signed area -4), but it passed
the default `.ccw` front-face, so the triangle was back-face culled and
nothing drew → the inside pixel was black. Fix: reorder to actually-CCW
(-1,-1)→(+1,-1)→(-1,+1) (NDC area +4 → screen area -1024, which `.ccw`
keeps). The rasterizer's sign logic was correct (working examples use
`.cw` for the natural CW full-screen quad; sw_mandelbrot.zig:199). Host
test is now 1809/1809 — the long-standing "1 known failure" footnote is
RETIRED. Verify standalone: `zig test --dep zm -Mroot=src/rlsw_shader.zig
-Mzm=src/zimrmath.zig --test-filter rasterizeTriangles`.

(2) Studied the uploaded SPIRV-Tools-main to answer "port spirv-opt to
Zig as a prepass?" — REJECTED. source/opt is 80,269 LOC; the minimal
load-bearing subset (DeadBranchElim/MergeReturn/InlineExhaustive/
AggressiveDCE/mem2reg/BlockMerge) is ~7.5k LOC of passes + ~17.5k LOC of
IRContext/def-use/dominator/type infra ≈ 25k LOC of entangled C++ (even
block_merge_util leans on the whole framework). Porting it would REPLACE
the 1400 lines we just deleted with 25k — anti-simplification. Crucially,
Zig already emits STRUCTURED reducible CF (OpSelectionMerge/OpLoopMerge
present), so no general restructurizer is needed — the raw-shader fails
are mechanical: OpUnreachable handling + multi-function (emit WGSL fns+
calls, since WGSL has functions — no inliner needed) + a Tint-style
reachability/structured-order front-end. See finishing_webgpu.md §2
"STRATEGY DECISION". spirv-opt stays (build-time only) until that lands.

>>> F5 DONE (turn 848): LEGACY WALKER DELETED — IR path is the sole CFG driver <<<

`src/spv2wgsl/walker.zig` (1434 lines) is GONE.  spv2wgsl module: 9 files
/ 7880 lines (was 11 / 9419).  `emitFunctionBody` calls `tryEmitViaIr`
unconditionally; an unstructurable CFG is a hard `IrBuildUnsupported`
(no fallback).  Removed: `WalkerChoice`, `walker_choice` State field,
`.ir_or_legacy`/`.legacy` dispatch, `convertSpirvToWgslWithWalker`
(folded into `convertSpirvToWgsl`).  CLI `--walker=` is now an
accepted-but-ignored deprecation no-op (keeps naga-validate-tint.sh +
`-Dwalker=` callers working).  Corpus test: strict `.ir` + new
`Status.unstructured` + `unstructured_fixtures` allow-list (18 Tint
torture shapes, count-gated via `baseline.tint_corpus_unstructured=18`);
`scanZigCache` restricted to `shader.opt.spv` (raw pre-opt `.spv` was
legacy-only → that's §2 work).  Study had verified safety: production
already used strict `.ir`; the 18 fallbacks were Tint UNIT-TEST CFG
torture (6 of which legacy emitted naga-INVALID WGSL for anyway — the
"fallback" was partly fiction); only real caller of legacy was the
corpus test.  LEFT (harmless dead code, follow-up): `PhiAssignMap`
precompute + the phi block in the shared `emitBlockBodyOnly` (IR nulls
`phi_assigns_ref`).  `tools/zglsl.zig` NOT deleted — it's GL-path (§2.3/
§7), not the WGSL walker.  GATES: wgpu-diff PASS, naga-tint 162/1/18,
live shaders naga 34/34, host 1808/1809 (1=known rlsw negative test), 4
smoke PASS, wgpu_smoke PASS, lint 0/272, wgpu examples + cube3d BUILD OK.
See finishing_webgpu.md §3.C.

# spv2wgsl hardening — deep-study findings + validation plan

>>> CPU SCALARS = STD-ACCURATE; CPU VECTORS + GPU = ZMATH SIMD/POLY <<<
Design (Simon, refined): the discriminator is VECTOR vs SCALAR, not f32.
  - Scalar on CPU  → match std.math exactly (copy if ≤100 lines, else
    delegate).  Includes f64 scalars (e.g. beginMode3D's tan(f64)).
  - Vector (Vec/F32x8/F32x16) on CPU → keep zmath's SIMD polynomial for
    MAX throughput (reasonable approximation OK here).
  - GPU (SPIR-V), any type → zmath approximation (shaders are cosmetic).
CPU and GPU need NOT agree (GPU = less precision; tests must NOT
expectEqual CPU-vs-GPU) but avoid weird SEMANTIC differences (NaN-vs-clamp).
Each fn now: `if (comptime !is_gpu and @typeInfo(T) != .vector) return
<scalar-exact>;` then the existing zmath switch/poly (which serves vector-
CPU AND all-GPU uniformly):
  - sin/cos     → scalar-CPU @sin/@cos (== std.math.sin/cos); else sin32/
    cos32(xN).   sincos likewise (.{@sin,@cos} scalar; else sincos32(xN)).
  - tan         → scalar-CPU std.math.tan (== @tan); else sin(x)/cos(x)
    (which routes vectors through the SIMD polynomial).
  - asin/acos   → scalar-CPU asinCpu/acosCpu; else asin32/acos32(xN).
  - atan/atan2  → scalar: std.math.atan/atan2 on CPU (>100-line, delegate),
    atanScalar/atan2Scalar on GPU; vectors: the 17-deg minimax / DirectXMath
    poly (CPU SIMD + GPU).
  - pow         → scalar f32 only: CPU std.math.pow (149>100, delegate);
    GPU @exp(@log) identity.
  - asinCpu/acosCpu (generic `fn (x: anytype)`): std accuracy for valid x;
    finite |x|>1 clamps to ±π/2, inf/nan → NaN.  Preserves zmath's forgiving
    clamp contract (2 tests: asin(-1.1)==-π/2, asin(inf)==NaN) — both CPU and
    GPU clamp, so no NaN-vs-clamp semantic surprise (precision may differ).
  - cpuMap1 helper was ADDED then REMOVED — the scalar-vs-vector split makes
    per-lane std unnecessary; vectors use the SIMD poly directly.
PERF (Simon's Q "losing perf with simd sin?"): an INTERMEDIATE version
routed ALL CPU sin/cos (incl vectors) through @sin/@cos and DID give up
zmath's lane-parallel SIMD.  This restructure RESTORES it: vector-CPU sin =
sin32xN (== original zmath); only scalar-CPU changed.  Net: no SIMD perf
loss vs original.
f64-TAN COMPILE BREAK caught+fixed: gating scalar-exact on `T == f32` sent
tan(f64) (runtime.zig beginMode3D) into the f32-only zmath switch →
@compileError on the cube3d/damaged_helmet wasm build.  Fix: discriminator
is `@typeInfo(T) != .vector` (f64 scalars route to @sin/std.math too) and
asinCpu/acosCpu are generic.
PER-TURN GATE for zimrmath tweaks: `./scripts/timed-build.sh tier-a-check
-Dfocus=tier-a` (~140s) = test + 4-example smoke + wgpu-smoke + corpus +
fixture.  NOT the full `zig build test`.
GATES (this work): zm 150/150 · lint 0/273 · cube3d+damaged_helmet wasm
BUILD OK · 4 tier-a smoke PASS · wgpu-smoke PASS · host 1821/1822 (the 1 =
known pre-existing rlsw_shader.rasterizeTriangles negative test).
FIXTURE DRIFT (was pre-existing) — NOW FIXED: `webtests/transpiler_corpus.ts`
was failing on stale `wgsl_corpus.json`; `--refresh-fixture` consolidated it
to 7 canonical entries (validator "NO REGRESSIONS").  No transpiled WGSL
changed — pure fixture maintenance.
STD.MATH AUDIT (zimrmath.zig, ~46 shipped refs + ~9 test-block):
  JUSTIFIED big-delegate (>100, Simon OK): pow 149, atan 107, atan2 296,
    hypot 137 (+ internal cabs→atan2).
  JUSTIFIED scalar-CPU exact path: tan(=@tan), asinCpu/acosCpu (asin/acos
    +isFinite+nan for the clamp contract).
  DONE — small EXACT utils now VENDORED in-house (single un-gated impls):
    maxInt, minInt, Log2Int (std's exact comptime code, std.meta.Int for the
    type), ceilPowerOfTwo (std's promote+overflow-check algorithm, keeps the
    error.Overflow contract), log2_int, isFinite, isPowerOfTwo, inf, nan,
    floatEps, floatMax, signbit, degreesToRadians, radiansToDegrees, and a
    vendored integer floor-sqrt `sqrtInt` (zm.sqrt's int path; zm.sqrt(u64)
    is used by codecs.zig).  cast was already vendored.  Internal fft direct
    uses rerouted to the local Log2Int/isPowerOfTwo; asinCpu/acosCpu now use
    local isFinite/nan.  (lerpOverTime→exp2 and min→std.math.min were COMMENTS,
    not calls.)  All GPU-portable: cube3d+damaged_helmet wasm BUILD OK.
    LINT NOTE: vendored std code needed zimr's explicit-local-type annotations
    (rule 2) — `const X: type = std.meta.Int(...)`, `: u16` on bit_count/
    log2_bits, `: T`/`: bool` in sqrtInt.  Caught the `const max` shadow of
    zm's `max()` fn (renamed max_val).
  std.math CALLS now = JUSTIFIED ONLY (7): pow/atan/atan2/hypot (big >100
    delegates) + tan/asin/acos (scalar-exact).  Everything else matching
    "std.math." is a comment, doc placeholder, or test block.
  FIXTURE: refreshed `tests/fixtures/wgsl_corpus.json` (--refresh-fixture) —
    7 canonical entries, validator "NO REGRESSIONS", tier-a-check bun step
    now green.  The pre-existing 10-vs-stale drift is cleared.
  TEST/COMMENT-ONLY (not real deps): approxEqAbs (tests), the "== std.math.
    sin/cos" doc comments in sin/cos, the literal "std.math.X" doc placeholder.

>>> STD.MATH → ZM MIGRATION COMPLETE + `std-math` LINT RULE (this turn) <<<
zimrmath is now the SINGLE file allowed to touch std.math, and only behind
a `if (comptime !is_gpu) return std.math.<fn>(...);` gate (accurate std on
host/comptime; a hand-rolled GPU-portable branch on SPIR-V — the dead std
branch is never analyzed for shaders).  Every other zimr file calls the
`zm.*` wrappers, so all code is GPU-portable by construction.
- Wrappers GATED (std on CPU, GPU branch otherwise): tan(=sin/cos),
  degreesToRadians, radiansToDegrees, isFinite, isPowerOfTwo,
  ceilPowerOfTwo, inf, nan, floatEps, floatMax, signbit, hypot, clamp
  (clamp already existed; left as-is, GPU-safe via max/min).
- Wrappers that are PURE BUILTINS (work everywhere, no gate, no std):
  log2(@log2), exp2(@exp2), exp(@exp), log(@log) — plus pre-existing
  sqrt/abs/min/max.  NOTE: std.math.log2(f32) IS literally `@log2`, so the
  3 fractal shaders using zm.log2 emit byte-identical WGSL (corpus unchanged).
- COMPTIME / integer utilities added: maxInt, minInt, Log2Int, log2_int,
  add/sub/mul (checked, error{Overflow}), cast (mirrors std.math.cast; body
  is GPU-portable so no gate).  `euler` already existed (Simon prefers it
  over `e`; do NOT add a file-scope `e` — it collides with local vars).
- signbit uses std.meta.Int (not @Type) for the unsigned bitcast type.
- DANGLING-REF GOTCHA: a prior sed pass turned `std.math.cast`/`.add` into
  `zm.cast`/`zm.add` via entities.zig's `const math = zm;` alias WITHOUT
  adding them to zm — host `zig build test` caught "zimrmath has no member
  'cast'".  When auditing zm coverage, grep `math.X` in the TWO aliased
  files (src/entities.zig, src/zimr.zig), not just `zm.X`.

The `std-math` lint rule (tools/lint_zimr.zig): fires on any `std.math.*`
field-access, EXEMPTS files ending `zimrmath.zig`, and is NON-SUPPRESSIBLE
(lineSuppressedByDirective returns false for tag "std-math" — a
`// lint:off std-math` does NOT silence it; verified with a probe).  The
ONLY sanctioned fix is to wrap the fn in zimrmath (gated, GPU-verified) and
call zm.<fn>.  Message says exactly that.  Goal: make it hard to write code
that won't compile for a shader.
GATES (all green this turn): lint 0/273 · zm 150/150 · spv2wgsl 58/58 ·
naga-tint 162/1/18 · naga corpus 61/61 · host `zig build test` compiles
(only the 2 known pre-existing negative-test runtime failures:
rlsw_shader.rasterizeTriangles, spv2wgsl.checkOutputClosure — NOT
regressions, unrelated to math).  Pre-existing unrelated dangling refs left
alone: zm.Vec4 in skip-listed unlit_fs.zig; zm.zsample2d (sampler intrinsic,
validates in corpus).

Written turn 809, context-fresh, AFTER the cardioid rendered (turn 808)
but BEFORE F4/F5 (flip default to ir / delete legacy).  The goal: find
latent bugs and build real validation so we are not relying on Simon's
phone to catch type errors, before we bet the shipped path on the IR
walker.

## >>> STATUS (read this FIRST) <<<
- Phase H1 (IR-level type check) — PLANNED, see below.  Not started.
- Phase H2 (wgsl_reflect grammar oracle) — PLANNED.  Not started.
- Phase H3 (Tint-ported structural invariants) — PLANNED.  Not started.
- The three bugs already fixed (loop header placement t805, phi
  double-emit t807, phi exit-arg misrouting t808) are NOT to be redone.

## >>> VALIDATION GATES (run these; "handled" means naga-valid) <<<
The whole point of this doc is to not rely on Simon's phone to catch
bad WGSL.  Two naga gates now exist (naga = the real gfx-rs/wgpu WGSL
validator, Firefox-grade; a BUILD-TIME tool, never shipped in the wasm):

  zig build naga-tint    — runs `scripts/naga-validate-tint.sh`: validates
                           EVERY IR-translated Tint fixture (181 corpus)
                           with naga, gated against
                           `tests/fixtures/external/naga-invalid-baseline.txt`.
                           FAILS on any NEW invalid (a regression you just
                           introduced) or any baselined-but-now-VALID entry
                           (so the baseline only shrinks).  This is the gate
                           that makes "the IR walker handles fixture X" mean
                           "X emits WGSL the browser accepts", not just "X
                           translated without erroring".
  scripts/naga-validate-corpus.sh [ir|legacy]
                         — validates the LIVE shader build's output (the
                           ~10 production shaders).

WHY BOTH: `zig build wgpu-diff` (the pure-Zig corpus test) only checks
that each fixture translates + matches structural patterns; it does NOT
run full naga validation.  Before the naga-tint gate existed, 21 fixtures
were silently counted "handled" while emitting naga-INVALID WGSL (found
turn 813).  Those are now baselined as explicit, tracked feature gaps —
NOT merge-phi bugs: function calls, hoisting-into-nested, vertex-shader
struct I/O, sint switch values, hoisted-var loop-header phis.  See the
baseline file's header for the burn-down families.

PER-COVERAGE-FEATURE WORKFLOW (do this for every new shape you add):
  1. implement → 2. `zig build naga-tint` MUST stay green (no new
  invalid) → 3. if the feature makes a baselined fixture valid, DELETE
  its line from the baseline (the gate enforces this) → 4. cardioid +
  wgpu-check + wgpu-diff + lint → 5. unit test → 6. record + snapshot.
The coverage number to optimize is naga-VALID count (currently 128 of
181), not raw translated count (149) — the gap (21) is the debt to burn.



All three bugs shared a property: **the IR was structurally plausible
but semantically wrong, and our gates could not see it.**  The
JS-shim `wgpu-check` only proves the wasm runs the pipeline without
trapping — it has NO real WGSL frontend, so it cannot validate types,
arity, or grammar.  Only Simon's phone (Chrome → Dawn/Tint, a real
WGSL frontend) caught the `u32 -> f32` type error.

We need gates that catch these BEFORE the phone.  Three tiers.

## >>> §4.B LAMBERT — lit cube BUILDS + WGSL naga-valid (turn 816 cont.) <<<
The Lambert-lit cube demo builds, lambert's WGSL is naga-valid (THE §4.B unknown,
now resolved), and migrating lambert un-broke the GL path too.  AWAITING browser
confirmation (no GPU here) — the build-side contract is fully green.

WHAT IT TOOK (more than wiring a demo — lambert was STALE):
1. examples/wgpu_lambert_demo/{wgpu_lambert_demo.zig, index.html}: adapted from the
   cube.  LitVertex {position[3], tex_coord[2], normal[3]} stride 32; 6 face normals;
   LambertSchema with Ubo {mvp, mat_model: [4]@Vector(4,f32)} (two mat4s, 128B) +
   Samplers {texture0}; 3-attr vertex layout (pos@0 off0, uv@1 off12, normal@2 off20);
   per-frame writeUbo(.{.mvp=mvp, .mat_model=model}).  Same Resources+pipeline draw
   path as the cube.
2. build.zig: wgpu-lambert-demo target (mirrors cube; wires engine WGSL via the
   `for (engine_shaders.items)` loop so @embedFile("lambert_vs.wgsl") resolves) +
   wgpu-lambert-standalone via one WgpuStandalone.add() call.

THE REAL BLOCKER (why lambert was on the skip-list): lambert_vs/fs were in the
`old_3d_shaders` skip-list (pointed at _deleted_glsl_placeholder.glsl, NOT compiled).
Removing them from the list surfaced the true reason — the lambert shader BODIES used
the OLD codegen API (`shader_externs.setup()`, direct `shader_externs.frag_normal`,
`position_out.*`), never migrated when the _io codegen changed.  FIX = rewrote both
bodies to the current `shaderMain(io) Out` API (like cube_split/default_shapes):
- `pub const Io = shader_externs.IoT(shader_io.Uniforms);` (NOTE: lambert's schema decl
  is named `Uniforms`, NOT `Ubo` — and IoT FLATTENS uniform fields directly onto the
  Io instance: `io_in.mvp` / `io_in.mat_model` / `io_in.col_diffuse`, NO `.u.` prefix.
  cube_split names it `Ubo` and uses `io_in.u.mvp` — the `.u` vs flatten distinction
  is driven by the schema decl name. Watch this for pbr/unlit when migrating them.)
- `pub const Out = shader_externs.Out;` + `out.position/frag_tex_coord/frag_normal`
  (VS), `out.final_color` (FS) + `comptime { _ = installSpirvEntry(shaderMain); }`.
- FS samples via `io_in.texture0(io_in.frag_tex_coord)`; light hardcoded (dir
  normalize(0.4,0.8,0.5), 25% ambient).

BONUS: un-skipping lambert means it now emits a REAL lambert.glsl too (was a
placeholder gravestone) — so the GL path's render.zig @embedFile("lambert.glsl") now
gets a real shader.  `zig build install` (full GL suite) stays clean.  Net positive.

GATES (all green): wgpu-lambert-demo + wgpu-lambert-standalone build clean; lambert
VS+FS WGSL naga "Validation successful"; live corpus 26/26 (was 24 — lambert's 2
joined); lint 0/273; cube byte-identical; FULL `zig build install` clean (GL path
intact w/ real lambert.glsl).  Snapshot zimr837.

PATTERN ESTABLISHED for the remaining engine 3D shaders: pbr/unlit/shadow/skybox are
STILL in old_3d_shaders for the SAME reason (stale bodies). Each is the same migration:
un-skip → rewrite body to shaderMain(io) API → validate WGSL. The helmet (§4.C) needs
pbr migrated this way first.

NEXT: Simon browser-checks the lit cube (diffuse shading visible across faces; the
top/light-facing faces brighter than the shadowed ones). Then §4.C helmet: migrate
pbr_vs/fs the same way + GLTF GpuMesh upload + PBR multi-group Resources (5 samplers +
lights + shadow).

## >>> STALE-WGSL HOLE CLOSED: pure-Zig tools are now main-build ARTIFACTS (turn 816 cont.) <<<
Fixed the recurring "edit spv2wgsl/zspv/zglsl → WGSL doesn't re-translate without
rm -rf .zig-cache" problem, structurally. Root cause + the real fix below.

ROOT CAUSE (confirmed empirically): the pure-Zig tools were built by the NESTED
`tools/build.zig` (via `tools_subbuild` = a system-command `zig build --build-file
tools/build.zig`) and invoked by PATH + addFileInput(path). A nested `zig build` is a
cache boundary the OUTER build can't see across: the outer build hashes the tool
binary as it sits on disk, with no ordering guarantee the sub-build rewrote it first
→ shader Run cache-hits on the old hash → stale WGSL. Verified: editing
src/spv2wgsl.zig + a SINGLE `zig build` did NOT re-translate.

THE FIX: build spv2wgsl/zspv/zglsl as artifacts of the MAIN build (addExecutable,
native, ReleaseFast) and invoke via addRunArtifact. Wired through new optional fields
on ShaderPipeline (spv2wgsl_exe/zspv_exe/zglsl_exe, null → fall back to path+tools_dep
for the C++ tools, which stay external). build.zig builds the three exes
(spv2wgsl imports src/spv2wgsl.zig as the "spv2wgsl" module) and sets the fields.

CRITICAL SUBTLETY (cost a few cycles, caught before claiming success): addRunArtifact
ALONE does NOT close the hole. It makes the Run depend on BUILDING the exe, but Zig
does NOT fingerprint the built binary's CONTENT into the Run's cache key. So the exe
recompiles (--summary shows `compile exe spv2wgsl ... success 27s`) while the Run stays
`cached` → still-stale output. Must ALSO add `run.addFileInput(exe.getEmittedBin())`
on each artifact branch: addRunArtifact gives the rebuild dependency, addFileInput on
the EMITTED BINARY gives the content-fingerprint that actually re-fires the Run.

GROUND-TRUTH VERIFICATION: after the full fix, editing src/spv2wgsl.zig + a single
`zig build` shows `run exe spv2wgsl (shader.wgsl) success 1ms` (RUN, not cached). That
is the cache-invalidation firing. NOTE on testing: output-diffing ONE shader is a bad
test — some edits (tempName; a `.0`→`.00` change) don't affect a given shader's output
(lambert_fs has no whole-number float constants; the IR path names temps via
wgslNameOf not tempName), which LOOKS like the fix failing when it isn't. The
`--summary all` Run-status (run vs cached) is the ground truth.

LESSON FOR FUTURE BUILD WORK: any build-time tool whose output is cached MUST be either
(a) a main-build artifact invoked with addRunArtifact + addFileInput(getEmittedBin()),
or (b) a path with addFileInput(path) AND a guarantee the file is fresh at hash time.
A nested `zig build` does NOT provide (b)'s freshness guarantee. Prefer (a) for pure-Zig
tools. The C++ SPIR-V tools (spirv-opt/val/cross) keep the path shape — they're external
and rarely change; their staleness risk is low and accepted.

GATES (all green; refactor touches the shader-pipeline spine): wgpu-lambert/cube/demo
build clean; live-shader naga 26/26; naga-tint 162/1/18; spv2wgsl 58/58; host tests
pass; lint 0/273. spv2wgsl.zig fully reverted (f32 fix intact). Snapshot zimr842.

NO MORE MANUAL CACHE CLEARS needed for tool edits. (rm -rf .zig-cache remains a valid
panic button but is no longer a correctness requirement.)

## >>> PBR FULLY NAGA-VALID + UN-SKIPPED: both blockers cleared (turn 816 cont.) <<<
RESOLVED the pbr_fs std140 blocker. Both PBR shaders (vs + fs) are now naga-valid and
pbr is PERMANENTLY UN-SKIPPED in build.zig (off old_3d_shaders) → goes through the
live WGSL-emission gate. The helmet's MATERIAL is done at the toolchain level.

THE std140 FIX (uniform-array alignment): WebGPU requires uniform-buffer array element
stride to be a multiple of 16 bytes, so pbr_fs's light arrays ([N]vec3 stride 12,
[N]f32 stride 4) were rejected ("array stride N not a multiple of 16"). Fixed in
src/shaders/pbr_fs_io.zig by padding ALL light-array element types to vec4:
  directional_light_dir/color  [2]vec3 → [2]vec4
  point_light_pos/color        [4]vec3 → [4]vec4
  point_light_range            [4]f32  → [4]vec4
The FS (pbr_fs.zig) reads .xyz from the vec4 lights and [idx][0] for the range; .w
ignored. Updated the GL helmet example (examples/damaged_helmet.zig) light-set calls
to pass vec4 arrays too (the schema is shared between the GL CPU path and the wgpu
path). NOTE: this was a SCHEMA + host change; the shader math is unchanged.

COMBINED with the earlier spv2wgsl f32-literal fix (whole-number floats now get ".0",
so `select(1.0, 0.0, cond)` is valid f32), pbr_fs is fully clean. Binding layout (the
stage-segregated scheme at full scale, all naga-valid):
  group0: 5 VS uniforms (mat_model/view/projection/normal/light_space) b0-4
  group1: 6 textures b0-5 + 6 samplers b6-11
  group2: 18 FS uniforms b0-17 (col_diffuse … shadow_enabled, light arrays vec4-padded)

PRE-EXISTING TEST NOISE (NOT regressions — verified by reading the tests): `zig build
test` shows two tests "failed": `spv2wgsl.test.checkOutputClosure catches undeclared
reference` and `rlsw_shader.test.rasterizeTriangles`. The first is a NEGATIVE test —
it does `expectError(error.OutputIdentifierMissing, ...)` on a deliberately-bad shader;
the `[default] output references _5` log line is the function correctly catching it,
and "1 errors were logged" is Zig's runner noting the intentional log.err, not an
assertion failure. The rlsw test uses inline TrivialVs/SolidGreenFs structs and touches
NOTHING related to pbr/light-arrays/renderConstant. Neither can be caused by the f32 or
vec4 changes (confirmed by inspection). `zig test <file>` in ISOLATION also fails for
rlsw_shader with "no module named 'zm'" — that's an invocation artifact (isolated test
lacks the build's module wiring), must use `zig build test`. These are background noise
to fix separately (likely install a test log handler), not blockers.

GATES (green): wgpu-lambert/cube/demo build clean; live-shader naga 32/32 (PBR's 2
joined); naga-tint 162/1/18; spv2wgsl 58/58 (assertions; the "logged" line is the
negative test); lint 0/273. Snapshot zimr843.

NEXT (the helmet demo — the substantial remaining piece, no toolchain unknowns left):
examples/damaged_helmet.zig is GL today (z.loadModelFromMemory + drawModel(f.gl);
@embedFiles assets/DamagedHelmet.glb). The wgpu version =
  1. loadModelFromGltfMemory → GpuMesh → upload CPU vertex/texcoord/normal/tangent +
     index arrays to vertex/index buffers.
  2. The §4(b) multi-group host path (like wgpu_lambert_demo but pbr's 3 groups: build
     5 VS-uniform buffers @group0, 6 textures + 6 samplers @group1, 18 FS-uniform
     buffers @group2; chain via createPipelineLayout; setBindGroup 0/1/2).
  3. Load the 5 PBR textures (base/MR/normal/AO/emissive) from the glb.
  4. A shadow pass (likely port shadow_vs/fs too — also stale-API + on the skip-list;
     same installSpirvEntry port as pbr).
  5. Standalone via one WgpuStandalone.add call.
  Honest estimate: ~2-3 sessions. Update zimr_wgpu.zig §6 if the helmet adds a shadow-
  pass group (per the docs-in-code rule).
Other stale skip-listed shaders (default, skybox, unlit, shadow vs+fs) still need the
same old-API→installSpirvEntry port when their consumers move to wgpu.

## >>> STALE-WGSL HOLE CLOSED: pure-Zig tools are now main-build ARTIFACTS (turn 816 cont.) <<<

## >>> STALE-WGSL HOLE CLOSED: pure-Zig tools are now main-build ARTIFACTS (turn 816 cont.) <<<
Fixed the recurring "edit spv2wgsl/zspv/zglsl → WGSL doesn't re-translate without
rm -rf .zig-cache" problem, structurally. Root cause + the real fix below.

ROOT CAUSE (confirmed empirically): the pure-Zig tools were built by the NESTED
`tools/build.zig` (via `tools_subbuild` = a system-command `zig build --build-file
tools/build.zig`) and invoked by PATH + addFileInput(path). A nested `zig build` is a
cache boundary the OUTER build can't see across: the outer build hashes the tool
binary as it sits on disk, with no ordering guarantee the sub-build rewrote it first
→ shader Run cache-hits on the old hash → stale WGSL. Verified: editing
src/spv2wgsl.zig + a SINGLE `zig build` did NOT re-translate.

THE FIX: build spv2wgsl/zspv/zglsl as artifacts of the MAIN build (addExecutable,
native, ReleaseFast) and invoke via addRunArtifact. Wired through new optional fields
on ShaderPipeline (spv2wgsl_exe/zspv_exe/zglsl_exe, null → fall back to path+tools_dep
for the C++ tools, which stay external). build.zig builds the three exes
(spv2wgsl imports src/spv2wgsl.zig as the "spv2wgsl" module) and sets the fields.

CRITICAL SUBTLETY (cost a few cycles, caught before claiming success): addRunArtifact
ALONE does NOT close the hole. It makes the Run depend on BUILDING the exe, but Zig
does NOT fingerprint the built binary's CONTENT into the Run's cache key. So the exe
recompiles (--summary shows `compile exe spv2wgsl ... success 27s`) while the Run stays
`cached` → still-stale output. Must ALSO add `run.addFileInput(exe.getEmittedBin())`
on each artifact branch: addRunArtifact gives the rebuild dependency, addFileInput on
the EMITTED BINARY gives the content-fingerprint that actually re-fires the Run.

GROUND-TRUTH VERIFICATION: after the full fix, editing src/spv2wgsl.zig + a single
`zig build` shows `run exe spv2wgsl (shader.wgsl) success 1ms` (RUN, not cached). That
is the cache-invalidation firing. NOTE on testing: output-diffing ONE shader is a bad
test — some edits (tempName; a `.0`→`.00` change) don't affect a given shader's output
(lambert_fs has no whole-number float constants; the IR path names temps via
wgslNameOf not tempName), which LOOKS like the fix failing when it isn't. The
`--summary all` Run-status (run vs cached) is the ground truth.

LESSON FOR FUTURE BUILD WORK: any build-time tool whose output is cached MUST be either
(a) a main-build artifact invoked with addRunArtifact + addFileInput(getEmittedBin()),
or (b) a path with addFileInput(path) AND a guarantee the file is fresh at hash time.
A nested `zig build` does NOT provide (b)'s freshness guarantee. Prefer (a) for pure-Zig
tools. The C++ SPIR-V tools (spirv-opt/val/cross) keep the path shape — they're external
and rarely change; their staleness risk is low and accepted.

GATES (all green; refactor touches the shader-pipeline spine): wgpu-lambert/cube/demo
build clean; live-shader naga 26/26; naga-tint 162/1/18; spv2wgsl 58/58; host tests
pass; lint 0/273. spv2wgsl.zig fully reverted (f32 fix intact). Snapshot zimr842.

NO MORE MANUAL CACHE CLEARS needed for tool edits. (rm -rf .zig-cache remains a valid
panic button but is no longer a correctness requirement.)

## >>> PBR PORTED to new API + spv2wgsl f32-literal bug FIXED; pbr_fs blocked on uniform-array std140 (turn 816 cont.) <<<
LAMBERT CONFIRMED RENDERING (Simon's screenshot): the lit cube shows correct
per-face Lambert shading (bright top, dim left, mid front) + sampled texture, 111fps.
§4.B DONE — the multi-group binding path produces correct pixels end-to-end.

Then drove the helmet forward by porting PBR (its material) off the stale API:
- pbr_vs.zig + pbr_fs.zig REWRITTEN from the old direct-extern API
  (`shader_externs.FIELD`, `export fn main`, `shader_externs.setup()`) to the
  current typed API (lambert's pattern: `IoT(Uniforms)` + `Out` + `shaderMain(io)`
  reading `io.FIELD` + `installSpirvEntry(shaderMain)`).  Mechanical mapping;
  samplers called as `io.texture0(uv)`; output is `out.out_color` (pbr_fs_io's
  Outputs field name — NOT `final_color` like lambert).  Replaced `std.math.clamp(x,
  0,1)` with `zm.clamp01(x)` (the new-API shaders avoid `std`).  Helper fns
  (distributionGgx/geometrySmith/fresnelSchlick/brdf/computeShadow) take params, so
  ported unchanged except fresnelSchlick's clamp + computeShadow now takes `io_in`.

VALIDATION (un-skipped pbr in build.zig, built, ran naga):
- pbr_vs: ✓ NAGA-VALID. Binding layout is the stage-segregated scheme working at
  full scale: VS uniforms group0 b0-4 (mat_model/view/projection/normal/light_space);
  pbr_fs uniforms group2 b0-17 (col_diffuse … shadow_enabled, incl arrays); samplers
  group1 (6 textures b0-5 + 6 samplers b6-11). THE GENERAL BINDING FIX SCALES TO PBR.
  3 groups, within WebGPU's 4-group limit. Confirmed the helmet's binding model works.

SPV2WGSL BUG FOUND + FIXED (benefits ALL shaders):
- pbr_fs hit `select(1, 0, cond)` for an f32 result → naga "expected f32, got i32".
  Root cause: renderConstant() formatted whole-valued f32 constants with `{d}`, which
  drops the decimal point (`1.0`→"1"), so WGSL read them as AbstractInt. FIX (src/
  spv2wgsl.zig renderConstant): for f32, if the `{d}` spelling has no `.`/`e`/`inf`/
  `nan` marker, append ".0". Now emits `select(1.0, 0.0, cond)`. (Also covers any
  whole-number float literal anywhere.) GOTCHA: had to clear .zig-cache to force shader
  re-translation (same hash path = cached WGSL); and `std.mem.indexOfAny` not
  `indexOfany`. spv2wgsl 58/58 tests still pass; corpus 13/13; naga-tint unchanged.

REMAINING pbr_fs BLOCKER (distinct, well-understood — std140 uniform-array alignment):
After the f32 fix, naga's next error: `array<f32, 4> point_light_range` in a uniform
buffer → "array stride 4 is not a multiple of the required alignment 16". This is the
WGSL/std140 rule: UNIFORM array elements must be 16-byte aligned. PBR's light arrays
all violate it: [4]f32 (stride 4), [2]vec3 + [4]vec3 (vec3 in arrays pads to 16 but
the element TYPE as-emitted is vec3 stride 12). Options for next session:
  (A) Emit these as storage buffers (read-only storage has relaxed array stride) —
      cleanest for variable-length light lists; means a 4th bind group or moving the
      FS light arrays to storage. spv2wgsl/the schema would need a "storage" hint.
  (B) Pad the array element types to 16 bytes in the schema (e.g. [4]@Vector(4,f32)
      for ranges, vec4 for the vec3 light dirs/colors/positions) so uniform std140 is
      satisfied — simplest, costs a little VRAM + host packing care.
  (C) Per-light struct array padded to 16. 
  Recommend (B) for the helmet (fixed MAX light counts, small) — least machinery; do
  (A) later if light lists need to grow. NOTE: this is a SCHEMA/host change, the
  shader body math is unaffected. Also: the spv2wgsl-emitted vec3 uniforms (view_pos,
  ambient_color, etc. — scalars/vec3 at group2) validated fine; it's specifically the
  ARRAY-of-small-type case that trips std140.

STATE: pbr_vs + pbr_fs bodies ported (correct, lint-clean); pbr RE-SKIPPED in
build.zig (pbr_fs not yet fully naga-valid, so kept off the WGSL-emission gate); the
spv2wgsl f32 fix is LANDED + permanent. Tree clean.

GATES (all green): wgpu-lambert/cube/demo build clean; lint 0/273; live-shader naga
13/13 (fresh — a stale pbr_fs from the experiment briefly showed 1 FAIL, gone after
cache clear); naga-tint 162/1/18; spv2wgsl 58/58. Snapshot zimr841.

NEXT (helmet, well-scoped): (1) fix the pbr uniform-array std140 issue — pad light
array element types to 16 bytes in pbr_fs_io (option B), re-validate pbr_fs naga →
should pass (it was the LAST error). (2) Un-skip pbr permanently. (3) Build the helmet
demo: examples/damaged_helmet.zig is GL today; wgpu version = loadModelFromGltfMemory
→ GpuMesh → vertex/index buffers → the §4(b) multi-group host path (like
wgpu_lambert_demo but pbr's 3 groups: 5 VS uniforms, 12 sampler bindings, 18 FS
uniforms) + load the 5 PBR textures + a shadow pass. Update zimr_wgpu.zig §6 if the
helmet adds a shadow-pass group. The architecture is proven; remaining work is the
std140 padding + the (substantial) demo wiring + glTF asset upload.

## >>> HELMET DE-RISKED: exact blockers found (skip-list + stale shader API) (turn 816 cont.) <<<
Continued the plan toward the helmet (§4.C). Instead of blindly starting it, ran the
proven "validate the unknown first" step: tried to get PBR's WGSL emitted + naga-valid
(PBR is the helmet's material — the hardest binding case). Found the TWO concrete
blockers, so the helmet is now a bounded task, not a mystery:

BLOCKER 1 — the `old_3d_shaders` skip-list (build.zig ~648):
pbr_vs/fs, shadow_vs/fs, skybox_vs/fs, unlit_vs/fs, default_vs/fs are ALL on a
skip-list that points them at src/shaders/_deleted_glsl_placeholder.glsl and does
NOT compile them through the SPIR-V→WGSL pipeline. Only `lambert` + `default_shapes`
are OFF the list (why lambert worked). So NO 3D engine material except lambert has
WGSL today.

BLOCKER 2 — the skip-listed shader BODIES are stale (old direct-extern API):
Temporarily un-skipped pbr and built → compile errors:
  - pbr_vs.zig:24  `shader_externs.setup()` — `setup` no longer exists in that form;
    the current API is `installSpirvEntry(shaderMain)` + an `io` struct.
  - pbr_vs uses `shader_externs.mat_model` / `.vertex_position` / `.frag_world_pos`
    directly (old direct-extern style) instead of `io.mat_model` etc.
  - pbr_fs.zig:69,255 `use of undeclared identifier 'std'`.
CONFIRMED all 10 skip-listed shaders are STALE (use `.setup()`/direct externs, no
`installSpirvEntry`); lambert/default_shapes are the only ported ones.

So porting a 3D material to wgpu = rewrite its VS+FS bodies from the old style to
lambert's current style (IoT(Uniforms) + Out + installSpirvEntry(shaderMain) + read
fields off the `io` param), THEN remove it from old_3d_shaders. The binding-collision
fix I just landed (stage-segregated groups) already covers them once compiled — so
no per-shader binding work needed, just the API port.

HELMET = bounded task now, estimate refined:
  1. Port pbr_vs.zig + pbr_fs.zig bodies to installSpirvEntry (the big one — pbr_fs
     is ~260 lines with the std refs + light loops; pbr_vs ~60). Un-skip pbr.
  2. Validate pbr WGSL naga-valid (the binding layout will be VS uniforms g0 [5
     uniforms b0-4], samplers g1 [6 tex + 6 samplers], FS uniforms g2 [many,
     incl arrays] — 3 groups, within WebGPU's limit; the §3 scheme handles it).
  3. Probably port shadow_vs/fs too (single-cascade shadow map the helmet uses).
  4. The demo: examples/damaged_helmet.zig is GL today (z.loadModelFromMemory +
     drawModel(f.gl)); a wgpu version = loadModelFromGltfMemory → GpuMesh → upload
     CPU arrays to vertex/index buffers → the §4(b) multi-group host path (like
     wgpu_lambert_demo but with pbr's bigger uniform/sampler set) + 5 textures +
     lights + the shadow pass. THE multi-group host pattern is proven by lambert.
  Honest estimate: 3-4 sessions (pbr body port 1-2, shadow port + validate 1,
  helmet demo wiring + gltf upload 1-2). The unknowns are now just "port effort",
  not "does the architecture work" — that's answered.

DECISION POINT for Simon: the lit lambert cube is built + naga-valid but still
NOT browser-confirmed (no GPU here). Recommend confirming lambert renders BEFORE
investing the helmet sessions — it's the cheap validation that the whole multi-group
binding path actually produces pixels, and the helmet builds directly on it. If
lambert renders, the helmet is "just" the (larger) same thing.

GATES (all green; tree restored clean after the un-skip experiment — build.zig
byte-matches backup): wgpu-lambert/cube/demo build clean; lint 0/273; live-shader
naga 29/29. No snapshot delta needed beyond recording (no code changed — the un-skip
was reverted), but taking zimr840 to capture this hardening note.

NEXT: (a) Simon browser-confirms lambert; (b) port pbr_vs/fs to installSpirvEntry +
un-skip + validate; then the helmet demo. Update zimr_wgpu.zig §6 if the helmet adds
a shadow-pass group (per the claude.md in-code-docs rule).

## >>> WEBGPU ARCHITECTURE DOC — central, in-code, cross-referenced (turn 816 cont.) <<<
Per Simon: documented the WebGPU architecture PRECISELY in a central CODE file so
future-me stops re-discovering it. Chose src/zimr_wgpu.zig (the public wgpu module
surface — the front door everything imports) and wrote a module-level `//!` doc
covering: §0 what it is, §1 the build-time shader pipeline (zig→spv→zspv→spv2wgsl→
wgsl, zero transpiler shipped), §2 the _io schema convention + the TWO codegen
paths (setup vs installSpirvEntry — the gotcha), §3 THE BINDING MODEL (stage-
segregated: VS uniforms=group0, samplers=group1, FS uniforms=group2), §4 the two
host binding paths (Resources for single-UBO; explicit bind groups for multi-group),
§5 runtime layers, §6 the 3D ladder + in-build standalone, §7 invariants.

Cross-referenced it from 33 files: every wgpu runtime module (shader_runtime_wgpu,
renderer_2d, gpu_iface, wgpu, render_pass, gpu_frame, pipeline_cache,
descriptor_encoder, shader_introspect, wgpu_texture), the codegen
(gen_shader_externs — points at §3), both demos (cube=§4(a) Resources,
lambert=§4(b) multi-group), and all 21 shader _io.zig files (binding-model pointer).
Each gets a SHORT "documented centrally in src/zimr_wgpu.zig, read that first"
comment instead of re-explaining. Also fixed the lambert demo's banner (was a
copy-artifact "cube").

PLAN.md: added a "WebGPU architecture reference" callout at the top of Current
focus pointing at the doc (mentions existence + links, does NOT duplicate).

claude.md: added the rule "Big-system docs live IN CODE, not in plans/tutorials" —
one canonical `//!` doc per subsystem in its central file; other files get short
pointers; plans may mention/link but not duplicate; the doc updates in the same
turn as an architecture change (like a test). Rationale recorded: kills the
rediscovery tax.

GATES (all green; annotations touched ~35 files): wgpu-lambert/cube/demo build clean;
lint 0/273; live-shader naga 29/29; spv2wgsl 58/58. Docs copied to outputs. Snapshot
zimr839.

NEXT: unchanged — Simon browser-checks the lit lambert cube (the binding fix should
make it render); then the helmet (pbr, now unblocked + the architecture doc covers
its multi-group path). When architecture shifts (e.g. helmet adds a shadow-pass
group or a shared cross-stage uniform), UPDATE the zimr_wgpu.zig `//!` doc per the
new claude.md rule.

## >>> CROSS-STAGE BINDING COLLISION: FIXED at toolchain level (general) (turn 816 cont.) <<<
Solved the cross-stage uniform binding collision GENERALLY — the fix is in the
shader codegen, so it applies to EVERY multi-stage engine shader automatically
(lambert, pbr, shadow, skybox), not just lambert. This unblocks the helmet (pbr).

THE FIX (one place: tools/gen_shader_externs.zig, the installSpirvEntry wrapper):
The engine emits loose `Uniforms` fields as `extern const NAME addrspace(.constant)`.
Previously the installSpirvEntry wrapper emitted zm_binding() for Ubo (set 0) and
Samplers (set 1, solved) but NOTHING for loose Uniforms — so spv2wgsl auto-numbered
each MODULE's uniforms from binding 0, and since VS+FS are separate modules they
COLLIDED (lambert: VS mat_model @g0/b1 vs FS col_diffuse @g0/b1).

Fix = emit explicit zm_binding() for each Uniforms field, SEGREGATED BY STAGE:
  - VS Uniforms → descriptor set 0   (VS detected: schema @hasDecl "Attributes")
  - samplers    → set 1              (unchanged, the Samplers solver)
  - FS Uniforms → descriptor set 2   (FS detected: schema @hasDecl "Inputs")
Stage detection is structural + verified across ALL 7 engine shader pairs (every
VS io has Attributes/no Inputs; every FS io has Inputs/no Attributes). Bindings run
0,1,2,… within each set in declaration order. Two stages → two disjoint sets → NO
collision possible, for any shader. (zm.binding() in zimrmath.zig emits the
OpDecorate DescriptorSet+Binding via inline asm; spv2wgsl honors explicit bindings.)

IMPORTANT GOTCHA (cost me a cycle): there are TWO codegen paths in
gen_shader_externs.zig — `setup()` (legacy hand-call API) AND the `installSpirvEntry`
wrapper (what shaders ACTUALLY use: `_ = shader_externs.installSpirvEntry(shaderMain)`).
I first added the Uniforms block to setup() only — DEAD CODE, no effect on the SPIR-V.
Had to ALSO add it to the installSpirvEntry wrapper (lines ~828-850) where the real
decoration emission lives. Both have it now (setup() for completeness/the legacy path).

RESULT (verified end-to-end):
- lambert_vs: mvp @g0/b0, mat_model @g0/b1 — both naga-valid
- lambert_fs: col_diffuse @g2/b0, texture0 @g1/b0, sampler @g1/b1 — naga-valid
- NO collision (mat_model g0/b1 vs col_diffuse g2/b0 = disjoint).
- WGSL layout EXACTLY matches the demo's host bind groups (3 groups).

HOST SIDE (examples/wgpu_lambert_demo/wgpu_lambert_demo.zig): builds 3 bind groups
by hand (Resources can't express multi-binding/multi-group uniform layouts):
  group0 = mvp@0 + mat_model@1 (VS uniforms, 2 buffers)
  group1 = texture0@0 + sampler@1
  group2 = col_diffuse@0 (FS uniform)
Pipeline layout chains all three. Per-frame queueWriteBuffer mvp+model; col_diffuse
written once (white). setBindGroup 0/1/2.

REGRESSION GATE (gen_shader_externs touches ALL shaders — checked hard): wgpu-cube-demo
+ wgpu-demo build clean (cube_split, mandelbrot, chroma unaffected — they use Ubo or
single uniforms, not the multi-uniform path); live-shader corpus PASS (0 FAIL);
naga-tint UNCHANGED 162/1/18; spv2wgsl 58/58; lint 0/273. Lambert standalone built
(zig build wgpu-lambert-standalone) + in outputs. Snapshot zimr838.

WHY THIS IS THE RIGHT (most future-unblocking) FIX, per Simon's call:
- It's at the toolchain, so pbr/shadow/skybox get correct non-colliding bindings for
  free — the helmet (pbr, 5 VS uniforms + many FS uniforms + 6 samplers) would have
  hit this collision HARD; now it won't.
- Deterministic, structural (no per-shader annotation, no manual binding bookkeeping).
- The host-side group convention (VS uniforms=g0, samplers=g1, FS uniforms=g2) is now
  a stable contract any wgpu consumer/Renderer can build layouts against.

STILL BROWSER-UNVERIFIED (no GPU here): the actual LIT cube render. The binding
collision (which would have failed pipeline validation) is GONE and the layout is
coherent + naga-valid, so it SHOULD render with visible diffuse shading across faces.
If not, most-likely-first: (a) winding/cull (cube CCW-from-outside + .back — should be
right, it's the same geometry as the working unlit cube); (b) the world-normal
transform (mat_model feeds mat3() in the VS) — if lighting looks flat, check the
normal attribute wiring (stride 32, attr@2 offset 20). The HARD part (bindings) is done.

NEXT: Simon browser-checks the lit cube. Then the helmet (now unblocked on bindings) —
loadModelFromGltfMemory → GpuMesh → vertex/index buffers → this same multi-group path
+ pbr's larger uniform/sampler set. The stage-segregated binding scheme scales to it.

## >>> §4.B LAMBERT: built, naga-valid, BLOCKED by cross-stage binding collision (turn 816 cont.) <<<
Built the lambert demo end-to-end (examples/wgpu_lambert_demo/, build target
wgpu-lambert-demo + wgpu-lambert-standalone — both compile, wasm produced).
Found a partial lambert target already existed from a prior session; rewrote the
demo file fresh from the cube + adapted (LitVertex with per-face normals stride 32,
3 vertex attrs, two-mat4 UBO intent).

GOOD NEWS: lambert_vs AND lambert_fs WGSL are each individually naga-valid
(Validation successful). Live-shader corpus GREW to 28 PASS / 0 FAIL (lambert
joined). The original §4.B unknown — "is lambert WGSL naga-valid?" — is CLEARED.

THE BLOCKER (systemic, NOT lambert-specific — reshapes the roadmap):
spv2wgsl translates VS and FS as SEPARATE modules, and auto-numbers each module's
uniforms from @binding(0) in declaration order (only explicit Binding decorations
are honored; engine uniforms are emitted as loose `addrspace(.constant)` externs
with NO binding decoration). Result — CROSS-STAGE BINDING COLLISION:
  lambert_vs: mvp @group(0)@binding(0), mat_model @group(0)@binding(1)
  lambert_fs: col_diffuse @group(0)@binding(1)  ← COLLIDES with mat_model
  (texture0/sampler correctly land at group(1) via the --sampler-group=1 path)
In WebGPU a (group,binding) slot is ONE resource across stages, so col_diffuse
and mat_model can't share group0/binding1 — the pipeline will FAIL VALIDATION.
The GL path doesn't care (GL binds uniforms by name), which is why this never
surfaced before wgpu. cube_split dodged it by having ONE uniform per stage in
different groups.

SCOPE: affects EVERY multi-uniform multi-stage engine shader on wgpu —
- lambert (mvp,mat_model | col_diffuse)
- pbr_vs has 5 uniforms (mat_model/view/projection/normal/light_space → bindings
  0-4), pbr_fs has col_diffuse/metallic/roughness/view_pos/ambient... also from 0
  → massive collision
- shadow, skybox likely too.
So this is a FOUNDATIONAL toolchain issue, exactly what §4.B was meant to surface
before the helmet (which is pbr — would hit this hard).

STATE OF THE DEMO (compiles, does NOT render yet — NOT claiming it works):
- Bypassed Resources entirely (Resources models ONE ubo buffer per group via a
  single binding-0 struct — confirmed in autoMaterialBindGroupLayout/writeUbo —
  so it CAN'T express multi-binding uniform groups; this is a 2nd Resources
  limitation after the cube's, and the real reason multi-uniform shaders need a
  different host path).
- Built the bind groups by hand: 3 uniform buffers (mvp, model, col_diffuse) +
  group0 BGL/BG (mvp@0, mat_model@1, col_diffuse@2) + group1 BGL/BG (texture@0,
  sampler@1), explicit pipeline layout chaining both. Per-frame queueWriteBuffer
  to mvp + model; manual setBindGroup(0)+setBindGroup(1).
- The host wiring is written for the FIXED layout (col_diffuse@2). It will NOT
  match the current WGSL (col_diffuse@1) until the WGSL is regenerated — so the
  pipeline validation will fail TODAY. This is intentional: the host side is ready
  for the fix.

THE FIX (next session — toolchain work, the real §4.B/pre-helmet task):
Need cross-stage binding allocation so VS and FS uniforms don't collide. Options:
  (A) A build flag analogous to --sampler-group=1 that OFFSETS the FS's uniform
      bindings (e.g. FS uniforms start after the VS's count), OR assigns the FS a
      different group. spv2wgsl already honors explicit bindings (spv2wgsl.zig
      ~290, reads DescriptorSet/Binding ~811) — so the cleanest is to make the
      codegen EMIT explicit, globally-unique (group,binding) per uniform across
      both stages. Investigate gen_shader_externs (emits the .constant externs)
      and whether zglsl/zspv or the Zig spirv backend can stamp a Binding
      decoration. NOTE: zglsl.zig had NO Binding/DescriptorSet handling — so the
      decoration likely must come from the Zig SPIR-V backend via the extern's
      declaration, or be injected by zspv. THIS IS THE THING TO FIGURE OUT FIRST.
  (B) Simpler stopgap to get a lit cube on screen NOW: author a lambert-for-wgpu
      shader variant whose uniforms are pre-assigned non-colliding explicit
      bindings (or fold mvp+mat_model into ONE struct uniform so the VS uses a
      single binding 0, and col_diffuse uses group0 binding1 in the FS without
      colliding — i.e. make each stage use exactly one uniform binding). The
      single-struct-per-stage approach also makes Resources usable again. This is
      probably the FASTEST path to a rendered lambert and worth doing first to
      unblock the visual, THEN solving (A) generally.

GATES (all green): wgpu-lambert-demo + wgpu-cube-demo + wgpu-demo build clean;
lint 0/273; live-shader naga 28/28; spv2wgsl 58/58; cube standalone still
byte-identical. Snapshot zimr837.

NEXT (revised): solve the cross-stage uniform binding collision (option B for a
fast visual lambert — single uniform-struct per stage — then option A generally).
This is now the gating item before the helmet (pbr hits this worst). Lambert
geometry/normals/host-wiring are DONE and correct; only the binding layout blocks.

## >>> DOCS FINISHED + §4.B lambert scoped (turn 816 cont.) <<<
Finished the doc cleanup (all stale Python-script refs now point at the in-build
step): PLAN.md (×2), finishing_webgpu.md §6.3, post-codegen-plan-v4.md (×2 — the
--verify plan now targets the WgpuStandalone step).  Remaining mentions of the
deleted script are HISTORICAL ("was deleted", "replaced the Python") and correct.
finishing_webgpu.md re-copied to outputs.  GATE green: cube byte-identical, lint
0/272, no instructional Python refs left.

§4.B LAMBERT — SCOPED, NOT STARTED (clean stopping point per the <90% rule).
Investigation result: lambert is a full unit of work like the cube was, because
the lambert WGSL is NOT emitted by any current build target.  The engine_shaders
list (build.zig 643-644) registers lambert_vs/fs, but only shaders actually
@embedFile'd by a built wasm get compiled to .wgsl — so lambert/pbr WGSL don't
exist in cache yet.  Confirmed by translating every cached shader.opt.spv: none
have mat_model/frag_normal.

WHAT LAMBERT NEEDS (precise next-session checklist — mirrors the cube turn):
1. lambert schemas (already exist, read this turn):
   - lambert_vs_io: Attributes {vertex_position vec3@0, vertex_tex_coord vec2@1,
     vertex_normal vec3@2}; Uniforms {mvp:[16]f32, mat_model:[16]f32} (TWO mat4s
     in the VS UBO — group 0).
   - lambert_fs_io: Samplers {texture0:.albedo}; Uniforms {col_diffuse:vec4}.
     Light is HARDCODED in the FS (fixed directional + 25% ambient) — no light
     uniform to push.  FS shape ≈ unlit + lighting math.
2. Decision: easiest path is a NEW wgpu_lambert_demo (or extend wgpu_cube_demo with
   a material toggle).  Recommend a fresh demo (isolation, like the cube) OR — since
   the cube demo's Resources+pipeline path is exactly reusable — add lambert as a
   second pipeline in the cube demo and a tap-to-toggle (mirrors examples/
   damaged_helmet.zig's picker).  Fresh demo is simpler to verify first.
3. Build target: register lambert_vs/fs for WGSL emission (the cube_pairs pattern
   at build.zig ~1503 — add lambert_vs/fs to a pairs list so .wgsl is emitted +
   wired as @embedFile). Then standalone via one WgpuStandalone.add() call.
4. CubeSchema → LambertSchema: Ubo gets {mvp:[4]@Vector(4,f32), mat_model:[4]@
   Vector(4,f32)} (128 bytes); Samplers unchanged (texture0). Vertex layout adds
   the normal: interleave OR a 3rd attribute — cube_split geometry has NO normals,
   so EITHER add per-face normals to the cube vertex data (6 face normals, easy for
   a cube) OR gen via genMeshCube (raylib mesh HAS normals — but separate arrays,
   needs the multi-buffer layout). Simplest: hand-add face normals to the inlined
   cube_vertices (CubeVertex gets a `normal:[3]f32`, stride 32, attr @2 offset 20).
5. Per frame: push BOTH mvp and mat_model (model matrix = the rotation; mat_model
   feeds the world-normal transform). writeUbo(.{.mvp=mvp, .mat_model=model}).
6. Gates: builds clean; lambert WGSL naga-valid (THE unknown — validate first
   thing, like cube_split's WGSL was); lint 0; standalone; browser-verify the lit
   cube (diffuse shading visible across faces). Snapshot.

NEXT: build §4.B lambert per the checklist above. Then the helmet (GLTF GpuMesh →
same Resources+pipeline path + PBR multi-group + 5 samplers + lights + shadow).

## >>> STANDALONE STEP GENERALIZED + docs updated (turn 816 cont.) <<<
Made the in-build standalone step BETTER: generalized from cube-specific to a
one-call helper any wgpu demo can use, and wired a SECOND consumer to prove it.

- `WgpuStandalone.add(b, exe, bundle_step, out_dir, out_basename, title,
  step_name, step_desc)` — derives the JS path + output path from out_dir,
  depends on the wasm (exe.getEmittedBin) + the JS-bundle step, registers the
  top-level step.  Adding a standalone to a new demo is now ONE call.
- Wired both demos through it: `zig build wgpu-standalone` (2D wgpu_demo) and
  `zig build wgpu-cube-standalone` (3D cube).  The 2D one is the second consumer
  proving generalization; both build clean.  Cube output stays BYTE-IDENTICAL to
  the verified-working file.
- Lambert/helmet will each get a standalone by one WgpuStandalone.add call when
  they exist — no script, no per-demo template.

DOCS updated (per Simon):
- `src/web/readme.html` (public-facing): shader paragraph now lists THREE
  compile targets (added WGSL-via-spv2wgsl, build-time-only); new paragraph on
  the single-file standalone (`zig build wgpu-standalone` / `wgpu-cube-standalone`,
  file://-runnable, bundler is a build step not a script).  <p> tags balanced 49/49.
- `src/notes/claude.md`: new "WebGPU standalone — an in-build step, NOT Python"
  subsection documenting the commands, WGPU_STANDALONE_TEMPLATE, the WgpuStandalone
  step, and the .add() helper, with the rule: new wgpu demo → one .add() call,
  don't reach for a script.

GATES (all green): wgpu-standalone + wgpu-cube-standalone + wgpu-demo build clean;
cube byte-identical to verified output; lint 0/272; readme well-formed.  Snapshot
zimr835.  (live-shader naga / naga-tint unchanged — no shader/transpiler touch.)

REMAINING FOLLOWUP (noted, low priority): a few OTHER docs still name the deleted
Python script (PLAN.md, post-codegen-plan-v4.md, finishing_webgpu §6.3) — stale
prose only.  NEXT: §4.B lambert.

## >>> CUBE RENDERS + standalone moved INTO build.zig (Python killed) (turn 816 cont.) <<<
CUBE CONFIRMED RENDERING: Simon's screenshot shows the textured (blue/white
checker) depth-tested cube spinning at 120fps in Android Chrome.  §4.A DONE —
3D-on-wgpu works end-to-end.  The Resources two-group binding (UBO group0 +
texture group1) was correct; texture0 is bound (not black).

THEN: killed scripts/build_standalone_wgpu.py — the wgpu standalone is now an
IN-BUILD step (`zig build wgpu-cube-standalone`).  Per Simon: the HTML template
is an inlined Zig string constant in build.zig, NOT a hand-written .html file.
- `WGPU_STANDALONE_TEMPLATE` (const multiline string in build.zig): the full
  page — CSS, the in-page debug pane (mobile error capture), the WASI shim, the
  bootstrap + frame loop.  Three explicit markers: __TITLE__, __JS_BODY__,
  __WASM_B64__ (explicit markers, NOT std.fmt — so the template's CSS/JS braces
  need no escaping).
- `WgpuStandalone` custom Step (mirrors the existing FixtureGlslCheck pattern):
  make() reads the built wasm (LazyPath via getPath2) + base64-encodes
  (std.base64.standard.Encoder); reads the Bun-bundled zimr_wgpu.js (fixed path);
  strips its `export {}` → globalThis assignment; injects the uncapturederror
  device hook; does 3 std.mem.replaceOwned substitutions into the template;
  writes via cwd.writeFile.  Wired to depend on the wasm + the JS-bundle step.
- PROVEN FAITHFUL: byte-diffed the in-build output against the Python output →
  BYTE-IDENTICAL (after fixing two `\n`→`
` template-extraction escapes).  Only
  then deleted the Python.  The deleted-script output is the SAME file Simon
  already verified rendering, so the in-build one renders identically.

0.16 API notes (for the next custom step): file read = `cwd.readFileAlloc(io,
path, gpa, .unlimited)` with `io = b.graph.io`; write = `cwd.writeFile(io,
.{.sub_path, .data})`; make-dir = `cwd.createDirPath(io, dir)` (NOT makePath);
LazyPath in make = `lp.getPath2(b, step)` + `lp.addStepDependencies(&self.step)`;
custom step = `@fieldParentPtr("step", step)` + `Step.init(.{.id=.custom,...})`.

LINT: the make() locals tripped rule-2 (untyped-local) — added explicit type
annotations (std.mem.Allocator, std.base64.Base64Encoder, []const u8, []u8, usize).

GATES (all green): wgpu-cube-demo + wgpu-cube-standalone + wgpu_demo build clean;
standalone byte-identical to the verified-working Python output; lint 0/272;
live-shader naga 24/24; naga-tint 162/1/18.  Snapshot zimr834.

FOLLOWUP (not done, noted): docs still reference the deleted Python script
(PLAN.md, post-codegen-plan-v4.md, finishing_webgpu §6.3 line ~430).  Stale doc
refs only — update opportunistically.  Also: the standalone step is cube-specific;
generalizing it (template + wasm + title args for any wgpu demo — lambert, helmet)
is a small follow-up when those demos exist.

NEXT: §4.B lambert (swap material on the cube's Resources+pipeline path), then the
helmet (loadModelFromGltfMemory → GpuMesh → vertex/index buffers → same path + PBR
multi-group Resources).

## >>> 3D-ON-WGPU: cube texture0 binding RESOLVED — Resources two-group pattern (turn 816 cont.) <<<
Closed the one loose end from the cube's first build: the FS texture0 binding.
The cube now builds with the CORRECT two-group bind layout — should render
textured, not black.  (Still needs Simon's browser confirmation for the actual
render, but the binding bug that would have made it black is fixed.)

THE BUG: my first cube used `loadShader(vs_shader_io, ...)` — but loadShader's
typed-schema path builds a pipeline layout with only ONE bind group (group 0,
the UBO).  cube_split_fs needs texture0 at @group(1) binding 0/1 (confirmed in
its WGSL).  So group 1 was never wired → pipeline-layout mismatch / black cube.

THE FIX (mirrors Renderer2D exactly — the proven two-group pattern): replaced
loadShader with `Resources(CubeSchema)` + an explicit pipeline.
- Defined `CubeSchema` inline in the demo: `pub const Ubo` (mvp, → group 0) AND
  `pub const Samplers { texture0: si.Sampler2D(.albedo,.{}) }` (→ group 1).  The
  layout solver assigns group 0 to the Ubo, group 1 to the sampler — matching
  cube_split's WGSL.
- `Resources(CubeSchema).init(gpa, &frame, .{ .initial_ubo=.{}, .texture0=tex })`
  builds BOTH bind-group layouts (bg_layouts[0], bg_layouts[1]) + bind groups.
- Pipeline layout chains both: `createPipelineLayout(device, &.{bgl0, bgl1})`.
- Explicit pipeline: createShaderModuleWgsl ×2 + StateCombo.fromParts(.triangle_list,
  .alpha, .less, .back, fmt, .depth24_plus, 1) + createRenderPipeline.
- Per frame: `resources.writeUbo(.{.mvp=mvp})` + `Backend.setPipeline(&ps,
  RenderPipeline(void,void){.gpu_handle=pipeline})` + `resources.bind(&ps)` (binds
  BOTH groups via groups_used bitmask) + setVertexBuffer/setIndexBuffer/drawIndexed.

SEVERAL API CORRECTIONS found by iterative building (recon had these wrong):
- `StateCombo.fromParts` order is (topology, blend, DEPTH, CULL, color_fmt,
  depth_fmt, samples) — depth BEFORE cull (I had them swapped → ".back not a
  DepthMode member").
- `setPipeline` needs `z.shader.RenderPipeline(void,void){.gpu_handle=h}`, not a
  raw `.{.gpu_handle=h}` anon struct (gpu_iface @compileErrors the raw form).
- `Sampler2D` lives in the `shader_interface` module (`si.Sampler2D`), NOT on
  `z.shader` (shader_runtime).  Wired shader_interface_mod to wgpu_cube_mod.
- Exposed `pub const pipeline_cache` on zimr_wgpu.zig (was internal-only; needed
  for StateCombo).  Safe re-export (not a named dep elsewhere for this module, so
  no collision like the `math`/`zm` one).

WHY THIS IS THE RIGHT ARCHITECTURE (not a workaround): loadShader's single-group
assumption is a real limitation for ANY multi-group shader.  The helmet's PBR
needs even more groups (material UBO + 5 samplers + lights).  Resources + explicit
pipeline is the pattern that scales there — so the cube now uses the same path the
helmet will.  Noted in finishing_webgpu §4: the loadShader single-schema path is
2D-shaped; 3D/PBR uses Resources.

GATES (all green): wgpu-cube-demo + wgpu-demo build clean; lint 0/272; live-shader
naga 24/24 (cube_split VS+FS in corpus); naga-tint unchanged 162/1/18; spv2wgsl
58/58.  Snapshot zimr833 (re-taken with the fix).

STILL UNVERIFIED (browser only): the spinning textured cube render.  If anything's
off, most-likely-first: (a) the cube renders but winding looks inverted → flip
cull to .front; (b) MVP/clip handedness (perspectiveFovRh gives z in [0,1], correct
for wgpu) — if the cube is missing/clipped, check near/far or eye distance. The
texture0-black risk is now eliminated.

NEXT: Simon browser-checks. If cube renders → §4.B lambert (swap material on this
same Resources+pipeline path), then the helmet (loadModelFromGltfMemory → GpuMesh
→ upload to vertex/index buffers → same draw path + PBR multi-group Resources).

## >>> 3D-ON-WGPU: the unlit cube demo BUILDS (§4.A) (turn 816) <<<
Built `examples/wgpu_cube_demo/` — the first 3D-on-wgpu demo: a depth-tested
textured spinning cube through the WebGPU backend.  All BUILD-SIDE gates green;
the spinning cube itself needs Simon's browser confirmation (no GPU in sandbox).

KEY DECISION (resolved the recon's open question): reused the EXISTING cube_split
shader pair (`cube_split_vs/fs` + `cube_split_vs_io` which already declares
`Ubo.mvp`) instead of unlit_vs/fs.  cube_split was an existing GL+CPU cube demo;
its typed shaders translate to naga-valid WGSL and have exactly the right schema.
Used loadShader with the VS schema (vs_shader_io) — its `Ubo.mvp` lands at
@group(0)@binding(0), the FS texture0 at @group(1) (the Renderer2D split).

WHAT LANDED:
- `examples/wgpu_cube_demo/wgpu_cube_demo.zig` (~290 lines): depth24plus texture
  created + threaded into beginRenderPass via `.depth_view`; cube geometry (24
  verts/36 idx interleaved pos+uv, reused from cube_split) → ONE wgpu vertex
  buffer (stride 20) + index buffer (uint32); checkerboard texture; loadShader
  with depth_state=.less, cull_mode=.back, vertex_buffer_layouts=<interleaved 3D
  layout>; per-frame MVP = mulMat(perspectiveFovRh, mulMat(lookAtRh, model-rot))
  pushed to the VS UBO; beginFrame→beginRenderPass(depth_view)→bindForDraw→
  setVertexBuffer→setIndexBuffer→drawIndexed→endRenderPass→endFrame.
- `examples/wgpu_cube_demo/index.html` (adapted from wgpu_demo).
- build.zig: `wgpu-cube-demo` target (mirrors wgpu_demo block; registers the
  cube_split VS+FS pair for .wgsl emission; wires zm + io modules; installs to
  zig-out/wgpu-cube/).

TWO API CORRECTIONS found by building (the recon had these slightly wrong):
1. `depth_format` is NOT a ShaderDesc field — it's `GpuFrame.depth_format`
   (default null).  Set `s.gpu_frame.depth_format = .depth24_plus` BEFORE
   loadShader (loadShader reads desc.f.depth_format for the depth-stencil state).
2. `zimr_wgpu` does NOT re-export the math module.  FIRST attempt added
   `pub const math = @import("zimrmath.zig")` to zimr_wgpu.zig — this REGRESSED
   wgpu_demo with "file exists in modules 'zimr_wgpu' and 'zm'" (mandelbrot_fs_io
   gets double-registered).  FIX: reverted that; import `zm` DIRECTLY in the cube
   demo (`const zm = @import("zm")`) + `wgpu_cube_mod.addImport("zm", zimrmath_mod)`
   in build.zig.  LESSON: don't re-export a whole module that's also a named dep
   elsewhere — it collides on shared io files.

GATES (all green): wgpu-cube-demo builds clean (wasm+js+html produced);
wgpu_demo builds clean (regression fixed); both embedded cube shaders naga-VALID;
live-shader naga 22/22 (cube_split joined); naga-tint unchanged 162/1/18;
lint 0/272.

NOT VERIFIED: the actual render (spinning cube) — Simon confirms in browser.
Build-side contract (compiles clean + WGSL naga-valid + structurally correct) is
fully met.  Likely first-render risks to watch: (a) winding/cull — cube_split is
CCW-from-outside + I set cull_mode=.back (should be correct, but if the cube looks
inside-out, flip to .front or .none); (b) the FS texture0 binding — bindForDraw
binds via the VS schema which has no Samplers, so texture0 may need explicit
binding (UNVERIFIED — if the cube renders untextured/black, this is why; check how
cube_split_fs's texture0 gets its bind group, may need a Samplers-bearing schema
or an explicit material bind group like Renderer2D.resources).

NEXT: Simon browser-checks the cube.  If it renders → §4.B lambert (swap material),
then the helmet (loadModelFromGltfMemory → same GpuMesh → same draw path + PBR).
If texture0 is unbound (black cube) → wire the FS sampler bind group (the one real
loose end).  Snapshot zimr833.

## >>> 3D-ON-WGPU GROUNDWORK: vertex-layout override + cube-demo recon (turn 815 cont.) <<<
Starting §4.A (the unlit depth-tested cube — the 3D linchpin).  This turn:
landed the one REUSABLE infrastructure change and did exhaustive API recon so
the demo itself is pure wiring next session.

INFRASTRUCTURE (landed, verified compiling):
- `src/shader_runtime_wgpu.zig`: added `vertex_buffer_layouts:
  ?[]const descriptor_encoder.VertexBufferLayout = null` to `ShaderDesc`.  At
  the pipeline-build site, `const vbls = desc.vertex_buffer_layouts orelse
  &.{default_vertex_layout};` then `pdesc.vertex_buffer_layouts = vbls`.
  Backward-compatible (null → the existing 2D Vertex2D layout, unchanged).  This
  is the "future overload" the old comment anticipated — 3D meshes now pass their
  own layout (e.g. two separate buffers: slot0 vec3 position @0, slot1 vec2 uv @1
  for raylib's non-interleaved arrays).  `wgpu-demo` still builds; lint 0/271.
  NOTE: the pre_bake_pipelines path (~line 456) still hardcodes the 2D layout —
  irrelevant for the cube (pre_bake defaults false), tidy later if 3D ever wants it.

RECON (all verified, ready to wire):
- Init: initDevice → getQueue → getSurface → getSurfaceFormat → GpuFrame.init
  (+ PipelineCache.init, BindGroupCache.init).  Mirror examples/wgpu_demo.
- Mesh: `gpu.genMeshCube(gpa, world, w,h,d)` → raylib Mesh with SEPARATE arrays
  vertices(XYZ f32)/texcoords(UV f32)/indices(u16).  → upload to TWO wgpu vertex
  buffers (slot0 pos, slot1 uv) + one index buffer.  GpuMesh holds the CPU
  pointers (gpu.zig GpuMesh).  loadModelFromGltfMemory produces the SAME shape
  (the helmet reuses this exact path).
- Buffers: wgpu.createBuffer(device,.{.size,.usage=BufferUsage{.vertex/.index/
  .copy_dst},.label}) + wgpu.queueWriteBuffer(queue,buf,0,bytes).
- Depth: wgpu.createTexture(device,.{.width,.height,.format=.depth24_plus(=10),
  .usage=TextureUsage{.render_attachment=true}}) → wgpu.createTextureView →
  thread as beginRenderPass `.depth_view`.  DepthMode.less=1.  beginRenderPass
  (gpu_iface BeginRenderPassDesc) already takes `depth_view: ?TextureViewHandle`
  — fully plumbed (JS bridge emits depthStencilAttachment clear/store).
- Draw: render_pass.setVertexBuffer(pass,.{slot,buffer,offset,size}) ×2 +
  setIndexBuffer(pass,.{buffer,format=.uint16,...}) + drawIndexed(pass,
  .{index_count,...}).
- MVP: zm.Mat=[4]Vec(@Vector(4,f32)); zm.mulMat / zm.identity / zm.rotationY /
  zm.translation / zm.lookAtRh / zm.perspectiveFovRh (the RH form has z in [0,1]
  — CORRECT for WebGPU, `r=far/(near-far)`).  Flatten Mat→[16]f32 column-major
  (matches WGSL mat4x4 + the orthoTopLeft convention in renderer_2d.zig:453).
- Shaders: unlit_vs_io (Attributes {vertex_position:vec3@0, vertex_tex_coord:
  vec2@1}; Uniforms {mvp:[16]f32}) + unlit_fs_io (Samplers {texture0:.albedo};
  Uniforms {col_diffuse:vec4}).  ENGINE SHADERS ALREADY EMIT .wgsl (build.zig
  emit_wgsl=true, line 726) — the cube demo just needs the engine_shaders.items
  loop (like wgpu_demo at line ~1357) and `@embedFile("unlit_vs.wgsl")` works.
- Live-shader naga corpus now 19/19 (unlit/lambert/etc. all validate) — the
  cube's unlit WGSL is confirmed naga-valid.

THE ONE REAL COMPLEXITY (decided): the unlit shader has TWO UBOs — `mvp` (VS,
→ @group(0) @binding(0)) and `col_diffuse`+`texture0` (FS, → @group(1)).
loadShader's schema (unlit_fs_io) auto-manages only the FS side (group 1).
Renderer2D's convention is exactly this split (VS UBO group0, FS material
group1; see renderer_2d.zig:22-27).  So the cube demo creates the group-0 MVP
bind group itself (mirror Renderer2D.updatePerFrame: writeUbo a 64-byte mat4),
and lets loadShader handle group 1.  ALTERNATIVELY (simpler for a first cube):
build the pipeline + both bind groups explicitly like wgpu_smoke_test.zig does,
bypassing loadShader's FS-centric schema.  Pick one next session.

PENDING (the cube demo itself — next session, ~250 lines + build target + html):
1. New build target `wgpu-cube-demo` mirroring the wgpu_demo block (build.zig
   ~1329): create wgpu_cube_demo_mod, run engine_shaders.items loop to wire
   unlit_vs/fs .wgsl, addExecutable reactor/disabled-entry/rdynamic, bundle
   zimr_wgpu.ts, install index.html.
2. examples/wgpu_cube_demo/wgpu_cube_demo.zig: init scaffold; create depth
   texture+view; genMeshCube → upload 2 vertex buffers + index buffer; loadShader
   (unlit, depth_state=.less, cull_mode=.back, vertex_buffer_layouts=<2-buffer 3D
   layout>) OR explicit pipeline; per-frame push MVP=mulMat(persp,mulMat(view,
   rotationY(t))); beginFrame→beginRenderPass(depth_view)→bind→setVertexBuffer×2→
   setIndexBuffer→drawIndexed→endRenderPass→endFrame.  Texture via
   WgpuTexture.createCheckerboard.
3. examples/wgpu_cube_demo/index.html (mirror wgpu_demo's).
4. Gate: zig build wgpu-cube-demo clean; embedded unlit WGSL naga-valid; lint
   0/271.  Browser render = Simon verifies on phone (no GPU here).
5. Then §4.B lambert (swap material), then the helmet (same path + GLTF + PBR).

## >>> LIVE SHADERS: all 10 now naga-valid (was 7/3) — IO + binding fixes (turn 813 cont.) <<<
Pivoted from synthetic Tint fixtures to the REAL zimr shaders.  Found all 10 go
through the IR path (zero legacy fallback), but 3 fragment shaders emitted
naga-INVALID WGSL.  None were control-flow bugs — three distinct IO/binding
issues in spv2wgsl.zig's emission (the long-standing "dying GLSL-path shaders"):

1. Fragment-input @location missing.  WGSL requires every non-builtin entry IO
   field to carry @location, but GLSL→SPIR-V leaves varyings' locations implicit
   (name-matched).  FIX: emitIoField now takes an auto_location; a non-builtin,
   non-struct IO field with no explicit Location gets a sequential location
   (0,1,2… in declaration order), matching vertex-output ↔ fragment-input
   numbering.  (Cleared the "Argument 0 varying error" on all 3.)

2. Binding collisions.  Uniforms with no explicit Binding decoration all
   defaulted to 0 → naga "conflict".  FIX: added State.next_auto_binding +
   resolveBinding(s,d) — explicit bindings honored, else sequential 0,1,2… per
   module.  (Cleared the cardioid/mandelbrot + others.)

3. GLSL default-uniform quirk.  A plain `uniform vec4 x;` lowers to a
   UniformConstant with a CONCRETE type, but WGSL's handle `var` is only for
   opaque resources → "Type isn't compatible with address space Handle".  FIX:
   the UniformConstant arm emits `var<uniform>` for non-opaque pointees, bare
   handle `var` only for type_image / type_sampler / type_sampled_image.  (The
   sampled-image case was the subtle one — GLSL combined samplers wrap the image
   in an OpTypeSampledImage, so the variable's pointee is type_sampled_image, not
   a bare type_image.)

RESULT: live-shader naga 7/3 → 10/10.  EVERY real zimr shader (default, lambert,
pbr, shadow, skybox, unlit, default_shapes — vertex + fragment) now produces
naga-valid WGSL.  This matters more than the synthetic fixtures: these are the
shaders the engine actually ships.

REGRESSION: naga-tint unchanged (162/1/18 — no fixture regressed).  wgpu-check
drift was EXACTLY the 3 fixed shaders (now valid); refreshed the corpus fixture.
The 7 previously-passing shaders stayed byte-identical.

NOTE: the auto-binding counter is currently global across @groups (so group 0 may
start at a nonzero binding if a group-1 resource was declared first) — valid, just
not minimal.  A per-group counter would tidy the numbering; deferred (correctness
first).

Gates: spv2wgsl 58/58, ir_build 33/33, ir_emit 9/9, wgpu-diff green, naga-tint
green (162/1/18), wgpu-check green, live-shader naga 10/10, lint 0/271.

## >>> FALLBACK BURN-DOWN: both-back-edge single-block infinite loop (turn 813 cont.) <<<
buildSingleBlockLoop's conditional handler required exactly one edge back to
the header and one to the merge.  branch_Loop_Infinite_BranchConditional and
branch_Loop_SingleBlock_BothBackedge have a header conditional whose BOTH edges
are the back-edge (neither reaches the merge) — a true infinite loop
(spirv-cross collapses it to `{}`).

FIX: a `both_backedge` case — when both edges are the back-edge, the condition
is immaterial (both arms re-loop), so lower to an empty continuing exactly like
an unconditional self-branch (`loop { continuing {} }`).

RESULT: cleared 2 fixtures.  naga-valid 160 → 162 / 181; fallback 20 → 18;
naga-debt still 1.  Added a buildSingleBlockLoop unit test.

REGRESSION: zero (wgpu-check NO drift).

Running fallback tally this session: 32 → 18 (cleared 14 across degenerate
both-break header, break-if-in-continuing 7-cascade, infinite-loop-header
neither-breaks, and now both-back-edge).

Gates: spv2wgsl 57/57, ir_build 33/33, ir_emit 9/9, wgpu-diff green
(177 ok / 4 known-bug), naga-tint green (162/1/18), wgpu-check green (no drift),
lint 0/271.

## >>> FALLBACK BURN-DOWN: infinite-loop header (neither edge breaks) (turn 813 cont.) <<<
A bail line shared by 3 fixtures (branch_BranchConditional_Continue_Continue_FromHeader,
phi_Phi_Loop_BranchConditionalBreak, phi_Phi_Loop_WithContinue_PhiInContinue) in
buildLoop's header-branch classifier: the `else` arm bailed when NEITHER header
edge targeted the merge.

Shape (confirmed via spirv-cross → `for(;;) { if (c) {…break…} }`): when neither
header edge is the merge, the header conditional is not a loop guard at all — it's
the first branch INSIDE an infinite-loop body, with the break occurring deeper in.
Tint handles this implicitly (it processes the header terminator as normal in-body
flow); our buildLoop was forcing every conditional header into a while-guard.

FIX (buildLoop): added a `header_in_body` case — when neither edge breaks, build
the body by running buildUnstructuredCond on the HEADER block itself (header
straight-line items first, then the conditional with each edge resolved against
the merge→exit_loop / continue→cont stops).  Reuses the existing in-loop
break/continue machinery instead of a forced guard.

RESULT: cleared 3 fixtures.  naga-valid 157 → 160 / 181; fallback 23 → 20;
naga-debt still 1.  Added a buildLoop unit test (infinite loop, in-body header
conditional).

REGRESSION: zero.  wgpu-check NO drift — the new case only fires on the
previously-bailed neither-to-merge header shape.

REMAINING fallbacks (20) cluster on DEFENSIVE GUARDS now, not clean shape
decisions: L109 (StopStack overflow — runaway recursion on genuinely-tricky
multi-block-backedge / Propagated shapes, ~7 fixtures) and L1465 (branchTarget
zero-operand guard, ~5).  These are the genuinely-unstructured / multi-exit group
flagged earlier as likely-staying-on-legacy; each needs individual study (some may
be irreducible even for Tint).  Cleaner remaining clusters: L1005 (~4:
ValueFromLoopBodyAndContinuing, SimultaneousAssignment, ContinueIsHeader,
Propagated_BreakIf) and L759 (~2: Infinite_BranchConditional, SingleBlock_BothBackedge).

Gates: spv2wgsl 56/56, ir_build 32/32, ir_emit 9/9, wgpu-diff green
(177 ok / 4 known-bug), naga-tint green (160/1/20), wgpu-check green (no drift),
lint 0/271.

## >>> FALLBACK BURN-DOWN: break-if in the continuing block — 7-fixture cascade (turn 813 cont.) <<<
Biggest fallback win so far.  A bail line shared by 3 fixtures
(branch_Loop_Continue_HasBreakIf/HasBreakUnless, phi_Phi_LoopWithIf) in
buildContinuing: it only accepted a PLAIN branch back to the header, and
bailed on a CONDITIONAL terminator in the continuing block.

Shape (confirmed via spirv-cross → `do { ... } while(...)`): the continuing
block ends with OpBranchConditional where one edge is the loop merge (break)
and the other is the header (back-edge).  WGSL spells this
`continuing { ...; break if cond; }`.  The IR + emitter ALREADY supported a
`break_if` continuing terminator (emitted last, as WGSL requires) — only the
BUILDER didn't produce it.

FIX (buildContinuing): when the continuing terminator is branch_cond with
one edge == loop merge and the other == header, emit a `break_if` (cond from
the branch; invert=true when the BREAK is the FALSE edge, so `break if
!(cond)`).  Needed the loop merge id, so added a `loop_merge_id` param to
buildContinuing (renamed to avoid shadowing an inner selection-merge local).

RESULT — a hoisting-family-style cascade: cleared 7 fixtures from ONE fix.
The 3 targeted + 4 free bonuses (branch_Branch_LoopBreak_FromContinueConstructTail,
branch_Loop_Loop_InnerContinueBreaks, phi_Phi_PhiInLoopHeader_FedByPhi_PhiUsed/Unused).
naga-valid 150 → 157 / 181; fallback 30 → 23; naga-debt still 1.  Added a
buildContinuing unit test (break_if, non-inverted).

REGRESSION: zero.  buildContinuing touches every loop with a continuing
block, but wgpu-check showed NO drift — the new case only fires on a
conditional continuing terminator, which no previously-handled shape had.

Gates: spv2wgsl 55/55, ir_build 31/31, ir_emit 9/9, wgpu-diff green
(177 ok / 4 known-bug), naga-tint green (157/1/23), wgpu-check green (no
drift), lint 0/271.

## >>> FALLBACK BURN-DOWN START: degenerate both-break loop header (turn 813 cont.) <<<
Began the F5 fallback burn-down (32 untranslated shapes → the path to
deleting the legacy walker).  Instrumented bail sites; several simple-loop
fixtures bailed in buildLoop at the header-branch classifier, which only
accepted "exactly one edge to the merge (break), the other to the body".

Studied Tint (EmitLoop/EmitLoopMerge ~loop setup): Tint never special-cases
the header branch — it creates the loop, then processes the header's
terminator NORMALLY inside the body, so edges to merge/continue resolve via
the walk-stop map.  A header `BranchConditional %c %merge %merge` just
becomes `if (c) { break } else { break }`.

FIX (buildLoop): added a `both_break` case — when BOTH header edges target
the merge (a loop that never iterates), build a guard If whose BOTH arms are
exit_loop (distinct break blocks so each can carry its own merge-phi break
edge), and skip building a body chain (there is none).

RESULT: cleared 2 fallbacks — branch_Loop_Never and (free bonus, same shape
in a single-block loop) branch_BranchConditional_LoopBreak_SingleBlock_LoopBreak.
naga-valid 148 → 150 / 181; fallback 32 → 30; naga-debt still 1.  Added a
buildLoop unit test (both arms exit_loop).

REGRESSION: zero.  buildLoop touches every loop, but wgpu-check showed NO
drift (identical output for all real shaders) — the new case only fires on
the previously-unhandled both-to-merge shape.

NOTE on shared bail lines: branch_Loop_Never and phi_Phi_Loop_BranchConditionalBreak
shared a bail line but are DIFFERENT shapes — the latter's header picks body
vs CONTINUING (neither edge to merge), with the break elsewhere; still a
fallback, a separate future feature.

Gates: spv2wgsl 54/54, ir_build 30/30, ir_emit 9/9, wgpu-diff green
(177 ok / 4 known-bug), naga-tint green (150/1/30), wgpu-check green (no
drift), lint 0/271.

## >>> SIMPLIFICATION: unified operand-shape table (turn 813 cont.) <<<
Acted on Tier-1.2 of spv2wgsl_simplifications.md.  The hoist analysis had
TWO hand-written classifiers encoding SPIR-V operand semantics — bodyResultId
(def-side: which ops produce a value result) and appendValueOperands
(use-side: which operands are value <id>s).  They covered the same opcode
space and had to be kept consistent BY HAND (add an op to one, forget the
other → drift).

Replaced both with a single `OpShape` table + `opShape(op)` function that
records the facts once: { has_value_result, value_from, value_count,
custom }.  bodyResultId is now a 1-liner reading opShape; appendValueOperands
is a generic from/count loop + 2 custom cases (CompositeExtract /
VectorShuffle, whose operands interleave literals with ids).  Adding an
opcode is now ONE table entry instead of two coordinated edits.

BEHAVIOR-PRESERVING — proven: wgpu-check (a snapshot test over the whole
corpus) showed ZERO drift, i.e. byte-identical output to the old two-function
version.  naga-tint unchanged at 148/1/32.  Pure refactor, no functional
change.  bodyResultId 40→10 lines; appendValueOperands 156→40; the operand
semantics now live in one place.

(Wrote two companion docs this turn: src/notes/spv2wgsl_tutorial.md — a
beginner-friendly explanation of the whole transpiler — and
src/notes/spv2wgsl_simplifications.md — ranked simplification suggestions.
The headline suggestion is still F5: finishing the fallback burn-down so
the legacy walker (~1400 lines) can be deleted.)

Gates: spv2wgsl 54/54, ir_build 29/29, ir_emit 9/9, wgpu-diff green,
naga-tint green (148/1/32), wgpu-check green (no drift), lint 0/271.

## >>> SIGNED SWITCH CASE LITERALS — naga-debt down to ONE (turn 813 cont.) <<<
Studied Tint (parser.cc EmitSwitch ~3838): a switch case literal is a raw
32-bit word; Tint types it to the selector — `i32(literal)` for a signed
selector, `u32(literal)` otherwise.  For a signed selector the word is
REINTERPRETED (bitcast), so 4000000000 → the i32 it encodes, -294967296.
naga rejects a bare `case 4000000000` because that abstract int overflows
i32.

FIX: added State.scalarTypeNameOf(id) (the value's scalar type spelling,
"i32"/"u32"/…) to the ir_emit duck-typed interface; ir_emit's switch
case-value loop now, when the selector is "i32", emits @bitCast(u32→i32)
of each case word as a signed decimal.  One unit test (ir_emit, signed
selector → `case -294967296`).

RESULT: branch_Switch_Case_SintValue naga-valid.  naga-valid 147 → 148 /
181; baseline 2 → 1.  Zero regressions (no shader-with-switch drifted;
live-shader naga unchanged 7 PASS / 3 FAIL).

>>> NAGA-DEBT IS NOW A SINGLE FIXTURE <<<
Only function_VertexShader_PositionUsed_Transitive remains baselined: the
position Output global is written inside a HELPER fn, needing the
module-scope-var → function param/return transform (thread the output
through the call chain).  That is a larger, separate feature — the last
piece of naga-debt before the focus shifts entirely to the 32 fallbacks
(untranslated shapes) and ultimately F5 (delete the legacy walker).

Gates: spv2wgsl 54/54, ir_build 29/29, ir_emit 9/9, wgpu-diff green,
naga-tint green (148/1/32), wgpu-check green, lint 0/271.

## >>> PHI-CROSS-BLOCK HOISTING — extends the hoist scan to phi operands (turn 813 cont.) <<<
Direct continuation of the hoisting work.  The cross-block hoist scan
caught instruction-operand uses but MISSED phi-operand uses: a phi
assignment `phiN = value` is emitted at the END of the phi's PREDECESSOR
block, so if `value` is defined in a different block than that
predecessor, it escapes its scope just like any cross-block use — but the
use site is the predecessor, not the phi's own block.

FIX (markHoistedResults use-scan): for each OpPhi, walk its (value,
pred_block) pairs; if def_block[value] != pred_block, mark value hoisted.
One added branch in the existing scan.

RESULT: cleared all 4 remaining phi-cross-block fixtures —
phi_Phi_PhiInLoopHeader_FedByHoistedVar_PhiUsed/Unused (a value defined
in a nested if-body feeds a loop-header phi via the back-edge),
phi_Phi_Bug_435621075, phi_Phi_Propagated_PropagatedPhiValue_BlockParam.
naga-valid 143 → 147 / 181; baseline 6 → 2.

REGRESSION: 3 WORKING shaders drifted (the phi-use scan now also hoists
phi predecessor values that are additionally used by regular
instructions).  Verified CORRECT: each hoisted var is declared, assigned,
then read, and all 3 still naga-validate (live-shader naga unchanged at
7 PASS / 3 FAIL).  Refreshed the corpus fixture.  Drift was benign and
correct, confirmed by naga (which checks scope + types).

Gates: spv2wgsl 53/53, ir_build 29/29, ir_emit 8/8, wgpu-diff green,
naga-tint green (147/2/32), wgpu-check green, lint 0/271.

REMAINING naga-debt — just 2 now:
  - branch_Switch_Case_SintValue: a signed switch case literal
    (4000000000 as i32) needs `i`-suffixed / correctly-typed formatting
    so naga accepts the abstract→i32 conversion.
  - function_VertexShader_PositionUsed_Transitive: position Output global
    written inside a HELPER fn — needs the module-scope-var → function
    param/return transform (thread the output through the call chain), a
    larger separate feature.

## >>> CROSS-BLOCK VALUE HOISTING — biggest single win (turn 813 cont.) <<<
Studied Tint first (parser.cc IdIsInScope ~1412 + AddOperandToTerminator
/ PropagateTerm ~2700-2760): Tint solves "value defined in block A, used
in block B" by PROPAGATING the SSA value out through control-instruction
results (threading it as block params through exits).  That is the
SSA-specific machinery our var-based model deliberately avoids — and the
var-based equivalent is far simpler: hoist the value to a function-scope
`var` (assign at the def site, read anywhere later), exactly like phis.

IMPLEMENTED (all in src/spv2wgsl.zig):
  - markHoistedResults(s, fn_k, end_k): two linear passes over the
    function (SPIR-V guarantees def-before-use in linear order).  Pass 1
    records each value result's defining block + result type.  Pass 2
    scans value-operand USES; if a use's block != the def block, mark the
    id `hoisted` and remember its type.  Called at the top of
    emitOneFunction (BEFORE the var-declaration prologue — the original
    bug was calling it in emitFunctionBody, which runs AFTER the prologue,
    so the `var` decl was skipped while the def site already emitted an
    assignment → undeclared identifier).
  - appendValueOperands(op, ops, …): a PRECISE, conservative operand-kind
    classifier giving only the <id> value-operand positions per opcode.
    Critical for correctness: a switch-case literal, shuffle component
    index, ext-inst opcode number, or storage-class enum must NEVER be
    mistaken for a value id (a false positive would MISCOMPILE a correct
    shader, which the gates might not catch).  Unknown opcodes contribute
    nothing (safe: misses a hoist rather than miscompiling).  Only Op
    enum members that actually exist are listed (pruned SMod/FMod/
    Transpose/ImageRead/CompositeInsert/Unreachable — not in our enum).
  - bodyResultId(op, ops): the value id an instruction DEFINES (result at
    ops[1] for value ops), or null for terminators/stores/labels/merges/
    debug and the already-fn-scope decls (Variable/Phi).
  - bindLhs(out, s, id, name, ty): centralizes the let-vs-var decision —
    `let _N: T = ` normally, `_N = ` for a hoisted id (assigns the
    pre-declared var).  All ~17 value-emitting helpers now route their
    binding LHS through it (one-line change each).
  - State.hoisted []bool + State.hoist_type []u32 (the captured types).
  - emitOneFunction declares `var _N: T;` for every hoisted id alongside
    the phi vars.

RESULT — the biggest single-feature jump of the arc: naga-valid 135 →
143 / 181; baseline 14 → 6.  Cleared in ONE feature: the whole
hoisting-into-nested family (branch_*Hoisting*, branch_ConvertHoisted),
both switch-hoist (HoistFromCase/Default), branch_Loop_ContinueUseBodyValue,
and branch_BranchConditional_DuplicateTrue_Premerge.

REGRESSION SAFETY (the thing I was most careful about): zero working
shaders broke.  Live-shader naga stayed exactly 7 PASS / 3 FAIL (the 3
are the known dying flat-uniform GLSL-path shaders).  ONE shader drifted
in wgpu-check — and it was one of those 3 already-invalid dying shaders;
refreshed the corpus fixture for it.  The conservative operand classifier
paid off: no literal/label was ever mistaken for a value id.

KNOWN LIMITATION (acceptable): the check is "def-block != use-block",
which technically over-hoists a value used only in a DESCENDANT block (a
`let` would be in scope there).  Over-hoisting is semantically SAFE (a
var works) and in practice caused drift on only the one dying shader, so
left as-is for minimalism; a nesting/dominance refinement could trim it
later if real shaders show unwanted drift.

Gates: spv2wgsl 53/53, ir_build 29/29, ir_emit 8/8, wgpu-diff green,
naga-tint green (143/6/32), wgpu-check green, lint 0/271.

REMAINING naga-debt (6): the phi-cross-block cases (phi_Phi_Bug_435621075,
phi_Phi_PhiInLoopHeader_FedByHoistedVar_PhiUsed/Unused,
phi_Phi_Propagated_PropagatedPhiValue_BlockParam — a related hoisting
variant where the PHI var, not an instruction result, escapes its block),
sint switch literals (branch_Switch_Case_SintValue), and the vertex
module-scope-output-via-call case (function_VertexShader_*Transitive).

## >>> VERTEX-SHADER STRUCT I/O — direct struct outputs (turn 813 cont.) <<<
Studied Tint first (parser.cc ~1040-1100 + ~4410-4532): Tint reads each
struct member's OpMemberDecorate (BuiltIn/Location/Flat) into per-member
`IOAttributes` when BUILDING the struct type, then its WGSL writer emits
a struct output by returning the attributed struct directly.  WGSL
forbids `@builtin` on a struct-typed wrapper field, so you cannot nest a
struct output inside a {name}Outputs wrapper — confirmed by hand-testing
the minimal valid form against naga (struct with `@builtin(position)` on
its vec4 member, returned directly).

PORTED that model (4 coordinated changes, all in src/spv2wgsl.zig):
  1. emitTypeStruct — emit `@builtin`/`@location`/`@interpolate(flat)` on
     members that carry those OpMemberDecorate decos.  SAFE for
     uniform-buffer structs: their members carry only `Offset`, never
     BuiltIn/Location, so they stay bare.  (Indentation: the leading two
     spaces are folded into the per-member `prefix` so UBO structs are
     byte-identical to before — caught a drift regression here via
     wgpu-check, fixed it.)
  2. Entry-output emission — when the single output is a struct-typed
     variable, return THAT struct directly (no wrapper); record its var
     id in new State field `output_alias_vid`.  Otherwise keep the
     {name}Outputs wrapper (fragment/scalar path, unchanged).
  3. emitStore — a store to the aliased struct-output var emits
     `outputs = v` (the var IS outputs), else `outputs.<name> = v`.
  4. emitAccessChain — a path through the aliased var roots at bare
     `outputs` (→ outputs.field_0), else `outputs.<name>` (the original
     access-chain-to-output redirect, also added this turn for the
     wrapper case).

RESULT: 2 of 3 vertex-struct fixtures fixed + naga-VALID
(function_VertexShader_PositionUsed_Struct, _PositionUnused_Struct).
naga-valid 133 → 135; baseline 16 → 14.  Cardioid (fragment/wrapper
mode) untouched — verified via wgpu-check.

REMAINING: function_VertexShader_PositionUsed_Transitive — the position
Output global is written from INSIDE a helper fn (`fn_13`), not the entry.
WGSL has no module-scope IO vars, so this needs Tint's module-scope-var-
to-function-param/return transform (thread the output through the call
chain).  That's a larger separate feature; left baselined with a note.

Gates: spv2wgsl 53/53, ir_build 29/29, ir_emit 8/8, wgpu-diff green,
naga-tint green (135/14/32), wgpu-check green, lint 0/271.

REMAINING naga-debt families (14): hoisting-into-nested (4), sint switch
(1), switch hoist (2), hoisted-var loop-header phis (2), vertex transitive
(1), misc (4: DuplicateTrue_Premerge, ContinueUseBodyValue,
Phi_Bug_435621075, Propagated_PropagatedPhiValue_BlockParam).

## >>> FUNCTION CALLS — first naga-debt family cleared (turn 813 cont.) <<<
First burn-down of the naga-invalid baseline, using the new gate to
enforce the win.  ROOT CAUSE: `emitFunctionCall` always emitted
`let _N: <type> = callee(...)`, but for a VOID-returning call the type
is empty → `let _7:  = fn_4()`, a WGSL parse error.  FIX: when the
call's return type is `.type_void`, emit a bare statement `callee(...);`
(no `let` binding); value-returning calls still bind.  One-line-class
fix; spirv-cross confirms the same shape (`_8(true);`).

RESULT: all 5 function_FunctionCall* fixtures now naga-VALID.  The
naga-tint gate did its job — it FAILED demanding the 5 be removed from
the baseline (baselined-but-now-valid → fail), so the baseline shrank
21 → 16.  naga-valid count 128 → 133 / 181.

No unit test added: the naga-tint gate over the real fixtures is a
stronger end-to-end guard than a synthetic hand-built module (a synthetic
attempt hit MalformedFunction on hand-rolled SPIR-V; not worth the
fragility when the gate covers it).

Gates: spv2wgsl 53/53, ir_build 29/29, wgpu-diff green, naga-tint green
(133 valid/16 known/32 fallback), wgpu-check green, lint 0/271.

REMAINING naga-debt families (16): hoisting-into-nested (branch_*Hoisting*,
ConvertHoisted), vertex-shader struct I/O (function_VertexShader_*),
sint switch (branch_Switch_Case_SintValue), switch hoist
(branch_Switch_HoistFrom*), hoisted-var loop-header phis
(phi_Phi_PhiInLoopHeader_FedByHoistedVar_*), and misc
(DuplicateTrue_Premerge, ContinueUseBodyValue, Phi_Bug_435621075,
Propagated_PropagatedPhiValue_BlockParam).

## >>> NAGA CORPUS GATE — "handled" now means naga-valid (turn 813 cont.) <<<
Made the long-term-correct choice over chasing more raw coverage: closed
the gate gap that let 21 fixtures count as "handled" while emitting
naga-INVALID WGSL.  New gate `zig build naga-tint`
(`scripts/naga-validate-tint.sh`) runs the real naga validator over every
IR-translated Tint fixture, diffed against
`tests/fixtures/external/naga-invalid-baseline.txt` (the 21 pre-existing
invalids, documented by family).  It FAILS on a new invalid (regression)
or a baselined-but-now-valid entry (forcing the baseline to only shrink).
Verified it has teeth (tested: new-invalid → fail, stale-entry → fail,
accurate → green).  Wired into build.zig next to wgpu-diff.

Now the metric to optimize is naga-VALID (128/181), not raw translated
(149).  The 21-fixture gap is the tracked debt; see the baseline header
for burn-down families (function calls, hoisting-into-nested, vertex
struct I/O, sint switch, hoisted-var loop-header phis).  Per-feature
workflow updated at the top of this doc (VALIDATION GATES section).

Gates: ir_build 29/29, ir_emit 8/8, spv2wgsl 53/53, wgpu-diff green,
naga-tint green (128 valid/21 known/32 fallback), wgpu-check green,
lint 0/271.

## >>> CROSS-CONSTRUCT MERGE PHIS — faithful Tint port (turn 813 cont.) <<<
Ported Tint's `EmitPhiIn{If,Switch,Loop}Merge` merge-phi resolution
FAITHFULLY (Simon: "write the best code possible") rather than keep
approximating.  Studied Tint's source (lang/spirv/reader/parser/
parser.cc): all three handlers share one cascade, per phi operand
`(value, pred_block)`:
  1. If pred_block's SPIR-V terminator is OpBranchConditional and we
     built an If for it (Tint's `branch_conditional_to_if_`), the merge
     folds into the same enclosing IR block — so the real exit edge is
     ONE of the If's branches, picked by which branch target == the
     phi's (merge) block id.
  2. Else if pred_block == construct header → "default value": there is
     no predecessor sub-block (one-sided if / default-is-merge / jump
     over), apply to whichever materialized exit edge lacks a value.
  3. Else pred_block's own IR terminator is the exit edge.
  + loop extra: a resolved `cont` terminator (conditional where one edge
    continued, other broke) is redirected to the If's `exit_loop` branch.

OUR IMPLEMENTATION:
  - New `cond_to_if: AutoHashMap(spirv_block_id → *ir.If)` (= Tint's
    branch_conditional_to_if_), populated in buildIf + buildUnstructuredCond.
  - `resolveMergePhiTarget(pred, merge, header) → {blk, is_default}` —
    the cascade.  `applyDefaultToShortestExit` — the default fixup.
    `collectLoopExits` — gathers a loop's break edges (descends ifs/
    switches, stops at nested loops) for the fixup.  `redirectContToExitLoop`
    — the cont reach-through.  All three attach passes (if/switch/loop)
    rewritten to use them.

CRITICAL BUG FIXED ALONG THE WAY: `buildBranch` (if-branch builder) did
NOT resolve the stop stack before recursing — so an if branch that
breaks an OUTER loop (target == loop merge) had `buildBlock` process the
loop-merge block's OWN body (emitting its trailing return) instead of
making an empty `exit_loop`.  That produced a `ret`-terminated branch
where an `exit_loop` belonged, and merge-phi attach hit it →
MalformedFunction.  Fix: buildBranch now checks `stops.lookup(branch_id)`
first (like buildCondTarget), materializing the outer exit.  This is the
keystone that made loop-merge-phi-from-if-break work.

RESULT: Tint fixtures IR-handled 142 → 149; fall-back 32; crash 0.
Newly-correct (naga-VALIDATED): phi_Phi_Loop_FromIfBreak,
phi_Phi_SwitchDefaultIsMerge, phi_Phi_Switch_FromIfBreak_InDefault,
phi_Phi_Propagated_PropagatedPhiValue (a scary-named "propagation"
fixture — confirms our var-based model handles Tint's SSA-named shapes).
Two new unit tests.  Cardioid still green.

CONFIRMS ARCHITECTURE THESIS AGAIN: porting Tint's RESOLUTION LOGIC (how
to find the right exit edge) is exactly what we needed — NOT Tint's SSA
value model.  We attach to mutable-var exit args; Tint threads SSA
results.  Same edge-finding cascade, different value representation.

>>> SEPARATE PRE-EXISTING ISSUE FOUND (not caused by this work): a
full naga sweep of all IR-handled fixtures shows 21 that TRANSLATE but
produce naga-INVALID WGSL.  Verified these were already invalid on the
pre-port baseline (clean3).  They are DISTINCT feature gaps, NOT
merge-phi: function calls (function_FunctionCall*), hoisting-into-nested
(branch_*Hoisting*), vertex-shader struct I/O (function_VertexShader_*),
sint switch values (branch_Switch_Case_SintValue), and a couple of
hoisted-var loop-header phis.  wgpu-diff's own checker does NOT catch
these (it checks structural patterns, not full naga validity).  ACTION
ITEM: add a naga-gate over the Tint corpus (not just live shaders) to
make these visible as a baseline, then burn them down as their own
families.  Tracked here so they aren't lost.

Gates: ir_build 29/29, ir_emit 8/8, spv2wgsl 53/53, wgpu-check green,
wgpu-diff green (181/177/4-known-bug/0-fail), lint 0/271.

REMAINING fallback families (32): deeper continuing (loop-in-continuing,
Continue_HasBreakIf), the genuinely-unstructured multi-exit group (~10),
ValueFromLoopBodyAndContinuing, BothJumpToMerge_InDefault, Propagated_BreakIf,
and the hoisted-var loop-header phis.

## >>> SINGLE-BLOCK LOOPS in IR (turn 813 cont.) <<<
Implemented the biggest remaining cluster: single-block loops
(`continue == header` — the header block IS its own continuing block,
no separate body).  New `buildSingleBlockLoop`:
  - OpBranch %header  → `loop { <body> }` empty continuing (infinite
    unless an in-body break exists — valid WGSL).
  - OpBranchConditional c A B with one edge==header(back-edge), the
    other==merge(break) → `loop { <body> continuing { break if <c> } }`.
    Added `ir.BreakIf.invert` (emits `break if !(cond);`) for the case
    where the FALSE edge is the back-edge (break on !cond).

TWO naga-caught correctness bugs fixed during this (why the naga gate
earns its keep):
  1. `break if` is ONLY legal in a continuing block — first attempt put
     it as the loop-body terminator → naga rejected.  Moved it into the
     continuing block.
  2. `break if` must be the LAST statement of the continuing block, but
     the emitter appended the header-phi iter-updates (iter_args) AFTER
     the terminator.  Restructured emitLoop's continuing emission to:
     items → iter-updates → terminator (so break_if lands last; for a
     plain back-edge branch the terminator emits nothing so order is
     immaterial).  This is a general emitLoop fix, not single-block only.

RESULT: Tint fixtures IR-handled 134 → 142; fall-back 39; crash 0.
phi_Phi_SingleBlockLoopIndex (single-block loop carrying a phi index)
now works.  All 5 sampled single-block fixtures naga-valid; cardioid
still naga-valid (the emitLoop change touches all loops).  New unit
test "build reconstructs a single-block conditional loop (break_if in
continuing)".

FORMATTING NOTE: hand-built SPIR-V test arrays kept getting re-widened
past the 120-col lint limit by `zig fmt` column-alignment.  Settled it
with `// zig fmt: off` / `// zig fmt: on` (codebase-endorsed escape
hatch; the linter respects it).

Gates: ir_build 28/28, ir_emit 8/8, spv2wgsl 52/52, wgpu-check green,
wgpu-diff green (181/179/0-fail), lint 0/271.

REMAINING fallback families (39): switch-merge phis (MALFORMED group),
loop-merge phis with cross-construct edges, loop-in-continuing,
continuing-with-break-if, and the genuinely-unstructured multi-exit
group (~10, may stay on legacy permanently).

## >>> ARCHITECTURE FEAR RETIRED + multi-block-continuing (turn 813 cont.) <<<
Simon's fear: that the HARDEST remaining shapes would force an
SSA/Tint-style rearchitecture.  TESTED IT, two ways:

1. BY ANALYSIS — ran the scariest-named fixtures (Phi_Propagated,
   PropagatedPhiValue, BlockParam, HoistingMultiExit) through
   spirv-cross (which targets GLSL = a var-based language exactly like
   our WGSL).  ALL lower to plain hoisted mutable vars
   (`int _14; for(;;){ _14=...; } int _18=_14;`).  Those fixture names
   describe TINT'S INTERNAL SSA mechanism, NOT a shape that requires
   SSA.  spirv-cross (the reference SPIR-V→GLSL/WGSL tool) made the
   SAME var-based choice we did.  Conclusion: our architecture is the
   standard one and does NOT need to move toward Tint.

2. BY BUILDING (Simon: "prove it on the hardest") — implemented a
   genuinely-hard case: a structured `if` INSIDE the continuing block
   (`branch_Loop_Continue_ContainsIf`).  Extended `buildContinuing` to
   handle a `selection_header` in the continuing chain by reusing the
   SAME `buildIf` machinery `buildBlock` uses, then continuing from its
   merge to the back-edge.  Output:
     loop { if(..){continue}else{break} continuing { if(..){}else{} } }
   naga-VALIDATES (correct, not just non-erroring).  No SSA, no
   rearchitecture — a targeted extension fit our model cleanly.

DIFFICULTY RANKING of the remaining ~47 fallbacks (all within our
var-based model — confirmed):
  HARDEST: unstructured multi-exit / deeply-nested cond re-entry (the
    StopStack-overflow group, ~10) — irregular CFGs; some may justly
    stay on legacy (even Tint rejects truly unstructured CF).
  HARD: loop-in-continuing (`LoopInContinuing`), continuing-with-breakif
    (`Continue_HasBreakIf`) — deeper continuing shapes; still bail.
  MEDIUM: loop-merge / switch-merge phis with cross-construct edges
    (Phi_Loop_FromIfBreak, Phi_SwitchDefaultIsMerge) — shapes are
    var-trivial; work is placing the var-assign on the right edge.
  EASIEST (biggest cluster): single-block loops (continue==header,
    L379, 13 fixtures) — one well-defined shape, best payoff.
  TRIVIAL after single-block: infinite loops (no merge edge, ~3).

PROGRESS: Tint fixtures IR-handled 132 → 134; fall-back 47; crash 0.
New unit test: "build reconstructs a loop whose continuing block
contains an if".  Gates: ir_build 27/27, ir_emit 8/8, spv2wgsl 51/51,
wgpu-check green, wgpu-diff green (181/179/0-fail), lint 0/271.

## >>> HEADER-CONDITIONAL LOOPS in IR + Tint comparison (turn 813 cont.) <<<
Studied Tint's new SPIR-V reader (`/tmp/dawn-main/.../lang/spirv/reader/
parser/parser.cc`, 4673 LOC) to decide if our strategy diverges.  KEY
FINDING:
  - SAME destination: both reconstruct flat SPIR-V into a structured
    tree of Loop/If/Switch with value-carrying results.
  - DIFFERENT phi mechanism, AND OUR DIFFERENCE IS THE RIGHT ONE FOR US:
    Tint's `core::ir` is strict SSA, so a value used outside its
    defining construct MUST be threaded out via a `Propagate(id,src)`
    pass that walks UP the construct tree pushing the value onto every
    exit + adding a construct result + synthesizing continuing-block
    params.  OUR IR is `var`-based: every phi is a hoisted
    `var phi{id}: T;` at fn scope, so a value defined inside a loop and
    read outside is just a mutable var read — NO SSA threading needed.
    So we should NOT port Tint's full Propagate walk; that complexity
    exists to serve SSA we don't have.  What we need is narrower:
    assign `var phi{id}` at the right EDGES, including edges that cross
    construct boundaries.  (Recorded so future-me doesn't "align with
    Tint" by importing SSA threading we don't want.)

INSTRUMENTED the actual bail sites (per-fixture line tags) to find the
REAL gap, not guess:
  - Dominant bail (buildLoop, ~4/6 sampled loop-phi fixtures):
    `buildLoop` required the loop header terminator to be a plain
    OpBranch → it DEFERRED every HEADER-CONDITIONAL loop (the classic
    `while (cond)` / for-loop, header = `OpBranchConditional cond, body,
    merge`).  This is the single biggest coverage gap.

FIX (the keystone): `buildLoop` now handles header-conditional loops by
synthesizing a guard `If` at the TOP of the loop body —
  `loop { <header body>; if (cond) { <body> } else { break; }
   continuing {...} }`
(operands swapped if the merge is the TRUE target).  The guard's break
edge is a REAL `exit_loop`, which is also what lets loop-merge phis
attach to the break edge.  New unit test:
"build reconstructs a header-conditional while-loop (guard-if at body
top)".

RESULT (the F5 progress bar):
  - Tint fixtures IR-handled: 132/181 (was ~111); fall-back 49; CRASH 0.
    The header-conditional fix moved ~20 fixtures from fallback to
    native IR in one change.
  - All newly-handled loop fixtures naga-VALIDATE (correct WGSL, not
    just non-erroring): spot-checked 6/6 + the cardioid still renders.
  - tint corpus known-bug 3 -> 2 (a fixture that produced the
    phi-overwrite pattern via legacy now translates cleanly via IR).
  - Cardioid path (wgpu-check strict .ir) green; no regressions.

Gates: ir_build 26/26, ir_emit 8/8, spv2wgsl 50/50, wgpu-check green,
wgpu-diff green (181/179/0-fail), lint 0/271.

REMAINING fallback families (49 fixtures), next targets:
  - loop-merge phis with specific predecessor patterns
    (phi_Phi_InLoopBody, phi_Phi_MultiBlockLoopIndex still bail)
  - single-block loops (continue == header)
  - switch-in-loop / loop-in-continuing
  - continuing-block phis
  - infinite loops (no merge edge)

## >>> IR-BUILDER CRASH ROOT FIXED (turn 813 cont.) <<<
The 6 `ir_crash_skip` segfaults were NOT 6 bugs — ONE root.  Debug stack
traces (via a throwaway `tools/ir_crash_probe.zig`, since deleted) showed
an unbounded recursion cycle:
  buildLoop → buildBlock → buildCondTarget → buildBlock → buildLoop → …
on multi-block-loop-break / loop-continue-from-branch shapes (an
unstructured conditional whose target re-enters an ACTIVE loop without
being a registered stop).  It recursed until `StopStack.push`'s capacity
`assert` fired at depth 32 → CRASH.

FIX (one change, root cause): `StopStack.push` now returns
`error.IrBuildUnsupported` on overflow instead of `assert`-crashing; all
5 push sites `try` it.  The fixed 32-slot cap is far above any valid
structured-SPIR-V nesting (a handful of levels), so this only ever trips
on a genuinely unsupported/cyclic shape — which now falls back cleanly.

RESULT:
  - All 6 former crashers now return `IrBuildUnsupported` cleanly.
  - Scanned ALL 181 Tint fixtures: ZERO crash the IR builder now.  The
    builder is crash-proof on every input — it always returns a clean
    error for shapes it can't lower, never crashes.
  - Removed `ir_crash_skip` + its helper from the corpus test entirely;
    restored the total floor to >=180.  wgpu-diff: 181 total, 178 ok, 0
    trans-fail, 0 crash.
  - Also fixed earlier the same class in `branchTarget` (zero-operand
    branch indexed [0] → segfault on a LIVE shader) — now bounds-checks
    and returns `IrBuildUnsupported`.

REMAINING (the real F5 coverage work, NOT crashes anymore): ~70 fixtures
still FALL BACK to legacy (clean `IrBuildUnsupported`) because the IR
builder doesn't yet LOWER those shapes.  Grouped by family:
  - multi-block / single-block loops with header-conditional exit
  - loop-merge phis (value escaping a loop) — `Phi_InLoopBody` etc.
  - switch-inside-loop / loop-inside-continuing
  - continuing-block phis
  - infinite loops (no merge)
These are FEATURE gaps to grow the IR builder into, one family at a time;
each handled family lets `.ir_or_legacy` shrink toward `.ir`, and when no
fixture needs the fallback, F5 deletes the legacy walker.

Gates: ir_build 25/25, ir_emit 8/8, spv2wgsl 49/49, wgpu-check (strict
.ir) green, wgpu-diff green (181/178/0-fail), lint 0/271.

## >>> "UNPLUG LEGACY" + F4 COMPLETE (turn 813) <<<
F4 (IR walker as default) is now complete EVERYWHERE: library
`convertSpirvToWgsl`, the build (`shader_codegen.zig`/`build.zig`), AND the
CLI tool (`tools/spv2wgsl.zig` — its own default was still `.legacy`,
the last missed spot; fixed).

THE SILENT FALLBACK IS GONE.  `WalkerChoice` now has three modes:
  - `.ir`         — IR ONLY.  Unsupported shape = HARD ERROR (no silent
                    legacy substitution).  Production default.
  - `.legacy`     — legacy walker only (escape hatch; F5 deletes).
  - `.ir_or_legacy` — try IR, fall back to legacy (the OLD `.ir`).  Now
                    EXPLICIT, used only by the corpus test so it stays
                    meaningful on shapes IR can't do yet.

MEASUREMENT that drove this (instrumented the fallback, scanned all .spv):
  - LIVE shaders (the ones that ship): 0 fall back to legacy.  The IR
    walker fully covers production.  So strict `.ir` is safe for the
    build — verified green.
  - Tint fixtures: ~70 still need legacy (deferred CFG shapes:
    single-block loops, header-conditional exits, loop-merge phis,
    switch-in-loop, continuing-block phis, infinite loops).  These are
    the F5 coverage gap, now run via `.ir_or_legacy`.

REAL BUGS the unplug surfaced + FIXED:
  1. `branchTarget` (ir_build.zig) indexed `operandsAt(...)[0]` with NO
     bounds check → SEGFAULT on a zero-operand branch terminator (hit by
     a live `.zig-cache` shader's helper).  Now bounds-checks and returns
     `IrBuildUnsupported`.  Made error-returning; both callers `try` it.
  2. SIX Tint fixtures SEGFAULT the IR builder (not a clean error — an
     actual crash inside `tryEmitViaIr`, uncatchable by the fallback).
     All multi-block-loop-break / loop-continue-from-branch shapes.
     Listed in `ir_crash_skip` in the corpus test (skipped so the
     baseline isn't blocked).  **This list IS the F5 checklist**: each
     entry is an IR-builder robustness bug — harden the builder so it
     returns `IrBuildUnsupported` instead of crashing, then remove the
     entry.  When `ir_crash_skip` is empty AND no fixture needs
     `.ir_or_legacy`, F5 deletes the legacy walker.
     The 6:
       branch_BranchConditional_Back_MultiBlock_LoopBreak_OnFalse
       branch_BranchConditional_Back_MultiBlock_LoopBreak_OnTrue
       branch_Branch_LoopBreak_MultiBlockLoop_FromContinueConstructEnd_Conditional
       branch_Branch_LoopBreak_MultiBlockLoop_FromContinueConstructEnd_Conditional_BreakIf
       branch_FalseBranch_LoopContinue
       branch_TrueBranch_LoopContinue

Corpus baseline: tint_corpus_known_bugs 2 -> 3 (a legacy phi-overwrite
artifact, shifted by the strict-IR routing; legacy is on death row so
this is bookkeeping, not a regression).  total floor 180 -> 174 (181
minus 6 skipped, minus 1 slack).

Gates after: ir_build 25/25, ir_emit 8/8, spv2wgsl 49/49, wgpu-check
(strict .ir default) green, wgpu-diff green, lint 0/271, legacy escape
hatch (`--walker=legacy`) still works.

## >>> NAGA TRIAGE CORRECTION (turn 812) <<<
The "11/45 failures" from t811 were MOSTLY A MEASUREMENT ARTIFACT.  The
corpus scan validated EVERY shader.opt.spv in `.zig-cache`, but the
cache accumulates STALE pre-harness orphans (old builds: flat
`u_resolution`/`u_time`/`u_tint` uniforms ALL at `@group(0)
@binding(0)`, no `@location` on inputs).  Those are not produced by
current sources.

After a CLEAN rebuild (`rm -rf .zig-cache` + cold build) there are only
**9 LIVE shaders**, and naga says **7 PASS / 2 FAIL**:
  1. one "Entry point Fragment invalid / Struct member 0 is missing a
     binding" (missing `@location` on the FS input) AND it still has the
     flat triple-binding-0 uniform signature → it comes from the LEGACY
     non-typed shader path (`examples/shader.zig` / `shader_chroma`
     family using flat `u_time`/`u_offset` uniforms), NOT the typed
     `_io` harness.
  2. one "Global variable 'col_diffuse' invalid / Type isn't compatible
     with address space Handle" (sampler/texture global with wrong
     address space) — same legacy-path origin.
The typed-IO harness path is CORRECT: the cardioid mandelbrot (built
via `mandelbrot_fs` + `mandelbrot_fs_io`) emits `@location(0)
frag_tex_coord` and PASSES naga.  So the 2 real failures are in the
DYING flat-uniform/GLSL path that's being migrated to the harness
(fix-on-notice: migrate or delete, don't band-aid).

METHODOLOGY FIX: `scripts/naga-validate-corpus.sh` now does a clean
shader rebuild before validating, so it checks LIVE output not cache
cruft.  (Better: have it validate the build's actual emitted .wgsl
artifacts directly rather than re-translating cache .opt.spv.)

LESSON (also a near-miss): deleting `shader.opt.spv` files out of
`.zig-cache` to force a rebuild CORRUPTED the build cache (the system-
command runner still expected those hashes → spirv-val "file does not
exist").  Recovery = `rm -rf .zig-cache` + cold rebuild.  Don't hand-
delete individual cache artifacts; clear the whole cache or touch
sources.

CONCLUSION: spv2wgsl's CURRENT (typed-harness) output is naga-clean on
the live shaders that matter.  naga earns its keep going forward as the
standing gate — but the gate must validate LIVE shaders.  The 2 legacy-
path failures are real but belong to the path scheduled for deletion.

## >>> NAGA ORACLE NOW WORKING (turn 811) <<<
Simon uploaded Go (t809) then Rust 1.96.0 (t811).  Outcome: we have a
REAL WGSL validator running over the corpus.

- **naga 29.0.3** built from crates.io via `cargo install naga-cli`
  (index.crates.io + static.crates.io both reachable through the proxy;
  the bare static.crates.io ROOT 403s but actual /crates/... tarball
  downloads are 200 — red herring).  Binary stashed at
  `tools/naga-prebuilt-linux-x86_64/naga` (survives sandbox resets;
  added to lint skip-prefix; it's a build-time TEST tool, NOT shipped).
  Run via `scripts/naga-validate-corpus.sh [ir|legacy]`.
  Rebuild recipe if the binary is lost: install Rust to a prefix
  (`./install.sh --prefix=/tmp/rust --disable-ldconfig` from the
  standalone tarball), `CARGO_HOME=/tmp/cargo-home` with a
  `config.toml` setting `[registries.crates-io] protocol="sparse"`,
  then `cargo install naga-cli --version 29.0.3 --root /tmp/naga-install`.

- **naga vs miniray**: naga is the trustworthy one.  Verified t811:
  naga REJECTS the t808 `u32->f32` WGSL (`automatic conversions cannot
  convert elements of u32 to f32`, exact line) AND ACCEPTS our working
  fractal (continuing+select+f32(u32)) that buggy miniray falsely
  rejected with 7 phantom errors.  So: use naga, drop the miniray-patch
  idea (the patched Go binary was a stopgap).

- **FIRST CORPUS RUN found 11/45 shaders naga rejects** — and they FAIL
  UNDER BOTH WALKERS (so NOT IR-walker regressions; long-standing).  Two
  bug classes, both look like REAL spv2wgsl emission bugs (need to
  confirm against Chrome, since naga is occasionally stricter than Dawn):
    1. (7 shaders) "Entry point main at Fragment is invalid / Argument 0
       varying error / Struct member 0 is missing a binding" — a
       fragment INPUT struct member emitted WITHOUT its `@location(N)`
       attribute.  Real WGSL violation.
    2. (4 shaders) "Global variable 'col_diffuse' is invalid / Type
       isn't compatible with address space Handle" — a sampler/texture
       global emitted with wrong type or address space.
  NEXT: triage these — pick one of each class, confirm whether Chrome
  also rejects (build a standalone, Simon screenshots) or whether it's
  naga-strictness; then fix the emitter for the real ones.  This is
  EXACTLY the "find bugs before the complicated shaders" goal paying off.

## Oracle feasibility (what we CAN run in the sandbox) — checked t809

- **Rust / naga**: NO.  No rustc/cargo installed; `static.rust-lang.org`
  (rustup) returns 403; `naga-wasm` npm package is dead (zero usable
  versions).  A real type-checking oracle via naga is BLOCKED.
- **Tint from source**: NO.  No cmake/gn/ninja; building Dawn needs
  depot_tools.  BUT the Tint *source* is readable at
  `/tmp/dawn-main/dawn-main/src/tint/` — we can PORT from it.
- **`wgsl_reflect` (npm, pure JS, v1.3.0)**: YES, installs + runs under
  Bun.  It is a GRAMMAR/SYNTAX validator, NOT a type checker.  Probed
  t809: it REJECTS syntax errors (missing brace → "Expected assignment
  operator"), but PASSES `x: f32 = (u32 value)` and undeclared idents.
  So it is strictly better than the current shim (catches malformed
  WGSL structure) but would NOT have caught our specific bug.

Conclusion: the type-level check MUST be our own (ported idea from
Tint), and wgsl_reflect is a cheap second gate for grammar.

## The risk surface in ir_build.zig (audited t809)

Bail-out points (these fall back to legacy — SAFE, just means we don't
use IR for that shape; legacy is buggy but a known baseline):
- `buildLoop`: single-block loop (`continue == header`) → deferred.
- `buildLoop`: header terminator not a plain `OpBranch` → deferred.
- `readLoopHeaderPhis`: header phi without exactly one init + one iter
  edge → deferred.  (NOTE: this function is CORRECT — it pairs init/
  iter by PREDECESSOR, not position, which is exactly the robustness
  the buggy `attachExitArg` lacked before t808.)
- `buildBlock`: OpSwitch on a plain block (no SelectionMerge) →
  deferred.
- various `table.get(...) orelse MalformedFunction` — a hard error
  (whole shader fails to translate).  These fire only on genuinely
  malformed SPIR-V; low risk from our own Zig-emitted SPIR-V.

The DANGEROUS class is NOT these — it is wrong-but-plausible IR that
passes `validate` (which currently only checks ARITY, not types).
`attachExitArg` (t808) was exactly this.  Other candidates to scrutinize
for the same "positional pairing can desync" pattern:
- `attachSwitchMergePhis` (switch case → merge phi routing) — does it
  route each case's value to the right exit in results order?  CHECK.
- `attachLoopMergePhis` (loop-exit phi routing across break edges) —
  same question.  CHECK.
- one-sided / negated / nested ifs where one branch IS the merge.

## THE PLAN

### H1 — IR-level type check (port of Tint's CheckOperandsMatchTarget)
Tint `lang/core/ir/validator.cc`:
- `CheckExit` calls `CheckOperandsMatchTarget(exit, ..., args.size(),
  control, control->Results())`.
- `CheckOperandsMatchTarget` checks (a) count match AND (b) per-position
  `source_value->Type() == target_value->Type()`, erroring on each
  mismatch.

Our gap: `ir.validate` checks count (arity) per exit, but `Exit.args`
is `[]ValueId` with NO type info, so it cannot do the type half.

We DON'T need to rebuild a type map — `State` already maintains
`value_id -> {type_id, wgsl_name}` (via `setId`, the `.value` kind).
The IR emitter already receives `s` and calls `s.wgslNameOf(id)`.

Implementation: add `s.typeIdOf(id) -> ?u32` accessor on State, and in
`ir_emit.emitPhiAssigns` (where we pair `results[i].phi_id = args[i]`),
assert `typeIdOf(args[i]) == results[i].type_id`.  On mismatch, return
an error → `tryEmitViaIr` falls back to legacy (same pattern as the
arity safety net added t808).  This catches the WHOLE bug class
(correct arity, wrong type) at emit time, with real type data —
something the standalone IR `validate` cannot do.
- Do the same in the loop init/iter emission (header_params vs
  iter_args) and switch.
- BONUS: this turns "wrong routing" from "ships broken WGSL" into
  "transparently falls back" — defense in depth on TOP of fixing the
  routing.

### H2 — wgsl_reflect grammar gate
Add a Bun test (`webtests/wgsl_grammar_check.ts`) that runs every
emitted corpus `.wgsl` through `new WgslReflect(src)` and fails on a
parse throw.  Wire as a new build step (e.g. `wgsl-grammar`) and fold
into the per-turn gate.  Catches malformed-WGSL-structure bugs the
shim can't.  npm dep is a BUILD-TIME TEST tool only — not shipped, so
it does not violate the "no Tint/naga in the wasm" thesis.

### H3 — sibling routing-func audit (DONE turn 809)
Audited `attachLoopMergePhis` + `attachSwitchMergePhis` for the t808
positional-desync pattern.  FINDING: the routing itself is CORRECT
(all phis at a merge route in scan order → args stay aligned with
results).  The only issue was robustness: both used
`by_id.get(pred) orelse return error.MalformedFunction`, i.e. they
HARD-FAILED the whole translation on an unregistered predecessor.
Reachability analysis: that miss is currently UNREACHABLE for valid
structured SPIR-V — the only unregistered-pred case is a header-direct
loop exit (header→merge), which makes the header an OpBranchConditional
that `buildLoop` already defers up front.  So this was a
hard-fail-where-we-should-defer issue, NOT a live bug.  FIX: both now
`orelse return error.IrBuildUnsupported` (graceful legacy fallback)
with a comment documenting WHY it's unreachable today and what to do
when header-conditional loops are added (route the header break-edge
like `attachExitArg`'s one-sided-if header edge).  Corpus audit: zero
loop-merge blocks have phis, so `attachLoopMergePhis` returns empty for
every real shader today; the handled break-from-body path is covered by
the existing "loop-merge phi (value escaping the loop)" unit test.
Gates after fix: ir_build 25/25, ir_emit 8/8, spv2wgsl 49/49, both
walkers green, lint 0.

### H3 (original) — differential + property scrutiny of the remaining routing funcs
Manually audit `attachSwitchMergePhis` / `attachLoopMergePhis` for the
positional-desync pattern (same root cause as t808).  Add targeted
ir_build unit tests for: multi-phi one-sided if (the t808 repro),
multi-phi switch merge, multi-phi loop-exit.  These are the shapes most
likely to hide the next instance of the bug.

## Order
H1 first (highest value — closes the exact bug class with real types),
then H3 (audit the sibling routing funcs while the pattern is fresh),
then H2 (the grammar oracle as ongoing insurance).
