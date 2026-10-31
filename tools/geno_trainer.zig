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
//!     policy, policy_m<N>    the newest policy and its checkpoints - a Gaussian policy's; a flow run keeps none
//!     log.csv                one line per round, a column for every number the learner keeps
//!                            (`robot_lab.SuperTrackLog`)
//!     judge.csv              every judgement, a line per clip, the servo's first (`robot_lab.JudgeLog`)
//!     recovery.csv           every judgement's probe, a line per clip and push speed: survived, lost, returned
//!                            (`robot_lab.RecoveryLog`)
//!     status.zon             also says what stopped being finite in a run the watchdog stopped, and the clip whose
//!                            policy collapsed, when one has
//!
//! Every file is written whole to `<name>.new` and renamed over the old one, so a reader never sees half a file and
//! a run stopped in the middle of a write keeps the previous version. Started again on the same folder, the trainer
//! carries on from the folder's weights and log; weights that do not fit the run's network (another width, another
//! motion) are refused, and the folder is left untouched. The run ends when its `stop` file appears, or after the
//! hours or batches `run.zon` allows; then the last weights, the log and the status are written, and the program
//! exits 0. It exits 1 when it refuses the run - an unreadable `run.zon`, a value out of its range
//! (`robot_lab.GenoRun.problem`), weights that do not fit - and 2 when the run fails: the GPU or the robot cannot be
//! set up, a file cannot be written, or something stopped being finite (the watchdog; the status names it, and the
//! state saved before it is kept).
//!
//! A run's folder belongs outside the repository: what a run writes is large and is not source. The recipes kept in
//! the repository are `examples/geno_lab/recipes/<name>.zon`, each copied into a new folder as its `run.zon`:
//!
//!     geno_trainer --run=../geno_runs/night1_full

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;
const parseFloat = std.fmt.parseFloat;
const parseInt = std.fmt.parseInt;
const splitScalar = std.mem.splitScalar;
const basename = std.fs.path.basename;
const copyForwards = std.mem.copyForwards;
const z = @import("zimr");
const zm = @import("zm");
const assertf = zm.assertf;
const float = zm.float;
const float64 = zm.float64;
const cli = @import("cli");
const zn_mlp = @import("zn_mlp");

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
const SuperTrackLearner = resident.Resident(zn_mlp);
const eql = std.mem.eql;
const clamp = zm.clamp;

/// The network kernels' SPIR-V: one module holding every entry of `zn_mlp`.
const zn_mlp_spirv: []const u8 = @embedFile("zn_mlp_spv");
/// The dance, retargeted to Geno and baked (`zig build clip-bake`), as the training page embeds it.
const dance_zclip: []const u8 = @embedFile("geno_dance_zclip");
/// LAFAN1's whole fall and get-up take on Geno (`robot_geno`'s bake), the second clip of a `dance_and_getup` run.
const getup_zclip: []const u8 = @embedFile("geno_getup_zclip");
/// Walking and running on Geno (`robot_geno`'s bake): the rest of a `one_minute` run.
const walk_zclip: []const u8 = @embedFile("geno_walk_zclip");
const run_zclip: []const u8 = @embedFile("geno_run_zclip");

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
    /// Wall-clock milliseconds when training started, and the minutes trained before it by earlier starts.
    started_at_ms: f64 = 0,
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

/// The minutes the run has trained, over every start.
fn trainingMinutes(progress: *const RunProgress) f32 {
    const elapsed_ms: f64 = wgpu.nowMs() - progress.started_at_ms;
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
        lab.policyMeanAction(&policy, observation, scratch, policy_action);
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
/// learner's own judging actor - a flow run's, whose policy no policy file holds.
const ProbedController = union(enum) {
    servo,
    policy: *const lab.GenoPolicy,
    learner_actor: track.Actor,
};

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
    action_scale: f32,
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
        .learner_actor => |actor| {
            // The judge's fleet, as `lab.judgePolicy` makes it, acted on by the learner itself.
            const fleet_options: track.Fleet.Options = .{
                .action_scale = action_scale,
                .task = judge_settings.task,
                .body_names = body_names,
            };
            try track.probeRecovery(gpa, model, clip, fleet_options, judge_settings.starts, actor, probe, bands);
        },
    }
    if (recoveries.items.len == 0) {
        try recoveries.appendSlice(gpa, lab.RecoveryLog.header);
    }
    try lab.RecoveryLog.appendLines(gpa, recoveries, batches, minutes, clip_label, bands, clip.frame_time);
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
            band.meanRecoverySeconds(clip.frame_time),
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
    if (progress.judgements.items.len == 0) {
        try progress.judgements.appendSlice(gpa, lab.JudgeLog.header);
        const servo: track.Judgement = try lab.judgePolicy(gpa, arena, trainer.m, body_names, clip, null, settings);
        try lab.JudgeLog.appendLine(gpa, &progress.judgements, 0, 0, progress.clip_label, servo);
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
            trainer.env.options.action_scale,
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
        trainer.env.options.action_scale,
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
};

const trainer_cli: cli.Config(TrainerArgs) = .{
    .prog = "geno_trainer",
    .description = "Trains Geno to track the dance with PPO or SuperTrack, headless, in a run folder: reads its " ++
        "run.zon, writes its state, policy, log.csv and status.zon as it goes, carries on from them when started " ++
        "again, and ends when the folder's stop file appears or the run's limits are reached.",
    .args = .{
        .@"--run" = .{ .description = "the run folder (made if missing)" },
        .@"--report-seconds" = .{ .description = "seconds between progress lines, at most" },
    },
};

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
    }

    fn deinit(body: *GenoBody) void {
        body.run_clip.deinit();
        body.walk_clip.deinit();
        body.getup_clip.deinit();
        body.clip.deinit();
        body.imported.deinit();
        body.robot.deinit();
        body.document.deinit();
    }
};

/// The run, once its parameters are accepted: the GPU and Geno set up, the folder's weights resumed, the servo
/// measured, then training until the run ends, and the last save. An error - the GPU or the robot that cannot be set
/// up, a file that cannot be written - ends the run, as `main` reports (exit 2); the weights that do not fit the run
/// refuse it (exit 1).
fn runTraining(
    gpa: Allocator,
    io: Io,
    report_interval_ms: f64,
    arena_state: *ArenaAllocator,
    folder: []const u8,
    parameters: lab.PpoRun,
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

    // Geno, exactly as the training page builds it.
    var body: GenoBody = undefined;
    try body.init(gpa);
    defer body.deinit();
    const imported: *rmj.Imported = &body.imported;
    const clips = [_]*const dance.Clip{&body.clip};
    const trainer_options: ppo_track.Options = parameters.recipe.options(parameters.motion);
    const trainer: *Trainer = try .init(gpa, &pipe, &imported.model, imported.names, &clips, trainer_options);
    defer trainer.deinit();

    var progress: RunProgress = .{ .clip_label = parameters.motion.label() };
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
    progress.started_at_ms = wgpu.nowMs();
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
    progress.started_at_ms = wgpu.nowMs();
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

    /// Seconds between failures over the window (`ppo_track.secondsToFailure`); null while nothing in it failed.
    fn secondsToFailure(self: *const RecentRounds, physics_steps_per_second: f32) ?f32 {
        var steps_watched: u64 = 0;
        var failures: u64 = 0;
        const counted: usize = @min(self.count, window_rounds);
        for (0..counted) |slot| {
            steps_watched += self.steps_watched[slot];
            failures += self.failures[slot];
        }
        return ppo_track.secondsToFailure(steps_watched, failures, physics_steps_per_second);
    }
};

/// The learner's running totals a round's line counts the differences of (`lab.SuperTrackLog.Line`): read before
/// and after each round.
const RoundTotals = struct {
    steps_watched: u64,
    failures: u64,
    pushes: u64,
    push_speed_sum: f64,
    planning_decisions: u64,
    planned_steps: u64,
    nonfinite_actions: u64,
    mirrors_refused: u64,
    windows_refused: u64,
    returns: u64,
    return_steps_sum: u64,

    fn of(learner: *const SuperTrackLearner) RoundTotals {
        const totals: RoundTotals = .{
            .steps_watched = learner.exposure,
            .failures = learner.failures,
            .pushes = learner.fleet.pushes_given,
            .push_speed_sum = learner.fleet.push_speed_sum,
            .planning_decisions = learner.planning_decisions,
            .planned_steps = learner.planned_steps,
            .nonfinite_actions = learner.nonfinite_actions,
            .mirrors_refused = learner.mirror_rejected,
            .windows_refused = learner.windows_refused,
            .returns = learner.fleet.returns,
            .return_steps_sum = learner.fleet.return_steps_sum,
        };
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

/// The physics' tasks a run asks for (`lab.SuperTrackLearner.physics_threads`): 0 is every core of the machine.
fn physicsThreads(asked: u32) u32 {
    if (asked > 0) {
        return asked;
    }
    const core_count: usize = std.Thread.getCpuCount() catch 1;
    return @intCast(@max(core_count, 1));
}

/// Where a SuperTrack run is between rounds: its log, its rounds and their recent failures, when it started and last
/// saved. Plain state, as `RunProgress` is for PPO.
const SuperTrackProgress = struct {
    /// State checkpoints kept at once (`saveSuperTrackCheckpoint`): each holds every weight and the optimisers'
    /// moments, so a long run keeps the newest few rather than all.
    const kept_state_checkpoints: usize = 4;

    /// The most clips a run trains at once (`lab.GenoMotion.dance_and_getup`).
    const most_clips: usize = 4;

    /// The run's clips as the judge's and the probe's lines name them - one per clip of the fleet, in its order.
    clip_labels: []const []const u8 = &.{"dance"},
    /// Each clip's recent rounds, and the learner's per-clip counts already taken into them.
    clip_recent: [most_clips]RecentRounds = @splat(.{}),
    clip_exposure_seen: [most_clips]u64 = @splat(0),
    clip_failures_seen: [most_clips]u64 = @splat(0),
    /// The milliseconds the last judgement and its probes took - carried into the next round's line, the round they
    /// delayed.
    pending_judging_ms: f32 = 0,
    /// What stopped being finite, once the watchdog has seen it (`Resident.nonfiniteCause`); empty while all is.
    nonfinite_cause: []const u8 = "",
    /// The clip the collapse alarm names (`lab.JudgeLog.collapsedClip`), or empty.
    collapsed_clip: []const u8 = "",
    /// The minutes of the state checkpoints this start has written and keeps, oldest first - `kept_state_checkpoints`
    /// of them at most (`saveSuperTrackCheckpoint`).
    state_checkpoint_minutes: [kept_state_checkpoints]u64 = @splat(0),
    state_checkpoint_count: usize = 0,
    log: ArrayList(u8) = .empty,
    rounds: u64 = 0,
    servo_seconds_to_failure: ?f32 = null,
    /// Wall-clock milliseconds when training started, and the minutes trained before it by earlier starts.
    started_at_ms: f64 = 0,
    minutes_before_this_start: f32 = 0,
    has_saved_this_start: bool = false,
    saved_at_minutes: f32 = 0,
    reported_at_ms: f64 = 0,
    recent: RecentRounds = .{},
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

/// The minutes a SuperTrack run has trained, over every start.
fn superTrackMinutes(progress: *const SuperTrackProgress) f32 {
    const elapsed_ms: f64 = wgpu.nowMs() - progress.started_at_ms;
    const elapsed_minutes: f32 = @floatCast(elapsed_ms / 60_000.0);
    return progress.minutes_before_this_start + elapsed_minutes;
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
    return lab.policyOfSuperTrack(arena, learner.policyParts(), action_scale);
}

/// Everything a SuperTrack run keeps, each file written whole: its state (`supertrack_state`), its policy, its log
/// and its status, with the recent time to failure over the last rounds (`RecentRounds`). Memory: every file's
/// bytes and every path in `arena`, the caller's scratch for this save.
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
    // The policy file holds a Gaussian policy; a flow run's policy lives in its state file alone (the file would hold
    // the untrained Gaussian policy the flow replaced, which no one should play).
    if (saves_state and settings.actor != .flow) {
        const policy: lab.GenoPolicy = try superTrackPolicy(arena, learner, settings.action_scale);
        const policy_bytes: []u8 = try lab.PolicyFile.encode(arena, &policy);
        const policy_path: []const u8 = try pathIn(arena, folder, RunFile.policy_name);
        try writeWhole(arena, io, policy_path, policy_bytes);
    }
    const log_path: []const u8 = try runFilePath(arena, folder, .log);
    try writeWhole(arena, io, log_path, progress.log.items);
    const physics_steps_per_second: f32 = 1.0 / learner.fleet.m.opt.timestep;
    // Each clip on its own line, when there are several.
    const clip_count: usize = progress.clip_labels.len;
    const clip_statuses: []lab.ClipStatus = try arena.alloc(lab.ClipStatus, if (clip_count > 1) clip_count else 0);
    for (clip_statuses, progress.clip_labels[0..clip_statuses.len], 0..) |*clip_status, label, clip| {
        clip_status.* = .{
            .clip = label,
            .recent_seconds_to_failure = progress.clip_recent[clip].secondsToFailure(physics_steps_per_second),
        };
    }
    const status: RunStatus = .{
        .state = state,
        .batches = progress.rounds,
        .steps = learner.exposure,
        .training_minutes = superTrackMinutes(progress),
        .servo_seconds_to_failure = progress.servo_seconds_to_failure,
        .recent_seconds_to_failure = progress.recent.secondsToFailure(physics_steps_per_second),
        .assist = 0,
        .written_at_seconds = native_os.wallClockSeconds(io),
        .clips = clip_statuses,
        .world_model_loss = learner.device_stats.world_model_loss,
        .critic_value_error = learner.device_stats.critic_value_error,
        .policy_gradient_norm = learner.device_stats.policy_gradient_norm,
        .windows_refused = learner.windows_refused,
        .nonfinite_actions = learner.nonfinite_actions,
        .nonfinite = progress.nonfinite_cause,
        .collapse = progress.collapsed_clip,
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
/// run keeps them - the lab's timeline of a run (none for a flow run: the policy file holds Gaussian policies only) -
/// and its whole state, `supertrack_state_m<minute>`, the newest few that this start has written kept
/// (`SuperTrackProgress`; an earlier start's stay, so a resumed run may hold more): what a run goes back to when its
/// newest state is not the one wanted, and a flow run's only way back. Nothing is written when the newest readback is
/// not finite (`error.StateNotFinite`, the watchdog's). Memory: the policy, the state, their bytes and the paths in
/// `arena`.
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
    if (settings.actor != .flow) {
        const policy: lab.GenoPolicy = try superTrackPolicy(arena, learner, settings.action_scale);
        const policy_bytes: []u8 = try lab.PolicyFile.encode(arena, &policy);
        const checkpoint_name: []const u8 = RunFile.policyCheckpointName(whole_minutes, &name_buffer);
        const checkpoint_path: []const u8 = try pathIn(arena, folder, checkpoint_name);
        try writeWhole(arena, io, checkpoint_path, policy_bytes);
    }
    // The state, and the oldest kept one let go once more than `kept_state_checkpoints` are. A checkpoint in the same
    // minute as the newest kept one overwrites it, and is not kept twice.
    const state_bytes: []u8 = try learner.exportState(arena);
    const state_name: []const u8 = RunFile.stateCheckpointName(whole_minutes, &name_buffer);
    const state_path: []const u8 = try pathIn(arena, folder, state_name);
    try writeWhole(arena, io, state_path, state_bytes);
    const kept: []u64 = &progress.state_checkpoint_minutes;
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
    const frames_per_second: usize = 60;
    const body_names: []const []const u8 = fleet.options.body_names;
    const model: *rbt.Model = fleet.m;
    const is_first_judgement: bool = progress.judgements.items.len == 0;
    if (is_first_judgement) {
        try progress.judgements.appendSlice(gpa, lab.JudgeLog.header);
    }
    // What is judged: the Gaussian policy's file, as the lab plays it - or, for a flow run, whose policy no policy
    // file holds, the learner's own judging actor (its flow from its mirror, at zero noise) on the judge's fleet.
    const is_flow_run: bool = settings.actor == .flow;
    var policy: ?*lab.GenoPolicy = null;
    if (!is_flow_run) {
        const file_policy: *lab.GenoPolicy = try arena.create(lab.GenoPolicy);
        file_policy.* = try superTrackPolicy(arena, learner, settings.action_scale);
        policy = file_policy;
    }
    const judged: ProbedController = if (policy) |file_policy|
        .{ .policy = file_policy }
    else
        .{ .learner_actor = learner.judgeActor() };
    const minutes: f32 = superTrackMinutes(progress);
    const rounds: u64 = progress.rounds;
    for (fleet.clips, progress.clip_labels) |clip, clip_label| {
        const starts: []usize = try track.evenStarts(arena, clip, frames_per_second);
        const judge_settings: lab.PolicyJudgeSettings = .{
            .starts = starts,
            .task = geno.tracking_task,
            .bodies = geno.drecon_bodies,
        };
        // The servo alone on this clip, once: the baseline every judgement of it is read against.
        if (is_first_judgement) {
            const servo: track.Judgement =
                try lab.judgePolicy(gpa, arena, model, body_names, clip, null, judge_settings);
            try lab.JudgeLog.appendLine(gpa, &progress.judgements, 0, 0, clip_label, servo);
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
                settings.action_scale,
                probe,
                &progress.recoveries,
                0,
                0,
            );
        }
        var judgement: track.Judgement = undefined;
        if (policy) |file_policy| {
            judgement = try lab.judgePolicy(gpa, arena, model, body_names, clip, file_policy, judge_settings);
        } else {
            const fleet_options: track.Fleet.Options = .{
                .action_scale = settings.action_scale,
                .task = judge_settings.task,
                .body_names = body_names,
            };
            judgement = try track.judge(gpa, model, clip, fleet_options, starts, judged.learner_actor);
        }
        try lab.JudgeLog.appendLine(gpa, &progress.judgements, rounds, minutes, clip_label, judgement);
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
            settings.action_scale,
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
    }
    const judgements_path: []const u8 = try runFilePath(arena, folder, .judgements);
    try writeWhole(arena, io, judgements_path, progress.judgements.items);
    progress.judged_at_minutes = minutes;
    // The collapse alarm, over every judgement the run has: said once, when a clip first collapses.
    const judgements_in_a_row: u32 = 3;
    const collapsed: []const u8 = lab.JudgeLog.collapsedClip(
        progress.judgements.items,
        progress.clip_labels,
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
    var controller: z.robot_policy.Controller = try .init(arena, fleet.m, decider.subset, character_count, .{
        .beta = policy.filter_beta,
        .decimation = policy.decimation,
    });
    const decided_actions: []f32 = try arena.alloc(f32, character_count * action_count);
    decider.decide(&policy, &controller, fleet, character_count, decided_actions);
    var worst_difference: f32 = 0.0;
    var largest_action: f32 = 0.0;
    for (0..character_count) |character| {
        learner.features(character);
        learner.host.policyRow();
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
    }
    say(io, "geno_trainer: resumed from round {d}, {d} world and {d} policy updates", .{
        progress.rounds,
        learner.world_updates,
        learner.policy_updates,
    });
    return true;
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
    const physics_steps_per_second: f32 = 1.0 / learner.fleet.m.opt.timestep;
    const recent_seconds: ?f32 = progress.recent.secondsToFailure(physics_steps_per_second);
    const failure_text: []const u8 = if (recent_seconds) |seconds|
        bufPrint(&failure_buffer, "loses the reference every {d:.2} s", .{seconds}) catch "?"
    else
        "no losses in the recent rounds";
    // With several clips, each clip's own time beside it: "  (dance 0.74 s, get-up 1.59 s, ...)".
    var clips_buffer: [192]u8 = undefined;
    var clips_text: []const u8 = "";
    if (progress.clip_labels.len > 1) {
        var used: usize = 0;
        for (progress.clip_labels, progress.clip_recent[0..progress.clip_labels.len], 0..) |label, recent, clip| {
            var piece_buffer: [48]u8 = undefined;
            const seconds: ?f32 = recent.secondsToFailure(physics_steps_per_second);
            const piece: []const u8 = clipTimeText(&piece_buffer, label, seconds);
            const separator: []const u8 = if (clip == 0) "  (" else ", ";
            const written: []const u8 = bufPrint(clips_buffer[used..], "{s}{s}", .{ separator, piece }) catch "";
            used += written.len;
        }
        const closing: []const u8 = bufPrint(clips_buffer[used..], ")", .{}) catch "";
        used += closing.len;
        clips_text = clips_buffer[0..used];
    }
    say(io, "{s}  round {d}  {d:.1} min  {d} world / {d} policy updates  {s}{s}", .{
        basename(folder),
        progress.rounds,
        superTrackMinutes(progress),
        learner.world_updates,
        learner.policy_updates,
        failure_text,
        clips_text,
    });
}

/// Trains a SuperTrack run round after round until it must end (`superTrackEndState`), logging every round and
/// saving everything at its first round and every `save_minutes`; the state it ended in. Memory: each round's paths
/// and files in `arena_state`, reset every round; the log grows in `progress` with `gpa`.
fn trainSuperTrack(
    gpa: Allocator,
    io: Io,
    report_interval_ms: f64,
    arena_state: *ArenaAllocator,
    folder: []const u8,
    run: lab.GenoRun,
    settings: lab.SuperTrackLearner,
    learner: *SuperTrackLearner,
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
        // The pushes' schedule follows the run's training hours (`robot_track.Pushes.scheduleShare`).
        learner.fleet.training_hours = superTrackMinutes(progress) / 60.0;
        // And the rates' schedule, when it is in hours (`robot_track_resident.Options.rate_decay_hours`).
        learner.training_hours = learner.fleet.training_hours;
        const before: RoundTotals = .of(learner);
        const round_started_ms: f64 = wgpu.nowMs();
        learner.act(learner.options.collect, 1.0);
        const acting_ended_ms: f64 = wgpu.nowMs();
        learner.train();
        const training_ended_ms: f64 = wgpu.nowMs();
        const after: RoundTotals = .of(learner);
        progress.rounds += 1;
        const steps_watched: u64 = after.steps_watched - before.steps_watched;
        const pushes: u64 = after.pushes - before.pushes;
        const push_speed_sum: f64 = after.push_speed_sum - before.push_speed_sum;
        const planned_steps: u64 = after.planned_steps - before.planned_steps;
        const returns: u64 = after.returns - before.returns;
        const return_steps: u64 = after.return_steps_sum - before.return_steps_sum;
        const round_line: lab.SuperTrackLog.Line = .{
            .round = progress.rounds,
            .training_minutes = superTrackMinutes(progress),
            .steps_watched = steps_watched,
            .failures = after.failures - before.failures,
            .world_updates = learner.world_updates,
            .policy_updates = learner.policy_updates,
            .pushes = pushes,
            .push_mean_speed = @floatCast(push_speed_sum / float64(@max(pushes, 1))),
            .push_schedule = learner.fleet.pushScheduleShare(),
            .returns = returns,
            .return_mean_seconds = float(return_steps) * learner.fleet.m.opt.timestep / float(@max(returns, 1)),
            .flagged_share = flaggedShare(learner),
            .mean_hazard = meanHazard(learner),
            .planning_decisions = after.planning_decisions - before.planning_decisions,
            .planned_step_share = float(planned_steps) / float(@max(steps_watched, 1)),
            .teacher2_examples = learner.distillation_example_count,
            .teacher3_examples = learner.fpo_example_count,
            .critic_trust = learner.criticTrust(),
            .nonfinite_actions = after.nonfinite_actions - before.nonfinite_actions,
            .mirrors_refused = after.mirrors_refused - before.mirrors_refused,
            .windows_refused = after.windows_refused - before.windows_refused,
            .acting_ms = @floatCast(acting_ended_ms - round_started_ms),
            .training_ms = @floatCast(training_ended_ms - acting_ended_ms),
            .judging_ms = progress.pending_judging_ms,
            .device = learner.device_stats,
        };
        progress.pending_judging_ms = 0;
        try lab.SuperTrackLog.appendLine(gpa, &progress.log, round_line);
        progress.recent.add(round_line.steps_watched, round_line.failures);
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
        // The policy file's play check - none for a flow run, which writes no policy file.
        const has_policy_file: bool = settings.actor != .flow;
        if (progress.has_saved_this_start and !progress.has_checked_policy_this_start and has_policy_file) {
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
            saveSuperTrackCheckpoint(arena, io, folder, learner, settings, progress) catch |err| switch (err) {
                error.StateNotFinite => return .failed_nonfinite,
                else => return err,
            };
        }
        const judge_minutes: f32 = run.controls.judge_minutes;
        const minutes_since_judgement: f32 = minutes - progress.judged_at_minutes;
        const is_judgement_due: bool = judge_minutes > 0 and minutes_since_judgement >= judge_minutes;
        if (is_judgement_due) {
            const judging_started_ms: f64 = wgpu.nowMs();
            try judgeSuperTrackPolicy(gpa, arena, io, folder, learner, settings, progress, run.controls.probe);
            progress.pending_judging_ms = @floatCast(wgpu.nowMs() - judging_started_ms);
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
fn runSuperTrack(
    gpa: Allocator,
    io: Io,
    report_interval_ms: f64,
    arena_state: *ArenaAllocator,
    folder: []const u8,
    run: lab.GenoRun,
    settings: lab.SuperTrackLearner,
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
    var pipe: z.Compute(zn_mlp) = try .initGpu(gpa, device, queue, &kernelEntries());
    defer pipe.deinit();

    var body: GenoBody = undefined;
    try body.init(gpa);
    defer body.deinit();
    const model: *rbt.Model = &body.imported.model;
    // The run's clips: the dance, and with `dance_and_getup` the get-up beside it - half the characters on each, each
    // keeping its own (`track.ClipAssignment.by_character`), so the harder clip gets its half of the time.
    // The run's clips: the first of Geno's, as many as its motion names (`lab.GenoMotion.clipLabels`) - with several,
    // each character keeping its own (`track.ClipAssignment.by_character`), so a harder clip gets its share of the
    // time.
    const every_clip = [_]*const dance.Clip{ &body.clip, &body.getup_clip, &body.walk_clip, &body.run_clip };
    const clip_labels: []const []const u8 = run.task.motion.clipLabels();
    const clips: []const *const dance.Clip = every_clip[0..clip_labels.len];
    const has_several_clips: bool = clips.len > 1;
    const clip_assignment: track.ClipAssignment = if (has_several_clips) .by_character else .random;
    const character_count: usize = settings.characters;
    const fleet: *track.Fleet = try .init(gpa, model, clips, .{
        .envs = character_count,
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
        .physics_threads = physicsThreads(settings.physics_threads),
    });
    // The physics' tasks on the trainer's own threads: the same numbers, sooner.
    fleet.physics_io = io;
    defer fleet.deinit();

    // The clips' labels, as every judgement and probe line names them.
    var progress: SuperTrackProgress = .{ .clip_labels = clip_labels };
    const clips_fit: bool = clips.len <= SuperTrackProgress.most_clips;
    assertf(clips_fit, @src(), "{d} clips; the progress keeps {d}", .{ clips.len, SuperTrackProgress.most_clips });
    defer progress.log.deinit(gpa);
    defer progress.judgements.deinit(gpa);
    defer progress.recoveries.deinit(gpa);
    try progress.log.appendSlice(gpa, lab.SuperTrackLog.header);
    // The servo alone on the training fleet, counted as the learner counts itself: a step watched per character and
    // a failure for each that lost the reference. It also puts real steps in the replay before the learner exists.
    const zero_actions: []f32 = try gpa.alloc(f32, character_count * track.actionSize(model));
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
    const physics_steps_per_second: f32 = 1.0 / model.opt.timestep;
    const servo_steps_watched: u64 = character_count * servo_steps;
    progress.servo_seconds_to_failure = ppo_track.secondsToFailure(
        servo_steps_watched,
        servo_failures,
        physics_steps_per_second,
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
    // How much of each kernel buffer the learner fills: a run near a limit is seen at its start, before it grows.
    const used: @FieldType(SuperTrackLearner, "buffers_used") = learner.buffers_used;
    const acts_share: f32 = float(used.acts_floats) / float(zn_mlp.acts_len);
    const dacts_share: f32 = float(used.dacts_floats) / float(zn_mlp.dacts_len);
    const params_share: f32 = float(used.params_floats) / float(zn_mlp.config.max);
    say(io, "geno_trainer: buffers used - activations {d:.0}%, their gradients {d:.0}%, parameters {d:.0}%", .{
        100 * acts_share,
        100 * dacts_share,
        100 * params_share,
    });
    say(io, "geno_trainer: SuperTrack on the {s} in {s}, {d} characters", .{
        run.task.motion.label(),
        folder,
        character_count,
    });
    progress.started_at_ms = wgpu.nowMs();
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
    return .finished;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa: Allocator = init.gpa;
    const io: Io = init.io;
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();

    const arguments: TrainerArgs = cli.args(&init, TrainerArgs, trainer_cli);
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
    const report_interval_ms: f64 = 1000.0 * arguments.@"--report-seconds";
    // The learner the run chose, each on its own path; EfficientTDMPC joins the trainer later.
    const trained: anyerror!Exit = switch (run.learner) {
        .ppo => runTraining(gpa, io, report_interval_ms, &arena_state, folder, run.toPpoRun().?),
        .supertrack => |settings| runSuperTrack(gpa, io, report_interval_ms, &arena_state, folder, run, settings),
        .efficient_tdmpc => {
            say(io, "geno_trainer: refused: run.zon: learner.efficient_tdmpc is not in the trainer yet", .{});
            return Exit.refused.code();
        },
    };
    const exit: Exit = trained catch |err| failed: {
        say(io, "geno_trainer: failed: {s}", .{@errorName(err)});
        break :failed .failed;
    };
    return exit.code();
}
