//! robot_track_resident_tests - the resident learner's tests, in a file of their own.
//!
//! WHY THEY LIVE HERE. A test needs a CONCRETE kernel module, which means importing
//! `gpu/zn_mlp.zig` by path - and every page builds that same file as its own module. A file that
//! imports it therefore cannot belong to the `zimr` module a page also imports, or Zig rightly
//! refuses: one file, two modules. Keeping the tests apart is what lets the learner itself be part of
//! the engine, which is how `robot_ppo_track` and its tests are arranged too.

const zm = @import("zm");
const gapInUnits = zm.gapInUnits;
const float = zm.float;
const float64 = zm.float64;
const clamp = zm.clamp;
const inf = zm.inf;
const nan = zm.nan;
const isFinite = zm.isFinite;
const std = @import("std");
const zrl = @import("zrl");
const report = @import("test_report.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const kit_mod = @import("robot_latent_kit.zig");
const kit_mlp = @import("kit_mlp.zig");
const latent = @import("robot_latent.zig");
const bmpc_kit = @import("robot_bmpc_kit.zig");
const zn = @import("zn");
/// The fleet on the baked get-up clip is a test-only helper, so it lives with the kit's tests.
const kit_tests = @import("robot_latent_kit_tests.zig");
const compute_host = @import("compute_host.zig");
const resident = @import("robot_track_resident.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");
const lab = @import("robot_lab.zig");
const rbt = @import("robot");
const robot_policy = @import("robot_policy.zig");

const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;
const expect = std.testing.expect;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const asBytes = std.mem.asBytes;
const sliceAsBytes = std.mem.sliceAsBytes;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectApproxEqRel = std.testing.expectApproxEqRel;
const expectEqualSlices = std.testing.expectEqualSlices;
const ArenaAllocator = std.heap.ArenaAllocator;
const startsWith = std.mem.startsWith;
const Resident = resident.Resident;

test "robot_track_resident: the loop runs, the world model learns, and the simulation acts from the mirror" {
    // A few rounds of the real loop on a real fleet: simulate and record, train the world model, train
    // the policy, refresh the mirror. What it checks is that the pieces fit - the ring's bookkeeping,
    // the slots, the layouts - and that the loop does something: the world model's loss falls, and the
    // weights the simulation acts from follow the GPU's. How WELL it learns is a budget question, and
    // the step-for-step comparisons against the CPU reference answer the correctness one.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
    });
    defer learner.deinit();
    host.element_count = @max(learner.data.end, learner.kit.param_count + learner.kit.policy_count);

    // Enough rounds that windows exist and both networks have been updated a few times.
    var first_loss: f32 = 0.0;
    var last_loss: f32 = 0.0;
    const before_policy: []f32 = try gpa.dupe(f32, learner.host.mirror);
    defer gpa.free(before_policy);
    for (0..12) |round| {
        learner.simulateAndTrain();
        if (learner.world_updates > 0) {
            learner.kit.loss();
            const value: f32 = (host.readLatest(.loss) orelse return error.NoReadback)[0];
            if (first_loss == 0.0) {
                first_loss = value;
            }
            last_loss = value;
        }
        _ = round;
    }
    report.print("\n  resident loop, 12 rounds: world loss {d:.3} -> {d:.3}, {d} world and {d} policy updates\n", .{
        first_loss,
        last_loss,
        learner.world_updates,
        learner.policy_updates,
    });
    try expect(learner.world_updates == 12 and learner.policy_updates == 12);
    try expect(last_loss < first_loss);
    // The mirror followed the GPU: the policy has moved since it was seeded.
    var moved: f32 = 0.0;
    for (learner.host.mirror, before_policy) |now, then| {
        moved = @max(moved, gapInUnits(now, then, 1.0));
    }
    try expect(moved > 0.0);
}

test "robot_track_resident: the normed world model learns alone first, then the policy through it - all finite" {
    // The loop with the world model in the normed form (`Options.world_form`): two hidden layers of linear, layer
    // norm and SiLU, its last layer starting at zero, so it begins predicting "nothing changes". For its first
    // updates (`world_alone_updates`) the policy takes no rollout update and acts as it was seeded; from then on it
    // learns through the world model, one update a round. Every weight stays finite all along, and the world model's
    // loss on each of its batches alone - before that batch's update, as the log reports it - is reported: the first
    // is the seeded model's, which predicts no change at all.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    const alone_updates: u32 = 3;
    const rounds: u32 = 6;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .world_form = .normed_silu,
        .world_hidden_layers = 2,
        .world_alone_updates = alone_updates,
    });
    defer learner.deinit();
    const learner_parameters: u32 = learner.kit.param_count + learner.kit.policy_count;
    host.element_count = @max(learner.data.end, learner_parameters);

    // Seeded: the world model's last layer - weights and bias - exactly zero.
    const world: kit_mod.NormedWorld(zn_mlp) = learner.kit.normed_world orelse return error.DenseWorldModel;
    const last_layer: kit_mlp.KitLayer = world.layers[world.layer_count - 1];
    const seeded_params: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    for (seeded_params[last_layer.weights_offset..][0..last_layer.parameterFloats()]) |weight| {
        try expectEqual(@as(f32, 0), weight);
    }
    const seeded_policy: []f32 = try gpa.dupe(f32, learner.host.mirror);
    defer gpa.free(seeded_policy);

    var losses_alone: [alone_updates - 1]f32 = undefined;
    for (0..rounds) |round| {
        learner.simulateAndTrain();
        const world_model_alone: bool = learner.world_updates < alone_updates;
        if (world_model_alone) {
            // The world model's loss on the batch its update drew, from the rollout before the update - its last
            // pass in the kit.
            learner.kit.loss();
            losses_alone[round] = (host.readLatest(.loss) orelse return error.NoReadback)[0];
            try expectEqual(@as(u32, 0), learner.policy_updates);
            try expectEqualSlices(f32, seeded_policy, learner.host.mirror);
        }
        const params: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        var nonfinite_parameters: u32 = 0;
        for (params[0..learner_parameters]) |parameter| {
            nonfinite_parameters += @intFromBool(!isFinite(parameter));
        }
        try expectEqual(@as(u32, 0), nonfinite_parameters);
    }
    report.print("\n  the normed world model, {d} rounds - its loss before each update alone:", .{rounds});
    for (losses_alone) |loss| {
        report.print(" {d:.4}", .{loss});
    }
    report.print("; {d} world and {d} policy updates\n", .{ learner.world_updates, learner.policy_updates });
    // One world model update a round; the policy's from the round its world model reached its updates alone.
    try expectEqual(rounds, learner.world_updates);
    try expectEqual(rounds - (alone_updates - 1), learner.policy_updates);
    var moved: f32 = 0.0;
    for (learner.host.mirror, seeded_policy) |now, then| {
        moved = @max(moved, gapInUnits(now, then, 1.0));
    }
    try expect(moved > 0.0);
}

test "robot_track_resident: a window starts from the action given before it, across a push, or from rest" {
    // The windows' starting actions (`lat_gather_start_actions`): real windows gathered from a fleet that has run a
    // few rounds with pushes - episodes ended among them - and each row's starting action read back, against the CPU
    // learner's rule read off the replay itself (robot_latent's `Learner.appliedBefore`): REST on an episode's first
    // step; otherwise the action recorded one step earlier - ACROSS A PUSH TOO, which ends a segment but never an
    // episode, so what the controller applies carries straight through it. Bit for bit: the same numbers, copied.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    // A push every 12 steps: segments of 12 records, so windows of 8 steps fit inside them, and some start exactly
    // on the record just after a push.
    fleet.options.pushes.every = 12;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .filter = 0.5,
    });
    defer learner.deinit();
    host.element_count = @max(host.element_count, learner.data.end);
    for (0..4) |_| {
        learner.simulateAndTrain();
    }
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const actions: usize = learner.host.raw.len;
    const replay: track.Replay = fleet.replay;
    var continuing_rows: usize = 0;
    var opening_rows: usize = 0;
    var rows_just_after_a_push: usize = 0;
    for (0..12) |_| {
        try expect(learner.drawWindows(0, .anywhere));
        learner.data.gather(kit, 0);
        const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
        for (learner.starts, 0..) |start, row| {
            const gathered: []const f32 = acts[kit.start_actions_at + row * actions ..][0..actions];
            // The rule, from the replay's own records - not from the flag the drawer staged.
            const episode_step: u32 = replay.episodeStepAt(start.env, start.index) orelse return error.NotARolloutStep;
            const opens_episode: bool = episode_step == 0;
            if (opens_episode) {
                opening_rows += 1;
                for (gathered) |number| {
                    try expectEqual(@as(f32, 0.0), number);
                }
                continue;
            }
            continuing_rows += 1;
            const given_before: []const f32 = replay.actionAt(start.env, start.index - 1);
            try expectEqualSlices(f32, given_before, gathered);
            const first_segment: u32 = replay.segmentAt(start.env, start.index);
            const segment_before: u32 = replay.segmentAt(start.env, start.index - 1);
            if (first_segment != segment_before) {
                rows_just_after_a_push += 1;
            }
        }
    }
    // Every case was met: the test checked the gather across a push, after an episode's start and from rest.
    try expect(continuing_rows > 0);
    try expect(opening_rows > 0);
    try expect(rows_just_after_a_push > 0);
    report.print("\n  starting actions: {d} windows continuing their episode ({d} just after a push), " ++
        "{d} opening it\n", .{ continuing_rows, rows_just_after_a_push, opening_rows });
}

test "robot_track_resident: the mirror acts as the GPU's policy would" {
    // The one thing the mirror must get right. The simulation chooses its actions from a host copy of
    // the policy's weights; training assumes those are the actions the policy chose. If the two ever
    // disagree, the loop collects data under one policy and improves another, and nothing downstream
    // would say so - the losses would look perfectly healthy.
    //
    // So: gather real windows, run the kit's ACTING rollout with the noise turned off, then put each
    // row's goal and state - read back from the very rows the GPU used - through the mirror, and
    // compare the actions. They are not bitwise equal and should not be expected to be: the mirror sums
    // the goal and state into one pre-activation as it goes, while the GPU does the two blocks one
    // after the other. Same arithmetic, different order.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
    });
    defer learner.deinit();
    host.element_count = @max(host.element_count, learner.data.end);
    // A few rounds, so the comparison is on TRAINED weights rather than the seeded ones - a policy of
    // near-zero outputs would agree with anything.
    for (0..4) |_| {
        learner.simulateAndTrain();
    }
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const actions: usize = learner.host.raw.len;
    try expect(learner.drawWindows(0, .anywhere));
    learner.data.gather(kit, 0);
    // No exploration noise: the mirror's forward has none either, and this compares the policies, not
    // their noise.
    const sigma: f32 = kit.sigma;
    kit.sigma = 0.0;
    kit.forward();
    kit.sigma = sigma;
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    var worst: f32 = 0.0;
    var largest: f32 = 0.0;
    for (0..kit.rows) |row| {
        // The row the GPU read: its goal, then its state. Straight out of the buffer, so a disagreement
        // can only come from the weights or the arithmetic - never from the inputs.
        const at: usize = kit.blockX(0) + row * kit.width;
        @memcpy(learner.host.goal, acts[at..][0..kit.lead]);
        @memcpy(learner.host.z, acts[at + kit.lead ..][0..f]);
        // And the action applied before the window's first decision, which the GPU's policy read: its starting action.
        learner.host.applied = acts[kit.start_actions_at + row * actions ..][0..actions];
        learner.host.policyRow();
        const theirs: []const f32 = acts[kit.raw_at + row * actions ..][0..actions];
        for (theirs, learner.host.raw) |gpu, mirrored| {
            worst = @max(worst, gapInUnits(gpu, mirrored, 1.0));
            largest = @max(largest, @abs(gpu));
        }
    }
    report.print("\n  mirror vs the kit's policy, {d} rows x {d} actions: " ++
        "worst difference {e} (largest action {e})\n", .{
        kit.rows,
        actions,
        worst,
        largest,
    });
    try expect(worst < 1.0e-5 * @max(largest, 1.0e-3));
}

test "robot_track_resident: the judge's actor - zero weights ARE the servo, trained ones act, training untouched" {
    // Plan F1b's known answers. With every mirrored weight zero the policy's output is exactly zero, so judging the
    // learner must give the servo's judgement to the bit. After a few rounds the policy has moved, and its judgement
    // must differ - the actor really acts. And judging borrows only the learner's scratch: its own fleet and its
    // random stream are byte-for-byte what they were, so a judged run trains exactly as an unjudged one.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
    });
    defer learner.deinit();
    host.element_count = @max(learner.data.end, learner.kit.param_count + learner.kit.policy_count);

    const clip: *const dance.Clip = fleet.clips[0];
    const starts: []usize = try track.evenStarts(gpa, clip, 90);
    defer gpa.free(starts);
    const servo: track.Judgement = try track.judge(gpa, fleet.m, clip, fleet.options, starts, null);

    // Zero weights: the servo, exactly.
    @memset(learner.host.mirror, 0.0);
    const silent: track.Judgement = try track.judge(gpa, fleet.m, clip, fleet.options, starts, learner.judgeActor());
    try expect(std.meta.eql(silent, servo));

    // Trained weights: a different judgement - and the learner's own fleet and random stream untouched by judging.
    for (0..12) |_| {
        learner.simulateAndTrain();
    }
    learner.syncMirror();
    const rng_before: @TypeOf(learner.rng) = learner.rng;
    const fleet_rng_before: @TypeOf(fleet.rng) = fleet.rng;
    const frames_before: []u32 = try gpa.dupe(u32, fleet.frame);
    defer gpa.free(frames_before);
    const acting: track.Judgement = try track.judge(gpa, fleet.m, clip, fleet.options, starts, learner.judgeActor());
    try expect(!std.meta.eql(acting, servo));
    try expect(std.meta.eql(learner.rng, rng_before));
    try expect(std.meta.eql(fleet.rng, fleet_rng_before));
    try expect(eql(u32, fleet.frame, frames_before));
    report.print("\n  judge's actor after 12 rounds: MTTF {d:.2} s (servo {d:.2} s), reward {d:.3} (servo {d:.3})\n", .{
        acting.meanTimeToFailure(),
        servo.meanTimeToFailure(),
        acting.meanReward(),
        servo.meanReward(),
    });
}

test "robot_track_resident: the policy's slow average follows every update, and the judge plays it, not the live one" {
    // A learner keeping its policy's slow average at d = 0.9 - quick, so a few updates set it apart - on the kit's CPU
    // twin. It starts as the seeded policy. After every round of one policy update it must be the CPU recurrence
    // avg <- avg + (1 - d)(w - avg) over the live weights read back after the update, bit for bit (`zm.polyakFollow`,
    // the kernel's own arithmetic). Then the judged weights the host holds are the average, the policy file's parts
    // are the judged weights, and the judge's actor acts with them: its actions do not change when the live weights
    // are made the average's, and do when the judged weights are made the live ones.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    const decay: f32 = 0.9;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = means, .spread = spreads }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .policy_average_decay = decay,
    });
    defer learner.deinit();
    const policy_at: usize = learner.kit.p_at;
    const policy_count: usize = learner.kit.policy_count;
    const average_at: usize = learner.policy_average_at;
    try expectEqual(@as(u32, @intCast(policy_count)), learner.policy_average_count);
    const expected_average: []f32 = try gpa.alloc(f32, policy_count);
    defer gpa.free(expected_average);
    var checks: report.Checks = .{};
    {
        const params: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        @memcpy(expected_average, params[average_at..][0..policy_count]);
        const starts_as_the_policy: bool = eql(f32, expected_average, params[policy_at..][0..policy_count]);
        checks.holds(starts_as_the_policy, "the average does not start as the seeded policy\n", .{});
    }
    const follow: f32 = 1.0 - decay;
    var rounds_with_an_update: u32 = 0;
    for (0..6) |round| {
        const updates_before: u64 = learner.policy_updates;
        learner.simulateAndTrain();
        learner.waitForReadback();
        const params: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        const updates_made: u64 = learner.policy_updates - updates_before;
        checks.holds(updates_made <= 1, "round {d}: {d} policy updates, one at most expected\n", .{
            round,
            updates_made,
        });
        if (updates_made == 1) {
            rounds_with_an_update += 1;
            const live: []const f32 = params[policy_at..][0..policy_count];
            for (expected_average, live) |*held, online| {
                held.* = zm.polyakFollow(f32, held.*, online, follow);
            }
        }
        const average: []const f32 = params[average_at..][0..policy_count];
        const follows_the_recurrence: bool = eql(f32, expected_average, average);
        checks.holds(follows_the_recurrence, "round {d}: the average is not the recurrence's, bit for bit\n", .{round});
    }
    checks.holds(rounds_with_an_update >= 3, "{d} rounds updated the policy, 3 or more expected\n", .{
        rounds_with_an_update,
    });
    // THE JUDGED WEIGHTS: the average's, not the live ones - which by now differ.
    learner.syncMirror();
    const judged_is_the_average: bool = eql(f32, learner.host.judged, expected_average);
    checks.holds(judged_is_the_average, "the judged weights are not the average\n", .{});
    const live_differs: bool = !eql(f32, learner.host.mirror, learner.host.judged);
    checks.holds(live_differs, "the live weights are still the average's: nothing tells them apart\n", .{});
    const parts_are_judged: bool = learner.policyParts().packed_weights.ptr == learner.host.judged.ptr;
    checks.holds(parts_are_judged, "the policy file's weights are not the judged ones\n", .{});
    // THE JUDGE's ACTOR, from the same zeroed actions each time.
    const actions: []f32 = try gpa.alloc(f32, fleet.options.envs * fleet.action_width);
    defer gpa.free(actions);
    const judged_actions: []f32 = try gpa.alloc(f32, actions.len);
    defer gpa.free(judged_actions);
    const judge: track.Actor = learner.judgeActor();
    @memset(actions, 0);
    judge.act(judge.context, fleet, actions);
    @memcpy(judged_actions, actions);
    const live_weights: []f32 = try gpa.dupe(f32, learner.host.mirror);
    defer gpa.free(live_weights);
    @memcpy(learner.host.mirror, learner.host.judged);
    @memset(actions, 0);
    judge.act(judge.context, fleet, actions);
    const ignores_the_live: bool = eql(f32, actions, judged_actions);
    checks.holds(ignores_the_live, "the judge's actions changed with the live weights\n", .{});
    @memcpy(learner.host.mirror, live_weights);
    @memcpy(learner.host.judged, live_weights);
    @memset(actions, 0);
    judge.act(judge.context, fleet, actions);
    const follows_the_judged: bool = !eql(f32, actions, judged_actions);
    checks.holds(follows_the_judged, "the judge's actions did not change with the judged weights\n", .{});
    try checks.finish();
}

test "robot_track_resident: a saved state resumes the same learner; another learner's file is refused by name" {
    // Plan A1's known answers, on the kit's CPU twin. A learner is trained a few rounds - so its weights, Adam's
    // moments, its counters and its random stream have all moved from where a fresh learner starts - and saved. A
    // fresh learner then loads the file. What must hold:
    //
    //   * the fresh learner, saved again, writes the very same bytes: every parameter, moment, normaliser value,
    //     counter and the random stream's state, bit for bit;
    //   * it chooses the saved learner's action on the same features, bit for bit (the mirror is the saved policy);
    //   * the pushes' top is as far open as it was saved, its clock not yet started - and a file whose top is no
    //     share of the range is refused by name;
    //   * a file whose options differ is refused, naming the option;
    //   * CONTROL - one exponent bit of the policy's last parameter changed in the file: the action differs. Without
    //     it, the action check could pass because loading did nothing and both learners happened to agree.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const action_count: usize = track.actionSize(fleet.m);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    // With the policy's slow average, the critic after it, the world model's skip head and Muon on the policy's hidden
    // matrix as on the world model's (its momentum in Adam's first moments), so the file carries them all and loading
    // brings them back - the change's moments among the world model's running statistics too.
    const learner_options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .policy_average_decay = 0.99,
        .train_critic = true,
        .skip_steps = 4,
        .world_form = .dense_tanh,
        .policy_muon = true,
        .world_gradient_clip = 50,
        .policy_gradient_clip = 20,
    };
    // One CPU pipe for both learners: on the CPU twin the kit's buffers are the kernel module's own, so the second
    // learner's `init` seeds fresh weights over the first one's - exactly what a restarted trainer would see.
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const saved_action: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(saved_action);
    const saved_top_share: f32 = 0.375;

    const saved_state: []u8 = saved: {
        const saved_learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{
            .mean = means,
            .spread = spreads,
        }, learner_options);
        defer saved_learner.deinit();
        for (0..4) |_| {
            saved_learner.simulateAndTrain();
        }
        try expect(saved_learner.world_updates > 0 and saved_learner.policy_updates > 0);
        saved_learner.waitForReadback();
        saved_learner.features(0);
        saved_learner.host.policyRow();
        @memcpy(saved_action, saved_learner.host.raw);
        // The pushes' top where a brake had held it, three eighths of the range open.
        fleet.push_top.share = saved_top_share;
        break :saved try saved_learner.exportState(gpa);
    };
    defer gpa.free(saved_state);
    // The two learners share the fleet: its top is moved on, with a clock running, so that loading has to bring
    // back the saved one.
    fleet.push_top.share = 0.875;
    fleet.push_top.told_hours = 2.0;

    const resumed_learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{
        .mean = means,
        .spread = spreads,
    }, learner_options);
    defer resumed_learner.deinit();
    // Before loading, the fresh learner acts otherwise: its weights are the seeded ones, not the trained ones.
    resumed_learner.features(0);
    resumed_learner.host.policyRow();
    const fresh_learner_acts_otherwise: bool = !eql(f32, resumed_learner.host.raw, saved_action);
    try expect(fresh_learner_acts_otherwise);

    try resumed_learner.importState(gpa, saved_state);
    try expectEqual(saved_top_share, fleet.push_top.share);
    try expectEqual(@as(?f32, null), fleet.push_top.told_hours);
    const state_saved_again: []u8 = try resumed_learner.exportState(gpa);
    defer gpa.free(state_saved_again);
    try expect(eql(u8, state_saved_again, saved_state));
    resumed_learner.features(0);
    resumed_learner.host.policyRow();
    try expect(eql(f32, resumed_learner.host.raw, saved_action));

    // A file trained with another step size: refused, by the option's path, and loading it changes nothing.
    const header_size: usize = @sizeOf(resident.StateHeader);
    const other_options_state: []u8 = try gpa.dupe(u8, saved_state);
    defer gpa.free(other_options_state);
    var other_options_header: resident.StateHeader = std.mem.bytesToValue(
        resident.StateHeader,
        other_options_state[0..header_size],
    );
    other_options_header.options.policy_rate *= 2.0;
    @memcpy(other_options_state[0..header_size], asBytes(&other_options_header));
    const named_problem: []const u8 = resumed_learner.stateProblem(other_options_state) orelse
        return error.TestExpectedRefusal;
    try expectEqualStrings("options.policy_rate", named_problem);
    try expectError(error.StateFileRefused, resumed_learner.importState(gpa, other_options_state));
    try expect(resumed_learner.stateProblem(saved_state[0..16]) != null);

    // A top that is no share of the range - past its end, or not a number: refused by name.
    const quiet_nan: f32 = @bitCast(@as(u32, 0x7FC0_0000));
    const impossible_tops = [_]f32{ 1.5, -0.25, quiet_nan };
    for (impossible_tops) |impossible_top| {
        const other_top_state: []u8 = try gpa.dupe(u8, saved_state);
        defer gpa.free(other_top_state);
        var other_top_header: resident.StateHeader = std.mem.bytesToValue(
            resident.StateHeader,
            other_top_state[0..header_size],
        );
        other_top_header.push_top_share = impossible_top;
        @memcpy(other_top_state[0..header_size], asBytes(&other_top_header));
        const top_problem: []const u8 = resumed_learner.stateProblem(other_top_state) orelse
            return error.TestExpectedRefusal;
        try expectEqualStrings("numbers.push_top_share: from 0 to 1", top_problem);
    }

    // Numbers that cannot be: a NaN first parameter, and a zero last spread (the file's last four bytes). Each refused
    // by its section's name before anything is loaded.
    const unusable_numbers_state: []u8 = try gpa.dupe(u8, saved_state);
    defer gpa.free(unusable_numbers_state);
    const quiet_nan_bits: u32 = 0x7FC0_0000;
    const not_a_number: f32 = @bitCast(quiet_nan_bits);
    @memcpy(unusable_numbers_state[header_size..][0..4], asBytes(&not_a_number));
    const parameters_problem: []const u8 = resumed_learner.stateProblem(unusable_numbers_state) orelse
        return error.TestExpectedRefusal;
    try expectEqualStrings("numbers.parameters: not finite", parameters_problem);
    @memcpy(unusable_numbers_state, saved_state);
    const zero_spread: f32 = 0.0;
    @memcpy(unusable_numbers_state[unusable_numbers_state.len - 4 ..][0..4], asBytes(&zero_spread));
    const spreads_problem: []const u8 = resumed_learner.stateProblem(unusable_numbers_state) orelse
        return error.TestExpectedRefusal;
    try expectEqualStrings("numbers.normalizer_spreads: not finite, or not above zero", spreads_problem);

    // CONTROL: the last action's output bias - the parameter just before the policy's block for its applied action -
    // with its top exponent bit flipped (a zero becomes 2.0, anything else changes by orders of magnitude). The file
    // is still well formed, so it loads, and the action must move.
    const damaged_state: []u8 = try gpa.dupe(u8, saved_state);
    defer gpa.free(damaged_state);
    const last_output_bias_index: usize = resumed_learner.kit.policyWeights().applied - 1;
    const last_output_bias_at: usize = header_size + last_output_bias_index * @sizeOf(f32);
    const exponent_byte_at: usize = last_output_bias_at + 3;
    damaged_state[exponent_byte_at] ^= 0x40;
    try resumed_learner.importState(gpa, damaged_state);
    resumed_learner.features(0);
    resumed_learner.host.policyRow();
    const damaged_file_acts_otherwise: bool = !eql(f32, resumed_learner.host.raw, saved_action);
    try expect(damaged_file_acts_otherwise);
}

/// A SUPERTRACK POLICY FILE AGAINST THE LEARNER THAT WROTE IT, on `fleet` - whose action is the joints' offsets, or
/// the offsets and a stiffness per limb (`track.Fleet.Options.limb_stiffness`). A learner trained a few rounds writes
/// its policy (`lab.policyOfSuperTrack`), which goes through its file as the lab reads it. Then:
///
///   * on rows the kit gathered itself, the file's policy gives the kit's own policy output BIT FOR BIT: the same
///     weights in the same layout, summed in the same order (the bias, then the inputs), through the same tanh;
///   * on the learner's own fleet, for 150 decisions with the file's policy acting, the lab's decider builds the
///     observation and decides as the learner's mirror does - to rounding, since the mirror sums the goal and the
///     state interleaved rather than one after the other - and the controller hands the fleet that action through
///     the policy's filter, as the learner gives its own: the joints' offsets at one share, the limbs' stiffnesses
///     at another, each number checked;
///   * CONTROL: one bias of the file's last layer changed, and the kit's rows are no longer matched.
///
/// The normaliser is not the identity, so that normalising - and normalising the goal and the state alike - is part
/// of what is checked.
fn expectPolicyFileActsAsItsLearner(gpa: Allocator, fleet: *track.Fleet) !void {
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    for (means, spreads, 0..) |*mean, *spread, feature_index| {
        const index_as_float: f32 = @floatFromInt(feature_index);
        const place_in_cycle_of_five: f32 = @floatFromInt(feature_index % 5);
        mean.* = 0.01 * index_as_float;
        spread.* = 1.0 + 0.1 * place_in_cycle_of_five;
    }
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = means, .spread = spreads }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
    });
    defer learner.deinit();
    host.element_count = @max(host.element_count, learner.data.end);
    for (0..4) |_| {
        learner.simulateAndTrain();
    }
    learner.waitForReadback();
    learner.syncMirror();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const written_policy: lab.GenoPolicy = try lab.policyOfSuperTrack(
        arena,
        learner.policyParts(),
        fleet.options.action_scale,
        1,
    );
    const policy_bytes: []u8 = try lab.PolicyFile.encode(arena, &written_policy);
    var policy: lab.GenoPolicy = try lab.PolicyFile.decode(arena, policy_bytes);
    try expectEqual(@as(u32, 1), policy.decimation);

    // The file's action is the learner's: the offsets, then the fleet's stiffnesses - none, or one a limb.
    const action_count: usize = learner.host.raw.len;
    const offset_count: usize = track.actionSize(fleet.m);
    try expectEqual(fleet.action_width, action_count);
    try expectEqual(action_count - offset_count, @as(usize, policy.stiffness_count));
    try expectEqual(learner.options.stiffness_filter, policy.stiffness_filter_beta);

    // The kit's own rows: real windows gathered on the device, the acting rollout with no noise.
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    try expect(learner.drawWindows(0, .anywhere));
    learner.data.gather(kit, 0);
    const sigma: f32 = kit.sigma;
    kit.sigma = 0.0;
    kit.forward();
    kit.sigma = sigma;
    const activations: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const scratch: lab.PolicyScratch = try .init(arena, &policy);
    // The goal - its features and the root target's slots, the kit's lead - then the state.
    const goal_width: usize = kit.lead;
    const goal_and_state: []f32 = try arena.alloc(f32, goal_width + feature_count);
    const file_action: []f32 = try arena.alloc(f32, action_count);
    var rows_matched_exactly: usize = 0;
    for (0..kit.rows) |row| {
        const row_start: usize = kit.blockX(0) + row * kit.width;
        @memcpy(goal_and_state[0..goal_width], activations[row_start..][0..goal_width]);
        @memcpy(goal_and_state[goal_width..], activations[row_start + kit.lead ..][0..feature_count]);
        // The action applied before the window's first decision, which the kit's policy read: its starting action.
        const applied: []const f32 = activations[kit.start_actions_at + row * action_count ..][0..action_count];
        lab.policyMeanAction(&policy, goal_and_state, applied, scratch, file_action);
        const kit_action: []const f32 = activations[kit.raw_at + row * action_count ..][0..action_count];
        if (eql(f32, kit_action, file_action)) {
            rows_matched_exactly += 1;
        }
    }
    try expectEqual(@as(usize, kit.rows), rows_matched_exactly);

    // The lab's decider on the learner's own fleet, acting for a few seconds of motion, against the learner's mirror.
    // Every decision takes the same path through both, so a few seconds hold the check: the stepping is what costs.
    const decision_count: usize = 150;
    const character_count: usize = fleet.options.envs;
    var decider: lab.PolicyDecider = try .init(arena, fleet.m, fleet.options.body_names, .{}, &policy);
    var controller: robot_policy.Controller =
        try .init(arena, fleet.m, decider.subset, character_count, policy.controllerOptions());
    const decided_actions: []f32 = try arena.alloc(f32, character_count * action_count);
    var worst_difference: f32 = 0.0;
    var largest_action: f32 = 0.0;
    for (0..decision_count) |_| {
        decider.decide(&policy, &controller, fleet, character_count, decided_actions);
        for (0..character_count) |character| {
            learner.features(character);
            // The mirror reads what the file's policy read: the action the controller's filter gave last.
            learner.host.applied = controller.appliedAction(character);
            learner.host.policyRow();
            const decided: []const f32 = decided_actions[character * action_count ..][0..action_count];
            for (decided, learner.host.raw) |from_file, from_mirror| {
                worst_difference = @max(worst_difference, gapInUnits(from_file, from_mirror, 1.0));
                largest_action = @max(largest_action, @abs(from_mirror));
            }
        }
        // The controller gives each decided action through the policy's filter, as the learner gives its own
        // (`giveAction`): blended into the action it gave before - a joint's offset at the policy's share, a limb's
        // stiffness at the stiffnesses' own.
        const given_before: []const f32 = try arena.dupe(f32, controller.filtered);
        const applied_actions: []const f32 = controller.apply(decided_actions);
        for (decided_actions, given_before, applied_actions, 0..) |decided_number, before, applied_number, at| {
            const number_in_action: usize = at % action_count;
            const is_offset: bool = number_in_action < offset_count;
            const share: f32 = if (is_offset) policy.filter_beta else policy.stiffness_filter_beta;
            const filtered: f32 = rbt.filteredActionNumber(share, decided_number, before);
            const blended: f32 = if (share == 1.0) decided_number else filtered;
            try expectEqual(blended, applied_number);
        }
        _ = fleet.step(applied_actions);
    }
    report.print("\n  SuperTrack policy file vs the mirror, {d} steps x {d} characters: worst {e} (largest {e})\n", .{
        decision_count,
        character_count,
        worst_difference,
        largest_action,
    });
    try expect(worst_difference < 1.0e-5 * @max(largest_action, 1.0e-3));

    // CONTROL: a bias of the last layer changed - the kit's first row is no longer what the file's policy gives.
    const last_layer: lab.PolicyLayer = policy.layers[policy.layers.len - 1];
    last_layer.weights_and_biases[last_layer.weights_and_biases.len - 1] += 0.5;
    const first_row_start: usize = kit.blockX(0);
    @memcpy(goal_and_state[0..goal_width], activations[first_row_start..][0..goal_width]);
    @memcpy(goal_and_state[goal_width..], activations[first_row_start + kit.lead ..][0..feature_count]);
    const first_applied: []const f32 = activations[kit.start_actions_at..][0..action_count];
    lab.policyMeanAction(&policy, goal_and_state, first_applied, scratch, file_action);
    try expect(!eql(f32, activations[kit.raw_at..][0..action_count], file_action));
}

test "robot_track_resident: a SuperTrack policy file acts as the kit's policy bit for bit, and as the learner acts" {
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    try expectEqual(track.actionSize(setup.fleet.m), setup.fleet.action_width);
    try expectPolicyFileActsAsItsLearner(gpa, setup.fleet);
}

test "robot_track_resident: a policy file with a stiffness per limb acts as its learner, each part by its own filter" {
    // The same robot and clip, the fleet's action the joints' offsets and a stiffness per limb: the policy's file
    // carries the stiffnesses and their filter's share, and the lab's player gives them to a fleet of that action.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const m: *rbt.Model = &setup.imported.model;
    const with_limbs: *track.Fleet = try .init(gpa, m, &.{&setup.clip}, .{
        .envs = 4,
        .capacity = 32,
        .limb_stiffness = true,
    });
    defer with_limbs.deinit();
    try expectEqual(track.actionSize(m) + m.limb_count, with_limbs.action_width);
    try expect(m.limb_count > 0);
    try expectPolicyFileActsAsItsLearner(gpa, with_limbs);
}

/// THE JUDGE's FIRST CONTROL for SuperTrack's observation, with `stiffness_count` stiffnesses after the joints'
/// offsets in the action - none, or one a limb: every weight and bias zero acts with zero offsets and every limb at
/// stiffness zero, the servo's own springs, so the judgement must equal the servo's on the same starts exactly -
/// which holds the decider's SuperTrack path, its every-step decisions, its unfiltered controller and, for a policy
/// with stiffnesses, the fleet the judge makes for it to the judge's own. Then the same policy is shown: the show's
/// fleet takes actions of the policy's width.
fn expectZeroPolicyJudgedAsTheServo(gpa: Allocator, stiffness_count: usize) !void {
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const m: *rbt.Model = setup.fleet.m;
    const feature_count: usize = track.localSize(m.body_count);
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const hidden_width: usize = 8;
    const action_count: usize = track.actionSize(m) + stiffness_count;
    // The policy reads the goal - the features and the root target's slots - then the state.
    const observation_size: usize = 2 * feature_count + rbt.root_target_size;
    const first_layer: usize = lab.PolicyLayer.parameterCount(.tanh, observation_size, hidden_width);
    const second_layer: usize = lab.PolicyLayer.parameterCount(.tanh, hidden_width, hidden_width);
    const third_layer: usize = lab.PolicyLayer.parameterCount(.none, hidden_width, action_count);
    // The block for the action applied before a decision, after the layers: zero, as a policy that does not read it.
    const applied_block: usize = action_count * hidden_width;
    const zero_weights: []f32 = try arena.alloc(f32, first_layer + second_layer + third_layer + applied_block);
    @memset(zero_weights, 0.0);
    const means: []f32 = try arena.alloc(f32, feature_count);
    const spreads: []f32 = try arena.alloc(f32, feature_count);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    const parts: resident.PolicyParts = .{
        .packed_weights = zero_weights,
        .feature_count = feature_count,
        .root_target = true,
        .hidden_width = hidden_width,
        .action_count = action_count,
        .normalizer = .{ .mean = means, .spread = spreads },
        .filter = 1.0,
        .stiffness_count = stiffness_count,
        .stiffness_filter = 1.0,
    };
    const policy: lab.GenoPolicy = try lab.policyOfSuperTrack(arena, parts, setup.fleet.options.action_scale, 1);
    try expectEqual(stiffness_count > 0, policy.givesLimbStiffness());
    // A start every 90 frames: each start's episode runs to the clip's end or a fall, and the judge takes the same path
    // from every start, so a few starts hold the comparison.
    const frames_between_starts: usize = 90;
    const starts: []usize = try track.evenStarts(arena, &setup.clip, frames_between_starts);
    const settings: lab.PolicyJudgeSettings = .{ .starts = starts };
    const names: []const []const u8 = setup.imported.names;
    const servo: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, null, settings);
    const zero: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, &policy, settings);
    try expectEqual(servo.starts, zero.starts);
    try expectEqual(servo.failures, zero.failures);
    try expectEqual(servo.reached_end, zero.reached_end);
    try expectEqual(servo.watched_steps, zero.watched_steps);
    try expectEqual(servo.reward_sum, zero.reward_sum);
    // Probed: the same policy through a push, on a fleet the probe makes for it - every push survived or lost.
    const probe: track.RecoveryProbe = .{ .speeds = &.{1.0} };
    var bands: [1]track.RecoveryBand = undefined;
    try lab.probePolicy(gpa, arena, m, names, &setup.clip, &policy, settings, probe, &bands);
    try expect(bands[0].pushes > 0);
    try expectEqual(bands[0].pushes, bands[0].survived + bands[0].lost);
    // Shown: a fleet of the policy's own action, stepped under it.
    const clips = [_]*const dance.Clip{&setup.clip};
    var show: lab.PolicyShow = try .start(arena, m, names, &clips, &policy, .{});
    defer show.end();
    try expectEqual(policy.actionSize(), show.fleet.action_width);
    const shown_steps: usize = 8;
    for (0..shown_steps) |_| {
        show.step(&policy);
    }
    try expectEqual(@as(u64, shown_steps), show.exposure_steps);
}

test "robot_track_resident: a SuperTrack policy of zero weights is judged as the servo alone" {
    const no_stiffnesses: usize = 0;
    try expectZeroPolicyJudgedAsTheServo(testing_allocator, no_stiffnesses);
}

test "robot_track_resident: a zero policy with a stiffness per limb is judged as the servo alone, and shown" {
    // The limb count of the tests' robot (`kit_tests.FleetSetup`), read from a model of its own.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    const limb_count: usize = setup.fleet.m.limb_count;
    setup.deinit();
    try expect(limb_count > 0);
    try expectZeroPolicyJudgedAsTheServo(gpa, limb_count);
}

/// A RESUMED LEARNER's BUFFERS POISONED before its state is loaded. Every CPU pipe of the kit's module shares the
/// module's buffers, so a learner resumed onto a pipe of its own still sees the saved learner's numbers wherever its
/// own `init` wrote none. NaN in every activation, parameter and moment the learner uses, between its `init` and its
/// `importState`, leaves a load nothing to inherit: whatever it does not write stays NaN, and the weights compared, or
/// the state saved again, show it.
fn poisonLearnerBuffers(
    gpa: Allocator,
    host: *compute_host.Compute(zn_mlp),
    learner: *const Resident(zn_mlp),
) !void {
    const acts_used: u32 = learner.buffers_used.acts_floats;
    const params_used: u32 = learner.buffers_used.params_floats;
    const poison: []f32 = try gpa.alloc(f32, @max(acts_used, params_used));
    defer gpa.free(poison);
    @memset(poison, nan(f32));
    host.uploadAt(.acts, 0, poison[0..acts_used]);
    host.upload(.params, poison[0..params_used]);
    host.upload(.adam_m, poison[0..params_used]);
    host.upload(.adam_v, poison[0..params_used]);
}

test "robot_track_resident: with the critic on, every world-model round trains it, its weights moving and finite" {
    // SuperTrack's GPU learner with `train_critic`: a few rounds on the kit's CPU twin. Every world-model update is a
    // critic update too (their counts agree), and the critic's online heads have moved from their starting weights
    // and are finite everywhere - it trains on the windows the world model gathers, and does not blow up there.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .train_critic = true,
        .critic = .{ .hidden = 16 },
    });
    defer learner.deinit();
    const critic: kit_mod.LatentCritic(zn_mlp) = learner.critic orelse return error.NoCritic;
    const online_start: u32 = critic.online_params_start;
    const online_floats: u32 = critic.online_params_end - online_start;
    host.element_count = @max(learner.data.end, critic.online_params_end);
    const params_before: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const starting_weights: []f32 = try gpa.dupe(f32, params_before[online_start..][0..online_floats]);
    defer gpa.free(starting_weights);
    for (0..6) |_| {
        learner.simulateAndTrain();
    }
    try expect(learner.critic_updates > 0);
    try expectEqual(learner.world_updates, learner.critic_updates);
    const params_after: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    // A copy: the buffer itself is the resumed learner's too.
    const trained_weights: []f32 = try gpa.dupe(f32, params_after[online_start..][0..online_floats]);
    defer gpa.free(trained_weights);
    var moved_weights: usize = 0;
    for (starting_weights, trained_weights) |before, after| {
        try expect(after == after and @abs(after) < 1e6);
        moved_weights += @intFromBool(before != after);
    }
    try expect(moved_weights > online_floats / 2);
    // The state file keeps the critic: a fresh learner of the same options, resumed from it, holds the same critic
    // weights and the same update count.
    const state_bytes: []u8 = try learner.exportState(gpa);
    defer gpa.free(state_bytes);
    var resumed_host: compute_host.Compute(zn_mlp) = .initCpu();
    const resumed: *Resident(zn_mlp) = try .init(gpa, &resumed_host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .train_critic = true,
        .critic = .{ .hidden = 16 },
    });
    defer resumed.deinit();
    resumed_host.element_count = host.element_count;
    try poisonLearnerBuffers(gpa, &resumed_host, resumed);
    try resumed.importState(gpa, state_bytes);
    try expectEqual(learner.critic_updates, resumed.critic_updates);
    const resumed_params: []const f32 = resumed_host.readLatest(.params) orelse return error.NoReadback;
    const resumed_weights: []const f32 = resumed_params[online_start..][0..online_floats];
    try expectEqualSlices(f32, trained_weights, resumed_weights);
}

test "robot_track_resident: with a flow acting, a saved state resumes the same learner, bit for bit" {
    // The learner with a flow actor (`actor = .flow`), trained a few rounds - the flow acting with each character's
    // drifting noise, and learning from SuperTrack's gradient - then saved. A fresh learner of the same options acts
    // otherwise before loading (its flow is still at rest); after loading it writes back the very same bytes (every
    // parameter - the flow's among them - moment, normaliser value, counter, the random stream, and each character's
    // noise) and chooses the very same action: the flow's mirror and noise are part of the state.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const action_count: usize = track.actionSize(fleet.m);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    const learner_options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .actor = .flow,
        .flow = .{ .hidden_width = 16 },
    };
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const saved_action: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(saved_action);
    const zero_noise: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(zero_noise);
    @memset(zero_noise, 0);

    // The saved learner's steps, kept past its block.
    var saved_acting_steps: u64 = 0;
    const saved_state: []u8 = saved: {
        const saved_learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{
            .mean = means,
            .spread = spreads,
        }, learner_options);
        defer saved_learner.deinit();
        for (0..4) |_| {
            saved_learner.simulateAndTrain();
        }
        try expect(saved_learner.world_updates > 0 and saved_learner.policy_updates > 0);
        saved_acting_steps = saved_learner.acting_steps;
        saved_learner.waitForReadback();
        saved_learner.syncMirror();
        saved_learner.features(0);
        saved_learner.host.correctedRow(zero_noise);
        @memcpy(saved_action, saved_learner.host.raw);
        break :saved try saved_learner.exportState(gpa);
    };
    defer gpa.free(saved_state);

    const resumed_learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{
        .mean = means,
        .spread = spreads,
    }, learner_options);
    defer resumed_learner.deinit();
    // Before loading, the fresh learner's flow is at rest: its typical action differs from the trained one's.
    resumed_learner.features(0);
    resumed_learner.host.correctedRow(zero_noise);
    try expect(!eql(f32, resumed_learner.host.raw, saved_action));

    try resumed_learner.importState(gpa, saved_state);
    // The steps taken come back too: every hashed noise stream carries on where the saved run was, rather than from its
    // start. (The pushes' schedule follows the trainer's training hours, which its own run saves.)
    try expectEqual(saved_acting_steps, resumed_learner.acting_steps);
    const state_saved_again: []u8 = try resumed_learner.exportState(gpa);
    defer gpa.free(state_saved_again);
    try expect(eql(u8, state_saved_again, saved_state));
    resumed_learner.features(0);
    resumed_learner.host.correctedRow(zero_noise);
    try expect(eql(f32, resumed_learner.host.raw, saved_action));
}

test "robot_track_resident: a flow at rest, judged through the learner's actor, is the policy alone" {
    // The judge for a flow run goes through the learner's own actor: the policy, corrected by its flow from zero
    // noise. A flow whose velocity is still zero, started from zero noise, corrects by exactly nothing - so judging it
    // must give the policy's own judgement to the bit: the same learner judged with its flow set aside.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .actor = .flow,
        .flow = .{ .hidden_width = 16 },
    });
    defer learner.deinit();
    const clip: *const dance.Clip = fleet.clips[0];
    const starts: []usize = try track.evenStarts(gpa, clip, 90);
    defer gpa.free(starts);
    const with_flow: track.Judgement =
        try track.judge(gpa, fleet.m, clip, fleet.options, starts, learner.judgeActor());
    const flow_actor: ?kit_mod.FlowActor(zn_mlp) = learner.kit.flow_actor;
    learner.kit.flow_actor = null;
    const policy_alone: track.Judgement =
        try track.judge(gpa, fleet.m, clip, fleet.options, starts, learner.judgeActor());
    learner.kit.flow_actor = flow_actor;
    try expect(std.meta.eql(with_flow, policy_alone));
}

test "robot_track_resident: planning flags start, keep and stop characters as their worked table says" {
    // `PlanningFlags`' own worked example: three characters, a budget of two, start 0.5, stop 0.1, two calm steps, a
    // decision every three on one clock - each step's slots, decisions and plan age as the table in its head, steps 4
    // and 5 (nobody decides) included; then calm, everyone stops and the clock comes to rest.
    const gpa: Allocator = testing_allocator;
    var flags: resident.PlanningFlags = try .init(gpa, 3, 2);
    defer flags.deinit(gpa);
    const settings: resident.PlanningFlags.Settings = .{
        .start_hazard = 0.5,
        .stop_hazard = 0.1,
        .calm_steps = 2,
        .budget = 2,
        .replan_every = 3,
    };
    const Expected = struct { hazards: [3]f32, slots: [3]?u32, deciding: [3]bool, age: ?u32 };
    const table = [_]Expected{
        .{ .hazards = .{ 0.6, 0.9, 0.7 }, .slots = .{ null, 0, 1 }, .deciding = .{ false, true, true }, .age = 1 },
        .{ .hazards = .{ 0.6, 0.3, 0.05 }, .slots = .{ null, 0, 1 }, .deciding = @splat(false), .age = null },
        .{ .hazards = .{ 0.6, 0.05, 0.05 }, .slots = .{ 1, 0, null }, .deciding = .{ true, true, false }, .age = 2 },
        .{ .hazards = .{ 0.2, 0.05, 0.8 }, .slots = .{ 1, null, 0 }, .deciding = .{ true, false, true }, .age = 1 },
        .{ .hazards = .{ 0.2, 0.05, 0.8 }, .slots = .{ 1, null, 0 }, .deciding = @splat(false), .age = null },
        .{ .hazards = .{ 0.2, 0.05, 0.8 }, .slots = .{ 1, null, 0 }, .deciding = @splat(false), .age = null },
        .{ .hazards = .{ 0.2, 0.05, 0.8 }, .slots = .{ 1, null, 0 }, .deciding = .{ true, false, true }, .age = 3 },
    };
    var deciding: [3]bool = undefined;
    for (table) |row| {
        const age: ?u32 = flags.step(&row.hazards, settings, true, &deciding);
        try expectEqualSlices(?u32, &row.slots, flags.slots);
        try expectEqualSlices(bool, &row.deciding, &deciding);
        try expectEqual(row.age, age);
    }
    // Nobody in danger: the clock rests at zero, and nobody decides.
    const calm = [3]f32{ 0, 0, 0 };
    for (0..4) |_| {
        _ = flags.step(&calm, settings, true, &deciding);
    }
    try expectEqualSlices(?u32, &.{ null, null, null }, flags.slots);
    try expectEqual(@as(u32, 0), flags.steps_since_decision);
}

test "robot_track_resident: the host reads the barrier's measures as the kernels do, and the hazard is their fraction" {
    // One row of normalised features, its head a metre too low and its up direction tilted far from the reference's.
    // The barrier's MEASURES, read on the host through slices (`zn_mlp.barrierMeasuresOf`) and turned into the
    // barrier's value (`barrierHinges`), against the kernels' - the tracking cost with the barrier at weight 1 minus
    // the same cost at weight 0 - for the same row, normaliser and margins. Then the planning hazard by hand: the head
    // a metre low against a margin of 0.25 is 4 margins; the tilt, 1 - cos = 0.900 against a margin of 1, is less -
    // the hazard is 4.
    const features: u32 = 12;
    const head_column: u32 = 2;
    const up_column: u32 = 5;
    const barrier: kit_mod.FailureBarrier = .{ .weight = 1 };
    var state: [features]f32 = undefined;
    var goal: [features]f32 = undefined;
    var means: [features]f32 = undefined;
    var spreads: [features]f32 = undefined;
    for (&state, &goal, &means, &spreads, 0..) |*state_value, *goal_value, *mean, *spread, column| {
        const position: f32 = @floatFromInt(column);
        state_value.* = 0.3 * @sin(position);
        goal_value.* = 0.3 * @cos(position);
        mean.* = 0.1 * position;
        spread.* = 0.5 + 0.05 * position;
    }
    // The head a metre below the reference's (in normalised units, a metre over the head's spread); the up
    // directions, raw: the character's (2, 0, 0.2), the reference's (0, 0, 2) - written as normalised features.
    goal[head_column] = 1.0;
    state[head_column] = 1.0 - 1.0 / spreads[head_column];
    const raw_up = [3]f32{ 2, 0, 0.2 };
    const raw_reference_up = [3]f32{ 0, 0, 2 };
    for (0..3) |axis| {
        const column: usize = up_column + axis;
        state[column] = (raw_up[axis] - means[column]) / spreads[column];
        goal[column] = (raw_reference_up[axis] - means[column]) / spreads[column];
    }
    const Row = zn.SliceRow(f32);
    const measures: zn_mlp.BarrierMeasures = zn_mlp.barrierMeasuresOf(
        Row,
        .{ .values = &state },
        .{ .values = &goal },
        .{ .values = &means },
        .{ .values = &spreads },
        head_column,
        up_column,
    );
    const host_value: f32 = zn_mlp.barrierHinges(
        measures,
        barrier.head_margin,
        barrier.head_width,
        barrier.tilt_margin,
        barrier.tilt_width,
    );
    // The kernels' value: the tracking cost of the row with and without the barrier.
    var pipe: compute_host.Compute(zn_mlp) = .initCpu();
    defer pipe.deinit();
    pipe.element_count = 64;
    var acts: [64]f32 = @splat(0);
    const states_at: u32 = 0;
    const goals_at: u32 = 16;
    const normaliser_at: u32 = 32;
    const cost_at: u32 = 60;
    @memcpy(acts[states_at..][0..features], &state);
    @memcpy(acts[goals_at..][0..features], &goal);
    @memcpy(acts[normaliser_at..][0..features], &means);
    @memcpy(acts[normaliser_at + features ..][0..features], &spreads);
    var costs: [2]f32 = undefined;
    for ([2]f32{ 0, 1 }, &costs) |barrier_weight, *cost| {
        pipe.upload(.acts, &acts);
        pipe.params = .{
            .rows = 1,
            .out_dim = features,
            .y_off = states_at,
            .t_off = goals_at,
            .u_off = normaliser_at,
            .x_off = cost_at,
            .barrier_head_column = head_column,
            .barrier_up_column = up_column,
            .barrier_weight = barrier_weight,
            .barrier_head_margin = barrier.head_margin,
            .barrier_head_width = barrier.head_width,
            .barrier_tilt_margin = barrier.tilt_margin,
            .barrier_tilt_width = barrier.tilt_width,
        };
        pipe.run("lat_tracking_cost", 1);
        const read: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
        cost.* = read[cost_at];
    }
    try expectApproxEqAbs(costs[1] - costs[0], host_value, 1e-5);
    // The hazard, by hand: a metre against a margin of 0.25.
    const hazard: f32 =
        resident.planningHazard(zn_mlp, &state, &goal, &means, &spreads, head_column, up_column, barrier);
    try expectApproxEqAbs(@as(f32, 4.0), hazard, 1e-4);
}

test "robot_track_resident: a pushed character is flagged to plan, and its decision falls due" {
    // The learner with planning on, acting with its untrained policy. Calm, nobody is
    // flagged: every hazard is below the start. Then character 0 is pushed sideways at 4 m/s: within a second and a
    // half its hazard passes the start, it takes a planner slot, and its first decision falls due.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    // The tests' fleet has no task head; the root's height serves - a fall lowers it as it lowers the head.
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .planning = .{
            .enabled = true,
            .flags = .{ .start_hazard = 0.5, .stop_hazard = 0.25, .calm_steps = 10, .budget = 2, .replan_every = 4 },
            // The hazards as they are: this is about the flags, not the projection.
            .lookahead_steps = 0,
        },
    });
    defer learner.deinit();
    const flags: *resident.PlanningFlags = &learner.planning_flags.?;
    learner.act(10, 1.0);
    for (flags.slots, learner.hazards) |slot, hazard| {
        try expect(slot == null);
        try expect(hazard < 0.5);
    }
    fleet.push(0, 4.0, 0.0);
    var flagged_after: ?usize = null;
    for (0..90) |step| {
        learner.act(1, 1.0);
        if (flags.slots[0] != null) {
            flagged_after = step;
            break;
        }
    }
    try expect(flagged_after != null);
    try expect(learner.planning_decisions > 0);
}

/// A learner of the planning tests' small sizes - a slot for each of the fleet's four characters, 16 candidates, a
/// horizon of 4, two rounds - over `fleet`, with `lookahead_steps` of hazard projection.
fn planningLearner(
    gpa: Allocator,
    host: *compute_host.Compute(zn_mlp),
    fleet: *track.Fleet,
    mean: []f32,
    spread: []f32,
    lookahead_steps: f32,
) !*Resident(zn_mlp) {
    return Resident(zn_mlp).init(gpa, host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .planning = .{
            .enabled = true,
            // A slot for every character (the tests' fleet has four), so no test depends on who fills them first:
            // competing for slots is the flags' worked table's to check.
            .flags = .{ .start_hazard = 0.5, .stop_hazard = 0.25, .calm_steps = 10, .budget = 4, .replan_every = 4 },
            .lookahead_steps = lookahead_steps,
            .candidates = 16,
            .horizon = 4,
            .rounds = 2,
            .elites = 4,
        },
    });
}

test "robot_track_resident: a learner too large for its buffers is refused by the buffer's name, and leaks nothing" {
    // The planning tests' learner with a flow and a critic, its search far larger than the kit's buffers: everything
    // before the search's kits built - the planning flags and their rows, the critic, the flow and its rows, the
    // planner's own rows - then the layout refused by name. The testing allocator fails the test on any allocation
    // left behind.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const refused = Resident(zn_mlp).init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .train_critic = true,
        .actor = .flow,
        .flow = .{ .hidden_width = 16, .hidden_layers = 1 },
        .planning = .{ .enabled = true, .flags = .{ .budget = 4 }, .candidates = 4096, .horizon = 8 },
    });
    try expectError(error.KitActivationsTooSmall, refused);
}

test "robot_track_resident: a pushed character's decision leaves its chosen plan in the mailbox, stamped" {
    // The planning tests' learner (`planningLearner`) acting with its untrained policy.
    // Character 0 is pushed until a decision is made; then the mailbox, read back with the parameters, must hold that
    // decision's step plus one as its stamp, and, in the pushed character's slot, the whole plan of the candidate the
    // search chose - every number finite, within the search's action bounds, and the candidate's own.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    // The tests' fleet has no task head; the root's height serves - a fall lowers it as it lowers the head.
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try planningLearner(gpa, &host, fleet, mean, spread, 10);
    defer learner.deinit();
    fleet.push(0, 4.0, 0.0);
    const flags: *resident.PlanningFlags = &learner.planning_flags.?;
    var decided: bool = false;
    for (0..120) |_| {
        learner.act(1, 1.0);
        if (flags.slots[0] != null and learner.planning_decisions > 0) {
            decided = true;
            break;
        }
    }
    try expect(decided);
    // Read everything back on the CPU twin - the candidates lie past the readback window acting needs.
    host.element_count = 0xffff_ffff;
    const parameters: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const planner: kit_mod.TrackingPlanner(zn_mlp) = learner.planner.?;
    const stamp: u32 = @bitCast(parameters[learner.mailbox_at]);
    try expectEqual(@as(u32, @intCast(learner.acting_steps)) + 1, stamp);
    const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
    const slot: u32 = flags.slots[0].?;
    const chosen_candidate: u32 = @trunc(acts[planner.mppi.chosen_offset + slot]);
    for (0..shape.horizon) |step| {
        const mailbox_action_at: usize = learner.mailbox_at + 1 + (slot * shape.horizon + step) * shape.action_width;
        const mailbox_action: []const f32 = parameters[mailbox_action_at..][0..shape.action_width];
        const candidate_row: u32 = slot * shape.candidates + chosen_candidate;
        const candidate_action_at: usize = shape.candidateActionAt(@intCast(step), candidate_row);
        const candidate_action: []const f32 = acts[candidate_action_at..][0..shape.action_width];
        try expectEqualSlices(f32, candidate_action, mailbox_action);
        for (mailbox_action) |value| {
            try expect(value == value and @abs(value) <= 1.0);
        }
    }
}

test "robot_track_resident: a decision the caller does not allow waits, pending, and is made with its true age" {
    // Character 0 starts planning on a step that may not decide: it takes a slot, but nothing is decided. The next
    // step, which may, makes the decision - for character 0 - and reports the plan age 2: the clock counted both.
    const gpa: Allocator = testing_allocator;
    var flags: resident.PlanningFlags = try .init(gpa, 3, 2);
    defer flags.deinit(gpa);
    const settings: resident.PlanningFlags.Settings = .{ .start_hazard = 0.5, .budget = 2, .replan_every = 3 };
    const hazards = [3]f32{ 0.9, 0, 0 };
    var deciding: [3]bool = undefined;
    const deferred: ?u32 = flags.step(&hazards, settings, false, &deciding);
    try expectEqual(@as(?u32, null), deferred);
    try expectEqualSlices(?u32, &.{ 0, null, null }, flags.slots);
    try expectEqualSlices(bool, &.{ false, false, false }, &deciding);
    try expect(flags.decision_pending);
    const made: ?u32 = flags.step(&hazards, settings, true, &deciding);
    try expectEqual(@as(?u32, 2), made);
    try expectEqualSlices(bool, &.{ true, false, false }, &deciding);
    try expect(!flags.decision_pending);
}

test "robot_track_resident: a rising hazard is projected ahead, a falling one read as it is" {
    // `projectedHazard`'s worked rows: rising from 0.2 to 0.3, ten steps ahead, 0.3 + 10 x 0.1 = 1.3; falling from 0.4
    // to 0.3, 0.3; and with no lookahead, the hazard itself.
    try expectApproxEqAbs(@as(f32, 1.3), resident.projectedHazard(0.3, 0.2, 10), 1e-6);
    try expectEqual(@as(f32, 0.3), resident.projectedHazard(0.3, 0.4, 10));
    try expectEqual(@as(f32, 0.3), resident.projectedHazard(0.3, 0.2, 0));
}

test "robot_track_resident: a planning character acts from its own plan, at the step the stamp says" {
    // A pushed character plans; once its decision is in the mailbox, for three steps its action must be exactly the
    // policy's reaction to the state it is in plus its plan's correction at index = acting steps - (stamp - 1) - read
    // from the parameters' readback before each step. (No flow here: the planner's basis is the identity, so the
    // correction adds as it is.)
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    // The tests' fleet has no task head; the root's height serves - a fall lowers it as it lowers the head.
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try planningLearner(gpa, &host, fleet, mean, spread, 10);
    defer learner.deinit();
    fleet.push(0, 4.0, 0.0);
    const flags: *resident.PlanningFlags = &learner.planning_flags.?;
    var decided: bool = false;
    for (0..120) |_| {
        learner.act(1, 1.0);
        if (flags.slots[0] != null and learner.planning_decisions > 0) {
            decided = true;
            break;
        }
    }
    try expect(decided);
    const planner: kit_mod.TrackingPlanner(zn_mlp) = learner.planner.?;
    const shape: bmpc_kit.SearchShape = planner.scorer.searchShape();
    const action_width: usize = shape.action_width;
    var steps_acted_from_plans: u32 = 0;
    for (0..3) |_| {
        // What the character should do this step, from the readback as the learner will read it.
        const parameters: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        const stamp: u32 = @bitCast(parameters[learner.mailbox_at]);
        const slot: u32 = flags.slots[0] orelse break;
        const plan_index: u32 = @as(u32, @intCast(learner.acting_steps)) - (stamp - 1);
        if (plan_index >= shape.horizon) {
            break;
        }
        const plan_correction_at: usize = learner.mailbox_at + 1 + (slot * shape.horizon + plan_index) * action_width;
        const correction: []const f32 = parameters[plan_correction_at..][0..action_width];
        learner.features(0);
        learner.host.policyRow();
        const expected: []f32 = try gpa.dupe(f32, learner.host.raw);
        defer gpa.free(expected);
        for (expected, correction) |*value, correction_value| {
            value.* += correction_value;
        }
        learner.act(1, 1.0);
        try expectEqualSlices(f32, expected, learner.actions[0..action_width]);
        steps_acted_from_plans += 1;
    }
    try expect(steps_acted_from_plans >= 2);
}

test "robot_track_resident: projecting the hazard ahead flags a pushed character sooner" {
    // The same push at the first step, on two fresh fleets: read as it is, the pushed character's hazard reaches the
    // start some steps later; projected ten steps along its rise, it gets there sooner.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var steps_to_flag: [2]usize = undefined;
    for ([2]f32{ 0, 10 }, &steps_to_flag) |lookahead_steps, *steps_taken| {
        var setup: kit_tests.FleetSetup = undefined;
        try setup.init(gpa);
        defer setup.deinit();
        const fleet: *track.Fleet = setup.fleet;
        fleet.head = 1;
        const f: usize = track.localSize(fleet.m.body_count);
        const mean: []f32 = try gpa.alloc(f32, f);
        defer gpa.free(mean);
        const spread: []f32 = try gpa.alloc(f32, f);
        defer gpa.free(spread);
        @memset(mean, 0.0);
        @memset(spread, 1.0);
        var host: compute_host.Compute(zn_mlp) = .initCpu();
        const learner: *Resident(zn_mlp) = try planningLearner(gpa, &host, fleet, mean, spread, lookahead_steps);
        defer learner.deinit();
        fleet.push(0, 4.0, 0.0);
        steps_taken.* = 200;
        for (0..200) |step| {
            learner.act(1, 1.0);
            if (learner.planning_flags.?.slots[0] != null) {
                steps_taken.* = step;
                break;
            }
        }
    }
    try expect(steps_to_flag[0] < 200);
    try expect(steps_to_flag[1] < steps_to_flag[0]);
}

test "robot_track_resident: planning keeps to its frame - one decision per call, the judge sees the policy alone" {
    // The planning tests' learner, a character pushed. Its first step's projected hazards are the hazards themselves -
    // no rise is invented before there is a step to rise from. Acting eight steps in one call - one frame - makes at
    // most one decision, whatever the clock says. And a judged step, after a decision, is the policy alone: the pushed
    // character's action is the policy's for its state - computed just before - and not its plan.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try planningLearner(gpa, &host, fleet, mean, spread, 10);
    defer learner.deinit();
    fleet.push(0, 4.0, 0.0);
    learner.act(1, 1.0);
    try expectEqualSlices(f32, learner.previous_hazards, learner.hazards);
    // Eight steps in one call: one decision at most.
    for (0..6) |_| {
        const decisions_before: u64 = learner.decisions_made;
        learner.act(8, 1.0);
        try expect(learner.decisions_made - decisions_before <= 1);
    }
    try expect(learner.decisions_made > 0);
    // A judged step: the pushed character, planning, acts as the policy does for the state it is in.
    try expect(learner.planning_flags.?.slots[0] != null);
    const action_width: usize = track.actionSize(fleet.m);
    learner.features(0);
    learner.host.policyRow();
    const policy_action: []f32 = try gpa.dupe(f32, learner.host.raw[0..action_width]);
    defer gpa.free(policy_action);
    learner.refreshMailbox();
    const plan_correction: ?[]const f32 = learner.plannedCorrection(0);
    learner.act(1, 0.0);
    try expectEqualSlices(f32, policy_action, learner.actions[0..action_width]);
    if (plan_correction) |planned| {
        try expect(!eql(f32, planned, learner.actions[0..action_width]));
    }
}

test "robot_track_resident: with a flow acting, the steps taken from plans become teacher 2's examples" {
    // The planning tests' learner with a flow as its actor. A pushed character acts from its plans; each step it takes
    // from one is kept as an example - the last holding exactly the condition it acted in and the plan's correction -
    // and a round of training then runs with teacher 2's batch in it, the flow's weights finite.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner_options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .actor = .flow,
        .flow = .{ .hidden_width = 16 },
        .planning = .{
            .enabled = true,
            .flags = .{ .start_hazard = 0.5, .stop_hazard = 0.25, .calm_steps = 10, .budget = 4, .replan_every = 4 },
            .candidates = 16,
            .horizon = 4,
            .rounds = 2,
            .elites = 4,
            .distill_rows = 16,
            .distill_examples = 64,
        },
    };
    const normaliser: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, normaliser, learner_options);
    defer learner.deinit();
    fleet.push(0, 4.0, 0.0);
    // Act until a character has acted from its plan.
    var acted_from_plan: bool = false;
    for (0..150) |_| {
        learner.refreshMailbox();
        if (learner.plannedCorrection(0)) |planned| {
            const action_width: usize = planned.len;
            const planned_copy: []f32 = try gpa.dupe(f32, planned);
            defer gpa.free(planned_copy);
            learner.features(0);
            const goal_copy: []f32 = try gpa.dupe(f32, learner.host.goal);
            defer gpa.free(goal_copy);
            const state_copy: []f32 = try gpa.dupe(f32, learner.host.z);
            defer gpa.free(state_copy);
            const examples_before: usize = learner.distillation_example_count;
            // Character 0 acts first in a step: its example goes where the ring's next one pointed before the step.
            const kept_at: usize = learner.distillation_next;
            learner.act(1, 1.0);
            try expect(learner.distillation_example_count > examples_before);
            // The condition: the goal - the kit's lead - then the state.
            const goal_width: usize = learner.kit.lead;
            const condition_width: usize = goal_width + f;
            const example_width: usize = condition_width + action_width;
            const example: []const f32 = learner.distillation_examples[kept_at * example_width ..][0..example_width];
            try expectEqualSlices(f32, goal_copy, example[0..goal_width]);
            try expectEqualSlices(f32, state_copy, example[goal_width..][0..f]);
            try expectEqualSlices(f32, planned_copy, example[condition_width..][0..action_width]);
            acted_from_plan = true;
            break;
        }
        learner.act(1, 1.0);
    }
    try expect(acted_from_plan);
    // A round of training with the batch in it.
    learner.simulateAndTrain();
    learner.waitForReadback();
    try expect(learner.kit.flow_actor.?.learning.?.distillation.?.has_batch);
    const parameters: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const flow_network = learner.kit.flow_actor.?.flow.network;
    for (parameters[flow_network.paramsStart()..flow_network.paramsEnd()]) |weight| {
        try expect(weight == weight and @abs(weight) < 1e6);
    }
    // The distillation's loss for the log, from the round's last update: positive and finite, and the learner's own
    // copy from the readback the same number. (Its arithmetic is the statistics kernels' own check.)
    const stats: []const f32 = parameters[learner.stats_at..][0..kit_mod.DeviceStats.floats];
    const distillation_loss: f32 = stats[kit_mod.DeviceStats.slot("distillation_loss")];
    try expect(distillation_loss > 0 and distillation_loss < 1e6);
    try expectEqual(distillation_loss, learner.device_stats.distillation_loss);
}

test "robot_track_resident: the host corrects the policy as the kit does" {
    // A learner with a flow, trained a few rounds so that its policy and its flow have both moved. The kit's acting
    // rollout on gathered windows, SuperTrack's exploration off and the flow's own noise hashed as always; then each
    // row's goal and state, read back from the very rows the kit used, put through the host with that same noise: the
    // policy's raw action plus the flow's correction must be the kit's - to the rounding of a different summation
    // order, as for the policy's mirror alone.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .actor = .flow,
        .flow = .{ .hidden_width = 16 },
    });
    defer learner.deinit();
    for (0..4) |_| {
        learner.simulateAndTrain();
    }
    // Everything back, on the CPU twin: the rows and the raw actions lie past the window acting reads.
    host.element_count = 0xffff_ffff;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const action_count: usize = learner.host.raw.len;
    try expect(learner.drawWindows(0, .anywhere));
    learner.data.gather(kit, 0);
    const sigma: f32 = kit.sigma;
    kit.sigma = 0.0;
    kit.forward();
    kit.sigma = sigma;
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    // The flow's noise at step 0: its own stream (`LatentKit.flowNoiseSeed`), at its own scale.
    const correction: kit_mod.FlowActor(zn_mlp).Correction = kit.flow_actor.?.correction;
    const flow_stream_seed: u32 = zn_mlp.latStepSeed(kit.seed, kit.steps + 3);
    const step_seed: u32 = zn_mlp.latStepSeed(flow_stream_seed, 0);
    const start_noise: []f32 = try gpa.alloc(f32, correction.synergy_count);
    defer gpa.free(start_noise);
    var worst: f32 = 0;
    var largest: f32 = 0;
    for (0..kit.rows) |row| {
        const at: usize = kit.blockX(0) + row * kit.width;
        @memcpy(learner.host.goal, acts[at..][0..kit.lead]);
        @memcpy(learner.host.z, acts[at + kit.lead ..][0..f]);
        for (start_noise, 0..) |*noise_value, synergy| {
            const hashed: f32 = zn_mlp.latNoise(step_seed, @intCast(row), @intCast(synergy));
            noise_value.* = correction.noise_scale * hashed;
        }
        learner.host.correctedRow(start_noise);
        const kit_raw: []const f32 = acts[kit.raw_at + row * action_count ..][0..action_count];
        for (kit_raw, learner.host.raw) |kit_value, host_value| {
            worst = @max(worst, gapInUnits(kit_value, host_value, 1.0));
            largest = @max(largest, @abs(kit_value));
        }
    }
    report.print("\n  the host's corrected policy vs the kit's, {d} rows x {d} actions: worst difference {e} " ++
        "(largest action {e})\n", .{ kit.rows, action_count, worst, largest });
    try expect(largest > 0);
    try expect(worst <= 1e-4 * @max(1, largest));
}

test "robot_track_resident: a flow run's policy file acts as its learner judges - the policy with the flow's mode" {
    // A learner with a flow, trained a little: its policy file (`lab.policyOfSuperTrack`, the flow copied out of the
    // CPU's copy of its weights) read back, and asked for its action on the kit's own rows, against the learner's
    // judging answer there - the judged policy corrected by the flow from zero noise (`HostPolicy.correctedRowOf`).
    // The same arithmetic: equal to the bit here, corrections of up to 9e-3 on actions of up to 3e-2.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .actor = .flow,
        .flow = .{ .hidden_width = 16 },
    });
    defer learner.deinit();
    for (0..4) |_| {
        learner.simulateAndTrain();
    }
    learner.waitForReadback();
    learner.syncMirror();
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const written_policy: lab.GenoPolicy =
        try lab.policyOfSuperTrack(arena, learner.policyParts(), fleet.options.action_scale, 1);
    const policy_bytes: []u8 = try lab.PolicyFile.encode(arena, &written_policy);
    const policy: lab.GenoPolicy = try lab.PolicyFile.decode(arena, policy_bytes);
    try expect(policy.flow != null);
    // The kit's own rows, as the slow test of the corrected policy reads them.
    host.element_count = 0xffff_ffff;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    try expect(learner.drawWindows(0, .anywhere));
    learner.data.gather(kit, 0);
    kit.forward();
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const action_count: usize = learner.host.raw.len;
    const scratch: lab.PolicyScratch = try .init(arena, &policy);
    const observation: []f32 = try arena.alloc(f32, kit.lead + f);
    const file_action: []f32 = try arena.alloc(f32, action_count);
    const no_applied_action: []f32 = try arena.alloc(f32, action_count);
    @memset(no_applied_action, 0);
    const zero_noise: []f32 = try arena.alloc(f32, learner.host.flow_coefficients.len);
    @memset(zero_noise, 0);
    var worst: f32 = 0;
    var largest: f32 = 0;
    var largest_correction: f32 = 0;
    for (0..kit.rows) |row| {
        const at: usize = kit.blockX(0) + row * kit.width;
        @memcpy(learner.host.goal, acts[at..][0..kit.lead]);
        @memcpy(learner.host.z, acts[at + kit.lead ..][0..f]);
        @memcpy(observation[0..kit.lead], learner.host.goal);
        @memcpy(observation[kit.lead..], learner.host.z);
        learner.host.policyRowOf(learner.host.judged);
        const uncorrected: []f32 = try arena.dupe(f32, learner.host.raw);
        learner.host.correctedRowOf(learner.host.judged, zero_noise);
        lab.policyMeanAction(&policy, observation, no_applied_action, scratch, file_action);
        for (file_action, learner.host.raw, uncorrected) |file_value, learner_value, policy_value| {
            worst = @max(worst, @abs(file_value - learner_value));
            largest = @max(largest, @abs(learner_value));
            largest_correction = @max(largest_correction, @abs(learner_value - policy_value));
        }
    }
    report.print("\n  a flow run's policy file against its learner, {d} rows x {d} actions: worst difference {e} " ++
        "(largest action {e}, largest correction {e})\n", .{
        kit.rows,
        action_count,
        worst,
        largest,
        largest_correction,
    });
    try expect(largest_correction > 0);
    try expect(worst <= 1.0e-5 * @max(largest, 1.0e-3));
}

test "robot_track_resident: a flow step in recovery becomes teacher 3's example once the next step shows where it led" {
    // A learner with a flow and no planning, FPO's start hazard 0 - every exploring step of the flow's is teacher 3's,
    // so this checks the data alone. Character 0's first step makes no example: the critic reads a state beside its
    // OWN frame's goal - the one the step before aimed at - and the first step has no step before it. At its second
    // step its pending example holds exactly [own goal | goal | state | coefficients]: the goal of the first step,
    // then the goal and state it acts in now. The step after completes it with exactly the state it reached. A judged
    // step completes a pending example (the step before it was real) but starts none: the policy alone is no
    // teacher's.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .actor = .flow,
        .flow = .{ .hidden_width = 16, .fpo_rows = 8, .fpo_examples = 64, .fpo_start_hazard = 0 },
    });
    defer learner.deinit();
    // The first step: the goal it aims at becomes the next state's own goal; no example yet.
    learner.features(0);
    const own_goal: []f32 = try gpa.dupe(f32, learner.host.goal);
    defer gpa.free(own_goal);
    learner.act(1, 1.0);
    try expect(!learner.fpo_pending_valid[0]);
    // The second step: [own goal | goal | state | coefficients], pending.
    learner.features(0);
    const goal: []f32 = try gpa.dupe(f32, learner.host.goal);
    defer gpa.free(goal);
    const state: []f32 = try gpa.dupe(f32, learner.host.z);
    defer gpa.free(state);
    learner.act(1, 1.0);
    try expect(learner.fpo_pending_valid[0]);
    const synergy_count: usize = learner.host.flow_coefficients.len;
    // The goals as wide as the kit's lead: the features and the root target's slots.
    const g: usize = learner.kit.lead;
    const pending_width: usize = 2 * g + f + synergy_count;
    const pending: []const f32 = learner.fpo_pending[0..pending_width];
    try expectEqualSlices(f32, own_goal, pending[0..g]);
    try expectEqualSlices(f32, goal, pending[g..][0..g]);
    try expectEqualSlices(f32, state, pending[2 * g ..][0..f]);
    const coefficients: []f32 = try gpa.dupe(f32, pending[2 * g + f ..][0..synergy_count]);
    defer gpa.free(coefficients);
    // The third step: the state reached completes it; character 0 acts first, so its example goes where the ring
    // pointed.
    learner.features(0);
    const next_state: []f32 = try gpa.dupe(f32, learner.host.z);
    defer gpa.free(next_state);
    const kept_at: usize = learner.fpo_next;
    learner.act(1, 1.0);
    try expect(learner.fpo_example_count >= 1);
    const example_width: usize = pending_width + f;
    const example: []const f32 = learner.fpo_examples[kept_at * example_width ..][0..example_width];
    try expectEqualSlices(f32, own_goal, example[0..g]);
    try expectEqualSlices(f32, goal, example[g..][0..g]);
    try expectEqualSlices(f32, state, example[2 * g ..][0..f]);
    try expectEqualSlices(f32, coefficients, example[2 * g + f ..][0..synergy_count]);
    try expectEqualSlices(f32, next_state, example[pending_width..][0..f]);
    // A judged step: it completes the pending example from the step before, and starts none.
    try expect(learner.fpo_pending_valid[0]);
    const examples_before: usize = learner.fpo_example_count;
    learner.act(1, 0.0);
    try expect(learner.fpo_example_count > examples_before);
    try expect(!learner.fpo_pending_valid[0]);
}

/// The mean and the sample deviation (divided by count - 1) of `values`, summed in their order - as
/// `stat_mean_and_deviation` sums them.
fn meanAndSampleDeviation(values: []const f32) [2]f32 {
    var sum: f32 = 0;
    for (values) |value| {
        sum += value;
    }
    const mean: f32 = sum / float(values.len);
    var squares: f32 = 0;
    for (values) |value| {
        squares += (value - mean) * (value - mean);
    }
    const deviation: f32 = if (values.len >= 2) @sqrt(squares / float(values.len - 1)) else 0;
    return .{ mean, deviation };
}

test "robot_track_resident: teacher 3's round start - every draw holds its example, the old losses the round's start" {
    // A learner with a flow and its critic, FPO's start hazard 0 so its examples come from the first steps. One round:
    // its start broadcasts each example's condition and coefficients to its draws' rows and takes the old losses and
    // the advantages before any update. After the round, every draw row must hold its example's condition and
    // coefficients; the old losses must be the draw losses at the weights the round started from - recomputed on the
    // same rows with those weights uploaded again, to the bit; and the advantages must be finite, and normalised over
    // the batch to mean 0 and sample deviation 1.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .train_critic = true,
        .actor = .flow,
        .flow = .{ .hidden_width = 16, .fpo_rows = 4, .fpo_examples = 64, .fpo_draws = 3, .fpo_start_hazard = 0 },
    });
    defer learner.deinit();
    // Everything back, on the CPU twin.
    host.element_count = 0xffff_ffff;
    // Examples, then the weights the round will start from (acting changes none).
    learner.act(8, 1.0);
    try expect(learner.fpo_example_count > 0);
    const params_now: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const starting_params: []f32 = try gpa.dupe(f32, params_now);
    defer gpa.free(starting_params);
    learner.simulateAndTrain();
    const flow_actor: kit_mod.FlowActor(zn_mlp) = learner.kit.flow_actor.?;
    const fpo: kit_mod.FlowActor(zn_mlp).Fpo = flow_actor.learning.?.fpo.?;
    try expect(fpo.has_batch);
    const update: kit_mod.FlowActor(zn_mlp).Fpo.Update = fpo.update.?;
    const trainer = update.trainer;
    const columns: kit_mod.FlowActor(zn_mlp).Fpo.Columns = fpo.exampleColumns();
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    // 1. Every draw row holds its example's condition - its goal, as wide as the kit's lead, and its state - and its
    // coefficients.
    const condition_width: usize = learner.kit.lead + f;
    const synergy_count: usize = fpo.synergy_count;
    const wide_width: usize = flow_actor.flow.wideRowWidth();
    for (0..fpo.rows) |example_index| {
        const example: []const f32 = acts[fpo.examples_at + example_index * columns.width ..][0..columns.width];
        for (0..update.draws) |draw| {
            const row: usize = example_index * update.draws + draw;
            const wide_row: []const f32 = acts[trainer.wide_rows_at + row * wide_width ..][0..condition_width];
            try expectEqualSlices(f32, example[columns.goal..][0..condition_width], wide_row);
            const action_row: []const f32 = acts[trainer.actions_at + row * synergy_count ..][0..synergy_count];
            try expectEqualSlices(f32, example[columns.coefficients..][0..synergy_count], action_row);
        }
    }
    // 3. The advantages, finite; normalised over the batch - mean 0, sample deviation 1.
    const advantage: kit_mod.FlowActor(zn_mlp).Fpo.Advantage = fpo.advantage.?;
    for (acts[advantage.advantages_at..][0..fpo.rows]) |value| {
        try expect(value == value and @abs(value) < 1e6);
    }
    const normalised: []const f32 = acts[update.advantages_at..][0..fpo.rows];
    var sum: f32 = 0;
    for (normalised) |value| {
        sum += value;
    }
    const normalised_mean: f32 = sum / float(fpo.rows);
    var squares: f32 = 0;
    for (normalised) |value| {
        squares += (value - normalised_mean) * (value - normalised_mean);
    }
    const normalised_deviation: f32 = @sqrt(squares / float(fpo.rows - 1));
    try expectApproxEqAbs(@as(f32, 0), normalised_mean, 1e-5);
    try expectApproxEqAbs(@as(f32, 1), normalised_deviation, 1e-4);
    // 4. The device's numbers for the log, each against the host's arithmetic on the same buffers: the old losses'
    //    and the raw advantages' mean and sample deviation (the round's start); the ratios' mean and the share the clip
    //    holds, and FlowDPG's velocity gradient's root mean square (the round's last update). And the learner's own
    //    copy, refreshed from the readback, is the block.
    const DeviceStats = kit_mod.DeviceStats;
    const stats_readback: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const stats: []const f32 = stats_readback[learner.stats_at..][0..DeviceStats.floats];
    const old_moments: [2]f32 = meanAndSampleDeviation(acts[update.old_losses_at..][0..fpo.rows]);
    try expectApproxEqRel(old_moments[0], stats[DeviceStats.slot("fpo_old_loss_mean")], 1e-5);
    try expectApproxEqRel(old_moments[1], stats[DeviceStats.slot("fpo_old_loss_deviation")], 1e-5);
    const advantage_moments: [2]f32 = meanAndSampleDeviation(acts[advantage.advantages_at..][0..fpo.rows]);
    try expectApproxEqAbs(advantage_moments[0], stats[DeviceStats.slot("fpo_advantage_mean")], 1e-5);
    try expectApproxEqRel(advantage_moments[1], stats[DeviceStats.slot("fpo_advantage_deviation")], 1e-5);
    var ratio_sum: f32 = 0;
    var held: f32 = 0;
    for (0..fpo.rows) |example| {
        const ratio: f32 = @exp(acts[update.old_losses_at + example] - acts[update.new_losses_at + example]);
        const example_advantage: f32 = acts[update.advantages_at + example];
        const clipped_ratio: f32 = clamp(ratio, 1 - fpo.clip, 1 + fpo.clip);
        ratio_sum += ratio;
        held += if (ratio * example_advantage <= clipped_ratio * example_advantage) 0 else 1;
    }
    const examples_count: f32 = float(fpo.rows);
    try expectApproxEqRel(ratio_sum / examples_count, stats[DeviceStats.slot("fpo_ratio_mean")], 1e-5);
    try expectEqual(held / examples_count, stats[DeviceStats.slot("fpo_clipped_share")]);
    const dacts: []const f32 = host.readLatest(.dacts) orelse return error.NoReadback;
    const dpg_trainer: @TypeOf(flow_actor.learning.?.trainer) = flow_actor.learning.?.trainer;
    const gradient_count: usize = dpg_trainer.rows * flow_actor.flow.action_width;
    var gradient_squares: f32 = 0;
    for (dacts[dpg_trainer.velocity_gradient_at..][0..gradient_count]) |value| {
        gradient_squares += value * value;
    }
    const gradient_rms: f32 = @sqrt(gradient_squares / float(gradient_count));
    try expect(gradient_rms > 0);
    try expectApproxEqRel(gradient_rms, stats[DeviceStats.slot("flow_dpg_gradient_rms")], 1e-5);
    try expectEqual(stats[DeviceStats.slot("fpo_ratio_mean")], learner.device_stats.fpo_ratio_mean);
    try expectEqual(stats[DeviceStats.slot("flow_dpg_gradient_rms")], learner.device_stats.flow_dpg_gradient_rms);
    // 2. The old losses: the draw losses at the starting weights, on the same rows.
    const old_losses: []f32 = try gpa.dupe(f32, acts[update.old_losses_at..][0..fpo.rows]);
    defer gpa.free(old_losses);
    host.upload(.params, starting_params);
    flow_actor.flow.drawLosses(&host, trainer, update.draws, update.old_losses_at);
    const recomputed_acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    try expectEqualSlices(f32, old_losses, recomputed_acts[update.old_losses_at..][0..fpo.rows]);
}

/// Every value that leans on the critic, as `learner` holds it now, against its full setting times `trust`.
fn expectCriticTrust(learner: *const Resident(zn_mlp), trust: f32) !void {
    const options: resident.Options = learner.options;
    const value_tail: kit_mod.LatentCritic(zn_mlp).Tail = learner.kit.value_tail.?;
    try expectEqual(options.value_tail * trust, value_tail.weight);
    try expectEqual(options.value_tail_pessimism * trust, value_tail.pessimism);
    const scorer_options: kit_mod.TrackingScorer(zn_mlp).Options = learner.planner.?.scorer.options;
    try expectEqual(trust, scorer_options.tail_weight);
    try expectEqual(options.value_tail_pessimism * trust, scorer_options.pessimism);
    const learning: kit_mod.FlowActor(zn_mlp).Learning = learner.kit.flow_actor.?.learning.?;
    try expectEqual(options.planning.distill_weight * trust, learning.distillation.?.weight);
    try expectEqual(options.flow.fpo_weight * trust, learning.fpo.?.weight);
}

test "robot_track_resident: trust in the critic weighs everything that leans on it, from nothing to whole" {
    // A learner with its critic's tail and its pessimism, a planner, and a flow with teachers 2 and 3; the ramp four
    // policy updates. Built, before any update, every one of them is at nothing - the tail's weight and pessimism,
    // the planner's tail weight and pessimism, teacher 2's and teacher 3's weights. After each round each is its full
    // setting times min(1, updates / 4), and whole once the ramp is past.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .train_critic = true,
        .value_tail = 0.8,
        .value_tail_pessimism = 0.5,
        .value_tail_ramp_updates = 4,
        .actor = .flow,
        .flow = .{ .hidden_width = 16, .fpo_rows = 4, .fpo_examples = 64, .fpo_weight = 0.2 },
        .planning = .{
            .enabled = true,
            .flags = .{ .start_hazard = 0.5, .stop_hazard = 0.25, .calm_steps = 10, .budget = 2, .replan_every = 4 },
            .candidates = 8,
            .horizon = 4,
            .rounds = 1,
            .elites = 2,
            .distill_weight = 0.5,
        },
    });
    defer learner.deinit();
    try expectCriticTrust(learner, 0);
    while (learner.policy_updates < 6) {
        learner.simulateAndTrain();
        const trust: f32 = @min(1.0, float(learner.policy_updates) / 4.0);
        try expectCriticTrust(learner, trust);
    }
    try expectCriticTrust(learner, 1);
}

test "robot_track_resident: the planner scores every prefix - its costs and the critic at every depth recombined" {
    // A learner with its critic and a planner whose objective is EfficientTDMPC's mean over every prefix of a plan;
    // the critic's trust whole after one update. Trained until it is, then character 0 pushed until a decision of
    // its own: the weights that decision uploaded must be the mean over depths' (`zimrrl.planObjectiveWeights` at the
    // critic's discount) negated, the critic's at the tail's full weight; and every candidate's score must be those
    // weights on the step costs and on the critic heads' mean at EVERY depth - recombined here from what the device
    // left, to a few parts in a hundred thousand.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .train_critic = true,
        .value_tail = 1.0,
        .value_tail_ramp_updates = 1,
        .planning = .{
            .enabled = true,
            .flags = .{ .start_hazard = 0.5, .stop_hazard = 0.25, .calm_steps = 10, .budget = 4, .replan_every = 4 },
            .candidates = 8,
            .horizon = 4,
            .rounds = 1,
            .elites = 2,
            .objective = .mean_over_depths,
        },
    });
    defer learner.deinit();
    while (learner.policy_updates < 2) {
        learner.simulateAndTrain();
    }
    const decisions_before: u64 = learner.planning_decisions;
    fleet.push(0, 4.0, 0.0);
    var decided: bool = false;
    for (0..120) |_| {
        learner.act(1, 1.0);
        if (learner.planning_decisions > decisions_before) {
            decided = true;
            break;
        }
    }
    try expect(decided);
    host.element_count = 0xffff_ffff;
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const planner: kit_mod.TrackingPlanner(zn_mlp) = learner.planner.?;
    const scorer: kit_mod.TrackingScorer(zn_mlp) = planner.scorer;
    const horizon: u32 = scorer.options.horizon;
    const rows: u32 = scorer.rowCount();
    const value_heads: u32 = scorer.value_heads;
    try expectEqual(@as(f32, 1), scorer.options.tail_weight);
    try expectEqual(learner.critic.?.options.discount, scorer.options.discount);
    // The weights: the mean over depths, negated - the critic's at the tail's whole weight.
    var cost_weights: [4]f32 = undefined;
    var value_weights: [4]f32 = undefined;
    try zrl.planObjectiveWeights(f32, .mean_over_depths, scorer.options.discount, &cost_weights, &value_weights);
    const uploaded: []const f32 = acts[scorer.weights_at..][0 .. 2 * horizon];
    for (0..horizon) |step| {
        try expectEqual(-cost_weights[step], uploaded[step]);
        try expectEqual(-value_weights[step], uploaded[horizon + step]);
    }
    // Every candidate's score from the step costs and the critic heads' mean at every depth.
    for (0..rows) |row| {
        var expected: f32 = 0;
        for (0..horizon) |step| {
            const cost: f32 = acts[scorer.step_costs_at + step * rows + row];
            try expect(cost == cost);
            expected += uploaded[step] * cost;
        }
        for (0..horizon) |depth_index| {
            var head_sum: f32 = 0;
            for (0..value_heads) |head| {
                const value_at: usize = scorer.values_at + (depth_index * value_heads + head) * rows + row;
                const value: f32 = acts[value_at];
                try expect(value == value);
                head_sum += value;
            }
            const head_mean: f32 = head_sum / float(value_heads);
            expected += uploaded[horizon + depth_index] * head_mean;
        }
        const score: f32 = acts[scorer.scores_at + row];
        const gap: f32 = @abs(score - expected) / @max(@abs(expected), 1e-3);
        try expect(gap < 1e-4);
    }
}

test "robot_track_resident: the skip model learns beside the world model, and a saved state carries it" {
    // A learner with a skip model of 4 steps in its 8-step windows (two jumps a window). Trained six world model
    // updates: the skip model's loss is finite and falls from its first update's, and the gate's pair - its first
    // jump's error and the world model's rolled the same steps - is recorded. Saved, then loaded by a fresh learner
    // on the same pipe: the trained skip model's weights are the loaded learner's, number for number, and saving again
    // writes the same bytes.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    const learner_options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .skip_span = 4,
        .world_form = .dense_tanh,
    };
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    var trained_skip_weights: []f32 = &.{};
    defer gpa.free(trained_skip_weights);
    const saved_state: []u8 = saved: {
        const learner: *Resident(zn_mlp) =
            try .init(gpa, &host, fleet, .{ .mean = means, .spread = spreads }, learner_options);
        defer learner.deinit();
        try expect(learner.kit.skip_model != null);
        var first_loss: ?f32 = null;
        var rounds: usize = 0;
        const world_updates_wanted: u32 = 6;
        const most_rounds: usize = 20;
        while (learner.world_updates < world_updates_wanted and rounds < most_rounds) : (rounds += 1) {
            learner.simulateAndTrain();
            learner.waitForReadback();
            const loss: f32 = learner.device_stats.skip_model_loss;
            try expect(loss == loss and loss >= 0);
            if (first_loss == null and loss > 0) {
                first_loss = loss;
            }
        }
        const latest: kit_mod.DeviceStats = learner.device_stats;
        try expect(first_loss != null);
        try expect(latest.skip_model_loss < first_loss.?);
        try expect(latest.skip_model_jump_error > 0 and latest.world_model_span_error > 0);
        report.print("\n  skip model: loss {e} -> {e}; first jump {e}, the world model rolled 4 steps {e}\n", .{
            first_loss.?,
            latest.skip_model_loss,
            latest.skip_model_jump_error,
            latest.world_model_span_error,
        });
        const skip_model: kit_mod.SkipModel(zn_mlp) = learner.kit.skip_model.?;
        const parameters: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
        const skip_range: []const f32 = parameters[skip_model.network.paramsStart()..skip_model.network.paramsEnd()];
        trained_skip_weights = try gpa.dupe(f32, skip_range);
        try expect(skip_model.network.paramsEnd() <= learner.params_end);
        break :saved try learner.exportState(gpa);
    };
    defer gpa.free(saved_state);
    const resumed: *Resident(zn_mlp) =
        try .init(gpa, &host, fleet, .{ .mean = means, .spread = spreads }, learner_options);
    defer resumed.deinit();
    try poisonLearnerBuffers(gpa, &host, resumed);
    try resumed.importState(gpa, saved_state);
    const resumed_skip: kit_mod.SkipModel(zn_mlp) = resumed.kit.skip_model.?;
    const resumed_parameters: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const resumed_range: []const f32 =
        resumed_parameters[resumed_skip.network.paramsStart()..resumed_skip.network.paramsEnd()];
    try expectEqualSlices(f32, trained_skip_weights, resumed_range);
    const saved_again: []u8 = try resumed.exportState(gpa);
    defer gpa.free(saved_again);
    try expect(eql(u8, saved_again, saved_state));
}

/// The world model's and the policy's weights after `rounds` rounds of a learner with `options`, on a fleet set up
/// afresh - a copy in `gpa`, the caller's to free.
fn trainedNetworkWeights(
    gpa: Allocator,
    options: resident.Options,
    rounds: usize,
) ![]f32 {
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = means, .spread = spreads }, options);
    defer learner.deinit();
    for (0..rounds) |_| {
        learner.simulateAndTrain();
    }
    learner.waitForReadback();
    const parameters: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const network_floats: usize = learner.kit.param_count + learner.kit.policy_count;
    return gpa.dupe(f32, parameters[0..network_floats]);
}

test "robot_track_resident: the skip head changes nothing the world model and the policy learn - to the bit" {
    // Two learners on fleets set up alike, both with the dense world model the head reads, one with a skip head of 4
    // steps: after three rounds the world model's and the policy's weights must be the same numbers. The head reads the
    // world model's layers but sends no gradient back, and its starting weights come from a stream of their own - so
    // all it adds is itself.
    const gpa: Allocator = testing_allocator;
    const without_head: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .world_form = .dense_tanh,
    };
    var with_head: resident.Options = without_head;
    with_head.skip_span = 4;
    const rounds: usize = 3;
    const plain_weights: []f32 = try trainedNetworkWeights(gpa, without_head, rounds);
    defer gpa.free(plain_weights);
    const headed_weights: []f32 = try trainedNetworkWeights(gpa, with_head, rounds);
    defer gpa.free(headed_weights);
    try expectEqualSlices(f32, plain_weights, headed_weights);
}

test "robot_track_resident: two clips in one run - every character keeps its own, every record reads its own rows" {
    // The learner on a fleet of two different clips, each character fixed to one (character i on clip i mod 2). After
    // 300 exploring steps - with restarts among them - every step the replay holds is on its character's clip, and
    // every record the learner last staged reads a table row inside that clip's rows. A gathered window is one
    // character's consecutive records, so it stays inside one clip with them.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.initTwoClips(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
    });
    defer learner.deinit();
    learner.act(300, 1.0);
    try expect(learner.failures > 0);
    const clip_count: usize = fleet.clips.len;
    try expectEqual(@as(usize, 2), clip_count);
    for (0..fleet.options.envs) |env| {
        const own_clip: usize = env % clip_count;
        const written: u64 = fleet.replay.written[env];
        const oldest: u64 = written -| fleet.replay.capacity;
        var index: u64 = oldest;
        while (index < written) : (index += 1) {
            try expectEqual(@as(u16, @intCast(own_clip)), fleet.replay.clipAt(env, index));
        }
        // The record the learner last staged for this character: its table row inside its clip's rows.
        const data: @TypeOf(learner.data) = learner.data;
        const record: []const f32 = data.staging[env * data.ring.record ..][0..data.ring.record];
        const table_row: u32 = @trunc(record[zn_mlp.latRecordTableRow(data.features, data.actions)]);
        const first_row: u32 = data.clip_rows[own_clip];
        const row_count: u32 = @intCast(fleet.clips[own_clip].frame_count);
        try expect(table_row >= first_row and table_row < first_row + row_count);
    }
}

test "robot_track_resident: a policy imagining 32 steps, a world model learning 8 - a round trains, resumes exactly" {
    // SuperMimic's horizons: a world model fit on windows of 8, a policy imagining 32 with the critic's tail past
    // them. The kit is as long as the policy's horizon and its world model's passes stop at 8; the windows drawn are
    // 32 long. A round trains both networks with finite weights; and a second learner given the first's state writes
    // back the very same bytes - the policy's horizon among the options they hold.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    // A replay long enough for 32-step windows.
    setup.fleet.deinit();
    setup.fleet = try track.Fleet.init(gpa, &setup.imported.model, &.{&setup.clip}, .{ .envs = 4, .capacity = 256 });
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    const learner_options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .policy_window = 32,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 48,
        .train_critic = true,
        .value_tail = 0.5,
    };
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const normalizer: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, normalizer, learner_options);
    defer learner.deinit();
    try expectEqual(@as(u32, 32), learner.kit.steps);
    try expectEqual(@as(u32, 8), learner.kit.world_steps);
    var rounds: u32 = 0;
    while (learner.policy_updates < 2 and rounds < 20) : (rounds += 1) {
        learner.simulateAndTrain();
    }
    try expect(learner.world_updates >= 2 and learner.policy_updates >= 2);
    learner.waitForReadback();
    const params: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    for (params[0..learner.params_end]) |weight| {
        try expect(weight == weight and @abs(weight) < 1e6);
    }
    // The policy's gradient's length before clipping, for the log: positive and finite.
    learner.refreshDeviceStats();
    const gradient_norm: f32 = learner.device_stats.policy_gradient_norm;
    try expect(gradient_norm > 0 and gradient_norm < 1e9);
    // The critic's numbers and the policy's barrier and tail, for the log: every one finite, the critic's error
    // positive (an untrained critic is wrong), the heads' spread and the barrier's hinge never below zero.
    const stats: kit_mod.DeviceStats = learner.device_stats;
    const numbers = [_]f32{
        stats.critic_value_mean,
        stats.critic_head_spread,
        stats.critic_value_error,
        stats.policy_barrier_hinge,
        stats.policy_tail_value,
        stats.policy_tail_deviation,
    };
    for (numbers) |number| {
        try expect(number == number and @abs(number) < 1e9);
    }
    try expect(stats.critic_value_error > 0);
    try expect(stats.critic_head_spread >= 0 and stats.policy_barrier_hinge >= 0);
    // Resumed: the same bytes back.
    const saved_state: []u8 = try learner.exportState(gpa);
    defer gpa.free(saved_state);
    var resumed_host: compute_host.Compute(zn_mlp) = .initCpu();
    const resumed_learner: *Resident(zn_mlp) =
        try .init(gpa, &resumed_host, fleet, normalizer, learner_options);
    defer resumed_learner.deinit();
    try poisonLearnerBuffers(gpa, &resumed_host, resumed_learner);
    try resumed_learner.importState(gpa, saved_state);
    const state_saved_again: []u8 = try resumed_learner.exportState(gpa);
    defer gpa.free(state_saved_again);
    try expectEqualSlices(u8, saved_state, state_saved_again);
}

test "robot_track_resident: the policy's rate boost - held, ramped to 1, then 1; none by default" {
    // XMimic's boost (`RateBoost`): 4 for 1,400 rounds, then a straight ramp to 1 over 300 - its two ends and its
    // middle, worked by hand; a ramp of no rounds drops to 1 at once; the default multiplies nothing.
    const xmimic: resident.RateBoost = .{ .multiplier = 4, .held_rounds = 1400, .ramp_rounds = 300 };
    try expectEqual(@as(f32, 4), xmimic.at(0));
    try expectEqual(@as(f32, 4), xmimic.at(1399));
    try expectEqual(@as(f32, 4), xmimic.at(1400));
    try expectEqual(@as(f32, 2.5), xmimic.at(1550));
    try expectApproxEqAbs(@as(f32, 1.01), xmimic.at(1699), 1e-6);
    try expectEqual(@as(f32, 1), xmimic.at(1700));
    try expectEqual(@as(f32, 1), xmimic.at(1_000_000));
    const no_ramp: resident.RateBoost = .{ .multiplier = 4, .held_rounds = 10, .ramp_rounds = 0 };
    try expectEqual(@as(f32, 4), no_ramp.at(9));
    try expectEqual(@as(f32, 1), no_ramp.at(10));
    const default_boost: resident.RateBoost = .{};
    try expectEqual(@as(f32, 1), default_boost.at(0));
    try expectEqual(@as(f32, 1), default_boost.at(5000));
}

test "robot_track_resident: the warm-up folds the statistics and updates nothing, and the round after it trains" {
    // A warm-up of 24 decisions (`Options.warmup_decisions`) at 12 collected a round: the first round leaves every
    // network's weight as it was, bit for bit, and makes no update and refuses no window - none is drawn - while the
    // world model's running statistics fold its transitions (their counts above 0); the second round, with 24 held,
    // updates the world model and the policy once each.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 12,
        .warmup_decisions = 24,
    });
    defer learner.deinit();
    host.element_count = @max(learner.data.end, learner.params_end);
    const network_floats: usize = learner.kit.param_count + learner.kit.policy_count;
    // Copies, not slices: the CPU pipe's buffers are shared by everything that runs on it.
    const starting_params: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    const weights_before: []f32 = try gpa.dupe(f32, starting_params[0..network_floats]);
    defer gpa.free(weights_before);
    try expect(learner.warmingUp());
    // THE WARM-UP's ROUND.
    learner.simulateAndTrain();
    try expectEqual(@as(u64, 12), learner.decisionsHeld());
    try expect(learner.warmingUp());
    try expectEqual(@as(u32, 0), learner.world_updates);
    try expectEqual(@as(u32, 0), learner.policy_updates);
    try expectEqual(@as(u64, 0), learner.windows_refused);
    // No round of training yet: the rate boost's clock has not started.
    try expectEqual(@as(u64, 0), learner.training_rounds);
    const after_warmup: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    try expectEqualSlices(f32, weights_before, after_warmup[0..network_floats]);
    // The running statistics folded the round's transitions: the first input column's count is above 0.
    const folded_count: f32 = after_warmup[learner.input_moments_at];
    try expect(folded_count > 0);
    // THE FIRST ROUND PAST IT.
    learner.simulateAndTrain();
    try expectEqual(@as(u64, 24), learner.decisionsHeld());
    try expect(!learner.warmingUp());
    try expectEqual(@as(u32, 1), learner.world_updates);
    try expectEqual(@as(u32, 1), learner.policy_updates);
    try expectEqual(@as(u64, 1), learner.training_rounds);
    const trained: []const f32 = host.readLatest(.params) orelse return error.NoReadback;
    try expect(!eql(f32, weights_before, trained[0..network_floats]));
}

test "robot_track_resident: the rates' schedule - every network's rate on its cosine, the floor after it" {
    // A learner with a critic and a flow, its rates on a cosine over four updates to 0.03 of their bases. After each
    // round, the critic's rate is its base times the schedule's share at the critic's own count, and the flow's at
    // the policy's - the cosine schedule's rate for a base of 1 (`zn.cosineLearningRate`); past the fourth update,
    // both at 0.03 of their bases.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner_options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .train_critic = true,
        .actor = .flow,
        .flow = .{ .hidden_width = 16 },
        .rate_decay_updates = 4,
        .rate_floor_share = 0.03,
    };
    const normalizer: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, normalizer, learner_options);
    defer learner.deinit();
    const critic_base: f32 = learner_options.critic.learning_rate;
    const flow_base: f32 = learner_options.flow.learning_rate;
    var rounds: u32 = 0;
    while (learner.policy_updates < 6 and rounds < 30) : (rounds += 1) {
        learner.simulateAndTrain();
        if (learner.critic_updates == 0 or learner.policy_updates == 0) {
            continue;
        }
        const critic_share: f32 = zn.cosineLearningRate(f32, learner.critic_updates, 4, 1, 0.03);
        const flow_share: f32 = zn.cosineLearningRate(f32, learner.policy_updates, 4, 1, 0.03);
        try expectEqual(critic_base * critic_share, learner.critic.?.options.learning_rate);
        const teacher = learner.kit.flow_actor.?.learning.?.teacher;
        try expectEqual(flow_base * flow_share, teacher.learning_rate);
    }
    try expect(learner.policy_updates >= 6);
    try expectEqual(critic_base * 0.03, learner.critic.?.options.learning_rate);
    try expectEqual(flow_base * 0.03, learner.kit.flow_actor.?.learning.?.teacher.learning_rate);
}

test "robot_track_resident: a planning decision waits for its round's last step - stamped with it, planned from it" {
    // The planning tests' learner (`planningLearner`), character 0 pushed, acting in rounds of twelve steps. The push's
    // hazard crosses the start partway through a round; the decision falling due there waits for the round's LAST
    // step, so the round that decides leaves in the mailbox a stamp of that step plus one - its plans start from the
    // states the round ends in.
    const options = @import("build_options");
    const slow: bool = comptime @hasDecl(options, "slow_tests") and options.slow_tests;
    if (!slow) {
        return error.SkipZigTest;
    }
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    fleet.head = 1;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try planningLearner(gpa, &host, fleet, mean, spread, 10);
    defer learner.deinit();
    fleet.push(0, 4.0, 0.0);
    var has_decided: bool = false;
    var rounds: u32 = 0;
    while (!has_decided and rounds < 20) : (rounds += 1) {
        const decisions_before: u64 = learner.planning_decisions;
        learner.act(12, 1.0);
        if (learner.planning_decisions == decisions_before) {
            continue;
        }
        learner.waitForReadback();
        learner.refreshMailbox();
        const stamp: u32 = @bitCast(learner.mailbox_copy[0]);
        const round_last_step: u32 = @truncate(learner.acting_steps);
        try expectEqual(round_last_step, stamp - 1);
        has_decided = true;
    }
    try expect(has_decided);
}

test "robot_track_resident: the policy's starts inside returns - all of them at a share of 1, before a loss at 0" {
    // A learner on a fleet with an aftermath and returns, its untrained policy falling. With every start to be drawn
    // inside a return, each start the policy stages is a record after a loss; with none, the policy stages exactly
    // the starts `before_loss` draws from the same random stream (`track.Replay.Books.sampleStart`) - a learner
    // without returns takes nothing more from it.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    setup.fleet.deinit();
    const m: *rbt.Model = &setup.imported.model;
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 4,
        .capacity = 512,
        .aftermath_steps = 60,
        .return_steps = 8,
    });
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const normaliser: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const learner: *Resident(zn_mlp) = try Resident(zn_mlp).init(gpa, &host, fleet, normaliser, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .return_window_share = 1,
    });
    defer learner.deinit();
    learner.act(300, 1.0);
    try expect(fleet.failed > 0);
    try expectEqual(@as(f32, 1), learner.returnWindowShare());
    try expect(learner.drawPolicyStarts(0));
    for (learner.starts) |start| {
        try expect(fleet.replay.afterLossAt(start.env, start.index));
    }
    // A share of 0: the starts `before_loss` draws from the same stream, one draw a start - the ring holds every
    // record, so none is drawn again - and nothing else taken from it.
    learner.options.return_window_share = 0;
    const stream_before: Random.DefaultPrng = learner.rng;
    try expect(learner.drawPolicyStarts(0));
    var stream: Random.DefaultPrng = stream_before;
    var books: track.Replay.Books = fleet.replay.books();
    books.clip_frames = learner.clip_frame_counts;
    const frames_needed: u32 = learner.policy_window_records * learner.data.decision_frames;
    for (learner.starts) |start| {
        const drawn: track.Replay.Window =
            books.sampleStart(stream.random(), frames_needed, .before_loss) orelse return error.NoStart;
        try expectEqual(@as(usize, start.env), drawn.env);
        try expectEqual(start.index, drawn.first);
        try expect(!fleet.replay.afterLossAt(start.env, start.index));
    }
}

test "robot_track_resident: a policy's start gathers what its window would - goals, references, roots, action before" {
    // A learner on a real fleet, the root target on. Windows of the policy's horizon that stay in one segment, drawn
    // from its replay, are staged as windows (`stageStarts`) and gathered - the reference; their first records are then
    // staged as starts (`stagePolicyStarts`) and gathered again, over blocks first filled with NaN. A start's rows come
    // from the clip's tables, a window's from its records: along an unbroken horizon they are the same rows, so the
    // first state, every goal and reference, the root's blocks and the action given before the start - all a rollout
    // reads - are the window's to the bit, and none is left unwritten.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    for (mean, spread, 0..) |*mu, *sigma, c| {
        mu.* = 0.01 * float(c % 13) - 0.05;
        sigma.* = 0.5 + 0.03 * float(c % 17);
    }
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = mean, .spread = spread }, .{
        .rows = 8,
        .window = 8,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 4,
        .root_target = true,
    });
    defer learner.deinit();
    host.element_count = @max(learner.data.end, learner.params_end);
    learner.act(30, 1.0);
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const root: kit_mod.LatentKit(zn_mlp).ImaginedRoot = kit.imagined_root orelse return error.NoImaginedRoot;
    // THE WINDOWS: the policy's horizon, before a loss, every record in one segment and in the ring.
    const horizon: u32 = learner.policy_window_records;
    const books: track.Replay.Books = fleet.replay.books();
    const range: kit_mod.RecordRing.HeldSteps = learner.data.ring.held() orelse return error.NoRecords;
    var rng: Random.DefaultPrng = .init(11);
    for (learner.starts) |*start| {
        var tries: u32 = 0;
        start.* = while (tries < 64) : (tries += 1) {
            const window: track.Replay.Window =
                books.sampleWindowStarting(rng.random(), horizon, .before_loss) orelse return error.NoWindow;
            if (resident.windowStartInRing(books, range, window, horizon)) |in_ring| {
                break in_ring;
            }
        } else return error.NoWindow;
    }
    learner.data.stageStarts(learner.starts, 0, horizon);
    learner.data.gather(kit, 0);
    const acts_floats: usize = learner.buffers_used.acts_floats;
    const from_windows: []f32 = try gpa.alloc(f32, acts_floats);
    defer gpa.free(from_windows);
    host.readRange(.acts, 0, from_windows);
    // THE STARTS, over blocks of NaN: whatever the starts' gather leaves unwritten stays NaN, equal to nothing.
    const poison: []f32 = try gpa.alloc(f32, acts_floats);
    defer gpa.free(poison);
    @memset(poison, nan(f32));
    const kit_blocks: u32 = kit.total - kit.x_at;
    host.uploadAt(.acts, kit.x_at, poison[0..kit_blocks]);
    const root_floats: u32 = kit_mod.LatentKit(zn_mlp).ImaginedRoot.rootBlockFloats(kit.steps, kit.rows);
    const goal_root_floats: u32 = kit_mod.LatentKit(zn_mlp).ImaginedRoot.goalRootBlockFloats(kit.steps, kit.rows);
    host.uploadAt(.acts, root.roots_at, poison[0..root_floats]);
    host.uploadAt(.acts, root.goal_roots_at, poison[0..goal_root_floats]);
    learner.data.stagePolicyStarts(learner.starts, 1, horizon);
    learner.data.gather(kit, 1);
    const from_starts: []f32 = try gpa.alloc(f32, acts_floats);
    defer gpa.free(from_starts);
    host.readRange(.acts, 0, from_starts);
    // TO THE BIT, region by region.
    const rows: u32 = kit.rows;
    const lead: u32 = kit.lead;
    const features: u32 = kit.features;
    const references: u32 = kit.references;
    var checks: report.Checks = .{};
    for (0..rows) |row| {
        const first_state_at: usize = kit.blockX(0) + row * kit.width + lead;
        const state_alike: bool =
            eql(f32, from_windows[first_state_at..][0..features], from_starts[first_state_at..][0..features]);
        checks.holds(state_alike, "row {d}: the first state differs\n", .{row});
        for (0..horizon) |step| {
            const wide_row_at: usize = kit.blockX(@intCast(step)) + row * kit.width;
            const goal_alike: bool =
                eql(f32, from_windows[wide_row_at..][0..lead], from_starts[wide_row_at..][0..lead]);
            checks.holds(goal_alike, "row {d} step {d}: the goal differs\n", .{ row, step });
            const reference_at: usize = wide_row_at + lead + features;
            const reference_alike: bool =
                eql(f32, from_windows[reference_at..][0..references], from_starts[reference_at..][0..references]);
            checks.holds(reference_alike, "row {d} step {d}: the reference differs\n", .{ row, step });
        }
    }
    const goal_block_floats: usize = horizon * rows * features;
    const goals_alike: bool =
        eql(f32, from_windows[kit.g_at..][0..goal_block_floats], from_starts[kit.g_at..][0..goal_block_floats]);
    checks.holds(goals_alike, "the goal block differs\n", .{});
    const pose_numbers: usize = zn_mlp.lat_root_pose_numbers;
    const first_roots: usize = rows * pose_numbers;
    const roots_alike: bool =
        eql(f32, from_windows[root.roots_at..][0..first_roots], from_starts[root.roots_at..][0..first_roots]);
    checks.holds(roots_alike, "the first roots differ\n", .{});
    const goal_roots: usize = horizon * rows * pose_numbers;
    const goal_roots_alike: bool =
        eql(f32, from_windows[root.goal_roots_at..][0..goal_roots], from_starts[root.goal_roots_at..][0..goal_roots]);
    checks.holds(goal_roots_alike, "the goals' roots differ\n", .{});
    const actions_before: usize = rows * kit.actions;
    const applied_alike: bool = eql(
        f32,
        from_windows[kit.start_actions_at..][0..actions_before],
        from_starts[kit.start_actions_at..][0..actions_before],
    );
    checks.holds(applied_alike, "the actions given before the starts differ\n", .{});
    try checks.finish();
}

test "robot_track_resident: steps in an aftermath are not watched - the time to failure counts only time at risk" {
    // A learner on a fleet with an aftermath and returns, its untrained policy falling, acting one step at a time:
    // after each step the fleet says which characters' steps were in an aftermath (`in_aftermath`), and the learner's
    // exposure must grow by the others only - every character's every step, less the aftermath's.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    setup.fleet.deinit();
    const m: *rbt.Model = &setup.imported.model;
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 4,
        .capacity = 256,
        .aftermath_steps = 40,
        .return_steps = 8,
    });
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const normaliser: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const learner: *Resident(zn_mlp) = try Resident(zn_mlp).init(gpa, &host, fleet, normaliser, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 16,
    });
    defer learner.deinit();
    var expected_exposure: u64 = 0;
    var aftermath_steps_seen: u64 = 0;
    for (0..200) |_| {
        learner.act(1, 1.0);
        for (fleet.in_aftermath) |after_loss| {
            if (after_loss) {
                aftermath_steps_seen += 1;
            } else {
                expected_exposure += 1;
            }
        }
    }
    try expect(aftermath_steps_seen > 0);
    try expectEqual(expected_exposure, learner.exposure);
}

test "robot_track_resident: the watchdog names what stopped being finite - a policy weight, then a device number" {
    // A fresh learner has nothing that is not finite. A not-a-number planted in its policy's weights on the device is
    // named as the policy's, from the newest readback; with the weights clean again, a device number not finite is
    // named by its field.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const normaliser: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const learner: *Resident(zn_mlp) = try Resident(zn_mlp).init(gpa, &host, fleet, normaliser, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 16,
    });
    defer learner.deinit();
    learner.waitForReadback();
    try expectEqual(@as(?[]const u8, null), learner.nonfiniteCause());
    // A policy weight not finite.
    const policy_weight_at: u32 = learner.kit.p_at + 3;
    const not_a_number: [1]f32 = .{nan(f32)};
    host.uploadAt(.params, policy_weight_at, &not_a_number);
    learner.waitForReadback();
    try expect(eql(u8, "the policy's weights", learner.nonfiniteCause().?));
    // The weight clean again, a device number not finite.
    const zero: [1]f32 = .{0};
    host.uploadAt(.params, policy_weight_at, &zero);
    learner.waitForReadback();
    learner.device_stats.world_model_loss = inf(f32);
    try expect(eql(u8, "world_model_loss", learner.nonfiniteCause().?));
}

test "robot_track_resident: FlowDPG hears the world model - the flow's cost gradients and velocity gradient move" {
    // A learner with a flow actor, acting and training a few rounds on the CPU: the policy's gradient at each action,
    // projected on the synergies (the flow's cost gradients), must not be all zero, nor FlowDPG's gradient at the
    // velocity - a flow at rest whose teacher hears nothing stays at rest.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const f: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const normaliser: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const learner: *Resident(zn_mlp) = try Resident(zn_mlp).init(gpa, &host, fleet, normaliser, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 16,
        .actor = .flow,
        .flow = .{ .hidden_width = 32 },
    });
    defer learner.deinit();
    const rounds: usize = 4;
    for (0..rounds) |_| {
        learner.simulateAndTrain();
    }
    learner.waitForReadback();
    const flow_actor: kit_mod.FlowActor(zn_mlp) = learner.kit.flow_actor.?;
    const trainer: @TypeOf(flow_actor.learningPart().trainer) = flow_actor.learningPart().trainer;
    // The CPU backend's buffers whole: the kernel module's own arrays (a readback is sliced to the learner's window).
    const acts: []const f32 = &zn_mlp.g.B.acts;
    const dacts: []const f32 = &zn_mlp.g.B.dacts;
    const gradient_floats: usize = trainer.rows * flow_actor.correction.synergy_count;
    var largest_cost_gradient: f32 = 0;
    for (acts[trainer.cost_gradients_at..][0..gradient_floats]) |value| {
        largest_cost_gradient = @max(largest_cost_gradient, @abs(value));
    }
    var largest_velocity_gradient: f32 = 0;
    for (dacts[trainer.velocity_gradient_at..][0..gradient_floats]) |value| {
        largest_velocity_gradient = @max(largest_velocity_gradient, @abs(value));
    }
    // A measurement, reported as every test reports one: a warning would mark the whole suite's run as failed.
    report.print("\n  FlowDPG: largest cost gradient {e}, largest velocity gradient {e}, world updates {d}\n", .{
        largest_cost_gradient,
        largest_velocity_gradient,
        learner.world_updates,
    });
    try expect(largest_cost_gradient > 0);
    try expect(largest_velocity_gradient > 0);
}

test "robot_track_resident: acting on four threads - the same actions and characters as on one, to the bit" {
    // Two learners with a flow, on fleets alike but for their tasks: one computes every character's action in one
    // loop, the other in four tasks on a pool of threads (`computeEveryAction`), its physics likewise. Every random
    // number is drawn first, in the characters' order, and each action is computed from its own numbers and the
    // shared weights in its task's own scratch - so after three rounds of acting, the actions chosen, every
    // character's state and the flow's drifting noise are the same in both, to the bit.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    setup.fleet.deinit();
    const m: *rbt.Model = &setup.imported.model;
    setup.fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{ .envs = 8, .capacity = 64 });
    const one_fleet: *track.Fleet = setup.fleet;
    const four_fleet: *track.Fleet = try track.Fleet.init(gpa, m, &.{&setup.clip}, .{
        .envs = 8,
        .capacity = 64,
        .physics_threads = 4,
    });
    defer four_fleet.deinit();
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    four_fleet.physics_io = threaded.io();
    const f: usize = track.localSize(m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    const normaliser: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 16,
        .actor = .flow,
        .flow = .{ .hidden_width = 32 },
    };
    var one_host: compute_host.Compute(zn_mlp) = .initCpu();
    const one_learner: *Resident(zn_mlp) = try Resident(zn_mlp).init(gpa, &one_host, one_fleet, normaliser, options);
    defer one_learner.deinit();
    var four_host: compute_host.Compute(zn_mlp) = .initCpu();
    const four_learner: *Resident(zn_mlp) = try Resident(zn_mlp).init(gpa, &four_host, four_fleet, normaliser, options);
    defer four_learner.deinit();
    try expectEqual(@as(usize, 4), four_learner.acting_scratches.len);
    for (0..3) |_| {
        one_learner.act(16, 1.0);
        four_learner.act(16, 1.0);
        try expectEqualSlices(f32, one_learner.actions, four_learner.actions);
        try expectEqualSlices(f32, one_learner.flow_noise, four_learner.flow_noise);
        for (0..8) |env| {
            try expectEqualSlices(f32, one_fleet.data[env].joint_positions, four_fleet.data[env].joint_positions);
            try expectEqualSlices(f32, one_fleet.data[env].joint_velocities, four_fleet.data[env].joint_velocities);
        }
    }
}

test "robot_track_resident: the action filter gives the fleet a fifth of a first action from rest" {
    // Two learners alike but for the filter, each on its own fleet from the same seeds. Their first exploring step
    // chooses the same action - the filter acts only after the choice - and the filtered learner gives the fleet
    // exactly 0.2 of it: the blend from rest, 0.2 x the action + 0.8 x 0.
    const gpa: Allocator = testing_allocator;
    var unfiltered_setup: kit_tests.FleetSetup = undefined;
    try unfiltered_setup.init(gpa);
    defer unfiltered_setup.deinit();
    var filtered_setup: kit_tests.FleetSetup = undefined;
    try filtered_setup.init(gpa);
    defer filtered_setup.deinit();
    const f: usize = track.localSize(unfiltered_setup.fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, f);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    const unfiltered_options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .filter = 1.0,
    };
    var filtered_options: resident.Options = unfiltered_options;
    filtered_options.filter = 0.2;
    var unfiltered_host: compute_host.Compute(zn_mlp) = .initCpu();
    var filtered_host: compute_host.Compute(zn_mlp) = .initCpu();
    const unfiltered: *Resident(zn_mlp) = try .init(
        gpa,
        &unfiltered_host,
        unfiltered_setup.fleet,
        .{ .mean = mean, .spread = spread },
        unfiltered_options,
    );
    defer unfiltered.deinit();
    const filtered: *Resident(zn_mlp) = try .init(
        gpa,
        &filtered_host,
        filtered_setup.fleet,
        .{ .mean = mean, .spread = spread },
        filtered_options,
    );
    defer filtered.deinit();
    unfiltered.act(1, 1.0);
    filtered.act(1, 1.0);
    var moved: bool = false;
    for (filtered.actions, unfiltered.actions) |given, chosen| {
        try expectEqual(0.2 * chosen, given);
        moved = moved or chosen != 0.0;
    }
    try expect(moved);
}

test "robot_track_resident: a window starts as its records say - after a push it continues, without its past none" {
    // ONE CHARACTER's BOOKS, ten records written into a ring of eight: the ring holds records 2 to 9. A push before
    // record 5 starts a segment, a new episode starts at record 8, and record 7 is no step of a rollout.
    //
    //     record          2   3   4 | 5   6   7  | 8   9         | a segment's end
    //     episode step    2   3   4   5   6   -    0   1         - unknown (`Replay.append`)
    //
    // Windows of one step (`windowStartInRing`), each against what the CPU learner's rule says of it
    // (robot_latent's `Learner.appliedBefore`):
    //
    //     first record   what was applied before it                          the start
    //     2              record 1's action - gone from the ring             none: drawn again
    //     3              record 2's action                                  continues its episode
    //     5              record 4's action: a push ends a segment, not      continues its episode
    //                    an episode
    //     7              unknown: no step of a rollout                      none
    //     8              rest: an episode's first step                      opens its episode
    //     9              a window reaching record 10, which the ring has not received: none
    //
    // And a learner's ring that holds less than the books - records 3 to 9, as a resident ring behind a CPU fleet's
    // larger replay may: a window at 3 has its record before in the books but not in the ring, so none.
    const capacity: usize = 8;
    var segments: [capacity]u32 = undefined;
    var episode_steps: [capacity]?u32 = undefined;
    const after_loss: [capacity]bool = @splat(false);
    const written = [1]u64{10};
    const record_segments = [8]u32{ 0, 0, 0, 1, 1, 1, 2, 2 };
    const record_steps = [8]?u32{ 2, 3, 4, 5, 6, null, 0, 1 };
    for (record_segments, record_steps, 2..) |segment, step, index| {
        segments[index % capacity] = segment;
        episode_steps[index % capacity] = step;
    }
    const books: track.Replay.Books = .{
        .envs = 1,
        .capacity = capacity,
        .segments = &segments,
        .episode_steps = &episode_steps,
        .after_loss = &after_loss,
        .written = &written,
    };
    const ring_held: kit_mod.RecordRing.HeldSteps = .{ .first = 2, .last = 9 };
    const window_length: u32 = 1;
    const Expected = struct { first: u64, start: ?kit_mod.Start };
    const cases = [6]Expected{
        .{ .first = 2, .start = null },
        .{ .first = 3, .start = .{ .env = 0, .index = 3, .continues_episode = true } },
        .{ .first = 5, .start = .{ .env = 0, .index = 5, .continues_episode = true } },
        .{ .first = 7, .start = null },
        .{ .first = 8, .start = .{ .env = 0, .index = 8, .continues_episode = false } },
        .{ .first = 9, .start = null },
    };
    for (cases) |case| {
        const window: track.Replay.Window = .{ .env = 0, .first = case.first, .steps = window_length };
        const start: ?kit_mod.Start = resident.windowStartInRing(books, ring_held, window, window_length);
        try expectEqual(case.start, start);
    }
    const shorter_ring_held: kit_mod.RecordRing.HeldSteps = .{ .first = 3, .last = 9 };
    const at_shorter_rings_oldest: track.Replay.Window = .{ .env = 0, .first = 3, .steps = window_length };
    const books_say: ?track.AppliedBefore = books.appliedBeforeAt(0, 3);
    try expectEqual(@as(?track.AppliedBefore, .previous_record), books_say);
    const in_shorter_ring: ?kit_mod.Start =
        resident.windowStartInRing(books, shorter_ring_held, at_shorter_rings_oldest, window_length);
    try expectEqual(@as(?kit_mod.Start, null), in_shorter_ring);
}

/// A TRAINER WHOSE BOOKS ARE KEPT BY HAND, as a simulator on the device keeps them (`acceptDeviceActing`): a CPU fleet
/// stepped `step_count` times with the setup's fixed actions, each step's records into the ring (`appendLatest`) and
/// each step's moments - read off the fleet's own replay - into the books. Character 1 is a planner: a plan's first
/// decision every fourth record, its next two followed while its motion goes on unbroken, the fourth the policy's; its
/// labels are the actions it took. Made in place, since the learner keeps a pointer to the pipe (`init`); `deinit`
/// frees everything.
const HandKeptTrainer = struct {
    setup: kit_tests.FleetSetup,
    host: compute_host.Compute(zn_mlp),
    mean: []f32,
    spread: []f32,
    learner: *Resident(zn_mlp),

    const planner: usize = 1;

    fn init(
        self: *HandKeptTrainer,
        gpa: Allocator,
        options: resident.Options,
        step_count: usize,
    ) !void {
        // The whole struct first, every field named; each is made in its turn below.
        self.* = .{
            .setup = undefined,
            .host = compute_host.Compute(zn_mlp).initCpu(),
            .mean = undefined,
            .spread = undefined,
            .learner = undefined,
        };
        try self.setup.init(gpa);
        errdefer self.setup.deinit();
        const fleet: *track.Fleet = self.setup.fleet;
        const feature_count: usize = track.localSize(fleet.m.body_count);
        self.mean = try gpa.alloc(f32, feature_count);
        errdefer gpa.free(self.mean);
        self.spread = try gpa.alloc(f32, feature_count);
        errdefer gpa.free(self.spread);
        @memset(self.mean, 0.0);
        @memset(self.spread, 1.0);
        const normalizer: latent.Normalizer = .{ .mean = self.mean, .spread = self.spread };
        self.learner = try Resident(zn_mlp).init(gpa, &self.host, fleet, normalizer, options);
        errdefer self.learner.deinit();
        const kit: *kit_mod.LatentKit(zn_mlp) = &self.learner.kit;
        const world_count: u32 = @intCast(fleet.options.envs);
        const input_width: u32 = kit.lead + kit.features;
        try self.learner.acceptDeviceActing(0, world_count, input_width, kit.actions);
        self.host.element_count = @max(self.learner.data.end, self.learner.params_end);
        self.learner.data.uploadTables(fleet);
        self.stepWithBooksKeptByHand(step_count);
    }

    fn stepWithBooksKeptByHand(self: *HandKeptTrainer, step_count: usize) void {
        const fleet: *track.Fleet = self.setup.fleet;
        const books: *track.KeptBooks = &self.learner.device_acting.?.books;
        const replay: track.Replay = fleet.replay;
        const moments: []rbt.RecordMoment = self.learner.gpa.alloc(rbt.RecordMoment, fleet.options.envs) catch
            @panic("out of memory");
        defer self.learner.gpa.free(moments);
        var planner_labelled_before: bool = false;
        for (0..step_count) |_| {
            _ = fleet.step(self.setup.actions_buffer);
            self.learner.data.appendLatest(fleet);
            for (moments, 0..) |*moment, env| {
                const index: u64 = replay.written[env] - 1;
                const breaks: bool = index == 0 or replay.segmentAt(env, index) != replay.segmentAt(env, index - 1);
                // The frame and clip too, as a simulator keeps them: a policy's start is drawn only where its horizon
                // of clip follows, and the ring's records name the fleet's real frame.
                moment.* = .{
                    .starts_segment = breaks,
                    .episode_step = replay.episodeStepAt(env, index).?,
                    .after_loss = replay.afterLossAt(env, index),
                    .frame = replay.frameAt(env, index),
                    .clip = replay.clipAt(env, index),
                };
                if (env != planner) {
                    continue;
                }
                const place_in_plan: u64 = index % 4;
                const begins_plan: bool = place_in_plan == 0;
                const plan_goes_on: bool = place_in_plan < 3 and planner_labelled_before and !breaks;
                moment.labelled = begins_plan or plan_goes_on;
                moment.begins_plan = begins_plan;
                planner_labelled_before = moment.labelled;
            }
            books.appendStep(moments);
        }
    }

    fn deinit(self: *HandKeptTrainer, gpa: Allocator) void {
        self.learner.deinit();
        gpa.free(self.spread);
        gpa.free(self.mean);
        self.setup.deinit();
    }
};

test "robot_track_resident: the world model's windows and the policy's starts reach the fall, each at its share" {
    // Books kept by hand (`HandKeptTrainer`) over 32 records of every character, the episode lost at record 23 - the
    // last of its segment, as plain SuperTrack's fleet ends an episode at its loss, no aftermath - and a new segment
    // from 24, too short for any window. The world model's windows are 8 decisions long (9 records), the policy's
    // horizon 16. Of the 24 first records a ring of 32 offers a window of 8, the 16 inside the first segment are
    // windows, and one of them - from record 15 - ends on the transition into the loss: 1 in 16 of the world model's
    // windows, within 4 standard deviations over 2,000 draws, where a window as long as the policy's would never
    // reach it. The records track the clip's last 32 frames, record 31 its last: a policy's start needs 16 frames of
    // clip after it, so records 0 to 15 are starts and no start runs past its clip; and of those, 8 to 15 lie in the
    // last horizon before the loss - a half of the starts, within 4 standard deviations, where windows of the
    // policy's horizon never began there.
    const gpa: Allocator = testing_allocator;
    const options: resident.Options = .{
        .rows = 8,
        .window = 8,
        .policy_window = 16,
        .hidden = 16,
        .policy_hidden = 16,
        .collect = 4,
    };
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, options, 0);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    try expectEqual(@as(u32, 8), learner.world_window_records);
    try expectEqual(@as(u32, 16), learner.policy_window_records);
    // THE BOOKS: every character's episode from record 0, lost at record 23; a new one from 24.
    const fleet: *track.Fleet = trainer.setup.fleet;
    const books: *track.KeptBooks = &learner.device_acting.?.books;
    const moments: []rbt.RecordMoment = try gpa.alloc(rbt.RecordMoment, fleet.options.envs);
    defer gpa.free(moments);
    const loss_record: u64 = 23;
    const record_count: u64 = 32;
    // The clip's last frame at the last record: record i tracks frame last - (31 - i).
    const last_frame: u32 = learner.clip_frame_counts[0] - 1;
    try expect(last_frame >= record_count);
    var index: u64 = 0;
    while (index < record_count) : (index += 1) {
        _ = fleet.step(trainer.setup.actions_buffer);
        learner.data.appendLatest(fleet);
        const opens_episode: bool = index == 0 or index == loss_record + 1;
        const first_of_episode: u64 = if (index > loss_record) loss_record + 1 else 0;
        const frames_to_the_end: u32 = @intCast(record_count - 1 - index);
        for (moments) |*moment| {
            moment.* = .{
                .starts_segment = opens_episode,
                .episode_step = @intCast(index - first_of_episode),
                .after_loss = false,
                .frame = last_frame - frames_to_the_end,
                .clip = 0,
            };
        }
        books.appendStep(moments);
    }
    // THE WORLD MODEL's WINDOWS: 250 batches of 8.
    const batches: usize = 250;
    const window_steps: u64 = learner.world_window_records;
    const last_window_start: u64 = loss_record - window_steps;
    var ending_on_the_loss: usize = 0;
    var starts_seen: [16]bool = @splat(false);
    for (0..batches) |_| {
        try expect(learner.drawWindows(0, .anywhere));
        for (learner.starts) |start| {
            // Inside the first segment, whole: no window crosses the loss into the next episode.
            try expect(start.index <= last_window_start);
            starts_seen[@intCast(start.index)] = true;
            if (start.index == last_window_start) {
                ending_on_the_loss += 1;
            }
        }
    }
    const draws: f64 = float64(batches * options.rows);
    const share: f64 = 1.0 / 16.0;
    const expected: f64 = draws * share;
    const deviation: f64 = @sqrt(draws * share * (1.0 - share));
    const found: f64 = float64(ending_on_the_loss);
    report.print("\n  the world model's windows ending on the loss: {d} of {d:.0} (expected {d:.1}, sd {d:.1})\n", .{
        ending_on_the_loss,
        draws,
        expected,
        deviation,
    });
    try expect(@abs(found - expected) <= 4.0 * deviation);
    // Every first record of the segment drawn: the draw is uniform over them, not stuck on a few.
    for (starts_seen) |seen| {
        try expect(seen);
    }
    // THE POLICY's STARTS: inside the clip - records 0 to 15 - and half of them in the last horizon before the loss.
    const policy_steps: u64 = learner.policy_window_records;
    const last_start_inside_the_clip: u64 = record_count - 1 - policy_steps;
    const first_in_the_last_horizon: u64 = loss_record + 1 - policy_steps;
    var in_the_last_horizon: usize = 0;
    for (0..batches) |_| {
        try expect(learner.drawPolicyStarts(0));
        for (learner.starts) |start| {
            try expect(start.index <= last_start_inside_the_clip);
            if (start.index >= first_in_the_last_horizon) {
                in_the_last_horizon += 1;
            }
        }
    }
    const half: f64 = 0.5;
    const expected_in_horizon: f64 = draws * half;
    const horizon_deviation: f64 = @sqrt(draws * half * half);
    const found_in_horizon: f64 = float64(in_the_last_horizon);
    report.print("  the policy's starts in the last horizon before the loss: {d} of {d:.0} (expected {d:.0})\n", .{
        in_the_last_horizon,
        draws,
        expected_in_horizon,
    });
    try expect(@abs(found_in_horizon - expected_in_horizon) <= 4.0 * horizon_deviation);
}

/// A hand-kept trainer's options for the label and phase checks: small networks, the action filter at a half, and the
/// policy's step large enough to see it learn in a few hundred updates.
fn handKeptOptions(phases: resident.Phases) resident.Options {
    return .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .filter = 0.5,
        .policy_rate = 1.0e-3,
        .world_updates = 1,
        .policy_updates = 1,
        .phases = phases,
    };
}

test "robot_track_resident: the skip head's batches - its schedule from the records, at its share, one step after" {
    // A hand-kept trainer with a skip head of 4 decisions, a projection 6 on, its batches half the world model's
    // updates. Its schedule is two steps of 4 over the window of 8. Windows gathered on it from the trainer's own ring:
    // each step's target the record 4 and 8 decisions on, each step's action the mean of its 4 records' actions, by
    // hand from the ring. Then two updates: the first the one-step model's, the second the skip head's - its loss
    // logged apart - and the kit a one-step model again after it.
    const gpa: Allocator = testing_allocator;
    var options: resident.Options = handKeptOptions(.{});
    options.skip_steps = 4;
    options.world_form = .dense_tanh;
    options.projection_steps = 6;
    options.skip_batch_share = 0.5;
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, options, 40);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    var checks: report.Checks = .{};
    const schedule_is_two_of_four: bool = learner.skip_schedule.len == 2 and
        learner.skip_schedule[0] == 4 and learner.skip_schedule[1] == 4;
    checks.holds(schedule_is_two_of_four, "the skip schedule is {any}\n", .{learner.skip_schedule});
    // THE GATHER ON THE SCHEDULE, against the ring read back.
    try expect(learner.drawWindows(0, .anywhere));
    const schedule: kit_mod.GatherSchedule = .{ .steps = 2, .records = 8, .at = learner.skip_schedule_at };
    learner.data.gatherOnSchedule(kit, 0, schedule);
    const acts: []f32 = try gpa.alloc(f32, learner.data.end);
    defer gpa.free(acts);
    trainer.host.readRange(.acts, 0, acts);
    const records: []f32 = try gpa.alloc(f32, learner.data.ring_end);
    defer gpa.free(records);
    trainer.host.readRange(.ring, 0, records);
    const ring: kit_mod.RecordRing = learner.data.ring;
    const f: u32 = kit.features;
    const action_count: u32 = kit.actions;
    for (learner.starts[0..kit.rows], 0..) |start, row| {
        for (0..2) |step| {
            const first: u64 = start.index + 4 * step;
            const end_slot: u64 = (first + 4) % ring.capacity;
            const end_record_at: u64 = ring.at + (end_slot * ring.envs + start.env) * ring.record;
            const end_record: []const f32 = records[end_record_at..][0..f];
            const target: []const f32 = acts[kit.blockT(@intCast(step + 1)) + row * f ..][0..f];
            checks.holds(eql(f32, end_record, target), "row {d} step {d}: the target is not the record 4 on\n", .{
                row,
                step,
            });
            const block_at: usize = kit.blockX(@intCast(step)) + row * kit.width;
            const block_actions_at: usize = block_at + kit.lead + f + kit.references;
            for (0..action_count) |number| {
                var action_sum: f32 = 0;
                for (0..4) |taken| {
                    const slot: u64 = (first + taken) % ring.capacity;
                    const record_at: u64 = ring.at + (slot * ring.envs + start.env) * ring.record;
                    action_sum += records[record_at + f + number];
                }
                const mean_action: f32 = action_sum / 4.0;
                const gathered: f32 = acts[block_actions_at + number];
                checks.holds(gathered == mean_action, "row {d} step {d} action {d}: {d}, not the mean {d}\n", .{
                    row,
                    step,
                    number,
                    gathered,
                    mean_action,
                });
            }
        }
    }
    // TWO UPDATES: the one-step model's, then the skip head's.
    learner.kit.pipe.beginRecording();
    learner.trainWorld(0);
    learner.trainWorld(1);
    learner.kit.pipe.submitRecording();
    learner.syncMirror();
    learner.refreshDeviceStats();
    checks.holds(learner.world_updates == 2, "{d} world updates\n", .{learner.world_updates});
    checks.holds(learner.skip_world_updates == 1, "{d} skip head updates\n", .{learner.skip_world_updates});
    const stats: kit_mod.DeviceStats = learner.device_stats;
    const both_losses: bool = stats.world_model_loss > 0 and stats.skip_head_loss > 0 and
        isFinite(stats.skip_head_loss);
    checks.holds(both_losses, "the losses: one-step {d}, skip head {d}\n", .{
        stats.world_model_loss,
        stats.skip_head_loss,
    });
    const one_step_again: bool = kit.world_steps == options.window and kit.skips.len == 0;
    checks.holds(one_step_again, "after the skip head's update: a window of {d}, {d} skips\n", .{
        kit.world_steps,
        kit.skips.len,
    });
    try checks.finish();
}

test "robot_track_resident: the skip head's consistency - the averaged one-step head chained under the held mean" {
    // A hand-kept trainer whose every world model update is the skip head's consistency (skip 4, projection 6). At the
    // first update the slow average IS the starting world model, so its chain can be taken by hand beforehand: the
    // same windows gathered, their actions over the skip held as their mean (each block's the mean of the four,
    // checked against the ring), and the starting one-step head rolled four steps. The update's target is that chain's
    // end, to the bit; its first block reads the reference at the skip's end; the one-step head's weights do not move
    // (no gradient reaches them, and Adam's first step on a zero gradient is zero), the skip head's do; and the
    // average follows the live weights by its decay, to the bit.
    const gpa: Allocator = testing_allocator;
    var options: resident.Options = handKeptOptions(.{});
    options.skip_steps = 4;
    options.world_form = .dense_tanh;
    options.projection_steps = 6;
    options.skip_batch_share = 1;
    options.skip_consistency_share = 1;
    options.world_average_decay = 0.75;
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, options, 40);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    var checks: report.Checks = .{};
    try expectEqual(kit.param_count, learner.world_average_count);
    const f: u32 = kit.features;
    const rows: u32 = kit.rows;
    // BY HAND: the windows drawn and gathered, the actions held, the starting model chained four steps.
    try expect(learner.drawWindows(0, .anywhere));
    learner.data.gather(kit, 0);
    kit.pipe.params = .{
        .rows = rows,
        .count = kit.actions,
        .stride = kit.width,
        .x_off = kit.x_at,
        .col = kit.lead + f + kit.references,
        .lat_steps = 4,
    };
    kit.pipe.run("lat_hold_mean_action", rows * kit.actions);
    const one_step_window: u32 = kit.world_steps;
    kit.world_steps = 4;
    kit.forwardRecorded();
    kit.world_steps = one_step_window;
    const acts: []f32 = try gpa.alloc(f32, learner.data.end);
    defer gpa.free(acts);
    trainer.host.readRange(.acts, 0, acts);
    const chain_end: []f32 = try gpa.dupe(f32, acts[kit.blockZ(4)..][0 .. rows * f]);
    defer gpa.free(chain_end);
    // The held actions, against the ring read back from its own buffer.
    const ring: kit_mod.RecordRing = learner.data.ring;
    const records: []f32 = try gpa.alloc(f32, learner.data.ring_end);
    defer gpa.free(records);
    trainer.host.readRange(.ring, 0, records);
    const action_column: u32 = kit.lead + f + kit.references;
    for (learner.starts[0..rows], 0..) |start, row| {
        for (0..kit.actions) |number| {
            var action_sum: f32 = 0;
            for (0..4) |taken| {
                const slot: u64 = (start.index + taken) % ring.capacity;
                action_sum += records[ring.at + (slot * ring.envs + start.env) * ring.record + f + number];
            }
            const mean_action: f32 = action_sum / 4.0;
            for (0..4) |block| {
                const held: f32 = acts[kit.blockX(@intCast(block)) + row * kit.width + action_column + number];
                checks.holds(held == mean_action, "row {d} block {d} action {d}: {d}, not the mean {d}\n", .{
                    row,
                    block,
                    number,
                    held,
                    mean_action,
                });
            }
        }
    }
    const params_count: usize = learner.params_end;
    const before: []f32 = try gpa.alloc(f32, params_count);
    defer gpa.free(before);
    trainer.host.readRange(.params, 0, before);
    // THE UPDATE, on the windows staged above - the consistency and the average's follow, as `trainWorld` takes
    // them once it has drawn its windows, counted as its first update.
    learner.kit.pipe.beginRecording();
    learner.world_updates += 1;
    learner.trainSkipConsistency(0, options.world_rate);
    learner.followWorldAverage();
    learner.kit.pipe.submitRecording();
    learner.syncMirror();
    learner.refreshDeviceStats();
    trainer.host.readRange(.acts, 0, acts);
    const target: []const f32 = acts[kit.blockT(1)..][0 .. rows * f];
    checks.holds(eql(f32, chain_end, target), "the target is not the chain's end\n", .{});
    const reference_column: u32 = kit.lead + f;
    for (0..rows) |row| {
        const first: []const f32 = acts[kit.blockX(0) + row * kit.width + reference_column ..][0..kit.references];
        const last: []const f32 = acts[kit.blockX(3) + row * kit.width + reference_column ..][0..kit.references];
        checks.holds(eql(f32, first, last), "row {d}: the first block's reference is not the skip's end's\n", .{row});
    }
    const after: []f32 = try gpa.alloc(f32, params_count);
    defer gpa.free(after);
    trainer.host.readRange(.params, 0, after);
    const head_floats: usize = kit.hidden * f + f;
    const one_step_head_still: bool = eql(f32, before[kit.w3..][0..head_floats], after[kit.w3..][0..head_floats]);
    const skip_head_moved: bool = !eql(f32, before[kit.w4..][0..head_floats], after[kit.w4..][0..head_floats]);
    checks.holds(one_step_head_still, "the one-step head moved\n", .{});
    checks.holds(skip_head_moved, "the skip head did not move\n", .{});
    var average_followed: bool = true;
    for (0..kit.param_count) |at| {
        const expected: f32 = zm.polyakFollow(f32, before[learner.world_average_at + at], after[at], 0.25);
        average_followed = average_followed and after[learner.world_average_at + at] == expected;
    }
    checks.holds(average_followed, "the world model's average did not follow by its decay\n", .{});
    const stats: kit_mod.DeviceStats = learner.device_stats;
    const measured: bool = stats.skip_consistency_loss > 0 and stats.skip_head_error > 0 and
        stats.chained_one_step_error > 0;
    checks.holds(measured, "the consistency's numbers: loss {d}, skip head error {d}, chained error {d}\n", .{
        stats.skip_consistency_loss,
        stats.skip_head_error,
        stats.chained_one_step_error,
    });
    try checks.finish();
}

test "robot_track_resident: the policy through skips - a horizon of its decisions, goals on its schedule" {
    // The window's 8 single steps, then 2 steps of the skip head's 4 decisions: 10 steps over 16 decisions. The
    // policy's starts are drawn with a clip of 16 decisions after them; its update gathers them on its schedule - its
    // last state's goal the clip's frame 16 decisions on - and the kit has no schedule after it.
    const gpa: Allocator = testing_allocator;
    var options: resident.Options = handKeptOptions(.{});
    options.skip_steps = 4;
    options.world_form = .dense_tanh;
    options.projection_steps = 6;
    options.policy_skip_steps = 2;
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, options, 40);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    var checks: report.Checks = .{};
    checks.holds(kit.steps == 10 and learner.policy_window_records == 16, "{d} steps over {d} records\n", .{
        kit.steps,
        learner.policy_window_records,
    });
    const expected_schedule = [_]u32{ 1, 1, 1, 1, 1, 1, 1, 1, 4, 4 };
    checks.holds(eql(u32, learner.policy_schedule, &expected_schedule), "the schedule {any}\n", .{
        learner.policy_schedule,
    });
    const policy_before: []f32 = try gpa.alloc(f32, kit.policy_count);
    defer gpa.free(policy_before);
    trainer.host.readRange(.params, kit.p_at, policy_before);
    learner.kit.pipe.beginRecording();
    learner.trainPolicy(0);
    learner.kit.pipe.submitRecording();
    checks.holds(learner.policy_updates == 1, "{d} policy updates\n", .{learner.policy_updates});
    checks.holds(kit.skips.len == 0, "the kit keeps a schedule of {d} after the update\n", .{kit.skips.len});
    // Each row's last goal: the features of the clip's frame 16 decisions after its start's - the clip's table row the
    // start record's plus 16, a decision a frame here (`lat_gather_policy_starts`).
    const acts: []f32 = try gpa.alloc(f32, learner.data.end);
    defer gpa.free(acts);
    trainer.host.readRange(.acts, 0, acts);
    const records: []f32 = try gpa.alloc(f32, learner.data.ring_end);
    defer gpa.free(records);
    trainer.host.readRange(.ring, 0, records);
    const ring: kit_mod.RecordRing = learner.data.ring;
    const f: u32 = kit.features;
    const table_width: u32 = zn_mlp.latTableWidth(f, kit.references);
    try expectEqual(@as(u32, 1), learner.data.decision_frames);
    for (learner.starts[0..kit.rows], 0..) |start, row| {
        const start_slot: u64 = start.index % ring.capacity;
        const start_record_at: u64 = ring.at + (start_slot * ring.envs + start.env) * ring.record;
        const start_table_row: u32 = @trunc(records[start_record_at + zn_mlp.latRecordTableRow(f, kit.actions)]);
        const table_row: u32 = start_table_row + 16;
        const frame: []const f32 = acts[learner.data.table_at + table_row * table_width ..][0..f];
        const goal: []const f32 = acts[kit.blockG(10) + row * f ..][0..f];
        checks.holds(eql(f32, frame, goal), "row {d}: the last goal is not the frame 16 after its start's\n", .{row});
    }
    const policy_after: []f32 = try gpa.alloc(f32, kit.policy_count);
    defer gpa.free(policy_after);
    trainer.host.readRange(.params, kit.p_at, policy_after);
    var all_finite: bool = true;
    for (policy_after) |weight| {
        all_finite = all_finite and isFinite(weight);
    }
    checks.holds(all_finite and !eql(f32, policy_before, policy_after), "the policy did not learn, finitely\n", .{});
    try checks.finish();
}

test "robot_track_resident: the policy learns the planners' kept labels - one-step windows, the world model untouched" {
    // A trainer whose books are kept by hand (`HandKeptTrainer`), then label updates (`trainPolicyOnLabels`): every
    // window staged is a kept label, one step long, starting from what was applied before it; the world model's
    // weights are not touched; and the distance between the action the policy would give and the labels falls - the
    // policy learns the planner's actions.
    const gpa: Allocator = testing_allocator;
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, handKeptOptions(.{}), 40);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const books: *track.KeptBooks = &learner.device_acting.?.books;
    const kept: []const track.Label = books.labels.keptLabels();
    try expect(kept.len > 8);
    for (kept) |label| {
        try expectEqual(@as(u32, HandKeptTrainer.planner), label.env);
    }
    // THE WORLD MODEL's WEIGHTS before any label update.
    const parameters_before: []f32 = try gpa.alloc(f32, learner.params_end);
    defer gpa.free(parameters_before);
    trainer.host.readRange(.params, 0, parameters_before);
    // THE LABEL UPDATES.
    const update_count: usize = 200;
    var label_losses: [update_count]f32 = undefined;
    for (&label_losses, 0..) |*label_loss, update| {
        learner.trainPolicyOnLabels(0);
        learner.refreshDeviceStats();
        label_loss.* = learner.device_stats.policy_label_loss;
        if (update > 0) {
            continue;
        }
        // The first batch: every window a kept label, one step long, from what was applied before it.
        for (learner.starts) |start| {
            const is_kept: bool = for (kept) |label| {
                if (label.env == start.env and label.index == start.index) {
                    break true;
                }
            } else false;
            try expect(is_kept);
            const episode_step: u32 = books.episodeStepAt(start.env, start.index).?;
            try expectEqual(episode_step > 0, start.continues_episode);
        }
        try expectEqual(@as(u32, 1), learner.data.staged[0].steps);
    }
    try expectEqual(@as(u64, update_count), learner.label_updates);
    try expectEqual(@as(u64, update_count), learner.policy_updates);
    try expectEqual(@as(u64, 0), learner.label_batches_refused);
    // The world model's weights, to the bit; the policy's moved.
    const parameters_after: []f32 = try gpa.alloc(f32, learner.params_end);
    defer gpa.free(parameters_after);
    trainer.host.readRange(.params, 0, parameters_after);
    const world_end: usize = kit.p_at;
    try expect(eql(f32, parameters_before[0..world_end], parameters_after[0..world_end]));
    const policy_end: usize = kit.p_at + kit.policy_count;
    try expect(!eql(f32, parameters_before[world_end..policy_end], parameters_after[world_end..policy_end]));
    // THE DISTANCE FALLS: the last ten batches' mean against the first ten's.
    var first_ten: f32 = 0;
    var last_ten: f32 = 0;
    for (label_losses[0..10], label_losses[update_count - 10 ..]) |first, last| {
        first_ten += first / 10.0;
        last_ten += last / 10.0;
    }
    report.print("\n  label loss: {e:.3} over the first ten updates, {e:.3} over the last ten ({d} labels kept)\n", .{
        first_ten,
        last_ten,
        kept.len,
    });
    try expect(last_ten < 0.5 * first_ten);
}

test "robot_track_resident: the labels' share of the policy's updates - all in phase 1, then ramped down and held" {
    // `labelUpdateShare` against its worked numbers: a ramp of 3 minutes down to 0.1 - all in phase 1; at phase 2's
    // start still all; a minute in 1 - 0.9 x 1/3 = 0.7; at three minutes and after, 0.1. A ramp of no minutes falls
    // at once.
    const phases: resident.Phases = .{ .enabled = true, .ramp_minutes = 3, .label_share_after_ramp = 0.1 };
    const minute: f32 = 1.0 / 60.0;
    try expectEqual(@as(f32, 1.0), resident.labelUpdateShare(phases, null));
    try expectEqual(@as(f32, 1.0), resident.labelUpdateShare(phases, 0));
    try expectApproxEqAbs(@as(f32, 0.7), resident.labelUpdateShare(phases, minute), 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.1), resident.labelUpdateShare(phases, 3 * minute), 1.0e-6);
    try expectApproxEqAbs(@as(f32, 0.1), resident.labelUpdateShare(phases, 60 * minute), 1.0e-6);
    var at_once: resident.Phases = phases;
    at_once.ramp_minutes = 0;
    try expectApproxEqAbs(@as(f32, 0.1), resident.labelUpdateShare(at_once, 0), 1.0e-6);
}

/// How a hand-kept trainer's first round of training is taken (`firstRoundInARunOfItsOwn`).
const FirstRound = enum {
    /// The trainer's own round, in phase 1 (`Resident.train`).
    phase_one_round,
    /// By hand, without phases: the world model's statistics folded, its update, then a label update, in one
    /// recording - as a round records them.
    label_update_by_hand,
};

/// THE WORLD MODEL's AND THE POLICY's WEIGHTS AND FIRST MOMENTS after a hand-kept trainer's first round of training
/// (`HandKeptTrainer`, forty steps; one world-model update and one policy update), taken as `how` says - in a run of
/// its own: the trainer made for it, and the kit's buffers poisoned with NaN once the numbers are copied, so a run
/// after it inherits nothing (every CPU pipe of the kit's module shares the module's buffers). Each run must have
/// trained the world model once and the policy once, on labels. The caller owns the copy: weights, then moments.
fn firstRoundInARunOfItsOwn(gpa: Allocator, how: FirstRound) ![]f32 {
    const in_phase_one: bool = how == .phase_one_round;
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, handKeptOptions(.{ .enabled = in_phase_one }), 40);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const policy_end: usize = learner.kit.p_at + learner.kit.policy_count;
    const weights_before: []f32 = try gpa.alloc(f32, policy_end);
    defer gpa.free(weights_before);
    trainer.host.readRange(.params, 0, weights_before);
    switch (how) {
        .phase_one_round => {
            try expect(learner.inPhaseOne());
            learner.train();
        },
        .label_update_by_hand => {
            learner.kit.pipe.beginRecording();
            learner.foldWorldStatistics();
            learner.trainWorld(0);
            learner.trainPolicyOnLabels(1);
            learner.kit.pipe.submitRecording();
            learner.syncMirror();
            learner.refreshDeviceStats();
        },
    }
    try expectEqual(@as(u32, 1), learner.world_updates);
    try expectEqual(@as(u32, 1), learner.policy_updates);
    try expectEqual(@as(u64, 1), learner.label_updates);
    const numbers: []f32 = try gpa.alloc(f32, 2 * policy_end);
    errdefer gpa.free(numbers);
    trainer.host.readRange(.params, 0, numbers[0..policy_end]);
    trainer.host.readRange(.adam_m, 0, numbers[policy_end..]);
    // The round moved the policy's weights.
    const world_end: usize = learner.kit.p_at;
    try expect(!eql(f32, weights_before[world_end..], numbers[world_end..policy_end]));
    try poisonLearnerBuffers(gpa, &trainer.host, learner);
    return numbers;
}

test "robot_track_resident: a round in phase 1 is the world model's update and a label update - to the bit" {
    // Phase 1 is the teacher alone: a round's policy update is a label update, and nothing else. A hand-kept trainer's
    // first round in phase 1 (`train`) against the same trainer's running statistics folded, world-model
    // update and label update taken by hand without phases: the world model's and the policy's weights and Adam's
    // first moments, bit for bit.
    const gpa: Allocator = testing_allocator;
    const in_phase_one: []f32 = try firstRoundInARunOfItsOwn(gpa, .phase_one_round);
    defer gpa.free(in_phase_one);
    const by_hand: []f32 = try firstRoundInARunOfItsOwn(gpa, .label_update_by_hand);
    defer gpa.free(by_hand);
    try expect(eql(u8, sliceAsBytes(in_phase_one), sliceAsBytes(by_hand)));
}

/// One number of a world model statistic, its moments read back against a host's f64 sum over the same values.
const PooledExpectation = struct {
    sum: f64 = 0,
    squares: f64 = 0,
    count: u64 = 0,

    fn add(expectation: *PooledExpectation, value: f64) void {
        expectation.sum += value;
        expectation.squares += value * value;
        expectation.count += 1;
    }

    /// The moments at params `at`, a block `stride` wide (count, mean, variance), as the expectation's: the count
    /// exact, the mean and variance to a millionth and a ten-thousandth of their size. Returns the mean and the
    /// variance read.
    fn expectMoments(
        expectation: PooledExpectation,
        moments: []const f32,
        at: usize,
        stride: usize,
    ) ![2]f32 {
        const count: f64 = float64(expectation.count);
        const mean: f64 = expectation.sum / count;
        const variance: f64 = @max(expectation.squares / count - mean * mean, 0);
        try expectEqual(@as(f32, @floatCast(count)), moments[at]);
        const mean_tolerance: f64 = 1.0e-6 + 1.0e-5 * @abs(mean);
        const variance_tolerance: f64 = 1.0e-9 + 1.0e-4 * variance;
        try expectApproxEqAbs(mean, moments[at + stride], mean_tolerance);
        try expectApproxEqAbs(variance, moments[at + 2 * stride], variance_tolerance);
        return .{ moments[at + stride], moments[at + 2 * stride] };
    }
};

test "robot_track_resident: the world model's running statistics - from their start, folded from the books" {
    // A hand-kept trainer after 40 steps of 4 characters, its ring of 32 holding the last 32. AT ITS START every
    // moment is XMimic's - mean 0, variance 1 - so the inputs' affine reads each column as it is over sqrt(1 + eps^2),
    // and the kit's change statistics are those moments over the clips' spreads, the loss's spread floored by each
    // feature's kind. FOLDED (`foldWorldStatistics`): every pair of records in the ring that the replay keeps in one
    // segment is a transition, and from the ring and the reference table read back - the state and the action from
    // its first record, the servo targets from its second's table row, the change between the two - each input
    // column's and each feature's count, mean and variance are those of its values over every transition; the affine
    // and the kit's statistics follow from them, the state's columns composed with a normaliser of means and spreads
    // other than 0 and 1, so the composition shows. A second fold, with nothing new, changes nothing.
    const gpa: Allocator = testing_allocator;
    const options: resident.Options = handKeptOptions(.{});
    const statistics: resident.WorldStatistics = options.world_statistics;
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, options, 40);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const feature_count: u32 = kit.features;
    const reference_count: u32 = kit.references;
    const action_count: u32 = learner.data.actions;
    const input_count: u32 = kit.inputs;
    try expectEqual(input_count, feature_count + reference_count + action_count);
    const local_layout: rbt.LocalLayout = .of(@intCast(learner.fleet.m.body_count));
    const input_epsilon: f32 = statistics.inputs_epsilon;
    const change_epsilon: f32 = statistics.change_epsilon;
    const affine: []f32 = try gpa.alloc(f32, 2 * input_count);
    defer gpa.free(affine);
    const kit_statistics: []f32 = try gpa.alloc(f32, 3 * feature_count);
    defer gpa.free(kit_statistics);
    // THE START: every clip mean 0 and spread 1.
    trainer.host.readRange(.params, kit.inputs_affine_at.?, affine);
    trainer.host.readRange(.acts, kit.increments_at.?, kit_statistics[0 .. 2 * feature_count]);
    trainer.host.readRange(.acts, kit.loss_weights_at.?, kit_statistics[2 * feature_count ..]);
    const starting_input_spread: f32 = @sqrt(1.0 + input_epsilon * input_epsilon);
    for (0..input_count) |column| {
        try expectEqual(@as(f32, 0), affine[column]);
        try expectApproxEqRel(1.0 / starting_input_spread, affine[input_count + column], 1.0e-6);
    }
    const starting_spread: f32 = @sqrt(1.0 + change_epsilon * change_epsilon);
    for (0..feature_count) |feature| {
        const change_floor: f32 = statistics.floorOf(local_layout, @intCast(feature));
        const loss_spread: f32 = @max(starting_spread, change_floor);
        try expectEqual(@as(f32, 0), kit_statistics[feature]);
        try expectEqual(starting_spread, kit_statistics[feature_count + feature]);
        try expectEqual(1.0 / (loss_spread * loss_spread), kit_statistics[2 * feature_count + feature]);
    }
    // Other clip means and spreads, uploaded where the kernel reads them.
    for (learner.norm.mean, learner.norm.spread, 0..) |*mean, *spread, feature| {
        mean.* = 0.1 * float(feature % 4);
        spread.* = 0.5 + 0.25 * float(feature % 3);
    }
    learner.data.uploadNormalizer(learner.norm);
    // THE FOLD, against every transition the ring holds.
    learner.foldWorldStatistics();
    const ring: kit_mod.RecordRing = learner.data.ring;
    const held: kit_mod.RecordRing.HeldSteps = ring.held().?;
    const ring_numbers: []f32 = try gpa.alloc(f32, ring.floats());
    defer gpa.free(ring_numbers);
    trainer.host.readRange(.ring, ring.at, ring_numbers);
    const table_row_column: u32 = zn_mlp.latRecordTableRow(feature_count, action_count);
    var table_rows: usize = 0;
    var record_at: usize = 0;
    while (record_at < ring_numbers.len) : (record_at += ring.record) {
        const table_row: usize = @trunc(ring_numbers[record_at + table_row_column]);
        table_rows = @max(table_rows, table_row + 1);
    }
    const table_width: usize = zn_mlp.latTableWidth(feature_count, reference_count);
    const table: []f32 = try gpa.alloc(f32, table_rows * table_width);
    defer gpa.free(table);
    trainer.host.readRange(.acts, learner.data.table_at, table);
    const moments: []f32 = try gpa.alloc(f32, learner.world_statistics_count);
    defer gpa.free(moments);
    trainer.host.readRange(.params, learner.input_moments_at, moments);
    trainer.host.readRange(.acts, kit.increments_at.?, kit_statistics[0 .. 2 * feature_count]);
    trainer.host.readRange(.acts, kit.loss_weights_at.?, kit_statistics[2 * feature_count ..]);
    const inputs_affine_in_block: usize = kit.inputs_affine_at.? - learner.input_moments_at;
    const change_in_block: usize = learner.change_moments_at - learner.input_moments_at;
    const inputs: []PooledExpectation = try gpa.alloc(PooledExpectation, input_count);
    defer gpa.free(inputs);
    @memset(inputs, .{});
    const changes: []PooledExpectation = try gpa.alloc(PooledExpectation, feature_count);
    defer gpa.free(changes);
    @memset(changes, .{});
    const replay: track.Replay = learner.fleet.replay;
    var index: u64 = held.first + 1;
    while (index <= held.last) : (index += 1) {
        for (0..ring.envs) |env| {
            const one_segment: bool = replay.segmentAt(env, index) == replay.segmentAt(env, index - 1);
            if (!one_segment) {
                continue;
            }
            const first: []const f32 = ring_numbers[ring.recordAt(env, index - 1) - ring.at ..];
            const second: []const f32 = ring_numbers[ring.recordAt(env, index) - ring.at ..];
            const table_row: usize = @trunc(second[table_row_column]);
            for (inputs, 0..) |*input, column| {
                const value: f32 = if (column < feature_count)
                    first[column]
                else if (column < feature_count + reference_count)
                    table[table_row * table_width + column]
                else
                    first[zn_mlp.latRecordAction(feature_count) + column - feature_count - reference_count];
                input.add(value);
            }
            for (changes, 0..) |*change, feature| {
                change.add(@as(f64, second[feature]) - @as(f64, first[feature]));
            }
        }
    }
    try expect(changes[0].count > 0);
    for (inputs, 0..) |input, column| {
        const read: [2]f32 = try input.expectMoments(moments, column, input_count);
        const spread: f32 = @sqrt(read[1] + input_epsilon * input_epsilon);
        var shift: f32 = read[0];
        var scale: f32 = 1.0 / spread;
        if (column < feature_count) {
            shift = (read[0] - learner.norm.mean[column]) / learner.norm.spread[column];
            scale = learner.norm.spread[column] / spread;
        }
        try expectApproxEqRel(shift, moments[inputs_affine_in_block + column], 1.0e-6);
        try expectApproxEqRel(scale, moments[inputs_affine_in_block + input_count + column], 1.0e-6);
    }
    for (changes, 0..) |change, feature| {
        const read: [2]f32 = try change.expectMoments(moments, change_in_block + feature, feature_count);
        const clip_spread: f32 = learner.norm.spread[feature];
        const spread: f32 = @sqrt(read[1] + change_epsilon * change_epsilon);
        const change_floor: f32 = statistics.floorOf(local_layout, @intCast(feature));
        const loss_spread: f32 = @max(spread, change_floor) / clip_spread;
        try expectApproxEqRel(read[0] / clip_spread, kit_statistics[feature], 1.0e-6);
        try expectApproxEqRel(spread / clip_spread, kit_statistics[feature_count + feature], 1.0e-6);
        const weight: f32 = 1.0 / (loss_spread * loss_spread);
        try expectApproxEqRel(weight, kit_statistics[2 * feature_count + feature], 1.0e-6);
    }
    // NOTHING NEW: a second fold leaves the moments as they are.
    learner.foldWorldStatistics();
    const moments_again: []f32 = try gpa.alloc(f32, learner.world_statistics_count);
    defer gpa.free(moments_again);
    trainer.host.readRange(.params, learner.input_moments_at, moments_again);
    try expectEqualSlices(f32, moments, moments_again);
}

test "robot_track_resident: phase 1 until its bound, then the labels' share ramped down - the candidates' share too" {
    // A trainer with phases - phase 1 at most 10 minutes, a ramp of 3 down to 0.1, phase 1's candidates' share 0.8 -
    // told the training's hours round by round, as the program that trains tells them. Phase 1 lasts to its bound;
    // there phase 2 begins, the round's hour noted; the labels' share falls over the ramp and is held; the
    // candidates' share of the world model's batches is the run's from phase 2 on.
    const gpa: Allocator = testing_allocator;
    const phases: resident.Phases = .{
        .enabled = true,
        .phase_one_minutes = 10,
        .ramp_minutes = 3,
        .label_share_after_ramp = 0.1,
        .phase_one_candidate_batch_share = 0.8,
    };
    var trainer: HandKeptTrainer = undefined;
    try trainer.init(gpa, handKeptOptions(phases), 40);
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const minute: f32 = 1.0 / 60.0;
    try expect(learner.inPhaseOne());
    try expectEqual(@as(f32, 1.0), learner.labelShare());
    try expectEqual(@as(f32, 0.8), learner.candidateBatchShare());
    // A round before the bound: phase 1 still.
    learner.training_hours = 9.5 * minute;
    learner.train();
    try expect(learner.inPhaseOne());
    // The round at the bound: phase 2 begins there.
    learner.training_hours = 10 * minute;
    learner.train();
    try expect(!learner.inPhaseOne());
    try expectEqual(@as(?f32, 10 * minute), learner.phase_two_began_hours);
    try expectEqual(learner.options.candidate_batch_share, learner.candidateBatchShare());
    // The ramp: a minute in, 0.7; at its end and after, 0.1.
    learner.training_hours = 11 * minute;
    try expectApproxEqAbs(@as(f32, 0.7), learner.labelShare(), 1.0e-5);
    learner.training_hours = 13 * minute;
    try expectApproxEqAbs(@as(f32, 0.1), learner.labelShare(), 1.0e-5);
    learner.training_hours = 30 * minute;
    try expectApproxEqAbs(@as(f32, 0.1), learner.labelShare(), 1.0e-5);
    // Every round so far trained the policy on labels alone: the share was whole until phase 2 began.
    try expectEqual(@as(u64, 2), learner.label_updates);
    try expectEqual(@as(u32, 2), learner.policy_updates);
}

test "robot_track_resident: the policy's updates by kind - labels at their share; none in phase 1 without labels" {
    const gpa: Allocator = testing_allocator;
    // AT A SHARE OF ONE HALF: phase 2 begun with a ramp of no minutes down to 0.5. Twenty turns, each in a recording
    // of its own as a round's: every second one a label update (`dueAtShare`), the others rollouts through the world
    // model.
    {
        const phases: resident.Phases = .{ .enabled = true, .ramp_minutes = 0, .label_share_after_ramp = 0.5 };
        var trainer: HandKeptTrainer = undefined;
        try trainer.init(gpa, handKeptOptions(phases), 40);
        defer trainer.deinit(gpa);
        const learner: *Resident(zn_mlp) = trainer.learner;
        learner.beginPhaseTwo();
        try expectEqual(@as(f32, 0.5), learner.labelShare());
        var kinds: [20]bool = undefined;
        for (&kinds) |*was_label_update| {
            const label_updates_before: u64 = learner.label_updates;
            learner.kit.pipe.beginRecording();
            learner.trainPolicyByKind(0);
            learner.kit.pipe.submitRecording();
            was_label_update.* = learner.label_updates > label_updates_before;
        }
        for (kinds, 1..) |was_label_update, update_number| {
            try expectEqual(update_number % 2 == 0, was_label_update);
        }
        try expectEqual(@as(u64, 10), learner.label_updates);
        try expectEqual(@as(u32, 20), learner.policy_updates);
    }
    // IN PHASE 1 WITH NO LABEL: a trainer acting on its CPU fleet keeps none. Every turn is refused, and none becomes
    // a rollout - in phase 1 the world model gives the policy nothing.
    {
        var setup: kit_tests.FleetSetup = undefined;
        try setup.init(gpa);
        defer setup.deinit();
        const fleet: *track.Fleet = setup.fleet;
        const feature_count: usize = track.localSize(fleet.m.body_count);
        const mean: []f32 = try gpa.alloc(f32, feature_count);
        defer gpa.free(mean);
        const spread: []f32 = try gpa.alloc(f32, feature_count);
        defer gpa.free(spread);
        @memset(mean, 0.0);
        @memset(spread, 1.0);
        var host: compute_host.Compute(zn_mlp) = .initCpu();
        const normalizer: latent.Normalizer = .{ .mean = mean, .spread = spread };
        const options: resident.Options = handKeptOptions(.{ .enabled = true });
        const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, normalizer, options);
        defer learner.deinit();
        host.element_count = @max(host.element_count, learner.data.end);
        for (0..3) |_| {
            learner.simulateAndTrain();
        }
        try expect(learner.inPhaseOne());
        try expectEqual(@as(u32, 3), learner.world_updates);
        try expectEqual(@as(u32, 0), learner.policy_updates);
        try expectEqual(@as(u64, 3), learner.label_batches_refused);
    }
}

test "robot_track_resident: a resumed learner carries on in its phase - phase 2's start saved, phase 1 kept as it was" {
    // Two learners with phases on one CPU pipe, as the resume check has them: one whose phase 2 began at 12 minutes,
    // one still in phase 1. Each saved, and loaded by a fresh learner: the first resumes in phase 2 from the same
    // hour, the second in phase 1.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.body_count);
    const mean: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(mean);
    const spread: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spread);
    @memset(mean, 0.0);
    @memset(spread, 1.0);
    const normalizer: latent.Normalizer = .{ .mean = mean, .spread = spread };
    const options: resident.Options = handKeptOptions(.{ .enabled = true });
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const minute: f32 = 1.0 / 60.0;
    for ([_]bool{ true, false }) |in_phase_two| {
        const saved_state: []u8 = saved: {
            const saved_learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, normalizer, options);
            defer saved_learner.deinit();
            if (in_phase_two) {
                saved_learner.training_hours = 12 * minute;
                saved_learner.beginPhaseTwo();
            }
            break :saved try saved_learner.exportState(gpa);
        };
        defer gpa.free(saved_state);
        const resumed_learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, normalizer, options);
        defer resumed_learner.deinit();
        try resumed_learner.importState(gpa, saved_state);
        const expected: ?f32 = if (in_phase_two) 12 * minute else null;
        try expectEqual(expected, resumed_learner.phase_two_began_hours);
        try expectEqual(!in_phase_two, resumed_learner.inPhaseOne());
    }
}

test "robot_track_resident: each planner's best quarter of its candidates is favoured, never one whose physics failed" {
    // Three planners of six candidates; the best quarter of six is two.
    //
    //     planner 0   0.5  0.9  NaN  0.1  0.2  0.7      favoured: 0.9 and 0.7
    //     planner 1   0.3  0.3  NaN  NaN  NaN  NaN      favoured: both 0.3s
    //     planner 2   every score NaN                  favoured: none
    const failed: f32 = nan(f32);
    const scores = [18]f32{
        0.5,    0.9,    failed, 0.1,    0.2,    0.7,
        0.3,    0.3,    failed, failed, failed, failed,
        failed, failed, failed, failed, failed, failed,
    };
    var favoured: [18]bool = undefined;
    resident.favourBestQuarter(&scores, 6, &favoured);
    const expected = [18]bool{
        false, true,  false, false, false, true,
        true,  true,  false, false, false, false,
        false, false, false, false, false, false,
    };
    try expectEqualSlices(bool, &expected, &favoured);
    // Equal scores: three best of four, and a quarter of four is one - the earliest of them, as the planner chooses.
    const tied = [4]f32{ 0.2, 0.8, 0.8, 0.8 };
    var tied_favoured: [4]bool = undefined;
    resident.favourBestQuarter(&tied, 4, &tied_favoured);
    try expectEqualSlices(bool, &.{ false, true, false, false }, &tied_favoured);
}

test "robot_track_resident: a candidate's window lies inside a kept lookahead, from a favoured candidate when asked" {
    // A recording made by hand: eight candidates in blocks of four, lookaheads of eight decisions (nine records),
    // three kept and five complete - so lookaheads 2, 3 and 4 are held. In lookaheads 2 and 4 the favoured are
    // candidates L % 4 and 4 + (L + 1) % 4; lookahead 3 has none (every score failed), so its favoured draws fall
    // back to every candidate.
    const candidate_count: u32 = 8;
    const lookahead_records: u32 = 9;
    const lookaheads_kept: u32 = 3;
    var favoured: [lookaheads_kept * candidate_count]bool = @splat(false);
    var planners_recorded: [lookaheads_kept]u32 = @splat(2);
    var recording: resident.CandidateRecording = .{
        .ring = .{ .at = 0, .envs = candidate_count, .capacity = lookaheads_kept * lookahead_records, .record = 4 },
        .candidates_per_planner = 4,
        .lookahead_records = lookahead_records,
        .lookaheads_kept = lookaheads_kept,
        .lookaheads_complete = 5,
        .favoured = &favoured,
        .planners_recorded = &planners_recorded,
    };
    for ([2]u64{ 2, 4 }) |lookahead| {
        const flags: []bool = recording.favouredOf(lookahead);
        flags[@intCast(lookahead % 4)] = true;
        flags[@intCast(4 + (lookahead + 1) % 4)] = true;
    }
    var generator: Random.DefaultPrng = .init(7);
    const random: Random = generator.random();
    const window_steps: u32 = 4;
    const lookahead_steps: u32 = lookahead_records - 1;
    var lookaheads_drawn: [5]u32 = @splat(0);
    var first_decisions_drawn: [5]u32 = @splat(0);
    var favoured_drawn_in_lookahead_3: [candidate_count]u32 = @splat(0);
    for (0..4000) |draw| {
        const favoured_only: bool = draw % 2 == 0;
        const start: kit_mod.Start = recording.drawStart(random, window_steps, favoured_only).?;
        const lookahead: u64 = start.index / lookahead_records;
        const first_decision: u64 = start.index % lookahead_records;
        // Inside a kept lookahead, the whole window too; continuing its stretch past the first decision.
        try expect(lookahead >= 2 and lookahead <= 4);
        try expect(first_decision + window_steps <= lookahead_steps);
        try expectEqual(first_decision > 0, start.continues_episode);
        try expect(start.env < candidate_count);
        lookaheads_drawn[@intCast(lookahead)] += 1;
        first_decisions_drawn[@intCast(first_decision)] += 1;
        if (!favoured_only) {
            continue;
        }
        if (lookahead == 3) {
            favoured_drawn_in_lookahead_3[start.env] += 1;
        } else {
            try expect(recording.favouredOf(lookahead)[start.env]);
        }
    }
    // Every kept lookahead drawn, and every place of the window in one; none from lookaheads 0 and 1, no longer held.
    try expectEqual(@as(u32, 0), lookaheads_drawn[0] + lookaheads_drawn[1]);
    for (lookaheads_drawn[2..]) |count| {
        try expect(count > 0);
    }
    for (first_decisions_drawn) |count| {
        try expect(count > 0);
    }
    // Lookahead 3 had none favoured: its favoured draws spread over every candidate.
    for (favoured_drawn_in_lookahead_3) |count| {
        try expect(count > 0);
    }
    // A window as long as a lookahead has one place: the lookahead's first decision.
    for (0..20) |_| {
        const whole: kit_mod.Start = recording.drawStart(random, lookahead_steps, false).?;
        try expectEqual(@as(u64, 0), whole.index % lookahead_records);
    }
    // None to draw: a window longer than a lookahead, or no lookahead complete.
    try expect(recording.drawStart(random, lookahead_steps + 1, false) == null);
    recording.lookaheads_complete = 0;
    try expect(recording.drawStart(random, window_steps, false) == null);
}

test "robot_track_resident: the gate's windows in pairs - two candidates of one planner, at a fresh lookahead's start" {
    // A recording made by hand: two planners of four candidates, lookaheads of four decisions (five records), three
    // kept and seven complete - so lookaheads 4, 5 and 6 are held - and the gate's draws from lookahead 5 on
    // (`CandidateRecording.drawPairStarts`). Every pair the same lookahead's first decision, one of the fresh; one
    // planner's block; two different candidates; each window opening from rest. Over the draws, both fresh
    // lookaheads, both planners and every candidate drawn. A fresh boundary older than the ring's oldest draws from
    // the oldest held; and nothing to draw - no fresh lookahead, a window longer than a lookahead, planners of one
    // candidate - is refused.
    const candidate_count: u32 = 8;
    const candidates_per_planner: u32 = 4;
    const lookahead_records: u32 = 5;
    const lookaheads_kept: u32 = 3;
    var favoured: [lookaheads_kept * candidate_count]bool = @splat(false);
    var planners_recorded: [lookaheads_kept]u32 = @splat(2);
    var recording: resident.CandidateRecording = .{
        .ring = .{ .at = 0, .envs = candidate_count, .capacity = lookaheads_kept * lookahead_records, .record = 4 },
        .candidates_per_planner = candidates_per_planner,
        .lookahead_records = lookahead_records,
        .lookaheads_kept = lookaheads_kept,
        .lookaheads_complete = 7,
        .favoured = &favoured,
        .planners_recorded = &planners_recorded,
    };
    var generator: Random.DefaultPrng = .init(11);
    const random: Random = generator.random();
    const window_steps: u32 = lookahead_records - 1;
    var starts: [64]kit_mod.Start = undefined;
    try expect(recording.drawPairStarts(random, window_steps, 5, &starts));
    var lookaheads_drawn: [7]u32 = @splat(0);
    var planners_drawn: [2]u32 = @splat(0);
    var candidates_drawn: [candidate_count]u32 = @splat(0);
    for (0..starts.len / 2) |pair| {
        const first: kit_mod.Start = starts[2 * pair];
        const second: kit_mod.Start = starts[2 * pair + 1];
        // One record: one lookahead's first decision, the same for both.
        try expectEqual(first.index, second.index);
        try expectEqual(@as(u64, 0), first.index % lookahead_records);
        const lookahead: u64 = first.index / lookahead_records;
        try expect(lookahead == 5 or lookahead == 6);
        lookaheads_drawn[@intCast(lookahead)] += 1;
        // One planner's block, two of its candidates.
        const planner: u32 = first.env / candidates_per_planner;
        try expectEqual(planner, second.env / candidates_per_planner);
        try expect(first.env != second.env);
        planners_drawn[planner] += 1;
        candidates_drawn[first.env] += 1;
        candidates_drawn[second.env] += 1;
        try expect(!first.continues_episode and !second.continues_episode);
    }
    try expect(lookaheads_drawn[5] > 0 and lookaheads_drawn[6] > 0);
    for (planners_drawn) |count| {
        try expect(count > 0);
    }
    for (candidates_drawn) |count| {
        try expect(count > 0);
    }
    // A boundary before the ring's oldest: only what is held, its oldest among it.
    try expect(recording.drawPairStarts(random, window_steps, 2, &starts));
    var oldest_held_drawn: bool = false;
    for (starts) |start| {
        const lookahead: u64 = start.index / lookahead_records;
        try expect(lookahead >= 4 and lookahead <= 6);
        oldest_held_drawn = oldest_held_drawn or lookahead == 4;
    }
    try expect(oldest_held_drawn);
    // Nothing to draw.
    try expect(!recording.drawPairStarts(random, window_steps, 7, &starts));
    try expect(!recording.drawPairStarts(random, window_steps + 1, 5, &starts));
    recording.candidates_per_planner = 1;
    try expect(!recording.drawPairStarts(random, window_steps, 5, &starts));
}

test "robot_track_resident: a lookahead of fewer planners than the ring's blocks is drawn within the blocks it ran" {
    // Three planners' blocks of four candidates, lookaheads of four decisions (five records), two kept. Lookahead 0
    // ran every block, lookahead 1 the first alone - the planners chosen by trouble were fewer. Completing them marks
    // each one's planners and favours within them; every window and every gate pair drawn from lookahead 1 is of its
    // first block, whatever the blocks past it hold.
    const candidates_per_planner: u32 = 4;
    const candidate_count: u32 = 3 * candidates_per_planner;
    const lookahead_records: u32 = 5;
    const lookaheads_kept: u32 = 2;
    var favoured: [lookaheads_kept * candidate_count]bool = @splat(true);
    var planners_recorded: [lookaheads_kept]u32 = @splat(3);
    var recording: resident.CandidateRecording = .{
        .ring = .{ .at = 0, .envs = candidate_count, .capacity = lookaheads_kept * lookahead_records, .record = 4 },
        .candidates_per_planner = candidates_per_planner,
        .lookahead_records = lookahead_records,
        .lookaheads_kept = lookaheads_kept,
        .favoured = &favoured,
        .planners_recorded = &planners_recorded,
    };
    var checks: report.Checks = .{};
    // Each block's scores rising with the candidate: the last of each block is its best.
    var scores: [candidate_count]f32 = undefined;
    for (&scores, 0..) |*score, candidate| {
        score.* = float(candidate % candidates_per_planner);
    }
    for ([2]u32{ 3, 1 }) |planner_count| {
        const lookahead: u64 = recording.lookaheads_complete;
        for (0..lookahead_records) |decision| {
            recording.ring.markAppended(recording.stepOf(lookahead, @intCast(decision)));
        }
        recording.complete(&scores, planner_count);
        checks.holds(recording.plannersOf(lookahead) == planner_count, "lookahead {d}: {d} planners\n", .{
            lookahead,
            recording.plannersOf(lookahead),
        });
    }
    // Lookahead 1's favoured: its block's best alone, nothing past its block - though the flags held true before.
    const favoured_1: []const bool = recording.favouredOf(1);
    for (favoured_1, 0..) |is_favoured, candidate| {
        const expected: bool = candidate == candidates_per_planner - 1;
        checks.holds(is_favoured == expected, "lookahead 1, candidate {d} favoured: {}\n", .{
            candidate,
            is_favoured,
        });
    }
    // Lookahead 0's: each of its three blocks' best.
    const favoured_0: []const bool = recording.favouredOf(0);
    for (favoured_0, 0..) |is_favoured, candidate| {
        const expected: bool = candidate % candidates_per_planner == candidates_per_planner - 1;
        checks.holds(is_favoured == expected, "lookahead 0, candidate {d} favoured: {}\n", .{
            candidate,
            is_favoured,
        });
    }
    var generator: Random.DefaultPrng = .init(5);
    const random: Random = generator.random();
    const window_steps: u32 = 2;
    var blocks_seen: [2][3]u32 = @splat(@splat(0));
    for (0..400) |draw| {
        const favoured_only: bool = draw % 2 == 0;
        const start: kit_mod.Start = recording.drawStart(random, window_steps, favoured_only).?;
        const lookahead: usize = @intCast(start.index / lookahead_records);
        blocks_seen[lookahead][start.env / candidates_per_planner] += 1;
    }
    const within_the_block: bool = blocks_seen[1][1] == 0 and blocks_seen[1][2] == 0;
    checks.holds(within_the_block, "lookahead 1's windows past its block: {d}, {d}\n", .{
        blocks_seen[1][1],
        blocks_seen[1][2],
    });
    const every_block_drawn: bool = blocks_seen[0][1] > 0 and blocks_seen[0][2] > 0;
    checks.holds(every_block_drawn, "lookahead 0's later blocks drawn: {d}, {d}\n", .{
        blocks_seen[0][1],
        blocks_seen[0][2],
    });
    var starts: [64]kit_mod.Start = undefined;
    const fresh_from: u64 = 1;
    const pairs_drawn: bool = recording.drawPairStarts(random, window_steps, fresh_from, &starts);
    checks.holds(pairs_drawn, "the gate's pairs not drawn\n", .{});
    var pairs_past_the_block: u32 = 0;
    for (starts) |start| {
        pairs_past_the_block += @intFromBool(start.env >= candidates_per_planner);
    }
    checks.holds(pairs_past_the_block == 0, "{d} gate rows past lookahead 1's block\n", .{pairs_past_the_block});
    try checks.finish();
}

/// ONE LOOKAHEAD's CANDIDATE RECORDS, WRITTEN BY HAND into a hand-kept trainer's candidates' ring, and completed - as a
/// replan would leave them: each planner's candidates set out from one state, and part from the first decision on;
/// every candidate's actions its own; frame row 0 throughout. Equal scores: every candidate favoured alike.
fn recordLookaheadByHand(trainer: *HandKeptTrainer, gpa: Allocator) !void {
    const learner: *Resident(zn_mlp) = trainer.learner;
    const recording: *resident.CandidateRecording = &learner.candidate_recording.?;
    const ring: *kit_mod.RecordRing = &recording.ring;
    const feature_count: usize = learner.kit.features;
    const action_count: usize = learner.kit.actions;
    const record: []f32 = try gpa.alloc(f32, ring.record);
    defer gpa.free(record);
    const lookahead: u64 = recording.lookaheads_complete;
    for (0..recording.lookahead_records) |decision| {
        const index: u64 = recording.stepOf(lookahead, @intCast(decision));
        for (0..ring.envs) |env| {
            const planner: usize = env / recording.candidates_per_planner;
            // At the first decision the planner's state; after it, the candidate's own.
            const whose_state: usize = if (decision == 0) planner else ring.envs + env;
            @memset(record, 0);
            for (record[0..feature_count], 0..) |*feature, column| {
                const phase: f32 = 0.7 * float(column) + 1.3 * float(whose_state) + 0.9 * float(decision);
                feature.* = 0.3 * @sin(phase + 0.5 * float(lookahead));
            }
            for (record[feature_count..][0..action_count], 0..) |*action, number| {
                action.* = 0.2 * @cos(0.6 * float(number) + 1.1 * float(env) + 0.4 * float(decision));
            }
            trainer.host.uploadAt(.ring, ring.recordAt(env, index), record);
        }
        ring.markAppended(index);
    }
    const scores: []f32 = try gpa.alloc(f32, ring.envs);
    defer gpa.free(scores);
    @memset(scores, 1.0);
    const every_planner: u32 = ring.envs / recording.candidates_per_planner;
    recording.complete(scores, every_planner);
}

/// A HAND-KEPT TRAINER RECORDING ITS PLANNERS' CANDIDATES, for the gate's checks: two planners of four candidates each,
/// lookaheads as long as the world model's window, four kept - two of them already written by hand
/// (`recordLookaheadByHand`). Its world model in the dense form, whose random start already answers an action: a
/// normed model's last layer starts at zero, so its first readings have no response for the gate to judge, and a
/// check of how the gate counts its readings needs readings that can pass. `deinit` as any hand-kept trainer.
fn initGateTrainer(
    trainer: *HandKeptTrainer,
    gpa: Allocator,
    phases: resident.Phases,
) !void {
    var options: resident.Options = handKeptOptions(phases);
    options.world_form = .dense_tanh;
    try trainer.init(gpa, options, 40);
    errdefer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const candidates_per_planner: u32 = 4;
    const candidate_count: u32 = 2 * candidates_per_planner;
    const lookaheads_kept: u32 = 4;
    const horizon: u32 = learner.kit.world_steps;
    try learner.acceptCandidateRecording(candidate_count, candidates_per_planner, horizon, lookaheads_kept);
    trainer.host.element_count = @max(trainer.host.element_count, learner.buffers_used.largestBuffer());
    try recordLookaheadByHand(trainer, gpa);
    try recordLookaheadByHand(trainer, gpa);
}

test "robot_track_resident: the world model measured for its gate - pairs from one state, fresh lookaheads only" {
    // A trainer of the gate's checks (`initGateTrainer`) with phases, its candidates' ring written by hand, and its
    // stats block poisoned with NaN. The
    // gate's measurement (`measureWorldModel`): its windows in pairs that set out from one state - rows 2p and 2p + 1's
    // first states the same to the bit - and part at the first step; its six numbers written, finite, and nothing
    // else in the block: nothing is trained. The learner's own stream untouched. Then the cadence, round by round
    // (`train`): not due again before the interval; due after it but refused while no lookahead is fresh - each round
    // makes every complete lookahead the updates' - and made at the first round with a fresh one.
    const gpa: Allocator = testing_allocator;
    var trainer: HandKeptTrainer = undefined;
    try initGateTrainer(&trainer, gpa, .{ .enabled = true });
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const Stats = kit_mod.DeviceStats;
    const poisoned: [Stats.floats]f32 = @splat(nan(f32));
    trainer.host.uploadAt(.params, learner.stats_at, &poisoned);
    const learner_stream_before: Random.DefaultPrng = learner.rng;

    // THE MEASUREMENT.
    learner.measureWorldModel(0);
    try expectEqual(@as(u64, 1), learner.gate_measurements);
    try expectEqual(@as(u64, 0), learner.gate_measurements_refused);
    try expect(eql(u8, asBytes(&learner_stream_before), asBytes(&learner.rng)));
    const acts: []const f32 = trainer.host.readLatest(.acts) orelse return error.NoReadback;
    const features: usize = kit.features;
    const pair_count: usize = kit.rows / 2;
    for (0..pair_count) |pair| {
        const first_row: usize = 2 * pair;
        const second_row: usize = first_row + 1;
        const first_state_at: usize = kit.blockX(0) + kit.lead;
        const first_states: [2][]const f32 = .{
            acts[first_state_at + first_row * kit.width ..][0..features],
            acts[first_state_at + second_row * kit.width ..][0..features],
        };
        try expect(eql(f32, first_states[0], first_states[1]));
        const step_one_at: usize = kit.blockT(1);
        const step_one_states: [2][]const f32 = .{
            acts[step_one_at + first_row * features ..][0..features],
            acts[step_one_at + second_row * features ..][0..features],
        };
        try expect(!eql(f32, step_one_states[0], step_one_states[1]));
    }
    const params: []const f32 = trainer.host.readLatest(.params) orelse return error.NoReadback;
    const stats: []const f32 = params[learner.stats_at..][0..Stats.floats];
    inline for (@typeInfo(Stats).@"struct".field_names) |field_name| {
        const stat: f32 = stats[Stats.slot(field_name)];
        const of_the_gate: bool = comptime startsWith(u8, field_name, "gate_");
        try expectEqual(of_the_gate, isFinite(stat));
    }
    try expect(stats[Stats.slot("gate_no_change_error")] > 0);

    // THE CADENCE. Measured at hours 0: not again before half a minute.
    learner.train();
    try expectEqual(@as(u64, 1), learner.gate_measurements);
    // A minute on: due, but the round before made both lookaheads the updates' - refused, and due still.
    learner.training_hours = 1.0 / 60.0;
    learner.train();
    try expectEqual(@as(u64, 1), learner.gate_measurements);
    try expectEqual(@as(u64, 1), learner.gate_measurements_refused);
    // A lookahead completed since: fresh, and measured.
    try recordLookaheadByHand(&trainer, gpa);
    learner.train();
    try expectEqual(@as(u64, 2), learner.gate_measurements);
    try expectEqual(@as(u64, 1), learner.gate_measurements_refused);
}

test "robot_track_resident: the gate's bars - each failing alone, each passed at its edge, none by numbers not finite" {
    // The default bars (`gatePasses`): the worked reading passes; a reading at every bar's edge passes - an error of
    // exactly a quarter of the no-change model's, a cosine of exactly 0.8, ratios of exactly a half and two; each bar
    // failed on its own fails; a no-change error of 0 - nothing moved - fails; and a number not finite anywhere fails,
    // an infinite no-change error with the rest.
    const gate: resident.Gate = .{};
    const passing: resident.GateReading = .{
        .world_error = 0.02,
        .no_change_error = 0.4,
        .first_response_cosine = 0.93,
        .first_response_ratio = 0.7,
        .last_response_cosine = 0.85,
        .last_response_ratio = 1.4,
    };
    try expect(resident.gatePasses(gate, passing));
    var at_edges: resident.GateReading = passing;
    at_edges.world_error = 0.1;
    at_edges.first_response_cosine = 0.8;
    at_edges.first_response_ratio = 0.5;
    at_edges.last_response_ratio = 2.0;
    try expect(resident.gatePasses(gate, at_edges));
    const Field = enum {
        world_error,
        no_change_error,
        first_response_cosine,
        first_response_ratio,
        last_response_cosine,
        last_response_ratio,
    };
    const Failing = struct { field: Field, value: f32 };
    const failing_alone = [_]Failing{
        .{ .field = .world_error, .value = 0.12 },
        .{ .field = .first_response_cosine, .value = 0.79 },
        .{ .field = .last_response_cosine, .value = 0.5 },
        .{ .field = .first_response_ratio, .value = 0.45 },
        .{ .field = .last_response_ratio, .value = 2.1 },
        .{ .field = .no_change_error, .value = inf(f32) },
    };
    for (failing_alone) |failing| {
        var reading: resident.GateReading = passing;
        switch (failing.field) {
            inline else => |field| @field(reading, @tagName(field)) = failing.value,
        }
        try expect(!resident.gatePasses(gate, reading));
    }
    var nothing_moved: resident.GateReading = passing;
    nothing_moved.world_error = 0;
    nothing_moved.no_change_error = 0;
    try expect(!resident.gatePasses(gate, nothing_moved));
    inline for (@typeInfo(Field).@"enum".field_names) |field_name| {
        var reading: resident.GateReading = passing;
        @field(reading, field_name) = nan(f32);
        try expect(!resident.gatePasses(gate, reading));
    }
}

test "robot_track_resident: the gate opens after its passes in a row - a failure starts the count again" {
    // A trainer of the gate's checks (`initGateTrainer`) with phases, measured at every round (an interval of 0), a
    // fresh lookahead written before each, its bars set round by round: lenient - every finite reading passes - or
    // strict - an error of at most none of the no-change model's, which no model reaches. The CPU's readback is
    // immediate, so each measurement is judged at its own round's end (`judgeGate`). Two passes needed: pass, fail,
    // pass stays in phase 1; the next pass opens phase 2 at its round's hours; after it the gate is judged for the
    // log alone. A measurement awaited from a readback that has not come is not judged, and no other is made
    // meanwhile; once its readback has come it is judged, and the next is made. And a gate that needs no passes never
    // opens.
    const gpa: Allocator = testing_allocator;
    const lenient: resident.Gate = .{
        .measure_every_minutes = 0,
        .state_error_ratio_bar = 1.0e30,
        .response_cosine_bar = -1,
        .response_ratio_band = 1.0e30,
    };
    var strict: resident.Gate = lenient;
    strict.state_error_ratio_bar = 0;
    const minute: f32 = 1.0 / 60.0;
    var trainer: HandKeptTrainer = undefined;
    try initGateTrainer(&trainer, gpa, .{ .enabled = true, .gate = lenient });
    defer trainer.deinit(gpa);
    const learner: *Resident(zn_mlp) = trainer.learner;
    const Round = struct { gate: resident.Gate, passes_in_a_row: u32, in_phase_one: bool };
    const rounds = [_]Round{
        .{ .gate = lenient, .passes_in_a_row = 1, .in_phase_one = true },
        .{ .gate = strict, .passes_in_a_row = 0, .in_phase_one = true },
        .{ .gate = lenient, .passes_in_a_row = 1, .in_phase_one = true },
        .{ .gate = lenient, .passes_in_a_row = 2, .in_phase_one = false },
        .{ .gate = lenient, .passes_in_a_row = 3, .in_phase_one = false },
    };
    for (rounds, 1..) |round, round_number| {
        learner.options.phases.gate = round.gate;
        learner.training_hours = float(round_number) * minute;
        try recordLookaheadByHand(&trainer, gpa);
        learner.train();
        try expectEqual(@as(u64, round_number), learner.gate_judged);
        try expectEqual(round.passes_in_a_row, learner.gate_passes_in_a_row);
        try expectEqual(round.in_phase_one, learner.inPhaseOne());
    }
    try expectEqual(@as(?f32, 4 * minute), learner.phase_two_began_hours);

    // AWAITED: a measurement recorded in a submission the CPU's readback - generation 0 - never reflects.
    const judged_before: u64 = learner.gate_judged;
    const measurements_before: u64 = learner.gate_measurements;
    learner.gate_awaited_submission = 7;
    learner.training_hours = 6 * minute;
    try recordLookaheadByHand(&trainer, gpa);
    learner.train();
    try expectEqual(judged_before, learner.gate_judged);
    try expectEqual(measurements_before, learner.gate_measurements);
    // Its readback come: judged at that round's end - none made in it, awaited at its start - then measured again.
    learner.gate_awaited_submission = 0;
    learner.training_hours = 7 * minute;
    learner.train();
    try expectEqual(judged_before + 1, learner.gate_judged);
    try expectEqual(measurements_before, learner.gate_measurements);
    learner.training_hours = 8 * minute;
    try recordLookaheadByHand(&trainer, gpa);
    learner.train();
    try expectEqual(judged_before + 2, learner.gate_judged);
    try expectEqual(measurements_before + 1, learner.gate_measurements);

    // A GATE THAT NEEDS NO PASSES never opens: phase 2 waits for the bound.
    var closed_gate: resident.Gate = lenient;
    closed_gate.passes_needed = 0;
    var closed_trainer: HandKeptTrainer = undefined;
    try initGateTrainer(&closed_trainer, gpa, .{ .enabled = true, .gate = closed_gate });
    defer closed_trainer.deinit(gpa);
    const closed_learner: *Resident(zn_mlp) = closed_trainer.learner;
    for (1..4) |round_number| {
        closed_learner.training_hours = float(round_number) * minute;
        try recordLookaheadByHand(&closed_trainer, gpa);
        closed_learner.train();
        try expectEqual(@as(u32, @intCast(round_number)), closed_learner.gate_passes_in_a_row);
        try expect(closed_learner.inPhaseOne());
    }
}

test "robot_track_resident: the candidates' batches at their share of the world model's updates, spread evenly" {
    // At a quarter: the fourth, eighth and twelfth of twelve updates.
    var due_at_a_quarter: [12]bool = undefined;
    for (&due_at_a_quarter, 1..) |*due, update| {
        due.* = resident.dueAtShare(update, 0.25);
    }
    const every_fourth = [12]bool{ false, false, false, true, false, false, false, true, false, false, false, true };
    try expectEqualSlices(bool, &every_fourth, &due_at_a_quarter);
    // At 0.8: eighty in a hundred, and never two of the characters' batches in a row.
    var due_count: u32 = 0;
    var previous_due: bool = true;
    for (1..101) |update| {
        const due: bool = resident.dueAtShare(update, 0.8);
        due_count += @intFromBool(due);
        try expect(due or previous_due);
        previous_due = due;
    }
    try expectEqual(@as(u32, 80), due_count);
    // At 0 none, at 1 all.
    for (1..50) |update| {
        try expect(!resident.dueAtShare(update, 0.0));
        try expect(resident.dueAtShare(update, 1.0));
    }
}
