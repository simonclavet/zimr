//! dag_png.zig - render the src/*.zig dependency graph to a PNG, drawn by
//! zimr itself (the same `Canvas` / software rasterizer / truetype
//! / PNG codec that the engine ships).  Dogfood: zimr drawing its own map.
//!
//!   - Nodes = src modules; rectangle AREA is proportional to lines of code.
//!   - Color = DAG level (L0 foundations -> L10), from the shared import_graph.
//!   - Edges = the TRANSITIVE REDUCTION (covering edges only, not the hairball).
//!   - Layout = layered by level + barycenter crossing reduction + iterative
//!     coordinate relaxation (connected nodes pull into alignment).  Modules
//!     with no in-tree file imports (module-wired foundations like zimrmath)
//!     are shown in a separate strip at the bottom.
//!
//! Usage: `zig build dag-png`  (writes src/notes/dag.png; run from repo root).

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const z = @import("zimr");
const zm = @import("zm");
const float = zm.float;
const ig = @import("import_graph.zig");
const fd = @import("file_descriptions.zig");

const Canvas = z.Canvas;
const Color = zm.Color;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const allocPrint = std.fmt.allocPrint;

// ---- tunables (all in final pixels) ---------------------------------------
const area_k: f32 = 7.0; // px^2 of box area per line of code
const aspect: f32 = 1.7; // node box width:height ratio (squarer => room for text lines)
const min_w: f32 = 96;
const min_h: f32 = 54;
const max_w: f32 = 300;
const max_h: f32 = 200;
const h_gap: f32 = 28; // min horizontal gap between boxes in a row
const row_vgap: f32 = 78; // vertical gap between row bands
const margin: f32 = 70; // outer margin
const top_pad: f32 = 132; // space above first row for the title block
const iso_gap: f32 = 84; // gap between main graph and the isolated strip
const sweeps: usize = 16; // barycenter ordering sweeps
const relax_passes: usize = 80; // coordinate relaxation passes
const min_canvas_w: f32 = 1180; // keep room for the title

// --- force-directed (freeform) layout tunables ---
const fd_iters: usize = 820; // total iterations
const fd_ygap: f32 = 76; // directed vertical rest gap: importer sits this far ABOVE its dep
const fd_yhier: f32 = 0.28; // strength of the directed vertical ordering (the SOLE y force)
const fd_attx: f32 = 0.08; // horizontal spring pulling coupled files toward a common column
const fd_k: f32 = 46; // repulsion scale (px) - small, balances the linear column spring
const fd_gravx: f32 = 0.05; // horizontal compaction toward the axis
const fd_rep_tail: usize = 260; // x-only repulsion enabled ONLY in the last N iters (fan-out)
const fd_rep_temp: f32 = 110; // temperature reset to this when repulsion turns on
const fd_step0: f32 = 150; // initial max displacement per iter (px)
const fd_cooling: f32 = 0.99; // temperature decay per iter
const fd_min_step: f32 = 1.2; // floor on the cooling temperature
const fd_overlap_passes: usize = 220; // box overlap-removal sweeps after convergence

fn countLines(io: std.Io, gpa: Allocator, path: []const u8) !usize {
    const cwd: std.Io.Dir = std.Io.Dir.cwd();
    const text: []u8 = cwd.readFileAlloc(io, path, gpa, .unlimited) catch return 0;
    var nl: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            nl += 1;
        }
    }
    return nl + 1;
}

/// A Spectral-ish ramp: deep indigo (L0) -> blue -> teal -> green -> yellow ->
/// orange -> red (top).  t in [0,1].
fn levelColor(t: f32) Color {
    const anchors = [_][4]f32{
        .{ 0.00, 49, 54, 149 },
        .{ 0.20, 69, 117, 180 },
        .{ 0.40, 116, 173, 209 },
        .{ 0.55, 150, 191, 150 },
        .{ 0.70, 224, 221, 128 },
        .{ 0.85, 253, 174, 97 },
        .{ 1.00, 240, 110, 70 },
    };
    var i: usize = 0;
    while (i + 1 < anchors.len and t > anchors[i + 1][0]) : (i += 1) {}
    const a: [4]f32 = anchors[i];
    const b: [4]f32 = anchors[@min(i + 1, anchors.len - 1)];
    const span: f32 = b[0] - a[0];
    const u: f32 = if (span > 0.0001) (t - a[0]) / span else 0;
    const r: f32 = a[1] + (b[1] - a[1]) * u;
    const g: f32 = a[2] + (b[2] - a[2]) * u;
    const bl: f32 = a[3] + (b[3] - a[3]) * u;
    return .{ .r = @intFromFloat(r), .g = @intFromFloat(g), .b = @intFromFloat(bl), .a = 255 };
}

fn darken(c: Color, f: f32) Color {
    return .{
        .r = @intFromFloat(float(c.r) * f),
        .g = @intFromFloat(float(c.g) * f),
        .b = @intFromFloat(float(c.b) * f),
        .a = c.a,
    };
}

fn textColorFor(c: Color) Color {
    const lum: f32 = (0.299 * float(c.r) +
        0.587 * float(c.g) +
        0.114 * float(c.b)) / 255.0;
    if (lum < 0.58) {
        return .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    }
    return .{ .r = 20, .g = 22, .b = 30, .a = 255 };
}

const KeyCtx = struct { key: []f32 };

fn keyLess(ctx: KeyCtx, a: u32, b: u32) bool {
    return ctx.key[a] < ctx.key[b];
}

/// Pack each row left->right (min gap), centered about x=0.
fn repack(rows: []ArrayList(u32), bw: []const f32, cx: []f32) void {
    for (rows) |row| {
        var total: f32 = 0;
        for (row.items, 0..) |id, i| {
            total += bw[id];
            if (i + 1 < row.items.len) {
                total += h_gap;
            }
        }
        var cursor: f32 = -total / 2;
        for (row.items) |id| {
            cx[id] = cursor + bw[id] / 2;
            cursor += bw[id] + h_gap;
        }
    }
}

/// Remove overlaps left-to-right (anchor leftmost), order-preserving.
fn resolveLR(row: []const u32, bw: []const f32, cx: []f32) void {
    var i: usize = 1;
    while (i < row.len) : (i += 1) {
        const prev: u32 = row[i - 1];
        const cur: u32 = row[i];
        const need: f32 = cx[prev] + bw[prev] / 2 + h_gap + bw[cur] / 2;
        if (cx[cur] < need) {
            cx[cur] = need;
        }
    }
}

/// Remove overlaps right-to-left (anchor rightmost), order-preserving.
fn resolveRL(row: []const u32, bw: []const f32, cx: []f32) void {
    if (row.len < 2) {
        return;
    }
    var i: usize = row.len - 1;
    while (i > 0) : (i -= 1) {
        const right: u32 = row[i];
        const cur: u32 = row[i - 1];
        const need: f32 = cx[right] - bw[right] / 2 - h_gap - bw[cur] / 2;
        if (cx[cur] > need) {
            cx[cur] = need;
        }
    }
}

/// Look up a file's curated key-symbol label ("" if none).
fn symsFor(name: []const u8) []const u8 {
    for (fd.key_symbols) |k| {
        if (std.mem.eql(u8, k.name, name)) {
            return k.syms;
        }
    }
    return "";
}

fn drawNode(
    canvas: *Canvas,
    name: []const u8,
    syms: []const u8,
    ccx: f32,
    ccy: f32,
    w: f32,
    h: f32,
    fill: Color,
) void {
    const x0: f32 = ccx - w / 2;
    const y0: f32 = ccy - h / 2;
    canvas.fillRect(.{ .x = x0 - 1.5, .y = y0 - 1.5, .w = w + 3, .h = h + 3 }, darken(fill, 0.5));
    canvas.fillRect(.{ .x = x0, .y = y0, .w = w, .h = h }, fill);
    const tc: Color = textColorFor(fill);
    const char_w: f32 = 0.632; // Atkinson Hyperlegible Mono advance ~0.63em
    const pad: f32 = 7;

    // file name across the top, shrunk to fit the width.
    const nlen: f32 = float(name.len);
    var nfs: f32 = clamp(h * 0.32, 11.0, 22.0);
    while (nfs > 10.0 and nlen * nfs * char_w > w - 2 * pad) {
        nfs -= 0.5;
    }
    const nw: f32 = nlen * nfs * char_w;
    canvas.text(.{ ccx - nw / 2, y0 + pad }, name, .{ .size = nfs, .color = tc });

    if (syms.len == 0) {
        return;
    }
    // key symbols below the name: one '|'-separated segment per line, as many
    // as the box height allows, each shrunk to fit the width.
    const sc: Color = .{ .r = tc.r, .g = tc.g, .b = tc.b, .a = 205 };
    const sfs0: f32 = clamp(h * 0.14, 9.0, 13.0);
    const line_h: f32 = sfs0 * 1.34;
    var yy: f32 = y0 + pad + nfs + 5;
    const bottom: f32 = y0 + h - pad * 0.5;
    var seg_start: usize = 0;
    var idx: usize = 0;
    while (idx <= syms.len) : (idx += 1) {
        const at_end: bool = (idx == syms.len);
        if (!at_end and syms[idx] != '|') {
            continue;
        }
        const seg: []const u8 = syms[seg_start..idx];
        seg_start = idx + 1;
        if (seg.len == 0 or yy + sfs0 > bottom) {
            continue;
        }
        var sfs: f32 = sfs0;
        const sl: f32 = float(seg.len);
        while (sfs > 8.0 and sl * sfs * char_w > w - 2 * pad) {
            sfs -= 0.5;
        }
        const sw: f32 = sl * sfs * char_w;
        canvas.text(.{ ccx - sw / 2, yy }, seg, .{ .size = sfs, .color = sc });
        yy += line_h;
    }
}

/// Freeform layout. Vertical position is governed by a SINGLE directed force:
/// each import edge pulls the importer above its dependency. With no level
/// scaffolding and no competing y-force, a file settles between the things it
/// depends on and the things that depend on it - so files that many others sit
/// on sink to the bottom, revealing what is truly fundamental. Horizontal
/// springs cluster coupled files; repulsion (x-only) is held back to the final
/// iterations to fan things out. Colour encodes in-degree (how many files
/// depend on this). Drawn with the reduced-edge skeleton to avoid a hairball.
fn renderForce(
    gpa: Allocator,
    io: std.Io,
    graph: ig.Graph,
    reduced: []ArrayList(u32),
    level: []const u32,
    max_level: u32,
    bw: []const f32,
    bh: []const f32,
) !void {
    const n: usize = graph.nodeCount();
    const fx: []f32 = try gpa.alloc(f32, n);
    const fy: []f32 = try gpa.alloc(f32, n);
    const dx: []f32 = try gpa.alloc(f32, n);
    const dy: []f32 = try gpa.alloc(f32, n);
    const conn: []bool = try gpa.alloc(bool, n);
    for (0..n) |i| {
        conn[i] = (graph.adj[i].items.len + graph.rev[i].items.len) > 0;
    }

    // in-degree drives colour: how many files depend on this one (fundamentality).
    const indeg: []f32 = try gpa.alloc(f32, n);
    var max_indeg: f32 = 1;
    for (0..n) |i| {
        indeg[i] = @floatFromInt(graph.rev[i].items.len);
        max_indeg = @max(max_indeg, indeg[i]);
    }

    // seed y by level (a valid ordering the springs then relax), x by golden angle.
    for (0..n) |i| {
        const lv: f32 = float(max_level - level[i]);
        fy[i] = lv * fd_ygap;
        const fi: f32 = float(i);
        fx[i] = @sin(fi * 2.39996323) * 320.0;
    }

    var t: f32 = fd_step0;
    var it: usize = 0;
    while (it < fd_iters) : (it += 1) {
        const rep_on: bool = (it + fd_rep_tail >= fd_iters);
        if (it + fd_rep_tail == fd_iters) {
            t = fd_rep_temp;
        }
        @memset(dx, 0);
        @memset(dy, 0);

        // x-only repulsion - only during the fan-out tail.
        if (rep_on) {
            for (0..n) |u| {
                for (u + 1..n) |v| {
                    if (!conn[u] or !conn[v]) {
                        continue;
                    }
                    var ddx: f32 = fx[u] - fx[v];
                    var ddy: f32 = fy[u] - fy[v];
                    var dist: f32 = @sqrt(ddx * ddx + ddy * ddy);
                    if (dist < 0.01) {
                        ddx = 0.1;
                        ddy = 0.13;
                        dist = 0.164;
                    }
                    const rep: f32 = (fd_k * fd_k) / dist;
                    const ux: f32 = ddx / dist;
                    dx[u] += ux * rep;
                    dx[v] -= ux * rep;
                }
            }
        }

        // horizontal spring: pull coupled files toward a shared column.
        for (0..n) |u| {
            for (graph.adj[u].items) |v| {
                const ddx: f32 = fx[u] - fx[v];
                dx[u] -= ddx * fd_attx;
                dx[v] += ddx * fd_attx;
            }
        }

        // directed vertical ordering: each importer must sit ABOVE its dep.
        // One-sided - only correct violations - so a dependency sinks below ALL
        // its importers (a universal leaf like zimrmath drops to the bottom)
        // instead of averaging to the middle of them.
        for (0..n) |u| {
            for (graph.adj[u].items) |v| {
                const sep: f32 = fy[v] - fy[u]; // want >= fd_ygap (v below u)
                if (sep < fd_ygap) {
                    const diff: f32 = (fd_ygap - sep) * fd_yhier;
                    dy[u] -= diff;
                    dy[v] += diff;
                }
            }
        }

        // horizontal compaction only (y is purely the directed ordering).
        for (0..n) |i| {
            if (!conn[i]) {
                continue;
            }
            dx[i] += (0.0 - fx[i]) * fd_gravx;
        }

        for (0..n) |i| {
            if (!conn[i]) {
                continue;
            }
            const d: f32 = @sqrt(dx[i] * dx[i] + dy[i] * dy[i]);
            if (d > 0.0001) {
                const s: f32 = @min(d, t) / d;
                fx[i] += dx[i] * s;
                fy[i] += dy[i] * s;
            }
        }
        t = @max(t * fd_cooling, fd_min_step);
    }

    // box overlap removal: separate along the axis of least penetration.
    var op: usize = 0;
    while (op < fd_overlap_passes) : (op += 1) {
        for (0..n) |u| {
            for (u + 1..n) |v| {
                if (!conn[u] or !conn[v]) {
                    continue;
                }
                const ox: f32 = (bw[u] + bw[v]) / 2 + 20 - @abs(fx[u] - fx[v]);
                const oy: f32 = (bh[u] + bh[v]) / 2 + 16 - @abs(fy[u] - fy[v]);
                if (ox > 0 and oy > 0) {
                    if (ox < oy) {
                        var sx: f32 = -1;
                        if (fx[u] >= fx[v]) {
                            sx = 1;
                        }
                        fx[u] += (ox / 2) * sx;
                        fx[v] -= (ox / 2) * sx;
                    } else {
                        var sy: f32 = -1;
                        if (fy[u] >= fy[v]) {
                            sy = 1;
                        }
                        fy[u] += (oy / 2) * sy;
                        fy[v] -= (oy / 2) * sy;
                    }
                }
            }
        }
    }

    // bounds of the connected cluster only.
    var minx: f32 = 1e9;
    var maxx: f32 = -1e9;
    var miny: f32 = 1e9;
    var maxy: f32 = -1e9;
    for (0..n) |i| {
        if (!conn[i]) {
            continue;
        }
        minx = @min(minx, fx[i] - bw[i] / 2);
        maxx = @max(maxx, fx[i] + bw[i] / 2);
        miny = @min(miny, fy[i] - bh[i] / 2);
        maxy = @max(maxy, fy[i] + bh[i] / 2);
    }
    const top_pad_f: f32 = 110;
    const shift_x: f32 = margin - minx;
    const shift_y: f32 = top_pad_f - miny;
    for (0..n) |i| {
        if (!conn[i]) {
            continue;
        }
        fx[i] += shift_x;
        fy[i] += shift_y;
    }
    const conn_w: f32 = maxx - minx;
    const conn_bottom: f32 = top_pad_f + (maxy - miny);

    // isolated (no-import) strip beneath the cluster.
    var iso_w: f32 = 0;
    var iso_h_max: f32 = 0;
    var iso_count: usize = 0;
    for (0..n) |i| {
        if (conn[i]) {
            continue;
        }
        iso_w += bw[i];
        iso_h_max = @max(iso_h_max, bh[i]);
        iso_count += 1;
    }
    if (iso_count > 1) {
        iso_w += float(iso_count - 1) * h_gap;
    }
    const content_w: f32 = @max(conn_w, iso_w);
    const canvas_w: f32 = content_w + margin * 2;
    const center_x: f32 = canvas_w / 2;
    const conn_center: f32 = margin + conn_w / 2;
    for (0..n) |i| {
        if (!conn[i]) {
            continue;
        }
        fx[i] += center_x - conn_center;
    }
    const iso_label_y: f32 = conn_bottom + iso_gap;
    const iso_row_cy: f32 = iso_label_y + 26 + iso_h_max / 2;
    var cursor: f32 = center_x - iso_w / 2;
    for (0..n) |i| {
        if (conn[i]) {
            continue;
        }
        fx[i] = cursor + bw[i] / 2;
        fy[i] = iso_row_cy;
        cursor += bw[i] + h_gap;
    }
    const canvas_h: f32 = iso_row_cy + iso_h_max / 2 + margin;

    const cw: i32 = @round(canvas_w);
    const ch: i32 = @round(canvas_h);
    var canvas: Canvas = try Canvas.init(gpa, cw, ch, .{
        .ss = 4,
        .background = .{ .r = 252, .g = 252, .b = 254, .a = 255 },
        .font_atlas_size = 128,
    });
    defer canvas.deinit();
    try canvas.useFont(@embedFile("dag_font.ttf"));

    // reduced-edge skeleton: importer (bottom) -> dependency (top), tinted by
    // the dependency's in-degree (so edges into fundamental files read warm).
    for (0..n) |u| {
        for (reduced[u].items) |v| {
            const tc: f32 = @sqrt(indeg[v] / max_indeg);
            const dc: Color = levelColor(tc);
            const ec: Color = .{ .r = dc.r, .g = dc.g, .b = dc.b, .a = 120 };
            const a: Vec2 = .{ fx[u], fy[u] + bh[u] / 2 };
            const b: Vec2 = .{ fx[v], fy[v] - bh[v] / 2 };
            canvas.line(a, b, .{ .color = ec, .thickness = 1.4 });
        }
    }
    // nodes coloured by in-degree (how many files depend on this one).
    for (0..n) |i| {
        const tc: f32 = @sqrt(indeg[i] / max_indeg);
        drawNode(&canvas, graph.names[i], symsFor(graph.names[i]), fx[i], fy[i], bw[i], bh[i], levelColor(tc));
    }
    if (iso_count > 0) {
        const div_col: Color = .{ .r = 214, .g = 216, .b = 224, .a = 255 };
        canvas.line(
            .{ margin, iso_label_y },
            .{ canvas_w - margin, iso_label_y },
            .{ .color = div_col, .thickness = 1.0 },
        );
        canvas.text(
            .{ margin, iso_label_y + 6 },
            "module-wired entries (nothing imports them):",
            .{ .size = 14, .color = .{ .r = 110, .g = 116, .b = 128, .a = 255 } },
        );
    }

    canvas.text(
        .{ margin, 40 },
        "zimr - src module dependency graph (freeform)",
        .{ .size = 30, .color = .{ .r = 24, .g = 26, .b = 34, .a = 255 } },
    );
    const sub: []const u8 = try allocPrint(gpa, "{d} modules  -  height = dependency depth (each file " ++
        "sits above its deps, below its dependees)  -  color/warmth = how many files depend on it " ++
        "(fundamental sinks to the bottom)", .{n});
    canvas.text(.{ margin, 84 }, sub, .{ .size = 15, .color = .{ .r = 92, .g = 98, .b = 110, .a = 255 } });

    try canvas.savePng(io, "src/notes/dag_force.png");
    var buf: [256]u8 = undefined;
    var ow: std.Io.File.Writer = std.Io.File.stdout().writer(io, &buf);
    try ow.interface.print("wrote src/notes/dag_force.png: {d}x{d}, {d} nodes, {d} reduced edges\n", .{
        cw,
        ch,
        n,
        ig.edgeCount(reduced),
    });
    try ow.interface.flush();
}

pub fn main() !void {
    const gpa: Allocator = std.heap.page_allocator;
    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io: std.Io = io_threaded.io();

    const out_path: []const u8 = "src/notes/dag.png";

    // --- graph + topology (shared analysis) ---
    const graph: ig.Graph = try ig.build(gpa, io, "src");
    const n: usize = graph.nodeCount();
    const level: []u32 = try ig.levels(gpa, graph);
    const max_level: u32 = ig.maxLevel(level);
    const reduced: []ArrayList(u32) = try ig.transitiveReduction(gpa, graph);

    // --- per-node line counts + box sizes (area ~ lines, in px) ---
    const lines: []usize = try gpa.alloc(usize, n);
    const bw: []f32 = try gpa.alloc(f32, n);
    const bh: []f32 = try gpa.alloc(f32, n);
    for (graph.names, 0..) |nm, i| {
        const path: []const u8 = try allocPrint(gpa, "src/{s}.zig", .{nm});
        lines[i] = try countLines(io, gpa, path);
        const area: f32 = float(lines[i]) * area_k;
        bw[i] = clamp(@sqrt(area * aspect), min_w, max_w);
        bh[i] = clamp(@sqrt(area / aspect), min_h, max_h);
    }

    // --- undirected neighbor lists (from reduced edges) ---
    const nbr: []ArrayList(u32) = try gpa.alloc(ArrayList(u32), n);
    for (0..n) |i| {
        nbr[i] = .empty;
    }
    for (0..n) |u| {
        for (reduced[u].items) |v| {
            try nbr[u].append(gpa, v);
            try nbr[v].append(gpa, @intCast(u));
        }
    }

    const cx: []f32 = try gpa.alloc(f32, n);
    const cy: []f32 = try gpa.alloc(f32, n);
    @memset(cx, 0);
    @memset(cy, 0);

    // --- connected nodes go into level rows; isolated go to a bottom strip ---
    const n_rows: usize = max_level + 1;
    const rows: []ArrayList(u32) = try gpa.alloc(ArrayList(u32), n_rows);
    for (0..n_rows) |i| {
        rows[i] = .empty;
    }
    var isolated: ArrayList(u32) = .empty;
    for (0..n) |i| {
        if (nbr[i].items.len == 0) {
            try isolated.append(gpa, @intCast(i));
        } else {
            const ri: usize = max_level - level[i]; // row 0 = top = max level
            try rows[ri].append(gpa, @intCast(i));
        }
    }

    // row Y bands (px), top -> bottom, skipping empty rows.
    var bottom_y: f32 = top_pad;
    {
        var y: f32 = top_pad;
        for (0..n_rows) |ri| {
            if (rows[ri].items.len == 0) {
                continue;
            }
            var rh: f32 = min_h;
            for (rows[ri].items) |id| {
                if (bh[id] > rh) {
                    rh = bh[id];
                }
            }
            const band_center: f32 = y + rh / 2;
            for (rows[ri].items) |id| {
                cy[id] = band_center;
            }
            y += rh + row_vgap;
            bottom_y = y;
        }
    }

    // initial pack + barycenter sweeps + relaxation (all about x=0).
    repack(rows, bw, cx);
    const key: []f32 = try gpa.alloc(f32, n);
    var sw: usize = 0;
    while (sw < sweeps) : (sw += 1) {
        for (0..n_rows) |ri| {
            for (rows[ri].items) |id| {
                if (nbr[id].items.len == 0) {
                    key[id] = cx[id];
                    continue;
                }
                var sum: f32 = 0;
                for (nbr[id].items) |m| {
                    sum += cx[m];
                }
                key[id] = sum / float(nbr[id].items.len);
            }
            std.mem.sort(u32, rows[ri].items, KeyCtx{ .key = key }, keyLess);
        }
        repack(rows, bw, cx);
    }
    var pass: usize = 0;
    while (pass < relax_passes) : (pass += 1) {
        for (0..n_rows) |ri| {
            for (rows[ri].items) |id| {
                if (nbr[id].items.len == 0) {
                    continue;
                }
                var sum: f32 = 0;
                for (nbr[id].items) |m| {
                    sum += cx[m];
                }
                cx[id] = sum / float(nbr[id].items.len);
            }
            if (pass % 2 == 0) {
                resolveLR(rows[ri].items, bw, cx);
            } else {
                resolveRL(rows[ri].items, bw, cx);
            }
        }
        // Recenter every row on a common axis (x=0) so the trunk stands
        // vertical instead of shearing sideways as rows drift.
        for (0..n_rows) |ri| {
            if (rows[ri].items.len == 0) {
                continue;
            }
            var mean: f32 = 0;
            for (rows[ri].items) |id| {
                mean += cx[id];
            }
            mean /= float(rows[ri].items.len);
            for (rows[ri].items) |id| {
                cx[id] -= mean;
            }
        }
    }

    // --- bounds of the connected graph ---
    var cmin_x: f32 = 1e9;
    var cmax_x: f32 = -1e9;
    for (0..n) |i| {
        if (nbr[i].items.len == 0) {
            continue;
        }
        if (cx[i] - bw[i] / 2 < cmin_x) {
            cmin_x = cx[i] - bw[i] / 2;
        }
        if (cx[i] + bw[i] / 2 > cmax_x) {
            cmax_x = cx[i] + bw[i] / 2;
        }
    }
    const conn_w: f32 = cmax_x - cmin_x;

    // --- isolated strip width (one centered row) ---
    var iso_w: f32 = 0;
    for (isolated.items, 0..) |id, i| {
        iso_w += bw[id];
        if (i + 1 < isolated.items.len) {
            iso_w += h_gap;
        }
    }

    const content_w: f32 = @max(@max(conn_w, iso_w), min_canvas_w);
    const canvas_w: f32 = content_w + margin * 2;
    const center_x: f32 = canvas_w / 2;

    // center the connected graph horizontally.
    const conn_center: f32 = (cmin_x + cmax_x) / 2;
    for (0..n) |i| {
        if (nbr[i].items.len != 0) {
            cx[i] += center_x - conn_center;
        }
    }

    // lay the isolated strip centered, just below the graph.
    var iso_h_max: f32 = min_h;
    for (isolated.items) |id| {
        if (bh[id] > iso_h_max) {
            iso_h_max = bh[id];
        }
    }
    const iso_label_y: f32 = bottom_y + iso_gap;
    const iso_row_cy: f32 = iso_label_y + 26 + iso_h_max / 2;
    {
        var cursor: f32 = center_x - iso_w / 2;
        for (isolated.items) |id| {
            cx[id] = cursor + bw[id] / 2;
            cy[id] = iso_row_cy;
            cursor += bw[id] + h_gap;
        }
    }

    const canvas_h: f32 = iso_row_cy + iso_h_max / 2 + margin;

    // --- render with zimr's own Canvas ---
    const cw: i32 = @round(canvas_w);
    const ch: i32 = @round(canvas_h);
    var canvas: Canvas = try Canvas.init(gpa, cw, ch, .{
        .ss = 4,
        .background = .{ .r = 252, .g = 252, .b = 254, .a = 255 },
        .font_atlas_size = 128,
    });
    defer canvas.deinit();
    try canvas.useFont(@embedFile("dag_font.ttf"));

    const max_lvl_f: f32 = float(max_level);

    // edges first (under nodes).
    for (0..n) |u| {
        const uc: Color = levelColor(float(level[u]) / max_lvl_f);
        const ec: Color = .{ .r = uc.r, .g = uc.g, .b = uc.b, .a = 140 };
        for (reduced[u].items) |v| {
            const a: Vec2 = .{ cx[u], cy[u] + bh[u] / 2 };
            const b: Vec2 = .{ cx[v], cy[v] - bh[v] / 2 };
            canvas.line(a, b, .{ .color = ec, .thickness = 1.7 });
        }
    }

    // connected nodes.
    for (0..n) |i| {
        if (nbr[i].items.len == 0) {
            continue;
        }
        const fill: Color = levelColor(float(level[i]) / max_lvl_f);
        drawNode(&canvas, graph.names[i], symsFor(graph.names[i]), cx[i], cy[i], bw[i], bh[i], fill);
    }

    // isolated strip: divider + label + nodes.
    const div_col: Color = .{ .r = 214, .g = 216, .b = 224, .a = 255 };
    canvas.line(
        .{ margin, iso_label_y },
        .{ canvas_w - margin, iso_label_y },
        .{ .color = div_col, .thickness = 1.0 },
    );
    canvas.text(
        .{ margin, iso_label_y + 6 },
        "module-wired foundations (no in-tree file imports):",
        .{ .size = 14, .color = .{ .r = 110, .g = 116, .b = 128, .a = 255 } },
    );
    for (isolated.items) |id| {
        const fill: Color = levelColor(float(level[id]) / max_lvl_f);
        drawNode(&canvas, graph.names[id], symsFor(graph.names[id]), cx[id], cy[id], bw[id], bh[id], fill);
    }

    // title block (ASCII only - the mono font lacks em-dash / arrows).
    canvas.text(
        .{ margin, 40 },
        "zimr - src module dependency graph",
        .{ .size = 30, .color = .{ .r = 24, .g = 26, .b = 34, .a = 255 } },
    );
    const sub: []const u8 = try allocPrint(gpa, "{d} modules  -  area ~ lines of code  -  " ++
        "color = DAG level (L0 foundations -> L{d})  -  " ++
        "transitive reduction ({d} edges)", .{ n, max_level, ig.edgeCount(reduced) });
    canvas.text(.{ margin, 84 }, sub, .{ .size = 15, .color = .{ .r = 92, .g = 98, .b = 110, .a = 255 } });

    try canvas.savePng(io, out_path);

    var buf: [256]u8 = undefined;
    var ow: std.Io.File.Writer = std.Io.File.stdout().writer(io, &buf);
    try ow.interface.print("wrote {s}: {d}x{d}, {d} nodes ({d} isolated), {d} edges\n", .{
        out_path, cw, ch, n, isolated.items.len, ig.edgeCount(reduced),
    });
    try ow.interface.flush();

    // second view: freeform force-directed layout (cluster structure).
    try renderForce(gpa, io, graph, reduced, level, max_level, bw, bh);
}
