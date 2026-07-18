//! comptime_julia — the Julia set computed ENTIRELY at COMPILE TIME and
//! baked into the binary as a `const` escape-value grid, then drawn on the GPU.
//! The graphical sibling of the CLI `comptime_julia` (which printed ASCII): same
//! comptime kernel, but the image is painted as colored cells.
//!
//! What it shows:
//!   - Zig comptime: the whole Julia iteration runs in the compiler; the escape
//!     grid lives in the read-only data section. Runtime does zero fractal math
//!     — it just maps each baked escape value to a color and draws it.
//!   - Julia vs Mandelbrot: same z = z² + c iteration, but here z₀ is the pixel
//!     coordinate and `c` is a FIXED constant (the whole image is one orbit
//!     family). Try other `julia_c*` values for wildly different shapes.
//!   - zm color math at runtime: `Color.fromHSV` (wasm-safe scalar path).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;

// Grid + view. The view is ~square (Julia sets are usually balanced about the
// origin); the grid + window match its aspect so cells stay square.
const grid_w: usize = 100;
const grid_h: usize = 88;
const iter_limit: u32 = 128;
const view_w: f32 = 3.4;
const view_h: f32 = 3.0;

/// The Julia constant `c`. Different values produce wildly different shapes —
/// `(0.285, 0.01)` is a starfish, `(-0.4, 0.6)` a fern, `(-0.7269, 0.1889)` a
/// spiral dragon. `(-0.7, 0.27015)` is the classic swirl.
const julia_cx: f32 = -0.7;
const julia_cy: f32 = 0.27015;

/// The Julia iteration — pure function, callable at comptime OR runtime. `z`
/// starts at the pixel coordinate and `c` is fixed. Returns the smooth
/// (continuous) escape value, or null for interior points.
fn juliaEscape(
    zx0: f32,
    zy0: f32,
    cx: f32,
    cy: f32,
    max_iter: u32,
) ?f32 {
    @setRuntimeSafety(false);
    const bail_r2: f32 = 256.0;
    var zx: f32 = zx0;
    var zy: f32 = zy0;
    var zx2: f32 = 0;
    var zy2: f32 = 0;
    var iter: u32 = 0;
    while (iter < max_iter) : (iter += 1) {
        zx2 = zx * zx;
        zy2 = zy * zy;
        if (zx2 + zy2 > bail_r2) break;
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
    return float(iter) + 1.0 - @log2(log_mag);
}

/// The baked image. Computed at COMPILE TIME: every pixel's iteration runs in
/// the Zig compiler. `null` = interior. This `const` ships in the binary's
/// read-only data; no fractal math runs at runtime.
const escape_grid: [grid_h * grid_w]?f32 = blk: {
    @setEvalBranchQuota(2_000_000_000);
    var grid: [grid_h * grid_w]?f32 = undefined;
    var y: usize = 0;
    while (y < grid_h) : (y += 1) {
        var x: usize = 0;
        while (x < grid_w) : (x += 1) {
            const u: f32 = (float(x) + 0.5) / float(grid_w);
            const v: f32 = (float(y) + 0.5) / float(grid_h);
            // Julia: z₀ is the pixel coordinate, c is fixed.
            const zx0: f32 = (u - 0.5) * view_w;
            const zy0: f32 = (0.5 - v) * view_h; // imaginary axis grows up
            grid[y * grid_w + x] = juliaEscape(zx0, zy0, julia_cx, julia_cy, iter_limit);
        }
    }
    break :blk grid;
};

/// Map a baked escape value to a color: interior is black, exterior cycles hue
/// by escape time. Runs at runtime (cheap) via the wasm-safe `Color.fromHSV`.
fn shade(escape: ?f32) Color {
    if (escape) |nu| {
        return Color.fromHSV(.{ @mod(nu * 0.02, 1.0), 0.7, 0.95, 1.0 });
    }
    return Color.black;
}

const State = struct {};

fn init(gpa: Allocator, f: *z.Frame, s: *State) !void {
    _ = gpa;
    _ = f;
    s.* = .{};
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    _ = s;
}

fn update(f: *z.Frame, s: *State) void {
    _ = s;
    // .fit mode reports a fixed 800x704 logical size, so the grid maps 1:1.
    const cw: f32 = f.window.widthf() / float(grid_w);
    const ch: f32 = f.window.heightf() / float(grid_h);
    var y: usize = 0;
    while (y < grid_h) : (y += 1) {
        var x: usize = 0;
        while (x < grid_w) : (x += 1) {
            const cell: z.Rectangle = .{
                .x = float(x) * cw,
                .y = float(y) * ch,
                .width = cw + 1.0, // +1 to avoid seams between cells
                .height = ch + 1.0,
            };
            f.gl.rect(cell, .{ .color = shade(escape_grid[y * grid_w + x]) });
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - comptime Julia",
            .width = 800,
            .height = 704,
            .scale_mode = .fit, // keep the fractal aspect, letterbox the rest
            .depth_format = null,
        },
    },
    .init = init,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
