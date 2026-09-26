// Spike: a realistic textured fragment shader using the NEW zm helpers - the
// no-zspv_rewrite path. Separate texture + sampler bindings (WGSL's model),
// paired by OpSampledImage inside the inline `sampleLod`. Compiling this and
// running it through spv2wgsl yields native `textureSample(tex, samp, uv)`.
const zm = @import("../../zimrmath.zig");

const albedo_tex = zm.texture2D("albedo_tex", 0, 1);
const albedo_smp = zm.sampler("albedo_smp", 0, 2);

const uv_in = @extern(*addrspace(.input) zm.Vec2, .{
    .name = "uv",
    .decoration = .{ .location = 0 },
});
const color_out = @extern(*addrspace(.output) zm.Vec, .{
    .name = "color",
    .decoration = .{ .location = 0 },
});

export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    color_out.* = zm.sampleLod(albedo_tex, albedo_smp, uv_in.*);
}
