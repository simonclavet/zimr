//! tests/math_full_smoke_fs.zig — Stage 3 smoke shader.
//! Imports `math` and exercises a representative cross-section of
//! its functions on SPIR-V.  If this compiles cleanly through the
//! SPIR-V → spirv-opt → spirv-cross pipeline, the covered subset
//! of math.zig is GPU-portable.
//!
//! See `src/notes/math_unification.md` Stage 3 entry.  Supersedes
//! the earlier `math_intrinsic_smoke_fs` (the intrinsic veneer was
//! inlined into math.zig at the end of Stage 3).

const zm = @import("zm");

extern const frag_tex_coord: zm.Vec2 addrspace(.input);
extern var out_color: zm.Vec addrspace(.output);

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    const u: f32 = frag_tex_coord[0];
    const v: f32 = frag_tex_coord[1];

    // Vector arithmetic + splat + swizzle.
    const a: zm.Vec = zm.f32x4(u, v, 0.0, 1.0);
    const b: zm.Vec = zm.splat(0.5);
    const c: zm.Vec = a + b;
    const sw: zm.Vec = zm.swizzle(c, .z, .y, .x, .w);

    // Geometric primitives.  cross3 was the Stage 3 finding that
    // forced rewriting it to avoid `andInt` (vector-level @bitCast
    // is rejected by SPIR-V's Logical addressing model).
    const x_axis: zm.Vec = zm.f32x4(1.0, 0.0, 0.0, 0.0);
    const y_axis: zm.Vec = zm.f32x4(0.0, 1.0, 0.0, 0.0);
    const n: zm.Vec = zm.cross3(x_axis, y_axis);
    const dot_val: f32 = zm.dot3(a, n);
    const n_normalized: zm.Vec = zm.normalize3(c);

    // Scalar trig — routes through the polynomial fallbacks
    // (atan2Scalar, asinScalar) inlined into math.zig at Stage 3.
    const angle: f32 = zm.atan2Rad(@as(f32, v), @as(f32, u));
    const asin_val: f32 = zm.asinRad(@as(f32, u * 0.5));

    // NOTE: Vector trig (zm.sinRad/cos/atan on Vec/F32x8/F32x16) is
    // NOT yet GPU-portable.  zmath's sin32xN body uses `andInt` /
    // `orInt` / `xorInt` for sign-bit manipulation; those go through
    // `@bitCast(Vec, @Vector(4, u32))` which SPIR-V's Logical
    // addressing model rejects.  Rewriting the int-op family (33
    // call sites) to use componentwise scalar bitcasts is post-plan
    // work.  For now, shader code that needs trig should use the
    // SCALAR forms (atan2Scalar / asinScalar are reachable through
    // the scalar dispatch in zm.atan2Rad(f32, f32) / zm.asinRad(f32)).

    // Matrix math — the column-major M*v API landed in Stage 2.
    const t: zm.Mat = zm.translation(u * 10.0, v * 10.0, 0.0);
    const m: zm.Mat = zm.mulMat(t, zm.identity());
    const transformed: zm.Vec = zm.mulMatVec(m, a);
    const point_transformed: zm.Vec = zm.mulMatPoint(m, zm.Vec3{ u, v, 0.0 });

    // Complex arithmetic (Phase 0.5 of math-unification).  Exercises
    // cmul + native `+` (the headline mandelbrot one-liner shape) and
    // cnorm2 (the iteration escape test).  All SPIR-V-portable —
    // Complex is just `@Vector(2, f32)` so `+` lowers to a single
    // `OpFAdd`; cmul becomes 4 OpFMul + 1 OpFSub + 1 OpFAdd + an
    // OpCompositeConstruct.
    const c_param: zm.Complex = zm.complex(u - 0.5, v - 0.5);
    var cz: zm.Complex = zm.c_zero;
    cz = zm.cmandelbrot_step(cz, c_param);
    cz = zm.cmandelbrot_step(cz, c_param);
    const escape_test: f32 = zm.cnorm2(cz);

    // Combine so the optimizer doesn't eliminate everything.
    const r_out: f32 = (transformed[0] + point_transformed[1] + dot_val + n_normalized[0] + angle + asin_val + escape_test) * 0.01;
    const g_out: f32 = (sw[0] + n[1] + cz[0]) * 0.1;
    out_color = zm.f32x4(r_out, g_out, 0.0, 1.0);
}
