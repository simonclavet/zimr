// Tagged unions: `union(enum)` lowers to a C struct holding an anonymous
// `union` payload plus an integer tag. Exercises construction (inline and via a
// local), switch with payload capture, a void variant, and a struct payload.
// run_test returns 0 on success; any non-zero is the failing check number.

const Value = union(enum) {
    int: i32,
    float: f32,
    none: void,
};

fn describe(v: Value) i32 {
    return switch (v) {
        .int => |n| n * 2,
        .float => |f| @as(i32, @intFromFloat(f)),
        .none => -1,
    };
}

const Point = struct { x: i32, y: i32 };

const Node = union(enum) {
    leaf: i32,
    branch: Point,
};

fn weight(n: Node) i32 {
    return switch (n) {
        .leaf => |v| v,
        .branch => |p| p.x + p.y,
    };
}

export fn run_test() i32 {
    // inline anonymous-literal construction, one per variant
    if (describe(.{ .int = 21 }) != 42) {
        return 1;
    }
    if (describe(.{ .float = 5.0 }) != 5) {
        return 2;
    }
    if (describe(.{ .none = {} }) != -1) {
        return 3;
    }

    // a local that is built up then read back
    var v: Value = .{ .int = 10 };
    if (describe(v) != 20) {
        return 4;
    }
    v = .{ .float = 7.0 };
    if (describe(v) != 7) {
        return 5;
    }

    // a variant whose payload is itself a struct
    if (weight(.{ .leaf = 99 }) != 99) {
        return 6;
    }
    if (weight(.{ .branch = .{ .x = 3, .y = 4 } }) != 7) {
        return 7;
    }

    return 0;
}
