//! tools/zspv.zig - pure-Zig SPIR-V binary reader/writer.
//!
//! Phase 1 of the S1.4.5b-followup work: replace the textual-surgery
//! comptime approach (`shader_post.rewriteSamplers`) with semantic
//! SPIR-V binary surgery.  See `src/notes/claude.md` for plan pointers.
//!
//! This file is the foundation - a SPIR-V reader + writer that can
//! round-trip a SPIR-V binary byte-for-byte without change.  No
//! transformation logic yet; that lands in Phase 2.
//!
//! Why phase 1 exists separately: the round-trip is the load-bearing
//! correctness check.  If we can read and write SPIR-V losslessly,
//! the binary parsing is sound and we can build any transformation
//! on top with confidence.  If it can't round-trip, no transformation
//! will be correct either.
//!
//! The command line lives in `zspv_main.zig`, the one file that needs both
//! this reader/writer and the rewrites in `zspv_rewrite.zig`. Keeping it
//! there is what stops the two libraries importing each other: the rewriter
//! needs `Module` from here, and nothing here needs the rewriter.
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
//! Every operand is a u32 - IDs are u32, literal integers are u32,
//! string char-groups are packed u32s.  This makes the parser
//! straightforward: we don't need to know each opcode's operand
//! types to read+write losslessly; we only need to know the word
//! count, which is in the instruction header.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const Allocator = std.mem.Allocator;

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
    /// big-endian binary (we only support little-endian - every
    /// real-world SPIR-V producer emits LE).
    BadMagic,

    /// File length isn't a multiple of 4.  SPIR-V is a stream of
    /// u32 words; a partial trailing word means the file is truncated.
    NotAlignedToWord,

    /// File is shorter than the 5-word header.
    HeaderTruncated,

    /// An instruction's claimed word count would read past the end
    /// of the file, or word_count is 0 (which is illegal - every
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
/// debug-info massaging - pure round-trip semantics.
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

// ---- Tests ----------------------------------------------------------

test "identity round-trip on a tiny hand-crafted module" {
    // Minimal valid-looking SPIR-V: header + one OpNop (opcode=0, wc=1).
    // OpNop has zero operands.  This isn't a fully-valid SPIR-V module
    // (no OpMemoryModel, etc.) but the reader/writer don't care -
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
