//! Struct-by-value: passing/returning structs, nested struct fields, and the
//! struct-return-to-global assignment that used to alias two globals to one
//! object (the bg/fg canvas bug). run_test() returns 0 on success.

const Vec2 = struct { x: i32, y: i32 };
const Box = struct { pos: Vec2, size: Vec2 };

fn add(a: Vec2, b: Vec2) Vec2 {
    return .{ .x = a.x + b.x, .y = a.y + b.y };
}
fn makeBox(
    px: i32,
    py: i32,
    w: i32,
    h: i32,
) Box {
    return .{ .pos = .{ .x = px, .y = py }, .size = .{ .x = w, .y = h } };
}

// two struct globals, each assigned from a struct-returning call: must NOT alias.
var g1: Vec2 = undefined;
var g2: Vec2 = undefined;

export fn run_test() i32 {
    // pass + return by value
    const p1 = Vec2{ .x = 3, .y = 4 };
    const p2 = Vec2{ .x = 10, .y = 20 };
    const s: Vec2 = add(p1, p2);
    if (s.x != 13 or s.y != 24) {
        return 1;
    }

    // nested struct fields
    const box: Box = makeBox(1, 2, 30, 40);
    if (box.pos.x != 1 or box.pos.y != 2) {
        return 2;
    }
    if (box.size.x != 30 or box.size.y != 40) {
        return 3;
    }

    // mutate a nested field through a local copy
    var b2: Box = box;
    b2.pos.x = 99;
    if (b2.pos.x != 99) {
        return 4;
    }
    if (box.pos.x != 1) {
        return 5;
    } // original unchanged (value semantics)

    // struct-return into two distinct globals: the aliasing regression (the
    // bg/fg canvas bug). If the two returned structs aliased one scratch slot,
    // both globals would read the last value. (Globals are read via a local copy
    // because direct inline field access on a struct global is a separate known
    // transpiler gap.)
    const one = Vec2{ .x = 1, .y = 1 };
    const two = Vec2{ .x = 2, .y = 2 };
    const zero = Vec2{ .x = 0, .y = 0 };
    g1 = add(one, zero);
    g2 = add(two, zero);
    const r1: Vec2 = g1;
    const r2: Vec2 = g2;
    if (r1.x != 1 or r1.y != 1) {
        return 6;
    }
    if (r2.x != 2 or r2.y != 2) {
        return 7;
    } // if aliased to g1, this would be 1

    return 0;
}
