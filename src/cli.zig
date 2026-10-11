// low level tokenizer

const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;
const mem = std.mem;
const testing = std.testing;
const Allocator = mem.Allocator;
const Writer = Io.Writer;

pub const Token = union(enum) {
    /// e.g. "--name"
    long: []const u8,
    /// e.g. "-f" or "-lA"
    short: [:0]const u8,
    /// e.g. "foo.txt" or "-"
    positional: [:0]const u8,
};

pub const Tokenizer = struct {
    state: union(enum) {
        none,
        value: [:0]const u8,
        positional_only,
    } = .none,
    remaining_argv: []const [:0]const u8,

    pub fn init(argv: []const [:0]const u8) Tokenizer {
        return .{ .remaining_argv = argv };
    }

    pub const NextError = error{
        IllegalToken,
        UnexpectedValue,
    };

    /// Call this at the start of argument processing and after each complete arg.
    /// If you get a `Token.long` or `Token.short`, conditionally call `value` immediately afterword iff the option takes a value.
    /// Returns `error.UnexpectedValue` if a `Token.long` argument included an "=" value, and `value` wasn't called.
    /// Returns null at the end of the argv array.
    pub fn next(t: *Tokenizer) NextError!?Token {
        sw: switch (t.state) {
            .value => return error.UnexpectedValue,
            .positional_only => if (t.remaining_argv.len == 0) {
                return null;
            } else {
                defer t.remaining_argv = t.remaining_argv[1..];
                return .{ .positional = t.remaining_argv[0] };
            },
            .none => if (t.remaining_argv.len == 0) {
                return null;
            } else {
                const arg = t.remaining_argv[0];

                if (mem.startsWith(u8, arg, "--")) {
                    if (arg.len == 2) {
                        t.state = .positional_only;
                        t.remaining_argv = t.remaining_argv[1..];
                        continue :sw t.state;
                    }

                    switch (arg[2]) {
                        '0'...'9', 'A'...'Z', 'a'...'z' => {},
                        else => return error.IllegalToken,
                    }

                    const maybe_eql_pos: ?usize = for (arg[3..], 3..) |char, i| {
                        switch (char) {
                            '0'...'9', 'A'...'Z', 'a'...'z', '-' => {},
                            '=' => break i,
                            else => return error.IllegalToken,
                        }
                    } else null;

                    if (maybe_eql_pos) |pos| {
                        t.state = .{ .value = arg[pos + 1 ..] };
                        return .{ .long = arg[0..pos] };
                    } else {
                        t.remaining_argv = t.remaining_argv[1..];
                        return .{ .long = arg };
                    }
                } else if (mem.startsWith(u8, arg, "-")) {
                    if (arg.len == 1) {
                        t.remaining_argv = t.remaining_argv[1..];
                        return .{ .positional = arg };
                    }

                    for (arg[1..]) |short_char| {
                        switch (short_char) {
                            '0'...'9', 'A'...'Z', 'a'...'z' => {},
                            else => return error.IllegalToken,
                        }
                    }

                    t.remaining_argv = t.remaining_argv[1..];
                    return .{ .short = arg };
                } else {
                    t.remaining_argv = t.remaining_argv[1..];
                    return .{ .positional = arg };
                }
            },
        }
    }

    pub const ValueError = error{
        IllegalToken,
        ExpectedValue,
    };

    /// Call this if a `Token.long` or `Token.short` from `Tokenizer.next` takes a value.
    /// Returns `error.ExpectedValue` at the end of the argv array.
    pub fn value(t: *Tokenizer) ValueError![:0]const u8 {
        switch (t.state) {
            .value => |v| {
                t.state = .none;
                t.remaining_argv = t.remaining_argv[1..];
                return v;
            },
            .none => {
                if (t.remaining_argv.len == 0) return error.ExpectedValue;
                defer t.remaining_argv = t.remaining_argv[1..];
                return t.remaining_argv[0];
            },
            .positional_only => return error.IllegalToken,
        }
    }
};

// high level api

pub const ShortName = enum {
    // zig fmt: off
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
    A, B, C, D, E, F, G, H, I, J, K, L, M, N, O, P, Q, R, S, T, U, V, W, X, Y, Z,
    a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z,
    // zig fmt: on
};

pub const ArgConfig = struct {
    /// Printed by --help for this argument in addition to type and default info.
    description: ?[]const u8 = null,
    /// A single-letter alias for this argument. Must be unique.
    /// Only allowed for named arguments.
    short: ?ShortName = null,
    /// A named argument name that resets this argument to its default.
    /// Must start with "--", and must be unique.
    /// Only allowed for named arguments with a default value of `null`, `false`, or `&.{}` for a slice of strings.
    clear: ?@EnumLiteral() = null,
};

pub fn Config(Args: type) type {
    const info = @typeInfo(Args).@"struct";

    const default: ArgConfig = .{};
    const attrs: std.lang.Type.Struct.FieldAttributes = .{
        .default_value_ptr = &default,
    };

    return struct {
        /// If null, the first arg will be used as the program name.
        prog: ?[]const u8 = null,
        /// If true, the first argument will be treated as the program name when parsing and skipped.
        /// Set to false for a positional argument to be able to recover it.
        skip_first_arg: bool = true,
        /// Printed after the Usage line of the --help before the per-argument help.
        description: ?[]const u8 = null,
        /// see `ArgConfig`.
        args: @Struct(.auto, null, info.field_names, &@splat(ArgConfig), &@splat(attrs)) = .{},
    };
}

fn validName(name: []const u8) bool {
    std.debug.assert(name.len >= 1);

    switch (name[0]) {
        '0'...'9', 'A'...'Z', 'a'...'z' => {},
        else => return false,
    }

    for (name[1..]) |char| {
        switch (char) {
            '0'...'9', 'A'...'Z', 'a'...'z', '-' => {},
            else => return false,
        }
    }

    return true;
}

inline fn isAccumulator(T: type) bool {
    return T == []const []const u8 or T == []const [:0]const u8;
}

inline fn isStringType(T: type) bool {
    return T == []const u8 or T == [:0]const u8;
}

const ArgInfo = struct {
    field_names: []const [:0]const u8,
    field_types: []const type,
    field_attrs: []const std.lang.Type.Struct.FieldAttributes,

    named_args: []const [:0]const u8,
    NamedFieldEnum: type,

    positional_args: []const [:0]const u8,
    PositionalFieldEnum: type,

    AccumulatorArgLists: type,

    short_map: std.EnumMap(ShortName, [:0]const u8),
    ClearEnum: type,
    clear_map_ptr: *const anyopaque,

    inline fn clearMap(info: ArgInfo, ClearEnum: type) std.EnumMap(ClearEnum, [:0]const u8) {
        const clear_ptr: *const std.EnumMap(ClearEnum, [:0]const u8) = @ptrCast(@alignCast(info.clear_map_ptr));
        return clear_ptr.*;
    }
};

fn EnumBackingInt(field_count: usize) type {
    return if (field_count > 0)
        std.math.IntFittingRange(0, field_count)
    else
        noreturn;
}

// @Enum wants a noreturn for TagInt if the enum has no members and it wants
// a *const [count]TagInt for the values but userland code is not allowed to
// create a *const [0]noreturn even though it's empty, which forces us to use
// this weird optional api
inline fn enumValues(BackingType: type, comptime count: usize) if (BackingType != noreturn)
    ?*const [count]BackingType
else
    ?noreturn {
    return if (count > 0)
        &std.simd.iota(BackingType, count)
    else
        null;
}

inline fn getArgInfo(Args: type, comptime config: Config(Args)) ArgInfo {
    comptime {
        const info = @typeInfo(Args).@"struct";

        var named = true;
        var positional_defaults = false;
        var positional_start_idx: usize = info.field_names.len;

        var short_map: std.EnumMap(ShortName, [:0]const u8) = .{};
        var clear_names: []const [:0]const u8 = &.{};
        var clear_args: []const [:0]const u8 = &.{};

        var accumulator_args: []const [:0]const u8 = &.{};

        for (info.field_names, info.field_attrs, info.field_types, 0..) |name, attrs, T, i| {
            const default = attrs.defaultValue(T);
            const has_default = default != null;

            const arg_conf = @field(config.args, name);

            if (mem.startsWith(u8, name, "--")) {
                if (name.len == 2) @compileError("Invalid argument name: '--'");
                if (mem.eql(u8, name[2..], "help")) @compileError("Argument uses reserved name '--help'");
                if (!named) @compileError("Named argument fields must come before positional ones");
                if (!validName(name[2..])) @compileError("Invalid argument name: '" ++ name ++ "'");

                if (arg_conf.clear) |clear| {
                    const c = @tagName(clear);
                    if (!mem.startsWith(u8, c, "--") or !validName(c[2..]))
                        @compileError("Invalid name '" ++ c ++ "' of clear option for argument '" ++ name ++ "'");

                    clear_names = clear_names ++ .{c};
                    clear_args = clear_args ++ .{name};
                }

                if (arg_conf.short) |short| {
                    if (short_map.fetchPut(short, name)) |previous_arg| {
                        @compileError("Duplicate short name '" ++ @tagName(short) ++ "' in arguments '" ++ previous_arg ++ "' and '" ++ name ++ "'");
                    }
                }
            } else {
                if (named) {
                    named = false;
                    positional_start_idx = i;
                }
                if (!validName(name)) @compileError("Invalid argument name: '" ++ name ++ "'");
                if (!has_default and positional_defaults) @compileError(
                    "Positional argument '" ++ name ++ "' has no default value but comes after positional arguments with default values",
                );
                if (arg_conf.short != null) @compileError("Short name is set for positional argument '" ++ name ++ "'");
                if (arg_conf.clear != null) @compileError("Clear is set for positional argument '" ++ name ++ "'");
                if (has_default) positional_defaults = true;
            }

            const clear_error = "Clear option is set for unsupported type '" ++ @typeName(T) ++ "' for argument '" ++ name ++ "'";

            switch (@typeInfo(T)) {
                .int, .float => if (arg_conf.clear != null) @compileError(clear_error),
                .@"enum" => |e| if (e.field_names.len == 0)
                    @compileError("Enum type for argument '" ++ name ++ "' has no fields")
                else if (arg_conf.clear != null) @compileError(clear_error),
                .bool => if (!named)
                    @compileError("Positional argument '" ++ name ++ "' is boolean")
                else if (default != false)
                    @compileError("Default value for boolean argument '" ++ name ++ "' is not false"),
                .optional => |o| {
                    // using std.meta.eql because `??[]T` does not support equality operators
                    if (!std.meta.eql(default, @as(T, null)))
                        @compileError("Default value for optional argument '" ++ name ++ " 'is not null");
                    switch (@typeInfo(o.child)) {
                        .int, .float => {},
                        .@"enum" => |e| if (e.field_names.len == 0)
                            @compileError("Optional enum type for argument '" ++ name ++ "' has no fields"),
                        .pointer => if (!isStringType(o.child))
                            @compileError("Optional pointer type for argument '" ++ name ++ "' is not '?[]const u8' or '?[:0]const u8'"),
                        else => @compileError("Invalid optional type '" ++ @typeName(T) ++ "' for argument '" ++ name ++ "'"),
                    }
                },
                .pointer => if (isAccumulator(T)) {
                    accumulator_args = accumulator_args ++ .{name};
                    if (!named and i != info.field_names.len - 1)
                        @compileError("Accumulated string argument '" ++ name ++ "' is not the last field");
                    const valid_default = if (default) |d| d.len == 0 else false;
                    if (!valid_default) @compileError("Default value for accumulated string argument '" ++ name ++ "' is not &.{}");
                } else if (!isStringType(T))
                    @compileError("Invalid type '" ++ @typeName(T) ++ "' for argument '" ++ name ++ "'")
                else if (arg_conf.clear != null) @compileError(clear_error),
                else => @compileError("Invalid type '" ++ @typeName(T) ++ "' for argument '" ++ name ++ "'"),
            }
        }

        const NamedEnumBackingInt = EnumBackingInt(positional_start_idx);
        const PositionalEnumBackingInt = EnumBackingInt(info.field_names.len - positional_start_idx);

        // we could also make sure there are no duplicates within clear_names
        // but @Enum handles that for us with a good enough error message
        // and we are already doing a lot of comptime
        for (clear_names, clear_args) |clear, clear_arg| {
            for (info.field_names[0..positional_start_idx]) |named_arg| {
                if (mem.eql(u8, clear, named_arg)) {
                    @compileError("Clear option for argument '" ++ clear_arg ++ "' has the same name as argument '" ++ named_arg ++ "'");
                }
            }
        }

        const ClearEnumBackingInt = EnumBackingInt(clear_names.len);
        const ClearEnum = @Enum(
            ClearEnumBackingInt,
            .exhaustive,
            clear_names,
            enumValues(ClearEnumBackingInt, clear_names.len) orelse &.{},
        );

        var clear_map: std.EnumMap(ClearEnum, [:0]const u8) = .{};
        for (clear_names, clear_args) |clear, arg| {
            clear_map.put(@field(ClearEnum, clear), arg);
        }

        const copied_map = clear_map;

        return .{
            .field_names = info.field_names,
            .field_attrs = info.field_attrs,
            .field_types = info.field_types,

            .named_args = info.field_names[0..positional_start_idx],
            .NamedFieldEnum = @Enum(
                NamedEnumBackingInt,
                .exhaustive,
                info.field_names[0..positional_start_idx],
                enumValues(NamedEnumBackingInt, positional_start_idx) orelse &.{},
            ),

            .positional_args = info.field_names[positional_start_idx..],
            .PositionalFieldEnum = @Enum(
                PositionalEnumBackingInt,
                .exhaustive,
                info.field_names[positional_start_idx..],
                enumValues(PositionalEnumBackingInt, info.field_names.len - positional_start_idx) orelse &.{},
            ),

            .AccumulatorArgLists = @Struct(
                .auto,
                null,
                accumulator_args,
                &@splat(std.ArrayList([:0]const u8)),
                &@splat(.{
                    .default_value_ptr = &std.ArrayList([:0]const u8).empty,
                }),
            ),

            .short_map = short_map,

            .ClearEnum = ClearEnum,
            .clear_map_ptr = &copied_map,
        };
    }
}

const Defined = enum {
    defined,
    undefined,
};

fn DefinedArgStruct(Args: type) type {
    const info = @typeInfo(Args).@"struct";
    const attrs: std.lang.Type.Struct.FieldAttributes = .{
        .default_value_ptr = &Defined.undefined,
    };
    return @Struct(.auto, null, info.field_names, &@splat(Defined), &@splat(attrs));
}

pub const Error = Allocator.Error || error{
    HelpRequested,
    IncorrectUsage,
};

/// Parse command line arguments.
pub fn parse(
    arena: Allocator,
    /// Must be a struct whose fields represent the command line arguments.
    /// Field names must match the regex `(--)?[0-9A-Za-z][0-9A-Za-z-]*`.
    /// Fields that start with `--` are named arguments.
    /// Valid types for each field are the following
    ///
    /// 1. `[]const u8` or `[:0]const u8` - the value will be used as-is.
    /// 2. any enum with at least 1 tag
    /// 3. any integer or float type
    /// 4. `?T` where `T` is one of the forms 1-3. The value is set according to above,
    /// never to null, except by the clear option.
    /// 5. `bool` - The value is always set to true, except by the clear option.
    /// 6. `[]const []const u8` or `[]const [:0]const u8` - The values will be
    /// accumulated in the order they are encountered.
    ///
    /// If the field type is one of the forms 1-3, it may have a default value.
    /// If the field does not have a default value, the parser requires it to
    /// be specified at runtime.
    ///
    /// Positional arguments with default values must come after other positional
    /// argument fields. Only one positional argument may have a field type of form 6,
    /// and it must be the last field. Positional arguments may not have a type of
    /// form 5 `bool`.
    ///
    /// If the field type is one of the forms 4-6, the field *must* have a default value:
    /// `null` for form 4, `false` for form 5, `&.{}` for form 6.
    Args: type,
    comptime config: Config(Args),
    argv: []const [:0]const u8,
) Error!Args {
    const info = getArgInfo(Args, config);

    var result: Args = undefined;
    var defined: DefinedArgStruct(Args) = .{};

    var accumulator_arg_lists: info.AccumulatorArgLists = .{};

    inline for (info.field_names, info.field_attrs, info.field_types) |name, attrs, T| {
        if (attrs.defaultValue(T)) |default_value| {
            @field(result, name) = default_value;
            @field(defined, name) = .defined;
        }
    }

    var positional_idx: usize = 0;
    var t: Tokenizer = .init(argv);

    if (config.skip_first_arg) {
        _ = t.value() catch |err| switch (err) {
            error.ExpectedValue => return error.IncorrectUsage,
            error.IllegalToken => unreachable, // can only trigger if the tokenizer is in positional_only mode
        };
    }

    while (t.next() catch return error.IncorrectUsage) |token| {
        sw: switch (token) {
            .short => |short| {
                if (short.len == 2) {
                    // unreachable is guaranteed because the tokenizer guarantees that the shorts have valid names
                    const short_enum = std.meta.stringToEnum(ShortName, short[1..2]) orelse unreachable;
                    continue :sw .{
                        .long = info.short_map.get(short_enum) orelse
                            return error.IncorrectUsage,
                    };
                }

                for (short[1..]) |char| {
                    const short_enum = std.meta.stringToEnum(ShortName, &.{char}) orelse unreachable;
                    const long_name = info.short_map.get(short_enum) orelse
                        return error.IncorrectUsage;
                    const long_enum = std.meta.stringToEnum(info.NamedFieldEnum, long_name) orelse unreachable;
                    switch (long_enum) {
                        inline else => |comptime_long| {
                            const arg = @tagName(comptime_long);
                            if (@FieldType(Args, arg) != bool) {
                                return error.IncorrectUsage;
                            }
                            @field(result, arg) = true;
                        },
                    }
                }
            },
            .long => |long_str| {
                if (mem.eql(u8, long_str, "--help")) {
                    return error.HelpRequested;
                }

                if (std.meta.stringToEnum(info.ClearEnum, long_str)) |clear_enum| {
                    const clear_map = info.clearMap(info.ClearEnum);
                    switch (clear_enum) {
                        inline else => |comptime_clear| {
                            const arg = comptime clear_map.getAssertContains(comptime_clear);
                            const Type = @FieldType(Args, arg);

                            switch (@typeInfo(Type)) {
                                .bool => @field(result, arg) = false,
                                .optional => @field(result, arg) = null,
                                // can only be an accumulator
                                .pointer => @field(accumulator_arg_lists, arg).clearRetainingCapacity(),
                                else => comptime unreachable,
                            }
                        },
                    }
                    break :sw;
                }

                const long = std.meta.stringToEnum(info.NamedFieldEnum, long_str) orelse
                    return error.IncorrectUsage;
                switch (long) {
                    inline else => |comptime_long| {
                        const arg = @tagName(comptime_long);
                        const Type = @FieldType(Args, arg);

                        // the error.IllegalToken path could be marked unreachable on every call
                        // to t.value()
                        switch (@typeInfo(Type)) {
                            .bool => @field(result, arg) = true,
                            .int => {
                                const value = t.value() catch return error.IncorrectUsage;
                                @field(result, arg) = parseInt(Type, value, 0) catch
                                    return error.IncorrectUsage;
                            },
                            .float => {
                                const value = t.value() catch return error.IncorrectUsage;
                                @field(result, arg) = parseFloat(Type, value) catch
                                    return error.IncorrectUsage;
                            },
                            .@"enum" => {
                                const value = t.value() catch return error.IncorrectUsage;
                                @field(result, arg) = std.meta.stringToEnum(Type, value) orelse
                                    return error.IncorrectUsage;
                            },
                            .pointer => if (isAccumulator(Type)) {
                                const value = t.value() catch return error.IncorrectUsage;
                                try @field(accumulator_arg_lists, arg).append(arena, value);
                            } else {
                                @field(result, arg) = t.value() catch return error.IncorrectUsage;
                            },
                            .optional => |o| {
                                switch (@typeInfo(o.child)) {
                                    .int => {
                                        const value = t.value() catch return error.IncorrectUsage;
                                        @field(result, arg) = parseInt(o.child, value, 0) catch
                                            return error.IncorrectUsage;
                                    },
                                    .float => {
                                        const value = t.value() catch return error.IncorrectUsage;
                                        @field(result, arg) = parseFloat(o.child, value) catch
                                            return error.IncorrectUsage;
                                    },
                                    .@"enum" => {
                                        const value = t.value() catch return error.IncorrectUsage;
                                        @field(result, arg) = std.meta.stringToEnum(o.child, value) orelse
                                            return error.IncorrectUsage;
                                    },
                                    .pointer => @field(result, arg) = t.value() catch return error.IncorrectUsage,
                                    else => comptime unreachable,
                                }
                            },
                            else => comptime unreachable,
                        }
                        @field(defined, arg) = .defined;
                    },
                }
            },
            .positional => |value| if (info.positional_args.len > 0) {
                switch (positional_idx) {
                    inline 0...info.positional_args.len - 1 => |i| {
                        const arg = info.positional_args[i];
                        const Type = @FieldType(Args, arg);

                        switch (@typeInfo(Type)) {
                            .int => {
                                @field(result, arg) = parseInt(Type, value, 0) catch
                                    return error.IncorrectUsage;
                            },
                            .float => {
                                @field(result, arg) = parseFloat(Type, value) catch
                                    return error.IncorrectUsage;
                            },
                            .@"enum" => {
                                @field(result, arg) = std.meta.stringToEnum(Type, value) orelse
                                    return error.IncorrectUsage;
                            },
                            .pointer => if (isAccumulator(Type))
                                try @field(accumulator_arg_lists, arg).append(arena, value)
                            else {
                                @field(result, arg) = value;
                            },
                            .optional => |o| switch (@typeInfo(o.child)) {
                                .int => {
                                    @field(result, arg) = parseInt(o.child, value, 0) catch
                                        return error.IncorrectUsage;
                                },
                                .float => {
                                    @field(result, arg) = parseFloat(o.child, value) catch
                                        return error.IncorrectUsage;
                                },
                                .@"enum" => {
                                    @field(result, arg) = std.meta.stringToEnum(o.child, value) orelse
                                        return error.IncorrectUsage;
                                },
                                .pointer => @field(result, arg) = value,
                                else => comptime unreachable,
                            },
                            else => comptime unreachable,
                        }
                        @field(defined, arg) = .defined;

                        if (!isAccumulator(Type)) {
                            positional_idx += 1;
                        }
                    },
                    info.positional_args.len => return error.IncorrectUsage,
                    else => unreachable,
                }
            } else return error.IncorrectUsage,
        }
    }

    inline for (@typeInfo(info.AccumulatorArgLists).@"struct".field_names) |arg| {
        @field(result, arg) = try @field(accumulator_arg_lists, arg).toOwnedSlice(arena);
    }

    inline for (info.field_names) |arg| {
        if (@field(defined, arg) == .undefined) {
            return error.IncorrectUsage;
        }
    }

    return result;
}

fn printEnumVariants(writer: *Writer, comptime info: std.lang.Type.Enum) Writer.Error!void {
    try writer.print("{{", .{});
    for (info.field_names, 0..) |name, i| {
        if (i > 0) {
            try writer.print("|", .{});
        }
        try writer.print("{s}", .{name});
    }
    try writer.print("}}", .{});
}

/// Prints an auto generated help message for arguments.
/// Only uses exe_name if config.prog is null and is recommended to be set to argv[0].
pub fn printUsage(writer: *Writer, Args: type, comptime config: Config(Args), exe_name: []const u8) Writer.Error!void {
    const info = getArgInfo(Args, config);

    try writer.print("Usage: {s}", .{config.prog orelse exe_name});

    if (info.named_args.len > 0) {
        try writer.print(" [OPTIONS]", .{});
    }

    if (info.positional_args.len > 0) {
        try writer.print(" [ARGS]", .{});
    }

    try writer.print("\n\n", .{});

    if (config.description) |desc| {
        try writer.print("{s}\n\n", .{desc});
    }

    if (info.named_args.len > 0) {
        try writer.print("OPTIONS:\n", .{});
    }
    inline for (info.named_args, 0..) |option, i| {
        const conf = @field(config.args, option);
        const Type = @FieldType(Args, option);

        try writer.print("  ", .{});

        if (conf.short) |short| {
            try writer.print("-{t}, ", .{short});
        }

        try writer.print("{s}", .{option});

        switch (@typeInfo(Type)) {
            .int => try writer.print(" <int>", .{}),
            .float => try writer.print(" <float>", .{}),
            .pointer => try writer.print(" <str>", .{}),
            .@"enum" => |e| {
                try writer.print(" ", .{});
                try printEnumVariants(writer, e);
            },
            .optional => |o| switch (@typeInfo(o.child)) {
                .int => try writer.print(" <int>", .{}),
                .float => try writer.print(" <float>", .{}),
                .pointer => try writer.print(" <str>", .{}),
                .@"enum" => |e| {
                    try writer.print(" ", .{});
                    try printEnumVariants(writer, e);
                },
                else => comptime unreachable,
            },
            .bool => {},
            else => comptime unreachable,
        }

        if (conf.clear) |clear| {
            try writer.print(", {t}", .{clear});
        }

        try writer.print("\n", .{});

        if (conf.description) |desc| {
            var lines = mem.splitScalar(u8, desc, '\n');
            while (lines.next()) |line| {
                try writer.print("    {s}\n", .{line});
            }
        }

        if (Type == bool) {
            if (@field(config.args, option).clear) |clear| {
                try writer.print("    Default: {t}\n", .{clear});
            }
        } else if (!isAccumulator(Type)) {
            if (info.field_attrs[i].defaultValue(Type)) |default| {
                try writer.print("    Default: ", .{});
                switch (@typeInfo(Type)) {
                    .int, .float => try writer.print("{}", .{default}),
                    .pointer => try writer.print("{q}", .{default}),
                    .@"enum" => try writer.print("'{t}'", .{default}),
                    .optional => try writer.print("null", .{}),
                    else => comptime unreachable,
                }
                try writer.print("\n", .{});
            }
        }

        try writer.print("\n", .{});
    }

    if (info.positional_args.len > 0) {
        try writer.print("ARGS:\n", .{});
    }
    inline for (info.positional_args, info.named_args.len..) |arg, i| {
        const conf = @field(config.args, arg);
        const Type = @FieldType(Args, arg);

        const is_accumulator = isAccumulator(Type);

        if (is_accumulator) {
            try writer.print("  ...{s}\n", .{arg});
        } else {
            try writer.print("  {s}: ", .{arg});
            switch (@typeInfo(Type)) {
                .int => try writer.print("<int>", .{}),
                .float => try writer.print("<float>", .{}),
                .pointer => try writer.print("<str>", .{}),
                .@"enum" => |e| try printEnumVariants(writer, e),
                .optional => |o| switch (@typeInfo(o.child)) {
                    .int => try writer.print("<int>", .{}),
                    .float => try writer.print("<float>", .{}),
                    .pointer => try writer.print("<str>", .{}),
                    .@"enum" => |e| try printEnumVariants(writer, e),
                    else => comptime unreachable,
                },
                else => comptime unreachable,
            }
            try writer.print("\n", .{});
        }

        if (conf.description) |desc| {
            var lines = mem.splitScalar(u8, desc, '\n');
            while (lines.next()) |line| {
                try writer.print("    {s}\n", .{line});
            }
        }

        if (!is_accumulator) if (info.field_attrs[i].defaultValue(Type)) |default| {
            try writer.print("    Default: ", .{});
            switch (@typeInfo(Type)) {
                .int, .float => try writer.print("{}", .{default}),
                .pointer => try writer.print("{q}", .{default}),
                .@"enum" => try writer.print("{t}", .{default}),
                .optional => try writer.print("null", .{}),
                else => comptime unreachable,
            }
            try writer.print("\n", .{});
        };

        try writer.print("\n", .{});
    }
}

fn ArgStringStruct(Args: type) type {
    const info = @typeInfo(Args).@"struct";
    return @Struct(.auto, null, info.field_names, &@splat(?[:0]const u8), &@splat(.{}));
}

fn getAccumulatorStrings(arena: Allocator, args: anytype) Allocator.Error![]const [:0]const u8 {
    const info = @typeInfo(@TypeOf(args)).@"struct";

    var value_count: usize = 0;

    inline for (info.field_names, info.field_types) |arg, T| {
        if (isAccumulator(T)) {
            value_count += @field(args, arg).len;
        }
    }

    var out: std.ArrayList([:0]const u8) = try .initCapacity(arena, value_count);

    inline for (info.field_names, info.field_types) |arg, T| {
        if (isAccumulator(T)) {
            for (@field(args, arg)) |value| {
                var aw: Writer.Allocating = .init(arena);

                if (comptime mem.startsWith(u8, arg, "--")) {
                    aw.writer.print("{s}=", .{arg}) catch return error.OutOfMemory;
                }

                aw.writer.print("{s}", .{value}) catch return error.OutOfMemory;

                out.appendAssumeCapacity(try aw.toOwnedSliceSentinel(0));
            }
        }
    }

    return try out.toOwnedSlice(arena);
}

// checks if a value is equal to the default value of an argument
// only supports those cases
fn eqlDefault(T: type, value: T, comptime default: T) bool {
    switch (@typeInfo(T)) {
        .bool => return !value,
        .int, .float, .@"enum" => return value == default,
        .optional => return value == null,
        .pointer => if (default.len == 0)
            return value.len == 0
        else
            return mem.eql(u8, value, default),
        else => comptime unreachable,
    }
}

fn appendArg(arena: Allocator, list: *std.ArrayList([:0]const u8), value: anytype, comptime maybe_arg: ?[:0]const u8) Allocator.Error!void {
    const T = @TypeOf(value);

    if (isAccumulator(T)) {
        if (maybe_arg) |arg| {
            for (value) |slice| {
                const with_sentinel = try arena.printSentinel("{s}={s}", .{ arg, slice }, 0);
                list.appendAssumeCapacity(with_sentinel);
            }
        } else if (T == []const [:0]const u8) {
            list.appendSliceAssumeCapacity(value);
        } else {
            for (value) |slice| {
                const with_sentinel = try arena.dupeSentinel(u8, slice, 0);
                list.appendAssumeCapacity(with_sentinel);
            }
        }

        return;
    }

    // this function will only be called when value is true
    if (T == bool) {
        list.appendAssumeCapacity(maybe_arg orelse comptime unreachable);
        return;
    }

    var aw: Writer.Allocating = .init(arena);
    if (maybe_arg) |arg| {
        aw.writer.print("{s}=", .{arg}) catch return error.OutOfMemory;
    }

    switch (@typeInfo(T)) {
        .int, .float => aw.writer.print("{}", .{value}) catch return error.OutOfMemory,
        .@"enum" => aw.writer.print("{t}", .{value}) catch return error.OutOfMemory,
        .pointer => aw.writer.print("{s}", .{value}) catch return error.OutOfMemory,
        .optional => |o| switch (@typeInfo(o.child)) {
            .int, .float => aw.writer.print("{}", .{value orelse unreachable}) catch return error.OutOfMemory,
            .@"enum" => aw.writer.print("{t}", .{value orelse unreachable}) catch return error.OutOfMemory,
            .pointer => aw.writer.print("{s}", .{value orelse unreachable}) catch return error.OutOfMemory,
            else => comptime unreachable,
        },
        else => comptime unreachable,
    }

    const str = try aw.toOwnedSliceSentinel(0);
    list.appendAssumeCapacity(str);
}

pub const ArgStringError = Allocator.Error || error{
    /// Returned if the passed in args have a state that is
    /// impossible to get from raw args.
    InvalidState,
};

/// Effectively the reverse of `parse`
pub fn getArgStrings(arena: Allocator, argv0: [:0]const u8, args: anytype) ArgStringError![]const [:0]const u8 {
    const Args = @TypeOf(args);
    const info = @typeInfo(Args).@"struct";

    comptime var past_first_positional = false;
    var stop_positionals: ?usize = null;

    var arg_string_count: usize = 1; // first is argv0
    inline for (info.field_names, info.field_attrs, info.field_types, 0..) |arg, attrs, T, i| {
        if (!past_first_positional and !comptime mem.startsWith(u8, arg, "--")) {
            arg_string_count += 1;
            past_first_positional = true;
        }

        if (isAccumulator(T)) {
            const acc_len = @field(args, arg).len;
            if (stop_positionals != null and acc_len != 0) {
                return error.InvalidState;
            }
            arg_string_count += acc_len;
        } else if (attrs.defaultValue(T)) |default| {
            const value = @field(args, arg);
            if (past_first_positional) {
                if (stop_positionals != null and !eqlDefault(T, value, default)) {
                    return error.InvalidState;
                } else if (@typeInfo(T) != .optional or !eqlDefault(T, value, default)) {
                    arg_string_count += 1;
                } else {
                    stop_positionals = i;
                }
            } else {
                if (!eqlDefault(T, value, default)) {
                    arg_string_count += 1;
                }
            }
        } else {
            arg_string_count += 1;
        }
    }

    var list: std.ArrayList([:0]const u8) = try .initCapacity(arena, arg_string_count);
    list.appendAssumeCapacity(argv0);

    past_first_positional = false;

    inline for (info.field_names, info.field_attrs, info.field_types, 0..) |arg, attrs, T, i| {
        if (!past_first_positional and !comptime mem.startsWith(u8, arg, "--")) {
            list.appendAssumeCapacity("--");
            past_first_positional = true;
        }

        const value = @field(args, arg);

        if (attrs.defaultValue(T)) |default| {
            if (past_first_positional) {
                if (stop_positionals) |idx| {
                    if (i >= idx) break;
                }
                try appendArg(arena, &list, value, null);
            } else {
                if (!eqlDefault(T, value, default)) {
                    try appendArg(arena, &list, value, arg);
                }
            }
        } else if (past_first_positional) {
            try appendArg(arena, &list, value, null);
        } else {
            try appendArg(arena, &list, value, arg);
        }
    }

    return list.items;
}

// tests

test parse {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Args = struct {
        @"--one": bool = false,
        @"--two": enum { bar, baz },
        @"--three": []const u8,
        @"--four": u64,
        @"--five": ?u64 = null,
        @"--six": bool = false,
        @"--seven": bool = false,
        @"--eight": bool = false,
        @"--unspecified": []const u8 = "unspecified",
        @"--accumulator": []const [:0]const u8 = &.{},
        one: u32,
        two: enum { bar, baz },
        three: ?[]const u8 = null,
        accumulator: []const []const u8 = &.{},
    };

    const config: Config(Args) = .{
        .prog = "test",
        .skip_first_arg = false,
        .description =
        \\foo
        \\bar
        ,
        .args = .{
            .@"--four" = .{ .short = .f },
            .@"--six" = .{
                .short = .s,
                .clear = .@"--no-six",
            },
            .@"--seven" = .{
                .short = .S,
                .description =
                \\description for
                \\argument seven
                ,
            },
            .@"--eight" = .{ .short = .e },
            .@"--accumulator" = .{
                .short = .a,
                .clear = .@"--reset-accumulator",
            },
        },
    };

    const args = try parse(
        arena.allocator(),
        Args,
        config,
        &.{
            "--one",
            "-se",
            "--two=bar",
            "10",
            "--three",
            "foo",
            "-f",
            "100",
            "baz",
            "abc",
            "def",
            "--no-six",
            "ghi",
            "--accumulator=a",
            "--reset-accumulator",
            "-a",
            "b",
            "-a",
            "c",
        },
    );

    const expected: Args = .{
        .@"--one" = true,
        .@"--two" = .bar,
        .@"--three" = "foo",
        .@"--four" = 100,
        .@"--five" = null,
        .@"--six" = false,
        .@"--seven" = false,
        .@"--eight" = true,
        .@"--unspecified" = "unspecified",
        .@"--accumulator" = &.{ "b", "c" },
        .one = 10,
        .two = .baz,
        .three = "abc",
        .accumulator = &.{ "def", "ghi" },
    };
    try testing.expectEqualDeep(expected, args);
}

test printUsage {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Args = struct {
        @"--one": bool = false,
        @"--two": enum { bar, baz },
        @"--three": []const u8,
        @"--four": u64,
        @"--five": ?u64 = null,
        @"--six": bool = false,
        @"--seven": bool = false,
        @"--eight": bool = false,
        @"--unspecified": []const u8 = "unspecified",
        @"--accumulator": []const [:0]const u8 = &.{},
        one: u32,
        two: enum { bar, baz },
        three: ?[]const u8 = null,
        accumulator: []const []const u8 = &.{},
    };

    const config: Config(Args) = .{
        .prog = "test",
        .skip_first_arg = false,
        .description =
        \\foo
        \\bar
        ,
        .args = .{
            .@"--four" = .{ .short = .f },
            .@"--six" = .{
                .short = .s,
                .clear = .@"--no-six",
            },
            .@"--seven" = .{
                .short = .S,
                .description =
                \\description for
                \\argument seven
                ,
            },
            .@"--eight" = .{ .short = .e },
            .@"--accumulator" = .{
                .short = .a,
                .clear = .@"--reset-accumulator",
            },
        },
    };

    var help_writer: Writer.Allocating = .init(arena.allocator());
    try printUsage(&help_writer.writer, Args, config, &.{});

    try testing.expectEqualStrings(
        \\Usage: test [OPTIONS] [ARGS]
        \\
        \\foo
        \\bar
        \\
        \\OPTIONS:
        \\  --one
        \\
        \\  --two {bar|baz}
        \\
        \\  --three <str>
        \\
        \\  -f, --four <int>
        \\
        \\  --five <int>
        \\    Default: null
        \\
        \\  -s, --six, --no-six
        \\    Default: --no-six
        \\
        \\  -S, --seven
        \\    description for
        \\    argument seven
        \\
        \\  -e, --eight
        \\
        \\  --unspecified <str>
        \\    Default: "unspecified"
        \\
        \\  -a, --accumulator <str>, --reset-accumulator
        \\
        \\ARGS:
        \\  one: <int>
        \\
        \\  two: {bar|baz}
        \\
        \\  three: <str>
        \\    Default: null
        \\
        \\  ...accumulator
        \\
        \\
    , help_writer.written());
}

test getArgStrings {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const Args = struct {
        @"--one": bool = false,
        @"--two": enum { bar, baz },
        @"--three": []const u8,
        @"--four": u64,
        @"--five": ?u64 = null,
        @"--six": bool = false,
        @"--seven": bool = false,
        @"--eight": bool = false,
        @"--unspecified": []const u8 = "unspecified",
        @"--accumulator": []const [:0]const u8 = &.{},
        one: u32,
        two: enum { bar, baz },
        three: ?[]const u8 = null,
        accumulator: []const []const u8 = &.{},
    };

    const parsed: Args = .{
        .@"--one" = true,
        .@"--two" = .bar,
        .@"--three" = "foo",
        .@"--four" = 100,
        .@"--five" = null,
        .@"--six" = false,
        .@"--seven" = false,
        .@"--eight" = true,
        .@"--unspecified" = "unspecified",
        .@"--accumulator" = &.{ "a", "b", "c" },
        .one = 10,
        .two = .baz,
        .three = "value",

        .accumulator = &.{
            "abc",
            "def",
            "ghi",
        },
    };

    const arg_str = try getArgStrings(arena.allocator(), "test", parsed);
    const expected_arg_str: []const []const u8 = &.{
        "test",
        "--one",
        "--two=bar",
        "--three=foo",
        "--four=100",
        "--eight",
        "--accumulator=a",
        "--accumulator=b",
        "--accumulator=c",
        "--",
        "10",
        "baz",
        "value",
        "abc",
        "def",
        "ghi",
    };

    try testing.expectEqualDeep(expected_arg_str, arg_str);
}

test {
    _ = @import("cli/test.zig");
}
