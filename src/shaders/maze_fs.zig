//! src/shaders/maze_fs.zig - face-shaded maze material.
//!
//! Pick a base color from the fragment's world normal (which axis it
//! faces most strongly), then apply Lambert with a 0.35 ambient floor.
//! Cube tops/floor read as one tone, undersides/ceiling another, and
//! the two wall orientations (+/-X vs +/-Z) get their own colors so corners
//! and corridors are legible from any angle - all from the geometry,
//! no texture. Same source compiles for SPIR-V (-> WGSL -> GPU) and
//! wasm32 (-> CPU). Schema lives in `maze_fs_io.zig`.

const zm = @import("zm");
const Vec = zm.Vec;
const Vec3 = zm.Vec3;
const clamp01 = zm.clamp01;
const dot = zm.dot;
const normalize = zm.normalize;
const shader_io = @import("maze_fs_io.zig");
const shader_externs = @import("maze_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

fn rgb(v: Vec) Vec3 {
    return .{ v[0], v[1], v[2] };
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const n: Vec3 = normalize(io_in.frag_world_normal);
    const ax: f32 = @abs(n[0]);
    const ay: f32 = @abs(n[1]);
    const az: f32 = @abs(n[2]);

    // Choose the color of the axis this face points along most.
    var base: Vec3 = undefined;
    if (ay >= ax and ay >= az) {
        // Up vs down.
        base = if (n[1] >= 0.0) rgb(io_in.u.col_top) else rgb(io_in.u.col_bottom);
    } else if (ax >= az) {
        base = rgb(io_in.u.col_wall_x);
    } else {
        base = rgb(io_in.u.col_wall_z);
    }

    // Lambert against the sun, 0.35 ambient floor.
    const light_dir: Vec3 = normalize(Vec3{
        io_in.u.light_dir[0],
        io_in.u.light_dir[1],
        io_in.u.light_dir[2],
    });
    const n_dot_l: f32 = clamp01(dot(n, light_dir));
    const lighting: f32 = 0.35 + 0.65 * n_dot_l;

    out.final_color = .{ base[0] * lighting, base[1] * lighting, base[2] * lighting, 1.0 };
    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
