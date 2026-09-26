//! doc_folds - the tutorials' code is GENERATED from the source, so it can't drift.
//!
//! Here's the problem this solves. A tutorial that shows code is making a promise: "this is what
//! the code looks like". The moment someone edits a function - fixes a comment, renames a
//! parameter, adds a line - a hand-copied quote of it starts lying. `doc_sync` catches the worst
//! of that (a quoted line that no longer exists anywhere), but it can't see a quote that's merely
//! INCOMPLETE: add a comment to a function and its old fold still passes, happily missing it.
//!
//! So instead of copying code into the page and hoping, the page says WHERE each block comes
//! from, and this tool fills the block in:
//!
//!     <details class="src-fold" data-src="src/robot_dance.zig" data-decl="pub const Tracker =">
//!       <summary><code>Tracker</code></summary><pre><code class="zig">...filled in...</code></pre>
//!     </details>
//!
//!     <pre data-src="src/robot_mocap_tutorial.zig" data-decl="test &quot;tutorial 2:">
//!       <code class="zig">...filled in...</code></pre>
//!
//! `data-decl` is how the declaration's first line starts (after its indentation), and it has to
//! pick out exactly one line in the file. When it can't - `pub const Data = struct {` appears once
//! per format in codecs.zig - add `data-in="pub const bvh ="` and the search starts after the first
//! line that starts with that. The block's content becomes the declaration exactly as it is in the
//! file: its doc comment, its first line, everything down to the line that closes it at the same
//! indentation - dedented, and HTML-escaped.
//!
//! There's one more generated region, the reference. Put these two markers in the page:
//!
//!     <!--doc-folds:ref src/robot_dance.zig src/robot_gym.zig-->
//!     <!--doc-folds:ref-end-->
//!
//! and everything between them becomes a table per file: every top-level `pub` declaration, with
//! the first sentence of its doc comment. So when somebody adds a public function, the tutorial's
//! reference grows by itself - and if nobody regenerated it, the gate says so.
//!
//! Two modes:
//!
//!     zig build doc-folds          --fix    rewrite every block from the source (you run this)
//!     zig build gate               --fix with the default -Dautofix, like `zig fmt`
//!     zig build gate -Dautofix=false  --check  fail on any difference, touch nothing (CI)
//!
//! The workflow that falls out of it: change the code however you like, run `zig build
//! doc-folds` (or just the gate), and the page follows. The only thing left to keep in sync by
//! hand is the prose around the code - which is exactly the part a tool can't write for you.

const std = @import("std");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const lastIndexOf = std.mem.lastIndexOf;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const trim = std.mem.trim;
const trimStart = std.mem.trimStart;
const allocPrint = std.fmt.allocPrint;
const splitScalar = std.mem.splitScalar;
const ArgIterator = std.process.Args.Iterator;

const File = std.Io.File;
const Dir = std.Io.Dir;
const Io = std.Io;

/// Plenty for any page or source file here (the biggest source is a few hundred kilobytes).
const read_limit: Io.Limit = .limited(64 << 20);

const Mode = enum { check, fix };

/// Everything the run found, so `main` can print one honest summary.
const Report = struct {
    blocks: usize = 0,
    regenerated: usize = 0,
    stale: usize = 0,
    references: usize = 0,
    errors: usize = 0,
};

/// A source file split into lines, read once and reused for every block that points at it.
const Source = struct {
    path: []const u8,
    lines: []const []const u8,
};

/// Where a declaration sits: its doc comment starts at `start`, it closes at `end` (both
/// inclusive), and its first line is indented by `indent` spaces.
const Span = struct {
    start: usize,
    end: usize,
    indent: usize,
};

const DeclError = error{ NotFound, Ambiguous, Unterminated };

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') {
        n += 1;
    }
    return n;
}

fn trimmed(line: []const u8) []const u8 {
    return trim(u8, line, " \t\r");
}

/// Split a file into lines, dropping any carriage returns so Windows checkouts behave.
fn splitLines(gpa: Allocator, text: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(gpa, trimStartCr(line));
    }
    return lines.items;
}

fn trimStartCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

/// The line a declaration starts on: the one whose text (after its indentation) starts with
/// `key`. With `scope`, the search starts after the first line starting with `scope` and takes
/// the first hit; without it, the hit has to be the only one in the file - two would mean the
/// page could silently switch to the wrong declaration one day.
fn findDecl(
    lines: []const []const u8,
    key: []const u8,
    scope: ?[]const u8,
) DeclError!usize {
    var from: usize = 0;
    if (scope) |s| {
        from = for (lines, 0..) |line, i| {
            if (startsWith(u8, trimmed(line), s)) {
                break i + 1;
            }
        } else return error.NotFound;
    }
    var found: ?usize = null;
    for (lines[from..], from..) |line, i| {
        if (!startsWith(u8, trimStart(u8, line, " \t"), key)) {
            continue;
        }
        if (scope != null) {
            return i;
        }
        if (found != null) {
            return error.Ambiguous;
        }
        found = i;
    }
    return found orelse error.NotFound;
}

/// Grow a declaration's first line into its whole span: up through its doc comment, and down to
/// the line that closes it at the same indentation (`}`, `};` or `},`). A one-line declaration
/// (`pub const x: f32 = 1.0;`) is just that line.
fn spanOf(lines: []const []const u8, first: usize) DeclError!Span {
    const indent: usize = indentOf(lines[first]);
    var start: usize = first;
    while (start > 0 and startsWith(u8, trimmed(lines[start - 1]), "///")) {
        start -= 1;
    }
    // A declaration that both opens and closes on one line - `pub const x = [_]u32{ 1, 2 };` -
    // ends with a semicolon AND contains a brace. Counting the braces tells the two apart; taking
    // the brace alone as proof of a block would swallow whatever declaration came next.
    const head: []const u8 = trimmed(lines[first]);
    var depth: isize = 0;
    for (head) |c| {
        depth += switch (c) {
            '{', '(', '[' => 1,
            '}', ')', ']' => -1,
            else => 0,
        };
    }
    if (endsWith(u8, head, ";") and depth <= 0) {
        return .{ .start = start, .end = first, .indent = indent };
    }
    var k: usize = first + 1;
    while (k < lines.len) : (k += 1) {
        const t: []const u8 = trimmed(lines[k]);
        const closes: bool = eql(u8, t, "}") or eql(u8, t, "};") or eql(u8, t, "},");
        if (closes and indentOf(lines[k]) == indent) {
            return .{ .start = start, .end = k, .indent = indent };
        }
    }
    return error.Unterminated;
}

/// The declaration as a block shows it: dedented by its first line's indentation, lines joined
/// with newlines, no trailing newline, and escaped for HTML.
fn render(gpa: Allocator, lines: []const []const u8, span: Span) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (lines[span.start .. span.end + 1], 0..) |line, i| {
        if (i > 0) {
            try out.append(gpa, '\n');
        }
        const body: []const u8 = if (indentOf(line) >= span.indent) line[span.indent..] else trimStart(u8, line, " ");
        try appendEscaped(gpa, &out, body);
    }
    return out.items;
}

fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            else => try out.append(gpa, c),
        }
    }
}

/// An attribute's value from a tag, un-escaped (`&quot;` and friends), or null when absent.
fn attribute(gpa: Allocator, tag: []const u8, name: []const u8) !?[]const u8 {
    const needle: []u8 = try allocPrint(gpa, " {s}=\"", .{name});
    const at: usize = indexOf(u8, tag, needle) orelse return null;
    const from: usize = at + needle.len;
    const to: usize = indexOfPos(u8, tag, from, "\"") orelse return null;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = from;
    while (i < to) {
        const entities = [_][2][]const u8{
            .{ "&quot;", "\"" }, .{ "&amp;", "&" }, .{ "&lt;", "<" }, .{ "&gt;", ">" }, .{ "&#39;", "'" },
        };
        const hit: ?[2][]const u8 = for (entities) |e| {
            if (startsWith(u8, tag[i..to], e[0])) {
                break e;
            }
        } else null;
        if (hit) |e| {
            try out.appendSlice(gpa, e[1]);
            i += e[0].len;
        } else {
            try out.append(gpa, tag[i]);
            i += 1;
        }
    }
    return out.items;
}

/// Read each source once; blocks pointing at the same file share it.
fn sourceFor(
    gpa: Allocator,
    io: Io,
    cache: *std.ArrayList(Source),
    path: []const u8,
) !Source {
    for (cache.items) |s| {
        if (eql(u8, s.path, path)) {
            return s;
        }
    }
    const text: []u8 = try Dir.cwd().readFileAlloc(io, path, gpa, read_limit);
    const source: Source = .{ .path = path, .lines = try splitLines(gpa, text) };
    try cache.append(gpa, source);
    return source;
}

fn say(io: Io, gpa: Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg: []u8 = try allocPrint(gpa, fmt, args);
    try File.stderr().writeStreamingAll(io, msg);
}

/// The first sentence of a declaration's doc comment, ready for a table cell: backticks become
/// `<code>`, decoration (`──`, `★`) is dropped, and HTML is escaped. "—" when there's no doc.
fn summary(gpa: Allocator, lines: []const []const u8, span: Span, first: usize) ![]u8 {
    var text: std.ArrayList(u8) = .empty;
    for (lines[span.start..first]) |line| {
        var t: []const u8 = trimmed(line);
        t = trimmed(t[3..]);
        if (t.len == 0) {
            if (text.items.len > 0) {
                break;
            }
            continue;
        }
        if (startsWith(u8, t, "──") or startsWith(u8, t, "★")) {
            if (text.items.len > 0) {
                break;
            }
            continue;
        }
        if (text.items.len > 0) {
            try text.append(gpa, ' ');
        }
        try text.appendSlice(gpa, t);
    }
    if (text.items.len == 0) {
        return try gpa.dupe(u8, "—");
    }
    // Cut at the first sentence end.
    var cut: usize = text.items.len;
    var i: usize = 0;
    while (i + 1 < text.items.len) : (i += 1) {
        if (text.items[i] == '.' and text.items[i + 1] == ' ') {
            cut = i + 1;
            break;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    var in_code: bool = false;
    for (text.items[0..cut]) |c| {
        if (c == '`') {
            try out.appendSlice(gpa, if (in_code) "</code>" else "<code>");
            in_code = !in_code;
            continue;
        }
        try appendEscaped(gpa, &out, &.{c});
    }
    if (in_code) {
        try out.appendSlice(gpa, "</code>");
    }
    return out.items;
}

/// The name a top-level `pub fn` / `pub const` declares, or null for anything else.
fn declName(line: []const u8) ?[]const u8 {
    const rest: []const u8 = if (startsWith(u8, line, "pub fn "))
        line["pub fn ".len..]
    else if (startsWith(u8, line, "pub const "))
        line["pub const ".len..]
    else
        return null;
    var n: usize = 0;
    while (n < rest.len and (std.ascii.isAlphanumeric(rest[n]) or rest[n] == '_')) {
        n += 1;
    }
    return if (n == 0) null else rest[0..n];
}

/// The generated reference: a table per file of every top-level `pub` declaration.
fn reference(
    gpa: Allocator,
    io: Io,
    cache: *std.ArrayList(Source),
    files: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var it: std.mem.TokenIterator(u8, .scalar) = std.mem.tokenizeScalar(u8, files, ' ');
    while (it.next()) |path| {
        const source: Source = try sourceFor(gpa, io, cache, path);
        const head: []u8 = try allocPrint(
            gpa,
            "\n<p><strong><code>{s}</code></strong></p>\n<table>\n<tr><th>declaration</th><th>what it is</th></tr>\n",
            .{path},
        );
        try out.appendSlice(gpa, head);
        for (source.lines, 0..) |line, i| {
            const name: []const u8 = declName(line) orelse continue;
            const span: Span = try spanOf(source.lines, i);
            const row: []u8 = try allocPrint(
                gpa,
                "<tr><td><code>{s}</code></td><td>{s}</td></tr>\n",
                .{ name, try summary(gpa, source.lines, span, i) },
            );
            try out.appendSlice(gpa, row);
        }
        try out.appendSlice(gpa, "</table>\n");
    }
    return out.items;
}

/// Regenerate (or check) one page. Returns the page's new text; `rep` says what happened.
fn processPage(
    gpa: Allocator,
    io: Io,
    page: []const u8,
    text: []const u8,
    rep: *Report,
) ![]u8 {
    var cache: std.ArrayList(Source) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var pos: usize = 0;
    while (indexOfPos(u8, text, pos, " data-src=\"")) |attr_at| {
        const tag_start: usize = lastIndexOf(u8, text[0..attr_at], "<") orelse break;
        const tag_end: usize = indexOfPos(u8, text, attr_at, ">") orelse break;
        const tag: []const u8 = text[tag_start .. tag_end + 1];
        const open: []const u8 = "<code class=\"zig\">";
        const body_start: usize = (indexOfPos(u8, text, tag_end, open) orelse break) + open.len;
        const body_end: usize = indexOfPos(u8, text, body_start, "</code>") orelse break;
        rep.blocks += 1;
        const src: []const u8 = (try attribute(gpa, tag, "data-src")).?;
        // The key is compared against the line with its indentation already stripped, so a key
        // written WITH indentation (easy to do when copying a nested declaration out of a file)
        // means the same thing. Trim it rather than report NotFound for a difference that makes
        // no difference.
        const key: []const u8 = trimmed((try attribute(gpa, tag, "data-decl")) orelse "");
        const scope: ?[]const u8 = try attribute(gpa, tag, "data-in");
        const current: []const u8 = text[body_start..body_end];
        try out.appendSlice(gpa, text[pos..body_start]);
        pos = body_end;
        const source: Source = sourceFor(gpa, io, &cache, src) catch |err| {
            try say(io, gpa, "{s}: block `{s}`: cannot read {s}: {s}\n", .{ page, key, src, @errorName(err) });
            rep.errors += 1;
            try out.appendSlice(gpa, current);
            continue;
        };
        const first: usize = findDecl(source.lines, key, scope) catch |err| {
            try say(io, gpa, "{s}: block `{s}` in {s}: {s}\n", .{ page, key, src, @errorName(err) });
            rep.errors += 1;
            try out.appendSlice(gpa, current);
            continue;
        };
        const span: Span = try spanOf(source.lines, first);
        const expected: []u8 = try render(gpa, source.lines, span);
        if (eql(u8, current, expected)) {
            try out.appendSlice(gpa, current);
            continue;
        }
        rep.stale += 1;
        try say(io, gpa, "{s}: `{s}` ({s}) differs from the source\n", .{ page, key, src });
        try out.appendSlice(gpa, expected);
        rep.regenerated += 1;
    }
    try out.appendSlice(gpa, text[pos..]);

    // The reference region, if the page has one.
    const begin_marker: []const u8 = "<!--doc-folds:ref ";
    const end_marker: []const u8 = "<!--doc-folds:ref-end-->";
    const joined: []u8 = out.items;
    if (indexOf(u8, joined, begin_marker)) |b| {
        const files_end: usize = indexOfPos(u8, joined, b, "-->") orelse return joined;
        const files: []const u8 = joined[b + begin_marker.len .. files_end];
        const region_start: usize = files_end + "-->".len;
        const region_end: usize = indexOfPos(u8, joined, region_start, end_marker) orelse return joined;
        const generated: []u8 = try reference(gpa, io, &cache, files);
        rep.references += 1;
        if (!eql(u8, joined[region_start..region_end], generated)) {
            rep.stale += 1;
            try say(io, gpa, "{s}: the reference is out of date\n", .{page});
            var rebuilt: std.ArrayList(u8) = .empty;
            try rebuilt.appendSlice(gpa, joined[0..region_start]);
            try rebuilt.appendSlice(gpa, generated);
            try rebuilt.appendSlice(gpa, joined[region_end..]);
            rep.regenerated += 1;
            return rebuilt.items;
        }
    }
    return joined;
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: Io = init.io;

    var mode: Mode = .check;
    var pages: std.ArrayList([]const u8) = .empty;
    var args: ArgIterator = try ArgIterator.initAllocator(init.minimal.args, gpa);
    _ = args.skip();
    while (args.next()) |arg| {
        if (eql(u8, arg, "--fix")) {
            mode = .fix;
        } else if (eql(u8, arg, "--check")) {
            mode = .check;
        } else {
            try pages.append(gpa, arg);
        }
    }

    var failed: bool = false;
    for (pages.items) |page| {
        var rep: Report = .{};
        const text: []u8 = try Dir.cwd().readFileAlloc(io, page, gpa, read_limit);
        const updated: []u8 = try processPage(gpa, io, page, text, &rep);
        if (mode == .fix and !eql(u8, text, updated)) {
            try Dir.cwd().writeFile(io, .{ .sub_path = page, .data = updated });
        }
        const verb: []const u8 = if (mode == .fix) "regenerated" else "stale";
        const msg: []u8 = try allocPrint(
            gpa,
            "{s}: {d} code block(s), {d} {s}, {d} reference region(s), {d} error(s)\n",
            .{ page, rep.blocks, if (mode == .fix) rep.regenerated else rep.stale, verb, rep.references, rep.errors },
        );
        try File.stdout().writeStreamingAll(io, msg);
        if (rep.errors > 0 or (mode == .check and rep.stale > 0)) {
            failed = true;
        }
    }
    if (failed) {
        const tail: []const u8 =
            "doc-folds FAILED: the tutorial's code no longer matches the source.\n" ++
            "Run `zig build doc-folds` to regenerate it; fix any block whose data-decl no longer\n" ++
            "finds its declaration (renamed? add data-in= to disambiguate).\n";
        try File.stderr().writeStreamingAll(io, tail);
        std.process.exit(1);
    }
}
