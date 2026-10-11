//! robot_bmpc_cartpole.zig - BMPC learns to balance a cartpole: the end-to-end gate of the BMPC agent.
//!
//! Every part of the agent has its own tests in robot_bmpc.zig; this file checks the claim those tests cannot make on
//! their own - that the parts, assembled and trained, LEARN. It trains a small BMPC agent on zrl's cartpole and then
//! judges it in the real simulator, against the same judgement of the agent before training.
//!
//! It trains for a few minutes, so it is not part of test-fast: `zig build bmpc-cartpole` runs it, optimised.
//!
//!     train:   seed with random actions -> the burst (world model only) -> plan and update, frame after frame
//!              (`gate_schedule`, `gate_frames`: 1650 updates over 2800 environment steps)
//!     judge:   the trained planner, evaluating, on fresh episodes  -> the fraction of steps with the pole up
//!     control: random actions on the same episodes                 -> the same fraction
//!     pass:    trained >= 0.9, random <= 0.5, and trained ahead of random by at least 0.4
//!
//! THE TASK. The cartpole as a balance task of fixed length, rewarded as the DeepMind Control Suite rewards its
//! cartpole balance task (`zrl.cartpoleBalanceReward`): upright x centred x small control x small velocity, every
//! factor graded. The action in [-1, 1] pushes the cart with up to 10 N. A fallen pole does not end the episode -
//! BMPC has no notion of termination - so an agent that lets the pole fall earns little for the rest of it.
//!
//! WHY THAT REWARD. BMPC plans three steps ahead (0.06 s here) and leaves the rest to its value function. With a
//! reward of 1 while the pole is up, every short plan scores the same until the pole is past saving, so the agent can
//! balance only once its value function has learned what is about to fall. A graded reward lets the plan itself see
//! which way is better - the setting BMPC's settings were tuned for, on the DeepMind Control Suite.
//!
//! WHAT IS JUDGED is behaviour, not reward: the fraction of steps with the pole within 12 degrees of vertical and the
//! cart within 2.4 m of the centre - the cartpole's own `failed` test, reversed.
const std = @import("std");
const zm = @import("zm");
const zn = @import("zn");
const zrl = @import("zrl");
const robot_bmpc = @import("robot_bmpc.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const Rng = zn.Rng;
const assertUnreachable = zm.assertUnreachable;
const float64 = zm.float64;
const pi = zm.pi;
const Bmpc = robot_bmpc.Bmpc(f64);

/// The force, in newtons, of a full push: the cartpole's own discrete pushes are +/-10 N.
const full_push_newtons: f64 = 10;

/// The cartpole as a balance task of fixed length, in the form the training loop asks for.
const CartpoleBalance = struct {
    state: zrl.CartpoleState(f64) = .{ .cart = 0, .cart_rate = 0, .pole_rad = 0, .pole_rate_rad = 0 },
    /// The steps of the current episode with the pole up: what the gate judges.
    upright_steps: usize = 0,

    pub fn reset(self: *CartpoleBalance, rng: Rng, observation: []f64) void {
        self.state = zrl.cartpoleReset(f64, rng, 0);
        self.upright_steps = 0;
        // The observation is four numbers by construction, so the width check cannot fail.
        zrl.cartpoleObserve(f64, self.state, observation) catch |err| {
            assertUnreachable(@src(), "cartpole observation: {s}", .{@errorName(err)});
        };
    }

    pub fn step(self: *CartpoleBalance, action: []const f64, observation: []f64) f64 {
        const force: f64 = full_push_newtons * action[0];
        const stepped: zrl.CartpoleStep(f64) = zrl.cartpoleContinuousStep(f64, self.state, force);
        self.state = stepped.state;
        zrl.cartpoleObserve(f64, self.state, observation) catch |err| {
            assertUnreachable(@src(), "cartpole observation: {s}", .{@errorName(err)});
        };
        // `failed` is the cartpole's own test - the pole past 12 degrees, or the cart past 2.4 m - and what the gate
        // judges. The reward is DMC's, computed after the step, as DMC computes it.
        if (!stepped.failed) {
            self.upright_steps += 1;
        }
        return zrl.cartpoleBalanceReward(f64, self.state, action[0]);
    }
};

const CartpoleTrainer = Bmpc.Trainer(CartpoleBalance);

const gate_environments: usize = 4;
const gate_episode_length: usize = 100;

/// The gate's training, sized to the 5-minute budget: 50 seed frames (200 random steps), a burst of 1000 updates, then
/// the planner with one update per frame - 1650 updates over 2800 environment steps in all.
const gate_schedule: Bmpc.Schedule = .{ .seed_frames = 50, .burst_updates = 1000, .updates_per_frame = 1 };
const gate_frames: usize = 700;

/// The gate's planner, for acting and reanalyze alike: BMPC's search, narrower.
const gate_planner: Bmpc.PlannerConfig = .{
    .horizon = 3,
    .iterations = 4,
    .candidates = 64,
    .policy_candidates = 8,
    .elites = 8,
};

/// The small agent the gate trains: BMPC's structure, with widths a CPU trains in minutes.
const gate_config: Bmpc.Config = .{
    .latent_width = 32,
    .hidden_width = 64,
    .encoder_hidden_width = 32,
    .simnorm_group = 8,
    .horizon = 3,
    .acting = gate_planner,
    .reanalyzing = gate_planner,
    .windows = 32,
    // The trainer sets this from the episode's length in any case (BMPC's rule); stated here as what it will be.
    .discount = Bmpc.discountFor(gate_episode_length),
};

fn gateTrainer(
    arena: Allocator,
    environments: []CartpoleBalance,
    schedule: Bmpc.Schedule,
    seed: u32,
) !CartpoleTrainer {
    const networks: Bmpc.Networks = try .init(arena, Rng.init(seed), zrl.cartpole_state_dim, 1, gate_config);
    return CartpoleTrainer.init(
        arena,
        environments,
        networks,
        zrl.cartpole_state_dim,
        1,
        gate_config,
        schedule,
        gate_episode_length,
        4096,
        Rng.init(seed + 1),
    );
}

/// The fraction of all the environments' steps with the pole up.
fn countUpright(environments: []const CartpoleBalance) f64 {
    var upright: usize = 0;
    for (environments) |environment| {
        upright += environment.upright_steps;
    }
    return float64(upright) / float64(environments.len * gate_episode_length);
}

/// The fraction of steps the pole stays up over one episode in each of the gate's environments, acted on by the
/// trained agent's planner in evaluation mode (the drawn elite, no exploration noise).
fn uprightFraction(trainer: *CartpoleTrainer, arena: Allocator, seed: u32) !f64 {
    var environments: [gate_environments]CartpoleBalance = @splat(.{});
    const width: usize = zrl.cartpole_state_dim;
    const observations: []f64 = try arena.alloc(f64, gate_environments * width);
    const next_observations: []f64 = try arena.alloc(f64, gate_environments * width);
    const first_steps: []bool = try arena.alloc(bool, gate_environments);
    const decision: Bmpc.Decision = .{
        .actions = try arena.alloc(f64, gate_environments),
        .target_means = try arena.alloc(f64, gate_environments),
        .target_spreads = try arena.alloc(f64, gate_environments),
    };
    const rng: Rng = .init(seed);
    for (&environments, 0..) |*environment, index| {
        environment.reset(rng.split(@intCast(index)), observations[index * width ..][0..width]);
    }
    @memset(first_steps, true);
    for (0..gate_episode_length) |frame| {
        const frame_rng: Rng = rng.split(1000 + @as(u32, @intCast(frame)));
        try trainer.actor.act(observations, first_steps, .evaluate, frame_rng, decision);
        for (&environments, 0..) |*environment, index| {
            _ = environment.step(decision.actions[index..][0..1], next_observations[index * width ..][0..width]);
        }
        @memcpy(observations, next_observations);
        @memset(first_steps, false);
    }
    return countUpright(&environments);
}

/// The same judgement for random actions, uniform in [-1, 1] - what an untrained planner amounts to, since its
/// zero-initialised reward and value heads score every plan 0.
fn randomUprightFraction(seed: u32) f64 {
    var environments: [gate_environments]CartpoleBalance = @splat(.{});
    var observation: [zrl.cartpole_state_dim]f64 = undefined;
    const rng: Rng = .init(seed);
    for (&environments, 0..) |*environment, index| {
        environment.reset(rng.split(@intCast(index)), &observation);
    }
    for (0..gate_episode_length) |frame| {
        for (&environments, 0..) |*environment, index| {
            const draw: u32 = @intCast(frame * gate_environments + index);
            const action: [1]f64 = .{rng.split(2000).uniform(f64, draw, -1, 1)};
            _ = environment.step(&action, &observation);
        }
    }
    return countUpright(&environments);
}

test "bmpc cartpole gate: trained, the planner keeps the pole up; acting at random does not" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var environments: [gate_environments]CartpoleBalance = @splat(.{});
    var trainer: CartpoleTrainer = try gateTrainer(arena, &environments, gate_schedule, 7);
    for (0..gate_frames) |_| {
        _ = try trainer.runFrame();
    }
    const trained: f64 = try uprightFraction(&trainer, arena, 99);
    const random: f64 = randomUprightFraction(99);
    const passed: bool = trained >= 0.9 and random <= 0.5 and trained - random >= 0.4;
    if (!passed) {
        std.log.err("bmpc cartpole gate: the pole up {d:.3} of the steps trained, {d:.3} acting at random", .{
            trained,
            random,
        });
        return error.GateFailed;
    }
}

// ---- The gate's run, instrumented: what to read when it fails. The world model's losses through training; the score
// of a do-nothing plan from four canonical states, against the true reward there; and how far apart the planner scores
// its own candidates, which is what decides whether its choice means anything.

fn logReport(frame: usize, report: ?Bmpc.LearnerReport) void {
    const world_model: Bmpc.WorldModelReport = report.?.world_model;
    std.log.warn("frame {d}: consistency {d:.4}  reward {d:.4}  value {d:.4}  total {d:.4}  gradient {d:.3}", .{
        frame,
        world_model.consistency,
        world_model.reward,
        world_model.value,
        world_model.total,
        world_model.gradient_norm,
    });
}

test "bmpc cartpole diagnosis: losses, the model's view of canonical states, the planner's spread" {
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var environments: [gate_environments]CartpoleBalance = @splat(.{});
    var trainer: CartpoleTrainer = try gateTrainer(arena, &environments, gate_schedule, 7);
    for (0..gate_frames) |frame| {
        _ = try trainer.runFrame();
        if (frame == 49 or (frame + 1) % 150 == 0 or frame + 1 == gate_frames) {
            logReport(frame, trainer.last_report);
        }
    }
    // Zero-action plans from four canonical states: rest, tilted 0.2 rad, level, hanging.
    const actor: *Bmpc.Actor = &trainer.actor;
    const angles = [gate_environments]f64{ 0, 0.2, pi / 2.0, pi };
    for (angles, 0..) |angle, index| {
        const state: zrl.CartpoleState(f64) = .{ .cart = 0, .cart_rate = 0, .pole_rad = angle, .pole_rate_rad = 0 };
        try zrl.cartpoleObserve(f64, state, actor.scorer.observations.data[index * 4 ..][0..4]);
    }
    for (actor.scorer.actions) |step_actions| {
        @memset(step_actions.data, 0);
    }
    try actor.scorer.score(actor.scorer_graph, actor.candidate_scores);
    const per_state: usize = actor.candidate_scores.len / gate_environments;
    for (angles, 0..) |angle, index| {
        std.log.warn("zero-action plan from pole {d:.2} rad: score {d:.4} (true reward at rest there {d:.4})", .{
            angle,
            actor.candidate_scores[index * per_state],
            zrl.cartpoleBalanceReward(f64, .{ .cart = 0, .cart_rate = 0, .pole_rad = angle, .pole_rate_rad = 0 }, 0),
        });
    }
    // The planner's own candidates at rest: how far apart does it score them?
    var observations: [gate_environments * 4]f64 = undefined;
    for (0..gate_environments) |index| {
        const state: zrl.CartpoleState(f64) = .{ .cart = 0, .cart_rate = 0, .pole_rad = 0.05, .pole_rate_rad = 0 };
        try zrl.cartpoleObserve(f64, state, observations[index * 4 ..][0..4]);
    }
    const first_steps: [gate_environments]bool = @splat(true);
    try actor.act(&observations, &first_steps, .evaluate, Rng.init(5), trainer.decision);
    var lowest: f64 = actor.candidate_scores[0];
    var highest: f64 = actor.candidate_scores[0];
    for (actor.candidate_scores[0..per_state]) |score| {
        lowest = @min(lowest, score);
        highest = @max(highest, score);
    }
    std.log.warn("planner at pole 0.05 rad: candidate scores from {d:.4} to {d:.4}; chosen action {d:.4}", .{
        lowest,
        highest,
        trainer.decision.actions[0],
    });
}
