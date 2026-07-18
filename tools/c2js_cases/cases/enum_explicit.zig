// enum with explicit values + @intFromEnum / @enumFromInt.
const E = enum(u8) { a = 10, b = 20, c = 30 };
export fn run_test() i32 {
    if (@intFromEnum(E.b) != 20) return 1;
    const f: E = @enumFromInt(30);
    if (f != E.c) return 2;
    return 0;
}
