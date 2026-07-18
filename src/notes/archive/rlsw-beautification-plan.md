# rlsw beautification plan (no features removed)

User redirected after the simplification analysis: keep every
feature, but look for structural improvements that make the code
more beautiful.  This doc is that pass.

## Survey findings

- **One-file monolith:** `src/rlsw.zig` is 6483 lines.  Two
  self-contained sub-namespaces inside it scream for extraction:
  - `pub const pixel = struct { ... };` — 707 lines, already its own
    namespace, just hosted in the wrong place.
  - `pub fn Pool(comptime T: type) type { ... }` — 161 lines of
    production code + 220 lines of tests.  Fully generic.

- **Context struct: 1629 lines, ~30 flat fields with snake-case
  prefixes.**  Prefix patterns:
  - `vp_size`, `vp_center`, `vp_half` — viewport state
  - `sc_min`, `sc_max`, `sc_clip_min`, `sc_clip_max` — scissor state
  - `stack_projection`, `stack_modelview`, `stack_texture`, plus
    `_counter` triplet, `current_matrix_mode`, `mat_mvp`,
    `is_dirty_mvp` — matrix state
  - `src_factor`, `dst_factor`, `blend_flags`, `blend_func` — blend
    state
  - `framebuffer_pool`, `texture_pool`, `bound_framebuffer`,
    `bound_texture`, `color_buffer`, `depth_buffer` — resource state

  Each cluster is *visibly* a struct that hasn't been factored yet.
  The prefixes exist because Zig fields share a namespace — `vp_size`
  is just spelling `viewport.size` without the dot.

- **Misleading section labels:**
  - Line 1577: `"// Gen / delete shims (Phase 4)"` actually contains
    `getTexture`, `getFramebuffer`, `isImmediateActive` — three
    small helpers, none of them gen/delete.
  - Line 2136: `"// Resource shims (Phase 4)"` contains the ACTUAL
    gen/delete shims.
  - Two confusingly similar labels for different things, 559 lines
    apart.

- **Test prefix inconsistency:** 161 tests across 10 tribes:
  ```
  79  era II
  19  phase 4
  18  phase 5B
  15  phase 5A
   9  era III
   7  phase 3
   6  phase 2
   3  cleanup B
   2  phase 1
   1  phase 5
  ```
  Each turn picked its own convention.

- **No rasterizer section.**  `drawPoint` + helpers ended up at the
  tail of the `"Begin / end immediate-mode plumbing"` section
  because turn 103 didn't add a new header.  When line / triangle /
  quad rasterizers ship, they'll keep accumulating in an
  unrelated section.

- **Top-level type decls in one big block.**  28 `pub const X = enum
  { ... }` decls before any code, in roughly definition order, no
  visual grouping by category (user-facing API vs internal storage
  vs resource shapes).

- **Null-fallback wart bleeds into 6 call sites.**  `color_buffer:
  ?*Texture` defaults to null; six sites do `self.color_buffer
  orelse &self.framebuffer.color`.  Same pattern for depth.  The
  workaround duplicates instead of being centralised.

- **Stale doc comments.**  A few `///` blocks reference future
  Phases as if they're still future, when they actually shipped:
  - Texture's docstring: "Function-pointer fields (`read_color8`,
    `read_color`) are wired in Phase 5..." — but those fields were
    REMOVED in turn 97 (Cleanup C, the pixel module consolidation).
  - "Phase 7 fills this in" on `blend_flags` / `blend_func` — Phase
    7 hasn't shipped, but the field-comment-as-roadmap has aged
    since the comment was written.

## Beautification proposals

### Tier 1 — high impact, low risk (mechanical)

**T1. Extract the `pixel` namespace to `src/rlsw_pixel.zig`.**
- `pub const pixel = struct { ... }` becomes `pub const X = struct { ... }`
  at the top level of `rlsw_pixel.zig`, with `pub`-marked methods
  becoming the file's exports.
- In `rlsw.zig`: `const pixel = @import("rlsw_pixel.zig");` (private
  alias) preserves all internal call sites (`pixel.write_color8_table`
  etc. still work).  Add `pub const pixel = pixel_module;` if external
  callers need access (they do — tests use it).
- Move the matching tests too — anything `// ---- Phase 5*` heading
  ships with the namespace.
- Net: rlsw.zig drops by ~700 production + ~700 test lines.
- Risk: zero — it's a private `struct` namespace already, the
  import-alias makes the move transparent.

**T2. Extract `Pool(T)` to `src/rlsw_pool.zig`.**
- Same pattern as T1.
- 161 lines + 220 test lines extracted.
- Could go higher into `src/pool.zig` since it's not rlsw-specific,
  but that's project scope.  rlsw-prefixed file is fine.

**T3. Fix the misleading section label at 1577.**
- Rename `"// Gen / delete shims (Phase 4)"` to something that
  reflects what's in it: `"// Pool accessors + immediate-mode
  predicate"` or `"// Resource lookups"`.
- Rename `"// Resource shims (Phase 4)"` at 2136 to `"// Pool gen /
  delete shims (Phase 4)"` so the relationship is clear.
- 2-line change, instantly clarifies file structure.

**T4. Add a rasterizer section header in Context.**
- Insert `// ==== Rasterizer (Era III) ====` before `drawPoint` at
  line ~2536.
- `drawPoint`, `fillPointSquare`, `fillPointSquareDepth` move under
  it.  Future `drawLine`, `drawTriangle`, etc. land in the same
  section.
- 3-line addition.

**T5. Test prefix unification.**
- Pick the era convention (newer, cleaner) and sweep.  Suggested
  mapping:
  - `phase 1` → `era I`
  - `phase 2` → `era I`
  - `phase 3` → `era I`
  - `phase 4` → `era I`
  - `phase 5` / `5A` / `5B` → `era I`
  - `cleanup B` → `era I` (cleanups happened in Era I)
  - `era II`, `era III` stay
- Mechanical sed pass.  Net: every test starts with `era N: ...`
  with `N ∈ {I, II, III}`.  Searchable, predictable, paginates
  cleanly.

**T6. Hide the null-fallback wart behind an accessor.**
- Add `fn effectiveColorBuffer(self: *const Context) *const Texture`
  and `fn effectiveColorBufferMut(self: *Context) *Texture` (mut
  for writing into pixel storage).
- Same for depth.
- Replace 6 `self.color_buffer orelse &self.framebuffer.color`
  sites with `self.effectiveColorBuffer()`.
- The orelse stays inside ONE method.
- Cost: ~12 lines of helper code; saves ~6 lines of duplicated
  fallback at call sites; centralizes the kludge for when we fix
  it properly.

**T7. Refresh stale doc comments.**
- Scan for `Phase 5` / `Phase 6` / `Phase 7` / "TODO" / "wired in"
  references.  Either delete the reference (if the work shipped) or
  keep it (if still future).
- Texture struct's "Function-pointer fields are wired in Phase 5"
  is the worst offender; just delete it (the fields don't exist).

### Tier 2 — high impact, modest disruption

**T8. Group Context fields into named sub-structs.**

Replace flat fields:
```zig
pub const Context = struct {
    framebuffer: DefaultFramebuffer,
    clear_color: types.Color,
    clear_depth: f32,
    vp_center: types.Vector2,
    vp_half: types.Vector2,
    vp_size: types.Vector2i,
    sc_min: types.Vector2i,
    sc_max: types.Vector2i,
    sc_clip_min: types.Vector2,
    sc_clip_max: types.Vector2,
    primitive: struct { ... },
    array: struct { ... },
    draw_mode: ?DrawMode,
    poly_mode: PolyMode,
    point_radius: f32,
    line_width: f32,
    stack_projection: [...]Matrix,
    stack_modelview: [...]Matrix,
    stack_texture: [...]Matrix,
    stack_projection_counter: u32,
    stack_modelview_counter: u32,
    stack_texture_counter: u32,
    current_matrix_mode: MatrixMode,
    mat_mvp: types.Matrix,
    is_dirty_mvp: bool,
    bound_framebuffer: Pool(Framebuffer).Handle,
    color_buffer: ?*Texture,
    depth_buffer: ?*Texture,
    framebuffer_pool: Pool(Framebuffer),
    bound_texture: ?*Texture,
    texture_pool: Pool(Texture),
    src_factor: BlendFactor,
    dst_factor: BlendFactor,
    blend_flags: u32,
    blend_func: ?*const fn (...) void,
    cull_face: Face,
    err_code: ErrorCode,
    user_state: std.enums.EnumSet(Capability),
    raster_state: std.enums.EnumSet(Capability),
    clear_color: types.Color,
    clear_depth: f32,
    // ...
};
```

with structured fields:
```zig
pub const Context = struct {
    target: TargetState,            // framebuffer + bound_framebuffer + color/depth_buffer
    viewport: Viewport,             // size + center + half
    scissor: Scissor,               // min + max + clip_min + clip_max
    matrices: MatrixStacks,         // 3 stacks + counters + mode + mvp + dirty
    blend: BlendState,              // src + dst + flags + func
    primitive: PrimitiveBuffer,     // already a sub-struct
    array: ArrayBindings,           // already a sub-struct, just naming
    state: RenderState,             // poly_mode + point_radius + line_width + cull_face
    capabilities: CapabilitySets,   // user_state + raster_state
    resources: ResourceState,       // 2 pools + 2 bound pointers
    clear: ClearState,              // clear_color + clear_depth
    draw_mode: ?DrawMode,           // stays top-level (1 field, primary)
    err_code: ErrorCode,            // stays top-level (1 field, primary)

    pub const Viewport = struct {
        size: types.Vector2i,
        center: types.Vector2,
        half: types.Vector2,
    };
    pub const Scissor = struct {
        min: types.Vector2i,
        max: types.Vector2i,
        clip_min: types.Vector2,
        clip_max: types.Vector2,
    };
    // ...
};
```

Site usage changes:
- `ctx.vp_size` → `ctx.viewport.size`
- `ctx.sc_min` → `ctx.scissor.min`
- `ctx.stack_modelview[ctx.stack_modelview_counter - 1]` →
  `ctx.matrices.modelview[ctx.matrices.modelview_counter - 1]`
- `ctx.color_buffer` → `ctx.resources.color_buffer`
- `ctx.user_state.contains(.depth_test)` →
  `ctx.capabilities.user.contains(.depth_test)`

Pros:
- Field-cluster comments become struct-typedef names (no comments
  needed; the struct name self-documents).
- The two-letter prefix shorthand (`vp_`, `sc_`) goes away —
  `ctx.viewport.size` reads like English.
- Related state migrates together when we eventually want to copy
  / serialise / save snapshots.
- New contributor sees `Context` and gets a high-level table of
  contents.

Cons:
- Disruptive: every field access in production code AND tests must
  migrate.  Maybe 200+ sites.
- More lines of struct definition (the sub-struct typedefs add ~30
  lines for boilerplate).

Tradeoff: I think this is worth it but it's a separate turn from
T1-T7.  The mechanical sweep is straightforward but the test churn
alone is ~50 file edits.

### Tier 3 — polish

**T9. Reorder top-level enum decls by category.**

Current order is roughly definition order; group by purpose:
- *User-facing draw API:* DrawMode, MatrixMode, PolyMode, Face,
  BlendFactor, ClearMask, TextureParam
- *User-facing data:* Format, DataType, InternalFormat, Filter, Wrap
- *Resource API:* Attachment, AttachmentParam, FramebufferStatus,
  Capability, ArrayKind, GetParam, TexParam
- *Errors / status:* ErrorCode
- *Internal storage:* PixelFormat, PixelAlpha
- *Internal types:* Vertex, gradient helpers, Texture,
  DefaultFramebuffer, Framebuffer

A 5-section comment-headed reordering with the same decls.  Pure
cosmetic; helps newcomers skim.

**T10. Consistent section-marker depth.**

Currently mixed: some sections use `// ===...` (4-equal-bars),
some use `// ---...` (4-dash-bars).  Both inside and outside Context.
Pick one rule:
- `// ====...===` for top-level sections (file-spanning)
- `// ----...---` for sub-sections within a top-level section.

Then sweep.  Cosmetic; removes the "is this a major or minor
divider?" cognitive load.

**T11. Method ordering within Context.**

Order is mostly logical already — lifecycle → state → cleanup →
matrices → resources → textures → drawing.  Minor improvements:
- `getTexture` / `getFramebuffer` (currently up at line 1595, in
  the wrong section per T3) move to the resource section.
- `isImmediateActive` could move to its own private-helpers
  section, or stay near the top as the "predicate that gates many
  setters" annotation.

Cosmetic.

### What turn 104 should actually do

**Apply T1, T2, T3, T4, T5, T6, T7 in turn 104.**  All Tier 1.
All mechanical, all low risk.  Effects:
- rlsw.zig drops from 6483 lines to roughly 4900 lines (extracted
  pixel + Pool sit in their own files).
- Two new files: `src/rlsw_pixel.zig` (~1400 lines including
  tests), `src/rlsw_pool.zig` (~380 lines including tests).
- File header structure becomes legible at-a-glance.
- Tests have one prefix scheme.
- The null-fallback kludge stops bleeding everywhere.
- Stale doc references go away.

**Defer T8 to turn 105.**  Field grouping is the most visibly-
impactful change but it's a disruptive sweep.  Single-purpose turn
deserves its own context.  Nothing in turn 104 blocks it.

**Defer T9, T10, T11 to a later "polish pass" turn.**  Pure
cosmetics, can ride along with another change.

### What's NOT in scope

- No feature removal (per user direction).
- No `@Vector` migration.
- No Context-by-pointer redesign (the null-fallback wart gets
  hidden by T6 but not architecturally fixed).
- No tests added or removed (tests move with their code in T1+T2;
  prefixes change in T5; no logic changes).

### Risk assessment

T1, T2: completely mechanical.  Tests come along.  Identical
behavior pre/post.  The only failure mode is forgetting a re-export
or import path.  Both can be smoke-tested.

T3, T4: comment changes.  Zero risk.

T5: text-only sed sweep on test names.  Zero behavioral risk.

T6: 6 call sites swept; new helper added.  Caller pattern
identical.  Trivial to verify with `zig build test`.

T7: comment deletions.  Zero risk.

Total turn 104 risk: very low.  Audit gates (1042/1042 tests) stay
green throughout.

### Effort estimate

Turn 104 (T1-T7): ~30 minutes of mechanical edits + verification
sweep.  Probably one chat turn.

Turn 105 (T8): ~1 hour.  Maybe spans two chat turns if the test
sweep is broken into chunks.

Turn 106 starts the line rasterizer with a noticeably tidier
codebase, no features lost.
