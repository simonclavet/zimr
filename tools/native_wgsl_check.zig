//! native_wgsl_check - the build's check that a native program embeds no WGSL.
//!
//! The native host runs SPIR-V only. Given a shader module in WGSL it refuses it, by name - but at run time, when the
//! program first builds that shader, on a machine that may be far from this one. A WGSL shader inside a native program
//! means some build path embedded the browser's form of a shader where the native one belonged, as the engine's
//! shaders embedded for apps once were.
//!
//! WGSL marks each shader stage's entry point with an attribute - `@vertex`, `@fragment` or `@compute` - text that no
//! SPIR-V module contains and no engine code compiled into a native program does. So a native program that contains one
//! embeds WGSL somewhere. This check reads each program after it links, and fails the build at the first marker,
//! printing the text that follows it: usually the shader's own first lines, which name it.
//!
//! Usage: `native_wgsl_check <program>...` (build.zig runs it on every Windows program it builds).

const std = @import("std");
const cli = @import("cli");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Writer = Io.Writer;
const File = Io.File;
const indexOf = std.mem.indexOf;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

/// The attributes that mark a WGSL shader stage's entry point.
const wgsl_entry_markers = [_][]const u8{ "@vertex", "@fragment", "@compute" };

/// How many bytes after a marker are printed: enough for a WGSL entry point's signature.
const excerpt_length: usize = 120;

const CheckArgs = struct {
    programs: []const []const u8 = &.{},
};

const check_cli: cli.Config(CheckArgs) = .{
    .prog = "native_wgsl_check",
    .description = "Fails when a native program embeds WGSL: the native host runs SPIR-V only.",
    .args = .{ .programs = .{ .description = "the native programs to check" } },
};

/// Where a WGSL entry marker was found.
const Found = struct {
    marker: []const u8,
    offset: usize,
};

/// The earliest WGSL entry marker in `bytes`, or null when it holds none.
fn firstMarker(bytes: []const u8) ?Found {
    var earliest: ?Found = null;
    for (wgsl_entry_markers) |marker| {
        const offset: usize = indexOf(u8, bytes, marker) orelse continue;
        const is_earlier: bool = if (earliest) |found| offset < found.offset else true;
        if (is_earlier) {
            earliest = .{ .marker = marker, .offset = offset };
        }
    }
    return earliest;
}

/// Writes `bytes` with every byte outside printable ASCII shown as `.`, so a binary's surroundings print on one line.
fn writePrintable(w: *Writer, bytes: []const u8) Writer.Error!void {
    for (bytes) |byte| {
        const is_printable: bool = byte >= ' ' and byte <= '~';
        try w.writeByte(if (is_printable) byte else '.');
    }
}

pub fn main(init: std.process.Init) !void {
    var arena: ArenaAllocator = .init(init.gpa);
    defer arena.deinit();
    const gpa: Allocator = arena.allocator();
    const io: Io = init.io;
    const cwd: Io.Dir = .cwd();
    const args: CheckArgs = cli.args(&init, CheckArgs, check_cli);
    var aw: Writer.Allocating = .init(gpa);
    const w: *Writer = &aw.writer;
    var failures: usize = 0;
    for (args.programs) |path| {
        const bytes: []const u8 = cwd.readFileAlloc(io, path, gpa, .unlimited) catch {
            try w.print("native-wgsl-check: cannot read {s}\n", .{path});
            failures += 1;
            continue;
        };
        const found: Found = firstMarker(bytes) orelse continue;
        const excerpt_end: usize = @min(bytes.len, found.offset + excerpt_length);
        try w.print("native-wgsl-check: {s} embeds WGSL - a native program must embed SPIR-V only. At byte {d}: ", .{
            path,
            found.offset,
        });
        try writePrintable(w, bytes[found.offset..excerpt_end]);
        try w.writeByte('\n');
        failures += 1;
    }
    if (failures == 0) {
        return;
    }
    try File.stderr().writeStreamingAll(io, aw.written());
    std.process.exit(1);
}

test "native-wgsl-check: finds the earliest entry marker, and none in SPIR-V-like bytes" {
    const shader_text: []const u8 = "struct Out { x: f32 }\n@fragment fn main() {}\n@vertex fn other() {}\n";
    const found: Found = firstMarker(shader_text) orelse return error.MarkerMissed;
    try expectEqualStrings("@fragment", found.marker);
    try expectEqual(@as(usize, 22), found.offset);
    const spirv_like = [_]u8{ 0x03, 0x02, 0x23, 0x07, 0x00, 0x00, 0x01, 0x00, '@', 'x' };
    try expect(firstMarker(&spirv_like) == null);
}
