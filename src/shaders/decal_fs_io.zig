//! src/shaders/decal_fs_io.zig - typed interface for the shader-projected decal
//! receiver fragment stage. Non-standard bind layout, expressed with two pins:
//!   - the projector UBO sits at group 1 (not the default FS group 2), via
//!     `pub const ubo_group = 1`;
//!   - the decal texture sits at group 2 (not the default sampler group 1), via
//!     the `Sampler2D` `.pinned` config.
//! The host serves the group-1 projector UBO from a 64-slot ring of pre-built
//! bind groups; the schema only sees "a UBO at group 1", so the ring stays a
//! pure host concern. Body in `decal_fs.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("decal_common_io.zig");

/// Interpolated inputs from the VS - aliases the shared `Interp`.
pub const Inputs = common.Interp;

/// Projector UBO - PINNED to group 1 (not the default FS group 2). `params.x` =
/// half box size; `params.y` = 1/decal_size. `forward` is the world direction
/// the projector faces (surface normal at the hit).
pub const ubo_group: u32 = 1;
pub const Ubo = struct {
    projector: [4]@Vector(4, f32) align(16),
    color: Vec align(16),
    params: Vec align(16),
    forward: Vec align(16),
};

/// Decal texture - PINNED to group 2 (binding 0 -> texture, 1 -> sampler).
pub const Samplers = struct {
    decal: shader.Sampler2D(.albedo, .{ .pinned = .{ .group = 2, .binding = 0 } }),
};

/// Stage output - the final decal colour (straight-alpha; 0-alpha outside box).
pub const Outputs = struct {
    final_color: Vec,
};
