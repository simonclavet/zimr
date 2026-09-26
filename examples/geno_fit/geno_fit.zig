//! examples/geno_fit - the new robot's body, riding the captures it will have to track.
//!
//! WHAT YOU ARE LOOKING AT
//!
//! Geno's skeleton, moved by a capture exactly as the capture says - no retargeting, no IK, no robot
//! physics - wearing the collision shapes fitted to Geno's own skinned mesh, and (the "mesh" toggle)
//! Geno's mesh itself, skinned by the same pose. Capsules everywhere but the feet and toes, which are
//! boxes aligned with the floor so a planted sole is flat.
//!
//! The shapes are made by `tools/geno_fit.py`, and three rules shape what you see:
//!   - limbs span joint to joint along their flesh, and neighbours must OVERLAP at every joint, so an
//!     elbow or a knee always reads as connected;
//!   - every shape stays inside the posed mesh on every frame of both captures (within 3 mm), so that
//!     lying down, the shapes meet the floor where the body does - each fixed by whichever change
//!     loses the least volume: pulling an end in, thinning, or both;
//!   - the torso is built from the body's cross-sections and then made ATHLETIC on purpose - belly in,
//!     chest a little fuller and wider, the back held where it is - at some cost in fit.
//!
//! This is the question to answer by eye before any of it becomes a physical robot: do these shapes
//! follow the character through a whole get-up and a dance? With the mesh on and the shapes on, the
//! skin turns see-through: look for shapes poking out of it, and for gaps it hides.
//!
//! HOW THE SHAPES STAY ON THEIR BONES
//!
//! The shapes were fitted in the BIND pose - where the mesh was skinned - and are stored in that
//! pose's world coordinates. At startup this page runs the bind pose through the very same forward
//! kinematics it animates with, and expresses each shape in its bone's frame from there. So the frame
//! a shape is attached in and the frame it is moved by are the same by construction, whatever
//! convention the kinematics use.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui;
const codecs = z.codecs;
const d3 = z.draw3d;
const fitted = z.robot_geno_shapes;

const Allocator = std.mem.Allocator;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const Vec = zm.Vec;
const Mat = zm.Mat;
const Quat = zm.Quat;
const vec = zm.vec;
const float = zm.float;
const int = zm.int;
const clamp = zm.clamp;
const splat = zm.splat;
const mulMat = zm.mulMat;
const qmul = zm.qmul;
const rotate = zm.rotate;
const conjugate = zm.conjugate;
const quatToMat = zm.quatToMat;
const quatFromTo = zm.quatFromTo;
const translation = zm.translation;
const scaling = zm.scaling;
const length3 = zm.length3;
const exp = zm.exp;
const identity = zm.identity;
const inverse = zm.inverse;
const matFromQuat = zm.matFromQuat;
const translationV = zm.translationV;

const bind_bvh = @embedFile("geno_bind.bvh");
/// Geno's own mesh and skin weights, from the same FBX the retargeting demo shows. Only the mesh is
/// taken from it: the pose comes from the capture, and each bone's bind frame from this page's own
/// kinematics of the bind file - the very frames the shapes are attached in, so the mesh and the
/// shapes can never disagree about where a bone is.
const geno_fbx = @embedFile("Geno.fbx");
const getup_bvh = @embedFile("getup.bvh");
const dance_bvh = @embedFile("dance.bvh");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const bg: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 };
const ground_col: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 };
const capsule_col: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 };
const box_col: Color = .{ .r = 150, .g = 190, .b = 140, .a = 255 };
const bone_col: Color = .{ .r = 230, .g = 210, .b = 120, .a = 255 };
const skin_col: Color = .{ .r = 225, .g = 205, .b = 190, .a = 255 };
/// The skin while the shapes are on: see-through, so the shapes stay visible inside it.
const skin_see_through_col: Color = .{ .r = 225, .g = 205, .b = 190, .a = 110 };

/// Captures are in centimetres; everything here is metres.
const cm: f32 = 0.01;

/// A fitted shape, expressed in its bone's own frame.
const Placed = struct {
    shape: fitted.Shape,
    /// Capsule: both end centres, in the bone's frame. Box: its centre.
    a: Vec,
    b: Vec,
    radius: f32,
    /// Box only: its orientation relative to the bone, and its half extents.
    rotation: Quat,
    half: Vec,
};

/// One capture, loaded and ready to pose.
const Capture = struct {
    clip: d3.BvhSkeletalClip,
    positions: []Vec,
    rotations: []Quat,
    /// For each fitted shape, the index of its bone in THIS capture - found by name, since the bind
    /// file (75 bones, with fingers) and a capture (35) number their bones differently.
    bone_of: []i32,
    /// How far to raise the character on each frame so no shape is below the floor - the capture's
    /// actor was built differently from Geno, and lying down Geno's head and hands would otherwise sink
    /// up to 13 cm into the ground. Worked out once at startup, over every frame.
    lift: []f32,

    fn frames(self: Capture) usize {
        return int(usize, float(@max(self.clip.animation.keyframeCount, 1)));
    }
};

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    cube: z.Mesh,
    sphere: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,

    placed: [fitted.geoms.len]Placed,
    captures: [2]Capture,
    /// Which capture is on show: 0 the get-up, 1 the dance.
    which: usize = 0,
    frame: f32 = 0,
    playing: bool = true,
    show_shapes: bool = true,
    show_bones: bool = true,
    show_mesh: bool = true,

    /// Geno's mesh, and what it takes to skin it with a capture.
    geno: d3.FbxModel,
    /// Per capture, per model bone: the capture bone that carries it - its own, or its nearest carried
    /// ancestor (the captures have no fingers; they stay where they sat on the hand).
    carrier: [2][]usize,
    /// Per capture, per model bone: that carrier's bind-pose frame, undone.
    unbind: [2][]Mat,
    skin: []Mat,
    /// The mesh at rest, kept apart from the mesh's own arrays: skinning writes those, and reading the
    /// rest pose back out of them would feed each frame's result into the next.
    rest: [][]f32,
    rest_normals: [][]f32,
    posed: [][]f32,
    posed_normals: [][]f32,
};

fn boneIndex(clip: d3.BvhSkeletalClip, name: []const u8) ?usize {
    for (0..clip.boneCount()) |i| {
        if (std.mem.eql(u8, clip.boneName(i), name)) {
            return i;
        }
    }
    return null;
}

/// Load Geno's mesh and work out, for each capture, which capture bone carries each of the model's
/// bones and where that carrier sat in the bind pose.
///
/// The skin matrix of a model bone is then "undo the carrier's bind frame, apply its frame now". For a
/// bone the capture carries itself that is ordinary skinning; for a finger it is exactly "stay where you
/// were on the hand", which is what the capture means by leaving the fingers out.
fn loadMesh(gpa: Allocator, f: *z.Frame, s: *State, bind: *const Capture) !void {
    // Geno's normals need rebuilding: over half of the file's oppose their triangle's winding, which
    // renders as dark bands down the limbs (the retargeting demo found this).
    s.geno = try d3.loadFbxModel(gpa, geno_fbx, .{ .recompute_normals = true, .scale = cm });
    const bones: usize = s.geno.clip.boneCount();
    s.skin = try gpa.alloc(Mat, bones);
    for (0..2) |c| {
        const capture: *const Capture = &s.captures[c];
        s.carrier[c] = try gpa.alloc(usize, bones);
        s.unbind[c] = try gpa.alloc(Mat, bones);
        for (0..bones) |b| {
            // Walk up from this bone to the first one the capture moves.
            var at: i32 = @intCast(b);
            var found: ?usize = null;
            while (at >= 0) : (at = s.geno.clip.skeleton.bones[@intCast(at)].parent) {
                found = boneIndex(capture.clip, s.geno.clip.boneName(@intCast(at)));
                if (found != null) {
                    break;
                }
            }
            const carrier: usize = found orelse 0;
            s.carrier[c][b] = carrier;
            const i: usize = boneIndex(bind.clip, capture.clip.boneName(carrier)) orelse 0;
            // Rotate, then translate: `mulMat(a, b)` applies b first.
            const world: Mat = mulMat(translationV(bind.positions[i] * splat(cm)), matFromQuat(bind.rotations[i]));
            s.unbind[c][b] = inverse(world);
        }
    }
    const meshes: usize = @intCast(s.geno.model.meshCount);
    s.rest = try gpa.alloc([]f32, meshes);
    s.rest_normals = try gpa.alloc([]f32, meshes);
    s.posed = try gpa.alloc([]f32, meshes);
    s.posed_normals = try gpa.alloc([]f32, meshes);
    for (0..meshes) |m| {
        const mesh: z.Mesh = s.geno.model.meshes[m];
        const floats: usize = @as(usize, @intCast(mesh.vertexCount)) * 3;
        s.rest[m] = try gpa.dupe(f32, mesh.vertices[0..floats]);
        s.rest_normals[m] = try gpa.dupe(f32, mesh.normals[0..floats]);
        s.posed[m] = try gpa.alloc(f32, floats);
        s.posed_normals[m] = try gpa.alloc(f32, floats);
        // The instanced draw uploads lazily; skinning updates the GPU copy, so make one exist now.
        _ = z.uploadMeshGpu(f.gl, @ptrCast(&s.geno.model.meshes[m]));
    }
}

fn unloadMesh(gpa: Allocator, s: *State) void {
    for (0..s.rest.len) |m| {
        gpa.free(s.posed_normals[m]);
        gpa.free(s.posed[m]);
        gpa.free(s.rest_normals[m]);
        gpa.free(s.rest[m]);
    }
    gpa.free(s.posed_normals);
    gpa.free(s.posed);
    gpa.free(s.rest_normals);
    gpa.free(s.rest);
    for (0..2) |c| {
        gpa.free(s.unbind[c]);
        gpa.free(s.carrier[c]);
    }
    gpa.free(s.skin);
    d3.unloadFbxModel(gpa, s.geno);
}

/// Geno's mesh on this frame's pose (lift included - it rides the same bone positions as the shapes).
fn drawMesh(s: *State, gl: *z.WgpuGl, capture: *const Capture) void {
    for (s.skin, 0..) |*matrix, b| {
        const k: usize = s.carrier[s.which][b];
        const world: Mat = mulMat(translationV(capture.positions[k] * splat(cm)), matFromQuat(capture.rotations[k]));
        // The carrier's bind frame undone first, then its frame now - so `world` goes on the left.
        matrix.* = mulMat(world, s.unbind[s.which][b]);
    }
    s.transform[0] = identity();
    const colour: Color = if (s.show_shapes) skin_see_through_col else skin_col;
    for (0..s.rest.len) |m| {
        d3.skinMeshCpu(s.geno.model.meshes[m], s.rest[m], s.rest_normals[m], s.skin, s.posed[m], s.posed_normals[m]);
        z.updateMeshGpu(gl, s.geno.model.meshes[m]);
        // The model's mesh array is a C pointer, so its elements come out `allowzero`; these are real.
        z.drawMeshInstanced(gl, @ptrCast(&s.geno.model.meshes[m]), &s.transform, colour);
    }
}

fn loadCapture(gpa: Allocator, bytes: []const u8) !Capture {
    var data: codecs.bvh.Data = try codecs.bvh.parse(gpa, bytes, null);
    defer data.deinit();
    const clip: d3.BvhSkeletalClip = try d3.loadBvhSkeletalClip(gpa, data);
    errdefer d3.unloadBvhSkeletalClip(gpa, clip);
    const count: usize = clip.boneCount();
    const positions: []Vec = try gpa.alloc(Vec, count);
    errdefer gpa.free(positions);
    const rotations: []Quat = try gpa.alloc(Quat, count);
    errdefer gpa.free(rotations);
    const bone_of: []i32 = try gpa.alloc(i32, fitted.geoms.len);
    errdefer gpa.free(bone_of);
    const lift: []f32 = try gpa.alloc(f32, @max(int(usize, float(@max(clip.animation.keyframeCount, 1))), 1));
    @memset(lift, 0.0);
    for (fitted.geoms, 0..) |geom, g| {
        bone_of[g] = -1;
        for (0..count) |i| {
            if (std.mem.eql(u8, clip.boneName(i), geom.bone)) {
                bone_of[g] = @intCast(i);
                break;
            }
        }
    }
    return .{ .clip = clip, .positions = positions, .rotations = rotations, .bone_of = bone_of, .lift = lift };
}

fn unloadCapture(gpa: Allocator, capture: Capture) void {
    gpa.free(capture.lift);
    gpa.free(capture.bone_of);
    gpa.free(capture.rotations);
    gpa.free(capture.positions);
    d3.unloadBvhSkeletalClip(gpa, capture.clip);
}

fn toVec(v: [3]f32) Vec {
    return vec(v[0], v[1], v[2]);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 16),
        .ui_host = undefined,
        .cam = z.OrbitCamera.init(vec(0.0, 0.9, 0), 3.2),
        .cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0),
        .sphere = try z.genMeshSphere(gpa, 1.0, 10, 8),
        .cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2),
        .transform = .{zm.identity()},
        .placed = undefined,
        .captures = undefined,
        .geno = undefined,
        .carrier = undefined,
        .unbind = undefined,
        .skin = &.{},
        .rest = &.{},
        .rest_normals = &.{},
        .posed = &.{},
        .posed_normals = &.{},
    };
    s.ui_host = z.UiHost.init(gpa, s.font);

    // The bind pose through the same kinematics the captures will go through: each shape's bone frame
    // there is what the shape is attached in.
    const bind: Capture = try loadCapture(gpa, bind_bvh);
    defer unloadCapture(gpa, bind);
    d3.bvhForwardKinematics(bind.clip, 0, bind.positions, bind.rotations);
    for (fitted.geoms, 0..) |geom, g| {
        const bone: i32 = bind.bone_of[g];
        const at: Vec = if (bone >= 0) bind.positions[@intCast(bone)] * splat(cm) else vec(0, 0, 0);
        const turn: Quat = if (bone >= 0) bind.rotations[@intCast(bone)] else zm.qidentity();
        const undo: Quat = conjugate(turn);
        s.placed[g] = .{
            .shape = geom.shape,
            .a = rotate(undo, toVec(geom.a) - at),
            .b = rotate(undo, toVec(geom.b) - at),
            .radius = geom.radius,
            .rotation = qmul(undo, .{ geom.rotation[0], geom.rotation[1], geom.rotation[2], geom.rotation[3] }),
            .half = toVec(geom.half),
        };
    }
    s.captures[0] = try loadCapture(gpa, getup_bvh);
    s.captures[1] = try loadCapture(gpa, dance_bvh);
    try planLift(gpa, s, &s.captures[0]);
    try planLift(gpa, s, &s.captures[1]);
    try loadMesh(gpa, f, s, &bind);
}

/// The lowest point any shape reaches, with the capture posed at its current frame.
fn lowestShape(s: *const State, capture: *const Capture) f32 {
    var low: f32 = 1.0e9;
    for (s.placed, 0..) |shape, g| {
        const bone: i32 = capture.bone_of[g];
        if (bone < 0) {
            continue;
        }
        const at: Vec = capture.positions[@intCast(bone)] * splat(cm);
        const turn: Quat = capture.rotations[@intCast(bone)];
        switch (shape.shape) {
            .capsule => {
                const a: Vec = at + rotate(turn, shape.a);
                const b: Vec = at + rotate(turn, shape.b);
                low = @min(low, @min(a[1], b[1]) - shape.radius);
            },
            .box => {
                const centre: Vec = at + rotate(turn, shape.a);
                const facing: Quat = qmul(turn, shape.rotation);
                for ([_]f32{ -1, 1 }) |sx| {
                    for ([_]f32{ -1, 1 }) |sy| {
                        for ([_]f32{ -1, 1 }) |sz| {
                            const corner: Vec = centre + rotate(facing, shape.half * vec(sx, sy, sz));
                            low = @min(low, corner[1]);
                        }
                    }
                }
            },
        }
    }
    return low;
}

/// How far to raise the character on every frame, planned once for the whole capture.
///
/// What each frame NEEDS is simple: however far its lowest shape is below the floor. But a lift that
/// follows that frame by frame jerks the character up and down, and a plain smoothing of it dips below
/// the need at every sharp moment - putting shapes back through the floor exactly when they matter. So
/// each frame's need is first widened to the largest need among its neighbours (an envelope a quarter
/// of a second wide), and THAT is smoothed: the result is never below what any frame needs, and moves
/// like a body rather than a spring.
fn planLift(gpa: Allocator, s: *const State, capture: *Capture) !void {
    const n: usize = capture.lift.len;
    const need: []f32 = try gpa.alloc(f32, n);
    defer gpa.free(need);
    for (0..n) |frame| {
        d3.bvhForwardKinematics(capture.clip, frame, capture.positions, capture.rotations);
        need[frame] = @max(0.0, -lowestShape(s, capture));
    }
    const reach: usize = 8;
    const wide: []f32 = try gpa.alloc(f32, n);
    defer gpa.free(wide);
    for (0..n) |frame| {
        var most: f32 = 0.0;
        const from: usize = frame -| reach;
        const to: usize = @min(n, frame + reach + 1);
        for (need[from..to]) |x| {
            most = @max(most, x);
        }
        wide[frame] = most;
    }
    // A Gaussian over time, as wide as the envelope: smooth, and - because it averages values that are
    // each already at least this frame's need within `reach` - never below it.
    const sigma: f32 = float(reach) / 3.0;
    for (0..n) |frame| {
        var sum: f32 = 0.0;
        var weight: f32 = 0.0;
        const from: usize = frame -| reach;
        const to: usize = @min(n, frame + reach + 1);
        for (from..to) |other| {
            const d: f32 = float(other) - float(frame);
            const w: f32 = exp(-0.5 * d * d / (sigma * sigma));
            sum += w * wide[other];
            weight += w;
        }
        capture.lift[frame] = @max(need[frame], sum / weight);
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    unloadMesh(gpa, s);
    unloadCapture(gpa, s.captures[1]);
    unloadCapture(gpa, s.captures[0]);
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    const capture: *Capture = &s.captures[s.which];
    const frames: f32 = float(capture.frames());
    if (s.playing) {
        // The captures run at 60 frames a second, which is also what the page aims for.
        const dt: f32 = if (f.time.delta_time > 0 and f.time.delta_time < 0.2) f.time.delta_time else 0.0;
        s.frame += dt * 60.0;
        if (s.frame >= frames) {
            s.frame = 0;
        }
    }
    const shown: usize = @trunc(clamp(s.frame, 0.0, frames - 1.0));
    d3.bvhForwardKinematics(capture.clip, shown, capture.positions, capture.rotations);
    // Raise the whole character by this frame's planned lift: positions are in the capture's
    // centimetres, so the lift goes in as centimetres too.
    const raise: f32 = capture.lift[shown] / cm;
    for (capture.positions) |*p| {
        p.*[1] += raise;
    }

    z.clearViewport(f, bg);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 10.0 });
    const gl = f.gl;
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.25);
    s.transform[0] = mulMat(translation(0, -0.1, 0), scaling(16, 0.2, 16));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_col);
    if (s.show_shapes) {
        drawShapes(s, gl, capture);
    }
    if (s.show_bones) {
        drawBones(gl, capture);
    }
    // Last, so that when it is see-through everything else is already there to be seen through it.
    if (s.show_mesh) {
        drawMesh(s, gl, capture);
    }
    z.endMode3D(gl);
}

/// Every fitted shape, carried by its bone: the bone's place and turn this frame, applied to where the
/// shape sat on that bone in the bind pose.
fn drawShapes(s: *State, gl: *z.WgpuGl, capture: *const Capture) void {
    for (s.placed, 0..) |shape, g| {
        const bone: i32 = capture.bone_of[g];
        if (bone < 0) {
            continue;
        }
        const at: Vec = capture.positions[@intCast(bone)] * splat(cm);
        const turn: Quat = capture.rotations[@intCast(bone)];
        switch (shape.shape) {
            .capsule => {
                const a: Vec = at + rotate(turn, shape.a);
                const b: Vec = at + rotate(turn, shape.b);
                const along: Vec = b - a;
                const span: f32 = length3(along);
                // The cylinder mesh runs up its own y axis from 0 to 1: stand it along the capsule.
                const upright: Quat = if (span > 1.0e-6)
                    quatFromTo(vec(0, 1, 0), along * splat(1.0 / span))
                else
                    zm.qidentity();
                s.transform[0] = mulMat(
                    mulMat(translation(a[0], a[1], a[2]), quatToMat(upright)),
                    scaling(shape.radius, span, shape.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, capsule_col);
                // And the rounded ends that make it a capsule.
                for ([_]Vec{ a, b }) |end| {
                    const ball: Mat = scaling(shape.radius, shape.radius, shape.radius);
                    s.transform[0] = mulMat(translation(end[0], end[1], end[2]), ball);
                    z.drawMeshInstanced(gl, &s.sphere, &s.transform, capsule_col);
                }
            },
            .box => {
                const centre: Vec = at + rotate(turn, shape.a);
                const facing: Quat = qmul(turn, shape.rotation);
                const size: Vec = shape.half * splat(2.0);
                s.transform[0] = mulMat(
                    mulMat(translation(centre[0], centre[1], centre[2]), quatToMat(facing)),
                    scaling(size[0], size[1], size[2]),
                );
                z.drawMeshInstanced(gl, &s.cube, &s.transform, box_col);
            },
        }
    }
}

/// The capture's own skeleton - a line from every joint to its parent - drawn over the shapes, so a
/// shape that has slid off its bone is easy to see.
fn drawBones(gl: *z.WgpuGl, capture: *const Capture) void {
    for (0..capture.clip.boneCount()) |i| {
        const parent: i32 = capture.clip.skeleton.bones[i].parent;
        if (parent < 0) {
            continue;
        }
        const here: Vec = capture.positions[i] * splat(cm);
        const up: Vec = capture.positions[@intCast(parent)] * splat(cm);
        z.drawLine3D(gl, here, up, bone_col);
    }
}

fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const captured: bool = u.wantCaptureMouse();
    const placement: ui.WindowOpts = .{ .initial_pos = .{ 4, 4 }, .initial_size = .{ 330, 220 } };
    if (u.window("Geno's body, on the captures", placement)) |window| {
        defer window.close();
        const capture: *const Capture = &s.captures[s.which];
        const frames: f32 = float(capture.frames());
        if (u.button(if (s.which == 0) "get-up (tap for the dance)" else "dance (tap for the get-up)", .{})) {
            s.which = 1 - s.which;
            s.frame = 0;
        }
        u.text("frame {d} of {d}", .{ int(usize, s.frame), capture.frames() });
        _ = u.slider("frame", &s.frame, .{ .min = 0.0, .max = frames - 1.0, .fmt = "{d:.0}" });
        _ = u.checkbox("play", &s.playing);
        u.sameLine(.{});
        _ = u.checkbox("shapes", &s.show_shapes);
        u.sameLine(.{});
        _ = u.checkbox("bones", &s.show_bones);
        if (u.button("<", .{})) {
            s.frame = @max(0.0, s.frame - 1.0);
            s.playing = false;
        }
        u.sameLine(.{});
        if (u.button(">", .{})) {
            s.frame = @min(frames - 1.0, s.frame + 1.0);
            s.playing = false;
        }
        u.sameLine(.{});
        _ = u.checkbox("mesh", &s.show_mesh);
        u.text("{d} shapes: blue capsules, green boxes", .{fitted.geoms.len});
        u.text("with the shapes on, the mesh is see-through", .{});
    }
    return captured;
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Geno's body, on the captures",
            .width = 960,
            .height = 540,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
