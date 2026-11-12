//! robotgpu's arena lengths for a PAGE that steps a few hundred worlds of a robot the size of Geno - the side-by-side
//! page's throughput probe, at most 256 worlds - in elements of each arena. A pipe allocates every arena at its full
//! length, whatever its worlds need, so a page holding two Sims at once (the one it draws, and the probe's) holds two
//! sets: about 56 MB each, within WebGPU's 128 MB a storage binding and a phone's memory.
//!
//!     Geno, one world       world_f about 9,600 floats   world_u about 4,700 words   efc_f about 19,600 floats
//!     256 worlds            2.5 M                        1.2 M                       5.0 M
//!     the arenas below      4.2 M (16 MB)                2.1 M (8 MB)                8.4 M (32 MB)
pub const model_f: u32 = 1 << 16;
pub const model_u: u32 = 1 << 16;
pub const batch_f: u32 = 1 << 16;
pub const world_f: u32 = 1 << 22;
pub const world_u: u32 = 1 << 21;
pub const efc_f: u32 = 1 << 23;
pub const scratch: u32 = 1 << 16;
pub const io: u32 = 1 << 16;
