# zimr 3D plotting — integration plan (`implot3d`)

> **UPDATE (2026-06-19) — `wgpu_plot3d_gallery` example landed.** A tabbed
> gallery reproducing ImPlot3D's README plots, mirroring `wgpu_plot_demo`'s
> shell but driving `z.plot3d`. Six tabs: Line+Scatter (`plotLine` spring +
> `plotScatter` parabola), Surface (`pushColormap(.hot)` + radial `cos(r)` wave),
> Scatter (two clouds, circle/square), Sphere (`genSphere` wireframe via
> `fill_alpha=0`), Mesh (hand-rolled `genTorus` standing in for the un-bundled
> duck OBJ, solid fill), Markers (10 kinds × filled/open via transparent
> `marker_fill_color`, plus rotated `plotText`). Registered through `addWgpuApp`
> ("plot3d_gallery") + added to `wgpu_examples`. Builds green (RC=0), lint clean,
> standalone produced. GPU render unverified by me — Simon to screenshot. Not yet
> in `manifest.json` (gallery website). Readme already documents plot/plot3d.
>
> **Bugfix (surfaced by the gallery's Markers tab):** `Marker.count` was `11` but
> there are only 10 concrete markers (circle..asterisk); `nextMarker`'s auto-cycle
> `@enumFromInt(@mod(idx, count))` hit `@enumFromInt(10)` → `invalidEnumValue`
> panic on the 11th auto-marker item in a plot. Fixed to `10`. Also set
> `marker = .none` on the gallery's connector lines so they don't churn the
> auto-marker cycle (markers there come from `plotScatter`).
>
> **✅ RESOLVED (T13) — the RTT tiling is FIXED engine-side.** The fix: an app
> that does render-to-texture sets `.manages_own_frame = true` and runs its
> offscreen passes BEFORE `z.beginDrawing`; the swapchain then opens exactly
> once per frame and is never torn down mid-frame. Backed by an encoder split
> (`ensureFrame` creates the encoder before the first offscreen pass; begin/
> endTextureMode only reopen the screen when it was already open). Validated on
> Simon's device with `shader_effects` + `render_texture`: full scene, no tiling.
> The plot3d GPU surface below can now be resurrected with this pattern.
>
> **[historical] PHASE 4 BLOCKER (RTT compositing dead-end on mobile).** The GPU
> surface needs per-frame render-to-texture (dynamic/animated surface). Built the
> full RTT path + proved the pieces individually: `viewProjMatrixRT` camera (unit
> tested), `registerTexture` bridge (RT→draw-list id), and `addImage` compositing
> all WORK — a solid-red RT composites cleanly into the plot pane. BUT calling
> `beginTextureMode`/`endTextureMode` corrupts the whole frame on Simon's
> tile-based mobile GPU: the UI tiles into a faint repeating grid (frame
> feedback). Confirmed it's the RTT pass-switch itself, not the 3D content (red-
> only test tiles too) and not the call site (top-of-frame tiles too). ROOT
> CAUSE: `beginDrawing` opens the swapchain pass with a real CLEAR; RTT ends that
> pass mid-frame and `reopen2DPass` reopens it with `.clear=null` (LOAD). Ending+
> reopening the swapchain attachment EVERY frame is what this GPU can't do. The
> `wgpu_render_texture` example avoids it by rendering its RT ONCE (`if invalid`)
> — static content, one pass-switch ever. A dynamic surface re-switches every
> frame. This is an ENGINE-ARCHITECTURE limit: no way to render a dynamic
> offscreen pass BEFORE the main swapchain pass from inside `update`. The demo's
> GPU-surface path is REVERTED to the working CPU painter's surface (no tiling).
> Engine plumbing kept (re-exported, harmless): `registerTexture`,
> `beginMode3DMatrix`, `drawTriangle3D`, `restore2DState`, `viewProjMatrix(RT)`,
> `Cube3D.appendTriangle`. OPTIONS for resuming GPU surface: (A) engine: a
> pre-main offscreen-pass hook (render all RTs before `beginDrawing` opens the
> swapchain pass) — the "right" fix, needs device verification; (B) non-RTT:
> draw 3D in the main pass + transparent plot window + scissor 3D to the pane
> (no pass-switch); (C) keep CPU surface (already correct), ship, move on.
>
> **UPDATE — edge-hover highlight DONE (interaction parity complete).** Direction
> after the RTT dead-end was option 3: ship the CPU surface, move on. First Phase-5
> item landed: `renderPlotBorder` now brightens + thickens the 4 edges of the axis
> nearest the cursor while the plot is hovered (`hoveredAxis` = nearest of the 12
> screen-space edges → its axis group; `lerpColorU32(border, white, 0.6)`, width
> 2.0). Pure `hoveredAxis`/`distPointSegment` helpers with a shipped unit test
> ("hoveredAxis picks the box axis nearest the cursor"). Build GREEN, lint 0/288,
> all plot3d tests pass. This was the last interaction-parity gap. REMAINING Phase
> 5: `Context`-as-receiver (kill global `gctx`); `png_canvas` export; revisit GPU
> surface if/when the engine gains a pre-main offscreen-pass hook.
>
> **UPDATE — zero-globals refactor COMPLETE (`gctx` + `style_color_stack` + `win_scope` killed).**
> plot3d.zig now has **zero module-level mutable state** and **zero `lint:off
> module-var` escape hatches** (verified). Every public + internal entry point
> takes an explicit `ctx: *Context` first param (`p3.beginPlot(ctx, …)`,
> `p3.plotLine(ctx, …)`, etc.). The `im` draw/widget shim is a `ctx`-bound value:
> `const im: Im = ctx.im();` per fn, so `im.foo(...)` call sites stayed textually
> identical; `Im` carries `{ h: ui.Ui, ctx: *Context }` (the ctx is for per-frame
> shim state — the window scope formerly in a `var win_scope`). `currentPlot()`→
> `ctx.currentPlot()`, `getStyle()`→`getStyle(ctx)`, `style_color_stack`→
> `ctx.style_color_stack`, `win_scope`→`ctx.win_scope`. Deleted `gctx`,
> `plotCtx`, `setCurrentContext`, `getCurrentContext`. `createContext` no longer
> auto-sets any global; `destroyContext(ctx)`/`setUiHandle(ctx, ui)` are explicit.
> `getViewScale` was kept ctx-free by snapshotting `style.view_scale_factor` onto
> `Plot3D.view_scale_factor` (set in beginPlot; defaults 1.0 = Style default), so
> the matrix math + the 4 unit tests stay context-free. Demo + the 4 plot3d unit
> tests updated to pass `ctx`. Green: full build RC=0, 0/288 lint, 1186 tests pass,
> no leaks. `genSphere` reverted to pure geometry (no ctx) since it touches neither.
>

> + `src/plot_core.zig`, imports unified, exposed as `zimr.plot3d` / `zimr.plot_core`.
> **Phase 1 DONE** — both files compile clean against the real `ui.zig` + `zimrmath`
> + `shader_interface` graph and the whole `src/` tree is lint-clean.
> **Phase 2 (math migration) DONE** — the bespoke f64 geometry types are GONE.
> `Point3`/`Quat` are now `zm.Vec`/`zm.Quat` (f32, w-lane = 0; conversion-free with
> `zm.rotate`/`cross3`/`dot4`), `Range` is `zm.Range(f32)`, and `Box`/`Plane`/`Ray`
> are thin plot-domain aggregates over `zm.Vec` (zm has no AABB/plane/segment type).
> No new math types were introduced; all ~50 consumer sites moved to zm free-fns and
> native vector ops (`.add`→`+`, `.scale(s)`→`*splat(s)`, `.rotate(p)`→`rotate(q,p)`,
> `.inverse()`→`inverse(q)`, `.at(i)`→`[i]`, `.x/.y/.z`→`[0..3]`). Quaternion
> conventions were proven against zm's own test vectors: `A.mul(B)`→`qmul(B,A)`
> (args swap, since `qmul(a,b)==b⊗a`) and `fromAngleAxis(angle,axis)`→
> `quatFromAxisAngle(axis,angle)`. `plot_core.niceNum`/`orderOfMagnitude` now delegate
> to `zm.niceNum`/`zm.floori` (dropped the duplicate Heckbert + scalar-floor bug).
> Verified line-by-line under **`zig test` full-body analysis** (not lazy build-obj):
> 0 errors, lint-clean, `zig fmt` applied. Several LATENT bugs (the code had never
> been fully body-analyzed, as plot3d is unwired) were fixed: `ui.ButtonResult`→
> `ui.Ui.ButtonResult`, scalar `math.isNan`→`std.math.isNan` (zm's isNan is
> vector-only), `*Axis`→`*const Axis` through `*const Plot` paths.
> ⚠ Quaternion *visual* correctness can't be checked in-sandbox (no GPU/browser) —
> needs a screenshot pass once a demo target exists.
> **Phase 2.5 (the demo) DONE** — `examples/wgpu_plot3d_demo/` landed and is wired
> into build.zig (`addWgpuApp("plot3d_demo", …)` + the servable `wgpu_examples`
> roster). It drives line/scatter/surface with drag-orbit, so it runs the migrated
> quaternion compose path live. `zig build wgpu-plot3d-demo` is GREEN: compiles +
> links under the real wgpu backend, whole-tree lint passes (288 files, 0 issues),
> and the self-contained `index.html` (wasm embedded) is generated. Building it
> caught two classes of issue the earlier `zig test` harness could NOT see:
>   (a) a generic-function body miss — `GetterXYZ(T).at` still returned a Vec via
>       struct-init `.{ .x=…, .y=…, .z=… }`; `refAllDecls` never instantiates
>       generics, so only an actual `plotLine(f32, …)` call forced its analysis.
>       Fixed to `point3(…)`. A full sweep confirmed it was the ONLY such miss
>       (no bespoke `.add/.sub/.scale/.cross/.normalized/.dot/.mul/.rotate` calls
>       and no 3-field Vec struct-inits remain anywhere).
>   (b) two cross-file `dup-pub-fn` lint collisions, dormant while plot3d was
>       unwired: `plot_core.niceNum` vs `zm.niceNum` (resolved by DELETING the
>       redundant wrapper — plot3d now calls `zm.niceNum(f32,…)` directly like
>       plot.zig does) and `plot.sampleColormap` vs `plot3d.sampleColormap` (a
>       legitimate 2D/3D namespaced dual-API mirroring ImPlot — suppressed on both
>       defs with `// lint:off dup-pub-fn`, order-robust across lint rosters).
> **STILL UNVERIFIED: rotation looks right.** Open the demo and drag-orbit; if the
> axes/helix tumble coherently, the `qmul` arg-swap conventions are confirmed.
> **[CONFIRMED 2026-06-18 via screenshot — rotation orbits coherently; conventions good.]**
> **Phase 3 parity (partial):** `beginPlot` title and series `label_id` now honour
> the Dear ImGui label/ID convention — visible text is the part before `##`;
> `###id` seeds a stable ID so the label can change without resetting stored
> rotation/limits; an empty/`##`-leading series label registers no legend entry.
> Two file-scope helpers (`labelVisibleEnd`, `idSeed`) funnel it through the one
> ID/label site in `beginPlot` and `registerOrGetItem`. (Fixed the demo showing a
> literal `##scene` title.)
> **NEXT: Phases 3–5 below.**
> **Verification coverage:** the demo now also drives `plotMesh` (built-in cube),
> `plotTriangle`, and `plotQuad` behind a toggle — these generic bodies + the
> `GetterPoints`/`beginItemEx` instantiation were previously never analyzed (the
> same blind spot that hid the `GetterXYZ.at` struct-init bug). A real
> `zig build wgpu-plot3d-demo` now instantiates every public plot-type entry
> point; all compile clean, no further latent bugs. So the whole CPU plotting
> surface is build-verified under `wgpu=true`, not just the line/scatter/surface
> trio.
> **Gesture camera (demo):** the demo now orbits on one-finger / left-drag and
> zooms on two-finger pinch (or wheel), matching the helmet/raytracer examples.
> Implemented demo-side: `beginPlot(..., .{ .no_inputs = true })` disables the
> library's own (right-drag/wheel) handler, the demo keeps the view quaternion as
> its single source of truth and pushes it each frame via the existing public
> `setupBoxRotationQuat(q, false, .always)` + `getStyle().view_scale_factor`. Orbit
> is gated to the plot rect (via `getPlotRectPos/Size`) so the checkboxes don't
> spin the scene; orbit reuses the same `qmul(yaw, qmul(rot, pitch))` compose the
> library uses. FOLLOW-UP (library, deferred): plot3d's own `handleInput` still
> uses right-drag + wheel only — making it touch-native (left-drag orbit + pinch)
> needs touch fields on `ui.InputSnapshot` (it currently carries mouse only), a
> `ui.zig` change that would also give the 2D `plot.zig` pinch for free.
>
> **UPDATE — Phase 3 + interaction parity (library-native) DONE:**
> - Phase 3 shim trim: removed 10 dead/re-implemented `im` members (incl. the
>   hand-rolled FNV hash). The shim is now used decls only.
> - Input plumbing: `ui.InputSnapshot` gained `touch_count` + `touch_pos[2]`,
>   populated in `UiHost.begin` from the frame's `InputState`. (Also hands the 2D
>   `plot.zig` the data for free if it wants pinch later.)
> - plot3d `handleInput` rewritten and now TOUCH-NATIVE: orbit on one-finger /
>   left-drag (per-frame delta, gated by `held` so it only starts on the plot),
>   zoom on two-finger pinch OR wheel, and a synthesized double-click-to-reset
>   (rotation→initial + refit). NB this also *fixed a latent bug*: the old path
>   rotated on `isMouseDown(.right)`, which the shim hardcodes to false, so the
>   library's own orbit never actually worked — the earlier demo only moved
>   because it drove the camera itself. The demo now uses plain `beginPlot` (no
>   `no_inputs`, no bespoke camera code) and `setupAxesLimits(..., .once)` so zoom
>   persists.
> PAN now added too (screen-space `pan_offset`): two-finger drag on touch, or
> shift+left-drag on desktop; double-click reset clears it. Only per-axis/plane
> edge hover-highlight remains deferred from interaction parity.
>
> **REMAINING:** Phase 5 — `auto_col` sentinel → `?zm.Color`; per-frame OOM
> policy; `Context`-as-receiver; edge-hover; native `png_canvas` 3D export.
> Phase 4 — the GPU depth path (the headline quality leap).
>
> **UPDATE — `auto_col` sentinel retired.** The magic `w < 0` float sentinel is
> gone: `Spec` color fields and `Style.colors[]` are now `?Vec4` (`null` = auto),
> and `isColorAuto` is deleted. Resolution in `beginItem` reads the optionals and
> writes back concrete colors; renderers unwrap the resolved values. This is a
> representation-only change — the same `Vec4` values flow through, so colors are
> unchanged (verified by compile/lint; hues to be eyeballed). NOTE the deeper
> sub-task — collapsing the float `Vec4` color struct onto `zm.Color` — is the
> risky color-precision part and is intentionally NOT done (deferred; needs visual
> verification of output).
> STILL REMAINING: per-frame OOM policy (12 silent `catch {}` sites — behavior is
> already "drop this frame"; needs documenting/centralizing); `Context`-as-
> receiver; edge-hover; `png_canvas` export (needs a headless-ui or sink path —
> plot3d is coupled to `ui.DrawList`, so NOT free); Phase 4 GPU depth path.
>
> **UPDATE — per-frame OOM policy landed.** Added a documented `dropFrameOnOom`
> helper and routed all 11 transient-buffer appends (triangle batch, tick/legend/
> title/label text, style-override stack) through it. The policy: a growth alloc
> that fails drops the affected primitive/label for this frame only; it's rebuilt
> next frame, so transient OOM degrades gracefully instead of crashing. One
> deliberate, greppable decision instead of scattered silent `catch {}`. (The
> `bufPrint catch return` for the mouse-pos readout is a fixed-buffer case, not
> OOM — left as is.) Verified green.
> STILL REMAINING: `Context`-as-receiver; edge-hover; `png_canvas` export (needs a
> headless-ui or sink path — plot3d is coupled to `ui.DrawList`, so NOT free);
> Phase 4 GPU depth path (the headline).
>
> **UPDATE — Phase 4 down-payment: matched GPU camera landed + validated.** Added
> `viewProjMatrix(plot) zm.Mat` (+ `getViewProjMatrix()` for the current plot): a
> column-vector ortho view-projection (`clip = VP · vec4(ndc,1)`) that, rendered
> into a viewport set to the plot rect with WebGPU depth [0,1], maps geometry
> pixel-for-pixel onto the CPU axes overlay (`ndcToPixels`). Built the rotation
> from `rotate()` on the basis vectors, so it matches the CPU path *by
> construction* — no quat/matrix convention coupling. Derivation: viewport-mapping
> the clip output collapses to exactly `ndcToPixels` (verified algebraically AND
> by an executing unit test over 7 sample points incl. cube corners — 0 failed;
> w==1 exact; depth strictly inside (0,1) via a √‖ndc_scale‖·1.01 half-extent).
> This de-risks the HARDEST part of Phase 4 (camera alignment) and is reusable for
> any custom GPU overlay. The test was transient (Plot3D needs a `gpa`-bearing
> `init`, so it's built via `ctx.plots.getOrAddByKey`); a permanent version fits
> once Context-as-receiver makes plot construction clean.
>
> **FINDING — `destroyContext` leaks.** It only does `gpa.destroy(ctx)`; there is
> NO `Context.deinit`, so the plots `Pool`, every `Plot3D` (axis tickers,
> `draw_list`, item pools), colormap data, and the style-color stack all leak.
> Harmless when a context lives for the whole program (the normal path), but it's
> a real lifecycle leak and a prerequisite for the clean unit tests / parallel
> plots Context-as-receiver is meant to enable. NEXT: write `Context.deinit`
> (walk plots → `Plot3D.deinit` → axes/ticker/draw_list/items, + colormaps +
> stacks) and call it from `destroyContext`.
>
> PHASE 4 NEXT STEPS (now that the camera is proven): plumb a GPU render context
> (frame/pass/uploader) into plot3d beyond the `ui.Ui` overlay handle; prototype
> a depth-tested `draw3d` pass for ONE `plotSurface` fed by `viewProjMatrix`,
> composited under the CPU box/labels; keep painter's-algo as the no-GPU/PNG
> fallback. Match `draw3d`'s WGSL matrix layout (transpose if its shader expects
> column-major storage).
> STILL REMAINING: GPU render-context plumbing + depth pass (rest of Phase 4);
> `Context.deinit`; `Context`-as-receiver; edge-hover; `png_canvas` export.
>
> **UPDATE — `Context.deinit` landed; leak fixed; first unit tests shipped.**
> Wrote a full ownership-tree teardown: `Pool(T).deinit` (frees each pooled entry,
> calling `T.deinit(gpa)` when present, then the backing list+map), plus `deinit`
> on `Ticker`, `Axis`, `Legend`, `ItemGroup`, `Plot3D`, `ColormapData`, and
> `Context`; `destroyContext` now calls `ctx.deinit()` before `gpa.destroy`. (The
> module-global style-color stack is program-lifetime and intentionally left.)
> Shipped two permanent tests in plot3d.zig, both green under the testing
> allocator: "destroyContext frees everything (no leak)" and "viewProjMatrix
> reproduces ndcToPixels" (the alignment proof is now a permanent regression
> guard, not a throwaway). This unblocks the clean unit-testing the plan wanted.
> STILL REMAINING: GPU render-context plumbing + depth pass (rest of Phase 4);
> `Context`-as-receiver; edge-hover; `png_canvas` export.
>
> **UPDATE — Phase 4 GPU camera now in the REAL GPU convention + proven.** Last
> turn's `viewProjMatrix` was row-major + plot-rect-viewport (a clean reference
> but the WRONG convention for the GPU). Corrected after reading the engine:
> the 3D batch's WGSL does `clip = vp * vec4(p,1)` (column-vector M·v), zm is
> COLUMN-MAJOR (`Mat[i]` = column i), and `zm.mulMatVec`/the demos use that same
> convention. New signature `viewProjMatrix(plot, target_w, target_h) zm.Mat`:
> column-major, folds the FULL-framebuffer pixel→clip map into the matrix (the
> single shared 3D pass uses the whole-framebuffer viewport, not a per-plot one),
> rotation columns from `rotate()` (orientation matches CPU by construction),
> orthographic (w==1), WebGPU depth [0,1]. The shipped regression test now
> validates it through `zm.mulMatVec` — the EXACT arithmetic the GPU runs — over
> 7 sample points vs `ndcToPixels`: 0 failed. So the hardest, otherwise-
> un-self-verifiable part of Phase 4 (camera + convention) is locked in.
>
> ARCHITECTURE (confirmed by reading the engine):
> - The plot3d caller (`update(f: *z.Frame, s)`) already HAS the frame; it only
>   forwards `ui.Ui` via `setUiHandle`. 3D draws go through `f.gl: *WgpuGl`.
> - `beginMode3D(gl, cam)` builds `view_proj = mulMat(proj, view)` and calls
>   `app.cube3d.?.beginFrame3D(view_proj)` — the 3D batch is driven purely by that
>   matrix. Injection point: a `beginMode3DMatrix(gl, vp)` that calls
>   `beginFrame3D(vp)` directly with OUR `viewProjMatrix` (bypassing Camera3D).
> - SINGLE shared depth-tested pass on the swapchain (NOT a separate pass — the
>   window opted into a depth buffer). 3D flushes at `endMode3D`; 2D HUD drawn
>   after composites on top (its pipeline is compare=always). So plot fills go
>   GPU/depth-tested, the CPU box/labels overlay stays on top for free.
>
> PHASE 4 NEXT (the part only Simon's screenshots can verify):
> 1. Thread the frame/gl into plot3d (e.g. `setRenderHandle(f)` alongside
>    `setUiHandle`), exposing target size for `viewProjMatrix`.
> 2. Add `beginMode3DMatrix(gl, vp)` to wgpu_app.zig (refactor `beginMode3D` to
>    share the cube3d setup).
> 3. Find the Cube3D triangle/mesh append API (the shape helpers tessellate into
>    it — `drawSphereSubdivided` etc.) and push a `plotSurface` mesh into it.
> 4. In `endPlot` (or a GPU sub-phase), if a per-plot `gpu: bool` flag is set:
>    `beginMode3DMatrix(gl, viewProjMatrix(plot, tw, th))`, append the surface
>    tris, `endMode3D` — BEFORE the 2D overlay flushes. Default flag OFF so the
>    proven CPU painter's path stays the default + PNG fallback.
> 5. Prototype on ONE `plotSurface`; Simon screenshots to confirm pixel alignment
>    with the CPU axes overlay, then convert Mesh/Triangle/Quad.
> STILL REMAINING: steps 1–5 above (rest of Phase 4); `Context`-as-receiver;
> edge-hover; `png_canvas` export.
>
> **UPDATE — Phase 4 GPU surface PROTOTYPE landed (compiles green; awaiting a
> screenshot to verify pixels).** Engine API added: `Cube3D.appendTriangle`
> (flat-shaded raw tri into the batch), `wgpu_app.beginMode3DMatrix(gl, vp)`
> (drives the depth-tested batch with a custom matrix; `beginMode3D` refactored
> to call it), `wgpu_app.drawTriangle3D(gl, a, b, c, color)` — both re-exported
> from zimr. Demo wired: a "surface on GPU (depth-tested)" checkbox (`gpu_surface`,
> OFF by default) swaps the CPU painter's `plotSurface` for `drawSurfaceGpu`,
> which projects each grid quad's verts to NDC via `plotToNDCcur` and emits two
> `drawTriangle3D`s under `beginMode3DMatrix(getViewProjMatrix(tw,th))` …
> `endMode3D`. The library itself is UNTOUCHED — the prototype lives in the demo
> (per the plan's "prototype one plotSurface first"), so the working CPU path
> can't regress. tw/th = `f.window.screen_width/height` (logical px, same space
> as the plot rect).
>
> **FIX (black screen on toggle):** the demo window never opted into a depth
> buffer (`depth_format` was null), so the depth-tested 3D pipeline had no depth
> attachment → black frame. Added `.depth_format = .depth24_plus` to the demo
> window config (matches wgpu_models3d/cube3d). If still black after this, next
> suspect is 2D-state restore after the 3D flush → try `z.reopenOverlayPass(f.gl)`
> right after `endMode3D` (weigh vs the mobile-tiling note on extra passes).
>
> NEEDS SIMON'S SCREENSHOT (the part no sandbox check can cover). Toggle it on and
> look for, in priority order:
>  - ALIGNMENT: the GPU surface should sit pixel-for-pixel inside the CPU axes box
>    (camera is unit-test-proven, so if it's offset/scaled wrong the likely cause
>    is a logical-vs-physical pixel mismatch in tw/th).
>  - 2D OVERLAY INTACT: the axes box/labels/legend must still draw ON TOP. If they
>    vanish or corrupt after the 3D flush, the fix is `z.reopenOverlayPass(f.gl)`
>    right after `endMode3D` (restores the 2D renderer's pipeline/bind state).
>  - DEPTH/FACING: surface should be solid + depth-sorted (no painter's seams). If
>    triangles are missing from one side, the batch pipeline is culling — winding
>    in `drawSurfaceGpu` (currently a,b,d / a,d,c) or cull mode needs a tweak.
> Once confirmed, migrate the prototype into plot3d proper (a per-plot `gpu` flag
> in `plotSurface`/`endPlot`, threading the frame via `setRenderHandle`), then
> extend to Mesh/Triangle/Quad.
> STILL REMAINING: verify+migrate the GPU path into the library; Mesh/Tri/Quad
> GPU; `Context`-as-receiver; edge-hover; `png_canvas` export.


Plan for folding the uploaded `zimr-plot/implot3d.zig` (+ `plot_core.zig`,
`implot3d_demo.zig`) into zimr. Goal: a first-class 3D plotting library that
leans on `ui.zig` and `zimrmath.zig` as hard as possible and is genuinely the
best 3D plot system it can be on this backend — not a literal ImPlot3D transcription.

---

## 0. What we were handed (and its real state)

A pure-Zig port of **ImPlot3D** (`implot3d.zig`, ~4,000 lines, 98 public fns) on
top of zimr's `ui` + `zm`, with a shared `plot_core.zig` (color/colormap/tick)
and a 30-demo `implot3d_demo.zig`. It is **independent of the 2D `implot.zig`**
in the same zip — it imports only `zm`, `ui`, `plot_core`. So we can take the 3D
library WITHOUT the 11,800-line 2D `implot.zig`.

**Headline caveat (from its README, confirmed): it has never been through
`zig build`.** Treat every claim below as "compiles in principle."

### What I verified against zimr's *real* `ui.zig` / `zimrmath.zig`
The port was written against zimr's actual API, not a guess — fidelity is high:
- Every `im`-shim `ui.Ui` method exists: `getId`, `pushId`/`pushIdInt`/`popId`,
  `buttonBehavior`, `itemSize`, `itemAdd`, `isItemHovered`, `getCursorScreenPos`,
  `setCursorPos`, `calcTextSize`, `getContentRegionAvail`, `getWindowDrawList`,
  `drawListAllocator`.
- Types match: `ui.Id=u32`, `ui.ColorU32=u32`, `ui.Style`, `ui.InputSnapshot`,
  `ui.DrawList`, `ui.Color`, `ui.MouseButton`.
- The `DrawListAdapter` already maps to zimr's real method names (`addRectOutline`,
  `addPolygon`, `addQuadFilled`, `addTexturedQuad`, `addCircle`,
  `pushClipRect`/`popClipRect`) — not ImGui's. All exist on `ui.DrawList`.
- `addText` matches (`alloc, font, s, pos, size, spacing, line_spacing:i32, col`);
  the `ui.Style` fields it reads (`font`, `font_size`, `font_spacing`,
  `line_spacing`, `frame_padding`, `text/window_bg/frame_bg/border/popup_bg/
  button_hovered/button_active`) all exist.
- Every `zm.Color` method it uses exists: `toWire`/`fromWire`/`toVec`/`fromVec`/
  `rgb`/`init`/`hex`/`fromFloats`/`fromHSV`.

So the "never compiled" gap is **small-to-moderate**: a real first-build pass,
lint conformance, and a handful of residual signature/idiom fixups — not a rewrite.

### Architecture recap (what we're adopting)
- **CPU projection, no GPU camera.** plot-space → per-axis normalize to
  NDC[-0.5,0.5]·scale (with log/symlog/custom forward transforms) → rotate by a
  quaternion → orthographic flatten + y-invert + center offset → screen `Vec2`.
  Forward and inverse exposed (`plotToPixels`, `pixelsToPlotRay/Plane` for picking).
- **Painter's-algorithm triangle batch** (`DrawList3D`): accumulate
  `(a,b,c,col,z)`, `std.mem.sort` far→near every frame, emit flat
  `addTriangleFilled`. Lines/markers/text draw straight to `ui.DrawList` on top.
- **`im` shim**: one private struct funnels ALL backend calls; the library body
  never touches `ui.*`/`zm.*` directly. This is the seam we exploit.
- Global singleton `Context` (`gctx`) + per-frame `setUiHandle(ui)`.

---

## 1. Relationship to zimr's existing `plot.zig` (2D)

zimr already has `plot.zig` + `plot_ui.zig` (our ImPlot-parity 2D library, ~34
demo tabs, near feature-complete). The zip's 2D `implot.zig` is a *parallel*,
larger, uncompiled 2D port. **Decision for this work: integrate 3D only.** Keep
`plot.zig` as the 2D library; bring in `implot3d` + `plot_core` for 3D. Whether
to later consolidate 2D onto `implot.zig` is a separate strategic question and
explicitly out of scope here. (`implot3d` does not need `implot.zig`.)

Naming: land it as `src/plot3d.zig` (drop the `implot3d` name to match zimr's
`plot.zig`), exposed as `zimr.plot3d`.

---

## 2. The plan, phased

### Phase 0 — land + wire (mechanical)
- Copy `implot3d.zig` → `src/plot3d.zig`, `plot_core.zig` → `src/plot_core.zig`,
  `implot3d_demo.zig` → `examples/wgpu_plot3d_demo/…`.
- Unify the import-name asymmetry the README flags: everything imports `ui`
  (zimr siblings are `@import("ui.zig")`), `zm`, `plot_core` consistently. In a
  single-module tree these are sibling `@import("X.zig")`, so rewrite
  `@import("ui")`/`@import("plot_core")` → `@import("ui.zig")`/`"plot_core.zig"`.
- Add `pub const plot3d = @import("plot3d.zig");` to `zimr.zig`.

### Phase 1 — first compile pass (highest leverage; do this before anything else)
The README is right that this flushes the unknowns. Reconcile against real
`ui.zig`/`zm` until `plot3d.zig` + `plot_core.zig` compile host + wasm:
- Residual signature/idiom fixups (likely: `@ptrCast` stride slicing,
  `bufPrintZ` label lifetimes, the `@bitCast` flag paths, `std.ArrayList`
  unmanaged calls, `@Vector` component access).
- **Lint conformance** to zimr's `zimrlint` rules (typed locals, braced ifs,
  `no-qualified-zm` → bind `const X = zm.X` at file scope, `[std-math]` →
  route through `zm` not `std.math`, multiline 5+-param fns, `@round`→int
  directly). `plot_core.niceNum/orderOfMagnitude` use `std.math.*` — must move
  to `zm` (it has `log10`/`floor`/`pow`) or be flagged.
- Get `implot3d_demo` compiling as a host test first (cheapest signal), then a
  wasm standalone.

### Phase 2 — use `zimrmath` maximally (the "best math" pass)
The port rolls its **own f64 `Point3`, `Quat`, `Plane3D`, `Ray`, `Box`** (~340
lines) with `fromAngleAxis`/`mul`/`rotate`/`normalize`. `zimrmath` already has
`Quat (=Vec @Vector(4,f32))`, `quatFromAxisAngle`, `quatFromMat`, quat multiply,
`rotate`, `Vec/Vec2/Vec3`, `Mat`, `matFromQuat`, ortho/proj builders.
- Replace the bespoke quaternion + vector math with `zm.Quat`/`zm.Vec`/`zm.Mat`.
  Screen-space visualization tolerates f32 fully; this deletes ~140 lines, gains
  SIMD, and is exactly the "use zimrmath" mandate. Keep a thin `Point3`/`Box`
  wrapper only where axis-range arithmetic genuinely wants f64 dynamic range
  (consider `f64` only for `Range`/axis limits; do projection in f32 via `zm`).
- Build the rotation as a `zm.Quat`; derive the screen transform with `zm` so
  the SAME matrix can drive the GPU path in Phase 4.
- Fold `plot_core` tick math (`niceNum`, `orderOfMagnitude`) onto `zm` and the
  color helpers onto `zm.Color` (they already pivot through it) — or move
  `plot_core` into `ui.zig`/`zimrmath` wholesale as the README suggests, so there
  is no third small module.

### Phase 3 — use `ui.zig` maximally
- The library already routes 100% through `ui` via the `im` shim — good. Trim
  the shim to thin pass-throughs; delete any re-implementation where `ui` already
  has the primitive.
- The demo ships its own `ig` widget shim; replace it with direct `ui.Ui` calls
  (or zimr's real widget API) so there's one widget vocabulary, not two.
- Reuse `ui`'s clip stack, ID stack, hit-testing, and `DrawList` directly.

### Phase 4 — make the 3D rendering the best it can be (the real upgrade)
ImPlot3D's painter's algorithm is a workaround for Dear ImGui having **no depth
buffer**. zimr is not so limited: `draw3d.zig` is a real depth-tested WebGPU 3D
engine (camera, `genMeshCube/Sphere/Heightmap`, `uploadMesh`, `loadModelFromMesh`,
`drawModel`, `depth24_plus`, cull-none + depth-sorted pipelines). So:
- **Add an optional GPU render path for `plotSurface`/`plotMesh`/`plotTriangle`/
  `plotQuad`.** Feed `draw3d`'s camera a view-projection matrix built (via `zm`)
  from the SAME plot quaternion + orthographic scale used by the CPU projection,
  so GPU-rasterized geometry aligns pixel-for-pixel with the CPU-projected axes.
  Result: correct per-pixel occlusion (no painter's-algorithm artifacts on
  intersecting/large surfaces), GPU fill, and **no per-frame O(n log n) CPU
  sort**. Keep the CPU `ui.DrawList` overlay (box, grid, ticks, legend, scatter
  markers, text, line plots) composited on top — exactly the layering ImPlot3D
  already assumes.
- Keep the painter's-algorithm path as the fallback for the no-GPU native PNG
  export route (`png_canvas`) and for small triangle counts.
- Then the deferred perf wins still worth doing on the CPU path: batch uniform
  line strips into one `addPolyline`; range-cull/decimate huge series before
  transform; cache the triangle sort when the quaternion is unchanged.
- This phase is the headline "best it can be" item and the main deviation from a
  straight port; it depends on Phases 1–2 landing first.

### Phase 5 — correctness, parity, polish
- Retire the `auto_col` magic float sentinel (`w=-1`) → `?zm.Color` (`null` =
  auto). Removes the bespoke float color struct; ~touch many sites (do it once
  the compiler is in the loop).
- `Context`-as-receiver (`ctx.beginPlot(...)`) to kill the mutable global
  singleton → enables independent/parallel plots and unit tests.
- Interaction parity the draft omits: pan/translation, double-click reset,
  per-axis/plane edge hover highlight, and a real double-click edge (zimr's
  `InputSnapshot` has no double-click — add one or synthesize).
- Stop swallowing allocation failures silently; adopt one documented per-frame
  OOM policy.
- Deliverables to prove it: a wasm `wgpu_plot3d_demo` tab set wired like
  `wgpu_plot_demo`, AND a native pure-Zig `png_canvas` 3D export example
  (surface/scatter to PNG) — the CPU path makes this free.

---

## 3. Sequencing, risk, what to check first
1. **Compile `plot_core` + `plot3d` first** (Phase 0–1). Everything else is blind
   until the type checker has run. Expect the bulk of surprises here; it's bounded.
2. The `zm`-math migration (Phase 2) is mechanical once compiling and removes code.
3. The GPU path (Phase 4) is the only architecturally novel piece; prototype the
   matched-camera alignment on a single `plotSurface` before converting the rest.
4. Lowest risk / highest immediate value: Phases 0–2 give a compiling, lint-clean,
   zimrmath-backed CPU 3D plotter with the full ImPlot3D API and demo. Phase 4 is
   the quality leap; Phase 5 is parity/polish.

## 4. Decisions for Simon
- **2D consolidation**: leave `plot.zig` as the 2D lib (recommended) vs. later
  adopt the zip's `implot.zig`? (Out of scope now; flagging.)
- **GPU vs CPU 3D default**: default `plotSurface`/`plotMesh` to the GPU
  depth-buffered path (best quality) with CPU fallback for native PNG, or keep CPU
  default and GPU opt-in? (Recommend GPU default in-browser, CPU for `png_canvas`.)
- **f64 vs f32 projection**: drop to f32 via `zm` everywhere (recommended;
  simpler, SIMD, fine for pixels) vs. keep f64 for axis ranges only?

## RTT migration: NO custom-renderer exception (T13 — corrected T13b)

CORRECTION: the helmet_sw black was NOT a custom-renderer offscreen-first
problem. It was a self-inflicted infinite recursion in `enterFrame2D`/
`leaveFrame2D` (a regex during the frame_phase consolidation replaced the
assignment INSIDE the helper bodies with a call to themselves), which crashed
EVERY example on the shared beginDrawing path. Once fixed, helmet_sw migrates
to offscreen-first cleanly (custom pbr3d.drawInApp included), as do the UI-
coupled examples. Lesson: debug-build + console FIRST for silent black; never
regex-replace a pattern that appears in the helper you just defined.

### [superseded] earlier (wrong) hypothesis

Most RTT examples migrate cleanly to offscreen-first (`manages_own_frame` + RTT
before `beginDrawing`): the ones whose offscreen pass uses the 2D renderer
(`beginMode3D`, `drawRectangle`, `drawTextureRec`, etc.) — split_screen,
render_texture, trails, text_on_texture, recursive_hud, texture_readback,
pipeline_rendertarget, pipeline_postprocess, lines_drawing all work.

BUT `helmet_sw` went BLACK (whole screen, even text) when migrated. Its RTT
uses a CUSTOM renderer — `s.renderer.drawInApp` (pbr3d.Renderer, draw3d.zig
~5621), which does `self.pass = gl.pass.*` (copies the live pass) + its own
pipeline/bind-groups — AND it renders THREE targets (CPU software raster +
GPU RTT + comptime inset) with `sw_fb.update`/`present` before the composite.
Reverted to legacy for now (visible, tiles on Simon's GPU). Something in the
custom-renderer-RTT + multi-framebuffer + offscreen-first interaction breaks
the SCREEN pass (not just the RTT — the 2D text also vanishes). NEEDS focused
investigation; likely candidates: `drawInApp`'s `gl.pass.*` copy relies on
`beginDrawing` having init'd `app.gl` first, or a batch/ortho-ring state issue
when the custom renderer runs before the screen opens.
Suspect the same risk for `pipeline_bloom` (multi-pass custom pipelines) and
`pipeline_msaa` (custom MSAA resolve pass) — treat those as custom-renderer
RTTs too, migrate/verify individually.
