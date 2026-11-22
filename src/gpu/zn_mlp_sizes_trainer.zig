//! The kernel module's buffer lengths for the HEADLESS TRAINER (`tools/geno_trainer.zig`), which `build.zig` copies
//! beside its own build of `zn_mlp.zig` under the name `zn_mlp_sizes.zig` - see that file for what each buffer holds.
//!
//! Sized for the first night's recipes (`examples/geno_lab/recipes/`) at the reference implementations' batches: the
//! whole system on Geno - 1,024 characters on the device with 64 decisions of replay each (472 numbers a record), the
//! minute's 24 clips of reference tables (22,192 frames), the teacher's 512 candidates and 4 kept lookaheads, the
//! acting rows, the model planner's 40 states of 16 candidates, the networks at a third of the reference widths
//! (SuperMimic's world model and policy 680 wide against their 2048, the critic's heads 170 against EfficientTDMPC's
//! 512), the critic, the flow and its teachers, and the skip head - takes, measured on the CPU without a device
//! (`geno_trainer --layout`, the build's `geno-trainer-layout` step):
//!
//!                         without the batch      each window of the batch      at 1,024 windows
//!     activations         95.3 million           173,700                       273 million
//!     their gradients     7.1 million            74,000                        83 million
//!     parameters          6.0 million            -                             6.0 million
//!
//! - the critic alone about 70,000 activations and 40,000 gradients of each window's. These lengths hold the whole
//! system at up to about 1,700 windows a batch (SuperMimic's world model takes 2,048), plain SuperTrack far more. A
//! run that needs more is refused at its start, naming the buffer (`KitActivationsTooSmall` and its two siblings).
//!
//! The device's buffers alone: the trainer keeps no CPU twin of the kernels (`cpu_twin`), which would hold every
//! buffer below as a static array in the program - gigabytes, and Windows refused to start a program of 1.9 GB. They
//! pass the 128 MB a WebGPU storage binding is guaranteed: they are a desktop GPU's, whose Vulkan binds 4 GB in one
//! buffer - 2.7 GB in all here, beside the simulator's. A browser that trains uses the kernel module's own smaller
//! sizes and smaller networks.

/// No CPU twin: the trainer runs its networks on the device alone, and measures a recipe's layout on a pipe that runs
/// nothing (`compute_host.Compute.initMeasure`, `geno_trainer --layout`).
pub const cpu_twin: bool = false;
/// 2^29 floats, 2 GB. The rollouts' blocks, the reference tables, the acting rows, the teachers' example rows and the
/// planner's candidate rows all live here - the batches' room, since the replay has a buffer of its own (`ring_len`).
/// The largest a kernel's 32-bit byte offsets reach whole: 2^31 bytes, of the 2^32 they count.
pub const acts_len: u32 = 1 << 29;
/// 5 x 2^26 floats, 1.34 GB: THE REPLAY OF RECORDS on the device (`robot_latent_kit.RecordRing`), the characters' and
/// the candidates' recorded lookaheads - XMimic's 20 s of replay, 600 decisions of 1,024 characters at 472 floats a
/// record, is 290 million, and the teacher's lookaheads a few million more. Past the 128 MB WebGPU guarantees: a
/// desktop GPU's Vulkan binds it whole (checked against `maxStorageBufferRange` at every binding, wgpu_vulkan.zig).
pub const ring_len: u32 = 5 << 26;
/// 2^27 floats, 512 MB: a gradient for every activation a backward reads - the policy's horizon over a batch of
/// windows, the critic's heads over theirs, the flow's training rows and the planner's scorer among them.
pub const dacts_len: u32 = 1 << 27;
/// 2^23 floats, 32 MB for each parameter buffer (the weights, their gradients, Adam's two moments, the loss): every
/// network's weights at a third of the reference implementations' widths - SuperMimic's world model and policy 680
/// wide (theirs 2048), the flow as wide as the policy, the critic's heads 170 (EfficientTDMPC's 512) - with the
/// critic's target copies and the skip head: the first night needs 6.0 million.
pub const params_len: u32 = 1 << 23;
