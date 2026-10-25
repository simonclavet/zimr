//! examples/geno_ppo - PPO on GENO, learned on the device in your hand.
//!
//! `getup_train` on the robot built from Geno's skeleton and mesh: standing armature on every joint,
//! self-collision off, every reset rested on the floor, DReCon's watched and actuated bodies in Geno's
//! names, and the dance from 5 s to 15 s (baked for `geno_train`). The action scale is stated, not
//! inherited: 1.2 rad per unit, filtered (a fifth new, four fifths held) - see `robot_geno.student_scale`.
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
const Vec2 = zm.Vec2;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;

const Trainer = ppo_track.Trainer(zn_mlp);

const geno = z.robot_geno;
const lab = z.robot_lab;
const dance_zclip = @embedFile("dance.zclip");
const roboto_mono_ttf = @embedFile("roboto_mono_ttf");

/// The page's colours: the background, the character, the reference, the floor.
const Look = struct {
    background: Color = .{ .r = 22, .g = 24, .b = 30, .a = 255 },
    character: Color = .{ .r = 120, .g = 170, .b = 225, .a = 255 },
    reference: Color = .{ .r = 86, .g = 92, .b = 104, .a = 255 },
    floor: Color = .{ .r = 74, .g = 80, .b = 92, .a = 255 },
};

/// The floor's slab, as drawn: square, of some thickness, its top just below the grid - where the physics floor
/// is, as near as the grid's lines allow without the two fighting for the same pixels.
const Floor = struct {
    side: f32 = 16,
    thickness: f32 = 0.2,
    top: f32 = -0.005,
};

/// The page's autosave (`autosaveIfDue`, `resumeFromAutosave`): how often, in seconds of training, and the largest
/// training log a resume reads back - about 70 bytes a batch, so a week of batches.
const Autosave = struct {
    interval_seconds: f32 = 300,
    most_log_bytes: usize = 16 << 20,
};

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

    /// The motion's name in `robot_geno`, whose PPO recipe the page trains with.
    fn motion(task: Task) lab.PpoMotion {
        return switch (task) {
            .getup => .getup,
            .dance => .dance,
        };
    }

    /// The trainer's options: PPO's recipe on Geno, its defaults - the same settings a training run's `run.zon`
    /// starts from - with Geno's task, DReCon bodies and the motion's tag.
    fn options(task: Task, recipe: lab.PpoRecipe) ppo_track.Options {
        return recipe.options(task.motion());
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

/// Everything that changes as training goes, every field with a default - and assigned AS A WHOLE
/// whenever training starts. That is the point: the app framework makes the `State` with
/// `gpa.create`, which hands back uninitialised memory, so a default written on a `State` field is
/// never applied. Grouped here, one assignment sets them all, and a field added later cannot be
/// forgotten.
const Progress = struct {
    /// Batches of history kept for the curve and the failure-rate window.
    const history_len: usize = 120;
    /// How many recent batches the mean time to failure is estimated over: a run log's window
    /// (`robot_lab.RunLog.window_batches`), the same for the trainer and the lab's curves.
    const window_batches: usize = lab.RunLog.window_batches;
    /// The mean times to failure the page times itself to, in seconds. The same marks for both motions: the measure
    /// does not depend on the clip's length, which is the point of it.
    const milestones = [_]f32{ 2.0, 5.0, 10.0, 20.0 };

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
    /// Whether this run has autosaved yet, and the training seconds at the last autosave (`autosaveIfDue`).
    has_autosaved: bool = false,
    autosaved_at_seconds: f32 = 0,
    /// The servo alone, measured the same way before any training: decisions left to run, then
    /// what it managed.
    servo_left: u32 = 96,
    servo_exposure: u64 = 0,
    servo_failures: u32 = 0,
};

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
    /// The training log, one CSV line a batch (`lab.RunLog`), saved with each autosave.
    training_log: ArrayList(u8),
    /// PPO's recipe on Geno as the page trains it: its defaults, the settings a training run's `run.zon` starts from.
    recipe: lab.PpoRecipe,
    look: Look,
    floor: Floor,
    autosave: Autosave,
};

/// Physics steps per second of the page's Geno: what turns steps watched into seconds of character-time.
fn physicsStepsPerSecond(model: *const rbt.Model) f32 {
    return 1.0 / model.opt.timestep;
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

/// The last `Progress.window_batches` batches: their mean time to failure, and whether they count.
fn recentWindow(p: *const Progress, physics_steps_per_second: f32) Recent {
    const count: usize = @min(p.history_count, Progress.window_batches);
    var exposure: u64 = 0;
    var failures: u64 = 0;
    var unassisted: bool = true;
    for (0..count) |i| {
        const index: usize = (p.history_count - 1 - i) % Progress.history_len;
        exposure += p.exposure[index];
        failures += p.failures[index];
        unassisted = unassisted and !p.assisted[index];
    }
    return .{
        .mttf = if (count == 0) null else ppo_track.secondsToFailure(exposure, failures, physics_steps_per_second),
        .unassisted = unassisted,
        .full = count == Progress.window_batches,
    };
}

// ---- Training unattended ----
//
// A night's training must survive what can happen while nobody watches: a crash, a restart, a closed window. So
// every few minutes the page saves the newest weights and the training log as saved values (`z.saveValue`) - in
// the browser's storage on the web, as files in the program's folder under the user's application data natively
// (`%APPDATA%\zimr\geno_ppo` on Windows) - and at start-up it carries on from them without asking, since there may
// be no one to ask. "Start over" discards them.
//
//     start-up:   autosave found, same network and motion?  -> resume from its batch   else  -> train from scratch
//     training:   every 5 minutes of training               -> save the weights, then the log
//     morning:    <motion>.weights  and  <motion>.log.csv   -> the newest weights, and one line per batch

/// What the weights buttons and the autosave last did, shown under the buttons.
fn setStatus(s: *State, comptime fmt: []const u8, args: anytype) void {
    const written: []const u8 = bufPrint(&s.progress.status, fmt, args) catch s.progress.status[0..0];
    s.progress.status_len = written.len;
}

/// The saved value's key for this motion's autosave: `<motion>.weights` or `<motion>.log.csv`.
fn autosaveKey(task: Task, comptime suffix: []const u8, buffer: []u8) []const u8 {
    return bufPrint(buffer, "{s}" ++ suffix, .{task.label()}) catch suffix;
}

/// Saves the newest weights, then the training log: after the first batch, then whenever
/// `interval_seconds` of training have passed since the last time. Whether it saved.
fn autosaveIfDue(
    gpa: Allocator,
    trainer: *Trainer,
    task: Task,
    training_log: []const u8,
    interval_seconds: f32,
    progress: *Progress,
) !bool {
    // Nothing to save before the first batch has trained.
    if (trainer.iterations == 0) {
        return false;
    }
    const seconds_since_autosave: f32 = progress.training_seconds - progress.autosaved_at_seconds;
    const is_due: bool = !progress.has_autosaved or seconds_since_autosave >= interval_seconds;
    // The parameters read back must be the update's whose counters are saved beside them: a later frame saves
    // when they are not yet (`isReadbackCurrent`) - a page cannot wait for a readback, which lands between frames.
    if (!is_due or !trainer.isReadbackCurrent()) {
        return false;
    }
    const weights_bytes: []u8 = try trainer.exportWeights(gpa);
    defer gpa.free(weights_bytes);
    var key_buffer: [48]u8 = undefined;
    z.saveValue(autosaveKey(task, ".weights", &key_buffer), weights_bytes);
    z.saveValue(autosaveKey(task, ".log.csv", &key_buffer), training_log);
    progress.has_autosaved = true;
    progress.autosaved_at_seconds = progress.training_seconds;
    return true;
}

/// What `resumeFromAutosave` found.
const ResumeOutcome = union(enum) {
    /// No autosave of this motion.
    nothing_saved,
    /// An autosave the trainer refused - another network's shape, another motion's tag - by the error's name.
    refused: []const u8,
    /// Carried on from the autosave's batch.
    resumed,
};

/// Carries on from this motion's autosave, if there is one this network accepts: its weights - and with them its
/// batch count, Adam's state and the normaliser's statistics - and its training log. Out of memory fails the start:
/// a log not carried on would be overwritten, empty, at the next autosave.
fn resumeFromAutosave(
    gpa: Allocator,
    trainer: *Trainer,
    task: Task,
    training_log: *ArrayList(u8),
    most_log_bytes: usize,
) Allocator.Error!ResumeOutcome {
    var key_buffer: [48]u8 = undefined;
    const weights_buffer: []u8 = try gpa.alloc(u8, trainer.weightsByteCount());
    defer gpa.free(weights_buffer);
    const saved_weights: []u8 = z.loadValue(autosaveKey(task, ".weights", &key_buffer), weights_buffer) orelse
        return .nothing_saved;
    trainer.importWeights(saved_weights) catch |err| {
        return .{ .refused = @errorName(err) };
    };
    const log_buffer: []u8 = try gpa.alloc(u8, most_log_bytes);
    defer gpa.free(log_buffer);
    if (z.loadValue(autosaveKey(task, ".log.csv", &key_buffer), log_buffer)) |saved_log| {
        training_log.clearRetainingCapacity();
        try training_log.appendSlice(gpa, saved_log);
    }
    return .resumed;
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
    const trainer_options: ppo_track.Options = task.options(s.recipe);
    s.trainer = try Trainer.init(s.gpa, &s.pipe, m, s.imported.names, &clips, trainer_options);
    s.progress = .{};
    s.training_log.clearRetainingCapacity();
    try s.training_log.appendSlice(s.gpa, lab.RunLog.header);
}

/// Discards this motion's autosave and log, and trains from scratch.
fn startOver(s: *State) !void {
    var key_buffer: [48]u8 = undefined;
    z.removeValue(autosaveKey(s.task, ".weights", &key_buffer));
    z.removeValue(autosaveKey(s.task, ".log.csv", &key_buffer));
    try startTask(s, s.task, true);
    setStatus(s, "started over", .{});
}

fn initState(gpa: Allocator, f: *z.Frame, s: *State) !void {
    s.progress = .{};
    s.gpa = gpa;
    s.training_log = .empty;
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
    const physics_options: rbt.Options = geno.physicsOptions();
    s.imported = try rmj.build(gpa, &s.robot, physics_options);
    const m: *rbt.Model = &s.imported.model;
    s.ghost = try rbt.Data.init(gpa, m);
    s.recipe = .{};
    s.look = .{};
    s.floor = .{};
    s.autosave = .{};
    const actions_per_character: usize = track.actionSize(m);
    const zero_action_count: usize = s.recipe.envs * actions_per_character;
    s.zero_actions = try gpa.alloc(f32, zero_action_count);
    @memset(s.zero_actions, 0.0);

    // The networks live on the GPU; the characters on the CPU.
    s.pipe = try z.Compute(zn_mlp).initGpu(gpa, f.gpu.device, f.gpu.queue, &pipelineEntries(zn_mlp));
    // The profiler times every stage of every physics step, each reading a crossing from wasm into
    // JS - about 1,300 a frame here, for a profile nobody is looking at. Frozen, its zones return
    // before touching the clock.
    z.profiler.freeze();
    try startTask(s, .getup, false);
    // Carry on from the last run's autosave, if any; the servo is still measured first.
    const most_log_bytes: usize = s.autosave.most_log_bytes;
    const outcome: ResumeOutcome = try resumeFromAutosave(gpa, s.trainer, s.task, &s.training_log, most_log_bytes);
    switch (outcome) {
        .nothing_saved => {},
        .refused => |reason| setStatus(s, "autosave refused: {s}", .{reason}),
        .resumed => setStatus(s, "resumed from batch {d}", .{s.trainer.iterations}),
    }
}

fn deinit(gpa: Allocator, s: *State) void {
    // The trainer first - it holds the networks on the GPU host - and then the host itself, which
    // owns the buffers, bind groups and compute pipelines.
    s.trainer.deinit();
    s.pipe.deinit();
    s.clip.deinit();
    gpa.free(s.zero_actions);
    s.ghost.deinit();
    s.training_log.deinit(gpa);
    s.imported.deinit();
    s.robot.deinit();
    s.doc.deinit();
    z.unloadMesh(gpa, s.cylinder);
    z.unloadMesh(gpa, s.cube);
    z.unloadMesh(gpa, s.sphere);
    s.ui_host.deinit();
    z.unloadFont(gpa, s.font);
}

/// The servo alone - the policy's actions held at exactly zero - on the very fleet that is about
/// to train, counted the same way as the policy: steps watched against failures among them. Done
/// before learning starts, so it measures the servo and nothing else.
fn measureServo(s: *State) void {
    const p: *Progress = &s.progress;
    const fleet: *track.Fleet = s.trainer.env.fleet;
    // The servo ALONE: the root assist, which would hold up characters the servo would lose, is off while measuring.
    const scheduled_assist: f32 = fleet.options.task.gains.assist;
    fleet.options.task.gains.assist = 0;
    defer fleet.options.task.gains.assist = scheduled_assist;
    const take: u32 = @min(p.servo_left, p.per_frame);
    for (0..take) |_| {
        for (0..2) |_| {
            _ = fleet.step(s.zero_actions);
            p.servo_exposure += fleet.failures.len;
            for (fleet.failures) |lost| {
                if (lost) {
                    p.servo_failures += 1;
                }
            }
        }
    }
    p.servo_left -= take;
}

/// One finished batch into the history, and the milestones it may have reached.
fn recordBatch(s: *State, stats: ppo_track.Stats) void {
    const p: *Progress = &s.progress;
    p.last = stats;
    const index: usize = p.history_count % Progress.history_len;
    p.exposure[index] = stats.exposure;
    p.failures[index] = stats.failures;
    p.assisted[index] = stats.assist > 0;
    p.history_count += 1;
    const steps_per_second: f32 = physicsStepsPerSecond(&s.imported.model);
    const recent: Recent = recentWindow(p, steps_per_second);
    // Only whole windows of unassisted batches count: the bar is the real task. A window with no
    // failures at all has passed every milestone.
    if (recent.full and recent.unassisted) {
        const seconds: f32 = recent.mttf orelse 1.0e9;
        for (Progress.milestones, &p.milestone_seconds) |mark, *when| {
            if (when.* == 0 and seconds >= mark) {
                when.* = p.training_seconds;
            }
        }
    }
}

/// Hand the newest weights to the Save overlay, named by motion and by how many batches trained
/// them - so the newest file on the phone is obvious by its name alone.
fn offerWeights(s: *State) void {
    const bytes: []u8 = s.trainer.exportWeights(s.gpa) catch return;
    defer s.gpa.free(bytes);
    var name_buffer: [64]u8 = undefined;
    const batches: u64 = s.trainer.iterations;
    const name: []const u8 = bufPrint(&name_buffer, "{s}_ppo_b{d}.weights", .{ s.task.label(), batches }) catch return;
    z.userfile.offerDownload(bytes, name);
}

/// Weights the user picked: carried on from if they fit this network AND this motion, refused by
/// name if not.
fn takeUploads(s: *State) void {
    while (z.userfile.pendingCount() > 0) {
        const size: u32 = z.userfile.nextSize();
        const bytes: []u8 = s.gpa.alloc(u8, size) catch {
            z.userfile.discardNext();
            return;
        };
        defer s.gpa.free(bytes);
        _ = z.userfile.readNext(bytes);
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

/// The failure rate over time, in plain ASCII - a density ramp every font has - one character a
/// batch: taller is longer between losses, relative to the best window so far.
fn drawCurve(u: ui.Ui, p: *const Progress, steps_per_second: f32) void {
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
        const index: usize = (p.history_count - shown + i) % Progress.history_len;
        const batch_exposure: u64 = p.exposure[index];
        const batch_failures: u32 = p.failures[index];
        const batch_seconds: ?f32 = ppo_track.secondsToFailure(batch_exposure, batch_failures, steps_per_second);
        const seconds: f32 = @min(batch_seconds orelse 30.0, 30.0);
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

/// The numbers that say whether it is learning. Returns whether the pointer belongs to the panel,
/// so the camera leaves it alone.
fn drawPanel(s: *State, f: *z.Frame) bool {
    const u: ui.Ui = s.ui_host.begin(f);
    const steps_per_second: f32 = physicsStepsPerSecond(&s.imported.model);
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
            const recent: Recent = recentWindow(p, steps_per_second);
            const servo_exposure: u64 = p.servo_exposure;
            const servo_failures: u32 = p.servo_failures;
            const servo_seconds: ?f32 = ppo_track.secondsToFailure(servo_exposure, servo_failures, steps_per_second);
            const servo: z.Str(24) = if (servo_seconds) |seconds|
                .print("{d:.1}s", .{seconds})
            else
                .print("never", .{});
            if (p.history_count == 0) {
                u.text("servo loses it every {s}", .{servo.slice()});
            } else if (recent.mttf) |seconds| {
                u.text("loses it every {d:.1}s servo {s}", .{ seconds, servo.slice() });
            } else {
                u.text("no losses lately! servo {s}", .{servo.slice()});
            }
        }
        if (p.last.assist > 0) {
            u.text("assist {d:.2} - fading, milestones wait", .{p.last.assist});
        }
        // Minutes of training to each milestone: the number every method in the plan is judged by.
        var marks: [64]u8 = undefined;
        var at: usize = 0;
        for (Progress.milestones, p.milestone_seconds) |mark, when| {
            const piece: []const u8 = if (when > 0)
                bufPrint(marks[at..], "{d:.0}s@{d:.1}m ", .{ mark, when / 60.0 }) catch ""
            else
                bufPrint(marks[at..], "{d:.0}s@-- ", .{mark}) catch "";
            at += piece.len;
        }
        u.text("{s}", .{marks[0..at]});
        _ = u.button("save", .{});
        const save_min: Vec2 = u.getItemRectMin();
        const save_max: Vec2 = u.getItemRectMax();
        z.userfile.setSaveRect(save_min[0], save_min[1], save_max[0] - save_min[0], save_max[1] - save_min[1]);
        u.sameLine(.{});
        _ = u.button("load", .{});
        const load_min: Vec2 = u.getItemRectMin();
        const load_max: Vec2 = u.getItemRectMax();
        z.userfile.setPickerRect(
            load_min[0],
            load_min[1],
            load_max[0] - load_min[0],
            load_max[1] - load_min[1],
            ".weights,application/octet-stream",
        );
        u.sameLine(.{});
        const label: z.Str(32) = .print("-> {s}", .{s.task.other().label()});
        if (u.button(label.slice(), .{})) {
            startTask(s, s.task.other(), true) catch |err| {
                p.failed = @errorName(err);
            };
        }
        u.sameLine(.{});
        if (u.button("start over", .{})) {
            startOver(s) catch |err| {
                p.failed = @errorName(err);
            };
        }
        if (p.status_len > 0) {
            u.text("{s}", .{p.status[0..p.status_len]});
        }
        drawCurve(u, p, steps_per_second);
    }
    return captured;
}

/// A point of the robot's world, where z is up, in the drawing's, where y is up: the quarter turn about x that
/// `zm.zUpToYUp` makes, (x, y, z) to (x, z, -y).
fn yUpOf(z_up_point: Vec) Vec {
    return vec(z_up_point[0], z_up_point[2], -z_up_point[1]);
}

fn drawRobot(s: *State, gl: *z.WgpuGl, d: *const rbt.Data, tint: Color) void {
    const m: *const rbt.Model = &s.imported.model;
    const to_y_up: Mat = zm.zUpToYUp();
    for (0..m.ngeom) |g| {
        const body: u32 = m.geom_body[g];
        const body_position: Vec = d.body_xpos[body];
        const body_rot: Quat = d.body_xrot[body];
        // The geom in the world: its offset from its body, turned with the body; its rotation, after the body's.
        const offset_in_world: Vec = zm.rotate(body_rot, m.geom_pos[g]);
        const world_pos: Vec = body_position + offset_in_world;
        const world_quaternion: Quat = qmul(body_rot, m.geom_rot[g]);
        const world_rot: Mat = quatToMat(world_quaternion);
        // The same place in the drawing, where y is up.
        const world_translation: Mat = translation(world_pos[0], world_pos[1], world_pos[2]);
        const translation_drawn: Mat = mulMat(to_y_up, world_translation);
        const place: Mat = mulMat(translation_drawn, world_rot);
        switch (m.geom_shape[g]) {
            .sphere => |sph| {
                const radius: f32 = sph.radius;
                s.transform[0] = mulMat(place, scaling(radius, radius, radius));
                z.drawMeshInstanced(gl, &s.sphere, &s.transform, tint);
            },
            .box => |b| {
                const size: Vec = b.half_extent * splat(2.0);
                s.transform[0] = mulMat(place, scaling(size[0], size[1], size[2]));
                z.drawMeshInstanced(gl, &s.cube, &s.transform, tint);
            },
            .capsule => |cap| {
                // The cylinder mesh rises from its base: its base moved down half the capsule's length, then the
                // mesh stretched to the capsule's radius and whole length.
                const capsule_length: f32 = 2.0 * cap.half_height;
                const base_lowered: Mat = mulMat(place, translation(0, -cap.half_height, 0));
                s.transform[0] = mulMat(base_lowered, scaling(cap.radius, capsule_length, cap.radius));
                z.drawMeshInstanced(gl, &s.cylinder, &s.transform, tint);
            },
            else => {},
        }
    }
}

/// The floor's slab: the unit cube's center half its thickness below the top, then the cube stretched to the slab.
fn drawFloor(
    gl: *z.WgpuGl,
    cube: *z.Mesh,
    transform: *[1]Mat,
    floor: Floor,
    tint: Color,
) void {
    const center_height: f32 = floor.top - 0.5 * floor.thickness;
    const center: Mat = mulMat(zm.zUpToYUp(), translation(0, 0, center_height));
    transform[0] = mulMat(center, scaling(floor.side, floor.side, floor.thickness));
    z.drawMeshInstanced(gl, cube, transform, tint);
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
            const stats: ppo_track.Stats = s.trainer.learn();
            recordBatch(s, stats);
            const training_minutes: f32 = p.training_seconds / 60.0;
            lab.RunLog.appendLine(s.gpa, &s.training_log, s.trainer.iterations, training_minutes, stats) catch |err| {
                p.failed = @errorName(err);
            };
            offerWeights(s);
        }
        // Checked every frame, not only as a batch ends: the update a batch dispatches is read back a frame or two
        // later, and only then are the parameters and the counters beside them of the same moment.
        const log_text: []const u8 = s.training_log.items;
        const interval_seconds: f32 = s.autosave.interval_seconds;
        const has_autosaved: bool = autosaveIfDue(
            s.gpa,
            s.trainer,
            s.task,
            log_text,
            interval_seconds,
            p,
        ) catch |err| saved: {
            p.failed = @errorName(err);
            break :saved false;
        };
        if (has_autosaved) {
            setStatus(s, "autosaved batch {d}", .{s.trainer.iterations});
        }
    }

    takeUploads(s);
    z.clearViewport(f, s.look.background);
    defer s.ui_host.render(f);
    const captured: bool = drawPanel(s, f);
    // The camera follows training character 0, whom the dance carries around the room: it orbits his root.
    const root_body: usize = 1;
    const shown_character: *const rbt.Data = &s.trainer.env.fleet.data[0];
    const root_position: Vec = shown_character.body_xpos[root_body];
    s.cam.target = yUpOf(root_position);
    const cam: Camera3D = s.cam.update(f, captured, .{ .min_distance = 1.5, .max_distance = 10.0 });
    z.beginMode3D(gl, cam);
    z.drawGrid(gl, 20, 0.5);
    drawFloor(gl, &s.cube, &s.transform, s.floor, s.look.floor);

    // The reference, where training character 0 should be; then the character itself.
    const fleet: *track.Fleet = s.trainer.env.fleet;
    const frame: usize = @min(@as(usize, fleet.frame[0]), s.clip.frame_count - 1);
    @memcpy(s.ghost.pos, s.clip.pose(frame));
    s.ghost.stage = .stale;
    rbt.kinematics(m, &s.ghost);
    drawRobot(s, gl, &s.ghost, s.look.reference);
    drawRobot(s, gl, &fleet.data[0], s.look.character);
    z.endMode3D(gl);
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
