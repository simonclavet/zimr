//! External-check fixture: a host unit test (`project.addTest`) importing zm and zn.

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

test "lerp, checked with zimrnum" {
    try std.testing.expect(zn.approxEqAbs(f32, lerp(0.0, 10.0, 0.5), 5.0, 1e-6));
    const v: zm.Vec2 = .{ 1.0, 2.0 };
    try std.testing.expectEqual(@as(f32, 2.0), v[1]);
}
