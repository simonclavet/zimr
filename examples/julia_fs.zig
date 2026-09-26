//! examples/julia_inline_fs.zig - Julia-set fragment shader with
//! iface co-located in the same file (Inputs / Outputs / Ubo at
//! the top, body below).  See `mandel_inline_fs.zig` for the
//! mechanism; this is its companion.
//!
//! Same iteration kernel as `mandel_inline_fs.zig` (`z' = z^2 + c`
//! via `zm.cmandelbrot_step`).  The only difference is the
//! per-pixel initial state: julia uses pixel as `z_0` and the UBO
//! `julia_c` as the constant; mandelbrot uses 0 as `z_0` and pixel
//! as the constant.

const zm = @import("zm");
const Complex = zm.Complex;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const Vec3 = zm.Vec3;
const cabs = zm.cabs;
const clamp01 = zm.clamp01;
const cmandelbrot_step = zm.cmandelbrot_step;
const cnorm2 = zm.cnorm2;
const float = zm.float;
const fract = zm.fract;
const log2 = zm.log2;
const pow = zm.pow;
const vec2 = zm.vec2;
const vec3 = zm.vec3;
const vec4 = zm.vec4;
const shader_io = @import("julia_fs_io.zig");
const shader_externs = @import("julia_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

fn hsv2rgb(c: Vec3) Vec3 {
    const k: Vec = vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    const cxyz: Vec3 = vec3(c[0], c[0], c[0]);
    const kxyz: Vec3 = vec3(k[0], k[1], k[2]);
    const sum: Vec3 = cxyz + kxyz;
    const f: Vec3 = vec3(fract(sum[0]), fract(sum[1]), fract(sum[2]));
    const six: Vec3 = vec3(6.0, 6.0, 6.0);
    const t: Vec3 = f * six - vec3(3.0, 3.0, 3.0);
    const p: Vec3 = vec3(@abs(t[0]), @abs(t[1]), @abs(t[2]));
    const p_clamped: Vec3 = vec3(
        clamp01(p[0] - 1.0),
        clamp01(p[1] - 1.0),
        clamp01(p[2] - 1.0),
    );
    const kxxx: Vec3 = vec3(k[0], k[0], k[0]);
    const sat: Vec3 = vec3(c[1], c[1], c[1]);
    const mixed: Vec3 = kxxx + (p_clamped - kxxx) * sat;
    const val: Vec3 = vec3(c[2], c[2], c[2]);
    return mixed * val;
}

pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    const frag: Vec2 = io_in.frag_tex_coord * io_in.u.resolution;
    const half_res: Vec2 = vec2(io_in.u.resolution[0] * 0.5, io_in.u.resolution[1] * 0.5);
    const scale: f32 = 4.0 / (io_in.u.zoom * io_in.u.resolution[1]);
    const pixel_complex: Vec2 = vec2(
        io_in.u.center[0] + (frag[0] - half_res[0]) * scale,
        io_in.u.center[1] - (frag[1] - half_res[1]) * scale,
    );

    const julia_c: Complex = io_in.u.julia_c;
    var z: Complex = pixel_complex;
    var n: f32 = 0;
    var escaped: u32 = 0;
    var i: u32 = 0;
    while (i < 1024) : (i +%= 1) {
        if (float(i) >= io_in.u.max_iter) {
            break;
        }
        if (cnorm2(z) > 128.0) {
            // Escape radius^2 128 (not 256): squaring in cmandelbrot_step can
            // overflow f32 to inf at the larger radius -> inf-inf = NaN ->
            // `NaN > R` is false -> escape never fires -> white. (N6 mandelbrot
            // lesson; 128 keeps every cmul intermediate finite on the
            // no-spirv-opt WGSL path while staying good for log-log smoothing.)
            escaped = 1;
            break;
        }
        z = cmandelbrot_step(z, julia_c);
        n += 1.0;
    }

    if (escaped == 0) {
        out.out_color = vec4(0, 0, 0, 1);
    } else {
        const mod_z: f32 = cabs(z);
        const nu: f32 = log2(log2(mod_z));
        const smoothed: f32 = n + 1.0 - nu;
        const t: f32 = smoothed / io_in.u.max_iter;
        const col: Vec3 = hsv2rgb(vec3(0.55 + 0.3 * t, 0.7, pow(t, 0.4)));
        out.out_color = vec4(col[0], col[1], col[2], 1.0);
    }

    return out;
}

comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
