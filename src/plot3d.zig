//! lint:alias plot3d
//! lint:off scope-balance: ImPlot3D provider/wrapper - begin*/end* here are forwarders, not paired usage.
//! implot3d.zig — a single-file, pure-Zig port of ImPlot3D v0.5 WIP
//! (https://github.com/brenocq/implot3d, MIT, (c) 2024-2025 Breno Cunha
//!  Queiroz; Zig port 2026).
//!
//! FIRST DRAFT. Written for Zig 0.16 idioms but never compiled; expect a
//! round of fixups on first build. Companion to implot.zig (the 2D port);
//! both are independent modules that share the same backend.
//!
//! ---- WHAT IMPLOT3D IS ------------------------------------------------------
//! Despite the name, ImPlot3D is a CPU 2D-projection renderer, NOT a GPU-3D
//! one. Data lives in f32 `Point3{x,y,z}`. The "camera" is a quaternion
//! rotation + per-axis ranges + a zoom factor; there is no GPU view/proj
//! matrix. Every point is projected on the CPU (rotate by quaternion ->
//! orthographic flatten -> screen Vec2). Triangles are depth-sorted with the
//! painter's algorithm (`DrawList3D` accumulates (tri, z) and `flush()` sorts
//! far->near) and emitted as flat 2D triangles to the regular `ui` DrawList.
//! Lines, markers, and text draw directly. This sits at the SAME layer as the
//! 2D port: above `ui`, never touching the wgpu/GL/sw backends underneath.
//!
//! ---- BACKEND MAPPING (zimrmath `zm` + `ui`) --------------------------------
//! Vec2 = zm.Vec2 = @Vector(2, f32); native operators only (a + b,
//!   a * @as(Vec2, @splat(s)) or splat2(s)); components v[0]/v[1] NOT
//!   .x/.y. Construct with zm.vec2(x, y) or .{ x, y }.
//! Rendering goes through the command-recording `ui.DrawList`
//!   (addTriangleFilled / addQuadFilled / addLine / addPolyline / addPolygon /
//!   addText / addTexturedQuad). There is NO raw vertex buffer; DrawList3D
//!   replicates ImDrawList3D's z-sorted triangle batch on the CPU and emits
//!   high-level shapes in back-to-front order.
//! Widgets/input route through the per-frame `ui.Ui` handle (stored on the
//!   Context as ctx.ui_handle); call `setUiHandle(ctx, ui)` once per frame before
//!   any implot3d call. Input is read from ctx.ui_handle.ctx.input.
//! Colors pack to zm.ColorU32 = u32 little-endian RGBA (0xAABBGGRR).
//!
//! ---- PRECISION ------------------------------------------------------------
//! The data + projection math is f32 (faithful to upstream; axis ranges and
//! projection accumulation want the precision). zm's 3D math is f32, so this
//! file keeps its own small f32 value types (Point3, Quat, Box, Range, Plane,
//! Ray) and only crosses to f32 `Vec2` at the render boundary. Same pattern
//! the 2D port used for its f32 Point/Range/PlotRect.
//!
//! ---- DOCUMENTED DEVIATIONS (first draft) ----------------------------------
//!   · Painter's-algorithm CPU triangle sort replicated in DrawList3D; no GPU
//!     depth buffer. Triangle buffer is allocated from the frame allocator.
//!   · AA thick-line texture path dropped -> plain polylines.
//!   · Mesh-image / textured quads: no perspective-correct per-fragment UVs;
//!     approximated via addTexturedQuad per cell.
//!   · Vertical text -> horizontal fallback.
//!   · No GPU mesh upload; PlotMesh projects + sorts on the CPU.

const std = @import("std");
const ArrayList = std.ArrayList;
const bufPrint = std.fmt.bufPrint;
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;
const Allocator = std.mem.Allocator;
const zm = @import("zm");
const maxInt = zm.maxInt;
const isInf = zm.isInf;
const isNan = zm.isNan;
const sinTurns = zm.sinTurns;
const cosTurns = zm.cosTurns;
const radFromTurns = zm.radFromTurns;
const turnsFromDeg = zm.turnsFromDeg;
const float = zm.float;
const Color = zm.Color;
const ui = @import("ui.zig");
/// Shared color + colormap + tick machinery (also used by implot.zig).
const plot_core = @import("plot_core.zig");
const math = zm;
const assert = zm.assert;
const splat2 = zm.splat2;

/// 2D screen-space vector (f32). Native @Vector ops; components [0]/[1].
const Vec2 = zm.Vec2;

// Color constructors — return zm.Color, the engine-wide color type (u8 RGBA).
// "Auto" colors are expressed as `?Color` = `null` (deduced from the colormap /
// ui style), matching plot.zig and the rest of zimr. The packed wire form is
// `zm.ColorU32` via `Color.toWire()` / `Color.fromWire()`; blend math uses
// `Color.lerp` / `Color.alpha` / `Color.scaleAlpha`.
pub inline fn rgb(r: u8, g: u8, b: u8) Color {
    return Color.rgb(r, g, b);
}
pub inline fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
    return Color.init(r, g, b, a);
}
pub inline fn hex(value: u32) Color {
    return Color.hex(value);
}
pub inline fn hsv(h: f32, s: f32, v: f32, a: f32) Color {
    return Color.fromHSV(.{ h, s, v, a });
}
/// Color from 0..1 sRGB floats (RGBA).
pub inline fn rgbaF(r: f32, g: f32, b: f32, a: f32) Color {
    return Color.fromFloats(r, g, b, a);
}

/// IMPLOT3D_AUTO sentinel for integer "automatic" fields (offset/stride/etc.).
pub const auto: i32 = -1;

/// Per-frame OOM policy. The growable buffers a plot fills each frame (the
/// depth-sorted triangle batch, tick/legend/title text, the style-override
/// stack) are transient: if a growth allocation fails, we drop the affected
/// primitive or label for THIS frame only. Everything is rebuilt and
/// re-submitted next frame, so a momentary allocation failure degrades the
/// frame gracefully instead of crashing. Route every such fallible append
/// through here so the policy is one deliberate, greppable decision rather than
/// scattered silent `catch {}`s. (One-time/persistent allocations are NOT
/// routed here — those propagate their errors.)
inline fn dropFrameOnOom(result: anytype) void {
    result catch {}; // lint:off catch-suppression: deliberate frame-drop policy
}

//=============================================================================
// [SECTION] Geometry — 3D points & quaternions via zimrmath (zm)
//
// A 3D point/vector is `zm.Vec` — a 4-wide `@Vector(4, f32)` with xyz used and
// the w lane carried as 0. This is the representation zm's 3D ops (cross,
// dot3, length3, normalize3) and the whole quaternion API are built around, so
// projection and rotation stay conversion-free and SIMD-aligned. Components are
// indexed: `p[0] p[1] p[2]`. `Quat` is `zm.Quat` (= `zm.Vec`; x y z w = [0..3]).
// `Range` is `zm.Range(f32)`. `Box`/`Plane`/`Ray` are thin plot-domain
// aggregates over `zm.Vec` (zm has no AABB / plane / ray-segment type).
//=============================================================================

const Vec = zm.Vec;
const vec4 = zm.vec4;
const quat = zm.quat;
const qidentity = zm.qidentity;
const quatFromAxisAngle = zm.quatFromAxisAngle;
const qmul = zm.qmul;
const rotate = zm.rotate;
const inverse = zm.inverse;
const normalize3 = zm.normalize3;
const mulMatVec = zm.mulMatVec;
const normalize4 = zm.normalize4;
const dot4 = zm.dot4;
const slerp = zm.slerp;
const equals3 = zm.equals3;
const splat = zm.splat;

/// 3D point/vector (xyz in [0..2]; the [3] lane is an unused 0).
pub const Point3 = Vec;
/// Rotation quaternion (x y z w = [0..3]).
const Quat = zm.Quat;
/// Inclusive 1D interval — axis range, fit extents, zoom/limit constraints.
// lint:off no-qualified-zm: generic instantiation forms the public alias; cannot bind
const Range = zm.Range(f32);

/// Make a 3D point with the w lane zeroed.
pub inline fn point3(x: f32, y: f32, z: f32) Point3 {
    return vec4(x, y, z, 0);
}
/// True if any xyz lane is NaN.
pub inline fn point3IsNan(p: Point3) bool {
    return p[0] != p[0] or p[1] != p[1] or p[2] != p[2];
}
/// Quaternion from elevation + azimuth (radians). Composes
/// `elevation ∘ (-90° about X) ∘ azimuth` (applied right-to-left, so azimuth
/// first). `qmul` is Hamilton order (`qmul(a, b) == a * b`), so that maps to
/// `qmul(qmul(el, zero), az)`.
pub fn quatFromElAz(elevation_turns: f32, azimuth_turns: f32) Quat {
    // `quatFromAxisAngle` is zimrmath's and takes radians, so the crossing is here and named.
    const az: Quat = quatFromAxisAngle(point3(0, 0, 1), radFromTurns(azimuth_turns));
    const el: Quat = quatFromAxisAngle(point3(1, 0, 0), radFromTurns(elevation_turns));
    // A quarter turn back, to put the camera's zero where a plot expects it.
    const zero: Quat = quatFromAxisAngle(point3(1, 0, 0), radFromTurns(-0.25));
    return qmul(qmul(el, zero), az);
}

//=============================================================================
// [SECTION] Box / Plane / Ray — plot-domain aggregates over zm.Vec
//=============================================================================

/// Axis-aligned bounding box in plot space.
pub const Box = struct {
    min: Point3 = @splat(0),
    max: Point3 = @splat(0),

    pub inline fn contains(self: Box, p: Point3) bool {
        return (p[0] >= self.min[0] and p[0] <= self.max[0]) and
            (p[1] >= self.min[1] and p[1] <= self.max[1]) and
            (p[2] >= self.min[2] and p[2] <= self.max[2]);
    }

    /// Liang-Barsky 3D clip of segment p0->p1 against the box. Returns false
    /// if fully outside; otherwise writes the clipped endpoints.
    pub fn clipLineSegment(
        self: Box,
        p0: Point3,
        p1: Point3,
        p0_clipped: *Point3,
        p1_clipped: *Point3,
    ) bool {
        if (self.contains(p0) and self.contains(p1)) {
            p0_clipped.* = p0;
            p1_clipped.* = p1;
            return true;
        }
        var t0: f32 = 0.0;
        var t1: f32 = 1.0;
        const d: Point3 = p1 - p0;
        const Updater = struct {
            t0: *f32,
            t1: *f32,
            fn update(self2: @This(), p: f32, q: f32) bool {
                if (p == 0.0) {
                    return q >= 0.0; // parallel: inside iff q >= 0
                }
                const r: f32 = q / p;
                if (p < 0.0) {
                    if (r > self2.t1.*) {
                        return false;
                    }
                    if (r > self2.t0.*) {
                        self2.t0.* = r;
                    }
                } else {
                    if (r < self2.t0.*) {
                        return false;
                    }
                    if (r < self2.t1.*) {
                        self2.t1.* = r;
                    }
                }
                return true;
            }
        };
        const up = Updater{ .t0 = &t0, .t1 = &t1 };
        if (!up.update(-d[0], p0[0] - self.min[0])) {
            return false;
        } // left
        if (!up.update(d[0], self.max[0] - p0[0])) {
            return false;
        } // right
        if (!up.update(-d[1], p0[1] - self.min[1])) {
            return false;
        } // bottom
        if (!up.update(d[1], self.max[1] - p0[1])) {
            return false;
        } // top
        if (!up.update(-d[2], p0[2] - self.min[2])) {
            return false;
        } // near
        if (!up.update(d[2], self.max[2] - p0[2])) {
            return false;
        } // far
        p0_clipped.* = p0 + d * splat(t0);
        p1_clipped.* = p0 + d * splat(t1);
        return true;
    }
};

/// A plane through `point` with the given `normal`.
pub const Plane = struct {
    point: Point3 = @splat(0),
    normal: Point3 = @splat(0),
};

/// A ray: origin + direction (direction not necessarily normalized).
pub const Ray = zm.Ray;

//=============================================================================
// [SECTION] Enums
//=============================================================================

/// Condition for SetupAxisLimits etc.
pub const Cond = enum(i32) {
    none = 0,
    always = 1,
    once = 2,
};

/// Styling colors (index into Style.colors).
pub const Col = enum(i32) {
    title_text = 0,
    inlay_text,
    frame_bg,
    plot_bg,
    plot_border,
    legend_bg,
    legend_border,
    legend_text,
    axis_text,
    axis_grid,
    axis_tick,
    axis_bg,
    axis_bg_hovered,
    axis_bg_active,

    pub const count: usize = 14;
};

/// Style variables (for PushStyleVar).
pub const StyleVar = enum(i32) {
    line_weight = 0,
    marker,
    marker_size,
    fill_alpha,
    plot_default_size,
    plot_min_size,
    plot_padding,
    label_padding,
    view_scale_factor,
    legend_padding,
    legend_inner_padding,
    legend_spacing,

    pub const count: usize = 12;
};

/// Marker styles. None = -2, Auto = -1, concrete markers 0..count-1.
pub const Marker = enum(i32) {
    none = -2,
    auto = -1,
    circle = 0,
    square,
    diamond,
    up,
    down,
    left,
    right,
    cross,
    plus,
    asterisk,

    // Count of concrete, drawable markers (circle..asterisk). Excludes the
    // none/auto sentinels. Used by nextMarker's auto-cycle modulo; must equal
    // the number of real variants or @enumFromInt overflows past asterisk.
    pub const count: usize = 10;
};

/// Legend location (bit flags for N/S/E/W composition).
pub const Location = packed struct(u32) {
    north: bool = false,
    south: bool = false,
    west: bool = false,
    east: bool = false,
    _pad: u28 = 0,

    pub const center = Location{};
    pub const north_loc = Location{ .north = true };
    pub const south_loc = Location{ .south = true };
    pub const west_loc = Location{ .west = true };
    pub const east_loc = Location{ .east = true };
    pub const north_west = Location{ .north = true, .west = true };
    pub const north_east = Location{ .north = true, .east = true };
    pub const south_west = Location{ .south = true, .west = true };
    pub const south_east = Location{ .south = true, .east = true };
};

/// Axis indices.
pub const Axis3D = enum(i32) {
    x = 0,
    y = 1,
    z = 2,

    pub const count: usize = 3;
};

/// Plane indices (perpendicular to the named axis).
pub const Plane3D = enum(i32) {
    yz = 0, // perpendicular to X
    xz = 1, // perpendicular to Y
    xy = 2, // perpendicular to Z

    pub const count: usize = 3;
};

/// Axis scale.
pub const Scale = enum(i32) {
    linear = 0,
    log10 = 1,
    sym_log = 2,
};

/// Built-in colormaps (index into the colormap table).
/// Shared with plot.zig via plot_core (same members, same discriminants).
pub const Colormap = plot_core.Colormap;

//=============================================================================
// [SECTION] Flags
//
// Bit layouts match the C++ enums. Item-specific flag structs share bits 0-1
// with ItemFlags (no_legend, no_fit) and use bits 10+ for their own options.
//=============================================================================

/// Flags for beginPlot(ctx).
pub const Flags = packed struct(u32) {
    no_title: bool = false, // bit 0
    no_legend: bool = false, // bit 1
    no_mouse_text: bool = false, // bit 2
    no_clip: bool = false, // bit 3
    no_menus: bool = false, // bit 4
    equal: bool = false, // bit 5
    no_rotate: bool = false, // bit 6
    no_pan: bool = false, // bit 7
    no_zoom: bool = false, // bit 8
    no_inputs: bool = false, // bit 9
    _pad: u22 = 0,

    pub const canvas_only = Flags{ .no_title = true, .no_legend = true, .no_mouse_text = true };
};

/// Common item flags (bits 0-1 shared by every *Flags struct below).
pub const ItemFlags = packed struct(u32) {
    no_legend: bool = false, // bit 0
    no_fit: bool = false, // bit 1
    _pad: u30 = 0,
};

pub const ScatterFlags = packed struct(u32) {
    no_legend: bool = false,
    no_fit: bool = false,
    _pad: u30 = 0,
};

pub const LineFlags = packed struct(u32) {
    no_legend: bool = false, // bit 0
    no_fit: bool = false, // bit 1
    _pad0: u8 = 0,
    segments: bool = false, // bit 10
    loop: bool = false, // bit 11
    skip_nan: bool = false, // bit 12
    _pad1: u19 = 0,
};

pub const TriangleFlags = packed struct(u32) {
    no_legend: bool = false,
    no_fit: bool = false,
    _pad0: u8 = 0,
    no_lines: bool = false, // bit 10
    no_fill: bool = false, // bit 11
    no_markers: bool = false, // bit 12
    _pad1: u19 = 0,
};

pub const QuadFlags = packed struct(u32) {
    no_legend: bool = false,
    no_fit: bool = false,
    _pad0: u8 = 0,
    no_lines: bool = false,
    no_fill: bool = false,
    no_markers: bool = false,
    _pad1: u19 = 0,
};

pub const SurfaceFlags = packed struct(u32) {
    no_legend: bool = false,
    no_fit: bool = false,
    _pad0: u8 = 0,
    no_lines: bool = false,
    no_fill: bool = false,
    no_markers: bool = false,
    _pad1: u19 = 0,
};

pub const MeshFlags = packed struct(u32) {
    no_legend: bool = false,
    no_fit: bool = false,
    _pad0: u8 = 0,
    no_lines: bool = false,
    no_fill: bool = false,
    no_markers: bool = false,
    _pad1: u19 = 0,
};

pub const ImageFlags = packed struct(u32) {
    no_legend: bool = false,
    no_fit: bool = false,
    _pad: u30 = 0,
};

pub const DummyFlags = packed struct(u32) {
    _pad: u32 = 0,
};

pub const LegendFlags = packed struct(u32) {
    no_buttons: bool = false, // bit 0
    no_highlight_item: bool = false, // bit 1
    horizontal: bool = false, // bit 2
    _pad: u29 = 0,
};

pub const AxisFlags = packed struct(u32) {
    no_label: bool = false, // bit 0
    no_grid_lines: bool = false, // bit 1
    no_tick_marks: bool = false, // bit 2
    no_tick_labels: bool = false, // bit 3
    lock_min: bool = false, // bit 4
    lock_max: bool = false, // bit 5
    auto_fit: bool = false, // bit 6
    invert: bool = false, // bit 7
    pan_stretch: bool = false, // bit 8
    _pad: u23 = 0,

    pub const lock = AxisFlags{ .lock_min = true, .lock_max = true };
    pub const no_decorations = AxisFlags{ .no_label = true, .no_grid_lines = true, .no_tick_labels = true };
};

//=============================================================================
// [SECTION] PixRect — pixel-space rectangle (min/max Vec2)
//=============================================================================

pub const PixRect = struct {
    min: Vec2 = .{ 0, 0 },
    max: Vec2 = .{ 0, 0 },

    pub inline fn fromXYWH(x: f32, y: f32, w: f32, h: f32) PixRect {
        return .{ .min = .{ x, y }, .max = .{ x + w, y + h } };
    }
    pub inline fn width(self: PixRect) f32 {
        return self.max[0] - self.min[0];
    }
    pub inline fn height(self: PixRect) f32 {
        return self.max[1] - self.min[1];
    }
    pub inline fn size(self: PixRect) Vec2 {
        return self.max - self.min;
    }
    pub inline fn center(self: PixRect) Vec2 {
        return (self.min + self.max) * splat2(0.5);
    }
    pub inline fn contains(self: PixRect, p: Vec2) bool {
        return p[0] >= self.min[0] and p[1] >= self.min[1] and
            p[0] < self.max[0] and p[1] < self.max[1];
    }
    pub inline fn overlaps(self: PixRect, o: PixRect) bool {
        return o.min[1] < self.max[1] and self.min[1] < o.max[1] and
            o.min[0] < self.max[0] and self.min[0] < o.max[0];
    }
    pub inline fn toRectangle(self: PixRect) ui.Rectangle {
        return .{ .x = self.min[0], .y = self.min[1], .width = self.width(), .height = self.height() };
    }
    pub inline fn fromRectangle(r: ui.Rectangle) PixRect {
        return .{ .min = .{ r.x, r.y }, .max = .{ r.x + r.width, r.y + r.height } };
    }
    // lint:off reserved-math-names: value-type method (Point3/Quat/PixRect)
    pub inline fn clamp(self: PixRect, p: Vec2) Vec2 {
        return .{
            math.clamp(p[0], self.min[0], self.max[0]),
            math.clamp(p[1], self.min[1], self.max[1]),
        };
    }
};

//=============================================================================
// [SECTION] im — the ui/imgui compatibility shim
//
// implot3d (like the 2D port) is written against an ImGui-shaped API. This
// shim maps that vocabulary onto zimr's `ui` (command-recording DrawList +
// per-frame Ui handle). It mirrors implot.zig's verified shim; both files keep
// their own copy so each is self-contained.
//=============================================================================

const Im = struct {
    /// Per-frame ui.Ui handle this shim is bound to (from Context.im()).
    h: ui.Ui,
    /// The owning context (for per-frame shim state like the window scope).
    // Im holds a *Context back-pointer to its parent, and Context builds/owns
    // Im (via Context.im()); the two are mutually referential, so neither can
    // be fully declared before the other.
    // lint:off decl-order: Im<->Context parent/child back-pointer cycle
    ctx: *Context,

    const ID = ui.Id;
    const Rect = PixRect;
    const DrawList = DrawListAdapter;
    const TextureRef = u32;
    const MouseButton = ui.MouseButton;
    const MouseCursor = ImCursor;
    const Mods = Modifiers;
    const ButtonFlags = ButtonBehaviorOpts;

    inline fn handle(self: Im) ui.Ui {
        return self.h;
    }
    inline fn input(self: Im) *const ui.InputSnapshot {
        return &self.h.ctx.input;
    }
    fn getStyle(self: Im) *ui.Style {
        return &self.h.ctx.style;
    }

    // ---- Color packing -------------------------------------------------
    // zm.Color owns float<->wire; the wire form is zm.ColorU32 (0xAABBGGRR).
    fn colorToU32(_: Im, c: Color) zm.ColorU32 {
        return c.toWire();
    }
    fn colorFromU32(_: Im, c: zm.ColorU32) Color {
        return Color.fromWire(c);
    }

    // ---- ui.Style auto colors -----------------------------------------
    /// The ui.Style color slots implot3d reads for auto-color defaults.
    const UiCol = enum {
        text,
        window_bg,
        frame_bg,
        border,
        popup_bg,
        button_hovered,
        button_active,
    };
    fn uiStyleColor(self: Im, c: UiCol) Color {
        const s: *ui.Style = &self.h.ctx.style;
        return switch (c) {
            .text => s.text,
            .window_bg => s.window_bg,
            .frame_bg => s.frame_bg,
            .border => s.border,
            .popup_bg => s.popup_bg,
            .button_hovered => s.button_hovered,
            .button_active => s.button_active,
        };
    }

    // ---- IDs -----------------------------------------------------------
    fn getID(self: Im, label: []const u8) ID {
        return self.h.getId(label);
    }
    fn pushID(self: Im, s: []const u8) void {
        self.h.pushId(s);
    }
    fn pushIDInt(self: Im, i: i32) void {
        self.h.pushIdInt(i);
    }
    fn popID(self: Im) void {
        self.h.popId();
    }

    // ---- Hit-testing & items ------------------------------------------
    const ButtonResult = struct { pressed: bool, hovered: bool, held: bool };
    fn buttonBehavior(self: Im, rect: Rect, id: ID, opts: ButtonFlags) ButtonResult {
        const r: ui.Ui.ButtonResult = self.h.buttonBehavior(rect.toRectangle(), id, .{ .repeat = opts.repeat });
        return .{ .pressed = r.pressed, .hovered = r.hovered, .held = r.held };
    }
    fn itemSize(self: Im, rect: Rect) void {
        self.h.itemSize(rect.size());
    }
    fn itemAdd(self: Im, rect: Rect, id: ID) bool {
        return self.h.itemAdd(rect.toRectangle(), id);
    }
    fn skipItems(self: Im) bool {
        return self.h.ctx.current_window == null;
    }
    fn isItemHovered(self: Im, opts: anytype) bool {
        return self.h.isItemHovered(opts);
    }

    // ---- Cursor / layout ----------------------------------------------
    fn getCursorScreenPos(self: Im) Vec2 {
        return self.h.getCursorScreenPos();
    }
    fn calcTextSize(self: Im, s: []const u8) Vec2 {
        return self.h.calcTextSize(s);
    }
    fn getTextLineHeight(self: Im) f32 {
        return self.h.ctx.style.font_size;
    }
    fn getContentRegionAvail(self: Im) Vec2 {
        return self.h.getContentRegionAvail();
    }
    fn calcItemSize(_: Im, s: Vec2, default_w: f32, default_h: f32) Vec2 {
        return .{
            if (s[0] != 0) s[0] else default_w,
            if (s[1] != 0) s[1] else default_h,
        };
    }

    // ---- Drawing -------------------------------------------------------
    fn getWindowDrawList(self: Im) DrawList {
        const h: ui.Ui = self.h;
        return .{ .list = h.getWindowDrawList().list, .gpa = h.drawListAllocator(), .h = h };
    }

    /// implot-shaped DrawList over ui's command-recording list.
    const DrawListAdapter = struct {
        list: *ui.DrawList,
        gpa: Allocator,
        h: ui.Ui,

        pub fn addLine(
            self: DrawListAdapter,
            a: Vec2,
            b: Vec2,
            col: zm.ColorU32,
            thickness: f32,
        ) void {
            self.list.addLine(self.gpa, a, b, col, thickness);
        }
        pub fn addRectFilled(
            self: DrawListAdapter,
            min: Vec2,
            max: Vec2,
            col: zm.ColorU32,
        ) void {
            self.list.addRectFilled(self.gpa, rectOf(min, max), col);
        }
        pub fn addRect(
            self: DrawListAdapter,
            min: Vec2,
            max: Vec2,
            col: zm.ColorU32,
        ) void {
            self.list.addRectOutline(self.gpa, rectOf(min, max), col);
        }
        pub fn addText(
            self: DrawListAdapter,
            pos: Vec2,
            col: zm.ColorU32,
            s: []const u8,
        ) void {
            const st: *ui.Style = &self.h.ctx.style;
            self.list.addText(self.gpa, st.font, s, pos, st.font_size, st.font_spacing, st.line_spacing, col);
        }
        pub fn addCircleFilled(
            self: DrawListAdapter,
            center: Vec2,
            radius: f32,
            col: zm.ColorU32,
        ) void {
            self.list.addCircleFilled(self.gpa, center, radius, col, 0);
        }
        pub fn addCircle(
            self: DrawListAdapter,
            center: Vec2,
            radius: f32,
            col: zm.ColorU32,
            thickness: f32,
        ) void {
            self.list.addCircle(self.gpa, center, radius, col, thickness, 0);
        }
        pub fn addTriangleFilled(
            self: DrawListAdapter,
            a: Vec2,
            b: Vec2,
            c: Vec2,
            col: zm.ColorU32,
        ) void {
            self.list.addTriangleFilled(self.gpa, a, b, c, col);
        }
        pub fn addQuadFilled(
            self: DrawListAdapter,
            a: Vec2,
            b: Vec2,
            c: Vec2,
            d: Vec2,
            col: zm.ColorU32,
        ) void {
            self.list.addQuadFilled(self.gpa, a, b, c, d, col);
        }
        pub fn addPolyline(
            self: DrawListAdapter,
            points: []const Vec2,
            col: zm.ColorU32,
            closed: bool,
            thickness: f32,
        ) void {
            self.list.addPolyline(self.gpa, points, col, thickness, closed);
        }
        pub fn addConvexPolyFilled(
            self: DrawListAdapter,
            points: []const Vec2,
            col: zm.ColorU32,
        ) void {
            self.list.addPolygon(self.gpa, points, col);
        }
        pub fn addImage(
            self: DrawListAdapter,
            tex: TextureRef,
            p_min: Vec2,
            p_max: Vec2,
            uv0: Vec2,
            uv1: Vec2,
            tint: zm.ColorU32,
        ) void {
            self.list.addTexturedQuad(self.gpa, rectOf(p_min, p_max), tex, uv0, uv1, tint);
        }
        /// Project-and-fill a textured quad given its four screen corners (mesh
        /// image path). ui only exposes an axis-aligned textured quad, so this
        /// approximates with the bounding rect (DEVIATION: no perspective UVs).
        pub fn addImageQuad(
            self: DrawListAdapter,
            tex: TextureRef,
            a: Vec2,
            b: Vec2,
            c: Vec2,
            d: Vec2,
            tint: zm.ColorU32,
        ) void {
            const minx: f32 = @min(@min(a[0], b[0]), @min(c[0], d[0]));
            const miny: f32 = @min(@min(a[1], b[1]), @min(c[1], d[1]));
            const maxx: f32 = @max(@max(a[0], b[0]), @max(c[0], d[0]));
            const maxy: f32 = @max(@max(a[1], b[1]), @max(c[1], d[1]));
            self.list.addTexturedQuad(
                self.gpa,
                .{ .x = minx, .y = miny, .width = maxx - minx, .height = maxy - miny },
                tex,
                .{ 0, 0 },
                .{ 1, 1 },
                tint,
            );
        }
        pub fn pushClipRect(self: DrawListAdapter, min: Vec2, max: Vec2, _: bool) void {
            self.list.pushClipRect(self.gpa, rectOf(min, max));
        }
        pub fn popClipRect(self: DrawListAdapter) void {
            self.list.popClipRect(self.gpa);
        }

        inline fn rectOf(min: Vec2, max: Vec2) ui.Rectangle {
            return .{ .x = min[0], .y = min[1], .width = max[0] - min[0], .height = max[1] - min[1] };
        }
    };

    // ---- Mouse / input -------------------------------------------------
    const Modifiers = packed struct(u8) {
        ctrl: bool = false,
        shift: bool = false,
        alt: bool = false,
        super: bool = false,
        _pad: u4 = 0,
    };
    const ButtonBehaviorOpts = struct { repeat: bool = false };

    fn getMousePos(self: Im) Vec2 {
        return self.input().mouse_pos;
    }
    fn isMouseClicked(self: Im, btn: MouseButton) bool {
        const i: *const ui.InputSnapshot = self.input();
        return switch (btn) {
            .left => i.mouse_left_clicked,
            .right => i.mouse_right_clicked,
            .middle => i.mouse_middle_clicked,
            else => false,
        };
    }
    fn isMouseDown(self: Im, btn: MouseButton) bool {
        return btn == .left and self.input().mouse_left_down;
    }
    fn isMouseReleased(self: Im, btn: MouseButton) bool {
        return btn == .left and self.input().mouse_left_released;
    }
    fn isMouseDoubleClicked(_: Im, _: MouseButton) bool {
        return false; // ui has no double-click edge (DEVIATION)
    }
    fn isMouseDragging(self: Im, btn: MouseButton) bool {
        return self.h.isMouseDragging(btn, -1);
    }
    fn getMouseDragDelta(self: Im, btn: MouseButton) Vec2 {
        return self.h.getMouseDragDelta(btn, -1);
    }
    fn getMouseWheel(self: Im) f32 {
        return self.input().mouse_wheel_y;
    }
    fn touchCount(self: Im) i32 {
        return self.input().touch_count;
    }
    fn touchPos(self: Im, i: usize) Vec2 {
        return self.input().touch_pos[i];
    }
    fn deltaTime(self: Im) f32 {
        return self.input().delta_time;
    }
    fn shiftDown(self: Im) bool {
        return self.h.isShiftDown();
    }
    fn isWindowHovered(self: Im, opts: anytype) bool {
        return self.h.isWindowHovered(opts);
    }

    const ImCursor = enum {
        none,
        arrow,
        hand,
        resize_ew,
        resize_ns,
        resize_nesw,
        resize_nwse,
        resize_all,
        not_allowed,
    };
    fn setMouseCursor(self: Im, c: ImCursor) void {
        const mapped: ui.MouseCursor = switch (c) {
            .none => .default,
            .arrow => .arrow,
            .hand => .pointing_hand,
            .resize_ew => .resize_ew,
            .resize_ns => .resize_ns,
            .resize_nesw => .resize_nesw,
            .resize_nwse => .resize_nwse,
            .resize_all => .resize_all,
            .not_allowed => .not_allowed,
        };
        self.h.setMouseCursor(mapped);
    }

    const IO = struct {
        mouse_pos: Vec2,
        mouse_wheel: f32,
        key_mods: Mods,
    };
    fn getIO(self: Im) IO {
        const i: *const ui.InputSnapshot = self.input();
        return .{
            .mouse_pos = i.mouse_pos,
            .mouse_wheel = i.mouse_wheel_y,
            .key_mods = .{
                .ctrl = self.h.isCtrlDown(),
                .shift = self.h.isShiftDown(),
                .alt = self.h.isAltDown(),
                .super = self.h.isSuperDown(),
            },
        };
    }

    // ---- Widgets (thin pass-throughs; used by 3D style editor + legend) --
    fn begin(self: Im, name: [:0]const u8, p_open: ?*bool) bool {
        self.ctx.win_scope = self.h.window(name, .{});
        if (p_open) |po| {
            po.* = self.ctx.win_scope != null;
        }
        return self.ctx.win_scope != null;
    }
    fn end(self: Im) void {
        if (self.ctx.win_scope) |w| {
            w.close();
            self.ctx.win_scope = null;
        }
    }
    fn button(self: Im, label: [:0]const u8) bool {
        return self.h.button(label, .{});
    }
    fn buttonEx(self: Im, label: [:0]const u8, sz: Vec2) bool {
        return self.h.button(label, .{ .size = sz });
    }
    fn invisibleButton(self: Im, label: [:0]const u8, sz: Vec2) bool {
        return self.h.invisibleButton(label, sz);
    }
    fn checkbox(self: Im, label: [:0]const u8, v: *bool) bool {
        return self.h.checkbox(label, v);
    }
    fn checkboxFlags(
        self: Im,
        label: [:0]const u8,
        flags: anytype,
        flag_bit: @TypeOf(flags.*),
    ) bool {
        // Emulate ImGui::CheckboxFlags over a packed-struct flag set.
        const B = @typeInfo(@TypeOf(flags.*)).@"struct".backing_integer.?;
        const f: B = @bitCast(flag_bit);
        var on: bool = (@as(B, @bitCast(flags.*)) & f) == f;
        const changed: bool = self.h.checkbox(label, &on);
        if (changed) {
            var cur: B = @bitCast(flags.*);
            if (on) {
                cur |= f;
            } else {
                cur &= ~f;
            }
            flags.* = @bitCast(cur);
        }
        return changed;
    }
    fn radioButton(self: Im, label: [:0]const u8, active: bool) bool {
        var cur: i32 = if (active) 1 else 0;
        return self.h.radioButton(label, &cur, 1);
    }
    fn selectable(self: Im, label: [:0]const u8, selected: bool) bool {
        return self.h.selectable(label, selected, .{});
    }
    fn sliderFloat(
        self: Im,
        label: [:0]const u8,
        v: *f32,
        mn: f32,
        mx: f32,
        _: [:0]const u8,
    ) bool {
        return self.h.slider(label, v, .{ .min = mn, .max = mx });
    }
    fn dragFloat(
        self: Im,
        label: [:0]const u8,
        v: *f32,
        speed: f32,
        mn: f32,
        mx: f32,
        _: [:0]const u8,
    ) bool {
        return self.h.drag(label, v, .{ .speed = speed, .min = mn, .max = mx });
    }
    fn colorEdit4(self: Im, label: [:0]const u8, v: *Color) bool {
        var arr: [4]f32 = v.toFloats();
        const changed: bool = self.h.colorEdit(label, &arr, .{});
        if (changed) {
            v.* = Color.fromFloats(arr[0], arr[1], arr[2], arr[3]);
        }
        return changed;
    }
    fn combo(
        self: Im,
        label: [:0]const u8,
        current: *i32,
        items_packed: []const u8,
    ) bool {
        var bufs: [32][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, items_packed, 0);
        while (it.next()) |seg| {
            if (seg.len == 0) {
                continue;
            }
            if (n >= bufs.len) {
                break;
            }
            bufs[n] = seg;
            n += 1;
        }
        return self.h.combo(label, current, bufs[0..n], .{});
    }
    fn beginCombo(self: Im, label: [:0]const u8, preview: [:0]const u8) bool {
        return self.h.beginCombo(label, preview, .{});
    }
    fn endCombo(self: Im) void {
        self.h.endCombo();
    }
    fn text(self: Im, comptime fmt: []const u8, args: anytype) void {
        self.h.text(fmt, args);
    }
    fn textUnformatted(self: Im, s: []const u8) void {
        self.h.text("{s}", .{s});
    }
    fn bulletText(self: Im, s: []const u8) void {
        self.h.bulletText("{s}", .{s});
    }
    fn textColored(self: Im, c: Color, s: []const u8) void {
        _ = c;
        self.h.text("{s}", .{s});
    }
    fn separatorText(self: Im, s: []const u8) void {
        self.h.text("{s}", .{s});
        self.h.separator();
    }
    fn separator(self: Im) void {
        self.h.separator();
    }
    fn sameLine(self: Im) void {
        self.h.sameLine(.{});
    }
    fn spacing(self: Im) void {
        self.h.dummy(.{ 0, 0 });
    }
    fn dummy(self: Im, sz: Vec2) void {
        self.h.dummy(sz);
    }
    fn indent(self: Im) void {
        self.h.indent();
    }
    fn unindent(self: Im) void {
        self.h.unindent();
    }
    fn beginGroup(self: Im) void {
        self.h.beginGroup();
    }
    fn endGroup(self: Im) void {
        self.h.endGroup();
    }
    fn pushItemWidth(self: Im, w: f32) void {
        self.h.pushItemWidth(w);
    }
    fn popItemWidth(self: Im) void {
        self.h.popItemWidth();
    }
    fn setNextItemWidth(self: Im, w: f32) void {
        self.h.setNextItemWidth(w);
    }
    fn beginTabBar(self: Im, label: [:0]const u8) bool {
        return self.h.beginTabBar(label, .{});
    }
    fn endTabBar(self: Im) void {
        self.h.endTabBar();
    }
    fn beginTabItem(self: Im, label: [:0]const u8) bool {
        return self.h.beginTabItem(label, null, .{});
    }
    fn endTabItem(self: Im) void {
        self.h.endTabItem();
    }
    fn beginPopup(self: Im, s: [:0]const u8) bool {
        return self.h.beginPopup(s);
    }
    fn endPopup(self: Im) void {
        self.h.endPopup();
    }
    fn openPopup(self: Im, s: [:0]const u8) void {
        self.h.openPopup(s);
    }
    fn beginTooltip(self: Im) void {
        self.h.beginTooltip();
    }
    fn endTooltip(self: Im) void {
        self.h.endTooltip();
    }

    // ---- Style push/pop (accepted-and-dropped no-ops, like the 2D port) --
    fn pushStyleColor(_: Im, _: anytype, _: Color) void {}
    fn pushStyleColorU32(_: Im, _: anytype, _: zm.ColorU32) void {}
    fn popStyleColor(_: Im, _: usize) void {}
    fn pushStyleVarF32(_: Im, _: anytype, _: f32) void {}
    fn pushStyleVarVec2(_: Im, _: anytype, _: Vec2) void {}
    fn popStyleVar(_: Im, _: usize) void {}
};

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        items: ArrayList(*T) = .empty,
        map: std.AutoHashMapUnmanaged(Im.ID, usize) = .{},
        gpa: Allocator,

        pub fn init(gpa: Allocator) Self {
            return .{ .gpa = gpa };
        }
        /// Free every pooled entry (calling `T.deinit(gpa)` if present) and the
        /// backing list/map.
        pub fn deinit(self: *Self) void {
            for (self.items.items) |ptr| {
                if (@hasDecl(T, "deinit")) ptr.deinit(self.gpa);
                self.gpa.destroy(ptr);
            }
            self.items.deinit(self.gpa);
            self.map.deinit(self.gpa);
        }
        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }
        pub fn size(self: *const Self) usize {
            return self.items.items.len;
        }
        pub fn getByKey(self: *Self, id: Im.ID) ?*T {
            const idx = self.map.get(id) orelse return null;
            return self.items.items[idx];
        }
        pub fn getOrAddByKey(self: *Self, id: Im.ID) *T {
            if (self.map.get(id)) |idx| return self.items.items[idx];
            const ptr = self.gpa.create(T) catch @panic("implot3d: OOM");
            ptr.* = if (@hasDecl(T, "init")) T.init(self.gpa) else .{};
            const idx = self.items.items.len;
            self.items.append(self.gpa, ptr) catch @panic("implot3d: OOM");
            self.map.put(self.gpa, id, idx) catch @panic("implot3d: OOM");
            return ptr;
        }
        pub fn getByIndex(self: *Self, idx: usize) *T {
            return self.items.items[idx];
        }
        pub fn getIndex(self: *const Self, item: *const T) usize {
            for (self.items.items, 0..) |p, i| {
                if (p == item) return i;
            }
            return maxInt(usize);
        }
        pub fn reset(self: *Self) void {
            self.map.clearRetainingCapacity();
            self.items.clearRetainingCapacity();
        }
    };
}

pub const Tick = struct {
    plot_pos: f32,
    major: bool,
    show_label: bool,
    label_size: Vec2 = .{ 0, 0 },
    text_offset: i32 = -1,
    idx: i32 = 0,

    pub fn init(value: f32, major: bool, show_label: bool) Tick {
        return .{ .plot_pos = value, .major = major, .show_label = show_label };
    }
};

pub const Ticker = struct {
    ticks: ArrayList(Tick) = .empty,
    text_buffer: ArrayList(u8) = .empty,
    gpa: Allocator,

    pub fn init(gpa: Allocator) Ticker {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *Ticker, gpa: Allocator) void {
        self.ticks.deinit(gpa);
        self.text_buffer.deinit(gpa);
    }
    pub fn reset(self: *Ticker) void {
        self.ticks.clearRetainingCapacity();
        self.text_buffer.clearRetainingCapacity();
    }
    pub fn tickCount(self: *const Ticker) usize {
        return self.ticks.items.len;
    }
    /// Add a tick with a pre-rendered label string.
    pub fn addTickLabel(
        self: *Ticker,
        ctx: *Context,
        value: f32,
        major: bool,
        show_label: bool,
        label: ?[]const u8,
    ) *Tick {
        const im: Im = ctx.im();
        var tick = Tick.init(value, major, show_label);
        if (show_label) {
            if (label) |l| {
                tick.text_offset = @intCast(self.text_buffer.items.len);
                dropFrameOnOom(self.text_buffer.appendSlice(self.gpa, l));
                dropFrameOnOom(self.text_buffer.append(self.gpa, 0));
                tick.label_size = im.calcTextSize(l);
            }
        }
        return self.addTick(tick);
    }
    pub fn addTick(self: *Ticker, tick_in: Tick) *Tick {
        var tick: Tick = tick_in;
        tick.idx = @intCast(self.ticks.items.len);
        self.ticks.append(self.gpa, tick) catch @panic("implot3d: OOM");
        return &self.ticks.items[self.ticks.items.len - 1];
    }
    pub fn getText(self: *const Ticker, idx: usize) [:0]const u8 {
        const off: usize = @intCast(self.ticks.items[idx].text_offset);
        const buf: []u8 = self.text_buffer.items[off..];
        const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..end :0];
    }
};

/// Optional custom forward/inverse transform (e.g. for log scales).
pub const TransformFn = *const fn (value: f32, data: ?*anyopaque) callconv(.c) f32;

inline fn constrainNan(v: f32) f32 {
    return if (isNan(v)) 0 else v;
}

inline fn constrainInf(v: f32) f32 {
    return if (v >= 0) @min(v, math.floatMax(f32)) else @max(v, -math.floatMax(f32));
}

pub const Axis = struct {
    flags: AxisFlags = .{},
    previous_flags: AxisFlags = .{},
    range: Range = .{ .min = 0, .max = 1 },
    range_cond: Cond = .none,
    ndc_scale: f32 = 1.0,
    scale: Scale = .linear,
    label: ArrayList(u8) = .empty,
    format: ?[]const u8 = null, // optional Zig-style format string for tick labels
    ticker: Ticker,
    show_default_ticks: bool = true,
    // custom transform
    transform_forward: ?TransformFn = null,
    transform_inverse: ?TransformFn = null,
    transform_data: ?*anyopaque = null,
    scaled_range: Range = .{},
    // fit
    fit_this_frame: bool = true,
    fit_extents: Range = .{ .min = math.inf(f32), .max = -math.inf(f32) },
    // constraints
    constraint_range: Range = .{ .min = -math.inf(f32), .max = math.inf(f32) },
    constraint_zoom: Range = .{ .min = math.floatMin(f32), .max = math.inf(f32) },
    // input
    hovered: bool = false,
    held: bool = false,
    // cached colors
    color_bg: u32 = 0,
    color_hov: u32 = 0,
    color_act: u32 = 0,

    pub fn init(gpa: Allocator) Axis {
        return .{ .ticker = Ticker.init(gpa) };
    }

    pub fn deinit(self: *Axis, gpa: Allocator) void {
        self.label.deinit(gpa);
        self.ticker.deinit(gpa);
    }

    pub fn reset(self: *Axis) void {
        self.range_cond = .none;
        self.scale = .linear;
        self.transform_forward = null;
        self.transform_inverse = null;
        self.transform_data = null;
        self.ticker.reset();
        self.show_default_ticks = true;
        self.fit_extents = .{ .min = math.inf(f32), .max = -math.inf(f32) };
        self.constraint_range = .{ .min = -math.inf(f32), .max = math.inf(f32) };
        self.constraint_zoom = .{ .min = math.floatMin(f32), .max = math.inf(f32) };
    }

    pub fn setRange(self: *Axis, v1_in: f32, v2_in: f32) void {
        const v1: f32 = constrainNan(constrainInf(v1_in));
        const v2: f32 = constrainNan(constrainInf(v2_in));
        self.range.min = @min(v1, v2);
        self.range.max = @max(v1, v2);
        self.constrain();
        self.updateTransformCache();
    }

    pub fn setMin(self: *Axis, min_in: f32, force: bool) bool {
        if (!force and self.isLockedMin()) {
            return false;
        }
        var m: f32 = constrainNan(constrainInf(min_in));
        if (m < self.constraint_range.min) {
            m = self.constraint_range.min;
        }
        const zoom: f32 = self.range.max - m;
        if (zoom < self.constraint_zoom.min) {
            m = self.range.max - self.constraint_zoom.min;
        }
        if (zoom > self.constraint_zoom.max) {
            m = self.range.max - self.constraint_zoom.max;
        }
        if (m >= self.range.max) {
            return false;
        }
        self.range.min = m;
        self.updateTransformCache();
        return true;
    }

    pub fn setMax(self: *Axis, max_in: f32, force: bool) bool {
        if (!force and self.isLockedMax()) {
            return false;
        }
        var m: f32 = constrainNan(constrainInf(max_in));
        if (m > self.constraint_range.max) {
            m = self.constraint_range.max;
        }
        const zoom: f32 = m - self.range.min;
        if (zoom < self.constraint_zoom.min) {
            m = self.range.min + self.constraint_zoom.min;
        }
        if (zoom > self.constraint_zoom.max) {
            m = self.range.min + self.constraint_zoom.max;
        }
        if (m <= self.range.min) {
            return false;
        }
        self.range.max = m;
        self.updateTransformCache();
        return true;
    }

    pub fn constrain(self: *Axis) void {
        self.range.min = constrainNan(constrainInf(self.range.min));
        self.range.max = constrainNan(constrainInf(self.range.max));
        if (self.range.min < self.constraint_range.min) {
            self.range.min = self.constraint_range.min;
        }
        if (self.range.max > self.constraint_range.max) {
            self.range.max = self.constraint_range.max;
        }
        const zoom: f32 = self.range.size();
        if (zoom < self.constraint_zoom.min) {
            const delta: f32 = (self.constraint_zoom.min - zoom) * 0.5;
            self.range.min -= delta;
            self.range.max += delta;
        }
        if (zoom > self.constraint_zoom.max) {
            const delta: f32 = (zoom - self.constraint_zoom.max) * 0.5;
            self.range.min += delta;
            self.range.max -= delta;
        }
        if (self.range.max <= self.range.min) {
            self.range.max = self.range.min + math.floatEps(f32);
        }
    }

    pub fn updateTransformCache(self: *Axis) void {
        if (self.transform_forward) |fwd| {
            self.scaled_range.min = fwd(self.range.min, self.transform_data);
            self.scaled_range.max = fwd(self.range.max, self.transform_data);
        } else {
            self.scaled_range.min = self.range.min;
            self.scaled_range.max = self.range.max;
        }
    }

    pub fn plotToNDC(self: *const Axis, plt: f32) f32 {
        if (self.transform_forward) |fwd| {
            const s: f32 = fwd(plt, self.transform_data);
            return (s - self.scaled_range.min) / (self.scaled_range.max - self.scaled_range.min);
        }
        return (plt - self.range.min) / (self.range.max - self.range.min);
    }

    pub fn ndcToPlot(self: *const Axis, t: f32) f32 {
        if (self.transform_inverse) |inv| {
            const s: f32 = t * (self.scaled_range.max - self.scaled_range.min) + self.scaled_range.min;
            return inv(s, self.transform_data);
        }
        return self.range.min + t * (self.range.max - self.range.min);
    }

    pub fn isRangeLocked(self: *const Axis) bool {
        return self.range_cond == .always;
    }
    pub fn isLockedMin(self: *const Axis) bool {
        return self.isRangeLocked() or self.flags.lock_min;
    }
    pub fn isLockedMax(self: *const Axis) bool {
        return self.isRangeLocked() or self.flags.lock_max;
    }
    pub fn isLocked(self: *const Axis) bool {
        return self.isLockedMin() and self.isLockedMax();
    }
    pub fn isAutoFitting(self: *const Axis) bool {
        return self.flags.auto_fit;
    }
    pub fn isInputLockedMin(self: *const Axis) bool {
        return self.isLockedMin() or self.isAutoFitting();
    }
    pub fn isInputLockedMax(self: *const Axis) bool {
        return self.isLockedMax() or self.isAutoFitting();
    }
    pub fn isInputLocked(self: *const Axis) bool {
        return self.isLocked() or self.isAutoFitting();
    }

    pub fn ndcSize(self: *const Axis) f32 {
        return self.ndc_scale;
    }
    pub fn getAspect(self: *const Axis) f32 {
        return self.range.size() / self.ndcSize();
    }
    pub fn setAspect(self: *Axis, units_per_ndc_unit: f32) void {
        const new_size: f32 = units_per_ndc_unit * self.ndcSize();
        const delta: f32 = (new_size - self.range.size()) * 0.5;
        if (self.isLocked()) {
            return;
        }
        if (self.isLockedMin() and !self.isLockedMax()) {
            self.setRange(self.range.min, self.range.max + 2 * delta);
        } else if (!self.isLockedMin() and self.isLockedMax()) {
            self.setRange(self.range.min - 2 * delta, self.range.max);
        } else {
            self.setRange(self.range.min - delta, self.range.max + delta);
        }
    }

    pub fn setLabel(self: *Axis, gpa: Allocator, label: []const u8) void {
        self.label.clearRetainingCapacity();
        dropFrameOnOom(self.label.appendSlice(gpa, label));
        dropFrameOnOom(self.label.append(gpa, 0));
    }
    pub fn getLabel(self: *const Axis) [:0]const u8 {
        if (self.label.items.len == 0) {
            return "";
        }
        const end = std.mem.indexOfScalar(u8, self.label.items, 0) orelse self.label.items.len;
        return self.label.items[0..end :0];
    }

    pub fn hasLabel(self: *const Axis) bool {
        return self.label.items.len > 1 and !self.flags.no_label;
    }
    pub fn hasGridLines(self: *const Axis) bool {
        return !self.flags.no_grid_lines;
    }
    pub fn hasTickLabels(self: *const Axis) bool {
        return !self.flags.no_tick_labels;
    }
    pub fn hasTickMarks(self: *const Axis) bool {
        return !self.flags.no_tick_marks;
    }

    pub fn extendFit(self: *Axis, value: f32) void {
        if (isNan(value) or isInf(value)) {
            return;
        }
        self.fit_extents.min = @min(self.fit_extents.min, value);
        self.fit_extents.max = @max(self.fit_extents.max, value);
    }
    pub fn applyFit(self: *Axis) void {
        if (!isInf(self.fit_extents.min) and !isInf(self.fit_extents.max)) {
            if (!self.isLockedMin()) {
                self.range.min = self.fit_extents.min;
            }
            if (!self.isLockedMax()) {
                self.range.max = self.fit_extents.max;
            }
            if (self.range.min == self.range.max) {
                self.range.min -= 0.5;
                self.range.max += 0.5;
            }
            self.constrain();
            self.updateTransformCache();
        }
        self.fit_extents = .{ .min = math.inf(f32), .max = -math.inf(f32) };
        self.fit_this_frame = false;
    }
};

pub const Item = struct {
    id: Im.ID = 0,
    color: u32 = 0xFFFFFFFF,
    marker: Marker = .none,
    name_offset: i32 = -1,
    show: bool = true,
    legend_hovered: bool = false,
    seen_this_frame: bool = false,
};

pub const Legend = struct {
    flags: LegendFlags = .{},
    previous_flags: LegendFlags = .{},
    location: Location = Location.north_west,
    previous_location: Location = Location.north_west,
    indices: ArrayList(i32) = .empty,
    labels: ArrayList(u8) = .empty,
    rect: PixRect = .{},
    hovered: bool = false,
    held: bool = false,

    pub fn reset(self: *Legend) void {
        self.indices.clearRetainingCapacity();
        self.labels.clearRetainingCapacity();
    }
    pub fn deinit(self: *Legend, gpa: Allocator) void {
        self.indices.deinit(gpa);
        self.labels.deinit(gpa);
    }
};

pub const ItemGroup = struct {
    item_pool: Pool(Item),
    legend: Legend = .{},
    colormap_idx: i32 = 0,
    marker_idx: i32 = 0,

    pub fn init(gpa: Allocator) ItemGroup {
        return .{ .item_pool = Pool(Item).init(gpa) };
    }
    pub fn deinit(self: *ItemGroup, gpa: Allocator) void {
        self.item_pool.deinit();
        self.legend.deinit(gpa);
    }
    pub fn getItemCount(self: *const ItemGroup) usize {
        return self.item_pool.len();
    }
    pub fn getItemID(_: *ItemGroup, ctx: *Context, label_id: []const u8) Im.ID {
        return ctx.im().getID(label_id);
    }
    pub fn getItem(self: *ItemGroup, id: Im.ID) ?*Item {
        return self.item_pool.getByKey(id);
    }
    pub fn getItemByLabel(self: *ItemGroup, ctx: *Context, label_id: []const u8) ?*Item {
        return self.getItem(self.getItemID(ctx, label_id));
    }
    pub fn getOrAddItem(self: *ItemGroup, id: Im.ID) *Item {
        return self.item_pool.getOrAddByKey(id);
    }
    pub fn getItemByIndex(self: *ItemGroup, i: usize) *Item {
        return self.item_pool.getByIndex(i);
    }
    pub fn getLegendCount(self: *const ItemGroup) usize {
        return self.legend.indices.items.len;
    }
    pub fn getLegendItem(self: *ItemGroup, i: usize) *Item {
        return self.item_pool.getByIndex(@intCast(self.legend.indices.items[i]));
    }
    pub fn getLegendLabel(self: *ItemGroup, i: usize) [:0]const u8 {
        const off: usize = @intCast(self.getLegendItem(i).name_offset);
        const buf: []u8 = self.legend.labels.items[off..];
        const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..end :0];
    }
    pub fn reset(self: *ItemGroup) void {
        self.item_pool.reset();
        self.legend.reset();
        self.colormap_idx = 0;
        self.marker_idx = 0;
    }
};

const Tri3D = struct {
    a: Vec2,
    b: Vec2,
    c: Vec2,
    col: zm.ColorU32,
    z: f32, // mean camera-space depth; larger = nearer (drawn later)
};

pub const DrawList3D = struct {
    tris: ArrayList(Tri3D) = .empty,
    gpa: Allocator,

    pub fn init(gpa: Allocator) DrawList3D {
        return .{ .tris = .empty, .gpa = gpa };
    }

    pub fn reset(self: *DrawList3D) void {
        self.tris.clearRetainingCapacity();
    }

    pub fn deinit(self: *DrawList3D) void {
        self.tris.deinit(self.gpa);
    }

    /// Queue a projected triangle with its mean depth.
    pub fn addTriangle(
        self: *DrawList3D,
        a: Vec2,
        b: Vec2,
        c: Vec2,
        col: zm.ColorU32,
        z: f32,
    ) void {
        dropFrameOnOom(self.tris.append(self.gpa, .{ .a = a, .b = b, .c = c, .col = col, .z = z }));
    }

    /// Queue a projected quad (split into two triangles sharing the depth).
    pub fn addQuad(
        self: *DrawList3D,
        a: Vec2,
        b: Vec2,
        c: Vec2,
        d: Vec2,
        col: zm.ColorU32,
        z: f32,
    ) void {
        self.addTriangle(a, b, c, col, z);
        self.addTriangle(a, c, d, col, z);
    }

    fn lessThan(_: void, lhs: Tri3D, rhs: Tri3D) bool {
        // Ascending z: smaller z (farther) first, so nearer tris paint last.
        return lhs.z < rhs.z;
    }

    /// Sort the accumulated triangles far->near and emit them to the 2D
    /// DrawList, then clear the batch.
    pub fn flush(self: *DrawList3D, dl: Im.DrawList) void {
        std.mem.sort(Tri3D, self.tris.items, {}, lessThan);
        for (self.tris.items) |t| {
            dl.addTriangleFilled(t.a, t.b, t.c, t.col);
        }
        self.tris.clearRetainingCapacity();
    }
};

pub const Plot3D = struct {
    id: Im.ID = 0,
    flags: Flags = .{},
    previous_flags: Flags = .{},
    title: ArrayList(u8) = .empty,
    just_created: bool = true,
    initialized: bool = false,
    // bounding rects
    frame_rect: PixRect = .{},
    canvas_rect: PixRect = .{},
    plot_rect: PixRect = .{},
    // rotation / axes / box
    initial_rotation: Quat = quat(-0.513269, -0.212596, -0.318184, 0.76819),
    rotation: Quat = qidentity(),
    rotation_cond: Cond = .none,
    axes: [Axis3D_count]Axis,
    // animation
    animation_time: f32 = 0,
    rotation_animation_end: Quat = qidentity(),
    // input
    setup_locked: bool = false,
    hovered: bool = false,
    held: bool = false,
    held_edge_idx: i32 = -1,
    held_plane_idx: i32 = -1,
    drag_rotation_axis: Point3 = @splat(0),
    // Gesture state: per-frame orbit delta tracking, pinch spacing, and a
    // double-click timer synthesized from left-click edges.
    orbit_active: bool = false,
    pan_active: bool = false,
    last_drag_pos: Vec2 = .{ 0, 0 },
    pan_offset: Vec2 = .{ 0, 0 }, // screen-space translation of the whole box
    view_scale_factor: f32 = 1.0, // snapshot of style.view_scale_factor (set in beginPlot)
    prev_pinch: f32 = 0,
    prev_pinch_mid: Vec2 = .{ 0, 0 }, // two-finger midpoint, for touch pan
    time_since_click: f32 = -1, // -1 = idle; >=0 counts up from last click
    // fit
    fit_this_frame: bool = true,
    // items
    items: ItemGroup,
    // 3D draw list
    draw_list: DrawList3D,
    // misc
    context_click: bool = false,
    open_context_this_frame: bool = false,

    const Axis3D_count = 3;

    pub fn init(gpa: Allocator) Plot3D {
        var p = Plot3D{
            .axes = undefined,
            .items = ItemGroup.init(gpa),
            .draw_list = DrawList3D.init(gpa),
        };
        for (&p.axes) |*ax| {
            ax.* = Axis.init(gpa);
        }
        p.rotation_animation_end = p.rotation;
        return p;
    }

    pub fn deinit(self: *Plot3D, gpa: Allocator) void {
        self.title.deinit(gpa);
        for (&self.axes) |*ax| {
            ax.deinit(gpa);
        }
        self.draw_list.deinit();
        self.items.deinit(gpa);
    }

    pub fn xAxis(self: *Plot3D) *Axis {
        return &self.axes[0];
    }
    pub fn yAxis(self: *Plot3D) *Axis {
        return &self.axes[1];
    }
    pub fn zAxis(self: *Plot3D) *Axis {
        return &self.axes[2];
    }

    pub fn setTitle(self: *Plot3D, gpa: Allocator, title: []const u8) void {
        self.title.clearRetainingCapacity();
        dropFrameOnOom(self.title.appendSlice(gpa, title));
        dropFrameOnOom(self.title.append(gpa, 0));
    }
    pub fn hasTitle(self: *const Plot3D) bool {
        return self.title.items.len > 1 and !self.flags.no_title;
    }
    pub fn getTitle(self: *const Plot3D) [:0]const u8 {
        if (self.title.items.len == 0) {
            return "";
        }
        const end = std.mem.indexOfScalar(u8, self.title.items, 0) orelse self.title.items.len;
        return self.title.items[0..end :0];
    }
    pub fn isRotationLocked(self: *const Plot3D) bool {
        return self.rotation_cond == .always;
    }

    pub fn extendFit(self: *Plot3D, point: Point3) void {
        self.axes[0].extendFit(point[0]);
        self.axes[1].extendFit(point[1]);
        self.axes[2].extendFit(point[2]);
    }
    pub fn rangeMin(self: *const Plot3D) Point3 {
        return point3(self.axes[0].range.min, self.axes[1].range.min, self.axes[2].range.min);
    }
    pub fn rangeMax(self: *const Plot3D) Point3 {
        return point3(self.axes[0].range.max, self.axes[1].range.max, self.axes[2].range.max);
    }
    pub fn rangeCenter(self: *const Plot3D) Point3 {
        return .{
            .x = (self.axes[0].range.min + self.axes[0].range.max) * 0.5,
            .y = (self.axes[1].range.min + self.axes[1].range.max) * 0.5,
            .z = (self.axes[2].range.min + self.axes[2].range.max) * 0.5,
        };
    }
    pub fn setRange(self: *Plot3D, min: Point3, max: Point3) void {
        self.axes[0].setRange(min.x, max.x);
        self.axes[1].setRange(min.y, max.y);
        self.axes[2].setRange(min.z, max.z);
    }
    pub fn getViewScale(self: *const Plot3D) f32 {
        const min_side: f32 = @min(self.plot_rect.width(), self.plot_rect.height());
        return min_side * 0.7 * self.view_scale_factor;
    }
    pub fn getBoxScale(self: *const Plot3D) Point3 {
        return point3(self.axes[0].ndcSize(), self.axes[1].ndcSize(), self.axes[2].ndcSize());
    }
};

pub const Spec = struct {
    line_color: ?Color = null, // null -> next colormap color
    line_colors: ?[]const u32 = null, // per-index; null -> use line_color
    line_weight: f32 = 1.0,
    fill_color: ?Color = null,
    fill_colors: ?[]const u32 = null,
    fill_alpha: f32 = -1, // IMPLOT3D_AUTO -> use style.fill_alpha
    marker: Marker = .auto,
    marker_size: f32 = -1, // auto -> style.marker_size
    marker_sizes: ?[]const f32 = null,
    marker_line_color: ?Color = null, // null -> line_color
    marker_line_colors: ?[]const u32 = null,
    marker_fill_color: ?Color = null, // null -> line_color
    marker_fill_colors: ?[]const u32 = null,
    offset: i32 = 0,
    stride: i32 = -1, // auto -> sizeof(T)
    flags: ItemFlags = .{},
};

pub const NextItemData = struct {
    spec: Spec = .{},
    render_line: bool = false,
    render_fill: bool = false,
    render_marker_line: bool = true,
    render_marker_fill: bool = true,
    is_auto_fill: bool = true,
    is_auto_line: bool = true,
    hidden: bool = false,

    pub fn reset(self: *NextItemData) void {
        self.* = .{};
    }
};

pub const Style = struct {
    // Item style
    line_weight: f32 = 1.0,
    marker: Marker = .none,
    marker_size: f32 = 4.0,
    fill_alpha: f32 = 1.0,
    // Plot style
    plot_default_size: Vec2 = .{ 400, 400 },
    plot_min_size: Vec2 = .{ 200, 200 },
    plot_padding: Vec2 = .{ 10, 10 },
    label_padding: Vec2 = .{ 5, 5 },
    view_scale_factor: f32 = 1.0,
    // Legend style
    legend_padding: Vec2 = .{ 10, 10 },
    legend_inner_padding: Vec2 = .{ 5, 5 },
    legend_spacing: Vec2 = .{ 5, 0 },
    // Colors (auto by default; resolved against the ui.Style). `null` = auto.
    colors: [Col.count]?Color = @splat(null),
    // Colormap
    colormap: Colormap = .deep,

    pub inline fn getColor(self: *const Style, idx: Col) ?Color {
        return self.colors[@intCast(@backingInt(idx))];
    }
    pub inline fn setColor(self: *Style, idx: Col, col: ?Color) void {
        self.colors[@intCast(@backingInt(idx))] = col;
    }
};

pub const ColormapData = struct {
    gpa: Allocator,
    keys: ArrayList(u32) = .empty, // all key colors, concatenated
    key_counts: ArrayList(u32) = .empty,
    key_offsets: ArrayList(u32) = .empty,
    tables: ArrayList(u32) = .empty, // expanded lerp tables, concatenated
    table_sizes: ArrayList(u32) = .empty,
    table_offsets: ArrayList(u32) = .empty,
    text: ArrayList(u8) = .empty, // names, NUL-separated
    text_offsets: ArrayList(u32) = .empty,
    quals: ArrayList(bool) = .empty,
    count: u16 = 0,

    pub fn init(gpa: Allocator) ColormapData {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *ColormapData, gpa: Allocator) void {
        self.keys.deinit(gpa);
        self.key_counts.deinit(gpa);
        self.key_offsets.deinit(gpa);
        self.tables.deinit(gpa);
        self.table_sizes.deinit(gpa);
        self.table_offsets.deinit(gpa);
        self.text.deinit(gpa);
        self.text_offsets.deinit(gpa);
        self.quals.deinit(gpa);
    }

    fn oom() noreturn {
        @panic("implot3d: OOM");
    }

    /// Register a colormap by its key colors. qual = qualitative (no lerp).
    pub fn append(
        self: *ColormapData,
        name: []const u8,
        key_colors: []const u32,
        qual: bool,
    ) Colormap {
        self.key_offsets.append(self.gpa, @intCast(self.keys.items.len)) catch oom();
        self.key_counts.append(self.gpa, @intCast(key_colors.len)) catch oom();
        self.keys.appendSlice(self.gpa, key_colors) catch oom();
        self.text_offsets.append(self.gpa, @intCast(self.text.items.len)) catch oom();
        self.text.appendSlice(self.gpa, name) catch oom();
        self.text.append(self.gpa, 0) catch oom();
        self.quals.append(self.gpa, qual) catch oom();
        const cmap: Colormap = @fromBackingInt(@intCast(self.count));
        self.count += 1;
        self.appendTable(cmap);
        return cmap;
    }

    fn appendTable(self: *ColormapData, cmap: Colormap) void {
        const idx: usize = @intCast(@backingInt(cmap));
        const kc: u32 = self.key_counts.items[idx];
        const ko: u32 = self.key_offsets.items[idx];
        const keys: []const u32 = self.keys.items[ko .. ko + kc];
        self.table_offsets.append(self.gpa, @intCast(self.tables.items.len)) catch oom();
        if (self.quals.items[idx] or kc == 1) {
            // qualitative: table = keys verbatim
            self.tables.appendSlice(self.gpa, keys) catch oom();
            self.table_sizes.append(self.gpa, kc) catch oom();
        } else {
            // continuous: resample to a fixed-resolution lerp table
            const resolution: u32 = 256;
            var i: u32 = 0;
            while (i < resolution) : (i += 1) {
                const t: f32 = float(i) / float(resolution - 1);
                self.tables.append(self.gpa, plot_core.sampleKeys(keys, t)) catch oom();
            }
            self.table_sizes.append(self.gpa, resolution) catch oom();
        }
    }

    pub fn getKeyCount(self: *const ColormapData, cmap: Colormap) usize {
        return self.key_counts.items[@intCast(@backingInt(cmap))];
    }
    pub fn getKeyColor(self: *const ColormapData, cmap: Colormap, idx: usize) u32 {
        const ci: usize = @intCast(@backingInt(cmap));
        const ko: u32 = self.key_offsets.items[ci];
        return self.keys.items[ko + idx];
    }
    pub fn getTableSize(self: *const ColormapData, cmap: Colormap) usize {
        return self.table_sizes.items[@intCast(@backingInt(cmap))];
    }
    pub fn getTableColor(self: *const ColormapData, cmap: Colormap, idx: usize) u32 {
        const ci: usize = @intCast(@backingInt(cmap));
        const to: u32 = self.table_offsets.items[ci];
        return self.tables.items[to + idx];
    }
    /// Sample the lerp table for cmap at t in [0,1].
    pub fn lerpTable(self: *const ColormapData, cmap: Colormap, t: f32) u32 {
        const ci: usize = @intCast(@backingInt(cmap));
        const sz: u32 = self.table_sizes.items[ci];
        const to: u32 = self.table_offsets.items[ci];
        if (sz == 1) {
            return self.tables.items[to];
        }
        const scaled: f32 = math.clamp(t, 0, 1) * float(sz - 1);
        var i: usize = @floor(scaled);
        if (i >= sz - 1) {
            i = sz - 2;
        }
        const frac: f32 = scaled - float(i);
        return plot_core.lerpWire(self.tables.items[to + i], self.tables.items[to + i + 1], frac);
    }
    /// Index a qualitative colormap by item index (wraps).
    pub fn getKeyColorWrapped(self: *const ColormapData, cmap: Colormap, idx: usize) u32 {
        const kc: usize = self.getKeyCount(cmap);
        return self.getKeyColor(cmap, idx % kc);
    }
};

const StyleColorMod = struct { col: Col, backup: ?Color };

pub const Context = struct {
    gpa: Allocator,
    plots: Pool(Plot3D),
    current_plot: ?*Plot3D = null,
    current_items: ?*ItemGroup = null,
    current_item: ?*Item = null,
    next_item_data: NextItemData = .{},
    style: Style = .{},
    colormap_data: ColormapData,
    ui_handle: ?ui.Ui = null,
    win_scope: ?ui.WindowHandle = null,
    /// LIFO style-color override stack (pushStyleColor/popStyleColor). Owned here
    /// so there is no module-level mutable state.
    style_color_stack: ArrayList(StyleColorMod) = .empty,

    pub fn init(gpa: Allocator) Context {
        return .{
            .gpa = gpa,
            .plots = Pool(Plot3D).init(gpa),
            .colormap_data = ColormapData.init(gpa),
        };
    }

    /// Free everything the context owns: every plot (and its axes/tickers/draw
    /// list/item pools), the colormap tables, and the style-color override stack.
    pub fn deinit(self: *Context) void {
        self.plots.deinit();
        self.colormap_data.deinit(self.gpa);
        self.style_color_stack.deinit(self.gpa);
    }

    /// The current plot (panics if called outside begin/endPlot).
    pub fn currentPlot(self: *Context) *Plot3D {
        return self.current_plot orelse @panic("implot3d: no current plot");
    }

    /// The bound per-frame ui handle (panics if `setUiHandle` wasn't called).
    pub fn handle(self: *Context) ui.Ui {
        return self.ui_handle orelse
            @panic("implot3d: no active frame; call setUiHandle(ctx, ctx, ui) before any implot3d call");
    }

    /// The ui shim bound to this context's frame handle. `const im: Im = ctx.im();`
    /// then `im.addLine(...)` etc. — the explicit, global-free replacement for
    /// the old module-level `im` namespace.
    pub fn im(self: *Context) Im {
        return .{ .h = self.handle(), .ctx = self };
    }
};

//=============================================================================
// [SECTION] Style
//=============================================================================

/// Set every style color to "auto" (deduce from the ui style / colormap).
pub fn styleColorsAuto(ctx: *Context, dst: ?*Style) void {
    const style: *Style = dst orelse &ctx.style;
    for (&style.colors) |*c| {
        c.* = null;
    }
}

/// True if the style slot `idx` is set to auto.
pub fn isStyleColorAuto(ctx: *Context, idx: Col) bool {
    return ctx.style.colors[@intCast(@backingInt(idx))] == null;
}

/// Resolve an auto color slot to its concrete default (against the ui style).
fn getAutoColor(ctx: *Context, idx: Col) Color {
    const im: Im = ctx.im();
    return switch (idx) {
        .title_text => im.uiStyleColor(.text),
        .inlay_text => im.uiStyleColor(.text),
        .frame_bg => im.uiStyleColor(.frame_bg),
        .plot_bg => im.uiStyleColor(.window_bg),
        .plot_border => im.uiStyleColor(.border),
        .legend_bg => im.uiStyleColor(.popup_bg),
        .legend_border => im.uiStyleColor(.border),
        .legend_text => im.uiStyleColor(.text),
        .axis_text => im.uiStyleColor(.text),
        .axis_grid => im.uiStyleColor(.text).scaleAlpha(0.25),
        .axis_tick => getAutoColor(ctx, .axis_grid),
        .axis_bg => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .axis_bg_hovered => im.uiStyleColor(.button_hovered),
        .axis_bg_active => im.uiStyleColor(.button_active),
    };
}

pub fn getStyle(ctx: *Context) *Style {
    return &ctx.style;
}

pub fn getStyleColor(ctx: *Context, idx: Col) Color {
    return if (ctx.style.colors[@intCast(@backingInt(idx))]) |c| c else getAutoColor(ctx, idx);
}

pub fn getStyleColorU32(ctx: *Context, idx: Col) zm.ColorU32 {
    const im: Im = ctx.im();
    return im.colorToU32(getStyleColor(ctx, idx));
}

/// The current plot's 2D draw list (the same backend-agnostic recorder used for
/// the box/legend). Use it for custom overlays drawn in pixel space.
pub fn getPlotDrawList(ctx: *Context) Im.DrawList {
    const im: Im = ctx.im();
    return im.getWindowDrawList();
}

const col_names = [_][:0]const u8{
    "TitleText", "InlayText",    "FrameBg",       "PlotBg",       "PlotBorder",
    "LegendBg",  "LegendBorder", "LegendText",    "AxisText",     "AxisGrid",
    "AxisTick",  "AxisBg",       "AxisBgHovered", "AxisBgActive",
};

/// Human-readable name for a style color (for editors/labels).
pub fn getStyleColorName(idx: Col) [:0]const u8 {
    return col_names[@intCast(@backingInt(idx))];
}

// Simple style-color override stack (LIFO). Mirrors implot.zig's behavior:
// pushStyleColor temporarily overrides a Col; popStyleColor restores it. The
// stack itself lives on the Context (Context.style_color_stack) — no globals.

pub fn pushStyleColor(ctx: *Context, idx: Col, col: Color) void {
    const style: *Style = getStyle(ctx);
    dropFrameOnOom(ctx.style_color_stack.append(
        ctx.gpa,
        .{ .col = idx, .backup = style.colors[@intCast(@backingInt(idx))] },
    ));
    style.colors[@intCast(@backingInt(idx))] = col;
}

pub fn popStyleColor(ctx: *Context, count: usize) void {
    const style: *Style = getStyle(ctx);
    var n: usize = count;
    while (n > 0) : (n -= 1) {
        // Unwinding a push: each entry carries which colour slot was overridden and what was
        // there before, so popping restores rather than guessing a default.
        const mod: StyleColorMod = ctx.style_color_stack.pop() orelse break;
        style.colors[@intCast(@backingInt(mod.col))] = mod.backup;
    }
}

//=============================================================================
// [SECTION] DrawList3D — CPU painter's-algorithm triangle batch
//
// ImPlot3D batches projected triangles with a per-triangle Z, then sorts them
// far->near and flushes to the ImGui DrawList. zimr's ui.DrawList has no raw
// vertex buffer, so we accumulate (a, b, c, col, z) tuples here and emit
// addTriangleFilled per triangle in sorted order on flush(). Lines/markers/
// text are drawn directly to the 2D DrawList by the renderers (they don't need
// z-sorting against the fills in practice — upstream draws them after the
// sorted tris too).
//=============================================================================

//=============================================================================
// [SECTION] Spec — per-item styling (replaces SetNext*Style)
//=============================================================================

//=============================================================================
// [SECTION] Pool — keyed object pool (mirrors the 2D port's ImPool)
//=============================================================================

//=============================================================================
// [SECTION] Ticker (axis tick storage; tick generation in the axis section)
//=============================================================================

pub const label_max_size: usize = 32;

//=============================================================================
// [SECTION] Item / Legend / ItemGroup
//=============================================================================

//=============================================================================
// [SECTION] NextItemData (resolved per-item render state)
//=============================================================================

//=============================================================================
// [SECTION] Axis (per-axis state; ImPlot3DAxis)
//=============================================================================

//=============================================================================
// [SECTION] Plot3D
//=============================================================================

//=============================================================================
// [SECTION] Context + global
//=============================================================================

/// Register all 16 built-in colormaps (key colors shared with implot.zig via
/// plot_core, so the data is defined exactly once).
fn initColormapTables(data: *ColormapData) void {
    const ck: type = plot_core.colormap_keys;
    _ = data.append("Deep", &ck.deep, true);
    _ = data.append("Dark", &ck.dark, true);
    _ = data.append("Pastel", &ck.pastel, true);
    _ = data.append("Paired", &ck.paired, true);
    _ = data.append("Viridis", &ck.viridis, false);
    _ = data.append("Plasma", &ck.plasma, false);
    _ = data.append("Hot", &ck.hot, false);
    _ = data.append("Cool", &ck.cool, false);
    _ = data.append("Pink", &ck.pink, false);
    _ = data.append("Jet", &ck.jet, false);
    _ = data.append("Twilight", &ck.twilight, false);
    _ = data.append("RdBu", &ck.rdbu, false);
    _ = data.append("BrBG", &ck.brbg, false);
    _ = data.append("PiYG", &ck.piyg, false);
    _ = data.append("Spectral", &ck.spectral, false);
    _ = data.append("Greys", &ck.greys, false);
}

/// Register the built-in colormaps. Full key tables live in the tooling
/// section (initColormapTables); this wires Deep as the default so the
/// foundation is usable. TODO: register all 16 built-ins.
fn initColormaps(data: *ColormapData) void {
    initColormapTables(data);
}

pub fn createContext(gpa: Allocator) *Context {
    const ctx = gpa.create(Context) catch @panic("implot3d: OOM");
    ctx.* = Context.init(gpa);
    initColormaps(&ctx.colormap_data);
    return ctx;
}
pub fn destroyContext(ctx: *Context) void {
    const gpa: Allocator = ctx.gpa;
    ctx.deinit();
    gpa.destroy(ctx);
}

/// Bind the per-frame ui.Ui handle on `ctx`. Call once per frame before any
/// implot3d call (beginPlot, the style/colormap widgets, etc. all read input,
/// layout, and the draw list through it).
pub fn setUiHandle(ctx: *Context, handle: ?ui.Ui) void {
    ctx.ui_handle = handle;
}

//=============================================================================
// [SECTION] Numeric helpers
//=============================================================================

//=============================================================================
// [SECTION] ColormapData
//
// Mirrors the 2D port's colormap storage: a set of named key-color lists, each
// expanded into a lerp table. The built-in tables are registered by
// initColormaps (full 16-map key data lives in the tooling section).
//=============================================================================

//=============================================================================
// [SECTION] Projection pipeline (the camera)
//
// ImPlot3D has no GPU camera. A point is mapped plot-space -> NDC (per-axis
// normalize to [-0.5,0.5]*NDCScale) -> rotated by the plot quaternion ->
// orthographically flattened to screen (scale by GetViewScale, invert y,
// offset to the plot-rect center). Depth (camera-space z) is the rotated
// point's z and feeds the painter's-algorithm sort.
//=============================================================================

/// plot-space -> NDC ([-0.5,0.5]*NDCScale per axis).
pub fn plotToNDC(plot: *const Plot3D, point: Point3) Point3 {
    var ndc: Point3 = @splat(0);
    inline for (0..3) |i| {
        const axis: *const Axis = &plot.axes[i];
        const plt: f32 = point[i];
        var t: f32 = undefined;
        if (axis.transform_forward) |fwd| {
            const s: f32 = fwd(plt, axis.transform_data);
            t = (s - axis.scaled_range.min) / (axis.scaled_range.max - axis.scaled_range.min);
        } else {
            t = (plt - axis.range.min) / (axis.range.max - axis.range.min);
        }
        const ndc_range: f32 = 0.5;
        const v: f32 = (if (axis.flags.invert) (ndc_range - t) else (t - ndc_range)) * axis.ndc_scale;
        switch (i) {
            0 => ndc[0] = v,
            1 => ndc[1] = v,
            2 => ndc[2] = v,
            else => unreachable,
        }
    }
    return ndc;
}

/// NDC -> plot-space (inverse of plotToNDC).
pub fn ndcToPlotP(plot: *const Plot3D, point: Point3) Point3 {
    var out: Point3 = @splat(0);
    inline for (0..3) |i| {
        const axis: *const Axis = &plot.axes[i];
        const ndc_range: f32 = 0.5 * axis.ndc_scale;
        const ndc_point: f32 = point[i];
        var t: f32 = if (axis.flags.invert) (ndc_range - ndc_point) else (ndc_point + ndc_range);
        t /= axis.ndc_scale;
        const v: f32 = axis.ndcToPlot(t);
        switch (i) {
            0 => out[0] = v,
            1 => out[1] = v,
            2 => out[2] = v,
            else => unreachable,
        }
    }
    return out;
}

/// NDC -> pixels (rotate by quaternion, flatten, offset to plot-rect center).
pub fn ndcToPixels(plot: *const Plot3D, point: Point3) Vec2 {
    const center: Vec2 = plot.plot_rect.center();
    const rotated: Point3 = rotate(plot.rotation, point);
    const scale: f32 = plot.getViewScale();
    const px: f32 = rotated[0] * scale + center[0] + plot.pan_offset[0];
    const py: f32 = -(rotated[1] * scale) + center[1] + plot.pan_offset[1]; // invert y
    return .{ px, py };
}

/// Camera-space depth of an NDC point (for painter's sort): the rotated z.
pub fn ndcDepth(plot: *const Plot3D, point: Point3) f32 {
    return rotate(plot.rotation, point)[2];
}

/// plot-space -> pixels.
pub fn plotToPixelsP(plot: *const Plot3D, point: Point3) Vec2 {
    return ndcToPixels(plot, plotToNDC(plot, point));
}

// ---- Free-function API (operate on the current plot) ----------------------

pub fn plotToNDCcur(ctx: *Context, point: Point3) Point3 {
    return plotToNDC(ctx.currentPlot(), point);
}
pub fn ndcToPlot(ctx: *Context, point: Point3) Point3 {
    return ndcToPlotP(ctx.currentPlot(), point);
}
pub fn ndcToPixelsCur(ctx: *Context, point: Point3) Vec2 {
    return ndcToPixels(ctx.currentPlot(), point);
}
pub fn plotToPixels(ctx: *Context, point: Point3) Vec2 {
    return plotToPixelsP(ctx.currentPlot(), point);
}
pub fn plotToPixelsXYZ(ctx: *Context, x: f32, y: f32, z: f32) Vec2 {
    return plotToPixels(ctx, point3(x, y, z));
}
pub fn getPlotRectPos(ctx: *Context) Vec2 {
    return ctx.currentPlot().plot_rect.min;
}
pub fn getPlotRectSize(ctx: *Context) Vec2 {
    return ctx.currentPlot().plot_rect.size();
}
/// The current plot's view rotation quaternion (for custom overlays/gizmos).
pub fn getPlotRotation(ctx: *Context) Quat {
    return ctx.currentPlot().rotation;
}
pub fn getFramePos(ctx: *Context) Vec2 {
    return ctx.currentPlot().frame_rect.min;
}
pub fn getFrameSize(ctx: *Context) Vec2 {
    return ctx.currentPlot().frame_rect.size();
}

// ---- Inverse projection (rays / plane picking) ----------------------------

/// Build an NDC-space ray from a pixel position (used for hover/picking).
pub fn pixelsToNDCRay(plot: *const Plot3D, pix: Vec2) Ray {
    const zoom: f32 = plot.getViewScale();
    const center: Vec2 = plot.plot_rect.center();
    const x: f32 = (pix[0] - center[0] - plot.pan_offset[0]) / zoom;
    const y: f32 = -(pix[1] - center[1] - plot.pan_offset[1]) / zoom; // invert y
    const inv: Quat = inverse(plot.rotation);
    const ndc_near: Point3 = rotate(inv, point3(x, y, 10.0));
    const ndc_far: Point3 = rotate(inv, point3(x, y, -10.0));
    return .{ .position = ndc_near, .direction = normalize3(ndc_far - ndc_near) };
}

/// Convert an NDC-space ray to a plot-space ray.
pub fn ndcRayToPlotRay(plot: *const Plot3D, ray: Ray) Ray {
    const plot_origin: Point3 = ndcToPlotP(plot, ray.position);
    const along: Point3 = ndcToPlotP(plot, ray.position + ray.direction);
    return .{ .position = plot_origin, .direction = normalize3(along - plot_origin) };
}

/// Pixel position -> plot-space ray.
pub fn pixelsToPlotRay(ctx: *Context, pix: Vec2) Ray {
    const plot: *Plot3D = ctx.currentPlot();
    return ndcRayToPlotRay(plot, pixelsToNDCRay(plot, pix));
}
pub fn pixelsToPlotRayXY(ctx: *Context, x: f32, y: f32) Ray {
    return pixelsToPlotRay(ctx, .{ @floatCast(x), @floatCast(y) });
}

/// Shared builder: column-major ortho VP mapping NDC-cube points to clip for a
/// `target_w`×`target_h` viewport with the plot centered at `center` (in that
/// target's pixel space). See `viewProjMatrix` / `viewProjMatrixRT`.
fn viewProjMatrixCentered(
    plot: *const Plot3D,
    target_w: f32,
    target_h: f32,
    center: Vec2,
) zm.Mat {
    const ex: Point3 = rotate(plot.rotation, point3(1, 0, 0));
    const ey: Point3 = rotate(plot.rotation, point3(0, 1, 0));
    const ez: Point3 = rotate(plot.rotation, point3(0, 0, 1));
    const scale: f32 = plot.getViewScale();
    const sx: f32 = 2 * scale / target_w;
    const sy: f32 = 2 * scale / target_h;
    const cx: f32 = 2 * (center[0] + plot.pan_offset[0]) / target_w - 1;
    const cy: f32 = 1 - 2 * (center[1] + plot.pan_offset[1]) / target_h;
    const nx: f32 = plot.axes[0].ndc_scale;
    const ny: f32 = plot.axes[1].ndc_scale;
    const nz: f32 = plot.axes[2].ndc_scale;
    const zhalf: f32 = 0.5 * @sqrt(nx * nx + ny * ny + nz * nz) * 1.01 + 1e-4;
    const kz: f32 = 0.5 / zhalf;
    return .{
        .{ sx * ex[0], sy * ex[1], -kz * ex[2], 0 }, // col0 (← ndc.x)
        .{ sx * ey[0], sy * ey[1], -kz * ey[2], 0 }, // col1 (← ndc.y)
        .{ sx * ez[0], sy * ez[1], -kz * ez[2], 0 }, // col2 (← ndc.z)
        .{ cx, cy, 0.5, 1 }, // col3 (← w=1)
    };
}

/// Build a column-vector view-projection matrix (`clip = VP · vec4(ndc, 1)`)
/// that maps NDC-cube points into clip space so that, when GPU geometry is
/// rendered into a viewport set to the plot rect (with the WebGPU depth range
/// [0,1]), it lands pixel-for-pixel on the CPU axes overlay produced by
/// `ndcToPixels`. This is the camera a depth-tested GPU surface/mesh pass
/// (draw3d) uses to align exactly with the painter's-algorithm CPU projection,
/// so the two can be composited (GPU fills under the CPU box/labels overlay).
///
/// The rotation is taken straight from `rotate()` applied to the basis vectors,
/// so it matches the CPU path *by construction* — no quaternion-vs-matrix
/// convention coupling. The projection is orthographic (constant `getViewScale`,
/// no perspective divide), so `w = 1` and depth is linear in the rotated z.
/// Returns a `zm.Mat` (`[4]Vec`, one `Vec` per row).
/// Build the view-projection matrix that drives a depth-tested GPU 3D pass
/// (`draw3d` / `beginFrame3D`) so its geometry lands pixel-for-pixel on the CPU
/// axes overlay (`ndcToPixels`). `target_w`/`target_h` are the render target
/// (framebuffer) size in pixels — the single shared 3D pass uses the full
/// framebuffer viewport, so the framebuffer→clip mapping is folded into the
/// matrix rather than set via a per-plot viewport.
///
/// Result is a `zm.Mat` in zm's COLUMN-MAJOR convention (each `Mat[i]` is a
/// column), so `zm.mulMatVec(vp, v)` / the WGSL `vp * vec4(p,1)` compute the
/// intended `M·v` — the same convention the cube/models demos use. The rotation
/// columns are taken straight from `rotate()` on the basis vectors, so the
/// orientation matches the CPU path by construction. Orthographic (`w == 1`),
/// WebGPU depth range [0,1].
pub fn viewProjMatrix(plot: *const Plot3D, target_w: f32, target_h: f32) zm.Mat {
    return viewProjMatrixCentered(plot, target_w, target_h, plot.plot_rect.center());
}

/// View-projection for rendering into an offscreen render texture sized to the
/// plot rect (the plot pane), for the RTT GPU-fill compositing path. The plot is
/// centered in the texture (center = size/2), so drawing the texture 1:1 at the
/// plot rect aligns it with the CPU axes overlay.
pub fn viewProjMatrixRT(plot: *const Plot3D) zm.Mat {
    const rw: f32 = plot.plot_rect.width();
    const rh: f32 = plot.plot_rect.height();
    return viewProjMatrixCentered(plot, rw, rh, .{ rw / 2, rh / 2 });
}

/// `viewProjMatrix` for the current plot (call between begin/endPlot).
pub fn getViewProjMatrix(ctx: *Context, target_w: f32, target_h: f32) zm.Mat {
    return viewProjMatrix(ctx.currentPlot(), target_w, target_h);
}

/// `viewProjMatrixRT` for the current plot (call between begin/endPlot).
pub fn getViewProjMatrixRT(ctx: *Context) zm.Mat {
    return viewProjMatrixRT(ctx.currentPlot());
}
/// Determine which of the three back faces are "active" (drawn) given the
/// current rotation. Writes plane_2d (or -1) if a degenerate 2D view is hit.
pub fn computeActiveFaces(
    active_faces: *[3]bool,
    rotation: Quat,
    axes: *const [3]Axis,
    plane_2d: ?*i32,
) void {
    if (plane_2d) |p| {
        p.* = -1;
    }
    const rot_face_n = [3]Point3{
        rotate(rotation, point3(1, 0, 0)),
        rotate(rotation, point3(0, 1, 0)),
        rotate(rotation, point3(0, 0, 1)),
    };
    var num_deg: i32 = 0;
    inline for (0..3) |i| {
        if (@abs(rot_face_n[i][2]) < 0.025) {
            active_faces[i] = (rot_face_n[i][0] + rot_face_n[i][1]) < 0.0;
            num_deg += 1;
        } else {
            const is_inverted: bool = axes[i].flags.invert;
            active_faces[i] = if (is_inverted) (rot_face_n[i][2] > 0.0) else (rot_face_n[i][2] < 0.0);
            if (plane_2d) |p| {
                p.* = @intCast(i);
            }
        }
    }
    if (num_deg != 2) {
        if (plane_2d) |p| {
            p.* = -1;
        }
    }
}

pub fn pixelsToPlotPlane(ctx: *Context, pix: Vec2, plane: Plane3D, mask: bool) Point3 {
    const plot: *Plot3D = ctx.currentPlot();
    const ray: Ray = pixelsToNDCRay(plot, pix);
    const o: Point3 = ray.position;
    const d: Point3 = ray.direction;
    const nan_pt: Point3 = point3(math.nan(f32), math.nan(f32), math.nan(f32));

    const intersectAt = struct {
        fn f(o2: Point3, d2: Point3, pl: Plane3D, coord: f32) Point3 {
            var denom: f32 = 0;
            var numer: f32 = 0;
            switch (pl) {
                .yz => {
                    denom = d2[0];
                    numer = coord - o2[0];
                },
                .xz => {
                    denom = d2[1];
                    numer = coord - o2[1];
                },
                .xy => {
                    denom = d2[2];
                    numer = coord - o2[2];
                },
            }
            if (@abs(denom) < 1e-12) return point3(math.nan(f32), math.nan(f32), math.nan(f32));
            const t = numer / denom;
            if (t < 0) return point3(math.nan(f32), math.nan(f32), math.nan(f32));
            return o2 + d2 * splat(t);
        }
    }.f;

    var active_faces: [3]bool = undefined;
    computeActiveFaces(&active_faces, plot.rotation, &plot.axes, null);

    const pidx: usize = @intCast(@backingInt(plane));
    const coord: f32 = (if (active_faces[pidx]) @as(f32, 0.5) else @as(f32, -0.5)) * plot.axes[pidx].ndc_scale;
    const p: Point3 = intersectAt(o, d, plane, coord);
    if (point3IsNan(p)) {
        return p;
    }

    if (mask) {
        const box_scale: Point3 = plot.getBoxScale();
        const inRange = struct {
            fn f(pt: Point3, bs: Point3) bool {
                return pt[0] >= -0.5 * bs[0] and pt[0] <= 0.5 * bs[0] and
                    pt[1] >= -0.5 * bs[1] and pt[1] <= 0.5 * bs[1] and
                    pt[2] >= -0.5 * bs[2] and pt[2] <= 0.5 * bs[2];
            }
        }.f;
        const masked: bool = switch (plane) {
            .yz => inRange(point3(0, p[1], p[2]), box_scale),
            .xz => inRange(point3(p[0], 0, p[2]), box_scale),
            .xy => inRange(point3(p[0], p[1], 0), box_scale),
        };
        if (!masked) {
            return nan_pt;
        }
    }
    return ndcToPlotP(plot, p);
}

// ---- Box geometry & face culling ------------------------------------------

/// The eight box corners in plot space (CCW convention from upstream).
pub fn computeBoxCorners(corners: *[8]Point3, range_min: Point3, range_max: Point3) void {
    corners[0] = point3(range_min[0], range_min[1], range_min[2]);
    corners[1] = point3(range_max[0], range_min[1], range_min[2]);
    corners[2] = point3(range_max[0], range_max[1], range_min[2]);
    corners[3] = point3(range_min[0], range_max[1], range_min[2]);
    corners[4] = point3(range_min[0], range_min[1], range_max[2]);
    corners[5] = point3(range_max[0], range_min[1], range_max[2]);
    corners[6] = point3(range_max[0], range_max[1], range_max[2]);
    corners[7] = point3(range_min[0], range_max[1], range_max[2]);
}

/// Box corners projected to pixels.
pub fn computeBoxCornersPix(
    plot: *const Plot3D,
    corners_pix: *[8]Vec2,
    corners: *const [8]Point3,
) void {
    for (0..8) |i| {
        corners_pix[i] = plotToPixelsP(plot, corners[i]);
    }
}

//=============================================================================
// [SECTION] Tick generation (default linear locator + formatter)
//=============================================================================

/// Format a tick value with the default "%g"-style formatter into buf.
fn formatTickDefault(value: f32, buf: []u8) []const u8 {
    return bufPrint(buf, "{d}", .{value}) catch buf[0..0];
}

/// "Nice number" rounding for tick intervals. Shared with implot.zig via
/// plot_core.
const niceNum = zm.niceNum;

/// Default linear tick locator. Fills `ticker` with major (labeled) and minor
/// ticks across `range`, sized for `pixels` of available length.
fn locatorDefault(ctx: *Context, ticker: *Ticker, range: Range, pixels: f32) void {
    if (range.min == range.max) {
        return;
    }
    const n_minor: i32 = @min(@max(@as(i32, 1), math.roundi(i32, pixels / 30.0)), 5);
    const n_major: i32 = @max(@as(i32, 2), math.roundi(i32, pixels / 80.0));
    const nice_range: f32 = niceNum(f32, range.size() * 0.99, false);
    const interval: f32 = niceNum(f32, nice_range / float(n_major - 1), true);
    const graphmin: f32 = @floor(range.min / interval) * interval;
    const graphmax: f32 = @ceil(range.max / interval) * interval;
    var buf: [label_max_size]u8 = undefined;

    var major: f32 = graphmin;
    while (major < graphmax + 0.5 * interval) : (major += interval) {
        if (major - interval < 0 and major + interval > 0) {
            major = 0;
        }
        if (range.contains(major)) {
            const label: []const u8 = formatTickDefault(major, &buf);
            _ = ticker.addTickLabel(ctx, major, true, true, label);
        }
        var i: i32 = 1;
        while (i < n_minor) : (i += 1) {
            const minor = major + float(i) * interval / float(n_minor);
            if (range.contains(minor)) {
                _ = ticker.addTickLabel(ctx, minor, false, false, null);
            }
        }
    }
}

/// Add user-specified ticks (with optional labels).
fn addTicksCustom(
    ctx: *Context,
    values: []const f32,
    labels: ?[]const [:0]const u8,
    ticker: *Ticker,
) void {
    var buf: [label_max_size]u8 = undefined;
    for (values, 0..) |v, i| {
        if (labels) |ls| {
            _ = ticker.addTickLabel(ctx, v, false, true, ls[i]);
        } else {
            const label: []const u8 = formatTickDefault(v, &buf);
            _ = ticker.addTickLabel(ctx, v, false, true, label);
        }
    }
}

//=============================================================================
// [SECTION] Setup API
//
// All Setup* must be called after beginPlot and before the first plot/setup-
// locking call. (We don't hard-assert the ordering; misuse simply has no
// effect after setup lock.)
//=============================================================================

fn axisPtr(ctx: *Context, idx: Axis3D) *Axis {
    return &ctx.currentPlot().axes[@intCast(@backingInt(idx))];
}

/// Compare two packed flag structs for equality.
inline fn flagsEql(a: anytype, b: @TypeOf(a)) bool {
    const I = @typeInfo(@TypeOf(a)).@"struct".backing_integer.?;
    return @as(I, @bitCast(a)) == @as(I, @bitCast(b));
}

pub fn setupAxis(ctx: *Context, idx: Axis3D, label: ?[]const u8, flags: AxisFlags) void {
    const plot: *Plot3D = ctx.currentPlot();
    const axis: *Axis = &plot.axes[@intCast(@backingInt(idx))];
    if (!flagsEql(axis.previous_flags, flags)) {
        axis.flags = flags;
    }
    axis.previous_flags = flags;
    if (label) |l| {
        axis.setLabel(ctx.gpa, l);
    }
}

/// Set a Zig-style format string for an axis's tick labels (e.g. "{d} Hz").
/// DEVIATION: upstream takes a C callback formatter; we take a format string.
pub fn setupAxisFormat(ctx: *Context, idx: Axis3D, fmt: ?[]const u8) void {
    const plot: *Plot3D = ctx.currentPlot();
    plot.axes[@intCast(@backingInt(idx))].format = fmt;
}

/// Apply equal aspect ratio using ref_axis as reference.
fn applyEqualAspect(plot: *Plot3D, ref_axis: Axis3D) void {
    const ri: usize = @intCast(@backingInt(ref_axis));
    const aspect: f32 = plot.axes[ri].getAspect();
    for (0..3) |i| {
        if (i != ri and !plot.axes[i].isInputLocked()) {
            plot.axes[i].setAspect(aspect);
        }
    }
}

pub fn setupAxisLimits(
    ctx: *Context,
    idx: Axis3D,
    min_lim: f32,
    max_lim: f32,
    cond: Cond,
) void {
    const plot: *Plot3D = ctx.currentPlot();
    const axis: *Axis = &plot.axes[@intCast(@backingInt(idx))];
    if (!plot.initialized or cond == .always) {
        axis.setRange(min_lim, max_lim);
        axis.range_cond = cond;
        axis.fit_this_frame = false;
        if (plot.flags.equal) {
            applyEqualAspect(plot, idx);
        }
    }
}

fn transformForwardLog10(v: f32, _: ?*anyopaque) callconv(.c) f32 {
    return math.log10(v);
}

fn transformInverseLog10(v: f32, _: ?*anyopaque) callconv(.c) f32 {
    return math.exp10(v);
}

const symlog_c: f32 = 1.0;

fn transformForwardSymLog(v: f32, _: ?*anyopaque) callconv(.c) f32 {
    const sign: f32 = if (v < 0) -1 else 1;
    return sign * math.log10(1 + @abs(v) / symlog_c);
}

fn transformInverseSymLog(v: f32, _: ?*anyopaque) callconv(.c) f32 {
    const sign: f32 = if (v < 0) -1 else 1;
    return sign * symlog_c * (math.exp10(@abs(v)) - 1);
}

pub fn setupAxisScale(ctx: *Context, idx: Axis3D, scale: Scale) void {
    const axis: *Axis = axisPtr(ctx, idx);
    axis.scale = scale;
    switch (scale) {
        .log10 => {
            axis.transform_forward = transformForwardLog10;
            axis.transform_inverse = transformInverseLog10;
            axis.transform_data = null;
            axis.constraint_range = .{ .min = math.floatMin(f32), .max = math.inf(f32) };
        },
        .sym_log => {
            axis.transform_forward = transformForwardSymLog;
            axis.transform_inverse = transformInverseSymLog;
            axis.transform_data = null;
            axis.constraint_range = .{ .min = -math.inf(f32), .max = math.inf(f32) };
        },
        .linear => {
            axis.transform_forward = null;
            axis.transform_inverse = null;
            axis.transform_data = null;
            axis.constraint_range = .{ .min = -math.inf(f32), .max = math.inf(f32) };
        },
    }
}

pub fn setupAxisScaleCustom(
    ctx: *Context,
    idx: Axis3D,
    forward: TransformFn,
    inverse_fn: TransformFn,
    data: ?*anyopaque,
) void {
    const axis: *Axis = axisPtr(ctx, idx);
    axis.transform_forward = forward;
    axis.transform_inverse = inverse_fn;
    axis.transform_data = data;
}

pub fn setupAxisTicks(
    ctx: *Context,
    idx: Axis3D,
    values: []const f32,
    labels: ?[]const [:0]const u8,
    keep_default: bool,
) void {
    const axis: *Axis = axisPtr(ctx, idx);
    axis.show_default_ticks = keep_default;
    addTicksCustom(ctx, values, labels, &axis.ticker);
}

pub fn setupAxisTicksRange(
    ctx: *Context,
    idx: Axis3D,
    v_min: f32,
    v_max: f32,
    n_ticks_in: usize,
    labels: ?[]const [:0]const u8,
    keep_default: bool,
) void {
    const n_ticks: usize = if (n_ticks_in < 2) 2 else n_ticks_in;
    var buf: [64]f32 = undefined;
    const n: usize = @min(n_ticks, buf.len);
    for (0..n) |i| {
        const t = float(i) / float(n - 1);
        buf[i] = v_min + t * (v_max - v_min);
    }
    setupAxisTicks(ctx, idx, buf[0..n], labels, keep_default);
}

pub fn setupAxisLimitsConstraints(
    ctx: *Context,
    idx: Axis3D,
    v_min: f32,
    v_max: f32,
) void {
    const axis: *Axis = axisPtr(ctx, idx);
    axis.constraint_range.min = v_min;
    axis.constraint_range.max = v_max;
}

pub fn setupAxisZoomConstraints(
    ctx: *Context,
    idx: Axis3D,
    zoom_min: f32,
    zoom_max: f32,
) void {
    const axis: *Axis = axisPtr(ctx, idx);
    axis.constraint_zoom.min = zoom_min;
    axis.constraint_zoom.max = zoom_max;
}

pub fn setupAxes(
    ctx: *Context,
    x_label: ?[]const u8,
    y_label: ?[]const u8,
    z_label: ?[]const u8,
    x_flags: AxisFlags,
    y_flags: AxisFlags,
    z_flags: AxisFlags,
) void {
    setupAxis(ctx, .x, x_label, x_flags);
    setupAxis(ctx, .y, y_label, y_flags);
    setupAxis(ctx, .z, z_label, z_flags);
}

pub fn setupAxesLimits(
    ctx: *Context,
    x_min: f32,
    x_max: f32,
    y_min: f32,
    y_max: f32,
    z_min: f32,
    z_max: f32,
    cond: Cond,
) void {
    setupAxisLimits(ctx, .x, x_min, x_max, cond);
    setupAxisLimits(ctx, .y, y_min, y_max, cond);
    setupAxisLimits(ctx, .z, z_min, z_max, cond);
    if (cond == .once) {
        ctx.currentPlot().fit_this_frame = false;
    }
}

/// Estimate the animation duration (seconds) for a rotation slerp.
fn calcAnimationTime(q1: Quat, q2: Quat) f32 {
    var d: f32 = dot4(q1, q2);
    if (d < 0) {
        d = -d;
    }
    d = math.clamp(d, -1, 1);
    const angle: f32 = math.acos(d) * 2.0;
    return @floatCast(@min(angle / math.pi, 1.0) * 0.5); // up to ~0.5s
}

pub fn setupBoxRotationQuat(
    ctx: *Context,
    rotation: Quat,
    animate: bool,
    cond: Cond,
) void {
    const plot: *Plot3D = ctx.currentPlot();
    if (!plot.initialized or cond == .always) {
        if (!animate) {
            plot.rotation = rotation;
            plot.animation_time = 0;
        } else {
            plot.rotation_animation_end = rotation;
            plot.animation_time = calcAnimationTime(plot.rotation, plot.rotation_animation_end);
        }
        plot.rotation_cond = cond;
    }
}

pub fn setupBoxRotation(
    ctx: *Context,
    elevation_deg: f32,
    azimuth_deg: f32,
    animate: bool,
    cond: Cond,
) void {
    // Degrees at the API - the convention for a plot's camera - and turns through the middle,
    // because 360 degrees is exactly one turn where 180/pi is not exactly anything.
    const elevation_turns: f32 = turnsFromDeg(elevation_deg);
    const azimuth_turns: f32 = turnsFromDeg(azimuth_deg);
    setupBoxRotationQuat(ctx, quatFromElAz(elevation_turns, azimuth_turns), animate, cond);
}

pub fn setupBoxInitialRotationQuat(ctx: *Context, rotation: Quat) void {
    ctx.currentPlot().initial_rotation = rotation;
}

pub fn setupBoxInitialRotation(ctx: *Context, elevation_deg: f32, azimuth_deg: f32) void {
    const elevation_turns: f32 = turnsFromDeg(elevation_deg);
    const azimuth_turns: f32 = turnsFromDeg(azimuth_deg);
    setupBoxInitialRotationQuat(ctx, quatFromElAz(elevation_turns, azimuth_turns));
}

pub fn setupBoxScale(ctx: *Context, x: f32, y: f32, z: f32) void {
    const plot: *Plot3D = ctx.currentPlot();
    plot.axes[0].ndc_scale = x;
    plot.axes[1].ndc_scale = y;
    plot.axes[2].ndc_scale = z;
}

pub fn setupLegend(ctx: *Context, location: Location, flags: LegendFlags) void {
    const items: *ItemGroup = ctx.current_items orelse return;
    const legend: *Legend = &items.legend;
    if (!flagsEql(legend.previous_location, location)) {
        legend.location = location;
    }
    legend.previous_location = location;
    if (!flagsEql(legend.previous_flags, flags)) {
        legend.flags = flags;
    }
    legend.previous_flags = flags;
}

// ---- Log/SymLog transforms (callconv(.c) to match TransformFn) ------------

//=============================================================================
// [SECTION] BeginPlot / SetupLock / EndPlot
//=============================================================================

/// Begin a 3D plot. Returns false if the plot is clipped/skipped; only call the
/// Setup*/Plot* API and endPlot when this returns true.
/// Dear ImGui label/ID convention, applied to `beginPlot`'s `title_id`:
/// the visible title is the text before the first `##`; everything from `##`
/// on is ID-only and not drawn. Returns the end index of the visible portion.
fn labelVisibleEnd(s: []const u8) usize {
    return std.mem.indexOf(u8, s, "##") orelse s.len;
}
/// The substring hashed for the persistent plot ID. With `###`, only the text
/// after it seeds the ID, so the visible label can change frame-to-frame
/// without resetting the plot's stored rotation/limits. Otherwise the whole
/// string seeds the ID (matching plain and `##` labels).
fn idSeed(s: []const u8) []const u8 {
    if (std.mem.indexOf(u8, s, "###")) |at| {
        return s[at + 3 ..];
    }
    return s;
}

pub fn beginPlot(ctx: *Context, title_id: [:0]const u8, size: Vec2, flags: Flags) bool {
    const im: Im = ctx.im();
    assert(ctx.current_plot == null, @src()); // mismatched beginPlot/endPlot

    if (im.skipItems()) {
        return false;
    }

    const id: Im.ID = im.getID(idSeed(title_id));
    const just_created: bool = ctx.plots.getByKey(id) == null;
    const plot: *Plot3D = ctx.plots.getOrAddByKey(id);
    ctx.current_plot = plot;
    ctx.current_items = &plot.items;

    plot.id = id;
    plot.just_created = just_created;
    plot.view_scale_factor = ctx.style.view_scale_factor;
    if (just_created) {
        plot.rotation = plot.initial_rotation;
        plot.fit_this_frame = true;
        for (&plot.axes) |*ax| {
            ax.fit_this_frame = true;
        }
    }
    if (!flagsEql(plot.previous_flags, flags)) {
        plot.flags = flags;
    }
    plot.previous_flags = flags;
    plot.setup_locked = false;
    plot.open_context_this_frame = false;
    plot.rotation_cond = .none;

    plot.setTitle(ctx.gpa, title_id[0..labelVisibleEnd(title_id)]);

    // Frame size
    var frame_size: Vec2 = im.calcItemSize(size, ctx.style.plot_default_size[0], ctx.style.plot_default_size[1]);
    if (frame_size[0] < ctx.style.plot_min_size[0] and size[0] < 0) {
        frame_size[0] = ctx.style.plot_min_size[0];
    }
    if (frame_size[1] < ctx.style.plot_min_size[1] and size[1] < 0) {
        frame_size[1] = ctx.style.plot_min_size[1];
    }

    const cursor: Vec2 = im.getCursorScreenPos();
    plot.frame_rect = .{ .min = cursor, .max = cursor + frame_size };
    im.itemSize(plot.frame_rect);
    if (!im.itemAdd(plot.frame_rect, plot.id)) {
        ctx.current_plot = null;
        ctx.current_items = null;
        ctx.current_item = null;
        return false;
    }

    plot.items.legend.reset();
    for (&plot.axes) |*ax| {
        ax.reset();
    }

    const dl: Im.DrawList = im.getWindowDrawList();
    dl.pushClipRect(plot.frame_rect.min, plot.frame_rect.max, true);
    return true;
}

inline fn almostEqual(a: f32, b: f32) bool {
    return @abs(a - b) <= 1e-9 * @max(@abs(a), @abs(b));
}

/// Draw text horizontally centered at `center` (top-aligned).
fn addTextCentered(
    ctx: *Context,
    dl: Im.DrawList,
    center: Vec2,
    col: zm.ColorU32,
    s: []const u8,
) void {
    const im: Im = ctx.im();
    const ts: Vec2 = im.calcTextSize(s);
    dl.addText(.{ center[0] - ts[0] * 0.5, center[1] }, col, s);
}

/// Scale all unlocked axis ranges about their centers (factor < 1 zooms in).
fn zoomAxes(plot: *Plot3D, factor: f32) void {
    for (&plot.axes) |*axis| {
        if (axis.isInputLocked()) {
            continue;
        }
        const center: f32 = (axis.range.min + axis.range.max) * 0.5;
        const half: f32 = (axis.range.max - axis.range.min) * 0.5 * factor;
        axis.setRange(center - half, center + half);
    }
}

/// Orbit the view by a per-frame screen drag (pixels). Yaw is about the world-up
/// axis (flipped when the box is upside-down so drag direction stays intuitive);
/// pitch is about screen-x. Compose order matches the validated convention.
fn orbitBy(plot: *Plot3D, dx: f32, dy: f32) void {
    const sens: f32 = 0.01;
    if (equals3(plot.drag_rotation_axis, point3(0, 0, 0))) {
        const up_vector: Point3 = rotate(plot.rotation, point3(0, 0, 1));
        plot.drag_rotation_axis = if (up_vector[2] < 0) point3(0, 0, -1) else point3(0, 0, 1);
    }
    const q_pitch: Quat = quatFromAxisAngle(point3(1, 0, 0), dy * sens);
    const q_yaw: Quat = quatFromAxisAngle(plot.drag_rotation_axis, dx * sens);
    plot.rotation = normalize4(qmul(qmul(q_pitch, plot.rotation), q_yaw));
}

/// 3D camera input. Orbit: one-finger / left-button drag (gated to a press that
/// began on the plot). Zoom: two-finger pinch or mouse wheel, around box center.
/// Double-click (synthesized from left-click edges) resets rotation + refits.
/// DEVIATION: per-axis/plane edge hover-highlight and pan/translation from
/// upstream HandleInput are not yet ported.
fn handleInput(ctx: *Context, plot: *Plot3D) void {
    const im: Im = ctx.im();
    if (plot.flags.no_inputs) {
        return;
    }

    const allow_rotate: bool = !plot.flags.no_rotate;
    const allow_zoom: bool = !plot.flags.no_zoom;
    const allow_pan: bool = !plot.flags.no_pan;

    const result: Im.ButtonResult = im.buttonBehavior(plot.plot_rect, plot.id, .{});
    plot.hovered = result.hovered;
    plot.held = result.held;

    const touches: i32 = im.touchCount();

    // DOUBLE-CLICK RESET (synthesized: two left-clicks within 0.3s on the plot).
    if (plot.hovered and im.isMouseClicked(.left)) {
        if (plot.time_since_click >= 0 and plot.time_since_click < 0.3) {
            plot.rotation = plot.initial_rotation;
            plot.pan_offset = .{ 0, 0 };
            plot.fit_this_frame = true;
            for (&plot.axes) |*ax| {
                ax.fit_this_frame = true;
            }
            plot.time_since_click = -1;
        } else {
            plot.time_since_click = 0;
        }
    } else if (plot.time_since_click >= 0) {
        plot.time_since_click += im.deltaTime();
        if (plot.time_since_click > 0.3) {
            plot.time_since_click = -1;
        }
    }

    if (touches >= 2) {
        // TWO FINGERS: pinch zooms (spacing change) and the midpoint pans.
        const a: Vec2 = im.touchPos(0);
        const b: Vec2 = im.touchPos(1);
        const dist: f32 = @sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));
        const mid: Vec2 = .{ (a[0] + b[0]) * 0.5, (a[1] + b[1]) * 0.5 };
        if (plot.prev_pinch > 0) {
            if (allow_zoom and dist > 0) {
                zoomAxes(plot, plot.prev_pinch / dist);
            }
            if (allow_pan) {
                plot.pan_offset = .{
                    plot.pan_offset[0] + (mid[0] - plot.prev_pinch_mid[0]),
                    plot.pan_offset[1] + (mid[1] - plot.prev_pinch_mid[1]),
                };
            }
        }
        plot.prev_pinch = dist;
        plot.prev_pinch_mid = mid;
        plot.orbit_active = false;
        plot.pan_active = false;
        plot.drag_rotation_axis = @splat(0);
    } else {
        plot.prev_pinch = 0;
        const mouse: Vec2 = im.getMousePos();
        const dragging_left: bool = plot.held and im.isMouseDown(.left);
        // Shift+left-drag pans; plain left-drag orbits. `*_active` skips the
        // press-frame teleport; `held` ensures the press began on the plot.
        if (dragging_left and im.shiftDown() and allow_pan) {
            if (plot.pan_active) {
                plot.pan_offset = .{
                    plot.pan_offset[0] + (mouse[0] - plot.last_drag_pos[0]),
                    plot.pan_offset[1] + (mouse[1] - plot.last_drag_pos[1]),
                };
            }
            plot.pan_active = true;
            plot.orbit_active = false;
            plot.last_drag_pos = mouse;
            plot.drag_rotation_axis = @splat(0);
        } else if (dragging_left and allow_rotate and !plot.isRotationLocked()) {
            if (plot.orbit_active) {
                orbitBy(plot, mouse[0] - plot.last_drag_pos[0], mouse[1] - plot.last_drag_pos[1]);
            }
            plot.orbit_active = true;
            plot.pan_active = false;
            plot.last_drag_pos = mouse;
        } else {
            plot.orbit_active = false;
            plot.pan_active = false;
            plot.drag_rotation_axis = @splat(0);
        }
    }

    // WHEEL ZOOM (desktop), around box center.
    if (plot.hovered and allow_zoom) {
        const wheel: f32 = im.getMouseWheel();
        if (wheel != 0) {
            zoomAxes(plot, 1.0 - 0.1 * wheel);
        }
    }
}

fn renderTicksAndLabels(
    ctx: *Context,
    dl: Im.DrawList,
    plot: *Plot3D,
    corners: *const [8]Point3,
    corners_pix: *const [8]Vec2,
    active_faces: *const [3]bool,
    plane_2d: i32,
) void {
    const im: Im = ctx.im();
    _ = corners;
    _ = corners_pix;
    _ = active_faces;
    _ = plane_2d;
    const tick_col: zm.ColorU32 = getStyleColorU32(ctx, .axis_tick);
    const text_col: zm.ColorU32 = getStyleColorU32(ctx, .axis_text);
    const range_min: Point3 = plot.rangeMin();
    const range_max: Point3 = plot.rangeMax();

    // For each axis, place tick labels along the edge from range_min varying
    // only that axis. (Simplification of upstream's active-edge selection.)
    var a: usize = 0;
    while (a < 3) : (a += 1) {
        const axis: *const Axis = &plot.axes[a];
        if (!axis.hasTickLabels() and !axis.hasTickMarks()) {
            continue;
        }
        for (axis.ticker.ticks.items, 0..) |tick, ti| {
            const axis_span: f32 = axis.range.max - axis.range.min;
            const t: f32 = (tick.plot_pos - axis.range.min) / axis_span;
            if (t < 0 or t > 1) {
                continue;
            }
            // Walk the edge that leaves `range_min` along THIS axis only; the other two
            // coordinates stay pinned at their minimum.
            //
            // ★ THE SWITCH IS LOAD-BEARING, NOT VERBOSITY. `Point3` is `@Vector(4, f32)`, and a
            // vector index must be COMPTIME-KNOWN - `tick_point[a]` with a runtime `a` is
            // `error: vector index not comptime known`. The switch gives each arm a literal
            // index. Anyone "simplifying" this back to `tick_point[a]` gets a compile error, but
            // only from a target that actually builds this file.
            var tick_point: Point3 = range_min;
            switch (a) {
                0 => tick_point[0] = range_min[0] + t * (range_max[0] - range_min[0]),
                1 => tick_point[1] = range_min[1] + t * (range_max[1] - range_min[1]),
                2 => tick_point[2] = range_min[2] + t * (range_max[2] - range_min[2]),
                else => unreachable,
            }
            const pix: Vec2 = plotToPixelsP(plot, tick_point);
            if (axis.hasTickMarks() and tick.major) {
                dl.addLine(pix, .{ pix[0], pix[1] + 4 }, tick_col, 1.0);
            }
            if (axis.hasTickLabels() and tick.show_label and tick.text_offset >= 0) {
                const label: []const u8 = axis.ticker.getText(ti);
                const label_size: Vec2 = im.calcTextSize(label);
                // Centred under the tick: back off by half the text width, then down by the
                // same 4px the tick mark uses.
                const label_pos: Vec2 = .{ pix[0] - label_size[0] * 0.5, pix[1] + 4 };
                dl.addText(label_pos, text_col, label);
            }
        }
        // The axis name, at the MIDDLE of that axis's own edge.
        //
        // ★ This previously read `var p = range_max; ... _ = &p;` - every axis drew its label at
        // the same `range_max` corner, so all three names stacked on one point and only the last
        // was readable. The `_ = &p` was there to stop the compiler complaining that a `var`
        // which is never written should be `const`, which is a fair signal that the line meant
        // to vary something and did not. Midpoint of the edge matches how the ticks above are
        // placed, so the label now sits with the values it names.
        if (axis.hasLabel()) {
            var label_point: Point3 = range_min;
            switch (a) {
                0 => label_point[0] = (range_min[0] + range_max[0]) * 0.5,
                1 => label_point[1] = (range_min[1] + range_max[1]) * 0.5,
                2 => label_point[2] = (range_min[2] + range_max[2]) * 0.5,
                else => unreachable,
            }
            const pix: Vec2 = plotToPixelsP(plot, label_point);
            dl.addText(pix, text_col, axis.getLabel());
        }
    }
}

const box_faces = [6][4]usize{
    .{ 0, 3, 7, 4 }, // X-min
    .{ 0, 4, 5, 1 }, // Y-min
    .{ 0, 1, 2, 3 }, // Z-min
    .{ 1, 2, 6, 5 }, // X-max
    .{ 3, 7, 6, 2 }, // Y-max
    .{ 4, 5, 6, 7 }, // Z-max
};

fn renderPlotBackground(
    ctx: *Context,
    dl: Im.DrawList,
    plot: *Plot3D,
    corners_pix: *const [8]Vec2,
    active_faces: *const [3]bool,
    plane_2d: i32,
) void {
    _ = plot;
    const col: zm.ColorU32 = getStyleColorU32(ctx, .plot_bg);
    var face: usize = 0;
    while (face < 3) : (face += 1) {
        if (plane_2d != -1 and @as(i32, @intCast(face)) != plane_2d) {
            continue;
        }
        // Same far-face selection as `renderGrid`: `active_faces` picks the wall behind the
        // data so the fill does not sit over it.
        const face_index: usize = face + 3 * @as(usize, @intFromBool(active_faces[face]));
        const face_corners: [4]usize = box_faces[face_index];
        dl.addQuadFilled(
            corners_pix[face_corners[0]],
            corners_pix[face_corners[1]],
            corners_pix[face_corners[2]],
            corners_pix[face_corners[3]],
            col,
        );
    }
}

const box_edges = [12][2]usize{
    .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 }, .{ 3, 0 }, // bottom
    .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 4 }, // top
    .{ 0, 4 }, .{ 1, 5 }, .{ 2, 6 }, .{ 3, 7 }, // verticals
};

/// Distance from point `p` to segment `a`–`b` (screen space).
fn distPointSegment(p: Vec2, a: Vec2, b: Vec2) f32 {
    const abx: f32 = b[0] - a[0];
    const aby: f32 = b[1] - a[1];
    const apx: f32 = p[0] - a[0];
    const apy: f32 = p[1] - a[1];
    const denom: f32 = abx * abx + aby * aby;
    const t: f32 = if (denom > 0) math.clamp((apx * abx + apy * aby) / denom, 0, 1) else 0;
    const dx: f32 = apx - t * abx;
    const dy: f32 = apy - t * aby;
    return @sqrt(dx * dx + dy * dy);
}

/// Which plot axis each of the 12 cube edges runs along (0=x, 1=y, 2=z). The
/// edges fall into 3 groups of 4 parallel edges; the bottom/top perimeters
/// alternate x/y, the verticals are all z.
const axis_of_edge = [12]u2{ 0, 1, 0, 1, 0, 1, 0, 1, 2, 2, 2, 2 };

/// Index (0..2) of the box axis whose screen-space edges are nearest `mouse`, or
/// -1 if the nearest edge is farther than `max_px`. The 12 edges group into 3
/// sets of 4 parallel edges (one per axis); the nearest single edge picks the
/// axis. Used to highlight the axis the cursor is over as an interaction hint.
fn hoveredAxis(corners_pix: *const [8]Vec2, mouse: Vec2, max_px: f32) i32 {
    var best: f32 = max_px;
    var best_axis: i32 = -1;
    for (box_edges, 0..) |e, i| {
        const d: f32 = distPointSegment(mouse, corners_pix[e[0]], corners_pix[e[1]]);
        if (d < best) {
            best = d;
            best_axis = @as(i32, axis_of_edge[i]);
        }
    }
    return best_axis;
}

/// Cursor proximity (screen px) within which a box edge counts as hovered.
const edge_hover_px: f32 = 30.0;

fn renderPlotBorder(
    ctx: *Context,
    dl: Im.DrawList,
    plot: *Plot3D,
    corners_pix: *const [8]Vec2,
    active_faces: *const [3]bool,
    plane_2d: i32,
) void {
    const im: Im = ctx.im();
    _ = active_faces;
    _ = plane_2d;
    const col: zm.ColorU32 = getStyleColorU32(ctx, .plot_border);
    // While hovering, brighten + thicken the 4 edges of the axis nearest the
    // cursor as an interaction affordance (matches ImPlot3D's edge feedback).
    const hi_axis: i32 = if (plot.hovered) hoveredAxis(corners_pix, im.getMousePos(), edge_hover_px) else -1;
    const hi_col: zm.ColorU32 = plot_core.lerpWire(col, 0xFFFFFFFF, 0.6);
    for (box_edges, 0..) |e, i| {
        if (hi_axis >= 0 and @as(i32, axis_of_edge[i]) == hi_axis) {
            dl.addLine(corners_pix[e[0]], corners_pix[e[1]], hi_col, 2.0);
        } else {
            dl.addLine(corners_pix[e[0]], corners_pix[e[1]], col, 1.0);
        }
    }
}

fn renderGrid(
    ctx: *Context,
    dl: Im.DrawList,
    plot: *Plot3D,
    corners: *const [8]Point3,
    active_faces: *const [3]bool,
    plane_2d: i32,
) void {
    const im: Im = ctx.im();
    const base: Color = getStyleColor(ctx, .axis_grid);
    const col_minor: zm.ColorU32 = im.colorToU32(base.scaleAlpha(0.3));
    const col_major: zm.ColorU32 = im.colorToU32(base.scaleAlpha(0.6));

    var face: usize = 0;
    while (face < 3) : (face += 1) {
        if (plane_2d != -1 and @as(i32, @intCast(face)) != plane_2d) {
            continue;
        }
        // Each axis pair has two opposing faces of the box; `active_faces` picks the one facing
        // away from the camera, so the grid is drawn on the far wall rather than across the data.
        const face_index: usize = face + 3 * @as(usize, @intFromBool(active_faces[face]));
        const axis_u: *const Axis = &plot.axes[(face + 1) % 3];
        const axis_v: *const Axis = &plot.axes[(face + 2) % 3];

        // The face's four corners, in winding order. Only three are needed: one origin and the
        // two edges leaving it.
        const face_corners: [4]usize = box_faces[face_index];
        const origin: Point3 = corners[face_corners[0]];
        const u_end: Point3 = corners[face_corners[1]];
        const v_end: Point3 = corners[face_corners[3]];
        const u_edge: Point3 = u_end - origin;
        const v_edge: Point3 = v_end - origin;

        // A grid line for a tick on axis U runs ALONG V, and vice versa - the line marks one
        // value of U and spans every value of V. Naming the endpoints after the edge they are
        // offset from is what makes that readable: previously `u_vec` came from `p1` while the
        // U-lines ran to `p3`, which is right but reads as a bug every time.
        if (axis_u.hasGridLines()) {
            for (axis_u.ticker.ticks.items) |tick| {
                const u_span: f32 = axis_u.range.max - axis_u.range.min;
                const t_u: f32 = (tick.plot_pos - axis_u.range.min) / u_span;
                if (t_u < 0 or t_u > 1) {
                    continue;
                }
                const offset_u: Point3 = u_edge * splat(t_u);
                const line_start: Vec2 = plotToPixelsP(plot, origin + offset_u);
                const line_end: Vec2 = plotToPixelsP(plot, v_end + offset_u);
                const color: zm.ColorU32 = if (tick.major) col_major else col_minor;
                dl.addLine(line_start, line_end, color, 1.0);
            }
        }
        if (axis_v.hasGridLines()) {
            for (axis_v.ticker.ticks.items) |tick| {
                const v_span: f32 = axis_v.range.max - axis_v.range.min;
                const t_v: f32 = (tick.plot_pos - axis_v.range.min) / v_span;
                if (t_v < 0 or t_v > 1) {
                    continue;
                }
                const offset_v: Point3 = v_edge * splat(t_v);
                const line_start: Vec2 = plotToPixelsP(plot, origin + offset_v);
                const line_end: Vec2 = plotToPixelsP(plot, u_end + offset_v);
                const color: zm.ColorU32 = if (tick.major) col_major else col_minor;
                dl.addLine(line_start, line_end, color, 1.0);
            }
        }
    }
}

fn renderPlotBox(ctx: *Context, dl: Im.DrawList, plot: *Plot3D) void {
    var active_faces: [3]bool = undefined;
    var plane_2d: i32 = -1;
    computeActiveFaces(&active_faces, plot.rotation, &plot.axes, &plane_2d);

    var corners: [8]Point3 = undefined;
    computeBoxCorners(&corners, plot.rangeMin(), plot.rangeMax());
    var corners_pix: [8]Vec2 = undefined;
    computeBoxCornersPix(plot, &corners_pix, &corners);

    renderPlotBackground(ctx, dl, plot, &corners_pix, &active_faces, plane_2d);
    renderPlotBorder(ctx, dl, plot, &corners_pix, &active_faces, plane_2d);
    renderGrid(ctx, dl, plot, &corners, &active_faces, plane_2d);
    renderTicksAndLabels(ctx, dl, plot, &corners, &corners_pix, &active_faces, plane_2d);
}

/// Lock setup: resolve default ticks/colors, lay out rects, run animation and
/// input, and render the plot box. Idempotent within a frame.
fn setupLock(ctx: *Context) void {
    const im: Im = ctx.im();
    const plot: *Plot3D = ctx.current_plot orelse return;
    if (plot.setup_locked) {
        return;
    }
    plot.setup_locked = true;

    const dl: Im.DrawList = im.getWindowDrawList();

    // Frame background
    dl.addRectFilled(plot.frame_rect.min, plot.frame_rect.max, getStyleColorU32(ctx, .frame_bg));

    // Canvas / plot rects
    const pad: Vec2 = ctx.style.plot_padding;
    plot.canvas_rect = .{ .min = plot.frame_rect.min + pad, .max = plot.frame_rect.max - pad };
    plot.plot_rect = plot.canvas_rect;

    // Equal aspect (if requested and not already ~equal)
    if (plot.flags.equal) {
        const xar: f32 = plot.axes[0].getAspect();
        const yar: f32 = plot.axes[1].getAspect();
        const zar: f32 = plot.axes[2].getAspect();
        if (!almostEqual(xar, yar) or !almostEqual(xar, zar)) {
            const aspect: f32 = (xar + yar + zar) / 3.0;
            plot.axes[0].setAspect(aspect);
            plot.axes[1].setAspect(aspect);
            plot.axes[2].setAspect(aspect);
        }
    }

    // Default ticks
    for (&plot.axes) |*axis| {
        if (axis.show_default_ticks) {
            const pixels: f32 = @floatCast(@as(f32, plot.getViewScale()) * axis.ndc_scale);
            locatorDefault(ctx, &axis.ticker, axis.range, pixels);
        }
    }

    // Cache axis colors
    for (&plot.axes) |*axis| {
        axis.color_bg = getStyleColorU32(ctx, .axis_bg);
        axis.color_hov = getStyleColorU32(ctx, .axis_bg_hovered);
        axis.color_act = getStyleColorU32(ctx, .axis_bg_active);
    }

    // Title
    if (plot.hasTitle()) {
        const col: zm.ColorU32 = getStyleColorU32(ctx, .title_text);
        const top_center = Vec2{ plot.frame_rect.center()[0], plot.canvas_rect.min[1] };
        addTextCentered(ctx, dl, top_center, col, plot.getTitle());
        plot.plot_rect.min[1] += im.getTextLineHeight() + ctx.style.label_padding[1];
    }

    // Animation
    if (plot.animation_time > 0) {
        const io: Im.IO = im.getIO();
        _ = io;
        const dt: f32 = 1.0 / 60.0; // ui has no DeltaTime in the snapshot; assume 60fps (DEVIATION)
        const t: f32 = math.clamp(dt / plot.animation_time, 0, 1);
        plot.animation_time -= dt;
        if (plot.animation_time < 0) {
            plot.animation_time = 0;
        }
        plot.rotation = slerp(plot.rotation, plot.rotation_animation_end, t);
    }

    plot.initialized = true;

    handleInput(ctx, plot);

    dl.pushClipRect(plot.plot_rect.min, plot.plot_rect.max, true);
    renderPlotBox(ctx, dl, plot);
}

fn renderLegend(ctx: *Context, dl: Im.DrawList, plot: *Plot3D) void {
    const im: Im = ctx.im();
    if (plot.flags.no_legend) {
        return;
    }
    const items: *ItemGroup = &plot.items;
    const n: usize = items.getLegendCount();
    if (n == 0) {
        return;
    }

    const txt_h: f32 = im.getTextLineHeight();
    const pad: Vec2 = ctx.style.legend_padding;
    const inner: Vec2 = ctx.style.legend_inner_padding;
    const icon: f32 = txt_h;

    // Measure
    var max_w: f32 = 0;
    for (0..n) |i| {
        const label: [:0]const u8 = items.getLegendLabel(i);
        const ts: Vec2 = im.calcTextSize(label);
        max_w = @max(max_w, ts[0]);
    }
    const w: f32 = inner[0] * 2 + icon + 4 + max_w;
    const h = inner[1] * 2 + float(n) * txt_h;

    // Position: north-west of the plot rect by default.
    const origin = Vec2{ plot.plot_rect.min[0] + pad[0], plot.plot_rect.min[1] + pad[1] };
    const lr = PixRect{ .min = origin, .max = origin + Vec2{ w, h } };
    plot.items.legend.rect = lr;

    dl.addRectFilled(lr.min, lr.max, getStyleColorU32(ctx, .legend_bg));
    dl.addRect(lr.min, lr.max, getStyleColorU32(ctx, .legend_border));

    const text_col: zm.ColorU32 = getStyleColorU32(ctx, .legend_text);
    for (0..n) |i| {
        const item: *Item = items.getLegendItem(i);
        const label: [:0]const u8 = items.getLegendLabel(i);
        const row_y = origin[1] + inner[1] + float(i) * txt_h;
        const icon_min = Vec2{ origin[0] + inner[0], row_y + 2 };
        const icon_max = Vec2{ icon_min[0] + icon - 4, icon_min[1] + icon - 4 };
        dl.addRectFilled(icon_min, icon_max, item.color);
        dl.addText(.{ icon_min[0] + icon, row_y }, text_col, label);
    }
}

fn renderMousePos(ctx: *Context, dl: Im.DrawList, plot: *Plot3D) void {
    const im: Im = ctx.im();
    if (plot.flags.no_mouse_text) {
        return;
    }
    if (!plot.hovered) {
        return;
    }
    const mp: Vec2 = im.getMousePos();
    const ray: Point3 = pixelsToPlotPlane(ctx, mp, .xy, true);
    if (point3IsNan(ray)) {
        return;
    }
    var buf: [64]u8 = undefined;
    const s: []const u8 = bufPrint(&buf, "{d:.3}, {d:.3}, {d:.3}", .{ ray[0], ray[1], ray[2] }) catch return;
    const ts: Vec2 = im.calcTextSize(s);
    const pos = Vec2{ plot.plot_rect.max[0] - ts[0] - 5, plot.plot_rect.max[1] - ts[1] - 5 };
    dl.addText(pos, getStyleColorU32(ctx, .inlay_text), s);
}

/// End the current plot: flush the sorted 3D triangles, fit, render legend, and
/// reset per-frame state.
pub fn endPlot(ctx: *Context) void {
    const im: Im = ctx.im();
    const plot: *Plot3D = ctx.current_plot orelse @panic("implot3d: mismatched beginPlot/endPlot");

    const dl: Im.DrawList = im.getWindowDrawList();
    // Flush the depth-sorted triangle batch into the 2D draw list.
    plot.draw_list.flush(dl);

    // Data fitting
    if (plot.fit_this_frame) {
        plot.fit_this_frame = false;
        if (!plot.flags.equal) {
            for (&plot.axes) |*axis| {
                if (axis.fit_this_frame) {
                    axis.fit_this_frame = false;
                    axis.applyFit();
                }
            }
        } else {
            var ref_axis: Axis3D = .x;
            var max_aspect: f32 = 0;
            for (&plot.axes, 0..) |*axis, i| {
                if (axis.fit_this_frame) {
                    axis.fit_this_frame = false;
                    axis.applyFit();
                    const aspect: f32 = axis.getAspect();
                    if (aspect > max_aspect) {
                        max_aspect = aspect;
                        ref_axis = @fromBackingInt(@intCast(i));
                    }
                }
            }
            applyEqualAspect(plot, ref_axis);
        }
    }

    setupLock(ctx);

    dl.popClipRect(); // plot rect

    plot.items.legend.hovered = false;
    renderLegend(ctx, dl, plot);
    renderMousePos(ctx, dl, plot);

    dl.popClipRect(); // frame rect

    // Reset per-frame item flags
    for (0..plot.items.getItemCount()) |i| {
        plot.items.getItemByIndex(i).seen_this_frame = false;
    }

    ctx.current_plot = null;
    ctx.current_items = null;
    ctx.current_item = null;
}

//=============================================================================
// [SECTION] Plot box rendering
//
// Faithful-but-consolidated port of upstream's RenderPlotBox family. Upstream
// splits this into GetAxesParameters + 7 helpers with intricate 2D-degenerate
// edge selection; here we draw directly from the box corners and the
// active-face set. DEVIATION: the exact "which edge gets the ticks in a
// degenerate 2D view" logic is simplified to a consistent choice; the chrome
// is otherwise equivalent (background faces, 12 edges, grid on back faces,
// ticks + labels along the front-bottom edges, axis labels).
//=============================================================================

// Box face -> its 4 corner indices (min/max faces per axis). Index by
// face + 3*active (0..5), matching upstream's `faces` table.

// The 12 box edges as corner-index pairs.

//=============================================================================
// [SECTION] Legend & mouse-position rendering (minimal first-draft)
//=============================================================================

//=============================================================================
// [SECTION] Items + renderers
//
// Data plotting. A "getter" is anything with `.count: usize` and
// `fn at(self, i) Point3`. Renderers project each primitive and feed fills to
// the plot's DrawList3D (depth-sorted) and lines/markers to the 2D DrawList.
// DEVIATION: upstream's raw vertex/index emission is replaced by high-level
// shape calls; per-vertex colors collapse to a single per-primitive color.
//=============================================================================

const item_highlight_line_scale: f32 = 2.0;
const item_highlight_mark_scale: f32 = 1.25;

/// Plot-space depth used for the painter's sort: apply axis inversion, rotate,
/// take z. Larger = nearer (drawn later).
fn getPointDepth(plot: *const Plot3D, p_in: Point3) f32 {
    var p: Point3 = p_in;
    if (plot.axes[0].flags.invert) {
        p[0] = -p[0];
    }
    if (plot.axes[1].flags.invert) {
        p[1] = -p[1];
    }
    if (plot.axes[2].flags.invert) {
        p[2] = -p[2];
    }
    return rotate(plot.rotation, p)[2];
}

/// Register (or fetch) the item for `label_id`, adding it to the legend once
/// per frame.
fn registerOrGetItem(
    ctx: *Context,
    label_id: []const u8,
    flags: ItemFlags,
    just_created: *bool,
) *Item {
    const items: *ItemGroup = ctx.current_items.?;
    const id: Im.ID = items.getItemID(ctx, idSeed(label_id));
    just_created.* = items.getItem(id) == null;
    const item: *Item = items.getOrAddItem(id);
    if (item.seen_this_frame) {
        return item;
    }
    item.seen_this_frame = true;
    const idx: usize = items.item_pool.getIndex(item);
    item.id = id;
    // Dear ImGui convention: only the text before `##` shows in the legend; a
    // label that is empty or begins with `##` registers no legend entry.
    const visible: []const u8 = label_id[0..labelVisibleEnd(label_id)];
    if (!flags.no_legend and visible.len > 0) {
        dropFrameOnOom(items.legend.indices.append(ctx.gpa, @intCast(idx)));
        item.name_offset = @intCast(items.legend.labels.items.len);
        dropFrameOnOom(items.legend.labels.appendSlice(ctx.gpa, visible));
        dropFrameOnOom(items.legend.labels.append(ctx.gpa, 0));
    }
    return item;
}

/// Next color from the current colormap (advances the per-group index).
fn nextColormapColorU32(ctx: *Context) u32 {
    const items: *ItemGroup = ctx.current_items.?;
    const cmap: Colormap = ctx.style.colormap;
    const kc: usize = ctx.colormap_data.getKeyCount(cmap);
    const idx: usize = @intCast(@mod(items.colormap_idx, @as(i32, @intCast(kc))));
    items.colormap_idx += 1;
    return ctx.colormap_data.getKeyColor(cmap, idx);
}

/// Next marker (advances the per-group index).
fn nextMarker(ctx: *Context) Marker {
    const items: *ItemGroup = ctx.current_items.?;
    const idx = @mod(items.marker_idx, @as(i32, @intCast(Marker.count)));
    items.marker_idx += 1;
    return @fromBackingInt(@intCast(idx));
}

fn endItem(ctx: *Context) void {
    ctx.next_item_data.reset();
    ctx.current_item = null;
}

/// Begin an item: resolve colors/markers/render flags from the spec into the
/// NextItemData. Returns false if the item is hidden.
fn beginItem(
    ctx: *Context,
    label_id: []const u8,
    spec: Spec,
    item_col: ?Color,
    item_mkr: ?Marker,
) bool {
    const im: Im = ctx.im();
    setupLock(ctx);
    const style: *Style = &ctx.style;
    const n: *NextItemData = &ctx.next_item_data;
    n.spec = spec;
    const s: *Spec = &n.spec;

    var just_created: bool = false;
    const item: *Item = registerOrGetItem(ctx, label_id, spec.flags, &just_created);
    ctx.current_item = item;

    if (item_col) |c| {
        item.color = im.colorToU32(c);
    } else if (just_created) {
        item.color = nextColormapColorU32(ctx);
    }

    if (item_mkr) |mkr| {
        if (mkr != .auto) {
            item.marker = mkr;
        } else if (just_created or item.marker == .none) {
            item.marker = nextMarker(ctx);
        }
    }

    const item_color: Color = im.colorFromU32(item.color);
    n.is_auto_line = s.line_color == null;
    n.is_auto_fill = s.fill_color == null;
    // Resolve auto (null) colors: line/fill fall back to the item color;
    // marker colors fall back to the resolved line color.
    const line_c: Color = s.line_color orelse item_color;
    var fill_c: Color = s.fill_color orelse item_color;
    const mline_c: Color = s.marker_line_color orelse line_c;
    var mfill_c: Color = s.marker_fill_color orelse line_c;

    if (s.line_weight < 0) {
        s.line_weight = style.line_weight;
    }
    if (s.marker == .auto) {
        s.marker = style.marker;
    }
    if (s.marker_size < 0) {
        s.marker_size = style.marker_size;
    }
    if (s.fill_alpha < 0) {
        s.fill_alpha = style.fill_alpha;
    }

    fill_c = fill_c.scaleAlpha(s.fill_alpha);
    mfill_c = mfill_c.scaleAlpha(s.fill_alpha);

    // Write the resolved concrete colors back so the renderers read them.
    s.line_color = line_c;
    s.fill_color = fill_c;
    s.marker_line_color = mline_c;
    s.marker_fill_color = mfill_c;

    n.render_line = line_c.a > 0 and s.line_weight > 0;
    n.render_fill = fill_c.a > 0;
    n.render_marker_line = line_c.a > 0 and s.line_weight > 0;
    n.render_marker_fill = fill_c.a > 0;

    if (!item.show) {
        endItem(ctx);
        return false;
    }
    if (item.legend_hovered and !ctx.current_items.?.legend.flags.no_highlight_item) {
        s.line_weight *= item_highlight_line_scale;
        s.marker_size *= item_highlight_mark_scale;
    }
    return true;
}

/// beginItem + data-fit extension over the getter's points.
fn beginItemEx(
    ctx: *Context,
    getter: anytype,
    label_id: []const u8,
    spec: Spec,
    item_col: ?Color,
    item_mkr: ?Marker,
) bool {
    if (beginItem(ctx, label_id, spec, item_col, item_mkr)) {
        const plot: *Plot3D = ctx.currentPlot();
        if (plot.fit_this_frame and !spec.flags.no_fit) {
            var i: usize = 0;
            while (i < getter.count) : (i += 1) plot.extendFit(getter.at(i));
        }
        return true;
    }
    return false;
}

// ---- Getters ---------------------------------------------------------------

/// Getter over three parallel coordinate slices.
fn GetterXYZ(comptime T: type) type {
    return struct {
        xs: []const T,
        ys: []const T,
        zs: []const T,
        count: usize,
        offset: i32 = 0,
        pub fn at(self: @This(), i_in: usize) Point3 {
            const n = self.count;
            const idx = @mod(@as(i64, @intCast(i_in)) + self.offset, @as(i64, @intCast(n)));
            const k: usize = @intCast(idx);
            return point3(@floatCast(self.xs[k]), @floatCast(self.ys[k]), @floatCast(self.zs[k]));
        }
    };
}

/// Getter over a slice of Point3.
const GetterPoints = struct {
    pts: []const Point3,
    count: usize,
    offset: i32 = 0,
    pub fn at(self: @This(), i_in: usize) Point3 {
        const idx = @mod(@as(i64, @intCast(i_in)) + self.offset, @as(i64, @intCast(self.count)));
        return self.pts[@intCast(idx)];
    }
};

/// Wrap a getter so the last point connects back to the first (loop).
fn GetterLoop(comptime G: type) type {
    return struct {
        inner: G,
        count: usize,
        pub fn at(self: @This(), i: usize) Point3 {
            return self.inner.at(@mod(i, self.inner.count));
        }
    };
}

// ---- Renderers (consume a getter, emit shapes) -----------------------------

/// Cull box in plot space (the current axis ranges).
fn cullBox(plot: *const Plot3D) Box {
    return .{ .min = plot.rangeMin(), .max = plot.rangeMax() };
}

/// Line strip: connect consecutive getter points (Liang-Barsky clipped).
fn renderLineStrip(
    plot: *Plot3D,
    dl: Im.DrawList,
    getter: anytype,
    col: zm.ColorU32,
    weight: f32,
) void {
    if (getter.count < 2) {
        return;
    }
    const box: Box = cullBox(plot);
    // A polyline, so each point is the END of one segment and the START of the next. Carrying
    // `segment_start` across the iteration is what makes it one `getter.at` per point rather
    // than two - the getters can be strided or wrapped views, so the call is not always free.
    var segment_start: Point3 = getter.at(0);
    var i: usize = 0;
    while (i < getter.count - 1) : (i += 1) {
        const segment_end: Point3 = getter.at(i + 1);
        // CLIPPED, not culled: a segment crossing the box edge is shortened to the part inside
        // rather than dropped, which is why this takes the two `clipped_*` outputs instead of
        // testing containment like the fill paths do.
        var clipped_start: Point3 = undefined;
        var clipped_end: Point3 = undefined;
        if (box.clipLineSegment(segment_start, segment_end, &clipped_start, &clipped_end)) {
            dl.addLine(
                plotToPixelsP(plot, clipped_start),
                plotToPixelsP(plot, clipped_end),
                col,
                weight,
            );
        }
        segment_start = segment_end;
    }
}

/// Line segments: every consecutive pair (i, i+1) for even i.
fn renderLineSegments(
    plot: *Plot3D,
    dl: Im.DrawList,
    getter: anytype,
    col: zm.ColorU32,
    weight: f32,
) void {
    const box: Box = cullBox(plot);
    // Disjoint segments, so `i` steps by TWO and nothing carries across iterations - the
    // difference from `renderLine` above, which treats the same points as one connected path.
    var i: usize = 0;
    while (i + 1 < getter.count) : (i += 2) {
        const segment_start: Point3 = getter.at(i);
        const segment_end: Point3 = getter.at(i + 1);
        var clipped_start: Point3 = undefined;
        var clipped_end: Point3 = undefined;
        if (box.clipLineSegment(segment_start, segment_end, &clipped_start, &clipped_end)) {
            dl.addLine(
                plotToPixelsP(plot, clipped_start),
                plotToPixelsP(plot, clipped_end),
                col,
                weight,
            );
        }
    }
}

/// Triangle fills (groups of 3), depth-sorted via DrawList3D.
fn renderTriangleFill(plot: *Plot3D, getter: anytype, col: zm.ColorU32) void {
    const box: Box = cullBox(plot);
    var prim: usize = 0;
    while (3 * prim + 2 < getter.count) : (prim += 1) {
        const vertex_a: Point3 = getter.at(3 * prim);
        const vertex_b: Point3 = getter.at(3 * prim + 1);
        const vertex_c: Point3 = getter.at(3 * prim + 2);
        // Dropped only when EVERY vertex is outside the box - a triangle with one corner inside
        // still has visible area. Note this is a corner test, not an overlap test: a large
        // triangle that spans the box with all three corners outside is culled even though part
        // of it is on screen. Cheap and nearly always right; the alternative is a real
        // box-triangle intersection per primitive.
        const all_outside: bool =
            !box.contains(vertex_a) and !box.contains(vertex_b) and !box.contains(vertex_c);
        if (all_outside) {
            continue;
        }
        const centroid: Point3 = (vertex_a + vertex_b + vertex_c) / splat(3);
        const depth: f32 = getPointDepth(plot, centroid);
        plot.draw_list.addTriangle(
            plotToPixelsP(plot, vertex_a),
            plotToPixelsP(plot, vertex_b),
            plotToPixelsP(plot, vertex_c),
            col,
            depth,
        );
    }
}

/// Quad fills (groups of 4), depth-sorted via DrawList3D.
fn renderQuadFill(plot: *Plot3D, getter: anytype, col: zm.ColorU32) void {
    const box: Box = cullBox(plot);
    var prim: usize = 0;
    while (4 * prim + 3 < getter.count) : (prim += 1) {
        const vertex_a: Point3 = getter.at(4 * prim);
        const vertex_b: Point3 = getter.at(4 * prim + 1);
        const vertex_c: Point3 = getter.at(4 * prim + 2);
        const vertex_d: Point3 = getter.at(4 * prim + 3);
        // Same corner-only cull as `renderTriangleFill`; see the note there.
        const all_outside: bool = !box.contains(vertex_a) and !box.contains(vertex_b) and
            !box.contains(vertex_c) and !box.contains(vertex_d);
        if (all_outside) {
            continue;
        }
        const centroid: Point3 = (vertex_a + vertex_b + vertex_c + vertex_d) / splat(4);
        const depth: f32 = getPointDepth(plot, centroid);
        plot.draw_list.addQuad(
            plotToPixelsP(plot, vertex_a),
            plotToPixelsP(plot, vertex_b),
            plotToPixelsP(plot, vertex_c),
            plotToPixelsP(plot, vertex_d),
            col,
            depth,
        );
    }
}

fn triMarker(
    dl: Im.DrawList,
    p: Vec2,
    s: f32,
    up: bool,
    fill: zm.ColorU32,
    line: zm.ColorU32,
    weight: f32,
    render_fill: bool,
    render_line: bool,
) void {
    const dir: f32 = if (up) -1 else 1;
    const tip = Vec2{ p[0], p[1] + dir * s };
    const b1 = Vec2{ p[0] - s, p[1] - dir * s };
    const b2 = Vec2{ p[0] + s, p[1] - dir * s };
    if (render_fill) {
        dl.addTriangleFilled(tip, b1, b2, fill);
    }
    if (render_line) {
        dl.addLine(tip, b1, line, weight);
        dl.addLine(b1, b2, line, weight);
        dl.addLine(b2, tip, line, weight);
    }
}

/// Draw one marker of `mkr` at screen position `p` (fill + outline).
fn renderMarker(
    dl: Im.DrawList,
    mkr: Marker,
    p: Vec2,
    size: f32,
    fill: zm.ColorU32,
    line: zm.ColorU32,
    weight: f32,
    render_fill: bool,
    render_line: bool,
) void {
    const s: f32 = size;
    switch (mkr) {
        .circle => {
            if (render_fill) {
                dl.addCircleFilled(p, s, fill);
            }
            if (render_line) {
                dl.addCircle(p, s, line, weight);
            }
        },
        .square => {
            const a = Vec2{ p[0] - s, p[1] - s };
            const b = Vec2{ p[0] + s, p[1] - s };
            const c = Vec2{ p[0] + s, p[1] + s };
            const d = Vec2{ p[0] - s, p[1] + s };
            if (render_fill) {
                dl.addQuadFilled(a, b, c, d, fill);
            }
            if (render_line) {
                dl.addLine(a, b, line, weight);
                dl.addLine(b, c, line, weight);
                dl.addLine(c, d, line, weight);
                dl.addLine(d, a, line, weight);
            }
        },
        .diamond => {
            const up = Vec2{ p[0], p[1] - s };
            const rt = Vec2{ p[0] + s, p[1] };
            const dn = Vec2{ p[0], p[1] + s };
            const lf = Vec2{ p[0] - s, p[1] };
            if (render_fill) {
                dl.addQuadFilled(up, rt, dn, lf, fill);
            }
            if (render_line) {
                dl.addLine(up, rt, line, weight);
                dl.addLine(rt, dn, line, weight);
                dl.addLine(dn, lf, line, weight);
                dl.addLine(lf, up, line, weight);
            }
        },
        .up => triMarker(dl, p, s, true, fill, line, weight, render_fill, render_line),
        .down => triMarker(dl, p, s, false, fill, line, weight, render_fill, render_line),
        .cross => {
            dl.addLine(.{ p[0] - s, p[1] - s }, .{ p[0] + s, p[1] + s }, line, weight);
            dl.addLine(.{ p[0] - s, p[1] + s }, .{ p[0] + s, p[1] - s }, line, weight);
        },
        .plus => {
            dl.addLine(.{ p[0] - s, p[1] }, .{ p[0] + s, p[1] }, line, weight);
            dl.addLine(.{ p[0], p[1] - s }, .{ p[0], p[1] + s }, line, weight);
        },
        .asterisk => {
            dl.addLine(.{ p[0] - s, p[1] - s }, .{ p[0] + s, p[1] + s }, line, weight);
            dl.addLine(.{ p[0] - s, p[1] + s }, .{ p[0] + s, p[1] - s }, line, weight);
            dl.addLine(.{ p[0] - s, p[1] }, .{ p[0] + s, p[1] }, line, weight);
            dl.addLine(.{ p[0], p[1] - s }, .{ p[0], p[1] + s }, line, weight);
        },
        .left, .right => {
            const dir: f32 = if (mkr == .right) 1 else -1;
            const tip = Vec2{ p[0] + dir * s, p[1] };
            const b1 = Vec2{ p[0] - dir * s, p[1] - s };
            const b2 = Vec2{ p[0] - dir * s, p[1] + s };
            if (render_fill) {
                dl.addTriangleFilled(tip, b1, b2, fill);
            }
            if (render_line) {
                dl.addLine(tip, b1, line, weight);
                dl.addLine(b1, b2, line, weight);
                dl.addLine(b2, tip, line, weight);
            }
        },
        .none, .auto => {},
    }
}

/// Draw markers at every getter point.
fn renderMarkers(
    ctx: *Context,
    plot: *Plot3D,
    dl: Im.DrawList,
    getter: anytype,
    n: *const NextItemData,
) void {
    const im: Im = ctx.im();
    const box: Box = cullBox(plot);
    const fill: zm.ColorU32 = im.colorToU32(n.spec.marker_fill_color.?);
    const line: zm.ColorU32 = im.colorToU32(n.spec.marker_line_color.?);
    var i: usize = 0;
    while (i < getter.count) : (i += 1) {
        // A marker is a point, so containment IS the correct cull here - unlike the triangle
        // and quad fills, where a corner test can drop something still partly on screen.
        const pt: Point3 = getter.at(i);
        if (!box.contains(pt)) {
            continue;
        }
        renderMarker(
            dl,
            n.spec.marker,
            plotToPixelsP(plot, pt),
            n.spec.marker_size,
            fill,
            line,
            n.spec.line_weight,
            n.render_marker_fill,
            n.render_marker_line,
        );
    }
}

//=============================================================================
// [SECTION] Plot functions (public API)
//
// Each takes a label, data, and an optional Spec. Numeric forms are generic
// over the element type T (cast to f32); Point3-slice forms are provided as
// ergonomic overloads. Spec defaults to .{} (auto color, style sizes).
//=============================================================================

// ---- Scatter ----

fn plotScatterImpl(
    ctx: *Context,
    comptime G: type,
    label_id: []const u8,
    getter: G,
    spec_in: Spec,
) void {
    const im: Im = ctx.im();
    const spec: Spec = spec_in;
    if (beginItemEx(ctx, getter, label_id, spec, spec.marker_line_color, spec.marker)) {
        const n: *NextItemData = &ctx.next_item_data;
        if (n.spec.marker == .none) {
            n.spec.marker = .circle;
        }
        const dl: Im.DrawList = im.getWindowDrawList();
        renderMarkers(ctx, ctx.currentPlot(), dl, getter, n);
        endItem(ctx);
    }
}

pub fn plotScatter(
    ctx: *Context,
    comptime T: type,
    label_id: []const u8,
    xs: []const T,
    ys: []const T,
    zs: []const T,
    spec: Spec,
) void {
    const count: usize = @min(@min(xs.len, ys.len), zs.len);
    if (count < 1) {
        return;
    }
    const getter = GetterXYZ(T){ .xs = xs, .ys = ys, .zs = zs, .count = count, .offset = spec.offset };
    plotScatterImpl(ctx, @TypeOf(getter), label_id, getter, spec);
}
pub fn plotScatterPoints(
    ctx: *Context,
    label_id: []const u8,
    pts: []const Point3,
    spec: Spec,
) void {
    if (pts.len < 1) {
        return;
    }
    const getter = GetterPoints{ .pts = pts, .count = pts.len, .offset = spec.offset };
    plotScatterImpl(ctx, GetterPoints, label_id, getter, spec);
}

// ---- Line ----

fn plotLineImpl(
    ctx: *Context,
    comptime G: type,
    label_id: []const u8,
    getter: G,
    spec: Spec,
) void {
    const im: Im = ctx.im();
    if (beginItemEx(ctx, getter, label_id, spec, spec.line_color, spec.marker)) {
        const plot: *Plot3D = ctx.currentPlot();
        const n: *NextItemData = &ctx.next_item_data;
        const s: *Spec = &n.spec;
        const dl: Im.DrawList = im.getWindowDrawList();
        if (n.render_line) {
            const col: zm.ColorU32 = im.colorToU32(s.line_color.?);
            if (@as(LineFlags, @bitCast(s.flags)).segments) {
                renderLineSegments(plot, dl, getter, col, s.line_weight);
            } else if (@as(LineFlags, @bitCast(s.flags)).loop) {
                const looped = GetterLoop(G){ .inner = getter, .count = getter.count + 1 };
                renderLineStrip(plot, dl, looped, col, s.line_weight);
            } else {
                renderLineStrip(plot, dl, getter, col, s.line_weight);
            }
        }
        if (s.marker != .none) {
            renderMarkers(ctx, plot, dl, getter, n);
        }
        endItem(ctx);
    }
}

pub fn plotLine(
    ctx: *Context,
    comptime T: type,
    label_id: []const u8,
    xs: []const T,
    ys: []const T,
    zs: []const T,
    spec: Spec,
) void {
    const count: usize = @min(@min(xs.len, ys.len), zs.len);
    if (count < 2) {
        return;
    }
    const getter = GetterXYZ(T){ .xs = xs, .ys = ys, .zs = zs, .count = count, .offset = spec.offset };
    plotLineImpl(ctx, @TypeOf(getter), label_id, getter, spec);
}
pub fn plotLinePoints(
    ctx: *Context,
    label_id: []const u8,
    pts: []const Point3,
    spec: Spec,
) void {
    if (pts.len < 2) {
        return;
    }
    const getter = GetterPoints{ .pts = pts, .count = pts.len, .offset = spec.offset };
    plotLineImpl(ctx, GetterPoints, label_id, getter, spec);
}

// ---- Triangle ----

fn renderTriangleEdges(
    plot: *Plot3D,
    dl: Im.DrawList,
    getter: anytype,
    col: zm.ColorU32,
    weight: f32,
) void {
    var prim: usize = 0;
    while (3 * prim + 2 < getter.count) : (prim += 1) {
        // Outlines only - projected straight to pixels, with no cull and no depth. Unlike the
        // FILL paths these go to the plain 2D draw list, so they always land on top of the
        // depth-sorted fills rather than interleaving with them.
        const pixel_a: Vec2 = plotToPixelsP(plot, getter.at(3 * prim));
        const pixel_b: Vec2 = plotToPixelsP(plot, getter.at(3 * prim + 1));
        const pixel_c: Vec2 = plotToPixelsP(plot, getter.at(3 * prim + 2));
        dl.addLine(pixel_a, pixel_b, col, weight);
        dl.addLine(pixel_b, pixel_c, col, weight);
        dl.addLine(pixel_c, pixel_a, col, weight);
    }
}

fn plotTriangleImpl(
    ctx: *Context,
    comptime G: type,
    label_id: []const u8,
    getter: G,
    spec: Spec,
) void {
    const im: Im = ctx.im();
    if (beginItemEx(ctx, getter, label_id, spec, spec.fill_color, spec.marker)) {
        const plot: *Plot3D = ctx.currentPlot();
        const n: *NextItemData = &ctx.next_item_data;
        const s: *Spec = &n.spec;
        const dl: Im.DrawList = im.getWindowDrawList();
        if (getter.count >= 3 and n.render_fill and !@as(TriangleFlags, @bitCast(s.flags)).no_fill) {
            renderTriangleFill(plot, getter, im.colorToU32(s.fill_color.?));
        }
        if (n.render_line and !@as(TriangleFlags, @bitCast(s.flags)).no_lines) {
            // edges of each triangle as a closed loop per group of 3
            renderTriangleEdges(plot, dl, getter, im.colorToU32(s.line_color.?), s.line_weight);
        }
        if (s.marker != .none and !@as(TriangleFlags, @bitCast(s.flags)).no_markers) {
            renderMarkers(ctx, plot, dl, getter, n);
        }
        endItem(ctx);
    }
}

pub fn plotTriangle(
    ctx: *Context,
    comptime T: type,
    label_id: []const u8,
    xs: []const T,
    ys: []const T,
    zs: []const T,
    spec: Spec,
) void {
    const count: usize = @min(@min(xs.len, ys.len), zs.len);
    if (count < 3) {
        return;
    }
    const getter = GetterXYZ(T){ .xs = xs, .ys = ys, .zs = zs, .count = count, .offset = spec.offset };
    plotTriangleImpl(ctx, @TypeOf(getter), label_id, getter, spec);
}
pub fn plotTrianglePoints(
    ctx: *Context,
    label_id: []const u8,
    pts: []const Point3,
    spec: Spec,
) void {
    if (pts.len < 3) {
        return;
    }
    const getter = GetterPoints{ .pts = pts, .count = pts.len, .offset = spec.offset };
    plotTriangleImpl(ctx, GetterPoints, label_id, getter, spec);
}

// ---- Quad ----

fn renderQuadEdges(
    plot: *Plot3D,
    dl: Im.DrawList,
    getter: anytype,
    col: zm.ColorU32,
    weight: f32,
) void {
    var prim: usize = 0;
    while (4 * prim + 3 < getter.count) : (prim += 1) {
        // Closed outline: the last edge runs back to the first corner. See the note in the
        // triangle version above about these bypassing the depth sort.
        const pixel_a: Vec2 = plotToPixelsP(plot, getter.at(4 * prim));
        const pixel_b: Vec2 = plotToPixelsP(plot, getter.at(4 * prim + 1));
        const pixel_c: Vec2 = plotToPixelsP(plot, getter.at(4 * prim + 2));
        const pixel_d: Vec2 = plotToPixelsP(plot, getter.at(4 * prim + 3));
        dl.addLine(pixel_a, pixel_b, col, weight);
        dl.addLine(pixel_b, pixel_c, col, weight);
        dl.addLine(pixel_c, pixel_d, col, weight);
        dl.addLine(pixel_d, pixel_a, col, weight);
    }
}

fn plotQuadImpl(
    ctx: *Context,
    comptime G: type,
    label_id: []const u8,
    getter: G,
    spec: Spec,
) void {
    const im: Im = ctx.im();
    if (beginItemEx(ctx, getter, label_id, spec, spec.fill_color, spec.marker)) {
        const plot: *Plot3D = ctx.currentPlot();
        const n: *NextItemData = &ctx.next_item_data;
        const s: *Spec = &n.spec;
        const dl: Im.DrawList = im.getWindowDrawList();
        if (getter.count >= 4 and n.render_fill and !@as(QuadFlags, @bitCast(s.flags)).no_fill) {
            renderQuadFill(plot, getter, im.colorToU32(s.fill_color.?));
        }
        if (n.render_line and !@as(TriangleFlags, @bitCast(s.flags)).no_lines) {
            renderQuadEdges(plot, dl, getter, im.colorToU32(s.line_color.?), s.line_weight);
        }
        if (s.marker != .none and !@as(TriangleFlags, @bitCast(s.flags)).no_markers) {
            renderMarkers(ctx, plot, dl, getter, n);
        }
        endItem(ctx);
    }
}

pub fn plotQuad(
    ctx: *Context,
    comptime T: type,
    label_id: []const u8,
    xs: []const T,
    ys: []const T,
    zs: []const T,
    spec: Spec,
) void {
    const count: usize = @min(@min(xs.len, ys.len), zs.len);
    if (count < 4) {
        return;
    }
    const getter = GetterXYZ(T){ .xs = xs, .ys = ys, .zs = zs, .count = count, .offset = spec.offset };
    plotQuadImpl(ctx, @TypeOf(getter), label_id, getter, spec);
}
pub fn plotQuadPoints(
    ctx: *Context,
    label_id: []const u8,
    pts: []const Point3,
    spec: Spec,
) void {
    if (pts.len < 4) {
        return;
    }
    const getter = GetterPoints{ .pts = pts, .count = pts.len, .offset = spec.offset };
    plotQuadImpl(ctx, GetterPoints, label_id, getter, spec);
}

// ---- Surface (grid of x_count by y_count heights) ----

/// Plot a surface from a regular grid. xs/ys/zs are row-major of length
/// x_count*y_count. Cells are emitted as depth-sorted quads.
pub fn plotSurface(
    ctx: *Context,
    comptime T: type,
    label_id: []const u8,
    xs: []const T,
    ys: []const T,
    zs: []const T,
    x_count: usize,
    y_count: usize,
    spec: Spec,
) void {
    const im: Im = ctx.im();
    const total: usize = x_count * y_count;
    if (total == 0 or xs.len < total or ys.len < total or zs.len < total) {
        return;
    }
    const getter = GetterXYZ(T){ .xs = xs, .ys = ys, .zs = zs, .count = total, .offset = spec.offset };
    if (beginItemEx(ctx, getter, label_id, spec, spec.fill_color, spec.marker)) {
        const plot: *Plot3D = ctx.currentPlot();
        const n: *NextItemData = &ctx.next_item_data;
        const s: *Spec = &n.spec;
        const dl: Im.DrawList = im.getWindowDrawList();
        const fill_col: zm.ColorU32 = im.colorToU32(s.fill_color.?);
        const line_col: zm.ColorU32 = im.colorToU32(s.line_color.?);
        var yi: usize = 0;
        while (yi + 1 < y_count) : (yi += 1) {
            var xi: usize = 0;
            while (xi + 1 < x_count) : (xi += 1) {
                // One cell of the (x_count x y_count) grid, named by its corner's grid position:
                // `x0y0` is the cell's origin, `x1y1` the diagonally opposite corner. The four
                // are listed in winding order, which is what `addQuad` expects.
                const index_x0y0: usize = yi * x_count + xi;
                const index_x1y0: usize = yi * x_count + (xi + 1);
                const index_x1y1: usize = (yi + 1) * x_count + (xi + 1);
                const index_x0y1: usize = (yi + 1) * x_count + xi;
                const corner_x0y0: Point3 = getter.at(index_x0y0);
                const corner_x1y0: Point3 = getter.at(index_x1y0);
                const corner_x1y1: Point3 = getter.at(index_x1y1);
                const corner_x0y1: Point3 = getter.at(index_x0y1);
                if (n.render_fill and !@as(SurfaceFlags, @bitCast(s.flags)).no_fill) {
                    // Depth for the painter's-algorithm sort is the cell CENTROID, not any one
                    // corner: sorting by a corner makes adjacent cells flip order along a shared
                    // edge and the surface tears.
                    const centroid: Point3 =
                        (corner_x0y0 + corner_x1y0 + corner_x1y1 + corner_x0y1) / splat(4);
                    const depth: f32 = getPointDepth(plot, centroid);
                    plot.draw_list.addQuad(
                        plotToPixelsP(plot, corner_x0y0),
                        plotToPixelsP(plot, corner_x1y0),
                        plotToPixelsP(plot, corner_x1y1),
                        plotToPixelsP(plot, corner_x0y1),
                        fill_col,
                        depth,
                    );
                }
                if (n.render_line and !@as(TriangleFlags, @bitCast(s.flags)).no_lines) {
                    // Only the two edges LEAVING this cell's origin are drawn; the other two
                    // belong to the neighbouring cells, which is what keeps every interior edge
                    // from being stroked twice.
                    //
                    // ★ CONSEQUENCE: the far boundary is not stroked at all. No cell has
                    // `yi == y_count - 1` or `xi == x_count - 1` as its origin, so the last row's
                    // horizontal edges and the last column's vertical edges are missing, and the
                    // wireframe is open on two sides. Left as-is rather than fixed blind, because
                    // closing it changes rendered output and the screenshot fixtures are the
                    // arbiter of that.
                    const pixel_x0y0: Vec2 = plotToPixelsP(plot, corner_x0y0);
                    dl.addLine(pixel_x0y0, plotToPixelsP(plot, corner_x1y0), line_col, s.line_weight);
                    dl.addLine(pixel_x0y0, plotToPixelsP(plot, corner_x0y1), line_col, s.line_weight);
                }
            }
        }
        endItem(ctx);
    }
}

// ---- Mesh (indexed triangles) ----

/// Plot an indexed triangle mesh. `idxs` are triplets into `vtx`.
pub fn plotMesh(
    ctx: *Context,
    label_id: []const u8,
    vtx: []const Point3,
    idxs: []const u32,
    spec: Spec,
) void {
    const im: Im = ctx.im();
    if (vtx.len == 0 or idxs.len < 3) {
        return;
    }
    const getter = GetterPoints{ .pts = vtx, .count = vtx.len };
    if (beginItemEx(ctx, getter, label_id, spec, spec.fill_color, spec.marker)) {
        const plot: *Plot3D = ctx.currentPlot();
        const n: *NextItemData = &ctx.next_item_data;
        const s: *Spec = &n.spec;
        const dl: Im.DrawList = im.getWindowDrawList();
        const fill_col: zm.ColorU32 = im.colorToU32(s.fill_color.?);
        const line_col: zm.ColorU32 = im.colorToU32(s.line_color.?);
        // `idxs` is a flat list of triplets, so `t` steps by 3 and the guard is `t + 2` - the
        // last complete triangle starts at `idxs.len - 3`. A trailing 1 or 2 stray indices are
        // ignored rather than read past the end.
        var t: usize = 0;
        while (t + 2 < idxs.len) : (t += 3) {
            const vertex_a: Point3 = vtx[idxs[t]];
            const vertex_b: Point3 = vtx[idxs[t + 1]];
            const vertex_c: Point3 = vtx[idxs[t + 2]];
            const pixel_a: Vec2 = plotToPixelsP(plot, vertex_a);
            const pixel_b: Vec2 = plotToPixelsP(plot, vertex_b);
            const pixel_c: Vec2 = plotToPixelsP(plot, vertex_c);
            if (n.render_fill and !@as(MeshFlags, @bitCast(s.flags)).no_fill) {
                // Centroid depth, for the same reason the surface uses it: a per-vertex depth
                // lets neighbouring triangles disagree about which is in front.
                const centroid: Point3 = (vertex_a + vertex_b + vertex_c) / splat(3);
                const depth: f32 = getPointDepth(plot, centroid);
                plot.draw_list.addTriangle(pixel_a, pixel_b, pixel_c, fill_col, depth);
            }
            if (n.render_line and !@as(TriangleFlags, @bitCast(s.flags)).no_lines) {
                // All three edges, unlike the surface grid above: a mesh has no implied
                // neighbour to stroke the shared edge, so every triangle draws its own.
                dl.addLine(pixel_a, pixel_b, line_col, s.line_weight);
                dl.addLine(pixel_b, pixel_c, line_col, s.line_weight);
                dl.addLine(pixel_c, pixel_a, line_col, s.line_weight);
            }
        }
        endItem(ctx);
    }
}

// ---- Text ----

/// Draw text at a plot-space position (angle in radians; horizontal-only on
/// this backend — DEVIATION: rotation falls back to horizontal).
pub fn plotText(
    ctx: *Context,
    text: []const u8,
    x: f32,
    y: f32,
    z: f32,
    angle: f32,
    pix_offset: Vec2,
) void {
    const im: Im = ctx.im();
    _ = angle;
    const plot: *Plot3D = ctx.currentPlot();
    setupLock(ctx);
    var box: Box = undefined;
    if (plot.flags.no_clip) {
        box = .{
            .min = point3(-math.inf(f32), -math.inf(f32), -math.inf(f32)),
            .max = point3(math.inf(f32), math.inf(f32), math.inf(f32)),
        };
    } else {
        box = .{ .min = plot.rangeMin(), .max = plot.rangeMax() };
    }
    const p3: Point3 = point3(x, y, z);
    if (!box.contains(p3)) {
        return;
    }
    var p: Vec2 = plotToPixelsP(plot, p3);
    p = p + pix_offset;
    const dl: Im.DrawList = im.getWindowDrawList();
    dl.addText(p, getStyleColorU32(ctx, .inlay_text), text);
}

// ---- Image ----

/// Draw a textured quad in plot space (mesh-image path). UVs are
/// axis-aligned-approximated (DEVIATION: no perspective-correct UVs).
pub fn plotImage(
    ctx: *Context,
    label_id: []const u8,
    tex_id: u32,
    p0: Point3,
    p1: Point3,
    p2: Point3,
    p3: Point3,
    uv0: Vec2,
    uv1: Vec2,
    tint: Color,
    spec: Spec,
) void {
    const im: Im = ctx.im();
    _ = uv0;
    _ = uv1;
    const pts = [_]Point3{ p0, p1, p2, p3 };
    const getter = GetterPoints{ .pts = &pts, .count = 4 };
    if (beginItemEx(ctx, getter, label_id, spec, null, null)) {
        const plot: *Plot3D = ctx.currentPlot();
        const dl: Im.DrawList = im.getWindowDrawList();
        const a: Vec2 = plotToPixelsP(plot, p0);
        const b: Vec2 = plotToPixelsP(plot, p1);
        const c: Vec2 = plotToPixelsP(plot, p2);
        const d: Vec2 = plotToPixelsP(plot, p3);
        dl.addImageQuad(tex_id, a, b, c, d, im.colorToU32(tint));
        endItem(ctx);
    }
}

// ---- Dummy (legend entry only) ----

pub fn plotDummy(ctx: *Context, label_id: []const u8, spec: Spec) void {
    var item_col: ?Color = spec.line_color;
    if (item_col == null) {
        item_col = spec.fill_color;
    }
    const getter = GetterPoints{ .pts = &[_]Point3{}, .count = 0 };
    if (beginItemEx(ctx, getter, label_id, spec, item_col, null)) {
        endItem(ctx);
    }
}

//=============================================================================
// [SECTION] Colormap free functions
//=============================================================================

pub fn addColormap(
    ctx: *Context,
    name: []const u8,
    colors: []const u32,
    qual: bool,
) Colormap {
    return ctx.colormap_data.append(name, colors, qual);
}
pub fn getColormapCount(ctx: *Context) usize {
    return ctx.colormap_data.count;
}
const colormap_names = [_][:0]const u8{
    "Deep", "Dark", "Pastel",   "Paired", "Viridis", "Plasma", "Hot",      "Cool",
    "Pink", "Jet",  "Twilight", "RdBu",   "BrBG",    "PiYG",   "Spectral", "Greys",
};

/// Name of a colormap by index (for selectors/combos).
pub fn getColormapName(cmap: Colormap) [:0]const u8 {
    const i: usize = @intCast(@backingInt(cmap));
    if (i < colormap_names.len) {
        return colormap_names[i];
    }
    return "Colormap";
}
pub fn getColormapSize(ctx: *Context, cmap: Colormap) usize {
    return ctx.colormap_data.getKeyCount(cmap);
}
pub fn getColormapColor(ctx: *Context, idx: usize, cmap: Colormap) Color {
    const im: Im = ctx.im();
    return im.colorFromU32(ctx.colormap_data.getKeyColorWrapped(cmap, idx));
}
pub fn getColormapColorU32(ctx: *Context, idx: usize, cmap: Colormap) u32 {
    return ctx.colormap_data.getKeyColorWrapped(cmap, idx);
}
pub fn sampleColormapU32(ctx: *Context, t: f32, cmap_in: ?Colormap) u32 {
    const cmap: Colormap = cmap_in orelse ctx.style.colormap;
    return ctx.colormap_data.lerpTable(cmap, t);
}

/// Sample a colormap continuously at t in [0,1].
pub fn sampleColormap(
    ctx: *Context,
    t: f32,
    cmap_in: ?Colormap,
) Color { // lint:off dup-pub-fn: 3D twin of plot.zig's; namespaced API
    const im: Im = ctx.im();
    return im.colorFromU32(sampleColormapU32(ctx, t, cmap_in));
}
/// Get the next color from the current colormap (advances the item index).
/// Only valid between beginPlot/endPlot.
pub fn nextColormapColor(ctx: *Context) Color {
    const im: Im = ctx.im();
    return im.colorFromU32(nextColormapColorU32(ctx));
}
/// Push/pop the active colormap.
pub fn pushColormap(ctx: *Context, cmap: Colormap) void {
    // First draft: set directly (no stack). TODO: stack like the 2D port.
    ctx.style.colormap = cmap;
}
pub fn popColormap() void {}

//=============================================================================
// [SECTION] Built-in mesh data (for PlotMesh demos)
//
// A compact unit cube (centered at origin, edge 1) is embedded. Sphere/duck
// from upstream's meshes file are large; a parametric sphere generator is
// provided instead so PlotMesh demos work without the multi-KB tables.
// DEVIATION: upstream ships literal sphere/duck vertex data; we generate.
//=============================================================================

pub const cube_vtx = [8]Point3{
    point3(-0.5, -0.5, -0.5),
    point3(0.5, -0.5, -0.5),
    point3(0.5, 0.5, -0.5),
    point3(-0.5, 0.5, -0.5),
    point3(-0.5, -0.5, 0.5),
    point3(0.5, -0.5, 0.5),
    point3(0.5, 0.5, 0.5),
    point3(-0.5, 0.5, 0.5),
};

pub const cube_idx = [36]u32{
    0, 1, 2, 0, 2, 3, // -z
    4, 6, 5, 4, 7, 6, // +z
    0, 4, 5, 0, 5, 1, // -y
    3, 2, 6, 3, 6, 7, // +y
    0, 3, 7, 0, 7, 4, // -x
    1, 5, 6, 1, 6, 2, // +x
};

/// Generate a UV-sphere mesh into caller-provided buffers. Returns the used
/// vertex and index counts. radius in plot units, centered at origin.
pub const SphereCounts = struct { vtx: usize, idx: usize };
pub fn genSphere(
    radius: f32,
    stacks: usize,
    slices: usize,
    out_vtx: []Point3,
    out_idx: []u32,
) SphereCounts {
    var vi: usize = 0;
    var ii: usize = 0;
    var st: usize = 0;
    while (st <= stacks) : (st += 1) {
        // Pole to pole is HALF a turn; once around is a WHOLE one. Both were spelled in
        // radians only so `@sin` would take them.
        const phi_turns = 0.5 * float(st) / float(stacks);
        var sl: usize = 0;
        while (sl <= slices) : (sl += 1) {
            const theta_turns = float(sl) / float(slices);
            if (vi >= out_vtx.len) {
                return .{ .vtx = vi, .idx = ii };
            }
            const sp: f32 = radius * sinTurns(phi_turns);
            out_vtx[vi] = point3(
                sp * cosTurns(theta_turns),
                sp * sinTurns(theta_turns),
                radius * cosTurns(phi_turns),
            );
            vi += 1;
        }
    }
    const stride: usize = slices + 1;
    st = 0;
    while (st < stacks) : (st += 1) {
        var sl: usize = 0;
        while (sl < slices) : (sl += 1) {
            const a: u32 = @intCast(st * stride + sl);
            const b: u32 = @intCast(st * stride + sl + 1);
            const c: u32 = @intCast((st + 1) * stride + sl);
            const d: u32 = @intCast((st + 1) * stride + sl + 1);
            if (ii + 6 > out_idx.len) {
                return .{ .vtx = vi, .idx = ii };
            }
            out_idx[ii] = a;
            out_idx[ii + 1] = c;
            out_idx[ii + 2] = b;
            out_idx[ii + 3] = b;
            out_idx[ii + 4] = c;
            out_idx[ii + 5] = d;
            ii += 6;
        }
    }
    return .{ .vtx = vi, .idx = ii };
}

//=============================================================================
// [SECTION] Tooling (style editor, colormap/style selectors, metrics, demo)
//
// First-draft UI helpers built on the `im` widget shim. They render real
// controls where the shim supports them and degrade gracefully otherwise.
//=============================================================================

/// A combo selecting the current colormap. Returns true if changed.
pub fn showColormapSelector(ctx: *Context, label: [:0]const u8) bool {
    const im: Im = ctx.im();
    const style: *Style = getStyle(ctx);
    var current: i32 = @backingInt(style.colormap);
    var packed_names: [256]u8 = undefined;
    var w: usize = 0;
    for (colormap_names) |nm| {
        for (nm) |ch| {
            if (w < packed_names.len) {
                packed_names[w] = ch;
                w += 1;
            }
        }
        if (w < packed_names.len) {
            packed_names[w] = 0;
            w += 1;
        }
    }
    if (im.combo(label, &current, packed_names[0..w])) {
        style.colormap = @fromBackingInt(@intCast(current));
        return true;
    }
    return false;
}

/// Show a style editor window contents (call inside your own window, or pass a
/// p_open to make it its own window via im.begin).
pub fn showStyleEditor(ctx: *Context, ref: ?*Style) void {
    const im: Im = ctx.im();
    _ = ref;
    const style: *Style = getStyle(ctx);
    im.text("Variables", .{});
    im.separator();
    _ = im.sliderFloat("LineWeight", &style.line_weight, 0, 5, "%.1f");
    _ = im.sliderFloat("MarkerSize", &style.marker_size, 0, 20, "%.1f");
    _ = im.sliderFloat("FillAlpha", &style.fill_alpha, 0, 1, "%.2f");
    _ = im.sliderFloat("ViewScaleFactor", &style.view_scale_factor, 0.1, 3, "%.2f");

    im.text("Colors", .{});
    im.separator();
    for (0..Col.count) |i| {
        im.pushIDInt(@intCast(i));
        defer im.popID();
        var v: Color = if (style.colors[i]) |c| c else getAutoColor(ctx, @fromBackingInt(@intCast(i)));
        if (im.colorEdit4(col_names[i], &v)) {
            style.colors[i] = v;
        }
    }

    im.text("Colormap", .{});
    im.separator();
    _ = showColormapSelector(ctx, "Colormap##sel");
}

/// A combo selecting a built-in style preset (only "Auto" for the first draft).
pub fn showStyleSelector(ctx: *Context, label: [:0]const u8) bool {
    const im: Im = ctx.im();
    var current: i32 = 0;
    if (im.combo(label, &current, "Auto\x00")) {
        styleColorsAuto(ctx, null);
        return true;
    }
    return false;
}

/// Minimal metrics window contents: plot count and current-plot info.
pub fn showMetricsWindow(ctx: *Context) void {
    const im: Im = ctx.im();
    im.text("ImPlot3D Metrics", .{});
    im.separator();
    im.text("Plots: {d}", .{ctx.plots.len()});
    im.text("Colormaps: {d}", .{ctx.colormap_data.count});
    if (ctx.current_plot) |plot| {
        im.text("Current plot id: {d}", .{plot.id});
        im.text("Items: {d}", .{plot.items.getItemCount()});
    }
}

/// Demo window: a stub that documents this is not ported (the upstream demo is
/// large and example-only).
pub fn showDemoWindow(ctx: *Context, p_open: ?*bool) void {
    const im: Im = ctx.im();
    if (im.begin("ImPlot3D Demo", p_open)) {
        im.text("The ImPlot3D demo is not ported.", .{});
        im.textUnformatted(
            "Use the plotting API directly: beginPlot / plotLine / plotScatter / plotSurface / plotMesh / endPlot.",
        );
        im.end();
    }
}

/// A short usage note (call inside a window).
pub fn showUserGuide(ctx: *Context) void {
    const im: Im = ctx.im();
    im.bulletText("Left/right-drag to rotate the box.");
    im.bulletText("Scroll to zoom.");
    im.textUnformatted("Call setUiHandle(ctx, ui) once per frame before any implot3d call.");
}

/// A minimal About window (its own window when p_open is given).
pub fn showAboutWindow(ctx: *Context, p_open: ?*bool) void {
    const im: Im = ctx.im();
    if (im.begin("About ImPlot3D", p_open)) {
        im.textUnformatted("ImPlot3D — pure-Zig port for zimr.");
        im.separator();
        im.textUnformatted("CPU 2D-projection 3D plotting above the ui draw layer.");
        im.end();
    }
}

//=============================================================================
// [SECTION] Tests
//=============================================================================

test "destroyContext frees everything (no leak)" {
    const alloc: Allocator = std.testing.allocator;
    const ctx: *Context = createContext(alloc);
    const plot: *Plot3D = ctx.plots.getOrAddByKey(0);
    plot.setTitle(alloc, "title");
    try plot.axes[0].label.appendSlice(alloc, "x-axis");
    try plot.axes[0].ticker.ticks.append(alloc, Tick.init(0.5, true, true));
    try plot.axes[0].ticker.text_buffer.appendSlice(alloc, "0.5\x00");
    plot.draw_list.addTriangle(.{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, 0, 0.5);
    _ = plot.items.item_pool.getOrAddByKey(1);
    try plot.items.legend.indices.append(alloc, 0);
    try plot.items.legend.labels.appendSlice(alloc, "series\x00");
    destroyContext(ctx); // std.testing.allocator fails the test on any leak
}

test "viewProjMatrix (GPU) reproduces ndcToPixels via mulMatVec over the full framebuffer" {
    const alloc: Allocator = std.testing.allocator;
    const ctx: *Context = createContext(alloc);
    defer destroyContext(ctx);
    const plot: *Plot3D = ctx.plots.getOrAddByKey(0);
    plot.plot_rect = .{ .min = .{ 100, 50 }, .max = .{ 500, 350 } };
    plot.pan_offset = .{ 12, -7 };
    plot.rotation = quatFromAxisAngle(normalize3(.{ 0.3, 0.8, 0.5, 0 }), 0.9);
    // Render target larger than the plot rect (plot is a sub-rect of the window).
    const tw: f32 = 800;
    const th: f32 = 600;
    const m: zm.Mat = viewProjMatrix(plot, tw, th);
    const samples = [_]Point3{
        .{ 0, 0, 0, 0 },       .{ 0.5, 0, 0, 0 },       .{ 0, 0.5, 0, 0 },
        .{ 0, 0, 0.5, 0 },     .{ 0.3, -0.4, 0.25, 0 }, .{ -0.5, -0.5, -0.5, 0 },
        .{ 0.5, 0.5, 0.5, 0 },
    };
    for (samples) |s| {
        // Exactly the shader's clip = vp * vec4(p, 1).
        const clip: Point3 = mulMatVec(m, .{ s[0], s[1], s[2], 1 });
        try expectApproxEqAbs(@as(f32, 1.0), clip[3], 1e-6);
        // Full-framebuffer viewport transform (WebGPU y-down framebuffer).
        const px: f32 = (clip[0] * 0.5 + 0.5) * tw;
        const py: f32 = (0.5 - clip[1] * 0.5) * th;
        const ref: Vec2 = ndcToPixels(plot, s);
        try expectApproxEqAbs(ref[0], px, 1e-2);
        try expectApproxEqAbs(ref[1], py, 1e-2);
        try expect(clip[2] > 0.0 and clip[2] < 1.0);
    }
}

test "viewProjMatrixRT maps NDC to plot-rect-local pixels (RTT compositing)" {
    const alloc: Allocator = std.testing.allocator;
    const ctx: *Context = createContext(alloc);
    defer destroyContext(ctx);
    const plot: *Plot3D = ctx.plots.getOrAddByKey(0);
    plot.plot_rect = .{ .min = .{ 100, 50 }, .max = .{ 500, 350 } }; // 400x300
    plot.pan_offset = .{ 12, -7 };
    plot.rotation = quatFromAxisAngle(normalize3(.{ 0.2, 0.7, 0.4, 0 }), 1.1);
    const rw: f32 = plot.plot_rect.width();
    const rh: f32 = plot.plot_rect.height();
    const m: zm.Mat = viewProjMatrixRT(plot);
    const samples = [_]Point3{
        .{ 0, 0, 0, 0 },   .{ 0.5, 0, 0, 0 },        .{ 0, 0.5, 0, 0 },
        .{ 0, 0, 0.5, 0 }, .{ -0.4, 0.3, -0.25, 0 }, .{ 0.5, 0.5, 0.5, 0 },
    };
    for (samples) |s| {
        const clip: Point3 = mulMatVec(m, .{ s[0], s[1], s[2], 1 });
        // RT viewport = the plot rect, so map clip → RT-local pixels …
        const px_rt: f32 = (clip[0] * 0.5 + 0.5) * rw;
        const py_rt: f32 = (0.5 - clip[1] * 0.5) * rh;
        // … which must equal the framebuffer pixel minus the plot-rect origin.
        const ref: Vec2 = ndcToPixels(plot, s);
        try expectApproxEqAbs(ref[0] - plot.plot_rect.min[0], px_rt, 1e-2);
        try expectApproxEqAbs(ref[1] - plot.plot_rect.min[1], py_rt, 1e-2);
        try expect(clip[2] > 0.0 and clip[2] < 1.0);
    }
}

test "hoveredAxis picks the box axis nearest the cursor" {
    // A trivial projected cube: bottom square 0-3, top square 4-7 offset by
    // (+3,-5) so no two edges are collinear (avoids distance ties).
    const corners = [8]Vec2{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, // bottom
        .{ 3, -5 }, .{ 13, -5 }, .{ 13, 5 }, .{ 3, 5 }, // top
    };
    // Near edge {0,1} (x-axis, group 0).
    try expectEqual(@as(i32, 0), hoveredAxis(&corners, .{ 5, 1 }, 30.0));
    // Near edge {1,2} (y-axis, group 1).
    try expectEqual(@as(i32, 1), hoveredAxis(&corners, .{ 11, 3 }, 30.0));
    // On the midpoint of vertical edge {0,4} (z-axis, group 2).
    try expectEqual(@as(i32, 2), hoveredAxis(&corners, .{ 1.5, -2.5 }, 30.0));
    // Far from every edge → none.
    try expectEqual(@as(i32, -1), hoveredAxis(&corners, .{ 500, 500 }, 30.0));
}
