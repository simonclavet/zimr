//! geno_trainer - DReCon trained by PPO on Geno, headless, in a run folder: the training a night runs.
//!
//! A run is a folder. The trainer reads the run's parameters from its `run.zon` (`robot_geno.PpoRun`: the motion, PPO's
//! recipe on Geno, the run's own controls), trains as fast as the GPU and the CPU allow - no window, no frames - and
//! writes what it learns into the same folder, so that another program can watch the run while it goes:
//!
//!     run.zon          the parameters; written with the defaults when the folder has none
//!     weights          the newest weights (`ppo_track.Trainer.exportWeights`), rewritten whole every few minutes
//!     weights_b<N>     a checkpoint: the weights after batch N, kept every so many minutes
//!     log.csv          one line per batch, raw counts (steps watched, failures, reward, episodes, assist)
//!     status.zon       where the run is: its state, batches, minutes, the servo's and the recent time to failure
//!     stop             created by anyone: the trainer saves everything and exits
//!
//! Every file is written whole to `<name>.new` and renamed over the old one, so a reader never sees half a file and
//! a run stopped in the middle of a write keeps the previous version. Started again on the same folder, the trainer
//! carries on from the folder's weights and log; weights that do not fit the run's network (another width, another
//! motion) are refused, and the folder is left untouched. The run ends when its `stop` file appears, or after the
//! hours or batches `run.zon` allows; then the last weights, the log and the status are written, and the program
//! exits 0. It exits 1 when it refuses the run - an unreadable `run.zon`, a value out of its range
//! (`robot_geno.PpoRun.problem`), weights that do not fit - and 2 when the run fails: the GPU or the robot cannot be
//! set up, or a file cannot be written.
//!
//!     geno_trainer --run=runs/night1

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Io = std.Io;
const bufPrint = std.fmt.bufPrint;
const allocPrint = std.fmt.allocPrint;
const ArrayList = std.ArrayList;
const parseFloat = std.fmt.parseFloat;
const splitScalar = std.mem.splitScalar;
const basename = std.fs.path.basename;
const z = @import("zimr");
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
const native_os = z.native_os;
const readWhole = native_os.readWhole;
const writeWhole = native_os.writeWhole;
const fileExists = native_os.fileExists;
const Trainer = ppo_track.Trainer(zn_mlp);

/// The network kernels' SPIR-V: one module holding every entry of `zn_mlp`.
const zn_mlp_spirv: []const u8 = @embedFile("zn_mlp_spv");
/// The dance, retargeted to Geno and baked (`zig build clip-bake`), as the training page embeds it.
const dance_zclip: []const u8 = @embedFile("geno_dance_zclip");

/// How the trainer ends, as its exit code tells whoever started it: `robot_geno`'s, so the training lab reads the
/// code by the same definition.
const Exit = geno.TrainerExit;

// ---- The run folder ----
//
// The folder's files, their names and the log's columns are `robot_geno`'s (`RunFile`, `RunLog`): the training lab
// reads what this program writes, by the same definitions.

const RunFile = geno.RunFile;
const RunLog = geno.RunLog;

const RunState = geno.RunState;
const RunStatus = geno.RunStatus;

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

/// The run's parameters from the folder's `run.zon` - written there with every default when the folder has none,
/// so that every run folder states what it trains. Null, after saying why, when the file cannot be read as a run.
fn readRunParameters(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
) !?geno.PpoRun {
    const run_path: []const u8 = try runFilePath(arena, folder, .parameters);
    const source: []u8 = try readWhole(gpa, io, run_path, RunFile.most_bytes) orelse {
        const defaults: geno.PpoRun = .{};
        var text: Io.Writer.Allocating = .init(arena);
        try defaults.write(&text.writer);
        try text.writer.writeAll("\n");
        try writeWhole(arena, io, run_path, text.written());
        const run_file_name: []const u8 = RunFile.parameters.fileName();
        say(io, "geno_trainer: no {s} in {s} - wrote one with every default", .{ run_file_name, folder });
        return defaults;
    };
    defer gpa.free(source);
    const terminated_source: [:0]const u8 = try arena.dupeSentinel(u8, source, 0);
    var failure: geno.PpoRun.ParseFailure = .{ .description = "" };
    return geno.PpoRun.parse(gpa, arena, terminated_source, &failure) catch |err| switch (err) {
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
    saved_at_minutes: f32 = 0,
    checkpointed_at_minutes: f32 = 0,
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

/// The newest weights, the log and the status, each written whole.
fn saveAll(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    progress: *RunProgress,
    state: RunState,
) !void {
    // The parameters read back, and the counters beside them, of the same update.
    trainer.waitForReadback();
    const weights_bytes: []u8 = try trainer.exportWeights(gpa);
    defer gpa.free(weights_bytes);
    const weights_path: []const u8 = try runFilePath(arena, folder, .weights);
    try writeWhole(arena, io, weights_path, weights_bytes);
    const log_path: []const u8 = try runFilePath(arena, folder, .log);
    try writeWhole(arena, io, log_path, progress.log.items);
    try saveStatus(arena, io, folder, trainer, progress, state);
    progress.has_saved_this_start = true;
    progress.saved_at_minutes = trainingMinutes(progress);
}

/// The weights kept as a checkpoint under the batch that trained them, `weights_b<N>`.
fn saveCheckpoint(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    progress: *RunProgress,
) !void {
    trainer.waitForReadback();
    const weights_bytes: []u8 = try trainer.exportWeights(gpa);
    defer gpa.free(weights_bytes);
    const name: []const u8 = try allocPrint(arena, "weights_b{d:0>7}", .{trainer.iterations});
    const checkpoint_path: []const u8 = try pathIn(arena, folder, name);
    try writeWhole(arena, io, checkpoint_path, weights_bytes);
    progress.checkpointed_at_minutes = trainingMinutes(progress);
}

/// Whether the run must end now, and how: its folder's `stop` file, or its limits.
fn endState(
    arena: Allocator,
    io: Io,
    folder: []const u8,
    parameters: geno.PpoRun,
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

/// The training minutes on the log's last line, or zero for a log with no batches.
fn lastLoggedMinutes(log_text: []const u8) f32 {
    const trimmed: []const u8 = std.mem.trimEnd(u8, log_text, "\n");
    const last_newline: ?usize = std.mem.lastIndexOfScalar(u8, trimmed, '\n');
    const last_line_start: usize = if (last_newline) |newline| newline + 1 else 0;
    const last_line: []const u8 = trimmed[last_line_start..];
    var columns: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, last_line, ',');
    _ = columns.next();
    const minutes_text: []const u8 = columns.next() orelse return 0;
    return parseFloat(f32, minutes_text) catch 0;
}

/// Carries the run on from the folder's weights and log, when it has them. False, after saying why, when the weights
/// do not fit this run's network - the run is then refused, and nothing in the folder is overwritten.
fn resumeFromFolder(
    gpa: Allocator,
    arena: Allocator,
    io: Io,
    folder: []const u8,
    trainer: *Trainer,
    progress: *RunProgress,
) !bool {
    const weights_path: []const u8 = try runFilePath(arena, folder, .weights);
    const weights_bytes: []u8 = try readWhole(gpa, io, weights_path, RunFile.most_bytes) orelse return true;
    defer gpa.free(weights_bytes);
    trainer.importWeights(weights_bytes) catch |err| {
        say(io, "geno_trainer: refused: the folder's weights do not fit this run ({s})", .{@errorName(err)});
        return false;
    };
    const log_path: []const u8 = try runFilePath(arena, folder, .log);
    if (try readWhole(gpa, io, log_path, RunFile.most_bytes)) |saved_log| {
        defer gpa.free(saved_log);
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
    parameters: geno.PpoRun,
    trainer: *Trainer,
    progress: *RunProgress,
) !RunState {
    const decisions_per_collect: u32 = 64;
    const save_minutes: f32 = parameters.save_minutes;
    const checkpoint_minutes: f32 = parameters.checkpoint_minutes;
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
            try saveAll(gpa, arena, io, folder, trainer, progress, .training);
        }
        const minutes_since_checkpoint: f32 = minutes - progress.checkpointed_at_minutes;
        const is_checkpoint_due: bool = checkpoint_minutes > 0 and minutes_since_checkpoint >= checkpoint_minutes;
        if (is_checkpoint_due) {
            try saveCheckpoint(gpa, arena, io, folder, trainer, progress);
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
    .description = "Trains DReCon on Geno with PPO, headless, in a run folder: reads its run.zon, writes its " ++
        "weights, log.csv and status.zon as it goes, carries on from them when started again, and ends when the " ++
        "folder's stop file appears or the run's limits are reached.",
    .args = .{
        .@"--run" = .{ .description = "the run folder (made if missing)" },
        .@"--report-seconds" = .{ .description = "seconds between progress lines, at most" },
    },
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
    parameters: geno.PpoRun,
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
    var document: codecs.xml.Document = try codecs.xml.parse(gpa, z.robot_geno_model, null);
    defer document.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &document);
    defer robot.deinit();
    for (robot.joints) |*joint| {
        if (joint.kind == .ball) {
            joint.armature = geno.standing_armature;
        }
    }
    const physics_options: rbt.Options = geno.physicsOptions();
    var imported: rmj.Imported = try rmj.build(gpa, &robot, physics_options);
    defer imported.deinit();
    var clip: dance.Clip = try .fromBytes(gpa, dance_zclip);
    defer clip.deinit();
    const clips = [_]*const dance.Clip{&clip};
    const trainer_options: ppo_track.Options = parameters.recipe.options(parameters.motion);
    const trainer: *Trainer = try .init(gpa, &pipe, &imported.model, imported.names, &clips, trainer_options);
    defer trainer.deinit();

    var progress: RunProgress = .{};
    defer progress.log.deinit(gpa);
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
    try saveAll(gpa, final_arena, io, folder, trainer, &progress, end_state);
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
    const parameters: geno.PpoRun = try readRunParameters(gpa, arena, io, folder) orelse return Exit.refused.code();
    if (parameters.problem()) |why| {
        say(io, "geno_trainer: refused: run.zon: {s}", .{why});
        return Exit.refused.code();
    }
    const report_interval_ms: f64 = 1000.0 * arguments.@"--report-seconds";
    const exit: Exit = runTraining(gpa, io, report_interval_ms, &arena_state, folder, parameters) catch |err| failed: {
        say(io, "geno_trainer: failed: {s}", .{@errorName(err)});
        break :failed .failed;
    };
    return exit.code();
}
