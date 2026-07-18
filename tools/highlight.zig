//! highlight — build-time Zig syntax highlighter for readme.html.
//!
//! A plain stdin -> stdout filter.  Every
//!   <pre><code class="language-zig"> … </code></pre>
//! block has its inner text HTML-decoded back to real Zig, tokenized with
//! std.zig.Tokenizer, and re-emitted with <span class="tok-…"> wrappers
//! (keywords, builtins, string/char literals, numbers, comments).  Everything
//! else — prose, shell blocks, the ASCII pipeline diagram in a bare
//! <pre><code> — passes through byte-for-byte.
//!
//! On brand: Zig's own tokenizer highlights Zig, at build time, so the served
//! page stays pure HTML+CSS with zero runtime JS.  Wired in build.zig: the
//! readme.html install pipes through this tool instead of copying verbatim.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Writer = std.Io.Writer;
const File = std.Io.File;
const Token = std.zig.Token;
const Tag = std.zig.Token.Tag;

const open_tag = "<pre><code class=\"language-zig\">";
const close_tag = "</code></pre>";

pub fn main(init: std.process.Init) !void {
    var arena: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: std.Io = init.io;

    const src: []u8 = try readAllStdin(gpa, io);

    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;

    var i: usize = 0;
    while (std.mem.indexOfPos(u8, src, i, open_tag)) |open_at| {
        // Copy everything up to and including the opener verbatim.
        try w.writeAll(src[i .. open_at + open_tag.len]);
        const body_start: usize = open_at + open_tag.len;
        const close_at: usize = std.mem.indexOfPos(u8, src, body_start, close_tag) orelse {
            // Unterminated block — copy the remainder and stop.
            try w.writeAll(src[body_start..]);
            i = src.len;
            break;
        };
        try highlightBlock(gpa, w, src[body_start..close_at]);
        try w.writeAll(close_tag);
        i = close_at + close_tag.len;
    }
    try w.writeAll(src[i..]);

    try File.stdout().writeStreamingAll(io, aw.written());
}

fn highlightBlock(gpa: Allocator, w: *Writer, escaped: []const u8) !void {
    // HTML-decode to real Zig source (normalizing CRLF -> LF), then
    // sentinel-terminate for the tokenizer.
    const decoded: []const u8 = try htmlDecode(gpa, escaped);
    const buf: [:0]u8 = try gpa.allocSentinel(u8, decoded.len, 0);
    @memcpy(buf, decoded);

    var tok: std.zig.Tokenizer = .init(buf);
    var cursor: usize = 0;
    while (true) {
        const t: Token = tok.next();
        // Gap between tokens holds whitespace and `//` line comments (which the
        // tokenizer skips); emit it with comment spans applied.
        try emitGap(w, decoded[cursor..t.loc.start]);
        if (t.tag == .eof) {
            break;
        }
        const text: []const u8 = decoded[t.loc.start..t.loc.end];
        if (classOf(t.tag)) |cls| {
            try w.writeAll("<span class=\"");
            try w.writeAll(cls);
            try w.writeAll("\">");
            try escapeInto(w, text);
            try w.writeAll("</span>");
        } else {
            try escapeInto(w, text);
        }
        cursor = t.loc.end;
    }
}

fn classOf(tag: Tag) ?[]const u8 {
    return switch (tag) {
        .string_literal, .multiline_string_literal_line, .char_literal => "tok-str",
        .number_literal => "tok-num",
        .builtin => "tok-builtin",
        .doc_comment, .container_doc_comment => "tok-comment",
        else => if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) "tok-kw" else null,
    };
}

// Emit an inter-token gap, wrapping `//` line comments in a comment span and
// passing whitespace through untouched.
fn emitGap(w: *Writer, gap: []const u8) !void {
    var run_start: usize = 0;
    var j: usize = 0;
    while (j < gap.len) {
        if (gap[j] == '/' and j + 1 < gap.len and gap[j + 1] == '/') {
            try escapeInto(w, gap[run_start..j]);
            var k: usize = j;
            while (k < gap.len and gap[k] != '\n') {
                k += 1;
            }
            try w.writeAll("<span class=\"tok-comment\">");
            try escapeInto(w, gap[j..k]);
            try w.writeAll("</span>");
            j = k;
            run_start = k;
        } else {
            j += 1;
        }
    }
    try escapeInto(w, gap[run_start..]);
}

// Re-escape for HTML text content.  Only &, <, > matter; quotes stay literal,
// matching the readme's existing convention (e.g. `"zimr"` unescaped in code).
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

// Decode the handful of entities the readme actually uses, and normalize line
// endings.  A bare `&` (Zig address-of, e.g. `&sw`) that isn't a known entity
// is kept literal — the readme writes those unescaped.
fn htmlDecode(gpa: Allocator, s: []const u8) ![]u8 {
    var out: ArrayList(u8) = .empty;
    var j: usize = 0;
    while (j < s.len) {
        const c: u8 = s[j];
        if (c == '\r') {
            try out.append(gpa, '\n');
            j += if (j + 1 < s.len and s[j + 1] == '\n') @as(usize, 2) else 1;
            continue;
        }
        if (c == '&') {
            const rest: []const u8 = s[j..];
            if (std.mem.startsWith(u8, rest, "&lt;")) {
                try out.append(gpa, '<');
                j += 4;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&gt;")) {
                try out.append(gpa, '>');
                j += 4;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&amp;")) {
                try out.append(gpa, '&');
                j += 5;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&quot;")) {
                try out.append(gpa, '"');
                j += 6;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "&#39;")) {
                try out.append(gpa, '\'');
                j += 5;
                continue;
            }
        }
        try out.append(gpa, c);
        j += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn readAllStdin(gpa: Allocator, io: std.Io) ![]u8 {
    var list: ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    const in: File = File.stdin();
    while (true) {
        var iov = [_][]u8{&buf};
        const n: usize = in.readStreaming(io, &iov) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) {
            break;
        }
        try list.appendSlice(gpa, buf[0..n]);
    }
    return list.toOwnedSlice(gpa);
}
