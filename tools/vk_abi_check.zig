//! VK-ABI-CHECK - every declaration in `src/vk.zig` compared with the official Vulkan headers, at compile time.
//!
//! `vk.zig` is declared by hand, and a hand-declared structure that is wrong does not fail: the driver reads
//! plausible garbage. This tool makes the compiler the judge. The build translates the official headers with
//! `translate-c` (module `vk_c`) and compiles this file against both modules FOR THE WINDOWS TARGET; every check is a
//! comptime comparison, so compiling it is running it, and a mismatch is a compile error naming the declaration:
//!
//!     structures and unions   size, alignment, field count, and each field's offset and size, by position
//!     enumerations            each tag's value against its C constant
//!                             (`Format.r8g8b8a8_unorm` <-> VK_FORMAT_R8G8B8A8_UNORM)
//!     constants               each value against its C constant (`queue_graphics_bit` <-> VK_QUEUE_GRAPHICS_BIT)
//!     commands                each `Pfn...` (the headers' `PFN_vk...`): parameter count, each parameter's size,
//!                             the return type's size
//!
//! Fields are compared by POSITION, not name: `vk.zig` renames them (`sType` is `s_type`), and the layout is what the
//! driver reads. Run: `zig build vk-abi-check -Dvulkan-headers=<the headers' include directory>` (or with
//! `VULKAN_SDK` set). The headers are a development-time oracle; nothing else in the build needs them.

const std = @import("std");
const vk = @import("vk");
const vk_c = @import("vk_c");

const comptimePrint = std.fmt.comptimePrint;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const toUpper = std.ascii.toUpper;
const isUpper = std.ascii.isUpper;
const isLower = std.ascii.isLower;
const isDigit = std.ascii.isDigit;

/// Constants `vk.zig` declares that have no C twin under the mechanical name (or are not integers).
const constants_without_twin = [_][]const u8{
    "bool_true",
    "bool_false",
    "khronos_validation_layer_name",
    "khr_surface_extension_name",
    "khr_win32_surface_extension_name",
    "khr_swapchain_extension_name",
    "ext_debug_utils_extension_name",
};

/// `text` upper-cased: `r8g8b8a8_unorm` -> `R8G8B8A8_UNORM`.
fn upper(comptime text: []const u8) []const u8 {
    comptime {
        var result: [text.len]u8 = undefined;
        for (text, 0..) |character, index| {
            result[index] = toUpper(character);
        }
        const final: [text.len]u8 = result;
        return &final;
    }
}

/// A type name as a C constant's prefix: `PhysicalDeviceType` -> `PHYSICAL_DEVICE_TYPE`.
fn upperSnake(comptime text: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        for (text, 0..) |character, index| {
            const previous: u8 = if (index == 0) 0 else text[index - 1];
            const starts_word: bool = isUpper(character) and (isLower(previous) or isDigit(previous));
            if (starts_word) {
                result = result ++ "_";
            }
            result = result ++ &[_]u8{toUpper(character)};
        }
        return result;
    }
}

/// `PresentModeKHR` -> `PresentMode`: extension enumerations' constants carry the suffix on each value instead.
fn trimVendorSuffix(comptime name: []const u8) []const u8 {
    for ([_][]const u8{ "KHR", "EXT" }) |suffix| {
        if (endsWith(u8, name, suffix)) {
            return name[0 .. name.len - suffix.len];
        }
    }
    return name;
}

fn checkLayout(
    comptime decl_name: [:0]const u8,
    comptime T: type,
    comptime field_names: []const [:0]const u8,
    comptime field_types: []const type,
) void {
    const c_name: []const u8 = "Vk" ++ decl_name;
    if (!@hasDecl(vk_c, c_name)) {
        @compileError("vk." ++ decl_name ++ ": the headers have no " ++ c_name);
    }
    const C: type = @field(vk_c, c_name);
    if (@sizeOf(T) != @sizeOf(C) or @alignOf(T) != @alignOf(C)) {
        @compileError(comptimePrint("vk.{s}: size {d} align {d}, but {s}: size {d} align {d}", .{
            decl_name, @sizeOf(T), @alignOf(T), c_name, @sizeOf(C), @alignOf(C),
        }));
    }
    const c_field_names: []const [:0]const u8 = switch (@typeInfo(C)) {
        .@"struct" => |info| info.field_names,
        .@"union" => |info| info.field_names,
        else => @compileError(c_name ++ " is not a structure or union"),
    };
    const c_field_types: []const type = switch (@typeInfo(C)) {
        .@"struct" => |info| info.field_types,
        .@"union" => |info| info.field_types,
        else => unreachable,
    };
    if (field_names.len != c_field_names.len) {
        @compileError(comptimePrint("vk.{s}: {d} fields, but {s}: {d}", .{
            decl_name, field_names.len, c_name, c_field_names.len,
        }));
    }
    // A union's fields all start at offset 0: only their sizes can differ.
    const is_union: bool = @typeInfo(T) == .@"union";
    for (field_names, field_types, c_field_names, c_field_types, 0..) |name, Field, c_field_name, CField, index| {
        const offset: usize = if (is_union) 0 else @offsetOf(T, name);
        const c_offset: usize = if (is_union) 0 else @offsetOf(C, c_field_name);
        if (offset != c_offset or @sizeOf(Field) != @sizeOf(CField)) {
            const message_format: []const u8 = "vk.{s} field {d} ({s}): offset {d} size {d}, " ++
                "but {s}.{s}: offset {d} size {d}";
            @compileError(comptimePrint(message_format, .{
                decl_name, index, name, offset, @sizeOf(Field), c_name, c_field_name, c_offset, @sizeOf(CField),
            }));
        }
    }
}

fn checkEnumeration(
    comptime decl_name: [:0]const u8,
    comptime T: type,
    comptime tag_names: []const [:0]const u8,
) void {
    // VK_SUCCESS, VK_ERROR_...: the result codes carry no type prefix.
    const prefix: []const u8 = if (eql(u8, decl_name, "Result"))
        "VK_"
    else
        "VK_" ++ upperSnake(trimVendorSuffix(decl_name)) ++ "_";
    for (tag_names) |tag_name| {
        const c_name: []const u8 = prefix ++ upper(tag_name);
        if (!@hasDecl(vk_c, c_name)) {
            @compileError("vk." ++ decl_name ++ "." ++ tag_name ++ ": the headers have no " ++ c_name);
        }
        const expected: i128 = @intCast(@field(vk_c, c_name));
        const actual: i128 = @backingInt(@field(T, tag_name));
        if (expected != actual) {
            @compileError(comptimePrint("vk.{s}.{s} = {d}, but {s} = {d}", .{
                decl_name, tag_name, actual, c_name, expected,
            }));
        }
    }
}

fn checkCommand(
    comptime decl_name: [:0]const u8,
    comptime c_name: [:0]const u8,
    comptime Function: type,
) void {
    if (!@hasDecl(vk_c, c_name)) {
        @compileError("vk." ++ decl_name ++ ": the headers have no " ++ c_name);
    }
    // In C, `PFN_vkX` is an optional pointer to the function.
    const COptional: type = @field(vk_c, c_name);
    const CFunction: type = @typeInfo(@typeInfo(COptional).optional.child).pointer.child;
    const info: std.lang.Type.Fn = @typeInfo(Function).@"fn";
    const c_info: std.lang.Type.Fn = @typeInfo(CFunction).@"fn";
    if (info.param_types.len != c_info.param_types.len) {
        @compileError(comptimePrint("vk.{s}: {d} parameters, but the headers: {d}", .{
            decl_name, info.param_types.len, c_info.param_types.len,
        }));
    }
    for (info.param_types, c_info.param_types, 0..) |Param, CParam, index| {
        if (@sizeOf(Param.?) != @sizeOf(CParam.?)) {
            @compileError(comptimePrint("vk.{s} parameter {d}: size {d}, but the headers: {d}", .{
                decl_name, index, @sizeOf(Param.?), @sizeOf(CParam.?),
            }));
        }
    }
    if (@sizeOf(info.return_type.?) != @sizeOf(c_info.return_type.?)) {
        @compileError("vk." ++ decl_name ++ ": the return type's size differs from the headers'");
    }
}

fn checkType(comptime decl_name: [:0]const u8, comptime T: type) void {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (info.layout == .@"extern") {
                checkLayout(decl_name, T, info.field_names, info.field_types);
            }
        },
        .@"union" => |info| {
            if (info.layout == .@"extern") {
                checkLayout(decl_name, T, info.field_names, info.field_types);
            }
        },
        .@"enum" => |info| {
            // Handles are enums of pointer size with one tag; enumerations proper are i32-tagged.
            if (info.tag_type == i32) {
                checkEnumeration(decl_name, T, info.field_names);
            }
        },
        .pointer => |info| {
            if (startsWith(u8, decl_name, "Pfn")) {
                // `PfnX` is the headers' `PFN_vkX`.
                checkCommand(decl_name, "PFN_vk" ++ decl_name[3..], info.child);
            }
        },
        else => {},
    }
}

fn checkDeclaration(comptime decl_name: [:0]const u8) void {
    const value: @TypeOf(@field(vk, decl_name)) = @field(vk, decl_name);
    const Value: type = @TypeOf(value);
    if (Value == type) {
        checkType(decl_name, value);
        return;
    }
    if (@typeInfo(Value) == .int or @typeInfo(Value) == .comptime_int) {
        for (constants_without_twin) |skipped| {
            if (eql(u8, skipped, decl_name)) {
                return;
            }
        }
        const c_name: []const u8 = "VK_" ++ upper(decl_name);
        if (!@hasDecl(vk_c, c_name)) {
            @compileError("vk." ++ decl_name ++ ": the headers have no " ++ c_name);
        }
        const expected: i128 = @intCast(@field(vk_c, c_name));
        const actual: i128 = @intCast(value);
        if (expected != actual) {
            @compileError(comptimePrint("vk.{s} = {d}, but {s} = {d}", .{ decl_name, actual, c_name, expected }));
        }
    }
}

comptime {
    @setEvalBranchQuota(2_000_000);
    for (@typeInfo(vk).@"struct".decl_names) |decl_name| {
        checkDeclaration(decl_name);
    }
}

pub fn main() void {}
