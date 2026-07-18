# zimr plotting — `implot.zig`, `implot3d.zig` & friends

A pure-Zig port of [ImPlot](https://github.com/epezent/implot) (2D) and
[ImPlot3D](https://github.com/brenocq/implot3d) (3D), rebuilt on top of the
**zimr** backend (`zimrmath.zig` for math, `ui.zig` for immediate-mode widgets
and the command-recording draw list). No C, no Dear ImGui C++, no emscripten —
everything renders through zimr's WebGPU/WGSL pipeline in the browser
(`wasm32-wasi`) or natively.

> **Status: first-draft, not yet compiled.** Every file parses and was written
> to Zig 0.16 idioms, and all cross-references have been resolved by static
> analysis, but the code has **never been through `zig build`**. Treat it as a
> complete, internally-consistent draft awaiting its first compile pass. See
> [§9 Status & caveats](#9-status--caveats).

---

## Table of contents

1. [The five files at a glance](#1-the-five-files-at-a-glance)
2. [Architecture](#2-architecture)
3. [Build & module wiring](#3-build--module-wiring)
4. [Quick start](#4-quick-start)
5. [The color model](#5-the-color-model)
6. [`implot.zig` — the 2D library](#6-implotzig--the-2d-library)
7. [`implot3d.zig` — the 3D library](#7-implot3dzig--the-3d-library)
8. [The demos](#8-the-demos)
9. [Status & caveats](#9-status--caveats)
10. [Conventions & idioms](#10-conventions--idioms)
11. [Roadmap](#11-roadmap)

---

## 1. The five files at a glance

| File | Lines | Role | Public API |
|------|------:|------|-----------:|
| `plot_core.zig` | ~137 | Shared color + colormap + tick machinery. Depends only on `zm` + `ui`. | 10 |
| `implot.zig` | ~11,800 | The 2D plotting library (`ImPlot::` equivalent). | 206 fns |
| `implot3d.zig` | ~4,000 | The 3D plotting library (`ImPlot3D::` equivalent). | 98 fns |
| `implot_demo.zig` | ~2,720 | Port of `implot_demo.cpp`: 56 interactive demos. | `showDemoWindow` |
| `implot3d_demo.zig` | ~1,520 | Port of `implot3d_demo.cpp`: 30 interactive demos. | `showDemoWindow` |

Dependency graph:

```
        zimrmath.zig (zm)      ui.zig
              │   │              │ │
              ▼   ▼              ▼ │
            plot_core.zig         │
              │      │            │
      ┌───────┘      └───────┐    │
      ▼                      ▼    ▼
  implot.zig            implot3d.zig
      │                      │
      ▼                      ▼
 implot_demo.zig      implot3d_demo.zig
```

`plot_core.zig`, `implot.zig`, and `implot3d.zig` never touch each other's
internals — the two libraries are independent and share only through
`plot_core`. Either library can be used without the other, and without its demo.

---

## 2. Architecture

### 2.1 The backend boundary: the `im` shim

Each library funnels **every** backend interaction — widgets, input, the draw
list, style colors — through a single private `const im = struct { … }` block
near the top of the file. Nothing in the library body calls `ui.*` or `zm.*`
for drawing directly; it all goes through `im`. This is the single most
important structural decision in the codebase: it means the ~16,000 lines of
plotting logic are backend-agnostic, and porting to a different UI/draw backend
is a matter of re-pointing one struct.

The most-used member is the **draw-list adapter** (`im.DrawList`). zimr's
`ui.DrawList` is *command-recording* (it has no raw vertex/index buffer; you
call `addLine`/`addRectFilled`/`addCircleFilled`/… and it records commands), and
each `add*` call takes the frame allocator. The adapter wraps that so the
library body can speak its preferred vocabulary — corner-based rects, packed
`u32` colors — without threading the allocator through every call site:

```zig
const dl = getPlotDrawList();          // an im.DrawList
dl.addRectFilled(min, max, packed_col); // min/max corners; gpa handled inside
dl.addLine(a, b, packed_col, 1.0);
```

> **Consequence (a documented deviation from upstream):** because there is no
> raw vertex buffer, the renderers are *immediate* (they emit high-level shapes
> per primitive) rather than batched. Anti-aliased thick-line texturing, the
> shaded-region exact self-intersection vertex, and marker LOD batching from
> upstream ImPlot are therefore gone; see each library's header comment.

### 2.2 The context & the per-frame handle

State lives in a heap-allocated `Context` (one per application, like
`GImPlot`/`GImPlot3D`), reached through a file-global `gctx` and an internal
`plotCtx()` accessor that panics loudly if no context exists. You create it once
and, **every frame**, hand the library the current `ui.Ui` handle:

```zig
const ctx = implot.createContext(gpa);   // once, at startup
defer implot.destroyContext(ctx);
// … each frame, inside your UI pass:
implot.setUiHandle(ui_handle);           // bind the frame's widget handle
```

`beginPlot` also sets the handle, so in the common case you don't call
`setUiHandle` separately for 2D. For 3D you should call `i3d.setUiHandle(ui)`
once per frame before any `implot3d` call. The handle is stored on the context;
the `im` shim panics if a drawing call happens while it is null (i.e. outside a
frame). This mirror of the upstream global-singleton model is the one piece of C
heritage most worth revisiting later (see [§11](#11-roadmap)).

### 2.3 The data-access machinery (comptime-monomorphized)

Both libraries accept plot data as **`anytype` numeric slices** (`[]const f32`,
`[]const f64`, `[]const u32`, …) and convert to `f64` internally. The bridge is
a small family of comptime types so the hot per-point path fully specializes and
inlines (no vtables, no boxing):

- **Indexers** read one logical element → `f64`:
  - `ValueIndexer(T)` — reads element *i* from raw bytes with a **circular
    offset** (`Spec.offset`, for ring buffers) and a **byte stride**
    (`Spec.stride`, for interleaved/struct data); the logical element count is
    `slice_bytes / stride`.
  - `IndexerLin` — `m·i + b` (implicit x values with a start/spacing).
  - `IndexerConst` — a constant (bar/shaded reference lines).
  - `IndexerAdd(A,B)` — `s₁·a[i] + s₂·b[i]` (error-bar extents).
- **Getters** combine indexers into points: `GetterXY`, `GetterXYZ`,
  `GetterLoop` (wrap-around), `GetterOverride*`.
- **Transformers** map plot-space → pixel-space, including the nonlinear forward
  transform (log/symlog/custom). `Transformer1` is one axis; `Transformer2`
  holds both and is copied out of the axis structs so hot loops touch a flat
  struct.
- **Renderers** are comptime-generic over the getter type
  (`LineStripRenderer(G)`, `ShadedRenderer`, `BarsRenderer`, …); each does
  per-primitive culling against the plot rect and emits draw-list shapes.

This is the part of the design that is already idiomatic Zig and reasonably
performant; the cost is mostly in the number of draw-list commands, not the
math (see [§9](#9-status--caveats)).

### 2.4 `plot_core.zig`: the shared module

To avoid two copies of identical data and logic, `plot_core.zig` owns the
genuinely-shared, backend-only pieces. It depends solely on `zm` and `ui`, so it
could later fold directly into `ui.zig`. It deliberately stays small and has no
dead surface — everything in it is either used by a library or part of a
symmetric, self-documenting API (e.g. the `pack`/`unpack` pair):

```zig
// plot_core.zig public surface
pub const Color  = zm.Color;              // the canonical concrete color
pub const ColorF = zm.Vec;                // float color (@Vector(4,f32))
pub const Wire   = ui.ColorU32;           // packed draw-list format (0xAABBGGRR)

pub inline fn rgb / rgba / rgbaF / hex / hsv (…) Color   // constructor family
pub inline fn pack(Color) Wire / unpack(Wire) Color / packF(ColorF) Wire
pub const wire_white / wire_black / wire_transparent : Wire

pub const colormap_keys = struct { deep, dark, …, greys };  // 16 key tables
pub fn niceNum(x, round) f64
pub inline fn orderOfMagnitude(v) i32
```

What deliberately stays *per-library*: the `Cond` / `Marker` / `Scale` /
`Location` enums (their backing integer types differ between 2D and 3D, so
sharing them would silently change one library's values) and `ColormapData` (it
is wired to each library's allocator-failure plumbing and text buffer).

---

## 3. Build & module wiring

These are plain Zig source files; wire them into your `build.zig` as a module
graph. Each library needs `zm`, `ui`, and `plot_core` visible under those import
names. Sketch:

```zig
// build.zig (sketch — adapt to your tree)
const zm        = b.addModule("zm",        .{ .root_source_file = b.path("zimrmath.zig") });
const ui        = b.addModule("ui",        .{ .root_source_file = b.path("ui.zig") });

const plot_core = b.addModule("plot_core", .{ .root_source_file = b.path("plot_core.zig") });
plot_core.addImport("zm", zm);
plot_core.addImport("ui", ui);

const implot = b.addModule("implot", .{ .root_source_file = b.path("implot.zig") });
implot.addImport("zm", zm);
implot.addImport("ui", ui);
implot.addImport("plot_core", plot_core);   // note: imported as @import("plot_core.zig")

const implot3d = b.addModule("implot3d", .{ .root_source_file = b.path("implot3d.zig") });
implot3d.addImport("zm", zm);
implot3d.addImport("ui", ui);                // see import-name note below
implot3d.addImport("plot_core", plot_core);
```

> **Import-name note.** The files are not fully consistent about how they import
> the backend, and this should be reconciled at first compile:
> - `implot.zig` uses `@import("zm")` and `@import("ui")`.
> - `implot3d.zig` uses `@import("zm")` and `@import("ui.zig")`.
> - `plot_core.zig` and both demos use `@import("zm")` / `@import("ui.zig")` /
>   `@import("plot_core.zig")` / `@import("implot.zig")` etc.
>
> This only works cleanly if your build graph resolves `"ui"` and `"ui.zig"` to
> the *same* module. It is harmless today because the only `ui` type crossing
> module boundaries is `ColorU32 = u32` (a plain alias, identical regardless of
> path), but unify the import names when you first build.

---

## 4. Quick start

A minimal per-frame 2D plot, assuming you already have a `ui.Ui` handle for the
current frame:

```zig
const implot = @import("implot");

// once, at startup:
var ctx = implot.createContext(gpa);
defer implot.destroyContext(ctx);

// each frame, inside your UI:
fn drawFrame(ui_handle: ui.Ui) void {
    implot.setUiHandle(ui_handle);

    const xs = [_]f64{ 0, 1, 2, 3, 4 };
    const ys = [_]f64{ 0, 1, 4, 9, 16 };

    if (implot.beginPlot("My Plot", .{ 400, 300 }, .{})) {
        defer implot.endPlot();
        implot.setupAxes("x", "y", .{}, .{});
        implot.plotLine("y = x²", &xs, &ys, .{
            .line_color = implot.rgb(0, 120, 255),
            .marker = .circle,
        });
    }
}
```

A minimal 3D plot:

```zig
const i3d = @import("implot3d");

fn drawFrame3D(ui_handle: ui.Ui) void {
    i3d.setUiHandle(ui_handle);
    const xs = [_]f32{ 0, 1, 2, 3 };
    const ys = [_]f32{ 0, 1, 0, 1 };
    const zs = [_]f32{ 0, 1, 2, 3 };
    if (i3d.beginPlot("3D", .{ 400, 400 }, .{})) {
        defer i3d.endPlot();
        i3d.setupAxes("x", "y", "z", .{}, .{}, .{});
        i3d.plotLine(f32, "curve", &xs, &ys, &zs, .{ .marker = .circle });
    }
}
```

The whole demo (every feature, interactive):

```zig
const demo = @import("implot_demo");
demo.showDemoWindow(ui_handle, &show_demo);   // call once per frame
```

---

## 5. The color model

Color is the one place several representations legitimately coexist, so it is
worth understanding the flow. **`zm.Color` is the canonical concrete color and
the single pivot** between the float domain and the packed wire format.

| Representation | Type | Used for |
|---|---|---|
| `zm.Color` | `extern struct { r,g,b,a: u8 }` | the canonical color; what callers build with `rgb/hex/hsv`. `toWire()` is exactly `ui.ColorU32`. |
| float color (`Vec4`) | `struct { x,y,z,w: f32 }` (sRGB 0..1) | the libraries' internal color, because it carries the **auto sentinel** (`w = -1` ⇒ "deduce from colormap/style") and is the form blending/alpha math runs in. |
| wire (`ui.ColorU32`) | `u32`, layout `0xAABBGGRR` | what the draw list consumes. |
| `zm.Vec` (`ColorF`) | `@Vector(4, f32)` | the SIMD float form `zm.Color` converts through. |

All packing goes through `plot_core` (over `zm.Color`); there is **no
hand-rolled channel-order bit math** anywhere in the libraries. To build colors,
prefer the public constructors over raw struct literals:

```zig
implot.rgb(255, 128, 0)         // opaque, 0..255 channels
implot.rgba(255, 128, 0, 200)   // with alpha
implot.hex(0xff8800ff)          // CSS-order 0xRRGGBBAA
implot.hsv(0.1, 0.8, 0.9, 1)    // HSVA, components 0..1
implot.fromColor(zm.Color.hex(0xff8800ff))   // straight from a zm.Color
```

Each library also exposes `fromColor`/`toColor` (float ↔ `zm.Color`) and
`colorToU32`/`colorFromU32` (float ↔ wire) for building per-element color
arrays. The special value `auto_col` (alpha `-1`) means "pick the next colormap
color / resolve from the style"; `isColorAuto` tests for it.

---

## 6. `implot.zig` — the 2D library

206 public functions. Naming is the upstream `ImPlot::PascalCase` converted to
`camelCase` (`PlotLine` → `plotLine`). Labels are `[:0]const u8`; data is
`anytype` numeric slices; every plotter takes a trailing `Spec` value.

### 6.1 The `Spec` — per-item styling

`Spec` replaces upstream's variadic `(Prop, value, …)` constructor with a plain
struct literal. Defaults give a sensible auto-styled item:

```zig
pub const Spec = struct {
    line_color: Vec4 = auto_col,        line_colors: ?[]const u32 = null,
    line_weight: f32 = 1.0,
    fill_color: Vec4 = auto_col,        fill_colors: ?[]const u32 = null,
    fill_alpha: f32 = 1.0,
    marker: Marker = .none,             marker_size: f32 = 4,
    marker_sizes: ?[]const f32 = null,
    marker_line_color: Vec4 = auto_col, marker_line_colors: ?[]const u32 = null,
    marker_fill_color: Vec4 = auto_col, marker_fill_colors: ?[]const u32 = null,
    size: f32 = 4,                      // error-bar whisker / digital bar height
    offset: i32 = 0,                    // circular index offset (ring buffers)
    stride: i32 = auto,                 // BYTES; auto = @sizeOf(Elem)
    flags: ItemFlags = .{},             // see "specialized flags" below
};
```

**Specialized flags via `@bitCast`.** `Spec.flags` is the common `ItemFlags`,
but each plotter accepts its own flag set overlaid on the same 32 bits. The bit
layout is shared, so you pass specialized flags by `@bitCast`:

```zig
implot.plotLine("loop", xs, ys, .{
    .flags = @bitCast(implot.LineFlags{ .segments = true, .no_legend = true }),
});
```

The flag structs are `packed struct(u32)` with **non-contiguous** bits (e.g.
`LineFlags.segments` is bit 10) chosen to coexist with `ItemFlags`. Available
flag sets: `PlotFlags`, `AxisFlags`, `LineFlags`, `StairsFlags`, `BarsFlags`,
`BarGroupsFlags`, `ErrorBarsFlags`, `InfLinesFlags`, `StemsFlags`,
`HistogramFlags`, `HeatmapFlags`, `PieChartFlags`, `TextFlags`, `SubplotFlags`,
`LegendFlags`, `DragToolFlags`, `ColormapScaleFlags`.

### 6.2 Lifecycle & setup

```
createContext / destroyContext / getCurrentContext / setCurrentContext / setUiHandle
beginPlot(title, size: Vec2, PlotFlags) bool   …   endPlot()
```

Inside a `beginPlot` block, configure axes/legend before plotting:

```
setupAxes / setupAxis / setupAxesLimits / setupAxisLimits
setupAxisScale / setupAxisTransform / setupAxisFormat / setupAxisFormatter
setupAxisTicks / setupAxisTicksRange / setupAxisLinks
setupAxisLimitsConstraints / setupAxisZoomConstraints
setupLegend / setupMouseText / setupLock / setupFinish
```

Axes are addressed by the `Axis` enum (`x1,x2,x3,y1,y2,y3`); conditions by
`Cond` (`none,always,once`); scales by `Scale` (`linear,time,log10,symlog,
custom`).

### 6.3 Plotters (34)

| Family | Functions |
|---|---|
| Lines | `plotLine`, `plotLineValues`, `plotLineG` |
| Scatter | `plotScatter`, `plotScatterValues`, `plotScatterG` |
| Shaded | `plotShaded`, `plotShadedValues`, `plotShadedLines`, `plotShadedG` |
| Bars | `plotBars`, `plotBarsValues`, `plotBarsG`, `plotBarGroups` |
| Stairs | `plotStairs`, `plotStairsValues`, `plotStairsG` |
| Stems / inf lines | `plotStems`, `plotStemsValues`, `plotInfLines` |
| Error bars | `plotErrorBars`, `plotErrorBarsAsym` |
| Statistical | `plotHistogram`, `plotHistogram2D`, `plotPieChart`, `plotPieChartF` |
| Fields | `plotHeatmap`, `plotDigital`, `plotDigitalG`, `plotImage` |
| Extras | `plotBubbles`, `plotBubblesValues`, `plotPolygon`, `plotText`, `plotDummy` |

Each `*Values` variant takes a single value array with implicit x; each `*G`
variant takes a getter callback (`Getter = *const fn(idx, ?*anyopaque) Point`).

### 6.4 Colormaps, style, tools

```
// colormaps
pushColormap / popColormap / sampleColormap / nextColormapColor
getColormapColor / getColormapColorU / getColormapName / getColormapIndex
getColormapCount / getColormapSize / addColormap
colormapButton / colormapSlider / colormapScale / colormapIcon

// style
getStyle / pushStyleColor / popStyleColor / pushStyleVar / pushStyleVarInt
pushStyleVarVec2 / popStyleVar

// query
isPlotHovered / isPlotSelected / getPlotSelection / getPlotMousePos
getPlotLimits / plotToPixels / pixelsToPlot / getPlotDrawList

// interactive drag tools & annotations
dragPoint / dragLineX / dragLineY / dragRect / annotation / tagX / tagY

// composition
beginSubplots / endSubplots / beginAlignedPlots / endAlignedPlots

// drag & drop (item ↔ plot ↔ axis ↔ legend)
beginDragDropSourceItem / beginDragDropSourcePlot / beginDragDropSourceAxis
beginDragDropTargetPlot / beginDragDropTargetAxis / beginDragDropTargetLegend
endDragDropSource / endDragDropTarget
```

The built-in colormaps (from `plot_core.colormap_keys`): Deep, Dark, Pastel,
Paired (qualitative); Viridis, Plasma, Hot, Cool, Pink, Jet, Twilight, RdBu,
BrBG, PiYG, Spectral, Greys (continuous).

---

## 7. `implot3d.zig` — the 3D library

98 public functions, the same conventions as 2D. The crucial thing to
understand is the rendering model.

### 7.1 It is a CPU projection renderer, not GPU 3D

ImPlot3D has **no GPU camera**. A data point travels entirely on the CPU:

```
plot space ──normalize per axis──▶ NDC [-0.5,0.5]·NDCScale
           ──rotate by the plot quaternion──▶ ──orthographic project──▶ screen (Vec2)
```

Data and the projection run in `f64` (`Point3`, `Quat`, `Box`, `Range`,
`Plane3D`, `Ray`); the result is crossed to `f32` `Vec2` only at the draw
boundary. Triangles (surfaces, meshes, quads) are accumulated with a per-triangle
mean depth in a **`DrawList3D` painter's-algorithm batch**, sorted far→near on
`flush()`, and emitted as flat 2D `addTriangleFilled` calls. So `implot3d` lives
at the *same layer* as `implot` — above `ui`, never touching WebGPU. zimr's GPU
3D engine (`draw3d.zig`) is optional and only acts as a mesh-geometry source for
`plotMesh`.

The projection pipeline is exposed for custom overlays and picking:

```
plotToNDC / ndcToPixels / plotToPixels               // forward (point → screen)
pixelsToPlotRay / pixelsToPlotPlane                  // inverse (screen → world)
getFramePos / getFrameSize / getPlotRectPos / getPlotRectSize / getPlotRotation
```

### 7.2 Axes, box, plotters

Axes are addressed by `Axis3D` (`x,y,z` — the index enum; the per-axis *struct*
is named `Axis` to avoid a name collision). The 3D box has its own setup:

```
setupAxes / setupAxis / setupAxesLimits / setupAxisLimits
setupAxisScale / setupAxisScaleCustom / setupAxisFormat
setupAxisTicks / setupAxisTicksRange
setupAxisLimitsConstraints / setupAxisZoomConstraints
setupBoxScale / setupBoxRotation / setupBoxRotationQuat
setupBoxInitialRotation / setupBoxInitialRotationQuat / setupLegend
```

Plotters come in two forms — a `comptime T` numeric-slice form and a
`Point3`-slice `*Points` overload:

| Plotter | Slice form | Points form |
|---|---|---|
| Scatter | `plotScatter(T, label, xs, ys, zs, spec)` | `plotScatterPoints` |
| Line | `plotLine(T, …)` | `plotLinePoints` |
| Triangle | `plotTriangle(T, …)` | `plotTrianglePoints` |
| Quad | `plotQuad(T, …)` | `plotQuadPoints` |
| Surface | `plotSurface(T, label, xs, ys, zs, x_count, y_count, spec)` | — |
| Mesh | `plotMesh(label, []Point3, []u32 idx, spec)` | — |
| Text / Image / Dummy | `plotText` / `plotImage` / `plotDummy` | — |

Built-in mesh helpers: `cube_vtx`/`cube_idx` and `genSphere(...)`. (Upstream
ships a literal duck/sphere; this port generates the sphere instead.)

### 7.3 Interaction

`handleInput` implements right-drag rotation (composed quaternion) and
wheel-zoom around the center. Upstream's per-axis/plane edge hovering, pan
translation, and double-click-reset are **simplified/omitted** in this draft.

---

## 8. The demos

Both demos are *consumers* of their library — the canonical examples and the de
facto integration tests. Each defines a tiny `ig` widget shim over the `ui.Ui`
handle (only the widgets the demo bodies use) and a `demo` namespace of
sample-data helpers (RNG, scrolling buffers, getters), plus a `demo_ext` block
with the custom plotters (`styleSeaborn`, the 2D candlestick).

```zig
implot_demo.showDemoWindow(ui_handle, &p_open);    // 56 demos
implot3d_demo.showDemoWindow(ui_handle, &p_open);   // 30 demos
```

- **`implot_demo.zig`** — tab bar: Plots (23), Subplots (4), Axes (10), Tools
  (12), Custom (4), plus Config and Help. Exercises ~108 distinct public
  `implot` calls.
- **`implot3d_demo.zig`** — tab bar: Plots (14), Axes (8), Tools (1: mouse
  picking), Custom (4), plus Config and Help. Exercises 48 distinct `implot3d`
  calls.

**Documented demo deviations:** callback axis formatters → plain Zig format
strings; ImGui-side metrics/style/demo menu toggles wired but no-op (they are
the host app's windows); image plots use a placeholder texture id; mesh plots
use the generated cube/sphere rather than upstream's literal duck; realtime
plots use a wall-clock time stand-in and fixed-capacity buffers; the candlestick
dataset is shrunk from 218 to 30 days; per-demo `static` locals become
file-scope `var` blocks (Zig has no function statics).

---

## 9. Status & caveats

**Not compiled.** This is the headline caveat and it colors everything else. The
files were written to compile *in principle*, every cross-reference resolves
under static analysis, and a 28-site type-annotation bug (locals mis-typed as
`*Context`) has been fixed — but the type checker has not run. Expect a real
first-build pass to surface fixups, most likely in:

- The `@ptrCast([*]const f32/f64)[…]` patterns used to slice interleaved
  (stride) data in several demos.
- `std.fmt.bufPrint`/`bufPrintZ` label lifetimes.
- The `comptime`/`@bitCast` flag and `checkboxFlags` bit-manipulation paths.
- The `"ui"` vs `"ui.zig"` import-name asymmetry (see [§3](#3-build--module-wiring)).

**Performance is correct-but-not-tuned.** The math path is comptime-specialized
and cheap; the cost center is the **number of draw-list commands** (each
`add*` is an `ArrayList.append`). A 1,000-point line emits ~1,000 commands.
Known wins, deliberately deferred: batch uniform-color line strips into a single
`addPolyline`; range-cull / decimate huge series before transform; cache the 3D
painter's sort across frames when the view quaternion is unchanged and
pre-reserve the triangle buffer.

**Allocation failures are swallowed.** Draw-list and pool growth use `catch {}` /
`catch oom()`. For a per-frame GPU plotting library, dropping a frame on OOM is
arguably acceptable, but it is currently an implicit, scattered policy rather
than a documented one.

---

## 10. Conventions & idioms

- **Naming.** Upstream `PascalCase` → `camelCase`. Enums/types stay `PascalCase`.
  Flags are `packed struct(u32)`; single-direction `Location` values are fields
  (`.{ .east = true }`), multi-direction ones are named consts (`.north_west`).
- **`begin*`/`end*` pairing.** `beginPlot`/`beginSubplots`/`beginItem` return
  `bool`; pair them with `endPlot`/etc. Using `defer endPlot();` right after a
  successful `beginPlot` is the recommended idiom and avoids missed-`end` bugs
  on early returns.
- **Zig 0.16 specifics.** Unmanaged `std.ArrayList` (`.append(gpa, …)`,
  `.pop()` returns `?T`); `@Vector` math with `[0]/[1]` component access (note
  `Vec2 = @Vector(2,f32)` uses `[0]/[1]`, while the color `Vec4` struct uses
  `.x/.y/.z/.w`); `std.mem.sort`; `std.Random.DefaultPrng`.
- **Data shape.** Plotters take `anytype` numeric slices and convert to `f64`.
  `Spec.stride` is in **bytes**; `Spec.offset` is a circular index. For
  interleaved data, pass slices into the same buffer with a custom stride.

---

## 11. Roadmap

Improvements identified but deliberately deferred until a compiler is in the
loop (they are behavior-changing or too large to land blind):

1. **Get it compiling** against a ~200-line stub `ui`/`zm` so `zig build-obj`
   can flush the unknowns above. Highest leverage by far.
2. **Retire the `auto_col` sentinel** by migrating the float-`Vec4` color fields
   to `?zm.Color` (`null` = auto). Removes the magic `w = -1` and the bespoke
   float color struct, at the cost of touching ~130 sites — wants a type
   checker.
3. **`Context`-as-receiver** (`ctx.beginPlot(…)`) to retire the mutable global
   singleton, enabling parallel/independent plots and unit tests.
4. **Draw-list batching** + 3D sort caching (the performance work in [§9](#9-status--caveats)).
5. **Unify the demo `ig` shims** (the two are ~67 and ~39 near-overlapping
   widget wrappers) and unify the backend import names.

See `PLAN_IMPROVEMENTS.md` for the detailed log of what has already been done in
the clean-up passes (the `*Context` fix, `plot_core` extraction, the `zm.Color`
pivot, colormap/tick de-duplication, and the demo color-literal cleanup).
