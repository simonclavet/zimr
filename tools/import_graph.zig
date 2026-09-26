//! import_graph.zig - shared src-module import-graph analysis for the zimr
//! tooling (dag_check, gen_files_md, ...).
//!
//! Tokenizer-based `@import("x.zig")` scan (no regex false edges from
//! comments/strings), forward + reverse adjacency, Tarjan SCC, and
//! longest-path DAG levels.  std-only.
//!
//! No build wiring needed: tools in tools/ pull this in as a sibling
//! file-import, `const ig = @import("import_graph.zig");`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const allocPrint = std.fmt.allocPrint;

/// Ascending string order, for std.mem.sort.
pub fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Null-terminated copy (Allocator.dupeZ was removed in Zig 0.17).
fn dupeZ(gpa: Allocator, bytes: []const u8) ![:0]u8 {
    const out: [:0]u8 = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(out, bytes);
    return out;
}

/// Append every `@import("X.zig")` target (bare name, no ".zig") found in
/// `source` to `out`.  Tokenizer-based: hits inside comments or strings are
/// impossible because the tokenizer does not emit tokens for them.
pub fn collectImports(
    gpa: Allocator,
    source: [:0]const u8,
    out: *ArrayList([]const u8),
) !void {
    var tk: std.zig.Tokenizer = .init(source);
    while (true) {
        const t: std.zig.Token = tk.next();
        if (t.tag == .eof) {
            break;
        }
        if (t.tag != .builtin) {
            continue;
        }
        if (!std.mem.eql(u8, source[t.loc.start..t.loc.end], "@import")) {
            continue;
        }
        const lp: std.zig.Token = tk.next();
        if (lp.tag != .l_paren) {
            continue;
        }
        const sl: std.zig.Token = tk.next();
        if (sl.tag != .string_literal) {
            continue;
        }
        const raw: []const u8 = source[sl.loc.start..sl.loc.end]; // has quotes
        if (raw.len < 2) {
            continue;
        }
        const inner: []const u8 = raw[1 .. raw.len - 1];
        // Resolve to a src-node name. File imports map by basename; a few
        // build-wired MODULE imports map to their backing src file so the
        // graph reflects real dependencies (e.g. `@import("zm")` is zimrmath,
        // imported almost everywhere - it is the engine's true foundation).
        var target: []const u8 = inner;
        if (std.mem.endsWith(u8, inner, ".zig")) {
            target = inner[0 .. inner.len - ".zig".len];
        } else if (std.mem.eql(u8, inner, "zm")) {
            target = "zimrmath";
        } else if (std.mem.eql(u8, inner, "shader_interface")) {
            target = "shader_interface";
        } else {
            continue; // std / builtin / build_options / external modules
        }
        try out.append(gpa, target);
    }
}

/// The src module import graph: `names` indexed by node id, `adj[i]` the
/// modules i imports, `rev[i]` the modules that import i (dependents).
pub const Graph = struct {
    names: [][]const u8,
    adj: []ArrayList(u32),
    rev: []ArrayList(u32),
    total_edges: usize,

    pub fn nodeCount(self: Graph) usize {
        return self.names.len;
    }

    pub fn outDegree(self: Graph, id: usize) usize {
        return self.adj[id].items.len;
    }

    pub fn inDegree(self: Graph, id: usize) usize {
        return self.rev[id].items.len;
    }
};

/// Parse every `*.zig` in `src_dir` and build the deduplicated import graph.
pub fn build(gpa: Allocator, io: std.Io, src_dir: []const u8) !Graph {
    const cwd: std.Io.Dir = std.Io.Dir.cwd();

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
            const bare: []const u8 = entry.name[0 .. entry.name.len - ".zig".len];
            try names.append(gpa, try gpa.dupe(u8, bare));
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessStr);
    const n: usize = names.items.len;

    var id_of: StringHashMap(u32) = .init(gpa);
    for (names.items, 0..) |nm, i| {
        try id_of.put(nm, @intCast(i));
    }

    const adj: []ArrayList(u32) = try gpa.alloc(ArrayList(u32), n);
    const rev: []ArrayList(u32) = try gpa.alloc(ArrayList(u32), n);
    for (0..n) |i| {
        adj[i] = .empty;
        rev[i] = .empty;
    }
    var total_edges: usize = 0;

    for (names.items, 0..) |nm, i| {
        const fname: []u8 = try allocPrint(gpa, "{s}.zig", .{nm});
        const path: []u8 = try std.fs.path.join(gpa, &.{ src_dir, fname });
        const text: []u8 = cwd.readFileAlloc(io, path, gpa, .unlimited) catch continue;
        const text_z: [:0]u8 = try dupeZ(gpa, text);
        var imports: ArrayList([]const u8) = .empty;
        try collectImports(gpa, text_z, &imports);
        for (imports.items) |tgt| {
            const tid: u32 = id_of.get(tgt) orelse continue;
            if (tid == @as(u32, @intCast(i))) {
                continue;
            }
            var dup: bool = false;
            for (adj[i].items) |e| {
                if (e == tid) {
                    dup = true;
                    break;
                }
            }
            if (!dup) {
                try adj[i].append(gpa, tid);
                try rev[tid].append(gpa, @intCast(i));
                total_edges += 1;
            }
        }
    }

    return .{
        .names = names.items,
        .adj = adj,
        .rev = rev,
        .total_edges = total_edges,
    };
}

const Frame = struct { v: u32, child: usize };

/// Iterative Tarjan SCC.  Returns each strongly-connected component as a list
/// of node ids.  (Self-edges are pre-filtered, so size-1 components are always
/// trivial.)
pub fn sccs(gpa: Allocator, g: Graph) !ArrayList(ArrayList(u32)) {
    const n: usize = g.names.len;
    const index: []i64 = try gpa.alloc(i64, n);
    const lowlink: []i64 = try gpa.alloc(i64, n);
    const on_stack: []bool = try gpa.alloc(bool, n);
    @memset(index, -1);
    @memset(lowlink, 0);
    @memset(on_stack, false);

    var stack: ArrayList(u32) = .empty;
    var comps: ArrayList(ArrayList(u32)) = .empty;
    var work: ArrayList(Frame) = .empty;
    var counter: i64 = 0;

    var s: usize = 0;
    while (s < n) : (s += 1) {
        if (index[s] != -1) {
            continue;
        }
        try work.append(gpa, .{ .v = @intCast(s), .child = 0 });
        while (work.items.len > 0) {
            const top: *Frame = &work.items[work.items.len - 1];
            const v: u32 = top.v;
            if (top.child == 0) {
                index[v] = counter;
                lowlink[v] = counter;
                counter += 1;
                try stack.append(gpa, v);
                on_stack[v] = true;
            }
            if (top.child < g.adj[v].items.len) {
                const w: u32 = g.adj[v].items[top.child];
                top.child += 1;
                if (index[w] == -1) {
                    try work.append(gpa, .{ .v = w, .child = 0 });
                } else if (on_stack[w] and index[w] < lowlink[v]) {
                    lowlink[v] = index[w];
                }
            } else {
                if (lowlink[v] == index[v]) {
                    var comp: ArrayList(u32) = .empty;
                    while (true) {
                        const w: u32 = stack.items[stack.items.len - 1];
                        stack.items.len -= 1;
                        on_stack[w] = false;
                        try comp.append(gpa, w);
                        if (w == v) {
                            break;
                        }
                    }
                    try comps.append(gpa, comp);
                }
                _ = work.pop();
                if (work.items.len > 0) {
                    const parent: u32 = work.items[work.items.len - 1].v;
                    if (lowlink[v] < lowlink[parent]) {
                        lowlink[parent] = lowlink[v];
                    }
                }
            }
        }
    }
    return comps;
}

/// Longest-path level per node (valid for a DAG): level[v] = 0 if v imports
/// nothing, else 1 + max(level over deps).  A bottom-up reading order.
pub fn levels(gpa: Allocator, g: Graph) ![]u32 {
    const n: usize = g.names.len;
    const level: []u32 = try gpa.alloc(u32, n);
    const pending: []usize = try gpa.alloc(usize, n);
    @memset(level, 0);
    for (0..n) |i| {
        pending[i] = g.adj[i].items.len;
    }
    var queue: ArrayList(u32) = .empty;
    for (0..n) |i| {
        if (pending[i] == 0) {
            try queue.append(gpa, @intCast(i));
        }
    }
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const v: u32 = queue.items[head];
        for (g.rev[v].items) |u| {
            if (level[v] + 1 > level[u]) {
                level[u] = level[v] + 1;
            }
            pending[u] -= 1;
            if (pending[u] == 0) {
                try queue.append(gpa, u);
            }
        }
    }
    return level;
}

/// Largest value in `level` (0 if empty).
pub fn maxLevel(level: []const u32) u32 {
    var m: u32 = 0;
    for (level) |l| {
        if (l > m) {
            m = l;
        }
    }
    return m;
}

/// Transitive reduction of the (acyclic) graph: the unique minimal edge set
/// with the same reachability.  Drops every edge u->v that is already implied
/// by a longer path u->...->v.  Returned as adjacency parallel to `g.adj`
/// (each list sorted ascending by id).  Result is meaningful only for a DAG.
pub fn transitiveReduction(gpa: Allocator, g: Graph) ![]ArrayList(u32) {
    const n: usize = g.names.len;

    // reach[u*n + x] = x is reachable from u via a path of length >= 1.
    const reach: []bool = try gpa.alloc(bool, n * n);
    @memset(reach, false);
    var stack: ArrayList(u32) = .empty;
    for (0..n) |s| {
        stack.clearRetainingCapacity();
        for (g.adj[s].items) |w| {
            try stack.append(gpa, w);
        }
        while (stack.items.len > 0) {
            const v: u32 = stack.pop().?;
            if (reach[s * n + v]) {
                continue;
            }
            reach[s * n + v] = true;
            for (g.adj[v].items) |w| {
                if (!reach[s * n + w]) {
                    try stack.append(gpa, w);
                }
            }
        }
    }

    // Keep u->v iff no OTHER direct successor w of u can already reach v.
    const red: []ArrayList(u32) = try gpa.alloc(ArrayList(u32), n);
    for (0..n) |i| {
        red[i] = .empty;
    }
    for (0..n) |u| {
        for (g.adj[u].items) |v| {
            var redundant: bool = false;
            for (g.adj[u].items) |w| {
                if (w == v) {
                    continue;
                }
                if (reach[@as(usize, w) * n + v]) {
                    redundant = true;
                    break;
                }
            }
            if (!redundant) {
                try red[u].append(gpa, v);
            }
        }
        std.mem.sort(u32, red[u].items, {}, lessU32);
    }
    return red;
}

fn lessU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

/// Count edges in an adjacency slice (e.g. a transitive-reduction result).
pub fn edgeCount(adj: []const ArrayList(u32)) usize {
    var total: usize = 0;
    for (adj) |list| {
        total += list.items.len;
    }
    return total;
}
