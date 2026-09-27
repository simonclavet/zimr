//! tools/buildaux.zig - build-time helper CLI for zimr's build graph.
//!
//! The Zig 0.16->0.17 build-system rework (configurer/maker split, devlog
//! 2026-05-26) removed user `makeFn` closures: the maker is a separate
//! release-mode process, so a closure from the configurer can't run there.
//! The custom build steps that used to live in build.zig as `Step` subclasses
//! therefore moved here as subcommands, invoked from the build graph via
//! `addRunArtifact`.  See src/notes/zig17_migration.md.
//!
//! Subcommands (bodies are faithful ports of the old build.zig make fns and, for
//! publish-pages, of the old release.bat / release.sh):
//!   dist-copy                                   mirror zig-out/web -> prebuilt/ (minus docs/)
//!   check-wgsl-clean  <file>                    non-empty, no __unresolved_, no // ERROR:
//!   publish-pages     <remote>                  force-push prebuilt/ as the orphan `pages` branch

const std = @import("std");
const ArrayList = std.ArrayList;
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;
const File = std.Io.File;
const allocPrint = std.fmt.allocPrint;

fn printUsage(io: std.Io) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.File.Writer = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(
        \\usage: buildaux dist-copy
        \\       buildaux check-wgsl-clean <file>
        \\       buildaux publish-pages <remote>
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
        // The autodoc bundle (`zig build docs`) is local-only: its sources.tar tops GitHub's
        // 100 MB per-file limit, so the pages push is rejected if it ships.
        if (firstSegmentIs(entry.path, "docs")) {
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

/// `path`'s first segment is `dir`, with either separator (the walker yields `\` on Windows).
fn firstSegmentIs(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) {
        return false;
    }
    if (path.len == dir.len) {
        return true;
    }
    const c: u8 = path[dir.len];
    return c == '/' or c == '\\';
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

/// Runs `argv` (a git command), returning its trimmed stdout. On a non-zero exit it relays git's
/// stderr and fails with `error.PublishFailed`, so `publishPages`' deferred cleanup still runs.
fn runGit(
    io: std.Io,
    arena: Allocator,
    env: ?*const std.process.Environ.Map,
    argv: []const []const u8,
) ![]const u8 {
    const result: std.process.RunResult = try std.process.run(arena, io, .{ .argv = argv, .environ_map = env });
    const git_succeeded: bool = result.term.success();
    if (!git_succeeded) {
        try File.stderr().writeStreamingAll(io, result.stderr);
        const failure_message: []u8 = try allocPrint(arena, "publish-pages: `git {s}` failed\n", .{argv[1]});
        try File.stderr().writeStreamingAll(io, failure_message);
        return error.PublishFailed;
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

/// A full git object id: 40 hex digits (SHA-1) or 64 (SHA-256).
fn isObjectId(text: []const u8) bool {
    const length_fits: bool = text.len == 40 or text.len == 64;
    if (!length_fits) {
        return false;
    }
    for (text) |char| {
        if (!std.ascii.isHex(char)) {
            return false;
        }
    }
    return true;
}

/// Deletes `path`, treating "already gone" as success.
fn deleteIfPresent(io: std.Io, dir: std.Io.Dir, path: []const u8) !void {
    dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn publishPages(
    io: std.Io,
    gpa: Allocator,
    parent_env: *const std.process.Environ.Map,
    remote: []const u8,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const cwd: std.Io.Dir = std.Io.Dir.cwd();

    _ = try runGit(io, arena, null, &.{ "git", "rev-parse", "--is-inside-work-tree" });
    // `dist-copy` writes the marker last, so its presence means the mirror finished.
    const mirror_finished: bool = if (cwd.access(io, "prebuilt/.nojekyll", .{})) |_| true else |_| false;
    if (!mirror_finished) {
        try File.stderr().writeStreamingAll(io, "publish-pages: prebuilt/ is incomplete - run `zig build dist`\n");
        return error.PublishFailed;
    }

    const announcement: []u8 = try allocPrint(
        arena,
        "\nPublishing prebuilt/ to `{s}` as the orphan `pages` branch...\n",
        .{remote},
    );
    try File.stdout().writeStreamingAll(io, announcement);

    // A throwaway index, so neither the working tree nor the real index is ever touched. It lives
    // in this checkout's own git dir (per worktree), not at a fixed temp name two runs could share.
    const index_path: []const u8 = try runGit(io, arena, null, &.{
        "git",
        "rev-parse",
        "--path-format=absolute",
        "--git-path",
        "zimr-pages.index",
    });
    try deleteIfPresent(io, cwd, index_path);
    defer deleteIfPresent(io, cwd, index_path) catch {}; // lint:off catch-suppression: cleanup, next run redoes it
    var env: std.process.Environ.Map = try parent_env.clone(arena);
    try env.put("GIT_INDEX_FILE", index_path);

    // Force past .gitignore - prebuilt/ is ignored on purpose.
    _ = try runGit(io, arena, &env, &.{ "git", "add", "-f", "-A", "--", "prebuilt" });
    // Write the staged tree, then take just its prebuilt/ subtree, so the CONTENTS (index.html,
    // wasm, ...) sit at the branch root rather than under a prebuilt/ subdir.
    const full_tree: []const u8 = try runGit(io, arena, &env, &.{ "git", "write-tree" });
    const subtree_spec: []u8 = try allocPrint(arena, "{s}:prebuilt", .{full_tree});
    const pages_tree: []const u8 = try runGit(io, arena, null, &.{ "git", "rev-parse", subtree_spec });
    // No `-p` parent: a root commit, so the branch is rewritten from scratch each run and never
    // accumulates history - the gallery costs one copy on the remote.
    const pages_commit: []const u8 = try runGit(io, arena, null, &.{
        "git",
        "commit-tree",
        pages_tree,
        "-m",
        "Update pages gallery",
    });
    // An empty source makes `:refs/heads/pages` a DELETE refspec - release.bat could take the site
    // down that way when commit-tree failed unnoticed. Push nothing but a real object id.
    const commit_is_object_id: bool = isObjectId(pages_commit);
    if (!commit_is_object_id) {
        const failure_message: []u8 = try allocPrint(
            arena,
            "publish-pages: commit-tree returned '{s}', not an object id\n",
            .{pages_commit},
        );
        try File.stderr().writeStreamingAll(io, failure_message);
        return error.PublishFailed;
    }

    // Inherited stdio (spawn's default), so git's progress and any credential prompt reach the terminal.
    const refspec: []u8 = try allocPrint(arena, "{s}:refs/heads/pages", .{pages_commit});
    var push: std.process.Child = try std.process.spawn(io, .{
        .argv = &.{ "git", "push", remote, refspec, "--force" },
    });
    const push_term: std.process.Child.Term = try push.wait(io);
    const push_succeeded: bool = push_term.success();
    if (!push_succeeded) {
        const failure_message: []u8 = try allocPrint(
            arena,
            "\npages push failed.  Retry:\n    git push {s} {s} --force\n",
            .{ remote, refspec },
        );
        try File.stderr().writeStreamingAll(io, failure_message);
        return error.PublishFailed;
    }

    try File.stdout().writeStreamingAll(
        io,
        "\nRelease complete.  pages branch updated (main untouched).\n" ++
            "Live gallery: https://simonclavet.github.io/zimr/\n",
    );
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
    } else if (eql(u8, cmd, "publish-pages")) {
        if (args.len != 3) {
            printUsage(io);
            std.process.exit(2);
        }
        publishPages(io, gpa, init.environ_map, args[2]) catch |err| switch (err) {
            // Already explained on stderr; exit without an error-return trace.
            error.PublishFailed => std.process.exit(1),
            else => return err,
        };
    } else {
        printUsage(io);
        std.process.exit(2);
    }
}

// ---- dist-copy: mirror zig-out/web -> prebuilt/ (port of distCopyMake) ----
// Pure-Zig recursive copy; wipes prebuilt/ first so removed files don't linger, skips
// the local-only docs/ subtree, then drops a `.nojekyll` marker at the root for GitHub Pages.

// ---- check-wgsl-clean (port of FixtureWgslCheck) ----
// Same gates spv2wgsl --strict enforces: non-empty, no unresolved refs, no
// error markers.

// ---- publish-pages (port of release.bat / release.sh) ----
// Stages prebuilt/ into a throwaway index, commits its subtree as a parentless commit and
// force-pushes that to <remote>'s `pages` branch; the working tree, the real index and main are
// never touched. Driven by `zig build publish -Dmode=release`, which passes `origin`; the remote
// is an argument so the plumbing can be exercised against a local bare repo.
