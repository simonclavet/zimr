# 2307: shader decorations dropped — findings and plan

Status: COMPLETE (Sep 26). Steps 1-2 and Plan v2 A-F done; G (upstream report) dropped by Simon. Ready to archive.

## Symptom (device)

Every pipeline fails `CreateRenderPipeline`: `Binding doesn't exist in [BindGroupLayout
"resources_bgl"] ... @group(0) @binding(1) ... "shapes_fs"`. In-sandbox: 69/69 WGSL files have
only `@group(0)`, 20 have two resources on one `(group, binding)`. `check` and smoke were green.

## Mechanism (read in the compiler source at 392b17125, `src/link/Spirv/Flush.zig`)

The rewritten SPIR-V linker (`b3727d9bd1 spirv: rewrite linker`) processes each nav's MIR on its
own and copies an annotation ONLY when its target is a result defined in that same MIR (`load()`:
annotations are indexed `by_target` and emitted in the `for (results.items)` loop). An asm
`OpDecorate %target ...` inside a function whose `%target` is a GLOBAL (another nav) targets an id
that is not a result of the function's MIR, so it is collected and never emitted. No error.

- `OpName` in the same asm block APPEARED to survive - it did not: the assembler puts debug-class
  ops in the function BODY, which is copied verbatim (an OpName inside a function, invalid position).
- An asm `OpDecorate` on an id created in the SAME asm block still works - that is how
  `std.spirv.specConst` does `SpecId`, and it is the only asm decoration left in std.
- Debug and ReleaseFast behave the same.

zimr decorated every Location / DescriptorSet / Binding that way (`shader_builtins.location` /
`.binding`, called from the generated `setup()` and `installSpirvEntry`). Builtins are unaffected:
they come from `std.spirv.position_out` etc., compiler-owned named `@extern`s.

## What upstream intends

- `std.builtin.ExternOptions.decoration` is `union { location, flat, descriptor{set, binding} }` -
  exactly zimr's three needs. Upstream's `test/behavior/spirv.zig` binds only through it.
- The old `std.gpu` asm `location()` / `binding()` helpers (zimr's are copies) are gone from std.
- 2307 REJECTS `@extern(*addrspace(.constant) const u32, ...)`: "extern in 'constant' address space
  must point to an opaque SPIR-V type". UniformConstant is for real image/sampler handles. zimr's
  `u32` sampler placeholder + `zspv --rewrite-samplers-wgsl` survives only as a bare `extern const`,
  on a loophole.
- The 956 blocker (opaque `@extern` folding to OpUndef) is GONE: `@SpirvType` texture + sampler
  `@extern`s with `.descriptor` materialize, `sampleLod`/`sampleLevel` lower to native
  `OpSampledImage`, and spv2wgsl emits correct `textureSample` / `textureSampleLevel`.

## Verification done (three independent angles)

1. Source: the Flush.zig mechanism above explains every observation, including the OpName one.
2. Minimal probes: asm decoration on a global dropped (Debug + ReleaseFast); `@extern` +
   `.decoration` correct; spv2wgsl lowers it to the right `@group/@binding/@location`.
3. Real shader A/B through the real pipeline (ssao_blur_fs + its real generated externs.zig,
   exact build-obj flags, real zspv, real spv2wgsl):
   - control (as generated): UBO and `src` both at `@group(0) @binding(0)` - reproduces the device.
   - `@extern` for UBO + locations: `@group(2) @binding(0)` for the UBO, locations right.
   - native texture/sampler as FILE-SCOPE `@extern`s, sampled from a `noinline` helper (the shape
     of the generated `src(uv)` accessors): all groups/bindings right, no zspv.
   - trap found: calling `texture2D()` / `sampler()` at RUNTIME leaves them as WGSL functions that
     return a texture handle + a function-scope `var` of handle type - both illegal WGSL. The
     generator must declare them at file scope. Guard against it in spv2wgsl.

## Plan

1. `tools/gen_shader_externs.zig`: every interface variable becomes a file-scope `@extern` with its
   decoration, numbers from the same solvers (`uniformGroupForSchema`, the sampler solver):
   inputs/outputs `.location`, UBO/loose uniforms `.descriptor`, each sampler field a texture
   `@extern` at `(group, N)` + a sampler `@extern` at `(group, N+1)` - the host's convention in
   `shader_runtime.zig`, unchanged. Reads become `.*`; UBO field reads auto-deref. `setup()` and the
   `zm_location` / `zm_binding` calls go. Accessors call `sampleLod` / `sampleLevel`.
2. Delete the placeholder machinery once nothing uses it: `zsample2d*`, `location`, `binding` in
   `shader_builtins`, `zspv --rewrite-samplers-wgsl` and the stage-2a wiring in
   `shader_codegen.zig` (check spikes, probes, `draw3d`, `kompute`, `zimrmath` references first).
3. Guard 1 (`spv2wgsl`, hard error): a uniform / storage / image / sampler variable with no
   DescriptorSet+Binding, or an input/output with no Location or BuiltIn. Compute's name-bound
   variables (`kbuf_*`, `P`) get an explicit carve-out. Also refuse a function returning a handle type.
4. Guard 2 (`webtests/runner.mjs`): parse each pipeline's WGSL `@group/@binding` and compare against
   the bind-group layouts it is created with - Dawn's exact check, in-sandbox.
5. Prove both guards red on the 2307 build before the fix and green after.
6. Upstream report: an asm `OpDecorate` whose target is another nav's id is silently dropped - ask
   for a compile error. The drop itself looks like the new design; the silence is the bug.

## Journal

**Step 1 landed - `tools/gen_shader_externs.zig`.** Every interface variable is a file-scope `@extern`
with its decoration; the entry wrapper reads `x.*` and writes `x.* = v`. Loose uniforms are one-field
uniform blocks (`_<name>_block.value`) because 2307 requires a `.uniform` extern to point at a struct;
their group now comes from `uniformGroupForSchema` too (identical on all four schemas that use them).
Samplers are a real texture at (group, N) + sampler at (group, N+1) from `solveSamplerSlots`; the
`io.<n>(uv)` accessors call `sampleLod` / `sampleLevel`. `setup()`, the top-level accessors, every
`zm_location` / `zm_binding`, and the `_location_*` / `_binding_u` sidecars are gone. The file's two
unit tests were never wired to a step and had rotted; rewritten, watched fail, then pass (run by hand:
`zig test --dep shader_interface -Mroot=tools/gen_shader_externs.zig -Mshader_interface=src/shader_interface.zig`).

Measured on the 54 WGSL modules produced since the edit (hello_world + launcher): zero duplicate
`(group, binding)` (was 20), groups above 0 wherever the scheme puts them (was none), default shapes
FS at `@group(1) @binding(0/1)` - the exact slot Dawn reported missing - and the decal FS honouring
`ubo_group = 1` with its texture pinned at group 2. The 42 group-0-only modules classify as legal:
VS UBO / loose uniforms / storage in group 0 by design, or no resources. No function returns a handle
type and no `var` has one (scan checked against the known-bad probe: 14 hits there, 0 here).
`check` green: 163 transpile ok / 0 failed, wgpu_bringup 202 init / ~28 per frame (unchanged).

Still open: 2 (delete zspv + placeholder helpers - zspv currently runs as a no-op), 3 and 4 (the two
guards, each proven red on the old build), 5, 6, plus readme.html / claude.md mentions of the old path.

**Step 2 landed - zspv and the placeholder path deleted.** `tools/zspv{,_rewrite,_main}.zig`, their
build wiring, `shader_builtins.{location,binding,zsample2d,zsample2d_level}`, the never-compiled
`src/shaders/probes/sampler_test_fs.zig` (registered only against the GLSL gravestone), the old-path
spike. spv2wgsl now reads the compiler's `shader.spv` directly, like `addCompute`. Proof it changed
nothing: all 50 distinct WGSL modules byte-identical before/after; launcher.html byte-identical.
`transpiler_corpus` scanned `*.rewritten.spv` and would have gone vacuous - now scans `shader.spv`.
MISSED at first: `tests/fixture_fs.zig` (check's math fixture) still called `sb.location` - the
reference sweep skipped `tests/`. Rewritten with `@extern` decorations and one uniform block.
NEW CONSEQUENCE: a failed shader compile leaves a zero-byte `shader.spv`; zspv used to hide that
(it only wrote on success), the corpus now reads it and counts a transpile failure.

## Review (end of Sep 26) - what was re-verified, what was wrong

Re-verified against the tree, not against summaries:
- `frag_depth` is still `@builtin(frag_depth)` (name-magic through an undecorated `@extern`).
- VS attribute locations match the schema's `Attr(kind, loc)` (lit_shadow: position 0, normal 1).
- Loose uniforms: the hand-built host layouts agree with what is emitted. lambert_demo binds group 0
  `mvp@0 model@1` and group 2 `col_diffuse@0` (16 bytes = one-field vec4 block); pbr3d binds group 0
  `model@0 view@1 projection@2 normal@3 light-space@4` - the schema's field order.
- `refAllDecls(shader_codegen.zig)` (src/tests.zig) compiles after the field removals.

Wrong or incomplete:
- claude.md's 2307 entry, written at the start of the session, calls 2307 "A NO-OP BUMP". It was not:
  every graphics pipeline was invalid on device while fmt, c2js, both standalones, `check` and smoke
  were all green. Must be rewritten - and its lesson is the point: nothing in-sandbox compares a
  shader's bindings against the host layout.
- Guard 1 as first written ("any undecorated resource is an error") would break every compute kernel:
  kompute's `@extern`s carry NO decoration, spv2wgsl numbers them in emission order
  (`resolveBinding` -> `next_auto_binding`, group defaults to 0), and `compute_host.parseBindings`
  reads the numbers back out of the WGSL by name and checks every kernel agrees. That is sound (the
  host follows the shader), so compute is not at risk - but the guard must scope to vertex/fragment.
- Guard 2 must not be built from scratch: `shader_introspect.layoutWgslMismatch(gpa, Schema, wgsl)`
  already reflects a WGSL module's `@group/@binding` and compares it cell by cell with
  `solveLayout(Schema)`, with unit tests. It is called in exactly ONE place (pbr3d's FS) and only in
  Debug, so it never saw this bug. It does not know loose `Uniforms` (solveLayout has no case for them).
- Simon's original ask - standalones of each launcher example - was not delivered; the diagnosis
  made it moot (every graphics shader was broken). Still available if the device disagrees.

## Plan v2 (supersedes the "Plan" section's steps 3-6)

A. Green tree. `transpiler_corpus` skips zero-byte `shader.spv` with a printed count ("N failed-
   compile leftovers skipped") - an empty file is never a transpiler input, and the compile that made
   it already failed its own step. `check` green. Snapshot.
B. Device verdict on the launcher (unchanged since step 1). DONE: Simon, Sep 26 - the launcher works on device.
C. Guard 1 - spv2wgsl, hard error, vertex/fragment modules only: a Uniform / UniformConstant /
   StorageBuffer variable without DescriptorSet + Binding, or an Input/Output without Location or
   BuiltIn. Compute keeps auto-numbering (its host reflects by name). Also refuse a function that
   returns a handle type. Prove it red on an old-style shader (asm-decorated globals, 2307), green on
   the tree.
D. Guard 2 - build time, every schema'd graphics shader: run `layoutWgslMismatch(Schema, wgsl)` on
   the generated WGSL. Teach `solveLayout` (or the checker) the loose-`Uniforms` cells first, or the
   four loose-uniform shaders read as drift. Prove it red on the 2307-broken WGSL (all group 0).
   A runner.mjs check for hand-built layouts (lambert) stays a possible later addition, not this step.
E. Docs: rewrite claude.md's 2307 entry; readme.html; `zig-spirv-compiler-interface.md`;
   lambert_demo's "loose .constant storage" comment; shader_codegen's remaining GL-era prose;
   `spirv_2307` notes into the interface doc.
F. `zig build test` once, detached, with `-Dfocus` - it has not run this session.
G. Upstream report: an asm OpDecorate on another nav's id is dropped silently - ask for an error.

**Plan v2 A done.** `transpiler_corpus` checks each `shader.spv`'s size before hashing and counts
zero-byte files as failed-compile leftovers, printed on their own line and never transpiled.
`tests/fixture_fs.zig` brought up to the house rules (bound zm vocabulary, typed locals). `check`
green: 157 unique inputs, 0 transpile failures, 1 leftover skipped.
**Plan v2 B done.** Simon: the fixed launcher works on device.

**Plan v2 C done - two hard checks in spv2wgsl.**
`checkGraphicsInterfaceDecorated` (after `pass2_decorations`): in a Vertex/Fragment module, a
Uniform / UniformConstant / StorageBuffer variable without DescriptorSet+Binding, or an Input/Output
without Location or BuiltIn, is logged by name and fails with `error.UndecoratedShaderInterface`.
Compute is exempt (kompute's externs are undecorated by design; its host reads bindings back by name) -
verified: all 4 compute modules carry 0 descriptor decorations and pass.
`checkNoHandleValues` (beside `checkNonFiniteConstants`, on the emitted WGSL): a texture/sampler type
after `->` or in an indented `var` fails with `error.WgslHandleUsedAsValue`.
Evidence: red on ssao_blur as 2307 shipped it (3 named), on its raw compile (6 named), on the asm probe
(2 named), on the runtime-`texture2D()` probe; green on 164 current modules and on the file-scope probe.
Pinned by fixtures `src/tests/fixtures/decorations/ssao_blur_{2307_undecorated,decorated}.spv` + three
tests (silent when passing); planted-off control: the "fires" test goes red without the call.
Then `check` went red: `spv2wgsl_check` walks EVERY `.spv` in `.zig-cache`, and 112 stale pre-fix
modules (genuinely broken 2307 output, no longer produced) now fail - all fresh ones (220) pass.
`rm -rf .zig-cache`, cold rebuild: launcher byte-identical to the device-confirmed one (so every shader
in it passed both gates), `check` green (56/56 clean), wgpu_bringup 202 / ~28 per frame unchanged.
Lesson for claude.md: after a generator or transpiler fix, stale cached SPIR-V from before it is
input to the cache-walking gates - clear the cache before believing a red (or a green) from them.

**Plan v2 D done - every schema'd shader's WGSL is checked against its schema at build time.**
DESIGN CHANGED from the v2 text: not `layoutWgslMismatch` in a test, but `checkWgsl` in
tools/gen_shader_externs.zig, run by the SAME per-shader bootstrap exe that generates the externs
(`--check-wgsl <in> <out> <name>`), so there is no extra compile and each run is ~1 ms. The WGSL every
consumer embeds is that step's output, so nothing builds against an unchecked module. Expected cells
come from the functions `emit` itself uses (Ubo, loose Uniforms at the uniform group in order, storage
slots, texture N / sampler N+1); each WGSL binding must match cell, KIND and NAME, and no slot may hold
two. It knows loose uniforms because it uses the generator's rule, not `solveLayout`'s.
The WGSL reflector moved to a new std-only, host-only `src/wgsl_reflect.zig` (re-exported from
shader_introspect, so `material.reflectWgslBindings` is unchanged). A first attempt put it in
`shader_interface` - lint refused it: that file is SHADER-SAFE and the reflector allocates.
Evidence: unit tests with ssao_blur's real 2307 header (refused, first fault the UBO at group 0), its
fixed header (accepted), swapped names (refused), loose uniforms in and out of order. Planted
off-by-one in the sampler cell -> hello-world FAILS naming effect_grade_fs and default_shapes_fs;
restored -> green. Launcher builds (byte-identical to the device-confirmed one); pbr_vs (5 loose
uniforms) and lambert's VS (2) translated fresh and passed; `check` green; bringup 202 / ~28 unchanged.

**Plan v2 E done - docs.** claude.md's 2307 entry rewritten (it had called the bump a no-op; now: what
broke, the fix, the two guards, the cache lesson, the standing rule), plus its three stale `zspv`
mentions. readme.html's "how a schema becomes bindings" describes the decorated `@extern`s and both
checks. zig-spirv-compiler-interface.md: new "2307: asm decorations on globals are dropped" section,
the 956 OpUndef blocker marked resolved, section 10 rewritten to the one remaining shader path.
shader_codegen.zig's GLSL-era pipeline prose rewritten to what runs. lambert_demo's comment fixed.
**Plan v2 F done.** `zig build test -Dfocus=hello_world` (detached, one run): 417/417 steps,
2012/2018 tests passed, 6 skipped, 0 failed.

## Final verification (end of session)
- Whole-repo sweep: no code references to the removed API (the only hits are two test assertions
  that generated output does NOT contain `zm_location` / `zm_binding`); the zspv files and the probe
  directory are gone. `zig fmt --check` clean on the gated surface and on all of tools/.
- Every test added or changed this session, run directly: spv2wgsl gates 6/6, generator 5/5,
  shader_interface 19/19, shader_introspect 27/27.
- Final tree: launcher builds byte-identical to the device-confirmed one; `check` green (0 transpile
  failures, no regressions, doc-gate 13 pages).
- Known and left alone: the WGSL corpus fixtures are all stale (keyed by SPIR-V hash; every hash
  changed with the compiler and the generator) - re-pin only after a full all-examples build, per
  claude.md. Two cached builds of ssao_blur_fs differed by one byte (offset ~31965) while
  transpiling identically; not investigated.
