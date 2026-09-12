//! Host-only standalone: renders `plot.renderDemoSvg` to stdout (redirect
//! to a .svg file).  Exercises the `plot.zig` rendering core through the
//! `SvgSink`; the in-engine path uses a `ui.DrawList` sink instead.
//! Build (ad-hoc; plot.zig is zm-only):
//!   zig build-exe -target x86_64-linux-gnu \
//!     --dep plot -Mroot=tools/plot_svg_demo.zig \
//!     --dep zm   -Mplot=src/plot.zig \
//!     --dep build_options -Mzm=src/zimrmath.zig \
//!     -Mbuild_options=<stub:`pub const assert_log=false;`>
const std = @import("std");
const Allocator = std.mem.Allocator;
const plot = @import("plot");

pub fn main() void {
    const gpa: Allocator = std.heap.page_allocator;
    // I/O implementation is chosen here in main and threaded to the write.
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    const svg: []u8 = plot.renderDemoSvg(gpa) catch return;
    defer gpa.free(svg);

    const out: std.Io.File = std.Io.File.stdout();
    out.writeStreamingAll(io, svg) catch {}; // lint:off catch-suppression: best-effort stdout write
}
