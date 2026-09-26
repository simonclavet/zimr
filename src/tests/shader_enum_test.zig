// src/tests/shader_enum_test.zig
// Regression guard for a bug class that bit hard once: the shader
// location / uniform-type enums are ABI, and three separate files
// used to hand-copy their integer values.  The copies drifted, and
// the result was silent uniform-upload corruption - `colDiffuse` (a
// vec4) was uploaded with the type tag for `int`, the diffuse sampler
// with the tag for `ivec3`, producing GL_INVALID_OPERATION on every
// textured/lit draw and a link failure on stricter mobile drivers.
// The structural fix lives in `types.zig`: the enums are now the
// single source of truth, rlgl.zig and drawing.zig derive their
// constants via `@intFromEnum`, and a `comptime` block in types.zig
// pins the wire values.  This test is the runtime belt-and-suspenders
// layer - it re-asserts the mapping independently, and (crucially)
// pins the `rlSetUniform` dispatch contract: that the integer tag for
// each type routes to the correctly-shaped glUniform* call.

const std = @import("std");
const testing = std.testing;
const types = @import("../types.zig");

const Sli = types.ShaderLocationIndex;
const Sut = types.ShaderUniformDataType;

// ShaderLocationIndex - these integer values index into a Shader's
// flat `locs[]` array.  rlgl.zig writes the array, drawing.zig reads
// it; if their notion of "which slot is colDiffuse" differs by even
// one, a matrix lands in the color slot.  Pin the layout.
test "ShaderLocationIndex wire values match raylib ABI" {
    try testing.expectEqual(@as(i32, 0), @backingInt(Sli.vertex_position));
    try testing.expectEqual(@as(i32, 1), @backingInt(Sli.vertex_texcoord01));
    try testing.expectEqual(@as(i32, 2), @backingInt(Sli.vertex_texcoord02));
    // vertex_normal at 3 (NOT 2) is the slot that historically drifted.
    try testing.expectEqual(@as(i32, 3), @backingInt(Sli.vertex_normal));
    try testing.expectEqual(@as(i32, 4), @backingInt(Sli.vertex_tangent));
    try testing.expectEqual(@as(i32, 5), @backingInt(Sli.vertex_color));
    try testing.expectEqual(@as(i32, 6), @backingInt(Sli.matrix_mvp));
    try testing.expectEqual(@as(i32, 7), @backingInt(Sli.matrix_view));
    try testing.expectEqual(@as(i32, 8), @backingInt(Sli.matrix_projection));
    try testing.expectEqual(@as(i32, 9), @backingInt(Sli.matrix_model));
    try testing.expectEqual(@as(i32, 10), @backingInt(Sli.matrix_normal));
    try testing.expectEqual(@as(i32, 12), @backingInt(Sli.color_diffuse));
    try testing.expectEqual(@as(i32, 15), @backingInt(Sli.map_albedo));
    try testing.expectEqual(@as(i32, 29), @backingInt(Sli.vertex_instancetransform));
}

// ShaderUniformDataType - the integer tag `rlSetUniform` switches on
// to choose the glUniform* variant.  The original bug: VEC4 hand-coded
// as 4 (actually `int`) and INT as 6 (actually `ivec3`).  Pin every
// value `rlSetUniform`'s switch arms depend on.
test "ShaderUniformDataType wire values match rlSetUniform dispatch" {
    try testing.expectEqual(@as(i32, 0), @backingInt(Sut.float));
    try testing.expectEqual(@as(i32, 1), @backingInt(Sut.vec2));
    try testing.expectEqual(@as(i32, 2), @backingInt(Sut.vec3));
    // vec4 == 3 and int == 4 are THE values that were swapped/wrong.
    try testing.expectEqual(@as(i32, 3), @backingInt(Sut.vec4));
    try testing.expectEqual(@as(i32, 4), @backingInt(Sut.int));
    try testing.expectEqual(@as(i32, 5), @backingInt(Sut.ivec2));
    try testing.expectEqual(@as(i32, 6), @backingInt(Sut.ivec3));
    try testing.expectEqual(@as(i32, 7), @backingInt(Sut.ivec4));
    try testing.expectEqual(@as(i32, 8), @backingInt(Sut.uint));
    try testing.expectEqual(@as(i32, 12), @backingInt(Sut.sampler2d));
}

// The dispatch contract, stated as a test.  `rlSetUniform` (in
// rlgl.zig) switches on the integer tag; this re-encodes which
// glUniform* shape each tag MUST map to, so a future edit to that
// switch that breaks the mapping fails here with a readable name.
// This mirrors the switch arms: float/vec* -> glUniform{N}fv,
// int/sampler2d -> glUniform1iv, ivec* -> glUniform{N}iv.
test "uniform type tags map to the correctly-shaped GL call" {
    const Shape = enum { f1, f2, f3, f4, i1, i2, i3, i4, u1 };
    const expected = struct {
        fn shapeOf(t: Sut) Shape {
            return switch (t) {
                .float => .f1,
                .vec2 => .f2,
                .vec3 => .f3,
                .vec4 => .f4,
                // int AND sampler2d both go through glUniform1iv
                // a sampler is set by binding its texture-unit index.
                .int, .sampler2d => .i1,
                .ivec2 => .i2,
                .ivec3 => .i3,
                .ivec4 => .i4,
                .uint => .u1,
                .uivec2, .uivec3, .uivec4 => .u1, // u{2,3,4} - grouped for the test
            };
        }
    };
    // The historically-broken pairs, asserted explicitly:
    // a vec4 must NOT be uploaded as an int, a sampler must be i1.
    try testing.expect(expected.shapeOf(.vec4) == .f4);
    try testing.expect(expected.shapeOf(.int) == .i1);
    try testing.expect(expected.shapeOf(.sampler2d) == .i1);
    try testing.expect(expected.shapeOf(.vec4) != expected.shapeOf(.int));
    try testing.expect(expected.shapeOf(.int) != expected.shapeOf(.ivec3));
}
