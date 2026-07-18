# shader_unification_eval.md — should we port all shaders to the IoT pattern?

Evaluation of unifying zimr's two shader-authoring patterns onto the
typed `_io.zig` IoT interface. Requested after the decal work, on the
principle that one type-safe way is better than two.

## The two patterns today

**IoT** (`<name>_{vs,fs}.zig` + `<name>_{vs,fs}_io.zig` + optional
`<name>_common_io.zig`): the body is a plain `shaderMain(io_in: Io) Out`
that reads uniforms/attributes as typed fields (`io_in.frag_normal`) and
samples via a typed method (`io_in.texture0(uv)`). A codegen step reads
the `_io.zig` schema and emits an `*_externs` module with the real
`@extern` SPIR-V bindings + an `IoT(Ubo)` wrapper type; the host binds
via `shader.Resources(Schema)` which auto-generates bind-group layouts.
Used by 40 shaders — every material/lighting family (cube3d, pbr,
gbuffer, lambert, lit_shadow, deferred, depth, the 2D effects…).

**Direct** (`<name>_{vs,fs}.zig`, no `_io`): the body is
`export fn entry()` that declares each binding with a raw
`@extern(*addrspace(.uniform|.input|.output|.constant), .{…})` and reads
`spirv.vertex_index` / `spirv.position_out` directly; samples via
`zsample2d(sampler, uv)` + a manual `binding(&sampler, group, bind)`.
The host hand-writes the bind-group layouts + pipeline layout. Used by 5
shaders: billboard, skybox, points, fluid_discs, decal.

## What IoT buys (the pros of porting everything)

1. **One mental model.** New contributors learn `shaderMain(io) Out` +
   a schema, full stop. No "is this a direct or IoT shader?" fork.
2. **Type-safe, named bindings.** `io_in.col_diffuse` vs
   `@extern(*addrspace(.uniform) const Uniforms, .{.name="u",
   .decoration=.{.descriptor=.{.set=1,.binding=0}}})`. The schema names
   the field once; the codegen assigns group/binding by the documented
   §3 rule (VS uniforms→0, samplers→1, FS uniforms→2). No hand-counted
   set/binding integers to get wrong — and getting them wrong is a
   silent GPU bug, exactly the class that cost us turns on decal.
3. **VS-out == FS-in by construction.** `_common_io.zig` defines the
   `Interp` varyings once; both stages alias it. A direct shader repeats
   the varying `@extern`s in both files with matching `.location` — a
   manual contract that drifts.
4. **Auto host wiring.** `Resources(Schema).init` generates the
   bind-group layouts from the schema. The direct decal shader needed
   ~35 lines of hand-written `BindGroupLayoutEntry` + `createBindGroupLayout`
   + `createPipelineLayout` in draw3d.zig; an IoT version needs ~2.
5. **The sampler-in-branch lint already covers IoT natively.** (The
   direct path only got covered after decal slipped through — see
   zimr557.) Uniform-scope discipline is easier to enforce on one shape.

## What porting COSTS (the cons)

### The per-shader boilerplate is real but small

The "tax" of IoT is the schema file(s). Minimal FS schema
(`cube3d_fs_io.zig`, a pass-through with no uniforms/samplers) is **19
lines**, most of it doc comment; the mechanical part is:

```zig
const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("cube3d_common_io.zig");
pub const Inputs = common.Interp;
pub const Outputs = struct { final_color: Vec };
```

— 5 real lines. A VS schema adds an `Attributes` struct (one
`shader.Attr(.vecN, loc)` per vertex input) and a `Ubo`/`Uniforms`
struct. A `_common_io.zig` (only if VS+FS share varyings) is ~5 real
lines. So the tax per shader is roughly:

| shader shape                | extra IoT files | ~real lines |
|-----------------------------|-----------------|-------------|
| FS pass-through             | 1 (`_fs_io`)    | 5           |
| VS + FS sharing varyings    | 3 (`_vs_io`, `_fs_io`, `_common_io`) | 20–30 |
| + a sampler                 | +1 line in `_fs_io` (`Sampler2D(.albedo,.{})`) | +1 |

Against that, IoT REMOVES the per-binding `@extern` blocks from the body
(each is 3–4 lines) and the host-side bind-group hand-wiring. For a
shader with 3+ bindings the net line count is close to a wash; the win is
type-safety, not brevity.

### The blocking gaps — things IoT can't (currently) express

This is the crux. Three of the five direct shaders use features the IoT
schema has no vocabulary for:

**A. Read-only storage buffers (SSBOs).** `points_vs` and
`fluid_discs_vs` read `positions[instance_index]` from a
`storageBuffer(Vec2, "positions", 0, 1)`. The `zm.storageBuffer` helper
works in any body (IoT bodies import `zm` too), BUT the IoT *schema*
(`Attributes`/`Samplers`/`Uniforms`) has no `StorageBuffer` member kind,
so:
  - the host-side `Resources(Schema)` can't auto-generate the SSBO
    bind-group layout — you'd still hand-write it, defeating pro #4; and
  - the binding group/index for the SSBO is passed as literal args to
    `storageBuffer(...)` in the body, i.e. still a hand-counted integer,
    defeating pro #2 for exactly the shaders that need it most.
  So these two could be *mechanically* ported (body compiles) but would
  be HALF-IoT: typed varyings, untyped storage bindings. That's arguably
  worse than an honest direct shader — it looks uniform but isn't.

**B. `@builtin` inputs as first-class schema members.** skybox/points/
fluid read `spirv.vertex_index` / `instance_index`. The generated
externs DO expose these (`shader_externs.vertex_index`), so an IoT body
CAN read them — but they're not schema fields, so they sit outside the
`io_in` object as a side-channel. Tolerable, not clean.

**C. Non-standard bind-group layouts.** IoT's binding scheme is FIXED
and stage-segregated: group 0 = VS uniforms, group 1 = samplers, group 2
= FS uniforms (zimr.zig §3). The decal shader deliberately uses group 0 =
shared camera UBO (VS), group 1 = per-decal projector UBO (FS), group 2 =
sampler — because the projector UBO is ring-buffered with 64 pre-built
per-slot bind groups (the dynamic-offset workaround). IoT would force the
projector uniform to group 2 and the sampler to group 1, and it owns
bind-group creation — so the 64-slot ring (which is the whole reason the
decal pipeline avoids clobber) would have to be retrofitted onto or
around `Resources`, which assumes one bind group per schema. This is the
hardest case: decal's host-side resource management is bespoke by
necessity, and IoT's auto-wiring actively fights it.

### The `_common` machinery only pays off with siblings

IoT's headline safety feature — VS-out == FS-in via a shared
`_common_io` — has value only when a VS and FS actually share varyings
AND evolve together. billboard/skybox/points/fluid/decal are each a lone
pipeline with 1–2 trivial varyings and a single consumer. For them the
`_common` file is pure ceremony: a third file to hold `struct { uv: Vec2,
col: Vec }`. The audit (zimr554) found ZERO drift precisely because these
are one-offs — there's nothing to drift against.

## Verdict

**Port the shaders that fit; keep a small, documented direct escape
hatch for the shaders that don't.** Specifically:

- **decal** → candidate to port, but its bespoke ring-buffered bind
  groups mean IoT's `Resources` auto-wiring saves little and complicates
  the ring. LOW priority; only if we generalize `Resources` to support
  a UBO ring first.
- **billboard, skybox** → cleanest port candidates (uniform + varyings +
  one sampler for billboard; vertex_index for skybox). The vertex_index
  side-channel is the only wart. MEDIUM value — mostly consistency.
- **points, fluid_discs** → SHOULD stay direct until IoT gains a
  first-class `StorageBuffer` schema member. Porting them now yields a
  dishonest half-IoT shader with hand-counted SSBO bindings.

**The real recommendation:** the two-pattern split is not an accident to
be erased — it tracks a genuine capability boundary. IoT is the right
default and already covers 40/45 shaders; the 5 direct shaders are
exactly the ones using storage buffers, raw builtins, or bespoke
bind-group topologies that the schema can't yet name. The highest-value
work is NOT porting all five — it's **closing the IoT capability gaps**
so "direct" becomes a true rarity:

1. Add a `StorageBuffer(Elem, .{.group, .binding, .readonly})` schema
   member + `Resources` auto-layout for it. Unblocks points + fluid, and
   any future compute-fed rendering. (Biggest single win.)
2. Add schema-level `@builtin` declarations (`Builtins = struct {
   vertex_index: u32, instance_index: u32 }`) so they're part of `io_in`.
3. Optionally let a schema opt out of the fixed §3 group scheme with
   explicit `@group/@binding` per member, for cases like decal.

With (1)+(2) done, points/fluid/skybox port cleanly and only decal (with
its ring) stays direct — a defensible single exception rather than a
parallel pattern. Without them, forcing a port makes the codebase LESS
honest, not more.

**Boilerplate bottom line:** porting a fitting shader adds ~20–30 lines
of schema (mostly one-time, mostly type declarations) and removes a
comparable amount of body `@extern` + host bind-group code — roughly
neutral on line count, a clear win on type-safety. Porting a
non-fitting shader (SSBO/ring) adds the schema tax AND keeps the manual
binding code, a net loss until the gaps above are closed.

---

## UPDATE — experiment run: all gaps are CLOSABLE (interface does not fail)

Ran the hardest-case experiment (see `shader_gap_experiments.md`):
ported fluid_discs_vs — 2 read-only SSBOs indexed by instance_index +
vertex_index quad expansion — to IoT, and verified it compiles to SPIR-V
AND transpiles to correct WGSL end-to-end.

Added to the interface (kept in-tree):
- `shader.StorageBuf(Elem, .read|.read_write)` + `Storage` schema section.
  Codegen emits the `storageBuffer` extern + an `io.<name>(i)` accessor;
  binds in the stage's uniform group after the Ubo (matches hand-wired).
- `shader.Builtin(.vertex_index|.instance_index)` + `Builtins` section.
  Accessor reads `std.spirv.<name>` (can't const-alias — it's a magic
  extern, which the experiment caught).

Emitted WGSL for the ported shader:
```
@group(0) @binding(0) var<uniform> u
@group(0) @binding(1) var<storage, read> positions
@group(0) @binding(2) var<storage, read> density
@builtin(vertex_index) / @builtin(instance_index)
```
— identical binding layout to fluid's hand-wired host code.

**Revised verdict:** gap A (SSBO) and gap B (builtins) are now closed at
the interface level. Gap C (decal's ring) was never an interface gap —
the decal SHADER types cleanly in IoT; only the host `Resources` needs
an N-bind-group ring mode (additive, non-blocking). So: **the interface
can express every shader we have.** Nothing is impossible. The remaining
work is production wiring (auto-bind the SSBO layout in `Resources`, then
port points/fluid/billboard/skybox for real), not interface design.
