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
const eql = std.mem.eql;

/// Declarations whose C twin translate-c cannot express: `IDC_ARROW` is `MAKEINTRESOURCE(32512)`, a pointer cast
/// through the narrow-or-wide macro pair; `win32.zig` declares the resource number itself.
const without_comparable_twin = [_][]const u8{"IDC_ARROW"};

fn isSkipped(comptime decl_name: []const u8) bool {
    for (without_comparable_twin) |skipped| {
        if (eql(u8, skipped, decl_name)) {
            return true;
        }
    }
    return false;
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
    const info: std.lang.Type.Struct = @typeInfo(T).@"struct";
    const c_info: std.lang.Type.Struct = @typeInfo(C).@"struct";
    if (info.field_names.len != c_info.field_names.len) {
        @compileError(comptimePrint("win32.{s}: {d} fields, but the headers: {d}", .{
            decl_name, info.field_names.len, c_info.field_names.len,
        }));
    }
    const c_names: []const [:0]const u8 = c_info.field_names;
    const c_types: []const type = c_info.field_types;
    for (info.field_names, info.field_types, c_names, c_types, 0..) |name, Field, c_name, CField, index| {
        const offset: usize = @offsetOf(T, name);
        const c_offset: usize = @offsetOf(C, c_name);
        if (offset != c_offset or @sizeOf(Field) != @sizeOf(CField)) {
            const message_format: []const u8 = "win32.{s} field {d} ({s}): offset {d} size {d}, " ++
                "but {s}: offset {d} size {d}";
            @compileError(comptimePrint(message_format, .{
                decl_name, index, name, offset, @sizeOf(Field), c_name, c_offset, @sizeOf(CField),
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
