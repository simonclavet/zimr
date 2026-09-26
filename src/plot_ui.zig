//! lint:alias plot_ui
//! plot_ui.zig - the `ui.zig` adapter for `plot.zig`.
//!
//! Two pieces:
//!   1. `DrawListSink` - records the (backend-agnostic) plot core's
//!      primitives into a `ui.DrawList`. The in-engine counterpart to
//!      `plot.zig`'s host-only `SvgSink`; same duck-typed method set, so
//!      the core neither knows nor cares which it is drawing into.
//!   2. `show` - a one-call interactive plot widget for use inside a zimr
//!      frame: reserves a rect, auto-fits to the data on first frame,
//!      handles drag-to-pan and wheel-zoom-around-cursor, then draws the
//!      frame, the series, and the decorations.
//!
//! Web interactivity is the point: this is what a static image cannot do.

const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const float = zm.float;
const ui = @import("ui.zig");
const plot = @import("plot.zig");
const draw2d = @import("draw2d.zig");

const Vec2 = zm.Vec2;
const Color = zm.Color;
const Range = zm.Range;
const inf = zm.inf;
const clamp = zm.clamp;
const floori = zm.floori;
const DataRange = Range(f64);
const assertf = zm.assertf;

// ============================================================================
// [SECTION] DrawListSink - plot core -> ui.DrawList
// ============================================================================

pub const DrawListSink = struct {
    dl: *ui.DrawList,
    gpa: Allocator,
    font: ?*const ui.Font,

    /// Build a sink from the active UI handle, or null if there is no
    /// draw list this frame (outside a window).
    pub fn fromUi(u: ui.Ui) ?DrawListSink {
        const dl: *ui.DrawList = u.getDrawList() orelse return null;
        return .{ .dl = dl, .gpa = u.drawListAllocator(), .font = u.style().font };
    }

    pub fn fillRect(self: *DrawListSink, r: plot.Rect, col: Color) void {
        self.dl.addRectFilled(
            self.gpa,
            .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h },
            col.toWire(),
        );
    }
    /// Scissor subsequent draws to `r` (the plot area), so series can't
    /// spill past the axes. Pair with `popClip`.
    pub fn pushClip(self: *DrawListSink, r: plot.Rect) void {
        self.dl.pushClipRect(
            self.gpa,
            .{ .x = r.x, .y = r.y, .width = r.w, .height = r.h },
        );
    }
    pub fn popClip(self: *DrawListSink) void {
        self.dl.popClipRect(self.gpa);
    }
    pub fn line(
        self: *DrawListSink,
        a: Vec2,
        b: Vec2,
        opts: draw2d.LineOpts,
    ) void {
        self.dl.addLine(self.gpa, a, b, opts.color.toWire(), opts.thickness);
    }
    pub fn polyline(
        self: *DrawListSink,
        pts: []const Vec2,
        col: Color,
        thickness: f32,
        closed: bool,
    ) void {
        self.dl.addPolyline(self.gpa, pts, col.toWire(), thickness, closed);
    }
    pub fn circleFilled(self: *DrawListSink, c: Vec2, radius: f32, col: Color) void {
        const segs: u32 = clamp(floori(u32, @max(0.0, radius) * 2.0), 8, 32);
        self.dl.addCircleFilled(self.gpa, c, radius, col.toWire(), segs);
    }
    pub fn triangleFilled(
        self: *DrawListSink,
        a: Vec2,
        b: Vec2,
        c: Vec2,
        col: Color,
    ) void {
        self.dl.addTriangleFilled(self.gpa, a, b, c, col.toWire());
    }
    pub fn texturedQuad(
        self: *DrawListSink,
        dst: plot.Rect,
        tex_id: u32,
        uv0: Vec2,
        uv1: Vec2,
        tint: Color,
    ) void {
        self.dl.addTexturedQuad(
            self.gpa,
            .{ .x = dst.x, .y = dst.y, .width = dst.w, .height = dst.h },
            tex_id,
            uv0,
            uv1,
            tint.toWire(),
        );
    }
    pub fn text(
        self: *DrawListSink,
        pos: Vec2,
        s: []const u8,
        opts: draw2d.TextOpts,
    ) void {
        self.dl.addText(self.gpa, self.font, s, pos, opts.size, opts.spacing, 0, opts.color.toWire());
    }
};

// ============================================================================
// [SECTION] Interactive widget
// ============================================================================

/// Which part of a drag-rect is currently grabbed.
pub const RectGrab = enum { none, move, c_x0y0, c_x1y0, c_x0y1, c_x1y1 };

/// Result of a rubber-band box selection (data-space bounds). `active` is true
/// while the user is dragging the band; `has` stays true after a completed
/// selection so the caller can act on the region.
pub const SelectRect = struct {
    x0: f64 = 0,
    x1: f64 = 0,
    y0: f64 = 0,
    y1: f64 = 0,
    active: bool = false,
    has: bool = false,
};

/// Per-plot state that persists across frames (axis ranges + the
/// fit-on-first-frame latch). One per plot, owned by the caller's State.
pub const PlotState = struct {
    x: DataRange = .{ .min = 0, .max = 1 },
    y: DataRange = .{ .min = 0, .max = 1 },
    /// Secondary (right) Y axis range, used by series with `.axis = .y2`.
    y2: DataRange = .{ .min = 0, .max = 1 },
    /// Secondary (top) X axis range, used by series with `.x_axis = .x2`.
    x2: DataRange = .{ .min = 0, .max = 1 },
    /// False until the first auto-fit has run; set it back to false to
    /// request a re-fit (e.g. from a "Fit" button).
    fitted: bool = false,
    /// Set once any touch is seen. On touch devices the hover state sticks at
    /// the last finger position after release, so we stop trusting hover for
    /// the value readout once this is true and drive it only from a live touch.
    seen_touch: bool = false,
    /// Per-series visibility, indexed by series order. Toggled by tapping a
    /// legend row. Series beyond index 15 can't be hidden (rare).
    hidden: [16]bool = @splat(false),
    /// Index of the drag handle currently grabbed (null = none) + the grab
    /// offset in data units so the handle doesn't jump to the cursor.
    drag_active: ?usize = null,
    drag_off: [2]f64 = .{ 0, 0 },
    /// Previous-frame active flag, to detect the press-down edge for grabbing.
    was_active: bool = false,
    /// Drag-rect grab state + move offset (data units).
    rect_grab: RectGrab = .none,
    rect_off: [2]f64 = .{ 0, 0 },
    /// Rubber-band box-select state: whether a band is being dragged + the
    /// pixel where the drag started.
    selecting: bool = false,
    sel_start: Vec2 = .{ 0, 0 },
    /// Last box selection in data space (band while dragging, retained after a
    /// completed drag). Exposed via getSelection(); consumed by box-zoom.
    sel: SelectRect = .{},

    // ---- query snapshot ------------------------------------------------
    // Written by show() each frame; read by the query API below so app code
    // can map data<->pixels, read the current limits, and locate the cursor
    // AFTER show() (e.g. to draw a custom overlay into the same window).
    // `q_valid` stays false until the first show().
    q_area: plot.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    q_x: plot.Axis = .{},
    q_y: plot.Axis = .{},
    q_x2: plot.Axis = .{},
    q_y2: plot.Axis = .{},
    q_mouse: Vec2 = .{ 0, 0 },
    q_valid: bool = false,

    /// Request a re-fit to the data on the next frame.
    pub fn requestFit(self: *PlotState) void {
        self.fitted = false;
    }

    /// Current data-space axis limits (after pan/zoom/fit). Valid after show().
    pub const Limits = struct {
        x: DataRange,
        y: DataRange,
        x2: DataRange,
        y2: DataRange,
    };

    /// Snapshot of the current axis limits. Valid after the first show().
    pub fn getPlotLimits(self: *const PlotState) Limits {
        return .{ .x = self.x, .y = self.y, .x2 = self.x2, .y2 = self.y2 };
    }

    /// Map a data point on the primary (x1/y1) axes to screen pixels. Honors
    /// the current scale (linear/log/symlog/time/custom). Valid after show().
    pub fn plotToPixels(self: *const PlotState, data: [2]f64) Vec2 {
        return .{ self.q_x.plotToPixel(data[0]), self.q_y.plotToPixel(data[1]) };
    }

    /// Inverse of `plotToPixels` (primary axes).
    pub fn pixelsToPlot(self: *const PlotState, px: Vec2) [2]f64 {
        return .{ self.q_x.pixelToPlot(px[0]), self.q_y.pixelToPlot(px[1]) };
    }

    /// Map a data point on the secondary (x2/y2) axes to screen pixels.
    pub fn plotToPixels2(self: *const PlotState, data: [2]f64) Vec2 {
        return .{ self.q_x2.plotToPixel(data[0]), self.q_y2.plotToPixel(data[1]) };
    }

    /// Cursor position in primary-axis data space. Valid after show().
    pub fn getPlotMousePos(self: *const PlotState) [2]f64 {
        return self.pixelsToPlot(self.q_mouse);
    }

    /// The plot area (framed region) in screen pixels, as set by show().
    pub fn plotArea(self: *const PlotState) plot.Rect {
        return self.q_area;
    }

    /// True when screen pixel `px` falls inside the plot area.
    pub fn isInside(self: *const PlotState, px: Vec2) bool {
        return self.q_area.contains(px);
    }

    /// The last completed box selection in data space, or null when there is
    /// no retained selection (e.g. box-select disabled, cleared by a tap, or
    /// already consumed by box-zoom).
    pub fn getSelection(self: *const PlotState) ?SelectRect {
        return if (self.sel.has) self.sel else null;
    }
};

pub const YAxis = enum { y1, y2 };
pub const XAxis = enum { x1, x2 };

/// A draggable handle the user can grab and move, mutating the caller's value
/// through a pointer. `point` uses both x and y; `line_x` a vertical guide at
/// x; `line_y` a horizontal guide at y.
pub const DragKind = enum { point, line_x, line_y };

pub const DragHandle = struct {
    kind: DragKind,
    x: ?*f64 = null,
    y: ?*f64 = null,
    color: ?Color = null,
    radius: f32 = 7,
};

/// A draggable/resizable rectangle in data space. Drag the interior to move
/// it, or a corner to resize. All four bounds are mutated through pointers.
pub const DragRect = struct {
    x0: *f64,
    x1: *f64,
    y0: *f64,
    y1: *f64,
    color: ?Color = null,
};

pub const SeriesKind = enum {
    line,
    scatter,
    bars,
    shaded,
    stairs,
    stems,
    inf_lines,
    error_bars,
    error_bars_asym,
    heatmap,
    shaded_between,
    bar_groups,
    pie,
    bubbles,
    candlestick,
    digital,
    image,
};

/// One drawable series. `spec` applies to line/scatter/stairs/stems; `bars`
/// to bars; `shaded` to shaded; `inflines`/`errorbars` to those kinds.
/// `err` supplies symmetric error magnitudes for `.error_bars`; `err_neg`/
/// `err_pos` supply asymmetric magnitudes for `.error_bars_asym`. For
/// `.heatmap`, `values` (row-major, `rows`x`cols`) + `heatmap` are used, and
/// `xs`/`ys` should hold the bounds corners so auto-fit frames the grid.
pub const Series = struct {
    kind: SeriesKind = .line,
    /// X samples. Leave empty (the default) for implicit-x: x = sample index,
    /// i.e. the series is plotted from `ys` alone (ImPlot's `PlotLine(ys)`).
    xs: []const f64 = &.{},
    ys: []const f64,
    spec: plot.LineSpec = .{},
    bars: plot.BarsSpec = .{},
    shaded: plot.ShadedSpec = .{},
    inflines: plot.InfLinesSpec = .{},
    errorbars: plot.ErrorBarsSpec = .{},
    err: ?[]const f64 = null,
    err_neg: ?[]const f64 = null,
    err_pos: ?[]const f64 = null,
    values: ?[]const f64 = null,
    rows: usize = 0,
    cols: usize = 0,
    heatmap: plot.HeatmapSpec = .{},
    /// Second y-series for `.shaded_between` (the band's other edge).
    ys2: ?[]const f64 = null,
    /// `.bar_groups`: `values` row-major item-major, `rows`=item count,
    /// `cols`=group count.
    bargroups: plot.BarGroupsSpec = .{},
    /// `.bubbles`: per-point sizes (parallel to xs/ys) + spec.
    sizes: ?[]const f64 = null,
    bubble: plot.BubbleSpec = .{},
    /// `.candlestick`: OHLC arrays parallel to xs, + spec.
    opens: ?[]const f64 = null,
    highs: ?[]const f64 = null,
    lows: ?[]const f64 = null,
    closes: ?[]const f64 = null,
    candle: plot.CandleSpec = .{},
    /// `.pie`: slice values come from `values`; this is the spec.
    pie: plot.PieSpec = .{},
    /// `.digital`: 0/1 step trace spec (drawn in a bottom screen band).
    digital: plot.DigitalSpec = .{},
    /// `.image`: GPU texture id to draw, the data-space bounds it fills
    /// (x0,y0,x1,y1), and uv/tint via `image`.
    tex_id: u32 = 0,
    img_bounds: [4]f64 = .{ 0, 0, 1, 1 },
    image: plot.ImageSpec = .{},
    /// Which Y axis this series is drawn against (right-side y2 is optional).
    axis: YAxis = .y1,
    /// Which X axis this series is drawn against (top-side x2 is optional).
    x_axis: XAxis = .x1,
    /// Shown in the legend (and a no-op there when null).
    label: ?[]const u8 = null,
};

pub const OverlayKind = enum { text, annotation, tag_x, tag_y };

/// A non-data overlay drawn on top of the plot: free text, a clamped text
/// bubble, or an axis-edge tag. `x`/`y` are data coords (text/annotation);
/// `value` is the tagged coordinate (tag_x/tag_y).
pub const Overlay = struct {
    kind: OverlayKind = .text,
    text: []const u8,
    x: f64 = 0,
    y: f64 = 0,
    value: f64 = 0,
    text_spec: plot.TextSpec = .{},
    ann_spec: plot.AnnotationSpec = .{},
    tag_spec: plot.TagSpec = .{},
};

pub const Options = struct {
    title: ?[]const u8 = null,
    /// Allow pan/zoom. Off = a static (but still laid-out) plot.
    interactive: bool = true,
    /// Wheel zoom sensitivity (fraction per wheel notch).
    zoom_rate: f32 = 0.1,
    /// Draw a legend for series that have a `label` (top-right, inside).
    show_legend: bool = true,
    /// Which corner the legend sits in.
    legend_location: plot.LegendLocation = .ne,
    /// Lay the legend out as a single horizontal row (default: vertical column).
    legend_horizontal: bool = false,
    /// Log10 scale per axis (data must be positive).
    x_log: bool = false,
    /// Treat x as epoch-seconds and label it with date/time ticks (overrides
    /// x_log). The transform stays linear.
    x_time: bool = false,
    y_log: bool = false,
    /// Symmetric-log scales (linear within +/-linthresh, log beyond). Override
    /// x_log / y_log.
    x_symlog: bool = false,
    y_symlog: bool = false,
    x_linthresh: f64 = 1,
    y_linthresh: f64 = 1,
    /// Custom forward/inverse transform per axis (overrides every other scale).
    x_transform: ?plot.AxisMap = null,
    y_transform: ?plot.AxisMap = null,
    /// Pan/zoom constraints (edge + span limits) per axis.
    x_constraints: ?plot.AxisConstraints = null,
    y_constraints: ?plot.AxisConstraints = null,
    /// Explicit tick positions + optional parallel labels per axis.
    x_tick_values: ?[]const f64 = null,
    x_tick_labels: ?[]const []const u8 = null,
    y_tick_values: ?[]const f64 = null,
    y_tick_labels: ?[]const []const u8 = null,
    /// Tick label number format per axis.
    x_format: plot.NumberFormat = .auto,
    y_format: plot.NumberFormat = .auto,
    /// Re-fit to the data every frame (useful for streaming data).
    auto_fit: bool = false,
    /// Lock equal data-units-per-pixel on both axes (circles stay round).
    /// Only grows ranges, never crops; linear axes only.
    equal_aspect: bool = false,
    /// Text / annotation / tag overlays drawn on top of the series.
    overlays: []const Overlay = &.{},
    /// Draggable handles (points / guide lines) the user can grab and move.
    drag_handles: []const DragHandle = &.{},
    /// Optional draggable/resizable rectangle (move + corner resize).
    drag_rect: ?DragRect = null,
    /// When true, a drag rubber-bands a selection (instead of panning) and
    /// reports the region through `selection`.
    box_select: bool = false,
    selection: ?*SelectRect = null,
    /// When true, a drag rubber-bands a box and, on release, zooms the view to
    /// that region (ImPlot's default box-zoom). Double-tap re-fits. No
    /// `selection` pointer needed - the box is tracked in PlotState.
    box_zoom: bool = false,
    /// Optional axis labels (x, left y, right y2).
    x_label: ?[]const u8 = null,
    y_label: ?[]const u8 = null,
    y2_label: ?[]const u8 = null,
    /// Caption for the secondary (top) X axis, when any series uses `.x_axis = .x2`.
    x2_label: ?[]const u8 = null,
    /// Chrome theming (area bg, grid, border, text). Defaults to the dark theme.
    style: plot.Style = .{},
    /// When set, reserve a strip on the right of the plot and draw a colorbar
    /// (gradient + value axis) aligned to the plot area. Pair its cmap/min/max
    /// with a heatmap series to annotate that series' value scale.
    colorbar: ?plot.ColorbarSpec = null,
};

/// A simple subplot grid. `beginSubplots` captures the cursor and computes a
/// uniform cell size; call `cellAt(r,c)` to position the cursor for each cell
/// (it returns the cell size to pass to `show`), then `finish()` to drop the
/// cursor below the grid. Give each cell's `show` a unique title so their
/// hit-targets don't collide.
pub const Subplots = struct {
    u: ui.Ui,
    base: Vec2,
    cell: Vec2,
    total: Vec2,
    spacing: f32,

    pub fn cellAt(self: Subplots, r: usize, c: usize) Vec2 {
        const x: f32 = self.base[0] + float(c) * (self.cell[0] + self.spacing);
        const y: f32 = self.base[1] + float(r) * (self.cell[1] + self.spacing);
        self.u.setCursorPos(.{ x, y });
        return self.cell;
    }

    pub fn finish(self: Subplots) void {
        self.u.setCursorPos(.{ self.base[0], self.base[1] + self.total[1] + self.spacing });
    }
};

pub fn beginSubplots(
    u: ui.Ui,
    total: Vec2,
    rows: usize,
    cols: usize,
    spacing: f32,
) Subplots {
    const fc: f32 = float(@max(cols, 1));
    const fr: f32 = float(@max(rows, 1));
    const cw: f32 = (total[0] - spacing * (fc - 1)) / fc;
    const ch: f32 = (total[1] - spacing * (fr - 1)) / fr;
    return .{
        .u = u,
        .base = u.getCursorPos(),
        .cell = .{ cw, ch },
        .total = total,
        .spacing = spacing,
    };
}

/// True if the pointer `m` is over the handle (a bit forgiving on the radius).
fn hitHandle(p: plot.Plot, h: DragHandle, m: Vec2) bool {
    switch (h.kind) {
        .point => {
            const xp: *f64 = h.x orelse return false;
            const yp: *f64 = h.y orelse return false;
            const hx: f32 = p.x.plotToPixel(xp.*);
            const hy: f32 = p.y.plotToPixel(yp.*);
            const dx: f32 = m[0] - hx;
            const dy: f32 = m[1] - hy;
            const tol: f32 = @max(h.radius * 2.5, 26);
            return dx * dx + dy * dy <= tol * tol;
        },
        .line_x => {
            const xp: *f64 = h.x orelse return false;
            const tol: f32 = @max(h.radius * 2.0, 18);
            return @abs(m[0] - p.x.plotToPixel(xp.*)) <= tol;
        },
        .line_y => {
            const yp: *f64 = h.y orelse return false;
            const tol: f32 = @max(h.radius * 2.0, 18);
            return @abs(m[1] - p.y.plotToPixel(yp.*)) <= tol;
        },
    }
}

/// Grab/drag handling. Returns true while a handle is grabbed (so the caller
/// suppresses panning that frame). Mutates the grabbed handle's value through
/// its pointer, preserving the grab offset so it doesn't snap to the cursor.
fn processDragHandles(
    u: ui.Ui,
    state: *PlotState,
    p: plot.Plot,
    handles: []const DragHandle,
    active: bool,
    press_edge: bool,
) bool {
    if (handles.len == 0) {
        return false;
    }
    const m: Vec2 = u.getMousePos();
    if (!active) {
        state.drag_active = null;
        return false;
    }
    if (state.drag_active) |idx| {
        if (idx < handles.len) {
            const h: DragHandle = handles[idx];
            if (h.x) |xp| {
                xp.* = p.x.pixelToPlot(m[0]) + state.drag_off[0];
            }
            if (h.y) |yp| {
                yp.* = p.y.pixelToPlot(m[1]) + state.drag_off[1];
            }
            return true;
        }
        state.drag_active = null;
    }
    if (press_edge) {
        for (handles, 0..) |h, i| {
            if (hitHandle(p, h, m)) {
                state.drag_active = i;
                state.drag_off[0] = if (h.x) |xp| xp.* - p.x.pixelToPlot(m[0]) else 0;
                state.drag_off[1] = if (h.y) |yp| yp.* - p.y.pixelToPlot(m[1]) else 0;
                return true;
            }
        }
    }
    return false;
}

/// Draw drag handles on top of the plot, highlighting the hovered/grabbed one.
fn drawDragHandles(
    sink: *DrawListSink,
    p: plot.Plot,
    handles: []const DragHandle,
    state: *const PlotState,
    m: Vec2,
) void {
    const accent: Color = .{ .r = 255, .g = 87, .b = 34, .a = 255 };
    const hole: Color = .{ .r = 22, .g = 22, .b = 26, .a = 255 };
    for (handles, 0..) |h, i| {
        const col: Color = h.color orelse accent;
        const hot: bool = (state.drag_active == i) or hitHandle(p, h, m);
        switch (h.kind) {
            .point => {
                const xp: *f64 = h.x orelse continue;
                const yp: *f64 = h.y orelse continue;
                const hx: f32 = p.x.plotToPixel(xp.*);
                const hy: f32 = p.y.plotToPixel(yp.*);
                const r: f32 = if (hot) h.radius + 2 else h.radius;
                sink.circleFilled(.{ hx, hy }, r, col);
                sink.circleFilled(.{ hx, hy }, r * 0.45, hole);
            },
            .line_x => {
                const xp: *f64 = h.x orelse continue;
                const hx: f32 = p.x.plotToPixel(xp.*);
                sink.line(
                    .{ hx, p.area.y },
                    .{ hx, p.area.bottom() },
                    .{ .color = col, .thickness = if (hot) 2.5 else 1.5 },
                );
            },
            .line_y => {
                const yp: *f64 = h.y orelse continue;
                const hy: f32 = p.y.plotToPixel(yp.*);
                sink.line(
                    .{ p.area.x, hy },
                    .{ p.area.right(), hy },
                    .{ .color = col, .thickness = if (hot) 2.5 else 1.5 },
                );
            },
        }
    }
}

/// Box hit-test: is `m` within `tol` pixels of (hx,hy) on both axes.
fn nearPt(m: Vec2, hx: f32, hy: f32, tol: f32) bool {
    return @abs(m[0] - hx) <= tol and @abs(m[1] - hy) <= tol;
}

/// Grab/drag handling for the rectangle. Returns true while grabbed.
fn processDragRect(
    u: ui.Ui,
    state: *PlotState,
    p: plot.Plot,
    dr: DragRect,
    active: bool,
    press_edge: bool,
) bool {
    const m: Vec2 = u.getMousePos();
    if (!active) {
        state.rect_grab = .none;
        return false;
    }
    if (state.rect_grab != .none) {
        const mx: f64 = p.x.pixelToPlot(m[0]);
        const my: f64 = p.y.pixelToPlot(m[1]);
        switch (state.rect_grab) {
            .move => {
                const w: f64 = dr.x1.* - dr.x0.*;
                const h: f64 = dr.y1.* - dr.y0.*;
                dr.x0.* = mx + state.rect_off[0];
                dr.y0.* = my + state.rect_off[1];
                dr.x1.* = dr.x0.* + w;
                dr.y1.* = dr.y0.* + h;
            },
            .c_x0y0 => {
                dr.x0.* = mx;
                dr.y0.* = my;
            },
            .c_x1y0 => {
                dr.x1.* = mx;
                dr.y0.* = my;
            },
            .c_x0y1 => {
                dr.x0.* = mx;
                dr.y1.* = my;
            },
            .c_x1y1 => {
                dr.x1.* = mx;
                dr.y1.* = my;
            },
            .none => {},
        }
        return true;
    }
    if (!press_edge) {
        return false;
    }
    const px0: f32 = p.x.plotToPixel(dr.x0.*);
    const px1: f32 = p.x.plotToPixel(dr.x1.*);
    const py0: f32 = p.y.plotToPixel(dr.y0.*);
    const py1: f32 = p.y.plotToPixel(dr.y1.*);
    const tol: f32 = 22;
    if (nearPt(m, px0, py0, tol)) {
        state.rect_grab = .c_x0y0;
        return true;
    }
    if (nearPt(m, px1, py0, tol)) {
        state.rect_grab = .c_x1y0;
        return true;
    }
    if (nearPt(m, px0, py1, tol)) {
        state.rect_grab = .c_x0y1;
        return true;
    }
    if (nearPt(m, px1, py1, tol)) {
        state.rect_grab = .c_x1y1;
        return true;
    }
    if (m[0] >= @min(px0, px1) and m[0] <= @max(px0, px1) and
        m[1] >= @min(py0, py1) and m[1] <= @max(py0, py1))
    {
        state.rect_grab = .move;
        state.rect_off[0] = dr.x0.* - p.x.pixelToPlot(m[0]);
        state.rect_off[1] = dr.y0.* - p.y.pixelToPlot(m[1]);
        return true;
    }
    return false;
}

/// Draw the drag-rect: translucent fill, border, and four corner handles.
fn drawDragRect(
    sink: *DrawListSink,
    p: plot.Plot,
    dr: DragRect,
    state: *const PlotState,
) void {
    const col: Color = dr.color orelse .{ .r = 255, .g = 193, .b = 7, .a = 255 };
    const px0: f32 = p.x.plotToPixel(dr.x0.*);
    const px1: f32 = p.x.plotToPixel(dr.x1.*);
    const py0: f32 = p.y.plotToPixel(dr.y0.*);
    const py1: f32 = p.y.plotToPixel(dr.y1.*);
    const x: f32 = @min(px0, px1);
    const y: f32 = @min(py0, py1);
    const w: f32 = @abs(px1 - px0);
    const h: f32 = @abs(py1 - py0);
    sink.fillRect(.{ .x = x, .y = y, .w = w, .h = h }, col.alpha(0.12));
    sink.line(.{ x, y }, .{ x + w, y }, .{ .color = col, .thickness = 1.5 });
    sink.line(.{ x, y + h }, .{ x + w, y + h }, .{ .color = col, .thickness = 1.5 });
    sink.line(.{ x, y }, .{ x, y + h }, .{ .color = col, .thickness = 1.5 });
    sink.line(.{ x + w, y }, .{ x + w, y + h }, .{ .color = col, .thickness = 1.5 });
    const cs: f32 = 5;
    const grabbing: bool = state.rect_grab != .none;
    const corners = [_]Vec2{ .{ px0, py0 }, .{ px1, py0 }, .{ px0, py1 }, .{ px1, py1 } };
    for (corners) |cpt| {
        const r: f32 = if (grabbing) cs + 1 else cs;
        sink.fillRect(.{ .x = cpt[0] - r, .y = cpt[1] - r, .w = r * 2, .h = r * 2 }, col);
    }
}

/// Rubber-band selection: capture the drag start, track the band in data
/// space, and finalize on release (a tap clears the selection).
fn processBoxSelect(
    u: ui.Ui,
    state: *PlotState,
    p: plot.Plot,
    sel: *SelectRect,
    active: bool,
    press_edge: bool,
) void {
    const m: Vec2 = u.getMousePos();
    if (press_edge) {
        state.selecting = true;
        state.sel_start = m;
    }
    if (!state.selecting) {
        return;
    }
    if (active) {
        const ax: f64 = p.x.pixelToPlot(state.sel_start[0]);
        const bx: f64 = p.x.pixelToPlot(m[0]);
        const ay: f64 = p.y.pixelToPlot(state.sel_start[1]);
        const by: f64 = p.y.pixelToPlot(m[1]);
        sel.x0 = @min(ax, bx);
        sel.x1 = @max(ax, bx);
        sel.y0 = @min(ay, by);
        sel.y1 = @max(ay, by);
        sel.active = true;
    } else {
        state.selecting = false;
        sel.active = false;
        const dx: f32 = @abs(m[0] - state.sel_start[0]);
        const dy: f32 = @abs(m[1] - state.sel_start[1]);
        sel.has = dx > 4 or dy > 4;
    }
}

/// Draw the selection band (bright while dragging, faint once completed).
fn drawBoxSelect(sink: *DrawListSink, p: plot.Plot, sel: *const SelectRect) void {
    if (!sel.active and !sel.has) {
        return;
    }
    const col: Color = .{ .r = 0, .g = 229, .b = 255, .a = 255 };
    const px0: f32 = p.x.plotToPixel(sel.x0);
    const px1: f32 = p.x.plotToPixel(sel.x1);
    const py0: f32 = p.y.plotToPixel(sel.y0);
    const py1: f32 = p.y.plotToPixel(sel.y1);
    const x: f32 = @min(px0, px1);
    const y: f32 = @min(py0, py1);
    const w: f32 = @abs(px1 - px0);
    const h: f32 = @abs(py1 - py0);
    const fill_a: f32 = if (sel.active) 0.18 else 0.08;
    sink.fillRect(.{ .x = x, .y = y, .w = w, .h = h }, col.alpha(fill_a));
    const th: f32 = if (sel.active) 1.5 else 1.0;
    sink.line(.{ x, y }, .{ x + w, y }, .{ .color = col, .thickness = th });
    sink.line(.{ x, y + h }, .{ x + w, y + h }, .{ .color = col, .thickness = th });
    sink.line(.{ x, y }, .{ x, y + h }, .{ .color = col, .thickness = th });
    sink.line(.{ x + w, y }, .{ x + w, y + h }, .{ .color = col, .thickness = th });
}

/// Range of size `newsize` centered on `r`'s midpoint.
fn centerTo(r: DataRange, newsize: f64) DataRange {
    const c: f64 = (r.min + r.max) * 0.5;
    return .{ .min = c - newsize * 0.5, .max = c + newsize * 0.5 };
}

/// Grow the smaller-scaled axis so both axes share data-units-per-pixel.
/// Never crops (only expands), and re-lays-out so ticks match. Linear only.
fn applyEqualAspect(state: *PlotState, p: *plot.Plot, frame: plot.Rect) void {
    assertf(
        p.x.scale == .linear and p.y.scale == .linear,
        @src(),
        "equal_aspect requires linear axes",
        .{},
    );
    const wx: f64 = @abs(p.x.px_max - p.x.px_min);
    const wy: f64 = @abs(p.y.px_max - p.y.px_min);
    if (wx <= 0 or wy <= 0) {
        return;
    }
    const target: f64 = @max(state.x.size() / wx, state.y.size() / wy);
    state.x = centerTo(state.x, target * wx);
    state.y = centerTo(state.y, target * wy);
    p.x.range = state.x;
    p.y.range = state.y;
    p.layout(frame);
}

/// Resolve an axis scale from the Options flags (transform wins, then symlog,
/// time, log10, else linear).
fn pickScale(
    transform: ?plot.AxisMap,
    symlog: bool,
    time: bool,
    log: bool,
) plot.Scale {
    if (transform != null) {
        return .custom;
    }
    if (symlog) {
        return .symlog;
    }
    if (time) {
        return .time;
    }
    if (log) {
        return .log10;
    }
    return .linear;
}

fn padRange(r: DataRange) DataRange {
    if (r.size() == 0) {
        const pad: f64 = if (r.min == 0) 0.5 else @abs(r.min) * 0.1;
        return .{ .min = r.min - pad, .max = r.max + pad };
    }
    const pad: f64 = r.size() * 0.05;
    return .{ .min = r.min - pad, .max = r.max + pad };
}

fn fitToSeries(state: *PlotState, series: []const Series) void {
    var xr: DataRange = .{ .min = inf(f64), .max = -inf(f64) };
    var yr: DataRange = .{ .min = inf(f64), .max = -inf(f64) };
    var y2r: DataRange = .{ .min = inf(f64), .max = -inf(f64) };
    var x2r: DataRange = .{ .min = inf(f64), .max = -inf(f64) };
    for (series) |s| {
        if (s.kind == .pie) {
            const r: f64 = s.pie.radius;
            xr.expand(s.pie.cx - r);
            xr.expand(s.pie.cx + r);
            yr.expand(s.pie.cy - r);
            yr.expand(s.pie.cy + r);
            continue;
        }
        if (s.kind == .image) {
            const xrng: *DataRange = if (s.x_axis == .x2) &x2r else &xr;
            xrng.expand(s.img_bounds[0]);
            xrng.expand(s.img_bounds[2]);
            const ir: *DataRange = if (s.axis == .y2) &y2r else &yr;
            ir.expand(s.img_bounds[1]);
            ir.expand(s.img_bounds[3]);
            continue;
        }
        if (s.kind == .heatmap) {
            const xrng: *DataRange = if (s.x_axis == .x2) &x2r else &xr;
            xrng.expand(s.heatmap.x0);
            xrng.expand(s.heatmap.x1);
            const hr: *DataRange = if (s.axis == .y2) &y2r else &yr;
            hr.expand(s.heatmap.y0);
            hr.expand(s.heatmap.y1);
            continue;
        }
        const xrng: *DataRange = if (s.x_axis == .x2) &x2r else &xr;
        if (s.xs.len == 0) {
            // Implicit-x: the series spans sample indices [0, len-1].
            if (s.ys.len > 0) {
                xrng.expand(0);
                xrng.expand(@floatFromInt(s.ys.len - 1));
            }
        } else {
            for (s.xs) |v| {
                xrng.expand(v);
            }
        }
        const tr: *DataRange = if (s.axis == .y2) &y2r else &yr;
        if (s.kind == .candlestick) {
            if (s.lows) |l| {
                for (l) |v| {
                    tr.expand(v);
                }
            }
            if (s.highs) |h| {
                for (h) |v| {
                    tr.expand(v);
                }
            }
        } else {
            for (s.ys) |v| {
                tr.expand(v);
            }
        }
    }
    if (xr.min <= xr.max) {
        state.x = padRange(xr);
    }
    if (yr.min <= yr.max) {
        state.y = padRange(yr);
    }
    if (y2r.min <= y2r.max) {
        state.y2 = padRange(y2r);
    }
    if (x2r.min <= x2r.max) {
        state.x2 = padRange(x2r);
    }
}

/// Pan (drag) and zoom (wheel, around the cursor). Mirrors ImPlot:
/// pan shifts the range by converting the rect edges +/- the per-frame
/// mouse delta back through `pixelToPlot`; zoom expands the range about
/// the cursor's data coordinate.
fn handleInteraction(
    u: ui.Ui,
    state: *PlotState,
    p: plot.Plot,
    frame: plot.Rect,
    hovered: bool,
    active: bool,
    zoom_rate: f32,
    pan_enabled: bool,
) void {
    const touch_count: i32 = u.getTouchPointCount();

    // Double-tap (touch) to fit, mirroring the desktop "Fit" button. Requesting
    // a re-fit clears `fitted`, so the next frame re-frames to the data.
    if (hovered and u.gesture() == .doubletap) {
        state.fitted = false;
        return;
    }

    // ---- pan: single-finger drag / mouse drag (never during a pinch) ----
    if (active and touch_count < 2 and pan_enabled) {
        const d: Vec2 = u.getMouseDragDelta(.left, -1);
        if (d[0] != 0 or d[1] != 0) {
            const nx_min: f64 = p.x.pixelToPlot(p.x.px_min - d[0]);
            const nx_max: f64 = p.x.pixelToPlot(p.x.px_max - d[0]);
            const ny_min: f64 = p.y.pixelToPlot(p.y.px_min - d[1]);
            const ny_max: f64 = p.y.pixelToPlot(p.y.px_max - d[1]);
            state.x = .{ .min = nx_min, .max = nx_max };
            state.y = .{ .min = ny_min, .max = ny_max };
            // Secondary axes share the same pixel span, so shifting them by the
            // same pixel delta keeps their series locked to the primary view.
            if (p.x2_enabled) {
                state.x2 = .{
                    .min = p.x2.pixelToPlot(p.x2.px_min - d[0]),
                    .max = p.x2.pixelToPlot(p.x2.px_max - d[0]),
                };
            }
            if (p.y2_enabled) {
                state.y2 = .{
                    .min = p.y2.pixelToPlot(p.y2.px_min - d[1]),
                    .max = p.y2.pixelToPlot(p.y2.px_max - d[1]),
                };
            }
            // Consume this frame's delta so next frame starts fresh.
            u.resetMouseDragDelta(.left);
        }
    }

    // ---- pinch zoom (touch): shared gesture detector, anchored at the
    // two-finger midpoint. `scale` is 1.0 when not pinching (a no-op). ----
    const pz: ui.Pinch = u.pinch();
    if (pz.scale > 0 and pz.scale != 1.0 and frame.contains(pz.mid)) {
        // scale > 1 = fingers spreading = zoom in -> data window shrinks.
        const factor: f64 = @floatCast(clamp(1.0 / pz.scale, 0.2, 5.0));
        const cx: f64 = p.x.pixelToPlot(pz.mid[0]);
        const cy: f64 = p.y.pixelToPlot(pz.mid[1]);
        state.x = p.x.zoomedRange(cx, factor);
        state.y = p.y.zoomedRange(cy, factor);
        if (p.x2_enabled) {
            state.x2 = p.x2.zoomedRange(p.x2.pixelToPlot(pz.mid[0]), factor);
        }
        if (p.y2_enabled) {
            state.y2 = p.y2.zoomedRange(p.y2.pixelToPlot(pz.mid[1]), factor);
        }
    }

    // ---- zoom: wheel over the plot (desktop), anchored at the cursor ----
    if (hovered and touch_count < 2) {
        const wheel: f32 = u.getMouseWheel();
        if (wheel != 0) {
            const factor: f64 = @floatCast(1.0 - clamp(wheel, -3.0, 3.0) * zoom_rate);
            const m: Vec2 = u.getMousePos();
            const mx: f64 = p.x.pixelToPlot(m[0]);
            const my: f64 = p.y.pixelToPlot(m[1]);
            state.x = p.x.zoomedRange(mx, factor);
            state.y = p.y.zoomedRange(my, factor);
            if (p.x2_enabled) {
                state.x2 = p.x2.zoomedRange(p.x2.pixelToPlot(m[0]), factor);
            }
            if (p.y2_enabled) {
                state.y2 = p.y2.zoomedRange(p.y2.pixelToPlot(m[1]), factor);
            }
        }
    }
}

/// Find the data sample nearest the cursor (within a pixel threshold) and
/// draw a highlight ring + a small "x, y" label. Shows on mouse hover or a
/// single finger; hidden during a two-finger pinch. Inspired by ImPlot's
/// crosshair/tooltip readout, snapped to actual samples.
fn drawReadout(
    u: ui.Ui,
    sink: *DrawListSink,
    p: plot.Plot,
    series: []const Series,
    hovered: bool,
) void {
    const touch_count: i32 = u.getTouchPointCount();
    if (touch_count >= 2) {
        return; // pinching - no readout
    }
    if (!hovered and touch_count != 1) {
        return;
    }
    const cursor: Vec2 = if (touch_count >= 1) u.getTouchPos(0) else u.getMousePos();
    // Cursor must be inside the plot area.
    if (cursor[0] < p.area.x or cursor[0] > p.area.right() or
        cursor[1] < p.area.y or cursor[1] > p.area.bottom())
    {
        return;
    }

    // Nearest sample in pixel space, within a 30px radius.
    var best_d2: f32 = 30.0 * 30.0;
    var best_px: Vec2 = .{ 0, 0 };
    var best_x: f64 = 0;
    var best_y: f64 = 0;
    var found: bool = false;
    for (series) |s| {
        const n: usize = if (s.xs.len == 0) s.ys.len else @min(s.xs.len, s.ys.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const xv: f64 = if (s.xs.len == 0) @floatFromInt(i) else s.xs[i];
            const px: f32 = p.x.plotToPixel(xv);
            const py: f32 = p.y.plotToPixel(s.ys[i]);
            // Skip points outside the plotting area.
            if (px < p.area.x or px > p.area.right() or py < p.area.y or py > p.area.bottom()) {
                continue;
            }
            const dx: f32 = px - cursor[0];
            const dy: f32 = py - cursor[1];
            const d2: f32 = dx * dx + dy * dy;
            if (d2 < best_d2) {
                best_d2 = d2;
                best_px = .{ px, py };
                best_x = xv;
                best_y = s.ys[i];
                found = true;
            }
        }
    }
    if (!found) {
        return;
    }

    const ring_outer: Color = .{ .r = 245, .g = 245, .b = 250, .a = 255 };
    const ring_inner: Color = .{ .r = 24, .g = 24, .b = 30, .a = 255 };
    const box_bg: Color = .{ .r = 18, .g = 18, .b = 24, .a = 235 };
    const box_text: Color = .{ .r = 235, .g = 235, .b = 245, .a = 255 };

    // Highlight ring at the sample.
    sink.circleFilled(best_px, 5.0, ring_outer);
    sink.circleFilled(best_px, 2.5, ring_inner);

    // Value label, boxed, placed up-and-right of the point and clamped inside.
    var buf: [64]u8 = undefined;
    const label: []const u8 = bufPrint(&buf, "{d:.3}, {d:.3}", .{ best_x, best_y }) catch "";
    if (label.len == 0) {
        return;
    }
    const pad: f32 = 4.0;
    const tw: f32 = plot.textWidth(label, 12);
    const box_w: f32 = tw + pad * 2;
    const box_h: f32 = 18.0;
    var bx: f32 = best_px[0] + 10.0;
    var by: f32 = best_px[1] - box_h - 8.0;
    bx = clamp(bx, p.area.x, p.area.right() - box_w);
    by = clamp(by, p.area.y, p.area.bottom() - box_h);
    sink.fillRect(.{ .x = bx, .y = by, .w = box_w, .h = box_h }, box_bg);
    sink.text(.{ bx + pad, by + 3.0 }, label, .{ .size = 12, .color = box_text });
}

/// Draw an interactive plot of `series` into the current window, advancing
/// the layout cursor by `size`. `state` carries the view across frames.
pub fn show(
    u: ui.Ui,
    state: *PlotState,
    size: Vec2,
    series: []const Series,
    opts: Options,
) void {
    const id_str: []const u8 = opts.title orelse "##plot";
    const origin: Vec2 = u.getCursorScreenPos();
    // Reserve the rect AND make it a hit-target for pan/zoom.
    _ = u.invisibleButton(id_str, size);
    const hovered: bool = u.isItemHovered(.{});
    const active: bool = u.isItemActive();
    // Reserve a strip on the right for the colorbar (if any) so the plot area
    // shrinks to make room; the bar + its labels live in the reclaimed space.
    const cbar_w: f32 = if (opts.colorbar != null) 64 else 0;
    const frame: plot.Rect = .{ .x = origin[0], .y = origin[1], .w = size[0] - cbar_w, .h = size[1] };

    // First-frame auto-fit to the data extents (or every frame if auto_fit).
    if (opts.auto_fit) {
        state.fitted = false;
    }
    if (!state.fitted) {
        fitToSeries(state, series);
        state.fitted = true;
    }

    var any_y2: bool = false;
    var any_x2: bool = false;
    for (series) |s| {
        if (s.axis == .y2) {
            any_y2 = true;
        }
        if (s.x_axis == .x2) {
            any_x2 = true;
        }
    }

    // Provisional layout to obtain pixel<->data transforms for interaction.
    var p: plot.Plot = .{ .title = opts.title };
    p.style = opts.style;
    p.x.range = state.x;
    p.y.range = state.y;
    p.x.scale = pickScale(opts.x_transform, opts.x_symlog, opts.x_time, opts.x_log);
    p.y.scale = pickScale(opts.y_transform, opts.y_symlog, false, opts.y_log);
    p.x.linthresh = opts.x_linthresh;
    p.y.linthresh = opts.y_linthresh;
    p.x.transform = opts.x_transform;
    p.y.transform = opts.y_transform;
    p.x.constraints = opts.x_constraints orelse .{};
    p.y.constraints = opts.y_constraints orelse .{};
    p.x.custom_ticks = opts.x_tick_values;
    p.x.custom_labels = opts.x_tick_labels;
    p.y.custom_ticks = opts.y_tick_values;
    p.y.custom_labels = opts.y_tick_labels;
    p.x.format = opts.x_format;
    p.y.format = opts.y_format;
    // Keep the live view within any constraints (covers the fitted range too).
    if (opts.x_constraints) |c| {
        state.x = c.apply(state.x);
    }
    if (opts.y_constraints) |c| {
        state.y = c.apply(state.y);
    }
    p.x.range = state.x;
    p.y.range = state.y;
    p.y2_enabled = any_y2;
    p.y2.range = state.y2;
    p.x2_enabled = any_x2;
    p.x2.range = state.x2;
    p.x.label = opts.x_label;
    p.y.label = opts.y_label;
    p.y2.label = opts.y2_label;
    p.x2.label = opts.x2_label;
    p.layout(frame);

    if (opts.interactive) {
        const press_edge: bool = active and !state.was_active;
        state.was_active = active;
        const hg: bool = processDragHandles(u, state, p, opts.drag_handles, active, press_edge);
        var rg: bool = false;
        if (!hg) {
            if (opts.drag_rect) |dr| {
                rg = processDragRect(u, state, p, dr, active, press_edge);
            }
        }
        var box_active: bool = false;
        if (opts.box_select or opts.box_zoom) {
            processBoxSelect(u, state, p, &state.sel, active, press_edge);
            box_active = true;
            // Box-zoom: a completed band (released, big enough) sets the view to
            // that region and is consumed so it isn't re-applied or left drawn.
            if (opts.box_zoom and state.sel.has) {
                state.x = .{ .min = state.sel.x0, .max = state.sel.x1 };
                state.y = .{ .min = state.sel.y0, .max = state.sel.y1 };
                state.sel.has = false;
                state.sel.active = false;
            }
            // Mirror to the caller's SelectRect (box_select report mode).
            if (opts.selection) |sel| {
                sel.* = state.sel;
            }
        }
        const grabbed: bool = hg or rg;
        handleInteraction(u, state, p, frame, hovered, active, opts.zoom_rate, !grabbed and !box_active);
        // Clamp the post-interaction view to any constraints, then re-layout
        // so ticks/grid match.
        if (opts.x_constraints) |c| {
            state.x = c.apply(state.x);
        }
        if (opts.y_constraints) |c| {
            state.y = c.apply(state.y);
        }
        p.x.range = state.x;
        p.y.range = state.y;
        p.y2.range = state.y2;
        p.x2.range = state.x2;
        p.layout(frame);
    }

    // Equalize data-units-per-pixel last, so it holds after pan/zoom too.
    if (opts.equal_aspect) {
        applyEqualAspect(state, &p, frame);
    }
    // Build legend entries (labeled series) + their series indices. Resolve
    // each series' palette color by draw order so toggling one off never
    // recolors the others.
    var entries: [16]plot.LegendEntry = undefined;
    var entry_sidx: [16]usize = undefined;
    var entry_hidden: [16]bool = undefined;
    var ne: usize = 0;
    for (series, 0..) |s, i| {
        if (s.label) |lbl| {
            if (ne >= entries.len) {
                break;
            }
            const col: Color = switch (s.kind) {
                .bars => s.bars.color orelse plot.autoColor(i),
                .shaded => s.shaded.color orelse plot.autoColor(i),
                .shaded_between => s.shaded.color orelse plot.autoColor(i),
                .inf_lines => s.inflines.color orelse plot.autoColor(i),
                .error_bars, .error_bars_asym => s.errorbars.color orelse plot.autoColor(i),
                else => s.spec.color orelse plot.autoColor(i),
            };
            entries[ne] = .{ .label = lbl, .color = col };
            entry_sidx[ne] = i;
            entry_hidden[ne] = if (i < state.hidden.len) state.hidden[i] else false;
            ne += 1;
        }
    }
    const have_legend: bool = opts.show_legend and ne > 0;
    const lay: plot.LegendLayout = if (have_legend)
        p.legendLayout(entries[0..ne], opts.legend_location, opts.legend_horizontal)
    else
        undefined;

    // Tap a legend row to toggle that series' visibility.
    if (have_legend and opts.interactive and u.gesture() == .tap) {
        if (lay.hit(u.getMousePos())) |row| {
            const si: usize = entry_sidx[row];
            if (si < state.hidden.len) {
                state.hidden[si] = !state.hidden[si];
                entry_hidden[row] = state.hidden[si];
            }
        }
    }

    // Double-tap a legend entry to solo it (hide all other series); double-tap
    // the soloed entry again to restore all. handleInteraction already queued a
    // fit for this double-tap, so we cancel it (fitted = true) to keep the view.
    if (have_legend and opts.interactive and u.gesture() == .doubletap) {
        if (lay.hit(u.getMousePos())) |row| {
            const si: usize = entry_sidx[row];
            // Are we already soloed to `si`? (si visible, every other hidden)
            var is_solo: bool = true;
            for (0..ne) |k| {
                const sk: usize = entry_sidx[k];
                if (sk >= state.hidden.len) {
                    continue;
                }
                if (state.hidden[sk] != (sk != si)) {
                    is_solo = false;
                }
            }
            for (0..ne) |k| {
                const sk: usize = entry_sidx[k];
                if (sk >= state.hidden.len) {
                    continue;
                }
                state.hidden[sk] = if (is_solo) false else (sk != si);
                entry_hidden[k] = state.hidden[sk];
            }
            state.fitted = true; // cancel the fit the double-tap queued
        }
    }

    var sink: DrawListSink = DrawListSink.fromUi(u) orelse return;
    // Optional full-frame background (themes the gutters where labels/title sit).
    if (p.style.panel_bg) |pb| {
        sink.fillRect(frame, pb);
    }
    p.drawFrame(&sink);
    // Clip series to the plot area. The draw-list replay intersects this with
    // the window's clip, so an oversized plot is bounded to its window.
    sink.pushClip(p.area);
    for (series, 0..) |s, i| {
        if (i < state.hidden.len and state.hidden[i]) {
            p.series_count += 1; // consume the palette slot so colors stay put
            continue;
        }
        const use_y2: bool = s.axis == .y2 and p.y2_enabled;
        const use_x2: bool = s.x_axis == .x2 and p.x2_enabled;
        const saved_y: plot.Axis = p.y;
        const saved_x: plot.Axis = p.x;
        if (use_y2) {
            p.y = p.y2;
        }
        if (use_x2) {
            p.x = p.x2;
        }
        switch (s.kind) {
            .line => p.plotLine(&sink, s.xs, s.ys, s.spec),
            .scatter => p.plotScatter(&sink, s.xs, s.ys, s.spec),
            .bars => p.plotBars(&sink, s.xs, s.ys, s.bars),
            .shaded => p.plotShaded(&sink, s.xs, s.ys, s.shaded),
            .stairs => p.plotStairs(&sink, s.xs, s.ys, s.spec),
            .stems => p.plotStems(&sink, s.xs, s.ys, s.spec),
            .inf_lines => p.plotInfLines(&sink, s.xs, s.inflines),
            .error_bars => {
                if (s.err) |e| {
                    p.plotErrorBars(&sink, s.xs, s.ys, e, s.errorbars);
                }
            },
            .error_bars_asym => {
                if (s.err_neg) |en| {
                    if (s.err_pos) |ep| {
                        p.plotErrorBarsAsym(&sink, s.xs, s.ys, en, ep, s.errorbars);
                    }
                }
            },
            .heatmap => {
                if (s.values) |v| {
                    p.plotHeatmap(&sink, v, s.rows, s.cols, s.heatmap);
                }
            },
            .shaded_between => {
                if (s.ys2) |y2| {
                    p.plotShadedBetween(&sink, s.xs, s.ys, y2, s.shaded);
                }
            },
            .bar_groups => {
                if (s.values) |v| {
                    p.plotBarGroups(&sink, v, s.rows, s.cols, s.bargroups);
                }
            },
            .pie => {
                if (s.values) |v| {
                    p.plotPie(&sink, v, s.pie);
                }
            },
            .bubbles => {
                if (s.sizes) |sz| {
                    p.plotBubbles(&sink, s.xs, s.ys, sz, s.bubble);
                }
            },
            .candlestick => {
                if (s.opens) |o| {
                    if (s.highs) |h| {
                        if (s.lows) |l| {
                            if (s.closes) |c| {
                                p.plotCandles(&sink, s.xs, o, h, l, c, s.candle);
                            }
                        }
                    }
                }
            },
            .digital => p.plotDigital(&sink, s.xs, s.ys, s.digital),
            .image => p.plotImage(
                &sink,
                s.tex_id,
                s.img_bounds[0],
                s.img_bounds[1],
                s.img_bounds[2],
                s.img_bounds[3],
                s.image,
            ),
        }
        if (use_y2) {
            p.y = saved_y;
        }
        if (use_x2) {
            p.x = saved_x;
        }
    }
    sink.popClip();
    p.drawDecorations(&sink);
    if (opts.drag_handles.len > 0) {
        sink.pushClip(p.area);
        drawDragHandles(&sink, p, opts.drag_handles, state, u.getMousePos());
        sink.popClip();
    }
    if (opts.drag_rect) |dr| {
        sink.pushClip(p.area);
        drawDragRect(&sink, p, dr, state);
        sink.popClip();
    }
    if (opts.box_select or opts.box_zoom) {
        sink.pushClip(p.area);
        drawBoxSelect(&sink, p, &state.sel);
        sink.popClip();
    }

    if (have_legend) {
        p.drawLegendEx(&sink, entries[0..ne], lay, entry_hidden[0..ne]);
    }

    // Overlays (text / annotations / axis tags) on top of everything.
    for (opts.overlays) |o| {
        switch (o.kind) {
            .text => p.plotText(&sink, o.text, o.x, o.y, o.text_spec),
            .annotation => p.annotation(&sink, o.text, o.x, o.y, o.ann_spec),
            .tag_x => p.tagX(&sink, o.value, o.text, o.tag_spec),
            .tag_y => p.tagY(&sink, o.value, o.text, o.tag_spec),
        }
    }

    // Colorbar in the reserved right strip, vertically aligned to the plot area.
    if (opts.colorbar) |cb| {
        var cbar: plot.ColorbarSpec = cb;
        if (cbar.axis_color == null) {
            cbar.axis_color = p.style.border;
        }
        if (cbar.text_color == null) {
            cbar.text_color = p.style.label;
        }
        const gap: f32 = 8;
        const bar_w: f32 = 16;
        const bar: plot.Rect = .{
            .x = frame.right() + gap,
            .y = p.area.y,
            .w = bar_w,
            .h = p.area.h,
        };
        plot.drawColorbar(&sink, bar, cbar);
    }

    // Nearest-sample value readout. On touch, the hover flag sticks at the
    // last finger position after release, so once we've seen any touch we
    // drive the readout only from a live finger (never stale hover).
    if (opts.interactive) {
        if (u.getTouchPointCount() >= 1) {
            state.seen_touch = true;
        }
        const allow_hover: bool = hovered and !state.seen_touch;
        drawReadout(u, &sink, p, series, allow_hover);
    }

    // Snapshot the final layout for the public query API (getPlotLimits,
    // plotToPixels/pixelsToPlot, getPlotMousePos, plotArea, isInside).
    state.q_area = p.area;
    state.q_x = p.x;
    state.q_y = p.y;
    state.q_x2 = p.x2;
    state.q_y2 = p.y2;
    state.q_mouse = u.getMousePos();
    state.q_valid = true;
}
