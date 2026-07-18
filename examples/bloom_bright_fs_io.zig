//! examples/bloom_bright_fs_io.zig — typed interface for the bloom
//! bright-pass fragment shader. Reads the scene render texture and keeps only
//! the luminance above `thresh`, remapped so the threshold maps to black. Body
//! in `bloom_bright_fs.zig`.
//!
//! Layout note: a post-process pass has no material group, so everything lives
//! in group 0. The per-pass UBO takes binding 0 (the codegen's fixed UBO slot);
//! the source texture + sampler are PINNED just after it at bindings 1 and 2.
//! `ubo_group = 0` keeps the UBO in the same group as the pinned texture so the
//! whole pass is one bind group.

const shader = @import("shader_interface");
const zm = @import("zm");
const Vec2 = zm.Vec2;
const Vec = zm.Vec;

/// Pin the UBO to group 0 (post passes have no material group; the source
/// texture shares group 0 too).
pub const ubo_group: u32 = 0;

/// Interpolated screen UV from the shared fullscreen VS (structural varying).
pub const Inputs = struct {
    v_uv: Vec2,
};

/// group(0) binding(0): the single per-pass scalar, padded to a vec4 (std140).
pub const Ubo = struct {
    /// {thresh, 0, 0, 0} — luminance below `thresh` is discarded.
    params: Vec,
};

/// The scene texture, pinned to group 0 right after the UBO (texture @binding 1,
/// sampler @binding 2).
pub const Samplers = struct {
    src: shader.Sampler2D(.albedo, .{ .pinned = .{ .group = 0, .binding = 1 } }),
};

/// Stage output — the bright-pass colour.
pub const Outputs = struct {
    final_color: Vec,
};
