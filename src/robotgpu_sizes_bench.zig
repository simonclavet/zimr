//! robotgpu's arena lengths for A MEASURING RUN OF THE DEVICE TEST (`-Dhost-test-sizes=src/robotgpu_sizes_bench.zig`),
//! in elements of each arena: the desktop's sizes (robotgpu_sizes.zig) for a quarter of its worlds - Geno at 1,024
//! worlds, with the same room a world - so the test can time what many worlds cost on a real GPU. Every arena still
//! fits lavapipe's 128 MB binding, the constraint rows' exactly, so the same build is checked on the build machine
//! at small world counts before it is run elsewhere at large ones.

/// Real-valued model constants: bodies, joints, dofs, geoms, and the clips of a tracking task (the test's own length).
pub const model_f: u32 = 1 << 18;
/// Topology and index tables.
pub const model_u: u32 = 1 << 18;
/// Per-world model parameters, for domain randomisation: 1,024 x 1,024.
pub const batch_f: u32 = 1 << 20;
/// Per-world state and everything derived from it: 1,024 x 11,152 floats (Geno on a tracking task, measured).
pub const world_f: u32 = 1 << 24;
/// Per-world integers - counts, row kinds and sources, each row's Jacobian's dofs, overflow bits: 1,024 x 6,580.
pub const world_u: u32 = 1 << 23;
/// Each world's constraint rows (`robotgpu.ConstraintRowsLayout`), 1,024 x 21,756 floats: 128 MB, lavapipe's largest
/// binding.
pub const efc_f: u32 = 1 << 25;
/// Per-world solver workspace, the Hessian first: 1,024 x about 6,330 floats.
pub const scratch: u32 = 1 << 23;
/// The host's window: uploads and small readbacks.
pub const io: u32 = 1 << 20;
