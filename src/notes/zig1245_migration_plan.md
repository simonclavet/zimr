# Zig 0.17.0-dev.1245 migration — working plan

## The compiler change (root cause)
1245 bans `@Vector` fields in `extern struct` on CPU targets (wasm32 + native):
"extern structs cannot contain fields of type '@Vector(N,f32)' — vectors have
no guaranteed in-memory representation." Fires at LAYOUT RESOLUTION, only on CPU
(spirv32-vulkan still accepts it). Vector<->array coercion still works both ways.

Also newly strict in 1245:
- `@bitCast` from ANY struct is banned (even scalar-field extern structs like Color).
  Fix: read fields directly.
- `&vec[i]` types as `*align(A:0:N:0) f32` (vector-element pointer), won't coerce
  to `*f32`. Fix: copy to scalar local, write back.
- `std.hash.crc.Crc32` removed; use `std.hash.crc.@"CRC-32/ISO-HDLC"` (PNG).

## Strategy
- Schema UBOs: `extern struct` -> plain `struct` (keep Vec fields). GPU bytes via
  shader_interface wire serializer (wireOf/wireSizeOf/wireOffsetOf), NOT asBytes/@sizeOf.
- SPIR-V side keeps an extern `UboWire` mirror (legal there) so WGSL is byte-identical.
- Vertex/storage structs that must stay extern (InstanceVertex, kompute Buffers):
  convert `[N]Vec` fields -> `[N][M]f32` (extern-legal, identical bytes); bind Vec
  locals for math (arrays have no arithmetic).

## spv2wgsl regression (FOUND + FIXED)
Plain-struct module Ubo now differs nominally from extern UboWire uniform, so SPIR-V
inserts OpCopyLogical (opcode 400) to copy between them. spv2wgsl didn't handle it ->
emitted `array<vec4<f32>,4>()` DEFAULTS instead of real mvp/light_vp/normal_matrix
(would break shadows on-device). FIX: added CopyLogical=400 to Op enum + wired
alongside CopyObject at 4 sites (root-trace, def_off, dispatch->emitLoad, opShape).
OpCopyLogical -> plain WGSL assignment `result = operand` (WGSL is layout-nominal-free).
VERIFIED: fresh transpile UNHANDLED=0, `_185 = _184` with real u.field_N flowing.

## LLVM native ReleaseFast crash (compiler bug — needs minimal repro)
`shadowmap_sw_verify` (native_verify.zig) ReleaseFast SEGFAULTs during LLVM codegen
(rc=139, raw segfault, no Zig panic). Debug compiles+runs clean; self-hosted
`-fno-llvm -fno-lld` ReleaseFast compiles+runs clean (0-byte diff). RESOLVED on
the current 1245 toolchain: the workaround (use_llvm=false/use_lld=false) has been
removed; the exe builds with the default LLVM ReleaseFast backend and verifies
0-byte-diff. See the resolution note further down. No repro to file.

## GATES for shadowmap_sw deliverable — ALL GREEN
- lint: green
- shadowmap-sw-standalone: rc=0, 4.85MB, 0 UNHANDLED in embedded WGSL
- shadowmap-sw-verify: 0 shadow-map + 0 image bytes differing (comptime==runtime)
- smoke -Dfocus=shadowmap_sw: PASS, ClobberScan clean, wgpu_smoke PASSED
- check: NO REGRESSIONS + wgpu_smoke PASSED; corpus refreshed 46 live + 86 carried

## zig build test — tree-wide 1245 sweep (IN PROGRESS)
FIXED:
- codecs.zig Crc32 (1245 std rename)
- ui.zig editVector2Field vector-element pointer
- shader_introspect validator/autoMaterial test Ubos -> plain struct
- mandel_sidebyside + rt_sidebyside `@bitCast([N]Color)` -> field-read loop + branch quota
- compute_host test Buffers [256]Vec2 -> [256][2]f32 + Vec2 math locals
PENDING:
- fluid_sort/sort_kernels.zig Buffers [50000]Vec2 x5 fields -> [N][2]f32 + ~20 math sites
- verify compute_host upload(.pos,&zeros[3]Vec2)/readLatest(->[]const Vec2) still typechecks
- re-run zig build test to green

## Systemic improvement (per Simon)
zm should be importable in almost all files -> Vec/Vec2/Vec3 aliases available ->
NO lint:off prefer-vec needed. shader_interface.zig currently claims "shader-safe,
no zm import" and uses raw @Vector with lint:off. INVESTIGATE: can shader_interface
import zm? If not, why? Fix the root cause so lint:off disappears.

## Zip: zimr580 (recipe: exclude .zig-cache zig-out .git tools/zig-x86_64-* 
## tools/bun-linux-x64 tools/naga prebuilt/standalone/*.html node_modules intake)

## UPDATE — session progress (careful pass)

### MAJOR 1245 API break DISCOVERED: struct typeinfo is now parallel arrays
`@typeInfo(T).@"struct"` no longer has `.fields` ([]StructField with .name/.type).
1245 replaces it with PARALLEL ARRAYS (std/lang.zig Type.Struct):
  field_names: []const [:0]const u8
  field_types: []const type   (same length as field_names)
  field_attrs: []const FieldAttributes  (.@"comptime", .@"align", .default_value_ptr)
  decl_names:  []const [:0]const u8
Iterate: `for (si.field_names, si.field_types, si.field_attrs) |n, T, a| {...}`.
Build a struct: `@Struct(.auto, null, &names, &types, &attrs)` (new builtin form).
Default value: `a.defaultValue()` or cast a.default_value_ptr.
STATUS: bridge.zig + shader_interface production code already on new API (prev session).
Fixed shader_interface merge TEST (was last old-API `.fields` site). Sweep confirmed
only 1 old-API site tree-wide; `layout.fields` elsewhere is zimr's OWN struct field (fine).

### SYSTEMIC FIX: zm now imported by shader_interface (removes all lint:off)
build.zig: shader_interface_mod now `.addImport("zm", zimrmath_mod)` (added after
zimrmath_mod decl). shader_interface.zig: `const zm=@import("zm"); const Vec=zm.Vec;
const Vec2=zm.Vec2;` — all 6 raw @Vector + lint:off REMOVED; writeWire uses
zm.assert(ok,@src()) not bare unreachable. 15 tests pass. zm is self-contained
(build_options via addOptions, std.log branch comptime-dead on SPIR-V) so shader-safe
tier holds. This is the RIGHT fix Simon asked for: Vec available almost everywhere.

### Still PENDING for zig build test green
- fluid_sort/sort_kernels.zig Buffers [50000]Vec2 x5 -> [N][2]f32 + ~20 Vec2 math locals
- compute_host upload(.pos,&zeros)/readLatest typecheck with [256][2]f32 (verify)
- full `zig build test` sweep for any other struct-typeinfo or extern-vec cascades

## LLVM native crash — RESOLVED on 1245 (was: workaround shipped)
HISTORY: `shadowmap_sw_verify` native exe SEGVed (rc=139) in ALL optimized LLVM
modes (ReleaseFast/Safe/Small) on dev.956–early-1245; Debug + self-hosted
`-fno-llvm` were clean. Bisected then: crash was in LLVM CODEGEN not LLD
(`-fno-lld` still crashed), not CPU-feature-specific (`-mcpu=baseline` still
crashed); trigger was THIS module's optimized IR interacting with LLVM, not
compiler_rt (a u128-heavy exe compiled clean).
RESOLUTION: gone on the current 0.17.0-dev.1245 toolchain. The build.zig backend
override (use_llvm=false, use_lld=false) has been REMOVED — smsw_verify_exe now
uses the default LLVM backend at `.ReleaseFast`. Confirmed by a forced clean
rebuild: compiles with no SEGV and verifies 0-byte diff. Broader toolchain sanity
(hello-world): native LLVM ReleaseFast, native self-hosted, and wasm ReleaseSmall
all build+run. Nothing left to bisect or report upstream.

## kompute BoundView (robustness enhancement)
src/kompute.zig: added BoundView(FieldT)/isVecBuffer — `bind` now presents a
`[N]@Vector(M,f32)` view over `[N][M]f32` storage (byte-identical; align(M*4) makes
the reinterpret sound). Lets a kompute Buffers declare vector arrays as extern-safe
`[N][M]f32` with ZERO kernel-body churn (pos[i] stays Vec2). Current kompute Buffers
(fluid_sort, compute_host test) are already PLAIN structs with [N]Vec2 (prev session)
so BoundView passes them through unchanged — it's forward-defense for any extern
storage buffer. fluid_sort standalone builds clean (0 UNHANDLED); zig build test green.

## STATUS: all gates green on 1245
lint ✓ | shadowmap-sw-standalone ✓ (0 UNHANDLED) | shadowmap-sw-verify ✓ (0-diff)
smoke shadowmap_sw ✓ | check ✓ (no regressions, wgpu_smoke, corpus 132) | zig build test ✓

## DEVICE BUG (Dawn) — unreachable-code WGSL, FIXED
Device (Chrome/Dawn) rejected the launcher: `Error while parsing WGSL: :533
warning: code is unreachable / return S2428();` → cascading InvalidRenderPipeline
"pbr3d_pipe" / InvalidCommandBuffer. The mock wgpu_smoke doesn't run Dawn's Tint
parser so it passed — this is why on-device testing caught it.

ROOT CAUSE: spv2wgsl emitted a `.unreach` block's fall-through `return T();` even
when the preceding structured code already diverges on every path — e.g. a loop
body ending in `if (c) { continue; } else { break; }`. naga (Firefox) WANTS that
return; Dawn/Tint (Chrome) REJECTS it as unreachable code. Parser divergence.

FIX (src/spv2wgsl.zig, IR emitter): added `itemsAlwaysDiverge`/`blockAlwaysDiverges`/
`constructAlwaysDiverges`/`termDiverges`. `emitBlock` now skips a `.unreach`
terminator when the block's items already provably diverge (last item is an if/
switch whose every branch diverges). CRITICAL nuance: `exit_if`/`exit_switch` fall
through to their construct's MERGE (NOT divergence); only `exit_loop`/`cont`/`ret`/
`kill`/`branch`/`unreach` truly leave. A conditional `break_if` can fall through, so
it doesn't diverge either. Two regression tests added (suppress-when-diverges,
keep-when-one-arm-falls-through) — both pass; 53/53 spv2wgsl tests green.

VERIFIED: rt_fs (the S986 shader) drops 2 unreachable returns, keeps 1 reachable
function-end return. All 17 launcher apps + launcher rebuild clean (0 UNHANDLED,
0 bad patterns). corpus refreshed (48 live + 86 carried), check green, test green.
LESSON: wgpu_smoke uses a mock, not Tint — WGSL-validity regressions need on-device
or a real Tint/naga parse in CI to catch. (Possible future: run naga+tint over the
corpus WGSL in `check`.)

## DEVICE BUG #2 (Dawn) — sampler binding collision, FIXED
helmet_sw device error: `entry point 'entry' references multiple variables that
use the same resource binding '@group(1)', '@binding(1)'`. The 6-texture PBR
fragment shader assigned textures at bindings 0,1,2,3,4,5 (spacing 1), but each
Sampler2D expands to a texture at N + a paired sampler at N+1 (zspv_rewrite
synthesizes the sampler half). So texture0@0's sampler@1 collided with the next
texture (metallic_roughness)@1. Latent bug — only triggered by 2+ unpinned
samplers; the whole prior corpus had ≤1 free sampler per shader.

ROOT CAUSE: the free-sampler binding solver advanced by 1 per Sampler2D instead
of 2. THREE copies of this solver had to be fixed in lockstep (they MUST agree or
the host BGL mismatches the WGSL @group/@binding):
  1. src/shader_introspect.zig `solveLayout` (host runtime BGL) — the live path
  2. tools/gen_shader_externs.zig module-level sampler loop (emits zm_binding)
  3. tools/gen_shader_externs.zig `_Spirv` branch sampler loop
Each now finds the lowest N where BOTH N and N+1 are free, claims both, advances
by 2. Result: textures 0,2,4,6,8,10; samplers 1,3,5,7,9,11 — no collision.
Updated 3 solveLayout tests (they encoded the old dense-by-1 spacing); all 23
shader_introspect tests + full `zig build test` green. helmet_sw / deferred_render
/ skinned_mesh / launcher rebuilt: 0 UNHANDLED, 0 duplicate (group,binding).
(autoMaterialBindGroupLayout is test-only, not on the live path — left as-is.)

Both device bugs (#1 unreachable-code, #2 binding collision) are Tint-only; the
mock wgpu_smoke can't catch either. Running real Tint/naga over the corpus in
`check` remains the recommended CI hardening.

## Device bug #3: sampler texture/sampler TYPE MISMATCH (Dawn-only) + solver unification

Symptom (helmet_sw): after #2 fixed the collision, Dawn still rejected
`pbr3d_pipe` — "Binding type in the shader (sampler) doesn't match the type in
the layout (texture)" at `@group(1) @binding(3)`.

Root cause: helmet's 6-texture PBR runs through draw3d's HAND-ROLLED
`pbr3d_pipe` (embeds `pbr_fs.wgsl`), and draw3d's `makeMaterialLayout` +
material bind-group builder used a stale BLOCK scheme — textures @0-5, samplers
@6-11 — while the schema-driven WGSL is INTERLEAVED (texture@2i, sampler@2i+1).
So binding 3 was a sampler in the shader but a texture in the host layout.

Fix (draw3d): both `makeMaterialLayout` and `buildMaterialBindGroup` now derive
from `pbr3d.material_tex_bindings`, a comptime `[6]u32` computed from
`solveLayout(pbr_fs_io)` (the SAME authority the WGSL uses). Host-vs-WGSL drift
is now structurally impossible, exactly like `FsUbo`. Locked by a regression
test ("pbr3d material bindings are the schema-derived interleaved pairs").

### The real structural fix — ONE sampler solver

Bugs #2 and #3 were both DRIFT between separate copies of the same sampler-
pairing algorithm. There were THREE: `shader_introspect.solveLayout` (host BGL)
+ two inlined in `tools/gen_shader_externs.zig` (module-level + `_Spirv`). They
had to stay byte-identical by hand — and didn't.

Unified into `shader_interface.solveSamplerSlots(comptime SamplersT) ->
[N]SamplerSlot`. shader_interface is the right home: both shader_introspect and
gen_shader_externs already import it, and it carries no host (wgpu) deps, so the
codegen tier stays clean (importing shader_introspect would drag in wgpu.zig —
the original reason the solver was duplicated). All three call sites + draw3d's
`material_tex_bindings` now delegate to it. Types added: `SamplerSlot {group,
binding, origin}`, `SamplerSlotOrigin`, `samplerFieldCount`.

Latent bug the unification surfaced & fixed: a PINNED/SHARED sampler now claims
BOTH its texture cell N and its paired-sampler cell N+1 (a Sampler2D always
occupies both on the GPU via zspv_rewrite). Previously only N was claimed, so a
free sampler could be assigned N+1 — colliding with a pinned sampler's sampler
half. No live shader hit it, but the corpus re-pinned cleanly and it's now
correct by construction.

Verified: `solveSamplerSlots(pbr_fs_io.Samplers)` == WGSL `@group(1)` decorations
== host `material_tex_bindings`: tex@0,2,4,6,8,10 / sampler@1,3,5,7,9,11, all
`texture_2d<f32>`. Gates: check (corpus 50 live + 86 carried, NO REGRESSIONS),
`zig build test`, lint, shadowmap-sw-verify (0-byte diff), and helmet_sw +
launcher + all 17 app standalones (0 UNHANDLED) all green.

All THREE device bugs are Tint-only; the mock wgpu_smoke catches none of them.
NEW build-time tripwire, WIRED INTO `zig build check`: `tools/spv2wgsl_check.zig`
(now built + run by the check step, `spv2wgsl_check our-corpus`) runs
`checkWgslBindings` over every corpus WGSL and fails the build on any duplicate
`@group@binding` cell (naming BOTH colliding vars) — exactly Dawn's "multiple
variables use the same resource binding". check now reports e.g. `272 ok, 0
failed`. This turns bug #2's class from an on-device error into a build-time one.
(It deliberately does NOT assert a texture@N/sampler@N+1 pairing — lone samplers
like shadow-comparison and deferred g-buffer inputs are legitimate; host-vs-WGSL
agreement for the material path is locked instead by `draw3d.material_tex_bindings`
sharing the solver.) Also fixed while here: a `readFileAlloc` → `@alignCast(u32)`
panic in spv2wgsl_check + both sites in tools/spv2wgsl.zig (copy into a naturally
4-aligned `[]u32` instead), and a duplicate `expectEqualStrings`/`wgpu` member in
shader_introspect.zig. The unreach and OpCopyLogical bugs are transpiler semantics,
not binding shape — running real Tint/naga over the corpus in `check` remains the
top remaining CI hardening (naga isn't in the sandbox / fetchable).
