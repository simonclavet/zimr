//! WIN32-ABI-CHECK - every structure, constant and function declared in `src/win32.zig` compared with the Windows
//! headers Zig ships (MinGW-w64), at compile time.
//!
//! The build translates `windows.h` with `translate-c` (module `win32_c`) and compiles this file against both modules
//! for x86_64-windows-gnu. Every comparison is comptime, so the compile is the check, and a mismatch is a compile error
//! naming the declaration. `win32.zig` keeps Windows' own names, so each declaration's twin has the same name:
//!
//!     structures   size, alignment, field count, each field's offset and size (by position)
//!     constants    each value, when the headers define one under the same name
//!     functions    parameter count, each parameter's size, the return type's size
//!
//! Run: `zig build win32-abi-check`. It needs nothing outside the Zig toolchain.

const std = @import("std");
const win32 = @import("win32");
const win32_c = @import("win32_c");

const comptimePrint = std.fmt.comptimePrint;
const startsWith = std.mem.startsWith;

/// The prefixes of declarations whose C twin translate-c cannot express. The cursors' `IDC_` names are each
/// `MAKEINTRESOURCE(n)`, a pointer cast through the narrow-or-wide macro pair (`__MINGW_NAME_AW`), which translate-c
/// leaves as a compile error; `win32.zig` declares the resource numbers themselves. Skipped by prefix, so that a
/// cursor added later needs no entry here - listing `IDC_ARROW` alone let the nine added with the cursors (C3) fail
/// the check.
const prefixes_without_comparable_twin = [_][]const u8{"IDC_"};

fn isSkipped(comptime decl_name: []const u8) bool {
    for (prefixes_without_comparable_twin) |prefix| {
        if (startsWith(u8, decl_name, prefix)) {
            return true;
        }
    }
    return false;
}

/// A field of a structure's flattened layout (`flatFields`): its name, its offset from the structure's start, and its
/// size.
const FlatField = struct {
    name: []const u8,
    offset: usize,
    size: usize,
};

/// The fields of `T`, in order, with each nameless structure member replaced by its own fields at their offsets within
/// `T`. The headers write a structure that extends another as a nameless member - MinGW-w64's
/// `__C89_NAMELESS struct { ... };`, the SDK's `MONITORINFO DUMMYSTRUCTNAME;` - which translate-c names `unnamed_N`,
/// while `win32.zig` writes the same fields in a row: `MONITORINFOEXW` is a nameless member and `szDevice` in the
/// headers, and five fields here. Flattened, both are the same five. A nameless union stays one field, compared by
/// its size: its members overlap, and have no order to compare.
fn flatFields(comptime T: type, comptime base_offset: usize) []const FlatField {
    var fields: []const FlatField = &.{};
    const info: std.lang.Type.Struct = @typeInfo(T).@"struct";
    for (info.field_names, info.field_types) |name, Field| {
        const offset: usize = base_offset + @offsetOf(T, name);
        const is_nameless_structure: bool = startsWith(u8, name, "unnamed_") and @typeInfo(Field) == .@"struct";
        if (is_nameless_structure) {
            fields = fields ++ flatFields(Field, offset);
        } else {
            const flat_field: FlatField = .{ .name = name, .offset = offset, .size = @sizeOf(Field) };
            fields = fields ++ &[_]FlatField{flat_field};
        }
    }
    return fields;
}

fn checkLayout(
    comptime decl_name: [:0]const u8,
    comptime T: type,
    comptime C: type,
) void {
    if (@sizeOf(T) != @sizeOf(C) or @alignOf(T) != @alignOf(C)) {
        @compileError(comptimePrint("win32.{s}: size {d} align {d}, but the headers: size {d} align {d}", .{
            decl_name, @sizeOf(T), @alignOf(T), @sizeOf(C), @alignOf(C),
        }));
    }
    const fields: []const FlatField = flatFields(T, 0);
    const c_fields: []const FlatField = flatFields(C, 0);
    if (fields.len != c_fields.len) {
        @compileError(comptimePrint("win32.{s}: {d} fields, but the headers: {d}", .{
            decl_name, fields.len, c_fields.len,
        }));
    }
    for (fields, c_fields, 0..) |field, c_field, index| {
        if (field.offset != c_field.offset or field.size != c_field.size) {
            const message_format: []const u8 = "win32.{s} field {d} ({s}): offset {d} size {d}, " ++
                "but {s}: offset {d} size {d}";
            @compileError(comptimePrint(message_format, .{
                decl_name, index, field.name, field.offset, field.size, c_field.name, c_field.offset, c_field.size,
            }));
        }
    }
}

fn checkFunction(
    comptime decl_name: [:0]const u8,
    comptime Function: type,
    comptime CFunction: type,
) void {
    const info: std.lang.Type.Fn = @typeInfo(Function).@"fn";
    const c_info: std.lang.Type.Fn = @typeInfo(CFunction).@"fn";
    if (info.param_types.len != c_info.param_types.len) {
        @compileError(comptimePrint("win32.{s}: {d} parameters, but the headers: {d}", .{
            decl_name, info.param_types.len, c_info.param_types.len,
        }));
    }
    for (info.param_types, c_info.param_types, 0..) |Param, CParam, index| {
        if (@sizeOf(Param.?) != @sizeOf(CParam.?)) {
            @compileError(comptimePrint("win32.{s} parameter {d}: size {d}, but the headers: {d}", .{
                decl_name, index, @sizeOf(Param.?), @sizeOf(CParam.?),
            }));
        }
    }
    if (@sizeOf(info.return_type.?) != @sizeOf(c_info.return_type.?)) {
        @compileError("win32." ++ decl_name ++ ": the return type's size differs from the headers'");
    }
}

fn checkDeclaration(comptime decl_name: [:0]const u8) void {
    const value: @TypeOf(@field(win32, decl_name)) = @field(win32, decl_name);
    const Value: type = @TypeOf(value);
    const twin: @TypeOf(@field(win32_c, decl_name)) = @field(win32_c, decl_name);
    if (Value == type) {
        // translate-c demotes a structure it cannot express - one with bit-fields - to `opaque {}`, which has no
        // layout to compare with; `win32.zig` pins each such structure's layout itself, from Microsoft's
        // documentation (the `DISPLAYCONFIG_` structures' comptime checks).
        if (@typeInfo(twin) == .@"opaque") {
            return;
        }
        if (@typeInfo(value) == .@"struct" and @typeInfo(value).@"struct".layout == .@"extern") {
            checkLayout(decl_name, value, twin);
        }
        return;
    }
    switch (@typeInfo(Value)) {
        .int, .comptime_int => {
            // A C macro may expand to an expression of another integer type: compare the values.
            const twin_value: i128 = @intCast(twin);
            const own_value: i128 = @intCast(value);
            if (twin_value != own_value) {
                @compileError(comptimePrint("win32.{s} = {d}, but the headers say {d}", .{
                    decl_name, own_value, twin_value,
                }));
            }
        },
        .@"fn" => checkFunction(decl_name, Value, @TypeOf(twin)),
        else => {},
    }
}

comptime {
    @setEvalBranchQuota(1_000_000);
    for (@typeInfo(win32).@"struct".decl_names) |decl_name| {
        if (@hasDecl(win32_c, decl_name) and !isSkipped(decl_name)) {
            checkDeclaration(decl_name);
        }
    }
}

pub fn main() void {}
