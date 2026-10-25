//! robot_lab - the training lab's shared ground: what the trainer, the lab and the pages agree on about a training
//! run of Geno on the dance. In order, each part followed by its tests: the learners' recipes (`SuperTrackRecipe` and
//! its plan's values, `supertrack_recipe`; `PpoRecipe`, and `PpoRun`, a PPO run's older parameters); a run's
//! parameters (`GenoRun` - the task every learner shares, the learner with its recipe, the run's controls - which
//! reads an older `PpoRun` as a PPO run); the run folder's files (their names, `RunFile`; how its trainer ended,
//! `TrainerExit`; its state as a person or the lab reads it, `RunState`, `RunStatus`; its log and its curves,
//! `RunLog`, `RunCurve`); and the policy a run deploys, whichever learner made it, with its file (`GenoPolicy`,
//! `policyMeanAction`, `PolicyFile`). Geno's body - its model, its bodies, its scales - is `robot_geno`'s; this file
//! builds on it, and nothing in it imports this file.

const std = @import("std");
const zm = @import("zm");
const isFinite = zm.isFinite;
const tanh = zm.tanh;
const clamp = zm.clamp;
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const builtin = @import("builtin");
const zrl = @import("zrl");
const asBytes = std.mem.asBytes;
const sliceAsBytes = std.mem.sliceAsBytes;
const bytesToValue = std.mem.bytesToValue;
const fromInt = std.enums.fromInt;
const panicf = zm.panicf;
const mulChecked = zm.mulChecked;
const maxInt = zm.maxInt;
const addChecked = zm.addChecked;
const dance = @import("robot_dance.zig");
const latent = @import("robot_latent.zig");
const robot_policy = @import("robot_policy.zig");
const robot_track = @import("robot_track.zig");
const ppo_track = @import("robot_ppo_track.zig");
const rbt = @import("robot.zig");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const ArrayList = std.ArrayList;
const Io = std.Io;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const indexOf = std.mem.indexOf;
const ArenaAllocator = std.heap.ArenaAllocator;
const allocPrint = std.fmt.allocPrint;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualDeep = std.testing.expectEqualDeep;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const parseFloat = std.fmt.parseFloat;
const parseInt = std.fmt.parseInt;
const float = zm.float;
const nan = zm.nan;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const writeInt = std.mem.writeInt;
const geno = @import("robot_geno.zig");
const resident = @import("robot_track_resident.zig");
const GenoTask = geno.GenoTask;
const student_scale = geno.student_scale;
const supertrack_action_scale = geno.supertrack_action_scale;
const tracking_task = geno.tracking_task;
const drecon_bodies = geno.drecon_bodies;

/// SuperTrack's RECIPE on Geno (plan A2): every setting the bench, the pages and the night train with that is not
/// the TASK (that's `tracking_task`) and not a run's sizes. One value, handed over whole and never rebuilt field by
/// field at a call site - which is exactly how the task's settings drifted apart before T1 made them one value. An
/// A/B copies it and changes ONE field; the copy's name then says what the experiment is.
///
/// Why a struct and not a bare `LearnerOptions`: the action scale belongs to the FLEET (it turns a unit of action
/// into a joint offset before the learner ever sees it), so no learner option can hold it. And a recipe without it
/// is a trap: a bench that builds its fleet from the recipe's learner half gets the fleet's default 0.2 rad, and
/// trains a quietly different policy with every other setting right.
pub const SuperTrackRecipe = struct {
    /// Radians of joint offset per unit of action - the fleet's `action_scale`.
    action_scale: f32,
    /// The shortest episode training allows, in physics steps: the task's rule is not applied before it
    /// (`Termination.grace_steps`). The paper's 48 frames (0.8 s at 60 Hz), and never less than the policy's window,
    /// so every episode - however bad the policy - still yields a window to train on. A LEARNER's aid only: the
    /// judge never has it (`robot_track.judgeOptions` zeroes it).
    training_grace_steps: u32,
    /// Everything the learner is told. Its SIZES (widths, window, batch) stay at `LearnerOptions`' defaults in the
    /// recipe: the bench picks them for the CPU and the night's start-up probe for the desktop GPU.
    learner: latent.LearnerOptions,

    /// The task the recipe TRAINS on: Geno's own (`tracking_task`), changed only by the training grace - long
    /// enough for the paper's minimum episode and for one of this recipe's windows, whichever is longer.
    pub fn trainingTask(self: SuperTrackRecipe) robot_track.Task {
        var task: robot_track.Task = tracking_task;
        const window: u32 = @intCast(self.learner.window);
        task.termination.grace_steps = @max(self.training_grace_steps, window);
        return task;
    }
};

/// The recipe today. Each field is a decision the plan recorded (`src/notes/rl_track_plan.md`), and the tests right
/// below hold each one against its REASON rather than against its number:
///   * 0.6 rad a unit (`supertrack_action_scale`) - C1 weighs it against the paper's 2.09;
///   * exploration noise of 0.1 of a unit - C1 again (the paper's sigma, in its units);
///   * a decision every 2 physics steps: 30 Hz over Geno's 60 Hz physics (Simon; F4e) - DReCon's clock;
///   * Simon's filter at 0.2, inside training too (F6a) - DReCon's filter;
///   * the policy sees what it is applying (A1) - with a filter, the filter's state is half of the control state;
///   * the world model's normaliser from the reference clips (F4a) - the paper's way, fixed before the first step;
///   * a training grace of 48 steps - the paper's minimum episode (F3b), a window when that is longer.
pub const supertrack_recipe: SuperTrackRecipe = .{
    .action_scale = supertrack_action_scale,
    .training_grace_steps = 48,
    .learner = .{
        .sigma = 0.1,
        .decide_every = 2,
        .filter = 0.2,
        .sees_applied = true,
        .world = .{ .normalize_from_clips = true },
    },
};

test "robot_lab: A2 - the SuperTrack recipe holds the plan's decisions, each against its reason" {
    // Plan A2's first known answer. Not the numbers restated - the REASONS, checked against things the recipe did
    // not write:
    //   * the clock and the filter are DReCon's (P5: Simon's filter and clock wherever a policy acts), so they must
    //     agree with `robot_policy.Controller`'s own defaults;
    //   * seeing the applied action is what makes a filter's state visible (A1), so a filtered recipe must see it;
    //   * the scale is the one `geno_train` trains with (the page reads `supertrack_action_scale` until Stage G moves
    //     it onto the recipe), so the two cannot part company unnoticed;
    //   * and NOTHING ELSE is overridden: every other field is `LearnerOptions`' default, so a stray size, rate or
    //     price cannot hide inside the one value. The expected value below is the plan's list, written out again.
    const recipe: SuperTrackRecipe = supertrack_recipe;
    const drecon: robot_policy.Controller.Options = .{};
    try expect(recipe.learner.filter == drecon.beta);
    try expect(recipe.learner.decide_every == drecon.decimation);
    const filtered: bool = recipe.learner.filter < 1.0;
    try expect(!filtered or recipe.learner.sees_applied);
    try expect(recipe.action_scale == supertrack_action_scale);
    var expected: latent.LearnerOptions = .{};
    expected.sigma = 0.1;
    expected.decide_every = 2;
    expected.filter = 0.2;
    expected.sees_applied = true;
    expected.world.normalize_from_clips = true;
    try expect(std.meta.eql(recipe.learner, expected));
    // The task it trains on is Geno's own, changed ONLY by the grace - and the grace never shorter than a window.
    var trained: robot_track.Task = recipe.trainingTask();
    try expect(trained.termination.grace_steps >= recipe.learner.window);
    try expect(trained.termination.grace_steps >= recipe.training_grace_steps);
    trained.termination.grace_steps = tracking_task.termination.grace_steps;
    try expect(std.meta.eql(trained, tracking_task));
}

test "robot_lab: A2 - a learner built from the recipe IS the recipe, on Geno's own model" {
    // Plan A2's second known answer: the decisions read back where they act, not where they are written (a knob is
    // only worth something if it reaches). Geno on the 10-second dance, a fleet at the recipe's scale, and a learner
    // from the recipe with ONLY its sizes shrunk - the very override a bench makes. Then: 30 decisions a second on
    // the model's OWN timestep, the block that reads the applied action exists, and the world model's normaliser is
    // the reference clip's, bit for bit (the replay is empty here, so a replay-measured one could not match it).
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const task: *GenoTask = (try GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clips = [_]*const dance.Clip{&task.clip};
    const fleet: *robot_track.Fleet = try .init(gpa, m, &clips, .{
        .envs = 2,
        .capacity = 64,
        .action_scale = supertrack_recipe.action_scale,
        .task = tracking_task,
        .body_names = task.imported.names,
    });
    defer fleet.deinit();
    var options: latent.LearnerOptions = supertrack_recipe.learner;
    options.hidden = 16;
    options.window = 4;
    options.batch = 2;
    options.world.hidden = 16;
    options.world.steps = 4;
    options.world.batch = 2;
    const learner: *latent.Learner = try .init(gpa, fleet, options);
    defer learner.deinit();

    // Geno's physics at 60 Hz and a decision every second step: 30 decisions a second.
    const decisions_per_second: f32 = 1.0 / (m.opt.timestep * float(learner.options.decide_every));
    try expect(@abs(decisions_per_second - 30.0) < 1.0e-3);
    try expect(learner.applied_block != null);
    const from_clip: latent.Normalizer = try latent.measureClipNormalizer(gpa, m, &clips);
    defer gpa.free(from_clip.mean);
    defer gpa.free(from_clip.spread);
    try expect(eql(f32, learner.world.norm.mean, from_clip.mean));
    try expect(eql(f32, learner.world.norm.spread, from_clip.spread));
}

// ==== ONE DEFINITION OF GENO'S TASK (plan T1) ====
//
// Geno's task - its servo, its floor, resets rested on that floor, the gated reward (gravity in the reward: lying
// with the right joint angles must not score) and the task's own failure rule - is ONE typed value, handed
// whole to every fleet and trainer that trains or judges Geno (`.task = geno.tracking_task`). Spelled out field
// by field at each call site, it drifted: D5 step 3's trainer and the end-to-end PPO test never got the gravity
// gate, the T-pose test never got the floor rest.
//
// Not part of it (see `robot_track.Task`): the action scale, which is each learner's (`student_scale`,
// `supertrack_action_scale`), and a run's sizes, episode cap and seed.

/// The motions a PPO run on Geno can train: both on the baked dance clip, getting up from the floor first or not.
pub const PpoMotion = enum {
    getup,
    dance,

    /// The motion's name in files and on screen.
    pub fn label(motion: PpoMotion) []const u8 {
        return switch (motion) {
            .getup => "get-up",
            .dance => "dance",
        };
    }

    /// What the motion's networks are trained for, carried in their weights file (`ppo_track.Options.tag`): a file
    /// for another motion is refused. Both motions share the dance clip, and so one tag.
    pub fn tag(motion: PpoMotion) u32 {
        return switch (motion) {
            .getup, .dance => 3,
        };
    }
};

/// PPO's recipe on Geno: every scalar of the trainer's options (`ppo_track.Options`), each defaulted to the value the
/// training page trains with. `options` joins it to Geno's task and bodies.
///
/// PPO learns in BATCHES. Every character acts for `horizon` decisions with the current policy, sampling its actions
/// around the policy's mean; the batch - `envs` x `horizon` decisions, each with its observation, action, reward and
/// how its episode went on - is turned into ADVANTAGES (how much better each action did than the critic expected,
/// `gamma` and `lambda`), and the policy is updated on it for `epochs` passes of `minibatch` rows. Then the batch is
/// thrown away and the next one collected with the updated policy: PPO learns only from what its current policy did.
pub const PpoRecipe = struct {
    /// Characters acting side by side, each its own episodes - vectorised environments. More characters give each
    /// batch more varied experience (different moments of the clip, different stumbles) and so steadier updates,
    /// for more simulation per batch. Eight keep a batch's decisions inside a phone's frames; a desktop takes many
    /// more.
    envs: u32 = 8,
    /// Decisions each character makes per batch: the rollout's length. With `envs` it sets the batch's size
    /// (8 x 64 = 512 decisions). A longer rollout lets an advantage see further before it must lean on the critic at
    /// the rollout's end, and leaves the data a little staler by the time it is learned from.
    horizon: u32 = 64,
    /// Passes over each batch, and the rows each gradient step of a pass takes. PPO reuses a batch for several
    /// passes - more learning from the same simulation - and its clipped objective keeps every pass's policy close to
    /// the one that collected the data, which is what makes reuse safe.
    epochs: u32 = 4,
    minibatch: u32 = 256,
    /// The DISCOUNT: a reward k decisions ahead counts gamma^k as much as one now. Credit reaches about
    /// 1 / (1 - gamma) decisions ahead: 100 decisions, 3.3 seconds at 30 decisions a second - long enough for a
    /// stumble's cost to reach the decision that caused it.
    gamma: f32 = 0.99,
    /// GAE's lambda (Generalised Advantage Estimation): how an advantage blends the critic's one-step estimate - the
    /// reward now plus the critic's value of the next state, steady but as wrong as the critic (lambda 0) - with the
    /// whole discounted return that followed, right on average but noisy (lambda 1). 0.95 leans toward the return
    /// while cutting most of its noise: the value nearly every PPO uses.
    lambda: f32 = 0.95,
    /// What the clip running out counts as (`ppo_track.ClipEnd`): the end of the story, with nothing after it to
    /// value, or the end of the tape while the character was doing fine, valued as if it went on.
    clip_end: ppo_track.ClipEnd = .terminal,
    /// The width of both networks' two hidden layers - the actor's and the critic's. One clip is a small function;
    /// small networks learn it faster at first (DReCon's figure 8).
    hidden: u32 = 48,
    /// Adam's step size, for both networks.
    learning_rate: f32 = 3.0e-4,
    /// Exploration at the start: log sigma -1.2, a Gaussian of 0.3 action units - 0.36 rad of raw offset at
    /// `student_scale`, 4 degrees at the joint once DReCon's filter has taken its fifth.
    initial_log_std: f32 = -1.2,
    /// Inputs normalised by their running mean and spread (`zrl.ObsNormalizer`, Welford's statistics):
    /// every input a Z-score of the same size, whatever its unit.
    normalize: bool = true,
    /// A CURRICULUM: a helping hand that holds the character's root up, this strong at the first batch and fading to
    /// nothing over `assist_batches`. Early on an untrained policy falls at once and learns little from it; held up,
    /// it lives long enough to learn what tracking is, and the hand fades before it can learn to lean on it.
    assist_start: f32 = 1.0,
    assist_batches: u32 = 300,
    /// Episodes end here even while tracking is fine, in physics steps: longer than the dance's twenty seconds.
    max_episode_steps: u32 = 1300,
    /// Radians of raw pose offset per unit of action (`student_scale`, where the reasoning lives).
    action_scale: f32 = student_scale,
    /// Physics steps a decision is held (30 Hz decisions over 60 Hz physics), and DReCon's filter: the share of
    /// a new action a joint receives each decision.
    decimation: u32 = 2,
    beta: f32 = 0.2,
    seed: u64 = 1,

    /// The trainer's options for `motion`: Geno's task and DReCon bodies, the motion's tag, and every field of this
    /// recipe - each the trainer's option of the same name, copied by one loop, so that a field added to the recipe
    /// reaches the trainer or fails to compile, and is never left behind.
    pub fn options(recipe: PpoRecipe, motion: PpoMotion) ppo_track.Options {
        var trainer_options: ppo_track.Options = .{
            .task = tracking_task,
            .bodies = drecon_bodies,
            .tag = motion.tag(),
        };
        inline for (@typeInfo(PpoRecipe).@"struct".field_names) |field_name| {
            @field(trainer_options, field_name) = @field(recipe, field_name);
        }
        return trainer_options;
    }
};

/// What makes PPO's settings impossible to train, naming the field - `prefix` is where the run file keeps them:
/// `recipe.` in a `PpoRun`, `learner.ppo.` in a `GenoRun` - and the range it must be in; null when they can be
/// trained. ZON checks each value's kind; this checks what the trainer needs of it: at least one character, one
/// decision and one pass per batch, a minibatch no larger than the batch (envs x horizon rows), a network, a discount
/// in its range, a positive and finite step size and action scale. The decision's length and the filter are the
/// task's (`taskProblem`).
fn ppoProblem(comptime prefix: []const u8, recipe: PpoRecipe) ?[]const u8 {
    if (recipe.envs == 0) {
        return prefix ++ "envs: at least 1 character";
    }
    if (recipe.horizon == 0) {
        return prefix ++ "horizon: at least 1 decision per batch";
    }
    if (recipe.epochs == 0) {
        return prefix ++ "epochs: at least 1 pass over each batch";
    }
    if (recipe.hidden == 0) {
        return prefix ++ "hidden: at least 1 unit";
    }
    const batch_rows: u64 = @as(u64, recipe.envs) * recipe.horizon;
    const is_minibatch_in_batch: bool = recipe.minibatch >= 1 and recipe.minibatch <= batch_rows;
    if (!is_minibatch_in_batch) {
        return prefix ++ "minibatch: from 1 to envs x horizon";
    }
    const is_gamma_in_range: bool = recipe.gamma > 0 and recipe.gamma <= 1;
    if (!is_gamma_in_range) {
        return prefix ++ "gamma: above 0, at most 1";
    }
    const is_lambda_in_range: bool = recipe.lambda >= 0 and recipe.lambda <= 1;
    if (!is_lambda_in_range) {
        return prefix ++ "lambda: from 0 to 1";
    }
    const is_learning_rate_usable: bool = recipe.learning_rate > 0 and isFinite(recipe.learning_rate);
    if (!is_learning_rate_usable) {
        return prefix ++ "learning_rate: above 0";
    }
    if (!isFinite(recipe.initial_log_std)) {
        return prefix ++ "initial_log_std: a finite number";
    }
    const is_assist_usable: bool = recipe.assist_start >= 0 and isFinite(recipe.assist_start);
    if (!is_assist_usable) {
        return prefix ++ "assist_start: 0 or more";
    }
    if (recipe.max_episode_steps == 0) {
        return prefix ++ "max_episode_steps: at least 1";
    }
    const is_action_scale_usable: bool = recipe.action_scale > 0 and isFinite(recipe.action_scale);
    if (!is_action_scale_usable) {
        return prefix ++ "action_scale: above 0";
    }
    return null;
}

/// What makes a learner's decision and filter impossible, named under `prefix` (`recipe.` in a `PpoRun`, the learner's
/// path in a `GenoRun`): at least one physics step per decision, and a filter that takes some, and at most all, of
/// each new action.
fn decisionProblem(comptime prefix: []const u8, decimation: u32, beta: f32) ?[]const u8 {
    if (decimation == 0) {
        return prefix ++ "decimation: at least 1 physics step per decision";
    }
    const is_beta_in_range: bool = beta > 0 and beta <= 1;
    if (!is_beta_in_range) {
        return prefix ++ "beta: above 0, at most 1";
    }
    return null;
}

/// What makes a run's controls impossible, named under `prefix` (none in a `PpoRun`, `controls.` in a `GenoRun`): a
/// save interval above zero, and checkpoints, judgements and an hour limit of zero (none) or more.
fn controlsProblem(
    comptime prefix: []const u8,
    save_minutes: f32,
    checkpoint_minutes: f32,
    judge_minutes: f32,
    stop_after_hours: f32,
) ?[]const u8 {
    const is_save_interval_usable: bool = save_minutes > 0 and isFinite(save_minutes);
    if (!is_save_interval_usable) {
        return prefix ++ "save_minutes: above 0";
    }
    const is_checkpoint_interval_usable: bool = checkpoint_minutes >= 0 and isFinite(checkpoint_minutes);
    if (!is_checkpoint_interval_usable) {
        return prefix ++ "checkpoint_minutes: 0 or more";
    }
    const is_judge_interval_usable: bool = judge_minutes >= 0 and isFinite(judge_minutes);
    if (!is_judge_interval_usable) {
        return prefix ++ "judge_minutes: 0 or more";
    }
    const is_hour_limit_usable: bool = stop_after_hours >= 0 and isFinite(stop_after_hours);
    if (!is_hour_limit_usable) {
        return prefix ++ "stop_after_hours: 0 or more";
    }
    return null;
}

/// A training run's parameters, as its run folder's `run.zon` writes them: the motion, the recipe, and the run's own
/// controls. Every field defaulted, so an empty `.{}` is the page's training of the dance, run until stopped.
pub const PpoRun = struct {
    motion: PpoMotion = .dance,
    recipe: PpoRecipe = .{},
    /// Minutes of training between rewrites of the folder's newest weights.
    save_minutes: f32 = 2,
    /// Minutes of training between checkpoints - weights kept under their batch number. Zero keeps none.
    checkpoint_minutes: f32 = 30,
    /// The run stops by itself after this many hours of training, or this many batches; zero is never.
    stop_after_hours: f32 = 0,
    stop_after_batches: u64 = 0,
    /// Minutes of training between judgements of the newest policy (`JudgeLog`); zero judges none.
    judge_minutes: f32 = 5,

    /// What `parse` reports for a file it cannot read: the parser's own description, kept in `arena`.
    pub const ParseFailure = struct {
        description: []const u8,
    };

    /// A run from `run.zon`'s text: the fields it names, every other field its default. A field the run does not
    /// have, a value of the wrong kind, or text that is not ZON fails, with the parser's description of where and
    /// why (`failure`, in `arena`). Memory: two allocators, as the ZON parser takes them - `gpa` its working memory,
    /// freed before it returns; `arena` the description of a failure, which lives as long as the caller's arena. The
    /// run returned is plain values, pointing into neither.
    pub fn parse(
        gpa: Allocator,
        arena: Allocator,
        source: [:0]const u8,
        failure: *ParseFailure,
    ) error{ OutOfMemory, ParseZon }!PpoRun {
        // Filled by the parser when it fails.
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        return std.zon.parse.fromSlice(PpoRun, .{
            .gpa = gpa,
            .arena = arena,
            .source = source,
            .diagnostics = &diagnostics,
        }) catch |err| {
            if (err == error.ParseZon) {
                const described: std.zon.parse.Diagnostics.Formatter = diagnostics.fmt("run.zon");
                failure.description = allocPrint(arena, "{f}", .{described}) catch "unreadable";
            }
            return err;
        };
    }

    /// What makes this run impossible to train, naming the field and the range it must be in - or null when it can
    /// be trained. ZON checks each value's kind; this checks what the trainer needs of it: at least one character,
    /// one decision and one pass per batch, a minibatch no larger than the batch (envs x horizon rows), a network,
    /// a discount and filter in their ranges, a positive and finite step size and action scale.
    pub fn problem(run: PpoRun) ?[]const u8 {
        const recipe: PpoRecipe = run.recipe;
        return ppoProblem("recipe.", recipe) orelse
            decisionProblem("recipe.", recipe.decimation, recipe.beta) orelse
            controlsProblem("", run.save_minutes, run.checkpoint_minutes, run.judge_minutes, run.stop_after_hours);
    }

    /// The run as ZON text, every field written: what a run folder's `run.zon` reads back as this run.
    pub fn write(run: PpoRun, writer: *Io.Writer) Io.Writer.Error!void {
        try std.zon.stringify.serialize(run, .{}, writer);
    }
};

// ---- A run's parameters ----
//
// A run file (`run.zon`) says three things: the TASK, the LEARNER with its recipe, and the run's CONTROLS.
//
//   * The task is what every learner shares: the motion, and - Geno's own, not in the file - the failure rule, the
//     physics and the servo. It is held apart from the learners because a comparison between two runs means
//     something only when both learned the same task; how often a learner decides, how it smooths its actions and
//     how far an action reaches are the learner's own, a controller's design, and the judge compares controllers on
//     the task they share.
//   * The learner is one of three, with its recipe: PPO (`PpoLearner`), SuperTrack (`SuperTrackLearner`) or
//     EfficientTDMPC (`TdmpcLearner`). Each keeps the settings its own experiments chose.
//   * The controls are the run's own: when it saves, keeps checkpoints and judges itself, and when it stops.
//
// Every field has a default, so a file names only what it changes - `.{}` is PPO on the dance with every default,
// and `.{ .learner = .{ .efficient_tdmpc = .{ .acting_horizon = 4 } } }` is EfficientTDMPC with one setting changed.
// A file written before this format, a `PpoRun`, reads as the same run with PPO as its learner, so that no older run
// folder is stranded.

/// What every learner's run on Geno shares (`GenoRun`), as its `run.zon` writes it: the motion - with Geno's own
/// failure rule, physics and servo (`tracking_task`), the same for every clip and every learner. That is what the
/// environment and the judge hold the same for a comparison between runs to mean anything. How often a learner
/// decides, how it smooths its actions and how far an action reaches are its own - a controller's design, chosen by
/// its own experiments - and travel with its recipe and its policy.
pub const GenoRunTask = struct {
    motion: PpoMotion = .dance,
};

/// PPO's recipe in a `GenoRun`: every field of `PpoRecipe`, its decision interval and DReCon's filter included - PPO
/// decides every `decimation` physics steps (DReCon's 30 Hz over Geno's 60 Hz physics), and each decision a joint's
/// target moves the share `beta` of the way to the new action (Simon: always 0.2). Defaulted to `PpoRecipe`'s values.
pub const PpoLearner = struct {
    envs: u32 = (PpoRecipe{}).envs,
    horizon: u32 = (PpoRecipe{}).horizon,
    epochs: u32 = (PpoRecipe{}).epochs,
    minibatch: u32 = (PpoRecipe{}).minibatch,
    gamma: f32 = (PpoRecipe{}).gamma,
    lambda: f32 = (PpoRecipe{}).lambda,
    clip_end: ppo_track.ClipEnd = (PpoRecipe{}).clip_end,
    hidden: u32 = (PpoRecipe{}).hidden,
    learning_rate: f32 = (PpoRecipe{}).learning_rate,
    initial_log_std: f32 = (PpoRecipe{}).initial_log_std,
    normalize: bool = (PpoRecipe{}).normalize,
    assist_start: f32 = (PpoRecipe{}).assist_start,
    assist_batches: u32 = (PpoRecipe{}).assist_batches,
    max_episode_steps: u32 = (PpoRecipe{}).max_episode_steps,
    action_scale: f32 = (PpoRecipe{}).action_scale,
    seed: u64 = (PpoRecipe{}).seed,

    /// Physics steps a decision is held for, and DReCon's filter: the share of a new action a joint's target takes
    /// each decision.
    decimation: u32 = (PpoRecipe{}).decimation,
    beta: f32 = (PpoRecipe{}).beta,
    /// The full `PpoRecipe` this learner is: every field, copied by one loop.
    pub fn recipe(learner: PpoLearner) PpoRecipe {
        var full_recipe: PpoRecipe = .{};
        inline for (@typeInfo(PpoLearner).@"struct".field_names) |field_name| {
            @field(full_recipe, field_name) = @field(learner, field_name);
        }
        return full_recipe;
    }
};

// Every field of PPO's recipe is a field of `PpoLearner` with the same type, and every field of the learner is the
// recipe's: checked when the file compiles. The copies between them are loops over the fields (`PpoLearner.recipe`,
// `GenoRun.fromPpoRun`); without this check, a field added to `PpoRecipe` and forgotten in `PpoLearner` would compile,
// and a converted run would quietly train with its default.
comptime {
    for (@typeInfo(PpoRecipe).@"struct".field_names) |field_name| {
        if (!@hasField(PpoLearner, field_name)) {
            @compileError("PpoRecipe." ++ field_name ++ " is no field of PpoLearner");
        }
        if (@FieldType(PpoLearner, field_name) != @FieldType(PpoRecipe, field_name)) {
            @compileError("PpoRecipe." ++ field_name ++ " has another type in PpoLearner");
        }
    }
    for (@typeInfo(PpoLearner).@"struct".field_names) |field_name| {
        if (!@hasField(PpoRecipe, field_name)) {
            @compileError("PpoLearner." ++ field_name ++ " is no field of PpoRecipe");
        }
    }
}

/// SuperTrack's recipe in a `GenoRun`: the GPU learner's options (`robot_track_resident.Options`) - every one, copied
/// to it by one loop and held to it when the file compiles - defaulted to the values the training page trains with
/// (`examples/geno_train`: networks and windows sized for a phone, the CAPS smoothness price on), and the action scale
/// the page trains under. SuperTrack acts at every physics step on every actuated joint, unfiltered.
pub const SuperTrackLearner = struct {
    /// Radians of joint offset per unit of action (`robot_geno.supertrack_action_scale`).
    action_scale: f32 = supertrack_action_scale,
    /// Windows per update, and steps per window.
    rows: u32 = 16,
    window: u32 = 8,
    /// The world model's width, and the policy's.
    hidden: u32 = 64,
    policy_hidden: u32 = 64,
    /// The two networks' step sizes.
    world_rate: f32 = (resident.Options{}).world_rate,
    policy_rate: f32 = (resident.Options{}).policy_rate,
    /// Exploration noise, in units of the policy's raw output: in the simulator while collecting, and inside every
    /// training rollout through the world model.
    sigma: f32 = (resident.Options{}).sigma,
    /// The price on the raw action's size, and the smoothness price along a window (CAPS): without it the policy's
    /// actions jump by most of their size from one step to the next.
    w_action: f32 = (resident.Options{}).w_action,
    w_smooth: f32 = 1.0,
    /// One round: this many simulation steps, then this many updates of each network.
    collect: u32 = 16,
    world_updates: u32 = 1,
    policy_updates: u32 = 1,
    seed: u64 = (resident.Options{}).seed,

    /// The GPU learner's options: every field but the action scale, which is the fleet's, copied by one loop.
    pub fn options(learner: SuperTrackLearner) resident.Options {
        var learner_options: resident.Options = .{};
        inline for (@typeInfo(resident.Options).@"struct".field_names) |field_name| {
            @field(learner_options, field_name) = @field(learner, field_name);
        }
        return learner_options;
    }
};

// Every option of the GPU learner is a field of `SuperTrackLearner`, with the same type, and every field of the learner
// but the fleet's action scale is an option: checked when the file compiles, so that an option added to the learner
// reaches the run file, and a run file never holds a setting nothing reads.
comptime {
    for (@typeInfo(resident.Options).@"struct".field_names) |field_name| {
        if (!@hasField(SuperTrackLearner, field_name)) {
            @compileError("robot_track_resident.Options." ++ field_name ++ " is no field of SuperTrackLearner");
        }
        if (@FieldType(SuperTrackLearner, field_name) != @FieldType(resident.Options, field_name)) {
            @compileError("SuperTrackLearner." ++ field_name ++ " has another type than the learner's option");
        }
    }
    for (@typeInfo(SuperTrackLearner).@"struct".field_names) |field_name| {
        const is_fleets: bool = eql(u8, field_name, "action_scale");
        if (!is_fleets and !@hasField(resident.Options, field_name)) {
            @compileError("SuperTrackLearner." ++ field_name ++ " is no option of the GPU learner");
        }
    }
}

/// Which version of the TD-MPC family an EfficientTDMPC run trains (`robot_bmpc.Bmpc(T).Config`): EfficientTDMPC's
/// Table 2, or BMPC's own settings beneath it.
pub const TdmpcPreset = enum {
    efficient_tdmpc,
    bmpc,
};

/// EfficientTDMPC's recipe in a `GenoRun`: the preset (`TdmpcPreset`), and the settings a run most often changes -
/// each null unless the run changes it, null meaning the preset's own value (`robot_bmpc.Bmpc(T).Config`). So the
/// preset is the one source of its numbers, and a run that chooses BMPC trains BMPC's settings, not EfficientTDMPC's
/// under BMPC's name. The action scale and the seed are the run's own.
///
/// EfficientTDMPC learns a WORLD MODEL in a latent space - an encoder from observations to a latent state, dynamics
/// that predict the next latent state from a state and an action, a reward and a value - and acts by PLANNING in it:
/// at every decision it tries candidate sequences of actions in the model and acts on the best one's first. A policy
/// network learns to imitate the planner, so that it can act on its own and seed the planner's search.
pub const TdmpcLearner = struct {
    preset: TdmpcPreset = .efficient_tdmpc,
    /// Physics steps a decision is held for, and DReCon's filter: EfficientTDMPC acts through DReCon's controller as
    /// PPO does (`robot_track_env.TrackEnv`), at DReCon's values until a measurement chooses its own.
    decimation: u32 = (PpoRecipe{}).decimation,
    beta: f32 = (PpoRecipe{}).beta,
    /// Radians of joint offset per unit of action: PPO's until a measurement chooses its own.
    action_scale: f32 = student_scale,
    /// The latent state's width, and the hidden width of every network that reads or writes it.
    latent_width: ?u32 = null,
    hidden_width: ?u32 = null,
    /// Dynamics heads trained side by side - an ensemble. Where they agree the model is sure; where they disagree
    /// it is guessing, and the planner scores a plan by their average.
    dynamics_heads: ?u32 = null,
    /// Decisions the acting planner looks ahead, and the reanalyze planner - the one that re-plans stored states
    /// with the newest model, to give the policy better targets to imitate.
    acting_horizon: ?u32 = null,
    reanalyze_horizon: ?u32 = null,
    /// PESSIMISM: the standard deviations of the heads' disagreement a reanalyzed plan pays. A plan through states the
    /// model is unsure of is scored down, so the policy learns to stay where the model is right - worth it where an
    /// episode can end early, as a fall ends the dance's.
    pessimism: ?f32 = null,
    /// Adam's step size, for every network.
    learning_rate: ?f32 = null,
    /// Windows of stored steps each update learns from: the batch, drawn from the replay of everything collected.
    windows: ?u32 = null,
    seed: u64 = 1,
};

/// What makes SuperTrack's settings impossible to train, named under `prefix` (`learner.supertrack.` in a `GenoRun`):
/// a positive, finite action scale and step sizes; noise and prices of zero or more; at least one window per update
/// and one step per window, a unit in each network, a step per round and an update of each network per round.
fn superTrackProblem(comptime prefix: []const u8, learner: SuperTrackLearner) ?[]const u8 {
    const is_action_scale_usable: bool = learner.action_scale > 0 and isFinite(learner.action_scale);
    if (!is_action_scale_usable) {
        return prefix ++ "action_scale: above 0";
    }
    const counts = [_]u32{
        learner.rows,
        learner.window,
        learner.hidden,
        learner.policy_hidden,
        learner.collect,
        learner.world_updates,
        learner.policy_updates,
    };
    const count_problems = [_][]const u8{
        prefix ++ "rows: at least 1 window",
        prefix ++ "window: at least 1 step",
        prefix ++ "hidden: at least 1 unit",
        prefix ++ "policy_hidden: at least 1 unit",
        prefix ++ "collect: at least 1 step",
        prefix ++ "world_updates: at least 1",
        prefix ++ "policy_updates: at least 1",
    };
    for (counts, count_problems) |count, count_problem| {
        if (count == 0) {
            return count_problem;
        }
    }
    const rates = [_]f32{ learner.world_rate, learner.policy_rate };
    const rate_problems = [_][]const u8{ prefix ++ "world_rate: above 0", prefix ++ "policy_rate: above 0" };
    for (rates, rate_problems) |rate, rate_problem| {
        const is_rate_usable: bool = rate > 0 and isFinite(rate);
        if (!is_rate_usable) {
            return rate_problem;
        }
    }
    const prices = [_]f32{ learner.sigma, learner.w_action, learner.w_smooth };
    const price_problems = [_][]const u8{
        prefix ++ "sigma: 0 or more",
        prefix ++ "w_action: 0 or more",
        prefix ++ "w_smooth: 0 or more",
    };
    for (prices, price_problems) |price, price_problem| {
        const is_price_usable: bool = price >= 0 and isFinite(price);
        if (!is_price_usable) {
            return price_problem;
        }
    }
    return null;
}

/// What makes EfficientTDMPC's settings impossible to train, named under `prefix` (`learner.efficient_tdmpc.` in a
/// `GenoRun`): a positive, finite action scale, and each setting the run names - the ones it leaves null are the
/// preset's own - in its range: at least one unit, head, decision and window, pessimism of zero or more, a positive
/// and finite step size.
fn tdmpcProblem(comptime prefix: []const u8, learner: TdmpcLearner) ?[]const u8 {
    const is_action_scale_usable: bool = learner.action_scale > 0 and isFinite(learner.action_scale);
    if (!is_action_scale_usable) {
        return prefix ++ "action_scale: above 0";
    }
    const counts = [_]?u32{
        learner.latent_width,
        learner.hidden_width,
        learner.dynamics_heads,
        learner.acting_horizon,
        learner.reanalyze_horizon,
        learner.windows,
    };
    const count_problems = [_][]const u8{
        prefix ++ "latent_width: at least 1 unit",
        prefix ++ "hidden_width: at least 1 unit",
        prefix ++ "dynamics_heads: at least 1 head",
        prefix ++ "acting_horizon: at least 1 decision",
        prefix ++ "reanalyze_horizon: at least 1 decision",
        prefix ++ "windows: at least 1 window",
    };
    for (counts, count_problems) |count, count_problem| {
        if (count) |named_count| {
            if (named_count == 0) {
                return count_problem;
            }
        }
    }
    if (learner.pessimism) |pessimism| {
        const is_pessimism_usable: bool = pessimism >= 0 and isFinite(pessimism);
        if (!is_pessimism_usable) {
            return prefix ++ "pessimism: 0 or more";
        }
    }
    if (learner.learning_rate) |learning_rate| {
        const is_learning_rate_usable: bool = learning_rate > 0 and isFinite(learning_rate);
        if (!is_learning_rate_usable) {
            return prefix ++ "learning_rate: above 0";
        }
    }
    return null;
}

/// The learner a `GenoRun` trains, with its recipe.
pub const GenoLearner = union(enum) {
    ppo: PpoLearner,
    supertrack: SuperTrackLearner,
    efficient_tdmpc: TdmpcLearner,

    /// The physics steps each of this learner's decisions is held for: PPO's and EfficientTDMPC's their recipes',
    /// SuperTrack's one - it acts at every step.
    pub fn decimation(learner: GenoLearner) u32 {
        return switch (learner) {
            .ppo => |ppo_learner| ppo_learner.decimation,
            .supertrack => 1,
            .efficient_tdmpc => |tdmpc_learner| tdmpc_learner.decimation,
        };
    }
};

/// A run's own controls (`GenoRun`): when it saves, keeps checkpoints and judges itself, and when it stops.
pub const GenoControls = struct {
    /// Minutes of training between rewrites of the folder's newest policy and state.
    save_minutes: f32 = (PpoRun{}).save_minutes,
    /// Minutes between checkpoints - policies kept under their minute. Zero keeps none.
    checkpoint_minutes: f32 = (PpoRun{}).checkpoint_minutes,
    /// Minutes between the judge's verdicts on the newest policy, written to the folder's judge.csv.
    judge_minutes: f32 = (PpoRun{}).judge_minutes,
    /// The run stops by itself after this many hours of training, or this many updates; zero is never.
    stop_after_hours: f32 = (PpoRun{}).stop_after_hours,
    stop_after_updates: u64 = (PpoRun{}).stop_after_batches,
};

/// A training run on Geno, as its folder's `run.zon` writes it - learner-neutral (the plan's L1): the task every
/// learner shares, the learner with its recipe, the run's controls. Every field defaulted, so an empty `.{}` is PPO
/// on the dance. A `run.zon` written before this type - a `PpoRun` - reads as the same run with PPO as its learner.
pub const GenoRun = struct {
    task: GenoRunTask = .{},
    learner: GenoLearner = .{ .ppo = .{} },
    controls: GenoControls = .{},

    pub const ParseFailure = PpoRun.ParseFailure;

    /// What makes this run impossible to train, naming the field by its path in the run file and the range it must be
    /// in - or null when it can be trained: the learner's own settings, its decision and filter among them, then the
    /// controls. One definition of
    /// each check, shared with the older `PpoRun`, which names the same fields by its own paths.
    pub fn problem(run: GenoRun) ?[]const u8 {
        const controls: GenoControls = run.controls;
        const learner_problem: ?[]const u8 = switch (run.learner) {
            .ppo => |learner| ppoProblem("learner.ppo.", learner.recipe()) orelse
                decisionProblem("learner.ppo.", learner.decimation, learner.beta),
            .supertrack => |learner| superTrackProblem("learner.supertrack.", learner),
            .efficient_tdmpc => |learner| tdmpcProblem("learner.efficient_tdmpc.", learner) orelse
                decisionProblem("learner.efficient_tdmpc.", learner.decimation, learner.beta),
        };
        return learner_problem orelse controlsProblem(
            "controls.",
            controls.save_minutes,
            controls.checkpoint_minutes,
            controls.judge_minutes,
            controls.stop_after_hours,
        );
    }

    /// A run from `run.zon`'s text: the fields it names, every other field its default. Text that is not a
    /// `GenoRun` is tried as an older `PpoRun` (`fromPpoRun`); when it is neither, the failure is the parser's
    /// description of where and why the text is no `GenoRun` (`failure`, in `arena`). Memory: two allocators, as the
    /// ZON parser takes them - `gpa` its working memory, freed before it returns; `arena` the description of a
    /// failure, which lives as long as the caller's arena. The run returned is plain values, pointing into neither.
    pub fn parse(
        gpa: Allocator,
        arena: Allocator,
        source: [:0]const u8,
        failure: *ParseFailure,
    ) error{ OutOfMemory, ParseZon }!GenoRun {
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const parsed: GenoRun = std.zon.parse.fromSlice(GenoRun, .{
            .gpa = gpa,
            .arena = arena,
            .source = source,
            .diagnostics = &diagnostics,
        }) catch |err| {
            if (err != error.ParseZon) {
                return err;
            }
            var older_failure: PpoRun.ParseFailure = .{ .description = "" };
            const older: PpoRun = PpoRun.parse(gpa, arena, source, &older_failure) catch {
                const described: std.zon.parse.Diagnostics.Formatter = diagnostics.fmt("run.zon");
                failure.description = allocPrint(arena, "{f}", .{described}) catch "unreadable";
                return error.ParseZon;
            };
            return fromPpoRun(older);
        };
        return parsed;
    }

    /// The `GenoRun` an older `run.zon` - a `PpoRun` - describes: its motion, decimation and filter as the task, the
    /// rest of its recipe as PPO's learner, its controls - its batches PPO's updates.
    pub fn fromPpoRun(older: PpoRun) GenoRun {
        const recipe: PpoRecipe = older.recipe;
        var learner: PpoLearner = .{};
        inline for (@typeInfo(PpoLearner).@"struct".field_names) |field_name| {
            @field(learner, field_name) = @field(recipe, field_name);
        }
        const run: GenoRun = .{
            .task = .{ .motion = older.motion },
            .learner = .{ .ppo = learner },
            .controls = .{
                .save_minutes = older.save_minutes,
                .checkpoint_minutes = older.checkpoint_minutes,
                .judge_minutes = older.judge_minutes,
                .stop_after_hours = older.stop_after_hours,
                .stop_after_updates = older.stop_after_batches,
            },
        };
        return run;
    }

    /// The run as the older `PpoRun` it would have been - for a trainer whose PPO path still takes one - or null when
    /// its learner is not PPO (`fromPpoRun` the other way: the two are each other's inverse for PPO's runs).
    pub fn toPpoRun(run: GenoRun) ?PpoRun {
        const learner: PpoLearner = switch (run.learner) {
            .ppo => |ppo_learner| ppo_learner,
            .supertrack, .efficient_tdmpc => return null,
        };
        const controls: GenoControls = run.controls;
        const older: PpoRun = .{
            .motion = run.task.motion,
            .recipe = learner.recipe(),
            .save_minutes = controls.save_minutes,
            .checkpoint_minutes = controls.checkpoint_minutes,
            .judge_minutes = controls.judge_minutes,
            .stop_after_hours = controls.stop_after_hours,
            .stop_after_batches = controls.stop_after_updates,
        };
        return older;
    }

    /// The run as ZON text, every field written: what a run folder's `run.zon` reads back as this run.
    pub fn write(run: GenoRun, writer: *Io.Writer) Io.Writer.Error!void {
        try std.zon.stringify.serialize(run, .{}, writer);
    }
};

test "GenoRun: an empty file is PPO on the dance; a partial one chooses EfficientTDMPC and changes one setting" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    const empty: GenoRun = try .parse(testing_allocator, arena, ".{}", &failure);
    try expectEqual(PpoMotion.dance, empty.task.motion);
    try expectEqual(@as(u32, 2), empty.learner.ppo.decimation);
    try expectEqual(@as(f32, 0.2), empty.learner.ppo.beta);
    try expect(empty.learner == .ppo);
    try expectEqual((PpoRecipe{}).envs, empty.learner.ppo.envs);
    const partial_source: [:0]const u8 =
        \\.{ .learner = .{ .efficient_tdmpc = .{ .acting_horizon = 4 } }, .controls = .{ .stop_after_hours = 8 } }
    ;
    const partial: GenoRun = try .parse(testing_allocator, arena, partial_source, &failure);
    try expect(partial.learner == .efficient_tdmpc);
    // The one setting it names, and the preset's own for the rest.
    try expectEqual(@as(?u32, 4), partial.learner.efficient_tdmpc.acting_horizon);
    try expectEqual(@as(?u32, null), partial.learner.efficient_tdmpc.dynamics_heads);
    try expectEqual(TdmpcPreset.efficient_tdmpc, partial.learner.efficient_tdmpc.preset);
    try expectEqual(@as(f32, 8), partial.controls.stop_after_hours);
    try expectEqual(@as(f32, 5), partial.controls.judge_minutes);
}

test "GenoRun: a misspelt field is refused by name; an older PPO run.zon reads as the same run" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    const misspelt: [:0]const u8 = ".{ .learnr = .{ .ppo = .{} } }";
    try expectError(error.ParseZon, GenoRun.parse(testing_allocator, arena, misspelt, &failure));
    try expect(indexOf(u8, failure.description, "learnr") != null);
    const older_source: [:0]const u8 =
        \\.{ .motion = .getup, .recipe = .{ .envs = 16, .beta = 0.3 },
        \\    .checkpoint_minutes = 10, .stop_after_batches = 900 }
    ;
    const older: GenoRun = try .parse(testing_allocator, arena, older_source, &failure);
    try expectEqual(PpoMotion.getup, older.task.motion);
    try expectEqual(@as(f32, 0.3), older.learner.ppo.beta);
    try expect(older.learner == .ppo);
    try expectEqual(@as(u32, 16), older.learner.ppo.envs);
    try expectEqual(@as(f32, 10), older.controls.checkpoint_minutes);
    try expectEqual(@as(u64, 900), older.controls.stop_after_updates);
    // The learner makes PPO's recipe back, the file's values in their places.
    const recipe: PpoRecipe = older.learner.ppo.recipe();
    try expectEqual(@as(u32, 16), recipe.envs);
    try expectEqual(@as(f32, 0.3), recipe.beta);
}

test "GenoRun: a run of any learner with its defaults can be trained; a setting out of range is named by its path" {
    const ppo_run: GenoRun = .{};
    const supertrack_run: GenoRun = .{ .learner = .{ .supertrack = .{} } };
    const tdmpc_run: GenoRun = .{ .learner = .{ .efficient_tdmpc = .{} } };
    try expectEqual(@as(?[]const u8, null), ppo_run.problem());
    try expectEqual(@as(?[]const u8, null), supertrack_run.problem());
    try expectEqual(@as(?[]const u8, null), tdmpc_run.problem());
    const out_of_range = [_]GenoRun{
        .{ .learner = .{ .ppo = .{ .beta = 0 } } },
        .{ .learner = .{ .ppo = .{ .envs = 0 } } },
        .{ .learner = .{ .supertrack = .{ .rows = 0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .dynamics_heads = 0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .pessimism = -1 } } },
        .{ .controls = .{ .save_minutes = 0 } },
    };
    const named = [_][]const u8{
        "learner.ppo.beta: above 0, at most 1",
        "learner.ppo.envs: at least 1 character",
        "learner.supertrack.rows: at least 1 window",
        "learner.efficient_tdmpc.dynamics_heads: at least 1 head",
        "learner.efficient_tdmpc.pessimism: 0 or more",
        "controls.save_minutes: above 0",
    };
    for (out_of_range, named) |run, expected| {
        try expect(eql(u8, expected, run.problem().?));
    }
    // The older format names the same checks by its own paths.
    const older: PpoRun = .{ .recipe = .{ .beta = 0 } };
    try expect(eql(u8, "recipe.beta: above 0, at most 1", older.problem().?));
}

test "GenoRun: a PPO run and the older PpoRun are each other's inverse; another learner's run has no PpoRun" {
    const older: PpoRun = .{
        .recipe = .{ .envs = 32, .gamma = 0.98, .beta = 0.3, .decimation = 3 },
        .save_minutes = 4,
        .judge_minutes = 7,
        .stop_after_batches = 900,
    };
    const run: GenoRun = .fromPpoRun(older);
    try expect(std.meta.eql(older, run.toPpoRun().?));
    const ppo_run: GenoRun = .{ .learner = .{ .ppo = .{ .horizon = 32 } }, .controls = .{ .checkpoint_minutes = 9 } };
    try expect(std.meta.eql(ppo_run, GenoRun.fromPpoRun(ppo_run.toPpoRun().?)));
    const supertrack_run: GenoRun = .{ .learner = .{ .supertrack = .{} } };
    try expectEqual(@as(?PpoRun, null), supertrack_run.toPpoRun());
}

test "GenoRun: each learner's run reads back as itself" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const runs = [_]GenoRun{
        .{ .learner = .{ .ppo = .{ .envs = 32, .learning_rate = 1e-4 } }, .controls = .{ .judge_minutes = 3 } },
        .{ .learner = .{ .supertrack = .{ .collect = 32, .w_smooth = 0.5 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .preset = .bmpc } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .dynamics_heads = 8, .pessimism = 5, .beta = 0.25 } } },
    };
    // SuperTrack's learner gives the GPU learner its options: the two it changes, and the page's values for the rest.
    const supertrack_options: resident.Options = runs[1].learner.supertrack.options();
    try expectEqual(@as(u32, 32), supertrack_options.collect);
    try expectEqual(@as(f32, 0.5), supertrack_options.w_smooth);
    try expectEqual(@as(u32, 16), supertrack_options.rows);
    for (runs) |run| {
        var text: Io.Writer.Allocating = .init(arena);
        try run.write(&text.writer);
        const source: [:0]const u8 = try arena.dupeSentinel(u8, text.written(), 0);
        var failure: GenoRun.ParseFailure = .{ .description = "" };
        const read_back: GenoRun = try .parse(testing_allocator, arena, source, &failure);
        try expectEqualDeep(run, read_back);
    }
}

test "PpoRun: an empty file is the page's own training, and the recipe's options are Geno's" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    var failure: PpoRun.ParseFailure = .{ .description = "" };
    const run: PpoRun = try .parse(testing_allocator, arena_state.allocator(), ".{}", &failure);
    try expectEqual(PpoMotion.dance, run.motion);
    try expectEqual(@as(u32, 8), run.recipe.envs);
    try expectEqual(student_scale, run.recipe.action_scale);
    const options: ppo_track.Options = run.recipe.options(run.motion);
    try expectEqual(student_scale, options.action_scale);
    try expectEqual(@as(u32, 3), options.tag);
    try expect(options.normalize);
    try expectEqual(tracking_task.floor_friction, options.task.floor_friction);
    try expectEqual(tracking_task.rest_on_floor, options.task.rest_on_floor);
}

test "PpoRun: a file names only what it changes; an unknown field is refused by name" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var failure: PpoRun.ParseFailure = .{ .description = "" };
    const partial_source: [:0]const u8 =
        \\.{
        \\    .motion = .getup,
        \\    .recipe = .{ .envs = 64, .learning_rate = 2e-4 },
        \\    .stop_after_hours = 10,
        \\}
    ;
    const partial: PpoRun = try .parse(testing_allocator, arena, partial_source, &failure);
    try expectEqual(PpoMotion.getup, partial.motion);
    try expectEqual(@as(u32, 64), partial.recipe.envs);
    try expectEqual(@as(f32, 2e-4), partial.recipe.learning_rate);
    try expectEqual(@as(u32, 64), partial.recipe.horizon);
    try expectEqual(@as(f32, 10), partial.stop_after_hours);

    const misspelt_source: [:0]const u8 = ".{ .recipe = .{ .envz = 64 } }";
    try expectError(error.ParseZon, PpoRun.parse(testing_allocator, arena, misspelt_source, &failure));
    try expect(indexOf(u8, failure.description, "envz") != null);
}

test "PpoRun: the defaults can be trained; a value out of its range is named" {
    const defaults: PpoRun = .{};
    try expect(defaults.problem() == null);
    var no_characters: PpoRun = .{};
    no_characters.recipe.envs = 0;
    try expect(startsWith(u8, no_characters.problem().?, "recipe.envs"));
    var minibatch_larger_than_batch: PpoRun = .{};
    minibatch_larger_than_batch.recipe.envs = 2;
    minibatch_larger_than_batch.recipe.horizon = 8;
    try expect(startsWith(u8, minibatch_larger_than_batch.problem().?, "recipe.minibatch"));
    var unfiltered: PpoRun = .{};
    unfiltered.recipe.beta = 0;
    try expect(startsWith(u8, unfiltered.problem().?, "recipe.beta"));
    var never_saves: PpoRun = .{};
    never_saves.save_minutes = nan(f32);
    try expect(startsWith(u8, never_saves.problem().?, "save_minutes"));
}

test "PpoRun: what `write` writes reads back as the same run" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var run: PpoRun = .{ .motion = .getup, .save_minutes = 5, .stop_after_batches = 20_000 };
    run.recipe.hidden = 96;
    run.recipe.clip_end = .bootstrap;
    var text: Io.Writer.Allocating = .init(arena);
    try run.write(&text.writer);
    const written: [:0]const u8 = try arena.dupeSentinel(u8, text.written(), 0);
    var failure: PpoRun.ParseFailure = .{ .description = "" };
    const read_back: PpoRun = try .parse(testing_allocator, arena, written, &failure);
    try expectEqual(run, read_back);
}

/// The files of a training run's folder, each by its name there: `tools/geno_trainer.zig` writes them, the training
/// lab (`examples/geno_lab`) reads them - one definition for both.
pub const RunFile = enum {
    /// The run's parameters, `PpoRun` as ZON.
    parameters,
    /// The newest weights (`ppo_track.Trainer.exportWeights`), rewritten whole every few minutes.
    weights,
    /// One line per batch (`RunLog`).
    log,
    /// Where the run is, ZON.
    status,
    /// Present when someone wants the run to stop: the trainer saves everything and exits.
    stop,
    /// One line per judgement of the newest policy, after the servo's (`JudgeLog`).
    judgements,

    /// The largest run file a reader takes in: a log of a few weeks of batches, weights many times over.
    pub const most_bytes: usize = 64 << 20;

    /// The file's name in the folder.
    pub fn fileName(file: RunFile) []const u8 {
        return switch (file) {
            .parameters => "run.zon",
            .weights => "weights",
            .log => "log.csv",
            .status => "status.zon",
            .stop => "stop",
            .judgements => "judge.csv",
        };
    }

    /// The newest policy (`GenoPolicy`, as `PolicyFile` writes it), rewritten whole with the weights.
    pub const policy_name: []const u8 = "policy";

    /// What every policy checkpoint's name starts with.
    pub const policy_checkpoint_prefix: []const u8 = "policy_m";

    /// A policy checkpoint's name: the policy after `minute` minutes of training, `policy_m<minute>` with five digits
    /// (two months of training), so that a folder listed by name lists them in training order. Minutes, not batches:
    /// a batch is a different thing to each learner, a minute of training the same, so every learner's run can be
    /// judged at the same minutes.
    pub fn policyCheckpointName(minute: u64, buffer: *NameBuffer) []const u8 {
        // Cannot fail: the buffer holds the prefix and the digits of any u64 (`name_capacity`).
        const name_format: []const u8 = policy_checkpoint_prefix ++ "{d:0>5}";
        return bufPrint(buffer, name_format, .{minute}) catch panicf(@src(), "a policy checkpoint name too long", .{});
    }

    /// The minute a policy checkpoint's name says (`policyCheckpointName` the other way); null for any other name.
    pub fn policyCheckpointMinute(name: []const u8) ?u64 {
        if (!startsWith(u8, name, policy_checkpoint_prefix)) {
            return null;
        }
        const digits: []const u8 = name[policy_checkpoint_prefix.len..];
        return parseInt(u64, digits, 10) catch null;
    }

    /// What every checkpoint's name starts with.
    pub const checkpoint_prefix: []const u8 = "weights_b";

    /// The longest name a checkpoint can have: the longer prefix and the twenty digits of the largest u64.
    pub const name_capacity: usize = @as(usize, @max(checkpoint_prefix.len, policy_checkpoint_prefix.len)) + 20;

    /// A buffer for a checkpoint's name, as long as the longest: a name built into one cannot be cut short, and a
    /// function that asks for one cannot be given a shorter buffer.
    pub const NameBuffer = [name_capacity]u8;

    /// A checkpoint's name in the folder: the weights after batch `batch`, `weights_b<batch>` with seven digits, so
    /// that a folder listed by name lists its checkpoints in training order. Built into `buffer` (`NameBuffer`).
    pub fn checkpointName(batch: u64, buffer: *NameBuffer) []const u8 {
        // Cannot fail: the buffer holds the prefix and the digits of any u64 (`name_capacity`).
        const name_format: []const u8 = checkpoint_prefix ++ "{d:0>7}";
        return bufPrint(buffer, name_format, .{batch}) catch panicf(@src(), "a checkpoint's name too long", .{});
    }

    /// The batch a checkpoint's name says (`checkpointName` the other way); null for any other name.
    pub fn checkpointBatch(name: []const u8) ?u64 {
        if (!startsWith(u8, name, checkpoint_prefix)) {
            return null;
        }
        const digits: []const u8 = name[checkpoint_prefix.len..];
        return parseInt(u64, digits, 10) catch null;
    }
};

/// How the trainer (`tools/geno_trainer.zig`) ends, as its exit code tells whoever started it - a person's shell, or
/// the training lab.
pub const TrainerExit = enum(u8) {
    /// The run ended as asked: its `stop` file, or its limits.
    finished = 0,
    /// The run was refused before training: no folder named, an unreadable or out-of-range `run.zon`, weights that
    /// do not fit.
    refused = 1,
    /// The run failed: the GPU or the robot could not be set up, or a file could not be written.
    failed = 2,

    pub fn code(exit: TrainerExit) u8 {
        return @backingInt(exit);
    }

    /// The exit an exit code means, or null for a code the trainer never gives - a program ended from outside.
    pub fn fromCode(exit_code: u32) ?TrainerExit {
        return fromInt(TrainerExit, exit_code);
    }
};

/// Where a run is, as its `status.zon` says.
pub const RunState = enum {
    /// The servo alone is being measured, before any training.
    measuring_servo,
    training,
    /// Its `stop` file appeared.
    stopped,
    /// It reached the hours or the batches its `run.zon` allows.
    finished,
};

/// What a run's `status.zon` holds: enough for a person, or a program watching the run, to know where it is without
/// reading the log. Times to failure in seconds; null when nothing has failed yet. Written by the trainer, read by the
/// training lab.
pub const RunStatus = struct {
    state: RunState,
    batches: u64,
    steps: u64,
    training_minutes: f32,
    servo_seconds_to_failure: ?f32,
    recent_seconds_to_failure: ?f32,
    assist: f32,
    /// When the status was written, in seconds since the Unix epoch by the wall clock; 0 when unknown - a status
    /// written by an older trainer.
    written_at_seconds: i64 = 0,

    /// Whether the run's trainer has gone silent: the status says it trains, but was written longer ago than three
    /// of the run's save intervals (`save_minutes`) - a trainer that died, or a machine that slept, without a word.
    /// A status of unknown age is never judged.
    pub fn isSilent(status: RunStatus, now_seconds: i64, save_minutes: f32) bool {
        const is_training: bool = status.state == .training or status.state == .measuring_servo;
        const has_known_age: bool = status.written_at_seconds > 0;
        if (!is_training or !has_known_age) {
            return false;
        }
        const age_seconds: f32 = float(now_seconds - status.written_at_seconds);
        const allowed_seconds: f32 = 3.0 * 60.0 * save_minutes;
        return age_seconds > allowed_seconds;
    }

    /// A status from its file's text; null when the text is not one - the file of an older trainer, or another
    /// program's. Memory: two allocators, as the ZON parser takes them - `gpa` its working memory, freed before it
    /// returns; `arena` anything the status itself points to, which lives as long as the caller's arena.
    pub fn parse(gpa: Allocator, arena: Allocator, source: [:0]const u8) ?RunStatus {
        // Filled by the parser when it fails; a status that cannot be read is only not shown.
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const options: std.zon.parse.Options = .{
            .gpa = gpa,
            .arena = arena,
            .source = source,
            .diagnostics = &diagnostics,
        };
        return std.zon.parse.fromSlice(RunStatus, options) catch null;
    }
};

/// A training run's log: one CSV line per batch, of raw counts rather than conclusions, so that any measure - the
/// time to failure over any window, the reward's trend - can be worked out from it afterwards. Written by the
/// trainer and the training page, read by the lab's curves.
pub const RunLog = struct {
    /// How many recent batches a run's time to failure is estimated over - by the trainer's status, the training
    /// page and the lab's curves alike: about two minutes of character-time at eight characters, enough failures to
    /// tell 10 seconds from 20.
    pub const window_batches: usize = 8;

    /// The log's first line: its columns.
    pub const header: []const u8 =
        "batch,training_minutes,steps,steps_watched,failures,mean_reward,episodes,mean_episode_steps,assist\n";

    /// Appends the line of a finished batch: the batches trained, the minutes they took, and the batch's counts.
    pub fn appendLine(
        gpa: Allocator,
        log: *ArrayList(u8),
        batches: u64,
        training_minutes: f32,
        stats: ppo_track.Stats,
    ) !void {
        var line_buffer: [160]u8 = undefined;
        const line: []const u8 = try bufPrint(&line_buffer, "{d},{d:.2},{d},{d},{d},{d:.5},{d},{d:.1},{d:.3}\n", .{
            batches,
            training_minutes,
            stats.steps,
            stats.exposure,
            stats.failures,
            stats.mean_reward,
            stats.episodes,
            stats.mean_episode,
            stats.assist,
        });
        try log.appendSlice(gpa, line);
    }

    /// One batch's line, read back: the fields `appendLine` writes, in its order.
    pub const Line = struct {
        batch: u64,
        training_minutes: f32,
        steps: u64,
        steps_watched: u64,
        failures: u32,
        mean_reward: f32,
        episodes: u32,
        mean_episode_steps: f32,
        assist: f32,
    };

    /// A batch's line read back, without its newline - or null for the header, or for a line that is not one of the
    /// log's: a column missing, one too many, or one that is not a number.
    pub fn parseLine(text: []const u8) ?Line {
        var columns: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, ',');
        const line: Line = .{
            .batch = nextInteger(u64, &columns) orelse return null,
            .training_minutes = nextFloat(&columns) orelse return null,
            .steps = nextInteger(u64, &columns) orelse return null,
            .steps_watched = nextInteger(u64, &columns) orelse return null,
            .failures = nextInteger(u32, &columns) orelse return null,
            .mean_reward = nextFloat(&columns) orelse return null,
            .episodes = nextInteger(u32, &columns) orelse return null,
            .mean_episode_steps = nextFloat(&columns) orelse return null,
            .assist = nextFloat(&columns) orelse return null,
        };
        const has_extra_column: bool = columns.next() != null;
        return if (has_extra_column) null else line;
    }

    /// The next column as an integer of type `Integer`; null when there is none, or it is not one.
    fn nextInteger(comptime Integer: type, columns: *std.mem.SplitIterator(u8, .scalar)) ?Integer {
        const column: []const u8 = columns.next() orelse return null;
        return parseInt(Integer, column, 10) catch null;
    }

    /// The next column as a number; null when there is none, or it is not one.
    fn nextFloat(columns: *std.mem.SplitIterator(u8, .scalar)) ?f32 {
        const column: []const u8 = columns.next() orelse return null;
        return parseFloat(f32, column) catch null;
    }
};

/// A run's judgements (`judge.csv`): a first line for the servo alone, the baseline every judgement is read against,
/// then one line each time the trainer judges its newest policy (`judgePolicy`, every `judge_minutes` of training) on
/// the same fixed starts. Raw counts and sums rather than conclusions, as the training log keeps them (`RunLog`): a
/// line holds every field of `robot_track.Judgement`, so that a reader rebuilds the judgement and asks it for its
/// measures and their standard errors by the same functions the trainer would use. Written by the trainer, read by
/// the lab.
pub const JudgeLog = struct {
    /// The file's first line: its columns.
    pub const header: []const u8 = "batch,training_minutes,starts,failures,reached_end,watched_steps,reward_sum," ++
        "tracked_steps_squares,failed_starts_steps,tracked_share_sum,tracked_share_squares,frame_time\n";

    /// Appends the line of one judgement, made after `batches` batches and `training_minutes` minutes of training
    /// (both zero for the servo's). Every number written as the shortest decimal that reads back to the same float,
    /// so a line read back is the judgement written. Memory: `log` grows with `gpa`, as its owner's.
    pub fn appendLine(
        gpa: Allocator,
        log: *ArrayList(u8),
        batches: u64,
        training_minutes: f32,
        judgement: robot_track.Judgement,
    ) !void {
        var line_buffer: [400]u8 = undefined;
        const line: []const u8 = try bufPrint(&line_buffer, "{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
            batches,
            training_minutes,
            judgement.starts,
            judgement.failures,
            judgement.reached_end,
            judgement.watched_steps,
            judgement.reward_sum,
            judgement.tracked_steps_squares,
            judgement.failed_starts_steps,
            judgement.tracked_share_sum,
            judgement.tracked_share_squares,
            judgement.frame_time,
        });
        try log.appendSlice(gpa, line);
    }

    /// One judgement's line, read back: when it was made, and the judgement.
    pub const Line = struct {
        batch: u64,
        training_minutes: f32,
        judgement: robot_track.Judgement,
    };

    /// A line's fields in `appendLine`'s order; null for the header, a line cut short, or one with a column too many.
    pub fn parseLine(text: []const u8) ?Line {
        var columns: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, ',');
        const batch: u64 = RunLog.nextInteger(u64, &columns) orelse return null;
        const training_minutes: f32 = RunLog.nextFloat(&columns) orelse return null;
        const judgement: robot_track.Judgement = .{
            .starts = RunLog.nextInteger(usize, &columns) orelse return null,
            .failures = RunLog.nextInteger(usize, &columns) orelse return null,
            .reached_end = RunLog.nextInteger(usize, &columns) orelse return null,
            .watched_steps = RunLog.nextInteger(usize, &columns) orelse return null,
            .reward_sum = nextFloat64(&columns) orelse return null,
            .tracked_steps_squares = nextFloat64(&columns) orelse return null,
            .failed_starts_steps = nextFloat64(&columns) orelse return null,
            .tracked_share_sum = nextFloat64(&columns) orelse return null,
            .tracked_share_squares = nextFloat64(&columns) orelse return null,
            .frame_time = RunLog.nextFloat(&columns) orelse return null,
        };
        const has_extra_column: bool = columns.next() != null;
        if (has_extra_column) {
            return null;
        }
        const line: Line = .{ .batch = batch, .training_minutes = training_minutes, .judgement = judgement };
        return line;
    }

    /// The next column as an f64; null when there is none, or it is not a number.
    fn nextFloat64(columns: *std.mem.SplitIterator(u8, .scalar)) ?f64 {
        const column: []const u8 = columns.next() orelse return null;
        return parseFloat(f64, column) catch null;
    }
};

/// A run's learning curve, read from its log as the log grows (`readMore`): one point per batch - its training
/// minutes, and the time to failure over the window of it and the batches before it (`RunLog.window_batches`), the
/// measure the trainer reports.
///
///     log         batch 1: 600 watched, 0 failures     batch 2: 600, 1     batch 3: 600, 2
///     window      600 / 0                              1200 / 1             1800 / 3
///     point       none failed yet                      20 s                 10 s          (at 60 steps a second)
pub const RunCurve = struct {
    pub const Point = struct {
        batch: u64,
        training_minutes: f32,
        /// Null while nothing in the window has failed: no time to failure to tell yet.
        seconds_to_failure: ?f32,
    };

    points: ArrayList(Point) = .empty,
    /// How far into the log's text the curve has read: always the end of a whole line.
    bytes_read: usize = 0,
    /// The last batches' steps watched and failures, in a ring.
    window_steps_watched: [RunLog.window_batches]u64 = @splat(0),
    window_failures: [RunLog.window_batches]u32 = @splat(0),
    batches_seen: usize = 0,
    /// Lines that are not the log's - another program's, or a damaged file's: skipped, and counted.
    skipped_lines: usize = 0,

    pub fn deinit(self: *RunCurve, gpa: Allocator) void {
        self.points.deinit(gpa);
    }

    /// Reads the log's whole lines past `bytes_read`, `log_text` being the whole log as its file holds it now. A
    /// last line without its newline - the log being written as it is read - waits for the next read. A log
    /// shorter than what was read - a run carried on from an earlier save - is read again from its start.
    pub fn readMore(
        self: *RunCurve,
        gpa: Allocator,
        log_text: []const u8,
        physics_steps_per_second: f32,
    ) !void {
        if (log_text.len < self.bytes_read) {
            // A fresh curve, keeping the points' memory: the list is set aside first, since the new value is
            // written straight into `self`.
            var kept_points: ArrayList(Point) = self.points;
            kept_points.clearRetainingCapacity();
            self.* = .{ .points = kept_points };
        }
        const unread: []const u8 = log_text[self.bytes_read..];
        const last_newline: usize = std.mem.lastIndexOfScalar(u8, unread, '\n') orelse return;
        const whole_lines: []const u8 = unread[0..last_newline];
        var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, whole_lines, '\n');
        while (lines.next()) |line_text| {
            const is_header: bool = startsWith(u8, line_text, "batch,");
            if (is_header) {
                continue;
            }
            const line: RunLog.Line = RunLog.parseLine(line_text) orelse {
                self.skipped_lines += 1;
                continue;
            };
            try self.addBatch(gpa, line, physics_steps_per_second);
        }
        self.bytes_read += last_newline + 1;
    }

    /// One batch into the window, and its point onto the curve.
    fn addBatch(
        self: *RunCurve,
        gpa: Allocator,
        line: RunLog.Line,
        physics_steps_per_second: f32,
    ) !void {
        const slot: usize = self.batches_seen % RunLog.window_batches;
        self.window_steps_watched[slot] = line.steps_watched;
        self.window_failures[slot] = line.failures;
        self.batches_seen += 1;
        const batches_in_window: usize = @min(self.batches_seen, RunLog.window_batches);
        var steps_watched: u64 = 0;
        var failures: u64 = 0;
        for (0..batches_in_window) |window_slot| {
            steps_watched += self.window_steps_watched[window_slot];
            failures += self.window_failures[window_slot];
        }
        const seconds_to_failure: ?f32 = ppo_track.secondsToFailure(steps_watched, failures, physics_steps_per_second);
        try self.points.append(gpa, .{
            .batch = line.batch,
            .training_minutes = line.training_minutes,
            .seconds_to_failure = seconds_to_failure,
        });
    }
};

test "RunFile: a checkpoint's batch reads back from its name; other names have none" {
    var name_buffer: RunFile.NameBuffer = undefined;
    const name: []const u8 = RunFile.checkpointName(1234, &name_buffer);
    try expectEqual(@as(?u64, 1234), RunFile.checkpointBatch(name));
    try expectEqual(@as(?u64, null), RunFile.checkpointBatch("weights"));
    try expectEqual(@as(?u64, null), RunFile.checkpointBatch("weights_bnew"));
    try expectEqual(@as(?u64, null), RunFile.checkpointBatch("log.csv"));
}

test "RunFile: a policy checkpoint's minute reads back from its name; a weights checkpoint's name has none" {
    var buffer: RunFile.NameBuffer = undefined;
    const name: []const u8 = RunFile.policyCheckpointName(90, &buffer);
    try expect(eql(u8, "policy_m00090", name));
    try expectEqual(@as(?u64, 90), RunFile.policyCheckpointMinute(name));
    try expectEqual(@as(?u64, null), RunFile.policyCheckpointMinute("weights_b0000090"));
    try expectEqual(@as(?u64, null), RunFile.policyCheckpointMinute(RunFile.policy_name));
}

test "RunStatus: silent when it trains but was written three save intervals ago; never when its age is unknown" {
    const minute: i64 = 60;
    const now: i64 = 1_000_000_000;
    const save_minutes: f32 = 2;
    const recent: RunStatus = .{
        .state = .training,
        .batches = 10,
        .steps = 0,
        .training_minutes = 1,
        .servo_seconds_to_failure = null,
        .recent_seconds_to_failure = null,
        .assist = 0,
        .written_at_seconds = now - 5 * minute,
    };
    try expect(!recent.isSilent(now, save_minutes));
    var old: RunStatus = recent;
    old.written_at_seconds = now - 7 * minute;
    try expect(old.isSilent(now, save_minutes));
    var finished_long_ago: RunStatus = old;
    finished_long_ago.state = .finished;
    try expect(!finished_long_ago.isSilent(now, save_minutes));
    var of_unknown_age: RunStatus = old;
    of_unknown_age.written_at_seconds = 0;
    try expect(!of_unknown_age.isSilent(now, save_minutes));
}

test "RunLog: a line written reads back as written; the header and a stranger's line do not" {
    var log: ArrayList(u8) = .empty;
    defer log.deinit(testing_allocator);
    const stats: ppo_track.Stats = .{
        .decisions = 64,
        .steps = 1024,
        .mean_reward = 0.25,
        .episodes = 2,
        .mean_episode = 70,
        .exposure = 1000,
        .failures = 3,
        .assist = 0.5,
    };
    try RunLog.appendLine(testing_allocator, &log, 7, 1.5, stats);
    const line_text: []const u8 = std.mem.trimEnd(u8, log.items, "\n");
    const line: RunLog.Line = RunLog.parseLine(line_text).?;
    try expectEqual(@as(u64, 7), line.batch);
    try expectEqual(@as(f32, 1.5), line.training_minutes);
    try expectEqual(@as(u64, 1024), line.steps);
    try expectEqual(@as(u64, 1000), line.steps_watched);
    try expectEqual(@as(u32, 3), line.failures);
    try expectEqual(@as(f32, 0.25), line.mean_reward);
    try expectEqual(@as(u32, 2), line.episodes);
    try expectEqual(@as(f32, 70), line.mean_episode_steps);
    try expectEqual(@as(f32, 0.5), line.assist);
    const header_line: []const u8 = std.mem.trimEnd(u8, RunLog.header, "\n");
    try expect(RunLog.parseLine(header_line) == null);
    try expect(RunLog.parseLine("7,1.5,1024") == null);
    try expect(RunLog.parseLine("7,1.5,1024,1000,3,0.25,2,70,0.5,extra") == null);
}

test "JudgeLog: a judgement written reads back as itself; the header and a line too long are no judgement" {
    const gpa: Allocator = testing_allocator;
    var log: ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    const judgement: robot_track.Judgement = .{
        .starts = 120,
        .failures = 37,
        .reached_end = 83,
        .watched_steps = 345_678,
        .reward_sum = 123_456.789,
        .frame_time = 1.0 / 60.0,
        .tracked_steps_squares = 1.234_567_890_123e9,
        .failed_starts_steps = 4321.5,
        .tracked_share_sum = 97.123_456_789,
        .tracked_share_squares = 85.987_654_321,
    };
    try log.appendSlice(gpa, JudgeLog.header);
    try JudgeLog.appendLine(gpa, &log, 4200, 61.5, judgement);
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, log.items, '\n');
    const header_line: []const u8 = lines.next().?;
    try expectEqual(@as(?JudgeLog.Line, null), JudgeLog.parseLine(header_line));
    const judgement_line: []const u8 = lines.next().?;
    const read: JudgeLog.Line = JudgeLog.parseLine(judgement_line).?;
    try expectEqual(@as(u64, 4200), read.batch);
    try expectEqual(@as(f32, 61.5), read.training_minutes);
    try expect(std.meta.eql(judgement, read.judgement));
    // Its measures, from the line read back, are the judgement's own.
    try expectEqual(judgement.meanTimeToFailureError(), read.judgement.meanTimeToFailureError());
    var too_long: [512]u8 = undefined;
    const longer_line: []const u8 = try bufPrint(&too_long, "{s},7", .{judgement_line});
    try expectEqual(@as(?JudgeLog.Line, null), JudgeLog.parseLine(longer_line));
}

test "RunCurve: a point per batch, the window's time to failure, none where nothing failed" {
    const log_text: []const u8 = RunLog.header ++
        "1,0.10,600,600,0,0.3,1,600.0,1.0\n" ++
        "2,0.20,600,600,1,0.3,1,600.0,1.0\n" ++
        "3,0.30,600,600,2,0.3,2,300.0,1.0\n";
    var curve: RunCurve = .{};
    defer curve.deinit(testing_allocator);
    try curve.readMore(testing_allocator, log_text, 60);
    try expectEqual(@as(usize, 3), curve.points.items.len);
    try expect(curve.points.items[0].seconds_to_failure == null);
    try expectApproxEqAbs(@as(f32, 20), curve.points.items[1].seconds_to_failure.?, 1e-4);
    try expectApproxEqAbs(@as(f32, 10), curve.points.items[2].seconds_to_failure.?, 1e-4);
    try expectEqual(@as(f32, 0.30), curve.points.items[2].training_minutes);
    try expectEqual(@as(usize, 0), curve.skipped_lines);
}

test "RunCurve: a line still being written waits; a shorter log is read again; a stranger's line is skipped" {
    var curve: RunCurve = .{};
    defer curve.deinit(testing_allocator);
    // The header alone: no points.
    try curve.readMore(testing_allocator, RunLog.header, 60);
    try expectEqual(@as(usize, 0), curve.points.items.len);
    // A last line without its newline waits; once its newline is there, it is read - and only once.
    const partial: []const u8 = RunLog.header ++ "1,0.10,600,600,1,0.3,1,600.0,1.0\n2,0.20,600";
    try curve.readMore(testing_allocator, partial, 60);
    try expectEqual(@as(usize, 1), curve.points.items.len);
    const whole: []const u8 = RunLog.header ++ "1,0.10,600,600,1,0.3,1,600.0,1.0\n2,0.20,600,600,1,0.3,1,600.0,1.0\n";
    try curve.readMore(testing_allocator, whole, 60);
    try expectEqual(@as(usize, 2), curve.points.items.len);
    try expectEqual(@as(u64, 2), curve.points.items[1].batch);
    // A shorter log - the run carried on from an earlier save - is read again from its start.
    const shorter: []const u8 = RunLog.header ++ "1,0.10,600,600,1,0.3,1,600.0,1.0\n";
    try curve.readMore(testing_allocator, shorter, 60);
    try expectEqual(@as(usize, 1), curve.points.items.len);
    // A line that is not the log's is skipped, and counted.
    const with_stranger: []const u8 = shorter ++ "not,a,batch\n";
    try curve.readMore(testing_allocator, with_stranger, 60);
    try expectEqual(@as(usize, 1), curve.points.items.len);
    try expectEqual(@as(usize, 1), curve.skipped_lines);
}

test "RunLog: a batch's line has a value for every column of the header" {
    var log: ArrayList(u8) = .empty;
    defer log.deinit(testing_allocator);
    try log.appendSlice(testing_allocator, RunLog.header);
    const stats: ppo_track.Stats = .{
        .decisions = 64,
        .steps = 1024,
        .mean_reward = 0.25,
        .episodes = 2,
        .mean_episode = 70,
    };
    try RunLog.appendLine(testing_allocator, &log, 3, 1.5, stats);
    var lines = splitScalar(u8, std.mem.trimEnd(u8, log.items, "\n"), '\n');
    const header_line: []const u8 = lines.next().?;
    const batch_line: []const u8 = lines.next().?;
    const header_columns: usize = std.mem.count(u8, header_line, ",") + 1;
    const batch_columns: usize = std.mem.count(u8, batch_line, ",") + 1;
    try expectEqual(header_columns, batch_columns);
    try expect(startsWith(u8, batch_line, "3,1.50,1024,"));
}

// ---- The policy a run deploys ----
//
// A training run produces two different things. Its TRAINING STATE is everything its learner needs to carry on: for
// PPO, both networks (the actor and the critic), Adam's two moments for every parameter, the observation normaliser's
// running statistics and the counters - the run folder's `weights` file. Its POLICY is only what acting needs: the
// function from what the character senses to what it does. The critic, the optimiser's moments and the exploration
// noise are tools of learning; a policy that is deployed - watched in the lab, judged, played in a page - needs none
// of them.
//
// Keeping the two apart is a practice worth its small cost:
//
//   * Every learner is watched and judged the same way. PPO, SuperTrack and EfficientTDMPC keep very different
//     training states, but each deploys a policy of the same form, so one player (`policyMeanAction`), one show
//     (`PolicyShow`) and one judge serve them all, and a comparison between learners compares their policies, not
//     the code paths that happen to run them.
//   * The observation's normalisation travels with the network. A network trained on normalised inputs computes
//     nonsense on raw ones; normalised by statistics other than its own, it computes something subtly wrong - a
//     classic deployment bug, in which a policy that trained well looks broken when it is evaluated. The statistics
//     are frozen into the policy at the moment it is written.
//   * The policy acts by its MEAN action. A stochastic policy explores by sampling around its mean while it learns;
//     shown or judged, it acts deterministically, so that what is measured is what it learned, not its noise.
//   * What turns the network's output into joint targets travels with it as well: the action's limit, its scale
//     (radians per unit) and DReCon's filter. A policy is judged under the controller it was trained under.
//
// The pipeline a policy applies, from observation to joints (the last two steps are the controller's,
// `robot_policy.Controller`):
//
//     observation -> normalise -> layer 1 -> ... -> layer n -> clamp -> scale -> filter -> joint targets
//
//   observation   the task's own units: angles, heights, velocities (`robot_policy.observeFrom`)
//   normalise     each input: its mean taken away, divided by its deviation, clamped to a few deviations
//   layers        dense: each output its bias plus its weighted inputs, through the layer's activation
//   clamp         the mean action held to the controller's range, plus or minus `action_limit`
//   scale         radians of joint offset per unit of action
//   filter        each decision, a joint's target moves the share `filter_beta` of the way to the new action

/// What a policy's layer applies to each of its pre-activations (`PolicyLayer`): nothing - a linear layer, as a PPO
/// actor's last layer is, so that its outputs are the action's mean - or tanh, which squashes every value into
/// (-1, 1), as a PPO actor's hidden layers do (`robot_gym.GpuPpoOn`).
pub const PolicyActivation = enum(u8) {
    none,
    tanh,
};

/// One dense layer of a policy (`GenoPolicy`): its activation, and its weights and biases. How many values it reads
/// and writes are the policy's widths on either side of it (`GenoPolicy.widths`), so that one layer's outputs are the
/// next one's inputs by construction.
///
/// Each output is the activation of its PRE-ACTIVATION: its bias, plus every input times the weight that joins the
/// two, the inputs taken in order. `weights_and_biases` is laid out as the GPU kit lays out a layer (`robot_gym`'s
/// `kitLayer`): first the weight matrix W, a row per input and a column per output, row-major - the weight from input
/// i to output o at `i * output_count + o` - then the bias vector b, one per output. The kit's order of arithmetic is
/// kept too (the bias first, then the inputs in order): floating-point addition is not associative, so the same
/// weights summed in another order give slightly different floats, and a policy played here would no longer act
/// exactly as it acted while it trained.
pub const PolicyLayer = struct {
    activation: PolicyActivation,
    weights_and_biases: []f32,

    /// How many floats a layer of this shape holds: W, then b.
    pub fn parameterCount(input_count: usize, output_count: usize) usize {
        const weight_count: usize = input_count * output_count;
        return weight_count + output_count;
    }
};

/// A policy as the lab plays it, whichever learner made it - the deployable part of a run (see this section's head):
/// the layers that turn an observation into an action, the observation's normaliser frozen at the moment the policy
/// was written, and what the controller does with the action.
///
/// The observation is normalised by the frozen normaliser, when there is one - zimrrl's `ObsNormalizer`, the very
/// function that normalised every observation the policy trained on, so that training and deployment agree by
/// construction. It then passes through the layers in order. The last layer's outputs, clamped to `action_limit`
/// either side, are the action: the policy's mean action, with no exploration noise. The controller scales it by
/// `action_scale` and low-passes it with `filter_beta`, DReCon's filter.
pub const GenoPolicy = struct {
    /// The network's widths, from input to output: the observation's size, each hidden layer's width, the action's
    /// size - a PPO actor on Geno is `{ observation, 48, 48, actuated joints }`. Layer i maps `widths[i]` values to
    /// `widths[i + 1]`, so there is one more width than there are layers, and the layers are chained by construction.
    widths: []u32,
    layers: []PolicyLayer,
    /// The observation normaliser as it stood when the policy was written (`zrl.ObsNormalizer`: each input's mean and
    /// sum of squared deviations, how many observations they count, the clip), never updated again - or null, when the
    /// policy takes raw observations. A policy only ever applies it (`applyInPlaceF32`).
    normalization: ?zrl.ObsNormalizer,
    /// The largest an action component may be either side of zero: the controller's range.
    action_limit: f32,
    /// Radians of joint offset per unit of action.
    action_scale: f32,
    /// DReCon's filter: the share of the way a joint's target moves toward a new action at each decision.
    filter_beta: f32,

    /// The observation's size: the first width.
    pub fn observationSize(policy: *const GenoPolicy) usize {
        return policy.widths[0];
    }

    /// The action's size - one component per actuated degree of freedom: the last width.
    pub fn actionSize(policy: *const GenoPolicy) usize {
        return policy.widths[policy.widths.len - 1];
    }

    /// The largest width: how wide each of the forward pass's two buffers must be (`PolicyScratch`).
    pub fn widestLayer(policy: *const GenoPolicy) usize {
        var widest_layer: usize = 0;
        for (policy.widths) |width| {
            widest_layer = @max(widest_layer, width);
        }
        return widest_layer;
    }

    /// Frees the policy's arrays, allocated with `gpa` (`policyOfPpo`, `PolicyFile.decode`). A policy made in an
    /// arena needs no `deinit`: the arena frees it.
    pub fn deinit(policy: *GenoPolicy, gpa: Allocator) void {
        for (policy.layers) |layer| {
            gpa.free(layer.weights_and_biases);
        }
        gpa.free(policy.layers);
        gpa.free(policy.widths);
        if (policy.normalization) |normalization| {
            gpa.free(normalization.mean);
            gpa.free(normalization.m2);
        }
    }
};

/// The forward pass's two buffers, used PING-PONG: each layer reads its input from one and writes its output into
/// the other, and the next layer the other way round - so a network of any depth runs in two buffers, each as wide as
/// its widest layer (`GenoPolicy.widestLayer`).
pub const PolicyScratch = struct {
    ping: []f32,
    pong: []f32,

    /// The two buffers sized for `policy` (`GenoPolicy.widestLayer`): the scratch's one constructor, so that no scratch
    /// is ever too narrow for its policy. Memory: both in `arena`, the caller's.
    pub fn init(arena: Allocator, policy: *const GenoPolicy) !PolicyScratch {
        const widest_layer: usize = policy.widestLayer();
        const ping: []f32 = try arena.alloc(f32, widest_layer);
        const pong: []f32 = try arena.alloc(f32, widest_layer);
        return .{ .ping = ping, .pong = pong };
    }
};

/// One layer of a policy on `layer_input`, written into `layer_output` (`PolicyLayer`): each output's bias, plus each
/// input times its weight in input order, then the layer's activation.
fn applyPolicyLayer(
    layer: PolicyLayer,
    layer_input: []const f32,
    layer_output: []f32,
) void {
    const input_count: usize = layer_input.len;
    const output_count: usize = layer_output.len;
    const biases_start: usize = input_count * output_count;
    for (0..output_count) |output_index| {
        // The bias first, then every input's contribution in input order: the kit's order of arithmetic.
        var pre_activation: f32 = layer.weights_and_biases[biases_start + output_index];
        for (layer_input, 0..) |input_value, input_index| {
            const weight: f32 = layer.weights_and_biases[input_index * output_count + output_index];
            pre_activation += input_value * weight;
        }
        layer_output[output_index] = switch (layer.activation) {
            .none => pre_activation,
            .tanh => tanh(pre_activation),
        };
    }
}

/// The action `policy` takes for `observation`, written into `action` (`GenoPolicy`): the observation normalised by
/// the frozen normaliser, passed through the layers - `scratch` holding each layer's input and output - and the last
/// layer's outputs clamped to the controller's range. No randomness: the policy's mean action, as the show and the
/// judge act.
pub fn policyMeanAction(
    policy: *const GenoPolicy,
    observation: []const f32,
    scratch: PolicyScratch,
    action: []f32,
) void {
    const observation_size: usize = policy.observationSize();
    const action_size: usize = policy.actionSize();
    const widest_layer: usize = policy.widestLayer();
    const observation_fits: bool = observation.len == observation_size;
    assertf(observation_fits, @src(), "policyMeanAction: an observation of {d}, the policy takes {d}", .{
        observation.len,
        observation_size,
    });
    assertf(action.len == action_size, @src(), "policyMeanAction: an action of {d}, the policy gives {d}", .{
        action.len,
        action_size,
    });
    const scratch_fits: bool = scratch.ping.len >= widest_layer and scratch.pong.len >= widest_layer;
    assertf(scratch_fits, @src(), "policyMeanAction: scratch of {d} and {d}, the widest layer {d}", .{
        scratch.ping.len,
        scratch.pong.len,
        widest_layer,
    });
    // The observation copied into the ping buffer, and normalised there by the frozen normaliser - the function that
    // normalised every observation the policy trained on.
    const normalized_observation: []f32 = scratch.ping[0..observation_size];
    @memcpy(normalized_observation, observation);
    if (policy.normalization) |normalization| {
        normalization.applyInPlaceF32(normalized_observation) catch {
            assertUnreachable(@src(), "policyMeanAction: a normaliser of another size than the observation", .{});
        };
    }
    // The layers, ping-pong: each reads the buffer the one before it wrote. The last writes straight into `action`.
    var layer_input: []const f32 = normalized_observation;
    var input_is_in_ping: bool = true;
    for (policy.layers, 0..) |layer, layer_index| {
        const is_last_layer: bool = layer_index + 1 == policy.layers.len;
        const output_count: usize = policy.widths[layer_index + 1];
        const other_buffer: []f32 = if (input_is_in_ping) scratch.pong else scratch.ping;
        const layer_output: []f32 = if (is_last_layer) action else other_buffer[0..output_count];
        applyPolicyLayer(layer, layer_input, layer_output);
        layer_input = layer_output;
        input_is_in_ping = !input_is_in_ping;
    }
    // The mean action, held to the controller's range.
    for (action) |*component| {
        component.* = clamp(component.*, -policy.action_limit, policy.action_limit);
    }
}

/// What a PPO actor is made of, as `robot_gym.GpuPpoOn` and `robot_ppo_track.Trainer` keep it - everything
/// `policyOfPpo` needs, and nothing of the critic or the optimiser.
pub const PpoPolicyParts = struct {
    /// The GPU kit's parameters - both networks and the log-standard-deviations, contiguous - as the weights file
    /// holds them: the latest readback, not the actor's CPU copy, which can lag it by an update.
    kit_parameters: []const f32,
    /// Where each of the actor's three layers starts among them (`GpuPpoOn.p_off`).
    actor_layer_offsets: [3]u32,
    /// The actor's widths: the observation's inputs, its two hidden layers' width, the action's components.
    observation_size: usize,
    hidden_width: usize,
    action_size: usize,
    /// The trainer's observation normaliser (`Trainer.observation_normalizer`), copied into the policy and frozen
    /// there; null when the trainer does not normalise.
    observation_normalizer: ?zrl.ObsNormalizer,
    /// The controller's range, scale and filter (`robot_track_env.Options.action_limit`, `.action_scale`, `.beta`).
    action_limit: f32,
    action_scale: f32,
    filter_beta: f32,
};

/// The policy of a PPO actor (`PpoPolicyParts`): its widths, its three layers - tanh, tanh and linear - copied out of
/// the kit's parameters, and a frozen copy of the trainer's normaliser. Memory: the policy's arrays are allocated with
/// `gpa` and are the caller's - `deinit(gpa)` frees them, or, when `gpa` is an arena, the arena does.
pub fn policyOfPpo(gpa: Allocator, parts: PpoPolicyParts) !GenoPolicy {
    const widths: []u32 = try gpa.alloc(u32, 4);
    errdefer gpa.free(widths);
    widths[0] = @intCast(parts.observation_size);
    widths[1] = @intCast(parts.hidden_width);
    widths[2] = @intCast(parts.hidden_width);
    widths[3] = @intCast(parts.action_size);
    const layer_activations = [3]PolicyActivation{ .tanh, .tanh, .none };
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, 3);
    var layers_made: usize = 0;
    errdefer {
        for (layers[0..layers_made]) |layer| {
            gpa.free(layer.weights_and_biases);
        }
        gpa.free(layers);
    }
    for (layers, 0..) |*layer, layer_index| {
        const input_count: usize = widths[layer_index];
        const output_count: usize = widths[layer_index + 1];
        const parameter_count: usize = PolicyLayer.parameterCount(input_count, output_count);
        const layer_start: usize = parts.actor_layer_offsets[layer_index];
        const layer_parameters: []const f32 = parts.kit_parameters[layer_start..][0..parameter_count];
        const weights_and_biases: []f32 = try gpa.dupe(f32, layer_parameters);
        layer.* = .{ .activation = layer_activations[layer_index], .weights_and_biases = weights_and_biases };
        layers_made += 1;
    }
    // The normaliser copied, so that the trainer's next observations cannot move the policy's.
    var normalization: ?zrl.ObsNormalizer = null;
    if (parts.observation_normalizer) |trainer_normalizer| {
        const frozen_mean: []f64 = try gpa.dupe(f64, trainer_normalizer.mean);
        errdefer gpa.free(frozen_mean);
        const frozen_m2: []f64 = try gpa.dupe(f64, trainer_normalizer.m2);
        normalization = .{
            .mean = frozen_mean,
            .m2 = frozen_m2,
            .count = trainer_normalizer.count,
            .clip = trainer_normalizer.clip,
            .epsilon = trainer_normalizer.epsilon,
        };
    }
    const policy: GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = normalization,
        .action_limit = parts.action_limit,
        .action_scale = parts.action_scale,
        .filter_beta = parts.filter_beta,
    };
    return policy;
}

/// A policy file (`GenoPolicy`): a `Header`, then each layer - a `LayerHeader` and its weights and biases (f32, W then
/// b) - then, when the observation is normalised, the frozen normaliser's per-input means and sums of squared
/// deviations (f64 each).
///
/// The header and the layers' headers are written and read as they lie in memory: an `extern struct` has C's layout,
/// the same on every target, so each declaration below IS the file's layout, for writing and for reading alike - there
/// are no two hand-written sequences to keep in step. Every target zimr builds for is little-endian (checked below),
/// so the bytes are the same everywhere.
///
/// A file is the only form a policy has outside a program, so its reader trusts none of it: every count is checked
/// against the bytes left before anything is allocated, with arithmetic that cannot overflow, and a file that is no
/// policy is refused by a name that says why (`ReadError`).
pub const PolicyFile = struct {
    pub const magic: [4]u8 = .{ 'G', 'P', 'O', 'L' };
    /// The layout's version: 2, the widths and the frozen normaliser (version 1 kept each layer's inputs, and each
    /// input's deviation in place of the normaliser's statistics).
    pub const version: u32 = 2;

    /// A file's flags (`Header.flags`), as a packed struct: a bit this reader does not know is one field to check.
    pub const Flags = packed struct(u32) {
        normalizes_observations: bool,
        unknown: u31 = 0,
    };

    /// The start of every policy file. The frozen normaliser's count, clip and epsilon are zero when the observation is
    /// not normalised.
    pub const Header = extern struct {
        magic: [4]u8,
        version: u32,
        layer_count: u32,
        /// `Flags`, as its backing integer.
        flags: u32,
        observation_size: u32,
        action_limit: f32,
        action_scale: f32,
        filter_beta: f32,
        observations_counted: f64,
        observation_clip: f64,
        observation_epsilon: f64,
    };

    /// What precedes each layer's weights and biases: its output count (its input count is the width before it) and
    /// its activation (`PolicyActivation`'s backing integer).
    pub const LayerHeader = extern struct {
        output_count: u32,
        activation: u32,
    };

    comptime {
        if (builtin.cpu.arch.endian() != .little) {
            @compileError("PolicyFile writes its headers as they lie in memory, which assumes a little-endian target");
        }
    }

    /// Why a file is no policy: the wrong first bytes, a version this reader does not know, flags it does not know, too
    /// few bytes for what the file says it holds, too many - bytes after its end - no layer, an activation it does not
    /// know, or a normaliser that cannot be (a clip or an epsilon not positive, a statistic not finite, a sum of
    /// squared deviations below zero).
    pub const ReadError = error{
        NotAPolicyFile,
        PolicyVersionUnknown,
        PolicyFlagsUnknown,
        PolicyTruncated,
        PolicyHasTrailingBytes,
        PolicyHasNoLayers,
        PolicyActivationUnknown,
        PolicyNormalizationInvalid,
        OutOfMemory,
    };

    /// The file's bytes for `policy`, allocated with `gpa` and the caller's to free (or its arena's). The policy must
    /// be one `decode` reads back: a width more than its layers, each layer holding the parameters of its shape, a
    /// normaliser as wide as the observation.
    pub fn encode(gpa: Allocator, policy: *const GenoPolicy) ![]u8 {
        const layer_count: usize = policy.layers.len;
        assertf(layer_count > 0, @src(), "PolicyFile.encode: a policy with no layer", .{});
        assertf(policy.widths.len == layer_count + 1, @src(), "PolicyFile.encode: {d} widths for {d} layers", .{
            policy.widths.len,
            layer_count,
        });
        for (policy.layers, 0..) |layer, layer_index| {
            const parameter_count: usize = PolicyLayer.parameterCount(
                policy.widths[layer_index],
                policy.widths[layer_index + 1],
            );
            const holds_its_parameters: bool = layer.weights_and_biases.len == parameter_count;
            assertf(holds_its_parameters, @src(), "PolicyFile.encode: layer {d} holds {d} parameters of {d}", .{
                layer_index,
                layer.weights_and_biases.len,
                parameter_count,
            });
        }
        const normalization: ?zrl.ObsNormalizer = policy.normalization;
        if (normalization) |normalizer| {
            const normalizer_fits: bool = normalizer.mean.len == policy.observationSize() and
                normalizer.m2.len == policy.observationSize();
            assertf(normalizer_fits, @src(), "PolicyFile.encode: a normaliser of {d}, an observation of {d}", .{
                normalizer.mean.len,
                policy.observationSize(),
            });
        }
        const flags: Flags = .{ .normalizes_observations = normalization != null };
        const header: Header = .{
            .magic = magic,
            .version = version,
            .layer_count = @intCast(layer_count),
            .flags = @bitCast(flags),
            .observation_size = policy.widths[0],
            .action_limit = policy.action_limit,
            .action_scale = policy.action_scale,
            .filter_beta = policy.filter_beta,
            .observations_counted = if (normalization) |normalizer| normalizer.count else 0,
            .observation_clip = if (normalization) |normalizer| normalizer.clip else 0,
            .observation_epsilon = if (normalization) |normalizer| normalizer.epsilon else 0,
        };
        var bytes: ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, asBytes(&header));
        for (policy.layers, 0..) |layer, layer_index| {
            const layer_header: LayerHeader = .{
                .output_count = policy.widths[layer_index + 1],
                .activation = @backingInt(layer.activation),
            };
            try bytes.appendSlice(gpa, asBytes(&layer_header));
            try bytes.appendSlice(gpa, sliceAsBytes(layer.weights_and_biases));
        }
        if (normalization) |normalizer| {
            try bytes.appendSlice(gpa, sliceAsBytes(normalizer.mean));
            try bytes.appendSlice(gpa, sliceAsBytes(normalizer.m2));
        }
        return bytes.toOwnedSlice(gpa);
    }

    /// The policy in a file's `bytes` (`encode`). Memory: its arrays are allocated with `gpa` and are the caller's -
    /// `deinit(gpa)` frees them, or, when `gpa` is an arena, the arena does; nothing points into `bytes`.
    pub fn decode(gpa: Allocator, bytes: []const u8) ReadError!GenoPolicy {
        var reader: Reader = .{ .bytes = bytes };
        const first_bytes: []const u8 = try reader.take(magic.len);
        if (!eql(u8, first_bytes, &magic)) {
            return error.NotAPolicyFile;
        }
        reader.at = 0;
        const header: Header = bytesToValue(Header, try reader.take(@sizeOf(Header)));
        if (header.version != version) {
            return error.PolicyVersionUnknown;
        }
        const flags: Flags = @bitCast(header.flags);
        if (flags.unknown != 0) {
            return error.PolicyFlagsUnknown;
        }
        const layer_count: usize = header.layer_count;
        if (layer_count == 0) {
            return error.PolicyHasNoLayers;
        }
        // The counts checked against the bytes left before anything is allocated: a damaged count asks for no memory.
        const least_layer_bytes: usize = mulChecked(usize, layer_count, @sizeOf(LayerHeader)) catch {
            return error.PolicyTruncated;
        };
        if (least_layer_bytes > reader.left()) {
            return error.PolicyTruncated;
        }
        const widths: []u32 = try gpa.alloc(u32, layer_count + 1);
        errdefer gpa.free(widths);
        widths[0] = header.observation_size;
        const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, layer_count);
        var layers_read: usize = 0;
        errdefer {
            for (layers[0..layers_read]) |layer| {
                gpa.free(layer.weights_and_biases);
            }
            gpa.free(layers);
        }
        for (layers, 0..) |*layer, layer_index| {
            const layer_header: LayerHeader = bytesToValue(LayerHeader, try reader.take(@sizeOf(LayerHeader)));
            const activation: PolicyActivation = fromInt(PolicyActivation, layer_header.activation) orelse {
                return error.PolicyActivationUnknown;
            };
            widths[layer_index + 1] = layer_header.output_count;
            const input_count: u32 = widths[layer_index];
            const parameter_count: usize = layerParameterCount(input_count, layer_header.output_count) orelse {
                return error.PolicyTruncated;
            };
            const parameter_bytes: usize = mulChecked(usize, parameter_count, @sizeOf(f32)) catch {
                return error.PolicyTruncated;
            };
            if (parameter_bytes > reader.left()) {
                return error.PolicyTruncated;
            }
            const weights_and_biases: []f32 = try gpa.alloc(f32, parameter_count);
            @memcpy(sliceAsBytes(weights_and_biases), try reader.take(parameter_bytes));
            layer.* = .{ .activation = activation, .weights_and_biases = weights_and_biases };
            layers_read += 1;
        }
        var normalization: ?zrl.ObsNormalizer = null;
        errdefer {
            if (normalization) |normalizer| {
                gpa.free(normalizer.mean);
                gpa.free(normalizer.m2);
            }
        }
        if (flags.normalizes_observations) {
            const observation_size: usize = header.observation_size;
            const statistics_bytes: usize = mulChecked(usize, observation_size, 2 * @sizeOf(f64)) catch {
                return error.PolicyTruncated;
            };
            if (statistics_bytes > reader.left()) {
                return error.PolicyTruncated;
            }
            // Once both arrays exist they are the normaliser's, and the cleanup above frees them; until then, this one.
            const mean: []f64 = try gpa.alloc(f64, observation_size);
            errdefer if (normalization == null) gpa.free(mean);
            const m2: []f64 = try gpa.alloc(f64, observation_size);
            normalization = .{
                .mean = mean,
                .m2 = m2,
                .count = header.observations_counted,
                .clip = header.observation_clip,
                .epsilon = header.observation_epsilon,
            };
            @memcpy(sliceAsBytes(mean), try reader.take(observation_size * @sizeOf(f64)));
            @memcpy(sliceAsBytes(m2), try reader.take(observation_size * @sizeOf(f64)));
        }
        if (normalization) |normalizer| {
            if (!normalizerIsUsable(normalizer)) {
                return error.PolicyNormalizationInvalid;
            }
        }
        if (reader.left() != 0) {
            return error.PolicyHasTrailingBytes;
        }
        const policy: GenoPolicy = .{
            .widths = widths,
            .layers = layers,
            .normalization = normalization,
            .action_limit = header.action_limit,
            .action_scale = header.action_scale,
            .filter_beta = header.filter_beta,
        };
        return policy;
    }

    /// Whether a normaliser read from a file can normalise: a positive, finite clip and epsilon (the epsilon keeps
    /// every deviation above zero), a finite count, and finite statistics, no sum of squared deviations below zero.
    fn normalizerIsUsable(normalizer: zrl.ObsNormalizer) bool {
        const clip_usable: bool = normalizer.clip > 0 and isFinite(normalizer.clip);
        const epsilon_usable: bool = normalizer.epsilon > 0 and isFinite(normalizer.epsilon);
        if (!clip_usable or !epsilon_usable or !isFinite(normalizer.count)) {
            return false;
        }
        for (normalizer.mean, normalizer.m2) |mean, m2| {
            const statistics_usable: bool = isFinite(mean) and isFinite(m2) and m2 >= 0;
            if (!statistics_usable) {
                return false;
            }
        }
        return true;
    }

    /// A layer's parameter count from a file's untrusted shape, W and b (`PolicyLayer.parameterCount`) - null when it
    /// overflows a `usize`: a damaged file, or a 32-bit machine such as the web's.
    fn layerParameterCount(input_count: u32, output_count: u32) ?usize {
        const matrix: usize = mulChecked(usize, input_count, output_count) catch {
            return null;
        };
        return addChecked(usize, matrix, output_count) catch null;
    }

    /// A policy file's bytes read in order; too few left is a truncated file.
    const Reader = struct {
        bytes: []const u8,
        at: usize = 0,

        /// The bytes not read yet.
        fn left(reader: *const Reader) usize {
            return reader.bytes.len - reader.at;
        }

        fn take(reader: *Reader, count: usize) error{PolicyTruncated}![]const u8 {
            if (reader.left() < count) {
                return error.PolicyTruncated;
            }
            const taken: []const u8 = reader.bytes[reader.at..][0..count];
            reader.at += count;
            return taken;
        }
    };
};

// ---- Showing and judging a policy ----
//
// A show runs a policy on characters of its own and lets a viewer draw them, one physics step at a time. The judge
// (`robot_track.judge`) runs a policy from fixed starts spread over the clip, the same starts every time, to say how
// good it is. Both act through one definition of a decision (`PolicyDecider.decide`), so that a run is judged exactly
// as it is shown.
//
// A decision lasts `decimation` physics steps (DReCon's k = 2: decisions at 30 Hz over Geno's 60 Hz physics). At the
// first physics step of each, every character observes - its simulated state, the reference around its frame, the
// action its controller is applying - and the policy gives its mean action; through the decision's steps the
// controller blends that action into the joints' targets at the policy's filter.
//
// A show counts the way survival analysis counts:
//
//   * EXPOSURE is the time at risk: one unit per character per physics step watched, whatever the character is doing.
//     A character whose episode ends - the reference lost, the clip run out, the cap reached - starts another at once,
//     and its exposure goes on counting, so episodes of every length add up on one clock.
//   * A FAILURE is an event on that clock: a physics step at which the fleet says a character lost the reference.
//
// Their ratio is a rate, failures per step at risk, and its inverse is the policy's mean time to failure:
// `exposure_steps / failure_count` physics steps, or that many timesteps in seconds. Counting this way needs no choice
// of where episodes begin or how long they should last, and a policy that never fails simply has a time to failure
// longer than the show. The judge counts the same way over its fixed starts (`robot_track.Judgement`).

/// What a policy show is started with (`PolicyShow.start`) beyond the policy itself: the run's task, which a policy
/// file does not carry. The policy brings its own action scale, limit and filter.
pub const PolicyShowSettings = struct {
    /// Characters shown side by side, each living its own episodes.
    character_count: usize = 1,
    /// The fleet's random stream: where each episode starts on the clip. The same seed gives the same episodes -
    /// `robot_ppo_track.evaluation_seed` to live what PPO's own evaluation lives.
    seed: u64 = ppo_track.evaluation_seed,
    /// Physics steps a decision is held for.
    decimation: u32 = 2,
    /// Physics steps after which an episode ends even while the character tracks well: a cut, not a failure. The
    /// dance's twenty seconds.
    max_episode_steps: u32 = 1200,
    /// The task the fleet runs (`robot_track.Task`: the servo, the floor, the reward, the failure rule - Geno's is
    /// `robot_geno.tracking_task`), and DReCon's bodies: the ones the policy watches and the joints it nudges.
    task: robot_track.Task = .{},
    bodies: robot_policy.Bodies = .{},
};

/// How a policy of `run` is shown (`PolicyShow`), whichever learner trained it: Geno's task and DReCon's bodies -
/// every learner's run is on them - and the learner's own decision interval; one character, on the evaluation's seed.
pub fn showSettingsFor(run: GenoRun) PolicyShowSettings {
    const settings: PolicyShowSettings = .{
        .decimation = run.learner.decimation(),
        .task = tracking_task,
        .bodies = drecon_bodies,
    };
    return settings;
}

/// How a policy decides for a fleet's characters (`decide`), with the scratch a decision needs: DReCon's choice of
/// bodies - the ones the policy watches, the joints it nudges - and buffers for an observation and the policy's layers.
/// One definition, used by the show and by the judge's actor alike.
pub const PolicyDecider = struct {
    /// The robot's model (the caller's).
    model: *rbt.Model,
    subset: robot_policy.Subset,
    /// The reference now and further ahead, a character's simulated state, the observation itself, the policy's two
    /// layer buffers.
    reference_views: robot_policy.Views,
    simulated_state: robot_track.State,
    observation: []f32,
    scratch: PolicyScratch,

    /// A decider for `policy` on `model` with DReCon's `bodies`, which must give the policy's observation and action
    /// sizes. Memory: everything in `arena`, the caller's.
    pub fn init(
        arena: Allocator,
        model: *rbt.Model,
        body_names: []const []const u8,
        bodies: robot_policy.Bodies,
        policy: *const GenoPolicy,
    ) !PolicyDecider {
        const subset: robot_policy.Subset = try robot_policy.subsetFor(
            arena,
            model,
            body_names,
            bodies.watched,
            bodies.actuated,
        );
        // The policy must fit the task: an observation of the size this subset observes, an action per joint it nudges.
        const observation_size: usize = robot_policy.observationSize(subset);
        const observation_fits: bool = observation_size == policy.observationSize();
        assertf(observation_fits, @src(), "PolicyDecider: observations of {d}, a policy of {d}", .{
            observation_size,
            policy.observationSize(),
        });
        const action_fits: bool = subset.dofs == policy.actionSize();
        assertf(action_fits, @src(), "PolicyDecider: {d} actuated, a policy of {d} actions", .{
            subset.dofs,
            policy.actionSize(),
        });
        const reference_views: robot_policy.Views = try .init(arena, model);
        const simulated_state: robot_track.State = try .init(arena, model.nbody);
        const scratch: PolicyScratch = try .init(arena, policy);
        const decider: PolicyDecider = .{
            .model = model,
            .subset = subset,
            .reference_views = reference_views,
            .simulated_state = simulated_state,
            .observation = try arena.alloc(f32, observation_size),
            .scratch = scratch,
        };
        return decider;
    }

    /// A decision: each of the first `character_count` characters of `fleet` observes - its simulated state, the
    /// reference around its frame, the action `controller` is applying to it - and `policy` gives its mean action for
    /// what it observed, into `actions` (a row of the action's size per character).
    pub fn decide(
        decider: *PolicyDecider,
        policy: *const GenoPolicy,
        controller: *const robot_policy.Controller,
        fleet: *robot_track.Fleet,
        character_count: usize,
        actions: []f32,
    ) void {
        const action_size: usize = decider.subset.dofs;
        for (0..character_count) |character| {
            const character_action: []f32 = actions[character * action_size ..][0..action_size];
            const clip: *const dance.Clip = fleet.clips[fleet.clip_of[character]];
            const action_being_applied: []const f32 = controller.lastAction(character);
            robot_track.stateOf(decider.model, &fleet.data[character], &decider.simulated_state);
            robot_policy.observeFrom(
                decider.model,
                decider.subset,
                fleet,
                clip,
                fleet.frame[character],
                decider.simulated_state,
                &decider.reference_views,
                action_being_applied,
                decider.observation,
            );
            policyMeanAction(policy, decider.observation, decider.scratch, character_action);
        }
    }
};

/// A policy SHOWN, whichever learner made it (`GenoPolicy`; this section's head): characters on a fleet of their own,
/// each decision the policy's mean action through DReCon's filter, one physics step at a time (`step`), counting
/// exposure and failures. It lives what `robot_ppo_track.Trainer.Show` lives for PPO's actor, step for step, with a
/// policy file in place of the trainer - so the lab watches every learner's run one way.
pub const PolicyShow = struct {
    decider: PolicyDecider,
    /// The characters, each tracking the clip on its own floor.
    fleet: *robot_track.Fleet,
    /// Turns a decision into what reaches the joints: the policy's actions scaled, filtered at its `filter_beta`, held
    /// through the decision's physics steps.
    controller: robot_policy.Controller,
    character_count: usize,
    decimation: u32,
    /// The policy's actions, every character's in a row (`character_count` times the action's size), decided at the
    /// first physics step of each decision.
    actions: []f32,
    /// Physics steps left in the current decision; at zero, the next step decides.
    physics_steps_until_decision: u32 = 0,
    /// What the show has lived (this section's head): a unit of exposure per physics step per character, and every
    /// failure - a physics step at which a character lost the reference.
    exposure_steps: u64 = 0,
    failure_count: u32 = 0,

    /// A show of `policy` on `clips` (`PolicyShowSettings`). Memory: everything in `arena`, the caller's, which must
    /// outlive the show; `end` releases what the fleet holds beyond its memory.
    pub fn start(
        arena: Allocator,
        model: *rbt.Model,
        body_names: []const []const u8,
        clips: []const *const dance.Clip,
        policy: *const GenoPolicy,
        settings: PolicyShowSettings,
    ) !PolicyShow {
        const character_count: usize = settings.character_count;
        const decider: PolicyDecider = try .init(arena, model, body_names, settings.bodies, policy);
        const fleet: *robot_track.Fleet = try .init(arena, model, clips, .{
            .envs = character_count,
            .capacity = 16,
            .seed = settings.seed,
            .max_steps = settings.max_episode_steps,
            .action_scale = policy.action_scale,
            .task = settings.task,
            .body_names = body_names,
        });
        errdefer fleet.deinit();
        const controller: robot_policy.Controller = try .init(arena, model, decider.subset, character_count, .{
            .beta = policy.filter_beta,
            .decimation = settings.decimation,
        });
        const actions: []f32 = try arena.alloc(f32, character_count * decider.subset.dofs);
        @memset(actions, 0.0);
        const show: PolicyShow = .{
            .decider = decider,
            .fleet = fleet,
            .controller = controller,
            .character_count = character_count,
            .decimation = settings.decimation,
            .actions = actions,
        };
        return show;
    }

    /// Releases what the fleet holds beyond its memory; the arena the show was started in frees the rest.
    pub fn end(show: *PolicyShow) void {
        show.fleet.deinit();
    }

    /// One physics step (this section's head): at the first step of a decision every character observes and the
    /// policy decides; then the filtered actions step the fleet, and the show counts what the step lived.
    pub fn step(show: *PolicyShow, policy: *const GenoPolicy) void {
        const fleet: *robot_track.Fleet = show.fleet;
        const decides_now: bool = show.physics_steps_until_decision == 0;
        if (decides_now) {
            show.decider.decide(policy, &show.controller, fleet, show.character_count, show.actions);
            show.physics_steps_until_decision = @max(show.decimation, 1);
        }
        // One physics step under the filtered actions.
        const filtered_actions: []const f32 = show.controller.apply(show.actions);
        _ = fleet.step(filtered_actions);
        show.physics_steps_until_decision -= 1;
        // What the step lived: a unit of exposure per character, and its failures. A character whose episode ended
        // starts the next one fresh: its controller forgets the action it was applying.
        for (0..show.character_count) |character| {
            show.exposure_steps += 1;
            if (fleet.failures[character]) {
                show.failure_count += 1;
            }
            if (fleet.dones[character]) {
                show.controller.forget(character);
            }
        }
    }
};

/// The judge's actor for a policy (`robot_track.Actor`, `robot_track.judge`): the policy's mean action for every
/// character of the judge's fleet, decided every `decimation` physics steps and filtered by DReCon's controller -
/// what `PolicyShow` does for a viewer, here for the judge, so that any learner's run is judged as it is shown. The
/// judge steps its fleet every physics step with what this actor gives it; a character it restarts begins fresh, its
/// controller forgetting the action it was applying.
pub const PolicyJudgeActor = struct {
    decider: PolicyDecider,
    controller: robot_policy.Controller,
    policy: *const GenoPolicy,
    character_count: usize,
    decimation: u32,
    /// The policy's actions, a row per character, decided at the first physics step of each decision.
    actions: []f32,
    /// Physics steps left in the current decision; at zero, the next step decides.
    physics_steps_until_decision: u32 = 0,

    /// An actor for `policy` on a judged fleet of `character_count` characters - one per start. Memory: everything in
    /// `arena`, the caller's; the actor must not move once its `actor` has been taken.
    pub fn init(
        arena: Allocator,
        model: *rbt.Model,
        body_names: []const []const u8,
        bodies: robot_policy.Bodies,
        decimation: u32,
        policy: *const GenoPolicy,
        character_count: usize,
    ) !PolicyJudgeActor {
        const decider: PolicyDecider = try .init(arena, model, body_names, bodies, policy);
        const controller: robot_policy.Controller = try .init(arena, model, decider.subset, character_count, .{
            .beta = policy.filter_beta,
            .decimation = decimation,
        });
        const actions: []f32 = try arena.alloc(f32, character_count * decider.subset.dofs);
        @memset(actions, 0.0);
        const judge_actor: PolicyJudgeActor = .{
            .decider = decider,
            .controller = controller,
            .policy = policy,
            .character_count = character_count,
            .decimation = decimation,
            .actions = actions,
        };
        return judge_actor;
    }

    /// The actor as the judge takes it: this one's context, and how it acts.
    pub fn actor(judge_actor: *PolicyJudgeActor) robot_track.Actor {
        return .{ .context = judge_actor, .act = actOnJudgedFleet };
    }

    fn actOnJudgedFleet(
        context: *anyopaque,
        fleet: *robot_track.Fleet,
        fleet_actions: []f32,
    ) void {
        const judge_actor: *PolicyJudgeActor = @ptrCast(@alignCast(context));
        // A character whose episode ended at the last step starts fresh.
        for (0..judge_actor.character_count) |character| {
            if (fleet.dones[character]) {
                judge_actor.controller.forget(character);
            }
        }
        const decides_now: bool = judge_actor.physics_steps_until_decision == 0;
        if (decides_now) {
            const policy: *const GenoPolicy = judge_actor.policy;
            const character_count: usize = judge_actor.character_count;
            judge_actor.decider.decide(policy, &judge_actor.controller, fleet, character_count, judge_actor.actions);
            judge_actor.physics_steps_until_decision = @max(judge_actor.decimation, 1);
        }
        const filtered_actions: []const f32 = judge_actor.controller.apply(judge_actor.actions);
        @memcpy(fleet_actions, filtered_actions);
        judge_actor.physics_steps_until_decision -= 1;
    }
};

/// What a policy is judged on (`judgePolicy`) beyond the policy itself: the starts (frames of the clip - the judge's
/// usual ones are `robot_track.evenStarts`), the physics steps a decision is held for, the task and DReCon's bodies.
pub const PolicyJudgeSettings = struct {
    starts: []const usize,
    decimation: u32 = 2,
    task: robot_track.Task = .{},
    bodies: robot_policy.Bodies = .{},
};

/// `policy` judged on `clip` (`robot_track.judge`: the same fixed starts every time, every start's first episode
/// counted to its end, nothing random) - or, with no policy, the servo alone on the same starts. Memory: the actor in
/// `arena`, the caller's; the judge's own fleet with `gpa`, freed before it returns.
pub fn judgePolicy(
    gpa: Allocator,
    arena: Allocator,
    model: *rbt.Model,
    body_names: []const []const u8,
    clip: *const dance.Clip,
    policy: ?*const GenoPolicy,
    settings: PolicyJudgeSettings,
) !robot_track.Judgement {
    const servo_scale: f32 = 0.0;
    const action_scale: f32 = if (policy) |judged| judged.action_scale else servo_scale;
    const fleet_options: robot_track.Fleet.Options = .{
        .action_scale = action_scale,
        .task = settings.task,
        .body_names = body_names,
    };
    const judged_policy: *const GenoPolicy = policy orelse {
        return robot_track.judge(gpa, model, clip, fleet_options, settings.starts, null);
    };
    const character_count: usize = settings.starts.len;
    var judge_actor: PolicyJudgeActor = try .init(
        arena,
        model,
        body_names,
        settings.bodies,
        settings.decimation,
        judged_policy,
        character_count,
    );
    return robot_track.judge(gpa, model, clip, fleet_options, settings.starts, judge_actor.actor());
}

/// A small policy made by hand for the file's tests: 3 inputs normalised, 4 tanh, 2 out. Its normaliser has counted 10
/// observations, whose deviations are 2, 0.5 and 1.5 (sums of squared deviations 40, 2.5 and 22.5).
fn handMadePolicy(gpa: Allocator) !GenoPolicy {
    const widths: []u32 = try gpa.dupe(u32, &.{ 3, 4, 2 });
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, 2);
    const first_weights: []f32 = try gpa.alloc(f32, 3 * 4 + 4);
    for (first_weights, 0..) |*weight, index| {
        weight.* = 0.1 * float(index) - 0.7;
    }
    const second_weights: []f32 = try gpa.alloc(f32, 4 * 2 + 2);
    for (second_weights, 0..) |*weight, index| {
        weight.* = 0.25 - 0.05 * float(index);
    }
    layers[0] = .{ .activation = .tanh, .weights_and_biases = first_weights };
    layers[1] = .{ .activation = .none, .weights_and_biases = second_weights };
    const means: []f64 = try gpa.dupe(f64, &.{ 0.5, -1.0, 2.0 });
    const squared_deviation_sums: []f64 = try gpa.dupe(f64, &.{ 40.0, 2.5, 22.5 });
    const normalization: zrl.ObsNormalizer = .{ .mean = means, .m2 = squared_deviation_sums, .count = 10, .clip = 5 };
    const policy: GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = normalization,
        .action_limit = 1.0,
        .action_scale = 0.3,
        .filter_beta = 0.2,
    };
    return policy;
}

test "GenoPolicy: its file reads back as itself and acts the same; a file that is no policy is refused by name" {
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadePolicy(gpa);
    defer policy.deinit(gpa);
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    try expectEqualSlices(u32, policy.widths, read_back.widths);
    for (policy.layers, read_back.layers) |written, read| {
        try expectEqual(written.activation, read.activation);
        try expectEqualSlices(f32, written.weights_and_biases, read.weights_and_biases);
    }
    const written_normalizer: zrl.ObsNormalizer = policy.normalization.?;
    const read_normalizer: zrl.ObsNormalizer = read_back.normalization.?;
    try expectEqualSlices(f64, written_normalizer.mean, read_normalizer.mean);
    try expectEqualSlices(f64, written_normalizer.m2, read_normalizer.m2);
    try expectEqual(written_normalizer.count, read_normalizer.count);
    try expectEqual(written_normalizer.clip, read_normalizer.clip);
    try expectEqual(written_normalizer.epsilon, read_normalizer.epsilon);
    try expectEqual(policy.filter_beta, read_back.filter_beta);
    // The same action, bit for bit, from the policy and from its file.
    var ping: [4]f32 = undefined;
    var pong: [4]f32 = undefined;
    const scratch: PolicyScratch = .{ .ping = &ping, .pong = &pong };
    const observation = [3]f32{ 1.25, -0.5, 9.0 };
    var action: [2]f32 = undefined;
    var action_read_back: [2]f32 = undefined;
    policyMeanAction(&policy, &observation, scratch, &action);
    policyMeanAction(&read_back, &observation, scratch, &action_read_back);
    try expectEqualSlices(f32, &action, &action_read_back);
    // Not a policy; cut short; and a file of the first version.
    var not_a_policy: [64]u8 = @splat(0);
    try expectError(error.NotAPolicyFile, PolicyFile.decode(gpa, &not_a_policy));
    try expectError(error.PolicyTruncated, PolicyFile.decode(gpa, bytes[0 .. bytes.len - 1]));
    const first_version: []u8 = try gpa.dupe(u8, bytes);
    defer gpa.free(first_version);
    const version_at: usize = @offsetOf(PolicyFile.Header, "version");
    writeInt(u32, first_version[version_at..][0..4], 1, .little);
    try expectError(error.PolicyVersionUnknown, PolicyFile.decode(gpa, first_version));
}

test "GenoPolicy: a damaged file is refused before it allocates; its flags, length and normaliser checked" {
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadePolicy(gpa);
    defer policy.deinit(gpa);
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    // Where the fields lie, from the layouts themselves.
    const layer_count_at: usize = @offsetOf(PolicyFile.Header, "layer_count");
    const flags_at: usize = @offsetOf(PolicyFile.Header, "flags");
    const observation_size_at: usize = @offsetOf(PolicyFile.Header, "observation_size");
    const clip_at: usize = @offsetOf(PolicyFile.Header, "observation_clip");
    const first_output_at: usize = @sizeOf(PolicyFile.Header) + @offsetOf(PolicyFile.LayerHeader, "output_count");
    const damaged: []u8 = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    // A layer count of four billion: refused as truncated, no allocation tried (the testing allocator would fail).
    @memcpy(damaged, bytes);
    writeInt(u32, damaged[layer_count_at..][0..4], maxInt(u32), .little);
    try expectError(error.PolicyTruncated, PolicyFile.decode(gpa, damaged));
    // A first layer of 65,536 by 65,536: far more parameters than the file holds - refused before allocating.
    @memcpy(damaged, bytes);
    writeInt(u32, damaged[observation_size_at..][0..4], 65_536, .little);
    writeInt(u32, damaged[first_output_at..][0..4], 65_536, .little);
    try expectError(error.PolicyTruncated, PolicyFile.decode(gpa, damaged));
    // No layer; a flag this reader does not know; a byte after the end.
    @memcpy(damaged, bytes);
    writeInt(u32, damaged[layer_count_at..][0..4], 0, .little);
    try expectError(error.PolicyHasNoLayers, PolicyFile.decode(gpa, damaged));
    @memcpy(damaged, bytes);
    writeInt(u32, damaged[flags_at..][0..4], 3, .little);
    try expectError(error.PolicyFlagsUnknown, PolicyFile.decode(gpa, damaged));
    const longer: []u8 = try gpa.alloc(u8, bytes.len + 1);
    defer gpa.free(longer);
    @memcpy(longer[0..bytes.len], bytes);
    longer[bytes.len] = 0;
    try expectError(error.PolicyHasTrailingBytes, PolicyFile.decode(gpa, longer));
    // A normaliser that cannot be: a sum of squared deviations below zero (the last eight bytes), a clip of zero.
    @memcpy(damaged, bytes);
    writeInt(u64, damaged[damaged.len - 8 ..][0..8], @bitCast(@as(f64, -1.0)), .little);
    try expectError(error.PolicyNormalizationInvalid, PolicyFile.decode(gpa, damaged));
    @memcpy(damaged, bytes);
    writeInt(u64, damaged[clip_at..][0..8], @bitCast(@as(f64, 0.0)), .little);
    try expectError(error.PolicyNormalizationInvalid, PolicyFile.decode(gpa, damaged));
}

test "GenoPolicy: an action past its limit is held at it; an input past its clip is held at its deviations" {
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadePolicy(gpa);
    defer policy.deinit(gpa);
    // The last layer made to give 3 and -3 whatever its inputs: weights zero, biases 3 and -3.
    const last: PolicyLayer = policy.layers[1];
    const biases_start: usize = policy.widths[1] * policy.widths[2];
    @memset(last.weights_and_biases, 0);
    last.weights_and_biases[biases_start] = 3.0;
    last.weights_and_biases[biases_start + 1] = -3.0;
    var ping: [4]f32 = undefined;
    var pong: [4]f32 = undefined;
    const scratch: PolicyScratch = .{ .ping = &ping, .pong = &pong };
    var action: [2]f32 = undefined;
    policyMeanAction(&policy, &.{ 0.0, 0.0, 0.0 }, scratch, &action);
    try expectEqualSlices(f32, &.{ 1.0, -1.0 }, &action);
    // An input 100 deviations from its mean is held at 5, as one 6 deviations away is: the same action.
    policy.layers[1].weights_and_biases[0] = 1.0;
    var far_action: [2]f32 = undefined;
    var near_action: [2]f32 = undefined;
    policyMeanAction(&policy, &.{ 0.5 + 100.0 * 2.0, -1.0, 2.0 }, scratch, &far_action);
    policyMeanAction(&policy, &.{ 0.5 + 6.0 * 2.0, -1.0, 2.0 }, scratch, &near_action);
    try expectEqualSlices(f32, &near_action, &far_action);
}
