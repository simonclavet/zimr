//! examples/rt_workers/kernels.zig - the registry.
//!
//! Compiled TWICE: into the app (so `Group.submitAll` knows the header type, checked at
//! comptime) and into a separate freestanding kernel wasm with ZERO imports, which the Web
//! Workers instantiate with `{}`. The build ASSERTS that import section is empty, so a kernel
//! that reaches for the DOM fails to build rather than failing on a phone.
const z = @import("zimr");

const jobs = z.jobs;

pub const tracer = @import("tracer.zig");
pub const traceTile = tracer.traceTile;

pub const job_kernels = .{
    .{ "traceTile", traceTile },
};

/// The bounds are TIGHT, and that is the point of this example.
///
/// `worker_png` moves 4 MB in and 2.7 MB out per job, and the cost of moving those bytes is
/// what dominated - and hid - its behaviour for weeks. Here:
///
///   in:  a Tile header + the sphere array. A few hundred bytes.
///   out: one band of pixels. At 320x240 in 16 bands that is 320 x 15 x RGBA = 19 KB.
///
/// So the transport is nothing and what you are watching is the POOL, not the plumbing.
/// 512 KB of headroom covers a full-frame band even if someone renders one tile for the whole
/// image, which is exactly what the "1 worker" comparison does.
pub const registry = jobs.Registry(job_kernels, .{
    .max_input = 64 << 10, // 64 KB - a scene is spheres, not geometry
    .max_output = 512 << 10, // 512 KB - one band, with room for the whole image in one tile
});
