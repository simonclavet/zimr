// Enum-typed struct fields: read (`@intFromEnum(s.col)`), store (`s.col = .x`), a
// u8 enum adjacent to another u8 field (a too-wide store would clobber it), and a
// u32-backed enum. The enum tag lowers to `typedef uintN_t enum__...;`; the cast
// `(enum__... *)&s.col`, the deref, the pointer-local declaration, and the field
// width all have to resolve that alias to its REAL width. Previously the cast was
// skipped (the type name leaked into the expression as a multiply) and the pointer
// declaration mistook the type name for the variable. Self-checks (0 = pass).
const Color = enum(u8) { red = 0, green = 1, blue = 2 };
const Big = enum(u32) { a = 0, b = 1000, c = 2000000 };
const Mixed = struct { col: Color, tag: u8, big: Big, n: i32 };

fn classify(c: Color) i32 {
    return switch (c) {
        .red => 100,
        .green => 200,
        .blue => 300,
    };
}

export fn run_test() i32 {
    var m: Mixed = undefined;
    m.col = .blue;
    m.tag = 222;
    m.big = .c;
    m.n = 42;
    m.col = .green; // re-store; must NOT clobber the adjacent tag

    if (@backingInt(m.col) != 1) return 1;
    if (m.tag != 222) return 2; // adjacency / corruption check
    if (@as(i32, @bitCast(@backingInt(m.big))) != 2000000) return 3;
    if (m.n != 42) return 4;
    if (classify(m.col) != 200) return 5;
    if (classify(.blue) != 300) return 6;

    var c2: Color = @fromBackingInt(@intCast(@as(u8, 2)));
    c2 = c2;
    if (@backingInt(c2) != 2) return 7;

    return 0;
}
