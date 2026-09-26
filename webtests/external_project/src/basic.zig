//! External-check fixture: one app reaching everything a project can wire into it
//! from build.zig. It only has to build; each embed is logged once so the
//! compiler has to produce it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zn = @import("zn");
const shared = @import("shared");
const bunny_proxy = @import("bunny_proxy");

/// A project asset (`app.module.addAnonymousImport`).
const hello_txt = @embedFile("hello.txt");
/// A zimr asset (`project.zimrPath`).
const bunny_obj = @embedFile("bunny.obj");
/// An engine shader (`.engine_wgsl = true`).
const pbr_fs_wgsl = @embedFile("pbr_fs.wgsl");

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
        std.log.info("basic: {d} B text, {d} B obj, {d} B wgsl, {d} baked vertices, zn {}, shared {d}", .{
            hello_txt.len,
            bunny_obj.len,
            pbr_fs_wgsl.len,
            bunny_proxy.vertex_count,
            zn.approxEqAbs(f32, 1.0, 1.05, 0.1),
            shared.answer(),
        });
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "external check - basic",
            .width = 640,
            .height = 480,
            .scale_mode = .responsive,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
};
