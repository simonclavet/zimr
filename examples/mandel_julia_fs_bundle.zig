//! examples/mandel_julia_fs_bundle.zig - single-module entry point for
//! native consumers of `mandel_julia_fs.zig`.  Bundles the shader source
//! and its io schema so they share one module.

pub const fs = @import("mandel_julia_fs.zig");
pub const io = @import("mandel_julia_fs_io.zig");
