//! robotgpu's arena lengths for the HEADLESS TRAINER ON A DESKTOP GPU (`zig build geno-trainer`), in elements of each
//! arena: Geno at up to 2,543 worlds - the first night's 1,536 (1,024 characters and the teacher's 512 candidates) with
//! room - and in the model's constants a run's clips, the minute of motion with every variant. The numbers a world are
//! measured on the first night's recipe (`geno_trainer --layout`). Each arena is well within a desktop GPU's binding of
//! 2 to 4 GB. The largest, the constraint rows, is 256 MB - past the 128 MB every device binds, so on a device that
//! binds no more this trainer stops at its first binding of it, loudly (the Vulkan host's `createBindGroup`); the
//! trainer built portable (`-Dtrainer-portable=true`, robotgpu_sizes_portable.zig) runs there, with smaller runs. Tests
//! and lavapipe use robotgpu_sizes_test.zig, chosen by the build.
//!
//! The trainer keeps no CPU twin of the simulator (`cpu_twin`): a twin holds every arena as a static array of the same
//! length (`kompute.Globals`), which would make these lengths the program's size - and Windows refused to start a
//! trainer of 1.9 GB.

/// No CPU twin: the trainer simulates on the device alone.
pub const cpu_twin: bool = false;
/// Real-valued model constants - bodies, joints, dofs, geoms - and a tracking task's clips beside them: every frame's
/// coordinates and its reference's features and bodies. For Geno that is 986 numbers a frame (99 coordinates, 387
/// features, 500 of bodies), so the minute of motion with its six variants - 24 clips, 22,192 frames - takes 21.9
/// million of these 33.6 million; this holds about 34,000 frames. (At 1 << 23 a simulator refuses those clips:
/// `ModelConstantsTooSmall`.)
pub const model_f: u32 = 1 << 25;
/// Topology and index tables.
pub const model_u: u32 = 1 << 18;
/// Per-world model parameters, for domain randomisation.
pub const batch_f: u32 = 1 << 22;
/// Per-world state and everything derived from it: 12,028 floats a world, 18.5 million for the first night's 1,536;
/// room for 2,789 worlds.
pub const world_f: u32 = 1 << 25;
/// Per-world integers - counts, row kinds and sources, each row's Jacobian's dofs, overflow bits: 6,596 a world, 10.1
/// million for the first night's 1,536. The arena that fills first: it holds 2,543 worlds. (At 1 << 23 a simulator
/// refuses more than 1,271 worlds: `WorldIntegersTooSmall`.)
pub const world_u: u32 = 1 << 24;
/// Each world's constraint rows (`robotgpu.ConstraintRowsLayout`): its limit candidates, and each row's quantities
/// with its Jacobian's nonzeros - 21,756 floats a world, 33.4 million for the first night's 1,536; room for 3,084.
pub const efc_f: u32 = 1 << 26;
/// Per-world solver workspace. No array lives here yet - Newton's Hessian and vectors are in each workgroup's shared
/// memory (robotgpu.zig's `newton_hessian`) - so it is as small as the tests' (robotgpu_sizes_test.zig).
pub const scratch: u32 = 1 << 19;
/// The host's window: what the worlds share - the start curriculum's bins, four numbers a bin (89 thousand for the
/// minute's clips at a bin a frame).
pub const io: u32 = 1 << 22;
