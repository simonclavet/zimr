//! bone_socket - port of raylib's `models_bone_socket` with the real rigged
//! character. Loads the CC0 `greenman.glb` (a 12-joint HIERARCHICAL skeleton
//! with 4 animations) and `greenman_sword.glb`, plays an animation, and rigidly
//! sockets the sword to the `socket_hand_R` bone so it swings with the hand.
//!
//! This is the honest v1: CPU skinning, like `skinned_mesh`, but generalised
//! from that flat 2-bone rig to a real one -
//!   * FULL node hierarchy: each node's world = local * parent-world (walked
//!     from the scene roots), not the unparented shortcut skinned_mesh used.
//!   * FULL TRS animation: every clip animates translation + rotation + scale,
//!     sampled per keyframe interval (linear for T/S, nlerp for R).
//!   * NAMED socket: the sword follows `world[socket_hand_R]` - a bone found by
//!     name, exactly as raylib does with `skeleton.bones[i].name`.
//! The character deforms via sum w_k*(v*skin_k); the sword (a rigid mesh) is just
//! world[socket] applied to each vertex per frame. Matrix order follows zm's
//! column-vector convention (see the `Mat` docs): build transforms with
//! `composeN`/`compose`, which read in application order - a node's local is
//! `composeN(scale, rotate, translate)`, a child's world is
//! `compose(local, parentWorld)`, and a skin matrix is `compose(inverseBind, jointWorld)`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const z = @import("zimr");
const zm = @import("zm");
const common = @import("example_common");
const c = z.colors;

const Camera3D = zm.Camera3D;
const Mat = zm.Mat;
const Vec = zm.Vec;
const f32x4 = zm.f32x4;
const pointVec = zm.pointVec;
const splat = zm.splat;
const compose = zm.compose;
const composeN = zm.composeN;
const mulMatVec = zm.mulMatVec;
const matFromQuat = zm.matFromQuat;
const translationV = zm.translationV;
const scalingV = zm.scalingV;
const quat_identity = zm.quat_identity;

const greenman_glb = @embedFile("greenman.glb");
const sword_glb = @embedFile("greenman_sword.glb");
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");
const bufPrint = std.fmt.bufPrint;

const max_nodes: usize = 32;
const max_joints: usize = 16;

const Path = enum { translation, rotation, scale };

/// One pre-read animation track (a sampler bound to a node + property).
const Track = struct {
    target_node: u32,
    path: Path,
    times: []f32,
    values: []f32, // comps-per-key flattened
    comps: usize, // 3 for T/S, 4 for R
};

const State = struct {
    font: z.Font,
    doc: z.codecs.gltf.Data, // kept alive: node hierarchy is read every frame

    char_model: z.Model,
    char_base: []f32, // bind-pose positions
    char_skinned: []f32, // per-frame destination (memcpy'd into the mesh)
    bone_ids: [*c]u8,
    bone_weights: [*c]f32,
    char_vc: usize,

    sword_model: z.Model,
    sword_base: []f32, // sword mesh positions (its own object space)
    sword_skinned: []f32,
    sword_vc: usize,

    joint_count: usize,
    joint_nodes: [max_joints]u32,
    inverse_bind: [max_joints]Mat,

    node_count: usize,
    parent: [max_nodes]i32, // -1 = root
    order: [max_nodes]usize, // node indices, parents before children
    socket_node: usize,

    tracks: []Track,
    duration: f32,
    cam: z.OrbitCamera,
    t: f32 = 0,
};

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    z.unloadModel(gpa, s.char_model);
    z.unloadModel(gpa, s.sword_model);
    gpa.free(s.char_base);
    gpa.free(s.char_skinned);
    gpa.free(s.sword_base);
    gpa.free(s.sword_skinned);
    for (s.tracks) |tr| {
        gpa.free(tr.times);
        gpa.free(tr.values);
    }
    gpa.free(s.tracks);
    s.doc.deinit();
}

/// Result of loading one glb's first mesh.
const MeshLoad = struct {
    model: z.Model,
    base: []f32,
    skinned: []f32,
    vc: usize,
    mesh: z.types.Mesh,
};

/// Load one glb's first mesh as base positions + an uploaded model. Frees the
/// meshesFromGltf slice container (its mesh CPU arrays travel with the model).
fn loadMeshPositions(
    gpa: Allocator,
    f: *z.Frame,
    doc: z.codecs.gltf.Data,
) !MeshLoad {
    const meshes: []z.types.Mesh = try z.codecs.gltf.meshesFromGltf(gpa, doc);
    if (meshes.len == 0) {
        return error.NoMesh;
    }
    const mesh: z.types.Mesh = meshes[0];
    gpa.free(meshes);
    const vc: usize = @intCast(mesh.vertexCount);
    const base: []f32 = try gpa.alloc(f32, vc * 3);
    @memcpy(base, mesh.vertices[0 .. vc * 3]);
    const skinned: []f32 = try gpa.alloc(f32, vc * 3);
    @memcpy(skinned, base);
    const model: z.Model = try z.loadModelFromMesh(f.gl, gpa, mesh);
    return .{ .model = model, .base = base, .skinned = skinned, .vc = vc, .mesh = mesh };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var doc: z.codecs.gltf.Data = try z.codecs.gltf.parse(gpa, greenman_glb);
    errdefer doc.deinit();

    const char: MeshLoad = try loadMeshPositions(gpa, f, doc);
    if (char.mesh.boneIndices == null or char.mesh.boneWeights == null) {
        return error.NotSkinned;
    }

    // Sword is a separate glb; its mesh CPU arrays travel with sword_model, so
    // the sword document can be dropped after upload.
    var sword_doc: z.codecs.gltf.Data = try z.codecs.gltf.parse(gpa, sword_glb);
    const sword: MeshLoad = try loadMeshPositions(gpa, f, sword_doc);
    sword_doc.deinit();

    // ---- skin: joints + inverse-bind matrices (glTF row-major floats) ----
    if (doc.skins.len == 0) {
        return error.NoSkin;
    }
    const skin: z.codecs.gltf.Skin = doc.skins[0];
    const joint_count: usize = @min(skin.joints.len, max_joints);
    var joint_nodes: [max_joints]u32 = undefined;
    var inverse_bind: [max_joints]Mat = undefined;
    const ibm_acc: u32 = skin.inverse_bind_matrices orelse return error.NoInverseBind;
    const ibm: []f32 = try z.codecs.gltf.readAccessor(f32, gpa, doc, doc.accessors[ibm_acc]);
    defer gpa.free(ibm);
    var j: usize = 0;
    while (j < joint_count) : (j += 1) {
        joint_nodes[j] = skin.joints[j];
        const b: usize = j * 16;
        inverse_bind[j] = .{
            f32x4(ibm[b + 0], ibm[b + 1], ibm[b + 2], ibm[b + 3]),
            f32x4(ibm[b + 4], ibm[b + 5], ibm[b + 6], ibm[b + 7]),
            f32x4(ibm[b + 8], ibm[b + 9], ibm[b + 10], ibm[b + 11]),
            f32x4(ibm[b + 12], ibm[b + 13], ibm[b + 14], ibm[b + 15]),
        };
    }

    // ---- hierarchy: parent[] from every node's children + a parents-first order ----
    const node_count: usize = @min(doc.nodes.len, max_nodes);
    var parent: [max_nodes]i32 = @splat(-1);
    for (doc.nodes[0..node_count], 0..) |n, ni| {
        for (n.children) |ch| {
            if (ch < node_count) {
                parent[ch] = @intCast(ni);
            }
        }
    }
    // Topological order: emit a node only after its parent (simple O(n^2), n tiny).
    var order: [max_nodes]usize = undefined;
    var emitted: [max_nodes]bool = @splat(false);
    var count: usize = 0;
    while (count < node_count) {
        for (0..node_count) |ni| {
            if (emitted[ni]) {
                continue;
            }
            const p: i32 = parent[ni];
            if (p < 0 or emitted[@intCast(p)]) {
                order[count] = ni;
                emitted[ni] = true;
                count += 1;
            }
        }
    }

    // ---- socket bone by NAME (as raylib matches skeleton.bones[i].name) ----
    var socket_node: usize = 0;
    for (doc.nodes[0..node_count], 0..) |n, ni| {
        if (n.name) |nm| {
            if (std.mem.eql(u8, nm, "socket_hand_R")) {
                socket_node = ni;
            }
        }
    }

    // ---- pre-read the "3_attack" clip's TRS tracks (a dynamic swing) ----
    var anim_index: usize = doc.animations.len - 1; // last = attack
    for (doc.animations, 0..) |a, ai| {
        if (a.name) |nm| {
            if (std.mem.eql(u8, nm, "3_attack")) {
                anim_index = ai;
            }
        }
    }
    const anim: z.codecs.gltf.Animation = doc.animations[anim_index];
    var tracks: std.ArrayListUnmanaged(Track) = .empty;
    errdefer tracks.deinit(gpa);
    var duration: f32 = 0;
    for (anim.channels) |chn| {
        const sampler: z.codecs.gltf.AnimationSampler = anim.samplers[chn.sampler];
        const times: []f32 = try z.codecs.gltf.readAccessor(f32, gpa, doc, doc.accessors[sampler.input]);
        const values: []f32 = try z.codecs.gltf.readAccessor(f32, gpa, doc, doc.accessors[sampler.output]);
        if (times.len > 0 and times[times.len - 1] > duration) {
            duration = times[times.len - 1];
        }
        const path: Path = switch (chn.target_path) {
            .translation => .translation,
            .rotation => .rotation,
            .scale => .scale,
            .weights => {
                gpa.free(times);
                gpa.free(values);
                continue;
            },
        };
        const comps: usize = if (path == .rotation) 4 else 3;
        try tracks.append(gpa, .{
            .target_node = chn.target_node,
            .path = path,
            .times = times,
            .values = values,
            .comps = comps,
        });
    }

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 22),
        .doc = doc,
        .char_model = char.model,
        .char_base = char.base,
        .char_skinned = char.skinned,
        .bone_ids = char.mesh.boneIndices,
        .bone_weights = char.mesh.boneWeights,
        .char_vc = char.vc,
        .sword_model = sword.model,
        .sword_base = sword.base,
        .sword_skinned = sword.skinned,
        .sword_vc = sword.vc,
        .joint_count = joint_count,
        .joint_nodes = joint_nodes,
        .inverse_bind = inverse_bind,
        .node_count = node_count,
        .parent = parent,
        .order = order,
        .socket_node = socket_node,
        .tracks = try tracks.toOwnedSlice(gpa),
        .duration = if (duration > 0) duration else 1.0,
        .cam = .{ .target = pointVec(0, 0.5, 0), .distance = 9.0, .pitch = 0.35, .yaw = 0.7 },
    };
}

/// Normalized lerp between quaternions (nlerp - enough for these clips).
fn nlerp(a: Vec, b: Vec, alpha: f32) Vec {
    const qd: f32 = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    const bb: Vec = if (qd < 0) -b else b;
    const q: Vec = a + (bb - a) * splat(alpha);
    const len: f32 = @sqrt(q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3]);
    if (len < 1e-6) {
        return quat_identity;
    }
    return q / splat(len);
}

/// Sample one track at time t into a 4-wide value (unused lanes = 0).
fn sampleTrack(tr: Track, t: f32) [4]f32 {
    const n: usize = tr.times.len;
    if (n == 0) {
        return .{ 0, 0, 0, 0 };
    }
    // Find the keyframe interval [k, k+1] containing t.
    var k: usize = 0;
    while (k + 1 < n and tr.times[k + 1] < t) : (k += 1) {}
    const k1: usize = @min(k + 1, n - 1);
    const t0: f32 = tr.times[k];
    const t1: f32 = tr.times[k1];
    const span: f32 = t1 - t0;
    const alpha: f32 = if (span > 1e-6) (t - t0) / span else 0.0;
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    if (tr.path == .rotation) {
        const a: Vec = f32x4(tr.values[k * 4], tr.values[k * 4 + 1], tr.values[k * 4 + 2], tr.values[k * 4 + 3]);
        const b: Vec = f32x4(tr.values[k1 * 4], tr.values[k1 * 4 + 1], tr.values[k1 * 4 + 2], tr.values[k1 * 4 + 3]);
        const q: Vec = nlerp(a, b, alpha);
        out = .{ q[0], q[1], q[2], q[3] };
    } else {
        var comp: usize = 0;
        while (comp < 3) : (comp += 1) {
            const va: f32 = tr.values[k * 3 + comp];
            const vb: f32 = tr.values[k1 * 3 + comp];
            out[comp] = va + (vb - va) * alpha;
        }
    }
    return out;
}

fn update(f: *z.Frame, s: *State) void {
    s.t += f.time.delta_time;
    if (s.t > s.duration) {
        s.t -= s.duration;
    }

    // ---- 1. per-node local TRS: bind pose, then override from the clip ----
    var trans: [max_nodes]Vec = undefined;
    var rot: [max_nodes]Vec = undefined;
    var scal: [max_nodes]Vec = undefined;
    for (0..s.node_count) |ni| {
        trans[ni] = s.doc.nodes[ni].translation;
        rot[ni] = s.doc.nodes[ni].rotation;
        scal[ni] = s.doc.nodes[ni].scale;
    }
    for (s.tracks) |tr| {
        if (tr.target_node >= s.node_count) {
            continue;
        }
        const v: [4]f32 = sampleTrack(tr, s.t);
        switch (tr.path) {
            .translation => trans[tr.target_node] = f32x4(v[0], v[1], v[2], 0),
            .rotation => rot[tr.target_node] = f32x4(v[0], v[1], v[2], v[3]),
            .scale => scal[tr.target_node] = f32x4(v[0], v[1], v[2], 0),
        }
    }

    // ---- 2. world matrices, parents before children ----
    var world: [max_nodes]Mat = undefined;
    for (s.order[0..s.node_count]) |ni| {
        const local: Mat = composeN(scalingV(scal[ni]), matFromQuat(rot[ni]), translationV(trans[ni]));
        const p: i32 = s.parent[ni];
        world[ni] = if (p < 0) local else compose(local, world[@intCast(p)]);
    }

    // ---- 3. skin the character: v' = sum w_k * (v * invBind_k * world_k) ----
    var skin_mat: [max_joints]Mat = undefined;
    for (0..s.joint_count) |ji| {
        skin_mat[ji] = compose(s.inverse_bind[ji], world[s.joint_nodes[ji]]);
    }
    var vi: usize = 0;
    while (vi < s.char_vc) : (vi += 1) {
        const p: Vec = f32x4(s.char_base[vi * 3], s.char_base[vi * 3 + 1], s.char_base[vi * 3 + 2], 1.0);
        var acc: Vec = f32x4(0, 0, 0, 0);
        var kk: usize = 0;
        while (kk < 4) : (kk += 1) {
            const w: f32 = s.bone_weights[vi * 4 + kk];
            if (w == 0) {
                continue;
            }
            const joint: usize = s.bone_ids[vi * 4 + kk];
            if (joint >= s.joint_count) {
                continue;
            }
            acc += mulMatVec(skin_mat[joint], p) * splat(w);
        }
        s.char_skinned[vi * 3] = acc[0];
        s.char_skinned[vi * 3 + 1] = acc[1];
        s.char_skinned[vi * 3 + 2] = acc[2];
    }
    z.updateMeshBuffer(s.char_model.meshes[0], 0, std.mem.sliceAsBytes(s.char_skinned), 0);

    // ---- 4. socket: rigidly transform the sword by the hand bone's world ----
    const socket: Mat = world[s.socket_node];
    var si: usize = 0;
    while (si < s.sword_vc) : (si += 1) {
        const p: Vec = f32x4(s.sword_base[si * 3], s.sword_base[si * 3 + 1], s.sword_base[si * 3 + 2], 1.0);
        const q: Vec = mulMatVec(socket, p);
        s.sword_skinned[si * 3] = q[0];
        s.sword_skinned[si * 3 + 1] = q[1];
        s.sword_skinned[si * 3 + 2] = q[2];
    }
    z.updateMeshBuffer(s.sword_model.meshes[0], 0, std.mem.sliceAsBytes(s.sword_skinned), 0);

    // ---- 5. draw ----
    const cam: Camera3D = s.cam.update(f, false, .{ .fovy_deg = 55 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 0.5);
    z.drawModel(f.gl, s.char_model, pointVec(0, 0, 0), 1.0, c.emerald_400);
    z.drawModel(f.gl, s.sword_model, pointVec(0, 0, 0), 1.0, c.sky_300);
    z.endMode3D(f.gl);

    f.gl.text(.{ 16, 14 }, "bone socket - rigged character", .{
        .size = 22,
        .color = .{ .r = 235, .g = 235, .b = 245, .a = 255 },
        .font = &s.font,
    });
    var hud_buf: [80]u8 = undefined;
    const hud: []const u8 = bufPrint(&hud_buf, "anim '3_attack'  t = {d:.2}s / {d:.2}s", .{ s.t, s.duration }) catch "";
    f.gl.text(.{ 16, 42 }, hud, .{ .size = 16, .color = .{ .r = 170, .g = 180, .b = 200, .a = 255 }, .font = &s.font });
    common.caption(f.gl, s.font, "drag = orbit, pinch/wheel = zoom - sword socketed to bone socket_hand_R");
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - bone socket (rigged character)",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .update = update,
    .deinit = deinit,
};
