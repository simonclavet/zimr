//! examples/geno_ppo - PPO on GENO, learned on the device in your hand.
//!
//! `getup_train` on the robot built from Geno's skeleton and mesh: standing armature on every joint,
//! self-collision off, every reset rested on the floor, DReCon's watched and actuated bodies in Geno's
//! names, and the dance from 5 s to 15 s (baked for `geno_train`). The action scale is stated, not
//! inherited: 1.2 rad per unit, filtered (a fifth new, four fifths held) - see `action_scale` below.
//!
//! What follows is `getup_train`'s own description.
//!
//! WHAT THIS IS
//!
//! The bench the whole tracking plan is measured on. A humanoid, a motion capture it should follow,
//! a servo driving it toward the capture, and a small policy that learns - right here, from
//! nothing - the corrections that keep it with the capture. Two motions to choose from: GETTING UP
//! off the floor (five seconds, contact-rich, the hard one) and DANCING (twenty seconds of
//! continuous balance). The characters are stepped on this device's CPU; the policy and value
//! networks train on its GPU. Nothing is downloaded pre-trained: every weight this page uses was
//! learned on the device it runs on, or uploaded by whoever runs it.
//!
//! THE NUMBER THAT MATTERS: MEAN TIME TO FAILURE
//!
//! Characters start at random points of the clip, so an episode can never outlast what is left of
//! the clip - on the five-second get-up that averages two and a half seconds, which makes "how long
//! did episodes last" top out well below perfect. So the page counts FAILURES - a character losing
//! the reference - against the time characters were watched, and shows their ratio: how long a
//! character tracks, on average, before it loses the reference. Running out of clip while still
//! with it is survival, not failure. The servo alone is measured the same way, on this device,
//! before learning starts; a perfect tracker's number grows without limit.
//!
//! HOW IT FITS A FRAME
//!
//! A batch of experience is too much for one frame, so each frame collects a FEW decisions
//! (`Trainer.collect`), adapted to the frame time the device achieves, and goes back to drawing.
//! When a batch is full, `Trainer.learn` dispatches the update to the GPU, which trains while the
//! next batch is collected. The clips arrive BAKED (`zig build clip-bake`): retargeted, filtered,
//! windowed and lifted offline into a few hundred kilobytes, so startup does no inverse kinematics.

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
const ppo_track = z.robot_ppo_track;
const zn_mlp = @import("zn_mlp");

const Allocator = std.mem.Allocator;
const Vec = zm.Vec;
const Mat = zm.Mat;
const Quat = zm.Quat;
const Color = zm.Color;
const Camera3D = zm.Camera3D;
const vec = zm.vec;
const qmul = zm.qmul;
const quatToMat = zm.quatToMat;
const float = zm.float;
const mulMat = zm.mulMat;
const translation = zm.translation;
const scaling = zm.scaling;
const splat = zm.splat;
const bufPrint = std.fmt.bufPrint;

const Trainer = ppo_track.Trainer(zn_mlp);

const geno = z.robot_geno;
const dance_zclip = @embedFile("dance.zclip");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

const bg: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 };
const sim_col: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 };
const ref_col: Color = .{ .r = 86, .g = 92, .b = 104, .a = 255 };
const ground_col: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 };

/// How many characters train at once: a phone's CPU is the bottleneck, and eight keeps a decision
/// inside a frame while still giving PPO a varied batch.
const envs: u32 = 8;
/// ACTION SCALE - radians of pose offset per unit of the policy's action, stated here rather than inherited.
///
/// 1.2 rad a unit, and the actions live in [-1, 1]. That sounds huge, so here's why it isn't. Every decision
/// goes through DReCon's filter: a joint receives a FIFTH of the new action and keeps four fifths of what it
/// had, and a decision is held for 2 physics steps (30 Hz). So the joint never jumps - to move an offset
/// quickly the policy must ASK for much more than it wants, and the filter hands it over gently. The planner
/// that teaches this policy measured exactly that: capped at 0.6 rad raw it barely beats the servo (1.4 s vs
/// 1.05 on the hard starts), allowed 1.2 it holds 3.48 s - while the offsets the joints actually RECEIVE
/// average 0.24 rad (14 degrees), because of the filter.
///
/// Exploration starts small to match: PPO's Gaussian begins at log sigma -1.2 (0.3 units), so a young policy's
/// random asks are 0.36 rad raw and 0.072 rad (4 degrees) at the joint a decision.
const action_scale: f32 = 1.2;
const initial_log_std: f32 = -1.2;

/// Batches of history kept for the curve and the failure-rate window.
const history_len: usize = 120;
/// How many recent batches the mean time to failure is estimated over. One batch is about 17
/// seconds of character-time; eight give enough failures to tell 10 s from 20 s.
const window_batches: usize = 8;

/// The mean times to failure the page times itself to, in seconds. The same marks for both motions:
/// the measure does not depend on the clip's length, which is the point of it.
const milestones = [_]f32{ 2.0, 5.0, 10.0, 20.0 };

/// The two motions, and what each needs.
const Task = enum {
    getup,
    dance,

    fn label(task: Task) []const u8 {
        return switch (task) {
            .getup => "get-up",
            .dance => "dance",
        };
    }

    fn clipBytes(task: Task) []const u8 {
        return switch (task) {
            .getup, .dance => dance_zclip,
        };
    }

    fn options(task: Task) ppo_track.Options {
        return .{
            .envs = envs,
            .horizon = 64,
            // The two tricks every learner gets: inputs scaled to unit spread, and a helping hand
            // on the root that fades to nothing over the first few minutes.
            .normalize = true,
            .assist_start = 1.0,
            .assist_batches = 300,
            // Geno: its DReCon bodies, its servo and floor, resets on the floor, and the action scale.
            .watched = &geno.drecon_watched,
            .actuated = &geno.drecon_actuated,
            .gains = geno.servo_gains,
            .floor_friction = geno.floor_friction,
            .rest_on_floor = true,
            .action_scale = action_scale,
            // Gravity in the reward and the termination: lying with the right joint angles must not score.
            .weights = geno.task_weights,
            .termination = geno.task_termination,
            .initial_log_std = initial_log_std,
            // Long enough for the whole clip: a cap shorter than the dance would end good episodes.
            .max_episode_steps = 700,
            // A get-up policy and a dance policy have identical shapes; the tag tells them apart
            // in a weights file, so one is never silently loaded as the other.
            .tag = switch (task) {
                .getup, .dance => 3,
            },
        };
    }

    /// Geno has one motion baked so far: "switching" restarts the dance.
    fn other(task: Task) Task {
        _ = task;
        return .dance;
    }
};

fn pipelineEntries(comptime M: type) [M.kernels.len]z.Compute(M).KernelWgsl {
    var table: [M.kernels.len]z.Compute(M).KernelWgsl = undefined;
    inline for (M.kernels, 0..) |name, i| {
        table[i] = .{ .name = name, .wgsl = @embedFile(name ++ "_wgsl") };
    }
    return table;
}

const State = struct {
    font: z.Font,
    ui_host: z.UiHost,
    cam: z.OrbitCamera,
    sphere: z.Mesh,
    cube: z.Mesh,
    cylinder: z.Mesh,
    transform: [1]Mat,

    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    /// The reference's pose, posed each frame by forward kinematics, for drawing.
    ghost: rbt.Data,

    gpa: Allocator,
    pipe: z.Compute(zn_mlp),
    task: Task,
    clip: dance.Clip,
    trainer: *Trainer,
    /// Exactly-zero actions for the whole fleet: the servo alone.
    zero_actions: []f32,
    progress: Progress,
};

/// Everything that changes as training goes, every field with a default - and assigned AS A WHOLE
/// whenever training starts. That is the point: the app framework makes the `State` with
/// `gpa.create`, which hands back uninitialised memory, so a default written on a `State` field is
/// never applied. Grouped here, one assignment sets them all, and a field added later cannot be
/// forgotten.
const Progress = struct {
    /// Decisions collected per frame, adapted to the frame time the device achieves.
    per_frame: u32 = 1,
    last: ppo_track.Stats = .{ .decisions = 0, .steps = 0, .mean_reward = 0, .episodes = 0, .mean_episode = 0 },
    failed: ?[]const u8 = null,
    /// What the weights buttons last did, shown under them.
    status: [96]u8 = @splat(0),
    status_len: usize = 0,
    /// Seconds spent training since this motion was chosen (or since weights were loaded).
    training_seconds: f32 = 0,
    /// When the mean time to failure first reached each milestone, in training seconds; 0 until.
    milestone_seconds: [milestones.len]f32 = @splat(0),
    /// Per batch: physics steps watched, failures among them, and whether the assist was on.
    exposure: [history_len]u64 = @splat(0),
    failures: [history_len]u32 = @splat(0),
    assisted: [history_len]bool = @splat(false),
    history_count: usize = 0,
    /// The servo alone, measured the same way before any training: decisions left to run, then
    /// what it managed.
    servo_left: u32 = 96,
    servo_exposure: u64 = 0,
    servo_failures: u32 = 0,
};

/// Mean time to failure, in seconds, from steps watched and failures among them - or null when
/// nothing has failed yet, which is where a perfect tracker lives. (Null rather than infinity: it
/// is a different kind of answer, and the panel says so in words.)
fn meanTimeToFailure(exposure: u64, failures: u64) ?f32 {
    if (failures == 0) {
        return null;
    }
    return float(exposure) / float(failures) / 60.0;
}

/// The recent past, as the milestones see it.
const Recent = struct {
    /// Mean time to failure over the window; null if nothing in it failed.
    mttf: ?f32,
    /// Every batch in the window ran with the assist at zero - the real task.
    unassisted: bool,
    /// The window is full: enough batches to trust the number.
    full: bool,
};

/// The last `window_batches` batches: their mean time to failure, and whether they count.
fn recentWindow(p: *const Progress) Recent {
    const count: usize = @min(p.history_count, window_batches);
    var exposure: u64 = 0;
    var failures: u64 = 0;
    var unassisted: bool = true;
    for (0..count) |i| {
        const index: usize = (p.history_count - 1 - i) % history_len;
        exposure += p.exposure[index];
        failures += p.failures[index];
        unassisted = unassisted and !p.assisted[index];
    }
    return .{
        .mttf = if (count == 0) null else meanTimeToFailure(exposure, failures),
        .unassisted = unassisted,
        .full = count == window_batches,
    };
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.progress = .{};
    s.gpa = gpa;
    s.font = try z.loadFont(f, gpa, roboto_mono_ttf, 16);
    s.ui_host = z.UiHost.init(gpa, s.font);
    s.cam = z.OrbitCamera.init(vec(0.0, 0.7, 0), 4.0);
    s.sphere = try z.genMeshSphere(gpa, 1.0, 10, 8);
    s.cube = try z.genMeshCube(gpa, 1.0, 1.0, 1.0);
    s.cylinder = try z.genMeshCylinder(gpa, 1.0, 1.0, 16, 2);
    s.transform = .{zm.identity()};

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
    s.zero_actions = try gpa.alloc(f32, envs * track.actionSize(m));
    @memset(s.zero_actions, 0.0);

    // The networks live on the GPU; the characters on the CPU.
    s.pipe = try z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, &pipelineEntries(zn_mlp));
    // The profiler times every stage of every physics step, each reading a crossing from wasm into
    // JS - about 1,300 a frame here, for a profile nobody is looking at. Frozen, its zones return
    // before touching the clock.
    z.profiler.freeze();
    try startTask(s, .getup, false);
}

/// Begin training on a motion from scratch: its baked clip, a fresh trainer, fresh progress.
/// `replace` says whether a previous motion's clip and trainer must be released first.
fn startTask(s: *State, task: Task, replace: bool) !void {
    if (replace) {
        s.trainer.deinit();
        s.clip.deinit();
    }
    const m: *rbt.Model = &s.imported.model;
    s.task = task;
    s.clip = try dance.Clip.fromBytes(s.gpa, task.clipBytes());
    // The fleet copies this list, so a local array is fine here.
    const clips = [_]*const dance.Clip{&s.clip};
    s.trainer = try Trainer.init(s.gpa, &s.pipe, m, s.imported.names, &clips, task.options());
    s.progress = .{};
}

fn deinit(gpa: Allocator, s: *State) void {
    // The trainer first - it holds the networks on the GPU host - and then the host itself, which
    // owns the buffers, bind groups and compute pipelines.
    s.trainer.deinit();
    s.pipe.deinit();
    s.clip.deinit();
    gpa.free(s.zero_actions);
    s.ghost.deinit();
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.cube);
    z.unloadMesh(gpa, s.sphere);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

fn update(f: *z.Frame, s: *State) void {
    const gl = f.gl;
    const m: *const rbt.Model = &s.imported.model;
    const p: *Progress = &s.progress;

    // A slice at a time: it grows while frames come in under budget and shrinks the moment one
    // does not, so the page stays responsive on a slow device and uses a fast one.
    const dt: f32 = f.time.delta_time;
    if (dt > 0 and dt < 0.018 and p.per_frame < 16) {
        p.per_frame += 1;
    } else if (dt > 0.024 and p.per_frame > 1) {
        p.per_frame -= 1;
    }
    if (p.servo_left > 0) {
        measureServo(s);
    } else if (p.failed == null) {
        if (dt > 0 and dt < 1.0) {
            p.training_seconds += dt;
        }
        if (s.trainer.collect(p.per_frame)) {
            if (s.trainer.learn()) |stats| {
                recordBatch(s, stats);
                offerWeights(s);
            } else |err| {
                p.failed = @errorName(err);
            }
        }
    }

    takeUploads(s);
    z.clearViewport(f, bg);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.5, .max_distance = 10.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.5);
    s.transform[0] = mulMat(mulMat(zm.zUpToYUp(), translation(0, 0, -0.5)), scaling(16, 16, 0.2));
    z.drawMeshInstanced(gl, &s.cube, &s.transform, ground_col);

    // The reference, where training character 0 should be; then the character itself.
    const fleet: *track.Fleet = s.trainer.fleet;
    const frame: usize = @min(@as(usize, fleet.frame[0]), s.clip.frame_count - 1);
    @memcpy(s.ghost.pos, s.clip.pose(frame));
    s.ghost.stage = .stale;
    rbt.kinematics(m, &s.ghost);
    drawRobot(s, gl, &s.ghost, ref_col);
    drawRobot(s, gl, &fleet.data[0], sim_col);
    z.endMode3D(gl);
}

/// One finished batch into the history, and the milestones it may have reached.
fn recordBatch(s: *State, stats: ppo_track.Stats) void {
    const p: *Progress = &s.progress;
    p.last = stats;
    const index: usize = p.history_count % history_len;
    p.exposure[index] = stats.exposure;
    p.failures[index] = stats.failures;
    p.assisted[index] = stats.assist > 0;
    p.history_count += 1;
    const recent: Recent = recentWindow(p);
    // Only whole windows of unassisted batches count: the bar is the real task. A window with no
    // failures at all has passed every milestone.
    if (recent.full and recent.unassisted) {
        const seconds: f32 = recent.mttf orelse 1.0e9;
        for (milestones, &p.milestone_seconds) |mark, *when| {
            if (when.* == 0 and seconds >= mark) {
                when.* = p.training_seconds;
            }
        }
    }
}

/// The servo alone - the policy's actions held at exactly zero - on the very fleet that is about
/// to train, counted the same way as the policy: steps watched against failures among them. Done
/// before learning starts, so it measures the servo and nothing else.
fn measureServo(s: *State) void {
    const p: *Progress = &s.progress;
    const fleet: *track.Fleet = s.trainer.fleet;
    const take: u32 = @min(p.servo_left, p.per_frame);
    for (0..take) |_| {
        for (0..2) |_| {
            _ = fleet.step(s.zero_actions);
            p.servo_exposure += envs;
            for (fleet.failures) |lost| {
                if (lost) {
                    p.servo_failures += 1;
                }
            }
        }
    }
    p.servo_left -= take;
}

/// The numbers that say whether it is learning. Returns whether the pointer belongs to the panel,
/// so the camera leaves it alone.
fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const captured: bool = u.wantCaptureMouse();
    // Compact on purpose: on a portrait phone the canvas is short, and a window that auto-expands
    // past it hides its own last lines.
    if (u.window("tracking, PPO", .{ .initial_pos = .{ 4, 4 }, .initial_size = .{ 330, 160 } })) |window| {
        defer window.close();
        const p: *Progress = &s.progress;
        if (p.failed) |why| {
            u.text("stopped: {s}", .{why});
        }
        const trainer: *Trainer = s.trainer;
        u.text("{s}: {d} batches {d}k steps {d}/f", .{
            s.task.label(),
            trainer.iterations,
            trainer.steps / 1000,
            p.per_frame,
        });
        if (p.servo_left > 0) {
            u.text("measuring the servo alone...", .{});
        } else {
            const recent: Recent = recentWindow(p);
            var servo_text: [24]u8 = undefined;
            const servo: []const u8 = if (meanTimeToFailure(p.servo_exposure, p.servo_failures)) |seconds|
                bufPrint(&servo_text, "{d:.1}s", .{seconds}) catch "?"
            else
                "never";
            if (p.history_count == 0) {
                u.text("servo loses it every {s}", .{servo});
            } else if (recent.mttf) |seconds| {
                u.text("loses it every {d:.1}s servo {s}", .{ seconds, servo });
            } else {
                u.text("no losses lately! servo {s}", .{servo});
            }
        }
        if (p.last.assist > 0) {
            u.text("assist {d:.2} - fading, milestones wait", .{p.last.assist});
        }
        // Minutes of training to each milestone: the number every method in the plan is judged by.
        var marks: [64]u8 = undefined;
        var at: usize = 0;
        for (milestones, p.milestone_seconds) |mark, when| {
            const piece: []const u8 = if (when > 0)
                bufPrint(marks[at..], "{d:.0}s@{d:.1}m ", .{ mark, when / 60.0 }) catch ""
            else
                bufPrint(marks[at..], "{d:.0}s@-- ", .{mark}) catch "";
            at += piece.len;
        }
        u.text("{s}", .{marks[0..at]});
        _ = u.button("save", .{});
        const save_min: zm.Vec2 = u.getItemRectMin();
        const save_max: zm.Vec2 = u.getItemRectMax();
        z.web.userfile.setSaveRect(save_min[0], save_min[1], save_max[0] - save_min[0], save_max[1] - save_min[1]);
        u.sameLine(.{});
        _ = u.button("load", .{});
        const load_min: zm.Vec2 = u.getItemRectMin();
        const load_max: zm.Vec2 = u.getItemRectMax();
        z.web.userfile.setPickerRect(
            load_min[0],
            load_min[1],
            load_max[0] - load_min[0],
            load_max[1] - load_min[1],
            ".weights,application/octet-stream",
        );
        u.sameLine(.{});
        var switch_label: [32]u8 = undefined;
        const label: []const u8 = bufPrint(&switch_label, "-> {s}", .{s.task.other().label()}) catch "switch";
        if (u.button(label, .{})) {
            startTask(s, s.task.other(), true) catch |err| {
                p.failed = @errorName(err);
            };
        }
        if (p.status_len > 0) {
            u.text("{s}", .{p.status[0..p.status_len]});
        }
        drawCurve(u, p);
    }
    return captured;
}

/// The failure rate over time, in plain ASCII - a density ramp every font has - one character a
/// batch: taller is longer between losses, relative to the best window so far.
fn drawCurve(u: ui.Ui, p: *const Progress) void {
    const shown: usize = @min(p.history_count, 32);
    if (shown == 0) {
        return;
    }
    const ramp: []const u8 = ".:-=+*#%@";
    var values: [32]f32 = undefined;
    var top: f32 = 0.1;
    for (0..shown) |i| {
        // Each character: that batch's own exposure over its failures, capped so one lucky batch
        // with no failures does not flatten the rest.
        const index: usize = (p.history_count - shown + i) % history_len;
        const seconds: f32 = @min(meanTimeToFailure(p.exposure[index], p.failures[index]) orelse 30.0, 30.0);
        values[i] = seconds;
        top = @max(top, seconds);
    }
    var line: [32]u8 = undefined;
    for (0..shown) |i| {
        const step: usize = @trunc(values[i] / top * float(ramp.len - 1));
        line[i] = ramp[@min(ramp.len - 1, step)];
    }
    u.text("{s}", .{line[0..shown]});
}

/// Hand the newest weights to the Save overlay, named by motion and by how many batches trained
/// them - so the newest file on the phone is obvious by its name alone.
fn offerWeights(s: *State) void {
    const bytes: []u8 = s.trainer.exportWeights(s.gpa) catch return;
    defer s.gpa.free(bytes);
    var name_buffer: [64]u8 = undefined;
    const batches: u64 = s.trainer.iterations;
    const name: []const u8 = bufPrint(&name_buffer, "{s}_ppo_b{d}.weights", .{ s.task.label(), batches }) catch return;
    z.web.userfile.offerDownload(bytes, name);
}

/// Weights the user picked: carried on from if they fit this network AND this motion, refused by
/// name if not.
fn takeUploads(s: *State) void {
    while (z.web.userfile.pendingCount() > 0) {
        const size: u32 = z.web.userfile.nextSize();
        const bytes: []u8 = s.gpa.alloc(u8, size) catch {
            z.web.userfile.discardNext();
            return;
        };
        defer s.gpa.free(bytes);
        _ = z.web.userfile.readNext(bytes);
        if (s.trainer.importWeights(bytes)) |_| {
            // A fresh record from here: the servo stands, the history and milestones restart.
            const servo_exposure: u64 = s.progress.servo_exposure;
            const servo_failures: u32 = s.progress.servo_failures;
            s.progress = .{};
            s.progress.servo_left = 0;
            s.progress.servo_exposure = servo_exposure;
            s.progress.servo_failures = servo_failures;
            setStatus(s, "loaded batch {d}", .{s.trainer.iterations});
            offerWeights(s);
        } else |err| {
            setStatus(s, "refused: {s}", .{@errorName(err)});
        }
    }
}

fn setStatus(s: *State, comptime fmt: []const u8, args: anytype) void {
    const written: []const u8 = bufPrint(&s.progress.status, fmt, args) catch s.progress.status[0..0];
    s.progress.status_len = written.len;
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
            .title = "zimr - getting up, learned on this device",
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
