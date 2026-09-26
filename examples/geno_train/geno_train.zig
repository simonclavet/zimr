//! examples/geno_train - SuperTrack on GENO, learned on the device you are holding.
//!
//! The same page as `track_train`, on the robot built from Geno's skeleton and mesh: standing armature on every
//! joint (in this servo a joint's strength is its free-flight inertia), self-collision off, every reset rested
//! on the floor, and an action reach of 0.6 rad per freedom (what the sampling teacher showed a policy needs).
//! The clip is the dance from 5 s to 15 s - the stretch where the servo alone falls within a second or so.
//!
//! WHAT THIS IS
//!
//! A humanoid, a motion capture it should follow, a servo driving it toward that capture, and a
//! policy that learns the corrections keeping it there - trained here, from nothing, on this device.
//! What separates this page from the PPO bench beside it is WHERE the work happens: the characters
//! are stepped on the CPU, and everything else stays on the GPU. The training data never comes back.
//!
//! Each round: the characters take some steps, each one appended to a ring on the GPU as a single
//! upload; then the world model trains through its own rollouts, and the policy trains through the
//! world model, on windows the GPU assembles itself out of that ring. Only two things cross back -
//! the policy's weights, so the simulation can act, and a handful of numbers for this panel.
//!
//! THE NUMBER THAT MATTERS: MEAN TIME TO FAILURE
//!
//! Characters start at random points of the clip, so an episode can never outlast what is left of
//! the clip - which makes "how long did episodes last" top out well below perfect. So the page counts
//! FAILURES - a character losing its reference - against the time characters were watched, and shows
//! the ratio: how long a character tracks, on average, before it loses the reference. Running out of
//! clip while still with it is survival, not failure.
//!
//! TRAIN ONLY
//!
//! Drawing costs both processors, and neither is spare here. The toggle stops drawing entirely and
//! gives the frame's whole budget to training. Progress is then reported in the two numbers that make
//! a phone's thermal throttling visible: training seconds, and the wall-clock seconds they took.

const std = @import("std");
const z = @import("zimr");
const zm = @import("zm");
const ui = z.ui;
const rbt = z.robot;
const rmj = z.robot_mjcf;
const mjcf = z.mjcf;
const codecs = z.codecs;
const dance = z.robot_dance;
const track = z.robot_track;
const latent = z.robot_latent;
const resident = z.robot_track_resident;
const zn_mlp = @import("zn_mlp");

const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const vec = zm.vec;
const float = zm.float;
const clamp = zm.clamp;
const int = zm.int;
const mulMat = zm.mulMat;
const Vec = zm.Vec;
const Mat = zm.Mat;
const Quat = zm.Quat;
const qmul = zm.qmul;
const quatToMat = zm.quatToMat;
const splat = zm.splat;
const translation = zm.translation;
const scaling = zm.scaling;

const geno = z.robot_geno;
const dance_zclip = @embedFile("dance.zclip");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const bg: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 };
const sim_col: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 };
const ref_col: Color = .{ .r = 86, .g = 92, .b = 104, .a = 255 };
const ground_col: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 };

/// Characters stepped together. Every one of them is another sample per step and another row the
/// ring carries, so this is the page's main dial on a device's appetite.
/// Four characters, not the old robot's eight: Geno's physics step costs about 0.6 ms on a phone, and a round of
/// eight (16 collected steps each) overran the frame's budget before the GPU had done anything.
const envs: usize = 4;

/// How long a callback may take, by mode. Shown, that is the 20 fps this panel is perfectly happy
/// at; training only, it is as long as a page can go without feeling stuck when the toggle is tapped.
const shown_budget: f32 = 0.050;
/// How many rounds of GPU work may be submitted and not yet confirmed done. What stops the crash is that
/// the queue is BOUNDED, not that it is tiny: the receipt (a readback) lands about once a frame, so this is
/// also roughly the rounds a frame a fast GPU may still run.
const max_rounds_in_flight: u64 = 8;
const training_budget: f32 = 0.250;

/// The learner, sized for a phone: small networks, short windows, a handful of windows per update.
const learner_options: resident.Options = .{
    .rows = 16,
    .window = 8,
    .hidden = 64,
    .policy_hidden = 64,
    .collect = 16,
    .world_updates = 1,
    .policy_updates = 1,
    // Smoothness (CAPS): without it the policy's actions jump by 70% of their size every frame and the body
    // looks like it is exploding; at 1 the jumps fall fourfold and it falls less (measured on the CPU twin).
    .w_smooth = 1.0,
};

/// The fleet's termination while training: Geno's (tracking error, and the bodies' height relative to the
/// reference's), with a training window's grace after every reset.
const training_termination: track.Termination = blk: {
    var t: track.Termination = geno.task_termination;
    t.grace_steps = learner_options.window;
    break :blk t;
};

/// Steps of servo-only simulation before the learner exists: the normaliser is measured from them, so
/// the networks see features in sensible units from their very first update.
const warmup_steps: usize = 200;

fn pipelineEntries(comptime M: type) [M.kernels.len]z.Compute(M).KernelWgsl {
    var table: [M.kernels.len]z.Compute(M).KernelWgsl = undefined;
    inline for (M.kernels, 0..) |name, i| {
        table[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

const State = struct {
    gpa: Allocator,
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    cube: z.Mesh,
    sphere: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]zm.Mat,

    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    clip: dance.Clip,
    ghost: rbt.Data,
    zero_actions: []f32,

    pipe: z.Compute(zn_mlp),
    learner: *resident.Resident(zn_mlp),
    norm: latent.Normalizer,

    /// Rounds run, and how much of the frame each callback dares spend.
    rounds: u64 = 0,
    per_frame: u32 = 1,
    /// GPU dispatches one training round submits - measured every round, not guessed.
    dispatches_per_round: u64 = 1,
    /// Frames on which rounds were held back because the GPU had not finished the ones before - in all, and
    /// as a share of RECENT frames (a moving average over about 20): a total always grows, so it cannot
    /// say whether the GPU is keeping up now; the share can.
    gpu_bound_frames: u64 = 0,
    gpu_bound_share: f32 = 0.0,
    /// Simulated seconds of character-time, and the wall-clock seconds they took - the two together
    /// are what makes a device throttling itself visible.
    training_seconds: f32 = 0,
    wall_seconds: f32 = 0,
    /// The servo alone, measured on this device before learning started.
    servo_mttf: ?f32 = null,
    /// What the learner had watched when this panel was last drawn, so rates are between draws.
    last_exposure: u64 = 0,
    last_wall: f32 = 0,
    steps_per_second: f32 = 0,
    train_only: bool = false,
    /// Watching the policy instead of training it: real time, no exploration noise, and a longer
    /// leash before an episode is called lost.
    watching: bool = false,
    /// The limits training uses, kept so watching can loosen them and give them back.
    training_limits: track.Termination = .{},
    status: [96]u8 = @splat(0),
    status_len: usize = 0,
};

/// Mean time to failure, in seconds, from steps watched and failures among them - or null while
/// nothing has failed yet, when the honest answer is "no idea, and longer than we have watched".
fn meanTimeToFailure(exposure: u64, failures: u64) ?f32 {
    if (failures == 0) {
        return null;
    }
    return float(exposure) / float(failures) / 60.0;
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.* = .{
        .gpa = gpa,
        .font = try z.loadFont(f, gpa, roboto_mono_ttf, 16),
        .ui_host = undefined,
        .cam = z.OrbitCamera.init(vec(0.0, 0.7, 0), 4.0),
        .cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0),
        .sphere = try z.genMeshSphere(gpa, 1.0, 10, 8),
        .cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2),
        .transform = .{zm.identity()},
        .doc = undefined,
        .robot = undefined,
        .imported = undefined,
        .clip = undefined,
        .ghost = undefined,
        .zero_actions = undefined,
        .pipe = undefined,
        .learner = undefined,
        .norm = undefined,
    };
    s.ui_host = z.UiHost.init(gpa, s.font);

    // The robot, exactly as every test in the tracking stack builds it.
    s.doc = try codecs.xml.parse(gpa, z.robot_geno_model, null);
    s.robot = try mjcf.readRobot(gpa, &s.doc);
    for (s.robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = geno.standing_armature;
        }
    }
    var options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    options.solver.algorithm = .newton;
    s.imported = try rmj.build(gpa, &s.robot, options);
    const m: *rbt.Model = &s.imported.model;
    s.ghost = try rbt.Data.init(gpa, m);
    s.clip = try dance.Clip.fromBytes(gpa, dance_zclip);
    s.zero_actions = try gpa.alloc(f32, envs * track.actionSize(m));
    @memset(s.zero_actions, 0.0);

    // The profiler times every stage of every physics step, each one a crossing out of wasm - about
    // a thousand a frame here, for a profile nobody is reading. Frozen, its zones return at once.
    z.profiler.freeze();
    s.pipe = try z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, &pipelineEntries(zn_mlp));

    // A fleet, and the servo alone on it for a while: it gives the normaliser something real to measure,
    // and it is the number every later one is judged against.
    const clips = [_]*const dance.Clip{&s.clip};
    const fleet: *track.Fleet = try .init(gpa, m, &clips, .{
        .envs = envs,
        .capacity = 256,
        .action_scale = 0.6,
        .gains = geno.servo_gains,
        .floor_friction = geno.floor_friction,
        .rest_on_floor = true,
        // Every episode must yield at least one training window, however bad the policy: without this a
        // policy failing within a window's length leaves nothing to train on, and training stops for good.
        // Gravity in the reward and the termination (lying with the right joint angles must not score), and a
        // training window's grace after every reset.
        .weights = geno.task_weights,
        .termination = training_termination,
    });
    // The servo alone, counted exactly as the learner counts itself: a step watched per character,
    // and a failure for each that lost its reference on that step.
    var servo_failures: u64 = 0;
    for (0..warmup_steps) |_| {
        _ = fleet.step(s.zero_actions);
        for (fleet.failures) |lost| {
            if (lost) {
                servo_failures += 1;
            }
        }
    }
    s.servo_mttf = meanTimeToFailure(envs * warmup_steps, servo_failures);
    s.norm = try latent.measureNormalizer(gpa, fleet);
    s.learner = try resident.Resident(zn_mlp).init(gpa, &s.pipe, fleet, s.norm, learner_options);
    s.training_limits = fleet.options.termination;
    setStatus(s, "learning from nothing", .{});
}

fn deinit(gpa: Allocator, s: *State) void {
    // The learner first - it holds the fleet and the networks' regions - then the host, which owns
    // the buffers, bind groups and pipelines.
    const fleet: *track.Fleet = s.learner.fleet;
    s.learner.deinit();
    fleet.deinit();
    s.pipe.deinit();
    gpa.free(s.norm.mean);
    gpa.free(s.norm.spread);
    gpa.free(s.zero_actions);
    s.clip.deinit();
    s.ghost.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.sphere);
    z.unloadMesh(gpa, s.cube);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// How much further a character may drift before an episode is called lost while WATCHING. Training
/// wants a short leash - a lost character is wasted simulation - but watching wants to see what losing
/// the reference actually looks like, and what the policy does about it, rather than have the moment
/// replaced instantly by a restart somewhere else in the clip.
const watching_leash: f32 = 1.8;

fn update(f: *z.Frame, s: *State) void {
    const dt: f32 = f.time.delta_time;
    if (s.watching) {
        // Real time, not as fast as the device can go: this is for watching. The policy acts from the
        // mirror, which nothing else refreshes while training is paused.
        // One step per sixtieth of a second, which is real time - a few more if a frame ran long,
        // never so many that watching turns back into training.
        const wanted: f32 = clamp(dt * 60.0, 1.0, 4.0);
        s.learner.syncMirror();
        s.learner.act(int(u32, wanted), 0.0);
        if (dt > 0 and dt < 1.0) {
            s.wall_seconds += dt;
        }
        drawScene(s, f);
        return;
    }
    const budget: f32 = if (s.train_only) training_budget else shown_budget;

    // A round at a time, more of them while callbacks come in under budget and fewer the moment one
    // does not. Expressed as a count rather than a clock because a page has no clock it can read
    // mid-frame - but it is a time budget all the same, and it fills a phone and a desktop alike.
    if (dt > 0 and dt < budget * 0.9 and s.per_frame < 64) {
        s.per_frame += 1;
    } else if (dt > budget * 1.2 and s.per_frame > 1) {
        s.per_frame -= 1;
    }
    if (dt > 0 and dt < 1.0) {
        s.wall_seconds += dt;
    }
    // ── ★★ NEVER LET GPU WORK OUTRUN THE GPU ──
    //
    // The count above follows the FRAME time, and the frame time only measures the CPU: a submitted
    // round costs it next to nothing while the GPU may need longer than a frame to run it. So on a
    // phone whose GPU cannot keep up, frames stayed fast, the count climbed toward 64 rounds a frame,
    // and the unrun work piled up in the browser's queue until memory ran out - a phone that slowed to
    // a crawl and a page that died after minutes. So: at most `max_rounds_in_flight` rounds' worth of
    // dispatches may be submitted and not yet confirmed (`mirrored` is the GPU's own receipt, through
    // the readback); past that, this frame submits nothing more, asks for a receipt, and backs off. On
    // the CPU backend both counts are zero and this never holds anything back.
    var held_back: bool = false;
    for (0..s.per_frame) |_| {
        const before: z.Compute(zn_mlp).Generation = s.pipe.readGeneration();
        if (before.submitted > before.mirrored + s.dispatches_per_round * max_rounds_in_flight) {
            held_back = true;
            break;
        }
        s.learner.round();
        s.rounds += 1;
        const after: u64 = s.pipe.readGeneration().submitted;
        if (after > before.submitted) {
            s.dispatches_per_round = after - before.submitted;
        }
    }
    s.gpu_bound_share += 0.05 * ((if (held_back) @as(f32, 1.0) else 0.0) - s.gpu_bound_share);
    if (held_back) {
        s.gpu_bound_frames += 1;
        s.learner.syncMirror();
        if (s.per_frame > 1) {
            s.per_frame -= 1;
        }
    }
    s.training_seconds += float(s.per_frame * learner_options.collect * envs) / 60.0;

    // Steps a second, measured between draws rather than within a frame.
    const watched: u64 = s.learner.exposure;
    if (s.wall_seconds - s.last_wall > 0.5) {
        const elapsed: f32 = s.wall_seconds - s.last_wall;
        s.steps_per_second = float(watched - s.last_exposure) / elapsed;
        s.last_exposure = watched;
        s.last_wall = s.wall_seconds;
    }

    if (s.train_only) {
        // Nothing is drawn at all - no scene, no panel, not even a cleared viewport beyond what the
        // frame owes the swap chain. The toggle is read from the panel, so it comes back through the
        // one frame we still draw when it is turned off.
        z.clearViewport(f, bg);
        _ = drawPanel(s, f);
        s.ui_host.render(f);
        return;
    }

    drawScene(s, f);
}

/// The panel, the ground, the reference and the character - everything the page draws when it draws.
fn drawScene(s: *State, f: *z.Frame) void {
    z.clearViewport(f, bg);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.5, .max_distance = 10.0 });
    const gl = f.gl;
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.5);
    s.transform[0] = mulMat(mulMat(zm.zUpToYUp(), translation(0, 0, -0.5)), scaling(16, 16, 0.2));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_col);

    // Where character 0 should be, and where it actually is.
    const m: *const rbt.Model = &s.imported.model;
    const fleet: *track.Fleet = s.learner.fleet;
    const frame: usize = @min(@as(usize, fleet.frame[0]), s.clip.frame_count - 1);
    @memcpy(s.ghost.pos, s.clip.pose(frame));
    s.ghost.stage = .stale;
    rbt.kinematics(m, &s.ghost);
    drawRobot(s, gl, &s.ghost, ref_col);
    drawRobot(s, gl, &fleet.data[0], sim_col);
    z.endMode3D(gl);
}

/// The panel: what the learner has done, how fast, and the one toggle. Returns whether the pointer
/// belongs to the interface, so the camera does not also act on it.
fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const captured: bool = u.wantCaptureMouse();
    // Compact on purpose: on a portrait phone the canvas is short, and a window that grows past it
    // hides its own last lines.
    if (u.window("SuperTrack, on this device", .{ .initial_pos = .{ 4, 4 }, .initial_size = .{ 330, 200 } })) |window| {
        defer window.close();
        const learner = s.learner;
        u.text("{d} characters, {d} rounds, {d} a frame", .{ envs, s.rounds, s.per_frame });
        u.text("world {d} updates, policy {d}", .{ learner.world_updates, learner.policy_updates });
        u.text("GPU-bound: {d:.0}% of recent frames ({d} in all)", .{
            s.gpu_bound_share * 100.0,
            s.gpu_bound_frames,
        });
        // Both should stay 0; a climbing count means training blew up on the device.
        u.text("bad weights refused: {d}, bad actions zeroed: {d}", .{
            learner.mirror_rejected,
            learner.nonfinite_actions,
        });
        // Two numbers, never one: what the policy PLUS its exploration noise manages while collecting,
        // and what the policy alone manages when it is watched or judged. Only the second is
        // comparable with the servo's, which was measured without noise.
        if (meanTimeToFailure(learner.exposure, learner.failures)) |mttf| {
            u.text("while exploring: {d:.2} s to failure", .{mttf});
        } else {
            u.text("while exploring: nothing lost yet", .{});
        }
        if (meanTimeToFailure(learner.judged_exposure, learner.judged_failures)) |mttf| {
            u.text("the policy alone: {d:.2} s to failure", .{mttf});
        } else if (learner.judged_exposure > 0) {
            u.text("the policy alone: nothing lost yet", .{});
        } else {
            u.text("the policy alone: watch it to find out", .{});
        }
        if (s.servo_mttf) |servo| {
            u.text("the servo alone, here: {d:.2} s", .{servo});
        }
        u.text("{d:.0} character-steps a second", .{s.steps_per_second});
        // Motion trained against wall-clock spent: when a device throttles itself, this is where it
        // shows - every loss looks exactly as healthy as before.
        u.text("trained {d:.0} s of motion in {d:.0} s", .{ s.training_seconds, s.wall_seconds });
        const watch_label: []const u8 = if (s.watching) "back to training" else "watch the policy (real time)";
        if (u.button(watch_label, .{})) {
            s.watching = !s.watching;
            // A longer leash while watching, and the training one back afterwards.
            const fleet: *track.Fleet = s.learner.fleet;
            fleet.options.termination = if (s.watching) s.training_limits.scaled(watching_leash) else s.training_limits;
        }
        if (!s.watching) {
            const label: []const u8 = if (s.train_only) "show the character" else "train only (stop drawing)";
            if (u.button(label, .{})) {
                s.train_only = !s.train_only;
            }
        }
        u.text("{s}", .{s.status[0..s.status_len]});
    }
    return captured;
}

fn setStatus(s: *State, comptime fmt: []const u8, args: anytype) void {
    const written: []u8 = bufPrint(&s.status, fmt, args) catch s.status[0..0];
    s.status_len = written.len;
}

fn drawRobot(s: *State, gl: *z.WgpuGl, d: *const rbt.Data, tint: Color) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        const body_rot: Quat = d.body_xrot[body];
        const world_pos: Vec = d.body_xpos[body] + zm.rotate(body_rot, m.geom_pos[g]);
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
            .title = "zimr - SuperTrack, learned on this device",
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
