//! elf_needs - what a Linux program asks of the system that starts it, and the build's check of it.
//!
//! A program linked against a C library carries, beside its code, the list of what it expects to find when it
//! starts: the dynamic loader that starts it (its interpreter, `PT_INTERP`), the shared libraries linked by name
//! (`DT_NEEDED`), and of each, the symbol versions it uses (`.gnu.version_r`). glibc's versions are named for the
//! release that last changed a function - `GLIBC_2.2.5` ... `GLIBC_2.31` ... - and a program that names
//! `GLIBC_2.34` does not start on a system whose glibc is 2.31: the loader refuses it before `main`.
//!
//! zimr's Linux programs (linux_port_plan.md) are built on any machine against Zig's own glibc stubs, for one glibc
//! (`linux_glibc_floor` in build.zig), and open every other system library - X11, ALSA, Vulkan - at run time with
//! `dlopen`, so that a program starts on a machine without them and says what is missing. This tool reads a linked
//! program and fails when it asks for more: a glibc version past the floor, or a library linked by name that is not
//! glibc's own. `platforms-check` runs it on the Linux launcher, so a change that would raise the oldest Linux the
//! programs start on - a newer std function, a new engine path - fails here the day it lands, not on someone's
//! older machine.
//!
//! Usage: `elf_needs [--glibc-at-most 2.31] [--print] <program>...` - silent when every program passes, unless
//! `--print`, which prints what each one needs.

const std = @import("std");
const cli = @import("cli");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Writer = Io.Writer;
const File = Io.File;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const readInt = std.mem.readInt;
const writeInt = std.mem.writeInt;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const splitScalar = std.mem.splitScalar;
const SplitIterator = std.mem.SplitIterator;
const parseInt = std.fmt.parseInt;
const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;

const NeedsArgs = struct {
    @"--glibc-at-most": []const u8 = "2.31",
    @"--print": bool = false,
    programs: []const []const u8 = &.{},
};

const needs_cli: cli.Config(NeedsArgs) = .{
    .prog = "elf_needs",
    .description = "Fails when a Linux program needs a glibc past a version, or links a library glibc does not ship.",
    .args = .{
        .@"--glibc-at-most" = .{ .description = "the newest glibc version a program may need (default 2.31)" },
        .@"--print" = .{ .description = "print what each program needs, not only what fails" },
        .programs = .{ .description = "the Linux programs to read" },
    },
};

// ELF64's layout: the byte offsets of the fields read here, from the ELF specification (the System V gABI) and
// glibc's `elf.h` - every field little-endian in an x86_64 or AArch64 program. Offsets into the file are `u64`, as
// ELF64 writes them.

/// The file header: the class and byte order in its identification bytes, then where the program and section header
/// tables lie, how big an entry of each is, and how many there are.
const header_size: u64 = 64;
const header_class_offset: u64 = 4;
const header_data_offset: u64 = 5;
const header_program_table_offset: u64 = 32;
const header_section_table_offset: u64 = 40;
const header_program_entry_size_offset: u64 = 54;
const header_program_count_offset: u64 = 56;
const header_section_entry_size_offset: u64 = 58;
const header_section_count_offset: u64 = 60;
/// `ELFCLASS64` and `ELFDATA2LSB`: the only kind of program read here.
const class_64: u8 = 2;
const data_little_endian: u8 = 1;
/// A program header: its type, and where its bytes lie in the file.
const program_type_offset: u64 = 0;
const program_file_offset_offset: u64 = 8;
const program_file_size_offset: u64 = 32;
/// `PT_INTERP`: the segment naming the interpreter, a path ending in a zero byte.
const program_type_interpreter: u32 = 3;
/// A section header: its type, where its bytes lie, its link (the section holding its strings) and its info (for
/// `.gnu.version_r`, how many entries it holds).
const section_type_offset: u64 = 4;
const section_file_offset_offset: u64 = 24;
const section_size_offset: u64 = 32;
const section_link_offset: u64 = 40;
const section_info_offset: u64 = 44;
/// `SHT_DYNAMIC` and `SHT_GNU_verneed`.
const section_type_dynamic: u32 = 6;
const section_type_version_needs: u32 = 0x6fff_fffe;
/// A dynamic entry: a tag and a value, 16 bytes. `DT_NULL` ends the list; `DT_NEEDED`'s value is a library's name.
const dynamic_entry_size: u64 = 16;
const dynamic_value_offset: u64 = 8;
const dynamic_tag_end: i64 = 0;
const dynamic_tag_needed: i64 = 1;
/// A version-needs entry (`Elf64_Verneed`): how many versions it requires, its library's name, where its first
/// version entry lies and where the next library's entry lies (both relative to this one; 0 ends the list).
const needs_count_offset: u64 = 2;
const needs_file_offset: u64 = 4;
const needs_first_version_offset: u64 = 8;
const needs_next_offset: u64 = 12;
/// A required version (`Elf64_Vernaux`): its name, and where the next one lies (relative; 0 ends the list).
const version_name_offset: u64 = 8;
const version_next_offset: u64 = 12;

/// The libraries glibc itself ships, which Zig links by name from its stubs - the only ones a zimr program may need
/// before it starts. Every other library is opened at run time.
const glibc_libraries = [_][]const u8{
    "libc.so.6",
    "libm.so.6",
    "libpthread.so.0",
    "libdl.so.2",
    "librt.so.1",
    "libutil.so.1",
    "libresolv.so.2",
    "ld-linux-x86-64.so.2",
    "ld-linux-aarch64.so.1",
};

/// What could not be read: a file too short for what its headers claim, or not a 64-bit little-endian ELF.
const ReadError = error{ NotElf64LittleEndian, Truncated };

/// A symbol version a program requires, and the library it requires it of.
const RequiredVersion = struct {
    library: []const u8,
    name: []const u8,
};

/// What a program asks of the system that starts it.
const Needs = struct {
    /// The dynamic loader that starts it, or null for a static program.
    interpreter: ?[]const u8,
    /// The libraries linked by name, in the file's order.
    libraries: []const []const u8,
    /// Every symbol version it requires.
    versions: []const RequiredVersion,
};

/// A glibc version as numbers: `2.2.5` is {2, 2, 5}, `2.31` is {2, 31, 0}.
const GlibcVersion = [3]u16;

/// The little-endian integer of type `T` at `offset` in `bytes`; `error.Truncated` when the file ends first.
fn intAt(comptime T: type, bytes: []const u8, offset: u64) ReadError!T {
    const size: usize = @sizeOf(T);
    const file_length: u64 = bytes.len;
    const fits: bool = offset <= file_length and file_length - offset >= size;
    if (!fits) {
        return error.Truncated;
    }
    const start: usize = @intCast(offset);
    return readInt(T, bytes[start..][0..size], .little);
}

/// The zero-terminated text at `index` in the string table at `table_offset`, `table_size` bytes long.
fn stringAt(
    bytes: []const u8,
    table_offset: u64,
    table_size: u64,
    index: u64,
) ReadError![]const u8 {
    const file_length: u64 = bytes.len;
    const table_end: u64 = table_offset + table_size;
    const start: u64 = table_offset + index;
    const inside: bool = table_end <= file_length and start < table_end;
    if (!inside) {
        return error.Truncated;
    }
    const start_index: usize = @intCast(start);
    const end_limit: usize = @intCast(table_end);
    const end_index: usize = indexOfScalarPos(u8, bytes[0..end_limit], start_index, 0) orelse
        return error.Truncated;
    return bytes[start_index..end_index];
}

/// A section's place in the file: where its bytes lie, how many, and its link and info fields.
const Section = struct {
    offset: u64,
    size: u64,
    link: u32,
    info: u32,
};

/// The section header at `index`.
fn sectionAt(
    bytes: []const u8,
    table_offset: u64,
    entry_size: u64,
    index: u64,
) ReadError!Section {
    const header: u64 = table_offset + index * entry_size;
    return .{
        .offset = try intAt(u64, bytes, header + section_file_offset_offset),
        .size = try intAt(u64, bytes, header + section_size_offset),
        .link = try intAt(u32, bytes, header + section_link_offset),
        .info = try intAt(u32, bytes, header + section_info_offset),
    };
}

/// Reads what the 64-bit little-endian ELF program in `bytes` needs. The texts returned point into `bytes`.
fn readNeeds(arena: Allocator, bytes: []const u8) (ReadError || Allocator.Error)!Needs {
    const is_elf: bool = bytes.len >= header_size and startsWith(u8, bytes, "\x7fELF");
    if (!is_elf or bytes[header_class_offset] != class_64 or bytes[header_data_offset] != data_little_endian) {
        return error.NotElf64LittleEndian;
    }
    const program_table: u64 = try intAt(u64, bytes, header_program_table_offset);
    const program_entry_size: u64 = try intAt(u16, bytes, header_program_entry_size_offset);
    const program_count: u64 = try intAt(u16, bytes, header_program_count_offset);
    const section_table: u64 = try intAt(u64, bytes, header_section_table_offset);
    const section_entry_size: u64 = try intAt(u16, bytes, header_section_entry_size_offset);
    const section_count: u64 = try intAt(u16, bytes, header_section_count_offset);

    var interpreter: ?[]const u8 = null;
    var program_index: u64 = 0;
    while (program_index < program_count) : (program_index += 1) {
        const header: u64 = program_table + program_index * program_entry_size;
        const program_type: u32 = try intAt(u32, bytes, header + program_type_offset);
        if (program_type != program_type_interpreter) {
            continue;
        }
        const path_offset: u64 = try intAt(u64, bytes, header + program_file_offset_offset);
        const path_size: u64 = try intAt(u64, bytes, header + program_file_size_offset);
        interpreter = try stringAt(bytes, path_offset, path_size, 0);
    }

    var libraries: ArrayList([]const u8) = .empty;
    var versions: ArrayList(RequiredVersion) = .empty;
    var section_index: u64 = 0;
    while (section_index < section_count) : (section_index += 1) {
        const header: u64 = section_table + section_index * section_entry_size;
        const section_type: u32 = try intAt(u32, bytes, header + section_type_offset);
        const is_dynamic: bool = section_type == section_type_dynamic;
        const is_version_needs: bool = section_type == section_type_version_needs;
        if (!is_dynamic and !is_version_needs) {
            continue;
        }
        const section: Section = try sectionAt(bytes, section_table, section_entry_size, section_index);
        const strings: Section = try sectionAt(bytes, section_table, section_entry_size, section.link);
        if (is_dynamic) {
            const section_end: u64 = section.offset + section.size;
            var entry: u64 = section.offset;
            while (entry + dynamic_entry_size <= section_end) : (entry += dynamic_entry_size) {
                const tag: i64 = try intAt(i64, bytes, entry);
                if (tag == dynamic_tag_end) {
                    break;
                }
                if (tag == dynamic_tag_needed) {
                    const name_index: u64 = try intAt(u64, bytes, entry + dynamic_value_offset);
                    try libraries.append(arena, try stringAt(bytes, strings.offset, strings.size, name_index));
                }
            }
            continue;
        }
        // `.gnu.version_r`: `info` libraries, each followed by the versions required of it.
        var needs_entry: u64 = section.offset;
        for (0..section.info) |_| {
            const version_count: u16 = try intAt(u16, bytes, needs_entry + needs_count_offset);
            const file_index: u32 = try intAt(u32, bytes, needs_entry + needs_file_offset);
            const library: []const u8 = try stringAt(bytes, strings.offset, strings.size, file_index);
            var version_entry: u64 = needs_entry + try intAt(u32, bytes, needs_entry + needs_first_version_offset);
            for (0..version_count) |_| {
                const name_index: u32 = try intAt(u32, bytes, version_entry + version_name_offset);
                const name: []const u8 = try stringAt(bytes, strings.offset, strings.size, name_index);
                try versions.append(arena, .{ .library = library, .name = name });
                const next_version: u32 = try intAt(u32, bytes, version_entry + version_next_offset);
                if (next_version == 0) {
                    break;
                }
                version_entry += next_version;
            }
            const next_needs: u32 = try intAt(u32, bytes, needs_entry + needs_next_offset);
            if (next_needs == 0) {
                break;
            }
            needs_entry += next_needs;
        }
    }
    return .{ .interpreter = interpreter, .libraries = libraries.items, .versions = versions.items };
}

/// `text` - `2.31`, `2.2.5` - as a version; null when it is not one to three numbers between dots.
fn versionOfNumbers(text: []const u8) ?GlibcVersion {
    var version: GlibcVersion = .{ 0, 0, 0 };
    var parts: SplitIterator(u8, .scalar) = splitScalar(u8, text, '.');
    var part_count: usize = 0;
    while (parts.next()) |part| {
        if (part_count == version.len) {
            return null;
        }
        version[part_count] = parseInt(u16, part, 10) catch return null;
        part_count += 1;
    }
    return version;
}

/// The glibc version a symbol version names (`GLIBC_2.28` -> 2.28), or null for any other name - `GLIBC_PRIVATE`,
/// `GLIBC_ABI_DT_RELR`, another library's.
fn glibcVersionOf(name: []const u8) ?GlibcVersion {
    const prefix: []const u8 = "GLIBC_";
    if (!startsWith(u8, name, prefix)) {
        return null;
    }
    return versionOfNumbers(name[prefix.len..]);
}

/// Whether `version` is a later glibc than `limit`.
fn isLater(version: GlibcVersion, limit: GlibcVersion) bool {
    for (version, limit) |part, limit_part| {
        if (part != limit_part) {
            return part > limit_part;
        }
    }
    return false;
}

/// Whether glibc itself ships `library`.
fn isGlibcLibrary(library: []const u8) bool {
    for (glibc_libraries) |glibc_library| {
        if (eql(u8, glibc_library, library)) {
            return true;
        }
    }
    return false;
}

/// Writes `version` as glibc spells it: `2.31`, `2.2.5`.
fn writeVersion(w: *Writer, version: GlibcVersion) Writer.Error!void {
    try w.print("{d}.{d}", .{ version[0], version[1] });
    if (version[2] != 0) {
        try w.print(".{d}", .{version[2]});
    }
}

/// Writes what is wrong with `needs` - each version past `limit`, each version naming no glibc release, each library
/// linked by name that glibc does not ship - and returns how many things are wrong.
fn writeFailures(
    w: *Writer,
    path: []const u8,
    needs: Needs,
    limit: GlibcVersion,
) Writer.Error!usize {
    var failures: usize = 0;
    for (needs.libraries) |library| {
        if (isGlibcLibrary(library)) {
            continue;
        }
        try w.print("elf-needs: {s} links {s} by name: zimr opens every library but glibc's own at run time " ++
            "(dlopen), so that a program starts without it and says what is missing\n", .{ path, library });
        failures += 1;
    }
    for (needs.versions) |required| {
        const version: GlibcVersion = glibcVersionOf(required.name) orelse {
            try w.print("elf-needs: {s} requires {s} of {s}, which names no glibc release\n", .{
                path,
                required.name,
                required.library,
            });
            failures += 1;
            continue;
        };
        if (!isLater(version, limit)) {
            continue;
        }
        try w.print("elf-needs: {s} requires {s} of {s}, past glibc ", .{ path, required.name, required.library });
        try writeVersion(w, limit);
        try w.writeAll(": it would not start on the oldest Linux zimr supports. Avoid the symbol, or raise " ++
            "`linux_glibc_floor` in build.zig, by decision\n");
        failures += 1;
    }
    return failures;
}

/// Writes what `needs` holds: the interpreter, the libraries, and the newest glibc version required.
fn writeNeeds(w: *Writer, path: []const u8, needs: Needs) Writer.Error!void {
    try w.print("elf-needs: {s}\n  interpreter  {s}\n  libraries   ", .{ path, needs.interpreter orelse "none" });
    for (needs.libraries) |library| {
        try w.print(" {s}", .{library});
    }
    var newest: ?GlibcVersion = null;
    for (needs.versions) |required| {
        const version: GlibcVersion = glibcVersionOf(required.name) orelse continue;
        const is_newest: bool = if (newest) |known| isLater(version, known) else true;
        if (is_newest) {
            newest = version;
        }
    }
    try w.writeAll("\n  glibc        ");
    if (newest) |version| {
        try writeVersion(w, version);
        try w.writeAll(" at most\n");
    } else {
        try w.writeAll("no version required\n");
    }
}

pub fn main(init: std.process.Init) !void {
    var arena_state: ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const io: Io = init.io;
    const cwd: Io.Dir = .cwd();
    const args: NeedsArgs = cli.args(&init, NeedsArgs, needs_cli);
    var aw: Writer.Allocating = .init(arena);
    const w: *Writer = &aw.writer;
    var failures: usize = 0;
    const limit: GlibcVersion = versionOfNumbers(args.@"--glibc-at-most") orelse {
        try w.print("elf-needs: --glibc-at-most {s} is not a version such as 2.31\n", .{args.@"--glibc-at-most"});
        try File.stderr().writeStreamingAll(io, aw.written());
        std.process.exit(2);
    };
    for (args.programs) |path| {
        const bytes: []const u8 = cwd.readFileAlloc(io, path, arena, .unlimited) catch {
            try w.print("elf-needs: cannot read {s}\n", .{path});
            failures += 1;
            continue;
        };
        const needs: Needs = readNeeds(arena, bytes) catch |err| {
            try w.print("elf-needs: {s} is not a program this reads: {s}\n", .{ path, @errorName(err) });
            failures += 1;
            continue;
        };
        if (args.@"--print") {
            try writeNeeds(w, path, needs);
        }
        failures += try writeFailures(w, path, needs, limit);
    }
    const has_output: bool = aw.written().len > 0;
    if (has_output) {
        try File.stderr().writeStreamingAll(io, aw.written());
    }
    if (failures > 0) {
        std.process.exit(1);
    }
}

test "elf-needs: versions read, compared and named" {
    try expectEqual(GlibcVersion{ 2, 31, 0 }, versionOfNumbers("2.31").?);
    try expectEqual(GlibcVersion{ 2, 2, 5 }, versionOfNumbers("2.2.5").?);
    try expect(versionOfNumbers("2.x") == null);
    try expect(versionOfNumbers("2.3.4.5") == null);
    try expectEqual(GlibcVersion{ 2, 28, 0 }, glibcVersionOf("GLIBC_2.28").?);
    try expect(glibcVersionOf("GLIBC_PRIVATE") == null);
    try expect(glibcVersionOf("GCC_3.0") == null);
    const floor: GlibcVersion = versionOfNumbers("2.31").?;
    try expect(isLater(versionOfNumbers("2.34").?, floor));
    try expect(!isLater(versionOfNumbers("2.31").?, floor));
    try expect(!isLater(versionOfNumbers("2.2.5").?, floor));
    try expect(isLater(versionOfNumbers("2.31.1").?, floor));
    try expect(isGlibcLibrary("libdl.so.2"));
    try expect(!isGlibcLibrary("libX11.so.6"));
}

/// A small ELF64 program's needs, written by hand at the specification's offsets: an interpreter segment, one
/// `.dynstr`, a `.dynamic` naming two libraries, and a `.gnu.version_r` requiring two versions of the first.
fn writeTestElf(bytes: []u8) void {
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "\x7fELF");
    bytes[header_class_offset] = class_64;
    bytes[header_data_offset] = data_little_endian;
    // One program header at 64, its interpreter's path at 512.
    writeInt(u64, bytes[header_program_table_offset..][0..8], 64, .little);
    writeInt(u16, bytes[header_program_entry_size_offset..][0..2], 56, .little);
    writeInt(u16, bytes[header_program_count_offset..][0..2], 1, .little);
    writeInt(u32, bytes[64 + program_type_offset ..][0..4], program_type_interpreter, .little);
    writeInt(u64, bytes[64 + program_file_offset_offset ..][0..8], 512, .little);
    writeInt(u64, bytes[64 + program_file_size_offset ..][0..8], 28, .little);
    @memcpy(bytes[512..][0..27], "/lib64/ld-linux-x86-64.so.2");
    // Four section headers at 128: none, the strings, the dynamic entries, the version needs.
    writeInt(u64, bytes[header_section_table_offset..][0..8], 128, .little);
    writeInt(u16, bytes[header_section_entry_size_offset..][0..2], 64, .little);
    writeInt(u16, bytes[header_section_count_offset..][0..2], 4, .little);
    const strings: []const u8 = "\x00libc.so.6\x00libdl.so.2\x00GLIBC_2.2.5\x00GLIBC_2.34\x00";
    @memcpy(bytes[640..][0..strings.len], strings);
    const strings_header: usize = 128 + 64;
    writeInt(u64, bytes[strings_header + section_file_offset_offset ..][0..8], 640, .little);
    writeInt(u64, bytes[strings_header + section_size_offset ..][0..8], strings.len, .little);
    const dynamic_header: usize = 128 + 2 * 64;
    writeInt(u32, bytes[dynamic_header + section_type_offset ..][0..4], section_type_dynamic, .little);
    writeInt(u64, bytes[dynamic_header + section_file_offset_offset ..][0..8], 768, .little);
    writeInt(u64, bytes[dynamic_header + section_size_offset ..][0..8], 3 * dynamic_entry_size, .little);
    writeInt(u32, bytes[dynamic_header + section_link_offset ..][0..4], 1, .little);
    writeInt(i64, bytes[768..][0..8], dynamic_tag_needed, .little);
    writeInt(u64, bytes[776..][0..8], 1, .little);
    writeInt(i64, bytes[784..][0..8], dynamic_tag_needed, .little);
    writeInt(u64, bytes[792..][0..8], 11, .little);
    const needs_header: usize = 128 + 3 * 64;
    writeInt(u32, bytes[needs_header + section_type_offset ..][0..4], section_type_version_needs, .little);
    writeInt(u64, bytes[needs_header + section_file_offset_offset ..][0..8], 832, .little);
    writeInt(u64, bytes[needs_header + section_size_offset ..][0..8], 48, .little);
    writeInt(u32, bytes[needs_header + section_link_offset ..][0..4], 1, .little);
    writeInt(u32, bytes[needs_header + section_info_offset ..][0..4], 1, .little);
    // One library, libc.so.6, with two versions: its entries right after it, 16 bytes apart.
    writeInt(u16, bytes[832 + needs_count_offset ..][0..2], 2, .little);
    writeInt(u32, bytes[832 + needs_file_offset ..][0..4], 1, .little);
    writeInt(u32, bytes[832 + needs_first_version_offset ..][0..4], 16, .little);
    writeInt(u32, bytes[848 + version_name_offset ..][0..4], 22, .little);
    writeInt(u32, bytes[848 + version_next_offset ..][0..4], 16, .little);
    writeInt(u32, bytes[864 + version_name_offset ..][0..4], 34, .little);
}

test "elf-needs: a hand-written program's interpreter, libraries and versions, and the version past the floor" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var bytes: [1024]u8 = undefined;
    writeTestElf(&bytes);
    const needs: Needs = try readNeeds(arena, &bytes);
    try expectEqualStrings("/lib64/ld-linux-x86-64.so.2", needs.interpreter.?);
    try expectEqual(@as(usize, 2), needs.libraries.len);
    try expectEqualStrings("libc.so.6", needs.libraries[0]);
    try expectEqualStrings("libdl.so.2", needs.libraries[1]);
    try expectEqual(@as(usize, 2), needs.versions.len);
    try expectEqualStrings("libc.so.6", needs.versions[0].library);
    try expectEqualStrings("GLIBC_2.2.5", needs.versions[0].name);
    try expectEqualStrings("GLIBC_2.34", needs.versions[1].name);
    var aw: Writer.Allocating = .init(arena);
    const failures: usize = try writeFailures(&aw.writer, "test", needs, versionOfNumbers("2.31").?);
    try expectEqual(@as(usize, 1), failures);
    const passes: usize = try writeFailures(&aw.writer, "test", needs, versionOfNumbers("2.34").?);
    try expectEqual(@as(usize, 0), passes);
    try expectError(error.NotElf64LittleEndian, readNeeds(arena, bytes[0..32]));
}
