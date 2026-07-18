//! src/shaders/shapes_filter_fs.zig — a user 2D shader, run over the ordinary 2D batch.
//!
//! raylib's `shaders_shapes_textures` draws shapes and a texture and puts SOME of them inside
//! `BeginShaderMode(grayscale)`. This is that shader.
//!
//! Note what it does NOT do: it never samples a render target, and it is not a post-process. It
//! is the fragment stage of the shapes pipeline itself, so it sees each primitive as it is
//! rasterized — a circle is grey because the circle's own fragments went through here.
const zm = @import("zm");
const Vec = zm.Vec;
const dot = zm.dot;
const clamp01 = zm.clamp01;
const shader_externs = @import("shapes_filter_fs_externs");

pub const Io = shader_externs.IoT(@import("shapes_filter_fs_io.zig").Ubo);
pub const Out = shader_externs.Out;
pub const TextureRef = shader_externs.TextureRef;

/// raylib's exact weights, from `resources/shaders/glsl330/grayscale.fs`.
///
/// These are Rec. 601 luma. Modern sRGB content technically wants Rec. 709
/// (0.2126, 0.7152, 0.0722), and the difference is visible on saturated reds and blues — but
/// this is a PORT, and matching raylib's output pixel for pixel is the point. A shader that
/// looked "more correct" than the thing it claims to reproduce would make the side-by-side a
/// lie.
///
/// What both have in common: they are not a flat 1/3 average. The eye is far more sensitive to
/// green than to blue, and averaging makes reds and blues come out muddily identical.
const luma_weights: Vec = .{ 0.299, 0.587, 0.114, 0.0 };

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // The exact same line the engine's own shapes shader runs: the texture sample times the
    // per-vertex tint. For an untextured shape the texture is 1x1 white, so this is the tint.
    const texel: Vec = io_in.texture0(io_in.frag_tex_coord);
    const base_color: Vec = texel * io_in.frag_color;

    const grey: f32 = dot(base_color, luma_weights);
    const grey_color: Vec = .{ grey, grey, grey, base_color[3] };

    // `mix` rather than a branch: a fragment shader that branches on a uniform still pays for
    // both sides on most hardware, and mixing lets the example fade the effect in and out
    // instead of snapping it.
    const amount: f32 = clamp01(io_in.u.params[0]);
    const mixed: Vec = base_color + (grey_color - base_color) * @as(Vec, @splat(amount));

    out.out_color = .{ mixed[0], mixed[1], mixed[2], base_color[3] };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
