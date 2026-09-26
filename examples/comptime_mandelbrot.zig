//! examples/comptime_mandelbrot.zig - the Mandelbrot set, computed
//! at COMPILE TIME, baked into the binary as a const, printed at
//! runtime.
//!
//! Run:
//!
//!   zig build comptime-mandelbrot
//!
//! What this proves:
//!
//!   The SAME Mandelbrot kernel from `examples/sw_mandelbrot.zig`
//!   runs in FOUR distinct execution environments:
//!
//!     1. WebGPU/WGSL - compiled via SPIR-V -> WGSL, runs in browser GPU
//!     2. WebGL2/GLSL - compiled via SPIR-V -> spirv-cross -> GLSL ES 3.0
//!     3. Native CPU - Zig ReleaseFast, per-pixel `shaderMain` calls
//!     4. **Compile-time Zig** - Mandelbrot evaluated by the Zig
//!        compiler itself, no runtime work, the image IS the binary
//!
//!   Mode #4 is the demo here.  The pixel data lives in the read-only
//!   data section of the executable.  At runtime, `main()` walks the
//!   const array and prints it.  No floats are computed at runtime;
//!   `@setEvalBranchQuota` lets the comptime branch see enough budget
//!   to finish.
//!
//!   This is the OS-version of "constexpr fractals" - but Zig comptime
//!   is way more general than C++ constexpr.  Anything Zig can do at
//!   runtime, Zig can do at compile time (modulo I/O and allocation
//!   constraints).  Including: floating-point iteration, conditional
//!   branches, log/cos, palette tables.

const std = @import("std");
const zm = @import("zm");
const float = zm.float;

// ============================================================================
// SECTION 1 - the kernel
// ============================================================================

/// The Mandelbrot iteration - pure function, no side effects.  Same
/// shape as `examples/sw_mandelbrot.zig`'s `MandelbrotFs.shaderMain`
/// but lifted out of the io/out wrapping so it can be called by
/// either runtime or comptime code.
///
/// Returns the smooth-iteration value (continuous escape time), or
/// `null` for interior points.  Caller maps this to a color.
fn mandelbrotEscape(
    cx: f32,
    cy: f32,
    max_iter: u32,
) ?f32 {
    @setRuntimeSafety(false);
    const BAIL_R2: f32 = 256.0;
    var zx: f32 = 0;
    var zy: f32 = 0;
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
    // Smooth escape value via Linas Vepstas' renormalization.
    const mag2: f32 = zx2 + zy2;
    const log_mag: f32 = 0.5 * @log(mag2);
    const nu: f32 = float(iter) + 1.0 - @log2(log_mag);
    return nu;
}

// ============================================================================
// SECTION 2 - comptime rendering
// ============================================================================

/// ASCII palette indexed by smooth escape value.  Order matters:
/// dense glyphs (`@`, `#`) for slow-escape pixels near the boundary;
/// sparse glyphs (`.`, ` `) for fast-escape pixels far from the set.
/// Interior pixels use the densest glyph as a visual anchor.
const palette: []const u8 = " .:-=+*#%@";

/// Map a smooth-iteration value to a palette index.  `null` (interior)
/// returns the densest palette character; non-null exterior values
/// cycle through the palette as `iter` grows.
fn pickGlyph(escape: ?f32) u8 {
    if (escape) |nu| {
        // The smooth escape value is unbounded above (deep interior
        // approaches max_iter); we wrap via modulo so the palette
        // cycles cleanly.
        const idx: usize = @floor(@mod(nu * 0.6, float(palette.len)));
        return palette[idx];
    }
    return '@'; // interior
}

/// Render the Mandelbrot set as an ASCII grid.  Pure function; the
/// caller can invoke this at comptime (`comptime renderAscii(...)`)
/// and have the whole image baked at compile time.
///
/// Returns a flat [img_w * (img_h + newlines)] byte array.  Each row is
/// terminated with `\n` so `std.debug.print("{s}", .{out})` prints
/// the image directly.
fn renderAscii(
    comptime width: usize,
    comptime height: usize,
    comptime max_iter: u32,
    comptime re_center: f32,
    comptime im_center: f32,
    comptime view_w: f32,
    comptime view_h: f32,
) [height * (width + 1)]u8 {
    // Each row contributes width chars + 1 newline.  img_h rows total.
    @setEvalBranchQuota(1_000_000_000);
    var buf: [height * (width + 1)]u8 = undefined;
    var out_idx: usize = 0;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            // Pixel centers at +0.5; map to [-0.5, +0.5] x view size.
            const u: f32 = (float(x) + 0.5) / float(width);
            const v: f32 = (float(y) + 0.5) / float(height);
            // Y flip: terminal Y grows down, imaginary axis grows up.
            const cx: f32 = re_center + (u - 0.5) * view_w;
            const cy: f32 = im_center + (0.5 - v) * view_h;
            const escape: ?f32 = mandelbrotEscape(cx, cy, max_iter);
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

/// The baked Mandelbrot.  This call site runs at COMPILE TIME - every
/// pixel of the iteration, the escape test, the smooth-iteration
/// formula, and the palette lookup is evaluated by the Zig compiler.
/// At runtime, this is a `const` byte array in the read-only data
/// section; no float math runs.
///
/// Resolution and max_iter are tuned for a comptime-budget-friendly
/// build (~15-40s compile depending on machine).  Push them up for
/// nicer images at the cost of compile time.
const img_w: usize = 120;
const img_h: usize = 54;
const iter_cap: u32 = 192;

const image: [img_h * (img_w + 1)]u8 = renderAscii(
    img_w,
    img_h,
    iter_cap,
    -0.7, // re_center: classic Mandelbrot view
    0.0, //  im_center
    3.2, //  view_w
    2.4, //  view_h
);

// ============================================================================
// SECTION 4 - runtime entry point (zero per-pixel work)
// ============================================================================

pub fn main() void {
    std.debug.print(
        \\zimr — comptime Mandelbrot
        \\
        \\The image below was rendered ENTIRELY at compile time.  Every
        \\pixel of the iteration, the smooth-escape formula, and the
        \\palette lookup ran in the Zig compiler.  Runtime work: zero
        \\float operations.  This is a printf of a const string.
        \\
        \\Same kernel runs natively (examples/sw_mandelbrot.zig) and on
        \\the GPU (examples/mandelbrot_fs.zig → SPIR-V → WGSL/GLSL).
        \\Four execution targets, one Zig source.
        \\
        \\Resolution: {d}x{d}  Max iterations: {d}
        \\
        \\
    , .{ img_w, img_h, iter_cap });

    std.debug.print("{s}", .{image});
}
