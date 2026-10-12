//! pdb_void_workaround - a workaround for a Zig compiler bug, and nothing more: it rewrites a Windows program's PDB so
//! LLDB can see the program's functions. Delete this file and its wiring in build.zig (every `pdb_void_workaround`)
//! once Zig emits `void` correctly. The tool fails the build when that happens, so it cannot outlive the bug.
//!
//! THE BUG. Zig's LLVM backend describes `void` to LLVM as a zero-size `DW_ATE_signed` basic type, where LLVM expects
//! no type at all. LLVM's CodeView writer has no type for a zero-size integer and writes T_NOTYPE (0), so every
//! function returning `void` has the return type T_NOTYPE in the PDB. LLDB, with either of its PDB readers, drops a
//! function with that return type: no breakpoint by its name, no arguments or locals, a frame named after the nearest
//! public symbol, and a backtrace that stops there. That is every function returning `void`, and every one returning
//! a struct, an optional or an error union with a payload, since those return through a hidden pointer and so return
//! `void` to LLVM. In hello_world it is 2194 function types, the app's `update` among them: only functions returning
//! a scalar or `!void` were visible.
//!
//! THE FIX. T_NOTYPE becomes T_VOID (3) as the return type of every LF_PROCEDURE and LF_MFUNCTION record in the PDB's
//! type stream. Both are four bytes, so nothing else in the file moves, and the GUID and age that tie the program to
//! its PDB still match. The type stream's hash table keeps the old records' hashes; LLDB does not check them.
//!
//! Usage: `pdb_void_workaround <in.pdb> <out.pdb>` (build.zig runs it on every Windows program's PDB, and installs the
//! result beside the program in place of the linker's).

const std = @import("std");
const cli = @import("cli");
const pdb = std.pdb;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const File = Io.File;
const allocPrint = std.fmt.allocPrint;
const eql = std.mem.eql;
const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const testing_allocator = std.testing.allocator;

/// CodeView's "no type": what LLVM writes as the return type of a Zig function returning `void`.
const t_notype: pdb.TypeIndex = 0x0000;
/// CodeView's `void`.
const t_void: pdb.TypeIndex = 0x0003;
/// The size the stream directory gives a stream that does not exist.
const nil_stream_size: u32 = 0xFFFF_FFFF;

const WorkaroundArgs = struct {
    input: []const u8,
    output: []const u8,
};

const workaround_cli: cli.Config(WorkaroundArgs) = .{
    .prog = "pdb_void_workaround",
    .description = "Works around a Zig compiler bug: gives a PDB's `void` functions a return type LLDB accepts.",
    .args = .{
        .input = .{ .description = "the PDB the linker wrote" },
        .output = .{ .description = "the PDB to write, every T_NOTYPE return type made T_VOID" },
    },
};

/// The little-endian u32 at `offset` in `bytes`.
fn readU32(bytes: []const u8, offset: usize) error{TruncatedPdb}!u32 {
    const fits: bool = offset + @sizeOf(u32) <= bytes.len;
    if (!fits) {
        return error.TruncatedPdb;
    }
    return readInt(u32, bytes[offset..][0..@sizeOf(u32)], .little);
}

/// A stream of an MSF file, the container a PDB is: how many bytes it holds, and the blocks holding them, in order.
const Stream = struct {
    size: u32,
    blocks: []const u32,
};

/// An MSF file in memory, read and written in the fixed-size blocks its superblock declares.
const Msf = struct {
    bytes: []u8,
    block_size: u32,

    fn open(bytes: []u8) error{ NotAPdb, TruncatedPdb }!Msf {
        const magic: []const u8 = pdb.SuperBlock.expect_magic;
        const has_magic: bool = bytes.len >= @sizeOf(pdb.SuperBlock) and eql(u8, bytes[0..magic.len], magic);
        if (!has_magic) {
            return error.NotAPdb;
        }
        // The superblock is the start of block 0, so a block holds at least the superblock.
        const block_size: u32 = try readU32(bytes, @offsetOf(pdb.SuperBlock, "block_size"));
        if (block_size < @sizeOf(pdb.SuperBlock)) {
            return error.NotAPdb;
        }
        return .{ .bytes = bytes, .block_size = block_size };
    }

    /// Block `index` of the file.
    fn block(msf: Msf, index: u32) error{TruncatedPdb}![]u8 {
        const start: usize = @as(usize, index) * msf.block_size;
        const fits: bool = start + msf.block_size <= msf.bytes.len;
        if (!fits) {
            return error.TruncatedPdb;
        }
        return msf.bytes[start..][0..msf.block_size];
    }

    /// How many blocks hold `size` bytes.
    fn blockCount(msf: Msf, size: u32) usize {
        return (@as(usize, size) + msf.block_size - 1) / msf.block_size;
    }

    /// `stream`'s bytes, copied out of its blocks into one buffer.
    fn read(msf: Msf, gpa: Allocator, stream: Stream) ![]u8 {
        const bytes: []u8 = try gpa.alloc(u8, stream.size);
        for (stream.blocks, 0..) |block_index, k| {
            const start: usize = k * msf.block_size;
            const length: usize = @min(msf.block_size, bytes.len - start);
            const source: []const u8 = try msf.block(block_index);
            @memcpy(bytes[start..][0..length], source[0..length]);
        }
        return bytes;
    }

    /// Writes `bytes`, `stream`'s new contents, back over its blocks.
    fn write(msf: Msf, stream: Stream, bytes: []const u8) error{TruncatedPdb}!void {
        for (stream.blocks, 0..) |block_index, k| {
            const start: usize = k * msf.block_size;
            const length: usize = @min(msf.block_size, bytes.len - start);
            const destination: []u8 = try msf.block(block_index);
            @memcpy(destination[0..length], bytes[start..][0..length]);
        }
    }

    /// Stream `which`, found through the stream directory.
    fn findStream(msf: Msf, gpa: Allocator, which: pdb.StreamType) !Stream {
        // The superblock names a block that lists the blocks holding the directory.
        const directory_size: u32 = try readU32(msf.bytes, @offsetOf(pdb.SuperBlock, "num_directory_bytes"));
        const block_map_index: u32 = try readU32(msf.bytes, @offsetOf(pdb.SuperBlock, "block_map_addr"));
        const block_map: []const u8 = try msf.block(block_map_index);
        const directory_blocks: []u32 = try gpa.alloc(u32, msf.blockCount(directory_size));
        for (directory_blocks, 0..) |*block_index, k| {
            block_index.* = try readU32(block_map, k * @sizeOf(u32));
        }
        const directory: []const u8 = try msf.read(gpa, .{ .size = directory_size, .blocks = directory_blocks });

        // The directory holds the stream count, every stream's size, then every stream's block list, in stream order.
        const stream_count: u32 = try readU32(directory, 0);
        const wanted: u32 = @backingInt(which);
        if (wanted >= stream_count) {
            return error.MissingStream;
        }
        var block_list_offset: usize = @sizeOf(u32) * (1 + @as(usize, stream_count));
        for (0..wanted) |earlier| {
            const earlier_size: u32 = try readU32(directory, @sizeOf(u32) * (1 + earlier));
            const earlier_exists: bool = earlier_size != nil_stream_size;
            if (earlier_exists) {
                block_list_offset += @sizeOf(u32) * msf.blockCount(earlier_size);
            }
        }
        const size: u32 = try readU32(directory, @sizeOf(u32) * (1 + @as(usize, wanted)));
        if (size == nil_stream_size) {
            return error.MissingStream;
        }
        const blocks: []u32 = try gpa.alloc(u32, msf.blockCount(size));
        for (blocks, 0..) |*block_index, k| {
            block_index.* = try readU32(directory, block_list_offset + @sizeOf(u32) * k);
        }
        return .{ .size = size, .blocks = blocks };
    }
};

/// Makes every function type in the type stream `types` that returns T_NOTYPE return T_VOID. Returns how many.
fn fixVoidReturns(types: []u8) error{TruncatedPdb}!usize {
    // The TPI and IPI streams share one header layout, which std names after the IPI.
    const header_size: u32 = try readU32(types, @offsetOf(pdb.IpiStreamHeader, "header_size"));
    const record_bytes: u32 = try readU32(types, @offsetOf(pdb.IpiStreamHeader, "type_record_bytes"));
    const records_end: usize = @as(usize, header_size) + record_bytes;
    if (records_end > types.len) {
        return error.TruncatedPdb;
    }
    var fixed_count: usize = 0;
    var record_start: usize = header_size;
    while (record_start < records_end) {
        // A record is its length, which leaves out the length field itself, its kind, then the kind's fields.
        const prefix_fits: bool = record_start + @sizeOf(pdb.LfRecordPrefix) <= records_end;
        if (!prefix_fits) {
            return error.TruncatedPdb;
        }
        const record_length: u16 = readInt(u16, types[record_start..][0..2], .little);
        const kind_start: usize = record_start + @offsetOf(pdb.LfRecordPrefix, "kind");
        const kind: pdb.LfRecordKind = @fromBackingInt(readInt(u16, types[kind_start..][0..2], .little));
        const record_end: usize = kind_start + record_length;
        if (record_end > records_end) {
            return error.TruncatedPdb;
        }
        // LF_PROCEDURE and LF_MFUNCTION both open with the return type.
        const is_function_type: bool = kind == .procedure or kind == .mfunction;
        if (is_function_type) {
            const return_type_start: usize = record_start + @sizeOf(pdb.LfRecordPrefix);
            if (return_type_start + @sizeOf(pdb.TypeIndex) > record_end) {
                return error.TruncatedPdb;
            }
            const return_type: *[@sizeOf(pdb.TypeIndex)]u8 = types[return_type_start..][0..@sizeOf(pdb.TypeIndex)];
            const returns_no_type: bool = readInt(pdb.TypeIndex, return_type, .little) == t_notype;
            if (returns_no_type) {
                writeInt(pdb.TypeIndex, return_type, t_void, .little);
                fixed_count += 1;
            }
        }
        record_start = record_end;
    }
    return fixed_count;
}

/// Applies the workaround to the PDB `bytes`, in place. Returns how many function types it rewrote.
fn fixPdb(gpa: Allocator, bytes: []u8) !usize {
    const msf: Msf = try .open(bytes);
    const type_stream: Stream = try msf.findStream(gpa, .tpi);
    const types: []u8 = try msf.read(gpa, type_stream);
    const fixed_count: usize = try fixVoidReturns(types);
    try msf.write(type_stream, types);
    return fixed_count;
}

pub fn main(init: std.process.Init) !u8 {
    const arena: Allocator = init.arena.allocator();
    const io: Io = init.io;
    const cwd: Io.Dir = .cwd();
    const args: WorkaroundArgs = cli.args(&init, WorkaroundArgs, workaround_cli);
    const bytes: []u8 = try cwd.readFileAlloc(io, args.input, arena, .unlimited);
    const fixed_count: usize = fixPdb(arena, bytes) catch |err| {
        const message: []const u8 = try allocPrint(arena, "pdb-void-workaround: {s}: {s}\n", .{
            args.input,
            @errorName(err),
        });
        try File.stderr().writeStreamingAll(io, message);
        return 1;
    };
    // Nothing to rewrite means Zig no longer writes T_NOTYPE for `void`: the bug is fixed, and this should go.
    const compiler_is_fixed: bool = fixed_count == 0;
    if (compiler_is_fixed) {
        const message: []const u8 = try allocPrint(
            arena,
            "pdb-void-workaround: no function type in {s} returns T_NOTYPE, so the Zig compiler bug this works " ++
                "around looks fixed. Delete tools/pdb_void_workaround.zig and every `pdb_void_workaround` in " ++
                "build.zig.\n",
            .{args.input},
        );
        try File.stderr().writeStreamingAll(io, message);
        return 1;
    }
    try cwd.writeFile(io, .{ .sub_path = args.output, .data = bytes });
    return 0;
}

fn putU16(bytes: []u8, offset: usize, value: u16) void {
    writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn putU32(bytes: []u8, offset: usize, value: u32) void {
    writeInt(u32, bytes[offset..][0..4], value, .little);
}

test "pdb-void-workaround: T_NOTYPE returns become T_VOID, in a type stream split across out-of-order blocks" {
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();

    // The type stream: a 56-byte header, then four records. The two returning T_NOTYPE are the ones to rewrite.
    var types: [124]u8 = @splat(0);
    putU32(&types, @offsetOf(pdb.IpiStreamHeader, "header_size"), 56);
    putU32(&types, @offsetOf(pdb.IpiStreamHeader, "type_record_bytes"), 68);
    putU16(&types, 56, 14); // LF_PROCEDURE returning T_NOTYPE, its return type at 60
    putU16(&types, 58, 0x1008);
    putU16(&types, 72, 14); // LF_PROCEDURE returning T_INT4, its return type at 76
    putU16(&types, 74, 0x1008);
    putU32(&types, 76, 0x0074);
    putU16(&types, 88, 6); // LF_ARGLIST, empty
    putU16(&types, 90, 0x1201);
    putU16(&types, 96, 26); // LF_MFUNCTION returning T_NOTYPE, its return type at 100
    putU16(&types, 98, 0x1009);

    // Six 64-byte blocks: the superblock, the block map, the directory, then the type stream in blocks 5 and 3, in
    // that order, around a block 4 nothing names.
    const block_size: usize = 64;
    var file: [6 * block_size]u8 = @splat(0);
    @memcpy(file[0..pdb.SuperBlock.expect_magic.len], pdb.SuperBlock.expect_magic);
    putU32(&file, @offsetOf(pdb.SuperBlock, "block_size"), block_size);
    putU32(&file, @offsetOf(pdb.SuperBlock, "num_blocks"), 6);
    putU32(&file, @offsetOf(pdb.SuperBlock, "num_directory_bytes"), 24);
    putU32(&file, @offsetOf(pdb.SuperBlock, "block_map_addr"), 1);
    putU32(&file, 1 * block_size, 2);
    // The directory: three streams, sized 0, nil and the type stream's length, then the type stream's two blocks.
    const directory: [6]u32 = .{ 3, 0, nil_stream_size, types.len, 5, 3 };
    for (directory, 0..) |word, k| {
        putU32(&file, 2 * block_size + 4 * k, word);
    }
    @memset(file[4 * block_size ..][0..block_size], 0xEE);
    @memcpy(file[5 * block_size ..][0..block_size], types[0..block_size]);
    @memcpy(file[3 * block_size ..][0 .. types.len - block_size], types[block_size..]);

    var expected: [file.len]u8 = file;
    putU32(&expected, 5 * block_size + 60, t_void);
    putU32(&expected, 3 * block_size + (100 - block_size), t_void);

    try expectEqual(@as(usize, 2), try fixPdb(gpa, &file));
    try expectEqualSlices(u8, &expected, &file);
}
