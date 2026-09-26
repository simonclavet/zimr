//! lint:alias types
// src/types.zig - public types ported from raylib 6.0's `raylib.h`.
// Adapted from raylib by Ramon Santamaria (@raysan5), zlib license.
// See THIRD_PARTY_LICENSES.md for full attribution.
// Source-of-truth: raylib_src/raylib.h.  Field names, field types, and
// field order MUST match the C version exactly - these are `extern
// struct` so the layout is fixed.  Anything that calls into a Zig
// function with a raylib C ABI ends up passing these structs by value;
// any mismatch silently corrupts arguments at the boundary.
// Why a separate file (vs in zimr.zig): pure-CPU modules (zimrmath,
// gestures, color math, image-CPU) need the type surface but not the
// browser glue.  Keeping types here means those modules host-test
// cleanly without dragging in `extern "dom"` declarations.
// Convention:
//   - One `extern struct` per raylib typedef.
//   - Field names in the C source and field names here are identical
//     (camelCase, since raylib uses camelCase for struct fields).
//   - Per-type init/zero helpers and named-color decls live with the
//     struct; methods that hit the GPU live elsewhere (Color.fade
//     calls into the C ABI port, not into the type).
// Coverage: every typedef from raylib.h's "Structures Definition"
// block (lines 200-553).  Enums + raylib-style constants (KEY_*,
// MOUSE_*, FLAG_*, ...) live in src/enums.zig.

// ===========================================================================
// Math primitives
// ===========================================================================

const std = @import("std");
const expect = std.testing.expect;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectEqual = std.testing.expectEqual;

// zmath-adoption: `Matrix` is `zm.Mat` (see the `Matrix` alias
// below).  math.zig imports only std + builtin, so this is a clean
// leaf import with no cycle.
const zm = @import("zm");
const Mat = zm.Mat;
const clamp = zm.clamp;
const cross = zm.cross;
const dot3 = zm.dot3;
const dot4 = zm.dot4;
const f32x4 = zm.f32x4;
const identity = zm.identity;
const length3 = zm.length3;
const lengthSq3 = zm.lengthSq3;
const lerp = zm.lerp;
const mulMatVec = zm.mulMatVec;
const normalize3 = zm.normalize3;
const pi = zm.pi;
const project3 = zm.project3;
const reflect3 = zm.reflect3;
const rotate2 = zm.rotate2;
const splat = zm.splat;
const splat2i = zm.splat2i;
const tau = zm.tau;
const translation = zm.translation;
const vec = zm.vec;
const vec_zero = zm.vec_zero;

// vector types does this; types.zig is no exception.
const Vec = zm.Vec;
const Vec2 = zm.Vec2;

// 2D / 3D / 4D vector aliases live in math.zig (`zm.Vec`,
// `zm.Vec2`) - files should `const Vec2 = zm.Vec2;` and
// `const Vec = zm.Vec;` at top instead of going through this
// module.  Turn 351 directive: don't re-export them here.
//
// Integer 2D vector - companion type to `Vec2` for pixel
// coordinates, viewport dimensions, and any value that's
// conceptually a count rather than a measurement.  Not part of
// raylib's API (raylib uses float vectors throughout); we add it
// because rendering code needs both kinds and the float kind
// loses the "this is an exact pixel count" intent at every read.
//
// Canonical home: `src/zimrmath.zig` (sibling of `Vec`, `Vec2`, `Vec3`).
// Re-exported here so callers that already `@import("types.zig")`
// for `Color`, `Rectangle`, etc. find `Vec2i` in the same place.
// The migration history (Phase -1 of `math_unification.md`) is
// documented at the math.zig declaration.
const Vec2i = zm.Vec2i;

/// Convert an integer pixel-coord vector to its float Vec2.  Useful
/// when feeding integer pixel coords into float math (viewport
/// center, NDC mapping).  Free function (not method) because
/// `@Vector(2, i32)` is a primitive - no method-syntax dispatch
/// - so the call site reads `vec2iToFloat(v)` rather than the
/// pre-migration `.toFloat()`.  Inline so it's free at the call
/// site.
pub inline fn vec2iToFloat(v: Vec2i) Vec2 {
    return .{ @floatFromInt(v[0]), @floatFromInt(v[1]) };
}

/// 4x4 column-major.  `m12` is column 4 row 1 (translation X).  This
/// is raylib's chosen layout - note the field declaration order zigzags
/// down each column so the in-memory order is the same as if you wrote
/// `float m[16]` with column-major addressing.
/// `Matrix` is `zm.Mat` - `[4]@Vector(4, f32)`, row-major.
/// zmath-adoption Z3 step 0: `Matrix` used to be a
/// distinct `extern struct` with 16 named `m0..m15` fields.  It was
/// collapsed into `zm.Mat` because it is the one storage type
/// that passes all three collapse clauses (see decision 2 in
/// `zmath-adoption-plan.md`): layout-compatible with `[4]@Vector]`,
/// no semantically-named fields (`.m5` was a bare index for
/// `m[1][1]`), and it never crosses a hard ABI boundary as a struct
/// - every matrix->GPU path already flattens it to `[16]f32` via
/// `matToArr` / `matrixToFloatV`.
/// Element access is now `m[row][col]` (the old `.mN` mapped as
/// `m[N / 4][N % 4]`).  Builders that used to be `Matrix.identity()`
/// / `.translation()` / `.scaling()` are now `zm.identity()` /
/// `zm.translation()` / `zm.scaling()` - same matrices.
const Matrix = Mat;

// ===========================================================================
// Color + Rectangle
// ===========================================================================

const Color = zm.Color;

/// The high-level color currency - defined in zimrmath (the one home for
/// color + its conversions). sRGB bytes; see `zm.Color`.
/// raylib's degree-hue HSV helper (canonical home - S4 dedup; image.zig
/// and wgpu_app.zig re-export this).
pub fn colorFromHSV(hue: f32, saturation: f32, value: f32) Color {
    return Color.fromHSV(.{ hue / 360.0, saturation, value, 1.0 });
}

/// Axis-aligned bounding rectangle in screen / world coordinates.
/// `(x, y)` is the top-left corner; `(width, height)` extends right
/// and down (raylib's convention - y grows downward).
/// Z4 wave 5: flipped from `extern struct` to plain
/// `struct` per Rule 13 - the rest of the storage-type family is
/// now plain struct (post-wave-4 Vec2 = `@Vector(2, f32)`, the
/// 3D family = `zm.Vec`, etc.), and Rectangle never crosses a
/// C-ABI seam by value (every GPU/raylib path takes individual
/// floats or a typed pointer).  The fields stay flat `f32` (no
/// "decompose into pos/size Vec2 fields" - see the wave-5
/// reflection: ~2000 sites of `r.x/.y/.width/.height` access vs
/// ~5-10 sites that would benefit from `r.pos + delta` Vec2 math;
/// the affordance is available via the new `pos()`/`translated()`
/// methods without the verbosity tax on every read site).
pub const Rectangle = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    // ---- Constructors
    pub fn init(x: f32, y: f32, width: f32, height: f32) Rectangle {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }
    /// Construct from top-left corner + size.
    pub fn fromCorners(top_left: Vec2, sz: Vec2) Rectangle {
        return .{ .x = top_left[0], .y = top_left[1], .width = sz[0], .height = sz[1] };
    }
    /// Construct from a pos + size pair of `Vec2`s.  Alias for
    /// `fromCorners` that reads naturally with the `pos()`/`size()`
    /// accessor pair.
    pub fn fromPosSize(pos_: Vec2, sz: Vec2) Rectangle {
        return .{ .x = pos_[0], .y = pos_[1], .width = sz[0], .height = sz[1] };
    }

    // ---- Accessors
    /// Top-left corner as `Vec2`.  Identical to `topLeft()` - the
    /// `pos` name exists for symmetry with `size()` so a caller doing
    /// pos/size math reads naturally.
    pub fn pos(r: Rectangle) Vec2 {
        return .{ r.x, r.y };
    }
    pub fn topLeft(r: Rectangle) Vec2 {
        return .{ r.x, r.y };
    }
    pub fn topRight(r: Rectangle) Vec2 {
        return .{ r.x + r.width, r.y };
    }
    pub fn bottomLeft(r: Rectangle) Vec2 {
        return .{ r.x, r.y + r.height };
    }
    pub fn bottomRight(r: Rectangle) Vec2 {
        return .{ r.x + r.width, r.y + r.height };
    }
    pub fn center(r: Rectangle) Vec2 {
        return .{ r.x + r.width * 0.5, r.y + r.height * 0.5 };
    }
    pub fn size(r: Rectangle) Vec2 {
        return .{ r.width, r.height };
    }

    // ---- Vec2-shaped affordances
    /// Translate `r` by `delta` (Vec2 add on the position; size
    /// unchanged).  Returns a new Rectangle; doesn't mutate.
    pub fn translated(r: Rectangle, delta: Vec2) Rectangle {
        return .{ .x = r.x + delta[0], .y = r.y + delta[1], .width = r.width, .height = r.height };
    }
    /// Scale `r`'s size by `factor` (Vec2 mul on the size; position
    /// unchanged).  Returns a new Rectangle; doesn't mutate.
    pub fn scaled(r: Rectangle, factor: Vec2) Rectangle {
        return .{ .x = r.x, .y = r.y, .width = r.width * factor[0], .height = r.height * factor[1] };
    }
    /// Inset `r` by `margin` on each side (positive = shrink, negative =
    /// grow).  Center stays the same.  Useful for adding padding around
    /// or within a widget rect.
    pub fn inset(r: Rectangle, margin: Vec2) Rectangle {
        return .{
            .x = r.x + margin[0],
            .y = r.y + margin[1],
            .width = r.width - 2 * margin[0],
            .height = r.height - 2 * margin[1],
        };
    }

    // ---- Tests
    /// Half-open inclusion: `r.x <= p.x < r.x + r.width` and likewise
    /// for y.  Standard hit-testing convention.
    pub fn contains(r: Rectangle, p: Vec2) bool {
        return p[0] >= r.x and p[0] < r.x + r.width and
            p[1] >= r.y and p[1] < r.y + r.height;
    }
    pub fn overlaps(a: Rectangle, b: Rectangle) bool {
        return a.x < b.x + b.width and
            b.x < a.x + a.width and
            a.y < b.y + b.height and
            b.y < a.y + a.height;
    }
    /// Returns the overlapping rectangle, or null if disjoint.  Width
    /// or height of 0 also returns null (touching is not overlap).
    pub fn intersection(a: Rectangle, b: Rectangle) ?Rectangle {
        const x: f32 = @max(a.x, b.x);
        const y: f32 = @max(a.y, b.y);
        const right: f32 = @min(a.x + a.width, b.x + b.width);
        const bottom: f32 = @min(a.y + a.height, b.y + b.height);
        if (right <= x or bottom <= y) {
            return null;
        }
        return .{ .x = x, .y = y, .width = right - x, .height = bottom - y };
    }
};

// ===========================================================================
// Image / Texture / RenderTexture
// ===========================================================================

pub const PixelFormat = enum(i32) {
    uncompressed_grayscale = 1,
    uncompressed_gray_alpha,
    uncompressed_r5g6b5,
    uncompressed_r8g8b8,
    uncompressed_r5g5b5a1,
    uncompressed_r4g4b4a4,
    uncompressed_r8g8b8a8,
    uncompressed_r32,
    uncompressed_r32g32b32,
    uncompressed_r32g32b32a32,
    uncompressed_r16,
    uncompressed_r16g16b16,
    uncompressed_r16g16b16a16,
    compressed_dxt1_rgb,
    compressed_dxt1_rgba,
    compressed_dxt3_rgba,
    compressed_dxt5_rgba,
    compressed_etc1_rgb,
    compressed_etc2_rgb,
    compressed_etc2_eac_rgba,
    compressed_pvrt_rgb,
    compressed_pvrt_rgba,
    compressed_astc_4x4_rgba,
    compressed_astc_8x8_rgba,

    /// True for the GPU-block-compressed formats (DXT/ETC/PVRT/ASTC).
    /// Most CPU-side image operations (crop, resize, recolor) bail
    /// when this is true because they'd need to decompress and
    /// recompress to apply the operation - raylib does the same.
    pub fn isCompressed(self: PixelFormat) bool {
        return @backingInt(self) >= @backingInt(PixelFormat.compressed_dxt1_rgb);
    }
};

pub const Image = extern struct {
    /// Raw pixel data.  Format depends on `format` (PixelFormat enum).
    data: ?*anyopaque = null,
    width: i32 = 0,
    height: i32 = 0,
    /// Mipmap levels uploaded.  1 = base only.
    mipmaps: i32 = 1,
    /// PixelFormat enum value.  See enums.zig.
    format: i32 = 0,

    /// Typed view of the `format` field.  The underlying field stays
    /// `i32` for raylib ABI parity, but call sites should prefer
    /// `image.pixelFormat()` over peeking at the int directly - it gives
    /// the compiler enough information to exhaustively check `switch`
    /// dispatch and rejects nonsense values like `-1` at runtime in
    /// safe builds.
    pub fn pixelFormat(self: Image) PixelFormat {
        return @fromBackingInt(@intCast(self.format));
    }

    // Verbs that act on Image (deinit / isValid / flipVertical /
    // flipHorizontal / rotateCW / rotateCCW / crop) live as free
    // functions in `drawing.textures`.  C-style: data here, verbs
    // there.  See `drawing.textures.unloadImage(gpa, image)`,
    // `drawing.textures.isImageValid(image)`, etc.
};

pub const Texture = extern struct {
    /// OpenGL/WebGL handle (in our port: an index into the JS-side
    /// handle table maintained by `src/web/runtime.js`).
    id: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    mipmaps: i32 = 1,
    format: i32 = 0,

    // Verbs that act on Texture (deinit / isValid / draw / drawAt /
    // drawEx / drawRec / drawPro) live as free functions
    // `deinit` in `rlgl.fwd.rlUnloadTexture(tex.id)`, the rest in
    // `drawing.textures`.  C-style: data here, verbs there.
};

/// Aliases - raylib defines these as `typedef Texture Texture;` etc.
pub const RenderTexture = extern struct {
    /// Framebuffer id.
    id: u32 = 0,
    /// Color attachment.
    texture: Texture = .{},
    /// Depth attachment.
    depth: Texture = .{},

    // Verbs (`isValid`, `deinit`) live in `drawing.textures` and
    // `rlgl.fwd.rlUnloadFramebuffer`.  See
    // `drawing.textures.isRenderTextureValid` and
    // `drawing.textures.unloadRenderTexture`.
};

pub const NPatchInfo = extern struct {
    source: Rectangle,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    /// NPatchLayout enum.
    layout: i32,
};

// ===========================================================================
// Font / glyph
// ===========================================================================

pub const GlyphInfo = extern struct {
    /// Codepoint.
    value: i32,
    offsetX: i32,
    offsetY: i32,
    advanceX: i32,
    /// Per-glyph image data; for atlas-rendered fonts this is unused
    /// after `LoadFontEx` packs glyphs into `Font.texture`.
    image: Image,
};

pub const Font = extern struct {
    /// Default character height in pixels.
    baseSize: i32 = 0,
    /// Number of glyphs in `glyphs` and corresponding `recs`.
    glyphCount: i32 = 0,
    /// Padding between glyphs in the atlas texture.
    glyphPadding: i32 = 0,
    /// Atlas texture: a single bitmap with all glyphs packed.
    texture: Texture = .{},
    /// Sub-rectangle into `texture` for each glyph; len = glyphCount.
    recs: [*c]Rectangle = null,
    /// Per-glyph metadata; len = glyphCount.
    glyphs: [*c]GlyphInfo = null,
    /// The font's outlines, for rasterizing glyphs at the size they are DRAWN
    /// (a `text2d.FontFace`; read it through `text2d.fontFace`). Set by
    /// `loadFont`/`loadFontEx`; null for baked-only fonts (bitmap, sprite, SDF,
    /// `loadFontBaked`), which always draw from `texture`. Opaque here because
    /// `types.zig` sits under `codecs.zig`, which several builds use as a module
    /// root on its own - importing `text2d.zig` from here would drag the whole
    /// text stack into those modules.
    face: ?*anyopaque = null,

    // Verbs (`isValid`, `deinit`) live in `drawing.text`
    // `isFontValid(font)` and `unloadFont(gpa, font)`.
};

// ===========================================================================
// Camera
// ===========================================================================

const Camera3D = zm.Camera3D;

/// raylib's `typedef Camera3D Camera;`.
pub const Camera = Camera3D;

// ===========================================================================
// Mesh / Material / Model
// ===========================================================================

pub const Mesh = extern struct {
    vertexCount: i32 = 0,
    triangleCount: i32 = 0,

    // Vertex attribute arrays.  All optional; a generated cube has
    // vertices/normals/texcoords but no tangents or bone weights.
    /// XYZ per vertex; shader-location 0.
    vertices: [*c]f32 = null,
    /// UV per vertex; shader-location 1.
    texcoords: [*c]f32 = null,
    /// Second UV channel; shader-location 5.
    texcoords2: [*c]f32 = null,
    /// Normals XYZ; shader-location 2.
    normals: [*c]f32 = null,
    /// Tangent XYZW; shader-location 4.
    tangents: [*c]f32 = null,
    /// RGBA per vertex; shader-location 3.
    colors: [*c]u8 = null,
    /// Index buffer (16-bit).
    indices: [*c]c_ushort = null,

    // Skinning data.
    /// MAX 256 bones.
    boneCount: i32 = 0,
    /// Up to 4 bones per vertex; shader-location 6.
    boneIndices: [*c]u8 = null,
    /// Bone weights matching boneIndices; shader-location 7.
    boneWeights: [*c]f32 = null,
    /// Bone palette pointer.  NOT owned by the Mesh - mirrors
    /// `model.boneMatrices` after `updateModelAnimation`.  Used by
    /// `drawMesh` to re-upload the boneMatrices uniform per draw.
    /// `null` means "this mesh isn't currently skinned" -> drawMesh
    /// uses the default shader path.
    boneMatrices: [*c]Matrix = null,

    // CPU-skinning result buffers.  Unused for GPU skinning.
    animVertices: [*c]f32 = null,
    animNormals: [*c]f32 = null,

    // GPU resources.
    /// VAO handle.
    vaoId: u32 = 0,
    /// VBO handles (per-attribute).  Allocated by `UploadMesh`.
    vboId: [*c]u32 = null,

    // Verbs (`deinit`, `boundingBox`) live in `drawing.models`
    // `unloadMesh(gpa, mesh)` and `getMeshBoundingBox(mesh)`.
};

pub const Shader = extern struct {
    /// Linked program id.
    id: u32 = 0,
    /// Per-shader-location uniform/attribute indices.  Length is
    /// RL_MAX_SHADER_LOCATIONS (32 in raylib).  Default shader locations
    /// match the ShaderLocationIndex enum.
    locs: [*c]i32 = null,

    // `deinit` lives in `drawing.shaders.unloadShader(gl, gpa, shader)`.
};

pub const MaterialMap = extern struct {
    texture: Texture = .{},
    color: Color = Color.white,
    /// Generic numeric parameter used by some maps (e.g. roughness).
    value: f32 = 0,
};

pub const Material = extern struct {
    shader: Shader = .{},
    /// Length is max_material_maps (12 in raylib); indices match
    /// MaterialMapIndex enum.
    maps: [*c]MaterialMap = null,
    params: [4]f32 = .{ 0, 0, 0, 0 },

    // Verbs (`isValid`, `deinit`, `setTexture`) live in
    // `drawing.models` - `isMaterialValid(material)`,
    // `unloadMaterial(gl, gpa, material)`,
    // `setMaterialTexture(material, map_type, texture)`.
};

/// TRS transform (translation / rotation / scale). Canonical home: `zm.Transform`.
pub const Transform = zm.Transform;

/// Animation pose: a heap array of Transform[boneCount].  raylib uses
/// `typedef Transform *ModelAnimPose;`.
pub const ModelAnimPose = [*c]Transform;

pub const BoneInfo = extern struct {
    name: [32]u8,
    parent: i32,
};

pub const ModelSkeleton = extern struct {
    boneCount: i32 = 0,
    bones: [*c]BoneInfo = null,
    bindPose: ModelAnimPose = null,
};

pub const Model = struct {
    /// Local-to-world transform applied to every mesh in the model.
    transform: Matrix,
    meshCount: i32 = 0,
    materialCount: i32 = 0,
    meshes: [*c]Mesh = null,
    materials: [*c]Material = null,
    /// `meshMaterial[i]` = index into `materials` for `meshes[i]`.
    meshMaterial: [*c]i32 = null,

    // Animation.
    skeleton: ModelSkeleton = .{},
    /// Updated each frame by UpdateModelAnimation.
    currentPose: ModelAnimPose = null,
    /// Bone matrix palette uploaded to the skinning shader.
    boneMatrices: [*c]Matrix = null,

    // Verbs (`isValid`, `deinit`, `boundingBox`) live in
    // `drawing.models` - `isModelValid(model)`,
    // `unloadModel(gpa, model)`, `getModelBoundingBox(model)`.
};

pub const ModelAnimation = extern struct {
    name: [32]u8,
    boneCount: i32 = 0,
    keyframeCount: i32 = 0,
    /// `keyframePoses[k]` is a Transform[boneCount] for keyframe k.
    keyframePoses: [*c]ModelAnimPose = null,
};

// ===========================================================================
// Geometry helpers (Ray, BoundingBox)
// ===========================================================================

/// Ray (origin + direction). Canonical home: `zm.Ray`.
pub const Ray = zm.Ray;

/// Ray-cast result. Canonical home: `zm.RayCollision`.
pub const RayCollision = zm.RayCollision;

/// Axis-aligned bounding box. Canonical home: `zm.Aabb`.
pub const Aabb = zm.Aabb;

/// Raylib spelling of `Aabb`.
pub const BoundingBox = Aabb;

// ===========================================================================
// Audio
// ===========================================================================

/// Opaque - defined privately in raudio.zig once the audio backend lands.
pub const rAudioBuffer = opaque {};
pub const rAudioProcessor = opaque {};

pub const Wave = extern struct {
    frameCount: u32 = 0,
    sampleRate: u32 = 0,
    sampleSize: u32 = 0,
    channels: u32 = 0,
    data: ?*anyopaque = null,
};

pub const AudioStream = extern struct {
    buffer: ?*rAudioBuffer = null,
    processor: ?*rAudioProcessor = null,
    sampleRate: u32 = 0,
    sampleSize: u32 = 0,
    channels: u32 = 0,
};

pub const Sound = extern struct {
    stream: AudioStream = .{},
    frameCount: u32 = 0,
};

pub const Music = extern struct {
    stream: AudioStream = .{},
    frameCount: u32 = 0,
    looping: bool = false,
    /// File-format-specific tag (WAV / OGG / MP3 / ...).
    ctxType: i32 = 0,
    /// Backend-internal pointer; managed by raudio.
    ctxData: ?*anyopaque = null,
};

// ===========================================================================
// VR
// ===========================================================================

pub const VrDeviceInfo = extern struct {
    hResolution: i32,
    vResolution: i32,
    hScreenSize: f32,
    vScreenSize: f32,
    eyeToScreenDistance: f32,
    lensSeparationDistance: f32,
    interpupillaryDistance: f32,
    lensDistortionValues: [4]f32,
    chromaAbCorrection: [4]f32,
};

pub const VrStereoConfig = struct {
    projection: [2]Matrix,
    viewOffset: [2]Matrix,
    leftLensCenter: [2]f32,
    rightLensCenter: [2]f32,
    leftScreenCenter: [2]f32,
    rightScreenCenter: [2]f32,
    scale: [2]f32,
    scaleIn: [2]f32,
};

// ===========================================================================
// File / automation
// ===========================================================================

pub const FilePathList = extern struct {
    /// Capacity not exposed; allocated by raylib as needed.
    count: u32 = 0,
    /// Null-terminated UTF-8 strings.
    paths: [*c][*c]u8 = null,
};

pub const AutomationEvent = extern struct {
    /// Frame index (since recording started).
    frame: u32,
    /// AutomationEventType enum (raylib internal).
    type: u32,
    params: [4]i32,
};

pub const AutomationEventList = extern struct {
    capacity: u32 = 0,
    count: u32 = 0,
    events: [*c]AutomationEvent = null,
};

// ===========================================================================
// Callbacks
// ===========================================================================
// Function pointer types raylib uses for tracelog hooks and the file-IO
// override system.  Optional (`?*const fn`) so they can be set to null
// to mean "use default behaviour".

pub const TraceLogCallback = ?*const fn (logLevel: i32, text: [*c]const u8, args: ?*anyopaque) callconv(.c) void;
pub const LoadFileDataCallback = ?*const fn (fileName: [*c]const u8, dataSize: [*c]i32) callconv(.c) [*c]u8;
pub const SaveFileDataCallback = ?*const fn (
    fileName: [*c]const u8,
    data: ?*anyopaque,
    dataSize: i32,
) callconv(.c) bool;
pub const LoadFileTextCallback = ?*const fn (fileName: [*c]const u8) callconv(.c) [*c]u8;
pub const SaveFileTextCallback = ?*const fn (fileName: [*c]const u8, text: [*c]const u8) callconv(.c) bool;
pub const AudioCallback = ?*const fn (bufferData: ?*anyopaque, frames: u32) callconv(.c) void;

// ============================================================================
// SECTION - Enums (was: src/enums.zig)
// ============================================================================
// raylib-style enums (typedef enum from raylib.h) plus the
// idiomatic raylib `KEY_*` / `MOUSE_*` / `FLAG_*` integer constants
// re-exported alongside the enum types.

pub const ConfigFlags = enum(u32) {
    vsync_hint = 0x00000040,
    fullscreen_mode = 0x00000002,
    window_resizable = 0x00000004,
    window_undecorated = 0x00000008,
    window_hidden = 0x00000080,
    window_minimized = 0x00000200,
    window_maximized = 0x00000400,
    window_unfocused = 0x00000800,
    window_topmost = 0x00001000,
    window_always_run = 0x00000100,
    window_transparent = 0x00000010,
    window_highdpi = 0x00002000,
    window_mouse_passthrough = 0x00004000,
    borderless_windowed_mode = 0x00008000,
    msaa_4x_hint = 0x00000020,
    interlaced_hint = 0x00010000,
};

// Trace log
// ===========================================================================

pub const TraceLogLevel = enum(i32) {
    all = 0,
    trace,
    debug,
    info,
    warning,
    err, // can't be `error` - Zig keyword
    fatal,
    none,
};

// Keyboard
// ===========================================================================
// Note: KEY_SPACE is 32, but most of the alphanumeric block has gaps
// the explicit `= N` annotations match raylib's original numeric values
// (which in turn track GLFW's keycodes).

pub const KeyboardKey = enum(i32) {
    null = 0,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    zero = 48,
    one,
    two,
    three,
    four,
    five,
    six,
    seven,
    eight,
    nine,
    semicolon = 59,
    equal = 61,
    a = 65,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave = 96,
    space = 32,
    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left,
    down,
    up,
    page_up = 266,
    page_down,
    home = 268,
    end,
    caps_lock = 280,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    f1 = 290,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    left_shift = 340,
    left_control,
    left_alt,
    left_super,
    right_shift = 344,
    right_control,
    right_alt,
    right_super,
    kb_menu = 348,
    kp_0 = 320,
    kp_1,
    kp_2,
    kp_3,
    kp_4,
    kp_5,
    kp_6,
    kp_7,
    kp_8,
    kp_9,
    kp_decimal = 330,
    kp_divide,
    kp_multiply,
    kp_subtract,
    kp_add,
    kp_enter,
    kp_equal,
    // Android / mobile
    back = 4,
    menu = 5,
    volume_up = 24,
    volume_down = 25,
    // Non-exhaustive marker.  The keyboard event queue can hold any
    // `i32` keycode the JS shim forwards (it filters to 1..512 but
    // doesn't restrict to enum tags), so `getKeyPressed` casts those
    // back to `KeyboardKey` via `@enumFromInt` - which would panic on
    // an unknown value if this enum were exhaustive.  The trade-off:
    // exhaustive `switch` over a `KeyboardKey` now needs an `else =>`
    // arm, which we don't have anywhere in the codebase today.
    _,
};

// raylib-style constants.  Generated by hand from KeyboardKey.  Kept
// in the same order as the enum decls so a side-by-side diff is easy.

// ===========================================================================
// Mouse
// ===========================================================================

pub const MouseButton = enum(i32) {
    left = 0,
    right = 1,
    middle = 2,
    side = 3,
    extra = 4,
    forward = 5,
    back = 6,
};

pub const MouseCursor = enum(i32) {
    default = 0,
    arrow,
    ibeam,
    crosshair,
    pointing_hand,
    resize_ew,
    resize_ns,
    resize_nwse,
    resize_nesw,
    resize_all,
    not_allowed,
};

// ===========================================================================
// Gamepad
// ===========================================================================

pub const GamepadButton = enum(i32) {
    unknown = 0,
    left_face_up,
    left_face_right,
    left_face_down,
    left_face_left,
    right_face_up,
    right_face_right,
    right_face_down,
    right_face_left,
    left_trigger_1,
    left_trigger_2,
    right_trigger_1,
    right_trigger_2,
    middle_left,
    middle,
    middle_right,
    left_thumb,
    right_thumb,
};

pub const GamepadAxis = enum(i32) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,
};

// ===========================================================================
// Materials
// ===========================================================================

/// Material-map slot indices.  Re-exported from `shader_interface.zig`
/// where it now lives canonically - same enum is used by typed shader
/// schemas (`Sampler2D(.albedo)`) and engine-side material maps
/// (`material.maps[.albedo].texture = ...`).  The move was driven by
/// module-boundary mechanics: `shader_interface` must be wirable as
/// a standalone named module for the codegen bootstrap exes, so its
/// dependency on `types.zig` was inverted (now `types.zig` depends
/// on `shader_interface` - a small one-way re-export).  Backwards-
/// compatible: every `types.MaterialMapIndex` call site keeps working.
const _shader_interface = @import("shader_interface");
pub const MaterialMapIndex = _shader_interface.MaterialMapIndex;

// Shaders
// ===========================================================================

pub const ShaderLocationIndex = enum(i32) {
    vertex_position = 0,
    vertex_texcoord01,
    vertex_texcoord02,
    vertex_normal,
    vertex_tangent,
    vertex_color,
    matrix_mvp,
    matrix_view,
    matrix_projection,
    matrix_model,
    matrix_normal,
    vector_view,
    color_diffuse,
    color_specular,
    color_ambient,
    map_albedo,
    map_metalness,
    map_normal,
    map_roughness,
    map_occlusion,
    map_emission,
    map_height,
    map_cubemap,
    map_irradiance,
    map_prefilter,
    map_brdf,
    vertex_boneids,
    vertex_boneweights,
    matrix_bonetransforms,
    vertex_instancetransform,
};

// raylib-style constants for the shader loc indices.  We don't enum
// every shader location below SHADER_LOC_VERTEX_INSTANCETRANSFORM
// the raylib examples only reference a handful.  Add others on demand.

pub const ShaderUniformDataType = enum(i32) {
    float = 0,
    vec2,
    vec3,
    vec4,
    int,
    ivec2,
    ivec3,
    ivec4,
    uint,
    uivec2,
    uivec3,
    uivec4,
    sampler2d,
};

pub const ShaderAttributeDataType = enum(i32) {
    float = 0,
    vec2,
    vec3,
    vec4,
};

// ============================================================================
// Compile-time guard: pin the wire values of the shader enums above.
// `ShaderLocationIndex` and `ShaderUniformDataType` are ABI - their
// integer values are baked into raylib's `locs[]` array layout and
// into `rlSetUniform`'s type-tag switch.  rlgl.zig and drawing.zig
// derive their own constants from these enums via `@intFromEnum`, so
// these enums are the SINGLE SOURCE OF TRUTH.
// This block exists because they were previously NOT the source of
// truth: three files hand-copied the integer values, the copies
// drifted (VEC4/INT tags off by an enum slot; VERTEX_NORMAL at 2 vs
// 3), and the result was silent uniform-upload corruption that took a
// long debugging session to find.  Now the copies are gone - but if
// someone reorders or inserts a variant in the enums above, every
// derived constant shifts silently again.  This guard turns that into
// a loud compile error pointing right here.
// If you intentionally change raylib's ABI, update these asserts to
// match - deliberately, with the GL-side layout in mind.
// ============================================================================
comptime {
    const SLI = ShaderLocationIndex;
    // Spot-check the slots that actually drifted historically, plus the
    // anchors (first, a matrix, the diffuse color/map) so a shift
    // anywhere in the range is caught.
    if (@backingInt(SLI.vertex_position) != 0) {
        @compileError("ShaderLocationIndex ABI drift: vertex_position must be 0");
    }
    if (@backingInt(SLI.vertex_texcoord02) != 2) {
        @compileError("ShaderLocationIndex ABI drift: vertex_texcoord02 must be 2");
    }
    if (@backingInt(SLI.vertex_normal) != 3) {
        @compileError("ShaderLocationIndex ABI drift: vertex_normal must be 3");
    }
    if (@backingInt(SLI.vertex_color) != 5) {
        @compileError("ShaderLocationIndex ABI drift: vertex_color must be 5");
    }
    if (@backingInt(SLI.matrix_mvp) != 6) {
        @compileError("ShaderLocationIndex ABI drift: matrix_mvp must be 6");
    }
    if (@backingInt(SLI.color_diffuse) != 12) {
        @compileError("ShaderLocationIndex ABI drift: color_diffuse must be 12");
    }
    if (@backingInt(SLI.map_albedo) != 15) {
        @compileError("ShaderLocationIndex ABI drift: map_albedo must be 15");
    }
    if (@backingInt(SLI.vertex_instancetransform) != 29) {
        @compileError("ShaderLocationIndex ABI drift: vertex_instancetransform must be 29");
    }

    const SUT = ShaderUniformDataType;
    // These are the tags rlSetUniform switches on to pick glUniform*.
    // The historical bug was VEC4 mistaken for 4 (=int) and INT for 6
    // (=ivec3); pin the whole float/int range.
    if (@backingInt(SUT.float) != 0) {
        @compileError("ShaderUniformDataType ABI drift: float must be 0");
    }
    if (@backingInt(SUT.vec3) != 2) {
        @compileError("ShaderUniformDataType ABI drift: vec3 must be 2");
    }
    if (@backingInt(SUT.vec4) != 3) {
        @compileError("ShaderUniformDataType ABI drift: vec4 must be 3");
    }
    if (@backingInt(SUT.int) != 4) {
        @compileError("ShaderUniformDataType ABI drift: int must be 4");
    }
    if (@backingInt(SUT.ivec3) != 6) {
        @compileError("ShaderUniformDataType ABI drift: ivec3 must be 6");
    }
    if (@backingInt(SUT.sampler2d) != 12) {
        @compileError("ShaderUniformDataType ABI drift: sampler2d must be 12");
    }
}

// Pixel format / texture filter / wrap
// ===========================================================================

pub const PIXELFORMAT_COMPRESSED_ASTC_4x4_RGBA: i32 = 23;
pub const PIXELFORMAT_COMPRESSED_ASTC_8x8_RGBA: i32 = 24;

pub const TextureFilter = enum(i32) {
    point = 0,
    bilinear,
    trilinear,
    anisotropic_4x,
    anisotropic_8x,
    anisotropic_16x,
};

pub const TextureWrap = enum(i32) {
    repeat = 0,
    clamp,
    mirror_repeat,
    mirror_clamp,
};

pub const CubemapLayout = enum(i32) {
    auto_detect = 0,
    line_vertical,
    line_horizontal,
    cross_three_by_four,
    cross_four_by_three,
};

// Fonts
// ===========================================================================

pub const FontType = enum(i32) {
    default = 0,
    bitmap,
    sdf,
};

// Blend modes
// ===========================================================================

pub const BlendMode = enum(i32) {
    alpha = 0,
    additive,
    multiplied,
    add_colors,
    subtract_colors,
    alpha_premultiply,
    custom,
    custom_separate,
};

// Gestures (bit field - multiple gestures can be detected at once)
// ===========================================================================

pub const Gesture = enum(u32) {
    none = 0,
    tap = 1,
    doubletap = 2,
    hold = 4,
    drag = 8,
    swipe_right = 16,
    swipe_left = 32,
    swipe_up = 64,
    swipe_down = 128,
    pinch_in = 256,
    pinch_out = 512,
};

// Camera
// ===========================================================================

pub const CameraMode = enum(i32) {
    custom = 0,
    free,
    orbital,
    first_person,
    third_person,
};

// N-Patch layouts
// ===========================================================================

pub const NPatchLayout = enum(i32) {
    nine_patch = 0,
    three_patch_vertical,
    three_patch_horizontal,
};

// ============================================================================
// SECTION - Tailwind palette + raylib defaults (was: src/colors.zig)
// ============================================================================

inline fn hex(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

// --- Greys ------------------------------------------------------------
pub const white = Color.init(255, 255, 255, 255);
pub const black = Color.init(0, 0, 0, 255);

pub const slate_50 = hex(248, 250, 252);
pub const slate_100 = hex(241, 245, 249);
pub const slate_200 = hex(226, 232, 240);
pub const slate_300 = hex(203, 213, 225);
pub const slate_400 = hex(148, 163, 184);
pub const slate_500 = hex(100, 116, 139);
pub const slate_600 = hex(71, 85, 105);
pub const slate_700 = hex(51, 65, 85);
pub const slate_800 = hex(30, 41, 59);
pub const slate_900 = hex(15, 23, 42);
pub const slate_950 = hex(2, 6, 23);

// --- Blue / sky -------------------------------------------------------
pub const sky_50 = hex(240, 249, 255);
pub const sky_100 = hex(224, 242, 254);
pub const sky_200 = hex(186, 230, 253);
pub const sky_300 = hex(125, 211, 252);
pub const sky_400 = hex(56, 189, 248);
pub const sky_500 = hex(14, 165, 233);
pub const sky_600 = hex(2, 132, 199);
pub const sky_700 = hex(3, 105, 161);
pub const sky_800 = hex(7, 89, 133);
pub const sky_900 = hex(12, 74, 110);

// --- Amber / gold -----------------------------------------------------
pub const amber_400 = hex(251, 191, 36);
pub const amber_500 = hex(245, 158, 11);
pub const gold = hex(255, 203, 0); // raylib gold

// --- Reds / pinks -----------------------------------------------------
pub const red_400 = hex(248, 113, 113);
pub const red_500 = hex(239, 68, 68);
pub const red_600 = hex(220, 38, 38);
pub const pink_400 = hex(244, 114, 182);
pub const pink_500 = hex(236, 72, 153);
pub const pink_600 = hex(219, 39, 119);

// --- Greens -----------------------------------------------------------
pub const green_400 = hex(74, 222, 128);
pub const green_500 = hex(34, 197, 94);
pub const emerald_500 = hex(16, 185, 129);

// Additional Tailwind shades used by examples (added Session N+29 for models3d).
pub const amber_200 = hex(253, 230, 138);
pub const amber_300 = hex(252, 211, 77);
pub const emerald_200 = hex(167, 243, 208);
pub const emerald_400 = hex(52, 211, 153);
pub const sky_950 = hex(8, 47, 73);
pub const rose_200 = hex(254, 205, 211);
pub const rose_400 = hex(251, 113, 133);
pub const rose_500 = hex(244, 63, 94);
pub const violet_400 = hex(167, 139, 250);
pub const violet_500 = hex(139, 92, 246);

// ============================================================================
// Tests for Vec2 / Color / Rectangle method APIs (formerly types_test.zig).
// Each method gets at least one positive-case test plus targeted
// edge-case tests for the trickier ones (normalize-of-zero, lerp at
// t=0/t=1, intersection of disjoint rects, etc.).
// ============================================================================

const eps: f32 = 1e-5;

// ===========================================================================
// Vec2
// ===========================================================================
// Z4 wave 4: `Vec2` is `@Vector(2, f32)` now.  Tests
// use Vec idioms (native operators, `zm.*` functions) - the old
// bespoke method suite (`.init`/`.zero`/`.add`/`.dot`/`.length`/
// `.normalize`/`.rotate`/`.reflect`/`.lerp`/`.clamp`) was deleted
// when the type flipped.  Use `zm.vec2(x, y)` to build values,
// or the short literal `Vec2{x, y}`.

test "Vec2 constructors + arithmetic" {
    const a: Vec2 = .{ 3, 4 };
    const b: Vec2 = .{ 1, 2 };
    try expectEqual(Vec2{ 4, 6 }, a + b);
    try expectEqual(Vec2{ 2, 2 }, a - b);
    try expectEqual(Vec2{ 3, 8 }, a * b);
    try expectEqual(Vec2{ 6, 8 }, a * @as(Vec2, @splat(2)));
    try expectEqual(Vec2{ -3, -4 }, -a);
    try expectEqual(Vec2{ 0, 0 }, @as(Vec2, @splat(0)));
}

test "Vec2 dot + length" {
    const a: Vec2 = .{ 3, 4 };
    const b: Vec2 = .{ 1, 2 };
    // 2-lane dot via builtin reduce.
    try expectApproxEqAbs(@as(f32, 11), @reduce(.Add, a * b), eps);
    const len_sq: f32 = @reduce(.Add, a * a);
    try expectApproxEqAbs(@as(f32, 25), len_sq, eps);
    try expectApproxEqAbs(@as(f32, 5), @sqrt(len_sq), eps);
}

test "Vec2 normalize unit length" {
    const v: Vec2 = .{ 3, 4 };
    const len: f32 = @sqrt(@reduce(.Add, v * v));
    const n: Vec2 = v / @as(Vec2, @splat(len));
    try expectApproxEqAbs(@as(f32, 1), @sqrt(@reduce(.Add, n * n)), eps);
    try expectApproxEqAbs(@as(f32, 0.6), n[0], eps);
    try expectApproxEqAbs(@as(f32, 0.8), n[1], eps);
}

test "Vec2 lerp endpoints" {
    const a: Vec2 = .{ 0, 0 };
    const b: Vec2 = .{ 10, 20 };
    try expectEqual(a, lerp(a, b, 0));
    try expectEqual(b, lerp(a, b, 1));
    const mid: Vec2 = lerp(a, b, 0.5);
    try expectApproxEqAbs(@as(f32, 5), mid[0], eps);
    try expectApproxEqAbs(@as(f32, 10), mid[1], eps);
}

test "Vec2 rotate by 90deg / 360deg" {
    // +x rotated 90 CCW -> +y
    const r90 = rotate2(Vec2{ 1, 0 }, pi / 2.0);
    try expectApproxEqAbs(@as(f32, 0), r90[0], 1.0e-6);
    try expectApproxEqAbs(@as(f32, 1), r90[1], 1.0e-6);
    // full turn is identity
    const r360 = rotate2(Vec2{ 0.4, -0.9 }, tau);
    try expectApproxEqAbs(@as(f32, 0.4), r360[0], 1.0e-5);
    try expectApproxEqAbs(@as(f32, -0.9), r360[1], 1.0e-5);
}

test "Vec2 min / max / clamp via native ops" {
    const a: Vec2 = .{ 3, 7 };
    const b: Vec2 = .{ 5, 2 };
    try expectEqual(Vec2{ 3, 2 }, @min(a, b));
    try expectEqual(Vec2{ 5, 7 }, @max(a, b));
    const v: Vec2 = .{ 7, 5 };
    const lo: Vec2 = .{ 0, 0 };
    const hi: Vec2 = .{ 4, 10 };
    try expectEqual(Vec2{ 4, 5 }, clamp(v, lo, hi));
}

// ===========================================================================
// Color - constructors
// ===========================================================================

test "Color.init / rgb / hex" {
    try expectEqual(Color{ .r = 1, .g = 2, .b = 3, .a = 4 }, Color.init(1, 2, 3, 4));
    try expectEqual(Color{ .r = 1, .g = 2, .b = 3, .a = 255 }, Color.rgb(1, 2, 3));
    // 0xff8800ff = orange-ish solid
    try expectEqual(Color{ .r = 0xff, .g = 0x88, .b = 0x00, .a = 0xff }, Color.hex(0xff8800ff));
    // Black with full alpha
    try expectEqual(Color{ .r = 0, .g = 0, .b = 0, .a = 0xff }, Color.hex(0x000000ff));
}

// ===========================================================================
// Color - predicates / conversion
// ===========================================================================

test "Color.equals" {
    try expect(Color.red.equals(Color.red));
    try expect(!Color.red.equals(Color.green));
}

test "Color.toInt round-trips with hex" {
    const c = Color.init(0x12, 0x34, 0x56, 0x78);
    try expectEqual(@as(u32, 0x12345678), c.toHex());
    // hex(toInt(c)) should equal c
    try expect(c.equals(Color.hex(c.toHex())));
}

test "Color.toFloats" {
    const c = Color.init(255, 0, 128, 255);
    const f: [4]f32 = c.toFloats();
    try expectApproxEqAbs(@as(f32, 1.0), f[0], eps);
    try expectApproxEqAbs(@as(f32, 0.0), f[1], eps);
    try expectApproxEqAbs(@as(f32, 128.0 / 255.0), f[2], eps);
    try expectApproxEqAbs(@as(f32, 1.0), f[3], eps);
}

// ===========================================================================
// Color - manipulation
// ===========================================================================

test "Color.lerp endpoints" {
    const a = Color.init(0, 0, 0, 255);
    const b = Color.init(255, 255, 255, 255);
    try expect(a.lerp(b, 0).equals(a));
    try expect(a.lerp(b, 1).equals(b));
    // Halfway should be roughly gray
    const mid: Color = a.lerp(b, 0.5);
    try expect(mid.r >= 126 and mid.r <= 128);
    try expect(mid.g >= 126 and mid.g <= 128);
    try expect(mid.b >= 126 and mid.b <= 128);
}

test "Color.fade clamps alpha" {
    const c = Color.red;
    try expectEqual(@as(u8, 0), c.fade(0).a);
    try expectEqual(@as(u8, 255), c.fade(1).a);
    try expectEqual(@as(u8, 0), c.fade(-1).a); // clamped low
    try expectEqual(@as(u8, 255), c.fade(2).a); // clamped high
    // RGB unchanged
    const f: Color = c.fade(0.5);
    try expectEqual(c.r, f.r);
    try expectEqual(c.g, f.g);
    try expectEqual(c.b, f.b);
}

test "Color.brightness" {
    const gray_ = Color.init(100, 100, 100, 200);
    // factor=2 brightens to 200/200/200
    const lit: Color = gray_.brightness(2);
    try expectEqual(@as(u8, 200), lit.r);
    try expectEqual(@as(u8, 200), lit.a); // alpha unchanged
    // factor=0 makes black
    try expectEqual(@as(u8, 0), gray_.brightness(0).r);
    // factor=255+ clamps to 255 per channel
    try expectEqual(@as(u8, 255), gray_.brightness(1000).r);
}

// ===========================================================================
// Rectangle - constructors + accessors
// ===========================================================================

test "Rectangle.init / fromCorners" {
    const r = Rectangle.init(1, 2, 3, 4);
    try expectEqual(@as(f32, 1), r.x);
    try expectEqual(@as(f32, 4), r.height);

    const r2 = Rectangle.fromCorners(.{ 1, 2 }, .{ 3, 4 });
    try expectEqual(r, r2);
}

test "Rectangle accessors" {
    const r = Rectangle.init(10, 20, 30, 40);
    try expectEqual(Vec2{ 10, 20 }, r.pos());
    try expectEqual(Vec2{ 10, 20 }, r.topLeft());
    try expectEqual(Vec2{ 40, 20 }, r.topRight());
    try expectEqual(Vec2{ 10, 60 }, r.bottomLeft());
    try expectEqual(Vec2{ 40, 60 }, r.bottomRight());
    try expectEqual(Vec2{ 25, 40 }, r.center());
    try expectEqual(Vec2{ 30, 40 }, r.size());
}

test "Rectangle Vec2-shaped affordances: translated / scaled / inset" {
    const r = Rectangle.init(10, 20, 30, 40);

    // translate: shift position, size unchanged.
    const t: Rectangle = r.translated(.{ 5, -3 });
    try expectEqual(Rectangle.init(15, 17, 30, 40), t);

    // scale: position unchanged, size multiplied component-wise.
    const s: Rectangle = r.scaled(.{ 2, 0.5 });
    try expectEqual(Rectangle.init(10, 20, 60, 20), s);

    // inset by (1, 2): shrink by 1 on left and right, 2 on top and bottom.
    const i: Rectangle = r.inset(.{ 1, 2 });
    try expectEqual(Rectangle.init(11, 22, 28, 36), i);
    // center invariant under inset.
    try expectEqual(r.center(), i.center());

    // fromPosSize: pos+size pair maps to (x, y, width, height).
    const r2 = Rectangle.fromPosSize(.{ 1, 2 }, .{ 3, 4 });
    try expectEqual(Rectangle.init(1, 2, 3, 4), r2);
}

// ===========================================================================
// Rectangle - tests
// ===========================================================================

test "Rectangle.contains" {
    const r = Rectangle.init(0, 0, 10, 10);
    try expect(r.contains(Vec2{ 5, 5 }));
    try expect(r.contains(Vec2{ 0, 0 })); // top-left inclusive
    try expect(!r.contains(Vec2{ 10, 5 })); // right edge exclusive
    try expect(!r.contains(Vec2{ 5, 10 })); // bottom edge exclusive
    try expect(!r.contains(Vec2{ -1, 5 }));
}

test "Rectangle.overlaps" {
    const a = Rectangle.init(0, 0, 10, 10);
    const b = Rectangle.init(5, 5, 10, 10);
    try expect(a.overlaps(b));
    try expect(b.overlaps(a)); // commutative

    // Touching but not overlapping (b starts at right edge of a)
    const c = Rectangle.init(10, 0, 5, 5);
    try expect(!a.overlaps(c));

    // Disjoint
    const d = Rectangle.init(100, 100, 5, 5);
    try expect(!a.overlaps(d));
}

test "Rectangle.intersection" {
    const a = Rectangle.init(0, 0, 10, 10);
    const b = Rectangle.init(5, 5, 10, 10);
    const i: Rectangle = a.intersection(b).?;
    try expectEqual(Rectangle.init(5, 5, 5, 5), i);

    // Disjoint -> null
    const d = Rectangle.init(100, 100, 5, 5);
    try expect(a.intersection(d) == null);

    // Touching -> null (touching is not overlap by our half-open convention)
    const c = Rectangle.init(10, 0, 5, 5);
    try expect(a.intersection(c) == null);
}

// ===========================================================================
// Vec2i
// ===========================================================================

test "Vec2i constructors + equality" {
    // `@Vector(2, i32)` literal coercion works the same as struct
    // literal - `.{ a, b }` picks up the inferred type from the
    // expected argument.
    try expectEqual(@as(Vec2i, .{ 3, 4 }), @as(Vec2i, .{ 3, 4 }));
    try expectEqual(splat2i(0), @as(Vec2i, .{ 0, 0 }));
    try expectEqual(splat2i(1), @as(Vec2i, .{ 1, 1 }));
    try expectEqual(splat2i(7), @as(Vec2i, .{ 7, 7 }));

    // Equality: SIMD comparison gives a bool vector; reduce with `.And`
    // for "all components equal", or use std.meta.eql for direct
    // value comparison.  expectEqual on @Vector also works.
    const a: Vec2i = .{ 3, 4 };
    const b: Vec2i = .{ 3, 4 };
    const c: Vec2i = .{ 3, 5 };
    try expect(@reduce(.And, a == b));
    try expect(!@reduce(.And, a == c));
}

test "Vec2i arithmetic basics" {
    const a: Vec2i = .{ 10, 20 };
    const b: Vec2i = .{ 3, 4 };
    try expectEqual(@as(Vec2i, .{ 13, 24 }), a + b);
    try expectEqual(@as(Vec2i, .{ 7, 16 }), a - b);
    try expectEqual(@as(Vec2i, .{ 20, 40 }), a * splat2i(2));
    try expectEqual(@as(Vec2i, .{ -10, -20 }), a * splat2i(-1));
}

test "vec2iToFloat preserves value exactly for in-range integers" {
    const i: Vec2i = .{ 640, 480 };
    const f: Vec2 = vec2iToFloat(i);
    try expectEqual(@as(f32, 640), f[0]);
    try expectEqual(@as(f32, 480), f[1]);
}

test "Vec2i min / max via @min / @max builtins" {
    const a: Vec2i = .{ 3, 9 };
    const b: Vec2i = .{ 7, 2 };
    try expectEqual(@as(Vec2i, .{ 3, 2 }), @min(a, b));
    try expectEqual(@as(Vec2i, .{ 7, 9 }), @max(a, b));
}

// ===========================================================================
// Vec
// ===========================================================================

test "Vec constructors + arithmetic" {
    const a: Vec = vec(3, 4, 5);
    const b: Vec = vec(1, 2, 0);
    try expectEqual(vec(4, 6, 5), a + b);
    try expectEqual(vec(2, 2, 5), a - b);
    try expectEqual(vec(6, 8, 10), a * splat(2));
    try expectEqual(vec(-3, -4, -5), -a);
    try expectEqual(vec(0, 0, 0), vec(0, 0, 0));
}

test "Vec.cross right-handed" {
    // x x y = z (right-handed coordinates)
    const x_axis: Vec = vec(1, 0, 0);
    const y_axis: Vec = vec(0, 1, 0);
    try expectEqual(vec(0, 0, 1), cross(x_axis, y_axis));
    // y x x = -z (anti-commutative)
    try expectEqual(vec(0, 0, -1), cross(y_axis, x_axis));
}

test "Vec.dot + length" {
    const v: Vec = vec(2, 3, 6);
    try expectApproxEqAbs(@as(f32, 49), lengthSq3(v), eps);
    try expectApproxEqAbs(@as(f32, 7), length3(v), eps);
    try expectApproxEqAbs(@as(f32, 0), dot3(vec(1, 0, 0), vec(0, 1, 0)), eps);
}

test "Vec.normalize unit length" {
    const n: Vec = normalize3(vec(2, 3, 6));
    try expectApproxEqAbs(@as(f32, 1), length3(n), eps);
}

test "Vec.lerp + reflect + project" {
    const a: Vec = vec(0, 0, 0);
    const b: Vec = vec(10, 20, 30);
    try expectEqual(a, lerp(a, b, 0));
    try expectEqual(b, lerp(a, b, 1));

    // Reflect off floor (normal +Y): incoming (1, -1, 0) -> outgoing (1, 1, 0)
    const reflected: Vec = reflect3(vec(1, -1, 0), vec(0, 1, 0));
    try expectApproxEqAbs(@as(f32, 1), reflected[0], eps);
    try expectApproxEqAbs(@as(f32, 1), reflected[1], eps);

    // Project (1, 1, 0) onto x-axis = (1, 0, 0)
    const projected: Vec = project3(vec(1, 1, 0), vec(1, 0, 0));
    try expectApproxEqAbs(@as(f32, 1), projected[0], eps);
    try expectApproxEqAbs(@as(f32, 0), projected[1], eps);
}

// ===========================================================================
// Vec
// ===========================================================================

test "Vec constructors + arithmetic + dot" {
    const a: Vec = f32x4(1, 2, 3, 4);
    const b: Vec = f32x4(5, 6, 7, 8);
    try expectEqual(f32x4(6, 8, 10, 12), a + b);
    try expectEqual(f32x4(-1, -2, -3, -4), -a);
    // dot = 1*5 + 2*6 + 3*7 + 4*8 = 5+12+21+32 = 70
    try expectApproxEqAbs(@as(f32, 70), dot4(a, b), eps);
    try expectEqual(@as(Vec, @splat(0)), vec_zero);
}

// ===========================================================================
// Matrix
// ===========================================================================

test "Matrix.identity is identity" {
    const i: Mat = identity();
    try expectApproxEqAbs(@as(f32, 1), i[0][0], eps);
    try expectApproxEqAbs(@as(f32, 1), i[1][1], eps);
    try expectApproxEqAbs(@as(f32, 1), i[2][2], eps);
    try expectApproxEqAbs(@as(f32, 1), i[3][3], eps);
    try expectApproxEqAbs(@as(f32, 0), i[1][0], eps); // off-diagonal
}

test "Matrix.translation puts xyz in the translation row" {
    const t: Mat = translation(7, 8, 9);
    try expectApproxEqAbs(@as(f32, 7), t[3][0], eps);
    try expectApproxEqAbs(@as(f32, 8), t[3][1], eps);
    try expectApproxEqAbs(@as(f32, 9), t[3][2], eps);
    try expectApproxEqAbs(@as(f32, 1), t[3][3], eps);
}

test "Matrix.identity * v == v (Vec.transform)" {
    const i: Mat = identity();
    const v: Vec = vec(3, 4, 5);
    // Row-vector convention: v * I = v.  Vec3 is treated as a point
    // (lane 3 = 1) for the affine transform.
    const v_pt: Vec = f32x4(v[0], v[1], v[2], 1);
    const result: Vec = mulMatVec(i, v_pt);
    try expectApproxEqAbs(v[0], result[0], eps);
    try expectApproxEqAbs(v[1], result[1], eps);
    try expectApproxEqAbs(v[2], result[2], eps);
}

test "Matrix.translation * v translates v (Vec.transform)" {
    const t: Mat = translation(10, 20, 30);
    const v: Vec = vec(1, 2, 3);
    const v_pt: Vec = f32x4(v[0], v[1], v[2], 1);
    const result: Vec = mulMatVec(t, v_pt);
    try expectApproxEqAbs(@as(f32, 11), result[0], eps);
    try expectApproxEqAbs(@as(f32, 22), result[1], eps);
    try expectApproxEqAbs(@as(f32, 33), result[2], eps);
}

// Matrix invert/mul behavior tests live in zimrmath.zig (the
// canonical implementation).  We don't re-test them here because
// types.zig is meant to be `std`-only above the math constructors.
// Keeping it that way preserves the invariant that data types
// don't import sibling modules.

// (The "method-style call" regression test was deleted with Z4 wave 4
//: `Vec2` is `@Vector(2, f32)` with no methods.  Vec
// and Vec were already methodless after waves 2-3.  Method-style
// calls on these types are now compile errors - there's nothing left
// to test.)

// ===========================================================================
// Resource types - Phase 12.2
// Most resource fns need GPU state or file I/O to test meaningfully.
// We stick to predicate + zero-init behavior here; full lifecycle
// coverage lives in the smoke tests.
// ===========================================================================

test "Texture is an alias for Texture" {
    try expectEqual(@as(type, Texture), Texture);
}

// Tests that exercise the verbs that *act on* these data types
// live next to the verbs themselves, in `drawing.textures`,
// `drawing.text`, `drawing.models`.  See `isImageValid` /
// `isTextureValid` / `isFontValid` / `isMaterialValid` /
// `isModelValid` test blocks there.
