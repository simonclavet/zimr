# zimr plotting — plan & status (`plot.zig` + `plot_ui.zig`)

Goal: **full ImPlot feature parity** in our own lean library — a `zm`-only
rendering core plus a `ui` adapter — while staying clean, easy to use, and
Zig-idiomatic. `plotref2/zimr-plot/` (the big port) is reference only; what
ships is `plot.zig` + `plot_ui.zig`.

## Architecture (two layers)
- **`src/plot.zig`** — rendering core, no UI/input. Draws over a duck-typed
  *sink* (`fillRect/line/polyline/circleFilled/triangleFilled/text/pushClip/
  popClip`). Owns `Axis` (linear/log10/time transforms), `Ticker`, `Plot`
  (layout/fit/frame/grid/ticks/labels/title/legend), the `plot*` renderers,
  `SvgSink` (host PNG/SVG snapshots), and the colormap/histogram kit. Pure and
  testable; verified headlessly via SvgSink → cairosvg.
- **`src/plot_ui.zig`** — the *easy* layer. `DrawListSink` (over `ui.DrawList`),
  `PlotState` (persistent view + interaction state), `Series` + `Options`, and
  one entry point: **`show(u, &state, size, series, opts)`**. Owns interaction
  (pan / wheel / pinch / double-tap-fit / readout), drag tools, box-select,
  subplots. This is what app code uses.
- **`src/zimrmath.zig`** — shared kit: `Range(T)`, `remap`, `niceNum`,
  `log10`/`exp10`, rich `Color` (always extend here, never hand-roll color).

Mental model: **`show` + `Series.<kind>(...)` is the 95% path.** Drop to the
`Plot` + sink core only for custom/host rendering.

## ImPlot parity checklist
Legend: [x] done · [~] partial · [ ] todo. Names reference ImPlot's API.

### Series / plotters
- [x] Line, [x] Scatter, [x] Stairs, [x] Stems
- [x] Bars — vertical + horizontal (`BarsSpec.horizontal`)
- [x] Bar groups — clustered + stacked (`plotBarGroups`)
- [x] Shaded — to-baseline (`plotShaded`) + between two lines (`plotShadedBetween`)
- [x] Error bars — symmetric + asymmetric
- [x] Infinite lines (vertical + horizontal)
- [x] Heatmap (colormapped grid) — [ ] per-cell value labels
- [x] Histogram + 2D histogram (pure binning helpers)
- [x] Text at data coords, [x] annotation bubble, [x] tagX/tagY
- [ ] Pie chart (`plotPieChart`)
- [ ] Digital signal (`plotDigital`)
- [x] Image in plot space (`plotImage` + sink `texturedQuad`)
- [ ] Bubbles (size-encoded scatter)
- [ ] Dummy (legend-only entry, no data)
- [ ] Candlestick helper (ImPlot ships this demo-only; provide a helper)
- [ ] Bar value labels

### Markers
- [x] Full 10: circle, square, diamond, up/down/left/right, plus, cross, asterisk

### Axes & scales
- [x] Linear, [x] log10, [x] **time** (calendar ticks; UTC/24h)
- [x] Inverted axis, [x] axis labels, [x] minor ticks/gridlines, [x] auto-fit
- [x] Secondary Y (**y2**) + per-series `axis` assignment
- [x] **Symlog** (`Scale.symlog` + `Options.x/y_symlog` + `linthresh`)
- [x] **Custom transform** (`Scale.custom` + `Transform` fwd/inv; `Options.x/y_transform`)
- [x] **Axis constraints** (`AxisConstraints`: edge min/max + span_min/max; clamped in show())
- [ ] **Custom ticks** (explicit positions/labels) + **custom number format**
- [ ] More axes: X2/X3, Y3 (have X, Y, Y2)
- [ ] Equal/locked aspect
- [ ] Programmatic fit API (fit-on-demand, set-limits cond)
- [ ] Time options: local time, ISO-8601, 12-hour
- [x] Zoom correct in nonlinear space — `Axis.zoomedRange` zooms in layout space
      (unifies linear/log/symlog/time/custom)
- [~] Linked axes — works by sharing a `DataRange`; no helper yet

### Interaction
- [x] Pan, wheel-zoom, pinch-zoom, double-tap-fit, nearest-sample readout
- [x] Drag tools: `dragPoint`, `dragLineX`, `dragLineY`, **`dragRect`** (move + resize)
- [x] Box-select (rubber-band) + query (report region)
- [x] Box-select → zoom-to-region (`Options.box_zoom`; double-tap re-fits)
- [x] Crosshairs + mouse-position text (Query demo, built on the query API)
- [ ] Per-axis drag-to-scale; context menu; configurable input map

### Legend
- [x] 4-corner location (`legend_location`)
- [x] Hide-on-click (dimmed swatch)
- [x] Solo-on-click (double-tap a legend entry), [x] horizontal layout
      (Options.legend_horizontal). [ ] hover-highlight, outside placement,
      drag-to-move, sort, style-accurate swatches

### Styling & color
- [x] 16 ImPlot colormaps + `sampleColormap` + `drawColormapBar`
- [x] Per-series color + 8-color `autoColor` palette
- [ ] **StyleVar/StyleColor stack** (weights, sizes, alpha, themable colors)
- [ ] Colormap widgets — esp. **`ColormapScale`** (labeled colorbar beside heatmap)

### Layout
- [x] **Subplots** grid (`beginSubplots`/`cellAt`/`finish`)
- [ ] Aligned plots (`beginAlignedPlots`)
- [ ] Subplot shared/linked axes, per-cell titles, resize splitters

### Data handling
- [ ] Stride + offset (struct-of-arrays input)
- [x] implicit-x (empty `xs` => x = sample index; line family + fit +
      readout). [ ] custom getters (`*G`), [ ] stride/offset
- [x] NaN handling (gap the line) — `plot.missing` sentinel; line/scatter/
      stairs/stems/shaded skip non-finite samples. [ ] realtime ring-buffer helper

### Query / integration
- [x] Query API on PlotState: getPlotLimits, getPlotMousePos, plotToPixels,
      pixelsToPlot, plotToPixels2, plotArea, isInside, getSelection
- [ ] Drag-and-drop source/target (needs `ui` DnD; parity-only)
- [x] Host SVG/PNG snapshot path (verification)

## API ergonomics & Zig-idiomatic principles
Standards every addition must meet (and a cleanup pass to bring existing API up):
1. **Options-struct, not positional args.** New behavior is a field on `Options`
   / a `*Spec` with a sane default, never a new positional parameter.
2. **Designated struct literals are the API — no fluent/builder chains.**
   Keep `.{ .kind = .line, .xs = …, .ys = … }`; that's idiomatic Zig and the
   thing app code already reads cleanly. Make the common cases *short* via good
   defaults (e.g. `.scatter` draws markers with zero extra config), not via
   setter methods or `Series.line(…)` wrappers. Builder/fluent chains
   (`x.color(c).label(s)`) are explicitly out — they trade clarity for keystrokes.
   If kind→field pairing ever becomes error-prone enough to warrant type
   enforcement, *evaluate* a `union(enum)` payload — but only adopt it if it
   doesn't add call-site nesting.
3. **No allocations in the hot path.** Renderers take caller buffers; binning
   helpers are pure. Keep it.
4. **Duck-typed `sink: anytype`** for renderers; never hard-depend on `ui`.
5. **Exclusive choices = enums; independent flags = bools/packed struct.**
6. **No C-isms.** Fold `drawLegendEx` → `drawLegend(sink, entries, .{ ... })`;
   no `Ex`/Hungarian suffixes. Consistent `plot*` verb + `*Spec` noun naming.
7. **Color via `zm.Color`** (`rgbHex`/`hex`/`lerp`/`alpha`); add a small named
   `palette` so demos stop spelling `.{ .r=…,.g=…,.b=…,.a=255 }`.
8. **Doc comment on every `pub`**, one line of intent + units.

## Gap-closing roadmap (next turns, in order)
Each turn: implement in core → host-PNG verify where possible → wire into
`plot_ui` (Options/Series) → add a demo tab → fmt+lint+build → zip+present.

- ~~T10 — Scales II~~ **DONE**: symlog + custom transform + transform-space
  zoom (`Axis.toLinear`/`fromLinear`/`zoomedRange` unify all scales). assertf
  guards added (symlog linthresh>0, custom needs transform, heatmap/bargroups/
  errorbars length checks). Symlog demo tab. *(next: T11 axis config)*
- **T11 — Axis config (mostly DONE):** constraints + custom ticks + custom
  number format + programmatic fit shipped (AxisCfg demo tab). *Remaining:* constraints (limit + zoom-span clamp in interaction);
  custom ticks (explicit values/labels); custom number format
  (auto/fixed/scientific/percent/SI); programmatic fit; equal/locked aspect.
- **T12 — Ergonomics pass (no OOP/builders):** make literals stay short via
  defaults (scatter auto-markers, sane spec defaults); add a `palette` of named
  colors to kill `.{ .r=…,.g=…,.b=… }` at call sites; fold `drawLegendEx` into
  `drawLegend(…, .{ … })`; naming + doc-comment audit. Designated struct
  literals remain the API — no constructor/setter methods added.
- **T13 — Easy renderers:** pie, digital, bubbles, dummy, image, candlestick
  helper, heatmap cell labels + bar labels. Host-PNG verify each.
- **T14 — Multiple axes:** generalize `{x,y,y2}` → `x[3]`/`y[3]` with enabled
  flags + per-series axis index; keep `show` ergonomic. Demo: 3-axis tab.
- **T15 — Input matrix:** stride/offset, `*G` getters, implicit-x, NaN gaps,
  realtime ring-buffer helper.
- **T16 — Styling system:** `Style` (weights/sizes/alpha/colors) with push/pop;
  themable cols; `ColormapScale` colorbar widget.
- **T17 — Interaction/query:** box-select→zoom, crosshairs, mouse-text, public
  query API (`getPlotLimits`/`getPlotMousePos`/`getSelection`/`plotToPixels`),
  per-axis drag.
- **T18 — Legend/layout polish:** solo, hover-highlight, horizontal/outside,
  styled swatches; aligned plots; subplot linked axes + titles.
- **T19 — Integration (optional, parity-only):** drag-drop, configurable input
  map, context menu — only if `ui` exposes the primitives; otherwise document
  as out-of-scope for a lean lib.

After T18 the library is feature-complete on everything that matters for a
standalone plotting lib; T19 items are ImGui-integration niceties.

## The demo example
`examples/wgpu_plot_demo/` — growing showcase, one tab per feature, reviewable
on a phone. Tabs are a wrapping multi-row **selectable grid** (the single-row
TabBar overflowed past ~12 tabs). Current 19 tabs: Lines, Drag, Markers,
Shaded, Stems, InfLine, ErrBars, Annot, Heatmap, Histo, Hist2D, Groups, Band,
HBars, Dual, Subplots, Rect, Select, Time, Symlog, AxisCfg, Equal, Pie, Bubbles, Candles, Digital, HeatLbl, DualX, Theme, Gaps, Query, BoxZoom, Legend, Image (34 tabs). Build:
`zig build wgpu-plot-demo-standalone -Dmode=release` →
`zig-out/standalone/wgpu_plot_demo.html`.

## Notes / gotchas
- Native PNG export (`png_canvas.zig`, `examples/native_plot_png`, `zig build
  native-plot-png`): pure-Zig, native, anti-aliased 2D surface -> PNG with ZERO
  third party. Goal was ergonomics: a small native program that outputs a
  publication-quality PNG. `Canvas.init(gpa,w,h,.{.ss=4,.background})` ->
  draw -> `savePng(io, path)`. The Canvas IS a drop-in `plot` sink (same method set:
  fillRect/line/polyline/circleFilled/triangleFilled/text/pushClip/popClip/
  texturedQuad), so the same plot core that runs in the browser renders to a
  file unchanged (no ui/GPU/wasm). Exposed as `zimr.Canvas`.
  ARCHITECTURE — "do all 3" synthesis of the brainstorm options:
    (1) imageDraw* primitives + codecs.png encoder = the backend (all pre-
        existing zimr CPU code; `exportImageToMemory(img,".png")`).
    (3) anti-aliasing via SUPERSAMPLING (z2d-inspired, but z2d is MPL-2.0 so
        inspiration only, not vendored): render at ss x into a big RGBA8 buffer
        with the aliased imageDraw*, then premultiplied box-downsample on
        resolve(). ss=4 gives crisp curves + text. Truetype glyphs are already
        coverage-AA; SSAA compounds it. No per-primitive analytic AA needed.
    (2) rlsw EVALUATED and REJECTED as the backend: it's a GL-style aliased
        triangle rasterizer (Vertex PCT, gradients, framebuffer, readPixels) with
        no native 2D AA and heavier setup (vertex submission, ECS pools). SSAA
        over imageDraw* dominates it for 2D figures; rlsw stays the 3D/shader
        path. Documented so the choice isn't re-litigated.
  TEXT on a no-GPU native target: `getFontDefault` and `loadFontRaylibBitmap` are
  wasm-only (return zero font on host), and `loadFontFromMemory` HARD-FAILS
  (cpuAtlasTextureId()==0 -> error.GpuUploadFailed). So `useFont` builds the CPU
  glyph path itself: `truetype.loadFontFromTtf` + `text2d.bakeFontAtlas` (pure
  Zig), then blits each glyph straight from the packed `atlas.image[recs[idx]]`
  via `imageDraw(...tint)` (bakeFontAtlas does NOT retain per-glyph .image, so we
  source the atlas, mirroring imageDrawTextWithFont's internals). Skip zero-size
  glyphs (space) — a 0-width rec divides-by-zero in imageDraw and NaN->int panics.
  imageDraw BUGFIX (image.zig ~1552): nearest-neighbor sampling produced a
  NEGATIVE source coord on fractional-origin blits (first row/col has t<0; a glyph
  at the atlas's left/top edge then sampled sx/sy<0 -> @intCast panic). Now
  clamps `sxc/syc = clamp(sx/sy, 0, dim-1)`. Benefits text + drawSkybox + any
  scaled imageDraw caller.
  BUILD: the native exe gets its OWN host-target `zimr` module instance (disjoint
  compile graph, like the mesh_bake codecs module) — the wasm `zimr_mod` carries
  generated-shader build deps, but the CPU PNG path needs none, so a separate
  module keeps it a fast, GPU-free native build. IO THREADING (this Zig dev
  build): `std.fs.cwd`/`createFileAbsolute` are GONE (fs moved to std.Io); the
  app picks the impl in `main` (only `std.Io.Threaded` today) and threads `io`
  down like the allocator — DON'T spin up a Threaded inside leaf/library fns.
  zimr now follows this: `Canvas.savePng(io, path)`, `ui.renderToPng(gpa, io,
  ...)`, `ui.loadPng(gpa, io, ...)`, `ui.snapshotPng(gpa, io, ...)` all take
  `io`; example/test `main`s create one `std.Io.Threaded` and pass `io.io()`.
  Idiom: `var t: std.Io.Threaded = .init(gpa,.{}); defer t.deinit(); const io:
  std.Io = t.io(); std.Io.Dir.cwd().writeFile(io, .{.sub_path,.data})`. Stdout
  the new way: `std.Io.File.stdout().writeStreamingAll(io, bytes)` (tools/
  plot_svg_demo.zig) — `std.posix.write(1,...)` retired.

- Image-in-plot (T13, last renderer): sink gained texturedQuad(dst, tex_id,
  uv0, uv1, tint). DrawListSink wraps ui addTexturedQuad; SvgSink draws a
  placeholder (tinted rect + outline + diagonals + img#<id> label) so geometry
  is host-verifiable. plot.plotImage(sink, tex_id, x0,y0,x1,y1, ImageSpec)
  projects the data rect (top edge -> larger data-y). plot_ui: SeriesKind.image
  + Series.tex_id/img_bounds[4]/image; dispatch + fit (expands bounds like
  heatmap). The draw-list path needs a REGISTERED u32 id: gl.renderer
  .registerTexture(loadTextureFromImage(f.gl, img)) -> id (WgpuTexture has no
  bare id). Demo Image tab makes a checkerboard in initState. Geometry locked
  by a capture-sink test (plotImage maps data bounds to a pixel rect).
- Legend polish: LegendLayout gained horizontal/cell_w/pad_x; hit() branches on
  orientation. legendLayout(entries, location, horizontal); drawLegendEx draws a
  single uniform-cell row when horizontal. Options.legend_horizontal threads it.
  Solo: double-tap a legend entry hides all others (double-tap again restores).
  Implemented in show() AFTER handleInteraction, which set fitted=false for the
  double-tap; we set fitted=true to cancel that queued fit. Demo: Legend tab.
- Box-zoom + getSelection: the box selection now lives in PlotState.sel
  (SelectRect, data space). processBoxSelect writes &state.sel; if
  opts.selection is set it's mirrored (back-compat report mode). Options.box_zoom
  consumes a completed band: sets state.x/y to the box then clears has/active
  (band vanishes; double-tap-fit restores). getSelection()->?SelectRect returns
  state.sel when .has. box_select (report) and box_zoom share the same drag/
  draw path (gated `box_select or box_zoom`). Demo: BoxZoom tab.
- Public query API (T17): show() snapshots the final layout into PlotState
  (q_area/q_x/q_y/q_x2/q_y2/q_mouse, q_valid). Methods on PlotState:
  getPlotLimits()->Limits, plotToPixels/pixelsToPlot (primary axes, scale-aware
  via Axis), plotToPixels2 (x2/y2), getPlotMousePos, plotArea, isInside. App
  code draws overlays AFTER show() with a DrawListSink.fromUi(u). plot_ui isn't
  in tests.zig (it pulls ui.zig), so the coord MATH is locked by a plot.zig
  Axis round-trip test; the wrappers are build-verified. Demo: Query tab draws
  a crosshair + live data coords (also covers ImPlot crosshairs/mouse-text).
- implicit-x: Series.xs now defaults to &.{}; empty xs => x = sample index.
  Core helpers xCoord(xs,i) + sampleCount(xs,ys) thread it through plotLine/
  scatter/stairs/stems/shaded; fitToSeries spans [0,ys.len-1]; drawReadout uses
  the index too. Non-line kinds (bars/candles/etc.) with empty xs draw nothing
  (safe, not a claimed feature). Host-tested (4 ys -> 3 segments).
- T15 (partial): NaN->gap shipped. plot.missing (=nan(f64)) marks a missing
  sample; finite2(x,y) gates every line-family renderer (plotLine breaks the
  segment via have_prev=false; stairs/stems/shaded `continue` on non-finite).
  fitToSeries is already NaN-safe (Range.expand uses < / > which are false for
  NaN). Host-verified (two-gap sine PNG). Demo: Gaps tab. Remaining T15:
  implicit-x (ys-only), stride/offset, custom getters, realtime ring buffer.
- T16 styling completed across chrome+legend+colorbar. Style gained legend_bg;
  drawLegendEx themes box bg/border/text via self.style. ColorbarSpec gained
  axis_color/text_color (?Color, null=>default constants); plot_ui defaults them
  from p.style.border/p.style.label so a themed plot's colorbar matches. Demo
  Theme tab's light Style sets legend_bg too. Series palette (autoColor) is the
  only remaining un-themed bit (intentional; per-series spec.color already works).
- T16 styling: plot.Style{ bg, panel_bg?, grid, minor_grid, border, text, label }
  threaded via Plot.style (defaults reproduce the dark theme). drawFrame uses
  bg/grid/minor_grid; drawDecorations uses border/text. plot_ui Options.style
  sets p.style; show() fills the WHOLE frame with panel_bg (if set) so gutter
  text (title/axis labels) reads on a light theme. Series colors stay per-spec /
  autoColor (palette theming deferred; legend + colorbar still use constants).
  Demo: Theme tab (29 tabs) toggles light/dark. Host-verified via SvgSink PNG.
- T14 step 2: secondary axes are now interactive. handleInteraction pans/zooms
  x2/y2 in pixel-lockstep with the primary x/y (same pixel delta for pan; same
  factor about the cursor/midpoint anchor for wheel/pinch), so secondary series
  + their axis labels track the view. Post-interaction re-layout now also re-sets
  p.x2.range = state.x2. Double-tap re-fit resets all four axes. Default matches
  ImPlot's 'drag plot moves all axes'; per-axis grab (hover one axis) is a later add.
- T14 (multiple axes), step 1: secondary X axis (X2, top), mirroring Y2.
  plot.zig: Plot.x2/x2_enabled/x2_ticks; layout() reserves a top gutter only
  when x2_enabled (existing plots unchanged) + generates x2 ticks; drawDecorations
  draws x2 ticks/label on top with title stacking. plot_ui: XAxis{x1,x2},
  Series.x_axis, PlotState.x2, Options.x2_label; draw loop save/swaps p.x for
  x2 series (same trick as y2); fitToSeries routes x-extent by x_axis. X2 is
  fit-once (not interactively panned), matching Y2. Demo: DualX tab (28 tabs).
  Next: X3/Y3 + per-axis interactive pan; binding model (series.axis/x_axis) ready.
- T16 colorbar (ColormapScale): plot.ColorbarSpec + plot.drawColorbar(sink,
  bar, spec) — vertical gradient (top=max) + outline + value-axis ticks +
  optional caption, all screen-space. plot_ui Options.colorbar reserves a
  64px right strip (frame.w -= 64) and draws it aligned to p.area. Wired into
  the heatmap demo tab (tracks the cycled cmap). Host-verified via SvgSink PNG.
- Scissor clamp extracted to pure clampScissorRect(x,y,w,h,rw,rh) in
  wgpu_draw.zig with 5 unit tests (off-left preserves right edge, off-right
  clamps to fb, fully-off=0, in-bounds unchanged, y un-flip + top clamp).
- plot.zig is now in src/tests.zig refAllDecls, so its ~10 inline tests run
  under `zig build test` (previously only via the isolated zig-test recipe).
- Build split: `zig build test` = host unit tests + build-check of the 10
  tier-A examples only (fast inner loop); `zig build test-all-examples` =
  exhaustive (host tests + every example wasm). Tier-A list + gating live in
  build.zig (`matchesFocus(name,"tier-a")` in the install-artifact graph walk).
- gltf negative test (`gltf.parse rejects malformed JSON`) is skipped
  (`if (true) return error.SkipZigTest;` before parse) so its intentional
  WARN never hits stderr during the test run.
- SCROLL HIJACK root cause (deeper): `ctx.hovered_window_id` is only ever SET
  to a window id, NEVER reset to 0, so it stays stale-pointing at the last
  window when the finger is over empty space. The touch-pan start gate used it,
  so a press in empty space (or a drag entering the window) hijack-scrolled.
  Fix: gate the touch-pan START on a GEOMETRIC point-in-window-body test of the
  press position + the press edge (mouse_left_clicked), NOT hovered_window_id.
  (Latent: sticky hovered_window_id still affects wheel-zoom/tooltip gates.)
- build: `zig build test` now build-checks only the tier-A example set (varied
  features, incl. plot_demo+damaged_helmet); `zig build test-all-examples` is
  the exhaustive sweep. Tier-A list lives in matchesFocus (single source).
- Touch-pan scroll (ui.zig closeWindow): a window only STARTS a touch-pan if
  the press DOWN-EDGE (mouse_left_clicked) landed while hovering that window.
  On touch, hover follows the finger, so without the press-edge gate a drag
  beginning outside and crossing in would hijack-scroll the window.
- THE off-screen-left spill bug (root cause): `WgpuGl.scissor` clamped a
  negative x to 0 but kept the full width, so the right edge sat at `0+w`,
  far past the window. Fix clamps BOTH edges ([0,rw]/[0,rh]) so clamping the
  left also shrinks the width. (rlsw was already correct: it stores x+w.)
  The ui.zig clip stack (intersect+restore) is necessary too, but the scissor
  clamp was what let content escape to the right.
- Heatmap/pie fit from their SPEC extent, not xs/ys: `fitToSeries` frames a
  heatmap by [x0,x1]x[y0,y1] and a pie by center+/-radius, so passing empty
  xs/ys is fine. (Bug: empty xs/ys left the axis at the default {0,1} and the
  heatmap drew oversized/spilling.)
- Clip stack (ui.zig DrawList.render): push_clip now INTERSECTS with the parent
  clip and pop_clip RESTORES it (was: set scissor absolutely + pop disables).
  This is what keeps a plot (or any widget) larger than its window from
  spilling past the window, incl. when the window is partly off-screen. `show()`
  just pushes `p.area`; the replay bounds it to the window automatically.
- Per-cell interaction gating (subplots): pan/drag/box-select use this
  cell's `active`; double-tap/wheel use `hovered`; **pinch** must be gated
  on `frame.contains(pz.mid)` because `u.pinch()` is a *global* gesture —
  otherwise every subplot zooms together.
- `zig build` runs `zimrlint` + `zig fmt --check` as hard prereqs. Lint:
  typed locals; braced `if(){...}`; ≤120 cols; bind `zm.X` at file scope; no
  `std.math` in shader-reachable code; with a pinned int type use bare
  `@floor`/`@round`/`@ceil` (not `@intFromFloat(@floor(..))`); `@splat` not `**`;
  fn ≥3 params one-per-line; no shadowing.
- This dev Zig (0.17.0-dev.864): `{d:0>2}` prints a `+` on *signed* ints — cast
  to unsigned before zero-padding. `std.meta.fields` deprecated.
- Verify renderers headlessly first: append a `test "DUMP …"` building a `Plot`
  + `SvgSink`, print between markers, `cairosvg` → PNG, then restore the file.
  Far faster than the ~2min single-core wasm rebuild.
- Standing instruction: every turn, save + present a project zip (excluding
  `.zig-cache`/`zig-out`/`.git`/toolchain/`prebuilt`) and the standalone html.
