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
const robot_bmpc_kit = @import("robot_bmpc_kit.zig");
const zn_mlp = @import("gpu/zn_mlp.zig");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const testing_allocator = std.testing.allocator;
const Rng = zn.Rng;
const Io = std.Io;
const assertUnreachable = zm.assertUnreachable;
const float64 = zm.float64;
const pi = zm.pi;
const Bmpc = robot_bmpc.Bmpc(f64);

/// The force, in newtons, of a full push: the cartpole's own discrete pushes are +/-10 N.
const full_push_newtons: f64 = 10;

/// The cartpole as a balance task of fixed length, in the form the training loop asks for - in `T`, the number type
/// of the agent it trains: f64 for the CPU agent, f32 for the GPU learning kit's.
fn CartpoleBalanceOf(comptime T: type) type {
    return struct {
        const Self = @This();
        state: zrl.CartpoleState(T) = .{ .cart = 0, .cart_rate = 0, .pole_rad = 0, .pole_rate_rad = 0 },
        /// The steps of the current episode with the pole up: what the gate judges.
        upright_steps: usize = 0,

        pub fn reset(self: *Self, rng: Rng, observation: []T) void {
            self.state = zrl.cartpoleReset(T, rng, 0);
            self.upright_steps = 0;
            // The observation is four numbers by construction, so the width check cannot fail.
            zrl.cartpoleObserve(T, self.state, observation) catch |err| {
                assertUnreachable(@src(), "cartpole observation: {s}", .{@errorName(err)});
            };
        }

        pub fn step(
            self: *Self,
            action: []const T,
            observation: []T,
        ) robot_bmpc.Bmpc(T).StepOutcome {
            const full_push: T = full_push_newtons;
            const force: T = full_push * action[0];
            const stepped: zrl.CartpoleStep(T) = zrl.cartpoleContinuousStep(T, self.state, force);
            self.state = stepped.state;
            zrl.cartpoleObserve(T, self.state, observation) catch |err| {
                assertUnreachable(@src(), "cartpole observation: {s}", .{@errorName(err)});
            };
            // `failed` is the cartpole's own test - the pole past 12 degrees, or the cart past 2.4 m - and what the
            // gate judges. The reward is DMC's, computed after the step, as DMC computes it.
            if (!stepped.failed) {
                self.upright_steps += 1;
            }
            // DMC's balance task never ends an episode itself: a pole past its limit just earns less, and every
            // episode runs to the loop's length.
            const reward: T = zrl.cartpoleBalanceReward(T, self.state, action[0]);
            return .{ .reward = reward };
        }
    };
}

/// The cartpole the CPU agent's gate trains on.
const CartpoleBalance = CartpoleBalanceOf(f64);

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

// ---- THE GATE ON THE GPU LEARNING KIT ----
//
// The same task, settings, schedule and judgement, the agent trained by `robot_bmpc_kit.KitTrainer` on the kit's CPU
// twin - every network, the learning and the planning in the kit's kernels, the host keeping only the cartpoles and
// the replay. One difference in settings: reanalyze plans its 60 stored states in chunks of 4, so a chunk's
// activations fit the kit's buffer (chunks decide exactly as one decision over all of them would). Run alone:
// `zig build bmpc-cartpole -Dtest-filter="kit cartpole"`.

const KitBmpc = robot_bmpc.Bmpc(f32);
const KitCartpole = CartpoleBalanceOf(f32);
const KitCartpoleTrainer = robot_bmpc_kit.KitTrainer(zn_mlp, KitCartpole);
const kit_gate_planner: KitBmpc.PlannerConfig = .{
    .horizon = gate_planner.horizon,
    .iterations = gate_planner.iterations,
    .candidates = gate_planner.candidates,
    .policy_candidates = gate_planner.policy_candidates,
    .elites = gate_planner.elites,
};
const kit_gate_config: KitBmpc.Config = .{
    .latent_width = gate_config.latent_width,
    .hidden_width = gate_config.hidden_width,
    .encoder_hidden_width = gate_config.encoder_hidden_width,
    .simnorm_group = gate_config.simnorm_group,
    .horizon = gate_config.horizon,
    .acting = kit_gate_planner,
    .reanalyzing = kit_gate_planner,
    .windows = gate_config.windows,
    .discount = KitBmpc.discountFor(gate_episode_length),
};
const kit_gate_schedule: KitBmpc.Schedule = .{
    .seed_frames = gate_schedule.seed_frames,
    .burst_updates = gate_schedule.burst_updates,
    .updates_per_frame = gate_schedule.updates_per_frame,
};
const kit_learner_options: robot_bmpc_kit.KitLearner(zn_mlp).Options = .{ .reanalyze_chunk_states = 4 };

/// The kit's trainer for the gate, its starting weights from `seed`.
fn kitGateTrainer(
    arena: Allocator,
    environments: []KitCartpole,
    seed: u32,
) !KitCartpoleTrainer {
    const state_width: u32 = zrl.cartpole_state_dim;
    const networks: KitBmpc.Networks = try .init(arena, Rng.init(seed), state_width, 1, kit_gate_config);
    return KitCartpoleTrainer.init(
        arena,
        environments,
        networks,
        state_width,
        1,
        kit_gate_config,
        kit_gate_schedule,
        gate_episode_length,
        4096,
        Rng.init(seed + 1),
        kit_learner_options,
    );
}

/// The kit's trained planner judged as the CPU gate judges: one episode in each of the gate's cartpoles, evaluating
/// (the drawn elite, no exploration), the fraction of steps with the pole up.
fn kitUprightFraction(
    trainer: *KitCartpoleTrainer,
    pipe: *KitCartpoleTrainer.Pipe,
    arena: Allocator,
    seed: u32,
) !f64 {
    var environments: [gate_environments]KitCartpole = @splat(.{});
    const width: usize = zrl.cartpole_state_dim;
    const observations: []f32 = try arena.alloc(f32, gate_environments * width);
    const next_observations: []f32 = try arena.alloc(f32, gate_environments * width);
    var first_steps: [gate_environments]bool = @splat(true);
    const rng: Rng = .init(seed);
    for (&environments, 0..) |*environment, index| {
        environment.reset(rng.split(@intCast(index)), observations[index * width ..][0..width]);
    }
    for (0..gate_episode_length) |frame| {
        const frame_rng: Rng = rng.split(1000 + @as(u32, @intCast(frame)));
        try trainer.decide(pipe, observations, &first_steps, .evaluate, frame_rng);
        for (&environments, 0..) |*environment, index| {
            _ = environment.step(trainer.actions[index..][0..1], next_observations[index * width ..][0..width]);
        }
        @memcpy(observations, next_observations);
        @memset(&first_steps, false);
    }
    var upright: usize = 0;
    for (environments) |environment| {
        upright += environment.upright_steps;
    }
    return float64(upright) / float64(gate_environments * gate_episode_length);
}

/// The agent's uncertainty signals (`KitPlanner.Signals`) along one evaluated episode of the trained kit agent, logged
/// every tenth step for the first cartpole - beside the pole's angle, so each signal can be read against how close the
/// pole is to falling. A record of what they look like on a task the agent learns.
fn logKitSignals(
    trainer: *KitCartpoleTrainer,
    pipe: *KitCartpoleTrainer.Pipe,
    arena: Allocator,
) !void {
    var environments: [gate_environments]KitCartpole = @splat(.{});
    const width: usize = zrl.cartpole_state_dim;
    const observations: []f32 = try arena.alloc(f32, gate_environments * width);
    const next_observations: []f32 = try arena.alloc(f32, gate_environments * width);
    var first_steps: [gate_environments]bool = @splat(true);
    const rng: Rng = .init(77);
    for (&environments, 0..) |*environment, index| {
        environment.reset(rng.split(@intCast(index)), observations[index * width ..][0..width]);
    }
    std.log.warn("kit cartpole signals: step  pole (deg)  score  disagreement  reward width  value width  " ++
        "latent entropy  inverse spread", .{});
    const simnorm_group: u32 = @intCast(kit_gate_config.simnorm_group);
    for (0..gate_episode_length) |frame| {
        const frame_rng: Rng = rng.split(1000 + @as(u32, @intCast(frame)));
        try trainer.decide(pipe, observations, &first_steps, .evaluate, frame_rng);
        if (frame % 10 == 0) {
            const device_acts: []const f32 = pipe.readLatest(.acts) orelse return error.NoReadback;
            const Signals: type = robot_bmpc_kit.KitPlanner(zn_mlp).Signals;
            const signals: Signals = trainer.actor.readSignals(device_acts, 0, simnorm_group);
            const pole_degrees: f32 = environments[0].state.pole_rad * 180 / pi;
            const row_format: []const u8 = "kit cartpole signals: {d:>4}  {d:>10.2}  {d:>5.2}  {d:>12.4}  " ++
                "{d:>12.3}  {d:>11.3}  {d:>14.3}  {d:>14.3}";
            std.log.warn(row_format, .{
                frame,
                pole_degrees,
                signals.plan_score,
                signals.heads_disagreement,
                signals.reward_width,
                signals.value_width,
                signals.latent_entropy,
                signals.first_layer_inverse_spread,
            });
        }
        for (&environments, 0..) |*environment, index| {
            _ = environment.step(trainer.actions[index..][0..1], next_observations[index * width ..][0..width]);
        }
        @memcpy(observations, next_observations);
        @memset(&first_steps, false);
    }
}

test "kit cartpole timing: what the gate's frames cost on the kit's CPU twin" {
    // Not the gate: its first frames, each kind timed - the seed frames (random actions, no learning), pretraining
    // updates, and planned frames with their update (one of them reanalyzing) - and the whole gate's time estimated
    // from them, so the gate is known to fit its budget before it runs.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    const io: Io = std.testing.io;
    var environments: [gate_environments]KitCartpole = @splat(.{});
    var trainer: KitCartpoleTrainer = try kitGateTrainer(arena, &environments, 7);
    var pipe: KitCartpoleTrainer.Pipe = .initCpu();
    defer pipe.deinit();
    trainer.uploadStart(&pipe);
    // The seed frames: random actions into the replay.
    for (0..gate_schedule.seed_frames) |_| {
        _ = try trainer.runFrame(&pipe);
    }
    // Pretraining updates, timed.
    const probe_updates: u32 = 20;
    const updates_started: Io.Timestamp = Io.Clock.now(.awake, io);
    for (0..probe_updates) |update_number| {
        const update_rng: Rng = Rng.init(5).split(@intCast(update_number));
        try trainer.learner.update(&pipe, &trainer.replay, update_rng, @intCast(update_number), true, null);
    }
    const update_ns: i96 = Io.Clock.now(.awake, io).nanoseconds - updates_started.nanoseconds;
    // Planned frames with their update, timed - ten real updates, so the tenth reanalyzes.
    trainer.frame = gate_schedule.seed_frames + 1;
    const probe_frames: u32 = 10;
    const frames_started: Io.Timestamp = Io.Clock.now(.awake, io);
    for (0..probe_frames) |_| {
        _ = try trainer.runFrame(&pipe);
    }
    const frames_ns: i96 = Io.Clock.now(.awake, io).nanoseconds - frames_started.nanoseconds;
    const seconds_per_update: f64 = float64(update_ns) / 1e9 / float64(probe_updates);
    const seconds_per_frame: f64 = float64(frames_ns) / 1e9 / float64(probe_frames);
    const planned_frames: usize = gate_frames - gate_schedule.seed_frames;
    const estimated_seconds: f64 = seconds_per_update * float64(gate_schedule.burst_updates) +
        seconds_per_frame * float64(planned_frames);
    std.log.warn("kit cartpole timing: {d:.3} s per pretraining update, {d:.3} s per planned frame " ++
        "(with its update, reanalyze every tenth); the gate's run about {d:.0} s", .{
        seconds_per_update,
        seconds_per_frame,
        estimated_seconds,
    });
}

test "kit cartpole gate: trained on the GPU learning kit, the planner learns as the CPU agent does" {
    // The CPU gate's run on the kit: the same 700 frames - seeding, the burst of pretraining updates, then planning
    // with an update every frame - judged the same way on fresh episodes, against the same random control. What it
    // asks is the CPU agent's own level at this budget, LEARNING rather than mastery: the CPU gate measures 0.333 to
    // 0.52 of the steps up across seeds (its own bar of 0.9, mastery, needs BMPC's tens of thousands of updates), so
    // the kit's agent must reach 0.333, at least 0.15 above acting at random.
    var arena_state: ArenaAllocator = .init(testing_allocator);
    defer arena_state.deinit();
    const arena: Allocator = arena_state.allocator();
    var environments: [gate_environments]KitCartpole = @splat(.{});
    var trainer: KitCartpoleTrainer = try kitGateTrainer(arena, &environments, 7);
    var pipe: KitCartpoleTrainer.Pipe = .initCpu();
    defer pipe.deinit();
    trainer.uploadStart(&pipe);
    for (0..gate_frames) |_| {
        _ = try trainer.runFrame(&pipe);
    }
    const trained: f64 = try kitUprightFraction(&trainer, &pipe, arena, 99);
    const random: f64 = randomUprightFraction(99);
    try logKitSignals(&trainer, &pipe, arena);
    const cpu_gate_level: f64 = 0.333;
    const passed: bool = trained >= cpu_gate_level and random <= 0.5 and trained - random >= 0.15;
    std.log.warn("kit cartpole gate: the pole up {d:.3} of the steps trained on the kit, {d:.3} acting at random", .{
        trained,
        random,
    });
    if (!passed) {
        return error.GateFailed;
    }
}
