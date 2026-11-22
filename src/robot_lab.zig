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
const sortSlice = std.mem.sort;
const ascending = std.sort.asc;
const zm = @import("zm");
const isFinite = zm.isFinite;
const tanh = zm.tanh;
const mish = zm.mish;
const silu = zm.silu;
const sinRad = zm.sinRad;
const cosRad = zm.cosRad;
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
const rbt = @import("robot");
const Allocator = std.mem.Allocator;
const bufPrint = std.fmt.bufPrint;
const comptimePrint = std.fmt.comptimePrint;
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
const float64 = zm.float64;
const pi = zm.pi;
const nan = zm.nan;
const inf = zm.inf;
const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const writeInt = std.mem.writeInt;
const zeroes = std.mem.zeroes;
const endsWith = std.mem.endsWith;
const geno = @import("robot_geno.zig");
const report = @import("test_report.zig");
const resident = @import("robot_track_resident.zig");
const kit_mlp = @import("kit_mlp.zig");
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

/// The recipe today. Each field is a decision the tracking plan recorded (`src/notes/archive/rl_track_plan_v6.md`),
/// and the tests right below hold each one against its REASON rather than against its number:
///   * 0.6 rad a unit (`supertrack_action_scale`) - C1 weighs it against the paper's 2.09;
///   * exploration noise of 0.1 of a unit - C1 again (the paper's sigma, in its units);
///   * a decision every 2 physics steps: 30 Hz over Geno's 60 Hz physics (F4e) - DReCon's clock;
///   * the action filter at 0.2, inside training too (F6a) - DReCon's filter;
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

// ==== ONE DEFINITION OF GENO'S TASK ====
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
/// ONE VARIANT OF A CLIP: its mirror image or not, and the speed it plays at - 1 for the clip's own.
pub const ClipVariant = struct {
    mirrored: bool,
    speed: f32,

    /// Whether this is the clip itself: unmirrored, at its own speed.
    pub fn isTheClip(variant: ClipVariant) bool {
        return !variant.mirrored and variant.speed == 1;
    }

    /// The label a variant's lines carry: its clip's, then "mirrored" for a mirror image and the speed for a copy at
    /// another - "dance", "dance mirrored", "dance at 0.8", "dance mirrored at 1.2". In `arena`.
    pub fn label(
        variant: ClipVariant,
        arena: Allocator,
        clip_label: []const u8,
    ) Allocator.Error![]const u8 {
        const mirror_text: []const u8 = if (variant.mirrored) " mirrored" else "";
        if (variant.speed == 1) {
            return allocPrint(arena, "{s}{s}", .{ clip_label, mirror_text });
        }
        return allocPrint(arena, "{s}{s} at {d:.1}", .{ clip_label, mirror_text, variant.speed });
    }
};

/// THE CLIPS' VARIANTS a run trains on beside the clips themselves (H2): each clip's mirror image - left for right,
/// baked beside it (`robot_geno.copyMirroredClip`) - and each of the two played slower and faster by `speed_change`
/// (`robot_geno.clipAtSpeed`): 0.2 is the motion at 0.8 and at 1.2 of its speed, a flight's included. A variant trains
/// beside its clip and is logged as its own; the judgement is the clips' own, never a variant's (H1).
pub const ClipVariants = struct {
    mirrored: bool = false,
    /// How much slower and faster the speed copies play: 0 for none, below 0.5.
    speed_change: f32 = 0,

    /// The most variants of one clip, itself among them: both sides, each at three speeds.
    pub const most_per_clip: usize = 6;

    /// Every variant of a clip these settings ask for, the clip itself first: each side - the clip's own, then its
    /// mirror image - at its own speed, then slower, then faster. In `out`; the variants returned are its first.
    pub fn list(variants: ClipVariants, out: *[most_per_clip]ClipVariant) []const ClipVariant {
        const side_count: usize = if (variants.mirrored) 2 else 1;
        const has_speeds: bool = variants.speed_change > 0;
        var count: usize = 0;
        for (0..side_count) |side| {
            const mirrored: bool = side == 1;
            out[count] = .{ .mirrored = mirrored, .speed = 1 };
            count += 1;
            if (!has_speeds) {
                continue;
            }
            out[count] = .{ .mirrored = mirrored, .speed = 1 - variants.speed_change };
            out[count + 1] = .{ .mirrored = mirrored, .speed = 1 + variants.speed_change };
            count += 2;
        }
        return out[0..count];
    }

    /// What makes these variants impossible, naming the field by `prefix` and the range it must be in - or null.
    pub fn problem(variants: ClipVariants, comptime prefix: []const u8) ?[]const u8 {
        const change: f32 = variants.speed_change;
        const change_in_range: bool = isFinite(change) and change >= 0 and change < 0.5;
        if (!change_in_range) {
            return prefix ++ "speed_change: 0 (none) or more, below 0.5";
        }
        return null;
    }
};

pub const GenoRunTask = struct {
    motion: GenoMotion = .dance,
    /// The variants trained beside the motion's clips: none by default.
    variants: ClipVariants = .{},
};

/// PPO's recipe in a `GenoRun`: every field of `PpoRecipe`, its decision interval and DReCon's filter included - PPO
/// decides every `decimation` physics steps (DReCon's 30 Hz over Geno's 60 Hz physics), and each decision a joint's
/// target moves the share `beta` of the way to the new action (always 0.2). Defaulted to `PpoRecipe`'s values.
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
/// WHERE A SUPERTRACK RUN's CHARACTERS ARE SIMULATED. On the CPU, a fleet of `characters` (`robot_track.Fleet`): each
/// decision the host steps every character and records its state into the learner's replay. Or on the device
/// (`robotgpu`): the characters are worlds of the GPU's simulator, which acts through the learner's policy, packs each
/// world's record and copies it into the learner's ring on the GPU, the host keeping only the books of which records
/// belong together, from the flags the device reports (`robot_track.KeptBooks`).
pub const TrainingPhysics = enum { cpu_fleet, device };

/// THE TEACHER OF A SUPERTRACK RUN ON THE DEVICE (`SuperTrackLearner.teacher`): planners among the characters. At
/// every replan each planner's state is copied into a block of candidate worlds, each candidate lives a plan drawn
/// about the planner's last through the simulator's own physics, and the best of them becomes the planner's plan.
/// What the planners then do is the policy's teacher: the actions they take from their plans are labels the policy
/// is distilled toward (`robot_track_resident.Phases`), and the candidates' lookaheads - many actions from one state
/// - are batches for the world model and the measure of its gate (`robot_track_resident.Gate`).
///
/// The candidates are worlds of the simulator beside the characters: a run with P planners of C candidates simulates
/// P x C worlds more.
pub const Teacher = struct {
    /// How many of the characters plan - the first of them, so that with several clips, each character on the clip
    /// of its index, the planners are spread over the clips. 0: no teacher.
    planners: u32 = 0,
    /// The newest lookaheads the learner keeps of every candidate (`robot_track_resident.CandidateRecording`): what
    /// the world model's batches of candidates are drawn from, and - those no update has drawn yet - its gate's
    /// windows.
    lookaheads_kept: u32 = 8,
    /// How the planners plan (`robot.PlanningOptions`): the candidates each runs ahead, how often it replans, how
    /// often it follows a plan whole, and how its candidates are drawn.
    planning: rbt.PlanningOptions = .{},
};

pub const SuperTrackLearner = struct {
    /// Radians of joint offset per unit of action (`robot_geno.supertrack_action_scale`).
    action_scale: f32 = supertrack_action_scale,
    /// Characters simulated side by side while collecting, each living its own episodes: the fleet's size. Four is
    /// sized for a phone: Geno's physics step costs about 0.6 ms there, and a round of eight characters (16 collected
    /// steps each) overran the page's frame budget before the GPU had done anything. A desktop trainer can afford more.
    characters: u32 = 4,
    /// Where the characters are simulated (`TrainingPhysics`): the CPU fleet unless the run asks for the device.
    physics: TrainingPhysics = .cpu_fleet,
    /// Whether the action carries a stiffness per limb after the joints' offsets, each limb's servo at the stiffness
    /// its character's action gives it (`robot_track.Fleet.Options.limb_stiffness`). Off, the action is the offsets
    /// alone and every limb is at the servo's own stiffness.
    limb_stiffness: bool = false,
    /// Simulation steps each character's replay keeps: what windows are drawn from. The training page's 256.
    replay_steps: u32 = 256,
    /// THE CLOCK (`robot_track.Fleet.Options.decide_every`): physics steps per decision - 2 for the policy and the
    /// world model at 30 Hz over 60 Hz physics. Every count of steps in a recipe then counts decisions.
    decide_every: u32 = (robot_track.Fleet.Options{}).decide_every,
    /// The longest episode, in decisions (`robot_track.Fleet.Options.max_steps`): 300 at 30 Hz is 10 s.
    max_steps: u32 = (robot_track.Fleet.Options{}).max_steps,
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
    /// The world model's form - SuperTrack's two tanh layers, or the normed form's SiLU layers, this many of them -
    /// as the learner's own options say (`robot_track_resident.Options.world_form`).
    world_form: resident.WorldModelForm = (resident.Options{}).world_form,
    world_hidden_layers: u32 = (resident.Options{}).world_hidden_layers,
    /// The world model's updates alone before the policy's first rollout through it
    /// (`robot_track_resident.Options.world_alone_updates`): 0 for none.
    world_alone_updates: u32 = (resident.Options{}).world_alone_updates,
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
    /// The world model's skip head and its projection (`robot_track_resident.Options.skip_steps`,
    /// `projection_steps`): no skip head by default.
    skip_steps: u32 = (resident.Options{}).skip_steps,
    projection_steps: u32 = (resident.Options{}).projection_steps,
    /// The skip head's share of the world model's updates (`robot_track_resident.Options.skip_batch_share`).
    skip_batch_share: f32 = (resident.Options{}).skip_batch_share,
    /// Muon on the policy's hidden matrix (`robot_track_resident.Options.policy_muon`); the world model's always.
    policy_muon: bool = (resident.Options{}).policy_muon,
    /// The root target in the policy's goal (`robot_track_resident.Options.root_target`): off, its slots zero. With
    /// it, the root's cost in the policy's loss, its shares of the bodies' weight
    /// (`robot_track_resident.Options.root_cost`).
    root_target: bool = (resident.Options{}).root_target,
    root_cost: robot_track.RootCostShares = (resident.Options{}).root_cost,
    /// The policy's skip steps after its single ones (`robot_track_resident.Options.policy_skip_steps`).
    policy_skip_steps: u32 = (resident.Options{}).policy_skip_steps,
    /// The skip head's consistency and its target's decay (`robot_track_resident.Options.skip_consistency_share`,
    /// `world_average_decay`).
    skip_consistency_share: f32 = (resident.Options{}).skip_consistency_share,
    world_average_decay: f32 = (resident.Options{}).world_average_decay,
    /// The world model's running statistics: its change's floors, the epsilons its spreads take and its moments'
    /// limit (`robot_track_resident.Options.world_statistics`).
    world_statistics: resident.WorldStatistics = (resident.Options{}).world_statistics,
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
    /// The action filter: the share of the chosen action in the action the fleet is given at each decision, the rest
    /// the action given before (`robot_track_resident.Options.filter`). 1 is no filter.
    filter: f32 = (resident.Options{}).filter,
    /// The action filter's share for the limbs' stiffnesses, as `filter` is the joints' offsets'
    /// (`robot_track_resident.Options.stiffness_filter`). 1 is no filter.
    stiffness_filter: f32 = (resident.Options{}).stiffness_filter,
    /// Whether the policy sees the action applied before its decision (`robot_track_resident.Options.sees_applied`).
    sees_applied: bool = (resident.Options{}).sees_applied,
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
    /// The share of the world model's updates on a planner's candidates' lookaheads, while the learner records them
    /// (`robot_track_resident.Options.candidate_batch_share`).
    candidate_batch_share: f32 = (resident.Options{}).candidate_batch_share,
    /// The weight of the policy's distillation toward the planners' labels, beside its rollout's
    /// (`robot_track_resident.Options.label_weight`).
    label_weight: f32 = (resident.Options{}).label_weight,
    /// The policy's slow average's decay (`robot_track_resident.Options.policy_average_decay`): what the judge, the
    /// probes and the policy file read. 0: none.
    policy_average_decay: f32 = (resident.Options{}).policy_average_decay,
    /// The training's two phases: the teacher alone, then the world model's gradient ramped in
    /// (`robot_track_resident.Phases`).
    phases: resident.Phases = .{},
    /// The teacher's planners, for a run on the device (`Teacher`): none by default.
    teacher: Teacher = .{},
    /// One round: this many simulation steps, then this many updates of each network.
    collect: u32 = 16,
    world_updates: u32 = 1,
    policy_updates: u32 = 1,
    seed: u64 = (resident.Options{}).seed,
    /// The warm-up: decisions collected before the first update (`robot_track_resident.Options.warmup_decisions`) -
    /// the foundation's 256; at most the replay's length. 0: none.
    warmup_decisions: u32 = (resident.Options{}).warmup_decisions,
    /// The policy's rate boost (`robot_track_resident.RateBoost`): XMimic's multiplier 4 for 1,400 rounds, then a ramp
    /// over 300; off by default.
    policy_rate_boost: resident.RateBoost = .{},

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
    graced_task.termination.grace_steps = learner.options().horizonDecisions();
    return graced_task;
}

// Every option of the GPU learner is a field of `SuperTrackLearner`, with the same type, and every field of the learner
// but the fleet's (the action scale, the characters and where they are simulated, the limbs' stiffness, the replay's
// length, the pushes, the aftermath) and the teacher's planners is an option:
// checked when the file compiles, so that an option added to the learner reaches the run file, and a run file never
// holds a setting nothing reads.
comptime {
    // Every field's name against the fleet's fourteen, character by character: more than the default quota.
    @setEvalBranchQuota(4000);
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
            eql(u8, field_name, "return_steps") or eql(u8, field_name, "decide_every") or
            eql(u8, field_name, "max_steps") or
            eql(u8, field_name, "curriculum") or eql(u8, field_name, "physics_threads") or
            eql(u8, field_name, "physics") or eql(u8, field_name, "limb_stiffness") or
            eql(u8, field_name, "teacher");
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

/// What makes a teacher's settings impossible (`Teacher`), named under `prefix` (`learner.supertrack.teacher.` in a
/// `GenoRun`) - nothing without planners; with them: no more planners than `characters`, two candidates a planner at
/// least, a replan every decision or less often, a lookahead kept, a following share that is a share, a drawing
/// whose noises are zero or more and whose reach is above zero, and planners chosen by trouble no more than the
/// planners, around the policy, their trouble projected zero or more decisions.
fn teacherProblem(
    comptime prefix: []const u8,
    teacher: Teacher,
    characters: u32,
) ?[]const u8 {
    if (teacher.planners == 0) {
        return null;
    }
    if (teacher.planners > characters) {
        return prefix ++ "planners: at most the characters - a planner is a character";
    }
    const planning: rbt.PlanningOptions = teacher.planning;
    // A planner chooses among its candidates: its warm start, and one drawn about it at least - and the world
    // model's gate measures it on two candidates of one replan.
    if (planning.candidates_per_planner < 2) {
        return prefix ++ "planning.candidates_per_planner: 2 or more - the warm start and a candidate drawn about it";
    }
    if (planning.replan_interval == 0) {
        return prefix ++ "planning.replan_interval: 1 or more decisions";
    }
    if (teacher.lookaheads_kept == 0) {
        return prefix ++ "lookaheads_kept: 1 or more";
    }
    // A NaN is no share: it fails both comparisons.
    const is_share: bool = planning.plan_following_share >= 0 and planning.plan_following_share <= 1;
    if (!is_share) {
        return prefix ++ "planning.plan_following_share: from 0 to 1";
    }
    const drawing: rbt.PlanDrawing = planning.drawing;
    const noises = [_]f32{ drawing.offset_noise_radians, drawing.stiffness_noise };
    const noise_problems = [_][]const u8{
        prefix ++ "planning.drawing.offset_noise_radians: 0 or more",
        prefix ++ "planning.drawing.stiffness_noise: 0 or more",
    };
    for (noises, noise_problems) |noise, noise_problem| {
        const is_noise_usable: bool = noise >= 0 and isFinite(noise);
        if (!is_noise_usable) {
            return noise_problem;
        }
    }
    const is_reach_usable: bool = drawing.offset_reach_radians > 0 and isFinite(drawing.offset_reach_radians);
    if (!is_reach_usable) {
        return prefix ++ "planning.drawing.offset_reach_radians: above 0";
    }
    // The planners chosen by trouble take the blocks of the teacher's planners, and start from the policy itself.
    if (planning.trouble_planners > teacher.planners) {
        return prefix ++ "planning.trouble_planners: at most the planners - each takes a planner's block of candidates";
    }
    const chooses_by_trouble: bool = planning.trouble_planners > 0;
    if (chooses_by_trouble and planning.phase_two_form != .offsets_around_policy) {
        return prefix ++ "planning.trouble_planners: a planner chosen anew starts from the policy - plans around it " ++
            "(phase_two_form .offsets_around_policy)";
    }
    const lookahead: f32 = planning.trouble_lookahead_decisions;
    const is_lookahead_usable: bool = lookahead >= 0 and isFinite(lookahead);
    if (!is_lookahead_usable) {
        return prefix ++ "planning.trouble_lookahead_decisions: 0 or more";
    }
    // The plans the flow learns from: a share of them, ranked in a window of at least one.
    const teach_share: f32 = planning.teach_share;
    const is_teach_share_usable: bool = teach_share > 0 and teach_share <= 1;
    if (!is_teach_share_usable) {
        return prefix ++ "planning.teach_share: above 0, at most 1";
    }
    if (planning.teach_window == 0) {
        return prefix ++ "planning.teach_window: at least 1";
    }
    return null;
}

/// What makes a run's pushes impossible (`robot_track.Pushes`), named under `prefix`: a rate of 0 or more; speeds of
/// 0 or more, the top no lower than the bottom; a line's hours of 0 or more; shares from 0 to 1 - the starts in
/// trouble, the brake's bar and its watched share, which cannot be 0; a watch and a window above 0; and a catch-up
/// pace of 1 or more - slower than the clock's line, a top once held would never be back on it.
fn pushesProblem(comptime prefix: []const u8, pushes: robot_track.Pushes) ?[]const u8 {
    const brake: rbt.PushBrake = pushes.brake;
    const zero_or_more = [_]f32{ pushes.rate_per_second, pushes.speed_min, pushes.full_hours };
    const zero_or_more_problems = [_][]const u8{
        prefix ++ "rate_per_second: 0 or more",
        prefix ++ "speed_min: 0 or more",
        prefix ++ "full_hours: 0 or more",
    };
    for (zero_or_more, zero_or_more_problems) |number, number_problem| {
        const is_zero_or_more: bool = number >= 0 and isFinite(number);
        if (!is_zero_or_more) {
            return number_problem;
        }
    }
    const is_top_above_bottom: bool = pushes.speed_max >= pushes.speed_min and isFinite(pushes.speed_max);
    if (!is_top_above_bottom) {
        return prefix ++ "speed_max: at least speed_min";
    }
    const shares = [_]f32{ pushes.start_share, brake.come_back_bar, brake.watched_share };
    const share_problems = [_][]const u8{
        prefix ++ "start_share: from 0 to 1",
        prefix ++ "brake.come_back_bar: from 0 to 1",
        prefix ++ "brake.watched_share: above 0, to 1",
    };
    for (shares, share_problems) |share, share_problem| {
        // A NaN is no share: it fails both comparisons.
        const is_share: bool = share >= 0 and share <= 1;
        if (!is_share) {
            return share_problem;
        }
    }
    if (brake.watched_share == 0) {
        return prefix ++ "brake.watched_share: above 0, to 1";
    }
    const above_zero = [_]f32{ brake.watch_seconds, brake.window_minutes };
    const above_zero_problems = [_][]const u8{
        prefix ++ "brake.watch_seconds: above 0",
        prefix ++ "brake.window_minutes: above 0",
    };
    for (above_zero, above_zero_problems) |number, number_problem| {
        const is_above_zero: bool = number > 0 and isFinite(number);
        if (!is_above_zero) {
            return number_problem;
        }
    }
    const is_pace: bool = brake.catch_up_pace >= 1 and isFinite(brake.catch_up_pace);
    if (!is_pace) {
        return prefix ++ "brake.catch_up_pace: 1 or more";
    }
    return null;
}

/// What makes SuperTrack's settings impossible to train, named under `prefix` (`learner.supertrack.` in a `GenoRun`):
/// a positive, finite action scale and step sizes; noise and prices of zero or more; at least one window per update
/// and one step per window, a unit in each network, a step per round and an update of each network per round.
/// The first of the world model's statistics' numbers that is unusable (`resident.WorldStatistics`), named after
/// `prefix`: every floor, the epsilon and the limit must be finite and above 0. Null when all are.
fn worldStatisticsProblem(comptime prefix: []const u8, statistics: resident.WorldStatistics) ?[]const u8 {
    const number_names = [_][]const u8{
        "position_floor",
        "rotation_floor",
        "up_floor",
        "velocity_floor",
        "angular_velocity_floor",
        "change_epsilon",
        "inputs_epsilon",
        "moments_limit",
    };
    inline for (number_names) |number_name| {
        const number: f32 = @field(statistics, number_name);
        const usable: bool = number > 0 and isFinite(number);
        if (!usable) {
            return prefix ++ number_name ++ ": above 0";
        }
    }
    return null;
}

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
    // With phases, the world model's gate measures it on pairs of windows - two candidates of one replan - so its
    // rows come in pairs (`resident.CandidateRecording.drawPairStarts`).
    const rows_in_pairs: bool = learner.rows % 2 == 0;
    if (learner.phases.enabled and !rows_in_pairs) {
        return prefix ++ "rows: an even number with phases - the gate's windows come in pairs";
    }
    // A window is drawn from one character's replay, so the replay must hold more than a window.
    if (learner.replay_steps <= learner.window) {
        return prefix ++ "replay_steps: more than window";
    }
    // The warm-up ends when every character's ring holds its decisions: past the replay's length it never would.
    if (learner.warmup_decisions > learner.replay_steps) {
        return prefix ++ "warmup_decisions: at most replay_steps";
    }
    // The boost multiplies the policy's rate: a number above 0 (1 for none).
    const boost_multiplier: f32 = learner.policy_rate_boost.multiplier;
    const boost_usable: bool = boost_multiplier > 0 and isFinite(boost_multiplier);
    if (!boost_usable) {
        return prefix ++ "policy_rate_boost.multiplier: above 0";
    }
    // The action filter's shares - the joints' offsets' and the limbs' stiffnesses' - each a share of the new action;
    // imagination passes its actions through the same filter (the kit's `filter`), so any share trains.
    const filter_in_range: bool = learner.filter > 0.0 and learner.filter <= 1.0;
    if (!filter_in_range) {
        return prefix ++ "filter: above 0, at most 1";
    }
    const stiffness_filter_in_range: bool = learner.stiffness_filter > 0.0 and learner.stiffness_filter <= 1.0;
    if (!stiffness_filter_in_range) {
        return prefix ++ "stiffness_filter: above 0, at most 1";
    }
    // The change's floors are errors no smaller than which a feature is judged, the epsilons what each spread takes
    // for a number that never moves, and the limit how many transitions the moments take: all above 0.
    if (worldStatisticsProblem(prefix ++ "world_statistics.", learner.world_statistics)) |problem| {
        return problem;
    }
    // The heads' projection is at least two decisions on, and at most 20 (two thirds of a second at 30 a second).
    const projection_in_range: bool = learner.projection_steps >= 2 and learner.projection_steps <= 20;
    if (!projection_in_range) {
        return prefix ++ "projection_steps: from 2 to 20 decisions";
    }
    // The skip head's step reaches at most the projection - a lerp toward it, not past it - and is more than one
    // decision, the one-step head's.
    const skip_in_range: bool = learner.skip_steps == 0 or
        (learner.skip_steps >= 2 and learner.skip_steps <= learner.projection_steps);
    if (!skip_in_range) {
        return prefix ++ "skip_steps: 0, or from 2 to projection_steps";
    }
    // The skip head's batches are the world model's windows rolled in its steps: at least one fits.
    if (learner.skip_steps > learner.window) {
        return prefix ++ "skip_steps: at most window - the skip head's batches are its steps over a window";
    }
    const skip_share_in_range: bool = learner.skip_batch_share >= 0 and learner.skip_batch_share <= 1;
    if (!skip_share_in_range) {
        return prefix ++ "skip_batch_share: from 0 to 1";
    }
    // Muon steps the matrices inside the two networks' clipped optimisers.
    // The world model's gradient is always bounded (XMimic's 1); the policy's Muon needs the policy's bound.
    const world_clip_usable: bool = learner.world_gradient_clip > 0 and isFinite(learner.world_gradient_clip);
    if (!world_clip_usable) {
        return prefix ++ "world_gradient_clip: above 0";
    }
    const policy_muon_without_clip: bool = learner.policy_muon and learner.policy_gradient_clip == 0;
    if (policy_muon_without_clip) {
        return prefix ++ "policy_muon: needs policy_gradient_clip above 0";
    }
    // The kit's blocks are the policy's steps, single and skip together: the world model's window must fit in them.
    if (learner.options().horizon() < learner.window) {
        return prefix ++ "policy_window: its steps and the skip steps (policy_skip_steps) together at least window";
    }
    // The policy steps through the skip head; at most 16 such steps (a horizon of 64 decisions at a skip of 4).
    if (learner.policy_skip_steps > 0 and learner.skip_steps == 0) {
        return prefix ++ "policy_skip_steps: the policy's skip steps need the skip head (skip_steps)";
    }
    if (learner.policy_skip_steps > 16) {
        return prefix ++ "policy_skip_steps: at most 16";
    }
    // The critic's imagined fit reads the policy's rollout one decision a step: not through skips.
    const imagined_through_skips: bool = learner.policy_skip_steps > 0 and learner.critic.imagined_share > 0;
    if (imagined_through_skips) {
        return prefix ++ "critic.imagined_share: 0 when the policy steps through skips (policy_skip_steps)";
    }
    const consistency_in_range: bool = learner.skip_consistency_share >= 0 and learner.skip_consistency_share <= 1;
    if (!consistency_in_range) {
        return prefix ++ "skip_consistency_share: from 0 to 1";
    }
    const world_decay_in_range: bool = learner.world_average_decay >= 0 and learner.world_average_decay < 1;
    if (!world_decay_in_range) {
        return prefix ++ "world_average_decay: 0 or more, below 1";
    }
    // The skip head is a last layer beside the dense world model's.
    if (learner.skip_steps > 0 and learner.world_form != .dense_tanh) {
        return prefix ++ "skip_steps: the skip head needs the dense world model (world_form .dense_tanh)";
    }
    // The skip head learns from the world model's windows: a jump must fit in one, and span more than one step.
    if (learner.skip_span > learner.window) {
        return prefix ++ "skip_span: at most window";
    }
    if (learner.skip_span == 1) {
        return prefix ++ "skip_span: 0 for none, or at least 2 - one step is the world model's own";
    }
    // The skip head reads the dense world model's second hidden layer; the normed form holds 1 to 4 hidden layers.
    if (learner.skip_span > 0 and learner.world_form != .dense_tanh) {
        return prefix ++ "skip_span: 0 with the world model in the normed form - the skip head reads the tanh form";
    }
    const max_hidden_layers: u32 = latent_kit.WorldForm.NormedSilu.max_hidden_layers;
    const hidden_layers: u32 = learner.world_hidden_layers;
    const hidden_layers_fit: bool = hidden_layers >= 1 and hidden_layers <= max_hidden_layers;
    if (learner.world_form == .normed_silu and !hidden_layers_fit) {
        return prefix ++ comptimePrint("world_hidden_layers: 1 to {d} in the normed form", .{max_hidden_layers});
    }
    const rates = [_]f32{ learner.world_rate, learner.policy_rate };
    const rate_problems = [_][]const u8{ prefix ++ "world_rate: above 0", prefix ++ "policy_rate: above 0" };
    for (rates, rate_problems) |rate, rate_problem| {
        const is_rate_usable: bool = rate > 0 and isFinite(rate);
        if (!is_rate_usable) {
            return rate_problem;
        }
    }
    const is_average_decay: bool = learner.policy_average_decay >= 0 and learner.policy_average_decay < 1;
    if (!is_average_decay) {
        return prefix ++ "policy_average_decay: 0 or more, below 1";
    }
    const prices = [_]f32{ learner.sigma, learner.w_action, learner.w_smooth, learner.label_weight };
    const price_problems = [_][]const u8{
        prefix ++ "sigma: 0 or more",
        prefix ++ "w_action: 0 or more",
        prefix ++ "w_smooth: 0 or more",
        prefix ++ "label_weight: 0 or more",
    };
    for (prices, price_problems) |price, price_problem| {
        const is_price_usable: bool = price >= 0 and isFinite(price);
        if (!is_price_usable) {
            return price_problem;
        }
    }
    // Shares are from none to all; the phases' minutes are minutes.
    const phases: resident.Phases = learner.phases;
    const shares = [_]f32{
        learner.candidate_batch_share,
        phases.label_share_after_ramp,
        phases.phase_one_candidate_batch_share,
    };
    const share_problems = [_][]const u8{
        prefix ++ "candidate_batch_share: from 0 to 1",
        prefix ++ "phases.label_share_after_ramp: from 0 to 1",
        prefix ++ "phases.phase_one_candidate_batch_share: from 0 to 1",
    };
    for (shares, share_problems) |share, share_problem| {
        // A NaN is no share: it fails both comparisons.
        const is_share: bool = share >= 0 and share <= 1;
        if (!is_share) {
            return share_problem;
        }
    }
    const minutes = [_]f32{ phases.phase_one_minutes, phases.ramp_minutes, phases.gate.measure_every_minutes };
    const minute_problems = [_][]const u8{
        prefix ++ "phases.phase_one_minutes: 0 or more",
        prefix ++ "phases.ramp_minutes: 0 or more",
        prefix ++ "phases.gate.measure_every_minutes: 0 or more",
    };
    for (minutes, minute_problems) |minute_count, minute_problem| {
        const are_minutes: bool = minute_count >= 0 and isFinite(minute_count);
        if (!are_minutes) {
            return minute_problem;
        }
    }
    // The gate's bars: an error's share is 0 or more, a cosine from -1 to 1, and a band at least 1 - narrower, it
    // would hold no ratio at all.
    const gate: resident.Gate = phases.gate;
    const is_error_share: bool = gate.state_error_ratio_bar >= 0 and isFinite(gate.state_error_ratio_bar);
    if (!is_error_share) {
        return prefix ++ "phases.gate.state_error_ratio_bar: 0 or more";
    }
    const is_cosine: bool = gate.response_cosine_bar >= -1 and gate.response_cosine_bar <= 1;
    if (!is_cosine) {
        return prefix ++ "phases.gate.response_cosine_bar: from -1 to 1";
    }
    const is_band: bool = gate.response_ratio_band >= 1 and isFinite(gate.response_ratio_band);
    if (!is_band) {
        return prefix ++ "phases.gate.response_ratio_band: 1 or more";
    }
    if (pushesProblem(prefix ++ "pushes.", learner.pushes)) |pushes_problem| {
        return pushes_problem;
    }
    // The critic's two lambdas: a trace's share kept each decision, from 0 to 1. A NaN fails both comparisons.
    const lambdas = [_]f32{ learner.critic.real_lambda, learner.critic.imagined_lambda };
    const lambda_problems = [_][]const u8{
        prefix ++ "critic.real_lambda: from 0 to 1",
        prefix ++ "critic.imagined_lambda: from 0 to 1",
    };
    for (lambdas, lambda_problems) |lambda, lambda_problem| {
        const is_lambda: bool = lambda >= 0 and lambda <= 1;
        if (!is_lambda) {
            return lambda_problem;
        }
    }
    return teacherProblem(prefix ++ "teacher.", learner.teacher, learner.characters);
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
    /// A SuperTrack run's state checkpoints kept at once, the newest, beside its policy checkpoints: each holds every
    /// weight and the optimisers' moments - tens of megabytes for a full recipe - and is what a run goes back to when
    /// its newest state is not the one wanted. Zero keeps the policies alone: the lab's timeline of the run, which
    /// plays policies, is whole without them. At most `most_kept_state_checkpoints`.
    kept_state_checkpoints: u8 = 4,
    /// Minutes between the judge's verdicts on the newest policy, written to the folder's judge.csv.
    judge_minutes: f32 = (PpoRun{}).judge_minutes,
    /// The run stops by itself after this many hours of training, or this many updates; zero is never.
    stop_after_hours: f32 = (PpoRun{}).stop_after_hours,
    stop_after_updates: u64 = (PpoRun{}).stop_after_batches,
    /// How every judgement's recovery probe pushes and watches (`robot_track.RecoveryProbe`, `recovery.csv`): pushes
    /// of 1 to 5 m/s, and a character that loses the reference followed five seconds for a return to it.
    probe: robot_track.RecoveryProbe = .{ .speeds = &.{ 1, 2, 3, 4, 5 }, .return_seconds = 5 },
    /// TIME EVERY DISPATCH ON THE DEVICE, for a SuperTrack run: each kernel's summed time and count, written to the
    /// folder's `kernel_times.csv` (`KernelTimeLog`) with every save. Off, a run times its rounds by phase alone
    /// (`RoundTimeLog`), with a few timestamps a submission; on, with one a dispatch - a profile's setting, not a
    /// long run's.
    kernel_times: bool = false,

    /// The most state checkpoints a run keeps at once (`kept_state_checkpoints`).
    pub const most_kept_state_checkpoints: u8 = 8;
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
            // Phase 1 is the teacher's labels alone, and labels come from planners, which act on the device.
            if (settings.phases.enabled and settings.physics != .device) {
                return "learner.supertrack.phases.enabled: the teacher's labels come from planners on the device " ++
                    "(physics .device)";
            }
            // A device's worlds carry a stiffness per limb in every action and record (`robotgpu.Counts.action_count`).
            if (settings.physics == .device and !settings.limb_stiffness) {
                return "learner.supertrack.limb_stiffness: a device's actions and records carry a stiffness per " ++
                    "limb (limb_stiffness true with physics .device)";
            }
            // The teacher's planners look ahead through the device's physics.
            const has_teacher: bool = settings.teacher.planners > 0;
            if (has_teacher and settings.physics != .device) {
                return "learner.supertrack.teacher.planners: the planners look ahead on the device (physics .device)";
            }
            // Phase 1 is the planners' labels alone: without planners the policy would learn nothing in it.
            if (settings.phases.enabled and !has_teacher) {
                return "learner.supertrack.phases.enabled: phase 1 is the teacher's labels - a run with phases has " ++
                    "planners (teacher.planners above 0)";
            }
            // The planners are chosen by trouble from phase 2 on: a run without phases never reaches it.
            const chooses_by_trouble: bool = has_teacher and settings.teacher.planning.trouble_planners > 0;
            if (chooses_by_trouble and !settings.phases.enabled) {
                return "learner.supertrack.teacher.planning.trouble_planners: the planners are chosen by trouble " ++
                    "from phase 2 on - a run with them has phases (phases.enabled)";
            }
            // On the device the search through the world model plans, from phase 2, for the physics' planners - its
            // plans seed theirs (the funnel) - and the characters in most trouble after them, chosen at the teacher's
            // replans, its plans in the flow's place: it needs the teacher, the phases and a flow actor, and room for
            // the physics' planners among its states.
            const plans_on_device: bool = settings.planning.enabled and settings.physics == .device;
            if (plans_on_device) {
                const teacher_planners: u32 = settings.teacher.planners;
                const has_everything: bool = teacher_planners > 0 and settings.phases.enabled and
                    settings.actor == .flow;
                if (!has_everything) {
                    return "learner.planning.enabled: on the device the search through the world model needs the " ++
                        "teacher's planners, the phases and a flow actor (teacher.planners, phases.enabled, " ++
                        "actor .flow)";
                }
                const trouble_planners: u32 = settings.teacher.planning.trouble_planners;
                const phase_two_planners: u32 = if (trouble_planners > 0) trouble_planners else teacher_planners;
                const budget: u32 = settings.planning.flags.budget;
                const budget_fits: bool = budget >= phase_two_planners and budget <= settings.characters;
                if (!budget_fits) {
                    return "learner.planning.flags.budget: at least the physics' planners of phase 2 (the model " ++
                        "plans for them first), at most the characters";
                }
            }
            // On the device the flow corrects every character with its own drifting noise; its third teacher's
            // examples - the real steps of characters in danger - are kept where the CPU fleet acts, so there it has
            // none to learn from: it is turned off by name.
            const flow_on_device: bool = settings.actor == .flow and settings.physics == .device;
            if (flow_on_device and settings.flow.fpo_rows > 0) {
                return "learner.supertrack.flow.fpo_rows: teacher 3's real steps are kept where the CPU fleet " ++
                    "acts - 0 with physics .device";
            }
            // A flow without FlowDPG learns from the plans alone: it needs planners that teach it - the phases' -
            // and, on the device, it has no other teacher.
            const flow_without_dpg: bool = settings.actor == .flow and !settings.flow.flow_dpg;
            if (flow_without_dpg and !settings.phases.enabled) {
                return "learner.supertrack.flow.flow_dpg: off, the flow learns from the planners alone - it needs " ++
                    "the phases";
            }
            // Labels from the flow's main mode: the flow must learn the plans on the device, with the phases.
            const phases: resident.Phases = settings.phases;
            const phase_one_from_flow: bool = phases.phase_one_labels == .flow_mode;
            const labels_from_flow: bool = phase_one_from_flow or phases.phase_two_labels == .flow_mode;
            const flow_learns_plans_on_device: bool = flow_on_device and phases.enabled;
            if (labels_from_flow and !flow_learns_plans_on_device) {
                return "learner.supertrack.phases: labels from the flow's mode need a flow actor learning the " ++
                    "plans - physics .device, the phases on";
            }
            // The flow's base the policy's slow average: there must be one, and the device acts through it.
            const base_on_average: bool = settings.actor == .flow and settings.flow.base == .policy_average;
            const average_kept: bool = settings.policy_average_decay > 0;
            if (base_on_average and !(average_kept and settings.physics == .device)) {
                return "learner.supertrack.flow.base: the policy's average needs policy_average_decay above 0 " ++
                    "and physics .device";
            }
            // On the CPU fleet a planning decision is made once a round; on the device, at every decision.
            const plans_cover_round: bool = settings.planning.horizon >= settings.collect;
            if (settings.planning.enabled and settings.physics != .device and !plans_cover_round) {
                return "learner.planning.horizon: shorter than a round (collect) - plans would cover only its start";
            }
            // A plan's knots must end on its last step: its fine steps, then a knot every span steps.
            const planning: resident.PlanningSettings = settings.planning;
            // A plan's skip steps jump the skip head's decisions: they need the head, and fit inside the horizon.
            const plan_skips_fit: bool = planning.skip_steps <= planning.horizon and
                (planning.skip_steps == 0 or settings.skip_steps > 0);
            if (planning.enabled and !plan_skips_fit) {
                return "learner.planning.skip_steps: at most the horizon, and only with the skip head (skip_steps)";
            }
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
        // Two clips at once are SuperTrack's - and a clip's variants are more clips.
        const is_supertrack: bool = run.learner == .supertrack;
        const has_several_clips: bool = run.task.motion.clipLabels().len > 1;
        if (has_several_clips and !is_supertrack) {
            return "task.motion: several clips at once, which only SuperTrack's learner trains";
        }
        if (run.task.variants.problem("task.variants.")) |variants_problem| {
            return variants_problem;
        }
        var variant_room: [ClipVariants.most_per_clip]ClipVariant = undefined;
        const has_variants: bool = run.task.variants.list(&variant_room).len > 1;
        if (has_variants and !is_supertrack) {
            return "task.variants: a clip's variants are more clips, which only SuperTrack's learner trains";
        }
        const learner_problem: ?[]const u8 = switch (run.learner) {
            .ppo => |learner| ppoProblem("learner.ppo.", learner.recipe()) orelse
                decisionProblem("learner.ppo.", learner.decimation, learner.beta),
            .supertrack => |learner| superTrackProblem("learner.supertrack.", learner),
            .efficient_tdmpc => |learner| tdmpcProblem("learner.efficient_tdmpc.", learner) orelse
                decisionProblem("learner.efficient_tdmpc.", learner.decimation, learner.beta),
        };
        if (learner_problem) |found| {
            return found;
        }
        const most_kept: u8 = GenoControls.most_kept_state_checkpoints;
        if (controls.kept_state_checkpoints > most_kept) {
            return comptimePrint("controls.kept_state_checkpoints: 0 to {d}", .{most_kept});
        }
        return controlsProblem(
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

    /// HOW MANY OF ITS LOG's STEPS MAKE A SECOND (`RunCurve`, the report): a step of a PPO run's log is a physics step
    /// of its fleet, a step of a SuperTrack run's a decision - `decide_every` physics steps, as the trainer counts its
    /// characters' decisions (`SuperTrackLog.Line.steps_watched`). EfficientTDMPC writes no log yet: counted as PPO's.
    /// `physics_steps_per_second` is the model's own, 60 for Geno.
    pub fn logStepsPerSecond(run: GenoRun, physics_steps_per_second: f32) f32 {
        return switch (run.learner) {
            .ppo, .efficient_tdmpc => physics_steps_per_second,
            .supertrack => |learner| physics_steps_per_second / float(@max(learner.decide_every, 1)),
        };
    }

    /// The run as ZON text, every field written: what a run folder's `run.zon` reads back as this run.
    pub fn write(run: GenoRun, writer: *Io.Writer) Io.Writer.Error!void {
        // The serializer checks at compile time that every field can be written, walking every learner's options
        // through their nested structs - more than the default thousand branches for a run of three learners.
        @setEvalBranchQuota(10_000);
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

test "GenoRun: a SuperTrack run is simulated on the CPU fleet unless it asks for the device, which reads back" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    // A SuperTrack run that names no physics: the CPU fleet, as every run before the field existed.
    const unnamed_source: [:0]const u8 = ".{ .learner = .{ .supertrack = .{} } }";
    const unnamed: GenoRun = try .parse(testing_allocator, arena, unnamed_source, &failure);
    try expectEqual(TrainingPhysics.cpu_fleet, unnamed.learner.supertrack.physics);
    try expectEqual(@as(?[]const u8, null), unnamed.problem());
    // One that asks for the device: read, written, and read back as itself.
    const device_source: [:0]const u8 = ".{ .learner = .{ .supertrack = .{ .physics = .device } } }";
    const on_device: GenoRun = try .parse(testing_allocator, arena, device_source, &failure);
    try expectEqual(TrainingPhysics.device, on_device.learner.supertrack.physics);
    var written: Io.Writer.Allocating = .init(arena);
    try on_device.write(&written.writer);
    const written_source: [:0]const u8 = try arena.dupeSentinel(u8, written.written(), 0);
    const read_back: GenoRun = try .parse(testing_allocator, arena, written_source, &failure);
    try expectEqual(TrainingPhysics.device, read_back.learner.supertrack.physics);
    // Refused by name without a stiffness per limb, which a device's actions and records carry: the trainer exits
    // with `TrainerExit.refused`.
    const why: []const u8 = on_device.problem() orelse return error.TestExpectedRefusal;
    try expect(indexOf(u8, why, "learner.supertrack.limb_stiffness") != null);
    // With it the run is accepted, judged as any run is.
    var with_stiffness: GenoRun = on_device;
    with_stiffness.learner.supertrack.limb_stiffness = true;
    try expect(with_stiffness.controls.judge_minutes > 0);
    try expectEqual(@as(?[]const u8, null), with_stiffness.problem());
}

test "GenoRun: a teacher's planners look ahead on the device, phases need them, and a run file keeps them" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    // A run on the device without a teacher: accepted.
    const source: [:0]const u8 = ".{ .learner = .{ .supertrack = .{ .physics = .device, .limb_stiffness = true } } }";
    const without_teacher: GenoRun = try .parse(testing_allocator, arena, source, &failure);
    try expectEqual(@as(u32, 0), without_teacher.learner.supertrack.teacher.planners);
    try expectEqual(@as(?[]const u8, null), without_teacher.problem());
    // Phases without planners: phase 1 would teach nothing - refused by the phases' name.
    var phases_alone: GenoRun = without_teacher;
    phases_alone.learner.supertrack.phases.enabled = true;
    const why_phases: []const u8 = phases_alone.problem() orelse return error.PhasesWithoutPlannersAccepted;
    try expect(startsWith(u8, why_phases, "learner.supertrack.phases.enabled: phase 1 is the teacher's labels"));
    // With planners the same run is accepted.
    var with_teacher: GenoRun = phases_alone;
    with_teacher.learner.supertrack.teacher.planners = 2;
    try expectEqual(@as(?[]const u8, null), with_teacher.problem());
    // Planners chosen by trouble need phases: refused without them by the option's name, accepted with them.
    var by_trouble: GenoRun = with_teacher;
    by_trouble.learner.supertrack.teacher.planning.trouble_planners = 1;
    try expectEqual(@as(?[]const u8, null), by_trouble.problem());
    by_trouble.learner.supertrack.phases.enabled = false;
    const why_trouble: []const u8 = by_trouble.problem() orelse return error.TroubleWithoutPhasesAccepted;
    try expect(startsWith(u8, why_trouble, "learner.supertrack.teacher.planning.trouble_planners: the planners are"));
    // A flow actor on the device: accepted without its third teacher, whose real steps the device does not keep;
    // with it, refused by its name.
    var flow_on_device: GenoRun = with_teacher;
    flow_on_device.learner.supertrack.actor = .flow;
    flow_on_device.learner.supertrack.flow.fpo_rows = 0;
    try expectEqual(@as(?[]const u8, null), flow_on_device.problem());
    flow_on_device.learner.supertrack.flow.fpo_rows = 32;
    const why_flow: []const u8 = flow_on_device.problem() orelse return error.FlowFpoOnDeviceAccepted;
    try expect(startsWith(u8, why_flow, "learner.supertrack.flow.fpo_rows: teacher 3's real steps are kept"));
    flow_on_device.learner.supertrack.flow.fpo_rows = 0;
    // Without FlowDPG and on the policy's average: accepted with the phases and an average; without the phases, or
    // without an average, refused by name.
    var flow_on_plans: GenoRun = flow_on_device;
    flow_on_plans.learner.supertrack.flow.flow_dpg = false;
    flow_on_plans.learner.supertrack.flow.base = .policy_average;
    flow_on_plans.learner.supertrack.policy_average_decay = 0.995;
    try expectEqual(@as(?[]const u8, null), flow_on_plans.problem());
    var plans_without_phases: GenoRun = flow_on_plans;
    plans_without_phases.learner.supertrack.phases.enabled = false;
    const why_no_teacher: []const u8 = plans_without_phases.problem() orelse return error.FlowWithoutTeacherAccepted;
    try expect(startsWith(u8, why_no_teacher, "learner.supertrack.flow.flow_dpg: off, the flow learns"));
    // Labels from the flow's mode: accepted with the flow on the device; with a Gaussian actor, refused by name.
    var labels_from_mode: GenoRun = flow_on_plans;
    labels_from_mode.learner.supertrack.phases.phase_two_labels = .flow_mode;
    try expectEqual(@as(?[]const u8, null), labels_from_mode.problem());
    var mode_without_flow: GenoRun = labels_from_mode;
    mode_without_flow.learner.supertrack.actor = .gaussian;
    mode_without_flow.learner.supertrack.flow.base = .live_policy;
    const why_no_flow: []const u8 = mode_without_flow.problem() orelse return error.ModeWithoutFlowAccepted;
    try expect(startsWith(u8, why_no_flow, "learner.supertrack.phases: labels from the flow's mode need"));
    var base_without_average: GenoRun = flow_on_plans;
    base_without_average.learner.supertrack.policy_average_decay = 0;
    const why_no_average: []const u8 = base_without_average.problem() orelse return error.BaseWithoutAverageAccepted;
    try expect(startsWith(u8, why_no_average, "learner.supertrack.flow.base: the policy's average needs"));
    // The root target: accepted, its drift charged in the policy's loss - the teacher's planners look ahead in the
    // simulator, where a character's slots are filled.
    var with_root_target: GenoRun = flow_on_plans;
    with_root_target.learner.supertrack.root_target = true;
    try expectEqual(@as(?[]const u8, null), with_root_target.problem());
    // The model planner on the device: with the teacher, the phases and the flow, accepted; without the flow, or with
    // more characters than are left beside the teacher's planners, refused by name.
    var model_on_device: GenoRun = flow_on_device;
    model_on_device.learner.supertrack.flow.fpo_rows = 0;
    model_on_device.learner.supertrack.planning.enabled = true;
    model_on_device.learner.supertrack.planning.flags.budget = 3;
    try expectEqual(@as(?[]const u8, null), model_on_device.problem());
    var model_without_flow: GenoRun = model_on_device;
    model_without_flow.learner.supertrack.actor = .gaussian;
    const why_model: []const u8 = model_without_flow.problem() orelse return error.ModelWithoutFlowAccepted;
    try expect(startsWith(u8, why_model, "learner.planning.enabled: on the device the search"));
    var model_too_few: GenoRun = model_on_device;
    model_too_few.learner.supertrack.planning.flags.budget = 1;
    const why_budget: []const u8 = model_too_few.problem() orelse return error.ModelBudgetAccepted;
    try expect(startsWith(u8, why_budget, "learner.planning.flags.budget: at least the physics' planners"));
    // With the root target, accepted: the model planner's rollouts imagine the root as the policy's do.
    var model_with_root: GenoRun = model_on_device;
    model_with_root.learner.supertrack.root_target = true;
    try expectEqual(@as(?[]const u8, null), model_with_root.problem());
    // Planners on the CPU fleet: refused by the planners' name.
    const planners_on_the_fleet: GenoRun = .{ .learner = .{ .supertrack = .{ .teacher = .{ .planners = 2 } } } };
    const why_fleet: []const u8 = planners_on_the_fleet.problem() orelse return error.PlannersOnTheFleetAccepted;
    try expect(startsWith(u8, why_fleet, "learner.supertrack.teacher.planners: the planners look ahead on the device"));
    // A run file's teacher, written and read back as itself - a setting of the planning among them.
    with_teacher.learner.supertrack.teacher.lookaheads_kept = 5;
    with_teacher.learner.supertrack.teacher.planning.candidates_per_planner = 6;
    with_teacher.learner.supertrack.teacher.planning.drawing.offset_noise_radians = 0.125;
    var written: Io.Writer.Allocating = .init(arena);
    try with_teacher.write(&written.writer);
    const written_source: [:0]const u8 = try arena.dupeSentinel(u8, written.written(), 0);
    const read_back: GenoRun = try .parse(testing_allocator, arena, written_source, &failure);
    const teacher_read: Teacher = read_back.learner.supertrack.teacher;
    try expectEqual(@as(u32, 2), teacher_read.planners);
    try expectEqual(@as(u32, 5), teacher_read.lookaheads_kept);
    try expectEqual(@as(u32, 6), teacher_read.planning.candidates_per_planner);
    try expectEqual(@as(f32, 0.125), teacher_read.planning.drawing.offset_noise_radians);
    // What the run file did not name is the planning's own default.
    const default_planning: rbt.PlanningOptions = .{};
    try expectEqual(default_planning.replan_interval, teacher_read.planning.replan_interval);
}

test "robot_lab: a skip head's step is 0, or from 2 to its projection; the projection from 2 to 20" {
    const prefix: []const u8 = "learner.supertrack.";
    var checks: report.Checks = .{};
    const Case = struct { skip_steps: u32, projection_steps: u32, refused_as: ?[]const u8 };
    const cases = [_]Case{
        .{ .skip_steps = 0, .projection_steps = 6, .refused_as = null },
        .{ .skip_steps = 4, .projection_steps = 6, .refused_as = null },
        .{ .skip_steps = 6, .projection_steps = 6, .refused_as = null },
        .{ .skip_steps = 1, .projection_steps = 6, .refused_as = "skip_steps: 0, or from 2 to projection_steps" },
        .{ .skip_steps = 7, .projection_steps = 6, .refused_as = "skip_steps: 0, or from 2 to projection_steps" },
        .{ .skip_steps = 0, .projection_steps = 1, .refused_as = "projection_steps: from 2 to 20 decisions" },
        .{ .skip_steps = 4, .projection_steps = 21, .refused_as = "projection_steps: from 2 to 20 decisions" },
    };
    for (cases) |case| {
        // The skip head reads the dense world model's second layer: its form named.
        const learner: SuperTrackLearner = .{
            .skip_steps = case.skip_steps,
            .projection_steps = case.projection_steps,
            .world_form = .dense_tanh,
        };
        const problem: ?[]const u8 = superTrackProblem(prefix, learner);
        if (case.refused_as) |expected| {
            const named: bool = problem != null and startsWith(u8, problem.?, prefix) and
                eql(u8, problem.?[prefix.len..], expected);
            checks.holds(named, "skip {d}, projection {d}: '{?s}', not '{s}'\n", .{
                case.skip_steps,
                case.projection_steps,
                problem,
                expected,
            });
        } else {
            checks.holds(problem == null, "skip {d}, projection {d} refused: {?s}\n", .{
                case.skip_steps,
                case.projection_steps,
                problem,
            });
        }
    }
    // With the normed world model: refused by name.
    const normed: SuperTrackLearner = .{ .skip_steps = 4, .world_form = .normed_silu };
    const normed_problem: []const u8 = superTrackProblem(prefix, normed) orelse "accepted";
    const normed_named: bool = startsWith(u8, normed_problem, prefix ++ "skip_steps: the skip head needs the dense");
    checks.holds(normed_named, "a skip head on the normed form: '{s}'\n", .{normed_problem});
    try checks.finish();
}

test "robot_lab: a teacher's settings are in range where it has planners, each refused by its path" {
    const prefix: []const u8 = "learner.supertrack.teacher.";
    // Without planners nothing reads the rest: no setting of it is refused.
    const no_planners: Teacher = .{ .planners = 0, .lookaheads_kept = 0 };
    const characters: u32 = 4;
    if (teacherProblem(prefix, no_planners, characters)) |why| {
        report.failure("a teacher without planners is refused: '{s}'\n", .{why});
        return error.TeacherWithoutPlannersRefused;
    }
    // As many planners as characters: accepted.
    const every_character: Teacher = .{ .planners = characters };
    if (teacherProblem(prefix, every_character, characters)) |why| {
        report.failure("as many planners as characters is refused: '{s}'\n", .{why});
        return error.EveryCharacterAPlannerRefused;
    }
    const Refused = struct { teacher: Teacher, refused_as: []const u8 };
    const not_a_number: f32 = nan(f32);
    const refused = [_]Refused{
        .{ .teacher = .{ .planners = characters + 1 }, .refused_as = "planners: at most the characters" },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .candidates_per_planner = 1 } },
            .refused_as = "planning.candidates_per_planner: 2 or more",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .replan_interval = 0 } },
            .refused_as = "planning.replan_interval: 1 or more",
        },
        .{ .teacher = .{ .planners = 2, .lookaheads_kept = 0 }, .refused_as = "lookaheads_kept: 1 or more" },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .plan_following_share = 1.5 } },
            .refused_as = "planning.plan_following_share: from 0 to 1",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .plan_following_share = not_a_number } },
            .refused_as = "planning.plan_following_share: from 0 to 1",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .drawing = .{ .offset_noise_radians = -0.1 } } },
            .refused_as = "planning.drawing.offset_noise_radians: 0 or more",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .drawing = .{ .stiffness_noise = not_a_number } } },
            .refused_as = "planning.drawing.stiffness_noise: 0 or more",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .drawing = .{ .offset_reach_radians = 0 } } },
            .refused_as = "planning.drawing.offset_reach_radians: above 0",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .trouble_planners = 3 } },
            .refused_as = "planning.trouble_planners: at most the planners",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .trouble_planners = 1, .phase_two_form = .whole_actions } },
            .refused_as = "planning.trouble_planners: a planner chosen anew starts from the policy",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .trouble_planners = 1, .trouble_lookahead_decisions = -1 } },
            .refused_as = "planning.trouble_lookahead_decisions: 0 or more",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .teach_share = 0 } },
            .refused_as = "planning.teach_share: above 0, at most 1",
        },
        .{
            .teacher = .{ .planners = 2, .planning = .{ .teach_window = 0 } },
            .refused_as = "planning.teach_window: at least 1",
        },
    };
    // Every case is gone through, each one that fails named: one run shows them all.
    var cases_failed: u32 = 0;
    for (refused) |case| {
        const why: []const u8 = teacherProblem(prefix, case.teacher, characters) orelse {
            report.failure("a teacher that should be refused as '{s}' is accepted\n", .{case.refused_as});
            cases_failed += 1;
            continue;
        };
        const names_its_path: bool = startsWith(u8, why, prefix) and indexOf(u8, why, case.refused_as) != null;
        if (!names_its_path) {
            report.failure("refused as '{s}', expected '{s}'\n", .{ why, case.refused_as });
            cases_failed += 1;
        }
    }
    try expectEqual(@as(u32, 0), cases_failed);
    // And a learner's check reaches the teacher's: the refusal comes through under the learner's prefix.
    const learner: SuperTrackLearner = .{ .teacher = .{ .planners = 2, .lookaheads_kept = 0 } };
    const through_the_learner: []const u8 =
        superTrackProblem("learner.supertrack.", learner) orelse return error.TeacherNotReachedThroughTheLearner;
    try expect(startsWith(u8, through_the_learner, "learner.supertrack.teacher.lookaheads_kept"));
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

/// A RECIPE IN THE REPOSITORY, embedded by the build as `embedded_name` (`<its folder>_<its name>`), read as the
/// trainer reads a run folder's `run.zon` - a field renamed or moved since it was written refuses it here, not at the
/// start of a night - and checked as the trainer checks it (`GenoRun.problem`): a SuperTrack run on the device, with a
/// limit to its hours. Memory: the run's strings in `arena`.
fn checkEmbeddedRecipe(
    comptime embedded_name: []const u8,
    arena: Allocator,
    checks: *report.Checks,
) !void {
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    const recipe_source: [:0]const u8 = @embedFile(embedded_name);
    const run: GenoRun = GenoRun.parse(testing_allocator, arena, recipe_source, &failure) catch |err| {
        report.failure("the recipe {s} is refused: {s}\n", .{ embedded_name, failure.description });
        return err;
    };
    const problem: ?[]const u8 = run.problem();
    checks.holds(problem == null, "the trainer refuses the recipe " ++ embedded_name ++ ": {?s}\n", .{problem});
    const learner: SuperTrackLearner = run.learner.supertrack;
    checks.holds(learner.physics == .device, embedded_name ++ ": not on the device\n", .{});
    checks.holds(run.controls.stop_after_hours > 0, embedded_name ++ ": no limit to its hours\n", .{});
}

test "the first night's recipes: every one read as written, and the trainer takes it" {
    // THE NIGHT's RECIPES IN THE REPOSITORY (`examples/geno_lab/recipes/night1/`, each embedded by the build as
    // `night1_<name>`): every run of the night a SuperTrack run on the device, an hour long (the check before it 20
    // minutes).
    const night_recipe_names = [_][]const u8{
        "00_check_control",
        "01_control",
        "02_control_seed2",
        "03_plain_supertrack",
        "04_no_teacher",
        "05_no_flow",
        "06_no_model_planner",
        "07_no_skip_head",
        "08_no_critic",
        "09_no_recovery",
        "10_no_root_target",
    };
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var checks: report.Checks = .{};
    inline for (night_recipe_names) |recipe_name| {
        try checkEmbeddedRecipe("night1_" ++ recipe_name, arena, &checks);
    }
    try checks.finish();
}

test "the three hours' recipes: every one read as written, and the trainer takes it" {
    // THE THREE HOURS' RECIPES (`examples/geno_lab/recipes/three_hours/`, each embedded as `three_hours_<name>`): 13
    // minutes each, judged once at their end without the recovery probe - and the last, a profile of 3 minutes, judged
    // never, with every dispatch timed.
    const three_hours_recipe_names = [_][]const u8{
        "01_control",
        "02_plain_supertrack",
        "03_control_seed2",
        "04_phase_two_by_gate",
        "05_no_teacher",
        "06_no_flow",
        "07_no_model_planner",
        "08_no_skip_head",
        "09_no_critic",
        "10_no_root_target",
        "11_no_recovery",
        "12_dispatch_times",
    };
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var checks: report.Checks = .{};
    inline for (three_hours_recipe_names) |recipe_name| {
        try checkEmbeddedRecipe("three_hours_" ++ recipe_name, arena, &checks);
    }
    // The block's own settings, read back: the control's 13 minutes, its one judgement, no probe; the profile's
    // dispatches timed.
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    const control: GenoRun = try .parse(testing_allocator, arena, @embedFile("three_hours_01_control"), &failure);
    try expectApproxEqAbs(@as(f32, 13), control.controls.stop_after_hours * 60, 1e-4);
    try expectEqual(@as(f32, 13), control.controls.judge_minutes);
    try expectEqual(@as(usize, 0), control.controls.probe.speeds.len);
    try expectEqual(@as(f32, 4), control.learner.supertrack.phases.phase_one_minutes);
    const profile_source: [:0]const u8 = @embedFile("three_hours_12_dispatch_times");
    const profile: GenoRun = try .parse(testing_allocator, arena, profile_source, &failure);
    try expect(profile.controls.kernel_times);
    try expectEqual(@as(f32, 0), profile.controls.judge_minutes);
    try checks.finish();
}

test "the foundation's recipes: every one read as written, and the trainer takes it" {
    // THE FIRST CHECK (`examples/geno_lab/recipes/foundation/`, each embedded as `foundation_<name>`): its two seeds
    // and the three hours' run 2 again, 13 minutes each. Read back: the first check's iteration in XMimic's records,
    // halved (C1) - 10 decisions collected, 10 world model updates and 2 policy updates on 1,024 each, 20 decisions of
    // horizon - its replay of 600, its warm-up of 256, its policy's rate boost of 4 for 1,400 rounds and 300 of ramp,
    // the two rates over the square root of 2; the two seeds alike but their seed; run 2's as the three hours had it.
    const foundation_recipe_names = [_][]const u8{
        "01_first_check",
        "02_first_check_seed2",
        "03_three_hours_run2",
    };
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var checks: report.Checks = .{};
    inline for (foundation_recipe_names) |recipe_name| {
        try checkEmbeddedRecipe("foundation_" ++ recipe_name, arena, &checks);
    }
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    const first: GenoRun = try .parse(testing_allocator, arena, @embedFile("foundation_01_first_check"), &failure);
    const learner: SuperTrackLearner = first.learner.supertrack;
    try expectEqual(@as(u32, 10), learner.collect);
    try expectEqual(@as(u32, 10), learner.world_updates);
    try expectEqual(@as(u32, 2), learner.policy_updates);
    try expectEqual(@as(u32, 1024), learner.rows);
    try expectEqual(@as(u32, 20), learner.policy_window);
    try expectEqual(@as(u32, 600), learner.replay_steps);
    try expectEqual(@as(u32, 256), learner.warmup_decisions);
    try expectEqual(@as(f32, 4), learner.policy_rate_boost.multiplier);
    try expectEqual(@as(u32, 1400), learner.policy_rate_boost.held_rounds);
    try expectEqual(@as(u32, 300), learner.policy_rate_boost.ramp_rounds);
    const halved_rate: f32 = 4.0e-4 / @sqrt(@as(f32, 2));
    try expectApproxEqAbs(halved_rate, learner.world_rate, 1e-10);
    try expectApproxEqAbs(halved_rate, learner.policy_rate, 1e-10);
    try expectApproxEqAbs(@as(f32, 13), first.controls.stop_after_hours * 60, 1e-4);
    const second_source: [:0]const u8 = @embedFile("foundation_02_first_check_seed2");
    const second: GenoRun = try .parse(testing_allocator, arena, second_source, &failure);
    var second_learner: SuperTrackLearner = second.learner.supertrack;
    try expectEqual(@as(u64, 2), second_learner.seed);
    second_learner.seed = learner.seed;
    try expect(std.meta.eql(learner.options(), second_learner.options()));
    try checks.finish();
}

test "the first run's recipe: read as written, every part on, on the device - and the trainer takes it" {
    // THE RECIPE IN THE REPOSITORY (`examples/geno_lab/recipes/first_run.zon`), read as the trainer reads a run
    // folder's `run.zon`: a field renamed or moved since it was written refuses it here, not at the start of a night.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var failure: GenoRun.ParseFailure = .{ .description = "" };
    const recipe_source: [:0]const u8 = @embedFile("first_run_recipe");
    const run: GenoRun = GenoRun.parse(testing_allocator, arena, recipe_source, &failure) catch |err| {
        report.failure("the first run's recipe is refused: {s}\n", .{failure.description});
        return err;
    };
    var checks: report.Checks = .{};
    const problem: ?[]const u8 = run.problem();
    checks.holds(problem == null, "the trainer refuses the first run's recipe: {?s}\n", .{problem});
    // Every part on: the device, the teacher and the phases, the variants, the pushes, returns, the critic with its
    // real lambda, the policy's slow average.
    const learner: SuperTrackLearner = run.learner.supertrack;
    checks.holds(learner.physics == .device, "the recipe is not on the device\n", .{});
    checks.holds(learner.teacher.planners > 0, "the recipe has no teacher\n", .{});
    checks.holds(learner.phases.enabled, "the recipe has no phases\n", .{});
    const variants: ClipVariants = run.task.variants;
    checks.holds(variants.mirrored and variants.speed_change > 0, "the recipe has no variants\n", .{});
    checks.holds(learner.pushes.rate_per_second > 0, "the recipe has no pushes\n", .{});
    checks.holds(learner.return_steps > 0, "the recipe has no returns\n", .{});
    const critic_learns_returns: bool = learner.train_critic and learner.critic.real_lambda > 0;
    checks.holds(critic_learns_returns, "the recipe's critic does not fit lambda-returns\n", .{});
    checks.holds(learner.policy_average_decay > 0, "the recipe's policy has no slow average\n", .{});
    checks.holds(learner.skip_steps > 0, "the recipe's world model has no skip head\n", .{});
    checks.holds(learner.policy_skip_steps > 0, "the recipe's policy does not step through skips\n", .{});
    // One planner or more on every clip: the planners are the first characters, each on the clip of its index.
    var variant_list: [ClipVariants.most_per_clip]ClipVariant = undefined;
    const variants_per_clip: usize = variants.list(&variant_list).len;
    const clip_count: usize = run.task.motion.clipLabels().len * variants_per_clip;
    const planners: usize = learner.teacher.planners;
    checks.holds(planners >= clip_count, "{d} planners for {d} clips\n", .{ planners, clip_count });
    try checks.finish();
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
        .{ .learner = .{ .supertrack = .{ .filter = 0.0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .dynamics_heads = 0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .pessimism = -1 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .characters = 0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .max_episode_steps = 1 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .update_to_data = 0 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .replay_steps = 299 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .aftermath_steps = 11 } } },
        .{ .learner = .{ .efficient_tdmpc = .{ .acting_horizon = 40 } } },
        .{ .controls = .{ .save_minutes = 0 } },
        .{ .controls = .{ .kept_state_checkpoints = 9 } },
    };
    const named = [_][]const u8{
        "learner.ppo.beta: above 0, at most 1",
        "learner.ppo.envs: at least 1 character",
        "learner.supertrack.rows: at least 1 window",
        "learner.supertrack.filter: above 0, at most 1",
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
        "controls.kept_state_checkpoints: 0 to 8",
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
    /// Where each round's time went, one line per round (`RoundTimeLog`).
    times,
    /// Each kernel's time on the device since the run's start, for a run that times every dispatch (`KernelTimeLog`).
    kernel_times,

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
            .times => "time.csv",
            .kernel_times => "kernel_times.csv",
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
    /// A tripwire against a run that learns nothing fired after its first rounds (`Tripwire`; `RunStatus.tripwire`
    /// names it): the run stopped, its state saved as it stood.
    failed_tripwire,
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
    /// The tripwire that stopped a run learning nothing (`RunState.failed_tripwire`, `TripwireFired.text`); empty
    /// otherwise.
    tripwire: []const u8 = "",
    /// THE COLLAPSE ALARM: the clip whose policy, once better than the servo, has been judged no better three times
    /// running (`JudgeLog.collapsedClip`); empty while none has. The run goes on - a person decides.
    collapse: []const u8 = "",
    world_model_loss: f32 = 0,
    critic_value_error: f32 = 0,
    policy_gradient_norm: f32 = 0,
    windows_refused: u64 = 0,
    nonfinite_actions: u64 = 0,
    /// A SuperTrack run's SUCCESS by SuperMimic's evaluation (`JudgeLog.superMimicSuccess`): the active training
    /// minutes - the clock less the judging and the checkpoints - and the round at which every clip was first completed
    /// with the clips' mean normalised return at the bar; null until then.
    success_active_minutes: ?f32 = null,
    success_round: ?u64 = null,
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

// ------------------------------------------------------------------------------------------------------------------
// THE TRIPWIRES: a run that learns nothing, stopped after its first rounds
// ------------------------------------------------------------------------------------------------------------------

/// THE TRIPWIRES AGAINST A RUN THAT LEARNS NOTHING. "Does not explode" is passed by a learner that does nothing - a
/// teacher whose plans are never acted on, a gradient that never arrives, a rate or a scale of zero - and such a run
/// goes on all night without a sign. So after a run's first rounds the trainer reads, once, what learning leaves
/// behind (`TripwireReading`), and the first miss (`firstTripwire`) ends the run, its tripwire named in `status.zon`
/// (`RunState.failed_tripwire`, `RunStatus.tripwire`) - in the order a learner is fed:
///
///     replay_still         the replay's write head where it was: the learner trains on what it always had
///     labels_absent        planners asked for, and not one record labelled with a planner's action
///     lookaheads_absent    planners asked for, and not one lookahead recorded for the world model
///     weights_unmoved      a network updated since the first reading, its weights as they were - none moved by
///                          more than `TripwireBars.weight_change_floor`
///     gradient_vanished    the world model's or the policy's latest gradient of length zero, where it is measured
///     offsets_dead         the servo's offsets from the policy none past `TripwireBars.dead_offset`: the policy's
///                          choice never reaches a joint
///     offsets_saturated    the typical offset past `TripwireBars.saturated_offset`: every target pinned against
///                          its joint's limit
pub const Tripwire = enum {
    replay_still,
    labels_absent,
    lookaheads_absent,
    weights_unmoved,
    gradient_vanished,
    offsets_dead,
    offsets_saturated,
};

/// The bars the tripwires read against (`firstTripwire`), and when they are read.
pub const TripwireBars = struct {
    /// The rounds from the first reading to the judgement: enough for every network a run trains to have had its
    /// updates - the policy its first labels, the critic its first batches of the characters' own.
    judged_after_rounds: u64 = 6,
    /// The least change of a network's most-moved weight that counts as motion: far below what Adam's steps at any
    /// real rate leave over a few updates (the reference's 2e-4, its cosine's floor 6e-6), far above what a rate of
    /// almost nothing does - a step of 1e-30 on a weight of order 0.1 is lost in its float entirely.
    weight_change_floor: f32 = 1e-6,
    /// The largest offset, in radians, at or below which the policy's choice reaches no joint: a millionth of a
    /// radian moves nothing a body could show - a scale of almost nothing, or a choice of zeros.
    dead_offset: f32 = 1e-6,
    /// The typical (median) offset, in radians, past which the policy is saturated: a quarter turn, where a hinge's
    /// or a ball's target sits on its limit. A policy that tracks moves its joints by tenths of a radian.
    saturated_offset: f32 = 0.5 * pi,
};

/// One network between the tripwires' two readings: its name, whether it had updates between them - a network not yet
/// trained (a flow before its first example) is not judged - and the largest change of any of its weights.
pub const NetworkMotion = struct {
    name: []const u8,
    updated: bool,
    largest_change: f32,
};

/// The servo's offsets from the policy, in radians - each character's applied action times the action's scale, its
/// joints' offsets alone, not their stiffnesses - over every character: the largest magnitude, and the median one.
pub const OffsetMagnitudes = struct {
    largest: f32,
    median: f32,
};

/// The teacher's arrivals since the run's start: records labelled with a planner's action, kept, dropped or not yet
/// settled; and lookaheads recorded whole.
pub const TeacherArrivals = struct {
    labelled_records: u64,
    lookaheads: u64,
};

/// WHAT THE TRIPWIRES READ (`firstTripwire`), once, some rounds after a first reading - each part null where the run
/// has no such thing.
pub const TripwireReading = struct {
    replay_moved: bool,
    teacher: ?TeacherArrivals = null,
    networks: []const NetworkMotion = &.{},
    /// The world model's and the policy's latest gradient lengths, where measured: a run that bounds them.
    world_gradient_norm: ?f32 = null,
    policy_gradient_norm: ?f32 = null,
    offsets: ?OffsetMagnitudes = null,
};

/// A tripwire that fired, and the network it names (`weights_unmoved`, `gradient_vanished`) - empty for the others.
pub const TripwireFired = struct {
    tripwire: Tripwire,
    network: []const u8 = "",

    /// The status's words for it: "weights_unmoved: the critic", or the tripwire's name alone. Memory: in `arena`.
    pub fn text(fired: TripwireFired, arena: Allocator) ![]const u8 {
        if (fired.network.len == 0) {
            return @tagName(fired.tripwire);
        }
        return allocPrint(arena, "{s}: {s}", .{ @tagName(fired.tripwire), fired.network });
    }
};

/// THE FIRST TRIPWIRE A READING FIRES (`Tripwire`), in the table's order, or null when every one holds. A number that
/// is not finite fails its bar: the comparisons are written so that NaN reads as a miss.
pub fn firstTripwire(reading: TripwireReading, bars: TripwireBars) ?TripwireFired {
    if (!reading.replay_moved) {
        return .{ .tripwire = .replay_still };
    }
    if (reading.teacher) |arrivals| {
        if (arrivals.labelled_records == 0) {
            return .{ .tripwire = .labels_absent };
        }
        if (arrivals.lookaheads == 0) {
            return .{ .tripwire = .lookaheads_absent };
        }
    }
    for (reading.networks) |network| {
        const moved: bool = network.largest_change > bars.weight_change_floor;
        if (network.updated and !moved) {
            return .{ .tripwire = .weights_unmoved, .network = network.name };
        }
    }
    const gradient_norms = [_]?f32{ reading.world_gradient_norm, reading.policy_gradient_norm };
    const gradient_networks = [_][]const u8{ "the world model", "the policy" };
    for (gradient_norms, gradient_networks) |maybe_norm, network_name| {
        const norm: f32 = maybe_norm orelse continue;
        if (!(norm > 0)) {
            return .{ .tripwire = .gradient_vanished, .network = network_name };
        }
    }
    const offsets: OffsetMagnitudes = reading.offsets orelse return null;
    if (!(offsets.largest > bars.dead_offset)) {
        return .{ .tripwire = .offsets_dead };
    }
    if (!(offsets.median <= bars.saturated_offset)) {
        return .{ .tripwire = .offsets_saturated };
    }
    return null;
}

/// The largest change between two readings of the same weights - `before` and `after` of one length.
pub fn largestChange(before: []const f32, after: []const f32) f32 {
    assertf(before.len == after.len, @src(), "{d} weights before, {d} after", .{ before.len, after.len });
    var largest: f32 = 0;
    for (before, after) |weight_before, weight_after| {
        const change: f32 = @abs(weight_after - weight_before);
        // A change of NaN counts as none: the watchdog speaks for those.
        if (change > largest) {
            largest = change;
        }
    }
    return largest;
}

/// The offsets' magnitudes as the tripwires read them (`OffsetMagnitudes`): the largest, and the median - the middle
/// one, the upper of the two middle ones for an even count. `scratch`, as long as `offsets`, is overwritten with the
/// sorted magnitudes. No offsets read as none at all.
pub fn offsetMagnitudes(offsets: []const f32, scratch: []f32) OffsetMagnitudes {
    assertf(scratch.len == offsets.len, @src(), "{d} offsets, scratch for {d}", .{ offsets.len, scratch.len });
    if (offsets.len == 0) {
        return .{ .largest = 0, .median = 0 };
    }
    for (offsets, scratch) |offset, *magnitude| {
        magnitude.* = @abs(offset);
    }
    sortSlice(f32, scratch, {}, ascending(f32));
    const middle: usize = scratch.len / 2;
    return .{ .largest = scratch[scratch.len - 1], .median = scratch[middle] };
}

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
        /// THE ACTIVE TRAINING MINUTES (InstantMimic's measure): the training clock less the time spent judging,
        /// probing and checkpointing - what a run's time to success is counted in (`RunStatus.success_active_minutes`).
        active_minutes: f32 = 0,
        /// The round's returns to the reference after a loss (`robot_track.Fleet.Options.return_steps`), and their mean
        /// time from the loss, in seconds.
        returns: u64 = 0,
        return_mean_seconds: f32 = 0,
        /// The pushes given in the round and their mean speed, in m/s - what the characters actually met.
        pushes: u64 = 0,
        push_mean_speed: f32 = 0,
        /// THE PUSHES' TOP in the round (`robot.PushTop`): the highest speed a push could be drawn at, in m/s, and
        /// where the training clock's line would have it - the two differ while the brake has held the top. Then the
        /// round's watched pushes ended, and those of them the characters came back from (`robot.PushBrake`).
        push_top_speed: f32 = 0,
        push_line_speed: f32 = 0,
        watched_pushes: u64 = 0,
        watched_came_back: u64 = 0,
        /// At the round's end: the share of the characters planning, and the characters' mean projected hazard.
        flagged_share: f32 = 0,
        mean_hazard: f32 = 0,
        /// The round's planning decisions (characters deciding), and the share of its exploring steps acted from a
        /// plan.
        planning_decisions: u64 = 0,
        planned_step_share: f32 = 0,
        /// THE TEACHER's part of the round's decisions watched and failures (robotgpu_host's `countTrainerDecisions`):
        /// the decisions where a planner acted from its plan - read against everyone's, whether the teacher's plans
        /// track better than the policy around them.
        planner_steps_watched: u64 = 0,
        planner_failures: u64 = 0,
        /// THE TEACHER's PLANS AGAINST THEIR BASELINE (robotgpu_host's `Planning.judgePlans`): the round's plans
        /// judged, the share of them that taught, and their mean advantage - a plan's lookahead score less its
        /// baseline's, the servo's as whole actions, the policy's around it. 0 without a baseline.
        teacher_plans: u64 = 0,
        teacher_teaching_share: f32 = 0,
        teacher_mean_advantage: f32 = 0,
        /// Teacher 2's and teacher 3's examples held at the round's end, and the trust in the critic.
        teacher2_examples: u64 = 0,
        teacher3_examples: u64 = 0,
        critic_trust: f32 = 0,
        /// THE TEACHER's PLANNERS (`Teacher`, `robot_track_resident.Phases`): the share of the policy's updates that
        /// are label updates at the round's end - 1 through phase 1, falling over phase 2's ramp, 0 without phases;
        /// the round's label updates, its world-model updates on candidates, the lookaheads it recorded, the labels
        /// its books kept and those they dropped for decisions after a loss (`robot_track.LabelBooks`); and the world
        /// model's gate's passes in a row at its end. The gate's latest measurement is among the device's numbers
        /// (`gate_*`).
        label_share: f32 = 0,
        /// The policy's rate multiplier at the round's end (`robot_track_resident.RateBoost`): 1 without a boost.
        policy_rate_multiplier: f32 = 0,
        label_updates: u64 = 0,
        candidate_world_updates: u64 = 0,
        lookaheads: u64 = 0,
        labels_kept: u64 = 0,
        labels_dropped_after_losses: u64 = 0,
        gate_passes: u32 = 0,
        /// The round's world-model updates on the skip head's schedule (`robot_track_resident.Options.skip_steps`);
        /// the skip head's latest loss is among the device's numbers (`skip_head_loss`).
        skip_world_updates: u64 = 0,
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

    /// The number a log holds under the column `name` on the line of round `round` - the header naming the columns -
    /// or null when the log has no such column, no such round, or no number there.
    pub fn numberAtRound(log_text: []const u8, name: []const u8, round: u64) ?f64 {
        var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, log_text, '\n');
        const header_line: []const u8 = lines.next() orelse return null;
        var names: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, header_line, ',');
        const wanted_index: usize = found: {
            var index: usize = 0;
            while (names.next()) |column_name| : (index += 1) {
                if (eql(u8, column_name, name)) {
                    break :found index;
                }
            }
            return null;
        };
        while (lines.next()) |text| {
            var columns: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, ',');
            const round_text: []const u8 = columns.next() orelse continue;
            const line_round: u64 = parseInt(u64, round_text, 10) catch continue;
            if (line_round != round) {
                continue;
            }
            if (wanted_index == 0) {
                return float64(line_round);
            }
            var column_now: usize = 1;
            while (columns.next()) |value| : (column_now += 1) {
                if (column_now == wanted_index) {
                    return parseFloat(f64, value) catch null;
                }
            }
            return null;
        }
        return null;
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

/// A RUN's TIME, ROUND BY ROUND (`time.csv`): where each round's time went - on the device, by the phase its
/// dispatches were for, and on the host, by the phase it was in (`robot.RoundPhase`) - so that the split of a round
/// is measured before any part of it is made faster. One line a round:
///
///     wall_ms             the round, from its first decision to the device's last work of it done
///     between_rounds_ms   before it, since the round before ended: saving, checkpoints, judging, the report
///     rested_ms           the time the round rested the device for the machine's share (`z.MachineShare`) - part
///                         of its wall time and of its phases' host times; 0 for a run that takes the whole machine
///     gpu_busy_ms         the device's time in the round's segments (`Compute.enableTimings`), every phase's
///     gpu_idle_share      the share of the wall time the device was in no segment: waiting for the host
///     gpu_span_ms         from the round's first mark on the device's clock to its last
///     host_wait_ms        the host's time waiting for the device: its spins on readbacks, and the round's end
///     submissions         the dispatches' submissions, both pipes'
///     dispatches          the dispatches, both pipes'
///     untimed_dispatches  dispatches no segment covered - the marks ran out; 0 in a round timed whole
///     <phase>_gpu_ms  <phase>_host_ms  <phase>_wait_ms  <phase>_segments      for each phase, in its order
///
/// THE IDLE SHARE IS THE DEVICE's OWN MEASURE: the wall time less the device's busy time, over the wall time. The
/// host's clock cannot give it - a host encoding commands and a host waiting both leave the device idle, and a host
/// waiting on a readback may be waiting for a device that is busy.
pub const RoundTimeLog = struct {
    /// One phase's part of a round: the device's time in its segments and their count; the host's time in the phase,
    /// and the part of that spent waiting for the device.
    pub const PhaseTimes = struct {
        gpu_ms: f32 = 0,
        host_ms: f32 = 0,
        wait_ms: f32 = 0,
        segments: u32 = 0,
    };

    /// One round, as its line holds it.
    pub const Line = struct {
        round: u64 = 0,
        training_minutes: f32 = 0,
        wall_ms: f32 = 0,
        between_rounds_ms: f32 = 0,
        rested_ms: f32 = 0,
        gpu_busy_ms: f32 = 0,
        gpu_idle_share: f32 = 0,
        gpu_span_ms: f32 = 0,
        host_wait_ms: f32 = 0,
        submissions: u64 = 0,
        dispatches: u64 = 0,
        untimed_dispatches: u64 = 0,
        phases: [rbt.RoundPhase.count]PhaseTimes = @splat(.{}),
    };

    /// WHAT A ROUND MEASURED, as a trainer gathers it: the device's time by phase from its pipes' reads added up
    /// (`Compute.readTimings`), in microseconds, with the reads' span on the device's clock
    /// (`compute_host.timingsSpanMicroseconds`); the host's clock over the round (`robot.PhaseClock`), ended; and the
    /// round's counts.
    pub const Measured = struct {
        round: u64,
        training_minutes: f32,
        between_rounds_ms: f64,
        rested_ms: f64 = 0,
        gpu_microseconds: [rbt.RoundPhase.count]f64,
        gpu_segments: [rbt.RoundPhase.count]u32,
        gpu_span_microseconds: f64,
        clock: rbt.PhaseClock,
        submissions: u64,
        dispatches: u64,
        untimed_dispatches: u64,
    };

    /// The share of a round's wall time its device spent in no segment: 1 less the busy time over the wall time, and
    /// never below 0 - a device timed busier than the wall clock, by the two clocks' rounding, is not idle. A round
    /// of no time has no idle share: 0.
    pub fn idleShare(wall_ms: f64, gpu_busy_ms: f64) f32 {
        if (wall_ms <= 0) {
            return 0;
        }
        const busy_share: f64 = gpu_busy_ms / wall_ms;
        const idle_share: f64 = @max(1.0 - busy_share, 0.0);
        return @floatCast(idle_share);
    }

    /// A round's line from what it measured: the wall time is the host's clock over every phase, the busy time the
    /// device's over every phase, and the idle share theirs (`idleShare`).
    pub fn lineOf(measured: Measured) Line {
        const microseconds_per_millisecond: f64 = 1000.0;
        const wall_ms: f64 = measured.clock.hostTotalMs();
        var line: Line = .{
            .round = measured.round,
            .training_minutes = measured.training_minutes,
            .wall_ms = @floatCast(wall_ms),
            .between_rounds_ms = @floatCast(measured.between_rounds_ms),
            .rested_ms = @floatCast(measured.rested_ms),
            .gpu_span_ms = @floatCast(measured.gpu_span_microseconds / microseconds_per_millisecond),
            .host_wait_ms = @floatCast(measured.clock.waitTotalMs()),
            .submissions = measured.submissions,
            .dispatches = measured.dispatches,
            .untimed_dispatches = measured.untimed_dispatches,
        };
        var gpu_busy_ms: f64 = 0;
        for (&line.phases, 0..) |*phase_times, phase| {
            const phase_gpu_ms: f64 = measured.gpu_microseconds[phase] / microseconds_per_millisecond;
            gpu_busy_ms += phase_gpu_ms;
            phase_times.* = .{
                .gpu_ms = @floatCast(phase_gpu_ms),
                .host_ms = @floatCast(measured.clock.host_ms[phase]),
                .wait_ms = @floatCast(measured.clock.wait_ms[phase]),
                .segments = measured.gpu_segments[phase],
            };
        }
        line.gpu_busy_ms = @floatCast(gpu_busy_ms);
        line.gpu_idle_share = idleShare(wall_ms, gpu_busy_ms);
        return line;
    }

    /// The log's first line: its columns - `Line`'s fields, each phase's four under the phase's name.
    pub const header: []const u8 = headerOf();

    fn headerOf() []const u8 {
        comptime var text: []const u8 = "";
        inline for (@typeInfo(Line).@"struct".field_names) |field_name| {
            if (comptime eql(u8, field_name, "phases")) {
                inline for (@typeInfo(rbt.RoundPhase).@"enum".field_names) |phase_name| {
                    inline for (@typeInfo(PhaseTimes).@"struct".field_names) |time_name| {
                        text = text ++ phase_name ++ "_" ++ time_name ++ ",";
                    }
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
            if (comptime eql(u8, field_name, "phases")) {
                for (line.phases) |phase_times| {
                    inline for (@typeInfo(PhaseTimes).@"struct".field_names) |time_name| {
                        const text: []const u8 = try bufPrint(&number_buffer, "{d}", .{
                            @field(phase_times, time_name),
                        });
                        try appendColumn(gpa, log, &is_first, text);
                    }
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

/// EACH KERNEL's TIME ON THE DEVICE (`kernel_times.csv`), for a run that times every dispatch
/// (`GenoControls.kernel_times`): the totals since the run's start, one line a kernel that was dispatched, the
/// largest time first - where a faster kernel would buy the most.
///
///     pipe         whose kernel: the learner's networks or the simulator's physics
///     kernel       its name
///     dispatches   how many times it was dispatched and timed
///     gpu_ms       its time on the device, summed
///     gpu_share    that time over every kernel's
pub const KernelTimeLog = struct {
    /// The file's first line: its columns.
    pub const header: []const u8 = "pipe,kernel,dispatches,gpu_ms,gpu_share\n";

    /// One kernel's totals.
    pub const Entry = struct {
        pipe: []const u8,
        kernel: []const u8,
        dispatches: u64,
        gpu_microseconds: f64,
    };

    /// Whether `first` took the device longer than `second`: the file's order.
    fn tookLonger(_: void, first: Entry, second: Entry) bool {
        return first.gpu_microseconds > second.gpu_microseconds;
    }

    /// The whole file into `out`: the header, then `entries` - sorted here, the largest time first - leaving out the
    /// kernels never dispatched. Memory: `out` grows with `gpa`, as its owner's.
    pub fn write(gpa: Allocator, out: *ArrayList(u8), entries: []Entry) !void {
        sortSlice(Entry, entries, {}, tookLonger);
        var total_microseconds: f64 = 0;
        for (entries) |entry| {
            total_microseconds += entry.gpu_microseconds;
        }
        try out.appendSlice(gpa, header);
        for (entries) |entry| {
            if (entry.dispatches == 0) {
                continue;
            }
            const gpu_ms: f64 = entry.gpu_microseconds / 1000.0;
            const gpu_share: f64 = if (total_microseconds > 0) entry.gpu_microseconds / total_microseconds else 0;
            var line_buffer: [240]u8 = undefined;
            const line: []const u8 = try bufPrint(&line_buffer, "{s},{s},{d},{d:.3},{d:.4}\n", .{
                entry.pipe,
                entry.kernel,
                entry.dispatches,
                gpu_ms,
                gpu_share,
            });
            try out.appendSlice(gpa, line);
        }
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
        "recovery_steps_sum,lost,returned,return_steps_sum,not_returned,step_seconds,return_fluid_steps," ++
        "return_action_rate_sum,return_jerk_sum\n";

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
    ) !void {
        for (bands) |band| {
            var line_buffer: [320]u8 = undefined;
            const line_format: []const u8 = "{d},{d},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d}\n";
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
                band.step_seconds,
                band.return_fluid_steps,
                band.return_action_rate_sum,
                band.return_jerk_sum,
            });
            try log.appendSlice(gpa, line);
        }
    }
};

pub const JudgeLog = struct {
    /// The file's first line: its columns - the line's place (`batch`, `training_minutes`, `clip`), then every field
    /// of `robot_track.Judgement` by its name, the quality's sums flattened into columns of their own names.
    pub const header: []const u8 = headerOf();

    fn headerOf() []const u8 {
        comptime var text: []const u8 = "batch,training_minutes,clip";
        inline for (@typeInfo(robot_track.Judgement).@"struct".field_names) |field_name| {
            if (comptime eql(u8, field_name, "quality")) {
                inline for (@typeInfo(robot_track.QualitySums).@"struct".field_names) |quality_field_name| {
                    text = text ++ "," ++ quality_field_name;
                }
            } else {
                text = text ++ "," ++ field_name;
            }
        }
        return text ++ "\n";
    }

    /// Appends the line of one judgement of clip `clip` - its label, "dance" or "get-up" - made after `batches`
    /// batches and `training_minutes` minutes of training (both zero for the servo's). Every number written as the
    /// shortest decimal that reads back to the same number, so a line read back is the judgement written. Memory:
    /// `log` grows with `gpa`, as its owner's.
    pub fn appendLine(
        gpa: Allocator,
        log: *ArrayList(u8),
        batches: u64,
        training_minutes: f32,
        clip: []const u8,
        judgement: robot_track.Judgement,
    ) !void {
        var number_buffer: [48]u8 = undefined;
        const place: []const u8 = try bufPrint(&number_buffer, "{d},{d},", .{ batches, training_minutes });
        try log.appendSlice(gpa, place);
        try log.appendSlice(gpa, clip);
        inline for (@typeInfo(robot_track.Judgement).@"struct".field_names) |field_name| {
            if (comptime eql(u8, field_name, "quality")) {
                inline for (@typeInfo(robot_track.QualitySums).@"struct".field_names) |quality_field_name| {
                    const QualityNumber: type = @FieldType(robot_track.QualitySums, quality_field_name);
                    const quality_value: QualityNumber = @field(judgement.quality, quality_field_name);
                    const text: []const u8 = try bufPrint(&number_buffer, ",{d}", .{quality_value});
                    try log.appendSlice(gpa, text);
                }
            } else {
                const text: []const u8 = try bufPrint(&number_buffer, ",{d}", .{@field(judgement, field_name)});
                try log.appendSlice(gpa, text);
            }
        }
        try log.append(gpa, '\n');
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
        var judgement: robot_track.Judgement = undefined;
        inline for (@typeInfo(robot_track.Judgement).@"struct".field_names) |field_name| {
            if (comptime eql(u8, field_name, "quality")) {
                inline for (@typeInfo(robot_track.QualitySums).@"struct".field_names) |quality_field_name| {
                    const Number: type = @FieldType(robot_track.QualitySums, quality_field_name);
                    @field(judgement.quality, quality_field_name) = nextNumber(Number, &columns) orelse return null;
                }
            } else {
                const Number: type = @FieldType(robot_track.Judgement, field_name);
                @field(judgement, field_name) = nextNumber(Number, &columns) orelse return null;
            }
        }
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

    /// The next column as a number of type `Number` - an unsigned integer, an f32 or an f64; null when there is
    /// none, or it is not one.
    fn nextNumber(comptime Number: type, columns: *std.mem.SplitIterator(u8, .scalar)) ?Number {
        const column: []const u8 = columns.next() orelse return null;
        return switch (@typeInfo(Number)) {
            .int => parseInt(Number, column, 10) catch null,
            .float => parseFloat(Number, column) catch null,
            else => @compileError("a judgement's column is an integer or a float, not " ++ @typeName(Number)),
        };
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

    /// THE SUCCESS BAR OF SUPERMIMIC's EVALUATION (BlinkMimic's): the clips' mean normalised return a run must reach,
    /// every clip completed beside it (`superMimicSuccess`).
    pub const success_normalised_return: f32 = 0.82;

    /// A judgement at which a run first succeeded (`superMimicSuccess`): its round, its training minutes as the
    /// judgement recorded them, and the clips' mean normalised return there.
    pub const SuperMimicSuccess = struct {
        batch: u64,
        training_minutes: f32,
        mean_normalised_return: f32,
    };

    /// THE FIRST JUDGEMENT AT WHICH A RUN SUCCEEDS, by SuperMimic's evaluation (`judge.csv`'s text): of the judgements
    /// after the servo's (batch 0), the first whose every clip of `clip_labels` was judged whole - its "/whole" line,
    /// one start from the clip's first frame - COMPLETED (run to the clip's end without losing the reference), and
    /// whose clips' mean normalised return (`Judgement.superMimicNormalisedReturn` at `scales`) is `bar` or more. Null
    /// while none has. A judgement missing a clip's whole line does not succeed. The whole history is read, so the
    /// answer holds across a resume.
    pub fn superMimicSuccess(
        judgements_text: []const u8,
        clip_labels: []const []const u8,
        scales: robot_track.SuperMimicScales,
        bar: f32,
    ) ?SuperMimicSuccess {
        assertf(clip_labels.len > 0 and clip_labels.len <= 64, @src(), "{d} clips", .{clip_labels.len});
        const all_bits: u64 = maxInt(u64);
        const unused_bits: u6 = @intCast(64 - clip_labels.len);
        const every_clip: u64 = all_bits >> unused_bits;
        var judgement: WholeClips = .{};
        var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, judgements_text, '\n');
        while (lines.next()) |text| {
            const line: Line = parseLine(text) orelse continue;
            if (line.batch == 0) {
                continue;
            }
            const clip_index: usize = wholeClipIndex(line.clip, clip_labels) orelse continue;
            // A new judgement begins: the one before decided.
            if (line.batch != judgement.batch) {
                if (judgement.succeeds(every_clip, bar)) |success| {
                    return success;
                }
                judgement = .{ .batch = line.batch, .training_minutes = line.training_minutes };
            }
            const clip_bit: u64 = @as(u64, 1) << @intCast(clip_index);
            const is_new_clip: bool = judgement.clips_seen & clip_bit == 0;
            if (!is_new_clip) {
                continue;
            }
            judgement.clips_seen |= clip_bit;
            const whole: robot_track.Judgement = line.judgement;
            const reached_every_end: bool = whole.reached_end == whole.starts and whole.starts > 0;
            const is_completed: bool = whole.failures == 0 and reached_every_end;
            if (is_completed) {
                judgement.clips_completed |= clip_bit;
            }
            judgement.normalised_return_sum += whole.superMimicNormalisedReturn(scales);
        }
        return judgement.succeeds(every_clip, bar);
    }

    /// One judgement's whole-clip lines, gathered (`superMimicSuccess`): which clips were seen and which completed,
    /// as bits by the clip's place in the labels, and their normalised returns' sum.
    const WholeClips = struct {
        batch: u64 = 0,
        training_minutes: f32 = 0,
        clips_seen: u64 = 0,
        clips_completed: u64 = 0,
        normalised_return_sum: f32 = 0,

        fn succeeds(judgement: WholeClips, every_clip: u64, bar: f32) ?SuperMimicSuccess {
            const every_clip_completed: bool = judgement.clips_seen == every_clip and
                judgement.clips_completed == every_clip;
            if (!every_clip_completed) {
                return null;
            }
            const clip_count: f32 = float(@popCount(every_clip));
            const mean_normalised_return: f32 = judgement.normalised_return_sum / clip_count;
            if (mean_normalised_return < bar) {
                return null;
            }
            const success: SuperMimicSuccess = .{
                .batch = judgement.batch,
                .training_minutes = judgement.training_minutes,
                .mean_normalised_return = mean_normalised_return,
            };
            return success;
        }
    };

    /// Which of `clip_labels` a line's clip is the whole-clip judgement of - "dance/whole" for "dance" - or null.
    fn wholeClipIndex(line_clip: []const u8, clip_labels: []const []const u8) ?usize {
        const suffix: []const u8 = "/whole";
        if (!endsWith(u8, line_clip, suffix)) {
            return null;
        }
        const clip: []const u8 = line_clip[0 .. line_clip.len - suffix.len];
        for (clip_labels, 0..) |label, index| {
            if (eql(u8, label, clip)) {
                return index;
            }
        }
        return null;
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

    /// Reads the log's whole lines past `bytes_read`, `log_text` being the whole log as its file holds it now, each
    /// line's steps counted at `log_steps_per_second` (`GenoRun.logStepsPerSecond`: a SuperTrack log's are decisions).
    /// A last line without its newline - the log being written as it is read - waits for the next read. A log
    /// shorter than what was read - a run carried on from an earlier save - is read again from its start, its header
    /// included.
    pub fn readMore(
        self: *RunCurve,
        gpa: Allocator,
        log_text: []const u8,
        log_steps_per_second: f32,
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
            try self.addLine(gpa, point_line, columns, log_steps_per_second);
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
        log_steps_per_second: f32,
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
        const seconds_to_failure: ?f32 = ppo_track.secondsToFailure(steps_watched, failures, log_steps_per_second);
        try self.points.append(gpa, .{
            .trained_units = line.trained_units,
            .training_minutes = line.training_minutes,
            .seconds_to_failure = seconds_to_failure,
        });
    }
};

test "RunCurve: a SuperTrack run's log counts decisions - at 30 a second where it decides every 2 physics steps" {
    // A round of 24 characters deciding 16 times: 384 decisions watched, 4 failures - a failure every 96 decisions,
    // 3.2 s at Geno's 30 decisions a second (`GenoRun.logStepsPerSecond`), where a PPO log's steps would be physics
    // steps, 60 a second.
    const supertrack_run: GenoRun = .{ .learner = .{ .supertrack = .{ .decide_every = 2 } } };
    const ppo_run: GenoRun = .{};
    try expectEqual(@as(f32, 30), supertrack_run.logStepsPerSecond(60));
    try expectEqual(@as(f32, 60), ppo_run.logStepsPerSecond(60));
    var log: ArrayList(u8) = .empty;
    defer log.deinit(testing_allocator);
    try log.appendSlice(testing_allocator, SuperTrackLog.header);
    try SuperTrackLog.appendLine(testing_allocator, &log, .{
        .round = 1,
        .training_minutes = 0.1,
        .steps_watched = 384,
        .failures = 4,
        .world_updates = 16,
        .policy_updates = 16,
    });
    var curve: RunCurve = .{};
    defer curve.deinit(testing_allocator);
    try curve.readMore(testing_allocator, log.items, supertrack_run.logStepsPerSecond(60));
    try expectApproxEqAbs(@as(f32, 3.2), curve.points.items[0].seconds_to_failure.?, 1e-5);
}

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

/// A reading of a run learning as it should: the replay moving, the teacher's labels and lookaheads arriving, both
/// networks updated and moved, their gradients there, the offsets a tenth of a radian.
fn healthyTripwireReading(networks: []const NetworkMotion) TripwireReading {
    return .{
        .replay_moved = true,
        .teacher = .{ .labelled_records = 40, .lookaheads = 6 },
        .networks = networks,
        .world_gradient_norm = 3.0,
        .policy_gradient_norm = 0.05,
        .offsets = .{ .largest = 0.9, .median = 0.1 },
    };
}

test "Tripwire: a run learning as it should fires none; each miss fires its own, in the table's order" {
    const bars: TripwireBars = .{};
    const moved = [_]NetworkMotion{
        .{ .name = "the world model", .updated = true, .largest_change = 2e-3 },
        .{ .name = "the policy", .updated = true, .largest_change = 4e-4 },
    };
    try expect(firstTripwire(healthyTripwireReading(&moved), bars) == null);
    // Each miss alone, and what fires.
    var still: TripwireReading = healthyTripwireReading(&moved);
    still.replay_moved = false;
    try expectEqual(Tripwire.replay_still, firstTripwire(still, bars).?.tripwire);
    var unlabelled: TripwireReading = healthyTripwireReading(&moved);
    unlabelled.teacher = .{ .labelled_records = 0, .lookaheads = 6 };
    try expectEqual(Tripwire.labels_absent, firstTripwire(unlabelled, bars).?.tripwire);
    var unrecorded: TripwireReading = healthyTripwireReading(&moved);
    unrecorded.teacher = .{ .labelled_records = 40, .lookaheads = 0 };
    try expectEqual(Tripwire.lookaheads_absent, firstTripwire(unrecorded, bars).?.tripwire);
    var vanished: TripwireReading = healthyTripwireReading(&moved);
    vanished.policy_gradient_norm = 0;
    const vanished_fired: TripwireFired = firstTripwire(vanished, bars).?;
    try expectEqual(Tripwire.gradient_vanished, vanished_fired.tripwire);
    try expectEqualStrings("the policy", vanished_fired.network);
    var dead: TripwireReading = healthyTripwireReading(&moved);
    dead.offsets = .{ .largest = 0, .median = 0 };
    try expectEqual(Tripwire.offsets_dead, firstTripwire(dead, bars).?.tripwire);
    // A scale of almost nothing: offsets of a billionth of a radian are no action either.
    var faint: TripwireReading = healthyTripwireReading(&moved);
    faint.offsets = .{ .largest = 1e-9, .median = 1e-10 };
    try expectEqual(Tripwire.offsets_dead, firstTripwire(faint, bars).?.tripwire);
    var saturated: TripwireReading = healthyTripwireReading(&moved);
    saturated.offsets = .{ .largest = 9, .median = 2 };
    try expectEqual(Tripwire.offsets_saturated, firstTripwire(saturated, bars).?.tripwire);
    // A NaN fails its bar.
    var not_a_number: TripwireReading = healthyTripwireReading(&moved);
    not_a_number.world_gradient_norm = nan(f32);
    try expectEqual(Tripwire.gradient_vanished, firstTripwire(not_a_number, bars).?.tripwire);
    // Without a teacher, nothing is asked of one; a part not measured is not read.
    var untaught: TripwireReading = healthyTripwireReading(&moved);
    untaught.teacher = null;
    untaught.world_gradient_norm = null;
    untaught.offsets = null;
    try expect(firstTripwire(untaught, bars) == null);
    // The first in the order wins: a still replay before a vanished gradient.
    var both: TripwireReading = vanished;
    both.replay_moved = false;
    try expectEqual(Tripwire.replay_still, firstTripwire(both, bars).?.tripwire);
}

test "Tripwire: a network updated and unmoved is named; one not yet updated is not judged" {
    const bars: TripwireBars = .{};
    // A rate of almost nothing: the critic's weights moved by less than the floor.
    const frozen_critic = [_]NetworkMotion{
        .{ .name = "the world model", .updated = true, .largest_change = 2e-3 },
        .{ .name = "the critic", .updated = true, .largest_change = 1e-9 },
    };
    const fired: TripwireFired = firstTripwire(healthyTripwireReading(&frozen_critic), bars).?;
    try expectEqual(Tripwire.weights_unmoved, fired.tripwire);
    try expectEqualStrings("the critic", fired.network);
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    try expectEqualStrings("weights_unmoved: the critic", try fired.text(arena_state.allocator()));
    // A flow before its first example: no updates, so no motion is asked of it.
    const untrained_flow = [_]NetworkMotion{
        .{ .name = "the world model", .updated = true, .largest_change = 2e-3 },
        .{ .name = "the flow", .updated = false, .largest_change = 0 },
    };
    try expect(firstTripwire(healthyTripwireReading(&untrained_flow), bars) == null);
}

test "Tripwire: the weights' largest change, and the offsets' largest and median magnitudes" {
    const before = [_]f32{ 0.1, -0.2, 0.3, 0.0 };
    const after = [_]f32{ 0.1, -0.25, 0.31, 0.0 };
    try expectApproxEqAbs(@as(f32, 0.05), largestChange(&before, &after), 1e-6);
    try expectEqual(@as(f32, 0), largestChange(&before, &before));
    // Five offsets: the median is the middle magnitude; four: the upper of the two middle ones.
    const offsets = [_]f32{ -0.4, 0.1, 0.05, -2.0, 0.2 };
    var scratch: [offsets.len]f32 = undefined;
    const magnitudes: OffsetMagnitudes = offsetMagnitudes(&offsets, &scratch);
    try expectEqual(@as(f32, 2.0), magnitudes.largest);
    try expectEqual(@as(f32, 0.2), magnitudes.median);
    const even = [_]f32{ 0.3, -0.1, 0.2, 0.4 };
    var even_scratch: [even.len]f32 = undefined;
    try expectEqual(@as(f32, 0.3), offsetMagnitudes(&even, &even_scratch).median);
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
        .quality = .{
            .steps = 3_456,
            .body_position_error_sum = 0.123_456_789,
            .body_rotation_error_sum = 2.718_281_828,
            .joint_error_sum = 31.415_926_5,
            .foot_steps = 13_824,
            .contacts_agreeing = 10_001,
            .slip_speed_sum = 456.789,
            .penetration_sum = 0.000_123_4,
        },
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

// ---- The report of a set of runs ----
//
// A NIGHT's RUNS SIDE BY SIDE (`geno_trainer --report=<runs folder>`). A night - or an afternoon - is a set of runs
// that differ from a control in one thing each, and its question is read off them together: did the control learn,
// what did each part add, and was that more than the noise between two runs of one recipe. The report reads the files
// every run folder holds - the run's parameters, its status, its log, its judgements, and its kernels' times where it
// timed them - and writes, for the set:
//
//   * a line per run: its state, its minutes and rounds, a round's time, when its phase 2 began, and its training's own
//     time to failure in each quarter of its minutes - the shape of its learning, from its log;
//   * the judge's verdict on each run, its clips' starts pooled, beside the servo's on the same starts, and against the
//     control: the difference in judged time to failure measured by two yardsticks - the control's repeats at other
//     seeds (the noise of one recipe run twice) and the two judgements' standard errors together (the noise of the
//     judge's starts). A difference inside either is noise;
//   * each clip's verdict, run by run;
//   * at each run's end, where its learning stood: the world model's loss and its gate's readings, the policy's losses,
//     the imagined root's drift;
//   * the device's time by kernel, for a run that timed every dispatch.
//
// The control is the run named so, or the first in the folder's order; its repeats are the runs whose recipe is the
// control's but for the seed - found by comparing the recipes, not their names.

/// A RUN's LOG READ AS A TABLE (the report's): the columns as its header names them, and each line's numbers - every
/// column of a run's log is a number. A line that is not numbers throughout, or not as long as the header, is skipped.
/// Read by name, so a log written by an older trainer, with fewer columns, reads as far as it goes. Memory: the names
/// point into the text; the rows are in `arena`.
pub const NumberTable = struct {
    names: []const []const u8 = &.{},
    rows: []const []const f64 = &.{},

    /// The table of the log `text`: its first line the header.
    pub fn read(arena: Allocator, text: []const u8) !NumberTable {
        var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
        const header_line: []const u8 = lines.next() orelse return .{};
        var names: ArrayList([]const u8) = .empty;
        var header_names: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, header_line, ',');
        while (header_names.next()) |name| {
            try names.append(arena, name);
        }
        var rows: ArrayList([]const f64) = .empty;
        while (lines.next()) |line_text| {
            const row: []f64 = try arena.alloc(f64, names.items.len);
            if (!readNumbers(line_text, row)) {
                continue;
            }
            try rows.append(arena, row);
        }
        const table: NumberTable = .{ .names = names.items, .rows = rows.items };
        return table;
    }

    /// Whether `line_text` is exactly `numbers.len` numbers, written into `numbers`.
    fn readNumbers(line_text: []const u8, numbers: []f64) bool {
        var values: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, line_text, ',');
        var count: usize = 0;
        while (values.next()) |value| {
            if (count == numbers.len) {
                return false;
            }
            numbers[count] = parseFloat(f64, value) catch return false;
            count += 1;
        }
        return count == numbers.len;
    }

    /// Where the column `name` is, or null when the header has none.
    pub fn columnOf(table: *const NumberTable, name: []const u8) ?usize {
        for (table.names, 0..) |column_name, column| {
            if (eql(u8, column_name, name)) {
                return column;
            }
        }
        return null;
    }

    /// The column `name`'s number on row `row`, or null when the header has no such column.
    pub fn numberAt(table: *const NumberTable, row: usize, name: []const u8) ?f64 {
        const column: usize = table.columnOf(name) orelse return null;
        return table.rows[row][column];
    }

    /// The column `name`'s numbers summed over every row; 0 when the header has no such column.
    pub fn sumOf(table: *const NumberTable, name: []const u8) f64 {
        const column: usize = table.columnOf(name) orelse return 0;
        var sum: f64 = 0;
        for (table.rows) |row| {
            sum += row[column];
        }
        return sum;
    }
};

/// SEVERAL JUDGEMENTS AS ONE (the report's "all clips"): every count and sum added - each clip's starts kept as starts
/// of their own - so that the pooled time to failure, and its standard error, are those of every start together. The
/// judgements must share their step's length (`robot_track.Judgement.frame_time`), as one run's judgements of one
/// policy do.
pub fn pooledJudgement(judgements: []const robot_track.Judgement) robot_track.Judgement {
    var pooled: robot_track.Judgement = zeroes(robot_track.Judgement);
    for (judgements) |judgement| {
        inline for (@typeInfo(robot_track.Judgement).@"struct".field_names) |field_name| {
            if (comptime eql(u8, field_name, "frame_time")) {
                pooled.frame_time = judgement.frame_time;
            } else if (comptime eql(u8, field_name, "quality")) {
                inline for (@typeInfo(robot_track.QualitySums).@"struct".field_names) |quality_field_name| {
                    @field(pooled.quality, quality_field_name) += @field(judgement.quality, quality_field_name);
                }
            } else {
                @field(pooled, field_name) += @field(judgement, field_name);
            }
        }
    }
    return pooled;
}

/// What a run folder holds for the report (`ReportRun.read`): its name, and each file's text - null where the folder
/// has none. `run.zon` and `status.zon` end in a zero, as their parsers read them.
pub const ReportTexts = struct {
    name: []const u8,
    parameters: ?[:0]const u8 = null,
    status: ?[:0]const u8 = null,
    log: ?[]const u8 = null,
    judgements: ?[]const u8 = null,
    kernel_times: ?[]const u8 = null,
};

/// When a run's phase 2 began (`ReportRun.phaseTwo`), as its log's label share says: 1 through phase 1, which trains
/// the policy on the teacher's labels alone; below 1 from phase 2, as the world model's rollouts are ramped in; 0 all
/// along for a run without phases.
pub const PhaseTwo = union(enum) {
    /// A run without phases: its policy learns through the world model from the first round.
    no_phases,
    /// Phase 1 all run long: the gate never passed, nor a bound came.
    phase_one_throughout,
    /// Phase 2 from this many training minutes.
    began_at_minutes: f32,
};

/// What a clip's "/whole" line adds to its name: SuperMimic's evaluation of the clip, one start from its first frame.
const whole_clip_suffix: []const u8 = "/whole";

/// A judgement's whole-clip lines together (`ReportRun.wholeReturnAt`).
pub const WholeReturn = struct {
    return_sum: f32 = 0,
    clips: usize = 0,
    completed: usize = 0,

    pub fn meanReturn(whole: WholeReturn) f32 {
        return whole.return_sum / float(@max(whole.clips, 1));
    }
};

/// ONE RUN AS THE REPORT READS IT (`RunsReport`): its recipe, its status, its log as a table, its judgements' lines and
/// its kernels' times - each empty where its folder has none. Memory: everything in the caller's arena, pointing into
/// the texts it was read from, which must outlive it.
pub const ReportRun = struct {
    name: []const u8,
    /// Its recipe; null when its `run.zon` cannot be read.
    run: ?GenoRun,
    status: ?RunStatus,
    log: NumberTable,
    judgements: []const JudgeLog.Line,
    /// `kernel_times.csv` as written - the longest kernel first (`KernelTimeLog`) - or empty.
    kernel_times: []const u8,

    /// The run in `texts`. Memory: `gpa` the parsers' working memory, freed before it returns; the run in `arena`.
    pub fn read(gpa: Allocator, arena: Allocator, texts: ReportTexts) !ReportRun {
        var failure: GenoRun.ParseFailure = .{ .description = "" };
        const run: ?GenoRun = if (texts.parameters) |source|
            GenoRun.parse(gpa, arena, source, &failure) catch |err| switch (err) {
                error.ParseZon => null,
                else => return err,
            }
        else
            null;
        const status: ?RunStatus = if (texts.status) |source| RunStatus.parse(gpa, arena, source) else null;
        const log: NumberTable = if (texts.log) |text| try .read(arena, text) else .{};
        var judgements: ArrayList(JudgeLog.Line) = .empty;
        if (texts.judgements) |text| {
            var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, text, '\n');
            while (lines.next()) |line_text| {
                const line: JudgeLog.Line = JudgeLog.parseLine(line_text) orelse continue;
                try judgements.append(arena, line);
            }
        }
        const read_run: ReportRun = .{
            .name = texts.name,
            .run = run,
            .status = status,
            .log = log,
            .judgements = judgements.items,
            .kernel_times = texts.kernel_times orelse "",
        };
        return read_run;
    }

    /// Its training minutes at its log's last line; 0 before any.
    pub fn minutes(self: *const ReportRun) f32 {
        const row_count: usize = self.log.rows.len;
        if (row_count == 0) {
            return 0;
        }
        const last_minutes: f64 = self.log.numberAt(row_count - 1, "training_minutes") orelse return 0;
        return @floatCast(last_minutes);
    }

    /// A round's mean seconds over the run - its acting, its training and the pauses between rounds (saving, judging)
    /// together: its minutes over its rounds. Null before a round.
    pub fn roundSeconds(self: *const ReportRun) ?f32 {
        const round_count: usize = self.log.rows.len;
        if (round_count == 0) {
            return null;
        }
        return self.minutes() * 60.0 / float(round_count);
    }

    /// The column `name`'s mean over the run's rounds; null without rounds or without the column.
    pub fn meanOf(self: *const ReportRun, name: []const u8) ?f64 {
        const round_count: usize = self.log.rows.len;
        if (round_count == 0) {
            return null;
        }
        _ = self.log.columnOf(name) orelse return null;
        return self.log.sumOf(name) / float64(round_count);
    }

    /// The column `name` at the run's last round; null without rounds or without the column.
    pub fn lastOf(self: *const ReportRun, name: []const u8) ?f64 {
        const round_count: usize = self.log.rows.len;
        if (round_count == 0) {
            return null;
        }
        return self.log.numberAt(round_count - 1, name);
    }

    /// WHEN ITS PHASE 2 BEGAN (`PhaseTwo`): the training minutes of the first round whose label share fell below 1,
    /// after rounds at 1.
    pub fn phaseTwo(self: *const ReportRun) PhaseTwo {
        const share_column: usize = self.log.columnOf("label_share") orelse return .no_phases;
        const minutes_column: usize = self.log.columnOf("training_minutes") orelse return .no_phases;
        var has_had_phase_one: bool = false;
        for (self.log.rows) |row| {
            const label_share: f64 = row[share_column];
            const is_phase_one: bool = label_share >= 1;
            if (is_phase_one) {
                has_had_phase_one = true;
                continue;
            }
            if (has_had_phase_one) {
                return .{ .began_at_minutes = @floatCast(row[minutes_column]) };
            }
        }
        return if (has_had_phase_one) .phase_one_throughout else .no_phases;
    }

    /// THE TRAINING's OWN TIME TO FAILURE IN EACH QUARTER OF ITS MINUTES: the decisions or steps its log watched in a
    /// quarter over the failures there, at `log_steps_per_second` (`GenoRun.logStepsPerSecond`) - null for a quarter
    /// with no failure, or no round. Training's own measure: under its pushes and its starts in trouble, so a run
    /// without them is measured otherwise, and only the judge compares every run alike.
    pub fn quarterSecondsToFailure(self: *const ReportRun, log_steps_per_second: f32) [4]?f32 {
        var quarters: [4]?f32 = @splat(null);
        const watched_column: usize = self.log.columnOf("steps_watched") orelse return quarters;
        const failures_column: usize = self.log.columnOf("failures") orelse return quarters;
        const minutes_column: usize = self.log.columnOf("training_minutes") orelse return quarters;
        const total_minutes: f32 = self.minutes();
        if (total_minutes <= 0) {
            return quarters;
        }
        var watched: [4]u64 = @splat(0);
        var failures: [4]u64 = @splat(0);
        for (self.log.rows) |row| {
            const row_minutes: f32 = @floatCast(row[minutes_column]);
            const share_of_run: f32 = @max(row_minutes / total_minutes, 0);
            const quarter_reached: usize = @trunc(share_of_run * 4);
            const quarter: usize = @min(quarter_reached, 3);
            const row_watched: u64 = @trunc(row[watched_column]);
            const row_failures: u64 = @trunc(row[failures_column]);
            watched[quarter] += row_watched;
            failures[quarter] += row_failures;
        }
        for (&quarters, watched, failures) |*seconds, quarter_watched, quarter_failures| {
            seconds.* = ppo_track.secondsToFailure(quarter_watched, quarter_failures, log_steps_per_second);
        }
        return quarters;
    }

    /// Its last judgement's batch - its policy's, after the servo's at batch 0 - or null before any.
    pub fn lastJudgedBatch(self: *const ReportRun) ?u64 {
        var last_batch: ?u64 = null;
        for (self.judgements) |line| {
            if (line.batch == 0) {
                continue;
            }
            const is_later: bool = if (last_batch) |batch| line.batch > batch else true;
            if (is_later) {
                last_batch = line.batch;
            }
        }
        return last_batch;
    }

    /// The training minutes its judgement at batch `batch` was made at; 0 when it has none.
    pub fn judgedMinutesAt(self: *const ReportRun, batch: u64) f32 {
        for (self.judgements) |line| {
            if (line.batch == batch) {
                return line.training_minutes;
            }
        }
        return 0;
    }

    /// The judgement of clip `clip` at batch `batch` - the servo's at 0 - or null when there is none. A clip's "/whole"
    /// line is the clip `<clip>/whole`.
    pub fn judgementOf(
        self: *const ReportRun,
        batch: u64,
        clip: []const u8,
    ) ?JudgeLog.Line {
        for (self.judgements) |line| {
            if (line.batch == batch and eql(u8, line.clip, clip)) {
                return line;
            }
        }
        return null;
    }

    /// Its clips' starts at batch `batch` pooled (`pooledJudgement`): every judged clip's line but the "/whole" ones;
    /// null when the batch has none. Memory: the clips' judgements gathered in `arena`.
    pub fn pooledAt(
        self: *const ReportRun,
        arena: Allocator,
        batch: u64,
    ) !?robot_track.Judgement {
        var gathered: ArrayList(robot_track.Judgement) = .empty;
        for (self.judgements) |line| {
            const is_whole: bool = endsWith(u8, line.clip, whole_clip_suffix);
            if (line.batch != batch or is_whole) {
                continue;
            }
            try gathered.append(arena, line.judgement);
        }
        if (gathered.items.len == 0) {
            return null;
        }
        return pooledJudgement(gathered.items);
    }

    /// Its clips' mean normalised return by SuperMimic's evaluation at batch `batch` - the "/whole" lines, one start
    /// from each clip's first frame, at Geno's task's scales - and how many of them ran to the clip's end; null when
    /// the batch has no whole line.
    pub fn wholeReturnAt(self: *const ReportRun, batch: u64) ?WholeReturn {
        var whole_return: WholeReturn = .{};
        for (self.judgements) |line| {
            const is_whole: bool = endsWith(u8, line.clip, whole_clip_suffix);
            if (line.batch != batch or !is_whole) {
                continue;
            }
            const judgement: robot_track.Judgement = line.judgement;
            whole_return.return_sum += judgement.superMimicNormalisedReturn(tracking_task.super_mimic);
            whole_return.clips += 1;
            const completed: bool = judgement.failures == 0 and judgement.reached_end == judgement.starts;
            if (completed) {
                whole_return.completed += 1;
            }
        }
        return if (whole_return.clips == 0) null else whole_return;
    }

    /// The judge's clips at batch `batch`, in the order judged - the "/whole" lines left out. Memory: in `arena`.
    pub fn clipsAt(
        self: *const ReportRun,
        arena: Allocator,
        batch: u64,
    ) ![]const []const u8 {
        var clips: ArrayList([]const u8) = .empty;
        for (self.judgements) |line| {
            const is_whole: bool = endsWith(u8, line.clip, whole_clip_suffix);
            if (line.batch != batch or is_whole) {
                continue;
            }
            try clips.append(arena, line.clip);
        }
        return clips.items;
    }
};

/// A RUN AGAINST THE CONTROL (`RunsReport`), by the pooled judged time to failure: the difference, and the two
/// yardsticks it is measured by - the control's repeats' largest gap from it, and the two judgements' standard errors
/// combined, sqrt(se_run^2 + se_control^2). Beyond twice the standard errors and beyond the repeats' gap, a difference;
/// inside either, noise - two seeds of one recipe, or two draws of the judge's starts, could give as much.
pub const AgainstControl = struct {
    difference_seconds: f32,
    repeats_gap_seconds: ?f32,
    standard_error_seconds: ?f32,

    pub const Verdict = enum { longer, shorter, within_noise };

    pub fn verdict(against: AgainstControl) Verdict {
        const error_bar: f32 = if (against.standard_error_seconds) |standard_error| 2 * standard_error else 0;
        const gap_bar: f32 = against.repeats_gap_seconds orelse 0;
        const bar: f32 = @max(error_bar, gap_bar);
        if (against.difference_seconds > bar) {
            return .longer;
        }
        if (against.difference_seconds < -bar) {
            return .shorter;
        }
        return .within_noise;
    }

    /// The difference against judged times `run` and `control` (seconds, and their standard errors), with the repeats'
    /// gap.
    pub fn of(run: Timed, control: Timed, repeats_gap_seconds: ?f32) AgainstControl {
        const both_errors: ?f32 = if (run.standard_error) |run_error|
            if (control.standard_error) |control_error|
                @sqrt(run_error * run_error + control_error * control_error)
            else
                null
        else
            null;
        const against: AgainstControl = .{
            .difference_seconds = run.seconds - control.seconds,
            .repeats_gap_seconds = repeats_gap_seconds,
            .standard_error_seconds = both_errors,
        };
        return against;
    }

    /// A judged time to failure and its standard error (`robot_track.Judgement.meanTimeToFailureError`).
    pub const Timed = struct {
        seconds: f32,
        standard_error: ?f32,

        pub fn of(judgement: robot_track.Judgement) Timed {
            return .{ .seconds = judgement.meanTimeToFailure(), .standard_error = judgement.meanTimeToFailureError() };
        }
    };
};

/// THE REPORT OF A SET OF RUNS (this section's head), written to a writer: the runs, their judgements against the
/// control's, clip by clip, where each run's learning stood at its end, and the kernels' times of a run that timed
/// them.
pub const RunsReport = struct {
    runs: []const ReportRun,
    /// The control's place in `runs`, and whether each run is one of its repeats - its recipe but for the seed.
    control: usize,
    is_repeat: []const bool,
    /// The physics steps a second of the runs' model (60 for Geno): what their logs' steps are counted against.
    physics_steps_per_second: f32,

    /// Whether `a` and `b` are one recipe but for their learners' seeds: the two written as `run.zon` with the seeds
    /// made equal, compared. Memory: the two texts in `gpa`, freed before it returns.
    fn sameRecipeButSeed(gpa: Allocator, a: ?GenoRun, b: ?GenoRun) !bool {
        var first: GenoRun = a orelse return false;
        var second: GenoRun = b orelse return false;
        switch (first.learner) {
            inline else => |*learner| learner.seed = 0,
        }
        switch (second.learner) {
            inline else => |*learner| learner.seed = 0,
        }
        var first_text: Io.Writer.Allocating = .init(gpa);
        defer first_text.deinit();
        var second_text: Io.Writer.Allocating = .init(gpa);
        defer second_text.deinit();
        try first.write(&first_text.writer);
        try second.write(&second_text.writer);
        return eql(u8, first_text.written(), second_text.written());
    }

    /// The report of `runs`, the control the one named `control_name` - or, with none so named, the first. Memory:
    /// `gpa` the recipes' comparison's scratch, freed before it returns; the report in `arena`, pointing into `runs`.
    pub fn init(
        gpa: Allocator,
        arena: Allocator,
        runs: []const ReportRun,
        control_name: []const u8,
        physics_steps_per_second: f32,
    ) !RunsReport {
        assertf(runs.len > 0, @src(), "a report of no runs", .{});
        const control: usize = for (runs, 0..) |run, index| {
            if (eql(u8, run.name, control_name)) {
                break index;
            }
        } else 0;
        const is_repeat: []bool = try arena.alloc(bool, runs.len);
        for (runs, is_repeat, 0..) |run, *repeat, index| {
            repeat.* = index != control and try sameRecipeButSeed(gpa, runs[control].run, run.run);
        }
        const runs_report: RunsReport = .{
            .runs = runs,
            .control = control,
            .is_repeat = is_repeat,
            .physics_steps_per_second = physics_steps_per_second,
        };
        return runs_report;
    }

    /// The repeats' largest gap from the control in pooled judged time to failure, each at its last judgement; null
    /// without a repeat judged. Memory: the pooled judgements' scratch in `arena`.
    fn repeatsGap(self: *const RunsReport, arena: Allocator) !?f32 {
        const control_run: *const ReportRun = &self.runs[self.control];
        const control_batch: u64 = control_run.lastJudgedBatch() orelse return null;
        const control_judged: robot_track.Judgement = try control_run.pooledAt(arena, control_batch) orelse return null;
        const control_seconds: f32 = control_judged.meanTimeToFailure();
        var largest_gap: ?f32 = null;
        for (self.runs, self.is_repeat) |*run, is_repeat| {
            if (!is_repeat) {
                continue;
            }
            const batch: u64 = run.lastJudgedBatch() orelse continue;
            const judged: robot_track.Judgement = try run.pooledAt(arena, batch) orelse continue;
            const gap: f32 = @abs(judged.meanTimeToFailure() - control_seconds);
            largest_gap = if (largest_gap) |gap_so_far| @max(gap_so_far, gap) else gap;
        }
        return largest_gap;
    }

    /// `value` in a field of `width` at `decimals` decimals, or a dash where there is none.
    fn writeOptionalNumber(
        writer: *Io.Writer,
        value: ?f32,
        width: usize,
        decimals: u8,
    ) !void {
        const number: f32 = value orelse {
            try writer.splatByteAll(' ', width - 1);
            try writer.writeAll("-");
            return;
        };
        var number_buffer: [32]u8 = undefined;
        const text: []const u8 = switch (decimals) {
            1 => try bufPrint(&number_buffer, "{d:.1}", .{number}),
            2 => try bufPrint(&number_buffer, "{d:.2}", .{number}),
            else => try bufPrint(&number_buffer, "{d:.3}", .{number}),
        };
        if (text.len < width) {
            try writer.splatByteAll(' ', width - text.len);
        }
        try writer.writeAll(text);
    }

    /// The runs, a line each: state, minutes, rounds, a round's time and its acting's and training's means, phase 2,
    /// the training's time to failure by quarter.
    fn writeRuns(self: *const RunsReport, writer: *Io.Writer) !void {
        const control_name: []const u8 = self.runs[self.control].name;
        try writer.print("THE RUNS - {d}; the control {s}", .{ self.runs.len, control_name });
        var has_repeat: bool = false;
        for (self.runs, self.is_repeat) |run, is_repeat| {
            if (!is_repeat) {
                continue;
            }
            const joiner: []const u8 = if (has_repeat) ", " else "; its repeats at other seeds ";
            try writer.print("{s}{s}", .{ joiner, run.name });
            has_repeat = true;
        }
        try writer.print("\n\n{s:<24} {s:<10} {s:>7} {s:>6} {s:>7} {s:>6} {s:>6}  {s:<14}  training's own time to " ++
            "failure, s,\n", .{ "run", "state", "minutes", "rounds", "s/round", "acting", "train", "phase 2" });
        try writer.print("{s:<24} {s:<10} {s:>7} {s:>6} {s:>7} {s:>6} {s:>6}  {s:<14}  by quarter of its minutes\n", .{
            "",
            "",
            "",
            "",
            "",
            "s",
            "s",
            "",
        });
        for (self.runs) |*run| {
            const state_name: []const u8 = if (run.status) |status| @tagName(status.state) else "?";
            var phase_buffer: [32]u8 = undefined;
            const phase_text: []const u8 = switch (run.phaseTwo()) {
                .no_phases => "none: no phases",
                .phase_one_throughout => "never",
                .began_at_minutes => |began| try bufPrint(&phase_buffer, "at {d:.1} min", .{began}),
            };
            try writer.print("{s:<24} {s:<10} {d:>7.1} {d:>6} ", .{
                run.name,
                state_name,
                run.minutes(),
                run.log.rows.len,
            });
            try writeOptionalNumber(writer, run.roundSeconds(), 7, 2);
            const acting_seconds: ?f32 = if (run.meanOf("acting_ms")) |milliseconds|
                @floatCast(milliseconds / 1000)
            else
                null;
            const training_seconds: ?f32 = if (run.meanOf("training_ms")) |milliseconds|
                @floatCast(milliseconds / 1000)
            else
                null;
            try writer.writeAll(" ");
            try writeOptionalNumber(writer, acting_seconds, 6, 2);
            try writer.writeAll(" ");
            try writeOptionalNumber(writer, training_seconds, 6, 2);
            try writer.print("  {s:<14} ", .{phase_text});
            const log_steps_per_second: f32 = if (run.run) |recipe|
                recipe.logStepsPerSecond(self.physics_steps_per_second)
            else
                self.physics_steps_per_second;
            for (run.quarterSecondsToFailure(log_steps_per_second)) |seconds| {
                try writer.writeAll(" ");
                try writeOptionalNumber(writer, seconds, 6, 2);
            }
            try writer.writeAll("\n");
        }
        try writer.writeAll("\n");
    }

    /// One run's pooled judgement: minutes, time to failure (standard error), tracked share, bodies' error, the whole
    /// clips' mean return and how many ran to their end.
    fn writeJudgedLine(
        writer: *Io.Writer,
        name: []const u8,
        judged_minutes: f32,
        judged: robot_track.Judgement,
        whole: ?WholeReturn,
    ) !void {
        try writer.print("{s:<24} {d:>7.1}  {d:>7.2} ", .{ name, judged_minutes, judged.meanTimeToFailure() });
        if (judged.meanTimeToFailureError()) |standard_error| {
            try writer.print("({d:>5.2})", .{standard_error});
        } else {
            try writer.print("{s:>7}", .{"(-)"});
        }
        try writer.print("  {d:>7.2} {d:>6.1}  ", .{ judged.meanTrackedShare(), judged.quality.bodyPositionCm() });
        if (whole) |whole_return| {
            try writer.print("{d:>6.2} {d:>2}/{d:<2}", .{
                whole_return.meanReturn(),
                whole_return.completed,
                whole_return.clips,
            });
        } else {
            try writer.print("{s:>6} {s:>5}", .{ "-", "" });
        }
    }

    /// The judge's verdicts, each run's clips pooled at its last judgement, against the servo's and the control's.
    fn writeJudged(self: *const RunsReport, arena: Allocator, writer: *Io.Writer) !void {
        try writer.writeAll("THE JUDGE - each run's last judgement, its clips' starts pooled; against the control: " ++
            "beyond twice the standard errors\n" ++
            "and beyond the repeats' gap, longer or shorter; inside either, noise\n\n");
        try writer.print("{s:<24} {s:>7}  {s:>15}  {s:>7} {s:>6}  {s:>6} {s:>5}  {s:>7} {s:>7} {s:>7}  {s}\n", .{
            "run",
            "minutes",
            "time to failure",
            "tracked",
            "bodies",
            "return",
            "ended",
            "against",
            "x gap",
            "x error",
            "verdict",
        });
        try writer.print("{s:<24} {s:>7}  {s:>15}  {s:>7} {s:>6}  {s:>6} {s:>5}  {s:>7}\n", .{
            "",
            "",
            "s (std error)",
            "share",
            "cm",
            "whole",
            "",
            "control",
        });
        const repeats_gap: ?f32 = try self.repeatsGap(arena);
        const control_run: *const ReportRun = &self.runs[self.control];
        const control_judged: ?robot_track.Judgement = if (control_run.lastJudgedBatch()) |batch|
            try control_run.pooledAt(arena, batch)
        else
            null;
        // The servo, from the control's judgements: every run's first, on the same starts.
        if (try control_run.pooledAt(arena, 0)) |servo| {
            try writeJudgedLine(writer, "the servo", 0, servo, control_run.wholeReturnAt(0));
            try writer.writeAll("\n");
        }
        for (self.runs, 0..) |*run, index| {
            const batch: u64 = run.lastJudgedBatch() orelse {
                try writer.print("{s:<24} not judged\n", .{run.name});
                continue;
            };
            const judged: robot_track.Judgement = try run.pooledAt(arena, batch) orelse continue;
            try writeJudgedLine(writer, run.name, run.judgedMinutesAt(batch), judged, run.wholeReturnAt(batch));
            const control: robot_track.Judgement = control_judged orelse {
                try writer.writeAll("\n");
                continue;
            };
            if (index == self.control) {
                try writer.writeAll("  the control\n");
                continue;
            }
            const against: AgainstControl = .of(.of(judged), .of(control), repeats_gap);
            try writer.print("  {d:>7.2} ", .{against.difference_seconds});
            const gap_ratio: ?f32 = if (repeats_gap) |gap|
                if (gap > 0) against.difference_seconds / gap else null
            else
                null;
            const error_ratio: ?f32 = if (against.standard_error_seconds) |standard_error|
                if (standard_error > 0) against.difference_seconds / standard_error else null
            else
                null;
            try writeOptionalNumber(writer, gap_ratio, 7, 1);
            try writer.writeAll(" ");
            try writeOptionalNumber(writer, error_ratio, 7, 1);
            const verdict_text: []const u8 = if (self.is_repeat[index]) "a repeat" else switch (against.verdict()) {
                .longer => "longer",
                .shorter => "shorter",
                .within_noise => "noise",
            };
            try writer.print("  {s}\n", .{verdict_text});
        }
        try writer.writeAll("\n");
    }

    /// One line of the clips' table: `run`'s judgement of each of `clips` at `batch`, time to failure and standard
    /// error.
    fn writeClipLine(
        writer: *Io.Writer,
        run: *const ReportRun,
        name: []const u8,
        batch: u64,
        clips: []const []const u8,
    ) !void {
        try writer.print("{s:<24}", .{name});
        for (clips) |clip| {
            const line: JudgeLog.Line = run.judgementOf(batch, clip) orelse {
                try writer.print(" {s:>14}", .{"-"});
                continue;
            };
            const judgement: robot_track.Judgement = line.judgement;
            try writer.print(" {d:>6.2} ", .{judgement.meanTimeToFailure()});
            if (judgement.meanTimeToFailureError()) |standard_error| {
                try writer.print("({d:>5.2})", .{standard_error});
            } else {
                try writer.print("{s:>7}", .{"(-)"});
            }
        }
        try writer.writeAll("\n");
    }

    /// Each clip's judged time to failure, run by run, the servo's first: the clips of the control's last judgement.
    fn writeClips(self: *const RunsReport, arena: Allocator, writer: *Io.Writer) !void {
        const control_run: *const ReportRun = &self.runs[self.control];
        const control_batch: u64 = control_run.lastJudgedBatch() orelse return;
        const clips: []const []const u8 = try control_run.clipsAt(arena, control_batch);
        try writer.writeAll("CLIP BY CLIP - the judged time to failure, s, at each run's last judgement\n\n");
        try writer.print("{s:<24}", .{"run"});
        for (clips) |clip| {
            try writer.print(" {s:>14}", .{clip});
        }
        try writer.writeAll("\n");
        try writeClipLine(writer, control_run, "the servo", 0, clips);
        for (self.runs) |*run| {
            const batch: u64 = run.lastJudgedBatch() orelse continue;
            try writeClipLine(writer, run, run.name, batch, clips);
        }
        try writer.writeAll("\n");
    }

    /// One column of the runs' ends: its title, the log's column it shows, its decimals.
    const EndColumn = struct {
        title: []const u8,
        name: []const u8,
        decimals: u8,
    };

    /// Where each run's learning stood at its last round: its log's own numbers.
    fn writeEnds(self: *const RunsReport, writer: *Io.Writer) !void {
        try writer.writeAll("AT EACH RUN's END - its log's last round: the world model's loss in its own units " ++
            "(its window's mean step and its last step),\nthen in the clips' units, and its gate's readings (an " ++
            "answer to an action, the physics' against the model's, after the\nfirst step and the window's last), " ++
            "the policy's losses, the imagined root's drift\n\n");
        const columns = [_]EndColumn{
            .{ .title = "W step", .name = "world_loss", .decimals = 3 },
            .{ .title = "W last", .name = "world_loss_last_step", .decimals = 3 },
            .{ .title = "world", .name = "world_model_loss", .decimals = 3 },
            .{ .title = "cos 1st", .name = "gate_first_response_cosine", .decimals = 2 },
            .{ .title = "cos last", .name = "gate_last_response_cosine", .decimals = 2 },
            .{ .title = "len 1st", .name = "gate_first_response_ratio", .decimals = 2 },
            .{ .title = "len last", .name = "gate_last_response_ratio", .decimals = 2 },
            .{ .title = "tracking", .name = "policy_tracking_loss", .decimals = 3 },
            .{ .title = "labels", .name = "policy_label_loss", .decimals = 3 },
            .{ .title = "label sh", .name = "label_share", .decimals = 2 },
            .{ .title = "drift m", .name = "policy_root_drift", .decimals = 2 },
            .{ .title = "turn rad", .name = "policy_root_turn", .decimals = 2 },
            .{ .title = "critic", .name = "critic_value_error", .decimals = 2 },
            .{ .title = "planner", .name = "planner_gain", .decimals = 2 },
        };
        try writer.print("{s:<24}", .{"run"});
        for (columns) |column| {
            try writer.print(" {s:>8}", .{column.title});
        }
        try writer.writeAll("\n");
        for (self.runs) |*run| {
            try writer.print("{s:<24}", .{run.name});
            for (columns) |column| {
                try writer.writeAll(" ");
                const value: ?f32 = if (run.lastOf(column.name)) |number| @floatCast(number) else null;
                try writeOptionalNumber(writer, value, 8, column.decimals);
            }
            try writer.writeAll("\n");
        }
        try writer.writeAll("\n");
    }

    /// The kernels' times of every run that timed them, the longest few, as `kernel_times.csv` has them sorted.
    fn writeKernels(self: *const RunsReport, writer: *Io.Writer) !void {
        const kernels_shown: usize = 16;
        for (self.runs) |*run| {
            if (run.kernel_times.len == 0) {
                continue;
            }
            try writer.print("THE DEVICE's TIME BY KERNEL - {s}, the {d} longest (kernel_times.csv)\n\n", .{
                run.name,
                kernels_shown,
            });
            const title_format: []const u8 = "{s:<12} {s:<36} {s:>10} {s:>12} {s:>7}\n";
            try writer.print(title_format, .{ "pipe", "kernel", "dispatches", "ms", "share" });
            var lines: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, run.kernel_times, '\n');
            _ = lines.next();
            var shown: usize = 0;
            while (lines.next()) |line_text| {
                if (shown == kernels_shown) {
                    break;
                }
                var fields: std.mem.SplitIterator(u8, .scalar) = splitScalar(u8, line_text, ',');
                const pipe: []const u8 = fields.next() orelse continue;
                const kernel: []const u8 = fields.next() orelse continue;
                const dispatches: []const u8 = fields.next() orelse continue;
                const gpu_ms: []const u8 = fields.next() orelse continue;
                const share: []const u8 = fields.next() orelse continue;
                try writer.print(title_format, .{ pipe, kernel, dispatches, gpu_ms, share });
                shown += 1;
            }
            try writer.writeAll("\n");
        }
    }

    /// The whole report. Memory: its scratch in `arena`.
    pub fn write(self: *const RunsReport, arena: Allocator, writer: *Io.Writer) !void {
        try self.writeRuns(writer);
        try self.writeJudged(arena, writer);
        try self.writeClips(arena, writer);
        try self.writeEnds(writer);
        try self.writeKernels(writer);
    }
};

/// A judgement of 20 starts over 2,000 steps of 1/60 s, `failures` of them losing the reference - each failing start
/// after 2,000 / 20 steps, so that its standard error is a number.
fn reportTestJudgement(failures: usize) robot_track.Judgement {
    const starts: usize = 20;
    const watched_steps: usize = 2000;
    const start_steps: f64 = float64(watched_steps) / float64(starts);
    const judgement: robot_track.Judgement = .{
        .starts = starts,
        .failures = failures,
        .reached_end = starts - failures,
        .watched_steps = watched_steps,
        .reward_sum = 0,
        .frame_time = 1.0 / 60.0,
        .tracked_steps_squares = float64(starts) * start_steps * start_steps,
        .failed_starts_steps = float64(failures) * start_steps,
    };
    return judgement;
}

/// A run's files made for the report's test: its recipe - the control's, or another seed's, or another number of
/// critic heads' - and a log of `rounds` rounds over `minutes` minutes, its label share 1 until `phase_two_round`, then
/// 0.5; and judge.csv's lines for two clips, the servo's at batch 0 then the policy's, each clip's starts losing the
/// reference at `policy_failures` of 20 starts over 2,000 steps. Memory: every text in `arena`, zero-ended where its
/// parser asks.
fn reportTestTexts(
    arena: Allocator,
    name: []const u8,
    seed: u64,
    critic_hidden: u32,
    policy_failures: usize,
) !ReportTexts {
    const learner: SuperTrackLearner = .{ .seed = seed, .decide_every = 2, .critic = .{ .hidden = critic_hidden } };
    const run: GenoRun = .{ .learner = .{ .supertrack = learner } };
    var run_text: Io.Writer.Allocating = .init(arena);
    try run.write(&run_text.writer);
    const parameters: [:0]const u8 = try arena.dupeSentinel(u8, run_text.written(), 0);
    var log: ArrayList(u8) = .empty;
    try log.appendSlice(arena, SuperTrackLog.header);
    const rounds: u64 = 40;
    const phase_two_round: u64 = 10;
    for (1..rounds + 1) |round| {
        const is_phase_one: bool = round < phase_two_round;
        try SuperTrackLog.appendLine(arena, &log, .{
            .round = round,
            .training_minutes = float(round) * 0.25,
            .steps_watched = 300,
            .failures = if (round <= rounds / 2) 10 else 5,
            .world_updates = 16,
            .policy_updates = 16,
            .label_share = if (is_phase_one) 1 else 0.5,
        });
    }
    var judgements: ArrayList(u8) = .empty;
    try judgements.appendSlice(arena, JudgeLog.header);
    const clips = [_][]const u8{ "dance", "walk" };
    const servo_failures: usize = 20;
    for (clips) |clip| {
        const servo: robot_track.Judgement = reportTestJudgement(servo_failures);
        try JudgeLog.appendLine(arena, &judgements, 0, 0, clip, servo);
    }
    for (clips) |clip| {
        const judged: robot_track.Judgement = reportTestJudgement(policy_failures);
        try JudgeLog.appendLine(arena, &judgements, rounds, 10, clip, judged);
    }
    const texts: ReportTexts = .{
        .name = name,
        .parameters = parameters,
        .log = log.items,
        .judgements = judgements.items,
    };
    return texts;
}

test "RunsReport: the control's repeat sets the noise, an ablation beyond it is longer, the quarters show learning" {
    // Three runs: the control (seed 1), its repeat at seed 2, and an ablation (another critic width). Each judged on
    // two clips of 20 starts over 2,000 steps (33.3 s) each: the control losing the reference at 18 starts of each - a
    // pooled time to failure of 66.7 s / 36 = 1.85 s - its repeat at 17 (1.96 s), the ablation at 9 (3.70 s). The
    // repeat's gap, 0.11 s, is the noise; the ablation's 1.85 s, beyond it and beyond twice the standard errors (1.33
    // s together), is longer. The repeat is found by its recipe, not its name. Each log fails 10 times a round in its
    // first half and 5 in its second: its quarters' times to failure double; phase 2 begins at round 10, 2.5 minutes.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const all_texts = [_]ReportTexts{
        try reportTestTexts(arena, "01_control", 1, 170, 18),
        try reportTestTexts(arena, "02_ablation", 1, 64, 9),
        try reportTestTexts(arena, "03_again", 2, 170, 17),
    };
    var runs: [all_texts.len]ReportRun = undefined;
    for (&runs, all_texts) |*run, texts| {
        run.* = try .read(testing_allocator, arena, texts);
    }
    const runs_report: RunsReport = try .init(testing_allocator, arena, &runs, "01_control", 60);
    try expectEqual(@as(usize, 0), runs_report.control);
    try expectEqualSlices(bool, &.{ false, false, true }, runs_report.is_repeat);
    // The log: phase 2 at 2.5 minutes; the quarters, at 30 decisions a second (decide_every 2), 300 / 10 / 30 = 1 s
    // in the first half and 2 s in the second.
    const control: *const ReportRun = &runs[0];
    try expectEqual(PhaseTwo{ .began_at_minutes = 2.5 }, control.phaseTwo());
    const quarters: [4]?f32 = control.quarterSecondsToFailure(control.run.?.logStepsPerSecond(60));
    try expectApproxEqAbs(@as(f32, 1), quarters[0].?, 1e-5);
    try expectApproxEqAbs(@as(f32, 2), quarters[3].?, 1e-5);
    // The judge: the pooled times, the repeat's gap, the ablation's verdict.
    const control_judged: robot_track.Judgement = (try control.pooledAt(arena, control.lastJudgedBatch().?)).?;
    try expectApproxEqAbs(@as(f32, 66.6667 / 36.0), control_judged.meanTimeToFailure(), 1e-3);
    const gap: f32 = (try runs_report.repeatsGap(arena)).?;
    try expectApproxEqAbs(@as(f32, 66.6667 / 34.0 - 66.6667 / 36.0), gap, 1e-3);
    const ablation_judged: robot_track.Judgement = (try runs[1].pooledAt(arena, 40)).?;
    const against: AgainstControl = .of(.of(ablation_judged), .of(control_judged), gap);
    try expectEqual(AgainstControl.Verdict.longer, against.verdict());
    const repeat_judged: robot_track.Judgement = (try runs[2].pooledAt(arena, 40)).?;
    const repeat_against: AgainstControl = .of(.of(repeat_judged), .of(control_judged), gap);
    try expectEqual(AgainstControl.Verdict.within_noise, repeat_against.verdict());
    // And the whole report writes, naming the repeat and the verdict.
    var text: Io.Writer.Allocating = .init(testing_allocator);
    defer text.deinit();
    try runs_report.write(arena, &text.writer);
    const written: []const u8 = text.written();
    try expect(indexOf(u8, written, "its repeats at other seeds 03_again") != null);
    try expect(indexOf(u8, written, "longer") != null);
    try expect(indexOf(u8, written, "a repeat") != null);
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
    /// A flow's hidden layers (`kit_mlp.KitLayerKind.normed_silu`): the norm, then SiLU (`zimrmath.silu`).
    layer_norm_silu = 4,

    /// Whether a layer of this activation is NORMED: its pre-activations layer-normalised, with a gain and a bias per
    /// output, before the activation.
    pub fn isNormed(activation: PolicyActivation) bool {
        return switch (activation) {
            .none, .tanh => false,
            .layer_norm_mish, .layer_norm_simnorm, .layer_norm_silu => true,
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
    /// SuperTrack's features (`robot_track.local`): the goal - the reference one frame ahead, then the root target's
    /// slots - then the character's own state, the features each in their root's frame and normalised by the clip's
    /// frozen statistics. What SuperTrack's policy reads (`resident.supertrackFeaturesInto`).
    supertrack_features = 1,
};

/// SUPERTRACK's OBSERVATION as a policy file keeps it (`resident.supertrackFeaturesInto`):
///
///     [ goal's features | root target's slots | state's features ]      2 x features + `rbt.root_target_size`
///
/// the clip's per-feature means and spreads, frozen when the policy was written (`robot_latent.Normalizer`: each
/// feature `(x - mean) / spread`, no clamp) - the goal's features and the state's normalised by the same statistics -
/// and whether the slots hold the root target (`rbt.root_target_size`) or zeros, as the policy was trained.
pub const SuperTrackObservation = struct {
    normalizer: latent.Normalizer,
    root_target: bool,

    /// The observation's width: the goal - the features and the root target's slots - then the state's features.
    pub fn size(observation: SuperTrackObservation) usize {
        const feature_count: usize = observation.normalizer.mean.len;
        return resident.supertrackGoalWidth(feature_count) + feature_count;
    }
};

/// What a policy reads, with what it needs to build it: nothing more for DReCon's observation (its own normaliser,
/// when it has one, is the policy's `normalization`), and for SuperTrack's features its statistics and its root
/// target's switch (`SuperTrackObservation`).
pub const PolicyObservation = union(ObservationKind) {
    drecon,
    supertrack_features: SuperTrackObservation,
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

/// The action applied before a decision, and the block that reads it (`GenoPolicy.applied_block`).
const AppliedReading = struct {
    action: []const f32,
    block: []const f32,
};

/// THE FLOW's CORRECTION a SuperTrack policy may carry (`GenoPolicy.flow`; robot_latent_kit's `FlowActor`): a velocity
/// network over [observation | point | time features] - its layers as a policy's, the observation SuperTrack's
/// [goal | state] - integrated from zero noise over K Euler steps to the coefficients c, decoded through the synergies
/// B (a row of the action's width per coefficient) and added to the policy's raw action before it is held to the
/// controller's range:
///
///     x_0 = 0
///     x_{s+1} = x_s + v([observation | x_s | sin, cos of pi 2^p t_s]) / K        t_s = s / K, p = 0 .. frequencies - 1
///     raw += B^T x_K
///
/// The flow's MODE, its answer at zero noise: what the judge plays for a flow run, in the host sampler's arithmetic
/// (`kit_mlp.KitFlow.sampleHost`), step for step.
pub const PolicyFlow = struct {
    /// The velocity network's widths, from its input - the observation, the point, the time features - to the
    /// coefficients; a layer between each two, as a policy's (`GenoPolicy.widths`).
    widths: []u32,
    layers: []PolicyLayer,
    euler_steps: u32,
    time_frequencies: u32,
    /// [coefficient][action]: each coefficient's direction in the action.
    synergies: []f32,

    /// How many coefficients the flow gives: its last width.
    pub fn coefficientCount(flow: *const PolicyFlow) usize {
        return flow.widths[flow.widths.len - 1];
    }

    /// Its input's width: the observation, the point - as many numbers as coefficients - and two time features per
    /// frequency.
    pub fn inputWidth(flow: *const PolicyFlow) usize {
        return flow.widths[0];
    }

    /// The widest of its layers' outputs: how wide each of its forward pass's two buffers must be.
    pub fn widestLayer(flow: *const PolicyFlow) usize {
        var widest_layer: usize = 0;
        for (flow.widths[1..]) |width| {
            widest_layer = @max(widest_layer, width);
        }
        return widest_layer;
    }

    /// Frees the flow's arrays, allocated with `gpa`.
    pub fn deinit(flow: *PolicyFlow, gpa: Allocator) void {
        for (flow.layers) |layer| {
            gpa.free(layer.weights_and_biases);
        }
        gpa.free(flow.layers);
        gpa.free(flow.widths);
        gpa.free(flow.synergies);
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
    /// THE BLOCK READING THE ACTION APPLIED BEFORE EACH DECISION, a row per action number, a column per first-layer
    /// unit (a SuperTrack policy trained with `sees_applied`): its terms join the first layer's sum after the
    /// observation's, before the activation - the kit's order. Null: the policy reads no applied action.
    applied_block: ?[]f32 = null,
    /// THE LIMBS' STIFFNESSES at the action's end, after the joints' numbers (a SuperTrack policy trained with a
    /// stiffness per limb, `robot_track.Fleet.Options.limb_stiffness`): how many - the model's limbs, or 0 for a
    /// policy whose action is the joints' alone - and the filter's share for them at each decision, as `filter_beta`
    /// is the joints'. A policy with them is played on a fleet whose limbs take the stiffness it gives.
    stiffness_count: u32 = 0,
    stiffness_filter_beta: f32 = 1.0,
    /// THE FLOW CORRECTING THE POLICY's ACTION (a SuperTrack run with a flow actor, `PolicyFlow`), or null: the
    /// policy's action alone.
    flow: ?PolicyFlow = null,

    /// The observation's size: the first width.
    pub fn observationSize(policy: *const GenoPolicy) usize {
        return policy.widths[0];
    }

    /// The action's size - one component per actuated degree of freedom, then one per limb for a policy that gives
    /// the limbs' stiffnesses: the last width.
    pub fn actionSize(policy: *const GenoPolicy) usize {
        return policy.widths[policy.widths.len - 1];
    }

    /// Whether the action carries a stiffness per limb after the joints' numbers.
    pub fn givesLimbStiffness(policy: *const GenoPolicy) bool {
        return policy.stiffness_count > 0;
    }

    /// THE CONTROLLER A POLICY ACTS THROUGH (`robot_policy.Controller`), as the show, the judge and the trainer's play
    /// check make it: the policy's own filter and decision interval, and its limbs' stiffnesses with their share.
    pub fn controllerOptions(policy: *const GenoPolicy) robot_policy.Controller.Options {
        return .{
            .beta = policy.filter_beta,
            .decimation = policy.decimation,
            .stiffness_count = policy.stiffness_count,
            .stiffness_beta = policy.stiffness_filter_beta,
        };
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
        if (policy.flow) |*flow| {
            flow.deinit(gpa);
        }
        if (policy.applied_block) |block| {
            gpa.free(block);
        }
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
            .supertrack_features => |observation| {
                gpa.free(observation.normalizer.mean);
                gpa.free(observation.normalizer.spread);
            },
        }
    }

    /// The first layer's reading of `applied`, the action applied before this decision - none for a policy without
    /// the block. A policy with one is given the whole action.
    pub fn appliedReading(policy: *const GenoPolicy, applied: []const f32) ?AppliedReading {
        const block: []const f32 = policy.applied_block orelse return null;
        const whole_action: bool = applied.len == policy.actionSize();
        assertf(whole_action, @src(), "a policy reading its applied action given {d} numbers, wants {d}", .{
            applied.len,
            policy.actionSize(),
        });
        return .{ .action = applied, .block = block };
    }
};

/// The forward pass's two buffers, used PING-PONG: each layer reads its input from one and writes its output into
/// the other, and the next layer the other way round - so a network of any depth runs in two buffers, each as wide as
/// its widest layer (`GenoPolicy.widestLayer`).
pub const PolicyScratch = struct {
    ping: []f32,
    pong: []f32,
    /// A flow's (`GenoPolicy.flow`): its input row, its two layer buffers and its velocity - empty for a policy
    /// without one.
    flow_row: []f32 = &.{},
    flow_ping: []f32 = &.{},
    flow_pong: []f32 = &.{},
    flow_velocity: []f32 = &.{},

    /// The buffers sized for `policy` (`GenoPolicy.widestLayer`, `PolicyFlow`): the scratch's one constructor, so that
    /// no scratch is ever too narrow for its policy. Memory: all in `arena`, the caller's.
    pub fn init(arena: Allocator, policy: *const GenoPolicy) !PolicyScratch {
        const widest_layer: usize = policy.widestLayer();
        const ping: []f32 = try arena.alloc(f32, widest_layer);
        const pong: []f32 = try arena.alloc(f32, widest_layer);
        const flow: *const PolicyFlow = if (policy.flow) |*corrects| corrects else {
            return .{ .ping = ping, .pong = pong };
        };
        const flow_widest: usize = flow.widestLayer();
        const scratch: PolicyScratch = .{
            .ping = ping,
            .pong = pong,
            .flow_row = try arena.alloc(f32, flow.inputWidth()),
            .flow_ping = try arena.alloc(f32, flow_widest),
            .flow_pong = try arena.alloc(f32, flow_widest),
            .flow_velocity = try arena.alloc(f32, flow.coefficientCount()),
        };
        return scratch;
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
        .layer_norm_silu => for (values) |*value| {
            value.* = silu(value.*);
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
    applied: ?AppliedReading,
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
        // The applied action's terms, after the inputs' and before the activation, in the kit's order.
        if (applied) |reading| {
            for (reading.action, 0..) |applied_value, applied_index| {
                const weight: f32 = reading.block[applied_index * output_count + output_index];
                pre_activation += applied_value * weight;
            }
        }
        layer_output[output_index] = switch (layer.activation) {
            .none => pre_activation,
            .tanh => tanh(pre_activation),
            // A normed layer's activation comes after its norm, which needs every pre-activation first.
            .layer_norm_mish, .layer_norm_simnorm, .layer_norm_silu => pre_activation,
        };
    }
    if (layer.activation.isNormed()) {
        applyNorm(layer, input_count, layer_output);
    }
}

/// THE FLOW's CORRECTION added to `action`, the policy's raw action (`PolicyFlow`): its K Euler steps from zero noise
/// with `observation` as their condition - the time features as `kit_mlp.KitFlow.sampleHost` writes them, the layers
/// as a policy's (`applyPolicyLayer`) - then the coefficients decoded through the synergies, coefficient after
/// coefficient, as the learner adds them (`HostPolicy.addCorrection`).
fn addFlowCorrection(
    flow: *const PolicyFlow,
    observation: []const f32,
    scratch: PolicyScratch,
    action: []f32,
) void {
    const condition_width: usize = observation.len;
    const coefficient_count: usize = flow.coefficientCount();
    const time_feature_count: usize = 2 * @as(usize, flow.time_frequencies);
    const row: []f32 = scratch.flow_row[0..flow.inputWidth()];
    @memcpy(row[0..condition_width], observation);
    const point: []f32 = row[condition_width..][0..coefficient_count];
    @memset(point, 0);
    const time_features: []f32 = row[condition_width + coefficient_count ..][0..time_feature_count];
    const step_size: f32 = 1.0 / float(flow.euler_steps);
    const velocity: []f32 = scratch.flow_velocity[0..coefficient_count];
    for (0..flow.euler_steps) |step_index| {
        const step_time: f32 = float(step_index) * step_size;
        for (0..flow.time_frequencies) |pair| {
            const frequency: f32 = @floatFromInt(@as(u32, 1) << @intCast(pair));
            const angle_rad: f32 = pi * frequency * step_time;
            time_features[2 * pair] = sinRad(angle_rad);
            time_features[2 * pair + 1] = cosRad(angle_rad);
        }
        // The velocity network, ping-pong as the policy's layers, its last layer into the velocity.
        var layer_input: []const f32 = row;
        var input_is_in_ping: bool = false;
        for (flow.layers, 0..) |layer, layer_index| {
            const is_last_layer: bool = layer_index + 1 == flow.layers.len;
            const output_count: usize = flow.widths[layer_index + 1];
            const other_buffer: []f32 = if (input_is_in_ping) scratch.flow_pong else scratch.flow_ping;
            const layer_output: []f32 = if (is_last_layer) velocity else other_buffer[0..output_count];
            applyPolicyLayer(layer, layer_input, null, layer_output);
            layer_input = layer_output;
            input_is_in_ping = !input_is_in_ping;
        }
        for (point, velocity) |*point_value, velocity_value| {
            point_value.* += step_size * velocity_value;
        }
    }
    const action_width: usize = action.len;
    for (point, 0..) |coefficient, synergy| {
        const direction: []const f32 = flow.synergies[synergy * action_width ..][0..action_width];
        for (action, direction) |*component, direction_value| {
            component.* += coefficient * direction_value;
        }
    }
}

/// The action `policy` takes for `observation`, written into `action` (`GenoPolicy`): the observation normalised by
/// the frozen normaliser, passed through the layers - `scratch` holding each layer's input and output - and the last
/// layer's outputs clamped to the controller's range. No randomness: the policy's mean action, as the show and the
/// judge act.
pub fn policyMeanAction(
    policy: *const GenoPolicy,
    observation: []const f32,
    applied: []const f32,
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
        const is_first_layer: bool = layer_index == 0;
        const reading: ?AppliedReading = if (is_first_layer) policy.appliedReading(applied) else null;
        applyPolicyLayer(layer, layer_input, reading, layer_output);
        layer_input = layer_output;
        input_is_in_ping = !input_is_in_ping;
    }
    // A flow's correction, before the range: added to the raw action as the learner adds it.
    if (policy.flow) |*flow| {
        addFlowCorrection(flow, observation, scratch, action);
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

/// The policy file's activation for a kit layer's kind (`PolicyActivation`): the layer computed the same way. A dense
/// ReLU layer has none - no network a policy file carries uses one.
fn policyActivationOf(kind: kit_mlp.KitLayerKind) PolicyActivation {
    return switch (kind) {
        .dense_tanh => .tanh,
        .normed_mish => .layer_norm_mish,
        .normed_silu => .layer_norm_silu,
        .normed_simnorm => .layer_norm_simnorm,
        .plain => .none,
        .dense_relu => {
            assertUnreachable(@src(), "a policy file carries no ReLU layer", .{});
            return .none;
        },
    };
}

/// A learner's flow as the policy file keeps it (`resident.FlowPolicyParts`, `PolicyFlow`): each layer's parameters
/// copied out of the CPU's copy of the weights - W, b, then a normed layer's gains and norm biases, as the kit lays
/// them - its widths from the layers' own, its sampler's settings and its synergies, for an action of `action_count`.
/// Memory: the flow's arrays allocated with `gpa`, the caller's (`PolicyFlow.deinit`).
fn policyFlowOf(
    gpa: Allocator,
    parts: resident.FlowPolicyParts,
    action_count: usize,
) !PolicyFlow {
    const layer_count: usize = parts.layers.len;
    const widths: []u32 = try gpa.alloc(u32, layer_count + 1);
    errdefer gpa.free(widths);
    widths[0] = parts.layers[0].input_width;
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, layer_count);
    var layers_made: usize = 0;
    errdefer {
        for (layers[0..layers_made]) |layer| {
            gpa.free(layer.weights_and_biases);
        }
        gpa.free(layers);
    }
    for (parts.layers, layers, 0..) |kit_layer, *layer, layer_index| {
        const chained: bool = kit_layer.input_width == widths[layer_index];
        assertf(chained, @src(), "policyFlowOf: layer {d} reads {d}, the layer before gives {d}", .{
            layer_index,
            kit_layer.input_width,
            widths[layer_index],
        });
        widths[layer_index + 1] = kit_layer.output_width;
        const kit_parameters: []const f32 =
            parts.parameters[kit_layer.weights_offset..][0..kit_layer.parameterFloats()];
        layer.* = .{
            .activation = policyActivationOf(kit_layer.kind),
            .weights_and_biases = try gpa.dupe(f32, kit_parameters),
            .norm_epsilon = if (kit_layer.kind.isNormed()) kit_layer.norm_epsilon else 0,
            .simnorm_group = if (kit_layer.kind == .normed_simnorm) kit_layer.simnorm_group else 0,
        };
        layers_made += 1;
    }
    const coefficient_count: usize = widths[layer_count];
    const synergy_count: usize = coefficient_count * action_count;
    assertf(parts.synergies.len == synergy_count, @src(), "policyFlowOf: {d} synergy numbers, want {d}", .{
        parts.synergies.len,
        synergy_count,
    });
    const flow: PolicyFlow = .{
        .widths = widths,
        .layers = layers,
        .euler_steps = parts.euler_steps,
        .time_frequencies = parts.time_frequencies,
        .synergies = try gpa.dupe(f32, parts.synergies),
    };
    return flow;
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
/// a frozen copy of the learner's feature statistics), deciding with no limit and through the learner's action filter
/// (`PolicyParts.filter`; the limbs' stiffnesses, where the action carries them, through `stiffness_filter`) -
/// exactly as the learner acts on the fleet, whose action scale is `action_scale`.
///
/// The packed first layer is already a dense layer over `[goal | state]` in `PolicyLayer`'s layout: a row of weights
/// per input, the goal's inputs first, then its biases. So each layer is one slice of the packed weights, in order.
/// Memory: the policy's arrays are allocated with `gpa` and are the caller's - `deinit(gpa)` frees them, or, when
/// `gpa` is an arena, the arena does.
/// `decimation` is the learner's clock (`robot_track.Fleet.Options.decide_every`): the player decides as often as the
/// policy was trained to.
pub fn policyOfSuperTrack(
    gpa: Allocator,
    parts: resident.PolicyParts,
    action_scale: f32,
    decimation: u32,
) !GenoPolicy {
    // The goal - the features and the root target's slots - then the state.
    const observation_size: usize = resident.supertrackGoalWidth(parts.feature_count) + parts.feature_count;
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
    // The block through which a policy reads the action applied before its decision, after the layers: kept when any
    // weight in it is not zero (a policy trained with `sees_applied`); an all-zero block adds exactly nothing, so it is
    // left out and the policy plays as one that reads no applied action.
    const applied_block_size: usize = parts.action_count * parts.hidden_width;
    const packed_block: []const f32 = parts.packed_weights[layer_start..][0..applied_block_size];
    const reads_applied_action: bool = for (packed_block) |weight| {
        if (weight != 0) {
            break true;
        }
    } else false;
    const applied_block: ?[]f32 = if (reads_applied_action) try gpa.dupe(f32, packed_block) else null;
    errdefer if (applied_block) |block| gpa.free(block);
    layer_start += applied_block_size;
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
    errdefer gpa.free(frozen_spreads);
    // The flow correcting the policy, when the learner has one: copied out of the CPU's copy of its weights.
    const flow: ?PolicyFlow = if (parts.flow) |flow_parts|
        try policyFlowOf(gpa, flow_parts, parts.action_count)
    else
        null;
    const no_limit: f32 = inf(f32);
    const policy: GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = null,
        .action_limit = no_limit,
        .action_scale = action_scale,
        .filter_beta = parts.filter,
        .observation = .{ .supertrack_features = .{
            .normalizer = .{ .mean = frozen_means, .spread = frozen_spreads },
            .root_target = parts.root_target,
        } },
        .decimation = decimation,
        .applied_block = applied_block,
        .stiffness_count = @intCast(parts.stiffness_count),
        .stiffness_filter_beta = parts.stiffness_filter,
        .flow = flow,
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
    pub const version: u32 = 5;

    /// A file's flags (`Header.flags`), as a packed struct: a bit this reader does not know is one field to check.
    pub const Flags = packed struct(u32) {
        normalizes_observations: bool,
        /// The file ends with a flow correcting the policy (`FlowHeader`, `GenoPolicy.flow`).
        holds_flow: bool = false,
        unknown: u30 = 0,
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
        /// The limbs' stiffnesses at the action's end (`GenoPolicy.stiffness_count`) and their filter's share: 0 and
        /// 1 for a policy whose action is the joints' alone.
        stiffness_filter_beta: f32,
        stiffness_count: u32,
        observations_counted: f64,
        observation_clip: f64,
        observation_epsilon: f64,
    };

    /// What a policy reads and how often it decides, after the `Header`. `feature_count` is the
    /// width of SuperTrack's feature normaliser - the observation is the goal's features and the root target's slots,
    /// then the state's features (`SuperTrackObservation`) - and zero for DReCon's observation.
    pub const ObservationHeader = extern struct {
        /// `ObservationKind`, as its backing integer.
        kind: u32,
        decimation: u32,
        feature_count: u32,
        /// The numbers of the block reading the applied action (`GenoPolicy.applied_block`), written last: 0 for none.
        applied_block_count: u32 = 0,
        /// Whether SuperTrack's goal holds the root target in its slots (1) or zeros (0): 0 for DReCon's observation.
        root_target: u32 = 0,
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

    /// THE FLOW's SECTION, last in a file that holds one (`Flags.holds_flow`, `PolicyFlow`): this header, then its
    /// layers as the policy's are written - a `LayerHeader` and the parameters each, the first reading the observation,
    /// the point and the time features - then the synergies, [coefficient][action]. Only with SuperTrack's observation,
    /// not normalised by a policy normaliser: the flow's condition is the observation as the layers read it.
    pub const FlowHeader = extern struct {
        layer_count: u32,
        euler_steps: u32,
        time_frequencies: u32,
        coefficient_count: u32,
    };

    /// The most time frequencies a flow's file may say (`FlowHeader.time_frequencies`): 2^p must fit a 32-bit integer.
    const most_time_frequencies: u32 = 24;

    comptime {
        if (builtin.cpu.arch.endian() != .little) {
            @compileError("PolicyFile writes its headers as they lie in memory, which assumes a little-endian target");
        }
        // And as they lie in memory they have no padding: a padding byte would be written as whatever the stack
        // held, and one policy written twice would make two different files.
        const headers = [_]type{ Header, ObservationHeader, LayerHeader, FlowHeader };
        for (headers) |HeaderType| {
            if (!resident.hasNoPadding(HeaderType)) {
                @compileError("PolicyFile's " ++ @typeName(HeaderType) ++ " has padding: its fields do not fill it");
            }
        }
    }

    /// Why a file is no policy: the wrong first bytes, a version this reader does not know, flags it does not know, too
    /// few bytes for what the file says it holds, too many - bytes after its end - no layer, an activation it does not
    /// know, a normed layer's settings that cannot be (an epsilon not positive and finite, a SimNorm group of zero or
    /// one that does not divide the layer's outputs, or settings on a layer that is not normed), or a normaliser that
    /// cannot be (a clip or an epsilon not positive, a statistic not finite, a sum of
    /// squared deviations below zero), an observation it does not know, a decision interval of zero, SuperTrack's
    /// feature statistics that cannot be (not half the observation past the root target's slots, a spread not
    /// positive and finite, a mean not finite), a root target's switch that is neither 0 nor 1 (or not 0 for an
    /// observation without the slots), or a block reading the applied action of a size the first layer cannot read.
    pub const ReadError = error{
        NotAPolicyFile,
        PolicyVersionUnknown,
        PolicyObservationUnknown,
        PolicyDecimationInvalid,
        PolicyStiffnessInvalid,
        PolicyFeaturesInvalid,
        PolicyRootTargetInvalid,
        PolicyFlagsUnknown,
        PolicyTruncated,
        PolicyHasTrailingBytes,
        PolicyHasNoLayers,
        PolicyActivationUnknown,
        PolicyNormInvalid,
        PolicyNormalizationInvalid,
        PolicyFlowInvalid,
        PolicyAppliedBlockInvalid,
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
        const stiffness_readable: bool =
            stiffnessProblem(policy.stiffness_count, policy.stiffness_filter_beta, policy.actionSize()) == null;
        assertf(stiffness_readable, @src(), "PolicyFile.encode: {d} stiffnesses at a share of {d} in {d} actions", .{
            policy.stiffness_count,
            policy.stiffness_filter_beta,
            policy.actionSize(),
        });
        const feature_count: usize = switch (policy.observation) {
            .drecon => 0,
            .supertrack_features => |observation| observation.normalizer.mean.len,
        };
        const root_target: bool = switch (policy.observation) {
            .drecon => false,
            .supertrack_features => |observation| observation.root_target,
        };
        if (policy.observation == .supertrack_features) {
            const observation: SuperTrackObservation = policy.observation.supertrack_features;
            const features_fit: bool = observation.size() == policy.observationSize() and
                observation.normalizer.spread.len == feature_count;
            assertf(features_fit, @src(), "PolicyFile.encode: {d} features for an observation of {d}", .{
                feature_count,
                policy.observationSize(),
            });
        }
        if (policy.flow) |*flow| {
            assertFlowWritable(policy, flow);
        }
        const flags: Flags = .{
            .normalizes_observations = normalization != null,
            .holds_flow = policy.flow != null,
        };
        const header: Header = .{
            .magic = magic,
            .version = version,
            .layer_count = @intCast(layer_count),
            .flags = @bitCast(flags),
            .observation_size = policy.widths[0],
            .action_limit = policy.action_limit,
            .action_scale = policy.action_scale,
            .filter_beta = policy.filter_beta,
            .stiffness_filter_beta = policy.stiffness_filter_beta,
            .stiffness_count = policy.stiffness_count,
            .observations_counted = if (normalization) |normalizer| normalizer.count else 0,
            .observation_clip = if (normalization) |normalizer| normalizer.clip else 0,
            .observation_epsilon = if (normalization) |normalizer| normalizer.epsilon else 0,
        };
        const observation_kind: ObservationKind = policy.observation;
        const observation_header: ObservationHeader = .{
            .kind = @backingInt(observation_kind),
            .decimation = policy.decimation,
            .feature_count = @intCast(feature_count),
            .applied_block_count = if (policy.applied_block) |block| @intCast(block.len) else 0,
            .root_target = @intFromBool(root_target),
        };
        var bytes: ArrayList(u8) = .empty;
        errdefer bytes.deinit(gpa);
        try bytes.appendSlice(gpa, asBytes(&header));
        try bytes.appendSlice(gpa, asBytes(&observation_header));
        for (policy.layers, 0..) |layer, layer_index| {
            try appendLayer(gpa, &bytes, layer, policy.widths[layer_index + 1]);
        }
        if (normalization) |normalizer| {
            try bytes.appendSlice(gpa, sliceAsBytes(normalizer.mean));
            try bytes.appendSlice(gpa, sliceAsBytes(normalizer.m2));
        }
        switch (policy.observation) {
            .drecon => {},
            .supertrack_features => |observation| {
                try bytes.appendSlice(gpa, sliceAsBytes(observation.normalizer.mean));
                try bytes.appendSlice(gpa, sliceAsBytes(observation.normalizer.spread));
            },
        }
        if (policy.applied_block) |block| {
            try bytes.appendSlice(gpa, sliceAsBytes(block));
        }
        if (policy.flow) |*flow| {
            const flow_header: FlowHeader = .{
                .layer_count = @intCast(flow.layers.len),
                .euler_steps = flow.euler_steps,
                .time_frequencies = flow.time_frequencies,
                .coefficient_count = @intCast(flow.coefficientCount()),
            };
            try bytes.appendSlice(gpa, asBytes(&flow_header));
            for (flow.layers, 0..) |layer, layer_index| {
                try appendLayer(gpa, &bytes, layer, flow.widths[layer_index + 1]);
            }
            try bytes.appendSlice(gpa, sliceAsBytes(flow.synergies));
        }
        return bytes.toOwnedSlice(gpa);
    }

    /// A layer as a file holds it: its `LayerHeader`, then its parameters.
    fn appendLayer(
        gpa: Allocator,
        bytes: *ArrayList(u8),
        layer: PolicyLayer,
        output_count: u32,
    ) !void {
        const layer_header: LayerHeader = .{
            .output_count = output_count,
            .activation = @backingInt(layer.activation),
            .simnorm_group = layer.simnorm_group,
            .norm_epsilon = layer.norm_epsilon,
        };
        try bytes.appendSlice(gpa, asBytes(&layer_header));
        try bytes.appendSlice(gpa, sliceAsBytes(layer.weights_and_biases));
    }

    /// That a policy's flow is one `decode` reads back: SuperTrack's observation, not normalised by a policy
    /// normaliser; an input of the observation, the point and the time features; each layer holding its shape's
    /// parameters and norm settings it can be read with; synergies for every coefficient and action number.
    fn assertFlowWritable(policy: *const GenoPolicy, flow: *const PolicyFlow) void {
        const condition_fits: bool = policy.observation == .supertrack_features and policy.normalization == null;
        assertf(condition_fits, @src(), "PolicyFile.encode: a flow reads SuperTrack's observation as it is", .{});
        const time_feature_count: usize = 2 * @as(usize, flow.time_frequencies);
        const input_width: usize = policy.observationSize() + flow.coefficientCount() + time_feature_count;
        const settings_fit: bool = flow.layers.len > 0 and flow.widths.len == flow.layers.len + 1 and
            flow.euler_steps > 0 and flow.time_frequencies <= most_time_frequencies and
            flow.inputWidth() == input_width;
        assertf(settings_fit, @src(), "PolicyFile.encode: a flow's settings that cannot be read back", .{});
        for (flow.layers, 0..) |layer, layer_index| {
            const input_count: u32 = flow.widths[layer_index];
            const output_count: u32 = flow.widths[layer_index + 1];
            const parameter_count: usize = PolicyLayer.parameterCount(layer.activation, input_count, output_count);
            const norm_problem: ?ReadError =
                normProblem(layer.activation, output_count, layer.simnorm_group, layer.norm_epsilon);
            const layer_fits: bool = layer.weights_and_biases.len == parameter_count and norm_problem == null;
            assertf(layer_fits, @src(), "PolicyFile.encode: the flow's layer {d} cannot be read back", .{layer_index});
        }
        const synergy_count: usize = flow.coefficientCount() * policy.actionSize();
        assertf(flow.synergies.len == synergy_count, @src(), "PolicyFile.encode: {d} synergy numbers, want {d}", .{
            flow.synergies.len,
            synergy_count,
        });
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
        // SuperTrack's observation is the goal's features and the root target's slots, then the state's features:
        // past the slots, two halves. Halving what is left rather than doubling the count: a damaged count of four
        // billion doubled would overflow a 32-bit `usize`, the web's.
        const feature_count: usize = observation_header.feature_count;
        const root_target_size: usize = rbt.root_target_size;
        const holds_root_slots: bool = header.observation_size >= root_target_size;
        const observation_features: usize = header.observation_size -| root_target_size;
        const features_are_two_halves: bool = holds_root_slots and observation_features % 2 == 0;
        const features_are_half: bool = features_are_two_halves and feature_count == observation_features / 2;
        const features_match_observation: bool = switch (observation_kind) {
            .drecon => feature_count == 0,
            .supertrack_features => feature_count > 0 and features_are_half,
        };
        if (!features_match_observation) {
            return error.PolicyFeaturesInvalid;
        }
        // The root target's switch: 0 or 1, and 0 for an observation without the slots.
        const root_target_valid: bool = switch (observation_kind) {
            .drecon => observation_header.root_target == 0,
            .supertrack_features => observation_header.root_target <= 1,
        };
        if (!root_target_valid) {
            return error.PolicyRootTargetInvalid;
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
            const read: LayerRead = try readLayer(gpa, &reader, widths[layer_index]);
            layer.* = read.layer;
            widths[layer_index + 1] = read.output_count;
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
            .supertrack_features => .{ .supertrack_features = .{
                .normalizer = try readFeatureNormalizer(gpa, &reader, feature_count),
                .root_target = observation_header.root_target == 1,
            } },
        };
        errdefer {
            switch (observation) {
                .drecon => {},
                .supertrack_features => |supertrack_observation| {
                    gpa.free(supertrack_observation.normalizer.mean);
                    gpa.free(supertrack_observation.normalizer.spread);
                },
            }
        }
        // The block reading the applied action, last, when the policy has one: a weight for each of the first
        // layer's outputs and each number of the action (`applyPolicyLayer` reads it so) - its count checked, and its
        // bytes against what is left, before it is allocated.
        const action_size: usize = widths[layer_count];
        const block_count: usize = observation_header.applied_block_count;
        if (block_count != 0) {
            const readable_count: usize = mulChecked(usize, widths[1], action_size) catch {
                return error.PolicyAppliedBlockInvalid;
            };
            if (block_count != readable_count) {
                return error.PolicyAppliedBlockInvalid;
            }
            const block_bytes: usize = mulChecked(usize, block_count, @sizeOf(f32)) catch {
                return error.PolicyTruncated;
            };
            if (block_bytes > reader.left()) {
                return error.PolicyTruncated;
            }
        }
        const applied_block: ?[]f32 = if (block_count == 0) null else try gpa.alloc(f32, block_count);
        errdefer if (applied_block) |block| gpa.free(block);
        if (applied_block) |block| {
            @memcpy(sliceAsBytes(block), try reader.take(block_count * @sizeOf(f32)));
        }
        // The flow, last, when the file holds one - only on SuperTrack's observation as it is.
        var flow: ?PolicyFlow = null;
        errdefer if (flow) |*read_flow| read_flow.deinit(gpa);
        if (flags.holds_flow) {
            const condition_fits: bool = observation_kind == .supertrack_features and !flags.normalizes_observations;
            if (!condition_fits) {
                return error.PolicyFlowInvalid;
            }
            flow = try readFlow(gpa, &reader, header.observation_size, action_size);
        }
        if (reader.left() != 0) {
            return error.PolicyHasTrailingBytes;
        }
        if (stiffnessProblem(header.stiffness_count, header.stiffness_filter_beta, action_size)) |problem| {
            return problem;
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
            .applied_block = applied_block,
            .stiffness_count = header.stiffness_count,
            .stiffness_filter_beta = header.stiffness_filter_beta,
            .flow = flow,
        };
        return policy;
    }

    /// A layer as `readLayer` read it, and how many outputs it has: the next layer's input.
    const LayerRead = struct {
        layer: PolicyLayer,
        output_count: u32,
    };

    /// The next layer of a file, reading `input_count` values (`appendLayer` wrote it): its header checked - its
    /// activation known, its norm settings ones it can have - and its parameters' bytes counted against what is left
    /// before any is allocated. Memory: its parameters allocated with `gpa`, the caller's.
    fn readLayer(gpa: Allocator, reader: *Reader, input_count: u32) ReadError!LayerRead {
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
        const read: LayerRead = .{
            .layer = .{
                .activation = activation,
                .weights_and_biases = weights_and_biases,
                .norm_epsilon = layer_header.norm_epsilon,
                .simnorm_group = layer_header.simnorm_group,
            },
            .output_count = output_count,
        };
        return read;
    }

    /// The flow's section (`FlowHeader`), for a policy observing `observation_size` numbers and acting with
    /// `action_size`: its settings checked - layers, steps, a frequency count whose powers fit, coefficients - its
    /// input the observation, the point and the time features, its last layer giving the coefficients, and every count
    /// checked against the bytes left before anything is allocated. Memory: the flow's arrays allocated with `gpa`,
    /// the caller's.
    fn readFlow(
        gpa: Allocator,
        reader: *Reader,
        observation_size: usize,
        action_size: usize,
    ) ReadError!PolicyFlow {
        const flow_header: FlowHeader = bytesToValue(FlowHeader, try reader.take(@sizeOf(FlowHeader)));
        const settings_fit: bool = flow_header.layer_count > 0 and flow_header.euler_steps > 0 and
            flow_header.time_frequencies <= most_time_frequencies and flow_header.coefficient_count > 0;
        if (!settings_fit) {
            return error.PolicyFlowInvalid;
        }
        const layer_count: usize = flow_header.layer_count;
        const least_layer_bytes: usize = mulChecked(usize, layer_count, @sizeOf(LayerHeader)) catch {
            return error.PolicyTruncated;
        };
        if (least_layer_bytes > reader.left()) {
            return error.PolicyTruncated;
        }
        const coefficient_count: usize = flow_header.coefficient_count;
        const time_feature_count: usize = 2 * @as(usize, flow_header.time_frequencies);
        const input_width: usize = observation_size + coefficient_count + time_feature_count;
        const input_width_fits: bool = input_width <= maxInt(u32);
        if (!input_width_fits) {
            return error.PolicyFlowInvalid;
        }
        const widths: []u32 = try gpa.alloc(u32, layer_count + 1);
        errdefer gpa.free(widths);
        widths[0] = @intCast(input_width);
        const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, layer_count);
        var layers_read: usize = 0;
        errdefer {
            for (layers[0..layers_read]) |layer| {
                gpa.free(layer.weights_and_biases);
            }
            gpa.free(layers);
        }
        for (layers, 0..) |*layer, layer_index| {
            const read: LayerRead = try readLayer(gpa, reader, widths[layer_index]);
            layer.* = read.layer;
            widths[layer_index + 1] = read.output_count;
            layers_read += 1;
        }
        if (widths[layer_count] != coefficient_count) {
            return error.PolicyFlowInvalid;
        }
        const synergy_count: usize = mulChecked(usize, coefficient_count, action_size) catch {
            return error.PolicyTruncated;
        };
        const synergy_bytes: usize = mulChecked(usize, synergy_count, @sizeOf(f32)) catch {
            return error.PolicyTruncated;
        };
        if (synergy_bytes > reader.left()) {
            return error.PolicyTruncated;
        }
        const synergies: []f32 = try gpa.alloc(f32, synergy_count);
        @memcpy(sliceAsBytes(synergies), try reader.take(synergy_bytes));
        const flow: PolicyFlow = .{
            .widths = widths,
            .layers = layers,
            .euler_steps = flow_header.euler_steps,
            .time_frequencies = flow_header.time_frequencies,
            .synergies = synergies,
        };
        return flow;
    }

    /// Why a file's stiffnesses cannot be (`GenoPolicy.stiffness_count`, `stiffness_filter_beta`), or null: the
    /// limbs' stiffnesses follow the joints' numbers, so there are fewer of them than actions; and their filter's
    /// share is above 0 and at most 1, as any filter's - a share of 0 would never let a stiffness move, and a number
    /// that is not finite is no share.
    fn stiffnessProblem(
        stiffness_count: u32,
        stiffness_filter_beta: f32,
        action_size: usize,
    ) ?ReadError {
        if (stiffness_count >= action_size) {
            return error.PolicyStiffnessInvalid;
        }
        const is_share: bool = stiffness_filter_beta > 0 and stiffness_filter_beta <= 1;
        if (!is_share) {
            return error.PolicyStiffnessInvalid;
        }
        return null;
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
            .layer_norm_mish, .layer_norm_silu => is_epsilon_usable and simnorm_group == 0,
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
//
// A failure is counted once, at the step the reference is lost: where episodes do not restart
// (`robot_track.Fleet.Options.restarts_episodes` off, a viewer's choice), the fleet judges the reference lost again at
// every step it stays lost, and a character lying on the floor for a second has failed once, not sixty times.

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
        // The policy must fit the task: an observation of the size it names, an action per joint the subset nudges -
        // and, for a policy that gives the limbs' stiffnesses, one more per limb of the model.
        const feature_count: usize = robot_track.localSize(model.body_count);
        const observation_size: usize = switch (policy.observation) {
            .drecon => robot_policy.observationSize(subset),
            .supertrack_features => resident.supertrackGoalWidth(feature_count) + feature_count,
        };
        const observation_fits: bool = observation_size == policy.observationSize();
        assertf(observation_fits, @src(), "PolicyDecider: observations of {d}, a policy of {d}", .{
            observation_size,
            policy.observationSize(),
        });
        const stiffness_count: usize = policy.stiffness_count;
        const stiffnesses_fit: bool = stiffness_count == 0 or stiffness_count == model.limb_count;
        assertf(stiffnesses_fit, @src(), "PolicyDecider: {d} limbs, a policy of {d} stiffnesses", .{
            model.limb_count,
            stiffness_count,
        });
        const action_fits: bool = subset.dofs + stiffness_count == policy.actionSize();
        assertf(action_fits, @src(), "PolicyDecider: {d} actuated and {d} stiffnesses, a policy of {d} actions", .{
            subset.dofs,
            stiffness_count,
            policy.actionSize(),
        });
        const reference_views: robot_policy.Views = try .init(arena, model);
        const simulated_state: robot_track.State = try .init(arena, model.body_count);
        const reference_state: robot_track.State = try .init(arena, model.body_count);
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
        const action_size: usize = policy.actionSize();
        for (0..character_count) |character| {
            const character_action: []f32 = actions[character * action_size ..][0..action_size];
            switch (policy.observation) {
                .drecon => decider.observeDrecon(controller, fleet, character),
                .supertrack_features => |observation| decider.observeFeatures(observation, fleet, character),
            }
            // The action the controller's filter gave this character at its previous decision: the action applied
            // before this one, which a policy trained to see it reads.
            const applied: []const f32 = controller.appliedAction(character);
            policyMeanAction(policy, decider.observation, applied, decider.scratch, character_action);
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

    /// SuperTrack's features of `character`, into `observation`: the goal - its features and the root target's slots -
    /// then the state, the order the policy's first layer reads them in, through the learner's own definition
    /// (`robot_track_resident.supertrackFeaturesInto`).
    fn observeFeatures(
        decider: *PolicyDecider,
        supertrack_observation: SuperTrackObservation,
        fleet: *robot_track.Fleet,
        character: usize,
    ) void {
        const feature_count: usize = decider.raw_features.len;
        const goal_width: usize = resident.supertrackGoalWidth(feature_count);
        const goal: []f32 = decider.observation[0..goal_width];
        const state: []f32 = decider.observation[goal_width..][0..feature_count];
        const feature_scratch: resident.FeatureScratch = .{
            .simulated = &decider.simulated_state,
            .reference = &decider.reference_state,
            .probe = &decider.reference_probe,
            .raw_features = decider.raw_features,
        };
        const normalizer: latent.Normalizer = supertrack_observation.normalizer;
        const root_target: bool = supertrack_observation.root_target;
        resident.supertrackFeaturesInto(fleet, character, normalizer, root_target, feature_scratch, goal, state);
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
    /// failure - a physics step at which a character lost the reference it held at the step before.
    exposure_steps: u64 = 0,
    failure_count: u32 = 0,
    /// Each character's reference lost at the last step and still lost: a failure already counted, until the
    /// reference is held again or a new episode begins.
    lost_at_last_step: []bool,

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
            .limb_stiffness = policy.givesLimbStiffness(),
        });
        errdefer fleet.deinit();
        const controller: robot_policy.Controller =
            try .init(arena, model, decider.subset, character_count, policy.controllerOptions());
        const actions: []f32 = try arena.alloc(f32, character_count * policy.actionSize());
        @memset(actions, 0.0);
        const lost_at_last_step: []bool = try arena.alloc(bool, character_count);
        @memset(lost_at_last_step, false);
        const show: PolicyShow = .{
            .decider = decider,
            .fleet = fleet,
            .controller = controller,
            .character_count = character_count,
            .decimation = policy.decimation,
            .actions = actions,
            .lost_at_last_step = lost_at_last_step,
        };
        return show;
    }

    /// Releases what the fleet holds beyond its memory; the arena the show was started in frees the rest.
    pub fn end(show: *PolicyShow) void {
        show.fleet.deinit();
    }

    /// Starts `character`'s episode again, now (`robot_track.Fleet.restart`) - as an ended episode starts, its
    /// controller forgetting the action it was applying - and has the policy decide at the next step: what a viewer's
    /// reset does, the fleet restarting nothing itself (`robot_track.Fleet.Options.restarts_episodes`) or not.
    pub fn restart(show: *PolicyShow, character: usize) void {
        show.fleet.restart(character);
        show.controller.forget(character);
        show.lost_at_last_step[character] = false;
        show.physics_steps_until_decision = 0;
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
        // What the step lived: a unit of exposure per character, and its failures - each counted at the step the
        // reference is lost, not again while it stays lost. A character whose episode ended starts the next one
        // fresh: its controller forgets the action it was applying, and nothing of the last episode's loss is kept.
        for (0..show.character_count) |character| {
            show.exposure_steps += 1;
            const is_lost: bool = fleet.failures[character];
            const is_new_loss: bool = is_lost and !show.lost_at_last_step[character];
            if (is_new_loss) {
                show.failure_count += 1;
            }
            const episode_ended: bool = fleet.dones[character];
            show.lost_at_last_step[character] = is_lost and !episode_ended;
            if (episode_ended) {
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
        const controller: robot_policy.Controller =
            try .init(arena, model, decider.subset, character_count, policy.controllerOptions());
        const actions: []f32 = try arena.alloc(f32, character_count * policy.actionSize());
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
        // And the fleet's action is the policy's whole action - its joints' numbers, then its limbs' stiffnesses
        // where it gives them: a narrower fleet would be handed each character's numbers at another's place.
        const full_width: usize = judge_actor.controller.fullWidth();
        const same_action: bool = fleet.action_width == full_width;
        assertf(same_action, @src(), "a judged fleet of actions {d} wide, the policy's are {d}", .{
            fleet.action_width,
            full_width,
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
    // A policy that gives the limbs' stiffnesses is judged on a fleet whose limbs take them.
    const limb_stiffness: bool = if (policy) |judged| judged.givesLimbStiffness() else false;
    const fleet_options: robot_track.Fleet.Options = .{
        .action_scale = action_scale,
        .task = settings.task,
        .body_names = body_names,
        .limb_stiffness = limb_stiffness,
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
    // A policy that gives the limbs' stiffnesses is judged on a fleet whose limbs take them.
    const limb_stiffness: bool = if (policy) |judged| judged.givesLimbStiffness() else false;
    const fleet_options: robot_track.Fleet.Options = .{
        .action_scale = action_scale,
        .task = settings.task,
        .body_names = body_names,
        .limb_stiffness = limb_stiffness,
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
    policyMeanAction(&read_back, &observation, &.{}, scratch, &file_mean);
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
    policyMeanAction(&read_back, &observation, &.{}, scratch, &moved_mean);
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
        applyPolicyLayer(layer, &input_values, null, whole_layer);
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
    policyMeanAction(&policy, &observation, &.{}, scratch, &action);
    policyMeanAction(&read_back, &observation, &.{}, scratch, &action_read_back);
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

/// A small SuperTrack policy made by hand for the file's tests: 2 features, so 13 inputs (the goal's 2 features and
/// the root target's 9 slots, then the state's 2), 3 tanh, 2 out, deciding at every physics step with no limit on its
/// action - as SuperTrack's policy acts. Its feature statistics: means 0.5 and -1, spreads 2 and 0.25; its root target
/// on.
fn handMadeSuperTrackPolicy(gpa: Allocator) !GenoPolicy {
    const input_count: u32 = 2 * 2 + rbt.root_target_size;
    const widths: []u32 = try gpa.dupe(u32, &.{ input_count, 3, 2 });
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, 2);
    const first_weights: []f32 = try gpa.alloc(f32, PolicyLayer.parameterCount(.tanh, input_count, 3));
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
        .observation = .{ .supertrack_features = .{
            .normalizer = .{ .mean = feature_means, .spread = feature_spreads },
            .root_target = true,
        } },
        .decimation = 1,
    };
    return policy;
}

/// `handMadeSuperTrackPolicy` with a flow correcting it, made by hand for the file's tests: 2 coefficients, one time
/// frequency - an input of 13 + 2 + 2 - a layer-normed SiLU layer of 4 with weights by a formula of their index, then a
/// last layer of zero weights and biases (0.5, -1): a constant velocity, whatever the hidden layer says. Four Euler
/// steps of a quarter from zero land the point at (0.5, -1) exactly, and the synergies (1, 2) and (-1, 0) add
/// 0.5 (1, 2) - (-1, 0) = (1.5, 1) to the policy's action.
fn handMadeFlowPolicy(gpa: Allocator) !GenoPolicy {
    var policy: GenoPolicy = try handMadeSuperTrackPolicy(gpa);
    const coefficient_count: u32 = 2;
    const time_frequencies: u32 = 1;
    const input_width: u32 = policy.widths[0] + coefficient_count + 2 * time_frequencies;
    const widths: []u32 = try gpa.dupe(u32, &.{ input_width, 4, coefficient_count });
    const layers: []PolicyLayer = try gpa.alloc(PolicyLayer, 2);
    const hidden: []f32 = try gpa.alloc(f32, PolicyLayer.parameterCount(.layer_norm_silu, input_width, 4));
    for (hidden, 0..) |*weight, index| {
        weight.* = 0.05 * float(index % 7) - 0.1;
    }
    const last: []f32 = try gpa.alloc(f32, PolicyLayer.parameterCount(.none, 4, coefficient_count));
    @memset(last, 0);
    last[4 * coefficient_count] = 0.5;
    last[4 * coefficient_count + 1] = -1.0;
    layers[0] = .{ .activation = .layer_norm_silu, .weights_and_biases = hidden, .norm_epsilon = 1e-5 };
    layers[1] = .{ .activation = .none, .weights_and_biases = last };
    policy.flow = .{
        .widths = widths,
        .layers = layers,
        .euler_steps = 4,
        .time_frequencies = time_frequencies,
        .synergies = try gpa.dupe(f32, &.{ 1, 2, -1, 0 }),
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
    policyMeanAction(&policy, &observation, &.{}, written_scratch, &written_action);
    policyMeanAction(&read_back, &observation, &.{}, read_scratch, &read_action);
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
    const written_observation: SuperTrackObservation = policy.observation.supertrack_features;
    const read_observation: SuperTrackObservation = switch (read_back.observation) {
        .supertrack_features => |observation| observation,
        .drecon => return error.TestExpectedSuperTrackFeatures,
    };
    try expectEqualSlices(f32, written_observation.normalizer.mean, read_observation.normalizer.mean);
    try expectEqualSlices(f32, written_observation.normalizer.spread, read_observation.normalizer.spread);
    try expect(read_observation.root_target);
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
    // A root target's switch neither 0 nor 1 is no switch.
    @memcpy(damaged, bytes);
    const root_target_at: usize = header_size + @offsetOf(PolicyFile.ObservationHeader, "root_target");
    writeInt(u32, damaged[root_target_at..][0..4], 2, .little);
    try expectError(error.PolicyRootTargetInvalid, PolicyFile.decode(gpa, damaged));
}

test "GenoPolicy: a block reading the applied action reads back as written, and its count is checked" {
    // `handMadeSuperTrackPolicy` given a block reading the applied action: a weight for each of its first layer's 3
    // outputs and each of its 2 action numbers. Written and read back, the block is the same, and the action read
    // back is the action written - for an applied action that changes it. A count the first layer cannot read is
    // `PolicyFile.decode`'s refusal (the damaged files' test).
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadeSuperTrackPolicy(gpa);
    defer policy.deinit(gpa);
    const block_count: usize = policy.widths[1] * policy.actionSize();
    const block: []f32 = try gpa.alloc(f32, block_count);
    for (block, 0..) |*weight, index| {
        weight.* = 0.2 * float(index) - 0.5;
    }
    policy.applied_block = block;
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    try expectEqualSlices(f32, block, read_back.applied_block orelse return error.TestExpectedAppliedBlock);
    var observation: [2 * 2 + rbt.root_target_size]f32 = undefined;
    for (&observation, 0..) |*number, index| {
        number.* = 0.1 * float(index) - 0.4;
    }
    const applied = [2]f32{ 0.7, -0.3 };
    const scratch: PolicyScratch = try .init(gpa, &read_back);
    defer {
        gpa.free(scratch.ping);
        gpa.free(scratch.pong);
    }
    var written_action: [2]f32 = undefined;
    var read_action: [2]f32 = undefined;
    var without_applied: [2]f32 = undefined;
    policyMeanAction(&policy, &observation, &applied, scratch, &written_action);
    policyMeanAction(&read_back, &observation, &applied, scratch, &read_action);
    policyMeanAction(&read_back, &observation, &.{ 0, 0 }, scratch, &without_applied);
    try expectEqualSlices(f32, &written_action, &read_action);
    try expect(!eql(f32, &read_action, &without_applied));
}

test "GenoPolicy: a flow run's file carries its flow, reads back as written, and adds the flow's mode" {
    // `handMadeFlowPolicy`: the flow's correction (1.5, 1) on top of the policy's own action, whatever the observation.
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadeFlowPolicy(gpa);
    defer policy.deinit(gpa);
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    const written_flow: PolicyFlow = policy.flow.?;
    const read_flow: PolicyFlow = read_back.flow orelse return error.TestExpectedFlow;
    try expectEqualSlices(u32, written_flow.widths, read_flow.widths);
    try expectEqual(written_flow.euler_steps, read_flow.euler_steps);
    try expectEqual(written_flow.time_frequencies, read_flow.time_frequencies);
    try expectEqualSlices(f32, written_flow.synergies, read_flow.synergies);
    for (written_flow.layers, read_flow.layers) |written_layer, read_layer| {
        try expectEqual(written_layer.activation, read_layer.activation);
        try expectEqual(written_layer.norm_epsilon, read_layer.norm_epsilon);
        try expectEqualSlices(f32, written_layer.weights_and_biases, read_layer.weights_and_biases);
    }
    // Its action: the policy's own, without the flow, plus (1.5, 1).
    var observation: [2 * 2 + rbt.root_target_size]f32 = undefined;
    for (&observation, 0..) |*number, index| {
        number.* = 0.3 * float(index) - 1.0;
    }
    const scratch: PolicyScratch = try .init(gpa, &read_back);
    defer {
        gpa.free(scratch.ping);
        gpa.free(scratch.pong);
        gpa.free(scratch.flow_row);
        gpa.free(scratch.flow_ping);
        gpa.free(scratch.flow_pong);
        gpa.free(scratch.flow_velocity);
    }
    var corrected: [2]f32 = undefined;
    policyMeanAction(&read_back, &observation, &.{}, scratch, &corrected);
    var without_flow: GenoPolicy = read_back;
    without_flow.flow = null;
    var alone: [2]f32 = undefined;
    policyMeanAction(&without_flow, &observation, &.{}, scratch, &alone);
    try expectApproxEqAbs(alone[0] + 1.5, corrected[0], 1e-6);
    try expectApproxEqAbs(alone[1] + 1.0, corrected[1], 1e-6);
    // Refused: a flow on DReCon's observation (the flag set on a file without the slots), and a flow cut short.
    var drecon_policy: GenoPolicy = try handMadePolicy(gpa);
    defer drecon_policy.deinit(gpa);
    const drecon_bytes: []u8 = try PolicyFile.encode(gpa, &drecon_policy);
    defer gpa.free(drecon_bytes);
    const flags_at: usize = @offsetOf(PolicyFile.Header, "flags");
    const with_flow_flag: PolicyFile.Flags = .{ .normalizes_observations = true, .holds_flow = true };
    writeInt(u32, drecon_bytes[flags_at..][0..4], @bitCast(with_flow_flag), .little);
    try expectError(error.PolicyFlowInvalid, PolicyFile.decode(gpa, drecon_bytes));
    try expectError(error.PolicyTruncated, PolicyFile.decode(gpa, bytes[0 .. bytes.len - 4]));
}

test "GenoPolicy: a file carries the limbs' stiffnesses and their filter's share; ones that cannot be are refused" {
    const gpa: Allocator = testing_allocator;
    var policy: GenoPolicy = try handMadeSuperTrackPolicy(gpa);
    defer policy.deinit(gpa);
    // A policy of the joints alone has none, and its controller none to filter.
    try expectEqual(@as(u32, 0), policy.stiffness_count);
    try expect(!policy.givesLimbStiffness());
    try expectEqual(@as(usize, 0), policy.controllerOptions().stiffness_count);
    // Its two actions made a joint's number and a limb's stiffness, the stiffness filtered at a half.
    policy.stiffness_count = 1;
    policy.stiffness_filter_beta = 0.5;
    const bytes: []u8 = try PolicyFile.encode(gpa, &policy);
    defer gpa.free(bytes);
    var read_back: GenoPolicy = try PolicyFile.decode(gpa, bytes);
    defer read_back.deinit(gpa);
    try expectEqual(@as(u32, 1), read_back.stiffness_count);
    try expectEqual(@as(f32, 0.5), read_back.stiffness_filter_beta);
    try expect(read_back.givesLimbStiffness());
    // The controller the file's policy acts through: its own filter and interval, the stiffnesses and their share.
    const controller_options: robot_policy.Controller.Options = read_back.controllerOptions();
    try expectEqual(policy.filter_beta, controller_options.beta);
    try expectEqual(policy.decimation, controller_options.decimation);
    try expectEqual(@as(usize, 1), controller_options.stiffness_count);
    try expectEqual(@as(f32, 0.5), controller_options.stiffness_beta);
    // As many stiffnesses as actions leaves no joint's number: refused.
    const damaged: []u8 = try gpa.dupe(u8, bytes);
    defer gpa.free(damaged);
    const count_at: usize = @offsetOf(PolicyFile.Header, "stiffness_count");
    const share_at: usize = @offsetOf(PolicyFile.Header, "stiffness_filter_beta");
    writeInt(u32, damaged[count_at..][0..4], 2, .little);
    try expectError(error.PolicyStiffnessInvalid, PolicyFile.decode(gpa, damaged));
    // A share of zero, one above 1, and one that is no number: each refused - every one tried, each read one named.
    const bad_shares = [_]f32{ 0.0, 1.5, nan(f32) };
    var bad_shares_read: u32 = 0;
    for (bad_shares) |bad_share| {
        @memcpy(damaged, bytes);
        @memcpy(damaged[share_at..][0..4], asBytes(&bad_share));
        var accepted: GenoPolicy = PolicyFile.decode(gpa, damaged) catch |err| {
            try expectEqual(@as(PolicyFile.ReadError, error.PolicyStiffnessInvalid), err);
            continue;
        };
        accepted.deinit(gpa);
        report.failure("a stiffness filter's share of {d} is read\n", .{bad_share});
        bad_shares_read += 1;
    }
    try expectEqual(@as(u32, 0), bad_shares_read);
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
    const unknown_flag: PolicyFile.Flags = .{ .normalizes_observations = true, .unknown = 1 };
    writeInt(u32, damaged[flags_at..][0..4], @bitCast(unknown_flag), .little);
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
    // A block reading the applied action of a size the first layer cannot read - three weights, where it would take
    // one for each of its outputs and each number of the action - and one of four billion: refused, nothing allocated.
    const applied_count_at: usize = @sizeOf(PolicyFile.Header) +
        @offsetOf(PolicyFile.ObservationHeader, "applied_block_count");
    const no_block_bytes: []u8 = try gpa.dupe(u8, bytes);
    defer gpa.free(no_block_bytes);
    writeInt(u32, no_block_bytes[applied_count_at..][0..4], 3, .little);
    try expectError(error.PolicyAppliedBlockInvalid, PolicyFile.decode(gpa, no_block_bytes));
    writeInt(u32, no_block_bytes[applied_count_at..][0..4], maxInt(u32), .little);
    try expectError(error.PolicyAppliedBlockInvalid, PolicyFile.decode(gpa, no_block_bytes));
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
    policyMeanAction(&policy, &.{ 0.0, 0.0, 0.0 }, &.{}, scratch, &action);
    try expectEqualSlices(f32, &.{ 1.0, -1.0 }, &action);
    // An input 100 deviations from its mean is held at 5, as one 6 deviations away is: the same action.
    policy.layers[1].weights_and_biases[0] = 1.0;
    var far_action: [2]f32 = undefined;
    var near_action: [2]f32 = undefined;
    policyMeanAction(&policy, &.{ 0.5 + 100.0 * 2.0, -1.0, 2.0 }, &.{}, scratch, &far_action);
    policyMeanAction(&policy, &.{ 0.5 + 6.0 * 2.0, -1.0, 2.0 }, &.{}, scratch, &near_action);
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

test "robot_lab: a clip's variants - the clip first, each side at three speeds, labelled; SuperTrack's alone" {
    // None asked: the clip alone. Mirrored: the clip and its mirror image. Speeds: each side at its own speed, slower,
    // faster - so both give six, in the order a run holds them, and each its label. A speed change outside [0, 0.5)
    // and variants asked of PPO are refused by name.
    var room: [ClipVariants.most_per_clip]ClipVariant = undefined;
    const none: ClipVariants = .{};
    try expectEqual(@as(usize, 1), none.list(&room).len);
    try expect(none.list(&room)[0].isTheClip());
    const mirrored: ClipVariants = .{ .mirrored = true };
    try expectEqual(@as(usize, 2), mirrored.list(&room).len);
    const speeds: ClipVariants = .{ .speed_change = 0.2 };
    try expectEqual(@as(usize, 3), speeds.list(&room).len);
    const both: ClipVariants = .{ .mirrored = true, .speed_change = 0.2 };
    const all: []const ClipVariant = both.list(&room);
    try expectEqual(@as(usize, ClipVariants.most_per_clip), all.len);
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const expected_labels = [_][]const u8{
        "walk",
        "walk at 0.8",
        "walk at 1.2",
        "walk mirrored",
        "walk mirrored at 0.8",
        "walk mirrored at 1.2",
    };
    for (all, expected_labels, 0..) |variant, expected_label, index| {
        const label: []const u8 = try variant.label(arena, "walk");
        try expectEqualStrings(expected_label, label);
        try expectEqual(index == 0, variant.isTheClip());
    }
    const out_of_range = [_]f32{ -0.1, 0.5, nan(f32) };
    for (out_of_range) |change| {
        const refused: GenoRun = .{
            .task = .{ .variants = .{ .speed_change = change } },
            .learner = .{ .supertrack = .{} },
        };
        const range_refusal: ?[]const u8 = refused.problem();
        try expect(range_refusal != null);
        try expect(startsWith(u8, range_refusal.?, "task.variants.speed_change"));
    }
    const with_ppo: GenoRun = .{ .task = .{ .variants = .{ .mirrored = true } } };
    const ppo_refusal: ?[]const u8 = with_ppo.problem();
    try expect(ppo_refusal != null);
    try expect(startsWith(u8, ppo_refusal.?, "task.variants"));
    const with_supertrack: GenoRun = .{ .task = .{ .variants = both }, .learner = .{ .supertrack = .{} } };
    try expectEqual(@as(?[]const u8, null), with_supertrack.problem());
}

test "robot_lab: the normed world model in a recipe - 1 to 4 hidden layers, and no skip head beside it" {
    // The world model's form reaches the learner by the recipe; in the normed form the kit holds 1 to 4 hidden
    // layers, and the skip head, which reads the tanh form's second layer, is refused by name.
    const prefix: []const u8 = "learner.supertrack.";
    const in_form: SuperTrackLearner = .{
        .world_form = .normed_silu,
        .world_hidden_layers = 3,
        .world_alone_updates = 500,
    };
    try expectEqual(@as(?[]const u8, null), superTrackProblem(prefix, in_form));
    try expectEqual(resident.WorldModelForm.normed_silu, in_form.options().world_form);
    try expectEqual(@as(u32, 500), in_form.options().world_alone_updates);
    const layer_counts = [_]u32{ 0, 5 };
    for (layer_counts) |layer_count| {
        var out_of_range: SuperTrackLearner = in_form;
        out_of_range.world_hidden_layers = layer_count;
        const refusal: []const u8 = superTrackProblem(prefix, out_of_range) orelse return error.Allowed;
        try expect(startsWith(u8, refusal, prefix ++ "world_hidden_layers: 1 to 4"));
    }
    // The dense form reads no layer count: any is allowed beside it.
    var dense: SuperTrackLearner = in_form;
    dense.world_form = .dense_tanh;
    dense.world_hidden_layers = 0;
    try expectEqual(@as(?[]const u8, null), superTrackProblem(prefix, dense));
    var with_skip: SuperTrackLearner = in_form;
    with_skip.skip_span = 4;
    const skip_refusal: []const u8 = superTrackProblem(prefix, with_skip) orelse return error.Allowed;
    try expect(startsWith(u8, skip_refusal, prefix ++ "skip_span: 0 with the world model in the normed form"));
}

test "robot_lab: with phases, a SuperTrack learner's rows come in pairs, and its gate's settings are in range" {
    // The world model's gate measures it on pairs of windows - two candidates of one replan - so with phases an odd
    // number of rows is refused by name, and allowed without; the gate's interval must be minutes, and each of its
    // bars in its range.
    const with_phases: resident.Phases = .{ .enabled = true };
    const paired: SuperTrackLearner = .{ .rows = 16, .phases = with_phases };
    try expectEqual(@as(?[]const u8, null), superTrackProblem("learner.supertrack.", paired));
    const unpaired: SuperTrackLearner = .{ .rows = 15, .phases = with_phases };
    const unpaired_refusal: []const u8 = superTrackProblem("learner.supertrack.", unpaired) orelse return error.Allowed;
    try expect(startsWith(u8, unpaired_refusal, "learner.supertrack.rows: an even number with phases"));
    const unpaired_without_phases: SuperTrackLearner = .{ .rows = 15 };
    try expectEqual(@as(?[]const u8, null), superTrackProblem("learner.supertrack.", unpaired_without_phases));
    var backwards_phases: resident.Phases = with_phases;
    backwards_phases.gate.measure_every_minutes = -1;
    const backwards: SuperTrackLearner = .{ .rows = 16, .phases = backwards_phases };
    const backwards_refusal: []const u8 =
        superTrackProblem("learner.supertrack.", backwards) orelse return error.Allowed;
    try expect(startsWith(u8, backwards_refusal, "learner.supertrack.phases.gate.measure_every_minutes"));
    // The gate's bars, each refused by name past its range; at its range's ends, allowed.
    const BarCase = struct { gate: resident.Gate, refused_as: ?[]const u8 };
    const bar_cases = [_]BarCase{
        .{ .gate = .{ .state_error_ratio_bar = -0.1 }, .refused_as = "learner.supertrack.phases.gate.state_error" },
        .{ .gate = .{ .state_error_ratio_bar = 0 }, .refused_as = null },
        .{ .gate = .{ .response_cosine_bar = 1.5 }, .refused_as = "learner.supertrack.phases.gate.response_cosine" },
        .{ .gate = .{ .response_cosine_bar = -1 }, .refused_as = null },
        .{ .gate = .{ .response_ratio_band = 0.9 }, .refused_as = "learner.supertrack.phases.gate.response_ratio" },
        .{ .gate = .{ .response_ratio_band = 1 }, .refused_as = null },
    };
    for (bar_cases) |bar_case| {
        var phases_with_bar: resident.Phases = with_phases;
        phases_with_bar.gate = bar_case.gate;
        const learner: SuperTrackLearner = .{ .rows = 16, .phases = phases_with_bar };
        const refusal: ?[]const u8 = superTrackProblem("learner.supertrack.", learner);
        const expected_name: []const u8 = bar_case.refused_as orelse {
            try expectEqual(@as(?[]const u8, null), refusal);
            continue;
        };
        try expect(startsWith(u8, refusal orelse return error.Allowed, expected_name));
    }
}

test "robot_lab: a recipe's pushes - each setting refused by name out of its range, allowed at its range's end" {
    // The pushes reach the fleet by the recipe (`SuperTrackLearner.pushes`), so they are judged through the learner's
    // settings. Every case is looked at before the test fails, so one run names each setting that is judged wrongly.
    const prefix: []const u8 = "learner.supertrack.";
    const Pushes = robot_track.Pushes;
    const PushesCase = struct { pushes: Pushes, refused_as: ?[]const u8 };
    const a_night: Pushes = .{
        .rate_per_second = 0.5,
        .speed_min = 0.5,
        .speed_max = 5,
        .full_hours = 6,
        .brake = .{ .come_back_bar = 0.6 },
        .start_share = 0.25,
    };
    const cases = [_]PushesCase{
        .{ .pushes = .{}, .refused_as = null },
        .{ .pushes = a_night, .refused_as = null },
        .{ .pushes = .{ .rate_per_second = -0.5 }, .refused_as = prefix ++ "pushes.rate_per_second" },
        .{ .pushes = .{ .speed_min = -1 }, .refused_as = prefix ++ "pushes.speed_min" },
        .{ .pushes = .{ .full_hours = -6 }, .refused_as = prefix ++ "pushes.full_hours" },
        .{ .pushes = .{ .full_hours = inf(f32) }, .refused_as = prefix ++ "pushes.full_hours" },
        .{ .pushes = .{ .speed_min = 2, .speed_max = 1 }, .refused_as = prefix ++ "pushes.speed_max" },
        .{ .pushes = .{ .speed_min = 2, .speed_max = 2 }, .refused_as = null },
        .{ .pushes = .{ .start_share = 1.5 }, .refused_as = prefix ++ "pushes.start_share" },
        .{ .pushes = .{ .start_share = 1 }, .refused_as = null },
        .{ .pushes = .{ .brake = .{ .come_back_bar = 1.5 } }, .refused_as = prefix ++ "pushes.brake.come_back_bar" },
        .{ .pushes = .{ .brake = .{ .come_back_bar = 1 } }, .refused_as = null },
        .{ .pushes = .{ .brake = .{ .watched_share = 0 } }, .refused_as = prefix ++ "pushes.brake.watched_share" },
        .{ .pushes = .{ .brake = .{ .watched_share = 1.5 } }, .refused_as = prefix ++ "pushes.brake.watched_share" },
        .{ .pushes = .{ .brake = .{ .watched_share = 1 } }, .refused_as = null },
        .{ .pushes = .{ .brake = .{ .watch_seconds = 0 } }, .refused_as = prefix ++ "pushes.brake.watch_seconds" },
        .{ .pushes = .{ .brake = .{ .window_minutes = 0 } }, .refused_as = prefix ++ "pushes.brake.window_minutes" },
        .{ .pushes = .{ .brake = .{ .catch_up_pace = 0.5 } }, .refused_as = prefix ++ "pushes.brake.catch_up_pace" },
        .{ .pushes = .{ .brake = .{ .catch_up_pace = 1 } }, .refused_as = null },
    };
    var cases_judged_wrongly: u32 = 0;
    for (cases, 0..) |case, case_index| {
        const learner: SuperTrackLearner = .{ .pushes = case.pushes };
        const refusal: []const u8 = superTrackProblem(prefix, learner) orelse "";
        const expected: []const u8 = case.refused_as orelse "";
        const is_allowed_as_expected: bool = expected.len == 0 and refusal.len == 0;
        const is_refused_as_expected: bool = expected.len > 0 and startsWith(u8, refusal, expected);
        if (is_allowed_as_expected or is_refused_as_expected) {
            continue;
        }
        cases_judged_wrongly += 1;
        report.failure("pushes case {d}: expected '{s}', found '{s}'\n", .{ case_index, expected, refusal });
    }
    try expectEqual(@as(u32, 0), cases_judged_wrongly);
}

test "robot_lab: a recipe's critic lambdas - each refused by name past 0 to 1, allowed at both ends" {
    const prefix: []const u8 = "learner.supertrack.";
    const LambdaCase = struct { real: f32, imagined: f32, refused_as: ?[]const u8 };
    const quiet_nan: f32 = @bitCast(@as(u32, 0x7FC0_0000));
    const cases = [_]LambdaCase{
        .{ .real = 0, .imagined = 0, .refused_as = null },
        .{ .real = 1, .imagined = 1, .refused_as = null },
        .{ .real = 0.5, .imagined = 0.92, .refused_as = null },
        .{ .real = -0.1, .imagined = 0.92, .refused_as = prefix ++ "critic.real_lambda" },
        .{ .real = 1.5, .imagined = 0.92, .refused_as = prefix ++ "critic.real_lambda" },
        .{ .real = quiet_nan, .imagined = 0.92, .refused_as = prefix ++ "critic.real_lambda" },
        .{ .real = 0.5, .imagined = 1.1, .refused_as = prefix ++ "critic.imagined_lambda" },
    };
    var checks: report.Checks = .{};
    for (cases, 0..) |case, case_index| {
        const critic: @FieldType(SuperTrackLearner, "critic") = .{
            .real_lambda = case.real,
            .imagined_lambda = case.imagined,
        };
        const learner: SuperTrackLearner = .{ .critic = critic };
        const refusal: []const u8 = superTrackProblem(prefix, learner) orelse "";
        const expected: []const u8 = case.refused_as orelse "";
        const as_expected: bool = if (expected.len == 0) refusal.len == 0 else startsWith(u8, refusal, expected);
        checks.holds(as_expected, "lambdas case {d}: expected '{s}', found '{s}'\n", .{
            case_index,
            expected,
            refusal,
        });
    }
    try checks.finish();
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

/// The number a log's `line` holds under the column `name` of its `header` - both without their line ends.
fn numberUnderColumn(
    header: []const u8,
    line: []const u8,
    name: []const u8,
) !f64 {
    var names = splitScalar(u8, header, ',');
    var values = splitScalar(u8, line, ',');
    while (names.next()) |column_name| {
        const value: []const u8 = values.next() orelse return error.LineShorterThanItsHeader;
        if (eql(u8, column_name, name)) {
            return parseFloat(f64, value);
        }
    }
    return error.NoSuchColumn;
}

test "RecoveryLog: a line has the header's columns, and the returns' fluid numbers stand under their own" {
    var log: ArrayList(u8) = .empty;
    defer log.deinit(testing_allocator);
    const band: robot_track.RecoveryBand = .{
        .speed = 3,
        .pushes = 4,
        .lost = 4,
        .returned = 1,
        .return_steps_sum = 90,
        .step_seconds = 1.0 / 60.0,
        .return_fluid_steps = 90,
        .return_action_rate_sum = 216,
        .return_jerk_sum = 43200,
    };
    try RecoveryLog.appendLines(testing_allocator, &log, 7, 1.5, "dance", &.{band});
    const header: []const u8 = RecoveryLog.header[0 .. RecoveryLog.header.len - 1];
    const line: []const u8 = log.items[0 .. log.items.len - 1];
    try expectEqual(std.mem.count(u8, header, ","), std.mem.count(u8, line, ","));
    try expectEqual(@as(f64, 90), try numberUnderColumn(header, line, "return_fluid_steps"));
    try expectEqual(@as(f64, 216), try numberUnderColumn(header, line, "return_action_rate_sum"));
    try expectEqual(@as(f64, 43200), try numberUnderColumn(header, line, "return_jerk_sum"));
}

test "RoundTimeLog: the idle share is the device's own measure, and a line's numbers stand under their columns" {
    // A ROUND OF ONE SECOND, as the course tells it. The host records the acting for 100 ms, waits in the books for
    // 300 ms while the device runs it, records the physics for 100 ms, and does its own work for the 500 ms left -
    // the device running the physics for the first 200 of them:
    //
    //     ms       0        100                   400       500             700              1,000
    //     host     | records |  waits in the books  | records |           its own work              |
    //     device   |  idle   |  acting 300 ms       |  idle   | physics 200 ms |       idle         |
    var clock: rbt.PhaseClock = .{};
    clock.begin(0);
    clock.enter(0, .acting);
    clock.enter(100, .books);
    clock.addWait(300);
    clock.enter(400, .physics);
    clock.enter(500, .other);
    clock.end(1000);
    const acting: usize = @backingInt(rbt.RoundPhase.acting);
    const books: usize = @backingInt(rbt.RoundPhase.books);
    const physics: usize = @backingInt(rbt.RoundPhase.physics);
    const other: usize = @backingInt(rbt.RoundPhase.other);
    var gpu_microseconds: [rbt.RoundPhase.count]f64 = @splat(0);
    var gpu_segments: [rbt.RoundPhase.count]u32 = @splat(0);
    gpu_microseconds[acting] = 300_000;
    gpu_segments[acting] = 9;
    gpu_microseconds[physics] = 200_000;
    gpu_segments[physics] = 1;
    const line: RoundTimeLog.Line = RoundTimeLog.lineOf(.{
        .round = 7,
        .training_minutes = 1.5,
        .between_rounds_ms = 12,
        // A round that shared the machine: 40 ms of its other work were the device's rest.
        .rested_ms = 40,
        .gpu_microseconds = gpu_microseconds,
        .gpu_segments = gpu_segments,
        // From the acting's first mark, at 100 ms, to the physics' last, at 700.
        .gpu_span_microseconds = 600_000,
        .clock = clock,
        .submissions = 10,
        .dispatches = 78,
        .untimed_dispatches = 3,
    });
    try expectEqual(@as(f32, 1000), line.wall_ms);
    try expectEqual(@as(f32, 500), line.gpu_busy_ms);
    try expectEqual(@as(f32, 300), line.host_wait_ms);
    try expectEqual(@as(f32, 600), line.gpu_span_ms);
    // THE IDLE SHARE: the device was in no segment for 500 of the 1,000 ms. The host's clock gives neither that nor
    // its complement: the host waited 300 ms - a share of 0.3, and 0.7 left.
    try expectApproxEqAbs(@as(f32, 0.5), line.gpu_idle_share, 1.0e-6);
    const acting_times: RoundTimeLog.PhaseTimes = .{ .gpu_ms = 300, .host_ms = 100, .wait_ms = 0, .segments = 9 };
    const books_times: RoundTimeLog.PhaseTimes = .{ .gpu_ms = 0, .host_ms = 300, .wait_ms = 300, .segments = 0 };
    const physics_times: RoundTimeLog.PhaseTimes = .{ .gpu_ms = 200, .host_ms = 100, .wait_ms = 0, .segments = 1 };
    const other_times: RoundTimeLog.PhaseTimes = .{ .gpu_ms = 0, .host_ms = 500, .wait_ms = 0, .segments = 0 };
    try expectEqual(acting_times, line.phases[acting]);
    try expectEqual(books_times, line.phases[books]);
    try expectEqual(physics_times, line.phases[physics]);
    try expectEqual(other_times, line.phases[other]);
    // The share's edges: a round of no time has none, and a device timed busier than the wall clock is not idle.
    try expectEqual(@as(f32, 0), RoundTimeLog.idleShare(0, 5));
    try expectEqual(@as(f32, 0), RoundTimeLog.idleShare(100, 101));
    try expectEqual(@as(f32, 0.25), RoundTimeLog.idleShare(100, 75));
    // THE FILE: as many columns in the line as in the header, and each number under its own name.
    var log: ArrayList(u8) = .empty;
    defer log.deinit(testing_allocator);
    try RoundTimeLog.appendLine(testing_allocator, &log, line);
    const header: []const u8 = RoundTimeLog.header[0 .. RoundTimeLog.header.len - 1];
    const line_text: []const u8 = log.items[0 .. log.items.len - 1];
    const header_columns: usize = std.mem.count(u8, header, ",") + 1;
    const columns_expected: usize = 12 + 4 * rbt.RoundPhase.count;
    try expectEqual(columns_expected, header_columns);
    try expectEqual(header_columns, std.mem.count(u8, line_text, ",") + 1);
    const Column = struct { name: []const u8, number: f64 };
    const columns = [_]Column{
        .{ .name = "round", .number = 7 },
        .{ .name = "training_minutes", .number = 1.5 },
        .{ .name = "wall_ms", .number = 1000 },
        .{ .name = "between_rounds_ms", .number = 12 },
        .{ .name = "rested_ms", .number = 40 },
        .{ .name = "gpu_busy_ms", .number = 500 },
        .{ .name = "gpu_idle_share", .number = 0.5 },
        .{ .name = "gpu_span_ms", .number = 600 },
        .{ .name = "host_wait_ms", .number = 300 },
        .{ .name = "submissions", .number = 10 },
        .{ .name = "dispatches", .number = 78 },
        .{ .name = "untimed_dispatches", .number = 3 },
        .{ .name = "acting_gpu_ms", .number = 300 },
        .{ .name = "acting_host_ms", .number = 100 },
        .{ .name = "acting_segments", .number = 9 },
        .{ .name = "books_host_ms", .number = 300 },
        .{ .name = "books_wait_ms", .number = 300 },
        .{ .name = "physics_gpu_ms", .number = 200 },
        .{ .name = "physics_segments", .number = 1 },
        .{ .name = "other_host_ms", .number = 500 },
        .{ .name = "planner_segments", .number = 0 },
    };
    for (columns) |column| {
        try expectEqual(column.number, try numberUnderColumn(header, line_text, column.name));
    }
}

test "KernelTimeLog: the kernels by their time on the device, the largest first, without those never dispatched" {
    // Four kernels of two pipes, in no order, one never dispatched: 10 ms between the three that ran.
    var entries = [_]KernelTimeLog.Entry{
        .{ .pipe = "simulator", .kernel = "dense_fwd", .dispatches = 4, .gpu_microseconds = 1000 },
        .{ .pipe = "simulator", .kernel = "broadphase", .dispatches = 0, .gpu_microseconds = 0 },
        .{ .pipe = "simulator", .kernel = "newton_solve", .dispatches = 2, .gpu_microseconds = 6000 },
        .{ .pipe = "learner", .kernel = "matmul", .dispatches = 8, .gpu_microseconds = 3000 },
    };
    var file: ArrayList(u8) = .empty;
    defer file.deinit(testing_allocator);
    try KernelTimeLog.write(testing_allocator, &file, &entries);
    const expected: []const u8 = "pipe,kernel,dispatches,gpu_ms,gpu_share\n" ++
        "simulator,newton_solve,2,6.000,0.6000\n" ++
        "learner,matmul,8,3.000,0.3000\n" ++
        "simulator,dense_fwd,4,1.000,0.1000\n";
    try expectEqualStrings(expected, file.items);
}

test "JudgeLog.superMimicSuccess: the first judgement with every clip completed whole and the mean return at the bar" {
    // Two clips. Each judgement writes every clip's line of starts, then its whole line; only the whole lines count,
    // and the servo's (batch 0) never does. Normalised returns by judgement:
    //
    //     batch   dance/whole          get-up/whole          why
    //     0       1.00, completed      1.00, completed       the servo's: not counted
    //     3       0.90, completed      0.95, lost            a clip not completed
    //     4       1.00, completed      (no line)             a clip not judged whole
    //     5       0.80, completed      0.82, completed       a mean of 0.81, below the bar of 0.82
    //     7       0.82, completed      0.86, completed       a mean of 0.84: THE SUCCESS
    //     9       0.90, completed      0.90, completed       later
    const gpa: Allocator = testing_allocator;
    const scales: robot_track.SuperMimicScales = .{};
    const step_maximum: f64 = scales.maxStepTracking();
    const available_steps: usize = 300;
    const Whole = struct { batch: u64, clip: []const u8, normalised: f64, completed: bool };
    const wholes = [_]Whole{
        .{ .batch = 0, .clip = "dance", .normalised = 1.0, .completed = true },
        .{ .batch = 0, .clip = "get-up", .normalised = 1.0, .completed = true },
        .{ .batch = 3, .clip = "dance", .normalised = 0.9, .completed = true },
        .{ .batch = 3, .clip = "get-up", .normalised = 0.95, .completed = false },
        .{ .batch = 4, .clip = "dance", .normalised = 1.0, .completed = true },
        .{ .batch = 5, .clip = "dance", .normalised = 0.80, .completed = true },
        .{ .batch = 5, .clip = "get-up", .normalised = 0.82, .completed = true },
        .{ .batch = 7, .clip = "dance", .normalised = 0.82, .completed = true },
        .{ .batch = 7, .clip = "get-up", .normalised = 0.86, .completed = true },
        .{ .batch = 9, .clip = "dance", .normalised = 0.90, .completed = true },
        .{ .batch = 9, .clip = "get-up", .normalised = 0.90, .completed = true },
    };
    var judgements: ArrayList(u8) = .empty;
    defer judgements.deinit(gpa);
    try judgements.appendSlice(gpa, JudgeLog.header);
    // Where the text ends after the success's judgement, for a history that stops there.
    var length_through_the_success: usize = 0;
    for (wholes) |whole| {
        const minutes: f32 = float(whole.batch) * 2;
        // The clip's line of starts first - a perfect one, which must not count.
        const starts_judgement: robot_track.Judgement = .{
            .starts = 5,
            .failures = 0,
            .reached_end = 5,
            .watched_steps = 1500,
            .reward_sum = 0,
            .frame_time = 1.0 / 30.0,
            .super_mimic_return_sum = step_maximum * 1500,
            .super_mimic_available_steps = 1500,
        };
        try JudgeLog.appendLine(gpa, &judgements, whole.batch, minutes, whole.clip, starts_judgement);
        const whole_judgement: robot_track.Judgement = .{
            .starts = 1,
            .failures = if (whole.completed) 0 else 1,
            .reached_end = if (whole.completed) 1 else 0,
            .watched_steps = available_steps,
            .reward_sum = 0,
            .frame_time = 1.0 / 30.0,
            .super_mimic_return_sum = whole.normalised * step_maximum * float64(available_steps),
            .super_mimic_available_steps = available_steps,
        };
        var label_buffer: [32]u8 = undefined;
        const whole_label: []const u8 = try bufPrint(&label_buffer, "{s}/whole", .{whole.clip});
        try JudgeLog.appendLine(gpa, &judgements, whole.batch, minutes, whole_label, whole_judgement);
        if (whole.batch == 7) {
            length_through_the_success = judgements.items.len;
        }
    }
    const labels = [_][]const u8{ "dance", "get-up" };
    const bar: f32 = JudgeLog.success_normalised_return;
    const success: JudgeLog.SuperMimicSuccess =
        JudgeLog.superMimicSuccess(judgements.items, &labels, scales, bar) orelse return error.NoSuccess;
    var checks: report.Checks = .{};
    checks.holds(success.batch == 7, "the success at batch {d}, 7 expected\n", .{success.batch});
    checks.holds(success.training_minutes == 14, "at {d} minutes, 14 expected\n", .{success.training_minutes});
    const mean_is_right: bool = @abs(success.mean_normalised_return - 0.84) <= 1e-5;
    checks.holds(mean_is_right, "a mean of {d}, 0.84 expected\n", .{success.mean_normalised_return});
    // A bar above every judgement's mean: none succeeds. One clip only: dance's first whole judgement past the servo
    // completed at 0.9 - batch 3.
    const above: ?JudgeLog.SuperMimicSuccess = JudgeLog.superMimicSuccess(judgements.items, &labels, scales, 0.95);
    checks.holds(above == null, "a success above every mean\n", .{});
    const dance_only = [_][]const u8{"dance"};
    const dance_success: ?JudgeLog.SuperMimicSuccess =
        JudgeLog.superMimicSuccess(judgements.items, &dance_only, scales, bar);
    const dance_batch: u64 = if (dance_success) |found| found.batch else 0;
    checks.holds(dance_batch == 3, "dance alone succeeds at batch {d}, 3 expected\n", .{dance_batch});
    // At the bar itself - the success's own mean - it still succeeds there.
    const at_the_bar: ?JudgeLog.SuperMimicSuccess =
        JudgeLog.superMimicSuccess(judgements.items, &labels, scales, success.mean_normalised_return);
    const at_the_bar_batch: u64 = if (at_the_bar) |found| found.batch else 0;
    checks.holds(at_the_bar_batch == 7, "at the bar itself, batch {d}, 7 expected\n", .{at_the_bar_batch});
    // A low bar, 0.45: batch 4 - dance alone, 1.0 - would clear it as a mean over both clips; a judgement without a
    // clip's whole line cannot succeed, so batch 5 does.
    const low: ?JudgeLog.SuperMimicSuccess = JudgeLog.superMimicSuccess(judgements.items, &labels, scales, 0.45);
    const low_batch: u64 = if (low) |found| found.batch else 0;
    checks.holds(low_batch == 5, "at a bar of 0.45, batch {d}, 5 expected\n", .{low_batch});
    // A history that ends with the success's judgement: decided at the text's end.
    const history_to_the_success: []const u8 = judgements.items[0..length_through_the_success];
    const last: ?JudgeLog.SuperMimicSuccess =
        JudgeLog.superMimicSuccess(history_to_the_success, &labels, scales, bar);
    const last_batch: u64 = if (last) |found| found.batch else 0;
    checks.holds(last_batch == 7, "a history ending at the success: batch {d}, 7 expected\n", .{last_batch});
    try checks.finish();
}

test "SuperTrackLog.numberAtRound: a column's number on a round's line, by the header's names" {
    const gpa: Allocator = testing_allocator;
    var log: ArrayList(u8) = .empty;
    defer log.deinit(gpa);
    try log.appendSlice(gpa, SuperTrackLog.header);
    const rounds = [_]u64{ 1, 2, 3 };
    for (rounds) |round| {
        try SuperTrackLog.appendLine(gpa, &log, .{
            .round = round,
            .training_minutes = float(round),
            .steps_watched = 100,
            .failures = 1,
            .world_updates = round,
            .policy_updates = round,
            .active_minutes = 0.75 * float(round),
        });
    }
    try expectEqual(@as(?f64, 1.5), SuperTrackLog.numberAtRound(log.items, "active_minutes", 2));
    try expectEqual(@as(?f64, 3), SuperTrackLog.numberAtRound(log.items, "training_minutes", 3));
    try expectEqual(@as(?f64, 2), SuperTrackLog.numberAtRound(log.items, "round", 2));
    try expectEqual(@as(?f64, null), SuperTrackLog.numberAtRound(log.items, "active_minutes", 4));
    try expectEqual(@as(?f64, null), SuperTrackLog.numberAtRound(log.items, "no_such_column", 2));
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
