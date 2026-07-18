//! src/shaders/terrain_fs.zig — height-banded terrain material.
//!
//! Lambert (0.25 ambient floor) times a color read from a four-stop
//! height ramp: normalize the fragment's world Y into [0,1] across the
//! terrain's height range, then blend low→mid→hi→top across the three
//! segments.  Classic water/grass/rock/snow banding, entirely from
//! geometry — the point of the heightmap example is that the shape
//! carries the read with no texture at all.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const clamp01 = zm.clamp01;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("terrain_fs_io.zig");
const shader_externs = @import("terrain_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

fn rgb(v: Vec) Vec3 {
    return .{ v[0], v[1], v[2] };
}

fn mix3(a: Vec3, b: Vec3, t: f32) Vec3 {
    const tt: Vec3 = @splat(t);
    return a + (b - a) * tt;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Height ramp: normalize world Y across [min_y, max_y].
    const min_y: f32 = io_in.u.params[0];
    const max_y: f32 = io_in.u.params[1];
    const span: f32 = @max(max_y - min_y, 0.0001);
    const h: f32 = clamp01((io_in.frag_world_pos[1] - min_y) / span);

    // Three segments over four stops (0, 1/3, 2/3, 1).
    const lo: Vec3 = rgb(io_in.u.band_lo);
    const mid: Vec3 = rgb(io_in.u.band_mid);
    const hi: Vec3 = rgb(io_in.u.band_hi);
    const top: Vec3 = rgb(io_in.u.band_top);
    var base: Vec3 = undefined;
    if (h < 0.3333) {
        base = mix3(lo, mid, h / 0.3333);
    } else if (h < 0.6666) {
        base = mix3(mid, hi, (h - 0.3333) / 0.3333);
    } else {
        base = mix3(hi, top, (h - 0.6666) / 0.3334);
    }

    // Lambert against the sun, 0.25 ambient floor.
    const normal: Vec3 = normalize(io_in.frag_world_normal);
    const light_dir: Vec3 = normalize(Vec3{
        io_in.u.light_dir[0],
        io_in.u.light_dir[1],
        io_in.u.light_dir[2],
    });
    const n_dot_l: f32 = @max(dot(normal, light_dir), 0.0);
    const lighting: f32 = 0.25 + 0.75 * n_dot_l;

    out.final_color = .{ base[0] * lighting, base[1] * lighting, base[2] * lighting, 1.0 };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
