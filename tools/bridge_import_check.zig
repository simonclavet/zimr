//! bridge_import_check - fails the build when a web page's wasm imports a function the bridge does not register.
//!
//! A page's wasm lists every host function it calls in its import section: a module - "dom", "wgpu", "env", "jobs",
//! "wasi_snapshot_preview1" - and a name. When a browser loads the page it binds each import to the function the
//! bridge registered under that name, and refuses the whole page if one is missing ("function import requires a
//! callable"). That happens at load time, on the user's device, never at build time. This check moves the failure
//! into the build: it reads the wasm's function imports, reads the names `src/bridge.zig` registers, and names every
//! import without a registered function.
//!
//! The bridge registers functions in three forms, all read here: `.set("name", funcNum(&...))`,
//! `.set("name", func(&...))`, and the WASI shim's lists of names (`ZimrWasi.install`), registered in a loop. The
//! check compares names only, not the module each was registered in: the bridge gives every function its own name
//! across all of its modules, so a name stands for one function.

const std = @import("std");
const cli = @import("cli");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const Writer = Io.Writer;
const File = Io.File;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const startsWith = std.mem.startsWith;
const trimStart = std.mem.trimStart;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const testing_allocator = std.testing.allocator;

const CheckArgs = struct {
    @"--bridge": []const u8 = "src/bridge.zig",
    programs: []const []const u8 = &.{},
};

const check_cli: cli.Config(CheckArgs) = .{
    .prog = "bridge_import_check",
    .description = "Fails when a web page's wasm imports a function the bridge does not register.",
    .args = .{
        .@"--bridge" = .{ .description = "the bridge's source, which registers the functions" },
        .programs = .{ .description = "the wasm modules to check" },
    },
};

// ---- The wasm's imports ----

/// A function the wasm imports: the module it is imported from, and its name.
const Import = struct {
    module: []const u8,
    name: []const u8,
};

const ParseError = error{
    /// The bytes do not begin with wasm's magic number.
    NotWasm,
    /// A section, a name or a number runs past the end of the bytes, or is malformed.
    Truncated,
};

/// A wasm module begins with its magic number, "\0asm", and a four-byte version; its sections follow. Each section is
/// an id byte, its size as an unsigned LEB128 number, and that many bytes; section 2 holds the imports.
const header_length: usize = 8;
const import_section_id: u8 = 2;

/// An import's kind, the byte after its two names; each is followed by its description.
const ImportKind = enum(u8) {
    /// The index of the function's type.
    function = 0,
    /// A reference type byte, then limits.
    table = 1,
    /// Limits.
    memory = 2,
    /// A value type byte, then a mutability byte.
    global = 3,
    /// An attribute byte, then a type index (exception handling).
    tag = 4,
    _,
};

/// Reads an unsigned LEB128 number at `cursor`: seven bits per byte, the lowest first, the high bit set on every byte
/// but the last. A 32-bit number takes at most five bytes.
fn readUnsigned(bytes: []const u8, cursor: *usize) ParseError!u32 {
    var value: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (cursor.* >= bytes.len) {
            return error.Truncated;
        }
        const byte: u8 = bytes[cursor.*];
        cursor.* += 1;
        value |= @as(u32, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) {
            return value;
        }
        if (shift >= 28) {
            return error.Truncated;
        }
        shift += 7;
    }
}

/// Reads one byte at `cursor`.
fn readByte(bytes: []const u8, cursor: *usize) ParseError!u8 {
    if (cursor.* >= bytes.len) {
        return error.Truncated;
    }
    const byte: u8 = bytes[cursor.*];
    cursor.* += 1;
    return byte;
}

/// Reads a name at `cursor`: its length, then that many bytes of UTF-8.
fn readName(bytes: []const u8, cursor: *usize) ParseError![]const u8 {
    const length: u32 = try readUnsigned(bytes, cursor);
    if (length > bytes.len - cursor.*) {
        return error.Truncated;
    }
    const name: []const u8 = bytes[cursor.*..][0..length];
    cursor.* += length;
    return name;
}

/// Skips a table's or a memory's limits: a flags byte, the minimum, and the maximum when the flags' lowest bit says
/// there is one.
fn skipLimits(bytes: []const u8, cursor: *usize) ParseError!void {
    const flags: u8 = try readByte(bytes, cursor);
    _ = try readUnsigned(bytes, cursor);
    if (flags & 1 != 0) {
        _ = try readUnsigned(bytes, cursor);
    }
}

/// Every function the module `wasm` imports, in its order; the other imports - memories, tables, globals, tags - are
/// skipped.
fn functionImports(gpa: Allocator, wasm: []const u8) (ParseError || Allocator.Error)![]const Import {
    if (wasm.len < header_length or !eql(u8, wasm[0..4], "\x00asm")) {
        return error.NotWasm;
    }
    var imports: ArrayList(Import) = .empty;
    var cursor: usize = header_length;
    while (cursor < wasm.len) {
        const section_id: u8 = try readByte(wasm, &cursor);
        const section_size: u32 = try readUnsigned(wasm, &cursor);
        if (section_size > wasm.len - cursor) {
            return error.Truncated;
        }
        const section_end: usize = cursor + section_size;
        if (section_id == import_section_id) {
            const section: []const u8 = wasm[0..section_end];
            var at: usize = cursor;
            const count: u32 = try readUnsigned(section, &at);
            for (0..count) |_| {
                const module: []const u8 = try readName(section, &at);
                const name: []const u8 = try readName(section, &at);
                const kind: ImportKind = @fromBackingInt(@intCast(try readByte(section, &at)));
                switch (kind) {
                    .function => {
                        _ = try readUnsigned(section, &at);
                        try imports.append(gpa, .{ .module = module, .name = name });
                    },
                    .table => {
                        _ = try readByte(section, &at);
                        try skipLimits(section, &at);
                    },
                    .memory => try skipLimits(section, &at),
                    .global => {
                        _ = try readByte(section, &at);
                        _ = try readByte(section, &at);
                    },
                    .tag => {
                        _ = try readByte(section, &at);
                        _ = try readUnsigned(section, &at);
                    },
                    _ => return error.Truncated,
                }
            }
        }
        cursor = section_end;
    }
    return imports.toOwnedSlice(gpa);
}

// ---- The bridge's registered functions ----

/// The set of names the bridge registers as functions.
const Names = StringHashMapUnmanaged(void);

/// `.set("name", funcNum(&...))` and `.set("name", func(&...))`: a name registered as a function - its call on one
/// line, or split across lines for length, the name or the function on a line of its own. Event handlers registered
/// the same way (`.set("onended", func(...))`) are read too, and harmlessly: no import bears their names.
fn addSetNames(gpa: Allocator, bridge: []const u8, names: *Names) Allocator.Error!void {
    const opening: []const u8 = ".set(";
    var cursor: usize = 0;
    while (indexOfPos(u8, bridge, cursor, opening)) |found| {
        cursor = found + opening.len;
        const argument: []const u8 = trimStart(u8, bridge[cursor..], " \t\r\n");
        if (!startsWith(u8, argument, "\"")) {
            continue;
        }
        const name_start: usize = bridge.len - argument.len + 1;
        const name_end: usize = indexOfScalarPos(u8, bridge, name_start, '"') orelse return;
        cursor = name_end + 1;
        const rest: []const u8 = bridge[name_end + 1 ..];
        if (!startsWith(u8, rest, ",")) {
            continue;
        }
        const value: []const u8 = trimStart(u8, rest[1..], " \t\r\n");
        if (startsWith(u8, value, "funcNum(") or startsWith(u8, value, "func(")) {
            try names.put(gpa, bridge[name_start..name_end], {});
        }
    }
}

/// The WASI shim's lists: every string in a `[_][]const u8{ ... }` array inside `ZimrWasi`, whose `install`
/// registers each name in a loop.
fn addWasiNames(gpa: Allocator, bridge: []const u8, names: *Names) Allocator.Error!void {
    const wasi_start: usize = indexOf(u8, bridge, "const ZimrWasi = struct {") orelse return;
    const wasi_end: usize = indexOfPos(u8, bridge, wasi_start, "\n};\n") orelse bridge.len;
    const wasi: []const u8 = bridge[0..wasi_end];
    var list_cursor: usize = wasi_start;
    while (indexOfPos(u8, wasi, list_cursor, "[_][]const u8{")) |list_start| {
        const list_end: usize = indexOfPos(u8, wasi, list_start, "};") orelse return;
        var string_cursor: usize = list_start;
        while (indexOfScalarPos(u8, wasi[0..list_end], string_cursor, '"')) |opening_quote| {
            const closing_quote: usize = indexOfScalarPos(u8, wasi[0..list_end], opening_quote + 1, '"') orelse break;
            try names.put(gpa, wasi[opening_quote + 1 .. closing_quote], {});
            string_cursor = closing_quote + 1;
        }
        list_cursor = list_end;
    }
}

/// The names `bridge` - the bridge's source - registers as functions, in its three forms.
fn registeredNames(gpa: Allocator, bridge: []const u8) Allocator.Error!Names {
    var names: Names = .empty;
    try addSetNames(gpa, bridge, &names);
    try addWasiNames(gpa, bridge, &names);
    return names;
}

pub fn main(init: std.process.Init) !void {
    var arena: ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: Io = init.io;
    const cwd: Io.Dir = .cwd();
    const args: CheckArgs = cli.args(&init, CheckArgs, check_cli);
    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    var failures: usize = 0;
    const bridge: []const u8 = cwd.readFileAlloc(io, args.@"--bridge", gpa, .unlimited) catch {
        try w.print("bridge-import-check: cannot read the bridge's source, {s}\n", .{args.@"--bridge"});
        try File.stderr().writeStreamingAll(io, aw.written());
        std.process.exit(1);
    };
    const registered: Names = try registeredNames(gpa, bridge);
    for (args.programs) |path| {
        const wasm: []const u8 = cwd.readFileAlloc(io, path, gpa, .unlimited) catch {
            try w.print("bridge-import-check: cannot read {s}\n", .{path});
            failures += 1;
            continue;
        };
        const imports: []const Import = functionImports(gpa, wasm) catch |err| {
            try w.print("bridge-import-check: {s} is not a wasm module this check can read ({s})\n", .{
                path,
                @errorName(err),
            });
            failures += 1;
            continue;
        };
        for (imports) |import| {
            if (registered.contains(import.name)) {
                continue;
            }
            try w.print("bridge-import-check: {s} imports {s}.{s}, which the bridge ({s}) does not register - " ++
                "a browser would refuse to load the page\n", .{ path, import.module, import.name, args.@"--bridge" });
            failures += 1;
        }
    }
    if (failures == 0) {
        return;
    }
    try File.stderr().writeStreamingAll(io, aw.written());
    std.process.exit(1);
}

test "bridge-import-check: reads a module's function imports, and skips its memory" {
    // The header, then an import section of three imports: env.memory (a memory, minimum 1 page), dom.js_log (a
    // function of type 0), and wasi_snapshot_preview1.fd_write (a function of type 1).
    const header: []const u8 = "\x00asm\x01\x00\x00\x00";
    const imports_body: []const u8 = "\x03" ++
        "\x03env" ++ "\x06memory" ++ "\x02\x00\x01" ++
        "\x03dom" ++ "\x06js_log" ++ "\x00\x00" ++
        "\x16wasi_snapshot_preview1" ++ "\x08fd_write" ++ "\x00\x01";
    const module = header ++ "\x02" ++ [_]u8{imports_body.len} ++ imports_body;
    const gpa: Allocator = testing_allocator;
    const imports: []const Import = try functionImports(gpa, module);
    defer gpa.free(imports);
    try expectEqual(@as(usize, 2), imports.len);
    try expectEqualStrings("dom", imports[0].module);
    try expectEqualStrings("js_log", imports[0].name);
    try expectEqualStrings("wasi_snapshot_preview1", imports[1].module);
    try expectEqualStrings("fd_write", imports[1].name);
    try expectError(error.NotWasm, functionImports(gpa, "not a module"));
}

test "bridge-import-check: reads the bridge's three registration forms" {
    const bridge: []const u8 =
        \\        ns.set("js_texture_destroy", funcNum(&jsTextureDestroy));
        \\        dom.set("js_crypto_random_fill",
        \\            func(&domCryptoRandomFill));
        \\        dom.set(
        \\            "js_set_overlay_textarea_ctrl_enter_for_newline",
        \\            func(&domSetOverlayTextareaCtrlEnterForNewline),
        \\        );
        \\        holder.set("onended", func(&onSourceEnded).call("bind", .{}));
        \\        canvas.set("width", num(4));
        \\const ZimrWasi = struct {
        \\    fn install(ns: Value) void {
        \\        const success = [_][]const u8{ "fd_write", "clock_time_get" };
        \\    }
        \\};
        \\
    ;
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const names: Names = try registeredNames(arena.allocator(), bridge);
    try expect(names.contains("js_texture_destroy"));
    try expect(names.contains("js_crypto_random_fill"));
    try expect(names.contains("js_set_overlay_textarea_ctrl_enter_for_newline"));
    try expect(names.contains("fd_write"));
    try expect(names.contains("clock_time_get"));
    try expect(!names.contains("width"));
    try expect(!names.contains("js_is_fullscreen"));
}
