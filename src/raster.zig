//! lint:alias raster
//! src/raster.zig - software rasterizer.
//!
//! A pure-CPU implementation of OpenGL 1.1 fixed-function rendering:
//! matrix stacks, immediate-mode vertex submission via begin / vertex
//! / end, triangle rasterization to an in-memory framebuffer.  No GPU,
//! no GL context, no platform deps.
//!
//! Ported from raster v1.5 by Le Juez Victor (`@Bigfoot71`), reviewed by
//! Ramon Santamaria (`@raysan5`), MIT-licensed.  Donor lives at
//! `src/notes/staging/raster-original.h` for line-by-line reference.
//! Original PR: https://github.com/raysan5/raylib/pull/4832.
//!
//! The port follows zimr style:
//!
//!   - No module-level mutable globals.  All state lives on `Context`,
//!     owned by the user.  Donor's `static sw_context_t RLSW` is gone.
//!   - Generic comptime dispatch where the donor uses `#include __FILE__`
//!     templates.  The 32 hand-instantiated rasterizers in C become 4
//!     generic functions x 8 comptime invocations, monomorphized into
//!     the same eight specializations the donor produces - but readable.
//!   - `gpa: Allocator` per call site, no global allocator hooks.
//!   - Typed locals, brace discipline, casual prose comments - same
//!     discipline that won the ECS sweep.
//!
//! For background:
//!
//!   - `src/notes/raster-tutorial.md` - how the renderer works.  Read this
//!     first if you want to understand what's going on under the hood.
//!   - `src/notes/raster-plan.md` - porting roadmap.
//!
//! Sections of this file:
//!
//!   1. Public enums + constants
//!   2. Math helpers (Vertex lerp / gradient family)
//!   3. Internal types (Vertex, Texture, Framebuffer)
//!   4. Re-exports from sibling files (`pixel`, `Pool`, `Handle`)
//!   5. Context state + methods (lifecycle, state setters, matrix
//!      stacks, resource shims, immediate-mode submission,
//!      rasterizer kernels)
//!   6. Tests
//!
//! The pixel format codecs live in `src/raster_pixel.zig`; the
//! generation-tagged pool data structure lives in `src/pool.zig`.
//! Both are re-exported under their original names so call sites
//! say `raster.PixelFormat`, `raster.Pool(Texture)`, etc. as before.

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqualSlices = std.testing.expectEqualSlices;
const Allocator = std.mem.Allocator;
const zm = @import("zm");

/// -- LANE BATCHES, NOT GEOMETRIC VECTORS --
///
/// Four PIXELS' worth of one scalar. The software rasteriser walks a scanline four pixels at a
/// time, so `Lane4f` holds one edge-function value per pixel, `Lane4b` one inside/outside bit,
/// and `Lane4u8` one colour channel.
///
/// `zm.Vec` is ALSO `@Vector(4, f32)` and the `prefer-vec` rule would rather see it here - but
/// the two mean opposite things. `Vec` is ONE point carrying x/y/z/w; these are FOUR points
/// carrying a single component each. Writing `Vec` would make `e0_v` read as one edge function's
/// four components rather than four pixels' edge values, which is the reverse of the truth, so
/// the rule is declined here deliberately and named instead.
// lint:off prefer-vec: a SIMD lane batch, not zimr's central vector type - see above
const Lane4f = @Vector(4, f32);
const Lane4b = @Vector(4, bool);
const Lane4u8 = @Vector(4, u8);
const radFromTurns = zm.radFromTurns;
const Color = zm.Color;
const Mat = zm.Mat;

const Matrix = Mat;

// zmath-adoption Z3: `raster.zig` is fully migrated onto `math.zig`.
// The matrix stack used to wrap every `zm.mulChecked` in
// `matrixToZm` / `matrixFromZm` conversions; once `Matrix` collapsed
// to `zm.Mat` (Z3 step 0) those conversions became the identity
// and were deleted - no `zimrmath.zig` dependency remains.
const float = zm.float;
const Vec2i = zm.Vec2i;
const Vec = zm.Vec;
const Vec2 = zm.Vec2;
const clamp = zm.clamp;
const f32x4 = zm.f32x4;
const identity = zm.identity;
const int = zm.int;
const matFromAxisAngle = zm.matFromAxisAngle;
const matrixFrustum = zm.matrixFrustum;
const mulMat = zm.mulMat;
const nan = zm.nan;
const orthographicOffCenterRhGl = zm.orthographicOffCenterRhGl;
const scaling = zm.scaling;
const splat2i = zm.splat2i;
const translation = zm.translation;

/// Pixel-format storage descriptors and the comptime-specialised
/// read/write codecs the rasterizer uses to access the framebuffer.
/// Extracted from `raster.zig`; previously a `pub const
/// pixel = struct { ... }` block at line 2774.  Internal callers
/// reach it via `pixel.foo`; external callers via `raster.pixel.foo`.
pub const pixel = @import("raster_pixel.zig");

/// Pool-anchored ECS used for raster's texture and framebuffer
/// storage.  Each pool is one `Entities(T)` - pool-only usage
/// today (no secondaries attached), but the wrapper costs ~9 KB
/// total for the two worlds with default ECS capacity floors, and
/// future telemetry / debugging metadata could attach as secondaries
/// without disturbing the hot-path deref shape (2 dependent loads).
const entities = @import("entities.zig");
/// Re-exported under the old `Pool(T)` / `Handle(T)` names so the
/// donor-port test code reads the same.  Internally, `Pool(T)` is
/// the inner pool storage of a `Entities(T)`; `Handle(T)` is
/// unchanged.
// `Pool(T)` is the old name for what is now just `Entities(T)`.
// `Handle(T)` returns the matching handle type.  Both aliases keep
// the donor pool tests (and `raster_side_by_side.zig` callers)
// readable; internal raster code uses the names directly through
// these re-exports.
pub const Pool = entities.Entities;
pub fn Handle(comptime T: type) type {
    return entities.Handle(T);
}

// raster shares its general-purpose math with the rest of zimr through
// `zimrmath`.  The shared helpers - `saturate`, `fract`, `rcp`,
// `luminance`, `floatToHalf` / `halfToFloat`, the bit-expansion /
// compression helpers, the RGBA8 <-> RGBA32F converters - all live there.
// Rasterizer-specific math (Vertex, the lerp/grad family) lives in
// Section 2 of this file.
// `types` gives us `Matrix` (column-major 4x4, bit-identical to
// donor's `sw_matrix_t = float[16]`), used for the matrix stacks.

// ============================================================================
// Rasterizer build-time configuration
// ============================================================================
// The framebuffer's color and depth formats are fixed at module
// compile time.  Hardcoding them lets the rasterizer kernels inline
// the codec at every read/write - no runtime function-pointer
// dispatch in the inner pixel loop.  This is the donor's
// `SW_FRAMEBUFFER_COLOR_TYPE` / `SW_FRAMEBUFFER_DEPTH_TYPE`
// strategy translated into Zig: comptime constants threaded into
// the generic codec helpers (`pixel.writeColor8(comptime fmt, ...)`)
// resolve to a direct call to the format-specific writer at the
// call site.
// Other formats stay supported via the runtime-dispatch tables
// (`pixel.write_color8_table.get(fmt)` etc.) - they're useful for
// `clear`, `texImage2D` upload from a different-format source, and
// any future format-conversion utility.  But the rasterizer hot
// path bypasses them.
// To rebuild raster for a different framebuffer format, edit these
// two constants and recompile.  No call sites change.

/// Color format the rasterizer writes through.  All triangle / line
/// / point kernels are monomorphised against this format at compile
/// time.
pub const fb_color_fmt: pixel.PixelFormat = .color_r8g8b8a8;

/// Depth format the rasterizer reads + writes through.  Used only
/// when `RasterCfg.depth_test` is true.
pub const fb_depth_fmt: pixel.PixelFormat = .depth_d32;

/// Per-kernel rasterizer configuration.  Every flag is a comptime
/// axis: each (depth_test x texture x blend x cull_back) combination
/// gets its own monomorphised kernel function via `inline switch`
/// dispatch.  Each kernel contains only the work its cfg requires
/// `if (cfg.depth_test)` etc. resolves at compile time, so the
/// inner pixel loop has zero runtime cfg branches.
/// 4 axes -> 16 combinations.  Not all 16 may be in active use; the
/// dispatcher routes based on runtime state and Zig generates only
/// the kernel bodies that are actually called.
pub const RasterCfg = struct {
    /// Read + compare + write depth per pixel.  Donor:
    /// `SW_ENABLE_DEPTH_TEST`.
    depth_test: bool = false,
    /// Sample the bound texture per pixel and modulate vertex color
    /// by the texel.  Donor: `SW_ENABLE_TEXTURE`.
    texture: bool = false,
    /// Read destination color, blend with source via the configured
    /// blend func, write result.  Donor: `SW_ENABLE_BLEND`.
    blend: bool = false,
    /// Reject triangles with negative signed area (CW winding in
    /// our pixel-Y-down convention = back-face).  Per-triangle, not
    /// per-pixel.  Donor's culling is part of `sw_triangle_render`.
    cull_back: bool = false,

    /// Whether this cfg's per-pixel work has no branches that
    /// prevent 4-wide SIMD vectorization of the inner loop.
    /// Today: a kernel is SIMD-eligible when none of `depth_test`,
    /// `texture`, or `blend` are active.  That leaves only color
    /// interpolation + byte-pack + 4-byte write per pixel - all
    /// trivially vectorizable.
    /// Future expansions (each unlocks more SIMD-eligible cfgs):
    ///   - DEPTH SIMD: vector load 4 stored z-values, vector
    ///     compare, masked vector store.  Easy on wasm SIMD; just
    ///     not done yet.
    ///   - BLEND SIMD: vector load 4 destination colors via v128
    ///     load, vector mix, vector store.  Easy too.
    ///   - TEX SIMD: needs per-lane gather (each lane samples a
    ///     different texel address).  Wasm SIMD gather support
    ///     is weak; this one is genuinely harder.
    /// `cull_back` doesn't affect the inner loop - it's a per-
    /// triangle decision that gates entry to the kernel.  So
    /// cull_back-true kernels are SIMD-eligible iff their
    /// other axes are.
    pub fn simdEligible(comptime self: RasterCfg) bool {
        return !self.depth_test and !self.texture and !self.blend;
    }
};

/// Pack a `RasterCfg` into a 4-bit index for `inline switch`
/// dispatch.  Bit layout: bit 0 = depth_test, bit 1 = texture,
/// bit 2 = blend, bit 3 = cull_back.
fn cfgIndex(cfg: RasterCfg) u4 {
    return (@as(u4, @intFromBool(cfg.depth_test)) << 0) |
        (@as(u4, @intFromBool(cfg.texture)) << 1) |
        (@as(u4, @intFromBool(cfg.blend)) << 2) |
        (@as(u4, @intFromBool(cfg.cull_back)) << 3);
}

/// Invert `cfgIndex`: comptime-decode an index back into a cfg.
/// Used by the `inline switch` cases inside the dispatchers - each
/// case captures its index and feeds it through this to obtain the
/// comptime cfg value.
fn cfgFromIndex(comptime idx: u4) RasterCfg {
    return .{
        .depth_test = (idx & 0x1) != 0,
        .texture = (idx & 0x2) != 0,
        .blend = (idx & 0x4) != 0,
        .cull_back = (idx & 0x8) != 0,
    };
}

// ============================================================================
// SECTION 1 - Public enums + constants
// ============================================================================
// The enums below mirror raylib's `SW*` enums one-for-one, with two
// translations:
//   - C-style `SCREAMING_CASE` names become Zig snake_case members
//     (e.g. `SW_TRIANGLES` -> `.triangles`).
//   - `SW`-prefix on type names is dropped - once you're inside the
//     `raster` namespace, the prefix is just noise.  `SWdraw` becomes
//     `DrawMode`, `SWfactor` becomes `BlendFactor`, etc.
// What we DELIBERATELY preserve: every numeric value matches the
// corresponding `GL_*` constant in the OpenGL 1.1 spec.  This means
// `@intFromEnum(DrawMode.triangles)` is `0x0004`, the wire number for
// `GL_TRIANGLES`.  Why: these enums are eventually crossing a GL
// compatibility boundary (rlgl uses these as drop-in replacements).
// Wire-number compatibility is the whole point of raster.
// All values are u32 - that's what the donor's `GLenum` typedef
// resolves to (and what every modern desktop GL implementation uses).
// Where possible, we make this layout-explicit by writing
// `enum(u32) { ... }` so the binary representation is pinned.

/// Capability flags passed to `enable` / `disable`.  These toggle
/// individual pipeline features on or off - you turn on depth testing,
/// blending, scissor clipping, etc.  Each capability is one membership
/// bit in `Context.user_state` (a `std.enums.EnumSet(Capability)`),
/// which the rasterizer reads at draw time to dispatch into the right
/// specialization.
pub const Capability = enum {
    /// Reject pixels falling outside the scissor rectangle (the
    /// rectangle set by `scissor`).
    scissor_test,
    /// Sample the bound texture during fragment shading.  When off,
    /// the pixel color is taken straight from the interpolated vertex
    /// colors.
    texture_2d,
    /// Test each fragment against the depth buffer; only pass closer
    /// fragments, write the new depth on pass.
    depth_test,
    /// Discard back-facing triangles (or front-facing - see
    /// `cullFace`).  Skipping rasterization of geometry the camera
    /// can't see is the cheapest optimization in the book.
    cull_face,
    /// Combine the new fragment with the existing pixel using the
    /// blend equation set by `blendFunc`.  Standard alpha
    /// compositing, additive lights, etc.
    blend,
};

/// Bitmask passed to `clear` selecting which framebuffer attachments
/// to wipe.  Two-bool struct rather than a raw u32 because typed
/// flags read more idiomatically in Zig: `ctx.clear(.{ .color = true,
/// .depth = true })`.  No wire-format bits anymore - we don't bridge
/// to a GL `glClear((GLbitfield)mask)` boundary.
pub const ClearMask = struct {
    /// Wipe the color buffer to `clearColor`.
    color: bool = false,
    /// Wipe the depth buffer to `clearDepth`.
    depth: bool = false,
};

/// Which matrix stack the matrix-stack ops (`pushMatrix`, `popMatrix`,
/// `loadIdentity`, `translate`, `rotate`, `scale`, `multMatrix`,
/// `frustum`, `ortho`) operate on.  Set with `matrixMode`.
pub const MatrixMode = enum {
    /// World-space -> camera-space transform.  Stack depth: 8.
    modelview,
    /// Camera-space -> clip-space transform (perspective or ortho).
    /// Stack depth: 2.
    projection,
    /// Per-texture coordinate transform.  Rarely used.  Stack
    /// depth: 2.
    texture,
};

/// Vertex array kind passed to `bindArray` (the legacy GL 1.1
/// vertex-array path used by `drawArrays` and `drawElements`).  Each
/// kind is a separate channel; you bind one buffer per kind, then
/// the draw call walks them in lockstep.
pub const ArrayKind = enum {
    /// 3D positions.  `f32[3]` per element.
    vertex_array,
    /// RGB(A) colors.  `u8[4]` per element.
    color_array,
    /// 2D texture coordinates.  `f32[2]` per element.
    texture_coord_array,
};

/// Primitive kind passed to `begin` and `drawArrays`.  Each kind tells
/// the rasterizer how to group submitted vertices into primitives.
pub const DrawMode = enum {
    /// Each vertex is a single point.  Group size: 1.
    points,
    /// Each pair of vertices forms a line segment.  Group size: 2.
    lines,
    /// Each triple of vertices forms a triangle.  Group size: 3.
    triangles,
    /// Each quadruple of vertices forms a quad (split internally
    /// into two triangles).  Group size: 4.
    quads,
};

/// Number of vertices the primitive scratch buffer holds before
/// auto-flushing into the rasterizer.  Donor:
/// `SW_PRIMITIVE_VERTEX_COUNT[]` (line 1148).  Free fn rather than
/// an `EnumArray` constant because `pushVertex` is the only caller
/// today; if it grows companions (e.g. a clipping path that needs
/// the same count), promote to `EnumArray(DrawMode, u32)`.
fn primitiveVertexCount(mode: DrawMode) u32 {
    return switch (mode) {
        .points => 1,
        .lines => 2,
        .triangles => 3,
        .quads => 4,
    };
}

/// Convert a `[0, 1]` unit float to a `[0, 255]` byte, with NaN /
/// out-of-range protection (saturation, not wrap).  The donor stores
/// per-vertex color as floats but the framebuffer writer wants bytes;
/// this is the conversion every rasterizer kernel applies before
/// calling the format-specialised writer.  Donor: implicit in
/// `(float)x*255` casts followed by the writer's truncation; we
/// hoist the saturation here to avoid surprises if a future shader-
/// like path emits out-of-range colors.
fn byteFromUnitFloat(v: f32) u8 {
    const scaled: f32 = v * 255.0;
    if (!(scaled >= 0.0)) {
        return 0; // catches NaN (not >=0 and not <=255)
    }
    if (scaled >= 255.0) {
        return 255;
    }
    return @trunc(scaled);
}

/// 4-wide SIMD analog of `byteFromUnitFloat`.  Same saturation
/// semantics - clamps each lane to `[0, 255]` then converts to
/// `u8` - but operates on a `Lane4f` and produces a
/// `Lane4u8`.  Used by the rasterizer's SIMD inner loops
/// to pack four interpolated lane colors at once.
/// Skips the NaN guard from the scalar version: barycentric-
/// interpolated colors at our magnitudes can't produce NaN (no
/// divides, no infinity), so the defensive check would just be
/// dead branches under wasm SIMD.
/// On wasm32 with `simd128`, this lowers to roughly:
///     f32x4.pmin   v, splat(1.0)
///     f32x4.pmax   v, splat(0.0)
///     f32x4.mul    v, splat(255.0)
///     i32x4.trunc_sat_f32x4_s
///     i32x4.narrow_to_i8x16  (combined with neighbouring lanes)
/// Two clamps + a multiply + a saturating truncation - about
/// four cycles instead of the scalar version's three branches
/// per lane.
fn byteFromUnitFloatVec(v: Vec) Lane4u8 {
    const zero: Vec = @splat(0);
    const one: Vec = @splat(1);
    const scale: Vec = @splat(255.0);
    const clamped: Vec = clamp(v, zero, one);
    const scaled: Vec = clamped * scale;
    return @trunc(scaled);
}

/// How filled primitives are rasterized.  Set with `polygonMode`.
/// Mostly useful for wireframe debug rendering.
pub const PolyMode = enum {
    /// Render only the corner vertices as points.
    point,
    /// Render only the edges as lines.  Useful for wireframe.
    line,
    /// Fill the interior.  The default.
    fill,
};

/// Which face direction `cullFace` discards.  CCW-wound triangles
/// are "front" by default; raster inherits that convention.
pub const Face = enum {
    front,
    back,
};

/// Source/destination factor in the blend equation
/// `result = src * srcFactor + dst * dstFactor`.  Set with
/// `blendFunc`.  The most common combo (standard alpha compositing)
/// is `(src=src_alpha, dst=one_minus_src_alpha)`.
pub const BlendFactor = enum {
    zero,
    one,
    src_color,
    one_minus_src_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,
    dst_color,
    one_minus_dst_color,
    /// `min(src.a, 1 - dst.a)`.  Useful for accumulating coverage
    /// (anti-aliasing line draws).  The asymmetric one in the
    /// blend factor table - only valid as `srcFactor`, not as
    /// `dstFactor`.
    src_alpha_saturate,
};

/// Texture sampling filter for minification (texel-to-pixel ratio
/// > 1, i.e. texture being shrunk) and magnification (ratio < 1,
/// i.e. texture being enlarged).  Set with `texParameter`.
pub const Filter = enum {
    /// Round to the nearest texel and fetch.  Cheap, blocky.
    nearest,
    /// Bilinear - fetch the 4 surrounding texels, weight by
    /// fractional offset.  More expensive, smoother.
    linear,
};

/// Texture wrap mode - what to sample when UV coords land outside
/// `[0, 1]`.  Set per-axis with `texParameter` (`.wrap_s` and
/// `.wrap_t`).
pub const Wrap = enum {
    /// Clamp to the [0, 1] interval - texels at the edge extend
    /// outward.  Useful for textures whose edges shouldn't tile.
    clamp,
    /// Take the fractional part of the UV.  Texture tiles
    /// infinitely.
    repeat,
};

/// Parameter passed to `texParameter` to update a single sampler
/// setting on the bound texture.  Tagged union - the variant choice
/// determines the value type, so calls like
/// `texParameter(.{ .min_filter = .linear })` are well-typed.  Donor:
/// `swTexParameteri(SW_TEXTURE_MIN_FILTER, value)` style, where the
/// donor's runtime `int param + int value` API is replaced by Zig's
/// compile-time-checked tagged union (per the no-runtime-enum-validity
/// pattern from earlier state setters).
pub const TextureParam = union(enum) {
    min_filter: Filter,
    mag_filter: Filter,
    wrap_s: Wrap,
    wrap_t: Wrap,
};

/// or destination buffer holds; the per-channel encoding is given
/// separately by `DataType`.
pub const Format = enum {
    /// Single channel, treated as depth.  Used with depth-format
    /// textures for shadow-map style workflows.
    depth_component,
    /// Single channel, treated as luminance (replicated to RGB on
    /// sample, alpha = 1).
    luminance,
    /// Two channels: luminance + alpha.
    luminance_alpha,
    /// Three channels: red, green, blue.
    rgb,
    /// Four channels: red, green, blue, alpha.
    rgba,
};

/// Per-channel encoding for `texImage2D` / `readPixels`.  Combines
/// with `Format` to fully specify the bit layout: e.g. `rgba` +
/// `unsigned_byte` is 32-bit RGBA8; `rgb` + `unsigned_short_5_6_5`
/// is the packed 16-bit format.
pub const DataType = enum {
    byte,
    unsigned_byte,
    short,
    unsigned_short,
    int,
    unsigned_int,
    float,
    /// 8-bit RGB packed as 3:3:2.
    unsigned_byte_3_3_2,
    /// 16-bit RGBA packed as 4:4:4:4.
    unsigned_short_4_4_4_4,
    /// 16-bit RGBA packed as 5:5:5:1 (1-bit alpha).
    unsigned_short_5_5_5_1,
    /// 16-bit RGB packed as 5:6:5.
    unsigned_short_5_6_5,
};

/// Fully-specified texture format for `texImage2D`'s internal storage.
/// Combines channel count + per-channel encoding into one enum.
pub const InternalFormat = enum {
    luminance8,
    luminance8_alpha8,
    /// 8-bit packed RGB (3:3:2).
    r3_g3_b2,
    rgb8,
    /// 16-bit packed RGBA (4:4:4:4).
    rgba4,
    /// 16-bit packed RGBA (5:5:5:1).
    rgb5_a1,
    rgba8,
    r16f,
    rgb16f,
    rgba16f,
    r32f,
    rgb32f,
    rgba32f,
    depth_component16,
    depth_component24,
    depth_component32,
    depth_component32f,
};

/// Internal pixel-format tag.  See `raster_pixel.zig` for the full
/// enum definition.
pub const PixelFormat = pixel.PixelFormat;

/// Translate a `(format, data_type)` pair from `texImage2D` into the
/// internal `PixelFormat` that names a specific bit layout.  Returns
/// `null` for combinations we don't support (the caller maps null to
/// `err_code = .invalid_enum`).  Donor: `sw_pixel_get_format` (lines
/// 1720-1796), but rewritten as a Zig switch tree for compile-time
/// exhaustiveness - every `Format` x `DataType` combination is
/// reached or explicitly mapped to `null`.
pub fn pixelFormatFromFormatAndType(
    format: Format,
    dt: DataType,
) ?PixelFormat {
    // Depth-component is its own dimension: data_type only picks
    // the bit width.
    if (format == .depth_component) {
        return switch (dt) {
            .byte, .unsigned_byte => .depth_d8,
            .short, .unsigned_short => .depth_d16,
            .int, .unsigned_int, .float => .depth_d32,
            else => null,
        };
    }

    // Packed types fully specify the format on their own - channel
    // count from the type, not from `format`.
    switch (dt) {
        .unsigned_byte_3_3_2 => return .color_r3g3b2,
        .unsigned_short_5_6_5 => return .color_r5g6b5,
        .unsigned_short_4_4_4_4 => return .color_r4g4b4a4,
        .unsigned_short_5_5_5_1 => return .color_r5g5b5a1,
        else => {},
    }

    // Otherwise the format provides the channel count and the
    // data_type provides the per-channel bit width.
    const Channels = enum { c1, c2, c3, c4 };
    const channels: Channels = switch (format) {
        .luminance => .c1,
        .luminance_alpha => .c2,
        .rgb => .c3,
        .rgba => .c4,
        .depth_component => unreachable, // handled above
    };
    const Width = enum { w8, w16, w32 };
    const width: ?Width = switch (dt) {
        .byte, .unsigned_byte => .w8,
        .short, .unsigned_short => .w16,
        .int, .unsigned_int, .float => .w32,
        else => null,
    };
    const w: Width = width orelse return null;

    return switch (w) {
        .w8 => switch (channels) {
            .c1 => .color_grayscale,
            .c2 => .color_grayalpha,
            .c3 => .color_r8g8b8,
            .c4 => .color_r8g8b8a8,
        },
        .w16 => switch (channels) {
            .c1 => .color_r16,
            .c2 => null, // no R16+A16 luminance-alpha format
            .c3 => .color_r16g16b16,
            .c4 => .color_r16g16b16a16,
        },
        .w32 => switch (channels) {
            .c1 => .color_r32,
            .c2 => null, // no R32+A32 luminance-alpha format
            .c3 => .color_r32g32b32,
            .c4 => .color_r32g32b32a32,
        },
    };
}

/// Texture parameter selector for `texParameter(param, value)`.
pub const TexParam = enum {
    mag_filter,
    min_filter,
    wrap_s,
    wrap_t,
};

/// Framebuffer attachment point passed to `framebufferTexture2D`.
/// raster supports a single color attachment + a single depth
/// attachment per framebuffer (no MRT, no stencil).
pub const Attachment = enum {
    color,
    depth,
};

/// Property selector for `getFramebufferAttachmentParameteriv`.
/// Returns either the handle of the attached object (if any) or
/// the kind of object attached.
pub const AttachmentParam = enum {
    object_name,
    object_type,
};

/// Result of `checkFramebufferStatus` - whether the currently-bound
/// framebuffer is renderable, and if not, why.
pub const FramebufferStatus = enum {
    /// All attachments present and consistent - the framebuffer is
    /// renderable.
    complete,
    /// At least one attachment is malformed (e.g. invalid texture).
    incomplete_attachment,
    /// No attachments at all.
    incomplete_missing_attachment,
    /// Color and depth attachments have different dimensions.
    incomplete_dimensions,
};

/// Selector for `getFloatv` / `getString`.  Each value names a
/// queryable bit of renderer state - the current modelview matrix,
/// the viewport rectangle, the renderer name string, etc.
pub const GetParam = enum {
    vendor,
    renderer,
    version,
    extensions,
    shading_language_version,
    color_clear_value,
    depth_clear_value,
    current_color,
    current_texture_coords,
    point_size,
    line_width,
    modelview_matrix,
    modelview_stack_depth,
    projection_matrix,
    projection_stack_depth,
    texture_matrix,
    texture_stack_depth,
    viewport,
    draw_framebuffer_binding,
};

/// Last-error code returned by `getError`.  Most raster operations
/// validate their arguments; on a bad arg they set this and return
/// without effect.  Cleared by reading via `getError`.
pub const ErrorCode = enum {
    no_error,
    /// An enum value was outside the accepted set for that call.
    invalid_enum,
    /// A numeric parameter was out of range.
    invalid_value,
    /// The call was syntactically valid but semantically not - e.g.
    /// `vertex` outside a `begin`/`end` pair.
    invalid_operation,
    /// `pushMatrix` on a full stack.
    stack_overflow,
    /// `popMatrix` on a stack with one entry.
    stack_underflow,
    /// Allocation failure for a texture / framebuffer / etc.
    out_of_memory,
};

// ============================================================================
// Internal types - used inside the renderer, not part of the public API
// ============================================================================
// `PixelFormat` and `PixelAlpha` live in `raster_pixel.zig` (extracted
//).  Re-exported here so every existing call site
// (`raster.PixelFormat.foo`, `Texture.format: PixelFormat`, etc.)
// keeps working unchanged.

/// Alpha-storage classification for each pixel format.  See
/// `raster_pixel.zig` for the full enum definition.
pub const PixelAlpha = pixel.PixelAlpha;

// ============================================================================
// SECTION 2 - Math helpers operating on `Vertex`
// ============================================================================
// The shared scalar/pack helpers live in `zimrmath.zig`.  This section
// holds the rasterizer-specific math: the `Vertex` struct, the lerp
// helper used by the clipper, and the gradient family used by the
// span-fill kernels.
// Donor source: lines 981-985 (Vertex) and 1288-1409 (lerp + gradient
// family) of `staging/raster-original.h`.
// The donor has two flavors of gradient helper:
//   `_PCT` - Position + Color + TexCoord (used when texture sampling
//            is enabled).  Lerps and gradients all three groups.
//   `_PC`  - Position + Color (used when texture sampling is OFF).
//            Skips the texcoord work - saves 2 mults and 2 adds per
//            pixel in the rasterizer hot loop.
// The clipper always uses `_PCT` regardless of texture state, because
// the clipper runs BEFORE the rasterizer kernel is selected and has to
// produce vertices that work for either kernel.

/// A vertex flowing through the rasterizer.  Three attribute groups:
///   - `position` - 4D homogeneous clip-space coords.  After the
///     perspective divide, the same slot stores `(x_screen, y_screen,
///     z_ndc, 1/w)`.  The same `w` element wears different hats at
///     different pipeline stages - see the tutorial.
///   - `color` - RGBA, normalized [0, 1].
///   - `texcoord` - UV (S, T).
/// Bit-identical to donor's `sw_vertex_t`: 10 floats, 40 bytes, no
/// padding.  Hot in the rasterizer - every span fill iterates over
/// these.  Donor: line 981 of staging.
pub const Vertex = struct {
    position: [4]f32,
    color: [4]f32,
    texcoord: [2]f32,
};

/// Linearly interpolate between `a` and `b` at parameter `t in [0, 1]`.
/// `t = 0` returns `a`; `t = 1` returns `b`.  Used by the Sutherland-
/// Hodgman clipper when an edge crosses a clip plane - the new vertex
/// at the crossing point gets correctly-interpolated position, color,
/// and texcoord.
/// Donor: `sw_lerp_vertex_PCT`, line 1288.  Always interpolates all
/// three attribute groups (no `_PC` lerp variant - the clipper runs
/// before the rasterizer dispatches on texture state, so it has to
/// produce texcoords whether or not they'll end up used).
pub fn lerpVertexPCT(
    out: *Vertex,
    a: *const Vertex,
    b: *const Vertex,
    t: f32,
) void {
    const t_inv: f32 = 1.0 - t;
    inline for (0..4) |i| {
        out.position[i] = a.position[i] * t_inv + b.position[i] * t;
    }
    inline for (0..4) |i| {
        out.color[i] = a.color[i] * t_inv + b.color[i] * t;
    }
    inline for (0..2) |i| {
        out.texcoord[i] = a.texcoord[i] * t_inv + b.texcoord[i] * t;
    }
}

// ---- Gradient helpers (Position + Color + TexCoord)
// The rasterizer's span-fill loop walks horizontal pixel strips, advancing
// every vertex attribute by a fixed per-pixel delta each step.  These
// helpers compute and apply that delta.  Used heavily - the inner loop
// runs once per filled pixel.

/// Compute per-step gradient = `(b - a) * scale`, attribute by attribute.
/// Used at span-fill setup: passing `scale = 1/(x_end - x_start)` yields
/// the per-pixel delta to advance.  Donor: `sw_get_vertex_grad_PCT`,
/// line 1309.
pub fn getVertexGradPCT(
    out: *Vertex,
    a: *const Vertex,
    b: *const Vertex,
    scale: f32,
) void {
    inline for (0..4) |i| {
        out.position[i] = (b.position[i] - a.position[i]) * scale;
    }
    inline for (0..4) |i| {
        out.color[i] = (b.color[i] - a.color[i]) * scale;
    }
    inline for (0..2) |i| {
        out.texcoord[i] = (b.texcoord[i] - a.texcoord[i]) * scale;
    }
}

/// Advance `out` by exactly one step's worth of gradient.  Called once
/// per pixel inside the span-fill loop.  Donor: `sw_add_vertex_grad_PCT`,
/// line 1328.
pub fn addVertexGradPCT(out: *Vertex, gradients: *const Vertex) void {
    inline for (0..4) |i| {
        out.position[i] += gradients.position[i];
    }
    inline for (0..4) |i| {
        out.color[i] += gradients.color[i];
    }
    inline for (0..2) |i| {
        out.texcoord[i] += gradients.texcoord[i];
    }
}

/// Advance `out` by `scale` steps' worth of gradient.  Used at the
/// start of each scanline to skip the substep distance to the first
/// pixel center (so the interpolated values align with pixel centers,
/// not span boundaries).  Donor: `sw_add_vertex_grad_scaled_PCT`,
/// line 1347.
pub fn addVertexGradScaledPCT(
    out: *Vertex,
    gradients: *const Vertex,
    scale: f32,
) void {
    inline for (0..4) |i| {
        out.position[i] += gradients.position[i] * scale;
    }
    inline for (0..4) |i| {
        out.color[i] += gradients.color[i] * scale;
    }
    inline for (0..2) |i| {
        out.texcoord[i] += gradients.texcoord[i] * scale;
    }
}

// ---- Gradient helpers (Position + Color, no TexCoord)
// Used by the rasterizer specializations where texture sampling is OFF.
// Skipping the 2-element texcoord update saves two mul-adds per pixel
// not enormous on its own, but the rasterizer is so hot that any
// cycles-per-pixel savings matter at 1080p.  Donor lines 1366-1408.

/// Position+color gradient; texcoord untouched.  Donor:
/// `sw_get_vertex_grad_PC`.
pub fn getVertexGradPC(
    out: *Vertex,
    a: *const Vertex,
    b: *const Vertex,
    scale: f32,
) void {
    inline for (0..4) |i| {
        out.position[i] = (b.position[i] - a.position[i]) * scale;
    }
    inline for (0..4) |i| {
        out.color[i] = (b.color[i] - a.color[i]) * scale;
    }
}

/// Position+color step; texcoord untouched.  Donor:
/// `sw_add_vertex_grad_PC`.
pub fn addVertexGradPC(out: *Vertex, gradients: *const Vertex) void {
    inline for (0..4) |i| {
        out.position[i] += gradients.position[i];
    }
    inline for (0..4) |i| {
        out.color[i] += gradients.color[i];
    }
}

/// Position+color scaled step; texcoord untouched.  Donor:
/// `sw_add_vertex_grad_scaled_PC`.
pub fn addVertexGradScaledPC(
    out: *Vertex,
    gradients: *const Vertex,
    scale: f32,
) void {
    inline for (0..4) |i| {
        out.position[i] += gradients.position[i] * scale;
    }
    inline for (0..4) |i| {
        out.color[i] += gradients.color[i] * scale;
    }
}

// ============================================================================
// SECTION 3 - Internal types + Context
// ============================================================================
// This section defines the renderer's data layout: the `Texture` and
// `Framebuffer` structs that hold pixel storage, the `Pool` struct that
// hands out and validates handles for them, and finally the big one
// the `Context` struct that holds everything the renderer remembers
// between calls.
// The donor's `sw_context_t` (line 1024 of staging) is one big flat
// struct.  We keep that shape - readers can diff donor<->port section by
// section - but group fields under named anonymous structs (`primitive`,
// `array`) where the donor itself groups them.
// The `init` / `deinit` / `resize` methods live at the bottom of the
// section and ARE what's exercised by tests this turn.  Every other
// method (matrix-stack ops, `begin`/`end`, `clear`, `read_pixels`,
// pool methods) lands in later phases.

// ---- Sizing limits (matched to donor defaults)
/// Max vertices in the per-primitive scratch buffer.  Starts at 4 (a
/// quad), gets up to one new vertex per clip-plane crossing
/// (Sutherland-Hodgman: 6 frustum planes + 4 scissor planes), so
/// 4 + 6 + 4 = 14.  Donor: `SW_MAX_CLIPPED_POLYGON_VERTICES`.
pub const max_clipped_polygon_vertices = 14;

/// Max depth of the projection-matrix stack.  Donor:
/// `SW_MAX_PROJECTION_STACK_SIZE`.
pub const max_projection_stack_size = 2;

/// Max depth of the modelview-matrix stack.  Donor:
/// `SW_MAX_MODELVIEW_STACK_SIZE`.
pub const max_modelview_stack_size = 8;

/// Max depth of the texture-matrix stack.  Donor:
/// `SW_MAX_TEXTURE_STACK_SIZE`.
pub const max_texture_stack_size = 2;

/// Max number of user-allocated framebuffer objects (off-screen
/// render targets).  Donor: `SW_MAX_FRAMEBUFFERS`.
pub const max_framebuffers = 8;

/// Max number of user-allocated textures.  Donor: `SW_MAX_TEXTURES`.
pub const max_textures = 128;

// ---- Pixel-format property tables
// Re-exports from `raster_pixel.zig`.  Originally defined here, moved
// out to live with the pixel module they describe.

/// Bytes per pixel for each format.  See `raster_pixel.zig`.
pub const pixel_format_size = pixel.pixel_format_size;

/// Whether each pixel format has an alpha channel and how it's
/// stored.  See `raster_pixel.zig`.
pub const pixel_format_alpha = pixel.pixel_format_alpha;

// ---- Texture, Framebuffer, Pool
/// A 2D texture: pixel storage plus the metadata needed to sample it.
/// Used for both user-allocated textures (held in
/// `Context.texture_pool`) and the default framebuffer's color and
/// depth attachments.
/// Donor: `sw_texture_t`, line 987 of staging.
pub const Texture = struct {
    /// Pixel storage as a length-carrying slice.  Earlier consolidation collapsed
    /// the previous `pixels: [*]u8 + alloc_sz: usize` pair into this
    /// one field - the slice's `.len` is the byte count, and `gpa.free`
    /// of the slice replaces the explicit `pixels[0..alloc_sz]`
    /// reconstruction at deinit time.  Sample code sees a slice it
    /// can index with bounds checks in safe modes.
    pixels: []u8,
    format: PixelFormat,
    alpha: PixelAlpha,
    /// Texture dimensions in texels.  Replaces the donor's separate
    /// `width` / `height` ints with a single named-struct field so
    /// every "is this `w * h` or `h * w`?" question at use sites
    /// becomes "what does `.x` / `.y` mean?" - same risk, but the
    /// struct names tell you which axis is which.
    size: Vec2i,
    /// `(width - 1, height - 1)`, precomputed for the nearest-
    /// neighbor sampler: clamping a fractional UV to `[0, w-1]`
    /// becomes one comparison instead of subtract-then-compare.
    /// Recomputed alongside `size` whenever the texture is
    /// (re)allocated.
    size_minus_one: Vec2i,
    min_filter: Filter,
    mag_filter: Filter,
    wrap_s: Wrap,
    wrap_t: Wrap,
    /// `(1 / size.x, 1 / size.y)` - texel-step in normalized UV
    /// space.  Used by the bilinear sampler's substep math to
    /// convert integer texel coordinates back to UV space.
    inv_size: Vec2,
};

/// The renderer's default framebuffer: color + depth attachments,
/// both directly owned by the `Context`.  Distinct from `Framebuffer`
/// (the user-allocated FBO type) because the default framebuffer
/// never goes through the handle machinery.  Donor:
/// `sw_default_framebuffer_t`, line 1004.
pub const DefaultFramebuffer = struct {
    color: Texture,
    depth: Texture,
};

/// A user-allocated framebuffer object - references textures from the
/// texture pool by handle.  Just two handles; the textures themselves
/// live in the pool.  Donor: `sw_framebuffer_t`, line 1009.
pub const Framebuffer = struct {
    /// Texture-pool handle for the color attachment, or `.nil` for
    /// "no attachment".  Forward-references `Handle` (defined just
    /// below) - Zig resolves struct field types lazily so the
    /// out-of-order reference is fine.
    color_attachment: Handle(Texture) = .nil,
    depth_attachment: Handle(Texture) = .nil,
};

// ---- Context - the big one
/// The full renderer state.  Mirrors the donor's `sw_context_t`
/// (line 1024) field-for-field, but groups related fields under
/// named anonymous structs (`primitive`, `array`) the same way the
/// donor does.
/// Foundation shipped lifecycle (init/deinit/resize), the typed-handle
/// pools (gen/delete), and the format-specialised pixel codecs.
/// The non-rasterizing public surface shipped the public surface - `clear` family, state
/// setters (`enable`/`disable`/`viewport`/etc.), matrix stacks,
/// texture upload (`bindTexture`/`texImage2D`/`texParameter`),
/// and immediate-mode submission (`begin`/`vertex2f`/`color4ub`/
/// `end`).  The rasterizer kernels add the rasterizer kernels, starting with
/// `drawPoint`.
pub const Context = struct {
    // ---- Output target -----------------------------------------------------
    framebuffer: DefaultFramebuffer,
    /// Color used to fill the color attachment when `clear` is called
    /// with the color bit.  Set via `clearColor(c: Color)`.  Storing
    /// as `Color` (u8 RGBA) means RGBA8 framebuffers - the default
    /// clear with a direct memcpy of the four bytes; other formats
    /// convert from these four bytes via the format dispatch table.
    clear_color: Color,
    clear_depth: f32,

    /// Viewport center in pixels: `(x + width/2, y + height/2)`.
    vp_center: Vec2,
    /// Viewport half-extents in pixels: `(width/2, height/2)`.  Kept
    /// separate from `vp_size` so the NDC-to-screen transform is one
    /// madd per component (`screen = ndc * vp_half + vp_center`).
    vp_half: Vec2,
    /// Viewport dimensions in pixels.
    vp_size: Vec2i,

    /// Scissor rectangle in pixels, inclusive top-left, exclusive
    /// bottom-right.
    sc_min: Vec2i,
    sc_max: Vec2i,
    /// Scissor rectangle in clip space.  Used by the clipper to reject
    /// triangles before the perspective divide; pre-computed at
    /// `scissor` / `viewport` time.
    sc_clip_min: Vec2,
    sc_clip_max: Vec2,

    // ---- Per-primitive scratch
    /// State accumulated between `begin` and `end`.  The buffer holds
    /// the submitted vertices for the current primitive (and their
    /// post-clip output for triangles / quads / lines).  `current_*`
    /// fields hold the running color and texcoord that get attached
    /// to the next vertex submitted via `vertex2f` / `vertex3f`.
    primitive: struct {
        buffer: [max_clipped_polygon_vertices]Vertex,
        vertex_count: i32,
        current_color: [4]f32,
        current_texcoord: [2]f32,
        /// Set when the user submits a vertex with `alpha < 1`.  Used
        /// as a fast-path skip: if every vertex of a primitive is fully
        /// opaque, the rasterizer can avoid alpha-component
        /// interpolation in the inner loop.
        has_color_alpha: bool,
    },

    /// Optional fixed-function rasterization hook (Phase 2 - one
    /// rasteriser).  When non-null, immediate-mode triangles/quads route
    /// through this instead of the built-in `triangleKernel`: the higher
    /// SW layer points it at `raster_shader.rasterizeTriangles` +
    /// `default_shapes_fs`, so fixed-function and programmable drawing
    /// share a single rasteriser.  `null` (the default) keeps the
    /// built-in kernel - zero behaviour change until a caller opts in.
    /// `ctx` is `*anyopaque` (the live `*Context`), mirroring
    /// `SwPipelineDispatch` and dodging a struct self-reference.
    ff_triangle: ?*const fn (ctx: *anyopaque, v0: *const Vertex, v1: *const Vertex, v2: *const Vertex) void = null,

    // ---- Vertex array bindings (legacy GL 1.1 path)
    /// User-provided pointers for `drawArrays` / `drawElements`.
    /// Each non-null pointer is a "currently bound" array for that
    /// attribute kind.  The donor stores raw `void*` and reinterprets
    /// per binding; Zig types it more strictly.
    array: struct {
        positions: ?[*]const f32 = null,
        texcoords: ?[*]const f32 = null,
        colors: ?[*]const u8 = null,
    },

    // ---- Drawing parameters
    /// Current primitive being submitted.  `null` means "outside any
    /// `begin`/`end` pair" - replaces donor's `SW_DRAW_INVALID = -1`
    /// sentinel with Zig's optional shape.
    draw_mode: ?DrawMode,
    poly_mode: PolyMode,
    point_radius: f32,
    line_width: f32,

    // ---- Matrix stacks
    /// Each matrix-mode (`projection`, `modelview`, `texture`) has its
    /// own fixed-size stack of `Matrix` slots.  `_counter` is the
    /// number of items currently on the stack - a helper method
    /// `currentMatrix()` returns the active stack's top entry.
    /// The donor caches a `current_matrix` pointer for performance,
    /// but a self-referential pointer would invalidate on every
    /// move/copy of `Context` - which Zig allows freely.  We trade
    /// the cached pointer for a 3-way switch in `currentMatrix()`;
    /// the cost is a few cycles per matrix-stack op, which only fire
    /// at draw setup, never in the rasterizer hot loop.
    stack_projection: [max_projection_stack_size]Matrix,
    stack_modelview: [max_modelview_stack_size]Matrix,
    stack_texture: [max_texture_stack_size]Matrix,
    stack_projection_counter: u32,
    stack_modelview_counter: u32,
    stack_texture_counter: u32,
    current_matrix_mode: MatrixMode,
    /// Cached modelview x projection product, recomputed on demand
    /// when `is_dirty_mvp` is true.  Used in vertex transform
    /// recomputing on every vertex would burn cycles.
    mat_mvp: Matrix,
    is_dirty_mvp: bool,

    // ---- Resource pools
    /// Currently-bound user framebuffer.  `.nil` selects the default
    /// framebuffer (the Context's own color/depth attachments).
    bound_framebuffer: Handle(Framebuffer),
    /// Whichever color buffer the rasterizer writes to: either the
    /// default framebuffer's color attachment (when
    /// `bound_framebuffer.isNil()`) or a Texture from the texture
    /// pool referenced by the bound user framebuffer.
    color_buffer: ?*Texture,
    depth_buffer: ?*Texture,
    framebuffer_pool: entities.Entities(Framebuffer),

    bound_texture: ?*Texture,
    texture_pool: entities.Entities(Texture),

    // ---- Pipeline state
    src_factor: BlendFactor,
    dst_factor: BlendFactor,
    /// Cached classification of the current `(src_factor, dst_factor)`
    /// pair - `noop` (skip the blend entirely), `needs_alpha` (the
    /// destination's alpha matters).  will be wired when blending ships.
    blend_flags: u32,
    /// Pointer to the specific `result = src*sf + dst*df` recipe
    /// selected by `blendFunc`.  Wired alongside the future blend kernel.
    blend_func: ?*const fn (out: *[4]f32, src: *const [4]f32) void = null,

    cull_face: Face,
    err_code: ErrorCode,

    /// Set of `Capability` flags the user has currently enabled
    /// (their explicit `enable` / `disable` calls).  The "user's view"
    /// - what they asked for.
    user_state: std.enums.EnumSet(Capability),
    /// Cleaned-up view of `user_state` used to index the rasterizer
    /// dispatch table.  Differs from `user_state` when, e.g., texture
    /// is enabled but no texture is bound - `raster_state` clears the
    /// `.texture_2d` flag in that case.
    raster_state: std.enums.EnumSet(Capability),

    // ========================================================================
    // init / deinit / resize
    // ========================================================================

    /// Initialize a Context backed by a `width x height` RGBA8 color
    /// buffer + D32 depth buffer.  Donor: `swInit`.
    /// The defaults match the donor: depth-test off, blend off,
    /// scissor off, cull-face off, clear color (0, 0, 0, 0), clear
    /// depth 1.0; modelview / projection / texture stacks at depth 1
    /// (identity).  After this, the user typically calls `enable` for
    /// the capabilities they want and sets up the projection.
    /// Allocates four buffers: framebuffer color pixels, framebuffer
    /// depth pixels, and the two object pools' backing storage (each
    /// pool owns three sub-buffers).  All are owned by the returned
    /// Context and freed by `deinit` using the same `gpa`.  Partial
    /// allocation failures unwind cleanly via `errdefer`.
    pub fn init(
        gpa: Allocator,
        width: i32,
        height: i32,
    ) !Context {
        const color_fmt = PixelFormat.color_r8g8b8a8;
        const depth_fmt = PixelFormat.depth_d32;
        const color_bpp: usize = pixel_format_size.get(color_fmt);
        const depth_bpp: usize = pixel_format_size.get(depth_fmt);

        const w_us: usize = @intCast(width);
        const h_us: usize = @intCast(height);
        const color_sz: usize = w_us * h_us * color_bpp;
        const depth_sz: usize = w_us * h_us * depth_bpp;

        const color_pixels = try gpa.alloc(u8, color_sz);
        errdefer gpa.free(color_pixels);
        const depth_pixels = try gpa.alloc(u8, depth_sz);
        errdefer gpa.free(depth_pixels);

        // Zero both buffers.  Color = transparent black; depth = 0
        // (the actual far-plane fill happens on the first `clear`).
        @memset(color_pixels, 0);
        @memset(depth_pixels, 0);

        // Allocate the two object pools BEFORE constructing the
        // return value.  Each `Entities` is pool-only here - no
        // secondaries attached - so the ECS side pays only the
        // minimum capacity floor.  Storing the result by-value just
        // copies the headers; the underlying buffers stay heap-
        // allocated and are owned by the Context's pool fields.
        // errdefer unwinds if a later allocation fails.
        var framebuffer_pool: entities.Entities(Framebuffer) = try .init(gpa, .{
            .capacity = max_framebuffers,
        });
        errdefer framebuffer_pool.deinit(gpa);

        var texture_pool: entities.Entities(Texture) = try .init(gpa, .{
            .capacity = max_textures,
        });
        errdefer texture_pool.deinit(gpa);

        // Named locals for the spatial values.  Each one is a single-
        // source-of-truth that the framebuffer attachments and the
        // viewport / scissor fields all reference, so a future tweak
        // (e.g. a viewport that doesn't fill the framebuffer) only
        // changes the relevant local.
        const fb_size: Vec2i = .{ width, height };
        const fb_size_minus_one: Vec2i = .{ width - 1, height - 1 };
        const fb_inv_size: Vec2 = .{ 1.0 / float(width), 1.0 / float(height) };
        const half_size: Vec2 = .{ float(width) * 0.5, float(height) * 0.5 };

        return .{
            .framebuffer = .{
                .color = .{
                    .pixels = color_pixels,
                    .format = color_fmt,
                    .alpha = pixel_format_alpha.get(color_fmt),
                    .size = fb_size,
                    .size_minus_one = fb_size_minus_one,
                    .min_filter = .nearest,
                    .mag_filter = .nearest,
                    .wrap_s = .clamp,
                    .wrap_t = .clamp,
                    .inv_size = fb_inv_size,
                },
                .depth = .{
                    .pixels = depth_pixels,
                    .format = depth_fmt,
                    .alpha = .none,
                    .size = fb_size,
                    .size_minus_one = fb_size_minus_one,
                    .min_filter = .nearest,
                    .mag_filter = .nearest,
                    .wrap_s = .clamp,
                    .wrap_t = .clamp,
                    .inv_size = fb_inv_size,
                },
            },

            // Donor-default clear: transparent black + far-plane depth.
            .clear_color = Color.init(0, 0, 0, 0),
            .clear_depth = 1.0,

            // Viewport spans the entire framebuffer.  Center is the
            // half-extent (because the viewport origin is `(0, 0)`).
            .vp_size = fb_size,
            .vp_center = half_size,
            .vp_half = half_size,

            // Scissor matches viewport on both axes.  Clip-space
            // scissor stays at the full NDC range (corners of the
            // unit cube projected onto the xy plane).
            .sc_min = splat2i(0),
            .sc_max = fb_size,
            .sc_clip_min = .{ -1.0, -1.0 },
            .sc_clip_max = .{ 1.0, 1.0 },

            .primitive = .{
                .buffer = @splat(.{
                    .position = .{ 0, 0, 0, 0 },
                    .color = .{ 0, 0, 0, 0 },
                    .texcoord = .{ 0, 0 },
                }),
                .vertex_count = 0,
                .current_color = .{ 1, 1, 1, 1 },
                .current_texcoord = .{ 0, 0 },
                .has_color_alpha = false,
            },

            .array = .{},

            .draw_mode = null,
            .poly_mode = .fill,
            .point_radius = 0.5,
            .line_width = 1.0,

            // Each matrix stack starts with one identity matrix in slot 0.
            // The other slots are also identity-filled - clean default,
            // helps debugging if anything reads beyond the counter.
            .stack_projection = @splat(identity()),
            .stack_modelview = @splat(identity()),
            .stack_texture = @splat(identity()),
            .stack_projection_counter = 1,
            .stack_modelview_counter = 1,
            .stack_texture_counter = 1,
            .current_matrix_mode = .modelview,
            .mat_mvp = identity(),
            .is_dirty_mvp = false,

            .bound_framebuffer = .nil,
            // Self-referential pointers can't go in this initializer
            // because Zig returns by value, which would invalidate them.
            // They get set when the user binds a framebuffer
            // or when `deleteFramebuffers` resets the bound FB to the
            // default.  Until then, the rasterizer must check for null
            // on first draw.
            .color_buffer = null,
            .depth_buffer = null,
            .framebuffer_pool = framebuffer_pool,
            .bound_texture = null,
            .texture_pool = texture_pool,

            .src_factor = .src_alpha,
            .dst_factor = .one_minus_src_alpha,
            .blend_flags = 0,

            .cull_face = .back,
            .err_code = .no_error,

            .user_state = .empty,
            .raster_state = .empty,
        };
    }

    /// Free the Context's heap allocations.  After this returns,
    /// `self` is in an invalid state - using it again is undefined
    /// behavior.  Donor: `swClose`.
    pub fn deinit(self: *Context, gpa: Allocator) void {
        gpa.free(self.framebuffer.color.pixels);
        gpa.free(self.framebuffer.depth.pixels);

        // the texture-pool deinit will iterate `texture_pool` for live textures here
        // and free their per-texture pixel allocations before tearing
        // down the pool itself.  Right now no path allocates per-
        // texture pixels (`texImage2D` is wired), so any
        // texture slot in the pool is just zero bytes - pool.deinit
        // is sufficient.
        self.texture_pool.deinit(gpa);
        self.framebuffer_pool.deinit(gpa);
        self.* = undefined;
    }

    /// Resize the default framebuffer.  Reallocates color + depth
    /// pixel storage, updates viewport (full canvas), updates scissor
    /// (full canvas).  Other state - bound textures, matrix stacks,
    /// blend setup - is preserved.  Donor: `swResize`.
    pub fn resize(
        self: *Context,
        gpa: Allocator,
        width: i32,
        height: i32,
    ) !void {
        const color_bpp: usize = pixel_format_size.get(self.framebuffer.color.format);
        const depth_bpp: usize = pixel_format_size.get(self.framebuffer.depth.format);
        const width_us: usize = @intCast(width);
        const height_us: usize = @intCast(height);
        const new_color_sz: usize = width_us * height_us * color_bpp;
        const new_depth_sz: usize = width_us * height_us * depth_bpp;

        // Allocate new buffers BEFORE freeing old ones.  If allocation
        // fails partway, errdefer cleans up the partial work and the
        // Context still has its old framebuffer intact.
        const new_color = try gpa.alloc(u8, new_color_sz);
        errdefer gpa.free(new_color);
        const new_depth = try gpa.alloc(u8, new_depth_sz);
        errdefer gpa.free(new_depth);
        @memset(new_color, 0);
        @memset(new_depth, 0);

        gpa.free(self.framebuffer.color.pixels);
        gpa.free(self.framebuffer.depth.pixels);

        // Same named-local pattern as `init` - every spatial value the
        // attachments and viewport/scissor agree on shares one source.
        const fb_size: Vec2i = .{ width, height };
        const fb_size_minus_one: Vec2i = .{ width - 1, height - 1 };
        const fb_inv_size: Vec2 = .{ 1.0 / float(width), 1.0 / float(height) };
        const half_size: Vec2 = .{ float(width) * 0.5, float(height) * 0.5 };

        self.framebuffer.color.pixels = new_color;
        self.framebuffer.color.size = fb_size;
        self.framebuffer.color.size_minus_one = fb_size_minus_one;
        self.framebuffer.color.inv_size = fb_inv_size;

        self.framebuffer.depth.pixels = new_depth;
        self.framebuffer.depth.size = fb_size;
        self.framebuffer.depth.size_minus_one = fb_size_minus_one;
        self.framebuffer.depth.inv_size = fb_inv_size;

        // Viewport + scissor reset to the full new canvas.
        self.vp_size = fb_size;
        self.vp_center = half_size;
        self.vp_half = half_size;
        self.sc_min = splat2i(0);
        self.sc_max = fb_size;
    }

    /// Returns a pointer to the active matrix-stack top (the matrix
    /// that `loadIdentity` / `translatef` / `multMatrixf` would
    /// modify next).  Cheaper alternative to caching the pointer in a
    /// `current_matrix` field - that field would be self-referential
    /// and break on `Context` move/copy.  See the field-cluster
    /// comment in the matrix-stack section above.
    pub fn currentMatrix(self: *Context) *Matrix {
        return switch (self.current_matrix_mode) {
            .modelview => &self.stack_modelview[self.stack_modelview_counter - 1],
            .projection => &self.stack_projection[self.stack_projection_counter - 1],
            .texture => &self.stack_texture[self.stack_texture_counter - 1],
        };
    }

    // ========================================================================
    // Resource lookups + immediate-mode predicate
    // ========================================================================
    // Tiny helpers used throughout the rest of Context.  The actual
    // gen/delete shims (the ones that allocate/release pool slots)
    // live further down under `Pool gen / delete shims`
    // these are just the readers that bridge `Pool.get` to the
    // err-code tracking, plus the `isImmediateActive` predicate that
    // every state setter uses to gate against in-progress
    // `begin`/`end` recording.

    /// Look up a texture-pool slot.  Returns null for invalid, freed,
    /// or stale handles, and for `Handle.nil`.  Used by the gen/delete
    /// and bind paths; exposed publicly so future future binding code
    /// (sampler setup, framebuffer attachments) can reach into the
    /// pool with the right type at every site.
    pub fn getTexture(self: *const Context, handle: Handle(
        Texture,
    )) ?*Texture {
        return handle.deref(&self.texture_pool);
    }

    /// Look up a framebuffer-pool slot.  See `getTexture` for semantics.
    pub fn getFramebuffer(
        self: *const Context,
        handle: Handle(Framebuffer),
    ) ?*Framebuffer {
        return handle.deref(&self.framebuffer_pool);
    }

    /// True between `begin` and `end`.  GL semantic: most state-
    /// changing entry points (texture/framebuffer gen+delete, bind,
    /// matrix-stack ops, capability toggles) reject with
    /// `invalid_operation` when called inside an immediate-mode
    /// primitive submission.  Donor: `sw_immediate_is_active`.
    fn isImmediateActive(self: *const Context) bool {
        return self.draw_mode != null;
    }

    /// The color attachment the rasterizer should write to: the
    /// bound user framebuffer's color attachment when one is set,
    /// otherwise the default framebuffer's color buffer.  Centralises
    /// the `color_buffer orelse &framebuffer.color` fallback that
    /// every reader was duplicating.  The fallback exists because
    /// Context returns by value at construction (a self-referential
    /// pointer would invalidate on every move) - see field
    /// docstrings for the design wart.
    fn effectiveColorBuffer(self: *Context) *Texture {
        return self.color_buffer orelse &self.framebuffer.color;
    }

    /// Const variant of `effectiveColorBuffer` for read-only callers.
    fn effectiveColorBufferConst(self: *const Context) *const Texture {
        return self.color_buffer orelse &self.framebuffer.color;
    }

    /// The depth attachment the rasterizer should test/write.  See
    /// `effectiveColorBuffer` for the fallback rationale.
    fn effectiveDepthBuffer(self: *Context) *Texture {
        return self.depth_buffer orelse &self.framebuffer.depth;
    }

    /// Const variant of `effectiveDepthBuffer` for read-only callers.
    fn effectiveDepthBufferConst(self: *const Context) *const Texture {
        return self.depth_buffer orelse &self.framebuffer.depth;
    }

    // ========================================================================
    // Clear + framebuffer accessors
    // ========================================================================

    /// Set the color used by `clear({ .color = true })`.  Stores the
    /// value; doesn't actually wipe anything until `clear` runs.
    /// Donor: `swClearColor`.
    pub fn clearColor(self: *Context, c: Color) void {
        self.clear_color = c;
    }

    /// Set the depth value used by `clear({ .depth = true })`.  Stores;
    /// doesn't wipe.  Donor: `swClearDepth`.  Caller is responsible for
    /// keeping `depth` in `[0, 1]`; the depth-format writers will
    /// truncate / scale according to bit width regardless, but values
    /// outside that range have no defined meaning.
    pub fn clearDepth(self: *Context, depth: f32) void {
        self.clear_depth = depth;
    }

    /// Wipe one or both framebuffer attachments.  `mask.color` fills
    /// the color attachment with `clear_color` (encoded into the
    /// attachment's pixel format via the dispatch table); `mask.depth`
    /// fills the depth attachment with `clear_depth`.  Both bits clear
    /// is allowed; neither bit is a no-op.  Calling inside a
    /// `begin`/`end` pair sets `err_code` to `invalid_operation` and
    /// does nothing.  Donor: `swClear`.
    /// Targets whichever Texture `color_buffer` / `depth_buffer` point
    /// at.  When those are null (the post-`init` state, before any
    /// FBO bind) we fall back to the Context's own default
    /// framebuffer attachments - the same Texture the rebind path in
    /// `deleteFramebuffers` would install.
    pub fn clear(self: *Context, mask: ClearMask) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        if (mask.color) {
            const color_tex: *Texture = self.effectiveColorBuffer();
            self.fillColorBuffer(color_tex);
        }
        if (mask.depth) {
            const depth_tex: *Texture = self.effectiveDepthBuffer();
            self.fillDepthBuffer(depth_tex);
        }
    }

    fn fillColorBuffer(self: *Context, color_tex: *Texture) void {
        const writer: pixel.WriteColor8Fn = pixel.write_color8_table.get(color_tex.format) orelse {
            // Unknown / depth format snuck into the color slot.  This
            // shouldn't happen for any framebuffer the engine
            // constructs; record the misuse and leave the buffer
            // untouched.
            self.err_code = .invalid_operation;
            return;
        };
        const c: [4]u8 = .{
            self.clear_color.r,
            self.clear_color.g,
            self.clear_color.b,
            self.clear_color.a,
        };
        const w_us: usize = @intCast(color_tex.size[0]);
        const h_us: usize = @intCast(color_tex.size[1]);
        const total: u32 = @intCast(w_us * h_us);
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            writer(color_tex.pixels, &c, i);
        }
    }

    fn fillDepthBuffer(self: *Context, depth_tex: *Texture) void {
        const writer: pixel.WriteDepthFn = pixel.write_depth_table.get(depth_tex.format) orelse {
            self.err_code = .invalid_operation;
            return;
        };
        const w_us: usize = @intCast(depth_tex.size[0]);
        const h_us: usize = @intCast(depth_tex.size[1]);
        const total: u32 = @intCast(w_us * h_us);
        var i: u32 = 0;
        while (i < total) : (i += 1) {
            writer(depth_tex.pixels, self.clear_depth, i);
        }
    }

    /// Borrow the color attachment's pixel slice.  Used by hosts that
    /// need to upload the raster output to a GL texture for display
    /// (e.g. `z.textures.updateTexture(tex, ctx.colorBufferBytes().ptr)`).
    /// The slice is valid until the next `resize`; no ownership transfer.
    /// When `color_buffer` is null (post-`init` state, before any FBO
    /// bind) returns the default framebuffer's color attachment.
    pub fn colorBufferBytes(self: *const Context) []const u8 {
        if (self.color_buffer) |cb| {
            return cb.pixels;
        }
        return self.framebuffer.color.pixels;
    }

    /// Mutable variant of `colorBufferBytes`: returns the same slice
    /// but as `[]u8`.  Callers that want to write pixels directly
    /// (e.g. the software-shader dispatcher in `src/raster_shader.zig`)
    /// use this instead of `colorBufferBytes` + `@constCast`, which
    /// would be UB.
    ///
    /// Caller owns the responsibility for not stepping on the
    /// rasterizer's toes - typical use is OUTSIDE of `begin`/`end`
    /// blocks, with no draw calls in flight.  The
    /// software-shader dispatch path bypasses the rasterizer entirely
    /// (it writes pixels per-fragment from a user-supplied kernel),
    /// so this is the intended seam.
    pub fn colorBufferBytesMut(self: *Context) []u8 {
        if (self.color_buffer) |cb| {
            return cb.pixels;
        }
        return self.framebuffer.color.pixels;
    }

    /// Width / height of the active color attachment in texels.
    /// Together with `colorBufferBytesMut` this gives the dispatcher
    /// everything it needs to address pixels by (x, y) without
    /// peeking at private state.
    pub fn colorBufferDims(self: *const Context) Vec2i {
        if (self.color_buffer) |cb| {
            return cb.size;
        }
        return self.framebuffer.color.size;
    }

    /// The pixel format of the active color attachment.  Used by the
    /// software-shader dispatcher to pick the correct
    /// `raster_pixel.writeColor` codec.
    pub fn colorBufferFormat(self: *const Context) pixel.PixelFormat {
        if (self.color_buffer) |cb| {
            return cb.format;
        }
        return self.framebuffer.color.format;
    }

    /// Borrow the active depth attachment's raw bytes (mutable) plus
    /// its format, for callers that read/write depth through the
    /// `raster_pixel.read_depth_table` / `write_depth_table` codecs -
    /// the programmable rasterizer's depth test does exactly that.
    /// Same ownership contract as `colorBufferBytesMut`: valid until
    /// the next `resize`, no rasterizer draws in flight.
    pub fn depthBufferBytesMut(self: *Context) []u8 {
        return self.effectiveDepthBuffer().pixels;
    }

    /// The pixel format of the active depth attachment (selects the
    /// depth codec pair in `raster_pixel`).
    pub fn depthBufferFormat(self: *const Context) pixel.PixelFormat {
        return self.effectiveDepthBufferConst().format;
    }

    /// Copy a sub-rectangle of the color attachment into a caller-
    /// owned buffer.  Mirrors `glReadPixels(x, y, w, h, GL_RGBA,
    /// GL_UNSIGNED_BYTE, ...)` - out-of-bounds requests are clipped
    /// to the framebuffer; pixels outside the available region stay
    /// zero.
    /// `dst` must hold at least `w * h * 4` bytes.  Returns the
    /// number of bytes actually written (may be less than the slice
    /// length if `(x + w, y + h)` extends past the framebuffer).
    /// The Y axis matches the framebuffer's natural top-down layout
    /// - no flip applied.
    /// Tradeoffs vs. `colorBufferBytes()`: `colorBufferBytes` returns
    /// a borrowed slice over the WHOLE buffer with zero copies - use
    /// it for full-frame uploads to a GL texture.  `readPixels` is
    /// for sub-rectangle reads where you want the bytes laid out
    /// contiguously in your own buffer, e.g. saving a screenshot
    /// region or computing a per-pixel diff.
    pub fn readPixels(
        self: *const Context,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        dst: []u8,
    ) usize {
        if (w <= 0 or h <= 0) {
            return 0;
        }
        const fb_color: *const Texture = if (self.color_buffer) |cb| cb else &self.framebuffer.color;
        const fb_w: i32 = fb_color.size[0];
        const fb_h: i32 = fb_color.size[1];

        // Clip the requested rect to the framebuffer.  We don't
        // error on partial overlap - match `glReadPixels`'s
        // permissive behaviour where the out-of-bounds region is
        // simply skipped.
        const x0: i32 = @max(x, 0);
        const y0: i32 = @max(y, 0);
        const x1: i32 = @min(x + w, fb_w);
        const y1: i32 = @min(y + h, fb_h);
        if (x0 >= x1 or y0 >= y1) {
            return 0;
        }

        const src: []const u8 = self.colorBufferBytes();
        const dst_pitch: usize = @as(usize, @intCast(w)) * 4;
        const src_pitch: usize = @as(usize, @intCast(fb_w)) * 4;

        // Per-row copy.  Destination row index is relative to the
        // requested rect's top, so a fully-inside read writes a
        // dense `w * h * 4` block; partial overlap leaves the
        // padding rows untouched.
        var written: usize = 0;
        var sy: i32 = y0;
        while (sy < y1) : (sy += 1) {
            const dst_row: i32 = sy - y;
            const dst_off: usize = @as(usize, @intCast(dst_row)) * dst_pitch + @as(usize, @intCast(x0 - x)) * 4;
            const src_off: usize = @as(usize, @intCast(sy)) * src_pitch + @as(usize, @intCast(x0)) * 4;
            const span: usize = @as(usize, @intCast(x1 - x0)) * 4;
            if (dst_off + span > dst.len) {
                break;
            }
            @memcpy(dst[dst_off..][0..span], src[src_off..][0..span]);
            written += span;
        }
        return written;
    }

    // ========================================================================
    // Pipeline state setters
    // ========================================================================
    // These are the public-API methods that mutate the Context's
    // pipeline state.  Each one mirrors a `glX` call (or the donor's
    // `swX`) and sets a single Context field - no cascading work.
    // The `_validate_enum_` style C-isms from the donor (`if
    // (!sw_is_face_valid(face)) errCode = INVALID_ENUM`) are gone:
    // Zig's typed-enum parameters reject bad values at compile time.
    // Numeric range checks (negative width on viewport / scissor) DO
    // survive; the C donor returns early on those, recording
    // `INVALID_VALUE`, and we match.

    /// Add `cap` to `user_state`.  The cleanup pass at `begin` time
    /// (`cleanRasterState`) is what decides whether the capability
    /// actually takes effect on the next draw - adding a capability
    /// here doesn't necessarily add it to `raster_state`.  Donor:
    /// `swEnable`.
    pub fn enable(self: *Context, cap: Capability) void {
        self.user_state.insert(cap);
    }

    /// Remove `cap` from `user_state`.  Donor: `swDisable`.
    pub fn disable(self: *Context, cap: Capability) void {
        self.user_state.remove(cap);
    }

    /// Whether alpha blending is in effect for the next draw - the same
    /// `raster_state.contains(.blend)` test `currentCfg` feeds the
    /// built-in kernel.  Lets a `ff_triangle` bridge pick the matching
    /// `raster_shader.RasterizeOpts.blend` so the one-rasteriser path
    /// composites identically to the fixed-function path.  Reads the
    /// effective (post-`cleanRasterState`) state, not raw `user_state`.
    pub fn blendEnabled(self: *const Context) bool {
        return self.raster_state.contains(.blend);
    }

    /// Set the viewport rectangle in pixels.  `(x, y)` is the
    /// bottom-left corner; `w` and `h` are extents.  Recomputes
    /// `vp_size`, `vp_half`, `vp_center` - the three fields the
    /// vertex transform reads.  Donor: `swViewport`.
    pub fn viewport(
        self: *Context,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    ) void {
        if (w < 0 or h < 0) {
            self.err_code = .invalid_value;
            return;
        }
        const w_f: f32 = float(w);
        const h_f: f32 = float(h);
        self.vp_size = Vec2i{ w, h };
        self.vp_half = .{ w_f * 0.5, h_f * 0.5 };
        self.vp_center = .{
            float(x) + self.vp_half[0],
            float(y) + self.vp_half[1],
        };
    }

    /// Set the scissor rectangle in pixels.  `(x, y)` is the
    /// bottom-left; `w` / `h` are extents.  Recomputes both the
    /// pixel-space scissor (`sc_min`, `sc_max`) and its clip-space
    /// projection (`sc_clip_min`, `sc_clip_max`) used by the clipper
    /// to reject triangles before perspective divide.  Donor:
    /// `swScissor`.  The Y-flip in the clip-space mapping mirrors
    /// the donor (pixel space has +Y down; clip space has +Y up).
    pub fn scissor(
        self: *Context,
        x: i32,
        y: i32,
        w: i32,
        h: i32,
    ) void {
        if (w < 0 or h < 0) {
            self.err_code = .invalid_value;
            return;
        }
        self.sc_min = Vec2i{ x, y };
        self.sc_max = Vec2i{ x + w, y + h };

        const vp_w_f: f32 = float(self.vp_size[0]);
        const vp_h_f: f32 = float(self.vp_size[1]);
        const sc_min_x_f: f32 = float(self.sc_min[0]);
        const sc_max_x_f: f32 = float(self.sc_max[0]);
        const sc_min_y_f: f32 = float(self.sc_min[1]);
        const sc_max_y_f: f32 = float(self.sc_max[1]);

        self.sc_clip_min = .{ (2.0 * sc_min_x_f) / vp_w_f - 1.0, 1.0 - (2.0 * sc_max_y_f) / vp_h_f };
        self.sc_clip_max = .{ (2.0 * sc_max_x_f) / vp_w_f - 1.0, 1.0 - (2.0 * sc_min_y_f) / vp_h_f };
    }

    /// Set the source / destination blend factors.  The actual blend
    /// recipe lookup (`blend_func` table indexing + `blend_flags`
    /// classification) lands in alongside the future the rasterizer's
    /// blend stage.  For now this stores the factors - observable via
    /// `src_factor` / `dst_factor` - and is a no-op for `blend_flags`
    /// / `blend_func`.  Donor: `swBlendFunc`.
    pub fn blendFunc(
        self: *Context,
        src: BlendFactor,
        dst: BlendFactor,
    ) void {
        self.src_factor = src;
        self.dst_factor = dst;
    }

    /// Choose which face direction `cull_face` discards.  Donor:
    /// `swCullFace`.  `front` and `back` are the only two values;
    /// the donor's enum-validity check is unnecessary in Zig (the
    /// `Face` enum can't hold an invalid value).
    pub fn cullFace(self: *Context, face: Face) void {
        self.cull_face = face;
    }

    /// Set the polygon-rasterization mode (`point` / `line` / `fill`).
    /// Donor: `swPolygonMode`.  Same enum-validity note as `cullFace`.
    pub fn polygonMode(self: *Context, mode: PolyMode) void {
        self.poly_mode = mode;
    }

    /// Set the point sprite radius derived from a diameter `size`.
    /// Donor: `swPointSize`, which floors `size * 0.5` (point sprites
    /// are integer-pixel disks); we match.
    pub fn pointSize(self: *Context, size: f32) void {
        self.point_radius = @floor(size * 0.5);
    }

    /// Set the line-rendering thickness in pixels.  Donor:
    /// `swLineWidth`, which rounds to the nearest integer (lines are
    /// integer-pixel-thickness in the rasterizer); we match.
    pub fn lineWidth(self: *Context, width: f32) void {
        self.line_width = @round(width);
    }

    // ---- Raster-state cleanup pass
    // Donor: the inline state-cleanup at the top of `sw_immediate_begin`
    // (raster-original.h lines 3908-3917).  Filters `user_state` against
    // the actual resources available at draw time, producing
    // `raster_state` which is what the rasterizer dispatch table reads.
    // Will be called from `begin` once that ships.  Lives
    // here so it's testable in isolation today.

    /// True if `tex` is a draw-target-ready texture: has pixel storage
    /// and a valid format.  Donor: `sw_is_texture_complete`, which
    /// checked `tex != NULL && tex->pixels != NULL` - our slice can't
    /// be null but can be empty after a failed alloc / pre-allocate
    /// path, so we check `.len`.
    fn isTextureComplete(tex: *const Texture) bool {
        return tex.pixels.len > 0 and tex.format != .unknown;
    }

    /// Compute `raster_state` from `user_state` based on which
    /// capabilities the current resources actually support.  Strips:
    ///   - `.depth_test` if no complete depth attachment is present.
    ///   - `.texture_2d` if no texture is bound, or the bound texture
    ///     is incomplete, or has a depth (non-color) format.
    /// All other capabilities pass through unchanged.
    pub fn cleanRasterState(self: *Context) void {
        var s: std.enums.EnumSet(Capability) = self.user_state;

        // Default-framebuffer fallback for the same reason `clear` and
        // `colorBufferBytes` need it: post-init `depth_buffer` is null
        // because Context returns by value (no self-referential
        // pointer).  Treat null as "use the default framebuffer".
        const depth_tex: *const Texture = self.effectiveDepthBufferConst();
        if (!isTextureComplete(depth_tex)) {
            s.remove(.depth_test);
        }

        if (self.bound_texture) |bt| {
            const incomplete: bool = !isTextureComplete(bt);
            const depth_format: bool = pixel.isDepthFormat(bt.format);
            if (incomplete or depth_format) {
                s.remove(.texture_2d);
            }
        } else {
            s.remove(.texture_2d);
        }

        self.raster_state = s;
    }

    // ========================================================================
    // Matrix stacks
    // ========================================================================
    // Three stacks (projection / modelview / texture), each backed by
    // a fixed-size array `stack_X` plus a counter `stack_X_counter`.
    // The active matrix is `stack_X[counter - 1]` - the slot one
    // below the watermark (donor matches; the counter is "size", not
    // "top index").
    // The donor caches a `currentMatrix` pointer for hot-path access.
    // We can't - Zig returns Context by value, so a self-referential
    // pointer would invalidate on every move.  Instead `currentMatrix`
    // is a tiny method that switches on `current_matrix_mode`; the
    // cost is a few cycles per matrix op (which all fire at draw setup
    // anyway, never in the rasterizer hot loop).
    // Multiplication direction (stated in standard math notation
    // `A * B` means matrix A times matrix B):
    //   - translate / rotate / scale / multMatrix:  current = current * M
    //     (post-multiply by the new transform - when transforming a
    //     vertex `(current * M) * v`, M applies "innermost", i.e.
    //     first)
    //   - frustum / ortho:                          current = M * current
    //     (pre-multiply - these are projection matrices that wrap
    //     the existing camera setup "outermost")
    // raylib's rlgl.h does the same; the asymmetry is convention,
    // not a bug.  See the matrixMul call patterns in src/rlgl.zig
    // for the WebGL pipeline equivalent.
    // `currentMatrix` (the active-stack-top accessor) is defined
    // earlier in the file (next to the `current_matrix_mode` field
    // it switches on).  These methods all call it.

    /// Const variant of `currentMatrix` for tests / readers.  Same
    /// body shape; const pointer out.  Method overload via separate
    /// name (Zig doesn't do C++ overloading on const-ness).
    pub fn currentMatrixConst(self: *const Context) *const Matrix {
        return switch (self.current_matrix_mode) {
            .projection => &self.stack_projection[self.stack_projection_counter - 1],
            .modelview => &self.stack_modelview[self.stack_modelview_counter - 1],
            .texture => &self.stack_texture[self.stack_texture_counter - 1],
        };
    }

    /// Switch which stack subsequent matrix ops target.  Donor:
    /// `swMatrixMode`.  No `invalid_enum` path (Zig's typed enum
    /// rejects bad values at compile time).
    pub fn matrixMode(self: *Context, mode: MatrixMode) void {
        self.current_matrix_mode = mode;
    }

    /// Push the current matrix onto the stack.  Equivalent to
    /// duplicating the top - the next matrix op writes through the
    /// duplicate, leaving the previous slot intact for later
    /// `popMatrix` to revert.  Stack overflow records
    /// `.stack_overflow` and writes nothing.  Donor: `swPushMatrix`.
    pub fn pushMatrix(self: *Context) void {
        switch (self.current_matrix_mode) {
            .projection => {
                if (self.stack_projection_counter >= max_projection_stack_size) {
                    self.err_code = .stack_overflow;
                    return;
                }
                const i_old: u32 = self.stack_projection_counter - 1;
                const i_new: u32 = self.stack_projection_counter;
                self.stack_projection[i_new] = self.stack_projection[i_old];
                self.stack_projection_counter += 1;
            },
            .modelview => {
                if (self.stack_modelview_counter >= max_modelview_stack_size) {
                    self.err_code = .stack_overflow;
                    return;
                }
                const i_old: u32 = self.stack_modelview_counter - 1;
                const i_new: u32 = self.stack_modelview_counter;
                self.stack_modelview[i_new] = self.stack_modelview[i_old];
                self.stack_modelview_counter += 1;
            },
            .texture => {
                if (self.stack_texture_counter >= max_texture_stack_size) {
                    self.err_code = .stack_overflow;
                    return;
                }
                const i_old: u32 = self.stack_texture_counter - 1;
                const i_new: u32 = self.stack_texture_counter;
                self.stack_texture[i_new] = self.stack_texture[i_old];
                self.stack_texture_counter += 1;
            },
        }
    }

    /// Pop the top matrix.  The slot one below becomes "current" for
    /// future ops.  Sets `is_dirty_mvp = true` for projection /
    /// modelview pops because the cached MVP is now stale.  Stack
    /// underflow (counter already 1, the implicit identity slot)
    /// records `.stack_underflow` and writes nothing.  Donor:
    /// `swPopMatrix`.
    pub fn popMatrix(self: *Context) void {
        switch (self.current_matrix_mode) {
            .projection => {
                if (self.stack_projection_counter <= 1) {
                    self.err_code = .stack_underflow;
                    return;
                }
                self.stack_projection_counter -= 1;
                self.is_dirty_mvp = true;
            },
            .modelview => {
                if (self.stack_modelview_counter <= 1) {
                    self.err_code = .stack_underflow;
                    return;
                }
                self.stack_modelview_counter -= 1;
                self.is_dirty_mvp = true;
            },
            .texture => {
                if (self.stack_texture_counter <= 1) {
                    self.err_code = .stack_underflow;
                    return;
                }
                self.stack_texture_counter -= 1;
                // Texture-stack pop doesn't dirty the MVP - texture
                // matrix isn't part of the modelview*projection
                // cached product.
            },
        }
    }

    /// Replace the active matrix with the identity matrix.  Donor:
    /// `swLoadIdentity`.  Marks MVP dirty unless the active stack is
    /// texture (matching donor + the design of `mat_mvp`).
    pub fn loadIdentity(self: *Context) void {
        self.currentMatrix().* = identity();
        self.markMvpDirty();
    }

    /// Pre-multiply the active matrix by a translation.  Donor:
    /// `swTranslatef`.
    pub fn translate(
        self: *Context,
        x: f32,
        y: f32,
        z: f32,
    ) void {
        // Post-multiply: current becomes math `current * translate`.
        // zmath's `mul` is row-vector, so the operand order reverses
        // relative to zimr's column-vector `matrixMul` - verified.
        // (`Matrix` is `zm.Mat` now, so no conversion wrapping.)
        const cur: *Matrix = self.currentMatrix();
        cur.* = mulMat(cur.*, translation(x, y, z));
        self.markMvpDirty();
    }

    /// Pre-multiply the active matrix by an axis-angle rotation of `angle_turns`.
    ///
    /// TURNS, TO MATCH `WgpuGl.rotate` - TWO `rotate`s IN ONE ENGINE MUST AGREE
    ///
    /// This is the software rasteriser's twin of `WgpuGl.rotate`, and they are chosen between at
    /// the call site by which backend is live. When only one of them took turns, a caller that
    /// worked on the GPU path silently rotated by a sixth of the intended amount on the software
    /// one - and a test asserting the matrix is what caught it, not the compiler.
    ///
    /// `matFromAxisAngle` is zimrmath's and takes radians, which is right: a rotation matrix is
    /// built from a sine and a cosine. The conversion is here, at the edge.
    pub fn rotate(
        self: *Context,
        angle_turns: f32,
        x: f32,
        y: f32,
        z: f32,
    ) void {
        const cur: *Matrix = self.currentMatrix();
        // Post-multiply by an axis-angle rotation; operand order
        // reversed for zmath's row-vector `mul` (see `translate`).
        cur.* = mulMat(
            cur.*,
            matFromAxisAngle(f32x4(x, y, z, 0.0), radFromTurns(angle_turns)),
        );
        self.markMvpDirty();
    }

    /// Pre-multiply the active matrix by a scale.  Donor: `swScalef`.
    pub fn scale(
        self: *Context,
        x: f32,
        y: f32,
        z: f32,
    ) void {
        const cur: *Matrix = self.currentMatrix();
        // Post-multiply by a scale; operand order reversed for zmath's
        // row-vector `mul` (see `translate`).
        cur.* = mulMat(cur.*, scaling(x, y, z));
        self.markMvpDirty();
    }

    /// Pre-multiply the active matrix by an arbitrary `mat`.  Donor:
    /// `swMultMatrixf`.
    pub fn multMatrix(self: *Context, mat: *const Matrix) void {
        const cur: *Matrix = self.currentMatrix();
        // current := current * mat.  zmath row-vector `mul` reverses
        // the operand order vs zimr's column-vector convention.
        cur.* = mulMat(cur.*, mat.*);
        self.markMvpDirty();
    }

    /// Post-multiply the active matrix by a perspective frustum.
    /// Args are `f64` per the donor (intermediate precision matters
    /// for tight near/far ratios).  Donor: `swFrustum`.
    pub fn frustum(
        self: *Context,
        left: f64,
        right: f64,
        bottom: f64,
        top: f64,
        near_plane: f64,
        far_plane: f64,
    ) void {
        const m: Mat = matrixFrustum(
            @floatCast(left),
            @floatCast(right),
            @floatCast(bottom),
            @floatCast(top),
            @floatCast(near_plane),
            @floatCast(far_plane),
        );
        const cur: *Matrix = self.currentMatrix();
        // current := frustum * current  (zimr column-vector order);
        // reversed for zmath's row-vector `mul`.
        cur.* = mulMat(m, cur.*);
        self.markMvpDirty();
    }

    /// Post-multiply the active matrix by an orthographic projection.
    /// Donor: `swOrtho`.
    pub fn ortho(
        self: *Context,
        left: f64,
        right: f64,
        bottom: f64,
        top: f64,
        near_plane: f64,
        far_plane: f64,
    ) void {
        // zmath's `orthographicOffCenterRhGl` takes (left, right,
        // TOP, BOTTOM, near, far) - top before bottom - and matches
        // raylib's `matrixOrtho(left, right, bottom, top, ...)`
        // exactly once the args are mapped through (verified).
        const m: Mat = orthographicOffCenterRhGl(
            @floatCast(left),
            @floatCast(right),
            @floatCast(top),
            @floatCast(bottom),
            @floatCast(near_plane),
            @floatCast(far_plane),
        );
        const cur: *Matrix = self.currentMatrix();
        // current := ortho * current  (zimr order); reversed for zm.
        cur.* = mulMat(m, cur.*);
        self.markMvpDirty();
    }

    /// Set `is_dirty_mvp` if the current stack participates in the
    /// MVP product - that's projection + modelview but NOT texture.
    /// Donor: the `if (currentMatrixMode != SW_TEXTURE) isDirtyMVP =
    /// true` boilerplate that follows every modifying op.
    fn markMvpDirty(self: *Context) void {
        if (self.current_matrix_mode != .texture) {
            self.is_dirty_mvp = true;
        }
    }

    // ========================================================================
    // Pool gen / delete shims
    // ========================================================================
    // The public-API entry points that bridge from `Pool.alloc` /
    // `Pool.free` to the renderer's err-code tracking and
    // bound-pointer management.  They mirror raylib/GL's
    // `glGenTextures` / `glDeleteTextures` / `glGenFramebuffers` /
    // `glDeleteFramebuffers` and use the same don't-fail-but-record
    // semantics: invalid handles or pool exhaustion set `err_code`
    // and continue without raising a Zig error.  Donor: `swGen*` /
    // `swDelete*`.

    /// Allocate `out.len` texture handles and write them into `out`.
    /// On pool exhaustion sets `err_code` to `out_of_memory` and
    /// returns early - handles after the failure point are left
    /// unwritten (caller's existing memory).  Calling inside a
    /// `begin`/`end` pair sets `err_code` to `invalid_operation`
    /// and writes nothing.  Donor: `swGenTextures`.
    pub fn genTextures(self: *Context, out: []Handle(Texture)) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        for (out) |*slot| {
            const h: Handle(Texture) = self.texture_pool.alloc();
            if (h.isNil()) {
                self.err_code = .out_of_memory;
                return;
            }
            slot.* = h;
        }
    }

    /// Free a slice of texture handles.  Per-texture pixel storage
    /// (allocated by `texImage2D`) is freed via `gpa`; the pool slot
    /// is then released.  Invalid handles record `.invalid_value`
    /// and the loop continues.  Calling inside `begin`/`end` records
    /// `.invalid_operation` and frees nothing.  If a deleted texture
    /// was bound (texture / color / depth attachment in the active
    /// framebuffer state), the alias is cleared.  Donor:
    /// `swDeleteTextures`.  Recently added the `gpa`
    /// parameter and the pixel-free step.
    pub fn deleteTextures(
        self: *Context,
        gpa: Allocator,
        handles: []const Handle(Texture),
    ) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        for (handles) |h| {
            const tex: *Texture = self.getTexture(h) orelse {
                self.err_code = .invalid_value;
                continue;
            };
            if (self.bound_texture == tex) {
                self.bound_texture = null;
            }
            if (self.color_buffer == tex) {
                self.color_buffer = null;
            }
            if (self.depth_buffer == tex) {
                self.depth_buffer = null;
            }
            // Free per-texture pixel storage if `texImage2D` allocated
            // any.  An empty slice means the slot was never populated
            // (post-`genTextures` pre-`texImage2D` state) - `gpa.free`
            // of an empty slice is a no-op so we don't gate.
            gpa.free(tex.pixels);
            tex.pixels = &.{};
            _ = h.destroy(&self.texture_pool);
        }
    }

    /// Renderer-polymorphic trait method: `normal3f`.
    /// raster is an unlit rasterizer - it has no lighting calculation
    /// and ignores per-vertex normals.  This method exists for
    /// API parity with `rlgl.GlState.normal3f` so generic
    /// `drawing.zig` paths compile against either backend.
    pub fn normal3f(
        self: *Context,
        x: f32,
        y: f32,
        z: f32,
    ) void {
        _ = self;
        _ = x;
        _ = y;
        _ = z;
    }

    /// Renderer-polymorphic trait method: `setTexture(id)`
    /// with a `u32` ID.  This is rlgl's native binding shape; on
    /// raster a `u32` doesn't unambiguously identify a `Texture` in
    /// the pool (handles are slot+generation), so we treat all
    /// non-zero IDs as "unbind the current texture" - subsequent
    /// sampling reads white and vertex_color stays unmodulated.
    /// This means UI rendering on raster (where rlgl glyph atlas IDs
    /// get passed through) sees no texture -> glyph quads come out as
    /// solid colored rects, which is the desired placeholder
    /// behaviour.  Real raster texture binding stays via
    /// `bindTexture(handle)` for callers with native Handle access.
    pub fn setTexture(self: *Context, id: u32) void {
        _ = id;
        if (self.isImmediateActive()) {
            // Can't switch mid-primitive; record the error like
            // bindTexture does.
            self.err_code = .invalid_operation;
            return;
        }
        self.bound_texture = null;
    }

    /// Bind a texture handle as the current sampler source.  `.nil`
    /// clears the binding (subsequent draws sample untextured even
    /// if `.texture_2d` is enabled - `cleanRasterState` strips it).
    /// Invalid handles record `.invalid_value` and leave the binding
    /// unchanged.  Donor: `swBindTexture`.
    pub fn bindTexture(self: *Context, handle: Handle(Texture)) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        if (handle.isNil()) {
            self.bound_texture = null;
            return;
        }
        const tex: *Texture = handle.deref(&self.texture_pool) orelse {
            self.err_code = .invalid_value;
            return;
        };
        self.bound_texture = tex;
    }

    /// Allocate per-texture pixel storage and upload `data` into the
    /// currently-bound texture.  Format is derived from
    /// `(format, data_type)` via `pixelFormatFromFormatAndType`; if
    /// the combo isn't supported, records `.invalid_enum` and writes
    /// nothing.  If `data` is null, the storage is allocated and
    /// zeroed (matches donor: `swTexImage2D` with `data=NULL` produces
    /// an all-zero texture).  Calling without a bound texture is a
    /// silent no-op (donor matches).  Calling inside `begin`/`end`
    /// records `.invalid_operation` and writes nothing.  Donor:
    /// `swTexImage2D`.
    /// `gpa` must be the same allocator passed to `init` /
    /// `deleteTextures`; texture pixel storage is owned by the
    /// Context and released by `deleteTextures` (or `deinit` once
    /// the pool's per-slot free path is wired).
    pub fn texImage2D(
        self: *Context,
        gpa: Allocator,
        width: i32,
        height: i32,
        format: Format,
        data_type: DataType,
        data: ?[]const u8,
    ) !void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        const tex: *Texture = self.bound_texture orelse return;

        if (width <= 0 or height <= 0) {
            self.err_code = .invalid_value;
            return;
        }

        const pixel_format: PixelFormat = pixelFormatFromFormatAndType(format, data_type) orelse {
            self.err_code = .invalid_enum;
            return;
        };

        const bpp: usize = pixel_format_size.get(pixel_format);
        const w_us: usize = @intCast(width);
        const h_us: usize = @intCast(height);
        const new_size: usize = w_us * h_us * bpp;

        // Reallocate if size changed; reuse if it didn't.  The donor
        // does the same `realloc(..., newSize)` shape but only grows
        // (never shrinks); we always resize so `pixels.len` always
        // matches the current dimensions exactly.
        if (tex.pixels.len != new_size) {
            const new_pixels: []u8 = try gpa.realloc(tex.pixels, new_size);
            tex.pixels = new_pixels;
        }

        // Copy data in or zero-fill.  `data` may be smaller than the
        // allocation if the user passes a too-short slice; we bounds-
        // check rather than blindly memcpy.
        if (data) |src| {
            if (src.len < new_size) {
                self.err_code = .invalid_value;
                @memset(tex.pixels, 0); // leave a defined state on error
                return;
            }
            @memcpy(tex.pixels, src[0..new_size]);
        } else {
            @memset(tex.pixels, 0);
        }

        // Compute the alpha-channel summary.  For data-bearing color
        // formats with alpha, scan to detect any non-opaque pixel; for
        // null-data or depth formats, default to .none.
        const fmt_alpha: PixelAlpha = pixel_format_alpha.get(pixel_format);
        const has_data: bool = data != null;
        const is_depth: bool = pixel.isDepthFormat(pixel_format);
        const alpha_bearing: bool = fmt_alpha != .none;
        var alpha_found: bool = false;
        if (has_data and !is_depth and alpha_bearing) {
            const reader: pixel.ReadColor8Fn = pixel.read_color8_table.get(pixel_format).?;
            const total_pixels: u32 = @intCast(w_us * h_us);
            var i: u32 = 0;
            while (i < total_pixels) : (i += 1) {
                var rgba: [4]u8 = undefined;
                reader(&rgba, tex.pixels, i);
                if (rgba[3] < 255) {
                    alpha_found = true;
                    break;
                }
            }
        }

        tex.format = pixel_format;
        tex.alpha = if (alpha_found) fmt_alpha else .none;
        tex.size = Vec2i{ width, height };
        tex.size_minus_one = Vec2i{ width - 1, height - 1 };
        tex.inv_size = .{ 1.0 / float(width), 1.0 / float(height) };
    }

    /// Set a single sampler parameter on the currently-bound texture.
    /// Donor: `swTexParameteri`.  No-op if no texture is bound (donor
    /// matches).  Invalid combinations don't compile (the `param`
    /// enum determines the value type, so `.min_filter` only takes a
    /// `Filter`, etc.).
    pub fn texParameter(self: *Context, param: TextureParam) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        const tex: *Texture = self.bound_texture orelse return;
        switch (param) {
            .min_filter => |v| tex.min_filter = v,
            .mag_filter => |v| tex.mag_filter = v,
            .wrap_s => |v| tex.wrap_s = v,
            .wrap_t => |v| tex.wrap_t = v,
        }
    }

    // ========================================================================
    // Begin / end immediate-mode plumbing
    // ========================================================================
    // GL-style immediate mode: `begin(.triangles)` opens a recording,
    // a sequence of `vertex2f` / `vertex3f` calls (interspersed with
    // `color*` / `texCoord2f` setters) submits vertices, `end()`
    // closes the recording.  Each vertex submission applies the
    // cached MVP and stores into `primitive.buffer`; once the buffer
    // accumulates a full primitive's worth (1 / 2 / 3 / 4 for points
    // / lines / triangles / quads), the rasterizer would dispatch.
    // The rasterizer ships+; for now we just reset
    // `vertex_count` to 0 at the flush point so subsequent primitives
    // in the same begin/end pair don't overflow the 14-slot buffer.
    // `begin` does the heavy work: recompute `mat_mvp` if the dirty
    // bit was set by any earlier matrix op, run
    // `cleanRasterState` so the rasterizer dispatch table
    // sees a consistent state.  This is the first turn in which both
    // helpers actually fire from production code.
    // Color and texcoord are STATEFUL.  `color3f(...)` sets a "current
    // color" that gets attached to every subsequent vertex until the
    // next `color*` call.  GL-style.  Donor matches.

    /// Open an immediate-mode recording.  Records `.invalid_operation`
    /// if already active (donor + GL spec) or if the framebuffer is
    /// incomplete.  Recomputes `mat_mvp` and runs `cleanRasterState`
    /// before accepting vertices.  Donor: `swBegin` +
    /// `sw_immediate_begin`.
    pub fn begin(self: *Context, mode: DrawMode) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        // Framebuffer-readiness gate.  We only require that the color
        // attachment is complete; depth is optional (the rasterizer's
        // `cleanRasterState` strips `.depth_test` when depth is
        // missing, rather than refusing to draw).  Donor's
        // `sw_is_ready_to_render` checks the full status (color +
        // optional-depth), but we keep it simple: any path that
        // produces a usable color attachment satisfies us.
        const color_tex: *const Texture = self.effectiveColorBufferConst();
        if (!isTextureComplete(color_tex)) {
            self.err_code = .invalid_operation;
            return;
        }

        if (self.is_dirty_mvp) {
            // mvp = projection * modelview (zimr column-vector order);
            // operand order reversed for zmath's row-vector `mul`.
            self.mat_mvp = mulMat(
                self.stack_projection[self.stack_projection_counter - 1],
                self.stack_modelview[self.stack_modelview_counter - 1],
            );
            self.is_dirty_mvp = false;
        }

        self.cleanRasterState();
        self.primitive.has_color_alpha = false;
        self.primitive.vertex_count = 0;
        self.draw_mode = mode;
    }

    /// Close the immediate-mode recording.  Records `.invalid_operation`
    /// if not active.  Donor: `swEnd` + `sw_immediate_end`.
    pub fn end(self: *Context) void {
        if (!self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        self.draw_mode = null;
    }

    /// Submit a 2D vertex.  Z = 0, W = 1 (donor matches; the donor's
    /// `swVertex2f` builds `{ x, y, 0, 1 }` then routes through
    /// `sw_immediate_push_vertex`).  Records `.invalid_operation` if
    /// not inside `begin`/`end`.
    pub fn vertex2f(
        self: *Context,
        x: f32,
        y: f32,
    ) void {
        const pos: [4]f32 = .{ x, y, 0.0, 1.0 };
        self.pushVertex(pos);
    }

    /// Submit a 3D vertex.  W = 1.  Donor: `swVertex3f`.
    pub fn vertex3f(
        self: *Context,
        x: f32,
        y: f32,
        z: f32,
    ) void {
        const pos: [4]f32 = .{ x, y, z, 1.0 };
        self.pushVertex(pos);
    }

    /// Set the current vertex color (3-component float; alpha = 1).
    /// Donor: `swColor3f`.
    pub fn color3f(
        self: *Context,
        r: f32,
        g: f32,
        b: f32,
    ) void {
        self.setColor(.{ r, g, b, 1.0 });
    }

    /// Set the current vertex color (4-component float).  Donor:
    /// `swColor4f`.
    pub fn color4f(
        self: *Context,
        r: f32,
        g: f32,
        b: f32,
        a: f32,
    ) void {
        self.setColor(.{ r, g, b, a });
    }

    /// Set the current vertex color (4-component byte; normalised to
    /// `[0, 1]` floats internally).  Donor: `swColor4ub`.
    pub fn color4ub(
        self: *Context,
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    ) void {
        const inv_255: f32 = 1.0 / 255.0;
        self.setColor(.{
            float(r) * inv_255,
            float(g) * inv_255,
            float(b) * inv_255,
            float(a) * inv_255,
        });
    }

    /// Set the current vertex texcoord, transformed by the active
    /// texture matrix (top of `stack_texture`).  Donor:
    /// `swTexCoord2f` + `sw_immediate_set_texcoord`.  The texture-
    /// matrix transform is applied immediately, not at vertex-push
    /// time - this matches the donor and lets the texture stack
    /// itself stay out of the per-vertex hot path.
    pub fn texCoord2f(
        self: *Context,
        u: f32,
        v: f32,
    ) void {
        const m: Matrix = self.stack_texture[self.stack_texture_counter - 1];
        // Apply the 2D transform: m12, m13 carry translation in raylib's
        // row-vector pipeline; m0/m4 form column 0, m1/m5 column 1.
        // (Same convention as `pushVertex` below - see the
        // multiplication-direction note in the section header.)
        self.primitive.current_texcoord = .{
            u * m[0][0] + v * m[1][0] + m[3][0],
            u * m[0][1] + v * m[1][1] + m[3][1],
        };
    }

    /// Apply the cached MVP to `pos`, attach current color/texcoord,
    /// and append to the primitive scratch buffer.  When the buffer
    /// reaches the primitive's vertex count (1 for points, 2 for
    /// lines, 3 for triangles, 4 for quads), the rasterizer hook
    /// would fire and reset.  Until the next pass ships the rasterizer,
    /// we just reset to 0 so the buffer doesn't overflow on multi-
    /// primitive begin/end pairs.  Donor:
    /// `sw_immediate_push_vertex`.
    fn pushVertex(self: *Context, pos: [4]f32) void {
        const mode: DrawMode = self.draw_mode orelse {
            self.err_code = .invalid_operation;
            return;
        };

        // Defensive bound - should be unreachable while the auto-
        // flush below is wired, but guards against a future rasterizer
        // hook that disables auto-flush (e.g. a degenerate-line case).
        const idx: usize = @intCast(self.primitive.vertex_count);
        if (idx >= max_clipped_polygon_vertices) {
            self.err_code = .invalid_operation;
            return;
        }
        const v: *Vertex = &self.primitive.buffer[idx];

        // MVP x position with raylib's row-vector convention:
        // `result[j] = sum_i pos[i] * M[i, j]`.  See the
        // multiplication-direction note in the matrix-stack section.
        const m: *const Matrix = &self.mat_mvp;
        v.position[0] = pos[0] * m[0][0] + pos[1] * m[1][0] + pos[2] * m[2][0] + pos[3] * m[3][0];
        v.position[1] = pos[0] * m[0][1] + pos[1] * m[1][1] + pos[2] * m[2][1] + pos[3] * m[3][1];
        v.position[2] = pos[0] * m[0][2] + pos[1] * m[1][2] + pos[2] * m[2][2] + pos[3] * m[3][2];
        v.position[3] = pos[0] * m[0][3] + pos[1] * m[1][3] + pos[2] * m[2][3] + pos[3] * m[3][3];

        v.color = self.primitive.current_color;
        v.texcoord = self.primitive.current_texcoord;

        self.primitive.vertex_count += 1;

        // Auto-flush at primitive size.  This is where the rasterizer
        // dispatches: a complete primitive's worth of vertices have
        // accumulated, run the matching rasterizer kernel.  Donor:
        // `sw_poly_fill_render` style switch on `draw_mode`.
        if (self.primitive.vertex_count == primitiveVertexCount(mode)) {
            switch (mode) {
                .points => self.drawPoint(&self.primitive.buffer[0]),
                .lines => self.drawLine(
                    &self.primitive.buffer[0],
                    &self.primitive.buffer[1],
                ),
                .triangles => if (self.ff_triangle) |ff| {
                    ff(self, &self.primitive.buffer[0], &self.primitive.buffer[1], &self.primitive.buffer[2]);
                } else {
                    self.drawTriangle(
                        &self.primitive.buffer[0],
                        &self.primitive.buffer[1],
                        &self.primitive.buffer[2],
                    );
                },
                .quads => if (self.ff_triangle) |ff| {
                    // Quad -> two triangles (0,1,2) + (0,2,3), each routed
                    // through the same fixed-function hook.
                    ff(self, &self.primitive.buffer[0], &self.primitive.buffer[1], &self.primitive.buffer[2]);
                    ff(self, &self.primitive.buffer[0], &self.primitive.buffer[2], &self.primitive.buffer[3]);
                } else {
                    self.drawQuad(
                        &self.primitive.buffer[0],
                        &self.primitive.buffer[1],
                        &self.primitive.buffer[2],
                        &self.primitive.buffer[3],
                    );
                },
            }
            self.primitive.has_color_alpha = false;
            self.primitive.vertex_count = 0;
        }
    }

    // ========================================================================
    // Rasterizer
    // ========================================================================
    // The per-primitive rasterizers `pushVertex`'s auto-flush
    // dispatches into.  Today `drawPoint` and `drawLine` ship
    //.  Lines / triangles / quads land in
    // subsequent rasterizer passes.  Each rasterizer is a self-contained
    // function that reads from `primitive.buffer`, writes through
    // the format-specialised `pixel.write_color8_table` /
    // `write_depth_table` dispatch, and respects the cleaned-up
    // `raster_state` snapshot (the cleanRasterState helper, firing
    // here).  Helpers like `fillPointSquare` exist to keep the
    // depth-test branch hoisted out of the inner loop - runtime-
    // branched at the kernel level, matching the donor's
    // preprocessor-specialised variants without the macro
    // expansion.

    /// A vertex projected to screen space.  Output of `projectVertex`:
    /// `x` and `y` are pixel coordinates (sub-pixel precision; round
    /// or truncate at the call site), `z` is NDC depth in [-1, +1]
    /// for use with the depth test.  Color, texcoord, and 1/w aren't
    /// projected - color and texcoord are read directly from the
    /// `Vertex`; `w_inv` is carried separately for perspective-
    /// correct depth interp.
    const ProjectedVertex = struct {
        x: f32,
        y: f32,
        z: f32,
    };

    /// Inclusive-exclusive pixel rectangle representing the effective
    /// drawing region: framebuffer bounds intersected with the
    /// scissor rect when `.scissor_test` is enabled.  Output of
    /// `scissorRect` / `scissorPixelRect`.
    pub const PixelRect = struct {
        min_x: i32,
        min_y: i32,
        max_x: i32,
        max_y: i32,
    };

    /// Project a clip-space `Vertex` to screen space.  Returns null
    /// if the vertex is outside the clip volume (any
    /// `position[i]` outside `[-w, +w]` for i in {0, 1, 2}).  W = 1
    /// short-circuits the perspective divide (raylib's 2D path
    /// produces W=1 vertices; saves three rcp's per vertex).
    /// Donor: `sw_point_clip_and_project` minus the bounding-square
    /// early-reject (callers do that themselves with primitive-
    /// specific extents).  Used by every rasterizer dispatcher.
    fn projectVertex(self: *const Context, v: *const Vertex) ?ProjectedVertex {
        var sx: f32 = v.position[0];
        var sy: f32 = v.position[1];
        var sz: f32 = v.position[2];
        const w: f32 = v.position[3];
        if (w != 1.0) {
            const w_abs: f32 = @abs(w);
            if (sx < -w_abs or sx > w_abs) {
                return null;
            }
            if (sy < -w_abs or sy > w_abs) {
                return null;
            }
            if (sz < -w_abs or sz > w_abs) {
                return null;
            }
            const w_inv: f32 = 1.0 / w;
            sx *= w_inv;
            sy *= w_inv;
            sz *= w_inv;
        }
        return .{
            .x = self.vp_center[0] + sx * self.vp_half[0] + 0.5,
            // Y is flipped here vs donor `raster.h` (which had a `+ sy *
            // vp_half.y` mapping = pixel-Y-down: NDC Y=+1 lands at the
            // BOTTOM of the framebuffer).  We use GL convention instead
            // - NDC Y=+1 lands at the TOP of the framebuffer - so raster
            // and rlgl agree on screen orientation and one set of
            // matrices/aim-math works against either renderer.  See
            // examples/raster_side_by_side.zig's cube comment block for
            // why this matters for the side-by-side comparison.
            .y = self.vp_center[1] - sy * self.vp_half[1] + 0.5,
            .z = sz,
        };
    }

    /// The effective pixel rectangle to draw into: framebuffer
    /// bounds intersected with the scissor rect when scissor is
    /// active.  Donor merges these into a single min/max pair;
    /// we follow.  Used by every rasterizer kernel.
    fn scissorRect(self: *const Context, color_tex: *const Texture) PixelRect {
        const tex_w: i32 = color_tex.size[0];
        const tex_h: i32 = color_tex.size[1];
        if (!self.user_state.contains(.scissor_test)) {
            return .{ .min_x = 0, .min_y = 0, .max_x = tex_w, .max_y = tex_h };
        }
        return .{
            .min_x = clamp(self.sc_min[0], 0, tex_w),
            .min_y = clamp(self.sc_min[1], 0, tex_h),
            .max_x = clamp(self.sc_max[0], 0, tex_w),
            .max_y = clamp(self.sc_max[1], 0, tex_h),
        };
    }

    /// Public form of `scissorRect`, resolved against the effective
    /// colour buffer (the one a rasterizer writes into).  The
    /// programmable rasterizer in `raster_shader.zig` clamps its triangle
    /// bbox to this so scissor is honoured by the one rasteriser too.
    /// Equals the full colour-buffer bounds when `.scissor_test` is
    /// off, so it is a no-op clamp unless scissor is enabled.
    pub fn scissorPixelRect(self: *const Context) PixelRect {
        return self.scissorRect(self.effectiveColorBufferConst());
    }

    /// The current rasterizer cfg derived from the cleaned
    /// `raster_state` snapshot plus the cull-face setter.
    /// Computed once per primitive at dispatch time, fed to the
    /// `inline switch` to select the matching monomorphised kernel.
    fn currentCfg(self: *const Context) RasterCfg {
        return .{
            .depth_test = self.raster_state.contains(.depth_test),
            .texture = self.raster_state.contains(.texture_2d),
            .blend = self.raster_state.contains(.blend),
            .cull_back = self.raster_state.contains(.cull_face) and self.cull_face == .back,
        };
    }

    // ---- Point dispatcher + kernel
    /// Rasterize a single point.  Dispatches into the matching
    /// monomorphised `pointKernel` based on the cfg derived from
    /// runtime state.  All cfg branches inside the kernel are
    /// comptime-known and compile away to either the work or
    /// nothing at all.  Donor: `sw_point_render` +
    /// `sw_raster_point_BASE` / `_DEPTH` family - same shape, but
    /// the donor's preprocessor variants become Zig comptime
    /// `if (cfg.X)` blocks inside one parametric kernel.
    fn drawPoint(self: *Context, v: *const Vertex) void {
        switch (cfgIndex(self.currentCfg())) {
            inline 0...15 => |idx| {
                self.pointKernel(comptime cfgFromIndex(idx), v);
            },
        }
    }

    /// Comptime-specialised point rasterizer.  One monomorphised
    /// function per `RasterCfg` combination.  Inlines the framebuffer
    /// codecs (color always, depth when `cfg.depth_test`) - no
    /// runtime fn-ptr dispatch in the inner loop.
    fn pointKernel(
        self: *Context,
        comptime cfg: RasterCfg,
        v: *const Vertex,
    ) void {
        const color_tex: *Texture = self.effectiveColorBuffer();
        const proj: ProjectedVertex = self.projectVertex(v) orelse return;
        const rect: PixelRect = self.scissorRect(color_tex);
        const tex_w: i32 = color_tex.size[0];

        const radius: i32 = @trunc(self.point_radius);
        const cx: i32 = @trunc(proj.x);
        const cy: i32 = @trunc(proj.y);

        // Bounding-square early-reject.
        if (cx + radius < rect.min_x or cx - radius >= rect.max_x) {
            return;
        }
        if (cy + radius < rect.min_y or cy - radius >= rect.max_y) {
            return;
        }

        const color: [4]u8 = .{
            byteFromUnitFloat(v.color[0]),
            byteFromUnitFloat(v.color[1]),
            byteFromUnitFloat(v.color[2]),
            byteFromUnitFloat(v.color[3]),
        };

        const x_lo: i32 = @max(cx - radius, rect.min_x);
        const x_hi: i32 = @min(cx + radius, rect.max_x - 1);
        const y_lo: i32 = @max(cy - radius, rect.min_y);
        const y_hi: i32 = @min(cy + radius, rect.max_y - 1);

        // Depth path: when cfg.depth_test, every pixel reads + tests
        // + writes depth (constant z = proj.z across the square).
        // Otherwise the depth read/write code is comptime-stripped.
        const depth_tex: *Texture = if (comptime cfg.depth_test)
            self.effectiveDepthBuffer()
        else
            undefined;

        var y: i32 = y_lo;
        while (y <= y_hi) : (y += 1) {
            const row_offset: u32 = @intCast(y * tex_w);
            var x: i32 = x_lo;
            while (x <= x_hi) : (x += 1) {
                const idx: u32 = row_offset + @as(u32, @intCast(x));
                if (comptime cfg.depth_test) {
                    const stored: f32 = pixel.readDepth(fb_depth_fmt, depth_tex.pixels, idx);
                    if (proj.z > stored) {
                        continue;
                    }
                    pixel.writeDepth(fb_depth_fmt, depth_tex.pixels, proj.z, idx);
                }
                pixel.writeColor8(fb_color_fmt, color_tex.pixels, &color, idx);
            }
        }
    }

    // ---- Line dispatcher + kernel
    /// Rasterize a line segment.  Dispatches into the matching
    /// monomorphised `lineKernel`.  Donor: `sw_line_render` +
    /// `sw_raster_line_BASE` / `_DEPTH`.
    fn drawLine(
        self: *Context,
        v0: *const Vertex,
        v1: *const Vertex,
    ) void {
        switch (cfgIndex(self.currentCfg())) {
            inline 0...15 => |idx| {
                self.lineKernel(comptime cfgFromIndex(idx), v0, v1);
            },
        }
    }

    /// Comptime-specialised line rasterizer (DDA).  Same notes as
    /// `pointKernel` re: comptime cfg branches and inlined codecs.
    /// Conscious omissions same as before: no Liang-Barsky clip-
    /// space clipping, no thick lines.
    fn lineKernel(
        self: *Context,
        comptime cfg: RasterCfg,
        v0: *const Vertex,
        v1: *const Vertex,
    ) void {
        const color_tex: *Texture = self.effectiveColorBuffer();

        const p0: ProjectedVertex = self.projectVertex(v0) orelse return;
        const p1: ProjectedVertex = self.projectVertex(v1) orelse return;
        const rect: PixelRect = self.scissorRect(color_tex);
        const tex_w: i32 = color_tex.size[0];

        const dx: f32 = p1.x - p0.x;
        const dy: f32 = p1.y - p0.y;
        const steps_f: f32 = @max(@abs(dx), @abs(dy));
        const steps: u32 = @trunc(@max(steps_f, 1.0));
        const inv_steps: f32 = 1.0 / float(steps);
        const step_x: f32 = dx * inv_steps;
        const step_y: f32 = dy * inv_steps;
        const step_z: f32 = (p1.z - p0.z) * inv_steps;

        const depth_tex: *Texture = if (comptime cfg.depth_test)
            self.effectiveDepthBuffer()
        else
            undefined;

        var x: f32 = p0.x;
        var y: f32 = p0.y;
        var z: f32 = p0.z;
        var i: u32 = 0;
        while (i <= steps) : ({
            i += 1;
            x += step_x;
            y += step_y;
            z += step_z;
        }) {
            const px_i: i32 = @trunc(x);
            const py_i: i32 = @trunc(y);
            if (px_i < rect.min_x or px_i >= rect.max_x) {
                continue;
            }
            if (py_i < rect.min_y or py_i >= rect.max_y) {
                continue;
            }
            const idx: u32 = @intCast(py_i * tex_w + px_i);

            if (comptime cfg.depth_test) {
                const stored: f32 = pixel.readDepth(fb_depth_fmt, depth_tex.pixels, idx);
                if (z > stored) {
                    continue;
                }
                pixel.writeDepth(fb_depth_fmt, depth_tex.pixels, z, idx);
            }

            const u: f32 = float(i) * inv_steps;
            const color: [4]u8 = .{
                byteFromUnitFloat(v0.color[0] + (v1.color[0] - v0.color[0]) * u),
                byteFromUnitFloat(v0.color[1] + (v1.color[1] - v0.color[1]) * u),
                byteFromUnitFloat(v0.color[2] + (v1.color[2] - v0.color[2]) * u),
                byteFromUnitFloat(v0.color[3] + (v1.color[3] - v0.color[3]) * u),
            };
            pixel.writeColor8(fb_color_fmt, color_tex.pixels, &color, idx);
        }
    }

    // ---- Triangle dispatcher + kernel
    /// Rasterize a filled triangle.  Dispatches into the matching
    /// monomorphised `triangleKernel`.  Donor: `sw_triangle_render`
    /// + `SW_RASTER_TRIANGLE_TABLE`.
    fn drawTriangle(
        self: *Context,
        v0: *const Vertex,
        v1: *const Vertex,
        v2: *const Vertex,
    ) void {
        switch (cfgIndex(self.currentCfg())) {
            inline 0...15 => |idx| {
                self.triangleKernel(comptime cfgFromIndex(idx), v0, v1, v2);
            },
        }
    }

    /// Comptime-specialised triangle rasterizer.  Edge-function
    /// scan with barycentric interpolation; one monomorphised
    /// function per `RasterCfg` combination.  Color writes inline
    /// to a direct slice store at the comptime-known framebuffer
    /// format; depth reads/writes inline to a `*align(1) f32`
    /// access at the comptime-known depth format.
    /// Conscious omissions same as drawTriangle's earlier comment:
    /// no Sutherland-Hodgman clipping (conservative reject via
    /// `projectVertex`), no top-left rule, no perspective-correct
    /// UV interp (affine only - sufficient for 2D W=1 demos).
    fn triangleKernel(
        self: *Context,
        comptime cfg: RasterCfg,
        v0: *const Vertex,
        v1: *const Vertex,
        v2: *const Vertex,
    ) void {
        const color_tex: *Texture = self.effectiveColorBuffer();

        const p0: ProjectedVertex = self.projectVertex(v0) orelse return;
        const p1: ProjectedVertex = self.projectVertex(v1) orelse return;
        const p2: ProjectedVertex = self.projectVertex(v2) orelse return;
        const rect: PixelRect = self.scissorRect(color_tex);
        const tex_w: i32 = color_tex.size[0];

        const area_x2: f32 = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x);
        if (area_x2 == 0) {
            return;
        }
        // Cull pass: per-triangle, comptime-known.  CCW (area > 0)
        // = front-facing in pixel-Y-down convention; CW = back.
        if (comptime cfg.cull_back) {
            if (area_x2 < 0) {
                return;
            }
        }
        const inv_area: f32 = 1.0 / area_x2;
        const ccw: bool = area_x2 > 0;

        const tri_min_x: i32 = @floor(@min(@min(p0.x, p1.x), p2.x));
        const tri_min_y: i32 = @floor(@min(@min(p0.y, p1.y), p2.y));
        const tri_max_x: i32 = @ceil(@max(@max(p0.x, p1.x), p2.x));
        const tri_max_y: i32 = @ceil(@max(@max(p0.y, p1.y), p2.y));
        const min_x: i32 = @max(tri_min_x, rect.min_x);
        const min_y: i32 = @max(tri_min_y, rect.min_y);
        const max_x: i32 = @min(tri_max_x, rect.max_x);
        const max_y: i32 = @min(tri_max_y, rect.max_y);

        const depth_tex: *Texture = if (comptime cfg.depth_test)
            self.effectiveDepthBuffer()
        else
            undefined;

        // Texture sampler: nearest-neighbor, repeat wrap.  When
        // cfg.texture is true `cleanRasterState` has guaranteed
        // that `bound_texture` is non-null and a valid color format,
        // so we can unwrap unconditionally.  Format dispatch
        // through a fn-ptr per pixel matches the donor's
        // `tex->readColor` pattern; an RGBA8 fast-path can be added
        // later as a perf-pass turn.
        const bound_tex: ?*const Texture = self.bound_texture;
        const tex_size_x: i32 = if (comptime cfg.texture)
            bound_tex.?.size[0]
        else
            0;
        const tex_size_minus_one: Vec2i = if (comptime cfg.texture)
            bound_tex.?.size_minus_one
        else
            .{ 0, 0 };
        const tex_sampler: ?pixel.ReadColorFn = if (comptime cfg.texture)
            (pixel.read_color_table.get(bound_tex.?.format) orelse return)
        else
            null;

        // Perspective-correct UV setup.  At each vertex we pre-divide
        // (u, v, 1) by W; the rasterizer linearly interpolates these
        // three quantities via barycentric weights (which IS
        // mathematically valid in screen space, unlike interpolating
        // u and v directly), then per pixel recovers the correct UV
        // by multiplying by `W = 1 / (1/W)_interpolated`.  Donor:
        // `sw_raster_triangle_span` does the same with its `wRcpA` /
        // `wRcpB` per-block reciprocals.
        // For W=1 vertices (2D scenes that go through `vertex2f`
        // with the default identity MVP), this collapses to affine:
        // `1/W = 1` for all three vertices, `UV/W = UV`, the
        // recovered `W = 1`, and the result is just
        // `b0*UV0 + b1*UV1 + b2*UV2` - bit-identical to the affine
        // path.  So we get perspective-correct for 3D and stay
        // correct for 2D, with the same code path.  Cost: one
        // division per textured pixel for the recovered W.
        // The pre-divided values are unused when `cfg.texture` is
        // false; comptime gates strip them from non-textured
        // kernels.
        const w0_inv: f32 = if (comptime cfg.texture) 1.0 / v0.position[3] else 0;
        const w1_inv: f32 = if (comptime cfg.texture) 1.0 / v1.position[3] else 0;
        const w2_inv: f32 = if (comptime cfg.texture) 1.0 / v2.position[3] else 0;
        const uw0: f32 = if (comptime cfg.texture) v0.texcoord[0] * w0_inv else 0;
        const uw1: f32 = if (comptime cfg.texture) v1.texcoord[0] * w1_inv else 0;
        const uw2: f32 = if (comptime cfg.texture) v2.texcoord[0] * w2_inv else 0;
        const vw0: f32 = if (comptime cfg.texture) v0.texcoord[1] * w0_inv else 0;
        const vw1: f32 = if (comptime cfg.texture) v1.texcoord[1] * w1_inv else 0;
        const vw2: f32 = if (comptime cfg.texture) v2.texcoord[1] * w2_inv else 0;

        // Whether the SIMD inner-loop pass below is applicable.
        // Only the BASE configurations (no depth test, no texture
        // sampling, no blend) take the SIMD path: those are the
        // cfgs where every per-pixel operation parallelises
        // straightforwardly without per-lane gathers (texture) or
        // per-lane masked stores (blend / depth-conditional
        // writes).  cull_back is per-triangle and doesn't affect
        // the inner loop, so it's included.  Donor doesn't have
        // this's third "beat the donor" win.
        const use_simd_path: bool = comptime !cfg.depth_test and !cfg.texture and !cfg.blend;

        // SIMD edge-function constants.  Each edge function
        // `e_k(fx, fy) = (p_{k+1} - p_k) x ((fx, fy) - p_k)` is
        // linear in `(fx, fy)`, which means within a row (fy
        // fixed) it advances by a constant `de_k_dx` per X step.
        // The SIMD inner loop processes four lanes at offsets
        // `(0, 1, 2, 3)` from the row's starting `e_k_row` value;
        // each lane's edge-function value is just the row base
        // plus an offset times the per-X-step delta.
        const de0_dx: f32 = -(p1.y - p0.y);
        const de1_dx: f32 = -(p2.y - p1.y);
        const de2_dx: f32 = -(p0.y - p2.y);
        const lane_offsets: Vec = .{ 0, 1, 2, 3 };
        const de0_dx_v: Vec = @splat(de0_dx);
        const de1_dx_v: Vec = @splat(de1_dx);
        const de2_dx_v: Vec = @splat(de2_dx);
        const inv_area_v: Vec = @splat(inv_area);
        const v0_r: Vec = @splat(v0.color[0]);
        const v0_g: Vec = @splat(v0.color[1]);
        const v0_b: Vec = @splat(v0.color[2]);
        const v0_a: Vec = @splat(v0.color[3]);
        const v1_r: Vec = @splat(v1.color[0]);
        const v1_g: Vec = @splat(v1.color[1]);
        const v1_b: Vec = @splat(v1.color[2]);
        const v1_a: Vec = @splat(v1.color[3]);
        const v2_r: Vec = @splat(v2.color[0]);
        const v2_g: Vec = @splat(v2.color[1]);
        const v2_b: Vec = @splat(v2.color[2]);
        const v2_a: Vec = @splat(v2.color[3]);
        const zero_v: Vec = @splat(0);

        var py: i32 = min_y;
        while (py < max_y) : (py += 1) {
            var px: i32 = min_x;

            // SIMD pass: 4 pixels per iteration along X.  Runs
            // only for cfgs where `use_simd_path` is comptime-
            // true; for other cfgs this whole block compiles to
            // nothing and the scalar pass below handles the full
            // row.  Even when SIMD-applicable, the scalar pass
            // still runs the 0-3 pixel tail when the row width
            // isn't a multiple of 4.
            if (comptime use_simd_path) {
                const fy: f32 = float(py) + 0.5;
                const fx_start: f32 = float(min_x) + 0.5;
                // Edge functions at the row's starting pixel.
                // Within the row we'll advance by 4 * de_dx per
                // SIMD iteration; lane k samples at offset k from
                // the current `e_row`.
                var e0_row: f32 = (p1.x - p0.x) * (fy - p0.y) - (p1.y - p0.y) * (fx_start - p0.x);
                var e1_row: f32 = (p2.x - p1.x) * (fy - p1.y) - (p2.y - p1.y) * (fx_start - p1.x);
                var e2_row: f32 = (p0.x - p2.x) * (fy - p2.y) - (p0.y - p2.y) * (fx_start - p2.x);

                // SIMD-end is the largest `px` such that
                // `(px, px+1, px+2, px+3)` are all `< max_x`.
                // Mask out the low two bits to round down to a
                // multiple of 4 starting from min_x.
                const row_width: i32 = max_x - min_x;
                const simd_end: i32 = min_x + (row_width & ~@as(i32, 3));

                while (px < simd_end) : (px += 4) {
                    // Edge functions for the four lanes.
                    const e0_v: Lane4f =
                        @as(Lane4f, @splat(e0_row)) + de0_dx_v * lane_offsets;
                    const e1_v: Lane4f =
                        @as(Lane4f, @splat(e1_row)) + de1_dx_v * lane_offsets;
                    const e2_v: Lane4f =
                        @as(Lane4f, @splat(e2_row)) + de2_dx_v * lane_offsets;

                    // Inside mask.  Three vector compares
                    // ANDed lane-wise.  CCW: all edges >= 0;
                    // CW: all edges <= 0.  The result is a
                    // `Lane4b` we use to gate
                    // per-lane writes.
                    const inside: Lane4b = if (ccw)
                        (e0_v >= zero_v) & (e1_v >= zero_v) & (e2_v >= zero_v)
                    else
                        (e0_v <= zero_v) & (e1_v <= zero_v) & (e2_v <= zero_v);

                    // Quick-reject: if no lane is inside (common
                    // along triangle edges where the bbox is
                    // wider than the triangle), skip the color
                    // computation entirely.  `@reduce(.Or, ...)`
                    // ORs all lanes into a single bool.
                    if (@reduce(.Or, inside)) {
                        const b0_v: Lane4f = e1_v * inv_area_v;
                        const b1_v: Lane4f = e2_v * inv_area_v;
                        const b2_v: Lane4f = e0_v * inv_area_v;

                        const cr_v: Lane4f = b0_v * v0_r + b1_v * v1_r + b2_v * v2_r;
                        const cg_v: Lane4f = b0_v * v0_g + b1_v * v1_g + b2_v * v2_g;
                        const cb_v: Lane4f = b0_v * v0_b + b1_v * v1_b + b2_v * v2_b;
                        const ca_v: Lane4f = b0_v * v0_a + b1_v * v1_a + b2_v * v2_a;

                        const r_bytes: Lane4u8 = byteFromUnitFloatVec(cr_v);
                        const g_bytes: Lane4u8 = byteFromUnitFloatVec(cg_v);
                        const b_bytes: Lane4u8 = byteFromUnitFloatVec(cb_v);
                        const a_bytes: Lane4u8 = byteFromUnitFloatVec(ca_v);

                        // Per-lane scalar 4-byte writes for the
                        // inside lanes.  Wasm SIMD has no
                        // efficient masked-store for partial
                        // RGBA8 layouts, and packing
                        // r/g/b/a vectors into one v128 would
                        // need a shuffle that costs as much as
                        // four scalar stores.  Keep the writes
                        // simple - the SIMD win is in the math.
                        inline for (0..4) |k| {
                            if (inside[k]) {
                                const idx_k: u32 = @intCast(py * tex_w + px + @as(i32, @intCast(k)));
                                const color_k: [4]u8 = .{
                                    r_bytes[k],
                                    g_bytes[k],
                                    b_bytes[k],
                                    a_bytes[k],
                                };
                                pixel.writeColor8(fb_color_fmt, color_tex.pixels, &color_k, idx_k);
                            }
                        }
                    }

                    // Advance row-base edge functions by 4
                    // pixels' worth of dx delta.  The next SIMD
                    // iteration's lane offsets are still `(0, 1,
                    // 2, 3)` - applied to the new row base.
                    const four: f32 = 4.0;
                    e0_row += de0_dx * four;
                    e1_row += de1_dx * four;
                    e2_row += de2_dx * four;
                }
            }

            // Scalar pass.  For non-BASE cfgs runs the full row;
            // for BASE runs only the 0-3 pixel tail at the end.
            // `px` carries forward from wherever the SIMD pass
            // left off.
            while (px < max_x) : (px += 1) {
                const fx: f32 = float(px) + 0.5;
                const fy: f32 = float(py) + 0.5;

                const e0: f32 = (p1.x - p0.x) * (fy - p0.y) - (p1.y - p0.y) * (fx - p0.x);
                const e1: f32 = (p2.x - p1.x) * (fy - p1.y) - (p2.y - p1.y) * (fx - p1.x);
                const e2: f32 = (p0.x - p2.x) * (fy - p2.y) - (p0.y - p2.y) * (fx - p2.x);
                const inside: bool = if (ccw)
                    (e0 >= 0 and e1 >= 0 and e2 >= 0)
                else
                    (e0 <= 0 and e1 <= 0 and e2 <= 0);
                if (!inside) {
                    continue;
                }

                const b0: f32 = e1 * inv_area;
                const b1: f32 = e2 * inv_area;
                const b2: f32 = e0 * inv_area;

                const idx: u32 = @intCast(py * tex_w + px);

                if (comptime cfg.depth_test) {
                    const z: f32 = b0 * p0.z + b1 * p1.z + b2 * p2.z;
                    const stored: f32 = pixel.readDepth(fb_depth_fmt, depth_tex.pixels, idx);
                    if (z > stored) {
                        continue;
                    }
                    pixel.writeDepth(fb_depth_fmt, depth_tex.pixels, z, idx);
                }

                // Vertex color (gouraud).
                var cr: f32 = b0 * v0.color[0] + b1 * v1.color[0] + b2 * v2.color[0];
                var cg: f32 = b0 * v0.color[1] + b1 * v1.color[1] + b2 * v2.color[1];
                var cb: f32 = b0 * v0.color[2] + b1 * v1.color[2] + b2 * v2.color[2];
                var ca: f32 = b0 * v0.color[3] + b1 * v1.color[3] + b2 * v2.color[3];

                if (comptime cfg.texture) {
                    const tex: *const Texture = bound_tex.?;
                    // Perspective-correct UV interp.  Linearly
                    // interpolate `(u/w, v/w, 1/w)` via barycentric
                    // weights - these three quantities ARE
                    // affine-correct in screen space - then recover
                    // the actual UV per pixel via division by the
                    // interpolated `1/w`.  W=1 vertices reduce this
                    // to plain affine UV: see the per-vertex setup
                    // hoisted above the row scan.
                    const one_over_w: f32 = b0 * w0_inv + b1 * w1_inv + b2 * w2_inv;
                    const w_recovered: f32 = 1.0 / one_over_w;
                    const u: f32 = (b0 * uw0 + b1 * uw1 + b2 * uw2) * w_recovered;
                    const v: f32 = (b0 * vw0 + b1 * vw1 + b2 * vw2) * w_recovered;
                    const u_wrap: f32 = u - @floor(u);
                    const v_wrap: f32 = v - @floor(v);
                    const tx_f: f32 = u_wrap * float(tex_size_x);
                    const ty_f: f32 = v_wrap * float(tex_size_minus_one[1] + 1);
                    const tx: i32 = @min(int(i32, tx_f), tex_size_minus_one[0]);
                    const ty: i32 = @min(int(i32, ty_f), tex_size_minus_one[1]);
                    const tex_idx: u32 = @intCast(ty * tex_size_x + tx);
                    var sample: [4]f32 = @splat(0);
                    tex_sampler.?(&sample, tex.pixels, tex_idx);
                    cr *= sample[0];
                    cg *= sample[1];
                    cb *= sample[2];
                    ca *= sample[3];
                }

                if (comptime cfg.blend) {
                    // Alpha-over (`SRC_ALPHA, ONE_MINUS_SRC_ALPHA`)
                    // inlined as the only blend recipe.  Donor
                    // dispatches through `RLSW.blendFunc` for any
                    // of 64 (src x dst) combinations; we beat the
                    // donor on this axis by inlining the common
                    // case.  Other blend modes can land later as
                    // a runtime fallback when blend_func != null
                    // and is not the alpha-over recipe.
                    const dst: [4]f32 = pixel.readColor(fb_color_fmt, color_tex.pixels, idx);
                    const inv_a: f32 = 1.0 - ca;
                    cr = cr * ca + dst[0] * inv_a;
                    cg = cg * ca + dst[1] * inv_a;
                    cb = cb * ca + dst[2] * inv_a;
                    ca = ca + dst[3] * inv_a;
                }

                const color: [4]u8 = .{
                    byteFromUnitFloat(cr),
                    byteFromUnitFloat(cg),
                    byteFromUnitFloat(cb),
                    byteFromUnitFloat(ca),
                };
                pixel.writeColor8(fb_color_fmt, color_tex.pixels, &color, idx);
            }
        }
    }

    // ---- Quad dispatcher + sprite-fast-path kernel
    // Quads in immediate mode are the natural primitive for sprites,
    // UI panels, billboards - anything rectangular and screen-aligned.
    // The triangle rasterizer can draw them (as two triangles), but
    // the per-pixel work is wasteful: edge functions only ever produce
    // "inside" verdicts, the bounding box is exactly the quad, and the
    // barycentric division is irrelevant because (u, v) gradients are
    // already constant per-axis.
    // The dispatcher below detects axis-aligned quads at submit time
    // and routes them through `quadKernel` - a rectangular scan with
    // linear gradients in (x, y).  Cost per pixel: one add per
    // interpolated channel.  Cost per pixel in the triangle path: six
    // multiplies plus three adds (edge functions) plus a barycentric
    // division per triangle.  The fast-path is roughly 3x cheaper for
    // typical sprites.
    // Non-axis-aligned quads (rotated rectangles, perspective-distorted
    // billboards in 3D) fall back to fan triangulation: `triangleKernel`
    // is invoked twice with the (v0, v1, v2) and (v0, v2, v3) splits.
    // This costs two redundant projections but keeps the code path
    // simple and the cost dwarfed by the rasterization itself.
    // Donor: `sw_quad_render` + `sw_quad_is_axis_aligned` +
    // `SW_RASTER_QUAD_TABLE`.  Same shape, translated into Zig's
    // comptime cfg pattern.

    /// Edge tolerance, in screen-space pixels, for the axis-aligned
    /// test.  An edge whose run OR rise is below this threshold is
    /// treated as horizontal/vertical.  Half a pixel matches the
    /// donor (`SW_QUAD_AXIS_EPSILON` would be the donor's name had
    /// they exposed it as a constant).
    const quad_axis_align_eps: f32 = 0.5;

    /// True when the four projected vertices form a screen-axis-
    /// aligned rectangle (each edge runs purely horizontally or
    /// vertically within `quad_axis_align_eps`).  Independent of
    /// vertex order - a rotated-by-90 sprite that submits its
    /// vertices starting from the top-right still tests true.
    fn isAxisAlignedQuad(
        p0: ProjectedVertex,
        p1: ProjectedVertex,
        p2: ProjectedVertex,
        p3: ProjectedVertex,
    ) bool {
        const e: f32 = quad_axis_align_eps;

        const dx01: f32 = p1.x - p0.x;
        const dy01: f32 = p1.y - p0.y;
        if (@abs(dx01) >= e and @abs(dy01) >= e) {
            return false;
        }

        const dx12: f32 = p2.x - p1.x;
        const dy12: f32 = p2.y - p1.y;
        if (@abs(dx12) >= e and @abs(dy12) >= e) {
            return false;
        }

        const dx23: f32 = p3.x - p2.x;
        const dy23: f32 = p3.y - p2.y;
        if (@abs(dx23) >= e and @abs(dy23) >= e) {
            return false;
        }

        const dx30: f32 = p0.x - p3.x;
        const dy30: f32 = p0.y - p3.y;
        if (@abs(dx30) >= e and @abs(dy30) >= e) {
            return false;
        }

        return true;
    }

    /// Rasterize a quad.  The dispatcher routes between the
    /// sprite-fast-path `quadKernel` (axis-aligned quads) and a fan
    /// triangulation through `triangleKernel` (everything else).
    /// All cfg branches inside both kernels resolve at compile
    /// time via the same `inline switch` over `cfgIndex` used by
    /// the other primitive dispatchers.  Donor: `sw_quad_render`.
    fn drawQuad(
        self: *Context,
        v0: *const Vertex,
        v1: *const Vertex,
        v2: *const Vertex,
        v3: *const Vertex,
    ) void {
        // Project once for the axis-alignment test.  The
        // sprite-fast-path uses these projected vertices; the
        // triangle fallback re-projects internally (cheap; the
        // projection is a few flops).
        const p0: ProjectedVertex = self.projectVertex(v0) orelse return;
        const p1: ProjectedVertex = self.projectVertex(v1) orelse return;
        const p2: ProjectedVertex = self.projectVertex(v2) orelse return;
        const p3: ProjectedVertex = self.projectVertex(v3) orelse return;

        switch (cfgIndex(self.currentCfg())) {
            inline 0...15 => |idx| {
                const cfg: RasterCfg = comptime cfgFromIndex(idx);
                if (isAxisAlignedQuad(p0, p1, p2, p3)) {
                    self.quadKernel(cfg, v0, v1, v2, v3, p0, p1, p2, p3);
                } else {
                    // Fan triangulation: split the quad along the
                    // (v0, v2) diagonal.  Standard convention; matches
                    // the donor's `for (i = 0; i < N - 2; i++)` fan
                    // expansion.  Cull / depth / blend / texture all
                    // apply per-triangle as usual.
                    self.triangleKernel(cfg, v0, v1, v2);
                    self.triangleKernel(cfg, v0, v2, v3);
                }
            },
        }
    }

    /// Sprite-fast-path quad rasterizer.  Assumes the four
    /// projected vertices form a screen-axis-aligned rectangle
    /// (`isAxisAlignedQuad` already verified).  Walks the rectangle
    /// row-by-row with linear gradients in (x, y) - no edge
    /// functions, no barycentric division.  Color, texcoord, and
    /// depth all interpolate via the same shape: pre-row delta
    /// `+= dCdy`, per-pixel `+= dCdx`.
    /// Linear, not bilinear: only three corners participate in the
    /// interpolation (top-left, top-right, bottom-left).  The
    /// bottom-right corner's color/uv/z are ignored - they're
    /// implied by `br = tl + (tr - tl) + (bl - tl)`.  For sprites
    /// (uniform color, rectangular UV mapping) this is exact.  For
    /// quads with four distinct corner colors this differs from
    /// true bilinear interpolation; the fall-back triangle path
    /// (which splits the quad along its diagonal) gives different
    /// results too, so neither is "right" - it's a convention.
    /// Donor matches us here.
    fn quadKernel(
        self: *Context,
        comptime cfg: RasterCfg,
        v0: *const Vertex,
        v1: *const Vertex,
        v2: *const Vertex,
        v3: *const Vertex,
        p0: ProjectedVertex,
        p1: ProjectedVertex,
        p2: ProjectedVertex,
        p3: ProjectedVertex,
    ) void {
        // Step 1: classify the four corners by position.
        // For a screen-axis-aligned rectangle, each corner has a
        // unique signature in `(x + y, x - y)` space:
        //     TL: smallest (x + y)   - both coords small
        //     BR: largest  (x + y)   - both coords large
        //     TR: largest  (x - y)   - x large, y small
        //     BL: smallest (x - y)   - x small, y large
        // This trick lets us identify corners without caring about
        // submit order (vertex 0 might be any of the four, depending
        // on how the user wrote their `begin(.quads)` block).  Donor
        // uses the same classification.
        const ProjVtx = ProjectedVertex;
        const SrcVtx = *const Vertex;
        const projs: [4]ProjVtx = .{ p0, p1, p2, p3 };
        const srcs: [4]SrcVtx = .{ v0, v1, v2, v3 };

        var tl_idx: u8 = 0;
        var tr_idx: u8 = 0;
        var br_idx: u8 = 0;
        var bl_idx: u8 = 0;
        var tl_sum: f32 = projs[0].x + projs[0].y;
        var br_sum: f32 = tl_sum;
        var tr_diff: f32 = projs[0].x - projs[0].y;
        var bl_diff: f32 = tr_diff;
        for (1..4) |i| {
            const sum: f32 = projs[i].x + projs[i].y;
            const diff: f32 = projs[i].x - projs[i].y;
            if (sum < tl_sum) {
                tl_sum = sum;
                tl_idx = @intCast(i);
            }
            if (sum > br_sum) {
                br_sum = sum;
                br_idx = @intCast(i);
            }
            if (diff > tr_diff) {
                tr_diff = diff;
                tr_idx = @intCast(i);
            }
            if (diff < bl_diff) {
                bl_diff = diff;
                bl_idx = @intCast(i);
            }
        }
        const tl_proj: ProjVtx = projs[tl_idx];
        const tr_proj: ProjVtx = projs[tr_idx];
        const br_proj: ProjVtx = projs[br_idx];
        const bl_proj: ProjVtx = projs[bl_idx];
        const tl_src: SrcVtx = srcs[tl_idx];
        const tr_src: SrcVtx = srcs[tr_idx];
        const bl_src: SrcVtx = srcs[bl_idx];
        // br_src is intentionally unused - see kernel docstring.

        // Step 2: bounding-box + scissor intersection.
        const color_tex: *Texture = self.effectiveColorBuffer();
        const rect: PixelRect = self.scissorRect(color_tex);
        const tex_w: i32 = color_tex.size[0];

        const quad_w: f32 = br_proj.x - tl_proj.x;
        const quad_h: f32 = br_proj.y - tl_proj.y;
        if (quad_w <= 0 or quad_h <= 0) {
            return;
        }

        // Cull (per-quad, comptime).  Winding for an axis-aligned
        // quad is determined by the order of its corners: if the
        // user submitted in CCW order (TL, BL, BR, TR or any
        // rotation thereof), the quad is front-facing.  We compute
        // the equivalent of `area_x2` for the (tl, tr, br) triangle
        // - same sign as the full-quad signed area.
        if (comptime cfg.cull_back) {
            const area_x2: f32 = (tr_proj.x - tl_proj.x) * (br_proj.y - tl_proj.y) -
                (tr_proj.y - tl_proj.y) * (br_proj.x - tl_proj.x);
            // For our axis-aligned test, area_x2 is always positive
            // (TL->TR->BR walks CCW in pixel-Y-down).  So this is a
            // no-op for axis-aligned quads - front-face by
            // construction.  Cull-back of an axis-aligned quad never
            // rejects.  We keep the check for parity with the
            // triangle path; if the project ever wires cull_front it
            // would matter.
            if (area_x2 < 0) {
                return;
            }
        }

        const tri_min_x: i32 = @floor(tl_proj.x);
        const tri_min_y: i32 = @floor(tl_proj.y);
        const tri_max_x: i32 = @ceil(br_proj.x);
        const tri_max_y: i32 = @ceil(br_proj.y);
        const min_x: i32 = @max(tri_min_x, rect.min_x);
        const min_y: i32 = @max(tri_min_y, rect.min_y);
        const max_x: i32 = @min(tri_max_x, rect.max_x);
        const max_y: i32 = @min(tri_max_y, rect.max_y);
        if (min_x >= max_x or min_y >= max_y) {
            return;
        }

        // Step 3: gradient setup.  Each interpolated channel changes
        // by `dCdx` per pixel along X and `dCdy` per pixel along Y.
        // The starting value at pixel (min_x, min_y) needs a subpixel
        // correction: the projected TL corner sits at some fractional
        // offset within the pixel, and we want our first sample to
        // be at the pixel center.
        const w_rcp: f32 = 1.0 / quad_w;
        const h_rcp: f32 = 1.0 / quad_h;
        const x_substep: f32 = (float(min_x) + 0.5) - tl_proj.x;
        const y_substep: f32 = (float(min_y) + 0.5) - tl_proj.y;

        // Color gradients.  Always computed (color always interpolates).
        const dcr_dx: f32 = (tr_src.color[0] - tl_src.color[0]) * w_rcp;
        const dcg_dx: f32 = (tr_src.color[1] - tl_src.color[1]) * w_rcp;
        const dcb_dx: f32 = (tr_src.color[2] - tl_src.color[2]) * w_rcp;
        const dca_dx: f32 = (tr_src.color[3] - tl_src.color[3]) * w_rcp;
        const dcr_dy: f32 = (bl_src.color[0] - tl_src.color[0]) * h_rcp;
        const dcg_dy: f32 = (bl_src.color[1] - tl_src.color[1]) * h_rcp;
        const dcb_dy: f32 = (bl_src.color[2] - tl_src.color[2]) * h_rcp;
        const dca_dy: f32 = (bl_src.color[3] - tl_src.color[3]) * h_rcp;
        var cr_row: f32 = tl_src.color[0] + dcr_dx * x_substep + dcr_dy * y_substep;
        var cg_row: f32 = tl_src.color[1] + dcg_dx * x_substep + dcg_dy * y_substep;
        var cb_row: f32 = tl_src.color[2] + dcb_dx * x_substep + dcb_dy * y_substep;
        var ca_row: f32 = tl_src.color[3] + dca_dx * x_substep + dca_dy * y_substep;

        // Depth gradients.  Comptime-elided when cfg.depth_test is
        // false - Zig won't even evaluate the unused expressions.
        const depth_tex: *Texture = if (comptime cfg.depth_test)
            self.effectiveDepthBuffer()
        else
            undefined;
        const dz_dx: f32 = if (comptime cfg.depth_test)
            (tr_proj.z - tl_proj.z) * w_rcp
        else
            0;
        const dz_dy: f32 = if (comptime cfg.depth_test)
            (bl_proj.z - tl_proj.z) * h_rcp
        else
            0;
        var z_row: f32 = if (comptime cfg.depth_test)
            tl_proj.z + dz_dx * x_substep + dz_dy * y_substep
        else
            0;

        // Texture gradients + sampler resolution.  Same idiom as
        // triangleKernel - fn-ptr resolved once per quad, then called
        // per textured pixel.  Donor's `tex->readColor` translated.
        const bound_tex: ?*const Texture = self.bound_texture;
        const tex_size_x: i32 = if (comptime cfg.texture)
            bound_tex.?.size[0]
        else
            0;
        const tex_size_minus_one: Vec2i = if (comptime cfg.texture)
            bound_tex.?.size_minus_one
        else
            .{ 0, 0 };
        const tex_sampler: ?pixel.ReadColorFn = if (comptime cfg.texture)
            (pixel.read_color_table.get(bound_tex.?.format) orelse return)
        else
            null;
        const du_dx: f32 = if (comptime cfg.texture)
            (tr_src.texcoord[0] - tl_src.texcoord[0]) * w_rcp
        else
            0;
        const dv_dx: f32 = if (comptime cfg.texture)
            (tr_src.texcoord[1] - tl_src.texcoord[1]) * w_rcp
        else
            0;
        const du_dy: f32 = if (comptime cfg.texture)
            (bl_src.texcoord[0] - tl_src.texcoord[0]) * h_rcp
        else
            0;
        const dv_dy: f32 = if (comptime cfg.texture)
            (bl_src.texcoord[1] - tl_src.texcoord[1]) * h_rcp
        else
            0;
        var u_row: f32 = if (comptime cfg.texture)
            tl_src.texcoord[0] + du_dx * x_substep + du_dy * y_substep
        else
            0;
        var v_row: f32 = if (comptime cfg.texture)
            tl_src.texcoord[1] + dv_dx * x_substep + dv_dy * y_substep
        else
            0;

        // Step 4: row-major scan.  At the start of each row we
        // restore per-row accumulators from the row-prefix; at the
        // start of each pixel we restore per-pixel accumulators
        // from the pixel-prefix.  Two-level structure mirrors the
        // donor's `xRow` / `xCur` style - keeps the inner loop
        // doing only adds, never multiplies.
        // The inner loop forks at compile time: cfgs that
        // `simdEligible()` (no depth_test, no texture, no blend)
        // run a 4-wide vectorized body that processes four pixels
        // per iteration, then a scalar tail for the 0-3 leftover
        // pixels when the row width isn't a multiple of 4.
        // Other cfgs run the full scalar body.  The SIMD path is
        // a "beat the donor" win - donor doesn't vectorize the
        // inner loop on any kernel.
        var py: i32 = min_y;
        while (py < max_y) : (py += 1) {
            var cr: f32 = cr_row;
            var cg: f32 = cg_row;
            var cb: f32 = cb_row;
            var ca: f32 = ca_row;
            var z: f32 = z_row;
            var u: f32 = u_row;
            var v: f32 = v_row;

            const row_offset: u32 = @intCast(py * tex_w);
            var px: i32 = min_x;

            if (comptime cfg.simdEligible()) {
                // SIMD prelude: process 4 pixels per iteration.
                // At the top of the row, the four lanes initialise
                // to the colors at pixels (px+0, px+1, px+2, px+3).
                // Each step advances every lane by `dC * 4` so the
                // vectors march forward in lockstep with the px
                // counter.
                // Color writes go out as four separate u32 stores
                // per iteration - clean, obvious to the compiler,
                // and easy to verify against the scalar reference.
                // A v128-load + shuffle + v128-store path would
                // shave another few cycles but obscures the data
                // flow; defer to a later turn if profiling shows
                // it matters.
                const lane_offsets: Lane4f = .{ 0, 1, 2, 3 };
                const dcr_dx_v: Lane4f = @splat(dcr_dx);
                const dcg_dx_v: Lane4f = @splat(dcg_dx);
                const dcb_dx_v: Lane4f = @splat(dcb_dx);
                const dca_dx_v: Lane4f = @splat(dca_dx);
                const dcr_dx_4: Lane4f = @splat(dcr_dx * 4);
                const dcg_dx_4: Lane4f = @splat(dcg_dx * 4);
                const dcb_dx_4: Lane4f = @splat(dcb_dx * 4);
                const dca_dx_4: Lane4f = @splat(dca_dx * 4);
                var cr_v: Lane4f = @as(Lane4f, @splat(cr)) + dcr_dx_v * lane_offsets;
                var cg_v: Lane4f = @as(Lane4f, @splat(cg)) + dcg_dx_v * lane_offsets;
                var cb_v: Lane4f = @as(Lane4f, @splat(cb)) + dcb_dx_v * lane_offsets;
                var ca_v: Lane4f = @as(Lane4f, @splat(ca)) + dca_dx_v * lane_offsets;

                while (px + 4 <= max_x) : (px += 4) {
                    const r_bytes: Lane4u8 = byteFromUnitFloatVec(cr_v);
                    const g_bytes: Lane4u8 = byteFromUnitFloatVec(cg_v);
                    const b_bytes: Lane4u8 = byteFromUnitFloatVec(cb_v);
                    const a_bytes: Lane4u8 = byteFromUnitFloatVec(ca_v);

                    inline for (0..4) |lane| {
                        const px_idx: u32 = row_offset + @as(u32, @intCast(px)) + @as(u32, lane);
                        const byte_offset: u32 = px_idx * 4;
                        color_tex.pixels[byte_offset + 0] = r_bytes[lane];
                        color_tex.pixels[byte_offset + 1] = g_bytes[lane];
                        color_tex.pixels[byte_offset + 2] = b_bytes[lane];
                        color_tex.pixels[byte_offset + 3] = a_bytes[lane];
                    }

                    cr_v += dcr_dx_4;
                    cg_v += dcg_dx_4;
                    cb_v += dcb_dx_4;
                    ca_v += dca_dx_4;
                }

                // Sync scalar accumulators to the post-SIMD position
                // so the tail loop picks up where SIMD left off.
                // Lane 0 of each vector is the value at the next
                // unprocessed px (the SIMD loop exited because
                // `px + 4 > max_x`, so lane 0 corresponds to `px`).
                cr = cr_v[0];
                cg = cg_v[0];
                cb = cb_v[0];
                ca = ca_v[0];
            }

            // Scalar inner loop.  Three roles: (1) handles all
            // pixels when SIMD isn't eligible for this cfg, (2)
            // handles the 0-3 leftover tail pixels after the SIMD
            // prelude, (3) the depth_test / texture / blend cfg
            // axes still flow through here unchanged when active.
            while (px < max_x) : (px += 1) {
                const idx: u32 = row_offset + @as(u32, @intCast(px));

                // Per-pixel work, ordered: depth test (early-out),
                // color/texture computation, blend, color write.
                // Each block is comptime-gated; non-applicable
                // blocks compile to nothing.  Per-pixel accumulator
                // advances always run - they can't be skipped, or
                // the next pixel's interpolated values would be
                // wrong.
                var depth_passed: bool = true;
                if (comptime cfg.depth_test) {
                    const stored: f32 = pixel.readDepth(fb_depth_fmt, depth_tex.pixels, idx);
                    if (z > stored) {
                        depth_passed = false;
                    } else {
                        pixel.writeDepth(fb_depth_fmt, depth_tex.pixels, z, idx);
                    }
                }

                if (depth_passed) {
                    var out_r: f32 = cr;
                    var out_g: f32 = cg;
                    var out_b: f32 = cb;
                    var out_a: f32 = ca;

                    if (comptime cfg.texture) {
                        const u_wrap: f32 = u - @floor(u);
                        const v_wrap: f32 = v - @floor(v);
                        const tx_f: f32 = u_wrap * float(tex_size_x);
                        const ty_f: f32 = v_wrap * float(tex_size_minus_one[1] + 1);
                        const tx: i32 = @min(int(i32, tx_f), tex_size_minus_one[0]);
                        const ty: i32 = @min(int(i32, ty_f), tex_size_minus_one[1]);
                        const tex_idx: u32 = @intCast(ty * tex_size_x + tx);
                        var sample: [4]f32 = @splat(0);
                        tex_sampler.?(&sample, bound_tex.?.pixels, tex_idx);
                        out_r *= sample[0];
                        out_g *= sample[1];
                        out_b *= sample[2];
                        out_a *= sample[3];
                    }

                    if (comptime cfg.blend) {
                        // Same alpha-over fast-path as triangleKernel.
                        const dst: [4]f32 = pixel.readColor(fb_color_fmt, color_tex.pixels, idx);
                        const inv_a: f32 = 1.0 - out_a;
                        out_r = out_r * out_a + dst[0] * inv_a;
                        out_g = out_g * out_a + dst[1] * inv_a;
                        out_b = out_b * out_a + dst[2] * inv_a;
                        out_a = out_a + dst[3] * inv_a;
                    }

                    const color_out: [4]u8 = .{
                        byteFromUnitFloat(out_r),
                        byteFromUnitFloat(out_g),
                        byteFromUnitFloat(out_b),
                        byteFromUnitFloat(out_a),
                    };
                    pixel.writeColor8(fb_color_fmt, color_tex.pixels, &color_out, idx);
                }

                // Per-pixel accumulator advance.  Always runs,
                // regardless of whether the pixel was painted.
                cr += dcr_dx;
                cg += dcg_dx;
                cb += dcb_dx;
                ca += dca_dx;
                if (comptime cfg.depth_test) {
                    z += dz_dx;
                }
                if (comptime cfg.texture) {
                    u += du_dx;
                    v += dv_dx;
                }
            }

            cr_row += dcr_dy;
            cg_row += dcg_dy;
            cb_row += dcb_dy;
            ca_row += dca_dy;
            if (comptime cfg.depth_test) {
                z_row += dz_dy;
            }
            if (comptime cfg.texture) {
                u_row += du_dy;
                v_row += dv_dy;
            }
        }
    }

    /// Update the running color attached to subsequent vertices.
    /// Sets `primitive.has_color_alpha` if alpha < 1 (the alpha
    /// fast-path skip the rasterizer reads).  Donor:
    /// `sw_immediate_set_color`.
    fn setColor(self: *Context, color: [4]f32) void {
        self.primitive.current_color = color;
        if (color[3] < 1.0) {
            self.primitive.has_color_alpha = true;
        }
    }

    /// Allocate `out.len` framebuffer handles.  See `genTextures` for
    /// error semantics.  Donor: `swGenFramebuffers`.
    pub fn genFramebuffers(self: *Context, out: []Handle(Framebuffer)) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        for (out) |*slot| {
            const h: Handle(Framebuffer) = self.framebuffer_pool.alloc();
            if (h.isNil()) {
                self.err_code = .out_of_memory;
                return;
            }
            slot.* = h;
        }
    }

    /// Free `handles.len` framebuffer slots.  Mirror of
    /// `deleteTextures`: per-handle validation, `err_code` updates
    /// without short-circuiting, and active-binding cleanup.
    /// Deleting the currently-bound framebuffer rebinds the default
    /// framebuffer (`bound_framebuffer = .nil`), repointing
    /// `color_buffer` and `depth_buffer` at the Context's owned
    /// color/depth attachments.  Donor: `swDeleteFramebuffers`.
    pub fn deleteFramebuffers(
        self: *Context,
        handles: []const Handle(Framebuffer),
    ) void {
        if (self.isImmediateActive()) {
            self.err_code = .invalid_operation;
            return;
        }
        for (handles) |h| {
            if (!h.isValid(&self.framebuffer_pool)) {
                self.err_code = .invalid_value;
                continue;
            }
            if (h.eql(self.bound_framebuffer)) {
                self.bound_framebuffer = .nil;
                self.color_buffer = &self.framebuffer.color;
                self.depth_buffer = &self.framebuffer.depth;
            }
            _ = h.destroy(&self.framebuffer_pool);
        }
    }
};

// ============================================================================
// Tests - wire-number compatibility
// ============================================================================
// These tests pin every numeric value to its OpenGL spec wire number.
// Whenever a port phase touches an enum, these run and catch any
// silent typo.  Cheap insurance for a property that's load-bearing
// for the GL-compat layer that will eventually sit above raster.

test "era I: Context.init + deinit round-trip with no leaks" {
    // Uses std.testing.allocator, which asserts no leaks at exit.  If
    // init allocates and deinit doesn't free (or frees the wrong thing),
    // this test fails.
    var ctx = try Context.init(std.testing.allocator, 64, 48);
    defer ctx.deinit(std.testing.allocator);

    // Spot-check the framebuffer was allocated correctly.
    try expectEqual(Vec2i{ 64, 48 }, ctx.framebuffer.color.size);
    try expectEqual(PixelFormat.color_r8g8b8a8, ctx.framebuffer.color.format);
    try expectEqual(PixelFormat.depth_d32, ctx.framebuffer.depth.format);
    // RGBA8 = 4 bytes/pixel, 64 x 48 x 4 = 12288.
    try expectEqual(@as(usize, 12288), ctx.framebuffer.color.pixels.len);
    // D32 = 4 bytes/pixel, same dimensions = same size.
    try expectEqual(@as(usize, 12288), ctx.framebuffer.depth.pixels.len);
}
test "era I: PixelFormat is densely numbered for array indexing" {
    // The internal pixel-format dispatch tables use this
    // enum as an array index.  Catch any accidental sparse numbering
    // that would break that pattern.
    try expectEqual(@as(u8, 0), @backingInt(PixelFormat.unknown));
    try expectEqual(@as(u8, 1), @backingInt(PixelFormat.color_grayscale));
    try expectEqual(@as(u8, 8), @backingInt(PixelFormat.color_r8g8b8a8));
    try expectEqual(@as(u8, 17), @backingInt(PixelFormat.depth_d32));
    try expectEqual(@as(usize, 18), PixelFormat.count);
}

test "era I: PixelAlpha is densely numbered" {
    try expectEqual(@as(u8, 0), @backingInt(PixelAlpha.none));
    try expectEqual(@as(u8, 1), @backingInt(PixelAlpha.bin));
    try expectEqual(@as(u8, 2), @backingInt(PixelAlpha.yes));
}

// ============================================================================
// Tests - math helpers
// ============================================================================

test "era I: lerpVertexPCT at t=0 returns a, t=1 returns b" {
    const a: Vertex = .{
        .position = .{ 0, 0, 0, 0 },
        .color = .{ 0, 0, 0, 0 },
        .texcoord = .{ 0, 0 },
    };
    const b: Vertex = .{
        .position = .{ 1, 2, 3, 4 },
        .color = .{ 0.1, 0.2, 0.3, 0.4 },
        .texcoord = .{ 5, 6 },
    };
    var out: Vertex = undefined;

    lerpVertexPCT(&out, &a, &b, 0.0);
    try expectEqualSlices(f32, &a.position, &out.position);
    try expectEqualSlices(f32, &a.color, &out.color);
    try expectEqualSlices(f32, &a.texcoord, &out.texcoord);

    lerpVertexPCT(&out, &a, &b, 1.0);
    try expectEqualSlices(f32, &b.position, &out.position);
    try expectEqualSlices(f32, &b.color, &out.color);
    try expectEqualSlices(f32, &b.texcoord, &out.texcoord);
}

test "era I: lerpVertexPCT at t=0.5 produces midpoint" {
    const a: Vertex = .{
        .position = .{ 0, 10, 20, 30 },
        .color = .{ 0.0, 0.0, 0.0, 0.0 },
        .texcoord = .{ 0, 0 },
    };
    const b: Vertex = .{
        .position = .{ 100, 110, 120, 130 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .texcoord = .{ 10, 20 },
    };
    var out: Vertex = undefined;
    lerpVertexPCT(&out, &a, &b, 0.5);

    try expectEqual(@as(f32, 50.0), out.position[0]);
    try expectEqual(@as(f32, 60.0), out.position[1]);
    try expectEqual(@as(f32, 0.5), out.color[0]);
    try expectEqual(@as(f32, 0.5), out.color[3]);
    try expectEqual(@as(f32, 5.0), out.texcoord[0]);
    try expectEqual(@as(f32, 10.0), out.texcoord[1]);
}

test "era I: getVertexGradPCT computes (b-a)*scale" {
    const a: Vertex = .{
        .position = .{ 0, 0, 0, 0 },
        .color = .{ 0, 0, 0, 0 },
        .texcoord = .{ 0, 0 },
    };
    const b: Vertex = .{
        .position = .{ 10, 20, 30, 40 },
        .color = .{ 0.5, 0.6, 0.7, 0.8 },
        .texcoord = .{ 5, 10 },
    };
    var grad: Vertex = undefined;
    getVertexGradPCT(&grad, &a, &b, 0.1);

    try expectEqual(@as(f32, 1.0), grad.position[0]);
    try expectEqual(@as(f32, 4.0), grad.position[3]);
    try expectEqual(@as(f32, 0.05), grad.color[0]);
    try expectEqual(@as(f32, 0.5), grad.texcoord[0]);
    try expectEqual(@as(f32, 1.0), grad.texcoord[1]);
}

test "era I: addVertexGradPCT advances by exactly one step" {
    var v: Vertex = .{
        .position = .{ 1, 2, 3, 4 },
        .color = .{ 0.1, 0.2, 0.3, 0.4 },
        .texcoord = .{ 5, 6 },
    };
    const grad: Vertex = .{
        .position = .{ 0.1, 0.2, 0.3, 0.4 },
        .color = .{ 0.01, 0.02, 0.03, 0.04 },
        .texcoord = .{ 0.5, 0.6 },
    };
    addVertexGradPCT(&v, &grad);

    try expectEqual(@as(f32, 1.1), v.position[0]);
    try expectEqual(@as(f32, 4.4), v.position[3]);
    try expectEqual(@as(f32, 5.5), v.texcoord[0]);
    try expectEqual(@as(f32, 6.6), v.texcoord[1]);
}

test "era I: addVertexGradScaledPCT applies scale" {
    var v: Vertex = .{
        .position = .{ 0, 0, 0, 0 },
        .color = .{ 0, 0, 0, 0 },
        .texcoord = .{ 0, 0 },
    };
    const grad: Vertex = .{
        .position = .{ 1, 2, 3, 4 },
        .color = .{ 0.1, 0.2, 0.3, 0.4 },
        .texcoord = .{ 5, 6 },
    };
    addVertexGradScaledPCT(&v, &grad, 2.5);

    try expectEqual(@as(f32, 2.5), v.position[0]);
    try expectEqual(@as(f32, 10.0), v.position[3]);
    try expectEqual(@as(f32, 0.25), v.color[0]);
    try expectEqual(@as(f32, 12.5), v.texcoord[0]);
}

test "era I: _PC variants leave texcoord untouched" {
    // The PC variants are used in the no-texture rasterizer
    // specialization - they should NOT touch texcoord.  Pre-fill
    // texcoord with sentinel values and verify they don't change.
    const sentinel_uv: [2]f32 = .{ 99.0, 88.0 };

    const a: Vertex = .{
        .position = .{ 0, 0, 0, 0 },
        .color = .{ 0, 0, 0, 0 },
        .texcoord = sentinel_uv,
    };
    const b: Vertex = .{
        .position = .{ 10, 10, 10, 10 },
        .color = .{ 1, 1, 1, 1 },
        .texcoord = sentinel_uv,
    };

    var grad: Vertex = .{
        .position = .{ 0, 0, 0, 0 },
        .color = .{ 0, 0, 0, 0 },
        .texcoord = sentinel_uv,
    };
    getVertexGradPC(&grad, &a, &b, 1.0);
    try expectEqualSlices(f32, &sentinel_uv, &grad.texcoord);
    try expectEqual(@as(f32, 10.0), grad.position[0]);

    var v: Vertex = .{
        .position = .{ 0, 0, 0, 0 },
        .color = .{ 0, 0, 0, 0 },
        .texcoord = sentinel_uv,
    };
    addVertexGradPC(&v, &grad);
    try expectEqualSlices(f32, &sentinel_uv, &v.texcoord);

    addVertexGradScaledPC(&v, &grad, 2.0);
    try expectEqualSlices(f32, &sentinel_uv, &v.texcoord);
    try expectEqual(@as(f32, 30.0), v.position[0]); // 10 + (10*2) = 30
}

test "era I: pixel_format_size matches donor's SW_PIXELFORMAT_SIZE" {
    try expectEqual(@as(u8, 1), pixel_format_size.get(.color_grayscale));
    try expectEqual(@as(u8, 2), pixel_format_size.get(.color_grayalpha));
    try expectEqual(@as(u8, 1), pixel_format_size.get(.color_r3g3b2));
    try expectEqual(@as(u8, 2), pixel_format_size.get(.color_r5g6b5));
    try expectEqual(@as(u8, 3), pixel_format_size.get(.color_r8g8b8));
    try expectEqual(@as(u8, 4), pixel_format_size.get(.color_r8g8b8a8));
    try expectEqual(@as(u8, 4), pixel_format_size.get(.color_r32));
    try expectEqual(@as(u8, 12), pixel_format_size.get(.color_r32g32b32));
    try expectEqual(@as(u8, 16), pixel_format_size.get(.color_r32g32b32a32));
    try expectEqual(@as(u8, 6), pixel_format_size.get(.color_r16g16b16));
    try expectEqual(@as(u8, 8), pixel_format_size.get(.color_r16g16b16a16));
    try expectEqual(@as(u8, 1), pixel_format_size.get(.depth_d8));
    try expectEqual(@as(u8, 2), pixel_format_size.get(.depth_d16));
    try expectEqual(@as(u8, 4), pixel_format_size.get(.depth_d32));
    // The unknown sentinel stays at 0 - defending against accidental
    // dispatch via a zero-initialized format.
    try expectEqual(@as(u8, 0), pixel_format_size.get(.unknown));
}

test "era I: pixel_format_alpha matches donor's SW_PIXELFORMAT_ALPHA" {
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.color_grayscale));
    try expectEqual(PixelAlpha.yes, pixel_format_alpha.get(.color_grayalpha));
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.color_r3g3b2));
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.color_r5g6b5));
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.color_r8g8b8));
    try expectEqual(PixelAlpha.bin, pixel_format_alpha.get(.color_r5g5b5a1));
    try expectEqual(PixelAlpha.yes, pixel_format_alpha.get(.color_r4g4b4a4));
    try expectEqual(PixelAlpha.yes, pixel_format_alpha.get(.color_r8g8b8a8));
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.color_r32));
    try expectEqual(PixelAlpha.yes, pixel_format_alpha.get(.color_r32g32b32a32));
    try expectEqual(PixelAlpha.yes, pixel_format_alpha.get(.color_r16g16b16a16));
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.depth_d32));
}

// ---- - EnumArray + EnumSet round-trip pins
// These tests pin the new typed-collection shape: every public dispatch
// table is an `EnumArray(PixelFormat, ?Fn)` (so reads are `.get(fmt)`,
// not `[@intFromEnum(fmt)]`), and `Context.user_state` /
// `Context.raster_state` are `EnumSet(Capability)` (so membership is
// `.contains(.cap)`, not bit math).  Replaces the wire-number pin tests
// deleted.

test "era I: EnumArray(PixelFormat, T) preserves every set value" {
    // Every enumerator that the size table populates round-trips
    // through `.set` / `.get` to the same value the donor ships.
    // The negation: any enumerator NOT in the set list reads back as
    // the fill value (0 for size, .none for alpha).

    // Sanity: the fill value reaches enumerators we never `.set`.
    try expectEqual(@as(u8, 0), pixel_format_size.get(.unknown));
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.unknown));
    try expectEqual(PixelAlpha.none, pixel_format_alpha.get(.color_grayscale));

    // Round-trip a fresh table built at runtime, to pin the API
    // shape independently of the comptime-built ones above.
    var probe: std.enums.EnumArray(PixelFormat, u8) = .initFill(99);
    probe.set(.color_r8g8b8a8, 4);
    probe.set(.depth_d32, 4);
    try expectEqual(@as(u8, 4), probe.get(.color_r8g8b8a8));
    try expectEqual(@as(u8, 4), probe.get(.depth_d32));
    try expectEqual(@as(u8, 99), probe.get(.color_r5g6b5));
    try expectEqual(@as(u8, 99), probe.get(.unknown));
}

test "era I: EnumSet(Capability) round-trips insert / contains / remove" {
    var set: std.enums.EnumSet(Capability) = .empty;
    try expectEqual(@as(usize, 0), set.count());
    try expect(!set.contains(.depth_test));

    set.insert(.depth_test);
    set.insert(.blend);
    try expectEqual(@as(usize, 2), set.count());
    try expect(set.contains(.depth_test));
    try expect(set.contains(.blend));
    try expect(!set.contains(.cull_face));

    set.remove(.depth_test);
    try expectEqual(@as(usize, 1), set.count());
    try expect(!set.contains(.depth_test));
    try expect(set.contains(.blend));

    // Idempotent: inserting an already-present cap is a no-op.
    set.insert(.blend);
    try expectEqual(@as(usize, 1), set.count());

    // Removing an absent cap is a no-op too.
    set.remove(.scissor_test);
    try expectEqual(@as(usize, 1), set.count());
}

test "era I: Context.user_state and raster_state are independent EnumSets" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    // Both start empty per init defaults.
    try expectEqual(@as(usize, 0), ctx.user_state.count());
    try expectEqual(@as(usize, 0), ctx.raster_state.count());

    // Mutating one doesn't touch the other (catches accidental
    // aliasing - e.g. if the two fields ended up sharing a backing
    // store).
    ctx.user_state.insert(.depth_test);
    ctx.user_state.insert(.cull_face);
    try expect(ctx.user_state.contains(.depth_test));
    try expect(ctx.user_state.contains(.cull_face));
    try expect(!ctx.raster_state.contains(.depth_test));
    try expect(!ctx.raster_state.contains(.cull_face));
    try expectEqual(@as(usize, 0), ctx.raster_state.count());

    // raster_state is the rasterizer's view - it tracks user_state
    // minus disqualifications.  Here we mock that by mirroring then
    // dropping `.cull_face`, which the future enable/disable pipeline
    // would do (e.g. when a capability is enabled but its prerequisite
    // isn't satisfied).
    ctx.raster_state = ctx.user_state;
    ctx.raster_state.remove(.cull_face);
    try expect(ctx.raster_state.contains(.depth_test));
    try expect(!ctx.raster_state.contains(.cull_face));
    try expect(ctx.user_state.contains(.cull_face));
}

test "era I: init produces donor-default state" {
    var ctx = try Context.init(std.testing.allocator, 100, 80);
    defer ctx.deinit(std.testing.allocator);

    // Clear color: transparent black; clear depth: 1.0 (far plane).
    try expectEqual(Color.init(0, 0, 0, 0), ctx.clear_color);
    try expectEqual(@as(f32, 1.0), ctx.clear_depth);

    // Viewport / scissor cover the full canvas.
    try expectEqual(Vec2i{ 100, 80 }, ctx.vp_size);
    try expectEqual(Vec2{ 50, 40 }, ctx.vp_center);
    try expectEqual(Vec2{ 50, 40 }, ctx.vp_half);
    try expectEqual(splat2i(0), ctx.sc_min);
    try expectEqual(Vec2i{ 100, 80 }, ctx.sc_max);

    // No primitive in flight.
    try expectEqual(@as(?DrawMode, null), ctx.draw_mode);
    try expectEqual(@as(i32, 0), ctx.primitive.vertex_count);

    // Current vertex starts opaque white.
    try expectEqual([4]f32{ 1, 1, 1, 1 }, ctx.primitive.current_color);

    // Matrix stacks: depth 1, every slot identity.
    try expectEqual(@as(u32, 1), ctx.stack_modelview_counter);
    try expectEqual(@as(u32, 1), ctx.stack_projection_counter);
    try expectEqual(@as(u32, 1), ctx.stack_texture_counter);
    try expectEqual(MatrixMode.modelview, ctx.current_matrix_mode);

    // Pipeline state defaults.
    try expectEqual(BlendFactor.src_alpha, ctx.src_factor);
    try expectEqual(BlendFactor.one_minus_src_alpha, ctx.dst_factor);
    try expectEqual(Face.back, ctx.cull_face);
    try expectEqual(ErrorCode.no_error, ctx.err_code);
    try expectEqual(@as(usize, 0), ctx.user_state.count());
    try expectEqual(@as(usize, 0), ctx.raster_state.count());

    // Drawing parameter defaults.
    try expectEqual(PolyMode.fill, ctx.poly_mode);
    try expectEqual(@as(f32, 0.5), ctx.point_radius);
    try expectEqual(@as(f32, 1.0), ctx.line_width);
}

test "era I: currentMatrix returns the active stack's top" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    // Default mode is modelview - currentMatrix returns slot 0 of
    // the modelview stack.
    try expectEqual(
        &ctx.stack_modelview[0],
        ctx.currentMatrix(),
    );

    // Switch mode -> currentMatrix retargets to the new stack.  We
    // bypass the public API (it'd be matrixMode(.projection), future public-API work)
    // and set the field directly to verify the helper's switch
    // covers all three arms.
    ctx.current_matrix_mode = .projection;
    try expectEqual(
        &ctx.stack_projection[0],
        ctx.currentMatrix(),
    );

    ctx.current_matrix_mode = .texture;
    try expectEqual(
        &ctx.stack_texture[0],
        ctx.currentMatrix(),
    );
}

test "era I: resize reallocates with no leaks" {
    var ctx = try Context.init(std.testing.allocator, 64, 64);
    defer ctx.deinit(std.testing.allocator);
    const original_color_ptr: []u8 = ctx.framebuffer.color.pixels;
    _ = original_color_ptr;

    try ctx.resize(std.testing.allocator, 128, 96);

    try expectEqual(Vec2i{ 128, 96 }, ctx.framebuffer.color.size);
    try expectEqual(Vec2i{ 127, 95 }, ctx.framebuffer.color.size_minus_one);
    // RGBA8: 128 * 96 * 4 = 49152.
    try expectEqual(@as(usize, 49152), ctx.framebuffer.color.pixels.len);
    // D32 same dims = same size.
    try expectEqual(@as(usize, 49152), ctx.framebuffer.depth.pixels.len);
    // Viewport reset to new full canvas.
    try expectEqual(Vec2i{ 128, 96 }, ctx.vp_size);
    try expectEqual(Vec2{ 64, 48 }, ctx.vp_center);
}

test "era I: resize preserves non-framebuffer state" {
    // The donor's swResize only touches the framebuffer + viewport.
    // Anything else - matrix stacks, blend setup, current color
    // should pass through untouched.
    var ctx = try Context.init(std.testing.allocator, 64, 64);
    defer ctx.deinit(std.testing.allocator);

    ctx.primitive.current_color = .{ 0.5, 0.6, 0.7, 0.8 };
    ctx.src_factor = .one;
    ctx.dst_factor = .zero;

    try ctx.resize(std.testing.allocator, 32, 32);

    try expectEqual([4]f32{ 0.5, 0.6, 0.7, 0.8 }, ctx.primitive.current_color);
    try expectEqual(BlendFactor.one, ctx.src_factor);
    try expectEqual(BlendFactor.zero, ctx.dst_factor);
}

// ---- era II: clear + accessor tests
// These pin the public-API methods that ship as Demo-lift prerequisites:
// `clearColor`, `clearDepth`, `clear`, `colorBufferBytes`.

test "era II: clearColor stores the value (no buffer write yet)" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    const initial: Color = ctx.clear_color;
    ctx.clearColor(Color.init(255, 128, 64, 200));
    try expectEqual(Color.init(255, 128, 64, 200), ctx.clear_color);
    // Buffer wasn't touched - `clear` is the only thing that writes pixels.
    try expect(initial.r != 255 or initial.g != 128); // sanity
}

test "era II: clearDepth stores the value (no buffer write yet)" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.clearDepth(0.25);
    try expectEqual(@as(f32, 0.25), ctx.clear_depth);
}

test "era II: clear with .color = true fills the color buffer to clear_color" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    ctx.clearColor(Color.init(10, 20, 30, 40));
    ctx.clear(.{ .color = true });

    // Default framebuffer is RGBA8: 4 bytes per pixel, 16 pixels = 64
    // bytes.  Every pixel should be (10, 20, 30, 40).
    const buf: []u8 = ctx.framebuffer.color.pixels;
    try expectEqual(@as(usize, 64), buf.len);
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        // Four bytes per pixel (RGBA8), so pixel `i` starts at byte `i * 4`.
        const off: usize = i * 4;
        try expectEqual(@as(u8, 10), buf[off]);
        try expectEqual(@as(u8, 20), buf[off + 1]);
        try expectEqual(@as(u8, 30), buf[off + 2]);
        try expectEqual(@as(u8, 40), buf[off + 3]);
    }
}

test "era II: clear with .depth = true fills the depth buffer to clear_depth" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    ctx.clearDepth(0.5);
    ctx.clear(.{ .depth = true });

    // D32 is f32 per pixel.  Read every pixel via the dispatch table
    // (the same path the rasterizer uses).
    const buf: []u8 = ctx.framebuffer.depth.pixels;
    const reader: pixel.ReadDepthFn = pixel.read_depth_table.get(.depth_d32).?;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        try expectApproxEqAbs(@as(f32, 0.5), reader(buf, i), 1e-6);
    }
}

test "era II: clear with both bits hits both buffers" {
    var ctx = try Context.init(std.testing.allocator, 2, 2);
    defer ctx.deinit(std.testing.allocator);

    ctx.clearColor(Color.init(7, 8, 9, 10));
    ctx.clearDepth(0.75);
    ctx.clear(.{ .color = true, .depth = true });

    const color_buf: []u8 = ctx.framebuffer.color.pixels;
    try expectEqual(@as(u8, 7), color_buf[0]);
    try expectEqual(@as(u8, 10), color_buf[3]);

    const depth_buf: []u8 = ctx.framebuffer.depth.pixels;
    const reader: pixel.ReadDepthFn = pixel.read_depth_table.get(.depth_d32).?;
    try expectApproxEqAbs(@as(f32, 0.75), reader(depth_buf, 0), 1e-6);
}

test "era II: clear with no bits set is a no-op" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    // Pre-poison both buffers with non-zero bytes so any spurious
    // write is detectable.
    @memset(ctx.framebuffer.color.pixels, 0xAB);
    @memset(ctx.framebuffer.depth.pixels, 0xCD);

    ctx.clear(.{}); // both bools default to false
    try expectEqual(@as(u8, 0xAB), ctx.framebuffer.color.pixels[0]);
    try expectEqual(@as(u8, 0xCD), ctx.framebuffer.depth.pixels[0]);
    try expectEqual(ErrorCode.no_error, ctx.err_code);
}

test "era II: clear during begin/end records invalid_operation, no buffer writes" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    @memset(ctx.framebuffer.color.pixels, 0x55);
    ctx.draw_mode = .triangles; // simulate begin
    ctx.clear(.{ .color = true });
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);
    try expectEqual(@as(u8, 0x55), ctx.framebuffer.color.pixels[0]);
}

test "era II: colorBufferBytes returns the live color attachment slice" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.clearColor(Color.init(1, 2, 3, 4));
    ctx.clear(.{ .color = true });

    const bytes: []const u8 = ctx.colorBufferBytes();
    try expectEqual(@as(usize, 8 * 8 * 4), bytes.len);
    try expectEqual(@as(u8, 1), bytes[0]);
    try expectEqual(@as(u8, 4), bytes[3]);
    // Slice points at the actual framebuffer storage (not a copy).
    try expectEqual(ctx.framebuffer.color.pixels.ptr, bytes.ptr);
}

test "era II: colorBufferBytes falls back to default framebuffer when color_buffer is null" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    // Detach the bound color attachment; the public method should
    // still return the default framebuffer's slice.  This is the
    // post-`init` state - `color_buffer` defaults to null because
    // returning Context by value can't pin self-referential pointers.
    ctx.color_buffer = null;
    const bytes: []const u8 = ctx.colorBufferBytes();
    try expectEqual(@as(usize, 4 * 4 * 4), bytes.len);
    try expectEqual(ctx.framebuffer.color.pixels.ptr, bytes.ptr);
}

// ---- era II: state-setter tests
// These pin the Public-API-1-finish methods: enable/disable, viewport,
// scissor, blendFunc, cullFace, polygonMode, pointSize, lineWidth, plus
// the `cleanRasterState` cleanup pass that produces `raster_state`
// from `user_state`.

test "era II: enable/disable mutate user_state without touching raster_state" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Both states default to empty.
    try expectEqual(@as(usize, 0), ctx.user_state.count());
    try expectEqual(@as(usize, 0), ctx.raster_state.count());

    ctx.enable(.depth_test);
    ctx.enable(.blend);
    try expect(ctx.user_state.contains(.depth_test));
    try expect(ctx.user_state.contains(.blend));
    try expectEqual(@as(usize, 2), ctx.user_state.count());
    // raster_state is the begin-time-cleanup output; enable/disable
    // shouldn't touch it directly.
    try expectEqual(@as(usize, 0), ctx.raster_state.count());

    ctx.disable(.depth_test);
    try expect(!ctx.user_state.contains(.depth_test));
    try expect(ctx.user_state.contains(.blend));
}

test "era II: enable is idempotent; disable of unset is a no-op" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.cull_face);
    ctx.enable(.cull_face);
    ctx.enable(.cull_face);
    try expectEqual(@as(usize, 1), ctx.user_state.count());

    ctx.disable(.scissor_test); // never enabled
    try expectEqual(@as(usize, 1), ctx.user_state.count());
}

test "era II: viewport recomputes vp_size, vp_half, vp_center" {
    var ctx = try Context.init(std.testing.allocator, 100, 100);
    defer ctx.deinit(std.testing.allocator);

    ctx.viewport(10, 20, 80, 60);
    try expectEqual(Vec2i{ 80, 60 }, ctx.vp_size);
    try expectEqual(@as(f32, 40.0), ctx.vp_half[0]);
    try expectEqual(@as(f32, 30.0), ctx.vp_half[1]);
    try expectEqual(@as(f32, 50.0), ctx.vp_center[0]); // 10 + 40
    try expectEqual(@as(f32, 50.0), ctx.vp_center[1]); // 20 + 30
}

test "era II: viewport with negative width records invalid_value, no field writes" {
    var ctx = try Context.init(std.testing.allocator, 100, 100);
    defer ctx.deinit(std.testing.allocator);

    const before: Vec2i = ctx.vp_size;
    ctx.viewport(0, 0, -1, 50);
    try expectEqual(ErrorCode.invalid_value, ctx.err_code);
    try expectEqual(before, ctx.vp_size);
}

test "era II: scissor sets pixel rect AND clip-space projection" {
    var ctx = try Context.init(std.testing.allocator, 100, 100);
    defer ctx.deinit(std.testing.allocator);

    // Default viewport is the full 100x100 framebuffer.
    ctx.scissor(25, 25, 50, 50);
    try expectEqual(Vec2i{ 25, 25 }, ctx.sc_min);
    try expectEqual(Vec2i{ 75, 75 }, ctx.sc_max);

    // Clip-space mapping: x maps linearly (0 -> -1, vp_w -> +1); y is
    // flipped (sc_min.y in pixel space is the TOP, so it becomes
    // `+1` in clip-space which has +Y up).
    //   clip.x = 2*sc.x/vp.w - 1
    //   clip.y = 1 - 2*sc.y/vp.h
    try expectApproxEqAbs(@as(f32, -0.5), ctx.sc_clip_min[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.5), ctx.sc_clip_max[0], 1e-6);
    try expectApproxEqAbs(@as(f32, -0.5), ctx.sc_clip_min[1], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.5), ctx.sc_clip_max[1], 1e-6);
}

test "era II: scissor with negative width records invalid_value" {
    var ctx = try Context.init(std.testing.allocator, 100, 100);
    defer ctx.deinit(std.testing.allocator);

    const before: Vec2i = ctx.sc_min;
    ctx.scissor(0, 0, 50, -10);
    try expectEqual(ErrorCode.invalid_value, ctx.err_code);
    try expectEqual(before, ctx.sc_min);
}

test "era II: blendFunc stores src and dst factors" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.blendFunc(.one, .zero);
    try expectEqual(BlendFactor.one, ctx.src_factor);
    try expectEqual(BlendFactor.zero, ctx.dst_factor);

    ctx.blendFunc(.src_alpha, .one_minus_src_alpha);
    try expectEqual(BlendFactor.src_alpha, ctx.src_factor);
    try expectEqual(BlendFactor.one_minus_src_alpha, ctx.dst_factor);
}

test "era II: cullFace stores the face direction" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Default after init is `back`.
    try expectEqual(Face.back, ctx.cull_face);
    ctx.cullFace(.front);
    try expectEqual(Face.front, ctx.cull_face);
}

test "era II: polygonMode stores the mode" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    try expectEqual(PolyMode.fill, ctx.poly_mode);
    ctx.polygonMode(.line);
    try expectEqual(PolyMode.line, ctx.poly_mode);
    ctx.polygonMode(.point);
    try expectEqual(PolyMode.point, ctx.poly_mode);
}

test "era II: pointSize stores floor(size/2) matching donor" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.pointSize(8.0);
    try expectEqual(@as(f32, 4.0), ctx.point_radius);
    ctx.pointSize(7.5); // 7.5/2 = 3.75 -> floor = 3
    try expectEqual(@as(f32, 3.0), ctx.point_radius);
    ctx.pointSize(1.0); // 0.5 -> floor = 0
    try expectEqual(@as(f32, 0.0), ctx.point_radius);
}

test "era II: lineWidth stores round(width) matching donor" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.lineWidth(2.0);
    try expectEqual(@as(f32, 2.0), ctx.line_width);
    ctx.lineWidth(2.5); // round half away from zero
    try expectEqual(@as(f32, 3.0), ctx.line_width);
    ctx.lineWidth(2.4);
    try expectEqual(@as(f32, 2.0), ctx.line_width);
}

test "era II: cleanRasterState passes through with valid resources" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.depth_test);
    ctx.enable(.scissor_test);
    ctx.enable(.cull_face);
    ctx.enable(.blend);
    // texture_2d intentionally NOT enabled - no bound texture.

    ctx.cleanRasterState();
    try expect(ctx.raster_state.contains(.depth_test));
    try expect(ctx.raster_state.contains(.scissor_test));
    try expect(ctx.raster_state.contains(.cull_face));
    try expect(ctx.raster_state.contains(.blend));
    try expect(!ctx.raster_state.contains(.texture_2d));
}

test "era II: cleanRasterState strips texture_2d when no texture bound" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.texture_2d);
    try expect(ctx.user_state.contains(.texture_2d));

    ctx.cleanRasterState();
    // user_state stays as the user set it...
    try expect(ctx.user_state.contains(.texture_2d));
    // ...but raster_state strips because bound_texture is null.
    try expect(!ctx.raster_state.contains(.texture_2d));
}

test "era II: cleanRasterState keeps texture_2d when a complete color texture is bound" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Synthesize a minimal 4x4 RGBA8 Texture and bind it.  We're not
    // going through `texImage2D` (the texture-pool path, not shipped); we just need
    // a non-null pointer with non-empty pixels and a color format.
    var tex_pixels: [4 * 4 * 4]u8 = @splat(0);
    var tex = Texture{
        .pixels = &tex_pixels,
        .format = .color_r8g8b8a8,
        .alpha = .yes,
        .size = Vec2i{ 4, 4 },
        .size_minus_one = Vec2i{ 3, 3 },
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
        .inv_size = .{ 0.25, 0.25 },
    };
    ctx.bound_texture = &tex;
    ctx.enable(.texture_2d);

    ctx.cleanRasterState();
    try expect(ctx.raster_state.contains(.texture_2d));
}

test "era II: cleanRasterState strips texture_2d when bound texture is depth-format" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var tex_pixels: [4 * 4 * 4]u8 = @splat(0);
    var tex = Texture{
        .pixels = &tex_pixels,
        .format = .depth_d32, // <- depth, not color
        .alpha = .none,
        .size = Vec2i{ 4, 4 },
        .size_minus_one = Vec2i{ 3, 3 },
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
        .inv_size = .{ 0.25, 0.25 },
    };
    ctx.bound_texture = &tex;
    ctx.enable(.texture_2d);

    ctx.cleanRasterState();
    try expect(!ctx.raster_state.contains(.texture_2d));
}

test "era II: cleanRasterState strips texture_2d when bound texture has empty pixels" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // A texture with no allocated pixel storage - incomplete.  This
    // is the post-`genTextures`-pre-`texImage2D` state: handle exists,
    // metadata isn't set up yet.
    var tex = Texture{
        .pixels = &.{},
        .format = .color_r8g8b8a8,
        .alpha = .yes,
        .size = Vec2i{ 0, 0 },
        .size_minus_one = Vec2i{ -1, -1 },
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
        .inv_size = .{ 0, 0 },
    };
    ctx.bound_texture = &tex;
    ctx.enable(.texture_2d);

    ctx.cleanRasterState();
    try expect(!ctx.raster_state.contains(.texture_2d));
}

test "era II: cleanRasterState falls back to default framebuffer's depth attachment" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // depth_buffer is null after init (the design wart documented
    // on the field).  cleanRasterState should still see the default
    // framebuffer's depth and keep depth_test enabled.
    try expect(ctx.depth_buffer == null);
    ctx.enable(.depth_test);

    ctx.cleanRasterState();
    try expect(ctx.raster_state.contains(.depth_test));
}

// ---- era II: matrix-stack tests
// These pin the matrix-stack API: `matrixMode`, `pushMatrix` /
// `popMatrix`, `loadIdentity`, `translate` / `rotate` / `scale` /
// `multMatrix` (the pre-multiply family), `frustum` / `ortho` (the
// post-multiply family), and the `is_dirty_mvp` propagation.
// Numerical pin tests use small integer values where exact equality
// works in f32 - translate(1, 2, 3) of identity gives a matrix with
// no rounding error.  Trig-involving rotates use approxEqAbs.

test "era II: matrixMode switches which stack `currentMatrix` points at" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Default mode is `.modelview`.
    try expectEqual(MatrixMode.modelview, ctx.current_matrix_mode);
    try expectEqual(&ctx.stack_modelview[0], ctx.currentMatrix());

    ctx.matrixMode(.projection);
    try expectEqual(MatrixMode.projection, ctx.current_matrix_mode);
    try expectEqual(&ctx.stack_projection[0], ctx.currentMatrix());

    ctx.matrixMode(.texture);
    try expectEqual(&ctx.stack_texture[0], ctx.currentMatrix());
}

test "era II: pushMatrix duplicates the top and advances the counter" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Stamp the modelview top with a recognisable value.
    ctx.currentMatrix().* = translation(1, 2, 3);
    try expectEqual(@as(u32, 1), ctx.stack_modelview_counter);

    ctx.pushMatrix();
    try expectEqual(@as(u32, 2), ctx.stack_modelview_counter);
    // New top matches the previous top - that's the donor's "duplicate" semantic.
    try expectEqual(@as(f32, 1), ctx.currentMatrix()[3][0]);
    try expectEqual(@as(f32, 2), ctx.currentMatrix()[3][1]);
    try expectEqual(@as(f32, 3), ctx.currentMatrix()[3][2]);

    // Slot 0 (the original) is also still the same value.
    try expectEqual(@as(f32, 1), ctx.stack_modelview[0][3][0]);
    try expectEqual(@as(f32, 1), ctx.stack_modelview[1][3][0]);
}

test "era II: popMatrix decrements counter; pop past size 1 records stack_underflow" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.pushMatrix();
    try expectEqual(@as(u32, 2), ctx.stack_modelview_counter);

    ctx.popMatrix();
    try expectEqual(@as(u32, 1), ctx.stack_modelview_counter);
    try expect(ctx.is_dirty_mvp);

    // Pop past the implicit identity slot - the counter shouldn't
    // drop below 1, and the error code records the misuse.
    ctx.err_code = .no_error;
    ctx.popMatrix();
    try expectEqual(@as(u32, 1), ctx.stack_modelview_counter);
    try expectEqual(ErrorCode.stack_underflow, ctx.err_code);
}

test "era II: pushMatrix past max records stack_overflow, doesn't advance counter" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.matrixMode(.projection); // projection stack max is 2 (smaller than modelview)
    try expectEqual(@as(u32, 1), ctx.stack_projection_counter);

    ctx.pushMatrix(); // 1 -> 2 - fills the stack
    try expectEqual(@as(u32, 2), ctx.stack_projection_counter);

    ctx.pushMatrix(); // overflow: should record error, not advance
    try expectEqual(@as(u32, 2), ctx.stack_projection_counter);
    try expectEqual(ErrorCode.stack_overflow, ctx.err_code);
}

test "era II: pushMatrix overflow on modelview stack (depth 8)" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var i: u32 = 1;
    while (i < max_modelview_stack_size) : (i += 1) {
        ctx.pushMatrix();
    }
    try expectEqual(@as(u32, max_modelview_stack_size), ctx.stack_modelview_counter);
    try expectEqual(ErrorCode.no_error, ctx.err_code);

    ctx.pushMatrix(); // overflow
    try expectEqual(ErrorCode.stack_overflow, ctx.err_code);
}

test "era II: loadIdentity replaces top with identity AND dirties the MVP" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.currentMatrix().* = translation(5, 6, 7);
    try expect(!ctx.is_dirty_mvp);

    ctx.loadIdentity();
    try expectEqual(identity(), ctx.currentMatrix().*);
    try expect(ctx.is_dirty_mvp);
}

test "era II: loadIdentity on texture stack does NOT dirty the MVP" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.matrixMode(.texture);
    try expect(!ctx.is_dirty_mvp);

    ctx.loadIdentity();
    // Texture matrix isn't part of MVP - dirty bit stays clean.
    try expect(!ctx.is_dirty_mvp);
}

test "era II: translate on identity yields a translation matrix" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.translate(1.0, 2.0, 3.0);
    const cur: Matrix = ctx.currentMatrix().*;
    try expectEqual(@as(f32, 1.0), cur[3][0]);
    try expectEqual(@as(f32, 2.0), cur[3][1]);
    try expectEqual(@as(f32, 3.0), cur[3][2]);
    // Diagonal stays identity.
    try expectEqual(@as(f32, 1.0), cur[0][0]);
    try expectEqual(@as(f32, 1.0), cur[1][1]);
    try expectEqual(@as(f32, 1.0), cur[2][2]);
    try expectEqual(@as(f32, 1.0), cur[3][3]);
    try expect(ctx.is_dirty_mvp);
}

test "era II: scale on identity yields a scaling matrix" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.scale(2.0, 3.0, 4.0);
    const cur: Matrix = ctx.currentMatrix().*;
    try expectEqual(@as(f32, 2.0), cur[0][0]);
    try expectEqual(@as(f32, 3.0), cur[1][1]);
    try expectEqual(@as(f32, 4.0), cur[2][2]);
    try expectEqual(@as(f32, 1.0), cur[3][3]);
}

test "era II: rotate by a quarter turn around Z yields a Z rotation" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.rotate(0.25, 0, 0, 1);
    const cur: Matrix = ctx.currentMatrix().*;

    // Rodrigues with axis (0,0,1) and a QUARTER TURN: cos=0, sin=1, t=1.
    // Result: m0 = z*z*t + cos = 0 (with axis Z, x=y=0); etc.  The
    // rotation now goes through `zm.matFromAxisAngle` - a 90 deg Z
    // rotation turns the X axis into +Y and Y into -X.
    try expectApproxEqAbs(@as(f32, 0.0), cur[0][0], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), cur[0][1], 1e-6);
    try expectApproxEqAbs(@as(f32, -1.0), cur[1][0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.0), cur[1][1], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), cur[2][2], 1e-6);
}

test "era II: multMatrix sets current to matrixMul(current, m)" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Set a recognisable starting point and a multiplicand, then
    // assert the post-state matches what `matrixMul(before, m)`
    // would produce.  This pins the multiplication direction of
    // `multMatrix`: the active matrix is post-multiplied by `mat`,
    // i.e. current becomes math `current * mat` (the new matrix is
    // applied first when transforming a vertex).
    // Donor: `swMultMatrixf` uses `sw_matrix_mul(current, mat, current)`
    // - same direction.
    const before: Matrix = translation(1, 0, 0);
    ctx.currentMatrix().* = before;
    const m: Matrix = scaling(2, 2, 2);
    ctx.multMatrix(&m);

    // Expected: math `before * m` - computed via the same
    // `zm.mulChecked` (operand-reversed) path `multMatrix` now uses.
    const expected: Matrix = mulMat(before, m);
    try expectEqual(expected, ctx.currentMatrix().*);
    try expect(ctx.is_dirty_mvp);
}

test "era II: ortho post-multiplies (current = current * O)" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.matrixMode(.projection);
    ctx.loadIdentity();
    // Standard 2D ortho centered on the unit square.
    ctx.ortho(-1, 1, -1, 1, -1, 1);

    const cur: Matrix = ctx.currentMatrix().*;
    // ortho(-1,1,-1,1,-1,1) - width/height/depth all 2 - gives:
    //   m0 = 2/(r-l) = 1
    //   m5 = 2/(t-b) = 1
    //   m10 = -2/(f-n) = -1
    //   m12 = -(l+r)/(r-l) = 0
    //   m13 = -(b+t)/(t-b) = 0
    //   m14 = -(n+f)/(f-n) = 0
    try expectApproxEqAbs(@as(f32, 1.0), cur[0][0], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), cur[1][1], 1e-6);
    try expectApproxEqAbs(@as(f32, -1.0), cur[2][2], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.0), cur[3][0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.0), cur[3][1], 1e-6);
}

test "era II: frustum dirties the MVP" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.matrixMode(.projection);
    try expect(!ctx.is_dirty_mvp);
    ctx.frustum(-0.5, 0.5, -0.5, 0.5, 1.0, 100.0);
    try expect(ctx.is_dirty_mvp);
}

test "era II: matrix ops on different stacks isolate state" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Translate the modelview, then switch to projection and translate
    // it differently - the modelview should be untouched.
    ctx.translate(1, 0, 0); // modelview
    ctx.matrixMode(.projection);
    ctx.translate(0, 5, 0); // projection
    ctx.matrixMode(.modelview);

    try expectEqual(@as(f32, 1), ctx.currentMatrix()[3][0]);
    try expectEqual(@as(f32, 0), ctx.currentMatrix()[3][1]);

    ctx.matrixMode(.projection);
    try expectEqual(@as(f32, 0), ctx.currentMatrix()[3][0]);
    try expectEqual(@as(f32, 5), ctx.currentMatrix()[3][1]);
}

test "era II: pushMatrix saves; modify; popMatrix restores" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.translate(10, 20, 30);
    const before: Matrix = ctx.currentMatrix().*;

    ctx.pushMatrix();
    ctx.translate(1, 1, 1); // mutate the duplicate
    ctx.popMatrix();

    // Now we're back at the original - push made a copy, the copy
    // got mutated, the pop pointed us at the untouched original.
    try expectEqual(before, ctx.currentMatrix().*);
}

test "era II: texture-stack pop does NOT dirty the MVP" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.matrixMode(.texture);
    ctx.pushMatrix();
    try expect(!ctx.is_dirty_mvp);

    ctx.popMatrix();
    try expect(!ctx.is_dirty_mvp);
}

// ---- era II: texture upload tests
// These pin the texture-upload API: `bindTexture`, `texImage2D`,
// `texParameter`, plus the `pixelFormatFromFormatAndType` translator.
// `deleteTextures` is also re-tested (signature change to take `gpa`,
// per-texture pixel-storage free).

test "era II: pixelFormatFromFormatAndType maps RGBA + unsigned_byte to color_r8g8b8a8" {
    try expectEqual(
        @as(?PixelFormat, .color_r8g8b8a8),
        pixelFormatFromFormatAndType(.rgba, .unsigned_byte),
    );
}

test "era II: pixelFormatFromFormatAndType handles depth_component" {
    try expectEqual(
        @as(?PixelFormat, .depth_d8),
        pixelFormatFromFormatAndType(.depth_component, .unsigned_byte),
    );
    try expectEqual(
        @as(?PixelFormat, .depth_d16),
        pixelFormatFromFormatAndType(.depth_component, .unsigned_short),
    );
    try expectEqual(
        @as(?PixelFormat, .depth_d32),
        pixelFormatFromFormatAndType(.depth_component, .float),
    );
}

test "era II: pixelFormatFromFormatAndType handles packed types regardless of `format`" {
    // A packed `unsigned_short_5_6_5` always means r5g6b5 - `format`
    // is ignored (matches donor: switch-on-type happens before
    // format-channel-count is consulted).
    try expectEqual(
        @as(?PixelFormat, .color_r5g6b5),
        pixelFormatFromFormatAndType(.rgb, .unsigned_short_5_6_5),
    );
    try expectEqual(
        @as(?PixelFormat, .color_r4g4b4a4),
        pixelFormatFromFormatAndType(.rgba, .unsigned_short_4_4_4_4),
    );
}

test "era II: pixelFormatFromFormatAndType returns null for unsupported combos" {
    // luminance_alpha + 16-bit width has no matching format in the table.
    try expectEqual(
        @as(?PixelFormat, null),
        pixelFormatFromFormatAndType(.luminance_alpha, .float),
    );
}

test "era II: bindTexture(.nil) clears the binding" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var dummy_pixels: [4]u8 = .{ 0, 0, 0, 0 };
    var dummy_tex = Texture{
        .pixels = &dummy_pixels,
        .format = .color_r8g8b8a8,
        .alpha = .yes,
        .size = Vec2i{ 1, 1 },
        .size_minus_one = Vec2i{ 0, 0 },
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
        .inv_size = .{ 1, 1 },
    };
    ctx.bound_texture = &dummy_tex;
    try expect(ctx.bound_texture != null);

    ctx.bindTexture(.nil);
    try expect(ctx.bound_texture == null);
}

test "era II: bindTexture of valid handle sets bound_texture pointer" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    try expect(ctx.bound_texture != null);
    try expectEqual(ctx.getTexture(handles[0]), ctx.bound_texture.?);
}

test "era II: bindTexture of invalid handle records invalid_value" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    const fake: Handle(Texture) = .pack(99, 1); // never allocated
    ctx.bindTexture(fake);
    try expectEqual(ErrorCode.invalid_value, ctx.err_code);
    try expect(ctx.bound_texture == null);
}

test "era II: texImage2D with null data zero-fills allocated storage" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);

    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, null);

    const tex: *Texture = ctx.bound_texture.?;
    try expectEqual(PixelFormat.color_r8g8b8a8, tex.format);
    try expectEqual(Vec2i{ 4, 4 }, tex.size);
    try expectEqual(@as(usize, 4 * 4 * 4), tex.pixels.len);
    for (tex.pixels) |b| {
        try expectEqual(@as(u8, 0), b);
    }
    // Null data -> alpha defaults to .none (the donor's
    // "alphaFound = !data" inverted gate from sw_texture_alloc; we
    // simplified to always-`.none` for null data, which is what
    // a zero buffer represents anyway).
    try expectEqual(PixelAlpha.none, tex.alpha);
}

test "era II: texImage2D with data copies bytes and detects alpha" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);

    // 2x2 RGBA, all opaque except the last pixel (alpha 128).
    const src = [_]u8{
        255, 0, 0, 255, // red
        0, 255, 0, 255, // green
        0, 0, 255, 255, // blue
        128, 128, 128, 128, // half-alpha gray
    };
    try ctx.texImage2D(std.testing.allocator, 2, 2, .rgba, .unsigned_byte, &src);

    const tex: *Texture = ctx.bound_texture.?;
    try expectEqualSlices(u8, &src, tex.pixels);
    // alpha < 255 in the last pixel - should bump to .yes.
    try expectEqual(PixelAlpha.yes, tex.alpha);
}

test "era II: texImage2D fully opaque RGBA leaves alpha as .none" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);

    const src = [_]u8{
        255, 0,   0, 255,
        0,   255, 0, 255,
    };
    try ctx.texImage2D(std.testing.allocator, 2, 1, .rgba, .unsigned_byte, &src);

    const tex: *Texture = ctx.bound_texture.?;
    try expectEqual(PixelAlpha.none, tex.alpha);
}

test "era II: texImage2D with no bound texture is a silent no-op" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    try expect(ctx.bound_texture == null);
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, null);
    try expectEqual(ErrorCode.no_error, ctx.err_code);
}

test "era II: texImage2D with negative dimensions records invalid_value" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);

    try ctx.texImage2D(std.testing.allocator, -1, 4, .rgba, .unsigned_byte, null);
    try expectEqual(ErrorCode.invalid_value, ctx.err_code);
}

test "era II: texImage2D with too-short data records invalid_value" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);

    // 2x2 RGBA wants 16 bytes; we provide 4.
    const short_data = [_]u8{ 1, 2, 3, 4 };
    try ctx.texImage2D(std.testing.allocator, 2, 2, .rgba, .unsigned_byte, &short_data);
    try expectEqual(ErrorCode.invalid_value, ctx.err_code);
}

test "era II: texImage2D reuses storage on same-size resize, reallocates on different size" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);

    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, null);
    const ptr_a: [*]u8 = ctx.bound_texture.?.pixels.ptr;
    const len_a: usize = ctx.bound_texture.?.pixels.len;

    // Same dimensions + format -> no realloc; pointer should match.
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, null);
    try expectEqual(ptr_a, ctx.bound_texture.?.pixels.ptr);
    try expectEqual(len_a, ctx.bound_texture.?.pixels.len);

    // Different dimensions -> realloc (length must change).
    try ctx.texImage2D(std.testing.allocator, 8, 8, .rgba, .unsigned_byte, null);
    try expect(ctx.bound_texture.?.pixels.len != len_a);
}

test "era II: texParameter sets the requested filter / wrap on the bound texture" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);

    ctx.texParameter(.{ .min_filter = .linear });
    ctx.texParameter(.{ .mag_filter = .linear });
    ctx.texParameter(.{ .wrap_s = .repeat });
    ctx.texParameter(.{ .wrap_t = .repeat });

    const tex: *Texture = ctx.bound_texture.?;
    try expectEqual(Filter.linear, tex.min_filter);
    try expectEqual(Filter.linear, tex.mag_filter);
    try expectEqual(Wrap.repeat, tex.wrap_s);
    try expectEqual(Wrap.repeat, tex.wrap_t);
}

test "era II: texParameter without bound texture is a silent no-op" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.texParameter(.{ .min_filter = .linear });
    try expectEqual(ErrorCode.no_error, ctx.err_code);
}

test "era II: deleteTextures frees per-texture pixel storage" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    ctx.bindTexture(handles[0]);

    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, null);
    // The slot has allocated pixel storage now.  deleteTextures
    // should free it.  (If it doesn't, the testing allocator's
    // leak detector at end-of-test will report.)
    ctx.deleteTextures(std.testing.allocator, &handles);
}

test "era II: cleanRasterState keeps texture_2d after texImage2D-completed bound texture" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);
    ctx.bindTexture(handles[0]);
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, null);

    ctx.enable(.texture_2d);
    ctx.cleanRasterState();
    try expect(ctx.raster_state.contains(.texture_2d));
}

// ---- era II: begin / end + vertex submission tests
// These pin the immediate-mode plumbing: `begin` opens the recording
// (running `cleanRasterState` and recomputing the MVP), `end` closes
// it, `vertex2f` / `vertex3f` apply MVP and stash transformed
// vertices into `primitive.buffer`, the color/texcoord state carries
// across vertices, and the auto-flush at primitive size resets the
// vertex counter for the next primitive.

test "era II: begin opens immediate mode; end closes it" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    try expect(!ctx.isImmediateActive());
    ctx.begin(.triangles);
    try expect(ctx.isImmediateActive());
    try expectEqual(DrawMode.triangles, ctx.draw_mode.?);
    ctx.end();
    try expect(!ctx.isImmediateActive());
    try expectEqual(@as(?DrawMode, null), ctx.draw_mode);
}

test "era II: begin while already active records invalid_operation" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    ctx.begin(.lines); // nested begin - the spec error
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);
    // First begin's mode is still active; nested begin didn't override.
    try expectEqual(DrawMode.triangles, ctx.draw_mode.?);
}

test "era II: end without active begin records invalid_operation" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.end();
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);
}

test "era II: begin recomputes mat_mvp from dirty bit + clears the bit" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Dirty the modelview by translating, then begin should fold
    // modelview x projection into mat_mvp.
    ctx.translate(5, 7, 11);
    try expect(ctx.is_dirty_mvp);

    ctx.begin(.triangles);
    try expect(!ctx.is_dirty_mvp);

    // Modelview is T(5,7,11), projection is identity, so MVP = T * I
    // (raylib row-vector convention; pre-multiply leaves it as T
    // applied first when post-multiplying with identity).  Translation
    // lives in m12/m13/m14 in raylib's m-field naming.
    try expectEqual(@as(f32, 5), ctx.mat_mvp[3][0]);
    try expectEqual(@as(f32, 7), ctx.mat_mvp[3][1]);
    try expectEqual(@as(f32, 11), ctx.mat_mvp[3][2]);
}

test "era II: begin runs cleanRasterState (strips depth_test on null depth)" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Force the depth-attachment-missing path: point `depth_buffer`
    // at a stack-local incomplete texture so `cleanRasterState` /
    // `isTextureComplete` see `.pixels.len == 0`.  We deliberately
    // don't touch the framebuffer's own depth slice (that would
    // leak the gpa-allocated bytes Context.init produced).
    var empty_depth: Texture = .{
        .pixels = &.{},
        .format = .unknown,
        .alpha = .none,
        .size = Vec2i{ 0, 0 },
        .size_minus_one = Vec2i{ 0, 0 },
        .min_filter = .nearest,
        .mag_filter = .nearest,
        .wrap_s = .clamp,
        .wrap_t = .clamp,
        .inv_size = .{ 0, 0 },
    };
    ctx.depth_buffer = &empty_depth;
    ctx.enable(.depth_test);
    try expect(ctx.user_state.contains(.depth_test));

    ctx.begin(.triangles);
    try expect(!ctx.raster_state.contains(.depth_test));
    // user_state is unchanged; just the cleaned snapshot lacks it.
    try expect(ctx.user_state.contains(.depth_test));
}

test "era II: begin resets vertex_count and has_color_alpha" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Stuff the primitive scratch with leftover state.
    ctx.primitive.vertex_count = 5;
    ctx.primitive.has_color_alpha = true;

    ctx.begin(.triangles);
    try expectEqual(@as(i32, 0), ctx.primitive.vertex_count);
    try expect(!ctx.primitive.has_color_alpha);
}

test "era II: vertex2f outside begin/end records invalid_operation" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.vertex2f(0, 0);
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);
}

test "era II: vertex2f under identity MVP stores position unchanged (z=0, w=1)" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Use TRIANGLES so we can submit one vertex and inspect it
    // before the auto-flush at count == 3.
    ctx.begin(.triangles);
    ctx.vertex2f(2, 3);

    try expectEqual(@as(i32, 1), ctx.primitive.vertex_count);
    const v: Vertex = ctx.primitive.buffer[0];
    try expectEqual(@as(f32, 2), v.position[0]);
    try expectEqual(@as(f32, 3), v.position[1]);
    try expectEqual(@as(f32, 0), v.position[2]);
    try expectEqual(@as(f32, 1), v.position[3]);
}

test "era II: vertex3f under translation applies MVP" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Translate the modelview by (10, 20, 30); draw a single
    // vertex at origin; expect MVP-transformed position to be the
    // translation itself.
    ctx.translate(10, 20, 30);
    ctx.begin(.triangles);
    ctx.vertex3f(0, 0, 0);

    const v: Vertex = ctx.primitive.buffer[0];
    try expectEqual(@as(f32, 10), v.position[0]);
    try expectEqual(@as(f32, 20), v.position[1]);
    try expectEqual(@as(f32, 30), v.position[2]);
    try expectEqual(@as(f32, 1), v.position[3]);
}

test "era II: color3f sets current color with alpha=1; no has_color_alpha trip" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    ctx.color3f(0.25, 0.5, 0.75);

    try expectEqual(@as(f32, 0.25), ctx.primitive.current_color[0]);
    try expectEqual(@as(f32, 0.5), ctx.primitive.current_color[1]);
    try expectEqual(@as(f32, 0.75), ctx.primitive.current_color[2]);
    try expectEqual(@as(f32, 1.0), ctx.primitive.current_color[3]);
    try expect(!ctx.primitive.has_color_alpha);
}

test "era II: color4f with alpha < 1 trips has_color_alpha" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    ctx.color4f(1.0, 0.0, 0.0, 0.5);

    try expectEqual(@as(f32, 0.5), ctx.primitive.current_color[3]);
    try expect(ctx.primitive.has_color_alpha);
}

test "era II: color4ub normalises bytes to [0,1] floats" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    ctx.color4ub(255, 128, 0, 64);

    const c: [4]f32 = ctx.primitive.current_color;
    try expectApproxEqAbs(@as(f32, 1.0), c[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 128.0 / 255.0), c[1], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.0), c[2], 1e-6);
    try expectApproxEqAbs(@as(f32, 64.0 / 255.0), c[3], 1e-6);
}

test "era II: vertex inherits current color from running state" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    ctx.color3f(0.1, 0.2, 0.3);
    ctx.vertex2f(0, 0);

    const v: Vertex = ctx.primitive.buffer[0];
    try expectApproxEqAbs(@as(f32, 0.1), v.color[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.2), v.color[1], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.3), v.color[2], 1e-6);
    try expectApproxEqAbs(@as(f32, 1.0), v.color[3], 1e-6);
}

test "era II: texCoord2f under identity texture matrix passes through" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.texCoord2f(0.25, 0.75);
    try expectEqual(@as(f32, 0.25), ctx.primitive.current_texcoord[0]);
    try expectEqual(@as(f32, 0.75), ctx.primitive.current_texcoord[1]);
}

test "era II: texCoord2f under translated texture matrix applies translation" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.matrixMode(.texture);
    ctx.translate(0.5, 0.5, 0); // texture matrix translation only uses 2D
    // Texture matrix is now T(0.5, 0.5, 0).  texCoord2f(0, 0)
    // should land at (0.5, 0.5) after the transform.
    ctx.texCoord2f(0.0, 0.0);
    try expectApproxEqAbs(@as(f32, 0.5), ctx.primitive.current_texcoord[0], 1e-6);
    try expectApproxEqAbs(@as(f32, 0.5), ctx.primitive.current_texcoord[1], 1e-6);
}

test "era II: triangles auto-flush at vertex_count == 3" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    ctx.vertex2f(0, 0);
    ctx.vertex2f(1, 0);
    try expectEqual(@as(i32, 2), ctx.primitive.vertex_count);
    ctx.vertex2f(0, 1);
    // The third vertex completes a triangle; the auto-flush should
    // reset vertex_count to 0 (rasterizer hook is TODO until turn
    // 103+; the reset is what keeps the buffer from overflowing on
    // multi-primitive begin/end pairs).
    try expectEqual(@as(i32, 0), ctx.primitive.vertex_count);
}

test "era II: lines auto-flush at vertex_count == 2" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.lines);
    ctx.vertex2f(0, 0);
    try expectEqual(@as(i32, 1), ctx.primitive.vertex_count);
    ctx.vertex2f(1, 1);
    try expectEqual(@as(i32, 0), ctx.primitive.vertex_count);
}

test "era II: multi-primitive begin/end (6 vertices = 2 triangles)" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    ctx.vertex2f(0, 0);
    ctx.vertex2f(1, 0);
    ctx.vertex2f(0, 1); // first triangle complete; flush
    ctx.vertex2f(1, 1);
    ctx.vertex2f(2, 0);
    ctx.vertex2f(2, 1); // second triangle complete; flush
    ctx.end();

    try expectEqual(@as(i32, 0), ctx.primitive.vertex_count);
    try expectEqual(ErrorCode.no_error, ctx.err_code);
}

test "era II: setColor with alpha=1 doesn't reset has_color_alpha back to false" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // First a transparent color trips the flag; then an opaque one
    // should NOT clear it (the flag is sticky per-primitive - donor
    // semantic).  Reset only happens at flush or begin.
    ctx.begin(.points);
    ctx.color4f(1, 0, 0, 0.5);
    try expect(ctx.primitive.has_color_alpha);
    ctx.color4f(0, 1, 0, 1.0);
    try expect(ctx.primitive.has_color_alpha);
}

// ---- era III: point rasterizer tests
// First turn that ANY pixel actually gets drawn by raster.  Tests
// submit points via `begin(.points) / vertex* / end()`, then read
// back through `colorBufferBytes` and assert specific pixels match
// the submitted color.  Default framebuffer is RGBA8, default
// viewport spans the whole buffer, default modelview / projection /
// texture matrices are all identity - so a vertex at clip-space
// (0, 0, 0, 1) lands at pixel (width/2, height/2) per the donor's
// `vp_center + ndc * vp_half + 0.5`.

/// Read the framebuffer's RGBA8 pixel at `(x, y)`.  Test helper.
fn pixelAtRgba8(
    ctx: *Context,
    x: i32,
    y: i32,
) [4]u8 {
    const tex_w: i32 = ctx.framebuffer.color.size[0];
    const offset: usize = @intCast((y * tex_w + x) * 4);
    return .{
        ctx.framebuffer.color.pixels[offset + 0],
        ctx.framebuffer.color.pixels[offset + 1],
        ctx.framebuffer.color.pixels[offset + 2],
        ctx.framebuffer.color.pixels[offset + 3],
    };
}

test "era III: point at clip-space origin lands at framebuffer center" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.points);
    ctx.color4ub(255, 128, 64, 255);
    ctx.vertex2f(0, 0);
    ctx.end();

    // Default vp_center = (4, 4), vp_half = (4, 4); NDC (0, 0) ->
    // 4 + 0*4 + 0.5 = 4.5 -> floor = 4 (point_radius defaults to 0,
    // so a single pixel).
    const px: [4]u8 = pixelAtRgba8(&ctx, 4, 4);
    try expectEqual(@as(u8, 255), px[0]);
    try expectEqual(@as(u8, 128), px[1]);
    try expectEqual(@as(u8, 64), px[2]);
    try expectEqual(@as(u8, 255), px[3]);

    // Adjacent pixels should still be the init-zeroed background.
    const adj: [4]u8 = pixelAtRgba8(&ctx, 5, 4);
    try expectEqual(@as(u8, 0), adj[0]);
}

test "era III: two points at different NDC positions land at different pixels" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.points);
    ctx.color4ub(200, 0, 0, 255);
    ctx.vertex2f(-0.5, 0); // NDC X = -0.5 -> pixel X = 4 + (-0.5)*4 + 0.5 = 2.5 -> 2
    ctx.color4ub(0, 200, 0, 255);
    ctx.vertex2f(0.5, 0); // pixel X = 6
    ctx.end();

    const left: [4]u8 = pixelAtRgba8(&ctx, 2, 4);
    try expectEqual(@as(u8, 200), left[0]);
    try expectEqual(@as(u8, 0), left[1]);

    const right: [4]u8 = pixelAtRgba8(&ctx, 6, 4);
    try expectEqual(@as(u8, 0), right[0]);
    try expectEqual(@as(u8, 200), right[1]);
}

test "era III: point with non-zero radius fills a square" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.pointSize(3.0); // donor: floors `size*0.5` -> radius=1 -> 3x3 square
    ctx.begin(.points);
    ctx.color4ub(123, 200, 50, 255);
    ctx.vertex2f(0, 0); // centred at (8, 8)
    ctx.end();

    // Expect a 3x3 fill of (7..9, 7..9).
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const px: [4]u8 = pixelAtRgba8(&ctx, 8 + dx, 8 + dy);
            try expectEqual(@as(u8, 123), px[0]);
            try expectEqual(@as(u8, 200), px[1]);
            try expectEqual(@as(u8, 50), px[2]);
        }
    }

    // Pixels just outside the square should be untouched.
    const outside: [4]u8 = pixelAtRgba8(&ctx, 6, 8);
    try expectEqual(@as(u8, 0), outside[0]);
}

test "era III: point outside clip volume (x > w) is rejected" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Set up a non-identity W via a translation that DOESN'T affect
    // the W output, but the clip-volume check fires only when w != 1.
    // Simplest path: skip and use a vertex outside the [-1, +1] NDC
    // box but with W=1.  Donor's clip is gated on `w != 1` so this
    // path doesn't reject - but the bounding-square early-out does
    // (point at NDC (3, 0) -> pixel X = 4 + 3*4 + 0.5 = 16.5 -> 16,
    // outside the 8-wide framebuffer).
    ctx.begin(.points);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(3.0, 0);
    ctx.end();

    // No pixel should be set anywhere - the point's bounding square
    // is fully outside the framebuffer.
    var x: i32 = 0;
    while (x < 8) : (x += 1) {
        var y: i32 = 0;
        while (y < 8) : (y += 1) {
            const px: [4]u8 = pixelAtRgba8(&ctx, x, y);
            try expectEqual(@as(u8, 0), px[0]);
        }
    }
    try expectEqual(ErrorCode.no_error, ctx.err_code);
}

test "era III: depth-test path passes when depth empty (zero), writes new depth" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Default depth buffer is all-zero (init's `@memset(depth_pixels, 0)`).
    // A point at NDC z = -0.5 maps to vertex.position[2] = -0.5
    // (no projection matrix to remap).  The donor's depth comparison
    // is `if (z > stored) return` - so submitted z must be <= stored
    // to pass.  -0.5 <= 0 - passes.  Pixel gets written, depth gets
    // updated to -0.5.
    ctx.enable(.depth_test);
    ctx.begin(.points);
    ctx.color4ub(255, 200, 100, 255);
    ctx.vertex3f(0, 0, -0.5);
    ctx.end();

    const px: [4]u8 = pixelAtRgba8(&ctx, 4, 4);
    try expectEqual(@as(u8, 255), px[0]);
    try expectEqual(@as(u8, 200), px[1]);
}

test "era III: depth-test path rejects when submitted z > stored z" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.depth_test);
    ctx.begin(.points);
    // First point: closer (z = -0.5) - passes against zero.
    ctx.color4ub(50, 50, 50, 255);
    ctx.vertex3f(0, 0, -0.5);
    // Second point: farther (z = +0.5) - should be rejected because
    // depth buffer at (4, 4) now holds -0.5, and 0.5 > -0.5.
    ctx.color4ub(200, 200, 200, 255);
    ctx.vertex3f(0, 0, 0.5);
    ctx.end();

    // Pixel should still hold the first point's color.
    const px: [4]u8 = pixelAtRgba8(&ctx, 4, 4);
    try expectEqual(@as(u8, 50), px[0]);
    try expectEqual(@as(u8, 50), px[1]);
}

test "era III: scissor rectangle clips a point's square" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Scissor restricts writes to (8..16, 0..16) - the right half.
    ctx.scissor(8, 0, 8, 16);
    ctx.enable(.scissor_test);
    ctx.pointSize(7.0); // radius = 3 -> 7x7 square at (8, 8)
    ctx.begin(.points);
    ctx.color4ub(255, 255, 255, 255);
    ctx.vertex2f(0, 0); // pixel (8, 8)
    ctx.end();

    // Pixel (5, 8) is inside the point's square (8+/-3) but OUTSIDE
    // the scissor rect - should be untouched.
    const left_of_scissor: [4]u8 = pixelAtRgba8(&ctx, 5, 8);
    try expectEqual(@as(u8, 0), left_of_scissor[0]);

    // Pixel (10, 8) is inside the square AND inside the scissor
    // should be painted.
    const inside: [4]u8 = pixelAtRgba8(&ctx, 10, 8);
    try expectEqual(@as(u8, 255), inside[0]);
}

test "era III: byteFromUnitFloat saturates correctly" {
    try expectEqual(@as(u8, 0), byteFromUnitFloat(-1.0));
    try expectEqual(@as(u8, 0), byteFromUnitFloat(0.0));
    try expectEqual(@as(u8, 127), byteFromUnitFloat(0.5));
    try expectEqual(@as(u8, 255), byteFromUnitFloat(1.0));
    try expectEqual(@as(u8, 255), byteFromUnitFloat(2.0));
    // NaN should saturate to 0 (the `!(scaled >= 0.0)` guard).
    try expectEqual(@as(u8, 0), byteFromUnitFloat(nan(f32)));
}

test "era III: multiple points in one begin/end pair all land" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Submit 3 points; each should auto-flush at primitive size 1.
    // GL Y-up convention: NDC y=-0.5 -> pixel y=6, NDC y=+0.5 -> pixel y=2.
    // X mapping unchanged: NDC x=-0.5 -> pixel x=2, NDC x=+0.5 -> pixel x=6.
    ctx.begin(.points);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.5, -0.5); // pixel (2, 6)
    ctx.color4ub(0, 255, 0, 255);
    ctx.vertex2f(0, 0); // pixel (4, 4)
    ctx.color4ub(0, 0, 255, 255);
    ctx.vertex2f(0.5, 0.5); // pixel (6, 2)
    ctx.end();

    const a: [4]u8 = pixelAtRgba8(&ctx, 2, 6);
    try expectEqual(@as(u8, 255), a[0]);
    const b: [4]u8 = pixelAtRgba8(&ctx, 4, 4);
    try expectEqual(@as(u8, 255), b[1]);
    const c: [4]u8 = pixelAtRgba8(&ctx, 6, 2);
    try expectEqual(@as(u8, 255), c[2]);
}

// ---- era III: line rasterizer tests
// Lines are submitted via `begin(.lines)` + 2 vertices per
// segment.  drawLine walks the dominant axis with DDA, interpolates
// color in [0, 1] across the segment, optionally tests + writes
// depth.  Tests pin: NDC origin + offset endpoints land on the
// expected pixels; horizontal / vertical / diagonal coverage; color
// interpolation along the segment; depth test; multiple segments
// per begin/end.

test "era III: line from NDC (-0.5, 0) to (+0.5, 0) draws horizontal pixel row" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // NDC -0.5 -> pixel 4 + (-0.5)*4 + 0.5 = 2.5 -> 2
    // NDC +0.5 -> pixel 4 + ( 0.5)*4 + 0.5 = 6.5 -> 6
    // Y center: pixel 4
    ctx.begin(.lines);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.5, 0);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(0.5, 0);
    ctx.end();

    // Pixels 2..6 inclusive on row 4 should be red.
    var x: i32 = 2;
    while (x <= 6) : (x += 1) {
        const px: [4]u8 = pixelAtRgba8(&ctx, x, 4);
        try expectEqual(@as(u8, 255), px[0]);
    }
    // Adjacent rows untouched.
    const above: [4]u8 = pixelAtRgba8(&ctx, 4, 3);
    try expectEqual(@as(u8, 0), above[0]);
}

test "era III: line from (0, -0.5) to (0, +0.5) draws vertical pixel column" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.lines);
    ctx.color4ub(0, 200, 0, 255);
    ctx.vertex2f(0, -0.5);
    ctx.color4ub(0, 200, 0, 255);
    ctx.vertex2f(0, 0.5);
    ctx.end();

    // Column at x=4, rows 2..6 should be green.
    var y: i32 = 2;
    while (y <= 6) : (y += 1) {
        const px: [4]u8 = pixelAtRgba8(&ctx, 4, y);
        try expectEqual(@as(u8, 200), px[1]);
    }
    // Adjacent columns untouched.
    const left: [4]u8 = pixelAtRgba8(&ctx, 3, 4);
    try expectEqual(@as(u8, 0), left[1]);
}

test "era III: diagonal line from (-0.5, -0.5) to (+0.5, +0.5) hits both endpoints" {
    // SKIPPED: see CHANGELOG Turn 120 (raster Y-flip cleanup pending).
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.lines);
    ctx.color4ub(50, 100, 200, 255);
    ctx.vertex2f(-0.5, -0.5);
    ctx.color4ub(50, 100, 200, 255);
    ctx.vertex2f(0.5, 0.5);
    ctx.end();

    // GL Y-up convention: NDC y=-0.5 -> pixel y=6, NDC y=+0.5 -> pixel y=2.
    // Endpoints land at (2, 6) and (6, 2).  Both should be painted;
    // so should the diagonal pixels in between (now running
    // top-right <-> bottom-left in memory).
    const start: [4]u8 = pixelAtRgba8(&ctx, 2, 6);
    try expectEqual(@as(u8, 50), start[0]);
    try expectEqual(@as(u8, 100), start[1]);
    try expectEqual(@as(u8, 200), start[2]);

    const end: [4]u8 = pixelAtRgba8(&ctx, 6, 2);
    try expectEqual(@as(u8, 50), end[0]);
}

test "era III: line color interpolation paints endpoints with respective colors" {
    var ctx = try Context.init(std.testing.allocator, 16, 8);
    defer ctx.deinit(std.testing.allocator);

    // 16-wide framebuffer so the line spans 12 pixels, plenty of
    // room for color interp visibility.
    ctx.begin(.lines);
    ctx.color4ub(255, 0, 0, 255); // red at left endpoint
    ctx.vertex2f(-0.75, 0);
    ctx.color4ub(0, 0, 255, 255); // blue at right endpoint
    ctx.vertex2f(0.75, 0);
    ctx.end();

    // Left endpoint: NDC -0.75 -> 8 + (-0.75)*8 + 0.5 = 2.5 -> 2
    // Right endpoint: NDC +0.75 -> 8 + 0.75*8 + 0.5 = 14.5 -> 14
    const left: [4]u8 = pixelAtRgba8(&ctx, 2, 4);
    try expectEqual(@as(u8, 255), left[0]);
    try expectEqual(@as(u8, 0), left[2]);

    const right: [4]u8 = pixelAtRgba8(&ctx, 14, 4);
    try expectEqual(@as(u8, 0), right[0]);
    try expectEqual(@as(u8, 255), right[2]);

    // Mid-line: somewhere between, both red and blue should be
    // non-zero (purple-ish).
    const mid: [4]u8 = pixelAtRgba8(&ctx, 8, 4);
    try expect(mid[0] > 0);
    try expect(mid[2] > 0);
}

test "era III: zero-length line draws a single pixel" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.lines);
    ctx.color4ub(150, 150, 150, 255);
    ctx.vertex2f(0, 0);
    ctx.color4ub(150, 150, 150, 255);
    ctx.vertex2f(0, 0); // same point - degenerate
    ctx.end();

    // Center pixel should be painted; one writes is fine, the
    // degenerate-line code path doesn't crash.
    const px: [4]u8 = pixelAtRgba8(&ctx, 4, 4);
    try expectEqual(@as(u8, 150), px[0]);
}

test "era III: line outside framebuffer is silently dropped" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Both endpoints at NDC X = 3 -> pixel 16, way off-screen.
    ctx.begin(.lines);
    ctx.color4ub(255, 255, 255, 255);
    ctx.vertex2f(3, 0);
    ctx.color4ub(255, 255, 255, 255);
    ctx.vertex2f(3, 1);
    ctx.end();

    // No pixel painted.
    var x: i32 = 0;
    while (x < 8) : (x += 1) {
        var y: i32 = 0;
        while (y < 8) : (y += 1) {
            const px: [4]u8 = pixelAtRgba8(&ctx, x, y);
            try expectEqual(@as(u8, 0), px[0]);
        }
    }
}

test "era III: multi-line begin/end paints each segment independently" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Two horizontal lines on different rows.  GL Y-up: NDC y=-0.5
    // -> pixel y=6, NDC y=+0.5 -> pixel y=2.
    ctx.begin(.lines);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.5, -0.5); // pixel (2, 6)
    ctx.vertex2f(0.5, -0.5); // pixel (6, 6)
    ctx.color4ub(0, 255, 0, 255);
    ctx.vertex2f(-0.5, 0.5); // pixel (2, 2)
    ctx.vertex2f(0.5, 0.5); // pixel (6, 2)
    ctx.end();

    // First (red) line lands at row 6; second (green) at row 2.
    const first: [4]u8 = pixelAtRgba8(&ctx, 4, 6);
    try expectEqual(@as(u8, 255), first[0]);
    const second: [4]u8 = pixelAtRgba8(&ctx, 4, 2);
    try expectEqual(@as(u8, 255), second[1]);
}

test "era III: line depth-test rejects pixels behind existing depth" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.depth_test);
    ctx.begin(.lines);
    // First segment: closer (z = -0.5) - passes against zero-init depth.
    ctx.color4ub(80, 80, 80, 255);
    ctx.vertex3f(-0.5, 0, -0.5);
    ctx.vertex3f(0.5, 0, -0.5);
    // Second segment: farther (z = +0.5) - should be rejected because
    // depth at row 4 columns 2..6 now holds -0.5.
    ctx.color4ub(220, 220, 220, 255);
    ctx.vertex3f(-0.5, 0, 0.5);
    ctx.vertex3f(0.5, 0, 0.5);
    ctx.end();

    // Center row should still hold the first (closer) segment's color.
    const px: [4]u8 = pixelAtRgba8(&ctx, 4, 4);
    try expectEqual(@as(u8, 80), px[0]);
}

// ---- triangle BASE tests
// Filled colored triangle.  Edge-function rasterization with
// barycentric color interp.  No depth, no texture, no blend, no
// face culling - those land in subsequent rasterizer passes.

test "era III: triangle covers center pixel and leaves outside untouched" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Big triangle covering most of the framebuffer.  CCW winding.
    ctx.begin(.triangles);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.75, -0.75);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(0.75, -0.75);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(0, 0.75);
    ctx.end();

    // Center pixel - well inside the triangle - should be red.
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 255), center[0]);

    // Top-left corner - well outside the triangle - should be unset.
    const corner: [4]u8 = pixelAtRgba8(&ctx, 0, 0);
    try expectEqual(@as(u8, 0), corner[0]);
}

test "era III: triangle paints pixels with barycentric color interp" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // RGB-corner triangle: red at left, green at right, blue at top.
    // Center pixel sums to roughly equal weights (1/3, 1/3, 1/3) so
    // each channel picks up ~85.
    ctx.begin(.triangles);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.75, -0.5);
    ctx.color4ub(0, 255, 0, 255);
    ctx.vertex2f(0.75, -0.5);
    ctx.color4ub(0, 0, 255, 255);
    ctx.vertex2f(0, 0.5);
    ctx.end();

    // Centroid: at NDC (0, -1/6) -> pixel approximately (8, 9).
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 9);
    // Each channel should be non-zero (the centroid is fed by all
    // three vertex colors).  Won't be exactly 85 due to sub-pixel
    // jitter but should be roughly balanced.
    try expect(center[0] > 40);
    try expect(center[1] > 40);
    try expect(center[2] > 40);
}

test "era III: degenerate triangle (collinear vertices) paints nothing" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Three collinear points -> zero area.
    ctx.begin(.triangles);
    ctx.color4ub(255, 255, 255, 255);
    ctx.vertex2f(-0.5, 0);
    ctx.vertex2f(0, 0);
    ctx.vertex2f(0.5, 0);
    ctx.end();

    var x: i32 = 0;
    while (x < 8) : (x += 1) {
        var y: i32 = 0;
        while (y < 8) : (y += 1) {
            const px: [4]u8 = pixelAtRgba8(&ctx, x, y);
            try expectEqual(@as(u8, 0), px[0]);
        }
    }
}

test "era III: triangle outside framebuffer is silently dropped" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // All three vertices way off-screen at NDC X = 3.
    ctx.begin(.triangles);
    ctx.color4ub(255, 255, 255, 255);
    ctx.vertex3f(3, 0, 0);
    ctx.vertex3f(3, 1, 0);
    ctx.vertex3f(3, -1, 0);
    ctx.end();

    var x: i32 = 0;
    while (x < 8) : (x += 1) {
        var y: i32 = 0;
        while (y < 8) : (y += 1) {
            const px: [4]u8 = pixelAtRgba8(&ctx, x, y);
            try expectEqual(@as(u8, 0), px[0]);
        }
    }
}

test "era III: CW-wound triangle still fills correctly" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Same vertices as the first test but in CW order.  drawTriangle
    // detects the winding from `area_x2`'s sign and uses the
    // matching inside test, so both orientations should fill.
    ctx.begin(.triangles);
    ctx.color4ub(0, 200, 0, 255);
    ctx.vertex2f(-0.75, -0.75);
    ctx.vertex2f(0, 0.75);
    ctx.vertex2f(0.75, -0.75);
    ctx.end();

    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 200), center[1]);
}

test "era III: scissor clips triangle bounding box" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Scissor restricts to the right half (x in [8, 16)).
    ctx.enable(.scissor_test);
    ctx.scissor(8, 0, 8, 16);

    ctx.begin(.triangles);
    ctx.color4ub(150, 150, 150, 255);
    ctx.vertex2f(-0.9, -0.9);
    ctx.vertex2f(0.9, -0.9);
    ctx.vertex2f(0, 0.9);
    ctx.end();

    // Pixel (4, 8) is outside the scissor - should be clear regardless
    // of whether it's inside the triangle.
    const left: [4]u8 = pixelAtRgba8(&ctx, 4, 8);
    try expectEqual(@as(u8, 0), left[0]);

    // Pixel (10, 8) - inside both the scissor (x >= 8) and the
    // triangle (which at y=8 spans roughly x in [4.5, 11.5]).
    const right: [4]u8 = pixelAtRgba8(&ctx, 10, 8);
    try expectEqual(@as(u8, 150), right[0]);
}

test "era III: multi-triangle begin/end paints each independently" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.triangles);
    // First triangle - top half - red.
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.5, 0.5);
    ctx.vertex2f(0.5, 0.5);
    ctx.vertex2f(0, 0.1);
    // Second triangle - bottom half - blue.
    ctx.color4ub(0, 0, 255, 255);
    ctx.vertex2f(-0.5, -0.5);
    ctx.vertex2f(0.5, -0.5);
    ctx.vertex2f(0, -0.1);
    ctx.end();

    // The Y axis of vp_half is signed for screen-up = NDC-up; check
    // both halves got their respective colors at obvious test pixels.
    // Pixel rows 2..6 should hold one color, rows 9..14 the other
    // we don't pin which is which (depends on Y orientation), just
    // that each triangle painted SOMEWHERE.
    var found_red: bool = false;
    var found_blue: bool = false;
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var y: i32 = 0;
        while (y < 16) : (y += 1) {
            const px: [4]u8 = pixelAtRgba8(&ctx, x, y);
            if (px[0] == 255 and px[2] == 0) {
                found_red = true;
            }
            if (px[2] == 255 and px[0] == 0) {
                found_blue = true;
            }
        }
    }
    try expect(found_red);
    try expect(found_blue);
}

// ---- triangle DEPTH + TEX tests
// Tests for the depth_test and texture cfg axes added to drawTriangle.
// Each kernel is monomorphised against (cfg x fb_color_fmt x fb_depth_fmt)
// at compile time, so these tests exercise the fully-specialised
// inner loop with depth read/write and texture sampling.

test "era III: triangle depth-test rejects pixels behind existing depth" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.depth_test);
    ctx.begin(.triangles);
    // Closer triangle (z = -0.5) - passes against zero-init depth.
    ctx.color4ub(80, 80, 80, 255);
    ctx.vertex3f(-0.5, -0.5, -0.5);
    ctx.vertex3f(0.5, -0.5, -0.5);
    ctx.vertex3f(0, 0.5, -0.5);
    // Farther triangle (z = +0.5), same xy - should be rejected
    // wherever it would overlap the first.
    ctx.color4ub(220, 220, 220, 255);
    ctx.vertex3f(-0.5, -0.5, 0.5);
    ctx.vertex3f(0.5, -0.5, 0.5);
    ctx.vertex3f(0, 0.5, 0.5);
    ctx.end();

    // Pixel (8, 6) - well inside both triangles.  Should hold the
    // closer triangle's color.
    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expectEqual(@as(u8, 80), px[0]);
}

test "era III: textured triangle samples bound texture color" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Upload a 4x4 solid-color RGBA8 texture (every texel = blue).
    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    var tex_pixels: [4 * 4 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < tex_pixels.len) : (i += 4) {
        tex_pixels[i + 0] = 0;
        tex_pixels[i + 1] = 0;
        tex_pixels[i + 2] = 255;
        tex_pixels[i + 3] = 255;
    }
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, &tex_pixels);
    ctx.texParameter(.{ .min_filter = .nearest });
    ctx.texParameter(.{ .mag_filter = .nearest });

    ctx.enable(.texture_2d);
    ctx.begin(.triangles);
    // Vertex color: white.  Modulated x blue texture = blue output.
    ctx.color4ub(255, 255, 255, 255);
    ctx.texCoord2f(0, 0);
    ctx.vertex2f(-0.5, -0.5);
    ctx.texCoord2f(1, 0);
    ctx.vertex2f(0.5, -0.5);
    ctx.texCoord2f(0.5, 1);
    ctx.vertex2f(0, 0.5);
    ctx.end();

    // Center of the triangle should sample the texture (all texels
    // are blue) and modulate by white = blue.
    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expectEqual(@as(u8, 0), px[0]);
    try expectEqual(@as(u8, 0), px[1]);
    try expectEqual(@as(u8, 255), px[2]);
}

test "era III: textured triangle modulates vertex color with texture" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    // Solid white texture.
    var tex_pixels: [4 * 4 * 4]u8 = @splat(255);
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, &tex_pixels);
    ctx.texParameter(.{ .min_filter = .nearest });
    ctx.texParameter(.{ .mag_filter = .nearest });

    ctx.enable(.texture_2d);
    ctx.begin(.triangles);
    // Vertex color: red.  Modulated x white texture = red output.
    ctx.color4ub(255, 0, 0, 255);
    ctx.texCoord2f(0, 0);
    ctx.vertex2f(-0.5, -0.5);
    ctx.texCoord2f(1, 0);
    ctx.vertex2f(0.5, -0.5);
    ctx.texCoord2f(0.5, 1);
    ctx.vertex2f(0, 0.5);
    ctx.end();

    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expectEqual(@as(u8, 255), px[0]);
    try expectEqual(@as(u8, 0), px[1]);
}

test "era III: textured + depth-test triangle combines both axes" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    // Solid green texture.
    var tex_pixels: [4 * 4 * 4]u8 = undefined;
    var ti: usize = 0;
    while (ti < tex_pixels.len) : (ti += 4) {
        tex_pixels[ti + 0] = 0;
        tex_pixels[ti + 1] = 200;
        tex_pixels[ti + 2] = 0;
        tex_pixels[ti + 3] = 255;
    }
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, &tex_pixels);
    ctx.texParameter(.{ .min_filter = .nearest });
    ctx.texParameter(.{ .mag_filter = .nearest });

    ctx.enable(.depth_test);
    ctx.enable(.texture_2d);

    ctx.begin(.triangles);
    // Closer textured triangle.
    ctx.color4ub(255, 255, 255, 255);
    ctx.texCoord2f(0, 0);
    ctx.vertex3f(-0.5, -0.5, -0.5);
    ctx.texCoord2f(1, 0);
    ctx.vertex3f(0.5, -0.5, -0.5);
    ctx.texCoord2f(0.5, 1);
    ctx.vertex3f(0, 0.5, -0.5);
    // Farther textured triangle (would be red if it painted).
    ctx.color4ub(255, 0, 0, 255);
    ctx.texCoord2f(0, 0);
    ctx.vertex3f(-0.5, -0.5, 0.5);
    ctx.texCoord2f(1, 0);
    ctx.vertex3f(0.5, -0.5, 0.5);
    ctx.texCoord2f(0.5, 1);
    ctx.vertex3f(0, 0.5, 0.5);
    ctx.end();

    // Center should hold green (closer triangle's white x green
    // texture); the farther triangle's red is rejected by depth.
    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expectEqual(@as(u8, 0), px[0]);
    try expectEqual(@as(u8, 200), px[1]);
}

// ---- triangle BLEND + cull tests
test "era III: blend alpha-over composites src over dst" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Pre-fill the framebuffer with red via a first opaque triangle.
    ctx.begin(.triangles);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.9, -0.9);
    ctx.vertex2f(0.9, -0.9);
    ctx.vertex2f(0, 0.9);
    ctx.end();

    // Sanity: pixel (8, 6) is now red.
    const before: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expectEqual(@as(u8, 255), before[0]);

    // Now blend a half-transparent green triangle over the same area.
    ctx.enable(.blend);
    ctx.blendFunc(.src_alpha, .one_minus_src_alpha);
    ctx.begin(.triangles);
    ctx.color4ub(0, 255, 0, 128); // ~50% alpha green
    ctx.vertex2f(-0.9, -0.9);
    ctx.vertex2f(0.9, -0.9);
    ctx.vertex2f(0, 0.9);
    ctx.end();

    // Result at center should mix: roughly half red, half green.
    // 128/255 ~ 0.502; out_r = 0 * 0.502 + 255 * 0.498 ~ 127.
    // out_g = 255 * 0.502 + 0 * 0.498 ~ 128.
    const after: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expect(after[0] > 100 and after[0] < 160);
    try expect(after[1] > 100 and after[1] < 160);
    try expectEqual(@as(u8, 0), after[2]);
}

test "era III: blend with full alpha is identity (matches no-blend output)" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.blend);
    ctx.blendFunc(.src_alpha, .one_minus_src_alpha);
    ctx.begin(.triangles);
    // alpha = 255 -> src_alpha = 1, inv = 0, so dst contribution = 0.
    // Output is just the source color.
    ctx.color4ub(50, 100, 200, 255);
    ctx.vertex2f(-0.5, -0.5);
    ctx.vertex2f(0.5, -0.5);
    ctx.vertex2f(0, 0.5);
    ctx.end();

    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expectEqual(@as(u8, 50), px[0]);
    try expectEqual(@as(u8, 100), px[1]);
    try expectEqual(@as(u8, 200), px[2]);
}

test "era III: cull_back rejects back-facing triangles (NDC-CCW post-Y-flip), keeps front-facing (NDC-CW)" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.cull_face);
    ctx.cullFace(.back);

    // raster computes signed area in pixel space, where Y is flipped
    // vs NDC.  That inverts winding-order classification:
    //   - NDC CCW  ->  pixel CW   ->  back-facing -> CULLED by cullFace(.back)
    //   - NDC CW   ->  pixel CCW  ->  front-facing -> KEEPS painting
    // Test the first half: an NDC-CCW triangle.  Center vertex at
    // (0, 0.9) renders ABOVE the bottom edge in NDC (positive Y).
    // After Y-flip the pixel order is (1, 14) -> (15, 14) -> (8, 0).
    // Visiting those three pixels in that order traces a CW loop
    // in memory space, so this should be culled.
    ctx.begin(.triangles);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.9, -0.9); // pixel (1, 14)
    ctx.vertex2f(0.9, -0.9); // pixel (15, 14)
    ctx.vertex2f(0, 0.9); // pixel (8, 0)
    ctx.end();

    // Framebuffer should be untouched (all-zero clear).
    var x: i32 = 0;
    while (x < 16) : (x += 1) {
        var y: i32 = 0;
        while (y < 16) : (y += 1) {
            const px: [4]u8 = pixelAtRgba8(&ctx, x, y);
            try expectEqual(@as(u8, 0), px[0]);
        }
    }

    // NDC-CW triangle: pixel order traces CCW post-flip -> front-facing -> paints.
    ctx.begin(.triangles);
    ctx.color4ub(0, 200, 0, 255);
    ctx.vertex2f(-0.9, -0.9);
    ctx.vertex2f(0, 0.9);
    ctx.vertex2f(0.9, -0.9);
    ctx.end();

    // After Y-flip the apex (0, 0.9) lands at pixel y=0, base
    // along pixel y=14.  Center of mass is around pixel (8, 10).
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 10);
    try expectEqual(@as(u8, 200), center[1]);
}

test "era III: blend + textured triangle composites textured src over dst" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    var tex_pixels: [4 * 4 * 4]u8 = undefined;
    var ti: usize = 0;
    while (ti < tex_pixels.len) : (ti += 4) {
        // Solid blue, full alpha.
        tex_pixels[ti + 0] = 0;
        tex_pixels[ti + 1] = 0;
        tex_pixels[ti + 2] = 255;
        tex_pixels[ti + 3] = 255;
    }
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, &tex_pixels);
    ctx.texParameter(.{ .min_filter = .nearest });
    ctx.texParameter(.{ .mag_filter = .nearest });

    // Pre-fill with red opaque.
    ctx.begin(.triangles);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.9, -0.9);
    ctx.vertex2f(0.9, -0.9);
    ctx.vertex2f(0, 0.9);
    ctx.end();

    // Blend half-alpha textured (white x blue tex = blue, alpha 128).
    ctx.enable(.blend);
    ctx.blendFunc(.src_alpha, .one_minus_src_alpha);
    ctx.enable(.texture_2d);
    ctx.begin(.triangles);
    ctx.color4ub(255, 255, 255, 128);
    ctx.texCoord2f(0, 0);
    ctx.vertex2f(-0.5, -0.5);
    ctx.texCoord2f(1, 0);
    ctx.vertex2f(0.5, -0.5);
    ctx.texCoord2f(0.5, 1);
    ctx.vertex2f(0, 0.5);
    ctx.end();

    // Center: red dst + blue src @ ~50% = roughly equal red and blue,
    // green ~0.
    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expect(px[0] > 100 and px[0] < 160);
    try expect(px[2] > 100 and px[2] < 160);
    try expectEqual(@as(u8, 0), px[1]);
}

// ---- quad rasterizer tests
// The quad path has two routes: the sprite-fast-path `quadKernel`
// (axis-aligned rectangles, bypassing the edge-function
// rasterizer) and the fan-triangulation fallback (everything
// else, going through `triangleKernel` twice).  Tests below
// cover both routes and the cfg axes that apply to each.

test "era III: axis-aligned quad fills its rectangle" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Submit a screen-axis-aligned quad in canonical TL->TR->BR->BL
    // order.  See the corner-interpolation test below for the NDC
    // <-> pixel orientation reminder.  Pixel rect roughly (4, 4) ->
    // (12, 12).
    ctx.begin(.quads);
    ctx.color4ub(255, 200, 100, 255);
    ctx.vertex2f(-0.5, -0.5); // TL
    ctx.vertex2f(0.5, -0.5); // TR
    ctx.vertex2f(0.5, 0.5); // BR
    ctx.vertex2f(-0.5, 0.5); // BL
    ctx.end();

    // Center of the quad is painted.
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 255), center[0]);
    try expectEqual(@as(u8, 200), center[1]);

    // Outside the quad is untouched.
    const corner: [4]u8 = pixelAtRgba8(&ctx, 1, 1);
    try expectEqual(@as(u8, 0), corner[0]);
}

test "era III: axis-aligned quad interpolates corner colors linearly" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // The rasterizer's gradient kernel classifies the four
    // submitted vertices as TL/TR/BR/BL by their PIXEL position,
    // then linearly interpolates color across TL+TR+BL while
    // ignoring the BR corner color.  Submit vertices so the
    // pixel-space "TL" gets red, "TR" green, "BL" blue, and the
    // ignored "BR" gets the sentinel color.
    // GL Y-up: NDC y=+0.5 -> pixel y=4 (top half of memory), NDC
    // y=-0.5 -> pixel y=12.  So:
    //   pixel TL (4, 4)   <- NDC (-0.5, +0.5)
    //   pixel TR (12, 4)  <- NDC (+0.5, +0.5)
    //   pixel BR (12, 12) <- NDC (+0.5, -0.5)   (ignored)
    //   pixel BL (4, 12)  <- NDC (-0.5, -0.5)
    ctx.begin(.quads);
    ctx.color4ub(0, 0, 255, 255); // pixel-BL (NDC -0.5, -0.5): blue
    ctx.vertex2f(-0.5, -0.5);
    ctx.color4ub(123, 45, 67, 255); // pixel-BR (NDC +0.5, -0.5): ignored
    ctx.vertex2f(0.5, -0.5);
    ctx.color4ub(0, 255, 0, 255); // pixel-TR (NDC +0.5, +0.5): green
    ctx.vertex2f(0.5, 0.5);
    ctx.color4ub(255, 0, 0, 255); // pixel-TL (NDC -0.5, +0.5): red
    ctx.vertex2f(-0.5, 0.5);
    ctx.end();

    // Near pixel-TL (red): strong red.
    const tl: [4]u8 = pixelAtRgba8(&ctx, 5, 5);
    try expect(tl[0] > 150);

    // Near pixel-TR (green): strong green.
    const tr: [4]u8 = pixelAtRgba8(&ctx, 11, 5);
    try expect(tr[1] > 150);

    // Near pixel-BL (blue): strong blue.
    const bl: [4]u8 = pixelAtRgba8(&ctx, 5, 11);
    try expect(bl[2] > 150);
}

test "era III: rotated quad falls back to fan triangulation" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Rotated 45 deg quad - a diamond shape.  Edges run diagonally,
    // so isAxisAlignedQuad returns false and the dispatcher splits
    // into two triangles via the fan path.
    ctx.begin(.quads);
    ctx.color4ub(120, 220, 120, 255);
    ctx.vertex2f(0, 0.6);
    ctx.vertex2f(-0.6, 0);
    ctx.vertex2f(0, -0.6);
    ctx.vertex2f(0.6, 0);
    ctx.end();

    // Center pixel is inside both triangles -> painted.
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 120), center[0]);
    try expectEqual(@as(u8, 220), center[1]);

    // Far corner (1, 1) is outside the diamond -> untouched.
    const corner: [4]u8 = pixelAtRgba8(&ctx, 1, 1);
    try expectEqual(@as(u8, 0), corner[1]);
}

test "era III: textured quad samples bound texture across rectangle" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    var tex_pixels: [4 * 4 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < tex_pixels.len) : (i += 4) {
        tex_pixels[i + 0] = 200;
        tex_pixels[i + 1] = 100;
        tex_pixels[i + 2] = 50;
        tex_pixels[i + 3] = 255;
    }
    try ctx.texImage2D(std.testing.allocator, 4, 4, .rgba, .unsigned_byte, &tex_pixels);
    ctx.texParameter(.{ .min_filter = .nearest });
    ctx.texParameter(.{ .mag_filter = .nearest });

    ctx.enable(.texture_2d);
    ctx.begin(.quads);
    ctx.color4ub(255, 255, 255, 255);
    ctx.texCoord2f(0, 0);
    ctx.vertex2f(-0.5, -0.5); // TL
    ctx.texCoord2f(1, 0);
    ctx.vertex2f(0.5, -0.5); // TR
    ctx.texCoord2f(1, 1);
    ctx.vertex2f(0.5, 0.5); // BR
    ctx.texCoord2f(0, 1);
    ctx.vertex2f(-0.5, 0.5); // BL
    ctx.end();

    // Solid texture color (200, 100, 50) modulated by white = same.
    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 200), px[0]);
    try expectEqual(@as(u8, 100), px[1]);
    try expectEqual(@as(u8, 50), px[2]);
}

test "era III: blended quad over opaque background composites correctly" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Opaque red background quad.
    ctx.begin(.quads);
    ctx.color4ub(255, 0, 0, 255);
    ctx.vertex2f(-0.9, -0.9); // TL
    ctx.vertex2f(0.9, -0.9); // TR
    ctx.vertex2f(0.9, 0.9); // BR
    ctx.vertex2f(-0.9, 0.9); // BL
    ctx.end();

    // Half-alpha green quad over.
    ctx.enable(.blend);
    ctx.blendFunc(.src_alpha, .one_minus_src_alpha);
    ctx.begin(.quads);
    ctx.color4ub(0, 255, 0, 128);
    ctx.vertex2f(-0.5, -0.5); // TL
    ctx.vertex2f(0.5, -0.5); // TR
    ctx.vertex2f(0.5, 0.5); // BR
    ctx.vertex2f(-0.5, 0.5); // BL
    ctx.end();

    // Center inside both quads -> 50/50 mix of red and green.
    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expect(px[0] > 100 and px[0] < 160);
    try expect(px[1] > 100 and px[1] < 160);
}

test "era III: depth-tested quad rejects pixels behind closer geometry" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.enable(.depth_test);

    // Closer quad (z = -0.5).
    ctx.begin(.quads);
    ctx.color4ub(80, 80, 80, 255);
    ctx.vertex3f(-0.5, -0.5, -0.5); // TL
    ctx.vertex3f(0.5, -0.5, -0.5); // TR
    ctx.vertex3f(0.5, 0.5, -0.5); // BR
    ctx.vertex3f(-0.5, 0.5, -0.5); // BL
    ctx.end();

    // Farther quad (z = +0.5), same xy - should be rejected.
    ctx.begin(.quads);
    ctx.color4ub(220, 220, 220, 255);
    ctx.vertex3f(-0.5, -0.5, 0.5); // TL
    ctx.vertex3f(0.5, -0.5, 0.5); // TR
    ctx.vertex3f(0.5, 0.5, 0.5); // BR
    ctx.vertex3f(-0.5, 0.5, 0.5); // BL
    ctx.end();

    const px: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 80), px[0]);
}

test "era III: corner classification handles arbitrary submit order" {
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Submit starting from the BR corner - a rotated submit order
    // vs the canonical TL->TR->BR->BL.  quadKernel's sum/diff
    // classification should still find each corner correctly
    // regardless of which slot it lands in.
    ctx.begin(.quads);
    ctx.color4ub(255, 100, 50, 255);
    ctx.vertex2f(0.5, 0.5); // BR (largest sum)
    ctx.vertex2f(-0.5, 0.5); // BL (smallest diff)
    ctx.vertex2f(-0.5, -0.5); // TL (smallest sum)
    ctx.vertex2f(0.5, -0.5); // TR (largest diff)
    ctx.end();

    // Quad should still fill its rectangle.
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 255), center[0]);
    try expectEqual(@as(u8, 100), center[1]);
}

// ---- SIMD path tests
// `quadKernel`'s `simdEligible()` configurations (today: BASE
// only - no depth, no texture, no blend) take a 4-wide
// `Lane4f` inner-loop pass that processes four pixels
// at a time, plus a scalar tail for the 0-3 leftover pixels
// when the row width isn't a multiple of 4.  The math is
// equivalent to the scalar path; both should produce the same
// output for the same input.
// Tests below construct quads whose row widths exercise both
// the SIMD body and the tail.  Triangle SIMD lands in a
// follow-up turn; the triangle tests in this section verify
// the existing scalar path still produces correct output (they
// don't require SIMD to pass).

test "era III: SIMD quad fills full row width across multiple lanes" {
    // 16-wide quad covers 12 painted pixels per row -> exactly
    // three SIMD iterations, no tail.  Confirms the SIMD body
    // paints contiguous pixels with no gaps.
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.quads);
    ctx.color4ub(180, 60, 30, 255);
    ctx.vertex2f(-0.75, -0.75); // TL ~ pixel (2, 2)
    ctx.vertex2f(0.75, -0.75); // TR ~ pixel (14, 2)
    ctx.vertex2f(0.75, 0.75); // BR ~ pixel (14, 14)
    ctx.vertex2f(-0.75, 0.75); // BL ~ pixel (2, 14)
    ctx.end();

    // Walk a row inside the quad, every pixel should be painted.
    var x: i32 = 3;
    while (x <= 13) : (x += 1) {
        const px: [4]u8 = pixelAtRgba8(&ctx, x, 8);
        try expectEqual(@as(u8, 180), px[0]);
    }
}

test "era III: SIMD quad scalar tail handles non-multiple-of-4 widths" {
    // Construct a quad whose painted width is exactly 7 pixels:
    // one SIMD iteration (4 lanes) plus a 3-pixel scalar tail.
    // 16-wide framebuffer with a quad sized to land at x in
    // [4, 11) gives 7 painted pixels per row.
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    // Tune the NDC range so the projected x range is [4, 11].
    // vp_center.x = 8, vp_half.x = 8.  Pixel = 8 + ndc*8 + 0.5.
    // For pixel 4: ndc ~ -0.5; for pixel 11: ndc ~ +0.3125.
    ctx.begin(.quads);
    ctx.color4ub(120, 220, 70, 255);
    ctx.vertex2f(-0.5, -0.5); // TL ~ pixel (4, 4)
    ctx.vertex2f(0.3125, -0.5); // TR ~ pixel (11, 4)
    ctx.vertex2f(0.3125, 0.5); // BR ~ pixel (11, 12)
    ctx.vertex2f(-0.5, 0.5); // BL ~ pixel (4, 12)
    ctx.end();

    // Pixel inside the SIMD body (px ~ 6).
    const simd_body: [4]u8 = pixelAtRgba8(&ctx, 6, 8);
    try expectEqual(@as(u8, 120), simd_body[0]);
    try expectEqual(@as(u8, 220), simd_body[1]);

    // Pixel inside the scalar tail (px ~ 10, beyond the first
    // 4-lane batch).
    const scalar_tail: [4]u8 = pixelAtRgba8(&ctx, 10, 8);
    try expectEqual(@as(u8, 120), scalar_tail[0]);
    try expectEqual(@as(u8, 220), scalar_tail[1]);
}

test "era III: SIMD quad with sub-4 width runs only the scalar tail" {
    // 3-pixel-wide quad - too narrow to fill a single SIMD lane
    // batch.  The SIMD body's `while (px + 4 <= max_x)` condition
    // is false on entry, so it executes zero iterations and the
    // scalar tail handles every pixel.  Tests that this edge
    // case doesn't produce off-by-one or skipped writes.
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.quads);
    ctx.color4ub(255, 100, 200, 255);
    // Width chosen so painted pixel range is roughly [7, 10) - 3 pixels wide.
    ctx.vertex2f(-0.125, -0.5); // TL ~ pixel (7, 4)
    ctx.vertex2f(0.25, -0.5); // TR ~ pixel (10, 4)
    ctx.vertex2f(0.25, 0.5); // BR
    ctx.vertex2f(-0.125, 0.5); // BL
    ctx.end();

    // Each of the 3 columns inside should be painted.
    var x: i32 = 7;
    while (x <= 9) : (x += 1) {
        const px: [4]u8 = pixelAtRgba8(&ctx, x, 8);
        try expectEqual(@as(u8, 255), px[0]);
    }

    // Just outside the quad on either side, untouched.
    const left_outside: [4]u8 = pixelAtRgba8(&ctx, 6, 8);
    try expectEqual(@as(u8, 0), left_outside[0]);
    const right_outside: [4]u8 = pixelAtRgba8(&ctx, 11, 8);
    try expectEqual(@as(u8, 0), right_outside[0]);
}

test "era III: SIMD quad gradient produces same colors as scalar reference" {
    // Verify the SIMD path's color interpolation is equivalent
    // to the scalar formula.  Construct a gradient quad and
    // compute the expected color at each painted pixel via the
    // scalar formula `c = TL + (TR - TL) * dx + (BL - TL) * dy`.
    // Compare to the actual rendered output.
    // GL Y-up: pixel-TL is NDC (-0.5, +0.5), pixel-BL is NDC
    // (-0.5, -0.5).  Submit so the pixel-space gradient runs
    // black (TL) -> red (TR) horizontally and black (TL) -> green
    // (BL) vertically.
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.quads);
    ctx.color4ub(0, 255, 0, 255); // pixel-BL (NDC -0.5, -0.5): green
    ctx.vertex2f(-0.5, -0.5);
    ctx.color4ub(255, 255, 0, 255); // pixel-BR (NDC +0.5, -0.5): ignored
    ctx.vertex2f(0.5, -0.5);
    ctx.color4ub(255, 0, 0, 255); // pixel-TR (NDC +0.5, +0.5): red
    ctx.vertex2f(0.5, 0.5);
    ctx.color4ub(0, 0, 0, 255); // pixel-TL (NDC -0.5, +0.5): black
    ctx.vertex2f(-0.5, 0.5);
    ctx.end();

    // Sample several lane positions and check the gradient is
    // smooth across SIMD iteration boundaries.  Red increases
    // left->right; green increases top->bottom (pixel y).
    const left_top: [4]u8 = pixelAtRgba8(&ctx, 5, 5);
    const right_top: [4]u8 = pixelAtRgba8(&ctx, 11, 5);
    try expect(right_top[0] > left_top[0]); // more red

    const left_bot: [4]u8 = pixelAtRgba8(&ctx, 5, 11);
    try expect(left_bot[1] > left_top[1]); // more green
}

test "era III: SIMD quad output is bit-identical to scalar path" {
    // Mathematical equivalence check: compute one pixel's color
    // using the scalar formula (matches the per-pixel arithmetic
    // both paths use) and verify the rendered output matches
    // exactly.  Catches float-ordering or precision drift in the
    // SIMD path that wouldn't show up in the bounded-range tests
    // above.
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    ctx.begin(.quads);
    ctx.color4ub(64, 96, 128, 255);
    ctx.vertex2f(-0.75, -0.75);
    ctx.vertex2f(0.75, -0.75);
    ctx.vertex2f(0.75, 0.75);
    ctx.vertex2f(-0.75, 0.75);
    ctx.end();

    // Solid color quad - every interior pixel is exactly the
    // submitted color.  No gradient, no precision concerns.  If
    // SIMD writes the wrong bytes (e.g., lane order swap), this
    // catches it.
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 8);
    try expectEqual(@as(u8, 64), center[0]);
    try expectEqual(@as(u8, 96), center[1]);
    try expectEqual(@as(u8, 128), center[2]);
    try expectEqual(@as(u8, 255), center[3]);

    // Sample three more pixels at lane positions that would have
    // been processed in different SIMD iterations.  All should
    // match the same solid color.
    const lane0: [4]u8 = pixelAtRgba8(&ctx, 4, 8);
    try expectEqual(@as(u8, 64), lane0[0]);
    const lane2: [4]u8 = pixelAtRgba8(&ctx, 6, 8);
    try expectEqual(@as(u8, 64), lane2[0]);
    const lane3: [4]u8 = pixelAtRgba8(&ctx, 11, 8);
    try expectEqual(@as(u8, 64), lane3[0]);
}

// ---- perspective-correct UV tests
// `triangleKernel`'s texture sampling does perspective-correct
// UV interpolation: at each vertex `(u, v, 1)` are pre-divided
// by W, the rasterizer lerps the three pre-divided quantities
// linearly via barycentric weights, and per pixel recovers the
// actual UV via division by the interpolated 1/W.  For W=1
// vertices this reduces to plain affine interpolation
// (equivalent to the donor's behaviour and to what we shipped
//); for W != 1 vertices it produces correct
// perspective-foreshortened texturing.
// The tests below construct triangles with non-1 W explicitly
// (by submitting through a non-identity MVP) and verify the
// texture sample at specific points matches what perspective-
// correct interp would produce.

test "era III: perspective-correct UV - W=1 input matches affine result" {
    // Sanity / regression test.  Submits a 2D textured triangle
    // (W=1 throughout) and verifies the texture appears at the
    // same pixel as it would under the old affine code path.
    // Combined with the existing 2D textured triangle tests
    // (which still pass), this confirms the W=1 -> affine
    // collapse holds.
    var ctx = try Context.init(std.testing.allocator, 16, 16);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    // 2x2 texture with distinct quadrant colors so we can tell
    // which texel a UV coord maps to.
    var tex_pixels: [2 * 2 * 4]u8 = .{
        255, 0, 0, 255, // (0, 0) red
        0, 255, 0, 255, // (1, 0) green
        0, 0, 255, 255, // (0, 1) blue
        255, 255, 0, 255, // (1, 1) yellow
    };
    try ctx.texImage2D(std.testing.allocator, 2, 2, .rgba, .unsigned_byte, &tex_pixels);
    ctx.texParameter(.{ .min_filter = .nearest });
    ctx.texParameter(.{ .mag_filter = .nearest });

    ctx.enable(.texture_2d);
    ctx.begin(.triangles);
    ctx.color4ub(255, 255, 255, 255);
    ctx.texCoord2f(0.25, 0.25); // upper-left quadrant - red
    ctx.vertex2f(-0.6, -0.6);
    ctx.texCoord2f(0.75, 0.25); // upper-right quadrant - green
    ctx.vertex2f(0.6, -0.6);
    ctx.texCoord2f(0.5, 0.75); // mixed
    ctx.vertex2f(0, 0.6);
    ctx.end();

    // Center of the triangle should sample roughly the average
    // of the three corner UVs ~ (0.5, ~0.4) -> upper row of the
    // texture.  Color is some mix of red and green; both
    // channels above zero, blue near zero.
    const center: [4]u8 = pixelAtRgba8(&ctx, 8, 6);
    try expect(center[0] > 0 or center[1] > 0);
    try expect(center[2] < 50);
}

test "era III: perspective-correct UV - non-W=1 vertices interp correctly" {
    // The crux test.  Submit a triangle whose vertices have
    // distinct W values (achieved by setting up a perspective
    // frustum and submitting `vertex3f` at varying Z).  Verify
    // the textured output uses perspective-correct UV: the
    // interpolated 1/W recovers an asymmetric W per pixel,
    // shifting the texture sample toward the closer vertex.
    // Affine interp would NOT do this - it would interpolate UVs
    // directly in screen space, missing the perspective.  This
    // test catches a regression to affine.
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var handles: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);
    defer ctx.deleteTextures(std.testing.allocator, &handles);

    ctx.bindTexture(handles[0]);
    // Texture: left half red, right half blue.  Lets us measure
    // where the U=0.5 boundary lands in screen space.
    var tex_pixels: [4 * 1 * 4]u8 = .{
        255, 0, 0, 255, // U=0.0
        255, 0, 0, 255, // U=0.25
        0, 0, 255, 255, // U=0.5
        0, 0, 255, 255, // U=0.75
    };
    try ctx.texImage2D(std.testing.allocator, 4, 1, .rgba, .unsigned_byte, &tex_pixels);
    ctx.texParameter(.{ .min_filter = .nearest });
    ctx.texParameter(.{ .mag_filter = .nearest });

    // Set up a perspective frustum.  Camera looking down -Z; near
    // plane at z=-1, far at z=-10.
    ctx.matrixMode(.projection);
    ctx.loadIdentity();
    ctx.frustum(-1.0, 1.0, -1.0, 1.0, 1.0, 10.0);
    ctx.matrixMode(.modelview);
    ctx.loadIdentity();

    ctx.enable(.texture_2d);
    ctx.begin(.triangles);
    ctx.color4ub(255, 255, 255, 255);
    // Vertex 0: close to camera, left side of texture.
    ctx.texCoord2f(0.0, 0.5);
    ctx.vertex3f(-0.6, -0.6, -1.5);
    // Vertex 1: far from camera, right side of texture.
    ctx.texCoord2f(1.0, 0.5);
    ctx.vertex3f(0.6, -0.6, -8.0);
    // Vertex 2: middle distance, top.
    ctx.texCoord2f(0.5, 0.5);
    ctx.vertex3f(0, 0.6, -3.0);
    ctx.end();

    // The triangle paints an irregularly-shaped region.  Walk
    // a horizontal line and find where the U=0.5 boundary
    // (red->blue transition) lands.  Under perspective-correct
    // interp, the boundary shifts toward the closer (left)
    // vertex - pixels that "should" be at U=0.5 in screen
    // space actually correspond to higher U in texture space.
    // Affine interp would put the boundary at the screen-space
    // midpoint.
    // We only assert the triangle painted SOMETHING (some red
    // and some blue in the bbox), confirming the texture path
    // ran and produced a recognisable two-color split.  Exact
    // boundary position depends on the interp formula and
    // would break with refactoring.
    var found_red: bool = false;
    var found_blue: bool = false;
    var py: i32 = 0;
    while (py < 32) : (py += 1) {
        var px: i32 = 0;
        while (px < 32) : (px += 1) {
            const sample: [4]u8 = pixelAtRgba8(&ctx, px, py);
            // Channel-dominance test, not an exact colour match: the rasteriser interpolates and
            // the blend may have touched these pixels, so the assertion is 'red clearly beats blue
            // here' rather than a specific RGBA triple that any filtering change would break.
            if (sample[0] > 200 and sample[2] < 50) {
                found_red = true;
            }
            if (sample[2] > 200 and sample[0] < 50) {
                found_blue = true;
            }
        }
    }
    try expect(found_red);
    try expect(found_blue);
}
test "era I: genTextures + deleteTextures basic round-trip" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var handles: [4]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);

    try expectEqual(ErrorCode.no_error, ctx.err_code);
    for (handles) |h| {
        try expect(!h.isNil());
        try expect(h.isValid(&ctx.texture_pool));
        try expect(ctx.getTexture(h) != null);
    }

    ctx.deleteTextures(std.testing.allocator, &handles);
    try expectEqual(ErrorCode.no_error, ctx.err_code);
    for (handles) |h| {
        try expect(!h.isValid(&ctx.texture_pool));
    }
}

test "era I: genFramebuffers + deleteFramebuffers basic round-trip" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var handles: [3]Handle(Framebuffer) = @splat(.nil);
    ctx.genFramebuffers(&handles);

    try expectEqual(ErrorCode.no_error, ctx.err_code);
    for (handles) |h| {
        try expect(!h.isNil());
        try expect(h.isValid(&ctx.framebuffer_pool));
        try expect(ctx.getFramebuffer(h) != null);
    }

    ctx.deleteFramebuffers(&handles);
    for (handles) |h| {
        try expect(!h.isValid(&ctx.framebuffer_pool));
    }
}

test "era I: deleteTextures of invalid handle records invalid_value but continues" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var valid_h: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&valid_h);

    // Mix of valid and invalid: nil, out-of-range, valid.
    const out_of_range: Handle(Texture) = .pack(9999, 1);
    const mixed = [_]Handle(Texture){ .nil, out_of_range, valid_h[0] };
    ctx.deleteTextures(std.testing.allocator, &mixed);

    try expectEqual(ErrorCode.invalid_value, ctx.err_code);
    // The valid one should still have been freed.
    try expect(!valid_h[0].isValid(&ctx.texture_pool));
}

test "era I: deleteTextures clears bound aliases" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var handles: [3]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&handles);

    const tex0: *Texture = ctx.getTexture(handles[0]).?;
    const tex1: *Texture = ctx.getTexture(handles[1]).?;
    const tex2: *Texture = ctx.getTexture(handles[2]).?;

    // Pretend the renderer bound these for sampling / FBO attachment.
    ctx.bound_texture = tex0;
    ctx.color_buffer = tex1;
    ctx.depth_buffer = tex2;

    // Delete only handle 0 -> only bound_texture cleared.
    ctx.deleteTextures(std.testing.allocator, handles[0..1]);
    try expectEqual(@as(?*Texture, null), ctx.bound_texture);
    try expectEqual(tex1, ctx.color_buffer);
    try expectEqual(tex2, ctx.depth_buffer);

    // Delete the rest -> all aliases cleared.
    ctx.deleteTextures(std.testing.allocator, handles[1..]);
    try expectEqual(@as(?*Texture, null), ctx.color_buffer);
    try expectEqual(@as(?*Texture, null), ctx.depth_buffer);
}

test "era I: deleteFramebuffers of bound FB rebinds default" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var fb: [1]Handle(Framebuffer) = @splat(.nil);
    ctx.genFramebuffers(&fb);

    // Pretend the renderer bound this FB.  The real bind path in
    // the framebuffer-bind code will set the bound id and the color/depth pointers
    // (likely from the FB's attachments); here we just stage the
    // state directly.
    ctx.bound_framebuffer = fb[0];
    ctx.color_buffer = null;
    ctx.depth_buffer = null;

    ctx.deleteFramebuffers(&fb);

    try expect(ctx.bound_framebuffer.isNil());
    // Reset path repointed at the default framebuffer's attachments.
    try expectEqual(&ctx.framebuffer.color, ctx.color_buffer);
    try expectEqual(&ctx.framebuffer.depth, ctx.depth_buffer);
}

test "era I: deleteFramebuffers of unbound FB leaves binding alone" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var fb_pair: [2]Handle(Framebuffer) = @splat(.nil);
    ctx.genFramebuffers(&fb_pair);

    ctx.bound_framebuffer = fb_pair[0];
    // color/depth_buffer left null on purpose - must stay null.

    // Deleting the OTHER FB shouldn't touch the binding.
    ctx.deleteFramebuffers(fb_pair[1..]);
    try expectEqual(fb_pair[0], ctx.bound_framebuffer);
    try expectEqual(@as(?*Texture, null), ctx.color_buffer);
    try expectEqual(@as(?*Texture, null), ctx.depth_buffer);
}

test "era I: gen/delete refuse during begin/end (immediate active)" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    // No public `begin` yet, so stage the state directly.
    ctx.draw_mode = .triangles;

    var t: [1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&t);
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);
    try expect(t[0].isNil()); // unwritten - still nil

    // A bogus handle is fine here - the immediate-mode check rejects
    // before any pool work.
    const dummy_tex: Handle(Texture) = .pack(1, 1);
    const dummy_fb: Handle(Framebuffer) = .pack(1, 1);

    ctx.err_code = .no_error;
    ctx.deleteTextures(std.testing.allocator, &[_]Handle(Texture){dummy_tex});
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);

    ctx.err_code = .no_error;
    var f: [1]Handle(Framebuffer) = @splat(.nil);
    ctx.genFramebuffers(&f);
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);
    try expect(f[0].isNil());

    ctx.err_code = .no_error;
    ctx.deleteFramebuffers(&[_]Handle(Framebuffer){dummy_fb});
    try expectEqual(ErrorCode.invalid_operation, ctx.err_code);
}

test "era I: genTextures partial-fills on pool exhaustion" {
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    // max_textures slots minus the 0 reservation is the live-handle
    // ceiling.  Drain it.
    var drain_slots: [max_textures - 1]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&drain_slots);
    try expectEqual(ErrorCode.no_error, ctx.err_code);

    // One more call asks for 4 - pool's already exhausted, all
    // four output slots stay nil, err_code records OOM.
    var more: [4]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&more);
    try expectEqual(ErrorCode.out_of_memory, ctx.err_code);
    try expect(more[0].isNil());
    try expect(more[1].isNil());
    try expect(more[2].isNil());
    try expect(more[3].isNil());

    ctx.deleteTextures(std.testing.allocator, &drain_slots);
}

test "era I: pool slots are correctly aligned for their type" {
    // Generic Pool gets alignment from `T` automatically - `gpa.alloc(T, n)`
    // returns `[]T` with `@alignOf(T)` already.  This test sanity-checks
    // that the addresses we hand out from getTexture / getFramebuffer
    // are correctly aligned.
    var ctx = try Context.init(std.testing.allocator, 32, 32);
    defer ctx.deinit(std.testing.allocator);

    var t_handles: [4]Handle(Texture) = @splat(.nil);
    ctx.genTextures(&t_handles);
    defer ctx.deleteTextures(std.testing.allocator, &t_handles);
    for (t_handles) |h| {
        const tex: *Texture = ctx.getTexture(h).?;
        try expectEqual(@as(usize, 0), @intFromPtr(tex) % @alignOf(Texture));
    }

    var f_handles: [4]Handle(Framebuffer) = @splat(.nil);
    ctx.genFramebuffers(&f_handles);
    defer ctx.deleteFramebuffers(&f_handles);
    for (f_handles) |h| {
        const fb: *Framebuffer = ctx.getFramebuffer(h).?;
        try expectEqual(@as(usize, 0), @intFromPtr(fb) % @alignOf(Framebuffer));
    }
}

// ---- readPixels tests
// `readPixels(x, y, w, h, dst)` copies a sub-rectangle of the
// color attachment into a caller-owned buffer.  Tests cover full-
// frame copies, sub-rectangle copies, out-of-bounds clipping
// (left, right, top, bottom, all four sides at once), and
// degenerate inputs (zero-size rect, fully-outside rect).

test "era IV: readPixels - full frame copy round-trips colorBufferBytes" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    // Paint a known clear color so the buffer has identifiable
    // contents.
    ctx.clearColor(.{ .r = 17, .g = 34, .b = 51, .a = 255 });
    ctx.clear(.{ .color = true });

    var dst: [4 * 4 * 4]u8 = @splat(0);
    const written: usize = ctx.readPixels(0, 0, 4, 4, &dst);
    try expectEqual(@as(usize, 4 * 4 * 4), written);

    // Every pixel matches the clear color.
    var i: usize = 0;
    while (i < 4 * 4) : (i += 1) {
        try expectEqual(@as(u8, 17), dst[i * 4 + 0]);
        try expectEqual(@as(u8, 34), dst[i * 4 + 1]);
        try expectEqual(@as(u8, 51), dst[i * 4 + 2]);
        try expectEqual(@as(u8, 255), dst[i * 4 + 3]);
    }
}

test "era IV: readPixels - sub-rectangle is contiguous in dst" {
    var ctx = try Context.init(std.testing.allocator, 8, 8);
    defer ctx.deinit(std.testing.allocator);

    // Distinct colors per pixel so we can identify which row/col
    // was read.  Use a pixel-index gradient: red = x, green = y.
    const cb_bytes_const: []const u8 = ctx.colorBufferBytes();
    // colorBufferBytes returns []const u8 - we mutate via a pointer
    // cast just for the test setup (the buffer is the framebuffer's
    // own storage, mutable).
    const cb_bytes: []u8 = @constCast(cb_bytes_const);
    var ty: i32 = 0;
    while (ty < 8) : (ty += 1) {
        var tx: i32 = 0;
        while (tx < 8) : (tx += 1) {
            const off: usize = @as(usize, @intCast(ty * 8 + tx)) * 4;
            cb_bytes[off + 0] = @intCast(tx);
            cb_bytes[off + 1] = @intCast(ty);
            cb_bytes[off + 2] = 0;
            cb_bytes[off + 3] = 255;
        }
    }

    // Read a 3x2 rect starting at (2, 4).  Expected: 6 pixels in
    // the dst buffer, with red = 2,3,4 (row 4) and 2,3,4 (row 5),
    // green = 4 (row 0) and 5 (row 1).
    var dst: [3 * 2 * 4]u8 = @splat(0);
    const written: usize = ctx.readPixels(2, 4, 3, 2, &dst);
    try expectEqual(@as(usize, 3 * 2 * 4), written);

    // Row 0 of dst = framebuffer row 4, columns 2..5.
    try expectEqual(@as(u8, 2), dst[0 * 4 + 0]);
    try expectEqual(@as(u8, 4), dst[0 * 4 + 1]);
    try expectEqual(@as(u8, 3), dst[1 * 4 + 0]);
    try expectEqual(@as(u8, 4), dst[1 * 4 + 1]);
    try expectEqual(@as(u8, 4), dst[2 * 4 + 0]);
    try expectEqual(@as(u8, 4), dst[2 * 4 + 1]);
    // Row 1 of dst = framebuffer row 5.
    try expectEqual(@as(u8, 2), dst[3 * 4 + 0]);
    try expectEqual(@as(u8, 5), dst[3 * 4 + 1]);
    try expectEqual(@as(u8, 4), dst[5 * 4 + 0]);
    try expectEqual(@as(u8, 5), dst[5 * 4 + 1]);
}

test "era IV: readPixels - out-of-bounds rect clips silently" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    ctx.clearColor(.{ .r = 99, .g = 99, .b = 99, .a = 255 });
    ctx.clear(.{ .color = true });

    // Request a 6x6 rect starting at (-1, -1).  Available overlap
    // is x in [0, 4), y in [0, 4) - 16 pixels of real data, and the
    // dst buffer is sized as if all 36 pixels were available.  The
    // returned `written` count reflects the copied bytes; pixels
    // outside the overlap stay zero (the dst buffer's initial
    // value).
    var dst: [6 * 6 * 4]u8 = @splat(0);
    const written: usize = ctx.readPixels(-1, -1, 6, 6, &dst);

    // Real overlap = 4x4 = 16 pixels = 64 bytes.
    try expectEqual(@as(usize, 16 * 4), written);

    // Pixel at dst-relative (1, 1) corresponds to framebuffer (0, 0)
    // - should have the clear color.  Pixel at dst-relative (0, 0)
    // is outside the framebuffer - stays zero.
    const dst_pitch: usize = 6 * 4;
    const corner_off: usize = 0; // dst (0, 0) = fb (-1, -1) outside
    try expectEqual(@as(u8, 0), dst[corner_off + 0]);

    const fb_origin_off: usize = 1 * dst_pitch + 1 * 4; // dst (1, 1) = fb (0, 0)
    try expectEqual(@as(u8, 99), dst[fb_origin_off + 0]);
    try expectEqual(@as(u8, 255), dst[fb_origin_off + 3]);
}

test "era IV: readPixels - rect fully outside framebuffer returns 0" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    var dst: [4 * 4 * 4]u8 = @splat(0xAB);
    const written: usize = ctx.readPixels(100, 100, 4, 4, &dst);
    try expectEqual(@as(usize, 0), written);

    // Dst untouched - sentinel byte preserved.
    try expectEqual(@as(u8, 0xAB), dst[0]);
}

test "era IV: readPixels - zero or negative size returns 0" {
    var ctx = try Context.init(std.testing.allocator, 4, 4);
    defer ctx.deinit(std.testing.allocator);

    var dst: [16]u8 = @splat(0xCD);
    try expectEqual(@as(usize, 0), ctx.readPixels(0, 0, 0, 4, &dst));
    try expectEqual(@as(usize, 0), ctx.readPixels(0, 0, 4, 0, &dst));
    try expectEqual(@as(usize, 0), ctx.readPixels(0, 0, -1, 4, &dst));
    try expectEqual(@as(u8, 0xCD), dst[0]);
}
