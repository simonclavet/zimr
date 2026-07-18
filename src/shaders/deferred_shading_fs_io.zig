//! src/shaders/deferred_shading_fs_io.zig — typed interface for the
//! deferred lighting fragment shader.  Companion to
//! `deferred_shading_fs.zig`.
//!
//! Three samplers (the G-buffer written by `gbuffer_fs`) and one
//! uniform block holding the camera position + FOUR point lights.
//!
//! raylib passes `struct Light lights[4]` as loose uniforms; std140
//! arrays-of-structs are a padding minefield, so we lay the lights out
//! STRUCT-OF-ARRAYS instead: one vec4 array for positions, one for
//! colors.  Two neat tricks fall out: the position's spare .w carries
//! the light's RADIUS-ish attenuation scale, and the color's spare .a
//! carries the ENABLED flag (0 = off) — no int-vs-bool layout drama,
//! and toggling a light is one float write.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("deferred_shading_common_io.zig");

/// Interpolated inputs from `deferred_shading_vs`.
pub const Inputs = common.Interp;

pub const max_lights: usize = 4;

/// The G-buffer, as written by the MRT pass (locations 0/1/2 there,
/// bindings 0..5 here — texture+sampler pairs in group 1).
pub const Samplers = struct {
    g_world_pos: shader.Sampler2D(.albedo, .{}),
    g_world_normal: shader.Sampler2D(.normal, .{}),
    g_albedo_spec: shader.Sampler2D(.emission, .{}),
};

/// FS uniform block (group 2, one binding), std140-exact by
/// construction: nothing but vec4s.
pub const Ubo = struct {
    /// Camera position in world space (.w spare); the Blinn-Phong
    /// specular needs the view direction per fragment.
    view_pos: Vec,
    /// xyz = light position (world); .w = attenuation scale (1 = the
    /// raylib-tuned falloff; bigger = light reaches further).
    light_pos: [max_lights]Vec,
    /// rgb = light color; .a = enabled (0 kills the light entirely).
    light_color: [max_lights]Vec,
};

/// Stage output — the lit fragment.
pub const Outputs = struct {
    final_color: Vec,
};
