//! lint:off import-at-root: test aggregator - every statement here is an
//! import by design, so hoisting 47 bindings adds names without adding
//! any information a reader does not already see.
// src/tests.zig - the host test aggregator.
//
// POLICY (Simon, t1176): every live source file gets
// `std.testing.refAllDecls` so no declaration can rot unanalyzed -
// dead code must either compile or be deleted.  Shallow (not
// recursive): file-level decls are forced; inner namespaces get
// coverage from real call sites + their own tests.  Wasm entry
// roots (spv2wgsl_wasm, wgpu_smoke_test, wgpu_runner) are excluded - they only
// make sense as wasm module roots.
//
// To add a test file:
//   1. Create `src/tests/your_test.zig`
//   2. Add an import line below
//   3. Imports inside the test use `@import("../X.zig")` for sibling
//      modules in `src/`

const std = @import("std");

comptime {
    // ===== Test files (cross-cutting suites) =====
    _ = @import("tests/leak_test.zig");
    _ = @import("tests/multiapp_test.zig");
    _ = @import("tests/features_test.zig");
    _ = @import("tests/ext_storage_test.zig");
    _ = @import("tests/errors_test.zig");
    _ = @import("tests/zimrphysics_stack_test.zig");
    _ = @import("tests/character_walk_test.zig");
    // -- *** SIX FILES THAT WERE NEVER IMPORTED BY ANYTHING (24 tests) --
    //
    // Found by walking the import closure of every test root: these are not in `fast_test_roots`
    // and were not listed here, so they compiled nowhere and ran never. The header's documented
    // exclusions (`spv2wgsl_wasm`, `wgpu_smoke_test`, `wgpu_runner` - wasm module roots) are
    // deliberate and stay out; these six had no such reason. Every dependency they name was
    // already inside this aggregator's closure, so wiring them costs no extra compile.
    //
    // * The same shape as zimrmath having no gate at all: a test that is written and never run
    // is worse than no test, because it reads like coverage.
    _ = @import("tests/shader_enum_test.zig");
    _ = @import("tests/snapshot_regression_test.zig");
    _ = @import("tests/ui_dock_builder_test.zig");
    _ = @import("tests/ui_dock_screenshot_test.zig");
    _ = @import("tests/ui_screenshot_test.zig");
    _ = @import("leakwatch.zig");
    // (The robot family - robot_control, robot_mpc, mjcf, urdf and the rest - is NOT imported here.
    // `src/robot_tests.zig` compiles and runs all of it, and `zig build test` runs that union through
    // `test-fast`. Imported here as well, every robot test ran twice, once in each binary. See
    // `robot_family` below for the half of this that `zimr.zig` would otherwise pull back in.)
    _ = @import("tests/cpu_shadowmap_test.zig");

    // (Removed: tests/spv2wgsl_corpus_test.zig.  Its three tests
    // translated real shaders through the recursive SPIR-V->WGSL emitter,
    // which overflows the default 8MB thread stack on deep fixtures and
    // forced every `zig build test` invocation to run under
    // `ulimit -s unlimited`.  Coverage tradeoff (accepted zimr1233): the
    // 181-fixture Tint corpus regression now runs ONLY via the separate
    // `zig build naga-tint` step (scripts/naga-validate-tint.sh, needs
    // naga); the routine `wgpu-check` gate carries just the 2-case locked
    // web corpus (webtests/transpiler_corpus.zig) plus fixture + smoke.
    // If the full corpus regression is wanted back in-process, wrap it in
    // a `std.Thread.spawn(.{ .stack_size = ... })` rather than the global
    // ulimit footgun.)

    // ===== Source modules whose own `test` blocks must RUN (not just typecheck) =====
    // `refAllDecls` (further down) forces decl *analysis* but does NOT include a
    // file's `test` blocks; `_ = @import` does.  raster_shader carries the
    // software-rasterizer coverage / clip / depth / parity tests.
    _ = @import("raster_shader.zig");

    // ===== spv2wgsl internals (shared SPIR-V->WGSL translator) =====
    // S1: the transpiler is one file; its sections are namespaces.
    std.testing.refAllDecls(@import("spv2wgsl.zig").types);
    std.testing.refAllDecls(@import("spv2wgsl.zig").ir);
    std.testing.refAllDecls(@import("spv2wgsl.zig").block_table);
    std.testing.refAllDecls(@import("spv2wgsl.zig").ir_build);
    std.testing.refAllDecls(@import("spv2wgsl.zig").sccp);
    std.testing.refAllDecls(@import("spv2wgsl.zig").ir_emit);
    std.testing.refAllDecls(@import("spv2wgsl.zig").wgsl_check);
}

/// `zimr.zig`'s re-exports of the robot family - the files `src/robot_tests.zig` compiles and runs.
/// Referencing them from here would pull every one of their tests into this binary as well, so the
/// `zimr.zig` sweep below skips these names. A namespace used as a set, so the check is one
/// `@hasDecl` per name rather than a comptime string loop that would need an eval-branch quota.
/// `robot` itself is not listed: `zimr.zig` aliases two dozen of its functions, which reach it anyway.
/// * A robot file `zimr.zig` exports and this set omits is not lost, only run twice - add it here once
/// `src/robot_tests.zig` imports it.
const robot_family = struct {
    pub const robot_physics: void = {};
    pub const robot_scene: void = {};
    pub const mjcf: void = {};
    pub const robot_mjcf: void = {};
    pub const robot_maximal: void = {};
    pub const robot_gym: void = {};
    pub const robot_dance: void = {};
    pub const robot_track: void = {};
    pub const robot_policy: void = {};
    pub const robot_ppo_track: void = {};
    pub const robot_latent: void = {};
    pub const robot_geno_shapes: void = {};
    pub const robot_geno: void = {};
    pub const robot_latent_kit: void = {};
    pub const robot_track_resident: void = {};
    pub const robot_supertrack: void = {};
    pub const robot_control: void = {};
    pub const robot_mpc: void = {};
};

test {
    std.testing.refAllDecls(@import("BindGroupCache.zig"));
    std.testing.refAllDecls(@import("codecs.zig"));
    std.testing.refAllDecls(@import("compute_host.zig"));
    std.testing.refAllDecls(@import("wgpu.zig").compute_pass);
    std.testing.refAllDecls(@import("dom_input.zig"));
    std.testing.refAllDecls(@import("draw3d.zig"));
    std.testing.refAllDecls(@import("draw3d.zig").draw_points);
    std.testing.refAllDecls(@import("easings.zig"));
    std.testing.refAllDecls(@import("entities.zig"));
    std.testing.refAllDecls(@import("errors.zig"));
    std.testing.refAllDecls(@import("renderer_trait.zig"));
    std.testing.refAllDecls(@import("gpu.zig"));
    std.testing.refAllDecls(@import("gpu_iface.zig"));
    std.testing.refAllDecls(@import("image.zig"));
    std.testing.refAllDecls(@import("Canvas.zig"));
    std.testing.refAllDecls(@import("kompute.zig"));
    std.testing.refAllDecls(@import("draw3d.zig").pbr3d);
    std.testing.refAllDecls(@import("zimrphysics.zig"));
    std.testing.refAllDecls(@import("wgpu.zig").render_pass);
    std.testing.refAllDecls(@import("renderer_2d.zig"));
    std.testing.refAllDecls(@import("raster.zig"));
    std.testing.refAllDecls(@import("SwAdapter.zig"));
    std.testing.refAllDecls(@import("raster_pixel.zig"));
    std.testing.refAllDecls(@import("raster_shader.zig"));
    std.testing.refAllDecls(@import("runtime.zig"));
    std.testing.refAllDecls(@import("shader_runtime_wgpu.zig").shader_compile);
    std.testing.refAllDecls(@import("shader_connect.zig"));
    // shader_interface + zimrmath are NAMED MODULES on the test target
    // (test_mod wires them) - file-importing them here would double-own
    // their graphs (one-file-one-module).  Reference the modules.
    std.testing.refAllDecls(@import("shader_interface"));
    std.testing.refAllDecls(@import("shader_introspect.zig"));
    std.testing.refAllDecls(@import("shader_runtime_wgpu.zig"));
    std.testing.refAllDecls(@import("shapes2d.zig"));
    std.testing.refAllDecls(@import("sound.zig"));
    std.testing.refAllDecls(@import("spv2wgsl.zig"));
    std.testing.refAllDecls(@import("wgpu.zig").storage_buffer);
    std.testing.refAllDecls(@import("sw_runtime.zig"));
    std.testing.refAllDecls(@import("text2d.zig"));
    std.testing.refAllDecls(@import("glyph_atlas.zig"));
    std.testing.refAllDecls(@import("plot.zig"));
    std.testing.refAllDecls(@import("types.zig"));
    std.testing.refAllDecls(@import("ui.zig"));
    std.testing.refAllDecls(@import("utils.zig"));
    std.testing.refAllDecls(@import("web.zig"));
    std.testing.refAllDecls(@import("wgpu.zig"));
    std.testing.refAllDecls(@import("wgpu_app.zig"));
    std.testing.refAllDecls(@import("WgpuGl.zig"));
    std.testing.refAllDecls(@import("wgpu_texture.zig"));
    std.testing.refAllDecls(@import("shader_codegen.zig"));
    // `refAllDecls(zimr.zig)`, minus the robot family (see `robot_family`).
    const zimr = @import("zimr.zig");
    inline for (comptime std.meta.declarations(zimr)) |decl_name| {
        if (!@hasDecl(robot_family, decl_name)) {
            _ = &@field(zimr, decl_name);
        }
    }
    std.testing.refAllDecls(@import("zm"));
}
