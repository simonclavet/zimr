//! command_line - every zimr tool's command line, through std's own parser (module `cli`).
//!
//! The parser is Zig PR 36930, "std: introduce cli module", vendored in `src/cli.zig` + `src/cli/` VERBATIM but for
//! the imports a copy outside std needs (each file's header says which), so it is deleted the day std has it. A tool
//! declares its command line as a struct - `@"--name"` fields are options, plain ones positionals, each with a
//! type, a default and a description - and gets typed values, `--help` and usage errors for free. `cli.parse`'s doc
//! comment lists the field forms; `src/cli/test.zig` shows them in use.
//!
//! One thing is ours: `cli.args` EXPLAINS a command line that does not fit (`serve: unknown option '--prot'`) before
//! the usage, where std's `Init.args` prints the usage alone - see `misfit`. When std merges the PR, `cli.Config`
//! becomes `std.cli.Config` and the vendored copy goes; `args` and `misfit` stay here, calling std's parser (or
//! `cli.args` becomes `init.args` and the explanation goes too). Nothing else in a tool changes.

const std = @import("std");
const std_cli = @import("cli.zig");
const init_args = @import("cli/init_args.zig");
const Init = std.process.Init;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const bufPrint = std.fmt.bufPrint;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const indexOfScalar = std.mem.indexOfScalar;
const parseInt = std.fmt.parseInt;
const parseFloat = std.fmt.parseFloat;

pub const Config = std_cli.Config;
pub const ArgConfig = std_cli.ArgConfig;
pub const ShortName = std_cli.ShortName;
pub const Error = std_cli.Error;
pub const parse = std_cli.parse;
pub const printUsage = std_cli.printUsage;

/// One field of a command-line struct, flattened from the 0.17 type info's parallel arrays: its name, its type, and
/// whether it must be given (it has no default).
const Field = struct { name: [:0]const u8, T: type, required: bool };

fn fieldsOf(comptime CliArgs: type) []const Field {
    comptime {
        const info: std.lang.Type.Struct = @typeInfo(CliArgs).@"struct";
        var list: [info.field_names.len]Field = undefined;
        for (info.field_names, info.field_types, info.field_attrs, 0..) |name, T, attrs, k| {
            list[k] = .{ .name = name, .T = T, .required = attrs.default_value_ptr == null };
        }
        const done: [info.field_names.len]Field = list;
        return &done;
    }
}

fn isNamed(comptime name: []const u8) bool {
    return name.len > 2 and name[0] == '-' and name[1] == '-';
}

/// `name` is some option's CLEAR - the one that puts it back to its default (`--check` for doc_folds' `--fix`).
fn isClearName(
    comptime CliArgs: type,
    comptime config: Config(CliArgs),
    name: []const u8,
) bool {
    inline for (comptime fieldsOf(CliArgs)) |field| {
        if (comptime isNamed(field.name)) {
            if (comptime @field(config.args, field.name).clear) |clear| {
                if (eql(u8, name, @tagName(clear))) {
                    return true;
                }
            }
        }
    }
    return false;
}

/// A value that does not fit: the value, the positional field it was for (named ones say their own name), and the
/// choices when it is an enum.
const Bad = struct { value: []const u8, field: []const u8 = "", choices: []const u8 };

const NamedStep = union(enum) { unknown, no_value, needs_value, bad_value: Bad, ok: bool };

/// Parses as the parser would: integers in any base Zig writes (`0x10`), floats, an enum's own tag names; any string
/// for the rest.
fn valueFits(comptime T: type, value: []const u8) bool {
    switch (@typeInfo(T)) {
        .optional => |optional| return valueFits(optional.child, value),
        .int => {
            _ = parseInt(T, value, 0) catch return false;
            return true;
        },
        .float => {
            _ = parseFloat(T, value) catch return false;
            return true;
        },
        .@"enum" => return std.meta.stringToEnum(T, value) != null,
        else => return true,
    }
}

/// For an enum, ` (one of: a b c)`; for anything else, nothing.
fn choicesOf(comptime T: type) []const u8 {
    return comptime switch (@typeInfo(T)) {
        .optional => |optional| choicesOf(optional.child),
        .@"enum" => |info| blk: {
            var text: []const u8 = " (one of:";
            for (info.field_names) |name| {
                text = text ++ " " ++ name;
            }
            break :blk text ++ ")";
        },
        else => "",
    };
}

/// The option `name` given with `inline_value` (after `=`) or with the arguments that follow: does it fit, and did it
/// take the next argument as its value? A value is taken whatever it looks like, as the parser takes it.
fn namedStep(
    comptime CliArgs: type,
    name: []const u8,
    inline_value: ?[]const u8,
    rest: []const [:0]const u8,
) NamedStep {
    inline for (comptime fieldsOf(CliArgs)) |field| {
        if (comptime isNamed(field.name)) {
            if (eql(u8, name, field.name)) {
                if (field.T == bool) {
                    return if (inline_value != null) .no_value else .{ .ok = false };
                }
                const value: []const u8 = inline_value orelse if (rest.len > 0) rest[0] else return .needs_value;
                if (!valueFits(field.T, value)) {
                    return .{ .bad_value = .{ .value = value, .choices = choicesOf(field.T) } };
                }
                return .{ .ok = inline_value == null };
            }
        }
    }
    return .unknown;
}

fn hasShortNames(comptime CliArgs: type, comptime config: Config(CliArgs)) bool {
    for (fieldsOf(CliArgs)) |field| {
        if (isNamed(field.name) and @field(config.args, field.name).short != null) {
            return true;
        }
    }
    return false;
}

const PositionalStep = union(enum) { extra, bad_value: Bad, ok: usize };

/// A field that collects a list of strings - a repeatable option, or the positionals left over.
fn isList(comptime T: type) bool {
    return T == []const []const u8 or T == []const [:0]const u8;
}

/// The positional field number `filled` (in declaration order) takes `value` - and a list field keeps taking, so the
/// count stays where it is.
fn positionalStep(
    comptime CliArgs: type,
    filled: usize,
    value: []const u8,
) PositionalStep {
    var index: usize = 0;
    inline for (comptime fieldsOf(CliArgs)) |field| {
        if (comptime !isNamed(field.name)) {
            if (index == filled) {
                if (comptime isList(field.T)) {
                    return .{ .ok = filled };
                }
                if (!valueFits(field.T, value)) {
                    return .{ .bad_value = .{ .value = value, .field = field.name, .choices = choicesOf(field.T) } };
                }
                return .{ .ok = filled + 1 };
            }
            index += 1;
        }
    }
    return .extra;
}

/// `name` appears in `argv`, bare or as `name=value`.
fn mentioned(argv: []const [:0]const u8, comptime name: []const u8) bool {
    for (argv[1..]) |arg| {
        if (eql(u8, arg, name) or startsWith(u8, arg, name ++ "=")) {
            return true;
        }
    }
    return false;
}

/// Where `name` stands among the positional fields, or -1 for a named one.
fn positionalNumber(comptime CliArgs: type, comptime name: []const u8) comptime_int {
    var index: comptime_int = 0;
    for (fieldsOf(CliArgs)) |field| {
        if (!isNamed(field.name)) {
            if (eql(u8, field.name, name)) {
                return index;
            }
            index += 1;
        }
    }
    return -1;
}

/// Why `argv` does not fit `CliArgs`, in words written into `buf`: the first argument with no place to go, or the
/// one that is missing - or null when nothing stands out. Asked only AFTER `parse` has refused the line: it explains,
/// it does not decide, so it follows the parser's own rules (`cli.parse`) and answers only when it is sure. A case it
/// does not model - a cluster of short options - gets null, and the usage alone has to do.
pub fn misfit(
    comptime CliArgs: type,
    comptime config: Config(CliArgs),
    argv: []const [:0]const u8,
    buf: []u8,
) ?[]const u8 {
    var filled: usize = 0; // positional fields given so far, in declaration order
    var only_positionals: bool = false;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg: []const u8 = argv[i];
        if (!only_positionals and eql(u8, arg, "--")) {
            only_positionals = true;
            continue;
        }
        if (!only_positionals and startsWith(u8, arg, "--")) {
            const eq_at: ?usize = indexOfScalar(u8, arg, '=');
            const name: []const u8 = if (eq_at) |at| arg[0..at] else arg;
            const inline_value: ?[]const u8 = if (eq_at) |at| arg[at + 1 ..] else null;
            if (eql(u8, name, "--help")) {
                continue;
            }
            if (isClearName(CliArgs, config, name)) {
                if (inline_value != null) {
                    return bufPrint(buf, "'{s}' takes no value", .{name}) catch null;
                }
                continue;
            }
            switch (namedStep(CliArgs, name, inline_value, argv[i + 1 ..])) {
                .unknown => return bufPrint(buf, "unknown option '{s}'", .{name}) catch null,
                .no_value => return bufPrint(buf, "'{s}' takes no value", .{name}) catch null,
                .needs_value => return bufPrint(buf, "'{s}' needs a value", .{name}) catch null,
                .bad_value => |bad| {
                    const text: []const u8 = "'{s}' is not a valid value for '{s}'{s}";
                    return bufPrint(buf, text, .{ bad.value, name, bad.choices }) catch null;
                },
                .ok => |took_next| i += @intFromBool(took_next),
            }
            continue;
        }
        if (!only_positionals and arg.len > 1 and arg[0] == '-') {
            if (comptime hasShortNames(CliArgs, config)) {
                return null;
            }
            const hint: []const u8 = if (eql(u8, arg, "-h")) " (help is --help)" else "";
            return bufPrint(buf, "unknown option '{s}'{s}", .{ arg, hint }) catch null;
        }
        switch (positionalStep(CliArgs, filled, arg)) {
            .extra => return bufPrint(buf, "unexpected argument '{s}'", .{arg}) catch null,
            .bad_value => |bad| {
                const text: []const u8 = "'{s}' is not a valid value for <{s}>{s}";
                return bufPrint(buf, text, .{ bad.value, bad.field, bad.choices }) catch null;
            },
            .ok => |next| filled = next,
        }
    }
    // Everything given had a place - is something REQUIRED missing?
    inline for (comptime fieldsOf(CliArgs)) |field| {
        if (field.required) {
            if (comptime isNamed(field.name)) {
                if (!mentioned(argv, field.name)) {
                    return bufPrint(buf, "missing '{s}'", .{field.name}) catch null;
                }
            } else if (comptime positionalNumber(CliArgs, field.name) >= 0) {
                if ((comptime positionalNumber(CliArgs, field.name)) >= filled) {
                    return bufPrint(buf, "missing <{s}>", .{field.name}) catch null;
                }
            }
        }
    }
    return null;
}

/// Parse the process's arguments into `CliArgs`; on `--help`, or a command line that does not fit `CliArgs`, print
/// the generated usage to stderr and EXIT - 0 for help, 1 for a bad command line. It is std's `Init.args` (the PR's,
/// in `cli/init_args.zig`) with one thing added: a line that does not fit is first EXPLAINED - `serve: unknown option
/// '--prot'` above the usage - where std prints the usage alone and leaves you to spot the typo.
pub fn args(
    init: *const Init,
    comptime CliArgs: type,
    comptime config: Config(CliArgs),
) CliArgs {
    const arena: Allocator = init.arena.allocator();
    const argv: []const [:0]const u8 = init.minimal.args.toSlice(arena) catch
        return init_args.args(init, CliArgs, config);
    if (std_cli.parse(arena, CliArgs, config, argv)) |parsed| {
        return parsed;
    } else |err| {
        if (err == error.IncorrectUsage) {
            var why_buf: [256]u8 = undefined;
            if (misfit(CliArgs, config, argv, &why_buf)) |why| {
                // The binary's own name: `.prog` may be the whole command a person types (`zig build bvh-trim --`),
                // which is right on the usage line and wrong in front of a message.
                const prog: []const u8 = std.fs.path.basename(argv[0]);
                var out_buf: [512]u8 = undefined;
                var stderr: Io.File.Writer = Io.File.stderr().writer(init.io, &out_buf);
                // lint:off catch-suppression: the explanation is best-effort - the usage below is the answer
                stderr.interface.print("{s}: {s}\n\n", .{ prog, why }) catch {};
                stderr.interface.flush() catch {}; // lint:off catch-suppression: as above
            }
        }
    }
    // Help, a bad line, or no memory: std's own method prints the usage and exits, exactly as it always did.
    return init_args.args(init, CliArgs, config);
}

// ---- tests: each explanation checked against the parser's own verdict ------------------------------------------

const TestMode = enum { fast, safe };

const TestArgs = struct {
    @"--port": u16 = 8080,
    @"--root": []const u8 = "zig-out",
    @"--fix": bool = false,
    @"--mode": TestMode = .fast,
    @"--tag": []const []const u8 = &.{},
    input: []const u8,
    rest: []const []const u8 = &.{},
};

const test_config: Config(TestArgs) = .{
    .prog = "tool",
    .args = .{ .@"--fix" = .{ .clear = .@"--check" } },
};

const TwoArgs = struct {
    first: []const u8,
    second: ?[]const u8 = null,
};

const two_config: Config(TwoArgs) = .{ .prog = "tool" };

/// The parser REFUSES `argv`, and `misfit` says why in exactly these words - so an explanation can never drift from
/// what the parser actually does without a test going red.
fn expectMisfit(
    comptime CliArgs: type,
    comptime config: Config(CliArgs),
    argv: []const [:0]const u8,
    why: []const u8,
) !void {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    try expectError(error.IncorrectUsage, std_cli.parse(arena.allocator(), CliArgs, config, argv));
    var buf: [256]u8 = undefined;
    try expectEqualStrings(why, misfit(CliArgs, config, argv, &buf) orelse "(no explanation)");
}

test "misfit names what the parser refused" {
    try expectMisfit(TestArgs, test_config, &.{ "tool", "--prot", "1", "in" }, "unknown option '--prot'");
    try expectMisfit(TestArgs, test_config, &.{ "tool", "in", "--port" }, "'--port' needs a value");
    try expectMisfit(
        TestArgs,
        test_config,
        &.{ "tool", "--port", "80a", "in" },
        "'80a' is not a valid value for '--port'",
    );
    try expectMisfit(
        TestArgs,
        test_config,
        &.{ "tool", "--mode=slow", "in" },
        "'slow' is not a valid value for '--mode' (one of: fast safe)",
    );
    try expectMisfit(TestArgs, test_config, &.{ "tool", "--fix=yes", "in" }, "'--fix' takes no value");
    try expectMisfit(TestArgs, test_config, &.{ "tool", "--check=1", "in" }, "'--check' takes no value");
    try expectMisfit(TestArgs, test_config, &.{ "tool", "-h" }, "unknown option '-h' (help is --help)");
    try expectMisfit(TestArgs, test_config, &.{ "tool", "--port", "9000" }, "missing <input>");
    try expectMisfit(TwoArgs, two_config, &.{ "tool", "a", "b", "c" }, "unexpected argument 'c'");
}

test "misfit stays quiet about a line the parser accepts" {
    // Every accepted form at once: `=` and separate values, a `0x` integer, the clear, a repeated list option, and
    // `--` followed by a positional that starts with a dash.
    const argv: []const [:0]const u8 = &.{
        "tool",    "--port=0x1F90", "--root", "web", "--fix", "--check", "--mode", "safe",
        "--tag=a", "--tag",         "b",      "in",  "x",     "--",      "-y",
    };
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const parsed: TestArgs = try std_cli.parse(arena.allocator(), TestArgs, test_config, argv);
    try expectEqual(@as(u16, 8080), parsed.@"--port");
    try expect(!parsed.@"--fix");
    var buf: [256]u8 = undefined;
    try expectEqual(@as(?[]const u8, null), misfit(TestArgs, test_config, argv, &buf));
}
