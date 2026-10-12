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
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;

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

/// The functions the bridge registers, each under the module it is registered in: a browser binds an import by its
/// module and its name together, so a name registered in one module does not answer an import from another.
const Registered = struct {
    /// `module.name` for each function registered.
    functions: StringHashMapUnmanaged(void) = .empty,
    /// The module each name is registered in, to say where a missing import's name was registered instead.
    module_of_name: StringHashMapUnmanaged([]const u8) = .empty,

    fn add(
        registered: *Registered,
        gpa: Allocator,
        module: []const u8,
        name: []const u8,
    ) Allocator.Error!void {
        const key: []const u8 = try allocPrint(gpa, "{s}.{s}", .{ module, name });
        try registered.functions.put(gpa, key, {});
        try registered.module_of_name.put(gpa, name, module);
    }

    fn contains(
        registered: *const Registered,
        gpa: Allocator,
        module: []const u8,
        name: []const u8,
    ) bool {
        const key: []const u8 = allocPrint(gpa, "{s}.{s}", .{ module, name }) catch return false;
        return registered.functions.contains(key);
    }
};

/// Which module each object of imports becomes, by the variable holding it: `imports.set("dom", dom)`.
const ModuleOfName = StringHashMapUnmanaged([]const u8);

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// The identifier ending just before `end` in `text`: the receiver of a call `receiver.set(`.
fn identifierBefore(text: []const u8, end: usize) []const u8 {
    var start: usize = end;
    while (start > 0 and isIdentifierByte(text[start - 1])) {
        start -= 1;
    }
    return text[start..end];
}

/// The identifier starting at `start` in `text`, after any blanks.
fn identifierAt(text: []const u8, start: usize) []const u8 {
    const rest: []const u8 = trimStart(u8, text[start..], " \t\r\n");
    var length: usize = 0;
    while (length < rest.len and isIdentifierByte(rest[length])) {
        length += 1;
    }
    return rest[0..length];
}

/// The module of each variable passed to `imports.set("module", variable)`.
fn modulesOfVariables(gpa: Allocator, bridge: []const u8) Allocator.Error!ModuleOfName {
    var modules: ModuleOfName = .empty;
    const opening: []const u8 = "imports.set(\"";
    var cursor: usize = 0;
    while (indexOfPos(u8, bridge, cursor, opening)) |found| {
        const module_start: usize = found + opening.len;
        const module_end: usize = indexOfScalarPos(u8, bridge, module_start, '"') orelse break;
        cursor = module_end + 1;
        if (!startsWith(u8, bridge[module_end + 1 ..], ",")) {
            continue;
        }
        const variable: []const u8 = identifierAt(bridge, module_end + 2);
        if (variable.len > 0) {
            try modules.put(gpa, variable, bridge[module_start..module_end]);
        }
    }
    return modules;
}

/// The module each installer struct registers into, by the variable it is installed on: `ZimrWgpu.install(wgpu_ns)`
/// with `imports.set("wgpu", wgpu_ns)` makes everything `ZimrWgpu`'s `install` registers a `wgpu` import.
fn modulesOfInstallers(
    gpa: Allocator,
    bridge: []const u8,
    modules_of_variables: *const ModuleOfName,
) Allocator.Error!ModuleOfName {
    var modules: ModuleOfName = .empty;
    const opening: []const u8 = ".install(";
    var cursor: usize = 0;
    while (indexOfPos(u8, bridge, cursor, opening)) |found| {
        cursor = found + opening.len;
        const installer: []const u8 = identifierBefore(bridge, found);
        const variable: []const u8 = identifierAt(bridge, cursor);
        const module: []const u8 = modules_of_variables.get(variable) orelse continue;
        if (installer.len > 0) {
            try modules.put(gpa, installer, module);
        }
    }
    return modules;
}

/// Where the name of the last top-level declaration in `text` begins: the last line starting `const ` or
/// `pub const ` - the text's own first line counting as a line start. Null when there is none.
fn lastTopLevelDeclarationName(text: []const u8) ?usize {
    var best: ?usize = null;
    const prefixes = [_][]const u8{ "const ", "pub const " };
    for (prefixes) |prefix| {
        if (startsWith(u8, text, prefix)) {
            best = @max(best orelse 0, prefix.len);
        }
        var line_prefix_buffer: [16]u8 = undefined;
        const line_prefix: []const u8 = bufPrint(&line_prefix_buffer, "\n{s}", .{prefix}) catch continue;
        if (std.mem.lastIndexOf(u8, text, line_prefix)) |found| {
            best = @max(best orelse 0, found + line_prefix.len);
        }
    }
    return best;
}

/// The top-level struct `position` lies inside: the nearest declaration before it at the start of a line,
/// `const Name = struct {` or `pub const Name = struct {`, with no top-level `};` closing it in between. Null outside
/// every top-level struct.
fn enclosingTopLevelStruct(bridge: []const u8, position: usize) ?[]const u8 {
    const before: []const u8 = bridge[0..position];
    const name_start: usize = lastTopLevelDeclarationName(before) orelse return null;
    const declaration: usize = name_start;
    const name: []const u8 = identifierAt(bridge, name_start);
    if (!startsWith(u8, bridge[name_start + name.len ..], " = struct {")) {
        return null;
    }
    if (indexOfPos(u8, before, declaration, "\n};\n") != null) {
        return null;
    }
    return name;
}

/// `.set("name", funcNum(&...))` and `.set("name", func(&...))`: a function registered under `name` - its call on one
/// line, or split across lines for length - in the module of its receiver: a variable that becomes a module itself
/// (`dom.set`), or an installer's own parameter (`ns.set` inside `ZimrWgpu`), whose module is the installer's.
/// Registrations on any other object - an event handler, `holder.set("onended", func(...))` - are no imports, and
/// are skipped.
fn addSetRegistrations(
    gpa: Allocator,
    bridge: []const u8,
    modules_of_variables: *const ModuleOfName,
    modules_of_installers: *const ModuleOfName,
    registered: *Registered,
) Allocator.Error!void {
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
        const is_function: bool = startsWith(u8, value, "funcNum(") or startsWith(u8, value, "func(");
        if (!is_function) {
            continue;
        }
        const receiver: []const u8 = identifierBefore(bridge, found);
        const installer: ?[]const u8 = enclosingTopLevelStruct(bridge, found);
        const installer_module: ?[]const u8 = if (installer) |name| modules_of_installers.get(name) else null;
        const module: []const u8 = modules_of_variables.get(receiver) orelse installer_module orelse continue;
        try registered.add(gpa, module, bridge[name_start..name_end]);
    }
}

/// The WASI shim's lists: every string in a `[_][]const u8{ ... }` array inside `ZimrWasi`, whose `install`
/// registers each name in a loop, in the module `ZimrWasi` is installed on.
fn addWasiRegistrations(
    gpa: Allocator,
    bridge: []const u8,
    modules_of_installers: *const ModuleOfName,
    registered: *Registered,
) Allocator.Error!void {
    const wasi_module: []const u8 = modules_of_installers.get("ZimrWasi") orelse return;
    const wasi_start: usize = indexOf(u8, bridge, "const ZimrWasi = struct {") orelse return;
    const wasi_end: usize = indexOfPos(u8, bridge, wasi_start, "\n};\n") orelse bridge.len;
    const wasi: []const u8 = bridge[0..wasi_end];
    var list_cursor: usize = wasi_start;
    while (indexOfPos(u8, wasi, list_cursor, "[_][]const u8{")) |list_start| {
        const list_end: usize = indexOfPos(u8, wasi, list_start, "};") orelse return;
        var string_cursor: usize = list_start;
        while (indexOfScalarPos(u8, wasi[0..list_end], string_cursor, '"')) |opening_quote| {
            const closing_quote: usize = indexOfScalarPos(u8, wasi[0..list_end], opening_quote + 1, '"') orelse break;
            try registered.add(gpa, wasi_module, wasi[opening_quote + 1 .. closing_quote]);
            string_cursor = closing_quote + 1;
        }
        list_cursor = list_end;
    }
}

/// The functions `bridge` - the bridge's source - registers, each with its module.
fn registeredFunctions(gpa: Allocator, bridge: []const u8) Allocator.Error!Registered {
    var registered: Registered = .{};
    const modules_of_variables: ModuleOfName = try modulesOfVariables(gpa, bridge);
    const modules_of_installers: ModuleOfName = try modulesOfInstallers(gpa, bridge, &modules_of_variables);
    try addSetRegistrations(gpa, bridge, &modules_of_variables, &modules_of_installers, &registered);
    try addWasiRegistrations(gpa, bridge, &modules_of_installers, &registered);
    return registered;
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
    const registered: Registered = try registeredFunctions(gpa, bridge);
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
            if (registered.contains(gpa, import.module, import.name)) {
                continue;
            }
            try w.print("bridge-import-check: {s} imports {s}.{s}, which the bridge ({s}) does not register - " ++
                "a browser would refuse to load the page", .{ path, import.module, import.name, args.@"--bridge" });
            if (registered.module_of_name.get(import.name)) |other_module| {
                try w.print(" (it registers {s}.{s}: the import and the registration name different modules)", .{
                    other_module,
                    import.name,
                });
            }
            try w.print("\n", .{});
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

test "bridge-import-check: reads the bridge's three registration forms, each in its module" {
    const bridge: []const u8 =
        \\const ZimrWgpu = struct {
        \\    fn install(ns: Value) void {
        \\        ns.set("js_texture_destroy", funcNum(&jsTextureDestroy));
        \\        ns.set("js_now_ms", funcNum(&jsNowMs));
        \\    }
        \\};
        \\const ZimrWasi = struct {
        \\    fn install(ns: Value) void {
        \\        const success = [_][]const u8{ "fd_write", "clock_time_get" };
        \\    }
        \\};
        \\fn boot() void {
        \\        dom.set("js_crypto_random_fill",
        \\            func(&domCryptoRandomFill));
        \\        dom.set(
        \\            "js_set_overlay_textarea_ctrl_enter_for_newline",
        \\            func(&domSetOverlayTextareaCtrlEnterForNewline),
        \\        );
        \\        holder.set("onended", func(&onSourceEnded).call("bind", .{}));
        \\        canvas.set("width", num(4));
        \\        imports.set("dom", dom);
        \\        ZimrWgpu.install(wgpu_ns);
        \\        imports.set("wgpu", wgpu_ns);
        \\        ZimrWasi.install(wasi);
        \\        imports.set("wasi_snapshot_preview1", wasi);
        \\}
        \\
    ;
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const registered: Registered = try registeredFunctions(gpa, bridge);
    try expect(registered.contains(gpa, "wgpu", "js_texture_destroy"));
    try expect(registered.contains(gpa, "dom", "js_crypto_random_fill"));
    try expect(registered.contains(gpa, "dom", "js_set_overlay_textarea_ctrl_enter_for_newline"));
    try expect(registered.contains(gpa, "wasi_snapshot_preview1", "fd_write"));
    try expect(registered.contains(gpa, "wasi_snapshot_preview1", "clock_time_get"));
    // An event handler and a property are no imports.
    try expect(registered.module_of_name.get("onended") == null);
    try expect(registered.module_of_name.get("width") == null);
    // A name registered in one module does not answer an import from another: the page that imported
    // `dom.js_now_ms` while the bridge registered `wgpu.js_now_ms` was refused by the browser.
    try expect(registered.contains(gpa, "wgpu", "js_now_ms"));
    try expect(!registered.contains(gpa, "dom", "js_now_ms"));
    try expectEqualStrings("wgpu", registered.module_of_name.get("js_now_ms").?);
}
