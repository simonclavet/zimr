const zm = @import("../../zimrmath.zig");
extern const texture0_sampler2d: u32 addrspace(.constant);
const uv_in = @extern(*addrspace(.input) zm.Vec2, .{ .name = "uv", .decoration = .{ .location = 0 } });
const color_out = @extern(*addrspace(.output) zm.Vec, .{ .name = "color", .decoration = .{ .location = 0 } });
export fn main() callconv(.{ .spirv_fragment = .{} }) void {
    zm.binding(&texture0_sampler2d, 1, 0);
    color_out.* = zm.zsample2d(texture0_sampler2d, uv_in.*);
}
