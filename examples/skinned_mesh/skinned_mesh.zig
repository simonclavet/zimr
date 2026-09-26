//! skinned_mesh - port of the GL `skinned_mesh`: a skinned glTF rig,
//! animated and deformed every frame. (The bone-socket technique - parenting
//! an object to a bone - now lives in its own `bone_socket` example on a real
//! rigged character, so this stays a focused pure-skinning demo.)
//!
//! The 2KB embedded GLB (same `skinned_mesh_data` the GL demo generated):
//! a 6-vertex quad, 2 bones, JOINTS_0/WEIGHTS_0, inverseBindMatrices, and a
//! "wave" animation rotating bone 1 +/-45 deg around Z over 1.5s - so the right
//! edge of the quad waves while the left edge stays anchored.
//!
//! Port shape: the GL original ran a GPU skinning shader (bone VBOs in
//! slots 7/8 + a boneMatrices uniform).  The wgpu typed-shader path has no
//! skinned pipeline variant yet, so this is the honest CPU-SKINNED v1:
//!   parse (codecs.gltf already does skins + animations + JOINTS/WEIGHTS)
//!   -> sample keyframes (nlerp quats) -> per-joint world = v*R*T
//!   -> skin matrix = v*inverseBind*world -> vertices deformed on the CPU
//!   -> `updateMeshBuffer` (the dynamic-mesh path) -> `drawModel`.
//! Bone gizmos (spheres + a line) draw the live skeleton over the mesh.
//! When the typed-3D-shader arc grows a skinned variant, the pose math
//! here moves behind it unchanged - the matrices are the same either way.
//!
//! Matrix conventions, derived from zm's source: zm is row-vector /
//! row-major (`mulMatVec(m, v) = v*m`, translation lives in row 3), which
//! makes glTF's COLUMN-major mat4 floats map DIRECTLY onto zm.Mat rows,
//! and "rotate then translate" compose as `mulMat(R, T)`.
const std = @import("std");
const bufPrint = std.fmt.bufPrint;
const Allocator = std.mem.Allocator;
const z = @import("zimr");

const zm = @import("zm");
const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Vec = zm.Vec;
const clamp = zm.clamp;
const f32x4 = zm.f32x4;
const matFromQuat = zm.matFromQuat;
const mulMat = zm.mulMat;
const mulMatVec = zm.mulMatVec;
const pointVec = zm.pointVec;
const quat_identity = zm.quat_identity;
const splat = zm.splat;
const translationV = zm.translationV;
const vec = zm.vec;
const common = @import("example_common");
const c = z.colors;
const skin_data = @import("skinned_mesh_data.zig");

const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const max_joints: usize = 8;

const State = struct {
    font: z.Font,
    model: z.Model,
    /// Bind-pose positions (the skin source - never mutated).
    base_positions: []f32,
    /// Per-frame skinned positions, memcpy'd into the mesh via
    /// `updateMeshBuffer`.
    skinned: []f32,
    /// vec4 u8 per vertex / vec4 f32 per vertex (views into the mesh).
    bone_ids: [*c]u8,
    bone_weights: [*c]f32,
    vertex_count: usize,

    // ---- the rig, extracted from the GLB at init ----
    joint_count: usize,
    /// glTF node index per joint slot.
    joint_nodes: [max_joints]u32,
    /// Bind translation per joint node (the rig animates rotation only).
    node_translation: [max_joints]Vec,
    inverse_bind: [max_joints]Mat,
    /// Keyframe times (shared by both channels in this rig).
    times: []f32,
    /// Per-joint keyframe rotations: rot[j][k] = quat at keyframe k.
    rot: [max_joints][]Vec,

    t: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadModel(gpa, s.model);
    gpa.free(s.base_positions);
    gpa.free(s.skinned);
    gpa.free(s.times);
    var j: usize = 0;
    while (j < s.joint_count) : (j += 1) {
        gpa.free(s.rot[j]);
    }
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var document: z.codecs.gltf.Data = try z.codecs.gltf.parse(gpa, &skin_data.skin_glb);
    defer document.deinit();

    const meshes: []z.types.Mesh = try z.codecs.gltf.meshesFromGltf(gpa, document);
    if (meshes.len == 0 or meshes[0].boneIndices == null or meshes[0].boneWeights == null) {
        return error.NotASkinnedMesh;
    }
    const mesh: z.types.Mesh = meshes[0];
    // Free the outer slice from meshesFromGltf (we keep meshes[0] by value; its
    // CPU arrays travel with the model). Without this the twice-lifecycle census
    // leaks a little each cycle.
    gpa.free(meshes);
    const vertex_count: usize = @intCast(mesh.vertexCount);

    // Snapshot the bind pose; the mesh's own position array becomes the
    // per-frame skinning destination.
    const base: []f32 = try gpa.alloc(f32, vertex_count * 3);
    @memcpy(base, mesh.vertices[0 .. vertex_count * 3]);
    const skinned: []f32 = try gpa.alloc(f32, vertex_count * 3);
    @memcpy(skinned, base);

    // ---- skin: joints + inverse binds (glTF column-major -> zm rows) ----
    if (document.skins.len == 0) {
        return error.NotASkinnedMesh;
    }
    const skin: z.codecs.gltf.Skin = document.skins[0];
    const joint_count: usize = @min(skin.joints.len, max_joints);
    var joint_nodes: [max_joints]u32 = undefined;
    var node_translation: [max_joints]Vec = undefined;
    var inverse_bind: [max_joints]Mat = undefined;
    const ibm_accessor: u32 = skin.inverse_bind_matrices orelse return error.NotASkinnedMesh;
    const ibm: []f32 = try z.codecs.gltf.readAccessor(f32, gpa, document, document.accessors[ibm_accessor]);
    defer gpa.free(ibm);
    var j: usize = 0;
    while (j < joint_count) : (j += 1) {
        joint_nodes[j] = skin.joints[j];
        node_translation[j] = document.nodes[skin.joints[j]].translation;
        const base_f: usize = j * 16;
        inverse_bind[j] = .{
            f32x4(ibm[base_f + 0], ibm[base_f + 1], ibm[base_f + 2], ibm[base_f + 3]),
            f32x4(ibm[base_f + 4], ibm[base_f + 5], ibm[base_f + 6], ibm[base_f + 7]),
            f32x4(ibm[base_f + 8], ibm[base_f + 9], ibm[base_f + 10], ibm[base_f + 11]),
            f32x4(ibm[base_f + 12], ibm[base_f + 13], ibm[base_f + 14], ibm[base_f + 15]),
        };
    }

    // ---- animation: shared timeline + per-joint rotation tracks ----
    if (document.animations.len == 0) {
        return error.NoAnimation;
    }
    const anim: z.codecs.gltf.Animation = document.animations[0];
    var times: []f32 = &.{};
    var rot: [max_joints][]Vec = undefined;
    var have_rot: [max_joints]bool = @splat(false);
    for (anim.channels) |ch| {
        if (ch.target_path != .rotation) {
            continue;
        }
        // Which joint slot does this channel's node drive?
        var slot: ?usize = null;
        var k: usize = 0;
        while (k < joint_count) : (k += 1) {
            if (joint_nodes[k] == ch.target_node) {
                slot = k;
            }
        }
        const joint_slot: usize = slot orelse continue;
        const sampler: z.codecs.gltf.AnimationSampler = anim.samplers[ch.sampler];
        if (times.len == 0) {
            times = try z.codecs.gltf.readAccessor(f32, gpa, document, document.accessors[sampler.input]);
        }
        const raw: []f32 = try z.codecs.gltf.readAccessor(f32, gpa, document, document.accessors[sampler.output]);
        defer gpa.free(raw);
        const quats: []Vec = try gpa.alloc(Vec, raw.len / 4);
        for (quats, 0..) |*q, qi| {
            q.* = f32x4(raw[qi * 4], raw[qi * 4 + 1], raw[qi * 4 + 2], raw[qi * 4 + 3]);
        }
        rot[joint_slot] = quats;
        have_rot[joint_slot] = true;
    }
    // Joints without a rotation track hold the bind rotation.
    j = 0;
    while (j < joint_count) : (j += 1) {
        if (!have_rot[j]) {
            const quats: []Vec = try gpa.alloc(Vec, 1);
            quats[0] = document.nodes[joint_nodes[j]].rotation;
            rot[j] = quats;
        }
    }

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .model = try z.loadModelFromMesh(f.gl, gpa, mesh),
        .base_positions = base,
        .skinned = skinned,
        .bone_ids = mesh.boneIndices,
        .bone_weights = mesh.boneWeights,
        .vertex_count = vertex_count,
        .joint_count = joint_count,
        .joint_nodes = joint_nodes,
        .node_translation = node_translation,
        .inverse_bind = inverse_bind,
        .times = times,
        .rot = rot,
    };
}

/// Normalized lerp between two quaternions - plenty for +/-45 deg keyframes.
fn nlerp(a: Vec, b: Vec, alpha: f32) Vec {
    const va: Vec = a * splat(1.0 - alpha) + b * splat(alpha);
    const len: f32 = @sqrt(va[0] * va[0] + va[1] * va[1] + va[2] * va[2] + va[3] * va[3]);
    if (len < 1e-8) {
        return quat_identity;
    }
    return va / splat(len);
}

/// Sample joint `j`'s rotation track at time `t` (looped externally).
fn sampleRotation(s: *const State, j: usize, t: f32) Vec {
    const track: []Vec = s.rot[j];
    if (track.len <= 1 or s.times.len <= 1) {
        return track[0];
    }
    var k: usize = 0;
    while (k + 1 < s.times.len and s.times[k + 1] < t) : (k += 1) {}
    if (k + 1 >= track.len) {
        return track[track.len - 1];
    }
    const span: f32 = @max(s.times[k + 1] - s.times[k], 1e-6);
    const alpha: f32 = clamp((t - s.times[k]) / span, 0.0, 1.0);
    return nlerp(track[k], track[k + 1], alpha);
}

fn update(f: *z.Frame, s: *State) void {
    // ---- pose: loop the timeline, build per-joint world + skin matrices ----
    const duration: f32 = if (s.times.len > 0) s.times[s.times.len - 1] else 1.0;
    s.t += f.time.delta_time;
    if (s.t > duration) {
        s.t -= duration;
    }
    var world: [max_joints]Mat = undefined;
    var skin_mat: [max_joints]Mat = undefined;
    var j: usize = 0;
    while (j < s.joint_count) : (j += 1) {
        const rot_m: Mat = matFromQuat(sampleRotation(s, j, s.t));
        // Rotate then translate (this rig's joints are unparented; a
        // hierarchy would multiply the parent's world here too).
        world[j] = mulMat(rot_m, translationV(s.node_translation[j]));
        // Bind space -> joint local -> world:  v * invBind * world.
        skin_mat[j] = mulMat(s.inverse_bind[j], world[j]);
    }

    // ---- CPU skinning: v' = sum_k w_k * (v * skin[joint_k]) ----
    var vi: usize = 0;
    while (vi < s.vertex_count) : (vi += 1) {
        const p: Vec = f32x4(
            s.base_positions[vi * 3],
            s.base_positions[vi * 3 + 1],
            s.base_positions[vi * 3 + 2],
            1.0,
        );
        var acc: Vec = f32x4(0, 0, 0, 0);
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const w: f32 = s.bone_weights[vi * 4 + k];
            if (w == 0) {
                continue;
            }
            const joint: usize = s.bone_ids[vi * 4 + k];
            if (joint >= s.joint_count) {
                continue;
            }
            acc += mulMatVec(skin_mat[joint], p) * splat(w);
        }
        s.skinned[vi * 3] = acc[0];
        s.skinned[vi * 3 + 1] = acc[1];
        s.skinned[vi * 3 + 2] = acc[2];
    }
    z.updateMeshBuffer(s.model.meshes[0], 0, std.mem.sliceAsBytes(s.skinned), 0);

    // ---- draw: the deformed quad + the live skeleton over it ----
    const vw: f32 = @max(f.window.widthf(), 1);
    const cam: Camera3D = .{
        .position = pointVec(1.0, 1.2, 4.5),
        .target = pointVec(1.0, 0.2, 0),
        .up = vec(0, 1, 0),
        .fovy_deg = 55,
        .projection = 0,
    };
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 10, 0.5);
    z.drawModel(f.gl, s.model, pointVec(0, 0, 0), 1.0, c.emerald_400);
    // Skeleton gizmos: joint world position is the world matrix's
    // translation row (row-major zm).
    j = 0;
    while (j < s.joint_count) : (j += 1) {
        const pos: Vec = pointVec(world[j][3][0], world[j][3][1], world[j][3][2]);
        z.drawSphere(f.gl, pos, .{ .radius = 0.08, .rings = 6, .slices = 8, .color = c.amber_400 });
        if (j + 1 < s.joint_count) {
            const next: Vec = pointVec(world[j + 1][3][0], world[j + 1][3][1], world[j + 1][3][2]);
            z.drawLine3D(f.gl, pos, next, c.amber_300);
        }
    }

    z.endMode3D(f.gl);

    f.gl.text(
        .{ 16, 14 },
        "skinned mesh - CPU skinning",
        .{ .size = 22, .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 }, .font = &s.font },
    );
    var hud_buf: [64]u8 = undefined;
    const hud: []const u8 = bufPrint(
        &hud_buf,
        "anim 'wave'  t = {d:.2}s / {d:.2}s",
        .{ s.t, duration },
    ) catch "";
    f.gl.text(.{ 16, 42 }, hud, .{ .size = 16, .color = .{ .r = 170, .g = 180, .b = 200, .a = 255 }, .font = &s.font });
    _ = vw;
    common.caption(f.gl, s.font, "glTF skin + animation parsed by codecs - bone 1 waves the right edge");
}

/// Descriptor-only: the runner (standalone) or a launcher drives this.
pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - skinned mesh (CPU skinning)",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
            // Clear via the pass loadOp (the runner does this in beginDrawing),
            // NOT a fullscreen clearViewport quad - that quad overwrites the 3D
            // pass on tile GPUs and the whole 3D block disappears.
            .clear = .{ .r = 10.0 / 255.0, .g = 12.0 / 255.0, .b = 18.0 / 255.0, .a = 1.0 },
        },
    },
    .init = initState,
    .deinit = deinit,
    .update = update,
    .memory = .managed,
};
