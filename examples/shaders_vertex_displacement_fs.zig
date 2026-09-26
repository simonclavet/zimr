//! examples/shaders_vertex_displacement_fs.zig - lights the displaced surface:
//! Lambert diffuse over a height-graded colour (deep trough -> mid water ->
//! bright crest), plus a Blinn specular glint. The normal it shades with was
//! computed in the vertex shader from the heightfield samples.
const zm = @import("zm");
const Vec3 = zm.Vec3;
const dot = zm.dot;
const normalize = zm.normalize;
const smoothstep = zm.smoothstep;
const shader_io = @import("shaders_vertex_displacement_fs_io.zig");
const shader_externs = @import("shaders_vertex_displacement_fs_externs");

pub const Io = shader_externs.IoT(void);
pub const Out = shader_externs.Out;

/// Element-wise linear blend a + (b - a) * t (the DSL has no vector `mix`).
fn mixVec3(a: Vec3, b: Vec3, t: f32) Vec3 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;
    const nrm: Vec3 = normalize(Vec3{ io_in.frag_normal[0], io_in.frag_normal[1], io_in.frag_normal[2] });
    const light_dir: Vec3 = normalize(Vec3{ 0.45, 0.80, 0.40 });
    const n_dot_l: f32 = @max(dot(nrm, light_dir), 0.0);
    const ambient: f32 = 0.28;
    const diffuse: f32 = ambient + (1.0 - ambient) * n_dot_l;

    // Height-banded colour: deep trough -> mid water -> bright crest.
    const h: f32 = io_in.frag_world[3];
    const deep: Vec3 = .{ 0.03, 0.10, 0.32 };
    const midc: Vec3 = .{ 0.06, 0.42, 0.66 };
    const crest: Vec3 = .{ 0.82, 0.94, 1.00 };
    const c1: Vec3 = mixVec3(deep, midc, smoothstep(0.25, 0.55, h));
    const base: Vec3 = mixVec3(c1, crest, smoothstep(0.62, 0.90, h));

    // Blinn specular glint. Exponent 32 via five squarings - the DSL has no pow().
    const view: Vec3 = normalize(Vec3{ io_in.frag_view[0], io_in.frag_view[1], io_in.frag_view[2] });
    const half: Vec3 = normalize(Vec3{ light_dir[0] + view[0], light_dir[1] + view[1], light_dir[2] + view[2] });
    var spec: f32 = @max(dot(nrm, half), 0.0);
    spec = spec * spec;
    spec = spec * spec;
    spec = spec * spec;
    spec = spec * spec;
    spec = spec * spec;
    const glint: f32 = spec * 0.55;

    out.final_color = .{
        base[0] * diffuse + glint,
        base[1] * diffuse + glint,
        base[2] * diffuse + glint,
        1.0,
    };
    return out;
}

comptime {
    _ = shader_io;
    _ = shader_externs.installSpirvEntry(shaderMain);
}
