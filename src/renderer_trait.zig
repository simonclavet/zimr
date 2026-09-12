//! lint:alias renderer_trait
// src/renderer_trait.zig - renderer-polymorphic immediate-mode interface.
// The convention from `notes/claude.md` → Architectural commitments
// → "`gl: anytype` for renderer-polymorphic scene code": scene-
// drawing functions take their renderer as `gl: anytype` and call
// the standard immediate-mode surface (`gl.begin`, `gl.end`,
// `gl.vertex3f`, etc.) on it.  Both the WebGPU backend (WgpuGl)
// and the software rasterizer (`raster`) get the same code path.
// This module provides:
//   - `assertIsGlContext(gl)` - comptime trait check.  Walks the
//     type at compile time and emits a clear `@compileError` if
//     a required method is missing.  Better diagnostic than the
//     "no field named X" errors that bare `anytype` produces at
//     the use site.
//     Translates the method-style API (`gl.begin(.triangles)`)
//     RL_TRIANGLES)`).  Trivial dispatch - every method is a
//     single-line forward.
//   - `SwAdapter` - thin struct wrapping `*raster.Context`.
//     raster already exposes the methods directly, so the adapter
//     mostly forwards 1:1.
//     and to give both adapters identical method shape (so the
//     `anytype` boundary is clean).
// The adapters are zero-overhead - every method monomorphises and
// inlines.  Adding a third renderer is a third adapter struct
// implementing the same surface; no other zimr code changes.

const raster = @import("raster.zig");

// zmath-adoption Z3: `renderer_trait.zig` is fully migrated onto
// `math.zig` (`zmath`).  Its one matrix path (`multMatrix` →
// `matToArr`) used to wrap the matrix in a `matrixToZm` conversion;
// once `Matrix` collapsed to `zm.Mat` that became the identity
// and was deleted.  No `zimrmath.zig` dependency remains.

// ============================================================================
// SECTION 1 - `assertIsGlContext` comptime trait check
// ============================================================================

/// The list of methods every gl-context type must expose.  When a
/// scene function calls `assertIsGlContext(gl)` at the top, the
/// compiler walks this list and verifies each one is present.  If
/// any method is missing the error message names the type AND the
/// missing method - far more useful than the default "no field
/// named X" you'd get at the first use site.
/// The list is intentionally minimal: only the methods scene
/// drawing actually needs.  Setup / teardown methods (texture
/// upload, framebuffer allocation) are renderer-specific and stay
/// out of the trait - the caller binds before calling
/// `drawScene`.
const required_methods: []const []const u8 = &.{
    "begin",
    "end",
    "vertex2f",
    "vertex3f",
    "color4ub",
    "texCoord2f",
    "matrixMode",
    "loadIdentity",
    "multMatrix",
    "frustum",
    "enable",
    "disable",
    "clearColor",
    "clear",
    // Note: `setBlendMode` is intentionally NOT in the trait.  The
    // enum lives in this file and would create a circular import if
    // forced onto the concrete types.  Drawing.zig doesn't need it
    // (it uses raw `enable(.blend)` + per-call `blendFunc`); only
    // the demo's drawScene uses `setBlendMode`, and that path goes
    // through the adapters which DO have it.  Adding `setBlendMode`
    // directly to raster.Context would need a shared
    // `BlendMode` enum somewhere neutral (types.zig?) - filed for
    // follow-up if a polymorphic caller ever needs it.
};

/// Small abstraction over both renderers' blend-mode shapes.  rlgl
/// uses preset `RL_BLEND_*` constants (alpha, additive, etc.) via
/// `rlSetBlendMode`; raster uses a `(src_factor, dst_factor)` pair
/// via `blendFunc`.  This enum names the recipes the demo actually
/// uses; adapters translate to their underlying API.  Extend as
/// needed; both adapters error or fall back on unsupported modes.
pub const BlendMode = SwAdapter.BlendMode;

/// Comptime trait check: error out at compile time if `gl` doesn't
/// expose the renderer interface.  Place this at the top of any
/// `fn drawX(gl: anytype, ...)` function - costs zero runtime,
/// catches typos at the trait boundary instead of buried in use
/// sites.
/// Pattern:
/// ```zig
/// fn drawCube(gl: anytype, t: f32) void {
///     assertIsGlContext(gl);  // comptime - no runtime cost
///     gl.clear(.{ .color = true, .depth = true });
///     // ...
/// }
/// ```
pub fn assertIsGlContext(gl: anytype) void {
    comptime {
        const T: type = @TypeOf(gl);
        // Accept both `T` and `*T` shapes.  Adapters are tiny
        // structs so callers may pass either.
        const Inner: type = if (@typeInfo(T) == .pointer)
            @typeInfo(T).pointer.child
        else
            T;
        for (required_methods) |name| {
            if (!@hasDecl(Inner, name)) {
                @compileError(
                    "type '" ++ @typeName(Inner) ++
                        "' is missing required gl-context method '" ++ name ++
                        "'.  See src/renderer_trait.zig for the full required-method list.",
                );
            }
        }
    }
}

// ============================================================================
// SECTION 2 - `GlAdapter`: rlgl method-style wrapper
// ============================================================================

// ============================================================================
// SECTION 3 - `SwAdapter`: raster method-style wrapper
// ============================================================================

/// Method-style wrapper around `*raster.Context`.  raster already
/// exposes the immediate-mode surface as methods directly, so
/// this adapter mostly forwards 1:1.  Exists for symmetry with
/// `GlAdapter`: scene code constructs an adapter explicitly
/// rather than passing the underlying `*raster.Context`, so the
/// `gl: anytype` boundary is uniform across the two renderers.
/// The raster software-rasterizer adapter. Defined in `SwAdapter.zig` (which
/// has no rlgl dependency) and re-exported here so GL-side `gl: anytype` demos
/// can use it alongside `GlAdapter`. The WebGPU side imports SwAdapter
/// directly, keeping the WGPU build free of the GL backend.
pub const SwAdapter = @import("SwAdapter.zig");

// ============================================================================
// Tests
// ============================================================================

test "assertIsGlContext: SwAdapter satisfies the trait" {
    var dummy_ctx: raster.Context = undefined;
    var adapter: SwAdapter = .init(&dummy_ctx);
    assertIsGlContext(&adapter);
}

// Concrete renderer types satisfy the trait directly — no adapter
// wrap needed.  The whole point: 2D draw code takes `gl: anytype` and
// accepts any renderer at any call site, with zero allocation and
// zero indirection.

test "assertIsGlContext: *raster.Context satisfies the trait directly" {
    var dummy_ctx: raster.Context = undefined;
    assertIsGlContext(&dummy_ctx);
}

test "assertIsGlContext: bare struct without methods would fail at compile time" {
    // Documenting the negative case.  We can't `expectError` a
    // compile-time error, but if you uncomment the line below
    // the test should fail to compile with a clear message
    // pointing at the missing methods.
    //   const Bad = struct {};
    //   var b: Bad = .{};
    //   assertIsGlContext(&b);
    // The compile-error path is exercised manually; we leave
    // this test as a documentation anchor.
}
