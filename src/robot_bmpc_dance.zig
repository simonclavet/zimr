//! robot_bmpc_dance - Geno's dance as an environment of the CPU EfficientTDMPC agent (`robot_bmpc.Bmpc(f32)`).
//!
//! The agent's training loop steps a list of environments, each one episode at a time, through a two-function
//! contract (`Bmpc(T).requireEnvironment`): `reset` starts an episode and writes its first observation; `step` acts
//! once, writes the observation that follows and says what the step earned and whether the episode goes on. A
//! `TrackCharacter` is one character of the dance behind that contract: a decision-level tracking environment of one
//! (`robot_track_env.TrackEnv`) on a fleet of its own - DReCon's observation, DReCon's controller (the decision held
//! for the learner's interval, through the 0.2 filter), Geno's task and reward.
//!
//! HOW A FALL REACHES THE AGENT. The agent models no termination: its value targets and its planner bootstrap from the
//! model's next state, so its trainer refuses a step that calls its state final. A character that loses the reference
//! therefore lives on through an AFTERMATH (`robot_track.Fleet.Options.aftermath_steps`): simulated and rewarded as
//! usual through its fall, under Geno's gravity-gated reward - its height 0.8 m low keeps 2 % of the reward, its body
//! lying flat 6 %, the two together about a tenth of a percent - and then the episode is CUT, as the clip's end and
//! the step cap are:
//!
//!     decision      ...   d      d+1  ...  d+30   d+31
//!     the step            lost   in the aftermath  cut | a new episode
//!     the reward          ~0.5   falling towards ~0.001
//!     stored as           -      -          truncated  (the successor: the TRUE state the fall ended in)
//!
//! The agent's world model then learns from its own data what losing the reference leads to, and its value learns
//! what it is worth - a second of almost nothing - without a notion of termination anywhere in its equations.
//!
//! WHERE AN EPISODE STARTS. The trainer's reset stream chooses it: `reset` draws the clip and the frame from the
//! `Rng` it is handed and puts the character there (`robot_track.Fleet.startAt`). A fleet restarts a character by
//! itself at the end of every episode; `reset` replaces that start with the trainer's, so that every start of a run
//! comes from one labelled stream and the same seeds replay the same run.
//!
//! WHAT IS COUNTED. Each character keeps the counts a training log needs: the physics steps it lived at risk (an
//! aftermath's steps come after the failure, so they are not at risk) and the failures among them.

const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const rbt = @import("robot");
const dance = @import("robot_dance.zig");
const track = @import("robot_track.zig");
const track_env = @import("robot_track_env.zig");
const robot_lab = @import("robot_lab.zig");
const geno = @import("robot_geno.zig");

const Allocator = std.mem.Allocator;
const Rng = zn.Rng;
const assertf = zm.assertf;
const isFinite = zm.isFinite;
const float = zm.float;

/// The agent the dance is trained with: f32 throughout, as its GPU form computes (`robot_lab.TdmpcAgent`).
pub const Agent = robot_lab.TdmpcAgent;

/// One character of the dance as an environment of the agent (see this file's head).
pub const TrackCharacter = struct {
    /// The character: a decision-level tracking environment of exactly one.
    environment: track_env.TrackEnv,
    /// What the last decision came to, and the observation an episode ended in when it was cut.
    outcome: [1]track_env.Outcome,
    ended_observation: []f32,
    /// Physics steps lived at risk - before a failure, not in an aftermath - and the failures among them.
    steps_at_risk: u64,
    failures: u64,

    /// A character on `clips` with `options` (one environment; every end a cut - see this file's head). An aftermath
    /// of zero is allowed: the first loss then reaches the trainer as a terminated step, which it refuses. Memory:
    /// everything in `arena`, the caller's; `deinit` releases the fleet's own.
    pub fn init(
        arena: Allocator,
        model: *rbt.Model,
        body_names: []const []const u8,
        clips: []const *const dance.Clip,
        options: track_env.Options,
    ) !TrackCharacter {
        assertf(options.envs == 1, @src(), "TrackCharacter: one character per environment, asked for {d}", .{
            options.envs,
        });
        const clip_end_is_a_cut: bool = options.clip_end == .bootstrap;
        assertf(clip_end_is_a_cut, @src(), "TrackCharacter: a clip's end must be a cut (clip_end = .bootstrap)", .{});
        // `reset` draws a start inside every clip: a frame before it (for its velocity) and one after it.
        for (clips, 0..) |clip, clip_index| {
            assertf(clip.frame_count >= 3, @src(), "TrackCharacter: clip {d} has {d} frames, a start needs 3", .{
                clip_index,
                clip.frame_count,
            });
        }
        const environment: track_env.TrackEnv = try .init(arena, model, body_names, clips, options);
        const ended_observation: []f32 = try arena.alloc(f32, environment.n_obs);
        const character: TrackCharacter = .{
            .environment = environment,
            .outcome = .{.{}},
            .ended_observation = ended_observation,
            .steps_at_risk = 0,
            .failures = 0,
        };
        return character;
    }

    pub fn deinit(character: *TrackCharacter) void {
        character.environment.deinit();
    }

    /// The observation's width: DReCon's observation of this character's watched bodies.
    pub fn observationWidth(character: *const TrackCharacter) usize {
        return character.environment.n_obs;
    }

    /// The action's width: one per degree of freedom of DReCon's actuated joints.
    pub fn actionWidth(character: *const TrackCharacter) usize {
        return character.environment.subset.dofs;
    }

    /// A new episode where the trainer's stream says - a clip, and a frame inside it - with the controller's filter
    /// forgotten, its first observation into `observation`.
    pub fn reset(character: *TrackCharacter, rng: Rng, observation: []f32) void {
        const fleet: *track.Fleet = character.environment.fleet;
        const clip_count: u32 = @intCast(fleet.clips.len);
        const clip_index: usize = rng.bits(0) % clip_count;
        const clip: *const dance.Clip = fleet.clips[clip_index];
        // A start needs a frame before it (for its velocity) and one after it (for its next reference).
        const playable_frames: u32 = @intCast(clip.frame_count - 2);
        const start_frame: usize = 1 + rng.bits(1) % playable_frames;
        fleet.startAt(0, clip_index, start_frame);
        character.environment.controller.forget(0);
        character.environment.episode_steps[0] = 0;
        character.environment.observe(0, observation);
    }

    /// One decision: `action` held for the learner's interval through DReCon's filter; the decision's reward (the mean
    /// over its held steps up to the end); the observation that follows into `observation` - when the episode was
    /// cut, the TRUE state it ended in, not the fresh start that replaced it - and how the episode went on.
    pub fn step(
        character: *TrackCharacter,
        action: []const f32,
        observation: []f32,
    ) Agent.StepOutcome {
        character.environment.decide(action, &character.outcome, character.ended_observation);
        const outcome: track_env.Outcome = character.outcome[0];
        // At risk: the decision's own steps (up to its episode's end - after it, the hold drives a fresh start that
        // `reset` replaces) that were not in an aftermath. A failure on such a discarded step would need a start
        // that fails within the rest of one hold, which a start on the reference does not under Geno's rule.
        character.steps_at_risk += outcome.credited - outcome.aftermath_steps;
        character.failures += outcome.failures;
        const ending: Agent.EpisodeEnding = switch (outcome.end) {
            .none => .continues,
            .cut => .truncated,
            // Lost with no aftermath: a final state, which the trainer refuses (`Agent.EpisodeEnding.terminated`).
            .stop => .terminated,
        };
        if (outcome.end == .cut) {
            @memcpy(observation, character.ended_observation);
        } else {
            character.environment.observe(0, observation);
        }
        return .{ .reward = outcome.reward, .ending = ending };
    }
};

// The character keeps the agent's contract: checked when this file compiles, not when a trainer is first built.
comptime {
    Agent.requireEnvironment(TrackCharacter);
}

/// The agent's training loop over the dance's characters.
pub const DanceTrainer = Agent.Trainer(TrackCharacter);

/// Character `index`'s settings for a run of `learner`: Geno's task and DReCon's bodies, the learner's interval,
/// filter, action scale, episode length and aftermath, every end of an episode a cut (`clip_end = .bootstrap`), and a
/// fleet of its own seeded apart from the others'.
pub fn characterOptions(learner: robot_lab.TdmpcLearner, index: usize) track_env.Options {
    const options: track_env.Options = .{
        .envs = 1,
        .decimation = learner.decimation,
        .beta = learner.beta,
        .clip_end = .bootstrap,
        .max_episode_steps = learner.max_episode_steps,
        .action_scale = learner.action_scale,
        .task = geno.tracking_task,
        .bodies = geno.drecon_bodies,
        .aftermath_steps = learner.aftermath_steps,
        .seed = learner.seed + index,
    };
    return options;
}

/// The agent's training loop for a run of `learner` (`trainerFor`), on a schedule of the caller's - a test's short
/// seeding, or a resumed run's.
pub fn trainerWithSchedule(
    arena: Allocator,
    characters: []TrackCharacter,
    learner: robot_lab.TdmpcLearner,
    schedule: Agent.Schedule,
) !DanceTrainer {
    assertf(characters.len == learner.characters, @src(), "{d} characters for a run of {d}", .{
        characters.len,
        learner.characters,
    });
    const observation_width: usize = characters[0].observationWidth();
    const action_width: usize = characters[0].actionWidth();
    const config: Agent.Config = learner.agentConfig();
    // The run's seed is a u64; the agent's streams take a u32 - the low half, then the next for the loop's own.
    const network_seed: u32 = @truncate(learner.seed);
    const networks: Agent.Networks = try .init(arena, Rng.init(network_seed), observation_width, action_width, config);
    const episode_decisions: usize = learner.episodeDecisions();
    const replay_rows: usize = learner.replay_steps;
    return DanceTrainer.init(
        arena,
        characters,
        networks,
        observation_width,
        action_width,
        config,
        schedule,
        episode_decisions,
        replay_rows,
        Rng.init(network_seed +% 1),
    );
}

/// The agent's training loop for a run of `learner` over `characters` (one per `learner.characters`, made with
/// `characterOptions`): its networks from the run's seed, its configuration and schedule the learner's
/// (`robot_lab.TdmpcLearner.agentConfig`, `.schedule`), episodes of the learner's length in decisions, a replay of
/// `replay_steps` decisions per character. Memory: everything in `arena`, which should outlive the trainer - the
/// networks, the actor's and the learner's graphs and the replay all live there.
pub fn trainerFor(
    arena: Allocator,
    characters: []TrackCharacter,
    learner: robot_lab.TdmpcLearner,
) !DanceTrainer {
    return trainerWithSchedule(arena, characters, learner, learner.schedule());
}

// ---- Known answers, on Geno and the training lab's clip ----

const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const zrl = @import("zrl");
const report = @import("test_report.zig");
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const eql = std.mem.eql;

/// Geno and the training lab's clip (`examples/geno_ppo/dance.zclip`, the dance from 5 s for 20 s), as the trainer
/// builds them. The clip is read from the repository; a test skips when it is not there.
const GenoDance = struct {
    document: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    clip: dance.Clip,

    fn init(setup: *GenoDance, gpa: Allocator) !void {
        // whole-init-first: the whole struct first, every field named.
        setup.* = .{
            .document = undefined,
            .robot = undefined,
            .imported = undefined,
            .clip = undefined,
        };
        var threaded: Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io: Io = threaded.io();
        var clip_file: Io.File = Io.Dir.cwd().openFile(io, "examples/geno_ppo/dance.zclip", .{}) catch
            return error.SkipZigTest;
        defer clip_file.close(io);
        const clip_info: Io.File.Stat = try clip_file.stat(io);
        const clip_bytes: []u8 = try gpa.alloc(u8, clip_info.size);
        defer gpa.free(clip_bytes);
        _ = try clip_file.readPositionalAll(io, clip_bytes, 0);
        setup.document = try codecs.xml.parse(gpa, @embedFile("tests/fixtures/robot/geno.xml"), null);
        errdefer setup.document.deinit();
        setup.robot = try mjcf.readRobot(gpa, &setup.document);
        errdefer setup.robot.deinit();
        for (setup.robot.joints) |*joint| {
            if (joint.kind == .ball) {
                joint.armature = geno.standing_armature;
            }
        }
        setup.imported = try robot_mjcf.build(gpa, &setup.robot, geno.physicsOptions());
        errdefer setup.imported.deinit();
        setup.clip = try .fromBytes(gpa, clip_bytes);
    }

    fn deinit(setup: *GenoDance) void {
        setup.clip.deinit();
        setup.imported.deinit();
        setup.robot.deinit();
        setup.document.deinit();
    }
};

/// The tests' run: two characters, a small agent - every width 16, two dynamics heads, short plans and few
/// candidates, small batches - and an aftermath of 30 physics steps; the rest of the learner's settings as a run's.
fn testLearner(aftermath_steps: u32) robot_lab.TdmpcLearner {
    const learner: robot_lab.TdmpcLearner = .{
        .characters = 2,
        .aftermath_steps = aftermath_steps,
        .latent_width = 16,
        .hidden_width = 16,
        .dynamics_heads = 2,
        .acting_horizon = 3,
        .reanalyze_horizon = 3,
        .windows = 8,
        .replay_steps = 1024,
        .seed = 11,
    };
    return learner;
}

/// Seeding only - random actions in [-1, 1], no update - so a test watches the loop and the characters, not learning.
const seeding_only: Agent.Schedule = .{ .seed_frames = 100_000, .burst_updates = 0, .updates_per_frame = 0 };

/// `learner`'s characters on Geno's dance, in `arena`.
fn testCharacters(
    arena: Allocator,
    setup: *GenoDance,
    learner: robot_lab.TdmpcLearner,
) ![]TrackCharacter {
    const model: *rbt.Model = &setup.imported.model;
    const clips: []const *const dance.Clip = try arena.dupe(*const dance.Clip, &.{&setup.clip});
    const characters: []TrackCharacter = try arena.alloc(TrackCharacter, learner.characters);
    for (characters, 0..) |*character, index| {
        const options: track_env.Options = characterOptions(learner, index);
        character.* = try TrackCharacter.init(arena, model, setup.imported.names, clips, options);
    }
    return characters;
}

test "TrackCharacter: a lost character lives on through its aftermath, then is cut - its true last state kept" {
    // Two characters acting at random lose the reference within a second or two. With an aftermath of 30 physics
    // steps (15 decisions) every loss must reach the replay as an episode CUT - a row stored as done and never as
    // terminated - and the step after it must begin a new episode somewhere else: the cut row's successor (the state
    // the fall ended in) is not the next row's observation (the fresh start).
    const gpa: Allocator = testing_allocator;
    var setup: GenoDance = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const learner: robot_lab.TdmpcLearner = testLearner(30);
    const characters: []TrackCharacter = try testCharacters(arena, &setup, learner);
    defer for (characters) |*character| {
        character.deinit();
    };
    var trainer: DanceTrainer = try trainerWithSchedule(arena, characters, learner, seeding_only);
    const frames: usize = 180;
    for (0..frames) |_| {
        _ = try trainer.runFrame();
    }
    const done_column: usize = trainer.row.doneColumn();
    const terminated_column: usize = trainer.row.terminatedColumn();
    const next_observation_start: usize = trainer.row.nextObservationStart();
    const observation_width: usize = trainer.row.observation_width;
    var cut_rows: usize = 0;
    for (characters, 0..) |character, index| {
        const ring: zrl.ReplayBuffer(f32) = trainer.replay.environment_rings[index];
        for (0..frames - 1) |frame| {
            const row: []const f32 = ring.row(frame);
            try expectEqual(@as(f32, 0), row[terminated_column]);
            const is_cut: bool = row[done_column] == 1;
            if (!is_cut) {
                continue;
            }
            cut_rows += 1;
            const ended_in: []const f32 = row[next_observation_start..][0..observation_width];
            const fresh_start: []const f32 = ring.row(frame + 1)[0..observation_width];
            try expect(!eql(f32, ended_in, fresh_start));
        }
        // Every physics step but an aftermath's is at risk, and random actions fail often.
        const physics_steps: u64 = frames * character.environment.heldSteps();
        try expect(character.failures > 0);
        try expect(character.steps_at_risk < physics_steps);
    }
    try expect(cut_rows > 0);
}

test "TrackCharacter: with no aftermath a loss is a final state, and the trainer refuses it" {
    // CONTROL for the test above: the same characters with an aftermath of zero end their episode AT the loss, which
    // is a terminated step - the trainer stops at it with `error.TerminationNotModelled` instead of storing a fall
    // that its value would read as going on.
    const gpa: Allocator = testing_allocator;
    var setup: GenoDance = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const learner: robot_lab.TdmpcLearner = testLearner(0);
    const characters: []TrackCharacter = try testCharacters(arena, &setup, learner);
    defer for (characters) |*character| {
        character.deinit();
    };
    var trainer: DanceTrainer = try trainerWithSchedule(arena, characters, learner, seeding_only);
    var refused: bool = false;
    for (0..180) |_| {
        _ = trainer.runFrame() catch |err| {
            try expectEqual(error.TerminationNotModelled, err);
            refused = true;
            break;
        };
    }
    try expect(refused);
}

test "TrackCharacter: the same seeds run the same dance, bit for bit" {
    // Every start comes from the trainer's reset stream and every action from its acting stream, so two trainers on
    // the same seeds store the same rows to the bit.
    const gpa: Allocator = testing_allocator;
    var setup: GenoDance = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const learner: robot_lab.TdmpcLearner = testLearner(30);
    const first_characters: []TrackCharacter = try testCharacters(arena, &setup, learner);
    const second_characters: []TrackCharacter = try testCharacters(arena, &setup, learner);
    defer for (first_characters, second_characters) |*first, *second| {
        first.deinit();
        second.deinit();
    };
    var first_trainer: DanceTrainer = try trainerWithSchedule(arena, first_characters, learner, seeding_only);
    var second_trainer: DanceTrainer = try trainerWithSchedule(arena, second_characters, learner, seeding_only);
    const frames: usize = 60;
    for (0..frames) |_| {
        _ = try first_trainer.runFrame();
        _ = try second_trainer.runFrame();
    }
    for (0..first_characters.len) |index| {
        const first_ring: zrl.ReplayBuffer(f32) = first_trainer.replay.environment_rings[index];
        const second_ring: zrl.ReplayBuffer(f32) = second_trainer.replay.environment_rings[index];
        for (0..frames) |frame| {
            try expect(eql(f32, first_ring.row(frame), second_ring.row(frame)));
        }
    }
}

test "the agent's parts train on the dance: a few updates, every loss finite" {
    // The quick form of the test below, run by default: the same small agent and characters, 12 decisions of random
    // actions, one pretraining update, then the planner with one update after each of 8 decisions - about 9 updates.
    // The claim kept is that every part, assembled on Geno, trains: each world-model loss and each policy loss finite,
    // and the policy updated once pretraining is over. Whether the world model's loss FALLS takes the long run.
    const gpa: Allocator = testing_allocator;
    var setup: GenoDance = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const learner: robot_lab.TdmpcLearner = testLearner(30);
    const characters: []TrackCharacter = try testCharacters(arena, &setup, learner);
    defer for (characters) |*character| {
        character.deinit();
    };
    const quick_schedule: Agent.Schedule = .{ .seed_frames = 12, .burst_updates = 1, .updates_per_frame = 1 };
    var trainer: DanceTrainer = try trainerWithSchedule(arena, characters, learner, quick_schedule);
    const frames: usize = 20;
    var policy_updates: usize = 0;
    for (0..frames) |_| {
        const frame_plan: Agent.Schedule.Frame = try trainer.runFrame();
        if (frame_plan.updates == 0) {
            continue;
        }
        const update_report: Agent.LearnerReport = trainer.last_report.?;
        const world: Agent.WorldModelReport = update_report.world_model;
        const world_losses = [_]f32{ world.consistency, world.reward, world.value, world.total, world.gradient_norm };
        for (world_losses) |loss| {
            try expect(isFinite(loss));
        }
        if (update_report.policy) |policy| {
            try expect(isFinite(policy.total));
            policy_updates += 1;
        }
    }
    try expect(policy_updates > 0);
}

test "the agent learns on the dance: its losses finite, the world model's falling" {
    // A small agent (every width 16, two dynamics heads) on two characters: 60 decisions of random actions, one
    // pretraining update, then the planner with two updates after every decision - 300 updates in all, reanalyze
    // among them. Not mastery - the claim is that the parts, assembled on Geno, train: every loss stays finite, the
    // policy learns once pretraining is over, and the world model's loss ends below where it began. A SLOW TEST
    // (`-Dslow-tests`): nearly three minutes on one core, most of the robot family's time - the test above keeps
    // its quick part by default.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: GenoDance = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const learner: robot_lab.TdmpcLearner = testLearner(30);
    const characters: []TrackCharacter = try testCharacters(arena, &setup, learner);
    defer for (characters) |*character| {
        character.deinit();
    };
    const short_schedule: Agent.Schedule = .{ .seed_frames = 60, .burst_updates = 1, .updates_per_frame = 2 };
    var trainer: DanceTrainer = try trainerWithSchedule(arena, characters, learner, short_schedule);
    const frames: usize = 210;
    var first_world_loss: ?f32 = null;
    var last_world_losses: [10]f32 = @splat(0);
    var policy_updates: usize = 0;
    for (0..frames) |frame| {
        const frame_plan: Agent.Schedule.Frame = try trainer.runFrame();
        if (frame_plan.updates == 0) {
            continue;
        }
        const update_report: Agent.LearnerReport = trainer.last_report.?;
        const world: Agent.WorldModelReport = update_report.world_model;
        const world_losses = [_]f32{ world.consistency, world.reward, world.value, world.total, world.gradient_norm };
        for (world_losses) |loss| {
            try expect(isFinite(loss));
        }
        if (update_report.policy) |policy| {
            try expect(isFinite(policy.total));
            policy_updates += 1;
        }
        if (first_world_loss == null) {
            first_world_loss = world.total;
        }
        last_world_losses[frame % last_world_losses.len] = world.total;
    }
    var last_mean: f32 = 0;
    for (last_world_losses) |loss| {
        last_mean += loss / float(last_world_losses.len);
    }
    report.print("\n  the agent on the dance: world-model loss {d:.4} at the first update, {d:.4} over the last ten " ++
        "frames; {d} policy updates; {d} updates in all\n", .{
        first_world_loss.?,
        last_mean,
        policy_updates,
        trainer.update_index,
    });
    try expect(policy_updates > 0);
    try expect(last_mean < first_world_loss.?);
}
