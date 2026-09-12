//! doc_sync — check that the code shown in a tutorial is the code that actually ships.
//!
//! A tutorial that quotes drifted source is worse than no tutorial: it teaches a version
//! of the code that does not exist, and it is confidently wrong. This already happened
//! once — `robots.html` quoted `Inertia.translate`'s doc comment, the comment was
//! corrected in the source, and the page kept teaching the old (backwards) description
//! until a one-off script caught it. This tool is that script, made permanent.
//!
//!     zig build doc-sync
//!
//! It extracts every `<pre><code>...</code></pre>` block from an HTML file, un-escapes the
//! entities, and requires each line to appear verbatim (ignoring indentation) somewhere in
//! the paired source file.
//!
//! ESCAPE HATCHES, because not every block is a quote:
//!   * `<pre class="bad">`    — deliberately WRONG code, shown to explain a bug.
//!   * `<pre class="sketch">` — illustrative usage that is not literally in the source.
//!   * a line ending in `...` — an elision.
//! Anything else must match, which is the point: the default is "this is real code".
//!
//! Zig rather than Python because the house rule is that tooling is Zig (the analysis and
//! codegen purge is complete). `scripts/robot_oracle.py` stays Python only because it
//! needs the MuJoCo package.

const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const trim = std.mem.trim;
const allocPrint = std.fmt.allocPrint;

const File = std.Io.File;

/// The doc/source pairs this checks. Add a row when a tutorial starts quoting code.
/// ★ SEVERAL SOURCES PER DOC, because a tutorial that covers a subsystem quotes the whole
/// subsystem. A line passes if it appears in ANY of them — the alternative, one pair per
/// source, would check every block against every file and report the other file's blocks as
/// drifted.
const Pair = struct { doc: []const u8, srcs: []const []const u8 };
const pairs = [_]Pair{
    .{
        .doc = "src/notes/tutorials/robots.html",
        .srcs = &.{
            "src/robot.zig",
            "src/robot_mpc.zig",
        },
    },
};

/// Replace the HTML entities a code block can legally contain. Deliberately not a general
/// un-escaper: if a block needs anything more exotic, that is worth noticing by hand.
fn unescape(gpa: Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < html.len) {
        if (html[i] == '&') {
            const rest: []const u8 = html[i..];
            const subs = [_]struct { from: []const u8, to: u8 }{
                .{ .from = "&amp;", .to = '&' },
                .{ .from = "&lt;", .to = '<' },
                .{ .from = "&gt;", .to = '>' },
                .{ .from = "&quot;", .to = '"' },
                .{ .from = "&#39;", .to = '\'' },
            };
            var matched: bool = false;
            for (subs) |sub| {
                if (startsWith(u8, rest, sub.from)) {
                    try out.append(gpa, sub.to);
                    i += sub.from.len;
                    matched = true;
                    break;
                }
            }
            if (matched) {
                continue;
            }
        }
        try out.append(gpa, html[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

/// True when `needle` appears in `haystack` as a whole line, ignoring indentation. Line
/// granularity is the right unit: it survives reflowing and reordering, and it still
/// catches every edit to the code itself.
fn hasLine(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |line| {
        if (eql(u8, trim(u8, line, " \t\r"), needle)) {
            return true;
        }
    }
    return false;
}

/// A `<pre ...>` opening tag carries a class that exempts the block from checking.
fn isExempt(open_tag: []const u8) bool {
    return indexOf(u8, open_tag, "class=\"bad\"") != null or
        indexOf(u8, open_tag, "class=\"sketch\"") != null;
}

const Report = struct { checked: u32, drifted: u32, exempt: u32 };

fn checkPair(gpa: Allocator, io: std.Io, pair: Pair) !Report {
    const limit: std.Io.Limit = .limited(64 * 1024 * 1024);
    const doc: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, pair.doc, gpa, limit);
    defer gpa.free(doc);
    var sources: std.ArrayList([]u8) = .empty;
    defer {
        for (sources.items) |text| {
            gpa.free(text);
        }
        sources.deinit(gpa);
    }
    for (pair.srcs) |path| {
        const text: []u8 = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, limit);
        try sources.append(gpa, text);
    }

    var rep: Report = .{ .checked = 0, .drifted = 0, .exempt = 0 };
    var scan: usize = 0;
    while (indexOfPos(u8, doc, scan, "<pre")) |open| {
        const tag_end: usize = indexOfPos(u8, doc, open, ">") orelse break;
        const body_start: usize = tag_end + 1;
        const close: usize = indexOfPos(u8, doc, body_start, "</pre>") orelse break;
        scan = close + "</pre>".len;

        if (isExempt(doc[open..tag_end])) {
            rep.exempt += 1;
            continue;
        }

        // Strip the inner <code> wrapper if present.
        var body: []const u8 = doc[body_start..close];
        if (startsWith(u8, body, "<code>")) {
            body = body["<code>".len..];
        }
        if (endsWith(u8, body, "</code>")) {
            body = body[0 .. body.len - "</code>".len];
        }

        const plain: []u8 = try unescape(gpa, body);
        defer gpa.free(plain);

        var lines = std.mem.splitScalar(u8, plain, '\n');
        while (lines.next()) |raw| {
            const line: []const u8 = trim(u8, raw, " \t\r");
            if (line.len == 0 or endsWith(u8, line, "...")) {
                continue;
            }
            rep.checked += 1;
            var found: bool = false;
            for (sources.items) |text| {
                if (hasLine(text, line)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                rep.drifted += 1;
                const msg: []u8 = try allocPrint(
                    gpa,
                    "{s}: line not found in any source:\n    {s}\n",
                    .{ pair.doc, line },
                );
                defer gpa.free(msg);
                try File.stderr().writeStreamingAll(io, msg);
            }
        }
    }
    return rep;
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();

    var failed: bool = false;
    for (pairs) |pair| {
        const rep: Report = try checkPair(gpa, init.io, pair);
        const msg: []u8 = try allocPrint(
            gpa,
            "{s}: {d} lines checked, {d} exempt block(s), {d} drifted\n",
            .{ pair.doc, rep.checked, rep.exempt, rep.drifted },
        );
        try File.stdout().writeStreamingAll(init.io, msg);
        if (rep.drifted > 0) {
            failed = true;
        }
    }
    if (failed) {
        const tail: []const u8 =
            "doc-sync FAILED: the tutorial teaches code that no longer exists.\n" ++
            "Fix the doc, or mark the block <pre class=\"sketch\"> if it is illustrative.\n";
        try File.stderr().writeStreamingAll(init.io, tail);
        std.process.exit(1);
    }
}
