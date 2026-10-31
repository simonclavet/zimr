//! The kernel module's buffer lengths, in floats - its activations', its activation gradients', and each of its
//! parameter buffers' (the weights, their gradients, Adam's two moments, the loss). Sized for the PAGES: the CPU twin
//! keeps every buffer as a static array, so these are wasm memory on every page using the kit, and a page's learner
//! is small. A program that needs more builds `zn_mlp.zig` beside a sizes file of its own under this file's name -
//! the headless trainer's (`zn_mlp_sizes_trainer.zig`, copied in by `build.zig`) - so its kernels' declared buffers,
//! its SPIR-V and its CPU module all agree on every length.

/// 2^21 floats, 8 MB: the rollout's blocks, the replay of features, the reference tables.
pub const acts_len: u32 = 1 << 21;
/// 2^20 floats, 4 MB: a gradient for every activation a backward reads.
pub const dacts_len: u32 = 1 << 20;
/// 2^18 floats, 1 MB each: every network's weights, and with them their gradients and moments.
pub const params_len: u32 = 1 << 18;
