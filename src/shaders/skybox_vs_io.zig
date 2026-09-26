//! src/shaders/skybox_vs_io.zig - typed interface for the gradient-skybox VS.
//! Emits a fullscreen triangle from `vertex_index`, unprojects each corner to a
//! world-space view ray, and forwards the ray + sky colours to the FS. Body in
//! `skybox_vs.zig`. UBO layout mirrors `draw3d.SkyboxSchema.Ubo`.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("skybox_common_io.zig");

/// No vertex buffer - the fullscreen triangle comes from `vertex_index`. The
/// empty `Attributes` marks this as the vertex stage (Ubo binds at group 0).
pub const Attributes = struct {};

/// group(0) binding(0) uniform - matches `draw3d.SkyboxSchema.Ubo`.
pub const Ubo = struct {
    inv_view_proj: [4]Vec align(16),
    camera_pos: Vec align(16),
    sky_bottom: Vec align(16),
    sky_top: Vec align(16),
};

/// Builtins the body reads.
pub const Builtins = struct {
    vertex_index: shader.Builtin(.vertex_index),
};

/// Varyings to the FS - view ray + forwarded sky colours.
pub const Outputs = common.Interp;
