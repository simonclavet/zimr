//! src/shaders/billboard_vs_io.zig — typed interface for the textured-3D /
//! billboard vertex shader. Reads the shared Cube3D camera UBO (only the
//! view-projection), passes the three vertex attributes through to the
//! fragment stage. Body in `billboard_vs.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const shader = @import("shader_interface");
const common = @import("billboard_common_io.zig");

/// Vertex-buffer attributes (TexVertex: position @0, uv @1, colour @2).
pub const Attributes = struct {
    p: shader.Attr(.vec3, 0),
    uv: shader.Attr(.vec2, 1),
    col: shader.Attr(.vec4, 2),
};

/// group(0) binding(0): shared camera UBO. Only the view-projection is used, so
/// the block mirrors just the leading `mat4x4` of Cube3D's camera block. The
/// host binds Cube3D's camera bind group here (`resources.bg_layouts[0]`).
pub const Ubo = struct {
    vp: [4]Vec align(16),
};

/// Varyings to the fragment stage — interpolated uv + vertex colour.
pub const Outputs = common.Interp;
