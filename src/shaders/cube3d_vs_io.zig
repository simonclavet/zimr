//! src/shaders/cube3d_vs_io.zig — typed interface for the immediate-mode 3D
//! batch vertex shader. Companion to `cube3d_vs.zig`.
//!
//! Immediate-batch model: every 3D primitive (cube, grid line, …) is
//! transformed to WORLD space on the CPU and appended to one vertex stream,
//! drawn in a single call. So the only uniform is the camera's view-projection
//! (set once per beginMode3D), and the per-primitive colour rides on the
//! vertices. This sidesteps the single-UBO hazard of per-draw rendering (N
//! draws all reading the last-written transform) — there is no per-primitive
//! uniform at all. The `Ubo`-struct form (`io_in.u.<field>`) emits one
//! combined binding matching a single-UBO `Resources` host.

const shader = @import("shader_interface");
const common = @import("cube3d_common_io.zig");

/// Vertex attributes: world-space position + world-space normal + the
/// primitive's colour. Locations match the interleaved P3 + N3 + C4 batch
/// vertex in `src/draw3d.zig`.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
    vertex_normal: shader.Attr(.vec3, 1),
    vertex_color: shader.Attr(.vec4, 2),
};

/// Single uniform block (group 0, binding 0): the camera view-projection,
/// set once per beginMode3D. mat4 == [4]@Vector(4,f32) (std140 columns). The
/// host `Resources` schema in `src/draw3d.zig` mirrors this struct.
pub const Ubo = struct {
    view_projection: [4]@Vector(4, f32),
};

/// Varying outputs to the fragment shader — aliases the shared `Interp`.
pub const Outputs = common.Interp;
