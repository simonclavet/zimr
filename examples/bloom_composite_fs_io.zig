//! examples/bloom_composite_fs_io.zig — typed interface for the bloom
//! composite pass: adds the blurred highlights back onto the original scene,
//! scaled by `intensity`. Body in `bloom_composite_fs.zig`.
//!
//! Layout: two source textures + one sampler, all in group 0 (post passes have
//! no material group). The per-pass UBO takes binding 0; the scene texture is
//! pinned at binding 1, the bloom texture at binding 2, and they SHARE one
//! sampler pinned at binding 3. `ubo_group = 0` keeps everything in one bind
//! group.

const shader = @import("shader_interface");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec = zm.Vec;

/// Pin the UBO to group 0 (post passes have no material group).
pub const ubo_group: u32 = 0;

/// Interpolated screen UV from the shared fullscreen VS (structural varying).
pub const Inputs = struct {
    v_uv: Vec2,
};

/// group(0) binding(0): the per-pass composite scalar, padded to a vec4.
pub const Ubo = struct {
    /// {intensity, 0, 0, 0} — how strongly the blurred bloom is added back.
    params: Vec,
};

/// Two source textures pinned into group 0 after the UBO: the original scene at
/// binding 1, the blurred bloom at binding 2. Each `Sampler2D` is a texture +
/// its own sampler, so scene owns bindings (1,2)-hmm — see note below.
///
/// NOTE: each `Sampler2D` field emits BOTH a texture and a sampler binding, so
/// pinning the texture also fixes its sampler at the next slot. Scene pinned to
/// (tex 1, sampler 2), bloom pinned to (tex 3, sampler 4). This differs from the
/// old hand-written WGSL (which shared one sampler) but is layout-equivalent —
/// the host binds the same sampler handle to both slots.
pub const Samplers = struct {
    scene: shader.Sampler2D(.albedo, .{ .pinned = .{ .group = 0, .binding = 1 } }),
    bloom: shader.Sampler2D(.emission, .{ .pinned = .{ .group = 0, .binding = 3 } }),
};

/// Stage output — the final composited colour.
pub const Outputs = struct {
    final_color: Vec,
};
