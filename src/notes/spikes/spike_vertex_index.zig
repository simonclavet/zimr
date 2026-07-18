const zm = @import("zm");
const float = zm.float;
const spirv = @import("std").spirv;
const col_out = @extern(*addrspace(.output) @Vector(4, f32), .{ .name = "col", .decoration = .{ .location = 0 } });

export fn main() callconv(.spirv_vertex) void {
    const vi: u32 = spirv.vertex_index;
    const x: f32 = if (vi == 0) -1.0 else if (vi == 1) 3.0 else -1.0;
    const y: f32 = if (vi == 2) 3.0 else -1.0;
    spirv.position_out.* = .{ x, y, 0.0, 1.0 };
    col_out.* = .{ float(vi) * 0.5, 0.0, 0.0, 1.0 };
}
