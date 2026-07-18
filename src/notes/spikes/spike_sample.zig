const zm = @import("zm");
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

// Spike: prove the @SpirvType sampled-image SAMPLE operation assembles to
// SPIR-V. The prior spike got "failed to assemble" because it bound SPIR-V
// types as VALUE operands; the fix is the "t" (type) asm constraint, which
// resolves to the module's real (deduped) type id — matching the @extern
// variable's pointee type for OpLoad.

const Image = @SpirvType(.{ .image = .{
    .usage = .{ .sampled = u32 },
    .format = .unknown,
    .dim = .@"2d",
    .depth = .unknown,
    .arrayed = false,
    .multisampled = false,
    .access = .unknown,
} });
const SampledImage = @SpirvType(.{ .sampled_image = Image });

const tex = @extern(*addrspace(.constant) const SampledImage, .{
    .name = "tex",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

const uv_in = @extern(*addrspace(.input) Vec2, .{
    .name = "uv",
    .decoration = .{ .location = 0 },
});
const color_out = @extern(*addrspace(.output) Vec, .{
    .name = "color",
    .decoration = .{ .location = 0 },
});

fn sampleImplicitLod(
    si_ptr: *addrspace(.constant) const SampledImage,
    uv: Vec2,
) Vec {
    return asm volatile (
        \\%si = OpLoad %si_ty %si_ptr
        \\%res = OpImageSampleImplicitLod %v4f %si %uv
        : [res] "" (-> Vec),
        : [si_ty] "t" (SampledImage),
          [v4f] "t" (Vec),
          [si_ptr] "" (si_ptr),
          [uv] "" (uv),
    );
}

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    color_out.* = sampleImplicitLod(tex, uv_in.*);
}
