# rlsw — port plan v3 (idiomatic, donor-decoupled)

A pure-Zig software rasterizer living in `src/rlsw.zig`.  Originally
ported from raylib's `rlsw.h` — but as of turn 89 we are no longer
holding to donor-faithfulness.  The goal now is the best, most
idiomatic, explicit, verbose-but-readable Zig software renderer
we can produce, whose API matches whatever shape makes the most
sense for zimr users — **not** what `rlsw.h` happens to expose.

The previous plan (`archive/rlsw-plan-v2-donor-faithful.md`) is
preserved for reference.  This document is the new authority.

## Where we are (snapshot at end of turn 117)

**rlsw is complete.**  Architecture stable since turn 110; demo
feature-complete since turn 116; documentation surfaced in
turn 117.  All three goals (bragging rights / perf / clarity)
satisfied; the project's value is now visible to anyone
reading the repo without having to dig through `notes/`.

**Final state:**

- `src/rlsw.zig` — pure-Zig software renderer, 1087-test
  coverage (5 of those for `readPixels` from turn 115).
- `src/renderer_trait.zig` — comptime trait + GlAdapter / SwAdapter,
  3 trait-check tests.
- `examples/rlsw_side_by_side.zig` — the dual-pipeline
  bragging-rights demo: cursor-driven divider + cube-tracks-
  cursor + bottom perf bar + click-to-toggle pixel-diff
  overlay with quantitative match percentage.
- README, CHEATSHEET, LICENSE all surface rlsw + gl_iface
  alongside the rest of zimr.

**Three "beat the donor" wins shipped during Era III** (turns
108-110): inlined alpha-over blend, sprite-quad fast-path,
4-wide SIMD on BASE quads.  All three composed visibly into
the textured-cube demo (turn 112) and the dual-pipeline A/B
demo (turn 114).

Era IV closed; rlsw drops out of "active sub-project" status.

**Audit health:**

- `zig build test --summary all` — 1087/1087 ✅
- `zig build smoke-test` — 43/43 ✅
- `zig fmt --check src/` — clean ✅
- `zig build install` — 42.47 KB wasm ✅
- 0 / 0 / 0 globals ✅
- only allowlisted SCC ✅
- 0 lines >120 chars ✅


## Why a new plan

The v2 plan was structured around "match the donor, then ship a
demo of what we matched."  Three things have changed:

1. **The donor compat goal is dropped.**  We don't need `swInit`
   to match `rlsw.h`'s `swInit`.  We need `Context.init` to be the
   best `Context.init` we can write.  This unlocks renaming, retyping,
   and re-shaping freely.

2. **The shipped code has accumulated style debt.**  The audit at
   turn 89 finds 72 `[*]u8` many-item pointers (most should be
   slices), 164 `[2]i32` / `[2]f32` / `[4]f32` / `[4]u8` tuple-arrays
   (most should be named structs with `.x` / `.y` / `.r` / `.g`
   accessors), 238 `@intFromEnum` calls (a lot of which exist only
   because we're indexing into raw arrays where an `EnumArray` would
   be safer and clearer).  The donor-faithful style produced a lot
   of "C in Zig syntax."

3. **Demo-driven didn't actually drive.**  Five phases shipped
   without ever creating the demo.  The scaffold is a 344-line
   document that describes what we intend, not a 344-line example
   that compiles.  We need the example file in the build
   end-to-end before adding more phases on top.

So this plan does three things in order: **clean up what's there**,
**lift the demo**, **then march forward** under the new style.

## Style + performance commitments (this is what changes)

These are the hard rules for new code AND for any function we touch:

1. **No many-item pointers in public APIs.**  `[*]u8` is a leaky
   abstraction — caller has to know the length out-of-band.  Use
   slices `[]u8` everywhere a length exists.  Many-item pointers
   are reserved for `extern` boundaries and the rare case where a
   slice can't be formed (FFI, zero-terminated C strings).

2. **Named structs over tuple-arrays for spatial values.**
   `Vec2i { x: i32, y: i32 }` and `Vec2f { x: f32, y: f32 }` and
   `Color { r: u8, g: u8, b: u8, a: u8 }` and `Rect2i { x, y, w, h }`.
   Spelled out at definition; called as `.x` / `.y` / `.r` etc.
   Live in `src/zimrmath.zig` (Vec2/Rect already partially exist
   for ECS use; we extend).  `[4]f32` for an interpolated RGBA stays
   as a `[4]f32` because the rasterizer's hot loop wants a flat
   array — but at the public-API boundary, it's `Color`.

3. **`std.enums.EnumArray(E, T)` over `[E.count]T` whenever the
   index is the enum.**  No more `arr[@intFromEnum(fmt)]` — that's
   `arr.get(fmt)`.  EnumArray is a struct wrapper around a `[N]T`,
   zero overhead, but `arr.get(fmt)` is a typed lookup and `arr.set
   (fmt, x)` is type-safe assignment.

4. **`std.enums.EnumSet(E)` over `u32` bitmasks.**  Capability flags,
   blend flags, etc., are EnumSets.  Set/clear/contains are typed.

5. **Drop GL wire numbers from enums.**  `DrawMode.triangles = 0x0004`
   becomes `DrawMode.triangles` (Zig auto-numbers).  We never bridge
   to rlgl.  Stop carrying the cost.

6. **Lift bare numeric literals to named locals at every call site
   (Style Guide Rule 6).**  This is the one place where "verbose"
   wins outright.  Numbers in code are signposts for the reader.

7. **Function arguments — types written out, one per line for
   anything 2+ args (Style Guide Rule 1).**  Already mostly
   followed; enforce on any new code.

8. **Comptime-specialize where it pays.**  The pixel format reader
   collection is a great case: instead of 56 separate functions
   plus 6 dispatch tables, one
   `fn readColor8(comptime fmt: PixelFormat, src: []const u8, idx: u32) [4]u8`
   the compiler specializes per format, plus a runtime dispatch
   table that's auto-generated by walking the enum at comptime.
   The runtime cost is identical — one indirect call.  The source
   shrinks 5x.

9. **Single-call helpers earn their keep (Style Guide Rule 8).**
   Every "does this need to be a separate function?" question is
   a Carmack-style inline-by-default decision.  When in doubt,
   inline.

10. **Performance posture: scalar first, vector later.**  No
    `@Vector` in the rasterizer kernels for v1.  Once the kernels
    work, profile, then vectorize the hotspots.  Wasm SIMD lowering
    is reasonable; portable Zig vectors will work without per-arch
    intrinsics.

11. **Errors: split.**  Allocation / setup APIs return error
    unions (`!Context`).  GL-semantic per-call APIs (`bindTexture
    (id)` with a bad id, `vertex3f` past the polygon buffer) record
    `Context.err_code` and continue.  This is the same split the
    v2 plan committed to — preserved because the ergonomic case for
    record-and-continue inside a `begin`/`end` block is real.

## Cadence + process

These are non-negotiable for every turn from this one forward:

- **Save `/mnt/user-data/outputs/zimr.zip` every turn**, even on
  pure-planning turns where no source changed.  Use the standard
  `zip -rq ... -x "zig-out/*" ".zig-cache/*" ".git/*" "node_modules/*"`
  recipe.

- **Re-read `src/notes/claude.md` every 3 turns**, before
  touching code.  Last read: turn 89.  Next due: turn 92.

- **Audit gate every turn** (with documented exceptions for
  pure-doc turns):
  - `zig build test --summary all` — green; count grows or
    holds.  Never shrinks.
  - `zig build smoke-test` — 42/42 PASS, 0 FAIL (43/43 once
    the example lands).
  - `zig build install` — wasm builds clean.
  - `python3 scripts/count_globals.py` — 0/0/0.
  - `python3 scripts/check_dag.py` — only the allowlisted
    `ui ↔ zimr` SCC.

- **CHANGELOG entry every code-changing turn**, prepended after
  `## [Unreleased]`.  Sections: brief narrative paragraph;
  "Code shipped" with bullet list; "Implementation choices" for
  decisions worth remembering; "Tests added" with count delta;
  "Audit numbers"; "Files touched"; "Next turn".  This is the
  pattern we already use.

## The new roadmap

Three eras, fifteen phases:

### ERA I — Cleanup (turns 89-97)

Pure refactor.  Behavior preserved exactly; tests should still
pass.  Each turn ends with all audit gates green.

| Turn | Work                                                                                      | Tests delta |
| ---: | ----------------------------------------------------------------------------------------- | ----------: |
| 89   | **DONE.** Roadmap (this v3 plan).                                                         |   0         |
| 90   | **DONE.** Cleanup A — types: Vec2i / Vector2 / Color in Context + Texture; named locals in init/resize. | +4 |
| 91   | **DONE (partial).** Cleanup B — wire-number values stripped from public enums; `ClearMask` collapsed to two-bool struct; wire-number pin tests deleted. | -15 |
| 92   | **DONE (off-plan detour).** Notes hygiene + style Rule 10 (line length).                  | n/a         |
| 93   | **DONE (off-plan detour).** `zig fmt` applied to rlsw.zig + types.zig; CHANGELOG rotated. | n/a         |
| 94   | **DONE (off-plan detour).** Big-bang `zig fmt` on whole tree + trailing-comma sweep; whole-tree `--check` added to audit gate. | 0 |
| 95   | **DONE.** Cleanup B finish — `EnumArray(PixelFormat, T)` for size + alpha + the six dispatch tables; `EnumSet(Capability)` for `user_state`/`raster_state`; round-trip pin tests. | +3 |
| 96   | **DONE.** Cleanup B+ — typed handles (zpool-inspired): `Pool(T).Handle` is a phantom-typed `enum(u32)` (24-bit index, 8-bit cycle); even/odd cycle convention replaces the LIVE bit; stale-handle detection at lookup; four gen/delete shims and `Context.bound_framebuffer` retyped; phantom decl required to keep `Handle(Texture) != Handle(Framebuffer)` (the original plan didn't account for Zig 0.16 comptime memoization). | +5 |
| 97   | **DONE.** Cleanup C — pixel module: 6 format-fn structs (62 fns) collapsed to 6 comptime-specialized fns; 6 dispatch tables comptime-built via `inline-for` + anonymous-struct dispatch wrappers; `[*]u8` → `[]u8` everywhere; `Texture.pixels: []u8` (was `[*]u8 + alloc_sz`); dropped `Texture.read_color8`/`read_color` fn-pointer fields; collapsed `expand1to8..expand6to8` and `compress8to1..compress8to6` (12 fns) into `expandToByte(n, v)` / `compressByteTo(n, v)`; renamed luminance helpers. | 0 |

### ERA II — Demo + visible API (turns 98-103)

The example file lands in the build at turn 98 (slid by 4 turns
relative to the original plan because of the Era I detours).  Each
turn after adds capability AND extends the demo so the user sees
something new.

| Turn | Work                                                                                      | Demo                                              |
| ---: | ----------------------------------------------------------------------------------------- | ------------------------------------------------- |
| 98   | **DONE.** Demo lift: `examples/rlsw_side_by_side.zig` promoted from staging to the build.  Public `Context.clear` / `clearColor` / `clearDepth` / `colorBufferBytes` shipped (the Demo-lift prerequisites). | Right half: rlsw clear-color cycles via clock; left half: WebGL slate-pulse. |
| 99   | **DONE.** Public API 1 finish — `enable` / `disable` / `viewport` / `scissor` / `blendFunc` / `cullFace` / `polygonMode` / `pointSize` / `lineWidth` shipped on `Context`.  Plus `cleanRasterState` private helper that filters `user_state` against bound-resource availability to produce `raster_state` (called from `begin` once Phase 102 ships).  17 new tests covering the state-setter family + the cleanup pass.  `frontFace` dropped — donor doesn't have it, CCW=front is implicit. | Same — state setters don't visibly change anything until rasterizer ships in turn 103+. |
| 100  | **DONE.** Matrix stacks: `matrixMode` / `pushMatrix` / `popMatrix` / `loadIdentity` / `translate` / `rotate` / `scale` / `multMatrix` / `frustum` / `ortho` shipped on `Context`, plus the private `markMvpDirty` helper.  Translate / rotate / scale / multMatrix pre-multiply (`current = m * current`); frustum / ortho post-multiply (`current = current * m`) — matches donor + raylib's rlgl.h.  Texture-stack mods don't dirty the MVP (donor: matrix isn't part of the modelview×projection product).  16 new tests covering stack ops, mul direction, error paths, and dirty-bit propagation. | Same — preparing for 3D. |
| 101  | **DONE.** Texture upload: `bindTexture`, `texImage2D`, `texParameter` shipped on `Context`; `deleteTextures` extended to take `gpa` and free per-texture pixel storage; new module-level `pixelFormatFromFormatAndType` translator + `TextureParam` tagged-union enum.  Demo extended to upload a 64×64 procedural checker into a rlsw-pool-backed texture, set sampler params (nearest filter, repeat wrap), and bind it.  18 new tests covering the format-translator, the bind/upload/param surface, and `deleteTextures`'s new free path. | Demo's bound texture is set up; rasterizer (Era III) will sample it. |
| 102  | **DONE.** Begin/end immediate-mode plumbing: `begin` / `end` / `vertex2f` / `vertex3f` / `color3f` / `color4f` / `color4ub` / `texCoord2f` shipped on `Context`; private `pushVertex` + `setColor` helpers; module-level `primitiveVertexCount`.  `begin` is the first production caller of `cleanRasterState` (turn 99) and the dirty-bit-driven MVP recompute (turn 100).  Auto-flush at primitive size resets vertex_count to 0 (rasterizer hook is TODO until turn 103+).  19 new tests covering state-machine, MVP recompute, color/texcoord stickiness, auto-flush, and multi-primitive begin/end. | UI shows "submitted N vertices".                  |
| 103  | **DONE.** Era III start — point rasterizer.  `Context.drawPoint(v)` private method handling clip-volume rejection, perspective divide (when w ≠ 1), NDC→viewport projection, scissor + framebuffer-bounds early-reject, square fill of (2*radius+1)² pixels, optional depth test+write.  Hot/cold split via private `fillPointSquare` / `fillPointSquareDepth` (branched once at the kernel level, donor's preprocessor variants as runtime branches).  Module-level `byteFromUnitFloat(v)` helper with NaN/saturation protection.  `pushVertex` auto-flush switch dispatches `.points → drawPoint`.  Demo extended to scatter 60 Lissajous-positioned 5×5 colored points each frame.  9 new tests; 1042 total. | First time ANY pixel gets drawn by the software rasterizer — colored point cloud over the cycling clear color. |
| 104  | **DONE.** Beautification pass (no features removed): T1 extracted `pixel` namespace to `src/rlsw_pixel.zig` (1463 lines incl. tests).  T2 extracted `Pool(T)` + `Handle(T)` to `src/pool.zig` (270 lines).  T3 fixed misleading section labels (line 1577 was "Gen / delete shims" but contained accessors; renamed to "Resource lookups + immediate-mode predicate").  T4 added `// === Rasterizer (Era III) ===` section header.  T5 swept test prefixes from 10 tribes ("phase 1/2/3/4/5/5A/5B", "cleanup B", "cleanup B+", etc.) to 3 (`era I`/`II`/`III`); 161 tests total.  T6 added `effectiveColorBuffer{,Const}()` / `effectiveDepthBuffer{,Const}()` accessors; 6 site duplications of `self.color_buffer orelse &self.framebuffer.color` reduced to one method.  T7 refreshed stale doc references (the file's status block, Texture's docstring, Context's docstring).  rlsw.zig from 6483 → 4863 lines (-25%).  Zero behavior changes. 1042/1042 tests still passing. | Same — beautification doesn't change pixels. |
| 105  | **DONE.** Era III line rasterizer.  `Context.drawLine(v0, v1)` private method using DDA: dominant-axis step count, fractional advance per iteration, color-interp in `[0, 1]`, optional per-pixel depth test+write.  Refactor of drawPoint to share the projection + scissor-rect helpers (`projectVertex`, `scissorRect`, plus `ProjectedVertex` / `PixelRect` types — three callers each, Rule 8 cleared).  Wired `pushVertex`'s auto-flush switch to dispatch `.lines → drawLine`.  Demo extended with rotating 12-spoke star burst (`begin(.lines)` block) drawn under the existing point cloud.  No Liang-Barsky clip-space line clipping (donor has it; we skip — sufficient for 2D vertex W=1 case).  No thick lines (`line_width >= 2` deferred).  No blend (Phase 7 deferred).  8 new tests covering horizontal/vertical/diagonal lines, color interpolation across endpoints, zero-length degenerate, off-screen rejection, multi-line begin/end, depth test rejection.  1042 → 1050. | Right half: rotating star burst behind the point cloud. |
| 106  | **DONE.** Triangle BASE.  `Context.drawTriangle(v0, v1, v2)` private method using edge-function rasterization: bounding-box scan of the projected triangle, evaluate three 2D-cross-product edge functions per pixel, fill if all three same sign as area_x2.  Color interp via barycentric weights derived from the same edge functions (one division per triangle, three multiplies per pixel).  Detects winding from area sign — both CCW and CW triangles fill correctly.  Degenerate (zero-area) triangles silently skipped.  Wired `pushVertex`'s auto-flush switch to dispatch `.triangles → drawTriangle`.  Demo extended with rotating colored triangle (RGB-corner Gouraud blend) between lines and points layers.  Mid-turn cleanup also stripped phase/era references from all code prose (78 references → 0; CHANGELOG and plan retain the narrative).  No Sutherland-Hodgman clip-space clipping (donor has it; conservative reject from `projectVertex` instead — sufficient for 2D W=1 demos).  No depth, no texture, no blend, no face culling (each lands in subsequent rasterizer pass).  7 new tests covering coverage + non-coverage, barycentric color interp, degenerate, off-screen rejection, CW winding, scissor clipping, multi-triangle begin/end.  1050 → 1057. | Right half: rotating Gouraud-shaded triangle. |
| 107  | **DONE.** Comptime-cfg architecture + depth + texture.  Module-level `fb_color_fmt` / `fb_depth_fmt` constants — framebuffer codecs inline at every read/write (no fn-ptr in inner loop) matching the donor's `SW_FRAMEBUFFER_COLOR_TYPE`/`_DEPTH_TYPE` strategy.  `RasterCfg` struct with depth_test / texture / blend / cull_back axes; dispatcher functions `drawPoint`/`drawLine`/`drawTriangle` use `inline switch` over `cfgIndex(currentCfg(self))` to dispatch into one of 16 monomorphised kernels.  Each kernel takes `comptime cfg: RasterCfg`; `if (cfg.X)` blocks resolve at compile time.  drawPoint refactored — `fillPointSquare`/`fillPointSquareDepth` collapse into one `pointKernel`.  drawLine's `if (do_depth)` runtime branch becomes comptime.  drawTriangle gains depth_test (z barycentric-interpolated, `fb_depth_fmt` inlined read+test+write) and texture (affine UV barycentric, runtime fn-ptr per-sample for tex format dispatch — matches donor's `tex->readColor`).  Demo extended: second textured triangle counter-rotating using the bound checker texture.  4 new tests covering triangle depth-rejection, texture sampling (solid blue + solid white textures), texture+vertex-color modulation, depth+texture combined.  1057 → 1061. | Right half: Gouraud triangle (upper-left) + textured checker triangle (lower-right). |
| 108  | **DONE.** Triangle BLEND + cull face.  Style guide re-read at start (cadence-due, no surprises).  `cfg.blend` and `cfg.cull_back` axes wired through `currentCfg` and the `triangleKernel` body.  Blend kernel inlines the alpha-over recipe (`SRC_ALPHA, ONE_MINUS_SRC_ALPHA`) directly — `dst = pixel.readColor(fb_color_fmt, ...)` then `out.rgb = src.rgb * src.a + dst.rgb * (1 - src.a)`.  This is one of the "beat the donor" wins promised: the donor dispatches every blended pixel through `RLSW.blendFunc` (a fn-ptr selected from a 64-entry table); we inline the common case.  Other blend modes can ship later via a runtime fallback.  Cull kernel: per-triangle `if (area_x2 < 0) return` when `cfg.cull_back`, free of cost.  Demo gained a half-alpha cyan overlay triangle showing the blend in action.  4 new tests covering alpha-over composite (50% green over red ≈ 50/50 mix), full-alpha blend identity (matches no-blend output), cull_back rejects CW + keeps CCW, and blend+texture combined.  1061 → 1065. | Right half: Gouraud triangle + textured triangle + semi-transparent cyan overlay. |
| 109  | **DONE.** Quad rasterizer.  Two-route dispatch from `drawQuad`: axis-aligned quads (the sprite fast-path) take `quadKernel`, a rectangular scan with linear gradients in (x, y) — no edge functions, no barycentric division, ~3× cheaper per pixel than the triangle path.  Non-axis-aligned quads fan-triangulate to two `triangleKernel` calls.  `isAxisAlignedQuad` uses the donor's epsilon-tolerance edge test (each edge purely horizontal or vertical within 0.5 px).  `quadKernel` classifies the four projected corners by `(x+y, x-y)` minimum/maximum (donor's trick) — submit order doesn't matter; rotated submissions still find their TL/TR/BR/BL.  All four cfg axes work for both routes (depth_test, texture, blend, cull_back).  Per-pixel work in `quadKernel`: clean three-block structure (depth → color/texture → blend) with an explicit `depth_passed` boolean so the per-pixel accumulator advances always run regardless of whether the pixel painted.  Demo gained a sprite quad in the upper-right, drifting around with axis-aligned edges so the fast-path stays selected.  7 new tests covering sprite fill, corner-color interp, rotated quad falling back to triangulation, textured quad, blended quad, depth-tested quad, and arbitrary submit order.  1065 → 1072. | Right half: drifting sprite quad in the upper-right plus all earlier passes. |
| 110  | **DONE.** SIMD pass — third "beat the donor" win.  Style guide re-read at start (cadence-due, no surprises).  `RasterCfg.simdEligible()` comptime method returns true when the inner loop has no per-pixel branching that prevents 4-wide vectorization (today: BASE only — no depth, no tex, no blend).  `quadKernel` forks at the inner loop: SIMD-eligible cfgs run a 4-wide `@Vector(4, f32)` body that processes four pixels per iteration, then a scalar tail for the 0-3 leftover pixels when row width isn't a multiple of 4.  Other cfgs run the existing scalar body.  Both share the prologue (corner classification, gradient setup) — no code duplication.  Existing `byteFromUnitFloatVec` re-used for the lane-byte conversion (lowers to `f32x4.pmin/pmax` + `i32x4.trunc_sat_f32x4_s` on wasm32).  Wasm SIMD support is mature in modern browsers (Chrome/Firefox/Safari all ship v128).  5 new tests covering: full-row alignment (no tail), 7-pixel rows (SIMD body + 3-pixel tail), 3-pixel rows (tail-only, SIMD skipped), gradient continuity across lane boundaries, and bit-identical output vs scalar reference for solid-color quads at multiple lane positions.  Triangle SIMD deferred — edge-function vectorization adds an inside-test mask layer that's tractable but distinct from the quad pattern, and shipping triangle SIMD changes a much larger surface area than this turn's scope.  1072 → 1077. | n/a — same demo, faster. |

### Era III closes

All four primitive types ship through the comptime-cfg dispatcher,
all four cfg axes work for triangles and quads, the sprite
fast-path is in place, and the BASE-quad SIMD path is in place.
Three "beat the donor" wins shipped:

1. Inlined alpha-over blend (turn 108) — donor dispatches each
   blended pixel through a runtime fn-ptr; we inline the
   common case.
2. Sprite fast-path (turn 109) — same as donor's strategy, but
   our comptime cfg structure makes adding more fast-paths
   trivial.
3. 4-wide SIMD on quad BASE (turn 110) — donor is fully scalar
   end-to-end; we vectorize the simplest hot loop.

Remaining "beat the donor" opportunities are queued as polish:

- Triangle SIMD (BASE, then DEPTH).  Edge-function inside-mask
  + barycentric + color interp all vectorize cleanly; per-lane
  scalar writes for inside lanes since wasm SIMD has no
  efficient masked store at byte granularity.  Will likely
  ship alongside the 3D cube demo when it actually exercises
  the triangle path heavily.
- DEPTH/BLEND SIMD on quad.  Vector compare + masked logic.
  Easy mechanically; defer until profiling shows it matters.
- TEX SIMD.  Wasm SIMD's gather is weak; per-lane serialization.
  Lowest priority of the SIMD work.
- RGBA8 texture fast-path.  Branch once per primitive on
  `bound_tex.format == .color_r8g8b8a8`, inline a 4-byte gather
  per sample instead of the runtime fn-ptr.  Donor doesn't do
  this; ~5-10 cycles saved per textured pixel.

These can land at any time without architectural changes.  The
codebase is in its final shape for the rest of the project.

### ERA IV — 3D milestone + polish (turns 111-114)

> **Renderer-polymorphism convention** (decided May 2026):
> scene-drawing functions take their renderer as `gl: anytype`
> with `assertIsGlContext(gl)` at the top.  Same scene code drives
> both rlgl (WebGL) and rlsw (software).  Full rationale in
> `PLAN.md` → Architectural commitments → "`gl: anytype` for
> renderer-polymorphic scene code".  This is what makes the
> side-by-side demo at turn 112 a single scene function rendered
> twice rather than two parallel scene implementations.

| Turn  | Work                                                                                  | Demo                                                                           |
| ----: | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| 111   | **DONE.** 3D demo wiring + perspective-correct UV.  `triangleKernel`'s texture sampling now lerps `(u/w, v/w, 1/w)` linearly via barycentric weights and recovers the actual UV per pixel via division by the interpolated 1/w — donor's exact strategy translated into the comptime-cfg kernel.  For W=1 vertices (2D scenes) the math collapses to plain affine, so existing 2D textured tests stayed bit-identical (1077/1077 → 1079/1079, +2 perspective-correct tests).  Demo gained a 3D cube as its centerpiece: 6 quads with a different solid color per face, perspective frustum projection, modelview rotation around X+Y, depth_test enabled for self-occlusion.  Cube data is a `[6]CubeFace` constant (corners + color) — render loop iterates, `begin(.quads)` per face.  Quad dispatcher's fan-triangulation fallback handles the perspective-distorted screen-space quads cleanly.  Demo now has a clear two-phase structure: Phase A (3D, perspective, depth) renders the cube, Phase B (2D, identity matrices, no depth) renders the existing star burst / triangles / sprite / points as overlay.  Star burst alpha dropped to ~40% so the cube reads through.  1077 → 1079. | Right half: spinning 3D cube as centerpiece + 2D overlay.                       |
| 112   | **DONE.** v1 milestone — textured cube + draggable composite UI.  Cube faces gained UVs (each face shows the full bound texture, modulated by the face's solid color tint).  `s.sw.enable(.texture_2d)` wraps the cube pass; the rasterizer's perspective-correct UV (turn 111) makes the texture stay glued to the cube faces under rotation without shimmer.  Demo also gained a draggable vertical divider for live A/B comparison: `divider_x` in `State`, mouse-drag tracking via `isMouseButtonDown(.left)` + `getMouseX`, composite via `drawTexturePro` with a source-rect crop matching the divider position.  Left of divider stays as the WebGL clear (will host rlgl-rendered scene in turn 113); right of divider shows the rlsw output upscaled to canvas size.  Caption labels for both sides + a "drag to A/B" hint at the bottom.  Framebuffer resized to 16:9 (400×225) to match canvas aspect; frustum half-width scales by aspect so the cube renders square.  No new tests — visual milestone, exercised by the existing smoke harness.  1079 → 1079. | Right half of canvas: spinning textured cube + 2D overlay; left half: WebGL background.  Drag cursor across canvas to slide divider. **v1 ships.** |
| 113   | **DONE.** `gl: anytype` polymorphism: `src/renderer_trait.zig` ships the trait check (`assertIsGlContext`) plus method-style adapters (`GlAdapter` over `*rlgl.GlState`, `SwAdapter` over `*rlsw.Context`).  Comptime trait check walks decls and emits clear `@compileError` for missing methods.  Demo's `update` refactored to flow every drawing call through `SwAdapter` via `drawScene(gl: anytype, ...)` — same code path turn 114 uses for the rlgl side.  +3 trait tests; 1079 → 1082. | Demo unchanged visually; architecture ready for dual-pipeline. |
| 114   | **DONE.** Dual-pipeline A/B demo shipped — the bragging-rights moment.  Both rlgl and rlsw render the same scene through `drawScene(gl: anytype, ...)`; rlgl into an offscreen `RenderTexture2D` FBO, rlsw into its CPU framebuffer.  Composite step blits each to its half of the canvas at the cursor X.  No clicks: cursor X drives the divider, cursor (X, Y) maps to NDC and rotates the cube to face the cursor (kiosk auto-rotates from time when cursor leaves canvas).  Bottom-strip perf bar shows median-of-30-frames per-pass times for both renderers, with a 16ms reference line.  Framebuffer is now full canvas resolution (800×450 minus 36px perf strip = 800×414); 1:1 mapping, no upscale softness.  GlAdapter's `enable(.depth_test)` becomes real (calls `rlgl.fwd.rlEnableDepthTest`); trait gains `setBlendMode(.alpha)` so the blend overlay works through the polymorphic interface.  `drawScene` covers cube + star burst + Gouraud + textured triangle + blend overlay + sprite quad — points dropped for full parity (rlgl has no native points).  +0 tests (visual milestone).  1082 → 1082. | Both halves render the cube + 2D overlay from two pipelines.  Move mouse → divider tracks, cube rotates to face cursor.  Bottom bar shows live perf comparison. **Bragging rights shipped.** |
| 115   | **DONE.** `readPixels` public API for rlsw + filter-parity fix.  `Context.readPixels(x, y, w, h, dst) usize` copies a sub-rectangle of the color attachment into a caller-owned buffer; mirrors `glReadPixels` semantics with permissive out-of-bounds clipping.  Five tests cover: full-frame round-trip, sub-rectangle layout in dst, partial-overlap clipping (negative origin, oversized rect), fully-outside (returns 0), and degenerate (zero/negative size returns 0).  Demo's rlgl-side checker now uses `setTextureFilter(.., TEXTURE_FILTER_POINT=0)` — without this, GL bilinear was blurring every checker boundary, making the two renderers look more different than they actually are.  Filter parity is the precondition for any honest pixel-diff visualization.  1082 → 1087. | Demo unchanged visually except: rlgl checker now nearest-sampled, so the cube's checker pattern reads as crisp boundaries on both sides instead of blurred-on-rlgl-only. |
| 116   | **DONE.** Pixel-diff overlay shipped — the bragging-rights closer.  Click the bottom-right "diff" button → both renderers freeze, `loadImageFromTexture` reads the rlgl FBO, `Context.readPixels` (turn 115) reads the rlsw framebuffer, per-pixel max-channel diff is computed and uploaded as a heatmap texture.  Three-band classification: `matched` (≤2/255 — slate, fades into chrome), `edge rounding` (3-8/255 — amber gradient, expected at sub-pixel triangle boundaries), `diverged` (>8/255 — red, real disagreement).  Top header shows "Pixel match: NN.NN% &#124; Max channel delta: D/255" + three legend swatches inline.  Click button again to resume live mode; live passes are skipped while the diff snapshot is cached so there's no wasted GPU/CPU work.  Style guide re-read at start (cadence-due, turn 113 last full read).  +0 tests (pure visual feature; the readback path it uses was tested in turn 115).  1087 → 1087. | Click "diff" button at bottom-right → heatmap of per-pixel difference between the two renderers + match-percentage stats + color legend. **Bragging rights closer shipped.** |
| 117   | **DONE.** Documentation: README + CHEATSHEET + LICENSE updated to surface rlsw + gl_iface.  README intro paragraph for rlsw, twelfth example showing dual-pipeline `gl: anytype` pattern, file tree includes `rlsw.zig` / `rlsw_pixel.zig` / `renderer_trait.zig` / `pool.zig`, license table gains rlsw row.  CHEATSHEET hand-appended `rlsw.zig` + `renderer_trait.zig` sections covering lifecycle, pipeline state, immediate mode, texture pool, pixel I/O, and the trait/adapter API.  `scripts/build_cheatsheet.py` updated to include both new files in `INCLUDED_FILES` so future regenerations pick them up automatically.  LICENSE's raylib mapping table gains `rlsw.h` → `src/rlsw.zig` + `src/rlsw_pixel.zig` row.  Test counts in README updated (864→1087, 42→43); DAG numbers updated (14 modules, 48 edges → 18 modules, 61 edges, 1 expected SCC). | n/a (docs only). |

v1 milestone at turn 112.

## Per-phase detail

The cleanup phases are spelled out in detail because they're the
most technical.  The forward phases get a sketch — they'll firm up
as we approach them.

### Turn 90 — Cleanup A: typed spatial values

**Goal:** replace `[2]i32`, `[2]f32`, `[4]f32` (when used as a
spatial position/size, not as an interpolated-color tuple),
`[4]u8` (when used as an RGBA color, not as a generic byte array)
with named structs.

**Changes:**

- In `src/zimrmath.zig`:
  - `Vec2i { x: i32, y: i32 }` (might already exist for ECS;
    extend if so).
  - `Vec2f { x: f32, y: f32 }`.
  - `Rect2i { x: i32, y: i32, width: i32, height: i32 }`.
  - `Color { r: u8, g: u8, b: u8, a: u8 }` with `pub const white:
    Color = .{ .r=255, .g=255, .b=255, .a=255 }` etc.  Conversion
    helpers `Color.toRgbaFloats(self) [4]f32` and
    `Color.fromRgbaFloats(rgba: [4]f32) Color` for the rasterizer
    interior boundary.
- In `src/rlsw.zig`'s `Context`:
  - `vp_size: Vec2i` (was `[2]i32`)
  - `vp_center: Vec2f` (was `[2]f32`)
  - `vp_half: Vec2f`
  - `sc_min: Vec2i`, `sc_max: Vec2i`
  - `sc_clip_min: Vec2f`, `sc_clip_max: Vec2f`
  - `clear_color: Color` (was `[4]f32`)
- In `Texture`:
  - `width`/`height` collapse into `size: Vec2i`.
  - `w_minus_1`/`h_minus_1` collapse into `size_minus_one: Vec2i`.
  - `tx`/`ty` collapse into `inv_size: Vec2f`.
- In `pixel.read_color8` / etc.: stay on `[4]u8` and `[4]f32` for
  rasterizer interior (these are interpolated-channel arrays, not
  spatial values; flat-array form is what the inner loop wants).

**Tests adapt.**  Every test that says `try expectEqual([2]i32{...}
, ctx.vp_size)` becomes `try expectEqual(Vec2i{ .x=..., .y=... },
ctx.vp_size)`.  Net new tests probably zero — these are
substitutions.

**Risk:** test file is mechanical to update.  Compiler will catch
every callsite.

### Turn 91 — Cleanup B: enum cleanup + EnumArray + EnumSet

**Goal:** drop GL wire-number values, type-ify pixel-format tables
and capability bitmasks.

**Changes:**

- All public enums in section 1 lose their `0xXXXX` hex values.
  `DrawMode = enum(u32) { triangles = 0x0004 ... }` becomes
  `DrawMode = enum { points, lines, triangles, quads }`.  Existing
  tests that pin wire numbers (`pinAllEnumValues`) get deleted —
  they were guarding compatibility we no longer want.
- `Capability` enum stays but its values become natural Zig values.
- `Context.user_state` and `Context.raster_state` become
  `state: std.enums.EnumSet(Capability)` and `raster_state:
  std.enums.EnumSet(Capability)`.  All `(state & SCISSOR_TEST_BIT)
  != 0` reads become `state.contains(.scissor_test)`.
- Pixel-format tables move from `[PixelFormat.count]?Fn` to
  `std.enums.EnumArray(PixelFormat, ?Fn)`.  All
  `read_color_table[@intFromEnum(fmt)]` reads become
  `read_color_table.get(fmt)`.
- `pixel_format_size: EnumArray(PixelFormat, u8)` and
  `pixel_format_alpha: EnumArray(PixelFormat, PixelAlpha)`.
- `PixelAlpha` enum (`none` / `bin` / `yes`) gets reconsidered.
  In the donor it controls "should the rasterizer skip alpha
  blending for opaque formats?"  Either keep as enum (clearer than
  three bools) or split into `has_alpha: bool` + `alpha_is_binary:
  bool`.  Decision: keep as enum, the three-state distinction is
  real.

**Tests adapt.**  Pin tests for `EnumSet`/`EnumArray` round-trips;
delete the wire-number pins.

### Turn 96 — Cleanup B+: typed handles (zpool-inspired) — **DONE**

**Goal:** distinct handle types per pool, with cycle-in-handle
stale-after-reuse detection.  Inspired by zig-gamedev/zpool's
`Handle(index_bits, cycle_bits, TResource)` design — but slimmed
down to fit our two-pool, single-element-per-slot use case.

**Why now**: phantom-typed handles catch a real bug class — passing
a TextureHandle to a function expecting a FramebufferHandle
currently compiles silently because both are bare `u32`.  And
cycle-in-handle catches stale-after-reuse, where today
`pool.valid(old_handle)` returns true if the slot was freed and
re-allocated to a new occupant.  Doing this BEFORE Cleanup C means
the pixel-module rewrite operates on the cleaned-up Pool API.

**Changes:**

- New `pub fn Handle(comptime TResource: type) type` returning a
  non-exhaustive enum:

  ```zig
  pub fn Handle(comptime TResource: type) type {
      _ = TResource;  // phantom — distinguishes Handle(Texture)
                     //          from Handle(Framebuffer).
      return enum(u32) {
          nil = 0,
          _,

          const cycle_bits: u5 = 8;
          const index_bits: u5 = 24;

          pub fn pack(index: u24, cycle: u8) @This() { ... }
          pub fn index(self: @This()) u24 { ... }
          pub fn cycle(self: @This()) u8 { ... }
          pub fn isNil(self: @This()) bool {
              return self == .nil;
          }
      };
  }
  ```

  - Total size: `u32` (matches today's `u32`).
  - 24-bit index = 16M slots ceiling.  Generous; the donor's
    `max_textures = 128` is way under.
  - 8-bit cycle = 256 acquire+release before the cycle wraps for a
    given slot.  Same as our `gen[u8]` byte today.
  - `nil` is the zero value (matches `handle_null = 0` today).
  - Non-exhaustive enum (`_` case) means any `u32` is a valid
    Handle bit pattern; we never have to `@enumFromInt`.
- `Pool(T)` has a `pub const Handle = HandleNs.Handle(T);`.
  `Pool(T).alloc` returns `Handle`, `Pool(T).get` takes `Handle`,
  etc.  The bare `u32` API goes away.
- `Pool(T).gen` becomes `Pool(T)._cycle: []u8` — the per-slot
  cycle counter.  `valid(h)` checks BOTH that the slot is live
  AND that `h.cycle()` matches `_cycle[h.index()]`.  Stale
  handles whose slots were reused will fail the cycle check.
- Adopt zpool's "even cycle = free, odd cycle = live" convention
  to eliminate the separate LIVE bit.  `alloc` increments cycle
  (free → live, even+1 = odd); `free` increments again (live →
  free, odd+1 = even).  Cycle wraps with `+%`.
- `Context` field types update: `texture_pool: Pool(Texture)` is
  the same shape, but `Context.bound_framebuffer_id: u32` becomes
  `Context.bound_framebuffer: Pool(Framebuffer).Handle`.  Same
  for any future `bound_texture_id`.
- The four gen/delete shims:
  - `genTextures(self: *Context, out: []Pool(Texture).Handle) void`
  - `deleteTextures(self: *Context, handles: []const Pool(Texture).Handle) void`
  - Same shape for framebuffers.
- `pool_slot_live` and `pool_slot_ver_mask` constants — gone.
  The cycle's LSB serves the role.

**What we DON'T adopt from zpool:**

- Configurable `(index_bits, cycle_bits)` — one set of defaults
  is enough.  Hardcoded `index_bits = 24, cycle_bits = 8`.
- `std.MultiArrayList` storage with `TColumns` — we have one
  element type per pool; AoS is fine.
- `RingQueue` FIFO free list — LIFO works fine for our case
  (cycle wrap concerns are negligible at 256 cycles per slot).
- Three-flavor API (`add` / `addIfNotFull` / `addAssumeNotFull`)
  — we have `alloc` returning `nil` on exhaustion, that's enough.
- The `AddressableHandle` round-trip — at 24+8 bits, packing
  costs nothing and unpacking via two `@truncate` is also free.

**Tests adapt.** Existing Pool tests pin u32 values
(`@as(u32, 1)`); they become `Pool(...).Handle` constructions.
**New tests:**

- "Handle(Texture) and Handle(Framebuffer) are distinct types"
  — `comptime` assertion that the types differ.
- "Stale handle after reuse fails cycle check" — alloc, free,
  alloc again same slot; old handle's `valid` is false.

### Turn 97 — Cleanup C: pixel module consolidation — **DONE**

**Goal:** the 56 reader/writer functions become 4 comptime-
specialized functions + comptime-built dispatch tables.  Slices
everywhere instead of many-item pointers.  `Texture` loses its
function-pointer fields.  Read style guide before starting.

**Changes:**

- `pub fn readColor8(comptime fmt: PixelFormat, src: []const u8,
  index: u32) [4]u8` — single fn with a `switch (fmt) { ... }`.  Each
  arm is the small inline expression we already have.  Compiler
  monomorphizes per format, generating identical machine code to
  what the 14 separate fns produce today.
- Dispatch tables built at comptime:
  ```zig
  pub const read_color8_table: EnumArray(PixelFormat, ?ReadColor8Fn)
      = blk: {
      var tab: EnumArray(PixelFormat, ?ReadColor8Fn) = .initFill(null);
      inline for (std.enums.values(PixelFormat)) |fmt| {
          if (comptime supportsColor8(fmt)) {
              tab.set(fmt, &struct {
                  fn dispatch(out: *[4]u8, src: []const u8, idx: u32) void {
                      out.* = readColor8(fmt, src, idx);
                  }
              }.dispatch);
          }
      }
      break :blk tab;
  };
  ```
  Same for `readColor`, `writeColor8`, `writeColor`.
- `Texture.pixels: []u8` (was `[*]u8` + separate `alloc_sz: usize`).
- Drop `Texture.read_color8` / `Texture.read_color` function-pointer
  fields.  Sample paths read the format off the texture and look
  up via the dispatch table directly.  Saves 16 bytes per texture
  and removes a redundant indirection.
- `expand_NtoB` family becomes
  `pub fn expandToByte(comptime n: u3, v: u8) u8` with one switch.
  Six functions become one.
- All `[*]u8` / `[*]const u8` parameters in pixel readers/writers
  become `[]u8` / `[]const u8`.
- Internal helpers (`luminance8`, `luminance`, `colorToColor8`,
  `color8ToColor`) get clearer names: `luminanceFromBytes`,
  `luminanceFromFloats`, `floatColorToBytes`, `byteColorToFloats`.

**Tests adapt.**  `pixel.read_color8.r5g6b5` → `pixel.readColor8(.color_r5g6b5, ...)`.
Round-trip tests are small mechanical changes.  Net test count
should hold or grow slightly (monomorphization sanity tests).

### Turn 94 — Demo lift

**Goal:** ship `examples/rlsw_side_by_side.zig` as a buildable file
that renders something visible.

**Changes:**

- Promote `src/notes/staging/rlsw-example-scaffold.zig` to
  `examples/rlsw_side_by_side.zig`.  Trim the `[pending]` sections
  to just what the current API supports.  Wire `z.run` properly.
- `update` body, minimum:
  1. Render the WebGL side (just clear to a different background
     color so the user can see two halves).
  2. Call `s.sw.clearColor(...)` and `s.sw.clear(.{ .color = true })`
     — the public `clear` ships THIS TURN as part of the demo
     prerequisites.
  3. `z.textures.updateTexture(s.sw_tex, sliceFromColorBuffer(s.sw))`
     — uploads sw framebuffer to GL texture.
  4. `z.shapes.drawTexture(...)` to draw the texture on the right half.
- Add `Context.colorBufferBytes() []const u8` — one-line accessor
  for the color attachment's pixel slice.  We need this for
  `updateTexture`.
- `examples-plan.md` gets an entry; `build.zig` is updated.
- Smoke test count should rise from 42 to 43 (the smoke-test
  harness currently runs each example once with a stub frame
  loop; the new example joins).

**Risk:** the example imports zimr.  Need to make sure the import
graph stays acyclic (`rlsw → std` only; example → both rlsw and
zimr).  `check_dag.py` will catch it if I get it wrong.

### Turn 95 — Public API 1: clear + state setters

**Goal:** the user-facing surface for setting up a frame.

**Methods on `Context`:**

- `clear(self: *Context, mask: ClearMask) void` — wipes the
  selected attachments using `clear_color`/`clear_depth`.
  Internally: per-format dispatch through the write-color/write-
  depth tables filling the buffer.
- `clearColor(self: *Context, c: Color) void`
- `clearDepth(self: *Context, depth: f32) void`
- `enable(self: *Context, cap: Capability) void` — sets the bit
  in `state` (and recomputes `raster_state` if a relevant cap is
  involved).
- `disable(self: *Context, cap: Capability) void`
- `viewport(self: *Context, x: i32, y: i32, w: i32, h: i32) void`
  — recomputes `vp_size`, `vp_center`, `vp_half`.
- `scissor(self: *Context, x: i32, y: i32, w: i32, h: i32) void`
  — recomputes `sc_min`/`sc_max` and the clip-space versions.
- `blendFunc(self: *Context, src: BlendFactor, dst: BlendFactor) void`
  — writes the factors and recomputes `blend_func`/`blend_flags`
  (Phase 7 wiring lands here).
- `cullFace(self: *Context, face: Face) void`
- `frontFace(self: *Context, winding: ...) void`
- `polygonMode(self: *Context, mode: PolyMode) void`
- `pointSize(self: *Context, size: f32) void`
- `lineWidth(self: *Context, width: f32) void`

**Tests:** invariant tests for each setter — the field changes,
related cached fields recompute, error states for bad inputs.

**Demo:** sw side cycles between three colors using `clearColor`.

### Turn 96 — Matrix stacks

**Goal:** the 3D math substrate.

**Methods on `Context`:**

- `matrixMode(self: *Context, mode: MatrixMode) void`
- `pushMatrix(self: *Context) void` (sets `err_code=stack_overflow`
  on full stack; doesn't `try`-fail because it's GL-semantic).
- `popMatrix(self: *Context) void`
- `loadIdentity(self: *Context) void`
- `translate(self: *Context, t: Vec3f) void` (Vec3f is a new
  zimrmath type; matrix ops want a 3-component vector)
- `rotate(self: *Context, angle_deg: f32, axis: Vec3f) void`
- `scale(self: *Context, s: Vec3f) void`
- `multMatrix(self: *Context, m: types.Matrix) void`
- `frustum(self, l: f64, r: f64, b: f64, t: f64, n: f64, f: f64) void`
- `ortho(self, ..., ..., ..., ..., ..., ...) void`
- (donor uses `f64` for these — matches GL spec; we can
  reconsider, but it's safer)

**Implementation:** introduce a `MatrixStack(comptime cap: u32)`
type so the three stacks have a uniform shape.  Replaces the
six fields (3 arrays + 3 counters) with three named stack-of-N
fields.

**Tests:** stack push/pop balance; identity at depth 1 after init;
matrix mode switching doesn't disturb other stacks; frustum +
ortho produce correct projection matrices (pin known matrices for
fixed inputs).

### Turn 97 — Texture upload

**Goal:** `texImage2D` works end-to-end; demo uploads a procedural
texture.

**Methods:**

- `bindTexture(self: *Context, id: u32) void`
- `texImage2D(self: *Context, format: PixelFormat, w: i32, h: i32,
  pixels: []const u8) !void` — allocates per-texture pixel storage
  via `gpa`, copies user data, fills in the `Texture` struct's
  `width`/`height`/`format`/etc.  This is the first allocation
  that's per-handle rather than per-pool.
- `texParameter(self: *Context, p: enum {min_filter, mag_filter,
  wrap_s, wrap_t}, value: ...) void`
- `deleteTextures` finally frees per-texture pixel storage (the
  TODO from Phase 4 closes here).

**Implementation:** `Texture` gets an owning `pixels: []u8` slice
that's allocated on `texImage2D` and freed on `deleteTextures`.
The default framebuffer's color/depth Textures keep using the
Context-owned big buffers — they don't go through the per-handle
alloc path.  Distinct ownership.

**Tests:** allocation/free leak test (round-trip `texImage2D` →
`deleteTextures` 100 times under `std.testing.allocator` — leak
detector catches any drift).  Format conversion sanity (upload
RGBA8, sample at known UVs, compare).

**Demo:** uploads a 64×64 procedural checker pattern.  UI shows
texture metadata.

### Turn 98 — Begin/end + vertex submission

**Goal:** vertices are accepted, transformed, and accumulated in
the primitive scratch buffer.  No rasterization yet.

**Methods:**

- `begin(self: *Context, mode: DrawMode) void`
- `vertex2f(self: *Context, p: Vec2f) void`
- `vertex3f(self: *Context, p: Vec3f) void`
- `color3f(self: *Context, c: Vec3f) void` (alpha defaults to 1)
- `color4f(self: *Context, c: [4]f32) void`
- `color4ub(self: *Context, c: Color) void`
- `texCoord2f(self: *Context, uv: Vec2f) void`
- `end(self: *Context) void`

**Implementation:** `begin` validates draw_mode (sets err_code on
nested begin), `vertex*` apply MVP, store transformed vertex into
`primitive.buffer[primitive.vertex_count++]`; when the buffer
hits a complete primitive (3 verts for triangles, 2 for lines),
the rasterizer is dispatched (Phase 98 onward will fill that in).
For now `end` resets state without drawing.

**Tests:** vertex count tracking; current_color/current_texcoord
sticky across vertex submissions; `begin`/`end` balance.

**Demo:** UI shows live vertex count.

### Turn 99 onward

Sketches only; we'll firm up as we land each one.  See the table
above.

## What gets dropped from the v2 plan

- **Wire-number compatibility** (Choice 5 in v2).  Gone.
- **"Donor lines covered" accounting** in CHANGELOG entries.
  Gone — we're not measuring our progress in donor lines anymore.
- **Per-variant rasterizer phases** (8a / 8b / 8c / 9 / 10 / 11
  / 12 in v2).  Collapsed into "Triangle BASE" + "Triangle DEPTH
  + TEX" + "Triangle BLEND + cull face" — three turns instead of
  six, because comptime specialization (Cleanup C) makes "the
  variants" automatic from the rasterizer state set.
- **PixelAlpha enum reconsideration.**  Stays as enum.
- **Multi-pixel-format mid-port.**  Already done (turns 87 + 88
  shipped all 14 formats).  Cleanup C consolidates the
  implementation; doesn't drop any formats.

## What carries over from the v2 plan

- **Demo-driven** principle — but we actually mean it this time
  (turn 93 lifts the example into the build).
- **Zero globals** — already verified every turn.
- **Side-by-side example** as the primary integration test.
- **v1 milestone = textured spinning cube on both sides.**
- **Tests grow each turn**, audit gates run each turn.

## Open questions

1. **Vec2 / Vec3 location.**  zimrmath already has some.  Make
   sure Cleanup A doesn't duplicate.  Also: `@Vector(N, T)` vs
   named struct.  Going with named struct for clarity at boundaries
   (`v.x` is more readable than `v[0]`); rasterizer hot paths can
   bitcast to `@Vector` internally if needed.

2. **Color representation.**  Two valid choices: `Color { r,g,b,a:
   u8 }` or `Color { r,g,b,a: f32 }`.  Going with u8 because that's
   what the user types (`.{ .r=255, .g=128, .b=0, .a=255 }` reads
   naturally) and because the framebuffer is byte-typed.  Float
   conversion happens at internal boundaries.

3. **Should `Pool(T)` move to `zimrmath` or `zimrtypes`?**  It's
   generic and reusable.  But moving it creates an import that
   doesn't exist today.  Defer until a second consumer appears.

4. **Texture pixel ownership.**  Per-handle slice (Phase 96 plan)
   vs Context-owned arena.  Per-handle is simpler to reason
   about; arena saves alloc calls but adds bookkeeping.  Going
   per-handle for v1; revisit if profiling shows it.

5. **Rasterizer state-set specialization.**  Cleanup C
   consolidates pixel-format dispatch via comptime.  Phase 100+
   wants the same trick for rasterizer kernels: one
   `rasterizeTriangle(comptime state: RasterState, ...)` that
   the compiler instantiates per (DEPTH? × TEX? × BLEND? ×
   CULL? × ...) combination.  This is the "variants" of the
   donor, made automatic.  Code-size cost: bounded (these
   bools are 4–5 of them, so 16–32 instantiations max).  Decide
   when we get there.

## Worked example: how a turn looks now

Turn 90 (Cleanup A — types) is a good model:

1. **Read style guide** if due (turn 92 next, so skip on turn 90).
2. **Plan the diff**: list every field that changes type, every
   call site that touches that field, every test that pins the
   shape.  Write the plan into the turn's first message.
3. **Edit src/zimrmath.zig** to add Vec2i / Vec2f / Color / Rect2i
   (whichever aren't there yet).  Write tests for the new types
   in the same file.
4. **Edit src/rlsw.zig** field by field.  Compiler errors guide
   the way; each one reveals a callsite.
5. **Update tests** to use the new types.
6. **Run audits.**  Iterate until green.
7. **Update CHANGELOG.**
8. **Save zip.**
9. **Reply to user** with a brief summary + the audit numbers.

The cycle is "plan, code, test, audit, ship" — same rhythm as
the previous era.  The difference is we're refactoring already-
shipped code, not adding new behavior.

## Closing note

The v2 plan was good for the era of "porting a C library to Zig
faithfully."  This v3 plan is for the era of "we've got the
building blocks; let's make them ours."  The cleanup phases
front-load the style debt; the forward phases ride the cleanup
forward.  By turn 105 we have a textured spinning cube that
nobody would mistake for a C port.
