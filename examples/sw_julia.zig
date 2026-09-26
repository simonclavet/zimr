//! examples/sw_julia.zig - native CPU Julia set, writes a colored PNG.
//!
//! Direct per-pixel compute, no rasterizer.  The same kernel pattern
//! as the Mandelbrot but `c` is a fixed constant and z_0 is per-pixel.
//! Produces a colored 1280x720 PNG using the same smooth-escape +
//! cosine palette as sw_mandelbrot.
//!
//! Run:
//!
//!   zig build sw-julia
//!
//! Output: julia.png in the working directory.
//!
//! Companion to sw_mandelbrot (native CPU, rasterized) and
//! comptime_julia (ASCII at compile time).  This one is the
//! "direct compute, colored image" point in the design space.

const std = @import("std");
const Allocator = std.mem.Allocator;
// GL-retirement P2: migrated off the GL `zimr` umbrella onto the native
// SW bundle (raster + raster_shader + codecs + math + the typed-pipeline pieces).
const sw = @import("sw_runtime");
const zm = @import("zm");
const float64 = zm.float64;
const float = zm.float;
const inf = zm.inf;

const width: u32 = 1280;
const height: u32 = 720;
const max_iter: u32 = 256;

// Julia constant - the classic dragon shape.
const c_x: f32 = -0.7;
const c_y: f32 = 0.27015;

// View window in the complex plane.  Julia sets are usually centered
// at the origin and symmetric, so a roughly square window works well.
const re_center: f32 = 0.0;
const im_center: f32 = 0.0;
const view_w: f32 = 3.4;
const view_h: f32 = view_w * @as(f32, height) / @as(f32, width);

fn monotonicNs() i128 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}

fn juliaPixel(zx0: f32, zy0: f32) [4]u8 {
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
        const zxy_new: f32 = 2 * zx * zy + c_y;
        const zx_new: f32 = zx2 - zy2 + c_x;
        zx = zx_new;
        zy = zxy_new;
    }
    if (iter == max_iter) {
        return .{ 0, 0, 0, 255 };
    }

    // Smooth-escape palette (same shape as sw_mandelbrot).
    const mag2: f32 = zx2 + zy2;
    const log_mag: f32 = 0.5 * @log(mag2);
    const nu: f32 = float(iter) + 1.0 - @log2(log_mag);
    const t: f32 = nu * 0.04; // palette period - tweak by eye

    const PI2: f32 = 6.28318530718;
    // Three-channel cosine palette, phase-shifted.  Different phase
    // offsets than sw_mandelbrot to give Julia its own visual identity.
    const r: f32 = 0.5 + 0.5 * @cos(PI2 * (t + 0.00));
    const g: f32 = 0.5 + 0.5 * @cos(PI2 * (t + 0.33));
    const b: f32 = 0.5 + 0.5 * @cos(PI2 * (t + 0.67));

    return .{
        @trunc(@max(0, @min(255, r * 255))),
        @trunc(@max(0, @min(255, g * 255))),
        @trunc(@max(0, @min(255, b * 255))),
        255,
    };
}

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa_impl.deinit();
    const gpa: Allocator = gpa_impl.allocator();

    const pixels: u32 = width * height;
    const buf: []u8 = try gpa.alloc(u8, pixels * 4);
    defer gpa.free(buf);

    // Render - measure best-of-N to avoid scheduler noise.
    const N: usize = 3;
    var best_ms: f64 = inf(f64);
    var run: usize = 0;
    while (run < N) : (run += 1) {
        const t0: i128 = monotonicNs();
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const u: f32 = (float(x) + 0.5) / float(width);
                const v: f32 = (float(y) + 0.5) / float(height);
                const zx0: f32 = re_center + (u - 0.5) * view_w;
                const zy0: f32 = im_center + (0.5 - v) * view_h;
                const rgba: [4]u8 = juliaPixel(zx0, zy0);
                const off: usize = (@as(usize, y) * width + x) * 4;
                buf[off + 0] = rgba[0];
                buf[off + 1] = rgba[1];
                buf[off + 2] = rgba[2];
                buf[off + 3] = rgba[3];
            }
        }
        const t1: i128 = monotonicNs();
        const ms: f64 = float64(t1 - t0) / 1_000_000.0;
        if (ms < best_ms) {
            best_ms = ms;
        }
    }

    const png_bytes: []u8 = try sw.codecs.png.encode(gpa, buf, width, height);
    defer gpa.free(png_bytes);

    const out_path: []const u8 = "julia.png";
    var io_threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();
    var f: std.Io.File = try std.Io.Dir.cwd().createFile(io, out_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, png_bytes);

    std.debug.print(
        \\sw_julia — native CPU Julia set
        \\
        \\Julia c:      ({d:.4}, {d:.4}i)
        \\Resolution:   {d}x{d}  Max iterations: {d}
        \\Render time:  {d:.2} ms  (min over {d} runs)
        \\Pixels:       {d}
        \\Throughput:   {d:.2} Mpx/s
        \\Output:       {s} ({d} bytes)
        \\
    , .{
        c_x,
        c_y,
        width,
        height,
        max_iter,
        best_ms,
        N,
        pixels,
        float64(pixels) / (best_ms / 1000.0) / 1_000_000.0,
        out_path,
        png_bytes.len,
    });
}
