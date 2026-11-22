//! geno_trainer - Geno trained to track the dance, headless, in a run folder: the training that runs for hours.
//!
//! A run is a folder. The trainer reads the run's parameters from its `run.zon` (`robot_lab.GenoRun`: the task, the
//! learner with its recipe, the run's own controls), trains as
//! fast as the GPU and the CPU allow - no window, no frames - and writes what it learns into the same folder, so that
//! another program can watch the run while it goes. It trains PPO (DReCon's controller) and SuperTrack, each on a
//! path of its own; a run that chose EfficientTDMPC is refused by name until it joins. A PPO run's folder:
//!
//!     run.zon          the parameters; written with the defaults when the folder has none
//!     weights          the newest weights (`ppo_track.Trainer.exportWeights`), rewritten whole every few minutes
//!     weights_b<N>     a checkpoint: the weights after batch N, kept every so many minutes
//!     policy           the newest policy (`robot_lab.PolicyFile`), written with the weights - what the lab plays
//!     policy_m<N>      a checkpoint: the policy after N minutes of training, kept with the weights' checkpoint
//!     log.csv          one line per batch, raw counts (steps watched, failures, reward, episodes, assist)
//!     status.zon       where the run is: its state, batches, minutes, the servo's and the recent time to failure
//!     stop             created by anyone: the trainer saves everything and exits
//!
//! A SuperTrack run's folder holds the same `run.zon`, `status.zon` and `stop`, with its own state, logs and
//! checkpoints:
//!
//!     supertrack_state       the whole learner (`Resident.exportState`): networks, Adam's moments, counters, random
//!                            stream - rewritten whole every few minutes
//!     supertrack_state_m<N>  a checkpoint of it after N minutes, the newest four of this start kept
//!     policy, policy_m<N>    the newest policy and its checkpoints - a flow run's with its flow correcting it
//!     log.csv                one line per round, a column for every number the learner keeps
//!                            (`robot_lab.SuperTrackLog`)
//!     judge.csv              every judgement, a line per clip, the servo's first (`robot_lab.JudgeLog`)
//!     recovery.csv           every judgement's probe, a line per clip and push speed: survived, lost, returned
//!                            (`robot_lab.RecoveryLog`)
//!     status.zon             also says what stopped being finite in a run the watchdog stopped, the tripwire that
//!                            stopped a run learning nothing (`lab.Tripwire`), and the clip whose policy collapsed,
//!                            when one has
//!
//! Every file is written whole to `<name>.new` and renamed over the old one, so a reader never sees half a file and
//! a run stopped in the middle of a write keeps the previous version. Started again on the same folder, the trainer
//! carries on from the folder's weights and log; weights that do not fit the run's network (another width, another
//! motion) are refused, and the folder is left untouched. The run ends when its `stop` file appears, or after the
//! hours or batches `run.zon` allows; then the last weights, the log and the status are written, and the program
//! exits 0. It exits 1 when it refuses the run - an unreadable `run.zon`, a value out of its range
//! (`robot_lab.GenoRun.problem`), weights that do not fit - and 2 when the run fails: the GPU or the robot cannot be
//! set up, a file cannot be written, something stopped being finite (the watchdog; the status names it, and the
//! state saved before it is kept), or a tripwire fired after the first rounds - a run that learns nothing (the status
//! names it, and the state is saved as it stood).
//!
//! A run's folder belongs outside the repository: what a run writes is large and is not source. The recipes kept in
//! the repository are `examples/geno_lab/recipes/<name>.zon`, each copied into a new folder as its `run.zon`:
//!
//!     geno_trainer --run=../geno_runs/first_run

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;
const sortSlice = std.mem.sort;
const lessThan = std.mem.lessThan;
const parseFloat = std.fmt.parseFloat;
const parseInt = std.fmt.parseInt;
const splitScalar = std.mem.splitScalar;
const basename = std.fs.path.basename;
const copyForwards = std.mem.copyForwards;
const z = @import("zimr");
const zm = @import("zm");
const maxInt = zm.maxInt;
const assertf = zm.assertf;
const float = zm.float;
const float64 = zm.float64;
const cli = @import("cli");
const zn_mlp = @import("zn_mlp");
/// The kernels at the pages' sizes, for their CPU twin alone: the other side of the check at a run's start
/// (`checkKernelsAtStart`).
const zn_mlp_twin = @import("zn_mlp_twin");
const robotgpu = @import("robotgpu");
const robotgpu_host = @import("robotgpu_host");

const wgpu = z.wgpu;
const vulkan_host = wgpu.vulkan_host;
const codecs = z.codecs;
const rbt = z.robot;
const rmj = z.robot_mjcf;
const mjcf = z.mjcf;
const dance = z.robot_dance;
const track = z.robot_track;
const ppo_track = z.robot_ppo_track;
const geno = z.robot_geno;
const lab = z.robot_lab;
const native_os = z.native_os;
const readWhole = native_os.readWhole;
const writeWhole = native_os.writeWhole;
const fileExists = native_os.fileExists;
const Trainer = ppo_track.Trainer(zn_mlp);
const resident = z.robot_track_resident;
const latent = z.robot_latent;
const latent_kit = z.robot_latent_kit;
const SuperTrackLearner = resident.Resident(zn_mlp);
const eql = std.mem.eql;
const clamp = zm.clamp;
const Random = std.Random;

/// The network kernels' SPIR-V: one module holding every entry of `zn_mlp`.
const zn_mlp_spirv: []const u8 = @embedFile("zn_mlp_spv");
/// The simulator's kernels' SPIR-V: one module holding every entry of `robotgpu`, for a run whose characters are
/// simulated on the device (`lab.TrainingPhysics.device`).
const robotgpu_spirv: []const u8 = @embedFile("robotgpu_spv");
/// The dance, retargeted to Geno and baked (`zig build clip-bake`), as the training page embeds it.
const dance_zclip: []const u8 = @embedFile("geno_dance_zclip");
/// LAFAN1's whole fall and get-up take on Geno (`robot_geno`'s bake), the second clip of a `dance_and_getup` run.
const getup_zclip: []const u8 = @embedFile("geno_getup_zclip");
/// Walking and running on Geno (`robot_geno`'s bake): the rest of a `one_minute` run.
const walk_zclip: []const u8 = @embedFile("geno_walk_zclip");
const run_zclip: []const u8 = @embedFile("geno_run_zclip");
/// Each clip's mirror image, baked beside it (`robot_geno.copyMirroredClip`): a run's mirrored variants.
const dance_mirrored_zclip: []const u8 = @embedFile("geno_dance_mirrored_zclip");
const getup_mirrored_zclip: []const u8 = @embedFile("geno_getup_mirrored_zclip");
const walk_mirrored_zclip: []const u8 = @embedFile("geno_walk_mirrored_zclip");
const run_mirrored_zclip: []const u8 = @embedFile("geno_run_mirrored_zclip");

/// How the trainer ends, as its exit code tells whoever started it: `robot_lab`'s, so the training lab reads the
/// code by the same definition.
const Exit = lab.TrainerExit;

// ---- The run folder ----
//
// The folder's files, their names and the log's columns are `robot_lab`'s (`RunFile`, `RunLog`): the training lab
// reads what this program writes, by the same definitions.

const RunFile = lab.RunFile;
const RunLog = lab.RunLog;

const RunState = lab.RunState;
const RunStatus = lab.RunStatus;

/// The path of `name` in the run folder, in `arena`.
fn pathIn(
    arena: Allocator,
    folder: []const u8,
    name: []const u8,
) Allocator.Error![]const u8 {
    return std.fs.path.join(arena, &.{ folder, name });
}

/// The path of the run file `file` in the run folder, in `arena`.
fn runFilePath(
    arena: Allocator,
    folder: []const u8,
    file: RunFile,
) Allocator.Error![]const u8 {
    return pathIn(arena, folder, file.fileName());
}

/// Prints one line of the run's progress.
fn say(io: Io, comptime format: []const u8, arguments: anytype) void {
    var line_buffer: [512]u8 = undefined;
    const line: []const u8 = bufPrint(&line_buffer, format ++ "\n", arguments) catch return;
    Io.File.stdout().writeStreamingAll(io, line) catch return;
}

/// The run's parameters from the folder's `run.zon` (`lab.GenoRun`) - written
/// there with every default when the folder has none, so that every run folder states what it trains, its learner
/// included. Null, after saying why, when the file cannot be read
/// as a run. Memory: two allocators, as the ZON parser takes them (`lab.GenoRun.parse`) - `gpa` the parser's working
/// memory, freed before it returns; `arena` everything else, the caller's scratch: the file's text, its path, a
/// default run's text, a refusal's description. The run returned is plain values, pointing into neither.
fn readRunParameters(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
) !?lab.GenoRun {
    const run_path: []const u8 = try runFilePath(arena, folder, .parameters);
    const source: []u8 = try readWhole(arena, io, run_path, RunFile.most_bytes) orelse {
        const defaults: lab.GenoRun = .{};
        var text: Io.Writer.Allocating = .init(arena);
        try defaults.write(&text.writer);
        try text.writer.writeAll("\n");
        try writeWhole(arena, io, run_path, text.written());
        const run_file_name: []const u8 = RunFile.parameters.fileName();
        say(io, "geno_trainer: no {s} in {s} - wrote one with every default", .{ run_file_name, folder });
        return defaults;
    };
    const terminated_source: [:0]const u8 = try arena.dupeSentinel(u8, source, 0);
    var failure: lab.GenoRun.ParseFailure = .{ .description = "" };
    return lab.GenoRun.parse(gpa, arena, terminated_source, &failure) catch |err| switch (err) {
        error.ParseZon => {
            say(io, "geno_trainer: refused: {s}", .{failure.description});
            return null;
        },
        error.OutOfMemory => err,
    };
}

// ---- Counting failures ----

/// Physics steps per second of the trainer's Geno: what turns steps watched into seconds of character-time.
fn physicsStepsPerSecond(trainer: *const Trainer) f32 {
    return 1.0 / trainer.m.opt.timestep;
}

/// The recent batches' steps watched and failures, kept in a ring.
const RecentBatches = struct {
    /// How many recent batches the recent time to failure is estimated over: the log's own window, the same for the
    /// page and the lab's curves.
    const window_batches: usize = RunLog.window_batches;

    steps_watched: [window_batches]u64 = @splat(0),
    failures: [window_batches]u32 = @splat(0),
    count: usize = 0,

    fn add(self: *RecentBatches, stats: ppo_track.Stats) void {
        const slot: usize = self.count % window_batches;
        self.steps_watched[slot] = stats.exposure;
        self.failures[slot] = stats.failures;
        self.count += 1;
    }

    /// Seconds between failures over the window (`ppo_track.secondsToFailure`); null while nothing in it failed.
    fn secondsToFailure(self: *const RecentBatches, physics_steps_per_second: f32) ?f32 {
        var steps_watched: u64 = 0;
        var failures: u64 = 0;
        const counted: usize = @min(self.count, window_batches);
        for (0..counted) |slot| {
            steps_watched += self.steps_watched[slot];
            failures += self.failures[slot];
        }
        return ppo_track.secondsToFailure(steps_watched, failures, physics_steps_per_second);
    }
};

// ---- The run ----

/// A MOMENT ON A RUN's CLOCK: the wall clock and the time the machine's share has rested the device so far
/// (`z.MachineShare`), read together. Two readings give the working time between them - the wall time less the rests
/// - which is what a run's clock counts: its time limits, its curriculum by hours, its saves and its logged times
/// follow the work done, whatever share of the machine the run had. Without a share no rest is ever taken, and the
/// working time is the wall time.
const ClockReading = struct {
    wall_ms: f64 = 0,
    slept_ms: f64 = 0,

    fn now(machine_share: ?*const z.MachineShare) ClockReading {
        const slept_ms: f64 = if (machine_share) |share| share.slept_ms else 0;
        const reading: ClockReading = .{ .wall_ms = wgpu.nowMs(), .slept_ms = slept_ms };
        return reading;
    }

    /// The working milliseconds from `earlier` to `later`: the wall time between them less the rests in it.
    fn workingMsSince(later: ClockReading, earlier: ClockReading) f64 {
        const wall_ms: f64 = later.wall_ms - earlier.wall_ms;
        const rested_ms: f64 = later.slept_ms - earlier.slept_ms;
        return wall_ms - rested_ms;
    }
};

/// Where a run is between batches: its log, its recent failures, the servo's measure, and when it last saved,
/// checkpointed and reported. Plain state - no allocator, no `Io`, no trainer: the functions below take those, and
/// the run's folder, as their arguments.
const RunProgress = struct {
    /// The run's clip, as the judge's and the probe's lines name it: its motion's label.
    clip_label: []const u8 = "dance",
    log: ArrayList(u8) = .empty,
    recent: RecentBatches = .{},
    servo_seconds_to_failure: ?f32 = null,
    last_stats: ppo_track.Stats = .{ .decisions = 0, .steps = 0, .mean_reward = 0, .episodes = 0, .mean_episode = 0 },
    /// The machine's share the run keeps to, whose rests its clock leaves out (`ClockReading`); null for a run that
    /// takes the whole machine.
    machine_share: ?*const z.MachineShare = null,
    /// The clock when training started, and the minutes trained before it by earlier starts.
    started: ClockReading = .{},
    minutes_before_this_start: f32 = 0,
    /// Whether this start has saved yet: its first batch always does, so that a run restarted by hand shows its new
    /// start at once.
    has_saved_this_start: bool = false,
    /// Whether this start's first policy file was read back and found to play as the trainer acts
    /// (`policyPlaysAsTrained`).
    has_checked_policy_this_start: bool = false,
    saved_at_minutes: f32 = 0,
    checkpointed_at_minutes: f32 = 0,
    /// The run's judgements as `judge.csv` holds them (`lab.JudgeLog`): the servo's line, then one per judgement of
    /// the newest policy - grown with the program's `gpa`, and freed with the log.
    judgements: ArrayList(u8) = .empty,
    /// The run's recovery probes as `recovery.csv` holds them (`lab.RecoveryLog`): the servo's lines, then one set
    /// per judgement.
    recoveries: ArrayList(u8) = .empty,
    judged_at_minutes: f32 = 0,
    /// Wall-clock milliseconds of the last progress line printed (`reportProgress`).
    reported_at_ms: f64 = 0,
};

/// The minutes the run has trained, over every start: working minutes, the machine's share's rests left out.
fn trainingMinutes(progress: *const RunProgress) f32 {
    const elapsed_ms: f64 = ClockReading.now(progress.machine_share).workingMsSince(progress.started);
    const elapsed_minutes: f32 = @floatCast(elapsed_ms / 60_000.0);
    return progress.minutes_before_this_start + elapsed_minutes;
}

/// The folder's `status.zon`: where the run is, written whole.
fn saveStatus(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *const Trainer,
    progress: *const RunProgress,
    state: RunState,
) !void {
    const status: RunStatus = .{
        .state = state,
        .batches = trainer.iterations,
        .steps = trainer.steps,
        .training_minutes = trainingMinutes(progress),
        .servo_seconds_to_failure = progress.servo_seconds_to_failure,
        .recent_seconds_to_failure = progress.recent.secondsToFailure(physicsStepsPerSecond(trainer)),
        .assist = progress.last_stats.assist,
        .written_at_seconds = native_os.wallClockSeconds(io),
    };
    var text: Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(status, .{}, &text.writer);
    try text.writer.writeAll("\n");
    const status_path: []const u8 = try runFilePath(arena, folder, .status);
    try writeWhole(arena, io, status_path, text.written());
}

/// The run's policy (`lab.GenoPolicy`): PPO's actor made from the trainer's latest readback - the parameters the
/// weights file holds, not the actor's CPU copy, which can lag the readback by an update - with its normaliser and
/// the controller's range, scale and filter. Memory: the policy's arrays are in `arena`, the caller's scratch - freed
/// with it, nothing to `deinit`.
fn trainerPolicy(arena: Allocator, trainer: *Trainer) !lab.GenoPolicy {
    const params: []const f32 = trainer.ppo.pipe.readLatest(.params) orelse {
        return error.NoReadback;
    };
    if (params.len < trainer.ppo.param_count) {
        return error.NoReadback;
    }
    const parts: lab.PpoPolicyParts = .{
        .kit_parameters = params,
        .actor_layer_offsets = trainer.ppo.p_off,
        .observation_size = trainer.n_obs,
        .hidden_width = trainer.options.hidden,
        .action_size = trainer.env.subset.dofs,
        .observation_normalizer = if (trainer.options.normalize) trainer.observation_normalizer else null,
        .action_limit = trainer.env.options.action_limit,
        .action_scale = trainer.env.options.action_scale,
        .filter_beta = trainer.env.options.beta,
        .decimation = trainer.env.options.decimation,
    };
    return lab.policyOfPpo(arena, parts);
}

/// The run's policy (`trainerPolicy`) written in the folder under `name` (`lab.PolicyFile`): a new file, renamed over
/// any old one. Memory: the policy, its file's bytes and the path in `arena`, the caller's scratch.
fn savePolicy(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    name: []const u8,
) !void {
    const policy: lab.GenoPolicy = try trainerPolicy(arena, trainer);
    const bytes: []u8 = try lab.PolicyFile.encode(arena, &policy);
    const path: []const u8 = try pathIn(arena, folder, name);
    try writeWhole(arena, io, path, bytes);
}

/// Whether the folder's policy file plays as the trainer acts: read back, decoded, and asked for its action on every
/// environment's observation now, against the trainer's own answer - its normaliser, its actor's mean on the same
/// parameters (the actor's CPU copy brought to the readback first, `syncWeights`), the controller's clamp - bit for
/// bit. Run once a start, after the first save: a policy file that plays otherwise is the program's fault, not the
/// training's, and the run fails rather than leave a file the lab would play wrongly. Memory: the file, the policy
/// and the buffers in `arena`, the caller's scratch.
fn policyPlaysAsTrained(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
) !bool {
    _ = trainer.ppo.syncWeights();
    const path: []const u8 = try pathIn(arena, folder, RunFile.policy_name);
    const bytes: []u8 = try native_os.readWhole(arena, io, path, RunFile.most_bytes) orelse {
        return false;
    };
    const policy: lab.GenoPolicy = try lab.PolicyFile.decode(arena, bytes);
    const observation: []f32 = try arena.alloc(f32, trainer.n_obs);
    const normalized: []f32 = try arena.alloc(f32, trainer.n_obs);
    const trainer_action: []f32 = try arena.alloc(f32, trainer.env.subset.dofs);
    const policy_action: []f32 = try arena.alloc(f32, trainer.env.subset.dofs);
    const scratch: lab.PolicyScratch = try .init(arena, &policy);
    const limit: f32 = trainer.env.options.action_limit;
    for (0..trainer.env.options.envs) |env| {
        trainer.env.observe(env, observation);
        @memcpy(normalized, observation);
        trainer.normalizeObservation(normalized);
        trainer.ppo.actMean(normalized, trainer_action);
        for (trainer_action) |*component| {
            component.* = clamp(component.*, -limit, limit);
        }
        lab.policyMeanAction(&policy, observation, &.{}, scratch, policy_action);
        if (!eql(f32, trainer_action, policy_action)) {
            return false;
        }
    }
    return true;
}

/// The newest weights, the policy, the log and the status, each written whole. Memory: all of it in `arena` - the
/// weights' bytes, the policy and its file, the paths - scratch for this save, which the caller resets after it.
fn saveAll(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    progress: *RunProgress,
    state: RunState,
) !void {
    // The parameters read back, and the counters beside them, of the same update.
    trainer.waitForReadback();
    const weights_bytes: []u8 = try trainer.exportWeights(arena);
    const weights_path: []const u8 = try runFilePath(arena, folder, .weights);
    try writeWhole(arena, io, weights_path, weights_bytes);
    try savePolicy(arena, io, folder, trainer, RunFile.policy_name);
    const log_path: []const u8 = try runFilePath(arena, folder, .log);
    try writeWhole(arena, io, log_path, progress.log.items);
    try saveStatus(arena, io, folder, trainer, progress, state);
    progress.has_saved_this_start = true;
    progress.saved_at_minutes = trainingMinutes(progress);
}

/// The weights kept as a checkpoint under the batch that trained them, `weights_b<N>`, and the policy under the
/// minute of training, `policy_m<N>`. Memory: the weights' bytes, the policy and the paths in `arena`, the caller's
/// scratch.
fn saveCheckpoint(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    progress: *RunProgress,
) !void {
    trainer.waitForReadback();
    const weights_bytes: []u8 = try trainer.exportWeights(arena);
    var name_buffer: RunFile.NameBuffer = undefined;
    const name: []const u8 = RunFile.checkpointName(trainer.iterations, &name_buffer);
    const checkpoint_path: []const u8 = try pathIn(arena, folder, name);
    try writeWhole(arena, io, checkpoint_path, weights_bytes);
    const minutes: f32 = trainingMinutes(progress);
    const whole_minutes: u64 = @floor(minutes);
    var policy_name_buffer: RunFile.NameBuffer = undefined;
    const policy_name: []const u8 = RunFile.policyCheckpointName(whole_minutes, &policy_name_buffer);
    try savePolicy(arena, io, folder, trainer, policy_name);
    progress.checkpointed_at_minutes = minutes;
}

/// Whether the run must end now, and how: its folder's `stop` file, or its limits.
fn endState(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    parameters: lab.PpoRun,
    trainer: *const Trainer,
    progress: *const RunProgress,
) !?RunState {
    const stop_path: []const u8 = try runFilePath(arena, folder, .stop);
    if (fileExists(io, stop_path)) {
        return .stopped;
    }
    const hours_trained: f32 = trainingMinutes(progress) / 60.0;
    const hour_limit: f32 = parameters.stop_after_hours;
    const batch_limit: u64 = parameters.stop_after_batches;
    const is_past_hours: bool = hour_limit > 0 and hours_trained >= hour_limit;
    const is_past_batches: bool = batch_limit > 0 and trainer.iterations >= batch_limit;
    return if (is_past_hours or is_past_batches) .finished else null;
}

/// Column `column_index` (from 0) of the log's last line, or null when the log has no such column - an empty log, or
/// one whose last line is its header.
fn lastLoggedColumn(log_text: []const u8, column_index: usize) ?[]const u8 {
    const trimmed: []const u8 = std.mem.trimEnd(u8, log_text, "\n");
    const last_newline: ?usize = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
    const last_line_start: usize = if (last_newline) |newline| newline + 1 else 0;
    const last_line: []const u8 = trimmed[last_line_start..];
    var columns: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, last_line, ',');
    for (0..column_index) |_| {
        _ = columns.next() orelse return null;
    }
    return columns.next();
}

/// The training minutes on the log's last line - its second column, in every learner's log - or zero for a log with
/// no lines yet.
fn lastLoggedMinutes(log_text: []const u8) f32 {
    const minutes_text: []const u8 = lastLoggedColumn(log_text, 1) orelse return 0;
    return parseFloat(f32, minutes_text) catch 0;
}

/// What a recovery probe (or a judgement) puts through its pushes: the servo alone, a policy file's policy, or a
/// learner's own judging actor - a flow run's (`judgesWithLearnerActor`).
const ProbedController = union(enum) {
    servo,
    policy: *const lab.GenoPolicy,
    learner_actor: LearnerActor,

    /// A learner acting itself, and the fleet it is judged on: the judge's task at the learner's own action scale,
    /// clock and action - its limbs' stiffnesses where its run has them (`learnerJudgeFleet`).
    const LearnerActor = struct {
        actor: track.Actor,
        fleet_options: track.Fleet.Options,
    };
};

/// THE FLEET A SUPERTRACK LEARNER IS JUDGED ON WHEN IT ACTS ITSELF (`ProbedController.learner_actor`): the judge's
/// task, and the learner's own action scale, clock and action width - a run whose action carries a stiffness per limb
/// is judged with it, each limb's servo at the stiffness the policy gives. Everything else is a fleet's default: no
/// pushes but the probe's own, no aftermath, no curriculum.
fn learnerJudgeFleet(
    settings: lab.SuperTrackLearner,
    task: track.Task,
    body_names: []const []const u8,
) track.Fleet.Options {
    return .{
        .action_scale = settings.action_scale,
        .task = task,
        .body_names = body_names,
        .decide_every = settings.decide_every,
        .limb_stiffness = settings.limb_stiffness,
    };
}

/// The recovery probe of `policy` - or of the servo alone - on the judge's starts (`lab.probePolicy`, every band of the
/// probe's push speeds), its lines added to `recoveries` (the header first, when it is empty) and `recovery.csv`
/// rewritten whole, and each band's survival said. Read beside the judge: the judge says how long the policy keeps the
/// reference undisturbed, the probe how it comes back when pushed. Memory: the actor in `arena`; the probe's fleets
/// with `gpa`, freed before it returns; the lines grow in `recoveries` with `gpa`, as its owner's.
fn probeAndRecord(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    model: *rbt.Model,
    body_names: []const []const u8,
    clip: *const dance.Clip,
    clip_label: []const u8,
    probed: ProbedController,
    judge_settings: lab.PolicyJudgeSettings,
    probe: track.RecoveryProbe,
    recoveries: *ArrayList(u8),
    batches: u64,
    minutes: f32,
) !void {
    const bands: []track.RecoveryBand = try arena.alloc(track.RecoveryBand, probe.speeds.len);
    switch (probed) {
        .servo => try lab.probePolicy(gpa, arena, model, body_names, clip, null, judge_settings, probe, bands),
        .policy => |policy| {
            try lab.probePolicy(gpa, arena, model, body_names, clip, policy, judge_settings, probe, bands);
        },
        .learner_actor => |learner_actor| {
            // The learner's own fleet under the judge's task, acted on by the learner itself.
            try track.probeRecovery(
                gpa,
                model,
                clip,
                learner_actor.fleet_options,
                judge_settings.starts,
                learner_actor.actor,
                probe,
                bands,
            );
        },
    }
    if (recoveries.items.len == 0) {
        try recoveries.appendSlice(gpa, lab.RecoveryLog.header);
    }
    try lab.RecoveryLog.appendLines(gpa, recoveries, batches, minutes, clip_label, bands);
    const recoveries_path: []const u8 = try runFilePath(arena, folder, .recoveries);
    try writeWhole(arena, io, recoveries_path, recoveries.items);
    const probed_controller: []const u8 = switch (probed) {
        .servo => "the servo",
        .policy => "the policy",
        .learner_actor => "the learner's actor",
    };
    for (bands) |band| {
        const probe_format: []const u8 = "recovery probe, {s}: pushed {d:.1} m/s, {d} pushes" ++
            " - survived {d:.2}, tracking back {d:.2} in {d:.2} s";
        say(io, probe_format, .{
            probed_controller,
            band.speed,
            band.pushes,
            band.survivalRate(),
            band.recoveryRate(),
            band.meanRecoverySeconds(),
        });
        if (band.returned == 0) {
            continue;
        }
        const return_format: []const u8 = "recovery probe, {s}: pushed {d:.1} m/s - {d} of {d} losses returned, in" ++
            " {d:.2} s, the action changing {d:.2} a second, the root's jerk {d:.0} m/s^3";
        say(io, return_format, .{
            probed_controller,
            band.speed,
            band.returned,
            band.lost,
            band.meanReturnSeconds(),
            band.meanReturnActionRate(),
            band.meanReturnJerk(),
        });
    }
}

/// The newest policy judged (`lab.judgePolicy`: fixed starts a second apart across the run's clip, the mean action,
/// nothing random), its line added to the run's judgements and `judge.csv` rewritten whole - and, before the first,
/// the servo alone judged on the same starts: the baseline every judgement is read against. Memory: the policy, the
/// judge's actor and the starts in `arena`, the caller's scratch; the judge's fleet with `gpa`, freed before it
/// returns; the judgements' text grows in `progress.judgements` with `gpa`, as `progress` owns it.
fn judgeNewestPolicy(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    progress: *RunProgress,
) !void {
    trainer.waitForReadback();
    const fleet: *track.Fleet = trainer.env.fleet;
    const clip: *const dance.Clip = fleet.clips[0];
    const frames_per_second: usize = 60;
    const starts: []usize = try track.evenStarts(arena, clip, frames_per_second);
    const settings: lab.PolicyJudgeSettings = .{
        .starts = starts,
        .task = trainer.options.task,
        .bodies = trainer.options.bodies,
    };
    const body_names: []const []const u8 = fleet.options.body_names;
    const whole_clip_start = [_]usize{1};
    var whole_settings: lab.PolicyJudgeSettings = settings;
    whole_settings.starts = &whole_clip_start;
    var whole_label_buffer: [80]u8 = undefined;
    const whole_label: []const u8 = try bufPrint(&whole_label_buffer, "{s}/whole", .{progress.clip_label});
    if (progress.judgements.items.len == 0) {
        try progress.judgements.appendSlice(gpa, lab.JudgeLog.header);
        const servo: track.Judgement = try lab.judgePolicy(gpa, arena, trainer.m, body_names, clip, null, settings);
        try lab.JudgeLog.appendLine(gpa, &progress.judgements, 0, 0, progress.clip_label, servo);
        // SUPERMIMIC'S EVALUATION: the whole clip from its first frame a start is defined at, one start - recorded as
        // the clip's "/whole" line, from which its normalised return and whether it reached the end are read.
        const servo_whole: track.Judgement =
            try lab.judgePolicy(gpa, arena, trainer.m, body_names, clip, null, whole_settings);
        try lab.JudgeLog.appendLine(gpa, &progress.judgements, 0, 0, whole_label, servo_whole);
        try probeAndRecord(
            gpa,
            arena,
            io,
            folder,
            trainer.m,
            body_names,
            clip,
            progress.clip_label,
            .servo,
            settings,
            (lab.GenoControls{}).probe,
            &progress.recoveries,
            0,
            0,
        );
    }
    const policy: lab.GenoPolicy = try trainerPolicy(arena, trainer);
    const judgement: track.Judgement = try lab.judgePolicy(gpa, arena, trainer.m, body_names, clip, &policy, settings);
    const minutes: f32 = trainingMinutes(progress);
    try lab.JudgeLog.appendLine(gpa, &progress.judgements, trainer.iterations, minutes, progress.clip_label, judgement);
    const whole: track.Judgement =
        try lab.judgePolicy(gpa, arena, trainer.m, body_names, clip, &policy, whole_settings);
    try lab.JudgeLog.appendLine(gpa, &progress.judgements, trainer.iterations, minutes, whole_label, whole);
    const batches: u64 = trainer.iterations;
    const recoveries: *ArrayList(u8) = &progress.recoveries;
    try probeAndRecord(
        gpa,
        arena,
        io,
        folder,
        trainer.m,
        body_names,
        clip,
        progress.clip_label,
        .{ .policy = &policy },
        settings,
        (lab.GenoControls{}).probe,
        recoveries,
        batches,
        minutes,
    );
    const judgements_path: []const u8 = try runFilePath(arena, folder, .judgements);
    try writeWhole(arena, io, judgements_path, progress.judgements.items);
    progress.judged_at_minutes = minutes;
    const error_seconds: f32 = judgement.meanTimeToFailureError() orelse 0;
    say(io, "judged at batch {d}: loses the reference every {d:.2} s (standard error {d:.2} s), {d} of {d} starts\n", .{
        trainer.iterations,
        judgement.meanTimeToFailure(),
        error_seconds,
        judgement.failures,
        judgement.starts,
    });
}

/// The minutes of training at the judgements' last line (`lab.JudgeLog`); zero when there is none.
fn lastJudgedMinutes(judgements_text: []const u8) f32 {
    var last_minutes: f32 = 0;
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, judgements_text, '\n');
    while (lines.next()) |line| {
        const judged: lab.JudgeLog.Line = lab.JudgeLog.parseLine(line) orelse continue;
        last_minutes = judged.training_minutes;
    }
    return last_minutes;
}

/// Carries the run on from the folder's weights and log, when it has them. False, after saying why, when the weights
/// do not fit this run's network - the run is then refused, and nothing in the folder is overwritten.
/// Memory: two allocators for two lifetimes - the folder's files are read into `arena`, the caller's scratch for
/// this start; the run's log is copied into `progress.log` with `gpa`, which `progress` owns and keeps growing for
/// the rest of the run.
fn resumeFromFolder(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    progress: *RunProgress,
) !bool {
    const weights_path: []const u8 = try runFilePath(arena, folder, .weights);
    const weights_bytes: []u8 = try readWhole(arena, io, weights_path, RunFile.most_bytes) orelse return true;
    trainer.importWeights(weights_bytes) catch |err| {
        say(io, "geno_trainer: refused: the folder's weights do not fit this run ({s})", .{@errorName(err)});
        return false;
    };
    const log_path: []const u8 = try runFilePath(arena, folder, .log);
    const judgements_path: []const u8 = try runFilePath(arena, folder, .judgements);
    if (try readWhole(arena, io, judgements_path, RunFile.most_bytes)) |saved_judgements| {
        progress.judgements.clearRetainingCapacity();
        try progress.judgements.appendSlice(gpa, saved_judgements);
        progress.judged_at_minutes = lastJudgedMinutes(saved_judgements);
    }
    if (try readWhole(arena, io, log_path, RunFile.most_bytes)) |saved_log| {
        progress.log.clearRetainingCapacity();
        try progress.log.appendSlice(gpa, saved_log);
        // The minutes already trained: the last line's second column.
        progress.minutes_before_this_start = lastLoggedMinutes(saved_log);
    }
    say(io, "geno_trainer: resumed from batch {d}", .{trainer.iterations});
    return true;
}

/// The servo alone, before any training, counted the way the policy is: steps watched against failures, over 96
/// decisions of every character - with the root assist off, which would otherwise hold up characters the servo alone
/// would lose.
fn measureServo(
    trainer: *Trainer,
    physics_steps_per_decision: u32,
    zero_actions: []const f32,
) ?f32 {
    const fleet: *track.Fleet = trainer.env.fleet;
    const scheduled_assist: f32 = fleet.options.task.gains.assist;
    fleet.options.task.gains.assist = 0;
    defer fleet.options.task.gains.assist = scheduled_assist;
    const servo_decisions: u32 = 96;
    var steps_watched: u64 = 0;
    var failures: u64 = 0;
    const servo_physics_steps: usize = servo_decisions * physics_steps_per_decision;
    for (0..servo_physics_steps) |_| {
        _ = fleet.step(zero_actions);
        steps_watched += fleet.failures.len;
        for (fleet.failures) |is_lost| {
            if (is_lost) {
                failures += 1;
            }
        }
    }
    return ppo_track.secondsToFailure(steps_watched, failures, physicsStepsPerSecond(trainer));
}

/// A line of progress, at most every `report_interval_ms` (`--report-seconds`): the run's folder name - several
/// trainers started by the lab share its console -, the batch, the minutes trained, the reward, and the time to
/// failure over the recent window - or that nothing in the window failed.
fn reportProgress(
    io: Io,
    report_interval_ms: f64,
    folder: []const u8,
    trainer: *const Trainer,
    progress: *RunProgress,
    stats: ppo_track.Stats,
) void {
    const now_ms: f64 = wgpu.nowMs();
    const is_first_report: bool = progress.reported_at_ms == 0;
    const since_report_ms: f64 = now_ms - progress.reported_at_ms;
    const is_report_due: bool = is_first_report or since_report_ms >= report_interval_ms;
    if (!is_report_due) {
        return;
    }
    progress.reported_at_ms = now_ms;
    var failure_buffer: [48]u8 = undefined;
    const recent_seconds: ?f32 = progress.recent.secondsToFailure(physicsStepsPerSecond(trainer));
    const failure_text: []const u8 = if (recent_seconds) |seconds|
        bufPrint(&failure_buffer, "loses the reference every {d:.2} s", .{seconds}) catch "?"
    else
        "no losses in the recent batches";
    const run_name: []const u8 = basename(folder);
    say(io, "{s}  batch {d}  {d:.1} min  {d} steps  reward {d:.3}  assist {d:.2}  {s}", .{
        run_name,
        trainer.iterations,
        trainingMinutes(progress),
        trainer.steps,
        stats.mean_reward,
        stats.assist,
        failure_text,
    });
}

/// Trains until the folder's `stop` file appears or the run's limits are reached, saving as it goes; the state it
/// ended in.
fn train(
    gpa: Allocator,
    io: Io,
    report_interval_ms: f64,
    arena_state: *ArenaAllocator,
    folder: []const u8,
    parameters: lab.PpoRun,
    trainer: *Trainer,
    progress: *RunProgress,
) !RunState {
    const decisions_per_collect: u32 = 64;
    const save_minutes: f32 = parameters.save_minutes;
    const checkpoint_minutes: f32 = parameters.checkpoint_minutes;
    const judge_minutes: f32 = parameters.judge_minutes;
    while (true) {
        // Paths and texts of one batch's files are made in the arena, emptied every batch.
        _ = arena_state.reset(.retain_capacity);
        const arena: Allocator = arena_state.allocator();
        if (try endState(arena, io, folder, parameters, trainer, progress)) |end_state| {
            return end_state;
        }
        if (!trainer.collect(decisions_per_collect)) {
            continue;
        }
        const stats: ppo_track.Stats = trainer.learn();
        progress.last_stats = stats;
        progress.recent.add(stats);
        const minutes_trained: f32 = trainingMinutes(progress);
        try RunLog.appendLine(gpa, &progress.log, trainer.iterations, minutes_trained, stats);
        const minutes: f32 = trainingMinutes(progress);
        const minutes_since_save: f32 = minutes - progress.saved_at_minutes;
        const is_save_due: bool = !progress.has_saved_this_start or minutes_since_save >= save_minutes;
        if (is_save_due) {
            try saveAll(arena, io, folder, trainer, progress, .training);
        }
        if (progress.has_saved_this_start and !progress.has_checked_policy_this_start) {
            if (!try policyPlaysAsTrained(arena, io, folder, trainer)) {
                say(io, "the policy file does not play as the trainer acts - the run fails\n", .{});
                return error.PolicyDoesNotPlayAsTrained;
            }
            progress.has_checked_policy_this_start = true;
        }
        const minutes_since_checkpoint: f32 = minutes - progress.checkpointed_at_minutes;
        const is_checkpoint_due: bool = checkpoint_minutes > 0 and minutes_since_checkpoint >= checkpoint_minutes;
        if (is_checkpoint_due) {
            try saveCheckpoint(arena, io, folder, trainer, progress);
        }
        const minutes_since_judgement: f32 = minutes - progress.judged_at_minutes;
        const is_judgement_due: bool = judge_minutes > 0 and minutes_since_judgement >= judge_minutes;
        if (is_judgement_due) {
            try judgeNewestPolicy(gpa, arena, io, folder, trainer, progress);
        }
        reportProgress(io, report_interval_ms, folder, trainer, progress, stats);
    }
}

/// The simulator's entry points, each in the one SPIR-V module (`robotgpu_spirv`), as `kernelEntries` lists the
/// networks'.
fn simulatorKernelEntries() [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl {
    var entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = undefined;
    inline for (robotgpu.kernels, 0..) |name, index| {
        entries[index] = .{ .name = name, .wgsl = robotgpu_spirv };
    }
    return entries;
}

/// THE TEACHER's PLANNERS FOR A RUN (`lab.Teacher`), on a simulator whose first worlds are their candidates: the
/// first `teacher.planners` characters plan, each with a block of `candidates_per_planner` candidates, planner after
/// planner. Three things are done at once, before the run's first decision:
///
///     the candidates    made copies of their planners (`Sim.copyWorlds`). A candidate is no episode of its own - no
///                       reset, no push, no bin of the curriculum (`robotgpu.isCandidate`) - and it is one from its
///                       first copy on; until then it would be a world like any other, at a state nobody gave it
///     the plans         each planner's action held at every knot (`Sim.startPlansFromActions`): what the first
///                       replan warm-starts from
///     the learner       made to record every replan's lookahead, the newest `teacher.lookaheads_kept` of them
///                       (`Resident.acceptCandidateRecording`): the world model's batches of candidates, and its gate;
///                       and given rows to choose for the candidates in, for the lookaheads around the policy of the
///                       training's second phase (`Resident.acceptCandidateActing`)
///
/// THE PLANNERS ARE THE FIRST CHARACTERS - from phase 2 they may be chosen by trouble instead, in the blocks these
/// ones' candidates hold (`Sim.choosePlannersByTrouble`): with several clips each world keeps the clip of its index
/// (`robotgpu.ClipAssignment.by_character`), so planners side by side are on clips one after another, and the teacher
/// plans on every clip once it has as many planners as there are clips.
///
/// Memory: the planning's buffers, the caller's to free (`Planning.deinit`); the planners' list is this call's
/// scratch, from `gpa`.
fn initTeacherPlanning(
    gpa: Allocator,
    simulator: *robotgpu_host.Sim,
    fleet: *const track.Fleet,
    learner: *SuperTrackLearner,
    teacher: lab.Teacher,
    first_character_world: u32,
) !robotgpu_host.Planning {
    const planner_worlds: []u32 = try gpa.alloc(u32, teacher.planners);
    defer gpa.free(planner_worlds);
    for (planner_worlds, 0..) |*planner_world, planner_index| {
        const planner: u32 = @intCast(planner_index);
        planner_world.* = first_character_world + planner;
    }
    const offset_count: u32 = @intCast(rbt.actionSize(fleet.m));
    var planning: robotgpu_host.Planning = try .init(
        gpa,
        simulator.counts,
        simulator.layout,
        planner_worlds,
        offset_count,
        fleet.options.action_scale,
        teacher.planning,
    );
    errdefer planning.deinit(gpa);
    // The layout, held to: the learner's first character is the world after the last candidate.
    const learners_first_world: u32 = learner.device_acting.?.first_world;
    const characters_follow_candidates: bool = learners_first_world == planning.candidateCapacity();
    assertf(characters_follow_candidates, @src(), "the learner's characters from world {d}, after {d} candidates", .{
        learners_first_world,
        planning.candidateCapacity(),
    });
    try simulator.copyWorlds(gpa, planning.copy_sources);
    try simulator.startPlansFromActions(gpa, &planning);
    try learner.acceptCandidateRecording(
        planning.candidateCapacity(),
        teacher.planning.candidates_per_planner,
        planning.horizon,
        teacher.lookaheads_kept,
    );
    try learner.acceptCandidateActing(planning.candidateCapacity());
    return planning;
}

/// A RUN's CHARACTERS ON THE DEVICE (`lab.TrainingPhysics.device`): the simulator, made on the learner's own device,
/// its worlds the learner's characters, and the clips' tables it was made from. The CPU fleet of such a run steps
/// nothing: it describes the task (`Fleet.trackingSettings`), makes the references (`RunTables`), gives the
/// curriculum its first bins, and serves the judge.
///
/// A ROUND's ACTING (`act`) is `Sim.actTrainerOnDevice`: the policy acts on the device, each world's record goes into
/// the learner's ring by a copy on the GPU, and the host keeps the books and the counts from the worlds' flags. THE
/// CLOCK of every draw - exploration, pushes, starts - is the learner's own count of acting steps, which its state
/// file saves: a resumed run draws on from where it stopped. The worlds themselves are not saved: a resumed run's
/// characters begin new episodes, and its curriculum its bins afresh, as a resumed CPU fleet's do.
///
/// WITH A TEACHER (`lab.Teacher.planners` above 0) the simulator's first worlds are the planners' candidates, and
/// the characters follow them, the planners first (`initTeacherPlanning`):
///
///     world    0 .. C - 1                            C .. C + P - 1     C + P ..
///              the candidates, a block a planner      the planners       the other characters
///
/// A replan runs at every decision whose number is a multiple of the teacher's replan interval
/// (`Sim.actTrainerOnDevice`): the candidates looked ahead, each planner's best its new plan. The plans and the
/// candidates' recording are not saved either: a resumed run's planners start from their actions held, and its
/// lookaheads from none.
const DeviceCharacters = struct {
    simulator: robotgpu_host.Sim,
    tables: robotgpu_host.RunTables,
    /// The pushes and returns the device's worlds have had, counted from their flags each decision.
    events: robotgpu_host.DeviceEvents = .{},
    /// The teacher's planners and their plans, for a run that has a teacher.
    planning: ?robotgpu_host.Planning = null,
    /// The stream the replans draw their candidates, and how each planner follows its plan, from.
    planner_stream: Random.DefaultPrng,

    /// The simulator for `fleet`'s task and clips on `device`, `learner` made to act through it, every character's
    /// first episode begun, and the teacher's planners made when `teacher` has any. Refused
    /// (`error.WindowLongerThanLookahead`) when the world model's window is longer than a planner's lookahead: a
    /// candidates' window is drawn inside one lookahead, so none could be drawn. Memory: the tables, the simulator's
    /// buffers and the planning's, freed by `deinit`; the learner's books and its candidates' recording are the
    /// learner's.
    fn init(
        gpa: Allocator,
        device: wgpu.DeviceHandle,
        queue: wgpu.QueueHandle,
        fleet: *track.Fleet,
        learner: *SuperTrackLearner,
        teacher: lab.Teacher,
    ) !DeviceCharacters {
        const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
        errdefer tables.deinit(gpa);
        // The candidates first, a block a planner; the characters after them.
        const character_count: u32 = @intCast(fleet.options.envs);
        const candidate_count: u32 = teacher.planners * teacher.planning.candidates_per_planner;
        const first_character_world: u32 = candidate_count;
        const simulated_worlds: u32 = candidate_count + character_count;
        const entries: [robotgpu.kernels.len]robotgpu_host.Pipe.KernelWgsl = simulatorKernelEntries();
        var simulator: robotgpu_host.Sim = try .initGpuTracking(
            gpa,
            device,
            queue,
            &entries,
            fleet.m,
            simulated_worlds,
            tables.clips,
        );
        errdefer simulator.deinit();
        const has_teacher: bool = teacher.planners > 0;
        const lookahead_decisions: u32 = simulator.counts.plan_horizon;
        if (has_teacher and learner.kit.world_steps > lookahead_decisions) {
            return error.WindowLongerThanLookahead;
        }
        // The fleet's task as one value, with the learner's filter at each decision.
        const decision_filter: rbt.DecisionFilterShares = .{
            .offsets = learner.options.filter,
            .stiffness = learner.options.stiffness_filter,
        };
        try simulator.setTracking(gpa, fleet.trackingSettings(decision_filter));
        try simulator.uploadStartBins(gpa, fleet);
        const arrays: robotgpu.WorldStateLayout = simulator.layout.world_f;
        try learner.acceptDeviceActing(
            first_character_world,
            character_count,
            arrays.policy_inputs.stride,
            arrays.actions.stride,
        );
        const start_clock: robotgpu.DecisionClock = .{
            .number = nextDecisionNumber(learner),
            .push_top_share = fleet.pushTopShare(),
        };
        try simulator.startEveryWorld(gpa, first_character_world, start_clock);
        // The teacher's planners, once their worlds stand at their first episodes' starts.
        var planning: ?robotgpu_host.Planning = null;
        if (has_teacher) {
            planning = try initTeacherPlanning(gpa, &simulator, fleet, learner, teacher, first_character_world);
        }
        // The replans' stream: the run's seed and how far the run has acted, so a resumed run draws on with new
        // candidates rather than its first start's again.
        const planner_stream_seed: u64 = learner.options.seed +% learner.acting_steps;
        const planner_stream: Random.DefaultPrng = .init(planner_stream_seed);
        return .{
            .simulator = simulator,
            .tables = tables,
            .planning = planning,
            .planner_stream = planner_stream,
        };
    }

    fn deinit(characters: *DeviceCharacters, gpa: Allocator) void {
        if (characters.planning) |planning| {
            planning.deinit(gpa);
        }
        characters.simulator.deinit();
        characters.tables.deinit(gpa);
    }

    /// The number of the learner's next decision: one past the acting steps it has taken, as the CPU fleet numbers
    /// its own.
    fn nextDecisionNumber(learner: *const SuperTrackLearner) u32 {
        const steps_taken: u32 = @truncate(learner.acting_steps);
        return steps_taken +% 1;
    }

    /// ONE ROUND's ACTING: `decisions` decisions of every character on the device, the policy explored at
    /// `noise_scale` of its sigma (0: the policy alone, judged) and the teacher's planners replanning on their
    /// interval, then the learner's count of acting steps advanced by them.
    fn act(
        characters: *DeviceCharacters,
        gpa: Allocator,
        learner: *SuperTrackLearner,
        decisions: u32,
        noise_scale: f32,
    ) !void {
        const physics_steps: u32 = @intCast(learner.fleet.options.decide_every);
        const noise: robotgpu_host.ActingNoise = .ofScale(noise_scale, learner.options.sigma);
        const planners: ?robotgpu_host.TrainerPlanners = if (characters.planning) |*planning|
            .{ .planning = planning, .random = characters.planner_stream.random() }
        else
            null;
        try characters.simulator.actTrainerOnDevice(
            zn_mlp,
            gpa,
            learner,
            decisions,
            nextDecisionNumber(learner),
            physics_steps,
            noise,
            planners,
            &characters.events,
        );
        learner.acting_steps += decisions;
    }
};

/// Every pipeline of `zn_mlp`, from its one SPIR-V module.
fn kernelEntries() [zn_mlp.kernels.len]z.Compute(zn_mlp).KernelWgsl {
    var table: [zn_mlp.kernels.len]z.Compute(zn_mlp).KernelWgsl = undefined;
    inline for (zn_mlp.kernels, 0..) |name, index| {
        table[index] = .{ .name = name, .wgsl = zn_mlp_spirv };
    }
    return table;
}

const TrainerArgs = struct {
    @"--run": []const u8 = "",
    @"--report-seconds": f32 = 10,
    @"--layout": bool = false,
    @"--report": []const u8 = "",
    @"--control": []const u8 = "",
    @"--machine-share": f32 = 1,
    @"--skip-kernel-check": bool = false,
};

const trainer_cli: cli.Config(TrainerArgs) = .{
    .prog = "geno_trainer",
    .description = "Trains Geno to track the dance with PPO or SuperTrack, headless, in a run folder: reads its " ++
        "run.zon, writes its state, policy, log.csv and status.zon as it goes, carries on from them when started " ++
        "again, and ends when the folder's stop file appears or the run's limits are reached.",
    .args = .{
        .@"--run" = .{ .description = "the run folder (made if missing)" },
        .@"--report-seconds" = .{ .description = "seconds between progress lines, at most" },
        .@"--layout" = .{
            .description = "build the run's SuperTrack learner on the CPU, without a device, report how much of " ++
                "each kernel buffer it needs, and exit: 0 when it fits, 1 when not",
        },
        .@"--report" = .{
            .description = "read every run folder in this folder - a night's runs - and write their report, " ++
                "beside them as report.txt and on the console; no device, nothing trained",
        },
        .@"--control" = .{ .description = "the report's control: a run folder's name (the first by name if none)" },
        .@"--machine-share" = .{
            .description = "the share of the machine the run takes, above 0 and at most 1: below 1 the trainer " ++
                "runs below the other programs' priority, on that share of the cores at most, and rests the GPU " ++
                "after each submission so it works that share of the time - the run trains as much slower; its " ++
                "clock counts the work, not the rests",
        },
        .@"--skip-kernel-check" = .{
            .description = "start without checking the device's kernels against their CPU twin - for a rerun on " ++
                "a device already checked; without it a run whose kernels differ from the twin is refused",
        },
    },
};

/// The text of the file `name` in `folder`, ending in a zero as the ZON parsers read it, or null when there is none.
/// Memory: in `arena`.
fn readTextEndingInZero(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    name: []const u8,
) !?[:0]const u8 {
    const path: []const u8 = try pathIn(arena, folder, name);
    const text: []u8 = try readWhole(arena, io, path, RunFile.most_bytes) orelse return null;
    return try arena.dupeSentinel(u8, text, 0);
}

/// Whether the name `first` sorts before `second`: byte by byte, as run folders are numbered.
fn nameComesFirst(_: void, first: []const u8, second: []const u8) bool {
    return lessThan(u8, first, second);
}

/// THE REPORT OF A FOLDER OF RUNS (`--report=<folder>`, `lab.RunsReport`): every run folder in it, by name, read -
/// its parameters, status, log, judgements and kernels' times - and the report written beside them as `report.txt`
/// and on the console. No device is touched: files are read. The control is the run named `control_name`, or the
/// first. Memory: the files' texts and the report in `arena`; the parsers' scratch in `gpa`.
fn writeRunsReport(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    runs_folder: []const u8,
    control_name: []const u8,
) !Exit {
    const entries: []native_os.FolderEntry = try native_os.listFolder(gpa, io, runs_folder);
    defer native_os.freeFolderEntries(gpa, entries);
    var names: ArrayList([]const u8) = .empty;
    for (entries) |entry| {
        if (entry.kind == .folder) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    if (names.items.len == 0) {
        say(io, "geno_trainer: refused: no run folders in {s}", .{runs_folder});
        return .refused;
    }
    sortSlice([]const u8, names.items, {}, nameComesFirst);
    var runs: ArrayList(lab.ReportRun) = .empty;
    for (names.items) |name| {
        const folder: []const u8 = try pathIn(arena, runs_folder, name);
        const texts: lab.ReportTexts = .{
            .name = name,
            .parameters = try readTextEndingInZero(arena, io, folder, RunFile.parameters.fileName()),
            .status = try readTextEndingInZero(arena, io, folder, RunFile.status.fileName()),
            .log = try readTextEndingInZero(arena, io, folder, RunFile.log.fileName()),
            .judgements = try readTextEndingInZero(arena, io, folder, RunFile.judgements.fileName()),
            .kernel_times = try readTextEndingInZero(arena, io, folder, RunFile.kernel_times.fileName()),
        };
        try runs.append(arena, try .read(gpa, arena, texts));
    }
    const physics_steps_per_second: f32 = 1.0 / geno.physicsOptions().timestep;
    const runs_report: lab.RunsReport = try .init(gpa, arena, runs.items, control_name, physics_steps_per_second);
    var text: Io.Writer.Allocating = .init(arena);
    try runs_report.write(arena, &text.writer);
    const report_path: []const u8 = try pathIn(arena, runs_folder, "report.txt");
    try writeWhole(arena, io, report_path, text.written());
    // Then on the console, a courtesy: the file is written, and a console gone ends nothing but the showing.
    Io.File.stdout().writeStreamingAll(io, text.written()) catch return .finished;
    say(io, "geno_trainer: the report of {d} runs, written to {s}", .{ runs.items.len, report_path });
    return .finished;
}

/// Geno as every learner's run builds it, exactly as the training pages do: the model's MJCF, the robot read from it
/// with its ball joints given the standing armature, the physics model on Geno's options, and the dance clip. Built in
/// place (`init`), since the physics model is built from the robot beside it; `deinit` releases all of it.
const GenoBody = struct {
    document: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: rmj.Imported,
    clip: dance.Clip,
    /// The get-up take (`getup_zclip`), walking and running: with the dance, every clip a run can train on, in the
    /// order `lab.GenoMotion.clipLabels` names them.
    getup_clip: dance.Clip,
    walk_clip: dance.Clip,
    run_clip: dance.Clip,
    /// Each clip's mirror image, in the same order: the dance's, the get-up's, walking's and running's.
    mirrored_clips: [4]dance.Clip,

    fn init(body: *GenoBody, gpa: Allocator) !void {
        // whole-init-first: the whole struct first, every field named.
        body.* = .{
            .document = undefined,
            .robot = undefined,
            .imported = undefined,
            .clip = undefined,
            .getup_clip = undefined,
            .walk_clip = undefined,
            .run_clip = undefined,
            .mirrored_clips = undefined,
        };
        body.document = try codecs.xml.parse(gpa, z.robot_geno_model, null);
        errdefer body.document.deinit();
        body.robot = try mjcf.readRobot(gpa, &body.document);
        errdefer body.robot.deinit();
        for (body.robot.joints) |*joint| {
            if (joint.kind == .ball) {
                joint.armature = geno.standing_armature;
            }
        }
        const physics_options: rbt.Options = geno.physicsOptions();
        body.imported = try rmj.build(gpa, &body.robot, physics_options);
        errdefer body.imported.deinit();
        body.clip = try .fromBytes(gpa, dance_zclip);
        errdefer body.clip.deinit();
        body.getup_clip = try .fromBytes(gpa, getup_zclip);
        errdefer body.getup_clip.deinit();
        body.walk_clip = try .fromBytes(gpa, walk_zclip);
        errdefer body.walk_clip.deinit();
        body.run_clip = try .fromBytes(gpa, run_zclip);
        errdefer body.run_clip.deinit();
        const mirrored_bytes = [4][]const u8{
            dance_mirrored_zclip,
            getup_mirrored_zclip,
            walk_mirrored_zclip,
            run_mirrored_zclip,
        };
        var mirrored_loaded: usize = 0;
        errdefer for (body.mirrored_clips[0..mirrored_loaded]) |*mirrored| {
            mirrored.deinit();
        };
        for (mirrored_bytes, &body.mirrored_clips) |bytes, *mirrored| {
            mirrored.* = try .fromBytes(gpa, bytes);
            mirrored_loaded += 1;
        }
    }

    /// Geno's clips in the order `lab.GenoMotion.clipLabels` names them - the dance, the get-up, walking, running -
    /// or their mirror images in the same order.
    fn clipsOf(body: *const GenoBody, mirrored: bool) [4]*const dance.Clip {
        if (mirrored) {
            const images: *const [4]dance.Clip = &body.mirrored_clips;
            return .{ &images[0], &images[1], &images[2], &images[3] };
        }
        return .{ &body.clip, &body.getup_clip, &body.walk_clip, &body.run_clip };
    }

    fn deinit(body: *GenoBody) void {
        for (&body.mirrored_clips) |*mirrored| {
            mirrored.deinit();
        }
        body.run_clip.deinit();
        body.walk_clip.deinit();
        body.getup_clip.deinit();
        body.clip.deinit();
        body.imported.deinit();
        body.robot.deinit();
        body.document.deinit();
    }
};

/// Whether a run's start checks the device's kernels (`checkKernelsAtStart`): always, unless the run is started with
/// `--skip-kernel-check`.
const KernelCheckAtStart = enum { check, skip };

/// ONE RUN OF THE KERNELS' CHECK against their CPU twin (`latent_kit.checkKernelsAgainstTwin`), from the check's own
/// data: its report, and both pipes given back as they were made (`latent_kit.clearKernelCheckData`) - every number the
/// check wrote set to zero again, the gradients it leaves among them, so a second run starts as the first did.
fn runKernelCheck(
    gpa: Allocator,
    pipe: *z.Compute(zn_mlp),
    twin: *z.Compute(zn_mlp_twin),
    options: latent_kit.KernelCheckOptions,
) !latent_kit.KernelCheckReport {
    const report: latent_kit.KernelCheckReport =
        try latent_kit.checkKernelsAgainstTwin(zn_mlp, zn_mlp_twin, gpa, pipe, twin, options);
    try latent_kit.clearKernelCheckData(zn_mlp, gpa, pipe);
    try latent_kit.clearKernelCheckData(zn_mlp_twin, gpa, twin);
    return report;
}

/// Every sequence of `report` past the bar, said with its worst field and value, after `run_name` ("first",
/// "second"); and a readback that never came.
fn sayKernelCheckFailures(
    io: Io,
    report: latent_kit.KernelCheckReport,
    run_name: []const u8,
) void {
    for (report.measured()) |sequence| {
        const worst: latent_kit.KernelCheckReport.WorstValue = sequence.worst orelse continue;
        say(io, "geno_trainer: the kernels' {s} check, {s}: {s} - {d} values past the bar, the worst at {d}: " ++
            "device {e:.6}, twin {e:.6}", .{
            run_name,
            sequence.name,
            worst.field,
            worst.values_past_bar,
            worst.index,
            worst.device_value,
            worst.twin_value,
        });
    }
    if (!report.complete) {
        say(io, "geno_trainer: the kernels' {s} check: a readback never came", .{run_name});
    }
}

/// THE DEVICE's KERNELS AGAINST THEIR CPU TWIN, AT A RUN's START (`latent_kit.checkKernelsAgainstTwin`). A kernel this
/// device runs wrongly would make every number of the run meaningless, and nothing in the run would say so. So before
/// anything is uploaded the kit's learning sequences and its blocked products run on the learner's own pipe - the very
/// SPIR-V and pipelines the run trains with - and on the CPU twin of the kernels' small build (`zn_mlp_twin`), from the
/// same data, and every value they leave is compared; then every number the check wrote is set back to zero, so the
/// learner finds its pipe as it was made (`runKernelCheck`). A few dispatches of a few thousand numbers each.
///
/// A CHECK THAT FAILS RUNS AGAIN, from the same data on pipes given back as they were made, and the two runs together
/// say what kind of fault it is. Failing again is a kernel this device computes differently from the twin - its
/// arithmetic, its code. Passing the second time is a fault no arithmetic explains: a write the device lost or ran out
/// of order, a fault of synchronisation, which would strike the training as unpredictably. Either way the run is
/// refused, each run's sequences past the bar said with their worst field and value; false then, or when a readback
/// never came.
fn checkKernelsAtStart(
    gpa: Allocator,
    io: Io,
    pipe: *z.Compute(zn_mlp),
    kernel_check: KernelCheckAtStart,
) !bool {
    if (kernel_check == .skip) {
        say(io, "geno_trainer: the device's kernels not checked against their CPU twin (--skip-kernel-check)", .{});
        return true;
    }
    var twin: z.Compute(zn_mlp_twin) = .initCpu();
    defer twin.deinit();
    const options: latent_kit.KernelCheckOptions = .{};
    const started_ms: f64 = wgpu.nowMs();
    const first: latent_kit.KernelCheckReport = try runKernelCheck(gpa, pipe, &twin, options);
    const check_seconds: f64 = (wgpu.nowMs() - started_ms) / 1000;
    const first_passes: bool = first.passes(options.gap_limit);
    if (first_passes) {
        say(io, "geno_trainer: the device's kernels match their CPU twin - {d} sequences, the largest gap {e:.2} " ++
            "(the bar {e:.0}), checked in {d:.1} s", .{
            first.sequence_count,
            first.largestGap(),
            options.gap_limit,
            check_seconds,
        });
        return true;
    }
    sayKernelCheckFailures(io, first, "first");
    const second: latent_kit.KernelCheckReport = try runKernelCheck(gpa, pipe, &twin, options);
    sayKernelCheckFailures(io, second, "second");
    const second_passes: bool = second.passes(options.gap_limit);
    if (second_passes) {
        say(io, "geno_trainer: refused: the kernels' check failed, then passed from the same data - a write this " ++
            "device lost or ran out of order, which no kernel's arithmetic explains and which would strike the " ++
            "training as unpredictably", .{});
        return false;
    }
    say(io, "geno_trainer: refused: this device's kernels differ from their CPU twin twice from the same data - " ++
        "the largest gaps {e:.2} and {e:.2}, the bar {e:.0}: every number trained here would be in doubt", .{
        first.largestGap(),
        second.largestGap(),
        options.gap_limit,
    });
    return false;
}

/// The run, once its parameters are accepted: the GPU and Geno set up, the folder's weights resumed, the servo
/// measured, then training until the run ends, and the last save. An error - the GPU or the robot that cannot be set
/// up, a file that cannot be written - ends the run, as `main` reports (exit 2); the weights that do not fit the run
/// refuse it (exit 1). The networks' pipe keeps to `machine_share`, whose rests the run's clock leaves out.
fn runTraining(
    gpa: Allocator,
    io: Io,
    report_interval_ms: f64,
    arena_state: *ArenaAllocator,
    folder: []const u8,
    parameters: lab.PpoRun,
    machine_share: *z.MachineShare,
    kernel_check: KernelCheckAtStart,
) !Exit {
    const arena: Allocator = arena_state.allocator();
    // A stop left by an earlier run is not this one's.
    const stale_stop_path: []const u8 = try runFilePath(arena, folder, .stop);
    try native_os.deleteFileIfPresent(io, stale_stop_path);

    // The GPU, without a window: the networks train there.
    const screen_side: u32 = 64;
    try vulkan_host.startHeadlessWithScreen(screen_side, screen_side);
    defer _ = vulkan_host.shutdown();
    const device: wgpu.DeviceHandle = wgpu.initDevice();
    const queue: wgpu.QueueHandle = wgpu.getQueue(device);
    var pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &kernelEntries());
    defer pipe.deinit();
    if (!try checkKernelsAtStart(gpa, io, &pipe, kernel_check)) {
        return .failed;
    }
    pipe.shareMachine(machine_share);

    // Geno, exactly as the training page builds it.
    var body: GenoBody = undefined;
    try body.init(gpa);
    defer body.deinit();
    const imported: *rmj.Imported = &body.imported;
    const clips = [_]*const dance.Clip{&body.clip};
    const trainer_options: ppo_track.Options = parameters.recipe.options(parameters.motion);
    const trainer: *Trainer = try .init(gpa, &pipe, &imported.model, imported.names, &clips, trainer_options);
    defer trainer.deinit();

    var progress: RunProgress = .{ .clip_label = parameters.motion.label(), .machine_share = machine_share };
    defer progress.log.deinit(gpa);
    defer progress.judgements.deinit(gpa);
    defer progress.recoveries.deinit(gpa);
    try progress.log.appendSlice(gpa, RunLog.header);
    if (!try resumeFromFolder(gpa, arena, io, folder, trainer, &progress)) {
        return .refused;
    }

    const actions_per_character: usize = track.actionSize(&imported.model);
    const zero_action_count: usize = parameters.recipe.envs * actions_per_character;
    const zero_actions: []f32 = try gpa.alloc(f32, zero_action_count);
    defer gpa.free(zero_actions);
    @memset(zero_actions, 0);
    progress.started = .now(machine_share);
    try saveStatus(arena, io, folder, trainer, &progress, .measuring_servo);
    progress.servo_seconds_to_failure = measureServo(trainer, parameters.recipe.decimation, zero_actions);
    if (progress.servo_seconds_to_failure) |servo_seconds| {
        say(io, "geno_trainer: {s} in {s} - the servo alone loses the reference every {d:.2} s", .{
            parameters.motion.label(),
            folder,
            servo_seconds,
        });
    } else {
        say(io, "geno_trainer: {s} in {s} - the servo alone never lost the reference while measured", .{
            parameters.motion.label(),
            folder,
        });
    }
    progress.started = .now(machine_share);
    progress.saved_at_minutes = progress.minutes_before_this_start;

    const end_state: RunState = try train(
        gpa,
        io,
        report_interval_ms,
        arena_state,
        folder,
        parameters,
        trainer,
        &progress,
    );
    _ = arena_state.reset(.retain_capacity);
    const final_arena: Allocator = arena_state.allocator();
    try saveAll(final_arena, io, folder, trainer, &progress, end_state);
    // The stop is consumed: started again, the run carries on.
    if (end_state == .stopped) {
        const consumed_stop_path: []const u8 = try runFilePath(final_arena, folder, .stop);
        try native_os.deleteFileIfPresent(io, consumed_stop_path);
    }
    say(io, "geno_trainer: {s} at batch {d}, {d:.1} minutes trained", .{
        @tagName(end_state),
        trainer.iterations,
        trainingMinutes(&progress),
    });
    return .finished;
}

// ---- The run's clips ----

/// THE RUN'S CLIPS, in the order its fleet holds them: the motion's own (`lab.GenoMotion.clipLabels`) - the clips the
/// judge judges - then each one's variants (`lab.ClipVariants`), trained and logged but never judged (H1): its mirror
/// image, baked, and the copies at another speed of either, built here when the run starts (`geno.clipAtSpeed`).
const RunClips = struct {
    /// Every clip in the fleet's order, and the label its lines carry.
    clips: []*const dance.Clip,
    labels: [][]const u8,
    /// How many of the first clips are the motion's own, the judged.
    judged_count: usize,
    /// The speed copies, which the run owns: `clips` points into them.
    built: []dance.Clip,
    built_count: usize,

    /// Memory: `clips`, `built` and the labels with `gpa`, released by `deinit` - the list of labels and each
    /// variant's label, which is made here (a judged clip's label is the motion's own text). None of it in the run's
    /// arena: the training loop resets that every round, and the labels are read at every save.
    fn init(
        gpa: Allocator,
        body: *const GenoBody,
        motion: lab.GenoMotion,
        variants: lab.ClipVariants,
    ) !RunClips {
        const model: *const rbt.Model = &body.imported.model;
        const motion_labels: []const []const u8 = motion.clipLabels();
        var variant_room: [lab.ClipVariants.most_per_clip]lab.ClipVariant = undefined;
        const variant_list: []const lab.ClipVariant = variants.list(&variant_room);
        var speed_copies_per_clip: usize = 0;
        for (variant_list) |variant| {
            if (variant.speed != 1) {
                speed_copies_per_clip += 1;
            }
        }
        const clip_count: usize = motion_labels.len * variant_list.len;
        var self: RunClips = .{
            .clips = try gpa.alloc(*const dance.Clip, clip_count),
            .labels = &.{},
            .judged_count = motion_labels.len,
            .built = &.{},
            .built_count = 0,
        };
        errdefer gpa.free(self.clips);
        self.labels = try gpa.alloc([]const u8, clip_count);
        errdefer gpa.free(self.labels);
        self.built = try gpa.alloc(dance.Clip, motion_labels.len * speed_copies_per_clip);
        errdefer gpa.free(self.built);
        errdefer for (self.built[0..self.built_count]) |*copy| {
            copy.deinit();
        };
        const own_clips: [4]*const dance.Clip = body.clipsOf(false);
        const mirrored_clips: [4]*const dance.Clip = body.clipsOf(true);
        // The judged clips first: each clip itself.
        for (motion_labels, 0..) |label, index| {
            self.clips[index] = own_clips[index];
            self.labels[index] = label;
        }
        // Then each clip's variants, the clip itself among them skipped.
        var probe: rbt.Data = try .init(gpa, model);
        defer probe.deinit();
        var at: usize = motion_labels.len;
        // The variants' labels made so far, freed if a later one fails.
        errdefer for (self.labels[motion_labels.len..at]) |variant_label| {
            gpa.free(variant_label);
        };
        for (motion_labels, 0..) |label, index| {
            for (variant_list) |variant| {
                if (variant.isTheClip()) {
                    continue;
                }
                const side: *const dance.Clip = if (variant.mirrored) mirrored_clips[index] else own_clips[index];
                if (variant.speed == 1) {
                    self.clips[at] = side;
                } else {
                    const at_speed: geno.ClipAtSpeed = try geno.clipAtSpeed(model, &probe, side, variant.speed);
                    self.built[self.built_count] = at_speed.clip;
                    self.clips[at] = &self.built[self.built_count];
                    self.built_count += 1;
                }
                self.labels[at] = try variant.label(gpa, label);
                at += 1;
            }
        }
        return self;
    }

    fn deinit(self: *RunClips, gpa: Allocator) void {
        for (self.built[0..self.built_count]) |*copy| {
            copy.deinit();
        }
        gpa.free(self.built);
        // The variants' labels, after the judged clips' - which are the motion's own text, not this struct's.
        for (self.labels[self.judged_count..]) |variant_label| {
            gpa.free(variant_label);
        }
        gpa.free(self.labels);
        gpa.free(self.clips);
    }

    /// The frames of every clip together: what the learner's tables hold a row of each.
    fn frameCount(self: *const RunClips) usize {
        var frames: usize = 0;
        for (self.clips) |clip| {
            frames += clip.frame_count;
        }
        return frames;
    }
};

// ---- SuperTrack's path ----
//
// SuperTrack learns in ROUNDS (`robot_track_resident.Resident`): every character simulates `collect` steps with the
// policy acting from its CPU mirror and exploration noise, every step recorded into the GPU's ring; then the world
// model and the policy each take their updates on windows the GPU gathers from that ring. Its run folder holds its
// own state file (`supertrack_state`: both networks, Adam's moments, the counters, the random stream) and its own log
// (`lab.SuperTrackLog`), beside the files every learner's run shares: `policy`, `status.zon`, `stop`.

/// The recent rounds' steps watched and failures, kept in a ring: what the run's recent time to failure is taken
/// over (`lab.SuperTrackLog.window_rounds`).
const RecentRounds = struct {
    const window_rounds: usize = lab.SuperTrackLog.window_rounds;

    steps_watched: [window_rounds]u64 = @splat(0),
    failures: [window_rounds]u64 = @splat(0),
    count: usize = 0,

    fn add(self: *RecentRounds, steps_watched: u64, failures: u64) void {
        const slot: usize = self.count % window_rounds;
        self.steps_watched[slot] = steps_watched;
        self.failures[slot] = failures;
        self.count += 1;
    }

    /// The decisions watched over the window.
    fn watched(self: *const RecentRounds) u64 {
        const counted: usize = @min(self.count, window_rounds);
        var steps_watched: u64 = 0;
        for (self.steps_watched[0..counted]) |round_steps| {
            steps_watched += round_steps;
        }
        return steps_watched;
    }

    /// Seconds between failures over the window (`ppo_track.secondsToFailure`); null while nothing in it failed.
    fn secondsToFailure(self: *const RecentRounds, steps_per_second: f32) ?f32 {
        return combinedSecondsToFailure(&.{self.*}, steps_per_second);
    }

    /// Seconds between failures over several clips' windows taken together - their steps watched and failures summed:
    /// a run's variants, as one line reports them.
    fn combinedSecondsToFailure(recents: []const RecentRounds, steps_per_second: f32) ?f32 {
        var steps_watched: u64 = 0;
        var failures: u64 = 0;
        for (recents) |recent| {
            const counted: usize = @min(recent.count, window_rounds);
            for (0..counted) |slot| {
                steps_watched += recent.steps_watched[slot];
                failures += recent.failures[slot];
            }
        }
        return ppo_track.secondsToFailure(steps_watched, failures, steps_per_second);
    }
};

/// The learner's running totals a round's line counts the differences of (`lab.SuperTrackLog.Line`): read before
/// and after each round.
const RoundTotals = struct {
    steps_watched: u64,
    failures: u64,
    /// The teacher's planners' part of the two (`Resident.countPlannerDecision`).
    planner_steps_watched: u64,
    planner_failures: u64,
    pushes: u64,
    push_speed_sum: f64,
    planning_decisions: u64,
    planned_steps: u64,
    nonfinite_actions: u64,
    mirrors_refused: u64,
    windows_refused: u64,
    returns: u64,
    return_steps_sum: u64,
    /// The watched pushes ended, and those the characters came back from (`robot.PushBrake`): the fleet's counts on
    /// both paths - a device's host tells the fleet each one it reads (`Fleet.noteWatchedPush`).
    watched_pushes: u64,
    watched_came_back: u64,
    /// The teacher's: the policy's updates on the planners' labels, the world model's on their candidates, the
    /// lookaheads recorded whole, the labels the books have kept and those they dropped for decisions after a loss -
    /// each 0 for a run without a teacher.
    label_updates: u64,
    candidate_world_updates: u64,
    lookaheads: u64,
    labels_kept: u64,
    labels_dropped_after_losses: u64,
    /// The world model's updates on the skip head's schedule.
    skip_world_updates: u64,
    /// The teacher's plans judged against their baseline, those that taught and their advantages' sum
    /// (`robotgpu_host.Planning`) - 0 without a device's planning.
    teacher_plans: u64 = 0,
    teacher_teaching_plans: u64 = 0,
    teacher_advantage_sum: f64 = 0,

    /// The learner's totals; with `device_characters`, the pushes and the returns are the device's, counted from its
    /// worlds' flags (`robotgpu_host.DeviceEvents`) - the CPU fleet steps nothing in such a run. A device's pushes'
    /// speeds are the host's own: each made again from the push's draw.
    fn of(learner: *const SuperTrackLearner, device_characters: ?*const DeviceCharacters) RoundTotals {
        const lookaheads: u64 = if (learner.candidate_recording) |recording| recording.lookaheads_complete else 0;
        const label_books: ?track.LabelBooks = if (learner.device_acting) |acting| acting.books.labels else null;
        const labels_kept: u64 = if (label_books) |books| books.labels_kept else 0;
        const labels_dropped_after_losses: u64 = if (label_books) |books| books.labels_dropped_after_losses else 0;
        var totals: RoundTotals = .{
            .steps_watched = learner.exposure,
            .failures = learner.failures,
            .planner_steps_watched = learner.planner_exposure,
            .planner_failures = learner.planner_failures,
            .pushes = learner.fleet.pushes_given,
            .push_speed_sum = learner.fleet.push_speed_sum,
            .planning_decisions = learner.planning_decisions,
            .planned_steps = learner.planned_steps,
            .nonfinite_actions = learner.nonfinite_actions,
            .mirrors_refused = learner.mirror_rejected,
            .windows_refused = learner.windows_refused,
            .returns = learner.fleet.returns,
            .return_steps_sum = learner.fleet.return_steps_sum,
            .watched_pushes = learner.fleet.watched_pushes_settled,
            .watched_came_back = learner.fleet.watched_pushes_came_back,
            .label_updates = learner.label_updates,
            .candidate_world_updates = learner.candidate_world_updates,
            .lookaheads = lookaheads,
            .labels_kept = labels_kept,
            .labels_dropped_after_losses = labels_dropped_after_losses,
            .skip_world_updates = learner.skip_world_updates,
        };
        if (device_characters) |characters| {
            const events: robotgpu_host.DeviceEvents = characters.events;
            totals.pushes = events.pushes;
            totals.push_speed_sum = events.push_speed_sum;
            totals.returns = events.returns;
            totals.return_steps_sum = events.return_decisions * learner.fleet.options.decide_every;
            if (characters.planning) |planning| {
                totals.teacher_plans = planning.judged_plans;
                totals.teacher_teaching_plans = planning.teaching_plans;
                totals.teacher_advantage_sum = planning.advantage_sum;
            }
        }
        return totals;
    }
};

/// The share of the learner's characters planning at the moment - 0 without planning.
fn flaggedShare(learner: *const SuperTrackLearner) f32 {
    const flags: resident.PlanningFlags = learner.planning_flags orelse return 0;
    var planning: f32 = 0;
    for (flags.slots) |slot| {
        planning += if (slot != null) 1 else 0;
    }
    return planning / float(@max(flags.slots.len, 1));
}

/// The characters' mean projected hazard after the latest step - 0 without planning, which alone measures it.
fn meanHazard(learner: *const SuperTrackLearner) f32 {
    if (learner.planning_flags == null) {
        return 0;
    }
    var hazard_sum: f32 = 0;
    for (learner.hazards) |hazard| {
        hazard_sum += hazard;
    }
    return hazard_sum / float(@max(learner.hazards.len, 1));
}

/// The physics' tasks a run asks for (`lab.SuperTrackLearner.physics_threads`), within the machine's share of its
/// cores: 0 asks for every core the share allows. Each task runs on a thread of its own while the others run, so the
/// tasks are the cores the physics takes at once - on a machine of 16 cores at a share of a half, 8 at most, the
/// other 8 left to the machine's user. A share of 1 allows every core.
fn physicsThreads(asked: u32, machine_share: f32) u32 {
    const core_count: usize = std.Thread.getCpuCount() catch 1;
    const shared_cores: u32 = @floor(machine_share * float(core_count));
    const most_tasks: u32 = @max(shared_cores, 1);
    if (asked > 0) {
        return @min(asked, most_tasks);
    }
    return most_tasks;
}

/// The two pipes of a SuperTrack run whose time is measured (`lab.RoundTimeLog`): the learner's networks, and - for a
/// run whose characters live there - the simulator's physics. Their names are a kernel line's first column
/// (`lab.KernelTimeLog`).
const TimedPipe = enum {
    learner,
    simulator,

    const count: usize = @typeInfo(TimedPipe).@"enum".field_names.len;
};

/// ONE PIPE's KERNELS OVER A RUN, for a run that times every dispatch (`lab.GenoControls.kernel_times`): each
/// kernel's time on the device and its timed dispatches, summed round after round (`Compute.readTimings` adds to
/// them), in the pipe's kernel order, with the kernels' names. Empty for a pipe whose dispatches are not timed one by
/// one.
const KernelTotals = struct {
    names: []const []const u8 = &.{},
    microseconds: []f64 = &.{},
    dispatches: []u64 = &.{},

    /// Totals of zero for a pipe's kernels, `names` - the pipe's own list, which outlives the totals. Memory: the two
    /// lists, the caller's to free (`deinit`).
    fn init(gpa: Allocator, names: []const []const u8) !KernelTotals {
        const microseconds: []f64 = try gpa.alloc(f64, names.len);
        errdefer gpa.free(microseconds);
        const dispatches: []u64 = try gpa.alloc(u64, names.len);
        @memset(microseconds, 0);
        @memset(dispatches, 0);
        return .{ .names = names, .microseconds = microseconds, .dispatches = dispatches };
    }

    fn deinit(totals: KernelTotals, gpa: Allocator) void {
        gpa.free(totals.microseconds);
        gpa.free(totals.dispatches);
    }
};

/// How many dispatches a pipe has made, over its kernels (`Compute.dispatch_counts`).
fn dispatchTotal(dispatch_counts: []const u32) u64 {
    var total: u64 = 0;
    for (dispatch_counts) |count| {
        total += count;
    }
    return total;
}

/// THE WORK A RUN's PIPES HAVE BEEN GIVEN SO FAR: the dispatches' submissions and the dispatches, the learner's pipe's
/// and - with `device_characters` - the simulator's. A round's are the difference of two.
const PipeWork = struct {
    submissions: u64,
    dispatches: u64,

    fn of(learner: *const SuperTrackLearner, device_characters: ?*DeviceCharacters) PipeWork {
        const learner_pipe: *z.Compute(zn_mlp) = learner.kit.pipe;
        var work: PipeWork = .{
            .submissions = learner_pipe.readGeneration().submitted,
            .dispatches = dispatchTotal(&learner_pipe.dispatch_counts),
        };
        if (device_characters) |characters| {
            const simulator_pipe: *robotgpu_host.Pipe = &characters.simulator.pipe;
            work.submissions += simulator_pipe.readGeneration().submitted;
            work.dispatches += dispatchTotal(&simulator_pipe.dispatch_counts);
        }
        return work;
    }
};

/// THE TRIPWIRES' FIRST READING (`lab.Tripwire`), taken at the first round whose end finds the learner's weights read
/// back: every network's weights - [0, `params_end`) of the parameters, in the program's `gpa` - and, then, the
/// learner's counts of updates, the teacher's examples and the replay's write head.
const TripwireStart = struct {
    parameters: []f32,
    round: u64,
    policy_updates: u64,
    critic_updates: u64,
    label_updates: u64,
    flow_examples: u64,
    replay_head: ?u64,
};

/// Where a SuperTrack run is between rounds: its log, its rounds and their recent failures, when it started and last
/// saved. Plain state, as `RunProgress` is for PPO.
const SuperTrackProgress = struct {
    /// The most clips a run trains at once: the minute's four, each with every variant (`lab.ClipVariants`).
    const most_clips: usize = 4 * lab.ClipVariants.most_per_clip;

    /// The run's clips as the judge's and the probe's lines name them - one per clip of the fleet, in its order - and
    /// how many of the first are judged: the motion's own, before their variants (`RunClips`).
    clip_labels: []const []const u8 = &.{"dance"},
    judged_clip_count: usize = 1,
    /// Each clip's recent rounds, and the learner's per-clip counts already taken into them.
    clip_recent: [most_clips]RecentRounds = @splat(.{}),
    clip_exposure_seen: [most_clips]u64 = @splat(0),
    clip_failures_seen: [most_clips]u64 = @splat(0),
    /// The milliseconds the last judgement and its probes took - carried into the next round's line, the round they
    /// delayed.
    pending_judging_ms: f32 = 0,
    /// THE ACTIVE CLOCK (`superTrackActiveMinutes`): the working milliseconds this start spent judging, probing and
    /// checkpointing, and the active minutes of the earlier starts (their log's last `active_minutes`).
    paused_ms: f64 = 0,
    active_minutes_before_this_start: f32 = 0,
    /// The run's success by SuperMimic's evaluation (`lab.JudgeLog.superMimicSuccess`), once it has come: its round
    /// and the active minutes there.
    success_round: ?u64 = null,
    success_active_minutes: ?f32 = null,
    /// THE RUN's TIME (`lab.RoundTimeLog`): the host's clock over the round being trained, which the learner and the
    /// simulator are told each phase of (`Resident.phase_clock`, `Sim.phase_clock`); the time log's lines; the last
    /// round's line, for the report; and the host's time when that round ended - 0 before this start's first.
    clock: rbt.PhaseClock = .{},
    times: ArrayList(u8) = .empty,
    last_round_times: lab.RoundTimeLog.Line = .{},
    /// Whether a round has been said to have dispatches no timing mark covered: said once, the first time.
    has_said_untimed: bool = false,
    round_ended_ms: f64 = 0,
    /// Each timed pipe's kernels over this start (`KernelTotals`), by `TimedPipe`: empty unless the run times every
    /// dispatch.
    kernel_totals: [TimedPipe.count]KernelTotals = @splat(.{}),
    /// What stopped being finite, once the watchdog has seen it (`Resident.nonfiniteCause`); empty while all is.
    nonfinite_cause: []const u8 = "",
    /// THE TRIPWIRES (`lab.Tripwire`): the first reading - taken at the first round the learner's weights came
    /// back, its parameters in the program's `gpa`, freed once the tripwires are judged - whether they have been, and
    /// the one that fired.
    tripwire_start: ?TripwireStart = null,
    tripwires_judged: bool = false,
    tripwire_fired: ?lab.TripwireFired = null,
    tripwire_bars: lab.TripwireBars = .{},
    /// The clip the collapse alarm names (`lab.JudgeLog.collapsedClip`), or empty.
    collapsed_clip: []const u8 = "",
    /// The state checkpoints this start keeps at once - the run's `lab.GenoControls.kept_state_checkpoints`: each
    /// holds every weight and the optimisers' moments, so a long run keeps the newest few rather than all - and the
    /// minutes of those it has written and keeps, oldest first (`saveSuperTrackCheckpoint`).
    kept_state_checkpoints: usize = 4,
    state_checkpoint_minutes: [lab.GenoControls.most_kept_state_checkpoints]u64 = @splat(0),
    state_checkpoint_count: usize = 0,
    log: ArrayList(u8) = .empty,
    rounds: u64 = 0,
    servo_seconds_to_failure: ?f32 = null,
    /// The machine's share the run keeps to, whose rests its clocks leave out (`ClockReading`); null for a run that
    /// takes the whole machine.
    machine_share: ?*const z.MachineShare = null,
    /// The clock when training started, and the minutes trained before it by earlier starts.
    started: ClockReading = .{},
    minutes_before_this_start: f32 = 0,
    has_saved_this_start: bool = false,
    saved_at_minutes: f32 = 0,
    reported_at_ms: f64 = 0,
    recent: RecentRounds = .{},
    /// The teacher's planners' recent rounds (`RoundTotals.planner_steps_watched`): empty without planners.
    planner_recent: RecentRounds = .{},
    /// Whether this start's first policy file was read back and found to play as the learner acts
    /// (`superTrackPolicyPlaysAsTrained`).
    has_checked_policy_this_start: bool = false,
    checkpointed_at_minutes: f32 = 0,
    /// The run's judgements as `judge.csv` holds them (`lab.JudgeLog`), grown with the program's `gpa`.
    judgements: ArrayList(u8) = .empty,
    /// The run's recovery probes as `recovery.csv` holds them (`lab.RecoveryLog`): the servo's lines, then one set
    /// per judgement.
    recoveries: ArrayList(u8) = .empty,
    judged_at_minutes: f32 = 0,
};

/// The minutes a SuperTrack run has trained, over every start: working minutes, the machine's share's rests left out
/// (`ClockReading`).
fn superTrackMinutes(progress: *const SuperTrackProgress) f32 {
    const elapsed_ms: f64 = ClockReading.now(progress.machine_share).workingMsSince(progress.started);
    const elapsed_minutes: f32 = @floatCast(elapsed_ms / 60_000.0);
    return progress.minutes_before_this_start + elapsed_minutes;
}

/// THE ACTIVE MINUTES a SuperTrack run has trained, over every start - InstantMimic's measure of a run's time: the
/// training clock less what this start spent judging, probing and checkpointing (`SuperTrackProgress.paused_ms`),
/// which no learner needs to train. The start's own setup is outside the clock already.
fn superTrackActiveMinutes(progress: *const SuperTrackProgress) f32 {
    const elapsed_ms: f64 = ClockReading.now(progress.machine_share).workingMsSince(progress.started);
    const active_ms: f64 = @max(elapsed_ms - progress.paused_ms, 0);
    const active_minutes: f32 = @floatCast(active_ms / 60_000.0);
    return progress.active_minutes_before_this_start + active_minutes;
}

/// THE RUN's SUCCESS, read from its judgements and its log (`lab.JudgeLog.superMimicSuccess`): the first judgement
/// with every judged clip completed whole and their mean normalised return at the bar, and the active minutes of its
/// round's line. Kept once found; said when first found. Read from the files' text, so it holds across a resume.
fn noteSuperTrackSuccess(io: Io, progress: *SuperTrackProgress) void {
    if (progress.success_round != null) {
        return;
    }
    const judged_labels: []const []const u8 = progress.clip_labels[0..progress.judged_clip_count];
    const scales: track.SuperMimicScales = geno.tracking_task.super_mimic;
    const bar: f32 = lab.JudgeLog.success_normalised_return;
    const success: lab.JudgeLog.SuperMimicSuccess =
        lab.JudgeLog.superMimicSuccess(progress.judgements.items, judged_labels, scales, bar) orelse return;
    const log_text: []const u8 = progress.log.items;
    const logged_active: ?f64 = lab.SuperTrackLog.numberAtRound(log_text, "active_minutes", success.batch);
    const active_at_round: f64 = logged_active orelse success.training_minutes;
    const active_minutes: f32 = @floatCast(active_at_round);
    progress.success_round = success.batch;
    progress.success_active_minutes = active_minutes;
    say(io, "SUCCESS at round {d}: every clip completed, their mean normalised return {d:.3} - after {d:.1} active" ++
        " minutes", .{ success.batch, success.mean_normalised_return, active_minutes });
}

/// The learner's policy file (`lab.policyOfSuperTrack`) from its newest weights: the readback brought up to every
/// update dispatched, and the mirror refreshed from it, first. Memory: the policy's arrays in `arena`, the caller's.
fn superTrackPolicy(
    arena: Allocator,
    learner: *SuperTrackLearner,
    action_scale: f32,
) !lab.GenoPolicy {
    learner.waitForReadback();
    learner.syncMirror();
    const learner_clock: u32 = learner.fleet.options.decide_every;
    return lab.policyOfSuperTrack(arena, learner.policyParts(), action_scale, learner_clock);
}

/// Whether a SuperTrack run is judged by its learner's own judging actor rather than by its policy file's player: a
/// flow run's - the flow from its mirror at zero noise - the same policy its file holds, as the file's play check finds
/// at its first save (`superTrackPolicyPlaysAsTrained`).
fn judgesWithLearnerActor(settings: lab.SuperTrackLearner) bool {
    return settings.actor == .flow;
}

/// EACH KERNEL's TIME SINCE THIS START (`lab.KernelTimeLog`, `kernel_times.csv`), written whole - nothing for a run
/// that does not time every dispatch, whose totals are empty. Memory: the entries, the file's bytes and its path in
/// `arena`, the caller's scratch for this save.
fn saveKernelTimes(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    progress: *const SuperTrackProgress,
) !void {
    var kernel_count: usize = 0;
    for (progress.kernel_totals) |totals| {
        kernel_count += totals.names.len;
    }
    if (kernel_count == 0) {
        return;
    }
    const entries: []lab.KernelTimeLog.Entry = try arena.alloc(lab.KernelTimeLog.Entry, kernel_count);
    var entry_index: usize = 0;
    for (progress.kernel_totals, 0..) |totals, pipe_index| {
        const pipe: TimedPipe = @fromBackingInt(@intCast(pipe_index));
        for (totals.names, totals.microseconds, totals.dispatches) |name, microseconds, dispatches| {
            entries[entry_index] = .{
                .pipe = @tagName(pipe),
                .kernel = name,
                .dispatches = dispatches,
                .gpu_microseconds = microseconds,
            };
            entry_index += 1;
        }
    }
    var file_text: ArrayList(u8) = .empty;
    try lab.KernelTimeLog.write(arena, &file_text, entries);
    const kernel_times_path: []const u8 = try runFilePath(arena, folder, .kernel_times);
    try writeWhole(arena, io, kernel_times_path, file_text.items);
}

/// Everything a SuperTrack run keeps, each file written whole: its state (`supertrack_state`), its policy, its log,
/// its rounds' times and its status, with the recent time to failure over the last rounds (`RecentRounds`). Memory:
/// every file's bytes and every path in `arena`, the caller's scratch for this save.
fn saveSuperTrack(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    learner: *SuperTrackLearner,
    settings: lab.SuperTrackLearner,
    progress: *SuperTrackProgress,
    state: RunState,
) !void {
    // The state's weights and counters of the same update - never a state that is not finite: a run that failed so
    // writes only its log and status, and a save that finds it refuses (`error.StateNotFinite`), the last good state
    // kept on disk.
    learner.waitForReadback();
    const saves_state: bool = state != .failed_nonfinite;
    if (saves_state) {
        if (learner.nonfiniteCause()) |cause| {
            progress.nonfinite_cause = cause;
            return error.StateNotFinite;
        }
        const state_bytes: []u8 = try learner.exportState(arena);
        const state_path: []const u8 = try runFilePath(arena, folder, .supertrack_state);
        try writeWhole(arena, io, state_path, state_bytes);
    }
    // The policy file: the policy, and a flow run's flow correcting it (`lab.PolicyFlow`) - what the lab plays.
    if (saves_state) {
        const policy: lab.GenoPolicy = try superTrackPolicy(arena, learner, settings.action_scale);
        const policy_bytes: []u8 = try lab.PolicyFile.encode(arena, &policy);
        const policy_path: []const u8 = try pathIn(arena, folder, RunFile.policy_name);
        try writeWhole(arena, io, policy_path, policy_bytes);
    }
    const log_path: []const u8 = try runFilePath(arena, folder, .log);
    try writeWhole(arena, io, log_path, progress.log.items);
    // The rounds' times, and - for a run that times every dispatch - each kernel's totals since this start.
    const times_path: []const u8 = try runFilePath(arena, folder, .times);
    try writeWhole(arena, io, times_path, progress.times.items);
    try saveKernelTimes(arena, io, folder, progress);
    // The learner's counts are of its fleet's steps - decisions - so they become seconds at its clock.
    const decisions_per_second: f32 = 1.0 / learner.fleet.decisionSeconds();
    // Each clip on its own line, when there are several.
    const clip_count: usize = progress.clip_labels.len;
    const clip_statuses: []lab.ClipStatus = try arena.alloc(lab.ClipStatus, if (clip_count > 1) clip_count else 0);
    for (clip_statuses, progress.clip_labels[0..clip_statuses.len], 0..) |*clip_status, label, clip| {
        clip_status.* = .{
            .clip = label,
            .recent_seconds_to_failure = progress.clip_recent[clip].secondsToFailure(decisions_per_second),
        };
    }
    const status: RunStatus = .{
        .state = state,
        .batches = progress.rounds,
        .steps = learner.exposure,
        .training_minutes = superTrackMinutes(progress),
        .servo_seconds_to_failure = progress.servo_seconds_to_failure,
        .recent_seconds_to_failure = progress.recent.secondsToFailure(decisions_per_second),
        .assist = 0,
        .written_at_seconds = native_os.wallClockSeconds(io),
        .clips = clip_statuses,
        .world_model_loss = learner.device_stats.world_model_loss,
        .critic_value_error = learner.device_stats.critic_value_error,
        .policy_gradient_norm = learner.device_stats.policy_gradient_norm,
        .windows_refused = learner.windows_refused,
        .nonfinite_actions = learner.nonfinite_actions,
        .nonfinite = progress.nonfinite_cause,
        .tripwire = if (progress.tripwire_fired) |fired| try fired.text(arena) else "",
        .collapse = progress.collapsed_clip,
        .success_active_minutes = progress.success_active_minutes,
        .success_round = progress.success_round,
    };
    var status_text: Io.Writer.Allocating = .init(arena);
    try std.zon.stringify.serialize(status, .{}, &status_text.writer);
    try status_text.writer.writeAll("\n");
    const status_path: []const u8 = try runFilePath(arena, folder, .status);
    try writeWhole(arena, io, status_path, status_text.written());
    progress.has_saved_this_start = true;
    progress.saved_at_minutes = superTrackMinutes(progress);
}

/// A CHECKPOINT under the run's minute of training: the learner's newest policy, `policy_m<minute>`, as every learner's
/// run keeps them - the lab's timeline of a run, a flow run's with its flow (`lab.PolicyFlow`) -
/// and its whole state, `supertrack_state_m<minute>`, the newest few that this start has written kept - as many as the
/// run's controls say, none when they say zero (`lab.GenoControls.kept_state_checkpoints`; an earlier start's stay,
/// so a resumed run may hold more): what a run goes back to when its newest state is not the one wanted. Nothing is
/// written when the newest readback is not finite (`error.StateNotFinite`, the watchdog's). Memory: the policy, the
/// state, their bytes and the paths in `arena`.
fn saveSuperTrackCheckpoint(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    learner: *SuperTrackLearner,
    settings: lab.SuperTrackLearner,
    progress: *SuperTrackProgress,
) !void {
    const minutes: f32 = superTrackMinutes(progress);
    learner.waitForReadback();
    if (learner.nonfiniteCause()) |cause| {
        progress.nonfinite_cause = cause;
        return error.StateNotFinite;
    }
    const whole_minutes: u64 = @floor(minutes);
    var name_buffer: RunFile.NameBuffer = undefined;
    // The policy's checkpoint: the lab's timeline of the run.
    const policy: lab.GenoPolicy = try superTrackPolicy(arena, learner, settings.action_scale);
    const policy_bytes: []u8 = try lab.PolicyFile.encode(arena, &policy);
    const checkpoint_name: []const u8 = RunFile.policyCheckpointName(whole_minutes, &name_buffer);
    const checkpoint_path: []const u8 = try pathIn(arena, folder, checkpoint_name);
    try writeWhole(arena, io, checkpoint_path, policy_bytes);
    const keeps_states: bool = progress.kept_state_checkpoints > 0;
    if (!keeps_states) {
        progress.checkpointed_at_minutes = minutes;
        return;
    }
    // The state, and the oldest kept one let go once more than `kept_state_checkpoints` are. A checkpoint in the same
    // minute as the newest kept one overwrites it, and is not kept twice.
    const state_bytes: []u8 = try learner.exportState(arena);
    const state_name: []const u8 = RunFile.stateCheckpointName(whole_minutes, &name_buffer);
    const state_path: []const u8 = try pathIn(arena, folder, state_name);
    try writeWhole(arena, io, state_path, state_bytes);
    const kept: []u64 = progress.state_checkpoint_minutes[0..progress.kept_state_checkpoints];
    const count: usize = progress.state_checkpoint_count;
    const overwrote_newest: bool = count > 0 and kept[count - 1] == whole_minutes;
    if (overwrote_newest) {
        progress.checkpointed_at_minutes = minutes;
        return;
    }
    if (progress.state_checkpoint_count == kept.len) {
        const oldest_name: []const u8 = RunFile.stateCheckpointName(kept[0], &name_buffer);
        const oldest_path: []const u8 = try pathIn(arena, folder, oldest_name);
        try native_os.deleteFileIfPresent(io, oldest_path);
        copyForwards(u64, kept[0 .. kept.len - 1], kept[1..]);
        progress.state_checkpoint_count -= 1;
    }
    kept[progress.state_checkpoint_count] = whole_minutes;
    progress.state_checkpoint_count += 1;
    progress.checkpointed_at_minutes = minutes;
}

/// The newest SuperTrack policy judged on EACH of the run's clips (`lab.judgePolicy`), a line per clip added to
/// `judge.csv` and a probe per clip to `recovery.csv` - and, before the first, the servo alone on the same starts. The
/// judge is every learner's: Geno's own task (not the training task's grace), DReCon's bodies, starts a second apart
/// across each clip, the policy's mean action - so its servo lines are a PPO run's, and the two runs' judgements can
/// be read against each other. Each clip on its own: a run on the dance and the get-up must not let the one's
/// numbers hide the other's. Memory: the policy, the judge's actor and the starts in `arena`; the judge's fleets with
/// `gpa`, freed before it returns; the judgements grow in `progress` with `gpa`.
fn judgeSuperTrackPolicy(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    learner: *SuperTrackLearner,
    settings: lab.SuperTrackLearner,
    progress: *SuperTrackProgress,
    probe: track.RecoveryProbe,
) !void {
    const fleet: *track.Fleet = learner.fleet;
    const labels_match: bool = fleet.clips.len == progress.clip_labels.len;
    assertf(labels_match, @src(), "{d} clips, {d} labels", .{ fleet.clips.len, progress.clip_labels.len });
    // The judgement is the motion's own clips', never a variant's: they come first (`RunClips`).
    const judged_count: usize = progress.judged_clip_count;
    const judged_clips: []const *const dance.Clip = fleet.clips[0..judged_count];
    const judged_labels: []const []const u8 = progress.clip_labels[0..judged_count];
    const frames_per_second: usize = 60;
    const body_names: []const []const u8 = fleet.options.body_names;
    const model: *rbt.Model = fleet.m;
    const is_first_judgement: bool = progress.judgements.items.len == 0;
    if (is_first_judgement) {
        try progress.judgements.appendSlice(gpa, lab.JudgeLog.header);
    }
    // The newest policy, whichever way it is judged: the weights of the round's last update, once their readback
    // has landed, in the mirror - which the policy's file is written from and the learner's own actor reads.
    learner.waitForReadback();
    learner.syncMirror();
    // What is judged: the policy's file, as the lab plays it - or, for a flow run, whose policy no policy file
    // holds, the learner's own judging actor: its flow from its mirror at zero noise, through its own filter, on a
    // fleet of its own action (`learnerJudgeFleet`).
    var policy: ?*lab.GenoPolicy = null;
    if (!judgesWithLearnerActor(settings)) {
        const file_policy: *lab.GenoPolicy = try arena.create(lab.GenoPolicy);
        file_policy.* = try superTrackPolicy(arena, learner, settings.action_scale);
        policy = file_policy;
    }
    const learner_fleet: track.Fleet.Options = learnerJudgeFleet(settings, geno.tracking_task, body_names);
    const judged: ProbedController = if (policy) |file_policy|
        .{ .policy = file_policy }
    else
        .{ .learner_actor = .{ .actor = learner.judgeActor(), .fleet_options = learner_fleet } };
    const minutes: f32 = superTrackMinutes(progress);
    const rounds: u64 = progress.rounds;
    for (judged_clips, judged_labels) |clip, clip_label| {
        const starts: []usize = try track.evenStarts(arena, clip, frames_per_second);
        const judge_settings: lab.PolicyJudgeSettings = .{
            .starts = starts,
            .task = geno.tracking_task,
            .bodies = geno.drecon_bodies,
        };
        // SUPERMIMIC'S EVALUATION: the whole clip from its first frame a start is defined at, one start - recorded as
        // the clip's "/whole" line, from which its normalised return and whether it reached the end are read.
        const whole_clip_start = [_]usize{1};
        var whole_settings: lab.PolicyJudgeSettings = judge_settings;
        whole_settings.starts = &whole_clip_start;
        var whole_label_buffer: [80]u8 = undefined;
        const whole_label: []const u8 = try bufPrint(&whole_label_buffer, "{s}/whole", .{clip_label});
        // The servo alone on this clip, once: the baseline every judgement of it is read against.
        if (is_first_judgement) {
            const servo: track.Judgement =
                try lab.judgePolicy(gpa, arena, model, body_names, clip, null, judge_settings);
            try lab.JudgeLog.appendLine(gpa, &progress.judgements, 0, 0, clip_label, servo);
            const servo_whole: track.Judgement =
                try lab.judgePolicy(gpa, arena, model, body_names, clip, null, whole_settings);
            try lab.JudgeLog.appendLine(gpa, &progress.judgements, 0, 0, whole_label, servo_whole);
            try probeAndRecord(
                gpa,
                arena,
                io,
                folder,
                model,
                body_names,
                clip,
                clip_label,
                .servo,
                judge_settings,
                probe,
                &progress.recoveries,
                0,
                0,
            );
        }
        var judgement: track.Judgement = undefined;
        var whole: track.Judgement = undefined;
        if (policy) |file_policy| {
            judgement = try lab.judgePolicy(gpa, arena, model, body_names, clip, file_policy, judge_settings);
            whole = try lab.judgePolicy(gpa, arena, model, body_names, clip, file_policy, whole_settings);
        } else {
            // The learner judged on its own fleet, as it acts.
            const learner_actor: track.Actor = judged.learner_actor.actor;
            judgement = try track.judge(gpa, model, clip, learner_fleet, starts, learner_actor);
            whole = try track.judge(gpa, model, clip, learner_fleet, &whole_clip_start, learner_actor);
        }
        try lab.JudgeLog.appendLine(gpa, &progress.judgements, rounds, minutes, clip_label, judgement);
        try lab.JudgeLog.appendLine(gpa, &progress.judgements, rounds, minutes, whole_label, whole);
        try probeAndRecord(
            gpa,
            arena,
            io,
            folder,
            model,
            body_names,
            clip,
            clip_label,
            judged,
            judge_settings,
            probe,
            &progress.recoveries,
            rounds,
            minutes,
        );
        const error_seconds: f32 = judgement.meanTimeToFailureError() orelse 0;
        say(io, "judged at round {d}, {s}: loses the reference every {d:.2} s (standard error {d:.2} s), {d} of {d}" ++
            " starts", .{
            rounds,
            clip_label,
            judgement.meanTimeToFailure(),
            error_seconds,
            judgement.failures,
            judgement.starts,
        });
        // SuperMimic's evaluation of the whole clip, and BlinkMimic's measures of its tracking (`track.QualitySums`).
        const quality: track.QualitySums = whole.quality;
        const is_completed: bool = whole.failures == 0 and whole.reached_end == whole.starts;
        const completed: []const u8 = if (is_completed) "completed" else "lost";
        say(io, "judged at round {d}, {s} whole: {s}, normalised return {d:.3}; bodies {d:.2} cm and {d:.2} deg," ++
            " joints {d:.2} deg, foot slip {d:.2} cm/s (the reference's {d:.2}), contact {d:.3}, depth {d:.3} mm", .{
            rounds,
            clip_label,
            completed,
            whole.superMimicNormalisedReturn(geno.tracking_task.super_mimic),
            quality.bodyPositionCm(),
            quality.bodyRotationDegrees(),
            quality.jointDegrees(),
            quality.footSlipCmPerSecond(),
            quality.referenceFootSlipCmPerSecond(),
            quality.contactAgreement(),
            quality.penetrationMm(),
        });
    }
    const judgements_path: []const u8 = try runFilePath(arena, folder, .judgements);
    try writeWhole(arena, io, judgements_path, progress.judgements.items);
    progress.judged_at_minutes = minutes;
    // The collapse alarm, over every judgement the run has: said once, when a clip first collapses.
    const judgements_in_a_row: u32 = 3;
    const collapsed: []const u8 = lab.JudgeLog.collapsedClip(
        progress.judgements.items,
        judged_labels,
        judgements_in_a_row,
    ) orelse "";
    const is_new_collapse: bool = collapsed.len > 0 and !eql(u8, collapsed, progress.collapsed_clip);
    if (is_new_collapse) {
        say(io, "ALARM: on {s} the policy, once better than the servo, has been no better three judgements running", .{
            collapsed,
        });
    }
    progress.collapsed_clip = collapsed;
}

/// Whether the folder's policy file plays as the learner acts: read back, decoded, and asked through the lab's own
/// decider (`lab.PolicyDecider`) for every character's action now, against the learner's mirror (`policyRow` on
/// `features`). To rounding, not to the bit: the mirror sums the goal's and the state's contributions interleaved,
/// the file's first layer one after the other (exactly as the kit does) - a few parts in a million of the largest
/// action. Run once a start, after the first save: a file that plays otherwise is the program's fault, and the run
/// fails rather than leave a policy the lab would play wrongly. Memory: the file, the policy, the decider and the
/// buffers in `arena`.
fn superTrackPolicyPlaysAsTrained(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    learner: *SuperTrackLearner,
) !bool {
    const path: []const u8 = try pathIn(arena, folder, RunFile.policy_name);
    const bytes: []u8 = try readWhole(arena, io, path, RunFile.most_bytes) orelse return false;
    const policy: lab.GenoPolicy = try lab.PolicyFile.decode(arena, bytes);
    const fleet: *track.Fleet = learner.fleet;
    const character_count: usize = fleet.options.envs;
    const action_count: usize = learner.host.raw.len;
    var decider: lab.PolicyDecider = try .init(arena, fleet.m, fleet.options.body_names, geno.drecon_bodies, &policy);
    var controller: z.robot_policy.Controller =
        try .init(arena, fleet.m, decider.subset, character_count, policy.controllerOptions());
    const decided_actions: []f32 = try arena.alloc(f32, character_count * action_count);
    decider.decide(&policy, &controller, fleet, character_count, decided_actions);
    // The learner's own answer: the judged policy's, corrected by the flow from zero noise where the run has one - as
    // the learner's judging actor acts (`Resident.judgeActor`).
    const has_flow: bool = learner.host.flow != null;
    const zero_noise: []f32 = try arena.alloc(f32, learner.host.flow_coefficients.len);
    @memset(zero_noise, 0);
    var worst_difference: f32 = 0.0;
    var largest_action: f32 = 0.0;
    for (0..character_count) |character| {
        learner.features(character);
        if (has_flow) {
            learner.host.correctedRowOf(learner.host.judged, zero_noise);
        } else {
            learner.host.policyRowOf(learner.host.judged);
        }
        const from_file: []const f32 = decided_actions[character * action_count ..][0..action_count];
        for (from_file, learner.host.raw) |file_component, mirror_component| {
            worst_difference = @max(worst_difference, @abs(file_component - mirror_component));
            largest_action = @max(largest_action, @abs(mirror_component));
        }
    }
    const rounding_allowed: f32 = 1.0e-5 * @max(largest_action, 1.0e-3);
    return worst_difference <= rounding_allowed;
}

/// Carries a SuperTrack run on from the folder's state and log, when it has them. False, after saying why, when the
/// state is not this learner's (`Resident.stateProblem` names the first thing that differs) - the run is then refused,
/// and nothing in the folder is overwritten. The replay is not kept: the first rounds refill it before the first
/// update. Memory: the folder's files read into `arena`, the caller's scratch for this start; the log copied into
/// `progress.log` with `gpa`, which `progress` owns for the rest of the run.
fn resumeSuperTrack(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    learner: *SuperTrackLearner,
    progress: *SuperTrackProgress,
) !bool {
    const state_path: []const u8 = try runFilePath(arena, folder, .supertrack_state);
    const state_bytes: []u8 = try readWhole(arena, io, state_path, RunFile.most_bytes) orelse return true;
    if (learner.stateProblem(state_bytes)) |problem| {
        say(io, "geno_trainer: refused: the folder's SuperTrack state is not this run's ({s})", .{problem});
        return false;
    }
    try learner.importState(gpa, state_bytes);
    const judgements_path: []const u8 = try runFilePath(arena, folder, .judgements);
    if (try readWhole(arena, io, judgements_path, RunFile.most_bytes)) |saved_judgements| {
        progress.judgements.clearRetainingCapacity();
        try progress.judgements.appendSlice(gpa, saved_judgements);
        progress.judged_at_minutes = lastJudgedMinutes(saved_judgements);
    }
    const log_path: []const u8 = try runFilePath(arena, folder, .log);
    if (try readWhole(arena, io, log_path, RunFile.most_bytes)) |saved_log| {
        progress.log.clearRetainingCapacity();
        try progress.log.appendSlice(gpa, saved_log);
        progress.minutes_before_this_start = lastLoggedMinutes(saved_log);
        const rounds_text: []const u8 = lastLoggedColumn(saved_log, 0) orelse "0";
        progress.rounds = parseInt(u64, rounds_text, 10) catch 0;
        const logged_active: ?f64 = lab.SuperTrackLog.numberAtRound(saved_log, "active_minutes", progress.rounds);
        progress.active_minutes_before_this_start = @floatCast(logged_active orelse 0);
        noteSuperTrackSuccess(io, progress);
    }
    // The rounds' times carry on after the earlier starts' lines.
    const times_path: []const u8 = try runFilePath(arena, folder, .times);
    if (try readWhole(arena, io, times_path, RunFile.most_bytes)) |saved_times| {
        progress.times.clearRetainingCapacity();
        try progress.times.appendSlice(gpa, saved_times);
    }
    say(io, "geno_trainer: resumed from round {d}, {d} world and {d} policy updates", .{
        progress.rounds,
        learner.world_updates,
        learner.policy_updates,
    });
    return true;
}

/// THE SERVO's OFFSETS FROM THE POLICY over every character on the device (`lab.OffsetMagnitudes`): each character's
/// applied action as the simulator holds it - the joints' offsets, before the limbs' stiffnesses - times the action's
/// scale, in radians. Memory: its arrays in `gpa`, freed before it returns.
fn characterOffsetMagnitudes(
    gpa: Allocator,
    characters: *DeviceCharacters,
    learner: *const SuperTrackLearner,
) !lab.OffsetMagnitudes {
    const first_world: u32 = learner.device_acting.?.first_world;
    const applied: @FieldType(robotgpu.WorldStateLayout, "applied_actions") =
        characters.simulator.layout.world_f.applied_actions;
    const character_count: usize = learner.fleet.options.envs;
    const applied_block: []f32 = try gpa.alloc(f32, character_count * applied.stride);
    defer gpa.free(applied_block);
    characters.simulator.pipe.readRange(.world_f, applied.at(first_world, 0), applied_block);
    const offset_count: usize = track.actionSize(learner.fleet.m);
    const offsets: []f32 = try gpa.alloc(f32, character_count * offset_count);
    defer gpa.free(offsets);
    const action_scale: f32 = learner.fleet.options.action_scale;
    for (0..character_count) |character| {
        const applied_offsets: []const f32 = applied_block[character * applied.stride ..][0..offset_count];
        const character_offsets: []f32 = offsets[character * offset_count ..][0..offset_count];
        for (applied_offsets, character_offsets) |applied_number, *offset| {
            offset.* = action_scale * applied_number;
        }
    }
    const scratch: []f32 = try gpa.alloc(f32, offsets.len);
    defer gpa.free(scratch);
    return lab.offsetMagnitudes(offsets, scratch);
}

/// The records the device acting's books have taken with a planner's action since the run's start (`LabelBooks`):
/// kept, dropped for any reason, or in a stretch not yet settled - every label that arrived. 0 without the books.
fn labelledRecordsArrived(learner: *const SuperTrackLearner) u64 {
    const acting: SuperTrackLearner.DeviceActing = learner.device_acting orelse return 0;
    const labels: track.LabelBooks = acting.books.labels;
    var arrived: u64 = labels.labels_kept + labels.labels_dropped_with_failed_plans;
    arrived += labels.labels_dropped_after_losses + labels.labels_dropped_at_episode_ends;
    for (labels.stretch_length) |open_records| {
        arrived += open_records;
    }
    return arrived;
}

/// Whether network `network` was due updates between the tripwires' first reading `start` and now: the world model at
/// every round; the policy once the world model's time alone is over (`Options.world_alone_updates`); the critic and
/// the flow where they had updates - a flow learns only once examples have come (teacher 2), and judging either
/// before would fire on a run that is learning as it should.
fn networkDueUpdates(
    network: SuperTrackLearner.Network,
    learner: *const SuperTrackLearner,
    start: TripwireStart,
) bool {
    return switch (network) {
        .world_model => true,
        .policy => learner.world_updates >= learner.options.world_alone_updates,
        .critic => learner.critic_updates > start.critic_updates,
        .flow => start.flow_examples > 0 and learner.label_updates > start.label_updates,
    };
}

/// The console's line for tripwires that hold (`judgeTripwires`): what each part read - so a night's console shows
/// every run was judged, and how far from each bar it stood.
fn sayTripwiresHold(io: Io, round: u64, reading: lab.TripwireReading) void {
    var networks_buffer: [256]u8 = undefined;
    var networks_text: Io.Writer = .fixed(&networks_buffer);
    for (reading.networks, 0..) |network, index| {
        const separator: []const u8 = if (index == 0) "" else ", ";
        const judged: []const u8 = if (network.updated) "" else " (not yet due)";
        const change: f32 = network.largest_change;
        // A line too long for the buffer is cut where it filled: the console's words, not a number anything reads.
        networks_text.print("{s}{s} {e:.1}{s}", .{ separator, network.name, change, judged }) catch break;
    }
    var teacher_buffer: [96]u8 = undefined;
    const teacher_text: []const u8 = if (reading.teacher) |arrivals|
        bufPrint(&teacher_buffer, ", {d} labelled records and {d} lookaheads arrived", .{
            arrivals.labelled_records,
            arrivals.lookaheads,
        }) catch ""
    else
        "";
    var offsets_buffer: [96]u8 = undefined;
    const offsets_text: []const u8 = if (reading.offsets) |offsets|
        bufPrint(&offsets_buffer, ", the servo's offsets up to {d:.2} rad, {d:.3} typical", .{
            offsets.largest,
            offsets.median,
        }) catch ""
    else
        "";
    say(io, "geno_trainer: the tripwires hold at round {d} - the replay moving{s}, the weights' largest moves: " ++
        "{s}{s}", .{
        round,
        teacher_text,
        networks_text.buffered(),
        offsets_text,
    });
}

/// THE TRIPWIRES (`lab.Tripwire`), at a round's end: the first reading at the first round past the warm-up whose end
/// has the learner's weights back (`TripwireStart`); `judged_after_rounds` rounds later the judgement - the tripwire
/// that fired, or null,
/// said on the console when they hold. Judged once; nothing is read after. Memory: the first reading's weights in
/// `gpa`, freed at the judgement (or with the progress, for a run that ends before it).
fn judgeTripwires(
    gpa: Allocator,
    io: Io,
    settings: lab.SuperTrackLearner,
    learner: *SuperTrackLearner,
    device_characters: ?*DeviceCharacters,
    progress: *SuperTrackProgress,
) !?lab.TripwireFired {
    if (progress.tripwires_judged) {
        return null;
    }
    // Through the warm-up no network is updated, by design (`resident.Options.warmup_decisions`): the tripwires'
    // first reading waits for its end, so their rounds are rounds that train.
    if (learner.warmingUp()) {
        return null;
    }
    const parameter_count: usize = learner.params_end;
    const readback: []const f32 = learner.kit.pipe.readLatest(.params) orelse return null;
    if (readback.len < parameter_count) {
        return null;
    }
    const weights: []const f32 = readback[0..parameter_count];
    const start: TripwireStart = progress.tripwire_start orelse {
        progress.tripwire_start = .{
            .parameters = try gpa.dupe(f32, weights),
            .round = progress.rounds,
            .policy_updates = learner.policy_updates,
            .critic_updates = learner.critic_updates,
            .label_updates = learner.label_updates,
            .flow_examples = learner.distillationExamples(),
            .replay_head = learner.data.ring.appended,
        };
        return null;
    };
    const bars: lab.TripwireBars = progress.tripwire_bars;
    if (progress.rounds - start.round < bars.judged_after_rounds) {
        return null;
    }
    progress.tripwires_judged = true;
    defer {
        gpa.free(start.parameters);
        progress.tripwire_start = null;
    }
    // Every network the learner has: due updates since the first reading or not, and how far its weights moved.
    const networks = [_]SuperTrackLearner.Network{ .world_model, .policy, .critic, .flow };
    var motions: [networks.len]lab.NetworkMotion = undefined;
    var motion_count: usize = 0;
    for (networks) |network| {
        const range: SuperTrackLearner.ParameterRange = learner.networkParameters(network) orelse continue;
        const before: []const f32 = start.parameters[range.first..][0..range.count];
        const after: []const f32 = weights[range.first..][0..range.count];
        motions[motion_count] = .{
            .name = network.label(),
            .updated = networkDueUpdates(network, learner, start),
            .largest_change = lab.largestChange(before, after),
        };
        motion_count += 1;
    }
    // The teacher's arrivals, where its planners act on the device.
    const has_teacher: bool = settings.teacher.planners > 0 and learner.device_acting != null;
    const recording: ?resident.CandidateRecording = learner.candidate_recording;
    const lookaheads: u64 = if (recording) |candidates| candidates.lookaheads_complete else 0;
    const arrivals: lab.TeacherArrivals = .{
        .labelled_records = labelledRecordsArrived(learner),
        .lookaheads = lookaheads,
    };
    // The servo's offsets, where the characters live on the device.
    const offsets: ?lab.OffsetMagnitudes = if (device_characters) |characters|
        try characterOffsetMagnitudes(gpa, characters, learner)
    else
        null;
    // The gradients' lengths are measured where they are bounded.
    const stats: @FieldType(SuperTrackLearner, "device_stats") = learner.device_stats;
    const replay_head: ?u64 = learner.data.ring.appended;
    const reading: lab.TripwireReading = .{
        .replay_moved = replay_head != null and replay_head != start.replay_head,
        .teacher = if (has_teacher) arrivals else null,
        .networks = motions[0..motion_count],
        .world_gradient_norm = if (settings.world_gradient_clip > 0) stats.world_gradient_norm else null,
        .policy_gradient_norm = if (settings.policy_gradient_clip > 0) stats.policy_gradient_norm else null,
        .offsets = offsets,
    };
    const fired: ?lab.TripwireFired = lab.firstTripwire(reading, bars);
    if (fired == null) {
        sayTripwiresHold(io, progress.rounds, reading);
    }
    return fired;
}

/// Whether a SuperTrack run must end now, and how: something no longer finite (the watchdog), its folder's `stop` file,
/// or its limits - hours of training, or policy updates (`controls.stop_after_updates`).
fn superTrackEndState(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    controls: lab.GenoControls,
    learner: *const SuperTrackLearner,
    progress: *SuperTrackProgress,
) !?RunState {
    // The watchdog: anything no longer finite ends the run before another round can save it.
    if (learner.nonfiniteCause()) |cause| {
        progress.nonfinite_cause = cause;
        return .failed_nonfinite;
    }
    const stop_path: []const u8 = try runFilePath(arena, folder, .stop);
    if (fileExists(io, stop_path)) {
        return .stopped;
    }
    const hours_trained: f32 = superTrackMinutes(progress) / 60.0;
    const is_past_hours: bool = controls.stop_after_hours > 0 and hours_trained >= controls.stop_after_hours;
    const update_limit: u64 = controls.stop_after_updates;
    const is_past_updates: bool = update_limit > 0 and learner.policy_updates >= update_limit;
    return if (is_past_hours or is_past_updates) .finished else null;
}

/// One clip's recent time to failure as the console line says it - "dance 1.20 s", or "dance no losses" while nothing
/// on it failed in the recent rounds - in `buffer`; "?" if it does not fit.
fn clipTimeText(buffer: []u8, label: []const u8, seconds: ?f32) []const u8 {
    if (seconds) |clip_seconds| {
        return bufPrint(buffer, "{s} {d:.2} s", .{ label, clip_seconds }) catch "?";
    }
    return bufPrint(buffer, "{s} no losses", .{label}) catch "?";
}

/// A line of SuperTrack's progress, at most every `report_interval_ms`: the run, its round, its minutes, its updates
/// and the recent time to failure.
fn reportSuperTrack(
    io: Io,
    report_interval_ms: f64,
    folder: []const u8,
    learner: *const SuperTrackLearner,
    progress: *SuperTrackProgress,
) void {
    const now_ms: f64 = wgpu.nowMs();
    const is_first_report: bool = progress.reported_at_ms == 0;
    const since_report_ms: f64 = now_ms - progress.reported_at_ms;
    const is_report_due: bool = is_first_report or since_report_ms >= report_interval_ms;
    if (!is_report_due) {
        return;
    }
    progress.reported_at_ms = now_ms;
    var failure_buffer: [48]u8 = undefined;
    // The counts are decisions (`Resident.countDecision`): seconds are them over the decisions a second.
    const decisions_per_second: f32 = 1.0 / learner.fleet.decisionSeconds();
    const recent_seconds: ?f32 = progress.recent.secondsToFailure(decisions_per_second);
    const failure_text: []const u8 = if (recent_seconds) |seconds|
        bufPrint(&failure_buffer, "loses the reference every {d:.2} s", .{seconds}) catch "?"
    else
        "no losses in the recent rounds";
    // With planners, theirs beside it: "  planners 2.31 s".
    var planner_buffer: [48]u8 = undefined;
    const has_planners: bool = progress.planner_recent.count > 0 and progress.planner_recent.watched() > 0;
    const planner_seconds: ?f32 = progress.planner_recent.secondsToFailure(decisions_per_second);
    const planner_text: []const u8 = if (!has_planners)
        ""
    else if (planner_seconds) |seconds|
        bufPrint(&planner_buffer, "  planners {d:.2} s", .{seconds}) catch "?"
    else
        "  planners no losses";
    // With several clips, each judged clip's own time beside it, and the variants' together after them:
    // "  (dance 0.74 s, get-up 1.59 s, ..., variants 0.91 s)".
    var clips_buffer: [192]u8 = undefined;
    var clips_text: []const u8 = "";
    if (progress.clip_labels.len > 1) {
        const judged_count: usize = progress.judged_clip_count;
        const clip_count: usize = progress.clip_labels.len;
        const judged_labels: []const []const u8 = progress.clip_labels[0..judged_count];
        var used: usize = 0;
        for (judged_labels, progress.clip_recent[0..judged_count], 0..) |label, recent, clip| {
            var piece_buffer: [48]u8 = undefined;
            const seconds: ?f32 = recent.secondsToFailure(decisions_per_second);
            const piece: []const u8 = clipTimeText(&piece_buffer, label, seconds);
            const separator: []const u8 = if (clip == 0) "  (" else ", ";
            const written: []const u8 = bufPrint(clips_buffer[used..], "{s}{s}", .{ separator, piece }) catch "";
            used += written.len;
        }
        if (clip_count > judged_count) {
            var piece_buffer: [48]u8 = undefined;
            const variants_recent: []const RecentRounds = progress.clip_recent[judged_count..clip_count];
            const seconds: ?f32 = RecentRounds.combinedSecondsToFailure(variants_recent, decisions_per_second);
            const piece: []const u8 = clipTimeText(&piece_buffer, "variants", seconds);
            const separator: []const u8 = if (judged_count == 0) "  (" else ", ";
            const written: []const u8 = bufPrint(clips_buffer[used..], "{s}{s}", .{ separator, piece }) catch "";
            used += written.len;
        }
        const closing: []const u8 = bufPrint(clips_buffer[used..], ")", .{}) catch "";
        used += closing.len;
        clips_text = clips_buffer[0..used];
    }
    say(io, "{s}  round {d}  {d:.1} min  {d} world / {d} policy updates  {s}{s}{s}", .{
        basename(folder),
        progress.rounds,
        superTrackMinutes(progress),
        learner.world_updates,
        learner.policy_updates,
        failure_text,
        planner_text,
        clips_text,
    });
    // Through the warm-up the rounds collect and update nothing (`Resident.warmingUp`): how far it has come.
    if (learner.warmingUp()) {
        say(io, "{s}  warming up, {d} of {d} decisions collected - no network updated yet", .{
            basename(folder),
            learner.decisionsHeld(),
            learner.options.warmup_decisions,
        });
    }
    // What the networks are learning, from the device's newest numbers: the world model's loss - in its own units,
    // XMimic's, its window's mean step and its last step, then in the clips' - the share of its updates the bound
    // clipped, the policy's tracking term through it, and with the root target on, how far the imagined root drifts
    // from the reference's.
    const stats: latent_kit.DeviceStats = learner.device_stats;
    var root_buffer: [80]u8 = undefined;
    const root_text: []const u8 = if (learner.options.root_target)
        bufPrint(&root_buffer, ", the imagined root {d:.2} m and {d:.2} rad off the reference's", .{
            stats.policy_root_drift,
            stats.policy_root_turn,
        }) catch "?"
    else
        "";
    say(io, "{s}  the world model's loss {d:.4} a step, {d:.4} at its last ({d:.4} in the clips' units, {d:.0}% of " ++
        "its updates clipped), the policy's tracking {d:.4}{s}", .{
        basename(folder),
        stats.world_loss,
        stats.world_loss_last_step,
        stats.world_model_loss,
        100 * stats.world_gradient_clipped_share,
        stats.policy_tracking_loss,
        root_text,
    });
    // Where the last round's time went (`lab.RoundTimeLog`): its wall time, the device's busy share of it and the
    // phase the device spent the most in, and the host's waits for the device.
    const times: lab.RoundTimeLog.Line = progress.last_round_times;
    const has_round_times: bool = times.wall_ms > 0;
    if (!has_round_times) {
        return;
    }
    var busiest: usize = 0;
    for (times.phases, 0..) |phase_times, phase| {
        if (phase_times.gpu_ms > times.phases[busiest].gpu_ms) {
            busiest = phase;
        }
    }
    const busiest_phase: rbt.RoundPhase = @fromBackingInt(@intCast(busiest));
    const busy_percent: f32 = 100 * (1 - times.gpu_idle_share);
    say(io, "{s}  the last round took {d:.0} ms: the device busy {d:.0}% of it ({s} {d:.0} ms), the host waiting " ++
        "{d:.0} ms; {d} dispatches in {d} submissions", .{
        basename(folder),
        times.wall_ms,
        busy_percent,
        @tagName(busiest_phase),
        times.phases[busiest].gpu_ms,
        times.host_wait_ms,
        times.dispatches,
        times.submissions,
    });
}

/// THE ROUND's TIME (`lab.RoundTimeLog`), gathered at the round's end, after its training is submitted: the device's
/// time by phase from both pipes' marks - read here, which waits for the device's last work of the round, a wait
/// counted as the host's - then the host's clock ended, and the round's submissions and dispatches since
/// `work_before`, with the time it rested the device for the machine's share, `rested_ms`. A run that times every
/// dispatch has each kernel's time added to its totals (`SuperTrackProgress.kernel_totals`).
fn roundTimes(
    learner: *SuperTrackLearner,
    device_characters: ?*DeviceCharacters,
    progress: *SuperTrackProgress,
    between_rounds_ms: f64,
    rested_ms: f64,
    work_before: PipeWork,
) lab.RoundTimeLog.Line {
    var gpu_microseconds: [rbt.RoundPhase.count]f64 = @splat(0);
    var gpu_segments: [rbt.RoundPhase.count]u32 = @splat(0);
    const read_began_ms: f64 = wgpu.nowMs();
    const learner_totals: KernelTotals = progress.kernel_totals[@backingInt(TimedPipe.learner)];
    const learner_read: z.TimingsRead = learner.kit.pipe.readTimings(
        &gpu_microseconds,
        &gpu_segments,
        learner_totals.microseconds,
        learner_totals.dispatches,
    );
    var simulator_read: z.TimingsRead = .{};
    if (device_characters) |characters| {
        const simulator_totals: KernelTotals = progress.kernel_totals[@backingInt(TimedPipe.simulator)];
        simulator_read = characters.simulator.pipe.readTimings(
            &gpu_microseconds,
            &gpu_segments,
            simulator_totals.microseconds,
            simulator_totals.dispatches,
        );
    }
    // The reads waited for the device: the host's wait, in the phase it is in - none of the round's own.
    const read_ended_ms: f64 = wgpu.nowMs();
    progress.clock.addWait(read_ended_ms - read_began_ms);
    progress.clock.end(read_ended_ms);
    const reads = [_]z.TimingsRead{ learner_read, simulator_read };
    const work_after: PipeWork = .of(learner, device_characters);
    const measured: lab.RoundTimeLog.Measured = .{
        .round = progress.rounds,
        .training_minutes = superTrackMinutes(progress),
        .between_rounds_ms = between_rounds_ms,
        .rested_ms = rested_ms,
        .gpu_microseconds = gpu_microseconds,
        .gpu_segments = gpu_segments,
        .gpu_span_microseconds = z.timingsSpanMicroseconds(&reads),
        .clock = progress.clock,
        .submissions = work_after.submissions - work_before.submissions,
        .dispatches = work_after.dispatches - work_before.dispatches,
        .untimed_dispatches = learner_read.untimed_dispatches + simulator_read.untimed_dispatches,
    };
    return lab.RoundTimeLog.lineOf(measured);
}

/// Trains a SuperTrack run round after round until it must end (`superTrackEndState`), logging every round - its
/// counts and where its time went - and saving everything at its first round and every `save_minutes`; the state it
/// ended in. Memory: each round's paths and files in `arena_state`, reset every round; the logs grow in `progress`
/// with `gpa`.
fn trainSuperTrack(
    gpa: Allocator,
    io: Io,
    report_interval_ms: f64,
    arena_state: *ArenaAllocator,
    folder: []const u8,
    run: lab.GenoRun,
    settings: lab.SuperTrackLearner,
    learner: *SuperTrackLearner,
    device_characters: ?*DeviceCharacters,
    progress: *SuperTrackProgress,
) !RunState {
    const save_minutes: f32 = run.controls.save_minutes;
    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena: Allocator = arena_state.allocator();
        if (try superTrackEndState(arena, io, folder, run.controls, learner, progress)) |end_state| {
            return end_state;
        }
        // The round, its two halves timed apart; its counts the totals' differences.
        // The pushes' top follows the run's training hours, where the brake allows (`robot.PushTop`).
        learner.fleet.tellTrainingHours(superTrackMinutes(progress) / 60.0);
        // And the rates' schedule, when it is in hours (`robot_track_resident.Options.rate_decay_hours`).
        learner.training_hours = learner.fleet.training_hours;
        const before: RoundTotals = .of(learner, device_characters);
        const work_before: PipeWork = .of(learner, device_characters);
        const round_start: ClockReading = .now(progress.machine_share);
        const round_started_ms: f64 = round_start.wall_ms;
        // The round's time: the host's clock from here, and how long the host was between rounds - saving, judging.
        const has_round_before: bool = progress.round_ended_ms > 0;
        const between_rounds_ms: f64 = if (has_round_before) round_started_ms - progress.round_ended_ms else 0;
        progress.clock.begin(round_started_ms);
        // The round's acting: on the device where the run's characters live there, else on the CPU fleet.
        if (device_characters) |characters| {
            try characters.act(gpa, learner, learner.options.collect, 1.0);
        } else {
            learner.act(learner.options.collect, 1.0);
        }
        const acting_end: ClockReading = .now(progress.machine_share);
        learner.train();
        const training_end: ClockReading = .now(progress.machine_share);
        const after: RoundTotals = .of(learner, device_characters);
        progress.rounds += 1;
        const steps_watched: u64 = after.steps_watched - before.steps_watched;
        const pushes: u64 = after.pushes - before.pushes;
        const push_speed_sum: f64 = after.push_speed_sum - before.push_speed_sum;
        const planned_steps: u64 = after.planned_steps - before.planned_steps;
        const returns: u64 = after.returns - before.returns;
        const return_steps: u64 = after.return_steps_sum - before.return_steps_sum;
        const teacher_plans: u64 = after.teacher_plans - before.teacher_plans;
        const teacher_teaching_plans: u64 = after.teacher_teaching_plans - before.teacher_teaching_plans;
        const teacher_advantage_sum: f64 = after.teacher_advantage_sum - before.teacher_advantage_sum;
        const round_line: lab.SuperTrackLog.Line = .{
            .round = progress.rounds,
            .active_minutes = superTrackActiveMinutes(progress),
            .training_minutes = superTrackMinutes(progress),
            .steps_watched = steps_watched,
            .failures = after.failures - before.failures,
            .world_updates = learner.world_updates,
            .policy_updates = learner.policy_updates,
            .pushes = pushes,
            .push_mean_speed = @floatCast(push_speed_sum / float64(@max(pushes, 1))),
            .push_top_speed = learner.fleet.pushTopSpeed(),
            .push_line_speed = learner.fleet.pushLineSpeed(),
            .watched_pushes = after.watched_pushes - before.watched_pushes,
            .watched_came_back = after.watched_came_back - before.watched_came_back,
            .returns = returns,
            .return_mean_seconds = float(return_steps) * learner.fleet.m.opt.timestep / float(@max(returns, 1)),
            .flagged_share = flaggedShare(learner),
            .mean_hazard = meanHazard(learner),
            .planning_decisions = after.planning_decisions - before.planning_decisions,
            .planned_step_share = float(planned_steps) / float(@max(steps_watched, 1)),
            .planner_steps_watched = after.planner_steps_watched - before.planner_steps_watched,
            .planner_failures = after.planner_failures - before.planner_failures,
            .teacher_plans = teacher_plans,
            .teacher_teaching_share = float(teacher_teaching_plans) / float(@max(teacher_plans, 1)),
            .teacher_mean_advantage = @floatCast(teacher_advantage_sum / float64(@max(teacher_plans, 1))),
            .teacher2_examples = learner.distillationExamples(),
            .teacher3_examples = learner.fpo_example_count,
            .critic_trust = learner.criticTrust(),
            .label_share = learner.labelShare(),
            .policy_rate_multiplier = learner.policyRateMultiplier(),
            .label_updates = after.label_updates - before.label_updates,
            .candidate_world_updates = after.candidate_world_updates - before.candidate_world_updates,
            .lookaheads = after.lookaheads - before.lookaheads,
            .labels_kept = after.labels_kept - before.labels_kept,
            .labels_dropped_after_losses = after.labels_dropped_after_losses - before.labels_dropped_after_losses,
            .skip_world_updates = after.skip_world_updates - before.skip_world_updates,
            .gate_passes = learner.gate_passes_in_a_row,
            .nonfinite_actions = after.nonfinite_actions - before.nonfinite_actions,
            .mirrors_refused = after.mirrors_refused - before.mirrors_refused,
            .windows_refused = after.windows_refused - before.windows_refused,
            .acting_ms = @floatCast(acting_end.workingMsSince(round_start)),
            .training_ms = @floatCast(training_end.workingMsSince(acting_end)),
            .judging_ms = progress.pending_judging_ms,
            .device = learner.device_stats,
        };
        progress.pending_judging_ms = 0;
        try lab.SuperTrackLog.appendLine(gpa, &progress.log, round_line);
        // THE TRIPWIRES, once, after the first rounds (`lab.Tripwire`): a run that learns nothing ends here.
        if (try judgeTripwires(gpa, io, settings, learner, device_characters, progress)) |fired| {
            progress.tripwire_fired = fired;
            return .failed_tripwire;
        }
        // Where the round's time went: read once the device has done the round's last work.
        const round_rested_ms: f64 = ClockReading.now(progress.machine_share).slept_ms - round_start.slept_ms;
        const round_times: lab.RoundTimeLog.Line =
            roundTimes(learner, device_characters, progress, between_rounds_ms, round_rested_ms, work_before);
        try lab.RoundTimeLog.appendLine(gpa, &progress.times, round_times);
        progress.last_round_times = round_times;
        // Dispatches no timing mark covered leave the round's phases short of their time: said the first time.
        if (round_times.untimed_dispatches > 0 and !progress.has_said_untimed) {
            progress.has_said_untimed = true;
            say(io, "geno_trainer: round {d}: {d} dispatches untimed - the timing marks ran out, and time.csv's " ++
                "phases leave them out", .{ round_times.round, round_times.untimed_dispatches });
        }
        progress.round_ended_ms = wgpu.nowMs();
        progress.recent.add(round_line.steps_watched, round_line.failures);
        progress.planner_recent.add(round_line.planner_steps_watched, round_line.planner_failures);
        // And each clip's recent rounds, from the learner's per-clip counts.
        for (0..learner.exposure_by_clip.len) |clip| {
            const clip_steps: u64 = learner.exposure_by_clip[clip] - progress.clip_exposure_seen[clip];
            const clip_failures: u64 = learner.failures_by_clip[clip] - progress.clip_failures_seen[clip];
            progress.clip_recent[clip].add(clip_steps, clip_failures);
            progress.clip_exposure_seen[clip] = learner.exposure_by_clip[clip];
            progress.clip_failures_seen[clip] = learner.failures_by_clip[clip];
        }
        const minutes_since_save: f32 = superTrackMinutes(progress) - progress.saved_at_minutes;
        const is_save_due: bool = !progress.has_saved_this_start or minutes_since_save >= save_minutes;
        if (is_save_due) {
            saveSuperTrack(arena, io, folder, learner, settings, progress, .training) catch |err| switch (err) {
                error.StateNotFinite => return .failed_nonfinite,
                else => return err,
            };
        }
        // The policy file's play check, once a start, after its first save.
        if (progress.has_saved_this_start and !progress.has_checked_policy_this_start) {
            if (!try superTrackPolicyPlaysAsTrained(arena, io, folder, learner)) {
                say(io, "the policy file does not play as the learner acts - the run fails", .{});
                return error.PolicyDoesNotPlayAsTrained;
            }
            progress.has_checked_policy_this_start = true;
        }
        const minutes: f32 = superTrackMinutes(progress);
        const checkpoint_minutes: f32 = run.controls.checkpoint_minutes;
        const minutes_since_checkpoint: f32 = minutes - progress.checkpointed_at_minutes;
        const is_checkpoint_due: bool = checkpoint_minutes > 0 and minutes_since_checkpoint >= checkpoint_minutes;
        if (is_checkpoint_due) {
            const checkpoint_start: ClockReading = .now(progress.machine_share);
            saveSuperTrackCheckpoint(arena, io, folder, learner, settings, progress) catch |err| switch (err) {
                error.StateNotFinite => return .failed_nonfinite,
                else => return err,
            };
            progress.paused_ms += ClockReading.now(progress.machine_share).workingMsSince(checkpoint_start);
        }
        const judge_minutes: f32 = run.controls.judge_minutes;
        const minutes_since_judgement: f32 = minutes - progress.judged_at_minutes;
        const is_judgement_due: bool = judge_minutes > 0 and minutes_since_judgement >= judge_minutes;
        if (is_judgement_due) {
            const judging_start: ClockReading = .now(progress.machine_share);
            try judgeSuperTrackPolicy(gpa, arena, io, folder, learner, settings, progress, run.controls.probe);
            const judging_ms: f64 = ClockReading.now(progress.machine_share).workingMsSince(judging_start);
            progress.pending_judging_ms = @floatCast(judging_ms);
            progress.paused_ms += judging_ms;
            noteSuperTrackSuccess(io, progress);
            // Said at once as well as logged with the next round: what a judgement costs sets how often to judge.
            const judging_seconds: f32 = progress.pending_judging_ms / 1000;
            say(io, "judging and probing took {d:.1} s", .{judging_seconds});
        }
        reportSuperTrack(io, report_interval_ms, folder, learner, progress);
    }
}

/// A SuperTrack run, once its parameters are accepted: the GPU and Geno set up, the fleet built on SuperTrack's
/// training task, the servo measured on it, the clip's feature normaliser measured, the learner made - and carried on
/// from the folder's state when it has one - then training until the run ends, and the last save. Errors and refusals
/// end the run as `runTraining`'s do.
/// Whether `err` is a learner's refusal of a buffer too small for it (`kit_mlp.KitLayout.checkFitsKit`).
fn isBufferRefusal(err: anyerror) bool {
    return err == error.KitActivationsTooSmall or err == error.KitGradientsTooSmall or
        err == error.KitParametersTooSmall or err == error.KitRingTooSmall;
}

/// A buffer refused, said with this build's size of it and how to measure what the run needs (`--layout`).
fn sayBufferRefusal(io: Io, err: anyerror) void {
    const capacity: u32 = if (err == error.KitActivationsTooSmall)
        zn_mlp.acts_len
    else if (err == error.KitGradientsTooSmall)
        zn_mlp.dacts_len
    else if (err == error.KitRingTooSmall)
        zn_mlp.ring_len
    else
        zn_mlp.config.max;
    say(io, "geno_trainer: {s}: the run's learner needs more of that buffer than this build's {d} floats - " ++
        "`geno_trainer --run=<folder> --layout` measures what it needs", .{ @errorName(err), capacity });
}

/// A SuperTrack run's training fleet (`track.Fleet.Options`): its characters, their replay and their task, the
/// pushes, the returns and the curriculum, and how its physics runs - one definition for the run (`runSuperTrack`)
/// and its layout alone (`measureSuperTrackLayout`). With several clips each character keeps its own
/// (`track.ClipAssignment.by_character`), so a harder clip gets its share of the time. The physics' tasks are as many
/// as the run asks, within `machine_share` of the machine's cores (`physicsThreads`).
fn superTrackFleetOptions(
    settings: lab.SuperTrackLearner,
    body: *const GenoBody,
    clip_count: usize,
    machine_share: f32,
) track.Fleet.Options {
    const has_several_clips: bool = clip_count > 1;
    const clip_assignment: track.ClipAssignment = if (has_several_clips) .by_character else .random;
    const options: track.Fleet.Options = .{
        .envs = settings.characters,
        .capacity = settings.replay_steps,
        .action_scale = settings.action_scale,
        .task = lab.superTrackTrainingTask(settings),
        // Geno's task exempts its feet from unexpected contact by name; the fleet resolves them through these.
        .body_names = body.imported.names,
        .pushes = settings.pushes,
        .aftermath_steps = settings.aftermath_steps,
        .aftermath_share = settings.aftermath_share,
        .return_steps = settings.return_steps,
        .clip_assignment = clip_assignment,
        .curriculum = settings.curriculum,
        .limb_stiffness = settings.limb_stiffness,
        .physics_threads = physicsThreads(settings.physics_threads, machine_share),
        .decide_every = settings.decide_every,
        .max_steps = settings.max_steps,
    };
    return options;
}

/// THE RUN's BUFFERS, MEASURED (`--layout`): the learner the run describes, built on the CPU twin of the kernels - no
/// device - with what a run on the device adds to it (`DeviceCharacters`: the characters' acting rows, the teacher's
/// candidates' recording and their rows), and how much of each kernel buffer it all needs, against this build's sizes
/// (`zn_mlp_sizes_trainer.zig`). The device's strides are its simulator's layout for the run's worlds
/// (`robotgpu.layoutFor`), with no arena's bound. Nothing is trained and the folder is not written: a recipe's fit is
/// known before a night starts, on any machine. `finished` when every buffer holds what it needs; `refused` when one
/// does not - the learner refuses it by the buffer's name.
fn measureSuperTrackLayout(
    gpa: Allocator,
    io: Io,
    run: lab.GenoRun,
    settings: lab.SuperTrackLearner,
) !Exit {
    var body: GenoBody = undefined;
    try body.init(gpa);
    defer body.deinit();
    const model: *rbt.Model = &body.imported.model;
    var run_clips: RunClips = try .init(gpa, &body, run.task.motion, run.task.variants);
    defer run_clips.deinit(gpa);
    const clips: []const *const dance.Clip = run_clips.clips;
    const whole_machine: f32 = 1;
    const fleet_options: track.Fleet.Options = superTrackFleetOptions(settings, &body, clips.len, whole_machine);
    const fleet: *track.Fleet = try .init(gpa, model, clips, fleet_options);
    defer fleet.deinit();
    const normalizer: latent.Normalizer = try latent.measureClipNormalizer(gpa, model, clips);
    defer gpa.free(normalizer.mean);
    defer gpa.free(normalizer.spread);
    // A pipe that runs nothing: the trainer keeps no CPU twin of the kernels, and the measure needs none - the learner
    // is built as a run builds it, and its buffers' numbers kept.
    var pipe: z.Compute(zn_mlp) = .initMeasure();
    const options: resident.Options = settings.options();
    const learner: *SuperTrackLearner = SuperTrackLearner.init(gpa, &pipe, fleet, normalizer, options) catch |err| {
        if (!isBufferRefusal(err)) {
            return err;
        }
        sayBufferRefusal(io, err);
        return .refused;
    };
    defer learner.deinit();
    const teacher: lab.Teacher = settings.teacher;
    if (settings.physics == .device) {
        // The candidates first, a block a planner, then the characters - as `DeviceCharacters` lays them out.
        const character_count: u32 = @intCast(fleet.options.envs);
        const candidate_count: u32 = teacher.planners * teacher.planning.candidates_per_planner;
        // The clips' tables as the run's simulator is made with them (`DeviceCharacters`), for its model arenas.
        const tables: robotgpu_host.RunTables = try .init(gpa, fleet);
        defer tables.deinit(gpa);
        const world_counts: robotgpu.Counts = robotgpu.countsOf(model, candidate_count + character_count);
        const counts: robotgpu.Counts = robotgpu.countsWithClips(world_counts, tables.clips);
        const unbounded: u32 = maxInt(u32);
        const no_bounds: robotgpu.Capacities = .{
            .world_f = unbounded,
            .world_u = unbounded,
            .efc_f = unbounded,
            .model_u = unbounded,
            .model_f = unbounded,
            .io = unbounded,
        };
        const layout: robotgpu.Layout = try robotgpu.layoutFor(counts, no_bounds);
        // The simulator's arenas, each against this build's (`robotgpu_sizes`): what the device's buffers must hold -
        // a run past one is refused, as the simulator would refuse it at its start.
        const capacities: robotgpu.Capacities = .{};
        var arenas_fit: bool = true;
        inline for (@typeInfo(robotgpu.Capacities).@"struct".field_names) |arena_name| {
            const arena: robotgpu.Arena = @field(robotgpu.Arena, arena_name);
            const needed: u32 = robotgpu.arenaEnd(layout, counts, arena);
            const capacity: u32 = @field(capacities, arena_name);
            say(io, "geno_trainer: --layout: the simulator's {s}: {d} of {d}", .{ arena_name, needed, capacity });
            arenas_fit = arenas_fit and needed <= capacity;
        }
        if (!arenas_fit) {
            say(io, "geno_trainer: --layout: the run's worlds do not fit this build's simulator", .{});
            return .refused;
        }
        const arrays: robotgpu.WorldStateLayout = layout.world_f;
        const input_stride: u32 = arrays.policy_inputs.stride;
        const action_stride: u32 = arrays.actions.stride;
        try learner.acceptDeviceActing(candidate_count, character_count, input_stride, action_stride);
        if (teacher.planners > 0) {
            const per_planner: u32 = teacher.planning.candidates_per_planner;
            const horizon: u32 = counts.plan_horizon;
            try learner.acceptCandidateRecording(candidate_count, per_planner, horizon, teacher.lookaheads_kept);
            try learner.acceptCandidateActing(candidate_count);
        }
    }
    const used: @FieldType(SuperTrackLearner, "buffers_used") = learner.buffers_used;
    say(io, "geno_trainer: --layout: activations {d} of {d} floats, their gradients {d} of {d}, " ++
        "parameters {d} of {d}, the replay's ring {d} of {d}", .{
        used.acts_floats,
        zn_mlp.acts_len,
        used.dacts_floats,
        zn_mlp.dacts_len,
        used.params_floats,
        zn_mlp.config.max,
        used.ring_floats,
        zn_mlp.ring_len,
    });
    // The two large buffers in megabytes, each one storage binding: a run prints what its device binds in one, and the
    // Vulkan host refuses a binding past it by name.
    const float_bytes: u64 = @sizeOf(f32);
    const activations_megabytes: u64 = (@as(u64, zn_mlp.acts_len) * float_bytes) >> 20;
    const ring_megabytes: u64 = (@as(u64, zn_mlp.ring_len) * float_bytes) >> 20;
    say(io, "geno_trainer: --layout: the activations' buffer {d} MB, the ring's {d} MB", .{
        activations_megabytes,
        ring_megabytes,
    });
    return .finished;
}

/// A SUPERTRACK RUN, once its parameters are accepted: the GPU, Geno and the run's clips set up, the training fleet
/// and the learner made, the folder's state resumed, the characters put on the device where the run asks, then
/// training round after round until the run ends (`trainSuperTrack`), and the last save. Every pipe on the device -
/// the learner's, the simulator's - keeps to `machine_share`, the physics' tasks within its share of the cores, and
/// the run's clocks leave its rests out.
fn runSuperTrack(
    gpa: Allocator,
    io: Io,
    report_interval_ms: f64,
    arena_state: *ArenaAllocator,
    folder: []const u8,
    run: lab.GenoRun,
    settings: lab.SuperTrackLearner,
    machine_share: *z.MachineShare,
    kernel_check: KernelCheckAtStart,
) !Exit {
    const arena: Allocator = arena_state.allocator();
    const stale_stop_path: []const u8 = try runFilePath(arena, folder, .stop);
    try native_os.deleteFileIfPresent(io, stale_stop_path);

    // The GPU, without a window: the networks train there.
    const screen_side: u32 = 64;
    try vulkan_host.startHeadlessWithScreen(screen_side, screen_side);
    defer _ = vulkan_host.shutdown();
    const device: wgpu.DeviceHandle = wgpu.initDevice();
    const queue: wgpu.QueueHandle = wgpu.getQueue(device);
    // The learner's pipe, its pipelines made in the call: the device's driver compiles each kernel from the module's
    // SPIR-V as its pipeline is made. The time it takes, its buffers' making with it, is said - so that two builds of
    // the kernels compare at their start as well as in their rounds.
    const pipe_started_ms: f64 = wgpu.nowMs();
    var pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &kernelEntries());
    defer pipe.deinit();
    const pipe_seconds: f64 = (wgpu.nowMs() - pipe_started_ms) / 1000;
    say(io, "geno_trainer: the learner's pipe made - its buffers and its {d} kernels' pipelines - in {d:.1} s", .{
        zn_mlp.kernels.len,
        pipe_seconds,
    });
    if (!try checkKernelsAtStart(gpa, io, &pipe, kernel_check)) {
        return .failed;
    }
    pipe.shareMachine(machine_share);

    var body: GenoBody = undefined;
    try body.init(gpa);
    defer body.deinit();
    const model: *rbt.Model = &body.imported.model;
    // The run's clips: the first of Geno's, as many as its motion names (`lab.GenoMotion.clipLabels`), then their
    // variants (`RunClips`) - with several, each character keeping its own (`track.ClipAssignment.by_character`), so
    // a harder clip gets its share of the time.
    var run_clips: RunClips = try .init(gpa, &body, run.task.motion, run.task.variants);
    defer run_clips.deinit(gpa);
    const clips: []const *const dance.Clip = run_clips.clips;
    const clip_labels: []const []const u8 = run_clips.labels;
    const character_count: usize = settings.characters;
    const fleet_options: track.Fleet.Options = superTrackFleetOptions(settings, &body, clips.len, machine_share.share);
    const fleet: *track.Fleet = try .init(gpa, model, clips, fleet_options);
    // The physics' tasks on the trainer's own threads: the same numbers, sooner.
    fleet.physics_io = io;
    defer fleet.deinit();

    // The clips' labels, as every judgement and probe line names them, and which of them are judged.
    var progress: SuperTrackProgress = .{
        .clip_labels = clip_labels,
        .judged_clip_count = run_clips.judged_count,
        .kept_state_checkpoints = run.controls.kept_state_checkpoints,
        .machine_share = machine_share,
    };
    const clips_fit: bool = clips.len <= SuperTrackProgress.most_clips;
    assertf(clips_fit, @src(), "{d} clips; the progress keeps {d}", .{ clips.len, SuperTrackProgress.most_clips });
    defer progress.log.deinit(gpa);
    defer progress.judgements.deinit(gpa);
    defer progress.recoveries.deinit(gpa);
    defer progress.times.deinit(gpa);
    defer if (progress.tripwire_start) |start| {
        gpa.free(start.parameters);
    };
    defer for (progress.kernel_totals) |totals| {
        totals.deinit(gpa);
    };
    try progress.log.appendSlice(gpa, lab.SuperTrackLog.header);
    try progress.times.appendSlice(gpa, lab.RoundTimeLog.header);
    // The servo alone on the training fleet, counted as the learner counts itself: a step watched per character and
    // a failure for each that lost the reference. It also puts real steps in the replay before the learner exists.
    const zero_actions: []f32 = try gpa.alloc(f32, character_count * fleet.action_width);
    defer gpa.free(zero_actions);
    @memset(zero_actions, 0.0);
    const servo_steps: usize = 200;
    var servo_failures: u64 = 0;
    for (0..servo_steps) |_| {
        _ = fleet.step(zero_actions);
        for (fleet.failures) |is_lost| {
            if (is_lost) {
                servo_failures += 1;
            }
        }
    }
    // A fleet's step is a decision: the decisions watched, over the decisions a second.
    const decisions_per_second: f32 = 1.0 / fleet.decisionSeconds();
    const servo_decisions_watched: u64 = character_count * servo_steps;
    progress.servo_seconds_to_failure = ppo_track.secondsToFailure(
        servo_decisions_watched,
        servo_failures,
        decisions_per_second,
    );
    // The features' normaliser from the reference clips themselves (SuperTrack's way) - over every clip of the run,
    // so the get-up's lying and the dance's steps are both typical to it: fixed before the first step. A resumed run
    // takes the one its state file saved instead.
    const normalizer: latent.Normalizer = try latent.measureClipNormalizer(gpa, model, clips);
    defer gpa.free(normalizer.mean);
    defer gpa.free(normalizer.spread);
    const learner: *SuperTrackLearner = try .init(gpa, &pipe, fleet, normalizer, settings.options());
    defer learner.deinit();
    if (!try resumeSuperTrack(gpa, arena, io, folder, learner, &progress)) {
        return .refused;
    }
    // The characters on the device, when the run asks for them (`lab.TrainingPhysics.device`): the simulator on the
    // learner's own device, after the resume - its clock is the learner's count of acting steps, which the state
    // file restores.
    var characters_on_device: ?DeviceCharacters = null;
    defer if (characters_on_device) |*characters| {
        characters.deinit(gpa);
    };
    if (settings.physics == .device) {
        const teacher: lab.Teacher = settings.teacher;
        const simulator_started_ms: f64 = wgpu.nowMs();
        const characters: DeviceCharacters =
            DeviceCharacters.init(gpa, device, queue, fleet, learner, teacher) catch |err| {
                if (err != error.WindowLongerThanLookahead) {
                    return err;
                }
                say(io, "geno_trainer: learner.supertrack.window: longer than a planner's lookahead - a window " ++
                    "of the candidates is drawn inside one lookahead", .{});
                return .refused;
            };
        const simulator_seconds: f64 = (wgpu.nowMs() - simulator_started_ms) / 1000;
        say(io, "geno_trainer: the simulator made - its tables, its buffers and its {d} kernels' pipelines - " ++
            "in {d:.1} s", .{ robotgpu.kernels.len, simulator_seconds });
        characters_on_device = characters;
        characters_on_device.?.simulator.pipe.shareMachine(machine_share);
        const simulator: *const robotgpu_host.Sim = &characters_on_device.?.simulator;
        const candidate_count: u32 = teacher.planners * teacher.planning.candidates_per_planner;
        say(io, "geno_trainer: the characters are simulated on the device - {d} worlds, {d} curriculum bins", .{
            simulator.counts.world_count,
            simulator.counts.curriculum_bin_total,
        });
        if (teacher.planners > 0) {
            say(io, "geno_trainer: the teacher - {d} planners among the characters, {d} candidates before them, " ++
                "a replan every {d} decisions over {d}", .{
                teacher.planners,
                candidate_count,
                teacher.planning.replan_interval,
                simulator.counts.plan_horizon,
            });
        }
    }
    const device_characters: ?*DeviceCharacters = if (characters_on_device) |*characters| characters else null;
    // THE RUN's TIME (`lab.RoundTimeLog`): both pipes time their dispatches on the device - by phase, or one by one
    // for a run that asks for its kernels' times - and the learner and the simulator tell the host's clock each
    // phase they enter.
    const times_kernels: bool = run.controls.kernel_times;
    const marks_per_dispatch: u32 = 1 << 17;
    // By phase, each submission's segments take a mark each and one more: room for 32,000 submissions a round, a
    // round's decisions, its replans' lookaheads and its training many times over.
    const marks_per_round: u32 = 1 << 16;
    const timing_options: z.TimingOptions = if (times_kernels)
        .{ .mark_capacity = marks_per_dispatch, .per_dispatch = true }
    else
        .{ .mark_capacity = marks_per_round };
    const device_is_timed: bool = try pipe.enableTimings(timing_options);
    learner.phase_clock = &progress.clock;
    if (device_characters) |characters| {
        _ = try characters.simulator.pipe.enableTimings(timing_options);
        characters.simulator.phase_clock = &progress.clock;
    }
    if (!device_is_timed) {
        say(io, "geno_trainer: this device writes no compute timestamps - time.csv holds the host's times alone", .{});
    }
    if (device_is_timed and times_kernels) {
        const learner_names: []const []const u8 = pipe.kernelNames();
        progress.kernel_totals[@backingInt(TimedPipe.learner)] = try KernelTotals.init(gpa, learner_names);
        if (device_characters) |characters| {
            const simulator_names: []const []const u8 = characters.simulator.pipe.kernelNames();
            progress.kernel_totals[@backingInt(TimedPipe.simulator)] = try KernelTotals.init(gpa, simulator_names);
        }
        say(io, "geno_trainer: every dispatch is timed - kernel_times.csv, written with each save", .{});
    }
    // How much of each kernel buffer the learner fills: a run near a limit is seen at its start, before it grows.
    const used: @FieldType(SuperTrackLearner, "buffers_used") = learner.buffers_used;
    const acts_share: f32 = float(used.acts_floats) / float(zn_mlp.acts_len);
    const dacts_share: f32 = float(used.dacts_floats) / float(zn_mlp.dacts_len);
    const params_share: f32 = float(used.params_floats) / float(zn_mlp.config.max);
    const ring_share: f32 = float(used.ring_floats) / float(zn_mlp.ring_len);
    say(io, "geno_trainer: buffers used - activations {d:.0}%, their gradients {d:.0}%, parameters {d:.0}%, " ++
        "the replay's ring {d:.0}%", .{
        100 * acts_share,
        100 * dacts_share,
        100 * params_share,
        100 * ring_share,
    });
    // The device's own envelope, beside it: the most one buffer may bind, and its memory.
    const capabilities: vulkan_host.ComputeCapabilities = wgpu.computeCapabilities();
    const megabyte: f32 = 1024 * 1024;
    const binding_megabytes: f32 = float(capabilities.max_storage_binding_bytes) / megabyte;
    const device_megabytes: f32 = float(capabilities.device_local_bytes) / megabyte;
    const activations_megabytes: f32 = float(zn_mlp.acts_len) * @sizeOf(f32) / megabyte;
    const ring_megabytes: f32 = float(zn_mlp.ring_len) * @sizeOf(f32) / megabyte;
    say(io, "geno_trainer: the device binds {d:.0} MB in one buffer and holds {d:.0} MB; the activations take " ++
        "{d:.0} MB, the replay's ring {d:.0} MB", .{
        binding_megabytes,
        device_megabytes,
        activations_megabytes,
        ring_megabytes,
    });
    // The device's memory the run's buffers take - the networks', and the simulator's where the characters live
    // there: made whole at this build's sizes, whatever the run fills - against the device's, and its share.
    const networks_megabytes: f32 = float(@sizeOf(zn_mlp.Buffers)) / megabyte;
    const simulator_bytes: usize = if (device_characters != null) @sizeOf(robotgpu.Buffers) else 0;
    const buffers_megabytes: f32 = networks_megabytes + float(simulator_bytes) / megabyte;
    const memory_share: f32 = buffers_megabytes / @max(device_megabytes, 1);
    say(io, "geno_trainer: the run's buffers take {d:.0} MB of the device's memory, {d:.0}% of it", .{
        buffers_megabytes,
        100 * memory_share,
    });
    if (memory_share > machine_share.share) {
        say(io, "geno_trainer: that is more than the machine's share, {d:.0}% - the buffers' sizes are this " ++
            "build's (`zn_mlp_sizes_trainer.zig`, `robotgpu_sizes.zig`)", .{100 * machine_share.share});
    }
    // The clips: how many, their frames, and the variants among them.
    const variant_count: usize = clips.len - run_clips.judged_count;
    say(io, "geno_trainer: {d} clips, {d} judged and {d} variants, {d} frames in all", .{
        clips.len,
        run_clips.judged_count,
        variant_count,
        run_clips.frameCount(),
    });
    say(io, "geno_trainer: SuperTrack on the {s} in {s}, {d} characters", .{
        run.task.motion.label(),
        folder,
        character_count,
    });
    progress.started = .now(progress.machine_share);
    progress.saved_at_minutes = progress.minutes_before_this_start;
    progress.checkpointed_at_minutes = progress.minutes_before_this_start;

    const end_state: RunState = try trainSuperTrack(
        gpa,
        io,
        report_interval_ms,
        arena_state,
        folder,
        run,
        settings,
        learner,
        device_characters,
        &progress,
    );
    _ = arena_state.reset(.retain_capacity);
    const final_arena: Allocator = arena_state.allocator();
    try saveSuperTrack(final_arena, io, folder, learner, settings, &progress, end_state);
    if (end_state == .stopped) {
        const consumed_stop_path: []const u8 = try runFilePath(final_arena, folder, .stop);
        try native_os.deleteFileIfPresent(io, consumed_stop_path);
    }
    say(io, "geno_trainer: {s} at round {d}, {d:.1} minutes trained", .{
        @tagName(end_state),
        progress.rounds,
        superTrackMinutes(&progress),
    });
    if (end_state == .failed_nonfinite) {
        say(io, "geno_trainer: {s} stopped being finite - the last saved state and checkpoints are from before", .{
            progress.nonfinite_cause,
        });
        // A run the watchdog stopped has failed, whatever it saved: a script running the trainer is told so.
        return .failed;
    }
    if (progress.tripwire_fired) |fired| {
        const fired_text: []const u8 = try fired.text(final_arena);
        say(io, "geno_trainer: a tripwire fired after the first rounds - {s}; the run learns nothing", .{fired_text});
        // A run that learns nothing has failed: the next run of a night starts instead.
        return .failed;
    }
    return .finished;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const arguments: TrainerArgs = cli.args(&init, TrainerArgs, trainer_cli);
    // A folder of runs reported, nothing trained.
    const runs_to_report: []const u8 = arguments.@"--report";
    if (runs_to_report.len > 0) {
        const reported: Exit = writeRunsReport(gpa, arena, io, runs_to_report, arguments.@"--control") catch |err| {
            say(io, "geno_trainer: the report failed: {s}", .{@errorName(err)});
            return Exit.failed.code();
        };
        return reported.code();
    }
    const folder: []const u8 = arguments.@"--run";
    if (folder.len == 0) {
        say(io, "geno_trainer: refused: name the run folder, --run=<folder>", .{});
        return Exit.refused.code();
    }
    native_os.makeFolder(io, folder) catch |err| {
        say(io, "geno_trainer: refused: the run folder {s} cannot be made ({s})", .{ folder, @errorName(err) });
        return Exit.refused.code();
    };
    const run: lab.GenoRun = try readRunParameters(gpa, arena, io, folder) orelse return Exit.refused.code();
    if (run.problem()) |why| {
        say(io, "geno_trainer: refused: run.zon: {s}", .{why});
        return Exit.refused.code();
    }
    // The run's buffers measured alone, no device: whether a recipe fits this build.
    if (arguments.@"--layout") {
        const settings: lab.SuperTrackLearner = switch (run.learner) {
            .supertrack => |supertrack_settings| supertrack_settings,
            .ppo, .efficient_tdmpc => {
                say(io, "geno_trainer: refused: --layout measures a SuperTrack run's buffers", .{});
                return Exit.refused.code();
            },
        };
        const measured: Exit = measureSuperTrackLayout(gpa, io, run, settings) catch |err| failed: {
            say(io, "geno_trainer: failed: {s}", .{@errorName(err)});
            break :failed .failed;
        };
        return measured.code();
    }
    // THE MACHINE's SHARE (`--machine-share`, `z.MachineShare`): below 1 the run leaves the rest of the machine to
    // its user - the program's priority below the other programs', the physics on that share of the cores at most,
    // the device rested after each submission so that it works that share of the time.
    const share: f32 = arguments.@"--machine-share";
    const is_share: bool = share > 0 and share <= 1;
    if (!is_share) {
        say(io, "geno_trainer: refused: --machine-share={d}: above 0 and at most 1", .{share});
        return Exit.refused.code();
    }
    var machine_share: z.MachineShare = .{ .share = share, .io = io };
    if (machine_share.rests()) {
        const is_lowered: bool = native_os.lowerProgramPriority();
        const priority: []const u8 = if (is_lowered) "below the other programs'" else "unchanged - the system refused";
        say(io, "geno_trainer: {d:.0}% of the machine - the device rested after each submission, the physics on " ++
            "{d:.0}% of the cores at most, the priority {s}", .{ 100 * share, 100 * share, priority });
    }
    const report_interval_ms: f64 = 1000.0 * arguments.@"--report-seconds";
    const kernel_check: KernelCheckAtStart = if (arguments.@"--skip-kernel-check") .skip else .check;
    // The learner the run chose, each on its own path; EfficientTDMPC joins the trainer later.
    const trained: anyerror!Exit = switch (run.learner) {
        .ppo => runTraining(
            gpa,
            io,
            report_interval_ms,
            &arena_state,
            folder,
            run.toPpoRun().?,
            &machine_share,
            kernel_check,
        ),
        .supertrack => |settings| runSuperTrack(
            gpa,
            io,
            report_interval_ms,
            &arena_state,
            folder,
            run,
            settings,
            &machine_share,
            kernel_check,
        ),
        .efficient_tdmpc => {
            say(io, "geno_trainer: refused: run.zon: learner.efficient_tdmpc is not in the trainer yet", .{});
            return Exit.refused.code();
        },
    };
    const exit: Exit = trained catch |err| failed: {
        say(io, "geno_trainer: failed: {s}", .{@errorName(err)});
        if (isBufferRefusal(err)) {
            sayBufferRefusal(io, err);
        }
        break :failed .failed;
    };
    return exit.code();
}
