// Runtime-initialized [N]u8 arrays - Zig's C backend emits them as C string
// literals with octal/control escapes. Was an xfail (escapes undecoded -> marker
// -> wrong); now decoded byte-for-byte. Includes control-char bytes.
export fn run_test() i32 {
    var d = [_]u8{ 5, 6, 7, 8 };
    d[0] +%= 1;
    if (d[0] != 6 or d[1] != 6 or d[2] != 7 or d[3] != 8) return 1;
    var e = [_]u8{ 1, 10, 13, 9, 200 }; // \1 \n \r \t + a high byte
    e[4] +%= 1;
    if (e[1] != 10 or e[2] != 13 or e[3] != 9 or e[4] != 201) return 2;
    return 0;
}
