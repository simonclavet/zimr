// Spike: storage buffers via the zm helpers (the first end-to-end-working
// @SpirvType resource path). Compiles to a real var<storage> binding +
// indexed load/store; spv2wgsl translates it to native WGSL.
const zm = @import("../../zimrmath.zig");

const src = zm.storageBuffer(u32, "src", 0, 0);
const dst = zm.storageBuffer(u32, "dst", 0, 1);

export fn main() callconv(.{ .spirv_kernel = .{ .x = 64, .y = 1, .z = 1 } }) void {
    zm.ssboStore(u32, dst, 0, zm.ssboLoad(u32, src, 0) * 2);
}
