//! robot_track_resident_tests - the resident learner's tests, in a file of their own.
//!
//! WHY THEY LIVE HERE. A test needs a CONCRETE kernel module, which means importing
//! `gpu/zn_mlp.zig` by path - and every page builds that same file as its own module. A file that
//! imports it therefore cannot belong to the `zimr` module a page also imports, or Zig rightly
//! refuses: one file, two modules. Keeping the tests apart is what lets the learner itself be part of
//! the engine, which is how `robot_ppo_track` and its tests are arranged too.

const zm = @import("zm");
const float = zm.float;
const clamp = zm.clamp;
const inf = zm.inf;
const nan = zm.nan;
const std = @import("std");
const zrl = @import("zrl");
const report = @import("test_report.zig");
const track = @import("robot_track.zig");
const dance = @import("robot_dance.zig");
const kit_mod = @import("robot_latent_kit.zig");
const latent = @import("robot_latent.zig");
const bmpc_kit = @import("robot_bmpc_kit.zig");
const zn = @import("zn");
/// The fleet on the baked get-up clip is a test-only helper, so it lives with the kit's tests.
const kit_tests = @import("robot_latent_kit_tests.zig");
const compute_host = @import("compute_host.zig");
const resident = @import("robot_track_resident.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");
const lab = @import("robot_lab.zig");
const rbt = @import("robot.zig");
const robot_policy = @import("robot_policy.zig");

const Allocator = std.mem.Allocator;
const Random = std.Random;
const Io = std.Io;
const expect = std.testing.expect;
const testing_allocator = std.testing.allocator;
const eql = std.mem.eql;
const asBytes = std.mem.asBytes;
const expectError = std.testing.expectError;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expectApproxEqAbs = std.testing.expectApproxEqAbs;
const expectApproxEqRel = std.testing.expectApproxEqRel;
const expectEqualSlices = std.testing.expectEqualSlices;
const ArenaAllocator = std.heap.ArenaAllocator;
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
    const f: usize = track.localSize(fleet.m.nbody);
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
        moved = @max(moved, @abs(now - then));
    }
    try expect(moved > 0.0);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
        @memcpy(learner.host.goal, acts[at..][0..f]);
        @memcpy(learner.host.z, acts[at + kit.lead ..][0..f]);
        learner.host.policyRow();
        const theirs: []const f32 = acts[kit.raw_at + row * actions ..][0..actions];
        for (theirs, learner.host.raw) |gpu, mirrored| {
            worst = @max(worst, @abs(gpu - mirrored));
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
    const f: usize = track.localSize(fleet.m.nbody);
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

test "robot_track_resident: a saved state resumes the same learner; another learner's file is refused by name" {
    // Plan A1's known answers, on the kit's CPU twin. A learner is trained a few rounds - so its weights, Adam's
    // moments, its counters and its random stream have all moved from where a fresh learner starts - and saved. A
    // fresh learner then loads the file. What must hold:
    //
    //   * the fresh learner, saved again, writes the very same bytes: every parameter, moment, normaliser value,
    //     counter and the random stream's state, bit for bit;
    //   * it chooses the saved learner's action on the same features, bit for bit (the mirror is the saved policy);
    //   * a file whose options differ is refused, naming the option;
    //   * CONTROL - one exponent bit of the policy's last parameter changed in the file: the action differs. Without
    //     it, the action check could pass because loading did nothing and both learners happened to agree.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.nbody);
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
    };
    // One CPU pipe for both learners: on the CPU twin the kit's buffers are the kernel module's own, so the second
    // learner's `init` seeds fresh weights over the first one's - exactly what a restarted trainer would see.
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const saved_action: []f32 = try gpa.alloc(f32, action_count);
    defer gpa.free(saved_action);

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
        break :saved try saved_learner.exportState(gpa);
    };
    defer gpa.free(saved_state);

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

    // CONTROL: the policy's last parameter - the last action's output bias - with its top exponent bit flipped (a
    // zero becomes 2.0, anything else changes by orders of magnitude). The file is still well formed, so it loads,
    // and the action must move.
    const damaged_state: []u8 = try gpa.dupe(u8, saved_state);
    defer gpa.free(damaged_state);
    const parameter_count: usize = resumed_learner.kit.param_count + resumed_learner.kit.policy_count;
    const last_parameter_at: usize = header_size + (parameter_count - 1) * @sizeOf(f32);
    const exponent_byte_at: usize = last_parameter_at + 3;
    damaged_state[exponent_byte_at] ^= 0x40;
    try resumed_learner.importState(gpa, damaged_state);
    resumed_learner.features(0);
    resumed_learner.host.policyRow();
    const damaged_file_acts_otherwise: bool = !eql(f32, resumed_learner.host.raw, saved_action);
    try expect(damaged_file_acts_otherwise);
}

test "robot_track_resident: a SuperTrack policy file acts as the kit's policy bit for bit, and as the learner acts" {
    // Plan A2's known answers. A learner trained a few rounds writes its policy (`lab.policyOfSuperTrack`), which goes
    // through its file as the lab reads it. Then:
    //
    //   * on rows the kit gathered itself, the file's policy gives the kit's own policy output BIT FOR BIT: the same
    //     weights in the same layout, summed in the same order (the bias, then the inputs), through the same tanh;
    //   * on the learner's own fleet, for 600 physics steps with the file's policy acting, the lab's decider builds the
    //     observation and decides as the learner's mirror does - to rounding, since the mirror sums the goal and the
    //     state interleaved rather than one after the other - and the controller hands the fleet that action
    //     unchanged (no filter, every step);
    //   * CONTROL: one bias of the file's last layer changed, and the kit's rows are no longer matched.
    //
    // The normaliser is not the identity, so that normalising - and normalising the goal and the state alike - is
    // part of what is checked.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.nbody);
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
    );
    const policy_bytes: []u8 = try lab.PolicyFile.encode(arena, &written_policy);
    var policy: lab.GenoPolicy = try lab.PolicyFile.decode(arena, policy_bytes);
    try expectEqual(@as(u32, 1), policy.decimation);

    // The kit's own rows: real windows gathered on the device, the acting rollout with no noise.
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const action_count: usize = learner.host.raw.len;
    try expect(learner.drawWindows(0, .anywhere));
    learner.data.gather(kit, 0);
    const sigma: f32 = kit.sigma;
    kit.sigma = 0.0;
    kit.forward();
    kit.sigma = sigma;
    const activations: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    const scratch: lab.PolicyScratch = try .init(arena, &policy);
    const goal_and_state: []f32 = try arena.alloc(f32, 2 * feature_count);
    const file_action: []f32 = try arena.alloc(f32, action_count);
    var rows_matched_exactly: usize = 0;
    for (0..kit.rows) |row| {
        const row_start: usize = kit.blockX(0) + row * kit.width;
        @memcpy(goal_and_state[0..feature_count], activations[row_start..][0..feature_count]);
        @memcpy(goal_and_state[feature_count..], activations[row_start + kit.lead ..][0..feature_count]);
        lab.policyMeanAction(&policy, goal_and_state, scratch, file_action);
        const kit_action: []const f32 = activations[kit.raw_at + row * action_count ..][0..action_count];
        if (eql(f32, kit_action, file_action)) {
            rows_matched_exactly += 1;
        }
    }
    try expectEqual(@as(usize, kit.rows), rows_matched_exactly);

    // The lab's decider on the learner's own fleet, acting for 600 physics steps, against the learner's mirror.
    const character_count: usize = fleet.options.envs;
    var decider: lab.PolicyDecider = try .init(arena, fleet.m, fleet.options.body_names, .{}, &policy);
    var controller: robot_policy.Controller = try .init(arena, fleet.m, decider.subset, character_count, .{
        .beta = policy.filter_beta,
        .decimation = policy.decimation,
    });
    const decided_actions: []f32 = try arena.alloc(f32, character_count * action_count);
    var worst_difference: f32 = 0.0;
    var largest_action: f32 = 0.0;
    for (0..600) |_| {
        decider.decide(&policy, &controller, fleet, character_count, decided_actions);
        for (0..character_count) |character| {
            learner.features(character);
            learner.host.policyRow();
            const decided: []const f32 = decided_actions[character * action_count ..][0..action_count];
            for (decided, learner.host.raw) |from_file, from_mirror| {
                worst_difference = @max(worst_difference, @abs(from_file - from_mirror));
                largest_action = @max(largest_action, @abs(from_mirror));
            }
        }
        const applied_actions: []const f32 = controller.apply(decided_actions);
        try expectEqualSlices(f32, decided_actions, applied_actions);
        _ = fleet.step(applied_actions);
    }
    report.print("\n  SuperTrack policy file vs the mirror, 600 steps x {d} characters: worst {e} (largest {e})\n", .{
        character_count,
        worst_difference,
        largest_action,
    });
    try expect(worst_difference < 1.0e-5 * @max(largest_action, 1.0e-3));

    // CONTROL: a bias of the last layer changed - the kit's first row is no longer what the file's policy gives.
    const last_layer: lab.PolicyLayer = policy.layers[policy.layers.len - 1];
    last_layer.weights_and_biases[last_layer.weights_and_biases.len - 1] += 0.5;
    const first_row_start: usize = kit.blockX(0);
    @memcpy(goal_and_state[0..feature_count], activations[first_row_start..][0..feature_count]);
    @memcpy(goal_and_state[feature_count..], activations[first_row_start + kit.lead ..][0..feature_count]);
    lab.policyMeanAction(&policy, goal_and_state, scratch, file_action);
    try expect(!eql(f32, activations[kit.raw_at..][0..action_count], file_action));
}

test "robot_track_resident: a SuperTrack policy of zero weights is judged as the servo alone" {
    // The judge's first control, for the new observation: every weight and bias zero acts with zero offsets, so the
    // judgement must equal the servo's on the same starts exactly - which holds the decider's SuperTrack path, its
    // every-step decisions and its unfiltered controller to the judge's own.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const m: *rbt.Model = setup.fleet.m;
    const feature_count: usize = track.localSize(m.nbody);
    var arena_state: ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const hidden_width: usize = 8;
    const action_count: usize = track.actionSize(m);
    const first_layer: usize = lab.PolicyLayer.parameterCount(.tanh, 2 * feature_count, hidden_width);
    const second_layer: usize = lab.PolicyLayer.parameterCount(.tanh, hidden_width, hidden_width);
    const third_layer: usize = lab.PolicyLayer.parameterCount(.none, hidden_width, action_count);
    const zero_weights: []f32 = try arena.alloc(f32, first_layer + second_layer + third_layer);
    @memset(zero_weights, 0.0);
    const means: []f32 = try arena.alloc(f32, feature_count);
    const spreads: []f32 = try arena.alloc(f32, feature_count);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    const parts: resident.PolicyParts = .{
        .packed_weights = zero_weights,
        .feature_count = feature_count,
        .hidden_width = hidden_width,
        .action_count = action_count,
        .normalizer = .{ .mean = means, .spread = spreads },
    };
    const policy: lab.GenoPolicy = try lab.policyOfSuperTrack(arena, parts, setup.fleet.options.action_scale);
    const starts: []usize = try track.evenStarts(arena, &setup.clip, 30);
    const settings: lab.PolicyJudgeSettings = .{ .starts = starts };
    const names: []const []const u8 = setup.imported.names;
    const servo: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, null, settings);
    const zero: track.Judgement = try lab.judgePolicy(gpa, arena, m, names, &setup.clip, &policy, settings);
    try expectEqual(servo.starts, zero.starts);
    try expectEqual(servo.failures, zero.failures);
    try expectEqual(servo.reached_end, zero.reached_end);
    try expectEqual(servo.watched_steps, zero.watched_steps);
    try expectEqual(servo.reward_sum, zero.reward_sum);
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
    const feature_count: usize = track.localSize(fleet.m.nbody);
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
    const trained_weights: []const f32 = params_after[online_start..][0..online_floats];
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
    const feature_count: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
        const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
            const example_width: usize = 2 * f + action_width;
            const example: []const f32 = learner.distillation_examples[kept_at * example_width ..][0..example_width];
            try expectEqualSlices(f32, goal_copy, example[0..f]);
            try expectEqualSlices(f32, state_copy, example[f..][0..f]);
            try expectEqualSlices(f32, planned_copy, example[2 * f ..][0..action_width]);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
        @memcpy(learner.host.goal, acts[at..][0..f]);
        @memcpy(learner.host.z, acts[at + kit.lead ..][0..f]);
        for (start_noise, 0..) |*noise_value, synergy| {
            const hashed: f32 = zn_mlp.latNoise(step_seed, @intCast(row), @intCast(synergy));
            noise_value.* = correction.noise_scale * hashed;
        }
        learner.host.correctedRow(start_noise);
        const kit_raw: []const f32 = acts[kit.raw_at + row * action_count ..][0..action_count];
        for (kit_raw, learner.host.raw) |kit_value, host_value| {
            worst = @max(worst, @abs(kit_value - host_value));
            largest = @max(largest, @abs(kit_value));
        }
    }
    report.print("\n  the host's corrected policy vs the kit's, {d} rows x {d} actions: worst difference {e} " ++
        "(largest action {e})\n", .{ kit.rows, action_count, worst, largest });
    try expect(largest > 0);
    try expect(worst <= 1e-4 * @max(1, largest));
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const pending_width: usize = 3 * f + synergy_count;
    const pending: []const f32 = learner.fpo_pending[0..pending_width];
    try expectEqualSlices(f32, own_goal, pending[0..f]);
    try expectEqualSlices(f32, goal, pending[f..][0..f]);
    try expectEqualSlices(f32, state, pending[2 * f ..][0..f]);
    const coefficients: []f32 = try gpa.dupe(f32, pending[3 * f ..][0..synergy_count]);
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
    try expectEqualSlices(f32, own_goal, example[0..f]);
    try expectEqualSlices(f32, goal, example[f..][0..f]);
    try expectEqualSlices(f32, state, example[2 * f ..][0..f]);
    try expectEqualSlices(f32, coefficients, example[3 * f ..][0..synergy_count]);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    // 1. Every draw row holds its example's condition and coefficients.
    const condition_width: usize = 2 * f;
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    // A learner with a skip model of 4 steps in its 8-step windows (two jumps a window). Trained a dozen world model
    // updates: the skip model's loss is finite and falls from its first update's, and the gate's pair - its first
    // jump's error and the world model's rolled the same steps - is recorded. Saved, then loaded by a fresh learner
    // on the same pipe: the trained skip model's weights are the loaded learner's, number for number, and saving again
    // writes the same bytes.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.nbody);
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
        while (learner.world_updates < 12 and rounds < 40) : (rounds += 1) {
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
    const feature_count: usize = track.localSize(fleet.m.nbody);
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
    // Two learners on fleets set up alike, one with a skip head of 4 steps: after six rounds the world model's and the
    // policy's weights must be the same numbers. The head reads the world model's layers but sends no gradient back,
    // and its starting weights come from a stream of their own - so all it adds is itself.
    const gpa: Allocator = testing_allocator;
    const without_head: resident.Options = .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
    };
    var with_head: resident.Options = without_head;
    with_head.skip_span = 4;
    const plain_weights: []f32 = try trainedNetworkWeights(gpa, without_head, 6);
    defer gpa.free(plain_weights);
    const headed_weights: []f32 = try trainedNetworkWeights(gpa, with_head, 6);
    defer gpa.free(headed_weights);
    try expectEqualSlices(f32, plain_weights, headed_weights);
}

test "robot_track_resident: the world model's change in units of the typical change - measured, placed, learned" {
    // A learner with the change's statistics on (a floor of 0.03): the means and spreads it places for the kit must be
    // `measureClipIncrements` on its fleet's clips - the spreads at least the floor - and the loss weights 1 / spread
    // squared; then it must learn a few rounds with every number finite.
    const gpa: Allocator = testing_allocator;
    var setup: kit_tests.FleetSetup = undefined;
    try setup.init(gpa);
    defer setup.deinit();
    const fleet: *track.Fleet = setup.fleet;
    const feature_count: usize = track.localSize(fleet.m.nbody);
    const means: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(means);
    const spreads: []f32 = try gpa.alloc(f32, feature_count);
    defer gpa.free(spreads);
    @memset(means, 0.0);
    @memset(spreads, 1.0);
    const spread_floor: f32 = 0.03;
    var host: compute_host.Compute(zn_mlp) = .initCpu();
    const learner: *Resident(zn_mlp) = try .init(gpa, &host, fleet, .{ .mean = means, .spread = spreads }, .{
        .rows = 8,
        .window = 8,
        .hidden = 32,
        .policy_hidden = 32,
        .collect = 32,
        .increment_spread_floor = spread_floor,
    });
    defer learner.deinit();
    const increments_at: u32 = learner.kit.increments_at.?;
    const loss_weights_at: u32 = learner.kit.loss_weights_at.?;
    const normalizer: latent.Normalizer = .{ .mean = means, .spread = spreads };
    const expected: latent.Normalizer =
        try latent.measureClipIncrements(gpa, fleet.m, fleet.clips, normalizer, spread_floor);
    defer gpa.free(expected.mean);
    defer gpa.free(expected.spread);
    host.element_count = 0xffff_ffff;
    const acts: []const f32 = host.readLatest(.acts) orelse return error.NoReadback;
    try expectEqualSlices(f32, expected.mean, acts[increments_at..][0..feature_count]);
    try expectEqualSlices(f32, expected.spread, acts[increments_at + feature_count ..][0..feature_count]);
    for (expected.spread, acts[loss_weights_at..][0..feature_count]) |spread, weight| {
        try expect(spread >= spread_floor);
        try expectEqual(1.0 / (spread * spread), weight);
    }
    while (learner.world_updates < 4) {
        learner.simulateAndTrain();
    }
    learner.waitForReadback();
    const loss: f32 = learner.device_stats.world_model_loss;
    try expect(loss == loss and loss > 0 and loss < 1.0e9);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
        const record: []const f32 = data.staging[env * data.record ..][0..data.record];
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    try resumed_learner.importState(gpa, saved_state);
    const state_saved_again: []u8 = try resumed_learner.exportState(gpa);
    defer gpa.free(state_saved_again);
    try expectEqualSlices(u8, saved_state, state_saved_again);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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

test "robot_track_resident: the policy's windows inside returns - all of them at a share of 1, the old draws at 0" {
    // A learner on a fleet with an aftermath and returns, its untrained policy falling. With every window to be
    // drawn inside a return, each window the policy stages starts on a record after a loss; with none, the policy
    // stages exactly the windows `before_loss` draws from the same random stream - a learner without returns is
    // unchanged.
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
    const f: usize = track.localSize(m.nbody);
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
    try expect(learner.drawPolicyWindows(0));
    for (learner.starts) |start| {
        try expect(fleet.replay.afterLossAt(start.env, start.index));
    }
    // A share of 0: the same windows as the old rule, from the same stream.
    learner.options.return_window_share = 0;
    const stream_before: Random.DefaultPrng = learner.rng;
    try expect(learner.drawWindows(0, .before_loss));
    const old_starts: []kit_mod.Start = try gpa.dupe(kit_mod.Start, learner.starts);
    defer gpa.free(old_starts);
    learner.rng = stream_before;
    try expect(learner.drawPolicyWindows(0));
    for (old_starts, learner.starts) |old_start, start| {
        try expectEqual(old_start.env, start.env);
        try expectEqual(old_start.index, start.index);
    }
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
    const f: usize = track.localSize(m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    const f: usize = track.localSize(fleet.m.nbody);
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
    for (0..12) |_| {
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
    const f: usize = track.localSize(m.nbody);
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
            try expectEqualSlices(f32, one_fleet.data[env].pos, four_fleet.data[env].pos);
            try expectEqualSlices(f32, one_fleet.data[env].vel, four_fleet.data[env].vel);
        }
    }
}
