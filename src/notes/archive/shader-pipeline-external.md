# zimr_build — Build-time API for downstream projects

zimr exposes its typed-shader pipeline as a public `zimr_build` module so
external `build.zig` files can compile Zig shaders without duplicating
pipeline logic.

## Status

**Phase 3a (current)** — API surface lands. The `ShaderPipeline` struct
moved out of `build.zig` into `src/shader_codegen.zig` and is registered as
`b.addModule("zimr_build", ...)`. Internal call sites (zimr's own
`build.zig`) reach it via a relative `@import("src/shader_codegen.zig")`.

**Phase 3b (not yet shipped)** — cross-platform prebuilts + a standalone
external example repo. Today, external consumers are blocked on:

1. The SPIR-V tools (spirv-opt / spirv-val / spirv-cross) and the
   zspv / zglsl text rewriters are built by zimr's `tools/build.zig`
   subbuild from source. Consumer builds depend transitively on that
   subbuild.
2. The pipeline's tool-path strings (e.g. `"tools/zig-out/bin/spirv-opt"`)
   are relative to zimr's build root. They need to become
   `std.Build.LazyPath` so a consumer can pass the dep's resolved paths.
3. Prebuilt tool binaries exist for `linux-x86_64` only
   (`tools/spirv-prebuilt-linux-x86_64/`). macOS and Windows require
   vendored prebuilts.

When Phase 3b lands, the consumer pattern will be:

```zig
// consumer's build.zig
const std = @import("std");
const zimr_build = @import("zimr_build");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimr_dep = b.dependency("zimr", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{ /* ... */ });
    exe.root_module.addImport("zimr", zimr_dep.module("zimr"));

    const pipeline = zimr_build.ShaderPipeline.init(
        b,
        zimr_dep, // resolves prebuilt tool paths + shader_interface module
    );
    pipeline.addShaderImport(
        exe.root_module,
        b.path("src/my_shader_fs.zig"),
        "my_shader_fs.glsl",
        .{ .iface = b.path("src/my_shader_fs_iface.zig") },
    );

    b.installArtifact(exe);
}
```

```zig
// consumer's build.zig.zon
.{
    .name = .my_project,
    .version = "0.1.0",
    .dependencies = .{
        .zimr = .{
            .url = "https://...",
            .hash = "...",
        },
    },
}
```

## Why this is staged

Cross-compiling SPIRV-Tools (a C++ library) for three platforms from a
single Linux box requires extra zig-cc invocations, careful flag
management, and CI hooks — none of which are needed for zimr's own
single-platform development. Splitting the API surface (Phase 3a) from
the prebuilt vendoring (Phase 3b) lets the surface land and stabilize
while the cross-compile work is scoped independently.

## API surface (current)

Located in `src/shader_codegen.zig`:

- `pub const ShaderPipeline = struct { ... };`
- `pub fn ShaderPipeline.init(b, tools_step, shader_interface_mod)` —
  currently takes internal handles; will accept `*std.Build.Dependency`
  in Phase 3b.
- `pub fn ShaderPipeline.addShader(source, opts) std.Build.LazyPath` —
  returns the LazyPath of the compiled GLSL.
- `pub fn ShaderPipeline.addShaderImport(mod, source, import_name, opts)` —
  convenience that wires the GLSL as an `@embedFile`-able anonymous
  import on `mod`.
- `pub const ShaderPipeline.ShaderOpts = struct { iface: ?std.Build.LazyPath = null };`
  pass `.iface` to enable Phase 2 typed-shader codegen.
