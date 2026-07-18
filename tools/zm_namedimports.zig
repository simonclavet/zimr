//! zm_namedimports — migrate `zm.X` bodies to named imports (reserved-math P4).
//!
//! Usage: zm_namedimports <file>...
//!
//! For each file with exactly ONE top-level (column-0) `const zm = @import("zm");`:
//!   1. collect the distinct body-level `zm.X` member accesses (skipping the
//!      ones that are already the init of a canonical `const X = zm.X;` binding),
//!   2. insert a sorted `const X = zm.X;` binding block right under the
//!      `const zm = @import("zm");` line (only for names not already bound),
//!   3. rewrite every body `zm.X` -> `X`.
//!
//! AST-based, so `zm.X` inside strings/comments is untouched (not an identifier
//! field-access node). Idempotent: a second run finds no body `zm.X` left to
//! rewrite (the binding inits are excluded) and adds nothing. Files with zero or
//! more than one top-level `zm` alias are skipped untouched — this is how the
//! namespace-local `zm`s in runtime.zig (each indented inside a `struct`) opt
//! out automatically. Same `std.Io` conventions as rename_local.
const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const Edit = struct {
    start: usize,
    end: usize,
    text: []const u8,
};

/// True iff `node` is a `field_access` whose object is the identifier `zm`.
fn isZmDotField(ast: *const Ast, node: Ast.Node.Index) bool {
    if (ast.nodeTag(node) != .field_access) {
        return false;
    }
    const obj_node: Ast.Node.Index = ast.nodeData(node).node_and_token[0];
    if (ast.nodeTag(obj_node) != .identifier) {
        return false;
    }
    return eql(u8, ast.tokenSlice(ast.nodeMainToken(obj_node)), "zm");
}

fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (eql(u8, x, s)) {
            return true;
        }
    }
    return false;
}

fn ltStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn ltEdit(_: void, a: Edit, b: Edit) bool {
    if (a.start != b.start) {
        return a.start < b.start;
    }
    return a.end < b.end;
}

/// Returns true if the file was rewritten.
fn processFile(gpa: Allocator, io: std.Io, path: []const u8) !bool {
    const raw: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(raw);
    const buf: [:0]u8 = try gpa.allocSentinel(u8, raw.len, 0);
    defer gpa.free(buf);
    @memcpy(buf, raw);

    var ast: Ast = try Ast.parse(gpa, buf, .{ .mode = .zig });
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) {
        std.debug.print("{s}: parse errors, skipping\n", .{path});
        return false;
    }

    const starts: []const u32 = ast.tokens.items(.start);

    // 1) Find top-level (column-0) `const zm = ...` decls. Require exactly one.
    var zm_insert_at: ?usize = null;
    var zm_count: usize = 0;
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @enumFromInt(i);
            const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse continue;
            const name_tok: u32 = vd.ast.mut_token + 1;
            if (!eql(u8, ast.tokenSlice(name_tok), "zm")) {
                continue;
            }
            const ft: u32 = ast.firstToken(node);
            const ft_off: usize = starts[ft];
            // Column 0 ⇒ the char before the first token is a newline (or BOF).
            if (ft_off != 0 and buf[ft_off - 1] != '\n') {
                continue;
            }
            zm_count += 1;
            // Insert point: start of the line AFTER the decl's terminating `;`.
            const last_off: usize = starts[ast.lastToken(node)];
            var nl: usize = last_off;
            while (nl < buf.len and buf[nl] != '\n') : (nl += 1) {}
            zm_insert_at = if (nl < buf.len) nl + 1 else buf.len;
        }
    }
    if (zm_count != 1) {
        std.debug.print("{s}: {d} top-level zm aliases — skipping\n", .{ path, zm_count });
        return false;
    }
    const insert_at: usize = zm_insert_at.?;

    // 2) Mark the init nodes of canonical `const X = zm.X;` bindings (so we don't
    //    rewrite them) and remember which names are already bound.
    var is_binding_init: []bool = try gpa.alloc(bool, ast.nodes.len);
    defer gpa.free(is_binding_init);
    @memset(is_binding_init, false);
    var already_bound: ArrayList([]const u8) = .empty;
    defer already_bound.deinit(gpa);
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @enumFromInt(i);
            const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse continue;
            const init_n: Ast.Node.Index = vd.ast.init_node.unwrap() orelse continue;
            if (!isZmDotField(&ast, init_n)) continue;
            const name: []const u8 = ast.tokenSlice(vd.ast.mut_token + 1);
            const field: []const u8 = ast.tokenSlice(ast.nodeData(init_n).node_and_token[1]);
            if (!eql(u8, name, field)) continue; // not canonical (name == member)
            is_binding_init[@intFromEnum(init_n)] = true;
            try already_bound.append(gpa, name);
        }
    }

    // 2b) Collect every *declared* name (top-level + local var/const, fn names,
    //     params).  Inserting a top-level `const X = zm.X` for any of these would
    //     duplicate a file-scope member or shadow a local/param (both Zig errors),
    //     so such names stay qualified.  Canonical `const X = zm.X` bindings are
    //     exempt — they are the legal home for the name.
    var declared: ArrayList([]const u8) = .empty;
    defer declared.deinit(gpa);
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @enumFromInt(i);
            if (ast.fullVarDecl(node)) |vd| {
                try declared.append(gpa, ast.tokenSlice(vd.ast.mut_token + 1));
            }
            var proto_buf: [1]Ast.Node.Index = undefined;
            const fp: Ast.full.FnProto = ast.fullFnProto(&proto_buf, node) orelse continue;
            if (fp.name_token) |nt| {
                try declared.append(gpa, ast.tokenSlice(nt));
            }
            var it = fp.iterate(&ast);
            while (it.next()) |param| {
                const pnt: u32 = param.name_token orelse continue;
                try declared.append(gpa, ast.tokenSlice(pnt));
            }
        }
    }

    // 3) Collect body `zm.X` field-accesses to rewrite (skip binding inits).
    //    Build deletion edits for the `zm.` prefix and gather distinct names.
    var edits: ArrayList(Edit) = .empty;
    defer edits.deinit(gpa);
    var used: ArrayList([]const u8) = .empty;
    defer used.deinit(gpa);
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @enumFromInt(i);
            if (is_binding_init[i]) continue;
            if (!isZmDotField(&ast, node)) continue;
            const obj_node, const field_tok = ast.nodeData(node).node_and_token;
            const zm_tok: u32 = ast.nodeMainToken(obj_node);
            const del_start: usize = starts[zm_tok];
            const del_end: usize = starts[field_tok];
            // Sanity: the bytes we delete must begin with `zm`.
            if (del_start + 2 > buf.len or !eql(u8, buf[del_start .. del_start + 2], "zm")) {
                continue;
            }
            const field_name: []const u8 = ast.tokenSlice(field_tok);
            // Leave qualified if the name collides with a declared name (fn/const/
            // param/local) that isn't a canonical `const X = zm.X` binding.
            if (containsStr(declared.items, field_name) and !containsStr(already_bound.items, field_name)) {
                continue;
            }
            try edits.append(gpa, .{ .start = del_start, .end = del_end, .text = "" });
            try used.append(gpa, field_name);
        }
    }

    if (edits.items.len == 0) {
        return false; // nothing to migrate (already done, or no body zm.X)
    }

    // 4) New bindings to add = distinct(used) − already_bound, sorted.
    std.mem.sort([]const u8, used.items, {}, ltStr);
    var to_add: ArrayList([]const u8) = .empty;
    defer to_add.deinit(gpa);
    for (used.items, 0..) |name, idx| {
        if (idx > 0 and eql(u8, name, used.items[idx - 1])) {
            continue; // dedupe
        }
        if (containsStr(already_bound.items, name)) {
            continue;
        }
        try to_add.append(gpa, name);
    }

    // 5) Build the binding block and queue it as an insertion edit.
    var block: ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    for (to_add.items) |name| {
        try block.appendSlice(gpa, "const ");
        try block.appendSlice(gpa, name);
        try block.appendSlice(gpa, " = zm.");
        try block.appendSlice(gpa, name);
        try block.appendSlice(gpa, ";\n");
    }
    if (block.items.len != 0) {
        try edits.append(gpa, .{ .start = insert_at, .end = insert_at, .text = try gpa.dupe(u8, block.items) });
    }

    // 6) Apply edits in ascending order.
    std.mem.sort(Edit, edits.items, {}, ltEdit);
    var out: ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var cursor: usize = 0;
    for (edits.items) |e| {
        if (e.start < cursor) {
            std.debug.print("{s}: overlapping edits — abort\n", .{path});
            return error.Overlap;
        }
        try out.appendSlice(gpa, buf[cursor..e.start]);
        try out.appendSlice(gpa, e.text);
        cursor = e.end;
    }
    try out.appendSlice(gpa, buf[cursor..buf.len]);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
    const rewrite_count: usize = edits.items.len - @as(usize, if (block.items.len != 0) 1 else 0);
    std.debug.print("{s}: +{d} bindings, {d} rewrites\n", .{ path, to_add.items.len, rewrite_count });
    return true;
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const arena: Allocator = init.arena.allocator();
    const io: std.Io = init.io;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) {
        std.debug.print("usage: zm_namedimports <file>...\n", .{});
        return error.BadArgs;
    }
    var changed: usize = 0;
    var skipped: usize = 0;
    for (argv[1..]) |path| {
        const did: bool = processFile(gpa, io, path) catch |e| {
            std.debug.print("{s}: error {s}\n", .{ path, @errorName(e) });
            continue;
        };
        if (did) {
            changed += 1;
        } else {
            skipped += 1;
        }
    }
    std.debug.print("done: {d} changed, {d} unchanged/skipped\n", .{ changed, skipped });
}
