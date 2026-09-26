//! examples/comptime_julia.zig - the Julia set, computed at COMPILE
//! TIME and baked into the binary as a const.  Companion to
//! examples/comptime_mandelbrot.zig.
//!
//! Run:
//!
//!   zig build comptime-julia
//!
//! The Julia set is the Mandelbrot's twin: same iteration formula
//! (`z = z^2 + c`), but here `c` is a FIXED constant for the whole
//! image and `z_0` is the per-pixel coordinate.  In Mandelbrot, it's
//! the other way around - `c` is per-pixel and `z_0 = 0`.
//!
//! For each fixed `c`, the Julia set produces a different shape.
//! `c = -0.7 + 0.27015i` gives a classic dragon-like form; `c = 0.285
//! + 0.01i` gives a starfish.  This file's default is the dragon.
//!
//! Same compile-time pattern as the Mandelbrot: `@setEvalBranchQuota`
//! + comptime function call -> the entire image is a const byte array
//! in the binary's read-only data section.  Runtime does a printf.

const std = @import("std");
const zm = @import("zm");
const float = zm.float;

// ============================================================================
// SECTION 1 - the kernel
// ============================================================================

/// One Julia iteration starting from (zx0, zy0) with fixed (cx, cy).
/// Returns smooth escape value, or `null` for interior points.
fn juliaEscape(
    zx0: f32,
    zy0: f32,
    cx: f32,
    cy: f32,
    max_iter: u32,
) ?f32 {
    @setRuntimeSafety(false);
    const BAIL_R2: f32 = 256.0;
    var zx: f32 = zx0;
    var zy: f32 = zy0;
    var iter: u32 = 0;
    var zx2: f32 = 0;
    var zy2: f32 = 0;
    while (iter < max_iter) : (iter += 1) {
        zx2 = zx * zx;
        zy2 = zy * zy;
        if (zx2 + zy2 > BAIL_R2) {
            break;
        }
        const zxy_new: f32 = 2 * zx * zy + cy;
        const zx_new: f32 = zx2 - zy2 + cx;
        zx = zx_new;
        zy = zxy_new;
    }
    if (iter == max_iter) {
        return null;
    }
    const mag2: f32 = zx2 + zy2;
    const log_mag: f32 = 0.5 * @log(mag2);
    const nu: f32 = float(iter) + 1.0 - @log2(log_mag);
    return nu;
}

// ============================================================================
// SECTION 2 - comptime rendering
// ============================================================================

const palette: []const u8 = " .:-=+*#%@";

fn pickGlyph(escape: ?f32) u8 {
    if (escape) |nu| {
        const idx: usize = @floor(@mod(nu * 0.6, float(palette.len)));
        return palette[idx];
    }
    return '@'; // interior
}

fn renderAscii(
    comptime width: usize,
    comptime height: usize,
    comptime max_iter: u32,
    comptime view_w: f32,
    comptime view_h: f32,
    comptime cx: f32,
    comptime cy: f32,
) [height * (width + 1)]u8 {
    @setEvalBranchQuota(1_000_000_000);
    var buf: [height * (width + 1)]u8 = undefined;
    var out_idx: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const u: f32 = (float(x) + 0.5) / float(width);
            const v: f32 = (float(y) + 0.5) / float(height);
            // Julia: z_0 is the pixel coordinate, c is fixed.
            const zx0: f32 = (u - 0.5) * view_w;
            const zy0: f32 = (0.5 - v) * view_h;
            const escape: ?f32 = juliaEscape(zx0, zy0, cx, cy, max_iter);
            buf[out_idx] = pickGlyph(escape);
            out_idx += 1;
        }
        buf[out_idx] = '\n';
        out_idx += 1;
    }
    return buf;
}

// ============================================================================
// SECTION 3 - the comptime call site
// ============================================================================

const img_w: usize = 120;
const img_h: usize = 54;
const iter_cap: u32 = 192;

/// The Julia constant `c`.  Different values produce wildly
/// different shapes - try `(0.285, 0.01)` for a starfish,
/// `(-0.4, 0.6)` for a fern, `(-0.7269, 0.1889)` for a spiral
/// dragon.
const julia_c_x: f32 = -0.7;
const julia_c_y: f32 = 0.27015;

const image: [img_h * (img_w + 1)]u8 = renderAscii(
    img_w,
    img_h,
    iter_cap,
    3.4, // view_w
    3.0, // view_h (square-ish since Julia sets are usually balanced)
    julia_c_x,
    julia_c_y,
);

// ============================================================================
// SECTION 4 - runtime entry point
// ============================================================================

pub fn main() void {
    std.debug.print(
        \\zimr — comptime Julia set
        \\
        \\The image below was rendered ENTIRELY at compile time by the
        \\Zig compiler.  Same iteration as the Mandelbrot (z = z² + c)
        \\but here `c` is a fixed constant ({d:.4} + {d:.4}i) and z₀
        \\is the per-pixel coordinate.
        \\
        \\Runtime work: zero float operations.  This is a printf of a
        \\const string baked into the binary at compile time.
        \\
        \\Resolution: {d}x{d}  Max iterations: {d}
        \\
        \\
    , .{ julia_c_x, julia_c_y, img_w, img_h, iter_cap });

    std.debug.print("{s}", .{image});
}
