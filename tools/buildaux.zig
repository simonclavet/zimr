//! tools/buildaux.zig — build-time helper CLI for zimr's build graph.
//!
//! The Zig 0.16→0.17 build-system rework (configurer/maker split, devlog
//! 2026-05-26) removed user `makeFn` closures: the maker is a separate
//! release-mode process, so a closure from the configurer can't run there.
//! The custom build steps that used to live in build.zig as `Step` subclasses
//! therefore moved here as subcommands, invoked from the build graph via
//! `addRunArtifact`.  See src/notes/zig17_migration.md.
//!
//! Subcommands (bodies are faithful ports of the old build.zig make fns):
//!   dist-copy                                   mirror zig-out/web -> prebuilt/
//!   check-wgsl-clean  <file>                    non-empty, no __unresolved_, no // ERROR:

const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;

fn printUsage(io: std.Io) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(
        \\usage: buildaux dist-copy
        \\       buildaux check-wgsl-clean <file>
        \\
    , .{}) catch {}; // lint:off catch-suppression: stderr write, best-effort
    w.interface.flush() catch {}; // lint:off catch-suppression: stderr flush, best-effort
}

fn distCopy(io: std.Io, gpa: Allocator) !void {
    const cwd: std.Io.Dir = std.Io.Dir.cwd();
    try cwd.deleteTree(io, "prebuilt");

    var src_dir: std.Io.Dir = try cwd.openDir(io, "zig-out/web", .{ .iterate = true });
    defer src_dir.close(io);

    var walker: std.Io.Dir.Walker = try src_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) {
            continue;
        }
        const dst: []u8 = try std.fs.path.join(gpa, &.{ "prebuilt", entry.path });
        defer gpa.free(dst);
        try entry.dir.copyFile(entry.basename, cwd, dst, io, .{ .make_path = true });
    }

    // GitHub Pages runs Jekyll unless the site root holds `.nojekyll`, and Jekyll silently
    // drops every file or directory whose name starts with `_` or `.`.
    try cwd.writeFile(io, .{ .sub_path = "prebuilt/.nojekyll", .data = "" });
}

fn die(
    io: std.Io,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch {}; // lint:off catch-suppression: stderr write, best-effort
    w.interface.flush() catch {}; // lint:off catch-suppression: stderr flush, best-effort
    std.process.exit(1);
}

fn checkWgslClean(
    io: std.Io,
    gpa: Allocator,
    path: []const u8,
) !void {
    const cwd: std.Io.Dir = std.Io.Dir.cwd();
    const bytes: []const u8 = try cwd.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    if (bytes.len == 0) {
        die(io, "fixture WGSL empty: {s}\n", .{path});
    }
    if (std.mem.indexOf(u8, bytes, "__unresolved_") != null) {
        die(io, "fixture WGSL contains '__unresolved_' placeholder: {s}\n", .{path});
    }
    if (std.mem.indexOf(u8, bytes, "// ERROR:") != null) {
        die(io, "fixture WGSL contains '// ERROR:' marker: {s}\n", .{path});
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa: Allocator = init.gpa;
    const io: std.Io = init.io;

    var args_list: ArrayList([]u8) = .empty;
    defer {
        for (args_list.items) |a| {
            gpa.free(a);
        }
        args_list.deinit(gpa);
    }
    var arg_it: std.process.Args.Iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;

    if (args.len < 2) {
        printUsage(io);
        std.process.exit(2);
    }
    const cmd: []const u8 = args[1];

    if (eql(u8, cmd, "dist-copy")) {
        try distCopy(io, gpa);
    } else if (eql(u8, cmd, "check-wgsl-clean")) {
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        try checkWgslClean(io, gpa, args[2]);
    } else {
        printUsage(io);
        std.process.exit(2);
    }
}

// ---- dist-copy: mirror zig-out/web -> prebuilt/ (port of distCopyMake) ----
// Pure-Zig recursive copy; wipes prebuilt/ first so removed files don't linger, then
// drops a `.nojekyll` marker at the root for GitHub Pages.

// ---- check-wgsl-clean (port of FixtureWgslCheck) ----
// Same gates spv2wgsl --strict enforces: non-empty, no unresolved refs, no
// error markers.
