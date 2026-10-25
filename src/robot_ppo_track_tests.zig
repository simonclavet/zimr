//! robot_ppo_track's tests, kept OUT of the zimr module.
//!
//! The same rule as the GPU kit's other proofs (see `robot_tests.zig`): these tests import
//! `gpu/zn_mlp.zig` by path, and a page that trains on the GPU imports that same file as a module of
//! its own - which Zig refuses, a file belonging to two modules. So the trainer lives in the zimr
//! module where pages can reach it, and its proofs live here, reachable only from the test root.
//!
//! Training chunks run from here too: `zig build test-robot_ppo_track_tests -Dtrain-chunk
//! -Dtest-filter="robot_ppo_track: train chunk - the get-up"`.

const std = @import("std");
const report = @import("test_report.zig");
const zm = @import("zm");
const float64 = zm.float64;
const vec = zm.vec;
const rbt = @import("robot.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const ppo_track = @import("robot_ppo_track.zig");
const track_env = @import("robot_track_env.zig");
const lab = @import("robot_lab.zig");
const robot_policy = @import("robot_policy.zig");
const sac_track = @import("robot_sac_track.zig");
const compute_host = @import("compute_host.zig");
const codecs = @import("codecs.zig");
const mjcf = @import("mjcf.zig");
const robot_mjcf = @import("robot_mjcf.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");
/// Geno, the robot built from its character - for the model-free baseline on it (S2b).
const geno = @import("robot_geno.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const sliceAsBytes = std.mem.sliceAsBytes;
const ArrayList = std.ArrayList;
const Host = compute_host.Compute(zn_mlp);
const Trainer = ppo_track.Trainer;
const Options = ppo_track.Options;
const Stats = ppo_track.Stats;
const getup_first = ppo_track.getup_first;
const walk_first = ppo_track.walk_first;
const window_frames = ppo_track.window_frames;
const float = zm.float;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectApproxEqRel = std.testing.expectApproxEqRel;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const bufPrint = std.fmt.bufPrint;

const flex2_xml: []const u8 = @embedFile("tests/fixtures/robot/humanoid_flex2.xml");

fn readAll(gpa: Allocator, io: Io, path: []const u8) ![]u8 {
    var file: Io.File = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const info: Io.File.Stat = try file.stat(io);
    const bytes: []u8 = try gpa.alloc(u8, info.size);
    errdefer gpa.free(bytes);
    _ = try file.readPositionalAll(io, bytes, 0);
    return bytes;
}

/// A clip retargeted onto this model and filtered.
fn loadClip(
    gpa: Allocator,
    io: Io,
    m: *rbt.Model,
    names: []const []const u8,
    path: []const u8,
    seconds: f32,
) !dance.Clip {
    const capture_bytes: []u8 = try readAll(gpa, io, path);
    defer gpa.free(capture_bytes);
    const rest_bytes: []u8 = try readAll(gpa, io, "assets/lafan1/Geno_stance.bvh");
    defer gpa.free(rest_bytes);
    var capture: codecs.bvh.Data = try codecs.bvh.parse(gpa, capture_bytes, null);
    defer capture.deinit();
    var rest: codecs.bvh.Data = try codecs.bvh.parse(gpa, rest_bytes, null);
    defer rest.deinit();
    var raw: dance.Clip = try dance.retargetClip(gpa, m, names, &capture, &rest, .{ .seconds = seconds });
    defer raw.deinit();
    return raw.smoothed(m, 5.0);
}

/// Everything a training run needs, built once.
const Setup = struct {
    doc: codecs.xml.Document,
    robot: mjcf.Robot,
    imported: robot_mjcf.Imported,
    clip: dance.Clip,

    fn init(
        setup: *Setup,
        gpa: Allocator,
        io: Io,
        path: []const u8,
        first: usize,
    ) !void {
        // whole-init-first: the whole struct first - defaults applied, every field named.
        setup.* = .{
            .doc = undefined,
            .robot = undefined,
            .imported = undefined,
            .clip = undefined,
        };
        setup.doc = try codecs.xml.parse(gpa, flex2_xml, null);
        errdefer setup.doc.deinit();
        setup.robot = try mjcf.readRobot(gpa, &setup.doc);
        errdefer setup.robot.deinit();
        var options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
        options.solver.algorithm = .newton;
        setup.imported = try robot_mjcf.build(gpa, &setup.robot, options);
        errdefer setup.imported.deinit();
        const m: *rbt.Model = &setup.imported.model;
        var whole: dance.Clip = try loadClip(gpa, io, m, setup.imported.names, path, 18.0);
        defer whole.deinit();
        setup.clip = try whole.window(first, window_frames);
        errdefer setup.clip.deinit();
        var scratch: rbt.Data = try .init(gpa, m);
        defer scratch.deinit();
        _ = try track.liftPerFrame(gpa, m, &setup.clip, &scratch, 3.0);
    }

    fn deinit(setup: *Setup) void {
        setup.clip.deinit();
        setup.imported.deinit();
        setup.robot.deinit();
        setup.doc.deinit();
    }
};

test "robot_sac_track: every row of SAC's replay is exactly the task's transition" {
    // SAC learns from each stored transition many times over, so the mapping from a decision to (observation, action,
    // reward, next observation, done) is held against a TWIN environment driven by the actions the replay recorded:
    // each row's observation is the twin's before the decision, its reward the twin's credited one, done is set
    // exactly on a stop, and the next observation is the twin's terminal capture on a cut and its next decision's
    // observation otherwise. A 30-step cap and bootstrapped clip ends make cuts; a full radian per unit of action,
    // during SAC's uniform warm-up (no updates yet), knocks characters over - stops.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const envs: usize = 4;
    const decisions: usize = 40;
    const env_options: track_env.Options = .{
        .envs = envs,
        .max_episode_steps = 30,
        .clip_end = .bootstrap,
        .action_scale = 1.0,
    };
    const sac: *sac_track.SacTrack = try .init(gpa, m, setup.imported.names, &clips, .{
        .env = env_options,
        .sac = .{ .warmup = 100_000, .replay_capacity = 1024 },
    });
    defer sac.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var twin: track_env.TrackEnv = try .init(arena, m, setup.imported.names, &clips, env_options);
    defer twin.deinit();
    const n_obs: usize = twin.n_obs;
    const dofs: usize = twin.subset.dofs;
    const width: usize = 2 * n_obs + dofs + 2;
    const before: []f32 = try arena.alloc(f32, envs * n_obs);
    const actions: []f32 = try arena.alloc(f32, envs * dofs);
    const outcomes: []track_env.Outcome = try arena.alloc(track_env.Outcome, envs);
    const terminal: []f32 = try arena.alloc(f32, envs * n_obs);
    const after: []f32 = try arena.alloc(f32, n_obs);
    var cuts: usize = 0;
    var stops: usize = 0;
    for (0..decisions) |t| {
        for (0..envs) |e| {
            twin.observe(e, before[e * n_obs ..][0..n_obs]);
        }
        _ = try sac.step();
        // This decision's rows (the ring has room for all of them, so row k sits at k * width).
        const rows: []const f32 = sac.agent.replay.data[t * envs * width ..][0 .. envs * width];
        for (0..envs) |e| {
            @memcpy(actions[e * dofs ..][0..dofs], rows[e * width + n_obs ..][0..dofs]);
        }
        twin.decide(actions, outcomes, terminal);
        for (0..envs) |e| {
            const row: []const f32 = rows[e * width ..][0..width];
            try expect(eql(f32, row[0..n_obs], before[e * n_obs ..][0..n_obs]));
            try expectEqual(outcomes[e].reward, row[n_obs + dofs]);
            // The row's last column is the bootstrap's discount: gamma, or zero on a stop.
            const discount: f32 = if (outcomes[e].end == .stop) 0.0 else sac.agent.options.gamma;
            try expectEqual(discount, row[2 * n_obs + dofs + 1]);
            const next: []const f32 = row[n_obs + dofs + 1 ..][0..n_obs];
            switch (outcomes[e].end) {
                .cut => {
                    try expect(eql(f32, next, terminal[e * n_obs ..][0..n_obs]));
                    cuts += 1;
                },
                .none => {
                    twin.observe(e, after);
                    try expect(eql(f32, next, after));
                },
                .stop => stops += 1,
            }
        }
    }
    try expect(cuts > 0 and stops > 0);
}

fn expectSacLearns(n_step: usize, normalize: bool) !void {
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const sac: *sac_track.SacTrack = try .init(gpa, m, setup.imported.names, &clips, .{
        .env = .{ .envs = 4 },
        .sac = .{
            .hidden = 32,
            .batch = 32,
            .warmup = 64,
            .replay_capacity = 4096,
            .normalize_observations = normalize,
        },
        .n_step = n_step,
    });
    defer sac.deinit();
    const first_weights: []f32 = try gpa.dupe(f32, sac.agent.actor.l1.w.data);
    defer gpa.free(first_weights);
    for (0..30) |_| {
        _ = try sac.step();
    }
    try expect(sac.agent.updates > 0);
    try expect(!eql(f32, first_weights, sac.agent.actor.l1.w.data));
    const critic_loss: f32 = sac.agent.critic_graph.valueOf(sac.agent.critic_loss).data[0];
    try expect(zm.isFinite(critic_loss));
}

test "robot_sac_track: SAC learns on the dance without breaking" {
    // Not a benchmark - the plumbing under load: past a short warm-up every decision triggers an update, the actor's
    // weights move, and the critic's loss stays finite. One-step rows, TD4's five-step ones, and those normalised at
    // sample time.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    try expectSacLearns(1, false);
    try expectSacLearns(5, false);
    try expectSacLearns(5, true);
}

test "robot_track_env: PPO through TrackEnv matches a bare TrackEnv, decision for decision" {
    // PPO's bookkeeping AROUND the environment, held against the environment alone: two identical fleets - one inside
    // a PPO trainer, one inside a bare TrackEnv - driven by the same actions (the ones PPO draws) must give the same
    // observations in PPO's batch, the same credited rewards, the same ends, and for every episode cut short the same
    // bootstrap: PPO's critic on the bare TrackEnv's terminal observation is exactly what PPO recorded. (It was also
    // TrackEnv's first known answer, when it was held against PPO's own, older copy of this logic.)
    // A 40-step cap and the clip's end as a cut make cut ends happen inside the test; exploration
    // at 1.6 pushes actions past the clamp and knocks characters over, so stops happen too.
    const build_options = @import("build_options");
    const slow: bool = comptime @hasDecl(build_options, "slow_tests") and build_options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const envs: usize = 4;
    const horizon: usize = 48;
    const options: Options = .{
        .envs = envs,
        .horizon = horizon,
        .max_episode_steps = 40,
        .clip_end = .bootstrap,
        .initial_log_std = 0.5,
    };
    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, options);
    defer trainer.deinit();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var env: track_env.TrackEnv = try .init(arena_state.allocator(), m, setup.imported.names, &clips, .{
        .envs = envs,
        .decimation = options.decimation,
        .beta = options.beta,
        .clip_end = options.clip_end,
        .max_episode_steps = options.max_episode_steps,
        .action_scale = options.action_scale,
        .task = options.task,
        .bodies = options.bodies,
        .seed = options.seed,
    });
    defer env.deinit();
    const n_obs: usize = env.n_obs;
    const dofs: usize = env.subset.dofs;
    try expect(n_obs == trainer.n_obs);
    const arena: Allocator = arena_state.allocator();
    const seen: []f32 = try arena.alloc(f32, n_obs);
    const outcomes: []track_env.Outcome = try arena.alloc(track_env.Outcome, envs);
    const terminal: []f32 = try arena.alloc(f32, envs * n_obs);
    var cuts: usize = 0;
    var stops: usize = 0;
    for (0..horizon) |t| {
        // What each character looks like before the decision - the environment's own look, taken first.
        const before: []f32 = try arena.alloc(f32, envs * n_obs);
        for (0..envs) |e| {
            env.observe(e, before[e * n_obs ..][0..n_obs]);
        }
        _ = trainer.collect(1);
        env.decide(trainer.raw[t * envs * dofs ..][0 .. envs * dofs], outcomes, terminal);
        for (0..envs) |e| {
            const at: usize = t * envs + e;
            try expect(eql(f32, trainer.observations[at * n_obs ..][0..n_obs], before[e * n_obs ..][0..n_obs]));
            try expectEqual(trainer.rewards[at], outcomes[e].reward);
            try expect(trainer.ends[at] == outcomes[e].end);
            try expect(trainer.dones[at] == (outcomes[e].ended > 0));
            switch (outcomes[e].end) {
                .cut => {
                    @memcpy(seen, terminal[e * n_obs ..][0..n_obs]);
                    try expectEqual(trainer.bootstrap[at], trainer.ppo.value(seen));
                    cuts += 1;
                },
                .stop => stops += 1,
                .none => {},
            }
        }
    }
    report.print("\n  TrackEnv against PPO's collection: {d} decisions x {d} characters, {d} cut, {d} stopped\n", .{
        horizon,
        envs,
        cuts,
        stops,
    });
    try expect(cuts > 0);
}

test "robot_ppo_track: an untrained policy is the servo, and the wiring says so" {
    // THE WIRING'S KNOWN ANSWER. A policy with no exploration whose output layer starts near zero
    // asks for almost nothing, so the trainer's rollout must look like the servo alone: episodes of
    // about the same length. A wiring mistake - an observation from the wrong environment, a reward
    // credited to the wrong decision, a filter never reset - shows up here as episodes that are
    // much shorter than doing nothing at all.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};

    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, .{
        .envs = 8,
        .horizon = 32,
        .initial_log_std = -20.0, // no exploration: the policy's mean, which starts near zero
    });
    defer trainer.deinit();
    const first: Stats = trainer.iterate();

    // The same fleet with the action left at exactly zero, for the same number of physics steps.
    const servo: *track.Fleet = try .init(gpa, m, &clips, .{ .envs = 8, .capacity = 16, .seed = 1 });
    defer servo.deinit();
    const zero: []f32 = try gpa.alloc(f32, 8 * track.actionSize(m));
    defer gpa.free(zero);
    @memset(zero, 0.0);
    for (0..32 * 2) |_| {
        _ = servo.step(zero);
    }
    const servo_mean: f32 = float(8 * 32 * 2) / float(@max(servo.episodes, 1));
    const trainer_mean: f32 = float(8 * 32 * 2) / float(@max(first.episodes, 1));
    report.print("\n  wiring: untrained policy {d:.1} frames an episode ({d} ended, reward {d:.3}); " ++
        "servo alone {d:.1} ({d} ended)\n", .{
        trainer_mean,
        first.episodes,
        first.mean_reward,
        servo_mean,
        servo.episodes,
    });
    try expect(first.mean_reward > 0.3 and first.mean_reward <= 1.0);
    try expect(trainer_mean > 0.7 * servo_mean and trainer_mean < 1.4 * servo_mean);
    // And a second iteration runs on the updated weights without anything going non-finite.
    const second: Stats = trainer.iterate();
    try expect(zm.isFinite(second.mean_reward));

    // THE CONTROL. Matching the servo exactly is also what a policy DISCONNECTED from the character
    // would do, so the same trainer with real exploration must track measurably worse - which it
    // can only do if its actions reach the joints.
    const noisy: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, .{
        .envs = 8,
        .horizon = 32,
        .initial_log_std = 0.5, // exp(0.5) = 1.6: far more than a policy would ever want
    });
    defer noisy.deinit();
    const shaken: Stats = noisy.iterate();
    report.print("  control: with exploration at 1.6, reward {d:.3} against {d:.3} untrained\n", .{
        shaken.mean_reward,
        first.mean_reward,
    });
    try expect(shaken.mean_reward < first.mean_reward - 0.01);
}

test "robot_ppo_track: a show lives, a physics step at a time, exactly what evaluate judges" {
    // THE KNOWN ANSWER. On the judge's seed, with as many characters, a show stepped `decisions x decimation`
    // physics steps acts as `evaluate` does over `decisions` decisions - the same starts, the same mean actions,
    // the same filter - so it must count the same exposure and the same failures, exactly.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    var host: Host = .initCpu();
    const characters: u32 = 2;
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, .{
        .envs = characters,
        .horizon = 8,
    });
    defer trainer.deinit();
    // Some training first, so that the policy is not the servo and its actions matter.
    _ = trainer.iterate();
    const decisions: usize = 40;
    const judged: Stats = try trainer.evaluate(decisions, false);

    var show: Trainer(zn_mlp).Show = try trainer.startShow(gpa, characters, ppo_track.evaluation_seed);
    defer Trainer(zn_mlp).endShow(gpa, &show);
    const physics_steps: usize = decisions * @max(trainer.options.decimation, 1);
    for (0..physics_steps) |_| {
        trainer.stepShow(&show);
    }
    try expectEqual(judged.exposure, show.exposure);
    try expectEqual(judged.failures, show.failures);

    // THE CONTROL. Another seed starts the characters elsewhere: the same policy lives a different show.
    var elsewhere: Trainer(zn_mlp).Show = try trainer.startShow(gpa, characters, ppo_track.evaluation_seed + 1);
    defer Trainer(zn_mlp).endShow(gpa, &elsewhere);
    for (0..physics_steps) |_| {
        trainer.stepShow(&elsewhere);
    }
    const first_character_frames_differ: bool = show.fleet.frame[0] != elsewhere.fleet.frame[0];
    try expect(first_character_frames_differ or show.failures != elsewhere.failures);
}

test "robot_ppo_track: a checkpoint carries a run on exactly" {
    // Save after some training, load into a trainer built from a DIFFERENT seed, and the two must
    // be the same learner: the same weights to the bit, the same optimiser state, the same count of
    // experience - and so the same answer to the same question.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
    var setup: Setup = undefined;
    setup.init(gpa, io, "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const path: []const u8 = "train/test_roundtrip.ckpt";
    // lint:off catch-suppression: best-effort cleanup - a file already gone must not fail the test
    defer Io.Dir.cwd().deleteFile(io, path) catch {};

    var host_a: Host = .initCpu();
    const original: *Trainer(zn_mlp) = try .init(gpa, &host_a, m, setup.imported.names, &clips, .{
        .envs = 4,
        .horizon = 64,
    });
    defer original.deinit();
    _ = original.iterate();
    try original.save(io, path);

    var host_b: Host = .initCpu();
    const resumed: *Trainer(zn_mlp) = try .init(gpa, &host_b, m, setup.imported.names, &clips, .{
        .envs = 4,
        .horizon = 64,
        .seed = 99,
    });
    defer resumed.deinit();
    try expect(try resumed.load(io, path));

    for (original.ppo.cpu_params, resumed.ppo.cpu_params) |a, b| {
        try expect(a == b);
    }
    try expect(original.ppo.adam_step == resumed.ppo.adam_step and original.ppo.adam_step > 0);
    try expect(original.decisions == resumed.decisions and original.iterations == resumed.iterations);
    // (The device-side moments are checked against the exported BYTES in the test below: on the
    // CPU twin two hosts share one set of buffers, so comparing host A's with host B's would
    // compare a buffer with itself - which is what this test used to do, and pass.)
    const probe: []f32 = try gpa.alloc(f32, original.n_obs);
    defer gpa.free(probe);
    for (probe, 0..) |*x, k| {
        x.* = @sin(float(k));
    }
    try expect(original.ppo.value(probe) == resumed.ppo.value(probe));
    // And a file that is not a checkpoint says so, rather than being read as one.
    try expect(!(try resumed.load(io, "train/does_not_exist.ckpt")));
}

test "robot_ppo_track: a sliced batch, and weights that travel as bytes" {
    // What a phone page depends on, in one place. It collects a few decisions a frame rather than
    // a whole batch at once - which must change NOTHING about what is learned. And its weights
    // leave as a downloaded file and come back as an uploaded one - which must carry the run on
    // exactly, and refuse, by name, a file that is not weights or is weights for another network.
    //
    // ONE LIVE TRAINER AT A TIME, on purpose. The kit's CPU twin keeps its buffers in module
    // globals - that is how the same kernels compile to WGSL, where storage buffers ARE globals -
    // so two hosts in one process share one set of buffers. Interleaving two trainers here would
    // have each overwrite the other's weights; comparing two hosts' device buffers would compare a
    // buffer with itself. Each trainer below starts after the last has finished, and device-side
    // numbers are compared against the exported BYTES, which cannot alias anything.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const small: Options = .{ .envs = 4, .horizon = 64 };
    var host: Host = .initCpu();

    // Whole batches first, and what they learned.
    const whole_params: []f32 = blk: {
        const whole: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, small);
        defer whole.deinit();
        for (0..2) |_| {
            _ = whole.iterate();
        }
        break :blk try gpa.dupe(f32, whole.ppo.cpu_params);
    };
    defer gpa.free(whole_params);

    // Then the same run collected three decisions at a time: the same weights, to the bit.
    const sliced: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, small);
    defer sliced.deinit();
    for (0..2) |_| {
        while (!sliced.collect(3)) {}
        _ = sliced.learn();
    }
    for (whole_params, sliced.ppo.cpu_params) |a, b| {
        try expect(a == b);
    }

    // Out as bytes. Keep what the sliced trainer acts with - its own copy, not the shared buffers.
    const bytes: []u8 = try sliced.exportWeights(gpa);
    defer gpa.free(bytes);
    const acting: []f32 = try gpa.dupe(f32, sliced.ppo.cpu_params);
    defer gpa.free(acting);
    const probe: []f32 = try gpa.alloc(f32, sliced.n_obs);
    defer gpa.free(probe);
    for (probe, 0..) |*x, k| {
        x.* = @cos(float(k) * 0.37);
    }
    const mean_saved: []f32 = try gpa.alloc(f32, sliced.env.subset.dofs);
    defer gpa.free(mean_saved);
    sliced.ppo.actMean(probe, mean_saved);
    const value_saved: f32 = sliced.ppo.value(probe);

    // Into a trainer from another seed - whose own initialisation overwrites the shared buffers
    // first, so everything it ends up with came through the bytes.
    var other_options: Options = small;
    other_options.seed = 77;
    const other: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, other_options);
    defer other.deinit();
    try other.importWeights(bytes);
    for (acting, other.ppo.cpu_params) |a, b| {
        try expect(a == b);
    }
    const mean_loaded: []f32 = try gpa.alloc(f32, other.env.subset.dofs);
    defer gpa.free(mean_loaded);
    other.ppo.actMean(probe, mean_loaded);
    for (mean_saved, mean_loaded) |a, b| {
        try expect(a == b);
    }
    try expect(value_saved == other.ppo.value(probe));
    try expect(other.iterations == 2 and other.ppo.adam_step == sliced.ppo.adam_step);
    // The optimiser's moments made it to the device, as the file had them.
    const count: usize = other.ppo.param_count;
    const header_size: usize = bytes.len - 3 * count * @sizeOf(f32);
    const moment_bytes: []const u8 = bytes[header_size + count * @sizeOf(f32) ..][0 .. count * @sizeOf(f32)];
    const device_moment: []const f32 = host.readLatest(.adam_m).?;
    try expect(eql(u8, moment_bytes, sliceAsBytes(device_moment[0..count])));

    // Refused, by name: bytes that are not weights, and weights for a network of another width.
    try expectError(error.NotAWeightsFile, other.importWeights("not weights at all"));
    try expectError(error.NotAWeightsFile, other.importWeights(bytes[0 .. bytes.len - 4]));
    var wide_options: Options = small;
    wide_options.hidden = 32;
    const wide: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, wide_options);
    defer wide.deinit();
    try expectError(error.WeightsShape, wide.importWeights(bytes));

    // The normaliser travels with the weights - a network trained on normalised inputs is a
    // different network without its statistics - and a file and a trainer that disagree about
    // normalising are refused, not half-read.
    var normed_options: Options = small;
    normed_options.normalize = true;
    const normed_bytes: []u8 = blk: {
        const normed: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, normed_options);
        defer normed.deinit();
        _ = normed.iterate();
        try expect(normed.observation_normalizer.count > 0);
        break :blk try normed.exportWeights(gpa);
    };
    defer gpa.free(normed_bytes);
    normed_options.seed = 5;
    const reloaded: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, normed_options);
    defer reloaded.deinit();
    try reloaded.importWeights(normed_bytes);
    try expect(reloaded.observation_normalizer.count == 4 * 64);
    var spread: f64 = 0.0;
    for (reloaded.observation_normalizer.m2) |m2| {
        spread += m2;
    }
    try expect(spread > 0.0);
    try expectError(error.WeightsShape, other.importWeights(normed_bytes));
}

/// One chunk of a long training run: resume, learn for `seconds`, save, and append the learning
/// curve to a CSV beside the checkpoint so the run's history survives every restart.
fn trainChunk(
    clip_path: []const u8,
    first: usize,
    name: []const u8,
    seconds: f32,
) !void {
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
    var setup: Setup = undefined;
    try setup.init(gpa, io, clip_path, first);
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, .{});
    defer trainer.deinit();

    var checkpoint_buffer: [256]u8 = undefined;
    const checkpoint: []const u8 = try bufPrint(&checkpoint_buffer, "train/{s}.ckpt", .{name});
    var curve_buffer: [256]u8 = undefined;
    const curve_path: []const u8 = try bufPrint(&curve_buffer, "train/{s}.csv", .{name});
    const resumed: bool = try trainer.load(io, checkpoint);

    var curve: ArrayList(u8) = .empty;
    defer curve.deinit(gpa);
    if (Io.Dir.cwd().openFile(io, curve_path, .{})) |file| {
        defer file.close(io);
        const info: Io.File.Stat = try file.stat(io);
        try curve.resize(gpa, info.size);
        _ = try file.readPositionalAll(io, curve.items, 0);
    } else |_| {
        try curve.appendSlice(gpa, "iteration,decisions,steps,mean_reward,episodes,mean_episode\n");
    }

    const started: Io.Timestamp = Io.Clock.now(.awake, io);
    var last: Stats = undefined;
    var ran: usize = 0;
    while (true) {
        const elapsed: i96 = Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
        if (float(@divTrunc(elapsed, 1_000_000)) > seconds * 1000.0) {
            break;
        }
        last = trainer.iterate();
        ran += 1;
        var line: [160]u8 = undefined;
        try curve.appendSlice(gpa, try bufPrint(&line, "{d},{d},{d},{d:.4},{d},{d:.2}\n", .{
            trainer.iterations,
            last.decisions,
            last.steps,
            last.mean_reward,
            last.episodes,
            last.mean_episode,
        }));
    }
    try trainer.save(io, checkpoint);
    // Judged, not trained: the mean action against the servo alone, same length of experience.
    const judged: Stats = try trainer.evaluate(300, false);
    const servo: Stats = try trainer.evaluate(300, true);
    // lint:off debug-print: the chunk's report; training chunks only run on the host, on request
    std.debug.print("\n  {s} JUDGED (mean action, 300 decisions x {d} envs): {d:.1} frames an episode, " ++
        "{d} ended, reward {d:.3} | servo alone: {d:.1} frames, {d} ended, reward {d:.3}\n", .{
        name,
        trainer.options.envs,
        judged.mean_episode,
        judged.episodes,
        judged.mean_reward,
        servo.mean_episode,
        servo.episodes,
        servo.mean_reward,
    });
    {
        const file: Io.File = try Io.Dir.cwd().createFile(io, curve_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, curve.items);
    }
    // lint:off debug-print: the chunk's report; training chunks only run on the host, on request
    std.debug.print("\n  {s}: {s}, {d} iterations this chunk, {d} in all ({d} physics steps); " ++
        "last: reward {d:.3}, {d} episodes ended, {d:.1} frames each\n", .{
        name,
        if (resumed) "resumed" else "started fresh",
        ran,
        trainer.iterations,
        trainer.steps,
        last.mean_reward,
        last.episodes,
        last.mean_episode,
    });
}

test "robot_ppo_track: train chunk - the get-up" {
    const options = @import("build_options");
    const enabled: bool = comptime @hasDecl(options, "train_chunk") and options.train_chunk;
    if (!enabled) {
        return error.SkipZigTest;
    }
    try trainChunk("assets/lafan1/fallAndGetUp2_subject2.bvh", getup_first, "ppo_getup", 180.0);
}

test "robot_ppo_track: train chunk - the walk control" {
    const options = @import("build_options");
    const enabled: bool = comptime @hasDecl(options, "train_chunk") and options.train_chunk;
    if (!enabled) {
        return error.SkipZigTest;
    }
    try trainChunk("assets/lafan1/walk1_subject2.bvh", walk_first, "ppo_walk", 180.0);
}

test "robot_ppo_track: Geno holds the T-pose - the model-free baseline (S2b)" {
    // Model-free learning on Geno, with no world model anywhere: the existing PPO trainer, unchanged, on the
    // held T-pose, with Geno's servo and floor. If early training cannot trust a world model, something
    // model-free must carry it - this is the baseline any such learner (CrossQ, DroQ) has to beat, and the
    // check that model-free learning can hold Geno up at all. Judged over 1,200 steps, not 300 - a judge
    // that counts falls needs a long window to resolve anything.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    // A MEASUREMENT: it asserts nothing but that its numbers are numbers, so it runs when its table is asked for -
    // `-Dslow-tests -Dtest-report` - and not on every slow run, which would print nothing. See
    // `report.requested`.
    if (!report.requested()) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io: Io = threaded.io();
    const model_text: []u8 = readAll(gpa, io, geno.model_fixture_path) catch return error.SkipZigTest;
    defer gpa.free(model_text);
    const bind_text: []u8 = try readAll(gpa, io, "src/tests/fixtures/robot/geno_bind.bvh");
    defer gpa.free(bind_text);
    const stance_text: []u8 = try readAll(gpa, io, "src/tests/fixtures/robot/geno_stance.bvh");
    defer gpa.free(stance_text);
    var doc: codecs.xml.Document = try codecs.xml.parse(gpa, model_text, null);
    defer doc.deinit();
    var robot: mjcf.Robot = try mjcf.readRobot(gpa, &doc);
    defer robot.deinit();
    var build_options: rbt.Options = .{ .timestep = 1.0 / 60.0, .gravity = vec(0, 0, -9.81), .max_contacts = 256 };
    build_options.solver.algorithm = .newton;
    var imported: robot_mjcf.Imported = try robot_mjcf.build(gpa, &robot, build_options);
    defer imported.deinit();
    var bind: geno.Posed = try geno.readPose(gpa, bind_text);
    defer bind.deinit(gpa);
    var stance: codecs.bvh.Data = try codecs.bvh.parse(gpa, stance_text, null);
    defer stance.deinit();
    var held: dance.Clip = try geno.heldClip(gpa, &imported, bind, stance, 10.0, 1.0 / 60.0);
    defer held.deinit();
    const clips = [_]*const dance.Clip{&held};
    var host: Host = .initCpu();
    // Geno's whole task (plan T1) - this test used to set only the servo, floor and bodies, and so ran
    // without the action scale, the floor rest, the gated reward and the task's failure rule.
    const geno_options: Options = .{
        .task = geno.tracking_task,
        .bodies = geno.drecon_bodies,
        .action_scale = geno.student_scale,
    };
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, &imported.model, imported.names, &clips, geno_options);
    defer trainer.deinit();
    const budget_seconds: f32 = 100.0;
    const started: Io.Timestamp = Io.Clock.now(.awake, io);
    var iterations: usize = 0;
    var last: Stats = undefined;
    while (true) {
        const elapsed: i96 = Io.Clock.now(.awake, io).nanoseconds - started.nanoseconds;
        if (float(@divTrunc(elapsed, 1_000_000)) > budget_seconds * 1000.0) {
            break;
        }
        last = trainer.iterate();
        iterations += 1;
    }
    const judged: Stats = try trainer.evaluate(1200, false);
    const servo: Stats = try trainer.evaluate(1200, true);
    report.print("\n  PPO on Geno's T-pose, {d:.0} s ({d} iterations, {d} steps): " ++
        "judged {d:.1} frames an episode " ++
        "({d} ended) | servo alone {d:.1} frames ({d} ended)\n", .{
        budget_seconds,
        iterations,
        last.steps,
        judged.mean_episode,
        judged.episodes,
        servo.mean_episode,
        servo.episodes,
    });
    try expect(judged.mean_episode == judged.mean_episode);
}

const demo_cap: usize = 60;

/// D5 step 3's budget: a teacher recording every `demo_stride` frames, up to `demo_cap` frames each; the clone's
/// minibatches; and how many decisions the judge watches (per character).
/// 10x the data (Sep 25): a start every 5 frames (was 20), each recorded clean AND perturbed.
const demo_stride: usize = 5;

const judged_decisions: usize = 600;

const clone_updates: usize = 2000;

test "robot_ppo_track: D5 step 3 - PPO's policy cloned from the teacher, judged in the real simulator" {
    // D5.3 step 3, end to end: the teacher (sharp MPPI on DReCon's clock and filter) dances across the task's clip
    // and every decision it makes becomes a demonstration - DReCon's observation (the trainer's OWN fleet supplies
    // the reference states, so it is the trainer's observation by construction) and the raw action / 1.2. Then
    // `Trainer.clone` - the normaliser set from the demonstrations, PPO's own policy chain with the mean-square-error
    // gradient - and the trainer's own `evaluate` judges the clone against the servo alone.
    const options = @import("build_options");
    if (!(comptime @hasDecl(options, "slow_tests") and options.slow_tests)) {
        return error.SkipZigTest;
    }
    // A MEASUREMENT IN ALL BUT NAME: its one check is that the clone's training loss fell, which gradient descent
    // all but guarantees, so it runs with its table - `-Dslow-tests -Dtest-report` - and not on every slow run.
    // To revisit: a real check (the clone outlasting the servo) would earn it its place back. See `report.requested`.
    if (!report.requested()) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const task: *geno.GenoTask = (try geno.GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse
        return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clips = [_]*const dance.Clip{&task.clip};
    var host: Host = .initCpu();
    // Geno's whole task (plan T1): this trainer used to be judged WITHOUT the gravity gate and with the old
    // limits, because it spelled the task out by hand and predated both.
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, task.imported.names, &clips, .{
        .task = geno.tracking_task,
        .bodies = geno.drecon_bodies,
        .action_scale = geno.student_scale,
        .envs = 8,
        .normalize = true,
        .initial_log_std = -1.2,
        .max_episode_steps = 700,
    });
    defer trainer.deinit();

    var run: geno.ServoRun = undefined;
    try run.init(gpa, &task.imported, geno.floor_friction);
    defer run.deinit();
    var planner: geno.Planner = try .init(gpa, &run, &task.imported, geno.d5_teacher);
    defer planner.deinit();
    var recorder: geno.DemoRecorder = try .init(gpa, &task.imported, &planner);
    defer recorder.deinit();
    var demo: geno.Demo = recorder.newDemo();
    defer demo.deinit(gpa);
    var kept: usize = 0;
    var starts: usize = 0;
    var first_rows: ArrayList(usize) = .empty;
    defer first_rows.deinit(gpa);
    var from: usize = 0;
    // Every start twice: clean, and perturbed at D5.5's calibrated level (the teacher then demonstrates RECOVERIES).
    while (from + demo_cap < task.clip.frame_count) : (from += demo_stride) {
        for ([_]track.StartNoise{ .{}, geno.d5_start_noise }) |noise| {
            try first_rows.append(gpa, demo.rows());
            const seed: u64 = 1000 + starts;
            kept += try recorder.record(&planner, trainer.env.fleet, &task.clip, from, demo_cap, noise, seed, &demo);
            starts += 1;
        }
    }
    try first_rows.append(gpa, demo.rows());
    // HELD OUT: every fifth start's demonstrations are never cloned on - its error separates "the observation
    // cannot predict the teacher" (held-out error far above training's: lookahead is missing) from "it can, and
    // the clone drifts off the teacher's states" (held-out near training's: distribution shift - DAgger).
    var train_obs: ArrayList(f32) = .empty;
    defer train_obs.deinit(gpa);
    var train_labels: ArrayList(f32) = .empty;
    defer train_labels.deinit(gpa);
    var held_obs: ArrayList(f32) = .empty;
    defer held_obs.deinit(gpa);
    var held_labels: ArrayList(f32) = .empty;
    defer held_labels.deinit(gpa);
    for (0..starts) |start| {
        const lo: usize = first_rows.items[start];
        const hi: usize = first_rows.items[start + 1];
        const held: bool = start % 5 == 4;
        const obs_into: *ArrayList(f32) = if (held) &held_obs else &train_obs;
        const labels_into: *ArrayList(f32) = if (held) &held_labels else &train_labels;
        try obs_into.appendSlice(gpa, demo.observations.items[lo * demo.width .. hi * demo.width]);
        try labels_into.appendSlice(gpa, demo.labels.items[lo * demo.dofs .. hi * demo.dofs]);
    }
    const dofs: usize = demo.dofs;
    // Two trivial predictors on the held-out rows, for scale: always zero, and the TRAINING labels' mean.
    const train_mean: []f64 = try gpa.alloc(f64, dofs);
    defer gpa.free(train_mean);
    @memset(train_mean, 0.0);
    const train_rows: usize = train_labels.items.len / dofs;
    for (0..train_rows) |row| {
        for (train_mean, train_labels.items[row * dofs ..][0..dofs]) |*mean, value| {
            mean.* += value;
        }
    }
    for (train_mean) |*mean| {
        mean.* /= float64(train_rows);
    }
    var zero_error: f64 = 0.0;
    var mean_error: f64 = 0.0;
    const held_rows: usize = held_labels.items.len / dofs;
    for (0..held_rows) |row| {
        for (held_labels.items[row * dofs ..][0..dofs], train_mean) |value, mean| {
            zero_error += value * value;
            mean_error += (value - mean) * (value - mean);
        }
    }
    zero_error /= float64(held_rows * dofs);
    mean_error /= float64(held_rows * dofs);

    const servo: Stats = try trainer.evaluate(judged_decisions, true);
    // A LEARNING CURVE: held-out error at cumulative checkpoints - early checkpoints beating the constants while
    // later ones do not is overfitting.
    const checkpoints = [_]usize{ 25, 50, 100, 200, 500, 1000, 2000 };
    var curve: [checkpoints.len]f32 = undefined;
    var done_updates: usize = 0;
    var result: Trainer(zn_mlp).CloneResult = .{ .before = 0.0, .after = 0.0 };
    for (checkpoints, 0..) |checkpoint, c| {
        const chunk: Trainer(zn_mlp).CloneResult = try trainer.clone(
            train_obs.items,
            train_labels.items,
            checkpoint - done_updates,
            1 + c,
        );
        if (c == 0) {
            result.before = chunk.before;
        }
        result.after = chunk.after;
        done_updates = checkpoint;
        curve[c] = trainer.cloneError(held_obs.items, held_labels.items);
    }
    const held_error: f32 = curve[checkpoints.len - 1];
    // THE NORMALISER on 660 rows: dimensions whose spread is near its floor, and how often a normalised input is
    // pinned at +-5 - on training rows against held-out ones.
    var narrow: usize = 0;
    const count: f64 = @max(trainer.observation_normalizer.count, 1);
    for (trainer.observation_normalizer.m2) |m2| {
        if (@sqrt(m2 / count) < 1.0e-3) {
            narrow += 1;
        }
    }
    var pinned: [2]usize = .{ 0, 0 };
    var inputs: [2]usize = .{ 0, 0 };
    for ([_][]const f32{ train_obs.items, held_obs.items }, 0..) |rows_of, which| {
        const width: usize = demo.width;
        var row: usize = 0;
        while (row * width < rows_of.len) : (row += 1) {
            const scratch: []f32 = trainer.obs_scratch[0..width];
            @memcpy(scratch, rows_of[row * width ..][0..width]);
            trainer.normalizeObservation(scratch);
            for (scratch) |z| {
                if (@abs(z) >= 5.0) {
                    pinned[which] += 1;
                }
            }
            inputs[which] += width;
        }
    }
    const cloned: Stats = try trainer.evaluate(judged_decisions, false);
    const servo_mttf: f64 = float64(servo.exposure) / float64(@max(servo.failures, 1));
    const clone_mttf: f64 = float64(cloned.exposure) / float64(@max(cloned.failures, 1));
    report.print("\n  D5 step 3: the teacher kept up {d} frames over {d} starts -> {d} demonstrations;\n" ++
        "  clone error {d:.4} -> {d:.4} over {d} minibatches;\n" ++
        "  judged ({d} decisions x 8): servo {d} failures, MTTF {d:.0} steps, reward {d:.3} | " ++
        "clone {d} failures, MTTF {d:.0} steps, reward {d:.3}\n", .{
        kept,
        starts,
        demo.rows(),
        result.before,
        result.after,
        clone_updates,
        judged_decisions,
        servo.failures,
        servo_mttf,
        servo.mean_reward,
        cloned.failures,
        clone_mttf,
        cloned.mean_reward,
    });
    report.print("  held out ({d} of {d} starts, {d} rows): clone error {d:.4} (training {d:.4}); " ++
        "always-zero {d:.4}, training mean {d:.4}\n", .{
        starts / 5,
        starts,
        held_rows,
        held_error,
        result.after,
        zero_error,
        mean_error,
    });
    report.print("  held-out error after", .{});
    for (checkpoints, curve) |checkpoint, value| {
        report.print(" {d}: {d:.4}", .{ checkpoint, value });
    }
    report.print("\n  normaliser: {d} of {d} inputs spread under 1e-3; pinned at +-5: training {d:.2}%, held out " ++
        "{d:.2}%\n", .{
        narrow,
        demo.width,
        100.0 * float64(pinned[0]) / float64(@max(inputs[0], 1)),
        100.0 * float64(pinned[1]) / float64(@max(inputs[1], 1)),
    });
    try expect(result.after < result.before);
}

test "robot_ppo_track: GAE - an episode CUT short is bootstrapped from where it ended; a lost one is not" {
    // Known answer: reward 1 a step, gamma 0.9, and a critic that is RIGHT - every value the worth of an endless
    // stream of 1s, 1 / (1 - 0.9) = 10 - so every TD error is zero. An episode cut short at its last step and
    // bootstrapped from the state it ended in (worth 10 too) must give advantages of exactly zero. Counted as a
    // death - the rule every end followed until Sep 26 - its last step's error is 1 - 10 = -9, leaking backward.
    const horizon: usize = 5;
    const rewards = [_]f32{ 1, 1, 1, 1, 1 };
    const values = [_]f32{ 10, 10, 10, 10, 10, 10 };
    const bootstrap = [_]f32{ 0, 0, 0, 0, 10 };
    var advantages: [5]f32 = undefined;
    var returns: [5]f32 = undefined;
    const cut = [_]ppo_track.EndKind{ .none, .none, .none, .none, .cut };
    ppo_track.gaeColumn(&rewards, &values, &cut, &bootstrap, horizon, 1, 0, 0.9, 0.95, &advantages, &returns);
    for (advantages, returns) |a, r| {
        try expect(@abs(a) < 1.0e-5 and @abs(r - 10.0) < 1.0e-5);
    }
    const lost = [_]ppo_track.EndKind{ .none, .none, .none, .none, .stop };
    ppo_track.gaeColumn(&rewards, &values, &lost, &bootstrap, horizon, 1, 0, 0.9, 0.95, &advantages, &returns);
    try expect(@abs(advantages[4] + 9.0) < 1.0e-5);
    try expect(@abs(advantages[3] - 0.9 * 0.95 * -9.0) < 1.0e-4);
    // The lambda-chain breaks at an end: a cut at step 2, then a new episode whose step 3 earns 2 - its surprise
    // must not reach back across the boundary.
    const rewards2 = [_]f32{ 1, 1, 1, 2, 1 };
    const boundary = [_]ppo_track.EndKind{ .none, .none, .cut, .none, .none };
    const bootstrap2 = [_]f32{ 0, 0, 10, 0, 0 };
    ppo_track.gaeColumn(&rewards2, &values, &boundary, &bootstrap2, horizon, 1, 0, 0.9, 0.95, &advantages, &returns);
    try expect(@abs(advantages[3] - 1.0) < 1.0e-5);
    try expect(@abs(advantages[2]) < 1.0e-5 and @abs(advantages[0]) < 1.0e-5);
}

test "robot_ppo_track: episodes CUT by the step cap are bootstrapped from where they ended (end to end)" {
    // The GAE known answer checks the arithmetic; this checks the plumbing: a real fleet and a real trainer with a
    // step cap of 6 physics steps (3 decisions), so every episode is cut short inside one batch. The decisions
    // that ended must say CUT and carry a finite, non-zero value of the state they ended in - valued from the
    // fleet's capture, before the restart - and `learn` must run on them.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const task: *geno.GenoTask = (try geno.GenoTask.init(gpa, threaded.io(), .dance_5_15)) orelse
        return error.SkipZigTest;
    defer task.deinit();
    const m: *rbt.Model = &task.imported.model;
    const clips = [_]*const dance.Clip{&task.clip};
    var host: Host = .initCpu();
    // Under Geno's WHOLE task since plan T1 (the gated reward and the task's failure rule included - it used to
    // run with the old limits). The task's rule has no grace and COULD end an episode on its first step; it does
    // not here because every episode starts on the reference's own pose, rested on the floor, and six steps are
    // nowhere near its limits (1 m, 90 degrees, 0.4 m relative height). So episodes still end by the cap - the
    // thing under test - and the counts below would say so if that ever changed.
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, task.imported.names, &clips, .{
        .task = geno.tracking_task,
        .bodies = geno.drecon_bodies,
        .action_scale = geno.student_scale,
        .envs = 2,
        .horizon = 8,
        .epochs = 1,
        .minibatch = 8,
        .normalize = true,
        .max_episode_steps = 6,
    });
    defer trainer.deinit();
    // The known answer for plan T1 on the PPO path: the task the trainer was given is the one its FLEET runs,
    // whole - the trainer hands it over in one assignment instead of copying it field by field. (Equal here
    // because `assist_start` is 0: the trainer writes its root assist into the fleet's `task.gains.assist`, so
    // with assist on, the TRAINING fleet's task differs by that one field on purpose; the judge's never does.)
    try expect(std.meta.eql(trainer.env.fleet.options.task, geno.tracking_task));
    try expect(trainer.env.fleet.options.action_scale == geno.student_scale);
    while (!trainer.collect(4)) {}
    var cut: usize = 0;
    var stopped: usize = 0;
    for (trainer.ends, trainer.bootstrap) |end, value| {
        switch (end) {
            .none => {},
            .stop => stopped += 1,
            .cut => {
                cut += 1;
                try expect(value == value and value != 0.0);
            },
        }
    }
    report.print("\n  cut episodes: {d} decisions ended CUT (bootstrapped), {d} STOPPED, of {d}\n", .{
        cut,
        stopped,
        trainer.ends.len,
    });
    try expect(cut >= 2);
    _ = trainer.learn();
}

test "PolicyShow: a PPO trainer's policy, shown without its trainer, lives what Trainer.Show lives - bit for bit" {
    // The lab's watch and judge show any learner's policy file one way (`lab.PolicyShow`); PPO's own show
    // (`Trainer.Show`) acts through the trainer. Same seed, same characters, same 600 physics steps: every decision's
    // actions, the exposure and the failures must be the same. A trainer that has collected a few decisions first,
    // so its normaliser has statistics to normalise by. CONTROL: one weight changed, the actions differ.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const clips = [_]*const dance.Clip{&setup.clip};
    const options: Options = .{ .envs = 2, .horizon = 8, .normalize = true };
    var host: Host = .initCpu();
    const trainer: *Trainer(zn_mlp) = try .init(gpa, &host, m, setup.imported.names, &clips, options);
    defer trainer.deinit();
    _ = trainer.collect(8);
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var policy: lab.GenoPolicy = try lab.policyOfPpo(arena, .{
        .kit_parameters = trainer.ppo.cpu_params,
        .actor_layer_offsets = trainer.ppo.p_off,
        .observation_size = trainer.n_obs,
        .hidden_width = trainer.options.hidden,
        .action_size = trainer.env.subset.dofs,
        .observation_normalizer = if (trainer.options.normalize) trainer.observation_normalizer else null,
        .action_limit = trainer.env.options.action_limit,
        .action_scale = trainer.env.options.action_scale,
        .filter_beta = trainer.env.options.beta,
    });
    const characters: usize = 2;
    var show: Trainer(zn_mlp).Show = try trainer.startShow(gpa, characters, ppo_track.evaluation_seed);
    defer Trainer(zn_mlp).endShow(gpa, &show);
    // PPO's show caps episodes at the fleet's own default, 600 physics steps: the policy show is given the same.
    var policy_show: lab.PolicyShow = try .start(arena, m, setup.imported.names, &clips, &policy, .{
        .character_count = characters,
        .seed = ppo_track.evaluation_seed,
        .decimation = options.decimation,
        .max_episode_steps = 600,
        .task = options.task,
        .bodies = options.bodies,
    });
    defer policy_show.end();
    for (0..600) |_| {
        trainer.stepShow(&show);
        policy_show.step(&policy);
        try expectEqualSlices(f32, show.actions, policy_show.actions);
    }
    try expectEqual(show.exposure, policy_show.exposure_steps);
    try expectEqual(show.failures, policy_show.failure_count);
    // The control: two new shows on the same seed, the second with one weight of the last layer changed - after one
    // step, their actions differ.
    const control_settings: lab.PolicyShowSettings = .{
        .character_count = characters,
        .seed = ppo_track.evaluation_seed,
        .decimation = options.decimation,
        .task = options.task,
        .bodies = options.bodies,
    };
    var unchanged_show: lab.PolicyShow = try .start(arena, m, setup.imported.names, &clips, &policy, control_settings);
    defer unchanged_show.end();
    unchanged_show.step(&policy);
    const last_layer: lab.PolicyLayer = policy.layers[policy.layers.len - 1];
    last_layer.weights_and_biases[last_layer.weights_and_biases.len - 1] += 0.5;
    var changed_show: lab.PolicyShow = try .start(arena, m, setup.imported.names, &clips, &policy, control_settings);
    defer changed_show.end();
    changed_show.step(&policy);
    try expect(!eql(f32, unchanged_show.actions, changed_show.actions));
}

/// A policy of two layers whose every weight and bias is zero, sized `observation_size` -> `hidden` -> `action_size`
/// and taking raw observations: its mean action is zero, whatever it observes. Memory: in `arena`.
fn zeroPolicy(
    arena: Allocator,
    observation_size: usize,
    hidden: usize,
    action_size: usize,
    options: Options,
) !lab.GenoPolicy {
    const widths: []u32 = try arena.alloc(u32, 3);
    widths[0] = @intCast(observation_size);
    widths[1] = @intCast(hidden);
    widths[2] = @intCast(action_size);
    const layers: []lab.PolicyLayer = try arena.alloc(lab.PolicyLayer, 2);
    const first_parameters: []f32 = try arena.alloc(f32, lab.PolicyLayer.parameterCount(observation_size, hidden));
    const second_parameters: []f32 = try arena.alloc(f32, lab.PolicyLayer.parameterCount(hidden, action_size));
    @memset(first_parameters, 0.0);
    @memset(second_parameters, 0.0);
    layers[0] = .{ .activation = .tanh, .weights_and_biases = first_parameters };
    layers[1] = .{ .activation = .none, .weights_and_biases = second_parameters };
    const policy: lab.GenoPolicy = .{
        .widths = widths,
        .layers = layers,
        .normalization = null,
        .action_limit = 1.0,
        .action_scale = options.action_scale,
        .filter_beta = options.beta,
    };
    return policy;
}

test "judgePolicy: zero weights are judged as the servo alone, twice the same; a policy at its limit is not the servo" {
    // The judge is the measuring instrument every comparison of runs rests on, so before its verdicts are trusted, its
    // controls. A policy whose every weight and bias is zero acts with zero offsets - the servo alone - and must be
    // judged exactly as the judge judges the servo with no policy at all: this holds the actor's whole path (the
    // decision, the filter, the hold, the restart) to the judge's own. The same policy judged twice must be judged
    // the same: nothing is random. And a policy that pushes every joint to its limit must be judged otherwise than the
    // servo: the instrument can tell controllers apart.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const names: []const []const u8 = setup.imported.names;
    const options: Options = .{};
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    // The policy's sizes, as DReCon's bodies on this robot give them.
    const bodies: robot_policy.Bodies = options.bodies;
    const subset: robot_policy.Subset = try robot_policy.subsetFor(arena, m, names, bodies.watched, bodies.actuated);
    const observation_size: usize = robot_policy.observationSize(subset);
    const policy: lab.GenoPolicy = try zeroPolicy(arena, observation_size, 8, subset.dofs, options);
    const starts: []usize = try track.evenStarts(arena, &setup.clip, 30);
    const settings: lab.PolicyJudgeSettings = .{
        .starts = starts,
        .decimation = options.decimation,
        .task = options.task,
        .bodies = bodies,
    };
    const servo: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, null, settings);
    const zero: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, &policy, settings);
    try expectEqual(servo.starts, zero.starts);
    try expectEqual(servo.failures, zero.failures);
    try expectEqual(servo.reached_end, zero.reached_end);
    try expectEqual(servo.watched_steps, zero.watched_steps);
    try expectEqual(servo.reward_sum, zero.reward_sum);
    const again: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, &policy, settings);
    try expectEqual(zero.watched_steps, again.watched_steps);
    try expectEqual(zero.reward_sum, again.reward_sum);
    // At its limit: the last layer's biases all one, so every joint's action is +1 whatever the policy observes.
    const last_layer: lab.PolicyLayer = policy.layers[1];
    const biases_start: usize = policy.widths[1] * policy.widths[2];
    @memset(last_layer.weights_and_biases[biases_start..], 1.0);
    const pushed: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, &policy, settings);
    const judged_otherwise: bool = pushed.watched_steps != servo.watched_steps or
        pushed.failures != servo.failures or
        pushed.reward_sum != servo.reward_sum;
    try expect(judged_otherwise);
}

test "judgePolicy: a judgement's sums are its starts' own - each start judged alone adds up to all judged together" {
    // The standard errors are worked from sums the judge keeps as each start's first episode ends (`track.Judgement`).
    // Each start runs on a world of its own, so judging the starts one at a time must give the same episodes: the
    // sums of the single judgements are the judgement of them all. A start that reached the clip's end tracked a
    // share of exactly one - the check that the steps available from a start are counted right.
    const gpa: Allocator = testing_allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var setup: Setup = undefined;
    setup.init(gpa, threaded.io(), "assets/lafan1/walk1_subject2.bvh", walk_first) catch return error.SkipZigTest;
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const names: []const []const u8 = setup.imported.names;
    const options: Options = .{};
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const starts: []usize = try track.evenStarts(arena, &setup.clip, 30);
    const together: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, null, .{
        .starts = starts,
        .task = options.task,
        .bodies = options.bodies,
    });
    var watched_steps: usize = 0;
    var failures: usize = 0;
    var tracked_steps_squares: f64 = 0;
    var failed_starts_steps: f64 = 0;
    var tracked_share_sum: f64 = 0;
    var tracked_share_squares: f64 = 0;
    for (starts) |start| {
        const alone: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, null, .{
            .starts = &.{start},
            .task = options.task,
            .bodies = options.bodies,
        });
        if (alone.reached_end == 1) {
            try expectEqual(@as(f64, 1.0), alone.tracked_share_sum);
        }
        watched_steps += alone.watched_steps;
        failures += alone.failures;
        tracked_steps_squares += alone.tracked_steps_squares;
        failed_starts_steps += alone.failed_starts_steps;
        tracked_share_sum += alone.tracked_share_sum;
        tracked_share_squares += alone.tracked_share_squares;
    }
    try expectEqual(watched_steps, together.watched_steps);
    try expectEqual(failures, together.failures);
    try expectApproxEqRel(tracked_steps_squares, together.tracked_steps_squares, 1.0e-12);
    try expectApproxEqRel(failed_starts_steps, together.failed_starts_steps, 1.0e-12);
    try expectApproxEqRel(tracked_share_sum, together.tracked_share_sum, 1.0e-12);
    try expectApproxEqRel(tracked_share_squares, together.tracked_share_squares, 1.0e-12);
}
