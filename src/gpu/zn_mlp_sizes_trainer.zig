//! The kernel module's buffer lengths for the HEADLESS TRAINER (`tools/geno_trainer.zig`), which `build.zig` copies
//! beside its own build of `zn_mlp.zig` under the name `zn_mlp_sizes.zig` - see that file for what each buffer holds.
//!
//! Sized for a long run of the whole system on Geno: the minute's reference tables (3,600 frames of about 600 numbers
//! each), a replay of a few hundred steps for each of 32 characters (441 numbers a step), windows of 32 steps, the
//! networks at a third of the reference implementations' widths (SuperMimic's world model and policy 680 wide against
//! their 2048, the flow as wide as the policy, the critic's heads 170 against EfficientTDMPC's 512), the critic, the
//! flow and its three teachers, the skip head and the planner's search: about 40 million floats of activations, 12.4
//! million of their gradients and 4 million of parameters. A run that needs more is refused at its start, naming the
//! buffer (`KitActivationsTooSmall` and its two siblings). These sizes pass the 128 MB a WebGPU storage binding is
//! guaranteed: they are the native trainer's, on a desktop GPU's Vulkan; a browser that trains uses the kernel module's
//! own smaller sizes and smaller networks.

/// 2^26 floats, 256 MB. The rollouts' blocks, the replay of features, the reference tables, the teachers' example rows
/// and the planner's candidate rows all live here; at a third of the reference widths the whole system needs about 40
/// million.
pub const acts_len: u32 = 1 << 26;
/// 2^24 floats, 64 MB: a gradient for every activation a backward reads - a 32-step horizon over a batch of windows,
/// the flow's training rows and the planner's scorer among them; about 12.4 million at a third of the reference widths.
pub const dacts_len: u32 = 1 << 24;
/// 2^23 floats, 32 MB for each parameter buffer (the weights, their gradients, Adam's two moments, the loss): every
/// network's weights at a third of the reference implementations' widths - SuperMimic's world model and policy 680
/// wide (theirs 2048), the flow as wide as the policy, the critic's heads 170 (EfficientTDMPC's 512) - with the
/// critic's target copies and the skip head.
pub const params_len: u32 = 1 << 23;
