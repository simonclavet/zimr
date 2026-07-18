const zm = @import("zm");
const Vec = zm.Vec;

// Spike 2: prove the storage-image WRITE op (OpImageWrite) assembles too.
const StorageImage = @SpirvType(.{ .image = .{
    .usage = .storage,
    .format = .rgba8unorm,
    .dim = .@"2d",
    .depth = .unknown,
    .arrayed = false,
    .multisampled = false,
    .access = .unknown,
} });

const img = @extern(*addrspace(.constant) const StorageImage, .{
    .name = "img",
    .decoration = .{ .descriptor = .{ .set = 0, .binding = 0 } },
});

fn imageStore(
    p: *addrspace(.constant) const StorageImage,
    coord: @Vector(2, i32),
    texel: Vec,
) void {
    asm volatile (
        \\%im = OpLoad %img_ty %p
        \\OpImageWrite %im %coord %texel
        :
        : [img_ty] "t" (StorageImage),
          [p] "" (p),
          [coord] "" (coord),
          [texel] "" (texel),
    );
}

export fn main() callconv(.{ .spirv_kernel = .{ .x = 8, .y = 8, .z = 1 } }) void {
    imageStore(img, .{ 0, 0 }, .{ 1.0, 0.0, 0.0, 1.0 });
}
