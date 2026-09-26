//! robot_track_resident_tests - the resident learner's tests, in a file of their own.
//!
//! WHY THEY LIVE HERE. A test needs a CONCRETE kernel module, which means importing
//! `gpu/zn_mlp.zig` by path - and every page builds that same file as its own module. A file that
//! imports it therefore cannot belong to the `zimr` module a page also imports, or Zig rightly
//! refuses: one file, two modules. Keeping the tests apart is what lets the learner itself be part of
//! the engine, which is how `robot_ppo_track` and its tests are arranged too.

const std = @import("std");
const track = @import("robot_track.zig");
const kit_mod = @import("robot_latent_kit.zig");
/// The fleet on the baked get-up clip is a test-only helper, so it lives with the kit's tests.
const kit_tests = @import("robot_latent_kit_tests.zig");
const compute_host = @import("compute_host.zig");
const resident = @import("robot_track_resident.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");

const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const Resident = resident.Resident;

test "robot_track_resident: the loop runs, the world model learns, and the simulation acts from the mirror" {
    // A few rounds of the real loop on a real fleet: simulate and record, train the world model, train
    // the policy, refresh the mirror. What it checks is that the pieces fit - the ring's bookkeeping,
    // the slots, the layouts - and that the loop does something: the world model's loss falls, and the
    // weights the simulation acts from follow the GPU's. How WELL it learns is a budget question, and
    // the step-for-step comparisons against the CPU reference answer the correctness one.
    const gpa: Allocator = std.testing.allocator;
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
    const before_policy: []f32 = try gpa.dupe(f32, learner.mirror);
    defer gpa.free(before_policy);
    for (0..12) |round| {
        learner.round();
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
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  resident loop, 12 rounds: world loss {d:.3} -> {d:.3}, {d} world and {d} policy updates\n", .{
        first_loss,
        last_loss,
        learner.world_updates,
        learner.policy_updates,
    });
    try expect(learner.world_updates == 12 and learner.policy_updates == 12);
    try expect(last_loss < first_loss);
    // The mirror followed the GPU: the policy has moved since it was seeded.
    var moved: f32 = 0.0;
    for (learner.mirror, before_policy) |now, then| {
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
    const gpa: Allocator = std.testing.allocator;
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
        learner.round();
    }
    const kit: *kit_mod.LatentKit(zn_mlp) = &learner.kit;
    const actions: usize = learner.raw.len;
    try expect(learner.drawWindows(0));
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
        @memcpy(learner.goal, acts[at..][0..f]);
        @memcpy(learner.z, acts[at + kit.lead ..][0..f]);
        learner.policyRow();
        const theirs: []const f32 = acts[kit.raw_at + row * actions ..][0..actions];
        for (theirs, learner.raw) |gpu, mirrored| {
            worst = @max(worst, @abs(gpu - mirrored));
            largest = @max(largest, @abs(gpu));
        }
    }
    // lint:off debug-print: test-only numbers for the plan journal; tests never run on wasm
    std.debug.print("\n  mirror vs the kit's policy, {d} rows x {d} actions: " ++
        "worst difference {e} (largest action {e})\n", .{
        kit.rows,
        actions,
        worst,
        largest,
    });
    try expect(worst < 1.0e-5 * @max(largest, 1.0e-3));
}
