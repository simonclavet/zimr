//! wgsl_corpus - the spv2wgsl regression corpus: every graphics shader the build compiles, held to
//! tests/fixtures/wgsl_corpus.txt.
//!
//!     wgsl_corpus <corpus> <fixture> <spv2wgsl source>...              check  (`zig build corpus`, in `check`)
//!     wgsl_corpus --refresh <corpus> <fixture> <spv2wgsl source>...    pin    (`zig build corpus-refresh`)
//!
//! <corpus> is the directory `shader_codegen.WgslCorpus` fills: for each shader the build translates, the
//! compiler's SPIR-V and the WGSL a page embeds, as `<source path without .zig>.spv` and `.wgsl`. So the corpus is
//! exactly the shaders this build ships, each named by its source file. (It used to be every `.spv` an old build
//! had left in `.zig-cache`, keyed by the MD5 of its bytes: a new compiler changed every MD5 at once, and the check
//! then compared nothing while it said there were no regressions.)
//!
//! Three checks per shader, and every failure says what to do about it:
//!
//!   * clean - no `__unresolved_N__`, spv2wgsl's placeholder for an id it could not translate. WGSL reserves every
//!     name that starts with `__`, so a single one makes the device refuse the whole module.
//!   * interface - what the shader shows the host: its entry point, the entry's inputs and outputs, and every
//!     binding with its type (`interfaceOf`). None of it depends on which Zig compiled the shader, so it is
//!     compared on every machine and right after a compiler bump - which is when it matters: the bump that broke
//!     every graphics pipeline while every gate was green (2307) did it by moving bindings.
//!   * output - for SPIR-V spv2wgsl has been given before, it must write the same WGSL. Up to three SPIR-V inputs
//!     per shader keep a pinned output, so two machines on two compilers are both covered. New SPIR-V - another
//!     Zig, an edited shader - is not compared: it is not spv2wgsl regressing.
//!
//! `--refresh` writes the fixture from this build: each shader's interface and output, the outputs other machines
//! pinned unless spv2wgsl's source changed since (which makes them stale), and the pinned shaders this build did
//! not compile whose source still exists. A shader whose source is gone is dropped.
//!
//! Exit codes: 0 nothing regressed, 1 something did, 2 a fixture line this tool does not write.

const std = @import("std");
const cli = @import("cli");
const Io = std.Io;
const File = Io.File;
const Writer = Io.Writer;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Md5 = std.crypto.hash.Md5;
const allocPrint = std.fmt.allocPrint;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfScalar = std.mem.indexOfScalar;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const sortSlice = std.mem.sort;
const splitScalar = std.mem.splitScalar;
const startsWith = std.mem.startsWith;
const trim = std.mem.trim;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const testing_allocator = std.testing.allocator;

/// The most SPIR-V inputs one shader keeps a pinned output for, the newest first: room for two machines on two
/// compilers, and the shader's previous revision.
const max_outputs_per_shader: usize = 3;
/// Far bigger than any shader, fixture or spv2wgsl source: a file this size is a mistake.
const max_file_bytes: usize = 64 * 1024 * 1024;
/// How many changed interface lines a failure prints before it counts the rest.
const max_interface_lines_shown: usize = 12;
/// How many shader names a note lists before it counts the rest.
const max_names_shown: usize = 6;
/// An MD5, in hex.
const md5_hex_len: usize = 2 * Md5.digest_length;
/// spv2wgsl's placeholder for an id it could not translate: `__unresolved_<id>__`.
const unresolved_marker: []const u8 = "__unresolved_";
/// Deeper than this a struct keeps its name: WGSL has no recursive structs, so only a malformed module gets here.
const max_struct_depth: u32 = 16;

/// One SPIR-V input and the WGSL spv2wgsl wrote for it, each as the hex MD5 of its bytes.
const Output = struct {
    spirv: []const u8,
    wgsl: []const u8,
};

/// A shader as the fixture remembers it.
const Pinned = struct {
    /// Its source path without `.zig`: `src/shaders/text_sdf_fs`.
    name: []const u8,
    /// `interfaceOf` its WGSL.
    interface: []const []const u8,
    /// The newest first, at most `max_outputs_per_shader`.
    outputs: []const Output,
};

/// The fixture: the spv2wgsl its outputs came from, and every pinned shader, sorted by name.
const Fixture = struct {
    /// `transpilerFingerprint` of spv2wgsl's source when the fixture was written.
    transpiler: []const u8 = "",
    shaders: []const Pinned = &.{},
};

/// A shader as this build compiled it.
const Built = struct {
    name: []const u8,
    /// Its WGSL file in the corpus, for a failure to point at.
    wgsl_path: []const u8,
    output: Output,
    interface: []const []const u8,
    /// How many `__unresolved_N__` its WGSL holds.
    unresolved: usize,
};

/// A WGSL struct: its name, and each member as written (`@location(0) uv: vec2<f32>`, `field_0: vec4<f32>`).
const WgslStruct = struct {
    name: []const u8,
    members: []const []const u8,
};

/// The kinds of failure a check found: each gets its own advice.
const ProblemKinds = struct {
    unresolved: bool = false,
    interface: bool = false,
    output: bool = false,
};

// ============================================================================
// A shader's interface
// ============================================================================

fn isIdentifierStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentifierChar(c: u8) bool {
    return isIdentifierStart(c) or (c >= '0' and c <= '9');
}

fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn entryLessThan(_: void, a: []const []const u8, b: []const []const u8) bool {
    return std.mem.lessThan(u8, a[0], b[0]);
}

fn containsLine(lines: []const []const u8, line: []const u8) bool {
    for (lines) |candidate| {
        if (eql(u8, candidate, line)) {
            return true;
        }
    }
    return false;
}

/// Whether two interfaces hold the same lines, in whatever order.
fn interfacesMatch(a: []const []const u8, b: []const []const u8) bool {
    for (a) |line| {
        if (!containsLine(b, line)) {
            return false;
        }
    }
    for (b) |line| {
        if (!containsLine(a, line)) {
            return false;
        }
    }
    return true;
}

/// The lines of `from` that `to` does not have.
fn missingLines(
    arena: Allocator,
    from: []const []const u8,
    to: []const []const u8,
) ![]const []const u8 {
    var missing: ArrayList([]const u8) = .empty;
    for (from) |line| {
        if (!containsLine(to, line)) {
            try missing.append(arena, line);
        }
    }
    return missing.toOwnedSlice(arena);
}

/// Each line of `text`, without the spaces, tabs and carriage return around it.
fn trimmedLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var lines: ArrayList([]const u8) = .empty;
    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(arena, trim(u8, line, " \t\r"));
    }
    return lines.toOwnedSlice(arena);
}

/// Append `piece` without the spaces, tabs and commas around it - unless nothing is left.
fn appendTrimmed(
    arena: Allocator,
    pieces: *ArrayList([]const u8),
    piece: []const u8,
) !void {
    const trimmed: []const u8 = trim(u8, piece, " \t,");
    if (trimmed.len > 0) {
        try pieces.append(arena, trimmed);
    }
}

/// `text` split at each comma outside `()` and `<>`, every piece trimmed, empty pieces left out.
fn splitTopLevel(arena: Allocator, text: []const u8) ![]const []const u8 {
    var pieces: ArrayList([]const u8) = .empty;
    var depth: usize = 0;
    var piece_start: usize = 0;
    for (text, 0..) |c, i| {
        switch (c) {
            '(', '<' => depth += 1,
            ')', '>' => depth -|= 1,
            ',' => {
                if (depth == 0) {
                    try appendTrimmed(arena, &pieces, text[piece_start..i]);
                    piece_start = i + 1;
                }
            },
            else => {},
        }
    }
    try appendTrimmed(arena, &pieces, text[piece_start..]);
    return pieces.toOwnedSlice(arena);
}

/// The index of the `)` closing the `(` at `open`, or null when nothing closes it.
fn matchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (text[open..], open..) |c, i| {
        if (c == '(') {
            depth += 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                return i;
            }
        }
    }
    return null;
}

/// The type in `name: type`, or all of `text` when it has no `:` (a result written as a bare type).
fn typeOf(text: []const u8) []const u8 {
    const colon: usize = indexOfScalar(u8, text, ':') orelse return text;
    return trim(u8, text[colon + 1 ..], " ");
}

fn findStruct(structs: []const WgslStruct, name: []const u8) ?WgslStruct {
    for (structs) |wgsl_struct| {
        if (eql(u8, wgsl_struct.name, name)) {
            return wgsl_struct;
        }
    }
    return null;
}

/// A struct member without its name - its attributes and its type, which are all its layout depends on:
/// `@align(16) field_3: vec3<f32>` is `@align(16) vec3<f32>`.
fn memberLayout(
    arena: Allocator,
    member: []const u8,
) Allocator.Error![]const u8 {
    const colon: usize = indexOfScalar(u8, member, ':') orelse return member;
    const member_type: []const u8 = trim(u8, member[colon + 1 ..], " ");
    const head: []const u8 = trim(u8, member[0..colon], " ");
    const name_start: usize = std.mem.lastIndexOfScalar(u8, head, ' ') orelse return member_type;
    return allocPrint(arena, "{s} {s}", .{ trim(u8, head[0..name_start], " "), member_type });
}

/// `type_text` with every struct name in it replaced by `{<member type>, ...}`, all the way down.
fn spellOutType(
    arena: Allocator,
    structs: []const WgslStruct,
    type_text: []const u8,
    depth: u32,
) Allocator.Error![]const u8 {
    var spelled: ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < type_text.len) {
        if (!isIdentifierStart(type_text[i])) {
            try spelled.append(arena, type_text[i]);
            i += 1;
            continue;
        }
        const word_start: usize = i;
        while (i < type_text.len and isIdentifierChar(type_text[i])) {
            i += 1;
        }
        const word: []const u8 = type_text[word_start..i];
        const may_spell_out: bool = depth < max_struct_depth;
        const found: ?WgslStruct = if (may_spell_out) findStruct(structs, word) else null;
        const wgsl_struct: WgslStruct = found orelse {
            try spelled.appendSlice(arena, word);
            continue;
        };
        try spelled.append(arena, '{');
        for (wgsl_struct.members, 0..) |member, member_index| {
            if (member_index > 0) {
                try spelled.appendSlice(arena, ", ");
            }
            const layout: []const u8 = try memberLayout(arena, member);
            try spelled.appendSlice(arena, try spellOutType(arena, structs, layout, depth + 1));
        }
        try spelled.append(arena, '}');
    }
    return spelled.toOwnedSlice(arena);
}

/// A binding as `@group(G) @binding(B) var<...> name: <its type, spelled out>`.
fn bindingLine(
    arena: Allocator,
    structs: []const WgslStruct,
    line: []const u8,
) ![]const u8 {
    const declaration: []const u8 = trim(u8, line, " ;");
    const colon: usize = indexOfScalar(u8, declaration, ':') orelse return declaration;
    const binding_type: []const u8 = try spellOutType(arena, structs, trim(u8, declaration[colon + 1 ..], " "), 0);
    return allocPrint(arena, "{s}: {s}", .{ trim(u8, declaration[0..colon], " "), binding_type });
}

/// Every `struct Name { ... };` in `lines`, members as written: one per line, as spv2wgsl writes them, or all on
/// the struct's own line.
fn collectStructs(
    arena: Allocator,
    lines: []const []const u8,
) ![]const WgslStruct {
    var structs: ArrayList(WgslStruct) = .empty;
    var members: ArrayList([]const u8) = .empty;
    var open_struct_name: ?[]const u8 = null;
    for (lines) |line| {
        if (open_struct_name) |struct_name| {
            if (startsWith(u8, line, "}")) {
                try structs.append(arena, .{ .name = struct_name, .members = try members.toOwnedSlice(arena) });
                open_struct_name = null;
            } else {
                try appendTrimmed(arena, &members, line);
            }
            continue;
        }
        if (!startsWith(u8, line, "struct ")) {
            continue;
        }
        const brace: usize = indexOfScalar(u8, line, '{') orelse continue;
        const struct_name: []const u8 = trim(u8, line["struct ".len..brace], " ");
        if (indexOfScalarPos(u8, line, brace, '}')) |close| {
            const one_line_members: []const []const u8 = try splitTopLevel(arena, line[brace + 1 .. close]);
            try structs.append(arena, .{ .name = struct_name, .members = one_line_members });
            continue;
        }
        open_struct_name = struct_name;
    }
    return structs.toOwnedSlice(arena);
}

/// The `fn ...` of the entry point whose stage attribute is on `lines[stage_index]`: the rest of that line, or the
/// next one.
fn entrySignature(lines: []const []const u8, stage_index: usize) []const u8 {
    const stage_line: []const u8 = lines[stage_index];
    if (indexOf(u8, stage_line, "fn ")) |fn_at| {
        return stage_line[fn_at..];
    }
    const has_next_line: bool = stage_index + 1 < lines.len;
    return if (has_next_line) lines[stage_index + 1] else "";
}

/// An entry point whose signature is not one spv2wgsl writes, kept whole so a change to it still shows.
fn rawEntryLine(
    arena: Allocator,
    stage: []const u8,
    signature: []const u8,
) ![]const []const u8 {
    const line: []const u8 = try allocPrint(arena, "{s} {s}", .{ stage, signature });
    return arena.dupe([]const u8, &.{line});
}

/// `<prefix> <x>` for each input or output `x` that `item` stands for: every member of its struct type, or `item`
/// itself when its type is not a struct.
fn appendIo(
    arena: Allocator,
    lines: *ArrayList([]const u8),
    structs: []const WgslStruct,
    prefix: []const u8,
    item: []const u8,
) !void {
    const item_alone: [1][]const u8 = .{item};
    const io_struct: ?WgslStruct = findStruct(structs, typeOf(item));
    const fields: []const []const u8 = if (io_struct) |found| found.members else &item_alone;
    for (fields) |field| {
        try lines.append(arena, try allocPrint(arena, "{s} {s}", .{ prefix, field }));
    }
}

/// One entry point's lines: `<stage> <name>`, then `<name> in <input>` and `<name> out <output>`, each sorted. An
/// input or output of struct type stands for its members.
fn entryLines(
    arena: Allocator,
    structs: []const WgslStruct,
    stage_line: []const u8,
    signature: []const u8,
) ![]const []const u8 {
    const fn_at: usize = indexOf(u8, stage_line, "fn ") orelse stage_line.len;
    const stage: []const u8 = trim(u8, stage_line[0..fn_at], " ");
    // `fn <name>(<params>) -> <result> {`
    const after_fn: []const u8 = if (startsWith(u8, signature, "fn ")) signature["fn ".len..] else signature;
    const open: usize = indexOfScalar(u8, after_fn, '(') orelse return rawEntryLine(arena, stage, signature);
    const close: usize = matchingParen(after_fn, open) orelse return rawEntryLine(arena, stage, signature);
    const name: []const u8 = trim(u8, after_fn[0..open], " ");
    const rest: []const u8 = trim(u8, after_fn[close + 1 ..], " {");
    const result: []const u8 = if (startsWith(u8, rest, "->")) trim(u8, rest["->".len..], " ") else "";

    const input_prefix: []const u8 = try allocPrint(arena, "{s} in", .{name});
    var inputs: ArrayList([]const u8) = .empty;
    for (try splitTopLevel(arena, after_fn[open + 1 .. close])) |param| {
        try appendIo(arena, &inputs, structs, input_prefix, param);
    }
    const output_prefix: []const u8 = try allocPrint(arena, "{s} out", .{name});
    var outputs: ArrayList([]const u8) = .empty;
    if (result.len > 0) {
        try appendIo(arena, &outputs, structs, output_prefix, result);
    }
    sortSlice([]const u8, inputs.items, {}, stringLessThan);
    sortSlice([]const u8, outputs.items, {}, stringLessThan);

    var lines: ArrayList([]const u8) = .empty;
    try lines.append(arena, try allocPrint(arena, "{s} {s}", .{ stage, name }));
    try lines.appendSlice(arena, inputs.items);
    try lines.appendSlice(arena, outputs.items);
    return lines.toOwnedSlice(arena);
}

/// What `wgsl` shows the host, one fact per line, in an order that does not depend on how anything was numbered:
///
///     @fragment entry                                   each entry point: its stage, then its name,
///     entry in @location(0) uv: vec2<f32>               then its inputs and its outputs, each sorted;
///     entry out @location(0) color: vec4<f32>
///     @group(1) @binding(0) var tex: texture_2d<f32>    then every binding, sorted.
///
/// A struct type is spelled out as its member types (`{vec4<f32>, f32}`), because its name is a SPIR-V id the next
/// compiler renumbers.
fn interfaceOf(arena: Allocator, wgsl: []const u8) ![]const []const u8 {
    const lines: []const []const u8 = try trimmedLines(arena, wgsl);
    const structs: []const WgslStruct = try collectStructs(arena, lines);
    var entries: ArrayList([]const []const u8) = .empty;
    var bindings: ArrayList([]const u8) = .empty;
    for (lines, 0..) |line, line_index| {
        if (startsWith(u8, line, "@group(")) {
            try bindings.append(arena, try bindingLine(arena, structs, line));
            continue;
        }
        const is_entry_point: bool = startsWith(u8, line, "@vertex") or startsWith(u8, line, "@fragment") or
            startsWith(u8, line, "@compute");
        if (is_entry_point) {
            try entries.append(arena, try entryLines(arena, structs, line, entrySignature(lines, line_index)));
        }
    }
    sortSlice([]const []const u8, entries.items, {}, entryLessThan);
    sortSlice([]const u8, bindings.items, {}, stringLessThan);
    var interface: ArrayList([]const u8) = .empty;
    for (entries.items) |entry_lines| {
        try interface.appendSlice(arena, entry_lines);
    }
    try interface.appendSlice(arena, bindings.items);
    return interface.toOwnedSlice(arena);
}

// ============================================================================
// The corpus
// ============================================================================

fn builtLessThan(_: void, a: Built, b: Built) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn hexOf(arena: Allocator, digest: [Md5.digest_length]u8) ![]const u8 {
    const hex: [md5_hex_len]u8 = std.fmt.bytesToHex(digest, .lower);
    return arena.dupe(u8, &hex);
}

/// The MD5 of `bytes`, in lowercase hex.
fn md5Hex(arena: Allocator, bytes: []const u8) ![]const u8 {
    var digest: [Md5.digest_length]u8 = undefined;
    Md5.hash(bytes, &digest, .{});
    return hexOf(arena, digest);
}

/// `path` with the host's separator turned into `/`, so a shader has one name on every machine.
fn forwardSlashes(arena: Allocator, path: []const u8) ![]const u8 {
    const copy: []u8 = try arena.dupe(u8, path);
    std.mem.replaceScalar(u8, copy, '\\', '/');
    return copy;
}

/// Every shader in the corpus directory, sorted by name.
fn readCorpus(arena: Allocator, io: Io, corpus_path: []const u8) ![]const Built {
    var corpus_dir: Io.Dir = try Io.Dir.cwd().openDir(io, corpus_path, .{ .iterate = true });
    defer corpus_dir.close(io);
    var walker: Io.Dir.Walker = try corpus_dir.walk(arena);
    defer walker.deinit();
    var built: ArrayList(Built) = .empty;
    while (try walker.next(io)) |entry| {
        const is_spirv: bool = entry.kind == .file and endsWith(u8, entry.path, ".spv");
        if (!is_spirv) {
            continue;
        }
        // The walker's path lives only until its next step, and it is spelled with the host's separator.
        const spirv_path: []const u8 = try arena.dupe(u8, entry.path);
        const stem: []const u8 = spirv_path[0 .. spirv_path.len - ".spv".len];
        const wgsl_path: []const u8 = try allocPrint(arena, "{s}.wgsl", .{stem});
        const spirv: []const u8 = try corpus_dir.readFileAlloc(io, spirv_path, arena, .limited(max_file_bytes));
        const wgsl: []const u8 = try corpus_dir.readFileAlloc(io, wgsl_path, arena, .limited(max_file_bytes));
        try built.append(arena, .{
            .name = try forwardSlashes(arena, stem),
            .wgsl_path = try std.fs.path.join(arena, &.{ corpus_path, wgsl_path }),
            .output = .{ .spirv = try md5Hex(arena, spirv), .wgsl = try md5Hex(arena, wgsl) },
            .interface = try interfaceOf(arena, wgsl),
            .unresolved = std.mem.count(u8, wgsl, unresolved_marker),
        });
    }
    sortSlice(Built, built.items, {}, builtLessThan);
    return built.toOwnedSlice(arena);
}

/// The MD5 of spv2wgsl's source files read as LF lines: a Windows checkout may hold them as CRLF, and one source
/// must give one fingerprint on every machine.
fn transpilerFingerprint(
    arena: Allocator,
    io: Io,
    source_paths: []const [:0]const u8,
) ![]const u8 {
    var md5: Md5 = .init(.{});
    for (source_paths) |source_path| {
        const text: []const u8 = try Io.Dir.cwd().readFileAlloc(io, source_path, arena, .limited(max_file_bytes));
        var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            md5.update(std.mem.trimEnd(u8, line, "\r"));
            md5.update("\n");
        }
    }
    var digest: [Md5.digest_length]u8 = undefined;
    md5.final(&digest);
    return hexOf(arena, digest);
}

/// The file's bytes, or null when there is no such file.
fn readOptionalFile(arena: Allocator, io: Io, path: []const u8) !?[]const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_bytes)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

/// Whether the shader's source, `<name>.zig`, is still in the tree.
fn sourceExists(arena: Allocator, io: Io, name: []const u8) !bool {
    const source_path: []const u8 = try allocPrint(arena, "{s}.zig", .{name});
    Io.Dir.cwd().access(io, source_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

// ============================================================================
// The fixture
// ============================================================================

const fixture_header: []const u8 =
    \\# The spv2wgsl corpus (tools/wgsl_corpus.zig). For every graphics shader the build compiles: what it shows
    \\# the host (`interface`), and the WGSL spv2wgsl wrote for each SPIR-V it was given (`output <spirv md5>
    \\# <wgsl md5>`, the newest first). `transpiler` is the MD5 of the spv2wgsl source those outputs came from.
    \\# `zig build corpus-refresh` writes this file; `zig build corpus` (and `zig build check`) holds every shader
    \\# to it. Commit it with the change that moved it.
    \\
;

/// The fixture as text: the header, the transpiler, then each shader with its interface and its outputs.
fn fixtureText(arena: Allocator, fixture: Fixture) ![]const u8 {
    var text: Writer.Allocating = .init(arena);
    const writer: *Writer = &text.writer;
    try writer.writeAll(fixture_header);
    try writer.print("transpiler {s}\n", .{fixture.transpiler});
    for (fixture.shaders) |shader| {
        try writer.print("\nshader {s}\n", .{shader.name});
        for (shader.interface) |line| {
            try writer.print("  interface {s}\n", .{line});
        }
        for (shader.outputs) |output| {
            try writer.print("  output {s} {s}\n", .{ output.spirv, output.wgsl });
        }
    }
    return text.written();
}

fn isMd5Hex(text: []const u8) bool {
    if (text.len != md5_hex_len) {
        return false;
    }
    for (text) |c| {
        const is_hex_digit: bool = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!is_hex_digit) {
            return false;
        }
    }
    return true;
}

/// `<spirv md5> <wgsl md5>`, or null when that is not what `text` holds.
fn parseOutput(text: []const u8) ?Output {
    const space: usize = indexOfScalar(u8, text, ' ') orelse return null;
    const output: Output = .{ .spirv = text[0..space], .wgsl = trim(u8, text[space + 1 ..], " ") };
    const both_are_md5: bool = isMd5Hex(output.spirv) and isMd5Hex(output.wgsl);
    return if (both_are_md5) output else null;
}

/// Close the shader being read, if any: it takes `interface` and `outputs`, which start over empty.
fn finishPinned(
    arena: Allocator,
    shaders: *ArrayList(Pinned),
    name: ?[]const u8,
    interface: *ArrayList([]const u8),
    outputs: *ArrayList(Output),
) !void {
    const shader_name: []const u8 = name orelse return;
    try shaders.append(arena, .{
        .name = shader_name,
        .interface = try interface.toOwnedSlice(arena),
        .outputs = try outputs.toOwnedSlice(arena),
    });
}

/// The fixture's text as a `Fixture`. A line it does not understand fails, with its number in `out_bad_line`.
fn parseFixture(
    arena: Allocator,
    text: []const u8,
    out_bad_line: *usize,
) !Fixture {
    var fixture: Fixture = .{};
    var shaders: ArrayList(Pinned) = .empty;
    var interface: ArrayList([]const u8) = .empty;
    var outputs: ArrayList(Output) = .empty;
    var shader_name: ?[]const u8 = null;
    for (try trimmedLines(arena, text), 1..) |line, line_number| {
        const in_shader: bool = shader_name != null;
        if (line.len == 0 or startsWith(u8, line, "#")) {
            continue;
        }
        if (startsWith(u8, line, "transpiler ")) {
            fixture.transpiler = trim(u8, line["transpiler ".len..], " ");
        } else if (startsWith(u8, line, "shader ")) {
            try finishPinned(arena, &shaders, shader_name, &interface, &outputs);
            shader_name = trim(u8, line["shader ".len..], " ");
        } else if (in_shader and startsWith(u8, line, "interface ")) {
            try interface.append(arena, line["interface ".len..]);
        } else if (in_shader and startsWith(u8, line, "output ")) {
            const output: Output = parseOutput(line["output ".len..]) orelse {
                out_bad_line.* = line_number;
                return error.FixtureNotUnderstood;
            };
            try outputs.append(arena, output);
        } else {
            out_bad_line.* = line_number;
            return error.FixtureNotUnderstood;
        }
    }
    try finishPinned(arena, &shaders, shader_name, &interface, &outputs);
    fixture.shaders = try shaders.toOwnedSlice(arena);
    return fixture;
}

fn pinnedLessThan(_: void, a: Pinned, b: Pinned) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn findPinned(shaders: []const Pinned, name: []const u8) ?Pinned {
    for (shaders) |shader| {
        if (eql(u8, shader.name, name)) {
            return shader;
        }
    }
    return null;
}

fn findBuilt(built: []const Built, name: []const u8) ?Built {
    for (built) |shader| {
        if (eql(u8, shader.name, name)) {
            return shader;
        }
    }
    return null;
}

/// The WGSL `pinned` keeps for this SPIR-V, or null when it keeps none for it.
fn pinnedWgslFor(pinned: Pinned, spirv: []const u8) ?[]const u8 {
    for (pinned.outputs) |output| {
        if (eql(u8, output.spirv, spirv)) {
            return output.wgsl;
        }
    }
    return null;
}

// ============================================================================
// Check and refresh
// ============================================================================

/// `names`, comma-separated: the first few, then how many more.
fn printNames(out: *Writer, names: []const []const u8) !void {
    for (names, 0..) |name, name_index| {
        if (name_index == max_names_shown) {
            try out.print(" and {d} more", .{names.len - max_names_shown});
            return;
        }
        if (name_index > 0) {
            try out.writeAll(", ");
        }
        try out.writeAll(name);
    }
}

/// A failed interface: the lines it lost (`was:`) and the lines it gained (`now:`), the first few of them.
fn printInterfaceChange(
    out: *Writer,
    name: []const u8,
    removed: []const []const u8,
    added: []const []const u8,
) !void {
    try out.print("\u{2717} {s}: interface changed\n", .{name});
    var shown: usize = 0;
    for (removed) |line| {
        if (shown == max_interface_lines_shown) {
            break;
        }
        try out.print("    was: {s}\n", .{line});
        shown += 1;
    }
    for (added) |line| {
        if (shown == max_interface_lines_shown) {
            break;
        }
        try out.print("    now: {s}\n", .{line});
        shown += 1;
    }
    const hidden: usize = removed.len + added.len - shown;
    if (hidden > 0) {
        try out.print("    ... and {d} more\n", .{hidden});
    }
}

/// Hold `built` to `fixture`: each failure is printed as it is found, then what to do about each kind of failure.
/// Returns the exit code.
fn checkCorpus(
    arena: Allocator,
    fixture_path: []const u8,
    fixture: Fixture,
    built: []const Built,
    transpiler: []const u8,
    out: *Writer,
) !u8 {
    try out.print(
        "WGSL corpus: the {d} graphics shaders this build compiles, held to {s}\n",
        .{ built.len, fixture_path },
    );
    var kinds: ProblemKinds = .{};
    var problem_count: usize = 0;
    var interfaces_compared: usize = 0;
    var interfaces_unchanged: usize = 0;
    var outputs_compared: usize = 0;
    var outputs_unchanged: usize = 0;
    var outputs_not_pinned: usize = 0;
    var not_pinned: ArrayList([]const u8) = .empty;
    for (built) |shader| {
        if (shader.unresolved > 0) {
            try out.print(
                "\u{2717} {s}: {d} unresolved ids (`__unresolved_N__`) in its WGSL\n",
                .{ shader.name, shader.unresolved },
            );
            kinds.unresolved = true;
            problem_count += 1;
        }
        const pinned: Pinned = findPinned(fixture.shaders, shader.name) orelse {
            try not_pinned.append(arena, shader.name);
            continue;
        };
        interfaces_compared += 1;
        const removed: []const []const u8 = try missingLines(arena, pinned.interface, shader.interface);
        const added: []const []const u8 = try missingLines(arena, shader.interface, pinned.interface);
        const interface_unchanged: bool = removed.len == 0 and added.len == 0;
        if (interface_unchanged) {
            interfaces_unchanged += 1;
        } else {
            try printInterfaceChange(out, shader.name, removed, added);
            kinds.interface = true;
            problem_count += 1;
        }
        const pinned_wgsl: []const u8 = pinnedWgslFor(pinned, shader.output.spirv) orelse {
            outputs_not_pinned += 1;
            continue;
        };
        outputs_compared += 1;
        if (eql(u8, pinned_wgsl, shader.output.wgsl)) {
            outputs_unchanged += 1;
        } else {
            try out.print(
                "\u{2717} {s}: spv2wgsl wrote different WGSL for SPIR-V it has seen before\n    now: {s}\n",
                .{ shader.name, shader.wgsl_path },
            );
            kinds.output = true;
            problem_count += 1;
        }
    }
    var not_built: ArrayList([]const u8) = .empty;
    for (fixture.shaders) |pinned| {
        if (findBuilt(built, pinned.name) == null) {
            try not_built.append(arena, pinned.name);
        }
    }

    try out.print(
        "  interface (entry point, inputs, outputs, bindings): {d} of {d} as pinned\n",
        .{ interfaces_unchanged, interfaces_compared },
    );
    try out.print(
        "  WGSL for SPIR-V spv2wgsl has seen before:            {d} of {d} as pinned\n",
        .{ outputs_unchanged, outputs_compared },
    );
    if (not_pinned.items.len > 0) {
        try out.print("  note: {d} not pinned yet (", .{not_pinned.items.len});
        try printNames(out, not_pinned.items);
        try out.writeAll(") - `zig build corpus-refresh` pins them\n");
    }
    if (outputs_not_pinned > 0) {
        try out.print(
            "  note: {d} compiled to SPIR-V the fixture has no WGSL for (another Zig, or an edited shader), so " ++
                "their interface was compared and their WGSL was not - `zig build corpus-refresh` pins it\n",
            .{outputs_not_pinned},
        );
    }
    if (not_built.items.len > 0) {
        try out.print("  note: {d} pinned but not compiled by this build (", .{not_built.items.len});
        try printNames(out, not_built.items);
        try out.writeAll(") - `zig build corpus-refresh` drops a shader whose source is gone\n");
    }

    if (interfaces_compared == 0) {
        try out.writeAll(
            "\u{2717} WGSL corpus: no shader of this build is pinned, so nothing was compared. Pin them with " ++
                "`zig build corpus-refresh`, and commit the fixture.\n",
        );
        return 1;
    }
    if (problem_count == 0) {
        try out.writeAll("\u{2713} WGSL corpus: no regressions\n");
        return 0;
    }
    try out.print("\u{2717} WGSL corpus: {d} problems. What to do:\n", .{problem_count});
    if (kinds.interface) {
        try out.writeAll(
            "  interface changed - what a shader shows the host is not what was pinned. If you changed its schema " ++
                "(its _io.zig)\n    or spv2wgsl on purpose, pin it: `zig build corpus-refresh`, and commit the " ++
                "fixture. If not, the host's bind groups\n    or vertex layout no longer match the shader, and the " ++
                "device will refuse its pipeline.\n",
        );
    }
    if (kinds.output) {
        const transpiler_unchanged: bool = eql(u8, fixture.transpiler, transpiler);
        const likely_cause: []const u8 = if (transpiler_unchanged)
            "spv2wgsl's source is the same as when it was pinned, so the change came from elsewhere: the Zig that " ++
                "built\n    spv2wgsl, or output that is not deterministic"
        else
            "spv2wgsl's source has changed since it was pinned, so that change is the likely cause";
        try out.print(
            "  WGSL changed - spv2wgsl now translates an input it was pinned on differently. {s}. If the new WGSL " ++
                "(the `now:`\n    file) is what you meant, pin it: `zig build corpus-refresh`.\n",
            .{likely_cause},
        );
    }
    if (kinds.unresolved) {
        try out.writeAll(
            "  unresolved ids - spv2wgsl had no translation for an instruction, and WGSL reserves every name " ++
                "starting with `__`,\n    so the device refuses the whole module. Fix spv2wgsl " ++
                "(`spv2wgsl <shader.spv> <out.wgsl>` reproduces it); pinning does not help.\n",
        );
    }
    return 1;
}

/// Write the fixture `built` makes of `old`: every built shader with its interface and its output now, plus the
/// outputs `old` pinned for other SPIR-V while spv2wgsl's source is unchanged, plus the shaders `old` pinned that
/// this build did not compile, while their source exists. Returns the exit code.
fn refreshFixture(
    arena: Allocator,
    io: Io,
    fixture_path: []const u8,
    old: Fixture,
    built: []const Built,
    transpiler: []const u8,
    out: *Writer,
) !u8 {
    // What another spv2wgsl wrote is not what this one writes: those outputs are stale.
    const transpiler_unchanged: bool = eql(u8, old.transpiler, transpiler);
    var shaders: ArrayList(Pinned) = .empty;
    var new_count: usize = 0;
    var new_interface_count: usize = 0;
    var new_output_count: usize = 0;
    var stale_output_count: usize = 0;
    var unresolved_count: usize = 0;
    for (built) |shader| {
        if (shader.unresolved > 0) {
            unresolved_count += 1;
        }
        var outputs: ArrayList(Output) = .empty;
        try outputs.append(arena, shader.output);
        if (findPinned(old.shaders, shader.name)) |pinned| {
            if (!interfacesMatch(pinned.interface, shader.interface)) {
                new_interface_count += 1;
            }
            if (pinnedWgslFor(pinned, shader.output.spirv)) |pinned_wgsl| {
                if (!eql(u8, pinned_wgsl, shader.output.wgsl)) {
                    new_output_count += 1;
                }
            }
            for (pinned.outputs) |output| {
                const is_this_spirv: bool = eql(u8, output.spirv, shader.output.spirv);
                if (is_this_spirv) {
                    continue;
                }
                if (!transpiler_unchanged) {
                    stale_output_count += 1;
                } else if (outputs.items.len < max_outputs_per_shader) {
                    try outputs.append(arena, output);
                }
            }
        } else {
            new_count += 1;
        }
        try shaders.append(arena, .{
            .name = shader.name,
            .interface = shader.interface,
            .outputs = try outputs.toOwnedSlice(arena),
        });
    }
    var kept_count: usize = 0;
    var dropped: ArrayList([]const u8) = .empty;
    for (old.shaders) |pinned| {
        if (findBuilt(built, pinned.name) != null) {
            continue;
        }
        const source_exists: bool = try sourceExists(arena, io, pinned.name);
        if (!source_exists) {
            try dropped.append(arena, pinned.name);
            continue;
        }
        if (!transpiler_unchanged) {
            stale_output_count += pinned.outputs.len;
        }
        try shaders.append(arena, .{
            .name = pinned.name,
            .interface = pinned.interface,
            .outputs = if (transpiler_unchanged) pinned.outputs else &.{},
        });
        kept_count += 1;
    }
    sortSlice(Pinned, shaders.items, {}, pinnedLessThan);
    const fixture: Fixture = .{ .transpiler = transpiler, .shaders = shaders.items };
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = fixture_path, .data = try fixtureText(arena, fixture) });

    try out.print(
        "wrote {s}: {d} shaders - {d} new, {d} with a new interface, {d} with new WGSL for SPIR-V seen before\n",
        .{ fixture_path, shaders.items.len, new_count, new_interface_count, new_output_count },
    );
    if (kept_count > 0) {
        try out.print(
            "  kept {d} pinned shaders this build does not compile: their source still exists\n",
            .{kept_count},
        );
    }
    if (dropped.items.len > 0) {
        try out.print("  dropped {d} whose source is gone: ", .{dropped.items.len});
        try printNames(out, dropped.items);
        try out.writeAll("\n");
    }
    if (stale_output_count > 0) {
        try out.print(
            "  dropped {d} outputs another machine pinned: spv2wgsl's source changed since, so they are stale - " ++
                "`zig build corpus-refresh` there pins its own again\n",
            .{stale_output_count},
        );
    }
    if (unresolved_count > 0) {
        try out.print(
            "  note: {d} shaders have unresolved ids; `zig build corpus` fails on them until spv2wgsl " ++
                "translates them\n",
            .{unresolved_count},
        );
    }
    try out.print("  `git diff {s}` shows what moved\n", .{fixture_path});
    return 0;
}

// ============================================================================
// Entry point
// ============================================================================

/// The command line (std's cli, `src/command_line.zig`).
const CorpusArgs = struct {
    @"--refresh": bool = false,
    corpus: []const u8,
    fixture: []const u8,
    @"transpiler-sources": []const [:0]const u8 = &.{},
};

const corpus_cli: cli.Config(CorpusArgs) = .{
    .prog = "wgsl_corpus",
    .description = "Holds every graphics shader's WGSL to the spv2wgsl corpus fixture, or rewrites the fixture.",
    .args = .{
        .@"--refresh" = .{ .description = "rewrite the fixture from this build instead of checking against it" },
        .corpus = .{ .description = "the build's corpus: <shader>.spv and <shader>.wgsl, by source path" },
        .fixture = .{ .description = "the fixture, tests/fixtures/wgsl_corpus.txt" },
        .@"transpiler-sources" = .{
            .description = "spv2wgsl's source files, which name the spv2wgsl outputs came from",
        },
    },
};

/// Check the corpus against the fixture, or rewrite the fixture from it (`--refresh`). Returns the exit code.
fn runCorpus(
    arena: Allocator,
    io: Io,
    args: CorpusArgs,
    out: *Writer,
) !u8 {
    const built: []const Built = try readCorpus(arena, io, args.corpus);
    if (built.len == 0) {
        try out.print("\u{2717} WGSL corpus: the build collected no shaders into {s}\n", .{args.corpus});
        return 1;
    }
    const transpiler: []const u8 = try transpilerFingerprint(arena, io, args.@"transpiler-sources");
    const fixture_text: ?[]const u8 = try readOptionalFile(arena, io, args.fixture);
    var fixture: Fixture = .{};
    if (fixture_text) |text| {
        var bad_line: usize = 0;
        fixture = parseFixture(arena, text, &bad_line) catch |err| switch (err) {
            error.FixtureNotUnderstood => {
                try out.print(
                    "\u{2717} {s}:{d}: not a line this tool writes. Restore the file from git, or delete it and " ++
                        "run `zig build corpus-refresh`.\n",
                    .{ args.fixture, bad_line },
                );
                return 2;
            },
            else => return err,
        };
    }
    if (args.@"--refresh") {
        return refreshFixture(arena, io, args.fixture, fixture, built, transpiler, out);
    }
    if (fixture_text == null) {
        try out.print(
            "\u{2717} WGSL corpus: {s} does not exist, so nothing was compared. Create it with " ++
                "`zig build corpus-refresh`, and commit it.\n",
            .{args.fixture},
        );
        return 1;
    }
    return checkCorpus(arena, args.fixture, fixture, built, transpiler, out);
}

pub fn main(init: std.process.Init) !u8 {
    var arena_state: ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const io: Io = init.io;
    const args: CorpusArgs = cli.args(&init, CorpusArgs, corpus_cli);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer: File.Writer = File.stdout().writer(io, &stdout_buf);
    const out: *Writer = &stdout_writer.interface;
    const exit_code: u8 = try runCorpus(arena, io, args, out);
    try out.flush();
    return exit_code;
}

// ============================================================================
// Tests
// ============================================================================

test "interfaceOf: the entry point, its inputs and outputs, then the bindings with their structs spelled out" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // The shape spv2wgsl writes, trimmed: structs first, bindings in SPIR-V order, then the entry point.
    const wgsl: []const u8 =
        \\struct S12 {
        \\  field_0: vec4<f32>,
        \\  field_1: f32,
        \\};
        \\struct S13 {
        \\  field_0: S12,
        \\  field_1: array<vec2<f32>>,
        \\};
        \\var<private> frag_color: vec4<f32>;
        \\@group(2) @binding(0) var<uniform> u: S12;
        \\@group(1) @binding(1) var texture0_sampler: sampler;
        \\@group(1) @binding(0) var texture0: texture_2d<f32>;
        \\@group(0) @binding(3) var<storage, read> points: S13;
        \\struct entryInputs {
        \\  @location(1) frag_color: vec4<f32>,
        \\  @location(0) frag_tex_coord: vec2<f32>,
        \\};
        \\struct entryOutputs {
        \\  @location(0) out_color: vec4<f32>,
        \\};
        \\@fragment
        \\fn entry(inputs: entryInputs) -> entryOutputs {
        \\  var outputs: entryOutputs;
        \\  return outputs;
        \\}
    ;
    const expected = [_][]const u8{
        "@fragment entry",
        "entry in @location(0) frag_tex_coord: vec2<f32>",
        "entry in @location(1) frag_color: vec4<f32>",
        "entry out @location(0) out_color: vec4<f32>",
        "@group(0) @binding(3) var<storage, read> points: {{vec4<f32>, f32}, array<vec2<f32>>}",
        "@group(1) @binding(0) var texture0: texture_2d<f32>",
        "@group(1) @binding(1) var texture0_sampler: sampler",
        "@group(2) @binding(0) var<uniform> u: {vec4<f32>, f32}",
    };
    const interface: []const []const u8 = try interfaceOf(arena, wgsl);
    try expectEqual(expected.len, interface.len);
    for (expected, interface) |want, got| {
        try expectEqualStrings(want, got);
    }
}

test "interfaceOf: renumbered SPIR-V ids change nothing, a storage array losing its runtime size does" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const pinned_wgsl: []const u8 =
        \\struct S14 {
        \\  field_0: array<vec2<f32>>,
        \\};
        \\@group(0) @binding(1) var<storage, read> positions: S14;
    ;
    // What the next compiler might write: every id renumbered.
    const renumbered_wgsl: []const u8 =
        \\struct S1213 {
        \\  field_0: array<vec2<f32>>,
        \\};
        \\@group(0) @binding(1) var<storage, read> positions: S1213;
    ;
    // The shape the 1980 bump gave every storage binding: an array with a fixed size.
    const fixed_size_wgsl: []const u8 =
        \\struct S14 {
        \\  field_0: array<vec2<f32>, 64>,
        \\};
        \\@group(0) @binding(1) var<storage, read> positions: S14;
    ;
    const pinned: []const []const u8 = try interfaceOf(arena, pinned_wgsl);
    try expect(interfacesMatch(pinned, try interfaceOf(arena, renumbered_wgsl)));
    try expect(!interfacesMatch(pinned, try interfaceOf(arena, fixed_size_wgsl)));
}

test "the fixture reads back what it wrote" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const outputs = [_]Output{
        .{ .spirv = "0123456789abcdef0123456789abcdef", .wgsl = "fedcba9876543210fedcba9876543210" },
        .{ .spirv = "00000000000000000000000000000001", .wgsl = "00000000000000000000000000000002" },
    };
    const interface = [_][]const u8{ "@fragment entry", "@group(2) @binding(0) var<uniform> u: {vec4<f32>}" };
    const shaders = [_]Pinned{.{ .name = "src/shaders/x_fs", .interface = &interface, .outputs = &outputs }};
    const written: Fixture = .{ .transpiler = "00112233445566778899aabbccddeeff", .shaders = &shaders };
    var bad_line: usize = 0;
    const read: Fixture = try parseFixture(arena, try fixtureText(arena, written), &bad_line);
    try expectEqualStrings(written.transpiler, read.transpiler);
    try expectEqual(1, read.shaders.len);
    try expectEqualStrings("src/shaders/x_fs", read.shaders[0].name);
    try expect(interfacesMatch(&interface, read.shaders[0].interface));
    try expectEqual(outputs.len, read.shaders[0].outputs.len);
    for (outputs, read.shaders[0].outputs) |want, got| {
        try expectEqualStrings(want.spirv, got.spirv);
        try expectEqualStrings(want.wgsl, got.wgsl);
    }
}

test "a fixture line this tool does not write is refused, with its number" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const text: []const u8 =
        \\# a comment
        \\transpiler 00112233445566778899aabbccddeeff
        \\
        \\shader src/shaders/x_fs
        \\  interface @fragment entry
        \\  output 0123 4567
    ;
    var bad_line: usize = 0;
    try expectError(error.FixtureNotUnderstood, parseFixture(arena, text, &bad_line));
    try expectEqual(6, bad_line);
}
