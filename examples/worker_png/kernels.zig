//! examples/worker_png/kernels.zig — the PURE half of the example.
//!
//! This file is compiled TWICE:
//!
//!   * into the app's wasm, so `registry.submit(...)` knows the kernel's header type —
//!     all at comptime, so a mismatch is a build error;
//!   * into a SEPARATE, freestanding kernel wasm (~20 KB, ZERO imports) that the workers
//!     instantiate. Zero imports is the whole trick: the worker's JS can instantiate it
//!     with `{}`. Nothing to stub, no DOM, no WebGPU, no WASI.
//!
//! It imports `zimr` like any other example — but it may only TOUCH the pure parts of it
//! (`codecs`, `zm`, `jobs`, `easings`, ...). Reach for `zimr.drawText` and the kernel wasm
//! sprouts a `dom` import and the trick dies. That is not a style rule you can forget: the
//! build ASSERTS the kernel wasm's import section is empty, so a kernel that touches the
//! DOM fails to build, with a message saying which import gave it away.
//!
//! (Zig's lazy analysis is what makes this work: `src/zimr.zig` declares the whole engine,
//! but only what the kernel actually REACHES gets compiled in. Touch nothing impure and
//! nothing impure is linked.)
//!
//! Note what is NOT here: `exportWorkerEntry`. build.zig generates a tiny root that calls
//! it, so the app — which imports this file for `registry` — never links the worker's
//! buffers.

const std = @import("std");
const zimr = @import("zimr");

const codecs = zimr.codecs;
const jobs = zimr.jobs;
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;

/// `extern`, not a plain struct: these bytes are memcpy'd out of the app's wasm and into
/// the kernel's — two separate compilations — and Zig's auto layout is free to reorder
/// fields. `extern` is what the language provides for a boundary. (The call site is
/// unchanged: `.{ .w = 1024, .h = 1024 }` still coerces.)
pub const Size = extern struct {
    w: u32,
    h: u32,
};

/// Encode an RGBA8 image to PNG.
///
/// An ordinary Zig function: allocator first, as everywhere else in std, and a plain
/// `std.Io.Writer` for output. Nothing about it announces that it will run on another
/// thread — which is exactly the point. It runs in its own wasm instance with its own
/// linear memory, so it cannot see the app's globals even if it wanted to.
///
/// `gpa` is an ARENA. Whatever the kernel allocates is released for it when the job ends,
/// which is why there is no `defer free` here and no way to leak.
///
/// ~240 ms for 1024x1024 in wasm on a phone. On the main thread that is a 233 ms frozen
/// frame — fourteen dropped frames, plainly visible. Here it is zero.
pub fn encodePng(
    gpa: Allocator,
    hdr: Size,
    pixels: []const u8,
    out: *std.Io.Writer,
) !void {
    const png: []u8 = try codecs.png.encode(gpa, pixels, hdr.w, hdr.h);
    try out.writeAll(png);
}

/// The kernel table, exposed so registries can COMPOSE. A page that bundles several
/// examples (the launcher) builds one kernel wasm from the concatenation:
///
///     jobs.Registry(worker_png.job_kernels ++ four_ways.job_kernels, .{})
///
/// which works because the wasm exports are keyed by NAME, not by an index or a hash —
/// so a merged kernel wasm satisfies every example's `submit` with nobody renumbering.
pub const job_kernels = .{
    .{ "encodePng", encodePng },
};

pub const registry = jobs.Registry(job_kernels, .{
    .max_input = 8 << 20, // 4 MB of RGBA at 1024x1024, with room to spare
    .max_output = 8 << 20, // a 1024x1024 PNG comes out around 2.7 MB
});

// The kernel is a plain function, so testing it needs no browser, no worker and no wasm.
// This is the ergonomic payoff, and it is worth stating plainly: if you can `zig build
// test` your kernel, the only thing left to break is transport — and transport is the
// engine's problem, not yours.
test "encodePng emits a valid PNG signature" {
    var out_buf: [1 << 16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const px: [4 * 4 * 4]u8 = @splat(255); // 4x4 RGBA, all white

    try encodePng(std.testing.allocator, .{ .w = 4, .h = 4 }, &px, &out);

    try expect(out.buffered().len > 8);
    try expectEqualSlices(u8, &[_]u8{ 0x89, 'P', 'N', 'G' }, out.buffered()[0..4]);
}
