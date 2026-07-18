//! cheatsheet — pure-Zig generator for zimr's public API cheatsheet.
//!
//! Walks every `src/*.zig`, extracts each `pub fn` (with its enclosing
//! `pub const X = struct {` namespace path and leading `///` doc), and emits a
//! single self-contained `cheatsheet.html` grouped by module. Replaces the old
//! `scripts/build_cheatsheet.py`, whose hardcoded module list went stale after
//! the module-collapse (it still named `rlgl.zig`/`gpu.zig`/`scene.zig` and
//! missed `zimrphysics.zig`/`plot3d.zig`) and cross-referenced raylib/imgui —
//! a mapping zimr has long since drifted away from. Auto-discovery means new
//! modules appear with zero edits here.
//!
//! Usage: cheatsheet [src_dir] [out_html]   (defaults: src  cheatsheet.html)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;

const Fn = struct {
    ns: []const u8, // namespace path, e.g. "Vec3" ("" for file scope)
    name: []const u8,
    sig: []const u8, // full signature, whitespace-collapsed, no body brace
    doc: []const u8, // joined /// lines (may be empty)
};

const Module = struct {
    name: []const u8, // file basename without .zig
    fns: ArrayList(Fn) = .empty,
};

// A struct namespace currently open on the brace stack.
const NsFrame = struct {
    name: []const u8,
    depth: usize, // brace depth at which this struct's body opened
    is_pub: bool, // the declaring `const` was `pub` (reachable from outside)
};

fn isFlag(a: []const u8) bool {
    return std.mem.startsWith(u8, a, "--");
}

/// Positional arg `idx` (1-based among argv) if present and not a `--flag`, else `dflt`.
fn posArg(args: []const []u8, idx: usize, dflt: []const u8) []const u8 {
    if (args.len > idx and !isFlag(args[idx])) {
        return args[idx];
    }
    return dflt;
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isPubFn(trimmed: []const u8) bool {
    if (!std.mem.startsWith(u8, trimmed, "pub ")) {
        return false;
    }
    var rest: []const u8 = trimmed[4..];
    inline for (.{ "inline ", "export ", "noinline " }) |kw| {
        if (std.mem.startsWith(u8, rest, kw)) {
            rest = rest[kw.len..];
        }
    }
    return std.mem.startsWith(u8, rest, "fn ");
}

fn allFramesPub(frames: []const NsFrame) bool {
    for (frames) |fr| {
        if (!fr.is_pub) {
            return false;
        }
    }
    return true;
}

fn nsPath(gpa: Allocator, frames: []const NsFrame) ![]const u8 {
    if (frames.len == 0) {
        return "";
    }
    var out: ArrayList(u8) = .empty;
    for (frames, 0..) |f, idx| {
        if (idx != 0) {
            try out.append(gpa, '.');
        }
        try out.appendSlice(gpa, f.name);
    }
    return out.items;
}

/// Capture the full signature from a `pub fn` start: collapse interior
/// whitespace, stop at the body-opening `{` (paren-depth 0).
fn captureSig(
    gpa: Allocator,
    text: []const u8,
    next_line_start: usize,
    first_line: []const u8,
) ![]const u8 {
    const start: usize = next_line_start - (first_line.len + 1);
    var out: ArrayList(u8) = .empty;
    var paren: i32 = 0;
    var seen_open: bool = false;
    var prev_space: bool = false;
    var i: usize = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '(') {
            paren += 1;
            seen_open = true;
        } else if (c == ')') {
            paren -= 1;
        } else if (c == '{' and seen_open and paren == 0) {
            break;
        } else if (c == ';' and seen_open and paren == 0) {
            break;
        }
        if (c == '\n' or c == '\r' or c == ' ' or c == '\t') {
            if (!prev_space and out.items.len > 0) {
                try out.append(gpa, ' ');
                prev_space = true;
            }
            continue;
        }
        prev_space = false;
        try out.append(gpa, c);
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

fn fnName(sig: []const u8) []const u8 {
    const fn_kw: usize = std.mem.indexOf(u8, sig, "fn ") orelse return sig;
    const after: []const u8 = sig[fn_kw + 3 ..];
    const paren: usize = std.mem.indexOfScalar(u8, after, '(') orelse return after;
    return std.mem.trim(u8, after[0..paren], " ");
}

fn containerOpen(line: []const u8) bool {
    inline for (.{
        "= struct {",        "= struct{", "= packed struct {",
        "= extern struct {", "= union(",  "= union {",
        "= enum(",           "= enum {",  "= opaque {",
    }) |pat| {
        if (std.mem.indexOf(u8, line, pat) != null) {
            return true;
        }
    }
    return false;
}

fn declName(trimmed: []const u8) ?[]const u8 {
    var s: []const u8 = trimmed;
    if (std.mem.startsWith(u8, s, "pub ")) {
        s = s[4..];
    }
    inline for (.{ "const ", "var " }) |kw| {
        if (std.mem.startsWith(u8, s, kw)) {
            const rest: []const u8 = s[kw.len..];
            var end: usize = 0;
            while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) {
                end += 1;
            }
            if (end == 0) {
                return null;
            }
            return rest[0..end];
        }
    }
    return null;
}

/// Parse one module's source: track struct-namespace nesting by brace depth and
/// emit a `Fn` for every `pub fn`, carrying any immediately-preceding `///` doc.
fn parseModule(gpa: Allocator, text: []const u8, mod: *Module) !void {
    var stack: ArrayList(NsFrame) = .empty;
    defer stack.deinit(gpa);

    var depth: usize = 0;
    var doc: ArrayList(u8) = .empty;
    defer doc.deinit(gpa);

    var lines: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line: []const u8 = std.mem.trimEnd(u8, raw, "\r");
        const trimmed: []const u8 = std.mem.trimStart(u8, line, " \t");

        // Accumulate doc comments (/// ...).
        if (std.mem.startsWith(u8, trimmed, "///")) {
            const d: []const u8 = std.mem.trimStart(u8, trimmed[3..], " ");
            if (doc.items.len > 0) {
                try doc.append(gpa, ' ');
            }
            try doc.appendSlice(gpa, d);
            continue;
        }

        if (isPubFn(trimmed) and allFramesPub(stack.items)) {
            const ns: []const u8 = try nsPath(gpa, stack.items);
            const sig: []const u8 = try captureSig(gpa, text, lines.index orelse text.len, line);
            try mod.fns.append(gpa, .{
                .ns = ns,
                .name = try gpa.dupe(u8, fnName(sig)),
                .sig = sig,
                .doc = try gpa.dupe(u8, doc.items),
            });
        }

        // Namespace push: a named decl whose value is a container type.
        if (containerOpen(line)) {
            if (declName(trimmed)) |nm| {
                const is_pub: bool = std.mem.startsWith(u8, trimmed, "pub ");
                try stack.append(gpa, .{ .name = try gpa.dupe(u8, nm), .depth = depth, .is_pub = is_pub });
            }
        }

        // Brace accounting + pop closed namespaces.
        for (line) |c| {
            if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                if (depth > 0) {
                    depth -= 1;
                }
                while (stack.items.len > 0 and stack.items[stack.items.len - 1].depth >= depth) {
                    _ = stack.pop();
                }
            }
        }

        if (trimmed.len != 0) {
            doc.clearRetainingCapacity();
        }
    }
}

/// Parse zimr.zig's top-level `pub const NAME = RHS;` re-exports into the flat
/// (lower-case = fn) and type (upper-case) name sets. Whole-module namespace
/// re-exports (`pub const ns = @import("x.zig");`) are escape hatches, skipped.
fn parseCurated(
    gpa: Allocator,
    src: []const u8,
    flat: *std.StringHashMapUnmanaged(void),
    types: *std.StringHashMapUnmanaged(void),
) !void {
    var lines: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "pub const ")) {
            continue;
        }
        const rest: []const u8 = line["pub const ".len..];
        const eq: usize = std.mem.indexOf(u8, rest, " = ") orelse continue;
        const name: []const u8 = std.mem.trim(u8, rest[0..eq], " ");
        if (name.len == 0) {
            continue;
        }
        var rhs: []const u8 = std.mem.trimStart(u8, rest[eq + 3 ..], " ");
        if (std.mem.indexOfScalar(u8, rhs, ';')) |sc| {
            rhs = rhs[0..sc];
        }
        if (std.mem.startsWith(u8, rhs, "@import(\"") and std.mem.endsWith(u8, rhs, ".zig\")")) {
            continue; // whole-module namespace escape hatch
        }
        const set: *std.StringHashMapUnmanaged(void) = if (name[0] >= 'a' and name[0] <= 'z') flat else types;
        try set.put(gpa, try gpa.dupe(u8, name), {});
    }
}

/// First dot-separated segment of a namespace path ("Vec3.Inner" -> "Vec3").
fn firstSeg(ns: []const u8) []const u8 {
    const dot: usize = std.mem.indexOfScalar(u8, ns, '.') orelse return ns;
    return ns[0..dot];
}

fn writeEscaped(w: *Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '&' => try w.writeAll("&amp;"),
            else => try w.writeByte(c),
        }
    }
}

fn emitSig(w: *Writer, f: Fn) !void {
    var sig: []const u8 = f.sig;
    if (std.mem.startsWith(u8, sig, "pub ")) {
        sig = sig[4..];
    }
    const fn_kw: usize = std.mem.indexOf(u8, sig, "fn ") orelse {
        try writeEscaped(w, sig);
        return;
    };
    try w.writeAll("<span class=\"k\">");
    try writeEscaped(w, sig[0 .. fn_kw + 2]);
    try w.writeAll("</span> ");
    const after: []const u8 = sig[fn_kw + 3 ..];
    const paren: usize = std.mem.indexOfScalar(u8, after, '(') orelse {
        try writeEscaped(w, after);
        return;
    };
    if (f.ns.len > 0) {
        try w.writeAll("<span class=\"ns\">");
        try writeEscaped(w, f.ns);
        try w.writeAll(".</span>");
    }
    try w.writeAll("<span class=\"nm\">");
    try writeEscaped(w, std.mem.trim(u8, after[0..paren], " "));
    try w.writeAll("</span>");
    try writeEscaped(w, after[paren..]);
}

fn emitHtml(w: *Writer, modules: []const Module, total_fns: usize) !void {
    try w.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en"><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>zimr cheatsheet</title>
        \\<style>
        \\:root{--bg:#0b0b0c;--fg:#e8e6e3;--mut:#8a8784;--acc:#7dd3fc;--card:#141416;--bd:#26262a}
        \\*{box-sizing:border-box}
        \\body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 ui-monospace,Menlo,Consolas,monospace}
        \\header{padding:24px 20px;border-bottom:1px solid var(--bd)}
        \\h1{margin:0;font-size:20px;letter-spacing:.04em}
        \\.sub{color:var(--mut);margin-top:6px}
        \\nav{display:flex;flex-wrap:wrap;gap:6px;padding:14px 20px;border-bottom:1px solid var(--bd)}
        \\nav a{color:var(--acc);text-decoration:none;padding:2px 8px}
        \\nav a{border:1px solid var(--bd);border-radius:5px;font-size:12px}
        \\main{padding:8px 20px 60px;max-width:1100px}
        \\section{margin-top:28px}
        \\h2{font-size:15px;color:var(--acc);border-bottom:1px solid var(--bd);padding-bottom:6px}
        \\.fn{padding:8px 10px;margin:6px 0;background:var(--card);border:1px solid var(--bd);border-radius:6px}
        \\.sig{white-space:pre-wrap;word-break:break-word}
        \\.ns{color:var(--mut)}.nm{color:#fff;font-weight:600}.k{color:#c792ea}
        \\.doc{color:var(--mut);margin-top:4px;font-size:12.5px}
        \\</style></head><body>
        \\
    );
    try w.print(
        "<header><h1>zimr cheatsheet</h1>" ++
            "<div class=\"sub\">{d} public functions \u{00b7} {d} modules \u{00b7} " ++
            "generated by tools/cheatsheet.zig</div></header>\n",
        .{ total_fns, modules.len },
    );
    try w.writeAll("<nav>");
    for (modules) |m| {
        try w.print("<a href=\"#{s}\">{s}</a>", .{ m.name, m.name });
    }
    try w.writeAll("</nav>\n<main>\n");
    for (modules) |m| {
        try w.print("<section id=\"{s}\"><h2>{s}.zig \u{2014} {d} fns</h2>\n", .{ m.name, m.name, m.fns.items.len });
        for (m.fns.items) |f| {
            try w.writeAll("<div class=\"fn\"><div class=\"sig\">");
            try emitSig(w, f);
            try w.writeAll("</div>");
            if (f.doc.len > 0) {
                try w.writeAll("<div class=\"doc\">");
                try writeEscaped(w, f.doc);
                try w.writeAll("</div>");
            }
            try w.writeAll("</div>\n");
        }
        try w.writeAll("</section>\n");
    }
    try w.writeAll("</main></body></html>\n");
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: std.Io = init.io;

    var args_list: ArrayList([]u8) = .empty;
    var arg_it: std.process.Args.Iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const src_dir: []const u8 = posArg(args_list.items, 1, "src");
    const out_path: []const u8 = posArg(args_list.items, 2, "cheatsheet.html");
    var show_all: bool = false;
    for (args_list.items) |a| {
        if (std.mem.eql(u8, a, "--all")) {
            show_all = true;
        }
    }

    const cwd: std.Io.Dir = std.Io.Dir.cwd();

    // Collect + sort top-level *.zig names for stable output.
    var names: ArrayList([]const u8) = .empty;
    {
        var dir: std.Io.Dir = try cwd.openDir(io, src_dir, .{ .iterate = true });
        defer dir.close(io);
        var it: std.Io.Dir.Iterator = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            if (!std.mem.endsWith(u8, entry.name, ".zig")) {
                continue;
            }
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);

    var modules: ArrayList(Module) = .empty;
    var total_fns: usize = 0;
    for (names.items) |fname| {
        const path: []const u8 = try std.fs.path.join(gpa, &.{ src_dir, fname });
        const text: []const u8 = cwd.readFileAlloc(io, path, gpa, .unlimited) catch continue;
        var mod: Module = .{ .name = fname[0 .. fname.len - ".zig".len] };
        try parseModule(gpa, text, &mod);
        if (mod.fns.items.len > 0) {
            total_fns += mod.fns.items.len;
            try modules.append(gpa, mod);
        }
    }

    // The cheatsheet publishes only the user-facing API: a fn is kept if its
    // name is a flat re-export in zimr.zig (`pub const drawCircle = ...`) or its
    // outermost enclosing type is a re-exported type (`pub const Rectangle =
    // ...`). `--all` shows every pub fn instead (debugging / coverage).
    if (!show_all) {
        const zimr_path: []const u8 = try std.fs.path.join(gpa, &.{ src_dir, "zimr.zig" });
        const zimr_src: []const u8 = cwd.readFileAlloc(io, zimr_path, gpa, .unlimited) catch "";
        var flat: std.StringHashMapUnmanaged(void) = .empty;
        var types: std.StringHashMapUnmanaged(void) = .empty;
        try parseCurated(gpa, zimr_src, &flat, &types);
        total_fns = 0;
        for (modules.items) |*mod| {
            var kept: ArrayList(Fn) = .empty;
            for (mod.fns.items) |f| {
                const outer: []const u8 = if (f.ns.len > 0) firstSeg(f.ns) else "";
                if (flat.contains(f.name) or (outer.len > 0 and types.contains(outer))) {
                    try kept.append(gpa, f);
                }
            }
            mod.fns = kept;
            total_fns += kept.items.len;
        }
    }

    var modules_out: ArrayList(Module) = .empty;
    for (modules.items) |mod| {
        if (mod.fns.items.len > 0) {
            try modules_out.append(gpa, mod);
        }
    }

    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try emitHtml(w, modules_out.items, total_fns);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = aw.written() });

    var err_buf: [256]u8 = undefined;
    var ew: std.Io.File.Writer = std.Io.File.stderr().writer(io, &err_buf);
    try ew.interface.print(
        "cheatsheet: {d} {s} fns across {d} modules -> {s}\n",
        .{ total_fns, if (show_all) "pub" else "user-facing", modules_out.items.len, out_path },
    );
    try ew.interface.flush();
}
