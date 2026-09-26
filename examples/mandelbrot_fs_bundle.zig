//! examples/mandelbrot_fs_bundle.zig - single-module entry point for
//! native consumers of `mandelbrot_fs.zig`.  Bundles the shader source
//! and its io schema together so they share one module (avoiding Zig
//! 0.16's one-file-per-module rule when both are reached by an example).
//!
//! Consumers import this and reach internals via `bundle.fs` and
//! `bundle.io`.  This is the same pattern as `default_shapes_bundle`
//! and `sw_runtime_bundle`.

pub const fs = @import("mandelbrot_fs.zig");
pub const io = @import("mandelbrot_fs_io.zig");
