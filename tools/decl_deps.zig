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
const cli = @import("cli");
const Ast = std.zig.Ast;
const Index = Ast.Node.Index;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const StringHashMap = std.StringHashMap;

fn declNameToken(ast: *const Ast, node: Index) ?u32 {
    if (ast.nodeTag(node) == .fn_decl) {
        var buf: [1]Index = undefined;
        const proto: Ast.full.FnProto = ast.fullFnProto(&buf, node) orelse return null;
        return proto.name_token;
    }
    const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse return null;
    return vd.ast.mut_token + 1;
}

/// The command line (std's cli, `src/command_line.zig`): `zig build decl-deps -- <file.zig>`.
const DepsArgs = struct {
    file: []const u8,
};

const deps_cli: cli.Config(DepsArgs) = .{
    .prog = "zig build decl-deps --",
    .description = "The file-scope dependency graph of a Zig file: one line per top-level declaration.",
};

pub fn main(init: std.process.Init) !void {
    // A one-shot tool: everything lives until exit, so everything comes from the process arena and goes with it.
    // (It took `init.gpa` and freed two of its eight allocations - 12 leak reports at every exit.)
    const arena: Allocator = init.arena.allocator();
    const io: Io = init.io;

    const args: DepsArgs = cli.args(&init, DepsArgs, deps_cli);
    const path: []const u8 = args.file;

    const bytes: []u8 = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    const source_z: [:0]u8 = try arena.allocSentinel(u8, bytes.len, 0);
    @memcpy(source_z, bytes);

    var ast: Ast = try std.zig.Ast.parse(arena, source_z, .{ .mode = .zig });
    defer ast.deinit(arena);
    if (ast.errors.len > 0) {
        std.debug.print("PARSE_ERROR ({d})\n", .{ast.errors.len});
        return;
    }

    const roots: []const Index = ast.rootDecls();
    const n: usize = roots.len;

    const names: [][]const u8 = try arena.alloc([]const u8, n);
    const ftok: []u32 = try arena.alloc(u32, n);
    const ltok: []u32 = try arena.alloc(u32, n);

    var name2idx: StringHashMap(usize) = .init(arena);
    defer name2idx.deinit();

    for (roots, 0..) |node, idx| {
        ftok[idx] = ast.firstToken(node);
        ltok[idx] = ast.lastToken(node);
        if (declNameToken(&ast, node)) |t| {
            const nm: []const u8 = ast.tokenSlice(t);
            names[idx] = nm;
            const gop: StringHashMap(usize).GetOrPutResult = try name2idx.getOrPut(nm);
            if (!gop.found_existing) {
                gop.value_ptr.* = idx;
            }
        } else {
            names[idx] = "";
        }
    }

    const edges: []std.AutoHashMap(usize, void) = try arena.alloc(std.AutoHashMap(usize, void), n);
    for (0..n) |k| {
        edges[k] = std.AutoHashMap(usize, void).init(arena);
    }

    // One pass over identifier nodes; attribute each to its enclosing root by
    // token span (roots are source-ordered, so ftok is strictly increasing).
    var i: usize = 0;
    while (i < ast.nodes.len) : (i += 1) {
        const node: Index = @fromBackingInt(@intCast(i));
        if (ast.nodeTag(node) != .identifier) {
            continue;
        }
        const use_tok: u32 = ast.nodeMainToken(node);
        const nm: []const u8 = ast.tokenSlice(use_tok);
        const used: usize = name2idx.get(nm) orelse continue;

        // rightmost root whose first token <= use_tok
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid: usize = (lo + hi) / 2;
            // Upper-bound binary search: narrow to the first token index PAST `use_tok`.
            if (ftok[mid] <= use_tok) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo == 0) {
            continue;
        }
        const enc: usize = lo - 1;
        // in inter-decl trivia (defensive)
        if (use_tok > ltok[enc]) {
            continue;
        }
        // self-reference (incl. the decl's own name tok)
        if (enc == used) {
            continue;
        }
        try edges[enc].put(used, {});
    }

    var out_buf: [1 << 16]u8 = undefined;
    var out_writer: Io.File.Writer = Io.File.stdout().writer(io, &out_buf);
    const out: *Io.Writer = &out_writer.interface;
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
