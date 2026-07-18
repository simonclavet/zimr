//! tools/spv2wgsl.zig — CLI wrapper around `src/spv2wgsl.zig`'s
//! SPIR-V → WGSL translator.  Built once by `tools/build.zig`,
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
//!
//! Exit codes:
//!   0 — success
//!   2 — usage error
//!   3 — input is not valid SPIR-V (magic mismatch / malformed)
//!   4 — translation failed (panic surfaced as an error in the underlying lib)
//!   5 — `--strict` and the output contains a `// ERROR:` marker
//!       (i.e. a combined-sampler shader or other source-level issue
//!       the translator can't fix; engine shaders must always pass --strict)

const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const spv2wgsl = @import("spv2wgsl");

fn printUsage(io: std.Io) void {
    var stderr_buf: [512]u8 = undefined;
    var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
    stderr_w.interface.print(
        \\usage: spv2wgsl <input.spv> <output.wgsl>   # translate
        \\       spv2wgsl --check <input.spv>          # parse + verify, no output
        \\       spv2wgsl --strict <input.spv> <output.wgsl>  # fail on any `// ERROR:` marker
        \\
    , .{}) catch {};
    stderr_w.interface.flush() catch {};
}

fn printErrorLine(
    io: std.Io,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
    try stderr_w.interface.print(fmt ++ "\n", args);
    try stderr_w.interface.flush();
}

/// Same as cmdTranslate but discards the output.  Useful for CI: "does
/// this SPIR-V translate at all?"  Exit code 0 means yes.
fn cmdCheck(
    io: std.Io,
    gpa: Allocator,
    input_path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, input_path, arena, .unlimited);
    if (bytes.len % 4 != 0) {
        try printErrorLine(io, "spv2wgsl: input is not a multiple of 4 bytes (not SPIR-V?)", .{});
        std.process.exit(3);
    }
    // Copy into a naturally-4-aligned []u32 rather than @alignCast-ing the
    // byte buffer (readFileAlloc only guarantees byte alignment; the cast
    // panics in safe builds when the buffer is misaligned).
    const words: []u32 = try arena.alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), bytes);

    const wgsl: []const u8 = spv2wgsl.convertSpirvToWgsl(arena, words) catch |err| switch (err) {
        error.NotSpirv, error.MalformedSpirv => {
            try printErrorLine(io, "spv2wgsl: {s}: {s}", .{ input_path, @errorName(err) });
            std.process.exit(3);
        },
        error.OutOfMemory => return err,
        // The recursive walker (Phase 3b) introduces `anyerror` into the
        // error set — defensively handle any other error by reporting
        // and exiting non-zero.
        else => {
            try printErrorLine(io, "spv2wgsl: {s}: {s}", .{ input_path, @errorName(err) });
            std.process.exit(3);
        },
    };
    // Quick stat — confirms work was done; aids casual debugging.
    var stdout_buf: [256]u8 = undefined;
    var stdout_w: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buf);
    stdout_w.interface.print(
        "spv2wgsl: {s} OK ({d} spv bytes -> {d} wgsl bytes)\n",
        .{ input_path, bytes.len, wgsl.len },
    ) catch {};
    stdout_w.interface.flush() catch {};
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

/// Translate `input.spv` → `output.wgsl`.  On failure, write nothing
/// (don't leave a half-written file on disk) and exit with a non-zero
/// status code.
fn cmdTranslate(
    io: std.Io,
    gpa: Allocator,
    input_path: []const u8,
    output_path: []const u8,
    opts: TranslateOpts,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, input_path, arena, .unlimited);
    if (bytes.len % 4 != 0) {
        try printErrorLine(io, "spv2wgsl: input is not a multiple of 4 bytes (not SPIR-V?)", .{});
        std.process.exit(3);
    }
    // Copy into a naturally-4-aligned []u32 rather than @alignCast-ing the
    // byte buffer (readFileAlloc only guarantees byte alignment; the cast
    // panics in safe builds when the buffer is misaligned).
    const words: []u32 = try arena.alloc(u32, bytes.len / 4);
    @memcpy(std.mem.sliceAsBytes(words), bytes);

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
        // are grep-friendly intentionally — the shader transpiles
        // but is unusable; the source must be fixed.
        var line_no: usize = 1;
        var error_count: usize = 0;
        var it = std.mem.splitScalar(u8, wgsl, '\n');
        while (it.next()) |line| : (line_no += 1) {
            if (std.mem.indexOf(u8, line, "// ERROR:") != null) {
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

    // Write the output atomically — write-and-rename is what we'd want
    // in production, but for build-step idempotency the bare write is
    // adequate (the build cache invalidates on input change).
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = wgsl,
    });
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: std.Io = init.io;

    var args_list: ArrayList([]u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var arg_it: std.process.Args.Iterator =
        try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }

    // `args_list` is the SOLE OWNER of every string and frees each element
    // exactly once above.  So parse over a SEPARATE, BORROWED view.
    //
    // This used to filter flags by compacting `args_list.items` IN PLACE:
    // `pos = items[1..]; pos[0] = args[0];` wrote argv[0]'s pointer into slot 1
    // (aliasing one allocation into two slots -> DOUBLE FREE at cleanup, and
    // leaking the string that slot 1 held), and the `--entry=` compaction
    // `pos[w] = pos[r]` shuffled owned pointers the same way.  Silent UB under
    // ReleaseFast; ReleaseSafe's allocator caught it instantly.
    //
    // RULE: never reorder, overwrite or compact an array whose elements are
    // owned allocations freed by index.  Build a borrowed view instead.
    var pos_list: ArrayList([]const u8) = .empty;
    defer pos_list.deinit(gpa); // borrowed pointers — nothing to free

    // Optional `--entry=NAME` selects ONE OpEntryPoint from a multi-kernel
    // module (kompute installKernel ×N); without it, last entry wins.
    var entry: ?[]const u8 = null;

    for (args_list.items, 0..) |arg, i| {
        // Optional leading `--walker=…` flag.  DEPRECATED no-op since F5
        // deleted the legacy walker: the structured-IR path is the only
        // driver.  We still ACCEPT and ignore it so existing callers
        // (`scripts/naga-validate-tint.sh`, `shader_codegen.zig`'s `-Dwalker`)
        // keep working unchanged; the value is not consulted.
        if (i == 1 and startsWith(u8, arg, "--walker=")) {
            continue;
        }
        if (startsWith(u8, arg, "--entry=")) {
            entry = arg["--entry=".len..];
            continue; // drop this arg
        }
        try pos_list.append(gpa, arg);
    }
    const pos: [][]const u8 = pos_list.items;

    if (pos.len < 2) {
        printUsage(io);
        std.process.exit(2);
    }

    if (eql(u8, pos[1], "--check")) {
        if (pos.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdCheck(io, gpa, pos[2]);
    } else if (eql(u8, pos[1], "--strict")) {
        if (pos.len != 4) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdTranslate(io, gpa, pos[2], pos[3], .{ .strict = true, .entry = entry });
    } else {
        if (pos.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdTranslate(io, gpa, pos[1], pos[2], .{ .strict = false, .entry = entry });
    }
}
