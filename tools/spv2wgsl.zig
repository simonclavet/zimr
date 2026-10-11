//! tools/spv2wgsl.zig - CLI wrapper around `src/spv2wgsl.zig`'s
//! SPIR-V -> WGSL translator.  Built once by `tools/build.zig`,
//! invoked from `src/shader_codegen.zig`'s `addShaderWgsl` step as part
//! of the WGSL shader pipeline (parallel to `spirv-cross` in the
//! GLSL pipeline).
//!
//! This is the canonical entry point for the wgpu migration plan's
//! Rule 2: "the normal Zig compiler compiles to SPIR-V, then our
//! Zig code translates and verifies, resulting in WGSL embedded in
//! wasm."  The translation is pure-Zig (no Naga, no Tint); validation
//! is "we produced WGSL with zero unresolved placeholders."
//!
//! Usage:
//!   spv2wgsl <input.spv> <output.wgsl>            # translate
//!   spv2wgsl --check <input.spv>                  # parse + verify, no output
//!   spv2wgsl --strict <input.spv> <output.wgsl>   # fail on any `// ERROR:` marker
//!   spv2wgsl --entry=NAME <input.spv> <output.wgsl>   # one entry point of a multi-kernel module
//!   (options in any order; `--help` for the generated usage)
//!
//! Exit codes:
//!   0 - success
//!   1 - usage error (std's cli convention; it was 2)
//!   3 - input is not valid SPIR-V (magic mismatch / malformed)
//!   4 - translation failed (panic surfaced as an error in the underlying lib)
//!   5 - `--strict` and the output contains a `// ERROR:` marker
//!       (i.e. a combined-sampler shader or other source-level issue
//!       the translator can't fix; engine shaders must always pass --strict)

const std = @import("std");
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const sliceAsBytes = std.mem.sliceAsBytes;
const splitScalar = std.mem.splitScalar;
const indexOf = std.mem.indexOf;
const spv2wgsl = @import("spv2wgsl");

/// The command line (std's cli, `src/command_line.zig`). Options come in any order; the hand parser this replaced
/// took `--check` / `--strict` only in first position, and a `--walker=` flag it then ignored.
const SpvArgs = struct {
    @"--check": bool = false,
    @"--strict": bool = false,
    @"--entry": ?[]const u8 = null,
    input: []const u8,
    output: ?[]const u8 = null,
};

const spv_cli: cli.Config(SpvArgs) = .{
    .prog = "spv2wgsl",
    .description = "Translates SPIR-V to WGSL, in pure Zig. Exit codes: 3 not valid SPIR-V, 4 translation failed, " ++
        "5 --strict and the output has an `// ERROR:` marker.",
    .args = .{
        .@"--check" = .{ .description = "parse and verify only: no output file, nothing written" },
        .@"--strict" = .{ .description = "fail (exit 5) on any `// ERROR:` marker - engine shaders always pass it" },
        .@"--entry" = .{ .description = "the one entry point to translate from a multi-kernel module (else the last)" },
        .input = .{ .description = "the SPIR-V module" },
        .output = .{ .description = "the WGSL file to write (not with --check)" },
    },
};

/// A command line the parser accepted but that does not make sense - `--check` with an output, a translation with
/// none: say which, print the generated usage, exit 1 (the parser's own code for a bad command line).
fn usageError(io: Io, message: []const u8) noreturn {
    var buf: [2048]u8 = undefined;
    var stderr: Io.File.Writer = Io.File.stderr().writer(io, &buf);
    // A report that cannot be written has nowhere left to go: exit 1 either way - it IS a bad command line.
    stderr.interface.print("spv2wgsl: {s}\n\n", .{message}) catch std.process.exit(1);
    cli.printUsage(&stderr.interface, SpvArgs, spv_cli, "spv2wgsl") catch std.process.exit(1);
    stderr.interface.flush() catch std.process.exit(1);
    std.process.exit(1);
}

fn printErrorLine(
    io: Io,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_w: Io.File.Writer = Io.File.stderr().writer(io, &stderr_buf);
    try stderr_w.interface.print(fmt ++ "\n", args);
    try stderr_w.interface.flush();
}

/// Same as cmdTranslate but discards the output.  Useful for CI: "does
/// this SPIR-V translate at all?"  Exit code 0 means yes.
fn cmdCheck(
    io: Io,
    gpa: Allocator,
    input_path: []const u8,
) !void {
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try Io.Dir.cwd().readFileAlloc(io, input_path, arena, .unlimited);
    if (bytes.len % 4 != 0) {
        try printErrorLine(io, "spv2wgsl: input is not a multiple of 4 bytes (not SPIR-V?)", .{});
        std.process.exit(3);
    }
    // Copy into a naturally-4-aligned []u32 rather than @alignCast-ing the
    // byte buffer (readFileAlloc only guarantees byte alignment; the cast
    // panics in safe builds when the buffer is misaligned).
    const words: []u32 = try arena.alloc(u32, bytes.len / 4);
    @memcpy(sliceAsBytes(words), bytes);

    const wgsl: []const u8 = spv2wgsl.convertSpirvToWgsl(arena, words) catch |err| switch (err) {
        error.NotSpirv, error.MalformedSpirv => {
            try printErrorLine(io, "spv2wgsl: {s}: {s}", .{ input_path, @errorName(err) });
            std.process.exit(3);
        },
        error.OutOfMemory => return err,
        // The recursive walker (Phase 3b) introduces `anyerror` into the
        // error set - defensively handle any other error by reporting
        // and exiting non-zero.
        else => {
            try printErrorLine(io, "spv2wgsl: {s}: {s}", .{ input_path, @errorName(err) });
            std.process.exit(3);
        },
    };
    // Quick stat - confirms work was done; aids casual debugging.
    var stdout_buf: [256]u8 = undefined;
    var stdout_w: Io.File.Writer = Io.File.stdout().writer(io, &stdout_buf);
    stdout_w.interface.print(
        "spv2wgsl: {s} OK ({d} spv bytes -> {d} wgsl bytes)\n",
        .{ input_path, bytes.len, wgsl.len },
    ) catch {}; // lint:off catch-suppression: stdout write, best-effort
    stdout_w.interface.flush() catch {}; // lint:off catch-suppression: stdout flush, best-effort
}

const TranslateOpts = struct {
    entry: ?[]const u8 = null,
    /// When true, scan the WGSL output for `// ERROR:` markers
    /// (emitted by handlers like the combined-sampler diagnostic).
    /// On any match: write nothing, print the matched lines on stderr,
    /// exit 5.  Used by `addShaderWgsl` to refuse to embed shaders
    /// with known source-level issues.
    strict: bool,
};

/// Translate `input.spv` -> `output.wgsl`.  On failure, write nothing
/// (don't leave a half-written file on disk) and exit with a non-zero
/// status code.
fn cmdTranslate(
    io: Io,
    gpa: Allocator,
    input_path: []const u8,
    output_path: []const u8,
    opts: TranslateOpts,
) !void {
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try Io.Dir.cwd().readFileAlloc(io, input_path, arena, .unlimited);
    if (bytes.len % 4 != 0) {
        try printErrorLine(io, "spv2wgsl: input is not a multiple of 4 bytes (not SPIR-V?)", .{});
        std.process.exit(3);
    }
    // Copy into a naturally-4-aligned []u32 rather than @alignCast-ing the
    // byte buffer (readFileAlloc only guarantees byte alignment; the cast
    // panics in safe builds when the buffer is misaligned).
    const words: []u32 = try arena.alloc(u32, bytes.len / 4);
    @memcpy(sliceAsBytes(words), bytes);

    const wgsl: []const u8 = spv2wgsl.convertSpirvToWgslEntry(
        arena,
        words,
        opts.entry,
    ) catch |err| switch (err) {
        error.NotSpirv => {
            try printErrorLine(io, "spv2wgsl: input is not SPIR-V (magic 0x07230203 not present)", .{});
            std.process.exit(3);
        },
        error.MalformedSpirv => {
            try printErrorLine(io, "spv2wgsl: malformed SPIR-V header", .{});
            std.process.exit(3);
        },
        error.OutOfMemory => return err,
        // Phase 3b widened convertSpirvToWgsl's error set via the walker.
        else => {
            try printErrorLine(io, "spv2wgsl: {s}", .{@errorName(err)});
            std.process.exit(3);
        },
    };

    if (opts.strict) {
        // Scan for `// ERROR:` markers emitted by handlers that
        // can't translate something (e.g. combined samplers).  These
        // are grep-friendly intentionally - the shader transpiles
        // but is unusable; the source must be fixed.
        var line_no: usize = 1;
        var error_count: usize = 0;
        var it = splitScalar(u8, wgsl, '\n');
        while (it.next()) |line| : (line_no += 1) {
            if (indexOf(u8, line, "// ERROR:") != null) {
                try printErrorLine(io, "spv2wgsl: {s}:{d}: {s}", .{ input_path, line_no, line });
                error_count += 1;
            }
        }
        if (error_count > 0) {
            try printErrorLine(
                io,
                "spv2wgsl: --strict aborted with {d} ERROR marker(s); output not written",
                .{error_count},
            );
            std.process.exit(5);
        }
    }

    // Write the output atomically - write-and-rename is what we'd want
    // in production, but for build-step idempotency the bare write is
    // adequate (the build cache invalidates on input change).
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = wgsl,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;

    const args: SpvArgs = cli.args(&init, SpvArgs, spv_cli);
    if (args.@"--check") {
        const only_input: bool = args.output == null and !args.@"--strict" and args.@"--entry" == null;
        if (!only_input) {
            usageError(io, "--check takes only the input: it writes nothing");
        }
        try cmdCheck(io, gpa, args.input);
        return;
    }
    const output: []const u8 = args.output orelse usageError(io, "a translation needs the output file (or --check)");
    try cmdTranslate(io, gpa, args.input, output, .{ .strict = args.@"--strict", .entry = args.@"--entry" });
}
