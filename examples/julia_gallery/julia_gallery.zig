//! julia_gallery — four classic Julia sets in a 2×2 grid, each computed
//! ENTIRELY at COMPILE TIME and baked into the binary, then drawn on the GPU.
//! The graphical sibling of the CLI `julia_gallery` (which wrote a PNG).
//!
//! Same z = z² + c kernel as comptime_julia, but the image is split into
//! four cells, each with its own Julia constant `c` and hue — dragon, fern,
//! starfish, spiral. The whole 2×2 escape grid lives in read-only data; runtime
//! does zero fractal math, just maps baked escape values to colors.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const Color = zm.Color;

const Case = struct {
    cx: f32,
    cy: f32,
    hue: f32,
};

// The four classic constants, laid out row-major in the 2×2 grid.
const cases = [_]Case{
    .{ .cx = -0.7, .cy = 0.27015, .hue = 0.00 }, // dragon  (top-left)
    .{ .cx = -0.4, .cy = 0.6, .hue = 0.25 }, // fern    (top-right)
    .{ .cx = 0.285, .cy = 0.01, .hue = 0.50 }, // starfish (bottom-left)
    .{ .cx = -0.7269, .cy = 0.1889, .hue = 0.66 }, // spiral  (bottom-right)
};

// 2×2 of 50×44 cells = 100×88 total — same comptime budget as comptime_julia.
const cols: usize = 2;
const rows: usize = 2;
const cell_w: usize = 50;
const cell_h: usize = 44;
const grid_w: usize = cell_w * cols;
const grid_h: usize = cell_h * rows;
const iter_limit: u32 = 128;
const view_w: f32 = 3.4;
const view_h: f32 = view_w * float(cell_h) / float(cell_w);

/// The Julia iteration — `z` starts at the pixel coordinate, `c` is fixed per
/// cell. Smooth (continuous) escape value, or null for interior points.
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

/// Which cell a grid pixel belongs to (row-major index into `cases`).
fn cellIndex(x: usize, y: usize) usize {
    return (y / cell_h) * cols + (x / cell_w);
}

/// The baked image. Every pixel's iteration runs in the Zig compiler; each cell
/// uses its own `c`. `null` = interior.
const escape_grid: [grid_h * grid_w]?f32 = blk: {
    @setEvalBranchQuota(2_000_000_000);
    var grid: [grid_h * grid_w]?f32 = undefined;
    var y: usize = 0;
    while (y < grid_h) : (y += 1) {
        var x: usize = 0;
        while (x < grid_w) : (x += 1) {
            const cs: Case = cases[cellIndex(x, y)];
            const lx: usize = x % cell_w;
            const ly: usize = y % cell_h;
            const u: f32 = (float(lx) + 0.5) / float(cell_w);
            const v: f32 = (float(ly) + 0.5) / float(cell_h);
            const zx0: f32 = (u - 0.5) * view_w;
            const zy0: f32 = (0.5 - v) * view_h;
            grid[y * grid_w + x] = juliaEscape(zx0, zy0, cs.cx, cs.cy, iter_limit);
        }
    }
    break :blk grid;
};

/// Map a baked escape value to a color: interior black, exterior cycles hue by
/// escape time, shifted by the cell's base hue so each set reads distinctly.
fn shade(escape: ?f32, hue: f32) Color {
    if (escape) |nu| {
        return Color.fromHSV(.{ @mod(nu * 0.02 + hue, 1.0), 0.7, 0.95, 1.0 });
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
    const cw: f32 = f.window.widthf() / float(grid_w);
    const ch: f32 = f.window.heightf() / float(grid_h);
    var y: usize = 0;
    while (y < grid_h) : (y += 1) {
        var x: usize = 0;
        while (x < grid_w) : (x += 1) {
            const hue: f32 = cases[cellIndex(x, y)].hue;
            const cell: z.Rectangle = .{
                .x = float(x) * cw,
                .y = float(y) * ch,
                .width = cw + 1.0,
                .height = ch + 1.0,
            };
            f.gl.rect(cell, .{ .color = shade(escape_grid[y * grid_w + x], hue) });
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - Julia gallery",
            .width = 800,
            .height = 704,
            .scale_mode = .fit,
            .depth_format = null,
        },
    },
    .init = init,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
