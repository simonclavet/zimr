//! External-check fixture: typed Zig shaders from the project's src/shaders/.
//! The pipeline compiled them to WGSL; the app embeds that and imports their IO
//! declarations, which is all a real renderer needs from the build.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const shared = @import("shared");
const trivial_vs_io = @import("trivial_vs_io.zig");
const trivial_fs_io = @import("trivial_fs_io.zig");

const trivial_vs_wgsl = @embedFile("trivial_vs.wgsl");
const trivial_fs_wgsl = @embedFile("trivial_fs.wgsl");

comptime {
    _ = trivial_vs_io;
    _ = trivial_fs_io;
}

const State = struct {
    logged: bool = false,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    _ = gpa;
    _ = f;
    s.* = .{};
}

fn deinit(gpa: Allocator, s: *State) void {
    _ = gpa;
    _ = s;
}

fn update(f: *z.Frame, s: *State) void {
    z.clearViewport(f, shared.background);
    if (!s.logged) {
        s.logged = true;
        std.log.info("shaded: vs {d} B, fs {d} B of WGSL", .{ trivial_vs_wgsl.len, trivial_fs_wgsl.len });
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "external check - shaded",
            .width = 640,
            .height = 480,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
