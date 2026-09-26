//! examples/bloom_blur_fs.zig - bloom separable-Gaussian blur FS body.
//!
//! A 5-tap Gaussian along the per-pass `dir` (already scaled by texel size in
//! the UBO): centre tap plus two symmetric pairs at the standard linear-
//! sampling offsets. The same compiled shader runs both the horizontal and
//! vertical passes - only the UBO's `dir` differs. Schema in
//! `bloom_blur_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const shader_externs = @import("bloom_blur_fs_externs");

pub const Io = shader_externs.IoT(shader_externs.Ubo);
pub const Out = shader_externs.Out;

// 5-tap Gaussian: centre weight + two symmetric pairs, with the standard
// linear-sampled offsets that fetch two texels per tap.
//
// NORMALIZED so w0 + 2*w1 + 2*w2 == 1.0. These are the inner three weights of a
// 9-tap Gaussian; used as-is (a 5-tap) they summed to ~0.859, so every blur pass
// lost ~14% brightness - compounding to a much dimmer bloom across the x4 passes.
// Dividing each by that 0.859 sum restores an energy-preserving blur.
const w0: f32 = 0.264150;
const w1: f32 = 0.226413;
const w2: f32 = 0.141508;
const o1: f32 = 1.3846153;
const o2: f32 = 3.2307692;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const uv: Vec2 = io_in.v_uv;
    const d: Vec = io_in.u.dir;
    const s1: Vec2 = .{ d[0] * o1, d[1] * o1 };
    const s2: Vec2 = .{ d[0] * o2, d[1] * o2 };

    // All samples happen here at shaderMain's top (uniform control flow, and the
    // linter requires samples out of helpers), then are weighted and summed.
    const c0: Vec = io_in.src(uv);
    const cp1: Vec = io_in.src(.{ uv[0] + s1[0], uv[1] + s1[1] });
    const cm1: Vec = io_in.src(.{ uv[0] - s1[0], uv[1] - s1[1] });
    const cp2: Vec = io_in.src(.{ uv[0] + s2[0], uv[1] + s2[1] });
    const cm2: Vec = io_in.src(.{ uv[0] - s2[0], uv[1] - s2[1] });

    out.final_color = .{
        c0[0] * w0 + (cp1[0] + cm1[0]) * w1 + (cp2[0] + cm2[0]) * w2,
        c0[1] * w0 + (cp1[1] + cm1[1]) * w1 + (cp2[1] + cm2[1]) * w2,
        c0[2] * w0 + (cp1[2] + cm1[2]) * w1 + (cp2[2] + cm2[2]) * w2,
        1.0,
    };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
