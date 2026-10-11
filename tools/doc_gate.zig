//! doc_gate - the build's check that every published page follows the shared documentation style.
//!
//! Takes the pages as arguments - build.zig passes the list it installs, each as `<published name>=<path>`, so the
//! two cannot disagree - and fails the build unless every page has these properties:
//!
//!   1. Exactly one `<!--docfmt:style-->` marker: with none the page gets no stylesheet, with two it gets it twice.
//!   2. No `<style>` block: the shared stylesheet is the only one.
//!   3. No `<script>`: highlighting happens at build time. The one exception, named below (`script_ok`), is
//!      application code, not presentation.
//!   4. No webfont fetched: a documentation page needs nothing from the network.
//!   5. No id used twice in a page: an anchor two headings share sends every link to the first.
//!   6. The landing page reaches every page: readme.html links every other published page, and no `.html` page that
//!      is not published - so a new page cannot go unlisted, and a moved one cannot leave a dead link behind.
//!
//! One more property - every code block carries a language class - is not checked, because it cannot be decided
//! mechanically: shell transcripts, MJCF and ASCII diagrams also live in bare `<pre><code>` blocks, and a diagram
//! classed `zig` would come out speckled. Classing those is a judgement.
//!
//! Usage: `doc_gate <name>=<page.html> [<name>=<page.html> ...]` (a bare path is named by its last component)

const std = @import("std");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const cli = @import("cli");
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const File = Io.File;
const indexOf = std.mem.indexOf;
const endsWith = std.mem.endsWith;
const indexOfPos = std.mem.indexOfPos;
const indexOfScalar = std.mem.indexOfScalar;
const eql = std.mem.eql;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;
const basename = std.fs.path.basename;

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

/// A page as the build passes it.
const Page = struct {
    /// The name it is published under: its file name in the installed site, what links name.
    name: []const u8,
    /// Its source file.
    path: []const u8,
};

/// A page argument, `<published name>=<path>`; a bare path is named by its last component.
fn pageOf(arg: []const u8) Page {
    if (indexOfScalar(u8, arg, '=')) |at| {
        return .{ .name = arg[0..at], .path = arg[at + 1 ..] };
    }
    return .{ .name = basename(arg), .path = arg };
}

/// The page every other is reached from.
const landing_page: []const u8 = "readme.html";

/// Whether `landing` links the page published as `name`: an `href` to it, alone or with an anchor.
fn linksPage(landing: []const u8, name: []const u8) bool {
    var buffer: [256]u8 = undefined;
    const plain: []const u8 = bufPrint(&buffer, "href=\"{s}\"", .{name}) catch return false;
    if (indexOf(u8, landing, plain) != null) {
        return true;
    }
    const anchored: []const u8 = bufPrint(&buffer, "href=\"{s}#", .{name}) catch return false;
    return indexOf(u8, landing, anchored) != null;
}

/// The relative links from `landing` to `.html` pages that are not published, in order.
fn unpublishedLinks(
    gpa: Allocator,
    landing: []const u8,
    published: []const Page,
) ![]const []const u8 {
    var found: ArrayList([]const u8) = .empty;
    const needle: []const u8 = "href=\"";
    var at: usize = 0;
    while (indexOfPos(u8, landing, at, needle)) |start_of_attribute| {
        const start: usize = start_of_attribute + needle.len;
        const end: usize = indexOfScalarPos(u8, landing, start, '"') orelse break;
        at = end;
        const target: []const u8 = landing[start..end];
        const page_part: []const u8 = target[0 .. indexOfScalar(u8, target, '#') orelse target.len];
        const is_relative_page: bool = endsWith(u8, page_part, ".html") and indexOf(u8, page_part, "://") == null;
        if (!is_relative_page) {
            continue;
        }
        const is_published: bool = for (published) |page| {
            if (eql(u8, page.name, page_part)) {
                break true;
            }
        } else false;
        if (!is_published) {
            try found.append(gpa, page_part);
        }
    }
    return found.items;
}

/// The command line (std's cli, `src/command_line.zig`).
const GateArgs = struct {
    pages: []const []const u8 = &.{},
};

const gate_cli: cli.Config(GateArgs) = .{
    .prog = "doc_gate",
    .description = "Checks the published doc pages: one stylesheet, no script, no network, no id twice, " ++
        "every page reached.",
    .args = .{ .pages = .{ .description = "the styled pages to check, each as <published name>=<path>" } },
};

/// The first `id` attribute value a page uses twice, or null. Only attributes INSIDE a tag count (the nearest `<`
/// before the match comes after the nearest `>`), so a code sample that merely contains the text `id="` cannot
/// trip it.
fn firstDuplicateId(gpa: Allocator, src: []const u8) !?[]const u8 {
    const IdSet = std.StringHashMapUnmanaged(void);
    var seen: IdSet = .empty;
    defer seen.deinit(gpa);
    const needle: []const u8 = " id=\"";
    var at: usize = 0;
    while (indexOfPos(u8, src, at, needle)) |found| {
        at = found + needle.len;
        const last_open: ?usize = std.mem.lastIndexOfScalar(u8, src[0..found], '<');
        const last_close: ?usize = std.mem.lastIndexOfScalar(u8, src[0..found], '>');
        const inside_tag: bool = if (last_open) |open| (last_close == null or open > last_close.?) else false;
        if (!inside_tag) {
            continue;
        }
        const end: usize = indexOfScalarPos(u8, src, at, '"') orelse break;
        const id: []const u8 = src[at..end];
        const entry: IdSet.GetOrPutResult = try seen.getOrPut(gpa, id);
        if (entry.found_existing) {
            return id;
        }
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var arena: ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: Io = init.io;
    const cwd: Io.Dir = .cwd();

    const args: GateArgs = cli.args(&init, GateArgs, gate_cli);

    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;

    var failures: usize = 0;
    var checked: usize = 0;
    var pages: ArrayList(Page) = .empty;
    var landing_source: ?[]const u8 = null;

    for (args.pages) |arg| {
        const page: Page = pageOf(arg);
        try pages.append(gpa, page);
        const path: []const u8 = page.path;
        const src: []const u8 = cwd.readFileAlloc(io, path, gpa, .unlimited) catch {
            try w.print("doc-gate: cannot read {s}\n", .{path});
            failures += 1;
            continue;
        };
        checked += 1;
        if (eql(u8, page.name, landing_page)) {
            landing_source = src;
        }

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

    // 6. The landing page reaches every page, and no page that is not published.
    if (landing_source) |landing| {
        for (pages.items) |page| {
            if (eql(u8, page.name, landing_page)) {
                continue;
            }
            if (!linksPage(landing, page.name)) {
                try w.print("doc-gate: {s} has no link to {s} - a published page no reader can reach\n", .{
                    landing_page,
                    page.name,
                });
                failures += 1;
            }
        }
        for (try unpublishedLinks(gpa, landing, pages.items)) |target| {
            try w.print("doc-gate: {s} links {s}, which is not a published page\n", .{ landing_page, target });
            failures += 1;
        }
    }

    if (failures == 0) {
        const summary: []const u8 = "one stylesheet, no script, no network, no id twice, every page reached";
        try w.print("doc-gate: {d} pages, {s}.\n", .{ checked, summary });
        try File.stdout().writeStreamingAll(io, aw.written());
        return;
    }
    try w.print("doc-gate: {d} violation(s) across {d} pages.\n", .{ failures, checked });
    try File.stderr().writeStreamingAll(io, aw.written());
    std.process.exit(1);
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "doc_gate: the landing page's links - every page reached, none dangling" {
    const gpa: Allocator = testing_allocator;
    const landing: []const u8 = "<a href=\"a.html\">a</a> <a href=\"b.html#part\">b</a>" ++
        " <a href=\"notes/c.html\">c</a> <a href=\"https://example.com/d.html\">d</a>";
    try expect(linksPage(landing, "a.html"));
    try expect(linksPage(landing, "b.html"));
    try expect(!linksPage(landing, "e.html"));
    const published = [_]Page{ pageOf("a.html=src/a.html"), pageOf("b.html=src/b.html") };
    var arena: ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const dangling: []const []const u8 = try unpublishedLinks(arena.allocator(), landing, &published);
    try expect(dangling.len == 1);
    try expectEqualStrings("notes/c.html", dangling[0]);
}

test "doc_gate: a page argument carries its published name" {
    const named: Page = pageOf("shader-authoring-tutorial.html=src/notes/tutorials/shader_authoring_tutorial.html");
    try expectEqualStrings("shader-authoring-tutorial.html", named.name);
    try expectEqualStrings("src/notes/tutorials/shader_authoring_tutorial.html", named.path);
    try expectEqualStrings("robots.html", pageOf("src/notes/tutorials/robots.html").name);
}

test "doc_gate: a duplicate id is found; ids in text, or once each, are not" {
    const gpa: Allocator = testing_allocator;
    try expectEqualStrings("a", (try firstDuplicateId(gpa, "<h3 id=\"a\">x</h3><h3 id=\"a\">y</h3>")).?);
    try expect((try firstDuplicateId(gpa, "<h3 id=\"a\">x</h3><h3 id=\"b\">y</h3>")) == null);
    // In a code sample the text is not an attribute.
    try expect((try firstDuplicateId(gpa, "<h3 id=\"a\">x</h3><pre>f( id=\"a\")</pre>")) == null);
}
