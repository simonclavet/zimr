//! lint:alias serialize
//! serialize.zig — comptime protobuf-style serialization for plain Zig structs.
//!
//! Reimplemented in pure Zig for zimr, inspired by zoto (Zephyr Proto). You hand
//! `encode` a struct value and get bytes; you hand `decode` a type and bytes and
//! get a value back — no wrapper types, no codegen, no `.proto` files. Field
//! numbers are assigned in declaration order (1, 2, 3...), so the wire format is
//! versioned: add, drop, or reorder-by-number fields and old data still reads
//! (unknown fields are skipped, missing fields keep their struct default). It's
//! slice-based (works in wasm — no filesystem needed) and the wire bytes are
//! protobuf-compatible.
//!
//! Supported field types: ints (varint), floats (fixed 32/64), bool, enums,
//! `[]const u8` (string/bytes), nested structs (recursive, length-delimited),
//! optionals (`?T` — absent when null), repeated slices `[]const T` (encode +
//! decode, allocating), and fixed vectors/arrays (`@Vector`, `[N]T`) — so the
//! zm math types (Vec, Vec2/3, Quat = @Vector; Mat = [4]Vec; Color = u8 struct)
//! all serialize directly.
//!
//! Overrides: a struct may declare `pub const _fields = .{ .name = .{ .number =
//! N } }` to pin field numbers for wire stability across renames. Fields without
//! an entry fall back to declaration order.
const std = @import("std");
const Allocator = std.mem.Allocator;

// --- protobuf wire types (the low 3 bits of every field tag) ---
const wire_varint: u3 = 0; // ints, bools, enums
const wire_i64: u3 = 1; // f64 (8 fixed bytes)
const wire_len: u3 = 2; // strings, bytes, nested messages
const wire_i32: u3 = 5; // f32 (4 fixed bytes)

pub const Error = error{
    Truncated, // ran off the end of the input
    MalformedVarint, // a varint that never terminated
    BufferTooSmall, // encode buffer smaller than encodedSize
    WireTypeMismatch, // a field's wire type didn't match its Zig type
} || Allocator.Error;

// ===========================================================================
// A tiny byte cursor. We compute encodedSize() up front, so the write cursor
// never has to grow — it just marches through a caller-sized buffer.
// ===========================================================================
const WriteCursor = struct {
    buf: []u8,
    pos: usize = 0,

    fn byte(self: *WriteCursor, value: u8) void {
        self.buf[self.pos] = value;
        self.pos += 1;
    }
    fn bytes(self: *WriteCursor, data: []const u8) void {
        @memcpy(self.buf[self.pos .. self.pos + data.len], data);
        self.pos += data.len;
    }
    // LEB128 varint: 7 bits per byte, high bit set means "more bytes follow".
    fn varint(self: *WriteCursor, value: u64) void {
        var remaining = value;
        while (remaining >= 0x80) {
            self.byte(@intCast((remaining & 0x7f) | 0x80));
            remaining >>= 7;
        }
        self.byte(@intCast(remaining));
    }
    fn tag(self: *WriteCursor, field_number: u32, wire_type: u3) void {
        self.varint((@as(u64, field_number) << 3) | wire_type);
    }
};

const ReadCursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn atEnd(self: *const ReadCursor) bool {
        return self.pos >= self.data.len;
    }
    fn byte(self: *ReadCursor) Error!u8 {
        if (self.pos >= self.data.len) {
            return Error.Truncated;
        }
        const b: u8 = self.data[self.pos];
        self.pos += 1;
        return b;
    }
    fn take(self: *ReadCursor, n: usize) Error![]const u8 {
        if (self.pos + n > self.data.len) {
            return Error.Truncated;
        }
        const slice: []const u8 = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }
    fn varint(self: *ReadCursor) Error!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const b: u8 = try self.byte();
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) {
                break;
            }
            if (shift >= 63) {
                return Error.MalformedVarint;
            }
            shift += 7;
        }
        return result;
    }
};

// ===========================================================================
// Varint helpers for signed/unsigned ints. We store ints as plain varints
// (two's-complement widened to u64) — simple and matches protobuf int32/int64.
// ===========================================================================
fn intToVarint(value: anytype) u64 {
    const T = @TypeOf(value);
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        // widen through i64 so the sign bit lands in the top of the u64
        return @bitCast(@as(i64, value));
    }
    return @intCast(value);
}

fn varintToInt(comptime T: type, raw: u64) T {
    const info = @typeInfo(T).int;
    if (info.signedness == .signed) {
        return @intCast(@as(i64, @bitCast(raw)));
    }
    return @intCast(raw);
}

fn varintSize(value: u64) usize {
    var remaining = value;
    var count: usize = 1;
    while (remaining >= 0x80) : (remaining >>= 7) {
        count += 1;
    }
    return count;
}

// ===========================================================================
// Field numbering: declaration order by default, or overridden by a struct's
// optional `pub const _fields` decl. Resolved entirely at comptime.
// ===========================================================================
fn fieldNumber(
    comptime T: type,
    comptime field_name: []const u8,
    comptime decl_index: usize,
) u32 {
    if (@hasDecl(T, "_fields")) {
        const overrides = @field(T, "_fields");
        if (@hasField(@TypeOf(overrides), field_name)) {
            return @field(overrides, field_name).number;
        }
    }
    return decl_index + 1; // protobuf field numbers start at 1
}

// ===========================================================================
// SIZE — walk the value at comptime + runtime and sum the encoded byte count,
// so we can allocate/validate the buffer before writing a single byte.
// ===========================================================================
pub fn encodedSize(value: anytype) usize {
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("encodedSize expects a struct value, got " ++ @typeName(T));
    }
    var total: usize = 0;
    inline for (info.@"struct".field_names, 0..) |field_name, i| {
        const number = comptime fieldNumber(T, field_name, i);
        total += fieldSize(number, @field(value, field_name));
    }
    return total;
}

fn fieldSize(field_number: u32, value: anytype) usize {
    const T = @TypeOf(value);
    const tag_size = varintSize(@as(u64, field_number) << 3);
    switch (@typeInfo(T)) {
        .int => return tag_size + varintSize(intToVarint(value)),
        .bool => return tag_size + 1,
        .@"enum" => return tag_size + varintSize(@backingInt(value)),
        .float => |f| return tag_size + (if (f.bits == 64) @as(usize, 8) else 4),
        .optional => return if (value) |inner| fieldSize(field_number, inner) else 0,
        .@"struct" => {
            const body: usize = encodedSize(value);
            return tag_size + varintSize(body) + body;
        },
        .pointer => |p| {
            if (p.size != .slice) {
                @compileError("only slices are supported, not " ++ @typeName(T));
            }
            if (p.child == u8) {
                return tag_size + varintSize(value.len) + value.len;
            }
            // repeated: each element carries its own tag
            var total: usize = 0;
            for (value) |elem| {
                total += fieldSize(field_number, elem);
            }
            return total;
        },
        .vector, .array => {
            const body: usize = bareSize(value);
            return tag_size + varintSize(body) + body;
        },
        else => @compileError("unsupported field type: " ++ @typeName(T)),
    }
}

// ===========================================================================
// ENCODE
// ===========================================================================

/// Encode `value` into `buf`, returning the number of bytes written. `buf` must
/// be at least `encodedSize(value)` long.
pub fn encode(value: anytype, buf: []u8) Error!usize {
    if (buf.len < encodedSize(value)) {
        return Error.BufferTooSmall;
    }
    var cursor = WriteCursor{ .buf = buf };
    encodeMessage(&cursor, value);
    return cursor.pos;
}

/// Convenience: encode into a freshly allocated slice the caller then owns.
pub fn encodeAlloc(value: anytype, gpa: Allocator) Error![]u8 {
    const buf = try gpa.alloc(u8, encodedSize(value));
    errdefer gpa.free(buf);
    const n: usize = try encode(value, buf);
    return buf[0..n];
}

fn encodeMessage(cursor: *WriteCursor, value: anytype) void {
    const T = @TypeOf(value);
    inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
        const number = comptime fieldNumber(T, field_name, i);
        encodeField(cursor, number, @field(value, field_name));
    }
}

fn encodeField(cursor: *WriteCursor, field_number: u32, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => {
            cursor.tag(field_number, wire_varint);
            cursor.varint(intToVarint(value));
        },
        .bool => {
            cursor.tag(field_number, wire_varint);
            cursor.varint(if (value) 1 else 0);
        },
        .@"enum" => {
            cursor.tag(field_number, wire_varint);
            cursor.varint(@backingInt(value));
        },
        .float => |f| {
            if (f.bits == 64) {
                cursor.tag(field_number, wire_i64);
                cursor.bytes(&@as([8]u8, @bitCast(@as(f64, value))));
            } else {
                cursor.tag(field_number, wire_i32);
                cursor.bytes(&@as([4]u8, @bitCast(@as(f32, value))));
            }
        },
        .optional => {
            if (value) |inner| {
                encodeField(cursor, field_number, inner);
            }
        },
        .@"struct" => {
            cursor.tag(field_number, wire_len);
            cursor.varint(encodedSize(value));
            encodeMessage(cursor, value);
        },
        .pointer => |p| {
            if (p.child == u8) {
                cursor.tag(field_number, wire_len);
                cursor.varint(value.len);
                cursor.bytes(value);
            } else {
                for (value) |elem| {
                    encodeField(cursor, field_number, elem);
                }
            }
        },
        .vector, .array => {
            cursor.tag(field_number, wire_len);
            cursor.varint(bareSize(value));
            encodeBare(cursor, value);
        },
        else => @compileError("unsupported field type: " ++ @typeName(T)),
    }
}

// ===========================================================================
// DECODE
// ===========================================================================

/// Decode `bytes` into a `T`. Strings and slices are allocated with `gpa`; free
/// the result with `freeDecoded(T, value, gpa)`. Fields absent from the input
/// keep their struct-declared default; unknown fields are skipped.
pub fn decode(comptime T: type, bytes: []const u8, gpa: Allocator) Error!T {
    var result: T = .{}; // struct defaults fill in anything the wire omits
    var cursor = ReadCursor{ .data = bytes };
    try decodeMessage(T, &result, &cursor, gpa);
    return result;
}

/// Is this a repeated field — a `[]const T` slice of something other than u8?
/// (u8 slices are strings/bytes and take the single length-delimited path.)
fn isRepeatedSlice(comptime FT: type) bool {
    const info: std.builtin.Type = @typeInfo(FT);
    return info == .pointer and info.pointer.size == .slice and info.pointer.child != u8;
}

/// Append one decoded element to a repeated field's slice, growing it. Protobuf
/// emits repeated elements as separate wire entries, so we grow one at a time.
/// The static empty default (`&.{}`) is handled specially since it isn't ours
/// to realloc. (One-at-a-time growth is O(n^2) — fine for typical save data.)
fn appendDecoded(
    comptime Elem: type,
    gpa: Allocator,
    slice_ptr: *[]const Elem,
    elem: Elem,
) Error!void {
    const old: []const Elem = slice_ptr.*;
    if (old.len == 0) {
        const fresh: []Elem = try gpa.alloc(Elem, 1);
        fresh[0] = elem;
        slice_ptr.* = fresh;
    } else {
        const grown: []Elem = try gpa.realloc(@constCast(old), old.len + 1);
        grown[old.len] = elem;
        slice_ptr.* = grown;
    }
}

fn decodeMessage(
    comptime T: type,
    result: *T,
    cursor: *ReadCursor,
    gpa: Allocator,
) Error!void {
    while (!cursor.atEnd()) {
        const tag: u64 = try cursor.varint();
        const number: u32 = @intCast(tag >> 3);
        const wire_type: u3 = @intCast(tag & 0x7);
        var matched = false;
        inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
            const expected = comptime fieldNumber(T, field_name, i);
            const FieldT: type = @typeInfo(T).@"struct".field_types[i];
            if (number == expected) {
                matched = true;
                if (comptime isRepeatedSlice(FieldT)) {
                    // repeated field: decode one element and append it to the slice
                    const Elem = @typeInfo(FieldT).pointer.child;
                    var elem: Elem = std.mem.zeroes(Elem);
                    try decodeField(Elem, &elem, wire_type, cursor, gpa);
                    try appendDecoded(Elem, gpa, &@field(result, field_name), elem);
                } else {
                    try decodeField(FieldT, &@field(result, field_name), wire_type, cursor, gpa);
                }
            }
        }
        if (!matched) {
            try skipField(wire_type, cursor);
        }
    }
}

fn decodeField(
    comptime FT: type,
    dst: *FT,
    wire_type: u3,
    cursor: *ReadCursor,
    gpa: Allocator,
) Error!void {
    switch (@typeInfo(FT)) {
        .int => {
            if (wire_type != wire_varint) {
                return Error.WireTypeMismatch;
            }
            dst.* = varintToInt(FT, try cursor.varint());
        },
        .bool => {
            if (wire_type != wire_varint) {
                return Error.WireTypeMismatch;
            }
            dst.* = (try cursor.varint()) != 0;
        },
        .@"enum" => {
            if (wire_type != wire_varint) {
                return Error.WireTypeMismatch;
            }
            dst.* = @fromBackingInt(@intCast(try cursor.varint()));
        },
        .float => |f| {
            if (f.bits == 64) {
                if (wire_type != wire_i64) {
                    return Error.WireTypeMismatch;
                }
                dst.* = @bitCast((try cursor.take(8))[0..8].*);
            } else {
                if (wire_type != wire_i32) {
                    return Error.WireTypeMismatch;
                }
                dst.* = @bitCast((try cursor.take(4))[0..4].*);
            }
        },
        .optional => |o| {
            var inner: o.child = undefined;
            try decodeField(o.child, &inner, wire_type, cursor, gpa);
            dst.* = inner;
        },
        .@"struct" => {
            if (wire_type != wire_len) {
                return Error.WireTypeMismatch;
            }
            const len: usize = @intCast(try cursor.varint());
            const body: []const u8 = try cursor.take(len);
            var sub = ReadCursor{ .data = body };
            try decodeMessage(FT, dst, &sub, gpa);
        },
        .pointer => |p| {
            if (wire_type != wire_len) {
                return Error.WireTypeMismatch;
            }
            const len: usize = @intCast(try cursor.varint());
            const raw: []const u8 = try cursor.take(len);
            if (p.child == u8) {
                // copy the bytes so they outlive the input buffer
                const owned = try gpa.alloc(u8, len);
                @memcpy(owned, raw);
                dst.* = owned;
            } else {
                @compileError("slice-of-slice element types aren't supported: " ++ @typeName(FT));
            }
        },
        .vector, .array => {
            if (wire_type != wire_len) {
                return Error.WireTypeMismatch;
            }
            const len: usize = @intCast(try cursor.varint());
            const body: []const u8 = try cursor.take(len);
            var sub = ReadCursor{ .data = body };
            try decodeBare(FT, dst, &sub);
        },
        else => @compileError("unsupported field type: " ++ @typeName(FT)),
    }
}

fn skipField(wire_type: u3, cursor: *ReadCursor) Error!void {
    switch (wire_type) {
        wire_varint => _ = try cursor.varint(),
        wire_i64 => _ = try cursor.take(8),
        wire_i32 => _ = try cursor.take(4),
        wire_len => {
            const len: usize = @intCast(try cursor.varint());
            _ = try cursor.take(len);
        },
        else => return Error.WireTypeMismatch,
    }
}

/// Free anything `decode` allocated (strings/bytes, and nested structs that
/// contain them). Safe to call on any decoded value.
pub fn freeDecoded(comptime T: type, value: T, gpa: Allocator) void {
    inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
        const FieldT: type = @typeInfo(T).@"struct".field_types[i];
        freeFieldValue(FieldT, @field(value, field_name), gpa);
    }
}

fn freeFieldValue(comptime FT: type, value: FT, gpa: Allocator) void {
    switch (@typeInfo(FT)) {
        .pointer => |p| {
            if (p.child == u8) {
                gpa.free(value);
            } else {
                // repeated slice: free each element's allocations, then the slice
                for (value) |elem| {
                    freeFieldValue(p.child, elem, gpa);
                }
                gpa.free(value);
            }
        },
        .@"struct" => freeDecoded(FT, value, gpa),
        .optional => |o| {
            if (value) |inner| {
                freeFieldValue(o.child, inner, gpa);
            }
        },
        else => {},
    }
}

// ===========================================================================
// Packed helpers for vectors and arrays (zm.Vec, zm.Quat, zm.Mat, and friends).
// We store the whole aggregate as one length-delimited field whose body is the
// elements written back-to-back with no per-element tag. Element counts are
// known at comptime, so decode reads exactly the right number back. Mat is
// [4]Vec, so this recurses (array -> vector -> floats) all on its own.
// ===========================================================================
fn bareSize(value: anytype) usize {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => return varintSize(intToVarint(value)),
        .bool => return 1,
        .@"enum" => return varintSize(@backingInt(value)),
        .float => |f| return if (f.bits == 64) @as(usize, 8) else 4,
        .vector => |v| {
            var total: usize = 0;
            inline for (0..v.len) |i| {
                total += bareSize(value[i]);
            }
            return total;
        },
        .array => |a| {
            var total: usize = 0;
            inline for (0..a.len) |i| {
                total += bareSize(value[i]);
            }
            return total;
        },
        else => @compileError("cannot pack element type: " ++ @typeName(T)),
    }
}

fn encodeBare(cursor: *WriteCursor, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => cursor.varint(intToVarint(value)),
        .bool => cursor.varint(if (value) 1 else 0),
        .@"enum" => cursor.varint(@backingInt(value)),
        .float => |f| {
            if (f.bits == 64) {
                cursor.bytes(&@as([8]u8, @bitCast(@as(f64, value))));
            } else {
                cursor.bytes(&@as([4]u8, @bitCast(@as(f32, value))));
            }
        },
        .vector => |v| {
            inline for (0..v.len) |i| {
                encodeBare(cursor, value[i]);
            }
        },
        .array => |a| {
            inline for (0..a.len) |i| {
                encodeBare(cursor, value[i]);
            }
        },
        else => @compileError("cannot pack element type: " ++ @typeName(T)),
    }
}

fn decodeBare(comptime T: type, dst: *T, cursor: *ReadCursor) Error!void {
    switch (@typeInfo(T)) {
        .int => dst.* = varintToInt(T, try cursor.varint()),
        .bool => dst.* = (try cursor.varint()) != 0,
        .@"enum" => dst.* = @fromBackingInt(@intCast(try cursor.varint())),
        .float => |f| {
            if (f.bits == 64) {
                dst.* = @bitCast((try cursor.take(8))[0..8].*);
            } else {
                dst.* = @bitCast((try cursor.take(4))[0..4].*);
            }
        },
        .vector => |v| {
            // vector elements aren't addressable, so decode into a scalar then
            // assign by (comptime) index
            var result: T = undefined;
            inline for (0..v.len) |i| {
                var elem: v.child = undefined;
                try decodeBare(v.child, &elem, cursor);
                result[i] = elem;
            }
            dst.* = result;
        },
        .array => |a| {
            var result: T = undefined;
            inline for (0..a.len) |i| {
                try decodeBare(a.child, &result[i], cursor);
            }
            dst.* = result;
        },
        else => @compileError("cannot unpack element type: " ++ @typeName(T)),
    }
}

// ===========================================================================
// tests — headless roundtrips
// ===========================================================================
const testing = std.testing;

const Inner = struct {
    kind: enum(u8) { a = 0, b = 1, c = 2 } = .a,
    weight: f32 = 0,
};

const Sample = struct {
    id: u32 = 0,
    balance: i32 = 0,
    name: []const u8 = "",
    active: bool = false,
    ratio: f64 = 0,
    inner: Inner = .{},
    tag: ?[]const u8 = null,
};

test "roundtrip: all core field types" {
    const original = Sample{
        .id = 42,
        .balance = -1234,
        .name = "hello zimr",
        .active = true,
        .ratio = 3.14159,
        .inner = .{ .kind = .c, .weight = 2.5 },
        .tag = "tagged",
    };
    const buf: []u8 = try encodeAlloc(original, testing.allocator);
    defer testing.allocator.free(buf);

    const decoded = try decode(Sample, buf, testing.allocator);
    defer freeDecoded(Sample, decoded, testing.allocator);

    try testing.expectEqual(@as(u32, 42), decoded.id);
    try testing.expectEqual(@as(i32, -1234), decoded.balance);
    try testing.expectEqualStrings("hello zimr", decoded.name);
    try testing.expectEqual(true, decoded.active);
    try testing.expectEqual(@as(f64, 3.14159), decoded.ratio);
    try testing.expect(decoded.inner.kind == .c);
    try testing.expectEqual(@as(f32, 2.5), decoded.inner.weight);
    try testing.expect(decoded.tag != null);
    try testing.expectEqualStrings("tagged", decoded.tag.?);
}

test "roundtrip: null optional stays null" {
    const original = Sample{ .id = 1, .tag = null };
    const buf: []u8 = try encodeAlloc(original, testing.allocator);
    defer testing.allocator.free(buf);
    const decoded = try decode(Sample, buf, testing.allocator);
    defer freeDecoded(Sample, decoded, testing.allocator);
    try testing.expectEqual(@as(?[]const u8, null), decoded.tag);
}

test "schema evolution: unknown fields are skipped" {
    // encode a struct with an extra trailing field, decode into one without it
    const Extended = struct {
        id: u32 = 0,
        name: []const u8 = "",
        extra: u32 = 0,
    };
    const Basic = struct {
        id: u32 = 0,
        name: []const u8 = "",
    };
    const ext = Extended{ .id = 7, .name = "x", .extra = 999 };
    const buf: []u8 = try encodeAlloc(ext, testing.allocator);
    defer testing.allocator.free(buf);
    const basic = try decode(Basic, buf, testing.allocator);
    defer freeDecoded(Basic, basic, testing.allocator);
    try testing.expectEqual(@as(u32, 7), basic.id);
    try testing.expectEqualStrings("x", basic.name);
}

test "binary-safe: serialized bytes survive a base64 round-trip" {
    // Mirrors what zimr's persistence does: raw binary would be corrupted by
    // localStorage's UTF-8 string round-trip, so it's base64'd first. Prove the
    // bytes (and the decoded struct) come back intact through base64.
    const original = Sample{
        .id = 7,
        .balance = -99,
        .name = "binary!",
        .active = true,
        .ratio = 2.71828,
        .inner = .{ .kind = .b, .weight = -3.5 },
        .tag = null,
    };
    const bytes: []u8 = try encodeAlloc(original, testing.allocator);
    defer testing.allocator.free(bytes);

    const encoder = std.base64.standard.Encoder;
    const b64: []u8 = try testing.allocator.alloc(u8, encoder.calcSize(bytes.len));
    defer testing.allocator.free(b64);
    _ = encoder.encode(b64, bytes);

    const decoder = std.base64.standard.Decoder;
    const back: []u8 = try testing.allocator.alloc(u8, try decoder.calcSizeForSlice(b64));
    defer testing.allocator.free(back);
    try decoder.decode(back, b64);

    try testing.expectEqualSlices(u8, bytes, back); // survived intact

    const decoded = try decode(Sample, back, testing.allocator);
    defer freeDecoded(Sample, decoded, testing.allocator);
    try testing.expectEqual(original.balance, decoded.balance);
    try testing.expectEqualStrings("binary!", decoded.name);
    try testing.expect(decoded.inner.kind == .b);
    try testing.expectEqual(@as(f32, -3.5), decoded.inner.weight);
}

// zm-style aggregates: @Vector for Vec/Quat, [N]Vec for Mat, u8-struct for Color.
const Vec4 = @Vector(4, f32); // lint:off prefer-vec: std-only file, cannot import zm here
const Vec3 = @Vector(3, f32); // lint:off prefer-vec: std-only file, cannot import zm here
const Mat4 = [4]Vec4;
const RgbaColor = struct { r: u8, g: u8, b: u8, a: u8 }; // no field defaults, like zm.Color

const Spatial = struct {
    position: Vec3 = .{ 0, 0, 0 },
    orientation: Vec4 = .{ 0, 0, 0, 1 },
    transform: Mat4 = .{ .{ 1, 0, 0, 0 }, .{ 0, 1, 0, 0 }, .{ 0, 0, 1, 0 }, .{ 0, 0, 0, 1 } },
    tint: RgbaColor = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    id: u32 = 0,
};

test "roundtrip: zm-style vectors, matrices, and a u8 colour struct" {
    const original = Spatial{
        .position = .{ 1.5, -2.5, 3.5 },
        .orientation = .{ 0.1, 0.2, 0.3, 0.9 },
        .transform = .{ .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, .{ 9, 10, 11, 12 }, .{ 13, 14, 15, 16 } },
        .tint = .{ .r = 200, .g = 100, .b = 50, .a = 255 },
        .id = 77,
    };
    const bytes: []u8 = try encodeAlloc(original, testing.allocator);
    defer testing.allocator.free(bytes);
    const decoded = try decode(Spatial, bytes, testing.allocator);
    defer freeDecoded(Spatial, decoded, testing.allocator);

    try testing.expect(@reduce(.And, original.position == decoded.position));
    try testing.expect(@reduce(.And, original.orientation == decoded.orientation));
    inline for (0..4) |row| {
        try testing.expect(@reduce(.And, original.transform[row] == decoded.transform[row]));
    }
    try testing.expectEqual(@as(u8, 200), decoded.tint.r);
    try testing.expectEqual(@as(u8, 255), decoded.tint.a);
    try testing.expectEqual(@as(u32, 77), decoded.id);
}

const Repeated = struct {
    id: u32 = 0,
    scores: []const u32 = &.{},
    name: []const u8 = "",
    points: []const f32 = &.{},
    flags: []const bool = &.{},
};

test "roundtrip: repeated (non-u8) slices decode back" {
    const original = Repeated{
        .id = 5,
        .scores = &.{ 100, 200, 300 },
        .name = "player",
        .points = &.{ 1.5, 2.5, 3.5, 4.5 },
        .flags = &.{ true, false, true },
    };
    const bytes: []u8 = try encodeAlloc(original, testing.allocator);
    defer testing.allocator.free(bytes);
    const decoded = try decode(Repeated, bytes, testing.allocator);
    defer freeDecoded(Repeated, decoded, testing.allocator);

    try testing.expectEqual(@as(u32, 5), decoded.id);
    try testing.expectEqualSlices(u32, &.{ 100, 200, 300 }, decoded.scores);
    try testing.expectEqualStrings("player", decoded.name);
    try testing.expectEqualSlices(f32, &.{ 1.5, 2.5, 3.5, 4.5 }, decoded.points);
    try testing.expectEqualSlices(bool, &.{ true, false, true }, decoded.flags);
}

test "roundtrip: empty repeated slice stays empty" {
    const original = Repeated{ .id = 1 };
    const bytes: []u8 = try encodeAlloc(original, testing.allocator);
    defer testing.allocator.free(bytes);
    const decoded = try decode(Repeated, bytes, testing.allocator);
    defer freeDecoded(Repeated, decoded, testing.allocator);
    try testing.expectEqual(@as(usize, 0), decoded.scores.len);
    try testing.expectEqual(@as(usize, 0), decoded.points.len);
}

const Numbered = struct {
    // pinned, out-of-order field numbers via _fields — lets you rename a field
    // in Zig without changing the wire number (schema stability)
    alpha: u32 = 0,
    beta: []const u8 = "",

    pub const _fields = .{
        .alpha = .{ .number = 10 },
        .beta = .{ .number = 3 },
    };
};

test "field-number overrides via _fields" {
    const original = Numbered{ .alpha = 42, .beta = "hi" };
    const bytes: []u8 = try encodeAlloc(original, testing.allocator);
    defer testing.allocator.free(bytes);
    const decoded = try decode(Numbered, bytes, testing.allocator);
    defer freeDecoded(Numbered, decoded, testing.allocator);
    try testing.expectEqual(@as(u32, 42), decoded.alpha);
    try testing.expectEqualStrings("hi", decoded.beta);
}
