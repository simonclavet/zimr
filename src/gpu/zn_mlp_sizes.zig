//! The kernel module's buffer lengths, in floats - its activations', its activation gradients', and each of its
//! parameter buffers' (the weights, their gradients, Adam's two moments, the loss). Sized for the PAGES: the CPU twin
//! keeps every buffer as a static array, so these are wasm memory on every page using the kit, and a page's learner
//! is small. A program that needs more builds `zn_mlp.zig` beside a sizes file of its own under this file's name -
//! the headless trainer's (`zn_mlp_sizes_trainer.zig`, copied in by `build.zig`) - so its kernels' declared buffers,
//! its SPIR-V and its CPU module all agree on every length.

/// Whether the kit keeps its CPU twin - every buffer below a static array in the program, the kernels as host
/// functions (`compute_host.Compute`'s `.cpu` and `.worker` backends): a page needs it where it has no GPU.
pub const cpu_twin: bool = true;
/// 2^21 floats, 8 MB: the rollout's blocks, the reference tables, the window starts.
pub const acts_len: u32 = 1 << 21;
/// 2^20 floats, 4 MB: the replay of records on the device (`robot_latent_kit.RecordRing`) - the track_train page's 8
/// characters at 256 decisions each take 967,000 floats of Geno (472 a record), 655,000 of the test humanoid (320),
/// as does the resident tests' 4 of 512. No larger: a page holds it twice, in the twin's static arrays and in a device
/// pipe's readback mirror (`compute_host`).
pub const ring_len: u32 = 1 << 20;
/// 2^20 floats, 4 MB: a gradient for every activation a backward reads.
pub const dacts_len: u32 = 1 << 20;
/// 2^18 floats, 1 MB each: every network's weights, and with them their gradients and moments.
pub const params_len: u32 = 1 << 18;
