//! The kernel module's buffer lengths for the HEADLESS TRAINER built PORTABLE:
//!
//!     zig build geno-trainer -Dtrainer-portable=true
//!
//! Every buffer stays within the 128 MB a WebGPU storage binding is guaranteed, so this trainer runs on every
//! device - lavapipe, and GPUs whose Vulkan binds no more (`maxStorageBufferRange`). The night's runs need the
//! desktop sizes (`zn_mlp_sizes_trainer.zig`); these hold smaller ones: on Geno at a third of the reference widths,
//! 16 windows a batch, a replay of 128 steps for each character and a search of 12 candidates fit. A run that needs
//! more is refused at its start, naming the buffer.

/// 2^25 floats, 128 MB - exactly the storage binding WebGPU guarantees.
pub const acts_len: u32 = 1 << 25;
/// 2^23 floats, 32 MB.
pub const dacts_len: u32 = 1 << 23;
/// 2^22 floats, 16 MB for each parameter buffer - the networks at a third of the reference widths need about 4 million.
pub const params_len: u32 = 1 << 22;
