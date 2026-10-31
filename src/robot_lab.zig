//! robot_lab - the training lab's shared ground: what the trainer, the lab and the pages agree on about a training
//! run of Geno on the dance. In order, each part followed by its tests: the learners' recipes (`SuperTrackRecipe` and
//! its plan's values, `supertrack_recipe`; `PpoRecipe`, and `PpoRun`, the parameters the trainer's PPO path takes); a
//! run's parameters (`GenoRun` - the task every learner shares, the learner with its recipe, the run's controls); the
//! run folder's files (their names, `RunFile`; how its trainer ended,
//! `TrainerExit`; its state as a person or the lab reads it, `RunState`, `RunStatus`; its log and its curves,
//! `RunLog`, `RunCurve`); and the policy a run deploys, whichever learner made it, with its file (`GenoPolicy`,
//! `policyMeanAction`, `PolicyFile`). Geno's body - its model, its bodies, its scales - is `robot_geno`'s; this file
//! builds on it, and nothing in it imports this file.

const std = @import("std");
const zm = @import("zm");
const isFinite = zm.isFinite;
const tanh = zm.tanh;
const mish = zm.mish;
const clamp = zm.clamp;
const assertf = zm.assertf;
const assertUnreachable = zm.assertUnreachable;
const builtin = @import("builtin");
const zrl = @import("zrl");
const zn = @import("zn");
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
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const expectEqualDeep = std.testing.expectEqualDeep;
const startsWith = std.mem.startsWith;
const splitScalar = std.mem.splitScalar;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const parseFloat = std.fmt.parseFloat;
const parseInt = std.fmt.parseInt;
const float = zm.float;
const nan = zm.nan;
const inf = zm.inf;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const writeInt = std.mem.writeInt;
const geno = @import("robot_geno.zig");
const resident = @import("robot_track_resident.zig");
const latent_kit = @import("robot_latent_kit.zig");
const robot_bmpc = @import("robot_bmpc.zig");
const GenoTask = geno.GenoTask;
const student_scale = geno.student_scale;
const supertrack_action_scale = geno.supertrack_action_scale;
const tracking_task = geno.tracking_task;
const drecon_bodies = geno.drecon_bodies;

/// SuperTrack's RECIPE on Geno: every setting the bench, the pages and the trainer train with that is not the TASK
/// (that's `tracking_task`) and not a run's sizes. One value, handed over whole and never rebuilt field by field at a
/// call site - settings rebuilt field by field at each call site drift apart. An
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
    /// recipe: the bench picks them for the CPU, and a run's own file for a desktop GPU.
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
    //   * the clock and the filter are DReCon's (the same filter and clock wherever a policy acts), so they must
    //     agree with `robot_policy.Controller`'s own defaults;
    //   * seeing the applied action is what makes a filter's state visible, so a filtered recipe must see it;
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

/// The motions a run on Geno can train. `getup` and `dance` are both the baked dance clip, getting up from the floor
/// first or not. The others are SEVERAL clips at once, each character keeping one of them
/// (`robot_track.ClipAssignment`): `dance_and_getup` the dance and LAFAN1's whole fall and get-up take (18 s of
/// standing, falling, lying and getting up again); `one_minute` those two, 11 s of walking and 11 s of running - sixty
/// seconds of motion. Several clips are SuperTrack's: PPO and EfficientTDMPC train one, and a run asking them for
/// more is refused by name.
pub const GenoMotion = enum {
    getup,
    dance,
    dance_and_getup,
    one_minute,

    /// The motion's name in files and on screen.
    pub fn label(motion: GenoMotion) []const u8 {
        return switch (motion) {
            .getup => "get-up",
            .dance => "dance",
            .dance_and_getup => "dance and get-up",
            .one_minute => "minute",
        };
    }

    /// The motion's clips, as every judgement and probe line names them - in the order the trainer holds Geno's
    /// clips (the dance, the get-up, walking, running), so a motion's clips are the first of them. One label: one
    /// clip.
    pub fn clipLabels(motion: GenoMotion) []const []const u8 {
        return switch (motion) {
            .getup => &.{"get-up"},
            .dance => &.{"dance"},
            .dance_and_getup => &.{ "dance", "get-up" },
            .one_minute => &.{ "dance", "get-up", "walk", "run" },
        };
    }

    /// What the motion's networks are trained for, carried in their weights file (`ppo_track.Options.tag`): a file
    /// for another motion is refused. The two one-clip motions share the dance clip, and so one tag.
    pub fn tag(motion: GenoMotion) u32 {
        return switch (motion) {
            .getup, .dance => 3,
            .dance_and_getup => 4,
            .one_minute => 5,
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
    pub fn options(recipe: PpoRecipe, motion: GenoMotion) ppo_track.Options {
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
    motion: GenoMotion = .dance,
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
    motion: GenoMotion = .dance,
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
// recipe's: checked when the file compiles. The copy between them is a loop over the fields (`PpoLearner.recipe`);
// without this check, a field added to `PpoRecipe` and forgotten in `PpoLearner` would compile, and a run would
// quietly train with its default.
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
    /// Characters simulated side by side while collecting, each living its own episodes: the fleet's size. Four is
    /// sized for a phone: Geno's physics step costs about 0.6 ms there, and a round of eight characters (16 collected
    /// steps each) overran the page's frame budget before the GPU had done anything. A desktop trainer can afford more.
    characters: u32 = 4,
    /// Simulation steps each character's replay keeps: what windows are drawn from. The training page's 256.
    replay_steps: u32 = 256,
    /// Windows per update, the world model's window, and the policy's horizon (0: the world model's window) - as the
    /// learner's own options say (`resident.Options`).
    rows: u32 = 16,
    window: u32 = 8,
    policy_window: u32 = 0,
    /// The share of the policy's windows drawn inside returns when the fleet has returns
    /// (`robot_track_resident.Options.return_window_share`).
    return_window_share: f32 = 0.25,
    /// The time-to-return cost's cap far from the reference (`robot_track_resident.Options.return_cost_cap`).
    return_cost_cap: f32 = 0,
    /// The world model's width, and the policy's.
    hidden: u32 = 64,
    policy_hidden: u32 = 64,
    /// The two networks' step sizes.
    world_rate: f32 = (resident.Options{}).world_rate,
    policy_rate: f32 = (resident.Options{}).policy_rate,
    /// The policy's optimiser: its gradient's length bound, each number's bound, Adam's second-moment decay - as the
    /// learner's own options say (`resident.Options.policy_gradient_clip`).
    policy_gradient_clip: f32 = (resident.Options{}).policy_gradient_clip,
    /// The world model's gradient bound (`robot_track_resident.Options.world_gradient_clip`).
    world_gradient_clip: f32 = (resident.Options{}).world_gradient_clip,
    /// The skip model's span (`robot_track_resident.Options.skip_span`): 0 for none.
    skip_span: u32 = (resident.Options{}).skip_span,
    /// The world model's change in units of the typical change (`robot_track_resident.Options.increment_spread_floor`):
    /// 0 for off.
    increment_spread_floor: f32 = (resident.Options{}).increment_spread_floor,
    policy_element_clip: f32 = (resident.Options{}).policy_element_clip,
    policy_beta2: f32 = (resident.Options{}).policy_beta2,
    /// The rates' schedule: a cosine over this many updates down to a floor share (0: constant rates) - as the
    /// learner's own options say (`resident.Options.rate_decay_updates`).
    rate_decay_updates: u32 = (resident.Options{}).rate_decay_updates,
    /// The rates' schedule in training hours, over the updates' when above 0
    /// (`robot_track_resident.Options.rate_decay_hours`).
    rate_decay_hours: f32 = (resident.Options{}).rate_decay_hours,
    rate_floor_share: f32 = (resident.Options{}).rate_floor_share,
    /// Exploration noise, in units of the policy's raw output: in the simulator while collecting, and inside every
    /// training rollout through the world model.
    sigma: f32 = (resident.Options{}).sigma,
    /// The price on the raw action's size, and the smoothness price along a window (CAPS): without it the policy's
    /// actions jump by most of their size from one step to the next.
    w_action: f32 = (resident.Options{}).w_action,
    w_smooth: f32 = 1.0,
    /// The failure barrier in the policy's loss (`robot_latent_kit.FailureBarrier`): off - weight 0 - by default; a
    /// run that is to learn recovery gives it a weight, so the policy feels the failure rule's cliff before the fall.
    barrier: @FieldType(resident.Options, "barrier") = .{},
    /// Whether SuperTrack's critic trains, and its settings (`robot_latent_kit.LatentCritic`): off by default.
    train_critic: bool = false,
    critic: @FieldType(resident.Options, "critic") = .{},
    /// The value tail in SuperTrack's policy loss, at its full weight, and the policy updates it ramps up over (it
    /// needs the critic): off - 0 - by default.
    value_tail: f32 = 0,
    value_tail_ramp_updates: u32 = 1000,
    /// The tail's pessimism (beta): the critic's heads' mean plus beta of their spread. 0 reads the plain mean.
    value_tail_pessimism: f32 = 0,
    /// Which policy acts - the Gaussian one, or a flow policy learning through FlowDPG and acting with each
    /// character's drifting noise (`robot_latent_kit.PolicyActor`, `FlowSettings`).
    actor: @FieldType(resident.Options, "actor") = .gaussian,
    flow: @FieldType(resident.Options, "flow") = .{},
    /// Planning for characters in danger (`robot_track_resident.PlanningSettings`); off unless enabled.
    planning: @FieldType(resident.Options, "planning") = .{},
    /// Pushes from outside while collecting (`robot_track.Pushes`): none by default; a run that is to learn recovery
    /// sets a rate and a range of speeds.
    pushes: robot_track.Pushes = .{},
    /// Where new episodes start along each clip (`robot_track.ResetCurriculum`): uniform unless a curriculum's bins are
    /// given - then toward the stretches failing most, and by their long-run weights.
    curriculum: robot_track.ResetCurriculum = .{},
    /// The physics' tasks (`robot_track.Fleet.Options.physics_threads`): the characters' physics steps split over this
    /// many threads, every core with 0 - the run's numbers the same whatever it is.
    physics_threads: u32 = 0,
    /// Physics steps a character lives on after losing its reference, and the share of the fleet's characters that
    /// do (`robot_track.Fleet.Options.aftermath_steps`, `aftermath_share`): none by default, so every loss resets, as
    /// SuperTrack trains. With an aftermath the world model learns falls and what follows them, and the policy still
    /// learns only from windows that start before a loss.
    aftermath_steps: u32 = 0,
    aftermath_share: f32 = 1.0,
    /// Steps in a row holding the reference again for a character in its aftermath to have returned, its episode going
    /// on (`robot_track.Fleet.Options.return_steps`): 0, no returns - every aftermath ends its episode.
    return_steps: u32 = 0,
    /// One round: this many simulation steps, then this many updates of each network.
    collect: u32 = 16,
    world_updates: u32 = 1,
    policy_updates: u32 = 1,
    seed: u64 = (resident.Options{}).seed,

    /// The GPU learner's options: every field but the fleet's (the action scale, the characters, the replay's length),
    /// copied by one loop.
    pub fn options(learner: SuperTrackLearner) resident.Options {
        var learner_options: resident.Options = .{};
        inline for (@typeInfo(resident.Options).@"struct".field_names) |field_name| {
            @field(learner_options, field_name) = @field(learner, field_name);
        }
        return learner_options;
    }
};

/// The task a SuperTrack learner trains on (`robot_track.Task`): Geno's (`robot_geno.tracking_task`: its servo, its
/// floor, its reward and its failure rule) with one change the learner needs - a training window's grace after every
/// reset. Every episode then yields at least one whole window however bad the policy: without it, a policy that fails
/// within a window's length leaves no window to train on, and training stops for good. The judge does not use it: a
/// learner is judged on Geno's task itself.
pub fn superTrackTrainingTask(learner: SuperTrackLearner) robot_track.Task {
    var graced_task: robot_track.Task = tracking_task;
    // A whole window of the policy's horizon - the length the learner draws.
    graced_task.termination.grace_steps = learner.options().horizon();
    return graced_task;
}

// Every option of the GPU learner is a field of `SuperTrackLearner`, with the same type, and every field of the learner
// but the fleet's (the action scale, the characters, the replay's length, the pushes, the aftermath) is an option:
// checked when the file compiles, so that an option added to the learner reaches the run file, and a run file never
// holds a setting nothing reads.
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
        const is_fleets: bool = eql(u8, field_name, "action_scale") or eql(u8, field_name, "characters") or
            eql(u8, field_name, "replay_steps") or eql(u8, field_name, "pushes") or
            eql(u8, field_name, "aftermath_steps") or eql(u8, field_name, "aftermath_share") or
            eql(u8, field_name, "return_steps") or
            eql(u8, field_name, "curriculum") or eql(u8, field_name, "physics_threads");
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

/// The agent an EfficientTDMPC run trains on Geno: f32 throughout, as its GPU form computes.
pub const TdmpcAgent = robot_bmpc.Bmpc(f32);

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
    /// model is unsure of is scored down, so the policy learns to stay where the model is right - worth it where the
    /// agent can fail early, as by a fall on the dance (the preset's value there: 10).
    pessimism: ?f32 = null,
    /// Adam's step size, for every network.
    learning_rate: ?f32 = null,
    /// Windows of stored steps each update learns from: the batch, drawn from the replay of everything collected.
    windows: ?u32 = null,
    seed: u64 = 1,
    /// The characters trained side by side, each its own environment (`robot_bmpc_dance.TrackCharacter`).
    characters: u32 = 8,
    /// Physics steps a character lives on after losing the reference before its episode is cut: its fall, rewarded
    /// as the task rewards it, is how the agent learns what losing the reference is worth - it models no termination
    /// (`robot_bmpc.Bmpc(T).EpisodeEnding.terminated`). One second.
    aftermath_steps: u32 = 60,
    /// Physics steps an episode lasts at most - ten seconds, so 300 decisions at DReCon's interval: the agent's
    /// discount comes from that length (`TdmpcLearner.episodeDecisions`, `robot_bmpc.Bmpc(T).discountFor`).
    max_episode_steps: u32 = 600,
    /// Decisions each character's replay keeps: BMPC keeps a million steps of its one environment; eight characters
    /// keep a hundred thousand each.
    replay_steps: u32 = 100_000,
    /// Updates per decision of each character: BMPC's and EfficientTDMPC's one.
    update_to_data: u32 = 1,

    /// The decisions an episode lasts at most: its physics steps over the interval a decision is held for.
    pub fn episodeDecisions(learner: TdmpcLearner) u32 {
        const held_steps: u32 = @max(learner.decimation, 1);
        return learner.max_episode_steps / held_steps;
    }

    /// The agent's whole configuration: the preset's (`TdmpcAgent.Config.efficientTdmpc` with episodes that can end
    /// early - a fall cuts one - or `.bmpc`), its discount from the episode's length, and every setting the run names
    /// in place of the preset's.
    pub fn agentConfig(learner: TdmpcLearner) TdmpcAgent.Config {
        const episode_decisions: usize = learner.episodeDecisions();
        const episodes_can_end_early: bool = true;
        var config: TdmpcAgent.Config = switch (learner.preset) {
            .efficient_tdmpc => .efficientTdmpc(episode_decisions, episodes_can_end_early),
            .bmpc => .bmpc(episode_decisions),
        };
        if (learner.latent_width) |latent_width| {
            config.latent_width = latent_width;
        }
        if (learner.hidden_width) |hidden_width| {
            config.hidden_width = hidden_width;
        }
        if (learner.dynamics_heads) |dynamics_heads| {
            config.dynamics_heads = dynamics_heads;
        }
        if (learner.acting_horizon) |acting_horizon| {
            config.acting.horizon = acting_horizon;
        }
        if (learner.reanalyze_horizon) |reanalyze_horizon| {
            config.reanalyzing.horizon = reanalyze_horizon;
        }
        if (learner.pessimism) |pessimism| {
            config.reanalyzing.pessimism = pessimism;
        }
        if (learner.learning_rate) |learning_rate| {
            config.learning_rate = learning_rate;
        }
        if (learner.windows) |windows| {
            config.windows = windows;
        }
        return config;
    }

    /// The agent's schedule: BMPC's - five episodes of random actions in every character (at least 1000 decisions),
    /// a burst of that many updates, then `update_to_data` updates per character after every decision.
    pub fn schedule(learner: TdmpcLearner) TdmpcAgent.Schedule {
        return .bmpc(learner.characters, learner.episodeDecisions(), learner.update_to_data);
    }
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
        learner.characters,
    };
    const count_problems = [_][]const u8{
        prefix ++ "rows: at least 1 window",
        prefix ++ "window: at least 1 step",
        prefix ++ "hidden: at least 1 unit",
        prefix ++ "policy_hidden: at least 1 unit",
        prefix ++ "collect: at least 1 step",
        prefix ++ "world_updates: at least 1",
        prefix ++ "policy_updates: at least 1",
        prefix ++ "characters: at least 1",
    };
    for (counts, count_problems) |count, count_problem| {
        if (count == 0) {
            return count_problem;
        }
    }
    // A window is drawn from one character's replay, so the replay must hold more than a window.
    if (learner.replay_steps <= learner.window) {
        return prefix ++ "replay_steps: more than window";
    }
    // The skip head learns from the world model's windows: a jump must fit in one, and span more than one step.
    if (learner.skip_span > learner.window) {
        return prefix ++ "skip_span: at most window";
    }
    if (learner.skip_span == 1) {
        return prefix ++ "skip_span: 0 for none, or at least 2 - one step is the world model's own";
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
/// `GenoRun`): a positive, finite action scale; each setting the run names - the ones it leaves null are the preset's
/// own - in its range: at least one unit, head, decision and window, pessimism of zero or more, a positive and finite
/// step size; and the run's fleet: a character, an episode of at least one decision, a replay that holds one, an
/// update per decision, and an aftermath at least as long as the acting planner looks ahead - so that wherever a plan
/// from a falling character reaches, the model has seen where a fall leads.
fn tdmpcProblem(comptime prefix: []const u8, learner: TdmpcLearner) ?[]const u8 {
    const is_action_scale_usable: bool = learner.action_scale > 0 and isFinite(learner.action_scale);
    if (!is_action_scale_usable) {
        return prefix ++ "action_scale: above 0";
    }
    const fleet_counts = [_]u32{ learner.characters, learner.episodeDecisions(), learner.update_to_data };
    const fleet_count_problems = [_][]const u8{
        prefix ++ "characters: at least 1",
        prefix ++ "max_episode_steps: at least one decision (decimation steps)",
        prefix ++ "update_to_data: at least 1",
    };
    for (fleet_counts, fleet_count_problems) |count, count_problem| {
        if (count == 0) {
            return count_problem;
        }
    }
    if (learner.replay_steps < learner.episodeDecisions()) {
        return prefix ++ "replay_steps: at least one episode's decisions (max_episode_steps / decimation)";
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
    // The aftermath against the acting planner's reach, in physics steps: the planner of the run's own preset, or the
    // horizon the run names.
    const acting_horizon: usize = learner.agentConfig().acting.horizon;
    const held_steps: usize = @max(learner.decimation, 1);
    const acting_reach_steps: usize = acting_horizon * held_steps;
    if (learner.aftermath_steps < acting_reach_steps) {
        return prefix ++ "aftermath_steps: at least the acting planner's reach (acting horizon x decimation)";
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

    /// One line on what the learner is, for a reader choosing between them (the lab's new-run form).
    pub fn summary(learner: GenoLearner) []const u8 {
        return switch (learner) {
            .ppo => "PPO: on-policy, DReCon's observation, a decision every 2 steps through DReCon's filter",
            .supertrack => "SuperTrack: a world model learned from replay, the policy trained through it, every step",
            .efficient_tdmpc => "EfficientTDMPC: a latent world model and a planner (not in the trainer yet)",
        };
    }

    /// Whether `tools/geno_trainer` trains this learner yet: PPO and SuperTrack; EfficientTDMPC joins later (phase B).
    pub fn isTrainable(learner: GenoLearner) bool {
        return switch (learner) {
            .ppo, .supertrack => true,
            .efficient_tdmpc => false,
        };
    }

    /// What one line of the learner's training log counts: PPO's batches, SuperTrack's rounds, EfficientTDMPC's
    /// updates.
    pub fn unitName(learner: GenoLearner) []const u8 {
        return switch (learner) {
            .ppo => "batch",
            .supertrack => "round",
            .efficient_tdmpc => "update",
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
    /// How every judgement's recovery probe pushes and watches (`robot_track.RecoveryProbe`, `recovery.csv`): pushes
    /// of 1 to 5 m/s, and a character that loses the reference followed five seconds for a return to it.
    probe: robot_track.RecoveryProbe = .{ .speeds = &.{ 1, 2, 3, 4, 5 }, .return_seconds = 5 },
};

/// A training run on Geno, as its folder's `run.zon` writes it - learner-neutral (the plan's L1): the task every
/// learner shares, the learner with its recipe, the run's controls. Every field defaulted, so an empty `.{}` is PPO
/// on the dance.
pub const GenoRun = struct {
    task: GenoRunTask = .{},
    learner: GenoLearner = .{ .ppo = .{} },
    controls: GenoControls = .{},

    pub const ParseFailure = PpoRun.ParseFailure;

    /// What makes this run impossible to train, naming the field by its path in the run file and the range it must be
    /// in - or null when it can be trained: the learner's own settings, its decision and filter among them, then the
    /// controls. One definition of each check, shared with `PpoRun`, which names the same fields by its own paths.
    pub fn problem(run: GenoRun) ?[]const u8 {
        const controls: GenoControls = run.controls;
        // A planning decision is made once a round, at its end (`robot_track_resident.Resident.act`), and its plans
        // are acted on through the next round: plans shorter than a round leave the rest of it unplanned.
        if (run.learner == .supertrack) {
            const settings: SuperTrackLearner = run.learner.supertrack;
            const plans_cover_round: bool = settings.planning.horizon >= settings.collect;
            if (settings.planning.enabled and !plans_cover_round) {
                return "learner.planning.horizon: shorter than a round (collect) - plans would cover only its start";
            }
            // A plan's knots must end on its last step: its fine steps, then a knot every span steps.
            const planning: resident.PlanningSettings = settings.planning;
            if (planning.enabled and !planning.knotsFit()) {
                return "learner.planning.fine_steps, knot_span: the knots do not end on the plan's last step - " ++
                    "(horizon - fine steps) must divide by the span";
            }
            // Windows inside returns carry a body's large distances from its reference, and large gradients with
            // them: a run whose policy learns from returns bounds its gradient's length.
            const policy_learns_from_returns: bool = settings.return_steps > 0 and settings.return_window_share > 0;
            if (policy_learns_from_returns and settings.policy_gradient_clip <= 0) {
                return "learner.policy_gradient_clip: above 0 when the policy learns from returns (return_steps)";
            }
        }
        // Two clips at once are SuperTrack's.
        const is_supertrack: bool = run.learner == .supertrack;
        const has_several_clips: bool = run.task.motion.clipLabels().len > 1;
        if (has_several_clips and !is_supertrack) {
            return "task.motion: several clips at once, which only SuperTrack's learner trains";
        }
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

    /// A run from `run.zon`'s text: the fields it names, every other field its default. A field the run does not
    /// have, a value of the wrong kind, or text that is not ZON fails, with the parser's description of where and why
    /// (`failure`, in `arena`). Memory: two allocators, as the ZON parser takes them - `gpa` its working memory, freed
    /// before it returns; `arena` the description of a failure, which lives as long as the caller's arena. The run
    /// returned is plain values, pointing into neither.
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
            if (err == error.ParseZon) {
                const described: std.zon.parse.Diagnostics.Formatter = diagnostics.fmt("run.zon");
                failure.description = allocPrint(arena, "{f}", .{described}) catch "unreadable";
            }
            return err;
        };
        return parsed;
    }

    /// The run as a `PpoRun` - the parameters the trainer's PPO path takes - or null when its learner is not PPO.
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
    try expectEqual(GenoMotion.dance, empty.task.motion);
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

test "GenoRun: a misspelt field is refused by name; a file in another layout is refused, not converted" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    const misspelt: [:0]const u8 = ".{ .learnr = .{ .ppo = .{} } }";
    try expectError(error.ParseZon, GenoRun.parse(testing_allocator, arena, misspelt, &failure));
    try expect(indexOf(u8, failure.description, "learnr") != null);
    // A file in PPO's own layout - a motion and a recipe at the top - is no `GenoRun`.
    const other_layout: [:0]const u8 = ".{ .motion = .getup, .recipe = .{ .envs = 16 } }";
    try expectError(error.ParseZon, GenoRun.parse(testing_allocator, arena, other_layout, &failure));
    try expect(indexOf(u8, failure.description, "motion") != null);
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
        .{ .learner = .{ .efficient_tdmpc = .{ .characters = 0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .max_episode_steps = 1 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .update_to_data = 0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .replay_steps = 299 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .aftermath_steps = 11 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .acting_horizon = 40 } } },
        .{ .controls = .{ .save_minutes = 0 } },
    };
    const named = [_][]const u8{
        "learner.ppo.beta: above 0, at most 1",
        "learner.ppo.envs: at least 1 character",
        "learner.supertrack.rows: at least 1 window",
        "learner.efficient_tdmpc.dynamics_heads: at least 1 head",
        "learner.efficient_tdmpc.pessimism: 0 or more",
        "learner.efficient_tdmpc.characters: at least 1",
        "learner.efficient_tdmpc.max_episode_steps: at least one decision (decimation steps)",
        "learner.efficient_tdmpc.update_to_data: at least 1",
        "learner.efficient_tdmpc.replay_steps: at least one episode's decisions (max_episode_steps / decimation)",
        // EfficientTDMPC's acting planner looks 6 decisions ahead, 12 physics steps at DReCon's interval: an
        // aftermath of 11 falls short, and a planner looking 40 decisions ahead needs 80 - more than the default 60.
        "learner.efficient_tdmpc.aftermath_steps: at least the acting planner's reach (acting horizon x decimation)",
        "learner.efficient_tdmpc.aftermath_steps: at least the acting planner's reach (acting horizon x decimation)",
        "controls.save_minutes: above 0",
    };
    for (out_of_range, named) |run, expected| {
        try expect(eql(u8, expected, run.problem().?));
    }
    // At the edge, exactly the planner's reach is enough, and one episode's decisions of replay.
    const edge_learner: TdmpcLearner = .{ .aftermath_steps = 12, .replay_steps = 300 };
    const at_the_edges: GenoRun = .{ .learner = .{ .efficient_tdmpc = edge_learner } };
    try expectEqual(@as(?[]const u8, null), at_the_edges.problem());
    // The older format names the same checks by its own paths.
    const older: PpoRun = .{ .recipe = .{ .beta = 0 } };
    try expect(eql(u8, "recipe.beta: above 0, at most 1", older.problem().?));
}

test "TdmpcLearner: the agent's configuration is the preset's, with the run's settings in place of its own" {
    // EfficientTDMPC's preset on the dance: four dynamics heads, the acting planner six decisions ahead scoring by
    // the mean over its prefixes, pessimism 10 in reanalyze (a fall can cut an episode early), and the discount
    // of an episode of 300 decisions (600 physics steps held 2 each) - BMPC's rule, 0.983.
    const defaults: TdmpcLearner = .{};
    try expectEqual(@as(u32, 300), defaults.episodeDecisions());
    const efficient: TdmpcAgent.Config = defaults.agentConfig();
    try expectEqual(@as(usize, 4), efficient.dynamics_heads);
    try expectEqual(@as(usize, 6), efficient.acting.horizon);
    try expectEqual(zrl.PlanObjective.mean_over_depths, efficient.acting.objective);
    try expectEqual(@as(f32, 10), efficient.reanalyzing.pessimism);
    try expectEqual(TdmpcAgent.discountFor(300), efficient.discount);
    // BMPC's preset beneath it: one head, three decisions ahead, no pessimism.
    const bmpc_learner: TdmpcLearner = .{ .preset = .bmpc };
    const bmpc: TdmpcAgent.Config = bmpc_learner.agentConfig();
    try expectEqual(@as(usize, 1), bmpc.dynamics_heads);
    try expectEqual(@as(usize, 3), bmpc.acting.horizon);
    try expectEqual(@as(f32, 0), bmpc.reanalyzing.pessimism);
    // Every setting a run names replaces the preset's, and nothing else moves.
    const changed: TdmpcLearner = .{
        .latent_width = 32,
        .hidden_width = 48,
        .dynamics_heads = 2,
        .acting_horizon = 4,
        .reanalyze_horizon = 2,
        .pessimism = 2.5,
        .learning_rate = 1e-3,
        .windows = 64,
    };
    const overridden: TdmpcAgent.Config = changed.agentConfig();
    try expectEqual(@as(usize, 32), overridden.latent_width);
    try expectEqual(@as(usize, 48), overridden.hidden_width);
    try expectEqual(@as(usize, 2), overridden.dynamics_heads);
    try expectEqual(@as(usize, 4), overridden.acting.horizon);
    try expectEqual(@as(usize, 2), overridden.reanalyzing.horizon);
    try expectEqual(@as(f32, 2.5), overridden.reanalyzing.pessimism);
    try expectEqual(@as(f32, 1e-3), overridden.learning_rate);
    try expectEqual(@as(usize, 64), overridden.windows);
    try expectEqual(efficient.acting.candidates, overridden.acting.candidates);
    try expectEqual(efficient.encoder_hidden_width, overridden.encoder_hidden_width);
    // BMPC's schedule for eight characters: five episodes of seeding (1500 decisions), a burst of 1500 x 8 updates,
    // then eight updates after every decision.
    const schedule: TdmpcAgent.Schedule = defaults.schedule();
    try expectEqual(@as(usize, 1500), schedule.seed_frames);
    try expectEqual(@as(usize, 12_000), schedule.burst_updates);
    try expectEqual(@as(usize, 8), schedule.updates_per_frame);
}

test "GenoRun: a PPO run as the trainer's PpoRun keeps every value; another learner's run has none" {
    const ppo_run: GenoRun = .{
        .task = .{ .motion = .getup },
        .learner = .{ .ppo = .{ .envs = 32, .gamma = 0.98, .beta = 0.3, .decimation = 3 } },
        .controls = .{ .save_minutes = 4, .judge_minutes = 7, .stop_after_updates = 900 },
    };
    const as_ppo_run: PpoRun = ppo_run.toPpoRun().?;
    try expectEqual(GenoMotion.getup, as_ppo_run.motion);
    try expectEqual(@as(u32, 32), as_ppo_run.recipe.envs);
    try expectEqual(@as(f32, 0.98), as_ppo_run.recipe.gamma);
    try expectEqual(@as(f32, 0.3), as_ppo_run.recipe.beta);
    try expectEqual(@as(u32, 3), as_ppo_run.recipe.decimation);
    try expectEqual(@as(f32, 4), as_ppo_run.save_minutes);
    try expectEqual(@as(f32, 7), as_ppo_run.judge_minutes);
    try expectEqual(@as(u64, 900), as_ppo_run.stop_after_batches);
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
    try expectEqual(GenoMotion.dance, run.motion);
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
    try expectEqual(GenoMotion.getup, partial.motion);
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
    /// One line per band of every recovery probe of the newest policy, after the servo's (`RecoveryLog`).
    recoveries,
    /// A SuperTrack run's whole learner (`robot_track_resident.Resident.exportState`), rewritten whole with the policy.
    supertrack_state,

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
            .recoveries => "recovery.csv",
            .supertrack_state => "supertrack_state",
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

    /// What every SuperTrack state checkpoint's name starts with.
    pub const state_checkpoint_prefix: []const u8 = "supertrack_state_m";

    /// A SuperTrack state checkpoint's name: the learner's whole state after `minute` minutes of training,
    /// `supertrack_state_m<minute>` with five digits, as `policyCheckpointName` names a policy's - what a run goes
    /// back to when the policy files cannot hold its policy (a flow's) or the newest state is not the one wanted.
    pub fn stateCheckpointName(minute: u64, buffer: *NameBuffer) []const u8 {
        const name_format: []const u8 = state_checkpoint_prefix ++ "{d:0>5}";
        return bufPrint(buffer, name_format, .{minute}) catch panicf(@src(), "a state checkpoint name too long", .{});
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
    /// A weight or a device number stopped being finite (`RunStatus.nonfinite` names which): the run stopped before
    /// saving it, its last saved state and checkpoints from before kept.
    failed_nonfinite,
};

/// What a run's `status.zon` holds: enough for a person, or a program watching the run, to know where it is without
/// reading the log. Times to failure in seconds; null when nothing has failed yet. Written by the trainer, read by the
/// training lab.
/// One clip's line in a run's status (`RunStatus.clips`): its label, and its characters' recent time to failure -
/// null while nothing on it failed in the recent rounds.
pub const ClipStatus = struct {
    clip: []const u8,
    recent_seconds_to_failure: ?f32,
};

pub const RunStatus = struct {
    state: RunState,
    batches: u64,
    steps: u64,
    training_minutes: f32,
    servo_seconds_to_failure: ?f32,
    recent_seconds_to_failure: ?f32,
    assist: f32,
    /// Each clip's own recent time to failure, when the run trains several - a run on the dance and the get-up must
    /// not let the one's numbers hide the other's. Empty for a run of one clip, whose `recent_seconds_to_failure` is
    /// its clip's.
    clips: []const ClipStatus = &.{},
    /// A SuperTrack run's newest numbers a person checks first (0 for a PPO run): the world model's loss, the critic's
    /// error, the policy's gradient length before clipping (`latent_kit.DeviceStats`), and the run's totals of updates
    /// skipped for want of windows and of actions replaced for not being finite - both 0 in a healthy run.
    /// What stopped being finite, in a run that failed so (`RunState.failed_nonfinite`); empty otherwise.
    nonfinite: []const u8 = "",
    /// THE COLLAPSE ALARM: the clip whose policy, once better than the servo, has been judged no better three times
    /// running (`JudgeLog.collapsedClip`); empty while none has. The run goes on - a person decides.
    collapse: []const u8 = "",
    world_model_loss: f32 = 0,
    critic_value_error: f32 = 0,
    policy_gradient_norm: f32 = 0,
    windows_refused: u64 = 0,
    nonfinite_actions: u64 = 0,
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

/// A SuperTrack run's training log (`log.csv`, as PPO's is): one line per ROUND - `collect` simulation steps of every
/// character, then `world_updates` and `policy_updates` updates - in raw counts. Its own columns, since a round is not
/// a batch; the columns every learner's log shares, by name, are `training_minutes`, `steps_watched` and `failures`,
/// which is all the lab's curves need (time to failure: steps watched per failure, over a window of lines).
///
///     round              rounds trained so far, this one included
///     training_minutes   minutes of training at the end of the round, over every start of the run
///     steps_watched      physics steps lived by the characters this round, with exploration noise
///     failures           of those steps, the ones at which a character lost the reference
///     world_updates      the world model's updates so far
///     policy_updates     the policy's updates so far
pub const SuperTrackLog = struct {
    /// How many recent rounds a run's time to failure is estimated over - the status's and the lab's curves alike: at
    /// four characters of 16 steps each, 8,192 steps, a little over two minutes of character-time, as PPO's window
    /// of batches is (`RunLog.window_batches`).
    pub const window_rounds: usize = 128;

    /// ONE ROUND'S LINE, and the log's columns: every field a column named by the field, the device's numbers
    /// (`latent_kit.DeviceStats`) flattened into columns of their own names - the header and every line are generated
    /// from this struct, so a number added here reaches the log, and the lab reads the columns by name (`RunCurve`).
    /// Counts are the round's own (the learner's totals' differences), the device's numbers their newest values.
    pub const Line = struct {
        round: u64,
        training_minutes: f32,
        steps_watched: u64,
        failures: u64,
        world_updates: u64,
        policy_updates: u64,
        /// The round's returns to the reference after a loss (`robot_track.Fleet.Options.return_steps`), and their mean
        /// time from the loss, in seconds.
        returns: u64 = 0,
        return_mean_seconds: f32 = 0,
        /// The pushes given in the round and their mean speed, in m/s - what the characters actually met - and how far
        /// the pushes' schedule had come, from 0 (none yet) to 1 (full strength) (`robot_track.Pushes.scheduleShare`).
        pushes: u64 = 0,
        push_mean_speed: f32 = 0,
        push_schedule: f32 = 0,
        /// At the round's end: the share of the characters planning, and the characters' mean projected hazard.
        flagged_share: f32 = 0,
        mean_hazard: f32 = 0,
        /// The round's planning decisions (characters deciding), and the share of its exploring steps acted from a
        /// plan.
        planning_decisions: u64 = 0,
        planned_step_share: f32 = 0,
        /// Teacher 2's and teacher 3's examples held at the round's end, and the trust in the critic.
        teacher2_examples: u64 = 0,
        teacher3_examples: u64 = 0,
        critic_trust: f32 = 0,
        /// The round's actions replaced for not being finite, weight readbacks refused, and updates skipped for want
        /// of windows - each 0 in a healthy run.
        nonfinite_actions: u64 = 0,
        mirrors_refused: u64 = 0,
        windows_refused: u64 = 0,
        /// Milliseconds of the round: acting (the simulation and the policy on the CPU); training on the CPU's side
        /// (recording the updates, submitting them, taking the readback - the GPU's own time is not seen); judging
        /// and probing, when the round had them.
        acting_ms: f32 = 0,
        training_ms: f32 = 0,
        judging_ms: f32 = 0,
        /// The device's numbers, newest (`latent_kit.DeviceStats`).
        device: latent_kit.DeviceStats = .{},
    };

    /// The log's first line: its columns, from `Line`'s fields, the device's flattened.
    pub const header: []const u8 = headerOf();

    fn headerOf() []const u8 {
        comptime var text: []const u8 = "";
        inline for (@typeInfo(Line).@"struct".field_names) |field_name| {
            if (comptime eql(u8, field_name, "device")) {
                inline for (@typeInfo(latent_kit.DeviceStats).@"struct".field_names) |device_field_name| {
                    text = text ++ device_field_name ++ ",";
                }
            } else {
                text = text ++ field_name ++ ",";
            }
        }
        return text[0 .. text.len - 1] ++ "\n";
    }

    /// Appends the line of a finished round - every column in the header's order, each number the shortest decimal
    /// that reads back to it. Memory: `log` grows with `gpa`, as its owner's.
    pub fn appendLine(gpa: Allocator, log: *ArrayList(u8), line: Line) !void {
        var is_first: bool = true;
        var number_buffer: [40]u8 = undefined;
        inline for (@typeInfo(Line).@"struct".field_names) |field_name| {
            if (comptime eql(u8, field_name, "device")) {
                inline for (@typeInfo(latent_kit.DeviceStats).@"struct".field_names) |device_field_name| {
                    const device_value: f32 = @field(line.device, device_field_name);
                    const text: []const u8 = try bufPrint(&number_buffer, "{d}", .{device_value});
                    try appendColumn(gpa, log, &is_first, text);
                }
            } else {
                const text: []const u8 = try bufPrint(&number_buffer, "{d}", .{@field(line, field_name)});
                try appendColumn(gpa, log, &is_first, text);
            }
        }
        try log.append(gpa, '\n');
    }

    /// One column's text, after a comma unless it is the line's first.
    fn appendColumn(
        gpa: Allocator,
        log: *ArrayList(u8),
        is_first: *bool,
        text: []const u8,
    ) !void {
        if (!is_first.*) {
            try log.append(gpa, ',');
        }
        is_first.* = false;
        try log.appendSlice(gpa, text);
    }
};

/// A run's judgements (`judge.csv`): a first line for the servo alone, the baseline every judgement is read against,
/// then one line each time the trainer judges its newest policy (`judgePolicy`, every `judge_minutes` of training) on
/// the same fixed starts. Raw counts and sums rather than conclusions, as the training log keeps them (`RunLog`): a
/// line holds every field of `robot_track.Judgement`, so that a reader rebuilds the judgement and asks it for its
/// measures and their standard errors by the same functions the trainer would use. Written by the trainer, read by
/// the lab.
/// The recovery probe's lines (`robot_track.probeRecovery`), one per band of push speed, as `recovery.csv` holds them -
/// read beside `judge.csv`: the judge says how long a policy keeps the reference undisturbed, the probe how it comes
/// back when pushed.
pub const RecoveryLog = struct {
    /// The file's first line: its columns.
    pub const header: []const u8 = "batch,training_minutes,clip,push_speed,pushes,survived,recovered," ++
        "recovery_steps_sum,lost,returned,return_steps_sum,not_returned,frame_time\n";

    /// Appends one line per band of a probe of clip `clip` - its label, "dance" or "get-up" - made after `batches`
    /// batches and `training_minutes` minutes of training (both zero for the servo's). Memory: `log` grows with `gpa`,
    /// as its owner's.
    pub fn appendLines(
        gpa: Allocator,
        log: *ArrayList(u8),
        batches: u64,
        training_minutes: f32,
        clip: []const u8,
        bands: []const robot_track.RecoveryBand,
        frame_time: f32,
    ) !void {
        for (bands) |band| {
            var line_buffer: [240]u8 = undefined;
            const line_format: []const u8 = "{d},{d},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n";
            const line: []const u8 = try bufPrint(&line_buffer, line_format, .{
                batches,
                training_minutes,
                clip,
                band.speed,
                band.pushes,
                band.survived,
                band.recovered,
                band.recovery_steps_sum,
                band.lost,
                band.returned,
                band.return_steps_sum,
                band.not_returned,
                frame_time,
            });
            try log.appendSlice(gpa, line);
        }
    }
};

pub const JudgeLog = struct {
    /// The file's first line: its columns.
    pub const header: []const u8 = "batch,training_minutes,clip,starts,failures,reached_end,watched_steps," ++
        "reward_sum,tracked_steps_squares,failed_starts_steps,tracked_share_sum,tracked_share_squares,frame_time\n";

    /// Appends the line of one judgement of clip `clip` - its label, "dance" or "get-up" - made after `batches`
    /// batches and `training_minutes` minutes of training (both zero for the servo's). Every number written as the
    /// shortest decimal that reads back to the same float, so a line read back is the judgement written. Memory: `log`
    /// grows with `gpa`, as its owner's.
    pub fn appendLine(
        gpa: Allocator,
        log: *ArrayList(u8),
        batches: u64,
        training_minutes: f32,
        clip: []const u8,
        judgement: robot_track.Judgement,
    ) !void {
        var line_buffer: [400]u8 = undefined;
        const line: []const u8 = try bufPrint(&line_buffer, "{d},{d},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n", .{
            batches,
            training_minutes,
            clip,
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

    /// One judgement's line, read back: when it was made, of which clip (a slice of the line's own text), and the
    /// judgement.
    pub const Line = struct {
        batch: u64,
        training_minutes: f32,
        clip: []const u8,
        judgement: robot_track.Judgement,
    };

    /// A line's fields in `appendLine`'s order; null for the header, a line cut short, or one with a column too many.
    pub fn parseLine(text: []const u8) ?Line {
        var columns: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, ',');
        const batch: u64 = RunLog.nextInteger(u64, &columns) orelse return null;
        const training_minutes: f32 = RunLog.nextFloat(&columns) orelse return null;
        const clip: []const u8 = columns.next() orelse return null;
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
        const line: Line = .{
            .batch = batch,
            .training_minutes = training_minutes,
            .clip = clip,
            .judgement = judgement,
        };
        return line;
    }

    /// THE COLLAPSE ALARM over a run's judgements (`judge.csv`'s text): the first of `clip_labels` whose policy, once
    /// judged keeping the reference longer than the servo, has since been judged keeping it no longer than the servo
    /// in each of its last `in_a_row` judgements - a policy that was learning and has fallen apart - or null. Below
    /// the servo before ever being above it is not a collapse: an untrained policy starts there. A clip's servo is its
    /// line of batch 0, judged once; the whole history is read each time, so the alarm holds across a resume.
    pub fn collapsedClip(
        judgements_text: []const u8,
        clip_labels: []const []const u8,
        in_a_row: u32,
    ) ?[]const u8 {
        for (clip_labels) |label| {
            var servo_seconds: ?f32 = null;
            var has_been_above: bool = false;
            var below_streak: u32 = 0;
            var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, judgements_text, '\n');
            while (lines.next()) |text| {
                const line: Line = parseLine(text) orelse continue;
                if (!eql(u8, line.clip, label)) {
                    continue;
                }
                const seconds: f32 = line.judgement.meanTimeToFailure();
                if (line.batch == 0) {
                    servo_seconds = seconds;
                    continue;
                }
                const servo: f32 = servo_seconds orelse continue;
                if (seconds > servo) {
                    has_been_above = true;
                    below_streak = 0;
                } else if (has_been_above) {
                    below_streak += 1;
                }
            }
            if (has_been_above and below_streak >= in_a_row) {
                return label;
            }
        }
        return null;
    }

    /// The next column as an f64; null when there is none, or it is not a number.
    fn nextFloat64(columns: *std.mem.SplitIterator(u8, .scalar)) ?f64 {
        const column: []const u8 = columns.next() orelse return null;
        return parseFloat(f64, column) catch null;
    }
};

/// A run's learning curve, read from its log as the log grows (`readMore`), whichever learner wrote the log: one point
/// per line - its training minutes, and the time to failure over the window of it and the lines before it, the measure
/// the trainer reports.
///
///     log         line 1: 600 watched, 0 failures      line 2: 600, 1      line 3: 600, 2
///     window      600 / 0                              1200 / 1            1800 / 3
///     point       none failed yet                      20 s                10 s          (at 60 steps a second)
///
/// LOGS ARE READ BY THEIR COLUMNS' NAMES. Each learner keeps its own log (`RunLog` for PPO's batches,
/// `SuperTrackLog` for SuperTrack's rounds), so the curve takes nothing from a column's position: the header names
/// the columns, and the curve finds the three every learner's log has - `training_minutes`, `steps_watched`,
/// `failures` - wherever they are. The first column says what one line is - `batch` or `round` - and so how many lines
/// the window holds (`RunLog.window_batches`, `SuperTrackLog.window_rounds`), each about two minutes of character-time.
/// A log whose header names neither, or lacks a column the curve needs, gives no points; its lines are counted as
/// skipped.
pub const RunCurve = struct {
    pub const Point = struct {
        /// The line's first column: batches trained so far for PPO, rounds for SuperTrack.
        trained_units: u64,
        training_minutes: f32,
        /// Null while nothing in the window has failed: no time to failure to tell yet.
        seconds_to_failure: ?f32,
    };

    /// Where the columns the curve needs are, as the log's header names them, and how many lines its window holds.
    pub const Columns = struct {
        column_count: usize,
        training_minutes_at: usize,
        steps_watched_at: usize,
        failures_at: usize,
        window_lines: usize,

        /// The columns of a log whose first line is `header_text` (without its newline), or null when it is no header
        /// the curve can read: the first column neither `batch` nor `round`, or a needed column missing.
        pub fn ofHeader(header_text: []const u8) ?Columns {
            var names: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, header_text, ',');
            const first_name: []const u8 = names.next() orelse return null;
            const window_lines: usize = if (eql(u8, first_name, "batch"))
                RunLog.window_batches
            else if (eql(u8, first_name, "round"))
                SuperTrackLog.window_rounds
            else
                return null;
            var training_minutes_at: ?usize = null;
            var steps_watched_at: ?usize = null;
            var failures_at: ?usize = null;
            var column_count: usize = 1;
            while (names.next()) |name| {
                const column_index: usize = column_count;
                column_count += 1;
                if (eql(u8, name, "training_minutes")) {
                    training_minutes_at = column_index;
                } else if (eql(u8, name, "steps_watched")) {
                    steps_watched_at = column_index;
                } else if (eql(u8, name, "failures")) {
                    failures_at = column_index;
                }
            }
            const columns: Columns = .{
                .column_count = column_count,
                .training_minutes_at = training_minutes_at orelse return null,
                .steps_watched_at = steps_watched_at orelse return null,
                .failures_at = failures_at orelse return null,
                .window_lines = window_lines,
            };
            return columns;
        }
    };

    /// The most lines any learner's window holds: the ring's size.
    const most_window_lines: usize = @max(RunLog.window_batches, SuperTrackLog.window_rounds);

    points: ArrayList(Point) = .empty,
    /// How far into the log's text the curve has read: always the end of a whole line.
    bytes_read: usize = 0,
    /// The log's columns, once its header has been read; null before.
    columns: ?Columns = null,
    /// The last lines' steps watched and failures, in a ring.
    window_steps_watched: [most_window_lines]u64 = @splat(0),
    window_failures: [most_window_lines]u64 = @splat(0),
    lines_seen: usize = 0,
    /// Lines that are not the log's - another program's, a damaged file's, or any line of a log whose header the
    /// curve cannot read: skipped, and counted.
    skipped_lines: usize = 0,

    pub fn deinit(self: *RunCurve, gpa: Allocator) void {
        self.points.deinit(gpa);
    }

    /// Reads the log's whole lines past `bytes_read`, `log_text` being the whole log as its file holds it now. A
    /// last line without its newline - the log being written as it is read - waits for the next read. A log
    /// shorter than what was read - a run carried on from an earlier save - is read again from its start, its header
    /// included.
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
            const columns: Columns = self.columns orelse {
                // The first line is the header: it says where the columns are. A log that does not start with one
                // the curve can read has every line skipped.
                self.columns = Columns.ofHeader(line_text);
                if (self.columns == null) {
                    self.skipped_lines += 1;
                }
                continue;
            };
            const point_line: PointLine = parsePointLine(line_text, columns) orelse {
                self.skipped_lines += 1;
                continue;
            };
            try self.addLine(gpa, point_line, columns, physics_steps_per_second);
        }
        self.bytes_read += last_newline + 1;
    }

    /// What a line gives the curve.
    const PointLine = struct {
        trained_units: u64,
        training_minutes: f32,
        steps_watched: u64,
        failures: u64,
    };

    /// A line read by `columns`, without its newline - or null when it is not one of the log's: too few or too many
    /// columns, or a needed one that is not a number.
    fn parsePointLine(line_text: []const u8, columns: Columns) ?PointLine {
        var trained_units: ?u64 = null;
        var training_minutes: ?f32 = null;
        var steps_watched: ?u64 = null;
        var failures: ?u64 = null;
        var column_count: usize = 0;
        var values: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, line_text, ',');
        while (values.next()) |value| {
            const column_index: usize = column_count;
            column_count += 1;
            if (column_index == 0) {
                trained_units = parseInt(u64, value, 10) catch return null;
            } else if (column_index == columns.training_minutes_at) {
                training_minutes = parseFloat(f32, value) catch return null;
            } else if (column_index == columns.steps_watched_at) {
                steps_watched = parseInt(u64, value, 10) catch return null;
            } else if (column_index == columns.failures_at) {
                failures = parseInt(u64, value, 10) catch return null;
            }
        }
        if (column_count != columns.column_count) {
            return null;
        }
        const point_line: PointLine = .{
            .trained_units = trained_units orelse return null,
            .training_minutes = training_minutes orelse return null,
            .steps_watched = steps_watched orelse return null,
            .failures = failures orelse return null,
        };
        return point_line;
    }

    /// One line into the window, and its point onto the curve.
    fn addLine(
        self: *RunCurve,
        gpa: Allocator,
        line: PointLine,
        columns: Columns,
        physics_steps_per_second: f32,
    ) !void {
        const window_lines: usize = columns.window_lines;
        const slot: usize = self.lines_seen % window_lines;
        self.window_steps_watched[slot] = line.steps_watched;
        self.window_failures[slot] = line.failures;
        self.lines_seen += 1;
        const lines_in_window: usize = @min(self.lines_seen, window_lines);
        var steps_watched: u64 = 0;
        var failures: u64 = 0;
        for (0..lines_in_window) |window_slot| {
            steps_watched += self.window_steps_watched[window_slot];
            failures += self.window_failures[window_slot];
        }
        const seconds_to_failure: ?f32 = ppo_track.secondsToFailure(steps_watched, failures, physics_steps_per_second);
        try self.points.append(gpa, .{
            .trained_units = line.trained_units,
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
    try JudgeLog.appendLine(gpa, &log, 4200, 61.5, "get-up", judgement);
    var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, log.items, '\n');
    const header_line: []const u8 = lines.next().?;
    try expectEqual(@as(?JudgeLog.Line, null), JudgeLog.parseLine(header_line));
    const judgement_line: []const u8 = lines.next().?;
    const read: JudgeLog.Line = JudgeLog.parseLine(judgement_line).?;
    try expectEqual(@as(u64, 4200), read.batch);
    try expectEqual(@as(f32, 61.5), read.training_minutes);
    try expectEqualStrings("get-up", read.clip);
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
    try expectEqual(@as(u64, 2), curve.points.items[1].trained_units);
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

test "RunCurve: a SuperTrack log is read by its columns' names, its window in rounds; an unknown header gives nothing" {
    // SuperTrack's columns are not PPO's - the counts sit in other places - and the curve finds them by name.
    var log: ArrayList(u8) = .empty;
    defer log.deinit(testing_allocator);
    try log.appendSlice(testing_allocator, SuperTrackLog.header);
    try SuperTrackLog.appendLine(testing_allocator, &log, .{
        .round = 1,
        .training_minutes = 0.10,
        .steps_watched = 600,
        .failures = 0,
        .world_updates = 1,
        .policy_updates = 0,
    });
    try SuperTrackLog.appendLine(testing_allocator, &log, .{
        .round = 2,
        .training_minutes = 0.20,
        .steps_watched = 600,
        .failures = 1,
        .world_updates = 2,
        .policy_updates = 1,
    });
    var curve: RunCurve = .{};
    defer curve.deinit(testing_allocator);
    try curve.readMore(testing_allocator, log.items, 60);
    try expectEqual(@as(usize, 2), curve.points.items.len);
    try expectEqual(@as(u64, 2), curve.points.items[1].trained_units);
    try expectEqual(@as(f32, 0.20), curve.points.items[1].training_minutes);
    try expectApproxEqAbs(@as(f32, 20), curve.points.items[1].seconds_to_failure.?, 1e-4);
    try expectEqual(SuperTrackLog.window_rounds, curve.columns.?.window_lines);
    // A log whose header names no column the curve knows: every line skipped, no point.
    var stranger: RunCurve = .{};
    defer stranger.deinit(testing_allocator);
    try stranger.readMore(testing_allocator, "step,loss\n1,0.5\n", 60);
    try expectEqual(@as(usize, 0), stranger.points.items.len);
    try expectEqual(@as(usize, 2), stranger.skipped_lines);
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
//   * So do what it observes and how often it decides. Learners differ in both: PPO's actor reads DReCon's
//     observation and decides every second physics step; SuperTrack's policy reads the character's state and the
//     reference one frame ahead, normalised by the clip's statistics, and decides at every physics step. A policy
//     names its observation (`ObservationKind`) and carries its decision interval, and whatever plays it builds the
//     observation it names and decides when it says - nothing about a learner is assumed by the player.
//
// The pipeline a policy applies, from observation to joints (the last two steps are the controller's,
// `robot_policy.Controller`):
//
//     observation -> normalise -> layer 1 -> ... -> layer n -> clamp -> scale -> filter -> joint targets
//
//   observation   the task's own units: angles, heights, velocities (`robot_policy.observeFrom`)
//   normalise     each input: its mean taken away, divided by its deviation, clamped to a few deviations
//   layers        dense: each output its bias plus its weighted inputs, through the layer's activation - for a
//                 NORMED layer, the outputs first layer-normalised together, each then scaled by its gain and
//                 shifted by its bias
//   clamp         the mean action held to the controller's range, plus or minus `action_limit`
//   scale         radians of joint offset per unit of action
//   filter        each decision, a joint's target moves the share `filter_beta` of the way to the new action

/// What a policy's layer applies to its pre-activations (`PolicyLayer`). The values are the file's, so they are
/// written out and never renumbered.
///
///   none                a linear layer, as a PPO actor's last layer is, so that its outputs are the action's mean
///   tanh                each value squashed into (-1, 1), as a PPO actor's hidden layers do (`robot_gym.GpuPpoOn`),
///                       and as EfficientTDMPC's policy squashes its mean
///   layer_norm_mish     TD-MPC2's normed layer (`zimrnum.NormedDense`), ending in Mish: the layer's pre-activations
///                       normalised TOGETHER - their mean taken away, divided by their spread (`zimrnum.layerNormRows`,
///                       epsilon inside the root) - each then times its gain plus its bias, then Mish
///                       (`zimrmath.mish`); the hidden layers of every EfficientTDMPC network
///   layer_norm_simnorm  the same normed layer ending in SimNorm (`zimrnum.simNormRows`): its outputs read as groups,
///                       each group softmaxed into a small probability vector - the encoder's last layer, whose output
///                       is the latent state
///
/// A normed layer's arithmetic after its linear part is zimrnum's own - the same functions the agent's graph runs -
/// so that only the linear part's order of summation can differ from the agent's (see `PolicyLayer`).
pub const PolicyActivation = enum(u8) {
    none = 0,
    tanh = 1,
    layer_norm_mish = 2,
    layer_norm_simnorm = 3,

    /// Whether a layer of this activation is NORMED: its pre-activations layer-normalised, with a gain and a bias per
    /// output, before the activation.
    pub fn isNormed(activation: PolicyActivation) bool {
        return switch (activation) {
            .none, .tanh => false,
            .layer_norm_mish, .layer_norm_simnorm => true,
        };
    }
};

/// Which observation a policy reads (`PolicyObservation`), as a policy file names it. The values are the file's, so
/// they are written out and never renumbered.
pub const ObservationKind = enum(u32) {
    /// DReCon's observation (`robot_policy.observeFrom`): the watched bodies' positions and velocities and the
    /// reference around the character's frame, in the root's heading frame, and the action being applied - what
    /// PPO's actor reads.
    drecon = 0,
    /// SuperTrack's features (`robot_track.local`): the goal - the reference one frame ahead - then the character's
    /// own state, each in the root's frame and normalised by the clip's frozen statistics. What SuperTrack's policy
    /// reads.
    supertrack_features = 1,
};

/// What a policy reads, with what it needs to build it: nothing more for DReCon's observation (its own normaliser,
/// when it has one, is the policy's `normalization`), and for SuperTrack's features the clip's per-feature means and
/// spreads, frozen when the policy was written (`robot_latent.Normalizer`: each feature `(x - mean) / spread`, no
/// clamp). The goal and the state are both normalised by the same statistics, so the policy's observation is twice
/// as wide as the normaliser.
pub const PolicyObservation = union(ObservationKind) {
    drecon,
    supertrack_features: latent.Normalizer,
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
///
/// A NORMED layer (`PolicyActivation.isNormed`) holds two vectors more after b, one value per output each: the layer
/// norm's gain, then its bias - zimrnum's `NormedDense` order (weight, bias, gain, norm bias). Its epsilon and, for
/// SimNorm, its group are the layer's own settings.
pub const PolicyLayer = struct {
    activation: PolicyActivation,
    weights_and_biases: []f32,
    /// A normed layer's epsilon, added to the variance inside the square root (zimrnum's `LayerNorm.epsilon`, 1e-5 in
    /// TD-MPC2); unused by a layer that is not normed.
    norm_epsilon: f32 = 0,
    /// A SimNorm layer's group - its outputs are softmaxed in consecutive groups of this many; unused otherwise.
    simnorm_group: u32 = 0,

    /// How many floats a layer of this shape and activation holds: W, then b, then - for a normed layer - the norm's
    /// gain and bias.
    pub fn parameterCount(
        activation: PolicyActivation,
        input_count: usize,
        output_count: usize,
    ) usize {
        const weight_count: usize = input_count * output_count;
        const norm_count: usize = if (activation.isNormed()) 2 * output_count else 0;
        return weight_count + output_count + norm_count;
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
    /// What the policy reads (`PolicyObservation`), and the frozen statistics its observation is built with.
    observation: PolicyObservation,
    /// Physics steps a decision is held for: the policy decides at the first of them, and its action stands for the
    /// rest. PPO's actor on Geno decides every 2 (30 Hz over 60 Hz physics), SuperTrack's policy every step.
    decimation: u32,

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
        switch (policy.observation) {
            .drecon => {},
            .supertrack_features => |feature_normalizer| {
                gpa.free(feature_normalizer.mean);
                gpa.free(feature_normalizer.spread);
            },
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

/// A normed layer's norm and activation on its pre-activations, in place (`PolicyActivation`): the row
/// layer-normalised (`zimrnum.layerNormRows`), each value times its gain plus its bias, then Mish (`zimrmath.mish`)
/// or SimNorm (`zimrnum.simNormRows`) - zimrnum's own functions, in the order zimrnum's `NormedDense` applies them.
fn applyNorm(
    layer: PolicyLayer,
    input_count: usize,
    values: []f32,
) void {
    const output_count: usize = values.len;
    const gains_start: usize = input_count * output_count + output_count;
    const gains: []const f32 = layer.weights_and_biases[gains_start..][0..output_count];
    const norm_biases: []const f32 = layer.weights_and_biases[gains_start + output_count ..][0..output_count];
    // The values as one row of a tensor, normalised in place: every value is read before any is written.
    const row_shape = [_]usize{ 1, output_count };
    const row: zn.Tensor(f32) = zn.Tensor(f32).fromSlice(values, &row_shape) catch |err| {
        return assertUnreachable(@src(), "applyNorm: a row of {d}: {s}", .{ output_count, @errorName(err) });
    };
    zn.layerNormRows(f32, row, row, layer.norm_epsilon) catch |err| {
        return assertUnreachable(@src(), "applyNorm: the layer norm: {s}", .{@errorName(err)});
    };
    for (values, gains, norm_biases) |*value, gain, norm_bias| {
        const scaled: f32 = value.* * gain;
        value.* = scaled + norm_bias;
    }
    switch (layer.activation) {
        .layer_norm_mish => for (values) |*value| {
            value.* = mish(value.*);
        },
        .layer_norm_simnorm => zn.simNormRows(f32, row, row, layer.simnorm_group) catch |err| {
            return assertUnreachable(@src(), "applyNorm: SimNorm in groups of {d}: {s}", .{
                layer.simnorm_group,
                @errorName(err),
            });
        },
        .none, .tanh => assertUnreachable(@src(), "applyNorm: a layer that is not normed", .{}),
    }
}

/// One layer of a policy on `layer_input`, written into `layer_output` (`PolicyLayer`): each output's bias, plus each
/// input times its weight in input order, then the layer's activation - for a normed layer, after the norm
/// (`applyNorm`).
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
            // A normed layer's activation comes after its norm, which needs every pre-activation first.
            .layer_norm_mish, .layer_norm_simnorm => pre_activation,
        };
    }
    if (layer.activation.isNormed()) {
        applyNorm(layer, input_count, layer_output);
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
    // The mean action, held to the controller's range - and never a non-finite number into the physics: a NaN target
    // makes NaN bodies, which no failure rule ever catches (every comparison with NaN is false). A non-finite component
    // becomes zero, the servo alone on that joint, as the SuperTrack learner does with its own actions. A policy with
    // no limit (SuperTrack's, an infinite `action_limit`) is held by nothing else.
    for (action) |*component| {
        const finite_component: f32 = if (isFinite(component.*)) component.* else 0.0;
        component.* = clamp(finite_component, -policy.action_limit, policy.action_limit);
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
    /// Physics steps a decision is held for (`robot_track_env.Options.decimation`).
    decimation: u32,
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
        const layer_activation: PolicyActivation = layer_activations[layer_index];
        const parameter_count: usize = PolicyLayer.parameterCount(layer_activation, input_count, output_count);
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
        .observation = .drecon,
        .decimation = parts.decimation,
    };
    return policy;
}

/// The policy of a SuperTrack learner (`robot_track_resident.PolicyParts`): its three layers - tanh, tanh and linear -
/// copied out of the packed weights acting uses, reading SuperTrack's features (the goal then the state, normalised by
/// a frozen copy of the learner's feature statistics), deciding at every physics step with no limit and no filter -
/// exactly as the learner acts on the fleet, whose action scale is `action_scale`.
///
/// The packed first layer is already a dense layer over `[goal | state]` in `PolicyLayer`'s layout: a row of weights
/// per input, the goal's inputs first, then its biases. So each layer is one slice of the packed weights, in order.
/// Memory: the policy's arrays are allocated with `gpa` and are the caller's - `deinit(gpa)` frees them, or, when
/// `gpa` is an arena, the arena does.
pub fn policyOfSuperTrack(
    gpa: Allocator,
    parts: resident.PolicyParts,
    action_scale: f32,
) !GenoPolicy {
    const observation_size: usize = 2 * parts.feature_count;
    const widths: []u32 = try gpa.alloc(u32, 4);
    errdefer gpa.free(widths);
    widths[0] = @intCast(observation_size);
    widths[1] = @intCast(parts.hidden_width);
    widths[2] = @intCast(parts.hidden_width);
    widths[3] = @intCast(parts.action_count);
    const layer_activations = [3]PolicyActivation{ .tanh, .tanh, .none };
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, 3);
    var layers_made: usize = 0;
    errdefer {
        for (layers[0..layers_made]) |layer| {
            gpa.free(layer.weights_and_biases);
        }
        gpa.free(layers);
    }
    var layer_start: usize = 0;
    for (layers, 0..) |*layer, layer_index| {
        const input_count: usize = widths[layer_index];
        const output_count: usize = widths[layer_index + 1];
        const layer_activation: PolicyActivation = layer_activations[layer_index];
        const parameter_count: usize = PolicyLayer.parameterCount(layer_activation, input_count, output_count);
        const layer_parameters: []const f32 = parts.packed_weights[layer_start..][0..parameter_count];
        const weights_and_biases: []f32 = try gpa.dupe(f32, layer_parameters);
        layer.* = .{ .activation = layer_activations[layer_index], .weights_and_biases = weights_and_biases };
        layers_made += 1;
        layer_start += parameter_count;
    }
    const every_weight_used: bool = layer_start == parts.packed_weights.len;
    assertf(every_weight_used, @src(), "policyOfSuperTrack: the layers hold {d} of {d} packed weights", .{
        layer_start,
        parts.packed_weights.len,
    });
    // The statistics copied, so that the learner's later normaliser - a resumed run measures its own - cannot move
    // the policy's.
    const frozen_means: []f32 = try gpa.dupe(f32, parts.normalizer.mean);
    errdefer gpa.free(frozen_means);
    const frozen_spreads: []f32 = try gpa.dupe(f32, parts.normalizer.spread);
    const no_limit: f32 = inf(f32);
    const every_action_unfiltered: f32 = 1.0;
    const every_physics_step: u32 = 1;
    const policy: GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = null,
        .action_limit = no_limit,
        .action_scale = action_scale,
        .filter_beta = every_action_unfiltered,
        .observation = .{ .supertrack_features = .{ .mean = frozen_means, .spread = frozen_spreads } },
        .decimation = every_physics_step,
    };
    return policy;
}

/// A zimrnum `NormedDense` as the player's layer (`PolicyLayer`): its four tensors in zimrnum's order - the linear
/// part's weight and bias, the norm's gain and bias - and its settings: the norm's epsilon, and SimNorm's group for a
/// layer ending in SimNorm. A layer ending in Mish is `layer_norm_mish`; one ending in SimNorm `layer_norm_simnorm`;
/// EfficientTDMPC's encoder and policy have no other kind. Memory: the layer's numbers from `gpa`, the caller's.
pub fn normedPolicyLayer(gpa: Allocator, normed: zn.NormedDense(f32)) !PolicyLayer {
    const activation: PolicyActivation = switch (normed.activation) {
        .mish => .layer_norm_mish,
        .sim_norm => .layer_norm_simnorm,
        else => {
            const activation_name: []const u8 = @tagName(normed.activation);
            assertUnreachable(@src(), "normedPolicyLayer: a normed layer ending in {s}", .{activation_name});
            return error.PolicyActivationUnknown;
        },
    };
    const simnorm_group: u32 = switch (normed.activation) {
        .sim_norm => |group| @intCast(group),
        else => 0,
    };
    var value_count: usize = 0;
    for (normed.tensors()) |tensor| {
        value_count += tensor.data.len;
    }
    const weights_and_biases: []f32 = try gpa.alloc(f32, value_count);
    var filled: usize = 0;
    for (normed.tensors()) |tensor| {
        @memcpy(weights_and_biases[filled..][0..tensor.data.len], tensor.data);
        filled += tensor.data.len;
    }
    const layer: PolicyLayer = .{
        .activation = activation,
        .weights_and_biases = weights_and_biases,
        .norm_epsilon = normed.norm.epsilon,
        .simnorm_group = simnorm_group,
    };
    return layer;
}

/// The policy an EfficientTDMPC agent deploys (`TdmpcAgent.Networks`), as a `GenoPolicy`. The agent acts by
/// planning; its policy network is what the planner taught, and what the show and the judge run without planning:
///
///     DReCon's observation, as it is - no normaliser in front of the encoder: its first layer's norm stands in for one
///     encoder: normed Mish layers, then a normed SimNorm layer - the latent state
///     policy:  normed Mish layers, then its HEAD - a plain linear layer of 2 x A outputs
///     the mean: tanh of the head's first A outputs
///
/// The head gives a raw centre and a raw spread for each of the A action dimensions (`zimrrl.TanhMeanGaussian`); the
/// mean action is tanh of the centre, so the file keeps the head's first A columns of weights and their biases and
/// drops the spread's - a last layer of A outputs through tanh. Everything else is the learner's controller: DReCon's
/// observation, its decision interval and filter, its action scale; the limit is 1, which tanh never reaches.
/// Memory: the policy's arrays from `gpa`, the caller's (`GenoPolicy.deinit`).
pub fn policyOfTdmpc(
    gpa: Allocator,
    networks: *const TdmpcAgent.Networks,
    learner: TdmpcLearner,
) !GenoPolicy {
    const encoder: zn.Mlp(f32) = networks.encoder;
    const policy_network: zn.Mlp(f32) = networks.policy;
    const encoder_last: zn.NormedDense(f32) = switch (encoder.last) {
        .normed => |normed| normed,
        .plain => {
            assertUnreachable(@src(), "policyOfTdmpc: an encoder without its SimNorm layer", .{});
            return error.PolicyActivationUnknown;
        },
    };
    const head: zn.Dense(f32) = switch (policy_network.last) {
        .plain => |plain| plain,
        .normed => {
            assertUnreachable(@src(), "policyOfTdmpc: a policy whose head is normed", .{});
            return error.PolicyActivationUnknown;
        },
    };
    const head_input_count: usize = head.weight.shape[0];
    const head_output_count: usize = head.weight.shape[1];
    const action_count: usize = head_output_count / 2;
    // The head gives two numbers per action dimension - the centres, then the spreads - so its width is even.
    assertf(head_output_count == 2 * action_count, @src(), "policyOfTdmpc: a head of {d} outputs", .{
        head_output_count,
    });
    // The layers in order: the encoder's hidden ones, its SimNorm layer, the policy's hidden ones, the mean.
    const layer_count: usize = encoder.hidden.len + 1 + policy_network.hidden.len + 1;
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, layer_count);
    var layers_made: usize = 0;
    errdefer {
        for (layers[0..layers_made]) |layer| {
            gpa.free(layer.weights_and_biases);
        }
        gpa.free(layers);
    }
    const widths: []u32 = try gpa.alloc(u32, layer_count + 1);
    errdefer gpa.free(widths);
    widths[0] = @intCast(encoder.spec.input);
    const normed_layers_in_order = [_][]const zn.NormedDense(f32){
        encoder.hidden,
        &.{encoder_last},
        policy_network.hidden,
    };
    for (normed_layers_in_order) |normed_layers| {
        for (normed_layers) |normed| {
            layers[layers_made] = try normedPolicyLayer(gpa, normed);
            widths[layers_made + 1] = @intCast(normed.dense.weight.shape[1]);
            layers_made += 1;
        }
    }
    // The mean: the head's first A columns - row i of its weight keeps entries 0 .. A - and their biases, through tanh.
    const mean_values: []f32 = try gpa.alloc(f32, PolicyLayer.parameterCount(.tanh, head_input_count, action_count));
    for (0..head_input_count) |input_index| {
        const head_row: []const f32 = head.weight.data[input_index * head_output_count ..][0..action_count];
        @memcpy(mean_values[input_index * action_count ..][0..action_count], head_row);
    }
    const mean_biases_start: usize = head_input_count * action_count;
    @memcpy(mean_values[mean_biases_start..][0..action_count], head.bias.data[0..action_count]);
    layers[layers_made] = .{ .activation = .tanh, .weights_and_biases = mean_values };
    widths[layers_made + 1] = @intCast(action_count);
    layers_made += 1;
    const policy: GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = null,
        .action_limit = 1.0,
        .action_scale = learner.action_scale,
        .filter_beta = learner.beta,
        .observation = .drecon,
        .decimation = learner.decimation,
    };
    return policy;
}

/// A policy file (`GenoPolicy`): a `Header`; an `ObservationHeader`; then each layer - a
/// `LayerHeader` and its weights and biases (f32, W then b, then for a normed layer the norm's gain and bias); then,
/// when the observation is normalised, the frozen normaliser's per-input means and sums of squared deviations (f64
/// each); then, for SuperTrack's features, the clip's per-feature means and spreads (f32 each).
///
///     Header              magic, version, layer count, flags, observation size, limit, scale, filter, normaliser's
///                         count, clip and epsilon
///     ObservationHeader   which observation (`ObservationKind`), the decision interval, the feature count
///     layer 1 .. n        LayerHeader (with a normed layer's SimNorm group and epsilon), then W and b - and the
///                         norm's gain and bias for a normed layer (`PolicyActivation.isNormed`)
///     normaliser          means, sums of squared deviations             when `Flags.normalizes_observations`
///     features            means, spreads                                when the observation is SuperTrack's
///
/// A file of any other version is refused: the layout has one version, its own, and nothing older is kept.
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
    /// The layout's version. A file of another is refused (`ReadError.PolicyVersionUnknown`): a file written before
    /// the layout last changed is written again by its trainer, not read in an older form.
    pub const version: u32 = 4;

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

    /// What a policy reads and how often it decides, after the `Header`. `feature_count` is the
    /// width of SuperTrack's feature normaliser - half the observation, which is the goal then the state - and zero for
    /// DReCon's observation.
    pub const ObservationHeader = extern struct {
        /// `ObservationKind`, as its backing integer.
        kind: u32,
        decimation: u32,
        feature_count: u32,
        reserved: u32 = 0,
    };

    /// What precedes each layer's weights and biases: its output count (its input count is the width before it), its
    /// activation (`PolicyActivation`'s backing integer), and a normed layer's settings - its SimNorm group (a SimNorm
    /// layer's, zero for any other) and its norm's epsilon (zero for a layer that is not normed).
    pub const LayerHeader = extern struct {
        output_count: u32,
        activation: u32,
        simnorm_group: u32,
        norm_epsilon: f32,
    };

    comptime {
        if (builtin.cpu.arch.endian() != .little) {
            @compileError("PolicyFile writes its headers as they lie in memory, which assumes a little-endian target");
        }
    }

    /// Why a file is no policy: the wrong first bytes, a version this reader does not know, flags it does not know, too
    /// few bytes for what the file says it holds, too many - bytes after its end - no layer, an activation it does not
    /// know, a normed layer's settings that cannot be (an epsilon not positive and finite, a SimNorm group of zero or
    /// one that does not divide the layer's outputs, or settings on a layer that is not normed), or a normaliser that
    /// cannot be (a clip or an epsilon not positive, a statistic not finite, a sum of
    /// squared deviations below zero), an observation it does not know, a decision interval of zero, or SuperTrack's
    /// feature statistics that cannot be (not half the observation, a spread not positive and finite, a mean not
    /// finite).
    pub const ReadError = error{
        NotAPolicyFile,
        PolicyVersionUnknown,
        PolicyObservationUnknown,
        PolicyDecimationInvalid,
        PolicyFeaturesInvalid,
        PolicyFlagsUnknown,
        PolicyTruncated,
        PolicyHasTrailingBytes,
        PolicyHasNoLayers,
        PolicyActivationUnknown,
        PolicyNormInvalid,
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
                layer.activation,
                policy.widths[layer_index],
                policy.widths[layer_index + 1],
            );
            const holds_its_parameters: bool = layer.weights_and_biases.len == parameter_count;
            assertf(holds_its_parameters, @src(), "PolicyFile.encode: layer {d} holds {d} parameters of {d}", .{
                layer_index,
                layer.weights_and_biases.len,
                parameter_count,
            });
            const output_count: u32 = policy.widths[layer_index + 1];
            const norm_problem: ?ReadError = normProblem(
                layer.activation,
                output_count,
                layer.simnorm_group,
                layer.norm_epsilon,
            );
            assertf(norm_problem == null, @src(), "PolicyFile.encode: layer {d}'s norm settings cannot be read back", .{
                layer_index,
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
        assertf(policy.decimation > 0, @src(), "PolicyFile.encode: a decision interval of zero", .{});
        const feature_count: usize = switch (policy.observation) {
            .drecon => 0,
            .supertrack_features => |feature_normalizer| feature_normalizer.mean.len,
        };
        if (policy.observation == .supertrack_features) {
            const feature_normalizer: latent.Normalizer = policy.observation.supertrack_features;
            const goal_and_state_width: usize = 2 * feature_count;
            const features_fit: bool = goal_and_state_width == policy.observationSize() and
                feature_normalizer.spread.len == feature_count;
            assertf(features_fit, @src(), "PolicyFile.encode: {d} features for an observation of {d}", .{
                feature_count,
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
        const observation_kind: ObservationKind = policy.observation;
        const observation_header: ObservationHeader = .{
            .kind = @backingInt(observation_kind),
            .decimation = policy.decimation,
            .feature_count = @intCast(feature_count),
        };
        var bytes: ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, asBytes(&header));
        try bytes.appendSlice(gpa, asBytes(&observation_header));
        for (policy.layers, 0..) |layer, layer_index| {
            const layer_header: LayerHeader = .{
                .output_count = policy.widths[layer_index + 1],
                .activation = @backingInt(layer.activation),
                .simnorm_group = layer.simnorm_group,
                .norm_epsilon = layer.norm_epsilon,
            };
            try bytes.appendSlice(gpa, asBytes(&layer_header));
            try bytes.appendSlice(gpa, sliceAsBytes(layer.weights_and_biases));
        }
        if (normalization) |normalizer| {
            try bytes.appendSlice(gpa, sliceAsBytes(normalizer.mean));
            try bytes.appendSlice(gpa, sliceAsBytes(normalizer.m2));
        }
        switch (policy.observation) {
            .drecon => {},
            .supertrack_features => |feature_normalizer| {
                try bytes.appendSlice(gpa, sliceAsBytes(feature_normalizer.mean));
                try bytes.appendSlice(gpa, sliceAsBytes(feature_normalizer.spread));
            },
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
        const observation_header: ObservationHeader = bytesToValue(
            ObservationHeader,
            try reader.take(@sizeOf(ObservationHeader)),
        );
        const observation_kind: ObservationKind = fromInt(ObservationKind, observation_header.kind) orelse {
            return error.PolicyObservationUnknown;
        };
        if (observation_header.decimation == 0) {
            return error.PolicyDecimationInvalid;
        }
        // Halving the observation rather than doubling the count: a damaged count of four billion doubled would
        // overflow a 32-bit `usize`, the web's.
        const feature_count: usize = observation_header.feature_count;
        const observation_is_two_halves: bool = header.observation_size % 2 == 0;
        const half_observation: usize = header.observation_size / 2;
        const features_are_half: bool = observation_is_two_halves and feature_count == half_observation;
        const features_match_observation: bool = switch (observation_kind) {
            .drecon => feature_count == 0,
            .supertrack_features => feature_count > 0 and features_are_half,
        };
        if (!features_match_observation) {
            return error.PolicyFeaturesInvalid;
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
            const norm_problem: ?ReadError = normProblem(
                activation,
                layer_header.output_count,
                layer_header.simnorm_group,
                layer_header.norm_epsilon,
            );
            if (norm_problem) |problem| {
                return problem;
            }
            widths[layer_index + 1] = layer_header.output_count;
            const input_count: u32 = widths[layer_index];
            const output_count: u32 = layer_header.output_count;
            const parameter_count: usize = layerParameterCount(activation, input_count, output_count) orelse {
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
            layer.* = .{
                .activation = activation,
                .weights_and_biases = weights_and_biases,
                .norm_epsilon = layer_header.norm_epsilon,
                .simnorm_group = layer_header.simnorm_group,
            };
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
        const observation: PolicyObservation = switch (observation_kind) {
            .drecon => .drecon,
            .supertrack_features => .{ .supertrack_features = try readFeatureNormalizer(gpa, &reader, feature_count) },
        };
        errdefer {
            switch (observation) {
                .drecon => {},
                .supertrack_features => |feature_normalizer| {
                    gpa.free(feature_normalizer.mean);
                    gpa.free(feature_normalizer.spread);
                },
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
            .observation = observation,
            .decimation = observation_header.decimation,
        };
        return policy;
    }

    /// SuperTrack's per-feature means and spreads, `feature_count` of each (f32), read from the file and checked: a
    /// mean must be finite, a spread positive and finite - each feature is divided by its spread. Memory: both arrays
    /// with `gpa`, the caller's; on an error, nothing is left allocated.
    fn readFeatureNormalizer(
        gpa: Allocator,
        reader: *Reader,
        feature_count: usize,
    ) ReadError!latent.Normalizer {
        const statistics_bytes: usize = mulChecked(usize, feature_count, 2 * @sizeOf(f32)) catch {
            return error.PolicyTruncated;
        };
        if (statistics_bytes > reader.left()) {
            return error.PolicyTruncated;
        }
        const means: []f32 = try gpa.alloc(f32, feature_count);
        errdefer gpa.free(means);
        const spreads: []f32 = try gpa.alloc(f32, feature_count);
        errdefer gpa.free(spreads);
        @memcpy(sliceAsBytes(means), try reader.take(feature_count * @sizeOf(f32)));
        @memcpy(sliceAsBytes(spreads), try reader.take(feature_count * @sizeOf(f32)));
        for (means, spreads) |mean, spread| {
            const feature_usable: bool = isFinite(mean) and isFinite(spread) and spread > 0;
            if (!feature_usable) {
                return error.PolicyFeaturesInvalid;
            }
        }
        const feature_normalizer: latent.Normalizer = .{ .mean = means, .spread = spreads };
        return feature_normalizer;
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
    fn layerParameterCount(
        activation: PolicyActivation,
        input_count: u32,
        output_count: u32,
    ) ?usize {
        const matrix: usize = mulChecked(usize, input_count, output_count) catch {
            return null;
        };
        const with_biases: usize = addChecked(usize, matrix, output_count) catch {
            return null;
        };
        if (!activation.isNormed()) {
            return with_biases;
        }
        // The norm's gain and bias: two more values per output. The output count is a u32, so twice it fits in a
        // usize of 64 bits; the sum is checked.
        const norm_values: usize = mulChecked(usize, 2, output_count) catch {
            return null;
        };
        return addChecked(usize, with_biases, norm_values) catch null;
    }

    /// Why a layer's norm settings cannot be (`ReadError.PolicyNormInvalid`), or null: a normed layer needs an epsilon
    /// that is positive and finite, a SimNorm layer a group of two or more that divides its outputs into whole groups;
    /// a layer that is not normed has neither (both zero), and a Mish layer no group.
    fn normProblem(
        activation: PolicyActivation,
        output_count: u32,
        simnorm_group: u32,
        norm_epsilon: f32,
    ) ?ReadError {
        const is_epsilon_usable: bool = norm_epsilon > 0 and isFinite(norm_epsilon);
        const is_group_usable: bool = simnorm_group >= 2 and output_count % simnorm_group == 0;
        const settings_fit: bool = switch (activation) {
            .none, .tanh => simnorm_group == 0 and norm_epsilon == 0,
            .layer_norm_mish => is_epsilon_usable and simnorm_group == 0,
            .layer_norm_simnorm => is_epsilon_usable and is_group_usable,
        };
        return if (settings_fit) null else error.PolicyNormInvalid;
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
// A decision lasts the policy's `decimation` physics steps (PPO's actor on Geno: k = 2, decisions at 30 Hz over Geno's
// 60 Hz physics; SuperTrack's policy: every step). At the first physics step of each, every character observes - its
// simulated state, the reference around its frame, the action its controller is applying - and the policy gives its
// mean action; through the decision's steps the controller blends that action into the joints' targets at the policy's
// filter.
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
/// file does not carry. The policy brings its own action scale, limit, filter and decision interval.
pub const PolicyShowSettings = struct {
    /// Characters shown side by side, each living its own episodes.
    character_count: usize = 1,
    /// The fleet's random stream: where each episode starts on the clip. The same seed gives the same episodes -
    /// `robot_ppo_track.evaluation_seed` to live what PPO's own evaluation lives.
    seed: u64 = ppo_track.evaluation_seed,
    /// Physics steps after which an episode ends even while the character tracks well: a cut, not a failure. The
    /// dance's twenty seconds.
    max_episode_steps: u32 = 1200,
    /// The task the fleet runs (`robot_track.Task`: the servo, the floor, the reward, the failure rule - Geno's is
    /// `robot_geno.tracking_task`), and DReCon's bodies: the ones the policy watches and the joints it nudges.
    task: robot_track.Task = .{},
    bodies: robot_policy.Bodies = .{},
};

/// How the lab shows a run's policy (`PolicyShow`), whichever learner trained it: Geno's task and DReCon's bodies -
/// every learner's run is on them; one character, on the evaluation's seed. What differs between learners - the
/// observation, the decision interval, the controller - is the policy's own.
pub fn genoShowSettings() PolicyShowSettings {
    const settings: PolicyShowSettings = .{
        .task = tracking_task,
        .bodies = drecon_bodies,
    };
    return settings;
}

/// How a policy decides for a fleet's characters (`decide`), with the scratch a decision needs: the joints the policy
/// nudges - DReCon's choice of bodies for DReCon's observation, every actuated joint for SuperTrack's features - and
/// buffers for the observation the policy names and for the policy's layers. One definition, used by the show and by
/// the judge's actor alike.
pub const PolicyDecider = struct {
    /// The robot's model (the caller's).
    model: *rbt.Model,
    subset: robot_policy.Subset,
    /// For DReCon's observation: the reference now and further ahead. For both: a character's simulated state.
    reference_views: robot_policy.Views,
    simulated_state: robot_track.State,
    /// For SuperTrack's features: the reference one frame ahead, the model data it is posed in, and one feature
    /// vector before normalising (`robot_track_resident.FeatureScratch`).
    reference_state: robot_track.State,
    reference_probe: rbt.Data,
    raw_features: []f32,
    /// The observation itself, and the policy's two layer buffers.
    observation: []f32,
    scratch: PolicyScratch,

    /// A decider for `policy` on `model`, which must give the policy's observation and action sizes: with DReCon's
    /// `bodies` for DReCon's observation (the bodies are not used for SuperTrack's features, which read every body).
    /// Memory: everything in `arena`, the caller's.
    pub fn init(
        arena: Allocator,
        model: *rbt.Model,
        body_names: []const []const u8,
        bodies: robot_policy.Bodies,
        policy: *const GenoPolicy,
    ) !PolicyDecider {
        const subset: robot_policy.Subset = switch (policy.observation) {
            .drecon => try robot_policy.subsetFor(arena, model, body_names, bodies.watched, bodies.actuated),
            .supertrack_features => try robot_policy.everyActuatedJoint(arena, model),
        };
        // The policy must fit the task: an observation of the size it names, an action per joint the subset nudges.
        const feature_count: usize = robot_track.localSize(model.nbody);
        const observation_size: usize = switch (policy.observation) {
            .drecon => robot_policy.observationSize(subset),
            .supertrack_features => 2 * feature_count,
        };
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
        const reference_state: robot_track.State = try .init(arena, model.nbody);
        const reference_probe: rbt.Data = try .init(arena, model);
        const raw_features: []f32 = try arena.alloc(f32, feature_count);
        const scratch: PolicyScratch = try .init(arena, policy);
        const decider: PolicyDecider = .{
            .model = model,
            .subset = subset,
            .reference_views = reference_views,
            .simulated_state = simulated_state,
            .reference_state = reference_state,
            .reference_probe = reference_probe,
            .raw_features = raw_features,
            .observation = try arena.alloc(f32, observation_size),
            .scratch = scratch,
        };
        return decider;
    }

    /// A decision: each of the first `character_count` characters of `fleet` observes what `policy` names - DReCon's
    /// observation (its simulated state, the reference around its frame, the action `controller` is applying to it) or
    /// SuperTrack's features (the goal, then its state) - and `policy` gives its mean action for what it observed, into
    /// `actions` (a row of the action's size per character).
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
            switch (policy.observation) {
                .drecon => decider.observeDrecon(controller, fleet, character),
                .supertrack_features => |feature_normalizer| decider.observeFeatures(
                    feature_normalizer,
                    fleet,
                    character,
                ),
            }
            policyMeanAction(policy, decider.observation, decider.scratch, character_action);
        }
    }

    /// DReCon's observation of `character`, into `observation` (`robot_policy.observeFrom`).
    fn observeDrecon(
        decider: *PolicyDecider,
        controller: *const robot_policy.Controller,
        fleet: *robot_track.Fleet,
        character: usize,
    ) void {
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
    }

    /// SuperTrack's features of `character`, into `observation`: the goal in its first half, the state in its second
    /// - the order the policy's first layer reads them in - through the learner's own definition
    /// (`robot_track_resident.supertrackFeaturesInto`).
    fn observeFeatures(
        decider: *PolicyDecider,
        feature_normalizer: latent.Normalizer,
        fleet: *robot_track.Fleet,
        character: usize,
    ) void {
        const feature_count: usize = decider.raw_features.len;
        const goal_half: []f32 = decider.observation[0..feature_count];
        const state_half: []f32 = decider.observation[feature_count..][0..feature_count];
        const feature_scratch: resident.FeatureScratch = .{
            .simulated = &decider.simulated_state,
            .reference = &decider.reference_state,
            .probe = &decider.reference_probe,
            .raw_features = decider.raw_features,
        };
        resident.supertrackFeaturesInto(fleet, character, feature_normalizer, feature_scratch, goal_half, state_half);
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
            .decimation = policy.decimation,
        });
        const actions: []f32 = try arena.alloc(f32, character_count * decider.subset.dofs);
        @memset(actions, 0.0);
        const show: PolicyShow = .{
            .decider = decider,
            .fleet = fleet,
            .controller = controller,
            .character_count = character_count,
            .decimation = policy.decimation,
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
/// character of the judge's fleet, decided every `decimation` physics steps (the policy's own) and filtered by DReCon's
/// controller - what `PolicyShow` does for a viewer, here for the judge, so that any learner's run is judged as it is
/// shown. The judge steps its fleet every physics step with what this actor gives it; a character it restarts begins
/// fresh, its controller forgetting the action it was applying.
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
        policy: *const GenoPolicy,
        character_count: usize,
    ) !PolicyJudgeActor {
        const decider: PolicyDecider = try .init(arena, model, body_names, bodies, policy);
        const controller: robot_policy.Controller = try .init(arena, model, decider.subset, character_count, .{
            .beta = policy.filter_beta,
            .decimation = policy.decimation,
        });
        const actions: []f32 = try arena.alloc(f32, character_count * decider.subset.dofs);
        @memset(actions, 0.0);
        const judge_actor: PolicyJudgeActor = .{
            .decider = decider,
            .controller = controller,
            .policy = policy,
            .character_count = character_count,
            .decimation = policy.decimation,
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
        // The FLEET'S characters, never more: a fleet may hold fewer than the actor was built for - the recovery
        // probe keeps only the starts with room for a whole push and watch before the clip ends - and acting on the
        // actor's count would read past the fleet's.
        const character_count: usize = fleet.options.envs;
        const fits: bool = character_count <= judge_actor.character_count;
        assertf(fits, @src(), "a judged fleet of {d} characters, an actor for {d}", .{
            character_count,
            judge_actor.character_count,
        });
        // A character whose episode ended at the last step starts fresh.
        for (0..character_count) |character| {
            if (fleet.dones[character]) {
                judge_actor.controller.forget(character);
            }
        }
        const decides_now: bool = judge_actor.physics_steps_until_decision == 0;
        if (decides_now) {
            const policy: *const GenoPolicy = judge_actor.policy;
            judge_actor.decider.decide(policy, &judge_actor.controller, fleet, character_count, judge_actor.actions);
            judge_actor.physics_steps_until_decision = @max(judge_actor.decimation, 1);
        }
        const filtered_actions: []const f32 = judge_actor.controller.apply(judge_actor.actions);
        @memcpy(fleet_actions, filtered_actions[0..fleet_actions.len]);
        judge_actor.physics_steps_until_decision -= 1;
    }
};

/// What a policy is judged on (`judgePolicy`) beyond the policy itself: the starts (frames of the clip - the judge's
/// usual ones are `robot_track.evenStarts`), the task and DReCon's bodies. The decision interval is the policy's.
pub const PolicyJudgeSettings = struct {
    starts: []const usize,
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
        judged_policy,
        character_count,
    );
    return robot_track.judge(gpa, model, clip, fleet_options, settings.starts, judge_actor.actor());
}

/// `policy` put through the recovery probe on `clip` (`robot_track.probeRecovery`: the judge's starts, each pushed once
/// at every band's speed, the probe's own seed for the directions) - or, with no policy, the servo alone - one band
/// per speed into `bands`. Memory as `judgePolicy`'s: the actor in `arena`, the probe's fleets with `gpa`, freed
/// before it returns.
pub fn probePolicy(
    gpa: Allocator,
    arena: Allocator,
    model: *rbt.Model,
    body_names: []const []const u8,
    clip: *const dance.Clip,
    policy: ?*const GenoPolicy,
    settings: PolicyJudgeSettings,
    probe: robot_track.RecoveryProbe,
    bands: []robot_track.RecoveryBand,
) !void {
    const servo_scale: f32 = 0.0;
    const action_scale: f32 = if (policy) |judged| judged.action_scale else servo_scale;
    const fleet_options: robot_track.Fleet.Options = .{
        .action_scale = action_scale,
        .task = settings.task,
        .body_names = body_names,
    };
    const judged_policy: *const GenoPolicy = policy orelse {
        return robot_track.probeRecovery(gpa, model, clip, fleet_options, settings.starts, null, probe, bands);
    };
    var judge_actor: PolicyJudgeActor = try .init(
        arena,
        model,
        body_names,
        settings.bodies,
        judged_policy,
        settings.starts.len,
    );
    const actor: robot_track.Actor = judge_actor.actor();
    return robot_track.probeRecovery(gpa, model, clip, fleet_options, settings.starts, actor, probe, bands);
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
        .observation = .drecon,
        .decimation = 2,
    };
    return policy;
}

test "policyOfTdmpc: the file acts as the agent's policy means to act - to rounding; one weight changed moves it" {
    // A small EfficientTDMPC agent - 12 inputs, 5 actions, latent and hidden widths 16 - whose policy head is scaled
    // up so that its means spread across (-1, 1) instead of sitting near 0. The agent's own mean action, through its
    // graph - the encoder, the policy network, tanh of the head's first half - against the file's, written and read
    // back. Only the order of summation inside each layer's linear part differs, so they agree to rounding.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const learner: TdmpcLearner = .{ .latent_width = 16, .hidden_width = 16, .decimation = 3, .beta = 0.25 };
    const observation_width: usize = 12;
    const action_width: usize = 5;
    var networks: TdmpcAgent.Networks = try .init(
        arena,
        zn.Rng.init(7),
        observation_width,
        action_width,
        learner.agentConfig(),
    );
    for (networks.policy.last.plain.weight.data) |*weight| {
        weight.* *= 40;
    }
    const observation = [_]f32{ 0.5, -1.0, 2.0, 0.1, -0.3, 0.9, 1.4, -2.2, 0.0, 0.7, -0.6, 3.0 };
    // The agent's mean, through its graph.
    var graph: zn.Graph(f32) = .init(arena);
    const input_shape = [_]usize{ 1, observation_width };
    const input: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, &observation), &input_shape);
    const input_value: zn.Var = try graph.constant(input);
    const encoded: zn.Mlp(f32).Attached = try networks.encoder.attach(&graph, input_value, arena);
    const head: zn.Mlp(f32).Attached = try networks.policy.attach(&graph, encoded.out, arena);
    const head_values: []const f32 = graph.valueOf(head.out).data;
    var agent_mean: [action_width]f32 = undefined;
    for (&agent_mean, head_values[0..action_width]) |*mean, centre| {
        mean.* = tanh(centre);
    }
    // The file's, written and read back.
    var policy: GenoPolicy = try policyOfTdmpc(testing_allocator, &networks, learner);
    defer policy.deinit(testing_allocator);
    const bytes: []u8 = try PolicyFile.encode(testing_allocator, &policy);
    defer testing_allocator.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(testing_allocator, bytes);
    defer read_back.deinit(testing_allocator);
    try expectEqualSlices(u32, &.{ 12, 256, 16, 16, 16, 5 }, read_back.widths);
    try expectEqual(@as(u32, 3), read_back.decimation);
    try expectEqual(@as(f32, 0.25), read_back.filter_beta);
    try expect(read_back.normalization == null);
    const scratch: PolicyScratch = try .init(arena, &read_back);
    var file_mean: [action_width]f32 = undefined;
    policyMeanAction(&read_back, &observation, scratch, &file_mean);
    var spread_seen: f32 = 0;
    for (agent_mean, file_mean) |expected, played| {
        try expectApproxEqAbs(expected, played, 1e-5);
        spread_seen = @max(spread_seen, @abs(expected));
    }
    // The means really spread: a test of numbers near zero would pass for many wrong files.
    try expect(spread_seen > 0.3);
    // CONTROL: one weight of the encoder's first layer changed in the file moves the action.
    read_back.layers[0].weights_and_biases[3] += 0.5;
    var moved_mean: [action_width]f32 = undefined;
    policyMeanAction(&read_back, &observation, scratch, &moved_mean);
    try expect(!eql(f32, &file_mean, &moved_mean));
}

test "PolicyLayer: a normed layer computes what zimrnum's NormedDense computes - its norm and activation exactly" {
    // Two layers as EfficientTDMPC builds them: 6 inputs to 16 outputs through Mish, and through SimNorm in groups of
    // 8. Their gains and norm biases are set away from 1 and 0, so a layer that skipped them would show. On the SAME
    // pre-activations the player's norm and activation equal the graph's to the bit - they are the same functions;
    // the whole layer agrees to rounding, since only the linear part's order of summation differs.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const input_values = [_]f32{ 0.3, -1.2, 0.8, 2.0, -0.4, 0.05 };
    const activations = [_]zn.Activation{ .mish, .{ .sim_norm = 8 } };
    const player_activations = [_]PolicyActivation{ .layer_norm_mish, .layer_norm_simnorm };
    for (activations, player_activations, 0..) |activation, player_activation, layer_seed| {
        const normed: zn.NormedDense(f32) = try .init(
            arena,
            zn.Rng.init(@intCast(31 + layer_seed)),
            input_values.len,
            16,
            .xavier,
            activation,
            0,
        );
        for (normed.norm.gain.data, normed.norm.bias.data, 0..) |*gain, *norm_bias, feature| {
            gain.* = 0.5 + 0.1 * float(feature);
            norm_bias.* = 0.2 - 0.03 * float(feature);
        }
        var graph: zn.Graph(f32) = .init(arena);
        const input: zn.Tensor(f32) = try .fromSlice(try arena.dupe(f32, &input_values), &.{ 1, input_values.len });
        const input_value: zn.Var = try graph.constant(input);
        const through_graph: zn.NormedDense(f32).Attached = try normed.attach(&graph, input_value);
        const linear: zn.Dense(f32).Attached = try normed.dense.attach(&graph, input_value);
        const graph_output: []const f32 = graph.valueOf(through_graph.out).data;
        const graph_linear: []const f32 = graph.valueOf(linear.out).data;
        const layer: PolicyLayer = try normedPolicyLayer(arena, normed);
        try expectEqual(player_activation, layer.activation);
        const parameter_count: usize = PolicyLayer.parameterCount(player_activation, input_values.len, 16);
        try expectEqual(parameter_count, layer.weights_and_biases.len);
        // The norm and the activation, on the graph's own pre-activations: bit for bit.
        const normed_here: []f32 = try arena.dupe(f32, graph_linear);
        applyNorm(layer, input_values.len, normed_here);
        try expectEqualSlices(f32, graph_output, normed_here);
        // The whole layer, from the input: to rounding.
        const whole_layer: []f32 = try arena.alloc(f32, 16);
        applyPolicyLayer(layer, &input_values, whole_layer);
        for (graph_output, whole_layer) |expected, played| {
            try expectApproxEqAbs(expected, played, 1e-5);
        }
        // CONTROL: another epsilon, or SimNorm in other groups, gives other numbers - the settings are used.
        var other_layer: PolicyLayer = layer;
        switch (player_activation) {
            .layer_norm_mish => other_layer.norm_epsilon = 0.5,
            else => other_layer.simnorm_group = 4,
        }
        const otherwise: []f32 = try arena.dupe(f32, graph_linear);
        applyNorm(other_layer, input_values.len, otherwise);
        try expect(!eql(f32, graph_output, otherwise));
    }
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
    try expect(read_back.observation == .drecon);
    try expectEqual(policy.decimation, read_back.decimation);
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

/// A small SuperTrack policy made by hand for the file's tests: 2 features, so 4 inputs (the goal, then the state),
/// 3 tanh, 2 out, deciding at every physics step with no limit on its action - as SuperTrack's policy acts. Its
/// feature statistics: means 0.5 and -1, spreads 2 and 0.25.
fn handMadeSuperTrackPolicy(gpa: Allocator) !GenoPolicy {
    const widths: []u32 = try gpa.dupe(u32, &.{ 4, 3, 2 });
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, 2);
    const first_weights: []f32 = try gpa.alloc(f32, PolicyLayer.parameterCount(.tanh, 4, 3));
    for (first_weights, 0..) |*weight, index| {
        weight.* = 0.3 - 0.04 * float(index);
    }
    const second_weights: []f32 = try gpa.alloc(f32, PolicyLayer.parameterCount(.none, 3, 2));
    for (second_weights, 0..) |*weight, index| {
        weight.* = 0.1 * float(index) - 0.4;
    }
    layers[0] = .{ .activation = .tanh, .weights_and_biases = first_weights };
    layers[1] = .{ .activation = .none, .weights_and_biases = second_weights };
    const feature_means: []f32 = try gpa.dupe(f32, &.{ 0.5, -1.0 });
    const feature_spreads: []f32 = try gpa.dupe(f32, &.{ 2.0, 0.25 });
    const policy: GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = null,
        .action_limit = inf(f32),
        .action_scale = supertrack_action_scale,
        .filter_beta = 1.0,
        .observation = .{ .supertrack_features = .{ .mean = feature_means, .spread = feature_spreads } },
        .decimation = 1,
    };
    return policy;
}

/// A small policy with EfficientTDMPC's layers, made by hand for the file's tests: 3 inputs, a layer-normed Mish
/// layer of 8, a layer-normed SimNorm layer of 8 in groups of 4, and a tanh mean of 2 - no normaliser, as the agent's
/// encoder takes DReCon's observation raw. Every weight, gain and bias set by a formula of its index.
fn handMadeNormedPolicy(gpa: Allocator) !GenoPolicy {
    const widths: []u32 = try gpa.dupe(u32, &.{ 3, 8, 8, 2 });
    const activations = [_]PolicyActivation{ .layer_norm_mish, .layer_norm_simnorm, .tanh };
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, activations.len);
    for (layers, activations, 0..) |*layer, activation, layer_index| {
        const parameter_count: usize = PolicyLayer.parameterCount(
            activation,
            widths[layer_index],
            widths[layer_index + 1],
        );
        const weights_and_biases: []f32 = try gpa.alloc(f32, parameter_count);
        for (weights_and_biases, 0..) |*value, index| {
            value.* = 0.6 - 0.07 * float(index % 17) + 0.01 * float(layer_index);
        }
        layer.* = .{
            .activation = activation,
            .weights_and_biases = weights_and_biases,
            .norm_epsilon = if (activation.isNormed()) 1e-5 else 0,
            .simnorm_group = if (activation == .layer_norm_simnorm) 4 else 0,
        };
    }
    const policy: GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = null,
        .action_limit = 1.0,
        .action_scale = 1.2,
        .filter_beta = 0.2,
        .observation = .drecon,
        .decimation = 2,
    };
    return policy;
}

test "GenoPolicy: a normed policy's file reads back and acts the same; norm settings that cannot be are refused" {
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadeNormedPolicy(gpa);
    defer policy.deinit(gpa);
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    for (policy.layers, read_back.layers) |written, read| {
        try expectEqual(written.activation, read.activation);
        try expectEqual(written.norm_epsilon, read.norm_epsilon);
        try expectEqual(written.simnorm_group, read.simnorm_group);
        try expectEqualSlices(f32, written.weights_and_biases, read.weights_and_biases);
    }
    // The same action, bit for bit.
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const observation = [_]f32{ 0.4, -1.5, 2.25 };
    var written_action: [2]f32 = undefined;
    var read_action: [2]f32 = undefined;
    const written_scratch: PolicyScratch = try .init(arena, &policy);
    const read_scratch: PolicyScratch = try .init(arena, &read_back);
    policyMeanAction(&policy, &observation, written_scratch, &written_action);
    policyMeanAction(&read_back, &observation, read_scratch, &read_action);
    try expectEqualSlices(f32, &written_action, &read_action);
    try expect(written_action[0] != written_action[1]);

    // Norm settings that cannot be, each refused by name: an epsilon of zero on the Mish layer, a group of 3 that does
    // not divide the SimNorm layer's 8 outputs, a group on the Mish layer.
    const layers_at: usize = @sizeOf(PolicyFile.Header) + @sizeOf(PolicyFile.ObservationHeader);
    const first_epsilon_at: usize = layers_at + @offsetOf(PolicyFile.LayerHeader, "norm_epsilon");
    const first_group_at: usize = layers_at + @offsetOf(PolicyFile.LayerHeader, "simnorm_group");
    const first_layer_values: usize = policy.layers[0].weights_and_biases.len * @sizeOf(f32);
    const second_layer_at: usize = layers_at + @sizeOf(PolicyFile.LayerHeader) + first_layer_values;
    const second_group_at: usize = second_layer_at + @offsetOf(PolicyFile.LayerHeader, "simnorm_group");
    const damaged: []u8 = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    const zero_epsilon: f32 = 0;
    @memcpy(damaged[first_epsilon_at..][0..4], asBytes(&zero_epsilon));
    try expectError(error.PolicyNormInvalid, PolicyFile.decode(gpa, damaged));
    @memcpy(damaged, bytes);
    writeInt(u32, damaged[second_group_at..][0..4], 3, .little);
    try expectError(error.PolicyNormInvalid, PolicyFile.decode(gpa, damaged));
    @memcpy(damaged, bytes);
    writeInt(u32, damaged[first_group_at..][0..4], 4, .little);
    try expectError(error.PolicyNormInvalid, PolicyFile.decode(gpa, damaged));
}

test "GenoPolicy: a file names its observation and decision interval; another version, or a bad one, is refused" {
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadePolicy(gpa);
    defer policy.deinit(gpa);
    policy.decimation = 3;
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    try expect(read_back.observation == .drecon);
    try expectEqual(@as(u32, 3), read_back.decimation);
    // A file of another version - the one before this layout, or any other - is refused, not read in an older form.
    const damaged: []u8 = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    const version_at: usize = @offsetOf(PolicyFile.Header, "version");
    writeInt(u32, damaged[version_at..][0..4], PolicyFile.version - 1, .little);
    try expectError(error.PolicyVersionUnknown, PolicyFile.decode(gpa, damaged));
    // An observation this reader does not know, and a decision interval of zero: each refused by its name.
    @memcpy(damaged, bytes);
    const header_size: usize = @sizeOf(PolicyFile.Header);
    const kind_at: usize = header_size + @offsetOf(PolicyFile.ObservationHeader, "kind");
    const decimation_at: usize = header_size + @offsetOf(PolicyFile.ObservationHeader, "decimation");
    writeInt(u32, damaged[kind_at..][0..4], 7, .little);
    try expectError(error.PolicyObservationUnknown, PolicyFile.decode(gpa, damaged));
    @memcpy(damaged, bytes);
    writeInt(u32, damaged[decimation_at..][0..4], 0, .little);
    try expectError(error.PolicyDecimationInvalid, PolicyFile.decode(gpa, damaged));
}

test "GenoPolicy: a SuperTrack policy's file carries its feature statistics; statistics that cannot be are refused" {
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadeSuperTrackPolicy(gpa);
    defer policy.deinit(gpa);
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    const written_features: latent.Normalizer = policy.observation.supertrack_features;
    const read_features: latent.Normalizer = switch (read_back.observation) {
        .supertrack_features => |feature_normalizer| feature_normalizer,
        .drecon => return error.TestExpectedSuperTrackFeatures,
    };
    try expectEqualSlices(f32, written_features.mean, read_features.mean);
    try expectEqualSlices(f32, written_features.spread, read_features.spread);
    try expectEqual(@as(u32, 1), read_back.decimation);
    try expectEqual(inf(f32), read_back.action_limit);
    try expectEqual(@as(f32, 1.0), read_back.filter_beta);
    // A spread of zero - the last four bytes - would divide by zero: refused. So is a feature count that is not half
    // the observation.
    const damaged: []u8 = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    writeInt(u32, damaged[damaged.len - 4 ..][0..4], @bitCast(@as(f32, 0.0)), .little);
    try expectError(error.PolicyFeaturesInvalid, PolicyFile.decode(gpa, damaged));
    @memcpy(damaged, bytes);
    const header_size: usize = @sizeOf(PolicyFile.Header);
    const feature_count_at: usize = header_size + @offsetOf(PolicyFile.ObservationHeader, "feature_count");
    writeInt(u32, damaged[feature_count_at..][0..4], 3, .little);
    try expectError(error.PolicyFeaturesInvalid, PolicyFile.decode(gpa, damaged));
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
    const layers_at: usize = @sizeOf(PolicyFile.Header) + @sizeOf(PolicyFile.ObservationHeader);
    const first_output_at: usize = layers_at + @offsetOf(PolicyFile.LayerHeader, "output_count");
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

test "robot_lab: two clips at once are SuperTrack's - a PPO or EfficientTDMPC run asking for them is refused by name" {
    // `dance_and_getup` trains two clips at once, which only SuperTrack's learner does: the same task with PPO's
    // learner (the default) names the field and why; with SuperTrack's, the run can be trained.
    const with_ppo: GenoRun = .{ .task = .{ .motion = .dance_and_getup } };
    const refusal: ?[]const u8 = with_ppo.problem();
    try expect(refusal != null);
    try expect(startsWith(u8, refusal.?, "task.motion"));
    const with_supertrack: GenoRun = .{ .task = .{ .motion = .dance_and_getup }, .learner = .{ .supertrack = .{} } };
    try expectEqual(@as(?[]const u8, null), with_supertrack.problem());
}

test "SuperTrackLog: the header and every line have the same columns, the device's numbers among them by name" {
    // The log is one definition - the line's fields - so the header's columns and a line's numbers must agree in count
    // and order, every device number a column of its own name, and no name twice.
    const header: []const u8 = SuperTrackLog.header;
    var header_columns: usize = 0;
    var names = splitScalar(u8, header[0 .. header.len - 1], ',');
    var seen_names: [128][]const u8 = undefined;
    while (names.next()) |name| {
        for (seen_names[0..header_columns]) |earlier| {
            try expect(!eql(u8, earlier, name));
        }
        seen_names[header_columns] = name;
        header_columns += 1;
    }
    inline for (@typeInfo(latent_kit.DeviceStats).@"struct".field_names) |device_field_name| {
        try expect(indexOf(u8, header, device_field_name) != null);
    }
    var log: ArrayList(u8) = .empty;
    defer log.deinit(testing_allocator);
    try SuperTrackLog.appendLine(testing_allocator, &log, .{
        .round = 3,
        .training_minutes = 0.5,
        .steps_watched = 640,
        .failures = 2,
        .world_updates = 3,
        .policy_updates = 3,
        .pushes = 4,
        .push_mean_speed = 1.25,
        .device = .{ .world_model_loss = 0.125, .critic_value_error = 2.5 },
    });
    const line: []const u8 = log.items[0 .. log.items.len - 1];
    const line_columns: usize = std.mem.count(u8, line, ",") + 1;
    try expectEqual(header_columns, line_columns);
}

test "JudgeLog.collapsedClip: a clip once better than the servo, then no better three times running - and only that" {
    // Judgements of 10 failures each, their times set by the steps watched (60 steps a second): the servo keeps every
    // clip 1 s. The dance's policy starts below it (untrained - not a collapse), rises to 1.5 s, then falls to 0.8 s
    // three judgements running: collapsed. The get-up's never rises above the servo: not learning yet, but no
    // collapse. The walk's rises, then falls only twice: not yet.
    const Judged = struct {
        /// A judgement of 10 starts and 10 failures keeping the reference `seconds` on average.
        fn of(seconds: f32) robot_track.Judgement {
            const frame_time: f32 = 1.0 / 60.0;
            const watched_steps: usize = @round(seconds * 10 / frame_time);
            const judgement: robot_track.Judgement = .{
                .starts = 10,
                .failures = 10,
                .reached_end = 0,
                .watched_steps = watched_steps,
                .reward_sum = 0,
                .tracked_steps_squares = 0,
                .failed_starts_steps = 0,
                .tracked_share_sum = 0,
                .tracked_share_squares = 0,
                .frame_time = frame_time,
            };
            return judgement;
        }
    };
    var text: ArrayList(u8) = .empty;
    defer text.deinit(testing_allocator);
    const clips = [_][]const u8{ "dance", "get-up", "walk" };
    const histories = [_][]const f32{
        &.{ 0.5, 1.5, 0.8, 0.8, 0.8 },
        &.{ 0.5, 0.6, 0.7, 0.8, 0.9 },
        &.{ 1.5, 0.8, 0.8 },
    };
    for (clips) |clip| {
        try JudgeLog.appendLine(testing_allocator, &text, 0, 0, clip, Judged.of(1.0));
    }
    for (clips, histories) |clip, history| {
        for (history, 1..) |seconds, judgement_index| {
            try JudgeLog.appendLine(testing_allocator, &text, judgement_index * 100, 0, clip, Judged.of(seconds));
        }
    }
    const collapsed: []const u8 = JudgeLog.collapsedClip(text.items, &clips, 3) orelse "";
    try expect(eql(u8, "dance", collapsed));
    // Only the get-up and the walk: neither has collapsed.
    const others = [_][]const u8{ "get-up", "walk" };
    try expectEqual(@as(?[]const u8, null), JudgeLog.collapsedClip(text.items, &others, 3));
}
