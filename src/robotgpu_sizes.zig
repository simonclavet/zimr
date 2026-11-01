//! robotgpu's arena lengths for DESKTOP GPUs - the native trainer and lab - in elements of each arena. Sized for Geno
//! at 4,096 worlds with room (the plan's memory envelope: about 127 KB a world, the constraint rows' dense Jacobian the
//! largest arena), each arena well within a desktop binding of 2 to 4 GB. Tests and lavapipe use
//! robotgpu_sizes_test.zig instead, chosen by the build.

/// Real-valued model constants: bodies, joints, dofs, geoms.
pub const model_f: u32 = 1 << 18;
/// Topology and index tables.
pub const model_u: u32 = 1 << 18;
/// Per-world model parameters, for domain randomisation.
pub const batch_f: u32 = 1 << 22;
/// Per-world state and everything derived from it: 4,096 x about 8,940 floats.
pub const world_f: u32 = 1 << 26;
/// Per-world integers: counts, row kinds and sources, contact pairs, overflow bits.
pub const world_u: u32 = 1 << 23;
/// Per-world constraint rows, the dense Jacobian first: 4,096 x about 16,460 floats.
pub const efc_f: u32 = 1 << 27;
/// Per-world solver workspace, the Hessian first: 4,096 x about 6,330 floats.
pub const scratch: u32 = 1 << 25;
/// The host's window: uploads and small readbacks.
pub const io: u32 = 1 << 22;
