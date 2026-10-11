//! lint:alias renderer_trait
//! renderer_trait - the SCENE contract for renderer-polymorphic code, and the software adapter.
//!
//! Scene-drawing functions take their renderer as `gl: anytype` and drive the same immediate-mode
//! surface on either backend - the WebGPU one (`WgpuGl`) or the software rasteriser (`raster`,
//! directly or through `SwAdapter`) - so one function draws the same picture on both (the
//! side-by-side demo does exactly that).
//!
//! Two contracts, one inside the other:
//!   * `types.requireGl` - the 2D drawing surface every draw function in shapes2d / draw2d / text2d /
//!     image draws through: primitives, colour, texture coordinates, the modelview stack, the scissor.
//!   * `requireGlScene` (here) - all of that, plus what a whole scene sets up: the matrix mode, the
//!     camera (`loadIdentity`, `multMatrix`, `frustum`), 3D vertices, and clearing the frame.
//! A backend that cannot do something still declares it, as a `@compileError` saying why - see
//! `types.requireGl`.

const raster = @import("raster.zig");
const types = @import("types.zig");
const requireGl = types.requireGl;

/// The software rasteriser's adapter. Defined in `SwAdapter.zig` (which has no GL dependency) and
/// re-exported here so scene code can name it beside this file's contract; the WebGPU side imports
/// SwAdapter directly, keeping the WGPU build free of anything else here.
pub const SwAdapter = @import("SwAdapter.zig");

/// The blend recipes scene code asks for by name (alpha, additive, ...); each backend translates them
/// to its own mechanism. Extend as needed - a backend errors or falls back on a mode it cannot do.
pub const BlendMode = SwAdapter.BlendMode;

/// What a SCENE function's `gl` must provide: everything `types.requireGl` asks for (the 2D surface),
/// plus the setup a whole scene does -
///
///     matrixMode(mode)              loadIdentity()            multMatrix(m: Mat)
///     frustum(l, r, b, t, n, f)     vertex3f(x, y, z: f32)    clearColor(r, g, b, a: u8)
///     clear(...)
///
/// Call it first in any `fn drawScene(gl: anytype, ...)`: it is comptime only, and a missing method
/// fails right there, by name, instead of deep inside the scene. `setBlendMode` is deliberately NOT
/// part of the contract: only the adapters have it (raster blends through raw `enable(.blend)` and
/// `blendFunc`), and requiring it of `raster.Context` would need the BlendMode enum somewhere both
/// sides can import.
pub fn requireGlScene(gl: anytype) void {
    requireGl(gl);
    const Gl: type = switch (@typeInfo(@TypeOf(gl))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(gl),
    };
    const scene: [7][]const u8 = .{
        "matrixMode", "loadIdentity", "multMatrix", "frustum", "vertex3f", "clearColor", "clear",
    };
    inline for (scene) |method| {
        if (!@hasDecl(Gl, method)) {
            @compileError("scene drawing: a gl needs `" ++ method ++ "`, and " ++ @typeName(Gl) ++
                " has none - declare it, as a @compileError if this backend cannot do it (see renderer_trait)");
        }
    }
}

// ============================================================================
// Tests
// ============================================================================

test "requireGlScene: SwAdapter satisfies the scene contract" {
    var dummy_ctx: raster.Context = undefined;
    var adapter: SwAdapter = .init(&dummy_ctx);
    requireGlScene(&adapter);
}

// A concrete renderer satisfies it directly - no adapter needed. That is the whole point: scene code
// takes `gl: anytype` and accepts any renderer at any call site, with no allocation and no indirection.
test "requireGlScene: *raster.Context satisfies it directly" {
    var dummy_ctx: raster.Context = undefined;
    requireGlScene(&dummy_ctx);
}
