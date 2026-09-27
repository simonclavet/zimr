// build.zig - a project that depends on zimr, built by zimr's `zig build external-check`.
//
// It exists so the package boundary is compiled by SOMETHING: zimr_template drifted
// for months as a separate repo nothing here built against (it is template/ now, built
// by `template-check`). This fixture is the exhaustive one: every way a project wires
// things into an app appears here once; the apps only have to build.
//
//   basic       zn, a shared module, a project asset, a zimr asset, engine WGSL,
//               a mesh baked at build time
//   shaded      typed Zig shaders from src/shaders/
//   four_ways   zimr's own example, taken from the dependency: GPU compute kernels
//               and worker job kernels beside a root that is not in this project
//   test        a host unit test importing zm + zn
//   lint        zimr's linter over src/, gating `check` and `*-standalone`

const std = @import("std");
const zimr = @import("zimr");

pub fn build(b: *std.Build) void {
    // `.lint = .{}`: every .zig under src/, always-on rules only.
    const project: *zimr.Project = .init(b, .{ .lint = .{} });

    const shared: *std.Build.Module = project.addModule(b.path("src/shared.zig"));

    const basic: zimr.Project.AppBuild = project.addApp(.{
        .name = "basic",
        .title = "external check - basic",
        .engine_wgsl = true,
    });
    basic.module.addImport("shared", shared);
    basic.module.addAnonymousImport("hello.txt", .{ .root_source_file = b.path("assets/hello.txt") });
    basic.module.addAnonymousImport("bunny.obj", .{
        .root_source_file = project.zimrPath("examples/shadowmap/bunny.obj"),
    });
    project.bakeMesh(basic.module, project.zimrPath("examples/shadowmap/bunny.obj"), "bunny_proxy", 10, 2);

    const shaded: zimr.Project.AppBuild = project.addApp(.{
        .name = "shaded",
        .title = "external check - shaded",
        .shaders = &.{ "trivial_vs", "trivial_fs" },
    });
    shaded.module.addImport("shared", shared);

    _ = project.addApp(.{
        .name = "four_ways",
        .title = "external check - four ways",
        .root_source_file = project.zimrPath("examples/four_ways/four_ways.zig"),
        .compute_kernels = &.{.{ .basename = "escape_kernel", .entries = &.{"mandel"} }},
        .job_kernels = true,
    });

    project.addTest(b.path("src/util.zig"));
}
