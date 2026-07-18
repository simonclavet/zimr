//! src/shaders/maze_fs_io.zig — face-shaded maze material schema.
//! Companion to `maze_fs.zig`.
//!
//! Rides the shared `gbuffer_vs` (world pos + world normal), like fog,
//! cel, and terrain — a new forward material is one fragment file.
//! Where terrain reads the fragment's world HEIGHT, this reads the
//! world NORMAL: floor, ceiling, and the four wall directions each get
//! a distinct tone, so a `genMeshCubicmap` maze reads as structure with
//! no atlas texture upload (the heightmap trick, applied to walls).

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("gbuffer_common_io.zig");

pub const Inputs = common.Interp;

/// FS uniform block (group 2, one binding).
pub const Ubo = struct {
    /// Sun direction (world), .w spare.
    light_dir: Vec,
    /// Up-facing surfaces (floor tops / cube tops).
    col_top: Vec,
    /// Down-facing surfaces (ceilings / cube undersides).
    col_bottom: Vec,
    /// Walls running along Z (their normals point ±X).
    col_wall_x: Vec,
    /// Walls running along X (their normals point ±Z).
    col_wall_z: Vec,
};

pub const Outputs = struct { final_color: Vec };
