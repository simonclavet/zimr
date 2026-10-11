// Byte arrays on both sides of the length at which Zig's C backend stops writing a string literal. Up to 4 095 bytes it
// writes one (`{"\000\001..."}`); from 4 096 bytes, a list of character constants, one hex escape per byte
// (`{{'\x0','\x1',...}}`), since a C compiler need not accept a longer literal. Each array cycles through every byte
// value, so a converter that misreads either form - or reads the character constants as zero - changes the checksum.
fn patternBytes(comptime length: usize) [length]u8 {
    @setEvalBranchQuota(length * 8 + 1000);
    var bytes: [length]u8 = undefined;
    for (&bytes, 0..) |*byte, index| {
        byte.* = @intCast((index * 7 + 3) % 256);
    }
    return bytes;
}

const string_literal_form: [4095]u8 = patternBytes(4095);
const first_character_list_form: [4096]u8 = patternBytes(4096);
const long_character_list_form: [8200]u8 = patternBytes(8200);

/// A checksum that every byte and its position change.
fn checksum(bytes: []const u8) u32 {
    var sum: u32 = 0;
    for (bytes, 0..) |byte, index| {
        const position_term: u32 = @intCast(index & 0xff);
        sum = sum *% 31 +% byte +% position_term;
    }
    return sum;
}

export fn run_test() i32 {
    const string_sum: u32 = checksum(&string_literal_form);
    const first_list_sum: u32 = checksum(&first_character_list_form);
    const long_list_sum: u32 = checksum(&long_character_list_form);
    const combined: u32 = string_sum ^ (first_list_sum >> 1) ^ (long_list_sum >> 2);
    return @bitCast(combined & 0x7fff_ffff);
}
