//! dag_check.zig - verify the `src/*.zig` file-level import graph is a DAG.
//!
//! The import-graph analysis (tokenizer @import scan, Tarjan SCC, levels)
//! lives in the shared `import_graph.zig`, used by both this gate and
//! gen_files_md.  This file is just the gate + report:
//!
//!   - No whitelist: the graph must be FULLY acyclic.  Prints each offending
//!     SCC and exits 1 on any cycle.
//!   - On success: module/edge counts, out-degree hubs, and the auto-computed
//!     DAG layering (longest-path levels = a suggested bottom-up reading
//!     order).  Exit 0.
//!
//! Usage: `dag_check [src_dir]`  (src_dir defaults to "src").

const std = @import("std");
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const sortSlice = std.mem.sort;
const ig = @import("import_graph.zig");

const Deg = struct { id: u32, deg: usize };

fn degMore(_: void, a: Deg, b: Deg) bool {
    return a.deg > b.deg;
}

/// The command line (std's cli, `src/command_line.zig`).
const DagArgs = struct {
    @"src-dir": []const u8 = "src",
};

const dag_cli: cli.Config(DagArgs) = .{
    .prog = "dag_check",
    .description = "Levels and cycles of the top-level src/*.zig import graph (by basename).",
};

pub fn main(init: std.process.Init) !void {
    var arena_state: ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const gpa: Allocator = arena_state.allocator();
    const io: Io = init.io;

    const args: DagArgs = cli.args(&init, DagArgs, dag_cli);
    const src_dir: []const u8 = args.@"src-dir";

    const g: ig.Graph = try ig.build(gpa, io, src_dir);
    const n: usize = g.nodeCount();

    var out_buf: [8192]u8 = undefined;
    var ow: Io.File.Writer = Io.File.stdout().writer(io, &out_buf);
    const out: *Io.Writer = &ow.interface;

    // Cycle detection - the gate.  No whitelist.
    const comps: ArrayList(ArrayList(u32)) = try ig.sccs(gpa, g);
    var n_nontrivial: usize = 0;
    for (comps.items) |c| {
        if (c.items.len > 1) {
            n_nontrivial += 1;
        }
    }

    try out.print("Modules:  {d}\n", .{n});
    try out.print("Edges:    {d}\n", .{g.total_edges});
    try out.print("SCCs:     {d} non-trivial\n", .{n_nontrivial});

    if (n_nontrivial > 0) {
        for (comps.items) |c| {
            if (c.items.len <= 1) {
                continue;
            }
            var members: ArrayList([]const u8) = .empty;
            for (c.items) |vid| {
                try members.append(gpa, g.names[vid]);
            }
            sortSlice([]const u8, members.items, {}, ig.lessStr);
            try out.print("  CYCLE (size {d}):", .{c.items.len});
            for (members.items) |m| {
                try out.print(" {s}", .{m});
            }
            try out.print("\n", .{});
        }
        try out.print("\nFAIL: src import graph is not a DAG.\n", .{});
        try out.flush();
        std.process.exit(1);
    }

    // Out-degree hubs (top 8).
    var degs: ArrayList(Deg) = .empty;
    for (0..n) |i| {
        try degs.append(gpa, .{ .id = @intCast(i), .deg = g.outDegree(i) });
    }
    sortSlice(Deg, degs.items, {}, degMore);
    try out.print("\nOut-degree (top 8):\n", .{});
    for (degs.items[0..@min(8, degs.items.len)]) |d| {
        try out.print("  {s:<20} {d}\n", .{ g.names[d.id], d.deg });
    }

    // DAG layering = longest-path levels (a bottom-up reading order).
    const level: []u32 = try ig.levels(gpa, g);
    const max_level: u32 = ig.maxLevel(level);
    try out.print("\nDAG levels (suggested bottom-up reading order):\n", .{});
    var lvl: u32 = 0;
    while (lvl <= max_level) : (lvl += 1) {
        var row: ArrayList([]const u8) = .empty;
        for (0..n) |i| {
            if (level[i] == lvl) {
                try row.append(gpa, g.names[i]);
            }
        }
        sortSlice([]const u8, row.items, {}, ig.lessStr);
        try out.print("  L{d} ({d}):", .{ lvl, row.items.len });
        for (row.items) |m| {
            try out.print(" {s}", .{m});
        }
        try out.print("\n", .{});
    }

    try out.flush();
}
