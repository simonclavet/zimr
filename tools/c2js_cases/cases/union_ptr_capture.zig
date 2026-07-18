// By-pointer capture of a tagged-union struct-payload member, accessed through a
// pointer-to-union (`for (&arr) |*s| switch (s.*) { .rect => |*rc| ... }`). The C
// backend lowers the capture to `(struct RectT *)&s->payload.rect`. Pre-fix, the
// &-address-of walker resolved only the first hop (`->payload`) and left the trailing
// `.rect` to be applied to the CAST result as a JS property access — `(addr).rect`
// -> undefined -> a read at address ~0 — so the captured payload silently read as 0.
// Fix: walk the whole `ptr->field(.member)*` chain (like the &v.field.member case),
// summing offsets, so a union payload member resolves to its real address.
const Shape = union(enum) {
    circle: u32,
    rect: struct { w: u32, h: u32 },
    point,
};

export fn run_test() i32 {
    var shapes = [_]Shape{
        .{ .circle = 5 },
        .{ .rect = .{ .w = 3, .h = 4 } },
        .point,
        .{ .rect = .{ .w = 6, .h = 7 } },
    };

    // by-POINTER capture: read AND mutate the struct payload in place
    var area: u32 = 0;
    for (&shapes) |*s| {
        switch (s.*) {
            .circle => |c| area += c,
            .rect => |*rc| {
                area += rc.w * rc.h; // read through the captured payload pointer
                rc.w += 100; // mutate in place
            },
            .point => area += 1,
        }
    }
    // circle 5 + rect 12 + point 1 + rect 42 = 60
    if (area != 60) return 1;

    // the in-place mutations must have landed in the array
    var wsum: u32 = 0;
    for (&shapes) |*s| {
        switch (s.*) {
            .rect => |*rc| wsum += rc.w, // 103 + 106 = 209
            else => {},
        }
    }
    if (wsum != 209) return 2;

    // by-value capture still reads the (now mutated) payloads correctly
    var vsum: u32 = 0;
    for (shapes) |s| {
        switch (s) {
            .rect => |rc| vsum += rc.h, // 4 + 7 = 11
            .circle => |c| vsum += c, // 5
            .point => vsum += 1,
        }
    }
    if (vsum != 17) return 3;

    return 0;
}
