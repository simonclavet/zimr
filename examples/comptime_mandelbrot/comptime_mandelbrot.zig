//! comptime_mandelbrot — the Mandelbrot set computed ENTIRELY at COMPILE
//! TIME and baked into the binary as a `const` escape-value grid, then drawn on
//! the GPU. The graphical sibling of the CLI `comptime_mandelbrot` (which printed
//! ASCII): same comptime kernel, but the image is painted as colored cells.
//!
//! What it shows:
//!   - Zig comptime: the whole Mandelbrot iteration runs in the compiler; the
//!     escape grid lives in the read-only data section. Runtime does zero
//!     fractal math — just maps each baked escape value to a color and draws it.
//!   - The same `mandelbrotEscape` kernel also runs on the GPU
//!     (examples/mandelbrot_fs.zig -> SPIR-V -> WGSL) and natively — one source,
//!     four execution targets.
//!   - zm color math at runtime: `Color.fromHSV` (wasm-safe scalar path).
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;

// Grid + view. 4:3 grid matches the 3.2 x 2.4 complex-plane view so cells stay
// square. Sized for a comptime-budget-friendly build (~the CLI version's cost).
const grid_w: usize = 100;
const grid_h: usize = 75;
const iter_limit: u32 = 128;
const re_center: f32 = -0.7;
const im_center: f32 = 0.0;
const view_w: f32 = 3.2;
const view_h: f32 = 2.4;

/// The Mandelbrot iteration — pure function, callable at comptime OR runtime OR
/// on the GPU. Returns the smooth (continuous) escape value, or null for
/// interior points.
fn mandelbrotEscape(cx: f32, cy: f32, max_iter: u32) ?f32 {
    @setRuntimeSafety(false);
    const bail_r2: f32 = 256.0;
    var zx: f32 = 0;
    var zy: f32 = 0;
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
            const cx: f32 = re_center + (u - 0.5) * view_w;
            const cy: f32 = im_center + (0.5 - v) * view_h; // imaginary axis grows up
            grid[y * grid_w + x] = mandelbrotEscape(cx, cy, iter_limit);
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
    // .fit mode reports a fixed 800x600 logical size, so the grid maps 1:1.
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
            .title = "zimr - WebGPU - comptime Mandelbrot",
            .width = 800,
            .height = 600,
            .scale_mode = .fit, // keep the 4:3 fractal aspect, letterbox the rest
            .depth_format = null,
        },
    },
    .init = init,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
