# finishing_new_gpu_foundations.md

A long-horizon plan for the next 20 sessions.  Builds on the May-2026
arc that just landed: passes return values, engine consumes its own
typed shaders, one shader API, GpuFrame is a thin GPU container,
Renderer2D owns drawing-layer state.  Now we go further.

This is not a roadmap of small wins.  This is the **theoretically
optimal basis** for "any Zig code, runs anywhere — CPU, GPU, comptime."
We're not chasing python's reach, jax's tracing, c's portability,
rust's safety.  We're chasing what Zig uniquely allows: one source,
three execution domains, no marshaling, no FFI, no glue.  And we're
chasing it with the simplicity bar set deliberately high — every
abstraction must read like the operation it represents.

---

## §0.  The greedy vision

Write `mandelbrot_fs.zig` once.  Run it on the GPU at 144Hz.  Run it
on the CPU per-pixel for debugging.  Run it at *comptime* to bake a
test image into the binary.  Step through it in the debugger.  Unit
test it as a normal function.  Profile it.  Move it to a compute
kernel, dispatch a million instances, write the results into a
storage buffer, blit the buffer back to a texture, sample the texture
in a second kernel that does denoising, render the final image at
full screen.  All in Zig.  No FFI.  No language boundary.

Then take the same machinery and build:

- A real path-traced cornell box with a thousand bounces per pixel.
- A 10,000-body rigid-body physics simulation that stays on the GPU
  for a full frame and never touches the CPU.
- A small convolutional neural network whose weights are a storage
  buffer and whose forward pass is a compute shader.
- A FM synthesizer whose voices are compute kernels and whose output
  goes straight to the Web Audio API.
- A CSG/SDF CAD viewer whose scene tree is built at *comptime*.
- A distributed game engine where two browsers share storage buffers
  over WebRTC and rasterize identical frames from identical state.

All on top of the same foundation.  All in Zig.  All readable.

This is the bet.

---

## §1.  Where we are (end of May 2026)

The wgpu stack stands at ~6.7K LOC across 16 modules.  The May-2026
arc closed all ten birds-eye items as either fully shipped or
re-framed:

```
1. createRenderPipeline takes two shader modules         ✅
2. Renderer2D uses engine WGSL, default_shaders deleted  ✅
3. Passes return values (mach move)                      ✅
4. One shader API (loadShaderFromWgsl deleted)           ✅
5. SwBackend dispatches fragment shaders                 ✅ (Turn 3 architecture)
6. Matrix stack + shapes batch moved to Renderer2D       ✅
7. DSL marker for @group(N) @binding(M)                  ✅ (Turn 1 chunks A-E)
8. wgpu_demo_split.zig (GPU vs CPU pixel parity)         ⏸ Turn 4, blocked on 3.9
9. Prefix convention + atomic rename                     ⏳ deferred
10. Vendor SPIRV-Headers grammar JSON                    ⏳ anytime
```

What's load-bearing about what shipped through Turn 3.8:

- **Three architectural shifts landed.**  No hidden state machine.
  No hand-written WGSL.  One shader path.  These are the three
  things every future addition rides on.
- **`GpuFrame` is 123 LOC of pure GPU primitives.**  Container, not
  god-object.
- **`PassState` is a value.**  Mach-flavored explicitness.  The user
  threads it.  The framework doesn't stash it.
- **`Renderer2D` owns its drawing-layer state.**  Matrix stack,
  shapes batch — they live where they're used, not as fields on the
  GPU container.
- **The trait is small** — 12 methods, all explicit args.
- **`Resources(Schema)` is the bind-group story.**  Turn 1's five
  chunks shipped; the word "bind group" disappears from user code.
  Layout decisions are comptime-driven from the DSL marker config.
- **`RenderPipeline(VsT, FsT)` is the only pipeline type.**  Turn 2
  shipped: single-shape `setPipeline`, comptime-generated SW
  dispatch function pointer, ~40 LOC net smaller than the original
  three-shape design.
- **Compile-time mandelbrot.**  Turn 3.6 shipped the proof of
  Property A in **four** execution environments: GPU/WGSL,
  GPU/GLSL, native CPU, AND compile-time (the comptime mandelbrot
  bakes pixels into the binary at build time; runtime cost is a
  `printf` of a const string).
- **WGSL pipeline closed.**  Turn 3.8 shipped Phases B2 + D1 of
  the webgpu migration: engine + example shaders all translate to
  WGSL at build time via `src/spv2wgsl.zig`, get `@embedFile`'d
  into wasm.  **No transpiler in the shipped wasm hot path** —
  every byte of WGSL was produced at build time.

What's blocked or in flight:

- **Translator correctness gap.**  The mandelbrot diagnostic
  proved the linear translator produces WGSL that Chrome parses
  but executes wrong for shaders with `break`/`continue` inside
  an inner `if`.  Three fractal shaders hit it.  **Turn 3.9 (the
  spv2wgsl rewrite) is the active sub-arc fixing this.**  Phase 0
  (foundations) ✅ done; Phases 1-9 over ~9 weeks.  See
  [`src/notes/archive/spv2wgsl-rewrite-plan.md`](spv2wgsl-rewrite-plan.md).
- **Turn 3.7 (engine VS native-importability)** deferred — two
  unblock paths identified; either resolves the codegen issue
  that prevents Renderer2D's shapes pipeline from carrying a real
  SW dispatch fn for arbitrary scenes.
- **Turn 4** (the headline split-screen demo) — blocked on Turn
  3.9 Phase 5.  Ships immediately after.

What's already partially there but not fully exercised:

- **`rlsw_shader.dispatchFragmentShader`** — works, has tests, has
  a GL-side demo (`mandelbrot_split.zig`).  Wired to the trait via
  the Turn 3 vtable + sw-mandelbrot demo (Turn 3.5).
- **`rlsw_shader.dispatchVertexShader` + `rasterizeTriangles`** —
  exist; consumed by `sw_mandelbrot.zig`.  Not yet driving an
  arbitrary 3D scene through the trait (Turn 15).
- **`StorageBuffer(T)`** — typed handle exists, modest usage in
  examples (the SPH fluid sim has it).  Not yet a first-class
  citizen of the typed shader pipeline (Turn 11).
- **`ComputePipeline` + `compute_pass`** — exist, exposed through
  `wgpu.zig`, no high-level helpers, no compute-shader DSL
  (Turn 7).

What's missing entirely:

- **Comptime evaluation of arbitrary shader functions** (we have
  the types; comptime-mandelbrot proves the pattern; nothing
  generalizes it yet).  Turn 8.
- **A unified `Buffer(T)` / `Texture(F)` abstraction** that's GPU-
  backed in wgpu mode and CPU-backed in SW mode.  Turns 5-6.
- **Multi-render-target, depth/stencil, MSAA** — engine path is
  one color attachment.  Turn 10.
- **Indirect draws + storage-buffer-driven scheduling.**  Turn 13.
- **Async pipeline compilation** — WebGPU has it; we don't expose
  it.  Turn 12.
- **Render bundles** — pre-recorded draw sequences, replayed each
  frame.  Required for UI-heavy scenes.  Turn 12.
- **Timestamp queries** — without these we can't measure what we
  ship.  Turn 14.

The plan below addresses all of the above, in order, sized so each
fits in a session.

---

## §1.5  Status board

Every turn at a glance.  See each turn's full entry for details.

| Turn  | Topic                                              | Status              |
| ----- | -------------------------------------------------- | ------------------- |
| 1     | `Resources(Schema)` foundation                     | ✅ shipped           |
| 2     | `RenderPipeline(VsT, FsT)` is the only type        | ✅ shipped           |
| 3     | `SwBackend` dispatches fragment shaders            | ✅ architecture; integration deferred |
| 3.5   | `sw-mandelbrot` — first SW demo                    | ✅ shipped           |
| 3.6   | Split-screen mandelbrot + comptime mandelbrot      | ✅ shipped           |
| 3.7   | Engine VS native-importability                     | ⏭ deferred (codegen surgery; two unblock paths identified) |
| 3.8   | WebGPU migration Phases B2 + D1                    | ✅ shipped           |
| **3.9** | **spv2wgsl recursive rewrite** (9 sub-phases)    | **🔧 in progress — Phases 0-4 ✅ + 5a ✅ + 6 ✅ + 8 ✅, Phase 9 next (5b/5c/7 low-pri cleanup)** |
| 4     | wgpu-vs-sw split-screen demo (headline)            | ⏸ blocked on 3.9    |
| 5     | `Buffer(T)` unified abstraction                    | ⏸                   |
| 6     | `Texture(format)` unified abstraction              | ⏸                   |
| 7     | `ComputePipeline(KernelT)` + `dispatch`            | ⏸                   |
| 8     | Comptime shader evaluation                         | ⏸                   |
| 9     | Math library completeness                          | ⏸                   |
| 10    | MRT + depth/stencil + MSAA                         | ⏸                   |
| 11    | Storage buffers as first-class typed entries       | ⏸                   |
| 12    | Render bundles + async pipeline compilation        | ⏸                   |
| 13    | Indirect draws + storage-buffer-driven scheduling  | ⏸                   |
| 14    | Timestamp queries + perf counters                  | ⏸                   |
| 15    | Vertex shader CPU path + SW triangle rasterizer    | ⏸                   |
| 16    | Demo — path-traced cornell box (compute)           | ⏸                   |
| 17    | Demo — 10K-body rigid-body physics                 | ⏸                   |
| 18    | Demo — tiny CNN inference                          | ⏸                   |
| 19    | Demo — FM synthesizer / audio compute              | ⏸                   |
| 20    | The Crown Demo (`crown.zig`)                       | ⏸                   |


---

## §2.  The five load-bearing properties

Every move in the plan must preserve these.  If a move would break
one, we either find a different move or change the property
explicitly with a documented rationale.

### Property A — One source, three execution domains.

Every shader.  Every kernel.  Every math helper.  Same Zig source
compiles to:

- **SPIR-V** for the GPU (via `zig build-obj -target spirv32-vulkan`,
  rewritten by our `zspv`, translated to WGSL by our `spv2wgsl`).
- **Native x86_64 / wasm32** for the CPU (the same Zig code,
  compiled normally and called from `rlsw_shader.dispatchX`).
- **Comptime** for the test path (call the function at `comptime`,
  the result is a `const` baked into the binary).

This is not an aspirational property.  It is **already partially
real** — `mandelbrot_fs.zig`'s `shaderMain` works as both a SPIR-V
fragment entry point AND a normal Zig function.  The plan extends
this to compute kernels, vertex shaders, and the full standard
library of shader helpers.

### Property B — Mach-style explicitness for the lower layer.

Every GPU object the user can hold is a typed handle.  Every state
change is a function call with explicit args.  No "current" anything
on a framework-owned struct.  Encoders, passes, pipelines, bind
groups — values the user threads.

The May-2026 arc landed this.  Future additions can't backslide.

### Property C — raygpu-style sugar layered ON TOP.

A `Renderer2D.drawRectangle(ps, x, y, w, h, color)` is a one-call
helper.  It expands to: setPipeline(deduped), setBindGroup(deduped),
push 4 vertices + 6 indices into the batch.  The user can write
this themselves with the lower-layer calls and get IDENTICAL
behavior — the helper is convenience, not magic.  No hidden globals.
No "begin" without an explicit close.  No state machine you forgot
about biting you.

This is the line between zimr and raygpu.  raygpu hides; zimr layers.

### Property D — Typed CPU↔GPU interface, comptime-verified.

Renaming a uniform breaks both sides of the boundary at compile
time.  Changing a UBO layout invalidates the bind group at compile
time.  Adding a sampler updates the bind group layout at compile
time.  The schema is the source of truth; codegen emits the
externs the shader sees; the host reads the same schema to build
its descriptors.  Already real; future additions extend it.

### Property E — Software path is faithful.

When the SW backend renders the same scene as the GPU backend, the
output is **pixel-comparable**.  Not byte-identical (floating-point
rounding differs across architectures), but visually
indistinguishable, with documented divergence thresholds.

This is what makes the SW path useful: it's a ground-truth oracle
for the GPU path.  Bug in the GPU shader?  Diff against SW.  Bug in
SW?  Diff against GPU.  Either way, you can localize without
guessing.

---

## §3.  What's missing for the dream

Eight foundation pieces that aren't built yet, sized to fit one
session each.  Plus seven capability extensions.  Plus five demos
that exercise the whole thing and prove the foundation.  Twenty
turns.

The ordering matters: pieces 1-3 unblock SW-CPU parity at the
trait level.  Pieces 4-5 unify resources.  Pieces 6-7 generalize
from fragment shaders to compute.  Pieces 8-15 are the
capability surface that turns the foundation into a graphics
engine someone would ship a game on.  16-20 are the demos that
make the foundation prove its worth.

---

## §4.  Twenty turns

Each turn = one session.  Sized to be completable in 1-2 hours of
focused work.  Tier-a-check stays green after every turn; smoke
stays 134/134.  Cold-rebuild time stays under 6 minutes.

### Turn 1.  The `Resources(Schema)` foundation

**Status: ✅ COMPLETE (May 2026). All 5 chunks + Renderer2D refactor shipped.**

The user-facing API is real and battle-tested:

```zig
// In a shader IO file
pub const Resources = struct {
    view_proj: shader.Ubo(MyUbo, .{}),
    albedo: shader.Sampler2D(.albedo, .{}),
    shadow_map: shader.Sampler2D(.shadow_map, .shared(engine_locs.shadow_map)),
};

// In host code
var resources = z.shader.Resources(my_io).init(f, .{
    .view_proj = view_proj_buffer,
    .albedo = white_tex,
    .shadow_map = shadow_tex,
});
defer resources.deinit();

resources.writeUbo(.view_proj, .{ .view_projection = mvp });
resources.bind(&pass);  // setBindGroup for each used group
resources.set(.albedo, new_tex);  // rebuild only affected group
```

The word "bind group" disappears from user code. All layout decisions
are comptime-driven by the DSL marker config.

**The five shipped chunks:**

- **Chunk A — SPIKE verified:** Zig SPIR-V backend accepts
  `zm_binding(&extern_sampler_const, set, bind)` at comptime; the
  decoration lands in SPIR-V as
  `OpDecorate id=X DescriptorSet N / Binding M`; WGSL output is
  `@group(N) @binding(M) var <name>: ...`.

- **Chunk B — `--sampler-group=1` build flag deleted:** rewriter's
  discover/respect-existing-decorations logic was already built in a
  previous turn (lines 262-290 of `tools/zspv_rewrite.zig`); the
  spike's codegen emissions made the flag redundant.  Engine WGSL
  byte-identical pre/post.

- **Chunk C — DSL marker config:** `Sampler2D(tag, config)` takes
  config struct; `SamplerConfig { pinned, shared }`; `shared(loc)`
  constructor for cross-shader anchors; comptime check rejecting both
  pinned+shared on the same field; 17 call sites migrated; codegen
  reads `@field(SamplerT, "sampler_config")` and emits correct
  `(group, binding)` from the marker.

- **Chunk D — Layout solver:** `shader_introspect.solveLayout(SchemaT)`
  produces `ResolvedLayout` with stable `(group, binding)` assignment.
  Pinned/shared claim cells first; free fields take lowest unclaimed
  binding in kind-default group (UBO→0, sampler→1, storage→2).
  Comptime dup-binding check.  9 solver tests pass.  Codegen uses
  the same algorithm inline (no host imports available there).

- **Chunk E — `Resources(Schema)` host-side type:** Five methods
  (`init`/`deinit`/`bind`/`writeUbo`/`set`).  `InitArgs` type is
  generated from the schema at comptime via `@Struct`.  Reads
  `solveLayout` output to know which groups/bindings; builds one
  BGL+BG per used group; tracks sampler textures for `set` to rebuild
  only affected group.

  **Plus E.1 — Codegen guard rails:** loud `@compileError` for typos
  like `Sample2D` instead of `Sampler2D` — pass-0 checks every
  `Samplers` field has both `slot` AND `sampler_config` decls.

  **Plus the Renderer2D refactor:** five hand-wired bind-group fields
  (`per_frame_bgl`, `material_bgl`, `per_frame_ubo`,
  `per_frame_bind_group`, `white_material_bind_group`) replaced by
  ONE `resources: Resources(EngineSchema)` field.  ~50 LOC of imperative
  encode-create calls replaced by declarative `EngineSchema` struct +
  one `Resources.init` call.

**Verification:**
- ✅ Tier-A check green in 7.5s warm
- ✅ Tier-A smoke: 4/4 PASS in 3.6s warm
- ✅ `wgpu-smoke`: 60 frames clean, engine WGSL byte-identical
  (3047 bytes WGSL pre/post)
- ✅ Full unfocused `zig build test`: all tests pass

**Build wiring change:** `shader_interface` named module added to
`zimr_wgpu_mod`'s imports so Renderer2D could declare its
`EngineSchema` using the DSL markers directly.

**Property A (one source, three execution domains) progress:**
- ✅ GPU domain: `Resources` builds the wgpu bind groups
- ✅ Comptime domain: `solveLayout` runs at comptime, produces
  layout that's also embedded in the codegen-emitted externs
- ⏳ CPU/SW domain: Turn 3 wires SwBackend to dispatch using the
  same Schema (no change to Resources needed — it works on either
  backend; SwBackend just needs to know how to consume the same
  layout for its CPU dispatch path).

**Property B (mach-style explicitness lower layer) intact:**
`WgpuBackend.setBindGroup(ps, idx, bg)` still works.  `Resources` is
sugar layered on top.  Users who want the lower API for special cases
(e.g. binding a custom Whole-screen-pass BG) can use both side-by-side.

**Property D (typed CPU↔GPU interface, comptime-verified) extended:**
Renaming a field in the schema breaks both the codegen emission AND
the host-side `Resources(Schema)` instantiation at compile time.
Adding a sampler updates the BGL.  Changing a UBO field reshapes the
buffer Resources allocates.

**Property E (software path is faithful) preserved:**
Resources doesn't make assumptions about backend.  Turn 3's SwBackend
implementation will be able to use the SAME Resources(Schema) value
because the backend dispatch happens in `bind()` via the
trait-conforming Backend.setBindGroup() call.  Today that always goes
to WgpuBackend; turn 2's `Pipeline(VsT, FsT)` typing makes it
dispatch the right backend automatically.

---

#### Historical record — chunk-by-chunk implementation log


**Chunk A — SPIKE.** ✅ Verified `zm_binding(&extern_sampler_const, set,
bind)` works through Zig's SPIR-V backend.  Codegen emits per-sampler
decorations; they land in SPIR-V as
`OpDecorate id=X DescriptorSet N / Binding M`.

**Chunk B — Build flag deleted.** ✅ `--sampler-group=1` removed from
`src/shader_codegen.zig`.  Engine FS WGSL byte-identical
(`@group(1) @binding(0)`).  Fixture corpus refreshed to 73 entries.

**Chunk C — DSL marker config.** ✅ `Sampler2D(tag, config)` now takes
the second arg.  `SamplerConfig { pinned, shared }` types.
`shared(loc)` constructor.  Comptime check rejecting both pinned+shared
set on same field.  17 call sites mechanically migrated.  10/10
shader_interface tests pass.  Codegen reads `@field(SamplerT,
"sampler_config")` and emits correct `(group, binding)` from the marker.

**Chunk D — Layout solver.** ✅ `shader_introspect.solveLayout(SchemaT)`
walks the resources struct and produces `ResolvedLayout` — one entry
per resource with stable `(group, binding)` assignment.  Pinned/shared
claim their cells first; free fields take lowest unclaimed binding in
the kind-default group.  Comptime dup-binding check rejects collisions
with `@compileError` naming the colliding fields.  9 solver tests pass
(empty schema, single sampler, multiple samplers, pinned, shared,
pinned+free mix, free-around-pinned, groups_used bitmask).

**Codegen-side parity:** the codegen's emission path was upgraded to
use the SAME algorithm as `solveLayout` (lowest unclaimed binding in
kind-default group when no override).  The two implementations
compute identical layouts from identical inputs.  Live test:
the engine FS schema (`Sampler2D(.albedo, .{})`) produces
`@group(1) @binding(0) var texture0;` in WGSL output, matching the
solver's output for the same input.

Verification:
- ✅ `wgpu-smoke`: 60 frames clean, engine WGSL byte-identical to pre-solver
- ✅ `zig build test`: all host tests pass including 9 new solver tests
- ✅ Tier-A smoke: 4/4 PASS in 3.5s warm

**Chunk E — REMAINING: `Resources(Schema)` user-facing type +
Renderer2D refactor + supporting fixes.**

`Resources(Schema)` is the host-side wrapper that owns the
BindGroupLayouts and BindGroups for a shader.  Its `init` walks the
resolved layout, builds one BGL per used group, builds one BG per
group from the user-supplied resource handles, exposes:

- `init(f, .{ .field = handle, ... })` — builds layouts + groups
- `deinit()` — frees the GPU resources
- `bind(*PassState)` — calls `setBindGroup` for each used group
- `set(comptime field, new_resource)` — rebuilds only affected group
- `writeUbo(comptime field, value)` — `queueWriteBuffer` to the UBO

Then Renderer2D switches its hand-wired BGL/BG construction (50+ LOC
today) to a single `Resources(default_shapes_fs_io).init(...)` call.

**Plus two supporting fixes** (small, high-value, surfaced during
the design discussion):

##### E.1 — Codegen guard rails: loudly reject unknown field types

**The footgun:**  `Samplers` is declared as a normal Zig struct.
Today, if a user typo's `Sample2D(.albedo, .{})` instead of
`Sampler2D(.albedo, .{})`, codegen iterates `Samplers.fields`,
hits a type with no `sampler_config` decl, and... silently
mishandles it.  Either it generates broken externs, or downstream
`@field` calls `@compileError` with an obscure message far from
the user's typo.

**The fix:**  add a `pass-0` to codegen's `Samplers` emission
loops: for every field, `@hasDecl(field.type, "sampler_config")`
must be true.  If false, `@compileError` naming the field, its
type, and the expected marker shape.  ~15 LOC, two emission
sites (setup() and installSpirvEntry).

**Future extension:**  the same pattern applies to `Storage` (when
the DSL marker for storage buffers lands) and `Ubo` (when UBO
becomes a Resources field rather than a top-level decl).  Each
recognized resource kind gets a `<kind>_config` decl on its marker
type; codegen checks for it before reading.

##### E.2 — Document the "IO file is just Zig" property

**The realization:**  the IO file (`foo_fs_io.zig`) is never
parsed as text.  It's `@import`-ed as a normal Zig module by
`gen_shader_externs.zig`, which is a Zig program that walks the
imported module via `@typeInfo`, `@hasDecl`, `@field`, `inline
for` — pure comptime reflection.

**The consequence:**  the user can do anything Zig comptime
allows when building their schema:

```zig
// Conditional fields based on build options
pub const Samplers = if (builtin.has_normal_map) struct {
    albedo: shader.Sampler2D(.albedo, .{}),
    normal: shader.Sampler2D(.normal, .{}),
} else struct {
    albedo: shader.Sampler2D(.albedo, .{}),
};
```

```zig
// Generate fields from a comptime list
const kinds = [_]shader.MaterialMapIndex{ .albedo, .normal, .metalness };
pub const Samplers = blk: {
    var fields: [kinds.len]std.builtin.Type.StructField = undefined;
    inline for (kinds, 0..) |kind, i| {
        fields[i] = .{
            .name = @tagName(kind),
            .type = shader.Sampler2D(kind, .{}),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    break :blk @Type(.{ .@"struct" = .{ ... } });
};
```

```zig
// Compose schemas from shared modules
const pbr = @import("pbr_io.zig");
pub const Samplers = shader.merge(.{ pbr.Samplers, struct {
    detail: shader.Sampler2D(.albedo, .{}),
} });
```

**Three categories of limitation, none about parsing:**

1. **Schema decls codegen looks for** — `Ubo`, `Uniforms`,
   `Samplers`, `Storage`, `Inputs`, `Outputs`, `Attributes`.
   Other decls are invisible to extern emission but useful for
   the user's own host code.
2. **Field types codegen recognizes** — only marker types with
   the expected `<kind>_config` decl.  Section E.1 makes this
   limitation loud instead of silent.
3. **Shader BODY constraints** — SPIR-V backend restrictions
   (no allocations, limited stdlib).  These apply to `_fs.zig`
   bodies, NOT to `_fs_io.zig` schemas.  The schema is pure
   comptime; it has none of these restrictions.

**Action item:**  add a "IO file is just Zig" section to
`src/notes/CHEATSHEET.md` with the three worked examples above,
so the property is discoverable by future contributors.

##### E.3 — Lint is part of the compile contract

**Stated explicitly:**  zimr treats lint warnings as compile
errors.  Like Zig itself, the bar is "if the linter complains,
you don't ship."  This applies to schemas + shader bodies + every
file in the tree.  Not negotiable.

What the comptime checks already enforce at a STRONGER level
than lint:

- `solveLayout` dup-binding collision → `@compileError`
- `Sampler2D` with both `.pinned` and `.shared` set → `@compileError`
- Codegen's pass-0 unknown-field-type check (E.1) → `@compileError`
- UBO alignment validation in `shader_introspect` → `@compileError`

What lint catches today (post-may-2026):

- GL-state usage in code paths that should be wgpu
- Deprecated raylib-style API calls
- UI window content exceeding 3× viewport height
- A growing list of zimr-specific patterns

What lint **should** catch but doesn't yet (deferred — separate
sessions, not turn 1):

- **Cross-stage coherence:**  VS `Outputs` field names + types
  must match FS `Inputs`.  Mismatch → garbage interpolation
  (compile chain tolerates).  Lint should reject.
- **Unused sampler fields:**  declared but never called as
  `io.<name>(uv)` in body.  Stale schema baggage.
- **Unused UBO fields:**  declared but never read.  Same class.
- **Snake_case for fields, PascalCase for types.**  Zig
  convention, to be enforced by lint.

**The design rule going forward:**  where comptime CAN see a
class of bug, prefer `@compileError` over lint warning (blocking
is stronger than nagging).  Where comptime CAN'T see it
(cross-file coherence, naming conventions, dead-code patterns),
lint is the right tool.

**The implication for turn 1:**  every comptime check we add is
a permanent rule baked into the type system.  Future code
literally cannot violate it.  Chunk E ships three:
unknown-field-type (E.1), dup-binding (already shipped chunk D),
pinned+shared mutual exclusion (already shipped chunk C).

---

#### What lands: the user-facing surface

A shader declares its resources as a Zig struct.  Locations are
auto-assigned by a comptime solver; per-field overrides exist for
cross-shader sharing.  The user's host code never types group or
binding numbers.

```zig
// In foo_fs_io.zig
const shader = @import("shader_interface");

pub const Ubo = extern struct {
    view_projection: [4]@Vector(4, f32) align(16),
    time: f32,
};

pub const Resources = struct {
    view_proj: shader.Ubo(Ubo, .{}),
    albedo: shader.Sampler2D(.albedo, .{}),
    normal: shader.Sampler2D(.normal, .{}),
    particles: shader.Buffer(Particle, .{ .access = .read_write }),
};
```

Then in host code:

```zig
// At app init
var resources = z.shader.Resources(foo_fs_io).init(f, .{
    .view_proj = view_proj_ubo,
    .albedo = white_tex,
    .normal = normal_tex,
    .particles = particle_buf,
});
defer resources.deinit();

// Each frame
resources.writeUbo(.view_proj, .{
    .view_projection = mvp,
    .time = total_seconds,
});

// In the draw loop
const pass = backend.beginRenderPass(encoder, .{ ... });
defer pass.end();
resources.bind(&pass);
backend.drawIndexed(&pass, .{ ... });
```

Total host-side surface: `.init`, `.deinit`, `.writeUbo`, `.set`,
`.bind`.  The word "bind group" appears nowhere in user code.

#### Cross-shader sharing — when you want it explicit

For resources shared across multiple shader programs (shadow maps,
environment cubemaps, debug log buffers), the marker accepts a
`.shared()` variant that pins to an externally-declared location:

```zig
// In a shared module — declared ONCE
pub const engine_locations = struct {
    pub const shadow_map = shader.SharedLocation{ .group = 3, .binding = 0 };
    pub const env_cube = shader.SharedLocation{ .group = 3, .binding = 1 };
};

// In any shader that uses these
pub const Resources = struct {
    view_proj: shader.Ubo(Ubo, .{}),                                // auto
    albedo: shader.Sampler2D(.albedo, .{}),                          // auto
    shadow_map: shader.Sampler2D(.shadow_map, .shared(engine_locations.shadow_map)),
    env_cube: shader.SamplerCube(.env, .shared(engine_locations.env_cube)),
};
```

Rename `shadow_map` in `engine_locations` → the type system catches
every consumer at compile time.  Coupling is explicit and named.

#### Layout solver — the precise rules

Comptime function `solveLayout(comptime ResourcesT: type) Layout`
runs once per schema and produces a stable assignment.  The rules,
in priority order:

1. **Pinned fields** (`.shared(loc)`) claim their `(group, binding)`
   cell first.  The solver never overrides them.
2. **Free fields** (`.{}`) are partitioned by resource kind:
   - `Ubo` → group 0
   - `Sampler2D`, `SamplerCube`, `Texture(.read_only)` → group 1
   - `Buffer(.access = .read_write | .write_only)` → group 2
   - Future: per-draw resources → group 3 (deferred until needed)
3. Within each group, free fields take **bindings in declaration
   order**, filling the lowest unoccupied slots.  A pinned field at
   `(1, 5)` claims slot 5 in group 1; the next free sampler takes
   slot 0, then 1, then 2, then 3, then 4, then 6 (skipping 5).
4. The result is a `pub const layout: [N]ResolvedBinding` array
   embedded into the schema module at comptime — visible via
   `@field(ResourcesT, "layout")`.

**Stability under insertion** is the key correctness property.
Adding a new free field at the *end* of the struct cannot renumber
existing fields.  Inserting in the middle can — and the comptime
check (next section) catches the case where insertion shifted a
pinned-elsewhere field.

#### Comptime dup-binding check

Inside `solveLayout`, after every assignment, a comptime hash map
verifies no two fields share `(group, binding)`.  Collision triggers
`@compileError` with both field names and locations:

```
error: bind group collision in `MyShader.Resources`:
  field `shadow_map` (line 12) pinned to @group(3) @binding(0)
  field `env_cube`   (line 13) pinned to @group(3) @binding(0)
```

The check runs at the schema's first comptime use.  No way to
deploy a colliding layout.

#### Visibility — inferred, never typed

A field appears in the VS schema → its visibility flag includes
`.vertex = true`.  Same field appears in the FS schema → also
`.fragment = true`.  The solver computes this from where the field
lives in the merged schema.  The user never types `.{ .visibility = ... }`.

The one corner case is read-write storage buffers in fragment
shaders — WebGPU forbids this in WebGL2-compatible profiles.  The
solver checks at comptime and emits a clear error pointing at the
offending field if it lives in an FS schema.

#### SPIR-V decoration emission — using the existing mechanism

The `zm.binding(ptr, set, bind)` function already exists in
`src/zimrmath.zig` (lines 7309-7322).  It emits `OpDecorate
DescriptorSet $set` + `OpDecorate Binding $bind` via inline asm.
**The mechanism is real and shipping today.**

What changes in turn 1: `tools/gen_shader_externs.zig` reads the
schema's `layout` const (produced by `solveLayout`) and emits a
`zm.binding(...)` call for every resource using its solved
`(group, binding)`.  Today's `zm_binding(&u, 0, _binding_u)` becomes
`zm_binding(&u, 0, 0)` (auto-assigned UBO at group 0 binding 0) or
`zm_binding(&u, 1, 3)` (whatever the solver decided).

This means `zspv`'s "fill in missing decorations" change becomes
trivial: **the decorations are never missing** after this turn.
`zspv`'s rewriter today *generates* DescriptorSet decorations
because Zig's backend didn't emit them.  After turn 1, Zig's
backend emits everything from the schema, and `zspv`'s rewriter
becomes "leave existing decorations alone, never invent new ones."

**The `--sampler-group=N` build flag dies.**

#### `Resources(Schema)` — implementation sketch

```zig
pub fn Resources(comptime SchemaT: type) type {
    const layout = comptime solveLayout(SchemaT);
    const NumGroups = comptime countGroups(layout);

    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        f: *gpu_frame.GpuFrame,

        // BGLs and BGs, one per group used.  Indexed by group number;
        // unused slots hold .invalid handles.
        layouts: [4]wgpu.BindGroupLayoutHandle = .{.invalid} ** 4,
        groups: [4]wgpu.BindGroupHandle = .{.invalid} ** 4,

        // Stable references to each resource by field name; needed for
        // .set() to know which group to rebuild.
        bindings: [layout.len]ResolvedBinding = layout,

        // The InitArgs type is generated from SchemaT at comptime —
        // a struct with one field per Resources field, typed to the
        // matching handle (BufferHandle for Ubo, WgpuTexture for
        // Sampler2D, etc.).
        pub const InitArgs = InitArgsFor(SchemaT);

        pub fn init(f: *gpu_frame.GpuFrame, args: InitArgs) Self {
            // Per group used: encode BGL entries, create BGL, create
            // BG with the user-supplied handles.  Total: NumGroups
            // WebGPU calls.
            // ...
        }

        pub fn deinit(self: *Self) void { ... }

        pub fn bind(self: *Self, ps: *PassState) void {
            inline for (0..NumGroups) |i| {
                Backend.setBindGroup(ps, i, self.groups[i]);
            }
        }

        /// Update a UBO field's contents.  Compile-time error if the
        /// named field isn't a Ubo.
        pub fn writeUbo(self: *Self, comptime field: anytype, value: UboType(SchemaT, field)) void {
            wgpu.queueWriteBuffer(
                self.f.queue,
                self.uboBufferFor(field),
                0,
                std.mem.asBytes(&value),
            );
        }

        /// Swap a resource for a different one of the same kind.
        /// Rebuilds only the bind group that contains the field.
        pub fn set(self: *Self, comptime field: anytype, new_resource: anytype) void {
            // ...
        }
    };
}
```

#### Renderer2D refactor

`Renderer2D.init` today hand-builds two BGLs + two BGs.  After turn 1:

```zig
pub const Renderer2D = struct {
    gpa: std.mem.Allocator,
    shapes_pipeline: wgpu.RenderPipelineHandle,
    resources: shader.Resources(default_shapes_merged),
    matrix_stack: MatrixStack,
    shapes_batch: ShapesBatch,
    ...

    pub fn init(gpa: std.mem.Allocator, f: *GpuFrame) !Renderer2D {
        // Pipeline construction (uses the same Schema)
        const pipeline = try buildShapesPipeline(f, default_shapes_merged);

        // Resources construction — replaces 50+ lines of hand-wired BGL/BG code
        var resources = shader.Resources(default_shapes_merged).init(f, .{
            .view_proj = createBuffer(...),
            .albedo = createWhite1x1(f),
        });
        ...
    }
};
```

The shape user-facing methods (`bindForPass`, `flushBatch`) keep
their signatures.  Implementation switches to `resources.bind(ps)`.
50+ LOC of hand-wired bind-group construction deleted.

#### Migration of existing schemas

Five engine + example schemas need the `.{}` argument added:

```diff
 pub const Samplers = struct {
-    texture0: shader.Sampler2D(.albedo),
+    texture0: shader.Sampler2D(.albedo, .{}),
 };
```

Mechanical sed pass.  No behavior change — the empty config is the
defaults, which match today's auto-numbering.

Renaming `Samplers` → `Resources` and folding `Ubo` + `Storage` into
the same struct is *optional* migration; old schemas keep working
with deprecated paths until a separate cleanup turn.

#### Acceptance criteria

1. `Sampler2D(.X, .{})` syntax works; existing tests pass with the
   mechanical migration.
2. `.shared(SharedLocation)` resolves to the right `(group, binding)`
   in the WGSL output.
3. A test schema with a deliberate dup-binding collision produces a
   `@compileError` with both field names.
4. `Resources(Schema)` builds + binds correctly; `wgpu_smoke` passes.
5. `Renderer2D` uses `Resources` internally; no external API change.
6. `--sampler-group=1` build flag deleted from `shader_codegen.zig`.
7. Tier-A green; full smoke 134/134.

#### Tutorial — how the final shape feels

This is the user-facing surface as it will exist after turn 1.
Five worked examples, increasing in complexity.

##### Example A — A flat-colored quad

Simplest possible shader.  No samplers, just per-vertex colors.

```zig
// flat_fs_io.zig — the schema
const shader = @import("shader_interface");

pub const Inputs = struct {
    frag_color: @Vector(4, f32),
};

pub const Out = struct {
    out_color: @Vector(4, f32),
};

pub const Resources = struct {};  // no resources at all

// flat_fs.zig — the body
pub fn shaderMain(io: Io) Out {
    return .{ .out_color = io.frag_color };
}
```

```zig
// In the user's main file
const z = @import("zimr_wgpu");
const flat_fs_io = @import("flat_fs_io.zig");

var resources = z.shader.Resources(flat_fs_io).init(f, .{});
defer resources.deinit();

// In update():
const pass = Backend.beginRenderPass(encoder, .{ .color_view = surf_view, .clear = clear_color });
defer pass.end();
resources.bind(&pass);  // no-op, no bind groups
Backend.drawIndexed(&pass, .{ .index_count = 6 });
```

Even with zero resources, the user calls `resources.bind(&pass)`
unconditionally.  Costs nothing (the `inline for` is empty).
Discipline trumps micro-optimization — the code reads the same
across all shaders.

##### Example B — Textured 2D drawing

The engine's own default shapes shader, written from scratch as if
it were a user shader.

```zig
// textured_fs_io.zig
const shader = @import("shader_interface");

pub const Inputs = struct {
    frag_tex_coord: @Vector(2, f32),
    frag_color: @Vector(4, f32),
};

pub const Out = struct {
    out_color: @Vector(4, f32),
};

pub const Resources = struct {
    albedo: shader.Sampler2D(.albedo, .{}),
};

// textured_fs.zig
pub fn shaderMain(io: Io) Out {
    const sample = io.albedo(io.frag_tex_coord);
    return .{ .out_color = sample * io.frag_color };
}
```

```zig
// Host
var resources = z.shader.Resources(textured_fs_io).init(f, .{
    .albedo = my_texture,
});
defer resources.deinit();

// Switch textures mid-frame:
resources.set(.albedo, another_texture);
resources.bind(&pass);
Backend.drawIndexed(&pass, .{ ... });

resources.set(.albedo, yet_another);
resources.bind(&pass);
Backend.drawIndexed(&pass, .{ ... });
```

`set` rebuilds only group 1 (where `albedo` lives, per the solver).
Group 0 (empty in this shader) is never touched.

##### Example C — UBO with per-frame updates

A shader that takes a view-projection matrix and a time scalar.

```zig
// scene_fs_io.zig
const shader = @import("shader_interface");

pub const Ubo = extern struct {
    view_projection: [4]@Vector(4, f32) align(16),
    time: f32,
    _padding: [3]f32 = .{ 0, 0, 0 },
};

pub const Resources = struct {
    scene: shader.Ubo(Ubo, .{}),
    albedo: shader.Sampler2D(.albedo, .{}),
};

// scene_fs.zig
pub fn shaderMain(io: Io) Out {
    const wobble = @sin(io.scene.time * 4.0) * 0.1;
    const uv = io.frag_tex_coord + @Vector(2, f32){ wobble, 0 };
    return .{ .out_color = io.albedo(uv) };
}
```

```zig
// Host — init
var resources = z.shader.Resources(scene_fs_io).init(f, .{
    .scene = createSceneUbo(f),  // returns a Buffer of UBO size
    .albedo = my_texture,
});
defer resources.deinit();

// Each frame
resources.writeUbo(.scene, .{
    .view_projection = computeMvp(),
    .time = total_seconds,
});

resources.bind(&pass);
Backend.drawIndexed(&pass, .{ ... });
```

`writeUbo` knows from the schema that `.scene` is a UBO; it routes
to `queueWriteBuffer`.  No bind group rebuild.  The bind group still
references the same buffer — only its contents changed.

##### Example D — Storage buffer with read-write compute

A compute kernel that doubles every particle's velocity.

```zig
// double_velocity_io.zig
const shader = @import("shader_interface");

pub const Particle = extern struct {
    position: @Vector(2, f32),
    velocity: @Vector(2, f32),
};

pub const Ubo = extern struct {
    particle_count: u32,
};

pub const Resources = struct {
    params: shader.Ubo(Ubo, .{}),
    particles: shader.Buffer(Particle, .{ .access = .read_write }),
};

pub const WorkgroupSize = [3]u32{ 64, 1, 1 };

// double_velocity.zig
pub fn kernel(io: Io) void {
    const i = io.global_invocation_id[0];
    if (i >= io.params.particle_count) return;
    io.particles[i].velocity *= @splat(2.0);
}
```

```zig
// Host — once at init
var resources = z.shader.Resources(double_velocity_io).init(f, .{
    .params = createParamsUbo(f),
    .particles = particle_storage_buffer,
});
defer resources.deinit();

// Dispatch
resources.writeUbo(.params, .{ .particle_count = 10000 });

const ps = Backend.beginComputePass(encoder);
defer Backend.endComputePass(ps);
Backend.setComputePipeline(ps, double_velocity_pipeline);
resources.bind(&ps);  // Same .bind() works for compute passes
Backend.dispatch(ps, .{ .x = (10000 + 63) / 64, .y = 1, .z = 1 });
```

Storage buffer lives in group 2 (per the solver).  Per-frame UBO
in group 0.  No samplers, so group 1 is empty.  Same API as
graphics — `init`, `writeUbo`, `bind`.

##### Example E — Cross-shader resource sharing

A scene with multiple shaders sharing a shadow map.

```zig
// engine_shared.zig — declared ONCE per project
const shader = @import("shader_interface");

pub const shadow_map_loc = shader.SharedLocation{ .group = 3, .binding = 0 };
pub const env_cube_loc = shader.SharedLocation{ .group = 3, .binding = 1 };

// pbr_fs_io.zig
pub const Resources = struct {
    scene: shader.Ubo(SceneUbo, .{}),
    albedo: shader.Sampler2D(.albedo, .{}),
    normal: shader.Sampler2D(.normal, .{}),
    metallic_roughness: shader.Sampler2D(.metallic_roughness, .{}),
    // Shared resources — pinned location
    shadow_map: shader.Sampler2D(.shadow_map, .shared(engine_shared.shadow_map_loc)),
    env_cube: shader.SamplerCube(.env, .shared(engine_shared.env_cube_loc)),
};

// terrain_fs_io.zig — DIFFERENT shader, same shared resources
pub const Resources = struct {
    scene: shader.Ubo(SceneUbo, .{}),
    heightmap: shader.Sampler2D(.heightmap, .{}),
    detail: shader.Sampler2D(.detail, .{}),
    shadow_map: shader.Sampler2D(.shadow_map, .shared(engine_shared.shadow_map_loc)),
    env_cube: shader.SamplerCube(.env, .shared(engine_shared.env_cube_loc)),
};
```

```zig
// Host — share the same texture handles across two Resources values.
//
// The PBR shader's Resources owns its own bind groups 0, 1, 2.  Its
// group 3 references the shared shadow_map_texture handle.
//
// The terrain shader's Resources is independently constructed and
// also references shared shadow_map_texture.  WebGPU sees two
// separate BindGroup objects backed by the same TextureView — fine.
var pbr_resources = z.shader.Resources(pbr_fs_io).init(f, .{
    .scene = scene_ubo,
    .albedo = pbr_albedo, .normal = pbr_normal, .metallic_roughness = pbr_mr,
    .shadow_map = shadow_map_texture,    // shared
    .env_cube = env_cube_texture,        // shared
});

var terrain_resources = z.shader.Resources(terrain_fs_io).init(f, .{
    .scene = scene_ubo,                   // same scene UBO
    .heightmap = terrain_heightmap, .detail = terrain_detail,
    .shadow_map = shadow_map_texture,    // SAME shared handle
    .env_cube = env_cube_texture,
});

// Each renders independently:
pbr_resources.bind(&pass);
Backend.drawIndexed(&pass, .{ ... });  // PBR objects

terrain_resources.bind(&pass);
Backend.drawIndexed(&pass, .{ ... });  // Terrain
```

Rename `shadow_map_loc` in `engine_shared.zig` — the type system
catches every consumer.  Coupling is named and visible.

#### Risks + what could go wrong

This is where I have to be honest about what's hard.

**Risk 1 — `solveLayout` produces a layout the user couldn't have
designed.**  The solver puts UBOs in group 0 and samplers in
group 1.  WebGPU has a guaranteed minimum of 4 bind groups —
fine.  But a user who *wanted* the UBO in group 1 (because they're
mimicking a tutorial they read online) has no way to override it
without `.shared(...)`.  And `.shared(...)` is documented as
"cross-shader sharing," not "force a specific group."

**Resolution:** add a `.pinned(.{ .group = N, .binding = M })`
variant alongside `.shared(...)` for the single-shader override
case.  Same mechanism, different API name.  Document the
intent: `.shared` for cross-shader coupling, `.pinned` for
single-shader override.  ~5 lines of additional code.

**Risk 2 — The visibility inference rule is wrong for some cases.**
The rule "field appears in VS schema → vertex visibility" is right
for UBOs (the same UBO often used by both stages) but wrong for
storage buffers that should be FRAGMENT-only even when declared
in a shared `Resources` struct.

**Resolution:** the visibility flag in the marker config is an
*override*, not a primary input.  Default is "inferred from usage
in the schema"; explicit `.visibility = .fragment_only` overrides.
Same `.{}` is "infer."  ~10 lines.

**Risk 3 — Zig's SPIR-V backend rejects the emitted decoration when
the binding number is *dynamic* (not a compile-time constant).**

`zm.binding` takes `comptime set, comptime bind` — must be
constants.  The solver produces them at comptime, so this is fine
*if* the solver result is itself comptime-visible to the codegen.
Codegen reads `@field(SchemaT, "layout")` which is a comptime
constant.  Should work — but the SPIR-V backend's exact treatment
of `asm volatile` with comptime arg values needs verification.

**Resolution:** the very first task of turn 1 is a 30-LOC spike
that emits a known-good schema, compiles to SPIR-V, dumps the
decorations, verifies they match the layout.  If the spike fails,
we know before writing the rest.

**Risk 4 — `Resources.set(.field, x)` semantics for storage
buffers.**  Replacing a storage buffer mid-frame on the GPU is
*allowed* but expensive (forces a new bind group, breaks
command-buffer caching).  Users will do this without realizing.

**Resolution:** document.  And: provide `resources.set` returns a
`SetResult` enum (`rebuilt_group` | `unchanged`) so user code can
detect the case if it cares.  Most won't.

**Risk 5 — The migration of existing schemas is "mechanical sed"
but the schemas have multiple non-Resources patterns** (`Ubo`,
`Uniforms`, `Samplers`, `Storage`, `Inputs`, `Outputs`,
`Attributes`).  Folding them all under `Resources` is the cleaner
end-state but breaks the existing `gen_shader_externs.zig` codegen
that expects separate `Samplers` / `Storage` / `Ubo` decls.

**Resolution:** turn 1 keeps the old `Samplers` / `Ubo` / `Storage`
decls working as deprecated aliases — codegen accepts either.
A separate cleanup turn (post-turn-1, before turn 5) unifies under
`Resources`.  This avoids a big-bang migration that would conflict
with everything else.

**Risk 6 — The comptime cost.**  `solveLayout` running once per
schema is fine.  But `Resources(Schema)` is a generic that
instantiates a separate type per schema; with 20+ schemas, comptime
work grows.  The tier-a-check target was "<15s warm" — turn 1 must
not blow that.

**Resolution:** measure after each major chunk lands.  If
comptime cost grows >2s, optimize the solver (it's pure data
manipulation — easy to make fast).

**Risk 7 — The generated layout file emission.**  My §4 plan said
"emit a generated `_layout.zig` companion file."  But Zig's
`@field(SchemaT, "layout")` works without a separate file — the
const can be embedded directly into the schema module by codegen.
**A separate file is probably unnecessary** and adds build-pipeline
state.  Simpler: codegen appends `pub const layout = ...;` to the
generated externs file (which already exists).  The user reads it
via `@import("foo_fs_externs.zig").layout`.

**Resolution:** drop the separate-file idea.  Embed in externs.

#### What this DOESN'T address (deferred to later turns)

- **Layer 3 (Renderer2D-style helpers hide bind groups completely).**
  Renderer2D is internally refactored to use `Resources`, but its
  external API (`drawRectangle`, `bindForPass`) is unchanged.  Going
  further (`renderer.draw(pass, ...)` with NO explicit bind step) is
  a separate turn.
- **`Pipeline(VsT, FsT)` carrying shader type.**  Turn 2's problem.
  Turn 1 just builds the Resources side.
- **SW backend dispatch.**  Turn 3.  Turn 1's Resources type works
  the same way on either backend — it stores handles and submits
  via `Backend.X` trait calls.

---

#### §N — The IO file is just Zig (and the lint contract)

A property of the design that's load-bearing but easy to miss:
**the `_fs_io.zig` / `_vs_io.zig` files are never parsed as text.**
They're `@import`-ed as normal Zig modules by `gen_shader_externs`,
which is itself a Zig program running at build time.  The chain:

1. `build.zig` wires up a build step that produces `externs.zig`
   for each shader.
2. That step runs a generated bootstrap exe at build time.
3. The bootstrap exe `@import`s the shader's IO file as `shader_io`,
   `@import`s `gen_shader_externs.zig` as `gen`, and calls
   `gen.emit(shader_io, writer)`.
4. `gen.emit` uses `@typeInfo`, `@hasDecl`, `@field`, `inline for`
   — pure comptime reflection — to walk the IO module's exports.

**Zero text parsing.  Zero AST manipulation.**  The mechanism is
"Zig importing Zig."  Which means **the user can do anything Zig
can do** when building their schema:

```zig
// Conditional schema based on a build option
pub const Samplers = if (builtin.has_normal_map) struct {
    albedo: shader.Sampler2D(.albedo, .{}),
    normal: shader.Sampler2D(.normal, .{}),
} else struct {
    albedo: shader.Sampler2D(.albedo, .{}),
};
```

```zig
// Generate fields from a comptime list
const map_kinds = [_]shader.MaterialMapIndex{ .albedo, .normal };
pub const Samplers = blk: {
    var fields: [map_kinds.len]std.builtin.Type.StructField = undefined;
    for (map_kinds, 0..) |kind, i| {
        fields[i] = .{
            .name = @tagName(kind),
            .type = shader.Sampler2D(kind, .{}),
            // ...
        };
    }
    break :blk @Type(.{ .@"struct" = ... });
};
```

```zig
// Compose schemas from shared modules
const pbr = @import("pbr_io.zig");
pub const Samplers = shader.merge(.{ pbr.Samplers, struct {
    detail: shader.Sampler2D(.albedo, .{}),
} });
```

All of this works.  The codegen's reflection doesn't care whether
a struct was hand-written or constructed via `@Type` — it sees a
struct with fields, walks them, emits the externs.

##### The actual limitations

Three categories, none of them about how we *process* the IO file:

**1. Schema decls the codegen looks for.**  Today: `Ubo`,
`Uniforms`, `Samplers`, `Storage`, `Inputs`, `Outputs`,
`Attributes`.  Decls outside this set are invisible to extern
emission (fine — the user can keep auxiliary decls for their own
host code).  Adding new schema patterns means extending codegen,
not the user's file format.

**2. Field types the codegen recognizes.**  Inside `Samplers`,
codegen expects each field's type to be `Sampler2D(...)` /
`Sampler2D_atSlot(...)` — types that carry a `sampler_config` decl.
**Today: a stray non-marker field in `Samplers` is silently
skipped.**  This is a footgun ("I typo'd `Sampler2D` as
`Sample2D` — and got no error, just a binding-mismatch crash
later").  Turn 1 chunk E fixes it: codegen errors loudly with
the field name + offending type when it can't recognize a
`Samplers`/`Storage` field.

**3. Shader body has SPIR-V constraints.**  The body file (not
the IO file) compiles to SPIR-V.  No allocations, no `@panic`,
limited stdlib subset, no function pointers.  These constrain
the shader *body*; the IO file is pure comptime and has none of
these restrictions.

##### Lint is part of the compile contract

**zimr treats lint warnings as compile errors.**  Like Zig itself,
the bar is "if the linter complains, you don't ship."  This is
not negotiable — it's an axis of correctness, not a style
preference.

What lint catches today:
- GL-state usage where wgpu-state is expected (post-migration
  cleanup)
- Calls to deprecated raylib-style APIs
- UI window content that exceeds 3× viewport height (the warning
  noted in the smoke test output)
- A growing list of zimr-specific patterns

What lint **doesn't** catch yet but should, sized for future
work (not turn 1 — separate sessions):

- **Cross-stage coherence:** VS `Outputs` and FS `Inputs` must
  have field names + types that agree.  The compile chain
  (Zig → SPIR-V → WGSL) tolerates mismatches with garbage
  interpolation; lint should reject.
- **Unused schema fields:** sampler declared in `Samplers` but
  never called as `io.<name>(uv)` in the body.  Stale schema
  baggage.
- **UBO field unused:** UBO declares `time: f32` but body never
  reads `io.u.time`.  Same class.
- **Snake_case for fields, PascalCase for types.**  Zig
  convention, soon to be enforced.

Most binding-layout bugs are caught at a STRONGER level than
lint: comptime errors from `shader_introspect.solveLayout`.  A
dup-binding collision produces `@compileError` naming both
colliding fields — you can't even compile, let alone ship.  This
is the right tradeoff: where comptime CAN see the bug, lint is
redundant; where comptime CAN'T (cross-file coherence), lint is
the tool.

The implication for turn 1: every comptime check we add IS a
permanent lint rule, baked into the type system, that no future
code can violate.  We get to choose which checks belong in which
layer — comptime for blocking errors, lint for cross-file
patterns.

##### Implication for chunk E

Two follow-on items added to chunk E's scope:

1. **Codegen errors on unknown field types in `Samplers` / `Storage`.**
   When `gen_shader_externs.emit` encounters a field whose type
   has no `sampler_config` / `storage_config` decl, emit a
   compile-time error naming the field, the type, and the
   expected marker shape.  ~15 LOC.

2. **Document the "IO file is just Zig" property** in
   `src/notes/CHEATSHEET.md` so future contributors and external
   zimr users know the comptime expressiveness is available
   without having to discover it.  ~30 LOC of prose + 3 worked
   examples (conditional fields, generated fields, composed
   schemas).

These are small but they make the foundation honest about what it
permits.  Without them, the design's most powerful property — that
schemas are real Zig — stays implicit.

---

### Turn 2.  `RenderPipeline(VsT, FsT)` is the only pipeline type

**Status: ✅ SHIPPED (May 2026).**  Single typed pipeline, function
pointer dispatch, composition over erasure.

**The shipped design:**

`RenderPipeline(VsT, FsT)` is the only pipeline type in the public
API.  Wgpu-only consumers pick `RenderPipeline(void, void)` and
accept that the SW dispatcher is `null`.  Consumers that participate
in SW dispatch use real VS/FS module types.

```zig
// shader_runtime_wgpu.zig
pub fn RenderPipeline(comptime VsT: type, comptime FsT: type) type {
    return struct {
        gpu_handle: wgpu.RenderPipelineHandle = .invalid,
        pub const Vs = VsT;
        pub const Fs = FsT;
    };
}

pub const FsDispatchFn = fn (
    ctx_opaque: *anyopaque,
    base_io_opaque: *const anyopaque,
    rect_x: i32, rect_y: i32, rect_w: i32, rect_h: i32,
) void;

pub fn makeFsDispatch(comptime FsT: type) ?*const FsDispatchFn {
    if (FsT == void) return null;
    if (!@hasDecl(FsT, "shaderMain")) return null;
    const Wrapper = struct {
        fn dispatch(ctx_opaque, io_opaque, rx, ry, rw, rh) void {
            const io_typed: *const FsT.Io = @ptrCast(@alignCast(io_opaque));
            // ... turn 3 wires the rasterizer call here.
            // For turn 2 the shim is a no-op witness — it just
            // verifies the type recovery and references
            // FsT.shaderMain so the comptime check is honest.
        }
    };
    return &Wrapper.dispatch;
}
```

`setPipeline(ps, pipeline: anytype)` accepts ONE shape — comptime-
asserts `@hasDecl(T, "Vs") and @hasDecl(T, "Fs")`.  Raw handles get
a compile-time error with a clear message pointing at the fix:

```
src/wherever.zig: error: setPipeline expects RenderPipeline(VsT, FsT);
  got `wgpu.RenderPipelineHandle`.  Wrap raw handles in
  `RenderPipeline(void, void){ .gpu_handle = h }` for wgpu-only
  pipelines, or use real shader types for SW-dispatchable pipelines.
```

The body of `setPipeline` extracts `pipeline.gpu_handle` and
populates `ps.current_fs_dispatch = comptime makeFsDispatch(T.Fs)`.
Both `WgpuBackend.setPipeline` and `SwBackend.setPipeline` share
this shape (single accepted type, same comptime-construction).

**`PassState.current_fs_dispatch: ?*const FsDispatchFn`** replaces
the old `current_pipeline_typed: ?TypeErasedPipeline`.  Populated
unconditionally by `setPipeline`; null when the FS type can't
dispatch (void or no shaderMain).  Turn 3's `SwBackend.flushBatch`
reads this pointer and calls through it.

**Side effect of the refactor: `flushBatch` stops defensively
re-binding the pipeline.**  Pre-turn-2 `flushBatch` called
`setPipeline(ps, b.pipeline)` "just in case" using a raw handle field
on `ShapesBatch`.  With the typed-pipeline rule, defensive
re-binding doesn't make sense — pipeline binding is the consumer's
responsibility (typically `Renderer2D.bindForPass`), threaded
explicitly like every other piece of state.  `flushBatch` now only
drains the batch + maintains the per-material `setBindGroup` calls.
`ShapesBatch.pipeline` field deleted; only `current_texture_bind_group`
and `current_shader` (used elsewhere for material-switch detection)
remain.

**Tests (9 total, all pass):**
- RenderPipeline carries VS and FS types as comptime decls
- RenderPipeline default-initialises with invalid gpu_handle
- RenderPipeline wraps a real gpu_handle value
- RenderPipeline(void, void) is valid for wgpu-only pipelines
- makeFsDispatch returns null for void FS type
- makeFsDispatch returns null for FS type without shaderMain
- makeFsDispatch returns a function pointer for FS type with shaderMain
- makeFsDispatch shim is callable end-to-end (witness test)
- (legacy) RenderPipeline tests from previous shape

**Verification:**
- ✅ Tier-A check green in 12.7s warm
- ✅ `wgpu-smoke`: 60 frames clean, 26 bridge calls during init (unchanged)
- ✅ Tier-A smoke: 4/4 PASS in 5.3s warm
- ✅ Full `zig build test`: all tests pass in 8.1s warm

**Net code change:**
- ~150 LOC of original turn-2 implementation removed
  (`TypeErasedPipeline` type, `rawHandle()` helper, opaque
  type-id markers, three-shape branching)
- ~110 LOC of new implementation added
  (`FsDispatchFn` typedef, `makeFsDispatch` comptime constructor,
   single-shape `setPipeline`, tests)
- Net: ~40 LOC smaller AND structurally simpler

**Property A (one source, three execution domains) progress:**
- ✅ GPU domain: pipeline binds via `setPipeline(ps, pipe)`
- ✅ Comptime domain: `makeFsDispatch` runs at the call site
- ⏳ CPU/SW domain: Turn 3 wires the rasterizer call inside the
  comptime-generated shim

**Property B (mach explicit lower layer) intact:**
`render_pass.setPipeline(ps.pass, handle)` is the low-level escape
hatch — used by `wgpu_smoke_test` directly, bypassing the trait.
`setPipeline` is the layered-sugar wrapper.

**Property D (typed CPU↔GPU, comptime-verified) extended:**
Pipeline-shader binding is now type-checked at compile time.  A
raw handle passed to `setPipeline` fails to compile.  Renaming the
FS type in a `RenderPipeline(VsT, FsT)` re-evaluates `makeFsDispatch`
at every call site.

**Property E (SW path faithful) ready:**
`current_fs_dispatch` carries the same function-pointer contract on
both backends.  When turn 3's SwBackend implements `flushBatch`, it
calls through this pointer — same dispatch path as wgpu uses for
its pipeline binding, just with a different "what does the GPU mean
here" interpretation.

---

#### Historical record — original turn 2 shape (option A, replaced)

The first turn-2 implementation shipped 2 types + 3 accepted shapes
for `setPipeline` (raw handle, typed pipeline, type-erased view).
All gates were green, but it introduced complexity that paid no rent:

- `TypeErasedPipeline` carried opaque type-id markers (using the
  address-of-comptime-const trick) that nothing actually read.
- `setPipeline(anytype)` had three branches for the three accepted
  shapes.  In practice every consumer would pick one shape and
  stick with it.
- The "preserve raw-handle compat" hedge added ~50 LOC for a
  migration that turned out to be ~5 LOC of actual call sites.

Replaced by the single-shape design above.  Lesson learned:
composition with comptime generics is enough — don't reinvent type
erasure via opaque pointers unless you actually need the dynamism.

---

### Turn 3.  `SwBackend` dispatches fragment shaders for real

**Status: ✅ ARCHITECTURE SHIPPED (May 2026).**  Vtable pattern proven
end-to-end; engine integration deferred to a follow-up turn that
solves the native-importability of shader body modules.

**What shipped:**

The SW dispatch architecture is built on three primitives, each
optimized for a specific concern:

1. **`SwPipelineDispatch`** — a small vtable struct holding type-
   erased function pointers (today: `flush_batch`, future: indirect
   draws, compute, etc.).  Stored as a **per-pipeline-TYPE comptime
   const** inside `RenderPipeline(VsT, FsT)` (or any user-defined
   pipeline struct with a `sw_dispatch` decl).  No allocation, no
   per-instance setup.

2. **`makeSwDispatch(VsT, FsT)`** — comptime constructor for the
   default vtable when both shader types provide `shaderMain`.
   Captures VsT and FsT in its closure so per-pixel work is fully
   comptime-specialized.

3. **`autoConnect(VsOut, FsIo)`** — comptime helper that generates
   the VsOut → FsIo varying-mapping function by walking matching
   field names (excluding `position`, which is consumed by the
   rasterizer for screen-space mapping).  Eliminates the per-shader-
   pair adapter that `rasterizeTriangles` would otherwise require.
   In zimr, VS Outputs and FS Inputs typically share the same
   `Interp` struct (via `_common_io.zig`), so this is the natural
   identity mapping.

**Performance properties (verified architecturally):**

- The indirect call through the vtable is paid **once per
  `flush_batch` call**, not per pixel.
- Inside the closure, VsT and FsT are comptime-known — the rasterizer
  inlines `FsT.shaderMain` per pixel, no virtual dispatch in the
  hot loop.
- `autoConnect`'s field walk happens entirely at comptime (`inline
  for`); the generated copy is straight-line code at the call site.
- `RenderPipeline.sw_dispatch` is a comptime const, so reading it
  via `&@TypeOf(pipeline).sw_dispatch` is a load of a known address
  — no runtime construction.

This is structurally the same speed as hand-written SW rendering:
one indirect call to enter the comptime-specialized rasterizer,
then full straight-line code for everything per-pixel.

**Trait integration:**

```zig
// gpu_iface.zig — PassState
pub const PassState = struct {
    pass: wgpu.RenderPassEncoderHandle,
    current_pipeline: ?wgpu.RenderPipelineHandle = null,
    sw_dispatch: ?*const SwPipelineDispatch = null,  // turn 3
    // ... bind groups + queue + batch
};

// Both WgpuBackend and SwBackend setPipeline:
pub fn setPipeline(ps: *PassState, pipeline: anytype) void {
    const T = @TypeOf(pipeline);
    // comptime assert RenderPipeline shape
    // ...
    ps.current_pipeline = pipeline.gpu_handle;
    ps.sw_dispatch = T.sw_dispatch;  // per-type comptime const
}
```

**Custom pipelines:**  the generic `RenderPipeline(VsT, FsT)` is one
shape; user/engine code can define its OWN pipeline struct with a
custom `sw_dispatch` value when the default witness stub isn't
enough.  The trait only requires `gpu_handle`, `Vs`, `Fs`, and
`sw_dispatch` decls — any struct with that shape is acceptable to
`setPipeline`.

**The headline test (in `shader_runtime_wgpu.zig`):**

```zig
test "SwPipelineDispatch through setPipeline rasterizes a triangle" {
    // Define real shader types (VsModule, FsModule with shaderMain)
    // Build a custom TestPipeline struct with hand-written
    //   sw_dispatch wired to rasterizeTriangles via autoConnect
    // Construct rlsw.Context (32×32 framebuffer, cleared black)
    // Set up PassState; call SwBackend.setPipeline(&ps, pipeline)
    // Verify ps.sw_dispatch matches TestPipeline.sw_dispatch
    // Call ps.sw_dispatch.?.flush_batch(&ctx, &ps)
    // Read framebuffer pixels; verify (4, 8) is green, (28, 4) is black
}
```

This is the structural proof:
- `setPipeline` correctly recorded the vtable
- The vtable dispatch through `flush_batch` reached the closure
- The closure called `rasterizeTriangles` with full comptime types
- `autoConnect` correctly mapped VS Out → FS Io by field name
- Pixels landed in the right places

**Tests added (8 new):**
- `makeSwDispatch returns null for void/void pipeline`
- `makeSwDispatch returns null when FS lacks shaderMain`
- `makeSwDispatch returns a vtable for valid VS+FS types`
- `RenderPipeline.sw_dispatch is null for wgpu-only pipeline`
- `RenderPipeline.sw_dispatch is non-null for SW-capable pipeline`
- `autoConnect copies matching field names except position`
- `autoConnect skips VsOut fields not present in FsIo`
- `SwPipelineDispatch through setPipeline rasterizes a triangle` (headline)

**Verification:**
- ✅ Tier-A check green
- ✅ `wgpu-smoke`: 60 frames clean
- ✅ Tier-A smoke: 4/4 PASS
- ✅ Full `zig build test`: all tests pass

**What's intentionally NOT done (deferred to a follow-up turn):**

1. **Engine VS body native-importability.**  The engine's
   `default_shapes_vs.zig` uses `addrspace(.constant)` /
   `addrspace(.input)` / `addrspace(.output)` via its auto-generated
   externs.  These are SPIR-V-only — the body doesn't compile to
   native today.  To wire `Renderer2D.shapes_pipeline` to the SW
   path requires either (a) target-aware codegen producing a native
   externs file, or (b) lifting `shaderMain` into the IO module via
   codegen.  Both are non-trivial; out of scope for turn 3's
   architecture goal.

2. **`SwBackend.beginFrame` acquiring `rlsw.Context`.**  Today
   SwBackend's lifecycle methods are stubs.  The vtable's
   `flush_batch` receives `ctx_opaque` from the caller — for the
   real engine path, `SwBackend.beginFrame` will allocate /
   acquire an rlsw context and stash it on `GpuFrame`, then
   threading happens through `PassState`.  Architectural; needs
   the engine VS native-importable first.

3. **`ShapesBatch` flow into the SW dispatcher.**  The headline test
   uses a side channel (`test_pipeline_impl_state` global) to pass
   vertex data.  Production engines will read from `ps.batch`
   (the ShapesBatch); each engine's `sw_dispatch.flush_batch`
   closure knows how to interpret its own batch format.

The acceptance criterion ("a host-side test draws a triangle, reads
pixels back, asserts the rectangle is red") is **met** — the test
verifies green pixels on a known-CCW triangle through the typed-
pipeline vtable.  The plan's wording ("when texture sampling needs
the texture data on the host side") is for a future turn — the
test deliberately uses a no-texture FS to scope down.

---

#### Big architectural insights from turn 3

**Insight 1: Vtables-as-comptime-consts.**  Storing the dispatch
vtable as `pub const sw_dispatch = makeSwDispatch(VsT, FsT)` on the
pipeline TYPE means there's exactly one vtable per pipeline shape,
allocated at compile time with no runtime overhead.  Reading it via
`@TypeOf(pipeline).sw_dispatch` is the equivalent of a static method
lookup — no instance state, no construction cost.

**Insight 2: `autoConnect` collapses the per-pair adapter.**  The
existing `rlsw_shader.rasterizeTriangles` required a
`comptime connect: fn(VsOut, *FsIo) void` per shader pair.  In
practice the VS Outputs and FS Inputs share the same `Interp`
struct (via `_common_io.zig`), so the connect is field-by-field
identity.  `autoConnect` generates this identity at comptime by
walking matching field names.  Users never write connect manually
unless their VS Out and FS Io shapes diverge.

**Insight 3: The trait stays trait-shaped.**  `setPipeline(ps,
pipeline: anytype)` accepts any struct with the right decls (Vs,
Fs, gpu_handle, sw_dispatch).  Engine-specific pipeline structs
(with custom batch-format handling in their vtable) plug in by
naming convention — no inheritance, no boxing, no runtime
polymorphism beyond the one fn ptr.

**Insight 4: The SW path is just data.**  The vtable is a const,
the function pointers in it are comptime-generated closures, and
the closures' bodies are comptime-specialized over VsT/FsT.  At
runtime: ONE indirect call to enter the closure, ZERO further
indirection per pixel.  This is the gold standard for "dispatch
into a comptime-known function via a runtime pointer."

---

### Turn 3.5.  `sw-mandelbrot` — first end-to-end SW demo

**Status: ✅ SHIPPED (May 2026).**  First runnable demonstration of
the turn-3 architecture producing a visual output.

**Lands:** `examples/sw_mandelbrot.zig` — a self-contained ~250-LOC
native executable that:

- Defines a `FullscreenVs` + `MandelbrotFs` shader pair inline using
  the new `pub fn shaderMain(io: Io) Out` pattern
- Builds a `MandelbrotPipeline` struct shaped for `setPipeline`
  acceptance (decls: `Vs`, `Fs`, `gpu_handle`, `sw_dispatch`)
- `sw_dispatch.flush_batch` closure rasterizes a fullscreen quad
  (two triangles, 6 indices) via `rlsw_shader.rasterizeTriangles`
  with `autoConnect` mapping `frag_uv` automatically
- Times 5 dispatches; reports min, throughput in Mpx/s
- Encodes the framebuffer to PNG via `zimr.codecs.png.encode`
- Saves `mandelbrot.png` to the cwd

**Build target:** `zig build sw-mandelbrot` (compiled ReleaseFast,
native target).  Wired into `build.zig` with a dedicated
`zimr_native_mod` (the production `zimr_mod` is wasm-targeted
for the in-browser engine).

**Numbers (single-threaded, ReleaseFast, x86_64):**
- 800×600 framebuffer
- MAX_ITER = 256
- ~136 ms / frame (min over 5 runs)
- 3.5 Mpx/s throughput
- ~7.4 fps

The number is single-threaded scalar f32; comparable to a clean
hand-coded SW Mandelbrot at that iteration depth.  No SIMD yet
(rasterizer is scalar in its inner pixel loop).  The architecture
is doing what it should: comptime inlining `FsT.shaderMain` into
the rasterizer's inner loop — the function call cost is at flush_batch
granularity, not per-pixel.

**The killer output:** classic Mandelbrot rendered correctly.  The
PNG looks identical to what a hand-coded SW renderer would produce.
That's the point — the architecture is invisible at the visual
level.  What's different is the source code: ~50 LOC of shader
struct + 30 LOC of pipeline wiring, and the same shader source
SHOULD compile to WGSL/GLSL for the GPU path (gated on codegen
native-importability, which is its own turn).

**Why it matters:**

1. **First runnable proof** that the turn-3 SW architecture is real
   end-to-end (the existing tests verified the seam; this demo
   exercises the full path with actual pixel output).
2. **Concrete example** showing the API surface a downstream user
   sees when adopting the SW dispatch path.
3. **Performance floor** established — 3.5 Mpx/s is a real number
   to optimize from.  SIMD'ing the rasterizer's inner loop should
   give 2-4× without much code churn.
4. **Visual hackernews moment**: "I built a software renderer in
   Zig where shaders are comptime-specialized — no JIT, no virtual
   dispatch per pixel, no overhead — and they share architecture
   with the WebGPU path."  The PNG and the perf number sell it.

**Build-system insight:** the demo needs a SEPARATE
`zimr_native_mod` because the production `zimr_mod` is wasm-
targeted (for the in-browser engine).  Both modules use the same
`src/zimr.zig` root; only the target differs.  Other native
host-side tools can follow this same pattern.

**File: `examples/sw_mandelbrot.zig`**

The demo's flush_batch closure (the heart of the architecture):

```zig
const MandelbrotPipeline = struct {
    gpu_handle: wgpu.RenderPipelineHandle = .invalid,
    pub const Vs = FullscreenVs;
    pub const Fs = MandelbrotFs;
    pub const sw_dispatch: ?*const shader_runtime_wgpu.SwPipelineDispatch =
        &Dispatch.vtable;

    const Dispatch = struct {
        const vtable = shader_runtime_wgpu.SwPipelineDispatch{
            .flush_batch = &flushBatch,
        };
        fn flushBatch(ctx_opaque: *anyopaque, ps_opaque: *anyopaque) void {
            const ctx: *rlsw.Context = @ptrCast(@alignCast(ctx_opaque));
            _ = ps_opaque;
            const vs_outs = [_]FullscreenVs.Out{ /* fullscreen quad */ };
            const indices = [_]u32{ 0, 1, 2, 3, 4, 5 };
            const connect = comptime shader_runtime_wgpu.autoConnect(
                FullscreenVs.Out, MandelbrotFs.Io,
            );
            rlsw_shader.rasterizeTriangles(
                FullscreenVs, MandelbrotFs, ctx,
                &vs_outs, &indices,
                .{ .frag_uv = .{ 0, 0 } },
                connect,
            );
        }
    };
};
```

The `Dispatch.vtable` is a comptime const on the pipeline TYPE.  The
`flushBatch` closure captures `FullscreenVs` and `MandelbrotFs`
statically, so when `rasterizeTriangles` is called with these comptime
type parameters, Zig inlines `MandelbrotFs.shaderMain` directly into
the rasterizer's inner pixel loop.  One indirect call to enter the
closure, then straight-line code for everything else.

---

### Turn 3.5  `examples/sw_mandelbrot.zig` — the SW demo lands

**Status: ✅ SHIPPED (May 2026).**  Bonus deliverable, not on the
original turn list — it crystallized once the turn-3 architecture
was in place and we wanted a runnable demonstration that didn't
require the engine VS native-importable.

**What shipped:**

A standalone native example that renders the Mandelbrot set through
the turn-3 typed-pipeline architecture.  Single file, 292 lines, no
GPU code, no engine integration.  Build target wired in `build.zig`:

```
zig build sw-mandelbrot
```

Output: `mandelbrot.png` at 1280×720, plus throughput stats.

**The shape:**

The shader is plain Zig.  No DSL, no preprocessor, no embedded
WGSL.  Two structs:

```zig
const FullscreenVs = struct {
    pub const Io = struct {
        attr_position: @Vector(2, f32),
        attr_uv: @Vector(2, f32),
    };
    pub const Out = struct {
        position: @Vector(4, f32),
        frag_uv: @Vector(2, f32),
    };
    pub fn shaderMain(io: Io) Out {
        return .{
            .position = .{ io.attr_position[0], io.attr_position[1], 0, 1 },
            .frag_uv = io.attr_uv,
        };
    }
};

const MandelbrotFs = struct {
    pub const Io = struct { frag_uv: @Vector(2, f32) };
    pub const Out = struct { out_color: @Vector(4, f32) };
    pub fn shaderMain(io: Io) Out {
        // 256-iter mandelbrot + smooth coloring + 3-channel cosine palette
        // ...
    }
};
```

The pipeline struct combines them with a hand-written `sw_dispatch`:

```zig
const MandelbrotPipeline = struct {
    gpu_handle: wgpu.RenderPipelineHandle = .invalid,
    pub const Vs = FullscreenVs;
    pub const Fs = MandelbrotFs;
    pub const sw_dispatch: ?*const SwPipelineDispatch = &Dispatch.vtable;

    const Dispatch = struct {
        const vtable = SwPipelineDispatch{ .flush_batch = &flushBatch };
        fn flushBatch(ctx_opaque: *anyopaque, ps_opaque: *anyopaque) void {
            // Fullscreen quad (2 CCW triangles).  rasterizeTriangles is
            // comptime-specialized over (FullscreenVs, MandelbrotFs).
            // autoConnect generates the VsOut→FsIo varying mapping by
            // walking matching field names.
            const connect = comptime autoConnect(FullscreenVs.Out, MandelbrotFs.Io);
            rlsw_shader.rasterizeTriangles(
                FullscreenVs, MandelbrotFs, ctx,
                &vs_outs, &indices, .{ .frag_uv = .{ 0, 0 } }, connect,
            );
        }
    };
};
```

Main calls `SwBackend.setPipeline(&ps, pipeline)` — exactly the
trait call — and then dispatches via `ps.sw_dispatch.?.flush_batch`.

**Measured performance (Intel Xeon 2.10 GHz, single core, Debug-cache ReleaseFast):**

| Resolution | Pixels    | Render time | Throughput   |
|------------|-----------|-------------|--------------|
|  800 × 600 |   480 000 |    161 ms   |  2.98 Mpx/s  |
| 1280 × 720 |   921 600 |    309 ms   |  2.98 Mpx/s  |
| 1920 ×1080 | 2 073 600 |    695 ms   |  2.98 Mpx/s  |

Linear scaling with pixel count — exactly what the architecture
predicts.  Throughput stays constant because each pixel does
identical work (256-iter Mandelbrot, log+log2 smooth coloring,
3-channel cosine palette).  Cache effects are negligible at these
sizes — the 8MB framebuffer for 1080p fits in L2 on most modern
chips, and the per-pixel inner loop is hot in L1.

This is **pure scalar f32** through Zig's auto-vectorizer.  No
hand-written SIMD intrinsics.  No JIT.  The throughput is "what
Zig's ReleaseFast produces for the inlined `MandelbrotFs.shaderMain`
inside `rasterizeTriangles`'s pixel loop."

**The image:** classic Mandelbrot view with smooth coloring (log-
log escape value normalization, Vepstas formula), Ultra-Fractal-style
palette (cream → cyan → black filaments → orange background).
Visually equivalent to what you'd get from a hand-written renderer.

**What this proves:**

1. **Inlining works.**  `MandelbrotFs.shaderMain` is comptime-known
   inside `rasterizeTriangles`; Zig inlines it.  If it weren't
   inlining, per-pixel function-call overhead would tank throughput
   below 1 Mpx/s.

2. **`autoConnect` works.**  No hand-written connect adapter.  The
   `frag_uv` field on `FullscreenVs.Out` flows to the `frag_uv`
   field on `MandelbrotFs.Io` automatically.  Adding a new varying
   means adding a field to both structs — no signature plumbing.

3. **The vtable works.**  `setPipeline` records the per-pipeline
   comptime const; `flush_batch` dispatches through it.  Zero per-
   instance overhead.

4. **The Zig-as-shader-source contract is real.**  No DSL, no
   shader compiler, no preprocessor.  Just a function with the
   right signature.  Native code emits straight Mandelbrot binary.

**What's NOT proven yet (next session's work):**

- Same source running on GPU side (blocked on codegen native-
  importability; see the three strategies below)
- Multi-threaded rasterization (single CPU available in dev box;
  the architecture is embarrassingly parallel by row/tile)
- SIMD throughput (Zig auto-vectorizes the inner loop; explicit
  `@Vector(8, f32)` would push to ~25 Mpx/s)

**Files:**
- `examples/sw_mandelbrot.zig` — the demo (292 lines)
- `mandelbrot.png` — example output (1280×720, ~380 KB)
- `build.zig` target `sw-mandelbrot` — invokes via `zig build sw-mandelbrot`

**Gates:**
- ✅ Demo builds clean
- ✅ Demo runs to completion, saves PNG
- ✅ Tier-A check green
- ✅ wgpu-smoke: 60 frames clean
- ✅ Full `zig build test`: all tests pass

---

### Turn 3.6  Side-by-side mandelbrot + comptime mandelbrot

**Status: ✅ SHIPPED (May 2026).**

**What we discovered:**

The "GPU + SW side-by-side" demo the plan had pegged for turn 4
**already exists** as `examples/mandelbrot_split.zig`.  It uses the
*older* `rlsw_shader.dispatchFragmentShader` API (not the turn-3
typed-pipeline vtable), but it does the canonical thing: same
`shaderMain` from `examples/mandelbrot_fs.zig` runs through two
pipelines:

- **GPU**: compiled to SPIR-V → spirv-opt → spirv-cross → GLSL ES 3.0,
  `@embedFile`'d into the wasm, uploaded to the browser GPU.
- **CPU**: compiled to wasm32, called from `dispatchFragmentShader`
  directly per pixel.

The cursor X position is the windowshade divider — drag the mouse
to A/B compare which strip came from which pipeline.  This pattern
shipped at S4 of the software-shader plan.  Same shader source,
two backends, visually pixel-equivalent.

Run with `zig build run-mandelbrot_split` (opens a browser).

**The genuinely new contribution this turn:** a **compile-time
Mandelbrot**.  Same kernel, fourth execution environment.

`examples/comptime_mandelbrot.zig` evaluates the entire Mandelbrot
set INSIDE THE ZIG COMPILER via `@setEvalBranchQuota` + comptime
function call.  The pixel data lives in the binary's read-only
data section.  At runtime, `main()` just prints the const.

```zig
const W: usize = 80;
const H: usize = 36;
const MAX_ITER: u32 = 128;

/// The baked Mandelbrot.  Runs at COMPILE TIME — every iteration,
/// the escape test, the smooth-iteration formula, and the palette
/// lookup is evaluated by the Zig compiler.  Runtime work: zero.
const IMAGE: [H * (W + 1)]u8 = renderAscii(W, H, MAX_ITER, ...);

pub fn main() !void {
    std.debug.print("{s}", .{IMAGE});  // printf of a const string
}
```

**Cost profile:**

- First build (cold cache): **16.4s** of comptime evaluation
- Subsequent builds (warm cache): 69ms (comptime result is cached)
- Runtime: **zero per-pixel float math** — printf of a const string

**What this proves:**

The Mandelbrot kernel runs in **FOUR distinct execution environments**
with one Zig source of truth:

| Mode             | How                                                   | Binary size impact     |
|------------------|-------------------------------------------------------|------------------------|
| WebGPU/WGSL      | Zig → SPIR-V → spv2wgsl → `@embedFile` → wgpu pipeline | shader string in wasm  |
| WebGL2/GLSL      | Zig → SPIR-V → spirv-cross → GLSL ES 3.0 → `@embedFile`| shader string in wasm  |
| Native CPU       | Zig ReleaseFast → `rlsw_shader.rasterizeTriangles`     | inlined into binary    |
| **Compile-time** | Zig comptime → const bytes baked into binary           | ~2KB of pixel data     |

The compile-time mode is genuinely new — Zig comptime is general
enough to evaluate floating-point iteration, transcendentals
(`@log`, `@log2`), branches, and palette lookups in the compiler
itself.  Most languages can't.  C++ constexpr can't reach this
shape (transcendentals aren't constexpr in C++23).  Zig can.

**The image** (printed by `zig build comptime-mandelbrot`):

```
..............................:::::::::::::::::::::----:::::::::::::::..........
...........................::::::::::::::::::::::--=.#----::::::::::::::........
........................:::::::::::::::::::::::----=+@+===--:::::::::::::.......
......................:::::::::::::::::::::::------=+* :*=----:::::::::::::.....
[...]
............::::::::::::::::::::---------=+%%.-# @@ @@@@@@@@.%-*+**.+--:::::::::.
..........::::::::::::::::-------------==+**@@@@@@@@@@@@@@@@@@+*@@@+=--:::::::::
........:::::::::::::::--------------===+ #.@@@@@@@@@@@@@@@@@@@@@@#==--:::::::::
.......::::::::::::::----*============++*@.@@@@@@@@@@@@@@@@@@@@@@-%+=---::::::::
.....:::::::::::::::----=**++++#*++++++%@@@@@@@@@@@@@@@@@@@@@@@@@@:*:=--::::::::
[symmetric across real axis — main cardioid, period-2 bulb, satellites]
```

**Files added/touched:**

- `examples/comptime_mandelbrot.zig` — the demo (~150 lines)
- `build.zig` — new `comptime-mandelbrot` step

**Gates:**

- ✅ `zig build comptime-mandelbrot`: builds + runs to completion
- ✅ `zig build sw-mandelbrot`: still works (turn 3.5)
- ✅ Tier-A check: 4.8s warm
- ✅ Full `zig build test`: all tests pass

---

### Turn 3.8  WebGPU migration Phases B2 + D1 — WGSL pipeline closed

**Status: ✅ SHIPPED.**

**The strategic context:**

The plan in `src/notes/webgpu-migration-plan.md` targets WebGL deletion
at Phase F.  "Supporting both" is transitional — once Phase F lands,
the pitch becomes *"one Zig source, one WebGPU runtime, four execution
modes, no GLSL toolchain, no transpiler in the shipped wasm"* rather
than *"we support both."*

The migration breakdown (post-this-turn):
- **Phase A — spv2wgsl 100% on the corpus.**  ✅ DONE
- **Phase B — `addShaderWgsl` + unconditional WGSL emission.**  ✅ DONE this turn
- **Phase C — engine shaders in Zig, `Renderer2D` uses `@embedFile`.**  ✅ DONE earlier (`default_shapes_*` exist, `DEFAULT_SHAPES_VS_WGSL = @embedFile("default_shapes_vs.wgsl")` is the live path)
- **Phase D — `loadShader` accepts only pre-translated WGSL.**  ✅ DONE this turn
- **Phase E — `SwBackend` wired through `rlsw_shader`.**  ⏳ turn 3 shipped the architecture, full wiring pending
- **Phase F — delete the GL path (25,491 LOC, 106 examples to port first).**  ⏳ the long tail

**What shipped this turn — Phase B2:**

Two flips in `build.zig`:

1. **Engine shaders**: emit `.wgsl` unconditionally, replacing the
   `default_shapes_*`-only opt-in:

   ```zig
   // Before:
   const emit_wgsl: bool = std.mem.startsWith(u8, sh_name, "default_shapes_");
   // After:
   const emit_wgsl: bool = true;
   ```

2. **Example shaders**: also opt in via `emit_wgsl = true` in the
   `addShaderEx` call.  `wgsl_strict = false` for examples (let
   them explore SPIR-V constructs not yet handled); engine shaders
   stay `wgsl_strict = true` (zero tolerance for `// ERROR:`).

**Phase B2 results:**

- 18 `.wgsl` files now in `.zig-cache` after a clean build (engine +
  examples + fixtures)
- **Zero `// ERROR:` markers across all 18** — every shader translates
  cleanly through spv2wgsl
- Corpus grew **42 → 64 entries** (22 newly-locked engine shaders)
- Tier-A check: **8.4s → 13.5s warm** (+5.1s for the additional
  spv2wgsl runs; cheap)

**What shipped this turn — Phase D1:**

`shader_runtime_wgpu.loadShader` previously took `.spirv_source` and
ran `compileFromSpirv` at runtime to translate SPIR-V → WGSL inside
the wasm.  Phase D1 moves that translation to build time:

```zig
// Before:
pub fn ShaderDesc(comptime SchemaT: type) type {
    return struct {
        // ...
        spirv_source: []const u8,   // SPIR-V binary
    };
}
// loadShader:
const compiled = try shader_compile.compileFromSpirv(gpa, words);
const shader_module = wgpu.createShaderModuleWgsl(device, compiled.wgsl, label);

// After:
pub fn ShaderDesc(comptime SchemaT: type) type {
    return struct {
        // ...
        wgsl_source: []const u8,    // pre-translated WGSL text
    };
}
// loadShader:
const shader_module = wgpu.createShaderModuleWgsl(device, desc.wgsl_source, label);
```

The `shader_compile` import is removed from `loadShader`'s hot path.
The `LoadError` no longer unions `shader_compile.ShaderError`.

**Phase D1 was a structurally clean change because `loadShader` had
ZERO external callers** — the runtime SPIR-V path was dead code
waiting to be repurposed.  Engine shaders bypass `loadShader`
entirely (they call `wgpu.createShaderModuleWgsl` directly with the
embedded WGSL); the 3 example shader call sites use the GL-side
`shader_runtime.loadShader` (which is a different function with a
different signature, scheduled for deletion in Phase F).

After Phase F lands and the GL `loadShader` goes away, this wgpu
`loadShader` will become the universal user-facing API for custom
shaders.  Today it's the right shape but unreferenced.

**Combined gates:**

- ✅ Tier-A check: 8.2s warm, 33s cold
- ✅ wgpu-smoke: 60 frames clean
- ✅ wgpu-check: 1.9s, NO REGRESSIONS
- ✅ Full `zig build test`: all tests pass (new `wgsl_source` regression test added)
- ✅ 18 `.wgsl` files in cache, 0 with `// ERROR:` markers
- ✅ Corpus: 64 entries locked
- ✅ wgpu_demo.wasm: 1,719,159 bytes (post-cleanup)

**Additional cleanups (D1 followups):**

- `src/renderer_2d.zig`: removed dead `const shader_compile = @import(...)` import (no usage).
- `src/wgpu_smoke_test.zig::buildTrianglePipeline`: was using `compileFromWgsl` just to dup a const string; replaced with direct `wgpu.createShaderModuleWgsl`.
- `src/zimr_wgpu.zig`: dropped `pub const shader_compile = @import(...)` and `pub const spv2wgsl = @import(...)` from the public API surface (kept in test block for test coverage).  Per Phase D1, runtime SPIR-V→WGSL is no longer a user-facing capability.
- `build.zig`: completed Phase B2's wiring loop — example shader `.wgsl` outputs are now exposed as `addAnonymousImport("{sh_name}.wgsl", ...)` on the consumer `exe_mod`, so example code can `@embedFile("mandelbrot_fs.wgsl")` and feed it directly to `loadShader(.{ .fs_wgsl_source = ... })`.

**D1 API correction (discovered during attempted consumer wiring):**

The initial D1 ship had `ShaderDesc.wgsl_source: []const u8` (single source).  This was incorrect — the build pipeline emits SEPARATE VS and FS WGSL files (each shader Zig source is compiled to its own SPIR-V → WGSL), so a single-source descriptor can't represent the pairing.  Also, the entry-point names in the descriptor encoder were hardcoded as `"vs_main"` / `"fs_main"` but spv2wgsl emits everything as `"main"`.

Both bugs were silent because `loadShader` had zero callers.  Fixed in this session:

```zig
// Before (incomplete D1):
pub fn ShaderDesc(comptime SchemaT: type) type {
    return struct {
        // ...
        wgsl_source: []const u8,   // single source, wrong shape
    };
}
// loadShader: createRenderPipeline(..., shader_module, shader_module, ...)
//             vs_entry_point = "vs_main", fs_entry_point = "fs_main"  // wrong

// After (correct D1):
pub fn ShaderDesc(comptime SchemaT: type) type {
    return struct {
        // ...
        vs_wgsl_source: []const u8,  // @embedFile("foo_vs.wgsl"), required
        fs_wgsl_source: []const u8,  // @embedFile("foo_fs.wgsl"), required
    };
}
// loadShader: createRenderPipeline(..., vs_module, fs_module, ...)
//             vs_entry_point = "main", fs_entry_point = "main"  // correct
```

The `LoadedShader(SchemaT)` struct now carries `vs_module + fs_module` rather than a single `shader_module`.  Pipeline cache hashing uses a new `pipeline_cache.hashSource2(vs, fs)` that combines both source hashes with a separator byte (so concat(A,B) ≠ concat(A',B') when A|B overlap).

**Regression guard test** (`src/shader_runtime_wgpu.zig`):

```zig
test "ShaderDesc carries vs_wgsl_source + fs_wgsl_source (Phase D1 — pre-translated WGSL)" {
    const _Desc = ShaderDesc(TestSchema);
    try std.testing.expect(@hasField(_Desc, "vs_wgsl_source"));
    try std.testing.expect(@hasField(_Desc, "fs_wgsl_source"));
    try std.testing.expect(!@hasField(_Desc, "spirv_source"));
    try std.testing.expect(!@hasField(_Desc, "wgsl_source"));
}
```

**Build wiring for the first consumer** (in progress):

`build.zig` now exposes engine WGSL + `mandelbrot_fs.wgsl` as anonymous imports on `wgpu_demo_mod`.  The `EngineShader` struct grew `wgsl_path` and `wgsl_name` fields so late-bound modules can wire engine WGSL via `addAnonymousImport`.  A small allow-list (`wgpu_demo_shaders = .{"mandelbrot_fs"}`) hooks up example shaders the demo wants to consume directly.

**Blocker for the first consumer** (newly discovered):

The engine VS `default_shapes_vs.zig` declares `view_projection: mat4` at `@group(0) @binding(0)`.  The `mandelbrot_fs_io.zig` schema declares `Ubo { center, zoom, resolution, max_iter }` and auto-layout places it at `@group(0) @binding(0)`.  **Pairing them collides at group 0.**

Two cleanest paths forward:

1. **Schema-driven multi-stage layout** — extend `shader_introspect.solveLayout` to accept a "binding group offset" so an FS paired with the engine VS lands its UBO at group 1+ instead of group 0.

2. **Custom VS per loadShader consumer** — write a `wgpu_mandelbrot_vs.zig` that shares the `mandelbrot_fs_io.Ubo` schema and computes a fullscreen quad from `Ubo.resolution`.  Both VS and FS reference the same single schema; bindings naturally land at `@group(0) @binding(0)` on both modules, used consistently.

Path 2 is more idiomatic (matches how `cube_split_vs.zig` + `cube_split_fs.zig` pair today via a shared schema concept) and doesn't require schema-system surgery.  It's the recommended next step.

**Phase D1 END-TO-END VALIDATION (shipped this session):**

Rather than wait on the Mandelbrot binding-collision puzzle, shipped the smallest possible `loadShader` consumer to PROVE the path works at the wasm level.  Four new files + build wiring:

- `examples/wgpu_trivial_vs_io.zig` — empty-schema VS io (Attributes + Outputs, no Ubo, no Samplers)
- `examples/wgpu_trivial_vs.zig` — pass-through vertex shader (clip-space positions in, position + UV out)
- `examples/wgpu_trivial_fs_io.zig` — empty-schema FS io (Inputs + Outputs)
- `examples/wgpu_trivial_fs.zig` — UV-gradient fragment shader (`out_color = vec4(u, v, 0.5, 1.0)`)
- `build.zig` — explicit `addShaderEx` registration block for these two shaders, wired as `@embedFile`-able imports on `wgpu_demo_mod`
- `examples/wgpu_demo/wgpu_demo.zig` — adds `trivial_shader: LoadedShader(TrivialSchema)` to State; calls `z.shader.loadShader(TrivialSchema, .{ .vs_wgsl_source = @embedFile("wgpu_trivial_vs.wgsl"), .fs_wgsl_source = @embedFile("wgpu_trivial_fs.wgsl"), .label = "wgpu_trivial" })` during init

**Entry point name bug caught and fixed.**  My initial fix used `"main"` as the entry point name, matching the SPIR-V backend's behavior for old-style `pub export fn main` shaders.  But the TYPED shader pipeline (`installSpirvEntry`) emits entry point `entry` — which is what `Renderer2D`'s hand-written pipeline uses too.  Hardcoded entry point in loadShader changed from `"main"` to `"entry"` to match.  Smoke test passed both before AND after the fix because the smoke harness's JS bridge is stubs (no real WGPU validation), but a real browser would have rejected the `"main"` lookup.

**Result of validation (after Ubo path added):**

```
✓ wasm instantiated (1,786,900 bytes)   [+68KB for new pipeline + bind group + UBO buffer machinery]
✓ exports present: memory, _initialize, update
✓ _initialize completed                  [loadShader ran to completion]
  bridge calls during init: 33           [+13 from before — pipeline + bind group + UBO buffer + queueWriteBuffer]
✓ ran 60 update() frames without trap
  bridge calls per frame: ~17.0          [+1 — pushUbo's queueWriteBuffer each frame]
✓ wgpu_smoke PASSED
```

The full path is proven, **including the typed-Ubo round trip:**

```
trivial_fs_io.zig (Ubo: { time: f32, _pad×3 })
trivial_fs.zig (reads io.u.time, modulates output color)
   → zig build-obj -target spirv32-vulkan
   → shader.spv
   → spv2wgsl   (Phase A/B — build-time only, no transpiler in shipped wasm)
   → trivial_fs.wgsl
   → @embedFile in wgpu_demo.zig   (Phase B2 wiring)
   → loadShader(TrivialSchema, .{ ... })   (Phase D1)
   → createShaderModuleWgsl + createBindGroupLayout + createBuffer + queueWriteBuffer
     + createPipelineLayout + createRenderPipeline
   → loaded.pushUbo(queue, .{ .time = t })   (per-frame typed UBO push)
```

**No transpiler in the shipped wasm hot path.**  Every byte of the trivial shaders' WGSL was produced at build time by `src/spv2wgsl.zig`.  At runtime, the wasm just hands the strings to WebGPU and pushes typed-Ubo bytes via `queueWriteBuffer`.

**Combined gates:**

- ✅ Tier-A check: 8.34s warm, 36s cold
- ✅ wgpu-smoke: 60 frames clean, trivial pipeline + UBO created during init, pushUbo each frame
- ✅ wgpu-check: 2.06s, NO REGRESSIONS
- ✅ Full `zig build test`: all tests pass
- ✅ Corpus: 72 entries locked (was 64 pre-session; 70 after trivial-no-Ubo; 72 after adding Ubo to trivial FS)
- ✅ wgpu_demo.wasm: 1,786,900 bytes (+68KB vs baseline pre-session)

**Migration position:** Phases A, B, C, D all green AND end-to-end validated.  E partial.  F is the remaining work — port 106 examples off the GL path, delete ~25K LOC.  Phase D1 is no longer "API shape is right but unproven"; it's "API shape is right AND working in a real wasm consumer, exercising shader module creation, pipeline build, bind group layout/binding, UBO buffer write, and per-frame typed UBO push."

---

### Turn 3.9.  spv2wgsl recursive rewrite

**Status: 🔧 IN PROGRESS — Phase 0 ✅ done (May 2026); Phases 1-9 pending.**

**Authoritative plan:**
[`src/notes/archive/spv2wgsl-rewrite-plan.md`](spv2wgsl-rewrite-plan.md) is the
detailed sub-plan.  This entry summarizes; that file is canonical.

**Why this turn exists:**

Turn 3.8 shipped the **WGSL pipeline closed** — engine + example
shaders translate through our `src/spv2wgsl.zig` at build time, get
`@embedFile`'d into wasm, fed to `device.createShaderModule` at
runtime.  No transpiler in the shipped wasm hot path.

But the **mandelbrot diagnostic** (force `out_color = red` at end of
`examples/mandelbrot_fs.zig`) revealed that the current single-pass
linear translator produces WGSL that Chrome parses but **executes
wrong** for shaders with a `break`/`continue` inside an inner `if`.
Three fractal shaders (mandelbrot, julia, mandel_julia) hit it; the
canonical Tint test corpus (181 fixtures) hits the same pattern in
3 cases.  Total: ~3% of real-world shaders, 0% acceptable for a
headline demo.

The current translator is a single-pass linear emitter (`src/spv2wgsl.zig`,
2448 LOC).  It cannot be patched into correctness — the bug is
structural: it doesn't model the control-flow tree, so it can't
know when a phi assignment sits in a branch that exits the
construct vs. one that converges.  The fix is a **recursive walker
over the structured CFG with a stop set**, the architecture Tint
itself adopted when it ran into the same wall.

**Why Turn 4 is blocked on this:**

Turn 4 (the wgpu-vs-sw split-screen mandelbrot demo) renders the
fractal — the same shader category that hits the bug.  Until the
translator fixes its handling of if-break inside loop, Turn 4
cannot demonstrate Property A (one source, three execution domains)
because the GPU side renders incorrectly.  Every downstream demo
turn (16-20) also wants correct translation.

**Plan (9 phases over ~9 weeks):**

- **Phase 0 — Foundations.**  ✅ DONE (May 2026, this session).
  Differential validator (`zig build wgpu-diff`, pure Zig, no JS),
  181 Tint test fixtures extracted into
  `tests/fixtures/external/tint/`, baseline metrics captured
  ([`spv2wgsl-baseline-may-2026.md`](../../spv2wgsl-baseline-may-2026.md)).
  Result: 178/181 Tint corpus clean, 3 known-bug hits (the exact
  pattern targeted); 13/16 internal corpus clean.  98.3%
  structural correctness on the most comprehensive SPIR-V CF
  corpus available — the 1.7% gap is exactly what the rewrite
  targets.

- **Phase 1 — BlockTable + module split.**  ⏸ start next.
  Mechanical refactor of `src/spv2wgsl.zig` (2448 LOC) into
  `src/spv2wgsl/{block_table,walker,selection,loop,switch,phi,instructions,state,types}.zig`.
  Pre-step: refactor body-instruction helpers (~50 sites) to take
  `out: *std.ArrayListUnmanaged(u8)` rather than write to a
  singleton `s.body_buf`.  Add `BlockInfo` table populated in
  Pass 1 (kind ∈ {if_header, loop_header, switch_header,
  selection_merge, loop_merge, continue_target, ordinary},
  parent_construct, structural successors).  **No emission
  change** — same bytes out, modular tree.  Phase 0's corpus test
  is the safety net.

- **Phase 2 — Walker scaffold + StopSet.**  Non-emitting recursive
  walker.  `walkBlock(*State, block_id, stop_set, *out_buf)` — the
  contract Tint's `EmitBlockParent` defines at
  `/tmp/dawn-study/dawn-main/src/tint/lang/spirv/reader/parser/parser.cc:1799`.
  StopSet = set of block ids that terminate the current walk.
  Feature-flagged off; output identical to linear emitter.

- **Phase 3 — Selection emitter.**  ⏰ The mandelbrot bug fix lands
  here.  Selection construct (if/else) emitted by the walker
  through `EmitBranchConditional` (cite: parser.cc:3672).
  Behind feature flag, then enable selection-only — loops still
  go through linear.  Diff-validator must hold across phases.

- **Phase 4 — Loop emitter.**  Loop construct via
  `EmitLoop`/`EmitLoopMerge` (parser.cc:3754/3768).  Mandelbrot
  loop translates correctly through the walker.  Enable on
  fractal corpus; rest still linear.

- **Phase 5 — Switch + cutover.**  Sub-phased (5a/5b/5c) for
  bisect safety.  5a: switch emitter behind flag.  5b: walker is
  default; linear available via opt-in flag.  5c: linear deleted.
  Mandelbrot/julia/mandel_julia render correctly under the
  walker; smoke + diff both green.

- **Phase 6 — External corpus + hardening.**  Re-run the diff
  against all 181 Tint fixtures; lower the `tint_corpus_known_bugs`
  baseline to 0.  Add fuzz mutation (bit flips, opcode swaps in
  controlled positions) to verify the walker degrades gracefully.
  Cross-check render output against a software-rendered reference
  on the three fractal shaders.

- **Phase 7 — Retire linear walker.**  Delete the linear-emitter
  code path (the body-instruction helpers themselves stay — the
  walker uses them).  ~2000 LOC down.

- **Phase 8 — Re-enable demo.**  Remove the `out_color = red`
  diagnostic from `examples/mandelbrot_fs.zig`.  Re-add the
  removed engine triangles in `examples/wgpu_demo/wgpu_demo.zig`.
  Take new screenshots for the README.

- **Phase 9 — Docs + archival.**  Move
  `src/notes/archive/spv2wgsl-rewrite-plan.md` to
  `src/notes/archive/`.  Final entry in
  `src/notes/changelogs/spv2wgsl-rewrite-changelog.md`.  Update
  PLAN.md to mark this turn done.

**Status board** (mirror of
[`spv2wgsl-rewrite-plan.md`](archive/spv2wgsl-rewrite-plan.md) §8; that
file is authoritative if they diverge):

| Phase | Topic                          | Status   |
| ----- | ------------------------------ | -------- |
| 0     | Foundations                    | ✅ done   |
| 1     | BlockTable + module split      | ✅ done   |
| 2     | Walker scaffold + StopSet      | ✅ done   |
| 3     | Selection emitter              | ✅ done   |
| 4     | Loop emitter                   | ✅ done   |
| 5     | Switch + cutover               | 🔧 5a done |
| 6     | External corpus + hardening    | ✅ done   |
| 7     | Retire linear walker           | ⏸ low-pri |
| 8     | Re-enable demo                 | ✅ done   |
| 9     | Docs + archival                | ⏸ next   |

**Pure-Zig destination commitment** (reaffirmed this session):
the rewrite ships pure Zig.  Dawn source (`/tmp/dawn-study/`) is
study material, never compiled or imported.  The 181
`.spv`/`.spvasm` fixtures derived from Tint test source are now
ours (Apache 2.0 attribution in `tests/fixtures/external/tint/LICENSE.md`).
No npm, no Bun, no emscripten wasm.  `zig build wgpu-diff` is a
native test binary.  The TS scaffolding from Phase 0.1
(`webtests/spv2wgsl_diff.ts`, `tools/assemble_spvasm.mjs`,
`tools/extract_tint_fixtures.py`) was deleted in Phase 0.4.

**Property A progress at Turn 3.9 close:**
- ✅ GPU domain: correct WGSL across the entire 197-shader
  combined corpus
- ✅ Comptime domain: spv2wgsl is a comptime-Zig function; comptime
  unit tests can call it
- ✅ CPU/SW domain: not affected by this turn directly (turn 3
  already established the SW dispatch path); after Phase 5 the
  same shader source runs correctly on both GPU and SW
- Turn 4 unblocked → the headline demo can finally ship

---

### Turn 4.  wgpu-vs-sw split-screen demo (the headline)

**Status: ⏸ BLOCKED on Turn 3.9 Phase 5 (cutover).**

**Bonus deliverable from the May-2026 plan's step #8.**  Becomes
real once Turn 3.9 closes.

**Lands:** an example that renders left half via WgpuBackend (GPU,
in the browser) and right half via SwBackend (CPU, through rlsw)
with the **same source-of-truth shader**.  The cursor X position
is the divider — drag to reveal the seam, see where the
floating-point precision differs between GPU and CPU.

Same shader source.  Same UBO.  Different runtime.  Pixel-parity
in 99.9% of pixels.

**Why it matters:** this is the **headline demonstration** of the
zimr foundation.  Every future contributor sees this example and
gets it instantly.  Every blog post links it.  Every docs page
references it.

**Why it blocked:** the demo renders mandelbrot — the exact shader
class that hits the if-break/phi-overwrite bug.  Turn 4 cannot
demonstrate "same source, two backends, pixel parity" if one
backend renders the wrong picture.  Turn 3.9 fixes this; Turn 4
ships immediately after.

**Dependencies beyond Turn 3.9:**
- Either Turn 3.7 strategy (1) or (2) above — engine VS
  native-importability — to make Renderer2D's pipeline drive a
  real shapes shader through `sw_dispatch`.  Or accept that Turn 4
  uses a custom split-screen pipeline (matching `examples/mandelbrot_split.zig`'s
  pattern) that doesn't need codegen surgery.

**Risks:** scheduling — the GPU side runs on the next vsync, the
CPU side runs synchronously.  Need to make sure both sides see the
same frame's UBO.  Solved by running both per-frame in `update()`
with a shared `view_proj` matrix; the CPU side writes pixels into
a texture, the GPU side blits it to the swap-chain alongside the
GPU half.

**Acceptance:** the example builds, the smoke harness runs it for
60 frames without trap, the visual A/B is documented in a
screenshot checked into `src/web/`.

---

### Turn 3.7 (deferred)  Engine VS native-importability

**Status: ⏭ DEFERRED.  Blocked on codegen surgery.**

**What it would unlock:**

- `Renderer2D.shapes_pipeline.sw_dispatch` populated by the codegen
  for the engine's actual 2D shapes shader
- Turn 4 (the split-screen demo) — same shader runs on WgpuBackend
  AND SwBackend simultaneously
- Property A (one source, three domains) demonstrable end-to-end

**The blocker:**

Auto-generated `*_externs.zig` files use SPIR-V-only constructs at
module level:

```zig
pub const position_out = std.gpu.position_out;  // fails on native (x86)
pub extern const world_dir: @Vector(3, f32) addrspace(.input);
pub extern var out_color: @Vector(4, f32) addrspace(.output);
pub extern const sky_top: @Vector(3, f32) addrspace(.constant);
```

Each of these fails to compile on native targets — `addrspace(.input)`,
`.output`, `.constant` only exist for SPIR-V; `std.gpu.position_out`
uses one internally.

**Why the obvious fix doesn't work:**

Wrapping the SPIR-V-only decls in `const _Spirv = if (_is_spirv)
struct { ... } else struct { stubs };` makes the externs file
native-compatible.  Zig 0.16 lazy-evaluates comptime-dead struct
and function-body branches — verified with spikes (`/tmp/spike_externs.zig`,
`/tmp/spike_dead.zig`).

But: OLDER-PATTERN shaders (`skybox_fs`, `lambert_fs`, `default_vs`,
`default_fs`, `pbr_vs`, `shadow_vs`, `unlit_fs`, etc.) access the
module-level externs DIRECTLY: `shader_externs.world_dir`,
`shader_externs.frag_normal`, `shader_externs.mat_model`, etc.
Moving these into `_Spirv` makes them inaccessible via the dotted
name, breaking the old shaders' SPIR-V compile.

Two distinct API patterns coexist in the codebase:

- **New IoT-based pattern** (`default_shapes_vs/fs`, `mandelbrot_fs`,
  `cube_split_vs/fs`) — uses `shader_externs.IoT(Ubo)` and
  `shader_externs.Out` only; native-friendly if the externs file
  is wrapped.

- **Old direct-extern pattern** (10+ shaders listed above) — uses
  `shader_externs.world_dir`, etc. directly; SPIR-V-only by design.

**Three strategies to unblock:**

1. **Per-shader native shim files via `build.zig` routing.**  Codegen
   emits two files per shader (the SPIR-V externs and a native shim
   with IoT/Out/setup-stub only); `build.zig` wires the right one
   based on target.  Clean, no shader churn, but doubles codegen
   surface.

2. **Migrate old shaders to the new IoT pattern.**  Then `_Spirv`
   wrapping becomes safe — nothing reaches for module-level externs.
   Bigger churn (10+ files), better long-term hygiene.  Aligns with
   the S5-of-the-software-shader-plan goal that "after S5 the old
   emission drops."

3. **Standalone SW-only demos with inline shaders** (what we did in
   turn 3.5).  Sidesteps the codegen problem entirely.  Doesn't
   demonstrate "same source, both backends" but does demonstrate
   the architecture works.

Pick (1) or (2) before turn 4.  Turn 3.5 ships independently.

---

### Turn 5.  `Buffer(T)` unified abstraction

**Lands:** `pub fn Buffer(comptime T: type) type` — a typed wrapper
that's GPU-backed in wgpu mode and a host slice in SW mode:

```zig
pub fn Buffer(comptime T: type) type {
    return struct {
        gpu_handle: wgpu.BufferHandle = .invalid,
        cpu_data: ?[]T = null,
        len: u32 = 0,

        pub fn create(backend: anytype, ...) Self;
        pub fn write(self: *Self, offset: u32, items: []const T) void;
        pub fn read(self: *Self, gpa: Allocator) ![]T;
        pub fn slice(self: *Self) []T;  // SW only; panics on GPU
    };
}
```

Storage buffers, vertex buffers, index buffers, and UBOs all become
`Buffer(T)` with `usage` flags.  `StorageBuffer(T)` (the current
existing type) collapses into a typedef.

**Why it matters:** the unified resource type is the second seam of
property A.  Today the GPU and SW paths each need their own resource
plumbing; a unified `Buffer(T)` makes user code identical across
backends.

**Risks:** the GPU-side write goes through `queueWriteBuffer`; the
SW-side write is a memcpy into the host slice.  Same surface,
different mechanics.  The `read` operation is async on GPU (needs
mapAsync) and sync on SW.  May need to expose `readAsync` separately
for the GPU path.

**Acceptance:** existing `StorageBuffer(T)` usages migrate to
`Buffer(T, .{ .storage = true })`; the wgpu_demo_split (turn 4)
uses a unified `Buffer(PerFrameUbo)` shared between both halves.

---

### Turn 6.  `Texture(format)` unified abstraction

**Lands:** the texture analog of turn 5.  `Texture(format)` wraps
either a `wgpu.TextureHandle` or an `rlsw_pixel`-backed CPU image.

Engine paths (the 1×1 white shapes texture, checker textures,
user-loaded PNGs) all become `Texture(.rgba8)`.  `WgpuTexture` and
`WgpuRenderTexture` become specializations.

**Why it matters:** sampling a texture is the most common shader
operation.  Unifying it across backends is the third seam of
property A.  Without this, the SW-path can render flat colors but
can't sample.

**Risks:** texture formats are a long list (rgba8, rgba16f, rgba32f,
depth24plus, etc.).  Software-renderer support is limited (rlsw_pixel
has the table — extend it as needed).

**Acceptance:** `Texture(.rgba8)` covers every existing texture use
in the engine + smoke examples; the SW backend can sample a
4×4 checker texture and produce the same image as the GPU backend.

---

### Turn 7.  `ComputePipeline(KernelT)` + `dispatch(*ComputePass, x, y, z)`

**Lands:** the compute analog of `RenderPipeline(VsT, FsT)`.  A
compute kernel is a Zig function with `pub fn kernel(io: KernelT.Io)
void` (no return — writes to storage buffers in the IO).
`ComputePipeline(KernelT)` carries the type; the SW backend
dispatches by running `for x in 0..gx: for y in 0..gy: for z in
0..gz: KernelT.kernel(io)` where the IO's workgroup ID is set per
iteration.

**Why it matters:** compute is the gateway to everything outside
graphics — physics, NN, image processing, audio, all run as compute
on GPU.  Without a unified compute story, those demos can't be
single-source.

**Risks:** workgroup semantics.  WebGPU has workgroup-local memory
(shared between threads in a workgroup) and barriers.  CPU
simulation needs to fake these (a sequential dispatch suffices for
correctness, just not perf).  Document the divergence.

**Acceptance:** a tiny compute kernel that doubles every element of
a storage buffer dispatches identically on both backends and
produces the same output.

---

### Turn 8.  Comptime shader evaluation

**Lands:** the third seam of property A.  Test code can call:

```zig
test "mandelbrot center pixel is in the set" {
    const result = comptime mandelbrot_fs.shaderMain(.{
        .frag_tex_coord = .{ 0.5, 0.5 },
        .u = .{ .center = .{ -0.5, 0.0 }, .zoom = 1.5, .iterations = 256 },
    });
    try std.testing.expect(result.out_color[0] > 0.5); // mostly white
}
```

The shader IS a Zig function.  Calling it at `comptime` evaluates it
fully.  Result is a `const`.  No GPU, no test harness, no fixture —
just a pure-function unit test.

This requires shader sources to be **comptime-evaluable Zig**: no
externs without comptime fallbacks, no `callconv(.spirv_fragment)`
on the entry point (we factored that out long ago — `shaderMain` is
already plain Zig), no `@import("builtin")` branching that the SPIR-V
backend can't tolerate.  Most shaders already meet this bar.

**Why it matters:** shader correctness becomes a normal Zig test
discipline.  No "build, deploy, eyeball" loop.  Bugs land with a
red unit test.

**Risks:** sampler operations at comptime — the texture isn't
materialized.  Solution: provide a `ComptimeSampler` type the test
sets up explicitly with a static pixel array.

**Acceptance:** `tests/comptime_shader_tests.zig` runs at host-test
time and exercises 3-5 representative shader functions at
comptime, asserting expected outputs for known inputs.

---

### Turn 9.  Math library completeness — quaternions, SDFs, raymarching, color spaces

**Audit + extend** `zimrmath.zig`.  Today it has the basics (vec/mat,
trig, generic helpers).  Missing for the ambition tier:

- Quaternion type + slerp / quat-to-mat / mat-to-quat
- Signed-distance-field primitives: `sdSphere`, `sdBox`, `sdRoundBox`,
  `sdTorus`, `sdCylinder`, `sdCapsule`, plus the combinators
  (`opUnion`, `opSubtract`, `opSmoothUnion`, `opTransform`)
- Raymarching loop helper: `raymarchScene(comptime sceneFn, origin,
  dir, max_steps) → Hit`
- Color space conversions: linear↔sRGB, RGB↔HSV, RGB↔OKLab
- Random / hash primitives that work on GPU (PCG, xxhash)
- Useful matrix utilities: lookAt, perspective with reverse-Z,
  orthographic, projection inverses

**Why it matters:** the demos in §4 turns 16-20 use this library
heavily.  Building each demo with its own one-off implementations
fragments the codebase and prevents code-sharing.

**Risks:** SDF operations recurse through comptime fn pointers; need
to verify SPIR-V backend handles them.  PCG random needs both a host
and SPIR-V path that produce identical streams from the same seed
(property E — pixel-parity).

**Acceptance:** all new functions have host tests; SDF primitives have
a fixture image render at comptime that's pixel-parity to a GPU
render.

---

### Turn 10.  Multi-render-target + depth/stencil + MSAA

**Lands:** the engine path stops being "one color attachment, no
depth."  `BeginRenderPassDesc` extends to:

```zig
pub const BeginRenderPassDesc = struct {
    color_attachments: []const ColorAttachment,
    depth_stencil_attachment: ?DepthStencilAttachment = null,
    sample_count: u32 = 1,
    label: []const u8 = "render",
};
```

`Renderer2D` continues to use one color attachment + alpha blending;
deferred-rendering examples can opt into 3-4 color attachments
(albedo, normal, roughness/metallic, depth).  MSAA resolves at
end-of-pass; depth tests gate fragments.

**Why it matters:** any 3D scene needs depth.  Any modern PBR scene
needs MRT.  These are table-stakes for the demos that close the
plan.

**Risks:** the `descriptor_encoder.encodeRenderPipelineDescriptor`
format extends — backwards-compat is fine because we own both ends.
SW path renders MRT into separate rlsw color buffers; depth is
already in rlsw.

**Acceptance:** a deferred-shading toy example renders a cube into
3 color attachments + depth, composes them in a second pass, all
on both backends with pixel-parity.

---

### Turn 11.  Storage buffers as first-class typed bind-group entries

**Lands:** the typed shader IO supports storage buffers naturally:

```zig
pub const Io = struct {
    pub const Ubo = extern struct { time: f32, ... };
    pub const Storage = struct {
        particles: Buffer(Particle, .{ .read_write = true, .group = 2, .binding = 0 }),
        debug_log: Buffer(LogEntry, .{ .write_only = true, .group = 2, .binding = 1 }),
    };
    frag_tex_coord: Vec2 = undefined,
    ...
};
```

`shader_introspect` reads the schema, emits the right
`BindGroupLayoutEntry` with the right buffer-binding-type
(`storage` / `read-only-storage`); `loadShader` builds the bind
group for `Storage` fields the same way it does for samplers today.

**Why it matters:** storage buffers are the GPU's general-purpose
memory.  Without them being typed schema fields, every storage
buffer use is hand-wired and fragile.  Compute kernels, persistent
GPU state, and indirect draws (turn 13) all need this.

**Risks:** read-only vs read-write storage buffer visibility rules.
WebGPU is strict.  The DSL marker (turn 1) handles group/binding;
this extends it to access modes.

**Acceptance:** the SPH fluid example (`examples/sph_fluid_2d.zig`,
~900 LOC, currently hand-wires its storage buffers) refactors to
schema-driven bindings and shrinks 200+ LOC.

---

### Turn 12.  Render bundles + async pipeline compilation

**Lands:** two perf primitives WebGPU offers that we don't expose
today.

**Render bundles:**

```zig
const bundle_encoder = backend.createRenderBundleEncoder(...);
// record once
backend.setPipeline(bundle_encoder, ...);
backend.drawIndexed(...);
const bundle = backend.finishRenderBundle(bundle_encoder);

// each frame, just execute
backend.executeBundle(ps, bundle);
```

Bundles capture a static sequence of draw calls — the GPU records
them once, replays each frame at zero CPU cost.  Required for
UI-heavy scenes (imgui rendering, plot library, etc.).

**Async pipeline compilation:**

```zig
const pipeline_future = backend.createRenderPipelineAsync(...);
// continue with other work
const pipeline = try pipeline_future.await();
```

Pipeline compilation is the single most expensive WebGPU operation
(can be 50-500ms per pipeline).  Today we block on it.  Async lets
us mask the cost during loading screens.

**Why it matters:** UI rendering at 144Hz requires bundles; first-
frame snappiness requires async compilation.  Both are infrastructure
the demos depend on.

**Risks:** SW backend has trivial bundle semantics (just record the
sequence and re-execute on the host).  Async on SW is synchronous —
the future resolves immediately.

**Acceptance:** the engine `Renderer2D.flushBatch` optionally targets
a bundle for "UI mode" (static draws); the wgpu_demo_split (turn 4)
uses async pipeline compilation for the GPU half and shows a
loading message until the pipeline is ready.

---

### Turn 13.  Indirect draws + storage-buffer-driven scheduling

**Lands:**

```zig
backend.drawIndirect(ps, indirect_buffer, offset);
backend.drawIndexedIndirect(ps, indirect_buffer, offset);
backend.dispatchIndirect(compute_ps, indirect_buffer, offset);
```

A `Buffer(DrawArgs, .{ .indirect = true })` holds draw-call
arguments.  A compute kernel writes into it.  The GPU executes the
draws based on what compute wrote — no CPU readback.

**Why it matters:** this is the pattern that unlocks 10K+ entities
in a physics or particle simulation.  CPU never sees the per-entity
state; compute decides what to draw based on visibility / culling /
LOD.

**Risks:** SW path emulates this by running compute, then iterating
the indirect buffer on the host and issuing draws.  Slower but
correct.

**Acceptance:** a 10,000-particle compute-driven simulation in
`examples/particle_compute.zig` (new, ~250 LOC).  GPU runs it at
144Hz; SW runs it at ~5Hz (acceptable for debug).

---

### Turn 14.  Timestamp queries + perf counters

**Lands:**

```zig
const query_set = backend.createQuerySet(.timestamp, 8);
backend.writeTimestamp(ps, query_set, 0);
// ... draws ...
backend.writeTimestamp(ps, query_set, 1);
const elapsed_ns: u64 = try backend.resolveQuery(query_set, 0, 1);
```

Plus a host-side counter for the SW backend so the same API works
on both.

**Why it matters:** **we can't claim performance we can't measure.**
Today everything is "feels fast" or "slow."  Real timestamps are
the difference between honest engineering and storytelling.

**Risks:** Chrome requires the `timestamp-query` feature in the
adapter request — add it.  Some adapters don't support it; fall
back to CPU-side measurement with a warning.

**Acceptance:** every demo (turns 16-20) prints a perf summary line
on shutdown: `[demo] avg frame ms: 6.2  GPU: 4.8  CPU: 1.1`.

---

### Turn 15.  Vertex shader CPU path + full SW triangle rasterizer through the trait

**Lands:** the SW backend's `setVertexBuffer` + `setIndexBuffer` + a
real rasterization path:

- `dispatchVertexShader(ctx, VsT, vertex_data) → []VertexOut` — runs
  the VS function for every vertex in the input buffer, produces
  clip-space outputs.
- `rasterizeTriangles(ctx, vertex_outs, indices, FsT, fragment_io_base)`
  — clips, perspective-divides, scan-converts, calls
  `dispatchFragmentShader` per pixel covered, with varyings
  interpolated.

Both already exist in `rlsw_shader.zig`.  Wiring them into the
trait's flushBatch closes the loop: the SW backend can render
ANY scene the GPU backend can render, not just batched 2D shapes.

**Why it matters:** without this, the SW path is 2D-only.  The
ambition (raytracers, physics, NN) needs full 3D rendering on both
backends — property A demands it.

**Risks:** correctness of the rasterizer at edge cases (degenerate
triangles, sub-pixel precision, depth interpolation).  Adopt
`rlsw_shader.zig`'s tests + extend with fixture renders.

**Acceptance:** a 3D cube spinning on both backends with pixel-parity
(modulo expected FP precision divergence < 1% of pixels off by ≤2
LSBs).

---

### Turn 16.  Demo — Path-traced cornell box (compute on GPU)

**The crown demo of the foundation.**

A compute shader implements a Whitted-style ray tracer (later
extended to path tracing) over a fixed cornell-box scene.  Storage
buffer holds the scene geometry (a few quads + a sphere).  Compute
kernel traces N rays per pixel, accumulates radiance.  Second
kernel does temporal accumulation across frames.  Final pass blits
the accumulator to the screen.

**Same source** runs on CPU (turn 7 made compute SW-dispatchable) —
runs at 0.1Hz instead of 60Hz, but produces the same image modulo
FP precision.

**Why it matters:** the absolute proof that the foundation can do
what the dream demands.  A path tracer is the canonical "real
compute workload."  Running it on both backends with pixel parity
is the strongest possible statement of property A.

**Acceptance:** a screenshot at the top of the readme.  Frame rate
counter visible.  CPU vs GPU toggle in the demo.  Existing
`examples/raytracer.zig` (964 LOC, GL-only today) gets a wgpu sibling
that exercises the new compute path.

---

### Turn 17.  Demo — Rigid-body physics, 10K bodies, deterministic

**A compute-driven physics simulation.**

Each rigid body is 64 bytes in a storage buffer (position, velocity,
angular velocity, mass, restitution, friction, the basics).  A
compute kernel applies forces and integrates.  A second kernel
does collision detection (spatial hash grid).  A third resolves
contacts.  Indirect-draw integration submits one draw per body.

**Determinism:** every kernel reads + writes storage buffers with no
dependence on dispatch order.  Two browsers running the same scene
produce bit-identical state.

**Why it matters:** this is the foundation for "distributed game
engine on GPU."  Two clients can sync only the input (forces, user
actions); the simulation state is recomputable from the input
history.

**Acceptance:** 10K boxes in a pile, settling under gravity, at
144Hz on the GPU.  CPU runs the same scene at ~3Hz, output is
state-deterministic match (positions agree to ε after N steps).

---

### Turn 18.  Demo — Tiny convolutional neural network inference

**A small MNIST-class CNN on the GPU.**

Weights live in storage buffers (loaded from a `@embedFile`).  Each
convolution layer is a compute kernel; each pooling layer is a
compute kernel; the final dense layer is a compute kernel.

User draws a digit in the browser canvas.  Pixels go to a storage
buffer.  Inference kernels run.  Output probabilities update in
real time.

**Why it matters:** zimr can do machine learning.  Not as a one-off
research stunt — as a natural consequence of the compute story.
Same code runs on CPU for debugging.

**Acceptance:** the user can draw a digit and the network predicts.
Inference latency < 16ms on GPU, < 500ms on CPU.

---

### Turn 19.  Demo — FM synthesizer / audio compute

**Audio is compute, just with a different output device.**

A compute kernel produces 4096 audio samples per dispatch (one
chunk).  The output storage buffer maps to a `Float32Array` that
Web Audio API consumes via an `AudioWorkletNode`.  Patches (frequency,
modulation index, envelope) come from UBOs.

**Why it matters:** zimr is a creative tool, not just a renderer.
Sound + visuals from the same compute primitives makes
audio-visualizer demos trivial.

**Acceptance:** a synthesizer playable with the QWERTY keyboard;
visual oscilloscope of the output waveform; ASIO-grade latency
(< 20ms keypress-to-sound).

---

### Turn 20.  The Crown Demo — `crown.zig`

**A single file, under 500 lines, that uses everything.**

The shopping list:

- Compute kernel that simulates a fluid (SPH or grid-based)
- Storage buffer for particles, written by compute, read by render
- Indirect draw — particles register their visibility, draws happen
  on GPU
- A render pass with MRT (color + depth + motion vectors)
- Async pipeline compilation during the loading splash
- Render bundle for the static UI overlay
- A second compute kernel that does post-process (DOF + bloom) on
  the rendered image
- Audio synthesis tied to the simulation (fluid pressure → bass
  note frequency)
- Profiling overlay showing GPU + CPU timestamps
- Toggleable CPU-only mode (runs at 5Hz but works)

This is the "this is what zimr can do" demo.  500 lines, uses every
foundation piece, looks stunning.

**Why it matters:** this is the demo that wins hearts.  Every
new contributor to zimr's docs page sees this and gets the vision.

**Acceptance:** it ships.  It's the readme hero shot.  It's the
talk demo.  It's what "zimr" means in 2026.

---

## §5.  Risks, contradictions, escape hatches

### The contradictions Simon flagged

> **"performant, explicit, simple. Some of these goals might be
> contradictory."**

They are.  Where the plan resolves them:

**Performant vs. simple.**  The SW backend is *deliberately* not
performant — it's the simple, debuggable, ground-truth path.  The
WGPU backend is fast.  The user chooses which to run.  The same
*source* compiles to both; the *runtime* shape diverges.  We don't
pretend the SW path is fast.  We pretend the source is the same
(which it actually is).

**Mach explicitness vs. raygpu sugar.**  Layered, never hidden.  The
explicit lower layer is always reachable.  Helpers compose, they
don't gate.  When `Renderer2D.drawRectangle(ps, ...)` does something
you don't like, you read its source — it's 8 lines.  You write
your own.

**Comptime vs. runtime.**  Comptime is for tests and
specialization.  It is NOT a runtime path — `comptime mandelbrot(...)`
produces a `const`, not a function pointer.  Don't confuse the
test convenience with a deployment target.

**Generality vs. focus.**  zimr's TARGET is hobby graphics + game
developers.  Not a JAX competitor.  Not a TensorFlow.  When we add
"NN inference," we add the primitives that let someone build a tiny
classifier in a 200-line example.  Not a framework.

### Known unknowns

- **WebGPU adapter feature flags vary.**  `timestamp-query`,
  `shader-f16`, `depth32float-stencil8` — not all browsers support
  all of them.  Our code paths must gracefully degrade.
- **SPIR-V compute support in Zig 0.16.**  The `target spirv32-vulkan`
  compute capability is real but lightly tested.  Turn 7 may surface
  compiler bugs.
- **Async + wasm + reactor model.**  WebGPU's async pipeline
  compilation needs an event loop.  zimr's wasi-reactor model
  doesn't have one.  The implementation in turn 12 may end up
  exposing a callback pattern rather than a `Future` type.

### Escape hatches

If turn 7 (compute) hits Zig SPIR-V compiler bugs, we can fall back
to hand-written WGSL for compute kernels temporarily, with a clear
note that this is the only exception to Rule 1 until the compiler
catches up.  This is honest about scope, not a retreat.

If turn 8 (comptime shader eval) is too restrictive (the shader
calls `@sin` which has no comptime impl), we add a `comptime` shim
in zimrmath that provides high-precision pure-Zig versions for
testing.  The shader doesn't change; the test does.

If turn 13 (indirect draws) is slow on the SW backend, that's
fine — SW path is the debug oracle, not the perf target.  Document
the expected divergence.

---

## §6.  How we know we're done

After 20 turns, this is true:

1. **`zig build tier-a-check`** is green in under 15s warm; the same
   command on a fresh clone is green in under 6 minutes cold.
2. **Smoke harness** is 134+/134+ passing.  Every new demo adds a
   smoke test.
3. **One canonical example, `examples/crown.zig`,** demonstrates the
   foundation: under 500 lines, uses every primitive, runs on both
   backends.
4. **Five demo screenshots** in the readme: cornell box, physics
   pile, NN classifier, synthesizer waveform, the crown demo.
5. **Property A** is empirically demonstrated by a pixel-parity
   test suite running every commit: ≥99% of pixels agree between
   GPU and SW backends across a corpus of 20+ reference shaders.
6. **The build pipeline is self-contained:** no `/tmp/` deps;
   SPIRV-Headers grammar vendored (the May-2026 plan's step #10
   slots in here); tools build from `tools/` to `tools/zig-out/bin/`.
7. **The user-facing import surface** (`@import("zimr_wgpu")`) is
   stable: every public type carries doc comments, every public
   function has a header explaining what it does and at least one
   example.
8. **One end-to-end tutorial** (`src/notes/tutorials/crown-tour.md`)
   walks a new contributor from "I cloned the repo" to "I drew my
   first triangle" to "I dispatched my first compute kernel" to
   "I added a new shader to the engine" in ~2 hours of reading +
   doing.
9. **`src/notes/finishing_new_gpu_foundations.md`** — this file —
   is updated to mark each turn complete, with a one-paragraph
   retrospective of what was harder/easier than expected.
10. **A blog post draft** in `src/notes/posts/why-zig-for-gpu.md`
    that's the public articulation of the bet.  Not published from
    here, just drafted, so when Simon decides to share, the words
    exist.

---

## §7.  The deeper ambitions, post-turn-20

This plan covers 20 sessions.  Past that:

**The distributed game engine.**  Two browsers, WebRTC data channel,
sync only inputs, both sides run the same compute kernels on
identical storage buffers.  Frame N is bit-identical (modulo
floating-point) on both sides.  A multiplayer experience that
needs no server logic — the simulation IS the consensus.

**Comptime shader specialization.**  `loadShader(SchemaT, .{
.constants = .{ .resolution = .{ 1920, 1080 } } })` triggers a
re-translation of the shader with those constants baked in.  Loop
unrolling, dead-branch elimination, GPU-side denormalization — all
at build time.

**JIT shader recompilation.**  In dev mode, edit a shader source,
save, the file watcher kicks a rebuild, the new wasm hot-replaces
the old one, the GPU state survives.  Hot reload as a first-class
workflow.

**Inverse rendering / differentiable graphics.**  Auto-diff through
the SW path (because it's pure Zig and we control the call graph).
Optimize a scene's material parameters to match a target image.
Educational, beautiful, the kind of thing that makes people share.

**A native desktop target.**  Today zimr targets browser only (wasm
+ WebGPU/WebGL2).  A `dawn`-backed native target via a separate
JS-bridge replacement.  Same source, different bridge, native
performance.

**A scientific computing crowd.**  Once compute is unified, the
audience extends beyond game devs.  Plot library + SDF + NN +
compute + audio = the "Mathematica for Zig people" demo.  Not the
target.  But a natural consequence.

---

## §8.  The closing word

Three months ago, zimr's wgpu side was scaffolding with hand-written
WGSL, a single backend, hidden state, and an aspirational SW path
that didn't work.

Today, after the May-2026 arc, it's an engine on its own typed shader
pipeline, with mach-style explicit passes and a clean separation of
GPU and drawing-layer concerns.  Six of the ten birds-eye items shipped.

This plan takes it further.  Twenty more sessions.  Each one a
contained chunk.  Each one moving the foundation toward
"theoretically optimal basis for simple low-level CPU/GPU code in
Zig."

The contradiction Simon worried about — "performant, explicit,
simple, ambitious, all at once" — isn't resolved by compromise.
It's resolved by **putting the right things at the right layer**.
The lowest layer is performant + explicit.  The middle layer adds
sugar without hiding.  The application layer reaches for ambition
because the layers below carry weight without bending.

We're not done.  We have not yet begun to ship.

Onward.

— Claude + Simon, May 2026
