//! src/shaders/gbuffer_fs_io.zig — typed interface for the G-buffer
//! fragment shader.  Companion to `gbuffer_fs.zig`.
//!
//! THE point of this schema: `Outputs` has THREE fields, which makes
//! this the engine's first multi-render-target fragment shader.  Each
//! field's declaration index is its `@location(N)` — i.e. which color
//! attachment of the MRT pass it lands in:
//!
//!   location 0 → world position   (rgba16_float attachment)
//!   location 1 → world normal     (rgba16_float attachment)
//!   location 2 → albedo + spec    (rgba8_unorm attachment)
//!
//! raylib packs albedo.rgb + specular-strength.a into one texture; we
//! keep that trick (it's a good one) and mirror it in the UNIFORM too:
//! the material is literally the vec4 this pass will store.

const zm = @import("zm");
const Vec = zm.Vec;
const common = @import("gbuffer_common_io.zig");

/// Interpolated inputs from `gbuffer_vs`.
pub const Inputs = common.Interp;

/// FS uniform block (group 2, one binding).  The whole material in one
/// vec4: rgb = flat albedo, a = specular strength [0,1].  Written to the
/// G-buffer verbatim — what you set is what pass 2 shades with.
pub const Ubo = struct {
    albedo_spec: Vec,
};

/// Stage outputs — one per MRT attachment, locations by field order.
/// Positions/normals ride in the xyz of float targets (w is spare; we
/// park 1.0 there so debug-viewing the raw buffer shows opaque pixels).
pub const Outputs = struct {
    g_world_pos: Vec,
    g_world_normal: Vec,
    g_albedo_spec: Vec,
};
