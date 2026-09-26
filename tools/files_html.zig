//! files_html — render `src/notes/files.md` (the per-file atlas) as a doc page.
//!
//! `zig build files-md` generates the markdown atlas; this turns it into
//! `src/notes/files.html`, which then goes through `docfmt` like every other
//! published page and so picks up the shared stylesheet automatically.
//!
//! It handles only the markdown that files.md actually contains — ATX headings,
//! fenced code, tables, lists, blockquote-free prose, `**bold**`, `*italic*`,
//! `` `code` `` and autolinks.  That is deliberate: a general markdown engine is
//! a large thing to own, and every construct it would add is one this document
//! does not use.
//!
//! The mermaid fence in the atlas is emitted as a plain <pre> rather than being
//! rendered.  Rendering it would mean shipping mermaid.js — runtime JS fetched
//! over the network, which is exactly what the docs just stopped doing.  The
//! graph is readable as text; `zig build dag-png` is there when a picture is
//! wanted.
//!
//! Usage: `files_html` (run from repo root; reads src/notes/files.md, writes
//! src/notes/files.html).

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const Writer = std.Io.Writer;
const File = std.Io.File;

const in_path = "src/notes/files.md";
const out_path = "src/notes/files.html";

const head =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width,initial-scale=1">
    \\<title>zimr file atlas</title>
    \\<!--docfmt:style-->
    \\</head>
    \\<body>
    \\<p class="faint"><a href="readme.html">&#8592; zimr</a></p>
    \\
;

const foot =
    \\</body>
    \\</html>
    \\
;

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: std.Io = init.io;
    const cwd: std.Io.Dir = std.Io.Dir.cwd();

    const md: []const u8 = try cwd.readFileAlloc(io, in_path, gpa, .unlimited);

    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    try w.writeAll(head);
    try render(w, md);
    try w.writeAll(foot);

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = aw.written() });

    var out_buf: [256]u8 = undefined;
    const msg: []const u8 = try bufPrint(
        &out_buf,
        "files_html: {s} -> {s} ({d} bytes)\n",
        .{ in_path, out_path, aw.written().len },
    );
    try File.stdout().writeStreamingAll(io, msg);
}

const Mode = enum { prose, code, table, list };

fn render(w: *Writer, md: []const u8) !void {
    var mode: Mode = .prose;
    var table_head_done: bool = false;
    var it = std.mem.splitScalar(u8, md, '\n');
    while (it.next()) |raw| {
        const line: []const u8 = std.mem.trimEnd(u8, raw, "\r");
        const trimmed: []const u8 = std.mem.trim(u8, line, " \t");

        // Fenced code: everything inside passes through escaped, untouched.
        if (std.mem.startsWith(u8, trimmed, "```")) {
            if (mode == .code) {
                try w.writeAll("</code></pre>\n");
                mode = .prose;
            } else {
                try closeBlock(w, &mode, &table_head_done);
                // The fence's info string (e.g. ```mermaid) becomes the class,
                // so docfmt highlights ```zig and leaves ```mermaid alone.
                const info: []const u8 = std.mem.trim(u8, trimmed[3..], " \t");
                try w.writeAll("<pre><code");
                if (info.len > 0) {
                    try w.writeAll(" class=\"");
                    try escapeInto(w, info);
                    try w.writeAll("\"");
                }
                try w.writeAll(">");
                mode = .code;
            }
            continue;
        }
        if (mode == .code) {
            try escapeInto(w, line);
            try w.writeAll("\n");
            continue;
        }

        // Blank line closes whatever run we are in.
        if (trimmed.len == 0) {
            try closeBlock(w, &mode, &table_head_done);
            continue;
        }

        // Heading.
        if (trimmed[0] == '#') {
            try closeBlock(w, &mode, &table_head_done);
            var level: usize = 0;
            while (level < trimmed.len and trimmed[level] == '#') : (level += 1) {}
            const text: []const u8 = std.mem.trim(u8, trimmed[level..], " \t");
            const tag: u8 = '0' + @as(u8, @intCast(@min(level, 6)));
            try w.writeAll("<h");
            try w.writeByte(tag);
            try w.writeAll(">");
            try inline_md(w, text);
            try w.writeAll("</h");
            try w.writeByte(tag);
            try w.writeAll(">\n");
            continue;
        }

        // Table row.
        if (trimmed.len > 0 and trimmed[0] == '|') {
            if (isDelimiterRow(trimmed)) {
                // The |---|---| row: switch the header run to the body.
                if (mode == .table and !table_head_done) {
                    try w.writeAll("</thead><tbody>\n");
                    table_head_done = true;
                }
                continue;
            }
            if (mode != .table) {
                try closeBlock(w, &mode, &table_head_done);
                try w.writeAll("<table><thead>\n");
                mode = .table;
                table_head_done = false;
            }
            const cell_tag: []const u8 = if (table_head_done) "td" else "th";
            try w.writeAll("<tr>");
            var cells = std.mem.splitScalar(u8, std.mem.trim(u8, trimmed, "|"), '|');
            while (cells.next()) |cell| {
                try w.writeAll("<");
                try w.writeAll(cell_tag);
                try w.writeAll(">");
                try inline_md(w, std.mem.trim(u8, cell, " \t"));
                try w.writeAll("</");
                try w.writeAll(cell_tag);
                try w.writeAll(">");
            }
            try w.writeAll("</tr>\n");
            continue;
        }

        // List item.
        if (std.mem.startsWith(u8, trimmed, "- ") or std.mem.startsWith(u8, trimmed, "* ")) {
            if (mode != .list) {
                try closeBlock(w, &mode, &table_head_done);
                try w.writeAll("<ul>\n");
                mode = .list;
            }
            try w.writeAll("<li>");
            try inline_md(w, trimmed[2..]);
            try w.writeAll("</li>\n");
            continue;
        }

        // An indented block in files.md is a code sample, not a list continuation.
        if (std.mem.startsWith(u8, line, "    ") and mode == .prose) {
            try w.writeAll("<pre><code>");
            try escapeInto(w, line[4..]);
            try w.writeAll("</code></pre>\n");
            continue;
        }

        // Ordinary prose.
        if (mode != .prose) {
            try closeBlock(w, &mode, &table_head_done);
        }
        try w.writeAll("<p>");
        try inline_md(w, trimmed);
        try w.writeAll("</p>\n");
    }
    try closeBlock(w, &mode, &table_head_done);
}

fn closeBlock(w: *Writer, mode: *Mode, table_head_done: *bool) !void {
    switch (mode.*) {
        .table => {
            try w.writeAll(if (table_head_done.*) "</tbody></table>\n" else "</thead></table>\n");
            table_head_done.* = false;
        },
        .list => try w.writeAll("</ul>\n"),
        .code => try w.writeAll("</code></pre>\n"),
        .prose => {},
    }
    mode.* = .prose;
}

fn isDelimiterRow(s: []const u8) bool {
    var saw_dash: bool = false;
    for (s) |c| {
        switch (c) {
            '-' => saw_dash = true,
            '|', ':', ' ', '\t' => {},
            else => return false,
        }
    }
    return saw_dash;
}

// `code`, **bold**, *italic*, [text](url) and bare http(s) autolinks.  Applied
// in one left-to-right pass so a `*` inside `code` is never taken for emphasis.
fn inline_md(w: *Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        const c: u8 = s[i];
        if (c == '`') {
            const end: usize = std.mem.indexOfScalarPos(u8, s, i + 1, '`') orelse {
                try escapeInto(w, s[i .. i + 1]);
                i += 1;
                continue;
            };
            try w.writeAll("<code>");
            try escapeInto(w, s[i + 1 .. end]);
            try w.writeAll("</code>");
            i = end + 1;
            continue;
        }
        if (c == '*' and i + 1 < s.len and s[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
                try w.writeAll("<strong>");
                try inline_md(w, s[i + 2 .. end]);
                try w.writeAll("</strong>");
                i = end + 2;
                continue;
            }
        }
        if (c == '*') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '*')) |end| {
                try w.writeAll("<em>");
                try inline_md(w, s[i + 1 .. end]);
                try w.writeAll("</em>");
                i = end + 1;
                continue;
            }
        }
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, s, i, ']')) |rb| {
                if (rb + 1 < s.len and s[rb + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, rb + 2, ')')) |rp| {
                        try w.writeAll("<a href=\"");
                        try escapeInto(w, s[rb + 2 .. rp]);
                        try w.writeAll("\">");
                        try inline_md(w, s[i + 1 .. rb]);
                        try w.writeAll("</a>");
                        i = rp + 1;
                        continue;
                    }
                }
            }
        }
        if (c == 'h' and std.mem.startsWith(u8, s[i..], "http")) {
            var j: usize = i;
            while (j < s.len and s[j] != ' ' and s[j] != ')' and s[j] != '\t') : (j += 1) {}
            try w.writeAll("<a href=\"");
            try escapeInto(w, s[i..j]);
            try w.writeAll("\">");
            try escapeInto(w, s[i..j]);
            try w.writeAll("</a>");
            i = j;
            continue;
        }
        try escapeInto(w, s[i .. i + 1]);
        i += 1;
    }
}

fn escapeInto(w: *Writer, s: []const u8) !void {
    var start: usize = 0;
    var j: usize = 0;
    while (j < s.len) : (j += 1) {
        const rep: ?[]const u8 = switch (s[j]) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => null,
        };
        if (rep) |r| {
            try w.writeAll(s[start..j]);
            try w.writeAll(r);
            start = j + 1;
        }
    }
    try w.writeAll(s[start..]);
}
