//! src/tests/ragdoll_bvh_test.zig — the real-data half of retarget_plan.md §13x.
//!
//! §13x-2's unit test proves the qpos path on a synthetic four-bone chain. This proves it on
//! the ACTUAL Geno skeleton driven by the ACTUAL dance capture: 96 bones, real offsets, a real
//! travelling root.
//!
//! ── ★★★ WHY BOTH, AND WHY THIS ONE MATTERS MORE ──
//!
//! A four-bone chain cannot exercise: a deep hierarchy where a parent error compounds, zero
//! length end-site bones, a root that translates, or 96 distinct quaternions. It CAN be wrong
//! in a way that a hand-built chain happens not to reach.
//!
//! ★ And the property is EXACTNESS, not tolerance. The robot's `kinematics` and the animation's
//! forward kinematics are two independent implementations of the same recursion. Driving one
//! with the other's data must agree to float precision, because it is a COPY. Anything else
//! means the qpos path is lying.
//!
//! ── ★★ WHAT THIS TEST CANNOT CATCH, STATED SO NOBODY TRUSTS IT TOO FAR ──
//!
//! Both sides share `quatFromChannels`, so a WRONG EULER DECODE cancels out: feed the
//! reference and the robot the same bad rotations and they still agree. Verified — corrupting
//! the channel order leaves this test green.
//!
//! ★ That is the correct scope, not a hole to plug here: this test is about the **qpos path**,
//! and the decode belongs to whatever produced the rotations. Confirmed the other way too —
//! writing the quaternion in MuJoCo's (w,x,y,z) instead of zm's (x,y,z,w) FAILS it across all
//! 96 bones.
//!
//! ★ A 0.0001 perturbation of one quaternion component also passes, because the joint
//! normalises: a control has to change the ROTATION, not just the numbers.
//!
//! ★ Lives in the FAST TIER (`zig build test-fast`) because `codecs.zig` and `robot.zig` both
//! depend on nothing but `zm` — no shaders, no renderer. See claude.md.

const std = @import("std");
const zm = @import("zm");
const codecs = @import("codecs");
const rbt = @import("robot");

const Allocator = std.mem.Allocator;
const Vec = zm.Vec;
const Quat = zm.Quat;
const vec = zm.vec;
const radFromDeg = zm.radFromDeg;
const float = zm.float;
const expect = std.testing.expect;

/// Euler angles to a quaternion in the BVH channel order the file declares.
///
/// ★ BVH rotation channels are applied in the ORDER THE HEADER LISTS THEM, which for
/// `dance1_subject2` is ZYX. Assuming XYZ produces a skeleton that is subtly and consistently
/// wrong — every joint bent about the wrong axis first.
fn quatFromChannels(chans: []const codecs.bvh.Channel, values: []const f32) Quat {
    var q: Quat = zm.quat_identity;
    for (chans, 0..) |c, i| {
        const a: f32 = radFromDeg(values[i]);
        const axis: ?Vec = switch (c) {
            .x_rotation => vec(1, 0, 0),
            .y_rotation => vec(0, 1, 0),
            .z_rotation => vec(0, 0, 1),
            else => null,
        };
        if (axis) |ax| {
            q = zm.qmul(q, zm.quatFromAxisAngle(ax, a));
        }
    }
    return q;
}

test "ragdoll: the real Geno skeleton plays the real dance frame exactly" {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var fh: std.Io.File = std.Io.Dir.cwd().openFile(
        io,
        "examples/geno_dance/dance1_20s.bvh",
        .{},
    ) catch return;
    defer fh.close(io);
    const st: std.Io.File.Stat = try fh.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, st.size);
    defer gpa.free(bytes);
    _ = try fh.readPositionalAll(io, bytes, 0);

    var data: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
    defer data.deinit();

    const n: usize = data.joints.len;
    try expect(n > 50); // the real thing, not a stub

    // ---- unpack the skeleton into the plain slices `skeletonToModel` takes ----
    const names: [][]const u8 = try gpa.alloc([]const u8, n);
    defer gpa.free(names);
    const parents: []i32 = try gpa.alloc(i32, n);
    defer gpa.free(parents);
    const offsets: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(offsets);
    // ★ METRES. The capture is centimetres and `robot.zig` speaks metres, so the conversion
    // happens here at load — the same rule the render path follows (claude.md).
    const cm_to_m: f32 = 0.01;
    for (data.joints, 0..) |j, i| {
        names[i] = j.name;
        parents[i] = j.parent;
        offsets[i] = vec(j.offset[0], j.offset[1], j.offset[2]) * @as(Vec, @splat(cm_to_m));
    }

    var m: rbt.Model = try rbt.skeletonToModel(gpa, names, parents, offsets, .{});
    defer m.deinit();
    var d: rbt.Data = try rbt.Data.init(gpa, &m);
    defer d.deinit();

    // ---- decode one frame's channels into local rotations + root translation ----
    const frame: usize = 120;
    try expect(data.frame_count > frame);
    const row: []const f32 =
        data.motion[frame * data.channel_count ..][0..data.channel_count];

    const rots: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(rots);
    var root_translation: Vec = vec(0, 0, 0);
    var cursor: usize = 0;
    for (data.joints, 0..) |j, i| {
        const vals: []const f32 = row[cursor..][0..j.channels.len];
        cursor += j.channels.len;
        var pos: Vec = vec(0, 0, 0);
        for (j.channels, 0..) |c, k| {
            switch (c) {
                .x_position => pos[0] = vals[k],
                .y_position => pos[1] = vals[k],
                .z_position => pos[2] = vals[k],
                else => {},
            }
        }
        if (i == 0) {
            root_translation = pos * @as(Vec, @splat(cm_to_m));
        }
        rots[i] = quatFromChannels(j.channels, vals);
    }

    @memcpy(d.pos, m.qpos0);
    rbt.poseFromLocalRotations(&m, &d, root_translation, rots);
    rbt.kinematics(&m, &d);

    // ---- the independent reference: plain forward kinematics over the same data ----
    const ref_pos: []Vec = try gpa.alloc(Vec, n);
    defer gpa.free(ref_pos);
    const ref_rot: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(ref_rot);
    for (0..n) |i| {
        if (parents[i] < 0) {
            ref_rot[i] = rots[i];
            ref_pos[i] = root_translation;
        } else {
            const p: usize = @intCast(parents[i]);
            ref_rot[i] = zm.qmul(ref_rot[p], rots[i]);
            ref_pos[i] = ref_pos[p] + zm.rotate(ref_rot[p], offsets[i]);
        }
    }

    // ★★ EXACT, ACROSS ALL 96 BONES. A tolerance of 1e-4 m is a tenth of a millimetre on a
    // 1.7 m figure — this is float noise, not agreement-within-reason.
    var worst: f32 = 0;
    for (0..n) |i| {
        const got: Vec = d.body_xpos[i + 1]; // body 0 is the world
        const want: Vec = ref_pos[i];
        inline for (0..3) |c| {
            worst = @max(worst, @abs(got[c] - want[c]));
        }
    }
    try expect(worst < 1.0e-4);

    // ★ And the root actually MOVED — a frame where everything sat at the origin would make
    // the comparison above pass while proving nothing.
    const travel: f32 = @abs(root_translation[0]) + @abs(root_translation[2]);
    try expect(travel > 0.1);
}

test "retarget: a skeleton onto ITSELF reproduces the source pose exactly" {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var fh: std.Io.File = std.Io.Dir.cwd().openFile(
        io,
        "examples/geno_dance/dance1_20s.bvh",
        .{},
    ) catch return;
    defer fh.close(io);
    const st: std.Io.File.Stat = try fh.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, st.size);
    defer gpa.free(bytes);
    _ = try fh.readPositionalAll(io, bytes, 0);
    var data: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
    defer data.deinit();

    const n: usize = data.joints.len;
    const names: [][]const u8 = try gpa.alloc([]const u8, n);
    defer gpa.free(names);
    const parents: []i32 = try gpa.alloc(i32, n);
    defer gpa.free(parents);
    for (data.joints, 0..) |j, i| {
        names[i] = j.name;
        parents[i] = j.parent;
    }

    // ★★★ THE DEGENERATE CASE, AND IT IS NOT VACUOUS. Retargeting a skeleton onto itself must
    // return the pose unchanged — but unlike a bind-pose identity (which holds for ANY bind,
    // as §11 learned the hard way), this exercises the ENTIRE path: the name map, the
    // global-to-local conversion, and the parent walk. A sign error, a conjugate the wrong way
    // round, or a parent visited out of order all break it.
    const map: []i32 = try codecs.bvh.mapJointsByName(gpa, names, names, .{});
    defer gpa.free(map);
    try expect(codecs.bvh.mappedCount(map) == n);

    // A source pose: give every joint a distinct rotation so nothing cancels.
    const src_local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(src_local);
    for (0..n) |i| {
        const t: f32 = float(i) * 0.137;
        src_local[i] = zm.quatFromAxisAngle(
            zm.normalize3(vec(@sin(t) + 1.1, @cos(t * 1.7), @sin(t * 0.3) - 0.4)),
            0.2 + 0.15 * @sin(t * 2.1),
        );
    }
    const src_global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(src_global);
    for (0..n) |i| {
        src_global[i] = if (parents[i] < 0)
            src_local[i]
        else
            zm.qmul(src_global[@intCast(parents[i])], src_local[i]);
    }

    const out_local: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(out_local);
    const out_global: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(out_global);
    // Identity alignment: a skeleton against itself already agrees about rest.
    const identity_alignment: []Quat = try gpa.alloc(Quat, n);
    defer gpa.free(identity_alignment);
    for (identity_alignment) |*q| {
        q.* = zm.quat_identity;
    }
    codecs.bvh.retargetRotations(parents, map, src_global, identity_alignment, out_local, out_global);

    // Every LOCAL rotation must come back as it went in (up to quaternion double-cover).
    var worst: f32 = 0;
    for (0..n) |i| {
        const a: Quat = src_local[i];
        const b: Quat = out_local[i];
        const dotp: f32 = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
        const sign: f32 = if (dotp < 0) -1.0 else 1.0;
        inline for (0..4) |c| {
            worst = @max(worst, @abs(a[c] - b[c] * sign));
        }
    }
    try expect(worst < 1.0e-4);
}

test "retarget: the mixamorig: prefix is stripped, and an unmapped rig is visibly empty" {
    const gpa: Allocator = std.testing.allocator;

    // ★ THE REAL MISMATCH, from the files: Mixamo prefixes every joint. Without stripping, a
    // LAFAN1 table matches NOTHING — and the failure mode is a rest pose, not an error, which
    // is why `mappedCount` exists and why callers must check it.
    const lafan = [_][]const u8{ "Hips", "Spine", "LeftArm", "Head" };
    const mixamo = [_][]const u8{
        "mixamorig:Hips",
        "mixamorig:Spine",
        "mixamorig:LeftArm",
        "mixamorig:Head",
    };

    const stripped: []i32 = try codecs.bvh.mapJointsByName(gpa, &mixamo, &lafan, .{});
    defer gpa.free(stripped);
    try expect(codecs.bvh.mappedCount(stripped) == 4);

    // With stripping disabled, nothing matches — the silent-failure case, made loud.
    const raw: []i32 = try codecs.bvh.mapJointsByName(gpa, &mixamo, &lafan, .{ .strip_prefix_at = "" });
    defer gpa.free(raw);
    try expect(codecs.bvh.mappedCount(raw) == 0);

    // ★ And a genuinely absent joint stays absent rather than matching something close.
    const partial = [_][]const u8{ "Hips", "Spine", "Tail" };
    const p: []i32 = try codecs.bvh.mapJointsByName(gpa, &lafan, &partial, .{});
    defer gpa.free(p);
    try expect(codecs.bvh.mappedCount(p) == 2);
    try expect(p[2] == codecs.bvh.no_source);
}

/// Load a BVH file and hand back its parsed data, or null when the fixture is absent.
fn loadBvhFixture(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
) !?codecs.bvh.Data {
    var file: std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const stat: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, stat.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return try codecs.bvh.parse(gpa, bytes, null);
}

/// Load an FBX file's SKELETON as BVH-shaped data, or null when the fixture is absent.
fn loadFbxSkeletonFixture(
    gpa: Allocator,
    io: std.Io,
    path: []const u8,
) !?codecs.bvh.Data {
    var file: std.Io.File = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer file.close(io);
    const stat: std.Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, stat.size);
    defer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    var scene: codecs.fbx.Scene = try codecs.fbx.loadScene(gpa, bytes);
    defer scene.deinit();
    return try codecs.bvh.fromFbx(gpa, &scene, .{});
}

test "retarget: LAFAN1 dance onto the Mixamo skeleton keeps bone DIRECTIONS, not lengths" {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();

    var source: codecs.bvh.Data =
        (try loadBvhFixture(gpa, io, "examples/geno_dance/dance1_20s.bvh")) orelse return;
    defer source.deinit();
    var target: codecs.bvh.Data =
        (try loadFbxSkeletonFixture(gpa, io, "assets/Drop_Kick.fbx")) orelse return;
    defer target.deinit();

    const source_joint_count: usize = source.joints.len;
    const target_joint_count: usize = target.joints.len;

    const source_names: [][]const u8 = try gpa.alloc([]const u8, source_joint_count);
    defer gpa.free(source_names);
    for (source.joints, 0..) |joint, index| {
        source_names[index] = joint.name;
    }
    const target_names: [][]const u8 = try gpa.alloc([]const u8, target_joint_count);
    defer gpa.free(target_names);
    const target_parents: []i32 = try gpa.alloc(i32, target_joint_count);
    defer gpa.free(target_parents);
    const target_offsets: []Vec = try gpa.alloc(Vec, target_joint_count);
    defer gpa.free(target_offsets);
    for (target.joints, 0..) |joint, index| {
        target_names[index] = joint.name;
        target_parents[index] = joint.parent;
        target_offsets[index] = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
    }

    // ★★ THE REAL CROSS-RIG MAP: LAFAN1 names against `mixamorig:`-prefixed ones. If the
    // prefix strip regressed, this drops to zero and the assertion below says so loudly —
    // which is the whole reason `mappedCount` is public.
    const source_of_target: []i32 =
        try codecs.bvh.mapJointsByName(gpa, source_names, target_names, .{});
    defer gpa.free(source_of_target);
    const matched: usize = codecs.bvh.mappedCount(source_of_target);
    // ★ MEASURED: 72 of 78 Mixamo joints find a LAFAN1 source (the capture has 96). The six
    // that do not are the rigs genuinely disagreeing — Mixamo's `HeadTop_End` vs LAFAN1's
    // `HeadEnd`, and end sites the two name differently. They keep their rest orientation,
    // which is the correct degradation: a stiff fingertip, not a scrambled skeleton.
    //
    // ★ The threshold is deliberately far below 72. It is here to catch a REGRESSION in the
    // prefix strip (which would give 0), not to pin an exact count that a fixture change
    // would break for no reason.
    try expect(matched > 30);

    // ---- one frame of the source, as global rotations ----
    const frame: usize = 200;
    try expect(source.frame_count > frame);
    const motion_row: []const f32 =
        source.motion[frame * source.channel_count ..][0..source.channel_count];

    const source_local_rotations: []Quat = try gpa.alloc(Quat, source_joint_count);
    defer gpa.free(source_local_rotations);
    var channel_cursor: usize = 0;
    for (source.joints, 0..) |joint, index| {
        const joint_values: []const f32 = motion_row[channel_cursor..][0..joint.channels.len];
        channel_cursor += joint.channels.len;
        source_local_rotations[index] = quatFromChannels(joint.channels, joint_values);
    }
    const source_global_rotations: []Quat = try gpa.alloc(Quat, source_joint_count);
    defer gpa.free(source_global_rotations);
    for (source.joints, 0..) |joint, index| {
        source_global_rotations[index] = if (joint.parent < 0)
            source_local_rotations[index]
        else
            zm.qmul(source_global_rotations[@intCast(joint.parent)], source_local_rotations[index]);
    }

    // ---- retarget ----
    const target_local_rotations: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(target_local_rotations);
    const target_global_rotations: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(target_global_rotations);
    // ★ Rest alignment, DERIVED from the two skeletons rather than hand-authored.
    const source_rest: []Quat = try gpa.alloc(Quat, source_joint_count);
    defer gpa.free(source_rest);
    const source_parents: []i32 = try gpa.alloc(i32, source_joint_count);
    defer gpa.free(source_parents);
    const source_offsets: []Vec = try gpa.alloc(Vec, source_joint_count);
    defer gpa.free(source_offsets);
    for (source.joints, 0..) |joint, index| {
        source_parents[index] = joint.parent;
        source_offsets[index] = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
    }
    codecs.bvh.restBoneOrientations(source_parents, source_offsets, source_rest);

    const target_rest: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(target_rest);
    codecs.bvh.restBoneOrientations(target_parents, target_offsets, target_rest);

    const rest_alignment: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(rest_alignment);
    codecs.bvh.restAlignmentOffsets(source_of_target, source_rest, target_rest, rest_alignment);

    codecs.bvh.retargetRotations(
        target_parents,
        source_of_target,
        source_global_rotations,
        rest_alignment,
        target_local_rotations,
        target_global_rotations,
    );

    // ★★★ THE PROPERTY THAT MAKES THIS A RETARGET AND NOT A COPY.
    //
    // A mapped target joint must end up ORIENTED like its source — that is what carries the
    // motion across. But its bone LENGTHS stay its own, which is what makes it the Mixamo
    // character performing the dance rather than Geno wearing a Mixamo name.
    //
    // So: every mapped joint's global rotation must equal its source's, exactly. Anything else
    // means the parent walk or the local conversion is wrong.
    var worst_orientation_error: f32 = 0;
    var checked_joints: usize = 0;
    for (0..target_joint_count) |target_joint| {
        const matched_source: i32 = source_of_target[target_joint];
        if (matched_source == codecs.bvh.no_source) {
            continue;
        }
        const want: Quat = zm.qmul(
            source_global_rotations[@intCast(matched_source)],
            rest_alignment[target_joint],
        );
        const got: Quat = target_global_rotations[target_joint];
        const alignment: f32 =
            want[0] * got[0] + want[1] * got[1] + want[2] * got[2] + want[3] * got[3];
        const sign: f32 = if (alignment < 0) -1.0 else 1.0;
        inline for (0..4) |component| {
            worst_orientation_error =
                @max(worst_orientation_error, @abs(want[component] - got[component] * sign));
        }
        checked_joints += 1;
    }
    try expect(checked_joints > 30);
    try expect(worst_orientation_error < 1.0e-5);

    // ★ And the target keeps its OWN proportions: at least one mapped bone must differ in
    // length from its source counterpart, or the two rigs are secretly the same size and this
    // test proves less than it appears to.
    var found_a_different_bone_length: bool = false;
    for (0..target_joint_count) |target_joint| {
        const matched_source: i32 = source_of_target[target_joint];
        if (matched_source == codecs.bvh.no_source or target_parents[target_joint] < 0) {
            continue;
        }
        const target_offset: Vec = target_offsets[target_joint];
        const target_length: f32 = @sqrt(
            target_offset[0] * target_offset[0] +
                target_offset[1] * target_offset[1] +
                target_offset[2] * target_offset[2],
        );
        const source_joint: codecs.bvh.Joint = source.joints[@intCast(matched_source)];
        const source_length: f32 = @sqrt(
            source_joint.offset[0] * source_joint.offset[0] +
                source_joint.offset[1] * source_joint.offset[1] +
                source_joint.offset[2] * source_joint.offset[2],
        );
        if (@abs(target_length - source_length) > 0.5) {
            found_a_different_bone_length = true;
            break;
        }
    }
    try expect(found_a_different_bone_length);
}

test "retarget: rest alignment puts a target's REST bone where its own rest points" {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var source: codecs.bvh.Data =
        (try loadBvhFixture(gpa, io, "examples/geno_dance/dance1_20s.bvh")) orelse return;
    defer source.deinit();
    var target: codecs.bvh.Data =
        (try loadFbxSkeletonFixture(gpa, io, "assets/Drop_Kick.fbx")) orelse return;
    defer target.deinit();

    // ★★★ THE BUG THIS EXISTS FOR, MEASURED FROM THE FILES:
    //
    //     LeftLeg    LAFAN1 (0,-1,0)   Mixamo (0,+1,0)   dot = -1.000
    //     LeftFoot   LAFAN1 (0,-1,0)   Mixamo (0,+1,0)   dot = -1.000
    //     LeftArm    LAFAN1 (0, 1,0)   Mixamo (0, 1,0)   dot = +1.000
    //
    // The leg bones point OPPOSITE at rest while the arms agree, so a plain global-orientation
    // copy bent the legs backwards — visible on device, and invisible in every test that only
    // compared a skeleton against itself.
    const source_joint_count: usize = source.joints.len;
    const target_joint_count: usize = target.joints.len;

    const source_parents: []i32 = try gpa.alloc(i32, source_joint_count);
    defer gpa.free(source_parents);
    const source_offsets: []Vec = try gpa.alloc(Vec, source_joint_count);
    defer gpa.free(source_offsets);
    const source_names: [][]const u8 = try gpa.alloc([]const u8, source_joint_count);
    defer gpa.free(source_names);
    for (source.joints, 0..) |joint, index| {
        source_parents[index] = joint.parent;
        source_offsets[index] = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
        source_names[index] = joint.name;
    }

    const target_parents: []i32 = try gpa.alloc(i32, target_joint_count);
    defer gpa.free(target_parents);
    const target_offsets: []Vec = try gpa.alloc(Vec, target_joint_count);
    defer gpa.free(target_offsets);
    const target_names: [][]const u8 = try gpa.alloc([]const u8, target_joint_count);
    defer gpa.free(target_names);
    for (target.joints, 0..) |joint, index| {
        target_parents[index] = joint.parent;
        target_offsets[index] = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
        target_names[index] = joint.name;
    }

    const source_of_target: []i32 =
        try codecs.bvh.mapJointsByName(gpa, source_names, target_names, .{});
    defer gpa.free(source_of_target);

    const source_rest: []Quat = try gpa.alloc(Quat, source_joint_count);
    defer gpa.free(source_rest);
    codecs.bvh.restBoneOrientations(source_parents, source_offsets, source_rest);
    const target_rest: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(target_rest);
    codecs.bvh.restBoneOrientations(target_parents, target_offsets, target_rest);

    const rest_alignment: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(rest_alignment);
    codecs.bvh.restAlignmentOffsets(source_of_target, source_rest, target_rest, rest_alignment);

    // ★★ THE PROPERTY: feed the retarget the SOURCE'S OWN REST orientations, and every target
    // joint must come out at ITS OWN rest orientation. Rest maps to rest — which is exactly
    // what "align the T-poses" means, and it is derived from the files rather than authored.
    const out_local: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(out_local);
    const out_global: []Quat = try gpa.alloc(Quat, target_joint_count);
    defer gpa.free(out_global);
    codecs.bvh.retargetRotations(
        target_parents,
        source_of_target,
        source_rest,
        rest_alignment,
        out_local,
        out_global,
    );

    var worst_rest_error: f32 = 0;
    var checked: usize = 0;
    for (0..target_joint_count) |target_joint| {
        if (source_of_target[target_joint] == codecs.bvh.no_source) {
            continue;
        }
        const want: Quat = target_rest[target_joint];
        const got: Quat = out_global[target_joint];
        const alignment: f32 =
            want[0] * got[0] + want[1] * got[1] + want[2] * got[2] + want[3] * got[3];
        const sign: f32 = if (alignment < 0) -1.0 else 1.0;
        inline for (0..4) |component| {
            worst_rest_error = @max(worst_rest_error, @abs(want[component] - got[component] * sign));
        }
        checked += 1;
    }
    try expect(checked > 30);
    try expect(worst_rest_error < 1.0e-4);

    // ★ And the alignment is NOT all identity — if it were, this test would pass while
    // changing nothing, which is how a correction quietly becomes a no-op.
    var found_a_real_correction: bool = false;
    for (0..target_joint_count) |target_joint| {
        if (source_of_target[target_joint] == codecs.bvh.no_source) {
            continue;
        }
        const q: Quat = rest_alignment[target_joint];
        const is_identity: bool = @abs(@abs(q[3]) - 1.0) < 1.0e-3;
        if (!is_identity) {
            found_a_real_correction = true;
            break;
        }
    }
    try expect(found_a_real_correction);
}

test "retarget: an FBX's bind orientations describe a real pose, unlike its bare offsets" {
    const gpa: Allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io: std.Io = threaded.io();
    var target: codecs.bvh.Data =
        (try loadFbxSkeletonFixture(gpa, io, "assets/Drop_Kick.fbx")) orelse return;
    defer target.deinit();

    const joint_count: usize = target.joints.len;

    // ★★★ THE MEASUREMENT THAT CONDEMNS THE DERIVED APPROACH.
    //
    // FK-ing Mixamo's offsets with IDENTITY rotations — which is what deriving an orientation
    // from bone directions assumes — puts every bone along +Y:
    //
    //     LeftHand (4.6, 212.0, 0.7)   straight up above the shoulder
    //     LeftFoot (8.2, 186.4, 0.0)   also up
    //
    // That is not a pose. The offsets live in ROTATED local joint frames, so a direction taken
    // from them describes nothing, and any correction built on it is built on noise.
    const rest_positions: []Vec = try gpa.alloc(Vec, joint_count);
    defer gpa.free(rest_positions);
    for (target.joints, 0..) |joint, index| {
        const offset: Vec = vec(joint.offset[0], joint.offset[1], joint.offset[2]);
        rest_positions[index] = if (joint.parent < 0)
            offset
        else
            rest_positions[@intCast(joint.parent)] + offset;
    }

    var hand_height: f32 = 0;
    var foot_height: f32 = 0;
    var hips_height: f32 = 0;
    for (target.joints, 0..) |joint, index| {
        const bare: []const u8 = if (std.mem.lastIndexOf(u8, joint.name, ":")) |i|
            joint.name[i + 1 ..]
        else
            joint.name;
        if (std.mem.eql(u8, bare, "LeftHand")) {
            hand_height = rest_positions[index][1];
        }
        if (std.mem.eql(u8, bare, "LeftFoot")) {
            foot_height = rest_positions[index][1];
        }
        if (std.mem.eql(u8, bare, "Hips")) {
            hips_height = rest_positions[index][1];
        }
    }

    // A real skeleton puts the FOOT below the hips. This one does not — proving the identity
    // assumption is false for this rig, which is the whole reason a T-pose is needed.
    try expect(hips_height > 50.0);
    try expect(foot_height > hips_height);
    try expect(hand_height > hips_height + 80.0);
}
