//! rename_pub_fn - rename a top-level function within its defining file.
//!
//! Usage: rename_pub_fn <file> <old_name> <new_name>
//!
//! Renames the `fn <old_name>` definition AND every bare identifier reference to
//! it within <file>, on the AST. Field accesses `x.old`, enum literals `.old`,
//! struct-init field names `.old =`, and `old` inside comments/strings are NOT
//! touched (none are identifier nodes), so English prose and longer names like
//! `log2` / `mulMat` are safe. Refuses if `<new_name>` already names a function
//! in the file (would create a duplicate definition). Cross-file qualified call
//! sites (`zm.old`) are updated separately. The compiler is the backstop: a
//! missed reference becomes an "undeclared identifier" error.
const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const arena: Allocator = init.arena.allocator();
    const io: std.Io = init.io;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(arena);
    if (argv.len != 4) {
        std.debug.print("usage: rename_pub_fn <file> <old_name> <new_name>\n", .{});
        return error.BadArgs;
    }
    const path: []const u8 = argv[1];
    const old_name: []const u8 = argv[2];
    const new_name: []const u8 = argv[3];

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

    var toks: ArrayList(u32) = .empty;
    defer toks.deinit(gpa);
    var collision: bool = false;
    var found_def: bool = false;
    {
        var i: usize = 0;
        while (i < ast.nodes.len) : (i += 1) {
            const node: Ast.Node.Index = @fromBackingInt(@intCast(i));
            if (ast.nodeTag(node) == .identifier) {
                const tok: u32 = ast.nodeMainToken(node);
                if (eql(u8, ast.tokenSlice(tok), old_name)) {
                    try toks.append(gpa, tok);
                }
            }
            var pbuf: [1]Ast.Node.Index = undefined;
            if (ast.fullFnProto(&pbuf, node)) |proto| {
                if (proto.name_token) |nt| {
                    const s: []const u8 = ast.tokenSlice(nt);
                    if (eql(u8, s, old_name)) {
                        try toks.append(gpa, nt);
                        found_def = true;
                    } else if (eql(u8, s, new_name)) {
                        collision = true;
                    }
                }
            }
        }
    }
    if (collision) {
        std.debug.print("{s}: '{s}' already names a function — refusing\n", .{ path, new_name });
        return error.Collision;
    }
    if (toks.items.len == 0) {
        std.debug.print("{s}: no occurrences of '{s}'\n", .{ path, old_name });
        return error.NotFound;
    }

    std.mem.sort(u32, toks.items, {}, comptime std.sort.asc(u32));
    var uniq: ArrayList(u32) = .empty;
    defer uniq.deinit(gpa);
    for (toks.items) |tk| {
        if (uniq.items.len == 0 or uniq.items[uniq.items.len - 1] != tk) {
            try uniq.append(gpa, tk);
        }
    }

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
    std.debug.print(
        "{s}: {s} -> {s}  (def={}, {d} sites)\n",
        .{ path, old_name, new_name, found_def, uniq.items.len },
    );
}
