//! examples/getup_frames - the get-up REFERENCE on the robot, one frame at a time.
//!
//! WHAT THIS IS FOR
//!
//! The tracking pages ask a physical character to follow this clip. Nothing can follow a pose the
//! robot could not hold in the first place, so before blaming a servo or a policy it is worth
//! looking at what they are being asked to do. This page poses the robot at a frame of the
//! retargeted clip - no physics, no learning, just the reference - and says, for that frame:
//!
//!   * how far each foot's lowest point is from the floor (below zero means through it),
//!   * how far each SOLE is from flat, measured from the foot to its own toe,
//!   * and which part of the body is lowest, since the clip is lifted so that part just clears
//!     the floor.
//!
//! A foot that is down and flat can carry weight. A foot that is down and tilted is the character
//! standing on an edge: the reference is asking for something the robot cannot do, and every
//! tracker built on top of it inherits that.
//!
//! The clip is the BAKED one the training pages use (`zig build clip-bake`), so what is drawn here
//! is exactly what they train against - not a fresh retarget that might differ.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui;
const rbt = z.robot;
const rmj = z.robot_mjcf;
const mjcf = z.mjcf;
const codecs = z.codecs;
const dance = z.robot_dance;
const d3 = z.draw3d;

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
const mulMat = zm.mulMat;
const qmul = zm.qmul;
const quatToMat = zm.quatToMat;
const translation = zm.translation;
const scaling = zm.scaling;
const splat = zm.splat;
const rotate = zm.rotate;
const length3 = zm.length3;
const asinRad = zm.asinRad;
const deg_per_rad = zm.deg_per_rad;

const humanoid_xml = @embedFile("humanoid_flex2.xml");
const getup_zclip = @embedFile("getup.zclip");
/// The capture the clip was retargeted FROM, so the two can be compared frame for frame. The baked
/// clip is frames 540..839 of it (`robot_clip_bake`'s get-up job), which is the whole alignment.
const getup_bvh = @embedFile("fallAndGetUp2_subject2.bvh");
const capture_first: usize = 540;
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const bg: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 };
const ref_col: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 };
const ground_col: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 };
const flat_col: Color = .{ .r = 110, .g = 200, .b = 130, .a = 255 };
const tilted_col: Color = .{ .r = 230, .g = 130, .b = 90, .a = 255 };
const capture_col: Color = .{ .r = 200, .g = 200, .b = 120, .a = 255 };

/// A foot counts as DOWN when its lowest point is within this of the floor.
const down_height: f32 = 0.01;
/// And as FLAT when its sole is within this of horizontal. Beyond it, the character is standing on
/// an edge - which is what this page was built to make visible.
const flat_degrees: f32 = 10.0;

/// What one foot is doing on one frame.
const Foot = struct {
    /// Its lowest point's height above the floor; negative means through it.
    height: f32,
    /// How far its sole is from flat, in degrees.
    tilt: f32,
    /// Where to draw the marker: the foot's own position.
    at: Vec,

    fn down(self: Foot) bool {
        return self.height <= down_height;
    }

    fn flat(self: Foot) bool {
        return self.tilt <= flat_degrees;
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

    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    clip: dance.Clip,
    data: rbt.Data,
    /// The capture itself: its skeleton, and where every joint of it sits on the frame on show.
    capture: d3.BvhSkeletalClip,
    capture_pos: []Vec,
    capture_rot: []Quat,
    /// Centimetres to metres, and a step sideways so the two stand beside each other.
    capture_scale: f32 = 0.01,
    capture_shift: f32 = 1.0,
    show_capture: bool = true,
    /// The capture's own sole angles, measured exactly as the robot's are.
    capture_left: f32 = 0,
    capture_right: f32 = 0,

    /// The frame on show, as a float so the slider can scrub it smoothly.
    frame: f32 = 0,
    playing: bool = false,
    /// Frames a second while playing - the clip's own rate, or slower to study it.
    rate: f32 = 30.0,
    show_markers: bool = true,
    left: Foot = .{ .height = 0, .tilt = 0, .at = zm.vec(0, 0, 0) },
    right: Foot = .{ .height = 0, .tilt = 0, .at = zm.vec(0, 0, 0) },
    /// The lowest point of the WHOLE body, and whether a foot is the thing reaching it.
    body_low: f32 = 0,
    feet_deepest: bool = false,
    /// How many of the clip's frames have a foot down but not flat.
    edge_frames: usize = 0,
    down_frames: usize = 0,
};

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 16),
        .ui_host = undefined,
        .cam = z.OrbitCamera.init(vec(0.0, 0.7, 0), 3.0),
        .cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0),
        .sphere = try z.genMeshSphere(gpa, 1.0, 10, 8),
        .cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2),
        .transform = .{zm.identity()},
        .doc = undefined,
        .robot = undefined,
        .imported = undefined,
        .clip = undefined,
        .data = undefined,
        .capture = undefined,
        .capture_pos = undefined,
        .capture_rot = undefined,
    };
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.doc = try codecs.xml.parse(gpa, humanoid_xml, null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    var options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81) };
    options.solver.algorithm = .newton;
    s.imported = try rmj.build(gpa, &s.robot, options);
    s.clip = try dance.Clip.fromBytes(gpa, getup_zclip);
    var capture_data: codecs.bvh.Data = try codecs.bvh.parse(gpa, getup_bvh, null);
    defer capture_data.deinit();
    s.capture = try d3.loadBvhSkeletalClip(gpa, capture_data);
    s.capture_pos = try gpa.alloc(Vec, s.capture.boneCount());
    s.capture_rot = try gpa.alloc(Quat, s.capture.boneCount());
    s.data = try rbt.Data.init(gpa, &s.imported.model);
    // The whole clip counted once, so the panel can say how much of it stands on an edge.
    countEdges(s);
    poseAt(s, 0);
}

fn deinit(gpa: Allocator, s: *State) void {
    gpa.free(s.capture_rot);
    gpa.free(s.capture_pos);
    d3.unloadBvhSkeletalClip(gpa, s.capture);
    s.data.deinit();
    s.clip.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// Pose the robot at a frame and work out what its feet are doing there.
fn poseAt(s: *State, frame: usize) void {
    const m: *const rbt.Model = &s.imported.model;
    const at: usize = @min(frame, s.clip.frame_count - 1);
    @memcpy(s.data.pos, s.clip.pose(at));
    s.data.stage = .stale;
    rbt.kinematics(m, &s.data);
    s.left = footAt(s, "foot_left", "toe_left");
    s.right = footAt(s, "foot_right", "toe_right");
    s.body_low = dance.lowestBodyPoint(m, &s.data);
    s.feet_deepest = @min(s.left.height, s.right.height) - s.body_low < 0.005;
    captureAt(s, at);
}

/// The capture posed on the same moment: clip frame `at` is capture frame `capture_first + at`. Its
/// own soles are measured the same way the robot's are - ankle to toe - so the two angles answer the
/// same question, and the difference between them is what retargeting did.
fn captureAt(s: *State, at: usize) void {
    const frames: usize = @intCast(@max(s.capture.animation.keyframeCount, 1));
    const frame: usize = @min(capture_first + at, frames - 1);
    d3.bvhForwardKinematics(s.capture, frame, s.capture_pos, s.capture_rot);
    s.capture_left = captureSole(s, "LeftFoot", "LeftToe");
    s.capture_right = captureSole(s, "RightFoot", "RightToe");
}

/// The angle a capture's sole makes with the floor: the capture stands in its own units and its own
/// up-axis (y), so only the direction matters here, not the scale.
fn captureSole(s: *State, foot: []const u8, toe: []const u8) f32 {
    const a: usize = captureBone(s, foot) orelse return 0.0;
    const b: usize = captureBone(s, toe) orelse return 0.0;
    const along: Vec = s.capture_pos[b] - s.capture_pos[a];
    const span: f32 = length3(along);
    if (span < 1.0e-6) {
        return 0.0;
    }
    return @abs(asinRad(clamp(along[1] / span, -1.0, 1.0))) * deg_per_rad;
}

/// A capture bone whose name contains `want` - captures disagree about punctuation and case, so a
/// substring is the only match that survives a different file.
fn captureBone(s: *State, want: []const u8) ?usize {
    for (0..s.capture.boneCount()) |i| {
        if (std.mem.indexOf(u8, s.capture.boneName(i), want) != null) {
            return i;
        }
    }
    return null;
}

/// One foot's height and tilt. A foot here is TWO bodies - the foot and its toe - and the toe is
/// usually the lower of them, so both go into the height; and the line from one to the other lies
/// along the sole, which is what makes the tilt measurable without assuming which way any axis
/// points.
fn footAt(s: *State, foot_name: []const u8, toe_name: []const u8) Foot {
    const m: *const rbt.Model = &s.imported.model;
    const names: []const []const u8 = s.imported.names;
    const height: f32 = @min(
        dance.lowestGeomNamed(m, &s.data, names, foot_name),
        dance.lowestGeomNamed(m, &s.data, names, toe_name),
    );
    var tilt: f32 = 0.0;
    var at: Vec = vec(0, 0, 0);
    if (bodyNamed(names, foot_name)) |foot| {
        at = s.data.body_xpos[foot];
        if (bodyNamed(names, toe_name)) |toe| {
            const along: Vec = s.data.body_xpos[toe] - at;
            const span: f32 = length3(along);
            if (span > 1.0e-6) {
                tilt = @abs(asinRad(clamp(along[2] / span, -1.0, 1.0))) * deg_per_rad;
            }
        }
    }
    return .{ .height = height, .tilt = tilt, .at = at };
}

fn bodyNamed(names: []const []const u8, want: []const u8) ?usize {
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, want)) {
            return i;
        }
    }
    return null;
}

/// The whole clip, once: how many frames have a foot down, and how many of those have it tilted.
fn countEdges(s: *State) void {
    s.down_frames = 0;
    s.edge_frames = 0;
    for (0..s.clip.frame_count) |frame| {
        poseAt(s, frame);
        for ([_]Foot{ s.left, s.right }) |foot| {
            if (foot.down()) {
                s.down_frames += 1;
                if (!foot.flat()) {
                    s.edge_frames += 1;
                }
            }
        }
    }
}

fn update(f: *z.Frame, s: *State) void {
    const frames: f32 = float(s.clip.frame_count);
    if (s.playing) {
        const dt: f32 = if (f.time.delta_time > 0 and f.time.delta_time < 0.2) f.time.delta_time else 0.0;
        s.frame += dt * s.rate;
        if (s.frame >= frames) {
            s.frame = 0;
        }
    }
    poseAt(s, int(usize, clamp(s.frame, 0.0, frames - 1.0)));

    z.clearViewport(f, bg);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 8.0 });
    const gl = f.gl;
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.25);
    s.transform[0] = mulMat(mulMat(zm.zUpToYUp(), translation(0, 0, -0.5)), scaling(16, 16, 0.2));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_col);
    drawRobot(s, gl, &s.data, ref_col);
    if (s.show_capture) {
        drawCapture(s, gl);
    }
    if (s.show_markers) {
        // A disc under each foot that is DOWN: green when the sole is flat enough to carry weight,
        // orange when the character is standing on an edge.
        for ([_]Foot{ s.left, s.right }) |foot| {
            if (!foot.down()) {
                continue;
            }
            const place: Mat = mulMat(zm.zUpToYUp(), translation(foot.at[0], foot.at[1], 0.005));
            s.transform[0] = mulMat(place, scaling(0.16, 0.16, 0.01));
            z.drawMeshInstanced(gl, &s.cube, &s.transform, if (foot.flat()) flat_col else tilted_col);
        }
    }
    z.endMode3D(gl);
}

/// The capture's skeleton, a step to the side: a dot at every joint and a line to its parent. In its
/// own units (centimetres) and its own up-axis, which the world already uses for drawing.
fn drawCapture(s: *State, gl: *z.WgpuGl) void {
    const shift: Vec = vec(s.capture_shift, 0, 0);
    for (0..s.capture.boneCount()) |i| {
        const here: Vec = s.capture_pos[i] * splat(s.capture_scale) + shift;
        z.drawSphereWires(gl, here, .{ .radius = 0.012, .rings = 4, .slices = 6, .color = capture_col });
        const parent: i32 = s.capture.skeleton.bones[i].parent;
        if (parent >= 0) {
            const up: Vec = s.capture_pos[@intCast(parent)] * splat(s.capture_scale) + shift;
            z.drawLine3D(gl, here, up, capture_col);
        }
    }
}

fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const captured: bool = u.wantCaptureMouse();
    if (u.window("the get-up reference, frame by frame", .{
        .initial_pos = .{ 4, 4 },
        .initial_size = .{ 350, 250 },
    })) |window| {
        defer window.close();
        const frames: f32 = float(s.clip.frame_count);
        u.text("frame {d} of {d}", .{ int(usize, s.frame), s.clip.frame_count });
        _ = u.slider("frame", &s.frame, .{ .min = 0.0, .max = frames - 1.0, .fmt = "{d:.0}" });
        _ = u.checkbox("play", &s.playing);
        u.sameLine(.{});
        _ = u.checkbox("markers", &s.show_markers);
        if (u.button("<", .{})) {
            s.frame = @max(0.0, s.frame - 1.0);
            s.playing = false;
        }
        u.sameLine(.{});
        if (u.button(">", .{})) {
            s.frame = @min(frames - 1.0, s.frame + 1.0);
            s.playing = false;
        }
        // Per foot: how far off the floor, and how far off flat. "on an edge" is the case that makes
        // a reference impossible to stand on.
        for ([_]struct { []const u8, Foot }{ .{ "left ", s.left }, .{ "right", s.right } }) |pair| {
            const foot: Foot = pair[1];
            const state: []const u8 = if (!foot.down())
                "in the air"
            else if (foot.flat())
                "down, flat"
            else
                "down, ON AN EDGE";
            u.text("{s}: {d:.3} m, sole {d:.1} deg - {s}", .{ pair[0], foot.height, foot.tilt, state });
        }
        u.text("lowest point of the body: {d:.3} m{s}", .{
            s.body_low,
            if (s.feet_deepest) " (a foot)" else " (not a foot)",
        });
        // The clip as a whole, counted once at startup.
        const share: f32 = if (s.down_frames == 0) 0.0 else 100.0 * float(s.edge_frames) / float(s.down_frames);
        u.text("over the clip: {d} foot-frames down, {d:.0}% of them on an edge", .{ s.down_frames, share });
        _ = u.checkbox("capture", &s.show_capture);
        // The same question asked of the source motion. A capture that is flat here while the robot is
        // not says the retarget (or the ankle's range) lost it; tilted in both says the motion is.
        u.text("capture soles: left {d:.1} deg, right {d:.1} deg", .{ s.capture_left, s.capture_right });
    }
    return captured;
}

fn drawRobot(s: *State, gl: *z.WgpuGl, d: *const rbt.Data, tint: Color) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        const body_rot: Quat = d.body_xrot[body];
        const world_pos: Vec = d.body_xpos[body] + rotate(body_rot, m.geom_pos[g]);
        const world_rot: Mat = quatToMat(qmul(body_rot, m.geom_rot[g]));
        const place: Mat = mulMat(
            mulMat(to_y_up, translation(world_pos[0], world_pos[1], world_pos[2])),
            world_rot,
        );
        switch (m.geom_shape[g]) {
            .sphere => |sph| {
                s.transform[0] = mulMat(place, scaling(sph.radius, sph.radius, sph.radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            },
            .box => |b| {
                const size: Vec = b.half_extent * splat(2.0);
                s.transform[0] = mulMat(place, scaling(size[0], size[1], size[2]));
                z.drawMeshInstanced(gl, &s.cube, &s.transform, tint);
            },
            .capsule => |cap| {
                s.transform[0] = mulMat(
                    mulMat(place, translation(0, -cap.half_height, 0)),
                    scaling(cap.radius, 2.0 * cap.half_height, cap.radius),
                );
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            },
            else => {},
        }
    }
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - the get-up reference, frame by frame",
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
