//! examples/geno_mirror - Geno's clips and their mirror images, side by side on the symmetric robot.
//!
//! WHAT YOU ARE LOOKING AT
//!
//! The robot every training run uses - Geno, built from its own skeleton and mesh and made symmetric, each body its
//! partner's mirror image - posed frame by frame by a baked clip, and beside it by the same clip mirrored left for
//! right. No physics and no learning: these are the references the trainer embeds, exactly as it reads them.
//!
//! A mirrored clip is made where the motion is still the capture's: every joint takes its partner's motion, reflected
//! across a vertical plane and turned by one fixed correction per joint, and is then copied onto the robot like any
//! capture, cut and rested on the floor. On a symmetric body the result is the original's mirror image, body for body
//! and sole for sole. Two views ask that question by eye:
//!
//!   * the MIRROR PAIR: the original on one side of the mirror plane, the mirrored clip on the other - each the
//!     other's reflection, the left hand's motion now the right hand's;
//!   * REFLECTED BACK: the mirrored clip's skeleton reflected across the plane again and drawn over the original's -
//!     where the mirror is right, the two skeletons are one.
//!
//! The panel says the same in numbers, frame by frame: each sole's height in both clips (the mirrored left is the
//! original right), and how far the mirrored clip's farthest body lies from where its partner was, reflected.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui;
const rbt = z.robot;
const rmj = z.robot_mjcf;
const mjcf = z.mjcf;
const codecs = z.codecs;
const dance = z.robot_dance;

const Allocator = std.mem.Allocator;
const eql = std.mem.eql;
const startsWith = std.mem.startsWith;
const bufPrint = std.fmt.bufPrint;
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
const floatMax = zm.floatMax;

const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

/// The four clips of the minute and their mirror images, baked beside each other (`examples/geno_ppo/*.zclip`).
const ClipPair = struct { label: []const u8, original: []const u8, mirrored: []const u8 };

const clip_pairs = [_]ClipPair{
    .{
        .label = "dance",
        .original = @embedFile("geno_dance_zclip"),
        .mirrored = @embedFile("geno_dance_mirrored_zclip"),
    },
    .{
        .label = "get-up",
        .original = @embedFile("geno_getup_zclip"),
        .mirrored = @embedFile("geno_getup_mirrored_zclip"),
    },
    .{
        .label = "walk",
        .original = @embedFile("geno_walk_zclip"),
        .mirrored = @embedFile("geno_walk_mirrored_zclip"),
    },
    .{
        .label = "run",
        .original = @embedFile("geno_run_zclip"),
        .mirrored = @embedFile("geno_run_mirrored_zclip"),
    },
};

/// The page's colours.
const Palette = struct {
    background: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 },
    ground: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 },
    mirror: Color = .{ .r = 150, .g = 160, .b = 185, .a = 255 },
    original: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 },
    mirrored: Color = .{ .r = 230, .g = 150, .b = 90, .a = 255 },
    sole_down: Color = .{ .r = 110, .g = 200, .b = 130, .a = 255 },
};

/// How the page lays the two clips out.
const Layout = struct {
    /// How close to the mirror plane the original's root comes, so the pair never overlaps.
    least_gap_m: f32 = 0.45,
    /// A sole counts as down within this of the floor.
    down_height_m: f32 = 0.01,
    /// Joint dots of the skeletons, in metres.
    joint_radius_m: f32 = 0.018,
    /// How far the camera's target sits to the pair's left, so the panel does not cover it.
    view_shift_m: f32 = 0.6,
};

/// Which way the page shows the pair.
const View = enum(i32) { mirror_pair = 0, reflected_back = 1 };

/// One clip on the robot: its frames and the pose on show.
const Posed = struct {
    clip: dance.Clip,
    data: rbt.Data,
};

/// What one sole is doing on the frame on show.
const Sole = struct {
    /// Its lowest point's height above the floor; negative means through it.
    height: f32 = 0,
    /// Where to draw its marker: the foot's own place.
    at: Vec = vec(0, 0, 0),
};

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    cube: z.Mesh,
    sphere: z.Mesh,
    transform: [1]Mat,
    palette: Palette = .{},
    layout: Layout = .{},

    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    /// Each body's partner across the body: its `Left` and `Right` swapped, a body on the midline its own.
    partners: []u32,
    lowest_points: []f32,
    original: Posed,
    mirrored: Posed,
    /// The clip on show, an index into `clip_pairs`.
    clip_index: i32 = 0,
    loaded_clip: i32 = -1,
    /// How far the pair stands from the mirror plane: the original moved this far along x, the mirrored clip as far
    /// the other way, so the two stay each other's reflection.
    offset_m: f32 = 0,

    /// The frame on show, as a float so the slider can scrub it smoothly.
    frame: f32 = 0,
    playing: bool = true,
    /// Frames a second while playing - the clips' own 60, or slower to study them.
    rate: f32 = 60.0,
    view: i32 = @backingInt(View.mirror_pair),
    follow: bool = true,
    show_soles: bool = true,

    original_left: Sole = .{},
    original_right: Sole = .{},
    mirrored_left: Sole = .{},
    mirrored_right: Sole = .{},
    /// How far the mirrored clip's farthest body lies from where its partner was in the original, reflected - and
    /// the most over the whole clip, measured when it loads.
    frame_gap_m: f32 = 0,
    clip_gap_m: f32 = 0,
};

/// A place across the mirror plane, x = 0 of the robot's z-up world: x to -x.
fn acrossTheMirror(place: Vec) Vec {
    return vec(-place[0], place[1], place[2]);
}

/// A place of the robot's z-up world where the drawing, y up, puts it: (x, y, z) to (x, z, -y), as `zUpToYUp` turns.
fn drawn(place: Vec) Vec {
    return vec(place[0], place[2], -place[1]);
}

fn bodyNamed(names: []const []const u8, want: []const u8) ?u32 {
    for (names, 0..) |name, index| {
        if (eql(u8, name, want)) {
            return @intCast(index);
        }
    }
    return null;
}

/// A body's partner across the body: `Left...` for `Right...` and back, a body on the midline its own.
fn partnerOf(names: []const []const u8, body: u32) u32 {
    const name: []const u8 = names[body];
    var swapped: [64]u8 = undefined;
    const partner_name: []const u8 = if (startsWith(u8, name, "Left"))
        bufPrint(&swapped, "Right{s}", .{name["Left".len..]}) catch return body
    else if (startsWith(u8, name, "Right"))
        bufPrint(&swapped, "Left{s}", .{name["Right".len..]}) catch return body
    else
        return body;
    return bodyNamed(names, partner_name) orelse body;
}

/// One sole on the posed robot: the lowest point of its foot and its toe, and the foot's place.
fn soleOf(
    s: *const State,
    data: *const rbt.Data,
    foot_name: []const u8,
    toe_name: []const u8,
) Sole {
    const names: []const []const u8 = s.imported.names;
    const foot: u32 = bodyNamed(names, foot_name) orelse return .{};
    const toe: u32 = bodyNamed(names, toe_name) orelse return .{};
    return .{
        .height = @min(s.lowest_points[foot], s.lowest_points[toe]),
        .at = data.body_positions[foot],
    };
}

/// Both clips posed at a frame.
fn poseAt(s: *State, frame: usize) void {
    const model: *const rbt.Model = &s.imported.model;
    for ([2]*Posed{ &s.original, &s.mirrored }) |posed| {
        const at: usize = @min(frame, posed.clip.frame_count - 1);
        @memcpy(posed.data.joint_positions, posed.clip.pose(at));
        posed.data.stage = .stale;
        rbt.kinematics(model, &posed.data);
    }
}

/// How far the mirrored clip's farthest body lies from where its partner was in the original, reflected.
fn mirrorGap(s: *const State) f32 {
    var worst: f32 = 0;
    for (1..s.imported.model.body_count) |body| {
        const partner: u32 = s.partners[body];
        const expected: Vec = acrossTheMirror(s.original.data.body_positions[partner]);
        worst = @max(worst, length3(s.mirrored.data.body_positions[body] - expected));
    }
    return worst;
}

/// The frame on show: both clips posed, their soles, and the gap between the mirrored clip and the original's
/// reflection.
fn showFrame(s: *State, frame: usize) void {
    poseAt(s, frame);
    const model: *const rbt.Model = &s.imported.model;
    rbt.bodyLowestPoints(model, &s.original.data, s.lowest_points);
    s.original_left = soleOf(s, &s.original.data, "LeftFoot", "LeftToeBase");
    s.original_right = soleOf(s, &s.original.data, "RightFoot", "RightToeBase");
    rbt.bodyLowestPoints(model, &s.mirrored.data, s.lowest_points);
    s.mirrored_left = soleOf(s, &s.mirrored.data, "LeftFoot", "LeftToeBase");
    s.mirrored_right = soleOf(s, &s.mirrored.data, "RightFoot", "RightToeBase");
    s.frame_gap_m = mirrorGap(s);
}

/// Load the pair at `clip_pairs[index]`: both clips, the offset that keeps the pair apart, and the gap over the clip.
fn loadPair(s: *State, index: usize) !void {
    if (s.loaded_clip >= 0) {
        s.original.clip.deinit();
        s.mirrored.clip.deinit();
    }
    s.original.clip = try dance.Clip.fromBytes(s.gpa, clip_pairs[index].original);
    s.mirrored.clip = try dance.Clip.fromBytes(s.gpa, clip_pairs[index].mirrored);
    s.loaded_clip = @intCast(index);
    // The original's root comes no closer to the plane than `least_gap_m`, and the mirrored clip's no closer from
    // the other side: the same shift, mirrored.
    var least_x: f32 = floatMax(f32);
    for (0..s.original.clip.frame_count) |frame| {
        least_x = @min(least_x, s.original.clip.pose(frame)[0]);
    }
    s.offset_m = s.layout.least_gap_m - least_x;
    s.clip_gap_m = 0;
    for (0..s.original.clip.frame_count) |frame| {
        poseAt(s, frame);
        s.clip_gap_m = @max(s.clip_gap_m, mirrorGap(s));
    }
    s.frame = 0;
    showFrame(s, 0);
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 16),
        .ui_host = undefined,
        .cam = z.OrbitCamera.init(vec(0.0, 0.9, 0), 4.2),
        .cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0),
        .sphere = try z.genMeshSphere(gpa, 1.0, 10, 8),
        .transform = .{zm.identity()},
        .doc = undefined,
        .robot = undefined,
        .imported = undefined,
        .partners = undefined,
        .lowest_points = undefined,
        .original = undefined,
        .mirrored = undefined,
    };
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cam.yaw = 0.0;
    s.cam.pitch = 0.25;
    s.doc = try codecs.xml.parse(gpa, z.robot_geno_model, null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    const options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81) };
    s.imported = try rmj.build(gpa, &s.robot, options);
    const model: *const rbt.Model = &s.imported.model;
    s.partners = try gpa.alloc(u32, model.body_count);
    for (s.partners, 0..) |*partner, body| {
        partner.* = partnerOf(s.imported.names, @intCast(body));
    }
    s.lowest_points = try gpa.alloc(f32, model.body_count);
    s.original.data = try rbt.Data.init(gpa, model);
    s.mirrored.data = try rbt.Data.init(gpa, model);
    try loadPair(s, 0);
}

fn deinit(gpa: Allocator, s: *State) void {
    if (s.loaded_clip >= 0) {
        s.original.clip.deinit();
        s.mirrored.clip.deinit();
    }
    s.mirrored.data.deinit();
    s.original.data.deinit();
    gpa.free(s.lowest_points);
    gpa.free(s.partners);
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const captured: bool = u.wantCaptureMouse();
    if (u.window("Geno's clips, mirrored", .{
        .initial_pos = .{ 4, 4 },
        .initial_size = .{ 390, 340 },
    })) |window| {
        defer window.close();
        for (clip_pairs, 0..) |pair, index| {
            if (index > 0) {
                u.sameLine(.{});
            }
            _ = u.radioButton(pair.label, &s.clip_index, @intCast(index));
        }
        const frames: f32 = float(s.original.clip.frame_count);
        u.text("frame {d} of {d}", .{ int(usize, s.frame), s.original.clip.frame_count });
        _ = u.slider("frame", &s.frame, .{ .min = 0.0, .max = frames - 1.0, .fmt = "{d:.0}" });
        _ = u.slider("frames a second", &s.rate, .{ .min = 2.0, .max = 60.0, .fmt = "{d:.0}" });
        _ = u.checkbox("play", &s.playing);
        u.sameLine(.{});
        _ = u.checkbox("follow", &s.follow);
        u.sameLine(.{});
        _ = u.checkbox("soles", &s.show_soles);
        if (u.button("<", .{})) {
            s.frame = @max(0.0, s.frame - 1.0);
            s.playing = false;
        }
        u.sameLine(.{});
        if (u.button(">", .{})) {
            s.frame = @min(frames - 1.0, s.frame + 1.0);
            s.playing = false;
        }
        _ = u.radioButton("mirror pair", &s.view, @backingInt(View.mirror_pair));
        u.sameLine(.{});
        _ = u.radioButton("reflected back", &s.view, @backingInt(View.reflected_back));
        // The mirrored left sole is the original right's, and the other way.
        u.text("soles (m)    original    mirrored", .{});
        u.text("  left       {d:8.4}    {d:8.4}", .{ s.original_left.height, s.mirrored_left.height });
        u.text("  right      {d:8.4}    {d:8.4}", .{ s.original_right.height, s.mirrored_right.height });
        // How far the mirrored clip's farthest body lies from where its partner was, reflected.
        u.text("mirror gap: {e:.1} m (the clip: {e:.1} m)", .{ s.frame_gap_m, s.clip_gap_m });
    }
    return captured;
}

/// The robot's shapes on a posed clip, moved `shift` along x - each shape where its body puts it.
fn drawRobot(
    s: *State,
    gl: *z.WgpuGl,
    data: *const rbt.Data,
    shift: Vec,
    tint: Color,
) void {
    const model: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..model.geom_count) |geom| {
        const body: u32 = model.geom_body[geom];
        if (body == 0) {
            continue;
        }
        const body_turn: Quat = data.body_orientations[body];
        const centre: Vec = data.body_positions[body] + rotate(body_turn, model.geom_local_position[geom]) + shift;
        const geom_turn: Quat = qmul(body_turn, model.geom_local_rotation[geom]);
        const place: Mat = mulMat(mulMat(to_y_up, translation(centre[0], centre[1], centre[2])), quatToMat(geom_turn));
        switch (model.geom_shape[geom]) {
            .sphere => |sphere| {
                s.transform[0] = mulMat(place, scaling(sphere.radius, sphere.radius, sphere.radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            },
            .box => |box| {
                const size: Vec = box.half_extent * splat(2.0);
                s.transform[0] = mulMat(place, scaling(size[0], size[1], size[2]));
                z.drawMeshInstanced(gl, &s.cube, &s.transform, tint);
            },
            .capsule => |capsule| {
                // A capsule lies along its own y: its segment's two ends, drawn y up.
                const half_axis: Vec = rotate(geom_turn, vec(0, capsule.half_height, 0));
                const start: Vec = drawn(centre - half_axis);
                const end: Vec = drawn(centre + half_axis);
                z.drawCapsule(gl, start, end, capsule.radius, 12, 6, tint);
            },
            else => {},
        }
    }
}

/// A posed clip's skeleton: a dot at every body and a line to its parent, each place through `placed`.
fn drawSkeleton(
    s: *State,
    gl: *z.WgpuGl,
    data: *const rbt.Data,
    placed: *const fn (Vec) Vec,
    tint: Color,
) void {
    const model: *const rbt.Model = &s.imported.model;
    for (1..model.body_count) |body| {
        const here: Vec = drawn(placed(data.body_positions[body]));
        z.drawSphereWires(gl, here, .{ .radius = s.layout.joint_radius_m, .rings = 4, .slices = 6, .color = tint });
        const parent: u32 = model.body_parent[body];
        if (parent == 0) {
            continue;
        }
        z.drawLine3D(gl, here, drawn(placed(data.body_positions[parent])), tint);
    }
}

fn unchanged(place: Vec) Vec {
    return place;
}

/// A sole that is down: a flat marker under its foot.
fn drawSole(s: *State, gl: *z.WgpuGl, sole: Sole, shift: Vec) void {
    if (sole.height > s.layout.down_height_m) {
        return;
    }
    const at: Vec = sole.at + shift;
    const place: Mat = mulMat(zm.zUpToYUp(), translation(at[0], at[1], 0.004));
    s.transform[0] = mulMat(place, scaling(0.16, 0.16, 0.008));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, s.palette.sole_down);
}

fn update(f: *z.Frame, s: *State) void {
    if (s.clip_index != s.loaded_clip) {
        const index: usize = @intCast(s.clip_index);
        loadPair(s, index) catch {
            s.clip_index = s.loaded_clip;
        };
    }
    const frames: f32 = float(s.original.clip.frame_count);
    if (s.playing) {
        const usable_delta: bool = f.time.delta_time > 0 and f.time.delta_time < 0.2;
        const dt: f32 = if (usable_delta) f.time.delta_time else 0.0;
        s.frame += dt * s.rate;
        if (s.frame >= frames) {
            s.frame = 0;
        }
    }
    showFrame(s, int(usize, clamp(s.frame, 0.0, frames - 1.0)));

    z.clearViewport(f, s.palette.background);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    const view: View = @fromBackingInt(@intCast(s.view));
    if (s.follow) {
        // Side by side, the pair's middle is on the mirror plane: follow the original's root along it. Reflected
        // back, follow the original's root itself.
        const root: Vec = s.original.data.body_positions[1];
        const across: f32 = if (view == .mirror_pair) 0 else root[0];
        s.cam.target = drawn(vec(across - s.layout.view_shift_m, root[1], 0.9));
    }
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.0, .max_distance = 12.0 });
    const gl = f.gl;
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 40, 0.25);
    s.transform[0] = mulMat(mulMat(zm.zUpToYUp(), translation(0, 0, -0.5)), scaling(30, 30, 0.2));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, s.palette.ground);
    switch (view) {
        .mirror_pair => {
            // The original moved off the plane one way, the mirrored clip as far the other: each the other's
            // reflection, and the plane between them drawn as a line on the floor.
            const shift: Vec = vec(s.offset_m, 0, 0);
            const mirrored_shift: Vec = vec(-s.offset_m, 0, 0);
            drawRobot(s, gl, &s.original.data, shift, s.palette.original);
            drawRobot(s, gl, &s.mirrored.data, mirrored_shift, s.palette.mirrored);
            const plane_half_length: f32 = 15.0;
            z.drawLine3D(gl, vec(0, 0.002, -plane_half_length), vec(0, 0.002, plane_half_length), s.palette.mirror);
            if (s.show_soles) {
                drawSole(s, gl, s.original_left, shift);
                drawSole(s, gl, s.original_right, shift);
                drawSole(s, gl, s.mirrored_left, mirrored_shift);
                drawSole(s, gl, s.mirrored_right, mirrored_shift);
            }
        },
        .reflected_back => {
            // Both skeletons where the original stands: the mirrored clip's reflected back across the plane, so
            // that a right mirror draws one skeleton.
            drawSkeleton(s, gl, &s.original.data, &unchanged, s.palette.original);
            drawSkeleton(s, gl, &s.mirrored.data, &acrossTheMirror, s.palette.mirrored);
        },
    }
    z.endMode3D(gl);
}

pub const app: z.AppSpec(State) = .{
    .config = .{
        .window = .{
            .title = "zimr - Geno's clips, mirrored",
            .width = 1100,
            .height = 640,
            .scale_mode = .responsive,
            .depth_format = .depth24_plus,
        },
    },
    .init = initState,
    .memory = .managed,
    .deinit = deinit,
    .update = update,
};
