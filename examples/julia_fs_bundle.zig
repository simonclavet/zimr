//! examples/julia_fs_bundle.zig — single-module entry point for
//! native consumers of `julia_fs.zig`.  Bundles the shader source
//! and its io schema so they share one module (one-file-per-module
//! rule).  Same pattern as `mandelbrot_fs_bundle`.

pub const fs = @import("julia_fs.zig");
pub const io = @import("julia_fs_io.zig");
