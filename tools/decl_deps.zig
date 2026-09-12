//! decl_deps - emit the file-scope dependency graph of a Zig file.
//!
//! For each top-level (`rootDecls`) declaration, prints one line:
//!   <idx>|<first_line>|<last_line>|<name>|<ref_idx>,<ref_idx>,...
//! where `ref_idx` are the indices of OTHER top-level decls referenced anywhere
//! inside this decl's token span. Lines are 1-indexed. `name` is empty for
//! anonymous roots (`test` / `comptime`).
//!
//! Same identity insight as the decl-order lint rule: Zig forbids shadowing a
//! container-scope decl, so a bare `.identifier` whose name matches a root decl
//! IS a reference to it - no scope analysis needed. Consumed by decl_reorder.py.
const std = @import("std");
const Ast = std.zig.Ast;
const Index = Ast.Node.Index;
const Allocator = std.mem.Allocator;

fn declNameToken(ast: *const Ast, node: Index) ?u32 {
    if (ast.nodeTag(node) == .fn_decl) {
        var buf: [1]Index = undefined;
        const proto: Ast.full.FnProto = ast.fullFnProto(&buf, node) orelse return null;
        return proto.name_token;
    }
    const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse return null;
    return vd.ast.mut_token + 1;
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const arena: Allocator = init.arena.allocator();
    const io: std.Io = init.io;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    if (argv.len < 2) {
        std.debug.print("usage: decl_deps <file.zig>\n", .{});
        return;
    }
    const path: []const u8 = argv[1];

    const bytes: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    const source_z: [:0]u8 = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(source_z, bytes);

    var ast: Ast = try std.zig.Ast.parse(gpa, source_z, .{ .mode = .zig });
    defer ast.deinit(gpa);
    if (ast.errors.len > 0) {
        std.debug.print("PARSE_ERROR ({d})\n", .{ast.errors.len});
        return;
    }

    const roots: []const Index = ast.rootDecls();
    const n: usize = roots.len;

    const names: [][]const u8 = try gpa.alloc([]const u8, n);
    const ftok: []u32 = try gpa.alloc(u32, n);
    const ltok: []u32 = try gpa.alloc(u32, n);

    var name2idx: std.StringHashMap(usize) = std.StringHashMap(usize).init(gpa);
    defer name2idx.deinit();

    for (roots, 0..) |node, idx| {
        ftok[idx] = ast.firstToken(node);
        ltok[idx] = ast.lastToken(node);
        if (declNameToken(&ast, node)) |t| {
            const nm: []const u8 = ast.tokenSlice(t);
            names[idx] = nm;
            const gop: std.StringHashMap(usize).GetOrPutResult = try name2idx.getOrPut(nm);
            if (!gop.found_existing) {
                gop.value_ptr.* = idx;
            }
        } else {
            names[idx] = "";
        }
    }

    const edges: []std.AutoHashMap(usize, void) = try gpa.alloc(std.AutoHashMap(usize, void), n);
    for (0..n) |k| {
        edges[k] = std.AutoHashMap(usize, void).init(gpa);
    }

    // One pass over identifier nodes; attribute each to its enclosing root by
    // token span (roots are source-ordered, so ftok is strictly increasing).
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const node: Index = @fromBackingInt(@intCast(i));
        if (ast.nodeTag(node) != .identifier) continue;
        const use_tok: u32 = ast.nodeMainToken(node);
        const nm: []const u8 = ast.tokenSlice(use_tok);
        const used: usize = name2idx.get(nm) orelse continue;

        // rightmost root whose first token <= use_tok
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid: usize = (lo + hi) / 2;
            if (ftok[mid] <= use_tok) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) continue;
        const enc: usize = lo - 1;
        if (use_tok > ltok[enc]) continue; // in inter-decl trivia (defensive)
        if (enc == used) continue; // self-reference (incl. the decl's own name tok)
        try edges[enc].put(used, {});
    }

    var out_buf: [1 << 16]u8 = undefined;
    var out_writer: std.Io.File.Writer = std.Io.File.stdout().writer(io, &out_buf);
    const out: *std.Io.Writer = &out_writer.interface;
    for (0..n) |idx| {
        const fl: usize = ast.tokenLocation(0, ftok[idx]).line + 1;
        const ll: usize = ast.tokenLocation(0, ltok[idx]).line + 1;
        try out.print("{d}|{d}|{d}|{s}|", .{ idx, fl, ll, names[idx] });
        var it: std.AutoHashMap(usize, void).KeyIterator = edges[idx].keyIterator();
        var first: bool = true;
        while (it.next()) |k| {
            if (!first) {
                try out.print(",", .{});
            }
            try out.print("{d}", .{k.*});
            first = false;
        }
        try out.print("\n", .{});
    }
    try out.flush();
}
