# Experiment: closing the IoT shader-interface gaps

Goal: prove the typed IoT interface can express EVERY shader we have,
including the hardest (fluid_discs: 2 read-only SSBOs indexed by
instance_index + vertex_index quad expansion). If it can't, the
interface has failed and needs redesign.

## Gaps identified (from shader_unification_eval.md)

- **A. Read-only storage buffers** — no `Storage` schema section that
  the codegen emits + `Resources` auto-binds. (Partial dead scaffolding
  exists: `autoStorageBindGroupLayout` in shader_introspect.zig refs a
  `StorageBuf(T,.read)` marker that was never defined, and puts storage
  at group 3 = compute-only. Wrong for vertex-stage fluid.)
- **B. `@builtin` inputs** (`vertex_index`/`instance_index`) — reachable
  via `shader_externs.vertex_index` but not schema members.
- **C. Non-standard bind-group layouts** (decal's ring) — the fixed §3
  group scheme + one-bg-per-schema `Resources` assumption.

## Design decisions (before coding)

### A. Storage buffers — `Storage` schema section

SSBOs bind in the SAME group as the stage's UBO, at bindings AFTER it.
For a VS shader: UBO at group 0 binding 0, SSBOs at group 0 bindings
1,2,3… This EXACTLY matches fluid's existing hand-wired layout
(`u`@(0,0), `positions`@(0,1), `density`@(0,2)), so no WGSL churn.

Marker: `StorageBuf(Elem, .read | .read_write)` — carries the element
type + access. Schema:
```zig
pub const Storage = struct {
    positions: shader.StorageBuf(Vec2, .read),
    density:   shader.StorageBuf(Vec2, .read),
};
```

Body access: the codegen emits, per field, the `storageBuffer(...)`
extern + an accessor so the body reads `io.positions(ii)` — parallel to
the sampler `io.albedo(uv)` pattern. Binding index = UBO present ? 1+i :
i. Group = the stage's uniform group (0 for VS).

### B. Builtins — `Builtins` schema section (optional)

```zig
pub const Builtins = struct {
    vertex_index: u32,
    instance_index: u32,
};
```
Codegen maps each to the matching `std.spirv.*`, exposed as `io.vertex_index`.
Zero binding cost (they're SPIR-V builtins, not descriptors). This is
pure ergonomics — the values are already reachable — so it's low-risk.

### C. Decal ring — explicit per-field binding + a ring-aware Resources

Deferred: decal's 64-slot ring is a host-side resource-management
concern, not an interface-expressiveness one. The SHADER can be
expressed in IoT (UBO + sampler); only the host ring needs `Resources`
to support N pre-built bind groups. Treat as a Resources feature, not an
interface gap. (If the shader can be typed, the interface hasn't failed;
the host wiring is a separate ergonomic.)

## Results (filled in as experiments run)

### VERDICT: the interface CAN express every shape. No failure.

Built the full IoT port of the hardest shader (fluid_discs → `xfluid_vs`):
2 read-only SSBOs indexed by `instance_index` + `vertex_index` quad
expansion. Result: it compiles to SPIR-V (13KB, clean) and transpiles to
valid WGSL (389 lines, ZERO errors/TODOs/unsupported). The emitted
bindings are byte-identical to fluid's hand-wired layout:

```wgsl
@group(0) @binding(0) var<uniform> u: S18;
@group(0) @binding(1) var<storage, read> positions: S856;
@group(0) @binding(2) var<storage, read> density: S856;
@builtin(vertex_index) vertex_index: u32,
@builtin(instance_index) instance_index: u32,
```

The body reads `io.positions(ii)`, `io.density(ii)`, `io.vertex_index()`,
`io.instance_index()`, `io.u` — fully typed, no raw `@extern`, no
hand-counted set/binding integers.

### What it took (the actual mechanism, now in the codebase)

**Gap A — storage buffers (CLOSED):**
- `shader_interface.zig`: new `StorageBuf(Elem, .read|.read_write)` marker
  + `StorageAccess` enum.
- `gen_shader_externs.zig`: a `Storage` schema section. Per field it
  emits `storageBuffer(Elem, name, group, binding)` (group = the stage's
  uniform group; binding = after the Ubo) + an `io.<name>(i)` accessor
  wrapping `ssboLoad`. CPU-side `_<name>: []const Elem` slice field for
  the software rasterizer path.
- (Still TODO for a full promotion: `Resources`/`autoStorageBindGroupLayout`
  host auto-binding — the existing `autoStorageBindGroupLayout` puts
  storage at group 3, needs the same in-uniform-group rule. Host wiring,
  not interface expressiveness — the SHADER is fully typed already.)

**Gap B — builtins (CLOSED):**
- `Builtin(.vertex_index|.instance_index)` marker + `Builtins` schema
  section. GOTCHA found by the experiment: `std.spirv.vertex_index` is a
  magic extern VALUE, not a comptime const — can't `const`-alias it
  (`error: unable to resolve comptime value`). Fix: the accessor reads
  `std.spirv.<name>` DIRECTLY inside its `if (comptime isSpirV())` branch;
  no intermediate const. Works.

**Gap C — decal ring (interface: NOT a gap; host: a Resources feature):**
The decal SHADER is expressible in IoT today (UBO + sampler). Only the
64-slot ring is bespoke, and that's host resource-management, not
interface expressiveness. `SamplerConfig.pinned` already lets a schema
pin explicit `(group, binding)` cells, so even decal's non-standard
sampler group is expressible. Verdict: no interface failure; a
ring-aware `Resources` is a separate ergonomic nicety.

### Bugs the experiment surfaced (each a real hardening)
1. void storage fields not initialized in the entry wrapper's io literal
   (`missing struct field: _positions`) → init them like samplers.
2. builtin const-alias doesn't resolve at comptime → read std.spirv in
   the accessor directly.
Both fixed; both would have bitten a naive first implementation.

### Conclusion
The IoT interface is NOT missing any expressive capability. Every shader
we have — including the storage-buffer + builtin fluid shader that
motivated keeping a "direct escape hatch" — is now expressible with full
type safety. The remaining work to actually PROMOTE the direct shaders is
host-side auto-binding (Resources storage support + a ring option), which
is convenience, not capability. The earlier "we've failed if we can't
express X" bar is cleared: there is no such X.


## RESULTS — all three gaps CLOSED

**Experiment: ported fluid_discs_vs (2 read-only SSBOs + vertex_index +
instance_index — the hardest shader) to IoT as `xfluid_vs`.**

Interface additions made (all in shader_interface.zig + gen_shader_externs.zig):
- `StorageBuf(Elem, .read|.read_write)` marker + `StorageAccess` enum.
- `Builtin(.vertex_index|.instance_index)` marker + `BuiltinKind` enum.
- Codegen emits, per `Storage` field: `storageBuffer(Elem, name, group,
  binding)` extern (group = stage's uniform group, binding = after the
  Ubo) + an `io.<name>(i)` accessor calling `ssboLoad`.
- Codegen emits, per `Builtins` field: an `io.<name>()` accessor reading
  `std.spirv.<name>` directly.
- IoT() wrapper: CPU `_<name>` slice fields for storage; void-inits them
  on SPIR-V in the entry wrapper.

Bugs the experiment surfaced (each a real interface-completeness issue,
now fixed):
1. Missing struct field `_positions` — the entry wrapper didn't init the
   storage void fields. Fixed: init `._<name> = {}` alongside samplers.
2. `unable to resolve comptime value` on `_builtin_vertex_index` — you
   CANNOT `const`-alias `std.spirv.vertex_index` (it's a magic extern
   value, not comptime). Fixed: accessor reads `std.spirv.<name>`
   inline; no const alias.

**Verified end-to-end:**
- `zig build-obj -target spirv32-vulkan ... xfluid_vs.zig` → rc=0 (SPIR-V
  compiled).
- `zspv` rewrite → rc=0.
- `spv2wgsl` → rc=0, emitting:
    @group(0) @binding(0) var<uniform> u
    @group(0) @binding(1) var<storage, read> positions
    @group(0) @binding(2) var<storage, read> density
    @builtin(vertex_index) / @builtin(instance_index)
  — binding layout IDENTICAL to fluid's hand-wired host layout.

## Conclusion

The interface does NOT fail. With `StorageBuf` + `Builtin` schema
members, IoT expresses every shader we have, including the hardest.
Gap C (decal's ring) remains a HOST-side resource-management ergonomic,
not an interface-expressiveness gap — the decal SHADER types fine in
IoT; only `Resources` needs an N-bind-group ring mode, which is additive
and doesn't block expressing the shader.

Remaining to make this production (follow-up, not done here):
- Wire `autoStorageBindGroupLayout` (already exists, wrong group) to the
  new in-stage-group scheme so `Resources` auto-binds SSBOs.
- Port points_vs + fluid_discs_vs for real (replace the direct versions),
  gate, ship.
- Then billboard/skybox port (no SSBO, trivial after this).

## DERISK: decal port (gap C) — the truth is MUCH better than feared

Question: put the last direct shader (decal) on IoT. Earlier assessment
feared multi-UBO schemas + new UBO pinning + a Resources ring mode.

KEY FINDING from reading the real shaders: the decal's two UBOs are
CLEANLY STAGE-SEGREGATED.
  - decal_vs reads ONLY `cam` (camera UBO @group0).
  - decal_fs reads ONLY `proj` (projector UBO @group1) + the sampler
    (@group2). The FS's group-0 camera UBO is "unused, layout parity".

So there is NO multi-UBO problem: each stage schema has exactly ONE
Ubo. The only non-standard thing is the FS layout — projector UBO at
group 1 (not the default FS group 2), texture at group 2 (not the
default sampler group 1). A SWAP, solved by two pins that ALREADY EXIST:
  - `pub const ubo_group: u32 = 1;` — honored by
    shader_interface.uniformGroupForSchema (the mechanism was already
    built, with the decal named in its doc comment).
  - `Sampler2D(.albedo, .{ .pinned = .{ .group = 2, .binding = 0 } })` —
    existing sampler pinning.

EXPERIMENT (xdecal_vs/fs + _io, since removed): wrote the two schemas +
bodies with those two pins. Verified end-to-end:
  - codegen emitted `zm_binding(&u, 1, ...)` (projector @group1) and
    `zm_binding(&decal_sampler2d, 2, 0)` (texture @group2).
  - build-obj spirv32 rc=0 (both stages); zspv rc=0; spv2wgsl rc=0.
  - FS WGSL: `@group(1)@binding(0) var<uniform> u`,
    `@group(2)@binding(0) var decal: texture_2d`,
    `@group(2)@binding(1) var decal_sampler`.
  - VS WGSL: `@group(0)@binding(0) var<uniform> u`, attrs p@0/n@1,
    varyings o_world@0/o_normal@1.
  — IDENTICAL to the direct decal layout (cam@0, proj@1, tex@2).

VERDICT: the decal SHADER is portable to IoT with ZERO new
infrastructure. The 64-slot projector-UBO RING stays a pure host
concern — the FS schema only sees "a UBO at group 1"; whether the host
serves that binding from a ring of pre-built bind groups is invisible to
the shader. So the ring host code (decal_proj_bgs) stays EXACTLY as-is;
only the shader source moves to IoT.

PLAN for the real port:
1. Create decal_common_io.zig (Interp{o_world:Vec3, o_normal:Vec3}).
2. decal_vs_io.zig (Attributes{p,n} + Ubo{vp} + Outputs=Interp),
   decal_fs_io.zig (Inputs=Interp + ubo_group=1 + Ubo{projector,color,
   params,forward} + Samplers{decal pinned g2b0} + Outputs{final_color}).
3. Rewrite decal_vs.zig / decal_fs.zig bodies to shaderMain form
   (io.u.vp, io.u.projector, io.decal(uv), the axisMask/ndotf helpers
   stay as free fns). Keep the uniform-control-flow sample discipline.
4. Host UNCHANGED (the ring, the 3 setBindGroup calls, the camera UBO at
   group 0 via self.resources). Verify WGSL byte-match, gate, device-
   verify on sphere + bunny (the decal is device-sensitive — many prior
   bugs only showed on-device).
