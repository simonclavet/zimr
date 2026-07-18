// Saturating arithmetic must clamp to the type range: `+|` `-|` `*|`, and the
// saturating shift `<<|` — which was an unhandled runtime helper (marker -> 0).
// Self-checks (returns 0 on success).
export fn run_test() i32 {
    var u: u8 = 200;
    u +%= 0;
    if (u +| 100 != 255) return 1;
    var lo: u8 = 10;
    lo +%= 0;
    if (lo -| 20 != 0) return 2;
    var m: u8 = 100;
    m +%= 0;
    if (m *| 5 != 255) return 3;
    var sh: i8 = 100;
    sh +%= 0;
    if (sh +| 50 != 127) return 4;
    var sn: i8 = -100;
    sn +%= 0;
    if (sn -| 50 != -128) return 5;
    var s8: u8 = 16;
    s8 +%= 0;
    if (s8 <<| 5 != 255) return 6; // 512 saturates to 255
    var s16: u16 = 0x100;
    s16 +%= 0;
    if (s16 <<| 10 != 65535) return 7; // saturates
    var ok: u8 = 0x10;
    ok +%= 0;
    if (ok <<| 2 != 64) return 8; // no saturation
    return 0;
}
