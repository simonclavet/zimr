//! ssao_blur_fs — separable BILATERAL blur for the SSAO buffer.
//!
//! Seven taps at stride 2 along one axis, weighted by how much each neighbour looks like it
//! belongs to the same surface:
//!
//!     w = exp(-dist2 * falloff) * pow(max(dot(n, n_centre), 0), normal_power)
//!
//! ★ THE TWO WEIGHTS DO DIFFERENT JOBS. The POSITION term rejects a neighbour that is simply
//! far away in world space — the ground behind a character, seen right next to it on screen.
//! The NORMAL term rejects one that is close but facing elsewhere — the two sides of a sharp
//! crease, which are adjacent in space and must not average together. Either alone leaves a
//! visible class of bleed.
//!
//! ★ EVERY SAMPLE USES `...Level(uv, 0)`. Implicit-LOD sampling needs screen-space derivatives
//! and is illegal under non-uniform control flow; the tap loop is unrolled with `inline for`
//! and samples explicitly, exactly as `ssao_fs` does. See `zimrlint`'s `sampler-in-branch`.
//!
//! ★ COVERAGE IS A MULTIPLIER, NOT A BRANCH. A tap that landed on background contributes zero
//! weight rather than being skipped, keeping the shader branch-free.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const dot = zm.dot;
const normalize = zm.normalize;
const pow = zm.pow;
const float = zm.float;
const shader_io = @import("ssao_blur_fs_io.zig");
const shader_externs = @import("ssao_blur_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// Taps per pass. Odd so the centre is included; 7 at stride 2 reaches +/-6 texels, which is
/// enough to hide a 9-sample spiral's noise without softening genuine contact shadows.
const tap_count: usize = 7;

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const uv: Vec2 = io_in.frag_uv;

    const texel_x: f32 = io_in.u.step[0];
    const texel_y: f32 = io_in.u.step[1];
    const axis_x: f32 = io_in.u.step[2];
    const axis_y: f32 = io_in.u.step[3];
    const falloff: f32 = io_in.u.weights[0];
    const normal_power: f32 = io_in.u.weights[1];

    const centre_pos_texel: Vec = io_in.g_world_posLevel(uv, 0.0);
    const centre_pos: Vec = .{ centre_pos_texel[0], centre_pos_texel[1], centre_pos_texel[2], 0 };
    const centre_nrm_texel: Vec = io_in.g_world_normalLevel(uv, 0.0);
    // Raw normal: `gbuffer_fs` writes it unencoded into an rgba16-float target.
    // Named before normalising: an anonymous literal does not coerce into a generic parameter.
    const centre_n_raw: Vec = .{
        centre_nrm_texel[0],
        centre_nrm_texel[1],
        centre_nrm_texel[2],
        0,
    };
    const centre_n: Vec = normalize(centre_n_raw);
    const covered: f32 = if (centre_pos_texel[3] < 0.5) 0.0 else 1.0;

    var sum: f32 = 0.0;
    var weight_sum: f32 = 0.0;
    inline for (0..tap_count) |ti| {
        // -6, -4, -2, 0, 2, 4, 6
        const offset: f32 = (float(ti) - 3.0) * 2.0;
        const suv: Vec2 = .{
            uv[0] + axis_x * offset * texel_x,
            uv[1] + axis_y * offset * texel_y,
        };
        const s_ao: Vec = io_in.srcLevel(suv, 0.0);
        const s_pos_texel: Vec = io_in.g_world_posLevel(suv, 0.0);
        const s_nrm_texel: Vec = io_in.g_world_normalLevel(suv, 0.0);

        const d: Vec = .{
            s_pos_texel[0] - centre_pos[0],
            s_pos_texel[1] - centre_pos[1],
            s_pos_texel[2] - centre_pos[2],
            0,
        };
        const dist2: f32 = dot(d, d);
        const s_n_raw: Vec = .{ s_nrm_texel[0], s_nrm_texel[1], s_nrm_texel[2], 0 };
        const s_n: Vec = normalize(s_n_raw);
        const n_align: f32 = @max(dot(s_n, centre_n), 0.0);

        const s_covered: f32 = if (s_pos_texel[3] < 0.5) 0.0 else 1.0;
        const w: f32 =
            @exp(-dist2 * falloff) * pow(n_align, normal_power) * s_covered;
        sum += s_ao[0] * w;
        weight_sum += w;
    }

    // A centre with no usable neighbours keeps its own value rather than dividing by zero.
    const blurred: f32 = if (weight_sum > 1.0e-5)
        sum / weight_sum
    else
        io_in.srcLevel(uv, 0.0)[0];
    // Background stays fully open.
    const result: f32 = blurred * covered + (1.0 - covered);
    out.blurred = .{ result, result, result, 1.0 };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
