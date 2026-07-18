//! src/shaders/effect_common_io.zig — the shared shape of every 2D
//! fragment EFFECT in the engine.
//!
//! An effect is: sample `texture0` at (or near) `frag_uv`, do math,
//! emit.  The vertex stage is `deferred_shading_vs` (the NDC fullscreen
//! quad, reused again — third consumer), so the only varying is its UV.
//! Each effect declares its own little Ubo; this file holds what they
//! all share so the family stays visibly one family.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const deferred = @import("deferred_shading_common_io.zig");

/// Interpolated inputs — the fullscreen quad's UV, verbatim.
pub const Inputs = deferred.Interp;

/// The one sampler every effect reads (raylib's `texture0` name kept —
/// it IS the raylib contract these shaders port).
pub const Samplers = struct {
    texture0: shader.Sampler2D(.albedo, .{}),
};

/// Every effect emits one color.
pub const Outputs = struct {
    final_color: Vec,
};
