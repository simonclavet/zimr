//! examples/shaders_vertex_displacement_vs.zig - the vertex shader that turns a
//! flat grid into a living surface by sampling a Perlin heightfield IN THE
//! VERTEX STAGE. `heightLevel` is the explicit-LOD accessor (->
//! textureSampleLevel), which needs no derivatives and is legal in the vertex
//! stage. Three heights per vertex (the vertex plus two neighbours) give the
//! world-space surface normal, so the surface is lit, not merely displaced.
//!
//! The three fetches are factored into `heightAt`. That is allowed because
//! `heightLevel` is explicit-LOD (uniformity-exempt); the `sampler-in-helper`
//! lint only forbids implicit-LOD samples in helpers (a fragment-stage rule).
const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const normalize = zm.normalize;
const mulMatPoint = zm.mulMatPoint;
const shader_io = @import("shaders_vertex_displacement_vs_io.zig");
const shader_externs = @import("shaders_vertex_displacement_vs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

/// Height at `uv`: two octaves of the heightfield, scrolled in different
/// directions by time `t` - scrolling a static texture is what animates the
/// swells. The `repeat` sampler tiles the noise, so `uv * freq` may exceed 1.
fn heightAt(io_in: Io, uv: Vec2, t: f32, freq: f32) f32 {
    const uv1: Vec2 = .{ uv[0] * freq + t * 0.030, uv[1] * freq + t * 0.021 };
    const uv2: Vec2 = .{ uv[0] * freq * 2.03 - t * 0.017, uv[1] * freq * 2.03 + t * 0.034 };
    const s1: Vec = io_in.heightLevel(uv1, 0.0);
    const s2: Vec = io_in.heightLevel(uv2, 0.0);
    return s1[0] * 0.65 + s2[0] * 0.35;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const uv: Vec2 = io_in.vertex_uv;
    const t: f32 = io_in.u.wave[0];
    const amp: f32 = io_in.u.wave[1];
    const freq: f32 = io_in.u.wave[2];
    const texel: f32 = io_in.u.wave[3];
    const slope: f32 = io_in.u.cam[3];

    const h0: f32 = heightAt(io_in, uv, t, freq);
    const hx: f32 = heightAt(io_in, .{ uv[0] + texel, uv[1] }, t, freq);
    const hz: f32 = heightAt(io_in, .{ uv[0], uv[1] + texel }, t, freq);

    const world_x: f32 = io_in.vertex_position[0];
    const world_z: f32 = io_in.vertex_position[1];
    const world_y: f32 = h0 * amp;
    const wp: Vec3 = .{ world_x, world_y, world_z };

    // The surface is y = h(x,z); its normal is normalize(-dy/dx, 1, -dy/dz).
    // `slope` folds amplitude and the uv->world scale so the finite differences
    // read as true world slopes.
    const dydx: f32 = (hx - h0) * slope;
    const dydz: f32 = (hz - h0) * slope;
    const nrm: Vec3 = normalize(Vec3{ -dydx, 1.0, -dydz });

    const view: Vec3 = normalize(Vec3{
        io_in.u.cam[0] - world_x,
        io_in.u.cam[1] - world_y,
        io_in.u.cam[2] - world_z,
    });

    out.position = mulMatPoint(io_in.u.mvp, wp);
    out.frag_normal = .{ nrm[0], nrm[1], nrm[2], 0.0 };
    out.frag_world = .{ world_x, world_y, world_z, h0 };
    out.frag_view = .{ view[0], view[1], view[2], 0.0 };
    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
