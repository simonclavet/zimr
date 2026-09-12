//! models_animation_blend_custom — port of raylib's per-bone animation
//! blending. The CC0 `greenman.glb` plays TWO clips at once — `2_move` (walk)
//! and `3_attack` — and blends them PER BONE: the upper body (torso, arms,
//! hands) follows the attack while the lower body (hips, legs) keeps walking,
//! so the character strides forward mid-swing. A checkbox flips to a uniform
//! 50/50 blend of the whole skeleton for comparison.
//!
//! Built on the same hierarchical CPU-skinning path as `bone_socket`: parse →
//! per-node local TRS (bind, overridden by each clip's sampled channels) →
//! blend the two clips' local TRS per node (lerp T/S, nlerp R) → walk the node
//! hierarchy → skin. Matrix order follows zm's convention (see the `Mat` docs):
//! transforms are built with `composeN`/`compose`, which read in application
//! order. raylib bakes GLOBAL poses and blends those; blending LOCAL TRS then
//! accumulating the hierarchy (as here) is the same idea and a touch cleaner.
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
const atkinson_mono_ttf = @embedFile("atkinson_mono_ttf");

const max_nodes: usize = 32;
const max_joints: usize = 16;

const Path = enum { translation, rotation, scale };

/// One pre-read animation track (a sampler bound to a node + property).
const Track = struct {
    target_node: u32,
    path: Path,
    times: []f32,
    values: []f32,
    comps: usize,
};

/// One animation clip: its TRS tracks plus its total duration.
const Clip = struct {
    tracks: []Track,
    duration: f32,
};

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    doc: z.codecs.gltf.Data,

    char_model: z.Model,
    char_base: []f32,
    char_skinned: []f32,
    bone_ids: [*c]u8,
    bone_weights: [*c]f32,
    char_vc: usize,

    joint_count: usize,
    joint_nodes: [max_joints]u32,
    inverse_bind: [max_joints]Mat,

    node_count: usize,
    parent: [max_nodes]i32,
    order: [max_nodes]usize,
    /// Per node: true = upper body (follows the attack clip in split mode).
    upper: [max_nodes]bool,

    walk: Clip,
    attack: Clip,
    split_mode: bool = true,

    cam: z.OrbitCamera,
    t_walk: f32 = 0,
    t_attack: f32 = 0,
};

fn freeClip(gpa: Allocator, clip: Clip) void {
    for (clip.tracks) |tr| {
        gpa.free(tr.times);
        gpa.free(tr.values);
    }
    gpa.free(clip.tracks);
}

fn deinit(gpa: Allocator, s: *State) void {
    z.unloadFont(gpa, s.font);
    s.ui_host.deinit();
    z.unloadModel(gpa, s.char_model);
    gpa.free(s.char_base);
    gpa.free(s.char_skinned);
    freeClip(gpa, s.walk);
    freeClip(gpa, s.attack);
    s.doc.deinit();
}

/// True if a joint node belongs to the upper body (torso/arms/hands/head),
/// matched by name — greenman uses `body_up`, `hand_*`, `socket_hand_*`,
/// `socket_hat`; everything else (hips, legs, root) is lower body.
fn nameIsUpper(name: []const u8) bool {
    const keys = [_][]const u8{ "up", "hand", "hat", "arm", "head", "chest", "spine", "neck", "shoulder" };
    for (keys) |k| {
        if (std.mem.indexOf(u8, name, k) != null) {
            return true;
        }
    }
    return false;
}

/// Pre-read a clip's TRS tracks (nlerp for rotation, lerp for T/S at draw time).
fn readClip(
    gpa: Allocator,
    doc: z.codecs.gltf.Data,
    anim: z.codecs.gltf.Animation,
) !Clip {
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
        try tracks.append(gpa, .{
            .target_node = chn.target_node,
            .path = path,
            .times = times,
            .values = values,
            .comps = if (path == .rotation) 4 else 3,
        });
    }
    return .{ .tracks = try tracks.toOwnedSlice(gpa), .duration = if (duration > 0) duration else 1.0 };
}

fn findClip(
    gpa: Allocator,
    doc: z.codecs.gltf.Data,
    want: []const u8,
    fallback: usize,
) !Clip {
    var idx: usize = @min(fallback, doc.animations.len - 1);
    for (doc.animations, 0..) |a, ai| {
        if (a.name) |nm| {
            if (std.mem.eql(u8, nm, want)) {
                idx = ai;
            }
        }
    }
    return readClip(gpa, doc, doc.animations[idx]);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    var doc: z.codecs.gltf.Data = try z.codecs.gltf.parse(gpa, greenman_glb);
    errdefer doc.deinit();

    const meshes: []z.types.Mesh = try z.codecs.gltf.meshesFromGltf(gpa, doc);
    if (meshes.len == 0 or meshes[0].boneIndices == null or meshes[0].boneWeights == null) {
        return error.NotSkinned;
    }
    const mesh: z.types.Mesh = meshes[0];
    gpa.free(meshes);
    const vc: usize = @intCast(mesh.vertexCount);
    const base: []f32 = try gpa.alloc(f32, vc * 3);
    @memcpy(base, mesh.vertices[0 .. vc * 3]);
    const skinned: []f32 = try gpa.alloc(f32, vc * 3);
    @memcpy(skinned, base);

    // ---- skin: joints + inverse-bind matrices ----
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

    // ---- hierarchy: parent[] + parents-first order[] + upper-body flags ----
    const node_count: usize = @min(doc.nodes.len, max_nodes);
    var parent: [max_nodes]i32 = @splat(-1);
    var upper: [max_nodes]bool = @splat(false);
    for (doc.nodes[0..node_count], 0..) |n, ni| {
        if (n.name) |nm| {
            upper[ni] = nameIsUpper(nm);
        }
        for (n.children) |ch| {
            if (ch < node_count) {
                parent[ch] = @intCast(ni);
            }
        }
    }
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

    const walk: Clip = try findClip(gpa, doc, "2_move", 2);
    errdefer freeClip(gpa, walk);
    const attack: Clip = try findClip(gpa, doc, "3_attack", 3);

    s.* = .{
        .font = try z.loadFont(f, gpa, atkinson_mono_ttf, 20),
        .ui_host = z.UiHost.init(gpa, s.font),
        .doc = doc,
        .char_model = try z.loadModelFromMesh(f.gl, gpa, mesh),
        .char_base = base,
        .char_skinned = skinned,
        .bone_ids = mesh.boneIndices,
        .bone_weights = mesh.boneWeights,
        .char_vc = vc,
        .joint_count = joint_count,
        .joint_nodes = joint_nodes,
        .inverse_bind = inverse_bind,
        .node_count = node_count,
        .parent = parent,
        .order = order,
        .upper = upper,
        .walk = walk,
        .attack = attack,
        .cam = .{ .target = pointVec(0, 0.9, 0), .distance = 6.0, .pitch = 0.25, .yaw = 0.7 },
    };
}

/// nlerp between quaternions (enough for these clips).
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

fn lerpVec(a: Vec, b: Vec, alpha: f32) Vec {
    return a + (b - a) * splat(alpha);
}

/// Sample one clip at time t into per-node local TRS arrays, starting from each
/// node's bind pose and overriding with the clip's channels.
fn poseFromClip(
    s: *State,
    clip: Clip,
    t: f32,
    trans: *[max_nodes]Vec,
    rot: *[max_nodes]Vec,
    scal: *[max_nodes]Vec,
) void {
    for (0..s.node_count) |ni| {
        trans[ni] = s.doc.nodes[ni].translation;
        rot[ni] = s.doc.nodes[ni].rotation;
        scal[ni] = s.doc.nodes[ni].scale;
    }
    for (clip.tracks) |tr| {
        if (tr.target_node >= s.node_count) {
            continue;
        }
        const v: [4]f32 = sampleTrack(tr, t);
        switch (tr.path) {
            .translation => trans[tr.target_node] = f32x4(v[0], v[1], v[2], 0),
            .rotation => rot[tr.target_node] = f32x4(v[0], v[1], v[2], v[3]),
            .scale => scal[tr.target_node] = f32x4(v[0], v[1], v[2], 0),
        }
    }
}

fn sampleTrack(tr: Track, t: f32) [4]f32 {
    const n: usize = tr.times.len;
    if (n == 0) {
        return .{ 0, 0, 0, 0 };
    }
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
    s.t_walk += f.time.delta_time;
    if (s.t_walk > s.walk.duration) {
        s.t_walk -= s.walk.duration;
    }
    s.t_attack += f.time.delta_time;
    if (s.t_attack > s.attack.duration) {
        s.t_attack -= s.attack.duration;
    }

    // ---- sample both clips into per-node local TRS ----
    var wt: [max_nodes]Vec = undefined;
    var wr: [max_nodes]Vec = undefined;
    var ws: [max_nodes]Vec = undefined;
    var at: [max_nodes]Vec = undefined;
    var ar: [max_nodes]Vec = undefined;
    var as: [max_nodes]Vec = undefined;
    poseFromClip(s, s.walk, s.t_walk, &wt, &wr, &ws);
    poseFromClip(s, s.attack, s.t_attack, &at, &ar, &as);

    // ---- blend per node, then walk the hierarchy ----
    var world: [max_nodes]Mat = undefined;
    for (s.order[0..s.node_count]) |ni| {
        // 0 = full walk, 1 = full attack. Split mode: upper body = attack (1),
        // lower body = walk (0). Uniform mode: everything at 0.5.
        const factor: f32 = if (s.split_mode) (if (s.upper[ni]) 1.0 else 0.0) else 0.5;
        const tt: Vec = lerpVec(wt[ni], at[ni], factor);
        const rr: Vec = nlerp(wr[ni], ar[ni], factor);
        const sc: Vec = lerpVec(ws[ni], as[ni], factor);
        const local: Mat = composeN(scalingV(sc), matFromQuat(rr), translationV(tt));
        const p: i32 = s.parent[ni];
        world[ni] = if (p < 0) local else compose(local, world[@intCast(p)]);
    }

    // ---- skin: v' = Σ wₖ · (v · invBindₖ · worldₖ) ----
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

    // ---- UI ----
    const vw: f32 = @max(f.window.widthf(), 1);
    const u: z.ui_real.Ui = s.ui_host.begin(f);
    u.setNextWindowPos(.{ 8, 8 }, .{});
    u.setNextWindowSize(.{ @min(300, vw - 16), 96 }, .{});
    if (u.window("animation blend", .{})) |w| {
        defer w.close();
        _ = u.checkbox("upper/lower split (else uniform 50/50)", &s.split_mode);
    }

    // ---- draw ----
    const cam: Camera3D = s.cam.update(f, u.wantCaptureMouse(), .{ .fovy_deg = 50 });
    z.beginMode3D(f.gl, cam);
    z.drawGrid(f.gl, 12, 0.5);
    z.drawModel(f.gl, s.char_model, pointVec(0, 0, 0), 1.0, c.emerald_400);
    z.endMode3D(f.gl);

    const mode: []const u8 = if (s.split_mode)
        "upper: 3_attack   lower: 2_move"
    else
        "uniform 50/50 blend";
    f.gl.text(.{ 16, 112 }, mode, .{
        .size = 16,
        .color = .{ .r = 190, .g = 200, .b = 215, .a = 255 },
        .font = &s.font,
    });
    common.caption(f.gl, s.font, "per-bone blend: arms swing the attack while the legs keep walking");
    s.ui_host.render(f);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - WebGPU - animation blend (per-bone)",
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
