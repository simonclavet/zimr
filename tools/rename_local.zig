//! rename_local - scoped rename of a function-local variable.
//!
//! Usage: rename_local <file> <line> <old_name> <new_name>
//!
//! Renames the local `<old_name>` declared on `<line>` to `<new_name>`,
//! touching ONLY references within the enclosing function/test body. Works on
//! the AST, so `.field` accesses, enum literals `.old`, and `old` in comments
//! or strings are NOT touched (none are identifier nodes). Every binding named
//! `old` in the function plus its identifier uses are renamed together - a
//! consistent alpha-rename that preserves semantics. Refuses if `new_name`
//! already appears in scope (would merge names) or the decl isn't found. The
//! compiler is the backstop: a missed reference becomes an "undeclared
//! identifier" error.
const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

fn lineOf(line_starts: []const u32, o: u32) u32 {
    var lo: usize = 0;
    var hi: usize = line_starts.len;
    while (lo < hi) {
        const mid: usize = lo + (hi - lo) / 2;
        if (line_starts[mid] <= o) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return @intCast(lo);
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const arena: Allocator = init.arena.allocator();
    const io: std.Io = init.io;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    if (argv.len != 5) {
        std.debug.print("usage: rename_local <file> <line> <old_name> <new_name>\n", .{});
        return error.BadArgs;
    }
    const path: []const u8 = argv[1];
    const target_line: u32 = try std.fmt.parseInt(u32, argv[2], 10);
    const old_name: []const u8 = argv[3];
    const new_name: []const u8 = argv[4];

    const raw: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(raw);
    const buf: [:0]u8 = try gpa.allocSentinel(u8, raw.len, 0);
    defer gpa.free(buf);
    @memcpy(buf, raw);

    var ast: Ast = try Ast.parse(gpa, buf, .{ .mode = .zig });
    defer ast.deinit(gpa);
    if (ast.errors.len != 0) {
        std.debug.print("{s}: parse errors, skipping\n", .{path});
        return error.ParseError;
    }

    const starts: []const u32 = ast.tokens.items(.start);

    var line_starts: ArrayList(u32) = .empty;
    defer line_starts.deinit(gpa);
    try line_starts.append(gpa, 0);
    for (buf, 0..) |ch, idx| {
        if (ch == '\n') {
            try line_starts.append(gpa, @intCast(idx + 1));
        }
    }

    // 1) Target var_decl: name token on `target_line`, slice == old_name.
    var target_name_tok: ?u32 = null;
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const vd: Ast.full.VarDecl = ast.fullVarDecl(node) orelse continue;
            const name_tok: u32 = vd.ast.mut_token + 1;
            if (!eql(u8, ast.tokenSlice(name_tok), old_name)) {
                continue;
            }
            if (lineOf(line_starts.items, starts[name_tok]) != target_line) {
                continue;
            }
            if (target_name_tok != null) {
                std.debug.print(
                    "{s}:{d}: ambiguous - two '{s}' decls on this line\n",
                    .{ path, target_line, old_name },
                );
                return error.Ambiguous;
            }
            target_name_tok = name_tok;
        }
    }
    const tnt: u32 = target_name_tok orelse {
        std.debug.print("{s}:{d}: no var_decl named '{s}' on that line\n", .{ path, target_line, old_name });
        return error.NotFound;
    };

    // 2) Innermost enclosing fn_decl/test_decl by token-index containment.
    var best_ft: u32 = 0;
    var best_lt: u32 = @intCast(ast.tokens.len - 1);
    var found_fn: bool = false;
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            const t: Ast.Node.Tag = ast.nodeTag(node);
            if (t != .fn_decl and t != .test_decl) {
                continue;
            }
            const ft: u32 = ast.firstToken(node);
            const lt: u32 = ast.lastToken(node);
            if (ft <= tnt and tnt <= lt and (!found_fn or ft > best_ft)) {
                best_ft = ft;
                best_lt = lt;
                found_fn = true;
            }
        }
    }

    // 3) Collect token indices to rename within [best_ft, best_lt].
    var toks: ArrayList(u32) = .empty;
    defer toks.deinit(gpa);
    var collision: bool = false;
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (ast.nodeTag(node) == .identifier) {
                const tok: u32 = ast.nodeMainToken(node);
                if (tok >= best_ft and tok <= best_lt) {
                    const s: []const u8 = ast.tokenSlice(tok);
                    if (eql(u8, s, old_name)) {
                        try toks.append(gpa, tok);
                    } else if (eql(u8, s, new_name)) {
                        collision = true;
                    }
                }
            }
            if (ast.fullVarDecl(node)) |vd| {
                const name_tok: u32 = vd.ast.mut_token + 1;
                if (name_tok >= best_ft and name_tok <= best_lt) {
                    const s: []const u8 = ast.tokenSlice(name_tok);
                    if (eql(u8, s, old_name)) {
                        try toks.append(gpa, name_tok);
                    } else if (eql(u8, s, new_name)) {
                        collision = true;
                    }
                }
            }
        }
    }
    if (collision) {
        std.debug.print(
            "{s}:{d}: '{s}' already in scope - skipping to avoid a name merge\n",
            .{ path, target_line, new_name },
        );
        return error.Collision;
    }
    std.mem.sort(u32, toks.items, {}, comptime std.sort.asc(u32));
    var uniq: ArrayList(u32) = .empty;
    defer uniq.deinit(gpa);
    for (toks.items) |tk| {
        if (uniq.items.len == 0 or uniq.items[uniq.items.len - 1] != tk) {
            try uniq.append(gpa, tk);
        }
    }
    if (uniq.items.len == 0) {
        std.debug.print("{s}:{d}: 0 occurrences of '{s}' in scope — skipping\n", .{ path, target_line, old_name });
        return error.NotFound;
    }

    // 4) Rewrite ascending: copy gaps, substitute new_name at each token.
    var out: ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var cursor: usize = 0;
    for (uniq.items) |tok| {
        const a: usize = starts[tok];
        const b: usize = a + old_name.len;
        if (!eql(u8, buf[a..b], old_name)) {
            std.debug.print("{s}: token {d} text mismatch — abort\n", .{ path, tok });
            return error.Mismatch;
        }
        try out.appendSlice(gpa, buf[cursor..a]);
        try out.appendSlice(gpa, new_name);
        cursor = b;
    }
    try out.appendSlice(gpa, buf[cursor..buf.len]);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });

    std.debug.print("{s}:{d}: {s} -> {s}  ({d} sites)\n", .{ path, target_line, old_name, new_name, uniq.items.len });
}
