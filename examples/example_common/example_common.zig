//! lint:alias common
//! example_common - shared scaffold for the wgpu example set. A cohesive palette, one caption
//! style, a subtle backdrop, and viewport-relative layout helpers, so every example reads
//! as part of the same family instead of ad-hoc per file. Import as `@import("example_common")`.
const z = @import("zimr");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const float = zm.float;

pub const Color = zm.Color;

/// The shared dark palette. Examples theme themselves from these instead of raw literals.
pub const palette = struct {
    pub const bg: Color = .{ .r = 10, .g = 12, .b = 18, .a = 255 }; // page background
    pub const surface: Color = .{ .r = 20, .g = 24, .b = 34, .a = 255 }; // panels / cards
    pub const ink: Color = .{ .r = 214, .g = 219, .b = 230, .a = 255 }; // primary text
    pub const ink_dim: Color = .{ .r = 122, .g = 130, .b = 148, .a = 230 }; // secondary text
    pub const accent: Color = .{ .r = 90, .g = 200, .b = 230, .a = 255 }; // cyan
    pub const accent2: Color = .{ .r = 240, .g = 140, .b = 90, .a = 255 }; // warm
    pub const good: Color = .{ .r = 120, .g = 200, .b = 130, .a = 255 };
    pub const warn: Color = .{ .r = 235, .g = 180, .b = 90, .a = 255 };

    /// A point on a cohesive HSV ramp (consistent saturation/value across examples).
    pub fn ramp(deg: f32) Color {
        return z.colorFromHSV(@mod(deg, 360.0), 0.55, 0.98);
    }
};

/// The standard caption: top-left label, one consistent style for every example.
pub fn caption(
    gl: anytype,
    font: z.Font,
    text: []const u8,
) void {
    gl.text(.{ 14, 12 }, text, .{ .size = 14, .color = palette.ink, .font = &font });
}

/// Fill the viewport with a subtle vertical gradient + a faint grid so examples sit on a
/// considered surface, not flat black. Call right after clearBackground, before content.
pub fn backdrop(
    gl: anytype,
    w: f32,
    h: f32,
) void {
    const bands: usize = 22;
    var i: usize = 0;
    while (i < bands) : (i += 1) {
        const f0: f32 = float(i) / float(bands);
        const y: f32 = f0 * h;
        const bh: f32 = h / float(bands) + 1.0;
        const r: u8 = @trunc(9.0 + 8.0 * f0);
        const g: u8 = @trunc(11.0 + 9.0 * f0);
        const b: u8 = @trunc(17.0 + 13.0 * f0);
        gl.rect(.{ .x = 0, .y = y, .width = w, .height = bh }, .{ .color = .{ .r = r, .g = g, .b = b, .a = 255 } });
    }
    const step: f32 = 48.0;
    const grid: Color = .{ .r = 255, .g = 255, .b = 255, .a = 10 };
    var x: f32 = step;
    while (x < w) : (x += step) {
        gl.line(.{ x, 0 }, .{ x, h }, .{ .color = grid, .thickness = 1.0 });
    }
    var yy: f32 = step;
    while (yy < h) : (yy += step) {
        gl.line(.{ 0, yy }, .{ w, yy }, .{ .color = grid, .thickness = 1.0 });
    }
}

/// Center of the viewport.
pub fn center(w: f32, h: f32) Vec2 {
    return .{ w * 0.5, h * 0.5 };
}

/// A panic handler that says what happened, for examples to install in one line.
///
/// ---- WHY EVERY EXAMPLE SHOULD HAVE THIS ----
///
/// A Zig safety check in a wasm build traps as a bare `RuntimeError: unreachable`: no message,
/// no stack, no line. **Six turns of debugging in `drecon2.md` went to bisecting a panic that
/// named itself the moment a handler was installed** - an `@intCast` overflow in
/// `robot.addContactRows`, found in one build after days of elimination.
///
/// An example is the ROOT MODULE of its own wasm binary, so `pub const panic` in the example is
/// the handler Zig uses. That means this cannot live here as a declaration - each example needs
/// one line:
///
///     pub const panic = std.debug.FullPanic(common.reportPanic);
///
/// ** THE MESSAGE GOES TO THE BROWSER CONSOLE, not to the page. A panic has already happened,
/// and the drawing path is exactly what cannot be trusted to report it.
pub fn reportPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    z.web.dom.log(.err, msg);
    @trap();
}
