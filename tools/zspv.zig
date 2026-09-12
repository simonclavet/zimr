//! tools/zspv.zig — pure-Zig SPIR-V binary reader/writer.
//!
//! Phase 1 of the S1.4.5b-followup work: replace the textual-surgery
//! comptime approach (`shader_post.rewriteSamplers`) with semantic
//! SPIR-V binary surgery.  See `src/notes/claude.md` for plan pointers.
//!
//! This file is the foundation — a SPIR-V reader + writer that can
//! round-trip a SPIR-V binary byte-for-byte without change.  No
//! transformation logic yet; that lands in Phase 2.
//!
//! Why phase 1 exists separately: the round-trip is the load-bearing
//! correctness check.  If we can read and write SPIR-V losslessly,
//! the binary parsing is sound and we can build any transformation
//! on top with confidence.  If it can't round-trip, no transformation
//! will be correct either.
//!
//! Usage:
//!   zspv <input.spv> <output.spv>             # identity round-trip
//!   zspv --check <input.spv>                  # parse + verify, no output
//!   zspv --dump <input.spv>                   # human-readable instruction dump
//!
//! Phase 2 will add `--rewrite-samplers` that does the actual semantic
//! transformation, allowing the limited spirv-opt pass list to be
//! retired and full `-O` to run on the post-rewrite SPIR-V.
//!
//! SPIR-V binary format (from the spec, simplified):
//!   Header: 5 little-endian u32 words:
//!     [0] = 0x07230203 (magic number)
//!     [1] = version  (e.g. 0x00010500 for 1.5)
//!     [2] = generator magic
//!     [3] = bound   (one more than the largest result ID; ID 0 is reserved)
//!     [4] = schema  (0)
//!   Followed by a stream of instructions, each:
//!     [0]      = (word_count << 16) | opcode
//!     [1..wc]  = operands (each is one u32 word; strings are null-terminated
//!                bytes packed little-endian into words and padded out)
//!
//! Every operand is a u32 — IDs are u32, literal integers are u32,
//! string char-groups are packed u32s.  This makes the parser
//! straightforward: we don't need to know each opcode's operand
//! types to read+write losslessly; we only need to know the word
//! count, which is in the instruction header.

const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const startsWith = std.mem.startsWith;
const Allocator = std.mem.Allocator;
const rewriter = @import("zspv_rewrite.zig");

// ---- Constants ------------------------------------------------------

/// First word of every SPIR-V binary.  Little-endian on disk.
pub const spv_magic: u32 = 0x07230203;

/// Header is 5 u32 words.
pub const spv_header_words: usize = 5;

// ---- Types ----------------------------------------------------------

/// A parsed SPIR-V instruction.  Owns its operand slice via the
/// arena allocator passed to `read`.
pub const Instruction = struct {
    /// Opcode (0..65535).  See the SPIR-V spec's instruction grammar
    /// for what each code means.  Phase 1 doesn't interpret these;
    /// Phase 2 will (OpName=5, OpTypeImage=25, OpTypeSampledImage=27,
    /// OpFunctionCall=57, OpImageSampleImplicitLod=87, OpVariable=59,
    /// OpFunction=54, OpFunctionEnd=56, OpLoad=61, OpTypePointer=32).
    opcode: u16,

    /// Operands.  Each is a single u32 from the binary stream.
    /// Length is `word_count - 1` where `word_count` came from the
    /// instruction header.  Strings appear here as packed bytes
    /// (little-endian within each u32, null-terminated, zero-padded).
    operands: []u32,
};

/// Full parsed module.  All instructions live in arena memory.
pub const Module = struct {
    /// Bytes [1..5) of the header.  Index 0 is the magic; we strip
    /// that on read and re-add on write.  Indices: [version,
    /// generator, bound, schema].  `bound` is the only field a
    /// transformation typically touches (must be > max-allocated-ID).
    header: [4]u32,

    /// Instructions in original module order.  Re-emitting them
    /// in this order with their original operands produces a
    /// byte-identical output.
    instructions: []Instruction,
};

// ---- Errors ---------------------------------------------------------

pub const ReadError = error{
    /// File doesn't start with 0x07230203.  Wrong file format, or
    /// big-endian binary (we only support little-endian — every
    /// real-world SPIR-V producer emits LE).
    BadMagic,

    /// File length isn't a multiple of 4.  SPIR-V is a stream of
    /// u32 words; a partial trailing word means the file is truncated.
    NotAlignedToWord,

    /// File is shorter than the 5-word header.
    HeaderTruncated,

    /// An instruction's claimed word count would read past the end
    /// of the file, or word_count is 0 (which is illegal — every
    /// instruction has at least the header word).
    InstructionTruncated,

    /// std allocator failed.
    OutOfMemory,
};

// ---- Read -----------------------------------------------------------

/// Parse a SPIR-V binary from `bytes` into a `Module`.  All allocations
/// (the instruction slice + each instruction's operand slice) come
/// from `alloc`.  Callers should typically pass an ArenaAllocator's
/// allocator so the whole module can be freed in one shot.
pub fn read(alloc: Allocator, bytes: []const u8) ReadError!Module {
    if (bytes.len % 4 != 0) {
        return ReadError.NotAlignedToWord;
    }
    if (bytes.len < spv_header_words * 4) {
        return ReadError.HeaderTruncated;
    }

    // View as a slice of u32 little-endian words.  SPIR-V is always
    // LE on disk; we don't bother supporting BE.
    const total_words: usize = bytes.len / 4;
    var words: []u32 = try alloc.alloc(u32, total_words);
    var i: usize = 0;
    while (i < total_words) : (i += 1) {
        words[i] = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    }

    if (words[0] != spv_magic) {
        return ReadError.BadMagic;
    }

    const header: [4]u32 = .{ words[1], words[2], words[3], words[4] };

    // Count instructions in a first pass so we can allocate the
    // exact slice up front.  Walking the instruction stream costs
    // O(n) words either way; doing it twice is cheap and lets us
    // avoid ArrayList resizing.
    var pos: usize = spv_header_words;
    var instr_count: usize = 0;
    while (pos < total_words) {
        const head: u32 = words[pos];
        const wc: u32 = head >> 16;
        if (wc == 0) {
            return ReadError.InstructionTruncated;
        }
        if (pos + wc > total_words) {
            return ReadError.InstructionTruncated;
        }
        instr_count += 1;
        pos += wc;
    }

    var instructions: []Instruction = try alloc.alloc(Instruction, instr_count);

    // Second pass: actually populate.  Each instruction's operand
    // slice points into a fresh allocation (so re-emitting can
    // tolerate transformations later that grow/shrink operand
    // counts).  Phase 1 doesn't transform, but Phase 2 will, so
    // it's worth setting up the right shape now.
    pos = spv_header_words;
    var idx: usize = 0;
    while (pos < total_words) {
        const head: u32 = words[pos];
        const wc: usize = @intCast(head >> 16);
        const opcode: u16 = @intCast(head & 0xFFFF);
        const operand_count: usize = wc - 1;
        const operands: []u32 = try alloc.alloc(u32, operand_count);
        var k: usize = 0;
        while (k < operand_count) : (k += 1) {
            operands[k] = words[pos + 1 + k];
        }
        instructions[idx] = .{ .opcode = opcode, .operands = operands };
        idx += 1;
        pos += wc;
    }

    alloc.free(words);

    return Module{
        .header = header,
        .instructions = instructions,
    };
}

// ---- Write ----------------------------------------------------------

pub const WriteError = error{
    /// Writer returned an error.
    WriteFailed,
};

fn writeWord(w: *std.Io.Writer, value: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try w.writeAll(&buf);
}

/// Serialize a `Module` back to a SPIR-V binary stream by writing
/// little-endian u32 words into `w` (which is the `.writer` of a
/// caller-owned `std.Io.Writer.Allocating`).  Caller deinits the
/// Allocating.  Output is always little-endian, no padding, no
/// debug-info massaging — pure round-trip semantics.
pub fn write(mod: Module, w: *std.Io.Writer) WriteError!void {
    // Header: magic + the 4 header words.
    writeWord(w, spv_magic) catch return WriteError.WriteFailed;
    for (mod.header) |hw| {
        writeWord(w, hw) catch return WriteError.WriteFailed;
    }

    // Instructions: emit the header word ((wc << 16) | opcode) then
    // the operands.  Word count includes the header word, so
    // wc = operands.len + 1.
    for (mod.instructions) |instr| {
        const wc: u32 = @intCast(instr.operands.len + 1);
        const head: u32 = (wc << 16) | @as(u32, instr.opcode);
        writeWord(w, head) catch return WriteError.WriteFailed;
        for (instr.operands) |op| {
            writeWord(w, op) catch return WriteError.WriteFailed;
        }
    }
}

// ---- Main entry point ----------------------------------------------

fn printUsage(io: std.Io) void {
    var stderr_buf: [512]u8 = undefined;
    var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
    stderr_w.interface.print(
        \\usage: zspv <input.spv> <output.spv>                     # identity round-trip
        \\       zspv --check <input.spv>                          # parse + verify, no output
        \\       zspv --dump <input.spv>                           # instruction dump
        \\       zspv --rewrite-samplers <in.spv> <out.spv>        # S1.4.5b combined-sampler rewrite (GLSL/GL path)
        \\       zspv --rewrite-samplers-wgsl [--sampler-group=N] <in.spv> <out.spv>
        \\           # split-sampler rewrite (WGSL/wgpu path).  --sampler-group sets
        \\           # the @group(N) for synthesized samplers (default 0).
        \\
    , .{}) catch {}; // lint:off catch-suppression: stderr write, best-effort
    stderr_w.interface.flush() catch {}; // lint:off catch-suppression: stderr flush, best-effort
}

fn cmdCheck(
    io: std.Io,
    gpa: Allocator,
    path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const mod: Module = try read(arena, bytes);

    var stdout_buf: [256]u8 = undefined;
    var stdout_w: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_w.interface.print(
        "ok: parsed {d} instructions, header.bound={d}\n",
        .{ mod.instructions.len, mod.header[2] },
    );
    try stdout_w.interface.flush();
}

fn cmdDump(
    io: std.Io,
    gpa: Allocator,
    path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const mod: Module = try read(arena, bytes);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w: std.Io.File.Writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try stdout_w.interface.print(
        "SPIR-V version=0x{x:0>8} generator=0x{x:0>8} bound={d} schema={d}\n",
        .{ mod.header[0], mod.header[1], mod.header[2], mod.header[3] },
    );
    try stdout_w.interface.print(
        "{d} instructions:\n",
        .{mod.instructions.len},
    );
    for (mod.instructions, 0..) |instr, i| {
        try stdout_w.interface.print(
            "  [{d:>5}] op={d:>3} wc={d:>2} operands={any}\n",
            .{ i, instr.opcode, instr.operands.len + 1, instr.operands },
        );
    }
    try stdout_w.interface.flush();
}

/// Read SPIR-V from `in_path`, run the S1.4.5b sampler rewrite,
/// write the result to `out_path`.  Phase 2 of the SPIR-V tool work.
/// See `tools/zspv_rewrite.zig` for the rewrite logic.
fn cmdRewriteSamplers(
    io: std.Io,
    gpa: Allocator,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited);
    var mod: Module = try read(arena, bytes);

    try rewriter.rewriteSamplers(arena, &mod);

    var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer alloc_writer.deinit();
    try write(mod, &alloc_writer.writer);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = alloc_writer.written() });
}

/// WGSL-shape variant of cmdRewriteSamplers — produces SPIR-V with
/// SEPARATE texture and sampler bindings and OpSampledImage combine
/// sites.  This is the shape that survives translation to WGSL via
/// `tools/spv2wgsl.zig`.  Once Phase F of the wgpu migration ships
/// (GL deletion), this becomes the only sampler-rewrite mode and
/// `cmdRewriteSamplers` above goes away.  See
/// `src/notes/webgpu-migration-plan.md` §3 for context.
fn cmdRewriteSamplersWgsl(
    io: std.Io,
    gpa: Allocator,
    in_path: []const u8,
    out_path: []const u8,
    sampler_group: u32,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited);
    var mod: Module = try read(arena, bytes);

    try rewriter.rewriteSamplersWgsl(arena, &mod, sampler_group);

    var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer alloc_writer.deinit();
    try write(mod, &alloc_writer.writer);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = alloc_writer.written() });
}

fn cmdRoundtrip(
    io: std.Io,
    gpa: Allocator,
    in_path: []const u8,
    out_path: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, in_path, arena, .unlimited);
    const mod: Module = try read(arena, bytes);

    // Write to an Allocating writer first, then to disk.  Lets us
    // validate the round-trip is byte-identical with the input
    // before committing.
    var alloc_writer: std.Io.Writer.Allocating = .init(gpa);
    defer alloc_writer.deinit();
    try write(mod, &alloc_writer.writer);
    const out_bytes: []const u8 = alloc_writer.written();

    // Sanity check: in Phase 1 (no transformation), output must
    // match input byte-for-byte.  If this ever fails, the
    // reader/writer is dropping or duplicating data.
    if (!eql(u8, bytes, out_bytes)) {
        var stderr_buf: [256]u8 = undefined;
        var stderr_w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_w.interface.print(
            "error: round-trip mismatch: {d} input bytes -> {d} output bytes\n",
            .{ bytes.len, out_bytes.len },
        );
        try stderr_w.interface.flush();
        std.process.exit(1);
    }

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out_bytes });
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: std.Io = init.io;

    // Collect argv into a flat list.  Zig 0.16's args API requires
    // going through an Iterator (cross-platform: Windows args are
    // WTF-16 internally, need conversion to UTF-8).
    var args_list: ArrayList([]u8) = .empty;
    defer {
        for (args_list.items) |a| gpa.free(a);
        args_list.deinit(gpa);
    }
    var arg_it: std.process.Args.Iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;

    if (args.len < 2) {
        printUsage(io);
        std.process.exit(2);
    }

    // Subcommand dispatch
    if (eql(u8, args[1], "--check")) {
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdCheck(io, gpa, args[2]);
    } else if (eql(u8, args[1], "--dump")) {
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdDump(io, gpa, args[2]);
    } else if (eql(u8, args[1], "--rewrite-samplers")) {
        if (args.len != 4) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdRewriteSamplers(io, gpa, args[2], args[3]);
    } else if (eql(u8, args[1], "--rewrite-samplers-wgsl")) {
        // Optional `--sampler-group=N` flag: sets the
        // DescriptorSet decoration (== @group(N) in WGSL) for the
        // synthesized texture+sampler variables.  Default 0 — the
        // WebGPU convention is "group 0 = per-frame globals," so
        // shaders bundled into a pipeline alongside a VS UBO at
        // group 0 binding 0 want their samplers in a different
        // group (typically 1, the per-material group).  The engine
        // shapes shader uses this; future engine shaders that share
        // a pipeline with a VS UBO will too.
        var sampler_group: u32 = 0;
        var pos_args: [2][]const u8 = .{ "", "" };
        var pos_count: usize = 0;
        for (args[2..]) |a| {
            if (startsWith(u8, a, "--sampler-group=")) {
                const v: []const u8 = a["--sampler-group=".len..];
                sampler_group = std.fmt.parseInt(u32, v, 10) catch {
                    printUsage(io);
                    std.process.exit(2);
                };
            } else {
                if (pos_count >= 2) {
                    printUsage(io);
                    std.process.exit(2);
                }
                pos_args[pos_count] = a;
                pos_count += 1;
            }
        }
        if (pos_count != 2) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdRewriteSamplersWgsl(io, gpa, pos_args[0], pos_args[1], sampler_group);
    } else {
        // Default: identity round-trip.
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try cmdRoundtrip(io, gpa, args[1], args[2]);
    }
}

// ---- Tests ----------------------------------------------------------

test "identity round-trip on a tiny hand-crafted module" {
    // Minimal valid-looking SPIR-V: header + one OpNop (opcode=0, wc=1).
    // OpNop has zero operands.  This isn't a fully-valid SPIR-V module
    // (no OpMemoryModel, etc.) but the reader/writer don't care —
    // they're format-level, not validity-level.
    const input_words = [_]u32{
        spv_magic, // magic
        0x00010500, // version 1.5
        0x00000000, // generator
        0x00000001, // bound
        0x00000000, // schema
        (1 << 16) | 0, // OpNop: wc=1, opcode=0
    };
    var input_bytes: [@sizeOf(@TypeOf(input_words))]u8 = undefined;
    for (input_words, 0..) |w, i| {
        std.mem.writeInt(u32, input_bytes[i * 4 ..][0..4], w, .little);
    }

    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const mod: Module = try read(arena, &input_bytes);
    try expectEqual(@as(usize, 1), mod.instructions.len);
    try expectEqual(@as(u16, 0), mod.instructions[0].opcode);
    try expectEqual(@as(usize, 0), mod.instructions[0].operands.len);
    try expectEqual(@as(u32, 1), mod.header[2]); // bound

    var alloc_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer alloc_writer.deinit();
    try write(mod, &alloc_writer.writer);

    try expectEqualSlices(u8, &input_bytes, alloc_writer.written());
}

test "bad magic is detected" {
    const bad_bytes: [20]u8 = @splat(0xFF);
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try expectError(ReadError.BadMagic, read(arena_state.allocator(), &bad_bytes));
}

test "non-word-aligned input is rejected" {
    const odd_bytes: [21]u8 = @splat(0);
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try expectError(ReadError.NotAlignedToWord, read(arena_state.allocator(), &odd_bytes));
}

test "header-only input parses with zero instructions" {
    const header_only = [_]u32{
        spv_magic,
        0x00010500,
        0,
        1,
        0,
    };
    var bytes: [20]u8 = undefined;
    for (header_only, 0..) |w, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], w, .little);
    }
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const mod: Module = try read(arena_state.allocator(), &bytes);
    try expectEqual(@as(usize, 0), mod.instructions.len);
}

test "truncated instruction is detected" {
    // Header claims an instruction with wc=10 but the file ends there.
    const truncated = [_]u32{
        spv_magic,
        0x00010500,
        0,
        1,
        0,
        (10 << 16) | 0, // claims 10 words but only 1 follows
    };
    var bytes: [24]u8 = undefined;
    for (truncated, 0..) |w, i| {
        std.mem.writeInt(u32, bytes[i * 4 ..][0..4], w, .little);
    }
    var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try expectError(
        ReadError.InstructionTruncated,
        read(arena_state.allocator(), &bytes),
    );
}
