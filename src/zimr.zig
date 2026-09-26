//! lint:alias z
//! ============================================================================
//! zimr WebGPU architecture - THE reference doc for the wgpu stack
//! ============================================================================
//!
//! This module is the public surface of zimr's WebGPU backend AND the
//! canonical description of how that backend is put together.  If you are
//! about to touch ANY wgpu code, shader, or example and you don't already
//! hold this model in your head: read this first.  Other wgpu files point
//! here rather than re-explaining; keep it that way (see claude.md, rule
//! "big-system docs live in code").
//!
//! ---- 0. What this is --------------------------------------------------
//! zimr is a pure-Zig port of raylib + Dear ImGui to the browser.  It is
//! migrating its rendering from WebGL2/GLSL to WebGPU/WGSL.  Both backends
//! exist transitionally; the GL path is scheduled for deletion (see
//! src/notes/webgpu-migration-plan.md Phase F).  This file is the WebGPU
//! half.  One import gives a consumer everything:
//!
//!     const z = @import("zimr");
//!     var r = try z.Renderer2D.init(gpa, &gpu_frame);   // 2D
//!     // or build a pipeline by hand for 3D - see section 4.
//!
//! ---- 1. The shader pipeline (BUILD-TIME ONLY) -------------------------
//! Shaders are authored in Zig (NOT WGSL, NOT GLSL).  At BUILD time each
//! shader compiles down a four-stage pipeline; the SHIPPED wasm carries
//! ZERO transpiler - only the final WGSL, `@embedFile`'d.  The chain:
//!
//!     shader.zig                         (author writes this)
//!       |  zig build-obj -target spirv32-vulkan
//!       v
//!     shader.spv                         (raw SPIR-V)
//!       |  zspv  (tools/zspv.zig - pure-Zig SPIR-V rewriter)
//!       |        * combined-image-sampler -> split texture+sampler
//!       |        * stamps DescriptorSet/Binding decorations
//!       v
//!     shader.spv  (rewritten)
//!       |  spv2wgsl  (src/spv2wgsl.zig - pure-Zig SPIR-V->WGSL)
//!       v
//!     shader.wgsl                        (@embedFile'd into the wasm)
//!
//! There is NO spirv-opt / spirv-cross on the WGSL path (those serve only
//! the dying GL path).  The transpiler IR is var-based, not SSA - this is
//! deliberate; do not move it toward SSA.  spv2wgsl HONORS explicit binding
//! decorations and only auto-numbers resources that lack them.
//!
//! ---- 2. The schema convention (`_io.zig` files) -----------------------
//! Every shader stage has a sibling `<name>_<stage>_io.zig` that declares
//! its interface as plain Zig structs.  Recognized sections:
//!
//!     Attributes  - VS vertex inputs   (each field an Attr(kind, location))
//!     Inputs      - FS interpolated varyings (locations by declaration order)
//!     Outputs     - stage outputs      (locations by declaration order)
//!     Ubo         - ONE uniform-buffer struct  (the single-UBO convention)
//!     Uniforms    - LOOSE uniform fields, each its own binding (engine path)
//!     Samplers    - Sampler2D(tag, config) fields (texture+sampler pairs)
//!
//! STAGE IS DETECTED STRUCTURALLY: a VS schema has `Attributes`; an FS
//! schema has `Inputs`.  (Verified across every engine shader pair.)  This
//! detection drives the binding model in section 3.  `Ubo` and `Uniforms` are
//! mutually exclusive in practice - `Ubo` = one struct buffer, `Uniforms`
//! = loose fields.  Codegen (tools/gen_shader_externs.zig) turns the schema
//! into `extern` decls + an `installSpirvEntry` wrapper that emits every
//! `OpDecorate` (location + binding) the shader needs.  NOTE: there are TWO
//! emission paths in that file - `setup()` (legacy hand-call) and the
//! `installSpirvEntry` wrapper.  Shaders use `installSpirvEntry`, so any
//! decoration change MUST land in the wrapper to reach the SPIR-V; `setup()`
//! alone is dead code.
//!
//! ---- 3. THE BINDING MODEL (read this twice) ---------------------------
//! WebGPU rejects a pipeline where one (group, binding) slot holds
//! different resources across stages.  Because the VS and FS are translated
//! as SEPARATE WGSL modules, each numbering its resources from 0, naive
//! emission COLLIDES (e.g. a VS `mat_model` and an FS `col_diffuse` both at
//! group0/binding1).  zimr avoids this by SEGREGATING bind groups BY STAGE
//! and resource class.  The contract - every wgpu shader and host follows it:
//!
//!     group 0  ->  VS uniforms        (Ubo, or loose VS `Uniforms`)
//!     group 1  ->  samplers           (texture@N, sampler@N+1 pairs)
//!     group 2  ->  FS uniforms        (loose FS `Uniforms`)
//!
//! Bindings run 0,1,2,... within each group in declaration order.  Two stages
//! -> two disjoint uniform groups -> collision is impossible, for any shader.
//! This is enforced in tools/gen_shader_externs.zig (the `installSpirvEntry`
//! wrapper emits `zm.binding(&field, set, bind)` with set = 0 for VS
//! uniforms, 1 for samplers, 2 for FS uniforms) and the `lambert_demo`
//! is the worked multi-group example.  A host building bind-group layouts
//! MUST mirror this grouping.
//!
//! ---- 4. The two host binding paths ------------------------------------
//! (a) Resources(Schema)  [shader_runtime.zig] - the easy path for
//!     SINGLE-UBO, SINGLE-GROUP shaders: one uniform buffer at group 0
//!     binding 0, samplers at group 1.  `Renderer2D` and the unlit
//!     `cube_demo` use it.  LIMITATION: it models exactly ONE ubo
//!     buffer per group at binding 0, so it CANNOT express multi-binding
//!     uniform groups or the section 3 split across three groups.
//! (b) Explicit bind groups by hand - for MULTI-UNIFORM / MULTI-GROUP
//!     shaders (lambert, pbr, the helmet): create one uniform buffer per
//!     loose uniform, build a BindGroupLayout + BindGroup per group via
//!     descriptor_encoder.encodeBindGroupLayoutEntries / encodeBindGroupEntries
//!     + wgpu.createBindGroupLayout / createBindGroup, chain them with
//!     createPipelineLayout, then setBindGroup(0/1/2) each frame.  See
//!     examples/lambert_demo/lambert_demo.zig for the canonical
//!     three-group implementation.
//!
//! ---- 5. Runtime layers (what the re-exports below are) ----------------
//!     wgpu.zig            - ~37 `js_*` externs (the raw WebGPU FFI) +
//!                           packed-struct descriptors (BufferUsage, etc.).
//!     src/bridge.zig- the JS bridge implementing every `js_*`.
//!     GpuFrame            - per-frame lifecycle (surface, depth, queue).
//!     render_pass         - setVertexBuffer/setIndexBuffer/drawIndexed +
//!                           beginRenderPass(.depth_view).
//!     descriptor_encoder  - serializes pipeline/bind-group descriptors to
//!                           the byte blobs the JS side decodes.
//!     pipeline_cache      - StateCombo.fromParts(topology, blend, DEPTH,
//!                           CULL, color_fmt, depth_fmt, samples) keying.
//!     shader_runtime - loadShader, Resources(Schema), RenderPipeline.
//!     gpu_iface           - WgpuBackend (setPipeline/setBindGroup/begin*).
//!     WgpuTexture         - texture+view+sampler bundle.
//!
//! ---- 6. The 3D ladder + standalone ------------------------------------
//! 3D-on-wgpu was proven incrementally: unlit cube (section 4.A, DONE, renders) ->
//! lambert lit cube (section 4.B, this is where the section 3 binding work landed) -> pbr
//! helmet (loadModelFromGltfMemory -> GpuMesh -> vertex/index buffers -> the
//! section 4(b) multi-group path).  Each demo ships a single self-contained HTML
//! via an IN-BUILD step (`zig build wgpu-<name>-standalone`): the
//! `WgpuStandalone` step in build.zig base64-inlines the wasm + inlines the
//! JS into the `wgpu_standalone_template` constant - no Python, no template
//! file.  Add one to a new demo with a single `WgpuStandalone.add(...)` call.
//!
//! ---- 7. Invariants (must hold) ----------------------------------------
//!   * No globals in the draw path - Frame/Draw context is passed explicitly.
//!   * Shipped wasm contains no transpiler; all WGSL is build-time.
//!   * Pure-Zig toolchain on the WGSL path (no spirv-opt/spirv-cross).
//!   * The section 3 group contract (VS uniforms=0, samplers=1, FS uniforms=2) is
//!     stable; host layouts and shader decorations agree on it.
//!   * Validate emitted WGSL with naga (scripts/naga-validate-corpus.sh ir)
//!     - every shader the live build emits must PASS.
//!
//! ============================================================================
//!
//! Re-export surface follows.  Internal modules (descriptor_encoder,
//! shader_introspect, ...) are exposed for advanced users who drop a layer.

pub const wgpu = @import("wgpu.zig");
pub const wgpu_app = @import("wgpu_app.zig");
pub const dom = web.dom;
pub const DateTime = web.dom.DateTime;
pub const localTime = web.dom.localNow;
pub const epochMillis = web.dom.epochMillis;
pub const timezoneOffsetMinutes = web.dom.tz_offset_min;

// Software rasterizer (pure-Zig) + its per-pixel fragment-shader dispatcher, so
// WGPU examples can run the SAME shaderMain on the CPU for side-by-side
// CPU|GPU comparisons (the mandel_sidebyside headline demo). math/colors are the
// shared scalar helpers the shaders + examples use.
pub const raster = @import("raster.zig");
pub const raster_shader = @import("raster_shader.zig");
// The raster renderer-trait adapter - drives the SOFTWARE half of side-by-side
// demos with the SAME `gl: anytype` code the GPU half uses. From its own
// rlgl-free file, so importing it here keeps the WGPU build clean of the GL
// backend. `SwGl` is the conventional name for "the raster `gl`".
pub const SwGl = @import("SwAdapter.zig");

// ---- Backend-agnostic core --------------------------------------------------
// These modules contain zero rendering - they're pure logic/data the whole
// engine shares. Re-exporting them here keeps the public surface on `zimr`
// (the single engine module; the old GL backend is gone). They reach out only
// to `zm` (wired) and each
// other via relative imports (which compile into this module).
pub const types = @import("types.zig");
pub const KeyboardKey = @import("types.zig").KeyboardKey;
// ---- Phase A: high-frequency convergence surface ----------------------------
/// raylib's `colors` namespace == the types module (RED, BLUE, ... constants).
pub const colors = @import("types.zig");
pub const Rectangle = @import("types.zig").Rectangle;
pub const NPatchInfo = @import("types.zig").NPatchInfo;
pub const clearViewport = wgpu_app.clearViewport;
pub const checkCollisionPointRec = wgpu_app.checkCollisionPointRec;
pub const checkCollisionCircleRec = @import("shapes2d.zig").checkCollisionCircleRec;
pub const checkCollisionCircles = @import("shapes2d.zig").checkCollisionCircles;
pub const colorFromHSV = wgpu_app.colorFromHSV;
pub const beginMode2D = wgpu_app.beginMode2D;
pub const BlendMode = wgpu.BlendMode;
pub const beginBlendMode = wgpu_app.beginBlendMode;

/// raylib's `BeginShaderMode` / `EndShaderMode`: a user fragment shader over the ORDINARY 2D
/// batch. Every rect, circle, text and texture drawn between the two is filtered as it
/// rasterizes - this is not a post-process and there is no fullscreen quad. See
/// `src/shader2d.zig`, and `examples/shaders_shapes_textures` for the whole thing in one file.
pub const Shader2D = @import("shader2d.zig").Shader2D;
pub const beginShaderMode = wgpu_app.beginShaderMode;
pub const endShaderMode = wgpu_app.endShaderMode;
pub const endBlendMode = wgpu_app.endBlendMode;
pub const endMode2D = wgpu_app.endMode2D;
pub const beginMode3D = wgpu_app.beginMode3D;
pub const OrbitCamera = wgpu_app.OrbitCamera;
pub const OrbitOptions = wgpu_app.OrbitOptions;
pub const beginMode3DMatrix = wgpu_app.beginMode3DMatrix;
pub const drawTriangle3D = wgpu_app.drawTriangle3D;
pub const endMode3D = wgpu_app.endMode3D;
pub const reopenOverlayPass = wgpu_app.reopenOverlayPass;
pub const restore2DState = wgpu_app.restore2DState;
pub const drawCube = wgpu_app.drawCube;
pub const drawLine3D = wgpu_app.drawLine3D;
pub const drawGrid = wgpu_app.drawGrid;
pub const drawCubeWires = wgpu_app.drawCubeWires;
pub const drawSphere = wgpu_app.drawSphere;
pub const drawSphereWires = wgpu_app.drawSphereWires;
pub const drawCylinder = wgpu_app.drawCylinder;
pub const drawCylinderWires = wgpu_app.drawCylinderWires;
/// Textured-3D: a cube with a texture on each face, and a camera-facing textured
/// quad (billboard) - both depth-tested in the immediate 3D pass.
pub const drawCubeTexture = wgpu_app.drawCubeTexture;
pub const drawBillboard = wgpu_app.drawBillboard;
pub const drawBillboardRec = wgpu_app.drawBillboardRec;
// Textured triangles stay here (not in draw2d): the path runs through the 3D
// pipeline - world-space [3]f32, depth buffer, wrapped in beginMode3D. Every other
// 2D texture/shape/spline draw is now a draw2d sink method (gl.texture / gl.image /
// gl.spline*), so this is the only texture draw left as an rlgl free function.
pub const drawTexturedTriangles = wgpu_app.drawTexturedTriangles;
pub const uploadDecalReceiver = wgpu_app.uploadDecalReceiver;
pub const drawDecal = wgpu_app.drawDecal;
pub const DecalDesc = wgpu_app.DecalDesc;
/// Gradient skybox: a fullscreen far-plane pass. z.drawSkybox(f.gl, cam, bottom, top).
pub const drawSkybox = wgpu_app.drawSkybox;
pub const drawPlane = wgpu_app.drawPlane;
pub const CubeDesc = wgpu_app.CubeDesc;
pub const SphereDesc = wgpu_app.SphereDesc;
pub const CylinderDesc = wgpu_app.CylinderDesc;
pub const PlaneDesc = wgpu_app.PlaneDesc;
pub const CameraMode = wgpu_app.CameraMode;
pub const updateCamera = wgpu_app.updateCamera;
pub const drawCylinderBetween = wgpu_app.drawCylinderBetween;
pub const drawCapsule = wgpu_app.drawCapsule;
pub const drawBoundingBox = wgpu_app.drawBoundingBox;
pub const getSphereBoundingBox = wgpu_app.getSphereBoundingBox;
pub const getCylinderBoundingBox = wgpu_app.getCylinderBoundingBox;
pub const getCapsuleBoundingBox = wgpu_app.getCapsuleBoundingBox;
pub const BoundingBox = wgpu_app.BoundingBox;
pub const Mesh = wgpu_app.Mesh;
pub const Model = wgpu_app.Model;
pub const genMeshCube = wgpu_app.genMeshCube;
pub const genMeshTangents = wgpu_app.genMeshTangents;
// New parametric-spine shape generators (reclaim the freed genMesh* names).
/// BVH skeletal animation: `bvh.Data` -> `ModelSkeleton` + `ModelAnimation`, plus forward
/// kinematics. Exposed as a namespace rather than flattened because the three verbs are only
/// meaningful together - and `unloadBvhSkeletalClip` must never be confused with `unloadModel`.
pub const draw3d = struct {
    pub const BvhSkeletalClip = @import("draw3d.zig").BvhSkeletalClip;
    pub const loadBvhSkeletalClip = @import("draw3d.zig").loadBvhSkeletalClip;
    pub const unloadBvhSkeletalClip = @import("draw3d.zig").unloadBvhSkeletalClip;
    pub const bvhForwardKinematics = @import("draw3d.zig").bvhForwardKinematics;

    /// FBX -> a skinned `Model` plus its skeleton and clip, in one call. See `loadFbxModel`
    /// for why assembling these together is the point rather than a convenience.
    pub const FbxModel = @import("draw3d.zig").FbxModel;
    pub const LoadFbxModelOptions = @import("draw3d.zig").LoadFbxModelOptions;
    pub const loadFbxModel = @import("draw3d.zig").loadFbxModel;
    pub const unloadFbxModel = @import("draw3d.zig").unloadFbxModel;
    pub const computeMeshNormals = @import("draw3d.zig").computeMeshNormals;
    pub const scaleBvhSkeletalClip = @import("draw3d.zig").scaleBvhSkeletalClip;
    pub const bvhForwardKinematicsFromRotations = @import("draw3d.zig").bvhForwardKinematicsFromRotations;
    pub const fbxBindOrientations = @import("draw3d.zig").fbxBindOrientations;

    /// CPU skinning, with zm's two easily-inverted conventions handled in one place. Use these
    /// rather than hand-rolling the matrix math - see `poseSkinMatrices`' doc.
    pub const poseSkinMatrices = @import("draw3d.zig").poseSkinMatrices;
    pub const skinMeshCpu = @import("draw3d.zig").skinMeshCpu;
};
pub const parametricMesh = @import("draw3d.zig").parametricMesh;
pub const ParametricFn = @import("draw3d.zig").ParametricFn;
pub const genMeshSphere = @import("draw3d.zig").genMeshSphere;
pub const genMeshHemiSphere = @import("draw3d.zig").genMeshHemiSphere;
pub const genMeshCylinder = @import("draw3d.zig").genMeshCylinder;
pub const genMeshCone = @import("draw3d.zig").genMeshCone;
pub const genMeshTorus = @import("draw3d.zig").genMeshTorus;
pub const genMeshKnot = @import("draw3d.zig").genMeshKnot;
pub const genMeshPlane = @import("draw3d.zig").genMeshPlane;
pub const genMeshKlein = @import("draw3d.zig").genMeshKlein;
// Platonic solids (flat-shaded).
pub const genMeshTetrahedron = @import("draw3d.zig").genMeshTetrahedron;
pub const genMeshOctahedron = @import("draw3d.zig").genMeshOctahedron;
pub const genMeshIcosahedron = @import("draw3d.zig").genMeshIcosahedron;
pub const genMeshDodecahedron = @import("draw3d.zig").genMeshDodecahedron;
pub const genMeshIcosphere = @import("draw3d.zig").genMeshIcosphere;
pub const genMeshRock = @import("draw3d.zig").genMeshRock;
pub const serialize = @import("serialize.zig");
// Mesh-ops toolkit (compose + edit any types.Mesh).
pub const meshMerge = @import("draw3d.zig").meshMerge;
pub const meshTranslate = @import("draw3d.zig").meshTranslate;
pub const meshScale = @import("draw3d.zig").meshScale;
pub const meshRotate = @import("draw3d.zig").meshRotate;
pub const meshInvert = @import("draw3d.zig").meshInvert;
pub const meshComputeAabb = @import("draw3d.zig").meshComputeAabb;
pub const meshClone = @import("draw3d.zig").meshClone;
pub const meshUnweld = @import("draw3d.zig").meshUnweld;
pub const meshWeld = @import("draw3d.zig").meshWeld;
pub const meshRemoveDegenerate = @import("draw3d.zig").meshRemoveDegenerate;
pub const genMeshDisk = @import("draw3d.zig").genMeshDisk;
pub const unloadMesh = @import("draw3d.zig").unloadMesh;
pub const unloadModel = @import("draw3d.zig").unloadModel;
pub const getScreenToWorldRay = @import("draw3d.zig").getScreenToWorldRay;
pub const getRayCollisionSphere = @import("draw3d.zig").getRayCollisionSphere;
pub const getRayCollisionBox = @import("draw3d.zig").getRayCollisionBox;
pub const getRayCollisionTriangle = @import("draw3d.zig").getRayCollisionTriangle;
pub const getRayCollisionQuad = @import("draw3d.zig").getRayCollisionQuad;
pub const getRayCollisionMesh = @import("draw3d.zig").getRayCollisionMesh;
pub const checkCollisionSpheres = @import("draw3d.zig").checkCollisionSpheres;
pub const checkCollisionBoxes = @import("draw3d.zig").checkCollisionBoxes;
pub const checkCollisionBoxSphere = @import("draw3d.zig").checkCollisionBoxSphere;
pub const uploadMesh = wgpu_app.uploadMesh;
pub const updateMeshBuffer = wgpu_app.updateMeshBuffer;
pub const genMeshHeightmap = @import("draw3d.zig").genMeshHeightmap;
pub const genMeshCubicmap = @import("draw3d.zig").genMeshCubicmap;
pub const loadModelFromMesh = wgpu_app.loadModelFromMesh;
pub const drawModel = wgpu_app.drawModel;
pub const drawModel3D = wgpu_app.drawModel3D;
pub const drawModelWires = wgpu_app.drawModelWires;
pub const drawMeshInstanced = wgpu_app.drawMeshInstanced;

// ---- images + textures ------------------------------------------------------
/// CPU-side image (raylib Image): `data` + width/height/format. Decode with
/// loadImageFromMemory; upload to the GPU with loadTextureFromImage.
pub const Image = @import("types.zig").Image;
pub const PixelFormat = @import("types.zig").PixelFormat;
/// Decode PNG bytes into an Image (CPU only - no GPU). Agnostic (codecs).
pub const loadImageFromMemory = wgpu_app.loadImageFromMemory;
/// A decoded GIF animation (raylib's `LoadImageAnim`): N fully-composited
/// RGBA8 canvases (one per frame) + each frame's delay in ms. Frame `i` is
/// `anim.frame(i)`; release with `anim.deinit(gpa)`. Play by uploading the
/// current frame into a `CpuFramebuffer` each time it changes.
pub const GifAnim = codecs.gif.Anim;
/// Decode animated (or single-frame) GIF bytes into a `GifAnim`. CPU only -
/// no GPU. The frames are already composited (disposal + transparency
/// applied), so a player just blits `anim.frame(i)`.
pub fn loadGifAnim(gpa: std.mem.Allocator, bytes: []const u8) codecs.gif.Error!GifAnim {
    return codecs.gif.decode(gpa, bytes);
}
/// Procedural CPU image generation (backend-agnostic; src/image.zig). Each
/// returns an Image to upload with loadTextureFromImage. genImageWhiteNoise
/// takes an `rng` (e.g. `z.rng.Seeded.init(seed).rng()`).
const image = @import("image.zig");
pub const genImageColor = image.genImageColor;
pub const genImageChecked = image.genImageChecked;
pub const genImageWhiteNoise = image.genImageWhiteNoise;
pub const genImagePerlinNoise = image.genImagePerlinNoise;
pub const genImageCellular = image.genImageCellular;
/// CPU image manipulation (backend-agnostic; src/image.zig). In-place / copy
/// ops on RGBA8 Images; pair with updateTexture to push edits to the GPU.
pub const imageColorInvert = image.imageColorInvert;
pub const imageCopy = image.imageCopy;
pub const imageRotateCW = image.imageRotateCW;
pub const imageRotate = image.imageRotate;
pub const imageResize = image.imageResize;
pub const imageFromChannel = image.imageFromChannel;
pub const imageFormat = image.imageFormat;
pub const imageAlphaMask = image.imageAlphaMask;
pub const imageRotateCCW = image.imageRotateCCW;
pub const imageBlurGaussian = image.imageBlurGaussian;
pub const unloadImage = image.unloadImage;
/// Reproducible RNG (`rng.Seeded.init(seed)`), re-exported from the runtime.
pub const rng = @import("runtime.zig").effects.rng;

// ---- Audio (Web Audio; backend-agnostic, shared with the GL path) ----
// Call `z.audio_device.init(f.audio_device)` once (that's what reaches the
// `extern "audio"` JS bridge), then synthesize with z.composer / z.waves and
// play via z.sounds. Keep an AudioState on your app State for the pools.
pub const audio_device = sound.audio_device;
pub const waves = sound.waves;
pub const sounds = sound.sounds;
pub const composer = sound.composer;
pub const analyser = sound.analyser;
pub const AudioState = sound.AudioState;
pub const Sound = @import("types.zig").Sound;
pub const Wave = @import("types.zig").Wave;
/// AudioStream: gapless real-time PCM streaming (3-buffer rotation scheduled
/// via playBufferAt). `z.streams.load/update/isProcessed/...`.
pub const AudioStream = @import("types.zig").AudioStream;
pub const streams = sound.streams;
/// Music: streamed/decoded playback (OGG via the bridge's async decodeAudioData),
/// looping + seek + position. `z.music.loadFromMemory/play/update/isReady/...`.
pub const Music = @import("types.zig").Music;
pub const music = sound.music;
/// S4: canonical impl lives in wgpu_app; the umbrella re-exports.
pub const loadTextureFromImage = wgpu_app.loadTextureFromImage;
/// Re-upload an Image into an existing texture in place (raylib UpdateTexture).
pub const updateTexture = wgpu_app.updateTexture;
pub const easings = @import("easings.zig");
// ---- easing fns (flat re-exports, like GL zimr) ----
pub const easeLinear = easings.linear;
pub const easeSineIn = easings.sineIn;
pub const easeSineOut = easings.sineOut;
pub const easeSineInOut = easings.sineInOut;
pub const easeCircIn = easings.circIn;
pub const easeCircOut = easings.circOut;
pub const easeCircInOut = easings.circInOut;
pub const easeQuadIn = easings.quadIn;
pub const easeQuadOut = easings.quadOut;
pub const easeQuadInOut = easings.quadInOut;
pub const easeCubicIn = easings.cubicIn;
pub const easeCubicOut = easings.cubicOut;
pub const easeCubicInOut = easings.cubicInOut;
pub const easeExpoIn = easings.expoIn;
pub const easeExpoOut = easings.expoOut;
pub const easeExpoInOut = easings.expoInOut;
pub const easeBackIn = easings.backIn;
pub const easeBackOut = easings.backOut;
pub const easeBackInOut = easings.backInOut;
pub const easeBounceOut = easings.bounceOut;
pub const easeBounceIn = easings.bounceIn;
pub const easeBounceInOut = easings.bounceInOut;
pub const easeElasticIn = easings.elasticIn;
pub const easeElasticOut = easings.elasticOut;
pub const easeElasticInOut = easings.elasticInOut;

pub const entities = @import("entities.zig");
pub const ecs = @import("entities.zig");
pub const zimrphysics = @import("zimrphysics.zig");
pub const zimrphysics2d = @import("zimrphysics2d.zig");
/// Reduced-coordinate articulated-body dynamics, in the style of MuJoCo. Complements
/// zimrphysics: that one is for many loose bodies, this one is for machines with joints.
pub const robot = @import("robot.zig");
/// The seam between `robot` and `zimrphysics`: kinematic proxies out, contacts back.
/// A separate module from `robot` on purpose - robot.zig depends only on zimrmath, so a
/// headless rollout or a batched GPU job does not drag a collision engine along with it.
pub const robot_physics = @import("robot_physics.zig");
/// Compose a robot spec with free bodies - and with other robots - into ONE `robot.Model`.
///
/// The answer to bidirectional coupling (section 4k): a contact between an arm and a crate is one
/// constraint between two inertias, and resolving it in two engines is not an approximation
/// of resolving it once. Put the crate in the tree and there is nothing to couple.
pub const robot_scene = @import("robot_scene.zig");
/// Read MuJoCo's own model format - the one Menagerie's robots are written in.
pub const mjcf = @import("mjcf.zig");
/// Turn a parsed MJCF robot into a simulable `robot.Model`.
pub const robot_mjcf = @import("robot_mjcf.zig");
/// The same robot model rebuilt in maximal coordinates (zimrphysics bodies + joints) - for
/// comparing the two engines on one model. See `src/notes/ragdoll_compare_plan.md`.
pub const robot_maximal = @import("robot_maximal.zig");
pub const robot_gym = @import("robot_gym.zig");
// The motion-tracking stack, in dependency order: clips and retargeting, the tracking task and
// its fleet, the residual policy's observation and controller, and the PPO trainer on the kit.
pub const robot_dance = @import("robot_dance.zig");
pub const robot_track = @import("robot_track.zig");
pub const robot_policy = @import("robot_policy.zig");
pub const robot_ppo_track = @import("robot_ppo_track.zig");
/// The latent world model and its normaliser - a page needs the normaliser to build a learner.
pub const robot_latent = @import("robot_latent.zig");
/// Geno's collision shapes, as `tools/geno_fit.py` fits them (generated; the robot model and the
/// `geno_fit` page both read this one table).
pub const robot_geno_shapes = @import("robot_geno_shapes.zig");
/// A robot built from the character its captures were recorded on (rl_track_plan.md, Phase R).
pub const robot_geno = @import("robot_geno.zig");
/// Geno's robot model as `robot_geno.writeModel` makes it - a fixture its tests hold byte-equal to a fresh
/// build, so pages load the body without re-measuring it.
pub const robot_geno_model: []const u8 = @embedFile("tests/fixtures/robot/geno.xml");
/// The networks and the resident data on the GPU: blocks, the feature ring, the reference tables.
pub const robot_latent_kit = @import("robot_latent_kit.zig");
/// SuperTrack's loop with the data and both networks resident on the GPU - what the training page runs.
pub const robot_track_resident = @import("robot_track_resident.zig");
/// SuperTrack (a supervised world model + a policy through it) and its kit driver.
pub const robot_supertrack = @import("robot_supertrack.zig");
/// Pose holding and inverse kinematics - the control layer every demo needs.
pub const robot_control = @import("robot_control.zig");
pub const robot_mpc = @import("robot_mpc.zig");
pub const physics_common = @import("physics_common.zig");

// Enforce the cross-engine API contract at compile time: the 2D and 3D physics engines
// must keep their shared, dimension-independent surface parallel (and share enum types).
comptime {
    physics_common.assertParallelEngines(zimrphysics2d, zimrphysics);
}
pub const sound = @import("sound.zig");
pub const web = @import("web.zig");
pub const net = @import("net.zig");

// ---- std.log -> on-page console (the proper logging fix) -------------------
//
// The on-page console panel is driven by `dom.js_log`. Plain `std.log.{info,
// warn,err}` does NOT reach it unless the ROOT module wires a logFn - otherwise
// example logging silently vanishes (and people resort to ad-hoc `pageLog`
// helpers). Re-export `std_options` from an example's root and all std.log
// "just works" on-page:
//
//     const z = @import("zimr");
//     pub const std_options = z.std_options;
//
// Each line is formatted with its scope/level prefix and routed through
// web.dom.log (which targets js_log on wasm, stderr on host).
fn zimrLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime fmt: []const u8,
    args: anytype,
) void {
    // lint:off import-at-top: logFn callback; module has no file-scope std
    const dom_level: web.dom.LogLevel = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    const prefix: []const u8 = if (scope == .default) "" else "(" ++ @tagName(scope) ++ ") ";
    // A generous buffer: assert failures and the memwatch per-frame-leak warning
    // both run long, and the diagnostic the reader needs is usually the HEAD of
    // the message. So on overflow we KEEP the leading bytes that fit and append a
    // short marker - never collapse the whole line to an opaque placeholder (an
    // earlier version replaced it with "(log message exceeded N bytes)", which
    // hid exactly the text being debugged). Zero-init so the truncation path can
    // find where real content ends (log text never contains a NUL).
    var buf: [16384]u8 = @splat(0);
    const marker: []const u8 = " [...truncated]";
    const msg: []const u8 = bufPrint(buf[0 .. buf.len - marker.len], prefix ++ fmt, args) catch trunc: {
        const cut: usize = std.mem.indexOfScalar(u8, buf[0 .. buf.len - marker.len], 0) orelse (buf.len - marker.len);
        @memcpy(buf[cut .. cut + marker.len], marker);
        break :trunc buf[0 .. cut + marker.len];
    };
    web.dom.log(dom_level, msg);
}

/// Root-module std options that route std.log to the on-page console.
/// `pub const std_options = z.std_options;` in your example's main file.
pub const std_options: std.Options = .{ .logFn = zimrLogFn };
pub const utils = @import("utils.zig");

/// The integrated, in-process profiler (Tracy-inspired). Comptime-gated by
/// `-Dmode` - live for debug/release, stripped in ship. See src/profiler.zig.
pub const profiler = @import("profiler.zig");

/// App-callable profiler views (flamegraph, etc.) built on ui.zig. The app
/// owns its own button/pause and calls these inside its UI. See profiler_ui.zig.
pub const profiler_ui = @import("profiler_ui.zig");

// Core lifecycle types
pub const GpuFrame = gpu.GpuFrame;
pub const PipelineCache = gpu.PipelineCache;
pub const BindGroupCache = @import("BindGroupCache.zig");

// Drawing layer
pub const Renderer2D = @import("renderer_2d.zig").Renderer2D;
pub const buildMaterialBindGroup = @import("renderer_2d.zig").buildMaterialBindGroup;
pub const orthoTopLeft = @import("renderer_2d.zig").orthoTopLeft;
pub const PerFrameUbo = @import("renderer_2d.zig").PerFrameUbo;

// Textures
pub const WgpuTexture = @import("wgpu_texture.zig").WgpuTexture;
pub const Texture = @import("types.zig").Texture;
pub const Sprite = @import("Sprite.zig");
// PORT IN PROGRESS: the real ImGui (ui.zig) compiled for the wgpu backend.
pub const ui_real = @import("ui.zig");
/// Plotting (ImPlot-style). `plot` is the zm-only rendering core (axis
/// transform, nice ticks, line/scatter/bars over a duck-typed sink);
/// `plot_ui` is the in-engine adapter - `DrawListSink` + the interactive
/// `show` widget (pan/zoom/fit). Example authors reach `z.plot_ui.show(...)`.
pub const plot = @import("plot.zig");
pub const plot_ui = @import("plot_ui.zig");

/// 3D plotting (a pure-Zig ImPlot3D port: CPU projection + painter's-algorithm
/// triangle batch over `ui.zig`). `plot_core` is the color/colormap/tick
/// machinery shared with the 2D side. See `src/notes/plot3d.md`.
pub const plot3d = @import("plot3d.zig");
pub const plot_core = @import("plot_core.zig");

/// Pure-Zig, native, anti-aliased 2D canvas -> PNG (no GPU, no third party).
/// Also a drop-in `plot` sink. See `examples/native_plot_png`.
pub const Canvas = @import("Canvas.zig");
/// Host that drives the REAL ImGui (ui.zig) on wgpu: z.UiHost.init(gpa, font)
/// on State, then host.begin(f) -> Ui (widgets) -> host.render(f) before
/// endDrawing.
pub const UiHost = wgpu_app.UiHost;
/// The full immediate-mode UI namespace (UiContext, Ui, widgets, ids,
/// state storage).  Example authors reach `z.ui.X`; UiHost is the
/// frame-bridge, this is the API surface (GL-retirement P5a: the live
/// umbrella inherits the re-export the GL one had).
pub const ui = @import("ui.zig");
/// Comptime feature flags + the todo() marker (re-exports of utils.*),
/// at the public paths example authors use.
pub const features = utils.features;
pub const todo = utils.todo;
pub const CpuFramebuffer = wgpu_app.CpuFramebuffer;
pub const WgpuRenderTexture = @import("wgpu_texture.zig").WgpuRenderTexture;

// GPU trait
pub const WgpuBackend = @import("gpu_iface.zig").WgpuBackend;
pub const uniformColor = @import("gpu_iface.zig").uniformColor;
pub const SwBackend = @import("gpu_iface.zig").SwBackend;
pub const PassState = @import("gpu_iface.zig").PassState;
pub const FrameContext = @import("gpu_iface.zig").FrameContext;
/// The default 2D vertex (`pos: vec2, uv: vec2, color: u8x4_unorm`) - the
/// layout `loadShader` builds its pipelines with. Exported so an app that owns
/// its own vertex buffer (a fullscreen triangle drawn through a shader's own
/// pipeline rather than the 2D shapes batch) can spell the type it uploads.
pub const Vertex2D = @import("gpu_iface.zig").Vertex2D;

// Shader loading.  `shader_compile.zig` (runtime SPIR-V->WGSL) is
// NOT re-exposed at this surface as of Phase D1 of the wgpu plan
// - build-time spv2wgsl is the only path.  See
// `src/notes/webgpu-migration-plan.md` section 3 Phase D.
pub const shader = @import("shader_runtime_wgpu.zig");

// Render / compute passes
pub const render_pass = wgpu.render_pass;
pub const compute_pass = wgpu.compute_pass;

// Internals for advanced users (typically not needed).
// `spv2wgsl.zig` is BUILD-TIME ONLY (Phase D1 of the wgpu plan);
// it's still loaded into the test block below so its tests run,
// but it's not re-exposed as a runtime API surface.
pub const gpu = @import("gpu.zig");
pub const shader_introspect = @import("shader_introspect.zig");

// Custom-pipeline API - complete WebGPU control (raw WGSL or Zig shaders, custom
// vertex layouts, explicit state) that composes with the immediate-mode renderer.
// See src/material.zig and src/notes/webgpu_control.md.
pub const material = @import("material.zig");
pub const Pipeline = material.Pipeline;
pub const PipelineOptions = material.PipelineOptions;
pub const ComputePipeline = material.ComputePipeline;
pub const VertexLayout = material.VertexBufferLayout;
pub const VertexAttr = material.VertexAttribute;

/// `z.Compute(M)` - run a kompute kernel module on the CPU or GPU (runtime toggle).
pub const Compute = @import("compute_host.zig").Compute;

/// The jobs `Registry` for a kompute module - DERIVED, so an example that wants the
/// `.worker` backend configures nothing. The kernel functions, the header type and the
/// exact input/output bounds all fall out of what the module already declares.
pub const komputeRegistry = @import("compute_host.zig").komputeRegistry;
/// The kernel table for a kompute module, exposed so registries can COMPOSE (the launcher
/// merges many examples into one kernel wasm by concatenating tables).
pub const komputeTable = @import("compute_host.zig").komputeTable;
/// The job-kernel wrapper for ONE kernel of a kompute module: the same `while` loop over ids
/// that the `.cpu` backend runs, packaged as a `jobs` kernel. Exposed so a page that merges
/// several examples' kernels (the launcher) can name one directly.
pub const komputeKernel = @import("compute_host.zig").komputeKernel;

/// `z.DrawPoints` - zero-copy instanced rendering of points from a GPU storage buffer.
pub const DrawPoints = @import("draw3d.zig").draw_points.DrawPoints;
/// `z.FluidDiscs` - instanced SDF discs for pixel-space particle fields
/// (zero-copy from a compute storage buffer; density-driven colour).
pub const FluidDiscs = @import("draw3d.zig").draw_points.FluidDiscs;
/// `z.BufRegion` - a buffer region (handle/offset/size) for renderer bindings.
pub const BufRegion = @import("draw3d.zig").draw_points.BufRegion;
pub const FluidDiscOptions = @import("draw3d.zig").draw_points.FluidOptions;
pub const StorageBuffer = wgpu.storage_buffer.StorageBuffer;

// Asset codecs (glTF parsing + JPEG/PNG decode), re-exported so wgpu
// consumers can load models/textures.  Lives in this module (rather than a
// separate one) because `raster` already pulls `types.zig` into the zimr
// module, and a file may belong to only one module - sharing it here avoids
// a one-file-per-module conflict.  Only pure functions get analyzed unless
// the GL/dom paths are referenced.
pub const codecs = @import("codecs.zig");

/// Run a PURE kernel off the main thread (a Web Worker), so a long job stops
/// freezing the frame. `codecs.png.encode` of a 1024x1024 image is ~240 ms in wasm on
/// a phone: on the main thread that is a 233 ms frozen frame, on a worker it is a
/// 17 ms worst frame gap. The job is not faster - it is ELSEWHERE.
///
/// See `src/jobs.zig`. Kernels live in their own file so the build can compile them
/// into a separate, freestanding, ZERO-IMPORT wasm that workers instantiate.
pub const jobs = @import("jobs.zig");

// A small reusable PBR 3D renderer (pipeline + glTF model loader + draw loop),
// generalized from the DamagedHelmet demo.  Lives in this module so it can
// import the wgpu primitives, codecs, and zm directly.
pub const pbr3d = @import("draw3d.zig").pbr3d;

/// The PBR shader PAIR as callable Zig - the same `src/shaders/pbr_vs.zig`
/// + `pbr_fs.zig` files the build compiles to SPIR-V -> WGSL for the GPU,
/// importable here so the software rasterizer can run `shaderMain` per
/// vertex / per fragment.  The one-source-two-renderers seam of the
/// helmet side-by-side (`examples/helmet_sw`).  Analyzed lazily:
/// apps that never reference it don't pull the shader bodies or their
/// generated `*_externs` modules into the wasm.
pub const pbr_shaders = struct {
    pub const vs = @import("shaders/pbr_vs.zig");
    pub const fs = @import("shaders/pbr_fs.zig");
};

/// The shader-projected DECAL shader pair as callable Zig - the same
/// `src/shaders/decal_vs.zig` + `decal_fs.zig` the build compiles to
/// SPIR-V -> WGSL for the GPU, importable here so the software rasterizer can
/// run `shaderMain` per vertex / per fragment. The one-source-two-renderers
/// seam of the decal side-by-side (`examples/decal_sw`): the projector-box
/// math (world -> box space, the inside/facing masks) runs bit-identically on
/// hardware and in software. Analyzed lazily like `pbr_shaders`.
pub const decal_shaders = struct {
    pub const vs = @import("shaders/decal_vs.zig");
    pub const fs = @import("shaders/decal_fs.zig");
};

/// The fixed-function 2D shape shader pair driving immediate-mode
/// drawing (`gl.begin`/`vertex`/`color`).  Exposed so a CPU side-by-side
/// can route its raster immediate-mode triangles through the SAME shader +
/// `raster_shader.rasterizeTriangles` the GPU side runs - one rasteriser,
/// no drift.  Analyzed lazily like `pbr_shaders`: apps that never
/// reference it don't pull the shader bodies or `*_externs` into the wasm.
pub const default_shapes = struct {
    pub const vs = @import("shaders/default_shapes_vs.zig");
    pub const fs = @import("shaders/default_shapes_fs.zig");
};

/// The SHADOW-MAP shader QUARTET as callable Zig - the same
/// `src/shaders/depth_vs/fs.zig` + `lit_shadow_vs/fs.zig` files the build
/// compiles to SPIR-V -> WGSL for the GPU, importable here so the software
/// rasterizer (and the COMPILER, at comptime) can run the same `shaderMain`s.
/// The one-source-three-renderers seam of the shadow-map side-by-side
/// (`examples/shadowmap_sw`).  Analyzed lazily like `pbr_shaders`.
/// The deferred-rendering shader quartet: the MRT G-buffer writer pair +
/// the fullscreen lighting pair.  Same one-source-many-executors deal as
/// shadow_shaders; analyzed lazily.
pub const deferred_shaders = struct {
    pub const gbuffer_vs = @import("shaders/gbuffer_vs.zig");
    pub const gbuffer_fs = @import("shaders/gbuffer_fs.zig");
    pub const shading_vs = @import("shaders/deferred_shading_vs.zig");
    pub const shading_fs = @import("shaders/deferred_shading_fs.zig");
};

/// The distance-fog fragment material (vertex stage = gbuffer_vs, reused).
pub const fog_shader = @import("shaders/fog_fs.zig");

/// The toon pair: banded-Lambert fragment material (vertex stage =
/// gbuffer_vs) + the inverted-hull outline vertex shader (fragment
/// stage = depth_fs's color passthrough).
/// The 2D fragment-effect family (vertex stage = deferred_shading_vs's
/// fullscreen quad, reused): raylib's post-style texture shaders.
/// The 2D fullscreen fragment-effect RUNNER - raylib's BeginShaderMode /
/// EndShaderMode for post-process shaders. Pairs with `effect_shaders` (the
/// shader bodies) below.
pub const effects2d = @import("effects2d.zig");

pub const effect_shaders = struct {
    pub const grade_fs = @import("shaders/effect_grade_fs.zig");
    pub const wave_fs = @import("shaders/effect_wave_fs.zig");
    pub const outline_fs = @import("shaders/effect_outline_fs.zig");
    pub const palette_fs = @import("shaders/effect_palette_fs.zig");
    pub const spotlight_fs = @import("shaders/effect_spotlight_fs.zig");
    pub const tiling_fs = @import("shaders/effect_tiling_fs.zig");
    pub const sieve_fs = @import("shaders/effect_sieve_fs.zig");
    pub const ascii_fs = @import("shaders/effect_ascii_fs.zig");
    pub const mask_fs = @import("shaders/effect_mask_fs.zig");
    pub const cubes_fs = @import("shaders/effect_cubes_fs.zig");
};

/// The manual-depth forward material (vertex stage = gbuffer_vs) - the
/// engine's first frag_depth-writing fragment shader.
pub const depth_write_shader = @import("shaders/depth_write_fs.zig");

/// `terrain_fs` - height-banded terrain material (vertex stage =
/// gbuffer_vs); behind the heightmap example.
pub const terrain_shader = @import("shaders/terrain_fs.zig");

/// `maze_fs` - face-shaded material (vertex stage = gbuffer_vs); behind
/// the cubicmap example (color by world-normal orientation).
pub const maze_shader = @import("shaders/maze_fs.zig");

/// `points3d_vs` - unlit point-cloud vertex stage (pairs with `cube3d_fs`);
/// behind the point_rendering example's single point_list draw.
pub const points3d_shader = @import("shaders/points3d_vs.zig");

/// The sphere-traced SDF scene with true frag_depth output - the marcher
/// behind the hybrid raster+raymarch example (fullscreen quad VS =
/// deferred_shading_vs, reused).
pub const hybrid_raymarch_shader = @import("shaders/hybrid_raymarch_fs.zig");

pub const toon_shaders = struct {
    pub const cel_fs = @import("shaders/cel_fs.zig");
    pub const outline_hull_vs = @import("shaders/outline_hull_vs.zig");
};

pub const shadow_shaders = struct {
    pub const depth_vs = @import("shaders/depth_vs.zig");
    pub const depth_fs = @import("shaders/depth_fs.zig");
    pub const lit_vs = @import("shaders/lit_shadow_vs.zig");
    pub const lit_fs = @import("shaders/lit_shadow_fs.zig");
};

/// Build an FS-`Io`-from-VS-`Out` connector by matching field names -
/// the `connect` argument `raster_shader.rasterizeTriangles` expects.  Used
/// by native rasterisation bridges that feed a VS `Out` to an FS `Io`.
pub const autoConnect = @import("shader_connect.zig").autoConnect;

// The WebGPU run-loop: `z.App` + `z.Frame` give a WebGPU example the same shape
// as a GL example (`App.run(cfg, State, initState, update)` +
// `fn update(f: *Frame, s: *State)`). See src/wgpu_app.zig. The `update` export
// the JS RAF loop calls lives there too (pulled in by referencing the module).
pub const App = wgpu_app.App;
pub const Frame = wgpu_app.Frame;
pub const Config = wgpu_app.Config;
pub const ScaleMode = wgpu_app.ScaleMode;
// 2D drawing API (free functions taking f.gl), mirroring the GL path's shape.
pub const beginDrawing = wgpu_app.beginDrawing;
pub const clearBackground = wgpu_app.clearBackground;
pub const endDrawing = wgpu_app.endDrawing;
pub const rlBegin = wgpu_app.rlBegin;
pub const rlEnd = wgpu_app.rlEnd;
pub const rlVertex2f = wgpu_app.rlVertex2f;
pub const rlColor4ub = wgpu_app.rlColor4ub;
pub const rlTexCoord2f = wgpu_app.rlTexCoord2f;
pub const rlSetTexture = wgpu_app.rlSetTexture;

/// Offscreen render target (raylib RenderTexture). Draw into it between
/// beginTextureMode/endTextureMode; display via drawTextureRec(rt.asTexture(), ...).
pub const RenderTexture = @import("wgpu_texture.zig").WgpuRenderTexture;
pub const loadRenderTexture = wgpu_app.loadRenderTexture;
pub const loadRenderTextureEx = wgpu_app.loadRenderTextureEx;
pub const loadRenderTextureDepthTex = wgpu_app.loadRenderTextureDepthTex;
pub const unloadRenderTexture = wgpu_app.unloadRenderTexture;
pub const updateMeshGpu = wgpu_app.updateMeshGpu;
pub const skeletonToModel = robot.skeletonToModel;
pub const poseFromLocalRotations = robot.poseFromLocalRotations;
pub const fitLocalRotations = robot.fitLocalRotations;
pub const fitBodyRotation = robot.fitBodyRotation;
pub const jacBody = robot.jacBody;
pub const ikStep = robot.ikStep;
pub const IkTask = robot.IkTask;
pub const IkOptions = robot.IkOptions;
pub const ikScratchSize = robot.ikScratchSize;
pub const computeTwistOffset = robot.computeTwistOffset;
pub const applyTwist = robot.applyTwist;
pub const computeTwistChainOffsets = robot.computeTwistChainOffsets;
pub const poseFromRetarget = robot.poseFromRetarget;
pub const PointSample = robot.PointSample;
pub const PointCloudOptions = robot.PointCloudOptions;
pub const SampleBuildInputs = robot.SampleBuildInputs;
pub const buildPointSamples = robot.buildPointSamples;
pub const solvePointCloud = robot.solvePointCloud;
pub const captureScale = robot.captureScale;
pub const CaptureFrame = robot.CaptureFrame;
pub const solveTwoBoneLimb = robot.solveTwoBoneLimb;
pub const hingeAngleForFlexion = robot.hingeAngleForFlexion;
pub const rotationBetweenDirectionPairs = robot.rotationBetweenDirectionPairs;
pub const maximumFlexion = robot.maximumFlexion;
pub const TwoBoneSolution = robot.TwoBoneSolution;
pub const RetargetPose = robot.RetargetPose;
pub const SkeletonToModelOptions = robot.SkeletonToModelOptions;
pub const meshGpuBuffers = wgpu_app.meshGpuBuffers;
pub const uploadMeshGpu = wgpu_app.uploadMeshGpu;
pub const MeshGpu = @import("draw3d.zig").MeshGpu;
pub const registerTexture = wgpu_app.registerTexture;
pub const setTextureFilter = wgpu_app.setTextureFilter;
pub const TextureFilter = wgpu_app.TextureFilter;
pub const beginTextureMode = wgpu_app.beginTextureMode;
pub const beginTextureModeRaw = wgpu_app.beginTextureModeRaw;
pub const beginTextureModeMrtRaw = wgpu_app.beginTextureModeMrtRaw;
pub const endTextureModeRaw = wgpu_app.endTextureModeRaw;
pub const endTextureMode = wgpu_app.endTextureMode;
// Text API (N5f) - bake/upload a font, draw + measure via the reusable layout.
pub const Font = wgpu_app.Font;
pub const loadFont = wgpu_app.loadFont;
pub const loadFontEx = wgpu_app.loadFontEx;
/// raylib `LoadFontData(..., FONT_SDF, ...)` - bake a font as a signed distance
/// field (crisp when magnified). Draw inside `beginShaderMode(sdf_shader)`.
pub const loadFontSdf = wgpu_app.loadFontSdf;
/// raylib's `LoadFontFromImage` - a BITMAP (sprite) font from an image whose
/// glyphs sit on a `key`-coloured background. `first_char` is the codepoint of
/// the first glyph (raylib uses 32). Decode the PNG with `z.loadImageFromMemory`,
/// pass the Image here (not consumed - free it yourself). See wgpu_app.
pub const loadFontFromImage = wgpu_app.loadFontFromImage;
/// CPU-side unload (glyph/rec arrays). Safe in `deinit`, which has no `gl`:
/// the GPU atlas is engine-owned and reclaimed by the registry reset at teardown.
pub const unloadFont = @import("text2d.zig").unloadFontOwned;
/// FULL release incl. the GPU atlas - use when REPLACING a font while running
/// (e.g. re-baking with more codepoints). See wgpu_app.releaseFont.
pub const releaseFont = wgpu_app.releaseFont;
pub const imageDrawTextWithFont = @import("text2d.zig").imageDrawTextWithFont;
pub const measureText = wgpu_app.measureText;
/// raylib `MeasureTextEx` - measure text with explicit inter-glyph spacing
/// (draw with `gl.text(pos, s, .{ .spacing = ... })`).
pub const measureTextEx = wgpu_app.measureTextEx;
pub const beginScissorMode = wgpu_app.beginScissorMode;
pub const endScissorMode = wgpu_app.endScissorMode;
// Multi-app viewport scoping (launcher-side; an example body never calls these).
pub const Placement = wgpu_app.Placement;
pub const pushViewport = wgpu_app.pushViewport;
pub const popViewport = wgpu_app.popViewport;
// Descriptor-only app shape (no globals/main); driven by the runner or launcher.
pub const AppSpec = wgpu_app.AppSpec;
pub const AppVtable = wgpu_app.AppVtable;
pub const eraseApp = wgpu_app.eraseApp;
pub const initInto = wgpu_app.initInto;
pub const Launcher = wgpu_app.Launcher;
pub const ChildId = wgpu_app.ChildId;
pub const bindFullscreenShader = wgpu_app.bindFullscreenShader;
pub const drawFullscreenTriangle = wgpu_app.drawFullscreenTriangle;
pub const drawFullscreenShader = wgpu_app.drawFullscreenShader;
// Input query API (free functions over f.input), mirroring the GL path.
pub const MouseButton = wgpu_app.MouseButton;
pub const getMousePosition = wgpu_app.getMousePosition;
pub const getDeviceGravity = wgpu_app.getDeviceGravity;
pub const getTouchPointCount = wgpu_app.getTouchPointCount;
pub const getTouchPosition = wgpu_app.getTouchPosition;
pub const getMouseX = wgpu_app.getMouseX;
pub const getMouseY = wgpu_app.getMouseY;
pub const getMouseDelta = wgpu_app.getMouseDelta;
pub const getMouseWheelMove = wgpu_app.getMouseWheelMove;
pub const isMouseButtonDown = wgpu_app.isMouseButtonDown;
pub const isKeyDown = wgpu_app.isKeyDown;
// ---- cursor (raylib HideCursor/ShowCursor/etc; needs the bridge's
// js_set_cursor_style, now provided). Wrappers live on the input namespace.
const input_ns = @import("runtime.zig").input;
pub const hideCursor = input_ns.hideCursor;
pub const showCursor = input_ns.showCursor;
pub const isCursorHidden = input_ns.isCursorHidden;
pub const disableCursor = input_ns.disableCursor;
pub const enableCursor = input_ns.enableCursor;
pub const setMouseCursor = input_ns.setMouseCursor;
pub const getTouchPointId = input_ns.getTouchPointId;

// ---- Gesture recognizers (backend-agnostic input math, re-exported from the
// runtime). The recognizers only read `current` seconds from a core TimeState,
// so the two time-taking entry points bridge wgpu's frame TimeState across.
const gestures_ns = @import("runtime.zig").gestures;
const core_ns = @import("runtime.zig").core;
pub const GesturesState = gestures_ns.GesturesState;
pub const Gesture = @import("types.zig").Gesture;
pub const getGestureDetected = gestures_ns.getGestureDetected;
pub const getGestureDragVector = gestures_ns.getGestureDragVector;
pub const getGestureDragAngle = gestures_ns.getGestureDragAngle;
pub const getGesturePinchVector = gestures_ns.getGesturePinchVector;
pub const getGesturePinchAngle = gestures_ns.getGesturePinchAngle;
pub const getGesturePinchScale = gestures_ns.getGesturePinchScale;
pub const getGesturePinchMid = gestures_ns.getGesturePinchMid;
pub const getGesturePinchMidDelta = gestures_ns.getGesturePinchMidDelta;

fn gestureTime(t: wgpu_app.TimeState) core_ns.TimeState {
    return .{ .current = t.time, .delta_time = t.delta_time };
}
/// Tick the gesture recognizers on the current frame's input snapshot.
pub fn updateGestures(
    state: *GesturesState,
    in: *input_ns.InputState,
    t: wgpu_app.TimeState,
) void {
    var ct: core_ns.TimeState = gestureTime(t);
    gestures_ns.update(state, in, &ct);
}
/// Seconds the current `.hold` gesture has been held (0 if not holding).
pub fn getGestureHoldDuration(state: *const GesturesState, t: wgpu_app.TimeState) f32 {
    var ct: core_ns.TimeState = gestureTime(t);
    return gestures_ns.getGestureHoldDuration(state, &ct);
}
pub const MouseCursor = @import("types.zig").MouseCursor;
pub const isKeyPressed = wgpu_app.isKeyPressed;
pub const getCharPressed = wgpu_app.getCharPressed;
pub const isMouseButtonPressed = wgpu_app.isMouseButtonPressed;
pub const isMouseButtonReleased = wgpu_app.isMouseButtonReleased;

// The WebGPU `gl: anytype` adapter (the "third renderer" alongside rlgl's
// GlAdapter + raster's SwAdapter): immediate-mode scene code drives Renderer2D's
// batch through it, so one `fn drawX(gl: anytype)` runs on all three backends.
pub const WgpuGl = @import("WgpuGl.zig");
const std = @import("std");
const bufPrint = std.fmt.bufPrint;

test {
    // Pull all module tests into one place.  `zig test
    // src/zimr.zig` runs everything reachable from the umbrella.
    _ = wgpu;
    _ = gpu;
    _ = BindGroupCache;
    _ = @import("renderer_2d.zig");
    _ = @import("wgpu_texture.zig");
    _ = @import("gpu_iface.zig");
    _ = shader.shader_compile;
    _ = shader;
    _ = wgpu.render_pass;
    _ = wgpu.compute_pass;
    _ = shader_introspect;
    _ = @import("compute_host.zig");
    _ = @import("draw3d.zig").draw_points;
    _ = @import("spv2wgsl.zig");
    _ = wgpu.storage_buffer;
    _ = wgpu_app;
    _ = WgpuGl;
}
