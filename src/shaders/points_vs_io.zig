//! src/shaders/points_vs_io.zig — typed interface for the instanced points VS.
//!
//! First real port from the direct `@SpirvType` pattern to IoT, using the new
//! `Storage` + `Builtins` schema sections. Reads `positions[instance_index]`
//! from a read-only storage buffer, expands a quad per instance via
//! `vertex_index`, and colours by height. Body in `points_vs.zig`.

const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("points_common_io.zig");

/// No vertex buffer — corners come from `vertex_index`, instance data from the
/// storage buffer. The empty `Attributes` marks this as the vertex stage (so
/// the Ubo binds at group 0, storage after it).
pub const Attributes = struct {};

/// VS uniform block (group 0, binding 0). Mirrors `DrawPoints.Uniforms`.
pub const Ubo = struct {
    half_ndc: Vec2,
    pad: Vec2,
    top: Vec,
    bot: Vec,
};

/// Read-only storage buffer of per-instance positions (group 0, binding 1 —
/// after the Ubo). A compute pass or CPU upload fills it.
pub const Storage = struct {
    positions: shader.StorageBuf(Vec2, .read),
};

/// Builtins the body reads.
pub const Builtins = struct {
    vertex_index: shader.Builtin(.vertex_index),
    instance_index: shader.Builtin(.instance_index),
};

/// Varyings to the FS — the per-vertex colour.
pub const Outputs = common.Interp;
