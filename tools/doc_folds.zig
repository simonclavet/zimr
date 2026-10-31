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
//! And the section numbers. A page that numbers its headings - `<h2 id="supertrack">11. SuperTrack`,
//! `<h3 id="idea">11.2 The idea` - gets every number from the heading's place in the page, and every
//! link to a numbered heading whose text is only its number - `<a href="#idea">11.2</a>`, or the same
//! with a section sign before it - shows that heading's number (`numberSections`). Sections can then
//! be moved, added and removed freely: the numbers and every reference to them follow. And the page's
//! contents, when it asks for it - between `<!--doc-folds:toc-->` and `<!--doc-folds:toc-end-->` - is
//! the list of its numbered chapters, each with its numbered sections (`tableOfContents`).
//!
//! Two modes:
//!
//!     zig build doc-folds   --fix    rewrite every block from the source, printing each page's diff
//!     zig build lint-fix    --fix    the same, after the linter's fixes - the one step that rewrites sources
//!     zig build gate        --check  fail on any difference, touch nothing - so does `tripwires`
//!
//! The workflow that falls out of it: change the code however you like, run `zig build lint-fix`
//! (or `zig build doc-folds`), and the page follows - every regenerated block printed as a diff,
//! as `zig build lint-fix` prints every file it rewrites. The only thing left to keep in sync by hand
//! is the prose around the code - which is exactly the part a tool can't write for you.

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const cli = @import("cli");
const line_diff = @import("line_diff.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const indexOfPos = std.mem.indexOfPos;
const lastIndexOf = std.mem.lastIndexOf;
const startsWith = std.mem.startsWith;
const endsWith = std.mem.endsWith;
const trim = std.mem.trim;
const trimStart = std.mem.trimStart;
const trimEnd = std.mem.trimEnd;
const allocPrint = std.fmt.allocPrint;
const splitScalar = std.mem.splitScalar;

const Io = std.Io;
const ArrayList = std.ArrayList;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const File = Io.File;
const Dir = Io.Dir;

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

fn trimStartCr(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') {
        return line[0 .. line.len - 1];
    }
    return line;
}

/// Split a file into lines, dropping any carriage returns so Windows checkouts behave.
fn splitLines(gpa: Allocator, text: []const u8) ![]const []const u8 {
    var lines: ArrayList([]const u8) = .empty;
    var it: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try lines.append(gpa, trimStartCr(line));
    }
    return lines.items;
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

fn appendEscaped(gpa: Allocator, out: *ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            else => try out.append(gpa, c),
        }
    }
}

/// The declaration as a block shows it: dedented by its first line's indentation, lines joined
/// with newlines, no trailing newline, and escaped for HTML.
fn render(gpa: Allocator, lines: []const []const u8, span: Span) ![]u8 {
    var out: ArrayList(u8) = .empty;
    for (lines[span.start .. span.end + 1], 0..) |line, i| {
        if (i > 0) {
            try out.append(gpa, '\n');
        }
        const body: []const u8 = if (indentOf(line) >= span.indent) line[span.indent..] else trimStart(u8, line, " ");
        try appendEscaped(gpa, &out, body);
    }
    return out.items;
}

/// An attribute's value from a tag, un-escaped (`&quot;` and friends), or null when absent.
fn attribute(gpa: Allocator, tag: []const u8, name: []const u8) !?[]const u8 {
    const needle: []u8 = try allocPrint(gpa, " {s}=\"", .{name});
    const at: usize = indexOf(u8, tag, needle) orelse return null;
    const from: usize = at + needle.len;
    const to: usize = indexOfPos(u8, tag, from, "\"") orelse return null;
    var out: ArrayList(u8) = .empty;
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
    cache: *ArrayList(Source),
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
/// `<code>`, decoration (`--`, `*`) is dropped, and HTML is escaped. "-" when there's no doc.
fn summary(gpa: Allocator, lines: []const []const u8, span: Span, first: usize) ![]u8 {
    var text: ArrayList(u8) = .empty;
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
    var out: ArrayList(u8) = .empty;
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
    cache: *ArrayList(Source),
    files: []const u8,
) ![]u8 {
    var out: ArrayList(u8) = .empty;
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

/// The reference region of `text`, if the page has one, regenerated (this file's head).
fn referenceRegion(
    gpa: Allocator,
    io: Io,
    page: []const u8,
    cache: *ArrayList(Source),
    text: []u8,
    rep: *Report,
) ![]u8 {
    const begin_marker: []const u8 = "<!--doc-folds:ref ";
    const end_marker: []const u8 = "<!--doc-folds:ref-end-->";
    const b: usize = indexOf(u8, text, begin_marker) orelse return text;
    const files_end: usize = indexOfPos(u8, text, b, "-->") orelse return text;
    const files: []const u8 = text[b + begin_marker.len .. files_end];
    const region_start: usize = files_end + "-->".len;
    const region_end: usize = indexOfPos(u8, text, region_start, end_marker) orelse return text;
    const generated: []u8 = try reference(gpa, io, cache, files);
    rep.references += 1;
    if (eql(u8, text[region_start..region_end], generated)) {
        return text;
    }
    rep.stale += 1;
    try say(io, gpa, "{s}: the reference is out of date\n", .{page});
    var rebuilt: ArrayList(u8) = .empty;
    try rebuilt.appendSlice(gpa, text[0..region_start]);
    try rebuilt.appendSlice(gpa, generated);
    try rebuilt.appendSlice(gpa, text[region_end..]);
    rep.regenerated += 1;
    return rebuilt.items;
}

/// How many decimal digits `text` has in a row from `start`.
fn digitCount(text: []const u8, start: usize) usize {
    var end: usize = start;
    while (end < text.len and text[end] >= '0' and text[end] <= '9') : (end += 1) {}
    return end - start;
}

/// Whether `text` is a section number and nothing else: `11` or `11.4`.
fn isSectionNumber(text: []const u8) bool {
    const whole: usize = digitCount(text, 0);
    if (whole == 0) {
        return false;
    }
    if (whole == text.len) {
        return true;
    }
    if (text[whole] != '.') {
        return false;
    }
    const part: usize = digitCount(text, whole + 1);
    return part > 0 and whole + 1 + part == text.len;
}

/// How long the number at the start of a heading's text is - `11. ` for a chapter, `11.4 ` for a section, the space
/// included - or null when it carries none.
fn headingNumberLength(title: []const u8, is_chapter: bool) ?usize {
    const whole: usize = digitCount(title, 0);
    if (whole == 0) {
        return null;
    }
    if (is_chapter) {
        const has_point_and_space: bool = startsWith(u8, title[whole..], ". ");
        return if (has_point_and_space) whole + 2 else null;
    }
    if (!startsWith(u8, title[whole..], ".")) {
        return null;
    }
    const part: usize = digitCount(title, whole + 1);
    const end: usize = whole + 1 + part;
    const has_space: bool = part > 0 and startsWith(u8, title[end..], " ");
    return if (has_space) end + 1 else null;
}

/// Whether `before` - a page up to an `href="#` - ends with a link's opening, `<a` and whitespace (a space, or a line
/// break where the link wraps).
fn isLinkStart(before: []const u8) bool {
    const opening: []const u8 = trimEnd(u8, before, " \t\r\n");
    const has_space: bool = opening.len < before.len;
    return has_space and endsWith(u8, opening, "<a");
}

/// Where the next chapter or section heading starts, from `pos` on, and which it is - or null when there are no more.
fn nextHeading(text: []const u8, pos: usize) ?struct { at: usize, is_chapter: bool } {
    const chapter_at: ?usize = indexOfPos(u8, text, pos, "<h2 id=\"");
    const section_at: ?usize = indexOfPos(u8, text, pos, "<h3 id=\"");
    if (chapter_at == null and section_at == null) {
        return null;
    }
    const is_chapter: bool = section_at == null or (chapter_at != null and chapter_at.? < section_at.?);
    const at: usize = if (is_chapter) chapter_at.? else section_at.?;
    return .{ .at = at, .is_chapter = is_chapter };
}

/// A page with its section numbers generated, and how many numbers changed.
const Numbered = struct {
    text: []u8,
    count: usize,
};

/// THE SECTION NUMBERS (this file's head). Two passes over the page:
///
///     headings   every `<h2 id="...">` whose text starts with a number - `11. ` - is the next CHAPTER, and every
///                `<h3 id="...">` whose text starts with one - `11.4 ` - the next SECTION of its chapter; each gets
///                the number its place gives it. A heading without a number is left as it is, and counts for nothing.
///     links      every `<a href="#id">` straight to a numbered heading whose whole text is a number - `11.4`,
///                with or without a section sign before it - shows that heading's number. A link with any other
///                text is left as it is.
///
/// Memory: `gpa`, the caller's (an arena in this tool).
fn numberSections(gpa: Allocator, text: []const u8) !Numbered {
    var numbers: std.StringHashMapUnmanaged([]const u8) = .empty;
    var changed: usize = 0;
    // The headings, in the page's order.
    var headed: ArrayList(u8) = .empty;
    var pos: usize = 0;
    var chapter: usize = 0;
    var section: usize = 0;
    while (nextHeading(text, pos)) |heading| {
        const id_start: usize = heading.at + "<h2 id=\"".len;
        const id_end: usize = indexOfPos(u8, text, id_start, "\"") orelse break;
        const tag_end: usize = indexOfPos(u8, text, id_end, ">") orelse break;
        const title_start: usize = tag_end + 1;
        try headed.appendSlice(gpa, text[pos..title_start]);
        pos = title_start;
        const prefix_length: usize = headingNumberLength(text[title_start..], heading.is_chapter) orelse continue;
        if (!heading.is_chapter and chapter == 0) {
            continue;
        }
        if (heading.is_chapter) {
            chapter += 1;
            section = 0;
        } else {
            section += 1;
        }
        const number: []const u8 = if (heading.is_chapter)
            try allocPrint(gpa, "{d}", .{chapter})
        else
            try allocPrint(gpa, "{d}.{d}", .{ chapter, section });
        try numbers.put(gpa, text[id_start..id_end], number);
        const prefix: []const u8 = if (heading.is_chapter)
            try allocPrint(gpa, "{s}. ", .{number})
        else
            try allocPrint(gpa, "{s} ", .{number});
        const old_prefix: []const u8 = text[title_start .. title_start + prefix_length];
        changed += @intFromBool(!eql(u8, old_prefix, prefix));
        try headed.appendSlice(gpa, prefix);
        pos = title_start + prefix_length;
    }
    try headed.appendSlice(gpa, text[pos..]);
    // The links to them: `<a`, any whitespace - a link may wrap there - then `href="#`.
    const page: []const u8 = headed.items;
    var linked: ArrayList(u8) = .empty;
    const target_open: []const u8 = "href=\"#";
    const section_sign: []const u8 = "\u{a7}";
    pos = 0;
    while (indexOfPos(u8, page, pos, target_open)) |target_at| {
        const id_start: usize = target_at + target_open.len;
        const opens_a_link: bool = isLinkStart(page[0..target_at]);
        if (!opens_a_link) {
            try linked.appendSlice(gpa, page[pos..id_start]);
            pos = id_start;
            continue;
        }
        const id_end: usize = indexOfPos(u8, page, id_start, "\"") orelse break;
        const label_start: usize = id_end + "\">".len;
        const opens_directly: bool = startsWith(u8, page[id_end..], "\">");
        const label_end: usize = indexOfPos(u8, page, id_end, "</a>") orelse break;
        const number: ?[]const u8 = numbers.get(page[id_start..id_end]);
        const label: []const u8 = if (opens_directly) page[label_start..label_end] else "";
        const has_sign: bool = startsWith(u8, label, section_sign);
        const label_number: []const u8 = if (has_sign) label[section_sign.len..] else label;
        if (!opens_directly or number == null or !isSectionNumber(label_number)) {
            try linked.appendSlice(gpa, page[pos..id_end]);
            pos = id_end;
            continue;
        }
        try linked.appendSlice(gpa, page[pos..label_start]);
        if (has_sign) {
            try linked.appendSlice(gpa, section_sign);
        }
        try linked.appendSlice(gpa, number.?);
        changed += @intFromBool(!eql(u8, label_number, number.?));
        pos = label_end;
    }
    try linked.appendSlice(gpa, page[pos..]);
    const result: Numbered = .{ .text = linked.items, .count = changed };
    return result;
}

/// THE CONTENTS (this file's head): the region between `<!--doc-folds:toc-->` and `<!--doc-folds:toc-end-->`, when
/// the page has one, rewritten as the list of its numbered chapters, each with its numbered sections nested in it -
/// every entry a link to its heading, titled by the heading's text without its number:
///
///     <ol>
///     <li><a href="#what">What this is</a>
///       <ol>
///       <li><a href="#problem">The problem</a></li>
///       </ol></li>
///     <li><a href="#ref">Reference</a></li>
///     </ol>
///
/// The count is 1 when the region changed, 0 otherwise. Memory: `gpa`, the caller's (an arena in this tool).
fn tableOfContents(gpa: Allocator, text: []u8) !Numbered {
    const begin_marker: []const u8 = "<!--doc-folds:toc-->";
    const end_marker: []const u8 = "<!--doc-folds:toc-end-->";
    const unchanged: Numbered = .{ .text = text, .count = 0 };
    const begin: usize = indexOf(u8, text, begin_marker) orelse return unchanged;
    const region_start: usize = begin + begin_marker.len;
    const region_end: usize = indexOfPos(u8, text, region_start, end_marker) orelse return unchanged;
    var list: ArrayList(u8) = .empty;
    try list.appendSlice(gpa, "\n<ol>\n");
    var chapter_open: bool = false;
    var sections_open: bool = false;
    var pos: usize = 0;
    while (nextHeading(text, pos)) |heading| {
        const id_start: usize = heading.at + "<h2 id=\"".len;
        const id_end: usize = indexOfPos(u8, text, id_start, "\"") orelse break;
        const tag_end: usize = indexOfPos(u8, text, id_end, ">") orelse break;
        const title_start: usize = tag_end + 1;
        pos = title_start;
        const prefix_length: usize = headingNumberLength(text[title_start..], heading.is_chapter) orelse continue;
        const title_end: usize = indexOfPos(u8, text, title_start, "<") orelse break;
        const id: []const u8 = text[id_start..id_end];
        const title: []const u8 = trim(u8, text[title_start + prefix_length .. title_end], " ");
        if (heading.is_chapter) {
            if (sections_open) {
                try list.appendSlice(gpa, "  </ol>");
                sections_open = false;
            }
            if (chapter_open) {
                try list.appendSlice(gpa, "</li>\n");
            }
            try list.appendSlice(gpa, try allocPrint(gpa, "<li><a href=\"#{s}\">{s}</a>", .{ id, title }));
            chapter_open = true;
            continue;
        }
        if (!chapter_open) {
            continue;
        }
        if (!sections_open) {
            try list.appendSlice(gpa, "\n  <ol>\n");
            sections_open = true;
        }
        try list.appendSlice(gpa, try allocPrint(gpa, "  <li><a href=\"#{s}\">{s}</a></li>\n", .{ id, title }));
    }
    if (sections_open) {
        try list.appendSlice(gpa, "  </ol>");
    }
    if (chapter_open) {
        try list.appendSlice(gpa, "</li>\n");
    }
    try list.appendSlice(gpa, "</ol>\n");
    if (eql(u8, text[region_start..region_end], list.items)) {
        return unchanged;
    }
    var rebuilt: ArrayList(u8) = .empty;
    try rebuilt.appendSlice(gpa, text[0..region_start]);
    try rebuilt.appendSlice(gpa, list.items);
    try rebuilt.appendSlice(gpa, text[region_end..]);
    const result: Numbered = .{ .text = rebuilt.items, .count = 1 };
    return result;
}

/// Regenerate (or check) one page. Returns the page's new text; `rep` says what happened.
fn processPage(
    gpa: Allocator,
    io: Io,
    page: []const u8,
    text: []const u8,
    rep: *Report,
) ![]u8 {
    var cache: ArrayList(Source) = .empty;
    var out: ArrayList(u8) = .empty;
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

    const with_reference: []u8 = try referenceRegion(gpa, io, page, &cache, out.items, rep);
    const numbered: Numbered = try numberSections(gpa, with_reference);
    const numbers_changed: usize = numbered.count;
    if (numbers_changed > 0) {
        rep.stale += numbers_changed;
        rep.regenerated += numbers_changed;
        try say(io, gpa, "{s}: {d} section number(s) out of date\n", .{ page, numbers_changed });
    }
    const contents: Numbered = try tableOfContents(gpa, numbered.text);
    if (contents.count > 0) {
        rep.stale += 1;
        rep.regenerated += 1;
        try say(io, gpa, "{s}: the contents is out of date\n", .{page});
    }
    return contents.text;
}

test "doc_folds: section numbers follow the headings' order, and links follow their headings" {
    // A page whose sections were moved: chapter 2's sections out of order, a link showing a stale number, a link
    // with words in it, and an unnumbered heading. The numbers come from the order; the number-only links follow
    // their headings; the rest is left alone.
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const page: []const u8 =
        \\<h2 id="intro">Contents</h2>
        \\<h2 id="one">1. One</h2>
        \\<h3 id="a">1.1 A</h3>
        \\<h2 id="two">2. Two</h2>
        \\<h3 id="c">2.3 C</h3>
        \\<h3 id="b">2.1 B</h3>
        \\<p>See <a href="#c">§2.3</a>, <a href="#b">2.1</a>, <a href="#b">B itself</a>, <a href="#two">§2</a>.</p>
        \\<p>And a link that wraps: <a
        \\href="#c">§2.3</a>.</p>
    ;
    const expected: []const u8 =
        \\<h2 id="intro">Contents</h2>
        \\<h2 id="one">1. One</h2>
        \\<h3 id="a">1.1 A</h3>
        \\<h2 id="two">2. Two</h2>
        \\<h3 id="c">2.1 C</h3>
        \\<h3 id="b">2.2 B</h3>
        \\<p>See <a href="#c">§2.1</a>, <a href="#b">2.2</a>, <a href="#b">B itself</a>, <a href="#two">§2</a>.</p>
        \\<p>And a link that wraps: <a
        \\href="#c">§2.1</a>.</p>
    ;
    const numbered: Numbered = try numberSections(gpa, page);
    try expectEqualStrings(expected, numbered.text);
    try expectEqual(@as(usize, 5), numbered.count);
}

test "doc_folds: the contents lists the numbered chapters, each with its numbered sections" {
    // A page asking for its contents, with an unnumbered heading and a chapter without sections: the list holds the
    // numbered headings only, the sections nested in their chapter, every title without its number or its anchor.
    var arena: ArenaAllocator = .init(testing_allocator);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const page: []u8 = try gpa.dupe(u8,
        \\<nav><!--doc-folds:toc-->stale<!--doc-folds:toc-end--></nav>
        \\<h2 id="intro">Contents</h2>
        \\<h2 id="one">1. One<a class="anchor" href="#one">#</a></h2>
        \\<h3 id="a">1.1 A first section<a class="anchor" href="#a">#</a></h3>
        \\<h3 id="b">1.2 B</h3>
        \\<h2 id="two">2. Two</h2>
    );
    const expected: []const u8 =
        \\<nav><!--doc-folds:toc-->
        \\<ol>
        \\<li><a href="#one">One</a>
        \\  <ol>
        \\  <li><a href="#a">A first section</a></li>
        \\  <li><a href="#b">B</a></li>
        \\  </ol></li>
        \\<li><a href="#two">Two</a></li>
        \\</ol>
        \\<!--doc-folds:toc-end--></nav>
        \\<h2 id="intro">Contents</h2>
        \\<h2 id="one">1. One<a class="anchor" href="#one">#</a></h2>
        \\<h3 id="a">1.1 A first section<a class="anchor" href="#a">#</a></h3>
        \\<h3 id="b">1.2 B</h3>
        \\<h2 id="two">2. Two</h2>
    ;
    const contents: Numbered = try tableOfContents(gpa, page);
    try expectEqualStrings(expected, contents.text);
    try expectEqual(@as(usize, 1), contents.count);
}

/// The command line (std's cli, `src/command_line.zig`). `--check` is `--fix`'s CLEAR - the PR's name for an option
/// that puts another back to its default - so the two are one switch, the last one written wins, and `--help`
/// shows them as a pair.
const FoldArgs = struct {
    @"--fix": bool = false,
    pages: []const []const u8 = &.{},
};

const fold_cli: cli.Config(FoldArgs) = .{
    .prog = "doc_folds",
    .description = "Fills every source fold in the pages from the declaration it names (--fix), or checks they match.",
    .args = .{
        .@"--fix" = .{ .description = "rewrite the pages; without it, only check them", .clear = .@"--check" },
        .pages = .{ .description = "the pages whose folds to fill or check" },
    },
};

pub fn main(init: std.process.Init) !void {
    var arena: ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: Io = init.io;

    const args: FoldArgs = cli.args(&init, FoldArgs, fold_cli);
    const mode: Mode = if (args.@"--fix") .fix else .check;

    var out_buffer: [4096]u8 = undefined;
    var out_writer: File.Writer = File.stdout().writer(io, &out_buffer);
    const out: *Io.Writer = &out_writer.interface;
    var failed: bool = false;
    for (args.pages) |page| {
        var rep: Report = .{};
        const text: []u8 = try Dir.cwd().readFileAlloc(io, page, gpa, read_limit);
        const updated: []u8 = try processPage(gpa, io, page, text, &rep);
        const changed: bool = !eql(u8, text, updated);
        const verb: []const u8 = if (mode == .fix) "regenerated" else "stale";
        // A check reports every page; a fix only the pages it rewrote or could not - `zig build lint-fix` prints what
        // changed, and a page it left alone is nothing to read.
        if (mode == .check or changed or rep.errors > 0) {
            try out.print("{s}: {d} code block(s), {d} {s}, {d} reference region(s), {d} error(s)\n", .{
                page,
                rep.blocks,
                if (mode == .fix) rep.regenerated else rep.stale,
                verb,
                rep.references,
                rep.errors,
            });
        }
        if (mode == .fix and changed) {
            try Dir.cwd().writeFile(io, .{ .sub_path = page, .data = updated });
            // What changed, as it changes - as `zig build lint-fix` shows every file it rewrites.
            try line_diff.print(gpa, out, page, text, updated);
        }
        try out.flush();
        if (rep.errors > 0 or (mode == .check and rep.stale > 0)) {
            failed = true;
        }
    }
    if (failed) {
        const tail: []const u8 =
            "doc-folds FAILED: the tutorial's code no longer matches the source.\n" ++
            "Run `zig build lint-fix` (or `zig build doc-folds`) to regenerate it; fix any block whose data-decl\n" ++
            "no longer finds its declaration (renamed? add data-in= to disambiguate).\n";
        try File.stderr().writeStreamingAll(io, tail);
        std.process.exit(1);
    }
}
