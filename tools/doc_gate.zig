//! doc_gate - fail the build if a published page drifts back to its own style.
//!
//! Every finding in `src/notes/docs_style_plan.md` section 1 - five palettes, three
//! highlighters, two pages fetching Google Fonts - existed because nothing
//! checked.  A style rule with no gate is a preference, and the next page gets
//! styled in the turn that creates it, exactly like those eleven were.
//!
//! Takes the page paths as arguments (build.zig passes the same list it
//! installs, so the two cannot disagree) and enforces four properties:
//!
//!   1. EXACTLY ONE `<!--docfmt:style-->` marker.  Zero means the page gets no
//!      stylesheet; two would inject it twice.
//!   2. NO `<style>` block.  The page does not own its own CSS any more.
//!   3. NO `<script>`.  Highlighting happens at build time; the one exception is
//!      listed below and is application code, not presentation.
//!   4. NO webfont fetch.  A doc page reaches across the network for nothing.
//!   5. NO id used twice in a page.  An anchor two headings share sends every link to
//!      the first - the robot tutorial's 11.2 and 11.8 were both `worldmodel` until
//!      Sep 27, and nothing noticed.
//!
//! A fifth property - "every code block carries a language class" - is NOT
//! gated, because it is not mechanically decidable: shell transcripts, MJCF and
//! the ASCII pipeline diagrams live in bare <pre><code> too, and a diagram
//! tagged `zig` comes out speckled.  Classing those is a judgement, so it stays
//! a judgement.
//!
//! Usage: `doc_gate <page.html> [page.html ...]`

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const File = std.Io.File;
const indexOf = std.mem.indexOf;
const endsWith = std.mem.endsWith;

const marker = "<!--docfmt:style-->";

/// index.html's <script> is the gallery's manifest-driven filter and search -
/// application code that happens to live in a page this gate covers.  Named
/// here so the exception is visible rather than implied.
const script_ok = [_][]const u8{"index.html"};

fn scriptAllowed(path: []const u8) bool {
    for (script_ok) |name| {
        if (endsWith(u8, path, name)) {
            return true;
        }
    }
    return false;
}

fn countOf(hay: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (indexOf(u8, hay[i..], needle)) |at| {
        n += 1;
        i += at + needle.len;
    }
    return n;
}

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: std.Io = init.io;
    const cwd: std.Io.Dir = std.Io.Dir.cwd();

    var args_list: ArrayList([]u8) = .empty;
    var arg_it: std.process.Args.Iterator = try .initAllocator(init.minimal.args, gpa);
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;

    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;

    var failures: usize = 0;
    var checked: usize = 0;

    for (args[1..]) |path| {
        const src: []const u8 = cwd.readFileAlloc(io, path, gpa, .unlimited) catch {
            try w.print("doc-gate: cannot read {s}\n", .{path});
            failures += 1;
            continue;
        };
        checked += 1;

        const markers: usize = countOf(src, marker);
        if (markers != 1) {
            try w.print(
                "doc-gate: {s}: {d} `{s}` markers, want exactly 1\n",
                .{ path, markers, marker },
            );
            failures += 1;
        }
        if (indexOf(u8, src, "<style") != null) {
            try w.print(
                "doc-gate: {s}: has its own <style> block — the shared sheet in tools/docfmt.zig is the only one\n",
                .{path},
            );
            failures += 1;
        }
        if (indexOf(u8, src, "<script") != null and !scriptAllowed(path)) {
            try w.print(
                "doc-gate: {s}: has a <script> — highlighting is done at build time by docfmt\n",
                .{path},
            );
            failures += 1;
        }
        if (try firstDuplicateId(gpa, src)) |id| {
            try w.print(
                "doc-gate: {s}: id=\"{s}\" is used more than once - every link to it lands on the first\n",
                .{ path, id },
            );
            failures += 1;
        }
        if (indexOf(u8, src, "fonts.googleapis") != null or
            indexOf(u8, src, "fonts.gstatic") != null)
        {
            try w.print(
                "doc-gate: {s}: fetches a webfont — the shared sheet uses the system mono stack\n",
                .{path},
            );
            failures += 1;
        }
    }

    if (failures == 0) {
        try w.print("doc-gate: {d} pages, one stylesheet, no script, no network, no id twice.\n", .{checked});
        try File.stdout().writeStreamingAll(io, aw.written());
        return;
    }
    try w.print("doc-gate: {d} violation(s) across {d} pages.\n", .{ failures, checked });
    try File.stderr().writeStreamingAll(io, aw.written());
    std.process.exit(1);
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The first `id` attribute value a page uses twice, or null. Only attributes INSIDE a tag count (the nearest `<`
/// before the match comes after the nearest `>`), so a code sample that merely contains the text `id="` cannot
/// trip it.
fn firstDuplicateId(gpa: Allocator, src: []const u8) !?[]const u8 {
    const IdSet = std.StringHashMapUnmanaged(void);
    var seen: IdSet = .empty;
    defer seen.deinit(gpa);
    const needle: []const u8 = " id=\"";
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, needle)) |found| {
        at = found + needle.len;
        const last_open: ?usize = std.mem.lastIndexOfScalar(u8, src[0..found], '<');
        const last_close: ?usize = std.mem.lastIndexOfScalar(u8, src[0..found], '>');
        const inside_tag: bool = if (last_open) |open| (last_close == null or open > last_close.?) else false;
        if (!inside_tag) {
            continue;
        }
        const end: usize = std.mem.indexOfScalarPos(u8, src, at, '"') orelse break;
        const id: []const u8 = src[at..end];
        const entry: IdSet.GetOrPutResult = try seen.getOrPut(gpa, id);
        if (entry.found_existing) {
            return id;
        }
    }
    return null;
}

test "doc_gate: a duplicate id is found; ids in text, or once each, are not" {
    const gpa: Allocator = std.testing.allocator;
    try expectEqualStrings("a", (try firstDuplicateId(gpa, "<h3 id=\"a\">x</h3><h3 id=\"a\">y</h3>")).?);
    try expect((try firstDuplicateId(gpa, "<h3 id=\"a\">x</h3><h3 id=\"b\">y</h3>")) == null);
    // In a code sample the text is not an attribute.
    try expect((try firstDuplicateId(gpa, "<h3 id=\"a\">x</h3><pre>f( id=\"a\")</pre>")) == null);
}
