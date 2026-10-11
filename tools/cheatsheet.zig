//! cheatsheet - zimr's public API as one page, generated from the source on every build.
//!
//! The surface is what `src/zimr.zig` exports - what a program reaches through `z.` - read with Zig's own parser:
//!   * `z`: every function, type, constant and re-export zimr.zig declares public. A re-export
//!     (`pub const drawCircle = shapes2d.drawCircle;`) is FOLLOWED to the declaration it names - through files,
//!     containers and aliases - and shown as that declaration, under the name `z.` gives it.
//!   * `z.<namespace>`: for each module zimr.zig exports whole (`pub const ui = @import("ui.zig");`), every public
//!     declaration in it.
//! An entry is the first sentence of its doc comment and its declaration as one line of Zig: a function's
//! signature, a type's kind (`struct`, `enum(u8)`), a constant's type. Each section is one `<code class="zig">`
//! block, so docfmt highlights it with Zig's tokenizer like every other page. One of the doc pages: built on every
//! build, styled by docfmt, checked by the doc gate, carried by `publish`.

const std = @import("std");
const cli = @import("cli");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;
const Index = Ast.Node.Index;
const eql = std.mem.eql;
const allocPrint = std.fmt.allocPrint;
const Io = std.Io;
const indexOf = std.mem.indexOf;
const endsWith = std.mem.endsWith;
const splitScalar = std.mem.splitScalar;
const trim = std.mem.trim;
const sortSlice = std.mem.sort;
const ArrayList = std.ArrayList;

/// The command line (std's cli, `src/command_line.zig`). The build passes both; `zig build cheatsheet` runs it.
const CheatArgs = struct {
    src: []const u8 = "src",
    output: []const u8 = "cheatsheet.html",
};

const cheat_cli: cli.Config(CheatArgs) = .{
    .prog = "cheatsheet",
    .description = "zimr's public API as one page: what src/zimr.zig exports, read with Zig's parser.",
    .args = .{
        .src = .{ .description = "the directory holding zimr.zig" },
        .output = .{ .description = "the page to write" },
    },
};

/// Modules imported by NAME rather than by path, and the file each one is (relative to the source directory).
const named_modules = [_][2][]const u8{
    .{ "zm", "zimrmath.zig" },
    .{ "zn", "zimrnum.zig" },
    .{ "kompute", "kompute.zig" },
    .{ "shader_builtins", "shader_builtins.zig" },
};

/// Past this many hops a path is treated as unreadable: re-exports that loop, or chains nobody writes on purpose.
const max_depth: u8 = 12;
/// A constant's value is shown when it is short; a long one reads as `...`.
const max_value_len: usize = 72;
/// A doc comment is cut to its first sentence, and to this many characters.
const max_doc_len: usize = 160;

/// A parsed file, kept for the whole run: every slice this tool hands out points into its text.
const Source = struct { path: []const u8, ast: Ast };
/// Where a declaration lives: its file, and its node there.
const Found = struct { source: *Source, node: Index };
/// Where a path can continue: a file's top level, or a container's members.
const Scope = struct { source: *Source, members: []const Index };
const Entry = struct { doc: []const u8, line: []const u8 };
const Section = struct { name: []const u8, entries: []const Entry };

/// Every file read, by path - so a file two namespaces share is parsed once.
const Files = struct {
    arena: Allocator,
    io: Io,
    dir: []const u8,
    by_path: std.StringHashMapUnmanaged(*Source) = .empty,

    fn load(self: *Files, path: []const u8) ?*Source {
        if (self.by_path.get(path)) |source| {
            return source;
        }
        const text: []u8 = Io.Dir.cwd().readFileAlloc(self.io, path, self.arena, .unlimited) catch return null;
        const text_z: [:0]u8 = self.arena.allocSentinel(u8, text.len, 0) catch return null;
        @memcpy(text_z, text);
        const source: *Source = self.arena.create(Source) catch return null;
        source.* = .{ .path = path, .ast = Ast.parse(self.arena, text_z, .{ .mode = .zig }) catch return null };
        self.by_path.put(self.arena, path, source) catch return null;
        return source;
    }

    /// The file an `@import("...")` call in `from` names: a path relative to `from`, or a named module.
    fn imported(self: *Files, from: *Source, call: Index) ?*Source {
        const ast: *const Ast = &from.ast;
        const tag: Ast.Node.Tag = ast.nodeTag(call);
        const is_call: bool = tag == .builtin_call_two or tag == .builtin_call_two_comma;
        if (!is_call or !eql(u8, ast.tokenSlice(ast.nodeMainToken(call)), "@import")) {
            return null;
        }
        const arg: Index = ast.nodeData(call).opt_node_and_opt_node[0].unwrap() orelse return null;
        const quoted: []const u8 = ast.tokenSlice(ast.nodeMainToken(arg));
        const name: []const u8 = trim(u8, quoted, "\"");
        for (named_modules) |module| {
            if (eql(u8, name, module[0])) {
                return self.load(std.fs.path.join(self.arena, &.{ self.dir, module[1] }) catch return null);
            }
        }
        if (!endsWith(u8, name, ".zig")) {
            return null;
        }
        const here: []const u8 = std.fs.path.dirname(from.path) orelse ".";
        return self.load(std.fs.path.join(self.arena, &.{ here, name }) catch return null);
    }
};

/// A declaration's name - a constant's or a function's - or null for anything else (a test, a field).
fn declName(ast: *const Ast, node: Index) ?[]const u8 {
    if (ast.fullVarDecl(node)) |var_decl| {
        return ast.tokenSlice(var_decl.ast.mut_token + 1);
    }
    var buf: [1]Index = undefined;
    const proto: Ast.full.FnProto = ast.fullFnProto(&buf, node) orelse return null;
    return if (proto.name_token) |name| ast.tokenSlice(name) else null;
}

fn isPublic(ast: *const Ast, node: Index) bool {
    if (ast.fullVarDecl(node)) |var_decl| {
        return var_decl.visib_token != null;
    }
    var buf: [1]Index = undefined;
    const proto: Ast.full.FnProto = ast.fullFnProto(&buf, node) orelse return false;
    return proto.visib_token != null;
}

fn findDecl(ast: *const Ast, members: []const Index, name: []const u8) ?Index {
    for (members) |member| {
        const member_name: []const u8 = declName(ast, member) orelse continue;
        if (eql(u8, member_name, name)) {
            return member;
        }
    }
    return null;
}

/// What an expression OPENS onto, for a path to continue in: an imported file, a container's members, or - for a
/// name or `a.b` - whatever the declaration it names opens onto.
fn scopeOfExpr(files: *Files, source: *Source, expr: Index, depth: u8) ?Scope {
    if (depth > max_depth) {
        return null;
    }
    if (files.imported(source, expr)) |file| {
        return .{ .source = file, .members = file.ast.rootDecls() };
    }
    var buf: [2]Index = undefined;
    if (source.ast.fullContainerDecl(&buf, expr)) |container| {
        // A container of two members or fewer hands its members back IN `buf`, which dies with this frame - so the
        // scope keeps a copy.
        const members: []const Index = files.arena.dupe(Index, container.ast.members) catch return null;
        return .{ .source = source, .members = members };
    }
    // lint:off decl-order: `a.b` is looked up in the scope `a` opens onto, and `a` is a name - resolution recurses
    const found: Found = declOfExpr(files, source, expr, depth + 1) orelse return null;
    const var_decl: Ast.full.VarDecl = found.source.ast.fullVarDecl(found.node) orelse return null;
    const init: Index = var_decl.ast.init_node.unwrap() orelse return null;
    return scopeOfExpr(files, found.source, init, depth + 1);
}

/// Which declaration an expression NAMES: a top-level name, or `lhs.name` looked up where `lhs` opens onto.
fn declOfExpr(files: *Files, source: *Source, expr: Index, depth: u8) ?Found {
    const ast: *const Ast = &source.ast;
    switch (ast.nodeTag(expr)) {
        .identifier => {
            const name: []const u8 = ast.tokenSlice(ast.nodeMainToken(expr));
            const node: Index = findDecl(ast, ast.rootDecls(), name) orelse return null;
            return .{ .source = source, .node = node };
        },
        .field_access => {
            const lhs: Index, const name_token: Ast.TokenIndex = ast.nodeData(expr).node_and_token;
            const scope: Scope = scopeOfExpr(files, source, lhs, depth + 1) orelse return null;
            const name: []const u8 = ast.tokenSlice(name_token);
            const node: Index = findDecl(&scope.source.ast, scope.members, name) orelse return null;
            return .{ .source = scope.source, .node = node };
        },
        else => return null,
    }
}

/// A node's source text on one line: `//` comments dropped, every run of whitespace one space, `( ` and `, )`
/// tidied - so a signature written over twelve lines reads as one.
fn oneLine(
    arena: Allocator,
    ast: *const Ast,
    first: Ast.TokenIndex,
    end_byte: usize,
) ![]const u8 {
    const text: []const u8 = ast.source[ast.tokenStart(first)..end_byte];
    var out: ArrayList(u8) = .empty;
    var lines = splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const code: []const u8 = raw[0 .. indexOf(u8, raw, "//") orelse raw.len];
        var words = std.mem.tokenizeAny(u8, code, " \t\r");
        while (words.next()) |word| {
            const glue: bool = out.items.len == 0 or out.items[out.items.len - 1] == '(' or word[0] == ')';
            if (!glue) {
                try out.append(arena, ' ');
            }
            try out.appendSlice(arena, word);
        }
    }
    const tidy: []u8 = try std.mem.replaceOwned(u8, arena, out.items, ",)", ")");
    return tidy;
}

/// The first sentence of the doc comment above `node`, or "" when it has none.
fn docOf(arena: Allocator, ast: *const Ast, node: Index) ![]const u8 {
    const first: Ast.TokenIndex = ast.firstToken(node);
    var start: Ast.TokenIndex = first;
    while (start > 0 and ast.tokenTag(start - 1) == .doc_comment) {
        start -= 1;
    }
    var text: ArrayList(u8) = .empty;
    var token: Ast.TokenIndex = start;
    while (token < first) : (token += 1) {
        const line: []const u8 = trim(u8, ast.tokenSlice(token)[3..], " \t");
        if (line.len == 0 and text.items.len > 0) {
            break;
        }
        if (text.items.len > 0) {
            try text.append(arena, ' ');
        }
        try text.appendSlice(arena, line);
        const sentence_ends: bool = indexOf(u8, text.items, ". ") != null or endsWith(u8, line, ".");
        if (sentence_ends) {
            break;
        }
    }
    const period: usize = if (indexOf(u8, text.items, ". ")) |at| at + 1 else text.items.len;
    if (period <= max_doc_len) {
        return text.items[0..period];
    }
    // Only a sentence too long to show whole is marked as cut.
    return allocPrint(arena, "{s}...", .{text.items[0..max_doc_len]});
}

/// The byte just past `token`.
fn tokenEnd(ast: *const Ast, token: Ast.TokenIndex) usize {
    return ast.tokenStart(token) + ast.tokenSlice(token).len;
}

/// A whole node's source on one line.
fn nodeText(arena: Allocator, ast: *const Ast, node: Index) ![]const u8 {
    return oneLine(arena, ast, ast.firstToken(node), tokenEnd(ast, ast.lastToken(node)));
}

/// One declaration as one line of Zig, under `name` (the name `z.` gives it, which a re-export may change).
/// An alias is followed to what it names; what cannot be followed is shown as written.
fn render(files: *Files, found: Found, name: []const u8, depth: u8) !Entry {
    const arena: Allocator = files.arena;
    const ast: *const Ast = &found.source.ast;
    const doc: []const u8 = try docOf(arena, ast, found.node);
    var buf: [1]Index = undefined;
    if (ast.fullFnProto(&buf, found.node)) |proto| {
        const has_body: bool = ast.nodeTag(found.node) == .fn_decl;
        const proto_node: Index = if (has_body) ast.nodeData(found.node).node_and_node[0] else found.node;
        const end: usize = tokenEnd(ast, ast.lastToken(proto_node));
        const signature: []const u8 = try oneLine(arena, ast, ast.firstToken(found.node), end);
        const own_name: []const u8 = if (proto.name_token) |token| ast.tokenSlice(token) else name;
        if (eql(u8, own_name, name)) {
            return .{ .doc = doc, .line = signature };
        }
        const from: []const u8 = try allocPrint(arena, "fn {s}(", .{own_name});
        const to: []const u8 = try allocPrint(arena, "fn {s}(", .{name});
        return .{ .doc = doc, .line = try std.mem.replaceOwned(u8, arena, signature, from, to) };
    }
    const var_decl: Ast.full.VarDecl = ast.fullVarDecl(found.node) orelse return .{ .doc = doc, .line = name };
    const keyword: []const u8 = ast.tokenSlice(var_decl.ast.mut_token);
    const head: []const u8 = try allocPrint(arena, "pub {s} {s}", .{ keyword, name });
    if (var_decl.ast.type_node.unwrap()) |type_node| {
        const type_text: []const u8 = try nodeText(arena, ast, type_node);
        return .{ .doc = doc, .line = try allocPrint(arena, "{s}: {s}", .{ head, type_text }) };
    }
    const init: Index = var_decl.ast.init_node.unwrap() orelse return .{ .doc = doc, .line = head };
    var container_buf: [2]Index = undefined;
    if (ast.fullContainerDecl(&container_buf, init)) |container| {
        // The kind, up to its `{`: `struct`, `extern struct`, `enum(u8)`, `union(enum)`.
        var brace: Ast.TokenIndex = container.ast.main_token;
        while (ast.tokenTag(brace) != .l_brace) {
            brace += 1;
        }
        const kind: []const u8 = try oneLine(arena, ast, ast.firstToken(init), ast.tokenStart(brace));
        return .{ .doc = doc, .line = try allocPrint(arena, "{s} = {s}", .{ head, kind }) };
    }
    const is_alias: bool = ast.nodeTag(init) == .identifier or ast.nodeTag(init) == .field_access;
    if (is_alias and depth < max_depth) {
        if (declOfExpr(files, found.source, init, depth + 1)) |target| {
            const followed: Entry = try render(files, target, name, depth + 1);
            return .{ .doc = if (doc.len > 0) doc else followed.doc, .line = followed.line };
        }
    }
    const value: []const u8 = try nodeText(arena, ast, init);
    const shown: []const u8 = if (value.len <= max_value_len) value else "...";
    return .{ .doc = doc, .line = try allocPrint(arena, "{s} = {s}", .{ head, shown }) };
}

/// Every public declaration a scope holds - a file's top level, or a container's members - in source order.
fn scopeEntries(files: *Files, scope: Scope) ![]const Entry {
    var entries: ArrayList(Entry) = .empty;
    for (scope.members) |node| {
        if (!isPublic(&scope.source.ast, node)) {
            continue;
        }
        const name: []const u8 = declName(&scope.source.ast, node) orelse continue;
        try entries.append(files.arena, try render(files, .{ .source = scope.source, .node = node }, name, 0));
    }
    return entries.items;
}

/// What a `z.` export opens onto when it is a NAMESPACE: a whole module (`= @import("ui.zig")`), or a lowercase
/// name for a container of declarations (`z.rng`, `z.waves`). Zig's own convention tells the two apart from a type:
/// a namespace is named in lowercase, a type in TitleCase - and a type stays one line.
fn namespaceOf(files: *Files, root: *Source, node: Index, name: []const u8) ?Scope {
    const var_decl: Ast.full.VarDecl = root.ast.fullVarDecl(node) orelse return null;
    const value: Index = var_decl.ast.init_node.unwrap() orelse return null;
    if (files.imported(root, value)) |file| {
        return .{ .source = file, .members = file.ast.rootDecls() };
    }
    const lowercase: bool = name[0] >= 'a' and name[0] <= 'z';
    if (!lowercase) {
        return null;
    }
    const scope: Scope = scopeOfExpr(files, root, value, 0) orelse return null;
    for (scope.members) |member| {
        if (isPublic(&scope.source.ast, member)) {
            return scope;
        }
    }
    return null;
}

/// Name order, ignoring case: `BindGroupCache` among the B's, not ahead of `analyser` with every TitleCase name.
fn sectionBefore(_: void, a: Section, b: Section) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

fn appendEscaped(arena: Allocator, html: *ArrayList(u8), text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '&' => try html.appendSlice(arena, "&amp;"),
            '<' => try html.appendSlice(arena, "&lt;"),
            '>' => try html.appendSlice(arena, "&gt;"),
            else => try html.append(arena, char),
        }
    }
}

/// A section: a heading, and one `<code class="zig">` block of `/// doc` + declaration pairs for docfmt to highlight.
fn appendSection(
    arena: Allocator,
    html: *ArrayList(u8),
    id: []const u8,
    title: []const u8,
    entries: []const Entry,
) !void {
    try html.appendSlice(arena, try allocPrint(arena, "<section id=\"{s}\"><h2>{s}</h2>", .{ id, title }));
    try html.appendSlice(arena, "<pre><code class=\"zig\">");
    for (entries) |entry| {
        if (entry.doc.len > 0) {
            try html.appendSlice(arena, "/// ");
            try appendEscaped(arena, html, entry.doc);
            try html.append(arena, '\n');
        }
        try appendEscaped(arena, html, entry.line);
        try html.appendSlice(arena, "\n\n");
    }
    try html.appendSlice(arena, "</code></pre></section>\n");
}

/// The page: the shared-style MARKER (docfmt injects the stylesheet every doc page shares), a header with the
/// counts, a nav of sections, then `z` and each namespace in name order.
fn writePage(
    arena: Allocator,
    io: Io,
    path: []const u8,
    flat: []const Entry,
    sections: []const Section,
) !void {
    var total: usize = flat.len;
    for (sections) |section| {
        total += section.entries.len;
    }
    var html: ArrayList(u8) = .empty;
    try html.appendSlice(arena,
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>zimr cheatsheet</title>
        \\<!--docfmt:style-->
        \\</head><body>
        \\
    );
    try html.appendSlice(arena, try allocPrint(arena, "<header><h1>zimr cheatsheet</h1><div class=\"sub\">" ++
        "{d} declarations \u{00b7} <code>z</code> and {d} namespaces \u{00b7} generated from src/zimr.zig by " ++
        "tools/cheatsheet.zig</div></header>\n<nav>\n<a href=\"#z\">z</a>", .{ total, sections.len }));
    // One link per line, as the readme writes its nav: the whitespace between links is what lets them space out
    // and wrap - the shared stylesheet gives `nav` no layout of its own, and links written back to back read as one
    // unbreakable word.
    for (sections) |section| {
        const short: []const u8 = section.name["z.".len..];
        try html.appendSlice(arena, try allocPrint(arena, "\n<a href=\"#ns-{s}\">{s}</a>", .{ short, short }));
    }
    try html.append(arena, '\n');
    try html.appendSlice(arena, "</nav>\n<main>\n");
    try appendSection(arena, &html, "z", "z - what zimr.zig exports itself", flat);
    for (sections) |section| {
        const id: []const u8 = try allocPrint(arena, "ns-{s}", .{section.name["z.".len..]});
        try appendSection(arena, &html, id, section.name, section.entries);
    }
    try html.appendSlice(arena, "</main>\n</body></html>\n");
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = html.items });
}

pub fn main(init: std.process.Init) !void {
    const arena: Allocator = init.arena.allocator();
    const args: CheatArgs = cli.args(&init, CheatArgs, cheat_cli);
    var files: Files = .{ .arena = arena, .io = init.io, .dir = args.src };
    const root_path: []const u8 = try std.fs.path.join(arena, &.{ args.src, "zimr.zig" });
    const root: *Source = files.load(root_path) orelse return error.ZimrNotFound;

    // `z` itself: what zimr.zig declares public - except namespaces, each of which is a section of its own.
    var flat: ArrayList(Entry) = .empty;
    var sections: ArrayList(Section) = .empty;
    for (root.ast.rootDecls()) |node| {
        if (!isPublic(&root.ast, node)) {
            continue;
        }
        const name: []const u8 = declName(&root.ast, node) orelse continue;
        if (namespaceOf(&files, root, node, name)) |scope| {
            const title: []const u8 = try allocPrint(arena, "z.{s}", .{name});
            try sections.append(arena, .{ .name = title, .entries = try scopeEntries(&files, scope) });
            continue;
        }
        try flat.append(arena, try render(&files, .{ .source = root, .node = node }, name, 0));
    }
    sortSlice(Section, sections.items, {}, sectionBefore);
    try writePage(arena, init.io, args.output, flat.items, sections.items);
}
