//! examples/julia_gallery.zig - four Julia sets in a 2x2 grid,
//! each with a different `c` constant, composited into a single
//! 1280x720 PNG.
//!
//! The Julia set is parametrized by a complex number `c`.  Tiny
//! changes to `c` produce wildly different shapes - dragons,
//! ferns, starfish, spirals.  This gallery shows four classic
//! choices side-by-side so the parametric beauty is visible at
//! a glance.
//!
//! Run:
//!
//!   zig build julia-gallery
//!
//! Output: julia_gallery.png in the working directory.

const std = @import("std");
const zm = @import("zm");
const float = zm.float;
const float64 = zm.float64;
const Allocator = std.mem.Allocator;
// GL-retirement P2: migrated off the GL `zimr` umbrella onto the native
// SW bundle (raster + raster_shader + codecs + math + the typed-pipeline pieces).
const sw = @import("sw_runtime");

const total_w: u32 = 1280;
const total_h: u32 = 720;
const cell_w: u32 = total_w / 2; // 640
const cell_h: u32 = total_h / 2; // 360
const max_iter: u32 = 256;

/// Four hand-picked Julia parameters, each producing a distinct,
/// visually striking shape.  Coordinates are the standard
/// (Re(c), Im(c)) used in textbooks; labels are descriptive
/// nicknames for the shapes they produce.
const JuliaCase = struct {
    cx: f32,
    cy: f32,
    label: []const u8,
    view_w: f32 = 3.4, // most look good at this zoom
};

const cases: [4]JuliaCase = .{
    .{ .cx = -0.7, .cy = 0.27015, .label = "dragon" },
    .{ .cx = -0.4, .cy = 0.6, .label = "fern" },
    .{ .cx = 0.285, .cy = 0.01, .label = "starfish" },
    .{ .cx = -0.7269, .cy = 0.1889, .label = "spiral" },
};

fn monotonicNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn juliaPixel(zx0: f32, zy0: f32, cx: f32, cy: f32, hue_offset: f32) [4]u8 {
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
        return .{ 0, 0, 0, 255 };
    }

    const mag2: f32 = zx2 + zy2;
    const log_mag: f32 = 0.5 * @log(mag2);
    const nu: f32 = float(iter) + 1.0 - @log2(log_mag);
    const t: f32 = nu * 0.04;

    // Each cell gets a slightly shifted palette so they're
    // visually distinguishable beyond just shape.
    const PI2: f32 = 6.28318530718;
    const r: f32 = 0.5 + 0.5 * @cos(PI2 * (t + hue_offset + 0.00));
    const g: f32 = 0.5 + 0.5 * @cos(PI2 * (t + hue_offset + 0.33));
    const b: f32 = 0.5 + 0.5 * @cos(PI2 * (t + hue_offset + 0.67));

    return .{
        @trunc(@max(0, @min(255, r * 255))),
        @trunc(@max(0, @min(255, g * 255))),
        @trunc(@max(0, @min(255, b * 255))),
        255,
    };
}

/// Render one Julia set into the rectangle (ox, oy)-(ox+cell_w, oy+cell_h)
/// of the big buffer.  Each cell is independent - the caller could
/// trivially parallelize across cells by spawning a thread per case.
fn renderCell(
    buf: []u8,
    ox: u32,
    oy: u32,
    case: JuliaCase,
    hue_offset: f32,
) void {
    const view_h: f32 = case.view_w * @as(f32, cell_h) / @as(f32, cell_w);
    var dy: u32 = 0;
    while (dy < cell_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < cell_w) : (dx += 1) {
            const u: f32 = (float(dx) + 0.5) / float(cell_w);
            const v: f32 = (float(dy) + 0.5) / float(cell_h);
            const zx0: f32 = (u - 0.5) * case.view_w;
            const zy0: f32 = (0.5 - v) * view_h;
            const rgba: [4]u8 = juliaPixel(zx0, zy0, case.cx, case.cy, hue_offset);
            const x: usize = ox + dx;
            const y: usize = oy + dy;
            const off: usize = (y * total_w + x) * 4;
            buf[off + 0] = rgba[0];
            buf[off + 1] = rgba[1];
            buf[off + 2] = rgba[2];
            buf[off + 3] = rgba[3];
        }
    }
}

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa: Allocator = gpa_impl.allocator();

    const pixels: u32 = total_w * total_h;
    const buf: []u8 = try gpa.alloc(u8, pixels * 4);
    defer gpa.free(buf);
    // Clear to dark background (visible if cells underdraw)
    @memset(buf, 0);

    const t0: i128 = monotonicNs();
    // 2x2 layout: TL=dragon, TR=fern, BL=starfish, BR=spiral.
    renderCell(buf, 0, 0, cases[0], 0.00);
    renderCell(buf, cell_w, 0, cases[1], 0.25);
    renderCell(buf, 0, cell_h, cases[2], 0.50);
    renderCell(buf, cell_w, cell_h, cases[3], 0.75);
    const t1: i128 = monotonicNs();
    const ms: f64 = float64(t1 - t0) / 1_000_000.0;

    // Draw a thin black divider between cells so they read as
    // four distinct images rather than one weird unified shape.
    const div_thickness: u32 = 2;
    {
        // Horizontal divider at y = cell_h
        var y: u32 = cell_h - div_thickness / 2;
        while (y < cell_h + (div_thickness + 1) / 2) : (y += 1) {
            var x: u32 = 0;
            while (x < total_w) : (x += 1) {
                const off: usize = (@as(usize, y) * total_w + x) * 4;
                buf[off + 0] = 0;
                buf[off + 1] = 0;
                buf[off + 2] = 0;
                buf[off + 3] = 255;
            }
        }
        // Vertical divider at x = cell_w
        y = 0;
        while (y < total_h) : (y += 1) {
            var x: u32 = cell_w - div_thickness / 2;
            while (x < cell_w + (div_thickness + 1) / 2) : (x += 1) {
                const off: usize = (@as(usize, y) * total_w + x) * 4;
                buf[off + 0] = 0;
                buf[off + 1] = 0;
                buf[off + 2] = 0;
                buf[off + 3] = 255;
            }
        }
    }

    const png_bytes: []u8 = try sw.codecs.png.encode(gpa, buf, total_w, total_h);
    defer gpa.free(png_bytes);

    const out_path: []const u8 = "julia_gallery.png";
    var io_threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    var f: std.Io.File = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, png_bytes);

    std.debug.print(
        \\julia_gallery — 4 Julia sets in a 2x2 grid
        \\
        \\Layout (each cell {d}x{d}):
        \\  TL: "{s}"  c = ({d:.4}, {d:.4}i)
        \\  TR: "{s}"  c = ({d:.4}, {d:.4}i)
        \\  BL: "{s}"  c = ({d:.4}, {d:.4}i)
        \\  BR: "{s}"  c = ({d:.4}, {d:.4}i)
        \\
        \\Total size:   {d}x{d}  Max iterations: {d}
        \\Render time:  {d:.2} ms  (all 4 cells, single-threaded)
        \\Throughput:   {d:.2} Mpx/s
        \\Output:       {s} ({d} bytes)
        \\
    , .{
        cell_w,                                        cell_h,
        cases[0].label,                                cases[0].cx,
        cases[0].cy,                                   cases[1].label,
        cases[1].cx,                                   cases[1].cy,
        cases[2].label,                                cases[2].cx,
        cases[2].cy,                                   cases[3].label,
        cases[3].cx,                                   cases[3].cy,
        total_w,                                       total_h,
        max_iter,                                      ms,
        float64(pixels) / (ms / 1000.0) / 1_000_000.0, out_path,
        png_bytes.len,
    });
}
