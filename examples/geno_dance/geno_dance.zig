//! examples/geno_dance — two skinned characters from FBX, side by side.
//!
//! The payoff of the mocap arc, and the smallest program that shows the pipeline is general
//! rather than tuned to one file:
//!
//!   Geno.fbx      + dance1_20s.bvh   75+21 bones, 1 mesh,  10 s, motion BORROWED
//!   Drop_Kick.fbx (Mixamo)           65 bones,    2 meshes, 2.9 s, motion its OWN take
//!
//! They share nothing — bone count, naming, mesh count, frame rate, and even how the motion
//! arrives all differ — yet both go through one `loadFbxModel` and one skinning path.
//!
//! ── ★ NO RETARGETING FOR GENO, AND THAT IS MEASURED ──
//!
//! Geno and `dance1_subject2` come from the same production and their skeletons agree exactly:
//! 96 bones, identical names, identical order — verified index by index, not inferred from the
//! names lining up. `skeletonsMatch` re-checks it at load and says so in the UI, because the
//! day it stops being true the mesh should complain rather than deform quietly wrongly.
//!
//! ── ★ WHERE THE MATRIX MATH LIVES ──
//!
//! Not here. `draw3d.poseSkinMatrices` and `draw3d.skinMeshCpu` own it, and their docs carry
//! the two zm conventions that are easy to invert and invisible in a bind pose — `mulMat`'s
//! argument order, and `vec` being a DIRECTION whose lane 3 is zero. This file does not import
//! a single matrix function; getting them wrong is no longer something an example can do.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const mulMat = zm.mulMat;
const translationV = zm.translationV;
const matFromQuat = zm.matFromQuat;
const radFromDeg = zm.radFromDeg;
const normalize3 = zm.normalize3;
const acosRad = zm.acosRad;
const clamp = zm.clamp;
const pi = zm.pi;
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui_real;
const mjcf = z.mjcf;
const d3 = z.draw3d;
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Vec = zm.Vec;
const Quat = zm.Quat;
const Color = zm.Color;
const float = zm.float;
const vec = zm.vec;
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

/// Character one: mesh, skin weights, and the rig its clusters were bound to. Its own take is
/// only a bind pose, so its motion comes from the BVH below.
const geno_fbx = @embedFile("Geno.fbx");
/// Ten seconds of `dance1_subject2` — the same production as Geno, and the reason no
/// retargeting is needed: 96 bones, same names, same order.
const dance_bvh = @embedFile("dance1_20s.bvh");
/// Character two: a Mixamo export that is SELF-CONTAINED — two skinned meshes, a 65-joint
/// `mixamorig:` skeleton, and its own animation in its second take.
///
/// ★ It shares nothing with Geno: different bone count, different naming, different mesh
/// count, different frame rate, and its motion arrives by a different route. Standing them
/// side by side is the demo AND the proof that none of this is tuned to one file.
const mixamo_fbx = @embedFile("Drop_Kick.fbx");

/// ★★★ GENO'S T-POSE, AND WHY IT IS A SEPARATE FILE.
///
/// Retargeting aligns two skeletons by their REFERENCE POSE, and the correction is only right
/// when both references depict the SAME PHYSICAL CONFIGURATION. They did not:
///
///   * Geno's FBX bind pose is an **A-POSE** — measured, hand at (49.4, 102.6, -4.9), hip
///     height, arms down.
///   * Mixamo's FBX bind pose is a **T-POSE** — arms out at shoulder height.
///
/// So `conjugate(mixamo_T) * geno_A` put Geno in its A-REST whenever Mixamo sat in its T-rest,
/// and every arm carried a constant ~45-degree droop through the whole clip.
///
/// GenoView ships `Geno_stance.bvh` for exactly this: the SAME 75-joint skeleton in a T-pose.
/// Its rotation channels are identical to `Geno_bind.bvh`'s and only the positions differ,
/// which is what makes it a genuinely separate artifact rather than something derivable.
const geno_tpose_bvh = @embedFile("Geno_stance.bvh");

const screen_w: i32 = 1000;
const screen_h: i32 = 760;

/// ★ EVERYTHING IS METRES FROM THE LOADER ONWARD. The captures and Geno are authored in
/// centimetres; `LoadFbxModelOptions.scale` and `scaleBvhSkeletalClip` convert once at load, so
/// no draw call, no shadow matrix and no AO radius ever carries a unit conversion.
///
/// ★★ THE SCENE WAS ALREADY METRIC — `ground_extent`, `light_extent`, `capsule_radius` and the
/// SSAO radius are all in metres and always were, because the old draw-time 0.01 converted
/// before they were applied. This finishes a convention rather than introducing one.
///
/// ★ And it is what §13 needs: `robot.zig` speaks metres, and a ragdoll synthesized from a
/// centimetre skeleton would get inertias off by a factor of 10^6.
const cm_to_m: f32 = 0.01;

/// The robot's hip height at rest, MEASURED from `humanoid.xml` rather than guessed — an earlier
/// hardcoded 0.9 was 8.5% off and skewed every target for the whole arc.
const robot_hip_height_m: f32 = 0.830;

// ── ★★★ `robot_height_m` AND `robot_total_bone_length_m` ARE GONE ──
//
// Both were introduced as scale anchors and both were wrong for the same underlying reason:
// **they measured the WHOLE robot against the WHOLE capture**, and the two are not the same
// anatomy — 65-78 capture joints, including fingers and a five-link spine, against 18 mapped
// bodies.
//
// ★★ `captureScale` now sums only MAPPED PAIRS, so it needs no whole-body constant at all: both
// sides are measured from the same correspondence, in the same loop. **A constant that has to be
// kept in step with a model is a constant that will drift** — this one deleted itself by making
// the question local.

/// The scale taking this capture's units to the robot's metres — from the LIBRARY.
///
/// ── ★★★ THE LAST FOUR BUGS ALL LIVED IN THIS CONVERSION ──
///
/// The scale, the anchor, the units and the anatomy mismatch were every one of them here, in the
/// example, where no test could reach them. **`robot.captureScale` now owns it**, with its three
/// properties — pose-invariant, unit-cancelling, anatomy-matched — asserted in the harness rather
/// than argued for in a comment.
fn captureScale(s: *const State, source: *const Character) f32 {
    return z.robot.captureScale(&s.robot.model, .{
        .positions = source.positions[0..source.boneCount()],
        .rotations = source.rotations[0..source.boneCount()],
        .parents = source.target_parents[0..source.boneCount()],
        .human_of_body = s.human_of_body,
    });
}

/// The floor is a large CUBE sunk so only its top face shows. `drawCubeTexture` takes a single
/// uniform size, so a thin slab is not available — and a sunken cube is better anyway: the
/// shadow pass in §12a-2 wants a receiver with real thickness, not a zero-height plane.
const ground_extent: f32 = 8.0;
const ground_light: Color = .{ .r = 205, .g = 205, .b = 205, .a = 255 };
const ground_dark: Color = .{ .r = 170, .g = 170, .b = 170, .a = 255 };

/// The sun's direction, from yaw and pitch.
///
/// ★ EXPOSED AS SLIDERS SO THE NORMALS CAN BE AUDITED. A fixed light hides normal errors: a
/// facet with a wrong normal just looks like a slightly odd shade and nothing contradicts it.
/// SWEEPING the light makes the error obvious — correct normals shade smoothly and
/// continuously as the light moves, while a bad patch pops, stays flat, or lights in the wrong
/// direction. It is the cheapest normal debugger there is, and unlike a normals-as-colour view
/// it needs no new shader.
///
/// Pitch is measured DOWN from the horizon, so 0 grazes the ground and 90 is directly overhead.
fn lightDirFrom(yaw_deg: f32, pitch_deg: f32) Vec {
    const yaw: f32 = yaw_deg * (pi / 180.0);
    const pitch: f32 = pitch_deg * (pi / 180.0);
    const cp: f32 = @cos(pitch);
    return vec(-@sin(yaw) * cp, -@sin(pitch), -@cos(yaw) * cp);
}
/// How far back along the light the camera sits, and how much it covers. Big enough to hold
/// both characters and the ground they stand on.
const light_distance: f32 = 6.0;
/// Half-width of the light's orthographic box, in world units.
///
/// ★ SIZED TO THE CASTERS, AND THE BOX FOLLOWS THEM. Tightening this to 1.6 spent the map's
/// resolution well but clipped the dance: `dance1` travels, so a box centred on the origin
/// loses the character the moment it steps away — visible as a shadow that simply stops.
///
/// `lightTarget` re-centres the box on the characters' midpoint every frame, which is the
/// standard fix for a directional map and cheaper than widening: following keeps the texel
/// density, widening throws it away.
const light_extent: f32 = 2.6;
const light_near: f32 = 0.1;
const light_far: f32 = 30.0;

const shadow_map_size: u32 = 1024;
/// G-buffer resolution. Square and fixed — see `initGbuffer`.
const gbuffer_size: u32 = 1024;

// ── Host mirrors of the two `lit_shadow` uniform blocks ──
//
// These MUST match `lit_shadow_vs_io.Ubo` / `lit_shadow_fs_io.Ubo` field for field: the layout
// is the wire contract between this file and the generated WGSL, and a mismatch shows up as
// garbage transforms rather than a compile error.

/// `lit_shadow_vs_io.Ubo` — group 0.
const LitVsUbo = struct {
    mvp: [4]Vec,
    light_vp: [4]Vec,
    normal_matrix: [4]Vec,
};

/// `lit_shadow_fs_io.Ubo` — group 2. `params` is {bias_slope, bias_min, 0, 0}; the defaults
/// in the shader's schema are tuned for an f16 depth map.
const LitFsUbo = struct {
    light_dir: Vec,
    base_color: Vec,
    params: Vec,
};

/// `ssao_fs_io.Ubo` — group 2 of the AO pass.
const SsaoUbo = struct {
    /// Camera view matrix: occlusion is measured in VIEW space so `radius` means a fixed
    /// distance from the camera rather than something that drifts as the scene moves.
    view: [4]Vec,
    /// {radius, bias, intensity, unused}
    params: Vec,
    /// {turns, inv_width, inv_height, unused}
    spiral: Vec,
};

/// `ssao_blur_fs_io.Ubo` — one pipeline, two passes, the axis switched by uniform.
const SsaoBlurUbo = struct {
    /// {texel_x, texel_y, axis_x, axis_y}
    step: Vec,
    /// {position_falloff, normal_power, 0, 0}
    weights: Vec,
};

const ssao_blur_ubo_bytes: u64 = z.shader.wireSizeOf(SsaoBlurUbo);
const ssao_blur_fs_wgsl = @embedFile("ssao_blur_fs.wgsl");
const ssao_ubo_bytes: u64 = z.shader.wireSizeOf(SsaoUbo);
const ssao_fs_wgsl = @embedFile("ssao_fs.wgsl");
/// ★ The AO pass reuses the DEFERRED SHADING vertex stage — same fullscreen quad, same UV
/// flip. `ssao_common_io` says so; shipping a second copy would be a second thing to keep in
/// step for no gain.
const fullscreen_vs_wgsl = @embedFile("deferred_shading_vs.wgsl");

/// The fullscreen triangle pair, in NDC.
const fullscreen_verts = [_][2]f32{
    .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 },
    .{ -1, -1 }, .{ 1, 1 },  .{ -1, 1 },
};

/// `gbuffer_vs_io.Ubo` — the geometry prepass, group 0.
const GbufVsUbo = struct {
    mvp: [4]Vec,
    model: [4]Vec,
    normal_matrix: [4]Vec,
};

/// `gbuffer_fs_io.Ubo` — group 2. Only the albedo matters to SSAO, which reads position and
/// normal, but the shader writes all three attachments regardless.
const GbufFsUbo = struct {
    albedo_spec: Vec,
};

const gbuf_vs_bytes: u64 = z.shader.wireSizeOf(GbufVsUbo);
const gbuf_fs_bytes: u64 = z.shader.wireSizeOf(GbufFsUbo);
const gbuffer_vs_wgsl = @embedFile("gbuffer_vs.wgsl");
const gbuffer_fs_wgsl = @embedFile("gbuffer_fs.wgsl");

/// `depth_vs_io.Ubo` — the light pass writes NDC depth to the red channel.
const DepthUbo = struct {
    mvp: [4]Vec,
    /// {cam_near, cam_far, viz_near, viz_far} — only the first two matter in shadow mode.
    params: Vec,
    /// 0 = raw `ndc_z*0.5+0.5`, which is exactly what `lit_shadow_fs` compares against.
    mode: i32,
    pad0: i32 = 0,
    pad1: i32 = 0,
    pad2: i32 = 0,
};

const depth_ubo_bytes: u64 = z.shader.wireSizeOf(DepthUbo);
const depth_vs_wgsl = @embedFile("depth_vs.wgsl");
const depth_fs_wgsl = @embedFile("depth_fs.wgsl");
const lit_vs_bytes: u64 = z.shader.wireSizeOf(LitVsUbo);
const lit_fs_bytes: u64 = z.shader.wireSizeOf(LitFsUbo);
const lit_vs_wgsl = @embedFile("lit_shadow_vs.wgsl");
const lit_fs_wgsl = @embedFile("lit_shadow_fs.wgsl");

/// The ground as the shadow pipeline sees it: position then normal, 24-byte stride — the same
/// layout `Cube3D`'s `MeshVertex` uses, so the characters can join this pass unchanged later.
const GroundVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
};

/// GenoView tints the character raylib's ORANGE against the grey floor, as linear rgb for the
/// shader's `base_color` (255,161,0 scaled to 0..1).
const character_albedo: Vec = .{ 1.0, 0.63, 0.0, 1.0 };
/// The floor's albedo — flat until §12e brings the checker back through the G-buffer.
const ground_albedo: Vec = .{ 0.72, 0.72, 0.74, 1.0 };

/// One skinned figure: its model, whatever clip drives it, and the per-frame scratch.
///
/// The clip is a SEPARATE field rather than always `model.clip` because the two characters get
/// their motion differently — Geno borrows a BVH, the Mixamo rig uses its own take — and the
/// update loop should not care which.
const Character = struct {
    model: d3.FbxModel,
    /// The clip actually played. May be `model.clip` or an external one.
    clip: d3.BvhSkeletalClip,
    /// True when `clip` is external and this struct must free it.
    owns_clip: bool,
    /// Where this figure stands, so two of them do not occupy the same space.
    offset: Vec,

    // ── ★ RETARGETING: this character can be driven by ANOTHER character's clip ──
    //
    // `source_character` indexes `State.characters`. When it points at this character, the clip
    // plays natively and nothing is retargeted. When it points elsewhere, that character's clip
    // becomes the SOURCE and the map below carries its motion across.
    source_character: usize,
    /// `source_of_target[j]` is the SOURCE joint feeding this character's joint j, or
    /// `codecs.bvh.no_source`. Rebuilt whenever `source_character` changes.
    source_of_target: []i32,
    /// How many of this character's joints found a source. Zero means the map is wrong, and
    /// the UI says so rather than showing a rest pose and letting it look like a solver bug.
    mapped_joint_count: usize,
    /// This character's own parent indices, cached as plain `i32` because that is what
    /// `codecs.bvh.retargetRotations` takes.
    target_parents: []i32,
    /// ★ Per-joint correction for the two rigs disagreeing about REST. Measured: LAFAN1's
    /// leg bones point (0,-1,0) at rest while Mixamo's point (0,+1,0) — dot = -1.000 — so an
    /// uncorrected copy bends the legs backwards. Derived, not authored; see
    /// `codecs.bvh.restAlignmentOffsets`.
    rest_alignment: []Quat,
    /// This skeleton's own rest orientations, recovered from its bone directions.
    rest_orientations: []Quat,
    /// World positions at the T-pose, for bone directions. Zeroed when no T-pose file exists.
    rest_positions: []Vec,
    /// Scratch for one retargeted frame. Sized to the LARGEST skeleton in the scene, because
    /// the source may have more joints than this character does.
    source_positions: []Vec,
    source_global_rotations: []Quat,
    retargeted_local_rotations: []Quat,
    retargeted_global_rotations: []Quat,
    /// Distance from the floor to this skeleton's root at rest, used to scale root travel
    /// between characters of different size.
    hip_height: f32,
    label: []const u8,

    skin: []Mat,
    positions: []Vec,
    rotations: []Quat,
    /// ★ THE REST POSE, KEPT SEPARATELY — one array per mesh, and it must be.
    ///
    /// `updateMeshBuffer` writes into `mesh.vertices` itself, so the mesh's own array stops
    /// being the rest pose after the first upload. Skinning from it would feed each frame's
    /// output back in as the next frame's input: the figure inflates into a fan of triangles
    /// and keeps drifting even with playback PAUSED, because the source keeps changing.
    /// `examples/skinned_mesh` keeps `base_positions` for the same reason.
    base_positions: [][]f32,
    skinned: [][]f32,
    /// The REST normals, kept for the same reason as `base_positions`: skinning writes into
    /// `mesh.normals`, so reading the rest pose from there would compound each frame.
    base_normals: [][]f32,
    skinned_normals: [][]f32,

    fn boneCount(self: *const Character) usize {
        return self.model.clip.boneCount();
    }

    fn duration(self: *const Character) f32 {
        return float(@max(self.clip.animation.keyframeCount, 0)) * self.clip.frame_time;
    }

    fn deinit(self: *Character, gpa: Allocator) void {
        for (self.base_positions) |b| {
            gpa.free(b);
        }
        for (self.skinned) |b| {
            gpa.free(b);
        }
        for (self.base_normals) |b| {
            gpa.free(b);
        }
        for (self.skinned_normals) |b| {
            gpa.free(b);
        }
        gpa.free(self.base_normals);
        gpa.free(self.skinned_normals);
        gpa.free(self.base_positions);
        gpa.free(self.skinned);
        gpa.free(self.rotations);
        gpa.free(self.source_of_target);
        gpa.free(self.target_parents);
        gpa.free(self.rest_alignment);
        gpa.free(self.rest_orientations);
        gpa.free(self.rest_positions);
        gpa.free(self.source_positions);
        gpa.free(self.source_global_rotations);
        gpa.free(self.retargeted_local_rotations);
        gpa.free(self.retargeted_global_rotations);
        gpa.free(self.positions);
        gpa.free(self.skin);
        if (self.owns_clip) {
            d3.unloadBvhSkeletalClip(gpa, self.clip);
        }
        d3.unloadFbxModel(gpa, self.model);
    }
};

const State = struct {
    ui_host: z.UiHost,
    font: z.Font,
    cam: z.OrbitCamera,
    gpa: Allocator,

    characters: [2]Character,
    /// The checkered floor, as a flattened textured box — GenoView's ground is a plane, but a
    /// box gives the shadow pass something with thickness to receive onto later (§12a).
    ground: z.WgpuTexture,
    /// The shadow-receiving ground: its own pipeline, buffers and bind groups.
    ground_pipeline: z.wgpu.RenderPipelineHandle,
    ground_vbo: z.wgpu.BufferHandle,
    ground_ibo: z.wgpu.BufferHandle,
    ground_index_count: u32,
    ground_vs_ubo: z.wgpu.BufferHandle,
    ground_fs_ubo: z.wgpu.BufferHandle,
    ground_g0: z.wgpu.BindGroupHandle,
    ground_g1: z.wgpu.BindGroupHandle,
    ground_g2: z.wgpu.BindGroupHandle,
    /// Layouts are kept only so `deinit` can release them — the leak checker counts every
    /// bind-group layout and pipeline layout, not just the buffers.
    ground_bgls: [3]z.wgpu.BindGroupLayoutHandle,
    ground_pl: z.wgpu.PipelineLayoutHandle,

    /// The light pass's depth pipeline. One UBO per character, because each has its own model
    /// matrix and a UBO cannot change between draws in a pass.
    depth_pipeline: z.wgpu.RenderPipelineHandle,
    depth_pl: z.wgpu.PipelineLayoutHandle,
    depth_bgl: z.wgpu.BindGroupLayoutHandle,
    depth_ubos: [2]z.wgpu.BufferHandle,
    depth_bgs: [2]z.wgpu.BindGroupHandle,

    /// Per-character `lit_shadow` uniforms, so the characters go through the SAME pipeline as
    /// the ground and therefore receive shadows — including their own.
    char_vs_ubos: [2]z.wgpu.BufferHandle,
    char_fs_ubos: [2]z.wgpu.BufferHandle,
    char_g0: [2]z.wgpu.BindGroupHandle,
    char_g2: [2]z.wgpu.BindGroupHandle,

    /// ── ★ THE G-BUFFER: world position, world normal, albedo ──
    ///
    /// Three attachments filled by ONE geometry walk via `beginTextureModeMrtRaw`. Only the
    /// first carries depth — one scene, one depth test.
    ///
    /// ★ POSITION AND NORMAL ARE rgba16-FLOAT, NOT rgba8. SSAO measures distances between
    /// sampled positions; at 8 bits per channel those distances quantise into terraces and the
    /// occlusion estimator reads the steps as geometry. The albedo target stays rgba8 because
    /// colour genuinely only needs 8 bits.
    gbuf_pos: z.RenderTexture,
    gbuf_normal: z.RenderTexture,
    gbuf_albedo: z.RenderTexture,
    gbuf_pipeline: z.wgpu.RenderPipelineHandle,
    gbuf_pl: z.wgpu.PipelineLayoutHandle,
    gbuf_bgls: [2]z.wgpu.BindGroupLayoutHandle,
    /// One set per drawable: two characters plus the ground.
    gbuf_vs_ubos: [3]z.wgpu.BufferHandle,
    gbuf_fs_ubos: [3]z.wgpu.BufferHandle,
    gbuf_g0: [3]z.wgpu.BindGroupHandle,
    gbuf_g2: [3]z.wgpu.BindGroupHandle,

    /// The ambient-occlusion factor, one channel's worth in an rgba8 target.
    ///
    /// ★ rgba8 IS ENOUGH HERE, unlike the G-buffer. AO is a 0..1 coverage number that gets
    /// multiplied into a colour; 256 levels is finer than the eye resolves in shading. The
    /// G-buffer needed f16 because it stores POSITIONS, whose differences drive the estimator.
    ssao_rt: z.RenderTexture,
    ssao_pipeline: z.wgpu.RenderPipelineHandle,
    ssao_pl: z.wgpu.PipelineLayoutHandle,
    ssao_bgls: [2]z.wgpu.BindGroupLayoutHandle,
    ssao_ubo: z.wgpu.BufferHandle,
    ssao_g1: z.wgpu.BindGroupHandle,
    ssao_g2: z.wgpu.BindGroupHandle,
    ssao_sampler: z.wgpu.SamplerHandle,
    /// The blur's scratch target. Pass 1 writes `ssao_rt` -> `ssao_blur_rt` (horizontal),
    /// pass 2 writes back `ssao_blur_rt` -> `ssao_rt` (vertical), so the composite keeps
    /// reading `ssao_rt` and nothing downstream has to know a blur happened.
    ssao_blur_rt: z.RenderTexture,
    ssao_blur_pipeline: z.wgpu.RenderPipelineHandle,
    ssao_blur_pl: z.wgpu.PipelineLayoutHandle,
    ssao_blur_bgls: [2]z.wgpu.BindGroupLayoutHandle,
    /// One UBO per pass — a uniform cannot change between draws inside a pass, and these are
    /// separate passes, but separate buffers also keep the two axes independently inspectable.
    ssao_blur_ubos: [2]z.wgpu.BufferHandle,
    ssao_blur_g2: [2]z.wgpu.BindGroupHandle,
    /// Bind group reading `ssao_rt` (for the horizontal pass) and one reading `ssao_blur_rt`.
    ssao_blur_g1: [2]z.wgpu.BindGroupHandle,
    fullscreen_vbo: z.wgpu.BufferHandle,

    /// The shadow map: rgba16-FLOAT colour plus its own depth attachment.
    ///
    /// ★ NOT `loadRenderTexture`, WHICH GIVES rgba8 — 256 depth levels. The default bias in
    /// `lit_shadow_fs_io` is tuned for an f16 map; against an 8-bit one it is roughly EIGHT
    /// TIMES too small, and the result is enormous smooth bands of false self-shadow across
    /// the body and head. That is what the device showed, and `shadowmap`'s own comment
    /// predicts it: "a float colour target stores the light-view depth at ~16-bit precision
    /// (vs 256 levels for rgba8), which is what lets the shadow bias drop low enough to avoid
    /// both acne and peter-panning."
    light_view: z.RenderTexture,
    /// ★ NEAREST, NOT LINEAR. Linear filtering blends depths ACROSS SILHOUETTE EDGES, and a
    /// blended depth is a distance to nothing — the comparison against it is meaningless.
    /// `loadRenderTexture`'s sampler is linear, which was the second half of the same bug.
    shadow_sampler: z.wgpu.SamplerHandle,

    play_time: f32 = 0,
    playing: bool = true,
    /// ★ ON by default, with the mesh off: the skeleton is what the robot is being COMPARED to,
    /// so both need to be visible without touching a control.
    show_skeleton: bool = true,
    /// Draw every body's and joint's local frame as red/green/blue axes.
    ///
    /// ★★ Off by default — it is a diagnostic view, and on a 78-joint skeleton it is a lot of
    /// lines. **On when a frame is suspected**, which in this project has been most of the time.
    show_transforms: bool = false,
    /// How long to draw those axes, in metres.
    axis_length: f32 = 0.08,
    /// ★★ OFF by default, because the robot is drawn OVERLAID on the character and a solid mesh
    /// hides it completely. Every screenshot of this example so far has begun by toggling this
    /// off — **a default that has to be undone before anything can be seen is the wrong
    /// default.** The skeleton still draws, so the comparison is immediate.
    show_mesh: bool = false,
    show_ground: bool = true,
    show_light_view: bool = true,
    show_ao: bool = true,
    // ── ★ THE ROBOT: `humanoid.xml` driven by the same retarget as the characters ──
    //
    // 16 bodies against a capture's 96 joints, hinges instead of ball joints, and a tree that
    // roots at the TORSO with the pelvis hanging below it. All three are handled by machinery
    // the characters already needed: the global-space retarget copes with the inverted tree,
    // and `fitBodyRotation` decomposes each desired rotation across whatever DOF a body has.
    robot_doc: z.codecs.xml.Document,
    robot_spec: mjcf.Robot,
    robot: z.robot_mjcf.Imported,
    robot_data: z.robot.Data,
    /// The robot's rest orientations, from its own `qpos0` — which is measurably a T-POSE.
    robot_reference: []Quat,
    /// Which capture joint drives each robot body, from `robot.lafan_to_humanoid`.
    human_of_body: []i32,
    robot_parents: []i32,
    robot_rest_alignment: []Quat,
    robot_local: []Quat,
    robot_global: []Quat,
    /// Body positions converted to the scene's Y-UP frame, filled once per pose.
    ///
    /// ★★ `robot_mjcf.build` keeps MJCF models Z-UP ON PURPOSE — its acceptance test is
    /// agreement with MuJoCo body for body, and a frame conversion inside it would turn any
    /// disagreement into two possible explanations (robot_mjcf.zig:33). So the robot arrives
    /// standing along +Z, and in a Y-up scene that reads as LYING FLAT ON THE GROUND.
    ///
    /// ★ The conversion happens ONCE HERE, where robot data enters the scene — not at draw
    /// time. That is the "one-line root rotation" robot_mjcf.zig:39 anticipates its callers
    /// applying, and it keeps every downstream user (drawing, and later contact or shadows)
    /// reading Y-up like the rest of zimr.
    robot_positions_y_up: []Vec,
    /// Per-joint motion relative to the T-pose, re-expressed in the robot's Z-up frame.
    source_delta_z_up: []Quat,
    /// Position pull per body, from the match table. Zero means orientation only.
    /// The human-side bone-direction reference the robot pairing uses, kept so `poseRobot` can
    /// build its motion delta against the SAME reference the alignment was built from.
    robot_human_reference: []Quat,
    /// Axis correspondence per body: `robot_bone_dir * conj(human_bone_dir)`.
    robot_axis_map: []Quat,
    robot_desired_global: []Quat,
    /// `i -> i` and all-identity, so `retargetRotations` can do the global-to-local walk with
    /// the correspondence already folded into the input.
    robot_identity_map: []i32,
    robot_identity_alignment: []Quat,
    robot_position_weights: []f32,
    robot_rotation_weights: []f32,
    /// Per-body rotation taking the HUMAN's rest bone direction onto the ROBOT's. Identity
    /// where the two already agree, which the measurement says is torso and both legs.
    robot_limb_correction: []Quat,
    /// ★ The ported twist offsets — see `src/notes/twist_port_plan.md`. `robot_twist[b]` maps
    /// the robot's rest bone direction onto the capture's; `robot_parent_twist[b]` is the twist
    /// of `b`'s parent, undone so a chain does not accumulate it.
    robot_rest_world: []Vec,
    robot_rest_rotations: []Quat,
    /// The robot's body positions at `qpos0`, kept for the rest-pose comparison.
    robot_rest_xpos: []Vec,
    /// The solved T-pose configuration, so it can be restored without re-solving.
    robot_tpose_qpos: []f32,
    /// The robot's body orientations at the solved T-pose, needed to place its geoms.
    robot_rest_xrot: []Quat,
    /// The robot's body POSITIONS in the solved rest pose, for the leaf correspondence check.
    robot_rest_body_pos: []Vec,
    /// Each 1-DOF body's bend at the SOLVED rest pose, in radians — the offset a hinge
    /// coordinate is measured from.
    robot_rest_flexion: []f32,
    /// Point-cloud samples, built once when the robot map changes.
    robot_samples: []z.robot.PointSample,
    robot_sample_count: usize = 0,
    /// How many robot bodies the match table resolved. **Zero means the robot is hidden and the
    /// cause is the TABLE**, which looked like a rendering bug for two turns.
    robot_mapped_count: usize = 0,
    /// How many frames `poseRobot` has actually completed. **Zero with the robot visible means
    /// the pose function is not being reached**, which draws every body at the origin.
    robot_posed_frames: usize = 0,
    /// Mean and worst world distance from a robot body to its capture joint, and which body is
    /// worst. **The metric that matches what the eye integrates**; angle metrics are blind to a
    /// figure standing in the wrong place.
    robot_visual_mean: f32 = -1,
    robot_visual_worst: f32 = -1,
    robot_visual_worst_name: []const u8 = "",
    /// How far to pull targets from the RETARGETED skeleton (0) toward the capture's own world
    /// joints (1).
    ///
    /// ── ★★★ THE DIAL BETWEEN SHAPE AND PLACE ──
    ///
    /// At 0 every target is built from the ROBOT's own bone lengths, so it is exactly reachable
    /// and the chain accumulates away from the capture. At 1 the targets ARE the capture's
    /// joints, so the figure stands where the dancer stands but a mismatched limb cannot reach.
    ///
    /// ★★ **1.0 is right when the proportions match** — `humanoid_flex2.xml` is Geno-shaped, and
    /// swept 0/0.5/1.0 the highest value won on every bone. **A robot whose proportions do NOT
    /// match wants a lower value**, which is the case this dial exists for and the one that was
    /// previously a hardcoded constant.
    ///
    /// ★ Exposed because the readout beside it now reports `fit` and `worst`, so the trade can be
    /// judged on the capture it applies to rather than inferred from a different one.
    robot_position_pull: f32 = 1.0,
    /// Load the STOCK `humanoid.xml` instead of the Geno-shaped `humanoid_flex2.xml`.
    ///
    /// ★★ `flex2` was built FOR Geno: arms shortened 20%, spine split matched, a third shoulder
    /// axis. **Running a Mixamo capture on the stock model is the honest generalisation test** —
    /// nothing about it was tuned for either.
    ///
    /// ★ Read ONCE, in `initRobot`. Changing it mid-session does nothing, which is why there is
    /// no checkbox for it: reloading the robot means rebuilding the model, data, tasks, scratch,
    /// samples and rest pose.
    robot_use_stock: bool = false,
    /// Last frame's configuration, for the posture term.
    robot_previous_qpos: []f32,
    robot_has_previous: bool = false,
    /// Draw the robot's actual GEOMS, not just capsules between body origins.
    show_robot_geoms: bool = true,
    /// True once the map and the solved T-pose exist — the comparison view depends on both.
    robot_ready: bool = false,
    robot_twist: []Quat,
    robot_parent_twist: []Quat,
    robot_tasks: []z.robot.IkTask,
    robot_ik_scratch: []f32,
    /// ★ Live, because the right count is a measurement. Zero disables the IK stage entirely,
    /// which is the A/B that says whether it is helping.
    /// ★ HIGHER THAN BEFORE, because the IK now does ALL the work: there is no analytic fit
    /// supplying a warm start, and each frame begins from the rest configuration. GMR warm-
    /// starts from the previous frame and converges in a handful; starting from rest costs more
    /// steps and buys a frame that cannot inherit the previous one's error.
    /// ★★ MUST MATCH A RADIO VALUE. It was 30 while the radios offered 0 and 20, so NEITHER
    /// showed as selected and the UI could not tell you what was running. A default that no
    /// control can display is a silent state.
    robot_ik_iterations: i32 = 20,
    robot_ik_damping: f32 = 1.0,
    /// Draw the robot on top of the character it follows, rather than beside it.
    robot_overlay: bool = true,
    /// Show both rest poses instead of the animation, for inspecting what the twists are built
    /// from.
    show_tpose_compare: bool = false,
    /// X offset between the two rest poses. Zero superimposes them.
    tpose_offset: f32 = 1.2,
    /// ★ How many mapped bodies take part. 1 is the TORSO ALONE — the smallest thing that can
    /// be checked, and the one every previous attempt skipped straight past.
    /// ★ All sixteen by default now that the formula is settled. The 1/2/4/8 steps remain, so
    /// a future problem can be bisected the same way this one finally was.
    /// Which candidate orientation formula to use — see `poseRobot`. Selectable because
    /// deriving the right one has cost more rounds than trying them will.
    /// ★  (mode 2) is the best measured candidate now that one-hinge joints BEND rather
    /// than aim: +0.151 against -0.231 and -0.196 for the other two. Still far from +1.0, so
    /// this is the current best, not a solution.
    robot_orientation_mode: i32 = 2,
    /// Degrees of yaw about the robot's up axis, correcting the two skeletons' FACING.
    ///
    /// ── ★★★ WHY A YAW, AND WHY A QUARTER TURN — both facings MEASURED ──
    ///
    ///     LAFAN1    LeftToeBase offset (Y-up)   = (0, 0, 15.26)      character faces +Z
    ///     humanoid  foot geom fromto (Z-up)     = -.07 -> +.14 in x   robot faces +X
    ///
    /// ★★ **The two skeletons are a quarter turn apart, and nothing else differs.** That is the
    /// whole correction — one number shared by every bone — and it is why the per-joint rest
    /// alignments this arc built were machinery for a problem that does not exist.
    ///
    /// ★ **-90, NOT +90, AND THE DERIVATION SAYS OTHERWISE.** Mapping Y-up to Z-up as
    /// `(x, y, z) -> (x, -z, y)` sends the human's +Z forward to -Y, and taking -Y to +X is
    /// +90 about Z on paper. The device says -90. So one of two sign conventions is opposite to
    /// my assumption — the handedness of that map, or zm's rotation sense.
    ///
    /// ★★ **THE MEASURED VALUE IS AUTHORITATIVE AND THE DISCREPANCY IS RECORDED RATHER THAN
    /// SMOOTHED OVER.** A derivation that disagrees with the device is a derivation with a bug
    /// in it, and writing "+90 by symmetry" over a working -90 would bury a real inconsistency
    /// for the next person to trip on.
    robot_facing_yaw: f32 = -90.0,
    /// ★★ REMOVED, DELIBERATELY. Two attempts at a "rest check" were both VACUOUS —
    /// `qmul(q, conj(q))` and `qmul(c, conj(c))` are identity for ANY input, so both read
    /// 0.0000 on device while proving nothing. A third guess would have been worse than none.
    ///
    /// ★ A real one has to compare against something EXTERNAL: solve with the human at its
    /// T-pose and assert the robot ends up STANDING — head above pelvis above feet. That needs
    /// its own solve and belongs in a test, not in the frame loop.
    robot_rest_check_removed: void = {},
    /// Mean unrepresentable angle across mapped bodies — the honest quality number, shown in
    /// the UI so a MODEL limit never gets mistaken for a bug.
    robot_mean_residual: f32 = 0,
    show_robot: bool = true,
    robot_dirty: bool = true,
    /// Which character's clip drives the robot.
    /// Which character's animation the robot follows. **1 = the Mixamo drop kick**, index 0 being
    /// Geno's dance.
    ///
    /// ── ★★★ DEFAULT TO THE CASE THAT FAILS ──
    ///
    /// This defaulted to the drop kick (index 1) so the least-tested path would be on screen.
    /// **But the drop kick WORKS and Geno's dance does not** — so the default was hiding the
    /// broken case behind a working one, and every screenshot needed a manual toggle first.
    ///
    /// ★ A default should show the thing most likely to be wrong. **Right now that is the
    /// dance**, whose targets collapsed to a 0.42 m ball while the drop kick's were fine.
    robot_source: usize = 0,

    /// Set when a source selection changes, so the name maps rebuild once rather than per frame.
    retarget_dirty: bool = true,
    /// ★ REST ALIGNMENT ON/OFF, so the correction can be judged against its absence.
    ///
    /// It is unambiguously right for limbs — LAFAN1's leg bones point (0,-1,0) at rest and
    /// Mixamo's point (0,+1,0), and without the correction the legs bend backwards. It is
    /// LESS clearly right for hands and feet, whose rest direction is derived from a THUMB and
    /// a TOE respectively, and those disagree by ~72 and 90 degrees between the two rigs:
    ///
    ///     LeftFoot   src(0,0,1)          dst(0,1,0)             dot = 0.000
    ///     LeftHand   src(0.50,0.69,0.52) dst(-0.68,0.62,0.40)   dot = 0.296
    ///
    /// A toggle is honest here: the limb fix is verified and the extremity behaviour is not,
    /// so both are visible side by side rather than one being assumed.
    align_rest: bool = true,
    /// Which offscreen target the corner inset shows: 0 shadow map, 1 G-buffer position,
    /// 2 G-buffer normal, 3 G-buffer albedo.
    ///
    /// ★ EVERY STAGE INSPECTABLE ON ITS OWN. §12's method, and the reason the earlier
    /// inverted-shadow and flat-grey bugs were findable at all: a six-pass pipeline where only
    /// the final image can be seen is a pipeline where any one stage can be silently wrong.
    debug_view: i32 = 4,
    /// Bone thickness in world units. A human forearm is ~4 cm at this scale; the default
    /// reads clearly without swallowing the joints.
    capsule_radius: f32 = 0.018,
    /// Sun direction. Defaults reproduce the original fixed `(-0.5, -1.0, -0.4)`.
    light_yaw: f32 = 51.0,
    light_pitch: f32 = 57.0,
    /// Shadow-compare bias, {slope, min}. ★ EXPOSED AS SLIDERS because the right values depend
    /// on the DEPTH MAP'S PRECISION and on how grazing the light is — and because self-shadow
    /// acne on a curved character is far pickier than a flat floor ever was. The defaults are
    /// `lit_shadow_fs_io`'s, tuned for an f16 map.
    /// SSAO knobs, live so the effect can be dialled against the render.
    ssao_radius: f32 = 0.5,
    ssao_bias: f32 = 0.025,
    ssao_intensity: f32 = 0.15,
    blur_ao: bool = true,
    /// Squared world distance is multiplied by this before the exponential — larger rejects
    /// neighbours sooner, preserving edges at the cost of leaving more noise.
    blur_falloff: f32 = 8.0,
    /// Exponent on the normal-alignment term; larger keeps creases crisper.
    blur_normal_power: f32 = 8.0,
    shadow_bias_slope: f32 = 0.0025,
    shadow_bias_min: f32 = 0.0008,
    status: [96]u8 = @splat(0),
    status_len: usize = 0,

    /// The facing correction as a quaternion, about the robot's up axis.
    ///
    /// ★ Z IS UP IN THE ROBOT'S FRAME, so the yaw is about Z — not about Y, which is up for the
    /// character side. Getting that wrong would tip the robot rather than turn it.
    fn robotFacingYaw(self: *const State) Quat {
        return zm.quatFromAxisAngle(vec(0, 0, 1), radFromDeg(self.robot_facing_yaw));
    }
};

/// A joint's world matrix from a sampled pose: rotate, then translate.
///
/// ★ `mulMat(a, b)` APPLIES **b FIRST, THEN a** in zm — the opposite of reading it
/// left-to-right, and the opposite of raylib's `MatrixMultiply`. So "rotate then translate" is
/// `mulMat(translation, rotation)`, not the other way round. Pinned by a test in `draw3d`
/// (`zm: mulMat and mulMatVec compose in the order the skinning path assumes`), because the
/// The inverse of a rotation-plus-translation matrix, computed as a rigid inverse rather than a
/// general one: transpose the rotation block, then negate the translation through it.
///
/// ★ Exact here and cheaper than a general inverse, BUT it assumes no scale — which holds
/// because BVH carries only rotation and translation, and `fromFbx` writes exactly those
fn setStatus(s: *State, comptime fmt: []const u8, args: anytype) void {
    const written: []u8 = bufPrint(&s.status, fmt, args) catch {
        s.status_len = 0;
        return;
    };
    s.status_len = written.len;
}

/// ★ The example's central claim, checked rather than trusted.
fn skeletonsMatch(a: d3.BvhSkeletalClip, b: d3.BvhSkeletalClip) bool {
    if (a.boneCount() != b.boneCount()) {
        return false;
    }
    for (0..a.boneCount()) |j| {
        if (!std.mem.eql(u8, a.boneName(j), b.boneName(j))) {
            return false;
        }
    }
    return true;
}

/// Build a character from FBX bytes, optionally driven by an external clip.
fn makeCharacter(
    gpa: Allocator,
    fbx_bytes: []const u8,
    external: ?d3.BvhSkeletalClip,
    offset: Vec,
    label: []const u8,
    recompute_normals: bool,
    self_index: usize,
    /// A BVH holding this skeleton in a T-POSE, or null to use the FBX bind pose. Supply one
    /// when the bind is NOT a T-pose — Geno's is an A-pose, and mixing an A reference with a
    /// T reference droops every arm by the difference.
    tpose_bvh: ?[]const u8,
) !Character {
    // ★ Retarget scratch is sized to the LARGEST skeleton any character in this scene has,
    // not to this one's. A 78-joint Mixamo rig driven by a 96-joint capture reads 96 source
    // rotations, and sizing to 78 would overrun.
    const max_scene_joint_count: usize = 128;
    const model: d3.FbxModel = try d3.loadFbxModel(gpa, fbx_bytes, .{
        .recompute_normals = recompute_normals,
        .scale = cm_to_m,
    });
    errdefer d3.unloadFbxModel(gpa, model);

    const n: usize = model.clip.boneCount();
    const skin: []Mat = try gpa.alloc(Mat, n);
    errdefer gpa.free(skin);
    const positions: []Vec = try gpa.alloc(Vec, n);
    errdefer gpa.free(positions);
    const rotations: []Quat = try gpa.alloc(Quat, n);
    errdefer gpa.free(rotations);

    // Retarget scratch. Sized to this character's own joint count; the source may have more or
    // fewer, which is exactly what the map exists to bridge.
    const source_of_target: []i32 = try gpa.alloc(i32, n);
    errdefer gpa.free(source_of_target);
    const target_parents: []i32 = try gpa.alloc(i32, n);
    errdefer gpa.free(target_parents);
    for (0..n) |joint| {
        target_parents[joint] = model.clip.skeleton.bones[joint].parent;
    }
    const rest_alignment: []Quat = try gpa.alloc(Quat, n);
    errdefer gpa.free(rest_alignment);
    for (rest_alignment) |*correction| {
        correction.* = zm.quat_identity;
    }
    const rest_orientations: []Quat = try gpa.alloc(Quat, n);
    // ★ T-pose world POSITIONS, kept because the twist offsets need bone DIRECTIONS and the
    // `bindPose` is Geno's A-POSE — a different pose entirely.
    const rest_positions: []Vec = try gpa.alloc(Vec, n);
    errdefer gpa.free(rest_orientations);
    errdefer gpa.free(rest_positions);
    // ── ★★★ THE REFERENCE POSE: BIND ORIENTATIONS, NOT DERIVED ONES ──
    //
    // Every character here comes from an FBX, and an FBX states each joint's true world
    // orientation at bind in its skin clusters' `TransformLink`. That is a REAL pose, unlike
    // one inferred from bone directions — Mixamo's offsets sit in rotated local frames, so
    // FK-ing them with identity rotations puts the hand straight up above the shoulder and the
    // foot ABOVE the hips.
    //
    // ★ Deriving is kept as the fallback for a skeleton with no bind data (a bare BVH), where
    // rest rotations genuinely are identity and the derivation holds.
    if (tpose_bvh) |tpose_bytes| {
        try referenceOrientationsFromTPoseBvh(
            gpa,
            tpose_bytes,
            model.clip,
            rest_orientations,
            rest_positions,
        );
    } else {
        d3.fbxBindOrientations(model, rest_orientations);
        // ★ No T-pose file: fall back to the FBX bind's own world positions, which for a Mixamo
        // rig IS a T-pose.
        const bind_pose: [*]z.types.Transform =
            @ptrCast(@alignCast(model.clip.skeleton.bindPose));
        for (0..n) |joint| {
            const parent: i32 = target_parents[joint];
            rest_positions[joint] = if (parent < 0)
                bind_pose[joint].translation
            else
                rest_positions[@intCast(parent)] +
                    zm.rotate(rest_orientations[@intCast(parent)], bind_pose[joint].translation);
        }
    }
    if (tpose_bvh == null) {
        var bind_is_present: bool = false;
        for (rest_orientations[0..n]) |orientation| {
            const is_identity: bool = @abs(@abs(orientation[3]) - 1.0) < 1.0e-4;
            if (!is_identity) {
                bind_is_present = true;
                break;
            }
        }
        if (!bind_is_present) {
            const rest_offsets: []Vec = try gpa.alloc(Vec, n);
            defer gpa.free(rest_offsets);
            const rest_pose: [*]z.types.Transform =
                @ptrCast(@alignCast(model.clip.skeleton.bindPose));
            for (0..n) |joint| {
                rest_offsets[joint] = rest_pose[joint].translation;
            }
            z.codecs.bvh.restBoneOrientations(target_parents, rest_offsets, rest_orientations);
        }
    }
    const source_positions: []Vec = try gpa.alloc(Vec, max_scene_joint_count);
    errdefer gpa.free(source_positions);
    const source_global_rotations: []Quat = try gpa.alloc(Quat, max_scene_joint_count);
    errdefer gpa.free(source_global_rotations);
    const retargeted_local_rotations: []Quat = try gpa.alloc(Quat, n);
    errdefer gpa.free(retargeted_local_rotations);
    const retargeted_global_rotations: []Quat = try gpa.alloc(Quat, n);
    errdefer gpa.free(retargeted_global_rotations);

    const mesh_count: usize = @intCast(model.model.meshCount);
    const base: [][]f32 = try gpa.alloc([]f32, mesh_count);
    errdefer gpa.free(base);
    const skinned: [][]f32 = try gpa.alloc([]f32, mesh_count);
    errdefer gpa.free(skinned);
    const base_n: [][]f32 = try gpa.alloc([]f32, mesh_count);
    errdefer gpa.free(base_n);
    const skinned_n: [][]f32 = try gpa.alloc([]f32, mesh_count);
    errdefer gpa.free(skinned_n);
    for (0..mesh_count) |m| {
        const mesh: z.Mesh = model.model.meshes[m];
        const vc: usize = @intCast(mesh.vertexCount);
        base[m] = try gpa.alloc(f32, vc * 3);
        @memcpy(base[m], mesh.vertices[0 .. vc * 3]);
        skinned[m] = try gpa.alloc(f32, vc * 3);
        base_n[m] = try gpa.alloc(f32, vc * 3);
        @memcpy(base_n[m], mesh.normals[0 .. vc * 3]);
        skinned_n[m] = try gpa.alloc(f32, vc * 3);
    }

    return .{
        .model = model,
        .clip = external orelse model.clip,
        .owns_clip = external != null,
        .offset = offset,
        .label = label,
        // Starts playing its own clip: no retarget until the UI asks for one.
        .source_character = self_index,
        .source_of_target = source_of_target,
        .mapped_joint_count = 0,
        .target_parents = target_parents,
        .rest_alignment = rest_alignment,
        .rest_orientations = rest_orientations,
        .rest_positions = rest_positions,
        .source_positions = source_positions,
        .source_global_rotations = source_global_rotations,
        .retargeted_local_rotations = retargeted_local_rotations,
        .retargeted_global_rotations = retargeted_global_rotations,
        .hip_height = rootHeightAtRest(model.clip),
        .skin = skin,
        .positions = positions,
        .rotations = rotations,
        .base_positions = base,
        .skinned = skinned,
        .base_normals = base_n,
        .skinned_normals = skinned_n,
    };
}

/// Build the ground plane and everything needed to draw it with `lit_shadow`.
///
/// ── ★ WHY THE GROUND GETS ITS OWN PIPELINE ──
///
/// `drawCubeTexture` and `drawMeshInstanced` both bind pipelines the engine owns
/// (`cube3d_fs`), which know nothing about a shadow map. Receiving a shadow means running
/// `lit_shadow_fs`, and that means building the pipeline here: shader modules, three bind-group
/// layouts, a pipeline layout, two UBOs and a sampler. `examples/shadowmap` is large mostly
/// because of this scaffolding, and there is no shortcut around it.
///
/// The plane is a static mesh, so its buffers are created ONCE with `createBufferInit` rather
/// than going through the retained registry — that registry exists for meshes the engine draws,
/// and this one is drawn by hand.
/// Build the G-buffer targets and the prepass pipeline.
///
/// ★ SIZED TO THE SHADOW MAP, NOT THE WINDOW. A G-buffer normally matches the backbuffer, but
/// that means rebuilding it on every resize — and SSAO at HALF resolution is the standard
/// trade (the plan's adversarial point 3 flagged attachment memory on mobile). A fixed square
/// keeps this phase simple and the memory bounded; matching the window is a later refinement
/// once the AO is known to be correct.
fn initGbuffer(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const dim: u32 = gbuffer_size;

    s.gbuf_pos = z.RenderTexture.create(device, .{
        .width = dim,
        .height = dim,
        .format = .rgba16_float,
        .with_depth = true,
        .depth_format = .depth24_plus,
        .label = "gd_gbuf_pos",
    });
    s.gbuf_normal = z.RenderTexture.create(device, .{
        .width = dim,
        .height = dim,
        .format = .rgba16_float,
        .label = "gd_gbuf_normal",
    });
    s.gbuf_albedo = z.RenderTexture.create(device, .{
        .width = dim,
        .height = dim,
        .format = .rgba8_unorm,
        .label = "gd_gbuf_albedo",
    });

    s.gbuf_bgls[0] =
        try z.gpu.uniformBindGroupLayout(gpa, device, gbuf_vs_bytes, .{ .vertex = true }, "gd_gbuf_g0");
    s.gbuf_bgls[1] =
        try z.gpu.uniformBindGroupLayout(gpa, device, gbuf_fs_bytes, .{ .fragment = true }, "gd_gbuf_g2");
    // gbuffer_vs/fs use groups 0 and 2; group 1 is empty but must still exist in the layout.
    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, &.{}, "gd_gbuf_empty");
    s.gbuf_pl = z.wgpu.createPipelineLayout(
        device,
        &.{ s.gbuf_bgls[0], empty_bgl, s.gbuf_bgls[1] },
        "gd_gbuf_pl",
    );

    for (0..s.gbuf_vs_ubos.len) |i| {
        s.gbuf_vs_ubos[i] = z.wgpu.createBuffer(device, .{
            .size = gbuf_vs_bytes,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "gd_gbuf_vs_ubo",
        });
        s.gbuf_fs_ubos[i] = z.wgpu.createBuffer(device, .{
            .size = gbuf_fs_bytes,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "gd_gbuf_fs_ubo",
        });
        s.gbuf_g0[i] = try z.gpu.uniformBindGroup(
            gpa,
            device,
            s.gbuf_bgls[0],
            s.gbuf_vs_ubos[i],
            gbuf_vs_bytes,
            "gd_gbuf_g0_bg",
        );
        s.gbuf_g2[i] = try z.gpu.uniformBindGroup(
            gpa,
            device,
            s.gbuf_bgls[1],
            s.gbuf_fs_ubos[i],
            gbuf_fs_bytes,
            "gd_gbuf_g2_bg",
        );
    }

    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_vs_wgsl, "gbuffer_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, gbuffer_fs_wgsl, "gbuffer_fs");
    const layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(GroundVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none, // no blend — a G-buffer stores data, not colour to mix
        .less,
        .none,
        .rgba16_float, // location 0: world position
        .depth24_plus,
        1,
    );
    const blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = combo,
        // ★ The MRT tail: locations 1 and 2. Their formats must match the render textures
        // bound at those slots or pipeline creation is rejected.
        .extra_color_formats = &.{ .rgba16_float, .rgba8_unorm },
    });
    defer gpa.free(blob);
    s.gbuf_pipeline =
        z.wgpu.createRenderPipeline(device, s.gbuf_pl, vs_mod, fs_mod, blob, "gd_gbuf_pipe");
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
}

/// Build the SSAO target, sampler, pipeline and bind groups.
fn initSsao(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;

    s.ssao_rt = z.RenderTexture.create(device, .{
        .width = gbuffer_size,
        .height = gbuffer_size,
        .format = .rgba8_unorm,
        // ★ Depth attachment even though a fullscreen quad needs no depth TEST: the pipeline's
        // state combo must name a depth format, and it has to match the pass's attachments.
        // `deferred_render`'s shading pass does the same and notes why the test still passes —
        // the quad sits at z=0 against a cleared depth of 1.0.
        .with_depth = true,
        .depth_format = .depth24_plus,
        .label = "gd_ssao_rt",
    });
    // ★ NEAREST. A FILTERED world position is a point on no surface, and the occlusion test
    // against it is meaningless — the same reason the shadow map wants nearest, and the second
    // half of the bug that made the shadows band.
    s.ssao_sampler = z.wgpu.createSampler(device, .{
        .mag_filter_linear = false,
        .min_filter_linear = false,
        .address_mode = .clamp_to_edge,
    });

    const g1_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
        .{ .binding = 2, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 3, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    };
    const g1_layout_blob: []const u8 =
        try z.gpu.encodeBindGroupLayoutEntries(gpa, &g1_entries);
    defer gpa.free(g1_layout_blob);
    s.ssao_bgls[0] = z.wgpu.createBindGroupLayout(device, g1_layout_blob, "gd_ssao_g1");
    const g1_binds = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .texture_view = s.gbuf_pos.color_view } },
        .{ .binding = 1, .resource = .{ .sampler = s.ssao_sampler } },
        .{ .binding = 2, .resource = .{ .texture_view = s.gbuf_normal.color_view } },
        .{ .binding = 3, .resource = .{ .sampler = s.ssao_sampler } },
    };
    const g1_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g1_binds);
    defer gpa.free(g1_blob);
    s.ssao_g1 = z.wgpu.createBindGroup(device, s.ssao_bgls[0], g1_blob, "gd_ssao_g1_bg");

    s.ssao_bgls[1] = try z.gpu.uniformBindGroupLayout(
        gpa,
        device,
        ssao_ubo_bytes,
        .{ .fragment = true },
        "gd_ssao_g2",
    );
    s.ssao_ubo = z.wgpu.createBuffer(device, .{
        .size = ssao_ubo_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
        .label = "gd_ssao_ubo",
    });
    s.ssao_g2 = try z.gpu.uniformBindGroup(
        gpa,
        device,
        s.ssao_bgls[1],
        s.ssao_ubo,
        ssao_ubo_bytes,
        "gd_ssao_g2_bg",
    );

    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, &.{}, "gd_ssao_empty");
    s.ssao_pl = z.wgpu.createPipelineLayout(
        device,
        &.{ empty_bgl, s.ssao_bgls[0], s.ssao_bgls[1] },
        "gd_ssao_pl",
    );

    s.fullscreen_vbo = z.wgpu.createBufferInit(
        device,
        f.gpu.queue,
        std.mem.sliceAsBytes(fullscreen_verts[0..]),
        .{ .vertex = true, .copy_dst = true },
        "gd_fullscreen_vbo",
    );

    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, fullscreen_vs_wgsl, "deferred_shading_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, ssao_fs_wgsl, "ssao_fs");
    const ndc_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf([2]f32),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        },
    };
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less, // quad at z=0 against cleared depth 1.0 — always passes
        .none,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{ndc_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = combo,
    });
    defer gpa.free(blob);
    s.ssao_pipeline =
        z.wgpu.createRenderPipeline(device, s.ssao_pl, vs_mod, fs_mod, blob, "gd_ssao_pipe");
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
}

/// Build the bilateral blur's target, pipeline and the two bind-group pairs.
fn initSsaoBlur(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;

    s.ssao_blur_rt = z.RenderTexture.create(device, .{
        .width = gbuffer_size,
        .height = gbuffer_size,
        .format = .rgba8_unorm,
        .with_depth = true,
        .depth_format = .depth24_plus,
        .label = "gd_ssao_blur_rt",
    });

    // Three texture+sampler pairs: the AO source, plus the two G-buffer channels that tell the
    // blur where the edges are.
    const g1_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
        .{ .binding = 2, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 3, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
        .{ .binding = 4, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 5, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    };
    const g1_layout_blob: []const u8 = try z.gpu.encodeBindGroupLayoutEntries(gpa, &g1_entries);
    defer gpa.free(g1_layout_blob);
    s.ssao_blur_bgls[0] = z.wgpu.createBindGroupLayout(device, g1_layout_blob, "gd_blur_g1");

    // Two bind groups differing ONLY in which texture is the source — the ping and the pong.
    const sources = [_]z.wgpu.TextureViewHandle{ s.ssao_rt.color_view, s.ssao_blur_rt.color_view };
    for (sources, 0..) |src_view, i| {
        const binds = [_]z.gpu.BindGroupEntry{
            .{ .binding = 0, .resource = .{ .texture_view = src_view } },
            .{ .binding = 1, .resource = .{ .sampler = s.ssao_sampler } },
            .{ .binding = 2, .resource = .{ .texture_view = s.gbuf_pos.color_view } },
            .{ .binding = 3, .resource = .{ .sampler = s.ssao_sampler } },
            .{ .binding = 4, .resource = .{ .texture_view = s.gbuf_normal.color_view } },
            .{ .binding = 5, .resource = .{ .sampler = s.ssao_sampler } },
        };
        const blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &binds);
        defer gpa.free(blob);
        s.ssao_blur_g1[i] = z.wgpu.createBindGroup(device, s.ssao_blur_bgls[0], blob, "gd_blur_g1_bg");
    }

    s.ssao_blur_bgls[1] = try z.gpu.uniformBindGroupLayout(
        gpa,
        device,
        ssao_blur_ubo_bytes,
        .{ .fragment = true },
        "gd_blur_g2",
    );
    for (0..s.ssao_blur_ubos.len) |i| {
        s.ssao_blur_ubos[i] = z.wgpu.createBuffer(device, .{
            .size = ssao_blur_ubo_bytes,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "gd_blur_ubo",
        });
        s.ssao_blur_g2[i] = try z.gpu.uniformBindGroup(
            gpa,
            device,
            s.ssao_blur_bgls[1],
            s.ssao_blur_ubos[i],
            ssao_blur_ubo_bytes,
            "gd_blur_g2_bg",
        );
    }

    const empty_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, &.{}, "gd_blur_empty");
    s.ssao_blur_pl = z.wgpu.createPipelineLayout(
        device,
        &.{ empty_bgl, s.ssao_blur_bgls[0], s.ssao_blur_bgls[1] },
        "gd_blur_pl",
    );
    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, fullscreen_vs_wgsl, "deferred_shading_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, ssao_blur_fs_wgsl, "ssao_blur_fs");
    const ndc_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf([2]f32),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
        },
    };
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .none,
        .rgba8_unorm,
        .depth24_plus,
        1,
    );
    const blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{ndc_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = combo,
    });
    defer gpa.free(blob);
    s.ssao_blur_pipeline =
        z.wgpu.createRenderPipeline(device, s.ssao_blur_pl, vs_mod, fs_mod, blob, "gd_blur_pipe");
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);
    z.wgpu.destroyBindGroupLayout(empty_bgl);
}

/// One axis of the bilateral blur.
///
/// ★ SEPARABLE: two 7-tap passes give the reach of a 49-tap square for 14 samples. The
/// bilateral weights are not strictly separable in theory, but the error is invisible against
/// the noise this exists to remove — the standard trade every SSAO blur makes.
fn drawSsaoBlurPass(s: *State, f: *z.Frame, pass_index: usize) void {
    const gl: *z.WgpuGl = f.gl;
    const target: z.RenderTexture = if (pass_index == 0) s.ssao_blur_rt else s.ssao_rt;
    z.beginTextureModeRaw(gl, target, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const ps: *z.PassState = gl.pass;
    ps.queue = f.gpu.queue;

    const texel: f32 = 1.0 / float(gbuffer_size);
    const ubo: SsaoBlurUbo = .{
        .step = if (pass_index == 0)
            .{ texel, texel, 1, 0 }
        else
            .{ texel, texel, 0, 1 },
        .weights = .{ s.blur_falloff, s.blur_normal_power, 0, 0 },
    };
    const bytes: [z.shader.wireSizeOf(SsaoBlurUbo)]u8 = z.shader.wireOf(SsaoBlurUbo, &ubo);
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.ssao_blur_ubos[pass_index], 0, &bytes);

    const Backend: type = z.WgpuBackend;
    Backend.setPipeline(ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.ssao_blur_pipeline });
    Backend.setBindGroup(ps, 1, s.ssao_blur_g1[pass_index]);
    Backend.setBindGroup(ps, 2, s.ssao_blur_g2[pass_index]);
    z.render_pass.setVertexBuffer(ps.pass, .{
        .slot = 0,
        .buffer = s.fullscreen_vbo,
        .offset = 0,
        .size = @sizeOf(@TypeOf(fullscreen_verts)),
    });
    z.render_pass.draw(ps.pass, .{
        .vertex_count = 6,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    z.endTextureModeRaw(gl);
}

/// Run the AO pass over the G-buffer.
fn drawSsao(s: *State, f: *z.Frame, view: Mat) void {
    const gl: *z.WgpuGl = f.gl;
    z.beginTextureModeRaw(gl, s.ssao_rt, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const ps: *z.PassState = gl.pass;
    ps.queue = f.gpu.queue;
    const inv_dim: f32 = 1.0 / float(gbuffer_size);
    const ubo: SsaoUbo = .{
        .view = view,
        .params = .{ s.ssao_radius, s.ssao_bias, s.ssao_intensity, 0 },
        // 7 turns: coprime with the 9 samples, so the spiral does not collapse into spokes.
        .spiral = .{ 7.0, inv_dim, inv_dim, 0 },
    };
    const bytes: [z.shader.wireSizeOf(SsaoUbo)]u8 = z.shader.wireOf(SsaoUbo, &ubo);
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.ssao_ubo, 0, &bytes);

    const Backend: type = z.WgpuBackend;
    Backend.setPipeline(ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.ssao_pipeline });
    Backend.setBindGroup(ps, 1, s.ssao_g1);
    Backend.setBindGroup(ps, 2, s.ssao_g2);
    z.render_pass.setVertexBuffer(ps.pass, .{
        .slot = 0,
        .buffer = s.fullscreen_vbo,
        .offset = 0,
        .size = @sizeOf(@TypeOf(fullscreen_verts)),
    });
    z.render_pass.draw(ps.pass, .{
        .vertex_count = 6,
        .instance_count = 1,
        .first_vertex = 0,
        .first_instance = 0,
    });
    z.endTextureModeRaw(gl);
}

fn initGround(
    gpa: Allocator,
    f: *z.Frame,
    s: *State,
    shadow_rt: z.RenderTexture,
) !void {
    const device: z.wgpu.DeviceHandle = f.gpu.device;
    const queue: z.wgpu.QueueHandle = f.gpu.queue;

    var plane: z.Mesh = try z.genMeshPlane(gpa, ground_extent * 2.0, ground_extent * 2.0, 1, 1);
    defer z.unloadMesh(gpa, plane);
    const vcount: usize = @intCast(plane.vertexCount);
    const icount: usize = @intCast(plane.triangleCount * 3);

    // Interleave into the pos+normal layout the shadow pipeline declares.
    const verts: []GroundVertex = try gpa.alloc(GroundVertex, vcount);
    defer gpa.free(verts);
    for (0..vcount) |i| {
        verts[i] = .{
            .pos = .{
                plane.vertices[i * 3 + 0],
                plane.vertices[i * 3 + 1],
                plane.vertices[i * 3 + 2],
            },
            .normal = if (plane.normals != null)
                .{ plane.normals[i * 3 + 0], plane.normals[i * 3 + 1], plane.normals[i * 3 + 2] }
            else
                .{ 0, 1, 0 },
        };
    }
    s.ground_vbo = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(verts),
        .{ .vertex = true, .copy_dst = true },
        "gd_ground_vbo",
    );
    s.ground_ibo = z.wgpu.createBufferInit(
        device,
        queue,
        std.mem.sliceAsBytes(plane.indices[0..icount]),
        .{ .index = true, .copy_dst = true },
        "gd_ground_ibo",
    );
    s.ground_index_count = @intCast(icount);

    // ---- bind-group layouts: VS uniforms at 0, samplers at 1, FS uniforms at 2 ----
    const g0_bgl: z.wgpu.BindGroupLayoutHandle =
        try z.gpu.uniformBindGroupLayout(gpa, device, lit_vs_bytes, .{ .vertex = true }, "gd_lit_g0");
    const g2_bgl: z.wgpu.BindGroupLayoutHandle =
        try z.gpu.uniformBindGroupLayout(gpa, device, lit_fs_bytes, .{ .fragment = true }, "gd_lit_g2");

    const g1_layout_entries = [_]z.shader_introspect.BindGroupLayoutEntry{
        .{ .binding = 0, .visibility = .{ .fragment = true }, .resource = .{ .texture = .{} } },
        .{ .binding = 1, .visibility = .{ .fragment = true }, .resource = .{ .sampler = .{} } },
    };
    const g1_layout_blob: []const u8 =
        try z.gpu.encodeBindGroupLayoutEntries(gpa, &g1_layout_entries);
    defer gpa.free(g1_layout_blob);
    const g1_bgl: z.wgpu.BindGroupLayoutHandle =
        z.wgpu.createBindGroupLayout(device, g1_layout_blob, "gd_lit_g1");
    const g1_entries = [_]z.gpu.BindGroupEntry{
        .{ .binding = 0, .resource = .{ .texture_view = shadow_rt.color_view } },
        .{ .binding = 1, .resource = .{ .sampler = s.shadow_sampler } },
    };
    const g1_blob: []const u8 = try z.gpu.encodeBindGroupEntries(gpa, &g1_entries);
    defer gpa.free(g1_blob);
    s.ground_g1 = z.wgpu.createBindGroup(device, g1_bgl, g1_blob, "gd_lit_g1_bg");

    // ---- the two uniform buffers, rewritten every frame ----
    s.ground_vs_ubo = z.wgpu.createBuffer(device, .{
        .size = lit_vs_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
        .label = "gd_lit_vs_ubo",
    });
    s.ground_fs_ubo = z.wgpu.createBuffer(device, .{
        .size = lit_fs_bytes,
        .usage = .{ .uniform = true, .copy_dst = true },
        .label = "gd_lit_fs_ubo",
    });
    s.ground_g0 = try z.gpu.uniformBindGroup(gpa, device, g0_bgl, s.ground_vs_ubo, lit_vs_bytes, "gd_g0_bg");
    s.ground_g2 = try z.gpu.uniformBindGroup(gpa, device, g2_bgl, s.ground_fs_ubo, lit_fs_bytes, "gd_g2_bg");

    // ---- the pipeline ----
    const bgls = [_]z.wgpu.BindGroupLayoutHandle{ g0_bgl, g1_bgl, g2_bgl };
    const pl: z.wgpu.PipelineLayoutHandle =
        z.wgpu.createPipelineLayout(device, bgls[0..], "gd_lit_pl");
    s.ground_bgls = bgls;
    s.ground_pl = pl;
    const vs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, lit_vs_wgsl, "lit_shadow_vs");
    const fs_mod: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, lit_fs_wgsl, "lit_shadow_fs");
    const layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(GroundVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x3, .offset = 12, .shader_location = 1 },
        },
    };
    // ★ The state combo must match the SCREEN pass's attachments exactly — format, depth
    // format and sample count. A mismatch is rejected at pipeline creation, which is the good
    // case; the bad case is a silently incompatible pass.
    const combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .alpha,
        .less,
        .none,
        f.gpu.backbuffer_format,
        .depth24_plus,
        1,
    );
    const blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = combo,
    });
    defer gpa.free(blob);
    s.ground_pipeline =
        z.wgpu.createRenderPipeline(device, pl, vs_mod, fs_mod, blob, "gd_lit_pipe");
    z.wgpu.destroyShaderModule(vs_mod);
    z.wgpu.destroyShaderModule(fs_mod);

    // ── ★ THE LIGHT PASS NEEDS A REAL DEPTH MAP, NOT A MASK ──
    //
    // The mask was the cheap first step and it produced an INVERTED shadow, because
    // `lit_shadow_fs` does a DEPTH COMPARISON: it reads the map as a distance-from-light and
    // shadows a fragment whose own distance is greater. Feeding it white-on-black meant the
    // empty parts of the map (0.0 = "very near") shadowed the whole frustum footprint, while
    // the silhouettes (1.0 = "very far") came out lit — a dark square with a bright figure in
    // it, exactly what the device showed.
    //
    // `depth_vs/fs` in `mode = 0` writes `ndc_z*0.5+0.5`, which is precisely the quantity
    // `lit_shadow_fs` expects. The two shaders are a matched pair; substituting for either
    // half is what went wrong.
    s.depth_bgl = try z.gpu.uniformBindGroupLayout(gpa, device, depth_ubo_bytes, .{ .vertex = true }, "gd_depth_bgl");
    const depth_bgls = [_]z.wgpu.BindGroupLayoutHandle{s.depth_bgl};
    s.depth_pl = z.wgpu.createPipelineLayout(device, depth_bgls[0..], "gd_depth_pl");
    const dvs: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, depth_vs_wgsl, "depth_vs");
    const dfs: z.wgpu.ShaderModuleHandle =
        z.wgpu.createShaderModuleWgsl(device, depth_fs_wgsl, "depth_fs");
    // The depth pass reads POSITION ONLY, but the stride must still match the character VBOs
    // it draws from — those are pos+normal.
    const depth_layout = z.gpu.VertexBufferLayout{
        .array_stride = @sizeOf(GroundVertex),
        .step_mode = .vertex,
        .attributes = &.{
            .{ .format = .float32x3, .offset = 0, .shader_location = 0 },
        },
    };
    const depth_combo: z.gpu.StateCombo = z.gpu.StateCombo.fromParts(
        .triangle_list,
        .none,
        .less,
        .none,
        .rgba16_float,
        .depth24_plus,
        1,
    );
    const depth_blob: []const u8 = try z.gpu.encodeRenderPipelineDescriptor(gpa, .{
        .vertex_buffer_layouts = &.{depth_layout},
        .vs_entry_point = "entry",
        .fs_entry_point = "entry",
        .state = depth_combo,
    });
    defer gpa.free(depth_blob);
    s.depth_pipeline =
        z.wgpu.createRenderPipeline(device, s.depth_pl, dvs, dfs, depth_blob, "gd_depth_pipe");
    z.wgpu.destroyShaderModule(dvs);
    z.wgpu.destroyShaderModule(dfs);

    for (0..s.char_vs_ubos.len) |i| {
        s.char_vs_ubos[i] = z.wgpu.createBuffer(device, .{
            .size = lit_vs_bytes,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "gd_char_vs_ubo",
        });
        s.char_fs_ubos[i] = z.wgpu.createBuffer(device, .{
            .size = lit_fs_bytes,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "gd_char_fs_ubo",
        });
        s.char_g0[i] =
            try z.gpu.uniformBindGroup(gpa, device, g0_bgl, s.char_vs_ubos[i], lit_vs_bytes, "gd_char_g0");
        s.char_g2[i] =
            try z.gpu.uniformBindGroup(gpa, device, g2_bgl, s.char_fs_ubos[i], lit_fs_bytes, "gd_char_g2");
    }

    for (0..s.depth_ubos.len) |i| {
        s.depth_ubos[i] = z.wgpu.createBuffer(device, .{
            .size = depth_ubo_bytes,
            .usage = .{ .uniform = true, .copy_dst = true },
            .label = "gd_depth_ubo",
        });
        s.depth_bgs[i] = try z.gpu.uniformBindGroup(
            gpa,
            device,
            s.depth_bgl,
            s.depth_ubos[i],
            depth_ubo_bytes,
            "gd_depth_bg",
        );
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    const font: z.Font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20);

    // An 8x8 checkerboard in mid-greys, like GenoView's floor. The squares come from the
    // IMAGE rather than from tiled UVs, because the cube's UVs run 0..1 across each face.
    const checker: z.Image = try z.genImageChecked(gpa, 64, 64, 8, 8, ground_light, ground_dark);
    defer z.unloadImage(gpa, checker);
    const ground: z.WgpuTexture = z.loadTextureFromImage(f.gl, checker);
    const light_view: z.RenderTexture = z.RenderTexture.create(f.gpu.device, .{
        .width = shadow_map_size,
        .height = shadow_map_size,
        .format = .rgba16_float,
        .with_depth = true,
        .depth_format = .depth24_plus,
        .label = "gd_shadow_rt",
    });
    const shadow_sampler: z.wgpu.SamplerHandle = z.wgpu.createSampler(f.gpu.device, .{
        .mag_filter_linear = false,
        .min_filter_linear = false,
        .address_mode = .clamp_to_edge,
    });

    // Geno borrows the dance capture; the skeletons match bone-for-bone so no retarget is
    // needed. The Mixamo rig plays its own take and needs nothing external.
    var dance_data: z.codecs.bvh.Data = try z.codecs.bvh.parse(gpa, dance_bvh, null);
    defer dance_data.deinit();
    const dance: d3.BvhSkeletalClip = try d3.loadBvhSkeletalClip(gpa, dance_data);
    errdefer d3.unloadBvhSkeletalClip(gpa, dance);
    // ★ The borrowed clip must share the character's scale — see `scaleBvhSkeletalClip`.
    d3.scaleBvhSkeletalClip(dance, cm_to_m);

    s.* = .{
        .ui_host = z.UiHost.init(gpa, font),
        .font = font,
        .cam = z.OrbitCamera.init(vec(0, 0.9, 0), 4.2),
        .gpa = gpa,
        .ground = ground,
        // Filled by `initGround` below, which needs the State to exist first.
        .ground_pipeline = undefined,
        .ground_vbo = undefined,
        .ground_ibo = undefined,
        .ground_index_count = 0,
        .ground_vs_ubo = undefined,
        .ground_fs_ubo = undefined,
        .ground_g0 = undefined,
        .ground_g1 = undefined,
        .ground_g2 = undefined,
        .ground_bgls = undefined,
        .ground_pl = undefined,
        .depth_pipeline = undefined,
        .depth_pl = undefined,
        .depth_bgl = undefined,
        .depth_ubos = undefined,
        .depth_bgs = undefined,
        .char_vs_ubos = undefined,
        .char_fs_ubos = undefined,
        .char_g0 = undefined,
        .char_g2 = undefined,
        .light_view = light_view,
        .shadow_sampler = shadow_sampler,
        .gbuf_pos = undefined,
        .gbuf_normal = undefined,
        .gbuf_albedo = undefined,
        .gbuf_pipeline = undefined,
        .gbuf_pl = undefined,
        .gbuf_bgls = undefined,
        .gbuf_vs_ubos = undefined,
        .gbuf_fs_ubos = undefined,
        .gbuf_g0 = undefined,
        .gbuf_g2 = undefined,
        .ssao_rt = undefined,
        .ssao_pipeline = undefined,
        .ssao_pl = undefined,
        .ssao_bgls = undefined,
        .ssao_ubo = undefined,
        .ssao_g1 = undefined,
        .ssao_g2 = undefined,
        .ssao_sampler = undefined,
        .ssao_blur_rt = undefined,
        .ssao_blur_pipeline = undefined,
        .ssao_blur_pl = undefined,
        .ssao_blur_bgls = undefined,
        .ssao_blur_ubos = undefined,
        .ssao_blur_g2 = undefined,
        .ssao_blur_g1 = undefined,
        .robot_doc = undefined,
        .robot_spec = undefined,
        .robot = undefined,
        .robot_data = undefined,
        .robot_reference = undefined,
        .human_of_body = undefined,
        .robot_parents = undefined,
        .robot_rest_alignment = undefined,
        .robot_local = undefined,
        .robot_global = undefined,
        .robot_positions_y_up = undefined,
        .source_delta_z_up = undefined,
        .robot_human_reference = undefined,
        .robot_axis_map = undefined,
        .robot_desired_global = undefined,
        .robot_identity_map = undefined,
        .robot_identity_alignment = undefined,
        .robot_position_weights = undefined,
        .robot_rotation_weights = undefined,
        .robot_rest_world = undefined,
        .robot_rest_rotations = undefined,
        .robot_rest_xpos = undefined,
        .robot_tpose_qpos = undefined,
        .robot_rest_xrot = undefined,
        .robot_rest_body_pos = undefined,
        .robot_rest_flexion = undefined,
        .robot_samples = undefined,
        .robot_previous_qpos = undefined,
        .robot_twist = undefined,
        .robot_parent_twist = undefined,
        .robot_limb_correction = undefined,
        .robot_tasks = undefined,
        .robot_ik_scratch = undefined,
        .fullscreen_vbo = undefined,
        .characters = .{
            // ★ Geno needs its normals rebuilt: 52.6% of the file's oppose their triangle's
            // winding, which renders as dark banding down the limbs. Mixamo's are clean, so
            // it keeps its authored normals — see `draw3d.computeMeshNormals`.
            try makeCharacter(gpa, geno_fbx, dance, vec(-0.7, 0, 0), "Geno + dance1", true, 0, geno_tpose_bvh),
            // Mixamo's FBX bind pose IS a T-pose, so no separate file is needed.
            try makeCharacter(gpa, mixamo_fbx, null, vec(0.7, 0, 0), "Mixamo Drop_Kick", false, 1, null),
        },
    };

    try initGround(gpa, f, s, light_view);
    try initRobot(gpa, s);
    try initGbuffer(gpa, f, s);
    try initSsao(gpa, f, s);
    try initSsaoBlur(gpa, f, s);

    // ★ The characters are drawn ONLY by custom pipelines from here on, and the engine's
    // upload is lazy behind `drawMeshInstanced` — so ask for it explicitly or the buffers
    // never exist and both passes silently draw nothing.
    for (&s.characters) |*c| {
        for (0..@intCast(c.model.model.meshCount)) |m| {
            _ = z.uploadMeshGpu(f.gl, @ptrCast(&c.model.model.meshes[m]));
        }
    }

    if (skeletonsMatch(s.characters[0].model.clip, dance)) {
        setStatus(s, "{d} + {d} bones", .{
            s.characters[0].boneCount(),
            s.characters[1].boneCount(),
        });
    } else {
        setStatus(s, "SKELETON MISMATCH on Geno", .{});
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    // Every GPU object `initGround` created — the leak checker counts bind-group layouts and
    // pipeline layouts too, not just buffers.
    z.wgpu.destroyRenderPipeline(s.ground_pipeline);
    z.wgpu.destroyPipelineLayout(s.ground_pl);
    for (s.ground_bgls) |bgl| {
        z.wgpu.destroyBindGroupLayout(bgl);
    }
    z.wgpu.destroyBindGroup(s.ground_g0);
    z.wgpu.destroyBindGroup(s.ground_g1);
    z.wgpu.destroyBindGroup(s.ground_g2);
    z.wgpu.destroyBuffer(s.ground_vbo);
    z.wgpu.destroyBuffer(s.ground_ibo);
    z.wgpu.destroyBuffer(s.ground_vs_ubo);
    z.wgpu.destroyBuffer(s.ground_fs_ubo);
    z.wgpu.destroyRenderPipeline(s.depth_pipeline);
    z.wgpu.destroyPipelineLayout(s.depth_pl);
    z.wgpu.destroyBindGroupLayout(s.depth_bgl);
    for (s.depth_ubos) |b| {
        z.wgpu.destroyBuffer(b);
    }
    for (s.depth_bgs) |bg| {
        z.wgpu.destroyBindGroup(bg);
    }
    for (s.char_vs_ubos) |b| {
        z.wgpu.destroyBuffer(b);
    }
    for (s.char_fs_ubos) |b| {
        z.wgpu.destroyBuffer(b);
    }
    for (s.char_g0) |bg| {
        z.wgpu.destroyBindGroup(bg);
    }
    for (s.char_g2) |bg| {
        z.wgpu.destroyBindGroup(bg);
    }
    s.ground.deinit();
    s.light_view.deinit();
    s.robot_data.deinit();
    s.robot.deinit();
    s.robot_spec.deinit();
    s.robot_doc.deinit();
    gpa.free(s.robot_reference);
    gpa.free(s.human_of_body);
    gpa.free(s.robot_parents);
    gpa.free(s.robot_rest_alignment);
    gpa.free(s.robot_local);
    gpa.free(s.robot_global);
    gpa.free(s.robot_positions_y_up);
    gpa.free(s.source_delta_z_up);
    gpa.free(s.robot_human_reference);
    gpa.free(s.robot_axis_map);
    gpa.free(s.robot_desired_global);
    gpa.free(s.robot_identity_map);
    gpa.free(s.robot_identity_alignment);
    gpa.free(s.robot_position_weights);
    gpa.free(s.robot_rotation_weights);
    gpa.free(s.robot_rest_world);
    gpa.free(s.robot_rest_rotations);
    gpa.free(s.robot_rest_xpos);
    gpa.free(s.robot_tpose_qpos);
    gpa.free(s.robot_rest_xrot);
    gpa.free(s.robot_rest_body_pos);
    gpa.free(s.robot_rest_flexion);
    gpa.free(s.robot_samples);
    gpa.free(s.robot_previous_qpos);
    gpa.free(s.robot_twist);
    gpa.free(s.robot_parent_twist);
    gpa.free(s.robot_limb_correction);
    gpa.free(s.robot_tasks);
    gpa.free(s.robot_ik_scratch);
    z.wgpu.destroySampler(s.shadow_sampler);
    s.gbuf_pos.deinit();
    s.gbuf_normal.deinit();
    s.gbuf_albedo.deinit();
    z.wgpu.destroyRenderPipeline(s.gbuf_pipeline);
    z.wgpu.destroyPipelineLayout(s.gbuf_pl);
    for (s.gbuf_bgls) |b| {
        z.wgpu.destroyBindGroupLayout(b);
    }
    for (s.gbuf_vs_ubos) |b| {
        z.wgpu.destroyBuffer(b);
    }
    for (s.gbuf_fs_ubos) |b| {
        z.wgpu.destroyBuffer(b);
    }
    for (s.gbuf_g0) |bg| {
        z.wgpu.destroyBindGroup(bg);
    }
    for (s.gbuf_g2) |bg| {
        z.wgpu.destroyBindGroup(bg);
    }
    s.ssao_rt.deinit();
    z.wgpu.destroyRenderPipeline(s.ssao_pipeline);
    z.wgpu.destroyPipelineLayout(s.ssao_pl);
    for (s.ssao_bgls) |b| {
        z.wgpu.destroyBindGroupLayout(b);
    }
    z.wgpu.destroyBuffer(s.ssao_ubo);
    z.wgpu.destroyBuffer(s.fullscreen_vbo);
    z.wgpu.destroyBindGroup(s.ssao_g1);
    z.wgpu.destroyBindGroup(s.ssao_g2);
    z.wgpu.destroySampler(s.ssao_sampler);
    s.ssao_blur_rt.deinit();
    z.wgpu.destroyRenderPipeline(s.ssao_blur_pipeline);
    z.wgpu.destroyPipelineLayout(s.ssao_blur_pl);
    for (s.ssao_blur_bgls) |b| {
        z.wgpu.destroyBindGroupLayout(b);
    }
    for (s.ssao_blur_ubos) |b| {
        z.wgpu.destroyBuffer(b);
    }
    for (s.ssao_blur_g1) |bg| {
        z.wgpu.destroyBindGroup(bg);
    }
    for (s.ssao_blur_g2) |bg| {
        z.wgpu.destroyBindGroup(bg);
    }
    for (&s.characters) |*c| {
        c.deinit(gpa);
    }
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
}

/// Pose one character at `time` and deform every mesh it owns.
///
/// The matrix work lives in `draw3d` — see `poseSkinMatrices`, which documents the two zm
/// conventions (argument order, and direction-vs-point vectors) that a hand-rolled version has
/// to get right. This function is only the loop over meshes.
fn poseCharacter(
    character: *Character,
    source: *const Character,
    source_is_self: bool,
    gl: *z.WgpuGl,
    time: f32,
) void {
    const source_frame_count: usize = @intCast(@max(source.clip.animation.keyframeCount, 0));
    if (source_frame_count == 0) {
        return;
    }
    var frame: usize = @trunc(@max(time / source.clip.frame_time, 0));
    if (frame >= source_frame_count) {
        frame = frame % source_frame_count;
    }

    // ★ PASSED IN, NOT INFERRED. Deriving this from `mapped_joint_count == 0` would conflate
    // "not retargeting" with "the name map found nothing" — and the second is a bug the UI
    // needs to report, not a case to silently fall back from.
    if (source_is_self) {
        // Native playback: the clip and the skeleton are the same rig, so the poses go
        // straight to the skin matrices.
        d3.poseSkinMatrices(
            source.clip,
            character.model.inverse_bind,
            frame,
            character.positions,
            character.rotations,
            character.skin,
        );
    } else {
        poseCharacterRetargeted(character, source, frame);
    }
    for (0..@intCast(character.model.model.meshCount)) |mesh_index| {
        d3.skinMeshCpu(
            character.model.model.meshes[mesh_index],
            character.base_positions[mesh_index],
            character.base_normals[mesh_index],
            character.skin,
            character.skinned[mesh_index],
            character.skinned_normals[mesh_index],
        );
        z.updateMeshGpu(gl, character.model.model.meshes[mesh_index]);
    }
}

fn update(f: *z.Frame, s: *State) void {
    const gl: *z.WgpuGl = f.gl;
    var longest: f32 = 0;
    for (&s.characters) |*c| {
        longest = @max(longest, c.duration());
    }

    if (s.playing and longest > 0) {
        s.play_time += f.time.delta_time;
        if (s.play_time >= longest) {
            s.play_time = 0;
        }
    }

    const u: ui.Ui = s.ui_host.begin(f);
    defer s.ui_host.render(f);

    // Pose and upload every character ONCE, before any pass draws them.
    // Rebuild the name maps only when a selection changed — mapping is a string compare per
    // joint pair and has no business running every frame.
    if (s.retarget_dirty) {
        s.retarget_dirty = false;
        for (0..s.characters.len) |character_index| {
            const source_index: usize = s.characters[character_index].source_character;
            if (source_index == character_index) {
                s.characters[character_index].mapped_joint_count = 0;
                continue;
            }
            // ★ A FAILED MAP MUST NOT LOOK LIKE A FAILED RETARGET. The only way this errors
            // is allocation, and swallowing it would leave a stale map driving the character —
            // indistinguishable on screen from a solver bug. Report it and fall back to the
            // character's own clip, which is visibly correct rather than subtly wrong.
            refreshRetargetMap(
                s.gpa,
                &s.characters[character_index],
                &s.characters[source_index],
                s.align_rest,
            ) catch {
                setStatus(s, "retarget map failed (out of memory)", .{});
                s.characters[character_index].source_character = character_index;
                s.characters[character_index].mapped_joint_count = 0;
            };
        }
    }

    if (s.robot_dirty) {
        s.robot_dirty = false;
        // ── ★★★ INVALIDATE THE SAMPLE CACHE WHEN THE SOURCE CHANGES ──
        //
        // `buildPointSamples` runs only when `robot_sample_count == 0`, and each sample stores a
        // JOINT INDEX into the source skeleton. **Switching from Geno to the Mixamo drop kick
        // would have kept samples pointing at Geno's indices** — a different skeleton with a
        // different joint order, so every target would read the wrong joint.
        //
        // ★★ It would not crash: the indices are in range for both. **It would just retarget to
        // the wrong bones**, which is the quietest failure mode this project has, and the fifth
        // time a cache has outlived the thing it was built from.
        s.robot_sample_count = 0;
        s.robot_has_previous = false;
        refreshRobotMap(s) catch {
            setStatus(s, "robot map failed (out of memory)", .{});
            s.show_robot = false;
        };
    }

    // ★ Poses are computed against whichever character's clip drives each one, so the source
    // is looked up here rather than assumed to be self.
    for (0..s.characters.len) |character_index| {
        const source_index: usize = s.characters[character_index].source_character;
        const source: *const Character = &s.characters[source_index];
        const clip_duration: f32 = source.duration();
        const time_in_clip: f32 = if (clip_duration > 0)
            @mod(s.play_time, clip_duration)
        else
            0;
        poseCharacter(
            &s.characters[character_index],
            source,
            source_index == character_index,
            gl,
            time_in_clip,
        );
    }

    if (s.show_robot) {
        const robot_source: *const Character = &s.characters[s.robot_source];
        const robot_frames: usize = @intCast(@max(robot_source.clip.animation.keyframeCount, 0));
        if (robot_frames > 0) {
            const clip_duration: f32 = robot_source.duration();
            const time_in_clip: f32 = if (clip_duration > 0)
                @mod(s.play_time, clip_duration)
            else
                0;
            var frame: usize = @trunc(@max(time_in_clip / robot_source.clip.frame_time, 0));
            if (frame >= robot_frames) {
                frame = frame % robot_frames;
            }
            poseRobot(s, frame);
        }
    }

    // ONE light camera, used by BOTH the light pass and the ground's shadow lookup. Deriving
    // it twice is how a shadow ends up projected from a slightly different place than it was
    // rendered from.
    const light_dir: Vec = lightDirFrom(s.light_yaw, s.light_pitch);
    const focus: Vec = lightTarget(s);
    const light_cam: Camera3D = .{
        .position = focus - light_dir * @as(Vec, @splat(light_distance)),
        .target = focus,
        .up = vec(0, 1, 0),
        .fovy_deg = light_extent * 2.0,
        .projection = @backingInt(zm.CameraProjection.orthographic),
    };
    const light_cam_vp: Mat = mulMat(
        light_cam.projMatrix(1.0, light_near, light_far),
        light_cam.viewMatrix(),
    );

    // ── ★ PASS 1: THE SCENE FROM THE LIGHT ──
    //
    // Step one of the shadow map, and deliberately ONLY step one: this renders the ordinary
    // ★ ALWAYS RUNS NOW — the ground samples this every frame, so it is no longer gated on
    // the debug toggle. The toggle only controls whether the result is also SHOWN.
    // ── ★★ EVERY OFFSCREEN PASS RUNS BEFORE `clearViewport` OPENS THE SCREEN PASS ──
    //
    // `beginTextureModeRaw` / `beginTextureModeMrtRaw` check `drawing_active`: if the screen
    // pass is already open they FLUSH THE 2D BATCH, end the pass, render offscreen, then
    // reopen. That flush is the bug — pending UI vertices get drawn under the OFFSCREEN
    // pass's projection (a 1024-square ortho, not the window's), so the panel lands at the
    // wrong place, and then draws again correctly when the batch is flushed for real. Two
    // panels, side by side, exactly as seen.
    //
    // ★ The camera update is hoisted above the passes for this: it only needs `u`, and it was
    // the sole reason the G-buffer pass had drifted below `clearViewport`. The comment there
    // claimed "before the screen pass opens" while the code did the opposite — a comment
    // asserting an ordering the code does not enforce is worse than none.
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{
        .min_distance = 0.6,
        .max_distance = 14.0,
    });
    const view_aspect: f32 = blk: {
        const gh: f32 = f.window.heightf();
        break :blk if (gh > 0) f.window.widthf() / gh else 1.0;
    };
    const cam_vp: Mat = mulMat(cam.projMatrix(view_aspect, 0.01, 1000.0), cam.viewMatrix());

    drawLightDepth(s, f, light_cam_vp);
    drawGbuffer(s, f, cam_vp);
    // ★ AO CONSUMES THE G-BUFFER, so it must come after — and before the screen opens.
    drawSsao(s, f, cam.viewMatrix());
    if (s.blur_ao) {
        // Horizontal into the scratch, vertical back into `ssao_rt` — so the composite and the
        // debug inset both keep reading one texture regardless of whether blurring is on.
        drawSsaoBlurPass(s, f, 0);
        drawSsaoBlurPass(s, f, 1);
    }

    z.clearViewport(f, .{ .r = 18, .g = 20, .b = 26, .a = 255 });

    // ★ THE 3D BLOCK ALWAYS OPENS, even when it draws nothing. `beginMode3D` is what puts the
    // pass into the depth-tested 3D state the custom pipelines below rely on; making it
    // conditional would mean the shadowed geometry renders differently depending on whether a
    // debug gizmo happens to be enabled. `drawScene` returns immediately when there is no
    // skeleton to draw, so the cost of always opening it is a state change, not geometry.
    z.beginMode3D(gl, cam);
    drawScene(s, gl);
    z.endMode3D(gl);

    // ── ★ THE LIT PASS: ground and characters, ONE pipeline, both receiving ──
    {
        if (s.show_ground) {
            drawShadowedGround(s, f, cam_vp, light_cam_vp, light_dir);
        }
        if (s.show_mesh) {
            drawCharactersLit(s, f, cam_vp, light_cam_vp, light_dir);
        }
        // ★ Hand the pass back once, after ALL foreign-pipeline work — not per draw.
        gl.renderer().bindForPass(gl.pass);
    }

    // ── ★ COMPOSITE: MULTIPLY THE AO OVER THE LIT IMAGE ──
    //
    // ★ NO NEW SHADER. AO is a 0..1 factor and the composite is `lit *= ao`, which is exactly
    // what a MULTIPLY-blended fullscreen quad does. The engine's 2D pipeline already carries a
    // `.multiply` variant, so this is one textured draw between the lit geometry and the UI.
    //
    // GenoView instead feeds AO into its lighting shader, separating `ssaoData.r` (ambient)
    // from `.g` (sun). That is better — it lets AO darken only the SKY term while leaving
    // direct sunlight alone — and it is what §12e will do once a lighting pass exists. A flat
    // multiply darkens everything including lit surfaces, which reads slightly heavy.
    //
    // ★ ORDER: after the 3D, BEFORE the UI. The UI is not part of the scene and must not be
    // multiplied by an occlusion factor computed from scene geometry.
    if (s.show_ao) {
        const cw: f32 = f.window.widthf();
        const ch: f32 = f.window.heightf();
        z.beginBlendMode(gl, .multiply);
        gl.texture(
            .{ .x = 0, .y = 0, .width = cw, .height = ch },
            s.ssao_rt.asTexture(),
            .{},
        );
        z.endBlendMode(gl);
    }

    if (s.show_light_view) {
        // The light's view, bottom-right. §12a-4 replaces its contents with linear depth.
        //
        // ★ SIZED AND PLACED FROM THE LIVE WINDOW, NOT THE CONFIGURED `screen_w`. The window
        // constant is what the app ASKS for; on a phone the canvas is whatever fits, so
        // anchoring to 1000 put this inset off the right edge and it simply never appeared.
        // `f.window.widthf()` is the actual size — `examples/render_texture` uses it for the
        // same reason.
        const view_w: f32 = f.window.widthf();
        const view_h: f32 = f.window.heightf();
        const size: f32 = @min(view_w, view_h) * 0.28;
        const shown: z.WgpuTexture = switch (s.debug_view) {
            1 => s.gbuf_pos.asTexture(),
            2 => s.gbuf_normal.asTexture(),
            3 => s.gbuf_albedo.asTexture(),
            4 => s.ssao_rt.asTexture(),
            else => s.light_view.asTexture(),
        };
        f.gl.texture(
            .{
                .x = view_w - size - 12.0,
                .y = view_h - size - 12.0,
                .width = size,
                .height = size,
            },
            shown,
            .{},
        );
    }

    drawPanel(s, u, longest);
}

/// Everything that casts or receives — drawn identically from the camera and from the light,
/// because a shadow map that renders a DIFFERENT scene than the one it shades is the classic
/// way to get shadows that do not line up.
/// Where the light box should be centred: the midpoint of the characters' hips, lifted to
/// chest height so the box covers a jump as well as a step.
///
/// ★ Uses the ROOT joint rather than a bounding box — the root is one already-computed vector
/// per character, and a directional box only needs to be roughly right to keep the subject
/// inside it.
fn lightTarget(s: *State) Vec {
    var sum: Vec = vec(0, 0, 0);
    for (&s.characters) |*c| {
        sum += c.positions[0] + c.offset;
    }
    var mid: Vec = sum / @as(Vec, @splat(float(s.characters.len)));
    mid[1] = 0.9;
    return mid;
}

/// Load `humanoid.xml` and prepare everything the retarget needs from the robot side.
fn initRobot(gpa: Allocator, s: *State) !void {
    // ── ★★★ `humanoid_flex2.xml` — the Geno-matched model ──
    //
    // ★★★ On top of flex 1: BALL joints where the robot was limited (elbow, knee, ankle) and a
    // TOE BONE, which Geno has and the robot did not. **Geno's animation is ROTATIONS on a fixed
    // skeleton, so matching it exactly needs 3 rotational DOF per joint and matching bone
    // lengths — not 6.** Translation would let the robot express more than the capture itself
    // can, and would let bones detach.
    //
    // ★★ The toe matters because the whole foot was ONE rigid segment: it could not flatten its
    // sole while pointing its toe, which is what a foot does at every push-off. Measured: sole
    // tilt 13-51 deg -> 5-21, forearm 4.7 -> 3.7.
    //
    // Every difference from stock is a measurement: arms shortened 20% (bones were 1.24-1.29x
    // the capture's, now 0.99-1.03), ONE shoulder axis added per arm (21 -> 23 DOF), shoulder
    // span narrowed (the torso was wider than Geno's and skewed to compensate), feet pitched
    // 24.6 degrees (Geno's ankle-to-toe is that far below horizontal; the sole was flat), and
    // the joint ranges widened where the solve was pinned.
    //
    // ★★★ Measured against flex 1: forearm 11.2 -> 4.7 deg, torso axis 9.0 -> 6.8, worst
    // single-frame pop **59 -> 14** (from 155 with the original six-mechanism pipeline).
    // ★★ Either model, chosen at runtime. **The generalisation test — a Geno-shaped robot versus
    // a stock one, on a Mixamo capture — should be one click, not a rebuild**, because a test
    // that requires a rebuild is a test nobody runs.
    s.robot_doc = try z.codecs.xml.parse(gpa, if (s.robot_use_stock)
        @embedFile("humanoid.xml")
    else
        @embedFile("humanoid_flex2.xml"), null);
    s.robot_spec = try mjcf.readRobot(gpa, &s.robot_doc);
    s.robot = try z.robot_mjcf.build(gpa, &s.robot_spec, .{});
    s.robot_data = try z.robot.Data.init(gpa, &s.robot.model);

    const body_count: usize = s.robot.model.nbody;
    s.robot_reference = try gpa.alloc(Quat, body_count);
    s.human_of_body = try gpa.alloc(i32, body_count);
    s.robot_parents = try gpa.alloc(i32, body_count);
    s.robot_rest_alignment = try gpa.alloc(Quat, body_count);
    s.robot_local = try gpa.alloc(Quat, body_count);
    s.robot_global = try gpa.alloc(Quat, body_count);
    s.robot_positions_y_up = try gpa.alloc(Vec, body_count);
    // Sized to the largest skeleton that can drive the robot, not to the robot.
    s.source_delta_z_up = try gpa.alloc(Quat, 128);
    s.robot_human_reference = try gpa.alloc(Quat, 128);
    s.robot_axis_map = try gpa.alloc(Quat, body_count);
    s.robot_desired_global = try gpa.alloc(Quat, body_count);
    s.robot_identity_map = try gpa.alloc(i32, body_count);
    s.robot_identity_alignment = try gpa.alloc(Quat, body_count);
    for (0..body_count) |body| {
        s.robot_identity_map[body] = @intCast(body);
        s.robot_identity_alignment[body] = zm.quat_identity;
    }
    s.robot_position_weights = try gpa.alloc(f32, body_count);
    s.robot_rotation_weights = try gpa.alloc(f32, body_count);
    s.robot_rest_world = try gpa.alloc(Vec, 128);
    s.robot_rest_rotations = try gpa.alloc(Quat, 128);
    s.robot_rest_xpos = try gpa.alloc(Vec, body_count);
    s.robot_tpose_qpos = try gpa.alloc(f32, s.robot.model.nq);
    s.robot_rest_xrot = try gpa.alloc(Quat, body_count);
    s.robot_rest_body_pos = try gpa.alloc(Vec, body_count);
    s.robot_rest_flexion = try gpa.alloc(f32, body_count);
    @memset(s.robot_rest_flexion, 0);
    s.robot_samples = try gpa.alloc(z.robot.PointSample, 256);
    s.robot_previous_qpos = try gpa.alloc(f32, s.robot.model.nq);
    s.robot_twist = try gpa.alloc(Quat, body_count);
    s.robot_parent_twist = try gpa.alloc(Quat, body_count);
    s.robot_limb_correction = try gpa.alloc(Quat, body_count);
    for (s.robot_limb_correction) |*correction| {
        correction.* = zm.quat_identity;
    }
    // ★★★ ONE TASK PER SAMPLE, NOT PER BODY. The point cloud puts up to four samples on a body,
    // so a body-sized task array silently truncated 43 samples to 17 — **two thirds of the robot
    // had no targets and simply stayed at rest.** `@min(count, tasks.len)` made it a quiet clamp
    // rather than a crash.
    s.robot_tasks = try gpa.alloc(z.robot.IkTask, 256);
    s.robot_ik_scratch = try gpa.alloc(f32, z.robot.ikScratchSize(s.robot.model.nv));
    @memset(s.robot_position_weights, 0);

    // ── ★★★ BONE DIRECTIONS, NOT BODY FRAMES ──
    //
    // `referenceOrientationsFromRest` reads `body_xrot` at `qpos0` — the body FRAME. For
    // `humanoid.xml` that is IDENTITY FOR EVERY BODY, because the file declares no rotation
    // anywhere; its bone directions live in the POSITION OFFSETS (`lower_arm_left` sits at
    // `.18 .18 -.18`). Aligning that identity against a real human T-pose rotation turned every
    // robot bone, which is what the device showed.
    //
    // ★ Both sides now answer the SAME QUESTION — which way does this bone point at rest —
    // through the same shortest-arc-from-+Y construction. See claude.md: two references must
    // match in KIND, not just in pose.
    z.robot.referenceOrientationsFromBoneDirections(&s.robot.model, s.robot_reference);

    for (0..body_count) |body| {
        s.robot_parents[body] = if (body == 0) -1 else @intCast(s.robot.model.body_parent[body]);
        s.robot_rest_alignment[body] = zm.quat_identity;
    }
}

/// The character's rest orientations expressed as BONE DIRECTIONS, to pair with the robot's.
///
/// ★★ The character keeps its own `rest_orientations` (from a real T-pose or the FBX bind) for
/// character-to-character retargeting, where both sides are real orientations. Pairing with the
/// ROBOT needs a different KIND of reference — bone directions — because that is all the robot
/// has. **The rule is that the two sides must match, not that any one construction is correct.**
fn characterBoneDirections(
    gpa: Allocator,
    character: *const Character,
    out_orientations: []Quat,
) !void {
    const joint_count: usize = character.boneCount();
    const rest_offsets: []Vec = try gpa.alloc(Vec, joint_count);
    defer gpa.free(rest_offsets);
    const rest_pose: [*]z.types.Transform =
        @ptrCast(@alignCast(character.model.clip.skeleton.bindPose));
    for (0..joint_count) |joint| {
        rest_offsets[joint] = rest_pose[joint].translation;
    }
    z.codecs.bvh.restBoneOrientations(
        character.target_parents[0..joint_count],
        rest_offsets,
        out_orientations[0..joint_count],
    );
}

/// The chains the twist offsets are computed along, parent to child.
///
/// ★★ Each body appears in EXACTLY ONE chain. The torso previously headed all three upper-body
/// chains, so its twist was computed three times and whichever ran last silently won. Arms start
/// at `upper_arm_*` and inherit the torso's twist through `parent_twist`, which is what that
/// term is for.
const robot_twist_chains = [_][]const []const u8{
    &.{ "torso", "head" },
    &.{ "torso", "waist_lower", "pelvis" },
    &.{ "upper_arm_right", "lower_arm_right", "hand_right" },
    &.{ "upper_arm_left", "lower_arm_left", "hand_left" },
    &.{ "pelvis", "thigh_right", "shin_right", "foot_right" },
    &.{ "pelvis", "thigh_left", "shin_left", "foot_left" },
};

/// Build the robot's twist offsets, via the SHARED library implementation.
///
/// ★★★ The body of this used to live here AND in the scorecard harness, and the two copies
/// drifted four ways before a screenshot caught it. `z.robot.computeTwistChainOffsets` is now
/// the single implementation; this function only prepares its inputs.
fn refreshRobotTwists(
    s: *State,
    source: *const Character,
    source_joint_count: usize,
) void {
    // ★ The source's T-pose world positions, converted to the robot's frame once here so the
    // shared builder needs no knowledge of either skeleton's up-axis convention.
    // ── ★★★ SCALED TO THE ROBOT'S SIZE ──
    //
    // Geno's rest positions are in CENTIMETRES (hips near 85) and the robot works in METRES
    // (hips near 0.83). **The twist offsets never noticed, because directions are normalised —
    // but `solveRobotTPose` uses these as POSITIONS**, and a 100x target is not a T-pose, it is
    // a request to reach the next room.
    //
    // ★ A units mismatch that is invisible to one consumer and fatal to another is exactly what
    // sharing a buffer between them invites.
    const rest_robot_frame: []Vec = s.robot_rest_world[0..source_joint_count];
    // ── ★★★ THE SCALE FROM ONE QUANTITY, IN ITS OWN UNITS ──
    //
    // The old form was `cm_to_m * robot_hip / source.hip_height`, pairing `rest_positions`
    // (assumed CENTIMETRES) with `hip_height` (assumed METRES). **Two fields, two unit
    // assumptions, and a different capture can honour neither** — the Mixamo drop kick left the
    // robot standing in its rest pose while the character danced.
    //
    // ★★★ Measuring the source's height FROM `rest_positions` removes both assumptions: the
    // ratio is between two lengths, one of which is in whatever unit that array uses, so the
    // unit cancels. **A scale derived from one quantity cannot disagree with itself.**
    const rest_scale: f32 = captureScale(s, source);
    for (0..source_joint_count) |joint| {
        const y_up: Vec = source.rest_positions[joint] * @as(Vec, @splat(rest_scale));
        rest_robot_frame[joint] = vec(y_up[0], -y_up[2], y_up[1]);
    }

    // ★ The T-pose rotations in the robot's frame too — the SOURCE's rest local frame is not
    // world (Spine3 carries four spine joints' accumulated rotation), so the twist must divide
    // it out. Passing `null` would silently make the example a different algorithm from the
    // measured one, which is the divergence this extraction exists to prevent.
    const rest_rotations: []Quat = s.robot_rest_rotations[0..source_joint_count];
    const y_to_z: Quat = zm.quatFromAxisAngle(vec(1, 0, 0), 1.5707963);
    for (0..source_joint_count) |joint| {
        rest_rotations[joint] = zm.qmul(
            zm.qmul(y_to_z, source.rest_orientations[joint]),
            zm.conjugate(y_to_z),
        );
    }

    // ── ★★★ SOLVE THE ROBOT INTO GENO'S T-POSE, AND USE THAT AS ITS REFERENCE ──
    //
    // **`humanoid.xml`'s `qpos0` IS NOT A T-POSE.** Seen side by side, Geno stands with arms
    // straight out while the robot folds its arms up into a triangle. Every twist offset has
    // been `shortestArc(robot rest bone -> geno rest bone)` between two DIFFERENT POSES — which
    // is the rule this arc has broken four times, and this is its root instance.
    //
    // ★★ So stop treating `qpos0` as the reference and BUILD one: IK the robot onto Geno's
    // T-pose joint positions, and take the resulting configuration as its rest. Both sides then
    // depict the same physical pose because the robot's was DERIVED from the character's.
    //
    // ★ This uses the solver that already exists and is tested. It runs once per source change,
    // not per frame.
    // ── ★★★ A SANITY BOUND ON THE SCALED REST POSE ──
    //
    // A units mismatch here has now produced a T-pose 100x too SMALL (targets unreachable) and
    // one 100x too LARGE (a figure the size of a building). Both compiled, both passed lint, and
    // both needed a screenshot to notice.
    //
    // ★ A human-scaled skeleton spans roughly two metres. Anything past four is a units bug, and
    // saying so on screen beats rendering it.
    var rest_span: f32 = 0;
    for (0..source_joint_count) |joint| {
        const p: Vec = rest_robot_frame[joint];
        rest_span = @max(rest_span, @abs(p[0]));
        rest_span = @max(rest_span, @abs(p[1]));
        rest_span = @max(rest_span, @abs(p[2]));
    }
    if (rest_span > 4.0 or rest_span < 0.2) {
        setStatus(s, "rest pose spans {d:.2} m — units mismatch, T-pose not built", .{rest_span});
        s.robot_ready = false;
        return;
    }

    solveRobotTPose(s, rest_robot_frame, source.target_parents[0..source_joint_count]);
    s.robot_ready = true;
    for (0..s.robot.model.nbody) |body| {
        s.robot_rest_xpos[body] = s.robot_data.body_xpos[body];
        s.robot_rest_xrot[body] = s.robot_data.body_xrot[body];
        // ★ The POSITIONS too: the leaf correspondence self-check needs both halves of the rest
        // pose, and keeping only the rotations is why it could not run here.
        s.robot_rest_body_pos[body] = s.robot_data.body_xpos[body];
    }
    // ★ Each hinge's bend at THIS rest pose, so a flexion can be written as an offset from it.
    @memset(s.robot_rest_flexion, 0);
    for (0..s.robot.model.nbody) |body| {
        if (s.robot.model.body_jnt_num[body] != 1) {
            continue;
        }
        const parent: u32 = s.robot.model.body_parent[body];
        if (parent == 0) {
            continue;
        }
        var child: ?usize = null;
        for (1..s.robot.model.nbody) |candidate| {
            if (s.robot.model.body_parent[candidate] == body) {
                child = candidate;
                break;
            }
        }
        const tip: usize = child orelse continue;
        const upper: Vec = s.robot_rest_xpos[body] - s.robot_rest_xpos[parent];
        const lower: Vec = s.robot_rest_xpos[tip] - s.robot_rest_xpos[body];
        const upper_len: f32 = @sqrt(upper[0] * upper[0] + upper[1] * upper[1] + upper[2] * upper[2]);
        const lower_len: f32 = @sqrt(lower[0] * lower[0] + lower[1] * lower[1] + lower[2] * lower[2]);
        if (upper_len < 1.0e-6 or lower_len < 1.0e-6) {
            continue;
        }
        const cosine: f32 = clamp(
            (upper[0] * lower[0] + upper[1] * lower[1] + upper[2] * lower[2]) /
                (upper_len * lower_len),
            -1.0,
            1.0,
        );
        s.robot_rest_flexion[body] = acosRad(cosine);
    }

    z.robot.computeTwistChainOffsets(
        &s.robot.model,
        &s.robot_data,
        s.robot.names,
        s.human_of_body,
        rest_robot_frame,
        rest_rotations,
        &robot_twist_chains,
        // ★ OFF: enabling it measures WORSE across six of seven stages — see
        // `src/notes/twist_port_plan.md` section 21.
        null,
        // ★ THE SOLVED T-POSE, not `qpos0` — both references now depict the same physical pose.
        s.robot_tpose_qpos,
        s.robot_twist,
        s.robot_parent_twist,
    );

    // ★★ THE TORSO'S REFERENCE BONE IS REPLACED AFTERWARDS. Its chain bone `torso -> head` is
    // VERTICAL, and a shortest arc between two vertical bones cannot encode YAW — which is the
    // axis the two skeletons actually differ about. Shoulder-to-shoulder is horizontal and sees
    // it exactly.
    if (findBody(s, "torso")) |torso| {
        if (shoulderAxes(s, rest_robot_frame)) |axes| {
            s.robot_twist[torso] =
                z.robot.computeTwistOffset(axes.robot, axes.human, zm.quat_identity);
            // Children of the torso inherit the corrected value.
            for (0..s.robot.model.nbody) |body| {
                if (s.robot.model.body_parent[body] == torso) {
                    s.robot_parent_twist[body] = s.robot_twist[torso];
                }
            }
        }
    }
}

fn findBody(s: *const State, wanted: []const u8) ?usize {
    for (s.robot.names, 0..) |name, index| {
        if (std.mem.eql(u8, name, wanted)) {
            return index;
        }
    }
    return null;
}

/// Rebuild the robot's joint map and rest alignment for whichever character now drives it.
fn refreshRobotMap(s: *State) !void {
    const source: *const Character = &s.characters[s.robot_source];
    const source_joint_count: usize = source.boneCount();

    const source_names: [][]const u8 = try s.gpa.alloc([]const u8, source_joint_count);
    defer s.gpa.free(source_names);
    for (0..source_joint_count) |joint| {
        source_names[joint] = source.clip.boneName(joint);
    }

    // ★ An unknown body name is an ERROR, not a stiff limb that looks like a solver bug.
    z.robot.resolveMatchTable(
        &z.robot.lafan_to_humanoid,
        s.robot.names,
        source_names,
        s.human_of_body,
    ) catch {
        setStatus(s, "robot match table failed to resolve", .{});
        s.show_robot = false;
        return;
    };

    // ★ The human side of the ROBOT pairing uses bone directions too — see
    // `characterBoneDirections`. Both sides, same question, same construction.
    const source_bone_directions: []Quat = try s.gpa.alloc(Quat, source_joint_count);
    defer s.gpa.free(source_bone_directions);
    try characterBoneDirections(s.gpa, source, source_bone_directions);

    z.codecs.bvh.restAlignmentOffsets(
        s.human_of_body,
        source_bone_directions,
        s.robot_reference,
        s.robot_rest_alignment,
    );
    @memcpy(s.robot_human_reference[0..source_joint_count], source_bone_directions);

    // ── ★★★ THE PER-LIMB CORRECTION, MEASURED FROM THE TWO REST POSES ──
    //
    // For every mapped body: the rotation taking the HUMAN's rest bone direction onto the
    // ROBOT's. Identity where they already agree — which the measurement says is the torso and
    // both legs — and roughly 55 degrees on the arms, where the robot rests diagonally and the
    // human rests straight out.
    //
    // ★ Derived, not authored. This is GMR's `rot_offset` column, and the reason theirs varies
    // per limb GROUP is exactly this: a robot's arm convention and its leg convention differ.
    for (0..s.robot.model.nbody) |body| {
        s.robot_limb_correction[body] = zm.quat_identity;
        const human_joint: i32 = s.human_of_body[body];
        if (human_joint < 0) {
            continue;
        }
        const joint: usize = @intCast(human_joint);

        // The robot's rest bone: its first child's offset, which at `qpos0` is also its world
        // direction because `humanoid.xml` declares no body rotations.
        var robot_child: ?usize = null;
        for (0..s.robot.model.nbody) |candidate| {
            if (candidate != 0 and s.robot.model.body_parent[candidate] == body) {
                robot_child = candidate;
                break;
            }
        }
        const robot_tip: usize = robot_child orelse continue;
        const robot_dir: Vec = normalize3(s.robot.model.body_pos[robot_tip]);

        // The human's rest bone, from its own rest offsets, through the position conversion.
        var human_child: ?usize = null;
        for (0..source_joint_count) |candidate| {
            if (source.target_parents[candidate] == @as(i32, @intCast(joint))) {
                human_child = candidate;
                break;
            }
        }
        const human_tip: usize = human_child orelse continue;
        const rest_pose: [*]z.types.Transform =
            @ptrCast(@alignCast(source.model.clip.skeleton.bindPose));
        const human_bone_y_up: Vec = rest_pose[human_tip].translation;
        const human_length: f32 = @sqrt(human_bone_y_up[0] * human_bone_y_up[0] +
            human_bone_y_up[1] * human_bone_y_up[1] + human_bone_y_up[2] * human_bone_y_up[2]);
        if (human_length < 1.0e-6) {
            continue;
        }
        const human_unit: Vec = human_bone_y_up / @as(Vec, @splat(human_length));
        const human_dir: Vec = vec(human_unit[0], -human_unit[2], human_unit[1]);

        s.robot_limb_correction[body] = shortestArcBetween(human_dir, robot_dir);
    }

    refreshRobotTwists(s, source, source_joint_count);

    // The table's position weights, indexed by body so `poseRobot` needs no name lookup.
    @memset(s.robot_position_weights, 0);
    @memset(s.robot_rotation_weights, 0);
    for (z.robot.lafan_to_humanoid) |row| {
        for (s.robot.names, 0..) |name, body| {
            if (std.mem.eql(u8, name, row.robot_body)) {
                s.robot_position_weights[body] = row.position_weight;
                s.robot_rotation_weights[body] = row.rotation_weight;
                break;
            }
        }
    }
}

/// Drive the robot from one frame of its source character's clip.
/// Drive the robot from one frame of its source character's clip.
///
/// ── ★★★ GMR'S DESIGN, AFTER THREE FAILED ATTEMPTS AT SOMETHING ELSE ──
///
/// GMR sets each robot body a full SE3 target — POSITION AND ORIENTATION, both in WORLD space,
/// taken straight from the human's corrected pose — and solves every task at once. **It never
/// computes per-joint local rotations and never decomposes anything.**
///
/// ★★ Decomposing was the fatal flaw in the three attempts before this one. Computing
/// `local = conj(parent_DESIRED_global) * desired_global` assumes the parent REACHES its desired
/// orientation — but `humanoid.xml`'s knee is one hinge and cannot, so every child was solved
/// against a parent that was wrong and the error compounded down the chain. That is where 89
/// degrees of residual came from: not one joint's honest shortfall, but accumulated
/// inconsistency.
///
/// ★ A solver has no such problem. When a parent falls short it compensates with the child,
/// because it optimises every joint against every target together.
fn poseRobot(s: *State, frame: usize) void {
    const source: *const Character = &s.characters[s.robot_source];
    const source_joint_count: usize = source.boneCount();

    // The source's world pose for this frame.
    d3.bvhForwardKinematics(
        source.clip,
        frame,
        source.positions[0..source_joint_count],
        source.rotations[0..source_joint_count],
    );

    const y_up_to_z_up: Quat = zm.quatFromAxisAngle(vec(1, 0, 0), 1.5707963);
    const z_up_to_y_up: Quat = zm.conjugate(y_up_to_z_up);

    const source_root_y_up: Vec = source.positions[0];
    // ── ★★★ MEASURED, NOT GUESSED ──
    //
    //     ROBOT  height 1.445 m   hips 0.830   shoulder 1.315
    //     HUMAN  height 165.0 cm  hips  84.4   shoulder  136.7
    //
    // ★★ A HARDCODED 0.9 here gave 0.9/84.4 = 0.01066 against a measured hip ratio of 0.00983
    // — **8.5% too large**, so every target sat further out than the robot could reach, on
    // every frame, for this entire arc. A guessed constant next to real geometry is a bug
    // waiting for someone to measure it.
    // ★★★ THE SAME UNIT-FREE RATIO AS THE REST SCALE. Two scales derived from different
    // quantities can disagree, and a per-frame scale that disagrees with the rest scale puts
    // every target in a different world from the offsets measured against the rest pose.
    // **One derivation, used twice.**
    const scale: f32 = captureScale(s, source);
    const root_z_up: Vec = vec(
        source_root_y_up[0] * scale,
        -source_root_y_up[2] * scale,
        source_root_y_up[1] * scale,
    );

    // ── ★★★ THE TORSO IS PLACED DIRECTLY, NOT SOLVED ──
    //
    // It is the ROOT body and carries the free joint, so its position AND orientation are
    // WRITABLE — six DOF, no chain above it, nothing to compete with. **If the torso alone does
    // not land on the human's torso, no amount of IK below it can help**, and every previous
    // attempt was solving sixteen bodies without ever checking one.
    //
    // ★ So: place the torso exactly, draw it, and only then add bones. IK becomes what it
    // should be — a refinement for the joints that CANNOT be placed directly — rather than the
    // thing being asked to rescue a wrong frame.

    // ★ Start from the REST configuration each frame rather than from the previous frame's
    // answer. A solver warm-started from a pose that was itself wrong inherits the error, and
    // debugging a drifting sequence is far harder than debugging a single frame.
    @memcpy(s.robot_data.pos, s.robot.model.qpos0);
    if (s.robot.model.njnt > 0 and s.robot.model.jnt_type[0] == .free) {
        const root_qpos: usize = s.robot.model.jnt_qpos_adr[0];
        s.robot_data.pos[root_qpos + 0] = root_z_up[0];
        s.robot_data.pos[root_qpos + 1] = root_z_up[1];
        s.robot_data.pos[root_qpos + 2] = root_z_up[2];
    }
    z.robot.kinematics(&s.robot.model, &s.robot_data);
    z.robot.comPos(&s.robot.model, &s.robot_data);

    // ── ★★★ THE INPUTS THE LIBRARY WANTS ──
    //
    // What follows converts a `Character` into the two arrays `robot.solvePointCloud` consumes:
    // the capture's joint positions and rotations, in the robot's Z-up frame at the robot's
    // scale. **That conversion is the example's only remaining job in the retarget.**
    //
    // ★★ The comments that stood here described `poseFromRetarget` and a 270-line duplicate loop
    // — both accurate when written, both long superseded by the point-cloud solve. **A comment
    // naming the wrong function is how three of this session's misdiagnoses started**: it reads
    // as documentation and behaves as misdirection.

    var positions_robot: [128]Vec = undefined;
    var rotations_robot: [128]Quat = undefined;
    const joint_count: usize = @min(source_joint_count, positions_robot.len);
    for (0..joint_count) |joint| {
        const p_y: Vec = (source.positions[joint] - source_root_y_up) * @as(Vec, @splat(scale));
        positions_robot[joint] = root_z_up + vec(p_y[0], -p_y[2], p_y[1]);
        rotations_robot[joint] = zm.qmul(
            zm.qmul(y_up_to_z_up, source.rotations[joint]),
            z_up_to_y_up,
        );
    }

    // ★★★ ONE POINT-CLOUD SOLVE, replacing the six sequential mechanisms. See
    // `solvePointCloud` for the measurements and `src/notes/retarget_formulation.md` for why
    // matching points subsumes position, direction, twist, bend plane and swivel at once.
    // ── ★★★ ONE LIBRARY CALL ──
    //
    // Samples built once and cached; the retargeted skeleton rebuilt each frame because it
    // follows the capture's directions. **Both come from `src/robot.zig`, so the harness measures
    // the code that ships** rather than a copy of it.
    if (s.robot_sample_count == 0) {
        refreshPointSamples(s, source);
    }
    var retargeted: [64]Vec = undefined;
    buildRetargetedSkeleton(s, positions_robot[0..joint_count], &retargeted);
    z.robot.solvePointCloud(
        &s.robot.model,
        &s.robot_data,
        s.robot_samples[0..s.robot_sample_count],
        .{
            .positions = positions_robot[0..joint_count],
            .rotations = rotations_robot[0..joint_count],
            .retargeted = retargeted[0..@min(s.robot.model.nbody, retargeted.len)],
            .root_world = rootBodyWorldPosition(s, positions_robot[0..joint_count]),
            .position_pull = s.robot_position_pull,
            .previous_qpos = if (s.robot_has_previous) s.robot_previous_qpos else null,
            .posture_weight = 0.15,
            .scratch = s.robot_ik_scratch,
            .tasks = s.robot_tasks,
        },
    );
    @memcpy(s.robot_previous_qpos, s.robot_data.pos[0..s.robot.model.nq]);
    s.robot_has_previous = true;
    recordRobotFit(s, positions_robot[0..joint_count]);

    const task_count: usize = 0;

    // ── ★★★ THE RIGHT ARM: A MASKED, LIMITED 3-DOF SOLVE ──
    //
    // Targets built from the capture's DIRECTIONS at the ROBOT's own bone lengths, so both are
    // exactly reachable and both bones point where the character's do. Masked to the arm's own
    // DOF — an unmasked hand task translates the whole robot, which is cheaper than bending an
    // arm and wrecks the torso. Limits enforced, because without them the solver returns poses
    // the robot cannot hold (measured: a shoulder at -118 against a range of [-85, 60]).
    // ── ★★ THE FOUR PER-LIMB CHAIN SOLVES ARE GONE ──
    //
    // They ran AFTER the pose loop and overrode it, and each was a separate masked solve whose
    // targets were built on where the stage before it was SUPPOSED to have put things — the
    // foot's aim was 4 degrees wrong for exactly that reason. **The single point-cloud solve
    // subsumes all four**: nothing is downstream of anything, so nothing inherits another
    // stage's error.

    // ── ★ (superseded) THE LEGS DO **NOT** GET THE CHAIN SOLVE ──
    //
    //                  existing path      chain solve
    //     thigh          12.5 deg         28-43 deg      WORSE
    //     shin/knee       6.6 deg         27-53 deg      MUCH WORSE
    //     hip at limit       -            2 of 4 frames
    //
    // ★★★ The construction that fixed the arm makes the legs worse by a factor of three. The
    // arm needed it because a 2-DOF shoulder pinned against a [-85,60] patch could not aim at
    // all; **the legs were already the best part of the retarget** (knee 6.6 deg) through the
    // twist-offset path, and a chain of exactly-reachable targets over-constrains a 4-DOF leg
    // where it rescued a 3-DOF arm.
    //
    // ★★ "It worked for the arm" is not a reason. The same code, the same targets, the same
    // mask — opposite outcomes, because the two limbs are not the same mechanism. **Measured
    // before shipping, and left off.**

    // ★ GMR's stopping rule: iterate while the error is still falling. From rest that is more
    // steps than from a warm start, which is the price of not inheriting last frame's error.
    // Every body has been posed; `comPos` is what the solver additionally needs.
    z.robot.comPos(&s.robot.model, &s.robot_data);

    const iteration_budget: usize = @intCast(@max(s.robot_ik_iterations, 0));
    var previous_error: f32 = 1.0e9;
    var final_error: f32 = 0;
    for (0..iteration_budget) |_| {
        final_error = z.robot.ikStep(
            &s.robot.model,
            &s.robot_data,
            s.robot_tasks[0..task_count],
            .{ .damping = s.robot_ik_damping },
            s.robot_ik_scratch,
        );
        z.robot.kinematics(&s.robot.model, &s.robot_data);
        z.robot.comPos(&s.robot.model, &s.robot_data);
        if (previous_error - final_error < 0.0005) {
            break;
        }
        previous_error = final_error;
    }
    // ★ The reported number is now the SOLVER's residual error, not a per-joint rotation
    // shortfall — it measures how far the robot ended from the targets it was given, which is
    // the thing a viewer actually wants to know.
    // ★ Zero tasks or zero iterations means the number is MEANINGLESS, not zero — reporting a
    // stale 0.000 with the solver off is how `ik error` read perfect while nothing had run.
    s.robot_mean_residual = if (task_count > 0 and iteration_budget > 0)
        final_error / float(task_count)
    else
        -1.0;

    // ── ★★★ A COLLAPSED ROBOT MEANS THIS FUNCTION NEVER RAN ──
    //
    // `robot_positions_y_up` starts zeroed, so if `poseRobot` is skipped every body draws at the
    // origin and the geoms pile into a ball. **That looks like a solver failure and is not one**
    // — it is the pose function not being reached at all, which has happened when the match
    // table failed to resolve and `show_robot` was cleared.
    //
    // ★ The readout beside the robot checkbox distinguishes them: `bodies 0/18` means the TABLE
    // failed; `bodies 18/18` with a ball on screen means this loop did not run.
    s.robot_posed_frames +|= 1;

    // ★ Z-UP -> Y-UP for display, once, at the boundary.
    for (0..s.robot.model.nbody) |body| {
        const z_up: Vec = s.robot_data.body_xpos[body];
        s.robot_positions_y_up[body] = vec(z_up[0], z_up[2], -z_up[1]);
    }
}

/// The shoulder-to-shoulder axis on both skeletons, at rest — a HORIZONTAL reference the
/// vertical spine bone cannot provide.
fn shoulderAxes(s: *State, rest_world: []const Vec) ?struct { robot: Vec, human: Vec } {
    var rl: ?usize = null;
    var rr: ?usize = null;
    for (s.robot.names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "upper_arm_left")) {
            rl = i;
        }
        if (std.mem.eql(u8, n, "upper_arm_right")) {
            rr = i;
        }
    }
    const left: usize = rl orelse return null;
    const right: usize = rr orelse return null;
    const hl: i32 = s.human_of_body[left];
    const hr: i32 = s.human_of_body[right];
    if (hl < 0 or hr < 0) {
        return null;
    }

    const robot_axis: Vec = s.robot_data.body_xpos[left] - s.robot_data.body_xpos[right];
    // ★ Already in the robot's frame — converted once by the caller.
    const human_y_up: Vec = rest_world[@intCast(hl)] - rest_world[@intCast(hr)];
    const robot_len: f32 = @sqrt(robot_axis[0] * robot_axis[0] +
        robot_axis[1] * robot_axis[1] + robot_axis[2] * robot_axis[2]);
    const human_len: f32 = @sqrt(human_y_up[0] * human_y_up[0] +
        human_y_up[1] * human_y_up[1] + human_y_up[2] * human_y_up[2]);
    if (robot_len < 1.0e-6 or human_len < 1.0e-6) {
        return null;
    }
    return .{
        .robot = robot_axis / @as(Vec, @splat(robot_len)),
        .human = human_y_up / @as(Vec, @splat(human_len)),
    };
}

/// Pose the robot into the character's T-pose, so both references depict the SAME pose.
///
/// ★ Thin wrapper over the SHARED solver — the example and the harness call one implementation.
fn solveRobotTPose(
    s: *State,
    rest_robot_frame: []const Vec,
    human_parents: []const i32,
) void {
    var pelvis_body: usize = 0;
    for (s.robot.names, 0..) |n, i| {
        if (std.mem.eql(u8, n, "pelvis")) {
            pelvis_body = i;
        }
    }
    z.robot.solveRestPoseFromSource(
        &s.robot.model,
        &s.robot_data,
        s.human_of_body,
        rest_robot_frame,
        human_parents,
        pelvis_body,
        s.robot_tasks,
        s.robot_ik_scratch,
        s.robot_tpose_qpos,
    );
}

/// Draw both rest poses side by side, or superimposed, with their joint frames.
///
/// ── ★★★ THE REST POSES ARE WHAT EVERY TWIST OFFSET IS BUILT FROM ──
///
/// Each `R_twist` is `shortestArc(robot rest bone -> source rest bone)`. **If those two rest
/// poses do not relate the way the code assumes, every twist is wrong and no amount of
/// per-frame work recovers it** — and until now the rest poses have only ever been inspected
/// through numbers.
///
/// ★ The offset slider superimposes them: at zero, a robot bone that does not lie along its
/// character bone IS the error in that bone's twist, visible directly.
///
/// ★★ Joint FRAMES are drawn too, not just bones. A bone shows direction; the twist offsets also
/// depend on rotation ABOUT that direction, which a capsule cannot show and which has already
/// cost this arc a quarter turn at the torso.
fn drawTposeComparison(s: *State, gl: *z.WgpuGl) void {
    const source: *const Character = &s.characters[s.robot_source];
    // ★ The SAME scale the T-pose solve used, or the two figures are different sizes and
    // superimposing them compares nothing.
    const draw_scale: f32 = cm_to_m * if (source.hip_height > 0.01)
        // ★★ `hip_height` IS ALREADY IN METRES while `rest_positions` are in CENTIMETRES.
        // Multiplying it by `cm_to_m` here as well divided by a hundredth and drew a T-pose the
        // size of a building. **Two quantities from the same struct in different units is the
        // trap**; the conversion belongs on the positions only.
        robot_hip_height_m / source.hip_height
    else
        1.0;
    if (!s.robot_ready) {
        // ★ Nothing to draw yet. Saying so beats an empty scene that reads as "the robot has no
        // T-pose" when it means "this view has no data".
        return;
    }
    const joint_count: usize = source.boneCount();
    const shift: Vec = vec(s.tpose_offset, 0, 0);

    // ── The CHARACTER's T-pose ──
    for (0..joint_count) |joint| {
        const parent: i32 = source.target_parents[joint];
        if (parent < 0) {
            continue;
        }
        const from: Vec = source.rest_positions[@intCast(parent)] * @as(Vec, @splat(draw_scale));
        const to: Vec = source.rest_positions[joint] * @as(Vec, @splat(draw_scale));
        drawBoneSegment(gl, from, to, Color{ .r = 240, .g = 150, .b = 60, .a = 255 }, 0.012);
    }
    for (0..joint_count) |joint| {
        const at: Vec = source.rest_positions[joint] * @as(Vec, @splat(draw_scale));
        drawJointFrame(gl, at, source.rest_orientations[joint], 0.05);
    }

    // ── The ROBOT's rest pose, in Y-up for display ──
    for (1..s.robot.model.nbody) |body| {
        const parent: u32 = s.robot.model.body_parent[body];
        if (parent == 0) {
            continue;
        }
        const child_z: Vec = s.robot_rest_xpos[body];
        const parent_z: Vec = s.robot_rest_xpos[parent];
        const from: Vec = vec(parent_z[0], parent_z[2], -parent_z[1]) + shift;
        const to: Vec = vec(child_z[0], child_z[2], -child_z[1]) + shift;
        drawBoneSegment(gl, from, to, Color{ .r = 150, .g = 240, .b = 140, .a = 255 }, 0.016);
    }
    // ★★ THE ROBOT HAS NO TOE. `foot_left`/`foot_right` are LEAF bodies at the ankle and the
    // foot's shape is a GEOM, not a body — so where Geno draws a foot bone there is nothing on
    // the robot to match it. **That is the model, not a missing bone**, and the comparison is
    // honest about it rather than looking broken.
    if (s.show_robot_geoms) {
        drawRobotGeoms(
            s,
            gl,
            s.robot_rest_xpos,
            s.robot_rest_xrot,
            shift,
            .{ .r = 120, .g = 210, .b = 120, .a = 255 },
        );
    }

    for (1..s.robot.model.nbody) |body| {
        const p_z: Vec = s.robot_rest_xpos[body];
        // ★ `humanoid.xml` declares no body rotations, so every rest frame is IDENTITY — the
        // triads all point the same way, and seeing that is itself the point: it is why the
        // robot side needs no local-frame division and the source side does.
        drawJointFrame(gl, vec(p_z[0], p_z[2], -p_z[1]) + shift, zm.quat_identity, 0.06);
    }
}

/// Draw a robot's actual GEOMS at the poses in `xpos`/`xrot`.
///
/// ── ★★★ THE GEOMS ARE THE ROBOT'S REAL SHAPE ──
///
/// Capsules drawn between body ORIGINS are a proxy: they show the kinematic tree, not the
/// figure. **The foot is the clearest case — `foot_left` is a leaf body at the ankle with no
/// child, so the tree view drew nothing there and it read as "no feet"**, when the foot exists
/// perfectly well as a geom.
///
/// ★ Each geom sits at `geom_pos`/`geom_rot` in its body's LOCAL frame, so its world placement
/// is the body's transform composed with that.
fn drawRobotGeoms(
    s: *State,
    gl: *z.WgpuGl,
    xpos: []const Vec,
    xrot: []const Quat,
    shift: Vec,
    color: Color,
) void {
    for (0..s.robot.model.geom_shape.len) |geom| {
        const body: u32 = s.robot.model.geom_body[geom];
        if (body >= xpos.len) {
            continue;
        }
        const body_position: Vec = xpos[body];
        const body_rotation: Quat = xrot[body];
        const local_position: Vec = s.robot.model.geom_pos[geom];
        const world_z_up: Vec = body_position + zm.rotate(body_rotation, local_position);
        const world_rotation: Quat = zm.qmul(body_rotation, s.robot.model.geom_rot[geom]);

        // ★ Z-up to Y-up for display, the same conversion the rest of the view uses.
        const at: Vec = vec(world_z_up[0], world_z_up[2], -world_z_up[1]) + shift;

        switch (s.robot.model.geom_shape[geom]) {
            .sphere => |sphere| {
                z.drawSphere(gl, at, .{ .radius = sphere.radius, .rings = 6, .slices = 8, .color = color });
            },
            // ★ Separate arms:  and  are distinct payload types even though
            // their fields match, so one capture cannot serve both.
            .capsule => |segment| {
                const axis_z_up: Vec =
                    zm.rotate(world_rotation, vec(0, segment.half_height, 0));
                const axis: Vec = vec(axis_z_up[0], axis_z_up[2], -axis_z_up[1]);
                z.drawCapsule(gl, at - axis, at + axis, segment.radius, 8, 4, color);
            },
            .cylinder => |segment| {
                // ★ zimr's capsule runs along LOCAL Y, not MuJoCo's Z — noted in `GeomShape`
                // and easy to get backwards, which would draw every limb across the body.
                const axis_z_up: Vec =
                    zm.rotate(world_rotation, vec(0, segment.half_height, 0));
                const axis: Vec = vec(axis_z_up[0], axis_z_up[2], -axis_z_up[1]);
                z.drawCapsule(gl, at - axis, at + axis, segment.radius, 8, 4, color);
            },
            else => {
                // Boxes and meshes: a sphere at the centre is enough to show it is there.
                z.drawSphere(gl, at, .{ .radius = 0.03, .rings = 4, .slices = 6, .color = color });
            },
        }
    }
}

/// A short capsule between two points, skipped when they coincide.
fn drawBoneSegment(
    gl: *z.WgpuGl,
    from: Vec,
    to: Vec,
    color: Color,
    radius: f32,
) void {
    const bone: Vec = to - from;
    const length_squared: f32 = bone[0] * bone[0] + bone[1] * bone[1] + bone[2] * bone[2];
    if (length_squared < 1.0e-9) {
        return;
    }
    z.drawCapsule(gl, from, to, radius, 6, 4, color);
}

/// Three short lines along a joint's own axes: red X, green Y, blue Z.
fn drawJointFrame(gl: *z.WgpuGl, at: Vec, rotation: Quat, size: f32) void {
    const axes = [3]Vec{ vec(size, 0, 0), vec(0, size, 0), vec(0, 0, size) };
    const colors = [3]Color{
        .{ .r = 255, .g = 70, .b = 70, .a = 255 },
        .{ .r = 70, .g = 255, .b = 70, .a = 255 },
        .{ .r = 90, .g = 140, .b = 255, .a = 255 },
    };
    inline for (axes, colors) |axis, color| {
        z.drawLine3D(gl, at, at + zm.rotate(rotation, axis), color);
    }
}

/// Draw the robot as capsules between each body and its parent — the same shape the character
/// skeletons use, so the three are directly comparable.
fn drawRobotCapsules(s: *State, gl: *z.WgpuGl, color: Color, radius: f32) void {
    // ── ★★★ OVERLAY: DRAW THE ROBOT ON TOP OF THE CHARACTER IT IS FOLLOWING ──
    //
    // Side by side, judging the retarget means mentally aligning two figures a couple of metres
    // apart — and capsules against a skinned mesh make that harder still. **Overlaid, every
    // discrepancy is the visible gap between a capsule and the limb it should lie along.**
    //
    // ★ The source character's own root offset is subtracted so the two share an origin; the
    // toggle keeps the side-by-side view for when the robot alone is what matters.
    const stand: Vec = if (s.robot_overlay)
        s.characters[s.robot_source].offset
    else
        vec(2.1, 0, 0);
    // ★★ The ROBOT's frames matter most: a foot pitched the wrong way, a head target driven into
    // the ground and a 90-degree rest convention were all invisible orientation errors on these
    // bodies. **Drawn in the same Y-up display frame as the capsules**, so the two skeletons'
    // axes can be compared directly.
    if (s.show_transforms) {
        for (1..s.robot.model.nbody) |body| {
            const z_up: Quat = s.robot_data.body_xrot[body];
            drawTransformAxes(
                gl,
                s.robot_positions_y_up[body] + stand,
                // ★ The robot solves in Z-up and this view is Y-up, the same conversion the
                // positions get one line below. **An axis drawn in the wrong up-convention would
                // be a diagnostic that lies**, which is worse than none.
                zm.qmul(zm.quatFromAxisAngle(vec(1, 0, 0), -1.5707963), z_up),
                s.axis_length,
            );
        }
    }

    for (1..s.robot.model.nbody) |body| {
        const position: Vec = s.robot_positions_y_up[body] + stand;
        const parent: u32 = s.robot.model.body_parent[body];
        if (parent == 0) {
            z.drawSphere(gl, position, .{
                .radius = radius * 1.6,
                .rings = 6,
                .slices = 8,
                .color = color,
            });
            continue;
        }
        const parent_position: Vec = s.robot_positions_y_up[parent] + stand;
        const bone: Vec = position - parent_position;
        const length_squared: f32 = bone[0] * bone[0] + bone[1] * bone[1] + bone[2] * bone[2];
        if (length_squared < 1.0e-9) {
            continue;
        }
        z.drawCapsule(gl, parent_position, position, radius, 8, 4, color);
    }
}

/// Read a T-pose BVH and produce this skeleton's reference orientations from it.
///
/// ── ★ WHY THE POSE HAS TO BE FORWARD-KINEMATIC'D ──
///
/// A BVH stores LOCAL rotations per joint. The reference a retarget needs is each joint's WORLD
/// orientation, so the hierarchy has to be walked and rotations accumulated — the same
/// accumulation the retarget itself does, applied once at load.
///
/// ★ Joints are matched BY NAME rather than by index. The T-pose file and the FBX describe the
/// same skeleton, but nothing guarantees the two loaders emit them in the same order, and a
/// silent index mismatch would rotate the wrong joints.
fn referenceOrientationsFromTPoseBvh(
    gpa: Allocator,
    tpose_bytes: []const u8,
    target_clip: d3.BvhSkeletalClip,
    out_reference_orientations: []Quat,
    /// ★ World POSITIONS from the same T-pose, matched by name. The twist offsets need bone
    /// DIRECTIONS, and taking them from the character's `bindPose` instead uses **Geno's
    /// A-POSE** — the mistake this arc has now made in four separate places.
    out_reference_positions: ?[]Vec,
) !void {
    var tpose: z.codecs.bvh.Data = try z.codecs.bvh.parse(gpa, tpose_bytes, null);
    defer tpose.deinit();

    const pose_joint_count: usize = tpose.joints.len;
    const target_joint_count: usize = target_clip.boneCount();

    // Decode frame 0's rotation channels into local rotations.
    const pose_local_rotations: []Quat = try gpa.alloc(Quat, pose_joint_count);
    defer gpa.free(pose_local_rotations);
    const first_frame: []const f32 = tpose.motion[0..tpose.channel_count];
    var channel_cursor: usize = 0;
    for (tpose.joints, 0..) |joint, index| {
        const joint_values: []const f32 = first_frame[channel_cursor..][0..joint.channels.len];
        channel_cursor += joint.channels.len;
        pose_local_rotations[index] = quatFromBvhChannels(joint.channels, joint_values);
    }

    // Accumulate into world positions too, when asked: the same walk, one extra term.
    const pose_world_positions: []Vec = try gpa.alloc(Vec, pose_joint_count);
    defer gpa.free(pose_world_positions);

    // Accumulate into world orientations.
    const pose_global_rotations: []Quat = try gpa.alloc(Quat, pose_joint_count);
    defer gpa.free(pose_global_rotations);
    for (tpose.joints, 0..) |joint, index| {
        const offset: Vec = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
        if (joint.parent < 0) {
            pose_global_rotations[index] = pose_local_rotations[index];
            pose_world_positions[index] = offset;
        } else {
            const parent: usize = @intCast(joint.parent);
            pose_global_rotations[index] =
                zm.qmul(pose_global_rotations[parent], pose_local_rotations[index]);
            // ★ ROTATED by the parent's world orientation. Accumulating raw offsets — which is
            // what the `bindPose` path did — is only correct when every rest rotation is
            // identity, and Geno's A-pose bind is emphatically not.
            pose_world_positions[index] =
                pose_world_positions[parent] + zm.rotate(pose_global_rotations[parent], offset);
        }
    }

    // Match by name, so a joint the T-pose file lacks keeps identity rather than borrowing
    // whichever joint happens to share its index.
    const pose_names: [][]const u8 = try gpa.alloc([]const u8, pose_joint_count);
    defer gpa.free(pose_names);
    for (tpose.joints, 0..) |joint, index| {
        pose_names[index] = joint.name;
    }
    const target_names: [][]const u8 = try gpa.alloc([]const u8, target_joint_count);
    defer gpa.free(target_names);
    for (0..target_joint_count) |joint| {
        target_names[joint] = target_clip.boneName(joint);
    }
    const pose_of_target: []i32 =
        try z.codecs.bvh.mapJointsByName(gpa, pose_names, target_names, .{});
    defer gpa.free(pose_of_target);

    if (out_reference_positions) |out_positions| {
        for (0..target_joint_count) |target_joint| {
            const matched: i32 = pose_of_target[target_joint];
            out_positions[target_joint] = if (matched < 0)
                vec(0, 0, 0)
            else
                pose_world_positions[@intCast(matched)];
        }
    }

    for (0..target_joint_count) |target_joint| {
        const matched_pose_joint: i32 = pose_of_target[target_joint];
        out_reference_orientations[target_joint] = if (matched_pose_joint == z.codecs.bvh.no_source)
            zm.quat_identity
        else
            pose_global_rotations[@intCast(matched_pose_joint)];
    }
}

/// Euler channels to a quaternion, in the order the BVH header declares them.
///
/// ★ BVH applies rotation channels IN THE ORDER LISTED, which for these files is ZYX. Assuming
/// XYZ bends every joint about the wrong axis first.
fn quatFromBvhChannels(channels: []const z.codecs.bvh.Channel, values: []const f32) Quat {
    var rotation: Quat = zm.quat_identity;
    for (channels, 0..) |channel, index| {
        const angle_radians: f32 = radFromDeg(values[index]);
        const axis: ?Vec = switch (channel) {
            .x_rotation => vec(1, 0, 0),
            .y_rotation => vec(0, 1, 0),
            .z_rotation => vec(0, 0, 1),
            else => null,
        };
        if (axis) |rotation_axis| {
            rotation = zm.qmul(rotation, zm.quatFromAxisAngle(rotation_axis, angle_radians));
        }
    }
    return rotation;
}

// ── ★★ `solveArmChain` and `ArmNames` DELETED ──
//
// A masked, joint-limited two-target solve per limb, run after the pose loop. It was the best of
// the six mechanisms and it is still a special case of the point cloud: two of its targets are
// two of the samples, and its mask is unnecessary once nothing runs afterwards to be protected
// from. **~90 lines, and the seam it lived in is gone with it.**

fn boneLength(v: Vec) f32 {
    return @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
}

/// The shortest rotation taking `from` onto `to`, both unit vectors.
///
/// ★ Shortest because twist about the resulting axis is unobservable in a direction — picking
/// the twist-free rotation is the honest default rather than an arbitrary choice.
fn shortestArcBetween(from: Vec, to: Vec) Quat {
    const alignment: f32 = from[0] * to[0] + from[1] * to[1] + from[2] * to[2];
    if (alignment > 0.99999) {
        return zm.quat_identity;
    }
    if (alignment < -0.99999) {
        // Exactly opposed: no unique axis, so any perpendicular will do.
        const helper: Vec = if (@abs(from[0]) < 0.9) vec(1, 0, 0) else vec(0, 1, 0);
        const axis: Vec = normalize3(vec(
            from[1] * helper[2] - from[2] * helper[1],
            from[2] * helper[0] - from[0] * helper[2],
            from[0] * helper[1] - from[1] * helper[0],
        ));
        return zm.quatFromAxisAngle(axis, 3.14159265);
    }
    const axis: Vec = normalize3(vec(
        from[1] * to[2] - from[2] * to[1],
        from[2] * to[0] - from[0] * to[2],
        from[0] * to[1] - from[1] * to[0],
    ));
    return zm.quatFromAxisAngle(axis, acosRad(clamp(alignment, -1.0, 1.0)));
}

/// The root's height above the floor at rest — the scale reference for root travel.
///
/// ★ HIP HEIGHT, NOT TOTAL HEIGHT. What has to match between two characters is how far the
/// root moves relative to LEG LENGTH: two figures of equal standing height but different legs
/// take different strides. See `codecs.bvh.scaleRootPosition`.
fn rootHeightAtRest(clip: d3.BvhSkeletalClip) f32 {
    const rest_pose: [*]z.types.Transform = @ptrCast(@alignCast(clip.skeleton.bindPose orelse return 1.0));
    const root_translation: Vec = rest_pose[0].translation;
    const height: f32 = @abs(root_translation[1]);
    // A skeleton whose root sits at the origin tells us nothing; fall back to a sane figure
    // rather than dividing by zero later.
    return if (height > 0.01) height else 1.0;
}

/// Rebuild `source_of_target` for whatever clip currently drives this character.
fn refreshRetargetMap(
    gpa: Allocator,
    character: *Character,
    source: *const Character,
    align_rest_poses: bool,
) !void {
    const target_joint_count: usize = character.boneCount();
    const source_joint_count: usize = source.boneCount();

    const target_names: [][]const u8 = try gpa.alloc([]const u8, target_joint_count);
    defer gpa.free(target_names);
    for (0..target_joint_count) |joint| {
        target_names[joint] = character.model.clip.boneName(joint);
    }
    const source_names: [][]const u8 = try gpa.alloc([]const u8, source_joint_count);
    defer gpa.free(source_names);
    for (0..source_joint_count) |joint| {
        source_names[joint] = source.clip.boneName(joint);
    }

    const map: []i32 = try z.codecs.bvh.mapJointsByName(gpa, source_names, target_names, .{});
    defer gpa.free(map);
    @memcpy(character.source_of_target, map);
    character.mapped_joint_count = z.codecs.bvh.mappedCount(map);

    // ★ The rest correction is a property of the PAIR, so it is rebuilt alongside the map.
    if (align_rest_poses) {
        z.codecs.bvh.restAlignmentOffsets(
            character.source_of_target[0..target_joint_count],
            source.rest_orientations[0..source_joint_count],
            character.rest_orientations[0..target_joint_count],
            character.rest_alignment[0..target_joint_count],
        );
    } else {
        for (character.rest_alignment[0..target_joint_count]) |*correction| {
            correction.* = zm.quat_identity;
        }
    }
}

/// Pose a character from ANOTHER character's clip.
///
/// ── ★ THREE STEPS, EACH ALREADY VERIFIED ON ITS OWN ──
///
///   1. Sample the SOURCE clip and accumulate its GLOBAL rotations.
///   2. `retargetRotations` turns those into local rotations on the TARGET's hierarchy. It
///      works in global space, so a joint the target lacks is absorbed automatically.
///   3. `bvhForwardKinematicsFromRotations` walks the TARGET's OWN rest offsets, so the motion
///      lands on the target's proportions rather than the source's.
///
/// ★★ STEP 3 MUST NOT USE `bvhForwardKinematics`. That one reads the frame's stored
/// TRANSLATIONS, which encode the SOURCE's bone lengths — using it here would give the target
/// the source's skeleton and quietly defeat the retarget.
fn poseCharacterRetargeted(
    character: *Character,
    source: *const Character,
    frame: usize,
) void {
    const source_joint_count: usize = source.boneCount();
    const target_joint_count: usize = character.boneCount();

    // Step 1 — the source's pose in world space. Scratch is sized to the largest skeleton in
    // the scene, so a source with more joints than the target still fits.
    d3.bvhForwardKinematics(
        source.clip,
        frame,
        character.source_positions[0..source_joint_count],
        character.source_global_rotations[0..source_joint_count],
    );

    // Step 2 — the source's orientations, expressed on the target's hierarchy.
    z.codecs.bvh.retargetRotations(
        character.target_parents[0..target_joint_count],
        character.source_of_target[0..target_joint_count],
        character.source_global_rotations[0..source_joint_count],
        character.rest_alignment[0..target_joint_count],
        character.retargeted_local_rotations[0..target_joint_count],
        character.retargeted_global_rotations[0..target_joint_count],
    );

    // The root travels as far as the source's root did, scaled for the size difference.
    const source_root_position: Vec = character.source_positions[0];
    const scaled_root_position: Vec = z.codecs.bvh.scaleRootPosition(
        source_root_position,
        source.hip_height,
        character.hip_height,
    );

    // Step 3 — the target's own bones, driven by the retargeted rotations.
    d3.bvhForwardKinematicsFromRotations(
        character.model.clip,
        scaled_root_position,
        character.retargeted_local_rotations[0..target_joint_count],
        character.positions,
        character.rotations,
    );

    // Skin matrices from the posed skeleton, exactly as the native path does.
    for (0..target_joint_count) |joint| {
        const joint_world: Mat = mulMat(
            translationV(character.positions[joint]),
            matFromQuat(character.rotations[joint]),
        );
        character.skin[joint] = mulMat(joint_world, character.model.inverse_bind[joint]);
    }
}

/// One character's world placement.
fn placementOf(c: *const Character) Mat {
    return translationV(c.offset);
}

/// Draw every character through the `lit_shadow` pipeline — which is what makes them RECEIVE
/// shadows, including their own.
///
/// ★ SELF-SHADOWING IS NOT A SEPARATE FEATURE. The depth map already contains the characters
/// (they are the casters), and `lit_shadow_fs` shadows any fragment whose light-space depth is
/// greater than the map's. Drawing the characters with the receiving shader is the whole of
/// it: an arm now darkens the chest behind it because the arm is nearer the light.
///
/// The cost is that they leave the engine's batch entirely — no more `drawMeshInstanced`, so
/// `uploadMeshGpu` at init is what puts their vertices on the GPU.
fn drawCharactersLit(
    s: *State,
    f: *z.Frame,
    cam_vp: Mat,
    light_vp: Mat,
    light_dir: Vec,
) void {
    const gl: *z.WgpuGl = f.gl;
    const ps: *z.PassState = gl.pass;
    const Backend: type = z.WgpuBackend;
    Backend.setPipeline(ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.ground_pipeline });
    Backend.setBindGroup(ps, 1, s.ground_g1);

    for (&s.characters, 0..) |*c, ci| {
        const model: Mat = placementOf(c);
        const vs: LitVsUbo = .{
            .mvp = mulMat(cam_vp, model),
            .light_vp = mulMat(light_vp, model),
            // Uniform scale plus translation: the rotation block is identity, so the inverse
            // transpose is too. A non-uniform scale would need the real thing.
            .normal_matrix = zm.identity(),
        };
        const fs: LitFsUbo = .{
            .light_dir = -normalize3(light_dir),
            .base_color = character_albedo,
            .params = .{ s.shadow_bias_slope, s.shadow_bias_min, 0, 0 },
        };
        const vb: [z.shader.wireSizeOf(LitVsUbo)]u8 = z.shader.wireOf(LitVsUbo, &vs);
        z.wgpu.queueWriteBuffer(f.gpu.queue, s.char_vs_ubos[ci], 0, &vb);
        const fb: [z.shader.wireSizeOf(LitFsUbo)]u8 = z.shader.wireOf(LitFsUbo, &fs);
        z.wgpu.queueWriteBuffer(f.gpu.queue, s.char_fs_ubos[ci], 0, &fb);
        Backend.setBindGroup(ps, 0, s.char_g0[ci]);
        Backend.setBindGroup(ps, 2, s.char_g2[ci]);

        for (0..@intCast(c.model.model.meshCount)) |m| {
            const buf: z.MeshGpu = z.meshGpuBuffers(gl, c.model.model.meshes[m]) orelse continue;
            drawIndexedBuffers(ps, buf);
        }
    }
}

/// Bind one mesh's buffers and issue its indexed draw — the tail every custom pass repeats.
fn drawIndexedBuffers(ps: *z.PassState, buf: z.MeshGpu) void {
    z.render_pass.setVertexBuffer(ps.pass, .{
        .slot = 0,
        .buffer = buf.vbo,
        .offset = 0,
        .size = 0,
    });
    z.render_pass.setIndexBuffer(ps.pass, .{
        .buffer = buf.ibo,
        .format = .uint16,
        .offset = 0,
        .size = 0,
    });
    z.render_pass.drawIndexed(ps.pass, .{
        .index_count = buf.index_count,
        .instance_count = 1,
        .first_index = 0,
        .base_vertex = 0,
        .first_instance = 0,
    });
}

/// The full scene as the camera sees it: receivers, casters, and the optional bone gizmos.
/// Render the casters' DEPTH from the light, into the shadow map.
///
/// ★ `beginTextureModeRaw`, NOT `beginTextureMode`. The plain version binds the engine's 2D
/// (rgba8) pipeline into the pass; this target is the depth pipeline's format, and mixing them
/// is an attachment mismatch. The raw pair opens the offscreen pass and batches nothing.
///
/// ★ CLEARED TO WHITE = "nothing here, infinitely far". Clearing to black would mean every
/// untouched texel reads as depth 0 — nearer than anything — and would shadow the entire
/// frustum. That inversion is exactly what the earlier white-on-black MASK produced.
fn drawLightDepth(s: *State, f: *z.Frame, light_vp: Mat) void {
    const gl: *z.WgpuGl = f.gl;
    z.beginTextureModeRaw(gl, s.light_view, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    const ps: *z.PassState = gl.pass;
    ps.queue = f.gpu.queue;
    const Backend: type = z.WgpuBackend;
    Backend.setPipeline(ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.depth_pipeline });

    for (&s.characters, 0..) |*c, ci| {
        const model: Mat = placementOf(c);
        const ubo: DepthUbo = .{
            .mvp = mulMat(light_vp, model),
            .params = .{ light_near, light_far, 0, 1 },
            // 0 = raw NDC depth, the form `lit_shadow_fs` compares against.
            .mode = 0,
        };
        const bytes: [z.shader.wireSizeOf(DepthUbo)]u8 = z.shader.wireOf(DepthUbo, &ubo);
        z.wgpu.queueWriteBuffer(f.gpu.queue, s.depth_ubos[ci], 0, &bytes);
        Backend.setBindGroup(ps, 0, s.depth_bgs[ci]);

        for (0..@intCast(c.model.model.meshCount)) |m| {
            // ★ THE SAME VBOs THE CAMERA PASS DRAWS. `meshGpuBuffers` exists for exactly this:
            // one upload per frame, read by both passes.
            const gpu_buf: z.MeshGpu = z.meshGpuBuffers(gl, c.model.model.meshes[m]) orelse continue;
            z.render_pass.setVertexBuffer(ps.pass, .{
                .slot = 0,
                .buffer = gpu_buf.vbo,
                .offset = 0,
                .size = 0,
            });
            z.render_pass.setIndexBuffer(ps.pass, .{
                .buffer = gpu_buf.ibo,
                .format = .uint16,
                .offset = 0,
                .size = 0,
            });
            z.render_pass.drawIndexed(ps.pass, .{
                .index_count = gpu_buf.index_count,
                .instance_count = 1,
                .first_index = 0,
                .base_vertex = 0,
                .first_instance = 0,
            });
        }
    }
    z.endTextureModeRaw(gl);
}

/// Fill the G-buffer: world position, world normal and albedo, in ONE geometry walk.
///
/// ★ THE INPUT SSAO NEEDS. `ssao_fs` reads positions and normals from here; without this pass
/// there is nothing for it to occlude against. Everything drawn must appear — a caster missing
/// from the G-buffer casts no ambient occlusion, exactly as a caster missing from the shadow
/// map casts no shadow.
fn drawGbuffer(s: *State, f: *z.Frame, cam_vp: Mat) void {
    const gl: *z.WgpuGl = f.gl;
    const rts = [_]z.RenderTexture{ s.gbuf_pos, s.gbuf_normal, s.gbuf_albedo };
    // ★ CLEARED TO ZERO ALPHA. `ssao_fs` reads alpha as its COVERAGE flag: a pixel the
    // geometry never touched has a meaningless position, and treating it as a real surface
    // would let the background occlude the scene.
    z.beginTextureModeMrtRaw(gl, &rts, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    const ps: *z.PassState = gl.pass;
    const Backend: type = z.WgpuBackend;
    Backend.setPipeline(ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.gbuf_pipeline });

    // Slot 0/1 are the characters; slot 2 is the ground.
    for (&s.characters, 0..) |*c, ci| {
        const model: Mat = placementOf(c);
        writeGbufUbos(s, f, ci, cam_vp, model, character_albedo);
        Backend.setBindGroup(ps, 0, s.gbuf_g0[ci]);
        Backend.setBindGroup(ps, 2, s.gbuf_g2[ci]);
        for (0..@intCast(c.model.model.meshCount)) |m| {
            const buf: z.MeshGpu = z.meshGpuBuffers(gl, c.model.model.meshes[m]) orelse continue;
            drawIndexedBuffers(ps, buf);
        }
    }

    writeGbufUbos(s, f, 2, cam_vp, zm.identity(), ground_albedo);
    Backend.setBindGroup(ps, 0, s.gbuf_g0[2]);
    Backend.setBindGroup(ps, 2, s.gbuf_g2[2]);
    drawIndexedBuffers(ps, .{
        .vbo = s.ground_vbo,
        .ibo = s.ground_ibo,
        .index_count = s.ground_index_count,
    });

    z.endTextureModeRaw(gl);
}

/// Upload one drawable's G-buffer uniforms.
fn writeGbufUbos(
    s: *State,
    f: *z.Frame,
    slot: usize,
    cam_vp: Mat,
    model: Mat,
    albedo: Vec,
) void {
    const vs: GbufVsUbo = .{
        .mvp = mulMat(cam_vp, model),
        .model = model,
        // Uniform scale plus translation, so the inverse transpose is the model matrix itself.
        .normal_matrix = model,
    };
    const fs: GbufFsUbo = .{ .albedo_spec = albedo };
    const vb: [z.shader.wireSizeOf(GbufVsUbo)]u8 = z.shader.wireOf(GbufVsUbo, &vs);
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.gbuf_vs_ubos[slot], 0, &vb);
    const fb: [z.shader.wireSizeOf(GbufFsUbo)]u8 = z.shader.wireOf(GbufFsUbo, &fs);
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.gbuf_fs_ubos[slot], 0, &fb);
}

/// Draw the ground through the `lit_shadow` pipeline, sampling the light pass.
///
/// ★ THIS BINDS A FOREIGN PIPELINE INTO THE SCREEN PASS, so the 2D pipeline must be restored
/// afterwards or the UI draws with the wrong one — the same hazard `renderer_2d.bindForPass`
/// exists to fix, and the one that produced a black canvas during the wgpu bringup.
fn drawShadowedGround(
    s: *State,
    f: *z.Frame,
    cam_vp: Mat,
    light_vp: Mat,
    light_dir: Vec,
) void {
    const gl: *z.WgpuGl = f.gl;
    const ps: *z.PassState = gl.pass;

    // The plane sits at the origin with an identity model matrix, so mvp is just the camera's
    // view-projection and the normal matrix is the identity.
    const vs: LitVsUbo = .{
        .mvp = cam_vp,
        .light_vp = light_vp,
        .normal_matrix = zm.identity(),
    };
    const fs: LitFsUbo = .{
        // `light_dir` is the direction TO the light, for the Lambert dot.
        .light_dir = -normalize3(light_dir),
        .base_color = ground_albedo,
        .params = .{ s.shadow_bias_slope, s.shadow_bias_min, 0, 0 },
    };
    const vs_bytes: [z.shader.wireSizeOf(LitVsUbo)]u8 = z.shader.wireOf(LitVsUbo, &vs);
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.ground_vs_ubo, 0, &vs_bytes);
    const fs_bytes: [z.shader.wireSizeOf(LitFsUbo)]u8 = z.shader.wireOf(LitFsUbo, &fs);
    z.wgpu.queueWriteBuffer(f.gpu.queue, s.ground_fs_ubo, 0, &fs_bytes);

    const Backend: type = z.WgpuBackend;
    Backend.setPipeline(ps, z.shader.RenderPipeline(void, void){ .gpu_handle = s.ground_pipeline });
    Backend.setBindGroup(ps, 0, s.ground_g0);
    Backend.setBindGroup(ps, 1, s.ground_g1);
    Backend.setBindGroup(ps, 2, s.ground_g2);
    drawIndexedBuffers(ps, .{
        .vbo = s.ground_vbo,
        .ibo = s.ground_ibo,
        .index_count = s.ground_index_count,
    });
}

/// Draw a body's local frame as three coloured axes: X red, Y green, Z blue.
///
/// ── ★★★ THE CONVENTION IS THE POINT ──
///
/// Half this project's hardest bugs were frames disagreeing invisibly: a foot pitched the wrong
/// way, a head target 1.5 m into the ground, a scale anchored on the wrong bone, a capture whose
/// rest orientations differ from the robot's by a constant 90 degrees. **Every one was a
/// quantity nobody could see.** Three axes per body make orientation a thing you look at rather
/// than infer from a residual.
///
/// ★ Red/green/blue for X/Y/Z is the near-universal convention; keeping it means the picture
/// needs no legend.
fn drawTransformAxes(gl: *z.WgpuGl, origin: Vec, rotation: Quat, length: f32) void {
    const axes = [_]struct { dir: Vec, color: Color }{
        .{ .dir = vec(1, 0, 0), .color = .{ .r = 235, .g = 70, .b = 70, .a = 255 } },
        .{ .dir = vec(0, 1, 0), .color = .{ .r = 80, .g = 220, .b = 90, .a = 255 } },
        .{ .dir = vec(0, 0, 1), .color = .{ .r = 80, .g = 140, .b = 255, .a = 255 } },
    };
    for (axes) |axis| {
        const tip: Vec = origin + zm.rotate(rotation, axis.dir * @as(Vec, @splat(length)));
        z.drawLine3D(gl, origin, tip, axis.color);
    }
}

fn drawScene(s: *State, gl: *z.WgpuGl) void {
    // ── ★★★ DRAW AND POSE MUST AGREE ABOUT WHETHER THE ROBOT EXISTS ──
    //
    // `poseRobot` is gated on `show_robot`; this draw was not. **So with `show_robot` false the
    // robot was never posed and still drawn** — every body at its zeroed position, which piles
    // the geoms into a ball at the origin and looks exactly like a solver that has collapsed.
    //
    // ★★★ The comment that used to sit here explained why drawing is not gated on
    // `show_skeleton` — a different flag, and correct. **It was read as covering `show_robot`
    // too**, which it never did, and that gap survived a dozen turns because a ball at the
    // origin is a plausible-looking failure of something else entirely.
    //
    // ★ Now: no pose, no draw.
    if (!s.show_robot) {
        return;
    }

    // ★ The ROBOT draws whether or not the SKELETON view is on: it has no mesh, so capsules are
    // all it has. Returning early on `show_skeleton` would hide it entirely.
    drawRobot(s, gl);

    if (!s.show_skeleton) {
        return;
    }
    const bone_colors = [_]Color{
        .{ .r = 120, .g = 200, .b = 255, .a = 255 },
        .{ .r = 255, .g = 180, .b = 110, .a = 255 },
    };
    // ★ Axes for every character joint, in the same world the capsules are drawn in.
    if (s.show_transforms) {
        for (&s.characters) |*c| {
            for (0..c.boneCount()) |joint| {
                drawTransformAxes(
                    gl,
                    c.positions[joint] + c.offset,
                    c.rotations[joint],
                    s.axis_length,
                );
            }
        }
    }

    for (&s.characters, 0..) |*c, ci| {
        drawSkeletonCapsules(c, gl, bone_colors[ci % bone_colors.len], s.capsule_radius);
    }
}

/// The robot, as capsules.
fn drawRobot(s: *State, gl: *z.WgpuGl) void {
    if (!s.show_robot) {
        return;
    }
    if (s.show_tpose_compare) {
        // ★★ THE COMPARISON NEEDS THE ROBOT'S MAP AND SOLVED T-POSE, which only exist once the
        // robot is enabled. **The first version drew nothing at all** when the robot checkbox
        // was off — a blank result that reads as "the robot has no T-pose" rather than "this
        // view has no data".
        drawTposeComparison(s, gl);
    } else {
        if (s.show_robot_geoms) {
            // ★ The robot's real shape, not a tree of body origins — which is what makes an
            // overlay against the character's mesh a fair comparison rather than a suggestive one.
            drawRobotGeoms(
                s,
                gl,
                s.robot_data.body_xpos[0..s.robot.model.nbody],
                s.robot_data.body_xrot[0..s.robot.model.nbody],
                // ★ The same placement `drawRobotCapsules` uses, so the two views agree.
                if (s.robot_overlay) s.characters[s.robot_source].offset else vec(2.1, 0, 0),
                .{ .r = 180, .g = 255, .b = 160, .a = 255 },
            );
        } else {
            drawRobotCapsules(
                s,
                gl,
                .{ .r = 180, .g = 255, .b = 160, .a = 255 },
                s.capsule_radius * 2.2,
            );
        }
    }
}

/// Draw a skeleton as CAPSULES — one per bone, from the joint to its parent.
///
/// ★ This is how BVHView and GenoView present a rig, and it reads far better than spheres and
/// lines: a capsule has THICKNESS, so it occludes correctly against the mesh and against other
/// bones, and its silhouette shows a limb's direction at a glance. `drawCapsule` already
/// exists (`wgpu_app.drawCapsule`, raylib parity) — cylinder body plus two spherical caps.
///
/// ★ ROOT AND END SITES ARE DRAWN AS BARE SPHERES. A capsule needs two endpoints; the root has
/// no parent, and an end site's "bone" is the synthetic stub §7 adds to give a leaf a
/// direction. Drawing those as spheres keeps every joint visible without inventing geometry
/// the skeleton does not have.
///
/// Kept as GEOMETRY, deliberately: §7a's analytical capsule shadows and AO are a different
/// lighting model, and mixing them into the deferred pipeline of §12 would mean maintaining
/// two.
fn drawSkeletonCapsules(c: *Character, gl: *z.WgpuGl, color: Color, radius: f32) void {
    for (0..c.boneCount()) |j| {
        const p: Vec = c.positions[j] + c.offset;
        const parent: i32 = c.clip.skeleton.bones[j].parent;
        if (parent < 0) {
            z.drawSphere(gl, p, .{ .radius = radius * 1.6, .rings = 6, .slices = 8, .color = color });
            continue;
        }
        const pp: Vec = c.positions[@intCast(parent)] + c.offset;
        const d: Vec = p - pp;
        // A zero-length bone would make `drawCapsule` build a degenerate cylinder; end sites
        // and coincident joints both produce them.
        if (d[0] * d[0] + d[1] * d[1] + d[2] * d[2] < 1.0e-9) {
            z.drawSphere(gl, p, .{ .radius = radius, .rings = 6, .slices = 8, .color = color });
            continue;
        }
        z.drawCapsule(gl, pp, p, radius, 8, 4, color);
    }
}

/// The control panel, split into TABS.
///
/// ★ It had grown to 651 px of content in a 250 px window — the UI lint said so on device, and
/// every slider needed scrolling to reach. Four tabs put each concern on one screen and let the
/// window sit small again, which matters on a phone where the panel competes with the scene for
/// the same pixels.
fn drawPanel(s: *State, u: ui.Ui, longest: f32) void {
    if (u.window("geno + mocap", .{
        .initial_pos = .{ 12, 12 },
        .initial_size = .{ 340, 268 },
    })) |w| {
        defer w.close();

        // Playback lives ABOVE the tabs: it is the one control wanted from every tab.
        _ = u.checkbox("play", &s.playing);
        u.sameLine(.{});
        _ = u.checkbox("mesh", &s.show_mesh);
        u.sameLine(.{});
        _ = u.checkbox("skeleton", &s.show_skeleton);
        u.sameLine(.{});
        // ★ Next to the skeleton toggle because it is the same kind of thing: a view of the
        // structure rather than the surface.
        _ = u.checkbox("transforms", &s.show_transforms);
        if (s.show_transforms) {
            _ = u.slider("axis length", &s.axis_length, .{ .min = 0.01, .max = 0.4, .fmt = "{d:.2}m" });
        }
        _ = u.slider("time", &s.play_time, .{ .min = 0, .max = longest, .fmt = "{d:.2}s" });

        if (u.beginTabBar("panel", .{})) {
            defer u.endTabBar();

            if (u.beginTabItem("Motion", null, .{})) {
                tabMotion(s, u);
                u.endTabItem();
            }
            if (u.beginTabItem("Light", null, .{})) {
                tabLight(s, u);
                u.endTabItem();
            }
            if (u.beginTabItem("AO", null, .{})) {
                tabAmbientOcclusion(s, u);
                u.endTabItem();
            }
            if (u.beginTabItem("Debug", null, .{})) {
                tabDebug(s, u);
                u.endTabItem();
            }
        }
    }
}

/// Who plays whose clip, and how the two rigs are aligned.
fn tabMotion(s: *State, u: ui.Ui) void {
    for (0..s.characters.len) |character_index| {
        const character: *Character = &s.characters[character_index];
        u.text("{s} plays:", .{character.label});

        // ★★ EVERY ROW NEEDS ITS OWN ID SCOPE. A widget's identity comes from its LABEL, and
        // both rows offer the same two character names — without this they share one radio
        // group and selecting a source for one moves the other's.
        u.pushIdInt(@intCast(character_index));
        defer u.popId();

        var chosen_source: i32 = @intCast(character.source_character);
        for (0..s.characters.len) |candidate_index| {
            if (u.radioButton(
                s.characters[candidate_index].label,
                &chosen_source,
                @intCast(candidate_index),
            )) {
                character.source_character = @intCast(chosen_source);
                s.retarget_dirty = true;
            }
            if (candidate_index + 1 < s.characters.len) {
                u.sameLine(.{});
            }
        }
        const is_retargeting: bool = character.source_character != character_index;
        if (is_retargeting) {
            u.text("  mapped {d}/{d} joints", .{
                character.mapped_joint_count,
                character.boneCount(),
            });
        }
    }
    u.separator();
    if (u.checkbox("align rest poses", &s.align_rest)) {
        s.retarget_dirty = true;
    }

    // ── ★ THE ROBOT ──
    // ★ The label names the file actually embedded. It said `humanoid.xml` for several turns
    // after the example switched to the flex model — **a UI that lies about which model it is
    // showing makes every screenshot ambiguous.**
    _ = u.checkbox("robot (humanoid_flex2.xml)", &s.show_robot);
    // ── ★★★ A CONTROL THAT CANNOT WORK IS WORSE THAN NO CONTROL ──
    //
    // The model is parsed in `initRobot`, which runs ONCE. Marking `robot_dirty` refreshes the
    // MAPPING, not the model — so a checkbox here would have looked live and done nothing, and
    // a screenshot taken after clicking it would have shown flex2 while claiming stock.
    //
    // ★★ **That is the same class as the label that read `humanoid.xml` while embedding
    // flex2**, and worse: a stale label misleads once, a dead control misleads every time it is
    // used. Reloading the robot mid-session means rebuilding the model, data, tasks, scratch,
    // samples and rest pose — real work, not a checkbox.
    //
    // ★ Until then the swap is a one-line edit at `initRobot`, and the comment there says so.
    if (s.show_robot) {
        // ── ★★★ SAY WHICH CLIP DRIVES THE ROBOT, NOT "robot plays" ──
        //
        // The panel had three separate "X plays:" groups — one per character and one for the
        // robot — with the same two clip names in each. **Three identical-looking radio pairs,
        // and nothing said which one moved the blue figure.** "does not follow the dance when I
        // ask it to" is what that ambiguity looks like from outside.
        //
        // ★ The heading now names the thing being driven and the row shows the current choice,
        // so the answer is readable without experimenting.
        u.text("ROBOT is driven by:", .{});
        // ★★ DISTINCT LABELS, not just a distinct ID SCOPE. These rows offered the very same
        // two character names as the rows above, and relying on `pushIdInt` alone to keep them
        // apart left the robot's selection unreachable. A label that differs is not something a
        // later edit can accidentally undo — an id scope is.
        // ★ Prefixed so they cannot be confused with the character rows above, which offer the
        // same two clips for a different purpose.
        // ★ ASCII only: the UI font has no glyph for "→" and rendered it as "?", which made the
        // labels read as questions. **A label that renders wrong is worse than a plain one.**
        const robot_choice_labels = [_][]const u8{ "use Geno dance1", "use Mixamo drop kick" };
        var robot_choice: i32 = @intCast(s.robot_source);
        for (0..s.characters.len) |candidate_index| {
            if (u.radioButton(
                robot_choice_labels[candidate_index % robot_choice_labels.len],
                &robot_choice,
                @intCast(candidate_index),
            )) {
                s.robot_source = @intCast(robot_choice);
                s.robot_dirty = true;
            }
            if (candidate_index + 1 < s.characters.len) {
                u.sameLine(.{});
            }
        }
        // ★ THE HONEST QUALITY NUMBER, ON SCREEN. A 16-body robot cannot express what 96 human
        // joints do, and its one-hinge knee cannot follow a human knee's twist. Showing the
        // mean unrepresentable angle keeps a MODEL LIMIT from reading as a bug.
        // ★ THE IK STAGE IS TOGGLEABLE, and off is the A/B that says whether the position
        // targets are helping rather than assuming they must. Radio buttons rather than a
        // slider because the interesting question is "none / a few / many", not a fine dial.
        // ★ IK stays: it is the one control that still changes the answer, and OFF is the A/B
        // that shows what the solver contributes — measured, the knee goes 61.6 -> 10.2 deg.
        // ★ The overlay is the instrument: a capsule that does not lie along its limb is the
        // error, directly, with no mental alignment in between.
        if (u.checkbox("T-pose compare", &s.show_tpose_compare)) {
            // ★ Turning the view on enables the robot and forces a rebuild, so it cannot show
            // an empty scene because of state it silently depends on.
            if (s.show_tpose_compare) {
                s.show_robot = true;
                s.robot_dirty = true;
            }
        }
        if (s.show_tpose_compare) {
            _ = u.slider("offset", &s.tpose_offset, .{
                .min = -0.5,
                .max = 2.0,
                .fmt = "{d:.2}",
            });
            if (s.robot_ready) {
                u.text("  orange=geno  green=robot  RGB=XYZ axes", .{});
                // ★ Explaining a real difference beats letting it read as a defect.
                u.text("  robot has no toe: its foot is a leaf at the ankle", .{});
            } else {
                u.text("  building robot rest pose...", .{});
            }
        }
        _ = u.checkbox("robot geoms (real shape)", &s.show_robot_geoms);
        _ = u.checkbox("overlay on character", &s.robot_overlay);
        if (s.robot_overlay and s.show_mesh) {
            // ★ An opaque mesh hides the capsules inside it, so the overlay reads as nothing at
            // all. Saying so beats letting someone conclude the robot vanished.
            u.text("  (turn OFF mesh to see it)", .{});
        }
        // ★ The shape/place dial, next to the fit readout that judges it.
        _ = u.slider("target pull", &s.robot_position_pull, .{ .min = 0, .max = 1, .fmt = "{d:.2}" });
        u.text("ik refine:", .{});
        _ = u.radioButton("off", &s.robot_ik_iterations, 0);
        u.sameLine(.{});
        _ = u.radioButton("on", &s.robot_ik_iterations, 20);
        // ★ Now the SOLVER's residual — how far the robot ended from the targets it was
        // given — rather than a per-joint rotation shortfall.
        if (s.robot_mean_residual < 0) {
            u.text("  ik error --  (solver idle)", .{});
        } else {
            u.text("  ik error {d:.3}", .{s.robot_mean_residual});
        }

        // ── ★★★ THE MEASUREMENTS, ON DEVICE ──
        //
        // Every metric in this project lives in the harness, on Geno. **The drop kick exists
        // only here**, so every diagnosis this session went: screenshot -> guess -> measure
        // something else in a different program. Six silent failures were found that way, each
        // costing turns.
        //
        // ★★★ These three answer the questions that actually went wrong:
        //
        //     bodies   an unmapped table hides the robot and looks like a render bug
        //     samples  a stale cache retargets to the WRONG BONES with no error at all
        //     visual   mean and WORST world offset — the 10 cm no angle metric could see
        //
        // ★ Cheap: they are read from state the solve already computed.
        // ★★ The fit against the clip the robot is ACTUALLY driven by. A large number here with
        // a plausible-looking figure on screen means the robot is tracking something else.
        // ★★★ THE SCALE, ON SCREEN. It is a DIVISOR applied to every target, so a wrong one
        // does not degrade the robot — it collapses it. **Two turns were spent on a ball at the
        // origin that this one number would have named immediately**, because a scale is not
        // something a picture shows: a robot 10x too small and a robot at the wrong place look
        // the same from outside.
        // ── ★★★ WHERE THE BONES ACTUALLY END UP ──
        //
        // Scale right, bodies mapped, samples built, 21179 frames posed — **and still a ball.**
        // Every aggregate says the machinery ran; none says WHERE it put anything. A root at the
        // origin and a root in the right place produce the same counts.
        //
        // ★ Root, its target, and the span of the whole robot. **A span near zero is a collapse;
        // a good span in the wrong place is a placement error** — and those are the two things
        // that have been confused for three turns.
        {
            var lo: Vec = .{ 1.0e9, 1.0e9, 1.0e9, 0 };
            var hi: Vec = .{ -1.0e9, -1.0e9, -1.0e9, 0 };
            for (1..s.robot.model.nbody) |b| {
                const p: Vec = s.robot_data.body_xpos[b];
                lo = @min(lo, p);
                hi = @max(hi, p);
            }
            const span: Vec = hi - lo;
            u.text("  robot span {d:.2} x {d:.2} x {d:.2} m", .{ span[0], span[1], span[2] });
            const root: Vec = s.robot_data.body_xpos[1];
            u.text("  root at {d:.2},{d:.2},{d:.2}", .{ root[0], root[1], root[2] });
        }

        u.text("  capture scale {d:.5}  (hip {d:.3} m)", .{
            captureScale(s, &s.characters[s.robot_source]),
            robot_hip_height_m,
        });
        u.text("  bodies {d}/{d}  samples {d}  posed {d}", .{
            s.robot_mapped_count,
            s.robot.model.nbody -| 1,
            s.robot_sample_count,
            s.robot_posed_frames,
        });
        if (s.robot_visual_worst >= 0) {
            u.text("  fit {d:.3} m  worst {d:.3} m {s}", .{
                s.robot_visual_mean,
                s.robot_visual_worst,
                s.robot_visual_worst_name,
            });
        }
    }
    if (s.show_skeleton) {
        _ = u.slider("bone radius", &s.capsule_radius, .{
            .min = 0.004,
            .max = 0.05,
            .fmt = "{d:.3}",
        });
    }
}

/// Sun direction and shadow bias.
fn tabLight(s: *State, u: ui.Ui) void {
    _ = u.checkbox("ground", &s.show_ground);
    _ = u.slider("light yaw", &s.light_yaw, .{ .min = 0.0, .max = 360.0, .fmt = "{d:.0}" });
    _ = u.slider("light pitch", &s.light_pitch, .{ .min = 5.0, .max = 89.0, .fmt = "{d:.0}" });
    u.separator();
    _ = u.slider("bias slope", &s.shadow_bias_slope, .{
        .min = 0.0,
        .max = 0.02,
        .fmt = "{d:.4}",
    });
    _ = u.slider("bias min", &s.shadow_bias_min, .{ .min = 0.0, .max = 0.01, .fmt = "{d:.4}" });
}

/// Ambient occlusion and its bilateral blur.
fn tabAmbientOcclusion(s: *State, u: ui.Ui) void {
    _ = u.checkbox("ao", &s.show_ao);
    _ = u.slider("radius", &s.ssao_radius, .{ .min = 0.05, .max = 2.0, .fmt = "{d:.2}" });
    _ = u.slider("bias", &s.ssao_bias, .{ .min = 0.0, .max = 0.2, .fmt = "{d:.3}" });
    _ = u.slider("power", &s.ssao_intensity, .{ .min = 0.0, .max = 1.0, .fmt = "{d:.2}" });
    u.separator();
    _ = u.checkbox("blur", &s.blur_ao);
    if (s.blur_ao) {
        _ = u.slider("falloff", &s.blur_falloff, .{ .min = 0.5, .max = 60.0, .fmt = "{d:.1}" });
        _ = u.slider("normal", &s.blur_normal_power, .{ .min = 1.0, .max = 32.0, .fmt = "{d:.1}" });
    }
}

/// The offscreen-target inset and the scene's vital statistics.
fn tabDebug(s: *State, u: ui.Ui) void {
    _ = u.checkbox("inset", &s.show_light_view);
    if (s.show_light_view) {
        _ = u.radioButton("shadow", &s.debug_view, 0);
        u.sameLine(.{});
        _ = u.radioButton("pos", &s.debug_view, 1);
        u.sameLine(.{});
        _ = u.radioButton("nrm", &s.debug_view, 2);
        _ = u.radioButton("albedo", &s.debug_view, 3);
        u.sameLine(.{});
        _ = u.radioButton("ao map", &s.debug_view, 4);
    }
    u.separator();
    if (s.status_len > 0) {
        u.text("{s}", .{s.status[0..s.status_len]});
    }
    for (&s.characters) |*c| {
        var vertex_count: i32 = 0;
        for (0..@intCast(c.model.model.meshCount)) |mesh_index| {
            vertex_count += c.model.model.meshes[mesh_index].vertexCount;
        }
        u.text("{s}: {d} bones, {d} verts, {d:.1}s", .{
            c.label,
            c.boneCount(),
            vertex_count,
            c.duration(),
        });
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - geno + mocap",
            .width = screen_w,
            .height = screen_h,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};

/// Where the robot's ROOT body should sit — the position of the capture joint it maps to.
///
/// ★ Not the capture's root. `humanoid.xml`'s root is the TORSO and maps to `Spine3`; the
/// capture's root is `Hips`, a spine lower.
fn rootBodyWorldPosition(s: *const State, positions: []const Vec) ?Vec {
    // ★★ FROM 1, NOT 0. Body 0 is the WORLD and its parent is also 0, so a scan from zero
    // matches it first, finds no mapped joint, and returns null — the translation is then never
    // written and the robot stands at the origin for the whole take. **A sentinel that also
    // satisfies the predicate is not a sentinel**, which is the second time body/joint 0 has
    // done this here.
    for (1..s.robot.model.nbody) |body| {
        if (s.robot.model.body_parent[body] != 0) {
            continue;
        }
        const human_joint: i32 = s.human_of_body[body];
        if (human_joint < 0 or @as(usize, @intCast(human_joint)) >= positions.len) {
            return null;
        }
        return positions[@intCast(human_joint)];
    }
    return null;
}

// ── ★★ `buildCorePairs` DELETED ──
//
// Two directions determined the torso EXACTLY and the pelvis within 11 degrees — the best result
// this project had before the point cloud, and the first time the core of the body tracked at
// all. **It is a special case of three sample points**, which is what a body with two children
// gets for free. The construction was right; it just did not need to be its own mechanism.

/// One point on a robot body, and where the capture says it should be.
///
/// ── ★★★ THE WHOLE RETARGET IS "MATCH THESE POINTS" ──
///
/// One point per body gives POSITION, two give DIRECTION, three give TWIST. The six mechanisms
/// this example used to run — direction pairs, twist offsets, per-body IK, chain IK, hinge
/// flexion, ankle aim — are each a special case, and at least eight of this project's bugs lived
/// in the seams between them.
// ── ★★★ THE RETARGET LIVES IN `src/robot.zig` NOW ──
//
// `PointSample`, `buildPointSamples` and `solvePointCloud` were defined HERE, and the harness
// had its own copy of the same construction. **Seven times an example and a test have
// re-implemented one stage and drifted** — the twist builder, the rest solve, the task set, the
// rest-flexion fix, the pose loop, the sample cache, and a posture weight of 0.02 against 0.15.
// Each was closed on its own; none removed the condition.
//
// ★★★ **Moving the algorithm into the library removes it.** What remains here is what genuinely
// belongs to the example: turning a `Character` into the arrays the library wants.

/// The visual fit: mean and worst world distance from a mapped body to its capture joint.
///
/// ★★ **The only metric here that can see a translation.** Nine angle metrics could not see the
/// whole figure standing 10 cm out of place; the worst is reported alongside the mean because
/// the worst bone is the one that draws the eye and a mean hides it.
fn recordRobotFit(s: *State, positions_robot: []const Vec) void {
    var sum: f32 = 0;
    var count: f32 = 0;
    s.robot_visual_worst = 0;
    s.robot_visual_worst_name = "";
    for (1..s.robot.model.nbody) |b| {
        const hb: i32 = s.human_of_body[b];
        if (hb < 0 or @as(usize, @intCast(hb)) >= positions_robot.len) {
            continue;
        }
        const d: f32 = boneLength(s.robot_data.body_xpos[b] - positions_robot[@intCast(hb)]);
        sum += d;
        count += 1;
        if (d > s.robot_visual_worst) {
            s.robot_visual_worst = d;
            s.robot_visual_worst_name = s.robot.names[b];
        }
    }
    s.robot_visual_mean = sum / @max(count, 1);
}

/// Fill `s.robot_samples` by asking the library, then record what the solve will use.
fn refreshPointSamples(s: *State, source: *const Character) void {
    const joints: usize = source.boneCount();
    s.robot_sample_count = z.robot.buildPointSamples(&s.robot.model, .{
        .human_of_body = s.human_of_body,
        .human_parents = source.target_parents[0..joints],
        .rest_positions = s.robot_rest_world[0..joints],
        .rest_rotations = s.robot_rest_rotations[0..joints],
        .robot_rest_rotations = s.robot_rest_xrot[0..s.robot.model.nbody],
        .body_names = s.robot.names,
        // ★ The rest POSITIONS as well as the rotations: `buildPointSamples` checks each leaf's
        // correspondence against the rest pose and needs both halves of it.
        .rest_positions_robot = s.robot_rest_body_pos[0..s.robot.model.nbody],
    }, s.robot_samples);

    // ★ Counted here so the UI reports what the SOLVE uses, not what the table resolved: a body
    // can be mapped and still receive no samples.
    var mapped: usize = 0;
    for (1..s.robot.model.nbody) |b| {
        if (s.human_of_body[b] >= 0) {
            mapped += 1;
        }
    }
    s.robot_mapped_count = mapped;
}

/// Build the retargeted skeleton: the capture's DIRECTIONS at the robot's OWN bone lengths,
/// placed by best fit rather than by an anchor.
///
/// ── ★★ THE SHAPE FIRST, THE PLACEMENT SECOND ──
///
/// Anchoring the walk on one body makes that body a single point of failure: the robot's ROOT is
/// its torso, whose origin is not where the capture's chest joint sits, and the whole figure
/// inherited that error. **Translating so the MEAN of the mapped joints matches means every body
/// votes and there is no privileged one to be wrong about.**
fn buildRetargetedSkeleton(
    s: *State,
    positions_robot: []const Vec,
    out: []Vec,
) void {
    const model: *const z.robot.Model = &s.robot.model;
    const limit: usize = @min(model.nbody, out.len);
    out[0] = .{ 0, 0, 0, 0 };
    for (1..limit) |b| {
        const parent: u32 = model.body_parent[b];
        const own_length: f32 = boneLength(model.body_pos[b]);
        const hb: i32 = s.human_of_body[b];
        if (parent == 0) {
            out[b] = if (hb >= 0 and @as(usize, @intCast(hb)) < positions_robot.len)
                positions_robot[@intCast(hb)]
            else
                .{ 0, 0, 0, 0 };
            continue;
        }
        const hp: i32 = s.human_of_body[parent];
        if (hb < 0 or hp < 0 or own_length < 1.0e-6) {
            out[b] = out[parent] + model.body_pos[b];
            continue;
        }
        const bone: Vec = positions_robot[@intCast(hb)] - positions_robot[@intCast(hp)];
        if (boneLength(bone) < 1.0e-6) {
            out[b] = out[parent] + model.body_pos[b];
            continue;
        }
        out[b] = out[parent] + normalize3(bone) * @as(Vec, @splat(own_length));
    }

    var offset: Vec = .{ 0, 0, 0, 0 };
    var counted: f32 = 0;
    for (1..limit) |b| {
        const hb: i32 = s.human_of_body[b];
        if (hb < 0 or @as(usize, @intCast(hb)) >= positions_robot.len) {
            continue;
        }
        offset += positions_robot[@intCast(hb)] - out[b];
        counted += 1;
    }
    if (counted > 0) {
        const shift: Vec = offset / @as(Vec, @splat(counted));
        for (1..limit) |b| {
            out[b] += shift;
        }
    }
}
