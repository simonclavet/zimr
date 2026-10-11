const cli = @import("../cli.zig");

const std = @import("std");

const ArenaAllocator = std.heap.ArenaAllocator;

const testing = std.testing;

const Io = std.Io;

const Writer = Io.Writer;

test "simple" {
    const SimpleArgs = struct {
        @"--output": [:0]const u8 = "-",
        @"--format": enum { json, csv },
        @"--verbose": bool = false,
        input: []const u8,
        @"additional-inputs": []const []const u8 = &.{},
    };

    const simple_args_config: cli.Config(SimpleArgs) = .{
        .description = "performs a task",
        .args = .{
            .@"--output" = .{
                .description = "default is stdout",
                .short = .o,
            },
            .@"--verbose" = .{
                .clear = .@"--quiet",
            },
        },
    };

    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const args = try cli.parse(arena.allocator(), SimpleArgs, simple_args_config, &.{
        "exe",
        "--format=json",
        "<input>",
        "-o",
        "outfile",
        "additional input 1",
        "--verbose",
        "additional input 2",
        "--quiet",
    });

    const expected: SimpleArgs = .{
        .@"--output" = "outfile",
        .@"--format" = .json,
        .@"--verbose" = false,
        .input = "<input>",
        .@"additional-inputs" = &.{
            "additional input 1",
            "additional input 2",
        },
    };

    try testing.expectEqualDeep(expected, args);

    var help_writer: Writer.Allocating = .init(arena.allocator());
    try cli.printUsage(&help_writer.writer, SimpleArgs, simple_args_config, "exe");

    try testing.expectEqualStrings(
        \\Usage: exe [OPTIONS] [ARGS]
        \\
        \\performs a task
        \\
        \\OPTIONS:
        \\  -o, --output <str>
        \\    default is stdout
        \\    Default: "-"
        \\
        \\  --format {json|csv}
        \\
        \\  --verbose, --quiet
        \\    Default: --quiet
        \\
        \\ARGS:
        \\  input: <str>
        \\
        \\  ...additional-inputs
        \\
        \\
    ,
        help_writer.written(),
    );

    const generated_arg_string = try cli.getArgStrings(arena.allocator(), "exe", args);
    const expected_arg_string: []const []const u8 = &.{
        "exe",
        "--output=outfile",
        "--format=json",
        "--",
        "<input>",
        "additional input 1",
        "additional input 2",
    };
    try testing.expectEqualDeep(
        expected_arg_string,
        generated_arg_string,
    );
}

const Abc = enum { a, b, c };
const Args = struct {
    @"--str": []const u8,
    @"--maybe-str": ?[]const u8 = null,
    @"--enum": Abc = .b,
    @"--maybe-enum": ?Abc = null,
    @"--int": u64 = 0,
    @"--float": ?f64 = null,
    @"--bool": bool = false,
    @"--accumulator": []const []const u8 = &.{},
    str: []const u8,
    @"maybe-int": ?u64 = null,
    accumulator: []const [:0]const u8 = &.{},
};
const args_config: cli.Config(Args) = .{
    .prog = "test",
    .description = "args for testing",
    .args = .{
        .@"--str" = .{
            .short = .s,
        },
        .@"--maybe-str" = .{
            .clear = .@"--reset-maybe-str",
        },
        .@"--maybe-enum" = .{
            .clear = .@"--reset-maybe-enum",
        },
        .@"--float" = .{
            .clear = .@"--reset-float",
        },
        .@"--bool" = .{
            .clear = .@"--no-bool",
        },
        .@"--accumulator" = .{
            .clear = .@"--reset-accumulator",
        },
    },
};

test "printUsage" {
    var aw: Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();

    try cli.printUsage(&aw.writer, Args, args_config, "");
    try testing.expectEqualStrings(
        \\Usage: test [OPTIONS] [ARGS]
        \\
        \\args for testing
        \\
        \\OPTIONS:
        \\  -s, --str <str>
        \\
        \\  --maybe-str <str>, --reset-maybe-str
        \\    Default: null
        \\
        \\  --enum {a|b|c}
        \\    Default: 'b'
        \\
        \\  --maybe-enum {a|b|c}, --reset-maybe-enum
        \\    Default: null
        \\
        \\  --int <int>
        \\    Default: 0
        \\
        \\  --float <float>, --reset-float
        \\    Default: null
        \\
        \\  --bool, --no-bool
        \\    Default: --no-bool
        \\
        \\  --accumulator <str>, --reset-accumulator
        \\
        \\ARGS:
        \\  str: <str>
        \\
        \\  maybe-int: <int>
        \\    Default: null
        \\
        \\  ...accumulator
        \\
        \\
    , aw.written());
}

const Arena = ArenaAllocator;

test "parse.onlyNoDefaults" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();

    const args = try cli.parse(arena.allocator(), Args, args_config, &.{
        "test",
        "--str",
        "foo",
        "bar",
    });

    const expected: Args = .{
        .@"--str" = "foo",
        .str = "bar",
    };

    try testing.expectEqualDeep(expected, args);
}

test "parse.allSet" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();

    const args = try cli.parse(arena.allocator(), Args, args_config, &.{
        "test",
        "-s",
        "foo",
        "bar",
        "--int=1",
        "--enum",
        "c",
        "--maybe-enum",
        "a",
        "--reset-maybe-enum",
        "--maybe-enum=b",
        "--no-bool",
        "--float",
        "10.5",
        "--bool",
        "1",
        "baz",
        "--maybe-str",
        "0",
        "qux",
        "--accumulator",
        "a",
        "--accumulator",
        "b",
        "--reset-accumulator",
        "--accumulator=c",
        "--accumulator=d",
    });

    const expected: Args = .{
        .@"--str" = "foo",
        .str = "bar",
        .@"--int" = 1,
        .@"--enum" = .c,
        .@"--maybe-enum" = .b,
        .@"--bool" = true,
        .@"--float" = 10.5,
        .@"maybe-int" = 1,
        .@"--maybe-str" = "0",
        .@"--accumulator" = &.{ "c", "d" },
        .accumulator = &.{ "baz", "qux" },
    };

    try testing.expectEqualDeep(expected, args);
}

test "parse.missingExpected" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();

    const args = cli.parse(arena.allocator(), Args, args_config, &.{
        "test",
    });

    try testing.expectError(error.IncorrectUsage, args);
}

test "getArgStrings.onlyNoDefaults" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();

    const parsed: Args = .{
        .@"--str" = "foo",
        .str = "bar",
    };

    const arg_strings = try cli.getArgStrings(arena.allocator(), "test", parsed);
    const expected: []const []const u8 = &.{
        "test",
        "--str=foo",
        "--",
        "bar",
    };

    try testing.expectEqualDeep(expected, arg_strings);
}

test "getArgStrings.allSet" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();

    const parsed: Args = .{
        .@"--str" = "foo",
        .str = "bar",
        .@"--int" = 1,
        .@"--enum" = .c,
        .@"--maybe-enum" = .b,
        .@"--bool" = true,
        .@"--float" = 10.5,
        .@"maybe-int" = 1,
        .@"--maybe-str" = "0",
        .@"--accumulator" = &.{ "c", "d" },
        .accumulator = &.{ "baz", "qux" },
    };

    const arg_strings = try cli.getArgStrings(arena.allocator(), "test", parsed);
    const expected: []const []const u8 = &.{
        "test",
        "--str=foo",
        "--maybe-str=0",
        "--enum=c",
        "--maybe-enum=b",
        "--int=1",
        "--float=10.5",
        "--bool",
        "--accumulator=c",
        "--accumulator=d",
        "--",
        "bar",
        "1",
        "baz",
        "qux",
    };

    try testing.expectEqualDeep(expected, arg_strings);
}

test "getArgStrings.invalidState" {
    var arena: Arena = .init(testing.allocator);
    defer arena.deinit();

    const parsed: Args = .{
        .@"--str" = "foo",
        .str = "bar",
        .accumulator = &.{"a"},
    };

    const arg_strings = cli.getArgStrings(arena.allocator(), "test", parsed);
    try testing.expectError(error.InvalidState, arg_strings);
}
