//! examples/goban_problems/kernels.zig - goban problems' job kernels: goban's own, since its computer is goban's.
//!
//! The build compiles this file into the kernel wasm the page's workers run (`kernel_deps` gives it goban's
//! kernels.zig as `k_goban`); the program itself submits its jobs through goban's registry.
const goban_kernels = @import("k_goban");

/// goban's kernels, by name.
pub const job_kernels = goban_kernels.job_kernels;

/// goban's registry.
pub const registry = goban_kernels.registry;
