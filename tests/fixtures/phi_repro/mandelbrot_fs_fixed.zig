//! examples/mandelbrot_fs.zig - Mandelbrot fragment shader in Zig.
//!
//! Companion to `examples/mandelbrot.zig` (the CPU side).  Compiles
//! to SPIR-V via the Zig shader build pipeline, then through
//! `spirv-opt` / `spirv-cross` to GLSL ES 3.0, and is `@embedFile`'d
//! back into the host as `mandelbrot_fs.glsl`.
//!
//! Schema (Inputs / Outputs / Ubo) lives in `mandelbrot_fs_io.zig`.
//! Codegen reflects on that file to produce `mandelbrot_fs_externs`
//! (cache-side); the CPU host imports the io file directly.

const zm = @import("zm");
const shader_io = @import("mandelbrot_fs_io.zig");
const shader_externs = @import("mandelbrot_fs_externs");

pub const Io = shader_externs.IoT(shader_io.Ubo);
pub const Out = shader_externs.Out;

// ---- Helpers --------------------------------------------------------
// `pub fn` (NOT `pub inline fn`) - spirv-opt's `-O` inline pass does
// the work post-codegen.  Forcing inline at the Zig level breaks the
// SPIR-V structured-control-flow markers.
fn hsv2rgb(c: zm.Vec3) zm.Vec3 {
    const k: zm.Vec = zm.vec4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
    const cxyz: zm.Vec3 = zm.vec3(c[0], c[0], c[0]);
    const kxyz: zm.Vec3 = zm.vec3(k[0], k[1], k[2]);
    const sum: zm.Vec3 = cxyz + kxyz;
    const f: zm.Vec3 = zm.vec3(zm.fract(sum[0]), zm.fract(sum[1]), zm.fract(sum[2]));
    const six: zm.Vec3 = zm.vec3(6.0, 6.0, 6.0);
    const t: zm.Vec3 = f * six - zm.vec3(3.0, 3.0, 3.0);
    const p: zm.Vec3 = zm.vec3(@abs(t[0]), @abs(t[1]), @abs(t[2]));
    const p_clamped: zm.Vec3 = zm.vec3(
        zm.clamp01(p[0] - 1.0),
        zm.clamp01(p[1] - 1.0),
        zm.clamp01(p[2] - 1.0),
    );
    const kxxx: zm.Vec3 = zm.vec3(k[0], k[0], k[0]);
    const sat: zm.Vec3 = zm.vec3(c[1], c[1], c[1]);
    const mixed: zm.Vec3 = kxxx + (p_clamped - kxxx) * sat;
    const val: zm.Vec3 = zm.vec3(c[2], c[2], c[2]);
    return mixed * val;
}

// ---- Pure-logic kernel -----------------------------------------------
//
// Takes an `Io` by value (varying inputs + uniforms), returns an
// `Out` by value (stage outputs).  Compiles on every target Zig
// supports - SPIR-V backend produces a fragment shader, x86_64/wasm
// targets get callable Zig that `rlsw_shader.dispatchFragmentShader`
// runs per pixel.
//
// Pattern (see `src/notes/software_shaders.md`):
//   - The signature is `pub fn shaderMain(io: Io) Out` - return-by-
//     value is required by SPIR-V's Logical addressing model;
//     pointer-out params don't survive spirv-val.
//   - The name is `shaderMain`, NOT `main`.  Zig's `std.start.zig`
//     auto-exports a `_start()` symbol if the root module declares
//     `main`, and `_start` requires `callconv(.naked)` which the
//     SPIR-V backend rejects.  Using a different name keeps
//     std.start dormant.
pub fn shaderMain(io_in: Io) Out {
    var out: Out = undefined;

    // Pixel -> complex plane.  At u.zoom=1.0 the canvas height spans
    // 4.0 units; halving u.zoom doubles the span.  Y is flipped:
    // screen Y grows downward, imaginary axis grows upward.  The CPU
    // side's `screenToComplex` flips with the same sign so mouse
    // interactions (drag, zoom-about-cursor) land where the user
    // points.
    const frag: zm.Vec2 = io_in.frag_tex_coord * io_in.u.resolution;
    const half_res: zm.Vec2 = zm.vec2(io_in.u.resolution[0] * 0.5, io_in.u.resolution[1] * 0.5);
    const scale: f32 = 4.0 / (io_in.u.zoom * io_in.u.resolution[1]);
    const c: zm.Vec2 = zm.vec2(
        io_in.u.center[0] + (frag[0] - half_res[0]) * scale,
        io_in.u.center[1] - (frag[1] - half_res[1]) * scale,
    );

    // Mandelbrot iteration: z_{n+1} = z_n^2 + c.  `Complex` is a
    // Vec2 alias with `cmul` and native `+`.  Reads like the textbook
    // math; same GLSL output as a hand-rolled version (spirv-opt
    // inlines the `cmul` call).
    //
    // `escaped` is a u32 flag instead of `bool` - Zig's SPIR-V codegen
    // emits `bool` storage as `u1` / `uint8_t`, which WebGL2 rejects.
    // `+%=` is the wrapping increment; without it Zig emits an
    // overflow check.
    const c_complex: zm.Complex = c;
    var z: zm.Complex = zm.c_zero;
    var n: f32 = 0;
    var escaped: u32 = 0;
    var i: u32 = 0;
    while (i < 1024) : (i +%= 1) {
        if (@as(f32, @floatFromInt(i)) >= io_in.u.max_iter) {
            break;
        }
        // Escape radius^2 = 128 (|z| > ~11.3). Large enough that the
        // log-log smooth-iteration term below stays accurate, small enough
        // that squaring in cmandelbrot_step CANNOT overflow f32 to inf: a
        // bailout at |z|^2=256 (the old value) let z reach ~16, and on the
        // boundary the NEXT square plus accumulated growth could push cmul
        // to inf -> inf-inf = NaN -> `NaN > 256` is false -> escape never
        // fires -> the loop runs out with NaN -> the whole pixel renders
        // white (the turn-901 mandelbrot WHITE bug). 128 keeps every
        // intermediate finite on the no-spirv-opt WGSL path.
        if (zm.cnorm2(z) > 128.0) {
            escaped = 1;
            break;
        }
        z = zm.cmandelbrot_step(z, c_complex);
        n += 1.0;
    }

    if (escaped == 0) {
        out.out_color = zm.vec4(0, 0, 0, 1);
    } else {
        // Smooth iteration count.  Without this you get visible bands
        // at every integer escape boundary.
        const mod_z: f32 = zm.cabs(z);
        const nu: f32 = zm.log2(zm.log2(mod_z));
        const smoothed: f32 = n + 1.0 - nu;
        // clamp01 guards the smooth-iteration tail: a fast escape can
        // drive `smoothed` negative, and pow(negative, 0.4) is NaN -
        // which a GPU renders as a hole (the clear color shows through,
        // so the fractal looks absent).  Clamping keeps every pixel
        // finite and in-gamut.
        const t: f32 = zm.clamp01(smoothed / io_in.u.max_iter);

        // Hue cycles through spectrum; `pow(t, 0.4)` lifts the dark
        // tail so escape regions don't go pitch black.
        const col: zm.Vec3 = hsv2rgb(zm.vec3(0.85 + 0.4 * t, 0.7, zm.pow(t, 0.4)));
        out.out_color = zm.vec4(col[0], col[1], col[2], 1.0);
    }

    return out;
}

// ---- GPU entry-point installer --------------------------------------
//
// On SPIR-V targets this materializes an `export fn entry() callconv(
// .spirv_fragment)` wrapper that reads externs into Io, calls
// shaderMain, writes the returned Out's fields to extern outputs.
// On CPU targets this is a no-op - the caller (rlsw_shader.dispatch-
// FragmentShader) invokes shaderMain(io) directly per pixel.
comptime {
    _ = shader_externs.installSpirvEntry(shaderMain);
}
