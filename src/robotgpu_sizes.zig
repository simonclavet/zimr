//! robotgpu's arena lengths for DESKTOP GPUs - the native trainer and lab - in elements of each arena. Sized for Geno
//! at 4,096 worlds with room (the plan's memory envelope: about 127 KB a world, the constraint rows' dense Jacobian the
//! largest arena), each arena well within a desktop binding of 2 to 4 GB. Tests and lavapipe use
//! robotgpu_sizes_test.zig instead, chosen by the build.

/// Real-valued model constants - bodies, joints, dofs, geoms - and a tracking task's clips beside them: every frame's
/// coordinates and its reference's features and bodies. For Geno that is 986 numbers a frame (99 coordinates, 387
/// features, 500 of bodies), so the minute of motion at 60 Hz - 3,600 frames - is 3.55 million; this holds 8,500
/// frames. (At 1 << 18 a simulator refuses the minute: `ModelConstantsTooSmall`.)
pub const model_f: u32 = 1 << 23;
/// Topology and index tables.
pub const model_u: u32 = 1 << 18;
/// Per-world model parameters, for domain randomisation.
pub const batch_f: u32 = 1 << 22;
/// Per-world state and everything derived from it: 4,096 x 11,152 floats (Geno on a tracking task, as the device
/// test measures a world: `robotgpu tracking throughput`).
pub const world_f: u32 = 1 << 26;
/// Per-world integers - counts, row kinds and sources, each row's Jacobian's dofs, overflow bits: 4,096 x 6,580 is
/// 27 million. (At 1 << 23 a simulator refuses more than 1,274 worlds: `WorldIntegersTooSmall`.)
pub const world_u: u32 = 1 << 25;
/// Each world's constraint rows (`robotgpu.ConstraintRowsLayout`): its limit candidates, and each row's quantities
/// with its Jacobian's nonzeros - 4,096 x 21,756 floats.
pub const efc_f: u32 = 1 << 27;
/// Per-world solver workspace, the Hessian first: 4,096 x about 6,330 floats.
pub const scratch: u32 = 1 << 25;
/// The host's window: uploads and small readbacks.
pub const io: u32 = 1 << 22;
