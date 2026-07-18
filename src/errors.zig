// src/errors.zig
// Composed error sets for the public loader API.  Sits at L3.5 in the
// layered DAG: above `codecs` and `web` (whose error sets it composes),
// below `sound` / `drawing` (which use it as their fn return type).
// Phase 1 of the DAG-plan extracted this from `types.zig` to break
// the `types → codecs` and `types → web` back-edges that put types
// in the SCC.  Lives in its own file (rather than inside `codecs` or
// `web`) because it composes BOTH sets - neither leaf alone is the
// right home.

const std = @import("std");
const Allocator = std.mem.Allocator;

const png_mod = @import("codecs.zig").png;
const fetch_mod = @import("web.zig").fetch;

/// Errors any zimr loader (texture, image, audio/font/model) might
/// surface.  Forms the `error{...}` set you'd `try` against in app
/// code: `const tex = z.loadTextureFromMemory(bytes) catch |e| ...`.
pub const LoadError =
    png_mod.Error ||
    fetch_mod.Error ||
    error{
        /// GPU couldn't allocate the texture (driver OOM / bad format
        /// / dimensions outside what GL_MAX_TEXTURE_SIZE allows).
        GpuUploadFailed,
        /// CPU allocator couldn't satisfy the request.  Some loaders
        /// already surface this via `png_mod.Error.OutOfMemory`; this
        /// is the form for paths that allocate outside png/fetch.
        OutOfMemory,
        /// GPU readback failed - typically the texture isn't 2D, the
        /// FBO came back incomplete, or we're on a host build where
        /// no GL context exists.  Surfaced by `loadImageFromTexture`
        /// and `loadImageFromScreen`.
        GpuReadbackFailed,
        /// glTF parse / extract failed.  Surfaced by `loadModelFromMemory`
        /// and the model-load fns that consume glTF (.gltf / .glb).
        /// The `codecs.gltf.Error` inner detail isn't propagated through
        /// LoadError; check the log for the specific cause.
        GltfParseFailed,
        /// PNG bytes couldn't be decoded - bad signature, malformed
        /// chunk, unsupported color format, truncated stream, etc.
        /// The specific cause is surfaced via `traceLog`.
        DecodeFailed,
        /// Caller-supplied dimensions are non-positive, mismatched
        /// across faces of a cubemap, or otherwise outside the
        /// function's valid input range.  Distinguishes "you passed
        /// bad arguments" from "the GPU/decoder rejected the upload".
        InvalidDimensions,
    };

// Re-export per-module sets for callers that want narrower handling.
pub const PngError = png_mod.Error;
pub const FetchError = fetch_mod.Error;

/// Errors the CPU-side image generators (`genImageColor`,
/// `genImageGradientLinear`, `genImagePerlinNoise`, …) can surface.
/// Strictly narrower than `LoadError` - these never touch the GPU,
/// never decode anything, never fetch anything, so the only failure
/// modes are allocator OOM and caller-supplied bad dimensions.
/// Declared as a subset of `LoadError` so a caller doing a `try`
/// chain that mixes generators and loaders only has to handle one
/// combined error set, and the compiler can prove the inclusion.
/// The bad-dimensions case used to be encoded as a silent
/// `std.mem.zeroes(Image)` return, which collided with a successfully
/// allocated 0×0 image and forced every caller to invent its own
/// post-hoc validity check.  Promoting it to a real error means the
/// existing `try` at every call site catches it, and a caller who
/// genuinely wants to ignore bad input writes `catch return` once.
pub const ImageGenError = Allocator.Error || error{
    /// `width <= 0`, `height <= 0`, or some other dimension-shaped
    /// argument (rect width/height, mipmap count) was non-positive
    /// or otherwise outside the function's valid range.
    InvalidDimensions,
};
