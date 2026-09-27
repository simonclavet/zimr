//! example_source - one example's source files, highlighted, as the JSON the
//! gallery's code pane shows under the running example.
//!
//!     example_source <name> <out.json> <display-path> <file> [<display-path> <file> ...]
//!
//! writes
//!
//!     {"name":"julia","files":[{"path":"examples/julia/julia.zig","lines":94,"html":"..."}]}
//!
//! `path` is what the pane's tab shows, `lines` is the file's line count, and
//! `html` is the file highlighted by docfmt's `highlightZig` - the same code that
//! highlights every doc page. So there is one highlighter, it runs at build time,
//! the gallery ships no highlighter of its own and the site ships no raw source.
//!
//! build.zig runs this once per example, on the example's folder plus the shader
//! files its `App` row wires (see `installExampleSource`), and installs the result
//! as web/<name>/source.json beside the example's page.
//!
//! One property is checked here instead of trusted: no highlighted span may cross
//! a newline, because the pane splits `html` on newlines into one row per line.
//! Zig guarantees it today (no Zig token spans lines). A language whose comments
//! do - WGSL's `/* */` - fails this build instead of rendering a broken pane.

const std = @import("std");
const docfmt = @import("docfmt.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const File = std.Io.File;
const startsWith = std.mem.startsWith;
const expect = std.testing.expect;

/// Far above the largest example file (scenes.zig, 218 KB): a file this big is a
/// mistake in the file list, not an example.
const max_source_bytes: usize = 16 * 1024 * 1024;

/// One file as the pane shows it: its tab label, line count and highlighted body.
const SourceFile = struct {
    path: []const u8,
    lines: usize,
    html: []const u8,
};

/// The whole of source.json.
const ExampleSource = struct {
    name: []const u8,
    files: []const SourceFile,
};

/// `raw` with every CRLF turned into LF. A Windows checkout (core.autocrlf) hands
/// the tool CRLF; the pane's rows and its copy button both want LF.
fn lfOnly(gpa: Allocator, raw: []const u8) ![]const u8 {
    const out: []u8 = try gpa.alloc(u8, raw.len);
    var len: usize = 0;
    for (raw, 0..) |c, i| {
        const is_cr_of_crlf: bool = c == '\r' and i + 1 < raw.len and raw[i + 1] == '\n';
        if (!is_cr_of_crlf) {
            out[len] = c;
            len += 1;
        }
    }
    return out[0..len];
}

/// Lines as an editor numbers them: a last line without its newline still counts.
fn lineCount(text: []const u8) usize {
    const newlines: usize = std.mem.count(u8, text, "\n");
    const ends_mid_line: bool = text.len > 0 and text[text.len - 1] != '\n';
    return newlines + @intFromBool(ends_mid_line);
}

/// True when every line of `html` closes each span it opens. Escaped text never
/// holds a raw `<`, so `<span` and `</span>` can only be the highlighter's markup.
fn spansCloseOnEveryLine(html: []const u8) bool {
    const open_tag: []const u8 = "<span";
    const close_tag: []const u8 = "</span>";
    var open_spans: usize = 0;
    var i: usize = 0;
    while (i < html.len) {
        if (startsWith(u8, html[i..], open_tag)) {
            open_spans += 1;
            i += open_tag.len;
            continue;
        }
        if (startsWith(u8, html[i..], close_tag)) {
            if (open_spans == 0) {
                return false;
            }
            open_spans -= 1;
            i += close_tag.len;
            continue;
        }
        const newline_inside_span: bool = html[i] == '\n' and open_spans != 0;
        if (newline_inside_span) {
            return false;
        }
        i += 1;
    }
    return open_spans == 0;
}

/// `text` (LF only) as highlighted HTML.
fn highlight(gpa: Allocator, text: []const u8) ![]const u8 {
    var html: Writer.Allocating = .init(gpa);
    try docfmt.highlightZig(gpa, &html.writer, text);
    return html.written();
}

pub fn main(init: std.process.Init) !u8 {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: std.Io = init.io;

    var stderr_buf: [512]u8 = undefined;
    var stderr_writer: File.Writer = File.stderr().writer(io, &stderr_buf);
    const stderr: *Writer = &stderr_writer.interface;

    const argv: []const [:0]const u8 = try init.minimal.args.toSlice(gpa);
    const has_file_pairs: bool = argv.len >= 5 and (argv.len - 3) % 2 == 0;
    if (!has_file_pairs) {
        try stderr.writeAll("usage: example_source <name> <out.json> <display-path> <file> ...\n");
        try stderr.flush();
        return 2;
    }
    const name: []const u8 = argv[1];
    const out_path: []const u8 = argv[2];
    const pairs: []const [:0]const u8 = argv[3..];

    const files: []SourceFile = try gpa.alloc(SourceFile, pairs.len / 2);
    var file_count: usize = 0;
    for (0..files.len) |i| {
        const display_path: []const u8 = pairs[2 * i];
        const disk_path: []const u8 = pairs[2 * i + 1];
        const raw: []u8 = std.Io.Dir.cwd().readFileAlloc(io, disk_path, gpa, .limited(max_source_bytes)) catch |err| {
            try stderr.print("example_source: {s}: cannot read {s}: {s}\n", .{ name, display_path, @errorName(err) });
            try stderr.flush();
            return 1;
        };
        const text: []const u8 = try lfOnly(gpa, raw);
        // An empty file (a placeholder in an example's folder) has nothing to show.
        if (text.len == 0) {
            continue;
        }
        const html: []const u8 = try highlight(gpa, text);
        if (!spansCloseOnEveryLine(html)) {
            try stderr.print(
                "example_source: {s}: a highlighted span in {s} crosses a newline; the pane needs one row per line\n",
                .{ name, display_path },
            );
            try stderr.flush();
            return 1;
        }
        files[file_count] = .{ .path = display_path, .lines = lineCount(text), .html = html };
        file_count += 1;
    }

    const example: ExampleSource = .{ .name = name, .files = files[0..file_count] };
    var json: Writer.Allocating = .init(gpa);
    try std.json.Stringify.value(example, .{}, &json.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = json.written() });
    return 0;
}

test "highlighted Zig closes every span on the line that opened it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    // Each Zig construct that could plausibly span lines: a doc comment, a
    // multiline string (one token per line), a line comment, markup to escape.
    const source: []const u8 =
        \\/// A doc comment.
        \\const banner: []const u8 =
        \\    \\first line of a multiline string
        \\    \\second line
        \\;
        \\// a comment with "quotes" and <angle brackets>
        \\fn answer() u32 {
        \\    return @intCast(42);
        \\}
        \\
    ;
    const html: []const u8 = try highlight(gpa, source);
    try expect(spansCloseOnEveryLine(html));
    try expect(std.mem.count(u8, html, "\n") == std.mem.count(u8, source, "\n"));
    try expect(std.mem.indexOf(u8, html, "&lt;angle brackets&gt;") != null);
}

test "a span left open across a newline is caught" {
    try expect(!spansCloseOnEveryLine("<span class=\"tok-comment\">/* two\nlines */</span>"));
    try expect(!spansCloseOnEveryLine("<span class=\"tok-kw\">const"));
    try expect(spansCloseOnEveryLine("<span class=\"tok-kw\">const</span> x = 1;\ny\n"));
}

test "CRLF becomes LF, and lines are counted the way an editor numbers them" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const text: []const u8 = try lfOnly(arena.allocator(), "a\r\nb\r\n");
    try expect(std.mem.eql(u8, text, "a\nb\n"));
    try expect(lineCount(text) == 2);
    try expect(lineCount("a\nb") == 2);
    try expect(lineCount("") == 0);
}
