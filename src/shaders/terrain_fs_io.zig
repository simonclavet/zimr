//! src/shaders/terrain_fs_io.zig — height-banded terrain material
//! schema.  Companion to `terrain_fs.zig`.
//!
//! Rides the shared `gbuffer_vs` (world pos + world normal), like fog
//! and cel — a new forward material is one fragment file.  Where
//! `fog_fs` paints one flat base color, this maps the fragment's WORLD
//! HEIGHT through a low→high color ramp (water/grass/rock/snow), so a
//! generated heightmap reads as terrain with no texture upload.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("gbuffer_common_io.zig");

pub const Inputs = common.Interp;

/// FS uniform block (group 2, one binding).
pub const Ubo = struct {
    /// Sun direction (world), .w spare.
    light_dir: Vec,
    /// Four ramp colors low→high (rgb; .a spare).
    band_lo: Vec,
    band_mid: Vec,
    band_hi: Vec,
    band_top: Vec,
    /// {min_y, max_y, 0, 0} — the height range the ramp spans.
    params: Vec,
};

pub const Outputs = struct { final_color: Vec };
