//! plot.zig — a native-Zig plotting library for zimr, in the spirit of
//! Dear ImGui's ImPlot but redesigned to be idiomatic Zig.
//!
//! Layering (the key departure from ImPlot, which welds rendering to a
//! single `ImDrawList`):
//!
//!   1. **Rendering core** (this file, the `Plot` type + `Axis`/`Ticker`).
//!      Depends only on `zm`.  Emits primitives to a *duck-typed sink* —
//!      anything exposing `fillRect / line / polyline / circleFilled /
//!      triangleFilled / text`.  Pure, allocation-light, host-testable,
//!      and renderable off-screen.
//!   2. **Sinks.**  `SvgSink` (here) renders to an SVG string for host
//!      snapshot tests and docs.  A `DrawListSink` wrapping `ui.DrawList`
//!      (next increment) renders in-engine.  The core never learns which.
//!   3. **ImPlot-style stateful API** (next increment): `beginPlot /
//!      setupAxes / plotLine / endPlot` over `ui.Ui`, a thin shell that
//!      drives the core with a `DrawListSink` and feeds interaction.
//!
//! Data coords are f64 (science data needs the precision); pixel coords
//! are f32 (`zm.Vec2`).  The axis transform encodes direction *and*
//! inversion in its pixel endpoints (ImPlot's trick), so there is no
//! hardcoded Y-flip and inverted axes fall out for free.

const std = @import("std");
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const float64 = zm.float64;
const draw2d = @import("draw2d.zig");
const core = @import("plot_core.zig");

// Bind zm helpers at file scope (lint: no qualified zm.* in bodies).
const Range = zm.Range;
const lerpV = zm.lerpV;
const niceNum = zm.niceNum;
const pi = zm.pi;
const tau = zm.tau;
const floori = zm.floori;
const inf = zm.inf;
const log10 = zm.log10;
const clamp = zm.clamp;
const exp10 = zm.exp10;
const assertf = zm.assertf;
const isFinite = zm.isFinite;
const nan = zm.nan;
const float = zm.float;

const Color = zm.Color;

/// Light text used for value labels drawn over bars.
const label_color: Color = .{ .r = 224, .g = 224, .b = 228, .a = 255 };

const Vec2 = zm.Vec2;
pub const DataRange = Range(f64);

/// Axis-aligned pixel rectangle (top-left origin, +y down).  The core's
/// own rect type so it owes nothing to `ui`; the `ui` adapter converts.
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }
    /// True if point `p` lies within the rectangle (inclusive edges).
    pub fn contains(self: Rect, p: Vec2) bool {
        return p[0] >= self.x and p[0] <= self.right() and p[1] >= self.y and p[1] <= self.bottom();
    }
    pub fn inset(self: Rect, dx: f32, dy: f32) Rect {
        return .{ .x = self.x + dx, .y = self.y + dy, .w = self.w - 2 * dx, .h = self.h - 2 * dy };
    }
};

// ============================================================================
// [SECTION] Public knobs
// ============================================================================

pub const Marker = enum {
    none,
    circle,
    square,
    diamond,
    triangle_up,
    triangle_down,
    triangle_left,
    triangle_right,
    plus,
    cross,
    asterisk,
};

pub const LineSpec = struct {
    /// null = auto-cycle the palette by series index.
    color: ?Color = null,
    thickness: f32 = 1.5,
    marker: Marker = .none,
    marker_size: f32 = 3.5,
    /// Draw markers only, skip the connecting line.
    markers_only: bool = false,
};

/// Tick label number formatting.
pub const NumberFormat = enum { auto, fixed, scientific, percent, si };

pub const BarsSpec = struct {
    color: ?Color = null,
    /// Bar width as a fraction of the slot width (1.0 = touching).
    width: f32 = 0.67,
    /// Horizontal bars: `ys` are category positions, `xs` the values (bars
    /// grow along x from 0). Vertical (default): `xs` positions, `ys` values.
    horizontal: bool = false,
    /// Draw the value above (vertical) / right of (horizontal) each bar.
    show_labels: bool = false,
    label_format: NumberFormat = .auto,
    label_decimals: u8 = 0,
};

/// Clustered or stacked bar groups. `values` is row-major item-major:
/// `values[item * group_count + group]`. Groups sit at x = 0,1,...
pub const BarGroupsSpec = struct {
    /// Total width of each group's cluster (data units).
    width: f32 = 0.67,
    /// Stack items within a group instead of placing them side by side.
    stacked: bool = false,
    /// Per-item colors; null = palette `autoColor(item)`.
    colors: ?[]const Color = null,
};

/// One legend row: a colored swatch + its label. Built by the caller from
/// its series (e.g. `plot_ui` resolves each series' palette color).
pub const LegendEntry = struct {
    label: []const u8,
    color: Color,
};

/// Corner placement for the legend box.
pub const LegendLocation = enum { nw, ne, sw, se };

/// Geometry of a laid-out legend, so the UI layer can hit-test row clicks.
pub const LegendLayout = struct {
    box: Rect,
    row_h: f32,
    pad_y: f32,
    n: usize,
    /// When true the entries run left-to-right in a single row; `cell_w` is the
    /// per-entry pitch and `pad_x` the inset from the box's left edge.
    horizontal: bool = false,
    cell_w: f32 = 0,
    pad_x: f32 = 0,
    /// Which legend entry (if any) the point `p` falls on.
    pub fn hit(self: LegendLayout, p: Vec2) ?usize {
        if (self.horizontal) {
            const top: f32 = self.box.y + self.pad_y;
            if (p[1] < top or p[1] > top + self.row_h) {
                return null;
            }
            const left: f32 = self.box.x + self.pad_x;
            if (p[0] < left or self.cell_w <= 0) {
                return null;
            }
            const idx: usize = @floor((p[0] - left) / self.cell_w);
            if (idx >= self.n) {
                return null;
            }
            return idx;
        }
        if (p[0] < self.box.x or p[0] > self.box.x + self.box.w) {
            return null;
        }
        const top: f32 = self.box.y + self.pad_y;
        if (p[1] < top) {
            return null;
        }
        const idx: usize = @floor((p[1] - top) / self.row_h);
        if (idx >= self.n) {
            return null;
        }
        return idx;
    }
};

/// Fill between a series and a horizontal baseline (`y_ref`). Give the color
/// an alpha below 255 for the usual translucent area look.
pub const ShadedSpec = struct {
    color: ?Color = null,
    y_ref: f64 = 0,
};

/// Full-extent reference lines. Vertical at x=value by default; set
/// `horizontal` to draw at y=value instead.
pub const InfLinesSpec = struct {
    color: ?Color = null,
    thickness: f32 = 1.5,
    horizontal: bool = false,
};

/// Symmetric vertical error bars. `cap` is the end-cap half-width in pixels.
pub const ErrorBarsSpec = struct {
    color: ?Color = null,
    thickness: f32 = 1.5,
    cap: f32 = 4.0,
};

/// Free-floating text at a data coordinate (`plotText`).
pub const TextSpec = struct {
    color: ?Color = null,
    size: f32 = 12,
    /// Pixel offset from the data point.
    offset: Vec2 = .{ 0, 0 },
    /// Center horizontally on the point (else left-aligned at it).
    center: bool = true,
};

/// A filled text bubble anchored above a data point, clamped into the area.
pub const AnnotationSpec = struct {
    bg: Color = .{ .r = 30, .g = 30, .b = 38, .a = 235 },
    text_color: Color = .{ .r = 232, .g = 232, .b = 238, .a = 255 },
    size: f32 = 12,
    offset: Vec2 = .{ 0, -8 },
    clamp: bool = true,
};

/// An axis-edge tag marking a coordinate (filled box + value text).
pub const TagSpec = struct {
    bg: Color = .{ .r = 66, .g = 66, .b = 82, .a = 255 },
    text_color: Color = .{ .r = 245, .g = 245, .b = 250, .a = 255 },
    size: f32 = 12,
};

pub const AxisFlags = packed struct(u8) {
    no_grid: bool = false,
    no_tick_labels: bool = false,
    invert: bool = false,
    _pad: u5 = 0,
};

/// ImPlot's default qualitative palette (Dear ImGui "modern" set).  Auto
/// hue cycling via `zm.hsvToRgb` is the planned enhancement; a curated
/// table reads better for small series counts, so we keep it for v0.
const palette = [_]Color{
    .{ .r = 33, .g = 150, .b = 243, .a = 255 }, // blue
    .{ .r = 244, .g = 67, .b = 54, .a = 255 }, // red
    .{ .r = 76, .g = 175, .b = 80, .a = 255 }, // green
    .{ .r = 255, .g = 152, .b = 0, .a = 255 }, // orange
    .{ .r = 156, .g = 39, .b = 176, .a = 255 }, // purple
    .{ .r = 0, .g = 188, .b = 212, .a = 255 }, // cyan
    .{ .r = 255, .g = 193, .b = 7, .a = 255 }, // amber
    .{ .r = 121, .g = 85, .b = 72, .a = 255 }, // brown
};

pub fn autoColor(series_index: usize) Color {
    return palette[series_index % palette.len];
}

/// Sentinel for a missing sample: assign to a series' x or y to break the
/// line / skip the point there (see `finite2`). It is a quiet NaN.
pub const missing: f64 = nan(f64);

/// True when both coordinates are finite (not NaN/inf). Non-finite samples
/// break a line / are skipped, so a series can encode missing data as NaN.
fn finite2(x: f64, y: f64) bool {
    return isFinite(x) and isFinite(y);
}

/// X coordinate of sample `i`: explicit `xs[i]`, or the index `i` itself when
/// `xs` is empty — implicit-x, ImPlot's `PlotLine(ys)` convenience (no alloc).
fn xCoord(xs: []const f64, i: usize) f64 {
    return if (xs.len == 0) @floatFromInt(i) else xs[i];
}

/// Number of samples to draw for a (possibly implicit-x) series: `ys.len` when
/// `xs` is empty, else the shorter of the two.
fn sampleCount(xs: []const f64, ys: []const f64) usize {
    return if (xs.len == 0) ys.len else @min(xs.len, ys.len);
}

const grid_color = Color{ .r = 60, .g = 60, .b = 70, .a = 255 };
const minor_grid_color = Color{ .r = 38, .g = 38, .b = 46, .a = 255 };
const border_color = Color{ .r = 110, .g = 110, .b = 125, .a = 255 };
const bg_color = Color{ .r = 24, .g = 24, .b = 30, .a = 255 };
const text_color = Color{ .r = 210, .g = 210, .b = 220, .a = 255 };
const legend_bg = Color{ .r = 18, .g = 18, .b = 24, .a = 220 };

/// Theming for a plot's chrome. Defaults reproduce the built-in dark theme;
/// override fields (via `plot_ui.Options.style`) for a light theme or accent
/// recoloring. Series colors are separate — set them per-series on each spec,
/// or fall back to the qualitative `autoColor` palette.
pub const Style = struct {
    /// Plot-area fill, drawn behind the grid and series.
    bg: Color = bg_color,
    /// Optional fill for the WHOLE plot frame (gutters included), drawn behind
    /// everything. Set this for a light theme so the axis labels/title (which
    /// live in the gutters) sit on the theme background, not the window's.
    /// Null (default) leaves the gutters transparent — the built-in dark look.
    panel_bg: ?Color = null,
    /// Major gridline color.
    grid: Color = grid_color,
    /// Minor gridline color (between majors).
    minor_grid: Color = minor_grid_color,
    /// Axis border + tick-mark color.
    border: Color = border_color,
    /// Tick label / title / axis-label text color.
    text: Color = text_color,
    /// Secondary text (legend entries, colorbar labels).
    label: Color = label_color,
    /// Legend box background.
    legend_bg: Color = legend_bg,
};

// ============================================================================
// [SECTION] Colormaps — ImPlot's 16 built-ins + sampling
//
// The enum, the key tables, and the sampling math are shared with plot3d via
// plot_core.zig (defined exactly once). plot3d's ctx-bound sampleColormap goes
// through its allocated ColormapData; this 2D twin is stateless and reads the
// built-in key tables directly through plot_core.
// ============================================================================

pub const Colormap = core.Colormap;

/// Sample a colormap at t in [0,1]. Qualitative maps pick a discrete color;
/// continuous maps interpolate between control colors.
const sampleColormap = core.sampleBuiltinColormap;

/// Draw a horizontal gradient strip of `cmap` filling `rect` (t=0 at left).
pub fn drawColormapBar(sink: anytype, rect: Rect, cmap: Colormap, segments: usize) void {
    const seg: usize = @max(segments, 1);
    const w: f32 = rect.w / float(seg);
    for (0..seg) |i| {
        const t: f32 = (float(i) + 0.5) / float(seg);
        const x: f32 = rect.x + float(i) * w;
        sink.fillRect(.{ .x = x, .y = rect.y, .w = w + 1.0, .h = rect.h }, sampleColormap(cmap, t));
    }
}

/// A vertical colorbar legend: a colormap gradient with a labeled value axis.
/// Drawn in screen space (like the legend), positioned by the caller next to
/// the plot area. Top of the bar = `max`, bottom = `min`.
pub const ColorbarSpec = struct {
    cmap: Colormap = .viridis,
    min: f64 = 0,
    max: f64 = 1,
    /// Number of tick labels, including both endpoints (>= 2).
    ticks: u8 = 5,
    label_format: NumberFormat = .auto,
    label_decimals: u8 = 2,
    /// Optional caption drawn above the bar (e.g. the measured quantity).
    label: ?[]const u8 = null,
    /// Outline + tick-mark color; null falls back to the default label color.
    axis_color: ?Color = null,
    /// Label text color; null falls back to the default label color.
    text_color: ?Color = null,
};

/// SI-suffixed compact format (e.g. 12k, 3.4M, 250m). ASCII suffixes only.
fn formatSI(buf: []u8, value: f64) []const u8 {
    const a: f64 = @abs(value);
    if (a == 0 or !zm.isFinite(a)) {
        return bufPrint(buf, "0", .{}) catch "";
    }
    const big = [_][]const u8{ "", "k", "M", "G", "T", "P" };
    const small = [_][]const u8{ "", "m", "u", "n", "p" };
    if (a >= 1000) {
        var x: f64 = value;
        var i: usize = 0;
        while (@abs(x) >= 1000 and i + 1 < big.len) : (i += 1) {
            x /= 1000.0;
        }
        return bufPrint(buf, "{d:.1}{s}", .{ x, big[i] }) catch "";
    }
    if (a < 1) {
        var x: f64 = value;
        var i: usize = 0;
        while (@abs(x) < 1 and i + 1 < small.len) : (i += 1) {
            x *= 1000.0;
        }
        return bufPrint(buf, "{d:.1}{s}", .{ x, small[i] }) catch "";
    }
    return bufPrint(buf, "{d:.1}", .{value}) catch "";
}

/// Decimal places to show given a tick interval: enough to distinguish
/// adjacent ticks, none for integer intervals.
/// Format a tick value into `buf` per `fmt`. Returns the written slice.
fn formatNumber(buf: []u8, value: f64, decimals: u8, fmt: NumberFormat) []const u8 {
    switch (fmt) {
        .auto, .fixed => {
            return bufPrint(buf, "{d:.[p]}", .{ .number = value, .p = decimals }) catch
                (bufPrint(buf, "{d}", .{value}) catch "");
        },
        .scientific => return bufPrint(buf, "{e:.2}", .{value}) catch "",
        .percent => return bufPrint(buf, "{d:.[p]}%", .{ .number = value * 100.0, .p = decimals }) catch "",
        .si => return formatSI(buf, value),
    }
}

/// Draw a vertical colorbar into the screen-space gradient rect `bar`. Tick
/// marks + value labels are written just to the RIGHT of `bar`, so the caller
/// must leave roughly 46px of clear space there. Pairs with `HeatmapSpec`
/// (use the same `cmap`/`min`/`max`) to annotate a heatmap's value scale.
pub fn drawColorbar(sink: anytype, bar: Rect, spec: ColorbarSpec) void {
    assertf(spec.ticks >= 2, @src(), "colorbar needs >= 2 ticks, got {d}", .{spec.ticks});
    // Gradient, painted bottom (min, t=0) to top (max, t=1).
    const seg: usize = 64;
    const segh: f32 = bar.h / float(seg);
    for (0..seg) |i| {
        const fi: f32 = float(i);
        const t: f32 = (fi + 0.5) / float(seg);
        const y: f32 = bar.bottom() - (fi + 1.0) * segh;
        sink.fillRect(.{ .x = bar.x, .y = y, .w = bar.w, .h = segh + 1.0 }, sampleColormap(spec.cmap, t));
    }
    // Thin outline (four edges).
    const oc: Color = spec.axis_color orelse label_color;
    const tc: Color = spec.text_color orelse label_color;
    sink.line(.{ bar.x, bar.y }, .{ bar.right(), bar.y }, .{ .color = oc, .thickness = 1 });
    sink.line(.{ bar.right(), bar.y }, .{ bar.right(), bar.bottom() }, .{ .color = oc, .thickness = 1 });
    sink.line(.{ bar.right(), bar.bottom() }, .{ bar.x, bar.bottom() }, .{ .color = oc, .thickness = 1 });
    sink.line(.{ bar.x, bar.bottom() }, .{ bar.x, bar.y }, .{ .color = oc, .thickness = 1 });
    // Tick marks + value labels (top = max, bottom = min).
    var buf: [32]u8 = undefined;
    const n: usize = spec.ticks;
    for (0..n) |i| {
        const frac: f64 = float64(i) / float64(n - 1);
        const fy: f32 = bar.bottom() - @as(f32, @floatCast(frac)) * bar.h;
        const value: f64 = spec.min + frac * (spec.max - spec.min);
        sink.line(.{ bar.right(), fy }, .{ bar.right() + 4, fy }, .{ .color = oc, .thickness = 1 });
        const s: []const u8 = formatNumber(&buf, value, spec.label_decimals, spec.label_format);
        sink.text(.{ bar.right() + 7, fy - 6 }, s, .{ .size = 12, .color = tc });
    }
    if (spec.label) |lb| {
        sink.text(.{ bar.x, bar.y - 16 }, lb, .{ .size = 12, .color = tc });
    }
}

/// Spec for `plotHeatmap`. Values (row-major, row 0 at top) are normalized
/// from [min,max] to [0,1], colored by `cmap`, tiling [x0,x1] x [y0,y1].
pub const HeatmapSpec = struct {
    cmap: Colormap = .viridis,
    min: f64 = 0,
    max: f64 = 1,
    x0: f64 = 0,
    x1: f64 = 1,
    y0: f64 = 0,
    y1: f64 = 1,
    /// Print each cell's value in its center (auto black/white for contrast).
    show_labels: bool = false,
    label_decimals: u8 = 1,
};

/// Texture-in-plot options for `plotImage`. `uv0`/`uv1` select a sub-rectangle
/// of the texture (top-left, bottom-right; default the whole 0..1). `tint`
/// multiplies the sampled texels (default opaque white = untinted).
pub const ImageSpec = struct {
    uv0: Vec2 = .{ 0, 0 },
    uv1: Vec2 = .{ 1, 1 },
    tint: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
};

/// Pie / donut. Center and radius are in data coordinates so the chart lives
/// in the plot's space (pair with `equal_aspect` to keep it circular).
pub const PieSpec = struct {
    cx: f64 = 0,
    cy: f64 = 0,
    radius: f64 = 1,
    colors: ?[]const Color = null,
    labels: ?[]const []const u8 = null,
    show_percent: bool = true,
};

/// Bubble chart: scatter with a per-point size mapped to a pixel radius.
pub const BubbleSpec = struct {
    color: ?Color = null,
    min_radius: f32 = 4,
    max_radius: f32 = 28,
    alpha: u8 = 120,
};

/// Candlestick / OHLC. `width` is the body width as a fraction of x-spacing.
pub const CandleSpec = struct {
    bull: Color = .{ .r = 38, .g = 166, .b = 91, .a = 255 },
    bear: Color = .{ .r = 217, .g = 83, .b = 79, .a = 255 },
    width: f64 = 0.67,
    wick_thickness: f32 = 1.5,
};

/// Digital / logic trace: a 0/1 step signal drawn in a fixed screen-space band
/// near the plot's bottom (x follows the data axis; y ignores the data range).
pub const DigitalSpec = struct {
    color: ?Color = null,
    height: f32 = 22,
    offset: f32 = 8,
    thickness: f32 = 2,
};

// ============================================================================
// [SECTION] Histogram binning — pure (caller owns buffers); render the result
// with plotBars (1D) or plotHeatmap (2D). Keeps the core allocation-free.
// ============================================================================

/// Count `values` into `counts.len` equal-width bins over [min,max]. Values
/// outside the range are dropped. Clears `counts` first.
pub fn histogramBins(values: []const f64, counts: []f64, min: f64, max: f64) void {
    for (counts) |*cnt| {
        cnt.* = 0;
    }
    const b: usize = counts.len;
    if (b == 0 or max <= min) {
        return;
    }
    const span: f64 = max - min;
    const bf: f64 = float64(b);
    for (values) |v| {
        if (v < min or v > max) {
            continue;
        }
        var idx: usize = @floor((v - min) / span * bf);
        if (idx >= b) {
            idx = b - 1;
        }
        counts[idx] += 1;
    }
}

/// Bin (x,y) samples into a row-major `rows`x`cols` grid (row 0 at top, so
/// higher y sits higher). Drops out-of-range points. Clears `counts` first.
pub fn histogramBins2D(
    xs: []const f64,
    ys: []const f64,
    counts: []f64,
    cols: usize,
    rows: usize,
    xmin: f64,
    xmax: f64,
    ymin: f64,
    ymax: f64,
) void {
    for (counts) |*cnt| {
        cnt.* = 0;
    }
    if (cols == 0 or rows == 0 or xmax <= xmin or ymax <= ymin) {
        return;
    }
    const n: usize = @min(xs.len, ys.len);
    const xspan: f64 = xmax - xmin;
    const yspan: f64 = ymax - ymin;
    const cf: f64 = float64(cols);
    const rf: f64 = float64(rows);
    for (0..n) |i| {
        const x: f64 = xs[i];
        const y: f64 = ys[i];
        if (x < xmin or x > xmax or y < ymin or y > ymax) {
            continue;
        }
        var cx: usize = @floor((x - xmin) / xspan * cf);
        if (cx >= cols) {
            cx = cols - 1;
        }
        var cy: usize = @floor((y - ymin) / yspan * rf);
        if (cy >= rows) {
            cy = rows - 1;
        }
        counts[(rows - 1 - cy) * cols + cx] += 1;
    }
}

// ============================================================================
// [SECTION] Axis transform — direction lives in the pixel endpoints
// ============================================================================

pub const Scale = enum { linear, log10, time, symlog, custom };

/// Forward/inverse pair for `Scale.custom`. `forward` maps a data value to a
/// monotonic coordinate the axis lays out linearly; `inverse` undoes it.
pub const AxisMap = struct {
    forward: *const fn (f64) f64,
    inverse: *const fn (f64) f64,
};

/// Symmetric-log forward map: linear within ±`lt`, one unit per decade beyond.
fn symForward(v: f64, lt: f64) f64 {
    const a: f64 = @abs(v);
    if (a <= lt) {
        return v / lt;
    }
    const s: f64 = if (v < 0) -1.0 else 1.0;
    return s * (1.0 + log10(a / lt));
}

fn symInverse(t: f64, lt: f64) f64 {
    const a: f64 = @abs(t);
    if (a <= 1.0) {
        return t * lt;
    }
    const s: f64 = if (t < 0) -1.0 else 1.0;
    return s * lt * exp10(a - 1.0);
}

/// Optional bounds on an axis range: hard edge limits + min/max span (zoom).
/// `null` fields are unconstrained.
pub const AxisConstraints = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    span_min: ?f64 = null,
    span_max: ?f64 = null,

    /// Clamp `r` to these constraints (span first, then shift into bounds).
    pub fn apply(self: AxisConstraints, r: DataRange) DataRange {
        var lo: f64 = r.min;
        var hi: f64 = r.max;
        if (self.min) |mn| {
            if (self.max) |mx| {
                assertf(mn <= mx, @src(), "axis constraint min {d} > max {d}", .{ mn, mx });
            }
        }
        if (self.span_max) |sm| {
            if (hi - lo > sm) {
                const c: f64 = (lo + hi) * 0.5;
                lo = c - sm * 0.5;
                hi = c + sm * 0.5;
            }
        }
        if (self.span_min) |sm| {
            if (hi - lo < sm) {
                const c: f64 = (lo + hi) * 0.5;
                lo = c - sm * 0.5;
                hi = c + sm * 0.5;
            }
        }
        if (self.min) |mn| {
            if (lo < mn) {
                hi += mn - lo;
                lo = mn;
            }
        }
        if (self.max) |mx| {
            if (hi > mx) {
                lo -= hi - mx;
                hi = mx;
            }
        }
        if (self.min) |mn| {
            if (lo < mn) {
                lo = mn;
            }
        }
        if (self.max) |mx| {
            if (hi > mx) {
                hi = mx;
            }
        }
        return .{ .min = lo, .max = hi };
    }
};

pub const Axis = struct {
    range: DataRange = .{ .min = 0, .max = 1 },
    /// Pixel at `range.min`. For X this is the left edge; for Y, because
    /// screen +y points down, this is the *bottom* edge. Inversion just
    /// swaps `px_min`/`px_max`.
    px_min: f32 = 0,
    px_max: f32 = 1,
    flags: AxisFlags = .{},
    label: ?[]const u8 = null,
    scale: Scale = .linear,
    /// Linear-region half-width for `Scale.symlog` (must be > 0).
    linthresh: f64 = 1,
    /// Forward/inverse pair for `Scale.custom`.
    transform: ?AxisMap = null,
    /// Optional pan/zoom constraints (edge limits + span limits).
    constraints: AxisConstraints = .{},
    /// Explicit tick positions; when set, replaces the auto locator.
    custom_ticks: ?[]const f64 = null,
    /// Optional labels parallel to `custom_ticks` (else values are formatted).
    custom_labels: ?[]const []const u8 = null,
    /// Tick label number format.
    format: NumberFormat = .auto,

    /// Keep log inputs strictly positive (log10(<=0) is undefined).
    fn logSafe(v: f64) f64 {
        return if (v > 1e-300) v else 1e-300;
    }

    /// Data value -> monotonic layout coordinate (the scale's forward map).
    /// All non-linear scales funnel through here so transforms, ticks, and
    /// zoom stay consistent.
    fn toLinear(self: Axis, v: f64) f64 {
        switch (self.scale) {
            .linear, .time => return v,
            .log10 => return log10(logSafe(v)),
            .symlog => return symForward(v, self.linthresh),
            .custom => {
                const tr: AxisMap = self.transform orelse {
                    assertf(false, @src(), "Scale.custom requires Axis.transform to be set", .{});
                    return v;
                };
                return tr.forward(v);
            },
        }
    }

    /// Inverse of `toLinear`.
    fn fromLinear(self: Axis, t: f64) f64 {
        switch (self.scale) {
            .linear, .time => return t,
            .log10 => return exp10(t),
            .symlog => return symInverse(t, self.linthresh),
            .custom => {
                const tr: AxisMap = self.transform orelse return t;
                return tr.inverse(t);
            },
        }
    }

    /// Data value -> [0,1] fraction along the axis.
    pub fn dataToFraction(self: Axis, v: f64) f64 {
        const lmin: f64 = self.toLinear(self.range.min);
        const lmax: f64 = self.toLinear(self.range.max);
        const span: f64 = lmax - lmin;
        if (span == 0) {
            return 0;
        }
        return (self.toLinear(v) - lmin) / span;
    }

    /// [0,1] fraction -> data value (inverse of `dataToFraction`).
    pub fn fractionToData(self: Axis, t: f64) f64 {
        const lmin: f64 = self.toLinear(self.range.min);
        const lmax: f64 = self.toLinear(self.range.max);
        return self.fromLinear(lmin + t * (lmax - lmin));
    }

    /// New range after zooming about `anchor` by `factor`, computed in the
    /// scale's layout space so log/symlog/custom zoom uniformly on screen.
    pub fn zoomedRange(self: Axis, anchor: f64, factor: f64) DataRange {
        const c: f64 = self.toLinear(anchor);
        const a: f64 = self.toLinear(self.range.min);
        const b: f64 = self.toLinear(self.range.max);
        return .{
            .min = self.fromLinear(c + (a - c) * factor),
            .max = self.fromLinear(c + (b - c) * factor),
        };
    }

    pub fn plotToPixel(self: Axis, v: f64) f32 {
        const t: f32 = @floatCast(self.dataToFraction(v));
        return lerpV(self.px_min, self.px_max, t);
    }

    pub fn pixelToPlot(self: Axis, px: f32) f64 {
        const span: f32 = self.px_max - self.px_min;
        if (span == 0) {
            return self.range.min;
        }
        const t: f64 = @floatCast((px - self.px_min) / span);
        return self.fractionToData(t);
    }
};

// ============================================================================
// [SECTION] Ticks — port of ImPlot's Locator_Default (Heckbert nice nums)
// ============================================================================

pub const Tick = struct {
    value: f64,
    px: f32,
    label: []const u8, // points into the owning Ticker's text buffer ("" for minors)
    major: bool = true,
};

/// Headroom for majors + their minor subdivisions.
pub const max_ticks = 64;
/// Minor subdivisions per major interval (ImPlot's Locator uses 10; 5 reads
/// cleaner). `minor_per_major - 1` minor ticks sit between each major.
const minor_per_major: u32 = 5;

fn decimalsFor(interval: f64) u8 {
    if (interval <= 0 or !zm.isFinite(interval)) {
        return 0;
    }
    const e: f64 = @floor(log10(interval));
    if (e >= 0) {
        return 0;
    }
    const d: f64 = -e;
    return floori(u8, @min(d, 8.0));
}

/// Snap a rough seconds-per-tick to a calendar-friendly step.
fn niceTimeStep(rough: f64) f64 {
    const steps = [_]f64{
        1,      2,      5,       10,      15,       30,
        60,     120,    300,     600,     900,      1800,
        3600,   7200,   10800,   21600,   43200,    86400,
        172800, 604800, 2592000, 7776000, 31536000,
    };
    for (steps) |s| {
        if (s >= rough) {
            return s;
        }
    }
    return steps[steps.len - 1];
}

/// Label granularity for a time axis, chosen from the tick step.
const TimeFmt = enum { hms, hm, md, year };

fn timeFmtKind(step: f64) TimeFmt {
    if (step < 60) {
        return .hms;
    }
    if (step < 86400) {
        return .hm;
    }
    if (step < 2592000) {
        return .md;
    }
    return .year;
}

/// Broken-down UTC time from epoch seconds (Hinnant's days->civil algorithm,
/// integer-only so it stays out of `std.math`).
const DateParts = struct { year: i64, month: i64, day: i64, hour: i64, min: i64, sec: i64 };

fn civilFromEpoch(secs: i64) DateParts {
    const days: i64 = @divFloor(secs, 86400);
    const sod: i64 = secs - days * 86400;
    const z: i64 = days + 719468;
    const era: i64 = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy: i64 = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp: i64 = @divTrunc(5 * doy + 2, 153);
    const day: i64 = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const month: i64 = if (mp < 10) mp + 3 else mp - 9;
    const year: i64 = yoe + era * 400 + (if (month <= 2) @as(i64, 1) else 0);
    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = @divTrunc(sod, 3600),
        .min = @divTrunc(@mod(sod, 3600), 60),
        .sec = @mod(sod, 60),
    };
}

const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

fn formatTime(buf: []u8, secs: f64, kind: TimeFmt) []const u8 {
    const isecs: i64 = @round(secs);
    const d: DateParts = civilFromEpoch(isecs);
    const mi: usize = @intCast(@mod(d.month - 1, 12));
    const hh: u64 = @intCast(d.hour);
    const mm: u64 = @intCast(d.min);
    const ss: u64 = @intCast(d.sec);
    const dd: u64 = @intCast(d.day);
    return switch (kind) {
        .hms => bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }) catch "",
        .hm => bufPrint(buf, "{d:0>2}:{d:0>2}", .{ hh, mm }) catch "",
        .md => bufPrint(buf, "{s} {d:0>2}", .{ month_names[mi], dd }) catch "",
        .year => bufPrint(buf, "{d}", .{d.year}) catch "",
    };
}

pub const Ticker = struct {
    ticks: [max_ticks]Tick = undefined,
    count: usize = 0,
    text: [max_ticks * 24]u8 = undefined,
    text_len: usize = 0,
    interval: f64 = 1,
    fmt: NumberFormat = .auto,

    /// Generate "nice" major ticks for `axis` over its current range.
    /// `pixels` is the axis length in screen px (drives tick density).
    pub fn generate(self: *Ticker, axis: Axis, pixels: f32, vertical: bool) void {
        self.count = 0;
        self.text_len = 0;
        self.fmt = axis.format;
        const range: DataRange = axis.range;
        if (range.size() == 0 or !zm.isFinite(range.size())) {
            return;
        }
        if (axis.custom_ticks) |cticks| {
            self.generateCustom(axis, cticks);
            return;
        }
        if (axis.scale == .log10) {
            self.generateLog(axis);
            return;
        }
        if (axis.scale == .time) {
            self.generateTime(axis, pixels, vertical);
            return;
        }
        if (axis.scale == .symlog) {
            self.generateSymlog(axis);
            return;
        }
        // ImPlot targets ~1 major per 400px (h) / 300px (v).
        const target_px: f32 = if (vertical) 300.0 else 400.0;
        const n_major: f64 = @max(2.0, @round(pixels / target_px));
        const nice_range: f64 = niceNum(f64, range.size() * 0.99, false);
        const interval: f64 = niceNum(f64, nice_range / (n_major - 1.0), true);
        self.interval = interval;
        const graph_min: f64 = @floor(range.min / interval) * interval;
        const graph_max: f64 = @ceil(range.max / interval) * interval;

        const decimals: u8 = decimalsFor(interval);
        var major: f64 = graph_min;
        // `+ 0.5*interval` mirrors ImPlot's inclusive upper bound.
        while (major < graph_max + 0.5 * interval) : (major += interval) {
            var m: f64 = major;
            // Combat "-0" / FP fuzz straddling zero.
            if (m - interval < 0 and m + interval > 0) {
                m = 0;
            }
            // Major tick: gridline + tick mark + label.
            if (range.contains(m) and self.count < max_ticks) {
                const label: []const u8 = self.writeLabel(m, decimals);
                self.ticks[self.count] = .{ .value = m, .px = axis.plotToPixel(m), .label = label, .major = true };
                self.count += 1;
            }
            // Minor ticks: faint gridline only, no label. Based off the raw
            // (un-snapped) major so spacing stays uniform, and added even when
            // the parent major falls outside the range so the edges fill in.
            var i: u32 = 1;
            while (i < minor_per_major) : (i += 1) {
                const frac: f64 = float64(i) / float64(minor_per_major);
                const minor: f64 = major + frac * interval;
                if (range.contains(minor) and self.count < max_ticks) {
                    const px: f32 = axis.plotToPixel(minor);
                    self.ticks[self.count] = .{ .value = minor, .px = px, .label = "", .major = false };
                    self.count += 1;
                }
            }
        }
    }

    /// Logarithmic ticks: majors at each power of ten in range (labeled),
    /// minors at 2..9 x that power (faint, unlabeled). ImPlot's Locator_Log10.
    fn generateLog(self: *Ticker, axis: Axis) void {
        const range: DataRange = axis.range;
        const lo: f64 = @max(range.min, 1e-300);
        const hi: f64 = @max(range.max, lo * 10.0);
        const log_lo: f64 = log10(lo);
        const log_hi: f64 = log10(hi);
        const exp_min: i32 = @floor(log_lo);
        const exp_max: i32 = @ceil(log_hi);
        // Thin the decades if there would be too many labeled powers.
        var step: i32 = 1;
        while (@divTrunc(exp_max - exp_min, step) > @as(i32, max_ticks / 4)) {
            step += 1;
        }
        self.interval = 1;
        var e: i32 = exp_min;
        while (e <= exp_max) : (e += step) {
            const base: f64 = exp10(float64(e));
            if (range.contains(base) and self.count < max_ticks) {
                const decimals: u8 = if (e < 0) @intCast(-e) else 0;
                const label: []const u8 = self.writeLabel(base, decimals);
                const px: f32 = axis.plotToPixel(base);
                self.ticks[self.count] = .{ .value = base, .px = px, .label = label, .major = true };
                self.count += 1;
            }
            // Minor decade subdivisions 2..9 (only when not thinning decades).
            if (step == 1) {
                var k: u32 = 2;
                while (k < 10) : (k += 1) {
                    const minor: f64 = base * float64(k);
                    if (range.contains(minor) and self.count < max_ticks) {
                        const px: f32 = axis.plotToPixel(minor);
                        self.ticks[self.count] = .{ .value = minor, .px = px, .label = "", .major = false };
                        self.count += 1;
                    }
                }
            }
        }
    }

    fn writeLabel(self: *Ticker, value: f64, decimals: u8) []const u8 {
        const start: usize = self.text_len;
        const avail: []u8 = self.text[start..];
        const s: []const u8 = formatNumber(avail, value, decimals, self.fmt);
        self.text_len += s.len;
        return s;
    }

    /// Copy a prebuilt label into the text buffer and return the stored slice.
    fn writeRaw(self: *Ticker, s: []const u8) []const u8 {
        const start: usize = self.text_len;
        const n: usize = @min(s.len, self.text.len - start);
        @memcpy(self.text[start .. start + n], s[0..n]);
        self.text_len += n;
        return self.text[start .. start + n];
    }

    /// Time axis: pick a calendar-friendly step and format date/time labels.
    /// Values are epoch seconds (f64); the transform stays linear.
    fn generateTime(self: *Ticker, axis: Axis, pixels: f32, vertical: bool) void {
        const range: DataRange = axis.range;
        const target_px: f32 = if (vertical) 90.0 else 150.0;
        const n_major: f64 = @max(2.0, @round(pixels / target_px));
        const step: f64 = niceTimeStep(range.size() / n_major);
        self.interval = step;
        const kind: TimeFmt = timeFmtKind(step);
        const start: f64 = @floor(range.min / step) * step;
        var t: f64 = start;
        var guard: usize = 0;
        while (t < range.max + step and self.count < max_ticks and guard < 2000) : (t += step) {
            guard += 1;
            if (range.contains(t)) {
                var buf: [24]u8 = undefined;
                const lbl: []const u8 = formatTime(&buf, t, kind);
                const stored: []const u8 = self.writeRaw(lbl);
                self.ticks[self.count] = .{ .value = t, .px = axis.plotToPixel(t), .label = stored, .major = true };
                self.count += 1;
            }
        }
    }

    pub fn slice(self: *const Ticker) []const Tick {
        return self.ticks[0..self.count];
    }

    /// Symlog ticks: zero, ±linthresh, and ±linthresh·10^k within range.
    fn generateSymlog(self: *Ticker, axis: Axis) void {
        const range: DataRange = axis.range;
        const lt: f64 = axis.linthresh;
        assertf(lt > 0, @src(), "symlog linthresh must be > 0, got {d}", .{lt});
        const decimals: u8 = decimalsFor(lt);
        if (range.contains(0)) {
            self.pushTick(axis, 0, decimals);
        }
        const max_abs: f64 = @max(@abs(range.min), @abs(range.max));
        var k: i32 = 0;
        while (k <= 30) : (k += 1) {
            const v: f64 = lt * exp10(float64(k));
            if (v > max_abs * 1.0001) {
                break;
            }
            if (range.contains(v)) {
                self.pushTick(axis, v, decimals);
            }
            if (range.contains(-v)) {
                self.pushTick(axis, -v, decimals);
            }
        }
    }

    /// Append one labeled major tick for `value`.
    fn pushTick(self: *Ticker, axis: Axis, value: f64, decimals: u8) void {
        if (self.count >= max_ticks) {
            return;
        }
        const label: []const u8 = self.writeLabel(value, decimals);
        self.ticks[self.count] = .{ .value = value, .px = axis.plotToPixel(value), .label = label, .major = true };
        self.count += 1;
    }

    /// Explicit caller-supplied ticks (optionally with parallel labels).
    fn generateCustom(self: *Ticker, axis: Axis, cticks: []const f64) void {
        if (axis.custom_labels) |labs| {
            assertf(labs.len >= cticks.len, @src(), "custom_labels {d} < custom_ticks {d}", .{ labs.len, cticks.len });
        }
        const dec: u8 = if (cticks.len >= 2) decimalsFor(@abs(cticks[1] - cticks[0])) else 2;
        for (cticks, 0..) |v, i| {
            if (self.count >= max_ticks or !axis.range.contains(v)) {
                continue;
            }
            const label: []const u8 = if (axis.custom_labels) |labs|
                (if (i < labs.len) self.writeRaw(labs[i]) else self.writeLabel(v, dec))
            else
                self.writeLabel(v, dec);
            self.ticks[self.count] = .{ .value = v, .px = axis.plotToPixel(v), .label = label, .major = true };
            self.count += 1;
        }
    }
};

// ============================================================================
// [SECTION] Plot — the rendering core
// ============================================================================

fn padRange(r: DataRange) DataRange {
    if (r.size() == 0) {
        const pad: f64 = if (r.min == 0) 0.5 else @abs(r.min) * 0.1;
        return .{ .min = r.min - pad, .max = r.max + pad };
    }
    const pad: f64 = r.size() * 0.05;
    return .{ .min = r.min - pad, .max = r.max + pad };
}

/// Crude monospace-ish width estimate for layout (host SVG has no font
/// metrics). The `ui` adapter will use real `measureText`.
pub fn textWidth(s: []const u8, size: f32) f32 {
    return float(s.len) * size * 0.55;
}

/// Center + radius (px) + angle (rad) -> a pixel point on the circle.
fn polar(center: Vec2, r: f32, ang: f64) Vec2 {
    return .{
        center[0] + r * @as(f32, @floatCast(@cos(ang))),
        center[1] + r * @as(f32, @floatCast(@sin(ang))),
    };
}

pub const Plot = struct {
    x: Axis = .{},
    y: Axis = .{},
    /// Optional secondary Y axis (right side), with its own range/ticks.
    y2: Axis = .{},
    y2_enabled: bool = false,
    /// Optional secondary X axis (top side), with its own range/ticks.
    x2: Axis = .{},
    x2_enabled: bool = false,
    /// Inner data area in screen pixels (inside the tick gutters).
    area: Rect = .{},
    title: ?[]const u8 = null,
    series_count: usize = 0,
    x_ticks: Ticker = .{},
    y_ticks: Ticker = .{},
    y2_ticks: Ticker = .{},
    x2_ticks: Ticker = .{},
    /// Chrome theming (defaults to the built-in dark theme).
    style: Style = .{},

    /// Lay an axis frame inside `frame`, reserving gutters for ticks and
    /// labels. Wires axis pixel endpoints (Y flips here, once).
    pub fn layout(self: *Plot, frame: Rect) void {
        // Reserve extra gutter room when an axis label is shown.
        const left_gutter: f32 = if (self.y.label != null) 60 else 48;
        const bottom_gutter: f32 = if (self.x.label != null) 44 else 28;
        const base_top: f32 = if (self.title != null) 22 else 8;
        // A secondary top X axis adds its own gutter above the plot (ticks +
        // optional label), stacked under the title. Disabled => unchanged.
        const x2_pad: f32 = if (self.x2_enabled)
            (if (self.x2.label != null) 34 else 20)
        else
            0;
        const top_gutter: f32 = base_top + x2_pad;
        const right_pad: f32 = if (self.y2_enabled)
            (if (self.y2.label != null) 60 else 48)
        else
            10;
        self.area = .{
            .x = frame.x + left_gutter,
            .y = frame.y + top_gutter,
            .w = frame.w - left_gutter - right_pad,
            .h = frame.h - top_gutter - bottom_gutter,
        };
        self.x.px_min = self.area.x;
        self.x.px_max = self.area.right();
        if (self.x.flags.invert) {
            std.mem.swap(f32, &self.x.px_min, &self.x.px_max);
        }
        // Y: data-min at the bottom, data-max at the top (screen +y down).
        self.y.px_min = self.area.bottom();
        self.y.px_max = self.area.y;
        if (self.y.flags.invert) {
            std.mem.swap(f32, &self.y.px_min, &self.y.px_max);
        }
        self.x_ticks.generate(self.x, self.area.w, false);
        self.y_ticks.generate(self.y, self.area.h, true);
        if (self.y2_enabled) {
            self.y2.px_min = self.area.bottom();
            self.y2.px_max = self.area.y;
            if (self.y2.flags.invert) {
                std.mem.swap(f32, &self.y2.px_min, &self.y2.px_max);
            }
            self.y2_ticks.generate(self.y2, self.area.h, true);
        }
        if (self.x2_enabled) {
            self.x2.px_min = self.area.x;
            self.x2.px_max = self.area.right();
            if (self.x2.flags.invert) {
                std.mem.swap(f32, &self.x2.px_min, &self.x2.px_max);
            }
            self.x2_ticks.generate(self.x2, self.area.w, false);
        }
    }

    /// Auto-fit both axes to the given series extents (call before layout).
    pub fn fit(self: *Plot, xs: []const f64, ys: []const f64) void {
        var xr: DataRange = .{ .min = inf(f64), .max = -inf(f64) };
        var yr: DataRange = .{ .min = inf(f64), .max = -inf(f64) };
        for (xs) |v| {
            xr.expand(v);
        }
        for (ys) |v| {
            yr.expand(v);
        }
        if (xr.min <= xr.max) {
            self.x.range = padRange(xr);
        }
        if (yr.min <= yr.max) {
            self.y.range = padRange(yr);
        }
    }

    fn project(self: Plot, x: f64, y: f64) Vec2 {
        return .{ self.x.plotToPixel(x), self.y.plotToPixel(y) };
    }

    pub fn drawFrame(self: *const Plot, sink: anytype) void {
        sink.fillRect(self.area, self.style.bg);
        // Grid: minor lines faint, major lines brighter.
        if (!self.x.flags.no_grid) {
            for (self.x_ticks.slice()) |t| {
                const gc: Color = if (t.major) self.style.grid else self.style.minor_grid;
                sink.line(.{ t.px, self.area.y }, .{ t.px, self.area.bottom() }, .{ .color = gc, .thickness = 1.0 });
            }
        }
        if (!self.y.flags.no_grid) {
            for (self.y_ticks.slice()) |t| {
                const gc: Color = if (t.major) self.style.grid else self.style.minor_grid;
                sink.line(.{ self.area.x, t.px }, .{ self.area.right(), t.px }, .{ .color = gc, .thickness = 1.0 });
            }
        }
    }

    pub fn drawDecorations(self: *const Plot, sink: anytype) void {
        // Border.
        const a: Vec2 = .{ self.area.x, self.area.y };
        const b: Vec2 = .{ self.area.right(), self.area.y };
        const c: Vec2 = .{ self.area.right(), self.area.bottom() };
        const d: Vec2 = .{ self.area.x, self.area.bottom() };
        const bc: Color = self.style.border;
        const tc: Color = self.style.text;
        sink.line(a, b, .{ .color = bc, .thickness = 1.0 });
        sink.line(b, c, .{ .color = bc, .thickness = 1.0 });
        sink.line(c, d, .{ .color = bc, .thickness = 1.0 });
        sink.line(d, a, .{ .color = bc, .thickness = 1.0 });
        // Tick marks + labels (majors only).
        if (!self.x.flags.no_tick_labels) {
            for (self.x_ticks.slice()) |t| {
                if (!t.major) {
                    continue;
                }
                sink.line(
                    .{ t.px, self.area.bottom() },
                    .{ t.px, self.area.bottom() + 4 },
                    .{ .color = bc, .thickness = 1.0 },
                );
                const tw: f32 = textWidth(t.label, 12);
                sink.text(.{ t.px - tw * 0.5, self.area.bottom() + 6 }, t.label, .{ .size = 12, .color = tc });
            }
        }
        if (!self.y.flags.no_tick_labels) {
            for (self.y_ticks.slice()) |t| {
                if (!t.major) {
                    continue;
                }
                sink.line(.{ self.area.x - 4, t.px }, .{ self.area.x, t.px }, .{ .color = bc, .thickness = 1.0 });
                const tw: f32 = textWidth(t.label, 12);
                sink.text(.{ self.area.x - 7 - tw, t.px - 6 }, t.label, .{ .size = 12, .color = tc });
            }
        }
        if (self.y2_enabled and !self.y2.flags.no_tick_labels) {
            for (self.y2_ticks.slice()) |t| {
                if (!t.major) {
                    continue;
                }
                sink.line(
                    .{ self.area.right(), t.px },
                    .{ self.area.right() + 4, t.px },
                    .{ .color = bc, .thickness = 1.0 },
                );
                sink.text(.{ self.area.right() + 7, t.px - 6 }, t.label, .{ .size = 12, .color = tc });
            }
            if (self.y2.label) |yl| {
                const tw: f32 = textWidth(yl, 12);
                sink.text(.{ self.area.right() - tw - 2, self.area.y - 16 }, yl, .{ .size = 12, .color = tc });
            }
        }
        if (self.x2_enabled and !self.x2.flags.no_tick_labels) {
            for (self.x2_ticks.slice()) |t| {
                if (!t.major) {
                    continue;
                }
                sink.line(.{ t.px, self.area.y }, .{ t.px, self.area.y - 4 }, .{ .color = bc, .thickness = 1.0 });
                const tw: f32 = textWidth(t.label, 12);
                sink.text(.{ t.px - tw * 0.5, self.area.y - 16 }, t.label, .{ .size = 12, .color = tc });
            }
            if (self.x2.label) |xl| {
                const tw: f32 = textWidth(xl, 12);
                sink.text(
                    .{ self.area.x + (self.area.w - tw) * 0.5, self.area.y - 30 },
                    xl,
                    .{ .size = 12, .color = tc },
                );
            }
        }
        if (self.title) |ttl| {
            const tw: f32 = textWidth(ttl, 14);
            // Stack above the x2 axis (label, then ticks) so nothing overlaps.
            const ty: f32 = if (self.x2_enabled)
                (if (self.x2.label != null) self.area.y - 44 else self.area.y - 30)
            else
                self.area.y - 18;
            sink.text(.{ self.area.x + (self.area.w - tw) * 0.5, ty }, ttl, .{ .size = 14, .color = tc });
        }
        // Axis labels: x centered below its tick labels, y at the top-left
        // of the axis (horizontal — the draw list has no rotated text).
        if (self.x.label) |xl| {
            const tw: f32 = textWidth(xl, 12);
            sink.text(
                .{ self.area.x + (self.area.w - tw) * 0.5, self.area.bottom() + 26 },
                xl,
                .{ .size = 12, .color = tc },
            );
        }
        if (self.y.label) |yl| {
            sink.text(.{ self.area.x + 2, self.area.y - 16 }, yl, .{ .size = 12, .color = tc });
        }
    }

    /// Draw a legend box (top-right, inside the plot area): one row per entry,
    /// a colored swatch + its label. No-op for an empty list.
    /// Compute the legend box + row metrics for a corner location. Used by
    /// both `drawLegendEx` (to draw) and the UI layer (to hit-test clicks).
    pub fn legendLayout(
        self: *const Plot,
        entries: []const LegendEntry,
        location: LegendLocation,
        horizontal: bool,
    ) LegendLayout {
        const row_h: f32 = 16;
        const pady: f32 = 4;
        const inset: f32 = 6;
        const swatch: f32 = 10;
        const padx: f32 = 6;
        const gap: f32 = 5;
        var max_tw: f32 = 0;
        for (entries) |e| {
            const tw: f32 = textWidth(e.label, 12);
            if (tw > max_tw) {
                max_tw = tw;
            }
        }
        const n_f: f32 = float(entries.len);
        // Horizontal: one row of uniform cells. Vertical: a column of rows.
        const cell_w: f32 = swatch + gap + max_tw + 12;
        const box_w: f32 = if (horizontal)
            padx * 2 + cell_w * n_f
        else
            padx * 2 + swatch + gap + max_tw;
        const box_h: f32 = if (horizontal)
            pady * 2 + row_h
        else
            pady * 2 + row_h * n_f;
        const left: f32 = self.area.x + inset;
        const right: f32 = self.area.right() - box_w - inset;
        const top: f32 = self.area.y + inset;
        const bottom: f32 = self.area.bottom() - box_h - inset;
        const box_x: f32 = switch (location) {
            .nw, .sw => left,
            .ne, .se => right,
        };
        const box_y: f32 = switch (location) {
            .nw, .ne => top,
            .sw, .se => bottom,
        };
        return .{
            .box = .{ .x = box_x, .y = box_y, .w = box_w, .h = box_h },
            .row_h = row_h,
            .pad_y = pady,
            .n = entries.len,
            .horizontal = horizontal,
            .cell_w = cell_w,
            .pad_x = padx,
        };
    }

    /// Draw a legend using a precomputed layout. `hidden[i]` (when provided)
    /// dims row i to signal a toggled-off series.
    pub fn drawLegendEx(
        self: *const Plot,
        sink: anytype,
        entries: []const LegendEntry,
        lay: LegendLayout,
        hidden: ?[]const bool,
    ) void {
        if (entries.len == 0) {
            return;
        }
        const swatch: f32 = 10;
        const padx: f32 = 6;
        const gap: f32 = 5;
        const b: Rect = lay.box;
        const dim: Color = .{ .r = 120, .g = 120, .b = 130, .a = 255 };
        const bc: Color = self.style.border;
        sink.fillRect(b, self.style.legend_bg);
        sink.line(.{ b.x, b.y }, .{ b.x + b.w, b.y }, .{ .color = bc, .thickness = 1.0 });
        sink.line(.{ b.x, b.y + b.h }, .{ b.x + b.w, b.y + b.h }, .{ .color = bc, .thickness = 1.0 });
        sink.line(.{ b.x, b.y }, .{ b.x, b.y + b.h }, .{ .color = bc, .thickness = 1.0 });
        sink.line(.{ b.x + b.w, b.y }, .{ b.x + b.w, b.y + b.h }, .{ .color = bc, .thickness = 1.0 });
        for (entries, 0..) |e, i| {
            const off: bool = if (hidden) |h| (i < h.len and h[i]) else false;
            const sw_col: Color = if (off) e.color.alpha(0.3) else e.color;
            const tx_col: Color = if (off) dim else self.style.text;
            const i_f: f32 = float(i);
            if (lay.horizontal) {
                const cx: f32 = b.x + padx + lay.cell_w * i_f;
                const cy: f32 = b.y + lay.pad_y;
                const sy: f32 = cy + (lay.row_h - swatch) * 0.5;
                sink.fillRect(.{ .x = cx, .y = sy, .w = swatch, .h = swatch }, sw_col);
                sink.text(.{ cx + swatch + gap, cy + 2 }, e.label, .{ .size = 12, .color = tx_col });
            } else {
                const ry: f32 = b.y + lay.pad_y + lay.row_h * i_f;
                const sy: f32 = ry + (lay.row_h - swatch) * 0.5;
                sink.fillRect(.{ .x = b.x + padx, .y = sy, .w = swatch, .h = swatch }, sw_col);
                sink.text(.{ b.x + padx + swatch + gap, ry + 2 }, e.label, .{ .size = 12, .color = tx_col });
            }
        }
    }

    /// Simple legend at the top-right, all entries visible.
    pub fn drawLegend(
        self: *const Plot,
        sink: anytype,
        entries: []const LegendEntry,
    ) void {
        self.drawLegendEx(sink, entries, self.legendLayout(entries, .ne, false), null);
    }

    pub fn plotLine(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        spec: LineSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const n: usize = sampleCount(xs, ys);
        if (!spec.markers_only and n >= 2) {
            // A non-finite (NaN/inf) sample breaks the line: we drop `have_prev`
            // so the next finite point starts a fresh segment (a visible gap),
            // matching ImPlot's missing-data behavior.
            var prev: Vec2 = undefined;
            var have_prev: bool = false;
            for (0..n) |i| {
                const xv: f64 = xCoord(xs, i);
                if (finite2(xv, ys[i])) {
                    const cur: Vec2 = self.project(xv, ys[i]);
                    if (have_prev) {
                        sink.line(prev, cur, .{ .color = col, .thickness = spec.thickness });
                    }
                    prev = cur;
                    have_prev = true;
                } else {
                    have_prev = false;
                }
            }
        }
        if (spec.marker != .none) {
            for (0..n) |i| {
                const xv: f64 = xCoord(xs, i);
                if (finite2(xv, ys[i])) {
                    self.drawMarker(sink, self.project(xv, ys[i]), spec.marker, spec.marker_size, col);
                }
            }
        }
    }

    pub fn plotScatter(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        spec: LineSpec,
    ) void {
        var s: LineSpec = spec;
        s.markers_only = true;
        if (s.marker == .none) {
            s.marker = .circle;
        }
        self.plotLine(sink, xs, ys, s);
    }

    pub fn plotBars(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        spec: BarsSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const n: usize = @min(xs.len, ys.len);
        if (n == 0) {
            return;
        }
        if (spec.horizontal) {
            const slot: f64 = if (n >= 2) @abs(ys[1] - ys[0]) else 1.0;
            const half: f64 = slot * spec.width * 0.5;
            const base_px: f32 = self.x.plotToPixel(self.x.range.clampValue(0));
            for (0..n) |i| {
                const b: f32 = self.y.plotToPixel(ys[i] - half);
                const t: f32 = self.y.plotToPixel(ys[i] + half);
                const vx: f32 = self.x.plotToPixel(xs[i]);
                const x0: f32 = @min(vx, base_px);
                const y0: f32 = @min(b, t);
                sink.fillRect(.{ .x = x0, .y = y0, .w = @abs(vx - base_px), .h = @abs(t - b) }, col);
                if (spec.show_labels) {
                    var buf: [24]u8 = undefined;
                    const s: []const u8 = formatNumber(&buf, xs[i], spec.label_decimals, spec.label_format);
                    const cy: f32 = (b + t) * 0.5 - 5;
                    const tx: f32 = if (vx >= base_px) vx + 4 else vx - 4 - textWidth(s, 11);
                    sink.text(.{ tx, cy }, s, .{ .size = 11, .color = label_color });
                }
            }
            return;
        }
        // Slot width from median neighbour spacing (uniform data assumed).
        const slot: f64 = if (n >= 2) @abs(xs[1] - xs[0]) else 1.0;
        const half: f64 = slot * spec.width * 0.5;
        const base_px: f32 = self.y.plotToPixel(self.y.range.clampValue(0));
        for (0..n) |i| {
            const l: f32 = self.x.plotToPixel(xs[i] - half);
            const r: f32 = self.x.plotToPixel(xs[i] + half);
            const top: f32 = self.y.plotToPixel(ys[i]);
            const x0: f32 = @min(l, r);
            const y0: f32 = @min(top, base_px);
            sink.fillRect(.{ .x = x0, .y = y0, .w = @abs(r - l), .h = @abs(base_px - top) }, col);
            if (spec.show_labels) {
                var buf: [24]u8 = undefined;
                const s: []const u8 = formatNumber(&buf, ys[i], spec.label_decimals, spec.label_format);
                const cx: f32 = (l + r) * 0.5;
                const above: bool = top <= base_px;
                const ty: f32 = if (above) top - 15 else top + 3;
                sink.text(.{ cx - textWidth(s, 11) * 0.5, ty }, s, .{ .size = 11, .color = label_color });
            }
        }
    }

    /// Filled area between `ys` and the `spec.y_ref` baseline — two triangles
    /// per segment. ImPlot's PlotShaded (baseline variant).
    pub fn plotShaded(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        spec: ShadedSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const n: usize = sampleCount(xs, ys);
        if (n < 2) {
            return;
        }
        const yref: f32 = self.y.plotToPixel(spec.y_ref);
        var i: usize = 0;
        while (i + 1 < n) : (i += 1) {
            const xa: f64 = xCoord(xs, i);
            const xb: f64 = xCoord(xs, i + 1);
            if (!finite2(xa, ys[i]) or !finite2(xb, ys[i + 1])) {
                continue;
            }
            const x0: f32 = self.x.plotToPixel(xa);
            const x1: f32 = self.x.plotToPixel(xb);
            const y0: f32 = self.y.plotToPixel(ys[i]);
            const y1: f32 = self.y.plotToPixel(ys[i + 1]);
            sink.triangleFilled(.{ x0, y0 }, .{ x1, y1 }, .{ x1, yref }, col);
            sink.triangleFilled(.{ x0, y0 }, .{ x1, yref }, .{ x0, yref }, col);
        }
    }

    /// Fill the band between two y-series over shared `xs` (ImPlot's two-arg
    /// PlotShaded). `spec.y_ref` is ignored.
    pub fn plotShadedBetween(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys1: []const f64,
        ys2: []const f64,
        spec: ShadedSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const n: usize = @min(xs.len, @min(ys1.len, ys2.len));
        if (n < 2) {
            return;
        }
        var i: usize = 0;
        while (i + 1 < n) : (i += 1) {
            const ax: f32 = self.x.plotToPixel(xs[i]);
            const bx: f32 = self.x.plotToPixel(xs[i + 1]);
            const a1: f32 = self.y.plotToPixel(ys1[i]);
            const b1: f32 = self.y.plotToPixel(ys1[i + 1]);
            const a2: f32 = self.y.plotToPixel(ys2[i]);
            const b2: f32 = self.y.plotToPixel(ys2[i + 1]);
            sink.triangleFilled(.{ ax, a1 }, .{ bx, b1 }, .{ bx, b2 }, col);
            sink.triangleFilled(.{ ax, a1 }, .{ bx, b2 }, .{ ax, a2 }, col);
        }
    }

    /// Clustered (default) or stacked bar groups. `values` is row-major
    /// item-major: `values[item * group_count + group]`. Groups at x=0,1,...
    pub fn plotBarGroups(
        self: *Plot,
        sink: anytype,
        values: []const f64,
        item_count: usize,
        group_count: usize,
        spec: BarGroupsSpec,
    ) void {
        if (item_count == 0 or group_count == 0) {
            return;
        }
        assertf(
            values.len >= item_count * group_count,
            @src(),
            "plotBarGroups: values.len {d} < item*group {d}",
            .{ values.len, item_count * group_count },
        );
        const gw: f64 = spec.width;
        const base_px: f32 = self.y.plotToPixel(self.y.range.clampValue(0));
        if (spec.stacked) {
            for (0..group_count) |g| {
                var acc_pos: f64 = 0;
                var acc_neg: f64 = 0;
                const cx: f64 = float64(g);
                const l: f32 = self.x.plotToPixel(cx - gw * 0.5);
                const r: f32 = self.x.plotToPixel(cx + gw * 0.5);
                for (0..item_count) |j| {
                    const v: f64 = values[j * group_count + g];
                    const col: Color = if (spec.colors) |cs| cs[j % cs.len] else autoColor(j);
                    var y_from: f64 = acc_pos;
                    var y_to: f64 = acc_pos;
                    if (v >= 0) {
                        y_from = acc_pos;
                        y_to = acc_pos + v;
                        acc_pos = y_to;
                    } else {
                        y_from = acc_neg;
                        y_to = acc_neg + v;
                        acc_neg = y_to;
                    }
                    const pf: f32 = self.y.plotToPixel(y_from);
                    const pt: f32 = self.y.plotToPixel(y_to);
                    sink.fillRect(.{ .x = @min(l, r), .y = @min(pf, pt), .w = @abs(r - l), .h = @abs(pt - pf) }, col);
                }
            }
        } else {
            const bw: f64 = gw / float64(item_count);
            for (0..group_count) |g| {
                for (0..item_count) |j| {
                    const v: f64 = values[j * group_count + g];
                    const col: Color = if (spec.colors) |cs| cs[j % cs.len] else autoColor(j);
                    const cx: f64 = float64(g) - gw * 0.5 + bw * (float64(j) + 0.5);
                    const l: f32 = self.x.plotToPixel(cx - bw * 0.5);
                    const r: f32 = self.x.plotToPixel(cx + bw * 0.5);
                    const top: f32 = self.y.plotToPixel(v);
                    sink.fillRect(.{
                        .x = @min(l, r),
                        .y = @min(top, base_px),
                        .w = @abs(r - l),
                        .h = @abs(base_px - top),
                    }, col);
                }
            }
        }
        self.series_count += item_count;
    }

    /// Step line: hold each `ys[i]` until the next x, then step (post-step).
    /// ImPlot's PlotStairs. Honors `spec.color`/`spec.thickness`.
    pub fn plotStairs(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        spec: LineSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const n: usize = sampleCount(xs, ys);
        if (n < 2) {
            return;
        }
        var i: usize = 0;
        while (i + 1 < n) : (i += 1) {
            const xa: f64 = xCoord(xs, i);
            const xb: f64 = xCoord(xs, i + 1);
            if (!finite2(xa, ys[i]) or !finite2(xb, ys[i + 1])) {
                continue;
            }
            const x0: f32 = self.x.plotToPixel(xa);
            const x1: f32 = self.x.plotToPixel(xb);
            const y0: f32 = self.y.plotToPixel(ys[i]);
            const y1: f32 = self.y.plotToPixel(ys[i + 1]);
            sink.line(.{ x0, y0 }, .{ x1, y0 }, .{ .color = col, .thickness = spec.thickness });
            sink.line(.{ x1, y0 }, .{ x1, y1 }, .{ .color = col, .thickness = spec.thickness });
        }
    }

    /// Vertical stems from the y=0 baseline to each sample, with a marker on
    /// top (defaults to a circle). Discrete-signal / lollipop style.
    pub fn plotStems(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        spec: LineSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const n: usize = sampleCount(xs, ys);
        if (n == 0) {
            return;
        }
        const base_px: f32 = self.y.plotToPixel(self.y.range.clampValue(0));
        const m: Marker = if (spec.marker == .none) .circle else spec.marker;
        for (0..n) |i| {
            const xv: f64 = xCoord(xs, i);
            if (!finite2(xv, ys[i])) {
                continue;
            }
            const x: f32 = self.x.plotToPixel(xv);
            const top: f32 = self.y.plotToPixel(ys[i]);
            sink.line(.{ x, base_px }, .{ x, top }, .{ .color = col, .thickness = spec.thickness });
            self.drawMarker(sink, .{ x, top }, m, spec.marker_size, col);
        }
    }

    /// Full-extent reference lines at each value: vertical at x=value, or
    /// horizontal at y=value when `spec.horizontal`.
    pub fn plotInfLines(
        self: *Plot,
        sink: anytype,
        values: []const f64,
        spec: InfLinesSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        for (values) |v| {
            if (spec.horizontal) {
                const y: f32 = self.y.plotToPixel(v);
                sink.line(
                    .{ self.area.x, y },
                    .{ self.area.right(), y },
                    .{ .color = col, .thickness = spec.thickness },
                );
            } else {
                const x: f32 = self.x.plotToPixel(v);
                sink.line(
                    .{ x, self.area.y },
                    .{ x, self.area.bottom() },
                    .{ .color = col, .thickness = spec.thickness },
                );
            }
        }
    }

    /// Symmetric vertical error bars: a line from y-err to y+err at each x,
    /// with horizontal end caps.
    pub fn plotErrorBars(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        err: []const f64,
        spec: ErrorBarsSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const dn: usize = @min(xs.len, ys.len);
        assertf(err.len >= dn, @src(), "plotErrorBars: err.len {d} < points {d}", .{ err.len, dn });
        const n: usize = @min(dn, err.len);
        for (0..n) |i| {
            const x: f32 = self.x.plotToPixel(xs[i]);
            const yt: f32 = self.y.plotToPixel(ys[i] + err[i]);
            const yb: f32 = self.y.plotToPixel(ys[i] - err[i]);
            sink.line(.{ x, yt }, .{ x, yb }, .{ .color = col, .thickness = spec.thickness });
            sink.line(.{ x - spec.cap, yt }, .{ x + spec.cap, yt }, .{ .color = col, .thickness = spec.thickness });
            sink.line(.{ x - spec.cap, yb }, .{ x + spec.cap, yb }, .{ .color = col, .thickness = spec.thickness });
        }
    }

    /// Asymmetric vertical error bars: separate `neg`/`pos` magnitudes per
    /// sample (the bar spans y-neg .. y+pos).
    pub fn plotErrorBarsAsym(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        neg: []const f64,
        pos: []const f64,
        spec: ErrorBarsSpec,
    ) void {
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        const dn: usize = @min(xs.len, ys.len);
        assertf(
            neg.len >= dn and pos.len >= dn,
            @src(),
            "plotErrorBarsAsym: neg/pos {d}/{d} < points {d}",
            .{ neg.len, pos.len, dn },
        );
        const n: usize = @min(dn, @min(neg.len, pos.len));
        for (0..n) |i| {
            const x: f32 = self.x.plotToPixel(xs[i]);
            const yt: f32 = self.y.plotToPixel(ys[i] + pos[i]);
            const yb: f32 = self.y.plotToPixel(ys[i] - neg[i]);
            sink.line(.{ x, yt }, .{ x, yb }, .{ .color = col, .thickness = spec.thickness });
            sink.line(.{ x - spec.cap, yt }, .{ x + spec.cap, yt }, .{ .color = col, .thickness = spec.thickness });
            sink.line(.{ x - spec.cap, yb }, .{ x + spec.cap, yb }, .{ .color = col, .thickness = spec.thickness });
        }
    }

    /// Draw free text at a data coordinate.
    pub fn plotText(
        self: *Plot,
        sink: anytype,
        s: []const u8,
        x: f64,
        y: f64,
        spec: TextSpec,
    ) void {
        const col: Color = spec.color orelse text_color;
        const px: f32 = self.x.plotToPixel(x);
        const py: f32 = self.y.plotToPixel(y);
        const tw: f32 = textWidth(s, spec.size);
        const tx: f32 = if (spec.center) px - tw * 0.5 else px;
        sink.text(
            .{ tx + spec.offset[0], py - spec.size * 0.5 + spec.offset[1] },
            s,
            .{ .size = spec.size, .color = col },
        );
    }

    /// A filled text bubble anchored above a data point. Clamped to the plot
    /// area when `spec.clamp`, so it never escapes the axes.
    pub fn annotation(
        self: *Plot,
        sink: anytype,
        s: []const u8,
        x: f64,
        y: f64,
        spec: AnnotationSpec,
    ) void {
        const px: f32 = self.x.plotToPixel(x) + spec.offset[0];
        const py: f32 = self.y.plotToPixel(y) + spec.offset[1];
        const padx: f32 = 5;
        const pady: f32 = 3;
        const bw: f32 = textWidth(s, spec.size) + padx * 2;
        const bh: f32 = spec.size + pady * 2;
        var bx: f32 = px - bw * 0.5;
        var by: f32 = py - bh;
        if (spec.clamp) {
            bx = @max(self.area.x, @min(bx, self.area.right() - bw));
            by = @max(self.area.y, @min(by, self.area.bottom() - bh));
        }
        sink.fillRect(.{ .x = bx, .y = by, .w = bw, .h = bh }, spec.bg);
        sink.text(.{ bx + padx, by + pady }, s, .{ .size = spec.size, .color = spec.text_color });
    }

    /// A tag on the x-axis at `value` (filled box + text just below the axis).
    pub fn tagX(
        self: *Plot,
        sink: anytype,
        value: f64,
        s: []const u8,
        spec: TagSpec,
    ) void {
        const px: f32 = self.x.plotToPixel(value);
        const padx: f32 = 4;
        const pady: f32 = 2;
        const bw: f32 = textWidth(s, spec.size) + padx * 2;
        const bh: f32 = spec.size + pady * 2;
        var bx: f32 = px - bw * 0.5;
        bx = @max(self.area.x, @min(bx, self.area.right() - bw));
        const by: f32 = self.area.bottom() + 2;
        sink.fillRect(.{ .x = bx, .y = by, .w = bw, .h = bh }, spec.bg);
        sink.text(.{ bx + padx, by + pady }, s, .{ .size = spec.size, .color = spec.text_color });
    }

    /// A tag on the y-axis at `value` (filled box + text just left of axis).
    pub fn tagY(
        self: *Plot,
        sink: anytype,
        value: f64,
        s: []const u8,
        spec: TagSpec,
    ) void {
        const py: f32 = self.y.plotToPixel(value);
        const padx: f32 = 4;
        const pady: f32 = 2;
        const bw: f32 = textWidth(s, spec.size) + padx * 2;
        const bh: f32 = spec.size + pady * 2;
        var by: f32 = py - bh * 0.5;
        by = @max(self.area.y, @min(by, self.area.bottom() - bh));
        const bx: f32 = self.area.x - bw - 3;
        sink.fillRect(.{ .x = bx, .y = by, .w = bw, .h = bh }, spec.bg);
        sink.text(.{ bx + padx, by + pady }, s, .{ .size = spec.size, .color = spec.text_color });
    }

    /// Draw a `rows`x`cols` grid (row-major, row 0 at top) of values, each
    /// cell colored by `spec.cmap` over [spec.min, spec.max], tiling the data
    /// rect [x0,x1] x [y0,y1].
    pub fn plotHeatmap(
        self: *Plot,
        sink: anytype,
        values: []const f64,
        rows: usize,
        cols: usize,
        spec: HeatmapSpec,
    ) void {
        assertf(
            values.len >= rows * cols,
            @src(),
            "plotHeatmap: values.len {d} < rows*cols {d}",
            .{ values.len, rows * cols },
        );
        self.series_count += 1;
        if (rows == 0 or cols == 0) {
            return;
        }
        const span: f64 = if (spec.max != spec.min) spec.max - spec.min else 1.0;
        const fc: f64 = float64(cols);
        const fr: f64 = float64(rows);
        for (0..rows) |r| {
            for (0..cols) |c| {
                const v: f64 = values[r * cols + c];
                const t: f32 = @floatCast(clamp((v - spec.min) / span, 0.0, 1.0));
                const col: Color = sampleColormap(spec.cmap, t);
                const cx0: f64 = spec.x0 + (spec.x1 - spec.x0) * float64(c) / fc;
                const cx1: f64 = spec.x0 + (spec.x1 - spec.x0) * float64(c + 1) / fc;
                const ct: f64 = spec.y1 + (spec.y0 - spec.y1) * float64(r) / fr;
                const cb: f64 = spec.y1 + (spec.y0 - spec.y1) * float64(r + 1) / fr;
                const px0: f32 = self.x.plotToPixel(cx0);
                const px1: f32 = self.x.plotToPixel(cx1);
                const pyt: f32 = self.y.plotToPixel(ct);
                const pyb: f32 = self.y.plotToPixel(cb);
                const x: f32 = @min(px0, px1);
                const y: f32 = @min(pyt, pyb);
                sink.fillRect(.{ .x = x, .y = y, .w = @abs(px1 - px0) + 1.0, .h = @abs(pyb - pyt) + 1.0 }, col);
                if (spec.show_labels) {
                    var buf: [24]u8 = undefined;
                    const s: []const u8 = formatNumber(&buf, v, spec.label_decimals, .auto);
                    const lr: f32 = float(col.r);
                    const lg: f32 = float(col.g);
                    const lb: f32 = float(col.b);
                    const lum: f32 = 0.299 * lr + 0.587 * lg + 0.114 * lb;
                    const tc: Color = if (lum > 140)
                        .{ .r = 20, .g = 20, .b = 20, .a = 255 }
                    else
                        .{ .r = 245, .g = 245, .b = 245, .a = 255 };
                    const mcx: f32 = (px0 + px1) * 0.5;
                    const mcy: f32 = (pyt + pyb) * 0.5 - 6;
                    sink.text(.{ mcx - textWidth(s, 10) * 0.5, mcy }, s, .{ .size = 10, .color = tc });
                }
            }
        }
    }

    fn drawMarker(
        self: *const Plot,
        sink: anytype,
        c: Vec2,
        m: Marker,
        size: f32,
        col: Color,
    ) void {
        _ = self;
        const s: f32 = size;
        switch (m) {
            .none => {},
            .circle => sink.circleFilled(c, s, col),
            .square => sink.fillRect(.{ .x = c[0] - s, .y = c[1] - s, .w = 2 * s, .h = 2 * s }, col),
            .diamond => {
                const top: Vec2 = .{ c[0], c[1] - s };
                const right: Vec2 = .{ c[0] + s, c[1] };
                const bottom: Vec2 = .{ c[0], c[1] + s };
                const left: Vec2 = .{ c[0] - s, c[1] };
                sink.triangleFilled(top, right, bottom, col);
                sink.triangleFilled(top, bottom, left, col);
            },
            .triangle_up => sink.triangleFilled(
                .{ c[0], c[1] - s },
                .{ c[0] - s, c[1] + s },
                .{ c[0] + s, c[1] + s },
                col,
            ),
            .triangle_down => sink.triangleFilled(
                .{ c[0], c[1] + s },
                .{ c[0] - s, c[1] - s },
                .{ c[0] + s, c[1] - s },
                col,
            ),
            .triangle_left => sink.triangleFilled(
                .{ c[0] - s, c[1] },
                .{ c[0] + s, c[1] - s },
                .{ c[0] + s, c[1] + s },
                col,
            ),
            .triangle_right => sink.triangleFilled(
                .{ c[0] + s, c[1] },
                .{ c[0] - s, c[1] - s },
                .{ c[0] - s, c[1] + s },
                col,
            ),
            .plus => {
                sink.line(.{ c[0] - s, c[1] }, .{ c[0] + s, c[1] }, .{ .color = col, .thickness = 1.5 });
                sink.line(.{ c[0], c[1] - s }, .{ c[0], c[1] + s }, .{ .color = col, .thickness = 1.5 });
            },
            .cross => {
                sink.line(.{ c[0] - s, c[1] - s }, .{ c[0] + s, c[1] + s }, .{ .color = col, .thickness = 1.5 });
                sink.line(.{ c[0] - s, c[1] + s }, .{ c[0] + s, c[1] - s }, .{ .color = col, .thickness = 1.5 });
            },
            .asterisk => {
                sink.line(.{ c[0] - s, c[1] }, .{ c[0] + s, c[1] }, .{ .color = col, .thickness = 1.5 });
                sink.line(.{ c[0], c[1] - s }, .{ c[0], c[1] + s }, .{ .color = col, .thickness = 1.5 });
                sink.line(.{ c[0] - s, c[1] - s }, .{ c[0] + s, c[1] + s }, .{ .color = col, .thickness = 1.5 });
                sink.line(.{ c[0] - s, c[1] + s }, .{ c[0] + s, c[1] - s }, .{ .color = col, .thickness = 1.5 });
            },
        }
    }

    /// Pie / donut chart of `values` (each >= 0). Center/radius in data coords.
    pub fn plotPie(self: *Plot, sink: anytype, values: []const f64, spec: PieSpec) void {
        assertf(values.len > 0, @src(), "plotPie: need at least one value", .{});
        self.series_count += 1;
        var total: f64 = 0;
        for (values) |v| {
            assertf(v >= 0, @src(), "plotPie: negative value {d}", .{v});
            total += v;
        }
        assertf(total > 0, @src(), "plotPie: values sum to zero", .{});
        const center: Vec2 = .{ self.x.plotToPixel(spec.cx), self.y.plotToPixel(spec.cy) };
        const r_px: f32 = @abs(self.x.plotToPixel(spec.cx + spec.radius) - center[0]);
        const white: Color = .{ .r = 245, .g = 245, .b = 245, .a = 255 };
        var buf: [24]u8 = undefined;
        var a0: f64 = -pi * 0.5;
        for (values, 0..) |v, i| {
            const frac: f64 = v / total;
            const a1: f64 = a0 + frac * tau;
            const col: Color = if (spec.colors) |cs| cs[i % cs.len] else autoColor(i);
            var segs: usize = @ceil((a1 - a0) / 0.19634954);
            if (segs < 1) {
                segs = 1;
            }
            if (segs > 160) {
                segs = 160;
            }
            for (0..segs) |k| {
                const f0: f64 = float64(k) / float64(segs);
                const f1: f64 = float64(k + 1) / float64(segs);
                const p0: Vec2 = polar(center, r_px, a0 + (a1 - a0) * f0);
                const p1: Vec2 = polar(center, r_px, a0 + (a1 - a0) * f1);
                sink.triangleFilled(center, p0, p1, col);
            }
            const mid: f64 = (a0 + a1) * 0.5;
            const lp: Vec2 = polar(center, r_px * 0.62, mid);
            if (spec.labels) |labs| {
                if (i < labs.len) {
                    sink.text(
                        .{ lp[0] - textWidth(labs[i], 12) * 0.5, lp[1] - 12 },
                        labs[i],
                        .{ .size = 12, .color = white },
                    );
                }
            }
            if (spec.show_percent) {
                const pct: []const u8 = bufPrint(&buf, "{d:.0}%", .{frac * 100.0}) catch "";
                sink.text(.{ lp[0] - textWidth(pct, 11) * 0.5, lp[1] }, pct, .{ .size = 11, .color = white });
            }
            a0 = a1;
        }
    }

    /// Bubble chart: scatter where `sizes` maps to a pixel radius.
    pub fn plotBubbles(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        sizes: []const f64,
        spec: BubbleSpec,
    ) void {
        const dn: usize = @min(xs.len, ys.len);
        assertf(sizes.len >= dn, @src(), "plotBubbles: sizes {d} < points {d}", .{ sizes.len, dn });
        const n: usize = @min(dn, sizes.len);
        var fill: Color = spec.color orelse autoColor(self.series_count);
        fill.a = spec.alpha;
        self.series_count += 1;
        var smin: f64 = inf(f64);
        var smax: f64 = -inf(f64);
        for (0..n) |i| {
            smin = @min(smin, sizes[i]);
            smax = @max(smax, sizes[i]);
        }
        const span: f64 = if (smax > smin) smax - smin else 1.0;
        for (0..n) |i| {
            const t: f32 = @floatCast((sizes[i] - smin) / span);
            const r: f32 = spec.min_radius + t * (spec.max_radius - spec.min_radius);
            sink.circleFilled(.{ self.x.plotToPixel(xs[i]), self.y.plotToPixel(ys[i]) }, r, fill);
        }
    }

    /// Candlestick / OHLC chart. All five arrays are parallel to `xs`.
    pub fn plotCandles(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        opens: []const f64,
        highs: []const f64,
        lows: []const f64,
        closes: []const f64,
        spec: CandleSpec,
    ) void {
        assertf(
            opens.len >= xs.len and highs.len >= xs.len and lows.len >= xs.len and closes.len >= xs.len,
            @src(),
            "plotCandles: OHLC arrays shorter than xs ({d})",
            .{xs.len},
        );
        self.series_count += 1;
        const spacing: f64 = if (xs.len >= 2) @abs(xs[1] - xs[0]) else 1.0;
        const half: f64 = spacing * spec.width * 0.5;
        for (0..xs.len) |i| {
            const bull: bool = closes[i] >= opens[i];
            const col: Color = if (bull) spec.bull else spec.bear;
            const xc: f32 = self.x.plotToPixel(xs[i]);
            const wtop: Vec2 = .{ xc, self.y.plotToPixel(highs[i]) };
            const wbot: Vec2 = .{ xc, self.y.plotToPixel(lows[i]) };
            sink.line(wtop, wbot, .{ .color = col, .thickness = spec.wick_thickness });
            const xl: f32 = self.x.plotToPixel(xs[i] - half);
            const xr: f32 = self.x.plotToPixel(xs[i] + half);
            const yo: f32 = self.y.plotToPixel(opens[i]);
            const yc: f32 = self.y.plotToPixel(closes[i]);
            const top: f32 = @min(yo, yc);
            var h: f32 = @abs(yc - yo);
            if (h < 1) {
                h = 1;
            }
            sink.fillRect(.{ .x = @min(xl, xr), .y = top, .w = @abs(xr - xl), .h = h }, col);
        }
    }

    /// Digital / logic step trace. `ys[i] != 0` is high. Drawn in a fixed band
    /// at the bottom of the plot area, so it doesn't disturb the y range.
    pub fn plotDigital(
        self: *Plot,
        sink: anytype,
        xs: []const f64,
        ys: []const f64,
        spec: DigitalSpec,
    ) void {
        const n: usize = @min(xs.len, ys.len);
        assertf(ys.len >= xs.len, @src(), "plotDigital: ys {d} < xs {d}", .{ ys.len, xs.len });
        const col: Color = spec.color orelse autoColor(self.series_count);
        self.series_count += 1;
        if (n < 2) {
            return;
        }
        const base: f32 = self.area.bottom() - spec.offset;
        const hi: f32 = base - spec.height;
        for (0..n - 1) |i| {
            const x0: f32 = self.x.plotToPixel(xs[i]);
            const x1: f32 = self.x.plotToPixel(xs[i + 1]);
            const lvl: f32 = if (ys[i] != 0) hi else base;
            sink.line(.{ x0, lvl }, .{ x1, lvl }, .{ .color = col, .thickness = spec.thickness });
            const nxt: f32 = if (ys[i + 1] != 0) hi else base;
            if (lvl != nxt) {
                sink.line(.{ x1, lvl }, .{ x1, nxt }, .{ .color = col, .thickness = spec.thickness });
            }
        }
    }

    /// Draw texture `tex_id` filling the data-space rectangle whose opposite
    /// corners are (x0,y0) and (x1,y1). The image's top edge maps to the larger
    /// data-y (so it reads upright on the screen-flipped y axis). `spec` sets
    /// the UV sub-rect (default full 0..1) and a tint (default opaque white).
    pub fn plotImage(
        self: *Plot,
        sink: anytype,
        tex_id: u32,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        spec: ImageSpec,
    ) void {
        self.series_count += 1;
        const ax: f32 = self.x.plotToPixel(x0);
        const bx: f32 = self.x.plotToPixel(x1);
        const ay: f32 = self.y.plotToPixel(y0);
        const by: f32 = self.y.plotToPixel(y1);
        const dst: Rect = .{
            .x = @min(ax, bx),
            .y = @min(ay, by),
            .w = @abs(bx - ax),
            .h = @abs(by - ay),
        };
        sink.texturedQuad(dst, tex_id, spec.uv0, spec.uv1, spec.tint);
    }
};

// ============================================================================
// [SECTION] SvgSink — host snapshot/render target
// ============================================================================

pub const SvgSink = struct {
    buf: ArrayList(u8) = .empty,
    gpa: Allocator,
    width: f32,
    height: f32,

    pub fn init(gpa: Allocator, width: f32, height: f32) SvgSink {
        return .{ .gpa = gpa, .width = width, .height = height };
    }
    pub fn deinit(self: *SvgSink) void {
        self.buf.deinit(self.gpa);
    }

    fn p(self: *SvgSink, comptime fmt: []const u8, args: anytype) void {
        var tmp: [512]u8 = undefined;
        const s: []const u8 = bufPrint(&tmp, fmt, args) catch return;
        self.buf.appendSlice(self.gpa, s) catch {};
    }

    pub fn begin(self: *SvgSink) void {
        self.p(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" " ++
                "viewBox=\"0 0 {d} {d}\" font-family=\"system-ui,sans-serif\">\n",
            .{ self.width, self.height, self.width, self.height },
        );
        self.p("<rect width=\"{d}\" height=\"{d}\" fill=\"#15151c\"/>\n", .{ self.width, self.height });
    }
    pub fn end(self: *SvgSink) void {
        self.p("</svg>\n", .{});
    }
    pub fn toOwned(self: *SvgSink) []u8 {
        return self.buf.toOwnedSlice(self.gpa) catch &.{};
    }

    fn hex(self: *SvgSink, c: Color) void {
        // 8-digit #RRGGBBAA so translucent fills (bars, shaded) preview the
        // same way the GPU blends them; opaque colors just get a trailing ff.
        self.p("#{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b, c.a });
    }

    // ---- sink interface ----
    pub fn fillRect(self: *SvgSink, r: Rect, col: Color) void {
        self.p("<rect x=\"{d:.2}\" y=\"{d:.2}\" width=\"{d:.2}\" height=\"{d:.2}\" fill=\"", .{ r.x, r.y, r.w, r.h });
        self.hex(col);
        self.p("\"/>\n", .{});
    }
    /// Host placeholder for a textured quad: the SvgSink has no GPU texture, so
    /// it draws the destination rect (faint tint fill + outline + diagonals)
    /// and an `img#<id>` label, making the quad's geometry verifiable in
    /// snapshots. The real (DrawListSink) path samples the texture.
    pub fn texturedQuad(
        self: *SvgSink,
        dst: Rect,
        tex_id: u32,
        uv0: Vec2,
        uv1: Vec2,
        tint: Color,
    ) void {
        _ = uv0;
        _ = uv1;
        self.fillRect(dst, tint.alpha(0.12));
        const tl: Vec2 = .{ dst.x, dst.y };
        const tr: Vec2 = .{ dst.x + dst.w, dst.y };
        const br: Vec2 = .{ dst.x + dst.w, dst.y + dst.h };
        const bl: Vec2 = .{ dst.x, dst.y + dst.h };
        self.line(tl, tr, .{ .color = tint, .thickness = 1.0 });
        self.line(tr, br, .{ .color = tint, .thickness = 1.0 });
        self.line(br, bl, .{ .color = tint, .thickness = 1.0 });
        self.line(bl, tl, .{ .color = tint, .thickness = 1.0 });
        self.line(tl, br, .{ .color = tint, .thickness = 1.0 });
        self.line(tr, bl, .{ .color = tint, .thickness = 1.0 });
        var buf: [24]u8 = undefined;
        const s: []const u8 = bufPrint(&buf, "img#{d}", .{tex_id}) catch "img";
        self.text(.{ dst.x + 4, dst.y + 4 }, s, .{ .size = 12, .color = tint });
    }
    pub fn line(
        self: *SvgSink,
        a: Vec2,
        b: Vec2,
        opts: draw2d.LineOpts,
    ) void {
        const col: Color = opts.color;
        const thickness: f32 = opts.thickness;
        self.p("<line x1=\"{d:.2}\" y1=\"{d:.2}\" x2=\"{d:.2}\" y2=\"{d:.2}\" stroke=\"", .{ a[0], a[1], b[0], b[1] });
        self.hex(col);
        self.p("\" stroke-width=\"{d:.2}\"/>\n", .{thickness});
    }
    pub fn polyline(
        self: *SvgSink,
        pts: []const Vec2,
        col: Color,
        thickness: f32,
        closed: bool,
    ) void {
        _ = closed;
        self.p("<polyline fill=\"none\" stroke=\"", .{});
        self.hex(col);
        self.p("\" stroke-width=\"{d:.2}\" points=\"", .{thickness});
        for (pts) |pt| {
            self.p("{d:.2},{d:.2} ", .{ pt[0], pt[1] });
        }
        self.p("\"/>\n", .{});
    }
    pub fn circleFilled(self: *SvgSink, c: Vec2, radius: f32, col: Color) void {
        self.p("<circle cx=\"{d:.2}\" cy=\"{d:.2}\" r=\"{d:.2}\" fill=\"", .{ c[0], c[1], radius });
        self.hex(col);
        self.p("\"/>\n", .{});
    }
    pub fn triangleFilled(
        self: *SvgSink,
        a: Vec2,
        b: Vec2,
        c: Vec2,
        col: Color,
    ) void {
        self.p(
            "<polygon points=\"{d:.2},{d:.2} {d:.2},{d:.2} {d:.2},{d:.2}\" fill=\"",
            .{ a[0], a[1], b[0], b[1], c[0], c[1] },
        );
        self.hex(col);
        self.p("\"/>\n", .{});
    }
    pub fn text(
        self: *SvgSink,
        pos: Vec2,
        s: []const u8,
        opts: draw2d.TextOpts,
    ) void {
        const size: f32 = opts.size;
        const col: Color = opts.color;
        self.p("<text x=\"{d:.2}\" y=\"{d:.2}\" font-size=\"{d:.1}\" fill=\"", .{ pos[0], pos[1] + size, size });
        self.hex(col);
        self.p("\">{s}</text>\n", .{s});
    }
};

// ============================================================================
// [SECTION] Demo — builds a representative plot and renders it to SVG
// ============================================================================

/// Render a self-contained demo plot to an SVG byte string (caller frees).
/// Exercises: auto-fit, nice ticks, grid, border, labels, title, a line
/// series, a marker (scatter) series, and a bar series.
pub fn renderDemoSvg(gpa: Allocator) ![]u8 {
    const N: usize = 64;
    var xs: [N]f64 = undefined;
    var sine: [N]f64 = undefined;
    var damp: [N]f64 = undefined;
    for (0..N) |i| {
        const t: f64 = float64(i) / @as(f64, N - 1) * 10.0;
        xs[i] = t;
        sine[i] = @sin(t) * 2.0 + 3.0;
        damp[i] = @exp(-t * 0.25) * @cos(t * 2.0) * 2.0 + 3.0;
    }
    // A small bar series on a coarser x grid.
    const B: usize = 10;
    var bxs: [B]f64 = undefined;
    var bys: [B]f64 = undefined;
    for (0..B) |i| {
        bxs[i] = float64(i) + 0.5;
        bys[i] = 0.5 + float64((i * 7 + 3) % 5) * 0.4;
    }

    var plot: Plot = .{ .title = "plot.zig demo - sin, damped cos, bars" };
    plot.x.label = "t";
    plot.y.label = "value";
    plot.fit(&xs, &sine);
    // Widen y to include bars sitting near zero.
    plot.y.range.expand(0);
    plot.layout(.{ .x = 0, .y = 0, .w = 720, .h = 420 });

    var sink = SvgSink.init(gpa, 720, 420);
    defer sink.deinit();
    sink.begin();
    plot.drawFrame(&sink);
    const sin_area: ShadedSpec = .{ .color = .{ .r = 76, .g = 175, .b = 80, .a = 35 }, .y_ref = plot.y.range.min };
    plot.plotShaded(&sink, &xs, &sine, sin_area);
    plot.plotBars(&sink, &bxs, &bys, .{ .color = .{ .r = 0, .g = 188, .b = 212, .a = 120 }, .width = 0.6 });
    plot.plotLine(&sink, &xs, &sine, .{ .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 } });
    plot.plotLine(&sink, &xs, &damp, .{ .color = .{ .r = 244, .g = 67, .b = 54, .a = 255 } });
    plot.plotScatter(&sink, &xs, &damp, .{
        .marker = .circle,
        .marker_size = 2.5,
        .color = .{ .r = 255, .g = 193, .b = 7, .a = 255 },
    });
    plot.plotStairs(&sink, &bxs, &bys, .{ .color = .{ .r = 156, .g = 39, .b = 176, .a = 255 } });
    plot.drawDecorations(&sink);
    const legend = [_]LegendEntry{
        .{ .label = "sin", .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 } },
        .{ .label = "damped cos", .color = .{ .r = 244, .g = 67, .b = 54, .a = 255 } },
        .{ .label = "bars", .color = .{ .r = 0, .g = 188, .b = 212, .a = 255 } },
        .{ .label = "steps", .color = .{ .r = 156, .g = 39, .b = 176, .a = 255 } },
    };
    plot.drawLegend(&sink, &legend);
    sink.end();
    return sink.toOwned();
}

/// A log-y demo: two exponentials spanning several decades, on a log10 axis
/// (powers-of-ten majors, faint 2..9 minors). Used by tests and the PNG path.
pub fn renderLogDemoSvg(gpa: Allocator) ![]u8 {
    const N: usize = 80;
    var xs: [N]f64 = undefined;
    var ya: [N]f64 = undefined;
    var yb: [N]f64 = undefined;
    for (0..N) |i| {
        const t: f64 = float64(i) / @as(f64, N - 1) * 10.0;
        xs[i] = t;
        ya[i] = exp10(t * 0.4); // 1 .. 1e4
        yb[i] = 2.0 * exp10(t * 0.25) + 1.0;
    }
    var plot: Plot = .{ .title = "plot.zig demo - log y axis" };
    plot.x.label = "t";
    plot.y.label = "value";
    plot.y.scale = .log10;
    plot.x.range = .{ .min = 0, .max = 10 };
    plot.y.range = .{ .min = 1, .max = 1.0e4 };
    plot.layout(.{ .x = 0, .y = 0, .w = 720, .h = 420 });

    var sink = SvgSink.init(gpa, 720, 420);
    defer sink.deinit();
    sink.begin();
    plot.drawFrame(&sink);
    plot.plotLine(&sink, &xs, &ya, .{ .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 } });
    plot.plotLine(&sink, &xs, &yb, .{ .color = .{ .r = 244, .g = 67, .b = 54, .a = 255 } });
    plot.drawDecorations(&sink);
    const legend = [_]LegendEntry{
        .{ .label = "10^0.4t", .color = .{ .r = 76, .g = 175, .b = 80, .a = 255 } },
        .{ .label = "2*10^0.25t", .color = .{ .r = 244, .g = 67, .b = 54, .a = 255 } },
    };
    plot.drawLegend(&sink, &legend);
    sink.end();
    return sink.toOwned();
}

/// Every marker type as its own scatter row — host snapshot for verifying
/// marker geometry without the GPU path.
pub fn renderMarkersDemoSvg(gpa: Allocator) ![]u8 {
    const ms = [_]Marker{
        .circle,        .square,        .diamond,        .triangle_up,
        .triangle_down, .triangle_left, .triangle_right, .plus,
        .cross,         .asterisk,
    };
    const npts: usize = 6;
    var xs: [npts]f64 = undefined;
    for (0..npts) |j| {
        xs[j] = float64(j) + 1.0;
    }
    var plot: Plot = .{ .title = "plot.zig demo - markers" };
    plot.x.range = .{ .min = 0, .max = 7 };
    plot.y.range = .{ .min = -1, .max = @floatFromInt(ms.len) };
    plot.layout(.{ .x = 0, .y = 0, .w = 720, .h = 420 });

    var sink = SvgSink.init(gpa, 720, 420);
    defer sink.deinit();
    sink.begin();
    plot.drawFrame(&sink);
    for (ms, 0..) |m, i| {
        var ys: [npts]f64 = undefined;
        for (0..npts) |j| {
            ys[j] = @floatFromInt(i);
        }
        plot.plotScatter(&sink, &xs, &ys, .{ .marker = m, .marker_size = 6.0, .color = autoColor(i) });
    }
    plot.drawDecorations(&sink);
    sink.end();
    return sink.toOwned();
}

const testing = std.testing;

test "plot.Axis: data<->pixel roundtrip (linear, Y flipped)" {
    var ax: Axis = .{ .range = .{ .min = 0, .max = 10 }, .px_min = 100, .px_max = 500 };
    // min->px_min, max->px_max, midpoint->middle.
    try testing.expectApproxEqAbs(@as(f32, 100), ax.plotToPixel(0), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 500), ax.plotToPixel(10), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 300), ax.plotToPixel(5), 1e-3);
    // Roundtrip.
    try testing.expectApproxEqAbs(@as(f64, 7.5), ax.pixelToPlot(ax.plotToPixel(7.5)), 1e-3);
    // Inverted-pixel axis (Y bottom>top).
    var ay: Axis = .{ .range = .{ .min = 0, .max = 1 }, .px_min = 400, .px_max = 100 };
    try testing.expectApproxEqAbs(@as(f32, 400), ay.plotToPixel(0), 1e-3); // data 0 at bottom
    try testing.expectApproxEqAbs(@as(f32, 100), ay.plotToPixel(1), 1e-3); // data 1 at top
}

test "plot.Ticker: nice major ticks land on round values inside range" {
    // ImPlot targets ~1 major per 400px (horizontal). At exactly 400px the
    // range gets just its endpoints; a wider axis gets interior ticks.
    const wide: Axis = .{ .range = .{ .min = 0, .max = 10 }, .px_min = 0, .px_max = 1600 };
    var tk: Ticker = .{};
    tk.generate(wide, 1600, false);
    try testing.expect(tk.count >= 3);
    // Interval is a nice 1/2/5 * 10^k; for [0,10] over 1600px -> 5.
    try testing.expectEqual(@as(f64, 5), tk.interval);
    var majors: usize = 0;
    var minors: usize = 0;
    for (tk.slice()) |t| {
        try testing.expect(wide.range.contains(t.value));
        if (t.major) {
            majors += 1;
            // Majors land on integer multiples of the interval.
            const k: f64 = t.value / tk.interval;
            try testing.expectApproxEqAbs(k, @round(k), 1e-9);
        } else {
            minors += 1;
        }
    }
    // Both kinds present: majors on the round grid, minors subdividing it.
    try testing.expect(majors >= 2);
    try testing.expect(minors >= 1);
    // Narrow axis still yields the endpoints (no crash, no empty set).
    const narrow: Axis = .{ .range = .{ .min = 0, .max = 10 }, .px_min = 0, .px_max = 400 };
    tk.generate(narrow, 400, false);
    try testing.expect(tk.count >= 2);
}

test "plot.decimalsFor" {
    try testing.expectEqual(@as(u8, 0), decimalsFor(2));
    try testing.expectEqual(@as(u8, 0), decimalsFor(10));
    try testing.expectEqual(@as(u8, 1), decimalsFor(0.5));
    try testing.expectEqual(@as(u8, 2), decimalsFor(0.02));
}

test "plot.Axis: log10 transform + power-of-ten ticks" {
    var ax: Axis = .{ .range = .{ .min = 1, .max = 1000 }, .px_min = 0, .px_max = 300, .scale = .log10 };
    // One decade per 100px: 1->0, 10->100, 1000->300.
    try testing.expectApproxEqAbs(@as(f32, 0), ax.plotToPixel(1), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 100), ax.plotToPixel(10), 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 300), ax.plotToPixel(1000), 1e-3);
    try testing.expectApproxEqAbs(@as(f64, 100), ax.pixelToPlot(ax.plotToPixel(100)), 1e-3);
    var tk: Ticker = .{};
    tk.generate(ax, 300, true);
    var majors: usize = 0;
    var minors: usize = 0;
    for (tk.slice()) |t| {
        if (t.major) {
            majors += 1;
            const lg: f64 = log10(t.value);
            try testing.expectApproxEqAbs(lg, @round(lg), 1e-9);
        } else {
            minors += 1;
        }
    }
    try testing.expect(majors >= 3);
    try testing.expect(minors >= 1);
}

test "plot.renderDemoSvg produces non-trivial svg" {
    const svg: []u8 = try renderDemoSvg(testing.allocator);
    defer testing.allocator.free(svg);
    try testing.expect(svg.len > 500);
    try testing.expect(std.mem.indexOf(u8, svg, "<svg") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "<polyline") == null); // we use <line> segments
    try testing.expect(std.mem.indexOf(u8, svg, "</svg>") != null);
}

test "plot.histogramBins" {
    const vals = [_]f64{ 0.1, 0.2, 0.9, 0.5, 0.5, 1.0, -0.3 };
    var counts: [2]f64 = undefined;
    histogramBins(&vals, &counts, 0, 1);
    // bin0=[0,0.5): 0.1, 0.2 -> 2 ; bin1=[0.5,1]: 0.9, 0.5, 0.5, 1.0 -> 4 ; -0.3 dropped
    try testing.expectEqual(@as(f64, 2), counts[0]);
    try testing.expectEqual(@as(f64, 4), counts[1]);
}

test "plot.histogramBins2D" {
    const xs = [_]f64{ 0.1, 0.9, 0.1 };
    const ys = [_]f64{ 0.1, 0.1, 0.9 };
    var counts: [4]f64 = undefined; // 2x2, row 0 = top (high y)
    histogramBins2D(&xs, &ys, &counts, 2, 2, 0, 1, 0, 1);
    // (0.1,0.9) -> top-left = row0,col0 ; (0.1,0.1),(0.9,0.1) -> bottom row
    try testing.expectEqual(@as(f64, 1), counts[0]); // top-left
    try testing.expectEqual(@as(f64, 1), counts[2]); // bottom-left
    try testing.expectEqual(@as(f64, 1), counts[3]); // bottom-right
}

test "time civil + format" {
    const d0: DateParts = civilFromEpoch(0);
    try testing.expectEqual(@as(i64, 1970), d0.year);
    try testing.expectEqual(@as(i64, 1), d0.month);
    try testing.expectEqual(@as(i64, 1), d0.day);
    const d1: DateParts = civilFromEpoch(1704067200); // 2024-01-01 00:00:00 UTC
    try testing.expectEqual(@as(i64, 2024), d1.year);
    try testing.expectEqual(@as(i64, 1), d1.month);
    try testing.expectEqual(@as(i64, 1), d1.day);
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("2024", formatTime(&buf, 1704067200, .year));
    try testing.expectEqualStrings("Jan 01", formatTime(&buf, 1704067200, .md));
    try testing.expectEqualStrings("00:00", formatTime(&buf, 1704067200, .hm));
    try testing.expectEqualStrings("12:34:56", formatTime(&buf, 1704067200 + 12 * 3600 + 34 * 60 + 56, .hms));
}

test "symlog + custom transform round-trips" {
    const ax: Axis = .{
        .range = .{ .min = -1000, .max = 1000 },
        .scale = .symlog,
        .linthresh = 1,
        .px_min = 0,
        .px_max = 100,
    };
    const samples = [_]f64{ -1000, -10, -0.5, 0, 0.5, 10, 1000 };
    for (samples) |v| {
        const f: f64 = ax.dataToFraction(v);
        const back: f64 = ax.fractionToData(f);
        try testing.expect(@abs(back - v) < 1e-6 * (@abs(v) + 1));
    }
    // 0 sits at the midpoint of a symmetric symlog range.
    try testing.expect(@abs(ax.dataToFraction(0) - 0.5) < 1e-9);

    const T = struct {
        fn fwd(x: f64) f64 {
            return if (x < 0) -@sqrt(-x) else @sqrt(x);
        }
        fn inv(x: f64) f64 {
            return if (x < 0) -(x * x) else x * x;
        }
    };
    const cx: Axis = .{
        .range = .{ .min = 0, .max = 100 },
        .scale = .custom,
        .transform = .{ .forward = T.fwd, .inverse = T.inv },
        .px_min = 0,
        .px_max = 1,
    };
    // sqrt(25)/sqrt(100) = 0.5
    try testing.expect(@abs(cx.dataToFraction(25) - 0.5) < 1e-9);
    // zoom is uniform in transform space: zooming out then to the same center.
    const z: DataRange = ax.zoomedRange(0, 0.5);
    try testing.expect(z.min > -1000 and z.max < 1000 and z.min < 0 and z.max > 0);
}

test "colorbar renders gradient, outline, and labels" {
    const gpa: Allocator = std.testing.allocator;
    var sink: SvgSink = SvgSink.init(gpa, 140, 220);
    defer sink.deinit();
    sink.begin();
    drawColorbar(&sink, .{ .x = 24, .y = 20, .w = 16, .h = 160 }, .{
        .cmap = .viridis,
        .min = 0,
        .max = 100,
        .ticks = 3,
        .label_decimals = 0,
        .label = "ZCBAR",
    });
    sink.end();
    const svg: []u8 = sink.toOwned();
    defer gpa.free(svg);
    try expect(std.mem.indexOf(u8, svg, "ZCBAR") != null);
    try expect(std.mem.indexOf(u8, svg, "100") != null);
    try expect(svg.len > 1000);
}

test "secondary x2 axis lays out and draws on top" {
    const gpa: Allocator = std.testing.allocator;
    var sink: SvgSink = SvgSink.init(gpa, 300, 220);
    defer sink.deinit();
    sink.begin();
    var p: Plot = .{};
    p.x.range = .{ .min = 0, .max = 10 };
    p.y.range = .{ .min = 0, .max = 1 };
    p.x2_enabled = true;
    p.x2.range = .{ .min = 0, .max = 200 };
    p.x2.label = "ZX2";
    p.layout(.{ .x = 0, .y = 0, .w = 300, .h = 220 });
    try expectApproxEqAbs(p.area.x, p.x2.px_min, 0.5);
    try expectApproxEqAbs(p.area.right(), p.x2.px_max, 0.5);
    try expect(p.area.y > 8);
    p.drawDecorations(&sink);
    sink.end();
    const svg: []u8 = sink.toOwned();
    defer gpa.free(svg);
    try expect(std.mem.indexOf(u8, svg, "ZX2") != null);
}

test "style themes the plot-area background" {
    const gpa: Allocator = std.testing.allocator;
    var sink: SvgSink = SvgSink.init(gpa, 200, 150);
    defer sink.deinit();
    sink.begin();
    var p: Plot = .{ .style = .{ .bg = .{ .r = 246, .g = 246, .b = 249, .a = 255 } } };
    p.x.range = .{ .min = 0, .max = 1 };
    p.y.range = .{ .min = 0, .max = 1 };
    p.layout(.{ .x = 0, .y = 0, .w = 200, .h = 150 });
    p.drawFrame(&sink);
    sink.end();
    const svg: []u8 = sink.toOwned();
    defer gpa.free(svg);
    try expect(std.mem.indexOf(u8, svg, "#f6f6f9ff") != null);
}

test "line breaks at NaN samples (gap)" {
    const gpa: Allocator = std.testing.allocator;
    var sink: SvgSink = SvgSink.init(gpa, 200, 150);
    defer sink.deinit();
    sink.begin();
    var p: Plot = .{};
    p.x.range = .{ .min = 0, .max = 4 };
    p.y.range = .{ .min = 0, .max = 4 };
    p.layout(.{ .x = 0, .y = 0, .w = 200, .h = 150 });
    const xs = [_]f64{ 0, 1, 2, 3, 4 };
    const ys = [_]f64{ 0, 1, nan(f64), 3, 4 };
    p.plotLine(&sink, &xs, &ys, .{});
    sink.end();
    const svg: []u8 = sink.toOwned();
    defer gpa.free(svg);
    // NaN at index 2 drops segments 1-2 and 2-3, leaving only 0-1 and 3-4.
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, svg, "<line");
    _ = it.first();
    while (it.next()) |_| {
        count += 1;
    }
    try expectEqual(@as(usize, 2), count);
}

test "implicit-x: ys-only series plots over sample indices" {
    const gpa: Allocator = std.testing.allocator;
    var sink: SvgSink = SvgSink.init(gpa, 200, 150);
    defer sink.deinit();
    sink.begin();
    var p: Plot = .{};
    p.x.range = .{ .min = 0, .max = 3 };
    p.y.range = .{ .min = 0, .max = 3 };
    p.layout(.{ .x = 0, .y = 0, .w = 200, .h = 150 });
    const ys = [_]f64{ 0, 2, 1, 3 };
    p.plotLine(&sink, &.{}, &ys, .{}); // empty xs -> implicit-x
    sink.end();
    const svg: []u8 = sink.toOwned();
    defer gpa.free(svg);
    // 4 samples over indices 0..3 -> 3 connected segments.
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, svg, "<line");
    _ = it.first();
    while (it.next()) |_| {
        count += 1;
    }
    try expectEqual(@as(usize, 3), count);
}

test "query math: plotToPixel/pixelToPlot round-trip + known mapping" {
    var p: Plot = .{};
    p.x.range = .{ .min = 0, .max = 10 };
    p.y.range = .{ .min = 0, .max = 100 };
    p.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    // Round-trip a handful of data points through pixels and back.
    const xs = [_]f64{ 0, 2.5, 5, 7.5, 10 };
    for (xs) |xv| {
        const px: f32 = p.x.plotToPixel(xv);
        const back: f64 = p.x.pixelToPlot(px);
        try expect(@abs(back - xv) < 1e-6);
    }
    // Y axis is screen-flipped: data max maps to the top (area.y), min to bottom.
    const top: f32 = p.y.plotToPixel(100);
    const bot: f32 = p.y.plotToPixel(0);
    try expect(top < bot);
    try expect(@abs(top - p.area.y) < 0.01);
    try expect(@abs(bot - p.area.bottom()) < 0.01);
}

test "horizontal legend layout: single row + x hit-testing" {
    var p: Plot = .{};
    p.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    const entries = [_]LegendEntry{
        .{ .label = "alpha", .color = .{ .r = 255, .g = 0, .b = 0, .a = 255 } },
        .{ .label = "beta", .color = .{ .r = 0, .g = 255, .b = 0, .a = 255 } },
        .{ .label = "gamma", .color = .{ .r = 0, .g = 0, .b = 255, .a = 255 } },
    };
    const lay: LegendLayout = p.legendLayout(&entries, .nw, true);
    try expect(lay.horizontal);
    try expect(lay.box.h < 30); // a single row tall
    const y: f32 = lay.box.y + lay.pad_y + 2;
    const base: f32 = lay.box.x + lay.pad_x;
    try expectEqual(@as(?usize, 0), lay.hit(.{ base + lay.cell_w * 0.5, y }));
    try expectEqual(@as(?usize, 1), lay.hit(.{ base + lay.cell_w * 1.5, y }));
    try expectEqual(@as(?usize, 2), lay.hit(.{ base + lay.cell_w * 2.5, y }));
    try expectEqual(@as(?usize, null), lay.hit(.{ base, lay.box.y - 5 }));
}

test "plotImage maps data bounds to a pixel rect" {
    const Cap = struct {
        dst: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        id: u32 = 0,
        pub fn texturedQuad(
            self: *@This(),
            dst: Rect,
            tex_id: u32,
            uv0: Vec2,
            uv1: Vec2,
            tint: Color,
        ) void {
            _ = uv0;
            _ = uv1;
            _ = tint;
            self.dst = dst;
            self.id = tex_id;
        }
    };
    var p: Plot = .{};
    p.x.range = .{ .min = 0, .max = 10 };
    p.y.range = .{ .min = 0, .max = 10 };
    p.layout(.{ .x = 0, .y = 0, .w = 400, .h = 300 });
    var cap: Cap = .{};
    p.plotImage(&cap, 7, 2, 2, 8, 8, .{});
    try expectEqual(@as(u32, 7), cap.id);
    const x2: f32 = p.x.plotToPixel(2);
    const x8: f32 = p.x.plotToPixel(8);
    const y2: f32 = p.y.plotToPixel(2);
    const y8: f32 = p.y.plotToPixel(8);
    try expect(@abs(cap.dst.x - @min(x2, x8)) < 0.01);
    try expect(@abs(cap.dst.w - @abs(x8 - x2)) < 0.01);
    try expect(@abs(cap.dst.y - @min(y2, y8)) < 0.01);
    try expect(@abs(cap.dst.h - @abs(y8 - y2)) < 0.01);
}
