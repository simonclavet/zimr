//! native_plot_png - a small, native, pure-Zig program that renders a
//! publication-quality plot straight to a PNG file. No GPU, no browser, no
//! third-party code: zimr rasterizes into a supersampled buffer (4x AA) with
//! its own `imageDraw*` + truetype text, then encodes with its own PNG codec.
//!
//! Build & run (native):
//!     zig build native-plot-png        # writes plot.png next to you
//! or standalone:
//!     zig build-exe examples/native_plot_png/main.zig --dep zimr ...
//!
//! The whole recipe is: make a Canvas, draw a Plot into it, savePng. The
//! Canvas *is* the plot's draw sink, so the same plot code that runs in the
//! browser renders here with no changes.

const std = @import("std");
const zm = @import("zm");
const float64 = zm.float64;
const Allocator = std.mem.Allocator;
const z = @import("zimr");

/// A clean light theme suitable for print/figures.
const figure_style: z.plot.Style = .{
    .bg = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    .grid = .{ .r = 214, .g = 214, .b = 222, .a = 255 },
    .minor_grid = .{ .r = 236, .g = 236, .b = 242, .a = 255 },
    .border = .{ .r = 90, .g = 96, .b = 108, .a = 255 },
    .text = .{ .r = 24, .g = 26, .b = 34, .a = 255 },
    .label = .{ .r = 64, .g = 68, .b = 80, .a = 255 },
    .legend_bg = .{ .r = 249, .g = 249, .b = 252, .a = 255 },
};

pub fn main() !void {
    const gpa: Allocator = std.heap.page_allocator;

    // The application picks the I/O implementation in main (like the
    // allocator) and threads it to anything that reads/writes. Currently
    // std.Io.Threaded is the only implementation.
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    // 1. A 900x560 page, supersampled 4x for crisp anti-aliasing.
    var canvas: z.Canvas = try z.Canvas.init(gpa, 900, 560, .{ .ss = 4 });
    defer canvas.deinit();
    try canvas.useFont(@embedFile("font.ttf"));

    // 2. Configure the plot.
    var p: z.plot.Plot = .{ .title = "damped oscillation (zimr, native PNG)", .style = figure_style };
    p.x.range = .{ .min = 0, .max = 12 };
    p.y.range = .{ .min = -1.05, .max = 1.05 };
    p.x.label = "time (s)";
    p.y.label = "amplitude";
    p.layout(.{ .x = 0, .y = 0, .w = 900, .h = 560 });

    // 3. Generate data.
    const n: usize = 400;
    var xs: [400]f64 = undefined;
    var envelope: [400]f64 = undefined;
    var signal: [400]f64 = undefined;
    for (0..n) |i| {
        const t: f64 = float64(i) / float64(n - 1) * 12.0;
        xs[i] = t;
        envelope[i] = @exp(-0.25 * t);
        signal[i] = @exp(-0.25 * t) * @cos(3.0 * t);
    }

    // 4. Draw into the canvas (the Canvas is the plot sink).
    p.drawFrame(&canvas);
    p.plotShaded(&canvas, &xs, &signal, .{ .y_ref = 0, .color = .{ .r = 60, .g = 130, .b = 246, .a = 48 } });
    p.plotLine(&canvas, &xs, &envelope, .{ .color = .{ .r = 150, .g = 156, .b = 168, .a = 255 }, .thickness = 1.5 });
    p.plotLine(&canvas, &xs, &signal, .{ .color = .{ .r = 33, .g = 118, .b = 230, .a = 255 }, .thickness = 2.0 });
    p.drawDecorations(&canvas);
    const entries = [_]z.plot.LegendEntry{
        .{ .label = "e^(-t/4) cos(3t)", .color = .{ .r = 33, .g = 118, .b = 230, .a = 255 } },
        .{ .label = "envelope", .color = .{ .r = 150, .g = 156, .b = 168, .a = 255 } },
    };
    p.drawLegendEx(&canvas, &entries, p.legendLayout(&entries, .ne, false), null);

    // 5. Save. Resolves the AA buffer, encodes PNG, writes the file via `io`.
    try canvas.savePng(io, "plot.png");
    std.debug.print("wrote plot.png ({d}x{d}, 4x supersampled)\n", .{ 900, 560 });
}
