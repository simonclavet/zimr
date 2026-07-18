//! src/shaders/depth_vs_io.zig — typed interface for the depth-in-red
//! vertex shader. Companion to `depth_vs.zig`.
//!
//! One attribute (position — the only thing a depth pass needs; extra
//! mesh attributes in the bound buffer are simply not consumed) and one
//! uniform block: the combined transform plus the linearization window
//! and mode selector. Keeping everything in a single group-0 UBO means
//! the consuming pipeline needs exactly one bind group.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("depth_common_io.zig");

/// Vertex attributes. Only position (location 0) is read; it matches
/// the leading `vec3` of every mesh vertex layout in the engine.
pub const Attributes = struct {
    vertex_position: shader.Attr(.vec3, 0),
};

/// Single uniform block (group 0, binding 0). std140: the mat4 and the
/// vec4 are each 16-byte aligned; the scalar tail (mode + 3 pad ints)
/// fills one 16-byte row, so @sizeOf == 96 with no interior padding.
/// The host `Resources` mirror must match byte-for-byte.
pub const Ubo = struct {
    /// `light_proj*light_view*model` (shadow pass) or camera MVP (viz).
    mvp: [4]Vec,
    /// {cam_near, cam_far, viz_near, viz_far}. cam_* linearize the NDC
    /// depth to a view-space distance; viz_* is the window that
    /// distance is normalized against for display contrast.
    params: Vec = .{ 0, 1, 0, 1 },
    /// 0 = raw `ndc_z*0.5+0.5` (shadow map); nonzero = linearized,
    /// normalized grayscale (visualisation).
    mode: i32 = 0,
    pad0: i32 = 0,
    pad1: i32 = 0,
    pad2: i32 = 0,
};

/// Varying outputs — aliases the shared `Interp`.
pub const Outputs = common.Interp;
