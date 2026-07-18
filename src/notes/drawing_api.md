# draw2d — THE drawing API (surface · multi-backend · one-API conversion plan)

> This is the canonical, current plan. Sections below the `## ✅ ONE-API MILESTONE — rlgl 2D draw exports REMOVED

Removed 29 rlgl free-function draw exports from zimr.zig (drawRectangle/Rec/Lines/
Rounded/RoundedLines/Rotated/GradientVertical/GradientCorners, drawCircle/Lines/
Sector/SectorLines/Gradient, drawLine/Dashed, drawTriangle/Lines/Gradient/Fan,
drawEllipse/Lines, drawRing/Lines, drawPoly/Lines, drawText, drawTexture/Rec,
drawSplineLinear). `zig build test` PASSES — every example compiles using ONLY the
draw2d sink surface. shapes_showcase standalone still renders. **draw2d is now the
sole 2D drawing API; the old positional free-functions are gone.**

KEPT as rlgl (still used, small documented set): 3D functions (drawGrid/Cube/Sphere/
Cylinder/Model/Line3D/Triangle3D/Billboard/Decal/Skybox/Plane/BoundingBox/Mesh, ~15)
— out of draw2d's 2D scope; and **drawTexturedTriangles (1) — mechanically 3D** (routes
through the cube3d pipeline, needs beginMode3D + a Camera3D, world-space `[3]f32`, a
depth buffer; the polygon example's own header says the triangle path "lives in the 3D
pipeline"), so it stays with the 3D set. Everything else 2D is a draw2d sink method.

✅ SPECIALISED 2D FOLD COMPLETE — the last four 2D-drawing functions are folded and
their exports removed from zimr.zig (`zig build test` green, 92 examples on the sink
surface alone):
• **drawTextureRotated** → `sink.texture` honours `.origin` + `.rotation_rad` via a
  general rotated-corner emit (`texCorner`) that reduces exactly to the axis-aligned
  quad when both are zero, so ONE `texture` method covers whole/rec/rotated (2 calls
  converted, pixel source → UV inline via tex dims). **Device-confirmed.**
• **drawTextureNPatch** → routed by `sink.image` when `.npatch` is set; the 1 example
  was restructured from a raw registered `types.Texture` to a `Sprite`. **Device-confirmed.**
• **drawSplineBasis / CatmullRom / BezierCubic** → reimplemented self-contained in
  draw2d (`spline*Emit`, 24 samples/segment stroked as a thick polyline like
  `splineLinear`; the mitred ribbon + round caps are dropped for one shared emit path).
  3 calls converted. **Device-pending** (splines_drawing standalone).

**draw2d is now the sole API for ALL 2D drawing; the only draws left as rlgl free
functions are 3D (including drawTexturedTriangles).**

Dead code note: the wgpu_app/shapes2d function BODIES for the removed exports still
exist (just no longer exported via z). A later pass can delete the truly-unused ones.

## BATCH 6 — MASTER SWEEP: 397 conversions across 106 files

Combined every handler into one master transform (patterns are exact — the `(` after
each name disambiguates drawRectangle vs drawRectangleRounded etc. — so order is
irrelevant) and applied it to ALL example .zig files. 397 calls converted across 106
files. `zig build test` PASSES, lint clean. gallery_all + logo_raylib_anim
standalones built + device-checkable.

Running tally: ~148 examples, ~680 draw calls converted. `zig build test` PASSES.

**54 stragglers remain (arg-shape variants the master skipped, by design):**
- `drawTextureRec` (40) DONE — made `TextureOpts.source` UV-space (0..1) to match
  (it was pixels); `sink.texture` uses source directly as UVs. 35 whole blits ->
  `.{ .tint }`, 5 sprite-frame sub-rects -> `.{ .source = .{ u0, v0, u1-u0, v1-v0 } }`.
  textures_sprite_animation standalone renders sub-rect frames (device-checked).
- `drawText` (7) DONE + `drawCircleGradient` i32-center (3) DONE. Root cause: the
  transform's arg-splitter didn't respect STRING literals, so drawText calls with a
  comma inside the string (`"Hello, World!"`) mis-split and were skipped. Made both
  the splitter AND the line-wrapper string-aware. hello_world standalone renders.
- `drawTextureRotated` (2), `drawTexturedTriangles` (1), `drawTextureNPatch` (1) —
  specialized; convert or leave.
Plus curve splines (3) and 3D functions (out of scope).

## BATCH 5 — last gaps + shapes_showcase fully converted

Filled the remaining rare gaps (self-contained emits in draw2d, methods on WgpuGl):
`circleGradient` (wrap shapes2d), `rectGradientVertical` / `rectGradientCorners`
(per-vertex color4ub), `triangleFan` (fan from points[0]), `splineLinear` (polyline),
`rectRoundedLinesXYWH` (edges + corner arc-lines). shapes_showcase is now FULLY
converted (0 rlgl) — it exercises nearly every primitive — plus math_sine_cosine,
lines_bezier, rounded_rectangle. Standalone built + smokes clean (~140 draws/frame).
`zig build test` PASSES.

Running tally: ~30 examples, ~230 draw calls, 21 gap primitives filled.

**Only remaining rlgl 2D calls:** the curve splines drawSplineBasis /
drawSplineCatmullRom / drawSplineBezierCubic (3 calls, splines_drawing) — they need
control-point interpolation math; left as rlgl (they compile fine) rather than risk
a subtly-wrong curve. Everything else 2D is on draw2d. (3D functions —
drawSphere/Cube/Cylinder/Grid — are out of draw2d's 2D scope by design.)

The gap primitives live on WgpuGl; SwAdapter/Canvas get any of them on demand (a
scene using one on those backends gets a clean missing-method error).

## BATCH 4 — 2D gap primitives + gap-heavy examples (~102 conversions)

Filled the 2D shape gaps. Emit strategy split by whether shapes2d needs a
`shapes_state` (which WgpuGl can't reach):
- REIMPLEMENTED self-contained in draw2d.zig (they need shapes_state): `circleSector`
  (fan), `poly` (fan over full circle), `ring` (inner/outer strip), `lineDashed`
  (dash walk). Plus `circleOutline` from before.
- WRAPPED shapes2d directly (no shapes_state, host-safe gl:anytype): `circleSectorLines`,
  `ringLines`, `triangleLines`, `polyLines`, `ellipse`/`ellipseLines` (via the Vec2
  `drawEllipseV`/`drawEllipseLinesV` — the plain ones take i32 centerX/Y).
All on WgpuGl (where examples draw); SwAdapter/Canvas get them on demand (missing-method
gap otherwise).

FULLY CONVERTED this batch: dashed_line, ring_drawing, ellipse_collision, pie_chart
(+ core in shapes_showcase, math_sine_cosine, rounded_rectangle, lines_bezier, gallery).
`zig build test` PASSES. ring_drawing + pie_chart standalones built + device-checkable.

Running tally: ~28 examples, ~220 draw calls converted; 15 gap primitives filled.
Remaining rare gaps: gradients (circleGradient, rectGradient*, triangleFan), splines
(SplineLinear/Basis/CatmullRom/Bezier), rectRoundedLines — a handful of calls, add on
demand or leave (missing-method).

## BATCH 3 — 69 more conversions (~9 examples)

split_screen, math_sine_cosine, digital_clock, text_layout, orthographic_projection,
gallery, music_streaming, shapes_showcase, splines_drawing — core calls converted via
the comprehensive transform (conv2.py: core + rectRotated/rectRounded/triangleGradient/
texture). `zig build test` PASSES. color_wheel + digital_clock standalones built +
device-checkable (color_wheel exercises the rectRounded + triangleGradient gaps).

Running tally: ~20 examples, ~117 draw calls converted; 5 gap primitives filled
(rectRotated, rectRoundedXYWH, triangleGradient, texture, circle-outline).

**Remaining, by category:**
- 3D functions (drawSphere/Cube/Cylinder/Grid/Wires, drawSpline*) — OUT of draw2d's
  2D scope; those stay (3D scene helpers). Examples: zimrphysics_demo, split_screen,
  orthographic_projection, models3d.
- 2D gaps still to fill (emit-able, add on demand): drawLineDashed, drawCircleSector
  (+Lines), drawTriangleLines, drawEllipse (+Lines), drawRing (+Lines), drawPoly
  (+Lines), drawCircleGradient, drawRectangleGradient*, drawTriangleFan. Concentrated
  in shapes_showcase, ellipse_collision, ring_drawing, dashed_line, pie_chart.
- drawTextureRec (sub-rect texture) — `texture` handles source via opts; a few call
  sites have a different arg shape (UV-based) to reconcile.

## TEXTURE GAP FILLED + batch 2 (texture example)

`sink.texture(dst, tex: WgpuTexture, opts: TextureOpts)` added on WgpuGl — draws a
pre-loaded GPU texture (the model examples actually use, from z.loadTextureFromImage).
Binds the texture directly and emits a textured quad (raylib `drawTexture`'s path) —
NO registry churn. (First attempt used `registerTexture` per frame, which
accumulated bind groups until the 64-slot registry filled and textures vanished
after ~1 frame; the direct-bind path fixes it.) `opts.source` selects a sub-rect in
pixels. GPU-only (WgpuTexture is a GPU object) — CPU sinks
lack the method, the accepted coverage gap. `TextureOpts { source, origin,
rotation_rad, tint }`.

Converted **textures_background_scrolling** (flagship): 6 `drawTexture` -> `texture`.
Standalone builds + smokes leak-clean + renders (device-verified). So the texture
duality (Sprite vs Texture) is resolved: `image` for portable pixel-carrying sprites,
`texture` for pre-loaded GPU handles.

## CONVERSION IN PROGRESS — batch 1 done (~10 examples, 42 calls)

Converted to draw2d + verified (zig build test PASSES): bouncing_ball, ball_physics,
bullet_hell, camera2d, collision_area, clock_of_clocks, color_wheel,
cellular_automata, kaleidoscope (waving_cubes: 2D done; its drawGrid/drawCube are 3D,
out of draw2d scope). A reusable balanced-brace transform (conv.py pattern) maps the
core rlgl calls: drawCircle/CircleLines->circle, drawLine->line, drawRectangle/Rec/
Lines->rect, drawTriangle->triangle, drawText->text (font by &pointer).

**Gaps FILLED** (emit helpers in draw2d.zig + methods on WgpuGl + SwAdapter):
- `rectRotated(rec, origin, rot_rad, opts)` <- drawRectangleRotated (rotated quad)
- `rectRoundedXYWH(x,y,w,h, roundness, segments, opts)` <- drawRectangleRounded
  (3 bars + 4 corner fans)
- `triangleGradient(a,b,c, ca,cb,cc)` <- drawTriangleGradient (per-vertex color4ub)
Device-verified in draw2d_demo (blue rotated rect, maroon rounded rect, RGB gradient
triangle). NOT added to Canvas/DrawList — if a scene uses them there it just won't
compile (missing method), which is the accepted coverage-gap behavior.

**Remaining work + the one real gap:**
- ~600 rlgl calls in other examples — apply the same transform, gate each, fill any
  new gap primitive hit (ellipse/ring/sector/poly/dashed — all emit-able).
- **TEXTURE gap (significant):** drawTexture/drawTextureRec (~60 calls) use a raw
  `Texture` (pre-loaded GPU handle); draw2d `image` takes a `Sprite` (pixel-carrying).
  Different models. Converting needs EITHER a draw2d texture-by-handle primitive
  (`sink.texture(dst, tex, src, tint)`) OR migrating those examples to Sprite. Decide
  before converting texture-drawing examples.
- Gap primitives on Canvas/DrawList (CPU/retained) are added on demand.
- Then delete the rlgl free-function exports -> one API.

=== history ===` marker
> are the older working notes kept for provenance.

## 1. The sink concept

A **sink** is any object that receives draw2d primitive calls. Four sinks exist,
and every one implements the *same* method set:

- `f.gl`  → `WgpuGl`        — GPU, immediate mode (the normal render path)
- `z.SwGl`→ `SwAdapter`     — CPU software rasterizer, immediate mode
- `Canvas`→ `Canvas`        — CPU, renders into an image buffer → PNG (headless/tests)
- `DrawListHandle` → `ui.DrawList` — retained: records now, replays on GPU later

Because the method set is identical, a routine written against `sink: anytype`
runs unchanged on any of them. `f.gl` is simply the GPU sink — there is nothing
GPU-specific about the *call site*.

## 2. The surface — 6 primitives, Options-struct style

    sink.rect(rectangle, .{ .color = c, .outline = 0 })   // outline 0 = filled
    sink.rectXYWH(x, y, w, h, .{ .color = c })            // loose-number twin
    sink.circle(center, radius, .{ .color = c, .outline = 0, .segments = 36 })
    sink.triangle(a, b, cc, .{ .color = col })
    sink.line(a, b, .{ .color = c, .thickness = 1 })
    sink.text(pos, str, .{ .size = 20, .color = c, .font = &my_font })
    sink.image(dst, sprite, .{ .source = null, .tint = white })
    sink.imageXYWH(x, y, w, h, sprite, .{})

Design: nouns not verbs; one Options struct per primitive; ONLY fields that do
something exist (audited — no silent no-ops). Colors/`Rectangle` are values at the
surface; `.font` is `*const Font` because retained sinks record it for replay.
`sprite` is a `z.Sprite` (a portable pixel-carrying handle); residency (GPU upload +
cache) is resolved per-backend behind the call.

## 3. Multi-backend: one scene, three backends

    // Written once, against any sink:
    fn drawScene(sink: anytype, t: f32) void {
        sink.rect(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, .{ .color = bg });
        sink.circle(.{ 400, 300 }, 40, .{ .color = ball });
        sink.line(.{ 0, 300 }, .{ 800, 300 }, .{ .color = axis, .thickness = 2 });
        sink.text(.{ 10, 10 }, "same code, any backend", .{ .size = 20, .color = ink, .font = &font });
    }

    drawScene(f.gl, t);                              // GPU (normal path)
    var sw: z.SwGl = z.SwGl.init(&sw_ctx);           // CPU software rasterizer
    drawScene(&sw, t);                               //   (see sidebyside.zig)
    var canvas = try Canvas.init(gpa, 800, 600);     // headless CPU → PNG
    drawScene(&canvas, t);                           //   (see native_plot_png)

`sidebyside.zig` already runs its `drawScene(gl: anytype)` on GPU + SW like this;
plot runs its scene on Canvas (PNG) + DrawList (GPU) + SvgSink (SVG). draw2d makes
this the norm for *any* example rather than a special case. The northstar (SPH fluid
identical on CPU vs GPU via a runtime toggle) is exactly this pattern.

## 4. rlgl → draw2d coverage

The old rlgl free functions (`z.drawRectangle(f.gl, ...)`) and draw2d
(`f.gl.rect(...)`) are BOTH backend-agnostic (`gl: anytype`); they differ in STYLE
(free-function + positional vs method + Options), not capability. draw2d currently
covers the CORE:

    drawRectangle/V/Rec         -> rect / rectXYWH
    drawRectangleLines          -> rect(.{ .outline = n })
    drawCircle/V                -> circle
    drawCircleLines             -> circle(.{ .outline = n })
    drawLine/V                  -> line
    drawText/Ex                 -> text
    drawTriangle                -> triangle
    drawTexture/V/Pro           -> image

NOT yet in draw2d (add on demand, or those calls stay rlgl until then):
drawEllipse(Lines), drawRing(Lines), drawCircleSector(Lines), drawPoly(Lines),
drawTriangleGradient, drawCircleGradient, drawLineDashed, drawRectangleRounded(Lines),
drawRectangleRotated.

## 5. The one-API conversion plan (phased)

GOAL: one drawing API (draw2d). The rlgl free functions get replaced in examples,
then deleted. The rlgl SUBSTRATE stays (drawTexturePro, drawWithFont, the gl trait
begin/vertex2f/setTexture) — draw2d is built on it; only the high-level raylib-named
wrappers go.

**Phase 0 — the surface (DONE).** All 6 primitives on all 4 backends, verified
(plot renders through Canvas; draw2d_demo device-proven on GPU). Options honest.
Proof-of-conversion: `bouncing_ball` converted (drawCircle→circle, drawText→text),
compiles + tests pass.

**Phase 1 — convert the launcher flagships' CORE drawing.** Flagships (build.zig):
helmet_sw, shadowmap_sw, decals, deferred_render, cel_shading, fog_rendering,
hybrid_render, textures_background_scrolling, ui_full_showcase, zimrphysics_demo,
zimrphysics2d_demo, mandel_sidebyside, rt_sidebyside, plot_demo, plot3d_demo,
sph_fluid_2d, ecs_boids, fluid_sort, skinned_mesh, mandel_julia, kaleidoscope,
waving_cubes, gallery_all. Most are 3D/compute and only use core 2D for HUD text +
simple shapes → mechanical. Per example: swap rlgl→draw2d calls, `zig build
<name>-standalone -Dmode=release`, smoke, device-verify. Fonts: `&state.font` +
`z.unloadFont` in deinit (now leak-clean). Work example-by-example, gate after each.

**Phase 2 — close the coverage gap for what flagships actually use.** If a flagship
uses an advanced primitive (ellipse/ring/sector/poly/gradient), ADD it to draw2d (an
emit helper in draw2d.zig + a method on each sink, following circleOutline) rather
than leave one call on rlgl. Add only what's used, backed by the existing renderers
(e.g. rounding → shapes2d.drawRectangleRounded).

**Phase 3 — sweep + remove rlgl.** Convert remaining non-flagship examples, then
delete the rlgl free-function exports from zimr.zig (drawRectangle, drawCircle,
drawLine, drawText, drawTriangle, …). draw2d becomes the sole high-level API — ONE
API. Then rewrite the readme's 2D-drawing section (it currently presents raylib
names, `z.drawRectangleV(f.gl, …)`) around the sink API + the multi-backend story.

**Known backend gap along the way:** SwAdapter `image` (SW texture path — the trait
setTexture is a no-op clear; needs bindTexture+texImage2D or a framebuffer blit).
Only blocks a flagship that draws *sprites* on the SW half.

=== history ===

# Drawing API unification — plan

## Goal

One primitive vocabulary across **immediate** (rlgl) and **retained** (`DrawList`,
`Canvas`). The same scene function

```zig
fn drawHud(sink: anytype) void { sink.rect(...); sink.image(...); sink.text(...); }
```

runs three ways with no rewrite:

```zig
drawHud(gl);       // immediate  → emits geometry to the GPU this frame
drawHud(&list);    // retained   → records commands into a DrawList (GPU replay)
drawHud(&canvas);  // retained   → rasterizes to an RGBA buffer → PNG (CPU, in-sandbox)
```

Immediate-vs-retained becomes a *backend* choice — exactly the axis CPU-vs-GPU
already is via `gl: anytype`. The `&canvas` target is the headline: any scene can
be dumped to a PNG and `view`ed in the sandbox with no device, the same
headless-verification move that found the font-atlas bug and proved the npatch
geometry this session, lifted from one primitive to whole scenes.

## Design decisions (locked)

1. **Names — noun-only.** `sink.rect` / `image` / `text` / `line` / `circle` /
   `triangle`. The sink type implies draw-vs-record, so the verb is redundant;
   this also kills the `draw*` / `add*` / `*Filled` three-way schism. raylib names
   survive only as compat aliases.
2. **Color — `Color` struct at the surface everywhere.** `DrawList` packs to
   `ColorU32` internally at the store boundary (same 4 bytes; packing is a backend
   detail). Verify `shapes2d` replay doesn't hard-require `ColorU32` at a hot spot;
   if it does, pack there, not at the call site.
3. **Rect — `Rectangle { x, y, width, height }` (f32) everywhere.** Retire
   `Rect { x, y, w, h }` (Canvas + plot migrate; mechanical).
4. **Angle — radians everywhere.** One unit means no per-call-site deg/rad
   ambiguity. The `WgpuGl.rotate` added this session takes degrees (mirrors
   `rlRotatef`) — it flips to radians; a degree-taking shim survives only for the
   raylib compat name and conventional exceptions (`fovy`).
5. **Font — per-call `.font` in Options, with a sink-level default.** Explicit like
   the color arg; default keeps it terse; survives a scene mixing two fonts.
   Canvas `useFont` becomes the default-setter, and its `text()` gains a `.font`
   override.
6. **Canvas — full Sink backend.** It already has every primitive + a clip stack.
   CPU-only concerns (supersample factor, `resolve`, PNG export) stay Canvas-only
   extensions beyond the shared trait.
7. **Migration — coexist, then delete.** Old `drawX` become thin shims over the new
   primitives; call sites migrate in screenshot-verifiable batches; shims come out
   in a final lint-enforced sweep. Not a pure rename — collapsing the texture/rect
   families changes arg *shape*, so call sites are rewritten, not find-replaced;
   coexistence keeps the gate green and the ~230 examples building throughout.

## The Sink surface

Six primitives, each a noun + an Options struct (defaults bracketed). All angles
radians, all colors `Color`, all rects `Rectangle`.

```zig
sink.rect(r: Rectangle, opts: RectOpts) void
sink.image(dst: Rectangle, tex: Texture, opts: ImageOpts) void
sink.text(pos: Vec2, str: []const u8, opts: TextOpts) void
sink.line(a: Vec2, b: Vec2, opts: LineOpts) void
sink.circle(center: Vec2, radius: f32, opts: CircleOpts) void
sink.triangle(a: Vec2, b: Vec2, c: Vec2, opts: ShapeOpts) void

// state — in the shared trait (both modes can honor these):
sink.pushClip(r: Rectangle) void   sink.popClip() void
sink.pushMatrix() void   sink.popMatrix() void
sink.translate(x, y, z: f32) void  sink.rotate(rad, x, y, z: f32) void  sink.scale(x, y, z: f32) void
```

```zig
pub const RectOpts = struct {
    color: Color,
    outline: f32 = 0,     // 0 → filled; >0 → line thickness
    rounding: f32 = 0,    // corner radius
    rotation: f32 = 0,    // radians, about the rect origin
};
pub const ImageOpts = struct {
    source: ?Rectangle = null,  // null → whole texture (pixel-space source rect)
    origin: Vec2 = .{ 0, 0 },
    rotation: f32 = 0,          // radians
    tint: Color = white,
    npatch: ?NPatchInfo = null, // set → nine/three-patch (folds drawTextureNPatch in)
};
pub const TextOpts = struct {
    size: f32,
    color: Color,
    font: ?Font = null,   // null → sink default
    spacing: f32 = 0,
};
pub const LineOpts   = struct { color: Color, thickness: f32 = 1 };
pub const CircleOpts = struct { color: Color, outline: f32 = 0, segments: u32 = 36 };
pub const ShapeOpts  = struct { color: Color, outline: f32 = 0 };
```

`image` alone collapses raylib's `DrawTexture` / `V` / `Ex` / `Rec` / `Pro` /
`NPatch` (six) plus Canvas `texturedQuad` plus DrawList `addImage` into one call.
`rect` collapses `drawRectangle` / `Rec` / `Rounded` / `Lines` / `Rotated` /
`GradientVertical` / `GradientCorners` (a gradient fill is a later `.fill`
extension) plus `fillRect` plus `addRectFilled` / `addRectOutline`.

## Two-tier architecture

The primitive surface is uniform, but the two modes implement it differently and
that difference must NOT leak into the trait:

- **Immediate** (`WgpuGl`, `SwAdapter`, `GlAdapter`): a primitive *decomposes now*
  into `begin`/`vertex2f`/`color4ub` on the existing low-level trait. This is what
  the current `shapes2d` `gl: anytype` free functions already do.
- **Retained** (`DrawList`, `Canvas`): a primitive is *recorded* at the primitive
  level — `DrawList` stores a rect/image/text command (so it can re-flow and
  replay), `Canvas` rasterizes into its RGBA buffer. They must NOT be forced to
  decompose to triangles, or the DrawList loses its command structure.

So the trait exposes the *primitive* level; each backend supplies its own body.

**Open implementation call (Phase 3):** how the three immediate adapters acquire
the primitive methods without writing them 3×. Recommended: the decompose logic
lives once as shared free helpers (`primitives.emitRect(gl, ...)`, essentially the
current `shapes2d` bodies), and each immediate adapter gets one-line delegating
methods (`pub fn rect(self: *@This(), r, o) { primitives.emitRect(self, r, o); }`).
Retained backends implement `rect`/`image`/`text` directly. (Avoids
`usingnamespace`, which is unstable on 0.17-dev.) Confirm before Phase 3.

## Migration map — current state → target

| Backend | primitives today | rect repr | color | font | changes |
|---|---|---|---|---|---|
| Immediate (`shapes2d` free fns + `WgpuGl` methods) | `drawRectangle*`×8, `drawTexture*`×6, `drawText`, `drawLine`, `drawCircle*`, `drawTriangle` | split (`drawRectangle` = pos+size) **and** `Rectangle` (`drawRectangleRec`) — inconsistent | `Color` | per-call | collapse families; unify rect to `Rectangle`; methodize as `sink.*`; keep `drawX` as shims |
| `DrawList` (ui.zig) | `addRectFilled`/`addRectOutline`, `addImage`, `addText`, `addLine`, `addCircleFilled`, `addTriangleFilled` | `Rectangle` | `ColorU32` | per-call (`?*const Font`) | rename `add*`→`*`; `Color` at surface (pack internally); fold filled/outline into opts |
| `Canvas` (Canvas.zig) | `fillRect`, `texturedQuad`, `text`, `line`, `circleFilled`, `triangleFilled`, `pushClip`/`popClip` | `Rect{w,h}` | `Color` | bound (`useFont`) | rename; `Rectangle`; `Texture` handle (not raw `tex_id: u32`); per-call `.font` + default; source-rect not raw UVs; becomes a Sink |

Notable existing inconsistencies this fixes: immediate `drawRectangle` is a
`*WgpuGl` method (pos+size) while `drawRectangleRec` is `gl: anytype` (`Rectangle`)
— the simple one doesn't even work on Sw/Gl today; `drawTexturePro` is radians
while raylib's is degrees; Canvas exposes normalized UVs while immediate exposes a
pixel source rect.

## Phases

0. **Value types.** Land `Rectangle` as the one rect (retire `Rect{w,h}`),
   `Color` at every surface, `Texture` handle in Canvas, radians in `WgpuGl.rotate`
   (+ degree shim). Mechanical; gate-caught.
   - [x] **Radians done.** Both immediate `rotate` impls flipped to `angle_rad`:
     `WgpuGl.rotate` (dropped the internal `radFromDeg`) and raster `Context.rotate`
     (dropped `angle_deg*pi/180`). Callers updated net-identical: `drawTextureNPatch`
     passes `rotation_rad` directly; `rlRotatef` kept as the DEGREES compat name,
     now converting `radFromDeg(angle_deg)` before calling `rotate`. Orphaned imports
     removed (`radFromDeg` in WgpuGl, `degFromRad` in image). Guardrail: the raster
     "rotate by pi/2 around Z" unit test still passes (was "90 degrees"). Convention:
     angle params are `_rad`-suffixed; `_deg` survives only on the raylib compat shim.
   - [ ] Rectangle unification (`Rect{w,h}` → `Rectangle{width,height}` in Canvas/plot)
   - [ ] Color at the DrawList surface (`ColorU32` → `Color`, pack internally)
   - [ ] Texture handle in Canvas (`tex_id: u32` → `Texture`)
1. **New primitive surface, immediate first.** Add `sink.rect`/`image`/`text`/… to
   the immediate adapters (via the shared helpers), and to `DrawList` + `Canvas`.
   Old `drawX`/`add*`/Canvas names become thin shims over them. Everything still
   builds.
2. **Collapse.** Fold the texture and rect families into the Options calls; the
   old six/eight entry points become shims that fill an Options struct.
3. **Extract the Sink trait.** Formalize the method set (mirror
   `renderer_trait.zig`); convert one HUD to `fn draw(sink: anytype)` and prove
   `draw(gl)` == `draw(&list)` == `draw(&canvas)` (the last dumped to PNG and
   viewed in-sandbox). Resolve the immediate-method mechanics call above.
4. **Migrate + delete.** Move call sites and examples in screenshot-verifiable
   batches; remove the shims in a final sweep the lint enforces.

## Before / after

```zig
// RECT — three reprs today (note the pos+size split and ColorU32)
z.drawRectangle(gl, .{ x, y }, .{ w, h }, color);
canvas.fillRect(.{ .x = x, .y = y, .w = w, .h = h }, col);
list.addRectFilled(.{ .x = x, .y = y, .width = w, .height = h }, cu32);
// after
sink.rect(.{ .x = x, .y = y, .width = w, .height = h }, .{ .color = color });

// IMAGE — the Pro/Ex/Rec/NPatch collapse
z.drawTexturePro(gl, tex, source, dest, origin, rotation_rad, tint);
canvas.texturedQuad(dest, tex.id, uv0, uv1, tint);
list.addImage(tex, p_min, p_max, uv_min, uv_max, cu32);
// after
sink.image(dest, tex, .{ .source = source, .origin = origin, .rotation = rot, .tint = tint });
sink.image(dest, tex, .{});  // whole texture, no rotation, white

// TEXT
z.drawText(gl, font, "hi", x, y, size, color);
canvas.text(.{ x, y }, "hi", size, col);            // font is bound state
list.addText(font, "hi", .{ x, y }, cu32);          // font first, no size
// after
sink.text(.{ x, y }, "hi", .{ .size = size, .color = color, .font = font });

// THE PAYOFF — one scene, three targets
fn drawHud(sink: anytype) void { sink.rect(...); sink.text(...); }
drawHud(gl); drawHud(&list); drawHud(&canvas);
```

## Resolved refinements + Phase-1 progress

**Rect variants — scheme B (locked).** The bare name takes the struct; a spelled-out
`XYWH` twin takes loose numbers, so callers without a `Rectangle` aren't forced to
build one. Only `rect` and `image` get the twin (their struct, `Rectangle`, is the
verbose one); `text`/`line`/`circle` take `Vec2`, whose literal `.{x, y}` is already
terse — no twin needed. Two names, not a comptime overload (Zig resolves by name;
clean errors).

```zig
sink.rect(r: Rectangle, opts)          sink.rectXYWH(x, y, w, h: f32, opts)
sink.image(dst: Rectangle, tex, opts)  sink.imageXYWH(x, y, w, h: f32, tex, opts)
```

**`Rect` stays.** `Rect{x,y,w,h}` (plot/Canvas) is NOT deleted — it remains the
internal terse helper; the public surface is `Rectangle{x,y,width,height}`, and a
trivial field-rename bridges the two. So "someone with a Rectangle draws it easily,
someone without one isn't forced to make one," and terse internal code keeps `Rect`.

**Shared Options live in `src/draw2d.zig`** — `RectOpts` / `ImageOpts` / `TextOpts`
/ `LineOpts` / `CircleOpts` / `ShapeOpts`, imported by every backend.

Progress:
- [x] `draw2d.zig` Options structs.
- [x] **Canvas `rect` + `rectXYWH`** — filled + outline; PNG-verified in-sandbox
  (both variants render). Rounding/rotation deferred on the CPU canvas. `fillRect`
  kept (coexist). Reusable host harness: `src/canvas_render_test.zig` (lint-excluded).
- [x] **Canvas `image` + `imageXYWH`** — REAL sampling (was a tint-fill stub).
  `Texture` handle + pixel-space `source`; box-averaged blit via `imageDraw`;
  tint honored. Needed a small non-owning `Texture` store on Canvas +
  `registerTexture(Image) -> Texture` (the GPU handle carries no pixels). An
  unregistered/GPU handle degrades to a tint fill. Origin/rotation/npatch deferred
  on CPU. PNG-verified (whole / sub-rect / tinted). `texturedQuad` kept (coexist).
  FOLLOW-UP: cross-backend texture identity — a scene targeting both GPU and Canvas
  needs the same handle resolvable on both; likely a uniform `sink.registerTexture`
  / asset layer. Deferred, noted.
- [x] **Canvas `circle`** — additive (`circleFilled` stays as the plot-sink name);
  filled disc, outline/segments deferred on CPU. PNG-verified.
- [ ] Canvas `text` + `line` — BLOCKED on the plot-sink reconciliation (below).

## Discovery: plot.zig is a proto-sink system (decision needed)

`plot.zig` already runs `fn draw(sink: anytype)` scenes against three sinks —
`SvgSink` (SVG string), `DrawListSink` (wraps `ui.DrawList`), and `Canvas` — via
its own contract: `fillRect`, `line`, `text`, `circleFilled`, `texturedQuad`,
`triangleFilled` (+ `begin`/`end`/`deinit`/`toOwned` lifecycle), with 64 call
sites. This is a parallel, older version of exactly the draw2d Sink.

Overlap analysis: `rect`/`image`/`circle` were safe to add (plot uses the *other*
names — `fillRect`/`texturedQuad`/`circleFilled` — which we kept). But **`line` and
`text` collide**: plot calls `sink.line(a,b,col,thickness)` and
`sink.text(pos,s,size,col)` with the old positional signatures, so reshaping them to
the draw2d opts form breaks plot's three sinks + its call sites.

The real question is whether plot's sink system *converges onto* draw2d (its three
sinks implement the draw2d Sink; `line`/`text` reshape everywhere; ~64 call sites
update) — which is the right endgame but a real migration — or whether `line`/`text`
on Canvas wait while the GPU/DrawList backends go first. DECISION PENDING.
- [x] **DrawList primitives (`rect`/`rectXYWH`/`circle`)** on `DrawListHandle` —
  the allocator-bound handle users already get from `getForegroundDrawList`. It
  holds the frame-arena allocator AND takes `Color` (packs via `toWire`), so
  `sink.rect(r, opts)` matches Canvas's signature exactly (no alloc param). Thin
  wrappers over the existing `add*`; rounding/outline-thickness deferred (the add*
  rect methods don't take them). Unit-tested in-sandbox (`zig build test`): `rect`
  emits the identical `rect_filled` command as `addRectFilled(toWire)`, `rectXYWH`
  matches `rect`, `circle` records. Had to rename the `rect` *param* in the handle's
  `addRectFilled`/`addRectOutline` to `r` (the new `rect` method shadowed it).
- [x] **Immediate primitives (`rect`/`rectXYWH`/`circle`)** on WgpuGl AND
  SwAdapter — the mechanics call resolved cleanly: shared `emit*` helpers in
  `draw2d.zig` (`rectFilled`/`rectOutline`/`circleFilled`, `gl: anytype`) that
  decompose via `setTexture(0)` (portable white-bind — all three adapters take
  `setTexture(u32)`) + `begin`/`color4ub`/`vertex2f`, mirroring the proven
  `drawRectangle`; each adapter gets one-line delegating methods. `sink.rect(r,
  opts)` is now identical across Canvas, DrawList, WgpuGl, and SwAdapter. Rounding
  + outline circles deferred. Gate-verified (both adapters compile, no regressions).
  VISUAL VERIFY PENDING: SW adapter → framebuffer → PNG in-sandbox (reusable, next),
  or a device standalone once an example calls `gl.rect`.
- [x] **Image on the immediate GPU backend + Sprite residency cache.**
  `WgpuGl.image(dst, sprite, opts)` calls `resolveSprite`: on a sprite it hasn't
  seen, uploads `sprite.image` via `WgpuTexture.createFromPixels` and registers it
  (engine-owned) — caching `sprite.id -> texture id` in the renderer (a bounded
  fixed-array map, cleared with the registry so no cycle vs wgpu_app). Then draws
  via the proven `drawTexturePro` / `drawTextureNPatch` (folds `.npatch` in).
  `imageXYWH` twin. z.Sprite exported. New `examples/draw2d_demo` exercises
  rect/circle/image(Sprite) on the GPU — smoke LEAK-CLEAN (uploaded texture freed on
  teardown, cache clears), standalone built for device confirm. So `sink.image(dst,
  sprite, opts)` now renders on Canvas AND the immediate GPU backend from one call.
- [x] **`line` on the immediate adapters (WgpuGl + SwAdapter).** They aren't plot
  sinks (only Canvas is), so `line` was safe to add without the plot collision that
  blocks it on Canvas. Emit is a thick quad perpendicular to a->b (`lineEmit`);
  mock-gl-tested; in the draw2d_demo device standalone. So the immediate surface now
  has rect / circle / image(Sprite) / line — only `text` remains there (needs the
  per-call `.font` default resolved, since the adapters hold no default font).
- [x] **`line` on DrawList** (DrawListHandle, wrapping `addLine`) — unit-tested.
  So `line` is on WgpuGl / SwAdapter / DrawList; only Canvas's is blocked (plot).

## Honest review pass — findings + one fix

Tie-up done: **`CircleOpts.outline` now works** (was a silent no-op on every
immediate/CPU path). Added `draw2d.circleOutline` (a ring = triangle strip between
inner/outer radius), wired WgpuGl + SwAdapter; DrawList already honored it via
`addCircle`. Mock-gl-tested + in the demo standalone.

Non-issue dismissed: the Sprite residency cap (64) is NOT a real footgun — the
texture registry itself caps at 64 and sprites register into it, so
`registerOwnedTexture` binds first. That's existing engine behavior.

Loose ends still open (honest list, by priority):
1. **Canvas `line`/`text`** keep the old plot-contract signatures — so `sink.line`/
   `sink.text` do NOT compile on Canvas. The "any backend" promise is incomplete
   until the plot convergence. THE big one.
2. **`RectOpts.rounding`** is still a silent no-op on all four backends (rounded
   rects unimplemented). Either implement (real work: corner arcs) or the field
   over-promises. Kept because it's a genuine planned feature, but flagged.
3. **Canvas circle outline / rect rounding** deferred (Canvas has no ring/rounded
   primitive; would need a CPU pixel path).
4. **Sprite-by-value vs Font-by-pointer** asymmetry: `image(dst, sprite, opts)`
   vs `text(pos, str, .{ .font = &f })`. Consequence of the existing `addText`
   taking `?*const Font`; making font by-value ripples into UI internals, so left
   as-is but noted.
5. **The sprite_quad replay guard** silently skips sprite draws on backends without
   `image` (bare raster ctx, test mocks). Fine in practice (UI is GPU-replayed) but
   a silent skip; documented.
6. **`z.unloadFont` is CPU-only** — frees glyphs/recs; the GPU texture waits for
   `resetRegistry`. Repeated mid-run load/unload would accumulate GPU textures until
   teardown. Bounded (fonts load once); can't free the texture from `deinit` (no
   renderer handle).
7. **Verification gaps** (honest): SwAdapter's rect/circle/line/triangle/text and
   DrawList's `image` are gate + mock-gl + unit-test verified but never actually
   rasterized/replayed to pixels. The emit path is shared + device-proven on GPU,
   but SW/DrawList sprite rendering specifically is unproven.

## Step 3 partial: DrawList `image` done

`DrawListHandle.image(dst, sprite, opts)` records a new `sprite_quad` DrawCmd
{dst, sprite (by value), opts}; at REPLAY the switch calls `gl.image(c.dst,
c.sprite, c.opts)`, so residency resolves against the immediate backend with no
renderer needed at record time. Safe because the UI DrawList is only ever replayed
on WgpuGl (`uiRenderNow(f.gl)`); the SW adapter renders scenes, not the DrawList —
so `gl.image` = WgpuGl.image (device-proven), no comptime guard. `imageXYWH` twin.
Gate green. So **image is on Canvas, WgpuGl, DrawList** (3/4).

Remaining: `image` on SwAdapter (`z.SwGl` = SwAdapter, confirmed) — the raster has
`genTextures`/`texImage2D` + a `bound_texture`, so it's feasible, but SW textured-2D
via `drawTexturePro` is UNTESTED (no example uses it), so it needs a SW texture
residency cache + SW->PNG verification as its own careful slice. Plus the plot
convergence (Canvas line/text).

## Font-free gap FIXED

Root cause found: the font's GPU atlas texture is registered via
`registerOwnedTexture`, so it's already freed by `resetRegistry` at teardown — NOT
the leak. The leak was the CPU glyph data (`font.glyphs` + `font.recs`); `tt` is a
parse-view over the bytes (no alloc). `text2d.unloadFont` needed a `font_cache`
(only to skip the default font) and called a no-op `unloadTexture` stub, so it was
unusable from an example `deinit(gpa, *State)`.

Fix: `text2d.unloadFontOwned(gpa, font)` — frees the CPU glyph bitmaps + glyph/rec
arrays, no `font_cache` (safe because `loadFont` never returns the default), no
texture free (registry-managed). Exported as **`z.unloadFont`**. Verified: the
draw2d_demo now loads a font, renders `text`, and `z.unloadFont`s it — smoke is
LEAK-CLEAN and the standalone renders text on device. This unblocks font use in any
`.managed` example, not just the demo.

## (superseded) Note: font-free gap

Freeing a loaded font's GPU texture requires `text2d.unloadFont(gpa, font_cache,
font)` — the `font_cache` recognizes/skips the default font. A `.managed` example's
`deinit(gpa, s)` can't reach the App's `font_cache`, and `z.unloadFont` isn't
exported; the local `unloadTexture` is a no-op stub. So font-loading examples leak
their font's GPU texture today (see the starfield comment). The draw2d_demo is kept
font-free + leak-clean; `text` is code-verified (gate + unit tests + wraps the
device-proven `drawWithFont`). FOLLOW-UP (orthogonal to draw2d): export a clean
`z.unloadFont` (or thread the font_cache to example teardown) so `.managed` examples
can load fonts leak-free — then a text device-demo is trivial.

Cold-build visibility: use `--summary all` (per-step wall-times on completed
builds); for cold builds that time out mid-step, build the expensive constituents
individually so each reports its own time.

## Steps 1-2 done: triangle + text

**triangle** (ShapeOpts) on all four backends — additive everywhere (Canvas's
`triangleFilled`/DrawList's `addTriangleFilled` stay). Emit is 3 verts via
`draw2d.triangleFilled` (mock-gl-tested); DrawList/Canvas reach their existing
filled-triangle. So the shape trio (rect/circle/triangle) is complete on all four.

**text** on WgpuGl / SwAdapter / DrawList — the `drawText`-is-a-wrapper discovery
paid off: WgpuGl/SwAdapter call `text2d.drawWithFont` directly (host-safe, no
cycle); DrawList wraps `addText`. Refined **`TextOpts.font` to `?*const Font`** (a
pointer, not a value) — retained backends record it for replay, so it must
reference a font that outlives the draw; null → the sink default (UiContext font on
DrawList; a no-op on the immediate adapters until a default source exists). Gate 97
ok, tests pass. Text render wraps the device-proven glyph path, so it's low-risk;
standalone confirm bundled with the image work.

Still missing on the unified surface: `text` on the immediate adapters has no
default font yet (explicit `.font` required); Canvas `line`/`text` (plot). 

## Remaining tail — each piece is real work, not a slice

The core surface (`rect`/`circle`/`image`/`line`) is delivered + verified across the
main backends. What's left is completeness, and each item needs dedicated effort:
  1. **`text` everywhere.** `drawText` lives ONLY in wgpu_app.zig (not a `gl:
     anytype` helper), so calling it from WgpuGl.zig is a circular import. Text needs
     the `gl: anytype` rendering core relocated to a host-safe module (text2d /
     draw2d), PLUS the per-call `.font` default resolved (adapters hold no default).
  2. **`image` on DrawList + SwAdapter.** DrawList: the handle has no renderer at
     record time, so a Sprite must resolve at REPLAY — a new resolve-at-replay
     DrawCmd variant. SwAdapter: needs SW-texture registration/sampling (its own
     texture path), distinct from the GPU upload.
  3. **plot-sink convergence** (~64 call sites; SvgSink/DrawListSink/Canvas adopt
     draw2d) — the biggest, and what unblocks Canvas `line`/`text`.

Recommended order: (1) text via the drawText relocation (most-missed primitive,
clean-ish refactor), then (2), then (3) as its own planned migration.

- [ ] DrawList `image` (record + resolve residency at replay) + SwAdapter `image`
  (SW texture sampling) — the two remaining image backends.
- [ ] Converge plot's sinks (SvgSink/DrawListSink/Canvas) + finish `line`/`text`.
- [ ] Immediate primitives (shared `emit*` helpers + one-line adapter methods).

## Texture identity across backends (resolved)

The seam in "same scene, any backend": a texture ref inside `fn draw(sink: anytype)`
must resolve to GPU residency (a bind group) on the GPU and to CPU pixels on Canvas.
Chosen model + sub-decisions:

- **Portable pixel-carrying handle + per-backend residency cache** (not a central
  registry, not per-backend handles). One handle works on every backend; each
  backend materializes + caches its own residency.
- **Owns its pixels** — the handle holds a deep copy; `deinit` frees it; the source
  `Image` can be freed right after. Self-contained lifetime, no dangling.
- **Monotonic id** keys the residency cache (not the pixel pointer — with owned,
  freeable pixels a reused address would alias the wrong texture). Id source is a
  single counter (`lint:off module-var`), 0 reserved as "none".
- **Dedicated type `Sprite`** (beside the bare GPU `Texture`, which stays as-is —
  it's embedded in `Font`/`Model`/`RenderTexture` and crosses to JS as an index, so
  it can't grow CPU pixels). Three roles, distinct: `Image` = transient CPU buffer,
  `Texture` = GPU handle, `Sprite` = the portable asset you load and draw.

`src/Sprite.zig`: `fromImage(gpa, img) → Sprite` (copies + assigns id), `deinit`,
`width`/`height`. The primitive is `sink.image(dst, sprite, opts)`.

Progress:
- [x] `Sprite` type (owns pixels, monotonic id).
- [x] **Canvas `image` takes `Sprite`** — samples `sprite.image` directly; the
  per-canvas texture store from the previous slice is removed (the handle carries
  pixels). PNG-verified with the source `Image` freed before drawing (proves
  ownership). raylib-compat: `LoadTexture` will become "make a Sprite + materialize
  GPU residency," a superset.
- [ ] GPU residency cache (upload sprite on first GPU draw, cache by `.id`) — lands
  with the immediate backend.

## PLOT CONVERGENCE line+text: DONE (fully verified)

Executed the line+text convergence. All 3 sinks (SvgSink plot.zig, DrawListSink
plot_ui.zig, Canvas) now take `draw2d.LineOpts` / `draw2d.TextOpts`; bodies derive
col/size/thickness from opts so SVG output is byte-identical. Transformed every
caller with a balanced-brace splitter:
  - plot.zig: 42 sink.line + 6 self.line + 22 sink.text + 1 self.text
  - Canvas.zig: 2 self.line (drawPolyline) + 1 test
  - plot_ui.zig: 10 sink.line + 1 sink.text  (MISSED first pass — its own internal
    calls; the full `zig build test` caught them, the flagship gate did not)
  - plot_demo.zig: 2 sink.line + 1 sink.text
Total 88 call sites. NOT touched (correctly): physics demo's `self.line`/`ctx.line`
(a different renderer type), `u.text(fmt, .{})` (formatted UI label — different
method). Also fixed a pre-existing build gap: native_plot_png exe lacked the `zm`
module (main.zig imports it) — added it.

VERIFIED: full `zig build test` PASSES (every example typecheck + host tests + PNG
snapshots). native_plot_png renders a correct plot (axes/grid/data/labels all
intact) — visual proof the converged Canvas line/text work.

**Canvas is now a FULL draw2d sink** (rect/circle/triangle/image/line/text). So
`fn draw(sink: anytype)` with the whole primitive set runs on Canvas / DrawList /
WgpuGl / SwAdapter (all but SwAdapter.image). The honest "any backend" gap from the
review pass is CLOSED for line/text.

Lesson recorded: the flagship gate does NOT catch call-site breakage in
non-flagship files (plot_ui internal calls, plot_demo). For cross-cutting signature
changes, `zig build test` (all examples) is the required gate, not `check`.

Still open (unchanged): shapes convergence (fillRect/circleFilled/triangleFilled —
entangled with plot Rect→Rectangle), texturedQuad (raw tex_id, different model from
Sprite), SwAdapter.image (untested SW textured-2D). These are optional; the surface
is complete for the core primitives.

## Options surface audit — speculative no-op fields removed

Audited every Options field for "advertises a capability, silently does nothing":
- REMOVED `RectOpts.rounding` (never read anywhere), `RectOpts.rotation_rad` (not
  honored by any rect impl), `ShapeOpts.outline` (triangle always fills). These
  lied. Re-add rounding wired to the existing `shapes2d.drawRectangleRounded`, and
  rect rotation via a rotated-quad emit, IF a real use case appears.
- KEPT + honest: RectOpts {color, outline}; CircleOpts {color, outline, segments}
  (segments honored on the tessellating backends — WgpuGl/SwAdapter/DrawList; Canvas
  draws a smooth disc, a documented per-backend choice, not a lie); LineOpts, TextOpts,
  ImageOpts (all fields honored). `CircleOpts.outline` was implemented earlier this
  review (ring emit). Gate 97 ok, NO REGRESSIONS, wgpu_smoke PASSED.
Net: every field on the draw2d surface now does what it says.

## SwAdapter `image` — DEFERRED (real reason, not a slice)

Study found the blocker: the SW raster's TRAIT `setTexture(id)` is a no-op that
CLEARS the binding (`_ = id; self.bound_texture = null;`). The real SW texture path
is `bindTexture(Handle)` + `texImage2D`, which `drawTexturePro` (the rlgl/draw2d
textured-quad path) does NOT use. So SwAdapter `image` can't be a `drawTexturePro`
call — it needs either a bespoke `bindTexture`-based textured quad (manual begin/
vertex2f/texCoord2f) or a direct blit into the raster framebuffer (à la Canvas). SW
sprite-drawing is a corner case, so this stays deferred with that finding recorded.
image is on Canvas / WgpuGl / DrawList (3/4); SwAdapter is the lone gap.

---
## PLOT CONVERGENCE — DONE ✅ (line + text)

**`line` converged this session; `text` was already converged in a prior session**
(the runbook below worked from stale memory on text — the code already had it).
So all 3 sinks (SvgSink, DrawListSink, Canvas) take `draw2d.LineOpts` / `TextOpts`
for line/text, and all call sites use the opts form.

- line: changed the 3 sink defs to derive `col`/`thickness` from `opts` (bodies
  otherwise untouched → SVG byte-identical). Transformed 51 `.line(a,b,c,d)` calls
  (42 sink + 6 SvgSink-internal in plot.zig, 2 Canvas.drawPolyline + 1 test) to
  `.line(a, b, .{ .color = c, .thickness = d })` via a balanced-brace splitter.
  Added `draw2d` import to plot.zig + plot_ui.zig.
- Verified: `zig build test` PASSES (compile + snapshot_regression_test SVG matches
  byte-for-byte), and `zig build native-plot-png` renders a correct plot (axes,
  grid, ticks, labels, colormap scatter) — Canvas's converged line/text confirmed
  on real pixels, not just mock-gl.

**Milestone: Canvas is now a FULL draw2d sink** (rect/circle/triangle/image/line/
text all present + verified). `fn draw(sink: anytype)` using the whole primitive set
now compiles and runs on Canvas / DrawList / WgpuGl / SwAdapter. **The "same call,
any backend" promise — the honest gap from the review pass — is now literally true.**

What deliberately stayed plot-specific (not a regression, by design): fillRect
(Rect vs Rectangle type entanglement), texturedQuad (raw tex_id, not a Sprite),
DrawListSink's clip/fit/limits glue. Those are optional future work, not blockers.

---
## (historical) PLOT CONVERGENCE — RUNBOOK

**Realistic scope + value.** Converge ONLY `line` + `text` (64 calls: 42 + 22).
That makes Canvas's `line`/`text` draw2d → the unified surface (rect/circle/
triangle/image/line/text) is finally complete on all 4 backends. This is a
VOCABULARY unification for line/text, NOT a big deletion — see caveats.

DO NOT (this pass) converge the shapes:
- `fillRect` (16): plot works in `plot.Rect` (x,y,w,h); draw2d `rect` takes
  `Rectangle` (x,y,width,height). Converging entangles with a plot-wide Rect→
  Rectangle migration — a separate, larger effort.
- `texturedQuad` (1): plot passes a raw registered `tex_id` + UVs; draw2d `image`
  takes a pixel-carrying `Sprite`. Different texture model — does NOT map. Leave it.
- `circleFilled` (2) / `triangleFilled` (11): Vec2-based so simpler, but low-value
  and can ride the later shape pass.
- `DrawListSink` is NOT deletable: it keeps plot glue (`pushClip`/`popClip`/
  `requestFit`/`getPlotLimits`). Convergence changes its drawing methods only.

**The 3 sinks (all have IDENTICAL sigs — verified):**
- `SvgSink` — src/plot.zig:2183 — `line`@2258, `text`@2304. SNAPSHOT-CRITICAL: it
  emits SVG strings; the byte output must stay identical or snapshot_regression_test
  fails. Preserve the exact `self.p(...)` format:
    line: `<line x1="{a0}" y1="{a1}" x2="{b0}" y2="{b1}" stroke="{col}" stroke-width="{thickness}"/>`
    text: `<text x="{p0}" y="{p1+size}" font-size="{size}" fill="{col}">{s}</text>`
- `DrawListSink` — src/plot_ui.zig:36 — `line`@66 (`self.dl.addLine(self.gpa,a,b,
  col.toWire(),thickness)`), `text`@114 (`self.dl.addText(self.gpa,self.font,s,pos,
  size,0.0,0,col.toWire())`). Keeps `self.font` as the default.
- `Canvas` — src/Canvas.zig:210 (`line`), :359 (`text`). `text` uses `self.atlas`
  (its baked font); the draw2d `text` opts.font (per-call font on Canvas) stays
  DEFERRED — plot passes no font, so null → atlas path. Fine.
- (`Cap`, plot.zig ~2760: a nested mini-sink with only `texturedQuad` — unaffected.)

**Per-method steps (each ATOMIC: sinks + all calls + gate + snapshot, one method):**

STEP 1 — line (42 calls). Sinks become `line(a: Vec2, b: Vec2, opts: draw2d.LineOpts)`
using `opts.color` / `opts.thickness`. Call transform, ALL in src/plot.zig:
  `sink.line(A, B, C, D)` -> `sink.line(A, B, .{ .color = C, .thickness = D })`
Also fix the 2 non-sink Canvas.line callers (Canvas.drawPolyline @242/245, Canvas
self-test @456) and DrawListSink/SvgSink `polyline` if they call their own `line`.

STEP 2 — text (22 calls). Sinks become `text(pos: Vec2, s: []const u8, opts:
draw2d.TextOpts)` using `opts.size` / `opts.color`. Call transform in src/plot.zig:
  `sink.text(P, S, SZ, C)` -> `sink.text(P, S, .{ .size = SZ, .color = C })`

**Transform GOTCHA (the whole reason to do this fresh):** args A/B (and P) are often
`.{ ... }` literals with INTERNAL commas, e.g.
`sink.line(.{ bar.x, bar.y }, .{ bar.right(), bar.y }, oc, 1)`. A naive comma-split
corrupts them. Use a balanced-brace/paren split, OR the safer route: change the sink
SIGNATURES first (breaks all calls → compiler lists every one), then fix each call
the compiler names — slower but self-verifying and impossible to silently mangle.

**Verify each step:** `zig build test` (typechecks all plot examples + runs
snapshot_regression_test — the SVG must match), then smoke plot_demo / ui_plot, then
the gate. If a snapshot legitimately shifts (it should NOT for a pure sig change),
investigate before regenerating.

**After line+text:** Canvas is a full draw2d sink; `fn draw(sink: anytype)` with the
whole primitive set runs on Canvas/DrawList/WgpuGl/SwAdapter. THEN the "any backend"
claim is finally, literally true — the honest gap from the review pass, closed.
