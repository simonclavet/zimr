//! gen_files_md.zig - generate src/notes/files.md, the per-file atlas.
//!
//! Zig port of scripts/gen_files_md.py.  Walks the tree, computes per-file
//! line/fn/test counts + deps + dependents (naive scans, matching the old
//! regexes), pulls descriptions from each file's leading `//!` header or the
//! curated table in file_descriptions.zig, and emits the markdown atlas.
//!
//! Usage: `gen_files_md`  (run from repo root; writes src/notes/files.md).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const Writer = std.Io.Writer;
const allocPrint = std.fmt.allocPrint;
const bufPrint = std.fmt.bufPrint;
const fd = @import("file_descriptions.zig");
const ig = @import("import_graph.zig");

const exclude_dirs = [_][]const u8{
    ".zig-cache",   "zig-out", "prebuilt", ".git",
    "node_modules", "archive", ".vscode",  ".zed",
    "__pycache__",
};
const exclude_dir_prefixes = [_][]const u8{ "zig-x86_64", "bun-linux" };
const binary_exts = [_][]const u8{
    ".png", ".jpg", ".glb", ".ttf", ".wasm",
    ".ico", ".zip", ".tsv", ".spv", ".bin",
};

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// An out-degree hub: a src module and how many in-tree modules it imports.
const Hub = struct { name: []const u8, deg: usize };

fn hubMore(_: void, a: Hub, b: Hub) bool {
    return a.deg > b.deg;
}

/// Sort context: maps `src/<name>.zig` path -> DAG level (9999 = not in the
/// src graph, sorts last).
const LvlCtx = struct { map: *StringHashMap(u32) };

fn lvlLess(ctx: LvlCtx, a: []const u8, b: []const u8) bool {
    const la: u32 = ctx.map.get(a) orelse 9999;
    const lb: u32 = ctx.map.get(b) orelse 9999;
    if (la != lb) {
        return la < lb;
    }
    return std.mem.lessThan(u8, a, b);
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

/// Thousands-separated decimal, e.g. 255263 -> "255,263".
fn commaInt(gpa: Allocator, n: usize) ![]u8 {
    var tmp: [32]u8 = undefined;
    const s: []const u8 = try bufPrint(&tmp, "{d}", .{n});
    const ncommas: usize = (s.len - 1) / 3;
    const out: []u8 = try gpa.alloc(u8, s.len + ncommas);
    var oi: usize = 0;
    for (s, 0..) |c, i| {
        if (i > 0 and (s.len - i) % 3 == 0) {
            out[oi] = ',';
            oi += 1;
        }
        out[oi] = c;
        oi += 1;
    }
    return out;
}

fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        return path[0..i];
    }
    return "";
}

fn baseOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| {
        return path[i + 1 ..];
    }
    return path;
}

/// os.path.splitext-style extension (includes the dot), ignoring leading dots.
fn extOf(name: []const u8) []const u8 {
    var i: usize = 0;
    while (i < name.len and name[i] == '.') {
        i += 1;
    }
    const rest: []const u8 = name[i..];
    if (std.mem.lastIndexOfScalar(u8, rest, '.')) |d| {
        return rest[d..];
    }
    return "";
}

/// stem = basename without its extension.
fn stemOf(name: []const u8) []const u8 {
    const ext: []const u8 = extOf(name);
    return name[0 .. name.len - ext.len];
}

/// Normalize a "/"-path: collapse "." and "a/.." segments (os.path.normpath).
fn normpath(gpa: Allocator, path: []const u8) ![]const u8 {
    var stack: ArrayList([]const u8) = .empty;
    var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) {
            continue;
        }
        if (std.mem.eql(u8, comp, "..")) {
            if (stack.items.len > 0 and !std.mem.eql(u8, stack.items[stack.items.len - 1], "..")) {
                _ = stack.pop();
            } else {
                try stack.append(gpa, comp);
            }
            continue;
        }
        try stack.append(gpa, comp);
    }
    if (stack.items.len == 0) {
        return ".";
    }
    return try std.mem.join(gpa, "/", stack.items);
}

/// `^\s*(?:pub\s+)?(?:inline\s+)?(?:extern\s+)?fn\s+\w+\s*\(` on one line.
fn fnLineMatch(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        i += 1;
    }
    i = tryKw(line, i, "pub");
    i = tryKw(line, i, "inline");
    i = tryKw(line, i, "extern");
    if (!std.mem.startsWith(u8, line[i..], "fn")) {
        return false;
    }
    i += 2;
    if (i >= line.len or !(line[i] == ' ' or line[i] == '\t')) {
        return false;
    }
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        i += 1;
    }
    var k: usize = 0;
    while (i + k < line.len and isWordChar(line[i + k])) {
        k += 1;
    }
    if (k == 0) {
        return false;
    }
    i += k;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
        i += 1;
    }
    return i < line.len and line[i] == '(';
}

/// Consume `kw` + at least one following space/tab if present at `i`.
fn tryKw(line: []const u8, i: usize, kw: []const u8) usize {
    if (!std.mem.startsWith(u8, line[i..], kw)) {
        return i;
    }
    const after: usize = i + kw.len;
    if (after >= line.len or !(line[after] == ' ' or line[after] == '\t')) {
        return i;
    }
    var j: usize = after;
    while (j < line.len and (line[j] == ' ' or line[j] == '\t')) {
        j += 1;
    }
    return j;
}

/// `^test\b` on one line (no leading whitespace).
fn testLineMatch(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "test")) {
        return false;
    }
    return line.len == 4 or !isWordChar(line[4]);
}

const Info = struct {
    path: []const u8,
    src: []const u8,
    is_zig: bool,
    lines: usize,
    fns: ?usize,
    tests: ?usize,
    fdeps: [][]const u8,
    mdeps: [][]const u8,
    hdr: []const u8,
};

fn codepointLen(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) {
            n += 1;
        }
    }
    return n;
}

fn bytePosOfCodepoint(s: []const u8, cp: usize) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] & 0xC0 != 0x80) {
            if (n == cp) {
                return i;
            }
            n += 1;
        }
    }
    return s.len;
}

/// Leading `//!` header joined to one string, truncated to 420 codepoints.
fn headerDesc(gpa: Allocator, src: []const u8) ![]const u8 {
    var parts: ArrayList([]const u8) = .empty;
    var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |ln| {
        if (std.mem.startsWith(u8, ln, "//!")) {
            const t: []const u8 = std.mem.trim(u8, ln[3..], " \t\r");
            if (t.len == 0 and parts.items.len > 0) {
                break;
            }
            if (t.len > 0) {
                try parts.append(gpa, t);
            }
        } else if (parts.items.len > 0 or std.mem.trim(u8, ln, " \t\r").len == 0) {
            break;
        } else {
            break;
        }
    }
    const desc: []const u8 = try std.mem.join(gpa, " ", parts.items);
    if (codepointLen(desc) > 420) {
        const cut: usize = bytePosOfCodepoint(desc, 417);
        var sub: []const u8 = desc[0..cut];
        if (std.mem.lastIndexOfScalar(u8, sub, ' ')) |sp| {
            sub = sub[0..sp];
        }
        return try allocPrint(gpa, "{s}…", .{sub});
    }
    return desc;
}

fn sortedKeys(gpa: Allocator, set: *StringHashMap(void)) ![][]const u8 {
    var keys: ArrayList([]const u8) = .empty;
    var it: std.StringHashMap(void).KeyIterator = set.keyIterator();
    while (it.next()) |k| {
        try keys.append(gpa, k.*);
    }
    std.mem.sort([]const u8, keys.items, {}, lessStr);
    return keys.items;
}

/// Scan `@import("X")` targets (naive, matches the old regex) into the dep sets.
fn scanImports(
    gpa: Allocator,
    src: []const u8,
    path: []const u8,
    fdeps: *StringHashMap(void),
    mdeps: *StringHashMap(void),
) !void {
    const needle: []const u8 = "@import(\"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, needle)) |pos| {
        const start: usize = pos + needle.len;
        const q: usize = std.mem.indexOfScalarPos(u8, src, start, '"') orelse {
            i = start;
            continue;
        };
        if (q == start or q + 1 >= src.len or src[q + 1] != ')') {
            i = q + 1;
            continue;
        }
        const target: []const u8 = src[start..q];
        if (std.mem.endsWith(u8, target, ".zig")) {
            const joined: []const u8 = if (dirOf(path).len == 0)
                target
            else
                try allocPrint(gpa, "{s}/{s}", .{ dirOf(path), target });
            try fdeps.put(try normpath(gpa, joined), {});
        } else if (!std.mem.eql(u8, target, "std") and
            !std.mem.eql(u8, target, "builtin") and
            !std.mem.eql(u8, target, "root"))
        {
            try mdeps.put(try gpa.dupe(u8, target), {});
        }
        i = q + 1;
    }
}

fn lookup(table: []const fd.Entry, path: []const u8) ?[]const u8 {
    for (table) |e| {
        if (std.mem.eql(u8, e.path, path)) {
            return e.text;
        }
    }
    return null;
}

fn nameDerived(gpa: Allocator, name: []const u8) ![]const u8 {
    const base: []const u8 = if (std.mem.startsWith(u8, name, "wgpu_"))
        name["wgpu_".len..]
    else
        name;
    const words: []u8 = try gpa.dupe(u8, base);
    for (words) |*c| {
        if (c.* == '_') {
            c.* = ' ';
        }
    }
    if (std.mem.startsWith(u8, base, "ui_")) {
        return try allocPrint(gpa, "UI example: {s} — runs through UiHost " ++
            "(beginFrameRaw/uiRenderNow) on the wgpu backend.", .{words[3..]});
    }
    if (std.mem.startsWith(u8, base, "input_")) {
        return try allocPrint(gpa, "Input example: {s} — exercises " ++
            "runtime.input through the wgpu app loop.", .{words[6..]});
    }
    return try allocPrint(gpa, "Example: {s} on the wgpu backend.", .{words});
}

fn descFor(gpa: Allocator, info: Info) ![]const u8 {
    if (lookup(&fd.descriptions, info.path)) |d| {
        return d;
    }
    if (info.hdr.len > 0) {
        return info.hdr;
    }
    const base: []const u8 = baseOf(info.path);
    const stem: []const u8 = stemOf(base);
    const d: []const u8 = dirOf(info.path);

    if (std.mem.startsWith(u8, d, "examples/wgpu_") and std.mem.endsWith(u8, base, ".zig")) {
        var parts: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, d, '/');
        _ = parts.next();
        const ex: []const u8 = parts.next() orelse "";
        if (std.mem.eql(u8, stem, ex)) {
            if (lookup(&fd.example_notes, ex)) |note| {
                return note;
            }
            return try nameDerived(gpa, ex);
        }
        if (std.mem.endsWith(u8, base, "_fs.zig") or std.mem.endsWith(u8, base, "_vs.zig")) {
            return "Shader source (shadermath DSL) compiled via the " ++
                "SPIR-V→WGSL pipeline for this example.";
        }
        if (std.mem.endsWith(u8, base, "_io.zig")) {
            return "Typed IO schema for the sibling shader source.";
        }
    }
    if (std.mem.eql(u8, d, "examples")) {
        if (std.mem.endsWith(u8, base, "_fs.zig") or std.mem.endsWith(u8, base, "_vs.zig")) {
            return "Top-level shader source (shadermath DSL), " ++
                "SPIR-V→WGSL compiled, consumed by wgpu examples.";
        }
        if (std.mem.endsWith(u8, base, "_io.zig")) {
            return "Typed IO schema for the sibling top-level shader.";
        }
        if (std.mem.endsWith(u8, base, "_bundle.zig")) {
            return "Native bundle wrapper exposing the sibling shader " ++
                "pair to host-side consumers.";
        }
    }
    if (std.mem.eql(u8, d, "src/shaders")) {
        if (std.mem.endsWith(u8, base, "_fs.zig") or std.mem.endsWith(u8, base, "_vs.zig")) {
            return "Engine shader source (shadermath DSL) in the " ++
                "SPIR-V→WGSL pipeline.";
        }
        if (std.mem.endsWith(u8, base, "_io.zig")) {
            return "Typed IO schema for the sibling engine shader.";
        }
    }
    if (std.mem.eql(u8, d, "src/tests")) {
        return "Cross-cutting host test suite (see file for scope).";
    }
    if (std.mem.endsWith(u8, base, ".html") and std.mem.startsWith(u8, d, "examples/")) {
        return "Per-example page that loads the wasm + bundled runtime.";
    }
    if (std.mem.endsWith(u8, base, ".md")) {
        var it: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, info.src, '\n');
        var seen: usize = 0;
        while (it.next()) |ln| {
            if (seen >= 30) {
                break;
            }
            seen += 1;
            var t: []const u8 = std.mem.trim(u8, ln, " \t\r");
            while (t.len > 0 and t[0] == '#') {
                t = t[1..];
            }
            t = std.mem.trim(u8, t, " \t\r");
            if (t.len > 0) {
                return try allocPrint(gpa, "Note: {s}", .{t});
            }
        }
        return "Design/plan note.";
    }
    return "(no description yet — add a //! header or a dict entry)";
}

fn areaOf(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "examples/wgpu_") or
        std.mem.startsWith(u8, path, "examples/shared"))
    {
        return "examples (wgpu + shared)";
    }
    if (std.mem.startsWith(u8, path, "examples/")) {
        return "examples (top-level)";
    }
    if (std.mem.startsWith(u8, path, "src/shaders/")) {
        return "src/shaders";
    }
    if (std.mem.startsWith(u8, path, "src/spv2wgsl/")) {
        return "src/spv2wgsl";
    }
    if (std.mem.startsWith(u8, path, "src/tests/")) {
        return "src/tests";
    }
    if (std.mem.startsWith(u8, path, "src/web/")) {
        return "src/web";
    }
    if (std.mem.startsWith(u8, path, "src/")) {
        return "src (core)";
    }
    if (std.mem.indexOfScalar(u8, path, '/')) |i| {
        return path[0..i];
    }
    return "(root)";
}

fn isExcludedDir(name: []const u8) bool {
    for (exclude_dirs) |d| {
        if (std.mem.eql(u8, name, d)) {
            return true;
        }
    }
    for (exclude_dir_prefixes) |p| {
        if (std.mem.startsWith(u8, name, p)) {
            return true;
        }
    }
    return false;
}

fn isBinary(name: []const u8) bool {
    const ext: []const u8 = extOf(name);
    for (binary_exts) |b| {
        if (std.mem.eql(u8, ext, b)) {
            return true;
        }
    }
    return false;
}

/// Recursively collect repo-relative file paths under `rel` (""=root),
/// honoring the dir/ext exclusions and skipping the root-level tests/ corpus.
fn walk(
    gpa: Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    rel: []const u8,
    out: *ArrayList([]const u8),
) !void {
    const open_path: []const u8 = if (rel.len == 0) "." else rel;
    var dir: std.Io.Dir = try cwd.openDir(io, open_path, .{ .iterate = true });
    defer dir.close(io);
    var it: std.Io.Dir.Iterator = dir.iterate();
    while (try it.next(io)) |entry| {
        const child: []const u8 = if (rel.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try allocPrint(gpa, "{s}/{s}", .{ rel, entry.name });
        if (entry.kind == .directory) {
            if (isExcludedDir(entry.name)) {
                continue;
            }
            if (rel.len == 0 and std.mem.eql(u8, entry.name, "tests")) {
                continue; // root corpus: grouped entry, not per-file
            }
            try walk(gpa, io, cwd, child, out);
        } else if (entry.kind == .file) {
            if (isBinary(entry.name)) {
                continue;
            }
            try out.append(gpa, child);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: std.Io = init.io;
    const cwd: std.Io.Dir = std.Io.Dir.cwd();

    var files: ArrayList([]const u8) = .empty;
    try walk(gpa, io, cwd, "", &files);
    std.mem.sort([]const u8, files.items, {}, lessStr);

    var info_map: StringHashMap(Info) = .init(gpa);
    var dependents: StringHashMap(*ArrayList([]const u8)) = .init(gpa);

    for (files.items) |p| {
        const src: []const u8 = cwd.readFileAlloc(io, p, gpa, .unlimited) catch "";
        // Match python text-mode universal newlines: \r\n and lone \r count
        // as one line terminator (matters only for stray-\r binary files).
        const lines: usize = std.mem.count(u8, src, "\r") +
            std.mem.count(u8, src, "\n") -
            std.mem.count(u8, src, "\r\n") + 1;
        const is_zig: bool = std.mem.endsWith(u8, p, ".zig");
        var inf: Info = .{
            .path = p,
            .src = src,
            .is_zig = is_zig,
            .lines = lines,
            .fns = null,
            .tests = null,
            .fdeps = &.{},
            .mdeps = &.{},
            .hdr = "",
        };
        if (is_zig) {
            var nfns: usize = 0;
            var ntests: usize = 0;
            var lit: std.mem.SplitIterator(u8, .scalar) = std.mem.splitScalar(u8, src, '\n');
            while (lit.next()) |ln| {
                if (fnLineMatch(ln)) {
                    nfns += 1;
                }
                if (testLineMatch(ln)) {
                    ntests += 1;
                }
            }
            inf.fns = nfns;
            inf.tests = ntests;
            var fset: StringHashMap(void) = .init(gpa);
            var mset: StringHashMap(void) = .init(gpa);
            try scanImports(gpa, src, p, &fset, &mset);
            inf.fdeps = try sortedKeys(gpa, &fset);
            inf.mdeps = try sortedKeys(gpa, &mset);
            inf.hdr = try headerDesc(gpa, src);
            for (inf.fdeps) |dep| {
                const gop: std.StringHashMap(*ArrayList([]const u8)).GetOrPutResult = try dependents.getOrPut(dep);
                if (!gop.found_existing) {
                    const list: *ArrayList([]const u8) = try gpa.create(ArrayList([]const u8));
                    list.* = .empty;
                    gop.value_ptr.* = list;
                }
                try gop.value_ptr.*.append(gpa, p);
            }
        }
        try info_map.put(p, inf);
    }

    // build.zig path references count as wiring-dependents.
    const bz: []const u8 = cwd.readFileAlloc(io, "build.zig", gpa, .unlimited) catch "";
    for (files.items) |p| {
        if (!std.mem.eql(u8, p, "build.zig") and std.mem.indexOf(u8, bz, p) != null) {
            const gop: std.StringHashMap(*ArrayList([]const u8)).GetOrPutResult = try dependents.getOrPut(p);
            if (!gop.found_existing) {
                const list: *ArrayList([]const u8) = try gpa.create(ArrayList([]const u8));
                list.* = .empty;
                gop.value_ptr.* = list;
            }
            try gop.value_ptr.*.append(gpa, "build.zig (wired)");
        }
    }

    // --- Topography: the src/*.zig module import graph (the SAME analysis
    // that backs `zig build dag-check`, via the shared import_graph.zig).
    // Gives per-file DAG levels (longest-path layers), out-degree hubs, and
    // the level-ordering for the "src (core)" section below. ---
    const graph: ig.Graph = try ig.build(gpa, io, "src");
    const level: []u32 = try ig.levels(gpa, graph);
    const max_level: u32 = ig.maxLevel(level);

    var level_of: StringHashMap(u32) = .init(gpa);
    for (graph.names, 0..) |nm, idx| {
        const key: []const u8 = try allocPrint(gpa, "src/{s}.zig", .{nm});
        try level_of.put(key, level[idx]);
    }

    var hubs: ArrayList(Hub) = .empty;
    for (graph.names, 0..) |nm, idx| {
        try hubs.append(gpa, .{ .name = nm, .deg = graph.outDegree(idx) });
    }
    std.mem.sort(Hub, hubs.items, {}, hubMore);

    const comps: ArrayList(ArrayList(u32)) = try ig.sccs(gpa, graph);
    var n_cycles: usize = 0;
    for (comps.items) |c| {
        if (c.items.len > 1) {
            n_cycles += 1;
        }
    }

    const reduced: []ArrayList(u32) = try ig.transitiveReduction(gpa, graph);
    const reduced_edges: usize = ig.edgeCount(reduced);

    // Group into areas.
    var area_names: ArrayList([]const u8) = .empty;
    var area_map: StringHashMap(*ArrayList([]const u8)) = .init(gpa);
    for (files.items) |p| {
        const a: []const u8 = areaOf(p);
        const gop: std.StringHashMap(*ArrayList([]const u8)).GetOrPutResult = try area_map.getOrPut(a);
        if (!gop.found_existing) {
            const list: *ArrayList([]const u8) = try gpa.create(ArrayList([]const u8));
            list.* = .empty;
            gop.value_ptr.* = list;
            try area_names.append(gpa, a);
        }
        try gop.value_ptr.*.append(gpa, p);
    }

    const fixed_order = [_][]const u8{
        "(root)",               "src (core)",               "src/shaders",
        "src/spv2wgsl",         "src/tests",                "src/web",
        "examples (top-level)", "examples (wgpu + shared)", "tools",
        "scripts",              "webtests",
    };
    var order: ArrayList([]const u8) = .empty;
    for (fixed_order) |a| {
        try order.append(gpa, a);
    }
    std.mem.sort([]const u8, area_names.items, {}, lessStr);
    for (area_names.items) |a| {
        var present: bool = false;
        for (fixed_order) |f| {
            if (std.mem.eql(u8, a, f)) {
                present = true;
                break;
            }
        }
        if (!present) {
            try order.append(gpa, a);
        }
    }

    // Order the "src (core)" section bottom-up by DAG level (then name) - the
    // suggested reading order from the topography block.
    if (area_map.get("src (core)")) |core_list| {
        std.mem.sort([]const u8, core_list.items, LvlCtx{ .map = &level_of }, lvlLess);
    }

    var total_zig: usize = 0;
    var total_lines: usize = 0;
    for (files.items) |p| {
        if (std.mem.endsWith(u8, p, ".zig")) {
            total_zig += 1;
            total_lines += info_map.get(p).?.lines;
        }
    }

    // Today's date (UTC), ISO yyyy-mm-dd.
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts.sec) };
    const ed: std.time.epoch.EpochDay = es.getEpochDay();
    const yd: std.time.epoch.YearAndDay = ed.calculateYearDay();
    const md: std.time.epoch.MonthAndDay = yd.calculateMonthDay();
    const date: []const u8 = try allocPrint(gpa, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        yd.year, md.month.numeric(), @as(u32, md.day_index) + 1,
    });

    var chunks: ArrayList([]const u8) = .empty;
    try chunks.append(gpa, "# zimr file atlas\n");
    try chunks.append(gpa, try allocPrint(gpa, "*Generated {s} by " ++
        "`zig build files-md` (tools/gen_files_md.zig) — regenerate after " ++
        "structural changes; counts/deps are computed, descriptions come from " ++
        "`//!` headers (preferred) or tools/file_descriptions.zig.*\n", .{date}));
    try chunks.append(gpa, try allocPrint(gpa, "**{d} .zig files, {s} lines of Zig.** " ++
        "Module-name dependencies (`zm`, `shader_interface`, " ++
        "`build_options`, `sw_runtime`, …) are build-wired; file " ++
        "dependencies are direct `@import` paths. *Dependents* are " ++
        "in-tree importers (plus `build.zig (wired)` when the build " ++
        "references the path).\n", .{ total_zig, try commaInt(gpa, total_lines) }));

    // Topography block: DAG levels + hubs (shared import_graph analysis).
    {
        var tb: ArrayList([]const u8) = .empty;
        try tb.append(gpa, "\n## Topography\n");
        try tb.append(gpa, try allocPrint(gpa, "The `src/*.zig` module import graph: " ++
            "**{d} modules, {d} edges, {d} cycles** ({d} edges after transitive " ++
            "reduction — see the graph below). The DAG levels below are " ++
            "longest-path layers — bottom-up: `L0` imports no in-tree module, and " ++
            "each level builds only on lower ones. This is the suggested reading " ++
            "order, and the order of the *src (core)* section.\n", .{
            graph.nodeCount(), graph.total_edges, n_cycles, reduced_edges,
        }));
        var lv: u32 = 0;
        while (lv <= max_level) : (lv += 1) {
            var row: ArrayList([]const u8) = .empty;
            for (graph.names, 0..) |nm, idx| {
                if (level[idx] == lv) {
                    try row.append(gpa, nm);
                }
            }
            std.mem.sort([]const u8, row.items, {}, lessStr);
            var cells: ArrayList([]const u8) = .empty;
            for (row.items) |nm| {
                try cells.append(gpa, try allocPrint(gpa, "`{s}`", .{nm}));
            }
            const joined: []const u8 = try std.mem.join(gpa, ", ", cells.items);
            try tb.append(gpa, try allocPrint(gpa, "- **L{d}** ({d}): {s}\n", .{
                lv, row.items.len, joined,
            }));
        }
        var hb: ArrayList([]const u8) = .empty;
        for (hubs.items[0..@min(8, hubs.items.len)]) |h| {
            try hb.append(gpa, try allocPrint(gpa, "`{s}` ({d})", .{ h.name, h.deg }));
        }
        try tb.append(gpa, try allocPrint(gpa, "\n**Out-degree hubs:** {s}\n", .{
            try std.mem.join(gpa, ", ", hb.items),
        }));
        try chunks.append(gpa, try std.mem.join(gpa, "", tb.items));
    }

    // Dependency graph (Mermaid) - the transitive reduction, so the diagram
    // shows only direct/covering edges instead of the full 212-edge hairball.
    {
        var mb: ArrayList([]const u8) = .empty;
        try mb.append(gpa, "\n## Dependency graph\n");
        try mb.append(gpa, try allocPrint(gpa, "Transitive reduction of the src import " ++
            "DAG ({d} direct `@import` edges reduced to {d} covering edges; an edge " ++
            "already implied by a longer path is dropped). Top-to-bottom: an importer " ++
            "points down to what it directly needs.\n", .{ graph.total_edges, reduced_edges }));
        try mb.append(gpa, "\n```mermaid\ngraph TD\n");

        const used: []bool = try gpa.alloc(bool, graph.names.len);
        @memset(used, false);
        for (0..graph.names.len) |u| {
            for (reduced[u].items) |v| {
                try mb.append(gpa, try allocPrint(gpa, "  {s} --> {s}\n", .{
                    graph.names[u], graph.names[v],
                }));
                used[u] = true;
                used[v] = true;
            }
        }
        // Declare any node with no covering edge (isolated) so it still shows.
        for (0..graph.names.len) |i| {
            if (!used[i]) {
                try mb.append(gpa, try allocPrint(gpa, "  {s}\n", .{graph.names[i]}));
            }
        }
        try mb.append(gpa, "```\n");
        try mb.append(gpa, "\nA pixel-rendered version of this same graph — drawn by zimr's own " ++
            "software rasterizer, with each box sized by line count — is regenerated by " ++
            "`zig build dag-png`:\n\n![src module dependency graph](dag.png)\n");
        try chunks.append(gpa, try std.mem.join(gpa, "", mb.items));
    }
    try chunks.append(gpa, "Grouped entries (not per-file): `tests/fixtures/external/" ++
        "tint/` — 363 SPIR-V/WGSL fixtures from Tint's corpus " ++
        "driving the spv2wgsl regression; `tests/fixtures/" ++
        "phi_repro/` — 7 minimized phi-node repros; `tests/" ++
        "snapshots/` — UI snapshot PNG baselines; `assets/` — " ++
        "runtime-fetched images.\n");

    for (order.items) |a| {
        const area_list_opt: ?*ArrayList([]const u8) = area_map.get(a);
        if (area_list_opt == null) {
            continue;
        }
        try chunks.append(gpa, try allocPrint(gpa, "\n## {s}\n", .{a}));
        for (area_list_opt.?.items) |p| {
            const i: Info = info_map.get(p).?;
            try chunks.append(gpa, try allocPrint(gpa, "### `{s}`\n", .{p}));
            try chunks.append(gpa, try allocPrint(gpa, "{s}\n", .{try descFor(gpa, i)}));

            var stats: ArrayList([]const u8) = .empty;
            try stats.append(gpa, try allocPrint(gpa, "{s} lines", .{try commaInt(gpa, i.lines)}));
            if (i.is_zig) {
                const head: []const u8 = if (i.src.len >= 64) i.src[0..64] else i.src;
                if (std.mem.startsWith(u8, head, "//! SHADER-SAFE") or
                    std.mem.endsWith(u8, p, "_io.zig"))
                {
                    try stats.insert(gpa, 0, "[shader-safe]");
                }
            }
            // Per-file DAG level tag (src-core modules only), leftmost.
            if (level_of.get(p)) |lv| {
                try stats.insert(gpa, 0, try allocPrint(gpa, "L{d}", .{lv}));
            }
            if (i.fns) |nf| {
                try stats.append(gpa, try allocPrint(gpa, "{d} fns", .{nf}));
                if (i.tests.? > 0) {
                    try stats.append(gpa, try allocPrint(gpa, "{d} tests", .{i.tests.?}));
                }
            }
            const stats_s: []const u8 = try std.mem.join(gpa, " · ", stats.items);

            var deps: ArrayList([]const u8) = .empty;
            for (i.fdeps) |fdp| {
                try deps.append(gpa, try allocPrint(gpa, "`{s}`", .{fdp}));
            }
            for (i.mdeps) |mdp| {
                try deps.append(gpa, try allocPrint(gpa, "`{s}` (module)", .{mdp}));
            }
            const deps_s: []const u8 = if (deps.items.len > 0)
                try std.mem.join(gpa, ", ", deps.items)
            else
                "—";

            var dd_s: []const u8 = "—";
            if (dependents.get(p)) |dlist| {
                std.mem.sort([]const u8, dlist.items, {}, lessStr);
                var dd: ArrayList([]const u8) = .empty;
                for (dlist.items) |x| {
                    try dd.append(gpa, try allocPrint(gpa, "`{s}`", .{x}));
                }
                dd_s = try std.mem.join(gpa, ", ", dd.items);
            }

            try chunks.append(gpa, try allocPrint(
                gpa,
                "*{s}*  \n**Deps:** {s}  \n**Dependents:** {s}\n",
                .{ stats_s, deps_s, dd_s },
            ));
        }
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    for (chunks.items, 0..) |c, i| {
        if (i > 0) {
            try w.writeAll("\n");
        }
        try w.writeAll(c);
    }
    try w.writeAll("\n");
    try cwd.writeFile(io, .{ .sub_path = "src/notes/files.md", .data = aw.written() });

    var out_buf: [256]u8 = undefined;
    var ow: std.Io.File.Writer = std.Io.File.stdout().writer(io, &out_buf);
    try ow.interface.print("wrote src/notes/files.md: {d} zig files, {d} entries, {s} zig lines\n", .{
        total_zig, files.items.len, try commaInt(gpa, total_lines),
    });
    try ow.interface.flush();
}
