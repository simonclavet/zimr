//! ssao_fs - screen-space ambient occlusion from the G-buffer's world position and normal.
//!
//! Scalable Ambient Obscurance (McGuire, Mara, Luebke). For each pixel, sample a spiral of
//! neighbours, and for each one ask how much it occludes the centre:
//!
//!     v   = sample_view_pos - centre_view_pos
//!     vv  = dot(v, v)
//!     vn  = dot(v, centre_normal) - bias
//!     f   = max(radius*radius - vv, 0)
//!     occ += f*f*f * max(vn / (0.001 + vv), 0)
//!
//! * THE CUBIC FALLOFF IS THE POINT. A linear one lets geometry that merely passes behind a
//! surface darken it; cubing makes occlusion vanish smoothly at the radius, so a distant wall
//! contributes nothing and a nearby crease contributes strongly.
//!
//! * WORLD POSITIONS IN, VIEW-SPACE MATH. The G-buffer stores world position, but occlusion is
//! computed after transforming into view space: `radius` then means a fixed distance from the
//! camera rather than something that changes meaning as the scene moves.
//!
//! * THE ALPHA CHANNEL OF `g_world_pos` IS THE COVERAGE FLAG. Background pixels were never
//! written by the G-buffer pass, so their position is garbage; they contribute nothing rather
//! than occluding the sky.
//!
//! -- ** EVERY SAMPLE USES `...Level(uv, 0)`, NOT `...(uv)` --
//!
//! WGSL rejects an IMPLICIT-LOD sample (`textureSample`) reached through non-uniform control
//! flow: it needs screen-space derivatives, which are only defined when neighbouring lanes
//! agree on the path taken. SSAO samples inside a loop by its very nature, so implicit LOD is
//! not available to it - and `zimrlint`'s `sampler-in-branch` rule catches this at build time
//! rather than leaving it to a Tint error at runtime.
//!
//! `sampleLevel` lowers to `textureSampleLevel`, which takes an explicit LOD and therefore
//! needs no derivatives. The G-buffer has no mips, so level 0 is the only correct choice
//! anyway. **This is the standard way to write any loop that samples.**

const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const dot = zm.dot;
const normalize = zm.normalize;
const clamp = zm.clamp;
const float = zm.float;
const shader_io = @import("ssao_fs_io.zig");
const shader_externs = @import("ssao_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// How many spiral samples. Nine is GenoView's count: enough that the blur can clean up the
/// remaining noise, few enough to stay cheap at full resolution.
const sample_count: usize = 9;

/// Transform a world point by a row-major matrix stored as four rows.
fn xformPoint(m: [4]Vec, p: Vec) Vec {
    const x: Vec = @splat(p[0]);
    const y: Vec = @splat(p[1]);
    const z: Vec = @splat(p[2]);
    return m[0] * x + m[1] * y + m[2] * z + m[3];
}

/// Transform a world direction - no translation row.
fn xformDir(m: [4]Vec, d: Vec) Vec {
    const x: Vec = @splat(d[0]);
    const y: Vec = @splat(d[1]);
    const z: Vec = @splat(d[2]);
    return m[0] * x + m[1] * y + m[2] * z;
}

/// A cheap per-pixel hash, so neighbouring pixels start their spiral at different angles. Two
/// pixels sharing a start angle sample the same neighbours and band together.
///
/// -- ** WHY THE PIXEL COORDS ARE FOLDED FIRST --
///
/// The obvious hash - `fract(px * py + px * 0.5)` - DIES AT SCALE. At 1024x1024, `px * py`
/// reaches ~1e6, where consecutive f32 values are ~0.06 apart. Taking `mod 1.0` of a number
/// that coarse yields a handful of distinct results instead of a smooth spread, so whole
/// regions share one start angle and the AO comes out in HORIZONTAL STREAKS rather than noise.
///
/// Folding into a 64-pixel tile keeps the arithmetic where f32 still has precision to spare
/// (~7e-6 spacing at these magnitudes), and the R2 low-discrepancy constants spread the tile's
/// angles evenly. A repeating 64-pixel pattern is invisible after the blur, whereas a
/// quantised one is not.
fn spiralStart(uv: Vec2, w: f32, h: f32) f32 {
    const px: f32 = @mod(uv[0] * w, 64.0);
    const py: f32 = @mod(uv[1] * h, 64.0);
    const r2: f32 = @mod(px * 0.7548776662 + py * 0.5698402909, 1.0);
    return r2 * 6.2831853;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const uv: Vec2 = io_in.frag_uv;

    const centre_texel: Vec = io_in.g_world_posLevel(uv, 0.0);
    // * COVERAGE AS A MULTIPLIER, NOT A BRANCH. The sky needs to come out fully open, but an
    // early return would put the samples below under non-uniform control flow. Folding
    // coverage into the arithmetic keeps the whole shader branch-free.
    const covered: f32 = if (centre_texel[3] < 0.5) 0.0 else 1.0;

    const view: [4]Vec = io_in.u.view;
    const radius: f32 = io_in.u.params[0];
    const bias: f32 = io_in.u.params[1];
    const intensity: f32 = io_in.u.params[2];
    const turns: f32 = io_in.u.spiral[0];
    const inv_w: f32 = io_in.u.spiral[1];
    const inv_h: f32 = io_in.u.spiral[2];

    const centre_v: Vec = xformPoint(view, .{ centre_texel[0], centre_texel[1], centre_texel[2], 1 });
    const nrm_texel: Vec = io_in.g_world_normalLevel(uv, 0.0);
    // * NO `*2-1` DECODE. `gbuffer_fs` writes the RAW world normal into an rgba16-FLOAT
    // target, which stores negatives directly - there is no 0..1 encoding to undo. Decoding
    // one anyway turned (0,1,0) into (-1,1,-1): every surface faced a direction it does not,
    // so the `vn` occlusion term was noise and the output was not AO at all.
    //
    // * The unsigned encoding is what an rgba8 normal target WOULD need. Reading the target's
    // FORMAT before writing the decode would have settled it in one look.
    const centre_n: Vec = normalize(xformDir(view, .{
        nrm_texel[0],
        nrm_texel[1],
        nrm_texel[2],
        0,
    }));

    // The spiral shrinks in SCREEN space with distance, so a surface far from the camera does
    // not get sampled across half the frame. 0.35 is a screen-space cap in UV units.
    const screen_radius: f32 = @min(radius / @max(-centre_v[2], 0.05), 0.35);
    const start: f32 = spiralStart(uv, 1.0 / @max(inv_w, 1.0e-6), 1.0 / @max(inv_h, 1.0e-6));

    var occlusion: f32 = 0.0;
    // * `inline for`, NOT a runtime loop. The SPIR-V -> WGSL transpiler rejects the loop form
    // here; unrolling at comptime emits straight-line code, which also removes the last trace
    // of non-uniform control flow around the samples. Nine iterations is small enough that the
    // unrolled shader stays reasonable.
    inline for (0..sample_count) |si| {
        const fi: f32 = (float(si) + 0.5) / float(sample_count);
        const angle: f32 = fi * turns * 6.2831853 + start;
        const offset: Vec2 = .{
            @cos(angle) * fi * screen_radius,
            @sin(angle) * fi * screen_radius,
        };
        const suv: Vec2 = .{ uv[0] + offset[0], uv[1] + offset[1] };
        const s_texel: Vec = io_in.g_world_posLevel(suv, 0.0);
        // Same trick for an uncovered NEIGHBOUR: weight it to zero instead of skipping it.
        const s_covered: f32 = if (s_texel[3] < 0.5) 0.0 else 1.0;
        const s_v: Vec = xformPoint(view, .{ s_texel[0], s_texel[1], s_texel[2], 1 });
        const v: Vec = .{ s_v[0] - centre_v[0], s_v[1] - centre_v[1], s_v[2] - centre_v[2], 0 };
        const vv: f32 = dot(v, v);
        const vn: f32 = dot(v, centre_n) - bias;
        const f: f32 = @max(radius * radius - vv, 0.0);
        occlusion += s_covered * f * f * f * @max(vn / (0.001 + vv), 0.0);
    }

    const r6: f32 = radius * radius * radius * radius * radius * radius;
    const norm: f32 = intensity / (@max(r6, 1.0e-6) * float(sample_count));
    const ao: f32 = clamp(1.0 - occlusion * norm * 5.0, 0.0, 1.0);
    // Uncovered pixels fall back to 1 (fully open) via the coverage multiplier.
    const final_ao: f32 = ao * covered + (1.0 - covered);
    out.occlusion = .{ final_ao, final_ao, final_ao, 1.0 };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
