//! line_diff - what changed between two versions of a text, printed as a unified diff.
//!
//! The tools that rewrite sources - `zimrlint --fix` (what `zig build fix` runs) and `doc_folds --fix` - print the
//! diff of every file they rewrite, the moment they write it. A fix that moves code without showing how is a fix
//! nobody reviewed; with the diff in the console, the person who ran it sees exactly what changed, in the form
//! `git diff` and `git apply` use (`--- a/<path>`, `+++ b/<path>`, `@@ -l,n +l,n @@` hunks with three lines of
//! context).
//!
//! The edit script is the shortest one: Myers, "An O(ND) Difference Algorithm and Its Variations" (1986), searched
//! only between the common head and tail, so a fix touching three lines of a 40 000-line file costs three lines of
//! search. Lines keep their '\n', so a file that gains or loses its final newline shows it, as `diff -u` does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Io = std.Io;
const endsWith = std.mem.endsWith;
const eql = std.mem.eql;
const expectEqualStrings = std.testing.expectEqualStrings;
const indexOfScalarPos = std.mem.indexOfScalarPos;
const startsWith = std.mem.startsWith;
const testing_allocator = std.testing.allocator;
const expectEqual = std.testing.expectEqual;

/// Unchanged lines shown around each change, as `diff -u` and `git diff` show them.
const context_lines: usize = 3;

/// Changed lines printed per file before the rest is only counted. A whole file reformatted is thousands of lines
/// nobody reads in a console, and `git diff` shows them all.
const max_printed_changes: usize = 400;

/// The edit count past which the search stops looking for the shortest script and reports the region between the
/// common head and tail as removed and added again - still exact, only longer. The search keeps one offset per
/// diagonal per edit, about d * d of them, so this bounds its memory on a file rewritten wholesale.
const max_edit_distance: usize = 1000;

/// One step of an edit script: a line both texts have, a line only the old one has, or a line only the new one has.
const Op = enum { equal, delete, insert };

/// A step and the line it is about on each side: an insert has no old line and a delete no new one (left 0).
const Edit = struct {
    op: Op,
    old_index: usize = 0,
    new_index: usize = 0,
};

/// Where a step of the search lands on diagonal `k` (x - y = k): the old-text line `x` it reaches, and whether it got
/// there one line down from diagonal `k + 1` - a line inserted - or one line right from `k - 1` - a line deleted.
const Move = struct {
    x: usize,
    is_insert: bool,
};

/// `text` cut into lines, each keeping its '\n' (the last one may have none). Borrows `text`.
fn splitLines(gpa: Allocator, text: []const u8) ![]const []const u8 {
    var lines: ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var start: usize = 0;
    while (start < text.len) {
        const newline: ?usize = indexOfScalarPos(u8, text, start, '\n');
        const end: usize = if (newline) |at| at + 1 else text.len;
        try lines.append(gpa, text[start..end]);
        start = end;
    }
    return lines.toOwnedSlice(gpa);
}

/// The furthest-reaching step onto diagonal `k` in row `d` of the search: one line down from diagonal `k + 1` or one
/// line right from `k - 1`, whichever lands further along, as long as it stays inside both texts - null when neither
/// does. `previous` is row `d - 1`, the furthest `x` on each of its diagonals (index `k + d - 1`, null where that
/// row did not reach); `k_index` is `k + d`. The search and the walk back both ask this, so they agree on every step.
fn moveInto(
    previous: []const ?usize,
    d: usize,
    k_index: usize,
    old_len: usize,
    new_len: usize,
) ?Move {
    var best: ?Move = null;
    // Down from diagonal k + 1, which row d - 1 has when k + 1 <= d - 1. On it, y = x - (k + 1).
    if (k_index + 2 <= 2 * d) {
        if (previous[k_index]) |x| {
            const y: usize = x + d - k_index - 1;
            if (y < new_len) {
                best = .{ .x = x, .is_insert = true };
            }
        }
    }
    // Right from diagonal k - 1, which row d - 1 has when k - 1 >= -(d - 1).
    if (k_index >= 2) {
        if (previous[k_index - 2]) |x| {
            const lands_further: bool = if (best) |down| x + 1 > down.x else true;
            if (x < old_len and lands_further) {
                best = .{ .x = x + 1, .is_insert = false };
            }
        }
    }
    return best;
}

/// Every old line deleted, then every new line inserted: the script for two texts kept nothing of each other.
fn appendReplacement(
    gpa: Allocator,
    old_len: usize,
    new_len: usize,
    old_offset: usize,
    new_offset: usize,
    script: *ArrayList(Edit),
) !void {
    try script.ensureUnusedCapacity(gpa, old_len + new_len);
    for (0..old_len) |index| {
        script.appendAssumeCapacity(.{ .op = .delete, .old_index = old_offset + index });
    }
    for (0..new_len) |index| {
        script.appendAssumeCapacity(.{ .op = .insert, .new_index = new_offset + index });
    }
}

/// The shortest script turning `old` into `new`, appended to `script` with each line index moved on by `old_offset`
/// and `new_offset` - the lines of the common head in front of them. Row `d` of the search holds, for each diagonal
/// `k` in `-d..d`, the furthest old-text line any path of `d` edits reaches on it; the first row that reaches the end
/// of both texts is the shortest script, and the walk back from there replays it. Past `max_edit_distance` edits,
/// `appendReplacement`.
fn appendMiddleScript(
    gpa: Allocator,
    old: []const []const u8,
    new: []const []const u8,
    old_offset: usize,
    new_offset: usize,
    script: *ArrayList(Edit),
) !void {
    if (old.len == 0 or new.len == 0) {
        return appendReplacement(gpa, old.len, new.len, old_offset, new_offset, script);
    }
    var trace: ArrayList([]?usize) = .empty;
    defer {
        for (trace.items) |row| {
            gpa.free(row);
        }
        trace.deinit(gpa);
    }
    const limit: usize = @min(old.len + new.len, max_edit_distance);
    var edit_count: ?usize = null;
    var d: usize = 0;
    search: while (d <= limit) : (d += 1) {
        try trace.ensureUnusedCapacity(gpa, 1);
        const row: []?usize = try gpa.alloc(?usize, 2 * d + 1);
        trace.appendAssumeCapacity(row);
        @memset(row, null);
        var k_index: usize = 0;
        while (k_index <= 2 * d) : (k_index += 2) {
            var x: usize = 0;
            if (d > 0) {
                if (moveInto(trace.items[d - 1], d, k_index, old.len, new.len)) |move| {
                    x = move.x;
                } else {
                    continue; // neither step stays inside the texts: row d does not reach this diagonal
                }
            }
            // y = x - k, where k = k_index - d. Then on down the diagonal, through every line the texts share.
            var y: usize = x + d - k_index;
            while (x < old.len and y < new.len and eql(u8, old[x], new[y])) {
                x += 1;
                y += 1;
            }
            row[k_index] = x;
            if (x == old.len and y == new.len) {
                edit_count = d;
                break :search;
            }
        }
    }
    const total_edits: usize = edit_count orelse {
        return appendReplacement(gpa, old.len, new.len, old_offset, new_offset, script);
    };

    // The walk back from the end of both texts: one edit per row, and the shared lines between edits.
    var reversed: ArrayList(Edit) = .empty;
    defer reversed.deinit(gpa);
    var x: usize = old.len;
    var y: usize = new.len;
    var row_index: usize = total_edits;
    while (row_index > 0) : (row_index -= 1) {
        // k = x - y, so k_index = x - y + d.
        const k_index: usize = x + row_index - y;
        const move: Move = moveInto(trace.items[row_index - 1], row_index, k_index, old.len, new.len).?;
        const landed_y: usize = move.x + row_index - k_index;
        while (x > move.x and y > landed_y) {
            x -= 1;
            y -= 1;
            try reversed.append(gpa, .{ .op = .equal, .old_index = old_offset + x, .new_index = new_offset + y });
        }
        if (move.is_insert) {
            y -= 1;
            try reversed.append(gpa, .{ .op = .insert, .new_index = new_offset + y });
        } else {
            x -= 1;
            try reversed.append(gpa, .{ .op = .delete, .old_index = old_offset + x });
        }
    }
    while (x > 0 and y > 0) {
        x -= 1;
        y -= 1;
        try reversed.append(gpa, .{ .op = .equal, .old_index = old_offset + x, .new_index = new_offset + y });
    }
    try script.ensureUnusedCapacity(gpa, reversed.items.len);
    var index: usize = reversed.items.len;
    while (index > 0) {
        index -= 1;
        script.appendAssumeCapacity(reversed.items[index]);
    }
}

/// The shortest script turning `old` into `new`: the lines both start and end with are equal steps, and only the
/// lines between them are searched.
fn editScript(
    gpa: Allocator,
    old: []const []const u8,
    new: []const []const u8,
) ![]Edit {
    var script: ArrayList(Edit) = .empty;
    errdefer script.deinit(gpa);
    var head: usize = 0;
    while (head < old.len and head < new.len and eql(u8, old[head], new[head])) {
        head += 1;
    }
    var tail: usize = 0;
    while (tail < old.len - head and tail < new.len - head and
        eql(u8, old[old.len - 1 - tail], new[new.len - 1 - tail]))
    {
        tail += 1;
    }
    for (0..head) |index| {
        try script.append(gpa, .{ .op = .equal, .old_index = index, .new_index = index });
    }
    try appendMiddleScript(gpa, old[head .. old.len - tail], new[head .. new.len - tail], head, head, &script);
    for (0..tail) |offset| {
        try script.append(gpa, .{
            .op = .equal,
            .old_index = old.len - tail + offset,
            .new_index = new.len - tail + offset,
        });
    }
    return script.toOwnedSlice(gpa);
}

/// `path` as a diff header names it: forward slashes, no leading `./` - `src/x.zig`, whichever separator the build
/// passed, so the printed diff is one `git apply` takes.
fn writeHeaderPath(out: *Io.Writer, path: []const u8) !void {
    var rest: []const u8 = path;
    if (startsWith(u8, rest, "./") or startsWith(u8, rest, ".\\")) {
        rest = rest[2..];
    }
    for (rest) |byte| {
        try out.writeByte(if (byte == '\\') '/' else byte);
    }
}

/// Prints how `before` became `after` as a unified diff: the `--- a/<path>` and `+++ b/<path>` headers, then one hunk
/// per group of changes, with `context_lines` unchanged lines around it. Nothing when the two are the same. At most
/// `max_printed_changes` changed lines are printed; a last line counts the rest.
pub fn print(
    gpa: Allocator,
    out: *Io.Writer,
    path: []const u8,
    before: []const u8,
    after: []const u8,
) !void {
    if (eql(u8, before, after)) {
        return;
    }
    const old: []const []const u8 = try splitLines(gpa, before);
    defer gpa.free(old);
    const new: []const []const u8 = try splitLines(gpa, after);
    defer gpa.free(new);
    const script: []Edit = try editScript(gpa, old, new);
    defer gpa.free(script);

    try out.writeAll("--- a/");
    try writeHeaderPath(out, path);
    try out.writeAll("\n+++ b/");
    try writeHeaderPath(out, path);
    try out.writeAll("\n");

    var printed: usize = 0;
    var hidden: usize = 0;
    // The lines of each text before `script[cursor]` - where the next hunk's header says it starts.
    var old_seen: usize = 0;
    var new_seen: usize = 0;
    var cursor: usize = 0;
    while (cursor < script.len) {
        var first_change: usize = cursor;
        while (first_change < script.len and script[first_change].op == .equal) {
            first_change += 1;
        }
        if (first_change == script.len) {
            break;
        }
        const hunk_start: usize = @max(cursor, first_change -| context_lines);
        for (script[cursor..hunk_start]) |edit| {
            old_seen += @intFromBool(edit.op != .insert);
            new_seen += @intFromBool(edit.op != .delete);
        }
        // The hunk runs on through every change whose unchanged gap to the one before is at most two contexts:
        // those contexts would touch, so they print as one hunk, as `git diff` prints them.
        var last_change: usize = first_change;
        var scan: usize = first_change;
        while (scan < script.len) {
            if (script[scan].op != .equal) {
                last_change = scan;
                scan += 1;
                continue;
            }
            var run_end: usize = scan;
            while (run_end < script.len and script[run_end].op == .equal) {
                run_end += 1;
            }
            const joins_next_change: bool = run_end < script.len and run_end - scan <= 2 * context_lines;
            if (!joins_next_change) {
                break;
            }
            scan = run_end;
        }
        const hunk_end: usize = @min(last_change + 1 + context_lines, script.len);
        const hunk: []const Edit = script[hunk_start..hunk_end];
        var old_count: usize = 0;
        var new_count: usize = 0;
        for (hunk) |edit| {
            old_count += @intFromBool(edit.op != .insert);
            new_count += @intFromBool(edit.op != .delete);
        }
        if (printed < max_printed_changes) {
            // A side with no line in the hunk names the line before it, as `diff -u` does.
            const old_start: usize = if (old_count > 0) old_seen + 1 else old_seen;
            const new_start: usize = if (new_count > 0) new_seen + 1 else new_seen;
            try out.print("@@ -{d},{d} +{d},{d} @@\n", .{ old_start, old_count, new_start, new_count });
        }
        for (hunk) |edit| {
            const is_change: bool = edit.op != .equal;
            if (printed >= max_printed_changes) {
                if (is_change) {
                    hidden += 1;
                }
                continue;
            }
            if (is_change) {
                printed += 1;
            }
            const line: []const u8 = if (edit.op == .insert) new[edit.new_index] else old[edit.old_index];
            const marker: u8 = switch (edit.op) {
                .equal => ' ',
                .delete => '-',
                .insert => '+',
            };
            try out.writeByte(marker);
            try out.writeAll(line);
            if (!endsWith(u8, line, "\n")) {
                try out.writeAll("\n\\ No newline at end of file\n");
            }
        }
        old_seen += old_count;
        new_seen += new_count;
        cursor = hunk_end;
    }
    if (hidden > 0) {
        try out.print("... and {d} more changed line(s) - `git diff` shows them all\n", .{hidden});
    }
}

/// `print`'s output for `before` -> `after`, as `x.zig`, compared with `expected`.
fn expectDiff(before: []const u8, after: []const u8, expected: []const u8) !void {
    var buffer: Io.Writer.Allocating = .init(testing_allocator);
    defer buffer.deinit();
    try print(testing_allocator, &buffer.writer, "./x.zig", before, after);
    try expectEqualStrings(expected, buffer.written());
}

test "line_diff: the same text prints nothing" {
    try expectDiff("a\nb\n", "a\nb\n", "");
    try expectDiff("", "", "");
}

test "line_diff: one changed line, with three lines of context either side" {
    try expectDiff(
        "a\nb\nc\nd\ne\nf\ng\nh\n",
        "a\nb\nc\nD\ne\nf\ng\nh\n",
        "--- a/x.zig\n+++ b/x.zig\n@@ -1,7 +1,7 @@\n a\n b\n c\n-d\n+D\n e\n f\n g\n",
    );
}

test "line_diff: a line added at the top, one removed at the bottom" {
    try expectDiff(
        "a\nb\n",
        "new\na\n",
        "--- a/x.zig\n+++ b/x.zig\n@@ -1,2 +1,2 @@\n+new\n a\n-b\n",
    );
}

test "line_diff: changes eight unchanged lines apart are two hunks; six apart, one" {
    const before: []const u8 = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n";
    try expectDiff(
        before,
        "X\n2\n3\n4\n5\n6\n7\n8\n9\nY\n",
        "--- a/x.zig\n+++ b/x.zig\n" ++
            "@@ -1,4 +1,4 @@\n-1\n+X\n 2\n 3\n 4\n" ++
            "@@ -7,4 +7,4 @@\n 7\n 8\n 9\n-10\n+Y\n",
    );
    try expectDiff(
        before,
        "1\nX\n3\n4\n5\n6\n7\n8\nY\n10\n",
        "--- a/x.zig\n+++ b/x.zig\n" ++
            "@@ -1,10 +1,10 @@\n 1\n-2\n+X\n 3\n 4\n 5\n 6\n 7\n 8\n-9\n+Y\n 10\n",
    );
}

test "line_diff: a final newline gained shows, as diff -u shows it" {
    try expectDiff(
        "a\nb",
        "a\nb\n",
        "--- a/x.zig\n+++ b/x.zig\n@@ -1,2 +1,2 @@\n a\n-b\n\\ No newline at end of file\n+b\n",
    );
}

test "line_diff: a Windows path prints with forward slashes" {
    var buffer: Io.Writer.Allocating = .init(testing_allocator);
    defer buffer.deinit();
    try print(testing_allocator, &buffer.writer, ".\\src\\x.zig", "a\n", "b\n");
    try expectEqualStrings("--- a/src/x.zig\n+++ b/src/x.zig\n@@ -1,1 +1,1 @@\n-a\n+b\n", buffer.written());
}

test "line_diff: the script is the shortest - a moved block is one delete and one insert per line, no more" {
    const old: []const []const u8 = &.{ "a\n", "b\n", "c\n", "d\n", "e\n" };
    const new: []const []const u8 = &.{ "a\n", "c\n", "d\n", "b\n", "e\n" };
    const script: []Edit = try editScript(testing_allocator, old, new);
    defer testing_allocator.free(script);
    var changes: usize = 0;
    for (script) |edit| {
        changes += @intFromBool(edit.op != .equal);
    }
    try expectEqual(@as(usize, 2), changes);
}
