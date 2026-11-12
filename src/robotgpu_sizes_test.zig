//! robotgpu's arena lengths for TESTS and lavapipe, in elements of each arena: a few dozen worlds of a robot the
//! size of Geno, every arena far within lavapipe's 128 MB binding and the test binaries' memory (the CPU twin keeps
//! every arena as a static). Desktop builds use robotgpu_sizes.zig instead, chosen by the build.

/// The model's constants, and a tracking task's clips beside them: every frame's coordinates and, where the task
/// observes, its reference's half of the observation (a few hundred numbers a frame, for a clip of hundreds of frames).
pub const model_f: u32 = 1 << 18;
pub const model_u: u32 = 1 << 16;
pub const batch_f: u32 = 1 << 16;
/// 64 worlds x about 8,940 floats.
pub const world_f: u32 = 1 << 20;
/// Each world's integers - among them its rows' Jacobian dofs: four rows a floor slot, a chain's dofs each.
pub const world_u: u32 = 1 << 19;
/// Each world's constraint rows (`robotgpu.ConstraintRowsLayout`): its limit candidates, and each row's quantities
/// with its Jacobian's nonzeros - a limit's one, a floor contact's a chain's worth, four rows a floor slot.
pub const efc_f: u32 = 1 << 22;
pub const scratch: u32 = 1 << 19;
pub const io: u32 = 1 << 16;
