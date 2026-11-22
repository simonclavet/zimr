//! robotgpu's arena lengths for the HEADLESS TRAINER BUILT PORTABLE (`zig build geno-trainer
//! -Dtrainer-portable=true`), in elements of each arena: every arena within the 128 MB one storage binding holds on
//! every device - WebGPU's guarantee, and the most that lavapipe and some GPUs' Vulkan bind (`maxStorageBufferRange`).
//! Geno at 1,024 worlds with room, a quarter of the desktop's (robotgpu_sizes.zig), and the same run's clips in the
//! model's constants: the minute of motion with every variant. The constraint rows and the model's constants are 128
//! MB exactly. A run that needs more is refused at its start, by the arena's name (`robotgpu.LayoutError`). The
//! numbers a world are Geno's on the trainer's run, as robotgpu_tests.zig lays it out.

/// No CPU twin: the trainer simulates on a device alone (lavapipe, where there is no GPU), so the arenas are no part
/// of the program.
pub const cpu_twin: bool = false;
/// Real-valued model constants and a tracking task's clips, as the desktop's: 986 numbers a frame for Geno, so the
/// minute's 24 clips - 22,192 frames - take 21.9 million of these 33.6 million; this holds about 34,000 frames.
pub const model_f: u32 = 1 << 25;
/// Topology and index tables.
pub const model_u: u32 = 1 << 18;
/// Per-world model parameters, for domain randomisation.
pub const batch_f: u32 = 1 << 20;
/// Per-world state and everything derived from it: 1,024 x 11,852 floats.
pub const world_f: u32 = 1 << 24;
/// Per-world integers: 1,024 x 6,592. The arena that fills first: it holds 1,272 worlds, so 1,024 characters leave
/// room for 248 more worlds - a planner's candidates.
pub const world_u: u32 = 1 << 23;
/// Each world's constraint rows (`robotgpu.ConstraintRowsLayout`): 1,024 x 21,756 floats of these 33.6 million.
pub const efc_f: u32 = 1 << 25;
/// Per-world solver workspace. No array lives here yet: Newton's Hessian and vectors are in each workgroup's shared
/// memory (robotgpu.zig's `newton_hessian`).
pub const scratch: u32 = 1 << 23;
/// The host's window: what the worlds share - the start curriculum's bins, four numbers a bin (89 thousand for the
/// minute's clips at a bin a frame).
pub const io: u32 = 1 << 20;
