//! robotgpu's arena lengths for TESTS and lavapipe, in elements of each arena: a few dozen worlds of a robot the
//! size of Geno, every arena far within lavapipe's 128 MB binding and the test binaries' memory (the CPU twin keeps
//! every arena as a static). Desktop builds use robotgpu_sizes.zig instead, chosen by the build.

pub const model_f: u32 = 1 << 16;
pub const model_u: u32 = 1 << 16;
pub const batch_f: u32 = 1 << 16;
/// 64 worlds x about 8,940 floats.
pub const world_f: u32 = 1 << 20;
pub const world_u: u32 = 1 << 16;
/// 64 worlds x about 16,460 floats.
pub const efc_f: u32 = 1 << 21;
pub const scratch: u32 = 1 << 19;
pub const io: u32 = 1 << 16;
