//! src/shaders/decal_vs_io.zig — typed interface for the shader-projected decal
//! receiver vertex stage. Standard VS: the shared Cube3D camera UBO at group 0
//! (only the view-projection is read), two world-space attributes, two world
//! varyings. Body in `decal_vs.zig`.

const shader = @import("shader_interface");
const common = @import("decal_common_io.zig");

/// Vertex-buffer attributes: world-space position (@0) + world-space normal
/// (@1). The receiver mesh is uploaded with its model transform baked in.
pub const Attributes = struct {
    p: shader.Attr(.vec3, 0),
    n: shader.Attr(.vec3, 1),
};

/// group(0) binding(0): shared camera UBO — mirrors just the leading mat4x4 of
/// Cube3D's camera block (only the view-projection is used). The host binds
/// Cube3D's camera bind group here (`self.resources`).
pub const Ubo = struct {
    vp: [4]@Vector(4, f32) align(16),
};

/// Varyings to the FS — world position + world normal.
pub const Outputs = common.Interp;
