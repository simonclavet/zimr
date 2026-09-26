//! Regression: a fixed array of extern structs INSIDE a struct INSIDE a
//! GLOBAL struct - the shape a single consolidated `var g` produces. The C
//! backend nests the element address as `&(&(&((Globals*)&g))->boot)->ring)->array[i]`;
//! before the last-resort lvalue-walker hook this leaked into a JS property
//! access on a heap offset (`(addr).ring` -> undefined). Found on-device in
//! zimr's bridge event ring (t1178). run_test() returns 0 on success.
const Rec = extern struct { code: u32, a: f32, b: f32 };
const Inner = struct {
    ring: [8]Rec = undefined,
    count: u32 = 0,
};
const Globals = struct {
    boot: Inner = .{},
};
// lint:off module-var: the regression's whole point - a consolidated global
var g: Globals = .{};

fn poke(code: u32) u32 {
    g.boot.ring[g.boot.count] = .{ .code = code, .a = 1.0, .b = 2.0 };
    g.boot.count += 1;
    return g.boot.ring[0].code;
}

export fn run_test() u32 {
    if (poke(7) != 7) {
        return 1; // first write lands at ring[0]
    }
    if (poke(9) != 7) {
        return 2; // ring[0] survives the second write
    }
    if (g.boot.ring[1].code != 9) {
        return 3; // second write landed at ring[1]
    }
    if (g.boot.count != 2) {
        return 4; // count advanced through the chain
    }
    if (g.boot.ring[1].b != 2.0) {
        return 5; // float fields strided correctly
    }
    var i: u32 = 0; // runtime-indexed drain, the bridge's poll loop shape
    var sum: u32 = 0;
    while (i < g.boot.count) : (i += 1) {
        sum +%= g.boot.ring[i].code;
    }
    if (sum != 16) {
        return 6;
    }
    return 0;
}
