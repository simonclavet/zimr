//! urdf_import - read a URDF, write a Zig model.
//!
//!     urdf_import <input.urdf> <output.zig> [import-path]
//!
//! Deliberately thin. Everything interesting lives in `src/urdf.zig` where it can be unit
//! tested; this is argument handling and file I/O, so that the importer never needs a
//! process to be exercised.
//!
//! The output is CHECKED IN, not a build artifact. A generated model that only exists
//! during a build cannot be reviewed in a diff - and a diff is exactly how a convention
//! regression gets noticed (section 4i-ter).

const std = @import("std");
const urdf = @import("urdf");

/// Reads a mesh named by the URDF, relative to the URDF's own directory.
///
/// -- `package://` --
///
/// ROS models write `package://robot_description/meshes/link.stl`, which resolves through a
/// package index this tool has no access to. Stripping the scheme and the package name and
/// treating the remainder as a relative path is what works for a checked-out model
/// directory, and it is what most standalone converters do. A path that then does not exist
/// is skipped with a warning rather than guessed at further.
const MeshLoader = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base: []const u8,
    /// Every buffer handed out, freed together at the end - the borrower has no idea how
    /// long `urdf.resolveMeshes` keeps them.
    loaded: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *MeshLoader) void {
        for (self.loaded.items) |bytes| {
            self.gpa.free(bytes);
        }
        self.loaded.deinit(self.gpa);
    }

    fn load(context: *anyopaque, filename: []const u8) ?[]const u8 {
        const self: *MeshLoader = @ptrCast(@alignCast(context));
        var relative: []const u8 = filename;
        if (std.mem.startsWith(u8, relative, "package://")) {
            relative = relative["package://".len..];
            // Drop the package name; what follows is a path inside it.
            if (std.mem.indexOfScalar(u8, relative, '/')) |slash| {
                relative = relative[slash + 1 ..];
            }
        }
        const path: []u8 = std.fs.path.join(self.gpa, &.{ self.base, relative }) catch return null;
        defer self.gpa.free(path);

        const cwd: std.Io.Dir = std.Io.Dir.cwd();
        const bytes: []u8 = cwd.readFileAlloc(self.io, path, self.gpa, .unlimited) catch {
            std.log.warn("cannot read mesh {s}", .{path});
            return null;
        };
        self.loaded.append(self.gpa, bytes) catch {
            self.gpa.free(bytes);
            return null;
        };
        return bytes;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa: std.mem.Allocator = init.gpa;

    var args_list: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (args_list.items) |a| {
            gpa.free(a);
        }
        args_list.deinit(gpa);
    }
    var arg_it: std.process.Args.Iterator =
        try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer arg_it.deinit();
    while (arg_it.next()) |arg| {
        try args_list.append(gpa, try gpa.dupe(u8, arg));
    }
    const args: [][]u8 = args_list.items;

    if (args.len < 3) {
        std.log.err("usage: urdf_import <input.urdf> <output.zig> [import-path]", .{});
        std.process.exit(2);
    }
    const input_path: []const u8 = args[1];
    const output_path: []const u8 = args[2];
    const import_path: []const u8 = if (args.len > 3) args[3] else "../../../robot.zig";

    const io: std.Io = init.io;
    const cwd: std.Io.Dir = std.Io.Dir.cwd();
    const source: []u8 = cwd.readFileAlloc(io, input_path, gpa, .unlimited) catch |err| {
        std.log.err("cannot read {s}: {t}", .{ input_path, err });
        std.process.exit(1);
    };
    defer gpa.free(source);

    var diagnostic: urdf.Diagnostic = .{};
    var robot: urdf.Robot = urdf.parse(gpa, source, &diagnostic) catch |err| {
        // The diagnostic is the whole reason the parser is strict: a refusal should say
        // WHERE and WHY, so the fix is obvious rather than a bisection.
        std.log.err("{s}: {t} — {s} (line {d})", .{
            input_path, err, diagnostic.detail, diagnostic.line,
        });
        std.process.exit(1);
    };
    defer robot.deinit();

    // * Load the collision meshes. This is the ONLY place in the import path that touches a
    // filesystem - `urdf.zig` parses bytes and is handed a callback, which is what lets it
    // be tested without a disk and reused from a build tool, a game or a browser.
    var loader: MeshLoader = .{
        .gpa = gpa,
        .io = io,
        .base = std.fs.path.dirname(input_path) orelse ".",
    };
    defer loader.deinit();
    const resolved: u32 = urdf.resolveMeshes(gpa, &robot, &loader, MeshLoader.load, 128) catch |err| {
        std.log.err("{s}: cannot read a collision mesh — {t}", .{ input_path, err });
        std.process.exit(1);
    };

    // Report what was NOT imported. section 4i's rule: an importer that quietly drops something
    // produces a robot that is subtly the wrong shape, and the person who has to find out
    // why is the person who did not see this line.
    const unresolved: u32 = urdf.meshCount(&robot);
    if (unresolved > 0) {
        std.log.warn(
            "{s}: {d} collision mesh(es) could not be read and were SKIPPED — those links " ++
                "will simulate their inertias but collide with nothing",
            .{ input_path, unresolved },
        );
    }

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const basename: []const u8 = std.fs.path.basename(input_path);
    urdf.emitZig(&aw.writer, &robot, basename, import_path) catch |err| {
        std.log.err("{s}: cannot emit — {t}", .{ input_path, err });
        std.process.exit(1);
    };

    cwd.writeFile(io, .{ .sub_path = output_path, .data = aw.written() }) catch |err| {
        std.log.err("cannot write {s}: {t}", .{ output_path, err });
        std.process.exit(1);
    };

    var joints: u32 = 0;
    for (robot.bodies) |body| {
        if (body.joint != null) {
            joints += 1;
        }
    }
    std.log.info("{s} -> {s}: {d} bodies, {d} joints, {d} collision hulls", .{
        input_path, output_path, robot.bodies.len, joints, resolved,
    });
}
